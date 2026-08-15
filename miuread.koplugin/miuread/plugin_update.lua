-- MiuRead update / about controller, split from main.lua.
-- Installs its Plugin methods onto the main Plugin class in the same way
-- plugin_maintenance.lua does.
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local Config = require("miuread.config")
local U = require("miuread.util")
local GestureBridge = require("miuread.gesture_bridge")
local RawButtonDialog = require("ui/widget/buttondialog")
local RawConfirmBox = require("ui/widget/confirmbox")
local RawPathChooser = require("ui/widget/pathchooser")

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ButtonDialog = gesture_aware_class(RawButtonDialog, {_miuread_transient=true, _miuread_modal_surface=true})
local ConfirmBox = gesture_aware_class(RawConfirmBox, {_miuread_transient=true, _miuread_modal_surface=true})
local PathChooser = gesture_aware_class(RawPathChooser, {_miuread_transient=true, _miuread_modal_surface=true})

local function home_exiting()
    local session = rawget(_G, "__MIUREAD_HOME_SESSION")
    return type(session) == "table" and session.exiting == true
end

local Plugin = {}

function Plugin:_download_dir_path()
    local custom=U.trim((self.store:preferences() or {}).download_dir or "")
    if custom~="" then return custom end
    return self.store.default_books_dir
end
function Plugin:_download_dir_label()
    local path=self:_download_dir_path()
    if path==self.store.default_books_dir then return "默认 · "..tostring(path) end
    return tostring(path)
end
function Plugin:_validate_download_dir(path)
    path=U.trim(path)
    if path=="" or path:sub(1,1)~="/" then return nil,"路径无效" end
    local attr=lfs.attributes(path)
    if not attr or attr.mode~="directory" then return nil,"文件夹不存在" end
    local probe=path.."/.miuread-write-test-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local f=io.open(probe,"wb")
    if not f then return nil,"该文件夹不可写" end
    f:write("ok"); f:close(); os.remove(probe)
    return true
end
function Plugin:directory_dialog()
    local current=self:_download_dir_path()
    if lfs.attributes(current,"mode")~="directory" then
        if lfs.attributes("/mnt/us/documents","mode")=="directory" then current="/mnt/us/documents"
        elseif lfs.attributes("/mnt/us","mode")=="directory" then current="/mnt/us"
        else current="/" end
    end
    local chooser=PathChooser:new{
        title="选择下载文件夹",
        select_directory=true,
        select_file=false,
        show_files=false,
        path=current,
        onConfirm=function(path)
            local ok,err=self:_validate_download_dir(path)
            if not ok then self:info("无法使用此文件夹：\n"..tostring(err)); return end
            local old=self:_download_dir_path()
            local p=self.store:preferences(); p.download_dir=path; self.store:save_preferences(p)
            local note="下载目录已设置为：\n"..tostring(path)
            if old~=path then note=note.."\n\n只影响以后下载的书籍；已下载内容保留在原位置。" end
            self:info(note)
        end,
    }
    UIManager:show(chooser)
end

function Plugin:_update_preferences()
    local p=self.store:preferences()
    p.update=U.merge({manifest=Config.UPDATE_MANIFEST,auto_check=true,interval=Config.AUTO_UPDATE_INTERVAL,
        last_attempt_at=0,last_success_at=0,last_prompted_version="",restart_mode="ask"},p.update or {})
    return p,p.update
end
function Plugin:_save_update_preferences(update)
    local p=self.store:preferences(); p.update=U.merge(p.update or {},update or {})
    self:_save_ui_preferences(p,"update_preferences")
end
function Plugin:_update_interval_label(seconds)
    seconds=tonumber(seconds) or Config.AUTO_UPDATE_INTERVAL
    if seconds<=86400 then return "每天" end
    if seconds<=3*86400 then return "每 3 天" end
    return "每 7 天"
end
function Plugin:update_frequency_menu()
    local values={{86400,"每天"},{3*86400,"每 3 天"},{7*86400,"每 7 天"}}
    local rows={}
    for _,entry in ipairs(values) do
        local seconds,label=entry[1],entry[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function()
            local _,u=self:_update_preferences(); return tonumber(u.interval)==seconds
        end,callback=function()
            local _,u=self:_update_preferences(); u.interval=seconds; self:_save_update_preferences(u); self:toast("更新检查频率已设为"..label)
        end}
    end
    return rows
end
function Plugin:update_restart_menu()
    local choices={{"ask","安装后询问（推荐）"},{"auto","安装后自动重启"},{"never","稍后手动重启"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function()
            local _,u=self:_update_preferences(); return tostring(u.restart_mode)==key
        end,callback=function()
            local _,u=self:_update_preferences(); u.restart_mode=key; self:_save_update_preferences(u); self:toast("更新完成后："..label)
        end}
    end
    return rows
end
function Plugin:update_settings_menu()
    local _,update=self:_update_preferences()
    return {
        {text="自动检查更新",checked_func=function()
            local _,u=self:_update_preferences(); return u.auto_check~=false
        end,keep_menu_open=true,callback=function()
            local _,u=self:_update_preferences(); u.auto_check=u.auto_check==false; self:_save_update_preferences(u)
        end},
        {text="检查频率 · "..self:_update_interval_label(update.interval),sub_item_table_func=function() return self:update_frequency_menu() end},
        {text="安装完成后 · "..(update.restart_mode=="auto" and "自动重启" or (update.restart_mode=="never" and "稍后手动重启" or "询问是否重启")),sub_item_table_func=function() return self:update_restart_menu() end},
        {text="检查"..tostring(Config.UPDATE_CHANNEL_LABEL).."更新",callback=self:safe("update",function() self:check_update(false) end)},
        {text="当前运行版本 · "..tostring(self.version),enabled=false},
        {text="更新通道 · "..tostring(Config.UPDATE_CHANNEL_LABEL),enabled=false},
        {text="当前版本 · AGPL-3.0-only",enabled=false},
    }
end
function Plugin:_restart_koreader(source)
    if self._koreader_restart_requested then return true end
    if (self.download_task and self.download_task:busy()) or self._download_runtime~=nil then
        self:info("当前任务尚未完成，暂不重启。\n\n请等待任务结束，或先在下载管理中取消任务。")
        return false
    end
    if #self.store:download_queue()>0 then
        self:info("当前还有一个排队任务，暂不重启。\n\n请先取消排队任务或等待它完成。")
        return false
    end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then
        self:info("缓存任务尚未完成，暂不重启。")
        return false
    end
    if Device and Device.isAndroid and Device:isAndroid() then
        self:info("Android 版 KOReader 无法保证由插件自动重新启动。\n\n请关闭并重新打开 KOReader。")
        return false
    end
    if Device and type(Device.canRestart)=="function" and not Device:canRestart() then
        self:info("当前设备不支持由 KOReader 自动重新启动。\n\n请关闭并重新打开 KOReader。")
        return false
    end

    self._koreader_restart_requested=true
    source=tostring(source or "manual")
    logger.info("[MiuRead][Restart] KOReader restart requested","source=",source,"expected_exit=85")

    -- Save everything before asking KOReader to restart. Do not call
    -- the native menu close helper here: on a replacement home it closes the native
    -- root first, which can empty UIManager's stack and turn the request into
    -- a normal exit (code 0) before the Restart event gets handled.
    pcall(function() self:_flush_home_preferences() end)
    pcall(function() self:onFlushSettings() end)
    if Device and Device.saveSettings then pcall(Device.saveSettings,Device) end

    local dispatched,dispatch_error=pcall(function()
        UIManager:broadcastEvent(Event:new("Restart"))
    end)
    if not dispatched then
        logger.warn("[MiuRead][Restart] Restart event failed",tostring(dispatch_error))
    end

    -- KOReader's launcher recognises exit code 85 as "restart KOReader".
    -- Keep a direct fallback because custom full-screen homes may leave no
    -- native root widget to consume the broadcast event. This never calls the
    -- device Reboot event and therefore cannot request a Kindle/Kobo reboot.
    if tonumber(UIManager._exit_code)~=85 then
        logger.info("[MiuRead][Restart] enforcing KOReader exit code 85")
        if not home_exiting() then self:_begin_koreader_exit("restart fallback") end
        UIManager:quit(85)
    end
    return true
end
function Plugin:_show_update_complete_dialog(version,allow_restart)
    if self._update_complete_dialog then
        pcall(function() UIManager:close(self._update_complete_dialog) end)
        self._update_complete_dialog=nil
    end
    local dialog
    local buttons={}
    if allow_restart~=false then
        buttons[#buttons+1]={{text="立即重启 KOReader",callback=function()
            -- Keep this dialog on the stack until the restart request has
            -- been accepted. It prevents an empty-stack normal exit.
            self:_restart_koreader("update-confirmed")
        end}}
    end
    buttons[#buttons+1]={{text="稍后重启",callback=function()
        UIManager:close(dialog)
        self._update_complete_dialog=nil
        self:toast("新版本将在下次启动 KOReader 时生效",3)
    end}}
    dialog=ButtonDialog:new{
        title="更新文件已安装："..tostring(version).."。\n\n当前仍在运行 "..tostring(self.version).."，重启 KOReader 后才会切换到新版本。",
        title_align="center",
        buttons=buttons,
    }
    self._update_complete_dialog=dialog
    UIManager:show(dialog)
end
function Plugin:_after_update_installed(manifest)
    local _,update=self:_update_preferences()
    local version=tostring(manifest and manifest.version or "新版本")
    logger.info("[MiuRead][Updater] presenting installed update","version=",version,"restart_mode=",tostring(update.restart_mode))
    if update.restart_mode=="never" then
        self:_show_update_complete_dialog(version,false)
    elseif update.restart_mode=="auto" then
        self:status_toast("更新完成","正在重启 KOReader",3)
        UIManager:scheduleIn(.35,function() self:_restart_koreader("update-auto") end)
    else
        self:_show_update_complete_dialog(version,true)
    end
end
function Plugin:_present_update(manifest,automatic)
    if manifest.current then
        if not automatic then self:info("当前已是最新版本\n\n当前版本："..tostring(self.version)) end
        return
    end
    local _,update=self:_update_preferences()
    if automatic and tostring(update.last_prompted_version or "")==tostring(manifest.version or "") then return end
    update.last_prompted_version=tostring(manifest.version or "")
    self:_save_update_preferences(update)
    local text="发现"..tostring(Config.UPDATE_CHANNEL_LABEL).."版本 "..tostring(manifest.version)
    local notes=tostring(manifest.summary or "")
    if notes=="" then notes=tostring(manifest.notes or "") end
    if notes~="" then
        text=text.."\n\n更新内容\n"..notes
    end
    text=text.."\n\n是否下载并安装"
    UIManager:show(ConfirmBox:new{text=text,ok_text="下载并安装",ok_callback=function()
        if not self:is_online() then self:info("当前网络不可用"); return end
        if not self.updater_async or not self.updater_async:available() then
            self:info("当前环境无法在后台下载安装包，请稍后重试。")
            return
        end
        if self.updater_async:busy() then self:toast("更新任务正在进行",2); return end
        self:status_toast("更新","正在后台下载并校验安装包……",4)
        local started,err=self.updater_async:run("update-download",function()
            return self.updater:download(manifest)
        end,function(result)
            if not result or result.ok~=true or tostring(result.value or "")=="" then
                self:info(self:_friendly_action_error(result and result.error or "后台下载失败","更新下载","update"))
                return
            end
            local path=tostring(result.value)
            self:status_toast("更新","安装包校验完成，正在安装……",4)
            UIManager:nextTick(function()
                local ok,install_err=self.updater:install(path,manifest)
                if ok then self:_after_update_installed(manifest)
                else self:info(self:_friendly_action_error(install_err,"更新安装","update")) end
            end)
        end,210)
        if not started then self:info(self:_friendly_action_error(err or "后台任务不可用","更新下载启动","update")) end
    end})
end
function Plugin:_run_update_check(automatic,on_done)
    if not self.updater_async or not self.updater_async:available() then
        return false,"后台更新检查不可用"
    end
    if self.updater_async:busy() then
        return false,"已有更新任务正在运行"
    end
    local started,err=self.updater_async:run(automatic and "auto-update-check" or "update-check",function()
        local manifest,check_err=self.updater:check()
        if not manifest then error(tostring(check_err or "无法读取更新清单")) end
        return manifest
    end,function(result)
        if result and result.ok==true and type(result.value)=="table" then
            if on_done then on_done(result.value,nil) end
        else
            if on_done then on_done(nil,tostring(result and result.error or "后台更新检查失败")) end
        end
    end,70)
    if not started then return false,tostring(err or "后台任务不可用") end
    return true
end

function Plugin:maybe_auto_check_update(force)
    local _,update=self:_update_preferences()
    if not force and update.auto_check==false then return false end
    if self._auto_update_check_running then return false end
    local now=os.time()
    local interval=math.max(21600,tonumber(update.interval) or Config.AUTO_UPDATE_INTERVAL)
    local last=tonumber(update.last_attempt_at) or 0
    if not force and now-last<interval then return false end
    if not self:is_online() then return false end
    if self.updater_async and self.updater_async:busy() then return false end
    self._auto_update_check_running=true
    update.last_attempt_at=now
    self:_save_update_preferences(update)
    local started,start_err=self:_run_update_check(true,function(manifest,err)
        self._auto_update_check_running=false
        local _,fresh=self:_update_preferences()
        if manifest then
            fresh.last_success_at=os.time()
            self:_save_update_preferences(fresh)
            self:_present_update(manifest,true)
        else
            logger.warn("[MiuRead][Updater] passive check failed",tostring(err))
            fresh.last_attempt_at=os.time()-math.max(0,interval-(Config.AUTO_UPDATE_RETRY_INTERVAL or 21600))
            self:_save_update_preferences(fresh)
        end
    end)
    if not started then
        self._auto_update_check_running=false
        logger.warn("[MiuRead][Updater] passive check not started",tostring(start_err or "unknown"))
    end
    return started
end
function Plugin:check_update(automatic)
    if automatic then return self:maybe_auto_check_update(true) end
    if not self:is_online() then self:info("当前网络不可用"); return false end
    if self.updater_async and self.updater_async:busy() then self:toast("更新任务正在进行",2); return false end
    self:status_toast("更新","正在后台检查"..tostring(Config.UPDATE_CHANNEL_LABEL).."版本……",3)
    local started,start_err=self:_run_update_check(false,function(manifest,err)
        local _,update=self:_update_preferences()
        update.last_attempt_at=os.time()
        if manifest then update.last_success_at=os.time() end
        self:_save_update_preferences(update)
        if not manifest then self:info("检查更新失败：\n"..tostring(err)); return end
        self:_present_update(manifest,false)
    end)
    if not started then self:info("无法启动后台更新检查：\n"..tostring(start_err or "后台任务不可用")) end
    return started
end
function Plugin:show_about()
    local memory_note=""
    local memory_status=self.memory_mode:status()
    if memory_status.enabled then
        memory_note="\n\n低内存保护当前已开启。卸载觅阅前，请在“性能与兼容性”中恢复缓存设置。"
    elseif memory_status.residual then
        memory_note="\n\n检测到外部或遗留的低内存设置，可在“性能与兼容性”中检查并恢复。"
    end
    self:info(Config.NAME.." "..self.version
        .."\n\n为 KOReader 提供微信读书书架、书籍下载、阅读同步与本地书籍管理。"
        .."\n\n支持阅读进度、划线、想法、评论及阅读记录等功能。"
        .."\n\n许可证：AGPL-3.0-only。"
        ..memory_note
        .."\n\n非官方社区项目，与微信读书及 KOReader 无官方隶属或合作关系。")
end


local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
