-- luacheck config for MiuRead (KOReader plugin).
-- KOReader injects a large widget/runtime surface; the linter should treat the
-- most common runtime globals as defined and stay quiet about widget method
-- self-arguments (idiomatic in KOReader).
std = "lua51"
globals = {
    "UIManager", "Device", "G_reader_settings", "Event", "logger",
    "WidgetContainer", "InputContainer", "Blitbuffer", "Screen", "Font",
    "unpack", "dbg",
}
ignore = {
    "212", -- unused argument
    "213", -- unused loop variable
    "431", -- shadowing an upvalue
}
max_line_length = false
