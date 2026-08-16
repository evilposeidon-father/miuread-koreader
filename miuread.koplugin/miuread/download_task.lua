local FFIUtil = require("ffi/util")
local Json = require("miuread.json")
local U = require("miuread.util")
local UIManager = require("ui/uimanager")
local Device = require("device")
local logger = require("logger")
local Config = require("miuread.config")
local lfs = require("libs/libkoreader-lfs")

local DownloadTask = {}
DownloadTask.__index = DownloadTask

local function is_android()
    if type(FFIUtil.isAndroid) ~= "function" then return false end
    local ok, value = pcall(FFIUtil.isAndroid)
    return ok and value == true
end

local function lower_worker_priority()
    -- KOReader already lowers subprocess priority. Android workers are more
    -- vulnerable to background scheduling, so do not lower them a second time.
    if is_android() then return false end
    local ok,ffi=pcall(require,"ffi")
    if not ok or not ffi then return false end
    pcall(ffi.cdef,"int setpriority(int which, int who, int prio);")
    local called = pcall(function() ffi.C.setpriority(0,0,10) end)
    return called
end

local function serializable_copy(value, seen)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then return value end
    if kind ~= "table" then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do
        if type(k) == "string" or type(k) == "number" then
            local x = serializable_copy(v, seen)
            if x ~= nil then out[k] = x end
        end
    end
    return out
end

function DownloadTask:new(store)
    return setmetatable({
        store = store,
        job = nil,
        poll_task = nil,
        standby_held = false,
        keep_awake_enabled = true,
        backgrounded = false,
        pause_reasons = {},
        foreground_poll_interval = 0.40,
        background_poll_interval = 1.50,
        paused_poll_interval = 2.00,
        owner_path = store.temp_dir .. "/download-task-owner.json",
        owner_token = tostring(os.time()) .. "-" .. tostring(math.random(100000,999999)),
    }, self)
end

function DownloadTask:set_backgrounded(value)
    self.backgrounded = value == true
    -- beta.3 keeps an actively progressing background download awake. The
    -- worker releases this lock when it is paused or has been waiting without
    -- progress for several minutes, so a dead network cannot drain the battery.
    if self.job and not self:is_paused() then
        self:_hold_awake()
    else
        self:_release_awake()
    end
end

function DownloadTask:_control_descriptor()
    if self.job then return self.job end
    -- FileManager and ReaderUI own different plugin instances. Read the active
    -- task descriptor from the persisted download state so either instance can
    -- pause or stop the same child process during a foreground recovery.
    local ok,state=pcall(self.store.download_state,self.store)
    local task=ok and type(state)=="table" and state.task or nil
    return type(task)=="table" and task or nil
end

function DownloadTask:_control_pause_path()
    local task=self:_control_descriptor()
    local path=type(task)=="table" and tostring(task.pause_path or "") or ""
    return path~="" and path or nil
end

function DownloadTask:_control_network_path()
    local task=self:_control_descriptor()
    local path=type(task)=="table" and tostring(task.network_path or "") or ""
    return path~="" and path or nil
end

function DownloadTask:set_network_mode(mode)
    mode=tostring(mode or "auto")=="ipv4" and "ipv4" or "auto"
    local path=self:_control_network_path()
    if not path then return false,"当前下载任务不支持网络模式切换" end
    local wrote,err=U.atomic_write(path,mode,true)
    if not wrote then return false,tostring(err or "无法写入网络模式") end
    if self.job then
        self.job.network_mode=mode
        self.job.restart_options=self.job.restart_options or {}
        self.job.restart_options.network_mode=mode
        self.job.restart_options.network_suggestion_silent=nil
    end
    logger.info("[MiuRead][DownloadTask] network mode updated",
        "mode=",mode,"shared=",tostring(self.job==nil))
    return true
end

function DownloadTask:dismiss_network_suggestion()
    local path=self:_control_network_path()
    if not path then return false end
    local wrote=U.atomic_write(path,"auto_silent",true)==true
    if wrote and self.job then
        self.job.restart_options=self.job.restart_options or {}
        self.job.restart_options.network_mode="auto"
        self.job.restart_options.network_suggestion_silent=true
    end
    if wrote then logger.info("[MiuRead][DownloadTask] IPv4 suggestion dismissed for current task") end
    return wrote
end

function DownloadTask:_marker_reasons(path)
    local reasons={}
    path=path or self:_control_pause_path()
    if not path then return reasons end
    local raw=U.read_file(path,true)
    if not raw then return reasons end
    local ok,value=pcall(Json.decode,raw)
    if not ok or type(value)~="table" then return reasons end
    for _,reason in ipairs(type(value.reasons)=="table" and value.reasons or {}) do
        reason=tostring(reason or "")
        if reason~="" then reasons[reason]=true end
    end
    return reasons
end

function DownloadTask:_merged_pause_reasons(path)
    path=path or self:_control_pause_path()
    -- While a task descriptor exists, the marker is the single source of
    -- truth shared by FileManager and ReaderUI. Never merge stale per-instance
    -- reasons back into it after another instance has resumed the worker.
    if path then return self:_marker_reasons(path) end
    local reasons={}
    for reason,value in pairs(self.pause_reasons or {}) do
        if value==true then reasons[reason]=true end
    end
    return reasons
end

function DownloadTask:is_paused()
    return next(self:_merged_pause_reasons())~=nil
end

function DownloadTask:_write_pause_marker(path,reasons)
    path=path or self:_control_pause_path()
    if not path then return false end
    reasons=reasons or self:_merged_pause_reasons(path)
    self.pause_reasons=reasons
    if next(reasons)==nil then
        os.remove(path)
        return true
    end
    local ordered={}
    for reason in pairs(reasons) do ordered[#ordered+1]=reason end
    table.sort(ordered)
    return U.atomic_write(path,Json.encode({
        paused=true,reasons=ordered,updated_at=os.time(),
    }),true)==true
end

function DownloadTask:pause(reason)
    reason=tostring(reason or "manual")
    local path=self:_control_pause_path()
    local reasons=self:_merged_pause_reasons(path)
    reasons[reason]=true
    local wrote=self:_write_pause_marker(path,reasons)
    self:_release_awake()
    logger.info("[MiuRead][DownloadTask] paused","reason=",reason,
        "marker=",tostring(wrote),"shared=",tostring(self.job==nil))
    if self.job then self:_schedule() end
    return wrote
end

function DownloadTask:resume(reason)
    local path=self:_control_pause_path()
    local reasons=self:_merged_pause_reasons(path)
    if reason==nil then
        reasons={}
    else
        reasons[tostring(reason)]=nil
    end
    local still_paused=next(reasons)~=nil
    self:_write_pause_marker(path,reasons)
    if not still_paused and self.job and not self.backgrounded then self:_hold_awake() end
    logger.info("[MiuRead][DownloadTask] resume requested",
        "reason=",tostring(reason or "all"),"still_paused=",tostring(still_paused),
        "shared=",tostring(self.job==nil))
    if self.job then self:_schedule() end
    return not still_paused
end

local TRANSIENT_PAUSE_REASONS = {
    home_interaction=true, reader_interaction=true, page_transition=true,
    thought_popup=true, transient_ui=true,
}

function DownloadTask:_replace_transient_pause_reasons(add_suspend)
    local path=self:_control_pause_path()
    local reasons=self:_merged_pause_reasons(path)
    for reason in pairs(TRANSIENT_PAUSE_REASONS) do reasons[reason]=nil end
    if add_suspend==true then reasons.suspend=true else reasons.suspend=nil end
    local still_paused=next(reasons)~=nil
    self:_write_pause_marker(path,reasons)
    if still_paused then self:_release_awake()
    elseif self.job then self:_hold_awake() end
    logger.info("[MiuRead][DownloadTask] lifecycle pause reasons normalized",
        "suspend=",tostring(add_suspend==true),"still_paused=",tostring(still_paused))
    if self.job then self:_schedule() end
    return not still_paused
end

function DownloadTask:on_suspend()
    -- Install the strong suspend reason and discard UI-only reasons atomically.
    -- Otherwise an unscheduled interaction timer can leave the worker paused
    -- forever after wake. Manual/network/auth pauses are intentionally kept.
    return self:_replace_transient_pause_reasons(true)
end

function DownloadTask:on_resume()
    -- Wake is also a cleanup boundary: clear stale interaction/transition
    -- reasons together with suspend, but never override an explicit manual or
    -- recovery pause.
    return self:_replace_transient_pause_reasons(false)
end

function DownloadTask:stop_for_foreground(reason)
    reason=tostring(reason or "foreground_recovery")
    local task=self:_control_descriptor()
    if type(task)~="table" then return false end
    self:pause(reason)
    local cancel_path=tostring(task.cancel_path or "")
    if cancel_path=="" then return false end
    local wrote=U.atomic_write(cancel_path,"1",true)==true
    if self.job then self.job.cancel_requested_at=os.time() end
    logger.warn("[MiuRead][DownloadTask] stopped for foreground recovery",
        "reason=",reason,"pid=",tostring(task.pid or ""),"marker=",tostring(wrote))
    if self.job then self:_schedule() end
    return wrote
end

function DownloadTask:last_state()
    return self.job and self.job.last_progress_state or nil
end

local function read_json(path)
    local raw=U.read_file(path,true)
    if not raw then return nil end
    local ok,value=pcall(Json.decode,raw)
    if ok and type(value)=="table" then return value end
end

local function file_exists(path)
    return tostring(path or "")~="" and lfs.attributes(path)~=nil
end

local function file_mtime(path)
    local attr=lfs.attributes(path)
    return attr and tonumber(attr.modification or attr.change) or nil
end

local function process_exists(pid)
    pid=tonumber(pid)
    if not pid or pid<=1 then return false end
    local proc="/proc/"..tostring(pid)
    if lfs.attributes("/proc","mode")~="directory" then return nil end
    if lfs.attributes(proc,"mode")~="directory" then return false end
    local status,status_error=U.read_file(proc.."/status",true)
    if not status then
        logger.warn("[MiuRead][DownloadTask] process status unavailable",
            "pid=",tostring(pid),"error=",tostring(status_error))
        return nil
    end
    local state=status:match("[\r\n]State:%s*([A-Z])") or status:match("^State:%s*([A-Z])")
    if state=="Z" or state=="X" then return false end
    return true
end

local function usable_recovery_result(result)
    if type(result)~="table" or result.ok~=true or type(result.value)~="table" then return false end
    local record=result.value
    local path=record.pending_install==true and record.pending_file or record.file
    if not path or not file_exists(path) then return false end
    local size=U.file_size(path)
    return size==nil or size>0
end

local function diagnostic_append(path, lines)
    if not path or path=="" then return false end
    local parent=path:match("^(.*)/[^/]+$")
    if parent then U.mkdir(parent) end
    local file=io.open(path,"ab")
    if not file then return false end
    local text=type(lines)=="table" and table.concat(lines,"\n") or tostring(lines or "")
    local written=file:write(text,"\n")
    file:flush()
    file:close()
    return written~=nil
end

local function prune_diagnostics(directory, keep)
    keep=math.max(1,tonumber(keep) or 5)
    local rows={}
    if lfs.attributes(directory,"mode")~="directory" then return end
    for name in lfs.dir(directory) do
        if name:match("^download%-diagnostic%-.+%.txt$") then
            local path=directory.."/"..name
            rows[#rows+1]={path=path,mtime=file_mtime(path) or 0}
        end
    end
    table.sort(rows,function(a,b) return a.mtime>b.mtime end)
    for index=keep+1,#rows do os.remove(rows[index].path) end
end

function DownloadTask:_claim(pid)
    return U.atomic_write(self.owner_path,Json.encode({
        token=self.owner_token,pid=tonumber(pid),updated_at=os.time(),
    }),true)
end

function DownloadTask:_owns_job()
    local owner=read_json(self.owner_path)
    return owner and tostring(owner.token or "")==tostring(self.owner_token)
        and tonumber(owner.pid or 0)==tonumber(self.job and self.job.pid or 0)
end

function DownloadTask:descriptor()
    local job=self.job
    if not job then return nil end
    return {
        pid=job.pid,progress_path=job.progress_path,result_path=job.result_path,
        recovery_path=job.recovery_path,diagnostic_path=job.diagnostic_path,
        cancel_path=job.cancel_path,pause_path=job.pause_path,network_path=job.network_path,
        worker_settings_path=job.worker_settings_path,
        started_at=job.started_at,owner_token=self.owner_token,task_token=job.task_token,
        restart_count=tonumber(job.restart_count) or 0,
    }
end

function DownloadTask:_reset_device_timeout()
    if not self.keep_awake_enabled then return false end
    local powerd = Device and Device.powerd
    if powerd and type(powerd.resetT1Timeout) == "function" then
        local ok, err = pcall(powerd.resetT1Timeout, powerd)
        if not ok then logger.warn("[MiuRead][DownloadTask] Kindle T1 reset failed", tostring(err)) end
        return ok
    end
    return false
end

function DownloadTask:_hold_awake()
    if not self.keep_awake_enabled or self.standby_held then return end
    local ok, err = pcall(function() UIManager:preventStandby() end)
    if ok then
        self.standby_held = true
        local reset = self:_reset_device_timeout()
        logger.info("[MiuRead][DownloadTask] standby lock acquired", "t1_reset=", tostring(reset))
    else
        logger.warn("[MiuRead][DownloadTask] standby lock failed", tostring(err))
    end
end

function DownloadTask:_release_awake()
    if not self.standby_held then return end
    self.standby_held = false
    pcall(function() UIManager:allowStandby() end)
    logger.info("[MiuRead][DownloadTask] standby lock released")
end

function DownloadTask:available()
    return type(FFIUtil.runInSubProcess) == "function"
        and type(FFIUtil.isSubProcessDone) == "function"
end

function DownloadTask:busy()
    return self.job ~= nil
end

function DownloadTask:_schedule()
    if self.poll_task then return end
    local task
    task = function()
        if self.poll_task ~= task then return end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    local interval = self:is_paused() and self.paused_poll_interval
        or (self.backgrounded and self.background_poll_interval or self.foreground_poll_interval)
    UIManager:scheduleIn(interval, task)
end

function DownloadTask:_read_progress(job)
    local raw = U.read_file(job.progress_path, true)
    if not raw or raw == job.last_progress_raw then return false end
    local ok, state = pcall(Json.decode, raw)
    if ok and type(state) == "table" then
        if job.task_token and tostring(state.task_token or "")~=tostring(job.task_token) then
            job.token_mismatch=true
            logger.warn("[MiuRead][DownloadTask] progress task identity mismatch")
            return false
        end
        job.last_progress_raw = raw
        job.last_progress_state = state
        job.last_progress_at = tonumber(state.updated_at) or file_mtime(job.progress_path) or os.time()
        if state.stage=="waiting_network" or state.waiting_network==true then
            job.waiting_started_at=job.waiting_started_at or job.last_progress_at
        else
            job.waiting_started_at=nil
            job.last_effective_progress_at=job.last_progress_at
        end
        job.waiting_notified = false
        if self.keep_awake_enabled and not self.backgrounded and not self:is_paused()
            and not self.standby_held then self:_hold_awake() end
        if job.on_progress then job.on_progress(state) end
        return true
    end
    return false
end

function DownloadTask:_finish(job, forced_error)
    self:_read_progress(job)
    local raw = U.read_file(job.result_path, true)
    local result
    local result_source="none"

    if forced_error then
        result = {ok = false, error = forced_error}
        result_source="forced"
    else
        if raw then
            local decoded_ok,decoded=pcall(Json.decode,raw)
            if decoded_ok and type(decoded)=="table" then
                result=decoded
                result_source="result"
            else
                result_source="invalid_result"
            end
        end
        if not result then
            local recovery_raw=job.recovery_path and U.read_file(job.recovery_path,true) or nil
            if recovery_raw then
                local recovery_ok,recovered=pcall(Json.decode,recovery_raw)
                if recovery_ok and usable_recovery_result(recovered) then
                    result=recovered
                    result.recovered=true
                    result_source="recovery_file"
                end
            end
        end
        if not result then
            local state=job.last_progress_state
            local recovered=state and state.recovery_result
            if usable_recovery_result(recovered) then
                result=U.copy(recovered)
                result.recovered=true
                result_source="progress_recovery"
            end
        end
        if not result then
            local stage = job.last_progress_state and job.last_progress_state.stage
            local diagnostic=job.diagnostic_path and U.read_file(job.diagnostic_path,true) or ""
            if diagnostic:find("result_write_failed",1,true) then
                result = {ok = false, error = "无法保存下载结果，请检查设备剩余空间和存储权限。已完成的章节断点仍会保留。"}
            elseif diagnostic:find("child_fatal",1,true) then
                result = {ok = false, error = "下载进程发生内部异常，诊断信息已保留。已完成的章节断点不会丢失。"}
            elseif stage == "package" then
                result = {ok = false, error = "EPUB 生成进程被中断；原有完整书未被覆盖，已下载章节仍保存在断点缓存。请再次下载继续。"}
            elseif stage == "done" then
                result = {ok = false, error = "EPUB 已完成生成，但下载记录未能恢复。请检查存储空间后重新打开书架；断点与已生成文件不会主动删除。"}
            elseif result_source=="invalid_result" then
                result = {ok = false, error = "下载结果写入不完整，诊断信息已保留；已完成的章节断点不会丢失。"}
            else
                result = {ok = false, error = "下载进程被系统中断；已完成的下载进度会继续保留。"}
            end
        end
    end

    local succeeded=type(result)=="table" and result.ok==true
    local cancelled=forced_error=="下载已取消"
    if succeeded or cancelled then
        os.remove(job.progress_path)
        if job.diagnostic_path then os.remove(job.diagnostic_path) end
    else
        local state=job.last_progress_state or {}
        diagnostic_append(job.diagnostic_path,{
            "time="..tostring(os.date("%Y-%m-%d %H:%M:%S")),
            "event=parent_finish",
            "pid="..tostring(job.pid or ""),
            "result_source="..tostring(result_source),
            "stage="..tostring(state.stage or "unknown"),
            "message="..tostring(state.message or ""),
            "started_at="..tostring(job.started_at or ""),
            "last_progress_at="..tostring(job.last_progress_at or ""),
            "process_alive="..tostring(process_exists(job.pid)),
            "result_exists="..tostring(file_exists(job.result_path)),
            "recovery_exists="..tostring(job.recovery_path and file_exists(job.recovery_path) or false),
            "error="..tostring(type(result)=="table" and result.error or result or "unknown"),
        })
        prune_diagnostics(self.store.temp_dir,tonumber(Config.DOWNLOAD_DIAGNOSTIC_KEEP) or 5)
        os.remove(job.progress_path)
    end

    -- Result/recovery/settings files may contain account state. Always remove
    -- them after the parent has consumed the result; only the sanitized text
    -- diagnostic is kept for failed jobs.
    os.remove(job.result_path)
    if job.recovery_path then os.remove(job.recovery_path) end
    os.remove(job.cancel_path)
    if job.pause_path then os.remove(job.pause_path) end
    if job.network_path then os.remove(job.network_path) end
    if job.worker_settings_path then os.remove(job.worker_settings_path) end
    if self:_owns_job() then os.remove(self.owner_path) end
    self.job = nil
    self:_release_awake()
    if job.on_done then
        local callback_ok,callback_error=xpcall(function() job.on_done(result) end,debug.traceback)
        if not callback_ok then logger.warn("[MiuRead][DownloadTask] completion callback failed",tostring(callback_error)) end
    end
end

function DownloadTask:_restart_interrupted(job)
    if not job or job.cancel_requested_at then return false end
    local count=tonumber(job.restart_count) or 0
    local maximum=math.max(0,tonumber(Config.DOWNLOAD_AUTO_RESTARTS) or 2)
    if count>=maximum or type(job.restart_book)~="table" or tostring(job.restart_book.bookId or "")=="" then
        return false
    end
    local book=serializable_copy(job.restart_book)
    local options=serializable_copy(job.restart_options or {}) or {}
    local network_control=job.network_path and U.read_file(job.network_path,true) or nil
    network_control=tostring(network_control or ""):match("^%s*([%w_%-]+)")
    if network_control=="ipv4" then
        options.network_mode="ipv4"
        options.network_suggestion_silent=nil
    elseif network_control=="auto_silent" then
        options.network_mode="auto"
        options.network_suggestion_silent=true
    end
    local on_progress,on_done=job.on_progress,job.on_done
    local state=U.copy(job.last_progress_state or {})
    state.stage="restart"
    state.message="后台下载进程被系统中断，正在从断点自动恢复（"..tostring(count+1).."/"..tostring(maximum).."）"
    state.updated_at=os.time()
    state.restart_count=count+1
    if on_progress then pcall(on_progress,state) end

    diagnostic_append(job.diagnostic_path,{
        "time="..tostring(os.date("%Y-%m-%d %H:%M:%S")),
        "event=automatic_restart",
        "pid="..tostring(job.pid or ""),
        "stage="..tostring((job.last_progress_state or {}).stage or "unknown"),
        "restart_count="..tostring(count+1),
    })
    os.remove(job.progress_path)
    os.remove(job.result_path)
    if job.recovery_path then os.remove(job.recovery_path) end
    os.remove(job.cancel_path)
    if job.pause_path then os.remove(job.pause_path) end
    if job.network_path then os.remove(job.network_path) end
    if job.worker_settings_path then os.remove(job.worker_settings_path) end
    if self:_owns_job() then os.remove(self.owner_path) end
    self.job=nil
    self:_release_awake()
    local ok,err=self:start(book,options,on_progress,on_done,count+1)
    if not ok then
        logger.warn("[MiuRead][DownloadTask] automatic restart failed",tostring(err))
        if on_done then
            on_done({ok=false,error="后台下载进程被系统中断，自动恢复失败："..tostring(err).."。断点仍已保留。"})
        end
        return true
    end
    if on_progress then pcall(on_progress,state) end
    logger.warn("[MiuRead][DownloadTask] worker restarted from checkpoint",
        "attempt=",tostring(count+1),"book=",tostring(book.bookId or ""))
    return true
end

function DownloadTask:_poll()
    local job = self.job
    if not job then return end
    if not self:_owns_job() then
        logger.info("[MiuRead][DownloadTask] controller ownership transferred","pid=",tostring(job.pid))
        self.job=nil
        self:_release_awake()
        return
    end

    self:_read_progress(job)
    if job.token_mismatch then
        self:_finish(job,"后台下载任务身份不匹配；断点已保留，请重新开始下载。")
        return
    end
    if read_json(job.result_path) then self:_finish(job); return end

    local now=os.time()
    local stall_sleep=math.max(120,tonumber(Config.DOWNLOAD_BACKGROUND_STALL_SLEEP_SECONDS) or 300)
    local effective_activity=tonumber(job.last_effective_progress_at or job.started_at) or now
    local effective_idle=math.max(0,now-effective_activity)
    local waiting_since=tonumber(job.waiting_started_at)
    local waiting_too_long=waiting_since and now-waiting_since>=stall_sleep
    local stalled_too_long=effective_idle>=stall_sleep
    if not self:is_paused() and not waiting_too_long and not stalled_too_long then
        local keepalive_gap=self.backgrounded
            and math.max(8,tonumber(Config.DOWNLOAD_BACKGROUND_KEEPALIVE_SECONDS) or 12) or 5
        if not job.last_keepalive or now-job.last_keepalive>=keepalive_gap then
            job.last_keepalive=now
            if not self.standby_held then self:_hold_awake() end
            local reset=self:_reset_device_timeout()
            if reset then logger.dbg("[MiuRead][DownloadTask] Kindle T1 timer reset") end
        end
    elseif (waiting_too_long or stalled_too_long) and self.standby_held then
        self:_release_awake()
        logger.info("[MiuRead][DownloadTask] stalled download may sleep",
            "pid=",tostring(job.pid),"idle=",tostring(effective_idle),
            "waiting=",tostring(waiting_since and now-waiting_since or 0))
    end

    local alive=process_exists(job.pid)
    local done_ok,done=pcall(FFIUtil.isSubProcessDone,job.pid,false)
    if not done_ok then
        logger.warn("[MiuRead][DownloadTask] poll failed",tostring(done))
    end

    local activity=tonumber(job.last_progress_at or file_mtime(job.progress_path) or job.started_at) or now
    local idle=math.max(0,now-activity)
    local final_state=job.last_progress_state
    local recovery_ready=job.recovery_path and read_json(job.recovery_path) or nil
    local snapshot_ready=final_state and usable_recovery_result(final_state.recovery_result)
    if final_state and final_state.stage=="done" and idle>=3
        and (usable_recovery_result(recovery_ready) or snapshot_ready) then
        self:_finish(job)
        return
    end
    local running=alive==true or (alive==nil and done_ok and done==false)

    if running then
        job.dead_seen_at=nil
        if self:is_paused() then
            job.waiting_notified=false
            self:_release_awake()
            self:_schedule()
            return
        end
        job.unknown_seen_at=nil
        job.rechecking_notified=false
        if job.cancel_requested_at and now-job.cancel_requested_at>=8 then
            pcall(FFIUtil.terminateSubProcess,job.pid)
            self:_finish(job,"下载已取消")
            return
        end
        if idle>=120 and not job.waiting_notified then
            job.waiting_notified=true
            local state=U.copy(job.last_progress_state or {})
            state.waiting_network=true
            state.message="等待网络或服务器响应"
            state.updated_at=now
            if job.on_progress then job.on_progress(state) end
        end
        if effective_idle>=stall_sleep and self.standby_held then
            self:_release_awake()
            logger.info("[MiuRead][DownloadTask] standby lock released while stalled",
                "pid=",tostring(job.pid),"idle=",tostring(effective_idle),
                "stage=",tostring(job.last_progress_state and job.last_progress_state.stage or "unknown"))
        end
        self:_schedule()
        return
    end

    if job.cancel_requested_at then
        pcall(FFIUtil.terminateSubProcess,job.pid)
        self:_finish(job,"下载已取消")
        return
    end

    -- A completed recovery file or a completed progress snapshot is accepted
    -- only after the worker is no longer confirmed alive. This prevents a
    -- transient result-file failure from turning a completed EPUB into an
    -- error while avoiding premature cleanup of a still-running worker.
    if usable_recovery_result(recovery_ready) then
        self:_finish(job)
        return
    end
    if job.last_progress_state and job.last_progress_state.stage=="done" and idle>=3 then
        self:_finish(job)
        return
    end

    if alive==nil then
        job.unknown_seen_at=job.unknown_seen_at or now
        if not job.rechecking_notified then
            job.rechecking_notified=true
            local state=U.copy(job.last_progress_state or {})
            state.message="正在重新确认下载任务状态"
            state.updated_at=now
            if job.on_progress then job.on_progress(state) end
        end
        -- Unknown means unknown: Android may temporarily deny /proc status,
        -- and a recreated UI may no longer own waitpid(). Give both the last
        -- progress heartbeat and the process-state check enough time.
        if idle<60 or now-job.unknown_seen_at<120 then self:_schedule(); return end
        if done_ok and done==true and self:_restart_interrupted(job) then return end
        -- When /proc is unavailable and waitpid ownership was lost, wait longer
        -- before deciding the worker vanished. This avoids duplicate workers on
        -- Android while still recovering a truly dead task from its checkpoint.
        if idle<180 or now-job.unknown_seen_at<180 then self:_schedule(); return end
        if self:_restart_interrupted(job) then return end
        self:_finish(job)
        return
    end

    job.dead_seen_at=job.dead_seen_at or now
    if not job.rechecking_notified then
        job.rechecking_notified=true
        local state=U.copy(job.last_progress_state or {})
        state.message="下载进程已停止，正在检查已完成内容"
        state.updated_at=now
        if job.on_progress then job.on_progress(state) end
    end
    -- Do not turn a short /proc race into a duplicate worker. A real dead
    -- process must remain absent for 30 seconds and make no progress for 20.
    if now-job.dead_seen_at<30 or idle<20 then self:_schedule(); return end
    if self:_restart_interrupted(job) then return end
    self:_finish(job)
end

function DownloadTask:cancel()
    local job = self.job
    if not job or job.cancel_requested_at or not self:_owns_job() then return end
    job.cancel_requested_at = os.time()
    self.pause_reasons={}
    if job.pause_path then os.remove(job.pause_path) end
    U.atomic_write(job.cancel_path, "1", true)
end

function DownloadTask:attach(descriptor,on_progress,on_done,restart_book,restart_options)
    if self.job then return false,"已有下载任务正在运行" end
    if not self:available() then return false,"当前 KOReader 不支持下载子进程" end
    descriptor=type(descriptor)=="table" and descriptor or nil
    local pid=descriptor and tonumber(descriptor.pid)
    if not pid or not descriptor.progress_path or not descriptor.result_path
        or not descriptor.cancel_path then return false,"下载任务记录不完整" end
    if not descriptor.pause_path or tostring(descriptor.pause_path)=="" then
        -- A pre-beta.10 worker cannot obey suspend barriers. Stop it cleanly
        -- instead of reattaching an unsafe process; its chapter checkpoint is
        -- retained and the user can continue the same download afterwards.
        U.atomic_write(descriptor.cancel_path,"1",true)
        return false,"旧版后台任务已安全停止；断点已保留，请继续下载"
    end
    self.keep_awake_enabled=self.store:preferences().download_keep_awake~=false
    local recovery_path=descriptor.recovery_path
        or tostring(descriptor.result_path):gsub("download%-result%-","download-recovery-")
    local diagnostic_path=descriptor.diagnostic_path
        or tostring(descriptor.result_path):gsub("download%-result%-","download-diagnostic-"):gsub("%.json$",".txt")
    self.job={
        pid=pid,progress_path=descriptor.progress_path,result_path=descriptor.result_path,
        recovery_path=recovery_path,diagnostic_path=diagnostic_path,
        cancel_path=descriptor.cancel_path,pause_path=descriptor.pause_path,network_path=descriptor.network_path,
        worker_settings_path=descriptor.worker_settings_path,
        on_progress=on_progress,on_done=on_done,last_progress_raw=nil,last_progress_state=nil,
        last_progress_at=nil,last_effective_progress_at=nil,waiting_started_at=nil,last_keepalive=0,started_at=descriptor.started_at,dead_seen_at=nil,
        unknown_seen_at=nil,waiting_notified=false,rechecking_notified=false,
        task_token=descriptor.task_token,
        restart_count=tonumber(descriptor.restart_count) or 0,
        restart_book=serializable_copy(restart_book),
        restart_options=serializable_copy(restart_options),
    }
    self.backgrounded=true
    self.pause_reasons=self:_marker_reasons(self.job.pause_path)
    self:_read_progress(self.job)
    if self.job.token_mismatch then
        self.job=nil
        return false,"后台下载任务身份不匹配"
    end
    local done_ok,done=pcall(FFIUtil.isSubProcessDone,pid,false)
    local alive=process_exists(pid)
    local result_ready=read_json(self.job.result_path)
    local recovery_ready=self.job.recovery_path and read_json(self.job.recovery_path) or nil
    local progress_ready=self.job.last_progress_state
    local completed_snapshot=progress_ready and progress_ready.stage=="done"
        and usable_recovery_result(progress_ready.recovery_result)
    -- A finished child without a consumable result is a stale task record, not
    -- a running task.  Do not attach it and automatically spawn a duplicate
    -- worker after KOReader starts (especially while the user is reading).
    if done_ok and done==true and alive~=true
        and not result_ready and not usable_recovery_result(recovery_ready)
        and not completed_snapshot then
        self.job=nil
        return false,"上次后台下载进程已经结束；断点已保留，请手动继续下载"
    end
    if not done_ok and alive==nil then
        logger.warn("[MiuRead][DownloadTask] attached with unknown process state",
            "pid=",tostring(pid),"error=",tostring(done))
    end
    self:_claim(pid)
    self:_release_awake()
    logger.info("[MiuRead][DownloadTask] attached","pid=",tostring(pid),
        "done=",tostring(done_ok and done or "unknown"),"alive=",tostring(alive))
    if result_ready or usable_recovery_result(recovery_ready) or completed_snapshot then
        local attached_job=self.job
        UIManager:scheduleIn(0,function()
            if self.job==attached_job and self:_owns_job() then self:_finish(attached_job) end
        end)
    else
        if alive==false then self.job.dead_seen_at=os.time() end
        self:_schedule()
    end
    return true
end

function DownloadTask:start(book, options, on_progress, on_done, restart_count)
    if self.job then return false, "已有下载任务正在运行" end
    if not self:available() then return false, "当前 KOReader 不支持下载子进程" end

    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
    local progress_path = self.store.temp_dir .. "/download-progress-" .. stamp .. ".json"
    local result_path = self.store.temp_dir .. "/download-result-" .. stamp .. ".json"
    local recovery_path = self.store.temp_dir .. "/download-recovery-" .. stamp .. ".json"
    local diagnostic_path = self.store.temp_dir .. "/download-diagnostic-" .. stamp .. ".txt"
    local cancel_path = self.store.temp_dir .. "/download-cancel-" .. stamp
    local pause_path = self.store.temp_dir .. "/download-pause-" .. stamp .. ".json"
    local network_path = self.store.temp_dir .. "/download-network-" .. stamp
    local worker_settings_path = self.store.temp_dir .. "/download-settings-" .. stamp .. ".lua"
    self.store:flush()
    local copied, copy_error = U.copy_file(self.store.settings_path, worker_settings_path)
    if not copied then return false, "无法建立安全下载状态副本：" .. tostring(copy_error or "未知错误") end
    local worker_data_dir = self.store.data_dir
    local task_token = stamp .. "-" .. tostring(math.random(100000,999999))
    local clean_book = serializable_copy(book)
    local clean_options = serializable_copy(options or {})
    clean_options.download_run_id=tostring(clean_options.download_run_id or task_token)
    clean_options.reader_active_path="/tmp/miuread-reader-active.flag"
    clean_options.reader_busy_path="/tmp/miuread-reader-busy.until"
    clean_options.pause_path=pause_path
    clean_options.network_mode=tostring(clean_options.network_mode or "auto")=="ipv4" and "ipv4" or "auto"
    clean_options.network_mode_path=network_path
    clean_options.performance_mode_path=Config.LIGHTWEIGHT_MODE_FLAG
    local initial_network_control=clean_options.network_suggestion_silent==true and "auto_silent" or clean_options.network_mode
    local network_written,network_error=U.atomic_write(network_path,initial_network_control,true)
    if not network_written then
        os.remove(worker_settings_path)
        return false,"无法建立下载网络控制状态："..tostring(network_error or "未知错误")
    end
    local start_auth=self.store:auth()
    local start_account=type(start_auth.account)=="table" and start_auth.account or {}
    local auth_snapshot={
        login_session_id=tostring(start_auth.login_session_id or ""),
        vid=tostring(start_account.vid or ""),
        logged_at=tonumber(start_account.logged_at or 0) or 0,
        ticket_updated_at=tonumber(start_auth.ticket_updated_at or 0) or 0,
    }
    self.keep_awake_enabled = self.store:preferences().download_keep_awake ~= false
    clean_options.cancelled = nil

    local child = function()
        lower_worker_priority()
        local Store = require("miuread.store")
        local Http = require("miuread.http")
        local Api = require("miuread.api")
        local Reader = require("miuread.content_reader")
        local Library = require("miuread.library")
        local Annotations = require("miuread.annotations")
        local Downloader = require("miuread.downloader")
        local JsonChild = require("miuread.json")
        local UChild = require("miuread.util")
        local LoggerChild = require("logger")
        local current_stage="bootstrap"
        local last_emitted_state={}
        local network_suggestion_detail

        local function write_direct(path,data)
            local file,open_error=io.open(path,"wb")
            if not file then return nil,open_error end
            local written,write_error=file:write(data or "")
            local flushed,flush_error=file:flush()
            file:close()
            if not written then return nil,write_error end
            if flushed==nil then return nil,flush_error end
            local size=UChild.file_size(path)
            if size and size~=#(data or "") then return nil,"written file size mismatch" end
            return true
        end

        local function write_safely(path,data)
            local errors={}
            for attempt=1,2 do
                local ok,err=UChild.atomic_write(path,data,true)
                if ok and UChild.file_exists(path) then return true,"atomic" end
                errors[#errors+1]="atomic"..tostring(attempt)..":"..tostring(err or "missing after write")
            end
            local ok,err=write_direct(path,data)
            if ok then return true,"direct" end
            errors[#errors+1]="direct:"..tostring(err)
            return nil,table.concat(errors,"; ")
        end

        local function append_diagnostic(event,message)
            local file=io.open(diagnostic_path,"ab")
            if not file then return false end
            file:write("time=",tostring(os.date("%Y-%m-%d %H:%M:%S")),"\n")
            file:write("event=",tostring(event or "unknown"),"\n")
            file:write("stage=",tostring(current_stage or "unknown"),"\n")
            local pid_value=""
            if type(FFIUtil.getpid)=="function" then
                local pid_ok,pid_or_error=pcall(FFIUtil.getpid)
                if pid_ok then pid_value=pid_or_error end
            end
            file:write("pid=",tostring(pid_value or ""),"\n")
            file:write("message=",tostring(message or ""):gsub("[\r\n]+"," | "),"\n---\n")
            file:flush()
            file:close()
            return true
        end

        local function write_json(path,value,label)
            local encoded_ok,encoded=pcall(JsonChild.encode,value)
            if not encoded_ok then
                append_diagnostic(tostring(label).."_encode_failed",encoded)
                return nil,"JSON encode failed: "..tostring(encoded)
            end
            local wrote,mode_or_error=write_safely(path,encoded)
            if not wrote then
                append_diagnostic(tostring(label).."_write_failed",mode_or_error)
                return nil,mode_or_error
            end
            return true,mode_or_error
        end

        local function emit(state)
            state = state or {}
            current_stage=tostring(state.stage or current_stage)
            if network_suggestion_detail then
                local control=UChild.read_file(network_path,true)
                control=tostring(control or ""):match("^%s*([%w_%-]+)") or "auto"
                if control=="ipv4" or control=="auto_silent" then
                    network_suggestion_detail=nil
                else
                    state.network_ipv4_suggested=true
                    state.network_ipv4_recovery=network_suggestion_detail.recovery_ipv4==true or nil
                    state.network_auto_unavailable=network_suggestion_detail.auto_unavailable==true or nil
                    state.network_auto_seconds=tonumber(network_suggestion_detail.auto_seconds)
                    state.network_ipv4_seconds=tonumber(network_suggestion_detail.ipv4_seconds)
                    state.network_gain_seconds=tonumber(network_suggestion_detail.gain_seconds)
                    state.network_trigger_baseline=tonumber(network_suggestion_detail.trigger_baseline)
                end
            end
            state.task_token = task_token
            state.updated_at = os.time()
            last_emitted_state=serializable_copy(state) or {}
            local wrote,write_error=write_json(progress_path,state,"progress")
            if not wrote then LoggerChild.warn("[MiuRead][DownloadTask] progress write failed",tostring(write_error)) end
            return wrote
        end

        local function display_error(raw)
            raw=tostring(raw or "未知下载错误")
            local display=raw:match("^(.-)\nstack traceback:") or raw
            display=display:gsub("^.-%.lua:%d+:%s*", "")
            if raw:lower():find("download cancelled",1,true) then
                return "下载已暂停，可稍后继续"
            end
            if raw:lower():find("not enough memory", 1, true) then
                return "设备内存不足，未生成新的 EPUB。原有完整书未被覆盖，已完成章节仍保存在断点缓存；再次下载时会继续。"
            end
            if raw:find("[MiuReadRateLimit]", 1, true)
                or raw:lower():find("hit api rate limit", 1, true) then
                return "微信读书暂时限制了请求频率。插件已停止继续请求；已完成章节和断点都已保留，请稍后继续下载。"
            end
            return display
        end

        local function run_download()
            local ok, value = xpcall(function()
                local store = Store:new{
                    settings_path = worker_settings_path,
                    data_dir = worker_data_dir,
                    isolated = true,
                }
                local http = Http:new(store)
                http:set_download_network_policy{
                    mode=clean_options.network_mode,
                    mode_path=network_path,
                }
                local reader = Reader:new(http, store)
                local api = Api:new(http, store, reader)
                local library = Library:new(api, http, store)
                local annotations = Annotations:new(api)
                local downloader = Downloader:new(reader, api, annotations, store, http)
                clean_options.cancelled = function()
                    return UChild.file_exists(cancel_path)
                end
                -- The parent and ReaderUI instances coordinate through a shared
                -- pause marker. Read it in the child itself; otherwise only the
                -- parent poller pauses while the download process keeps working.
                clean_options.paused = function()
                    return UChild.file_exists(pause_path)
                end
                http.cancelled = clean_options.cancelled
                http.rate_limit_retries = 3
                http.min_weread_interval = 0.45
                local last_progress_percent = 0
                http.on_rate_limit = function(remaining, attempt, maximum, code)
                    emit{
                        stage = "rate_limit",
                        current = 0,
                        total = 0,
                        percent = last_progress_percent,
                        chapter = clean_book.title or "",
                        message = "微信读书请求过快，等待 " .. tostring(remaining)
                            .. " 秒后自动继续（" .. tostring(attempt) .. "/" .. tostring(maximum) .. "）",
                        rate_limit_code = tostring(code or ""),
                        wait_seconds = tonumber(remaining),
                    }
                end
                http.on_network_suggestion = function(detail)
                    network_suggestion_detail=serializable_copy(detail or {}) or {}
                    emit(serializable_copy(last_emitted_state) or {})
                end
                emit{stage = "prepare", current = 0, total = 1, chapter = clean_book.title or "",
                    message = "正在准备下载"}
                local record = downloader:book(clean_book, clean_options, function(stage, current, total, chapter, detail)
                    detail = detail or {}
                    local percent
                    if stage == "package" then
                        percent = 0.96
                    elseif total and total > 0 then
                        local base = (math.max(1, current) - 1) / total
                        local step = 0
                        if stage == "resume" then step = 0.90
                        elseif stage == "content" then step = 0.08
                        elseif stage == "underlines" then step = 0.35
                        elseif stage == "thoughts" then step = 0.55
                        elseif stage == "footnotes" then step = 0.75
                        elseif stage == "images" then step = 0.88 end
                        percent = math.min(0.94, base * 0.94 + step / total)
                    end
                    if stage == "package" then
                        detail.message = detail.message or "正在低内存生成并验证 EPUB"
                    end
                    if percent ~= nil then last_progress_percent = percent end
                    emit{
                        stage = stage,
                        current = current,
                        total = total,
                        chapter = chapter,
                        batch = detail.batch,
                        batch_total = detail.batches,
                        underlines = detail.underlines,
                        thoughts = detail.thoughts,
                        percent = percent,
                        message = detail.message,
                        waiting_network = detail.waiting_network==true or stage=="waiting_network" or nil,
                    }
                end)
                return {
                    record = record,
                    auth = store:auth(),
                    session = store:session(clean_book.bookId),
                }
            end, debug.traceback)

            local payload
            if ok then
                payload = {
                    ok = true,
                    value = serializable_copy(value and value.record),
                    auth = serializable_copy(value and value.auth),
                    auth_snapshot = serializable_copy(auth_snapshot),
                    session = serializable_copy(value and value.session),
                }
                -- Save the same completed payload independently before the
                -- normal result file. The parent can recover from either file
                -- or from the final progress snapshot.
                local recovery_ok,recovery_error=write_json(recovery_path,payload,"recovery")
                emit{stage = "done", current = 1, total = 1, percent = 1,
                    chapter = clean_book.title or "",
                    recovery_result = {ok=true,value=payload.value},
                    recovery_saved = recovery_ok==true, recovery_error = recovery_ok and nil or tostring(recovery_error)}
            else
                local raw_error = tostring(value)
                LoggerChild.warn("[MiuRead][DownloadTask] child failed", raw_error)
                local friendly=display_error(raw_error)
                emit{stage = UChild.file_exists(cancel_path) and "cancelled" or "error", message = friendly}
                payload = {ok = false, error = friendly}
                append_diagnostic("download_failed",raw_error)
            end

            local result_ok,result_error=write_json(result_path,payload,"result")
            if not result_ok then
                append_diagnostic("result_write_failed",result_error)
                if payload.ok==true then
                    emit{stage = "done", current = 1, total = 1, percent = 1,
                        chapter = clean_book.title or "",
                        recovery_result = {ok=true,value=payload.value},
                        result_write_failed = true, message = "正在恢复已完成的下载结果"}
                else
                    emit{stage = "error", message = payload.error, result_write_failed = true}
                end
            end
        end

        local child_ok,child_error=xpcall(run_download,debug.traceback)
        if not child_ok then
            local friendly=display_error(child_error)
            LoggerChild.warn("[MiuRead][DownloadTask] child fatal",tostring(child_error))
            append_diagnostic("child_fatal",child_error)
            write_json(result_path,{ok=false,error=friendly},"emergency_result")
            emit{stage="error",message=friendly,fatal=true}
        end
    end

    os.remove(pause_path)
    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then
        os.remove(worker_settings_path)
        os.remove(pause_path)
        os.remove(network_path)
        return false, tostring(err or pid or "无法启动下载子进程")
    end

    self.job = {
        pid = pid,
        progress_path = progress_path,
        result_path = result_path,
        recovery_path = recovery_path,
        diagnostic_path = diagnostic_path,
        cancel_path = cancel_path,
        pause_path = pause_path,
        network_path = network_path,
        network_mode = clean_options.network_mode,
        worker_settings_path = worker_settings_path,
        on_progress = on_progress,
        on_done = on_done,
        last_progress_raw = nil,
        last_progress_state = nil,
        last_progress_at = nil,
        last_effective_progress_at = nil,
        waiting_started_at = nil,
        last_keepalive = 0,
        dead_seen_at = nil,
        unknown_seen_at = nil,
        waiting_notified = false,
        rechecking_notified = false,
        task_token = task_token,
        restart_count = tonumber(restart_count) or 0,
        restart_book = serializable_copy(book),
        restart_options = serializable_copy(clean_options),
        started_at = os.time(),
    }
    self:_claim(pid)
    self.pause_reasons={}
    self.backgrounded = false
    self:_hold_awake()
    logger.info("[MiuRead][DownloadTask] started", "pid=", tostring(pid))
    self:_schedule()
    return true
end

return DownloadTask
