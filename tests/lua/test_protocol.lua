local B = require("tests.lua.bootstrap")
local P = require("miuread.protocol")

local T = {}

local UA = P.USER_AGENT
local QUERY = "b=abc123&c=xyz&r=42"

function T.test_sign_golden_vector()
    B.eq(P.web_sign(QUERY), "2bb1475a", "sign golden vector")
end

function T.test_obfuscate_golden_vectors()
    B.eq(P.obfuscate("1234567890"), "e80329f0775bcd15g0109e5", "numeric obfuscate")
    B.eq(P.obfuscate("hello-book"), "dc842741468656c6c6f2d626f6f6b14f", "string obfuscate")
    B.eq(P.obfuscate(42), "a1d32a6022aa1d0c6e83eb4", "integer obfuscate")
end

function T.test_app_id_and_escape()
    B.eq(P.app_id(UA), "wb115321887466h529830856", "app_id golden vector")
    B.eq(P.escape("a b&c=中文"), "a%20b%26c%3D%E4%B8%AD%E6%96%87", "escape golden vector")
end

function T.test_reader_url_golden()
    B.eq(P.reader_url("book_123"), "https://weread.qq.com/web/reader/8e242b510626f6f6b5f313233bfb", "reader_url golden vector")
end

function T.test_read_fields_golden()
    local t = P.read_fields({
        book_id = "bk1", chapter_uid = 777, chapter_index = 3, chapter_offset = 120,
        progress = 42, summary = "总结", elapsed = 30,
        app_id = P.app_id(UA), psvts = "psvts_abc", pclts = "pclts_def",
        token = "tok123", now = 1700000000, ts = 1700000000123, rn = 7,
    })
    B.eq(t.s, "8da65c8a", "read payload signature golden")
    B.eq(t.sg, "a85105e7143b10df73b6fea8fb9e1cfeb51b38c21000d2d4d9f8f960c3daf3c7", "read payload sg golden")
    B.eq(t.b, "a4042c906626b31a407fd1c", "read payload b golden")
    B.eq(t.c, "f1c323303309f1c159253cf", "read payload c golden")
    B.eq(t.pr, 42, "pr")
    B.eq(t.ci, 3, "ci")
    B.eq(t.co, 120, "co")
    B.eq(t.rt, 30, "rt")
end

function T.test_reader_token_single_source()
    local C = require("miuread.config")
    B.eq(P.READER_TOKEN, C.READER_TOKEN, "protocol reads token from config")
    B.eq(C.READER_TOKEN, "3c5c8717f3daf09iop3423zafeqoi", "reader token default")
end

return T
