--[[--
Renderer for plugin-owned XPointer annotations projected onto arbitrary local
books. Records are deliberately kept outside KOReader's annotation array. This
view module projects only the records intersecting the current CREngine view to
screen rectangles and paints them in ReaderView's existing paint pass.

This module has no KOReader imports so its visibility filtering, cache, and hit
testing remain independently testable.
--]]--

local Overlay = {}
Overlay.__index = Overlay

local function inside(rect, pos, padding)
    if not rect or not pos then return false end
    padding = padding or 0
    return pos.x >= rect.x - padding
        and pos.x <= rect.x + rect.w + padding
        and pos.y >= rect.y - padding
        and pos.y <= rect.y + rect.h + padding
end

function Overlay:new(opts)
    opts = opts or {}
    return setmetatable({
        records = opts.records or {},
        enabled = opts.enabled ~= false,
        cache = {},
        pos_cache = {},
        visible = {},
        generation = 1,
        clock = opts.clock or os.clock,
        hit_padding = tonumber(opts.hit_padding) or 3,
        last_metrics = {
            candidates = 0,
            boxes = 0,
            elapsed_ms = 0,
            cache_hit = false,
        },
    }, self)
end

function Overlay:setRecords(records)
    records = type(records) == "table" and records or {}
    -- Incremental cache retention: keep position cache entries whose record id
    -- is unchanged so a chapter merge does not force 2N XPointer lookups on
    -- the next frame (fluency review).
    local retained = {}
    if #records > 0 and self.pos_cache then
        local old = self.pos_cache
        local old_records = self.records
        for index, record in ipairs(old_records or {}) do
            local id = type(record) == "table" and tostring(record.id or record.range or "")
            if id ~= "" and old and old[index] then
                retained[id] = old[index]
            end
        end
    end
    self.records = records
    local pos_cache = {}
    for index, record in ipairs(records) do
        local id = type(record) == "table" and tostring(record.id or record.range or "")
        if id ~= "" and retained[id] then pos_cache[index] = retained[id] end
    end
    self.pos_cache = pos_cache
    self.cache = {}
    self:invalidate()
end

function Overlay:setEnabled(enabled)
    self.enabled = enabled ~= false
    self.visible = {}
end

-- Distance from a numeric document position to a span [s, e]. Zero when the
-- position falls inside the span (the reader is on that annotation).
local function distance_to_span(pos, s, e)
    if pos < s then return s - pos end
    if pos > e then return pos - e end
    return 0
end

local NEG_CACHE_TTL = 30

-- Negative-cache hit? Failed lookups are remembered for a short TTL so
-- paint/nearest/warmup never hammer a record every pass, while a transient
-- failure (e.g. document mid-reflow) is retried once the TTL elapses.
local function neg_cached(overlay, record)
    local rid = type(record) == "table" and tostring(record.id or record.range or "")
    if rid == "" then return false end
    local at = overlay._nearest_neg_cache and overlay._nearest_neg_cache[rid]
    return at ~= nil and os.time() - tonumber(at) < NEG_CACHE_TTL
end

-- Resolve one record's numeric span [s, e], reusing pos_cache when the entry
-- matches, otherwise performing the two XPointer lookups. Failures enter the
-- negative cache so paint/nearest/warmup never hammer a record that cannot
-- locate. Returns (s, e) or nil.
local function lookup_span(overlay, index, record)
    local document = overlay.ui and overlay.ui.document
    if not document or type(document.getPosFromXPointer) ~= "function" then return nil end
    local cached = overlay.pos_cache and overlay.pos_cache[index]
    if cached and cached.pos0 == record.pos0 and cached.pos1 == record.pos1
        and cached.s ~= nil and cached.e ~= nil then
        return cached.s, cached.e
    end
    local rid = type(record) == "table" and tostring(record.id or record.range or "")
    if neg_cached(overlay, record) then
        -- Recent lookup failure: skip the expensive retry this pass.
        return nil
    end
    local ok_start, sv = pcall(document.getPosFromXPointer, document, record.pos0)
    local ok_end, ev = pcall(document.getPosFromXPointer, document, record.pos1)
    local s, e = tonumber(sv), tonumber(ev)
    if ok_start and ok_end and s ~= nil and e ~= nil then
        overlay.pos_cache = overlay.pos_cache or {}
        overlay.pos_cache[index] = { pos0 = record.pos0, pos1 = record.pos1, s = s, e = e }
        return s, e
    end
    if rid ~= "" then
        overlay._nearest_neg_cache = overlay._nearest_neg_cache or {}
        overlay._nearest_neg_cache[rid] = os.time()
    end
    return nil
end

-- Find the record whose numeric span [s, e] is closest to pos (a value
-- from document:getCurrentPos()). Returns (record, distance) or (nil).
-- Reuses the position cache; falls back to a live XPointer lookup when the
-- cache entry is missing or stale.
function Overlay:nearest(pos)
    local document = self.ui and self.ui.document
    pos = tonumber(pos)
    if not document or not pos or #self.records == 0 then return nil end
    if type(document.getPosFromXPointer) ~= "function" then return nil end
    local best, best_distance
    for index, record in ipairs(self.records) do
        if type(record) == "table" and record.pos0 and record.pos1 then
            local s, e = lookup_span(self, index, record)
            if s ~= nil and e ~= nil then
                local d = distance_to_span(pos, s, e)
                if best == nil or d < best_distance then
                    best, best_distance = record, d
                end
            end
        end
    end
    return best, best_distance
end

-- Number of records still lacking a usable position cache entry (cheap:
-- no XPointer work). Used by the plugin frame-batched warmup.
function Overlay:missingPositions(limit)
    limit = tonumber(limit) or 1
    local count = 0
    for index, record in ipairs(self.records) do
        if type(record) == "table" and record.pos0 and record.pos1 then
            local cached = self.pos_cache and self.pos_cache[index]
            if not (cached and cached.pos0 == record.pos0 and cached.pos1 == record.pos1
                and cached.s ~= nil and cached.e ~= nil) then
                if not neg_cached(self, record) then
                    count = count + 1
                    if count >= limit then break end
                end
            end
        end
    end
    return count
end

-- Resolve up to limit missing position cache entries. Called between paint
-- frames (plugin-scheduled) so a large record set warms up incrementally
-- instead of stalling the next paint pass with 2N XPointer lookups.
function Overlay:warmPositions(limit)
    limit = tonumber(limit) or 32
    local warmed = 0
    for index, record in ipairs(self.records) do
        if warmed >= limit then break end
        if type(record) == "table" and record.pos0 and record.pos1 then
            local cached = self.pos_cache and self.pos_cache[index]
            if not (cached and cached.pos0 == record.pos0 and cached.pos1 == record.pos1
                and cached.s ~= nil and cached.e ~= nil) then
                if not neg_cached(self, record) then
                    local s, e = lookup_span(self, index, record)
                    if s ~= nil and e ~= nil then warmed = warmed + 1 end
                end
            end
        end
    end
    return warmed
end

function Overlay:invalidate()
    self.generation = self.generation + 1
    self.visible = {}
end

function Overlay:resetLayout()
    self.cache = {}
    self.pos_cache = {}
    self:invalidate()
end

local function draw_boxes(overlay, bb, x, y, boxes)
    overlay.visible = {}
    for _, entry in ipairs(boxes) do
        overlay.visible[#overlay.visible + 1] = entry
        -- Reuse KOReader's native underline renderer in ReaderView's existing
        -- paint pass, without requesting an additional e-ink refresh.
        overlay.view:drawHighlightRect(
            bb, x, y, entry.rect, "underscore", nil, false
        )
    end
end

function Overlay:_computeVisible()
    local document = self.ui and self.ui.document
    local view = self.view
    if not document or not view or self.ui.paging then
        return {}, 0
    end
    if type(document.getCurrentPos) ~= "function"
        or type(document.getPosFromXPointer) ~= "function"
        or type(document.getScreenBoxesFromPositions) ~= "function" then
        return {}, 0
    end

    local top = tonumber(document:getCurrentPos()) or 0
    local height = self.ui.dimen and tonumber(self.ui.dimen.h) or 0
    local visible_pages = type(document.getVisiblePageCount) == "function"
        and tonumber(document:getVisiblePageCount()) or 1
    local bottom = top + height * math.max(1, visible_pages or 1)
    local visible = {}
    local candidates = 0

    for index, record in ipairs(self.records) do
        if type(record) == "table" and record.pos0 and record.pos1 then
            local start_pos, end_pos = lookup_span(self, index, record)
            if start_pos ~= nil and end_pos ~= nil
                and start_pos <= bottom and end_pos >= top then
                candidates = candidates + 1
                local ok_boxes, boxes = pcall(
                    document.getScreenBoxesFromPositions,
                    document, record.pos0, record.pos1, true
                )
                if ok_boxes and type(boxes) == "table" then
                    for _, rect in ipairs(boxes) do
                        if type(rect) == "table" and tonumber(rect.h) ~= 0 then
                            visible[#visible + 1] = {
                                rect = rect,
                                record = record,
                            }
                        end
                    end
                end
            end
        end
    end
    return visible, candidates
end

function Overlay:paintTo(bb, x, y)
    local started = self.clock()
    if not self.enabled or #self.records == 0 then
        self.visible = {}
        self.last_metrics = {
            candidates = 0,
            boxes = 0,
            elapsed_ms = (self.clock() - started) * 1000,
            cache_hit = false,
        }
        return
    end

    local document = self.ui and self.ui.document
    if not document then return end
    local ok_page, page_value = false, nil
    if type(document.getCurrentPage) == "function" then
        ok_page, page_value = pcall(document.getCurrentPage, document)
    end
    local page = ok_page and tonumber(page_value) or 0
    local can_cache = self.view and self.view.view_mode == "page"
    local cache_key = tostring(page)
    local cached = can_cache and self.cache[cache_key] or nil
    local boxes, candidates
    if cached then
        boxes = cached.boxes
        candidates = cached.candidates
    else
        boxes, candidates = self:_computeVisible()
        if can_cache then
            self.cache[cache_key] = {
                boxes = boxes,
                candidates = candidates,
            }
        end
    end
    draw_boxes(self, bb, x, y, boxes)
    self.last_metrics = {
        candidates = candidates,
        boxes = #boxes,
        elapsed_ms = (self.clock() - started) * 1000,
        cache_hit = cached ~= nil,
    }
end

function Overlay:hitTest(pos)
    for index = #self.visible, 1, -1 do
        local entry = self.visible[index]
        if inside(entry.rect, pos, self.hit_padding) then
            return entry.record
        end
    end
end

return Overlay
