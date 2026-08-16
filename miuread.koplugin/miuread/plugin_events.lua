-- MiuRead event entry points, split from main.lua. Dispatchers stay thin:
-- real behaviour lives in the domain controllers.
local UIManager = require("ui/uimanager")
local Session = require("miuread.session_state")

local Plugin = {}

function Plugin:onExit()
    self:_cancel_interactive_network("exit")
    if not Session.home_exiting() then self:_begin_koreader_exit("external exit") end
    return false
end
function Plugin:onRestart()
    if not Session.home_exiting() then self:_begin_koreader_exit("external restart") end
    return false
end
function Plugin:onShowMiuRead()
    if self:_home_enabled() then return self:return_to_miuread_home() end
    self:show_shelf(false,false,"account")
end
function Plugin:onMiuReadReturnHome()
    if self:_home_enabled() then return self:return_to_miuread_home() end
    self:show_shelf(false,false,"account")
    return true
end
function Plugin:onToggleMiuReadProgressSync()
    if self:require_login() then self:toggle_progress_sync() end
    return true
end
function Plugin:onToggleMiuReadTimeSync()
    self:toggle_time_sync()
    return true
end
function Plugin:onShowMiuReadDownloads()
    self:show_downloads()
    return true
end
function Plugin:onShowMiuReadSyncStatus()
    self:show_sync_status(false)
    return true
end
function Plugin:onMiuReadSyncAll()
    self:_sync_shortcut()
    return true
end
function Plugin:onMiuReadQRLogin()
    if self:logged_in() then self:show_account_status() else self.auth_flow:start() end
    return true
end
function Plugin:onMiuReadLogout()
    self:confirm_logout()
    return true
end
function Plugin:onMiuReadReaderPanel()
    self:show_reader_quick_panel()
    return true
end
function Plugin:onMiuReadReaderFont()
    self:_show_reader_font_panel()
    return true
end
function Plugin:onMiuReadReaderTypeset()
    self:_show_reader_advanced_typeset_panel()
    return true
end
function Plugin:onMiuReadReaderProgress()
    self:_show_reader_progress_control()
    return true
end
function Plugin:onMiuReadUploadProgress()
    self:upload_local_progress(true)
    return true
end
function Plugin:onMiuReadPullProgress()
    self:manual_sync()
    return true
end
function Plugin:onMiuReadCurrentBook()
    self:_show_reader_current_book_panel()
    return true
end
function Plugin:onMiuReadCloseBook()
    if self:_home_enabled() then return self:return_to_miuread_home() end
    local ReaderUI=require("apps/reader/readerui")
    if ReaderUI and ReaderUI.instance and ReaderUI.instance.document then
        local readerui=ReaderUI.instance
        local file=readerui.document.file
        UIManager:nextTick(function()
            readerui:onClose()
            if file then readerui:showFileManager(file) end
        end)
    end
    return true
end


local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
