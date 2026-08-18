-- MiuRead home local-inline browser controller, extracted from plugin_home_content.lua.
-- Owns the 13 _home_local_* pure-helper methods that produce local-shelf data
-- (cache snapshots, root enumeration, inline navigation, empty states).
-- The four orchestration helpers (_home_apply_local_inline_section,
-- _home_set_local_inline_location, _home_ensure_local_inline_loaded,
-- _home_handle_back) stay in plugin_home_content because they mix local and
-- home section state across controllers.
local lfs = require("libs/libkoreader-lfs")
local U = require("miuread.util")
local Lazy = require("miuread.lazy")
local LocalLibrary = Lazy("miuread.local_library")
local LocalMetadata = require("miuread.local_metadata")
local logger = require("logger")

local Plugin = {}

function Plugin:_home_local_cache()
    local value=self.store:get("home_local_index",{})
    if type(value)~="table" then value={} end
    value.books=type(value.books)=="table" and value.books or {}
    return value
end

function Plugin:_home_local_tree_cache()
    local cache=self.store:get("home_local_tree_index",{version=1,dirs={}})
    cache=type(cache)=="table" and cache or {version=1,dirs={}}
    cache.version=1
    cache.dirs=type(cache.dirs)=="table" and cache.dirs or {}
    return cache
end

function Plugin:_home_local_roots(enabled_only)
    local home=self:_home_preferences()
    local rows={}
    for _,root in ipairs(type(home.local_roots)=="table" and home.local_roots or {}) do
        local path=LocalLibrary.normalize(root.path or "")
        if path~="" and lfs.attributes(path,"mode")=="directory"
            and (not enabled_only or root.enabled~=false) then
            rows[#rows+1]={path=path,name=U.trim(tostring(root.name or ""))~="" and U.trim(tostring(root.name)) or LocalLibrary.basename(path),enabled=root.enabled~=false,readonly=root.readonly~=false}
        end
    end
    return rows
end

function Plugin:_home_local_root_for_path(path,roots)
    path=LocalLibrary.normalize(path)
    for _,root in ipairs(roots or self:_home_local_roots(true)) do
        local root_path=LocalLibrary.normalize(root.path)
        if path==root_path or path:sub(1,#root_path+1)==root_path.."/" then return root end
    end
    return nil
end

function Plugin:_home_local_inline_context()
    local home=self:_home_preferences()
    local roots=self:_home_local_roots(true)
    if #roots==0 then return {roots=roots,picker=true,path="",root=nil} end
    local path=LocalLibrary.normalize(home.local_inline_path or "")
    if #roots>1 and path=="" then return {roots=roots,picker=true,path="",root=nil} end
    local root=self:_home_local_root_for_path(path,roots)
    if not root then
        if #roots==1 then path=roots[1].path; root=roots[1]
        else return {roots=roots,picker=true,path="",root=nil} end
    end
    return {roots=roots,picker=false,path=path,root=root}
end

function Plugin:_home_local_inline_parent_entry(context)
    if not context or context.picker or not context.root then return nil end
    local path=LocalLibrary.normalize(context.path)
    local root_path=LocalLibrary.normalize(context.root.path)
    local target
    local detail
    if path~=root_path then
        target=path:match("^(.*)/[^/]+$") or root_path
        if target=="" or not (target==root_path or target:sub(1,#root_path+1)==root_path.."/") then target=root_path end
        detail=target==root_path and tostring(context.root.name or LocalLibrary.basename(root_path)) or LocalLibrary.basename(target)
    elseif #(context.roots or {})>1 then
        target=""
        detail="书库目录"
    else
        return nil
    end
    return {
        kind="folder",local_folder=true,local_parent=true,source="local",
        title="返回上一级",status_text=tostring(detail or "上一级"),
        folder_path=target,path=target,root_path=root_path,
    }
end

function Plugin:_home_local_inline_rows()
    local context=self:_home_local_inline_context()
    local rows={}
    if context.picker then
        for _,root in ipairs(context.roots or {}) do
            local entry=self:_home_local_folder_entry(root.path,root.name,root.path)
            entry.local_root_entry=true
            rows[#rows+1]=entry
        end
        return rows,context,nil
    end
    local parent=self:_home_local_inline_parent_entry(context)
    if parent then rows[#rows+1]=parent end
    local snapshot=self:_home_local_tree_cache().dirs[context.path]
    if type(snapshot)=="table" then
        local folders,books=self:_local_browser_decorate(snapshot,context.root.path)
        for _,folder in ipairs(folders) do rows[#rows+1]=folder end
        for _,book in ipairs(books) do rows[#rows+1]=book end
    end
    return rows,context,snapshot
end

function Plugin:_home_local_inline_title()
    local home=self:_home_preferences()
    if tostring(home.local_library_mode or "direct")~="direct" then return "" end
    local context=self:_home_local_inline_context()
    if context.picker then return "选择本地书库目录" end
    local root_name=tostring(context.root and context.root.name or "本地书籍")
    if context.path==LocalLibrary.normalize(context.root and context.root.path or "") then
        return U.utf8_truncate(root_name,26,"…")
    end
    return U.utf8_truncate(root_name.." / "..LocalLibrary.basename(context.path),26,"…")
end

function Plugin:_home_local_empty_text()
    local home=self:_home_preferences()
    local mode=tostring(home.local_library_mode or "direct")
    if mode=="manual" then return "本地书库尚未扫描\n请在设置中点击扫描本地书库" end
    if mode~="direct" then return "这里还没有本地书籍\n请先设置本地书库目录" end
    local context=self:_home_local_inline_context()
    if #(context.roots or {})==0 then return "这里还没有本地书籍\n请先设置本地书库目录" end
    if context.picker then return "请选择一个本地书库目录" end
    local snapshot=self:_home_local_tree_cache().dirs[context.path]
    if type(snapshot)~="table" then return "正在读取这个文件夹…" end
    if snapshot.error then return "无法读取文件夹\n"..tostring(snapshot.error) end
    return "这个文件夹里没有可显示的书籍"
end

function Plugin:_home_local_folder_entry(path,title,root_path)
    path=LocalLibrary.normalize(path)
    local snapshot=self:_home_local_tree_cache().dirs[path]
    local count=type(snapshot)=="table" and (#(snapshot.folders or {})+#(snapshot.books or {})) or nil
    return {
        kind="folder",local_folder=true,source="local",title=tostring(title or LocalLibrary.basename(path)),
        folder_path=path,path=path,root_path=LocalLibrary.normalize(root_path or path),
        status_text=count and (tostring(count).." 项") or "文件夹",
    }
end

function Plugin:_home_local_known_paths()
    local known={}
    local function remember(path)
        path=LocalLibrary.normalize(path)
        if path~="" then known[path]=true end
    end
    for _,book in pairs(self.store:library() or {}) do
        for _,record in pairs(book.variants or {}) do
            if type(record)=="table" then remember(record.file); remember(record.original_file) end
        end
        for _,chapter in pairs(book.chapters or {}) do
            for _,record in pairs(chapter or {}) do
                if type(record)=="table" then remember(record.file); remember(record.original_file) end
            end
        end
    end
    return known
end

function Plugin:_home_local_rows()
    local index_cache=self:_home_local_cache()
    local tree=self:_home_local_tree_cache()
    local roots=self:_home_local_roots(true)
    local rows={}
    local known_paths=self:_home_local_known_paths()
    local home=self:_home_preferences()
    local mode=tostring(home.local_library_mode or "direct")
    local hidden=type(home.hidden_local_files)=="table" and home.hidden_local_files or {}
    local indexed_by_file={}
    for _,book in ipairs(index_cache.books or {}) do indexed_by_file[LocalLibrary.normalize(book.file)]=book end

    local function add_book(row)
        local path=LocalLibrary.normalize(row and row.file or "")
        if path=="" or not U.file_exists(path) or known_paths[path] or hidden[path]==true
            or LocalLibrary.is_likely_dictionary(path,row.title) then return end
        local copy=U.copy(row)
        local old=indexed_by_file[path]
        if old and tonumber(old.modified_at or 0)==tonumber(copy.modified_at or 0) then LocalMetadata.merge(copy,old) end
        copy.file=path; copy.local_file=true; copy.source="local"
        copy.status_text=self:_home_status_text(copy,true)
        rows[#rows+1]=copy
    end

    if mode=="direct" then
        -- The home grid itself is the folder browser. Only the selected level
        -- is exposed; recursive indexes remain completely separate.
        local inline_rows=self:_home_local_inline_rows()
        for _,row in ipairs(inline_rows or {}) do rows[#rows+1]=row end
    else
        local enabled={}
        for _,root in ipairs(roots) do enabled[LocalLibrary.normalize(root.path)]=true end
        for _,book in ipairs(index_cache.books or {}) do
            local root=LocalLibrary.normalize(book.library_root or index_cache.root or "")
            if root=="" or enabled[root] then add_book(book) end
        end
        table.sort(rows,function(a,b)
            local am,bm=tonumber(a.last_read_at or a.modified_at) or 0,tonumber(b.last_read_at or b.modified_at) or 0
            if am~=bm then return am>bm end
            return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
        end)
    end
    return rows,index_cache
end

function Plugin:_home_local_inline_navigate(path,root_path)
    path=LocalLibrary.normalize(path or "")
    root_path=LocalLibrary.normalize(root_path or "")
    if path~="" and lfs.attributes(path,"mode")~="directory" then
        self:info("本地书库目录不存在")
        return false
    end
    self._home_inline_navigation_generation=(tonumber(self._home_inline_navigation_generation) or 0)+1
    local generation=self._home_inline_navigation_generation
    self:_home_set_local_inline_location(path,root_path)
    local cached=path~="" and self:_home_local_tree_cache().dirs[path] or nil
    self:_home_apply_local_inline_section(type(cached)=="table")
    if path=="" then return true end
    if type(cached)~="table" or cached.error then self:toast("正在打开文件夹…",2) end
    local home=self:_home_preferences()
    if type(cached)=="table" and not cached.error and home.local_check_on_open==false then return true end
    return self:_home_refresh_local_directory(path,function(snapshot)
        if generation~=self._home_inline_navigation_generation then return end
        local context=self:_home_local_inline_context()
        if context.picker or LocalLibrary.normalize(context.path)~=path then return end
        self:_home_apply_local_inline_section(true)
    end,true)
end


local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
