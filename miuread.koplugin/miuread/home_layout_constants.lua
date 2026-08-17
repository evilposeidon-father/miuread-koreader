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
M.HOME_ACTION_ITEM_ORDER = {"refresh","search","downloads","sleep","miuread_settings","all_books","history","file_manager","screenshot"}
M.HOME_ACTION_ITEM_DEFAULT = {refresh=true,search=true,downloads=true,sleep=true,miuread_settings=true,all_books=false,history=false,file_manager=false,screenshot=false}
M.HOME_ACTION_LAYOUT_VERSION = 4
M.HOME_PANEL_ITEM_V1_ORDER = {"wifi","rotate","screenshot","koreader_settings","return_koreader","quit","frontlight","sync","miuread_settings","downloads","restart","sleep","full_refresh"}
M.HOME_PANEL_ITEM_V1_DEFAULT = {wifi=true,rotate=true,screenshot=true,koreader_settings=true,return_koreader=true,quit=true,frontlight=false,sync=false,miuread_settings=false,downloads=false,restart=false,sleep=false,full_refresh=false}
M.HOME_PANEL_ITEM_V2_ORDER = {"wifi","rotate","screenshot","koreader_settings","return_koreader","quit","sync","miuread_settings","downloads","restart","sleep","full_refresh"}
M.HOME_PANEL_ITEM_V2_DEFAULT = {wifi=true,rotate=true,screenshot=true,koreader_settings=true,return_koreader=true,quit=true,sync=false,miuread_settings=false,downloads=false,restart=false,sleep=false,full_refresh=false}
-- The pull-down row can use eight slots. Bluetooth is a conditional candidate:
-- supported Kindle devices receive it, while unsupported devices fall through
-- to Sync as the eighth useful control.
M.HOME_PANEL_ITEM_ORDER = {"wifi","bluetooth","rotate","screenshot","full_refresh","koreader_settings","return_koreader","quit","miuread_settings","downloads","restart","sleep"}
M.HOME_PANEL_ITEM_DEFAULT = {wifi=true,bluetooth=true,rotate=true,screenshot=true,full_refresh=true,koreader_settings=true,return_koreader=true,quit=true,miuread_settings=false,downloads=false,restart=false,sleep=false}
M.HOME_PANEL_LAYOUT_VERSION = 4

M.HOME_SOURCE_LABELS = {account="书架",generated="已下载",["local"]="本地书籍",mp="公众号"}
M.HOME_ACTION_LABELS = {
    refresh="更新",search="搜索",downloads="下载",sleep="休眠",
    miuread_settings="觅阅设置",all_books="全部书籍",history="阅读历史",file_manager="文件管理",screenshot="截图",
}
M.HOME_PANEL_LABELS = {
    wifi="Wi-Fi",bluetooth="蓝牙",rotate="方向锁定",screenshot="截图",koreader_settings="KOReader 设置",
    return_koreader="返回 KOReader",quit="退出 KO",frontlight="前光",
    miuread_settings="觅阅设置",downloads="下载",restart="重启 KOReader",sleep="休眠",full_refresh="全屏刷新",
}

M.RUNTIME_MODE_KEY = "__MIUREAD_RUNTIME_MODE"

local function book_time(book)
    if type(book) ~= "table" then return 0 end
    local function t(value) return tonumber(value) or 0 end
    local primary = math.max(
        t(book.local_recent_read_at), t(book.lastReadTime), t(book.readUpdateTime),
        t(book.last_read_at), t(book.opened_at))
    if primary > 0 then return primary end
    return math.max(t(book.cloudUpdatedAt), t(book.updateTime),
        t(book.downloadedAt), t(book.modified_at))
end

-- Pure shelf-row sorter shared by the home shelf and the 全部书籍 view.
-- sort: "recent" (default) | "added" | "title" | "author".
function M.sort_rows(rows, sort)
    rows = type(rows) == "table" and rows or {}
    sort = sort or "recent"
    local out = {}
    -- Lua 5.1 table.sort is not stable: pin the original index as the final
    -- tiebreak so identical keys keep a reproducible order.
    local indexed = {}
    for index, row in ipairs(rows) do indexed[index] = {row = row, index = index} end
    table.sort(indexed, function(x, y)
        local a, b = x.row, y.row
        if sort == "author" then
            local aa, ba = tostring(a.author or ""):lower(), tostring(b.author or ""):lower()
            if aa ~= ba then return aa < ba end
        elseif sort == "added" then
            local at = tonumber(a.created_at or a.added_at or a.updated_at or 0) or 0
            local bt = tonumber(b.created_at or b.added_at or b.updated_at or 0) or 0
            if at ~= bt then return at > bt end
        elseif sort ~= "title" then
            local at, bt = book_time(a), book_time(b)
            if at ~= bt then return at > bt end
        end
        local at, bt = tostring(a.title or ""):lower(), tostring(b.title or ""):lower()
        if at ~= bt then return at < bt end
        return x.index < y.index
    end)
    for index, entry in ipairs(indexed) do out[index] = entry.row end
    return out
end

-- Bottom-tab page key normalization (shelf/store/me, default shelf).
-- Single source of truth: view rendering, back behavior and persistence all
-- funnel through this so the page value can never drift.
function M.normalize_page(page)
    if page ~= "store" and page ~= "me" then return "shelf" end
    return page
end

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