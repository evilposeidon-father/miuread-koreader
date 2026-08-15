-- MiuRead native KOReader menu guard controller, split from main.lua.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Session = require("miuread.session_state")
local HomeView = require("miuread.home_view")

local HOME_SESSION = Session.home()
local NATIVE_MENU_GUARD = Session.native_menu_guard()

local Plugin = {}

function Plugin:_cancel_native_menu_guard()
    -- Clean up a beta.4 callback override if this code is loaded in the same
    -- process during development; beta.5 never installs a new override.
    local legacy_menu=NATIVE_MENU_GUARD.menu
    local legacy_close=NATIVE_MENU_GUARD.original_close
    if legacy_menu and legacy_close and legacy_menu.onCloseFileManagerMenu~=legacy_close then
        legacy_menu.onCloseFileManagerMenu=legacy_close
    end
    NATIVE_MENU_GUARD.token=(tonumber(NATIVE_MENU_GUARD.token) or 0)+1
    NATIVE_MENU_GUARD.active=false
    NATIVE_MENU_GUARD.finishing=false
    NATIVE_MENU_GUARD.menu=nil
    NATIVE_MENU_GUARD.container=nil
    NATIVE_MENU_GUARD.watch=nil
    NATIVE_MENU_GUARD.original_close=nil
end

function Plugin:_return_from_native_filemanager()
    if Session.home_exiting() or UIManager._exit_code~=nil or not self:_home_enabled() then return false end
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local fm=ok_fm and FileManager and FileManager.instance or nil
    local menu=NATIVE_MENU_GUARD.menu or (fm and fm.menu) or nil
    if menu and menu.menu_container and type(menu.onCloseFileManagerMenu)=="function" then
        pcall(menu.onCloseFileManagerMenu,menu)
    end
    self:_cancel_native_menu_guard()
    Session.home().suppressed =false
    Session.home().native_visit =false
    Session.home().expected_close =false
    Session.home().reader_origin =false
    Session.home().reader_file =nil
    local shown=self:show_miuread_home(false)
    if shown then
        self:_set_foreground("home")
        HomeView.raise(true)
        UIManager:scheduleIn(.04,function() UIManager:setDirty("all","full") end)
    end
    return shown
end

function Plugin:_native_menu_overlay_present()
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local fm=ok_fm and FileManager and FileManager.instance or nil
    local reader=self:_active_reader_ui()
    for _,window in ipairs(UIManager._window_stack or {}) do
        local widget=window and window.widget or nil
        if widget and widget~=fm and widget~=reader and widget~=HomeView.current()
            and widget.toast~=true then
            return true
        end
    end
    return false
end

function Plugin:_finish_native_menu_visit(token,reason)
    if token~=NATIVE_MENU_GUARD.token or not NATIVE_MENU_GUARD.active or NATIVE_MENU_GUARD.finishing then return false end
    NATIVE_MENU_GUARD.finishing=true
    if Session.home_exiting() or UIManager._exit_code~=nil or not self:_home_enabled() then
        self:_cancel_native_menu_guard()
        return false
    end

    -- A book opened from this temporary menu still belongs to the MiuRead
    -- navigation session. The exact file is filled in as soon as ReaderUI is
    -- available.
    Session.home().suppressed =false
    Session.home().native_visit =false
    Session.home().reader_origin =true
    Session.home().expected_close =false

    local function settle(attempt)
        if token~=NATIVE_MENU_GUARD.token or not NATIVE_MENU_GUARD.active then return end
        if Session.home_exiting() or UIManager._exit_code~=nil or not self:_home_enabled() then
            self:_cancel_native_menu_guard()
            return
        end
        if HOME_SESSION.suspended==true or self._miuread_suspended==true then
            UIManager:scheduleIn(.6,function() settle(attempt+1) end)
            return
        end
        local reader=self:_active_reader_ui()
        if reader then
            local file=reader.document and reader.document.file or nil
            mark_reader_origin(file)
            self:_close_home_for_reader("native menu opened reader")
            self:_cancel_native_menu_guard()
            logger.info("[MiuRead][Home] native menu closed into reader",tostring(reason or "closed"))
            return
        end
        -- Native settings and plugin dialogs may replace the original menu.
        -- Wait until the last native layer closes before raising MiuRead again.
        if self:_native_menu_overlay_present() then
            local delay=attempt<20 and .12 or (attempt<80 and .3 or .7)
            UIManager:scheduleIn(delay,function() settle(attempt+1) end)
            return
        end

        self:_cancel_native_menu_guard()
        Session.home().suppressed =false
        Session.home().native_visit =false
        Session.home().reader_origin =false
        Session.home().reader_file =nil
        Session.home().expected_close =false
        logger.info("[MiuRead][Home] native menu closed; MiuRead home revealed",tostring(reason or "closed"))
        if HomeView.is_shown() then
            self:_set_foreground("home")
            HomeView.raise(true)
            UIManager:scheduleIn(.04,function() UIManager:setDirty("all","full") end)
        else
            self:_ensure_filemanager_base(Session.home().return_file)
            self:_restore_home_after_reader_close(1)
            UIManager:scheduleIn(.18,function() UIManager:setDirty("all","full") end)
        end
    end
    UIManager:scheduleIn(.04,function() settle(1) end)
    return true
end

function Plugin:_guard_native_koreader_menu(menu)
    if not menu then return nil end
    self:_set_navigation_state("native_menu","KOReader menu opened over home")
    NATIVE_MENU_GUARD.token=(tonumber(NATIVE_MENU_GUARD.token) or 0)+1
    local token=NATIVE_MENU_GUARD.token
    NATIVE_MENU_GUARD.active=true
    NATIVE_MENU_GUARD.finishing=false
    NATIVE_MENU_GUARD.menu=menu
    NATIVE_MENU_GUARD.container=menu.menu_container

    Session.home().suppressed =false
    Session.home().native_visit =false
    Session.home().reader_origin =true
    Session.home().expected_close =false

    -- Do not replace KOReader's close callback. Native settings pages replace
    -- their menu/container as navigation goes deeper; observing the window
    -- stack is safer than changing callbacks owned by KOReader.
    local function watch()
        if token~=NATIVE_MENU_GUARD.token or not NATIVE_MENU_GUARD.active then return end
        if Session.home_exiting() or UIManager._exit_code~=nil or not self:_home_enabled() then
            self:_cancel_native_menu_guard()
            return
        end
        if HOME_SESSION.suspended==true or self._miuread_suspended==true then
            UIManager:scheduleIn(.6,watch)
            return
        end
        local container=menu.menu_container or NATIVE_MENU_GUARD.container
        if not container or not UIManager:isWidgetShown(container) then
            self:_finish_native_menu_visit(token,"watchdog")
            return
        end
        UIManager:scheduleIn(.16,watch)
    end
    NATIVE_MENU_GUARD.watch=watch
    UIManager:scheduleIn(.16,watch)
    return token
end

function Plugin:_show_native_koreader_menu()
    if Session.home_exiting() or UIManager._exit_code~=nil then return false end
    -- Ignore repeated taps while a native menu/settings visit is active. This
    -- prevents duplicate menu stacks and duplicate close watchers.
    if NATIVE_MENU_GUARD.active then return true end
    self:_cancel_native_menu_guard()
    self:_set_navigation_state("native_menu","opening KOReader menu over home")
    HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
    HOME_SESSION.home_restore_active=false
    self:_ensure_filemanager_base(Session.home().return_file)
    if HomeView.is_shown() then HomeView.raise(true) end

    Session.home().suppressed =false
    Session.home().native_visit =false
    Session.home().reader_origin =true
    Session.home().expected_close =false

    local candidates={}
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local fm=ok_fm and FileManager and FileManager.instance or nil
    if fm and fm.menu then candidates[#candidates+1]=fm.menu end
    if self.ui and self.ui.menu and self.ui.menu~=(fm and fm.menu) then
        candidates[#candidates+1]=self.ui.menu
    end
    for _,menu in ipairs(candidates) do
        if menu and type(menu.onShowMenu)=="function" then
            local ok,err=xpcall(function() menu:onShowMenu() end,debug.traceback)
            if ok then
                self:_guard_native_koreader_menu(menu)
                logger.info("[MiuRead][Home] native KOReader menu opened over MiuRead home")
                return true
            end
            logger.warn("[MiuRead][Home] native menu failed",tostring(err))
        end
    end

    self:_cancel_native_menu_guard()
    Session.home().reader_origin =false
    Session.home().reader_file =nil
    if HomeView.is_shown() then
        self:_set_foreground("home")
        HomeView.raise()
    else
        self:_set_navigation_state("recovering","native menu unavailable")
    end
    logger.warn("[MiuRead][Home] no native KOReader menu available")
    self:info("KOReader 菜单暂时无法打开")
    return false
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
