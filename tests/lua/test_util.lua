local B = require("tests.lua.bootstrap")
local U = require("miuread.util")

local T = {}

function T.test_copy_deep_and_cycles()
    local source = {a = 1, b = {c = {d = 2}}}
    source.self = source
    local copy = U.copy(source)
    B.ok(copy ~= source, "copy is a new table")
    B.eq(copy.b.c.d, 2, "nested value copied")
    B.ok(copy.self == copy, "cycle preserved as cycle")
    B.ok(copy.b ~= source.b, "nested table copied, not shared")
    B.ok(U.copy(nil) == nil, "nil passes through")
end

function T.test_merge_deep()
    local merged = U.merge({a = 1, b = {x = 1, y = 2}}, {b = {y = 3, z = 4}})
    B.eq(merged.a, 1, "scalar kept")
    B.eq(merged.b.x, 1, "nested scalar kept")
    B.eq(merged.b.y, 3, "nested scalar replaced")
    B.eq(merged.b.z, 4, "nested scalar added")
end

function T.test_trim()
    B.eq(U.trim("  hello  "), "hello")
    B.eq(U.trim(nil), "")
end

function T.test_utf8_len()
    B.eq(U.utf8_len(""), 0)
    B.eq(U.utf8_len("abc"), 3)
    B.eq(U.utf8_len("微信读书"), 4)
    B.eq(U.utf8_len("a微b信c"), 5)
end

function T.test_utf8_sub()
    B.eq(U.utf8_sub("微信读书", 2, 3), "信读")
    B.eq(U.utf8_sub("微信读书", 1, 1), "微")
    B.eq(U.utf8_sub("abc", 2), "bc")
    B.eq(U.utf8_sub("abc", 2, 1), "")
end

function T.test_utf8_truncate()
    B.eq(U.utf8_truncate("微信读书", 2), "微信…")
    B.eq(U.utf8_truncate("微信", 2), "微信", "no ellipsis when nothing cut")
    B.eq(U.utf8_truncate("", 0), "")
    B.eq(U.utf8_truncate("abc", 1, "..."), "a...")
end

function T.test_utf8_validity()
    B.eq(U.is_valid_utf8("微信"), true)
    B.eq(U.is_valid_utf8("\255\254"), false)
    B.eq(U.contains_replacement_char("a\239\191\189b"), true)
    B.eq(U.replacement_char_count("a\239\191\189b\239\191\189"), 2)
end

function T.test_first_line_and_xml()
    B.eq(U.first_line("第一行\n第二行"), "第一行")
    B.eq(U.first_line("abc\r\ndef"), "abc")
    B.eq(U.xml('<a href="x">&\'</a>'), "&lt;a href=&quot;x&quot;&gt;&amp;&apos;&lt;/a&gt;")
end

function T.test_url_decode()
    B.eq(U.url_decode("a+b%2Fc%20d"), "a b/c d")
end

function T.test_safe_name()
    B.eq(U.safe_name("a/b\\c:d*e?f\"g<h>i|j"), "a_b_c_d_e_f_g_h_i_j")
    B.eq(U.safe_name("   "), "item")
end

return T
