-- MiuRead download controller, split from main.lua.
-- Installs its Plugin methods onto the main Plugin class in the same way
-- plugin_maintenance.lua does. open_file/_open_file_direct/_current_document_path
-- stay in main.lua because they mutate the shared home-session locals there.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local U = require("miuread.util")
local Text = require("miuread.text")
local Http = require("miuread.http")
local TransientGuard = require("miuread.transient_guard")
local Lazy = require("miuread.lazy")
local ActionSheet = Lazy("miuread.action_sheet")
local HomeView = Lazy("miuread.home_view")
local HomeData = require("miuread.home_data")
local DownloadProgress = Lazy("miuread.download_progress")
local DownloadResult = Lazy("miuread.download_result")
local DownloadCoordinator = require("miuread.download_coordinator")
local BookIntegrity = Lazy("miuread.book_integrity")
local EpubInstaller = Lazy("miuread.epub_installer")
local Cookies = require("miuread.cookies")
local Thoughts = require("miuread.thoughts")
local GestureBridge = require("miuread.gesture_bridge")
local RawButtonDialog = require("ui/widget/buttondialog")
local RawConfirmBox = require("ui/widget/confirmbox")
local RawInfoMessage = require("ui/widget/infomessage")
local RawMenu = require("ui/widget/menu")

local ok_socket, socket = pcall(require, "socket")
local function monotonic_wall_time()
    if ok_socket and socket and type(socket.gettime) == "function" then return socket.gettime() end
    return os.time()
end

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ButtonDialog = gesture_aware_class(RawButtonDialog, {_miuread_transient=true, _miuread_modal_surface=true})
local ConfirmBox = gesture_aware_class(RawConfirmBox, {_miuread_transient=true, _miuread_modal_surface=true})
local InfoMessage = gesture_aware_class(RawInfoMessage, {_miuread_transient=true, _miuread_modal_surface=true})
local Menu = gesture_aware_class(RawMenu, {_miuread_transient=true, _miuread_modal_surface=true})

local ThoughtNativePopup = Lazy("miuread.thought_native_popup")
local _ = Text.tr

local Plugin = {}

-- Lazily attach the deep download state/queue coordinator to this plugin
-- instance. The coordinator owns persisted-state and queue invariants.
local function coordinator(self)
    local instance = rawget(self, "_download_coordinator")
    if instance == nil then
        instance = DownloadCoordinator.new(self.store)
        rawset(self, "_download_coordinator", instance)
    end
    return instance
end

function Plugin:_download_preflight(callback)
    local state=HomeData.device_state(true) or {}
    local function check_battery()
        local battery=tonumber(state.battery)
        if self:_notice_enabled("low_battery") and battery and battery<20 and state.charging~=true then
            local dialog
            dialog=ButtonDialog:new{title="当前电量较低。继续下载整本书可能明显缩短使用时间。",title_align="center",buttons={
                {{text="继续下载",callback=function() UIManager:close(dialog); callback() end}},
                {{text="继续并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("low_battery",false); callback() end}},
                {{text="取消",callback=function() UIManager:close(dialog) end}},
            }}
            UIManager:show(dialog)
            return true
        end
        callback()
        return true
    end
    local free=tonumber(state.storage_free)
    if free and free>0 and free<64*1024*1024 then
        self:info("剩余存储空间不足，无法安全开始下载。\n\n请先打开“下载”并进入存储清理。")
        return false
    end
    if self:_notice_enabled("low_storage") and free and free>0 and free<256*1024*1024 then
        local dialog
        dialog=ButtonDialog:new{title="剩余存储空间较少。下载图片或生成 EPUB 后可能无法正常保存。",title_align="center",buttons={
            {{text="继续下载",callback=function() UIManager:close(dialog); check_battery() end}},
            {{text="打开下载管理",callback=function() UIManager:close(dialog); self:show_downloads() end}},
            {{text="继续并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("low_storage",false); check_battery() end}},
        }}
        UIManager:show(dialog)
        return true
    end
    return check_battery()
end

function Plugin:choose_download_mode(b,opt,open_after)
    local dialog
    local function launch(background,defer_until_reader_closed)
        if defer_until_reader_closed==true then
            if dialog then UIManager:close(dialog) end
            self:_queue_download(b,opt,open_after,{defer_until_reader_closed=true,reason="退出阅读后下载"})
            return
        end
        if self._download_launch_pending then
            self:toast("下载操作正在准备，请勿重复点击",2)
            return
        end
        self._download_launch_pending=true
        if dialog then UIManager:close(dialog) end
        self:status_toast("觅阅",tostring(b and b.title or "未命名")..
            (background and "正在准备后台下载" or "正在准备下载"),2)
        UIManager:scheduleIn(.20,function()
            self._download_launch_pending=false
            self:download(b,opt,open_after,nil,background)
        end)
    end
    local function begin_after_preflight(background)
        local active_reader=self:_active_reader_ui()~=nil
        if not active_reader then launch(background); return end
        local preferences=self.store:preferences()
        local policy=tostring(preferences.download_reader_policy or "ask")
        if policy=="allow" or preferences.download_reader_warning==false or not self:_notice_enabled("reader_download") then
            launch(background)
            return
        end
        if policy=="after_reading" then
            launch(true,true)
            return
        end
        if dialog then UIManager:close(dialog) end
        dialog=ButtonDialog:new{title="阅读时下载会增加耗电，并可能导致翻页、评论或菜单响应变慢。",title_align="center",buttons={
            {{text="继续后台下载",callback=function() UIManager:close(dialog); dialog=nil; launch(true) end}},
            {{text="退出阅读后下载",callback=function() UIManager:close(dialog); dialog=nil; launch(true,true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
    end
    local function start(background)
        if dialog then UIManager:close(dialog); dialog=nil end
        self:_download_preflight(function() begin_after_preflight(background) end)
    end
    dialog=ButtonDialog:new{title="下载方式",title_align="center",buttons={
        {{text="后台下载",callback=function() start(true) end}},
        {{text="留在当前页面下载",callback=function() start(false) end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end
function Plugin:choose_download(b,limit,open_after,uid)
    -- Single-version policy: new downloads are always the clean edition.
    -- The legacy "notes" chapter edition is only updated when it is the sole
    -- existing file for that chapter, so old downloads stay readable.
    local annotations=false
    if uid then
        local clean=self.store:chapter_variant(b.bookId,uid,"clean")
        local notes=self.store:chapter_variant(b.bookId,uid,"notes")
        if notes and notes.file and U.file_exists(notes.file)
            and not (clean and clean.file and U.file_exists(clean.file)) then
            annotations=true
        end
    end
    self:choose_download_mode(b,{annotations=annotations,limit=limit,chapter_uid=uid},open_after)
end
function Plugin:_download_summary(rec,opt)
    local preview=tostring(rec and rec.access_scope or "")=="preview" and not (opt and opt.chapter_uid)
    local preview_mode=tostring(rec and rec.preview_mode or "complete")
    local heading=preview and (preview_mode=="info" and "试读信息版生成完成"
        or (preview_mode=="partial" and "部分试读版生成完成" or "试读版生成完成")) or "下载完成"
    local lines={heading}
    local annotation_note=DownloadResult.summary_note(rec)
    if annotation_note then lines[#lines+1]=annotation_note end
    lines[#lines+1]="保存位置："..tostring(rec.file or "")
    lines[#lines+1]="打开一次后会出现在 KOReader 最近阅读中"
    if rec and rec.partial_range==true then
        lines[#lines+1]="章节版不会上传整书阅读进度，避免局部比例覆盖云端位置。"
    end
    if preview and preview_mode=="info" then lines[#lines+1]="本文件只包含书籍信息和权限说明。" end
    return table.concat(lines,"\n")
end

function Plugin:_refresh_local_files()
    local ui=self.ui
    if not ui then return end
    local chooser=ui.file_chooser
    if chooser then
        if type(chooser.refreshPath)=="function" then pcall(chooser.refreshPath,chooser)
        elseif type(chooser.refresh)=="function" then pcall(chooser.refresh,chooser) end
    end
    if type(ui.onRefresh)=="function" then pcall(ui.onRefresh,ui) end
end
function Plugin:_update_open_shelf_download_status(book_id,status)
    local view=self._shelf_view
    if not view or view._miu_closed or type(view.item_table)~="table" then return false end
    local changed=false
    for _,entry in ipairs(view.item_table) do
        if tostring(entry.book_id or "")==tostring(book_id or "") then
            entry.status=tostring(status or "")
            changed=true
        end
    end
    if changed and type(view.updateItems)=="function" then pcall(view.updateItems,view,nil,true) end
    return changed
end
local DOWNLOAD_STAGE_LABELS={
    prepare="准备下载",catalog="读取目录",resume="恢复断点",content="下载正文",
    underlines="获取划线",thoughts="获取想法",footnotes="处理脚注",
    images="处理图片",package="生成 EPUB",restart="断点恢复",waiting_network="等待网络",done="下载完成",error="下载失败",
    cancelled="下载已取消",
}
function Plugin:_download_dialog_is_shown(runtime)
    runtime=runtime or self._download_runtime
    local dialog=runtime and runtime.dialog or nil
    if not dialog then return false end
    local ok,shown=pcall(UIManager.isWidgetShown,UIManager,dialog)
    if ok and shown==true then return true end
    -- The widget may have been retired by a reader transition, suspend, resize
    -- or generic transient cleanup. A stale Lua reference must never be treated
    -- as a visible progress surface.
    if runtime.dialog==dialog then runtime.dialog=nil end
    logger.info("[MiuRead][DownloadUI] stale dialog reference cleared",
        "background=",tostring(runtime.background==true))
    return false
end
function Plugin:_on_download_progress(runtime,state)
    if self._download_runtime~=runtime then return end
    runtime.last_state=U.copy(state or {})
    runtime.task=self.download_task and self.download_task:descriptor() or runtime.task
    if self:_download_dialog_is_shown(runtime) then
        runtime.dialog:set_state(state)
    end
    if state and state.network_ipv4_suggested==true
        and state.stage~="package" and state.stage~="done" and state.stage~="error"
        and state.stage~="cancelled" then
        self:_show_download_ipv4_suggestion(runtime,state)
    end
    self:_write_download_state("active",self:_active_download_payload(runtime,state),false)
    local home_percent=self:_download_percent(state)
    local home_mark=math.floor(home_percent/5)*5
    if runtime.home_progress_mark~=home_mark then
        runtime.home_progress_mark=home_mark
        self:_home_update_download_card(runtime,state)
    end
    if state and state.stage=="rate_limit" then
        local wait=tonumber(state.wait_seconds) or 0
        self:_update_open_shelf_download_status(runtime.book.bookId,
            wait>0 and ("请求受限 · "..tostring(wait).."秒") or "请求受限 · 等待恢复")
    elseif state and state.stage=="restart" then
        self:_update_open_shelf_download_status(runtime.book.bookId,"从断点自动恢复")
    elseif state and (state.waiting_network==true or state.stage=="waiting_network") then
        self:_update_open_shelf_download_status(runtime.book.bookId,"等待网络 · 已保存进度")
    end
    if runtime.background and self.store:preferences().download_notice_enabled~=false then
        runtime.notified_milestones=runtime.notified_milestones or {}
        local percent=self:_download_percent(state)
        for _,mark in ipairs({25,50,75}) do
            if percent>=mark and not runtime.notified_milestones[mark] then
                runtime.notified_milestones[mark]=true
                self:_update_open_shelf_download_status(runtime.book.bookId,"生成中 "..tostring(mark).."%")
                self:status_toast("后台下载",tostring(runtime.book.title or "未命名").." · "..tostring(mark).."%",3)
            end
        end
    end
end
function Plugin:_finish_download_runtime(runtime,result)
    if self._download_runtime~=runtime then return end
    local b=runtime.book or {}
    local opt=runtime.options or {}
    local done=runtime.done
    local open_after=runtime.open_after==true
    local was_background=runtime.background==true
    self:_close_download_dialog("finished")
    if self.download_task then self.download_task:set_backgrounded(false) end
    self._download_runtime=nil
    if not result or result.ok~=true then
        local err=result and result.error or "未知下载错误"
        logger.warn("[MiuRead][Download] failed",tostring(err))
        if tostring(err)=="下载已取消" then
            self.store:clear_download_state()
            self:_update_open_shelf_download_status(b.bookId,"生成已取消")
            self:_notify_home_data_changed("content")
            if was_background then self:status_toast("觅阅","下载已取消",3) else self:toast("下载已取消",3) end
            self:_start_next_queued_download()
            return
        end
        local auth_required=Http.is_auth_error(err)
        local rate_limited=Http.is_rate_limit_error(err)
        local network_failed=Http.is_network_error and Http.is_network_error(err)
        local content_pending=tostring(err):find("[MiuReadAnnotationPending]",1,true)~=nil
        local image_missing=tostring(err):find("[MiuReadImageMissing]",1,true)~=nil
            or tostring(err):find("[MiuReadImageExternal]",1,true)~=nil
        local validation_failed=tostring(err):find("EPUB 完整性验证失败",1,true)~=nil
        local wait_seconds=tonumber(tostring(err):match("wait_seconds=(%d+)"))
        if auth_required then self:_mark_auth_problem("download",err,true) end
        self:_write_download_state("failed",{
            title=b.title,book_id=b.bookId,book=U.copy(b),options=U.copy(opt),
            error=tostring(err),stage=runtime.last_state and runtime.last_state.stage,
            current=runtime.last_state and runtime.last_state.current,total=runtime.last_state and runtime.last_state.total,
            percent=runtime.last_state and runtime.last_state.percent,seen=false,
            auth_required=auth_required or nil,
            error_kind=auth_required and "authentication" or (rate_limited and "rate_limit"
                or (network_failed and "network" or (image_missing and "image_missing"
                or (content_pending and "content_pending" or (validation_failed and "validation" or nil))))),
            wait_seconds=rate_limited and wait_seconds or nil,
        },true)
        self:_update_open_shelf_download_status(b.bookId,
            auth_required and "等待重新登录" or (rate_limited and "请求受限 · 稍后继续"
                or (network_failed and "等待网络 · 可继续"
                or (image_missing and "正文图片待修复 · 断点已保留" or "生成未完成"))))
        self:_notify_home_data_changed("content")
        local first
        if auth_required then
            first="微信读书登录已失效。下载断点已经保留，请重新扫码登录后继续。"
        elseif rate_limited then
            first="微信读书暂时限制了请求频率。插件已停止继续请求，正文和断点均已保留，请稍后继续下载。"
        elseif network_failed then
            first="网络连接暂时中断。已完成章节和下载断点均已保留，网络恢复后可继续下载。"
        elseif image_missing then
            first="书籍正文图片仍有缺失。已完成章节和下载断点均已保留，可在“修复书籍”中只补缺失内容；原文件没有被覆盖。"
        elseif content_pending then
            first="生成未完成，原文件和下载进度已保留。请稍后使用“生成／更新书籍”重试。"
        elseif validation_failed then
            first="生成的书籍校验未通过，原文件和下载进度已保留。请重试；若仍失败，请反馈日志。"
        else
            first=U.first_line(err)
        end
        if was_background then
            local toast_title=auth_required and "下载登录验证失败" or (rate_limited and "请求受限"
                or (network_failed and "等待网络" or (image_missing and "书籍图片待修复" or "觅阅")))
            local toast_text=auth_required and "后台下载已暂停，重新扫码后自动继续"
                or (rate_limited and "已停止继续请求，下载断点已保留"
                or (network_failed and "下载断点已保留，网络恢复后可继续"
                or (image_missing and "已完成内容和断点已保留，可用修复书籍继续"
                or (content_pending and "生成未完成，原文件和进度已保留"
                or (tostring(b.title or "未命名").."下载未完成，进度已保留")))))
            self:status_toast(toast_title,toast_text,5)
        else self:info(first) end
        -- Any failed book pauses the single waiting task. The user decides whether
        -- to retry the current book or skip it, avoiding repeated requests after an
        -- account, network, validation or content problem.
        if #self.store:download_queue()>0 then
            self:status_toast("下载队列","等待任务已暂停，请先处理当前失败任务",5)
        end
        return
    end
    self:_mark_auth_channel_ok("download")
    local rec=self:_merge_download_result(result,b,opt)
    -- A regenerated clean edition gets a new document layout. Any overlay
    -- records keyed to the old file must not be projected onto the new one;
    -- the dynamic per-chapter pull rebuilds them as the reader advances.
    if opt.annotations~=true and rec.file and self.external_annotations_db then
        pcall(self.external_annotations_db.clearDocument,self.external_annotations_db,rec.file)
    end
    if opt.annotations==true then
        if rec.annotation_pending==true then
            local kind=tostring(rec.annotation_error_kind or ((rec.annotation_summary or {}).error_kind) or "incomplete")
            local errors=type(rec.annotation_summary)=="table" and rec.annotation_summary.errors or nil
            local detail="划线与想法未完整获取"
            if type(errors)=="table" and #errors>0 then
                local first=errors[1]
                detail=type(first)=="table" and tostring(first.error or detail) or tostring(first or detail)
            end
            if kind=="forbidden" then
                self:_mark_auth_access_denied("annotations",detail,true)
            elseif kind=="authentication" then
                self:_mark_auth_problem("annotations",detail,true)
            elseif DownloadResult.annotation_pending(rec) then
                self:_mark_auth_channel_error("annotations",detail)
            else
                -- Data-specific annotation failures are preserved as unresolved
                -- items but do not mean the annotation endpoint itself is down.
                self:_mark_auth_channel_ok("annotations")
            end
        else
            self:_mark_auth_channel_ok("annotations")
        end
    end
    if rec.pending_install and tostring(self:_current_document_path() or "")~=tostring(rec.file or "") then
        self:_install_pending_downloads(false)
        self.store:reload()
        local kind=rec.variant or (opt.annotations and "notes" or "clean")
        local refreshed=opt.chapter_uid and self.store:chapter_variant(b.bookId,opt.chapter_uid,kind)
            or self.store:variant(b.bookId,kind)
        if refreshed then rec=U.copy(refreshed) end
    end
    self:_refresh_local_files()
    local pending=rec.pending_install==true and rec.pending_file and U.file_exists(rec.pending_file)
    local annotation_pending=DownloadResult.annotation_pending(rec)
    local annotation_fallback=DownloadResult.annotation_fallback(rec)
    self:_update_open_shelf_download_status(b.bookId,DownloadResult.shelf_status(rec,pending))
    if pending or annotation_pending then
        self:_write_download_state(DownloadResult.state(rec,pending),{
            title=b.title,book_id=b.bookId,book=U.copy(b),options=U.copy(opt),file=rec.file,
            pending_file=pending and rec.pending_file or nil,pending_install=pending or nil,percent=1,
            current=rec.chapter_count,total=rec.expected_chapter_count,completed_at=os.time(),
            annotation_pending=annotation_pending or nil,
            annotation_fallback=annotation_fallback or nil,
            annotation_error_kind=rec.annotation_error_kind,
        },true)
    else
        self.store:clear_download_state()
    end
    self:_notify_home_data_changed("content")
    if done then done(rec,was_background); self:_start_next_queued_download(); return end
    if pending then
        local text=DownloadResult.notice(b.title,rec,true)
        if was_background then self:status_toast("觅阅",text,5) else self:info(text) end
    elseif was_background then
        if self.store:preferences().download_complete_notice~=false or annotation_pending or annotation_fallback then
            self:status_toast("觅阅",DownloadResult.notice(b.title,rec,false),5)
        end
    elseif open_after and rec.file then
        if not annotation_pending then self.store:clear_download_state() end
        self:open_file(rec.file)
    else
        self:_show_download_complete(rec,opt,b)
    end
    self:_start_next_queued_download()
end
function Plugin:_recover_download_state()
    local state=self.store:download_state()
    if state.status~="active" then return false end
    local runtime={
        book=U.copy(state.book or {bookId=state.book_id,title=state.title}),
        options=U.copy(state.options or {}),
        last_state={stage=state.stage,current=state.current,total=state.total,percent=state.percent,
            chapter=state.chapter,message=state.message},
        background=true,dialog=nil,started_at=state.started_at,task=U.copy(state.task),
        open_after=false,done=nil,recovered=true,
    }
    if type(runtime.task)=="table" then
        self._download_runtime=runtime
        local ok,err=self.download_task:attach(runtime.task,
            function(progress) self:_on_download_progress(runtime,progress) end,
            function(result) self:_finish_download_runtime(runtime,result) end,
            runtime.book,runtime.options)
        if ok then
            runtime.task=self.download_task:descriptor() or runtime.task
            self.download_task:set_backgrounded(true)
            self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
            logger.info("[MiuRead][Download] active task recovered","pid=",tostring(runtime.task.pid),
                "book=",tostring(runtime.book.bookId or ""))
            return true
        end
        self._download_runtime=nil
        logger.warn("[MiuRead][Download] active task recovery failed",tostring(err))
    end
    state.status="interrupted"
    state.error="上次下载已停止，已完成内容仍保存在断点缓存；再次下载时会继续。"
    state.updated_at=os.time()
    self.store:save_download_state(state)
    return false
end
function Plugin:_download_percent(state)
    return coordinator(self):percent(state)
end
function Plugin:_download_state()
    return coordinator(self):active_state(self._download_runtime,
        self.download_task and self.download_task:busy())
end
function Plugin:_has_download_status()
    return coordinator(self):has_status(self.download_task and self.download_task:busy())
end
function Plugin:_download_status_label()
    return coordinator(self):status_label(self._download_runtime,
        self.download_task and self.download_task:busy())
end
function Plugin:_write_download_state(status,patch,force)
    return coordinator(self):write_state(status,patch,force)
end
function Plugin:_active_download_payload(runtime,state)
    local task_descriptor = self.download_task and self.download_task:descriptor()
    return coordinator(self):active_payload(runtime,state,task_descriptor)
end
function Plugin:_close_download_dialog(reason)
    local runtime=self._download_runtime
    if not runtime or not runtime.dialog then return false end
    local dialog=runtime.dialog
    runtime.dialog=nil
    local shown=false
    local ok_shown,value=pcall(UIManager.isWidgetShown,UIManager,dialog)
    if ok_shown then shown=value==true end
    local ok,err=true,nil
    if shown then
        ok,err=pcall(dialog.close,dialog,reason or "programmatic")
        if not ok then
            logger.warn("[MiuRead][DownloadUI] dialog close failed",tostring(err))
            ok,err=pcall(UIManager.close,UIManager,dialog,"ui")
        end
    end
    logger.info("[MiuRead][DownloadUI] dialog retired",
        "reason=",tostring(reason or "programmatic"),
        "shown=",tostring(shown),"ok=",tostring(ok))
    return ok
end
function Plugin:_send_download_to_background()
    local runtime=self._download_runtime
    if not runtime or not self.download_task or not self.download_task:busy() then return end
    runtime.background=true
    if self.download_task then self.download_task:set_backgrounded(true) end
    self:_close_download_dialog("background")
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    self:status_toast("觅阅",tostring(runtime.book.title or "未命名").."已转入后台下载",3)
end
function Plugin:_show_active_download_dialog()
    local runtime=self._download_runtime
    if not runtime or not self.download_task or not self.download_task:busy() then self:show_download_status(); return end

    -- A non-nil reference is not proof that KOReader still shows the widget.
    -- If it is genuinely visible, keep the single instance and just make sure
    -- no newer MiuRead modal is covering it. Otherwise discard the stale ref.
    if self:_download_dialog_is_shown(runtime) then
        TransientGuard.close_all(runtime.dialog)
        UIManager:setDirty(runtime.dialog,"ui")
        logger.info("[MiuRead][DownloadUI] existing dialog reused")
        return
    end

    TransientGuard.close_all()
    local orphan_count=DownloadProgress.close_orphans and DownloadProgress.close_orphans() or 0
    if orphan_count>0 then
        logger.warn("[MiuRead][DownloadUI] orphan surfaces removed",tostring(orphan_count))
    end

    local dialog
    dialog=DownloadProgress:new{
        title="正在下载《"..tostring(runtime.book.title or "未命名").."》",
        on_cancel=function() if self.download_task then self.download_task:cancel() end end,
        on_background=function() self:_send_download_to_background() end,
        on_close=function(widget,reason)
            if self._download_runtime~=runtime then return end
            if runtime.dialog==widget then runtime.dialog=nil end
            local busy=self.download_task and self.download_task:busy() or false
            if busy and runtime.background~=true and reason~="finished" and reason~="cancelled" then
                -- Any external retirement (reader transition, suspend, resize,
                -- another MiuRead modal) means the task continues in background.
                runtime.background=true
                if self.download_task then self.download_task:set_backgrounded(true) end
                self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
            end
            logger.info("[MiuRead][DownloadUI] closed",
                "reason=",tostring(reason),"busy=",tostring(busy),
                "background=",tostring(runtime.background==true))
        end,
    }
    runtime.dialog=dialog
    local shown=dialog:show()==true
    if not shown then
        if runtime.dialog==dialog then runtime.dialog=nil end
        runtime.background=true
        self.download_task:set_backgrounded(true)
        logger.warn("[MiuRead][DownloadUI] show failed; task kept in background")
        self:status_toast("下载","进度窗口未能打开，下载仍在后台继续",3)
        return
    end
    runtime.background=false
    self.download_task:set_backgrounded(false)
    if runtime.last_state then dialog:set_state(runtime.last_state) end
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    logger.info("[MiuRead][DownloadUI] shown",
        "book=",tostring(runtime.book and runtime.book.bookId or ""),
        "percent=",tostring(self:_download_percent(runtime.last_state)))
end
function Plugin:_merge_download_result(result,book,opt)
    self.store:reload()
    if type(result.auth)=="table" then
        local current=self.store:auth()
        local current_account=type(current.account)=="table" and current.account or {}
        local child_account=type(result.auth.account)=="table" and result.auth.account or {}
        local snapshot=type(result.auth_snapshot)=="table" and result.auth_snapshot or {}
        local snapshot_session=tostring(snapshot.login_session_id or "")
        local snapshot_vid=tostring(snapshot.vid or child_account.vid or "")
        local snapshot_logged=tonumber(snapshot.logged_at or child_account.logged_at or 0) or 0
        local same_login=snapshot_session~=""
            and snapshot_session==tostring(current.login_session_id or "")
            and snapshot_vid~=""
            and snapshot_vid==tostring(current_account.vid or "")
        if same_login then
            local merged_cookies=U.copy(current.cookies or {})
            local core={wr_vid=true,wr_skey=true,wr_rt=true}
            local child_ticket_time=tonumber(result.auth.ticket_updated_at or 0) or 0
            local current_ticket_time=tonumber(current.ticket_updated_at or 0) or 0
            for name,value in pairs(result.auth.cookies or {}) do
                if not core[name] or child_ticket_time>=current_ticket_time then
                    merged_cookies[name]=value
                end
            end
            merged_cookies=Cookies.sanitize(merged_cookies)
            current.cookies=merged_cookies
            if tostring(result.auth.api_key or "")~="" then current.api_key=result.auth.api_key end
            if child_ticket_time>=current_ticket_time then
                if tostring(result.auth.wr_ticket or "")~="" then current.wr_ticket=result.auth.wr_ticket end
                if tostring(result.auth.wr_wrpa or "")~="" then current.wr_wrpa=result.auth.wr_wrpa end
                if child_ticket_time>current_ticket_time then current.ticket_updated_at=child_ticket_time end
            end
            self.store:save_auth(current)
        else
            logger.warn("[MiuRead][Download] child authentication merge skipped",
                "snapshot_session=",snapshot_session,
                "current_session=",tostring(current.login_session_id or ""),
                "snapshot_vid=",snapshot_vid,
                "current_vid=",tostring(current_account.vid or ""),
                "snapshot_logged_at=",tostring(snapshot_logged),
                "current_logged_at=",tostring(current_account.logged_at or 0))
        end
    end

    local rec=result.value or {}
    local kind=rec.variant or (opt.annotations and "notes" or "clean")
    if opt.chapter_uid then self.store:save_chapter_variant(book.bookId,opt.chapter_uid,kind,rec)
    else self.store:save_variant(book.bookId,kind,rec) end
    if rec.pending_install==true and rec.pending_file then
        self.store:add_pending_install(book.bookId,kind,opt.chapter_uid,rec)
    else
        self.store:remove_pending_install(book.bookId,kind,opt.chapter_uid)
    end
    local existing_book=self.store:book(book.bookId)
    local preserve_catalog=opt.chapter_uid~=nil or rec.partial_range==true
    local catalog=preserve_catalog and existing_book and existing_book.catalog or rec.chapter_map
    self.store:save_book(book.bookId,{
        book_id=tostring(book.bookId),title=book.title,author=book.author,cover=book.cover,
        directory=rec.directory,updated_at=os.time(),catalog=catalog,access=nil,
        content_type=book.content_type,
    })
    if type(self.store.clear_book_access)=="function" then self.store:clear_book_access(book.bookId) end
    self.access:unlock_book(book.bookId)

    if type(result.session)=="table" then
        local allowed={"psvts","pclts","token","reader_url","chapters","context_updated_at","app_id"}
        local patch={}
        for _,key in ipairs(allowed) do if result.session[key]~=nil then patch[key]=result.session[key] end end
        if next(patch) then self.store:save_session(book.bookId,patch) end
    end
    return rec
end
function Plugin:_show_download_complete(rec,opt,book)
    local dialog
    local buttons={
        {{text="立即阅读",callback=function() UIManager:close(dialog); self:open_file(rec.file) end}},
    }
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=self:_download_summary(rec,opt),title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:show_download_status()
    if self.download_task and self.download_task:busy() then self:_show_active_download_dialog(); return end
    local state=self.store:download_state()
    if not state.status or state.status=="" then self:info("当前没有后台下载记录。") return end
    if state.status=="completed" then
        self.store:clear_download_state()
        self:info("下载已经完成，记录已自动清除。\n\n可在下载管理的已完成列表中打开书籍。")
        return
    end
    local title=tostring(state.title or "未命名")
    local lines={}
    if state.status=="completed" then lines[#lines+1]="下载完成"
    elseif state.status=="annotation_pending" then lines[#lines+1]="正文已生成，划线与想法待补全"
    elseif state.status=="pending_install" then
        if state.annotation_pending==true then lines[#lines+1]="新版本已下载完成"
        elseif state.annotation_fallback==true then lines[#lines+1]="新版本已下载完成"
        else lines[#lines+1]="新版本已下载完成" end
    elseif state.status=="failed" and state.auth_required==true then lines[#lines+1]="等待重新登录"
    elseif state.status=="failed" and state.error_kind=="rate_limit" then lines[#lines+1]="请求频率受限，稍后可继续"
    elseif state.status=="failed" and state.error_kind=="network" then lines[#lines+1]="网络中断，断点已保留"
    elseif state.status=="failed" and state.error_kind=="image_missing" then lines[#lines+1]="正文图片未完整，断点可修复"
    elseif state.status=="failed" then lines[#lines+1]="下载未完成"
    elseif state.status=="interrupted" then lines[#lines+1]="上次下载已中断"
    else lines[#lines+1]=tostring(state.status) end
    lines[#lines+1]="《"..title.."》"
    if state.current and state.total and tonumber(state.total)>0 then lines[#lines+1]="章节 "..tostring(state.current).." / "..tostring(state.total) end
    if state.error and state.error~="" then lines[#lines+1]="\n"..U.first_line(state.error) end
    if state.status=="pending_install" then lines[#lines+1]="\n关闭当前书籍后会自动安装新版本。" end
    local buttons={}
    local dialog
    if (state.status=="completed" or state.status=="annotation_pending") and state.file and U.file_exists(state.file) then
        buttons[#buttons+1]={{text="立即阅读",callback=function()
            UIManager:close(dialog)
            if state.status~="annotation_pending" then self.store:clear_download_state() end
            self:open_file(state.file)
        end}}
    end
    if state.status=="annotation_pending" and type(state.book)=="table" then
        buttons[#buttons+1]={{text="重新生成",callback=function()
            UIManager:close(dialog)
            self:choose_download(state.book,nil,false)
        end}}
    elseif state.status=="failed" and state.auth_required==true then
        buttons[#buttons+1]={{text="重新扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}}
    elseif state.status=="failed" and state.error_kind=="image_missing" and type(state.book)=="table" then
        buttons[#buttons+1]={{text="修复书籍",callback=function()
            UIManager:close(dialog); self:_repair_downloaded_book(state.book_id or state.book)
        end}}
    elseif (state.status=="failed" or state.status=="interrupted") and type(state.book)=="table" then
        buttons[#buttons+1]={{text="继续下载",callback=function() UIManager:close(dialog); self:download(state.book,state.options or {},false) end}}
    end
    if (state.status=="failed" or state.status=="interrupted") and #self.store:download_queue()>0 then
        buttons[#buttons+1]={{text="跳过并开始等待书籍",callback=function()
            UIManager:close(dialog); self.store:clear_download_state(); self:_start_next_queued_download()
        end}}
        buttons[#buttons+1]={{text="停止全部下载",callback=function()
            UIManager:close(dialog); self.store:clear_download_state(); self.store:save_download_queue({}); self:toast("下载任务已全部停止")
        end}}
    end
    buttons[#buttons+1]={{text="清除记录",callback=function() UIManager:close(dialog); self.store:clear_download_state() end}}
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=table.concat(lines,"\n"),title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:_install_pending_record(book_id,kind,chapter_uid,record)
    local pending=tostring(record and record.pending_file or "")
    local target=tostring(record and record.file or "")
    if pending=="" or target=="" or not U.file_exists(pending) then return false,"等待安装文件不存在" end
    local validation={book_id=book_id,variant=record.variant or kind,chapters=record.chapter_map,
        previous_chapters=record.previous_chapter_map}
    local ok,mode_or_error=EpubInstaller.install(pending,target,validation)
    if not ok then return false,"无法安装新 EPUB："..tostring(mode_or_error) end
    local updated=U.copy(record)
    updated.pending_file=nil
    updated.pending_install=nil
    updated.previous_chapter_map=nil
    updated.installed_at=os.time()
    updated.file_size=U.file_size(target)
    if chapter_uid then self.store:save_chapter_variant(book_id,chapter_uid,kind,updated)
    else self.store:save_variant(book_id,kind,updated) end
    self.store:remove_pending_install(book_id,kind,chapter_uid)
    return true,updated
end

function Plugin:_install_pending_downloads(notify)
    -- Most reader closes have nothing to install. Avoid a full settings reload,
    -- integrity check and backup cycle on that hot path. A freshly opened Store
    -- already reflects disk state; download completion also updates this Store
    -- before requesting installation.
    local cached_pending=self.store:pending_installs()
    if type(cached_pending)~="table" or #cached_pending==0 then return false end

    local perf_started=monotonic_wall_time()
    local current=tostring(self:_current_document_path() or "")
    local reload_started=monotonic_wall_time()
    self.store:reload()
    local reload_ms=math.floor((monotonic_wall_time()-reload_started)*1000+.5)
    local prune_started=monotonic_wall_time()
    local pending=self.store:prune_pending_installs()
    local prune_ms=math.floor((monotonic_wall_time()-prune_started)*1000+.5)
    if #pending==0 then
        logger.info("[MiuRead][Download] pending install check",
            "pending=0","reload_ms=",tostring(reload_ms),"prune_ms=",tostring(prune_ms))
        return false
    end
    local installed_records={}
    for _,item in ipairs(pending) do
        local book_id=tostring(item.book_id or "")
        local kind=tostring(item.kind or "")
        local chapter_uid=item.chapter_uid and tostring(item.chapter_uid) or nil
        local book=self.store:book(book_id)
        local record
        if chapter_uid then
            local row=book and book.chapters and book.chapters[chapter_uid]
            record=row and row[kind]
        else
            record=book and book.variants and book.variants[kind]
        end
        if not record or record.pending_install~=true or not U.file_exists(record.pending_file) then
            self.store:remove_pending_install(book_id,kind,chapter_uid)
        elseif tostring(record.file or "")~=current then
            local ok,value=self:_install_pending_record(book_id,kind,chapter_uid,record)
            if ok then
                value.book_id=value.book_id or book_id
                value._kind=kind
                value._chapter_uid=chapter_uid
                installed_records[#installed_records+1]=value
            else
                logger.warn("[MiuRead][Download] pending install failed",tostring(value))
            end
        end
    end
    local installed=#installed_records
    if installed>0 then
        local remaining=self.store:prune_pending_installs()
        local state=self.store:download_state()
        local aggregate=DownloadResult.aggregate(installed_records)
        local any_pending=aggregate.annotation_pending==true
        local any_fallback=aggregate.annotation_fallback==true
        local pending_record,last_record=nil,installed_records[#installed_records]
        for _,record in ipairs(installed_records) do
            if DownloadResult.annotation_pending(record) and not pending_record then pending_record=record end
        end
        if #remaining==0 then
            state.status=any_pending and "annotation_pending" or "completed"
            state.annotation_pending=any_pending or nil
            state.annotation_fallback=any_fallback or nil
            state.annotation_error_kind=pending_record and pending_record.annotation_error_kind or nil
            state.pending_install=nil
            state.pending_file=nil
            state.seen=false
            if installed==1 then
                local record=installed_records[1]
                state.file=record.file
                state.book_id=record.book_id
                local stored=self.store:book(record.book_id)
                state.title=stored and stored.title or record.title
                state.book=stored and {bookId=record.book_id,title=stored.title,author=stored.author,cover=stored.cover} or nil
                state.options=self:_annotation_retry_options(record._kind,record,record._chapter_uid)
            else
                state.file=pending_record and pending_record.file or (last_record and last_record.file)
                state.book=nil
                state.options=nil
                state.title="多个新版本"
            end
        else
            state.status="pending_install"
            state.pending_install=true
            state.annotation_pending=any_pending or state.annotation_pending
            state.annotation_fallback=any_fallback or state.annotation_fallback
        end
        state.updated_at=os.time()
        self.store:save_download_state(state)
        self:_refresh_local_files()
        if notify then
            local text
            if any_pending then text=installed>1 and "多个新版本已安装" or "新版本已安装"
            elseif any_fallback then text=installed>1 and "多个新版本已安装" or "新版本已安装"
            else text=installed>1 and "多个新版本已安装" or "新版本已安装" end
            self:status_toast("觅阅",text,4)
        end
        logger.info("[MiuRead][Download] pending install timing",
            "pending=",tostring(#pending),"installed=",tostring(installed),
            "reload_ms=",tostring(reload_ms),"prune_ms=",tostring(prune_ms),
            "total_ms=",tostring(math.floor((monotonic_wall_time()-perf_started)*1000+.5)))
        return true
    end
    logger.info("[MiuRead][Download] pending install timing",
        "pending=",tostring(#pending),"installed=0",
        "reload_ms=",tostring(reload_ms),"prune_ms=",tostring(prune_ms),
        "total_ms=",tostring(math.floor((monotonic_wall_time()-perf_started)*1000+.5)))
    return false
end

function Plugin:_download_job_key(book,opt)
    return coordinator(self):job_key(book,opt)
end
function Plugin:_queue_download(book,opt,open_after,extra)
    extra=type(extra)=="table" and extra or {}
    local C=coordinator(self)
    local duplicate=C:find_duplicate(book,opt,
        self._download_runtime and self._download_runtime.book or nil,
        self._download_runtime and self._download_runtime.options or nil)
    if duplicate=="active" then
        self:info("这本书已经在下载中。\n\n请在下载管理中查看当前状态。")
        return false
    end
    if duplicate=="queued" then
        self:info("这本书已经在等待下载。\n\n请在下载管理中查看或移除等待任务。")
        return false
    end
    local queue=self.store:download_queue()
    local position,reason,job=C:enqueue(book,opt,open_after,extra)
    if not position then
        if reason=="full" then
            local waiting=queue[1] or {}
            local waiting_title=tostring(waiting.book and waiting.book.title or "未命名")
            local new_title=tostring(book and book.title or "未命名")
            local dialog
            dialog=ButtonDialog:new{title="等待位置中已有《"..waiting_title.."》。\n\n最多只能有一本正在下载、一本等待。",title_align="center",buttons={
                {{text="替换为《"..U.utf8_truncate(new_title,12).."》",callback=function()
                    UIManager:close(dialog)
                    self.store:save_download_queue({job})
                    self:status_toast("下载队列","等待任务已替换",3)
                    self:_notify_home_data_changed("content")
                end}},
                {{text="保留原等待任务",callback=function() UIManager:close(dialog) end}},
                {{text="查看下载",callback=function() UIManager:close(dialog); self:show_downloads() end}},
            }}
            UIManager:show(dialog)
        else
            self:info("暂时无法加入下载队列。")
        end
        return false
    end
    local title=extra.defer_until_reader_closed and "已安排退出阅读后下载" or "新的任务已加入等待"
    self:status_toast("下载队列",title,3)
    self:_notify_home_data_changed("content")
    return true
end
function Plugin:_start_next_queued_download()
    local C=coordinator(self)
    local ok_start,next_job=C:can_start_next(
        self.download_task and self.download_task:busy(),
        self._download_runtime~=nil,
        self:is_online(),
        self:logged_in(),
        self:_active_reader_ui())
    if not ok_start then return false end
    local job=C:dequeue_next()
    if not job then return false end
    UIManager:scheduleIn(.15,function()
        self:download(job.book or {},job.options or {},job.open_after==true,nil,true,true)
    end)
    return true
end
function Plugin:show_waiting_downloads()
    local queue=self.store:download_queue()
    if #queue==0 then self:info("当前没有等待下载的任务。") return end
    local job=queue[1]
    local title=tostring(job.book and job.book.title or "未命名")
    local variant=(job.options and job.options.annotations) and "划线与想法版" or "纯净版"
    if job.options and job.options.range_start_index then variant="章节版 · "..variant end
    if job.defer_until_reader_closed==true then variant=variant.." · 退出阅读后开始" end
    local items={
        {text=title,post_text=variant,callback=function()
            UIManager:show(ConfirmBox:new{text="从等待队列移除《"..title.."》？",ok_text="移除",cancel_text="保留",ok_callback=function()
                self.store:remove_queued_download(1); self:toast("已移出等待队列")
            end})
        end},
    }
    self:list("等待下载 · 最多一本",items)
end

function Plugin:download(b,opt,open_after,done,start_in_background,from_queue)
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    opt=U.copy(opt or {})
    local requested_id=tostring(b and (b.bookId or b.book_id) or "")
    if from_queue~=true and requested_id~="" then
        for _,job in ipairs(self.store:download_queue()) do
            local queued_id=tostring(job.book and (job.book.bookId or job.book.book_id) or "")
            if queued_id==requested_id then
                self:info("这本书已经在等待下载。\n\n请在下载管理中查看或移除等待任务。")
                return false
            end
        end
    end
    if self.download_task and self.download_task:busy() then
        if from_queue then
            self:_queue_download(b,opt,open_after)
            return false
        end
        return self:_queue_download(b,opt,open_after)
    end
    local stored=self.store:download_state()
    if stored.status=="active" and self:_recover_download_state() then
        if from_queue then
            self:_queue_download(b,opt,open_after)
            return false
        end
        return self:_queue_download(b,opt,open_after)
    end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，完成后再开始下载。"); return end
    if b and b.bookId and tostring(b.bookId)~="" then
        self.store:save_book(b.bookId,{book_id=tostring(b.bookId),title=b.title,author=b.author,
            content_type=b.content_type,updated_at=os.time()})
    end
    local prefs=self.store:preferences()
    if opt.images==nil then opt.images=prefs.images end
    opt.network_mode=tostring(prefs.download_network_mode or "auto")=="ipv4" and "ipv4" or "auto"
    opt.active_document_path=self:_current_document_path()
    local runtime={book=U.copy(b),options=U.copy(opt),last_state={stage="prepare",current=0,total=1,percent=0,chapter=b.title or ""},background=start_in_background==true,dialog=nil,started_at=os.time(),open_after=open_after==true,done=done,notified_milestones={}}
    self._download_runtime=runtime
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    self:_notify_home_data_changed("content")
    local ok,err=self.download_task:start(b,opt,
        function(state) self:_on_download_progress(runtime,state) end,
        function(result) self:_finish_download_runtime(runtime,result) end)
    if not ok then
        self._download_runtime=nil
        self.store:clear_download_state()
        self:_notify_home_data_changed("content")
        if from_queue then self:_queue_download(b,opt,open_after) end
        self:info(self:_friendly_action_error(err,"下载任务启动","download"))
        return false
    end
    runtime.task=self.download_task:descriptor()
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    if runtime.background then
        self.download_task:set_backgrounded(true)
        self:_update_open_shelf_download_status(b.bookId,"生成中 0%")
        if self.store:preferences().download_notice_enabled~=false then
            self:status_toast("觅阅",tostring(b.title or "未命名").."已转入后台下载",3)
        end
    else
        self:_show_active_download_dialog()
    end
end



function Plugin:_range_variant(book_id,kind)
    local record=self.store:variant(book_id,kind)
    if record and record.file and U.file_exists(record.file) and record.partial_range==true then return record end
end
function Plugin:_has_range_variant(book_id)
    return self:_range_variant(book_id,"range_notes")~=nil or self:_range_variant(book_id,"range_clean")~=nil
end
function Plugin:range_extend_menu(b)
    local items={}
    local clean=self:_range_variant(b.bookId,"range_clean")
    local notes=self:_range_variant(b.bookId,"range_notes")
    if clean then items[#items+1]={text="扩展章节版 · 纯净版",callback=function() self:show_range_extend_options(b,false,clean) end} end
    if notes then items[#items+1]={text="扩展章节版 · 划线与想法版（旧版）",callback=function() self:show_range_extend_options(b,true,notes) end} end
    if #items==0 then return {{text="当前没有可扩展的章节版",enabled=false}} end
    return items
end
function Plugin:show_range_extend_options(b,annotations,record)
    local context=self:_interactive_network_context()
    self:_request_catalog(b,"range-extend",function(rows)
        rows=rows or {}
        local first=math.max(1,tonumber(record.range_start_index) or 1)
        local last=math.min(#rows,tonumber(record.range_end_index) or first)
        local items={}
        for _,count in ipairs({5,10,20}) do
            local target=math.min(#rows,last+count)
            items[#items+1]={text="追加后续 "..tostring(math.max(0,target-last)).." 章",enabled=target>last,
                callback=function()
                    self:choose_download_mode(b,{annotations=annotations,range_start_index=first,range_end_index=target,
                        range_start_title=rows[first] and rows[first].title,range_end_title=rows[target] and rows[target].title},false)
                end}
        end
        items[#items+1]={text="扩展到指定章节",enabled=last<#rows,callback=function()
            self:_chapter_list_menu(b,rows,"选择新的结束章节",function(target)
                self:choose_download_mode(b,{annotations=annotations,range_start_index=first,range_end_index=target,
                    range_start_title=rows[first] and rows[first].title,range_end_title=rows[target] and rows[target].title},false)
            end,last+1)
        end}
        items[#items+1]={text="重新选择章节范围",callback=function() self:chapters(b) end}
        self:list("扩展章节版 · 当前 "..tostring(last-first+1).." 章",items)
    end,{context=context,status_text="正在后台读取可扩展章节…"})
end
function Plugin:_current_catalog_index(record,rows)
    if not record or not record.record then return nil end
    local local_map=record.record.chapter_map or {}
    if #local_map==0 then return nil end
    local ratio=self.sync:local_ratio() or 0
    local position=self.sync:position(record,ratio,local_map)
    local uid=tostring(position and position.chapter_uid or "")
    if uid=="" then
        local local_index=math.max(1,math.min(#local_map,math.floor(ratio*#local_map)+1))
        local chapter=local_map[local_index] or {}
        uid=tostring(chapter.uid or chapter.chapterUid or chapter.chapter_uid or "")
    end
    if uid~="" then
        for index,chapter in ipairs(rows or {}) do
            if tostring(chapter.chapterUid or chapter.uid or "")==uid then return index end
        end
    end
    local local_index=math.max(1,math.min(#local_map,math.floor(ratio*#local_map)+1))
    local hinted=tonumber(local_map[local_index] and local_map[local_index].index)
    if hinted and rows and rows[hinted] then return hinted end
    return nil
end
function Plugin:download_current_chapters(count)
    local record=self:_current_book_record()
    if not record or not record.book then self:info("当前不是觅阅生成的书籍。") return end
    local b={bookId=record.book.book_id,title=record.book.title,author=record.book.author,cover=record.book.cover}
    local wanted=math.max(1,tonumber(count) or 1)
    local context=self:_interactive_network_context()
    self:_request_catalog(b,"current-chapter-download",function(rows)
        rows=rows or {}
        local first=self:_current_catalog_index(record,rows)
        if not first or not rows[first] then self:info("暂时无法确定当前章节，请使用“选择章节范围”。") return end
        local last=math.min(#rows,first+wanted-1)
        self:_choose_range_version(b,rows,first,last,false)
    end,{context=context,status_text="正在后台定位当前章节…"})
end

function Plugin:_chapter_state_text(book_id,chapter)
    local uid=tostring(chapter.chapterUid or chapter.uid or "")
    local states={}
    for _,entry in ipairs({{"clean","纯净版"},{"notes","划线与想法版（旧版）"}}) do
        local record=self.store:chapter_variant(book_id,uid,entry[1])
        if record and record.file and U.file_exists(record.file) then states[#states+1]=entry[2] end
    end
    return #states>0 and table.concat(states," · ") or tostring(chapter.wordCount or "")
end
function Plugin:_chapter_list_menu(b,rows,title,callback,start_index)
    local items={}
    for index,ch in ipairs(rows or {}) do
        if not start_index or index>=start_index then
            local chapter=ch
            items[#items+1]={
                text=chapter.title or tostring(chapter.chapterUid or chapter.uid or index),
                post_text=self:_chapter_state_text(b.bookId,chapter),
                callback=function() callback(index,chapter) end,
            }
        end
    end
    self:list(title,items,"没有可用章节")
end
function Plugin:_choose_range_version(b,rows,first,last,open_after,annotations)
    first=math.max(1,tonumber(first) or 1)
    last=math.min(#rows,tonumber(last) or first)
    if last<first then first,last=last,first end
    local first_ch,last_ch=rows[first],rows[last]
    -- New chapter downloads are clean editions only. Legacy range_notes
    -- extension keeps its explicit flag through the extend menu.
    self:choose_download_mode(b,{
        annotations=annotations==true,range_start_index=first,range_end_index=last,
        range_start_title=first_ch and first_ch.title,range_end_title=last_ch and last_ch.title,
    },open_after==true)
end
function Plugin:_range_count_menu(b,rows,first)
    local start_ch=rows[first]
    local items={}
    for _,count in ipairs({1,3,5,10,20}) do
        local actual=math.min(count,#rows-first+1)
        items[#items+1]={text="下载接下来 "..tostring(actual).." 章",post_text=actual<count and "已到全书末尾" or nil,
            callback=function() self:_choose_range_version(b,rows,first,first+actual-1,false) end}
    end
    items[#items+1]={text="选择结束章节",callback=function()
        self:_chapter_list_menu(b,rows,"选择结束章节",function(last) self:_choose_range_version(b,rows,first,last,false) end,first)
    end}
    self:list("从《"..tostring(start_ch and start_ch.title or "所选章节").."》开始",items)
end
function Plugin:chapters(b)
    local context=self:_interactive_network_context()
    self:_request_catalog(b,"chapters",function(rows)
        rows=rows or {}
        local items={
            {text="下载单章",callback=function()
                self:_chapter_list_menu(b,rows,"选择单章 · "..tostring(b.title or "未命名"),function(_,chapter) self:chapter_menu(b,chapter) end)
            end},
            {text="下载章节范围",callback=function()
                self:_chapter_list_menu(b,rows,"选择起始章节",function(first)
                    self:_chapter_list_menu(b,rows,"选择结束章节",function(last) self:_choose_range_version(b,rows,first,last,false) end,first)
                end)
            end},
            {text="从指定章节开始",callback=function()
                self:_chapter_list_menu(b,rows,"选择起始章节",function(first) self:_range_count_menu(b,rows,first) end)
            end},
        }
        self:list("章节下载 · "..tostring(b.title or "未命名"),items,"没有可用章节")
    end,{context=context,status_text="正在后台读取章节目录…"})
end
function Plugin:chapter_menu(b,ch)
    local uid=tostring(ch.chapterUid or ch.uid or "")
    local clean=self.store:chapter_variant(b.bookId,uid,"clean")
    local notes=self.store:chapter_variant(b.bookId,uid,"notes")
    if not (clean and clean.file and U.file_exists(clean.file)) then clean=nil end
    if not (notes and notes.file and U.file_exists(notes.file)) then notes=nil end
    local items={}
    for _,entry in ipairs({{record=clean,label="纯净版"},{record=notes,label="划线与想法版（旧版）"}}) do
        local record=entry.record
        if record then
            local label=DownloadResult.variant_label(entry.label,record)
            items[#items+1]={text="阅读"..label,callback=function() self:open_file(record.file) end}
        end
    end
    items[#items+1]={text=(clean or notes) and "更新本章" or "下载本章",callback=function() self:choose_download(b,nil,true,uid) end}
    if clean or notes then items[#items+1]={text="删除本章文件",callback=function() self:_confirm_delete_chapter_cache(b.bookId,uid,ch.title or uid) end} end
    self:list(ch.title or uid,items)
end

-- open_file / _open_file_direct / _current_document_path remain in main.lua
-- because they read and update the home-session locals defined there.

function Plugin:_variant_label(kind)
    kind=tostring(kind or "clean")
    local preview=kind:sub(1,8)=="preview_"
    local range=kind:sub(1,6)=="range_"
    local base=preview and kind:sub(9) or (range and kind:sub(7) or kind)
    local label=base=="notes" and "划线与想法版（旧版）" or "纯净版"
    if preview then return "试读版 · "..label end
    if range then return "章节版 · "..label end
    return label
end
function Plugin:_close_download_menus()
    local detail=self._download_book_menu; self._download_book_menu=nil
    local root=self._downloads_menu; self._downloads_menu=nil
    if detail then pcall(function() UIManager:close(detail) end) end
    if root and root~=detail then pcall(function() UIManager:close(root) end) end
end
function Plugin:_cache_action_blocked()
    if self.download_task and self.download_task:busy() then self:info("下载任务进行中，暂时不能修改下载文件。") return true end
    local state=self.store:download_state()
    if state.status=="active" then self:info("后台下载状态正在恢复，暂时不能清理文件。") return true end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请勿重复操作。") return true end
    return false
end
local function human_size(bytes)
    bytes=tonumber(bytes) or 0
    if bytes>=1024*1024*1024 then return string.format("%.2f GB",bytes/(1024*1024*1024)) end
    if bytes>=1024*1024 then return string.format("%.1f MB",bytes/(1024*1024)) end
    if bytes>=1024 then return string.format("%.1f KB",bytes/1024) end
    return tostring(bytes).." B"
end
local function path_name(path) return tostring(path or ""):match("([^/]+)$") or "" end
local function is_download_temp_name(name)
    name=tostring(name or "")
    return name=="download-task-owner.json"
        or name:match("^download%-settings%-.+%.lua$")
        or name:match("^download%-diagnostic%-.+%.txt$")
        or name:match("^download%-progress%-.+%.json$")
        or name:match("^download%-result%-.+%.json$")
        or name:match("^download%-recovery%-.+%.json$")
        or name:match("^download%-pause%-.+%.json$")
        or name:match("^download%-cancel%-.+")
end
local function is_epub_residue_name(name)
    name=tostring(name or "")
    return name:match("%.miuread%-new%-%d+%-%d+$")
        or name:match("%.miuread%-backup$")
        or name:match("%.miuread%-linkfix$")
        or name:match("%.miuread%-linkbak$")
end
local function is_pending_epub_name(name)
    return tostring(name or ""):match("%.miuread%-pending$")~=nil
end
function Plugin:_all_partial_cache_paths()
    local paths={}
    for _,book_path in ipairs(U.list(self.store.cache_books_dir)) do
        if lfs.attributes(book_path,"mode")=="directory" then
            for _,path in ipairs(U.list(book_path)) do
                if path_name(path):match("^%.miuread%-partial%-") then paths[#paths+1]=path end
            end
        end
    end
    return paths
end
function Plugin:_download_residue_paths()
    local paths={}
    for _,path in ipairs(U.list(self.store.temp_dir)) do
        if is_download_temp_name(path_name(path)) then paths[#paths+1]=path end
    end
    for _,path in ipairs(U.list(self.store:books_root())) do
        if is_epub_residue_name(path_name(path)) then paths[#paths+1]=path end
    end
    for _,path in ipairs(self:_all_partial_cache_paths()) do paths[#paths+1]=path end
    return paths
end
function Plugin:_storage_categories()
    local categories={books={},partial={},protected={},covers={self.store.covers_dir},temp={}}
    for _,path in ipairs(U.list(self.store:books_root())) do
        local name=path_name(path)
        if (name:lower():match("%.epub$") or name:lower():match("%.epub%.miuread%-locked$")) and not is_epub_residue_name(name) then
            categories.books[#categories.books+1]=path
        elseif is_epub_residue_name(name) or is_pending_epub_name(name) then
            categories.temp[#categories.temp+1]=path
        end
    end
    for _,book_path in ipairs(U.list(self.store.cache_books_dir)) do
        if lfs.attributes(book_path,"mode")=="directory" then
            for _,path in ipairs(U.list(book_path)) do
                if path_name(path):match("^%.miuread%-partial%-") then
                    categories.partial[#categories.partial+1]=path
                else
                    categories.protected[#categories.protected+1]=path
                end
            end
        end
    end
    for _,path in ipairs(U.list(self.store.temp_dir)) do
        if is_download_temp_name(path_name(path)) then categories.temp[#categories.temp+1]=path end
    end
    return categories
end
function Plugin:_run_cache_cleanup(paths,options)
    options=options or {}
    if self:_cache_action_blocked() then return end
    local unique,seen={},{}
    for _,path in ipairs(paths or {}) do
        path=tostring(path or "")
        if path~="" and not seen[path] then seen[path]=true; unique[#unique+1]=path end
    end
    self:_close_download_menus()
    local dialog=InfoMessage:new{text=tostring(options.progress_text or "正在清理，请稍候……")}
    self._cache_cleanup_dialog=dialog
    UIManager:show(dialog)

    local function close_progress()
        if self._cache_cleanup_dialog then pcall(function() UIManager:close(self._cache_cleanup_dialog) end) end
        self._cache_cleanup_dialog=nil
    end
    local function finish(result)
        local ok,unexpected=xpcall(function()
            close_progress()
            result=type(result)=="table" and result or {ok=false,error="未知错误"}
            result.finished_at=os.time()
            result.operation=tostring(options.operation or options.done_text or "缓存清理")
            self.store:reload()
            local commit_ok=true
            if result.ok==true and options.commit then
                local committed,err=xpcall(options.commit,debug.traceback)
                if not committed then
                    commit_ok=false
                    result.commit_error=tostring(err)
                    logger.err("[MiuRead][CacheCleanup] commit failed",tostring(err))
                    self.store:prune_missing_files()
                end
            elseif result.ok~=true then
                self.store:prune_missing_files()
            end
            U.mkdir(self.store.cache_books_dir); U.mkdir(self.store.covers_dir); U.mkdir(self.store.temp_dir)
            self.store:save_cleanup_result(result)
            self:_refresh_local_files()

            local freed=tonumber(result.freed_bytes or 0) or 0
            local removed=tonumber(result.removed or 0) or 0
            local message
            if result.ok==true and commit_ok then
                if freed>0 or removed>0 then
                    message=(options.done_text or _("Cache cleared"))
                        .."\n释放空间："..human_size(freed)
                        .."\n清理项目："..tostring(removed)
                elseif options.success_even_if_empty==true then
                    message=options.done_text or _("Cache cleared")
                else
                    message="没有可清理内容"
                end
            elseif result.ok==true then
                message="文件已清理，但记录刷新失败。重启 KOReader 后会自动重新检查。"
            else
                local err=result.error or table.concat(result.errors or {},"\n") or "未知错误"
                message="清理未完全完成"
                if freed>0 then message=message.."\n已释放："..human_size(freed) end
                message=message.."\n"..U.first_line(err,260)
            end
            self:toast(message,4)
            if options.refresh~=false then UIManager:scheduleIn(.30,function() self:show_downloads() end) end
        end,debug.traceback)
        if not ok then
            close_progress()
            logger.err("[MiuRead][CacheCleanup] result handling failed",tostring(unexpected))
            pcall(function() self:info("清理任务已经结束，但结果显示失败。请重启 KOReader 后检查存储占用。") end)
        end
    end
    if #unique==0 then finish({ok=true,removed=0,missing=0,freed_bytes=0,errors={}}); return end
    local ok,err=self.cache_cleanup_task:start(unique,finish,options.policy)
    if not ok then
        close_progress()
        self:info("无法开始清理：\n"..tostring(err))
        UIManager:scheduleIn(.15,function() self:show_downloads() end)
    end
end

function Plugin:_confirm_delete_variant(book_id,kind,title)
    if self:_cache_action_blocked() then return end
    local record=self.store:variant(book_id,kind)
    if not (record and record.file and U.file_exists(record.file)) then self.store:forget_variant(book_id,kind); self:toast("该版本已经不存在"); self:show_downloads(); return end
    local label=self:_variant_label(kind)
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》的"..label.."？\n\n只删除这个 EPUB，其他版本和下载断点会保留。",
        ok_callback=function()
            local paths=self.store:variant_paths(book_id,kind)
            self:_run_cache_cleanup(paths,{
                progress_text="正在删除"..label.."……",
                done_text=label.."已删除",
                commit=function() self.store:forget_variant(book_id,kind) end,
                policy={mode="variant_delete"},operation="删除单个 EPUB",
            })
        end,
    })
end

function Plugin:_confirm_delete_chapter_cache(book_id,uid,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:chapter_paths(book_id,uid)
    if #paths==0 then self.store:forget_chapter_all(book_id,uid); self:toast("本章文件已经不存在"); return end
    UIManager:show(ConfirmBox:new{
        text="删除“"..tostring(title or uid).."”的全部单章文件？",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:chapter_paths(book_id,uid),{
                progress_text="正在删除本章文件……",
                done_text="本章文件已删除",
                commit=function() self.store:forget_chapter_all(book_id,uid) end,
                policy={mode="chapter_delete"},operation="删除单章 EPUB",
            })
        end,
    })
end

function Plugin:_confirm_clear_partial_cache(book_id,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:partial_cache_paths(book_id)
    if #paths==0 then self:toast("没有未完成下载缓存"); return end
    UIManager:show(ConfirmBox:new{
        text="清理《"..tostring(title or book_id).."》的未完成下载缓存？\n\n已生成的 EPUB 不会删除；下次下载将重新获取尚未完成的内容。",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:partial_cache_paths(book_id),{
                progress_text="正在清理未完成下载缓存……",
                done_text="下载断点已清理",
                commit=function() self.store:prune_missing_files() end,
                policy={mode="download_residue"},operation="清理单本下载断点",
            })
        end,
    })
end
local function add_complete_delete_path(paths,seen,path)
    path=tostring(path or ""):gsub("\\","/"):gsub("/+","/")
    if #path>1 then path=path:gsub("/$","") end
    if path~="" and not seen[path] then seen[path]=true; paths[#paths+1]=path end
end

function Plugin:_complete_book_delete_plan(book_id)
    book_id=tostring(book_id or "")
    local paths,seen,documents={},{},{}
    local function add(path) add_complete_delete_path(paths,seen,path) end
    local function add_document(path)
        path=tostring(path or "")
        if path=="" then return end
        documents[#documents+1]=path
        add(path)
        local ok,DocSettings=pcall(require,"docsettings")
        if ok and DocSettings then
            local settings=DocSettings:open(path)
            if settings then
                add(settings:getSidecarDir(path,"doc"))
                add(settings:getSidecarDir(path,"dir"))
                if DocSettings.isHashLocationEnabled and DocSettings.isHashLocationEnabled() then
                    add(settings:getSidecarDir(path,"hash"))
                end
                add(settings:getHistoryPath(path))
            end
        end
    end

    local function add_record(record)
        if type(record)~="table" then return end
        add_document(record.file)
        add_document(record.original_file)
        add_document(record.pending_file)
    end
    local book=self.store:book(book_id)
    if book then
        for _,record in pairs(book.variants or {}) do add_record(record) end
        for _,row in pairs(book.chapters or {}) do
            for _,record in pairs(row or {}) do add_record(record) end
        end
    end
    add(self.store:book_cache_path(book_id))
    add(self.store:cover_path(book_id))
    local cover_index=self.store:get("cover_index",{})
    add(cover_index[book_id])
    for _,row in ipairs(self.store:pending_installs()) do
        if tostring(row.book_id or "")==book_id then
            add_document(row.file)
            add_document(row.pending_file)
        end
    end
    local state=self.store:download_state()
    local state_id=tostring(state.book_id or (state.book and (state.book.bookId or state.book.book_id)) or "")
    if state_id==book_id then
        add_document(state.file); add_document(state.original_file); add_document(state.pending_file)
    end
    return paths,documents
end

function Plugin:_commit_complete_book_delete(book_id,documents)
    book_id=tostring(book_id or "")
    local ok_history,history=pcall(require,"readhistory")
    if ok_history and history and type(history.removeItemByPath)=="function" then
        for _,path in ipairs(documents or {}) do pcall(history.removeItemByPath,history,path) end
    end
    self.store:forget_book_local_state(book_id)
    if self._cover_index_pending then self._cover_index_pending[book_id]=nil end
    local repair_pending=self._book_repair_pending
    if type(repair_pending)=="table" then repair_pending[book_id]=nil end
    Thoughts.clear_memory_cache()
    if ThoughtNativePopup and type(ThoughtNativePopup.clear_cache)=="function" then
        pcall(ThoughtNativePopup.clear_cache)
    end
    self.store:prune_missing_files()
    self:_notify_home_data_changed("content")
end

function Plugin:_confirm_delete_book_downloads(book_id,title)
    if self:_cache_action_blocked() then return end
    book_id=tostring(book_id or "")
    local paths,documents=self:_complete_book_delete_plan(book_id)
    local current=tostring(self:_current_document_path() or "")
    for _,path in ipairs(documents) do
        if current~="" and current==tostring(path) then
            self:info("请先退出正在阅读的《"..tostring(title or book_id).."》，再删除这本书。")
            return
        end
    end
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》？\n\n将删除本机中的全部版本、单章文件、下载断点、封面、想法与评论缓存、阅读记录和本书设置。删除后无法恢复，重新阅读需要再次下载。\n\n微信读书云端书架、进度、划线和想法不会受到影响。",
        ok_text="删除全部",
        cancel_text="取消",
        ok_callback=function()
            self:_run_cache_cleanup(paths,{
                progress_text="正在完整删除本书……",
                done_text="本书及全部本机相关内容已删除",
                commit=function() self:_commit_complete_book_delete(book_id,documents) end,
                policy={mode="book_delete",allowed_paths=U.copy(paths)},
                operation="完整删除本书",
                success_even_if_empty=true,
            })
        end,
    })
end
function Plugin:_annotation_retry_options(kind,record,chapter_uid)
    record=type(record)=="table" and record or {}
    local opt={annotations=true}
    if chapter_uid then
        opt.chapter_uid=tostring(chapter_uid)
    elseif tostring(kind or ""):sub(1,6)=="range_" or record.partial_range==true then
        opt.range_start_index=tonumber(record.range_start_index)
        opt.range_end_index=tonumber(record.range_end_index)
        opt.range_start_title=record.range_start_title
        opt.range_end_title=record.range_end_title
    end
    return opt
end

function Plugin:_download_book_labels(b)
    local labels={}
    for _,kind in ipairs({"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then
            labels[#labels+1]=DownloadResult.variant_label(self:_variant_label(kind),r)
        end
    end
    local chapter_count=0
    for _,row in pairs(b.chapters or {}) do
        for _,r in pairs(row or {}) do
            if r.file and U.file_exists(r.file) then
                chapter_count=chapter_count+1
            end
        end
    end
    if chapter_count>0 then
        labels[#labels+1]="单章 "..tostring(chapter_count)
    end
    if self.store:book_has_partial_cache(b.book_id) then labels[#labels+1]="未完成缓存" end
    return labels,chapter_count
end

function Plugin:show_storage_usage()
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请稍候。") return end
    local categories=self:_storage_categories()
    local dialog=InfoMessage:new{text="正在统计存储占用……"}
    UIManager:show(dialog)
    local function done(result)
        local ok,unexpected=xpcall(function()
            pcall(function() UIManager:close(dialog) end)
            if not (result and result.ok==true and type(result.sizes)=="table") then
                self:info("存储统计失败：\n"..U.first_line(result and result.error or "未知错误",220))
                return
            end
            local size=result.sizes
            self:info("存储占用\n\n已下载书籍："..human_size(size.books)
                .."\n下载断点："..human_size(size.partial)
                .."\n想法与章节数据（受保护）："..human_size(size.protected)
                .."\n封面缓存："..human_size(size.covers)
                .."\n临时与待安装文件："..human_size(size.temp))
        end,debug.traceback)
        if not ok then
            pcall(function() UIManager:close(dialog) end)
            logger.err("[MiuRead][Storage] result handling failed",tostring(unexpected))
            pcall(function() self:info("存储统计结果显示失败。") end)
        end
    end
    local started,err=self.cache_cleanup_task:start_scan(categories,done)
    if not started then pcall(function() UIManager:close(dialog) end); self:info("无法开始统计：\n"..tostring(err)) end
end



function Plugin:_clear_download_residue()
    if self:_cache_action_blocked() then return end
    local paths=self:_download_residue_paths()
    UIManager:show(ConfirmBox:new{text="清理全部下载断点和失败任务留下的临时文件？\n\n不会删除已生成 EPUB、想法与章节数据、待安装文件和封面。",ok_callback=function()
        self:_run_cache_cleanup(paths,{progress_text="正在清理下载断点与临时文件……",done_text="下载断点与临时文件已清理",operation="清理下载断点与临时文件",policy={mode="download_residue"},commit=function()
            U.mkdir(self.store.temp_dir); self.store:prune_missing_files()
            local state=self.store:download_state()
            if state.status=="failed" or state.status=="interrupted" then self.store:clear_download_state() end
        end})
    end})
end
function Plugin:_clear_cover_cache()
    if self:_cache_action_blocked() then return end
    UIManager:show(ConfirmBox:new{text="清理全部封面缓存？\n\n不会删除书籍、想法、章节数据或阅读记录；下次进入书架时会按需重新下载封面。",ok_callback=function()
        self:_run_cache_cleanup({self.store.covers_dir},{progress_text="正在清理封面缓存……",done_text="封面缓存已清理",operation="清理封面缓存",policy={mode="cover_cache"},commit=function()
            U.mkdir(self.store.covers_dir); self.store:set("cover_index",{})
        end})
    end})
end
function Plugin:show_download_cleanup_dialog()
    if self:_cache_action_blocked() then return end
    if HomeView.is_shown() and not self:_active_reader_ui() then
        return ActionSheet.show{
            title="存储清理",
            subtitle="不会删除书籍 划线 想法 阅读记录或已完成下载",
            actions={
                {icon="⌫",label="下载临时文件",detail="清理断点和失败任务残留",callback=function() self:_clear_download_residue() end},
                {icon="▧",label="失效封面缓存",detail="需要时会自动重新生成",callback=function() self:_clear_cover_cache() end},
            },
            footer_action={label="取消",callback=function() end},
        }
    end
    local dialog
    dialog=ButtonDialog:new{title="清理下载与缓存",title_align="center",buttons={
        {{text="清理下载断点与临时文件",callback=function() UIManager:close(dialog); self:_clear_download_residue() end}},
        {{text="清理封面缓存",callback=function() UIManager:close(dialog); self:_clear_cover_cache() end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end

function Plugin:show_downloads(back_callback)
    if type(back_callback)=="function" then
        self._downloads_return_callback=back_callback
    elseif self.ui and self.ui.document and type(self._downloads_return_callback)=="function" then
        back_callback=self._downloads_return_callback
    else
        self._downloads_return_callback=nil
    end
    local source_document=self.ui and self.ui.document or nil
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，请稍候。") return end
    self.store:reload(); self.store:prune_missing_files()
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end); self._download_book_menu=nil end
    if self._downloads_menu then
        self._downloads_menu._miuread_suppress_restore=true
        pcall(function() UIManager:close(self._downloads_menu) end)
        self._downloads_menu=nil
    end
    local items={}
    if self:_has_download_status() then items[#items+1]={text=self:_download_status_label(),callback=function() self:show_download_status() end} end
    items[#items+1]={text="下载设置",post_text="策略 目录与提醒",sub_item_table_func=function() return self:download_settings_menu() end}
    local queue=self.store:download_queue()
    items[#items+1]={text="等待下载",post_text=tostring(#queue).." 项",callback=function() self:show_waiting_downloads() end}
    items[#items+1]={text="存储占用",callback=function() self:show_storage_usage() end}
    items[#items+1]={text="存储与清理",callback=function() self:show_download_cleanup_dialog() end}
    items[#items+1]={text="已完成",enabled=false}
    for _,b in ipairs(self.store:all_books()) do
        local labels=self:_download_book_labels(b)
        if #labels>0 then
            local book_id=tostring(b.book_id)
            items[#items+1]={text=b.title or book_id,post_text=table.concat(labels," · "),callback=function() self:downloaded_book_menu(book_id) end}
        end
    end
    if HomeView.is_shown() and not self:_active_reader_ui() then
        self._downloads_menu=nil
        return self:_show_miuread_menu("下载管理",items,{on_back=back_callback,page_size=7})
    end
    local menu=Menu:new{title="下载管理",item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._downloads_menu=menu
    local function close_downloads()
        if menu._miuread_closing then return true end
        menu._miuread_closing=true
        local ok,err=pcall(UIManager.close,UIManager,menu)
        if not ok then
            menu._miuread_closing=false
            logger.warn("[MiuRead][Downloads] close failed",tostring(err))
            return false
        end
        if self._downloads_menu==menu then self._downloads_menu=nil end
        if type(back_callback)=="function" and menu._miuread_suppress_restore~=true and not menu._miuread_restore_scheduled then
            menu._miuread_restore_scheduled=true
            UIManager:scheduleIn(.06,function()
                self._downloads_return_callback=nil
                if self.ui and self.ui.document==source_document then
                    local restore_ok,restore_err=pcall(back_callback)
                    if not restore_ok then logger.warn("[MiuRead][Downloads] restore failed",tostring(restore_err)) end
                end
            end)
        end
        return true
    end
    menu.onClose=close_downloads
    menu.onCloseAllMenus=close_downloads
    UIManager:show(menu)
end

function Plugin:downloaded_chapters_menu(book_id)
    self.store:reload()
    local b=self.store:book(book_id)
    if not b then self:toast("下载记录已不存在"); self:show_downloads(); return end
    local order={}
    for index,ch in ipairs(b.catalog or {}) do
        order[tostring(ch.uid or ch.chapterUid or ch.chapter_uid or "")]=index
    end
    local rows={}
    for uid,row in pairs(b.chapters or {}) do
        local labels={}
        local title
        for _,kind in ipairs({"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}) do
            local r=row and row[kind]
            if r and r.file and U.file_exists(r.file) then
                labels[#labels+1]=DownloadResult.variant_label(self:_variant_label(kind),r)
                title=title or r.title
            end
        end
        if #labels>0 then
            rows[#rows+1]={uid=tostring(uid),title=tostring(title or uid),labels=labels,index=order[tostring(uid)] or 999999}
        end
    end
    table.sort(rows,function(a,c)
        if a.index~=c.index then return a.index<c.index end
        return a.uid<c.uid
    end)
    local items={}
    local book={bookId=book_id,title=b.title,author=b.author,cover=b.cover}
    for _,entry in ipairs(rows) do
        local chapter={chapterUid=entry.uid,title=entry.title}
        items[#items+1]={text=entry.title,post_text=table.concat(entry.labels," · "),callback=function() self:chapter_menu(book,chapter) end}
    end
    self:list("单章文件 · "..tostring(b.title or book_id),items,"没有单章文件")
end

function Plugin:downloaded_book_menu(book_ref)
    local book_id=type(book_ref)=="table" and tostring(book_ref.book_id or book_ref.bookId) or tostring(book_ref)
    self.store:reload(); self.store:prune_missing_files()
    local b=self.store:book(book_id)
    if not b then self:toast("下载记录已不存在"); self:show_downloads(); return end
    local items={}
    local variants={}
    for _,kind in ipairs({"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then
            local label=DownloadResult.variant_label(self:_variant_label(kind),r)
            variants[#variants+1]={kind=kind,file=r.file,label=label,record=r}
        end
    end
    if #variants>0 then
        items[#items+1]={text="可阅读版本",enabled=false}
        for _,variant in ipairs(variants) do
            local kind_key=variant.kind; local file=variant.file; local label=variant.label; local record=variant.record
            items[#items+1]={text="阅读"..label,post_text="EPUB",callback=function() self:open_file(file) end}
            items[#items+1]={text="删除"..label,post_text="仅删除该版本",callback=function() self:_confirm_delete_variant(book_id,kind_key,b.title) end}
        end
    end
    local _,chapter_count=self:_download_book_labels(U.merge(b,{book_id=book_id}))
    local has_partial=self.store:book_has_partial_cache(book_id)
    if chapter_count>0 or has_partial then
        items[#items+1]={text="单章与断点",enabled=false}
        if chapter_count>0 then
            items[#items+1]={text="单章文件",post_text=tostring(chapter_count).." 个",callback=function() self:downloaded_chapters_menu(book_id) end}
        end
        if has_partial then
            local repairable=#BookIntegrity.partial_repairs(self.store,book_id)
            if repairable>0 then
                items[#items+1]={text="修复未完成下载",post_text=tostring(repairable).." 个断点",callback=function() self:_repair_downloaded_book(book_id) end}
            end
            items[#items+1]={text="清理未完成下载缓存",post_text="保留已生成 EPUB",callback=function() self:_confirm_clear_partial_cache(book_id,b.title) end}
        end
    end
    if #variants>0 or chapter_count>0 or has_partial then
        items[#items+1]={text="本书管理",enabled=false}
        items[#items+1]={text="删除这本书",post_text="同时删除本机想法、评论与记录",callback=function() self:_confirm_delete_book_downloads(book_id,b.title) end}
    end
    if #items==0 then self:toast("本书没有可管理的下载内容"); self:show_downloads(); return end
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end) end
    if HomeView.is_shown() and not self:_active_reader_ui() then
        self._download_book_menu=nil
        return self:_show_home_bubble_menu(b.title or book_id,items,{page_size=7})
    end
    local menu=Menu:new{title=b.title or book_id,item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._download_book_menu=menu
    UIManager:show(menu)
end


local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
