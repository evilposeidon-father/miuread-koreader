-- MiuRead lazy module loader (Lua 5.1 compatible).
-- Heavy UI modules are loaded on first use instead of at plugin startup.
local lazy = {}
local proxies = {}
local loaded_names = {}

local function make_proxy(name)
    local module
    local has_module = false

    local function ensure_loaded()
        if not has_module then
            module = require(name)
            has_module = true
            loaded_names[name] = true
        end
        return module
    end

    return setmetatable({}, {
        __index = function(_, key)
            -- Never force-load a dialog module just to run close() on exit.
            -- close() is only meaningful when the dialog has already been
            -- shown, and in that case ensure_loaded has already run.
            if key == "close" and not has_module then
                return function() end
            end
            return ensure_loaded()[key]
        end,
    })
end

function lazy.load(name)
    name = tostring(name or "")
    if name == "" then
        error("lazy module name is empty", 2)
    end
    local proxy = proxies[name]
    if proxy == nil then
        proxy = make_proxy(name)
        proxies[name] = proxy
    end
    return proxy
end

function lazy.is_loaded(name)
    return loaded_names[tostring(name or "")] == true
end

setmetatable(lazy, {
    __call = function(_, name)
        return lazy.load(name)
    end,
})

return lazy
