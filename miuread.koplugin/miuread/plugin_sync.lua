-- MiuRead sync controller, split from main.lua.
-- Installs its Plugin methods onto the main Plugin class in the same way
-- plugin_maintenance.lua does.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local U = require("miuread.util")
local Text = require("miuread.text")
local Http = require("miuread.http")
local HomeView = require("miuread.home_view")
local LocalAnnotationDatabase = require("miuread.local_annotation_database")
local GestureBridge = require("miuread.gesture_bridge")
local RawButtonDialog = require("ui/widget/buttondialog")
local RawConfirmBox = require("ui/widget/confirmbox")

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ButtonDialog = gesture_aware_class(RawButtonDialog, {_miuread_transient=true, _miuread_modal_surface=true})
local ConfirmBox = gesture_aware_class(RawConfirmBox, {_miuread_transient=true, _miuread_modal_surface=true})

local _ = Text.tr

local Plugin = {}

function Plugin:progress_sync_label()
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then return "已关闭" end
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
    if session and session.sync_repair_required==true then
        local kind=tostring(session.sync_repair_kind or "")
        if kind=="context" or kind=="position" then return "需要修复" end
    end
    local state=session and session.progress_sync_state or nil
    local labels={checking="正在检查",retrying="正在重试",mapping_pending="准备章节信息",mapping_preparing="准备章节信息",mapping_failed="章节信息失败",position_locating="正在定位",aligned="已同步",local_selected="使用本机位置",local_uploaded="已上传并确认",uploading="正在上传",verifying_upload="正在确认",upload_failed="上传失败",upload_unconfirmed="云端未确认",source_conflict="云端来源冲突",remote_selected="已采用云端位置",different="等待选择",deferred="本次暂不处理",remote_unavailable="等待重新检查",remote_jump_unconfirmed="跳转待确认"}
    return labels[state] or "已开启"
end

function Plugin:_sync_success_notice_enabled()
    return (self.store:preferences().sync or {}).success_notice_enabled~=false
end
function Plugin:toggle_sync_success_notice()
    local p=self.store:preferences(); p.sync=p.sync or {}
    p.sync.success_notice_enabled=not (p.sync.success_notice_enabled~=false)
    self:_save_ui_preferences(p,"sync_success_notice")
    self:status_toast("同步成功提醒",p.sync.success_notice_enabled and "已开启" or "已关闭",3)
end
function Plugin:_show_auto_sync_success(text)
    if self._sync_success_notified==true or not self:_sync_success_notice_enabled() then return end
    self._sync_success_notified=true
    self:status_toast("同步完成",text or "已成功上传",3)
end
function Plugin:sync_diagnostics_menu()
    return {
        {text="检查当前书籍识别",callback=function()
            local r=self.sync:record()
            if not r or not r.book then self:info("当前文件未被识别为觅阅书籍。") return end
            self:info("当前书籍已识别\n\n书名："..tostring(r.book.title or "未命名")
                .."\n书籍 ID："..tostring(r.book.book_id or "")
                .."\n文件："..tostring(r.path or ""))
        end},
        {text="检查登录状态",callback=function() self:show_account_status() end},
        {text="测试云端进度读取",callback=function() self:manual_sync() end},
        {text="测试当前进度上传",callback=function() self:upload_local_progress(true) end},
        {text="测试上传 30 秒阅读时间",callback=function()
            if not self.sync:record() then self:info("请先打开一本觅阅下载的书籍。") return end
            self:status_toast("阅读时间测试","正在上传 30 秒……",3)
            self.sync:test_upload(function(ok,result,position,value)
                if ok then
                    self:status_toast("阅读时间测试","30 秒已成功上传",4)
                elseif type(value)=="table" and (value.uncertain==true or tostring(value.error_kind or "")=="unconfirmed") then
                    self:status_toast("阅读时间测试","已提交，等待微信读书确认",5)
                else
                    self:info("阅读时间测试失败\n\n"..tostring(result or "未知错误"))
                end
            end)
        end},
        {text="查看详细错误",callback=function() self:show_sync_status(true) end},
        {text="重置当前书籍同步状态",callback=function()
            local r=self.sync:record()
            if not r or not r.book then self:info("请先打开一本觅阅下载的书籍。") return end
            local id=tostring(r.book.book_id)
            UIManager:show(ConfirmBox:new{text="重置当前书籍的临时同步状态？\n\n不会删除书籍、本机阅读位置、划线、想法或账号。",ok_callback=function()
                self.sync:stop("manual_reset",0)
                local sessions=self.store:get("sessions",{})
                local session=sessions[id] or {}
                for _,key in ipairs({
                    "last_error","last_response_summary",
                    "last_http_code","last_http_length","last_payload_public","last_path","last_stage",
                    "progress_sync_state","progress_sync_message","progress_upload_state","progress_upload_error",
                    "progress_local_percent","progress_remote_percent","progress_decided_at",
                    "consecutive_failures"
                }) do session[key]=nil end
                -- Failed remote reading time is intentionally not queued for later replay.
                session.pending_report_seconds=0
                sessions[id]=session
                self.store:set("sessions",sessions)
                self.sync:clear_verified("manual_reset")
                self.sync.last_error=nil
                self.sync.consecutive_failures=0
                self._sync_success_notified=false
                self:status_toast("阅读同步","临时状态已重置",3)
                UIManager:scheduleIn(.5,function()
                    if not self.ui or not self.ui.document then return end
                    local prefs=self.store:preferences().sync or {}
                    if prefs.progress_enabled~=false then self:ensure_read_report_progress("manual_reset",true)
                    elseif prefs.time_enabled==true then self.sync:start("manual_reset") end
                end)
            end})
        end},
    }
end

function Plugin:_schedule_home_annotation_summary_refresh(force)
    local now=os.time()
    if force~=true and type(self._annotation_summary_cache)=="table"
        and now-(tonumber(self._annotation_summary_cache_at) or 0)<12 then return false end
    if self.sync_summary_async and self.sync_summary_async:busy() then return false end
    if self._home_sync_summary_task then return false end
    local task
    task=function()
        if self._home_sync_summary_task~=task then return end
        if self:_home_ui_busy() or self:_active_reader_ui() then
            UIManager:scheduleIn(.55,task)
            return
        end
        self._home_sync_summary_task=nil
        if not self.sync_summary_async or not self.sync_summary_async:available() then return end
        local started,err=self.sync_summary_async:run("annotation-summary",function()
            return LocalAnnotationDatabase.global_summary(self.store) or {}
        end,function(result)
            if result and result.ok and type(result.value)=="table" then
                self._annotation_summary_cache=result.value
                self._annotation_summary_cache_at=os.time()
                self._home_sync_summary_cache=nil
                self._home_sync_summary_cache_at=nil
                if HomeView.is_shown() and not self:_active_reader_ui() then
                    self:_notify_home_data_changed("header")
                end
            elseif result and result.error then
                logger.warn("[MiuRead][SyncSummary] refresh failed",tostring(result.error))
            end
        end,20)
        if not started then logger.warn("[MiuRead][SyncSummary] worker unavailable",tostring(err or "unknown")) end
    end
    self._home_sync_summary_task=task
    UIManager:scheduleIn(force==true and .12 or .70,task)
    return true
end

function Plugin:_home_sync_summary(force)
    -- Never walk every local annotation database from a home gesture. Session
    -- counters are cheap; annotation counters come from an asynchronously
    -- refreshed snapshot.
    local sessions=self.store:get("sessions",{}) or {}
    local progress,time_count,progress_failed=0,0,0
    local pending_progress_states={
        waiting_network=true,uploading=true,upload_unconfirmed=true,upload_failed=true,
        verifying_upload=true,deferred=true,verification_required=true,remote_jump_unconfirmed=true,
    }
    for _,session in pairs(sessions) do
        if type(session)=="table" then
            local state=tostring(session.progress_sync_state or "")
            if pending_progress_states[state] then progress=progress+1 end
            if state=="upload_failed" or state=="upload_unconfirmed" or state=="remote_jump_unconfirmed" then
                progress_failed=progress_failed+1
            end
            if tonumber(session.pending_report_seconds or 0)>0 then time_count=time_count+1 end
        end
    end
    local annotations=type(self._annotation_summary_cache)=="table" and self._annotation_summary_cache or {}
    local highlight=tonumber(annotations.highlight or 0) or 0
    local thought=tonumber(annotations.thought or 0) or 0
    local bookmark=tonumber(annotations.bookmark or 0) or 0
    local total=progress+time_count+highlight+thought+bookmark
    local checking=type(self._annotation_summary_cache)~="table"
        or (self.sync_summary_async and self.sync_summary_async:busy())==true
    local summary={
        progress=progress,time=time_count,highlight=highlight,thought=thought,bookmark=bookmark,
        annotation_pending=tonumber(annotations.pending or 0) or 0,
        annotation_failed=tonumber(annotations.failed or 0) or 0,
        failed=progress_failed+(tonumber(annotations.failed or 0) or 0),
        total=total,books=tonumber(annotations.books or 0) or 0,checking=checking,
    }
    self._home_sync_summary_cache=summary
    self._home_sync_summary_cache_at=os.time()
    self:_schedule_home_annotation_summary_refresh(force==true)
    return summary
end

function Plugin:_home_sync_status_label(force)
    local summary=self:_home_sync_summary(force)
    if summary.failed>0 then return "失败 "..tostring(summary.failed) end
    if summary.total>0 then return "待同步 "..tostring(summary.total) end
    if self.annotation_async and self.annotation_async:busy() then return "同步中" end
    if summary.checking==true then return "同步检查中" end
    return "已同步"
end

function Plugin:_sync_all_pending_annotations(on_done)
    local pending=LocalAnnotationDatabase.pending_books(self.store,80) or {}
    if #pending==0 then if on_done then on_done(true,{synced=0,deleted=0,failed=0}) end; return true end
    if not self:logged_in() then if on_done then on_done(false,{error="请先登录微信读书账号"}) end; return false end
    if self.annotation_async and self.annotation_async:busy() then
        if on_done then on_done(false,{error="批注同步正在运行"}) end
        return false
    end
    local jobs={}
    for _,item in ipairs(pending) do
        local id=tostring(item.book_id or "")
        if id~="" then
            local book=U.copy(self.store:book(id) or {book_id=id})
            book.book_id=tostring(book.book_id or book.bookId or id)
            local record=U.copy(self:_preferred_record(id) or {})
            jobs[#jobs+1]={book=book,record=record}
        end
    end
    if #jobs==0 then if on_done then on_done(true,{synced=0,deleted=0,failed=0}) end; return true end
    local prefs=U.copy(self:_annotation_sync_preferences())
    local service=self.annotation_sync
    local started,err=self.annotation_async:run("annotation-sync-all",function()
        local total={ok=true,synced=0,deleted=0,failed=0,locate_failed=0,metadata_failed=0,coord_failed=0,unknown=0,books=0}
        for _,job in ipairs(jobs) do
            local result=service:sync_book(job.book,job.record,{preferences=prefs,limit=200}) or {}
            total.books=total.books+1
            if result.ok==false then total.failed=total.failed+1; total.ok=false
            else
                for _,key in ipairs({"synced","deleted","failed","locate_failed","metadata_failed","coord_failed","unknown"}) do
                    total[key]=total[key]+(tonumber(result[key] or 0) or 0)
                end
                if tonumber(result.failed or 0)>0 then total.ok=false end
            end
        end
        return total
    end,function(worker_result)
        if not worker_result or worker_result.ok~=true then
            if on_done then on_done(false,{error=worker_result and worker_result.error or "后台任务失败"}) end
            return
        end
        local result=worker_result.value or {}
        if on_done then on_done(result.ok~=false,result) end
    end,220)
    if not started then if on_done then on_done(false,{error=err or "后台任务不可用"}) end; return false end
    return true
end

function Plugin:_sync_home_pending()
    local function proceed(summary)
        summary=summary or self:_home_sync_summary(false)
        if summary.total<=0 and summary.checking~=true then
            self:toast("所有待处理内容都已同步",2)
            return true
        end
        if not self:logged_in() then self:info("请先登录微信读书账号。") return false end
        self:toast("正在同步待处理内容…",2)
        local annotation_count=tonumber(summary.annotation_pending or 0) or 0
        local function finish(ok,result)
            self._home_sync_summary_cache=nil
            self._home_sync_summary_cache_at=nil
            if ok then
                -- The annotation worker has just completed successfully, so use
                -- an immediate zero snapshot instead of rescanning every book on
                -- the UI thread merely to paint a success message.
                self._annotation_summary_cache={pending=0,failed=0,delete_pending=0,bookmark=0,highlight=0,thought=0,books=0}
                self._annotation_summary_cache_at=os.time()
            else
                self._annotation_summary_cache=nil
                self._annotation_summary_cache_at=0
            end
            self:_schedule_home_annotation_summary_refresh(true)
            if HomeView.is_shown() then self:_notify_home_data_changed("header") end
            local after=self:_home_sync_summary(false)
            if ok and after.total<=0 then
                self:status_toast("同步完成","进度 时间 划线和想法已处理",3)
            elseif ok then
                local message="仍有 "..tostring(after.total).." 项待处理"
                if after.progress>0 or after.time>0 then message=message.."\n阅读进度或时间将在对应书籍同步环境恢复后继续处理" end
                self:info(message)
            else
                self:info("同步未全部完成\n\n"..tostring(result and result.error or "失败项目已保留 可稍后重试"))
            end
        end
        if annotation_count>0 then return self:_sync_all_pending_annotations(finish) end
        -- Progress/time are normally submitted as the reader closes. If a stale
        -- pending state remains, keep it visible instead of fabricating a current
        -- book from the home screen.
        finish(true,{})
        return true
    end

    local age=os.time()-(tonumber(self._annotation_summary_cache_at) or 0)
    if type(self._annotation_summary_cache)=="table" and age<=6 then
        return proceed(self:_home_sync_summary(false))
    end
    -- A manual sync must never claim "已同步" from an unknown annotation
    -- snapshot. Do the exact multi-book SQLite count in a subprocess, then
    -- continue with the result without blocking the tap animation.
    if self.sync_summary_async and self.sync_summary_async:available() and not self.sync_summary_async:busy() then
        self:toast("正在检查待同步内容…",2)
        local started,err=self.sync_summary_async:run("annotation-summary-manual",function()
            return LocalAnnotationDatabase.global_summary(self.store) or {}
        end,function(result)
            if result and result.ok and type(result.value)=="table" then
                self._annotation_summary_cache=result.value
                self._annotation_summary_cache_at=os.time()
                proceed(self:_home_sync_summary(false))
            else
                self:info("无法检查本地划线与想法\n\n"..tostring(result and result.error or "后台检查失败"))
            end
        end,20)
        if started then return true end
        logger.warn("[MiuRead][SyncSummary] manual start failed",tostring(err or "unknown"))
    elseif self.sync_summary_async and self.sync_summary_async:busy() then
        self:toast("正在检查同步状态…",2)
        local generation=(tonumber(self._home_sync_manual_wait_generation) or 0)+1
        self._home_sync_manual_wait_generation=generation
        local wait
        wait=function()
            if generation~=self._home_sync_manual_wait_generation then return end
            if self.sync_summary_async and self.sync_summary_async:busy() then UIManager:scheduleIn(.45,wait); return end
            if type(self._annotation_summary_cache)=="table" then proceed(self:_home_sync_summary(false))
            else self:info("同步状态检查未完成 请稍后重试") end
        end
        UIManager:scheduleIn(.45,wait)
        return true
    end
    -- Subprocess support is expected on Kindle. If it is unavailable, keep the
    -- UI responsive and make the limitation explicit rather than performing a
    -- potentially long full-database scan on the main thread.
    self:info("当前环境无法在后台检查本地划线与想法 请稍后重试")
    return false
end

function Plugin:sync_settings_menu()
    return {
        {text="阅读进度",post_text=self.store:preferences().sync.progress_enabled~=false and "已开启" or "已关闭",checked_func=function() return self.store:preferences().sync.progress_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_progress_sync() end},
        {text="阅读时间",post_text=self.store:preferences().sync.time_enabled==true and "已开启" or "已关闭",checked_func=function() return self.store:preferences().sync.time_enabled==true end,keep_menu_open=true,callback=function() self:toggle_time_sync() end},
        {text="本地划线与想法",post_text="手动同步待处理内容",enabled=false},
        {text="新想法云端可见范围",post_text=self:annotation_sync_visibility_label(),sub_item_table_func=function() return self:annotation_sync_visibility_menu() end},
        {text="同步成功提醒",checked_func=function() return self:_sync_success_notice_enabled() end,keep_menu_open=true,callback=function() self:toggle_sync_success_notice() end},
        {text="同步诊断",sub_item_table_func=function() return self:sync_diagnostics_menu() end},
    }
end

function Plugin:sync_menu()
    local rows={
        {text="同步状态",post_text=self:_home_sync_status_label(),callback=function() self:show_sync_status(false) end},
        {text="同步待处理内容",post_text="进度 时间 划线 想法",callback=function() self:_sync_home_pending() end},
    }
    for _,row in ipairs(self:sync_settings_menu()) do rows[#rows+1]=row end
    if self:_current_book_record() then
        rows[#rows+1]={text="重新读取当前书籍云端进度",callback=function() self:manual_sync() end}
    end
    return rows
end

function Plugin:toggle_time_sync(confirmed)
    local current=self.store:preferences()
    if current.sync.time_enabled==true and confirmed~=true then
        UIManager:show(ConfirmBox:new{
            text="关闭后，觅阅不会上传后续阅读时长，其他设备上的阅读统计可能不完整。",
            ok_text="关闭时间同步",cancel_text="保持开启",ok_callback=function() self:toggle_time_sync(true) end,
        })
        return
    end
    local p=self.store:preferences(); p.sync.time_enabled=not p.sync.time_enabled
    self:_save_ui_preferences(p,"time_sync_toggle")
    if p.sync.time_enabled then
        local record=self.sync:record()
        if record and p.sync.progress_enabled~=false and not self.sync:is_current_verified() then
            self:ensure_read_report_progress("time_sync_enabled",false)
        else
            self.sync:start("enabled")
        end
        if self:_original_weread_plugin_present() then
            self:info("阅读时间同步已开启。\n\n检测到原作者 WeRead 插件目录（weread.koplugin）。它与觅阅是两个独立插件；若两边都开启阅读时间同步，可能重复上报。可按自己的需要在插件管理中关闭其中一边。")
        else
            self:status_toast("阅读时间同步","已开启",3)
        end
    else
        self.sync:stop("disabled")
        self:status_toast("阅读时间同步","已关闭",3)
    end
end





function Plugin:_show_progress_success(_text)
    local prefs=self.store:preferences().sync or {}
    -- When reading-time sync is active, its first accepted report contains the
    -- current position too, so one combined notice is enough.
    if prefs.time_enabled==true then return end
    self:_show_auto_sync_success("阅读进度已上传")
end
function Plugin:toggle_progress_sync(confirmed)
    local current=self.store:preferences()
    if current.sync.progress_enabled~=false and confirmed~=true then
        UIManager:show(ConfirmBox:new{
            text="关闭后，其他设备将无法自动接续本书的阅读位置。本机阅读位置不会被删除。",
            ok_text="关闭进度同步",cancel_text="保持开启",ok_callback=function() self:toggle_progress_sync(true) end,
        })
        return
    end
    local p=self.store:preferences(); p.sync.progress_enabled=not (p.sync.progress_enabled~=false); p.sync.pull_on_open=p.sync.progress_enabled
    self:_save_ui_preferences(p,"progress_sync_toggle")
    local r=self.sync:record()
    if p.sync.progress_enabled then
        self.sync:clear_verified("progress_sync_enabled")
        self:toast("阅读进度同步已开启",3)
        if r then UIManager:scheduleIn(.1,function() self:ensure_read_report_progress("enabled",false) end) end
    else
        if r then self.store:save_session(r.book.book_id,{progress_sync_state="disabled",progress_sync_message="阅读进度同步已关闭"}) end
        self.sync.progress_hold=false
        self.sync:start("progress_disabled")
        self:toast("阅读进度同步已关闭",3)
    end
end

function Plugin:_save_progress_state(id,state,message,localp,remotep)
    self.store:save_session(id,{
        progress_sync_state=state,
        progress_sync_message=message,
        progress_local_percent=localp,
        progress_remote_percent=remotep,
        progress_decided_at=os.time(),
    })
end
function Plugin:ensure_read_report_progress(reason,automatic)
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then
        if not automatic then self:info("阅读进度同步已关闭。") end
        self.sync:start("progress_disabled")
        return false
    end
    local r=self.sync:record()
    if not r then
        if not automatic then self:info(_("No matching MiuRead book is open.")) end
        return false
    end
    local id=tostring(r.book.book_id)
    if not self:is_online() then
        self:_save_progress_state(id,"waiting_network","等待 Wi-Fi 恢复后读取云端位置",nil,nil)
        self.sync:end_progress_sync("等待网络恢复")
        if automatic then
            self:_wait_for_network("progress-"..id,function(ready)
                if ready and self.ui and self.ui.document then
                    self:ensure_read_report_progress("network_ready",true)
                end
            end,{minimum_delay=2,max_wait=90,interval=3})
        else
            self:info("Wi-Fi 尚未恢复。\n\n本地阅读位置已保留。阅读时间失败部分不会补传，联网后会重新确认当前进度。")
        end
        return false
    end
    if self._progress_check_running then
        if not automatic then self:toast("正在检查阅读位置……",2) end
        return false
    end

    self._progress_check_running=true
    self.sync:begin_progress_sync(reason or "读取云端进度")
    local chapter_percent=math.floor((self.sync:local_ratio() or 0)*100+.5)
    local function local_failed(err,meta)
        self._progress_check_running=false
        local kind=tostring(meta and meta.error_kind or "position")
        local message
        if kind=="authentication" then message="登录状态无法用于获取章节信息"
        elseif kind=="transport" or kind=="server" then message="网络暂时无法获取章节信息"
        elseif kind=="busy" then message="章节信息后台任务暂时繁忙"
        else message="当前书籍章节信息无法完成换算" end
        self:_save_progress_state(id,"mapping_failed",message,chapter_percent,nil)
        self.sync:end_progress_sync("章节信息准备失败")
        logger.warn("[MiuRead][ProgressMap] initial position failed","book=",id,
            "kind=",kind,"reason=",tostring(err or "unknown"))
        if automatic and kind=="busy" and self.ui and self.ui.document then
            UIManager:scheduleIn(1.0,function()
                if self.ui and self.ui.document then self:ensure_read_report_progress("mapping_retry",true) end
            end)
        elseif not automatic then
            self:info(message.."。\n\n"..U.first_line(tostring(err or "未知错误"),220)
                .."\n\n不会把章节百分比直接当成整书进度上传。")
        end
    end

    local started,resolve_error=self.sync:resolve_local_progress(function(local_position,local_err,meta)
        if not local_position then local_failed(local_err,meta); return end
        local localp=math.floor((tonumber(local_position.progress) or 0)+.5)
        self:_save_progress_state(id,"checking","正在读取云端位置",localp,nil)
        self.sync:remote(id,function(remote,remote_err)
            self._progress_check_running=false
            self._progress_remote_retries=self._progress_remote_retries or {}
            if not remote then
                local retries=tonumber(self._progress_remote_retries[id] or 0) or 0
                if automatic and retries<1 and self.ui and self.ui.document then
                    self._progress_remote_retries[id]=retries+1
                    self:_save_progress_state(id,"retrying","云端位置读取失败，准备重试",localp,nil)
                    self.sync:end_progress_sync("云端位置读取失败，等待重试")
                    UIManager:scheduleIn(2.5,function()
                        if self.ui and self.ui.document then
                            self:ensure_read_report_progress("remote_progress_retry",true)
                        end
                    end)
                    return
                end
                self:_save_progress_state(id,"remote_unavailable","暂时无法读取云端位置",localp,nil)
                self.sync:end_progress_sync("云端位置暂时不可用，阅读时间等待确认")
                if not automatic then
                    self:info("暂时无法读取云端位置。\n\n为了避免覆盖其他设备上的位置，本次阅读时间会等待位置确认后再上传。")
                end
                logger.warn("[MiuRead][Sync] remote position unavailable", tostring(remote_err or "unknown"))
                return
            end
            self._progress_remote_retries[id]=0
            if remote.conflict then
                local webp=remote.web and math.floor((tonumber(remote.web.percent) or 0)+.5) or nil
                local agentp=remote.agent and math.floor((tonumber(remote.agent.percent) or 0)+.5) or nil
                self:_save_progress_state(id,"source_conflict","云端两个来源的位置不一致",localp,webp or agentp)
                self.sync.state="verification_required"
                self.sync.last_stage="等待选择云端位置来源"
                self:on_remote_source_conflict(id,localp,remote,automatic==true)
                return
            end
            local remotep=math.floor((tonumber(remote.percent) or 0)+.5)
            local coordinate_match=self:_remote_matches(remote,local_position)
            local cmp=self.sync:compare(localp,remote)
            if coordinate_match or cmp=="same" then
                self.sync:mark_verified(id,"positions_aligned",localp,remotep,local_position)
                self:_save_progress_state(id,"aligned",coordinate_match and "章节位置一致" or "本机与云端位置接近",localp,remotep)
                self.sync:end_progress_sync("位置已确认，阅读时间开始同步")
                if not automatic then
                    local detail=coordinate_match and "章节和章节内位置一致，无需处理。" or "位置接近，无需处理。"
                    self:info("本机位置："..localp.."%\n云端位置："..remotep.."%\n\n"..detail)
                end
                return
            end
            self:_save_progress_state(id,"different","检测到本机与云端位置不同",localp,remotep)
            self.sync.state="verification_required"
            self.sync.last_stage="等待选择本机或云端位置"
            self:on_remote_progress(id,localp,remote,automatic==true)
        end)
    end,{
        precise=true,
        prepare_catalog=true,
        on_stage=function(stage,detail)
            if stage=="mapping_preparing" then
                self:_save_progress_state(id,"mapping_preparing","正在后台准备完整章节信息",chapter_percent,nil)
                self.sync.last_stage="正在后台准备完整章节信息"
            elseif stage=="position_locating" then
                self:_save_progress_state(id,"position_locating","正在按微信原始正文定位当前位置",chapter_percent,nil)
                self.sync.last_stage="正在按微信原始正文定位当前位置"
            elseif stage=="position_fallback" then
                logger.info("[MiuRead][ProgressMap] source position fallback","book=",id,
                    "reason=",tostring(detail or "unknown"))
            end
        end,
    })
    if not started then
        self._progress_check_running=false
        self.sync:end_progress_sync("无法启动章节位置检查")
        self:_save_progress_state(id,"mapping_failed","章节位置后台任务暂时不可用",chapter_percent,nil)
        if not automatic then self:info("暂时无法启动章节位置检查：\n"..tostring(resolve_error or "后台任务不可用")) end
        return false
    end
    return true
end

function Plugin:manual_sync()
    return self:ensure_read_report_progress("manual_progress_sync",false)
end

function Plugin:_remote_matches(remote,target)
    local threshold=tonumber(self.store:preferences().sync.threshold) or 2
    if not remote then return false,nil,nil end
    local target_position=type(target)=="table" and target or nil
    local target_percent=target_position and tonumber(target_position.progress) or tonumber(target)
    if target_percent==nil then return false,nil,nil end
    local target_uid=target_position and tostring(target_position.chapter_uid or target_position.chapterUid or "") or ""
    local target_co=target_position and tonumber(target_position.chapter_offset or target_position.offset)
    local chapter_words=target_position and tonumber(target_position.chapter_word_count) or 0
    local co_tolerance=math.max(12,math.floor((chapter_words or 0)*0.005))

    local function match(candidate)
        if not candidate then return false,nil,nil end
        local percent=tonumber(candidate.percent)
        local candidate_uid=tostring(candidate.chapter_uid or candidate.chapterUid or "")
        local candidate_co=tonumber(candidate.offset or candidate.chapter_offset)
        if target_uid~="" and candidate_uid~="" and target_uid~=candidate_uid then
            return false,percent,candidate.source,{reason="chapter_uid_mismatch"}
        end
        if target_co~=nil and candidate_co~=nil and target_uid~="" and candidate_uid~="" then
            local delta=math.abs(candidate_co-target_co)
            if delta<=co_tolerance then
                return true,percent,candidate.source,{co_delta=delta,co_tolerance=co_tolerance}
            end
            return false,percent,candidate.source,{
                reason="chapter_offset_mismatch",co_delta=delta,co_tolerance=co_tolerance,
            }
        end
        return percent and math.abs(percent-target_percent)<=threshold,
            percent,candidate.source,{reason="percent_fallback"}
    end
    if remote.conflict then
        local ok,pct,source,meta=match(remote.web); if ok then return true,pct,source,meta end
        ok,pct,source,meta=match(remote.agent); if ok then return true,pct,source,meta end
        return false,nil,nil,meta
    end
    return match(remote)
end

function Plugin:upload_local_progress(manual,callback)
    local r=self.sync:record()
    if not r then
        if manual then self:info("请先打开一本觅阅下载的书籍。") end
        if callback then callback(false,"未识别当前书籍") end
        return false
    end
    local id=tostring(r.book.book_id)
    local session=self.store:session(id) or {}
    if session.sync_repair_required==true
        and (tostring(session.sync_repair_kind or "")=="context" or tostring(session.sync_repair_kind or "")=="position") then
        if manual then self:_show_sync_repair_prompt(session.sync_repair_error,"context",id) end
        if callback then callback(false,session.sync_repair_error or "当前书籍需要修复同步") end
        return false
    end

    self.sync:begin_progress_sync("主动上传本机阅读进度")
    local chapter_percent=math.floor((self.sync:local_ratio() or 0)*100+.5)
    local started,resolve_error=self.sync:resolve_local_progress(function(position,position_error,meta)
        if not position then
            local kind=tostring(meta and meta.error_kind or "position")
            local message=kind=="authentication" and "登录状态无法用于获取章节信息"
                or ((kind=="transport" or kind=="server") and "网络暂时无法获取章节信息"
                or "当前文件暂时无法安全换算整书进度")
            self:_save_progress_state(id,"mapping_failed",message,chapter_percent,nil)
            self.sync:end_progress_sync("当前进度定位失败")
            if manual then self:info(message.."。\n\n"..U.first_line(tostring(position_error or "未知错误"),220)) end
            if callback then callback(false,position_error or message) end
            return
        end

        local target=math.floor((tonumber(position.progress) or 0)+.5)
        self:_save_progress_state(id,"uploading","正在上传本机阅读进度",target,nil)
        if manual then self:status_toast("阅读进度同步","正在上传 "..target.."%……",3) end
        local upload_started=self.sync:upload_progress(function(ok,result,submitted)
            if not ok then
                local current_session=self.store:session(id) or {}
                local repair=current_session.sync_repair_required==true
                    and (tostring(current_session.sync_repair_kind or "")=="context" or tostring(current_session.sync_repair_kind or "")=="position")
                local kind=tostring(current_session.last_error_kind or self.sync.last_error_kind or "")
                local state=(kind=="transport" or kind=="server" or kind=="unconfirmed") and "upload_unconfirmed" or "upload_failed"
                self:_save_progress_state(id,state,repair and "当前书籍同步信息需要修复" or "本次上传暂未完成",target,nil)
                self.sync:end_progress_sync(repair and "当前书籍同步信息需要修复" or "本次上传暂未完成，稍后可继续")
                if manual then
                    if repair then self:_show_sync_repair_prompt(result,"context",id)
                    elseif kind=="authentication" then self:status_toast("阅读进度同步","登录状态需要重新验证",4)
                    else self:status_toast("阅读进度同步","本次未获确认，稍后可再次同步",4) end
                end
                if callback then callback(false,result) end
                return
            end
            local submitted_position=type(submitted)=="table" and submitted or position
            target=math.floor((tonumber(submitted_position and submitted_position.progress) or target)+.5)
            self:_save_progress_state(id,"verifying_upload","请求已接收，正在确认云端位置",target,nil)
            local function verify(attempt)
                UIManager:scheduleIn(attempt==1 and 1.5 or 2.5,function()
                    if not self.ui or not self.ui.document then return end
                    self.sync:remote(id,function(remote,remote_err)
                        local matched,actual,source,verify_meta=self:_remote_matches(remote,submitted_position)
                        logger.info("[MiuRead][ProgressVerify]",
                            "book=",id,
                            "submitted_chapter=",tostring(submitted_position and submitted_position.chapter_uid or "-"),
                            "submitted_co=",tostring(submitted_position and (submitted_position.chapter_offset or submitted_position.offset) or "-"),
                            "remote_chapter=",tostring(remote and remote.chapter_uid or "-"),
                            "remote_co=",tostring(remote and remote.offset or "-"),
                            "co_delta=",tostring(verify_meta and verify_meta.co_delta or "-"),
                            "matched=",tostring(matched==true))
                        if matched then
                            actual=math.floor((tonumber(actual) or target)+.5)
                            self.sync:mark_verified(id,"local_progress_uploaded",target,actual,submitted_position)
                            self:_save_progress_state(id,"local_uploaded","本机进度已上传并确认",target,actual)
                            self.store:save_session(id,{
                                progress_upload_state="verified",
                                progress_upload_verified_at=os.time(),
                                progress_upload_source=source,
                                progress_upload_chapter_uid=submitted_position and submitted_position.chapter_uid,
                                progress_upload_co=submitted_position and (submitted_position.chapter_offset or submitted_position.offset),
                                progress_upload_remote_co=remote and remote.offset,
                            })
                            self.sync:end_progress_sync("本机阅读进度已上传并确认")
                            local chapter_title=tostring(submitted_position and (submitted_position.summary or submitted_position.chapter_title) or "")
                            local chapter_percent=tonumber(submitted_position and submitted_position.chapter_percent)
                            local precision_label=(submitted_position and submitted_position.native_offset==true) and "原生章节坐标" or "章节锚点"
                            if manual then
                                local detail="已上传并确认："..target.."%"
                                if chapter_title~="" then detail=detail.."\n章节："..chapter_title end
                                if chapter_percent then detail=detail.."\n章节内位置："..tostring(chapter_percent).."%" end
                                detail=detail.."\n定位方式："..precision_label
                                    .."\n\n提示：手机端微信读书的排版与 KOReader 不同，同一进度可能落在相邻页；请以章节为准。"
                                self:info(detail)
                            else
                                self:_show_progress_success("已同步："..target.."%")
                            end
                            UIManager:scheduleIn(.2,function()
                                if self.ui and self.ui.document then
                                    self:_sync_progress_anchor_quietly()
                                end
                            end)
                            if callback then callback(true,remote) end
                        elseif attempt<2 then
                            verify(attempt+1)
                        else
                            self:_save_progress_state(id,"upload_unconfirmed","请求已发送，但云端位置尚未更新",target,remote and remote.percent)
                            self.store:save_session(id,{progress_upload_state="unconfirmed",progress_upload_error=remote_err})
                            self.sync:end_progress_sync("进度请求已发送，云端尚未确认")
                            if manual then self:info("上传请求已发送，但云端位置尚未更新。\n\n本机位置："..target.."%") end
                            if callback then callback(false,remote_err or "云端位置尚未更新") end
                        end
                    end,{force=true})
                end)
            end
            verify(1)
        end,{position_override=position})
        if not upload_started then
            self.sync:end_progress_sync("无法启动阅读进度上传")
            if manual then self:info("无法启动阅读进度上传：同步任务正在运行。") end
            if callback then callback(false,"同步任务正在运行") end
        end
    end,{
        precise=true,
        prepare_catalog=true,
        on_stage=function(stage)
            if stage=="mapping_preparing" then
                self:_save_progress_state(id,"mapping_preparing","正在后台准备完整章节信息",chapter_percent,nil)
            elseif stage=="position_locating" then
                self:_save_progress_state(id,"position_locating","正在定位当前阅读位置",chapter_percent,nil)
            end
        end,
    })
    if not started then
        self.sync:end_progress_sync("无法启动当前进度定位")
        self:_save_progress_state(id,"mapping_failed","章节位置后台任务暂时不可用",chapter_percent,nil)
        if manual then self:info("暂时无法启动当前进度定位：\n"..tostring(resolve_error or "后台任务不可用")) end
        if callback then callback(false,resolve_error or "后台任务不可用") end
        return false
    end
    return true
end

function Plugin:_use_remote_position(id,localp,remote)
    local remotep=math.floor((tonumber(remote and remote.percent) or 0)+.5)
    local jumped,jump_error=self.sync:jump_remote(remote)
    if not jumped then
        self:_save_progress_state(id,"remote_jump_unconfirmed","无法跳转到云端位置",localp,remotep)
        self.sync:end_progress_sync("云端位置跳转失败，阅读时间暂缓上传")
        self:info(tostring(jump_error or "无法跳转到云端位置。").."\n\n当前位置未确认，因此暂不上传阅读时间。")
        return false
    end
    UIManager:scheduleIn(1.2,function()
        local actual_position=self.sync:local_position()
        local actual=actual_position and actual_position.progress and math.floor(actual_position.progress+.5) or localp
        local threshold=tonumber(self.store:preferences().sync.threshold) or 2
        if math.abs(actual-remotep)<=threshold then
            self.sync:mark_verified(id,"remote_position_selected",actual,remotep,actual_position)
            self:_save_progress_state(id,"remote_selected","已采用云端位置",actual,remotep)
            self.sync:end_progress_sync("已采用云端位置，阅读时间开始同步")
            self:status_toast("阅读进度同步","已切换到云端进度："..remotep.."%",4)
        else
            self:_save_progress_state(id,"remote_jump_unconfirmed","已请求跳转，位置仍待确认",actual,remotep)
            self.sync:end_progress_sync("云端位置仍待确认，阅读时间暂缓上传")
            self:info("已请求跳到云端位置，但当前显示位置为 "..actual.."%。\n\n为避免覆盖云端位置，暂不上传阅读时间。")
        end
    end)
    return true
end

function Plugin:on_remote_source_conflict(id,localp,remote,automatic)
    if automatic and self._progress_prompted_book_id==tostring(id) then
        self.sync:end_progress_sync("云端来源冲突等待用户处理")
        return
    end
    self._progress_prompted_book_id=tostring(id)
    local webp=remote.web and math.floor((tonumber(remote.web.percent) or 0)+.5) or nil
    local agentp=remote.agent and math.floor((tonumber(remote.agent.percent) or 0)+.5) or nil
    local web_time=remote.web and remote.web.updated_at and (" · "..self:_relative_time(remote.web.updated_at)) or ""
    local agent_time=remote.agent and remote.agent.updated_at and (" · "..self:_relative_time(remote.agent.updated_at)) or ""
    local title="云端阅读位置来源不一致\n\n"
        .."本机位置："..localp.."%\n（当前阅读）\n\n"
        .."微信读书网页："..tostring(webp or "未获取").."%"..web_time.."\n"
        .."官方接口："..tostring(agentp or "未获取").."%"..agent_time
    local dialog,closing_for_action
    local function defer()
        self:_save_progress_state(id,"deferred","云端来源不一致，本次暂不处理",localp,webp or agentp)
        self.sync:end_progress_sync("云端来源冲突尚未确认")
    end
    local buttons={}
    if remote.web then buttons[#buttons+1]={{text="使用网页云端 "..webp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote.web)
    end}} end
    if remote.agent then buttons[#buttons+1]={{text="使用官方云端 "..agentp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote.agent)
    end}} end
    buttons[#buttons+1]={{text="使用本机并上传 "..localp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:upload_local_progress(true)
    end}}
    buttons[#buttons+1]={{text="本次暂不处理",callback=function()
        closing_for_action=true; UIManager:close(dialog); defer()
    end}}
    dialog=ButtonDialog:new{title=title,title_align="center",close_callback=function()
        if not closing_for_action then defer() end
    end,buttons=buttons}
    UIManager:show(dialog)
end

function Plugin:on_remote_progress(id,localp,remote,automatic)
    local remotep=math.floor((tonumber(remote.percent) or 0)+.5)
    if automatic and self._progress_prompted_book_id==tostring(id) then
        self.sync:end_progress_sync("已提示位置差异，等待用户选择")
        return
    end
    self._progress_prompted_book_id=tostring(id)
    local source=remote.source=="web_cookie" and "网页云端" or (remote.source=="agent_gateway" and "官方云端" or "云端")
    local remote_time=remote.updated_at and ("\n（"..self:_relative_time(remote.updated_at).."）") or ""
    local text="检测到阅读位置不同\n\n本机位置："..localp.."%\n（当前阅读）\n\n"..source.."位置："..remotep.."%"..remote_time
    local dialog,closing_for_action
    local function defer()
        self:_save_progress_state(id,"deferred","本次暂不处理位置差异",localp,remotep)
        self.sync:end_progress_sync("位置差异尚未确认，阅读时间暂缓上传")
    end
    dialog=ButtonDialog:new{title=text,title_align="center",close_callback=function()
        if not closing_for_action then defer() end
    end,buttons={
        {{text="使用云端位置",callback=function()
            closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote)
        end}},
        {{text="使用本机位置并上传",callback=function()
            closing_for_action=true; UIManager:close(dialog); self:upload_local_progress(true)
        end}},
        {{text="本次暂不同步位置",callback=function()
            closing_for_action=true; UIManager:close(dialog); defer()
        end}},
    }}
    UIManager:show(dialog)
end

function Plugin:_relative_time(ts)
    ts=tonumber(ts or 0) or 0
    if ts<=0 then return "尚未同步" end
    local delta=math.max(0,os.time()-ts)
    if delta<10 then return "刚刚" end
    if delta<60 then return tostring(delta).."秒前" end
    if delta<3600 then return tostring(math.floor(delta/60)).."分钟前" end
    if delta<86400 then return tostring(math.floor(delta/3600)).."小时前" end
    return U.now_text(ts)
end
function Plugin:show_sync_status(detail)
    local s=self.sync:status()
    local remote=s.remote and math.floor((s.remote.percent or 0)+.5) or nil
    local local_text=s.local_percent~=nil and (tostring(s.local_percent).."%")
        or (s.local_chapter_percent~=nil and ("本章 "..tostring(s.local_chapter_percent).."%") or "—")
    local time_text
    if not s.time_enabled then time_text="已关闭"
    elseif not s.record or s.state=="stopped" then time_text="未运行"
    elseif s.state=="verification_required" or s.state=="fetching_remote" or s.state=="progress_sync" then time_text="等待位置确认"
    elseif s.state=="repair_required" then time_text="需要修复同步"
    elseif s.state=="paused" then time_text="已暂停"
    elseif tostring(s.last_error_kind or "")=="authentication" then time_text="登录待验证"
    elseif tostring(s.last_error_kind or "")=="transport" then time_text="等待网络恢复"
    elseif tostring(s.last_error_kind or "")=="server" then time_text="等待自动重试"
    elseif s.state=="uploading" then time_text="正在同步"
    else time_text="运行中" end

    if HomeView.is_shown() and not self:_active_reader_ui() then
        local pending=self:_home_sync_summary(true)
        local function pending_text(count,normal)
            count=tonumber(count or 0) or 0
            return count>0 and ("待同步 "..tostring(count)) or tostring(normal or "已同步")
        end
        local rows={
            {text="总状态",post_text=self:_home_sync_status_label(),enabled=false,bold=true},
            {text="阅读进度",post_text=pending_text(pending.progress,self:progress_sync_label()),enabled=false},
            {text="阅读时间",post_text=pending_text(pending.time,time_text),enabled=false},
            {text="本地划线",post_text=pending_text(pending.highlight,"已同步"),enabled=false},
            {text="本地想法",post_text=pending_text(pending.thought,"已同步"),enabled=false},
        }
        if pending.bookmark>0 then rows[#rows+1]={text="本地书签",post_text="待同步 "..tostring(pending.bookmark),enabled=false} end
        rows[#rows+1]={text="上次同步",post_text=self:_relative_time(s.last_upload),enabled=false}
        if detail then
            rows[#rows+1]={text="详细信息",separator=true,enabled=false}
            rows[#rows+1]={text="后台服务版本",post_text=tostring(s.service_version or "—"),enabled=false}
            if s.last_position_basis then rows[#rows+1]={text="上次定位方式",post_text=U.first_line(s.last_position_basis,80),enabled=false} end
            if s.last_position_fallback and s.last_position_fallback~="" then rows[#rows+1]={text="定位回退原因",post_text=U.first_line(s.last_position_fallback,80),enabled=false} end
            if s.last_stage then rows[#rows+1]={text="当前阶段",post_text=U.first_line(s.last_stage,80),enabled=false} end
            if s.last_error then rows[#rows+1]={text="最近错误",post_text=U.first_line(s.last_error,80),enabled=false} end
        end
        return self:_show_miuread_menu("同步状态",rows,{page_size=7})
    end

    local lines={"阅读同步","","阅读时间："..time_text,"阅读进度："..self:progress_sync_label(),"当前位置："..local_text}
    if remote then lines[#lines+1]="云端位置："..remote.."%" end
    lines[#lines+1]="上次同步："..self:_relative_time(s.last_upload)
    if detail then
        lines[#lines+1]=""
        lines[#lines+1]="详细信息"
        lines[#lines+1]="单次阅读时间上限：30 秒"
        if s.last_position_basis then
            lines[#lines+1]="上次定位方式："..tostring(s.last_position_basis)
        end
        if s.last_position_fallback and s.last_position_fallback~="" then
            lines[#lines+1]="定位回退原因："..U.first_line(s.last_position_fallback,120)
        end
        lines[#lines+1]="后台服务版本："..tostring(s.service_version or "—")
        if s.last_elapsed then lines[#lines+1]="上次提交时长："..tostring(s.last_elapsed).." 秒" end
        if s.last_stage then lines[#lines+1]="当前阶段："..U.first_line(s.last_stage,160) end
        if s.last_error then lines[#lines+1]="最近错误："..U.first_line(s.last_error,200) end
        if s.last_response_summary then lines[#lines+1]="响应摘要："..U.first_line(s.last_response_summary,200) end
        if s.last_http_code then lines[#lines+1]="HTTP："..tostring(s.last_http_code) end
        if s.last_path then lines[#lines+1]="上传路径："..tostring(s.last_path) end
    end
    self:info(table.concat(lines,"\n"))
end

function Plugin:repair_current_sync()
    local r=self:_current_book_record()
    if not r or not r.book then self:info("请先打开一本觅阅下载的书籍。"); return false end
    local book_id=tostring(r.book.book_id or "")
    local title=tostring(r.book.title or "当前书籍")
    if self.sync.repair_busy==true and tostring(self.sync.repair_book_id or "")==book_id then
        self:status_toast("检查与修复","《"..title.."》正在处理，请勿重复操作",3)
        return true
    end
    self:status_toast("检查与修复","正在检查《"..title.."》的登录和章节同步状态",4)
    local started=self.sync:repair_current(function(ok,result)
        if ok then
            self._sync_repair_prompt_book=nil
            self:status_toast("阅读同步已修复","当前进度已同步 阅读时间从现在重新开始同步",5)
        else
            local err=tostring(result or "未知错误")
            local record=self.sync:record()
            local book_id=record and record.book and tostring(record.book.book_id or "") or ""
            local session=book_id~="" and (self.store:session(book_id) or {}) or {}
            local kind=tostring(session.sync_repair_kind or self.sync.last_error_kind or "")
            if kind=="authentication" or Http.is_auth_error(err) then
                local dialog
                dialog=ButtonDialog:new{title="微信读书登录已失效",buttons={
                    {{text="重新扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}},
                    {{text="稍后",callback=function() UIManager:close(dialog) end}},
                }}
                UIManager:show(dialog)
            elseif kind=="context" then
                self:info("当前书籍同步修复失败\n\n登录状态正常 但无法可靠识别当前章节。\n\n已暂停这本书的阅读时间同步 其他书籍不受影响。")
            elseif kind=="transport" then
                self:info("阅读同步修复失败\n\n当前网络连接仍不可用。\n\n本次失败的阅读时间不会补传 可以稍后再次修复。")
            else
                self:info("阅读同步修复失败\n\n微信读书未确认本次同步。\n\n本次失败的阅读时间不会补传 可以稍后再次修复。")
            end
        end
    end)
    if not started then self:info("暂时无法启动同步修复 请稍后再试。") end
    return started
end

function Plugin:_show_sync_repair_prompt(err,kind,book_id)
    kind=tostring(kind or "")
    if kind~="context" and kind~="position" then return false end
    if self.sync and self.sync.repair_busy==true then return false end
    local r=self:_current_book_record()
    local current_id=r and r.book and tostring(r.book.book_id or "") or ""
    book_id=tostring(book_id or current_id)
    if book_id=="" or (current_id~="" and book_id~=current_id) then return end
    if self._sync_repair_prompt_book==book_id then return end
    self._sync_repair_prompt_book=book_id
    local title=tostring(r and r.book and r.book.title or "当前书籍")
    local detail=(tostring(kind or "")=="context")
        and "当前书籍的章节同步信息无法可靠识别。"
        or ((tostring(kind or "")=="authentication") and "当前登录或同步状态已失效。" or "本次阅读同步未成功。")
    local dialog
    local function close()
        self._sync_repair_prompt_book=nil
        if dialog then UIManager:close(dialog) end
    end
    dialog=ConfirmBox:new{
        text="《"..title.."》阅读同步失败\n\n"..detail
            .."\n\n本次失败的阅读时间不会补传。其他书籍不受影响。",
        ok_text="修复同步", cancel_text="稍后",
        ok_callback=function() close(); self:repair_current_sync() end,
        cancel_callback=close,
    }
    UIManager:show(dialog)
end

function Plugin:on_auth_required(channel,err)
    local notify=tostring(channel or "")~="read_report"
    local marked=self:_mark_auth_problem(channel,err,notify)
    if marked and not notify then
        self:status_toast("阅读时间上传","登录验证暂时失败，本次时间不补传；下载不受影响",5)
    end
    return marked
end
function Plugin:on_auth_channel_ok(channel)
    self:_mark_auth_channel_ok(channel)
end

function Plugin:on_read_report_ready()
    -- Background sync starts silently.
end
function Plugin:on_read_report_success(path)
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
    if r and (session.progress_sync_state=="mapping_pending" or session.progress_sync_state=="mapping_preparing")
        and self.store:preferences().sync.progress_enabled~=false then
        UIManager:scheduleIn(.5,function()
            if self.ui and self.ui.document then self:ensure_read_report_progress("catalog_ready",true) end
        end)
    elseif r and self.store:preferences().sync.progress_enabled~=false then
        -- Automatic background reports already carry the latest position. Do not
        -- immediately query the cloud again: the extra read caused avoidable I/O
        -- and UI stalls on slower devices. Manual uploads still perform full
        -- confirmation through upload_local_progress().
        local position=self.sync:local_position()
        if position and position.safe==true and position.progress~=nil then
            local target=math.floor((tonumber(position.progress) or 0)+.5)
            self.store:save_session(r.book.book_id,{
                progress_upload_state="submitted",
                progress_upload_at=os.time(),
                progress_upload_percent=target,
            })
        end
    end
end
function Plugin:on_read_report_interval_success(status)
    if status and (status.recovery_probe==true or tonumber(status.elapsed_seconds or 0)<=0) then return end
    local prefs=self.store:preferences().sync or {}
    if prefs.time_enabled~=true then return end
    if prefs.progress_enabled~=false then
        self:_show_auto_sync_success("阅读进度和阅读时间已上传")
    else
        self:_show_auto_sync_success("阅读时间已上传")
    end
end
function Plugin:on_read_report_failure(err,kind,book_id)
    kind=tostring(kind or "")
    if kind=="authentication" or Http.is_auth_error(err) then
        self:_mark_auth_problem("read_report",err,false)
        return
    end
    if kind=="context" or kind=="position" then self:_show_sync_repair_prompt(err,"context",book_id) end
end
function Plugin:_current_book_record()
    self.store:reload()
    local r=self.sync:record()
    if r then return r end
    local doc=self.ui and self.ui.document
    local path=doc and (doc.file or (doc.getFilePath and doc:getFilePath()))
    local b,rec,variant=self.store:file_record(path)
    if b then return {book=b,record=rec,variant=variant,path=path} end
    local raw=path and U.read_file(path,true)
    local id=raw and (raw:match('"book_id"%s*:%s*"([^"]+)"') or raw:match('miuread://book/([^<"]+)'))
    local fallback=id and self.store:book(id)
    if fallback then return {book=fallback,record=fallback.variants and (fallback.variants.notes or fallback.variants.clean or fallback.variants.range_notes or fallback.variants.range_clean or fallback.variants.preview_notes or fallback.variants.preview_clean),variant=nil,path=path} end
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
