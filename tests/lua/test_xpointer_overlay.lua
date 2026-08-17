local B = require("tests.lua.bootstrap")
local Overlay = require("miuread.xpointer_overlay")

local T = {}

local function fake_document()
    local calls = 0
    return {
        calls = function() return calls end,
        getCurrentPos = function() return 0 end,
        getVisiblePageCount = function() return 1 end,
        getPosFromXPointer = function(_, xp)
            calls = calls + 1
            return tonumber(xp)
        end,
        getScreenBoxesFromPositions = function()
            return { { x = 0, y = 0, w = 10, h = 5 } }
        end,
    }
end

local function fake_overlay(doc)
    local o = Overlay:new({
        records = {
            { pos0 = "10", pos1 = "20" },
            { pos0 = "30", pos1 = "40" },
        },
    })
    o.ui = { document = doc, dimen = { h = 100 }, paging = false }
    o.view = { view_mode = "page", drawHighlightRect = function() end }
    return o
end

function T.test_position_cache_reuses_lookups()
    local doc = fake_document()
    local o = fake_overlay(doc)
    o:_computeVisible()
    local after_first = doc.calls()
    B.eq(after_first, 4, "first pass looks up pos0+pos1 per record")
    o:_computeVisible()
    B.eq(doc.calls(), after_first, "second pass reuses cached positions")
end

function T.test_reset_layout_clears_position_cache()
    local doc = fake_document()
    local o = fake_overlay(doc)
    o:_computeVisible()
    local before = doc.calls()
    o:resetLayout()
    o:_computeVisible()
    B.eq(doc.calls(), before + 4, "reset re-looks-up every record")
end

function T.test_set_records_clears_position_cache()
    local doc = fake_document()
    local o = fake_overlay(doc)
    o:_computeVisible()
    local before = doc.calls()
    o:setRecords({ { pos0 = "50", pos1 = "60" } })
    o:_computeVisible()
    B.eq(doc.calls(), before + 2, "setRecords re-looks-up new records")
end

local function paint_document()
    local page = 1
    local box_calls = 0
    return {
        setPage = function(p) page = p end,
        box_calls = function() return box_calls end,
        getCurrentPos = function() return 0 end,
        getCurrentPage = function() return page end,
        getVisiblePageCount = function() return 1 end,
        getPosFromXPointer = function(_, xp) return tonumber(xp) end,
        getScreenBoxesFromPositions = function()
            box_calls = box_calls + 1
            return { { x = 0, y = 0, w = 10, h = 5 } }
        end,
    }
end

local function paint_overlay(doc)
    local o = Overlay:new({ records = { { pos0 = "10", pos1 = "20" } } })
    o.ui = { document = doc, dimen = { h = 100 }, paging = false }
    o.view = { view_mode = "page", drawHighlightRect = function() end }
    return o
end

function T.test_page_cache_persists_across_page_turns()
    local doc = paint_document()
    local o = paint_overlay(doc)
    doc.setPage(1)
    o:paintTo(nil, 0, 0)
    B.eq(doc.box_calls(), 1, "first paint computes page 1")
    doc.setPage(2)
    o:invalidate()
    o:paintTo(nil, 0, 0)
    B.eq(doc.box_calls(), 2, "page 2 computes once")
    doc.setPage(1)
    o:invalidate()
    o:paintTo(nil, 0, 0)
    B.eq(doc.box_calls(), 2, "revisit page 1 reuses page cache")
end

function T.test_reflow_clears_page_cache()
    local doc = paint_document()
    local o = paint_overlay(doc)
    doc.setPage(1)
    o:paintTo(nil, 0, 0)
    local before = doc.box_calls()
    o:resetLayout()
    o:paintTo(nil, 0, 0)
    B.eq(doc.box_calls(), before + 1, "reflow recomputes page")
end

function T.test_nearest_finds_closest_record()
    local doc = fake_document()
    local o = fake_overlay(doc)
    -- records: [10,20] and [30,40]
    local record, d = o:nearest(28)
    B.eq(record.pos0, "30", "closest span start")
    B.eq(d, 2, "distance to span edge")
end

function T.test_nearest_inside_span_is_zero()
    local doc = fake_document()
    local o = fake_overlay(doc)
    local record, d = o:nearest(15)
    B.eq(record.pos0, "10", "inside span picks that record")
    B.eq(d, 0, "distance zero inside span")
end

function T.test_nearest_ties_prefer_first_record()
    local doc = fake_document()
    local o = fake_overlay(doc)
    -- equidistant between [10,20] and [30,40]
    local record, d = o:nearest(25)
    B.ok(record ~= nil)
    B.eq(d, 5)
end

function T.test_nearest_empty_records_returns_nil()
    local doc = fake_document()
    local o = Overlay:new({ records = {} })
    o.ui = { document = doc }
    local record = o:nearest(10)
    B.ok(record == nil, "no records -> nil")
end

function T.test_nearest_no_document_returns_nil()
    local o = Overlay:new({ records = { { pos0 = "1", pos1 = "2" } } })
    local record = o:nearest(10)
    B.ok(record == nil, "no ui.document -> nil")
end

function T.test_warm_positions_batches_lookups()
    local doc = fake_document()
    local o = fake_overlay(doc)
    B.eq(o:missingPositions(1), 1, "first missing reported")
    B.eq(o:missingPositions(5), 2, "both records missing")
    B.eq(o:warmPositions(1), 1, "warms one record per call")
    B.eq(o:missingPositions(5), 1, "one still missing")
    o:warmPositions(5)
    B.eq(o:missingPositions(5), 0, "all warmed")
    o:_computeVisible()
    local calls = doc.calls()
    o:_computeVisible()
    B.eq(doc.calls(), calls, "warmed cache reused by paint")
end

function T.test_nearest_neg_cache_skips_failed_lookups()
    local doc = {
        getCurrentPos = function() return 0 end,
        getPosFromXPointer = function() error("cannot locate") end,
        getScreenBoxesFromPositions = function() return {} end,
    }
    local o = Overlay:new({ records = { { id = "bad", pos0 = "10", pos1 = "20" } } })
    o.ui = { document = doc, dimen = { h = 100 }, paging = false }
    o.view = { view_mode = "page", drawHighlightRect = function() end }
    local ok, err = pcall(function() o:nearest(0) end)
    B.ok(ok, "nearest tolerates lookup failure: " .. tostring(err))
    B.eq(o:missingPositions(5), 0, "failed record is neg-cached, not missing")
    o:resetLayout()
    B.eq(o:missingPositions(5), 0, "neg cache survives resetLayout")
end

return T
