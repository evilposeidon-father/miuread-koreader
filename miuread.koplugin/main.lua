-- MiuRead 觅阅 · 微信读书助手
-- 许可证：AGPL-3.0-only。
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
local PluginCrashReport=require("miuread.plugin_crash_report")
local PluginUpdate=require("miuread.plugin_update")
local PluginSync=require("miuread.plugin_sync")
local PluginSyncCenter=require("miuread.plugin_sync_center")
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
local PluginHomeCustomize=require("miuread.plugin_home_customize")
local PluginUiMenus=require("miuread.plugin_ui_menus")
local PluginHomeContent=require("miuread.plugin_home_content")
local Json=require("miuread.json")
local Store=require("miuread.store")
local Http=require("miuread.http")
local Api=require("miuread.api")
local Auth=require("miuread.auth")
local Reader=require("miuread.content_reader")
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
local AnnotationKinds = require("miuread.annotation_kinds")
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
PluginCrashReport.install(Plugin)
PluginUpdate.install(Plugin)
PluginSync.install(Plugin)
PluginSyncCenter.install(Plugin)
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
PluginHomeCustomize.install(Plugin)
PluginUiMenus.install(Plugin)
PluginHomeContent.install(Plugin)
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
    -- Silent sync scheduler: timers use UIManager, the gate uses the live
    -- login/network state, and actions are the existing sync entry points.
    self:_ensure_sync_scheduler()
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
    -- Crash detection runs after a full successful init: any crash.log growth
    -- is then guaranteed to come from previous runs, not this one.
    pcall(self.crash_report_startup, self)
    -- Session keepalive: renew the web session on book open and on a daily
    -- timer to reduce how often a server-side TTL recycle forces re-scanning.
    pcall(self.sync.schedule_login_keepalive_loop, self.sync)
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
        local ReaderChild=require("miuread.content_reader")
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
    if tostring(a.api_key or "")=="" or next(a.cookies or {})==nil then return false end
    -- A persisted login-expired error means the WeChat authorization was revoked
    -- server-side even though local credentials still exist. Treat it as logged
    -- out so the UI shows a re-login prompt instead of a misleading "已登录".
    local health=self:_auth_health()
    local code=tostring(health.last_error_code or "")
    if code=="-2011" or code=="-2012" or code=="-2041" then return false end
    return true
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
    local label=annotations and "划线与想法版（旧版）" or "纯净版"
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
        {text="重新生成划线与想法版（旧版）",callback=function() self:_confirm_current_book_rebuild(book,true) end},
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
    -- A pending reader-only cloud pull must not follow the plugin back to the
    -- home screen where it would retry its gate forever.
    self:_sync_scheduler_cancel("external_annotations")

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
    -- Dynamic cloud annotations follow the reading position (throttled).
    self:_external_annotation_page_update(page)
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
        for _,failure in ipairs(failures) do
            lines[#lines+1]=string.format("- %s [%s] %s",
                AnnotationKinds.label(failure.kind),
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
            for index,item in ipairs(result.errors) do
                if index>6 then break end
                if type(item)=="table" then
                    lines[#lines+1]=string.format("- %s [%s] %s",
                        AnnotationKinds.label(item.kind),
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
    local anchor=(kind=="bookmark" and (manual or tostring(item.id or "")=="miu-progress-anchor")) and self:_reader_bookmark_anchor_text(item) or ""

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
    -- Fluency: the explicit-open refresh is throttled. Any successful snapshot
    -- (including mutation-triggered ones) arms a short cooldown, so repeatedly
    -- opening the annotation panel does not re-run a full mirror upsert on the
    -- UI thread every time.
    if reason == "annotation_panel"
        and monotonic_wall_time() - (self._local_annotation_panel_snapshot_at or 0) < 15 then
        return true
    end
    local total_started=monotonic_wall_time()
    -- During reading Sync already owns the current book record. Avoid a full
    -- Store:reload() before every local snapshot; only fall back when the
    -- reader has not established a sync record yet.
    local current=(self.sync and self.sync:record()) or self:_current_book_record()
    local book_id=current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id=="" then return false end
    local annotations=(self.ui.annotation and self.ui.annotation.annotations)
        or (self.ui.bookmark and self.ui.bookmark.bookmarks) or {}
    -- The synthetic progress anchor is a single, always-present bookmark row.
    -- Keep it in every snapshot so ordinary annotation snapshots do not mark
    -- it absent and accidentally delete its remote bookmark.
    do
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
        self._local_annotation_panel_snapshot_at = monotonic_wall_time()
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
        local captured=self:_capture_local_annotation_snapshot(reason)
        -- Annotation edits trigger the same silent upload path the shortcut
        -- uses: debounce first, then a quiet background worker.
        if captured and reason=="annotations_modified" then
            self:_sync_scheduler_request("local_annotations",12,reason)
        end
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
    -- Power-key suspend: kick off a best-effort annotation/thought sync before
    -- the device sleeps. KOReader pauses the process during suspend, so the
    -- request completes after wake and its callback shows the result then.
    self:_sync_annotations_before_suspend()
end

function Plugin:_sync_annotations_before_suspend()
    local current = self:_current_book_record()
    local book_id = current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id == "" or not self:logged_in() then return false end
    if self.annotation_async and self.annotation_async:busy() then return false end
    if self._sleep_sync_guard then return false end
    self._sleep_sync_guard = true
    local prefs = U.copy(self:_annotation_sync_preferences())
    local book = U.copy(current.book or {})
    local record = U.copy(current.record or {})
    local service = self.annotation_sync
    local ok, err = self.annotation_async:run("annotation-sync-suspend", function()
        return service:sync_book(book, record, {preferences=prefs, limit=200})
    end, function(worker_result)
        self._sleep_sync_guard = false
        local synced = worker_result and worker_result.ok == true
            and worker_result.value and worker_result.value.ok == true
        if not self._miuread_suspended then
            self:toast(synced and "息屏前批注已同步" or "息屏前批注同步未完成", 2.5)
        end
    end)
    if not ok then self._sleep_sync_guard = false end
    return true
end

-- 休眠按钮（觅阅首页/阅读器「休眠」）：先同步批注/想法与阅读时长，完成后
-- 提示结果再真正息屏；8 秒超时兜底，失败也照常息屏（用户要求"失败报失败再息屏"）。
function Plugin:_sleep_sync_then_suspend()
    if self._sleep_sync_busy then return true end
    self._sleep_sync_busy = true
    local done = false
    local function finish(label)
        if done then return end
        done = true
        self._sleep_sync_busy = false
        if label then self:toast(label, 1.8) end
        UIManager:flushSettings()
        UIManager:suspend()
    end
    -- 阅读时长：daemon final flush（若在阅读会话中）
    if self.sync and not self.sync.suspended and self.ui and self.ui.document then
        pcall(function()
            local elapsed = 0
            if type(self.sync._final_elapsed) == "function" then
                elapsed = math.max(0, math.floor(tonumber(self.sync:_final_elapsed(true)) or 0))
            end
            self.sync:stop_fast("sleep", elapsed)
        end)
    end
    local current = self:_current_book_record()
    local book_id = current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id == "" or not self:logged_in() or (self.annotation_async and self.annotation_async:busy()) then
        finish(nil)
        return true
    end
    local timeout = UIManager:scheduleIn(8, function() finish("同步超时，即将休眠") end)
    pcall(function() self:_capture_local_annotation_snapshot("sleep_sync") end)
    local prefs = U.copy(self:_annotation_sync_preferences())
    local book = U.copy(current.book or {})
    local record = U.copy(current.record or {})
    local service = self.annotation_sync
    local started, err = self.annotation_async:run("annotation-sync-sleep", function()
        return service:sync_book(book, record, {preferences=prefs, limit=200})
    end, function(worker_result)
        UIManager:unschedule(timeout)
        if worker_result and worker_result.ok == true and worker_result.value and worker_result.value.ok == true then
            finish("批注与阅读时长已同步，即将休眠")
        else
            finish("同步未完成，即将休眠")
        end
    end)
    if not started then
        UIManager:unschedule(timeout)
        finish(nil)
    end
    return true
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
    self:_restore_miuread_highlight_action_policy()
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
