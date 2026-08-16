local B = require("tests.lua.bootstrap")
local C = require("miuread.codec")

local T = {}

function T.test_b64_known_vector()
    B.eq(C.b64encode("Man"), "TWFu", "b64 Man")
    B.eq(C.b64encode("Ma"), "TWE=", "b64 Ma")
    B.eq(C.b64encode("M"), "TQ==", "b64 M")
    B.eq(C.b64encode(""), "", "b64 empty")
end

function T.test_b64_roundtrip_utf8()
    local text = "微信读书 The quick brown fox 0123456789"
    B.eq(C.b64decode(C.b64encode(text)), text, "utf-8 roundtrip")
end

function T.test_b64_decode_urlsafe_and_junk()
    B.eq(C.b64decode("5b6u5L-h6K-75Lmm"), "微信读书", "url-safe base64 decodes")
    B.eq(C.b64decode("aGVsbG8=\n"), "hello", "newline junk tolerated")
end

function T.test_text_xhtml_escapes()
    local out = C.text_xhtml('a<b>&"c"')
    B.contains(out, "&lt;b&gt;", "escapes tag")
    B.contains(out, "&amp;", "escapes ampersand")
    B.contains(out, "&quot;", "escapes quote")
end

return T
