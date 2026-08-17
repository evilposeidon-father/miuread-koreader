-- MiuRead home mode / background scheduling controller, split from main.lua.
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local U = require("miuread.util")
local Text = require("miuread.text")
local Config = require("miuread.config")
local Session = require("miuread.session_state")
local HomeView = require("miuread.home_view")
local HomeData = require("miuread.home_data")
local TimeZone = require("miuread.timezone")
local UiScale = require("miuread.ui_scale")
local Lazy = require("miuread.lazy")
local LocalLibrary = Lazy("miuread.local_library")
local HomeLayouts = require("miuread.home_layout_constants")
local GestureBridge = require("miuread.gesture_bridge")
local RawButtonDialog = require("ui/widget/buttondialog")
local RawInputDialog = require("ui/widget/inputdialog")

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
local RUNTIME_MODE_KEY = HomeLayouts.RUNTIME_MODE_KEY
local quick_boolean_layout_matches = HomeLayouts.quick_boolean_layout_matches
local quick_order_matches = HomeLayouts.quick_order_matches

local HOME_SESSION = Session.home()

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ButtonDialog = gesture_aware_class(RawButtonDialog, {_miuread_transient=true, _miuread_modal_surface=true})
local InputDialog = gesture_aware_class(RawInputDialog, {_miuread_transient=true, _miuread_modal_surface=true})

local _ = Text.tr

local ok_socket, socket = pcall(require, "socket")
local function monotonic_wall_time()
    if ok_socket and socket and type(socket.gettime) == "function" then return socket.gettime() end
    return os.time()
end

-- Mirrors main.lua's local normalize.
local function normalize(v) local b=v.bookInfo or v.book or v; return {bookId=tostring(b.bookId or v.bookId or ""),title=b.title or v.title or "未命名",author=b.author or v.author or "",cover=b.cover or v.cover,category=b.category or v.category,progress=tonumber(v.progress or b.progress or 0) or 0,updateTime=tonumber(v.updateTime or b.updateTime or 0) or 0} end

local Plugin = {}

function Plugin:_bluetooth_state(_force)
    -- Bluetooth is owned by KOReader's loaded Bluetooth controller/plugin.
    -- MiuRead only exposes the existing capability in its toolbar.
    local manager=rawget(_G,"KOBluetoothStateManager")
    local controller=rawget(_G,"_bt_controller_instance")
    if not manager or not controller or type(manager.isOn)~="function" then
        return {known=true,supported=false,enabled=false}
    end
    local ok,enabled=pcall(function() return manager:isOn()==true end)
    if not ok then return {known=false,supported=true,enabled=false} end
    return {known=true,supported=true,enabled=enabled==true}
end

function Plugin:_bluetooth_supported()
    local state=self:_bluetooth_state(false)
    return state.supported==true
end

function Plugin:_home_panel_item_available(key)
    if key=="bluetooth" then return self:_bluetooth_supported() end
    if key=="sleep" then return Device:canSuspend()==true end
    return true
end

function Plugin:_bluetooth_toggle()
    if not self:_bluetooth_supported() then
        self:toast("当前 KOReader 未提供蓝牙控制",2)
        return false
    end
    -- Reuse the Bluetooth controller's registered KOReader event.
    UIManager:sendEvent(Event:new("ToggleBluetooth"))
    return true
end

function Plugin:_home_preferences()
    local preferences=self.store:preferences()
    preferences.home_ui=type(preferences.home_ui)=="table" and preferences.home_ui or {}
    local home=preferences.home_ui
    local changed=false
    if home.enabled==nil then home.enabled=true; changed=true end
    local old_layout_version=tonumber(home.layout_version) or 0
    if old_layout_version<20 then
        home.layout_version=20
        home.layout_style=home.layout_style=="compact" and "compact" or "desk"
        -- Keep the selected mode and page positions while upgrading the home
        -- structure. Removed experimental widget fields are no longer read.
        home.widgets=nil
        home.preset=nil
        home.goal_minutes=nil
        home.swipe_quick=nil
        home.initial_page=nil
        changed=true
    end
    if old_layout_version<23 then
        home.layout_version=23
        changed=true
    end
    -- v24: bottom-tab page key. Unknown values are dropped back to shelf so
    -- the page field can never desynchronize from the view/tab normalization.
    if old_layout_version<24 then
        home.layout_version=24
        changed=true
    end
    if home.page~=nil and HomeLayouts.normalize_page(home.page)~=home.page then
        home.page=nil
        changed=true
    end
    local shelf_sort=tostring(home.shelf_sort or "recent")
    if shelf_sort~="recent" and shelf_sort~="added" and shelf_sort~="title" and shelf_sort~="author" then
        home.shelf_sort=nil
        changed=true
    end
    if (tonumber(home.performance_defaults_version) or 0)<1 then
        -- Historical performance defaults are no longer allowed to change a
        -- feature switch during ordinary startup. The current local-library
        -- policy is normalized below from the user's saved choice.
        home.performance_defaults_version=1
        changed=true
    end
    if (tonumber(home.network_metadata_defaults_version) or 0)<2 then
        -- beta.35 repairs the historical beta.8 default once. After a user
        -- explicitly changes this switch, future upgrades must preserve it.
        if home.network_metadata_user_set~=true then home.network_metadata=true end
        home.network_metadata_defaults_version=2
        if home.network_metadata_user_set~=true then home.network_metadata_user_set=false end
        changed=true
    end
    if home.layout_style~="compact" and home.layout_style~="desk" then
        home.layout_style="desk"
        changed=true
    end
    if home.display_size~="compact" and home.display_size~="standard" and home.display_size~="large" then
        home.display_size="standard"
        changed=true
    end
    if home.ui_font_mode~="default" and home.ui_font_mode~="follow" and home.ui_font_mode~="custom" then
        home.ui_font_mode="default"
        changed=true
    end
    if type(home.ui_font_face)~="string" then home.ui_font_face=""; changed=true end
    if home.local_check_on_open==nil then home.local_check_on_open=true; changed=true end
    -- beta.16 removes the old mutually-exclusive auto/manual/folder modes.
    -- Updating the library and browsing it by folder are independent choices:
    -- the home grid is always a flat book shelf, while folder browsing remains
    -- available from the local-library entry.
    if (tonumber(home.local_browse_version) or 0)<2 then
        home.local_browse_version=2
        home.local_auto_update=true
        home.local_library_mode="auto" -- compatibility for older call sites
        home.auto_scan=true
        home.local_inline_path=nil
        home.local_inline_root=nil
        changed=true
    end
    if home.local_auto_update==nil then home.local_auto_update=true; changed=true end
    if home.local_library_mode~="auto" then home.local_library_mode="auto"; changed=true end
    if home.auto_scan~=(home.local_auto_update==true) then
        home.auto_scan=home.local_auto_update==true; changed=true
    end
    if type(home.visible_sections)~="table" then home.visible_sections={}; changed=true end
    for _,section in ipairs(HOME_SECTION_ORDER) do
        if home.visible_sections[section]==nil then home.visible_sections[section]=true; changed=true end
    end
    if type(home.source_order)~="table" then home.source_order={}; changed=true end
    local source_seen,source_order={},{}
    for _,section in ipairs(home.source_order) do
        if home.visible_sections[section]~=nil and not source_seen[section] then
            source_seen[section]=true
            source_order[#source_order+1]=section
        end
    end
    for _,section in ipairs(HOME_SECTION_ORDER) do
        if not source_seen[section] then source_seen[section]=true; source_order[#source_order+1]=section end
    end
    if table.concat(source_order,"|")~=table.concat(home.source_order,"|") then changed=true end
    home.source_order=source_order
    if home.auto_hide_empty==nil then home.auto_hide_empty=false; changed=true end
    local function normalize_quick_group(items_key,order_key,version_key,expected_version,item_order,item_defaults)
        if type(home[items_key])~="table" then home[items_key]={}; changed=true end
        if type(home[order_key])~="table" then home[order_key]={}; changed=true end
        if (tonumber(home[version_key]) or 0)<expected_version then
            -- Layout upgrades are incremental: keep explicit visibility and
            -- ordering, then append only genuinely new keys below. Special
            -- migrations that remove/replace a key run before this helper.
            home[version_key]=expected_version
            changed=true
        end
        for _,key in ipairs(item_order) do
            if home[items_key][key]==nil then home[items_key][key]=item_defaults[key]==true; changed=true end
        end
        local seen,normalized={},{}
        for _,key in ipairs(home[order_key]) do
            if item_defaults[key]~=nil and not seen[key] then seen[key]=true; normalized[#normalized+1]=key end
        end
        for _,key in ipairs(item_order) do
            if not seen[key] then seen[key]=true; normalized[#normalized+1]=key end
        end
        if table.concat(normalized,"|")~=table.concat(home[order_key],"|") then changed=true end
        home[order_key]=normalized
    end
    -- Home action layout v3 permanently removes frontlight from the homepage
    -- shortcut candidate set. It also repairs the beta.20 order where Sleep was
    -- inserted before an old Frontlight entry and pushed MiuRead Settings out
    -- of the six visible slots. User customizations are preserved otherwise.
    if (tonumber(home.action_layout_version) or 0)<HOME_ACTION_LAYOUT_VERSION then
        home.action_items=type(home.action_items)=="table" and home.action_items or {}
        home.action_order=type(home.action_order)=="table" and home.action_order or U.copy(HOME_ACTION_ITEM_V1_ORDER)
        local old_v1_recommended=quick_boolean_layout_matches(home.action_items,HOME_ACTION_ITEM_V1_DEFAULT,HOME_ACTION_ITEM_V1_ORDER)
            and quick_order_matches(home.action_order,HOME_ACTION_ITEM_V1_ORDER)
        local old_v2_recommended=quick_boolean_layout_matches(home.action_items,HOME_ACTION_ITEM_V2_DEFAULT,HOME_ACTION_ITEM_V2_ORDER)
            and quick_order_matches(home.action_order,HOME_ACTION_ITEM_V2_ORDER)
        local had_frontlight=home.action_items.frontlight==true
        if home.action_items.sleep==nil then
            home.action_items.sleep=(had_frontlight and Device:canSuspend()==true) or false
        end
        if old_v1_recommended or old_v2_recommended then
            home.action_items.sleep=Device:canSuspend()==true
            home.action_items.miuread_settings=true
        end
        home.action_items.frontlight=nil

        local seen,cleaned={},{}
        for _,name in ipairs(home.action_order) do
            if name~="frontlight" and HOME_ACTION_ITEM_DEFAULT[name]~=nil and not seen[name] then
                seen[name]=true
                cleaned[#cleaned+1]=name
            end
        end
        local function insert_after(after_key,key)
            if seen[key] then return end
            local out,inserted={},false
            for _,name in ipairs(cleaned) do
                out[#out+1]=name
                if name==after_key then out[#out+1]=key; inserted=true end
            end
            if not inserted then out[#out+1]=key end
            cleaned=out; seen[key]=true
        end
        insert_after("sync","sleep")
        insert_after("sleep","miuread_settings")
        for _,key in ipairs(HOME_ACTION_ITEM_ORDER) do
            if not seen[key] then seen[key]=true; cleaned[#cleaned+1]=key end
        end
        home.action_order=cleaned
        home.action_layout_version=HOME_ACTION_LAYOUT_VERSION
        changed=true
    end
    -- Layout v4 removes the retired "sync" shortcut from the home action bar:
    -- sync is fully automatic and must never ask for attention. Everything
    -- else the user customized is preserved.
    if (tonumber(home.action_layout_version) or 0)<HOME_ACTION_LAYOUT_VERSION then
        home.action_items=type(home.action_items)=="table" and home.action_items or {}
        home.action_items.sync=nil
        local seen,cleaned={},{}
        for _,name in ipairs(home.action_order) do
            if name~="sync" and HOME_ACTION_ITEM_DEFAULT[name]~=nil and not seen[name] then
                seen[name]=true; cleaned[#cleaned+1]=name
            end
        end
        for _,key in ipairs(HOME_ACTION_ITEM_ORDER) do
            if not seen[key] then seen[key]=true; cleaned[#cleaned+1]=key end
        end
        home.action_order=cleaned
        home.action_layout_version=HOME_ACTION_LAYOUT_VERSION
        changed=true
    end
    normalize_quick_group("action_items","action_order","action_layout_version",HOME_ACTION_LAYOUT_VERSION,HOME_ACTION_ITEM_ORDER,HOME_ACTION_ITEM_DEFAULT)
    -- Never reintroduce the retired homepage-frontlight key from merged legacy
    -- preferences. Direct frontlight control is rendered by HomeQuickPanel.
    if home.action_items.frontlight~=nil then home.action_items.frontlight=nil; changed=true end
    -- Pull-down layout v3 expands the control strip from six to eight slots.
    -- Old recommended layouts move to the new recommendation. Customized
    -- layouts keep their choices and receive Bluetooth as an opt-in candidate.
    if (tonumber(home.panel_layout_version) or 0)<HOME_PANEL_LAYOUT_VERSION then
        home.panel_items=type(home.panel_items)=="table" and home.panel_items or {}
        home.panel_order=type(home.panel_order)=="table" and home.panel_order or U.copy(HOME_PANEL_ITEM_V1_ORDER)
        local old_v1_recommended=quick_boolean_layout_matches(home.panel_items,HOME_PANEL_ITEM_V1_DEFAULT,HOME_PANEL_ITEM_V1_ORDER)
            and quick_order_matches(home.panel_order,HOME_PANEL_ITEM_V1_ORDER)
        local old_v2_recommended=quick_boolean_layout_matches(home.panel_items,HOME_PANEL_ITEM_V2_DEFAULT,HOME_PANEL_ITEM_V2_ORDER)
            and quick_order_matches(home.panel_order,HOME_PANEL_ITEM_V2_ORDER)
        if old_v1_recommended or old_v2_recommended then
            home.panel_items={}
            for _,key in ipairs(HOME_PANEL_ITEM_ORDER) do home.panel_items[key]=HOME_PANEL_ITEM_DEFAULT[key]==true end
            home.panel_order=U.copy(HOME_PANEL_ITEM_ORDER)
        else
            home.panel_items.frontlight=nil
            if home.panel_items.bluetooth==nil then home.panel_items.bluetooth=false end
            local seen,kept={},{}
            for _,name in ipairs(home.panel_order) do
                if name~="frontlight" and HOME_PANEL_ITEM_DEFAULT[name]~=nil and not seen[name] then
                    seen[name]=true; kept[#kept+1]=name
                end
            end
            for _,name in ipairs(HOME_PANEL_ITEM_ORDER) do
                if not seen[name] then seen[name]=true; kept[#kept+1]=name end
            end
            home.panel_order=kept
        end
        home.panel_layout_version=HOME_PANEL_LAYOUT_VERSION
        changed=true
    end
    -- Layout v4 removes the retired "sync" entry from the pull-down panel.
    if (tonumber(home.panel_layout_version) or 0)<HOME_PANEL_LAYOUT_VERSION then
        home.panel_items=type(home.panel_items)=="table" and home.panel_items or {}
        home.panel_items.sync=nil
        local seen,kept={},{}
        for _,name in ipairs(home.panel_order) do
            if name~="sync" and HOME_PANEL_ITEM_DEFAULT[name]~=nil and not seen[name] then
                seen[name]=true; kept[#kept+1]=name
            end
        end
        for _,name in ipairs(HOME_PANEL_ITEM_ORDER) do
            if not seen[name] then seen[name]=true; kept[#kept+1]=name end
        end
        home.panel_order=kept
        home.panel_layout_version=HOME_PANEL_LAYOUT_VERSION
        changed=true
    end
    normalize_quick_group("panel_items","panel_order","panel_layout_version",HOME_PANEL_LAYOUT_VERSION,HOME_PANEL_ITEM_ORDER,HOME_PANEL_ITEM_DEFAULT)
    -- Unsupported hardware controls disappear instead of leaving dead slots.
    if not Device:canSuspend() then
        if home.panel_items.sleep==true then home.panel_items.sleep=false; changed=true end
        if home.action_items.sleep==true then home.action_items.sleep=false; changed=true end
    end
    local panel_enabled=0
    for _,key in ipairs(home.panel_order or HOME_PANEL_ITEM_ORDER) do
        if home.panel_items[key]==true and self:_home_panel_item_available(key) then
            panel_enabled=panel_enabled+1
            if panel_enabled>8 then home.panel_items[key]=false; changed=true end
        end
    end
    if type(home.hidden_local_files)~="table" then home.hidden_local_files={}; changed=true end
    if home.more_expanded==nil then home.more_expanded=false; changed=true end
    if home.network_metadata==nil then home.network_metadata=true; changed=true end
    if home.background_thought_index~=nil then home.background_thought_index=nil; changed=true end
    if home.active_section~="account" and home.active_section~="generated" and home.active_section~="local" and home.active_section~="mp" then home.active_section="account"; changed=true end
    if home.lockscreen_recent==nil then home.lockscreen_recent=true; changed=true end
    home.local_root=tostring(home.local_root or "")
    local original_roots=type(home.local_roots)=="table" and home.local_roots or {}
    local normalized_roots,root_seen={},{}
    local function add_root(value)
        local item=type(value)=="table" and value or {path=value}
        local path=LocalLibrary.normalize(item.path or "")
        if path=="" or root_seen[path] or lfs.attributes(path,"mode")~="directory" then return end
        root_seen[path]=true
        normalized_roots[#normalized_roots+1]={
            path=path,
            name=U.trim(tostring(item.name or ""))~="" and U.trim(tostring(item.name)) or LocalLibrary.basename(path),
            enabled=item.enabled~=false,
            readonly=item.readonly~=false,
        }
    end
    for _,root in ipairs(original_roots) do add_root(root) end
    if #normalized_roots==0 then
        add_root(home.local_root)
        if #normalized_roots==0 then
            local legacy=self.store:get("home_local_index",{})
            if type(legacy)=="table" then add_root(legacy.root) end
        end
        if #normalized_roots==0 and lfs.attributes("/mnt/us/documents/Books","mode")=="directory" then
            add_root("/mnt/us/documents/Books")
        end
    end
    local function root_signature(rows)
        local parts={}
        for _,root in ipairs(rows or {}) do
            local item=type(root)=="table" and root or {path=root}
            parts[#parts+1]=table.concat({tostring(item.path or ""),tostring(item.name or ""),tostring(item.enabled~=false),tostring(item.readonly~=false)},"|")
        end
        return table.concat(parts,";")
    end
    if root_signature(original_roots)~=root_signature(normalized_roots) then changed=true end
    home.local_roots=normalized_roots
    home.local_root=normalized_roots[1] and normalized_roots[1].path or ""

    -- Direct browsing keeps its current folder in preferences so returning from
    -- a book or restarting KOReader restores the same level. Empty path means
    -- the multi-root picker; a single enabled root opens directly at its root.
    local old_inline_path=tostring(home.local_inline_path or "")
    local old_inline_root=tostring(home.local_inline_root or "")
    local inline_path=LocalLibrary.normalize(old_inline_path)
    local inline_root=LocalLibrary.normalize(old_inline_root)
    local enabled_roots={}
    for _,root in ipairs(normalized_roots) do if root.enabled~=false then enabled_roots[#enabled_roots+1]=root end end
    local matched_root
    if inline_path~="" and lfs.attributes(inline_path,"mode")=="directory" then
        for _,root in ipairs(enabled_roots) do
            if inline_path==root.path or inline_path:sub(1,#root.path+1)==root.path.."/" then
                matched_root=root
                break
            end
        end
    end
    if #enabled_roots==0 then
        inline_path=""; inline_root=""
    elseif matched_root then
        inline_root=matched_root.path
    elseif #enabled_roots==1 then
        inline_path=enabled_roots[1].path
        inline_root=enabled_roots[1].path
    else
        inline_path=""; inline_root=""
    end
    if old_inline_path~=inline_path or old_inline_root~=inline_root then changed=true end
    home.local_inline_path=inline_path
    home.local_inline_root=inline_root
    home.local_browse_version=2
    if type(home.page_by_section)~="table" then home.page_by_section={}; changed=true end
    if changed then self.store:save_preferences(preferences) end
    UiScale.setDisplayMode(home.display_size or "standard")
    UiScale.setFontName(self:_home_ui_font_name(home))
    return home,preferences
end

function Plugin:_save_ui_preferences(preferences,reason,delay)
    preferences=preferences or self.store:preferences()
    if not self.store.save_preferences_deferred then
        self.store:save_preferences(preferences)
        return true
    end
    self.store:save_preferences_deferred(preferences)
    self._ui_preferences_save_pending=true
    self._ui_preferences_save_generation=(tonumber(self._ui_preferences_save_generation) or 0)+1
    local generation=self._ui_preferences_save_generation
    UIManager:scheduleIn(math.max(.35,tonumber(delay) or 1.35),function()
        if generation~=(tonumber(self._ui_preferences_save_generation) or 0)
            or self._ui_preferences_save_pending~=true then return end
        self._ui_preferences_save_pending=false
        self.store:flush()
        logger.info("[MiuRead][UIState] preferences saved after idle",
            "reason=",tostring(reason or "ui"))
    end)
    return true
end

function Plugin:_mark_ui_preferences_flushed()
    if self._ui_preferences_save_pending~=true then return false end
    self._ui_preferences_save_generation=(tonumber(self._ui_preferences_save_generation) or 0)+1
    self._ui_preferences_save_pending=false
    return true
end

function Plugin:_save_home_preferences(home,preferences)
    preferences=preferences or self.store:preferences()
    preferences.home_ui=home
    self.store:save_preferences(preferences)
    UiScale.setDisplayMode(home.display_size or "standard")
    UiScale.setFontName(self:_home_ui_font_name(home))
end

function Plugin:_save_home_preferences_deferred(home,preferences,delay)
    preferences=preferences or self.store:preferences()
    preferences.home_ui=home
    if self.store.save_preferences_deferred then
        self.store:save_preferences_deferred(preferences)
    else
        return self:_save_home_preferences(home,preferences)
    end
    self._home_state_save_pending=true
    self._home_state_save_generation=(tonumber(self._home_state_save_generation) or 0)+1
    local generation=self._home_state_save_generation
    UIManager:scheduleIn(tonumber(delay) or 1.20,function()
        if generation~=self._home_state_save_generation or not self._home_state_save_pending then return end
        self._home_state_save_pending=false
        self.store:flush()
        logger.info("[MiuRead][HomeState] preferences saved after idle")
    end)
end

function Plugin:_flush_home_preferences()
    if not self._home_state_save_pending then return false end
    self._home_state_save_generation=(tonumber(self._home_state_save_generation) or 0)+1
    self._home_state_save_pending=false
    self.store:flush()
    logger.info("[MiuRead][HomeState] preferences saved before leaving home")
    return true
end

function Plugin:_home_section_cache_revision(section,page)
    self._home_section_revisions=type(self._home_section_revisions)=="table"
        and self._home_section_revisions or {}
    return table.concat({
        tostring(tonumber(self._home_data_revision) or 0),
        tostring(tonumber(self._home_section_revisions[section]) or 0),
        tostring(tonumber(page) or 1),
    },":")
end

function Plugin:_home_bump_section_revision(section)
    self._home_section_revisions=type(self._home_section_revisions)=="table"
        and self._home_section_revisions or {}
    self._home_section_revisions[section]=(tonumber(self._home_section_revisions[section]) or 0)+1
end

function Plugin:_home_enabled()
    return tostring(self._runtime_mode or rawget(_G,RUNTIME_MODE_KEY) or "plugin")=="desktop"
end

function Plugin:_configured_home_enabled()
    local home=self:_home_preferences()
    return home.enabled~=false
end

function Plugin:_runtime_mode_label()
    return self:_home_enabled() and "觅阅桌面" or "插件模式"
end

function Plugin:_configured_mode_label()
    return self:_configured_home_enabled() and "觅阅桌面" or "插件模式"
end

function Plugin:_home_mode_label()
    local current=self:_runtime_mode_label()
    local configured=self:_configured_mode_label()
    if current==configured then return current end
    return "当前"..current.." · 重启后"..configured
end

function Plugin:_mode_intro_preferences()
    local preferences=self.store:preferences()
    preferences.mode_intro=type(preferences.mode_intro)=="table" and preferences.mode_intro or {}
    return preferences.mode_intro,preferences
end

function Plugin:_mode_intro_pending_mode()
    local intro=self:_mode_intro_preferences()
    local mode=tostring(intro.pending_mode or "")
    if mode~="desktop" and mode~="plugin" then return "" end
    return mode
end

function Plugin:_mode_intro_needed()
    if self._reader_context then return false end
    if not self:_notice_enabled("mode_environment") then return false end
    local pending=self:_mode_intro_pending_mode()
    local runtime=self:_home_enabled() and "desktop" or "plugin"
    return pending~="" and pending==runtime
end

function Plugin:_set_mode_intro_pending(mode,reason)
    mode=tostring(mode or "")
    if mode~="desktop" and mode~="plugin" then return false end
    local intro,preferences=self:_mode_intro_preferences()
    intro.pending_mode=mode
    intro.pending_reason=tostring(reason or "user_switch")
    intro.pending_at=os.time()
    self.store:save_preferences(preferences)
    return true
end

function Plugin:_clear_mode_intro_pending()
    local intro,preferences=self:_mode_intro_preferences()
    if tostring(intro.pending_mode or "")=="" and tostring(intro.pending_reason or "")=="" then return false end
    intro.pending_mode=""
    intro.pending_reason=""
    intro.pending_at=0
    self.store:save_preferences(preferences)
    return true
end

function Plugin:_ack_mode_intro()
    local intro,preferences=self:_mode_intro_preferences()
    intro.last_confirmed_mode=self:_home_enabled() and "desktop" or "plugin"
    intro.confirmed_at=os.time()
    intro.pending_mode=""
    intro.pending_reason=""
    intro.pending_at=0
    self.store:save_preferences(preferences)
end

function Plugin:_desktop_compatibility_info()
    self:info("觅阅桌面会接管 KOReader 的部分主页、菜单、手势和阅读界面。\n\n如果同时启用了其他美化 UI 或美化补丁，可能造成卡顿、闪烁、菜单异常、手势失效或返回异常。\n\n建议使用觅阅桌面时，先禁用或删除其他美化 UI 和相关补丁。需要保留其他美化界面时，请使用插件模式。")
end

function Plugin:_show_mode_restart_notice(enabled)
    local text=enabled
        and "重启后将使用觅阅桌面。觅阅会提供完整主页和阅读快捷界面。"
        or "重启后将使用插件模式。KOReader 将继续管理主页和主要阅读界面，觅阅书架、下载、评论、同步、修复和账号功能仍可使用。"
    if not self:_notice_enabled("mode_switch") then
        self:toast("运行模式已保存，重启 KOReader 后生效",3)
        return true
    end
    local dialog
    dialog=ButtonDialog:new{title=text,title_align="center",buttons={
        {{text="立即重启",callback=function() UIManager:close(dialog); self:_restart_koreader("mode switch") end}},
        {{text="稍后重启",callback=function() UIManager:close(dialog); self:toast("运行模式将在重启后生效",3) end}},
        {{text="稍后重启并不再提示",callback=function()
            UIManager:close(dialog); self:_set_notice_enabled("mode_switch",false); self:toast("运行模式将在重启后生效",3)
        end}},
    }}
    UIManager:show(dialog)
    return true
end

function Plugin:_set_home_mode(use_miuread_home)
    local enabled=use_miuread_home==true
    local target_mode=enabled and "desktop" or "plugin"
    local home,preferences=self:_home_preferences()
    local configured=home.enabled~=false
    if configured==enabled then
        if self:_home_enabled()==enabled then
            self:_clear_mode_intro_pending()
            self:toast(enabled and "当前已是觅阅桌面模式" or "当前已是插件模式",2)
        else
            if self:_notice_enabled("mode_environment") and self:_mode_intro_pending_mode()~=target_mode then
                self:_set_mode_intro_pending(target_mode,"user_switch")
            end
            self:toast(enabled and "已设置重启后使用觅阅桌面" or "已设置重启后使用插件模式",2)
        end
        return false
    end
    home.enabled=enabled
    home.layout_version=24
    self:_save_home_preferences(home,preferences)
    if self:_home_enabled()==enabled then
        self:_clear_mode_intro_pending()
        self:toast("已取消待切换模式，当前继续使用"..self:_runtime_mode_label(),3)
        return true
    end
    if self:_notice_enabled("mode_environment") then
        self:_set_mode_intro_pending(target_mode,"user_switch")
    else
        self:_clear_mode_intro_pending()
    end
    return self:_show_mode_restart_notice(enabled)
end

function Plugin:_request_home_mode(enabled)
    return self:_set_home_mode(enabled==true)
end

function Plugin:_schedule_mode_intro_after_surface(delay)
    if not self:_mode_intro_needed() then return false end
    self._mode_intro_generation=(tonumber(self._mode_intro_generation) or 0)+1
    local generation=self._mode_intro_generation
    local attempts=0
    local function attempt()
        if generation~=self._mode_intro_generation or not self:_mode_intro_needed() then return end
        if Session.home_exiting() or UIManager._exit_code~=nil then return end
        if HOME_SESSION.suspended==true or self._miuread_suspended==true then
            UIManager:scheduleIn(.35,attempt)
            return
        end
        attempts=attempts+1
        local ready=false
        if self:_home_enabled() then
            ready=HomeView.is_shown() and not self:_active_reader_ui()
        else
            local navigation=self:_navigation_state()
            ready=not self:_active_reader_ui() and not self:_current_document_path()
                and navigation~="opening_reader" and navigation~="closing_reader"
                and navigation~="reader" and navigation~="suspended" and navigation~="exiting"
            if ready then
                local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
                if ok and FileManager then ready=FileManager.instance~=nil end
            end
        end
        if ready then
            UIManager:scheduleIn(.18,function()
                if generation==self._mode_intro_generation and self:_mode_intro_needed() then self:_show_mode_intro() end
            end)
            return
        end
        if attempts<50 then UIManager:scheduleIn(.15,attempt) end
    end
    UIManager:scheduleIn(tonumber(delay) or .8,attempt)
    return true
end

function Plugin:_show_mode_intro()
    if self._reader_context or not self:_mode_intro_needed() then return false end
    local desktop=self:_home_enabled()
    local dialog
    if desktop then
        dialog=ButtonDialog:new{
            title="当前使用：觅阅桌面\n\n觅阅桌面会提供完整主页、书架和阅读快捷界面，并接管 KOReader 的部分主页、菜单、手势和返回操作。\n\n如果同时启用了其他美化 UI 或美化补丁，可能造成卡顿、闪烁、菜单异常、手势失效或返回异常。\n\n建议先禁用或删除其他美化 UI 和相关补丁。需要保留 KOReader 原界面或其他美化 UI 时，可改用插件模式。",
            title_align="center",
            buttons={
                {{text="继续使用觅阅桌面",callback=function() UIManager:close(dialog); self:_ack_mode_intro() end}},
                {{text="切换到插件模式",callback=function()
                    UIManager:close(dialog); self:_ack_mode_intro(); self:_request_home_mode(false)
                end}},
            },
        }
    else
        dialog=ButtonDialog:new{
            title="当前使用：插件模式\n\n插件模式不会替换 KOReader 的主页和主要阅读界面，适合使用 KOReader 原界面，或搭配其他美化 UI 和美化补丁。\n\n微信书架、搜索、下载、评论、同步、修复和公众号等觅阅功能仍可使用。\n\n如果希望使用觅阅完整主页和阅读快捷界面，可以恢复觅阅桌面。恢复前建议先禁用或删除其他美化 UI 和相关补丁。",
            title_align="center",
            buttons={
                {{text="继续使用插件模式",callback=function() UIManager:close(dialog); self:_ack_mode_intro() end}},
                {{text="恢复觅阅桌面",callback=function()
                    UIManager:close(dialog); self:_ack_mode_intro(); self:_request_home_mode(true)
                end}},
            },
        }
    end
    UIManager:show(dialog)
    return true
end

function Plugin:_return_to_configured_home()
    if not self:_home_enabled() then self:toast("插件模式下不启用觅阅桌面",2); return false end
    if HomeView.is_shown() then HomeView.raise(); return true end
    if not (self.ui and self.ui.document) and Session.home().native_visit then return self:_return_from_native_filemanager() end
    if self:_active_reader_ui() then return self:return_to_miuread_home() end
    return self:show_miuread_home(false)
end

function Plugin:home_mode_menu()
    local rows={
        {text="使用觅阅桌面",post_text="主页 + 完整桌面阅读界面",radio=true,checked_func=function() return self:_configured_home_enabled() end,callback=function()
            self:_request_home_mode(true)
        end},
        {text="使用插件模式",post_text="保留 KOReader 或其他美化界面",radio=true,checked_func=function() return not self:_configured_home_enabled() end,callback=function()
            self:_request_home_mode(false)
        end},
        {text="当前运行",post_text=self:_home_mode_label(),enabled=false},
        {text="桌面模式兼容说明",callback=function() self:_desktop_compatibility_info() end},
    }
    return rows
end

function Plugin:_home_refresh_priority(kind)
    -- "page" is a full home-state repaint with the normal UI waveform.
    -- "full" remains the heavier structural rebuild used by settings/rotation.
    local priority={header=1,section=2,content=3,page=4,full=5}
    return priority[tostring(kind or "content")] or 3
end

function Plugin:_home_defer_refresh_kind(kind)
    kind=tostring(kind or "content")
    self._home_refresh_pending=true
    local current=self._home_refresh_pending_kind
    if not current or self:_home_refresh_priority(kind)>self:_home_refresh_priority(current) then
        self._home_refresh_pending_kind=kind
    end
    if self:_home_background_blocked() then
        local resume_current=self._home_resume_pending_kind
        if not resume_current or self:_home_refresh_priority(kind)>self:_home_refresh_priority(resume_current) then
            self._home_resume_pending_kind=kind
        end
    end
    return kind
end

function Plugin:_home_background_blocked()
    return self._home_suspended==true or self._home_resume_barrier==true
        or self:_page_transition_active()
end

function Plugin:_home_modal_surface_active()
    local stack=UIManager._window_stack or {}
    for index=#stack,1,-1 do
        local window=stack[index]
        local widget=window and window.widget or nil
        if widget and widget._miuread_modal_surface==true
            and widget._miuread_recovery_surface~=true
            and UIManager:isWidgetShown(widget) then
            self._home_modal_cooldown_until=math.max(
                tonumber(self._home_modal_cooldown_until) or 0,monotonic_wall_time()+2.6)
            return true
        end
    end
    return false
end

function Plugin:_home_ui_busy()
    local now=monotonic_wall_time()
    if self:_home_background_blocked() then return true end
    if self:_home_modal_surface_active() then return true end
    return now < (tonumber(self._home_ui_quiet_until) or 0)
        or now < (tonumber(self._home_post_reader_protect_until) or 0)
        or now < (tonumber(self._home_modal_cooldown_until) or 0)
end

function Plugin:_home_refresh_header_now(force_device,force_sync)
    if not HomeView.is_shown() or self:_active_reader_ui() then return false end
    if force_device==true then HomeData.quick_device_state(true) end
    return HomeView.update_header{
        account_name=self:_home_account_name(),
        wifi_text=self:_home_wifi_text(),
        time_text=self:_display_time("%H:%M"),
        battery_text=self:_home_battery_text(),
    }
end

function Plugin:_home_schedule_clock()
    self._home_clock_generation=(tonumber(self._home_clock_generation) or 0)+1
    local generation=self._home_clock_generation
    if self._home_clock_task then
        UIManager:unschedule(self._home_clock_task)
        self._home_clock_task=nil
    end
    if not HomeView.is_shown() or self:_active_reader_ui() then return false end
    HomeView.update_time(self:_display_time("%H:%M"))
    local task
    task=function()
        if generation~=self._home_clock_generation or self._home_clock_task~=task then return end
        if not HomeView.is_shown() then
            self._home_clock_task=nil
            return
        end
        if self._home_suspended~=true and HOME_SESSION.suspended~=true and not self:_active_reader_ui() then
            HomeView.update_time(self:_display_time("%H:%M"))
        end
        local now=os.time()
        UIManager:scheduleIn(math.max(10,60-(now%60)+.12),task)
    end
    self._home_clock_task=task
    local now=os.time()
    UIManager:scheduleIn(math.max(10,60-(now%60)+.12),task)
    return true
end

function Plugin:_home_schedule_stale_checks(delay)
    self._home_stale_check_generation=(tonumber(self._home_stale_check_generation) or 0)+1
    local generation=self._home_stale_check_generation
    if self._home_stale_check_task then
        UIManager:unschedule(self._home_stale_check_task)
        self._home_stale_check_task=nil
    end
    local task
    task=function()
        if generation~=self._home_stale_check_generation or self._home_stale_check_task~=task then return end
        if not HomeView.is_shown() or self:_active_reader_ui()
            or self._home_suspended==true or HOME_SESSION.suspended==true then
            self._home_stale_check_task=nil
            return
        end
        if self:_home_ui_busy() then
            UIManager:scheduleIn(self:_lightweight_enabled() and 1.2 or .75,task)
            return
        end
        self._home_stale_check_task=nil
        -- Cache first. Only stale sources are allowed to do work here.
        self:_home_refresh_remote(false,false)
        if self._home_active_section=="local" then self:_home_scan_local(false) end
    end
    self._home_stale_check_task=task
    local minimum=self:_lightweight_enabled()
        and (tonumber(Config.LIGHTWEIGHT_HOME_IDLE_DELAY) or 6) or .8
    UIManager:scheduleIn(math.max(minimum,tonumber(delay) or 4.5),task)
    return true
end

function Plugin:_home_resume_visible_work_after_idle()
    if self._home_ui_resume_task then UIManager:unschedule(self._home_ui_resume_task) end
    if self._home_suspended==true or HOME_SESSION.suspended==true then
        self._home_ui_resume_task=nil
        return false
    end
    local task
    task=function()
        if self._home_ui_resume_task~=task then return end
        if self._home_suspended==true or HOME_SESSION.suspended==true then
            self._home_ui_resume_task=nil
            return
        end
        if not HomeView.is_shown() or self:_active_reader_ui() then
            self._home_ui_resume_task=nil
            return
        end
        local now=monotonic_wall_time()
        if self:_home_modal_surface_active() then
            UIManager:scheduleIn(.45,task)
            return
        end
        local deadline=math.max(
            tonumber(self._home_ui_quiet_until) or 0,
            tonumber(self._home_post_reader_protect_until) or 0,
            tonumber(self._home_modal_cooldown_until) or 0)
        local remain=deadline-now
        if remain>0 then
            UIManager:scheduleIn(math.max(.20,remain+.08),task)
            return
        end
        if self:_home_background_blocked() then
            UIManager:scheduleIn(.45,task)
            return
        end
        self._home_ui_resume_task=nil
        -- Recent-reading changes are applied only after the post-reader/user
        -- interaction barrier releases. This keeps Reader->Home fast and uses
        -- a static hero-layer update instead of rebuilding the shelf.
        self:_home_refresh_recent_hero_cached()
        local pending_kind=self._home_refresh_pending_kind
        if pending_kind then
            self._home_refresh_pending_kind=nil
            self._home_refresh_pending=false
            self:_refresh_home_view(nil,pending_kind)
            UIManager:scheduleIn(.35,function()
                if HomeView.is_shown() and not self:_active_reader_ui() then
                    self:_home_resume_visible_work_after_idle()
                end
            end)
            return
        end
        local metadata=self._home_visible_metadata_targets or {}
        local covers=self._home_visible_cover_targets or {}
        self:_home_schedule_local_metadata(metadata)
        self:_home_schedule_remote_covers(covers)
        local pending_network_key=self._home_pending_network_metadata_key
        self._home_pending_network_metadata_key=nil
        if pending_network_key and self._home_hero
            and self:_home_network_metadata_key(self._home_hero)==pending_network_key then
            self:_home_schedule_network_metadata(self._home_hero,false)
        end
        UIManager:scheduleIn(.85,function()
            if HomeView.is_shown() and not self:_active_reader_ui() and not self:_home_ui_busy() then
                self:_home_schedule_cover_derivatives(covers)
            end
        end)
        if self.download_task then
            self.download_task:resume("home_interaction")
            self.download_task:resume("page_transition")
        end
        self:_home_schedule_stale_checks(1.1)
        logger.info("[MiuRead][HomePerf] background released after interaction")
    end
    self._home_ui_resume_task=task
    UIManager:scheduleIn(.35,task)
end

function Plugin:_home_enter_post_reader_priority_window(seconds,reason)
    if not HomeView.is_shown() then return false end
    local duration=math.max(4.0,tonumber(seconds) or 4.0)
    self._home_post_reader_protect_until=math.max(
        tonumber(self._home_post_reader_protect_until) or 0,monotonic_wall_time()+duration)
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    self._home_cover_render_generation=(tonumber(self._home_cover_render_generation) or 0)+1
    if self.home_metadata_async and self.home_metadata_async:busy() then self.home_metadata_async:cancel("post-reader priority") end
    if self.home_cover_async and self.home_cover_async:busy() then self.home_cover_async:cancel("post-reader priority") end
    if self.cover_render_async and self.cover_render_async:busy() then self.cover_render_async:cancel("post-reader priority") end
    self:_home_resume_visible_work_after_idle()
    logger.info("[MiuRead][HomePerf] post-reader priority window",
        "seconds=",tostring(duration),"reason=",tostring(reason or "reader closed"))
    return true
end

function Plugin:_home_bump_interaction_generation()
    HOME_SESSION.home_interaction_generation=(tonumber(HOME_SESSION.home_interaction_generation) or 0)+1
    self._home_interaction_generation=HOME_SESSION.home_interaction_generation
    return self._home_interaction_generation
end

function Plugin:_home_note_interaction(first,kind)
    self._home_ui_quiet_until=math.max(tonumber(self._home_ui_quiet_until) or 0,monotonic_wall_time()+2.2)
    self:_home_bump_interaction_generation()
    -- Stop optional visible-book work immediately; it can be restarted from
    -- cached targets after the user has been idle for a moment.
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    self._home_cover_render_generation=(tonumber(self._home_cover_render_generation) or 0)+1
    if self.home_metadata_async and self.home_metadata_async:busy() then self.home_metadata_async:cancel("home interaction") end
    if self.home_cover_async and self.home_cover_async:busy() then self.home_cover_async:cancel("home interaction") end
    if self.cover_render_async and self.cover_render_async:busy() then self.cover_render_async:cancel("home interaction") end
    if self.download_task and self.download_task:busy() then self.download_task:pause("home_interaction") end
    self:_home_resume_visible_work_after_idle()
    if first then
        logger.info("[MiuRead][HomePerf] interaction priority","kind=",tostring(kind or "input"))
    end
end

function Plugin:_home_unschedule_task(field)
    local task=self[field]
    if task then
        UIManager:unschedule(task)
        self[field]=nil
        return true
    end
    return false
end

function Plugin:_home_freeze_for_suspend()
    if self._home_suspended==true then return true end
    self._home_suspended=true
    self._home_resume_barrier=true
    self._home_resume_first_frame=false
    self._home_resume_generation=(tonumber(self._home_resume_generation) or 0)+1
    self._home_resume_started_clock=nil

    local cover_retry_pending=self._home_cover_render_retry_task~=nil
    self._home_resume_pending_work={
        scan=self._home_refreshing==true or (self.home_async and self.home_async:busy()) or false,
        remote=self._home_remote_refreshing==true or (self.shelf_async and self.shelf_async:busy()) or false,
        metadata=(self.home_metadata_async and self.home_metadata_async:busy()) or false,
        covers=(self.home_cover_async and self.home_cover_async:busy())
            or (self.cover_render_async and self.cover_render_async:busy())
            or cover_retry_pending or false,
    }
    if self._home_refresh_pending_kind then self:_home_defer_refresh_kind(self._home_refresh_pending_kind) end

    self:_home_unschedule_task("_home_refresh_task")
    self:_home_unschedule_task("_home_render_refresh_task")
    self:_home_unschedule_task("_home_resume_background_task")
    self:_home_unschedule_task("_home_ui_resume_task")
    self:_home_unschedule_task("_home_clock_task")
    self:_home_unschedule_task("_home_stale_check_task")
    self:_home_unschedule_task("_home_cover_render_retry_task")
    self:_home_unschedule_task("_home_manual_metadata_retry_task")
    self._home_pending_network_metadata_key=nil
    self._home_refresh_debounce_generation=(tonumber(self._home_refresh_debounce_generation) or 0)+1
    self._home_render_refresh_generation=(tonumber(self._home_render_refresh_generation) or 0)+1
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    self._shelf_refresh_generation=(tonumber(self._shelf_refresh_generation) or 0)+1
    self._home_refreshing=false
    self._home_remote_refreshing=false
    self._home_cover_inflight={}

    if self.home_async then self.home_async:cancel("device suspended") end
    if self.local_browser_async then self.local_browser_async:cancel("device suspended") end
    if self.home_metadata_async then self.home_metadata_async:cancel("device suspended") end
    if self.home_cover_async then self.home_cover_async:cancel("device suspended") end
    if self.cover_render_async then self.cover_render_async:cancel("device suspended") end
    if self.annotation_async then self.annotation_async:cancel("device suspended") end
    if self.updater_async then
        self.updater_async:cancel("device suspended")
        self._auto_update_check_running=false
    end
    if self.sync_summary_async then self.sync_summary_async:cancel("device suspended") end
    self:_home_unschedule_task("_home_sync_summary_task")
    if self.shelf_async and self._home_resume_pending_work.remote then self.shelf_async:cancel("device suspended") end

    logger.info("[MiuRead][Resume] home tasks frozen",
        "generation=",tostring(self._home_resume_generation),
        "scan=",tostring(self._home_resume_pending_work.scan),
        "remote=",tostring(self._home_resume_pending_work.remote),
        "metadata=",tostring(self._home_resume_pending_work.metadata),
        "covers=",tostring(self._home_resume_pending_work.covers))
    return true
end

function Plugin:_home_resume_visible_targets()
    local current=HomeView.current()
    local opts=current and current.opts or {}
    local metadata_targets,cover_targets={},{}
    if opts.hero then
        metadata_targets[#metadata_targets+1]=opts.hero
        cover_targets[#cover_targets+1]=opts.hero
    end
    for _,book in ipairs(opts.shelf_books or {}) do
        metadata_targets[#metadata_targets+1]=book
        cover_targets[#cover_targets+1]=book
    end
    return metadata_targets,cover_targets
end

function Plugin:_home_finish_resume_background(generation)
    if generation~=self._home_resume_generation or self._home_suspended==true then return false end
    self._home_resume_background_task=nil
    self._home_resume_barrier=false
    local pending_kind=self._home_resume_pending_kind or self._home_refresh_pending_kind
    self._home_resume_pending_kind=nil
    local pending=self._home_resume_pending_work or {}
    self._home_resume_pending_work=nil

    logger.info("[MiuRead][Resume] background released",
        "generation=",tostring(generation),"refresh=",tostring(pending_kind or "none"))

    if pending_kind then
        self._home_refresh_pending_kind=nil
        self._home_refresh_pending=false
        self:_notify_home_data_changed(pending_kind)
    end

    if pending.scan then
        UIManager:scheduleIn(.25,function()
            if generation==self._home_resume_generation and not self:_home_background_blocked() and HomeView.is_shown() then
                self:_home_scan_local(false)
            end
        end)
    end
    if pending.remote then
        UIManager:scheduleIn(.70,function()
            if generation==self._home_resume_generation and not self:_home_background_blocked() and HomeView.is_shown() then
                self:_home_refresh_remote(false,false)
            end
        end)
    end
    if pending.metadata or pending.covers then
        UIManager:scheduleIn(1.05,function()
            if generation~=self._home_resume_generation or self:_home_background_blocked() or not HomeView.is_shown() then return end
            local metadata_targets,cover_targets=self:_home_resume_visible_targets()
            if pending.metadata then self:_home_schedule_local_metadata(metadata_targets) end
            if pending.covers then
                self:_home_schedule_remote_covers(cover_targets)
                self:_home_schedule_cover_derivatives(cover_targets)
            end
        end)
    end
    if self.download_task then self.download_task:on_resume() end
    return true
end

function Plugin:_home_schedule_resume_background(delay,generation)
    generation=tonumber(generation) or tonumber(self._home_resume_generation) or 0
    self:_home_unschedule_task("_home_resume_background_task")
    local interaction_generation=tonumber(self._home_interaction_generation) or 0
    local task
    task=function()
        if self._home_resume_background_task~=task then return end
        self._home_resume_background_task=nil
        if generation~=self._home_resume_generation or self._home_suspended==true then return end
        if interaction_generation~=(tonumber(self._home_interaction_generation) or 0) then
            self:_home_schedule_resume_background(2.4,generation)
            return
        end
        self:_home_finish_resume_background(generation)
    end
    self._home_resume_background_task=task
    UIManager:scheduleIn(math.max(.5,tonumber(delay) or 3.5),task)
    return true
end

function Plugin:_home_resume_interaction(generation,first,kind)
    if generation~=self._home_resume_generation or self._home_suspended==true then return end
    self:_home_bump_interaction_generation()
    local elapsed=self._home_resume_started_clock and math.floor((os.clock()-self._home_resume_started_clock)*1000+.5) or -1
    if first then
        logger.info("[MiuRead][Resume] first interaction",
            "kind=",tostring(kind or "input"),"ms=",tostring(elapsed))
    end
    if self._home_resume_barrier==true then self:_home_schedule_resume_background(2.4,generation) end
end

function Plugin:_home_begin_resume(slept)
    self._home_suspended=false
    self._home_resume_barrier=true
    self._home_resume_first_frame=false
    self._home_resume_generation=(tonumber(self._home_resume_generation) or 0)+1
    local generation=self._home_resume_generation
    self._home_resume_started_clock=os.clock()
    self._home_resume_sleep_seconds=math.max(0,tonumber(slept) or 0)
    HOME_SESSION.last_resume_clock=monotonic_wall_time()

    if self._home_resume_surface_task then
        UIManager:unschedule(self._home_resume_surface_task)
        self._home_resume_surface_task=nil
    end

    local long_safe=self._home_resume_sleep_seconds>=7200
    logger.info("[MiuRead][Resume] event received",
        "generation=",tostring(generation),"slept=",tostring(self._home_resume_sleep_seconds),
        "mode=",long_safe and "long_safe_restore" or "normal")

    -- Do not touch UIManager's window ordering in the Resume callback. Kindle
    -- may still be restoring the framebuffer and orientation at that point.
    -- Wait for two identical geometry samples, then repaint/rebuild only the
    -- already-shown Home surface via public widget operations.
    local last_w,last_h,last_rotation,stable,attempts=nil,nil,nil,0,0
    local task
    task=function()
        if self._home_resume_surface_task~=task
            or generation~=self._home_resume_generation
            or self._home_suspended==true or HOME_SESSION.suspended==true then return end
        attempts=attempts+1
        local sw,sh=Device.screen:getWidth(),Device.screen:getHeight()
        local rotation=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil
        if sw==last_w and sh==last_h and rotation==last_rotation then
            stable=stable+1
        else
            last_w,last_h,last_rotation,stable=sw,sh,rotation,0
        end
        if stable<1 and attempts<7 then
            UIManager:scheduleIn(.12,task)
            return
        end
        self._home_resume_surface_task=nil
        local raised=HomeView.resume{
            rebuild_visual=long_safe,
            on_interaction=function(first,kind)
                self:_home_resume_interaction(generation,first,kind)
            end,
        }
        if not raised then
            self._home_resume_barrier=false
            self.sync:on_resume(slept)
            self:_schedule_home_startup(.12)
            logger.warn("[MiuRead][Resume] existing home unavailable; startup scheduled")
            return
        end
        self._home_resume_first_frame=true
        self:_home_schedule_clock()
        local elapsed=math.floor((os.clock()-self._home_resume_started_clock)*1000+.5)
        logger.info("[MiuRead][Resume] first surface released",
            "ms=",tostring(elapsed),"samples=",tostring(attempts),
            "mode=",long_safe and "long_safe_restore" or "normal")
        UIManager:scheduleIn(.10,function()
            if generation==self._home_resume_generation and self._home_suspended~=true then
                self.sync:on_resume(slept)
            end
        end)
        self:_home_schedule_resume_background(long_safe and 4.2 or 3.5,generation)
    end
    self._home_resume_surface_task=task
    UIManager:scheduleIn(.12,task)
    return true
end

function Plugin:_refresh_home_view(message,refresh_kind)
    if message and message~="" then self:toast(message,2) end
    if self:_home_background_blocked() then
        self:_home_defer_refresh_kind(refresh_kind or "content")
        logger.info("[MiuRead][Resume] home rebuild deferred",tostring(refresh_kind or "content"))
        return false
    end
    if HomeView.is_shown() then
        local kind=refresh_kind or "content"
        UIManager:scheduleIn(.05,function()
            if not HomeView.is_shown() or self:_active_reader_ui() then return end
            if kind=="header" then
                -- Header-only state changes must not reconstruct shelves or covers.
                self:_home_refresh_header_now(false,false)
            else
                self:_show_miuread_home_now(false,true,true,kind)
            end
        end)
        return true
    end
    return false
end

function Plugin:_notify_home_data_changed(refresh_kind)
    local requested=self:_home_defer_refresh_kind(refresh_kind or "content")
    if self:_home_background_blocked() then
        logger.info("[MiuRead][Resume] data refresh deferred",tostring(requested))
        return true
    end
    self._home_refresh_debounce_generation=(tonumber(self._home_refresh_debounce_generation) or 0)+1
    local generation=self._home_refresh_debounce_generation
    local task
    task=function()
        if generation~=self._home_refresh_debounce_generation then return end
        if not HomeView.is_shown() or self:_active_reader_ui() then
            self._home_refresh_task=nil
            return
        end
        if self:_home_ui_busy() then
            self._home_refresh_task=nil
            self:_home_resume_visible_work_after_idle()
            return
        end
        self._home_refresh_task=nil
        local kind=self._home_refresh_pending_kind or "content"
        self._home_refresh_pending_kind=nil
        self._home_refresh_pending=false
        self:_refresh_home_view(nil,kind)
    end
    if self._home_refresh_task then UIManager:unschedule(self._home_refresh_task) end
    self._home_refresh_task=task
    -- Several cover/download/status events inside this window become one
    -- ordinary e-ink UI update instead of a visible series of repaints.
    UIManager:scheduleIn(.25,task)
    return true
end

function Plugin:_home_schedule_render_refresh(kind)
    if self:_home_background_blocked() then
        self:_home_defer_refresh_kind(kind or "content")
        return false
    end
    self._home_render_refresh_generation=(tonumber(self._home_render_refresh_generation) or 0)+1
    local generation=self._home_render_refresh_generation
    local task
    task=function()
        if generation~=self._home_render_refresh_generation then return end
        self._home_render_refresh_task=nil
        if HomeView.is_shown() and not self:_active_reader_ui() then
            HomeView.refresh(kind or "content")
        end
    end
    self._home_render_refresh_task=task
    UIManager:scheduleIn(.35,task)
end

function Plugin:_home_apply_cover_path(book_id,path)
    book_id=tostring(book_id or "")
    path=tostring(path or "")
    if book_id=="" or path=="" then return false end
    local changed=false
    local function apply(book)
        if type(book)=="table" and tostring(book.bookId or book.book_id or "")==book_id
            and tostring(book.cover_path or "")~=path then
            book.cover_path=path
            -- A new raw source invalidates the small display derivative. The
            -- background renderer will replace it without blocking this view.
            book.home_cover_path=nil
            changed=true
        end
    end
    local hero_id=self:_home_cover_render_id(self._home_hero)
    hero_id=tostring(hero_id or "")
    apply(self._home_hero)
    for _,section in pairs(self._home_sections or {}) do
        for _,book in ipairs(section.rows or {}) do apply(book) end
    end
    if hero_id==book_id then
        local current=HomeView.current()
        if current and current.opts and not current.opts.screensaver_file then current.opts.screensaver_file=path end
    end
    return changed
end

function Plugin:_home_refresh_remote(force,user_requested)
    if self:_home_background_blocked() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.remote=true
        return false
    end
    if self._home_remote_refreshing or self:_active_reader_ui() then return false end
    local _,_,updated_at=self.library:cached()
    local now=os.time()
    local age=math.max(0,now-(tonumber(updated_at) or 0))
    local shelf_ttl=self:_lightweight_enabled()
        and (tonumber(Config.LIGHTWEIGHT_HOME_REMOTE_TTL) or 30*60)
        or HOME_SHELF_REFRESH_TTL
    if force~=true then
        if age<shelf_ttl then return false end
        if now-(tonumber(self._home_remote_auto_attempt_at) or 0)<HOME_REMOTE_AUTO_RETRY then return false end
    end
    if not self:logged_in() then
        if user_requested then self:toast("登录后才能刷新微信书架",3) end
        return false
    end
    if not self:is_online() then
        if user_requested then self:toast("当前没有网络连接",3) end
        return false
    end
    self._home_remote_refreshing=true
    if force~=true then self._home_remote_auto_attempt_at=now end
    if user_requested then self:toast("正在刷新书架…",2) end
    local started=self:_refresh_shelf_async(function(_,_,err)
        self._home_remote_refreshing=false
        if err then
            if user_requested then self:toast(self:_friendly_remote_error(err,"书架刷新"),4) end
            return
        end
        if HomeView.is_shown() and not self:_active_reader_ui() then
            self:_notify_home_data_changed("section")
        end
        if user_requested then self:toast("书架已刷新",2) end
    end,true)
    if not started then self._home_remote_refreshing=false end
    return started==true
end

function Plugin:_home_manual_refresh()
    local active=self._home_active_section or "account"
    if active=="account" or active=="mp" then
        local started=self:_home_refresh_remote(true,true)
        if not started and HomeView.is_shown() then self:_notify_home_data_changed("section") end
        return true
    end
    if active=="local" then
        local started=self:_home_scan_local(true)
        if started then self:toast("正在更新本地书库…",2)
        else self:toast("本地书库暂时无法开始更新",2) end
        return true
    end
    -- Generated books are already known to MiuRead. Reconcile its saved
    -- records/files only; do not scan arbitrary folders or query the network.
    self.store:reload()
    self.store:prune_missing_files()
    self:toast("正在更新已下载书籍…",2)
    self:_notify_home_data_changed("section")
    return true
end

function Plugin:_home_refresh_whole_page()
    if not HomeView.is_shown() or self:_active_reader_ui() then return false end
    -- "Refresh entire home" means show every state MiuRead already knows now.
    -- It does not force network, local scans, metadata lookups or a full-waveform
    -- e-ink refresh; those remain separate explicit actions.
    HomeData.quick_device_state(true)
    self._home_recent_read_dirty=true
    HOME_SESSION.recent_read_dirty=true
    local shown=self:_show_miuread_home_now(false,true,true,"page",{skip_background=true})
    if shown then
        self:_home_schedule_clock()
        self:toast("主页状态已刷新",2)
    end
    return shown==true
end

function Plugin:_home_complete_refresh(confirmed)
    if confirmed~=true and self:_notice_enabled("library_scan") then
        self:_confirm_library_scan(function() self:_home_complete_refresh(true) end)
        return true
    end
    self:_home_reset_local_metadata()
    self.store:reload()
    self.store:prune_missing_files()
    self:toast("正在完整更新书架与书籍信息…",3)
    self:_home_refresh_remote(true,false)
    self:_home_scan_local(true)
    UIManager:scheduleIn(.35,function()
        if HomeView.is_shown() and not self:_active_reader_ui() then
            self:_show_miuread_home_now(true,true,true,"content")
        end
    end)
    UIManager:scheduleIn(1.8,function()
        if HomeView.is_shown() and not self:_active_reader_ui() then UIManager:setDirty("all","full") end
    end)
    return true
end

function Plugin:_set_home_layout(style)
    style=style=="compact" and "compact" or "desk"
    local home,preferences=self:_home_preferences()
    home.layout_style=style
    home.layout_version=24
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(style=="compact" and "已切换到紧凑布局" or "已切换到标准布局","full")
end

function Plugin:_home_open_section(section)
    if section=="account" then return self:_home_leave_and_run("account shelf",function() self:show_shelf(false,false,"account") end) end
    if section=="generated" then return self:_home_leave_and_run("generated shelf",function() self:show_shelf(false,false,"generated") end) end
    if section=="local" then return self:_home_leave_and_run("local shelf",function() self:show_home_local_library() end) end
    return self:_home_leave_and_run("mp shelf",function() self:show_mp_shelf(false) end)
end

function Plugin:_home_visible_section_keys(sections,home)
    sections=sections or self._home_sections or {}
    home=home or self:_home_preferences()
    home.visible_sections=type(home.visible_sections)=="table" and home.visible_sections or {}
    local keys={}
    for _,section in ipairs(home.source_order or HOME_SECTION_ORDER) do
        local entry=sections[section]
        local enabled=home.visible_sections[section]~=false
        local empty=not entry or #(entry.rows or {})==0
        if enabled and (home.auto_hide_empty~=true or not empty) then keys[#keys+1]=section end
    end
    -- Never leave the home without a selectable source. When every visible
    -- source is empty, keep the first user-enabled one as an empty-state tab.
    if #keys==0 then
        for _,section in ipairs(home.source_order or HOME_SECTION_ORDER) do
            if home.visible_sections[section]~=false then keys[1]=section; break end
        end
    end
    if #keys==0 then
        home.visible_sections.account=true
        keys[1]="account"
    end
    return keys
end

function Plugin:_home_build_tabs(active)
    local tabs={}
    for _,section in ipairs(self._home_visible_keys or HOME_SECTION_ORDER) do
        local tab_section=section
        local entry=self._home_sections and self._home_sections[tab_section] or nil
        tabs[#tabs+1]={
            title=entry and entry.title or tab_section,
            count=entry and #(entry.rows or {}) or 0,
            selected=active==tab_section,
            on_tap=function() self:_set_home_section(tab_section) end,
        }
    end
    return tabs
end

function Plugin:_home_page_limit()
    -- 3.5 uses a stable 4 × 2 grid in both orientations.
    return 8
end

function Plugin:_home_preview_page(rows,hero,page,limit)
    limit=math.max(1,tonumber(limit) or self:_home_page_limit())
    local filtered,seen={},{}
    -- “继续阅读”是快捷入口，不应从对应书架中隐藏同一本书。
    -- 保留书架项目，确保标题数量、分页数量和实际可见内容一致。
    for _,book in ipairs(rows or {}) do
        local key=self:_home_book_key(book)
        if key~="" and not seen[key] then
            seen[key]=true
            filtered[#filtered+1]=book
        end
    end
    local has_folders=false
    for _,book in ipairs(filtered) do if book.local_folder==true or book.kind=="folder" then has_folders=true; break end end
    if has_folders then
        local packed,current,used={}, {}, 0
        local columns=4
        for _,book in ipairs(filtered) do
            local weight=(book.local_folder==true or book.kind=="folder") and 2 or 1
            -- A two-column folder card may not start in the last column. Count
            -- the unused slot before pagination so rendering never crosses the
            -- right edge when folders and books are mixed.
            local padding=(weight==2 and used%columns==columns-1) and 1 or 0
            if used>0 and used+padding+weight>limit then
                packed[#packed+1]=current; current={}; used=0; padding=0
            end
            used=used+padding
            current[#current+1]=book; used=used+weight
        end
        if #current>0 or #packed==0 then packed[#packed+1]=current end
        local total_pages=math.max(1,#packed)
        page=math.max(1,math.min(total_pages,tonumber(page) or 1))
        return packed[page] or {},page,total_pages,#filtered
    end
    local total_pages=math.max(1,math.ceil(#filtered/limit))
    page=math.max(1,math.min(total_pages,tonumber(page) or 1))
    local first=(page-1)*limit+1
    local preview={}
    for index=first,math.min(#filtered,first+limit-1) do preview[#preview+1]=filtered[index] end
    return preview,page,total_pages,#filtered
end

function Plugin:_home_page_for(section)
    local home=self:_home_preferences()
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    return math.max(1,tonumber(home.page_by_section[section]) or 1)
end

function Plugin:_home_change_page(delta)
    local section=self._home_active_section or "account"
    local selected=self._home_sections and self._home_sections[section]
    if not selected then return false end
    local home,preferences=self:_home_preferences()
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    local _,current,total=self:_home_preview_page(selected.rows,self._home_hero,home.page_by_section[section],self:_home_page_limit())
    local target=math.max(1,math.min(total,current+(tonumber(delta) or 0)))
    if target==current then return true end
    home.page_by_section[section]=target
    self:_home_bump_interaction_generation()
    self:_save_home_preferences_deferred(home,preferences)
    return self:_home_apply_section(section)
end

function Plugin:_home_apply_section(section)
    local selected=self._home_sections and self._home_sections[section]
    if not selected or not HomeView.is_shown() then return false end
    self._home_active_section=section
    local home=self:_home_preferences()
    local preview,page,total_pages=self:_home_preview_page(
        selected.rows,self._home_hero,
        home.page_by_section and home.page_by_section[section],
        self:_home_page_limit()
    )
    if not home.page_by_section or tonumber(home.page_by_section[section])~=page then
        local current,preferences=self:_home_preferences()
        current.page_by_section=type(current.page_by_section)=="table" and current.page_by_section or {}
        current.page_by_section[section]=page
        self:_save_home_preferences_deferred(current,preferences)
    end
    local started=os.clock()
    local updated=HomeView.update_section{
        tabs=self:_home_build_tabs(section),
        shelf_title=section=="local" and self:_home_local_inline_title() or "",
        shelf_books=preview,
        shelf_page=page,
        shelf_pages=total_pages,
        empty_text=selected.empty,
        on_open_book=function(book,anchor) self:_home_open_book(book,anchor) end,
        on_hold_book=function(book,anchor) self:_home_hold_book(book,anchor) end,
        home_actions=self:_home_action_entries(),
        on_shelf_all=function()
            if section=="local" then self:show_home_local_library()
            else self:show_home_all_books() end
        end,
        on_shelf_page=function(delta) self:_home_change_page(delta) end,
        section_cache_key=section,
        section_revision=self:_home_section_cache_revision(section,page),
    }
    -- Section switching stays in-memory, but the cover/metadata workers must
    -- still run for the newly shown page: otherwise a cold 已下载 section keeps
    -- placeholder covers until a full rebuild happens elsewhere.
    if type(preview) == "table" and #preview > 0 then
        self:_home_schedule_local_metadata(preview)
        self:_home_schedule_remote_covers(preview)
    end
    logger.info("[MiuRead][HomeSwitch] applied",
        "section=",tostring(section),"page=",tostring(page),
        "ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
    return updated
end

function Plugin:_set_home_section(section)
    local allowed={}
    for _,key in ipairs(self._home_visible_keys or HOME_SECTION_ORDER) do allowed[key]=true end
    section=allowed[section] and section or (self._home_visible_keys and self._home_visible_keys[1]) or "account"
    local home,preferences=self:_home_preferences()
    if home.active_section==section and self._home_active_section==section then return end
    home.active_section=section
    self:_home_bump_interaction_generation()
    self:_save_home_preferences_deferred(home,preferences)
    if self:_home_apply_section(section) then
        logger.info("[MiuRead][Home] section updated partial",tostring(section))
    else
        self:_refresh_home_view(nil,"section")
    end
    if section=="local" then
        UIManager:scheduleIn(.05,function()
            if HomeView.is_shown() and self._home_active_section=="local" then self:_home_ensure_local_inline_loaded() end
        end)
        self:_home_schedule_stale_checks(1.0)
    end
end

function Plugin:_home_cover_render_id(book)
    if type(book)~="table" then return nil end
    local id=tostring(book.bookId or book.book_id or "")
    if id~="" then return id end
    local seed=tostring(book.cover_path or book.file or book.title or "book")
    local hash=5381
    for i=1,#seed do hash=(hash*33+seed:byte(i))%4294967296 end
    return string.format("local-%08x",hash)
end

function Plugin:_home_prepare_lockscreen_cover(book)
    if type(book)~="table" then return nil end
    local width,height=Device.screen:getWidth(),Device.screen:getHeight()
    if width<=0 or height<=0 then return nil end
    local id=self:_home_cover_render_id(book)
    if not id then return tostring(book.cover_path or "")~="" and book.cover_path or nil end
    local dir=self.store.data_dir.."/lockscreen"
    U.mkdir(dir)
    local prefix=dir.."/"..U.id_name(id)
    local current=prefix.."-fill3-"..tostring(width).."x"..tostring(height)..".png"
    if lfs.attributes(current,"mode")=="file" and (tonumber(U.file_size(current) or 0) or 0)>0 then return current end
    -- Keep the beta.2 full-screen artifact as a temporary fallback while the
    -- sharper beta.3 image is rebuilt in a low-priority worker.
    local previous=prefix.."-fill2-"..tostring(width).."x"..tostring(height)..".png"
    if lfs.attributes(previous,"mode")=="file" and (tonumber(U.file_size(previous) or 0) or 0)>0 then return previous end
    local fallback=tostring(book.cover_path or "")
    return fallback~="" and fallback or nil
end

function Plugin:_home_apply_rendered_cover_path(book_id,path)
    book_id=tostring(book_id or "")
    path=tostring(path or "")
    if book_id=="" or path=="" then return false,false,{} end
    local changed=false
    local hero_changed=false
    local sections={}
    local function apply(book,section)
        if type(book)=="table" and tostring(self:_home_cover_render_id(book) or "")==book_id
            and tostring(book.home_cover_path or "")~=path then
            book.home_cover_path=path
            changed=true
            if section then sections[section]=true end
        end
    end
    if self._home_hero and tostring(self:_home_cover_render_id(self._home_hero) or "")==book_id then
        apply(self._home_hero)
        hero_changed=true
    end
    for key,section in pairs(self._home_sections or {}) do
        for _,book in ipairs(section.rows or {}) do apply(book,key) end
    end
    return changed,hero_changed,sections
end

function Plugin:_home_cover_target_fresh(target,inputs)
    target=tostring(target or "")
    if target=="" or lfs.attributes(target,"mode")~="file" then return false end
    if (tonumber(U.file_size(target) or 0) or 0)<=0 then return false end
    local target_mtime=tonumber(lfs.attributes(target,"modification") or 0) or 0
    if target_mtime<=0 then return false end
    local found=false
    for _,raw in ipairs(inputs or {}) do
        local path=tostring(raw or "")
        if path~="" and path~=target and lfs.attributes(path,"mode")=="file" then
            found=true
            local source_mtime=tonumber(lfs.attributes(path,"modification") or 0) or 0
            if source_mtime<=0 or source_mtime>target_mtime then return false end
        end
    end
    return found
end

function Plugin:_home_cover_input_stamp(inputs)
    local parts={}
    for _,raw in ipairs(inputs or {}) do
        local path=tostring(raw or "")
        if path~="" and lfs.attributes(path,"mode")=="file" then
            parts[#parts+1]=table.concat({
                path,
                tostring(tonumber(lfs.attributes(path,"modification") or 0) or 0),
                tostring(tonumber(U.file_size(path) or 0) or 0),
            },"|")
        end
    end
    table.sort(parts)
    return table.concat(parts,"+")
end

function Plugin:_home_schedule_cover_derivatives(books)
    if self._download_runtime~=nil then return false end
    if self:_home_ui_busy() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.covers=true
        return false
    end
    if not self.cover_render_async or not self.cover_render_async:available() then return false end
    local lightweight=self:_lightweight_enabled()
    local derivative_limit=lightweight and (tonumber(Config.LIGHTWEIGHT_DERIVATIVE_COVER_QUEUE) or 1) or math.huge
    local derivative_gap=lightweight and (tonumber(Config.LIGHTWEIGHT_DERIVATIVE_GAP) or 1.0) or .8

    local check_started=monotonic_wall_time()
    local sw,sh=Device.screen:getWidth(),Device.screen:getHeight()
    if sw<=0 or sh<=0 then return false end
    local thumb_w=math.max(240,math.min(420,math.floor(sw*.34+.5)))
    local thumb_h=math.max(340,math.floor(thumb_w/.69+.5))
    local render_dir=self.store.data_dir.."/cover-render-v1"
    local lock_dir=self.store.data_dir.."/lockscreen"
    local source_dir=self.store.data_dir.."/lockscreen-source"
    U.mkdir(render_dir); U.mkdir(lock_dir); U.mkdir(source_dir)

    local hero_id=tostring(self:_home_cover_render_id(self._home_hero) or "")
    local items,seen={},{}
    for _,book in ipairs(books or {}) do
        if type(book)=="table" then
            local id=self:_home_cover_render_id(book)
            if id and not seen[id] then
                local sources,source_seen={},{}
                local function add(path)
                    path=tostring(path or "")
                    if path~="" and not source_seen[path] and lfs.attributes(path,"mode")=="file" then
                        source_seen[path]=true
                        sources[#sources+1]=path
                    end
                end
                add(book.cover_path)
                local stored=(book.bookId or book.book_id) and self.store:book(tostring(book.bookId or book.book_id)) or nil
                local record=(book.bookId or book.book_id) and self:_preferred_record(tostring(book.bookId or book.book_id)) or nil
                if type(stored)=="table" then add(stored.cover_path) end
                if type(record)=="table" then add(record.cover_path) end
                local file=tostring(book.file or (record and record.file) or "")
                if #sources>0 or (file~="" and U.file_exists(file)) then
                    seen[id]=true
                    local inputs={}
                    for _,path in ipairs(sources) do inputs[#inputs+1]=path end
                    if file~="" and U.file_exists(file) and not source_seen[file] then inputs[#inputs+1]=file end
                    local home_target=render_dir.."/"..U.id_name(id).."-home1-"..tostring(thumb_w).."x"..tostring(thumb_h)..".png"
                    local lock_target=(hero_id~="" and id==hero_id)
                        and (lock_dir.."/"..U.id_name(id).."-fill3-"..tostring(sw).."x"..tostring(sh)..".png") or nil
                    items[#items+1]={
                        id=id,
                        sources=sources,
                        inputs=inputs,
                        input_stamp=self:_home_cover_input_stamp(inputs),
                        file=file,
                        source_dir=source_dir,
                        home_target=home_target,
                        home_w=thumb_w,home_h=thumb_h,
                        lock_target=lock_target,
                        lock_w=sw,lock_h=sh,
                        home_fresh=self:_home_cover_target_fresh(home_target,inputs),
                        lock_fresh=not lock_target or self:_home_cover_target_fresh(lock_target,inputs),
                    }
                    if #items>=10 then break end
                end
            end
        end
    end
    if #items==0 then return false end

    local worker_items={}
    local fresh_count=0
    local fast_changed=false
    local fast_hero_changed=false
    local fast_sections={}
    local fast_ids={}
    for _,item in ipairs(items) do
        if item.home_fresh then
            fresh_count=fresh_count+1
            local changed,is_hero,sections=self:_home_apply_rendered_cover_path(item.id,item.home_target)
            fast_changed=fast_changed or changed
            fast_hero_changed=fast_hero_changed or is_hero
            if changed then fast_ids[item.id]=true end
            for section in pairs(sections or {}) do fast_sections[section]=true end
        end
        if item.lock_target and item.lock_fresh then
            local current_hero_id=tostring(self:_home_cover_render_id(self._home_hero) or "")
            if current_hero_id~="" and item.id==current_hero_id then
                HOME_SESSION.screensaver_file=item.lock_target
                local current=HomeView.current()
                if current and current.opts then current.opts.screensaver_file=item.lock_target end
            end
        end
        if not (item.home_fresh and item.lock_fresh) and #worker_items<derivative_limit then
            worker_items[#worker_items+1]=item
        end
    end

    if fast_changed and HomeView.is_shown() and not self:_active_reader_ui() then
        for section in pairs(fast_sections) do self:_home_bump_section_revision(section) end
        local active=self._home_active_section or "account"
        if fast_hero_changed and self._home_hero then HomeView.update_hero(self._home_hero) end
        if fast_sections[active] then
            for id in pairs(fast_ids) do HomeView.update_book(id) end
        end
    end

    if #worker_items==0 then
        logger.info("[MiuRead][CoverRender] visible cache reused",
            "fresh=",tostring(fresh_count),
            "check_ms=",tostring(math.floor((monotonic_wall_time()-check_started)*1000+.5)))
        return false
    end

    local signature_parts={tostring(sw),tostring(sh),tostring(thumb_w),tostring(thumb_h),hero_id}
    for _,item in ipairs(worker_items) do
        signature_parts[#signature_parts+1]=table.concat({
            tostring(item.id),tostring(item.home_target),tostring(item.lock_target or ""),tostring(item.input_stamp or "")
        },"|")
    end
    local request_signature=table.concat(signature_parts,";")
    local now_clock=os.time()
    if self._home_cover_render_inflight_signature==request_signature then return false end
    if self._home_cover_render_last_signature==request_signature
        and now_clock-(tonumber(self._home_cover_render_last_clock) or 0)<5 then return false end
    if self._home_cover_render_failed_signature==request_signature
        and now_clock-(tonumber(self._home_cover_render_failed_clock) or 0)<600 then
        logger.info("[MiuRead][CoverRender] retry cooled down","seconds=600")
        return false
    end
    local competing=lightweight and (
        (self.home_metadata_async and self.home_metadata_async:busy())
        or (self.home_cover_async and self.home_cover_async:busy())
    )
    if self.cover_render_async:busy() or competing then
        if not self._home_cover_render_retry_task then
            local retry
            retry=function()
                if self._home_cover_render_retry_task~=retry then return end
                self._home_cover_render_retry_task=nil
                if HomeView.is_shown() and not self:_active_reader_ui() and not self:_home_ui_busy() then
                    self:_home_schedule_cover_derivatives(books)
                end
            end
            self._home_cover_render_retry_task=retry
            UIManager:scheduleIn(derivative_gap,retry)
        end
        return false
    end

    self._home_cover_render_inflight_signature=request_signature
    self._home_cover_render_generation=(tonumber(self._home_cover_render_generation) or 0)+1
    local generation=self._home_cover_render_generation
    local worker=function()
        local CoverRender=require("miuread.cover_render")
        local LocalMetadataChild=require("miuread.local_metadata")
        local UChild=require("miuread.util")
        CoverRender.lower_priority()
        local out={}
        for _,item in ipairs(worker_items) do
            local sources={}
            for _,path in ipairs(item.sources or {}) do sources[#sources+1]=path end
            if item.file~="" and UChild.file_exists(item.file) then
                local ok,metadata=pcall(LocalMetadataChild.read,item.file,item.source_dir,{open_document=false,use_bim=true})
                if ok and type(metadata)=="table" and tostring(metadata.cover_path or "")~="" then
                    sources[#sources+1]=metadata.cover_path
                end
            end
            local source=CoverRender.best_source(sources)
            if source then
                local home_path=item.home_target
                if not CoverRender.is_fresh(home_path,source) then
                    home_path=CoverRender.render_home(source,item.home_target,item.home_w,item.home_h)
                end
                local lock_path
                if item.lock_target then
                    lock_path=item.lock_target
                    if not CoverRender.is_fresh(lock_path,source) then
                        lock_path=CoverRender.render_fill(source,item.lock_target,item.lock_w,item.lock_h,{ink_boost=.075})
                    end
                end
                out[#out+1]={id=item.id,home_path=home_path,lock_path=lock_path,source=source}
            end
        end
        return out
    end

    logger.info("[MiuRead][CoverRender] worker scheduled",
        "pending=",tostring(#worker_items),"fresh=",tostring(fresh_count),
        "check_ms=",tostring(math.floor((monotonic_wall_time()-check_started)*1000+.5)))
    local render_started=monotonic_wall_time()
    local started=self.cover_render_async:run("home-cover-render",worker,function(result)
        if self._home_cover_render_inflight_signature==request_signature then
            self._home_cover_render_inflight_signature=nil
        end
        if generation~=self._home_cover_render_generation then return end
        if not result or result.ok~=true or type(result.value)~="table" then
            self._home_cover_render_failed_signature=request_signature
            self._home_cover_render_failed_clock=os.time()
            if result and result.error then logger.warn("[MiuRead][CoverRender] worker failed",U.first_line(result.error,120)) end
            return
        end
        self._home_cover_render_failed_signature=nil
        self._home_cover_render_failed_clock=0
        self._home_cover_render_last_signature=request_signature
        self._home_cover_render_last_clock=os.time()
        if self._download_runtime~=nil then
            -- Rendering may have started just before a download. Keep the files,
            -- but do not touch the visible shelf until the download finishes.
            logger.info("[MiuRead][CoverRender] visible apply deferred during download")
            return
        end
        local any_changed=false
        local hero_changed=false
        local changed_sections={}
        local changed_ids={}
        for _,entry in ipairs(result.value) do
            if entry.home_path and lfs.attributes(entry.home_path,"mode")=="file" then
                local changed,is_hero,sections=self:_home_apply_rendered_cover_path(entry.id,entry.home_path)
                any_changed=any_changed or changed
                hero_changed=hero_changed or is_hero
                if changed then changed_ids[entry.id]=true end
                for section in pairs(sections or {}) do changed_sections[section]=true end
            end
            if entry.lock_path and lfs.attributes(entry.lock_path,"mode")=="file" then
                local current_hero_id=tostring(self:_home_cover_render_id(self._home_hero) or "")
                if current_hero_id~="" and entry.id==current_hero_id then
                    HOME_SESSION.screensaver_file=entry.lock_path
                    local current=HomeView.current()
                    if current and current.opts then current.opts.screensaver_file=entry.lock_path end
                end
            end
        end
        if any_changed and HomeView.is_shown() and not self:_active_reader_ui() then
            for section in pairs(changed_sections) do self:_home_bump_section_revision(section) end
            local active=self._home_active_section or "account"
            if hero_changed and self._home_hero then HomeView.update_hero(self._home_hero) end
            if changed_sections[active] then
                for id in pairs(changed_ids) do HomeView.update_book(id) end
            end
        end
        logger.info("[MiuRead][CoverRender] visible cache ready",
            "rendered=",tostring(#result.value),"fresh=",tostring(fresh_count),
            "elapsed_ms=",tostring(math.floor((monotonic_wall_time()-render_started)*1000+.5)),
            "lightweight=",tostring(lightweight))
        if lightweight and HomeView.is_shown() and not self:_active_reader_ui() then
            UIManager:scheduleIn(derivative_gap,function()
                if HomeView.is_shown() and not self:_active_reader_ui() and not self:_home_ui_busy() then
                    self:_home_schedule_cover_derivatives(books)
                end
            end)
        end
    end,55)
    if started~=true and self._home_cover_render_inflight_signature==request_signature then
        self._home_cover_render_inflight_signature=nil
    end
    return started==true
end

function Plugin:_time_preferences()
    local preferences=self.store:preferences()
    preferences.time_display=TimeZone.normalize(preferences.time_display)
    return preferences.time_display,preferences
end

function Plugin:_display_time(format,timestamp)
    local value=self:_time_preferences()
    return TimeZone.date(value,format,timestamp)
end

function Plugin:_save_time_preferences(value,preferences,message)
    preferences=preferences or self.store:preferences()
    preferences.time_display=TimeZone.normalize(value)
    self.store:save_preferences(preferences)
    -- MiuRead now formats its own regional time; it no longer depends on
    -- changing Kindle's process timezone.
    TimeZone.apply(preferences.time_display)
    if HomeView.is_shown() then self:_refresh_home_view(message or "时间显示已更新","full")
    elseif message then self:toast(message,2) end
    return true
end

function Plugin:_set_time_mode(mode)
    local value,preferences=self:_time_preferences()
    value.mode=mode
    self:_save_time_preferences(value,preferences,"时间来源已更新")
end

function Plugin:time_mode_menu()
    return {
        {text="跟随设备",post_text="使用 Kindle / KOReader 当前时区",checked_func=function()
            return (self:_time_preferences()).mode=="device"
        end,callback=function() self:_set_time_mode("device") end},
        {text="地区时区",post_text="支持常用地区及夏令时",checked_func=function()
            return (self:_time_preferences()).mode=="zone"
        end,callback=function() self:_set_time_mode("zone") end},
        {text="固定 UTC 偏移",post_text="适合没有地区时区数据的旧设备",checked_func=function()
            return (self:_time_preferences()).mode=="fixed"
        end,callback=function() self:_set_time_mode("fixed") end},
    }
end

function Plugin:time_zone_menu()
    local rows={}
    for _,zone in ipairs(TimeZone.zones()) do
        local id,label=zone.id,zone.label
        rows[#rows+1]={text=label,post_text=TimeZone.zone_offset_text(id),checked_func=function()
            local value=self:_time_preferences()
            return value.mode=="zone" and value.zone==id
        end,callback=function()
            local value,preferences=self:_time_preferences()
            value.mode="zone"; value.zone=id
            self:_save_time_preferences(value,preferences,"时区已切换为"..label)
        end}
    end
    return rows
end

function Plugin:time_fixed_offset_dialog()
    local value,preferences=self:_time_preferences()
    local dialog
    dialog=InputDialog:new{
        title="固定 UTC 偏移",
        description="输入例如 +09:00、+08:00 或 -05:00",
        input=TimeZone.offset_text(value.offset_minutes),
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(dialog) end},
            {text="保存",is_enter_default=true,callback=function()
                local parsed=TimeZone.parse_offset(dialog:getInputText())
                if parsed==nil then self:toast("请输入 -14:00 到 +14:00 之间的有效偏移",3); return end
                UIManager:close(dialog)
                value.mode="fixed"; value.offset_minutes=parsed
                self:_save_time_preferences(value,preferences,"固定时区已更新")
            end},
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Plugin:time_display_settings_menu()
    local value=self:_time_preferences()
    return {
        {text="时间来源",post_text=TimeZone.label(value),sub_item_table_func=function() return self:time_mode_menu() end},
        {text="地区时区",post_text=TimeZone.zone(value.zone) and TimeZone.zone(value.zone).label or "中国 · 北京",sub_item_table_func=function() return self:time_zone_menu() end},
        {text="固定 UTC 偏移",post_text=TimeZone.offset_text(value.offset_minutes),callback=function() self:time_fixed_offset_dialog() end},
        {text="当前时间",post_text=self:_display_time("%Y-%m-%d %H:%M"),enabled=false},
        {text="说明",post_text="只调整觅阅显示 不修改 Kindle 系统时钟",enabled=false},
    }
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
