-- Home network-metadata patch helpers, extracted from plugin_home_content.
--
-- MiuRead 4.5.35 moved the pure key/patch helpers out of the home controller
-- so they are independently unit-testable.
local U = require("miuread.util")

local M = {}

local DETAIL_FIELDS = {"description","category","publisher","published_date","isbn"}
local PATCH_FIELDS = {"title","author","description","category","publisher","published_date","language","isbn","pages"}

function M.metadata_key(book)
    if type(book)~="table" then return "" end
    local id=tostring(book.bookId or book.book_id or "")
    if id~="" then return "book:"..id end
    local file=tostring(book.file or ""):gsub("\\","/"):gsub("/+","/")
    if file~="" then return "file:"..file end
    local title=U.trim(tostring(book.title or ""))
    local author=U.trim(tostring(book.author or ""))
    if title~="" then return "title:"..title.."|"..author end
    return ""
end

function M.patch_has_data(patch)
    if type(patch)~="table" then return false end
    for _,key in ipairs(PATCH_FIELDS) do
        if U.trim(tostring(patch[key] or ""))~="" then return true end
    end
    return false
end

function M.patch_field_count(patch)
    if type(patch)~="table" then return 0 end
    local count=0
    for _,key in ipairs(PATCH_FIELDS) do
        if U.trim(tostring(patch[key] or ""))~="" then count=count+1 end
    end
    return count
end

function M.missing_fields(book,patch)
    book=type(book)=="table" and book or {}
    patch=type(patch)=="table" and patch or {}
    local missing={}
    for _,key in ipairs(DETAIL_FIELDS) do
        local value=patch[key]
        if value==nil or value=="" then value=book[key] end
        if key=="description" and U.trim(tostring(value or ""))=="" then
            value=book.intro or book.summary
        end
        if U.trim(tostring(value or ""))=="" then missing[#missing+1]=key end
    end
    return missing
end

function M.merge_patch(book,patch)
    if type(book)~="table" or type(patch)~="table" then return false end
    local changed=false
    local function fill(key,value)
        if value==nil or value=="" then return end
        local current=book[key]
        if current==nil or current=="" then book[key]=value; changed=true end
    end
    for _,key in ipairs(PATCH_FIELDS) do
        fill(key,patch[key])
    end
    if patch.metadata_source and (book.network_metadata_source==nil or book.network_metadata_source=="") then
        book.network_metadata_source=patch.metadata_source
        changed=true
    end
    return changed
end

return M
