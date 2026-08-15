-- Session reader for the Store facade.
local U = require("miuread.util")
local defaults = require("miuread.store_defaults")
local logger = require("logger")

local StoreSessions = {}

function StoreSessions.invalidate_report_contexts_table(sessions)
    sessions=type(sessions)=="table" and sessions or {}
    local changed=0
    local clear_keys={
        "legacy_report_context","report_context","psvts","pclts","token","reader_url",
        "context_updated_at","report_login_session_id","verification_login_session_id",
        "remote","remote_sources","remote_checked_at","remote_web_error","remote_agent_error",
        "remote_verified","verified_at","verified_reason","verified_local_percent","verified_remote_percent",
        "progress_sync_state","progress_sync_message","progress_upload_state","progress_upload_error",
        "progress_upload_verified_at","progress_upload_source","progress_upload_at","progress_upload_percent",
        "last_response_summary","last_http_code","last_http_length","last_payload_public","last_path",
        "last_stage","last_error","last_attempts",
    }
    for _,session in pairs(sessions) do
        if type(session)=="table" then
            for _,key in ipairs(clear_keys) do
                if session[key]~=nil then session[key]=nil; changed=changed+1 end
            end
            if tonumber(session.consecutive_failures or 0)~=0 then session.consecutive_failures=0; changed=changed+1 end
            if tonumber(session.pending_report_seconds or 0)~=0 then session.pending_report_seconds=0; changed=changed+1 end
        end
    end
    return sessions,changed
end
function StoreSessions.invalidate_upload_health_table(auth)
    auth=U.merge(defaults.auth,auth or {})
    auth.health.notice_pending=false
    auth.health.last_error_channel=""
    if tostring(auth.api_key or "")~="" and next(auth.cookies or {})~=nil then
        auth.health.state="unknown"
        for _,channel in ipairs({"progress","read_report"}) do
            local row=auth.health.channels[channel] or {}
            auth.health.channels[channel]={
                state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0,
                last_ok_at=tonumber(row.last_ok_at or 0) or 0,
            }
        end
    end
    return auth
end

function StoreSessions:clear_login_bound_sessions(reason)
    local sessions=self:get("sessions",{})
    local cleaned,changed=StoreSessions.invalidate_report_contexts_table(sessions)
    if changed>0 then self:set("sessions",cleaned) end
    self:save_auth(StoreSessions.invalidate_upload_health_table(self:get("auth",{})))
    logger.info("[MiuRead][Store] login-bound sessions cleared",
        "reason=",tostring(reason or "unknown"),"fields=",tostring(changed))
    return changed,reason
end
function StoreSessions:invalidate_report_contexts(reason)
    return self:clear_login_bound_sessions(reason)
end
function StoreSessions:session(id) return self:get("sessions",{})[tostring(id)] end
function StoreSessions:save_session(id,patch,flush_now) local a=self:get("sessions",{}); local k=tostring(id); a[k]=U.merge(a[k] or {},patch or {}); self.db:saveSetting("sessions",a); if flush_now~=false then self:flush() end; return a[k] end
function StoreSessions:invalidate_book_sync_context(id,reason,core_map_hash)
    local sessions=self:get("sessions",{})
    local key=tostring(id or "")
    if key=="" then return false end
    local row=type(sessions[key])=="table" and sessions[key] or {}
    for _,field in ipairs({
        "legacy_report_context","report_context","report_login_session_id","report_core_map_hash",
        "remote_verified","verified_at","verified_reason","verified_local_percent","verified_remote_percent",
        "verification_login_session_id","progress_upload_state","progress_upload_verified_at","progress_upload_source",
        "pending_report_seconds"
    }) do row[field]=nil end
    row.sync_context_invalidated_at=os.time()
    row.sync_context_invalidated_reason=tostring(reason or "book_context_changed")
    row.book_core_map_hash=tostring(core_map_hash or row.book_core_map_hash or "")
    row.pending_report_seconds=0
    sessions[key]=row
    self.db:saveSetting("sessions",sessions)
    self:flush()
    return true,row
end
function StoreSessions:clear_session(id) local a=self:get("sessions",{}); a[tostring(id)]=nil; self:set("sessions",a) end

return StoreSessions
