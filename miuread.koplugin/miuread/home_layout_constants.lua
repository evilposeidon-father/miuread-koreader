-- Shared home layout constants and layout-matching helpers.
--
-- main.lua and plugin_home both configure the home quick layouts, so this
-- module is the single source of truth for the order/defaults/layout versions
-- and for the boolean/order equality helpers used during preference repair.

local M = {}

M.COVER_GUARD_WINDOW = 6 * 60 * 60
M.HOME_LOCAL_CACHE_TTL = 20 * 60
M.HOME_SHELF_REFRESH_TTL = 10 * 60
M.HOME_REMOTE_AUTO_RETRY = 5 * 60
M.HOME_SECTION_ORDER = {"account", "generated", "local", "mp"}
M.HOME_QUICK_ITEM_LEGACY_ORDER = {"wifi","frontlight","refresh_shelf","full_refresh","settings","koreader_menu","downloads","sync","night","rotate","sleep","restart","quit"}
M.HOME_QUICK_ITEM_LEGACY_DEFAULT = {wifi=true,frontlight=true,refresh_shelf=true,full_refresh=true,settings=true,koreader_menu=true,downloads=true,sync=true,night=false,rotate=false,sleep=true,restart=false,quit=false}

-- 3.5 separates the always-visible home actions from the pull-down control
-- center. Defaults intentionally avoid duplicates, while both areas remain
-- fully configurable.
M.HOME_ACTION_ITEM_V1_ORDER = {"refresh","search","downloads","sync","frontlight","miuread_settings","all_books","history","file_manager","screenshot"}
M.HOME_ACTION_ITEM_V1_DEFAULT = {refresh=true,search=true,downloads=true,sync=true,frontlight=true,miuread_settings=true,all_books=false,history=false,file_manager=false,screenshot=false}
M.HOME_ACTION_ITEM_V2_ORDER = {"refresh","search","downloads","sync","sleep","miuread_settings","frontlight","all_books","history","file_manager","screenshot"}
M.HOME_ACTION_ITEM_V2_DEFAULT = {refresh=true,search=true,downloads=true,sync=true,sleep=true,miuread_settings=true,frontlight=false,all_books=false,history=false,file_manager=false,screenshot=false}
-- Frontlight is no longer a homepage shortcut candidate. It lives only in the
-- pull-down direct-control section (and the reader controls).
M.HOME_ACTION_ITEM_ORDER = {"refresh","search","downloads","sync","sleep","miuread_settings","all_books","history","file_manager","screenshot"}
M.HOME_ACTION_ITEM_DEFAULT = {refresh=true,search=true,downloads=true,sync=true,sleep=true,miuread_settings=true,all_books=false,history=false,file_manager=false,screenshot=false}
M.HOME_ACTION_LAYOUT_VERSION = 3
M.HOME_PANEL_ITEM_V1_ORDER = {"wifi","rotate","screenshot","koreader_settings","return_koreader","quit","frontlight","sync","miuread_settings","downloads","restart","sleep","full_refresh"}
M.HOME_PANEL_ITEM_V1_DEFAULT = {wifi=true,rotate=true,screenshot=true,koreader_settings=true,return_koreader=true,quit=true,frontlight=false,sync=false,miuread_settings=false,downloads=false,restart=false,sleep=false,full_refresh=false}
M.HOME_PANEL_ITEM_V2_ORDER = {"wifi","rotate","screenshot","koreader_settings","return_koreader","quit","sync","miuread_settings","downloads","restart","sleep","full_refresh"}
M.HOME_PANEL_ITEM_V2_DEFAULT = {wifi=true,rotate=true,screenshot=true,koreader_settings=true,return_koreader=true,quit=true,sync=false,miuread_settings=false,downloads=false,restart=false,sleep=false,full_refresh=false}
-- The pull-down row can use eight slots. Bluetooth is a conditional candidate:
-- supported Kindle devices receive it, while unsupported devices fall through
-- to Sync as the eighth useful control.
M.HOME_PANEL_ITEM_ORDER = {"wifi","bluetooth","rotate","screenshot","full_refresh","koreader_settings","return_koreader","quit","sync","miuread_settings","downloads","restart","sleep"}
M.HOME_PANEL_ITEM_DEFAULT = {wifi=true,bluetooth=true,rotate=true,screenshot=true,full_refresh=true,koreader_settings=true,return_koreader=true,quit=true,sync=true,miuread_settings=false,downloads=false,restart=false,sleep=false}
M.HOME_PANEL_LAYOUT_VERSION = 3

M.RUNTIME_MODE_KEY = "__MIUREAD_RUNTIME_MODE"

function M.quick_boolean_layout_matches(actual, expected, order)
    if type(actual) ~= "table" then return false end
    for _, key in ipairs(order or {}) do
        if (actual[key] == true) ~= (expected[key] == true) then return false end
    end
    return true
end

function M.quick_order_matches(actual, expected)
    if type(actual) ~= "table" or #actual ~= #expected then return false end
    for index, key in ipairs(expected) do if actual[index] ~= key then return false end end
    return true
end

return M
