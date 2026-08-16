local B = require("tests.lua.bootstrap")
local lazy = require("miuread.lazy")

local T = {}

-- A real module registered under package.preload so lazy can force-load it.
package.preload["tests.lua.lazy_fixture"] = function()
    return { value = 42, close = function() error("close must not force-load") end }
end

function T.test_proxy_is_not_loaded_until_used()
    B.ok(not lazy.is_loaded("tests.lua.lazy_fixture"), "not loaded before use")
    local proxy = lazy.load("tests.lua.lazy_fixture")
    B.ok(not lazy.is_loaded("tests.lua.lazy_fixture"), "creating proxy does not load")
    B.eq(proxy.value, 42, "property access loads the module")
    B.ok(lazy.is_loaded("tests.lua.lazy_fixture"), "loaded after use")
end

function T.test_close_never_force_loads()
    package.preload["tests.lua.lazy_close_fixture"] = function()
        error("must not be loaded")
    end
    local proxy = lazy.load("tests.lua.lazy_close_fixture")
    proxy.close()
    B.ok(not lazy.is_loaded("tests.lua.lazy_close_fixture"), "close() is a safe no-op")
end

function T.test_empty_name_rejected()
    local ok = pcall(function() lazy.load("") end)
    B.ok(not ok, "empty module name errors")
end

return T
