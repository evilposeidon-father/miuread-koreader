-- Auth reader for the Store facade.
local U = require("miuread.util")
local defaults = require("miuread.store_defaults")

local StoreAuth = {}

local function generate_login_session_id()
    return tostring(os.time()).."-"..tostring(math.random(100000,999999))
end
local function sanitized_auth(value)
    local auth=U.merge(defaults.auth,value or {})
    auth.mp_cookie_header=nil
    auth.mp_extra_headers=nil
    auth.mp_referer=nil
    auth.mp_auth_source=nil
    auth.mp_authorized_at=nil
    return auth
end

function StoreAuth:auth() return sanitized_auth(self:get("auth",{})) end
function StoreAuth:save_auth(v) self:set("auth",sanitized_auth(v)) end
function StoreAuth:generate_login_session_id() return generate_login_session_id() end
function StoreAuth:ensure_login_session_id()
    local auth=self:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    if tostring(auth.login_session_id or "")=="" and tostring(account.vid or "")~=""
        and tostring(auth.api_key or "")~="" and next(auth.cookies or {})~=nil then
        auth.login_session_id=generate_login_session_id()
        self:save_auth(auth)
    end
    return tostring(auth.login_session_id or "")
end
function StoreAuth:auth_health()
    local auth=self:auth()
    return U.merge(defaults.auth.health,auth.health or {})
end
function StoreAuth:update_auth_health(patch)
    local auth=self:auth()
    auth.health=U.merge(defaults.auth.health,auth.health or {})
    auth.health=U.merge(auth.health,patch or {})
    self:save_auth(auth)
    return auth.health
end
function StoreAuth:clear_auth() self:set("auth",U.copy(defaults.auth)) end
function StoreAuth:clear_account_shelf_cache()
    local cache=self:shelf_cache()
    cache.books={}; cache.mp={}; cache.updated_at=0
    self:save_shelf_cache(cache)
end

return StoreAuth
