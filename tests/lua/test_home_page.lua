local B = require("tests.lua.bootstrap")

local HomeLayouts = require("miuread.home_layout_constants")

local T = {}

function T.test_normalize_page_defaults_to_shelf()
    B.eq(HomeLayouts.normalize_page(nil), "shelf", "nil -> shelf")
    B.eq(HomeLayouts.normalize_page(false), "shelf", "false -> shelf")
    B.eq(HomeLayouts.normalize_page("bogus"), "shelf", "unknown -> shelf")
    B.eq(HomeLayouts.normalize_page(""), "shelf", "empty -> shelf")
end

function T.test_normalize_page_passes_known_keys()
    B.eq(HomeLayouts.normalize_page("shelf"), "shelf")
    B.eq(HomeLayouts.normalize_page("store"), "store")
    B.eq(HomeLayouts.normalize_page("me"), "me")
end

function T.test_sort_rows_recent_puts_last_read_first()
    local rows = {
        {title = "旧书", lastReadTime = 100},
        {title = "新书", lastReadTime = 200},
        {title = "未读", lastReadTime = 0},
    }
    local sorted = HomeLayouts.sort_rows(rows, "recent")
    B.eq(sorted[1].title, "新书", "most recent first")
    B.eq(sorted[2].title, "旧书")
    B.eq(sorted[3].title, "未读")
    B.eq(#sorted, 3, "input untouched size")
end

function T.test_sort_rows_title_falls_back_to_name()
    local rows = {
        {title = "Beta"},
        {title = "Alpha"},
        {title = "Gamma"},
    }
    local sorted = HomeLayouts.sort_rows(rows, "title")
    B.eq(sorted[1].title, "Alpha")
    B.eq(sorted[2].title, "Beta")
    B.eq(sorted[3].title, "Gamma")
end

function T.test_sort_rows_author_groups_by_author()
    local rows = {
        {title = "A", author = "李四"},
        {title = "B", author = "张三"},
        {title = "C", author = "张三"},
    }
    local sorted = HomeLayouts.sort_rows(rows, "author")
    B.eq(sorted[1].author, "张三")
    B.eq(sorted[2].author, "张三")
    B.eq(sorted[3].author, "李四")
end

function T.test_sort_rows_defaults_to_recent_and_handles_empty()
    B.eq(#HomeLayouts.sort_rows(nil, nil), 0, "empty input")
    B.eq(#HomeLayouts.sort_rows({}, "bogus"), 0, "unknown sort tolerated")
    local rows = {{title = "X", lastReadTime = 50}, {title = "Y"}}
    local sorted = HomeLayouts.sort_rows(rows, nil)
    B.eq(sorted[1].title, "X")
end

return T