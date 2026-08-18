local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local UiScale = require("miuread.ui_scale")
local U = require("miuread.util")
local Lazy = require("miuread.lazy")
local LocalLibrary = Lazy("miuread.local_library")
local HomeLayouts = require("miuread.home_layout_constants")
local HOME_SECTION_ORDER = HomeLayouts.HOME_SECTION_ORDER
local HOME_ACTION_LAYOUT_VERSION = HomeLayouts.HOME_ACTION_LAYOUT_VERSION
local HOME_ACTION_ITEM_V1_ORDER = HomeLayouts.HOME_ACTION_ITEM_V1_ORDER
local HOME_ACTION_ITEM_V1_DEFAULT = HomeLayouts.HOME_ACTION_ITEM_V1_DEFAULT
local HOME_ACTION_ITEM_V2_ORDER = HomeLayouts.HOME_ACTION_ITEM_V2_ORDER
local HOME_ACTION_ITEM_V2_DEFAULT = HomeLayouts.HOME_ACTION_ITEM_V2_DEFAULT
local HOME_ACTION_ITEM_ORDER = HomeLayouts.HOME_ACTION_ITEM_ORDER
local HOME_ACTION_ITEM_DEFAULT = HomeLayouts.HOME_ACTION_ITEM_DEFAULT
local HOME_PANEL_LAYOUT_VERSION = HomeLayouts.HOME_PANEL_LAYOUT_VERSION
local HOME_PANEL_ITEM_V1_ORDER = HomeLayouts.HOME_PANEL_ITEM_V1_ORDER
local HOME_PANEL_ITEM_V1_DEFAULT = HomeLayouts.HOME_PANEL_ITEM_V1_DEFAULT
local HOME_PANEL_ITEM_V2_ORDER = HomeLayouts.HOME_PANEL_ITEM_V2_ORDER
local HOME_PANEL_ITEM_V2_DEFAULT = HomeLayouts.HOME_PANEL_ITEM_V2_DEFAULT
local HOME_PANEL_ITEM_ORDER = HomeLayouts.HOME_PANEL_ITEM_ORDER
local HOME_PANEL_ITEM_DEFAULT = HomeLayouts.HOME_PANEL_ITEM_DEFAULT
local quick_boolean_layout_matches = HomeLayouts.quick_boolean_layout_matches
local quick_order_matches = HomeLayouts.quick_order_matches
local quick_group = HomeLayouts.quick_group

local Plugin = {}

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


local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M

