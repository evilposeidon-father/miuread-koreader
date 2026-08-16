-- Read-report HTTP transport over miuread.http.
--
-- MiuRead 4.5.33 replaces the legacy ltn12 client for the reading-time report
-- path. Every request is single-attempt (retries=0) because retry/backoff is
-- owned by read_report_service, not the transport; an internal retry could
-- double-report an elapsed interval.
local Protocol = require("miuread.protocol")

local Transport = {}
Transport.__index = Transport

function Transport:new(http)
    return setmetatable({ http = http }, self)
end

local function memory_store(settings)
    return {
        -- No on-disk rate-limit/pacing files in the subprocess.
        data_dir = "",
        temp_dir = "",
        auth = function()
            return {
                cookies = settings:get("cookies", {}),
                api_key = settings:get("api_key", ""),
                wr_ticket = settings:get("wr_ticket", ""),
                wr_wrpa = settings:get("wr_wrpa", ""),
                login_session_id = settings:get("login_session_id", ""),
            }
        end,
        save_auth = function(auth)
            auth = auth or {}
            if auth.cookies ~= nil then settings:set("cookies", auth.cookies) end
            if auth.api_key ~= nil then settings:set("api_key", auth.api_key) end
            if auth.wr_ticket ~= nil then settings:set("wr_ticket", auth.wr_ticket) end
            if auth.wr_wrpa ~= nil then settings:set("wr_wrpa", auth.wr_wrpa) end
        end,
    }
end
Transport.memory_store = memory_store

function Transport:get_text(url, opts)
    opts = opts or {}
    local text, code, headers = self.http:request({
        url = url,
        method = "GET",
        auth = true,
        retries = 0,
        headers = {
            Accept = opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            Referer = opts.referer or "https://weread.qq.com/",
        },
    })
    if code and code >= 200 and code < 300 then return text end
    error("HTTP " .. tostring(code) .. ", body_bytes=" .. tostring(#(text or "")))
end

function Transport:post_json(url, data, opts)
    opts = opts or {}
    return self.http:post_json(url, data, {
        auth = true,
        retries = 0,
        headers = {
            Origin = "https://weread.qq.com",
            Referer = opts.referer or "https://weread.qq.com/",
            Accept = "application/json, text/plain, */*",
        },
    })
end

function Transport:gateway(api_name, params)
    params = params or {}
    params.api_name = api_name
    params.skill_version = params.skill_version or Protocol.SKILL_VERSION
    local auth = self.http.store:auth()
    local api_key = auth.api_key or ""
    if api_key == "" then error("WeRead API key is not configured") end
    return self.http:post_json("https://i.weread.qq.com/api/agent/gateway", params, {
        auth = false,
        retries = 0,
        headers = { Authorization = "Bearer " .. api_key },
    })
end

function Transport:get_progress(book_id)
    local result = self:gateway("/book/getprogress", { bookId = book_id })
    if type(result) == "table" then
        result._progress_source = "agent_gateway"
        result._progress_fetched_at = os.time()
    end
    return result
end

function Transport:report_read(payload, referer)
    return self:post_json("https://weread.qq.com/web/book/read", payload, {
        referer = referer or "https://weread.qq.com/",
    })
end

return Transport
