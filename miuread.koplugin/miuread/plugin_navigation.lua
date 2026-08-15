-- MiuRead reader navigation / lifecycle controller, split from main.lua.
-- Owns the reader open/close/rebuild/return state machine. Home rendering
-- methods (_show_miuread_home_now and friends) stay in main.lua.
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Session = require("miuread.session_state")
local HomeView = require("miuread.home_view")
local Device = require("device")
local U = require("miuread.util")
local HomeData = require("miuread.home_data")
local Lazy = require("miuread.lazy")
local ReaderToolbar = Lazy("miuread.reader_toolbar")
local ReaderTransitionGuard = require("miuread.reader_transition_guard")

local HOME_SESSION = Session.home()
local NAVIGATION = Session.navigation()
local NAVIGATION_STATES = Session.NAVIGATION_STATES
local READER_CLOSE = Session.reader_close()
local READER_REBUILD = Session.reader_rebuild()

local function navigation_state_from_foreground(owner)
    return Session.navigation_state_from_foreground(owner)
end
local function reader_close_active()
    return Session.reader_close_active()
end
local function reader_rebuild_active()
    return Session.reader_rebuild_active()
end
local function normalized_reader_file(path)
    return Session.normalized_reader_file(path)
end
local function mark_reader_origin(path)
    return Session.mark_reader_origin(path)
end

local ok_socket, socket = pcall(require, "socket")
local function monotonic_wall_time()
    if ok_socket and socket and type(socket.gettime) == "function" then return socket.gettime() end
    return os.time()
end

local Plugin = {}

function Plugin:_reader_file(readerui,file)
    local path=normalized_reader_file(file)
    if path then return path end
    local document=readerui and readerui.document or nil
    if document then
        path=normalized_reader_file(document.file or (document.getFilePath and document:getFilePath()) or nil)
    end
    return path
end

function Plugin:_reader_should_return_home(readerui,file)
    if not self:_home_enabled() or Session.home().suppressed or Session.home().native_visit
        or Session.home_exiting() or UIManager._exit_code~=nil then return false end
    local path=self:_reader_file(readerui,file)
    if Session.home().reader_origin then
        if path and not Session.home().reader_file then mark_reader_origin(path) end
        return true
    end
    if path and Session.home().reader_file and path==Session.home().reader_file then
        mark_reader_origin(path)
        return true
    end
    return false
end

function Plugin:_install_reader_quick_panel_zone()
    if not self:_home_enabled() then return false end
    local readerui=self.ui
    if not readerui or not readerui.document then return false end
    -- Keep KOReader's own touch-zone geometry and priority. The menu bridge
    -- below redirects only the native menu handler after links, footnotes,
    -- highlights and normal page gestures have had their normal chance.
    if not readerui._miuread_native_menu_zone_preserved then
        readerui._miuread_native_menu_zone_preserved=true
        logger.info("[MiuRead][ReaderToolbar] native menu touch zones preserved")
    end
    return true
end

function Plugin:_install_reader_menu_bridge()
    if not self:_home_enabled() then return false end
    local readerui=self.ui
    local menu=readerui and readerui.menu or nil
    if not readerui or not readerui.document or not menu then return false end
    if menu._miuread_bridge_owner==self then return true end

    local original_tap=menu.onTapShowMenu
    local original_swipe=menu.onSwipeShowMenu
    local original_press=menu.onPressMenu
    local original_key=menu.onKeyPressShowMenu
    local plugin=self

    menu._miuread_bridge_owner=self
    menu._miuread_original_onTapShowMenu=original_tap
    menu._miuread_original_onSwipeShowMenu=original_swipe
    menu._miuread_original_onPressMenu=original_press
    menu._miuread_original_onKeyPressShowMenu=original_key

    menu.onTapShowMenu=function(native_menu,ges)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            -- Desktop mode reserves the reader control center for a downward
            -- menu swipe. Ordinary taps remain part of the reading surface and
            -- never leave a persistent MiuRead bar behind.
            return nil
        end
        if type(original_tap)=="function" then return original_tap(native_menu,ges) end
    end
    menu.onSwipeShowMenu=function(native_menu,ges)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            local activation=native_menu.activation_menu
                or (G_reader_settings and G_reader_settings:readSetting("activate_menu")) or "swipe_tap"
            if activation~="tap" and ges and ges.direction=="south" then
                local shown=plugin:show_reader_quick_panel()
                if shown then readerui:handleEvent(Event:new("HandledAsSwipe")) end
                return shown
            end
            return nil
        end
        if type(original_swipe)=="function" then return original_swipe(native_menu,ges) end
    end
    menu.onPressMenu=function(native_menu,...)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            return plugin:show_reader_quick_panel()
        end
        if type(original_press)=="function" then return original_press(native_menu,...) end
    end
    menu.onKeyPressShowMenu=function(native_menu,...)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            return plugin:show_reader_quick_panel()
        end
        if type(original_key)=="function" then return original_key(native_menu,...) end
    end
    logger.info("[MiuRead][ReaderToolbar] native menu handlers redirected; touch zones unchanged")
    return true
end

function Plugin:_install_reader_home_bridge()
    local readerui=self.ui
    if not readerui or not readerui.document or type(readerui.onHome)~="function" then return false end
    local plugin=self
    if not readerui._miuread_original_onHome then
        local original=readerui.onHome
        readerui._miuread_original_onHome=original
        readerui.onHome=function(ui,...)
            if plugin and plugin._reader_context and plugin:_reader_should_return_home(ui) then
                logger.info("[MiuRead][Reader] native bookshelf redirected before FileManager")
                return plugin:return_to_miuread_home()
            end
            return original(ui,...)
        end
    end
    if type(readerui.showFileManager)=="function" and not readerui._miuread_original_showFileManager then
        local original_show_filemanager=readerui.showFileManager
        readerui._miuread_original_showFileManager=original_show_filemanager
        readerui.showFileManager=function(ui,file,...)
            local args={n=select("#",...),...}
            local return_home=plugin and plugin:_reader_should_return_home(ui,file)
            local generation
            if return_home then
                local path=plugin:_reader_file(ui,file)
                Session.home().return_file =path or Session.home().return_file
                mark_reader_origin(path)
                generation=plugin:_begin_reader_return("native filemanager",path,false)
                READER_CLOSE.native_requested=true
                READER_CLOSE.state="native_surface_waiting"
                logger.info("[MiuRead][ReaderClose] native FileManager requested",
                    "generation=",tostring(generation))
            end
            -- Never suppress KOReader's native transition. It owns document
            -- teardown and FileManager creation; MiuRead only observes the
            -- stable docless surface and raises the parked home afterwards.
            local packed={xpcall(function()
                return original_show_filemanager(ui,file,unpack_args(args,1,args.n))
            end,debug.traceback)}
            if not packed[1] then error(packed[2]) end
            if return_home then plugin:_schedule_reader_return_finish(generation,.10,"native filemanager") end
            return unpack_args(packed,2,#packed)
        end
    end
    return true
end

function Plugin:onHome()
    if self.ui and self.ui.document and self:_reader_should_return_home(self.ui) then
        logger.info("[MiuRead][Reader] Home event redirected to MiuRead home")
        return self:return_to_miuread_home()
    end
    if not (self.ui and self.ui.document) and self:_home_enabled()
        and Session.home().native_visit and not Session.home_exiting() then
        logger.info("[MiuRead][Home] FileManager Home event redirected to MiuRead home")
        return self:_return_from_native_filemanager()
    end
    return false
end

function Plugin:_reader_instance()
    local ok,ReaderUI=pcall(require,"apps/reader/readerui")
    if not ok or not ReaderUI then return nil end
    return ReaderUI.instance
end

function Plugin:_widget_in_window_stack(target)
    if not target then return false end
    for _,window in ipairs(UIManager._window_stack or {}) do
        if window and window.widget==target then return true end
    end
    if type(UIManager.isWidgetShown)=="function" then
        local ok,shown=pcall(UIManager.isWidgetShown,UIManager,target)
        if ok and shown==true then return true end
    end
    return false
end

function Plugin:_reader_in_window_stack(reader)
    reader=reader or self:_reader_instance()
    return reader~=nil and self:_widget_in_window_stack(reader)
end

function Plugin:_reader_lifecycle_state()
    local reader=self:_reader_instance()
    if reader and reader.document then return "active",reader end
    if reader and self:_reader_in_window_stack(reader) then return "closing",reader end
    return "closed",reader
end

function Plugin:_active_reader_ui()
    local state,reader=self:_reader_lifecycle_state()
    return state=="active" and reader or nil
end

function Plugin:_filemanager_instance()
    local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
    return ok and FileManager and FileManager.instance or nil
end

function Plugin:_navigation_state()
    local state=tostring(NAVIGATION.state or "native")
    if not NAVIGATION_STATES[state] then state="native" end
    return state
end

function Plugin:_set_navigation_state(state,reason)
    state=tostring(state or "native")
    if not NAVIGATION_STATES[state] then state="recovering" end
    local previous=self:_navigation_state()
    if previous~=state then
        NAVIGATION.generation=(tonumber(NAVIGATION.generation) or 0)+1
        NAVIGATION.state=state
        NAVIGATION.changed_at=os.time()
        NAVIGATION.reason=tostring(reason or "state change")
        NAVIGATION.reader_session_generation=tonumber(HOME_SESSION.reader_session_generation) or 0
        HOME_SESSION.navigation_state=state
        HOME_SESSION.navigation_generation=NAVIGATION.generation
        logger.info("[MiuRead][Navigation]",previous,"->",state,
            "generation=",tostring(NAVIGATION.generation),"reason=",NAVIGATION.reason)
    else
        HOME_SESSION.navigation_state=state
        HOME_SESSION.navigation_generation=tonumber(NAVIGATION.generation) or 0
    end
    return tonumber(NAVIGATION.generation) or 0,previous~=state
end

function Plugin:_navigation_token()
    return {
        generation=tonumber(NAVIGATION.generation) or 0,
        state=self:_navigation_state(),
        reader_session_generation=tonumber(HOME_SESSION.reader_session_generation) or 0,
    }
end

function Plugin:_navigation_token_valid(token,allowed_states)
    if type(token)~="table" or tonumber(token.generation)~=(tonumber(NAVIGATION.generation) or 0) then return false end
    if allowed_states==nil then return true end
    local state=self:_navigation_state()
    if type(allowed_states)=="string" then return state==allowed_states end
    if type(allowed_states)=="table" then
        if allowed_states[state]==true then return true end
        for _,value in ipairs(allowed_states) do if state==value then return true end end
    end
    return false
end

function Plugin:_set_foreground(owner)
    local value=tostring(owner or "native")
    if HOME_SESSION.foreground~=value then
        HOME_SESSION.foreground=value
        HOME_SESSION.foreground_changed_at=os.time()
    end
    local state=navigation_state_from_foreground(value)
    if value=="home_pending" and not reader_close_active() then state="recovering" end
    if value=="reader_transition" and not reader_close_active() then state="opening_reader" end
    self:_set_navigation_state(state,"foreground "..value)
    return HOME_SESSION.foreground
end

function Plugin:_page_transition_active()
    return tostring(HOME_SESSION.page_transition_state or "idle")~="idle"
end

function Plugin:_begin_page_transition(kind)
    kind=tostring(kind or "transition")
    HOME_SESSION.page_transition_generation=(tonumber(HOME_SESSION.page_transition_generation) or 0)+1
    HOME_SESSION.page_transition_state=kind
    HOME_SESSION.page_transition_started_clock=monotonic_wall_time()
    HOME_SESSION.page_transition_started_kind=kind
    if kind=="opening_reader" then self:_set_navigation_state("opening_reader","page transition")
    elseif kind=="closing_reader" then self:_set_navigation_state("closing_reader","page transition")
    elseif kind=="native_menu" then self:_set_navigation_state("native_menu","page transition")
    else self:_set_navigation_state("recovering","page transition "..kind) end
    self._page_transition_generation=HOME_SESSION.page_transition_generation
    self._page_transition_state=HOME_SESSION.page_transition_state
    if self._page_transition_release_task then
        UIManager:unschedule(self._page_transition_release_task)
        self._page_transition_release_task=nil
    end
    -- pause() resolves the active descriptor from disk, so this works across
    -- the separate FileManager and ReaderUI plugin instances.
    if self.download_task then self.download_task:pause("page_transition") end
    logger.info("[MiuRead][Transition] begin",HOME_SESSION.page_transition_state,
        "generation=",tostring(HOME_SESSION.page_transition_generation))
    return HOME_SESSION.page_transition_generation
end

function Plugin:_finish_page_transition(delay,reason)
    local generation=tonumber(HOME_SESSION.page_transition_generation) or 0
    local transition_kind=tostring(HOME_SESSION.page_transition_started_kind or HOME_SESSION.page_transition_state or "")
    local transition_started=tonumber(HOME_SESSION.page_transition_started_clock) or 0
    if self._page_transition_release_task then
        UIManager:unschedule(self._page_transition_release_task)
        self._page_transition_release_task=nil
    end
    local task
    task=function()
        if self._page_transition_release_task~=task
            or generation~=(tonumber(HOME_SESSION.page_transition_generation) or 0) then return end
        self._page_transition_release_task=nil
        HOME_SESSION.page_transition_state="idle"
        self._page_transition_state="idle"
        if self.download_task then
            if HomeView.is_shown() and not self:_active_reader_ui() and self:_home_ui_busy() then
                logger.info("[MiuRead][HomePerf] download resume deferred after transition")
                self:_home_resume_visible_work_after_idle()
            else
                self.download_task:resume("page_transition")
            end
        end
        local reason_text=tostring(reason or "surface ready")
        logger.info("[MiuRead][Transition] complete",reason_text,
            "generation=",tostring(generation))
        if transition_kind=="opening_reader" and transition_started>0
            and reason_text:find("reader first page",1,true) then
            local elapsed_ms=math.floor((monotonic_wall_time()-transition_started)*1000+.5)
            logger.info("[MiuRead][Perf] interaction","kind=reader_open","elapsed_ms=",tostring(elapsed_ms))
            self:_record_performance("reader_open",elapsed_ms)
            if self._performance_prompt_pending then self:_schedule_performance_prompt(1.2) end
        end
        if generation==(tonumber(HOME_SESSION.page_transition_generation) or 0) then
            HOME_SESSION.page_transition_started_clock=0
            HOME_SESSION.page_transition_started_kind=nil
        end
    end
    self._page_transition_release_task=task
    UIManager:scheduleIn(math.max(0,tonumber(delay) or 0),task)
    return true
end

function Plugin:_schedule_download_resume_after_wake(delay)
    self._download_resume_generation=(tonumber(self._download_resume_generation) or 0)+1
    local generation=self._download_resume_generation
    if self._download_resume_task then
        UIManager:unschedule(self._download_resume_task)
        self._download_resume_task=nil
    end
    local task
    task=function()
        if self._download_resume_task~=task or generation~=self._download_resume_generation then return end
        self._download_resume_task=nil
        if HOME_SESSION.suspended==true or self._miuread_suspended==true or self:_page_transition_active() then
            self:_schedule_download_resume_after_wake(2.0)
            return
        end
        if self.download_task then self.download_task:on_resume() end
    end
    self._download_resume_task=task
    UIManager:scheduleIn(math.max(.5,tonumber(delay) or 3.5),task)
    return true
end

function Plugin:_ensure_reader_transition_guard(reason)
    if Session.home_exiting() or UIManager._exit_code~=nil or HOME_SESSION.suspended==true then return false end
    if not self:_home_enabled() or not Session.home().reader_origin then return false end
    local reader=self:_active_reader_ui()
    if not reader and self.ui and self.ui.document then reader=self.ui end
    local shown=ReaderTransitionGuard.ensure(reader,reason or "reader session")
    if shown then HOME_SESSION.transition_guard=true end
    return shown
end

function Plugin:_release_reader_transition_guard(reason)
    HOME_SESSION.transition_guard=false
    return ReaderTransitionGuard.close(reason or "surface ready")
end

function Plugin:_close_reader_recovery_surface()
    local dialog=self._reader_recovery_dialog
    self._reader_recovery_dialog=nil
    if dialog and UIManager:isWidgetShown(dialog) then pcall(UIManager.close,UIManager,dialog) end
end

function Plugin:_show_reader_recovery_surface(detail)
    self:_set_navigation_state("recovering","reader recovery surface")
    if self._reader_recovery_dialog and UIManager:isWidgetShown(self._reader_recovery_dialog) then return true end
    local dialog
    local function try_home()
        if dialog and UIManager:isWidgetShown(dialog) then UIManager:close(dialog) end
        self._reader_recovery_dialog=nil
        self:_set_foreground("home_pending")
        self:_restore_home_after_reader_close(1)
    end
    local function try_native()
        if dialog and UIManager:isWidgetShown(dialog) then UIManager:close(dialog) end
        self._reader_recovery_dialog=nil
        if self:_ensure_filemanager_base(Session.home().return_file or Session.home().reader_file) then
            self:_set_foreground("native")
            self:_release_reader_transition_guard("native recovery ready")
            self:_finish_page_transition(0,"native recovery ready")
            UIManager:setDirty("all","full")
        else
            UIManager:scheduleIn(.12,function() self:_show_reader_recovery_surface("KOReader 文件管理器仍未就绪") end)
        end
    end
    dialog=ButtonDialog:new{
        title="页面暂时无法恢复"..((detail and tostring(detail)~="") and ("\n\n"..tostring(detail)) or ""),
        title_align="center",
        buttons={
            {{text="返回觅阅主页",callback=try_home}},
            {{text="打开 KOReader 文件管理器",callback=try_native}},
            {{text="重启 KOReader",callback=function() self:_restart_koreader("reader-recovery") end}},
        },
    }
    dialog._miuread_recovery_surface=true
    self._reader_recovery_dialog=dialog
    UIManager:show(dialog)
    logger.warn("[MiuRead][Reader] recovery surface shown",tostring(detail or "unknown"))
    return true
end

function Plugin:_cancel_reader_close_settle(reason,reset_shared)
    self._reader_close_settle_generation=(tonumber(self._reader_close_settle_generation) or 0)+1
    if self._reader_close_settle_task then
        UIManager:unschedule(self._reader_close_settle_task)
        self._reader_close_settle_task=nil
    end
    if self._reader_close_watch_task then
        UIManager:unschedule(self._reader_close_watch_task)
        self._reader_close_watch_task=nil
    end
    self._reader_return_finish_task=nil
    if READER_CLOSE.state~="idle" then
        READER_CLOSE.watch_token=(tonumber(READER_CLOSE.watch_token) or 0)+1
    end
    if reset_shared==true and READER_CLOSE.state~="idle" then
        READER_CLOSE.generation=(tonumber(READER_CLOSE.generation) or 0)+1
        READER_CLOSE.state="idle"
        READER_CLOSE.session_generation=0
        READER_CLOSE.reader_file=nil
        READER_CLOSE.requested_at=0
        READER_CLOSE.requested_clock=0
        READER_CLOSE.poll_state=nil
        READER_CLOSE.poll_count=0
        READER_CLOSE.close_event_received=false
        READER_CLOSE.native_requested=false
        READER_CLOSE.stable_samples=0
        READER_CLOSE.fallback_attempted=false
        READER_CLOSE.reason=nil
    end
    if reason then logger.info("[MiuRead][ReaderClose] watcher cancelled",tostring(reason)) end
    return true
end

function Plugin:_close_home_for_reader(reason)
    if not self:_home_enabled() then
        self:_set_foreground("reader")
        return true
    end
    self:_home_stop_background(reason or "reader active")
    self:_close_miuread_transients()
    if HomeView.is_shown() then
        HomeView.park()
        self._home_view=HomeView.current()
        logger.info("[MiuRead][Home] parked below reader",tostring(reason or "reader active"))
    end
    if self:_active_reader_ui() or (self.ui and self.ui.document) then
        self:_set_foreground("reader")
    else
        self:_set_foreground("reader_pending")
    end
    return true
end

function Plugin:_reader_close_snapshot()
    local state,reader=self:_reader_lifecycle_state()
    return {
        lifecycle=state,
        reader=reader,
        reader_in_stack=reader and self:_reader_in_window_stack(reader) or false,
        document_present=reader and reader.document~=nil or false,
        filemanager=self:_filemanager_instance(),
        opening=normalized_reader_file(HOME_SESSION.opening_file),
        session_generation=tonumber(HOME_SESSION.reader_session_generation) or 0,
    }
end

function Plugin:_complete_reader_close(generation,reason)
    if generation~=(tonumber(READER_CLOSE.generation) or 0) or READER_CLOSE.state=="idle" then return false end
    local snapshot=self:_reader_close_snapshot()
    -- MiuRead keeps its rendered home parked under ReaderUI. Once ReaderUI has
    -- actually left the stack, that existing home can be restored immediately;
    -- FileManager is no longer a prerequisite for the visible return path.
    if snapshot.lifecycle~="closed" then return false end
    if not snapshot.filemanager and not HomeView.is_shown() then return false end
    READER_CLOSE.state="home_restoring"
    self:_ensure_reader_transition_guard("stable reader close")
    self:_close_miuread_transients()
    self:_set_foreground("home_pending")

    local shown=false
    if HomeView.is_shown() then
        HomeView.unpark(true,{
            on_interaction=function(first,kind) self:_home_note_interaction(first,kind) end,
        })
        HomeView.raise(true)
        UIManager:setDirty(HomeView.current(),"ui")
        shown=true
    else
        shown=self:_show_miuread_home_now(false,false,true)==true
    end
    if not shown then
        READER_CLOSE.state="failed"
        self:_finish_page_transition(0,"home restore failed")
        self:_show_reader_recovery_surface("觅阅主页未能恢复")
        return false
    end

    HOME_SESSION.reader_session_active=false
    HOME_SESSION.return_requested=false
    HOME_SESSION.return_session_generation=0
    HOME_SESSION.return_request_file=nil
    Session.home().reader_origin =false
    Session.home().reader_file =nil
    Session.home().return_file =nil
    self:_set_foreground("home")
    self:_close_reader_recovery_surface()
    self:_release_reader_transition_guard("home restored after stable close")
    self:_home_enter_post_reader_priority_window(4.0,"stable reader close")
    self:_finish_page_transition(.18,"home restored after stable close")
    self:_resume_pending_post_reader_work("home restored after stable close",2.0)
    READER_CLOSE.state="completed"
    logger.info("[MiuRead][ReaderClose] home restored",
        "generation=",tostring(generation),"reason=",tostring(reason or READER_CLOSE.reason or "close"))
    local requested_clock=tonumber(READER_CLOSE.requested_clock) or 0
    if requested_clock>0 then
        local elapsed_ms=math.floor((monotonic_wall_time()-requested_clock)*1000+.5)
        logger.info("[MiuRead][ReaderClosePerf] return complete",
            "elapsed_ms=",tostring(elapsed_ms))
        self:_record_performance("reader_home",elapsed_ms)
        if self._performance_prompt_pending then self:_schedule_performance_prompt(.9) end
    end
    self:_clear_reader_return(generation,"home restored")
    return true
end

function Plugin:_schedule_reader_close_settle(path,session_generation,reason)
    local generation=self:_begin_reader_return(reason or "document closed",path,false,session_generation)
    READER_CLOSE.close_event_received=true
    if READER_CLOSE.state~="native_surface_waiting" then READER_CLOSE.state="document_closed" end
    return self:_schedule_reader_return_finish(generation,.10,reason or "document closed")
end

-- Home rendering stays in main.lua; reader return helpers resume here.

function Plugin:_ensure_filemanager_base(file,opts)
    opts=type(opts)=="table" and opts or {}
    local perf_started=monotonic_wall_time()
    local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
    if not ok or not FileManager then return false end
    if FileManager.instance then
        if opts.conceal_under_home==true and HomeView.is_shown() then
            -- A native base may already have been inserted above the parked
            -- MiuRead root by another plugin instance. Put the existing home
            -- back on top before the UI loop can repaint that native page.
            HomeView.raise(true)
            UIManager:setDirty(HomeView.current(),opts.refresh_kind or "ui")
            logger.info("[MiuRead][Home] existing FileManager concealed below MiuRead home")
        end
        return true
    end
    local target=tostring(file or Session.home().return_file or "")
    local dir=target~="" and target:match("^(.*)/[^/]+$") or nil
    local selected=target~="" and target or nil
    local show_started=monotonic_wall_time()
    local shown,err=xpcall(function() FileManager:showFiles(dir,selected) end,debug.traceback)
    local show_ms=math.floor((monotonic_wall_time()-show_started)*1000+.5)
    if not shown then
        logger.warn("[MiuRead][Home] failed to recreate FileManager base",tostring(err))
        return false
    end
    if not FileManager.instance then
        logger.warn("[MiuRead][Home] FileManager base was not established")
        return false
    end
    if opts.conceal_under_home==true and HomeView.is_shown() then
        -- FileManager:showFiles queues a repaint, but does not need to be the
        -- visible surface. Raise the already-rendered, still-parked MiuRead
        -- home synchronously in the same callback. When UIManager flushes its
        -- dirty queue, the user sees MiuRead directly instead of a one-frame
        -- KOReader file browser flash.
        HomeView.raise(true)
        UIManager:setDirty(HomeView.current(),opts.refresh_kind or "ui")
        logger.info("[MiuRead][Home] FileManager base concealed below MiuRead home")
    end
    logger.info("[MiuRead][Home] FileManager base ready")
    logger.info("[MiuRead][ReaderClosePerf] FileManager base created",
        "show_ms=",tostring(show_ms),
        "total_ms=",tostring(math.floor((monotonic_wall_time()-perf_started)*1000+.5)))
    return true
end

function Plugin:_restore_home_after_reader_close(attempt,generation)
    attempt=tonumber(attempt) or 1
    if generation==nil then
        if HOME_SESSION.home_restore_active==true
            and (tonumber(HOME_SESSION.home_restore_generation) or 0)>0 then return true end
        HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
        HOME_SESSION.home_restore_active=true
        generation=HOME_SESSION.home_restore_generation
        self._home_restore_generation=generation
        if not reader_close_active() then self:_set_navigation_state("recovering","home restore requested") end
    else
        self._home_restore_generation=tonumber(HOME_SESSION.home_restore_generation) or 0
    end
    if generation~=(tonumber(HOME_SESSION.home_restore_generation) or 0) then return false end
    if Session.home().suppressed or Session.home().native_visit or Session.home_exiting() or UIManager._exit_code~=nil
        or HOME_SESSION.suspended==true or self._miuread_suspended==true or not self:_home_enabled() then
        HOME_SESSION.home_restore_active=false
        if HOME_SESSION.suspended~=true and self._miuread_suspended~=true then
            self:_finish_page_transition(.2,"home restore no longer required")
        end
        return false
    end
    if READER_CLOSE.state~="idle" and READER_CLOSE.state~="completed"
        and READER_CLOSE.state~="failed" and READER_CLOSE.state~="home_restoring" then
        HOME_SESSION.home_restore_active=false
        self:_schedule_reader_return_finish(READER_CLOSE.generation,.10,"home restore delegated")
        return false
    end
    local reader_state=self:_reader_lifecycle_state()
    if reader_state~="closed" then
        if attempt<40 then
            UIManager:scheduleIn(.15,function() self:_restore_home_after_reader_close(attempt+1,generation) end)
        else
            HOME_SESSION.home_restore_active=false
            if reader_state=="active" then self:_set_foreground("reader") end
            self:_finish_page_transition(0,"home restore cancelled by reader")
        end
        return false
    end
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local has_base=ok_fm and FileManager and FileManager.instance~=nil
    if HomeView.is_shown() then
        if not has_base and attempt>=25 then
            has_base=self:_ensure_filemanager_base(Session.home().return_file or Session.home().reader_file)==true
        end
        if not has_base then
            if attempt<40 then
                UIManager:scheduleIn(.12,function() self:_restore_home_after_reader_close(attempt+1,generation) end)
            else
                HOME_SESSION.home_restore_active=false
                self:_finish_page_transition(0,"home base recovery required")
                self:_show_reader_recovery_surface("KOReader 文件管理器未能恢复")
            end
            return false
        end
        -- FileManager provides KOReader's docless services and gesture manager,
        -- but it must stay below the MiuRead root. Restore the parked surface
        -- with one bounded UI repaint instead of rebuilding and full-refreshing.
        HomeView.unpark(true,{
            on_interaction=function(first,kind) self:_home_note_interaction(first,kind) end,
        })
        HomeView.raise(true)
        UIManager:setDirty(HomeView.current(),"ui")
        Session.home().reader_origin =false
        Session.home().reader_file =nil
        Session.home().return_file =nil
        self:_set_foreground("home")
        self:_home_schedule_clock()
        self:_close_reader_recovery_surface()
        self:_release_reader_transition_guard("home already visible")
        self:_home_enter_post_reader_priority_window(4.0,"home revealed")
        self:_finish_page_transition(.18,"home revealed")
        self:_resume_pending_post_reader_work("home revealed",2.0)
        HOME_SESSION.home_restore_active=false
        return true
    end

    if not has_base and attempt>=25 then
        has_base=self:_ensure_filemanager_base(Session.home().return_file)==true
    end
    if not has_base then
            if attempt<40 then
                UIManager:scheduleIn(.12,function() self:_restore_home_after_reader_close(attempt+1,generation) end)
            else
                HOME_SESSION.home_restore_active=false
                self:_finish_page_transition(0,"home base recovery required")
                self:_show_reader_recovery_surface("KOReader 文件管理器未能恢复")
            end
            return false
        end

    local shown=self:_show_miuread_home_now(false,false,true)
    if not shown and attempt<2 then
        UIManager:scheduleIn(.12,function() self:_restore_home_after_reader_close(attempt+1,generation) end)
        return false
    end
    if shown then
        Session.home().return_file =nil
        self:_set_foreground("home")
        self:_close_reader_recovery_surface()
        self:_release_reader_transition_guard("home restored")
        self:_home_enter_post_reader_priority_window(4.0,"home rebuilt")
        self:_finish_page_transition(.18,"home rebuilt")
        self:_resume_pending_post_reader_work("home restored",2.0)
    else
        self:_set_navigation_state("recovering","home creation failed")
        self:_finish_page_transition(0,"home creation recovery required")
        self:_show_reader_recovery_surface("觅阅主页未能创建，已保留安全退路")
    end
    HOME_SESSION.home_restore_active=false
    return shown
end

function Plugin:_begin_reader_return(reason,file,request_close,session_generation)
    local expected_session=tonumber(session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0
    local active=READER_CLOSE.state~="idle" and READER_CLOSE.state~="completed" and READER_CLOSE.state~="failed"
    if active and tonumber(READER_CLOSE.session_generation or 0)==expected_session then
        return tonumber(READER_CLOSE.generation) or 0,false
    end
    READER_CLOSE.generation=(tonumber(READER_CLOSE.generation) or 0)+1
    READER_CLOSE.state=request_close==false and "reader_closing" or "close_requested"
    READER_CLOSE.session_generation=expected_session
    READER_CLOSE.reader_file=normalized_reader_file(file) or normalized_reader_file(HOME_SESSION.reader_session_file)
    READER_CLOSE.requested_at=os.time()
    READER_CLOSE.requested_clock=monotonic_wall_time()
    READER_CLOSE.poll_state=nil
    READER_CLOSE.poll_count=0
    READER_CLOSE.close_event_received=false
    READER_CLOSE.native_requested=false
    READER_CLOSE.stable_samples=0
    READER_CLOSE.fallback_attempted=false
    READER_CLOSE.close_attempts=0
    READER_CLOSE.close_command_sent_at=0
    READER_CLOSE.foreground_stop_attempted=false
    READER_CLOSE.native_fallback_attempted=false
    READER_CLOSE.reason=tostring(reason or "return home")
    READER_CLOSE.watch_token=(tonumber(READER_CLOSE.watch_token) or 0)+1

    HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
    HOME_SESSION.home_restore_active=false
    self._reader_return_generation=READER_CLOSE.generation
    self._reader_returning=true
    self._reader_return_started=READER_CLOSE.requested_at
    self._reader_return_reason=READER_CLOSE.reason
    self._reader_return_session_generation=expected_session
    self._home_reader_transition=true
    self:_begin_page_transition("closing_reader")
    self:_ensure_reader_transition_guard("reader close requested")
    HOME_SESSION.return_requested=true
    HOME_SESSION.return_session_generation=expected_session
    HOME_SESSION.return_request_file=READER_CLOSE.reader_file
    local path=READER_CLOSE.reader_file
    Session.home().return_file =path or Session.home().return_file
    if path then mark_reader_origin(path) end
    logger.info("[MiuRead][ReaderClose] requested",
        "generation=",tostring(READER_CLOSE.generation),
        "session=",tostring(expected_session),"reason=",READER_CLOSE.reason)
    return READER_CLOSE.generation,true
end

function Plugin:_clear_reader_return(generation,reason)
    if generation and generation~=(tonumber(READER_CLOSE.generation) or 0) then return false end
    if self._reader_return_finish_task then
        UIManager:unschedule(self._reader_return_finish_task)
        self._reader_return_finish_task=nil
    end
    if self._reader_close_watch_task then
        UIManager:unschedule(self._reader_close_watch_task)
        self._reader_close_watch_task=nil
    end
    self._reader_returning=false
    self._reader_return_started=0
    self._reader_return_reason=nil
    self._home_reader_transition=false
    self._miuread_return_requested=false
    HOME_SESSION.return_requested=false
    HOME_SESSION.return_session_generation=0
    HOME_SESSION.return_request_file=nil
    READER_CLOSE.state="idle"
    READER_CLOSE.session_generation=0
    READER_CLOSE.reader_file=nil
    READER_CLOSE.requested_at=0
    READER_CLOSE.requested_clock=0
    READER_CLOSE.poll_state=nil
    READER_CLOSE.poll_count=0
    READER_CLOSE.close_event_received=false
    READER_CLOSE.native_requested=false
    READER_CLOSE.stable_samples=0
    READER_CLOSE.fallback_attempted=false
    READER_CLOSE.close_attempts=0
    READER_CLOSE.close_command_sent_at=0
    READER_CLOSE.foreground_stop_attempted=false
    READER_CLOSE.native_fallback_attempted=false
    READER_CLOSE.reason=nil
    READER_CLOSE.watch_token=(tonumber(READER_CLOSE.watch_token) or 0)+1
    logger.info("[MiuRead][ReaderClose] state cleared",tostring(reason or "complete"))
    return true
end

local function reader_close_poll_delay(phase,elapsed)
    elapsed=math.max(0,tonumber(elapsed) or 0)
    if phase=="confirm" then return .10 end
    if phase=="opening" then return elapsed<1.5 and .18 or .32 end
    if elapsed<.8 then return .12 end
    if elapsed<2.5 then return .22 end
    if elapsed<5 then return .35 end
    return .55
end

function Plugin:_reader_close_poll_state(state,detail)
    state=tostring(state or "unknown")
    READER_CLOSE.poll_count=(tonumber(READER_CLOSE.poll_count) or 0)+1
    if READER_CLOSE.poll_state==state then return false end
    READER_CLOSE.poll_state=state
    logger.info("[MiuRead][ReaderClose] state",state,tostring(detail or ""),
        "poll=",tostring(READER_CLOSE.poll_count))
    return true
end

function Plugin:_schedule_reader_return_finish(generation,delay,reason)
    if generation~=(tonumber(READER_CLOSE.generation) or 0) or READER_CLOSE.state=="idle" then return false end
    if self._reader_close_watch_task then
        UIManager:unschedule(self._reader_close_watch_task)
        self._reader_close_watch_task=nil
    end
    READER_CLOSE.watch_token=(tonumber(READER_CLOSE.watch_token) or 0)+1
    local watch_token=READER_CLOSE.watch_token
    local task
    task=function()
        if self._reader_close_watch_task~=task
            or generation~=(tonumber(READER_CLOSE.generation) or 0)
            or watch_token~=(tonumber(READER_CLOSE.watch_token) or 0) then return end
        self._reader_close_watch_task=nil
        self:_finish_reader_return(generation,reason)
    end
    self._reader_close_watch_task=task
    self._reader_return_finish_task=task
    UIManager:scheduleIn(math.max(.05,tonumber(delay) or .12),task)
    return true
end

function Plugin:_finish_reader_return(generation,reason)
    if generation~=(tonumber(READER_CLOSE.generation) or 0) or READER_CLOSE.state=="idle" then return false end
    self._reader_return_finish_task=nil
    if HOME_SESSION.suspended==true or self._miuread_suspended==true then
        self:_reader_close_poll_state("suspended","waiting for resume")
        return self:_schedule_reader_return_finish(generation,.6,"waiting after suspend")
    end
    local snapshot=self:_reader_close_snapshot()
    local requested_clock=tonumber(READER_CLOSE.requested_clock) or 0
    if requested_clock<=0 then
        requested_clock=monotonic_wall_time()
        READER_CLOSE.requested_clock=requested_clock
    end
    local elapsed=math.max(0,monotonic_wall_time()-requested_clock)
    local expected=tonumber(READER_CLOSE.session_generation) or 0

    if snapshot.session_generation~=expected and snapshot.lifecycle=="active" then
        logger.info("[MiuRead][ReaderClose] cancelled; new reader session",
            "expected=",tostring(expected),"current=",tostring(snapshot.session_generation))
        self:_clear_reader_return(generation,"new reader session")
        self:_set_foreground("reader")
        self:_finish_page_transition(1.0,"new reader session")
        return false
    end
    if snapshot.opening then
        READER_CLOSE.stable_samples=0
        self:_reader_close_poll_state("opening_another_document",snapshot.opening)
        return self:_schedule_reader_return_finish(generation,reader_close_poll_delay("opening",elapsed),"another document opening")
    end
    if snapshot.lifecycle=="active" then
        READER_CLOSE.state="reader_closing"
        READER_CLOSE.stable_samples=0
        self:_reader_close_poll_state("reader_active","waiting for CloseDocument")
        local attempts=tonumber(READER_CLOSE.close_attempts) or 0
        if elapsed>=.6 and attempts==0 then
            logger.warn("[MiuRead][ReaderClose] close command missing; retrying",
                "generation=",tostring(generation))
            self:_request_reader_close(generation,"watchdog initial")
            return true
        end
        if elapsed>=1.8 and attempts<2 then
            logger.warn("[MiuRead][ReaderClose] close not acknowledged; retrying",
                "generation=",tostring(generation),"attempts=",tostring(attempts))
            self:_close_miuread_transients()
            self:_request_reader_close(generation,"watchdog retry")
            return true
        end
        if elapsed>=5 and READER_CLOSE.foreground_stop_attempted~=true then
            READER_CLOSE.foreground_stop_attempted=true
            local stopped=self.download_task
                and self.download_task:stop_for_foreground("return_home_timeout") or false
            logger.warn("[MiuRead][ReaderClose] foreground recovery requested",
                "generation=",tostring(generation),"download_stopped=",tostring(stopped))
            self:_request_reader_close(generation,"foreground recovery")
            return true
        end
        if elapsed>=8 and READER_CLOSE.native_fallback_attempted~=true then
            READER_CLOSE.native_fallback_attempted=true
            local active=self:_active_reader_ui()
            if active and type(active.showFileManager)=="function" then
                logger.warn("[MiuRead][ReaderClose] using native FileManager fallback",
                    "generation=",tostring(generation))
                local ok_native,err_native=xpcall(function()
                    active:showFileManager(READER_CLOSE.reader_file or Session.home().return_file)
                end,debug.traceback)
                if not ok_native then
                    logger.warn("[MiuRead][ReaderClose] native fallback failed",tostring(err_native))
                end
                self:_schedule_reader_return_finish(generation,.18,"native fallback")
                return true
            end
        end
        if elapsed>=12 then
            logger.warn("[MiuRead][ReaderClose] reader still active after timeout",
                "generation=",tostring(generation))
            self:_clear_reader_return(generation,"reader close timed out")
            self:_set_foreground("reader")
            self:_finish_page_transition(0,"reader close timed out")
            self:info("暂时无法返回主页，请再次点击返回主页。")
            return false
        end
        return self:_schedule_reader_return_finish(generation,reader_close_poll_delay("active",elapsed),"reader active")
    end
    if snapshot.lifecycle=="closing" then
        READER_CLOSE.state="reader_closing"
        READER_CLOSE.stable_samples=0
        self:_reader_close_poll_state("reader_leaving_stack",
            snapshot.document_present and "document still attached" or "document released")
        return self:_schedule_reader_return_finish(generation,reader_close_poll_delay("closing",elapsed),"reader closing")
    end

    if HomeView.is_shown() then
        READER_CLOSE.state="home_restoring"
        READER_CLOSE.stable_samples=1
        self:_reader_close_poll_state("home_surface_ready","restoring parked MiuRead home")
        return self:_complete_reader_close(generation,reason or "parked home ready")
    end

    if snapshot.filemanager then
        READER_CLOSE.state="native_surface_waiting"
        READER_CLOSE.stable_samples=(tonumber(READER_CLOSE.stable_samples) or 0)+1
        self:_reader_close_poll_state("native_surface_ready","confirming stable base")
        if READER_CLOSE.stable_samples>=2 then
            return self:_complete_reader_close(generation,reason)
        end
        return self:_schedule_reader_return_finish(generation,reader_close_poll_delay("confirm",elapsed),"confirm native surface")
    end

    READER_CLOSE.stable_samples=0
    self:_reader_close_poll_state("native_surface_missing","waiting for FileManager")
    -- Once CloseDocument has been acknowledged and ReaderUI has left the
    -- stack, there is no benefit in exposing a blank/native interval for five
    -- seconds. Give KOReader one short tick to create its own FileManager; if
    -- it does not, establish the required native base immediately and keep it
    -- below the already-rendered MiuRead home.
    local can_build_concealed=READER_CLOSE.close_event_received==true and elapsed>=.35
    if (can_build_concealed or elapsed>=1.2) and READER_CLOSE.fallback_attempted~=true then
        READER_CLOSE.fallback_attempted=true
        logger.info("[MiuRead][ReaderClose] creating concealed FileManager base",
            "generation=",tostring(generation),"elapsed=",string.format("%.2f",elapsed))
        local ready=self:_ensure_filemanager_base(
            READER_CLOSE.reader_file or Session.home().return_file or Session.home().reader_file,
            {conceal_under_home=true,refresh_kind="ui"})
        if not ready then
            logger.warn("[MiuRead][ReaderClose] concealed FileManager base failed",
                "generation=",tostring(generation))
        end
        return self:_schedule_reader_return_finish(generation,.10,"concealed FileManager")
    end
    if elapsed>=10 then
        READER_CLOSE.state="failed"
        self:_finish_page_transition(0,"reader close recovery required")
        self:_show_reader_recovery_surface("KOReader 文件管理器未能恢复")
        return false
    end
    return self:_schedule_reader_return_finish(generation,reader_close_poll_delay("missing",elapsed),"waiting for native surface")
end

function Plugin:_request_reader_close(generation,source)
    if generation~=(tonumber(READER_CLOSE.generation) or 0) or READER_CLOSE.state=="idle" then return false end
    local state,active=self:_reader_lifecycle_state()
    if state~="active" or not active or not active.document then
        self:_schedule_reader_return_finish(generation,.10,"reader already closing")
        return false
    end
    READER_CLOSE.close_attempts=(tonumber(READER_CLOSE.close_attempts) or 0)+1
    READER_CLOSE.close_command_sent_at=monotonic_wall_time()
    logger.info("[MiuRead][ReaderClose] close command",
        "generation=",tostring(generation),"attempt=",tostring(READER_CLOSE.close_attempts),
        "source=",tostring(source or "direct"))
    pcall(function() active:handleEvent(Event:new("CloseReaderMenu")) end)
    pcall(function() active:handleEvent(Event:new("CloseConfigMenu")) end)
    local ok_close,err_close=xpcall(function() active:onClose(false) end,debug.traceback)
    if not ok_close then
        logger.warn("[MiuRead][ReaderClose] close request failed",tostring(err_close))
        self:_schedule_reader_return_finish(generation,.18,"close request failed")
        return false
    end
    self:_schedule_reader_return_finish(generation,.10,"close requested")
    return true
end

function Plugin:return_to_miuread_home(reason)
    if Session.home_exiting() or UIManager._exit_code~=nil then return false end
    self:_cancel_native_menu_guard()
    Session.home().suppressed =false
    Session.home().native_visit =false
    Session.home().expected_close =false
    self._miuread_return_requested=true

    self:_ensure_reader_transition_guard("return entry")
    local lifecycle,readerui=self:_reader_lifecycle_state()
    if lifecycle=="active" and readerui then
        local file=self:_reader_file(readerui,Session.home().return_file)
        local generation,started=self:_begin_reader_return(reason or "explicit return",file,true)
        if not started then return true end
        -- The transition and its shared download pause are already active before
        -- closing any transient reader widget. This keeps the action independent
        -- from ReaderToolbar:onCloseWidget and gives foreground navigation priority.
        self:_close_miuread_transients()
        self:_schedule_reader_return_finish(generation,.12,"return requested")
        UIManager:nextTick(function()
            self:_request_reader_close(generation,"next tick")
        end)
        UIManager:scheduleIn(.35,function()
            if generation~=(tonumber(READER_CLOSE.generation) or 0) or READER_CLOSE.state=="idle" then return end
            if (tonumber(READER_CLOSE.close_attempts) or 0)==0 then
                logger.warn("[MiuRead][ReaderClose] deferred close command did not run; retrying",
                    "generation=",tostring(generation))
                self:_request_reader_close(generation,"entry watchdog")
            end
        end)
        return true
    end

    local generation=self:_begin_reader_return(reason or "reader already closing",Session.home().return_file,false)
    self:_close_miuread_transients()
    self:_set_foreground("home_pending")
    self:_schedule_reader_return_finish(generation,.10,"reader already closing")
    return true
end



-- Reader-ready and dimension commits complete the lifecycle controller.

function Plugin:onReaderReady()
    HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
    HOME_SESSION.home_restore_active=false

    local ready_path=normalized_reader_file(self:_current_document_path())
    -- If the same Reader unexpectedly reappears while an explicit Home return
    -- is already in progress, do not cancel that user request. Close the
    -- transiently recreated Reader again and keep the existing close watchdog.
    if reader_close_active() and HOME_SESSION.return_requested==true
        and ready_path and normalized_reader_file(READER_CLOSE.reader_file)==ready_path then
        logger.warn("[MiuRead][Lifecycle] reader reappeared during explicit return",
            "generation=",tostring(READER_CLOSE.generation),"book=",tostring(ready_path))
        READER_CLOSE.state="reader_closing"
        READER_CLOSE.close_event_received=false
        self:_set_foreground("reader_transition")
        self:_ensure_reader_transition_guard("reader reappeared during explicit return")
        self:_schedule_reader_return_finish(READER_CLOSE.generation,.08,"reader reappeared")
        UIManager:nextTick(function()
            if reader_close_active() and HOME_SESSION.return_requested==true then
                self:_request_reader_close(READER_CLOSE.generation,"reappeared during explicit return")
            end
        end)
        return
    end

    local had_candidate,preserve_session=self:_reader_rebuild_ready_state()
    self:_cancel_reader_close_settle("reader ready")
    if READER_CLOSE.state~="idle" then
        self:_clear_reader_return(READER_CLOSE.generation,"reader ready cancelled stale return")
        self:_finish_page_transition(1.0,"reader ready")
    elseif not preserve_session then
        HOME_SESSION.return_requested=false
        HOME_SESSION.return_session_generation=0
        HOME_SESSION.return_request_file=nil
    end
    if not preserve_session then
        HOME_SESSION.reader_session_generation=(tonumber(HOME_SESSION.reader_session_generation) or 0)+1
    end
    HOME_SESSION.reader_session_active=true
    HOME_SESSION.reader_session_file=ready_path
    self._reader_session_generation=HOME_SESSION.reader_session_generation
    local ready_session=self._reader_session_generation
    self._home_reader_transition=false
    self:_close_reader_recovery_surface()
    self:_close_home_for_reader("reader ready")
    self:_ensure_reader_transition_guard("reader ready")
    if self._reader_active_path then U.atomic_write(self._reader_active_path,"1",true) end
    -- Give EPUB opening and the first visible page priority over background
    -- work, but do not keep cloud/state workers blocked for a fixed eight
    -- seconds. Three seconds is enough to protect the first interactions; the
    -- idle gate below keeps extending the delay while the user is active.
    self:_mark_reader_busy(3)
    logger.info("[MiuRead][Sync] reader ready","session=",tostring(self._reader_session_generation or 0),
        "rebuild=",tostring(had_candidate==true),"preserved=",tostring(preserve_session==true))
    -- ReaderUI already paints its first page. Avoid a second forced full-screen
    -- refresh, which was the visible extra flash after opening a book.
    self:_finish_page_transition(1.2,"reader first page")
    UIManager:scheduleIn(.05,function()
        if not (self.ui and self.ui.document)
            or tonumber(HOME_SESSION.reader_session_generation or 0)~=ready_session
            or reader_close_active() then return end
        self:_install_reader_menu_bridge()
        self:_install_reader_quick_panel_zone()
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
        local path=self:_current_document_path()
        local book,record,variant
        if path then
            book,record,variant=self.store:identify_file(path,false)
            self:_record_recent_read(path,book,record)
        end
        if record and (record.annotation_requested==true or tostring(variant or record.variant or ""):find("notes",1,true)) then
            self:_setup_thought_tap()
            logger.info("[MiuRead][ThoughtPopup] local tap ready before cloud sync")
        end
        local pending=HOME_SESSION.pending_annotation_jump
        if type(pending)=="table" then
            local age=os.time()-(tonumber(pending.requested_at) or 0)
            if age<0 or age>45 then
                HOME_SESSION.pending_annotation_jump=nil
            else
                local current_id=book and tostring(book.book_id or book.bookId or "") or ""
                local same_book=current_id~="" and current_id==tostring(pending.book_id or "")
                local same_file=normalized_reader_file(path)==normalized_reader_file(pending.source_path)
                if same_book or same_file then
                    HOME_SESSION.pending_annotation_jump=nil
                    UIManager:scheduleIn(.16,function()
                        if not (self.ui and self.ui.document) or reader_close_active() then return end
                        self:_reader_goto_annotation(pending)
                        if pending.manage==true then
                            UIManager:scheduleIn(.14,function()
                                local item=self:_annotation_find_reader_item(pending)
                                if item then
                                    local kind=self:_reader_annotation_type(item)
                                    self:_show_reader_annotation_actions(item,kind,nil,function()
                                        self:_show_reader_records(self:_reader_annotation_type(item) or kind,function() self:show_reader_quick_panel() end)
                                    end)
                                else
                                    self:toast("已跳到批注位置；当前记录暂时无法直接编辑",2)
                                end
                            end)
                        end
                    end)
                end
            end
        end
    end)
    -- Prime only lightweight page/chapter data. No toolbar widget survives a
    -- close or page turn; every visible panel is created fresh and destroyed.
    ReaderToolbar.invalidate()
    self:_reset_reader_toolbar_state_cache()
    self:_schedule_reader_toolbar_state_refresh(nil,.35)
    self:_schedule_reader_toolbar_prewarm(ready_session,1.1)
    self:_teardown_thought_tap()
    self:_teardown_external_annotations()
    self:_setup_external_annotations()
    self._progress_prompted_book_id=nil
    self._progress_check_running=false
    self._progress_remote_retries={}
    self._sync_success_notified=false
    self._last_progress_submit_notice=nil
    if self._reader_sync_ready_task then
        UIManager:unschedule(self._reader_sync_ready_task)
        self._reader_sync_ready_task=nil
    end
    local task
    task=function()
        if self._reader_sync_ready_task~=task then return end
        if not self:_reader_background_idle() then
            UIManager:scheduleIn(.65,task)
            return
        end
        self._reader_sync_ready_task=nil
        if self.ui and self.ui.document
            and tonumber(HOME_SESSION.reader_session_generation or 0)==ready_session
            and not reader_close_active() then self.sync:on_reader_ready() end
    end
    self._reader_sync_ready_task=task
    -- Let KOReader paint the first page and restore input before identity and
    -- cloud-progress work begins. Local comment taps are already installed by
    -- the next-tick block above, so this does not delay reading interaction.
    UIManager:scheduleIn(.60,task)
    local device_task
    device_task=function()
        if self._miuread_suspended==true or HOME_SESSION.suspended==true then return end
        if not (self.ui and self.ui.document) or reader_close_active()
            or tonumber(HOME_SESSION.reader_session_generation or 0)~=ready_session then return end
        if not self:_reader_background_idle() then UIManager:scheduleIn(.75,device_task); return end
        HomeData.quick_device_state(true)
    end
    UIManager:scheduleIn(1.8,device_task)
    if had_candidate then
        UIManager:scheduleIn(.18,function()
            if self.ui and self.ui.document
                and tonumber(HOME_SESSION.reader_session_generation or 0)==ready_session
                and not reader_close_active() then self:onSetDimensions() end
        end)
    end
end

function Plugin:onSetDimensions()
    local now=monotonic_wall_time()
    HOME_SESSION.last_dimension_event_clock=now
    self._reader_dimension_last_event_clock=now
    self._reader_dimension_event_count=(tonumber(self._reader_dimension_event_count) or 0)+1
    local sw,sh=Device.screen:getWidth(),Device.screen:getHeight()
    local rotation=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil

    if HOME_SESSION.suspended==true or self._miuread_suspended==true then
        READER_REBUILD.pending_width,READER_REBUILD.pending_height=sw,sh
        READER_REBUILD.pending_rotation=rotation
        return true
    end
    if reader_close_active() then
        HOME_SESSION.pending_dimension_width=sw
        HOME_SESSION.pending_dimension_height=sh
        HOME_SESSION.pending_dimension_rotation=rotation
        logger.info("[MiuRead][Rotation] deferred during reader close",
            "state=",tostring(READER_CLOSE.state),"size=",tostring(sw).."x"..tostring(sh))
        return true
    end
    if reader_rebuild_active() then
        READER_REBUILD.pending_width,READER_REBUILD.pending_height=sw,sh
        READER_REBUILD.pending_rotation=rotation
        logger.info("[MiuRead][Rotation] deferred during reader rebuild",
            "size=",tostring(sw).."x"..tostring(sh))
        return true
    end

    if not (self.ui and self.ui.document) then
        -- HomeWidget owns Home geometry. Avoid a second plugin-level rebuild.
        return true
    end

    self:_set_foreground("reader")
    self._reader_dimension_generation=(tonumber(self._reader_dimension_generation) or 0)+1
    local generation=self._reader_dimension_generation
    local event_count=self._reader_dimension_event_count
    if self._reader_dimension_task then
        UIManager:unschedule(self._reader_dimension_task)
        self._reader_dimension_task=nil
    end
    logger.info("[MiuRead][Rotation] event","generation=",tostring(generation),
        "size=",tostring(sw).."x"..tostring(sh),"rotation=",tostring(rotation))

    local last_w,last_h,last_rotation,stable,attempts=nil,nil,nil,0,0
    local task
    task=function()
        if self._reader_dimension_task~=task or generation~=self._reader_dimension_generation then return end
        if HOME_SESSION.suspended==true or self._miuread_suspended==true then
            self._reader_dimension_task=nil
            return
        end
        if reader_close_active() or reader_rebuild_active() then
            self._reader_dimension_task=nil
            HOME_SESSION.pending_dimension_width=Device.screen:getWidth()
            HOME_SESSION.pending_dimension_height=Device.screen:getHeight()
            HOME_SESSION.pending_dimension_rotation=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil
            return
        end
        attempts=attempts+1
        local cw,ch=Device.screen:getWidth(),Device.screen:getHeight()
        local cr=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil
        if cw==last_w and ch==last_h and cr==last_rotation then
            stable=stable+1
        else
            last_w,last_h,last_rotation,stable=cw,ch,cr,0
        end
        if stable<2 and attempts<8 then
            UIManager:scheduleIn(.12,task)
            return
        end
        self._reader_dimension_task=nil
        if not (self.ui and self.ui.document) then return end
        local changed=cw~=self._reader_dimension_width or ch~=self._reader_dimension_height
            or cr~=self._reader_dimension_rotation
        self._reader_dimension_width,self._reader_dimension_height=cw,ch
        self._reader_dimension_rotation=cr
        if changed then
            self:_close_miuread_transients()
            ReaderToolbar.invalidate()
            self:_reset_reader_toolbar_state_cache()
            self:_schedule_reader_toolbar_state_refresh(nil,.10)
            -- Menu method bridges are geometry-independent; only the gesture
            -- zone needs to be rebound after a real size commit.
            self:_install_reader_quick_panel_zone()
            local reader=self:_active_reader_ui()
            UIManager:setDirty(reader or nil,"full")
        end
        logger.info("[MiuRead][Rotation] committed",
            "generation=",tostring(generation),"coalesced=",tostring(math.max(1,(tonumber(self._reader_dimension_event_count) or event_count)-event_count+1)),
            "samples=",tostring(attempts),"changed=",tostring(changed),
            "size=",tostring(cw).."x"..tostring(ch),"rotation=",tostring(cr))
    end
    self._reader_dimension_task=task
    UIManager:scheduleIn(.30,task)
    return true
end

function Plugin:onScreenResize() return self:onSetDimensions() end
function Plugin:onRotation() return self:onSetDimensions() end


local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
