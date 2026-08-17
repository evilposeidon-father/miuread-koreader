-- Crash report builder: detects a new crash from crash.log growth, extracts
-- the tail, and assembles a markdown report from diagnostic context + recent
-- oplog. Pure logic (no file I/O, no KOReader); the plugin controller feeds
-- in the inputs so the whole pipeline is headless-testable.

local CrashReport = {}

local CRASH_PATTERNS = { "PANIC", "stack traceback", "Fatal signal", "Segmentation fault" }

function CrashReport.escape_pattern(s)
    return (tostring(s):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- Loose classifier: does this log content look like a crash? The growth check
-- is the primary signal; this only avoids spurious reports on routine noise.
function CrashReport.is_crash_content(text)
    text = tostring(text or "")
    for _, marker in ipairs(CRASH_PATTERNS) do
        if text:find(marker, 1, true) then return true end
    end
    return false
end

-- Keep the last max_bytes of text aligned to a line boundary. Returns the
-- trimmed tail and whether truncation happened.
function CrashReport.extract_tail(text, max_bytes)
    max_bytes = tonumber(max_bytes) or 4096
    if max_bytes < 1 then max_bytes = 1 end
    text = tostring(text or "")
    local total = #text
    if total <= max_bytes then return text, false end
    local start = total - max_bytes + 1
    local nl = text:find("\n", start)
    if nl then start = nl + 1 end
    return text:sub(start), true
end

-- Decide whether to report, given the marker saved by the previous run and
-- the current crash.log state. Growth beyond the marker means new content.
function CrashReport.should_report(prev_marker, current)
    current = current or {}
    if type(prev_marker) ~= "table" or prev_marker.size == nil then return true end
    return (tonumber(current.size) or 0) > (tonumber(prev_marker.size) or 0)
end

-- Defense in depth: redact credential-shaped fragments from free text before
-- it leaves the device (crash.log may contain URLs carrying cookies).
function CrashReport.redact_text(text, markers)
    local out = tostring(text or "")
    for _, marker in ipairs(markers or { "cookie=", "token=", "secret=", "password=", "passwd=", "api_key=", "vid=" }) do
        out = out:gsub("(" .. CrashReport.escape_pattern(marker) .. ")[^%s&\"']+", "%1[redacted]")
    end
    return out
end

-- Assemble a markdown report. env fields:
--   version, schema, channel, device_label, logged_in, time, crash_log_path,
--   crash_log_size, crash_tail, oplog_entries (list of rendered strings)
local FENCE = string.char(96, 96, 96) -- three backticks, kept out of source

function CrashReport.build_report(env)
    env = env or {}
    local out = {}
    out[#out + 1] = "## MiuRead 崩溃报告（自动生成）"
    out[#out + 1] = ""
    out[#out + 1] = "- 版本：" .. tostring(env.version or "unknown") .. " (schema " .. tostring(env.schema or "?") .. ")"
    out[#out + 1] = "- 通道：" .. tostring(env.channel or "?")
    out[#out + 1] = "- 设备：" .. tostring(env.device_label or "unknown")
    out[#out + 1] = "- 登录：" .. tostring(env.logged_in or "unknown")
    out[#out + 1] = "- 时间：" .. tostring(env.time or "-")
    if env.crash_log_path and env.crash_log_path ~= "" then
        out[#out + 1] = "- 日志：" .. tostring(env.crash_log_path) .. " (" .. tostring(env.crash_log_size or "?") .. " bytes)"
    end
    out[#out + 1] = ""
    out[#out + 1] = "### crash.log 尾部"
    out[#out + 1] = ""
    local tail = tostring(env.crash_tail or "")
    if tail == "" then tail = "（无内容）" end
    out[#out + 1] = FENCE
    out[#out + 1] = tail
    out[#out + 1] = FENCE
    out[#out + 1] = ""
    out[#out + 1] = "### 最近操作"
    out[#out + 1] = ""
    local ops = env.oplog_entries
    if type(ops) == "table" and #ops > 0 then
        for _, line in ipairs(ops) do out[#out + 1] = "- " .. tostring(line) end
    else
        out[#out + 1] = "（无）"
    end
    return table.concat(out, "\n")
end

return CrashReport
