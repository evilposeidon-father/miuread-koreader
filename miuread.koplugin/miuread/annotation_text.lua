-- Annotation text-processing helpers, extracted from annotations.lua.
--
-- MiuRead 4.5.38 moved the pure UTF-8/HTML unit, tokenizer, text-index and
-- normalization helpers into this deep module so quote location can be
-- unit-tested independently.
local M = {}

local function utf8_len_at(text, i)
    local c = text:byte(i)
    if not c or c < 0x80 then return 1 end
    if c < 0xE0 then return 2 end
    if c < 0xF0 then return 3 end
    return 4
end

local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = " ", ensp = " ", emsp = " ", thinsp = " ",
    hellip = "…", mdash = "—", ndash = "–",
    lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”",
    zwnj = "", zwj = "",
}

local function utf8_encode(codepoint)
    codepoint = tonumber(codepoint)
    if not codepoint or codepoint < 0 or codepoint > 0x10FFFF
        or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
        return nil
    end
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
    elseif codepoint < 0x10000 then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + (math.floor(codepoint / 0x40) % 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    return string.char(
        0xF0 + math.floor(codepoint / 0x40000),
        0x80 + (math.floor(codepoint / 0x1000) % 0x40),
        0x80 + (math.floor(codepoint / 0x40) % 0x40),
        0x80 + (codepoint % 0x40)
    )
end

local function decode_html_unit(unit)
    unit = tostring(unit or "")
    local decimal = unit:match("^&#(%d+);$")
    if decimal then return utf8_encode(tonumber(decimal, 10)) or unit end
    local hexadecimal = unit:match("^&#[xX]([%x]+);$")
    if hexadecimal then return utf8_encode(tonumber(hexadecimal, 16)) or unit end
    local named = unit:match("^&([%w]+);$")
    if named and NAMED_ENTITIES[named] ~= nil then return NAMED_ENTITIES[named] end
    return unit
end

local function split_units(raw)
    local units, p = {}, 1
    while p <= #raw do
        local entity = raw:sub(p):match("^&[#%w]+;")
        if entity then
            units[#units + 1] = entity
            p = p + #entity
        else
            local n = utf8_len_at(raw, p)
            units[#units + 1] = raw:sub(p, p + n - 1)
            p = p + n
        end
    end
    return units
end

local function is_ignorable_text(value)
    if value == nil or value == "" then return true end
    if value:match("^%s+$") then return true end
    return value == "\194\160"       -- non-breaking space
        or value == "\227\128\128" -- ideographic space
        or value == "\226\128\139" -- zero-width space
        or value == "\226\128\140" -- zero-width non-joiner
        or value == "\226\128\141" -- zero-width joiner
        or value == "\239\187\191" -- UTF-8 BOM
end

local SKIP_TEXT_TAGS = {
    script = true, style = true, noscript = true, template = true, svg = true,
}

local function tag_info(raw)
    local slash, name = tostring(raw or ""):match("^<%s*(/?)%s*([%w:_%-]+)")
    if not name then return false, "", false end
    return slash == "/", name:lower(), tostring(raw):match("/%s*>$") ~= nil
end

local function tokenize(html)
    local tokens, visible = {}, 0
    local i, skip_depth, anchor_depth = 1, 0, 0
    while i <= #html do
        if html:sub(i, i) == "<" then
            local j = html:find(">", i + 1, true)
            if not j then
                local raw = html:sub(i)
                tokens[#tokens + 1] = {
                    kind="text", raw=raw, units=split_units(raw), start=visible,
                    skip=skip_depth > 0, inside_anchor=anchor_depth > 0,
                }
                if skip_depth == 0 then visible = visible + #tokens[#tokens].units end
                break
            end
            local raw = html:sub(i, j)
            local closing, name, self_closing = tag_info(raw)
            if closing and name == "a" then anchor_depth = math.max(0, anchor_depth - 1) end
            tokens[#tokens + 1] = {kind="tag", raw=raw}
            if closing and SKIP_TEXT_TAGS[name] then
                skip_depth = math.max(0, skip_depth - 1)
            elseif not closing and not self_closing and SKIP_TEXT_TAGS[name] then
                skip_depth = skip_depth + 1
            end
            if not closing and not self_closing and name == "a" then anchor_depth = anchor_depth + 1 end
            i = j + 1
        else
            local j = html:find("<", i, true) or (#html + 1)
            local raw = html:sub(i, j - 1)
            local units = split_units(raw)
            local skipped = skip_depth > 0
            tokens[#tokens + 1] = {
                kind="text", raw=raw, units=units, start=visible,
                stop=skipped and visible or (visible + #units), skip=skipped,
                inside_anchor=anchor_depth > 0,
            }
            if not skipped then visible = visible + #units end
            i = j
        end
    end
    return tokens, visible
end

local function utf16_width(value)
    local first = tostring(value or ""):byte(1) or 0
    return first >= 0xF0 and 2 or 1
end

local function build_text_index(tokens)
    local pieces, starts, ends, ordinals = {}, {}, {}, {}
    local compact_bounds, utf16_bounds = {}, {}
    local byte_pos, compact_count, utf16_count = 1, 0, 0

    for _, token in ipairs(tokens or {}) do
        if token.kind == "text" and not token.skip then
            for index, unit in ipairs(token.units or {}) do
                local raw_pos = token.start + index - 1
                local decoded = decode_html_unit(unit)

                if utf16_bounds[utf16_count] == nil then utf16_bounds[utf16_count] = raw_pos end
                local width = utf16_width(decoded)
                if width > 1 then
                    for extra = 1, width - 1 do utf16_bounds[utf16_count + extra] = raw_pos end
                end
                utf16_count = utf16_count + width
                utf16_bounds[utf16_count] = raw_pos + 1

                if not is_ignorable_text(decoded) then
                    compact_bounds[compact_count] = compact_bounds[compact_count] or raw_pos
                    pieces[#pieces + 1] = decoded
                    starts[byte_pos] = raw_pos
                    ordinals[byte_pos] = compact_count
                    local end_byte = byte_pos + #decoded - 1
                    ends[end_byte] = raw_pos + 1
                    byte_pos = end_byte + 1
                    compact_count = compact_count + 1
                    compact_bounds[compact_count] = raw_pos + 1
                end
            end
        end
    end

    return {
        text = table.concat(pieces), starts = starts, ends = ends, ordinals = ordinals,
        compact_bounds = compact_bounds, compact_count = compact_count,
        utf16_bounds = utf16_bounds, utf16_count = utf16_count,
    }
end

local function normalize_text(value)
    local raw = tostring(value or ""):gsub("<[^>]+>", "")
    local out, count = {}, 0
    for _, unit in ipairs(split_units(raw)) do
        local decoded = decode_html_unit(unit)
        if not is_ignorable_text(decoded) then
            out[#out + 1] = decoded
            count = count + 1
        end
    end
    return table.concat(out), count
end

M.utf8_len_at = utf8_len_at
M.utf8_encode = utf8_encode
M.decode_html_unit = decode_html_unit
M.split_units = split_units
M.is_ignorable_text = is_ignorable_text
M.tag_info = tag_info
M.tokenize = tokenize
M.utf16_width = utf16_width
M.build_text_index = build_text_index
M.normalize_text = normalize_text
M.NAMED_ENTITIES = NAMED_ENTITIES
M.SKIP_TEXT_TAGS = SKIP_TEXT_TAGS

return M
