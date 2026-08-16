local B = require("tests.lua.bootstrap")
local D = require("miuread.digests")

local T = {}

function T.test_md5_vectors()
    B.eq(D.md5(""), "d41d8cd98f00b204e9800998ecf8427e", "md5 empty")
    B.eq(D.md5("abc"), "900150983cd24fb0d6963f7d28e17f72", "md5 abc")
    B.eq(D.md5("The quick brown fox jumps over the lazy dog"),
        "9e107d9d372bb6826bd81d3542a419d6", "md5 fox")
    B.eq(D.md5("微信读书"), "664b5d039b78fe3d81097e9977924823", "md5 utf-8")
end

function T.test_sha256_vectors()
    B.eq(D.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 empty")
    B.eq(D.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 abc")
    B.eq(D.sha256("The quick brown fox jumps over the lazy dog"),
        "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592", "sha256 fox")
    B.eq(D.sha256("微信读书"), "987dccf2ea2b28cc25cfa87ead5e9d9320b8dcccebdbfacf326559ed2c0941a0", "sha256 utf-8")
end

function T.test_nil_input_is_empty_string()
    B.eq(D.md5(nil), D.md5(""), "md5 nil == md5 empty")
    B.eq(D.sha256(nil), D.sha256(""), "sha256 nil == sha256 empty")
end

return T
