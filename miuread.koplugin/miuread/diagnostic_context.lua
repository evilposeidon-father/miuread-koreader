-- Shared diagnostic context collection (version / device / preferences),
-- used by the manual diagnostic bundle and by crash reports so both stay in
-- sync. Pure logic: callers build the provider table from live KOReader state
-- and this module redacts, normalizes and renders it.

local DC = {}

local DEFAULT_MARKERS = { "cookie", "token", "secret", "api_key", "credential", "passw" }

-- Recursively redact values whose keys contain any marker. Cycles are
-- replaced with "[cyclic]" instead of recursing forever.
function DC.redact(value, markers)
    local keys = markers or DEFAULT_MARKERS
    local function walk(v, seen)
        if type(v) ~= "table" then return v end
        if seen[v] then return "[cyclic]" end
        seen[v] = true
        local out = {}
        for key, item in pairs(v) do
            local lower = tostring(key):lower()
            local sensitive = false
            for _, marker in ipairs(keys) do
                if lower:find(tostring(marker), 1, true) then sensitive = true break end
            end
            if sensitive then
                out[key] = "[redacted]"
            else
                out[key] = walk(item, seen)
            end
        end
        return out
    end
    return walk(value, {})
end

-- provider: { version, schema, channel, runtime, logged_in, time,
--             device = { model, firmware, screen, ... },
--             preferences = { ... } }
function DC.collect(provider)
    provider = provider or {}
    local device = type(provider.device) == "table" and provider.device or {}
    return {
        version = tostring(provider.version or "unknown"),
        schema = tostring(provider.schema or "?"),
        channel = tostring(provider.channel or "?"),
        runtime = tostring(provider.runtime or "unknown"),
        logged_in = provider.logged_in == true and "true" or "false",
        time = tostring(provider.time or ""),
        device = device,
        preferences = DC.redact(provider.preferences or {}),
    }
end

-- Flat key=value lines (kept stable so reports stay diff-able across runs).
function DC.render_lines(ctx)
    ctx = ctx or {}
    local device = type(ctx.device) == "table" and ctx.device or {}
    local lines = {
        "version=" .. tostring(ctx.version or "unknown"),
        "schema=" .. tostring(ctx.schema or "?"),
        "channel=" .. tostring(ctx.channel or "?"),
        "runtime=" .. tostring(ctx.runtime or "unknown"),
        "logged_in=" .. tostring(ctx.logged_in or "false"),
        "time=" .. tostring(ctx.time or ""),
        "device.model=" .. tostring(device.model or "unknown"),
        "device.firmware=" .. tostring(device.firmware or "unknown"),
        "device.screen=" .. tostring(device.screen or "?"),
    }
    return lines
end

function DC.render_text(ctx)
    return table.concat(DC.render_lines(ctx), "\n")
end

return DC
