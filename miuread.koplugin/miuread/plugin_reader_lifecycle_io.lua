-- MiuRead reader lifecycle + interactive network controller, extracted from main.lua.
-- Owns:
--   * interactive network workers (_run_interactive_network / _request_catalog /
--     _wait_for_network / _cancel_network_waits + auth snapshot apply)
--   * reader lifecycle state machine (_finalize_reader_instance_close /
--     _start_reader_rebuild_candidate / _finish_reader_rebuild_candidate /
--     _reader_rebuild_ready_state / _reader_rebuild_cancel)
-- Both domains share the same Plugin instance (self) but are logically
-- independent; keeping them together avoids cross-controller calls.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Text = require("miuread.text")
local U = require("miuread.util")
local Session = require("miuread.session_state")
local HomeView = require("miuread.home_view")
local Lazy = require("miuread.lazy")
local ok_socket, socket = pcall(require, "socket")
local function monotonic_wall_time()
    if ok_socket and socket and type(socket.gettime)=="function" then return socket.gettime() end
    return os.time()
end

local _ = Text.tr
local HOME_SESSION = Session.home()
local READER_REBUILD = Session.reader_rebuild()
local normalized_reader_file = Session.normalized_reader_file
local reader_rebuild_active = Session.reader_rebuild_active

local function interactive_child_store(auth,data_dir,temp_dir)
    local current=U.copy(type(auth)=="table" and auth or {})
    local changed=false
    local store={data_dir=tostring(data_dir or ""),temp_dir=tostring(temp_dir or "")}
    function store:auth() return U.copy(current) end
    function store:save_auth(value) current=U.copy(type(value)=="table" and value or {}); changed=true end
    function store:snapshot() return U.copy(current),changed end
    return store
end

local Plugin = {}

function Plugin:_interactive_network_context()
    return {
        reader_file=normalized_reader_file(self:_current_document_path()),
        reader_generation=tonumber(HOME_SESSION.reader_session_generation) or 0,
        home_shown=HomeView.is_shown()==true,
        home_section=tostring(self._home_active_section or ""),
    }
end

function Plugin:_interactive_network_context_valid(context)
    context=type(context)=="table" and context or {}
    if self._miuread_suspended==true or HOME_SESSION.suspended==true or Session.home_exiting() then return false end
    local current_file=normalized_reader_file(self:_current_document_path())
    if context.reader_file then
        return current_file==context.reader_file
            and tonumber(HOME_SESSION.reader_session_generation or 0)==tonumber(context.reader_generation or 0)
    end
    if current_file then return false end
    if context.home_shown then
        return HomeView.is_shown()==true and tostring(self._home_active_section or "")==tostring(context.home_section or "")
    end
    return true
end

function Plugin:_apply_interactive_auth(snapshot)
    if type(snapshot)~="table" or snapshot.changed~=true or type(snapshot.auth)~="table" then return false end
    local current=self.store:auth()
    local incoming=snapshot.auth
    local current_session=tostring(current.login_session_id or "")
    local incoming_session=tostring(incoming.login_session_id or "")
    if current_session=="" or incoming_session=="" or current_session~=incoming_session then
        logger.warn("[MiuRead][NetTask] ignored stale auth snapshot")
        return false
    end
    local current_vid=tostring((current.account or {}).vid or (current.cookies or {}).wr_vid or "")
    local incoming_vid=tostring((incoming.account or {}).vid or (incoming.cookies or {}).wr_vid or "")
    if current_vid~="" and incoming_vid~="" and current_vid~=incoming_vid then
        logger.warn("[MiuRead][NetTask] ignored cross-account auth snapshot")
        return false
    end
    self.store:save_auth(incoming)
    return true
end

function Plugin:_cancel_interactive_network(reason)
    self._interactive_network_generation=(tonumber(self._interactive_network_generation) or 0)+1
    self._interactive_network_key=nil
    if self.interactive_network_async then self.interactive_network_async:cancel(reason or "cancelled") end
    return true
end

function Plugin:_run_interactive_network(key,label,worker,callback,options)
    options=type(options)=="table" and options or {}
    key=tostring(key or label or "interactive")
    label=tostring(label or key)
    if not self:is_online() then
        if options.silent~=true then self:info(_("Network unavailable")) end
        return false,"offline"
    end
    local async=self.interactive_network_async
    if not async or not async:available() then
        if options.silent~=true then self:info("当前设备暂时无法启动后台网络任务，请稍后重试。") end
        return false,"background worker unavailable"
    end
    if async:busy() then
        if tostring(self._interactive_network_key or "")==key then
            if options.silent~=true then self:toast("该网络请求正在进行中",2) end
            return false,"duplicate request"
        end
        self:_cancel_interactive_network("superseded by "..key)
    end
    self._interactive_network_generation=(tonumber(self._interactive_network_generation) or 0)+1
    local generation=self._interactive_network_generation
    self._interactive_network_key=key
    local context=options.context or self:_interactive_network_context()
    local started_at=monotonic_wall_time()
    if options.status_title and options.status_text and options.silent~=true then
        self:status_toast(options.status_title,options.status_text,tonumber(options.status_seconds) or 2)
    end
    logger.info("[MiuRead][NetTask] started","key=",key)
    local started,err=async:run(label,worker,function(result)
        if generation~=self._interactive_network_generation then return end
        self._interactive_network_key=nil
        local network_ms=math.floor((monotonic_wall_time()-started_at)*1000+.5)
        if not self:_interactive_network_context_valid(context) then
            logger.info("[MiuRead][NetTask] stale result dropped","key=",key,"network_ms=",tostring(network_ms))
            return
        end
        local callback_started=monotonic_wall_time()
        if callback then callback(result) end
        local callback_ms=math.floor((monotonic_wall_time()-callback_started)*1000+.5)
        logger.info("[MiuRead][NetTask] completed","key=",key,
            "network_ms=",tostring(network_ms),"callback_ms=",tostring(callback_ms),
            "ok=",tostring(result and result.ok==true))
    end,tonumber(options.timeout) or 35)
    if not started then
        if generation==self._interactive_network_generation then self._interactive_network_key=nil end
        if options.silent~=true then self:info("无法启动后台网络任务：\n"..tostring(err or "未知错误")) end
        return false,err
    end
    return true
end

function Plugin:_request_catalog(book,label,on_ready,options)
    options=type(options)=="table" and options or {}
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if id=="" then return false,"missing book id" end
    local auth=U.copy(self.store:auth())
    local data_dir,temp_dir=self.store.data_dir,self.store.temp_dir
    label=tostring(label or "catalog")
    local key="catalog:"..id..":"..label
    return self:_run_interactive_network(key,label,function()
        local HttpChild=require("miuread.http")
        local ReaderChild=require("miuread.content_reader")
        local DownloaderChild=require("miuread.downloader")
        local child_store=interactive_child_store(auth,data_dir,temp_dir)
        local child_http=HttpChild:new(child_store)
        local child_reader=ReaderChild:new(child_http,child_store)
        local child_downloader=DownloaderChild:new(child_reader,nil,nil,child_store,child_http)
        local request_ok,catalog,rows=pcall(child_downloader.catalog,child_downloader,id)
        local child_auth,auth_changed=child_store:snapshot()
        return {request_ok=request_ok,rows=request_ok and rows or nil,
            error=request_ok and nil or tostring(catalog),auth=child_auth,auth_changed=auth_changed}
    end,function(result)
        if not result or result.ok~=true then
            local message=result and result.error or "章节目录加载失败"
            if options.on_error then options.on_error(message)
            elseif options.silent~=true then self:info(self:_friendly_remote_error(message,"章节目录加载")) end
            return
        end
        local payload=type(result.value)=="table" and result.value or {}
        if payload.auth_changed==true then self:_apply_interactive_auth{auth=payload.auth,changed=true} end
        if payload.request_ok~=true then
            local message=tostring(payload.error or "章节目录加载失败")
            if options.on_error then options.on_error(message)
            elseif options.silent~=true then self:info(self:_friendly_remote_error(message,"章节目录加载")) end
            return
        end
        if on_ready then on_ready(type(payload.rows)=="table" and payload.rows or {}) end
    end,{
        context=options.context,timeout=tonumber(options.timeout) or 45,silent=options.silent,
        status_title=options.status_title or "章节",
        status_text=options.status_text or "正在后台读取章节目录…",
        status_seconds=2,
    })
end

function Plugin:_wait_for_network(label,callback,options)
    options=options or {}
    self._network_wait_tokens=self._network_wait_tokens or {}
    label=tostring(label or "default")
    local token=(tonumber(self._network_wait_tokens[label]) or 0)+1
    self._network_wait_tokens[label]=token
    local started=os.time()
    local minimum=math.max(0,tonumber(options.minimum_delay) or 0)
    local maximum=math.max(minimum+1,tonumber(options.max_wait) or 45)
    local interval=math.max(.5,tonumber(options.interval) or 2)
    local function check()
        if not self._network_wait_tokens or self._network_wait_tokens[label]~=token then return end
        local elapsed=os.time()-started
        if elapsed>=minimum and self:is_online() then
            self._network_wait_tokens[label]=nil
            callback(true)
            return
        end
        if elapsed>=maximum then
            self._network_wait_tokens[label]=nil
            callback(false)
            return
        end
        UIManager:scheduleIn(interval,check)
    end
    UIManager:scheduleIn(math.max(.1,tonumber(options.initial_delay) or .1),check)
    return token
end
function Plugin:_cancel_network_waits()
    self._network_wait_tokens={}
end
function Plugin:_reader_rebuild_cancel(reason,clear_shared)
    local owner=READER_REBUILD.owner
    if owner and owner._reader_rebuild_task then
        pcall(UIManager.unschedule,UIManager,owner._reader_rebuild_task)
        owner._reader_rebuild_task=nil
    end
    if self._reader_rebuild_task then
        UIManager:unschedule(self._reader_rebuild_task)
        self._reader_rebuild_task=nil
    end
    READER_REBUILD.generation=(tonumber(READER_REBUILD.generation) or 0)+1
    if clear_shared~=false then
        READER_REBUILD.state="idle"
        READER_REBUILD.session_generation=0
        READER_REBUILD.reader_file=nil
        READER_REBUILD.started_at=0
        READER_REBUILD.started_clock=0
        READER_REBUILD.max_wait=0
        READER_REBUILD.reason=nil
        READER_REBUILD.owner=nil
        READER_REBUILD.pending_width=nil
        READER_REBUILD.pending_height=nil
        READER_REBUILD.pending_rotation=nil
        READER_REBUILD.internal_hint=false
    end
    if reason then logger.info("[MiuRead][Lifecycle] rebuild watcher cancelled",tostring(reason)) end
    return true
end

function Plugin:_prepare_reader_disappearance(reason)
    if self._reader_checkpoint_dirty==true then
        self:_flush_reader_checkpoint(reason or "reader_disappeared",true)
    end
    self:_mark_reader_busy(4)
    self:_close_active_thought_popup(reason or "reader disappeared")
    if ThoughtNativePopup and type(ThoughtNativePopup.cleanup)=="function" then
        pcall(ThoughtNativePopup.cleanup)
    end
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    if self._local_annotation_snapshot_task then
        UIManager:unschedule(self._local_annotation_snapshot_task)
        self._local_annotation_snapshot_task=nil
    end
    if self._reader_sync_ready_task then
        UIManager:unschedule(self._reader_sync_ready_task)
        self._reader_sync_ready_task=nil
    end
    self:_cancel_network_waits()
    self:_cancel_interactive_network(reason or "reader disappeared")
    if self.repair_async and self.repair_async.job and self.repair_async.job.label=="book-migration-check" then
        self.repair_async:cancel(reason or "reader disappeared")
        if self.annotation_async then self.annotation_async:cancel(reason or "reader disappeared") end
    end
    self._miuread_repair_prompt_open=false
    self:_teardown_thought_tap()
    self:_teardown_external_annotations()
    self._progress_prompted_book_id=nil
    self._progress_check_running=false
    return true
end

function Plugin:_finalize_reader_instance_close(closing_path,session_generation,options)
    options=type(options)=="table" and options or {}
    local explicit_return=options.explicit_return==true
    local document_switch=options.document_switch==true
    closing_path=normalized_reader_file(closing_path)
        or normalized_reader_file(HOME_SESSION.reader_session_file)
        or normalized_reader_file(Session.home().reader_file)
    session_generation=tonumber(session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0

    self:_prepare_reader_disappearance(options.reason or "document closed")
    if self.sync then self.sync:on_close() end
    -- A pending reader-only cloud pull must not follow the plugin back to the
    -- home screen where it would retry its gate forever.
    self:_sync_scheduler_cancel("external_annotations")

    -- A confirmed switch has a new ReaderUI already alive. Never clear shared
    -- reader markers or start Home/post-reader work from the old plugin instance.
    if document_switch then
        logger.info("[MiuRead][Lifecycle] previous reader finalized after document switch",
            "book=",tostring(closing_path or ""),"session=",tostring(session_generation))
        return true
    end

    if self._reader_active_path then os.remove(self._reader_active_path) end
    if self._reader_busy_path then
        local busy_path=self._reader_busy_path
        UIManager:scheduleIn(4,function() os.remove(busy_path) end)
    end
    self:_schedule_post_reader_work("document closed",1.4)
    HOME_SESSION.reader_session_active=false

    if explicit_return then
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
    end

    if self:_home_enabled() and Session.home().reader_origin and not Session.home().suppressed
        and not Session.home().native_visit and not Session.home_exiting() then
        self:_set_foreground("reader_transition")
        if explicit_return then
            READER_CLOSE.close_event_received=true
            if READER_CLOSE.state~="native_surface_waiting" then READER_CLOSE.state="document_closed" end
            self._miuread_return_requested=false
            logger.info("[MiuRead][ReaderClose] CloseDocument received",
                "generation=",tostring(READER_CLOSE.generation))
            self:_schedule_reader_return_finish(READER_CLOSE.generation,.10,"explicit close document")
        else
            self:_schedule_reader_close_settle(closing_path,session_generation,"confirmed document close")
        end
    else
        self:_set_foreground("native")
        UIManager:scheduleIn(.12,function()
            if self:_reader_lifecycle_state()~="closed" then return end
            if self:_filemanager_instance() or self:_ensure_filemanager_base(closing_path) then
                if ReaderTransitionGuard.is_shown() then
                    self:_release_reader_transition_guard("native surface restored")
                end
                UIManager:setDirty(nil,"ui")
                self:_finish_page_transition(.8,"native surface restored")
            else
                self:_finish_page_transition(0,"native restore failed")
                self:_show_reader_recovery_surface("KOReader 文件管理器未能恢复")
            end
        end)
    end
    return true
end

function Plugin:_finish_reader_rebuild_candidate(generation,reason)
    if generation~=(tonumber(READER_REBUILD.generation) or 0)
        or not reader_rebuild_active() then return false end
    if HOME_SESSION.suspended==true or self._miuread_suspended==true then
        READER_REBUILD.state="suspended_pending"
        self._reader_rebuild_task=nil
        return false
    end
    local active=self:_active_reader_ui()
    if active and active.document then
        local current=normalized_reader_file(self:_reader_file(active))
        local expected=normalized_reader_file(READER_REBUILD.reader_file)
        if current and expected and current==expected then
            local elapsed=math.floor((monotonic_wall_time()-(tonumber(READER_REBUILD.started_clock) or monotonic_wall_time()))*1000+.5)
            logger.info("[MiuRead][Lifecycle] reader rebuild completed",
                "same_book=true","session=",tostring(READER_REBUILD.session_generation or 0),
                "ms=",tostring(math.max(0,elapsed)))
            self:_reader_rebuild_cancel("same reader returned",true)
            return true
        end
        local old_owner=READER_REBUILD.owner
        local old_path=READER_REBUILD.reader_file
        local old_session=READER_REBUILD.session_generation
        self:_reader_rebuild_cancel("different reader returned",true)
        if old_owner and type(old_owner._finalize_reader_instance_close)=="function" then
            pcall(old_owner._finalize_reader_instance_close,old_owner,old_path,old_session,
                {document_switch=true,reason="reader switched during rebuild candidate"})
        end
        return true
    end

    local elapsed=math.max(0,monotonic_wall_time()-(tonumber(READER_REBUILD.started_clock) or monotonic_wall_time()))
    if elapsed<(tonumber(READER_REBUILD.max_wait) or 2.4) then
        local task
        task=function()
            if self._reader_rebuild_task~=task then return end
            self._reader_rebuild_task=nil
            self:_finish_reader_rebuild_candidate(generation,reason)
        end
        self._reader_rebuild_task=task
        UIManager:scheduleIn(elapsed<1.0 and .18 or .28,task)
        return false
    end

    local old_path=READER_REBUILD.reader_file
    local old_session=READER_REBUILD.session_generation
    self:_reader_rebuild_cancel("candidate confirmed closed",true)
    logger.info("[MiuRead][Lifecycle] rebuild candidate became real close",
        "book=",tostring(old_path or ""),"wait_ms=",tostring(math.floor(elapsed*1000+.5)))
    return self:_finalize_reader_instance_close(old_path,old_session,
        {reason=reason or "rebuild candidate timeout"})
end

function Plugin:_start_reader_rebuild_candidate(closing_path,session_generation,reason,internal_hint)
    self:_reader_rebuild_cancel(nil,true)
    local now=monotonic_wall_time()
    local path=normalized_reader_file(closing_path)
        or normalized_reader_file(HOME_SESSION.reader_session_file)
        or normalized_reader_file(Session.home().reader_file)
    if path and READER_REBUILD.recent_book==path and now-(tonumber(READER_REBUILD.recent_started_at) or 0)<=10 then
        READER_REBUILD.recent_count=(tonumber(READER_REBUILD.recent_count) or 0)+1
    else
        READER_REBUILD.recent_book=path
        READER_REBUILD.recent_count=1
    end
    READER_REBUILD.recent_started_at=now
    if READER_REBUILD.recent_count>=3 then READER_REBUILD.safe_until=now+15 end

    READER_REBUILD.generation=(tonumber(READER_REBUILD.generation) or 0)+1
    local generation=READER_REBUILD.generation
    READER_REBUILD.state="pending"
    READER_REBUILD.session_generation=tonumber(session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0
    READER_REBUILD.reader_file=path
    READER_REBUILD.started_at=os.time()
    READER_REBUILD.started_clock=now
    READER_REBUILD.reason=tostring(reason or "CloseDocument without explicit return")
    READER_REBUILD.owner=self
    READER_REBUILD.internal_hint=internal_hint==true

    local recent_dimension=now-(tonumber(HOME_SESSION.last_dimension_event_clock) or 0)<=5
    local recent_resume=now-(tonumber(HOME_SESSION.last_resume_clock) or 0)<=8
    local fuse=(tonumber(READER_REBUILD.safe_until) or 0)>now
    -- ReaderUI marks reloadDocument()/switchDocument() with tearing_down=true.
    -- A same-book internal reload on slower Kindle devices can legitimately
    -- take several seconds, so give that explicit signal a longer bounded
    -- window without delaying ordinary unrequested closes.
    READER_REBUILD.max_wait=READER_REBUILD.internal_hint and 18.0
        or (fuse and 5.5 or ((recent_dimension or recent_resume) and 4.2 or 2.4))
    self:_set_foreground("reader")
    logger.info("[MiuRead][Lifecycle] rebuild candidate",
        "book=",tostring(path or ""),"session=",tostring(READER_REBUILD.session_generation),
        "recent_dimensions=",tostring(recent_dimension),"recent_resume=",tostring(recent_resume),
        "internal_hint=",tostring(READER_REBUILD.internal_hint),"fuse=",tostring(fuse),
        "deadline_ms=",tostring(math.floor(READER_REBUILD.max_wait*1000+.5)))

    local task
    task=function()
        if self._reader_rebuild_task~=task then return end
        self._reader_rebuild_task=nil
        self:_finish_reader_rebuild_candidate(generation,READER_REBUILD.reason)
    end
    self._reader_rebuild_task=task
    UIManager:scheduleIn(.22,task)
    return true
end

function Plugin:_reader_rebuild_ready_state()
    if not reader_rebuild_active() then return false,false end
    local ready_path=normalized_reader_file(self:_current_document_path())
    local expected=normalized_reader_file(READER_REBUILD.reader_file)
    if ready_path and expected and ready_path==expected then
        local preserved_session=tonumber(READER_REBUILD.session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0
        local elapsed=math.floor((monotonic_wall_time()-(tonumber(READER_REBUILD.started_clock) or monotonic_wall_time()))*1000+.5)
        self:_reader_rebuild_cancel("ReaderReady same book",true)
        HOME_SESSION.reader_session_generation=preserved_session
        HOME_SESSION.reader_session_active=true
        HOME_SESSION.reader_session_file=ready_path
        logger.info("[MiuRead][Lifecycle] reader returned",
            "same_book=true","preserved_session=",tostring(preserved_session),
            "ms=",tostring(math.max(0,elapsed)))
        return true,true
    end
    local old_owner=READER_REBUILD.owner
    local old_path=READER_REBUILD.reader_file
    local old_session=READER_REBUILD.session_generation
    self:_reader_rebuild_cancel("ReaderReady different book",true)
    if old_owner and type(old_owner._finalize_reader_instance_close)=="function" then
        pcall(old_owner._finalize_reader_instance_close,old_owner,old_path,old_session,
            {document_switch=true,reason="different ReaderReady"})
    end
    logger.info("[MiuRead][Lifecycle] reader returned","same_book=false",
        "old=",tostring(old_path or ""),"new=",tostring(ready_path or ""))
    return true,false
end

local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
