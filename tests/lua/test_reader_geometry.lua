-- Tests for miuread.reader_geometry (pure reader geometry helpers).

local B = require("tests.lua.bootstrap")
local Stubs = require("tests.lua.koreader_stubs")
Stubs.install()

local ReaderGeometry = require("miuread.reader_geometry")

local T = {}

function T.test_progress_percent_from_pages()
    local ui = { getCurrentPage = function() return 25 end }
    local document = { getPageCount = function() return 100 end }
    B.eq(ReaderGeometry.progress_percent(ui, document), 25, "25/100 → 25%")
end

function T.test_progress_percent_from_rolling()
    local ui = { rolling = { current_pos = 50, full_height = 200 } }
    local document = {}
    B.eq(ReaderGeometry.progress_percent(ui, document), 25, "50/200 → 25%")
end

function T.test_progress_percent_nil_when_no_ui()
    B.eq(ReaderGeometry.progress_percent(nil, nil), nil, "nil ui → nil")
end

function T.test_current_page_prefers_getCurrentPage()
    local ui = { getCurrentPage = function() return 42 end, rolling = { current_page = 7 } }
    B.eq(ReaderGeometry.current_page(ui), 42, "getCurrentPage wins")
end

function T.test_current_page_falls_back_to_rolling()
    local ui = { rolling = { current_pos = 99 } }
    B.eq(ReaderGeometry.current_page(ui), 99, "rolling fallback")
end

function T.test_nearest_toc_index_finds_preceding()
    local source = {
        { page = 1 }, { page = 10 }, { page = 25 }, { page = 50 },
    }
    B.eq(ReaderGeometry.nearest_toc_index(source, 30), 3, "entry at 25 precedes page 30")
    B.eq(ReaderGeometry.nearest_toc_index(source, 5), 1, "entry at 1 precedes page 5")
    B.eq(ReaderGeometry.nearest_toc_index(source, 0), nil, "no entry before page 0")
    B.eq(ReaderGeometry.nearest_toc_index(source, nil), nil, "nil page → nil")
end

function T.test_normalize_toc_items_basic()
    local items = ReaderGeometry.normalize_toc_items({
        { title = "第一章", page = 1, xpointer = "xp1" },
        { text = "第二章", pageno = 20, level = 2 },
        { name = "" },
    }, 2, function(v) return tostring(v) end)
    B.eq(#items, 3, "three items")
    B.eq(items[1].title, "第一章", "title from title field")
    B.eq(items[1].page, 1, "page from page field")
    B.eq(items[1].current, false, "item 1 not current")
    B.eq(items[2].current, true, "item 2 current")
    B.eq(items[2].depth, 2, "depth from level")
    B.eq(items[3].title, "未命名章节", "empty title falls back")
end

function T.test_normalize_toc_items_empty_title_via_trim()
    local items = ReaderGeometry.normalize_toc_items({
        { title = "  " }, { title = "真章" },
    }, nil, function(v) return v == "  " and "" or tostring(v) end)
    B.eq(items[1].title, "未命名章节", "whitespace title → fallback")
    B.eq(items[2].title, "真章", "real title kept")
end

return T
