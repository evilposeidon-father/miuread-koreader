local B = require("tests.lua.bootstrap")
local Transport = require("miuread.read_report_transport")

local T = {}

local function fake_http()
    local calls = {}
    return {
        calls = calls,
        store = { auth = function() return { api_key = "k123", cookies = { wr_skey = "12345678" } } end },
        request = function(_, opt)
            calls[#calls + 1] = { kind = "request", opt = opt }
            return "html", 200, {}, "url"
        end,
        post_json = function(_, url, data, opt)
            calls[#calls + 1] = { kind = "post_json", url = url, data = data, opt = opt }
            return { ok = 1 }, {}, {}
        end,
    }
end

function T.test_get_text_is_single_attempt_with_auth()
    local fh = fake_http()
    local tr = Transport:new(fh)
    tr:get_text("https://weread.qq.com/web/reader/x", { referer = "https://weread.qq.com/" })
    B.eq(#fh.calls, 1, "one request")
    local c = fh.calls[1]
    B.eq(c.kind, "request", "uses raw request")
    B.eq(c.opt.method, "GET", "GET method")
    B.eq(c.opt.retries, 0, "single attempt")
    B.eq(c.opt.auth, true, "auth enabled")
    B.eq(c.opt.headers.Referer, "https://weread.qq.com/", "referer header")
end

function T.test_report_read_is_single_attempt_with_origin()
    local fh = fake_http()
    local tr = Transport:new(fh)
    tr:report_read({ s = "sig" }, "https://weread.qq.com/web/reader/y")
    local c = fh.calls[1]
    B.eq(c.kind, "post_json", "uses post_json")
    B.eq(c.url, "https://weread.qq.com/web/book/read", "report URL")
    B.eq(c.opt.retries, 0, "single attempt")
    B.eq(c.opt.auth, true, "auth enabled")
    B.eq(c.opt.headers.Origin, "https://weread.qq.com", "origin header")
    B.eq(c.opt.headers.Referer, "https://weread.qq.com/web/reader/y", "referer header")
end

function T.test_gateway_uses_bearer_and_no_cookie()
    local fh = fake_http()
    local tr = Transport:new(fh)
    tr:get_progress("bk1")
    local c = fh.calls[1]
    B.eq(c.kind, "post_json", "uses post_json")
    B.eq(c.url, "https://i.weread.qq.com/api/agent/gateway", "gateway URL")
    B.eq(c.opt.auth, false, "no cookie for gateway")
    B.eq(c.opt.headers.Authorization, "Bearer k123", "bearer auth")
    B.eq(c.opt.retries, 0, "single attempt")
end

function T.test_catalog_post_has_cookie_headers()
    local fh = fake_http()
    local tr = Transport:new(fh)
    tr:post_json("https://weread.qq.com/web/book/chapterInfos", { bookIds = { "bk1" } }, { referer = "https://weread.qq.com/web/reader/z" })
    local c = fh.calls[1]
    B.eq(c.opt.auth, true, "auth enabled")
    B.eq(c.opt.headers.Origin, "https://weread.qq.com", "origin header")
    B.eq(c.opt.headers.Accept, "application/json, text/plain, */*", "accept header")
end

return T
