-- MiuRead home content / local library controller, split from main.lua.
local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local U = require("miuread.util")
local Text = require("miuread.text")
local Config = require("miuread.config")
local Session = require("miuread.session_state")
local HomeView = require("miuread.home_view")
local Library = require("miuread.library")
local LocalMetadata = require("miuread.local_metadata")
local NetworkMetadata = require("miuread.network_metadata")
local HomeNetworkMetadata = require("miuread.home_network_metadata")
local PluginSettings = require("miuread.plugin_settings")
local Protocol = require("miuread.protocol")
local ActionSheet = require("miuread.action_sheet")
local Lazy = require("miuread.lazy")
local FullShelfView = Lazy("miuread.full_shelf_view")
local LocalBrowserView = Lazy("miuread.local_browser_view")
local LocalAnnotationDatabase = Lazy("miuread.local_annotation_database")
local LocalLibrary = Lazy("miuread.local_library")
local ReaderListDialog = Lazy("miuread.reader_list_dialog")
local ScreenshotMode = Lazy("miuread.screenshot_mode")
local HomeLayouts = require("miuread.home_layout_constants")
local HomeData = require("miuread.home_data")
local ReadTimeLedger = require("miuread.read_time_ledger")
local AnnotationKinds = require("miuread.annotation_kinds")
local GestureBridge = require("miuread.gesture_bridge")
local RawConfirmBox = require("ui/widget/confirmbox")
local RawInputDialog = require("ui/widget/inputdialog")

local HOME_LOCAL_CACHE_TTL = HomeLayouts.HOME_LOCAL_CACHE_TTL
local HOME_ACTION_ITEM_ORDER = HomeLayouts.HOME_ACTION_ITEM_ORDER
local HOME_ACTION_LABELS = HomeLayouts.HOME_ACTION_LABELS

local HOME_SESSION = Session.home()
local READER_CLOSE = Session.reader_close()
local HOME_OWNER_KEY = "__MIUREAD_HOME_OWNER"

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ConfirmBox = gesture_aware_class(RawConfirmBox, {_miuread_transient=true, _miuread_modal_surface=true})
local InputDialog = gesture_aware_class(RawInputDialog, {_miuread_transient=true, _miuread_modal_surface=true})

local _ = Text.tr

local unpack_args = unpack or table.unpack

local ok_socket, socket = pcall(require, "socket")
local function monotonic_wall_time()
    if ok_socket and socket and type(socket.gettime) == "function" then return socket.gettime() end
    return os.time()
end

-- Mirrors main.lua's local normalize.
local function normalize(v) local b=v.bookInfo or v.book or v; return {bookId=tostring(b.bookId or v.bookId or ""),title=b.title or v.title or "未命名",author=b.author or v.author or "",cover=b.cover or v.cover,category=b.category or v.category,progress=tonumber(v.progress or b.progress or 0) or 0,updateTime=tonumber(v.updateTime or b.updateTime or 0) or 0} end

local Plugin = {}

function Plugin:_schedule_home_startup(delay)
    self._home_start_generation=(tonumber(self._home_start_generation) or 0)+1
    local generation=self._home_start_generation
    local function attempt(number)
        if generation~=self._home_start_generation then return end
        if Session.home().suppressed or Session.home().native_visit or Session.home_exiting() or UIManager._exit_code~=nil
            or HOME_SESSION.suspended==true or not self:_home_enabled() then return end
        if HomeView.is_shown() or self:_active_reader_ui() then return end
        local navigation=self:_navigation_state()
        if navigation=="opening_reader" or navigation=="reader" or navigation=="closing_reader"
            or navigation=="native_menu" or navigation=="suspended" or navigation=="exiting" then
            if number<40 and navigation~="exiting" then UIManager:scheduleIn(.25,function() attempt(number+1) end) end
            return
        end
        local owner=tostring(HOME_SESSION.foreground or "")
        local owner_age=os.time()-(tonumber(HOME_SESSION.foreground_changed_at) or os.time())
        if (owner=="reader" or owner=="reader_pending" or owner=="reader_transition") and owner_age<6 then
            if number<40 then UIManager:scheduleIn(.25,function() attempt(number+1) end) end
            return
        end
        local ready=false
        local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
        if ok and FileManager and FileManager.instance then ready=true end
        if not ready and number>=4 then
            ready=self:_ensure_filemanager_base(Session.home().return_file)
        end
        if ready then
            local shown=self:_show_miuread_home_now(false,false,true)
            if shown or HomeView.is_shown() then
                logger.info("[MiuRead][Home] startup bookshelf shown","attempt=",tostring(number))
                return
            end
        end
        if number<40 then
            UIManager:scheduleIn(.25,function() attempt(number+1) end)
        else
            logger.warn("[MiuRead][Home] startup bookshelf was not shown")
        end
    end
    UIManager:scheduleIn(tonumber(delay) or .5,function() attempt(1) end)
end

function Plugin:_home_status_text(book,is_local)
    book=book or {}
    local id=tostring(book.bookId or book.book_id or "")
    local state=self:_download_state()
    local state_id=tostring(state.book_id or (state.book and state.book.bookId) or "")
    if id~="" and state_id==id then
        if state.status=="active" then
            -- Active progress is rendered as a thin bar on the matching shelf
            -- card. Keep it out of Recent Reading and out of status text.
            return ""
        end
        if state.status=="failed" then return "失败" end
        if state.status=="annotation_pending" then return "批注待修复" end
        if state.status=="interrupted" or state.status=="pending_install" then return "待修复" end
    end
    if id~="" then
        for _,job in ipairs(self.store:download_queue()) do
            local queued_id=tostring(job.book and (job.book.bookId or job.book.book_id) or "")
            if queued_id==id then return "排队中" end
        end
    end
    if is_local or book.source=="local" or book.local_file==true then return "本地" end
    local file=tostring(book.file or "")
    if book.source=="miuread" or book.shelf_section=="generated" or (file~="" and U.file_exists(file)) then return "已生成" end
    if Protocol.is_mp_account(id) or book.source=="mp" then return "公众号" end
    return "未生成"
end

function Plugin:_home_root()
    local prefs=self.store:preferences().home_ui or {}
    local explicit=U.trim(tostring(prefs.local_root or ""))
    if explicit~="" and lfs.attributes(explicit,"mode")=="directory" then return explicit end

    local native_home=""
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"home_dir")
        if ok then native_home=U.trim(tostring(value or "")) end
    end
    local download_root=tostring(self.store.default_books_dir or ""):gsub("/+$","")
    local normalized_home=native_home:gsub("/+$","")
    if download_root~="" and (normalized_home==download_root or normalized_home:sub(1,#download_root+1)==download_root.."/") then
        -- KOReader often remembers the MiuRead download folder as its current
        -- home. That is not the user's full local library.
        native_home=""
    end

    for _,candidate in ipairs({
        "/mnt/us/documents",
        "/mnt/onboard",
        native_home,
        "/mnt/us/books",
        self.store.default_books_dir,
    }) do
        if candidate and candidate~="" and candidate~="/" and lfs.attributes(candidate,"mode")=="directory" then
            return candidate
        end
    end
    return self.store.default_books_dir
end

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

function Plugin:_home_apply_local_inline_section(refresh_metadata)
    if not self._home_sections then return false end
    local rows=select(1,self:_home_local_rows())
    self._home_sections["local"]={title="本地书籍",rows=rows,empty=self:_home_local_empty_text()}
    self:_home_bump_section_revision("local")
    if self._home_active_section~="local" or not HomeView.is_shown() then return true end
    local updated=self:_home_apply_section("local")
    if refresh_metadata and updated then
        local home=self:_home_preferences()
        local preview=self:_home_preview_page(rows,self._home_hero,
            home.page_by_section and home.page_by_section["local"],self:_home_page_limit())
        self:_home_schedule_local_metadata(preview)
        self:_home_schedule_remote_covers(preview)
    end
    return updated
end

function Plugin:_home_set_local_inline_location(path,root_path)
    local home,preferences=self:_home_preferences()
    home.local_inline_path=LocalLibrary.normalize(path or "")
    home.local_inline_root=LocalLibrary.normalize(root_path or "")
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    home.page_by_section["local"]=1
    self:_home_bump_interaction_generation()
    self:_save_home_preferences_deferred(home,preferences)
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

function Plugin:_home_ensure_local_inline_loaded()
    local home=self:_home_preferences()
    if tostring(home.local_library_mode or "direct")~="direct" then return false end
    local context=self:_home_local_inline_context()
    if context.picker or context.path=="" then return false end
    local existing=self:_home_local_tree_cache().dirs[context.path]
    if type(existing)=="table" and not existing.error then return true end
    local generation=(tonumber(self._home_inline_navigation_generation) or 0)+1
    self._home_inline_navigation_generation=generation
    self:toast("正在读取本地文件夹…",2)
    return self:_home_refresh_local_directory(context.path,function()
        if generation~=self._home_inline_navigation_generation then return end
        local current=self:_home_local_inline_context()
        if current.picker or LocalLibrary.normalize(current.path)~=LocalLibrary.normalize(context.path) then return end
        self:_home_apply_local_inline_section(true)
    end,true)
end

function Plugin:_home_handle_back()
    if self._home_active_section~="local" then return false end
    local home=self:_home_preferences()
    if tostring(home.local_library_mode or "direct")~="direct" then return false end
    local context=self:_home_local_inline_context()
    if context.picker or not context.root then return false end
    local parent=self:_home_local_inline_parent_entry(context)
    if not parent then return false end
    self:_home_local_inline_navigate(parent.folder_path,parent.root_path)
    return true
end

function Plugin:_home_attach_local_record(row)
    if type(row)~="table" then return row end
    local id=tostring(row.bookId or row.book_id or "")
    if id=="" then return row end
    local stored=type(row.local_record)=="table" and row.local_record or self.store:book(id)
    if type(stored)=="table" then
        for _,key in ipairs({"description","intro","summary","category","publisher","series","translator","language","pages","wordCount","word_count","format","variant","annotation_requested","metadata_source","metadata_mtime","metadata_checked_at","metadata_complete"}) do
            if (row[key]==nil or row[key]=="") and stored[key]~=nil and stored[key]~="" then row[key]=stored[key] end
        end
        if not row.cover_path and stored.cover_path then row.cover_path=stored.cover_path end
    end
    local record=self:_preferred_record(id)
    if record and record.file and U.file_exists(record.file) then
        row.file=record.file
        for _,key in ipairs({"description","author","title","category","publisher","series","translator","language","pages","wordCount","word_count","format","variant","annotation_requested","metadata_source","metadata_mtime","metadata_checked_at","metadata_complete"}) do
            if (row[key]==nil or row[key]=="") and record[key]~=nil and record[key]~="" then row[key]=record[key] end
        end
        if not row.cover_path and record.cover_path then row.cover_path=record.cover_path end
    end
    return row
end

function Plugin:_home_miuread_rows()
    local remote_books,remote_mp=self.library:cached()
    remote_books=type(remote_books)=="table" and remote_books or {}
    local remote_by_id={}
    for _,book in ipairs(remote_books) do
        local id=tostring(book.bookId or book.book_id or "")
        if id~="" then remote_by_id[id]=book end
    end
    local rows=self:_shelf_rows("generated",false,remote_books,{},#remote_books>0)
    rows=self.library:sort_filter(rows,{section="generated"})
    table.sort(rows,function(a,b)
        local ar,br=tonumber(a.lastReadTime) or 0,tonumber(b.lastReadTime) or 0
        if ar~=br then return ar>br end
        local ad,bd=tonumber(a.downloadedAt) or 0,tonumber(b.downloadedAt) or 0
        if ad~=bd then return ad>bd end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    self:_prepare_shelf_rows(rows)
    local fields={"title","author","description","intro","summary","category","publisher","translator","wordCount","cover"}
    for _,row in ipairs(rows) do
        self:_home_attach_local_record(row)
        local id=tostring(row.bookId or row.book_id or "")
        local remote=remote_by_id[id]
        if remote then
            for _,key in ipairs(fields) do
                if (row[key]==nil or row[key]=="") and remote[key]~=nil and remote[key]~="" then row[key]=remote[key] end
            end
        end
        row.description=row.description or row.intro or row.summary
        row.source="miuread"
        row.status_text=self:_home_status_text(row,false)
    end
    return rows
end

local function normalized_home_time(value)
    local stamp=tonumber(value) or 0
    if stamp>100000000000 then stamp=math.floor(stamp/1000) end
    return stamp>0 and stamp or 0
end

local function home_recent_item_identity(item)
    if type(item)~="table" then return "","" end
    local id=tostring(item.book_id or item.bookId or "")
    local file=LocalLibrary.normalize(item.file or "")
    return id,file
end

local function home_recent_item_key(item)
    local id,file=home_recent_item_identity(item)
    if id~="" then return "book:"..id end
    return file~="" and ("file:"..file) or ""
end

function Plugin:_home_share_recent_read(book_id,path,stamp)
    book_id=tostring(book_id or "")
    path=LocalLibrary.normalize(path or "")
    stamp=normalized_home_time(stamp)
    if stamp<=0 or (book_id=="" and path=="") then return false end
    local item={book_id=book_id,file=path,read_at=stamp}
    item.key=home_recent_item_key(item)
    local bridge=type(HOME_SESSION.recent_reads_bridge)=="table"
        and HOME_SESSION.recent_reads_bridge or {version=1,items={}}
    bridge.version=1
    bridge.items=type(bridge.items)=="table" and bridge.items or {}
    local items={item}
    local seen_ids,seen_files={},{}
    if book_id~="" then seen_ids[book_id]=true end
    if path~="" then seen_files[path]=true end
    for _,old in ipairs(bridge.items) do
        local old_id,old_file=home_recent_item_identity(old)
        local duplicate=(old_id~="" and seen_ids[old_id]) or (old_file~="" and seen_files[old_file])
        if not duplicate and (old_id~="" or old_file~="") then
            if old_id~="" then seen_ids[old_id]=true end
            if old_file~="" then seen_files[old_file]=true end
            items[#items+1]=old
            if #items>=10 then break end
        end
    end
    bridge.items=items
    HOME_SESSION.recent_reads_bridge=bridge
    HOME_SESSION.recent_read_dirty=true
    return true
end

function Plugin:_home_recent_read_state()
    local stored
    if self.store.recent_reads then stored=self.store:recent_reads()
    else stored=self.store:get("recent_reads",{version=1,items={}}) end
    stored=type(stored)=="table" and stored or {version=1,items={}}
    stored.items=type(stored.items)=="table" and stored.items or {}
    local bridge=type(HOME_SESSION.recent_reads_bridge)=="table"
        and HOME_SESSION.recent_reads_bridge or {items={}}
    local merged={version=1,items={}}
    local seen_ids,seen_files={},{}
    local function append(item)
        if type(item)~="table" then return end
        local id,file=home_recent_item_identity(item)
        if id=="" and file=="" then return end
        if (id~="" and seen_ids[id]) or (file~="" and seen_files[file]) then return end
        if id~="" then seen_ids[id]=true end
        if file~="" then seen_files[file]=true end
        merged.items[#merged.items+1]=item
    end
    for _,item in ipairs(type(bridge.items)=="table" and bridge.items or {}) do
        append(item)
        if #merged.items>=10 then break end
    end
    if #merged.items<10 then
        for _,item in ipairs(stored.items) do
            append(item)
            if #merged.items>=10 then break end
        end
    end
    return merged
end

function Plugin:_home_apply_recent_read_times(...)
    local state=self:_home_recent_read_state()
    local by_book,by_file={},{}
    for _,item in ipairs(state.items or {}) do
        if type(item)=="table" then
            local stamp=normalized_home_time(item.read_at)
            local id=tostring(item.book_id or "")
            local file=LocalLibrary.normalize(item.file or "")
            if stamp>0 and id~="" and stamp>(tonumber(by_book[id]) or 0) then by_book[id]=stamp end
            if stamp>0 and file~="" and stamp>(tonumber(by_file[file]) or 0) then by_file[file]=stamp end
        end
    end
    for index=1,select("#",...) do
        local list=select(index,...)
        for _,book in ipairs(type(list)=="table" and list or {}) do
            local id=tostring(book.bookId or book.book_id or "")
            local file=LocalLibrary.normalize(book.file or "")
            local stamp=math.max(tonumber(by_book[id]) or 0,tonumber(by_file[file]) or 0)
            if stamp>0 then book.local_recent_read_at=stamp end
        end
    end
    return state
end

function Plugin:_home_book_time(book)
    if type(book)~="table" then return 0 end
    local primary=math.max(
        normalized_home_time(book.local_recent_read_at),
        normalized_home_time(book.lastReadTime),
        normalized_home_time(book.readUpdateTime),
        normalized_home_time(book.last_read_at),
        normalized_home_time(book.opened_at))
    if primary>0 then return primary end
    return math.max(
        normalized_home_time(book.cloudUpdatedAt),
        normalized_home_time(book.updateTime),
        normalized_home_time(book.downloadedAt),
        normalized_home_time(book.modified_at))
end

function Plugin:_home_recent_book(miuread_rows,local_rows,account_rows)
    local lists={miuread_rows or {},local_rows or {},account_rows or {}}
    local state=self:_home_apply_recent_read_times(unpack_args(lists))
    local by_book,by_file={},{}
    for _,list in ipairs(lists) do
        for _,book in ipairs(list) do
            if not (book.local_folder==true or book.kind=="folder") then
                local id=tostring(book.bookId or book.book_id or "")
                local file=LocalLibrary.normalize(book.file or "")
                if id~="" and not by_book[id] then by_book[id]=book end
                if file~="" and not by_file[file] then by_file[file]=book end
            end
        end
    end
    -- A successful local Reader session is authoritative. Progress 0% and
    -- 100% are both valid recent reads; cloud timestamps are only fallback.
    for _,item in ipairs(state.items or {}) do
        if type(item)=="table" then
            local id=tostring(item.book_id or "")
            local file=LocalLibrary.normalize(item.file or "")
            local match=(id~="" and by_book[id]) or (file~="" and by_file[file]) or nil
            if match then return match end
        end
    end
    local best
    for _,list in ipairs(lists) do
        for _,book in ipairs(list) do
            if not (book.local_folder==true or book.kind=="folder")
                and (not best or self:_home_book_time(book)>self:_home_book_time(best)) then best=book end
        end
    end
    if best then return best end
    for _,list in ipairs(lists) do
        for _,book in ipairs(list) do
            if not (book.local_folder==true or book.kind=="folder") then return book end
        end
    end
    return nil
end

function Plugin:_home_last_read_text(book)
    local stamp=self:_home_book_time(book)
    if stamp<=0 then return "" end
    local now=os.time()
    local day=self:_display_time("%Y-%m-%d",stamp)
    if day==self:_display_time("%Y-%m-%d",now) then return "今天 "..self:_display_time("%H:%M",stamp) end
    if day==self:_display_time("%Y-%m-%d",now-24*60*60) then return "昨天 "..self:_display_time("%H:%M",stamp) end
    if self:_display_time("%Y",stamp)==self:_display_time("%Y",now) then return self:_display_time("%m月%d日",stamp) end
    return self:_display_time("%Y年%m月%d日",stamp)
end

function Plugin:_home_source_text(book)
    if not book then return "" end
    if book.source=="local" or book.local_file==true then
        local format=tostring(book.format or ""):upper()
        return format~="" and ("本地 · "..format) or "本地书籍"
    end
    if book.source=="miuread" or book.shelf_section=="generated" then return "书架" end
    if Protocol.is_mp_account(tostring(book.bookId or book.book_id or "")) then return "公众号" end
    local category=U.trim(tostring(book.category or ""))
    return category~="" and ("书架 · "..category) or "书架"
end

function Plugin:_home_me_duration()
    -- Device feedback: 页面今日/本周时长改用与「阅读周报」弹窗同一计算
    -- （KOReader 阅读统计），两处数值必然一致；「刷新阅读时长」按钮重算本函数。
    -- reading_stats(true) forces a live read; the default 30s cache made the
    -- card show stale values while the report showed fresh ones (device
    -- feedback: 点击刷新没生效 / 周报没同步到卡片).
    local ok, stats = pcall(HomeData.reading_stats, HomeData, true)
    if not ok or type(stats) ~= "table" then
        return {today = "—", week = "—", source = "本机统计"}
    end
    local week = tonumber(stats.week_seconds or 0) or 0
    local today = tonumber(stats.today_seconds or 0) or 0
    local function fmt(seconds)
        -- format_duration is dot-defined (no self): passing HomeData as the
        -- first pcall arg made seconds a table -> tonumber -> 0 分钟 (device
        -- feedback: card showed 0 while the report showed real values).
        local ok2, text = pcall(HomeData.format_duration, seconds)
        if ok2 and tostring(text or "") ~= "" then return tostring(text) end
        return tostring(seconds > 0 and math.floor(seconds / 60) .. " 分钟" or "—")
    end
    return {today = fmt(today), week = fmt(week), source = "本机统计"}
end

function Plugin:_home_refresh_duration()
    -- 我的页「刷新阅读时长」：强制重读统计（_home_me_duration 用
    -- reading_stats(true)）并立即重建当前页。直接走 _show_miuread_home_now
    -- 而不是 _refresh_home_view，避免 0.05s 调度窗口内被跳过导致
    -- 「提示已刷新但页面没变」（device feedback）。
    if not HomeView.is_shown() then return false end
    self:toast("阅读时长已刷新", 1.2)
    UIManager:scheduleIn(.05, function()
        if HomeView.is_shown() and not self:_active_reader_ui() then
            self:_show_miuread_home_now(false, true, true, "content")
        end
    end)
    return true
end

function Plugin:_set_home_page(page)
    page = HomeLayouts.normalize_page(page)
    local home, preferences = self:_home_preferences()
    if (home.page or "shelf") == page then return end
    -- Debounce rapid tab taps: e-ink full rebuilds are expensive and must not
    -- queue multiple builds within the same event burst.
    if self._home_page_switch_pending == true then return true end
    self._home_page_switch_pending = true
    local generation = (self._home_page_switch_generation or 0) + 1
    self._home_page_switch_generation = generation
    local retries = 0
    local function apply()
        if generation ~= self._home_page_switch_generation then return end
        self._home_page_switch_pending = false
        if not HomeView.is_shown() then
            -- Right after a reader close the parked home is still restoring;
            -- dropping the tap here made 书城/我的 clicks randomly dead
            -- (device feedback). Retry shortly instead of discarding.
            retries = retries + 1
            if retries <= 6 then
                self._home_page_switch_pending = true
                UIManager:scheduleIn(.25, apply)
            end
            return
        end
        local current_home, current_preferences = self:_home_preferences()
        if (current_home.page or "shelf") == page then return end
        current_home.page = page
        self:_save_home_preferences_deferred(current_home, current_preferences)
        -- No page-name toast on tab switches: _refresh_home_view pops an
        -- InfoMessage whenever message is non-empty, which the bottom tabs
        -- must not trigger (device feedback: 弹窗提示页面名没必要).
        self:_refresh_home_view(nil, "content")
    end
    UIManager:nextTick(apply)
    return true
end

function Plugin:_show_home_book_open_popup(book,anchor)
    local id=tostring(book and (book.bookId or book.book_id) or "")
    local target=U.copy(book or {})
    local state=self:_download_state()
    local same_failed=state.status=="failed" and tostring(state.book_id or state.bookId or "")==id
    local partial=id~="" and self.store:book_has_partial_cache(id)==true
    local label=(same_failed or partial) and "继续下载 / 修复" or "下载并阅读"
    ActionSheet.show{
        anchor=anchor,preferred_direction="above",width_ratio=.62,
        title=tostring(target.title or "书籍"),
        subtitle=(same_failed or partial) and "下载尚未完整" or "这本书尚未下载",
        actions={
            {icon="⇩",label=label,detail=(same_failed or partial) and "继续现有任务，必要时重新生成" or "加入下载任务",callback=function()
                self:choose_download(target,nil,false)
            end},
            {icon="i",label="查看详情",detail="书籍简介和出版信息",callback=function() self:book_details(target) end},
        },
    }
    return true
end

function Plugin:_home_open_book(book,anchor)
    if book and (book.local_folder==true or book.kind=="folder") then
        local folder_path=LocalLibrary.normalize(book.folder_path or book.path)
        local root_path=LocalLibrary.normalize(book.root_path or folder_path)
        local home=self:_home_preferences()
        if tostring(home.local_library_mode or "direct")=="direct"
            and HomeView.is_shown() and self._home_active_section=="local" then
            return self:_home_local_inline_navigate(folder_path,root_path)
        end
        local root=self:_home_local_root_for_path(folder_path,self:_home_local_roots(true))
        return self:show_local_browser(folder_path,root or {path=root_path,name=book.title},{},false)
    end
    if book and (book.source=="local" or book.local_file==true) then return self:_home_open_local(book) end
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if Protocol.is_mp_account(id) then
        return self:_home_leave_and_run("mp account",function() self:mp_account(book) end)
    end
    self:_home_attach_local_record(book)
    local record=id~="" and self:_preferred_record(id) or nil
    if record and record.file and U.file_exists(record.file) then
        self:_home_stop_background("opening book")
        return self:_open_file_direct(record.file)
    end
    if id~="" then return self:_show_home_book_open_popup(book,anchor) end
    self:info("本地书籍记录不存在")
    return false
end

function Plugin:_home_book_key(book)
    if not book then return "" end
    if book.local_folder==true or book.kind=="folder" then
        local folder=LocalLibrary.normalize(book.folder_path or book.path or "")
        if folder~="" then return "folder:"..folder end
    end
    local id=tostring(book.bookId or book.book_id or "")
    if id~="" then return "book:"..id end
    local path=tostring(book.file or "")
    if path~="" then return "file:"..path end
    return tostring(book.title or "").."|"..tostring(book.author or "")
end

function Plugin:_home_recent_books(miuread_rows,local_rows,account_rows,hero,limit)
    local rows={}
    local hero_key=self:_home_book_key(hero)
    local seen={}
    if hero_key~="" then seen[hero_key]=true end
    for _,list in ipairs({miuread_rows or {},local_rows or {},account_rows or {}}) do
        for _,book in ipairs(list) do
            local progress=tonumber(book.progress) or 0
            local key=self:_home_book_key(book)
            if not (book.local_folder==true or book.kind=="folder")
                and (progress>0 or self:_home_book_time(book)>0) and key~="" and not seen[key] then
                seen[key]=true
                rows[#rows+1]=book
            end
        end
    end
    table.sort(rows,function(a,b)
        local at,bt=self:_home_book_time(a),self:_home_book_time(b)
        if at~=bt then return at>bt end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    local result={}
    for i=1,math.min(math.max(1,tonumber(limit) or 3),#rows) do result[#result+1]=rows[i] end
    return result
end


function Plugin:_home_all_rows()
    local rows,seen={},{}
    -- Prefer the downloaded copy when the same WeRead book exists in both
    -- "微信书架" and "已下载".
    for _,section in ipairs({"generated","account","local","mp"}) do
        local entry=self._home_sections and self._home_sections[section]
        for _,book in ipairs(entry and entry.rows or {}) do
            local key=self:_home_book_key(book)
            if not (book.local_folder==true or book.kind=="folder") and key~="" and not seen[key] then
                seen[key]=true
                rows[#rows+1]=book
            end
        end
    end
    return rows
end

function Plugin:_home_show_full_shelf(title,rows,options)
    options=type(options)=="table" and options or {}
    rows=type(rows)=="table" and rows or {}
    if #rows==0 then self:info("这里还没有书籍") return false end
    self:_prepare_shelf_rows(rows)
    local prefs=self.store:preferences()
    local show_covers=self:_shelf_covers_enabled(prefs)
    if show_covers then self:_begin_cover_guard("home_all_books") end
    local view
    local ok,result=pcall(function()
        view=FullShelfView.show{
            title=tostring(title or "全部书籍").." · "..tostring(#rows).."本",
            books=rows,
            show_actions=options.show_actions==true,
            show_tabs=false,
            show_covers=show_covers,
            left_action_label=options.left_action_label,
            right_action_label=options.right_action_label,
            on_left_action=options.on_left_action,
            on_right_action=options.on_right_action,
            on_select=function(book,anchor) self:_home_open_book(book,anchor) end,
            on_hold=function(book,anchor) self:_home_hold_book(book,anchor) end,
            on_page_changed=function(page,first,last,current)
                if show_covers then self:_on_shelf_page(rows,current,page,first,last) end
            end,
            on_rendered=function() self:_clear_cover_guard() end,
            on_close=function()
                if self._home_full_shelf_view==view then self._home_full_shelf_view=nil end
                self:_cancel_cover_loading()
                collectgarbage("step",120)
            end,
        }
        return view
    end)
    view=result or view
    if ok and view then
        self._home_full_shelf_view=view
        self:_home_schedule_local_shelf_metadata(rows,view)
        return true
    end
    self:_clear_cover_guard()
    logger.warn("[MiuRead][Home] full shelf unavailable",tostring(view))
    local items={}
    for _,book in ipairs(rows) do
        local row=book
        items[#items+1]={
            text=tostring(row.title or "未命名"),
            post_text=tostring(row.author or ""),
            callback=function(anchor) self:_home_open_book(row,anchor) end,
            hold_callback=function() self:_home_hold_book(row) end,
        }
    end
    self:list(tostring(title or "全部书籍"),items)
    return true
end

function Plugin:_home_all_books_state()
    self._home_all_books_options=type(self._home_all_books_options)=="table" and self._home_all_books_options or {
        source="all",status="all",sort="recent",
    }
    return self._home_all_books_options
end

function Plugin:_home_all_books_apply(rows)
    local state=self:_home_all_books_state()
    local filtered={}
    for _,book in ipairs(rows or {}) do
        local source=tostring(book.source or book.shelf_section or "")
        local id=tostring(book.bookId or book.book_id or "")
        local source_ok=state.source=="all"
            or (state.source=="account" and source=="account" and not Protocol.is_mp_account(id))
            or (state.source=="generated" and (source=="miuread" or source=="generated" or book.shelf_section=="generated"))
            or (state.source=="local" and (source=="local" or book.local_file==true))
            or (state.source=="mp" and Protocol.is_mp_account(id))
        local progress=tonumber(book.progress or 0) or 0
        local status=tostring(book.status_text or "")
        local status_ok=state.status=="all"
            or (state.status=="reading" and progress>0 and progress<100)
            or (state.status=="unread" and progress<=0)
            or (state.status=="finished" and progress>=100)
            or (state.status=="downloaded" and book.file and U.file_exists(book.file))
            or (state.status=="failed" and (status:find("失败",1,true) or status:find("修复",1,true)))
        if source_ok and status_ok then filtered[#filtered+1]=book end
    end
    table.sort(filtered,function(a,b)
        if state.sort=="title" then
            return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
        elseif state.sort=="author" then
            local aa,ba=tostring(a.author or ""):lower(),tostring(b.author or ""):lower()
            if aa~=ba then return aa<ba end
            return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
        elseif state.sort=="added" then
            local at=tonumber(a.created_at or a.added_at or a.updated_at or 0) or 0
            local bt=tonumber(b.created_at or b.added_at or b.updated_at or 0) or 0
            if at~=bt then return at>bt end
        else
            local at,bt=self:_home_book_time(a),self:_home_book_time(b)
            if at~=bt then return at>bt end
        end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    return filtered
end

function Plugin:_home_close_full_shelf()
    local view=self._home_full_shelf_view
    if view and UIManager:isWidgetShown(view) then
        pcall(function() UIManager:close(view) end)
    end
    self._home_full_shelf_view=nil
end

function Plugin:_home_all_books_option_dialog()
    local state=self:_home_all_books_state()
    local source_labels={all="全部来源",account="书架",generated="已下载",["local"]="本地书籍",mp="公众号"}
    local status_labels={all="全部状态",reading="阅读中",unread="尚未开始",finished="已读完",downloaded="已下载",failed="异常"}
    local sort_labels={recent="最近阅读",added="最近加入",title="按书名",author="按作者"}

    local function apply_choice(key,value)
        state[key]=value
        self:_home_close_full_shelf()
        UIManager:scheduleIn(.05,function() self:show_home_all_books() end)
    end
    local function choice_rows(key,choices,labels)
        local rows={}
        for _,value in ipairs(choices) do
            local choice_value=value
            rows[#rows+1]={
                text=labels[choice_value],radio=true,checked_func=function() return state[key]==choice_value end,
                callback=function() apply_choice(key,choice_value) end,
            }
        end
        return rows
    end

    return self:_show_standalone_menu("筛选与排序",{
        {text="来源",post_text=source_labels[state.source],sub_item_table_func=function()
            return choice_rows("source",{"all","account","generated","local","mp"},source_labels)
        end},
        {text="状态",post_text=status_labels[state.status],sub_item_table_func=function()
            return choice_rows("status",{"all","reading","unread","finished","downloaded","failed"},status_labels)
        end},
        {text="排序",post_text=sort_labels[state.sort],sub_item_table_func=function()
            return choice_rows("sort",{"recent","added","title","author"},sort_labels)
        end},
        {text="恢复默认",post_text="全部来源 · 全部状态 · 最近阅读",callback=function()
            self._home_all_books_options={source="all",status="all",sort="recent"}
            self:_home_close_full_shelf()
            UIManager:scheduleIn(.05,function() self:show_home_all_books() end)
        end},
    })
end

function Plugin:show_home_all_books()
    local rows=self:_home_all_books_apply(self:_home_all_rows())
    if #rows==0 then self:info("当前筛选条件下没有书籍") return false end
    local view
    local ok=self:_home_show_full_shelf("全部书籍",rows,{
        show_actions=true,
        left_action_label="搜索全部书籍",
        right_action_label="筛选与排序",
        on_left_action=function() self:show_home_search_dialog() end,
        on_right_action=function() self:_home_all_books_option_dialog() end,
    })
    return ok
end

function Plugin:show_home_reading_history()
    local rows={}
    for _,book in ipairs(self:_home_all_rows()) do
        if self:_home_book_time(book)>0 or tonumber(book.progress or 0)>0 then rows[#rows+1]=book end
    end
    table.sort(rows,function(a,b)
        local at,bt=self:_home_book_time(a),self:_home_book_time(b)
        if at~=bt then return at>bt end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    return self:_home_show_full_shelf("阅读历史",rows)
end

function Plugin:show_home_search_dialog()
    local d
    d=InputDialog:new{
        title="搜索我的书籍",input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local query=U.trim(d:getInputText())
                UIManager:close(d)
                if query=="" then return end
                local results=self.library:search(self:_home_all_rows(),query)
                if #results==0 then self:info("没有找到相关书籍") return end
                self:_home_show_full_shelf("搜索 “"..query.."”",results)
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end


function Plugin:_annotation_book_title_map()
    local map = {}
    for _, book in ipairs(self:_home_all_rows()) do
        local id = tostring(book.bookId or book.book_id or "")
        if id ~= "" then
            map[id] = {title=tostring(book.title or "未命名"), author=tostring(book.author or ""), book=book}
        end
    end
    for id, book in pairs(self.store:library() or {}) do
        id = tostring(id)
        if not map[id] then
            map[id] = {title=tostring(book.title or "未命名"), author=tostring(book.author or ""), book=book}
        end
    end
    return map
end

function Plugin:show_annotation_search_dialog(back_callback, scope)
    local d
    local scope_title = scope == "thought" and "搜索我的想法" or (scope == "highlight" and "搜索我的划线" or "搜索批注")
    local scope_desc = scope == "thought" and "只搜索我写下的想法"
        or (scope == "highlight" and "只搜索我的划线（含书签）" or "搜索全部书籍的划线、想法和书签")
    d=InputDialog:new{
        title=scope_title,
        description=scope_desc,
        input=tostring(self._annotation_last_search or ""),
        buttons={{
            {text="取消",id="close",callback=function()
                UIManager:close(d)
                if back_callback then UIManager:scheduleIn(.05,back_callback) end
            end},
            {text="搜索",is_enter_default=true,callback=function()
                local query=U.trim(d:getInputText())
                UIManager:close(d)
                if query=="" then
                    if back_callback then UIManager:scheduleIn(.05,back_callback) end
                    return
                end
                self._annotation_last_search=query
                UIManager:nextTick(function() self:_annotation_run_search(query,back_callback,scope) end)
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
    return true
end

function Plugin:_annotation_run_search(query,back_callback,scope)
    local results,err=LocalAnnotationDatabase.search_all(self.store,query,200)
    if type(results)~="table" then
        self:info("批注搜索失败：\n"..tostring(err or "无法读取本地批注"))
        if back_callback then UIManager:scheduleIn(.05,back_callback) end
        return false
    end
    if scope == "thought" or scope == "highlight" then
        local filtered={}
        for _,result in ipairs(results) do
            local kind=tostring(result.kind or "")
            if scope=="thought" and kind=="thought" then
                filtered[#filtered+1]=result
            elseif scope=="highlight" and (kind=="highlight" or kind=="bookmark") then
                -- 划线 scope includes bookmarks (they render as line markers).
                filtered[#filtered+1]=result
            end
        end
        results=filtered
    end
    return self:_annotation_search_results(query,results,back_callback)
end

function Plugin:_annotation_search_excerpt(result)
    result=type(result)=="table" and result or {}
    local text=tostring(result.matched_text or "")
    if text=="" then
        for _,value in ipairs({result.note,result.selected_text,result.anchor_text,result.text}) do
            value=tostring(value or "")
            if value~="" then text=value break end
        end
    end
    text=U.trim(text:gsub("%s+"," "))
    if text=="" then text=AnnotationKinds.TEXT_FALLBACK end
    return U.utf8_truncate(text,140,"…")
end

function Plugin:_annotation_current_book_id()
    local current=self:_current_book_record()
    return current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
end

function Plugin:_annotation_pending_jump(result,manage)
    HOME_SESSION.pending_annotation_jump={
        requested_at=os.time(),
        book_id=tostring(result.book_id or ""),
        local_id=tostring(result.local_id or ""),
        kind=tostring(result.kind or ""),
        pos0=tostring(result.pos0 or ""), pos1=tostring(result.pos1 or ""),
        xpointer=tostring(result.xpointer or ""), page=tonumber(result.page),
        text=tostring(result.text or ""), selected_text=tostring(result.selected_text or ""),
        note=tostring(result.note or ""), datetime=tostring(result.datetime or ""),
        source_path=tostring(result.source_path or ""), manage=manage==true,
    }
end

function Plugin:_annotation_find_reader_item(result)
    local annotations=(self.ui and self.ui.annotation and self.ui.annotation.annotations)
        or (self.ui and self.ui.bookmark and self.ui.bookmark.bookmarks) or {}
    local target_kind=tostring(result and result.kind or "")
    local target_pos=tostring(result and (result.pos0 or result.start) or "")
    local target_xp=tostring(result and result.xpointer or "")
    local target_page=tonumber(result and result.page)
    local target_text=tostring(result and result.selected_text or "")
    if target_text=="" then target_text=tostring(result and result.text or "") end
    target_text=U.trim(target_text:gsub("%s+"," "))
    local target_note=U.trim(tostring(result and result.note or ""):gsub("%s+"," "))
    local best,best_score=nil,-1
    for _,item in ipairs(type(annotations)=="table" and annotations or {}) do
        local kind=self:_reader_annotation_type(item)
        if target_kind=="" or kind==target_kind then
            local score=0
            local pos=tostring(item.pos0 or item.start or "")
            local xp=tostring(item.xpointer or ((type(item.page)=="string" and not tonumber(item.page)) and item.page or ""))
            local page=self:_reader_annotation_page(item)
            if target_pos~="" and pos==target_pos then score=score+12 end
            if target_xp~="" and xp==target_xp then score=score+10 end
            if target_page and page and tonumber(page)==target_page then score=score+2 end
            local item_text=U.trim(tostring(item.text or item.notes or ""):gsub("%s+"," "))
            local item_note=U.trim(tostring(item.note or ""):gsub("%s+"," "))
            if target_text~="" and item_text==target_text then score=score+4 end
            if target_note~="" and item_note==target_note then score=score+4 end
            if score>best_score then best,best_score=item,score end
        end
    end
    return best_score>=4 and best or nil
end

function Plugin:_annotation_open_result(result,book_info,manage,after_manage)
    result=type(result)=="table" and result or {}
    local target_id=tostring(result.book_id or "")
    if target_id~="" and target_id==self:_annotation_current_book_id() and self.ui and self.ui.document then
        self:_reader_goto_annotation(result)
        if manage==true then
            UIManager:scheduleIn(.12,function()
                local item=self:_annotation_find_reader_item(result)
                if item then self:_show_reader_annotation_actions(item,self:_reader_annotation_type(item),nil,after_manage)
                else self:toast("已跳到批注位置；当前记录暂时无法直接编辑",2) end
            end)
        end
        return true
    end

    self:_annotation_pending_jump(result,manage)
    local source=tostring(result.source_path or "")
    if source~="" and U.file_exists(source) then return self:_open_file_direct(source) end
    local target_book=book_info and book_info.book or nil
    if not target_book then
        for _,book in ipairs(self:_home_all_rows()) do
            if tostring(book.bookId or book.book_id or "")==target_id then target_book=book break end
        end
    end
    if target_book then
        local opened=self:_home_open_book(target_book)
        if opened~=false then return true end
    end
    HOME_SESSION.pending_annotation_jump=nil
    self:info("《"..tostring(book_info and book_info.title or "未知书籍").."》的本地书籍文件不存在，暂时无法跳转。")
    return false
end

function Plugin:_annotation_recent_list(back_callback)
    local results, err = LocalAnnotationDatabase.recent_all(self.store, 200)
    if type(results) ~= "table" then
        self:info("批注读取失败：\n" .. tostring(err or "无法读取本地批注"))
        return false
    end
    return self:_annotation_search_results("", results, back_callback, {
        title = "我的批注",
        subtitle = "最近划线与想法 · 点击跳转，长按管理",
        on_back = back_callback or function() self:_refresh_home_view(nil, "content") end,
    })
end

function Plugin:_annotation_search_results(query,results,back_callback,opts)
    local title_map=self:_annotation_book_title_map()
    local rows={}
    for _,result in ipairs(type(results)=="table" and results or {}) do
        local current=result
        local info=title_map[tostring(current.book_id or "")] or {
            title="未知书籍",author="",book=nil,
        }
        local value=AnnotationKinds.label(current.kind)
        if current.page then value=value.." · 第 "..tostring(current.page).." 页" end
        rows[#rows+1]={
            icon=AnnotationKinds.icon(current.kind),
            label=self:_annotation_search_excerpt(current),
            detail=U.utf8_truncate(info.title,42,"…")
                ..(info.author~="" and (" · "..U.utf8_truncate(info.author,18,"…")) or ""),
            value=value,
            callback=function() self:_annotation_open_result(current,info,false) end,
            hold_callback=function() self:_annotation_open_result(current,info,true,function()
                self:_capture_local_annotation_snapshot("annotation_search_manage")
                -- Management may have written rows through paths other than this
                -- module; drop the recent-list cache so the re-open is fresh.
                LocalAnnotationDatabase.invalidate_recent_cache()
                UIManager:scheduleIn(.06,function()
                    if query=="" then self:_annotation_recent_list(back_callback)
                    else self:_annotation_run_search(query,back_callback) end
                end)
            end) end,
        }
    end
    local dialog_opts = type(opts) == "table" and opts or {}
    ReaderListDialog.show{
        title=dialog_opts.title or "批注搜索",
        subtitle=dialog_opts.subtitle
            or ("“"..tostring(query).."” · "..tostring(#rows).." 处 · 点击跳转，长按管理"),
        items=rows,page_size=5,
        empty_text=query=="" and "还没有批注记录" or "没有找到匹配的批注",
        on_back=dialog_opts.on_back or function() self:show_annotation_search_dialog(back_callback) end,
        on_home=self:_home_enabled() and function() return self:return_to_miuread_home("annotation search") end or nil,
    }
    return true
end

function Plugin:_home_local_book_details(book)
    local lines={tostring(book.title or "未命名")}
    if U.trim(tostring(book.author or ""))~="" then lines[#lines+1]="作者："..tostring(book.author) end
    if U.trim(tostring(book.format or ""))~="" then lines[#lines+1]="格式："..tostring(book.format) end
    if tonumber(book.progress or 0)>0 then lines[#lines+1]="进度："..tostring(math.floor((tonumber(book.progress) or 0)+.5)).."%" end
    if U.trim(tostring(book.description or ""))~="" then lines[#lines+1]="\n"..tostring(book.description) end
    lines[#lines+1]="\n文件："..tostring(book.file or "")
    self:info(table.concat(lines,"\n"))
end

function Plugin:_home_refresh_one_book_metadata(book,network_too)
    if type(book)~="table" then return false end
    local path=tostring(book.file or "")
    local local_changed=false
    if path~="" and U.file_exists(path) then
        self:toast("正在更新这本书的信息…",2)
        local metadata,err=LocalMetadata.read(path,self:_home_local_metadata_dir(),{open_document=true,use_bim=true})
        if metadata then
            if book.source=="local" or book.local_file==true then
                local_changed=self:_home_update_local_cache(path,metadata)
            else
                local_changed=self:_home_update_miuread_metadata(path,metadata)
            end
            if LocalMetadata.merge(book,metadata) then local_changed=true end
            book.status_text=self:_home_status_text(book,book.source=="local" or book.local_file==true)
        else
            logger.warn("[MiuRead][Home] local metadata refresh failed",tostring(err or "unknown"))
        end
    end
    local network_started=false
    if network_too~=false then
        network_started=self:_home_schedule_network_metadata(book,true,false,nil,true)==true
    end
    if local_changed then self:_refresh_home_view(network_started and "本地信息已更新，正在网络补全" or "书籍信息已更新","content")
    elseif network_started then self:toast("正在从网络补全书籍信息…",2)
    elseif path=="" or not U.file_exists(path) then
        self:info("当前没有可读取的本地文件，网络信息也暂时无法获取")
        return false
    else
        self:toast("没有发现需要更新的信息",2)
    end
    return local_changed or network_started
end

function Plugin:_home_remove_lockscreen_cover_cache(book)
    if type(book)~="table" then return false end
    local id=tostring(book.bookId or book.book_id or "")
    if id=="" then return false end
    local dir=self.store.data_dir.."/lockscreen"
    if lfs.attributes(dir,"mode")~="directory" then return false end
    local prefix=U.id_name(id).."-"
    local removed=false
    local ok,iter,state,var=pcall(lfs.dir,dir)
    if not ok or not iter then return false end
    for name in iter,state,var do
        if name~="." and name~=".." and name:sub(1,#prefix)==prefix and name:match("%.png$") then
            if os.remove(dir.."/"..name) then removed=true end
        end
    end
    return removed
end

function Plugin:_home_force_refresh_current_cover(book,on_done)
    if type(book)~="table" then return false end
    local id=tostring(book.bookId or book.book_id or "")
    local cover=tostring(book.cover or book.coverUrl or "")
    if cover=="" and id~="" then
        local remote_books=self.library:cached()
        for _,row in ipairs(type(remote_books)=="table" and remote_books or {}) do
            if tostring(row.bookId or row.book_id or "")==id then
                cover=tostring(row.cover or row.coverUrl or "")
                if cover~="" then break end
            end
        end
    end
    if id=="" or cover=="" or not self.home_cover_async or self.home_cover_async:busy() then return false end
    if not self:is_online() then return false end

    local old_cached=self.library:cached_cover_path(id)
    local refresh_token="manual-"..tostring(os.time()).."-"..tostring(math.floor((os.clock()%1)*1000))
    local item={bookId=id,cover=cover}
    local background=self.home_cover_async:available()
    local covers_dir=self.store.covers_dir
    local worker
    if background then
        worker=function()
            local HttpChild=require("miuread.http")
            local LibraryChild=require("miuread.library")
            local store={
                covers_dir=covers_dir,
                auth=function() return {cookies={}} end,
                save_auth=function() end,
                get=function(_,_,default) return default end,
                set=function() end,
            }
            return LibraryChild:new(nil,HttpChild:new(store),store):cache_cover(item,{
                retries=1,timeout={8,15},persist_index=false,skip_index_lookup=true,
                cache_suffix=refresh_token,
            })
        end
    else
        worker=function()
            return self.library:cache_cover(item,{
                retries=0,timeout={4,7},persist_index=false,skip_index_lookup=true,
                cache_suffix=refresh_token,
            })
        end
    end

    local started=self.home_cover_async:run("home-cover-manual-refresh",worker,function(result)
        if not result or result.ok~=true or not result.value then
            logger.warn("[MiuRead][Cover] manual refresh failed",tostring(id),
                tostring(result and result.error or "unknown"))
            if on_done then on_done(false) end
            return
        end
        local path=tostring(result.value)
        local index=self.store:get("cover_index",{})
        index[tostring(id)]=path
        self.store:set("cover_index",index)
        if self._cover_index_pending then self._cover_index_pending[tostring(id)]=nil end

        book.cover_path=path
        self:_home_apply_cover_path(id,path)
        for key,section in pairs(self._home_sections or {}) do
            for _,row in ipairs(section.rows or {}) do
                if tostring(row.bookId or row.book_id or "")==id then
                    row.cover_path=path
                    self:_home_bump_section_revision(key)
                    break
                end
            end
        end

        self:_home_remove_lockscreen_cover_cache(book)
        local home=self:_home_preferences()
        if home.lockscreen_recent~=false then
            local hero=self._home_hero
            if hero and tostring(hero.bookId or hero.book_id or "")==id then
                hero.cover_path=path
                local screensaver=self:_home_prepare_lockscreen_cover(hero)
                HOME_SESSION.screensaver_file=screensaver
                local current=HomeView.current()
                if current and current.opts then current.opts.screensaver_file=screensaver end
                UIManager:scheduleIn(.25,function()
                    if HomeView.is_shown() and not self:_active_reader_ui() then self:_home_schedule_cover_derivatives({hero}) end
                end)
            end
        end

        if old_cached and old_cached~=path then os.remove(old_cached) end
        if HomeView.is_shown() then
            if self._home_hero and tostring(self._home_hero.bookId or self._home_hero.book_id or "")==id then
                HomeView.update_hero(self._home_hero)
            end
            HomeView.update_book(id)
        end
        logger.info("[MiuRead][Cover] manual refresh complete",tostring(id),tostring(path))
        if on_done then on_done(true) end
    end,background and 35 or 14)
    return started==true
end

function Plugin:_home_refresh_current_network_metadata(book)
    if type(book)~="table" then return false end
    if not self:is_online() then
        self:toast("当前未联网，无法更新书籍信息和封面",2)
        return false
    end

    self:toast("正在更新这本书的信息和封面…",2)
    local state={metadata_done=false,metadata_ok=false,metadata_partial=false,cover_done=false,cover_ok=false,finished=false}
    local function finish()
        if state.finished or not state.metadata_done or not state.cover_done then return end
        state.finished=true
        if state.metadata_ok and state.cover_ok then
            self:toast(state.metadata_partial
                and "封面和书籍信息已刷新，部分资料暂未找到"
                or "书籍信息和封面已更新",2)
        elseif state.cover_ok then
            self:toast("封面已更新，网络书籍信息更新失败",2)
        elseif state.metadata_ok then
            self:toast(state.metadata_partial
                and "书籍信息已刷新，部分资料暂未找到；封面更新失败"
                or "书籍信息已更新，封面更新失败",2)
        else
            self:toast("当前书籍更新失败，请稍后重试",2)
        end
    end

    local metadata_started=self:_home_schedule_network_metadata(book,true,true,function(ok,_,detail)
        state.metadata_done=true
        state.metadata_ok=ok==true
        state.metadata_partial=type(detail)=="table" and detail.partial==true
        finish()
    end,true)==true
    if not metadata_started then state.metadata_done=true end

    local cover_started=self:_home_force_refresh_current_cover(book,function(ok)
        state.cover_done=true
        state.cover_ok=ok==true
        finish()
    end)==true
    if not cover_started then state.cover_done=true end

    if metadata_started or cover_started then
        finish()
        return true
    end
    if self.home_metadata_async and self.home_metadata_async:busy() then
        self:toast("已有图书信息任务正在进行，请稍后再试",2)
    elseif self.home_cover_async and self.home_cover_async:busy() then
        self:toast("已有封面任务正在进行，请稍后再试",2)
    elseif tostring(book.cover or book.coverUrl or "")=="" then
        self:toast("当前书籍没有可更新的网络封面",2)
    else
        self:toast("当前暂时无法开始更新",2)
    end
    return false
end

function Plugin:_home_hide_local_book(book)
    local path=tostring(book and book.file or ""):gsub("\\","/"):gsub("/+","/")
    if path=="" then return false end
    local home,preferences=self:_home_preferences()
    home.hidden_local_files=type(home.hidden_local_files)=="table" and home.hidden_local_files or {}
    home.hidden_local_files[path]=true
    self:_save_home_preferences(home,preferences)
    self:_show_miuread_home_now(false,true,true,"content")
    self:toast("已从觅阅书架隐藏")
    return true
end

function Plugin:_home_delete_local_book(book,anchor,confirmed)
    local path=tostring(book and book.file or "")
    if path=="" or not U.file_exists(path) then self:info("本地文件不存在") return false end
    local function delete_now()
        local ok,err=os.remove(path)
        if not ok then self:info("删除失败：\n"..tostring(err or "无法删除文件")); return end
        local cache=self:_home_local_cache()
        local kept={}
        for _,row in ipairs(cache.books or {}) do if tostring(row.file or "")~=path then kept[#kept+1]=row end end
        cache.books=kept
        self.store:set("home_local_index",cache)
        self:_show_miuread_home_now(false,true,true,"content")
        self:toast("本地文件已删除")
    end
    if confirmed==true then delete_now(); return true end
    if HomeView.is_shown() then
        return ActionSheet.show{
            anchor=anchor,preferred_direction="above",width_ratio=.60,
            title="删除本地文件？",subtitle="《"..tostring(book.title or "书籍").."》删除后无法通过觅阅恢复。",
            actions={
                {icon="×",label="取消",detail="保留本地文件",callback=function() end},
                {icon="!",label="删除文件",detail="阅读进度侧边文件不会主动删除",danger=true,callback=delete_now},
            },
        }
    end
    UIManager:show(ConfirmBox:new{text="删除本地文件《"..tostring(book.title or "书籍").."》？\n\n文件删除后无法通过觅阅恢复。阅读进度侧边文件不会主动删除。",ok_text="删除文件",cancel_text="取消",ok_callback=delete_now})
    return true
end

function Plugin:_home_repair_book(book)
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if id=="" then self:info("这本书没有可用的修复记录") return false end
    return self:_repair_downloaded_book(id)
end

function Plugin:_show_home_refresh_popup(anchor)
    ActionSheet.show{
        cache_key="home_refresh",
        anchor=anchor,
        preferred_direction="below",
        title="更新",
        subtitle="内容更新与墨水屏全刷分开执行",
        actions={
            {icon="↻",label="更新当前栏目",detail="只检查当前看到的内容",callback=function() self:_home_manual_refresh() end},
            {icon="▣",label="刷新整个主页",detail="核对已有状态并整页更新一次",callback=function() self:_home_refresh_whole_page() end},
            {icon="☁",label="更新书架",detail="重新获取微信书架变化",callback=function() self:_home_refresh_remote(true,true) end},
            {icon="⌕",label="更新本地书库",detail="检查新增、删除和移动的书籍",callback=function()
                local started=self:_home_scan_local(true)
                if started then self:toast("正在更新本地书库…",2) end
            end},
            {icon="i",label="更新最近阅读信息",detail="更新顶部这本书的资料和封面",callback=function()
                local hero=self._home_hero
                if hero then self:_home_refresh_current_network_metadata(hero)
                else self:toast("当前没有最近阅读书籍",2) end
            end},
            {icon="▤",label="全屏刷新",detail="整屏刷新并清除墨水屏残影",callback=function() self:_home_full_refresh(true) end},
        },
    }
end

function Plugin:_show_home_download_popup(anchor)
    ActionSheet.show{
        cache_key="home_download",
        anchor=anchor,
        preferred_direction="below",
        title="下载",
        subtitle=self:_download_menu_text(),
        actions={
            {icon="⇩",label="下载任务",detail="查看进度 排队和失败重试",callback=function() self:show_downloads() end},
            {icon="⚙",label="下载设置",detail="下载策略 目录与提醒",callback=function()
                self:_show_standalone_menu("下载设置",self:download_settings_menu())
            end},
        },
        footer_action={label="存储清理",callback=function() self:show_download_cleanup_dialog() end},
    }
end

function Plugin:_show_home_search_popup(anchor)
    ActionSheet.show{
        cache_key="home_search",
        anchor=anchor,
        preferred_direction="below",
        width_ratio=.62,
        title="搜索",
        subtitle="微信书库、我的书籍与批注分开搜索",
        actions={
            {icon="⌕",label="搜索微信读书",detail="全库搜索，未加入书架也能下载",callback=function() self:search_dialog("搜索微信读书") end},
            {icon="▦",label="搜索我的书籍",detail="书架、已生成和本地书籍",callback=function() self:show_home_search_dialog() end},
            {icon="highlight",label="搜索批注",detail="全部划线、想法和书签",callback=function() self:show_annotation_search_dialog() end},
        },
    }
end

function Plugin:_show_home_frontlight_popup(anchor)
    local enabled=self:_reader_frontlight_enabled()
    local value=math.floor((tonumber(self:_reader_frontlight_value()) or 0)+.5)
    ActionSheet.show{
        cache_key="home_frontlight",
        anchor=anchor,
        preferred_direction="below",
        width_ratio=.60,
        title="前光",
        subtitle="当前亮度 "..tostring(value),
        actions={
            {icon="☼",label="亮度与色温",detail="打开完整前光调节",callback=function() self:_home_frontlight() end},
            {icon=enabled and "○" or "●",label=enabled and "关闭前光" or "开启前光",detail="快速切换前光",callback=function() self:_reader_toggle_frontlight() end},
            {icon="◐",label="切换夜间模式",detail="反转阅读显示",callback=function() self:_home_toggle_night() end},
        },
        wide_last=true,
    }
end

function Plugin:_show_home_settings_center()
    return self:_show_standalone_menu("觅阅设置",{
        {text="首页与书架",post_text="布局 书架与快捷入口",sub_item_table_func=function() return self:display_settings_menu() end},
        {text="阅读界面",post_text="显示与快捷控制",sub_item_table_func=function() return self:reader_quick_panel_settings_menu() end},
        {text="想法、划线与批注",post_text="想法显示与本地批注",sub_item_table_func=function() return PluginSettings.comments(self) end},
        {text="时间与时区",post_text="时间来源与地区显示",sub_item_table_func=function() return self:time_display_settings_menu() end},
        {text="更新与关于",post_text="版本 更新通道与说明",sub_item_table_func=function() return PluginSettings.update_about(self) end},
        {text="工具与维护",post_text="修复 清理与诊断",sub_item_table_func=function() return self:maintenance_menu() end},
    },{page_size=6})
end

function Plugin:_show_home_settings_popup(anchor)
    local actions={
        {icon="▦",label="首页与书架",detail="布局 书架与快捷入口",callback=function()
            self:_show_standalone_menu("首页与书架",self:display_settings_menu(),{anchor=anchor})
        end},
        {icon="Aa",label="阅读界面",detail="显示与快捷控制",callback=function()
            self:_show_standalone_menu("阅读界面",self:reader_quick_panel_settings_menu(),{anchor=anchor})
        end},
        {icon="✎",label="评论与批注",detail="评论 划线与想法",callback=function()
            self:_show_standalone_menu("评论、划线与想法",PluginSettings.comments(self),{anchor=anchor})
        end},
        {icon="◷",label="时间与时区",detail="时间来源与地区显示",callback=function()
            self:_show_standalone_menu("时间与时区",self:time_display_settings_menu(),{anchor=anchor})
        end},
        {icon="↺",label="更新与关于",detail="版本 更新通道与说明",callback=function()
            self:_show_standalone_menu("更新与关于",PluginSettings.update_about(self),{anchor=anchor})
        end},
        {icon="⚙",label="工具与维护",detail="修复 清理与诊断",callback=function()
            self:_show_standalone_menu("工具与维护",self:maintenance_menu(),{anchor=anchor})
        end},
    }
    return ActionSheet.show{
        cache_key="home_settings",
        anchor=anchor,preferred_direction="below",width_ratio=.78,columns=2,
        title="觅阅设置",subtitle="常用设置与维护",actions=actions,
    }
end

function Plugin:_show_home_all_books_popup(anchor)
    ActionSheet.show{
        cache_key="home_all_books",
        anchor=anchor,preferred_direction="below",width_ratio=.58,
        title="全部书籍",subtitle="浏览完整书架",
        actions={
            {icon="▦",label="打开全部书籍",detail="查看当前所有书籍",callback=function() self:show_home_all_books() end},
            {icon="◷",label="阅读历史",detail="查看最近阅读记录",callback=function() self:show_home_reading_history() end},
        },
    }
end

function Plugin:_show_home_history_popup(anchor)
    ActionSheet.show{
        cache_key="home_history",
        anchor=anchor,preferred_direction="below",width_ratio=.58,
        title="阅读历史",subtitle="最近阅读与完整书架",
        actions={
            {icon="◷",label="打开阅读历史",detail="查看最近阅读记录",callback=function() self:show_home_reading_history() end},
            {icon="▦",label="全部书籍",detail="返回完整书架浏览",callback=function() self:show_home_all_books() end},
        },
    }
end

function Plugin:_show_home_file_manager_popup(anchor)
    ActionSheet.show{
        cache_key="home_file_manager",
        anchor=anchor,preferred_direction="below",width_ratio=.58,
        title="文件管理",subtitle="本地文件入口",
        actions={
            {icon="▤",label="打开 KOReader 文件管理",detail="进入原生文件浏览器",callback=function() self:_home_close_to_native(true) end},
            {icon="▦",label="本地书库",detail="查看觅阅本地书籍",callback=function() self:show_home_local_library() end},
        },
    }
end

function Plugin:_show_home_screenshot_popup(anchor)
    ActionSheet.show{
        cache_key="home_screenshot",
        anchor=anchor,preferred_direction="below",width_ratio=.58,
        title="截图",subtitle="屏幕操作",
        actions={
            {icon="▣",label="开始截图",detail="进入截图模式",callback=function() ScreenshotMode.start(self,anchor) end},
            {icon="▤",label="全屏刷新",detail="清除墨水屏残影",callback=function() self:_home_full_refresh() end},
        },
    }
end

function Plugin:_home_visible_action_neighbor(key,direction)
    local home=self:_home_preferences()
    local order=home.action_order or HOME_ACTION_ITEM_ORDER
    local items=home.action_items or {}
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return nil end
    local step=direction<0 and -1 or 1
    local i=index+step
    while i>=1 and i<=#order do
        if items[order[i]]==true then return order[i] end
        i=i+step
    end
    return nil
end

function Plugin:_home_move_visible_action(key,direction)
    local home,preferences=self:_home_preferences()
    local order=home.action_order or U.copy(HOME_ACTION_ITEM_ORDER)
    local items=home.action_items or {}
    local index,target
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local step=direction<0 and -1 or 1
    local i=index+step
    while i>=1 and i<=#order do
        if items[order[i]]==true then target=i; break end
        i=i+step
    end
    if not target then return false end
    order[index],order[target]=order[target],order[index]
    home.action_order=order
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
    return true
end

function Plugin:_show_home_quick_notice(anchor,title,subtitle,delay)
    return ActionSheet.show{
        anchor=anchor,preferred_direction="below",width_ratio=.48,
        title=tostring(title or "完成"),subtitle=tostring(subtitle or ""),auto_close=tonumber(delay) or 1.4,
    }
end

function Plugin:_home_replace_action_item(from_key,to_key)
    if from_key==to_key then return true end
    local home,preferences=self:_home_preferences()
    local items=home.action_items or {}
    if items[to_key]==true then return false end
    local order=home.action_order or U.copy(HOME_ACTION_ITEM_ORDER)
    local from_i,to_i
    for i,name in ipairs(order) do
        if name==from_key then from_i=i end
        if name==to_key then to_i=i end
    end
    if not from_i or not to_i then return false end
    order[from_i],order[to_i]=order[to_i],order[from_i]
    items[from_key]=false; items[to_key]=true
    home.action_items=items; home.action_order=order
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
    return true
end

function Plugin:_show_home_action_replace_popup(key,anchor)
    local home=self:_home_preferences()
    local actions={}
    for _,candidate in ipairs(home.action_order or HOME_ACTION_ITEM_ORDER) do
        if candidate~=key and home.action_items[candidate]~=true then
            if candidate~="sleep" or Device:canSuspend() then
                local target=candidate
                actions[#actions+1]={icon="↔",label=HOME_ACTION_LABELS[target] or target,detail="替换当前快捷项",callback=function()
                    self:_home_replace_action_item(key,target)
                end}
            end
        end
    end
    return ActionSheet.show{
        anchor=anchor,preferred_direction="below",width_ratio=.70,title="更换快捷项",subtitle="替换后保持当前位置",
        actions=actions,
    }
end

function Plugin:_home_action_function_actions(key,anchor)
    if key=="refresh" then return {
        {icon="↻",label="更新当前栏目",detail="只检查当前看到的内容",callback=function() self:_home_manual_refresh() end},
        {icon="▣",label="刷新整个主页",detail="核对已有状态并整页更新一次",callback=function() self:_home_refresh_whole_page() end},
        {icon="☁",label="更新书架",detail="重新获取微信书架变化",callback=function() self:_home_refresh_remote(true,true) end},
        {icon="⌕",label="更新本地书库",detail="检查新增、删除和移动的书籍",callback=function()
            local started=self:_home_scan_local(true)
            if started then self:toast("正在更新本地书库…",2) end
        end},
        {icon="i",label="更新最近阅读信息",detail="更新顶部这本书的资料和封面",callback=function()
            local hero=self._home_hero
            if hero then self:_home_refresh_current_network_metadata(hero)
            else self:toast("当前没有最近阅读书籍",2) end
        end},
        {icon="▤",label="全屏刷新",detail="整屏刷新并清除墨水屏残影",callback=function() self:_home_full_refresh(true) end},
    } end
    if key=="search" then return {
        {icon="⌕",label="搜索微信读书",detail="全库搜索，未加入书架也能下载",callback=function() self:search_dialog("搜索微信读书") end},
        {icon="▦",label="搜索我的书籍",detail="书架、已生成和本地书籍",callback=function() self:show_home_search_dialog() end},
        {icon="highlight",label="搜索批注",detail="全部划线、想法和书签",callback=function() self:show_annotation_search_dialog() end},
        {icon="▦",label="全部书籍",detail="打开完整书架",callback=function() self:show_home_all_books() end},
        {icon="◷",label="阅读历史",detail="查看最近阅读记录",callback=function() self:show_home_reading_history() end},
        {icon="▤",label="本地书库",detail="浏览本地书籍",callback=function() self:show_home_local_library() end},
        {icon="◎",label="公众号",detail="切换到公众号书架",callback=function() self:_set_home_section("mp") end},
    } end
    if key=="downloads" then return {
        {icon="⇩",label="下载任务",detail="进度 排队与失败重试",callback=function() self:show_downloads() end},
        {icon="⚙",label="下载设置",detail="策略 目录与提醒",callback=function() self:_show_standalone_menu("下载设置",self:download_settings_menu(),{anchor=anchor}) end},
        {icon="✚",label="检查书籍完整性",detail="发现需要修复的已下载书",callback=function() self:scan_downloaded_books_for_integrity_repair() end},
        {icon="⌫",label="存储清理",detail="清理临时文件与失效缓存",callback=function() self:show_download_cleanup_dialog() end},
    } end
    if key=="sleep" then
        local rows={
            {icon="◐",label="休眠",detail="立即进入休眠",callback=function() self:_home_sleep() end},
            {icon="←",label="返回 KOReader",detail="离开觅阅桌面",callback=function() self:_home_close_to_native(true) end},
            {icon="↺",label="重启 KOReader",detail="保存状态后重新启动",callback=function() self:_show_home_power_confirm(anchor,"重启 KOReader？","阅读状态会先保存。","重启",function() self:_restart_koreader("home power bubble") end) end},
            {icon="⏻",label="退出 KOReader",detail="返回 Kindle 原生环境",callback=function() self:_show_home_power_confirm(anchor,"退出 KOReader？","当前阅读和设置会先保存。","退出",function() self:_quit_koreader(true) end) end},
        }
        if type(Device.canReboot)=="function" and Device:canReboot() then rows[#rows+1]={icon="↻",label="重启设备",detail="重新启动 Kindle",callback=function() self:_home_reboot_device(anchor) end} end
        if type(Device.canPowerOff)=="function" and Device:canPowerOff() then rows[#rows+1]={icon="■",label="关闭设备",detail="完全关闭 Kindle",danger=true,callback=function() self:_home_poweroff_device(anchor) end} end
        return rows
    end
    if key=="miuread_settings" then return {
        {icon="▦",label="首页与书架",detail="布局 书架与快捷入口",callback=function() self:_show_standalone_menu("首页与书架",self:display_settings_menu(),{anchor=anchor}) end},
        {icon="Aa",label="阅读界面",detail="显示与快捷控制",callback=function() self:_show_standalone_menu("阅读界面",self:reader_quick_panel_settings_menu(),{anchor=anchor}) end},
        {icon="✎",label="评论与批注",detail="评论 划线与想法",callback=function() self:_show_standalone_menu("评论、划线与想法",PluginSettings.comments(self),{anchor=anchor}) end},
        {icon="↺",label="更新与关于",detail="版本 更新通道与说明",callback=function() self:_show_standalone_menu("更新与关于",PluginSettings.update_about(self),{anchor=anchor}) end},
        {icon="⚙",label="工具与维护",detail="修复 清理与诊断",callback=function() self:_show_standalone_menu("工具与维护",self:maintenance_menu(),{anchor=anchor}) end},
    } end
    if key=="all_books" then return {
        {icon="▦",label="全部书籍",detail="打开完整书架",callback=function() self:show_home_all_books() end},
        {icon="◷",label="阅读历史",detail="最近阅读记录",callback=function() self:show_home_reading_history() end},
    } end
    if key=="history" then return {
        {icon="◷",label="阅读历史",detail="最近阅读记录",callback=function() self:show_home_reading_history() end},
        {icon="▦",label="全部书籍",detail="打开完整书架",callback=function() self:show_home_all_books() end},
    } end
    if key=="file_manager" then return {
        {icon="▤",label="KOReader 文件管理",detail="打开原生文件浏览器",callback=function() self:_home_close_to_native(true) end},
        {icon="▦",label="本地书库",detail="查看觅阅本地书籍",callback=function() self:show_home_local_library() end},
    } end
    if key=="screenshot" then return {
        {icon="▣",label="开始截图",detail="进入截图模式",callback=function() ScreenshotMode.start(self,anchor) end},
        {icon="▤",label="全屏刷新",detail="清除残影",callback=function() self:_home_full_refresh() end},
    } end
    return {}
end

function Plugin:_show_home_action_manage_popup(key,label,anchor)
    local can_left=self:_home_visible_action_neighbor(key,-1)~=nil
    local can_right=self:_home_visible_action_neighbor(key,1)~=nil
    local actions=self:_home_action_function_actions(key,anchor)
    local manage={
        {label="← 左移",enabled=can_left,callback=function() self:_home_move_visible_action(key,-1) end},
        {label="更换",callback=function() self:_show_home_action_replace_popup(key,anchor) end},
        {label="隐藏",callback=function() self:_home_toggle_group_item("action",key) end},
        {label="右移 →",enabled=can_right,callback=function() self:_home_move_visible_action(key,1) end},
    }
    return ActionSheet.show{
        cache_key="home_action_manage_"..tostring(key),
        anchor=anchor,preferred_direction="below",width_ratio=.80,
        title=tostring(label or HOME_ACTION_LABELS[key] or "快捷项"),subtitle="点击使用主功能 · 长按扩展与管理",
        actions=actions,wide_last=(#actions%2==1),footer_actions=manage,
    }
end

function Plugin:_home_book_delete_state(book)
    local book_id=tostring(book and (book.bookId or book.book_id) or "")
    if book_id=="" then return nil end
    self.store:reload()
    self.store:prune_missing_files()
    local stored=self.store:book(book_id)
    if not stored then return {book_id=book_id,variants={},chapter_count=0,has_partial=false} end
    local kinds={"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}
    local variants={}
    local preferred=self:_preferred_record(book_id)
    local preferred_file=preferred and tostring(preferred.file or "") or ""
    local current_kind=nil
    for _,kind in ipairs(kinds) do
        local record=stored.variants and stored.variants[kind]
        if record and record.file and U.file_exists(record.file) then
            local row={kind=kind,label=self:_variant_label(kind),record=record}
            variants[#variants+1]=row
            if preferred_file~="" and tostring(record.file)==preferred_file then current_kind=kind end
        end
    end
    if not current_kind and variants[1] then current_kind=variants[1].kind end
    local _,chapter_count=self:_download_book_labels(U.merge(stored,{book_id=book_id}))
    return {
        book_id=book_id,
        stored=stored,
        variants=variants,
        current_kind=current_kind,
        chapter_count=tonumber(chapter_count) or 0,
        has_partial=self.store:book_has_partial_cache(book_id)==true,
    }
end

function Plugin:_show_home_delete_book_popup(book,anchor)
    local state=self:_home_book_delete_state(book)
    if not state then self:info("这本书没有可删除的本地记录") return false end
    local current_label="未识别"
    for _,row in ipairs(state.variants or {}) do
        if row.kind==state.current_kind then current_label=row.label; break end
    end
    local installed={}
    for _,row in ipairs(state.variants or {}) do installed[#installed+1]=row.label end
    if state.chapter_count>0 then installed[#installed+1]="单章文件" end
    if state.has_partial then installed[#installed+1]="未完成缓存" end
    if #installed==0 then self:info("这本书没有可删除的本地版本") return false end
    local subtitle="ⓘ 当前版本："..current_label
    if #installed>1 then subtitle=subtitle.." · 本地共 "..tostring(#installed).." 类文件" end
    local actions={}
    if state.current_kind then
        actions[#actions+1]={
            icon="⌫",label="删除当前版本",detail=current_label.." · 仅删除这个 EPUB",danger=true,
            callback=function() self:_confirm_delete_variant(state.book_id,state.current_kind,book.title) end,
        }
    end
    if #installed>1 or not state.current_kind then
        actions[#actions+1]={
            icon="!",label="删除全部本地版本",detail="同时清理本机评论、记录与缓存",danger=true,
            callback=function() self:_confirm_delete_book_downloads(state.book_id,book.title) end,
        }
    end
    actions[#actions+1]={
        icon="i",label="查看已下载版本",detail=table.concat(installed,"、"),
        callback=function() self:downloaded_book_menu(state.book_id) end,
    }
    ActionSheet.show{
        anchor=anchor,
        preferred_direction="above",
        width_ratio=.66,
        title="删除书籍 · "..tostring(book.title or "书籍"),
        subtitle=subtitle,
        actions=actions,wide_last=(#actions%2==1),
        footer_action={label="取消",callback=function() end},
    }
    return true
end

function Plugin:_show_home_local_book_more(book,anchor)
    ActionSheet.show{
        anchor=anchor,preferred_direction="above",width_ratio=.62,
        title=tostring(book.title or "本地书籍"),subtitle="更多书籍操作",
        actions={
            {icon="▤",label="在文件管理中查看",detail="打开 KOReader 文件浏览器",callback=function() self:_home_close_to_native(true) end},
            {icon="−",label="从觅阅书架隐藏",detail="保留本地文件",callback=function() self:_home_hide_local_book(book) end},
        },
        footer_action={label="返回书籍操作",callback=function() self:_home_hold_book(book,anchor) end},
    }
end

function Plugin:_show_home_remote_book_more(book,anchor)
    local target=U.copy(book or {})
    local id=tostring(target.bookId or target.book_id or "")
    local actions={
        {icon="⇩",label="生成／更新书籍",detail="重新生成或更新 EPUB",callback=function() self:choose_download(target,nil,false) end},
        {icon="▤",label="按章节下载",detail="选择章节后生成",callback=function() self:chapters(target) end},
    }
    if id~="" and self:_has_range_variant(id) then
        actions[#actions+1]={icon="＋",label="扩展已有章节版",detail="继续增加章节范围",callback=function()
            self:_show_home_bubble_menu("扩展已有章节版",self:range_extend_menu(target),{anchor=anchor,preferred_direction="above",page_size=7})
        end}
    end
    if id~="" and (self:_book_has_cache(id) or self.store:book_has_partial_cache(id)) then
        actions[#actions+1]={icon="▣",label="管理本书文件",detail="查看和管理已生成文件",callback=function() self:downloaded_book_menu(id) end}
    end
    actions[#actions+1]={icon="i",label="书籍详情",detail="简介、作者与出版信息",callback=function() self:book_details(target) end}
    return ActionSheet.show{
        anchor=anchor,preferred_direction="above",width_ratio=.66,
        title=tostring(target.title or "书籍"),subtitle="更多书籍操作",
        actions=actions,wide_last=(#actions%2==1),
        footer_action={label="返回书籍操作",callback=function() self:_home_hold_book(target,anchor) end},
    }
end

function Plugin:_home_hold_book(book,anchor)
    if not book then return end
    if book.local_folder==true or book.kind=="folder" then
        local actions={
            {icon="▤",label="在文件管理中查看",detail="打开 KOReader 文件浏览器",callback=function() self:_home_close_to_native(true) end},
        }
        if not book.local_parent then
            actions[#actions+1]={icon="refresh",label="刷新这一层",detail="只更新当前文件夹",callback=function()
                local path=LocalLibrary.normalize(book.folder_path or book.path)
                self:_home_refresh_local_directory(path,function()
                    local context=self:_home_local_inline_context()
                    if HomeView.is_shown() and not context.picker and LocalLibrary.normalize(context.path)==path then
                        self:_home_apply_local_inline_section(true)
                    end
                end,true)
            end}
        end
        ActionSheet.show{
            anchor=anchor,preferred_direction="above",width_ratio=.62,
            title=tostring(book.title or "文件夹"),subtitle=book.local_parent and "本地书库导航" or "本地书库文件夹",
            actions=actions,wide_last=(#actions%2==1),
        }
        return
    end
    local id=tostring(book.bookId or book.book_id or "")
    if Protocol.is_mp_account(id) then
        local target=U.copy(book)
        ActionSheet.show{
            anchor=anchor,
            preferred_direction="above",
            width_ratio=.62,
            title=tostring(target.title or "公众号"),
            subtitle=U.trim(tostring(target.author or ""))~="" and tostring(target.author) or "公众号内容",
            actions={
                {icon="i",label="查看信息",detail="作者与简介",callback=function()
                    local lines={tostring(target.title or "公众号")}
                    if U.trim(tostring(target.author or ""))~="" then lines[#lines+1]="作者："..tostring(target.author) end
                    if U.trim(tostring(target.description or target.intro or ""))~="" then lines[#lines+1]="\n"..tostring(target.description or target.intro) end
                    self:info(table.concat(lines,"\n"))
                end},
                {icon="↻",label="刷新并打开",detail="更新文章列表后打开",callback=function()
                    self:_refresh_shelf_async(function() self:mp_account(target) end,false)
                end},
                {icon="⇩",label="下载管理",detail="查看文章下载任务",callback=function() self:show_downloads() end},
            },
            wide_last=true,
        }
        return
    end
    if book.source=="local" or book.local_file==true then
        ActionSheet.show{
            anchor=anchor,
            preferred_direction="above",
            width_ratio=.66,
            title=tostring(book.title or "本地书籍"),
            subtitle=U.trim(tostring(book.author or ""))~="" and tostring(book.author) or "本地书籍",
            actions={
                {icon="i",label="查看详情",detail="文件、进度和图书信息",callback=function() self:_home_local_book_details(book) end},
                {icon="↻",label="更新书籍信息",detail="重新提取并尝试网络补全",callback=function() self:_home_refresh_one_book_metadata(book,true) end},
                {icon="!",label="删除本地文件",detail="删除后无法通过觅阅恢复",danger=true,callback=function() self:_home_delete_local_book(book,anchor) end},
            },
            wide_last=true,
            footer_action={label="更多书籍操作",callback=function() self:_show_home_local_book_more(book,anchor) end},
        }
        return
    end

    local target=U.copy(book)
    self:_home_attach_local_record(target)
    local record=id~="" and self:_preferred_record(id) or nil
    local available=record and record.file and U.file_exists(record.file)
    local primary_actions={
        {icon="i",label="查看详情",detail="书籍简介和出版信息",callback=function() self:book_details(target) end},
        {icon="↻",label="更新书籍信息",detail="微信读书详情与网络补全",callback=function() self:_home_refresh_one_book_metadata(target,true) end},
    }
    if available then
        primary_actions[#primary_actions+1]={icon="✚",label="检查这本书",detail="检查正文、目录和生成记录",callback=function() self:_home_repair_book(target) end}
        primary_actions[#primary_actions+1]={icon="⌫",label="删除书籍",detail="选择删除当前或全部版本",danger=true,callback=function()
            self:_show_home_delete_book_popup(target,anchor)
        end}
    else
        primary_actions[#primary_actions+1]={icon="⇩",label="下载书籍",detail="加入下载任务",callback=function() self:choose_download(target,nil,false) end}
    end
    ActionSheet.show{
        anchor=anchor,
        preferred_direction="above",
        width_ratio=.66,
        title=tostring(target.title or "书籍"),
        subtitle=U.trim(tostring(target.author or ""))~="" and tostring(target.author)
            or (available and "已下载" or "尚未下载"),
        actions=primary_actions,wide_last=(#primary_actions%2==1),
        footer_action={label="更多书籍操作",callback=function() self:_show_home_remote_book_more(target,anchor) end},
    }
end

function Plugin:_home_action_entries()
    local home=self:_home_preferences()
    local download_state=self:_download_state()
    local queue=self.store:download_queue()
    local download_badge=nil
    if download_state.status=="failed" then download_badge="!"
    elseif download_state.status=="active" then download_badge=tostring(self:_download_percent(download_state)).."%"
    elseif #queue>0 then download_badge=tostring(#queue) end

    local definitions={
        refresh={icon="↻",icon_key="refresh",label="更新",callback=function()
            -- Single tap means "update what I am looking at". E-ink full refresh
            -- remains available from the long-press menu and quick panel.
            self:_home_manual_refresh()
        end},
        search={icon="⌕",icon_key="search",label="搜索",callback=function(anchor) self:_show_home_search_popup(anchor) end},
        downloads={icon="⇩",icon_key="download",label="下载",badge=download_badge,callback=function(anchor) self:_show_home_download_popup(anchor) end},
        miuread_settings={icon="⚙",icon_key="settings",label="觅阅设置",callback=function(anchor) self:_show_home_settings_popup(anchor) end},
        all_books={icon="▦",label="全部书籍",callback=function() self:show_home_all_books() end},
        history={icon="◷",label="阅读历史",callback=function() self:show_home_reading_history() end},
        file_manager={icon="▤",label="文件管理",callback=function(anchor) self:_show_home_file_manager_popup(anchor) end},
        screenshot={icon="▣",label="截图",callback=function(anchor) ScreenshotMode.start(self,anchor) end},
    }
    if Device:canSuspend() then definitions.sleep={icon="◐",icon_key="sleep",label="休眠",callback=function() self:_home_sleep() end} end
    for key,entry in pairs(definitions) do
        local item_key=key; local item_label=entry.label
        entry.hold_callback=function(anchor) self:_show_home_action_manage_popup(item_key,item_label,anchor) end
    end
    local entries,used={},{}
    for _,key in ipairs(home.action_order or HOME_ACTION_ITEM_ORDER) do
        if home.action_items[key]==true and definitions[key] and not used[key] then
            used[key]=true; entries[#entries+1]=definitions[key]
            if #entries>=6 then break end
        end
    end
    return entries
end

function Plugin:_home_download_notice()
    local state=self:_download_state()
    local queue=self.store:download_queue()
    local notice
    if state.status=="active" then
        local percent=self:_download_percent(state)
        notice={
            title="正在下载《"..tostring(state.title or "书籍").."》",
            detail="已完成 "..tostring(percent).."%",
            progress=percent/100,
        }
    elseif state.status=="failed" then
        notice={
            title="有一项下载未完成",
            detail=state.auth_required==true and "账号需要重新登录" or "点击查看并继续下载",
            important=true,
        }
    elseif state.status=="annotation_pending" then
        notice={
            title="正文已下载完成",
            detail="划线与想法待补全，点击查看",
            important=true,
        }
    elseif state.status=="interrupted" or state.status=="pending_install" then
        notice={
            title="下载等待继续",
            detail=self:_download_status_label():gsub("^后台下载%s*[·：]?%s*",""),
            important=true,
        }
    elseif #queue>0 then
        notice={title=tostring(#queue).." 项等待下载",detail="点击查看下载队列"}
    end
    if notice then
        notice.on_tap=function() self:_home_leave_and_run("downloads",function() self:show_downloads() end) end
    end
    return notice
end

function Plugin:_home_library_sections(account_count,generated_count,local_count,mp_count)
    return {
        {title="书架",detail="账号中的全部书籍",count=account_count,on_tap=function()
            self:_home_leave_and_run("account shelf",function() self:show_shelf(false,false,"account") end)
        end},
        {title="已下载",detail="已保存到设备",count=generated_count,on_tap=function()
            self:_home_leave_and_run("generated shelf",function() self:show_shelf(false,false,"generated") end)
        end},
        {title="本地书籍",detail="KOReader 普通文件",count=local_count,on_tap=function()
            self:_home_leave_and_run("local shelf",function() self:show_home_local_library() end)
        end},
        {title="公众号",detail="公众号与文章",count=mp_count,on_tap=function()
            self:_home_leave_and_run("mp shelf",function() self:show_mp_shelf(false) end)
        end},
    }
end

function Plugin:_home_alerts()
    local alerts={}
    local health=self:_auth_health(); self:_recompute_auth_health(health)
    local auth=self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    local previously_logged_in=U.trim(tostring(account.name or ""))~="" or (tonumber(account.logged_at) or 0)>0
    if not self:logged_in() and previously_logged_in then
        alerts[#alerts+1]={title="微信读书账号需要重新登录",detail="点击重新扫码；已下载书籍和本地阅读记录不会删除",important=true,on_tap=function() self:_home_leave_and_run("login",function() self.auth_flow:start() end) end}
    elseif health.state=="partial" then
        alerts[#alerts+1]={title="账号部分功能需要处理",detail="点击查看状态；必要时重新扫码即可恢复",important=true,on_tap=function() self:_home_leave_and_run("account status",function() self:show_account_status() end) end}
    end
    return alerts
end

function Plugin:_home_stop_background(reason)
    self:_flush_home_preferences()
    self._home_resume_generation=(tonumber(self._home_resume_generation) or 0)+1
    self:_home_unschedule_task("_home_resume_background_task")
    self:_home_unschedule_task("_home_manual_metadata_retry_task")
    self._home_pending_network_metadata_key=nil
    self._home_resume_barrier=false
    self._home_suspended=false
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    self._home_refreshing=false
    self._home_cover_inflight={}
    if self.home_async then self.home_async:cancel(reason or "home hidden") end
    self:_cancel_home_directory_request(reason or "home hidden")
    if self.home_metadata_async then self.home_metadata_async:cancel(reason or "home hidden") end
    if self.home_cover_async then self.home_cover_async:cancel(reason or "home hidden") end
    if self.cover_render_async then self.cover_render_async:cancel(reason or "home hidden") end
end

function Plugin:_home_merge_directory_snapshot(snapshot,old_snapshot)
    snapshot=type(snapshot)=="table" and snapshot or {folders={},books={}}
    old_snapshot=type(old_snapshot)=="table" and old_snapshot or {}
    local old_by_file={}
    for _,row in ipairs(old_snapshot.books or {}) do old_by_file[LocalLibrary.normalize(row.file)]=row end
    local legacy=self:_home_local_cache()
    for _,row in ipairs(legacy.books or {}) do
        local path=LocalLibrary.normalize(row.file)
        if old_by_file[path]==nil then old_by_file[path]=row end
    end
    for _,row in ipairs(snapshot.books or {}) do
        local old=old_by_file[LocalLibrary.normalize(row.file)]
        if old and tonumber(old.modified_at or 0)==tonumber(row.modified_at or 0) then LocalMetadata.merge(row,old) end
        row.local_file=true; row.source="local"; row.status_text=self:_home_status_text(row,true)
    end
    return snapshot
end

function Plugin:_home_store_directory_snapshot(path,snapshot)
    path=LocalLibrary.normalize(path)
    local cache=self:_home_local_tree_cache()
    snapshot=self:_home_merge_directory_snapshot(snapshot,cache.dirs[path])
    cache.dirs[path]=snapshot
    cache.updated_at=os.time()
    self.store:set("home_local_tree_index",cache)
    return snapshot
end

function Plugin:_home_scan_local(force)
    local home=self:_home_preferences()
    local mode="auto" -- compatibility label for existing logging
    if force~=true and home.local_auto_update~=true then return false end
    if force~=true then
        local cached=self:_home_local_cache()
        local scanned_at=tonumber(cached and cached.scanned_at or 0) or 0
        local local_ttl=self:_lightweight_enabled()
            and (tonumber(Config.LIGHTWEIGHT_HOME_LOCAL_TTL) or 60*60)
            or HOME_LOCAL_CACHE_TTL
        if scanned_at>0 and os.time()-scanned_at<local_ttl then return false end
    end
    if self:_home_background_blocked() or self:_active_reader_ui() then return false end
    local roots=self:_home_local_roots(true)
    if #roots==0 or not self.home_async or self.home_async:busy() or not self.home_async:available() then return false end
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    local generation=self._home_scan_generation
    self._home_refreshing=true
    local root_payload=U.copy(roots)
    local recursive=true
    if not recursive then
        local context=self:_home_local_inline_context()
        local seen={}
        for _,item in ipairs(root_payload) do seen[LocalLibrary.normalize(item.path)]=true end
        if not context.picker and context.path~="" and not seen[LocalLibrary.normalize(context.path)] then
            root_payload[#root_payload+1]={path=context.path,name=LocalLibrary.basename(context.path),enabled=true,readonly=true}
        end
    end
    local started,err=self.home_async:run(recursive and "home-local-library" or "home-local-roots",function()
        local ok_ffi,ffi=pcall(require,"ffi")
        if ok_ffi and ffi then
            pcall(ffi.cdef,"int setpriority(int which, int who, int prio);")
            pcall(function() ffi.C.setpriority(0,0,recursive and 14 or 12) end)
        end
        local Library=require("miuread.local_library")
        if recursive then
            local merged={books={},roots={},scanned_at=os.time(),truncated=false}
            for _,root in ipairs(root_payload) do
                local result=Library.scan(root.path,{limit=1000,max_depth=5,include_dictionaries=false})
                merged.roots[#merged.roots+1]={path=root.path,name=root.name,truncated=result.truncated==true}
                for _,book in ipairs(result.books or {}) do
                    book.library_root=root.path
                    merged.books[#merged.books+1]=book
                    if #merged.books>=1000 then merged.truncated=true; break end
                end
                if #merged.books>=1000 then break end
            end
            table.sort(merged.books,function(a,b)
                local am,bm=tonumber(a.modified_at) or 0,tonumber(b.modified_at) or 0
                if am~=bm then return am>bm end
                return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
            end)
            return merged
        end
        local result={}
        for _,root in ipairs(root_payload) do
            result[root.path]=Library.list_directory(root.path,{limit=1600,include_cover=false,include_dictionaries=false})
        end
        return result
    end,function(result)
        if generation~=self._home_scan_generation then return end
        self._home_refreshing=false
        if not result or result.ok~=true or type(result.value)~="table" then
            logger.warn("[MiuRead][Home] local scan failed",tostring(result and result.error or "unknown"))
            return
        end
        if recursive then
            local previous=self:_home_local_cache()
            local previous_by_file={}
            for _,book in ipairs(previous.books or {}) do previous_by_file[LocalLibrary.normalize(book.file)]=book end
            for _,book in ipairs(result.value.books or {}) do
                local old=previous_by_file[LocalLibrary.normalize(book.file)]
                if old and tonumber(old.modified_at or 0)==tonumber(book.modified_at or 0) then LocalMetadata.merge(book,old) end
                book.local_file=true; book.source="local"; book.status_text=self:_home_status_text(book,true)
            end
            self.store:set("home_local_index",result.value)
            logger.info("[MiuRead][Home] local library indexed",
                "mode=",mode,"books=",tostring(#(result.value.books or {})),
                "truncated=",tostring(result.value.truncated==true))
        else
            for path,snapshot in pairs(result.value) do self:_home_store_directory_snapshot(path,snapshot) end
            logger.info("[MiuRead][Home] local folders refreshed","count=",tostring(#root_payload),"recursive=false")
        end
        if HomeView.is_shown() then self:_notify_home_data_changed("content") end
    end,recursive and 240 or 120)
    if not started then
        self._home_refreshing=false
        logger.warn("[MiuRead][Home] local scan not started",tostring(err))
        return false
    end
    return true
end

function Plugin:_cancel_local_browser_fallback()
    local task=self._local_browser_fallback_task
    if task then UIManager:unschedule(task) end
    self._local_browser_fallback_task=nil
    local scanner=self._local_browser_fallback_scanner
    self._local_browser_fallback_scanner=nil
    if scanner and scanner.cancel then pcall(scanner.cancel,scanner) end
end

function Plugin:_cancel_home_directory_request(reason)
    self._home_directory_generation=(tonumber(self._home_directory_generation) or 0)+1
    if self.local_browser_async then self.local_browser_async:cancel(reason or "local folder request cancelled") end
    self:_cancel_local_browser_fallback()
    self._home_directory_active_path=nil
    self._home_directory_request_owner=nil
end

function Plugin:_home_refresh_local_directory(path,callback,force,owner)
    path=LocalLibrary.normalize(path)
    local cache=self:_home_local_tree_cache()
    local cached=cache.dirs[path]
    if force~=true and type(cached)=="table" then
        if callback then callback(cached,false) end
        return true
    end
    if path=="" or lfs.attributes(path,"mode")~="directory" then
        if callback then callback({path=path,folders={},books={},error="文件夹不存在"},false) end
        return false
    end
    local function failure_snapshot(message)
        if type(cached)=="table" and not cached.error then return cached end
        return self:_home_store_directory_snapshot(path,{
            path=path,folders={},books={},scanned_at=os.time(),error=tostring(message or "无法读取文件夹"),
        })
    end

    -- A new navigation request owns the directory slot. Cancelling the old
    -- worker and generation prevents a late result from replacing the folder
    -- the user is currently viewing.
    self:_cancel_home_directory_request("new local folder request")
    local generation=self._home_directory_generation
    self._home_directory_active_path=path
    self._home_directory_request_owner=owner

    local function complete(snapshot,scanned)
        if generation~=self._home_directory_generation then return false end
        self:_cancel_local_browser_fallback()
        self._home_directory_active_path=nil
        self._home_directory_request_owner=nil
        if callback then callback(snapshot,scanned) end
        return true
    end

    local function start_incremental(reason)
        logger.info("[MiuRead][LocalBrowser] using incremental reader",path,tostring(reason or "worker unavailable"))
        local scanner=LocalLibrary.new_directory_scan(path,{
            limit=1600,include_cover=false,include_dictionaries=false,
        })
        self._local_browser_fallback_scanner=scanner
        local task
        task=function()
            if self._local_browser_fallback_task~=task or generation~=self._home_directory_generation then
                if scanner and scanner.cancel then pcall(scanner.cancel,scanner) end
                return
            end
            local ok,done=pcall(scanner.step,scanner,32)
            if not ok then
                self._local_browser_fallback_task=nil
                self._local_browser_fallback_scanner=nil
                complete(failure_snapshot(tostring(done or "无法读取文件夹")),true)
                return
            end
            if done then
                self._local_browser_fallback_task=nil
                self._local_browser_fallback_scanner=nil
                local good,snapshot=pcall(scanner.snapshot,scanner)
                if not good or type(snapshot)~="table" then
                    complete(failure_snapshot(tostring(snapshot or "无法读取文件夹")),true)
                elseif snapshot.error then
                    complete(failure_snapshot(snapshot.error),true)
                else
                    complete(self:_home_store_directory_snapshot(path,snapshot),true)
                end
                return
            end
            UIManager:scheduleIn(.02,task)
        end
        self._local_browser_fallback_task=task
        UIManager:scheduleIn(0,task)
        return true
    end

    local worker=self.local_browser_async
    if not worker or not worker:available() then
        return start_incremental("background worker unavailable")
    end
    local started,err=worker:run("local-folder",function()
        local ok_ffi,ffi=pcall(require,"ffi")
        if ok_ffi and ffi then
            pcall(ffi.cdef,"int setpriority(int which, int who, int prio);")
            pcall(function() ffi.C.setpriority(0,0,10) end)
        end
        local Library=require("miuread.local_library")
        return Library.list_directory(path,{limit=1600,include_cover=false,include_dictionaries=false})
    end,function(result)
        if generation~=self._home_directory_generation then return end
        if result and result.ok==true and type(result.value)=="table" then
            complete(self:_home_store_directory_snapshot(path,result.value),true)
        else
            complete(failure_snapshot(tostring(result and result.error or "无法读取文件夹")),true)
        end
    end,90)
    if started then return true end
    logger.warn("[MiuRead][LocalBrowser] background read not started",tostring(err))
    return start_incremental(tostring(err or "worker did not start"))
end

function Plugin:_home_local_metadata_dir()
    local path=self.store.covers_dir.."/local"
    U.mkdir(path)
    return path
end

function Plugin:_home_reset_local_metadata()
    local dir=self:_home_local_metadata_dir()
    U.remove_tree(dir)
    U.mkdir(dir)
    local prefix=tostring(dir):gsub("\\","/"):gsub("/+","/").."/"
    local function clear_book(book)
        local changed=false
        local cover=tostring(book.cover_path or ""):gsub("\\","/"):gsub("/+","/")
        if cover:sub(1,#prefix)==prefix then book.cover_path=nil; changed=true end
        for _,key in ipairs({"metadata_source","metadata_mtime","metadata_checked_at","metadata_complete"}) do
            if book[key]~=nil then book[key]=nil; changed=true end
        end
        return changed
    end
    local cache=self:_home_local_cache()
    local changed=false
    for _,book in ipairs(cache.books or {}) do if clear_book(book) then changed=true end end
    if changed then self.store:set("home_local_index",cache) end

    local tree=self:_home_local_tree_cache()
    local tree_changed=false
    for _,snapshot in pairs(tree.dirs or {}) do
        for _,book in ipairs(type(snapshot)=="table" and snapshot.books or {}) do
            if clear_book(book) then tree_changed=true end
        end
    end
    if tree_changed then tree.updated_at=os.time(); self.store:set("home_local_tree_index",tree) end
end

function Plugin:_home_update_local_cache(filepath,metadata)
    filepath=LocalLibrary.normalize(filepath)
    local cache=self:_home_local_cache()
    local changed=false
    for _,row in ipairs(cache.books or {}) do
        if LocalLibrary.normalize(row.file)==filepath then
            if LocalMetadata.merge(row,metadata) then changed=true end
            row.status_text=self:_home_status_text(row,true)
            break
        end
    end
    if changed then
        cache.scanned_at=tonumber(cache.scanned_at) or os.time()
        self.store:set("home_local_index",cache)
    end
    local tree=self:_home_local_tree_cache()
    local tree_changed=false
    for _,snapshot in pairs(tree.dirs or {}) do
        for _,row in ipairs(type(snapshot)=="table" and snapshot.books or {}) do
            if LocalLibrary.normalize(row.file)==filepath then
                if LocalMetadata.merge(row,metadata) then tree_changed=true end
                row.status_text=self:_home_status_text(row,true)
            end
        end
    end
    if tree_changed then tree.updated_at=os.time(); self.store:set("home_local_tree_index",tree) end
    return changed or tree_changed
end

function Plugin:_home_update_miuread_metadata(filepath,metadata)
    local book,record=self.store:identify_file(filepath,true)
    if type(book)~="table" then return false end
    local changed=LocalMetadata.merge(book,metadata)
    if type(record)=="table" and LocalMetadata.merge(record,metadata) then changed=true end
    local id=tostring(book.book_id or (record and record.book_id) or "")
    if changed and id~="" then self.store:save_book(id,book) end
    return changed
end



function Plugin:_home_network_metadata_key(book)
    return HomeNetworkMetadata.metadata_key(book)
end

function Plugin:_home_network_metadata_cache()
    local cache=self.store:get("home_network_metadata",{version=1,rows={}})
    cache=type(cache)=="table" and cache or {version=1,rows={}}
    cache.rows=type(cache.rows)=="table" and cache.rows or {}
    return cache
end

local home_network_patch_has_data = HomeNetworkMetadata.patch_has_data
local home_network_patch_field_count = HomeNetworkMetadata.patch_field_count
local home_network_missing_fields = HomeNetworkMetadata.missing_fields

function Plugin:_home_merge_network_patch(book,patch)
    return HomeNetworkMetadata.merge_patch(book,patch)
end

function Plugin:_home_apply_cached_network_metadata(book)
    local key=self:_home_network_metadata_key(book)
    if key=="" then return false end
    local row=self:_home_network_metadata_cache().rows[key]
    if type(row)~="table" or type(row.patch)~="table" then return false end
    return self:_home_merge_network_patch(book,row.patch)
end

function Plugin:_home_save_network_metadata(book,patch,completed)
    local key=self:_home_network_metadata_key(book)
    if key=="" then return false end
    local cache=self:_home_network_metadata_cache()
    cache.rows[key]={
        checked_at=os.time(),
        completed=completed==true,
        patch=type(patch)=="table" and patch or {},
    }
    local count=0
    local ordered={}
    for cache_key,row in pairs(cache.rows) do
        ordered[#ordered+1]={key=cache_key,at=tonumber(type(row)=="table" and row.checked_at or 0) or 0}
    end
    table.sort(ordered,function(a,b) return a.at>b.at end)
    for index,row in ipairs(ordered) do
        count=index
        if index>120 then cache.rows[row.key]=nil end
    end
    self.store:set("home_network_metadata",cache)
    return count>0
end

function Plugin:_home_queue_manual_network_metadata(book,force,silent,on_done)
    if self._home_manual_metadata_retry_task then
        logger.info("[MiuRead][HomeMetadata] manual request already queued",
            "book=",tostring(book and (book.bookId or book.book_id) or ""))
        return false
    end
    local deadline=monotonic_wall_time()+12
    local task
    task=function()
        if self._home_manual_metadata_retry_task~=task then return end
        if not HomeView.is_shown() or self:_active_reader_ui() then
            self._home_manual_metadata_retry_task=nil
            logger.info("[MiuRead][HomeMetadata] manual queue cancelled", "reason=home_hidden")
            if on_done then on_done(false,nil,{error="home_hidden"}) end
            return
        end
        if not self:is_online() then
            self._home_manual_metadata_retry_task=nil
            logger.info("[MiuRead][HomeMetadata] manual queue cancelled", "reason=offline")
            if on_done then on_done(false,nil,{error="offline"}) end
            return
        end
        local blocked=self:_home_background_blocked()
        local busy=self.home_metadata_async and self.home_metadata_async:busy()
        if blocked or busy then
            if monotonic_wall_time()<deadline then
                UIManager:scheduleIn(.25,task)
                return
            end
            self._home_manual_metadata_retry_task=nil
            logger.warn("[MiuRead][HomeMetadata] manual queue timed out",
                "book=",tostring(book and (book.bookId or book.book_id) or ""),
                "blocked=",tostring(blocked),"busy=",tostring(busy))
            if on_done then on_done(false,nil,{error="worker_busy_timeout"}) end
            return
        end
        self._home_manual_metadata_retry_task=nil
        local started=self:_home_schedule_network_metadata(book,force,silent,on_done,true)
        if not started and on_done then on_done(false,nil,{error="retry_start_failed"}) end
    end
    self._home_manual_metadata_retry_task=task
    UIManager:scheduleIn(.18,task)
    logger.info("[MiuRead][HomeMetadata] manual request queued",
        "book=",tostring(book and (book.bookId or book.book_id) or ""))
    return true
end

function Plugin:_home_schedule_network_metadata(book,force,silent,on_done,explicit)
    explicit=explicit==true
    if type(book)~="table" or not HomeView.is_shown() or self:_active_reader_ui() then return false end
    if explicit then
        -- A user-requested metadata refresh must not be rejected by the quiet
        -- window created by that very tap. It still yields to real lifecycle
        -- transitions/suspend and stays on the background worker.
        if self:_home_background_blocked() then
            return self:_home_queue_manual_network_metadata(book,force,silent,on_done)
        end
    elseif self:_home_ui_busy() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.metadata=true
        local pending_key=self:_home_network_metadata_key(book)
        if pending_key~="" then self._home_pending_network_metadata_key=pending_key end
        return false
    end
    local home=self:_home_preferences()
    if home.network_metadata==false and force~=true then return false end
    local key=self:_home_network_metadata_key(book)
    if key=="" then return false end
    local cache=self:_home_network_metadata_cache()
    local cached=cache.rows[key]
    local cached_completed=type(cached)=="table" and (cached.completed==true
        or home_network_patch_has_data(cached.patch))
    if force~=true and cached_completed then
        if type(cached.patch)=="table" and self:_home_merge_network_patch(book,cached.patch) then
            if self._home_hero and self:_home_network_metadata_key(self._home_hero)==key then
                HomeView.update_hero(self._home_hero)
            end
        end
        return false
    end
    if not self:is_online() or not self.home_metadata_async or not self.home_metadata_async:available() then return false end
    if self.home_metadata_async:busy() then
        if explicit then return self:_home_queue_manual_network_metadata(book,force,silent,on_done) end
        return false
    end
    local candidate=U.copy(book)
    local id=tostring(candidate.bookId or candidate.book_id or "")
    if self._home_pending_network_metadata_key==key then self._home_pending_network_metadata_key=nil end
    if explicit then
        logger.info("[MiuRead][HomeMetadata] manual requested",
            "book=",id~="" and id or key)
    end
    local started,err=self.home_metadata_async:run("home-network-metadata",function()
        local patch={}
        if id~="" and not Protocol.is_mp_account(id) then
            local ok,detail=pcall(self.api.book,self.api,id)
            if ok and type(detail)=="table" then
                local info=type(detail.bookInfo)=="table" and detail.bookInfo
                    or (type(detail.book)=="table" and detail.book or detail)
                patch.title=info.title or detail.title
                patch.author=info.author or detail.author
                patch.description=info.intro or info.description or info.summary
                    or detail.intro or detail.description or detail.summary
                patch.category=info.category or detail.category
                patch.publisher=info.publisher or detail.publisher
                patch.isbn=info.isbn or info.isbn13 or info.isbn10 or detail.isbn
                patch.published_date=info.publishTime or info.publishedDate or detail.publishTime
                patch.metadata_source="weread_book_info"
            end
        end
        local merged=U.copy(candidate)
        for k,v in pairs(patch) do if v~=nil and v~="" then merged[k]=v end end
        local needs_external = U.trim(tostring(patch.description or merged.description or merged.intro or merged.summary or ""))==""
            or U.trim(tostring(patch.category or merged.category or ""))==""
            or U.trim(tostring(patch.publisher or merged.publisher or ""))==""
            or U.trim(tostring(patch.published_date or merged.published_date or ""))==""
            or U.trim(tostring(patch.isbn or merged.isbn or ""))==""
        if needs_external then
            local external=NetworkMetadata.fetch(self.http,merged)
            if type(external)=="table" then
                for k,v in pairs(external) do if (patch[k]==nil or patch[k]=="") and v~=nil and v~="" then patch[k]=v end end
            end
        end
        return patch
    end,function(result)
        if not result or result.ok~=true then
            logger.warn("[MiuRead][HomeMetadata] network metadata unavailable",
                "book=",id~="" and id or key,
                "error=",tostring(result and result.error or "unknown"))
            if not cached_completed then self:_home_save_network_metadata(candidate,{},false) end
            if force==true and silent~=true then self:toast("网络图书信息更新失败，请稍后重试",2) end
            if on_done then on_done(false,nil,{error=tostring(result and result.error or "unknown")}) end
            return
        end
        local patch=type(result.value)=="table" and result.value or {}
        local saved_patch={}
        if type(cached)=="table" and type(cached.patch)=="table" then
            for k,v in pairs(cached.patch) do if v~=nil and v~="" then saved_patch[k]=v end end
        end
        for k,v in pairs(patch) do if v~=nil and v~="" then saved_patch[k]=v end end
        local found=home_network_patch_has_data(saved_patch)
        self:_home_save_network_metadata(candidate,saved_patch,found)
        if self._home_hero and self:_home_network_metadata_key(self._home_hero)==key then
            local changed=self:_home_merge_network_patch(self._home_hero,patch)
            if changed and HomeView.is_shown() then HomeView.update_hero(self._home_hero) end
        end
        local missing=home_network_missing_fields(candidate,saved_patch)
        local detail={
            partial=found and #missing>0,
            complete=found and #missing==0,
            missing=missing,
            fields=home_network_patch_field_count(saved_patch),
            source=tostring(saved_patch.metadata_source or patch.metadata_source or "unknown"),
        }
        logger.info("[MiuRead][HomeMetadata] completed",
            "book=",id~="" and id or key,
            "found=",tostring(found),
            "fields=",tostring(detail.fields),
            "source=",detail.source,
            "missing=",#missing>0 and table.concat(missing,",") or "none")
        if force==true and silent~=true then
            if not found then
                self:toast("暂未找到可补全的网络信息",2)
            elseif #missing>0 then
                self:toast("网络书籍信息已刷新，部分资料暂未找到",2)
            else
                self:toast("当前书籍的网络信息已更新",2)
            end
        end
        if on_done then on_done(found,patch,detail) end
    end,35)
    if not started then
        logger.warn("[MiuRead][HomeMetadata] network metadata worker not started",
            "book=",id~="" and id or key,"error=",tostring(err))
        if explicit and self.home_metadata_async and self.home_metadata_async:busy() then
            return self:_home_queue_manual_network_metadata(book,force,silent,on_done)
        end
    end
    return started==true
end

function Plugin:_home_schedule_local_metadata(books)
    if self._download_runtime~=nil then return false end
    if self:_home_ui_busy() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.metadata=true
        return false
    end
    if not HomeView.is_shown() then return false end
    local lightweight=self:_lightweight_enabled()
    local queue_limit=lightweight and (tonumber(Config.LIGHTWEIGHT_LOCAL_METADATA_QUEUE) or 3) or 6
    local metadata_gap=lightweight and (tonumber(Config.LIGHTWEIGHT_METADATA_GAP) or .75) or .22
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    local generation=self._home_metadata_generation
    local queue,seen={},{}
    for _,book in ipairs(books or {}) do
        local filepath=tostring(book and book.file or "")
        local is_local=book and (book.source=="local" or book.local_file==true)
        if filepath~="" and is_local and not seen[filepath] and LocalMetadata.needs_refresh(book,true) then
            seen[filepath]=true
            queue[#queue+1]={file=filepath,book=book}
            -- Prioritise only what the user can see now. Remaining covers are
            -- picked up on later pages instead of blocking the home screen.
            if #queue>=queue_limit then break end
        end
    end
    if #queue==0 then return false end

    local index=1
    local hero_changed=false
    local changed_book_keys={}
    local cache_dir=self:_home_local_metadata_dir()
    local function finish()
        if generation~=self._home_metadata_generation or not HomeView.is_shown() then return end
        if hero_changed and self._home_hero then
            HomeView.update_hero(self._home_hero)
        end
        for key in pairs(changed_book_keys) do HomeView.update_book(key) end
    end
    local function apply_metadata(item,metadata,err)
        if generation~=self._home_metadata_generation then return end
        if metadata then
            local visible_changed=item.book and LocalMetadata.merge(item.book,metadata) or false
            self:_home_update_local_cache(item.file,metadata)
            if visible_changed then
                local item_id=tostring(item.book and (item.book.bookId or item.book.book_id) or "")
                local item_key=item_id~="" and item_id or ("file:"..tostring(item.file or ""))
                local hero=self._home_hero
                local hero_id=tostring(hero and (hero.bookId or hero.book_id) or "")
                local hero_file=tostring(hero and hero.file or "")
                local is_hero=(item_id~="" and hero_id==item_id)
                    or (item_id=="" and hero_id=="" and hero_file~="" and hero_file==tostring(item.file or ""))
                if is_hero then hero_changed=true
                elseif item_key~="file:" then changed_book_keys[item_key]=true end
            end
        elseif err then
            logger.warn("[MiuRead][Home] local metadata unavailable",tostring(item.file),tostring(err))
        end
        index=index+1
    end
    local function next_book()
        if generation~=self._home_metadata_generation or not HomeView.is_shown() or self:_active_reader_ui() then return end
        if self._download_runtime~=nil then return end
        if self:_home_ui_busy() then UIManager:scheduleIn(math.max(.45,metadata_gap),next_book); return end
        local item=queue[index]
        if not item then finish(); return end
        if self.home_metadata_async and self.home_metadata_async:available() then
            if self.home_metadata_async:busy() then UIManager:scheduleIn(math.max(.35,metadata_gap),next_book); return end
            local filepath=item.file
            local started=self.home_metadata_async:run("home-local-metadata",function()
                local Metadata=require("miuread.local_metadata")
                return Metadata.read(filepath,cache_dir,{open_document=true,use_bim=true})
            end,function(result)
                if generation~=self._home_metadata_generation then return end
                if result and result.ok and type(result.value)=="table" then
                    apply_metadata(item,result.value)
                else
                    apply_metadata(item,nil,result and result.error or "后台提取失败")
                end
                if queue[index] then UIManager:scheduleIn(metadata_gap,next_book) else finish() end
            end,45)
            if not started then UIManager:scheduleIn(.4,next_book) end
            return
        end
        -- Compatibility fallback for devices without subprocess support. Run
        -- only one visible book per tick and stop immediately when reading starts.
        local metadata,err=LocalMetadata.read(item.file,cache_dir,{open_document=true,use_bim=true})
        apply_metadata(item,metadata,err)
        if queue[index] then UIManager:scheduleIn(math.max(.35,metadata_gap),next_book) else finish() end
    end
    UIManager:scheduleIn(lightweight and math.max(1.2,metadata_gap*2) or .8,next_book)
    return true
end

function Plugin:_home_schedule_remote_covers(books)
    if self._download_runtime~=nil then return false end
    if self:_home_ui_busy() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.covers=true
        return false
    end
    local lightweight=self:_lightweight_enabled()
    local queue_limit=lightweight and (tonumber(Config.LIGHTWEIGHT_REMOTE_COVER_QUEUE) or 4) or 10
    local cover_gap=lightweight and (tonumber(Config.LIGHTWEIGHT_COVER_GAP) or .65) or .08
    local derivative_gap=lightweight and (tonumber(Config.LIGHTWEIGHT_DERIVATIVE_GAP) or 1.0) or .75
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    local generation=self._home_cover_generation
    self._home_cover_inflight=type(self._home_cover_inflight)=="table" and self._home_cover_inflight or {}
    local queue,seen={},{}
    for _,book in ipairs(books or {}) do
        local id=tostring(book and (book.bookId or book.book_id) or "")
        if id~="" and not seen[id] and not self._home_cover_inflight[id]
            and book.cover and book.cover~="" and not book.cover_path then
            seen[id]=true
            queue[#queue+1]={bookId=id,cover=book.cover,book=book}
            if #queue>=queue_limit then break end
        end
    end
    if #queue==0 or not self.home_cover_async then return end
    local index,changed_count=1,0
    local changed_sections={}
    local changed_ids={}
    local rendered_books={}
    local hero_changed=false
    local function mark_changed(book_id)
        changed_ids[tostring(book_id or "")]=true
        local hero_id=tostring(self._home_hero and (self._home_hero.bookId or self._home_hero.book_id) or "")
        if hero_id==book_id then hero_changed=true end
        for key,section in pairs(self._home_sections or {}) do
            for _,book in ipairs(section.rows or {}) do
                if tostring(book.bookId or book.book_id or "")==book_id then
                    changed_sections[key]=true
                    break
                end
            end
        end
    end
    local function apply_batch()
        if generation~=self._home_cover_generation or not HomeView.is_shown() or self:_active_reader_ui() then return end
        if self._download_runtime~=nil then return end
        if changed_count<=0 then return end
        for section in pairs(changed_sections) do self:_home_bump_section_revision(section) end
        local active=self._home_active_section or "account"
        if hero_changed and self._home_hero then
            -- Update only the recent-reading static layer; unrelated shelf cards
            -- keep their rendered objects and do not blink.
            HomeView.update_hero(self._home_hero)
        end
        if changed_sections[active] then
            for id in pairs(changed_ids) do HomeView.update_book(id) end
        end
        logger.info("[MiuRead][HomeCoverBatch] applied",
            "changed=",tostring(changed_count),"hero=",tostring(hero_changed),
            "active=",tostring(active))
    end
    local function finish()
        if changed_count>0 and generation==self._home_cover_generation and HomeView.is_shown() then
            -- Let the final worker callback leave the input path before one
            -- bounded e-ink update. A later tab switch wins automatically.
            UIManager:scheduleIn(.35,apply_batch)
        end
        if #rendered_books>0 and generation==self._home_cover_generation then
            UIManager:scheduleIn(derivative_gap,function()
                if generation==self._home_cover_generation and HomeView.is_shown() and not self:_active_reader_ui() then
                    self:_home_schedule_cover_derivatives(rendered_books)
                end
            end)
        end
    end
    local function next_cover()
        if generation~=self._home_cover_generation or not HomeView.is_shown() or self:_active_reader_ui() then return end
        if self._download_runtime~=nil then return end
        if self:_home_ui_busy() then UIManager:scheduleIn(math.max(.45,cover_gap),next_cover); return end
        if lightweight and self.home_metadata_async and self.home_metadata_async:busy() then
            UIManager:scheduleIn(math.max(.5,cover_gap),next_cover)
            return
        end
        if self.home_cover_async:busy() then UIManager:scheduleIn(math.max(.3,cover_gap),next_cover); return end
        local item=queue[index]
        if not item then finish(); return end
        if self._home_cover_inflight[item.bookId] then
            index=index+1
            if queue[index] then UIManager:scheduleIn(.02,next_cover) else finish() end
            return
        end
        self._home_cover_inflight[item.bookId]=generation
        local background=self.home_cover_async:available()
        local covers_dir=self.store.covers_dir
        local worker
        if background then
            worker=function()
                local HttpChild=require("miuread.http")
                local LibraryChild=require("miuread.library")
                local store={
                    covers_dir=covers_dir,
                    auth=function() return {cookies={}} end,
                    save_auth=function() end,
                    get=function(_,_,default) return default end,
                    set=function() end,
                }
                return LibraryChild:new(nil,HttpChild:new(store),store):cache_cover(item,{
                    retries=1,timeout={8,15},persist_index=false,skip_index_lookup=true,
                })
            end
        else
            worker=function()
                return self.library:cache_cover(item,{
                    retries=0,timeout={4,7},persist_index=false,skip_index_lookup=true,
                })
            end
        end
        local started=self.home_cover_async:run("home-cover",worker,function(result)
            if self._home_cover_inflight[item.bookId]==generation then
                self._home_cover_inflight[item.bookId]=nil
            end
            if generation~=self._home_cover_generation then return end
            if result and result.ok and result.value then
                self:_remember_cover_path(item.bookId,result.value)
                local changed=self:_home_apply_cover_path(item.bookId,result.value)
                if item.book then
                    item.book.cover_path=result.value
                    item.book.home_cover_path=nil
                    rendered_books[#rendered_books+1]=item.book
                end
                if changed then
                    changed_count=changed_count+1
                    mark_changed(item.bookId)
                end
            elseif result and result.error then
                logger.warn("[MiuRead][Home] cover download failed",tostring(item.bookId),U.first_line(result.error,120))
            end
            index=index+1
            if queue[index] then UIManager:scheduleIn(cover_gap,next_cover) else finish() end
        end,background and 35 or 14)
        if not started then
            if self._home_cover_inflight[item.bookId]==generation then self._home_cover_inflight[item.bookId]=nil end
            UIManager:scheduleIn(math.max(.35,cover_gap),next_cover)
        end
    end
    logger.info("[MiuRead][HomeCoverBatch] queued","count=",tostring(#queue),
        "lightweight=",tostring(lightweight))
    UIManager:scheduleIn(lightweight and math.max(.8,cover_gap) or .12,next_cover)
end

function Plugin:_home_open_miuread(book)
    self:_home_stop_background("opening book")
    local id=tostring(book and (book.bookId or book.book_id) or "")
    local record=id~="" and self:_preferred_record(id) or nil
    if record and record.file and U.file_exists(record.file) then
        return self:_open_file_direct(record.file)
    end
    if id~="" then self:book_menu(book) else self:info("本地书籍记录不存在") end
end

function Plugin:_home_open_local(book)
    local path=tostring(book and book.file or "")
    if path=="" or not U.file_exists(path) then self:info("本地文件不存在"); return end
    self:_home_stop_background("opening local book")
    return self:_open_file_direct(path)
end

function Plugin:_home_schedule_local_shelf_metadata(rows,view)
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    local generation=self._home_metadata_generation
    local lightweight=self:_lightweight_enabled()
    local queue_limit=lightweight and (tonumber(Config.LIGHTWEIGHT_LOCAL_METADATA_QUEUE) or 3) or 8
    local metadata_gap=lightweight and (tonumber(Config.LIGHTWEIGHT_METADATA_GAP) or .75) or .25
    local queue={}
    for _,book in ipairs(rows or {}) do
        if not (book.local_folder==true or book.kind=="folder")
            and book.file and LocalMetadata.needs_refresh(book,true) then
            queue[#queue+1]=book
            if #queue>=queue_limit then break end
        end
    end
    if #queue==0 then return false end
    local index,changed_any=1,false
    local cache_dir=self:_home_local_metadata_dir()
    local function finish()
        if changed_any and generation==self._home_metadata_generation
            and view and not view._miu_closed and type(view.updateItems)=="function" then
            pcall(view.updateItems,view,nil,true)
        end
    end
    local function apply_metadata(book,metadata,err)
        if metadata then
            local visible_changed=LocalMetadata.merge(book,metadata)
            book.status_text=self:_home_status_text(book,true)
            local cache_changed=self:_home_update_local_cache(book.file,metadata)
            changed_any=changed_any or visible_changed or cache_changed
        elseif err then
            logger.warn("[MiuRead][Home] local shelf metadata unavailable",tostring(book.file),tostring(err))
        end
        index=index+1
    end
    local function next_book()
        if generation~=self._home_metadata_generation or self:_active_reader_ui() then return end
        local book=queue[index]
        if not book then finish(); return end
        if self.home_metadata_async and self.home_metadata_async:available() then
            if self.home_metadata_async:busy() then UIManager:scheduleIn(math.max(.35,metadata_gap),next_book); return end
            local filepath=book.file
            local started=self.home_metadata_async:run("shelf-local-metadata",function()
                local Metadata=require("miuread.local_metadata")
                return Metadata.read(filepath,cache_dir,{open_document=true,use_bim=true})
            end,function(result)
                if generation~=self._home_metadata_generation then return end
                if result and result.ok and type(result.value)=="table" then
                    apply_metadata(book,result.value)
                else
                    apply_metadata(book,nil,result and result.error or "后台提取失败")
                end
                if queue[index] then UIManager:scheduleIn(metadata_gap,next_book) else finish() end
            end,45)
            if not started then UIManager:scheduleIn(.4,next_book) end
            return
        end
        local metadata,err=LocalMetadata.read(book.file,cache_dir,{open_document=true,use_bim=true})
        apply_metadata(book,metadata,err)
        if queue[index] then UIManager:scheduleIn(math.max(.4,metadata_gap),next_book) else finish() end
    end
    UIManager:scheduleIn(lightweight and math.max(.8,metadata_gap) or .25,next_book)
    return true
end

function Plugin:_local_browser_decorate(snapshot,root_path)
    snapshot=type(snapshot)=="table" and snapshot or {folders={},books={}}
    local cache=self:_home_local_tree_cache()
    local folders={}
    for _,folder in ipairs(snapshot.folders or {}) do
        local path=LocalLibrary.normalize(folder.folder_path or folder.path)
        local child=cache.dirs[path]
        local count=type(child)=="table" and (#(child.folders or {})+#(child.books or {})) or nil
        folders[#folders+1]={
            kind="folder",local_folder=true,source="local",title=tostring(folder.title or LocalLibrary.basename(path)),
            folder_path=path,path=path,root_path=LocalLibrary.normalize(root_path or path),
            status_text=count and (tostring(count).." 项") or "文件夹",
        }
    end
    local books={}
    local known=self:_home_local_known_paths()
    local home=self:_home_preferences()
    local hidden=type(home.hidden_local_files)=="table" and home.hidden_local_files or {}
    for _,book in ipairs(snapshot.books or {}) do
        local path=LocalLibrary.normalize(book.file)
        if path~="" and U.file_exists(path) and not known[path] and hidden[path]~=true
            and not LocalLibrary.is_likely_dictionary(path,book.title) then
            book.file=path; book.local_file=true; book.source="local"; book.status_text=self:_home_status_text(book,true)
            books[#books+1]=book
        end
    end
    return folders,books
end

function Plugin:_show_local_browser_snapshot(path,root,stack,snapshot)
    path=LocalLibrary.normalize(path)
    root=root or {path=path,name=LocalLibrary.basename(path)}
    stack=type(stack)=="table" and stack or {}
    local folders,books=self:_local_browser_decorate(snapshot,root.path)
    local title=(path==LocalLibrary.normalize(root.path))
        and tostring(root.name or LocalLibrary.basename(path))
        or tostring(LocalLibrary.basename(path))
    local view
    local function open_folder(folder)
        -- Keep the current level alive underneath. This preserves its page
        -- position and avoids a home-screen flash while the child directory is
        -- read in the background.
        local next_stack=U.copy(stack)
        next_stack[#next_stack+1]={path=path,title=title}
        self:show_local_browser(folder.folder_path or folder.path,root,next_stack,false,view)
    end
    local function go_back()
        if view and not view._miu_closed then UIManager:close(view) end
        -- The previous directory (or the MiuRead home at the configured root)
        -- is already present underneath.
    end
    view=LocalBrowserView.show{
        title=title,folders=folders,books=books,
        empty_text=snapshot.error and ("无法读取文件夹\n"..tostring(snapshot.error)) or "这个文件夹里没有可显示的书籍",
        on_open_folder=open_folder,
        on_open_book=function(book) self:_home_open_local(book) end,
        on_hold_book=function(book) self:_home_hold_book(book) end,
        on_back=go_back,
        on_close=function(closed_view)
            if self._home_directory_request_owner==closed_view then
                self:_cancel_home_directory_request("local browser closed")
            end
        end,
        on_refresh=function()
            self:_home_refresh_local_directory(path,function(fresh)
                local next_folders,next_books=self:_local_browser_decorate(fresh,root.path)
                if view and not view._miu_closed then view:updateData{folders=next_folders,books=next_books,error=fresh.error} end
                if HomeView.is_shown() then self:_notify_home_data_changed("content") end
            end,true,view)
        end,
    }
    self:_home_schedule_local_shelf_metadata(books,view)
    return view
end

function Plugin:show_local_browser(path,root,stack,force,request_owner)
    path=LocalLibrary.normalize(path)
    if path=="" or lfs.attributes(path,"mode")~="directory" then self:info("本地书库目录不存在"); return false end
    local cache=self:_home_local_tree_cache()
    local cached=cache.dirs[path]
    if type(cached)=="table" and force~=true then
        local view=self:_show_local_browser_snapshot(path,root,stack,cached)
        local home=self:_home_preferences()
        if home.local_check_on_open~=false then
            self:_home_refresh_local_directory(path,function(fresh,scanned)
                if not scanned or not view or view._miu_closed then return end
                local folders,books=self:_local_browser_decorate(fresh,root and root.path or path)
                view:updateData{folders=folders,books=books,error=fresh.error}
                self:_home_schedule_local_shelf_metadata(books,view)
            end,true,view)
        end
        return view
    end
    self:toast("正在打开文件夹…",2)
    self:_home_refresh_local_directory(path,function(snapshot)
        self:_show_local_browser_snapshot(path,root,stack,snapshot)
        if HomeView.is_shown() then self:_notify_home_data_changed("content") end
    end,true,request_owner)
    return true
end

function Plugin:_open_local_library_folders()
    local roots=self:_home_local_roots(true)
    if #roots==0 then
        self:info("还没有设置本地书库目录。\n\n可在 首页与书架 → 本地书籍 中添加。")
        return false
    end
    if #roots==1 then return self:show_local_browser(roots[1].path,roots[1],{},false) end
    local folders={}
    for _,root in ipairs(roots) do folders[#folders+1]=self:_home_local_folder_entry(root.path,root.name,root.path) end
    local picker
    picker=LocalBrowserView.show{
        title="本地文件夹",folders=folders,books={},
        on_open_folder=function(folder)
            local selected
            for _,root in ipairs(roots) do if root.path==folder.folder_path then selected=root; break end end
            self:show_local_browser(folder.folder_path,selected or {path=folder.folder_path,name=folder.title},{},false,picker)
        end,
        on_back=function(view) if view and not view._miu_closed then UIManager:close(view) end end,
        on_close=function(closed_view)
            if self._home_directory_request_owner==closed_view then self:_cancel_home_directory_request("local root picker closed") end
        end,
        on_refresh=function() self:_home_scan_local(true) end,
    }
    return picker
end

function Plugin:show_home_local_library(rows)
    local roots=self:_home_local_roots(true)
    if #roots==0 then
        self:info("还没有设置本地书库目录。\n\n可在 首页与书架 → 本地书籍 中添加。")
        return false
    end
    rows=type(rows)=="table" and rows or select(1,self:_home_local_rows())
    if #rows==0 then
        if self:_home_preferences().local_auto_update==true then self:_home_scan_local(false) end
        self:info("本地书库暂时没有可显示的书籍。")
        return false
    end
    return self:_home_show_full_shelf("本地书籍",rows,{
        show_actions=true,
        left_action_label="搜索",
        right_action_label="文件夹",
        on_left_action=function() self:show_home_search_dialog("local") end,
        on_right_action=function() self:_open_local_library_folders() end,
    })
end

function Plugin:_home_account_name()
    local auth=self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    local name=U.trim(tostring(account.name or ""))
    if name~="" then return name end
    return self:logged_in() and "已登录" or "未登录"
end

function Plugin:_home_prepare_hero_book(book)
    if type(book)~="table" then return nil end
    local hero=U.copy(book)
    hero.heading="继续阅读"
    hero.source_text=self:_home_source_text(hero)
    hero.last_read_text=self:_home_last_read_text(hero)
    hero.status_text=self:_home_status_text(hero,hero.source=="local" or hero.local_file==true)
    self:_home_apply_cached_network_metadata(hero)
    if U.trim(tostring(hero.format or ""))=="" then
        local extension=tostring(hero.file or ""):match("%.([%w]+)$")
        if extension then hero.format=extension:upper() end
    end
    local variant=tostring(hero.variant or "")
    if hero.annotation_requested==true or variant:find("notes",1,true) then
        hero.edition_text="含评论"
    elseif variant:find("clean",1,true) then
        hero.edition_text="纯净版"
    end
    hero.on_tap=function(anchor) self:_home_open_book(hero,anchor) end
    hero.on_refresh_metadata=function() self:_home_refresh_current_network_metadata(hero) end
    return hero
end

function Plugin:_home_refresh_recent_hero_cached()
    if self._home_recent_read_dirty~=true and HOME_SESSION.recent_read_dirty~=true then return false end
    if not HomeView.is_shown() or self:_active_reader_ui() then return false end
    local sections=self._home_sections or {}
    local generated=sections.generated and sections.generated.rows or {}
    local local_rows=sections["local"] and sections["local"].rows or {}
    local account=sections.account and sections.account.rows or {}
    if #generated==0 and #local_rows==0 and #account==0 then return false end
    self:_home_apply_recent_read_times(generated,local_rows,account)
    local hero=self:_home_prepare_hero_book(self:_home_recent_book(generated,local_rows,account))
    self._home_recent_read_dirty=false
    HOME_SESSION.recent_read_dirty=false
    if not hero then return false end
    local previous_key=self:_home_book_key(self._home_hero)
    local current_key=self:_home_book_key(hero)
    local previous_time=self:_home_book_time(self._home_hero)
    local current_time=self:_home_book_time(hero)
    self._home_hero=hero
    if previous_key~=current_key or previous_time~=current_time then
        HomeView.update_hero(hero)
        logger.info("[MiuRead][Recent] hero updated",
            "book=",tostring(current_key),"read_at=",tostring(current_time))
    end
    local current=HomeView.current()
    local shelf=(current and current.opts and current.opts.shelf_books) or {}
    local metadata_targets={hero}
    local cover_targets={hero}
    for _,book in ipairs(shelf) do
        metadata_targets[#metadata_targets+1]=book
        cover_targets[#cover_targets+1]=book
    end
    self._home_visible_metadata_targets=metadata_targets
    self._home_visible_cover_targets=cover_targets
    local home=self:_home_preferences()
    HOME_SESSION.lockscreen_recent_enabled=home.lockscreen_recent~=false
    HOME_SESSION.screensaver_file=home.lockscreen_recent~=false and self:_home_prepare_lockscreen_cover(hero) or nil
    if home.network_metadata~=false then
        local key=self:_home_network_metadata_key(hero)
        if key~="" then self._home_pending_network_metadata_key=key end
    end
    return true
end

function Plugin:_show_miuread_home_now(force_scan,from_refresh,quiet,refresh_kind,options)
    options=type(options)=="table" and options or {}
    if Session.home_exiting() or UIManager._exit_code~=nil or HOME_SESSION.suspended==true or self._miuread_suspended==true then return false end
    if READER_CLOSE.state~="idle" and READER_CLOSE.state~="completed"
        and READER_CLOSE.state~="failed" and READER_CLOSE.state~="home_restoring" then
        logger.info("[MiuRead][ReaderClose] home rebuild blocked during close",READER_CLOSE.state)
        return false
    end
    if self:_home_background_blocked() and HomeView.is_shown() and not self:_active_reader_ui() then
        self:_home_defer_refresh_kind(refresh_kind or "content")
        HomeView.raise()
        return true
    end
    Session.home().suppressed =false
    Session.home().native_visit =false
    Session.home().expected_close =false
    -- The rendered home stays parked under ReaderUI. Keep the reader-origin
    -- token until ReaderUI has actually left so an explicit return can raise it.
    if not self:_active_reader_ui() then
        Session.home().reader_origin =false
        Session.home().reader_file =nil
        Session.home().return_file =nil
    end

    if force_scan==true then self:_home_reset_local_metadata() end
    local miuread_rows=self:_home_miuread_rows()
    local local_rows=self:_home_local_rows()
    local cached_books,cached_mp=self.library:cached()
    cached_books=type(cached_books)=="table" and cached_books or {}
    cached_mp=type(cached_mp)=="table" and cached_mp or {}

    local account_rows=self:_shelf_rows("account",false,cached_books,{},#cached_books>0)
    self:_prepare_shelf_rows(account_rows)
    for _,row in ipairs(account_rows) do
        self:_home_attach_local_record(row)
        row.source="account"
        row.description=row.description or row.intro or row.summary
        row.status_text=self:_home_status_text(row,false)
    end
    local mp_rows=self:_shelf_rows("account",true,{},cached_mp,#cached_mp>0)
    self:_prepare_shelf_rows(mp_rows)
    for _,row in ipairs(mp_rows) do
        row.source="mp"
        row.status_text=self:_home_status_text(row,false)
    end

    local home,home_preferences=self:_home_preferences()
    self:_home_apply_recent_read_times(miuread_rows,local_rows,account_rows,mp_rows)
    local hero=self:_home_prepare_hero_book(self:_home_recent_book(miuread_rows,local_rows,account_rows))

    local sections={
        account={title="书架",rows=account_rows,empty="书架空空，去书城逛逛吧"},
        generated={title="已下载",rows=miuread_rows,empty="还没有已下载的书籍"},
        ["local"]={title="本地书籍",rows=local_rows,empty=self:_home_local_empty_text()},
        mp={title="公众号",rows=mp_rows,empty="这里还没有公众号内容"},
    }
    -- P3: shelf-wide sort (recent/added/title/author), pure sorter in constants.
    local shelf_sort=home.shelf_sort or "recent"
    for _,section in pairs(sections) do
        if type(section.rows)=="table" and #section.rows>0 then
            section.rows=HomeLayouts.sort_rows(section.rows,shelf_sort)
        end
    end
    self._home_data_revision=(tonumber(self._home_data_revision) or 0)+1
    self._home_sections=sections
    local visible_keys=self:_home_visible_section_keys(sections,home)
    self._home_visible_keys=visible_keys
    local active=visible_keys[1] or "account"
    for _,key in ipairs(visible_keys) do
        if key==home.active_section then active=key; break end
    end
    local selected=sections[active]
    if home.active_section~=active then
        home.active_section=active
        local _,preferences=self:_home_preferences()
        self:_save_home_preferences_deferred(home,preferences)
    end
    self._home_active_section=active
    self._home_hero=hero
    local preview_limit=self:_home_page_limit()
    local selected_preview,shelf_page,shelf_pages=self:_home_preview_page(
        selected.rows,hero,home.page_by_section and home.page_by_section[active],preview_limit
    )
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    if tonumber(home.page_by_section[active])~=shelf_page then
        home.page_by_section[active]=shelf_page
        local _,preferences=self:_home_preferences()
        self:_save_home_preferences_deferred(home,preferences)
    end
    local tabs=self:_home_build_tabs(active)

    local screensaver_file=home.lockscreen_recent~=false and self:_home_prepare_lockscreen_cover(hero) or nil
    HOME_SESSION.lockscreen_recent_enabled=home.lockscreen_recent~=false
    HOME_SESSION.screensaver_file=screensaver_file
    local home_alerts=self:_home_alerts()
    self._home_panel_sync_label=self:progress_sync_label()
    self._home_panel_download_detail=""
    self._home_panel_status_text=(home_alerts[1] and tostring(home_alerts[1].title or "")) or ""
    local view,err=HomeView.show({
        title="觅阅",
        wifi_text=self:_home_wifi_text(),
        time_text=self:_display_time("%H:%M"),
        battery_text=self:_home_battery_text(),
        account_name=self:_home_account_name(),
        layout_style=home.layout_style,
        display_size=home.display_size,
        hero=hero,
        tabs=tabs,
        shelf_title=active=="local" and self:_home_local_inline_title() or "",
        shelf_books=selected_preview,
        shelf_page=shelf_page,
        shelf_pages=shelf_pages,
        empty_text=selected.empty,
        -- Download progress belongs to the matching shelf card; only true
        -- account/health alerts occupy the home notice strip.
        alerts=home_alerts,
        lockscreen_enabled=home.lockscreen_recent~=false,
        screensaver_file=screensaver_file,
        on_quick_panel=function() self:show_home_quick_panel() end,
        on_interaction=function(first,kind) self:_home_note_interaction(first,kind) end,
        on_account=function() self:_home_leave_and_run("account status",function() self:show_account_status() end) end,
        on_menu=function() self:show_home_menu() end,
        on_back=function() return self:_home_handle_back() end,
        on_empty_account=function() self:_home_open_section(active) end,
        on_empty_shelf=function()
            if active=="account" then self:_set_home_page("store")
            else self:show_home_all_books() end
        end,
        on_open_book=function(book,anchor) self:_home_open_book(book,anchor) end,
        on_hold_book=function(book,anchor) self:_home_hold_book(book,anchor) end,
        home_actions=self:_home_action_entries(),
        on_shelf_all=function()
            if active=="local" then self:show_home_local_library()
            else self:show_home_all_books() end
        end,
        on_shelf_page=function(delta) self:_home_change_page(delta) end,
        page=home.page or "shelf",
        tabs_bottom={
            {title="书架", selected=(home.page or "shelf")=="shelf", on_tap=function() self:_set_home_page("shelf") end},
            {title="书城", selected=(home.page or "shelf")=="store", on_tap=function() self:_set_home_page("store") end},
            {title="我的", selected=(home.page or "shelf")=="me", on_tap=function() self:_set_home_page("me") end},
        },
        on_page=function(page) self:_set_home_page(page) end,
        on_store_search=function() self:search_dialog("搜索微信读书") end,
        on_store_mp=function() self:show_mp_shelf(false) end,
        me_stats=(home.page or "shelf")=="me" and self:_home_me_duration() or nil,
        on_refresh_duration=function() self:_home_refresh_duration() end,
        on_reading_report=function() self:show_reading_report() end,
        on_my_annotations=function() self:_annotation_recent_list() end,
        on_all_books=function() self:show_home_all_books() end,
        on_history=function() self:show_home_reading_history() end,
        on_settings=function() self:_show_home_settings_center() end,
        section_cache_key=active,
        section_revision=self:_home_section_cache_revision(active,shelf_page),
        on_close=function(current)
            if self._home_view==current then self._home_view=nil end
            if current and (current._miu_suppress_restore==true or current._miu_superseded==true) then return end
            if Session.home().expected_close or Session.home().native_visit or Session.home_exiting() or UIManager._exit_code~=nil then return end
            if not self._home_reader_transition and not Session.home().suppressed and self:_home_enabled() then
                local token=self:_navigation_token()
                UIManager:scheduleIn(.6,function()
                    if not self:_navigation_token_valid(token,{home=true,native=true,recovering=true}) then return end
                    if Session.home().expected_close or Session.home().native_visit or Session.home_exiting() or UIManager._exit_code~=nil then return end
                    if not HomeView.is_shown() and not self:_active_reader_ui() and not Session.home().suppressed then
                        self:_restore_home_after_reader_close(1)
                    end
                end)
            end
        end,
    },refresh_kind)
    if not view then
        logger.warn("[MiuRead][Home] bookshelf unavailable",tostring(err or "unknown"))
        if not quiet then self:info("觅阅首页暂时无法显示：\n"..tostring(err or "未知错误")) end
        return false
    end
    self._home_view=view
    rawset(_G,HOME_OWNER_KEY,self)
    self:_set_foreground("home")
    self._home_refresh_pending=false
    self:_home_schedule_clock()
    if active=="local" then
        UIManager:scheduleIn(.05,function()
            if HomeView.is_shown() and self._home_active_section=="local" then self:_home_ensure_local_inline_loaded() end
        end)
    end

    local metadata_targets={}
    local cover_targets={}
    if hero then
        metadata_targets[#metadata_targets+1]=hero
        cover_targets[#cover_targets+1]=hero
    end
    for _,book in ipairs(selected_preview) do
        metadata_targets[#metadata_targets+1]=book
        cover_targets[#cover_targets+1]=book
    end
    self._home_visible_metadata_targets=metadata_targets
    self._home_visible_cover_targets=cover_targets
    if options.skip_background~=true then
        self:_home_schedule_local_metadata(metadata_targets)
        self:_home_schedule_remote_covers(cover_targets)
        -- Existing covers are converted only after the home is already interactive.
        -- Newly downloaded covers schedule the same worker when their batch ends.
        UIManager:scheduleIn(.85,function()
            if HomeView.is_shown() and not self:_active_reader_ui() then self:_home_schedule_cover_derivatives(cover_targets) end
        end)
    end
    local hero_needs_network = hero and (
        U.trim(tostring(hero.description or hero.intro or hero.summary or ""))==""
        or U.trim(tostring(hero.category or ""))==""
        or U.trim(tostring(hero.publisher or ""))==""
        or U.trim(tostring(hero.published_date or ""))==""
        or U.trim(tostring(hero.isbn or ""))==""
    )
    local hero_key=hero and self:_home_network_metadata_key(hero) or ""
    local hero_recent_changed=hero_key~="" and tostring(home.last_network_metadata_recent_key or "")~=hero_key
    if hero_recent_changed then
        home.last_network_metadata_recent_key=hero_key
        self:_save_home_preferences_deferred(home,home_preferences)
    end
    if options.skip_background~=true
        and hero_recent_changed and hero_needs_network and home.network_metadata~=false then
        -- Only the newly changed recent-reading book may start an automatic
        -- network lookup. Successful results stay cached until manual refresh.
        UIManager:scheduleIn(2.5,function()
            if HomeView.is_shown() and not self:_active_reader_ui()
                and self._home_hero and self:_home_network_metadata_key(self._home_hero)==hero_key then
                self:_home_schedule_network_metadata(self._home_hero,false)
            end
        end)
    end

    if not from_refresh and options.skip_background~=true then
        if force_scan==true then self:_home_scan_local(true) end
        -- Startup remains cache-first. Stale cloud/local checks are allowed
        -- only after the interface is idle and their TTL has expired.
        self:_home_schedule_stale_checks(4.5)
    end
    return true
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
