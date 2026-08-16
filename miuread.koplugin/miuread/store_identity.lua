-- EPUB identity / file recognition reader for the Store facade.
local Json = require("miuread.json")
local U = require("miuread.util")
local logger = require("logger")
local StoreLibrary = require("miuread.store_library")

local StoreIdentity = {}

local function normalize_path(path)
    local value=tostring(path or ""):gsub("\\","/"):gsub("/+","/")
    value=value:gsub("/%./","/")
    while value:find("/[^/]+/%.%./") do value=value:gsub("/[^/]+/%.%./","/") end
    if #value>1 then value=value:gsub("/$","") end
    return value
end

local function read_pipe(command)
    local pipe=io.popen(command,"r")
    if not pipe then return nil end
    local data=pipe:read("*a")
    pipe:close()
    if data=="" then return nil end
    return data
end

local function xml_unescape(value)
    return tostring(value or "")
        :gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&apos;", "'")
        :gsub("&amp;", "&")
end

local function filename_key(path)
    local name=tostring(StoreLibrary.basename(path) or ""):lower()
    -- Treat harmless spacing differences around the variant suffix as the same
    -- filename, but only relink when the match is unique.
    name=name:gsub("%s+", "")
    return name:gsub("　", "")
end

local function identity_from_blob(blob,identity)
    blob=tostring(blob or "")
    identity=type(identity)=="table" and identity or {}
    identity.book_id=identity.book_id
        or blob:match('"book_id"%s*:%s*"([^"]+)"')
        or blob:match("miuread://book/([^<%s\"]+)")
    identity.variant=identity.variant or blob:match('"variant"%s*:%s*"([^"]+)"')
    identity.content_type=identity.content_type or blob:match('"content_type"%s*:%s*"([^"]+)"')
    if identity.standalone==nil and blob:match('"standalone"%s*:%s*true') then identity.standalone=true end
    identity.chapter_uid=identity.chapter_uid or blob:match('"chapter_uid"%s*:%s*"?([^",}%s]+)')
    identity.title=identity.title or xml_unescape(blob:match("<dc:title[^>]*>(.-)</dc:title>"))
    identity.author=identity.author or xml_unescape(blob:match("<dc:creator[^>]*>(.-)</dc:creator>"))
    return identity
end

function StoreIdentity:epub_identity_light(path)
    if not path or not U.file_exists(path) or not tostring(path):lower():match("%.epub$") then return nil end
    local file=io.open(path,"rb")
    if not file then return nil end
    local size=file:seek("end") or 0
    file:seek("set",0)
    local head=file:read(math.min(size,768*1024)) or ""
    local tail=""
    if size>#head then
        file:seek("set",math.max(0,size-1024*1024))
        tail=file:read("*a") or ""
    end
    file:close()
    local identity=identity_from_blob(head.."\n"..tail,{})
    if tostring(identity.book_id or "")~="" or tostring(identity.title or "")~="" then return identity end
    return nil
end

function StoreIdentity:epub_identity(path)
    local identity=self:epub_identity_light(path) or {}
    if tostring(identity.book_id or "")~="" then return identity end
    if not path or not U.file_exists(path) or not tostring(path):lower():match("%.epub$") then return nil end
    local quoted=U.shell_quote(path)
    local raw=read_pipe("unzip -p "..quoted.." OEBPS/miuread.json 2>/dev/null")
    if raw then
        local ok,value=pcall(Json.decode,raw)
        if ok and type(value)=="table" then identity=U.merge(identity,value) end
    end
    local opf=read_pipe("unzip -p "..quoted.." OEBPS/package.opf 2>/dev/null")
    if opf then identity=identity_from_blob(opf,identity) end
    if tostring(identity.book_id or "")~="" or tostring(identity.title or "")~="" then return identity end
    return nil
end

local function access_from_epub_meta(_meta)
    return nil
end

local function metadata_key(value)
    local text=tostring(value or ""):lower()
    text=text:gsub("%.epub$","")
    text=text:gsub("%s*%[[^%]]-%]%s*$","")
    text=text:gsub("%s*【.-】%s*$","")
    text=text:gsub("[%s%c%p]+","")
    text=text:gsub("　","")
    for _,mark in ipairs({"，","。","！","？","：","；","“","”","‘","’","《","》","〈","〉","（","）","【","】","·","—","…"}) do
        text=text:gsub(mark,"",1e6)
    end
    return text
end

local function relink_saved_record(store,all,book,record,path,current_size,relink)
    if not relink or type(record)~="table" then return end
    local changed=false
    if record.file~=path then
        record.file=path
        record.directory=path:match("^(.*)/[^/]+$")
        changed=true
    end
    if current_size and tonumber(record.file_size)~=tonumber(current_size) then
        record.file_size=current_size
        changed=true
    end
    if record.directory and book.directory~=record.directory then
        book.directory=record.directory
        changed=true
    end
    if changed then store:set("library",all) end
end

-- Older MiuRead library records may still point to a valid generated EPUB but
-- lack chapter_map. The EPUB itself embeds the authoritative local chapter list
-- in OEBPS/miuread.json. Restore that list once on discovery instead of forcing
-- progress sync to guess from an empty local map. This reads only ZIP metadata
-- and the small embedded MiuRead JSON; it never scans chapter bodies or uses the
-- network.
local function restore_embedded_chapter_map(store,all,book,record,path,kind,forced_uid)
    if type(record)~="table" or type(book)~="table" then return false end
    if type(record.chapter_map)=="table" and #record.chapter_map>0 then return false end
    if not path or not U.file_exists(path) or not tostring(path):lower():match("%.epub$") then return false end

    local ok_installer,Installer=pcall(require,"miuread.epub_installer")
    if not ok_installer or type(Installer)~="table" or type(Installer.inspect)~="function" then return false end
    local ok_meta,meta=pcall(Installer.inspect,path)
    if not ok_meta or type(meta)~="table" then return false end

    local book_id=tostring(book.book_id or record.book_id or "")
    local meta_id=tostring(meta.book_id or meta.bookId or "")
    if book_id~="" and meta_id~="" and book_id~=meta_id then
        logger.warn("[MiuRead][Store] embedded chapter map ignored book mismatch",
            "record=",book_id,"embedded=",meta_id)
        return false
    end
    local chapters=type(meta.chapters)=="table" and meta.chapters or {}
    if #chapters==0 then return false end

    record.chapter_map=U.copy(chapters)
    record.chapter_count=#chapters
    if tostring(record.core_map_hash or "")=="" and tostring(meta.core_map_hash or "")~="" then
        record.core_map_hash=tostring(meta.core_map_hash)
    end
    if record.partial_range==nil and meta.partial_range~=nil then record.partial_range=meta.partial_range==true end
    if record.range_start_index==nil then record.range_start_index=tonumber(meta.range_start_index) end
    if record.range_end_index==nil then record.range_end_index=tonumber(meta.range_end_index) end
    if record.range_start_title==nil then record.range_start_title=meta.range_start_title end
    if record.range_end_title==nil then record.range_end_title=meta.range_end_title end

    local uid=tostring(forced_uid or record.chapter_uid or meta.chapter_uid or "")
    if uid~="" then record.chapter_uid=uid end

    -- Only a complete multi-chapter EPUB may also repair an empty book catalog.
    -- A standalone/range EPUB carries only a subset and must still obtain the
    -- full WeRead catalog through the normal context-only path.
    local local_is_subset=meta.standalone==true or meta.partial_range==true
    if not local_is_subset and (type(book.catalog)~="table" or #book.catalog==0) then
        book.catalog=U.copy(chapters)
    end

    store:set("library",all)
    logger.info("[MiuRead][Store] embedded chapter map restored",
        "book=",book_id~="" and book_id or meta_id,
        "variant=",tostring(kind or record.variant or ""),
        "chapters=",tostring(#chapters),
        "standalone=",tostring(meta.standalone==true),
        "partial=",tostring(meta.partial_range==true))
    return true
end

function StoreIdentity:file_record_fast(path,relink)
    if not path then return nil end
    local normalized=normalize_path(path)
    local current_size
    local function file_size()
        if current_size==nil then current_size=U.file_size(path) or false end
        return current_size~=false and current_size or nil
    end
    local all=self:library()
    local function match_record(record)
        return type(record)=="table" and record.file and normalize_path(record.file)==normalized
    end
    for _,book in pairs(all) do
        for kind,record in pairs(book.variants or {}) do
            if match_record(record) then
                relink_saved_record(self,all,book,record,path,file_size(),relink)
                restore_embedded_chapter_map(self,all,book,record,path,kind,nil)
                return book,record,kind
            end
        end
        for uid,row in pairs(book.chapters or {}) do
            for kind,record in pairs(row or {}) do
                if match_record(record) then
                    record.chapter_uid=uid
                    relink_saved_record(self,all,book,record,path,file_size(),relink)
                    restore_embedded_chapter_map(self,all,book,record,path,kind,uid)
                    return book,record,kind
                end
            end
        end
    end
    local wanted_name=filename_key(path)
    if wanted_name=="" then return nil end
    local matches={}
    for _,book in pairs(all) do
        for kind,record in pairs(book.variants or {}) do
            if type(record)=="table" and filename_key(record.file)==wanted_name then
                matches[#matches+1]={book=book,record=record,kind=kind}
            end
        end
        for uid,row in pairs(book.chapters or {}) do
            for kind,record in pairs(row or {}) do
                if type(record)=="table" and filename_key(record.file)==wanted_name then
                    matches[#matches+1]={book=book,record=record,kind=kind,uid=uid}
                end
            end
        end
    end
    if #matches==1 then
        local found=matches[1]
        if found.uid then found.record.chapter_uid=found.uid end
        relink_saved_record(self,all,found.book,found.record,path,file_size(),relink)
        restore_embedded_chapter_map(self,all,found.book,found.record,path,found.kind,found.uid)
        return found.book,found.record,found.kind
    end
    return nil
end

function StoreIdentity:file_record_from_identity(path,meta,relink)
    if not path or type(meta)~="table" then return nil end
    local current_size=U.file_size(path)
    local all=self:library()
    local id=tostring(meta.book_id or "")
    if id=="" then
        local wanted_title=metadata_key(meta.title)
        local wanted_author=metadata_key(meta.author)
        local matches={}
        if wanted_title~="" then
            for key,book in pairs(all) do
                if metadata_key(book.title)==wanted_title then
                    local author=metadata_key(book.author)
                    if wanted_author=="" or author=="" or author==wanted_author then
                        matches[#matches+1]={id=tostring(book.book_id or key),book=book}
                    end
                end
            end
        end
        if #matches==1 then
            id=matches[1].id
            meta.book_id=id
            meta.recovered_by="embedded_title"
            logger.info("[MiuRead][Store] legacy EPUB identity recovered by title","book=",id)
        else return nil end
    end
    local kind=tostring(meta.variant or "")
    if kind=="" then
        local name=tostring(StoreLibrary.basename(path) or "")
        if name:find("纯净版",1,true) then kind="clean"
        elseif name:find("划线与想法版",1,true) or name:find("想法版",1,true) then kind="notes" end
    end
    local chapters=type(meta.chapters)=="table" and meta.chapters or {}
    local standalone=meta.standalone==true
    local uid=tostring(meta.chapter_uid or ((chapters[1] and (chapters[1].uid or chapters[1].chapter_uid)) or ""))
    local book=all[id]
    if kind=="" and book then
        local available={}
        for existing_kind,existing_record in pairs(book.variants or {}) do
            if type(existing_record)=="table" then available[#available+1]=existing_kind end
        end
        kind=#available==1 and tostring(available[1]) or "recovered"
    elseif kind=="" then kind="recovered" end
    local record
    if book then
        if standalone then
            local row=uid~="" and book.chapters and book.chapters[uid] or nil
            record=row and row[kind]
            if record then record.chapter_uid=uid end
        else
            record=book.variants and book.variants[kind]
        end
        if record and (type(record.chapter_map)~="table" or #record.chapter_map==0) and #chapters>0 then
            record.chapter_map=U.copy(chapters)
            record.chapter_count=#chapters
            if tostring(record.core_map_hash or "")=="" and tostring(meta.core_map_hash or "")~="" then
                record.core_map_hash=tostring(meta.core_map_hash)
            end
        end
        if not record then
            record={
                book_id=id,title=meta.title or book.title or StoreLibrary.basename(path),author=meta.author or book.author or "",
                file=path,directory=path:match("^(.*)/[^/]+$"),variant=kind,
                content_type=meta.content_type,sync_enabled=meta.sync_enabled,read_report_enabled=meta.read_report_enabled,
                downloaded_at=tonumber(meta.generated_at) or os.time(),chapter_map=chapters,
                chapter_count=#chapters,complete=meta.complete~=false,file_size=current_size,
                partial_range=meta.partial_range==true,range_start_index=tonumber(meta.range_start_index),
                range_end_index=tonumber(meta.range_end_index),range_start_title=meta.range_start_title,
                range_end_title=meta.range_end_title,annotation_pending=meta.annotation_pending==true or nil,
                annotation_error_kind=meta.annotation_error_kind,core_map_hash=meta.core_map_hash,recovered=true,
            }
            if standalone and uid~="" then
                record.chapter_uid=uid
                book.chapters=book.chapters or {}; book.chapters[uid]=book.chapters[uid] or {}; book.chapters[uid][kind]=record
            else
                book.variants=book.variants or {}; book.variants[kind]=record
            end
        end
        if (#(book.catalog or {})==0) and #chapters>0 then book.catalog=U.copy(chapters) end
    else
        book={
            book_id=id,title=meta.title or tostring(StoreLibrary.basename(path) or id):gsub("%.epub$",""),
            author=meta.author or "",variants={},chapters={},catalog=chapters,
            content_type=meta.content_type,directory=path:match("^(.*)/[^/]+$"),updated_at=os.time(),recovered=true,
        }
        record={
            book_id=id,title=book.title,author=book.author,file=path,directory=book.directory,
            variant=kind,content_type=meta.content_type,sync_enabled=meta.sync_enabled,
            read_report_enabled=meta.read_report_enabled,downloaded_at=tonumber(meta.generated_at) or os.time(),
            chapter_map=chapters,chapter_count=#chapters,complete=meta.complete~=false,file_size=current_size,recovered=true,
            partial_range=meta.partial_range==true,range_start_index=tonumber(meta.range_start_index),
            range_end_index=tonumber(meta.range_end_index),range_start_title=meta.range_start_title,
            range_end_title=meta.range_end_title,annotation_pending=meta.annotation_pending==true or nil,
            annotation_error_kind=meta.annotation_error_kind,core_map_hash=meta.core_map_hash,
        }
        if standalone and uid~="" then record.chapter_uid=uid; book.chapters[uid]={[kind]=record}
        else book.variants[kind]=record end
        all[id]=book
    end
    if record and relink then relink_saved_record(self,all,book,record,path,current_size,true) end
    return book,record,kind
end

function StoreIdentity:identify_file(path,relink)
    local book,record,kind=self:file_record_fast(path,relink)
    if book then return book,record,kind end
    local meta=self:epub_identity(path)
    return self:file_record_from_identity(path,meta,relink)
end

function StoreIdentity:file_record(path)
    return self:identify_file(path,true)
end


return StoreIdentity
