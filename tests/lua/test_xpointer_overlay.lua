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

return T
