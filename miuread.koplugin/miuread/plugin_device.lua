-- MiuRead device / home quick control controller, split from main.lua.
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local U = require("miuread.util")
local Text = require("miuread.text")
local Lazy = require("miuread.lazy")
local ActionSheet = Lazy("miuread.action_sheet")
local HomeQuickPanel = Lazy("miuread.home_quick_panel")
local HomeView = Lazy("miuread.home_view")
local Orientation = require("miuread.orientation_controller")
local HomeData = require("miuread.home_data")
local TimeZone = require("miuread.timezone")
local PluginSettings = require("miuread.plugin_settings")
local GestureBridge = require("miuread.gesture_bridge")
local RawButtonDialog = require("ui/widget/buttondialog")

local ScreenshotMode = Lazy("miuread.screenshot_mode")

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ButtonDialog = gesture_aware_class(RawButtonDialog, {_miuread_transient=true, _miuread_modal_surface=true})

local _ = Text.tr

local ok_socket, socket = pcall(require, "socket")
local function monotonic_wall_time()
    if ok_socket and socket and type(socket.gettime) == "function" then return socket.gettime() end
    return os.time()
end

-- Home layout constants live in miuread.home_layout_constants.
local HomeLayouts = require("miuread.home_layout_constants")
local HOME_PANEL_ITEM_ORDER = HomeLayouts.HOME_PANEL_ITEM_ORDER

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local ROOT = source:match("^(.*)[/\\]miuread[/\\]plugin_device%.lua$") or "."

local Plugin = {}

function Plugin:_home_wifi_toggle()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end
    local on=false
    local ok_state,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
    if ok_state then on=value==true end
    local ok
    if on then
        if type(NetworkMgr.toggleWifiOff)=="function" then ok=pcall(NetworkMgr.toggleWifiOff,NetworkMgr)
        elseif type(NetworkMgr.turnOffWifi)=="function" then ok=pcall(NetworkMgr.turnOffWifi,NetworkMgr) end
        if ok then self:toast("Wi-Fi 已关闭",1.5) end
    else
        if type(NetworkMgr.toggleWifiOn)=="function" then ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr)
        elseif type(NetworkMgr.turnOnWifi)=="function" then ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr) end
        if ok then self:toast("正在开启 Wi-Fi",1.5) end
    end
    if ok then HomeData.invalidate_device_state() end
    UIManager:scheduleIn(1,function() self:_refresh_home_view(nil,"header") end)
    return ok==true
end

function Plugin:_home_wifi_settings()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end

    -- Only refresh the MiuRead home after KOReader's network picker has
    -- actually closed. Refreshing while it is visible rebuilds the home view
    -- over the picker and makes the network list disappear immediately.
    local function refresh_after_picker_close()
        UIManager:scheduleIn(.15,function()
            self:_refresh_home_view(nil,"header")
        end)
    end

    local function show_network_list()
        -- Wi-Fi is already on: build KOReader's native network picker directly.
        if type(NetworkMgr.getNetworkList)=="function" then
            local ok_list,networks=pcall(NetworkMgr.getNetworkList,NetworkMgr)
            if ok_list and type(networks)=="table" then
                local ok_widget,NetworkSetting=pcall(require,"ui/widget/networksetting")
                if ok_widget and NetworkSetting and type(NetworkSetting.new)=="function" then
                    local dialog=NetworkSetting:new{
                        network_list=networks,
                        -- Deliberately omit connect_callback here. KOReader
                        -- auto-dismisses an already-connected network picker
                        -- when that callback is present. The close hook below
                        -- performs the single MiuRead header refresh instead.
                    }
                    local original_on_close=dialog.onCloseWidget
                    dialog.onCloseWidget=function(widget)
                        if type(original_on_close)=="function" then
                            local ok_close,err=xpcall(function()
                                original_on_close(widget)
                            end,debug.traceback)
                            if not ok_close then
                                logger.warn("[MiuRead][Home] network picker close failed",tostring(err))
                            end
                        end
                        refresh_after_picker_close()
                    end
                    UIManager:show(dialog)
                    return true
                end
            end
        end

        -- Backends with their own picker use KOReader's long-press flag.
        -- Their completion callback runs after the picker has been dismissed.
        if type(NetworkMgr.toggleWifiOn)=="function" then
            local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,refresh_after_picker_close,true,true)
            if ok then return true end
        end
        if type(NetworkMgr.turnOnWifi)=="function" then
            local ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr,refresh_after_picker_close,true)
            if ok then return true end
        end
        return false
    end

    local on=false
    local ok_state,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
    if ok_state then on=value==true end
    if on then
        if show_network_list() then return true end
    elseif type(NetworkMgr.toggleWifiOn)=="function" then
        -- Ask KOReader to enable Wi-Fi and show the available network list.
        local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,refresh_after_picker_close,true,true)
        if ok then return true end
    elseif type(NetworkMgr.turnOnWifi)=="function" then
        local ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr,function()
            UIManager:scheduleIn(.1,show_network_list)
        end,true)
        if ok then return true end
    end

    self:info("Wi-Fi 网络列表暂时无法打开")
    return false
end

function Plugin:_home_frontlight()
    local ok_fl,has_fl=pcall(Device.hasFrontlight,Device)
    if not ok_fl or not has_fl then self:info("当前设备不支持前光"); return false end
    return self:_show_frontlight_panel{placement="center"}
end

function Plugin:_koreader_device_listener()
    local ui=self.ui
    if ui and ui.devicelistener then return ui.devicelistener end
    local ok_reader,ReaderUI=pcall(require,"apps/reader/readerui")
    if ok_reader and ReaderUI and ReaderUI.instance and ReaderUI.instance.devicelistener then
        return ReaderUI.instance.devicelistener
    end
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager.instance and FileManager.instance.devicelistener then
        return FileManager.instance.devicelistener
    end
    return nil
end

function Plugin:_home_toggle_night()
    local listener=self:_koreader_device_listener()
    if not (listener and type(listener.onToggleNightMode)=="function") then
        self:info("当前 KOReader 暂时无法切换夜间模式")
        return false
    end
    local before=self:_reader_night_enabled()
    local ok,err=pcall(listener.onToggleNightMode,listener)
    if not ok then
        logger.warn("[MiuRead][NightMode] native toggle failed",tostring(err))
        self:info("夜间模式切换失败")
        return false
    end
    UIManager:scheduleIn(.08,function()
        local after=self:_reader_night_enabled()
        if after==before then logger.warn("[MiuRead][NightMode] state unchanged after native toggle") end
    end)
    return true
end

function Plugin:_orientation_status_label()
    return Orientation.status_label()
end

function Plugin:_orientation_icon_key()
    return Orientation.icon_key()
end

function Plugin:_orientation_feedback(ok,message)
    message=U.trim(tostring(message or ""))
    if message~="" then self:status_toast("屏幕方向",message,3) end
    return ok==true
end

function Plugin:_orientation_toggle_lock()
    local ok,message=Orientation.toggle_session_lock()
    return self:_orientation_feedback(ok,message)
end

function Plugin:_show_orientation_panel()
    local dialog
    local function run(action)
        if dialog then UIManager:close(dialog) end
        local ok,message=action()
        self:_orientation_feedback(ok,message)
    end
    local buttons={
        {{text="跟随 KOReader",callback=function() run(Orientation.follow_koreader) end}},
        {{text="锁定当前方向",callback=function() run(Orientation.lock_current) end}},
        {
            {text="固定竖屏",callback=function() run(Orientation.set_portrait) end},
            {text="固定横屏",callback=function() run(Orientation.set_landscape) end},
        },
    }
    if Orientation.has_gsensor() then
        buttons[#buttons+1]={{text="恢复自动旋转",callback=function() run(Orientation.enable_auto_rotation) end}}
    end
    buttons[#buttons+1]={{text="取消",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{
        title="屏幕方向\n\n当前："..Orientation.status_label(),
        title_align="center",
        buttons=buttons,
    }
    UIManager:show(dialog)
    return true
end

-- Compatibility entry for older internal callers. Rotation is no longer a
-- blind 90-degree step: it now opens the direction controls.
function Plugin:_home_rotate()
    return self:_show_orientation_panel()
end

function Plugin:_home_full_refresh(confirmed)
    if confirmed~=true and self:_notice_enabled("full_refresh") then
        local dialog
        dialog=ButtonDialog:new{title="全屏刷新可以清除墨水屏残影，屏幕会短暂闪烁。",title_align="center",buttons={
            {{text="立即刷新",callback=function() UIManager:close(dialog); self:_home_full_refresh(true) end}},
            {{text="刷新并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("full_refresh",false); self:_home_full_refresh(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
        return true
    end
    local listener=self:_koreader_device_listener()
    if listener and type(listener.onFullRefresh)=="function" then
        local ok,err=pcall(listener.onFullRefresh,listener)
        if ok then return true end
        logger.warn("[MiuRead][Refresh] native full refresh failed",tostring(err))
    end
    -- Compatibility fallback for KOReader builds where the active UI listener
    -- is temporarily unavailable during a desktop transition.
    UIManager:broadcastEvent(Event:new("FullRefresh"))
    return true
end

function Plugin:_home_sleep()
    if Device:canSuspend() then
        UIManager:flushSettings()
        UIManager:suspend()
        return true
    end
    self:info("当前设备不支持休眠")
    return false
end

function Plugin:_home_device_power_busy(action_label)
    action_label=tostring(action_label or "执行此操作")
    if (self.download_task and self.download_task:busy()) or self._download_runtime~=nil then
        self:info("当前下载任务尚未完成，暂不"..action_label.."。\n\n请等待任务结束，或先在下载管理中取消任务。")
        return true
    end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then
        self:info("缓存任务尚未完成，暂不"..action_label.."。")
        return true
    end
    return false
end

function Plugin:_show_home_power_confirm(anchor,title,detail,confirm_label,callback)
    return ActionSheet.show{
        anchor=anchor,preferred_direction="above",width_ratio=.58,
        title=tostring(title or "确认操作"),subtitle=tostring(detail or ""),
        actions={
            {icon="×",label="取消",detail="不执行任何操作",callback=function() end},
            {icon="!",label=tostring(confirm_label or "确定"),detail="保存当前状态后执行",danger=true,callback=callback},
        },
    }
end

function Plugin:_flush_before_power_action()
    pcall(function() self:_flush_home_preferences() end)
    pcall(function() self:onFlushSettings() end)
    if Device and Device.saveSettings then pcall(Device.saveSettings,Device) end
end

function Plugin:_home_reboot_device(anchor,confirmed)
    if type(Device.canReboot)~="function" or not Device:canReboot() then
        self:info("当前设备不支持由 KOReader 重启设备")
        return false
    end
    if self:_home_device_power_busy("重启设备") then return false end
    if confirmed~=true and HomeView.is_shown() then
        return self:_show_home_power_confirm(anchor,"重启整个设备？","这会重新启动 Kindle，而不是只重启 KOReader。","重启设备",function()
            self:_home_reboot_device(anchor,true)
        end)
    end
    self:_flush_before_power_action()
    UIManager:broadcastEvent(Event:new("RequestReboot"))
    return true
end

function Plugin:_home_poweroff_device(anchor,confirmed)
    if type(Device.canPowerOff)~="function" or not Device:canPowerOff() then
        self:info("当前设备不支持由 KOReader 关机")
        return false
    end
    if self:_home_device_power_busy("关机") then return false end
    if confirmed~=true and HomeView.is_shown() then
        return self:_show_home_power_confirm(anchor,"关闭整个设备？","日常使用建议优先使用休眠。","关机",function()
            self:_home_poweroff_device(anchor,true)
        end)
    end
    self:_flush_before_power_action()
    UIManager:broadcastEvent(Event:new("RequestPowerOff"))
    return true
end

function Plugin:_home_preview_books(rows,hero,limit)
    local out,seen={},{}
    local hero_key=self:_home_book_key(hero)
    if hero_key~="" then seen[hero_key]=true end
    for _,book in ipairs(rows or {}) do
        local key=self:_home_book_key(book)
        if key~="" and not seen[key] then
            seen[key]=true
            out[#out+1]=book
            if #out>=math.max(1,tonumber(limit) or 4) then break end
        end
    end
    return out
end





function Plugin:maintenance_menu()
    return {
        {text="书库维护",post_text="扫描 资料 封面与书架",sub_item_table_func=function()
            return {
                {text="重新扫描全部本地书库",callback=function()
                    local started=self:_home_scan_local(true)
                    if started then self:toast("正在重新扫描本地书库…",2) end
                end},
                {text="更新缺失书籍资料",callback=function()
                    self:_home_reset_local_metadata(); self:_home_complete_refresh(true)
                end},
                {text="重建封面",callback=function() self:_clear_cover_cache() end},
                {text="重建书架索引",callback=function()
                    self.store:reload(); self.store:prune_missing_files(); self:_show_miuread_home_now(false,true,true,"full")
                end},
            }
        end},
        {text="书籍修复",post_text="完整性与旧评论数据",sub_item_table_func=function()
            return {
                {text="检查下载完整性",callback=function() self:scan_downloaded_books_for_integrity_repair() end},
                {text="评论数据迁移",sub_item_table_func=function() return self:book_repair_settings_menu() end},
            }
        end},
        {text="阅读周报",post_text="本周与今日阅读统计",callback=function() self:show_reading_report() end},
        {text="缓存体检与一键清理",post_text="扫描可释放空间",callback=function() self:show_cache_health() end},
        {text="备份与恢复",post_text="配置 断点与本地批注库",sub_item_table_func=function()
            return {
                {text="立即备份配置与数据",callback=function() self:export_config_backup() end},
                {text="从最近备份恢复",post_text="恢复后自动重启",callback=function() self:restore_config_backup() end},
                {text="备份位置",post_text=self:_backup_latest_dir(),enabled=false},
            }
        end},
        {text="存储清理",post_text="临时文件 缓存与旧记录",callback=function() self:show_download_cleanup_dialog() end},
        {text="诊断",post_text="诊断包 同步与时间",sub_item_table_func=function()
            return {
                {text="生成诊断包",post_text="版本 设备 偏好与下载诊断",callback=function() self:export_diagnostic_bundle() end},
                {text="同步诊断",sub_item_table_func=function() return self:sync_diagnostics_menu() end},
                {text="时间诊断",callback=function()
                    local value=self:_time_preferences()
                    local zone=TimeZone.zone(value.zone)
                    self:info("觅阅时间："..self:_display_time("%Y-%m-%d %H:%M:%S")
                        .."\n设备时间："..os.date("%Y-%m-%d %H:%M:%S")
                        .."\n显示来源："..TimeZone.label(value)
                        .."\n地区："..tostring(zone and zone.label or "—")
                        .."\n偏移："..TimeZone.offset_text(TimeZone.offset_minutes(value)))
                end},
            }
        end},
        {text="性能与兼容性",post_text=self:_performance_mode_label(),sub_item_table_func=function() return PluginSettings.performance(self) end},
        {text="运行模式",post_text=self:_home_mode_label(),sub_item_table_func=function() return self:home_mode_menu() end},
        {text="系统操作",post_text="退出 重启与关机",sub_item_table_func=function()
            local system_items={
                {text="退出 KOReader",callback=function() self:_quit_koreader() end},
                {text="重启 KOReader",callback=function() self:_restart_koreader() end},
            }
            if type(Device.canReboot)=="function" and Device:canReboot() then
                system_items[#system_items+1]={text="重启设备",callback=function() self:_home_reboot_device() end}
            end
            if type(Device.canPowerOff)=="function" and Device:canPowerOff() then
                system_items[#system_items+1]={text="关机",callback=function() self:_home_poweroff_device() end}
            end
            return system_items
        end},
    }
end

function Plugin:show_home_quick_panel(more_expanded)
    local started=monotonic_wall_time()
    local now=started
    if self._home_quick_panel_opening==true
        or now-(tonumber(self._home_quick_panel_last_open) or 0)<.35 then return true end
    self._home_quick_panel_opening=true
    self._home_quick_panel_last_open=now

    -- Opening the control center must never query Wi-Fi, disk or download
    -- storage. The home surface already has a recent device snapshot.
    local state=HomeData.cached_device_state() or {}
    local wifi_on=state.wifi_on
    local wifi_name=U.trim(tostring(state.wifi_name or ""))
    local wifi_detail
    if wifi_on==nil then wifi_detail="状态未知"
    elseif wifi_on~=true then wifi_detail="已关闭"
    elseif wifi_name~="" then wifi_detail=U.utf8_truncate(wifi_name,11,"…")
    elseif state.online==true then wifi_detail="已连接"
    else wifi_detail="未连接" end
    local download_detail=tostring(self._home_panel_download_detail or "")
    local sync_label=self:_home_sync_status_label()
    local bluetooth_state=self:_bluetooth_state(false)
    local definitions={
        wifi={
            icon="Wi-Fi",
            icon_path=ROOT.."/resources/"..(wifi_on==false and "wifi-off.svg" or (state.online==true and "wifi-connected.svg" or "wifi-disconnected.svg")),
            label="Wi-Fi",detail=wifi_detail,
            callback=function() self:_home_wifi_toggle() end,
            hold_callback=function() self:_home_wifi_settings() end
        },
        bluetooth=bluetooth_state.supported==true and {
            icon="bluetooth",icon_key="bluetooth",label="蓝牙",detail=bluetooth_state.enabled==true and "已开启" or "已关闭",
            callback=function() self:_bluetooth_toggle() end
        } or nil,
        rotate={
            icon="方向",icon_key=self:_orientation_icon_key(),label="方向锁定",detail=self:_orientation_status_label(),
            callback=function() self:_orientation_toggle_lock() end,
            hold_callback=function() self:_show_orientation_panel() end
        },
        screenshot={icon="▣",icon_key="screenshot",label="截图",detail="",callback=function(anchor) ScreenshotMode.start(self,anchor) end},
        koreader_settings={icon="⚙",icon_key="ko-reader",label="KO设置",detail="",callback=function() self:_show_native_koreader_menu() end},
        return_koreader={icon="←",icon_key="return",label="返回KO",detail="",callback=function() self:_home_close_to_native(true) end},
        quit={icon="⏻",icon_key="power",label="退出 KO",detail="",callback=function() self:_quit_koreader() end},
        sync={icon="⇅",icon_key="sync",label="同步",detail=sync_label,callback=function() self:_sync_home_pending() end,hold_callback=function(anchor) self:_show_home_sync_popup(anchor) end},
        miuread_settings={icon="⚙",icon_key="settings",label="觅阅设置",detail="",callback=function() self:_show_home_settings_center() end},
        downloads={icon="⇩",icon_key="download",label="下载",detail=download_detail,
            callback=function(anchor) self:_show_home_download_popup(anchor) end,
            hold_callback=function() self:show_downloads() end},
        restart={icon="↺",icon_key="restart",label="重启",detail="",callback=function() self:_restart_koreader() end},
        full_refresh={icon="▤",icon_key="full-refresh",label="全屏刷新",detail="",callback=function() self:_home_full_refresh() end},
    }
    if Device:canSuspend() then
        definitions.sleep={icon="◐",icon_key="sleep",label="休眠",detail="",callback=function() self:_home_sleep() end}
    end

    local home,preferences=self:_home_preferences()
    local buttons={}
    for _,key in ipairs(home.panel_order or HOME_PANEL_ITEM_ORDER) do
        if home.panel_items[key]==true and definitions[key] then buttons[#buttons+1]=definitions[key] end
        if #buttons>=8 then break end
    end

    local battery=tonumber(state.battery) and (tostring(math.floor(state.battery+.5)).."%") or "未知"
    local status_text=tostring(self._home_panel_status_text or "")
    if status_text=="" and sync_label:match("^失败") then status_text="同步需要处理" end
    local frontlight_control=nil
    if Device:hasFrontlight() then
        local minimum,maximum=self:_reader_frontlight_bounds()
        local warmth_state=self:_reader_warmth_state()
        frontlight_control={
            get_enabled=function() return self:_reader_frontlight_enabled() end,
            get_night=function() return self:_reader_night_enabled() end,
            on_toggle=function() return self:_reader_toggle_frontlight() end,
            on_night=function() return self:_home_toggle_night() end,
            brightness={min=minimum,max=maximum,value=self:_reader_frontlight_value() or minimum,get_value=function() return self:_reader_frontlight_value() or minimum end,on_set=function(value)
                if not self:_reader_set_frontlight(value) then return false end
                return self:_reader_frontlight_value() or value
            end},
            warmth=warmth_state and {min=warmth_state.min,max=warmth_state.max,value=warmth_state.value,get_value=function() local latest=self:_reader_warmth_state(); return latest and latest.value or warmth_state.value end,on_set=function(value)
                if not self:_reader_set_warmth(value) then return false end
                local latest=self:_reader_warmth_state(); return latest and latest.value or value
            end} or nil,
        }
    end
    local prepared=monotonic_wall_time()
    local panel,err=HomeQuickPanel.show{
        time_text=self:_display_time("%H:%M"),
        battery_text=battery,
        status_text=status_text,
        buttons=buttons,
        frontlight=frontlight_control,
        on_customize=function(anchor) self:show_home_customization(anchor) end,
        on_tools=function(anchor)
            self:_show_standalone_menu("工具与维护",self:maintenance_menu(),{anchor=anchor})
        end,
    }
    self._home_quick_panel_opening=false
    local completed=monotonic_wall_time()
    local total_ms=math.floor((completed-started)*1000+.5)
    logger.info("[MiuRead][QuickPanel] timing",
        "prep_ms=",tostring(math.floor((prepared-started)*1000+.5)),
        "show_ms=",tostring(math.floor((completed-prepared)*1000+.5)),
        "total_ms=",tostring(total_ms))
    if not panel then
        logger.warn("[MiuRead][QuickPanel] unavailable",tostring(err or "unknown"))
        self:info("快捷控制暂时无法打开")
        return false
    end
    self:_record_performance("home_panel",total_ms)
    return true
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
