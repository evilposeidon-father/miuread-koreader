local RawButtonDialog=require("ui/widget/buttondialog")
local RawConfirmBox=require("ui/widget/confirmbox")
local RawInfoMessage=require("ui/widget/infomessage")
local RawInputDialog=require("ui/widget/inputdialog")
local RawMenu=require("ui/widget/menu")
local RawPathChooser=require("ui/widget/pathchooser")
local UIManager=require("ui/uimanager")
local Device=require("device")
local Blitbuffer=require("ffi/blitbuffer")
local Event=require("ui/event")
local WidgetContainer=require("ui/widget/container/widgetcontainer")
local logger=require("logger")
local ok_socket,socket=pcall(require,"socket")
local function monotonic_wall_time()
    if ok_socket and socket and type(socket.gettime)=="function" then return socket.gettime() end
    return os.time()
end
local MAIN_LOAD_STARTED_AT=monotonic_wall_time()
local lfs=require("libs/libkoreader-lfs")
local Config=require("miuread.config")
local Text=require("miuread.text")
local U=require("miuread.util")
local Lazy=require("miuread.lazy")
local PluginMaintenance=require("miuread.plugin_maintenance")
local PluginUpdate=require("miuread.plugin_update")
local PluginSync=require("miuread.plugin_sync")
local PluginDownload=require("miuread.plugin_download")
local PluginReader=require("miuread.plugin_reader")
local PluginSearchMp=require("miuread.plugin_search_mp")
local PluginRepair=require("miuread.plugin_repair")
local PluginPreferences=require("miuread.plugin_preferences")
local PluginThoughtPopup=require("miuread.plugin_thought_popup")
local PluginDevice=require("miuread.plugin_device")
local PluginBook=require("miuread.plugin_book")
local PluginEvents=require("miuread.plugin_events")
local PluginExit=require("miuread.plugin_exit")
local PluginNavigation=require("miuread.plugin_navigation")
local PluginNativeMenu=require("miuread.plugin_native_menu")
local PluginShelf=require("miuread.plugin_shelf")
local PluginHome=require("miuread.plugin_home")
local Json=require("miuread.json")
local Store=require("miuread.store")
local Http=require("miuread.http")
local Api=require("miuread.api")
local Auth=require("miuread.auth")
local Reader=require("miuread.reader")
local Protocol=require("miuread.protocol")
local MP=require("miuread.mp")
local Access=require("miuread.access")
local Annotations=require("miuread.annotations")
local LocalAnnotationDatabase=Lazy("miuread.local_annotation_database")
local AnnotationSync=require("miuread.annotation_sync")
local Downloader=require("miuread.downloader")
local DownloadProgress=require("miuread.download_progress")
local DownloadTask=require("miuread.download_task")
local DownloadResult=require("miuread.download_result")
local BookIntegrity=require("miuread.book_integrity")
local EpubInstaller=require("miuread.epub_installer")
local CacheCleanupTask=require("miuread.cache_cleanup_task")
local MemoryMode=require("miuread.memory_mode")
local PerformanceMode=require("miuread.performance_mode")
local Library=require("miuread.library")
local ShelfView=require("miuread.shelf_view")
local FullShelfView=Lazy("miuread.full_shelf_view")
local LocalBrowserView=Lazy("miuread.local_browser_view")
local HomeView=Lazy("miuread.home_view")
local HomeQuickPanel=require("miuread.home_quick_panel")
local ActionSheet=Lazy("miuread.action_sheet")
local TransientGuard=require("miuread.transient_guard")
local ScreenshotMode=Lazy("miuread.screenshot_mode")
local GestureBridge=require("miuread.gesture_bridge")
local Orientation=require("miuread.orientation_controller")
local HomeData=require("miuread.home_data")
local TimeZone=require("miuread.timezone")
local UiScale=require("miuread.ui_scale")
local LocalLibrary=Lazy("miuread.local_library")
local LocalMetadata=require("miuread.local_metadata")
local NetworkMetadata=require("miuread.network_metadata")
local Async=require("miuread.async")
local Sync=require("miuread.sync")
local Updater=require("miuread.updater")
local Cookies=require("miuread.cookies")
local Thoughts=require("miuread.thoughts")
local ThoughtNativePopup=Lazy("miuread.thought_native_popup")
local ReaderToolbar=Lazy("miuread.reader_toolbar")
local ReaderListDialog=Lazy("miuread.reader_list_dialog")
local DataMigration=require("miuread.data_migration")
local MigrationProgress=require("miuread.migration_progress")
local DownloadDatabase=require("miuread.download_database")
local StatusToast=require("miuread.status_toast")
local ReaderTransitionGuard=require("miuread.reader_transition_guard")
local PluginMenu=require("miuread.plugin_menu")
local PluginSettings=require("miuread.plugin_settings")
local Actions=require("miuread.actions")
local ExternalAnnotationsDB=require("miuread.external_annotations_db")
local ExternalAnnotationSync=require("miuread.external_annotation_sync")
local function gesture_aware_class(base, attributes)
    local class=base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base,self,event)
    end
    return class
end
local ButtonDialog=gesture_aware_class(RawButtonDialog,{_miuread_transient=true,_miuread_modal_surface=true})
local ConfirmBox=gesture_aware_class(RawConfirmBox,{_miuread_transient=true,_miuread_modal_surface=true})
local InfoMessage=gesture_aware_class(RawInfoMessage,{_miuread_transient=true,_miuread_modal_surface=true})
local InputDialog=gesture_aware_class(RawInputDialog,{_miuread_transient=true,_miuread_modal_surface=true})
local Menu=gesture_aware_class(RawMenu,{_miuread_transient=true,_miuread_modal_surface=true})
local PathChooser=gesture_aware_class(RawPathChooser,{_miuread_transient=true,_miuread_modal_surface=true})
local _=Text.tr
local unpack_args=unpack or table.unpack
local HomeLayouts = require("miuread.home_layout_constants")
local COVER_GUARD_WINDOW = HomeLayouts.COVER_GUARD_WINDOW
local HOME_LOCAL_CACHE_TTL = HomeLayouts.HOME_LOCAL_CACHE_TTL
local HOME_SHELF_REFRESH_TTL = HomeLayouts.HOME_SHELF_REFRESH_TTL
local HOME_REMOTE_AUTO_RETRY = HomeLayouts.HOME_REMOTE_AUTO_RETRY
local HOME_SECTION_ORDER = HomeLayouts.HOME_SECTION_ORDER
local HOME_QUICK_ITEM_LEGACY_ORDER = HomeLayouts.HOME_QUICK_ITEM_LEGACY_ORDER
local HOME_QUICK_ITEM_LEGACY_DEFAULT = HomeLayouts.HOME_QUICK_ITEM_LEGACY_DEFAULT
local HOME_ACTION_ITEM_V1_ORDER = HomeLayouts.HOME_ACTION_ITEM_V1_ORDER
local HOME_ACTION_ITEM_V1_DEFAULT = HomeLayouts.HOME_ACTION_ITEM_V1_DEFAULT
local HOME_ACTION_ITEM_V2_ORDER = HomeLayouts.HOME_ACTION_ITEM_V2_ORDER
local HOME_ACTION_ITEM_V2_DEFAULT = HomeLayouts.HOME_ACTION_ITEM_V2_DEFAULT
local HOME_ACTION_ITEM_ORDER = HomeLayouts.HOME_ACTION_ITEM_ORDER
local HOME_ACTION_ITEM_DEFAULT = HomeLayouts.HOME_ACTION_ITEM_DEFAULT
local HOME_ACTION_LAYOUT_VERSION = HomeLayouts.HOME_ACTION_LAYOUT_VERSION
local HOME_PANEL_ITEM_V1_ORDER = HomeLayouts.HOME_PANEL_ITEM_V1_ORDER
local HOME_PANEL_ITEM_V1_DEFAULT = HomeLayouts.HOME_PANEL_ITEM_V1_DEFAULT
local HOME_PANEL_ITEM_V2_ORDER = HomeLayouts.HOME_PANEL_ITEM_V2_ORDER
local HOME_PANEL_ITEM_V2_DEFAULT = HomeLayouts.HOME_PANEL_ITEM_V2_DEFAULT
local HOME_PANEL_ITEM_ORDER = HomeLayouts.HOME_PANEL_ITEM_ORDER
local HOME_PANEL_ITEM_DEFAULT = HomeLayouts.HOME_PANEL_ITEM_DEFAULT
local HOME_PANEL_LAYOUT_VERSION = HomeLayouts.HOME_PANEL_LAYOUT_VERSION
local quick_boolean_layout_matches = HomeLayouts.quick_boolean_layout_matches
local quick_order_matches = HomeLayouts.quick_order_matches

-- ReaderUI and FileManager create separate plugin instances. Keep navigation
-- state in _G so opening/closing a document does not lose its MiuRead origin.
-- miuread.session_state owns those tables (defaults, normalization) and
-- exposes the typed accessors used by main.lua and the split controllers.
local Session = require("miuread.session_state")
local HOME_SESSION = Session.home()
local READER_CLOSE = Session.reader_close()
local READER_REBUILD = Session.reader_rebuild()
local NAVIGATION = Session.navigation()
Session.sync_home_navigation_fields()
local NAVIGATION_STATES = Session.NAVIGATION_STATES
local function navigation_state_from_foreground(owner)
    return Session.navigation_state_from_foreground(owner)
end
local function reader_rebuild_active()
    return Session.reader_rebuild_active()
end
-- ReaderUI and FileManager transition asynchronously and may use different
-- plugin instances. Keep one shared close coordinator so CloseDocument,
-- showFileManager and delayed callbacks cannot race each other.
local function reader_close_active()
    return Session.reader_close_active()
end
local normalized_reader_file = Session.normalized_reader_file
local mark_reader_origin = Session.mark_reader_origin
-- Track a temporary KOReader menu visit globally because FileManager and
-- ReaderUI use different plugin instances. MiuRead remains visible underneath
-- native menus and is raised again after the last native page closes.
local NATIVE_MENU_GUARD=Session.native_menu_guard()
local DIRECT_MENU_INSERTED=false
local SCREENSAVER_PATCHED=false
local HOME_OWNER_KEY="__MIUREAD_HOME_OWNER"

local function home_owner()
    local owner=rawget(_G,HOME_OWNER_KEY)
    if type(owner)=="table" and owner._runtime_mode=="desktop" then return owner end
    return nil
end

local function install_home_screensaver_patch()
    if SCREENSAVER_PATCHED then return true end
    local ok,Screensaver=pcall(require,"ui/screensaver")
    if not ok or not Screensaver or type(Screensaver.setup)~="function" then return false end
    if Screensaver._miuread_original_setup then SCREENSAVER_PATCHED=true; return true end
    local original=Screensaver.setup
    local keys={"screensaver_type","screensaver_document_cover","screensaver_show_message","screensaver_img_background"}
    local function snapshot()
        local saved={}
        for _,key in ipairs(keys) do
            saved[key]={has=G_reader_settings:has(key),value=G_reader_settings:readSetting(key)}
        end
        return saved
    end
    local function restore(saved)
        for _,key in ipairs(keys) do
            local row=saved[key]
            if row and row.has then G_reader_settings:saveSetting(key,row.value)
            else G_reader_settings:delSetting(key) end
        end
    end
    Screensaver._miuread_original_setup=original
    Screensaver.setup=function(manager,...)
        local args={n=select("#",...),...}
        local current=HomeView.current()
        local opts=current and current.opts or nil
        local target=opts and opts.lockscreen_enabled~=false and tostring(opts.screensaver_file or "") or ""
        local use_home_target=HomeView.is_shown()
        if target=="" and Session.home().reader_origin and HOME_SESSION.lockscreen_recent_enabled~=false then
            target=tostring(HOME_SESSION.screensaver_file or "")
            use_home_target=target~=""
        end

        -- Preserve KOReader's native path whenever ReaderUI/FileManager still
        -- exists.  beta.34 only intervenes in the exact beta.33 gap where the
        -- parked MiuRead home is visible after ReaderUI has closed and before a
        -- FileManager instance exists.  Kindle calls Screensaver:setup/show
        -- before the normal Suspend broadcast, so without this fallback recent
        -- KOReader versions return early and never establish screen_saver_mode.
        local ReaderUI=require("apps/reader/readerui")
        local FileManager=require("apps/filemanager/filemanager")
        local native_ui=ReaderUI.instance or FileManager.instance
        if not native_ui and args.n==0 and HomeView.is_shown() and current then
            local owner=home_owner()
            if HomeView.suspend then pcall(HomeView.suspend) end
            if owner and type(owner._home_freeze_for_suspend)=="function" then
                local frozen,freeze_err=pcall(owner._home_freeze_for_suspend,owner)
                if not frozen then
                    logger.warn("[MiuRead][Suspend] screensaver prefreeze failed",tostring(freeze_err))
                end
            end

            manager.ui=(owner and owner.ui) or current
            manager.show_message=false
            manager.prefix=""
            manager.event_message=nil
            manager.overlay_message=nil
            manager.image=nil
            manager.image_file=nil
            manager.screensaver_background="white"

            if use_home_target and target~="" and lfs.attributes(target,"mode")=="file" then
                manager.screensaver_type="cover"
                manager.image_file=target
                logger.info("[MiuRead][Suspend] screensaver home fallback",
                    "native_ui=false","target=true","prefrozen=",tostring(owner~=nil))
            else
                -- No valid MiuRead cover is available.  Keep the already-painted
                -- home surface instead of inventing a new fallback image; show()
                -- will still mark the device as being in screen-saver mode.
                manager.screensaver_type="disable"
                logger.info("[MiuRead][Suspend] screensaver home fallback",
                    "native_ui=false","target=false","prefrozen=",tostring(owner~=nil))
            end
            return
        end

        if use_home_target and target~="" and lfs.attributes(target,"mode")=="file" then
            local saved=snapshot()
            G_reader_settings:saveSetting("screensaver_type","document_cover")
            G_reader_settings:saveSetting("screensaver_document_cover",target)
            G_reader_settings:saveSetting("screensaver_show_message",false)
            G_reader_settings:saveSetting("screensaver_img_background","white")
            local packed={xpcall(function()
                return original(manager,unpack_args(args,1,args.n))
            end,debug.traceback)}
            restore(saved)
            if not packed[1] then error(packed[2]) end
            return unpack_args(packed,2,#packed)
        end
        return original(manager,unpack_args(args,1,args.n))
    end
    SCREENSAVER_PATCHED=true
    return true
end
local source=debug.getinfo(1,"S").source:gsub("^@",""); local ROOT=source:match("^(.*)/main%.lua$") or "."
local RUNTIME_MODE_KEY=HomeLayouts.RUNTIME_MODE_KEY
local Plugin=WidgetContainer:extend{name="miuread",is_doc_only=false,version=Config.VERSION}
ExternalAnnotationSync.install(Plugin)
PluginMaintenance.install(Plugin)
PluginUpdate.install(Plugin)
PluginSync.install(Plugin)
PluginDownload.install(Plugin)
PluginReader.install(Plugin)
PluginSearchMp.install(Plugin)
PluginRepair.install(Plugin)
PluginPreferences.install(Plugin)
PluginThoughtPopup.install(Plugin)
PluginDevice.install(Plugin)
PluginBook.install(Plugin)
PluginEvents.install(Plugin)
PluginExit.install(Plugin)
PluginNavigation.install(Plugin)
PluginNativeMenu.install(Plugin)
PluginShelf.install(Plugin)
PluginHome.install(Plugin)
local function normalize(v) local b=v.bookInfo or v.book or v; return {bookId=tostring(b.bookId or v.bookId or ""),title=b.title or v.title or "未命名",author=b.author or v.author or "",cover=b.cover or v.cover,category=b.category or v.category,progress=tonumber(v.progress or b.progress or 0) or 0,updateTime=tonumber(v.updateTime or b.updateTime or 0) or 0} end
local function sanitize_saved_auth(store)
    local auth=store:auth()
    local cleaned,changed=Cookies.sanitize(auth.cookies or {})
    if changed then
        auth.cookies=cleaned
        store:save_auth(auth)
        logger.info("[MiuRead][Auth] startup cookie cleanup",
            "names=",table.concat(Cookies.names(cleaned),","))
    end
end
function Plugin:init()
    math.randomseed(os.time()+math.floor(collectgarbage("count")))
    self.store=Store:new()
    self.external_annotations_db=ExternalAnnotationsDB:new(self.store)
    local runtime_mode=rawget(_G,RUNTIME_MODE_KEY)
    if runtime_mode~="desktop" and runtime_mode~="plugin" then
        local configured=((self.store:preferences().home_ui or {}).enabled~=false)
        runtime_mode=configured and "desktop" or "plugin"
        rawset(_G,RUNTIME_MODE_KEY,runtime_mode)
    end
    self._runtime_mode=runtime_mode
    logger.info("[MiuRead][Mode] runtime frozen",tostring(runtime_mode))
    local timezone_ok,timezone_error=TimeZone.apply((self.store:preferences() or {}).time_display)
    if not timezone_ok then logger.warn("[MiuRead][TimeZone] startup apply failed",tostring(timezone_error or "unknown")) end
    self._reader_context=self.ui and self.ui.document~=nil
    if self._reader_context then
        local document=self.ui.document
        local path=normalized_reader_file(document and (document.file or (document.getFilePath and document:getFilePath())) or nil)
        if Session.home().reader_origin or (path and Session.home().reader_file ==path) then
            mark_reader_origin(path)
            logger.info("[MiuRead][Home] reader origin restored",tostring(path or "unknown"))
        end
    end
    if self:_home_enabled() then HomeView.prune_duplicates() end
    if HOME_SESSION.suspended==true then
        self:_set_navigation_state("suspended","plugin initialized while suspended")
    elseif reader_close_active() then
        self:_set_navigation_state("closing_reader","plugin initialized during reader close")
    elseif NATIVE_MENU_GUARD.active==true or self:_navigation_state()=="native_menu" then
        self:_set_navigation_state("native_menu","native menu plugin initialized")
    elseif self._reader_context then
        self:_set_navigation_state("reader","reader plugin initialized")
    elseif HomeView.is_shown() then
        self:_set_navigation_state("home","home plugin initialized")
    else
        self:_set_navigation_state("native","file manager plugin initialized")
    end
    self._reader_active_path="/tmp/miuread-reader-active.flag"
    self._reader_busy_path="/tmp/miuread-reader-busy.until"
    self._reader_busy_until=tonumber(U.read_file(self._reader_busy_path,true) or 0) or 0
    self._reader_last_interaction_clock=0
    self._home_quick_panel_last_open=0
    self._home_quick_panel_opening=false
    -- Keep expensive home workers out of the user's immediate interaction path.
    -- Every touch extends a short quiet window; visible metadata/cover work is
    -- resumed only after that window expires.
    self._home_ui_quiet_until=0
    self._home_post_reader_protect_until=0
    self._home_modal_cooldown_until=0
    self._home_ui_resume_task=nil
    self._home_manual_metadata_retry_task=nil
    self._home_pending_network_metadata_key=nil
    -- Ordinary UI preferences are written into LuaSettings immediately but
    -- their flash flush is coalesced. Critical auth/download/session state
    -- continues to use Store:set() and remains synchronous.
    self._ui_preferences_save_pending=false
    self._ui_preferences_save_generation=0
    self._home_visible_metadata_targets={}
    self._home_visible_cover_targets={}
    self._reader_quick_panel_pending=false
    self._reader_toolbar_state_cache={session=0,page=nil,total=nil,chapter="",updated_at=0}
    self._reader_toolbar_state_task=nil
    self._reader_toolbar_prewarm_task=nil
    self._reader_toolbar_header_perf=nil
    self._reader_toolbar_options_perf=nil
    self._mode_intro_generation=0
    self._thought_popup_marker_path=self.store.temp_dir.."/thought-popup.pending.json"
    self._thought_popup_last_crash_path=self.store.data_dir.."/thought-popup-last-crash.json"
    local pending_popup=U.read_file(self._thought_popup_marker_path,true)
    if pending_popup then
        -- A pending marker can only survive an abnormal exit. Preserve it as a
        -- compact diagnostic instead of letting the next launch mistake it for
        -- a currently active window.
        U.atomic_write(self._thought_popup_last_crash_path,pending_popup,true)
        os.remove(self._thought_popup_marker_path)
        logger.warn("[MiuRead][ThoughtPopup] previous session ended while popup was active")
    end
    self._thought_popup=nil
    self._thought_popup_busy=false
    self._thought_popup_generation=0
    self._reader_checkpoint_task=nil
    self._reader_checkpoint_last=0
    self._reader_checkpoint_dirty=false
    self._reader_returning=false
    self._reader_return_generation=0
    self._reader_return_started=0
    self._reader_return_finish_task=nil
    self._reader_return_completed_generation=nil
    self._reader_return_session_generation=0
    self._reader_close_settle_task=nil
    self._reader_close_settle_generation=0
    self._reader_close_watch_task=nil
    self._reader_dimension_task=nil
    self._reader_dimension_generation=0
    self._reader_dimension_width=Device.screen:getWidth()
    self._reader_dimension_height=Device.screen:getHeight()
    self._reader_dimension_rotation=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil
    self._miuread_suspended=HOME_SESSION.suspended==true
    self._reader_native_menu_opening=false
    self._post_reader_work_task=nil
    HOME_SESSION.post_reader_work_generation=tonumber(HOME_SESSION.post_reader_work_generation) or 0
    self._post_reader_work_generation=HOME_SESSION.post_reader_work_generation
    self._reader_recovery_dialog=nil
    -- Opening state is shared with the FileManager-side plugin instance so a
    -- slow tap cannot start the same ReaderUI transition twice.
    if tonumber(HOME_SESSION.opening_at or 0)>0
        and os.time()-tonumber(HOME_SESSION.opening_at or 0)>30 then
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
    end
    if self._reader_context then
        U.atomic_write(self._reader_active_path,"1",true)
        self._reader_busy_until=os.time()+3
        U.atomic_write(self._reader_busy_path,tostring(self._reader_busy_until),true)
    else
        os.remove(self._reader_active_path)
        os.remove(self._reader_busy_path)
    end
    self.memory_mode=MemoryMode:new(self.store)
    self.performance_mode=PerformanceMode:new(self.store)
    self._reader_interaction_resume_task=nil
    self._reader_interaction_resume_generation=0
    self._performance_prompt_pending=nil
    self._performance_prompt_dialog=nil
    self.book_repair=DataMigration:new(self.store)
    logger.info("[MiuRead] initialized", "version=", tostring(Config.VERSION),
        "schema=", tostring(Config.SCHEMA), "root=", tostring(ROOT))
    sanitize_saved_auth(self.store)
    self.http=Http:new(self.store)
    self.reader=Reader:new(self.http,self.store)
    self.api=Api:new(self.http,self.store,self.reader)
    self.mp=MP:new(self.reader,self.http,self.store,self.api)
    self.annotations=Annotations:new(self.api)
    self.annotation_sync=AnnotationSync:new(self.api,self.reader,self.store)
    do
        local annotation_prefs=self:_annotation_sync_preferences()
        logger.info("[MiuRead][AnnotationSync] initialized",
            "enabled=",tostring(annotation_prefs.enabled==true),"mode=manual")
    end
    self.downloader=Downloader:new(self.reader,self.api,self.annotations,self.store,self.http)
    self.download_task=DownloadTask:new(self.store)
    self.cache_cleanup_task=CacheCleanupTask:new(self.store)
    self.library=Library:new(self.api,self.http,self.store)
    local cover_quality_version=tonumber(self.store:get("cover_quality_version",0)) or 0
    if cover_quality_version<2 then
        local cleared,clear_error=pcall(self.library.clear_covers,self.library)
        if not cleared then logger.warn("[MiuRead][Cover] quality cache reset failed",tostring(clear_error or "unknown")) end
        self.store:set("cover_quality_version",2)
    end
    self.access=Access:new(self.library,self.api,self.reader,self.store)
    self.async=Async:new(self.store,{allow_android=true,disable_fallback=true})
    self.mp_async=Async:new(self.store,{poll_interval=.35,allow_android=true})
    self.search_async=Async:new(self.store,{poll_interval=.4,allow_android=true})
    self.shelf_async=Async:new(self.store,{poll_interval=.4,allow_android=true})
    -- User-triggered network reads that used to run through UIManager must
    -- always stay off the UI thread. This worker is intentionally separate
    -- from sync/download/search workers so those lifecycles cannot block it.
    self.interactive_network_async=Async:new(self.store,{poll_interval=.30,allow_android=true,disable_fallback=true})
    self._interactive_network_generation=0
    self._interactive_network_key=nil
    self.cover_async=Async:new(self.store,{poll_interval=.30,allow_android=true})
    self.identity_async=Async:new(self.store,{poll_interval=.20,allow_android=true,
        disable_fallback=true})
    self.repair_async=Async:new(self.store,{poll_interval=.35,allow_android=true})
    self.annotation_async=Async:new(self.store,{poll_interval=.30,allow_android=true,disable_fallback=true})
    -- Update manifest/package network I/O must never occupy the UI loop.
    -- Installation itself stays foreground because it replaces the live plugin tree.
    self.updater_async=Async:new(self.store,{poll_interval=.30,allow_android=true,disable_fallback=true})
    -- Summary scans may touch one SQLite cache per annotated book. Keep them
    -- out of every home tap and pull-down path.
    self.sync_summary_async=Async:new(self.store,{poll_interval=.45,allow_android=true,disable_fallback=true})
    self._annotation_summary_cache=nil
    self._annotation_summary_cache_at=0
    self._home_sync_summary_task=nil
    if self:_home_enabled() then
        self.home_async=Async:new(self.store,{poll_interval=.45,allow_android=true,disable_fallback=true})
        -- Desktop-only workers are not created in plugin mode.
        self.local_browser_async=Async:new(self.store,{poll_interval=.20,allow_android=true,disable_fallback=true})
        self.home_metadata_async=Async:new(self.store,{poll_interval=.35,allow_android=true,disable_fallback=true})
        self.home_cover_async=Async:new(self.store,{poll_interval=.30,allow_android=true})
        -- High-quality cover conversion must never run on the UI thread.
        self.cover_render_async=Async:new(self.store,{poll_interval=.35,allow_android=true,disable_fallback=true})
    else
        self.home_async=nil
        self.local_browser_async=nil
        self.home_metadata_async=nil
        self.home_cover_async=nil
        self.cover_render_async=nil
    end
    self.auth_flow=Auth:new(self.http,self.store,self)
    self.sync=Sync:new(self.reader,self.api,self.store,self,self.async,self.identity_async)
    self.updater=Updater:new(self.http,self.store,self.version,ROOT)
    self._suspended_at=nil
    self._cover_generation=0
    self._cover_refresh_task=nil
    self._cover_index_pending={}
    self._cover_index_flush_task=nil
    self._cover_safe_mode=false
    self._cover_safe_notice_shown=false
    self._shelf_view=nil
    self._last_shelf_mode=false
    self._last_shelf_section="account"
    self._shelf_refresh_generation=0
    self._shelf_main_busy=false
    self._downloads_menu=nil
    self._download_book_menu=nil
    self._cache_cleanup_dialog=nil
    self._download_runtime=nil
    self._download_state_last_write=0
    self._download_state_last_stage=nil
    self._auth_notice_dialog=nil
    self._sync_success_notified=false
    self._home_view=nil
    self._home_scan_generation=0
    self._home_refreshing=false
    self._home_start_generation=0
    self._home_reader_transition=false
    self._home_metadata_generation=0
    self._home_cover_generation=0
    self._home_sections=nil
    self._home_visible_keys=nil
    self._home_active_section=nil
    self._home_hero=nil
    self._home_remote_refreshing=false
    self._home_render_refresh_task=nil
    self._home_render_refresh_generation=0
    self._home_refresh_debounce_generation=0
    self._home_state_save_generation=0
    self._home_state_save_pending=false
    self._home_interaction_generation=tonumber(HOME_SESSION.home_interaction_generation) or 0
    self._home_data_revision=0
    self._home_section_revisions={account=0,generated=0,["local"]=0,mp=0}
    self._home_directory_generation=0
    self._home_directory_active_path=nil
    self._home_directory_request_owner=nil
    self._local_browser_fallback_task=nil
    self._local_browser_fallback_scanner=nil
    self._home_inline_navigation_generation=0
    self._home_cover_inflight={}
    self._home_cover_render_generation=0
    self._home_cover_render_retry_task=nil
    self._home_suspended=false
    self._home_resume_generation=0
    self._home_resume_barrier=false
    self._home_resume_first_frame=false
    self._home_resume_background_task=nil
    self._home_resume_pending_kind=nil
    self._home_resume_pending_work=nil
    self._home_resume_started_clock=nil
    self._home_resume_sleep_seconds=0
    self._home_resume_surface_task=nil
    self._reader_rebuild_task=nil
    self._reader_dimension_event_count=0
    self._reader_dimension_last_event_clock=0
    self._resume_lifecycle_generation=0
    if HOME_SESSION.page_transition_state==nil then HOME_SESSION.page_transition_state="idle" end
    if HOME_SESSION.page_transition_generation==nil then HOME_SESSION.page_transition_generation=0 end
    self._page_transition_state=tostring(HOME_SESSION.page_transition_state or "idle")
    self._page_transition_generation=tonumber(HOME_SESSION.page_transition_generation) or 0
    self._page_transition_release_task=nil
    self._download_resume_generation=0
    self._download_resume_task=nil

    if not self._reader_context then
        local guard=self.store:cover_guard()
        local guard_age=os.time()-(tonumber(guard.started_at) or 0)
        if guard.active==true and guard_age>=0 and guard_age<COVER_GUARD_WINDOW then
            self._cover_safe_mode=true
            logger.warn("[MiuRead][Cover] previous render did not finish; safe shelf mode enabled",
                "stage=",tostring(guard.stage or ""),"age=",tostring(guard_age))
        end
        if guard.active==true then
            self.store:save_cover_guard({active=false,started_at=0,stage="",version=Config.VERSION})
        end

        local startup_download_state=self.store:download_state()
        if startup_download_state.status=="completed" then self.store:clear_download_state() end
        local recovered=self:_recover_download_state()
        if not recovered then UIManager:scheduleIn(1.0,function() self:_start_next_queued_download() end) end
    end
    Actions.register()
    if self:_home_enabled() then install_home_screensaver_patch() end
    if self:_home_enabled() and not DIRECT_MENU_INSERTED then
        local ok_insert, inserter = pcall(require, "ui/plugin/insert_menu")
        if ok_insert and inserter and type(inserter.add) == "function" then
            pcall(inserter.add, "miuread_return_home_direct")
        end
        DIRECT_MENU_INSERTED = true
    end
    self.ui.menu:registerToMainMenu(self)
    if self._reader_context and self:_home_enabled() then self:_install_reader_home_bridge() end
    if not self._reader_context then
        local state=self.updater:startup()
        if state=="updated" then
            UIManager:scheduleIn(1,function() self:status_toast("更新完成","当前运行版本 "..tostring(self.version),4) end)
        elseif state=="mismatch" then
            UIManager:scheduleIn(1,function() self:info("更新文件已经替换，但当前运行版本与目标版本不一致。\n\n请完整退出并重新启动 KOReader。\n当前运行："..tostring(self.version)) end)
        end
        UIManager:scheduleIn(.8,function() if not self:_current_document_path() then self:_install_pending_downloads(false) end end)
        UIManager:scheduleIn(1.4,function() self:_show_auth_notice() end)
        UIManager:scheduleIn(5.0,function() self:maybe_auto_check_update(false) end)
        -- Mode guidance is never a startup gate. Reveal the selected runtime
        -- surface first, then show guidance only when a fresh install or an
        -- explicit user-requested mode switch armed it.
        if self:_home_enabled() and not Session.home().suppressed then
            self:_schedule_home_startup(.65)
        end
        if self:_mode_intro_needed() then
            self:_schedule_mode_intro_after_surface(.85)
        end
    end
end

function Plugin:addToMainMenu(items)
    if self.ui and self.ui.document and self:_home_enabled() then
        items.miuread_return_home_direct={
            text="退出阅读并返回觅阅主页",
            sorting_hint="tools",
            callback=self:safe("return-home-direct",function() self:return_to_miuread_home() end),
        }
    elseif not (self.ui and self.ui.document) and self:_home_enabled() then
        -- FileManager caches its menu table. Register this recovery entry
        -- unconditionally while MiuRead home mode is enabled; checking
        -- Session.home().native_visit here made the item disappear when the menu table
        -- had been built before the temporary native visit started.
        items.miuread_return_home_direct={
            text="返回觅阅主页",
            sorting_hint="tools",
            callback=self:safe("return-home-direct",function() self:_return_from_native_filemanager() end),
        }
    end
    items.miuread={
        text=Config.NAME,
        sorting_hint="tools",
        sub_item_table_func=function()
            if self:_home_enabled() then
                return self.ui.document and self:reader_menu() or self:home_menu()
            end
            return self.ui.document and PluginMenu.reader(self) or PluginMenu.home(self)
        end,
    }
end
function Plugin:info(t)
    TransientGuard.close_all()
    UIManager:show(InfoMessage:new{text=tostring(t or "")})
end
function Plugin:toast(t,s) UIManager:show(InfoMessage:new{text=tostring(t or ""),timeout=s or 2}) end
function Plugin:status_toast(title,text,timeout)
    local ok,err=pcall(StatusToast.show,{
        title=tostring(title or ""),
        text=tostring(text or ""),
        timeout=timeout or 3,
    })
    if not ok then
        logger.warn("[MiuRead] status toast failed",tostring(err))
        self:toast(tostring(title or "").." · "..tostring(text or ""):gsub("%s+"," "),timeout or 3)
    end
end
function Plugin:_original_weread_plugin_present()
    local plugins_root=ROOT:match("^(.*)/[^/]+$") or "."
    return lfs.attributes(plugins_root.."/weread.koplugin","mode")=="directory"
end
function Plugin:_begin_cover_guard(stage)
    self.store:save_cover_guard({
        active=true,
        started_at=os.time(),
        stage=tostring(stage or "shelf"),
        version=Config.VERSION,
    })
end
function Plugin:_clear_cover_guard()
    local guard=self.store:cover_guard()
    if guard.active==true then
        self.store:save_cover_guard({active=false,started_at=0,stage="",version=Config.VERSION})
    end
end
function Plugin:_shelf_covers_enabled(prefs)
    prefs=prefs or self.store:preferences()
    local enabled=prefs.shelf_covers~=false
    if enabled and self._cover_safe_mode then
        if not self._cover_safe_notice_shown then
            self._cover_safe_notice_shown=true
            self:toast("检测到上次封面加载异常，本次已使用安全书架模式。",4)
        end
        return false
    end
    return enabled
end
function Plugin:safe(label,fn) return function(...) local a={...}; local ok,e=xpcall(function() return fn(unpack_args(a)) end,debug.traceback); if not ok then logger.err("[MiuRead]",label,e); self:info(_("Operation failed")..":\n"..U.first_line(e)) end end end
function Plugin:is_online() local ok,N=pcall(require,"ui/network/manager"); if not ok or not N or not N.isOnline then return true end; local g,v=pcall(N.isOnline,N); return not g or v==true end
function Plugin:online(label,fn) if not self:is_online() then self:info(_("Network unavailable")); return end; UIManager:scheduleIn(.05,self:safe(label,fn)) end

local function interactive_child_store(auth,data_dir,temp_dir)
    local current=U.copy(type(auth)=="table" and auth or {})
    local changed=false
    local store={data_dir=tostring(data_dir or ""),temp_dir=tostring(temp_dir or "")}
    function store:auth() return U.copy(current) end
    function store:save_auth(value) current=U.copy(type(value)=="table" and value or {}); changed=true end
    function store:snapshot() return U.copy(current),changed end
    return store
end

function Plugin:_interactive_network_context()
    return {
        reader_file=normalized_reader_file(self:_current_document_path()),
        reader_generation=tonumber(HOME_SESSION.reader_session_generation) or 0,
        home_shown=HomeView.is_shown()==true,
        home_section=tostring(self._home_active_section or ""),
    }
end

function Plugin:_interactive_network_context_valid(context)
    context=type(context)=="table" and context or {}
    if self._miuread_suspended==true or HOME_SESSION.suspended==true or Session.home_exiting() then return false end
    local current_file=normalized_reader_file(self:_current_document_path())
    if context.reader_file then
        return current_file==context.reader_file
            and tonumber(HOME_SESSION.reader_session_generation or 0)==tonumber(context.reader_generation or 0)
    end
    if current_file then return false end
    if context.home_shown then
        return HomeView.is_shown()==true and tostring(self._home_active_section or "")==tostring(context.home_section or "")
    end
    return true
end

function Plugin:_apply_interactive_auth(snapshot)
    if type(snapshot)~="table" or snapshot.changed~=true or type(snapshot.auth)~="table" then return false end
    local current=self.store:auth()
    local incoming=snapshot.auth
    local current_session=tostring(current.login_session_id or "")
    local incoming_session=tostring(incoming.login_session_id or "")
    if current_session=="" or incoming_session=="" or current_session~=incoming_session then
        logger.warn("[MiuRead][NetTask] ignored stale auth snapshot")
        return false
    end
    local current_vid=tostring((current.account or {}).vid or (current.cookies or {}).wr_vid or "")
    local incoming_vid=tostring((incoming.account or {}).vid or (incoming.cookies or {}).wr_vid or "")
    if current_vid~="" and incoming_vid~="" and current_vid~=incoming_vid then
        logger.warn("[MiuRead][NetTask] ignored cross-account auth snapshot")
        return false
    end
    self.store:save_auth(incoming)
    return true
end

function Plugin:_cancel_interactive_network(reason)
    self._interactive_network_generation=(tonumber(self._interactive_network_generation) or 0)+1
    self._interactive_network_key=nil
    if self.interactive_network_async then self.interactive_network_async:cancel(reason or "cancelled") end
    return true
end

function Plugin:_run_interactive_network(key,label,worker,callback,options)
    options=type(options)=="table" and options or {}
    key=tostring(key or label or "interactive")
    label=tostring(label or key)
    if not self:is_online() then
        if options.silent~=true then self:info(_("Network unavailable")) end
        return false,"offline"
    end
    local async=self.interactive_network_async
    if not async or not async:available() then
        if options.silent~=true then self:info("当前设备暂时无法启动后台网络任务，请稍后重试。") end
        return false,"background worker unavailable"
    end
    if async:busy() then
        if tostring(self._interactive_network_key or "")==key then
            if options.silent~=true then self:toast("该网络请求正在进行中",2) end
            return false,"duplicate request"
        end
        self:_cancel_interactive_network("superseded by "..key)
    end
    self._interactive_network_generation=(tonumber(self._interactive_network_generation) or 0)+1
    local generation=self._interactive_network_generation
    self._interactive_network_key=key
    local context=options.context or self:_interactive_network_context()
    local started_at=monotonic_wall_time()
    if options.status_title and options.status_text and options.silent~=true then
        self:status_toast(options.status_title,options.status_text,tonumber(options.status_seconds) or 2)
    end
    logger.info("[MiuRead][NetTask] started","key=",key)
    local started,err=async:run(label,worker,function(result)
        if generation~=self._interactive_network_generation then return end
        self._interactive_network_key=nil
        local network_ms=math.floor((monotonic_wall_time()-started_at)*1000+.5)
        if not self:_interactive_network_context_valid(context) then
            logger.info("[MiuRead][NetTask] stale result dropped","key=",key,"network_ms=",tostring(network_ms))
            return
        end
        local callback_started=monotonic_wall_time()
        if callback then callback(result) end
        local callback_ms=math.floor((monotonic_wall_time()-callback_started)*1000+.5)
        logger.info("[MiuRead][NetTask] completed","key=",key,
            "network_ms=",tostring(network_ms),"callback_ms=",tostring(callback_ms),
            "ok=",tostring(result and result.ok==true))
    end,tonumber(options.timeout) or 35)
    if not started then
        if generation==self._interactive_network_generation then self._interactive_network_key=nil end
        if options.silent~=true then self:info("无法启动后台网络任务：\n"..tostring(err or "未知错误")) end
        return false,err
    end
    return true
end

function Plugin:_request_catalog(book,label,on_ready,options)
    options=type(options)=="table" and options or {}
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if id=="" then return false,"missing book id" end
    local auth=U.copy(self.store:auth())
    local data_dir,temp_dir=self.store.data_dir,self.store.temp_dir
    label=tostring(label or "catalog")
    local key="catalog:"..id..":"..label
    return self:_run_interactive_network(key,label,function()
        local HttpChild=require("miuread.http")
        local ReaderChild=require("miuread.reader")
        local DownloaderChild=require("miuread.downloader")
        local child_store=interactive_child_store(auth,data_dir,temp_dir)
        local child_http=HttpChild:new(child_store)
        local child_reader=ReaderChild:new(child_http,child_store)
        local child_downloader=DownloaderChild:new(child_reader,nil,nil,child_store,child_http)
        local request_ok,catalog,rows=pcall(child_downloader.catalog,child_downloader,id)
        local child_auth,auth_changed=child_store:snapshot()
        return {request_ok=request_ok,rows=request_ok and rows or nil,
            error=request_ok and nil or tostring(catalog),auth=child_auth,auth_changed=auth_changed}
    end,function(result)
        if not result or result.ok~=true then
            local message=result and result.error or "章节目录加载失败"
            if options.on_error then options.on_error(message)
            elseif options.silent~=true then self:info(self:_friendly_remote_error(message,"章节目录加载")) end
            return
        end
        local payload=type(result.value)=="table" and result.value or {}
        if payload.auth_changed==true then self:_apply_interactive_auth{auth=payload.auth,changed=true} end
        if payload.request_ok~=true then
            local message=tostring(payload.error or "章节目录加载失败")
            if options.on_error then options.on_error(message)
            elseif options.silent~=true then self:info(self:_friendly_remote_error(message,"章节目录加载")) end
            return
        end
        if on_ready then on_ready(type(payload.rows)=="table" and payload.rows or {}) end
    end,{
        context=options.context,timeout=tonumber(options.timeout) or 45,silent=options.silent,
        status_title=options.status_title or "章节",
        status_text=options.status_text or "正在后台读取章节目录…",
        status_seconds=2,
    })
end

function Plugin:_wait_for_network(label,callback,options)
    options=options or {}
    self._network_wait_tokens=self._network_wait_tokens or {}
    label=tostring(label or "default")
    local token=(tonumber(self._network_wait_tokens[label]) or 0)+1
    self._network_wait_tokens[label]=token
    local started=os.time()
    local minimum=math.max(0,tonumber(options.minimum_delay) or 0)
    local maximum=math.max(minimum+1,tonumber(options.max_wait) or 45)
    local interval=math.max(.5,tonumber(options.interval) or 2)
    local function check()
        if not self._network_wait_tokens or self._network_wait_tokens[label]~=token then return end
        local elapsed=os.time()-started
        if elapsed>=minimum and self:is_online() then
            self._network_wait_tokens[label]=nil
            callback(true)
            return
        end
        if elapsed>=maximum then
            self._network_wait_tokens[label]=nil
            callback(false)
            return
        end
        UIManager:scheduleIn(interval,check)
    end
    UIManager:scheduleIn(math.max(.1,tonumber(options.initial_delay) or .1),check)
    return token
end
function Plugin:_cancel_network_waits()
    self._network_wait_tokens={}
end

function Plugin:list(title,items,empty)
    if not items or #items==0 then self:info(empty or _("No items")); return end
    -- When MiuRead home owns the foreground, keep MiuRead-origin lists inside
    -- the MiuRead visual language. Native KOReader lists are still used in
    -- ReaderUI/FileManager contexts and for genuinely native system pages.
    if HomeView.is_shown() and not self:_active_reader_ui() then
        return self:_show_standalone_menu(title,items)
    end
    for _, item in ipairs(items) do
        if type(item)=="table" and (item.sub_item_table_func or item.sub_item_table) then
            return self:_show_standalone_menu(title,items)
        end
    end
    TransientGuard.close_all()
    local menu=Menu:new{title=title,item_table=items,is_borderless=true,title_bar_fm_style=true}
    UIManager:show(menu)
    return menu
end
function Plugin:logged_in()
    local a=self.store:auth()
    return tostring(a.api_key or "")~="" and next(a.cookies or {})~=nil
end
function Plugin:require_login()
    if not self:logged_in() then
        self:info(_("Not logged in"))
        return false
    end
    return true
end

local AUTH_CHANNEL_LABELS={
    shelf="书架访问",progress="云端进度读取",download="正文下载",
    annotations="划线与想法访问",read_report="阅读时间上传",
}
local AUTH_CHANNEL_ORDER={"shelf","progress","download","annotations","read_report"}
local function auth_error_code(value)
    if Http.auth_error_code then
        local ok,code=pcall(Http.auth_error_code,value)
        if ok and code then return tostring(code) end
    end
    local text=tostring(value or "")
    return text:match("error_code=([%-]?%d+)") or text:match('"errcode"%s*:%s*([%-]?%d+)') or ""
end
local function auth_row(value)
    return U.merge({state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0,last_ok_at=0},
        type(value)=="table" and value or {})
end
function Plugin:_auth_health()
    if self.store.auth_health then return self.store:auth_health() end
    local auth=self.store:auth()
    return U.merge({state="unknown",last_checked_at=0,last_ok_at=0,last_error_at=0,
        last_error_code="",last_error_message="",last_error_channel="",notice_pending=false,channels={}},auth.health or {})
end
function Plugin:_save_auth_health(health)
    local auth=self.store:auth()
    auth.health=health
    self.store:save_auth(auth)
    return health
end
function Plugin:_recompute_auth_health(health)
    health.channels=health.channels or {}
    if not self:logged_in() then health.state="logged_out"; return health end
    local partial,unknown=false,false
    for _,channel in ipairs(AUTH_CHANNEL_ORDER) do
        local state=tostring(auth_row(health.channels[channel]).state)
        if state=="expired" or state=="error" then partial=true
        elseif state~="ok" then unknown=true end
    end
    health.state=partial and "partial" or (unknown and "unknown" or "ok")
    return health
end
function Plugin:_mark_auth_channel_ok(channel)
    if not self:logged_in() then return end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    health.channels[channel]={state="ok",checked_at=now,error="",code="",failures=0,retry_at=0,last_ok_at=now}
    health.last_checked_at=now
    health.last_ok_at=now
    self:_recompute_auth_health(health)
    if health.state=="ok" then
        health.last_error_at=0
        health.last_error_code=""
        health.last_error_message=""
        health.last_error_channel=""
        health.notice_pending=false
    end
    self:_save_auth_health(health)
end
function Plugin:_mark_auth_channel_error(channel,err,retry_at)
    if not self:logged_in() then return end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    local previous=auth_row(health.channels[channel])
    health.channels[channel]={state="error",checked_at=now,error=U.first_line(err,180),code="",
        failures=(tonumber(previous.failures) or 0)+1,retry_at=tonumber(retry_at) or 0,last_ok_at=previous.last_ok_at or 0}
    health.last_checked_at=now
    health.last_error_at=now
    health.last_error_message=U.first_line(err,220)
    health.last_error_channel=channel
    self:_recompute_auth_health(health)
    self:_save_auth_health(health)
end
function Plugin:_mark_auth_access_denied(channel,err,notify)
    if not self:logged_in() then return false end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    local previous=auth_row(health.channels[channel])
    local failures=(tonumber(previous.failures) or 0)+1
    local threshold=math.max(1,tonumber(Config.AUTH_NOTICE_FAILURE_THRESHOLD) or 2)
    local confirmed=failures>=threshold
    local message=U.first_line(err or "HTTP 403",220)
    health.channels[channel]={state=confirmed and "expired" or "error",checked_at=now,
        error=U.first_line(message,180),code="403",failures=failures,retry_at=0,
        last_ok_at=previous.last_ok_at or 0}
    health.last_checked_at=now
    health.last_error_at=now
    health.last_error_code="403"
    health.last_error_message=message
    health.last_error_channel=channel
    if notify~=false and confirmed then health.notice_pending=true end
    self:_recompute_auth_health(health)
    self:_save_auth_health(health)
    logger.warn("[MiuRead][Auth] feature access denied",
        "channel=",tostring(channel),"failures=",tostring(failures),"confirmed=",tostring(confirmed),
        "error=",U.first_line(message,160))
    if health.notice_pending then UIManager:scheduleIn(.05,function() self:_show_auth_notice() end) end
    return true
end
function Plugin:_mark_auth_problem(channel,err,notify)
    local text=tostring(err or "登录状态暂时不可用")
    if not Http.is_auth_error(text) then return false end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    local previous=auth_row(health.channels[channel])
    local threshold=math.max(1,tonumber(Config.AUTH_NOTICE_FAILURE_THRESHOLD) or 2)
    local failures=(tonumber(previous.failures) or 0)+1
    local confirmed=text:find("自动续期失败",1,true)~=nil
        or text:find("renewal=",1,true)~=nil
        or text:find("refreshed=",1,true)~=nil
    if confirmed then failures=math.max(failures,threshold) end
    local expired=failures>=threshold
    local code=auth_error_code(text)
    health.channels[channel]={state=expired and "expired" or "error",checked_at=now,
        error=U.first_line(text,180),code=code,failures=failures,retry_at=0,last_ok_at=previous.last_ok_at or 0}
    health.last_checked_at=now
    health.last_error_at=now
    health.last_error_code=code
    health.last_error_message=U.first_line(text,220)
    health.last_error_channel=channel
    if notify~=false and expired then health.notice_pending=true end
    self:_recompute_auth_health(health)
    self:_save_auth_health(health)
    logger.warn("[MiuRead][Auth] feature request authentication failed",
        "channel=",tostring(channel),"code=",tostring(code),"failures=",tostring(failures),
        "confirmed=",tostring(confirmed),"error=",U.first_line(text,160))
    if health.notice_pending then UIManager:scheduleIn(.05,function() self:_show_auth_notice() end) end
    return true
end
function Plugin:_clear_auth_notice_pending()
    local health=self:_auth_health()
    if health.notice_pending~=false then
        health.notice_pending=false
        self:_save_auth_health(health)
    end
end
function Plugin:_show_auth_notice()
    if self._auth_notice_dialog or not self:logged_in() then return end
    local health=self:_auth_health()
    if health.notice_pending~=true then return end
    local channel_key=tostring(health.last_error_channel or "")
    local channel=AUTH_CHANNEL_LABELS[channel_key] or "在线功能"
    local annotation_forbidden=channel_key=="annotations" and tostring(health.last_error_code or "")=="403"
    local notice_text=annotation_forbidden
        and "正文下载仍可使用，但划线与想法接口连续拒绝访问。插件已保留正文、已有批注和下载断点。请重新扫码后再次生成书籍。"
        or "只有此功能受到影响，其他功能会继续运行。插件会保留下载断点和待上传阅读时间，并在后续真实请求中自动重试。多次失败后可重新扫码。"
    local dialog
    local function close()
        if self._auth_notice_dialog==dialog then self._auth_notice_dialog=nil end
        UIManager:close(dialog)
    end
    dialog=ButtonDialog:new{
        title=channel.."暂时异常\n\n"..notice_text,
        title_align="center",
        buttons={
            {{text="查看账号状态",callback=function()
                self:_clear_auth_notice_pending(); close(); self:show_account_status()
            end}},
            {{text="重新扫码",callback=function()
                self:_clear_auth_notice_pending(); close(); self.auth_flow:start()
            end}},
            {{text="稍后处理",callback=function()
                self:_clear_auth_notice_pending(); close()
            end}},
        },
    }
    self._auth_notice_dialog=dialog
    UIManager:show(dialog)
end
function Plugin:_account_status_label()
    if not self:logged_in() then return "未登录 · 点击扫码" end
    local auth=self.store:auth()
    local health=self:_auth_health()
    self:_recompute_auth_health(health)
    local name=U.trim(tostring((auth.account or {}).name or ""))
    if health.state=="partial" then
        return name~="" and ("部分功能异常 · "..name) or "部分功能异常 · 点击查看"
    end
    if health.state~="ok" then
        return name~="" and ("已登录 · "..name) or "已登录 · 功能待验证"
    end
    return name~="" and ("已登录 · "..name) or "已登录"
end
local function account_channel_text(row)
    row=auth_row(row)
    local state=tostring(row.state or "unknown")
    if state=="ok" then return "正常" end
    if state=="expired" then return "多次验证失败，可重新扫码" end
    if state=="error" then
        local retry_at=tonumber(row.retry_at or 0) or 0
        return retry_at>os.time() and "暂时失败，等待自动重试" or "暂时失败"
    end
    return "将在实际使用时验证"
end
function Plugin:_account_details_text()
    local auth=self.store:auth()
    local health=self:_auth_health()
    self:_recompute_auth_health(health)
    local name=U.trim(tostring((auth.account or {}).name or ""))
    local lines={"账号状态","","账号："..(name~="" and name or "—")}
    if not self:logged_in() then
        lines[#lines+1]="基础登录：尚未登录"
        return table.concat(lines,"\n")
    end
    lines[#lines+1]="基础登录：正常"
    lines[#lines+1]="在线功能："..(health.state=="ok" and "全部正常" or (health.state=="partial" and "部分暂时异常" or "等待实际使用验证"))
    lines[#lines+1]=""
    for _,channel in ipairs(AUTH_CHANNEL_ORDER) do
        lines[#lines+1]=AUTH_CHANNEL_LABELS[channel].."："..account_channel_text((health.channels or {})[channel])
    end
    lines[#lines+1]=""
    lines[#lines+1]="最后检查："..self:_relative_time(health.last_checked_at)
    if tonumber(health.last_error_at or 0)>0 then
        local channel=AUTH_CHANNEL_LABELS[tostring(health.last_error_channel or "")] or "在线功能"
        local code=tostring(health.last_error_code or "")
        lines[#lines+1]="最近异常："..channel..(code~="" and ("（"..code.."）") or "")
    end
    local sync_status=self.sync and self.sync:status() or {}
    local pending=math.max(0,math.floor(tonumber(sync_status.pending_report_elapsed or 0) or 0))
    if pending>0 then lines[#lines+1]="待上传阅读时间："..tostring(pending).." 秒" end
    lines[#lines+1]=""
    lines[#lines+1]="续期只用于失败后的恢复，不再作为下载或上传的前置条件。"
    return table.concat(lines,"\n")
end
function Plugin:_set_all_auth_ok()
    if not self:logged_in() then return end
    local now=os.time()
    local okrow={state="ok",checked_at=now,error="",code="",failures=0,retry_at=0,last_ok_at=now}
    local health=self:_auth_health()
    health.state="ok"
    health.last_checked_at=now
    health.last_ok_at=now
    health.last_error_at=0
    health.last_error_code=""
    health.last_error_message=""
    health.last_error_channel=""
    health.notice_pending=false
    health.channels={
        shelf=U.copy(okrow),progress=U.copy(okrow),download=U.copy(okrow),
        annotations=U.copy(okrow),read_report=U.copy(okrow),
    }
    self:_save_auth_health(health)
end
function Plugin:check_account_status()
    if not self:logged_in() then self.auth_flow:start(); return end
    local auth=U.copy(self.store:auth())
    local data_dir,temp_dir=self.store.data_dir,self.store.temp_dir
    local context=self:_interactive_network_context()
    self:_run_interactive_network("account-status","account-status-check",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local child_store=interactive_child_store(auth,data_dir,temp_dir)
        local child_api=ApiChild:new(HttpChild:new(child_store),child_store)
        local ok,value=pcall(child_api.shelf,child_api,{retries=0,timeout={7,12}})
        local child_auth,auth_changed=child_store:snapshot()
        return {request_ok=ok,value=ok and value or nil,error=ok and nil or tostring(value),
            auth=child_auth,auth_changed=auth_changed}
    end,function(result)
        if not result or result.ok~=true then
            self:_mark_auth_channel_error("shelf",result and result.error or "账号检查失败")
            self:show_account_status()
            return
        end
        local payload=type(result.value)=="table" and result.value or {}
        if payload.auth_changed==true then self:_apply_interactive_auth{auth=payload.auth,changed=true} end
        if payload.request_ok==true then
            self:_mark_auth_channel_ok("shelf")
        elseif Http.is_auth_error(payload.error) then
            self:_mark_auth_problem("shelf",payload.error,false)
        else
            self:_mark_auth_channel_error("shelf",payload.error or "账号检查失败")
        end
        self:show_account_status()
    end,{context=context,timeout=24,status_title="账号状态",status_text="正在后台检查基础账号和书架访问"})
end
function Plugin:confirm_logout()
    if not self:logged_in() then self:toast("当前没有登录微信读书账号",3); return end
    local downloading=self.download_task and self.download_task:busy()
    local text="退出当前微信读书账号？\n\n已下载书籍、本地阅读记录和下载断点都会保留。"
    if downloading then text=text.."\n\n当前下载会停止；重新登录后可从断点继续。" end
    UIManager:show(ConfirmBox:new{text=text,ok_text="退出登录",ok_callback=function()
        if downloading and self.download_task then self.download_task:cancel() end
        self.auth_flow:cancel()
        self:_cancel_interactive_network("logout")
        self._auth_transitioning=true
        if self.sync and self.sync.invalidate_login_session then
            pcall(self.sync.invalidate_login_session,self.sync,"logout")
        end
        if self.store.clear_login_bound_sessions then self.store:clear_login_bound_sessions("logout") end
        if self.store.clear_account_shelf_cache then self.store:clear_account_shelf_cache() end
        self.store:clear_auth()
        self._auth_transitioning=false
        self:status_toast("账号","已退出登录",4)
    end})
end

function Plugin:on_auth_replacing(_old_auth,_new_auth)
    self:_cancel_interactive_network("auth replacing")
    self._auth_transitioning=true
    if self.sync and self.sync.invalidate_login_session then
        self.sync:invalidate_login_session("new_login")
    end
    if self.store.clear_login_bound_sessions then self.store:clear_login_bound_sessions("new_login") end
    if self.store.clear_account_shelf_cache then self.store:clear_account_shelf_cache() end
end

function Plugin:show_account_status()
    if HomeView.is_shown() and not self:_active_reader_ui() then
        local auth=self.store:auth()
        local health=self:_auth_health(); self:_recompute_auth_health(health)
        local account=type(auth.account)=="table" and auth.account or {}
        local name=U.trim(tostring(account.name or ""))
        local rows={
            {text="账号",post_text=name~="" and name or "—",enabled=false},
            {text="基础登录",post_text=self:logged_in() and "正常" or "尚未登录",enabled=false},
        }
        if self:logged_in() then
            local online_label=health.state=="ok" and "全部正常" or (health.state=="partial" and "部分暂时异常" or "等待实际使用验证")
            rows[#rows+1]={text="在线功能",post_text=online_label,enabled=false}
            for _,channel in ipairs(AUTH_CHANNEL_ORDER) do
                rows[#rows+1]={text=AUTH_CHANNEL_LABELS[channel],post_text=account_channel_text((health.channels or {})[channel]),enabled=false}
            end
            rows[#rows+1]={text="最后检查",post_text=self:_relative_time(health.last_checked_at),enabled=false}
            rows[#rows+1]={text="账号操作",separator=true,enabled=false}
            rows[#rows+1]={text="重新检查状态",callback=function() self:check_account_status() end}
            rows[#rows+1]={text="重新扫码登录",callback=function() self.auth_flow:start() end}
            rows[#rows+1]={text="退出登录",callback=function() self:confirm_logout() end}
        else
            rows[#rows+1]={text="账号操作",separator=true,enabled=false}
            rows[#rows+1]={text="扫码登录",callback=function() self.auth_flow:start() end}
        end
        return self:_show_miuread_menu("账号状态",rows,{page_size=7})
    end

    local dialog
    local buttons={}
    if self:logged_in() then
        buttons[#buttons+1]={{text="重新检查状态",callback=function() UIManager:close(dialog); self:check_account_status() end}}
        buttons[#buttons+1]={{text="重新扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}}
        buttons[#buttons+1]={{text="退出登录",callback=function()
            UIManager:close(dialog); self:confirm_logout()
        end}}
    else
        buttons[#buttons+1]={{text="扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}}
    end
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=self:_account_details_text(),title_align="left",buttons=buttons}
    UIManager:show(dialog)
end

function Plugin:on_auth_success(name)
    self._auth_transitioning=false
    local health=self:_auth_health()
    local web_ready=(((health.channels or {}).download or {}).state=="ok")
    if self._auth_notice_dialog then
        pcall(function() UIManager:close(self._auth_notice_dialog) end)
        self._auth_notice_dialog=nil
    end
    local resumed=false
    local state=self.store:download_state()
    if state.status=="failed" and state.auth_required==true and type(state.book)=="table" then
        state.status="interrupted"
        state.error="登录已恢复，正在继续下载。"
        state.auth_required=nil
        state.updated_at=os.time()
        self.store:save_download_state(state)
        local book,options=U.copy(state.book),U.copy(state.options or {})
        UIManager:scheduleIn(1.0,function()
            if not self._download_runtime and not (self.download_task and self.download_task:busy()) then
                self:download(book,options,false,nil,true)
            end
        end)
        resumed=true
    else
        UIManager:scheduleIn(.8,function() self:_start_next_queued_download() end)
    end
    if self.sync and self.sync.on_auth_restored then
        local ok,value=pcall(self.sync.on_auth_restored,self.sync)
        resumed=resumed or (ok and value==true)
    end
    local title="账号登录成功"
    local detail=tostring(name or "微信读书账号")
        ..(resumed and " · 正在恢复后台任务" or (web_ready and "" or " · 在线功能将在实际使用时验证"))
    self:status_toast(title,detail,5)
end
function Plugin:_download_menu_text()
    if self:_has_download_status() then
        return "下载管理 · "..tostring(self:_download_status_label()):gsub("^后台下载%s*[：·]?%s*","")
    end
    local queue=self.store:download_queue()
    return #queue>0 and ("下载管理 · "..tostring(#queue).." 项等待") or "下载管理"
end
function Plugin:_sync_menu_text()
    return "阅读同步 · "..tostring(self:progress_sync_label())
end
function Plugin:home_menu()
    self:maybe_auto_check_update(false)
    local account={text=self:_account_status_label(),callback=function() self:show_account_status() end}
    local out={}
    if self:_home_enabled() then
        out[#out+1]={text="返回觅阅主页",callback=self:safe("home-ui",function() self:_return_to_configured_home() end)}
    end
    out[#out+1]={text="我的书架",callback=self:safe("shelf",function() self:show_shelf(false,false,"account") end)}
    local trailing={
        {text="搜索书籍",callback=self:safe("search",function() self:search_dialog() end)},
        {text=self:_download_menu_text(),callback=self:safe("downloads",function() self:show_downloads() end)},
        {text=self:_sync_menu_text(),sub_item_table_func=function() return self:sync_menu() end},
        account,
        {text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end},
        {text="KOReader 菜单",callback=function() self:_show_native_koreader_menu() end},
    }
    for _,row in ipairs(trailing) do out[#out+1]=row end
    local health=self:_auth_health()
    self:_recompute_auth_health(health)
    if self:logged_in() and health.state=="partial" then
        for index,row in ipairs(out) do
            if row==account then table.remove(out,index); break end
        end
        table.insert(out,1,account)
    end
    return out
end

function Plugin:_confirm_current_book_rebuild(book,annotations)
    local label=annotations and "划线与想法版" or "纯净版"
    UIManager:show(ConfirmBox:new{
        text="重新生成当前书籍的"..label.."？\n\n新文件会在生成完成后替换对应版本。",
        ok_text="重新生成",
        cancel_text="取消",
        ok_callback=function() self:choose_download_mode(book,{annotations=annotations},false) end,
    })
end

function Plugin:current_book_download_menu(book)
    local items={
        {text="下载当前章",callback=function() self:download_current_chapters(1) end},
        {text="当前章及后续 5 章",callback=function() self:download_current_chapters(6) end},
        {text="当前章及后续 10 章",callback=function() self:download_current_chapters(11) end},
        {text="选择章节范围",callback=function() self:chapters(book) end},
    }
    if self:_has_range_variant(book.bookId) then
        items[#items+1]={text="扩展已有章节版",sub_item_table_func=function() return self:range_extend_menu(book) end}
    end
    return items
end

function Plugin:current_book_rebuild_menu(book)
    return {
        {text="重新生成纯净版",callback=function() self:_confirm_current_book_rebuild(book,false) end},
        {text="重新生成划线与想法版",callback=function() self:_confirm_current_book_rebuild(book,true) end},
    }
end

function Plugin:current_book_menu()
    local r=self:_current_book_record()
    if not r or not r.book then return {{text="未识别当前觅阅书籍",enabled=false}} end
    local b={bookId=r.book.book_id,title=r.book.title,author=r.book.author,cover=r.book.cover}
    return {
        {text="书籍详情",callback=function() self:book_details(b) end},
        {text="下载章节",sub_item_table_func=function() return self:current_book_download_menu(b) end},
        {text="重新生成",sub_item_table_func=function() return self:current_book_rebuild_menu(b) end},
        {text="管理本地文件",callback=function() self:downloaded_book_menu(tostring(b.bookId)) end},
    }
end

function Plugin:current_mp_article_menu(mp_context)
    local account={bookId=mp_context.bookId,title=mp_context.account_title or "公众号",author="公众号"}
    local target
    for _,article in ipairs(self.mp:cached_articles(mp_context.bookId) or {}) do
        if tostring(article.reviewId or article.originalId or "")==tostring(mp_context.reviewId or "") then
            target=article; break
        end
    end
    if not target then return {{text="当前文章信息不可用",enabled=false}} end
    local article=U.copy(target)
    return {
        {text="重新下载文章",callback=function() self:open_or_download_mp_article(account,article,true) end},
        {text="删除本篇缓存",callback=function()
            UIManager:show(ConfirmBox:new{text="删除《"..tostring(article.title or "文章").."》的本地缓存？",ok_callback=function()
                local ok,err=self.mp:clear_article(account.bookId,article)
                if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
                self:status_toast("公众号","本篇缓存已删除",4)
            end})
        end},
        {text="公众号缓存管理",sub_item_table_func=function() return self:mp_cache_menu(account,self.mp:cached_articles(account.bookId)) end},
    }
end

function Plugin:reader_menu()
    self:maybe_auto_check_update(false)
    local current_path=self:_current_document_path()
    local mp_context=self.mp and self.mp:identify_path(current_path) or nil
    if mp_context then
        local desktop=self:_home_enabled()
        local out={
            {text="返回文章列表",callback=self:safe("mp-back",function() self:open_mp_account_by_id(mp_context.bookId,mp_context.account_title) end)},
            {text="上一篇",callback=self:safe("mp-prev",function() self:open_mp_neighbor(-1) end)},
            {text="下一篇",callback=self:safe("mp-next",function() self:open_mp_neighbor(1) end)},
            {text="当前文章",sub_item_table_func=function() return self:current_mp_article_menu(mp_context) end},
        }
        if desktop then out[#out+1]={text="全部阅读功能",callback=function() self:show_reader_control_center("reading") end} end
        out[#out+1]={text=self:_download_menu_text(),callback=function() self:show_downloads() end}
        out[#out+1]={text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end}
        if not desktop then out[#out+1]={text="KOReader 菜单",callback=function() self:_show_koreader_reader_menu() end} end
        return out
    end
    local desktop=self:_home_enabled()
    local out={
        {text=desktop and "退出阅读并返回觅阅主页" or "返回书架",callback=self:safe("shelf",function()
            if desktop then self:return_to_miuread_home()
            else self:show_shelf(false,false,"account") end
        end)},
    }
    if desktop then
        out[#out+1]={text="全部阅读功能",callback=function() self:show_reader_control_center("reading") end}
    end
    out[#out+1]={text="当前书籍",sub_item_table_func=function() return self:current_book_menu() end}
    do
        local external_annotations_available=self:_external_annotations_menu_available()
        out[#out+1]={
            text="本地书划线与想法",
            post_text=external_annotations_available and nil or "仅支持本地重排书籍",
            enabled_func=function() return external_annotations_available end,
            sub_item_table_func=function() return self:external_annotations_menu_items() end,
        }
    end
    out[#out+1]={text=self:_sync_menu_text(),sub_item_table_func=function() return self:sync_menu() end}
    out[#out+1]={text=self:_download_menu_text(),callback=function() self:show_downloads() end}
    out[#out+1]={text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end}
    if not desktop then
        out[#out+1]={text="KOReader 菜单",callback=function() self:_show_koreader_reader_menu() end}
    end
    return out
end

function Plugin:account_menu()
    local out={
        {text="账号状态",callback=function() self:show_account_status() end},
        {text=self:logged_in() and "重新扫码登录" or "扫码登录",callback=self:safe("login",function() self.auth_flow:start() end)},
    }
    if self:logged_in() then
        out[#out+1]={text="退出登录",callback=function() self:confirm_logout() end}
    end
    return out
end

function Plugin:_toggle_home_lockscreen(confirmed)
    local home,preferences=self:_home_preferences()
    local enabling=home.lockscreen_recent==false
    if enabling and confirmed~=true and self:_notice_enabled("lockscreen") then
        local dialog
        dialog=ButtonDialog:new{title="锁屏封面需要生成和写入图片，关闭书籍或刷新主页时可能会稍慢。",title_align="center",buttons={
            {{text="开启",callback=function() UIManager:close(dialog); self:_toggle_home_lockscreen(true) end}},
            {{text="开启并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("lockscreen",false); self:_toggle_home_lockscreen(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
        return
    end
    home.lockscreen_recent=enabling
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(home.lockscreen_recent and "主页锁屏将显示最近阅读封面" or "已恢复 KOReader 原锁屏设置","header")
end

function Plugin:home_layout_settings_menu()
    local home=self:_home_preferences()
    return {
        {text="标准布局",post_text="继续阅读与分类书架",checked_func=function() return home.layout_style~="compact" end,callback=function()
            self:_set_home_layout("desk")
        end},
        {text="紧凑布局",post_text="缩小内容，适合旧设备",checked_func=function() return home.layout_style=="compact" end,callback=function()
            self:_set_home_layout("compact")
        end},
    }
end

function Plugin:_set_home_display_size(mode)
    if mode~="compact" and mode~="standard" and mode~="large" then mode="standard" end
    local home,preferences=self:_home_preferences()
    home.display_size=mode
    self:_save_home_preferences(home,preferences)
    local labels={compact="紧凑",standard="标准",large="大号"}
    self:_refresh_home_view("觅阅显示大小已切换为"..(labels[mode] or "标准"),"full")
end

function Plugin:home_display_size_menu()
    local labels={compact="紧凑",standard="标准",large="大号"}
    local details={compact="显示更多内容",standard="默认，适合多数设备",large="更大的文字与图标"}
    local rows={}
    for _,mode in ipairs({"compact","standard","large"}) do
        local key=mode
        rows[#rows+1]={
            text=labels[key],post_text=details[key],
            checked_func=function() return self:_home_preferences().display_size==key end,
            callback=function() self:_set_home_display_size(key) end,
        }
    end
    return rows
end

function Plugin:_home_ui_body_font_name()
    local doc=self.ui and self.ui.document
    if doc and type(doc.getFontFace)=="function" then
        local ok,value=pcall(doc.getFontFace,doc)
        value=ok and U.trim(tostring(value or "")) or ""
        if value~="" then return value end
    end
    local font=self.ui and self.ui.font
    local value=font and U.trim(tostring(font.font_face or "")) or ""
    if value~="" then return value end
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,saved=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font")
        saved=ok and U.trim(tostring(saved or "")) or ""
        if saved~="" then return saved end
    end
    return nil
end

function Plugin:_home_ui_font_name(home)
    home=type(home)=="table" and home or (self.store:preferences().home_ui or {})
    local mode=tostring(home.ui_font_mode or "default")
    if mode=="follow" then return self:_home_ui_body_font_name() end
    if mode=="custom" then
        local value=U.trim(tostring(home.ui_font_face or ""))
        return value~="" and value or nil
    end
    return nil
end

function Plugin:_home_ui_font_label(home)
    home=type(home)=="table" and home or self:_home_preferences()
    local mode=tostring(home.ui_font_mode or "default")
    if mode=="follow" then
        local name=self:_home_ui_body_font_name()
        return name and ("跟随正文 · "..name) or "跟随正文"
    end
    if mode=="custom" then
        local name=U.trim(tostring(home.ui_font_face or ""))
        return name~="" and name or "自定义字体"
    end
    return "界面默认"
end

function Plugin:_set_home_ui_font(mode,face)
    mode=tostring(mode or "default")
    if mode~="follow" and mode~="custom" then mode="default" end
    local home,preferences=self:_home_preferences()
    home.ui_font_mode=mode
    if face~=nil then home.ui_font_face=U.trim(tostring(face or "")) end
    if mode=="custom" and U.trim(tostring(home.ui_font_face or ""))=="" then
        home.ui_font_mode="default"
    end
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view("觅阅界面字体已更新","full")
    else self:toast("觅阅界面字体已更新",2) end
    return true
end

function Plugin:home_ui_font_face_menu()
    local rows={}
    local choices=self:_reader_font_face_choices()
    if #choices==0 then return {{text="未读取到可用正文字体",enabled=false}} end
    for _,choice in ipairs(choices) do
        local selected=tostring(choice.name or "")
        local label=tostring(choice.label or selected)
        rows[#rows+1]={
            text=label,
            checked_func=function()
                local home=self:_home_preferences()
                return home.ui_font_mode=="custom" and tostring(home.ui_font_face or "")==selected
            end,
            keep_menu_open=true,
            callback=function() self:_set_home_ui_font("custom",selected) end,
        }
    end
    return rows
end

function Plugin:home_ui_font_menu()
    local home=self:_home_preferences()
    return {
        {text="界面默认字体",checked_func=function() return self:_home_preferences().ui_font_mode=="default" end,keep_menu_open=true,callback=function() self:_set_home_ui_font("default") end},
        {text="跟随阅读正文字体",post_text=self:_home_ui_body_font_name() or "最近使用",checked_func=function() return self:_home_preferences().ui_font_mode=="follow" end,keep_menu_open=true,callback=function() self:_set_home_ui_font("follow") end},
        {text="自定义字体",post_text=home.ui_font_mode=="custom" and self:_home_ui_font_label(home) or "选择正文字体库",sub_item_table_func=function() return self:home_ui_font_face_menu() end},
    }
end

function Plugin:_home_toggle_source(section)
    local allowed={account=true,generated=true,["local"]=true,mp=true}
    if not allowed[section] then return false end
    local home,preferences=self:_home_preferences()
    home.visible_sections=type(home.visible_sections)=="table" and home.visible_sections or {}
    local currently=home.visible_sections[section]~=false
    if currently then
        local enabled=0
        for _,key in ipairs(HOME_SECTION_ORDER) do
            if home.visible_sections[key]~=false then enabled=enabled+1 end
        end
        if enabled<=1 then self:toast("至少保留一个书架来源",2); return false end
    end
    home.visible_sections[section]=not currently
    local visible=self:_home_visible_section_keys(self._home_sections,home)
    local active_ok=false
    for _,key in ipairs(visible) do if key==home.active_section then active_ok=true; break end end
    if not active_ok then home.active_section=visible[1] or "account" end
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(nil,"content")
    return true
end

function Plugin:_toggle_home_auto_hide_empty()
    local home,preferences=self:_home_preferences()
    home.auto_hide_empty=home.auto_hide_empty~=true
    local visible=self:_home_visible_section_keys(self._home_sections,home)
    local active_ok=false
    for _,key in ipairs(visible) do if key==home.active_section then active_ok=true; break end end
    if not active_ok then home.active_section=visible[1] or "account" end
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(nil,"content")
end

local HOME_SOURCE_LABELS={account="微信书架",generated="已下载",["local"]="本地书籍",mp="公众号"}

function Plugin:_home_move_source(key,delta)
    local home,preferences=self:_home_preferences()
    local order=home.source_order or HOME_SECTION_ORDER
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local target=index+(tonumber(delta) or 0)
    if target<1 or target>#order then return false end
    order[index],order[target]=order[target],order[index]
    home.source_order=order
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(nil,"content")
    return true
end

function Plugin:home_source_order_menu()
    local home=self:_home_preferences()
    local rows={}
    for index,key in ipairs(home.source_order or HOME_SECTION_ORDER) do
        local item_key,item_index=key,index
        rows[#rows+1]={
            text=HOME_SOURCE_LABELS[item_key] or item_key,
            post_text=tostring(item_index),
            sub_item_table_func=function()
                local current=self:_home_preferences().source_order or HOME_SECTION_ORDER
                local current_index
                for i,name in ipairs(current) do if name==item_key then current_index=i; break end end
                current_index=current_index or item_index
                return {
                    {text="上移",enabled_func=function() return current_index>1 end,callback=function() self:_home_move_source(item_key,-1) end},
                    {text="下移",enabled_func=function() return current_index<#current end,callback=function() self:_home_move_source(item_key,1) end},
                }
            end,
        }
    end
    return rows
end

function Plugin:home_source_settings_menu()
    local home=self:_home_preferences()
    local rows={}
    for _,section in ipairs(home.source_order or HOME_SECTION_ORDER) do
        local key=section
        rows[#rows+1]={
            text=HOME_SOURCE_LABELS[key],
            checked_func=function() return self:_home_preferences().visible_sections[key]~=false end,
            keep_menu_open=true,
            callback=function() self:_home_toggle_source(key) end,
        }
    end
    rows[#rows+1]={
        text="自动隐藏空来源",
        checked_func=function() return self:_home_preferences().auto_hide_empty==true end,
        keep_menu_open=true,
        callback=function() self:_toggle_home_auto_hide_empty() end,
    }
    rows[#rows+1]={text="调整来源顺序",sub_item_table_func=function() return self:home_source_order_menu() end}
    rows[#rows+1]={text="恢复默认顺序",callback=function()
        local current,preferences=self:_home_preferences()
        current.source_order=U.copy(HOME_SECTION_ORDER)
        self:_save_home_preferences(current,preferences)
        self:_refresh_home_view("书架来源顺序已恢复默认","content")
    end}
    return rows
end

local HOME_ACTION_LABELS={
    refresh="更新",search="搜索",downloads="下载",sync="同步",sleep="休眠",
    miuread_settings="觅阅设置",all_books="全部书籍",history="阅读历史",file_manager="文件管理",screenshot="截图",
}
local HOME_PANEL_LABELS={
    wifi="Wi-Fi",bluetooth="蓝牙",rotate="方向锁定",screenshot="截图",koreader_settings="KOReader 设置",
    return_koreader="返回 KOReader",quit="退出 KO",frontlight="前光",sync="同步",
    miuread_settings="觅阅设置",downloads="下载",restart="重启 KOReader",sleep="休眠",full_refresh="全屏刷新",
}

function Plugin:_home_toggle_group_item(group,key)
    local home,preferences=self:_home_preferences()
    local is_action=group=="action"
    local items_key=is_action and "action_items" or "panel_items"
    local order=is_action and HOME_ACTION_ITEM_ORDER or HOME_PANEL_ITEM_ORDER
    local max_count=is_action and 6 or 8
    local items=home[items_key] or {}
    local currently=items[key]==true
    local count=0
    for _,name in ipairs(order) do
        if items[name]==true and (is_action or self:_home_panel_item_available(name)) then count=count+1 end
    end
    if not currently and count>=max_count then
        self:toast((is_action and "主页快捷栏最多显示六项" or "下滑工具栏最多显示八项"),2)
        return false
    end
    items[key]=not currently
    home[items_key]=items
    self:_save_home_preferences(home,preferences)
    local labels=is_action and HOME_ACTION_LABELS or HOME_PANEL_LABELS
    if currently then
        self:toast("已隐藏「"..tostring(labels[key] or key).."」，可在 设置 → 菜单与快捷按键 中恢复",3)
    else
        self:toast("已显示「"..tostring(labels[key] or key).."」",2)
    end
    if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
    return true
end

function Plugin:_home_move_group_item(group,key,delta)
    local home,preferences=self:_home_preferences()
    local order_key=group=="action" and "action_order" or "panel_order"
    local order=home[order_key] or {}
    local positions={}
    for index,name in ipairs(order) do
        if group=="action" or self:_home_panel_item_available(name) then positions[#positions+1]=index end
    end
    local visible_index
    for index,position in ipairs(positions) do if order[position]==key then visible_index=index; break end end
    if not visible_index then return false end
    local target_visible=visible_index+(tonumber(delta) or 0)
    if target_visible<1 or target_visible>#positions then return false end
    local source_position,target_position=positions[visible_index],positions[target_visible]
    order[source_position],order[target_position]=order[target_position],order[source_position]
    home[order_key]=order
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
    return true
end

function Plugin:_home_group_order_menu(group)
    local home=self:_home_preferences()
    local order=group=="action" and (home.action_order or HOME_ACTION_ITEM_ORDER) or (home.panel_order or HOME_PANEL_ITEM_ORDER)
    local labels=group=="action" and HOME_ACTION_LABELS or HOME_PANEL_LABELS
    local rows={}
    local visible_index=0
    for _,key in ipairs(order) do
        local item_key=key
        if group=="action" or self:_home_panel_item_available(item_key) then
            visible_index=visible_index+1
            local item_index=visible_index
            rows[#rows+1]={
                text=labels[item_key] or item_key,post_text=tostring(item_index),
                sub_item_table_func=function()
                    local current=self:_home_preferences()[group=="action" and "action_order" or "panel_order"] or order
                    local visible={}
                    for _,name in ipairs(current) do
                        if group=="action" or self:_home_panel_item_available(name) then visible[#visible+1]=name end
                    end
                    local current_index
                    for i,name in ipairs(visible) do if name==item_key then current_index=i; break end end
                    current_index=current_index or item_index
                    return {
                        {text="上移",enabled_func=function() return current_index>1 end,callback=function() self:_home_move_group_item(group,item_key,-1) end},
                        {text="下移",enabled_func=function() return current_index<#visible end,callback=function() self:_home_move_group_item(group,item_key,1) end},
                    }
                end,
            }
        end
    end
    return rows
end

function Plugin:_home_group_settings_menu(group)
    local is_action=group=="action"
    local order=is_action and HOME_ACTION_ITEM_ORDER or HOME_PANEL_ITEM_ORDER
    local defaults=is_action and HOME_ACTION_ITEM_DEFAULT or HOME_PANEL_ITEM_DEFAULT
    local labels=is_action and HOME_ACTION_LABELS or HOME_PANEL_LABELS
    local items_key=is_action and "action_items" or "panel_items"
    local order_key=is_action and "action_order" or "panel_order"
    local version_key=is_action and "action_layout_version" or "panel_layout_version"
    local rows={}
    for _,key in ipairs(order) do
        local item_key=key
        if is_action or self:_home_panel_item_available(item_key) then
            rows[#rows+1]={
                text=labels[item_key] or item_key,
                checked_func=function() return self:_home_preferences()[items_key][item_key]==true end,
                keep_menu_open=true,
                callback=function() self:_home_toggle_group_item(group,item_key) end,
            }
        end
    end
    rows[#rows+1]={text="调整顺序",sub_item_table_func=function() return self:_home_group_order_menu(group) end}
    rows[#rows+1]={text="恢复推荐布局",callback=function()
        local home,preferences=self:_home_preferences()
        home[items_key]={}
        for _,key in ipairs(order) do home[items_key][key]=defaults[key]==true end
        home[order_key]=U.copy(order)
        home[version_key]=is_action and HOME_ACTION_LAYOUT_VERSION or HOME_PANEL_LAYOUT_VERSION
        self:_save_home_preferences(home,preferences)
        if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
        self:toast("已恢复推荐布局")
    end}
    if is_action then
        rows[#rows+1]={text="使用提示：在主页菜单栏长按快捷项，可左移、更换、隐藏或右移",enabled=false}
    end
    return rows
end

function Plugin:home_action_settings_menu() return self:_home_group_settings_menu("action") end
function Plugin:home_panel_settings_menu() return self:_home_group_settings_menu("panel") end

function Plugin:_home_group_enabled_count(group)
    local home=self:_home_preferences()
    local is_action=group=="action"
    local order=is_action and HOME_ACTION_ITEM_ORDER or HOME_PANEL_ITEM_ORDER
    local items=home[is_action and "action_items" or "panel_items"] or {}
    local count=0
    for _,key in ipairs(order) do
        if items[key]==true and (is_action or self:_home_panel_item_available(key)) then count=count+1 end
    end
    return math.min(count,is_action and 6 or 8)
end

function Plugin:_home_restore_all_quick_defaults()
    local home,preferences=self:_home_preferences()
    home.action_items={}
    for _,key in ipairs(HOME_ACTION_ITEM_ORDER) do home.action_items[key]=HOME_ACTION_ITEM_DEFAULT[key]==true end
    home.action_order=U.copy(HOME_ACTION_ITEM_ORDER)
    home.action_layout_version=HOME_ACTION_LAYOUT_VERSION
    home.panel_items={}
    for _,key in ipairs(HOME_PANEL_ITEM_ORDER) do home.panel_items[key]=HOME_PANEL_ITEM_DEFAULT[key]==true end
    home.panel_order=U.copy(HOME_PANEL_ITEM_ORDER)
    home.panel_layout_version=HOME_PANEL_LAYOUT_VERSION
    if not Device:canSuspend() then home.panel_items.sleep=false end
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
    self:toast("主页快捷布局已恢复推荐设置",2)
end

function Plugin:home_customization_menu()
    return {
        {text="主页快捷栏",post_text=tostring(self:_home_group_enabled_count("action")).." / 6",sub_item_table_func=function() return self:home_action_settings_menu() end},
        {text="下滑工具栏",post_text=tostring(self:_home_group_enabled_count("panel")).." / 8",sub_item_table_func=function() return self:home_panel_settings_menu() end},
        {text="恢复全部推荐布局",post_text="主页 + 下滑工具栏",callback=function() self:_home_restore_all_quick_defaults() end},
    }
end

function Plugin:show_home_customization(anchor)
    return self:_show_standalone_menu("主页自定义",self:home_customization_menu(),{anchor=anchor})
end

local READER_QUICK_LABELS={
    toc="目录",progress="阅读进度",font="字体排版",frontlight="前光",sync="阅读同步",
    comment_font="评论显示",page_display="页面显示",home="觅阅书架",typeset="高级排版",
    current_book="当前书籍",downloads="下载管理",full_refresh="全屏刷新",
    koreader_menu="KOReader 高级菜单",sleep="休眠",
}

function Plugin:_notice_enabled(key)
    local notices=self.store:preferences().notices or {}
    return notices[key]~=false
end

function Plugin:_set_notice_enabled(key,enabled)
    local p=self.store:preferences(); p.notices=type(p.notices)=="table" and p.notices or {}
    p.notices[key]=enabled==true
    self.store:save_preferences(p)
end

local NOTICE_LABELS={
    reader_download="阅读时下载提醒",low_battery="低电量下载提醒",low_storage="存储空间提醒",
    full_refresh="全屏刷新说明",lockscreen="锁屏封面影响说明",library_scan="扫描书库提醒",
    repair_while_reading="阅读中修复提醒",mode_switch="运行模式切换说明",mode_environment="进入模式说明",
}

function Plugin:notice_settings_menu()
    local order={"reader_download","low_battery","low_storage","full_refresh","lockscreen","library_scan","repair_while_reading","mode_switch","mode_environment"}
    local rows={}
    for _,key in ipairs(order) do
        local notice_key=key
        rows[#rows+1]={text=NOTICE_LABELS[notice_key] or notice_key,checked_func=function() return self:_notice_enabled(notice_key) end,keep_menu_open=true,callback=function()
            self:_set_notice_enabled(notice_key,not self:_notice_enabled(notice_key))
        end}
    end
    rows[#rows+1]={text="恢复全部使用提醒",callback=function()
        for _,key in ipairs(order) do self:_set_notice_enabled(key,true) end
        self:toast("使用提醒已恢复")
    end}
    rows[#rows+1]={text="数据删除与覆盖确认",post_text="始终保留",enabled=false}
    return rows
end

function Plugin:download_reader_policy_menu()
    local choices={{"ask","每次询问（推荐）"},{"allow","允许阅读时后台下载"},{"after_reading","退出阅读后再下载"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function() return tostring(self.store:preferences().download_reader_policy or "ask")==key end,callback=function()
            local p=self.store:preferences(); p.download_reader_policy=key; self.store:save_preferences(p); self:toast("阅读时下载策略已更新")
        end}
    end
    return rows
end

function Plugin:_download_network_mode()
    return tostring((self.store:preferences() or {}).download_network_mode or "auto")=="ipv4" and "ipv4" or "auto"
end

function Plugin:_download_network_mode_label()
    return self:_download_network_mode()=="ipv4" and "IPv4" or "自动"
end

function Plugin:_set_download_network_mode(mode,quiet)
    mode=tostring(mode or "auto")=="ipv4" and "ipv4" or "auto"
    local preferences=self.store:preferences()
    preferences.download_network_mode=mode
    self.store:save_preferences(preferences)
    local active=self.download_task and self.download_task:busy()
    if active then
        local ok,err=self.download_task:set_network_mode(mode)
        if not ok then
            logger.warn("[MiuRead][Download] active network mode switch unavailable",tostring(err))
            if quiet~=true then self:toast("设置已保存，将从下一次下载生效",3) end
            return false
        end
    end
    if quiet~=true then
        self:toast(mode=="ipv4" and "下载网络已切换为 IPv4" or "下载网络已恢复自动选择",3)
    end
    return true
end

function Plugin:download_network_mode_menu()
    return {
        {text="自动（推荐）",radio=true,checked_func=function() return self:_download_network_mode()=="auto" end,callback=function() self:_set_download_network_mode("auto") end},
        {text="仅 IPv4",radio=true,checked_func=function() return self:_download_network_mode()=="ipv4" end,callback=function() self:_set_download_network_mode("ipv4") end},
    }
end

function Plugin:_show_download_ipv4_suggestion(runtime,state)
    if not runtime or runtime.network_prompted==true then return end
    runtime.network_prompted=true
    -- Mark the current task as already prompted before showing the dialog.
    -- The worker keeps downloading, and a UI transition/restart cannot turn
    -- the same detection into repeated prompts. Choosing IPv4 below overwrites
    -- this task-local silent marker immediately.
    if self.download_task and self.download_task:busy() then
        self.download_task:dismiss_network_suggestion()
    end
    local auto=tonumber(state and state.network_auto_seconds)
    local ipv4=tonumber(state and state.network_ipv4_seconds)
    local recovery=state and state.network_ipv4_recovery==true
    local comparison=""
    if auto and ipv4 then
        comparison="\n\n自动线路约 "..string.format("%.1f",auto).." 秒，IPv4 约 "..string.format("%.1f",ipv4).." 秒。"
    elseif recovery and ipv4 then
        comparison="\n\n当前线路无法连接；IPv4 测试可正常访问服务器。"
    end
    local dialog
    dialog=ButtonDialog:new{
        title=(recovery and "当前网络可尝试切换 IPv4\n\n下载已经暂停在断点，没有继续请求后面的章节。"
            or "检测到 IPv4 下载更快\n\n当前下载多次响应较慢。觅阅已对同一服务器进行了两组网络对照，两组测试中 IPv4 都明显更快。")
            ..comparison.."\n\n是否切换到 IPv4？",
        title_align="center",
        buttons={
            {{text="切换 IPv4",callback=function()
                UIManager:close(dialog)
                local switched=self:_set_download_network_mode("ipv4",true)
                if switched then
                    self:status_toast("下载网络","已切换为 IPv4，当前下载从下一次请求开始使用",4)
                else
                    self:status_toast("下载网络","IPv4 设置已保存，将从下一次下载生效",4)
                end
            end}},
            {{text="继续当前网络",callback=function()
                UIManager:close(dialog)
            end}},
        },
    }
    UIManager:show(dialog)
end

function Plugin:show_home_layout_dialog()
    local home=self:_home_preferences()
    local function choose(style)
        self:_set_home_layout(style)
    end
    return self:_show_standalone_menu("页面布局",{
        {text="标准布局",radio=true,checked_func=function() return home.layout_style~="compact" end,callback=function() choose("desk") end},
        {text="紧凑布局",radio=true,checked_func=function() return home.layout_style=="compact" end,callback=function() choose("compact") end},
    })
end

function Plugin:_home_close_to_native(show_notice)
    -- This is the only temporary path that intentionally reveals FileManager.
    Orientation.release_session("return to KOReader")
    self:_cancel_native_menu_guard()
    Session.home().suppressed =false
    Session.home().native_visit =true
    Session.home().reader_origin =false
    Session.home().reader_file =nil
    Session.home().expected_close =true
    self:_home_stop_background("temporary native visit")
    -- Ensure there is always a native page below the fullscreen MiuRead home.
    self:_ensure_filemanager_base(Session.home().return_file)
    HomeQuickPanel.close()
    ActionSheet.close()
    HomeView.close(true)
    self._home_view=nil
    self:_set_foreground("native")
    Session.home().expected_close =false
    if show_notice~=false then
        self:toast("已进入 KOReader；可从“返回觅阅主页”回到觅阅",3)
    end
    return true
end

function Plugin:_home_leave_and_run(reason,callback)
    Session.home().suppressed =false
    Session.home().native_visit =false
    self._home_child_reason=reason or "home action"
    local runner=function()
        local ok,err=xpcall(callback,debug.traceback)
        if not ok then
            logger.warn("[MiuRead][Home] action failed",tostring(reason),tostring(err))
            self:info("这个入口暂时无法打开。\n\n"..tostring(err))
        end
    end
    if type(UIManager.tickAfterNext)=="function" then UIManager:tickAfterNext(runner)
    else UIManager:scheduleIn(.05,runner) end
end

function Plugin:_show_miuread_menu(title,items,options)
    options=options or {}
    items=type(items)=="table" and items or {}
    if #items==0 then self:info("没有可用选项"); return nil end

    local function build_rows()
        local rows={}
        for _,entry in ipairs(items) do
            local source=entry
            local enabled=source.enabled~=false
            if type(source.enabled_func)=="function" then
                local ok,value=pcall(source.enabled_func)
                enabled=ok and value~=false
            end
            local label=""
            if type(source.text_func)=="function" then
                local ok,value=pcall(source.text_func)
                label=ok and tostring(value or "") or ""
            else
                label=tostring(source.text or "")
            end
            local checked=false
            if type(source.checked_func)=="function" then
                local ok,value=pcall(source.checked_func)
                checked=ok and value==true
            end
            if checked then label=(source.radio==true and "● " or "✓ ")..label end

            local value=source.post_text
            if type(value)=="function" then
                local ok,result=pcall(value)
                value=ok and result or ""
            end
            value=tostring(value or "")

            local row={
                label=label,
                value=value,
                detail=tostring(source.detail or ""),
                enabled=enabled,
                checked=checked,
                bold=source.separator==true or source.heading==true,
                arrow=false,
            }
            local icon_key=source.icon_key or source.icon
            if icon_key and tostring(icon_key)~="" then row.icon=tostring(icon_key) end

            if source.sub_item_table_func or source.sub_item_table then
                row.arrow=true
                row.callback=function()
                    local child=source.sub_item_table
                    if type(source.sub_item_table_func)=="function" then
                        local ok,value=xpcall(source.sub_item_table_func,debug.traceback)
                        if not ok then self:info("这个入口暂时无法打开。\n\n"..tostring(value)); return end
                        child=value
                    end
                    local child_options=U.copy(options)
                    child_options.on_back=function()
                        self:_show_miuread_menu(title,items,options)
                    end
                    child_options.on_close=nil
                    self:_show_miuread_menu(tostring(source.text or title),child,child_options)
                end
            elseif type(source.callback)=="function" then
                -- Only a real child page gets a chevron. Toggles and direct
                -- actions stay visually flat even when their menu closes.
                row.arrow=source.arrow==true
                row.keep_open=source.keep_menu_open==true
                row.callback=function(...)
                    logger.info("[MiuRead][Menu] MiuRead item tapped",tostring(source.text or ""))
                    local args={...}
                    local ok,err=xpcall(function() return source.callback(unpack_args(args)) end,debug.traceback)
                    if not ok then
                        logger.warn("[MiuRead][Menu] MiuRead action failed",tostring(source.text or ""),tostring(err))
                        self:info("这个入口暂时无法打开。\n\n"..tostring(err))
                    end
                end
            end
            rows[#rows+1]=row
        end
        return rows
    end

    local on_back=options.on_back or options.on_close
    local on_home=options.on_home
    if on_home==nil and HomeView.is_shown() then
        on_home=function()
            if HomeView.is_shown() then HomeView.raise(true) end
        end
    end
    local dialog,err=ReaderListDialog.show{
        title=tostring(title or "觅阅"),
        subtitle=tostring(options.subtitle or ""),
        items=build_rows,
        page_size=tonumber(options.page_size) or 7,
        on_back=on_back,
        on_home=on_home,
    }
    if not dialog then
        logger.warn("[MiuRead][Menu] custom list unavailable",tostring(err or "unknown"))
    end
    return dialog
end

function Plugin:_show_home_bubble_menu(title,items,options)
    options=type(options)=="table" and options or {}
    items=type(items)=="table" and items or {}
    local resolved={}
    for _,source in ipairs(items) do
        if type(source)=="table" and source.hidden~=true then
            local enabled=source.enabled~=false
            if type(source.enabled_func)=="function" then
                local ok,value=pcall(source.enabled_func)
                enabled=ok and value~=false
            end
            local label=source.text
            if label==nil and type(source.text_func)=="function" then
                local ok,value=pcall(source.text_func); if ok then label=value end
            end
            label=tostring(label or "")
            if type(source.checked_func)=="function" then
                local ok,checked=pcall(source.checked_func)
                if ok and checked==true then label="✓ "..label end
            end
            resolved[#resolved+1]={source=source,label=label,enabled=enabled,detail=tostring(source.post_text or "")}
        end
    end
    if #resolved==0 then return ActionSheet.show{anchor=options.anchor,title=tostring(title or "觅阅"),subtitle="没有可用选项",auto_close=1.6} end
    local page_size=math.max(4,math.min(8,tonumber(options.page_size) or 8))
    local pages=math.max(1,math.ceil(#resolved/page_size))
    local page=math.max(1,math.min(pages,tonumber(options.page) or 1))
    local first=(page-1)*page_size+1
    local last=math.min(#resolved,first+page_size-1)
    local actions={}
    local parent=options._bubble_parent
    for index=first,last do
        local row=resolved[index]
        local source=row.source
        local has_child=source.sub_item_table_func~=nil or source.sub_item_table~=nil
        actions[#actions+1]={
            icon=has_child and "›" or (row.label:sub(1,3)=="✓ " and "✓" or "•"),
            label=row.label,detail=row.detail,enabled=row.enabled,submenu=has_child,
            callback=function()
                if has_child then
                    local child=source.sub_item_table
                    if type(source.sub_item_table_func)=="function" then
                        local ok,value=xpcall(source.sub_item_table_func,debug.traceback)
                        if not ok then self:info("这个入口暂时无法打开。\n\n"..tostring(value)); return end
                        child=value
                    end
                    local child_opts=U.copy(options)
                    child_opts.page=1
                    child_opts._bubble_parent={title=title,items=items,options=U.copy(options)}
                    child_opts._bubble_parent.options._bubble_parent=parent
                    return self:_show_home_bubble_menu(tostring(source.text or title),child,child_opts)
                end
                if type(source.callback)=="function" then
                    local ok,err=xpcall(source.callback,debug.traceback)
                    if not ok then self:info("这个入口暂时无法打开。\n\n"..tostring(err)); return end
                    if source.keep_menu_open==true then
                        local reopen=U.copy(options); reopen.page=page
                        UIManager:scheduleIn(.04,function() self:_show_home_bubble_menu(title,items,reopen) end)
                    end
                end
            end,
        }
    end
    local footer={}
    if parent then
        footer[#footer+1]={label="‹ 返回",callback=function()
            local back=U.copy(parent.options or {})
            return self:_show_home_bubble_menu(parent.title,parent.items,back)
        end}
    end
    if page>1 then footer[#footer+1]={label="‹ 上一页",callback=function()
        local previous=U.copy(options); previous.page=page-1
        return self:_show_home_bubble_menu(title,items,previous)
    end} end
    if page<pages then footer[#footer+1]={label="下一页 ›",callback=function()
        local following=U.copy(options); following.page=page+1
        return self:_show_home_bubble_menu(title,items,following)
    end} end
    return ActionSheet.show{
        anchor=options.anchor,preferred_direction=options.preferred_direction or "below",
        width_ratio=tonumber(options.width_ratio) or .78,columns=1,
        title=tostring(title or "觅阅"),subtitle=pages>1 and ("第 "..page.." / "..pages.." 页") or tostring(options.subtitle or ""),
        actions=actions,footer_actions=footer,
    }
end

function Plugin:_show_standalone_menu(title,items,options)
    options=options or {}
    items=type(items)=="table" and items or {}
    if options.force_native~=true and options.native_input~=true
        and HomeView.is_shown() and not self:_active_reader_ui() then
        return self:_show_miuread_menu(title,items,options)
    end
    if options.reader_context==true and type(options.on_home)=="function"
        and not (items[1] and items[1]._miuread_reader_home==true) then
        local navigable={{
            _miuread_reader_home=true,
            text="返回觅阅主页",
            post_text="⌂",
            separator=true,
            close_before_action=true,
            callback=options.on_home,
        }}
        for _,entry in ipairs(items) do navigable[#navigable+1]=entry end
        items=navigable
    end
    if #items==0 then self:info("没有可用选项"); return nil end
    local menu
    local close_standalone
    local rows={}
    for _,entry in ipairs(items) do
        local source=entry
        local enabled=source.enabled~=false
        if type(source.enabled_func)=="function" then
            local ok,value=pcall(source.enabled_func)
            enabled=ok and value~=false
        end
        local label=tostring(source.text or (type(source.text_func)=="function" and source.text_func() or ""))
        if type(source.checked_func)=="function" then
            local ok,checked=pcall(source.checked_func)
            if ok and checked==true then label="✓ "..label end
        end
        local row={
            text=label,
            post_text=source.post_text,
            enabled=enabled,
            separator=source.separator,
        }
        if source.sub_item_table_func or source.sub_item_table then
            row.post_text=row.post_text or "›"
            row.callback=function()
                local child=source.sub_item_table
                if type(source.sub_item_table_func)=="function" then
                    local ok,value=xpcall(source.sub_item_table_func,debug.traceback)
                    if not ok then self:info("这个入口暂时无法打开。\n\n"..tostring(value)); return end
                    child=value
                end
                local child_options=U.copy(options)
                child_options.on_close=function()
                    self:_show_standalone_menu(title,items,options)
                end
                if close_standalone then close_standalone(true) end
                UIManager:scheduleIn(.04,function()
                    self:_show_standalone_menu(tostring(source.text or title),child,child_options)
                end)
            end
        elseif type(source.callback)=="function" then
            row.callback=function(...)
                logger.info("[MiuRead][Menu] standalone item tapped",tostring(source.text or ""))
                local args={...}
                local function run_action()
                    local ok,err=xpcall(function() return source.callback(unpack_args(args)) end,debug.traceback)
                    if not ok then
                        logger.warn("[MiuRead][Menu] standalone action failed",tostring(source.text or ""),tostring(err))
                        self:info("这个入口暂时无法打开。\n\n"..tostring(err))
                        return
                    end
                    if source.keep_menu_open==true and menu and UIManager:isWidgetShown(menu) then
                        UIManager:scheduleIn(.05,function()
                            if menu and UIManager:isWidgetShown(menu) then
                                local refreshed=self:_standalone_rows(title,items,menu)
                                if refreshed then menu.item_table=refreshed; pcall(menu.updateItems,menu) end
                            end
                        end)
                    end
                end
                if source.close_before_action==true and close_standalone then
                    if close_standalone()~=false then UIManager:scheduleIn(.04,run_action)
                    else run_action() end
                else
                    run_action()
                end
            end
        end
        rows[#rows+1]=row
    end
    -- Reader-side menus must receive their own title-bar tap before any
    -- ReaderUI gesture zone. RawMenu keeps KOReader's native event order; the
    -- bridged Menu remains unchanged for MiuRead home pages.
    TransientGuard.close_all()
    local MenuClass=options.native_input==true and RawMenu or Menu
    menu=MenuClass:new{title=tostring(title or "觅阅"),item_table=rows,is_borderless=true,title_bar_fm_style=true}
    menu._miuread_transient=true
    menu._miuread_modal_surface=true
    -- TitleBar captures a dynamic self:onClose() call when it is created.
    -- Replacing Menu:onClose on this concrete instance is sufficient and avoids
    -- mutating already-built child button fields that differ across KOReader
    -- versions.
    close_standalone=function(suppress_restore)
        if not menu or menu._miuread_closing then return true end
        suppress_restore=suppress_restore==true or menu._miuread_suppress_restore==true
        menu._miuread_closing=true
        local ok,err=pcall(UIManager.close,UIManager,menu)
        if not ok then
            menu._miuread_closing=false
            logger.warn("[MiuRead][Menu] standalone close failed",tostring(err))
            return false
        end
        if suppress_restore~=true and type(options.on_close)=="function" and not menu._miuread_restore_scheduled then
            menu._miuread_restore_scheduled=true
            UIManager:scheduleIn(.06,function()
                local restore_ok,restore_err=pcall(options.on_close)
                if not restore_ok then logger.warn("[MiuRead][Menu] standalone restore failed",tostring(restore_err)) end
            end)
        end
        return true
    end
    menu.onClose=close_standalone
    menu.onCloseAllMenus=close_standalone
    menu._close=function(_,_,cancel_pending)
        menu._miuread_suppress_restore=cancel_pending==true
        return close_standalone(cancel_pending==true)
    end
    UIManager:show(menu)
    return menu
end

-- Small helper used only when a standalone toggle menu stays open.
function Plugin:_standalone_rows(title,items,menu)
    local rows={}
    for _,entry in ipairs(items or {}) do
        local source=entry
        local enabled=source.enabled~=false
        if type(source.enabled_func)=="function" then local ok,v=pcall(source.enabled_func); enabled=ok and v~=false end
        local label=tostring(source.text or (type(source.text_func)=="function" and source.text_func() or ""))
        if type(source.checked_func)=="function" then local ok,v=pcall(source.checked_func); if ok and v==true then label="✓ "..label end end
        local row={text=label,post_text=source.post_text,enabled=enabled,separator=source.separator}
        if source.sub_item_table_func or source.sub_item_table then
            row.post_text=row.post_text or "›"
            row.callback=function()
                local child=source.sub_item_table
                if type(source.sub_item_table_func)=="function" then local ok,v=xpcall(source.sub_item_table_func,debug.traceback); if not ok then self:info(tostring(v)); return end; child=v end
                self:_show_standalone_menu(tostring(source.text or title),child)
            end
        elseif type(source.callback)=="function" then
            row.callback=function(...) return source.callback(...) end
        end
        rows[#rows+1]=row
    end
    return rows
end

function Plugin:_reader_open_native_page(label,opener,return_callback)
    if not (self.ui and self.ui.document) then return false end
    self._reader_native_return_token=(tonumber(self._reader_native_return_token) or 0)+1
    local token=self._reader_native_return_token
    local reader_ui=self.ui
    local document=reader_ui.document
    local reader_session=tonumber(HOME_SESSION.reader_session_generation) or 0
    self:_close_miuread_transients()
    self:_set_navigation_state("native_menu","reader native page "..tostring(label or ""))
    local baseline={}
    for _,window in ipairs(UIManager._window_stack or {}) do
        local widget=window and window.widget or nil
        if widget then baseline[widget]=true end
    end

    local function restore_reader(reason,restore_callback)
        if token~=self._reader_native_return_token then return false end
        if self.ui~=reader_ui or not self.ui or self.ui.document~=document then return false end
        if tonumber(HOME_SESSION.reader_session_generation or 0)~=reader_session then return false end
        if reader_close_active() or self._reader_returning or self._home_reader_transition then return false end
        self:_set_navigation_state("reader",reason or "native reader page closed")
        if restore_callback==true and type(return_callback)=="function" then
            local restore_ok,restore_err=pcall(return_callback)
            if not restore_ok then logger.warn("[MiuRead][Reader] native page restore failed",tostring(restore_err)) end
        end
        return true
    end

    UIManager:scheduleIn(.05,function()
        if token~=self._reader_native_return_token or reader_close_active()
            or HOME_SESSION.suspended==true or self._miuread_suspended==true
            or self.ui~=reader_ui or not self.ui or self.ui.document~=document
            or tonumber(HOME_SESSION.reader_session_generation or 0)~=reader_session then return end
        local ok,result=xpcall(opener,debug.traceback)
        if not ok or result==false then
            logger.warn("[MiuRead][Reader] native page open failed",tostring(label or ""),tostring(result))
            restore_reader("native reader page open failed",false)
            if type(return_callback)=="function" then UIManager:scheduleIn(.06,return_callback) end
            return
        end
        local seen_overlay=false
        local stable=0
        local attempts=0
        local function has_new_overlay()
            for _,window in ipairs(UIManager._window_stack or {}) do
                local widget=window and window.widget or nil
                if widget and not baseline[widget] and widget.toast~=true and widget._miuread_transient~=true
                    and UIManager:isWidgetShown(widget) then
                    return true
                end
            end
            return false
        end
        local function watch()
            if token~=self._reader_native_return_token then return end
            if HOME_SESSION.suspended==true or self._miuread_suspended==true then
                UIManager:scheduleIn(.6,watch)
                return
            end
            if self.ui~=reader_ui or not self.ui or self.ui.document~=document then return end
            if tonumber(HOME_SESSION.reader_session_generation or 0)~=reader_session then return end
            if reader_close_active() or self._reader_returning or self._home_reader_transition then return end
            attempts=attempts+1
            if has_new_overlay() then
                seen_overlay=true
                stable=0
            else
                stable=stable+1
            end
            if (seen_overlay and stable>=3) or (not seen_overlay and attempts>=18) then
                restore_reader("native reader page closed",true)
                return
            end
            local delay=attempts<60 and .12 or (attempts<300 and .30 or .70)
            UIManager:scheduleIn(delay,watch)
        end
        UIManager:scheduleIn(.12,watch)
    end)
    return true
end

function Plugin:_reader_wifi_state()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr or type(NetworkMgr.isWifiOn)~="function" then return nil end
    local ok,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
    if ok then return value==true end
    return nil
end

function Plugin:_reader_wifi_toggle()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end
    local on=self:_reader_wifi_state()==true
    local ok=false
    if on then
        if type(NetworkMgr.toggleWifiOff)=="function" then ok=pcall(NetworkMgr.toggleWifiOff,NetworkMgr)
        elseif type(NetworkMgr.turnOffWifi)=="function" then ok=pcall(NetworkMgr.turnOffWifi,NetworkMgr) end
        if ok then self:toast("Wi-Fi 已关闭",1.5) end
    else
        if type(NetworkMgr.toggleWifiOn)=="function" then ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr)
        elseif type(NetworkMgr.turnOnWifi)=="function" then ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr) end
        if ok then self:toast("正在开启 Wi-Fi",1.5) end
    end
    if ok then HomeData.invalidate_device_state() end
    return ok==true
end

function Plugin:_reader_wifi_settings(back_callback)
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end
    local restored=false
    local function restore_reader_menu()
        if restored then return end
        restored=true
        if type(back_callback)=="function" then UIManager:scheduleIn(.12,back_callback) end
    end
    local function show_network_list()
        if type(NetworkMgr.getNetworkList)=="function" then
            local ok_list,networks=pcall(NetworkMgr.getNetworkList,NetworkMgr)
            if ok_list and type(networks)=="table" then
                local ok_widget,NetworkSetting=pcall(require,"ui/widget/networksetting")
                if ok_widget and NetworkSetting and type(NetworkSetting.new)=="function" then
                    local dialog=NetworkSetting:new{network_list=networks}
                    local original_on_close=dialog.onCloseWidget
                    dialog.onCloseWidget=function(widget)
                        if type(original_on_close)=="function" then
                            local ok_close,err=xpcall(function() original_on_close(widget) end,debug.traceback)
                            if not ok_close then logger.warn("[MiuRead][Reader] network picker close failed",tostring(err)) end
                        end
                        restore_reader_menu()
                    end
                    UIManager:show(dialog)
                    return true
                end
            end
        end
        if type(NetworkMgr.toggleWifiOn)=="function" then
            local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,restore_reader_menu,true,true)
            if ok then return true end
        end
        if type(NetworkMgr.turnOnWifi)=="function" then
            local ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr,restore_reader_menu,true)
            if ok then return true end
        end
        return false
    end
    if self:_reader_wifi_state()==true then
        if show_network_list() then return true end
    elseif type(NetworkMgr.toggleWifiOn)=="function" then
        -- KOReader's long-press flag enables Wi-Fi and keeps the network list
        -- visible. Restore the MiuRead reader panel only after that picker closes.
        local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,restore_reader_menu,true,true)
        if ok then return true end
    elseif type(NetworkMgr.turnOnWifi)=="function" then
        local ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr,function()
            UIManager:scheduleIn(.1,function()
                if not show_network_list() then restore_reader_menu() end
            end)
        end,true)
        if ok then return true end
    end
    self:info("Wi-Fi 网络列表暂时无法打开")
    restore_reader_menu()
    return false
end

function Plugin:_home_wifi_text()
    local state=HomeData.cached_device_state() or HomeData.quick_device_state() or {}
    if state.wifi_on==false then return "已关闭" end
    if state.wifi_on==true then
        local ssid=U.trim(tostring(state.wifi_name or ""))
        if ssid~="" then return U.utf8_truncate(ssid,13,"…") end
        return state.online==true and "已连接" or "未连接"
    end
    return "Wi-Fi"
end

function Plugin:_home_status_line()
    -- Backward-compatible text for older callers; the home header renders
    -- Wi-Fi, sync and time as independent groups from beta.18 onward.
    return self:_home_wifi_text()
end

function Plugin:_home_battery_text()
    local device=HomeData.cached_device_state() or HomeData.quick_device_state() or {}
    if tonumber(device.battery) then
        return tostring(math.floor(tonumber(device.battery)+.5)).."%"
    end
    return "--%"
end

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
    if book.source=="miuread" or book.shelf_section=="generated" then return "微信书架" end
    if Protocol.is_mp_account(tostring(book.bookId or book.book_id or "")) then return "公众号" end
    local category=U.trim(tostring(book.category or ""))
    return category~="" and ("微信书架 · "..category) or "微信书架"
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
    local source_labels={all="全部来源",account="微信书架",generated="已下载",["local"]="本地书籍",mp="公众号"}
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

function Plugin:show_annotation_search_dialog(back_callback)
    local d
    d=InputDialog:new{
        title="搜索批注",
        description="搜索全部书籍的划线、想法和书签",
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
                UIManager:nextTick(function() self:_annotation_run_search(query,back_callback) end)
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
    return true
end

function Plugin:_annotation_run_search(query,back_callback)
    local results,err=LocalAnnotationDatabase.search_all(self.store,query,200)
    if type(results)~="table" then
        self:info("批注搜索失败：\n"..tostring(err or "无法读取本地批注"))
        if back_callback then UIManager:scheduleIn(.05,back_callback) end
        return false
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
    if text=="" then text="无文字内容" end
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

function Plugin:_annotation_search_results(query,results,back_callback)
    local title_map=self:_annotation_book_title_map()
    local kind_labels={bookmark="书签",highlight="划线",thought="想法"}
    local kind_icons={bookmark="bookmark",highlight="highlight",thought="thought"}
    local rows={}
    for _,result in ipairs(type(results)=="table" and results or {}) do
        local current=result
        local info=title_map[tostring(current.book_id or "")] or {
            title="未知书籍",author="",book=nil,
        }
        local value=kind_labels[current.kind] or "批注"
        if current.page then value=value.." · 第 "..tostring(current.page).." 页" end
        rows[#rows+1]={
            icon=kind_icons[current.kind] or "highlight",
            label=self:_annotation_search_excerpt(current),
            detail=U.utf8_truncate(info.title,42,"…")
                ..(info.author~="" and (" · "..U.utf8_truncate(info.author,18,"…")) or ""),
            value=value,
            callback=function() self:_annotation_open_result(current,info,false) end,
            hold_callback=function() self:_annotation_open_result(current,info,true,function()
                self:_capture_local_annotation_snapshot("annotation_search_manage")
                UIManager:scheduleIn(.06,function() self:_annotation_run_search(query,back_callback) end)
            end) end,
        }
    end
    ReaderListDialog.show{
        title="批注搜索",
        subtitle="“"..tostring(query).."” · "..tostring(#rows).." 处 · 点击跳转，长按管理",
        items=rows,page_size=5,empty_text="没有找到匹配的批注",
        on_back=function() self:show_annotation_search_dialog(back_callback) end,
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
            {icon="☁",label="更新微信书架",detail="重新获取微信书架变化",callback=function() self:_home_refresh_remote(true,true) end},
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

function Plugin:_show_home_sync_popup(anchor)
    local summary=self:_home_sync_summary()
    local subtitle=self:_home_sync_status_label()
    if summary.total>0 then
        subtitle=subtitle.."  ·  进度 "..tostring(summary.progress)
            .."  时间 "..tostring(summary.time)
            .."  划线 "..tostring(summary.highlight)
            .."  想法 "..tostring(summary.thought)
    end
    ActionSheet.show{
        cache_key="home_sync",
        anchor=anchor,
        preferred_direction="below",
        title="同步",
        subtitle=subtitle,
        actions={
            {icon="⇅",label="同步待处理内容",detail="进度 时间 划线与想法",callback=function() self:_sync_home_pending() end},
            {icon="i",label="查看同步详情",detail="分别查看四类数据状态",callback=function() self:show_sync_status(false) end},
            {icon="⚙",label="同步设置",detail="开关 可见范围 提醒与诊断",callback=function()
                self:_show_standalone_menu("同步设置",self:sync_settings_menu())
            end},
        },
        wide_last=true,
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
        {text="评论、划线与想法",post_text="评论显示与本地批注",sub_item_table_func=function() return PluginSettings.comments(self) end},
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
        {icon="☁",label="更新微信书架",detail="重新获取微信书架变化",callback=function() self:_home_refresh_remote(true,true) end},
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
    if key=="sync" then return {
        {icon="⇅",label="立即同步",detail="处理当前待同步内容",callback=function() self:_sync_home_pending() end},
        {icon="i",label="同步详情",detail="查看各类数据状态",callback=function() self:show_sync_status(false) end},
        {icon="✚",label="修复同步",detail="检查并修复异常状态",callback=function() self:show_sync_status(true) end},
        {icon="⚙",label="同步设置",detail="开关 范围与提醒",callback=function() self:_show_standalone_menu("同步设置",self:sync_settings_menu(),{anchor=anchor}) end},
        {icon="!",label="同步诊断",detail="查看诊断信息",callback=function() self:_show_standalone_menu("同步诊断",self:sync_diagnostics_menu(),{anchor=anchor}) end},
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
        {icon="⇅",label="同步",detail="进度 时间与批注同步",callback=function() self:_show_standalone_menu("同步",self:sync_settings_menu(),{anchor=anchor}) end},
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

    local sync_summary=self:_home_sync_summary()
    local sync_badge=nil
    if sync_summary.failed>0 then sync_badge="!"
    elseif sync_summary.total>0 then sync_badge=sync_summary.total>99 and "99+" or tostring(sync_summary.total) end

    local definitions={
        refresh={icon="↻",icon_key="refresh",label="更新",callback=function()
            -- Single tap means "update what I am looking at". E-ink full refresh
            -- remains available from the long-press menu and quick panel.
            self:_home_manual_refresh()
        end},
        search={icon="⌕",icon_key="search",label="搜索",callback=function(anchor) self:_show_home_search_popup(anchor) end},
        downloads={icon="⇩",icon_key="download",label="下载",badge=download_badge,callback=function(anchor) self:_show_home_download_popup(anchor) end},
        sync={icon="⇅",icon_key="sync",label="同步",badge=sync_badge,callback=function(anchor)
            self:_sync_home_pending(); self:_show_home_quick_notice(anchor,"正在同步","待处理内容已提交")
        end},
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
        {title="微信书架",detail="账号中的全部书籍",count=account_count,on_tap=function()
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

function Plugin:_home_network_metadata_cache()
    local cache=self.store:get("home_network_metadata",{version=1,rows={}})
    cache=type(cache)=="table" and cache or {version=1,rows={}}
    cache.rows=type(cache.rows)=="table" and cache.rows or {}
    return cache
end

local function home_network_patch_has_data(patch)
    if type(patch)~="table" then return false end
    for _,key in ipairs({"title","author","description","category","publisher","published_date","language","isbn","pages"}) do
        if U.trim(tostring(patch[key] or ""))~="" then return true end
    end
    return false
end

local HOME_NETWORK_DETAIL_FIELDS={"description","category","publisher","published_date","isbn"}

local function home_network_patch_field_count(patch)
    if type(patch)~="table" then return 0 end
    local count=0
    for _,key in ipairs({"title","author","description","category","publisher","published_date","language","isbn","pages"}) do
        if U.trim(tostring(patch[key] or ""))~="" then count=count+1 end
    end
    return count
end

local function home_network_missing_fields(book,patch)
    book=type(book)=="table" and book or {}
    patch=type(patch)=="table" and patch or {}
    local missing={}
    for _,key in ipairs(HOME_NETWORK_DETAIL_FIELDS) do
        local value=patch[key]
        if value==nil or value=="" then value=book[key] end
        if key=="description" and U.trim(tostring(value or ""))=="" then
            value=book.intro or book.summary
        end
        if U.trim(tostring(value or ""))=="" then missing[#missing+1]=key end
    end
    return missing
end

function Plugin:_home_merge_network_patch(book,patch)
    if type(book)~="table" or type(patch)~="table" then return false end
    local changed=false
    local function fill(key,value)
        if value==nil or value=="" then return end
        local current=book[key]
        if current==nil or current=="" then book[key]=value; changed=true end
    end
    for _,key in ipairs({"title","author","description","category","publisher","published_date","language","isbn","pages"}) do
        fill(key,patch[key])
    end
    if patch.metadata_source and (book.network_metadata_source==nil or book.network_metadata_source=="") then
        book.network_metadata_source=patch.metadata_source
        changed=true
    end
    return changed
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
    hero.heading="最近阅读"
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
        account={title="微信书架",rows=account_rows,empty="这里还没有微信书架内容"},
        generated={title="已下载",rows=miuread_rows,empty="这里还没有已下载书籍"},
        ["local"]={title="本地书籍",rows=local_rows,empty=self:_home_local_empty_text()},
        mp={title="公众号",rows=mp_rows,empty="这里还没有公众号内容"},
    }
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
        sync_text=self:_home_sync_status_label(),
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
        on_open_book=function(book,anchor) self:_home_open_book(book,anchor) end,
        on_hold_book=function(book,anchor) self:_home_hold_book(book,anchor) end,
        home_actions=self:_home_action_entries(),
        on_shelf_all=function()
            if active=="local" then self:show_home_local_library()
            else self:show_home_all_books() end
        end,
        on_shelf_page=function(delta) self:_home_change_page(delta) end,
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

function Plugin:show_miuread_home(force_scan,from_refresh)
    local lifecycle=self:_reader_lifecycle_state()
    if lifecycle~="closed" then return self:return_to_miuread_home() end
    return self:_show_miuread_home_now(force_scan,from_refresh)
end

function Plugin:_open_file_direct(path)
    path=normalized_reader_file(path)
    if not path or not U.file_exists(path) then self:info(_("No cached file")); return false end
    local now=os.time()
    local opening=tostring(HOME_SESSION.opening_file or "")
    local opening_age=now-(tonumber(HOME_SESSION.opening_at) or 0)
    if opening~="" and opening_age>=0 and opening_age<12 then
        if opening==path then
            logger.info("[MiuRead][Reader] duplicate open ignored",opening)
            self:status_toast("正在打开书籍","请稍候",2)
            return true
        end
        logger.info("[MiuRead][Reader] replacing pending open target",opening,"with",path)
    end
    HOME_SESSION.opening_file=path
    HOME_SESSION.opening_at=now
    self:_cancel_interactive_network("reader opening")
    HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
    HOME_SESSION.home_restore_active=false

    if self:_home_enabled() and not Session.home().native_visit and not Session.home().suppressed then
        Session.home().return_file =path
        mark_reader_origin(path)
        self._home_reader_transition=true
        self:_begin_page_transition("opening_reader")
        self:_home_stop_background("reader opening")
        -- Keep the rendered home underneath ReaderUI, but park all of its
        -- input handlers so it cannot leave stale gesture zones behind.
        self:_close_home_for_reader("reader opening")
        self:_set_foreground("reader_pending")
    end

    local function fail(err)
        if tostring(HOME_SESSION.opening_file or "")==path then
            HOME_SESSION.opening_file=nil
            HOME_SESSION.opening_at=0
        end
        self._home_reader_transition=false
        self:_finish_page_transition(0,"open failed")
        logger.warn("[MiuRead][Reader] open failed",path,tostring(err))
        local active=self:_active_reader_ui()
        if active and active.dialog then
            pcall(UIManager.setDirty,UIManager,active.dialog,"ui")
        else
            self:_ensure_filemanager_base(Session.home().return_file)
            self:_set_foreground("home_pending")
            self:_restore_home_after_reader_close(1)
        end
        self:info("书籍暂时无法打开：\n"..U.first_line(err,120))
        return false
    end

    if self.ui and self.ui.document and type(self.ui.switchDocument)=="function" then
        local ok,result=xpcall(function() return self.ui:switchDocument(path) end,debug.traceback)
        if not ok then return fail(result) end
        if result==false then return fail("KOReader 拒绝切换到目标书籍") end
        return result==nil and true or result
    end
    local ReaderUI=require("apps/reader/readerui")
    local ok,result=xpcall(function()
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        return ReaderUI:showReader(path)
    end,debug.traceback)
    if not ok then return fail(result) end
    if result==false then return fail("KOReader 拒绝打开目标书籍") end
    return result==nil and true or result
end

function Plugin:open_file(path)
    if not path then self:info(_("No cached file")); return end
    local book=self.store:identify_file(path,false)
    local book_id=book and tostring(book.book_id or book.bookId or "") or ""
    local resolved=book_id~="" and self.access:resolve_path(book_id,path) or path
    if not resolved or not U.file_exists(resolved) then self:info(_("No cached file")); return end
    self:_open_file_direct(resolved)
end

function Plugin:_current_document_path()
    local doc=self.ui and self.ui.document
    return doc and (doc.file or (doc.getFilePath and doc:getFilePath())) or nil
end
function Plugin:_record_recent_read(path,book,record)
    path=normalized_reader_file(path) or tostring(path or "")
    local book_id=tostring((book and (book.book_id or book.bookId))
        or (record and (record.book_id or record.bookId)) or "")
    if path=="" and book_id=="" then return false end
    local stamp=os.time()
    if self.store.record_recent_read then
        self.store:record_recent_read(book_id,path,stamp)
    elseif book_id~="" then
        self.store:mark_last_read(book_id,path,nil,false,stamp)
    end
    self:_home_share_recent_read(book_id,path,stamp)
    self._home_recent_read_dirty=true
    HOME_SESSION.recent_read_dirty=true
    local owner=home_owner()
    if owner and owner~=self then
        -- Keep the parked Home instance's in-memory view current too. These are
        -- deferred settings writes; no synchronous disk I/O is added to
        -- ReaderReady or the page-turn path.
        if owner.store and owner.store.record_recent_read then
            owner.store:record_recent_read(book_id,path,stamp)
        elseif owner.store and book_id~="" then
            owner.store:mark_last_read(book_id,path,nil,false,stamp)
        end
        owner._home_recent_read_dirty=true
    end
    logger.info("[MiuRead][Recent] reader recorded",
        "book=",book_id~="" and book_id or "local","file=",tostring(path),
        "shared=true")
    return true
end

function Plugin:on_sync_record_ready(current)
    self:_teardown_thought_tap()
    if current and current.book then
        local book_id,path=tostring(current.book.book_id),current.path
        local record=current.record or {}
        local variant=tostring(current.variant or record.variant or "")
        if record.annotation_requested==true or variant:find("notes",1,true) then
            self:_setup_thought_tap()
        end
        -- ReaderReady already records the file immediately in LuaSettings
        -- memory. Once Sync resolves the canonical book id, backfill that id
        -- without a synchronous disk flush or another delayed timer.
        self:_record_recent_read(path,current.book,current.record)
        self:_schedule_current_book_repair_check(current,false)
    end
    if self.store:preferences().sync.progress_enabled~=false then
        if self.sync:is_current_verified() then
            self.sync:end_progress_sync("已恢复本书最近验证成功的阅读位置")
        else
            self:_wait_for_network("reader-ready-progress",function(ready)
                if ready and self.ui and self.ui.document then
                    self:ensure_read_report_progress("reader_ready",true)
                elseif self.ui and self.ui.document then
                    self:_save_progress_state(tostring(current.book.book_id),"waiting_network",
                        "等待 Wi-Fi 恢复后读取云端位置",nil,nil)
                end
            end,{minimum_delay=4.0,max_wait=60,interval=2.5})
        end
    end
end
function Plugin:on_sync_record_missing()
    logger.dbg("[MiuRead][Sync] external EPUB ignored")
end
function Plugin:_reader_rebuild_cancel(reason,clear_shared)
    local owner=READER_REBUILD.owner
    if owner and owner._reader_rebuild_task then
        pcall(UIManager.unschedule,UIManager,owner._reader_rebuild_task)
        owner._reader_rebuild_task=nil
    end
    if self._reader_rebuild_task then
        UIManager:unschedule(self._reader_rebuild_task)
        self._reader_rebuild_task=nil
    end
    READER_REBUILD.generation=(tonumber(READER_REBUILD.generation) or 0)+1
    if clear_shared~=false then
        READER_REBUILD.state="idle"
        READER_REBUILD.session_generation=0
        READER_REBUILD.reader_file=nil
        READER_REBUILD.started_at=0
        READER_REBUILD.started_clock=0
        READER_REBUILD.max_wait=0
        READER_REBUILD.reason=nil
        READER_REBUILD.owner=nil
        READER_REBUILD.pending_width=nil
        READER_REBUILD.pending_height=nil
        READER_REBUILD.pending_rotation=nil
        READER_REBUILD.internal_hint=false
    end
    if reason then logger.info("[MiuRead][Lifecycle] rebuild watcher cancelled",tostring(reason)) end
    return true
end

function Plugin:_prepare_reader_disappearance(reason)
    if self._reader_checkpoint_dirty==true then
        self:_flush_reader_checkpoint(reason or "reader_disappeared",true)
    end
    self:_mark_reader_busy(4)
    self:_close_active_thought_popup(reason or "reader disappeared")
    if ThoughtNativePopup and type(ThoughtNativePopup.cleanup)=="function" then
        pcall(ThoughtNativePopup.cleanup)
    end
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    if self._local_annotation_snapshot_task then
        UIManager:unschedule(self._local_annotation_snapshot_task)
        self._local_annotation_snapshot_task=nil
    end
    if self._reader_sync_ready_task then
        UIManager:unschedule(self._reader_sync_ready_task)
        self._reader_sync_ready_task=nil
    end
    self:_cancel_network_waits()
    self:_cancel_interactive_network(reason or "reader disappeared")
    if self.repair_async and self.repair_async.job and self.repair_async.job.label=="book-migration-check" then
        self.repair_async:cancel(reason or "reader disappeared")
        if self.annotation_async then self.annotation_async:cancel(reason or "reader disappeared") end
    end
    self._repair_prompt_open=false
    self:_teardown_thought_tap()
    self:_teardown_external_annotations()
    self._progress_prompted_book_id=nil
    self._progress_check_running=false
    return true
end

function Plugin:_finalize_reader_instance_close(closing_path,session_generation,options)
    options=type(options)=="table" and options or {}
    local explicit_return=options.explicit_return==true
    local document_switch=options.document_switch==true
    closing_path=normalized_reader_file(closing_path)
        or normalized_reader_file(HOME_SESSION.reader_session_file)
        or normalized_reader_file(Session.home().reader_file)
    session_generation=tonumber(session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0

    self:_prepare_reader_disappearance(options.reason or "document closed")
    if self.sync then self.sync:on_close() end

    -- A confirmed switch has a new ReaderUI already alive. Never clear shared
    -- reader markers or start Home/post-reader work from the old plugin instance.
    if document_switch then
        logger.info("[MiuRead][Lifecycle] previous reader finalized after document switch",
            "book=",tostring(closing_path or ""),"session=",tostring(session_generation))
        return true
    end

    if self._reader_active_path then os.remove(self._reader_active_path) end
    if self._reader_busy_path then
        local busy_path=self._reader_busy_path
        UIManager:scheduleIn(4,function() os.remove(busy_path) end)
    end
    self:_schedule_post_reader_work("document closed",1.4)
    HOME_SESSION.reader_session_active=false

    if explicit_return then
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
    end

    if self:_home_enabled() and Session.home().reader_origin and not Session.home().suppressed
        and not Session.home().native_visit and not Session.home_exiting() then
        self:_set_foreground("reader_transition")
        if explicit_return then
            READER_CLOSE.close_event_received=true
            if READER_CLOSE.state~="native_surface_waiting" then READER_CLOSE.state="document_closed" end
            self._miuread_return_requested=false
            logger.info("[MiuRead][ReaderClose] CloseDocument received",
                "generation=",tostring(READER_CLOSE.generation))
            self:_schedule_reader_return_finish(READER_CLOSE.generation,.10,"explicit close document")
        else
            self:_schedule_reader_close_settle(closing_path,session_generation,"confirmed document close")
        end
    else
        self:_set_foreground("native")
        UIManager:scheduleIn(.12,function()
            if self:_reader_lifecycle_state()~="closed" then return end
            if self:_filemanager_instance() or self:_ensure_filemanager_base(closing_path) then
                if ReaderTransitionGuard.is_shown() then
                    self:_release_reader_transition_guard("native surface restored")
                end
                UIManager:setDirty(nil,"ui")
                self:_finish_page_transition(.8,"native surface restored")
            else
                self:_finish_page_transition(0,"native restore failed")
                self:_show_reader_recovery_surface("KOReader 文件管理器未能恢复")
            end
        end)
    end
    return true
end

function Plugin:_finish_reader_rebuild_candidate(generation,reason)
    if generation~=(tonumber(READER_REBUILD.generation) or 0)
        or not reader_rebuild_active() then return false end
    if HOME_SESSION.suspended==true or self._miuread_suspended==true then
        READER_REBUILD.state="suspended_pending"
        self._reader_rebuild_task=nil
        return false
    end
    local active=self:_active_reader_ui()
    if active and active.document then
        local current=normalized_reader_file(self:_reader_file(active))
        local expected=normalized_reader_file(READER_REBUILD.reader_file)
        if current and expected and current==expected then
            local elapsed=math.floor((monotonic_wall_time()-(tonumber(READER_REBUILD.started_clock) or monotonic_wall_time()))*1000+.5)
            logger.info("[MiuRead][Lifecycle] reader rebuild completed",
                "same_book=true","session=",tostring(READER_REBUILD.session_generation or 0),
                "ms=",tostring(math.max(0,elapsed)))
            self:_reader_rebuild_cancel("same reader returned",true)
            return true
        end
        local old_owner=READER_REBUILD.owner
        local old_path=READER_REBUILD.reader_file
        local old_session=READER_REBUILD.session_generation
        self:_reader_rebuild_cancel("different reader returned",true)
        if old_owner and type(old_owner._finalize_reader_instance_close)=="function" then
            pcall(old_owner._finalize_reader_instance_close,old_owner,old_path,old_session,
                {document_switch=true,reason="reader switched during rebuild candidate"})
        end
        return true
    end

    local elapsed=math.max(0,monotonic_wall_time()-(tonumber(READER_REBUILD.started_clock) or monotonic_wall_time()))
    if elapsed<(tonumber(READER_REBUILD.max_wait) or 2.4) then
        local task
        task=function()
            if self._reader_rebuild_task~=task then return end
            self._reader_rebuild_task=nil
            self:_finish_reader_rebuild_candidate(generation,reason)
        end
        self._reader_rebuild_task=task
        UIManager:scheduleIn(elapsed<1.0 and .18 or .28,task)
        return false
    end

    local old_path=READER_REBUILD.reader_file
    local old_session=READER_REBUILD.session_generation
    self:_reader_rebuild_cancel("candidate confirmed closed",true)
    logger.info("[MiuRead][Lifecycle] rebuild candidate became real close",
        "book=",tostring(old_path or ""),"wait_ms=",tostring(math.floor(elapsed*1000+.5)))
    return self:_finalize_reader_instance_close(old_path,old_session,
        {reason=reason or "rebuild candidate timeout"})
end

function Plugin:_start_reader_rebuild_candidate(closing_path,session_generation,reason,internal_hint)
    self:_reader_rebuild_cancel(nil,true)
    local now=monotonic_wall_time()
    local path=normalized_reader_file(closing_path)
        or normalized_reader_file(HOME_SESSION.reader_session_file)
        or normalized_reader_file(Session.home().reader_file)
    if path and READER_REBUILD.recent_book==path and now-(tonumber(READER_REBUILD.recent_started_at) or 0)<=10 then
        READER_REBUILD.recent_count=(tonumber(READER_REBUILD.recent_count) or 0)+1
    else
        READER_REBUILD.recent_book=path
        READER_REBUILD.recent_count=1
    end
    READER_REBUILD.recent_started_at=now
    if READER_REBUILD.recent_count>=3 then READER_REBUILD.safe_until=now+15 end

    READER_REBUILD.generation=(tonumber(READER_REBUILD.generation) or 0)+1
    local generation=READER_REBUILD.generation
    READER_REBUILD.state="pending"
    READER_REBUILD.session_generation=tonumber(session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0
    READER_REBUILD.reader_file=path
    READER_REBUILD.started_at=os.time()
    READER_REBUILD.started_clock=now
    READER_REBUILD.reason=tostring(reason or "CloseDocument without explicit return")
    READER_REBUILD.owner=self
    READER_REBUILD.internal_hint=internal_hint==true

    local recent_dimension=now-(tonumber(HOME_SESSION.last_dimension_event_clock) or 0)<=5
    local recent_resume=now-(tonumber(HOME_SESSION.last_resume_clock) or 0)<=8
    local fuse=(tonumber(READER_REBUILD.safe_until) or 0)>now
    -- ReaderUI marks reloadDocument()/switchDocument() with tearing_down=true.
    -- A same-book internal reload on slower Kindle devices can legitimately
    -- take several seconds, so give that explicit signal a longer bounded
    -- window without delaying ordinary unrequested closes.
    READER_REBUILD.max_wait=READER_REBUILD.internal_hint and 18.0
        or (fuse and 5.5 or ((recent_dimension or recent_resume) and 4.2 or 2.4))
    self:_set_foreground("reader")
    logger.info("[MiuRead][Lifecycle] rebuild candidate",
        "book=",tostring(path or ""),"session=",tostring(READER_REBUILD.session_generation),
        "recent_dimensions=",tostring(recent_dimension),"recent_resume=",tostring(recent_resume),
        "internal_hint=",tostring(READER_REBUILD.internal_hint),"fuse=",tostring(fuse),
        "deadline_ms=",tostring(math.floor(READER_REBUILD.max_wait*1000+.5)))

    local task
    task=function()
        if self._reader_rebuild_task~=task then return end
        self._reader_rebuild_task=nil
        self:_finish_reader_rebuild_candidate(generation,READER_REBUILD.reason)
    end
    self._reader_rebuild_task=task
    UIManager:scheduleIn(.22,task)
    return true
end

function Plugin:_reader_rebuild_ready_state()
    if not reader_rebuild_active() then return false,false end
    local ready_path=normalized_reader_file(self:_current_document_path())
    local expected=normalized_reader_file(READER_REBUILD.reader_file)
    if ready_path and expected and ready_path==expected then
        local preserved_session=tonumber(READER_REBUILD.session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0
        local elapsed=math.floor((monotonic_wall_time()-(tonumber(READER_REBUILD.started_clock) or monotonic_wall_time()))*1000+.5)
        self:_reader_rebuild_cancel("ReaderReady same book",true)
        HOME_SESSION.reader_session_generation=preserved_session
        HOME_SESSION.reader_session_active=true
        HOME_SESSION.reader_session_file=ready_path
        logger.info("[MiuRead][Lifecycle] reader returned",
            "same_book=true","preserved_session=",tostring(preserved_session),
            "ms=",tostring(math.max(0,elapsed)))
        return true,true
    end
    local old_owner=READER_REBUILD.owner
    local old_path=READER_REBUILD.reader_file
    local old_session=READER_REBUILD.session_generation
    self:_reader_rebuild_cancel("ReaderReady different book",true)
    if old_owner and type(old_owner._finalize_reader_instance_close)=="function" then
        pcall(old_owner._finalize_reader_instance_close,old_owner,old_path,old_session,
            {document_switch=true,reason="different ReaderReady"})
    end
    logger.info("[MiuRead][Lifecycle] reader returned","same_book=false",
        "old=",tostring(old_path or ""),"new=",tostring(ready_path or ""))
    return true,false
end

function Plugin:onPageUpdate(page)
    self:_mark_reader_busy(2)
    local cache=self:_reader_toolbar_cache()
    local current=tonumber(page)
    if current then cache.page=current end
    -- Page turns only update the in-memory position immediately. Chapter/ToC
    -- lookup is delayed until the reader has been idle, keeping the flip path
    -- free of optional work.
    self:_schedule_reader_toolbar_state_refresh(current,.55)
    self.sync:on_page(page)
end
function Plugin:_annotation_sync_preferences()
    local p=self.store:preferences()
    p.annotation_sync=type(p.annotation_sync)=="table" and p.annotation_sync or {}
    if p.annotation_sync.enabled==nil then p.annotation_sync.enabled=false end
    if tostring(p.annotation_sync.review_visibility or "")=="" then p.annotation_sync.review_visibility="private" end
    p.annotation_sync.highlight_style=tonumber(p.annotation_sync.highlight_style) or 1
    p.annotation_sync.highlight_color=tonumber(p.annotation_sync.highlight_color) or 0
    return p.annotation_sync,p
end

function Plugin:annotation_sync_diagnostic_only()
    return Config.ANNOTATION_COORD_DIAGNOSTIC_ONLY == true
end

function Plugin:annotation_sync_enabled()
    local prefs=self:_annotation_sync_preferences()
    return prefs.enabled==true
end

function Plugin:toggle_annotation_sync()
    local prefs,all=self:_annotation_sync_preferences()
    prefs.enabled=prefs.enabled~=true
    all.annotation_sync=prefs
    self.store:save_preferences(all)
    logger.info("[MiuRead][AnnotationSync] enabled changed",
        "enabled=",tostring(prefs.enabled==true),"mode=manual")
    if prefs.enabled then
        self:toast("本地批注云同步已开启；当前为手动上传",2.5)
    else
        self:toast("本地批注云同步已关闭",2)
    end
    return prefs.enabled
end

function Plugin:annotation_sync_visibility_label()
    local prefs=self:_annotation_sync_preferences()
    local labels={public="公开",friendship="关注可见",private="私密",friends_hidden="屏蔽好友",one_book="共读"}
    return labels[tostring(prefs.review_visibility or "private")] or "私密"
end

function Plugin:set_annotation_sync_visibility(mode)
    local allowed={public=true,friendship=true,private=true,friends_hidden=true,one_book=true}
    mode=allowed[tostring(mode or "")] and tostring(mode) or "private"
    local prefs,all=self:_annotation_sync_preferences()
    prefs.review_visibility=mode
    all.annotation_sync=prefs
    self.store:save_preferences(all)
    self:toast("新想法云端可见范围："..self:annotation_sync_visibility_label(),2)
end

function Plugin:annotation_sync_visibility_menu()
    local labels={{"public","公开"},{"friendship","关注可见"},{"private","私密"},{"friends_hidden","屏蔽好友"},{"one_book","共读"}}
    local rows={}
    for _,item in ipairs(labels) do
        local key,label=item[1],item[2]
        rows[#rows+1]={text=label,checked_func=function()
            local prefs=self:_annotation_sync_preferences(); return tostring(prefs.review_visibility)==key
        end,keep_menu_open=true,callback=function() self:set_annotation_sync_visibility(key) end}
    end
    return rows
end

function Plugin:show_local_annotation_sync_status()
    local current=self:_current_book_record()
    local book_id=current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id=="" then self:info("请先打开一本觅阅生成的书籍。") return false end
    self:_capture_local_annotation_snapshot("sync_status")
    local summary,err=LocalAnnotationDatabase.summary(self.store,book_id)
    if not summary then self:info("读取本地批注状态失败："..tostring(err or "未知错误")); return false end
    local lines={
        "《"..tostring(current.book.title or "当前书籍").."》",
        "",
        "书签："..tostring(summary.bookmark or 0),
        "划线："..tostring(summary.highlight or 0),
        "想法："..tostring(summary.thought or 0),
        "",
        "已同步："..tostring(summary.synced or 0),
        "待上传及重试："..tostring(summary.pending or 0),
        "待删除："..tostring(summary.delete_pending or 0),
        "待处理合计："..tostring((tonumber(summary.pending or 0) or 0)+(tonumber(summary.delete_pending or 0) or 0)),
        "定位失败："..tostring(summary.locate_failed or 0),
        "元数据失败："..tostring(summary.metadata_failed or 0),
        "坐标校验失败："..tostring(summary.coord_failed or 0),
        "结果未知："..tostring(summary.unknown or 0),
        "旧坐标已同步："..tostring(summary.legacy_synced or 0),
    }
    local failures=LocalAnnotationDatabase.failures(self.store,book_id,5)
    if type(failures)=="table" and #failures>0 then
        lines[#lines+1]=""
        lines[#lines+1]="最近失败："
        local kind_label={bookmark="书签",highlight="划线",thought="想法"}
        for _,failure in ipairs(failures) do
            lines[#lines+1]=string.format("- %s [%s] %s",
                kind_label[failure.kind] or tostring(failure.kind or "批注"),
                tostring(failure.stage or failure.state or "unknown"),
                U.utf8_truncate(tostring(failure.error or ""),72,""))
        end
    end
    self:info(table.concat(lines,"\n"))
    return true
end

function Plugin:_sync_progress_anchor_quietly()
    if not self:logged_in() then return false end
    local current = self.sync and self.sync:record() or self:_current_book_record()
    local book_id = current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id == "" then return false end
    if self.annotation_async and self.annotation_async:busy() then return false end

    local captured = self:_capture_local_annotation_snapshot("progress_anchor")
    if not captured then
        logger.info("[MiuRead][ProgressAnchor] snapshot unavailable", "book=", book_id)
        return false
    end

    local service = self.annotation_sync
    local prefs = U.copy(self:_annotation_sync_preferences())
    local book = U.copy(current.book or {})
    local record = U.copy(current.record or {})
    local started, err = self.annotation_async:run("annotation-sync", function()
        return service:sync_book(book, record, {preferences = prefs, limit = 200})
    end, function(worker_result)
        if not worker_result or worker_result.ok ~= true then
            logger.warn("[MiuRead][ProgressAnchor] sync failed",
                tostring(worker_result and worker_result.error or "worker failed"))
            return
        end
        local result = worker_result.value or {}
        if result.ok == false then
            logger.warn("[MiuRead][ProgressAnchor] sync failed", tostring(result.error or "unknown"))
            return
        end
        logger.info("[MiuRead][ProgressAnchor] synced",
            "book=", book_id, "synced=", tostring(result.synced or 0))
    end, 180)
    if not started then
        logger.warn("[MiuRead][ProgressAnchor] start failed", tostring(err or "busy"))
    end
    return started
end

function Plugin:sync_local_annotations_now(force_diagnostic)
    local diagnostic_only=force_diagnostic==true or self:annotation_sync_diagnostic_only()
    logger.info("[MiuRead][AnnotationSync] manual sync requested",
        diagnostic_only and "mode=coordinate_diagnostic" or "mode=manual", "explicit=true")
    if not self:logged_in() then self:info("请先登录微信读书账号。") return false end
    local current=self:_current_book_record()
    local book_id=current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id=="" then self:info("请先打开一本觅阅生成的书籍。") return false end
    if self.annotation_async and self.annotation_async:busy() then
        self:toast("本地批注正在同步",1.5)
        return false
    end
    if not self:_capture_local_annotation_snapshot("manual_sync") then
        self:info("保存本地批注状态失败，本次未执行云同步。")
        return false
    end
    local prefs=U.copy(self:_annotation_sync_preferences())
    local book=U.copy(current.book or {})
    local record=U.copy(current.record or {})
    local service=self.annotation_sync
    self:toast(diagnostic_only and "正在生成批注坐标诊断…" or "正在同步本地批注…",2)
    local started,err=self.annotation_async:run("annotation-sync",function()
        return service:sync_book(book,record,{preferences=prefs,limit=200,diagnostic_only=diagnostic_only})
    end,function(worker_result)
        if not worker_result or worker_result.ok~=true then
            self:info(self:_friendly_action_error(worker_result and worker_result.error or "后台任务失败","本地批注同步","annotations"))
            return
        end
        local result=worker_result.value or {}
        if result.ok==false then
            self:info(self:_friendly_action_error(result.error or "未知错误","本地批注同步","annotations"))
            return
        end
        if result.diagnostic_only==true then
            local lines={
                "批注坐标诊断完成",
                "",
                "云端批注写入：已暂停",
                "导出章节："..tostring(result.diagnostic_exported or 0),
                "检查本地批注："..tostring(result.total or 0),
            }
            if tonumber(result.failed or 0)>0 then
                lines[#lines+1]="定位异常："..tostring(result.failed or 0)
            end
            lines[#lines+1]=""
            lines[#lines+1]="文件目录："
            lines[#lines+1]=tostring(result.diagnostic_root or "")
            lines[#lines+1]=""
            lines[#lines+1]="请把对应章节文件夹、thoughts.sqlite3、local_annotations.sqlite3 和生成的 EPUB 一起给 AI。"
            self:info(table.concat(lines,"\n"))
            return
        end
        local lines={
            "本地批注同步完成",
            "",
            "已同步："..tostring(result.synced or 0),
            "已删除："..tostring(result.deleted or 0),
            "云端已存在："..tostring(result.reconciled or 0),
            "定位失败："..tostring(result.locate_failed or 0),
            "元数据失败："..tostring(result.metadata_failed or 0),
            "坐标校验失败："..tostring(result.coord_failed or 0),
            "结果未知："..tostring(result.unknown or 0),
            "旧坐标已同步："..tostring(result.legacy_synced or 0).."（不会自动重传）",
        }
        if tonumber(result.failed or 0)>0 then lines[#lines+1]="待处理合计："..tostring(result.failed or 0) end
        if type(result.errors)=="table" and #result.errors>0 then
            lines[#lines+1]=""
            lines[#lines+1]="未上传："
            local kind_label={bookmark="书签",highlight="划线",thought="想法"}
            for index,item in ipairs(result.errors) do
                if index>6 then break end
                if type(item)=="table" then
                    lines[#lines+1]=string.format("- %s [%s] %s",
                        kind_label[item.kind] or tostring(item.kind or "批注"),
                        tostring(item.stage or "unknown"),
                        U.utf8_truncate(tostring(item.error or ""),72,""))
                else
                    lines[#lines+1]="- "..U.utf8_truncate(tostring(item),88,"")
                end
            end
            lines[#lines+1]=""
            lines[#lines+1]="以上记录仍保留在本地，没有猜测错误位置。"
        end
        self:info(table.concat(lines,"\n"))
    end,180)
    if not started then self:info(self:_friendly_action_error(err or "后台任务不可用","本地批注同步启动","annotations")); return false end
    return true
end

function Plugin:_local_annotation_chapter_context(item,current,kind,reason,prepared)
    if type(current)~="table" then return {} end
    local record=type(current.record)=="table" and current.record or {}
    local book=type(current.book)=="table" and current.book or {}
    local manual=reason=="manual_sync"
    local selected,before,after="","",""
    if manual and (kind=="highlight" or kind=="thought") then
        selected,before,after=self:_reader_annotation_selection_context(item,kind)
    end
    local anchor=(kind=="bookmark" and (manual or reason=="progress_anchor" or reason=="suspend_anchor")) and self:_reader_bookmark_anchor_text(item) or ""

    local standalone_uid=tostring(record.chapter_uid or "")
    if standalone_uid~="" then
        return {
            chapter_uid=standalone_uid,
            chapter_idx=tonumber((record.chapter_map or {})[1] and (record.chapter_map or {})[1].index) or 1,
            selected_text=selected, context_before=before, context_after=after,
            anchor_text=anchor,
        }
    end

    prepared=type(prepared)=="table" and prepared or {}
    local chapter_map=type(prepared.chapter_map)=="table" and prepared.chapter_map
        or (type(record.chapter_map)=="table" and record.chapter_map
        or (type(book.catalog)=="table" and book.catalog or {}))
    if #chapter_map==0 then
        return {selected_text=selected,context_before=before,context_after=after,anchor_text=anchor}
    end

    local toc=prepared.toc or (self.ui and self.ui.toc or nil)
    local toc_index

    -- Prefer the annotation XPointer: for rolling documents it identifies the
    -- real spine position more precisely than an estimated rendered page.
    local xp=self:_reader_annotation_xpointer(item)
    if xp and toc and type(toc.getTocIndexByPage)=="function" then
        local ok,value=pcall(toc.getTocIndexByPage,toc,xp)
        if ok then toc_index=tonumber(value) end
    end

    local page=self:_reader_annotation_page(item)
    if not toc_index and page and toc and type(toc.getTocIndexByPage)=="function" then
        local ok,value=pcall(toc.getTocIndexByPage,toc,page)
        if ok then toc_index=tonumber(value) end
    end
    local toc_rows=type(prepared.toc_rows)=="table" and prepared.toc_rows
        or (toc and type(toc.toc)=="table" and toc.toc or {})
    if page and not toc_index then
        local page_rows=type(prepared.toc_page_rows)=="table" and prepared.toc_page_rows or nil
        if page_rows and #page_rows>0 then
            local lo,hi,best=1,#page_rows,nil
            while lo<=hi do
                local mid=math.floor((lo+hi)/2)
                if page_rows[mid].page<=page then best=page_rows[mid].index; lo=mid+1
                else hi=mid-1 end
            end
            toc_index=best
        else
            local best=-math.huge
            for index,entry in ipairs(toc_rows) do
                local p=tonumber(entry.page or entry.pageno)
                if p and p<=page and p>=best then best=p; toc_index=index end
            end
        end
    end

    local index=math.max(1,math.min(#chapter_map,math.floor(tonumber(toc_index) or 1)))
    local chapter=chapter_map[index] or {}
    local uid=tostring(chapter.uid or chapter.chapterUid or chapter.chapter_uid or "")
    return {
        chapter_uid=uid,
        chapter_idx=tonumber(chapter.index) or index,
        selected_text=selected, context_before=before, context_after=after,
        anchor_text=anchor,
    }
end

function Plugin:_capture_local_annotation_snapshot(reason)
    if not (self.ui and self.ui.document) then return false end
    local total_started=monotonic_wall_time()
    -- During reading Sync already owns the current book record. Avoid a full
    -- Store:reload() before every local snapshot; only fall back when the
    -- reader has not established a sync record yet.
    local current=(self.sync and self.sync:record()) or self:_current_book_record()
    local book_id=current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id=="" then return false end
    local annotations=(self.ui.annotation and self.ui.annotation.annotations)
        or (self.ui.bookmark and self.ui.bookmark.bookmarks) or {}
    if reason=="manual_sync" or reason=="progress_anchor" or reason=="suspend_anchor" then
        local rows={}
        for _, item in ipairs(annotations) do rows[#rows+1]=item end
        local anchor=self:_progress_anchor_item()
        if anchor then rows[#rows+1]=anchor end
        annotations=rows
    end

    local record=type(current.record)=="table" and current.record or {}
    local book=type(current.book)=="table" and current.book or {}
    local chapter_map=type(record.chapter_map)=="table" and record.chapter_map
        or (type(book.catalog)=="table" and book.catalog or {})
    local prepared={chapter_map=chapter_map,toc_prepare_ms=0}
    if tostring(record.chapter_uid or "")=="" and #chapter_map>0 then
        local toc_started=monotonic_wall_time()
        local toc=self.ui and self.ui.toc or nil
        if toc and type(toc.fillToc)=="function" then pcall(toc.fillToc,toc) end
        local toc_rows=toc and type(toc.toc)=="table" and toc.toc or {}
        local page_rows={}
        for index,entry in ipairs(toc_rows) do
            local page=tonumber(entry.page or entry.pageno)
            if page then page_rows[#page_rows+1]={page=page,index=index} end
        end
        table.sort(page_rows,function(a,b)
            if a.page==b.page then return a.index<b.index end
            return a.page<b.page
        end)
        prepared.toc=toc
        prepared.toc_rows=toc_rows
        prepared.toc_page_rows=page_rows
        prepared.toc_prepare_ms=math.floor((monotonic_wall_time()-toc_started)*1000+.5)
    end

    local snapshot_started=monotonic_wall_time()
    local ok,result=xpcall(function()
        return LocalAnnotationDatabase.snapshot(self.store,book_id,annotations,current.path,function(item,kind)
            return self:_local_annotation_chapter_context(item,current,kind,reason,prepared)
        end)
    end,debug.traceback)
    local snapshot_ms=math.floor((monotonic_wall_time()-snapshot_started)*1000+.5)
    local total_ms=math.floor((monotonic_wall_time()-total_started)*1000+.5)
    if ok and result then
        logger.info("[MiuRead][LocalAnnotations] snapshot saved",
            "book=",book_id,"count=",tostring(result.count or 0),
            "toc_ms=",tostring(prepared.toc_prepare_ms or 0),
            "snapshot_ms=",tostring(snapshot_ms),
            "total_ms=",tostring(total_ms),
            "reason=",tostring(reason or "quiet"))
        return true
    end
    logger.warn("[MiuRead][LocalAnnotations] snapshot failed",
        "book=",book_id,"toc_ms=",tostring(prepared.toc_prepare_ms or 0),
        "snapshot_ms=",tostring(snapshot_ms),"total_ms=",tostring(total_ms),
        "reason=",tostring(reason or "quiet"),tostring(result))
    return false
end

function Plugin:_schedule_local_annotation_snapshot(reason,delay)
    if not (self.ui and self.ui.document) then return false end
    if self._local_annotation_snapshot_task then
        UIManager:unschedule(self._local_annotation_snapshot_task)
        self._local_annotation_snapshot_task=nil
    end
    local task
    task=function()
        if self._local_annotation_snapshot_task~=task then return end
        self._local_annotation_snapshot_task=nil
        self:_capture_local_annotation_snapshot(reason)
    end
    self._local_annotation_snapshot_task=task
    UIManager:scheduleIn(math.max(.5,tonumber(delay) or 2.4),task)
    return true
end

function Plugin:onAnnotationsModified()
    self._reader_checkpoint_dirty=true
    -- KOReader emits this for new, edited and deleted highlights/notes. Save
    -- once after a short quiet period so a later crash cannot discard a whole
    -- reading session, without writing on every pen movement.
    self:_schedule_reader_checkpoint("annotations_modified",2.0)
    -- Mirror KOReader's local records after the same quiet period. This phase is
    -- local-only: no range calculation and no network request runs in the pen/
    -- gesture callback.
    self:_schedule_local_annotation_snapshot("annotations_modified",2.4)
end
function Plugin:onSuspend()
    self._miuread_suspended=true
    HOME_SESSION.suspended=true
    HOME_SESSION.foreground_before_suspend=HOME_SESSION.foreground
    HOME_SESSION.navigation_before_suspend=self:_navigation_state()
    self:_set_foreground("suspended")
    StatusToast.set_blocked(true)
    StatusToast.close()
    self:_cancel_interactive_network("suspend")
    if self._local_annotation_snapshot_task then
        UIManager:unschedule(self._local_annotation_snapshot_task)
        self._local_annotation_snapshot_task=nil
    end
    self:_close_miuread_transients()
    self:_cancel_reader_close_settle("suspend")
    if self._home_resume_surface_task then
        UIManager:unschedule(self._home_resume_surface_task)
        self._home_resume_surface_task=nil
    end
    if reader_rebuild_active() then
        local owner=READER_REBUILD.owner
        if owner and owner._reader_rebuild_task then
            pcall(UIManager.unschedule,UIManager,owner._reader_rebuild_task)
            owner._reader_rebuild_task=nil
        end
        if owner and owner~=self and owner.sync and type(owner.sync.on_suspend)=="function" then
            pcall(owner.sync.on_suspend,owner.sync)
        end
        READER_REBUILD.state="suspended_pending"
    end
    if HomeView.suspend then HomeView.suspend() end
    if READER_CLOSE.state=="idle" then
        HOME_SESSION.return_requested=false
        HOME_SESSION.return_session_generation=0
        HOME_SESSION.return_request_file=nil
    end
    if self._reader_dimension_task then
        UIManager:unschedule(self._reader_dimension_task)
        self._reader_dimension_task=nil
    end
    if self._reader_checkpoint_dirty==true then
        self:_flush_reader_checkpoint("suspend",true)
    end
    -- Freeze every home producer before KOReader paints the lock screen.  The
    -- visible home widget is preserved; only stale work and callbacks are
    -- invalidated, so wake-up never has to rebuild the page before showing it.
    if HomeView.is_shown() and not self:_active_reader_ui() then
        self:_home_freeze_for_suspend()
    end
    -- Stop the download child at its next safe boundary before KOReader paints
    -- the lock screen. The process and chapter checkpoints remain intact.
    if self.download_task then self.download_task:on_suspend() end
    if self._download_resume_task then
        UIManager:unschedule(self._download_resume_task)
        self._download_resume_task=nil
    end
    -- No interaction/helper timer is allowed to wake or poll background work
    -- after Suspend has taken ownership. DownloadTask:on_suspend() already
    -- removed all UI-only pause reasons in the same marker write.
    self._reader_interaction_resume_generation=(tonumber(self._reader_interaction_resume_generation) or 0)+1
    if self._reader_interaction_resume_task then
        UIManager:unschedule(self._reader_interaction_resume_task)
        self._reader_interaction_resume_task=nil
    end
    if self._reader_toolbar_state_task then
        UIManager:unschedule(self._reader_toolbar_state_task)
        self._reader_toolbar_state_task=nil
    end
    if self._post_reader_work_task then
        UIManager:unschedule(self._post_reader_work_task)
        self._post_reader_work_task=nil
        HOME_SESSION.post_reader_work_deferred_phase="suspend:"..tostring(HOME_SESSION.post_reader_work_phase or "")
    end
    self:_mark_reader_busy(10)
    self._suspended_at=os.time()
    logger.info("[MiuRead][Suspend] lifecycle timers cancelled",
        "rebuild=",tostring(reader_rebuild_active()),"rotation=true","resume=true")
    self._suspend_anchor_book_id = nil
    if self.ui and self.ui.document then
        local current = self.sync and self.sync:record() or self:_current_book_record()
        local book_id = current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
        if book_id ~= "" then
            self:_capture_local_annotation_snapshot("suspend_anchor")
            self._suspend_anchor_book_id = book_id
        end
    end
    self.sync:on_suspend()
end
function Plugin:onResume()
    self._miuread_suspended=false
    HOME_SESSION.suspended=false
    StatusToast.set_blocked(false)
    local close_pending=reader_close_active()
    local native_menu_pending=NATIVE_MENU_GUARD.active==true
    if close_pending then
        self:_set_foreground("reader_transition")
        self:_schedule_reader_return_finish(READER_CLOSE.generation,.25,"resume close watcher")
    elseif native_menu_pending then
        self:_set_navigation_state("native_menu","resume into KOReader menu")
    end
    if self._reader_active_path then U.atomic_write(self._reader_active_path,"1",true) end
    self:_mark_reader_busy(5)
    local slept=self._suspended_at and os.time()-self._suspended_at or 0
    self._suspended_at=nil
    HOME_SESSION.last_resume_clock=monotonic_wall_time()
    self._resume_lifecycle_generation=(tonumber(self._resume_lifecycle_generation) or 0)+1
    local resume_generation=self._resume_lifecycle_generation

    local reader_active=self.ui and self.ui.document
    if reader_rebuild_active() then
        if reader_active then
            self:_reader_rebuild_ready_state()
        else
            local owner=READER_REBUILD.owner
            if owner and type(owner._finish_reader_rebuild_candidate)=="function" then
                READER_REBUILD.state="pending"
                local generation=READER_REBUILD.generation
                UIManager:scheduleIn(.35,function()
                    if resume_generation~=self._resume_lifecycle_generation or HOME_SESSION.suspended==true then return end
                    pcall(owner._finish_reader_rebuild_candidate,owner,generation,"resume rebuild re-evaluation")
                end)
            end
        end
    end
    if close_pending then
        self:_ensure_reader_transition_guard("resume during reader close")
        self:_schedule_download_resume_after_wake(3.5)
    elseif native_menu_pending then
        self:_schedule_download_resume_after_wake(3.5)
    end
    if reader_active and not close_pending and not native_menu_pending then
        self:_close_home_for_reader("resume into reader")
        self:_ensure_reader_transition_guard("resume into reader")
        self:_set_foreground("reader")
        UIManager:nextTick(function()
            if self.ui and self.ui.document then
                self:_install_reader_menu_bridge()
                self:_install_reader_quick_panel_zone()
            end
        end)
        self:_schedule_download_resume_after_wake(3.5)
    end
    if not close_pending and not native_menu_pending and not reader_active and HomeView.is_shown() then
        self:_set_foreground("home")
        -- Restore the already-built surface and its input ranges first.  Shelf
        -- refresh, scans, covers and metadata remain behind the interaction
        -- barrier until the page has been released and idle.
        UIManager:nextTick(function()
            if resume_generation~=self._resume_lifecycle_generation
                or HOME_SESSION.suspended==true or self._miuread_suspended==true then return end
            self:_home_begin_resume(slept)
        end)
        UIManager:scheduleIn(1.0,function()
            if HomeView.is_shown() and not self:_active_reader_ui() then
                self:_resume_pending_post_reader_work("resume home",2.0)
            end
        end)
        return
    end

    if not close_pending and not native_menu_pending and not reader_active and not HomeView.is_shown() then
        if self:_home_enabled() and Session.home().reader_origin and not Session.home().native_visit
            and not Session.home().suppressed and not Session.home_exiting() then
            self:_set_foreground("home_pending")
            UIManager:scheduleIn(.12,function()
                if not self:_active_reader_ui() and HOME_SESSION.suspended~=true then
                    self:_restore_home_after_reader_close(1)
                end
            end)
        else
            self:_set_foreground("native")
            UIManager:scheduleIn(.05,function() UIManager:setDirty(nil,"ui") end)
        end
        self:_schedule_download_resume_after_wake(3.5)
    end
    local prefs=self.store:preferences().sync or {}
    local recheck=prefs.progress_enabled~=false and slept>=math.max(60,tonumber(prefs.resume_after) or 300)
    if recheck then
        self._progress_prompted_book_id=nil
        -- Keep the last verified state visible while wake-up revalidation runs.
        -- A transient Wi-Fi delay must not turn a healthy book into an error.
    end
    self.sync:on_resume(slept)
    if recheck then
        self:_wait_for_network("resume-progress",function(ready)
            if ready and self.ui and self.ui.document then
                self:ensure_read_report_progress("resume_recheck",true)
            elseif self.ui and self.ui.document then
                local r=self.sync:record()
                if r then self:_save_progress_state(tostring(r.book.book_id),"waiting_network",
                    "设备已唤醒，等待 Wi-Fi 完全恢复",nil,nil) end
            end
        end,{minimum_delay=6,max_wait=75,interval=3})
    end
    if self._suspend_anchor_book_id then
        local anchor_book_id = self._suspend_anchor_book_id
        self._suspend_anchor_book_id = nil
        self:_wait_for_network("resume-progress-anchor", function(ready)
            if ready and self.ui and self.ui.document then
                local current = self.sync and self.sync:record() or self:_current_book_record()
                local book_id = current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
                if book_id == anchor_book_id then
                    self:_sync_progress_anchor_quietly()
                end
            end
        end, {minimum_delay=2, max_wait=90, interval=3})
    end
end
function Plugin:_post_reader_work_needed()
    local pending=self.store:pending_installs()
    if type(pending)=="table" and #pending>0 then return "install",#pending end
    local queue=self.store:download_queue()
    if type(queue)=="table" and #queue>0 then return "queue",#queue end
    return nil,0
end

function Plugin:_resume_pending_post_reader_work(reason,delay)
    local phase=tostring(HOME_SESSION.post_reader_work_phase or "")
    if phase=="" or self._post_reader_work_task then return false end
    if self:_active_reader_ui() or ReaderTransitionGuard.is_shown() then return false end
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    if not HomeView.is_shown() and not (ok_fm and FileManager and FileManager.instance) then
        return false
    end
    return self:_schedule_post_reader_work(reason or "surface ready",delay or 2.0,phase)
end

function Plugin:_run_post_reader_work(generation)
    if generation~=(tonumber(HOME_SESSION.post_reader_work_generation) or 0) then return false end
    self._post_reader_work_task=nil
    local phase=tostring(HOME_SESSION.post_reader_work_phase or "")
    if self._miuread_suspended==true or HOME_SESSION.suspended==true then
        if phase~="" then HOME_SESSION.post_reader_work_deferred_phase="suspend:"..phase end
        return false
    end
    if phase=="" then
        HOME_SESSION.post_reader_work_deferred_phase=nil
        return true
    end

    local function reschedule(delay)
        local task
        task=function()
            if self._post_reader_work_task~=task then return end
            self._post_reader_work_task=nil
            self:_run_post_reader_work(generation)
        end
        self._post_reader_work_task=task
        UIManager:scheduleIn(math.max(.25,tonumber(delay) or .8),task)
        return false
    end

    if self:_active_reader_ui() or ReaderTransitionGuard.is_shown() then
        -- Do not poll while the user is reading. The next stable home/native
        -- surface or CloseDocument event resumes this exact pending phase.
        if tostring(HOME_SESSION.post_reader_work_deferred_phase or "")~=phase then
            logger.info("[MiuRead][Download] post-reader work deferred until reader closes",phase)
            HOME_SESSION.post_reader_work_deferred_phase=phase
        end
        return false
    end

    -- Returning to the bookshelf is latency-sensitive. Never let install or
    -- queue maintenance run before the page-transition barrier has released.
    if tostring(HOME_SESSION.page_transition_state or "idle")~="idle" then
        if tostring(HOME_SESSION.post_reader_work_deferred_phase or "")~="transition:"..phase then
            logger.info("[MiuRead][Download] post-reader work waiting for transition",phase)
            HOME_SESSION.post_reader_work_deferred_phase="transition:"..phase
        end
        return reschedule(.7)
    end

    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    if not HomeView.is_shown() and not (ok_fm and FileManager and FileManager.instance) then
        logger.info("[MiuRead][Download] post-reader work waiting for stable surface",phase)
        return reschedule(.8)
    end
    if HomeView.is_shown() and self:_home_ui_busy() then
        logger.info("[MiuRead][Download] post-reader work yielded to active home",phase)
        return reschedule(.8)
    end

    -- If the user touched the restored home after this work was queued, yield
    -- once more. This prevents a background install/check from stealing the
    -- first interaction after returning from a book.
    local interaction_generation=tonumber(HOME_SESSION.home_interaction_generation) or 0
    local scheduled_generation=tonumber(HOME_SESSION.post_reader_work_interaction_generation) or 0
    if interaction_generation~=scheduled_generation then
        HOME_SESSION.post_reader_work_interaction_generation=interaction_generation
        logger.info("[MiuRead][Download] post-reader work yielded to home interaction",phase)
        return reschedule(1.5)
    end

    HOME_SESSION.post_reader_work_deferred_phase=nil
    local phase_started=monotonic_wall_time()
    if phase=="install" then
        local ok,err=pcall(self._install_pending_downloads,self,true)
        if not ok then logger.warn("[MiuRead][Download] pending install failed",tostring(err)) end
        local queue=self.store:download_queue()
        if type(queue)=="table" and #queue>0 then
            HOME_SESSION.post_reader_work_phase="queue"
            HOME_SESSION.post_reader_work_interaction_generation=tonumber(HOME_SESSION.home_interaction_generation) or 0
            logger.info("[MiuRead][Download] post-reader phase complete",
                "phase=install","ms=",tostring(math.floor((monotonic_wall_time()-phase_started)*1000+.5)),
                "next=queue")
            return reschedule(.8)
        end
        HOME_SESSION.post_reader_work_phase=nil
        logger.info("[MiuRead][Download] post-reader phase complete",
            "phase=install","ms=",tostring(math.floor((monotonic_wall_time()-phase_started)*1000+.5)),
            "next=none")
        return true
    end
    if phase=="queue" then
        local ok,err=pcall(self._start_next_queued_download,self)
        if not ok then logger.warn("[MiuRead][Download] queued start failed",tostring(err)) end
        HOME_SESSION.post_reader_work_phase=nil
        logger.info("[MiuRead][Download] post-reader phase complete",
            "phase=queue","ms=",tostring(math.floor((monotonic_wall_time()-phase_started)*1000+.5)),
            "next=none")
        return true
    end
    HOME_SESSION.post_reader_work_phase=nil
    return true
end

function Plugin:_schedule_post_reader_work(reason,delay,phase)
    phase=tostring(phase or HOME_SESSION.post_reader_work_phase or "")
    if phase=="" then
        local needed=self:_post_reader_work_needed()
        phase=tostring(needed or "")
    end
    if phase=="" then
        HOME_SESSION.post_reader_work_phase=nil
        HOME_SESSION.post_reader_work_deferred_phase=nil
        if self._post_reader_work_task then
            UIManager:unschedule(self._post_reader_work_task)
            self._post_reader_work_task=nil
        end
        logger.info("[MiuRead][Download] post-reader work skipped",tostring(reason or "close"),"nothing pending")
        return false
    end

    HOME_SESSION.post_reader_work_phase=phase
    HOME_SESSION.post_reader_work_deferred_phase=nil
    HOME_SESSION.post_reader_work_interaction_generation=tonumber(HOME_SESSION.home_interaction_generation) or 0
    HOME_SESSION.post_reader_work_generation=(tonumber(HOME_SESSION.post_reader_work_generation) or 0)+1
    self._post_reader_work_generation=HOME_SESSION.post_reader_work_generation
    local generation=self._post_reader_work_generation
    if self._post_reader_work_task then
        UIManager:unschedule(self._post_reader_work_task)
        self._post_reader_work_task=nil
    end
    local task
    task=function()
        if self._post_reader_work_task~=task then return end
        self._post_reader_work_task=nil
        self:_run_post_reader_work(generation)
    end
    self._post_reader_work_task=task
    UIManager:scheduleIn(math.max(0,tonumber(delay) or 2.0),task)
    logger.info("[MiuRead][Download] post-reader work scheduled",tostring(reason or "close"),phase)
    return true
end

function Plugin:onCloseDocument()
    local closing_path=normalized_reader_file(self:_current_document_path())
        or normalized_reader_file(HOME_SESSION.reader_session_file)
        or normalized_reader_file(Session.home().reader_file)
    local opening_path=normalized_reader_file(HOME_SESSION.opening_file)
    local session_generation=tonumber(HOME_SESSION.reader_session_generation) or 0
    local explicit_return=reader_close_active()
        and (self._miuread_return_requested==true or HOME_SESSION.return_requested==true)
    local expected_close=Session.home().expected_close or Session.home_exiting()
        or HOME_SESSION.expected_close==true or HOME_SESSION.exiting==true or UIManager._exit_code~=nil

    -- Preserve a genuine switch target. It is distinct from an unexplained
    -- disappearance of the current ReaderUI.
    local switching_document=opening_path and closing_path and opening_path~=closing_path
    if not switching_document and (opening_path==nil or opening_path==closing_path) then
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
    end

    if explicit_return or expected_close then
        if tostring(HOME_SESSION.page_transition_state or "")~="closing_reader" and not expected_close then
            self:_begin_page_transition("closing_reader")
        end
        if not expected_close then self:_ensure_reader_transition_guard("close document") end
        self:_reader_rebuild_cancel("explicit/expected close",true)
        return self:_finalize_reader_instance_close(closing_path,session_generation,
            {explicit_return=explicit_return,reason=expected_close and "expected document close" or "explicit document close"})
    end

    if switching_document then
        self:_reader_rebuild_cancel("explicit document switch",true)
        self:_prepare_reader_disappearance("document switch")
        if self.sync then self.sync:on_close() end
        logger.info("[MiuRead][Lifecycle] document switch observed",
            "old=",tostring(closing_path or ""),"new=",tostring(opening_path or ""))
        return true
    end

    -- No MiuRead/Home request exists. Treat this first as an internal ReaderUI
    -- rebuild candidate and stay out of Home/FileManager lifecycle until KOReader
    -- either returns a Reader or the bounded deadline proves it really closed.
    self:_prepare_reader_disappearance("reader rebuild candidate")
    local internal_hint=self.ui and self.ui.tearing_down==true
    logger.info("[MiuRead][Lifecycle] document disappeared","cause=unknown",
        "book=",tostring(closing_path or ""),"session=",tostring(session_generation),
        "tearing_down=",tostring(internal_hint))
    return self:_start_reader_rebuild_candidate(closing_path,session_generation,
        "CloseDocument without explicit return",internal_hint)
end

function Plugin:onFlushSettings()
    self:_mark_ui_preferences_flushed()
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    self:_flush_reader_checkpoint("flush_settings",true)
    self:_flush_cover_index()
    self.store:flush()
end
logger.info("[MiuRead][Startup] main.lua loaded",
    "ms=",tostring(math.floor((monotonic_wall_time()-MAIN_LOAD_STARTED_AT)*1000+.5)))
return Plugin
