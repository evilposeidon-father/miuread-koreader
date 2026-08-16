-- Recent reads / shelf cache / covers / update reader for the Store facade.
local U = require("miuread.util")
local defaults = require("miuread.store_defaults")

local StoreMeta = {}

function StoreMeta:mark_last_read(id,path,progress,flush_now,at)
    id=tostring(id or "")
    if id=="" then return end
    local patch={last_read_at=tonumber(at) or os.time()}
    if path then patch.last_read_path=path end
    if progress~=nil then patch.progress_local_percent=tonumber(progress) end
    self:save_session(id,patch,flush_now)
end
function StoreMeta:recent_reads()
    local state=self:get("recent_reads",{version=1,items={}})
    if type(state)~="table" then state={version=1,items={}} end
    state.version=1
    if type(state.items)~="table" then state.items={} end
    return state
end
function StoreMeta:record_recent_read(book_id,path,at)
    book_id=tostring(book_id or "")
    path=tostring(path or "")
    if book_id=="" and path=="" then return nil end
    local stamp=tonumber(at) or os.time()
    local key=book_id~="" and ("book:"..book_id) or ("file:"..path)
    local state=self:recent_reads()
    local items={{key=key,book_id=book_id,file=path,read_at=stamp}}
    for _,row in ipairs(state.items) do
        if type(row)=="table" and tostring(row.key or "")~=key then
            local same_book=book_id~="" and tostring(row.book_id or "")==book_id
            local same_file=path~="" and tostring(row.file or "")==path
            if not same_book and not same_file then items[#items+1]=row end
        end
        if #items>=10 then break end
    end
    state.items=items
    self:set_deferred("recent_reads",state)
    if book_id~="" then self:mark_last_read(book_id,path,nil,false,stamp) end
    return items[1]
end
function StoreMeta:shelf_cache() return U.merge(defaults.shelf_cache,self:get("shelf_cache",{})) end
function StoreMeta:save_shelf_cache(v) self:set("shelf_cache",U.merge(defaults.shelf_cache,v or {})) end
function StoreMeta:update_cached_progress(id,percent)
    id=tostring(id or "")
    percent=tonumber(percent)
    if id=="" or percent==nil then return false end
    local cache=self:shelf_cache()
    local changed=false
    for _,group in ipairs({cache.books or {},cache.mp or {}}) do
        for _,row in ipairs(group) do
            if tostring(row.bookId or row.book_id or "")==id then
                row.progress=U.clamp(percent,0,100)
                row.finished=row.progress>=100
                changed=true
            end
        end
    end
    if changed then self:save_shelf_cache(cache) end
    return changed
end
function StoreMeta:cover_guard() return U.merge(defaults.cover_guard,self:get("cover_guard",{})) end
function StoreMeta:save_cover_guard(v) self:set("cover_guard",U.merge(defaults.cover_guard,v or {})) end
function StoreMeta:cover_path(id) return self.covers_dir.."/"..U.id_name(id)..".img" end
function StoreMeta:update_state() return self:get("update_state",{}) end
function StoreMeta:save_update_state(v) self:set("update_state",v or {}) end

return StoreMeta
