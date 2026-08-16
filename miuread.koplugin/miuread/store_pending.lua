-- Pending installs / cleanup / read-report bookkeeping reader.
local U = require("miuread.util")

local StorePending = {}

function StorePending:pending_installs() return self:get("pending_installs",{}) end
function StorePending:save_pending_installs(rows) self:set("pending_installs",type(rows)=="table" and rows or {}) end
function StorePending:add_pending_install(book_id,kind,chapter_uid,record)
    local rows=self:pending_installs()
    local key=table.concat({tostring(book_id or ""),tostring(chapter_uid or "full"),tostring(kind or "")},":")
    local item={key=key,book_id=tostring(book_id or ""),kind=tostring(kind or ""),
        chapter_uid=chapter_uid and tostring(chapter_uid) or nil,file=record and record.file,
        pending_file=record and record.pending_file,created_at=os.time()}
    local replaced=false
    for index,row in ipairs(rows) do
        if tostring(row.key or "")==key then rows[index]=item; replaced=true; break end
    end
    if not replaced then rows[#rows+1]=item end
    self:save_pending_installs(rows)
    return item
end
function StorePending:remove_pending_install(book_id,kind,chapter_uid)
    local rows,out=self:pending_installs(),{}
    local key=table.concat({tostring(book_id or ""),tostring(chapter_uid or "full"),tostring(kind or "")},":")
    local changed=false
    for _,row in ipairs(rows) do
        if tostring(row.key or "")==key then changed=true else out[#out+1]=row end
    end
    if changed then self:save_pending_installs(out) end
    return changed
end
function StorePending:prune_pending_installs()
    local rows,out=self:pending_installs(),{}
    local changed=false
    for _,row in ipairs(rows) do
        if row.pending_file and U.file_exists(row.pending_file) then out[#out+1]=row else changed=true end
    end
    if changed then self:save_pending_installs(out) end
    return out
end
function StorePending:last_cleanup_result() return self:get("last_cleanup_result",{}) end
function StorePending:save_cleanup_result(result) self:set("last_cleanup_result",type(result)=="table" and result or {}) end
function StorePending:is_read_report_consumed(stamp)
    stamp=tostring(stamp or "")
    if stamp=="" then return false end
    local rows=self:get("read_report_consumed",{})
    return rows[stamp]~=nil
end
function StorePending:mark_read_report_consumed(stamp)
    stamp=tostring(stamp or "")
    if stamp=="" then return end
    local rows=self:get("read_report_consumed",{})
    rows[stamp]=os.time()
    local ordered={}
    for key,at in pairs(rows) do ordered[#ordered+1]={key=key,at=tonumber(at) or 0} end
    table.sort(ordered,function(a,b) return a.at>b.at end)
    for index=#ordered,21,-1 do rows[ordered[index].key]=nil end
    self:set("read_report_consumed",rows)
end

return StorePending
