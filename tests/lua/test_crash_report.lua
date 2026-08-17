local B = require("tests.lua.bootstrap")
local CrashReport = require("miuread.crash_report")

local T = {}

function T.test_extract_tail_short_text_unchanged()
    local tail, truncated = CrashReport.extract_tail("hello", 100)
    B.eq(tail, "hello")
    B.eq(truncated, false)
end

function T.test_extract_tail_truncates_to_line_boundary()
    local text = "line1\nline2\nline3\nline4\nline5"
    local tail, truncated = CrashReport.extract_tail(text, 12)
    B.eq(truncated, true)
    B.eq(tail, "line4\nline5")
end

function T.test_is_crash_content()
    B.ok(CrashReport.is_crash_content("PANIC: unprotected error in call to Lua API"))
    B.ok(CrashReport.is_crash_content("stack traceback:"))
    B.ok(CrashReport.is_crash_content("Fatal signal 11"))
    B.ok(not CrashReport.is_crash_content("logged in ok"))
    B.ok(not CrashReport.is_crash_content(""))
end

function T.test_should_report_growth()
    B.ok(CrashReport.should_report(nil, { size = 100 }))
    B.ok(CrashReport.should_report({ size = 50 }, { size = 100 }))
    B.ok(not CrashReport.should_report({ size = 100 }, { size = 100 }))
    B.ok(not CrashReport.should_report({ size = 200 }, { size = 100 }))
end

function T.test_redact_text_credential_shapes()
    local out = CrashReport.redact_text("url?token=abc123&x=1 cookie=SECRET")
    B.contains(out, "token=[redacted]")
    B.contains(out, "cookie=[redacted]")
    B.ok(not out:find("abc123", 1, true))
    B.ok(not out:find("SECRET", 1, true))
end

function T.test_build_report_contains_sections()
    local report = CrashReport.build_report({
        version = "4.5.50",
        schema = "112",
        channel = "stable",
        device_label = "Kindle Paperwhite 3",
        logged_in = "true",
        time = "2026-08-17 10:00:00",
        crash_log_path = "/tmp/crash.log",
        crash_log_size = "1234",
        crash_tail = "PANIC: boom",
        oplog_entries = { "T [sync] pull fail code=x" },
    })
    B.contains(report, "## MiuRead 崩溃报告")
    B.contains(report, "版本：4.5.50")
    B.contains(report, "Kindle Paperwhite 3")
    B.contains(report, "### crash.log 尾部")
    B.contains(report, "PANIC: boom")
    B.contains(report, "### 最近操作")
    B.contains(report, "code=x")
end

function T.test_build_report_empty_ops_and_tail()
    local report = CrashReport.build_report({ version = "x" })
    B.contains(report, "（无内容）")
    B.contains(report, "（无）")
end

function T.test_escape_pattern_handles_magic_chars()
    B.eq(CrashReport.escape_pattern("a.b"), "a%.b")
    B.eq(CrashReport.escape_pattern("token="), "token=")
end

return T
