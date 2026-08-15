-- Books/variants/paths reader for the Store facade.
local lfs = require("libs/libkoreader-lfs")
local U = require("miuread.util")

local StoreLibrary = {}

local function basename(path) return tostring(path or ""):match("([^/]+)$") end
function StoreLibrary:library() return self:get("library",{}) end
function StoreLibrary:book(id) return self:library()[tostring(id)] end
function StoreLibrary:save_book(id,patch)
    local all=self:library(); local key=tostring(id); all[key]=U.merge(all[key] or {book_id=key,variants={},chapters={}},patch or {}); self:set("library",all); return all[key]
end
function StoreLibrary:clear_book_access(id)
    local all=self:library(); local key=tostring(id)
    if type(all[key])=="table" and all[key].access~=nil then
        all[key].access=nil
        self:set("library",all)
    end
    return all[key]
end
function StoreLibrary:save_variant(id,kind,record)
    local b=self:book(id) or {book_id=tostring(id),variants={},chapters={}}; b.variants=b.variants or {}; b.variants[kind]=U.copy(record); return self:save_book(id,b)
end
function StoreLibrary:save_chapter_variant(id,uid,kind,record)
    local b=self:book(id) or {book_id=tostring(id),variants={},chapters={}}; b.chapters=b.chapters or {}; local key=tostring(uid); b.chapters[key]=b.chapters[key] or {}; b.chapters[key][kind]=U.copy(record); return self:save_book(id,b)
end
function StoreLibrary:variant(id,kind) local b=self:book(id); return b and b.variants and b.variants[kind] end
function StoreLibrary:chapter_variant(id,uid,kind) local b=self:book(id); return b and b.chapters and b.chapters[tostring(uid)] and b.chapters[tostring(uid)][kind] end
local function add_unique_path(out,seen,path)
    path=tostring(path or "")
    if path~="" and not seen[path] then seen[path]=true; out[#out+1]=path end
end
function StoreLibrary:partial_cache_paths(id)
    local root=self:book_cache_path(id)
    local out={}
    if lfs.attributes(root,"mode")~="directory" then return out end
    local ok,iter,state=pcall(lfs.dir,root)
    if not ok or type(iter)~="function" then return out end
    for name in iter,state do
        if name~="." and name~=".." and tostring(name):match("^%.miuread%-partial%-") then out[#out+1]=root.."/"..name end
    end
    table.sort(out)
    return out
end
function StoreLibrary:book_has_partial_cache(id) return #self:partial_cache_paths(id)>0 end
function StoreLibrary:variant_paths(id,kind)
    local r=self:variant(id,kind)
    return r and r.file and {r.file} or {}
end
function StoreLibrary:chapter_paths(id,uid)
    local b=self:book(id); local row=b and b.chapters and b.chapters[tostring(uid)]
    local out,seen={},{}
    for _,r in pairs(row or {}) do add_unique_path(out,seen,r and r.file) end
    return out
end
function StoreLibrary:book_paths(id,include_cache)
    local b=self:book(id)
    local out,seen={},{}
    if b then
        for _,r in pairs(b.variants or {}) do add_unique_path(out,seen,r and r.file) end
        for _,row in pairs(b.chapters or {}) do for _,r in pairs(row or {}) do add_unique_path(out,seen,r and r.file) end end
    end
    if include_cache~=false then add_unique_path(out,seen,self:book_cache_path(id)) end
    return out
end
function StoreLibrary:all_download_paths(include_covers)
    local out,seen={},{}
    for id,_ in pairs(self:library()) do for _,path in ipairs(self:book_paths(id,true)) do add_unique_path(out,seen,path) end end
    add_unique_path(out,seen,self.cache_books_dir)
    if include_covers then add_unique_path(out,seen,self.covers_dir) end
    return out
end
local function book_has_records(book)
    if type(book)~="table" then return false end
    if next(book.variants or {}) then return true end
    for _,row in pairs(book.chapters or {}) do if next(row or {}) then return true end end
    return false
end
function StoreLibrary:forget_variant(id,kind)
    local all=self:library(); local key=tostring(id); local b=all[key]; if not b then return end
    if b.variants then b.variants[kind]=nil end
    if not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function StoreLibrary:forget_chapter(id,uid,kind)
    local all=self:library(); local key=tostring(id); local b=all[key]; local row=b and b.chapters and b.chapters[tostring(uid)]
    if row then row[kind]=nil; if next(row)==nil then b.chapters[tostring(uid)]=nil end end
    if b and not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function StoreLibrary:forget_chapter_all(id,uid)
    local all=self:library(); local key=tostring(id); local b=all[key]
    if b and b.chapters then b.chapters[tostring(uid)]=nil end
    if b and not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function StoreLibrary:forget_book(id) local all=self:library(); all[tostring(id)]=nil; self:set("library",all) end
function StoreLibrary:forget_book_local_state(id)
    local key=tostring(id or "")
    if key=="" then return false end
    local all=self:library(); all[key]=nil; self:set("library",all)
    local sessions=self:get("sessions",{}); sessions[key]=nil; self:set("sessions",sessions)
    local covers=self:get("cover_index",{}); covers[key]=nil; self:set("cover_index",covers)

    local queue_out={}
    for _,job in ipairs(self:download_queue()) do
        local job_id=tostring((job.book and (job.book.bookId or job.book.book_id)) or job.book_id or "")
        if job_id~=key then queue_out[#queue_out+1]=job end
    end
    self:save_download_queue(queue_out)

    local pending_out={}
    for _,row in ipairs(self:pending_installs()) do
        if tostring(row.book_id or "")~=key then pending_out[#pending_out+1]=row end
    end
    self:save_pending_installs(pending_out)

    local repair=self:get("book_repair_state",{}); repair[key]=nil; self:set("book_repair_state",repair)
    local history_out={}
    for _,row in ipairs(self:get("book_repair_history",{})) do
        if tostring(row.book_id or "")~=key then history_out[#history_out+1]=row end
    end
    self:set("book_repair_history",history_out)

    local shelf=self:shelf_cache()
    local shelf_changed=false
    for _,group in ipairs({shelf.books or {},shelf.mp or {}}) do
        for _,row in ipairs(group) do
            if tostring(row.bookId or row.book_id or "")==key and row.cover_path~=nil then
                row.cover_path=nil; shelf_changed=true
            end
        end
    end
    if shelf_changed then self:save_shelf_cache(shelf) end

    local state=self:download_state()
    if tostring(state.book_id or (state.book and (state.book.bookId or state.book.book_id)) or "")==key then
        self:clear_download_state()
    end
    return true
end
function StoreLibrary:forget_all_books() self:set("library",{}) end
function StoreLibrary:prune_missing_files()
    local all=self:library(); local changed=false
    for id,b in pairs(all) do
        for kind,r in pairs(b.variants or {}) do if not (r and r.file and U.file_exists(r.file)) then b.variants[kind]=nil; changed=true end end
        for uid,row in pairs(b.chapters or {}) do
            for kind,r in pairs(row or {}) do if not (r and r.file and U.file_exists(r.file)) then row[kind]=nil; changed=true end end
            if next(row or {})==nil then b.chapters[uid]=nil; changed=true end
        end
        if not book_has_records(b) and not self:book_has_partial_cache(id) then all[id]=nil; changed=true end
    end
    if changed then self:set("library",all) end
    return changed
end
function StoreLibrary:delete_variant(id,kind)
    for _,path in ipairs(self:variant_paths(id,kind)) do U.remove_tree(path) end
    self:forget_variant(id,kind)
end
function StoreLibrary:delete_chapter(id,uid,kind)
    local r=self:chapter_variant(id,uid,kind); if r and r.file then U.remove_tree(r.file) end
    self:forget_chapter(id,uid,kind)
end
function StoreLibrary:delete_book(id)
    for _,path in ipairs(self:book_paths(id,true)) do U.remove_tree(path) end
    self:forget_book(id)
end
function StoreLibrary:all_books()
    local o={}; for id,b in pairs(self:library()) do local x=U.copy(b); x.book_id=x.book_id or id; o[#o+1]=x end
    table.sort(o,function(a,b) return tonumber(a.updated_at or a.downloaded_at or 0)>tonumber(b.updated_at or b.downloaded_at or 0) end); return o
end

return StoreLibrary
