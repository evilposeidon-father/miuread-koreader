-- Pure reader geometry helpers extracted from plugin_reader.lua.
-- Independent of the Plugin instance: callers pass the ui/document they own,
-- so these are unit-testable without a KOReader runtime.
local U = require("miuread.util")

local M = {}

-- Clamp a page ratio to [0,100]. Returns nil when inputs are unusable.
function M.progress_percent(ui, document)
    if not ui or not document then return nil end
    local current, total
    if type(ui.getCurrentPage) == "function" and type(document.getPageCount) == "function" then
        local ok_current, value_current = pcall(ui.getCurrentPage, ui)
        local ok_total, value_total = pcall(document.getPageCount, document)
        if ok_current and ok_total then current, total = tonumber(value_current), tonumber(value_total) end
    end
    if current and total and total > 0 then
        return math.max(0, math.min(100, current / total * 100))
    end
    local rolling = ui.rolling
    local pos = rolling and tonumber(rolling.current_page or rolling.current_pos)
    local pages = rolling and tonumber(rolling.page_count or rolling.full_height)
    if pos and pages and pages > 0 then return math.max(0, math.min(100, pos / pages * 100)) end
    return nil
end

-- Current page number from ui.getCurrentPage, falling back to rolling state.
function M.current_page(ui)
    if not ui then return nil end
    if type(ui.getCurrentPage) == "function" then
        local ok, value = pcall(ui.getCurrentPage, ui)
        if ok and tonumber(value) then return tonumber(value) end
    end
    local rolling = ui.rolling or nil
    return tonumber(rolling and (rolling.current_page or rolling.current_pos))
end

-- Nearest preceding ToC index for a page (fallback when getTocIndexByPage is
-- unreliable). Returns nil when no entry precedes the page.
function M.nearest_toc_index(source, current_page)
    if not current_page then return nil end
    local nearest_page = -math.huge
    local result
    for index, entry in ipairs(source) do
        local page = tonumber(entry.page or entry.pageno)
        if page and page <= current_page and page >= nearest_page then
            result = index
            nearest_page = page
        end
    end
    return result
end

-- Build the display items for a ToC source. Pure data — callers attach their
-- own callback; U is injected so headless tests can stub the trim helper.
function M.normalize_toc_items(source, current_index, trim)
    trim = trim or U.trim
    source = type(source) == "table" and source or {}
    local items = {}
    for index, entry in ipairs(source) do
        local title = trim(tostring(entry.title or entry.text or entry.name or ""))
        if title == "" then title = "未命名章节" end
        local page = tonumber(entry.page or entry.pageno)
        items[#items + 1] = {
            title = title,
            depth = tonumber(entry.depth or entry.level) or 1,
            page = page,
            page_label = entry.page_label or (page and tostring(page) or ""),
            current = current_index == index,
            destination_xpointer = entry.xpointer or entry.xp,
        }
    end
    return items
end

return M
