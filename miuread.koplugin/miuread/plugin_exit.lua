-- MiuRead exit / quit / menu controller, split from main.lua.
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Session = require("miuread.session_state")
local Orientation = require("miuread.orientation_controller")
local HomeQuickPanel = require("miuread.home_quick_panel")
local HomeView = require("miuread.home_view")
local PluginSettings = require("miuread.plugin_settings")
local GestureBridge = require("miuread.gesture_bridge")
local RawConfirmBox = require("ui/widget/confirmbox")

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ConfirmBox = gesture_aware_class(RawConfirmBox, {_miuread_transient=true, _miuread_modal_surface=true})

local Plugin = {}

function Plugin:_begin_koreader_exit(reason)
    Orientation.release_session(reason or "KOReader exit")
    self:_cancel_interactive_network(reason or "KOReader exit")
    self:_cancel_native_menu_guard()
    Session.home().exiting =true
    Session.home().suppressed =true
    Session.home().native_visit =false
    Session.home().return_file =nil
    Session.home().reader_origin =false
    Session.home().reader_file =nil
    Session.home().expected_close =true
    self:_set_foreground("exiting")
    self._home_start_generation=(tonumber(self._home_start_generation) or 0)+1
    self:_home_stop_background(reason or "KOReader exit")
    self:_close_reader_recovery_surface()
    self:_release_reader_transition_guard("KOReader exit")
    HomeQuickPanel.close()
    HomeView.close()
    self._home_view=nil
end

function Plugin:_quit_koreader(confirmed,anchor)
    local active=(self.download_task and self.download_task:busy()) or self._download_runtime~=nil
    local queued=#self.store:download_queue()>0
    local detail=""
    if active and queued then detail="当前任务会中断，重启后可继续；排队任务会保留。"
    elseif active then detail="当前任务会中断，重新启动后可继续。"
    elseif queued then detail="当前有一个排队任务，重新启动后仍会保留。" end
    local function do_exit()
        self:_begin_koreader_exit("quit")
        pcall(function() self:onFlushSettings() end)
        if Device and Device.saveSettings then pcall(Device.saveSettings,Device) end
        UIManager:nextTick(function() UIManager:broadcastEvent(Event:new("Exit")) end)
    end
    if confirmed==true then do_exit(); return true end
    if HomeView.is_shown() then
        return self:_show_home_power_confirm(anchor,"退出 KOReader？",detail~="" and detail or "当前阅读和设置会先保存。","退出",do_exit)
    end
    UIManager:show(ConfirmBox:new{text="退出 KOReader？"..(detail~="" and ("\n\n"..detail) or ""),ok_text="退出",cancel_text="取消",ok_callback=do_exit})
    return true
end

function Plugin:show_home_menu()
    if not self:_home_enabled() then return self:_show_standalone_menu("插件设置",PluginSettings.menu(self)) end
    return self:_show_standalone_menu("觅阅菜单",self:settings_menu())
end

function Plugin:home_preview_menu()
    return {
        {text="打开觅阅菜单",callback=function() self:show_home_menu() end},
        {text="切换到插件模式",callback=function() self:_set_home_mode(false) end},
        {text="KOReader 文件管理器",callback=function() self:_home_close_to_native() end},
    }
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
