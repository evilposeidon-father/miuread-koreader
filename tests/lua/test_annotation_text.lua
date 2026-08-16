local B = require("tests.lua.bootstrap")
local AT = require("miuread.annotation_text")

local T = {}

function T.test_utf8_helpers()
    B.eq(AT.utf8_len_at("a", 1), 1, "ascii width")
    B.eq(AT.utf8_len_at("中", 1), 3, "cjk width")
    B.eq(AT.utf8_encode(0x4E2D), "中", "encode cjk")
    B.eq(AT.utf8_encode(65), "A", "encode ascii")
    B.eq(AT.utf8_encode(-1), nil, "invalid codepoint")
end

function T.test_decode_html_unit()
    B.eq(AT.decode_html_unit("&#65;"), "A", "decimal entity")
    B.eq(AT.decode_html_unit("&#x4E2D;"), "中", "hex entity")
    B.eq(AT.decode_html_unit("&amp;"), "&", "named entity")
    B.eq(AT.decode_html_unit("plain"), "plain", "no entity")
end

function T.test_split_units()
    local units = AT.split_units("a&amp;b")
    B.eq(#units, 3, "three units")
    B.eq(units[1], "a", "unit 1")
    B.eq(units[2], "&amp;", "unit 2")
    B.eq(units[3], "b", "unit 3")
end

function T.test_ignorable_text()
    B.eq(AT.is_ignorable_text(""), true, "empty")
    B.eq(AT.is_ignorable_text("   "), true, "whitespace")
    B.eq(AT.is_ignorable_text("a"), false, "visible")
end

function T.test_tag_info()
    local slash1, name1, self1 = AT.tag_info("<p>")
    B.eq(slash1, false, "open slash")
    B.eq(name1, "p", "open name")
    B.eq(self1, false, "open self")
    local slash2, name2 = AT.tag_info("</p>")
    B.eq(slash2, true, "close slash")
    B.eq(name2, "p", "close name")
    local _, _, self3 = AT.tag_info("<br/>")
    B.eq(self3, true, "self closing")
end

function T.test_tokenize_and_index()
    local tokens, visible = AT.tokenize("<p>hi</p>")
    B.eq(#tokens, 3, "three tokens")
    B.eq(visible, 2, "two visible units")
    local idx = AT.build_text_index(tokens)
    B.eq(idx.text, "hi", "index text")
    B.eq(idx.compact_count, 2, "compact count")
    local text, count = AT.normalize_text("<p>a&amp;b</p>")
    B.eq(text, "a&b", "normalized text")
    B.eq(count, 3, "normalized count")
end

return T
