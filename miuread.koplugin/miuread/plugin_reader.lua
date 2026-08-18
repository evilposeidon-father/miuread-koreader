-- MiuRead reader controller, split from main.lua.
-- Installs its Plugin methods onto the main Plugin class in the same way
-- plugin_maintenance.lua does. Reader navigation/lifecycle methods stay in
-- main.lua because they own the shared home-session transition state.
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Config = require("miuread.config")
local U = require("miuread.util")
local Text = require("miuread.text")
local HomeData = require("miuread.home_data")
local Lazy = require("miuread.lazy")
local HomeView = Lazy("miuread.home_view")
local HomeQuickPanel = require("miuread.home_quick_panel")
local ActionSheet = Lazy("miuread.action_sheet")
local LocalAnnotationDatabase = Lazy("miuread.local_annotation_database")
local Orientation = require("miuread.orientation_controller")
local GestureBridge = require("miuread.gesture_bridge")
local RawConfirmBox = require("ui/widget/confirmbox")
local RawInputDialog = require("ui/widget/inputdialog")
local ReaderToolbar = Lazy("miuread.reader_toolbar")
local ReaderListDialog = Lazy("miuread.reader_list_dialog")
local ReaderControlCenter = Lazy("miuread.reader_control_center")
local ReaderProgressDialog = Lazy("miuread.reader_progress_dialog")
local ReaderSettingsDialog = Lazy("miuread.reader_settings_dialog")
local ReaderTypographyDialog = Lazy("miuread.reader_typography_dialog")
local ReaderTocDialog = Lazy("miuread.reader_toc_dialog")
local ReaderFrontlightDialog = Lazy("miuread.reader_frontlight_dialog")
local ThoughtNativePopup = Lazy("miuread.thought_native_popup")
local AnnotationKinds = require("miuread.annotation_kinds")
local ReadTimeLedger = require("miuread.read_time_ledger")
local HighlightPolicy = require("miuread.highlight_policy")
local ExternalAnnotationParse = require("miuread.external_annotation_parse")
local ScreenshotMode = Lazy("miuread.screenshot_mode")

local _ = Text.tr

local READER_QUICK_ACTION_ORDER={"more","toc","progress","search","back","toggle_annotations","nearest_annotation","annotations","comments","edge_guard","font","spacing","page"}
local READER_QUICK_ACTION_DEFAULT={more=true,toc=true,progress=true,search=true,back=true,toggle_annotations=true,nearest_annotation=false,annotations=true,comments=true,edge_guard=false,font=false,spacing=false,page=false}
local READER_QUICK_ACTION_LABELS={more="更多",search="搜索",back="回到阅读",toggle_annotations="显隐划线",nearest_annotation="最近批注",annotations="批注",comments="想法",edge_guard="防误触",toc="目录",progress="进度",font="字体",spacing="行距",page="页面"}
local READER_QUICK_ACTION_MAX=8

-- Pure migration for quick-action preferences. Preserves the user's own
-- order/visibility and only leads with "更多" (clamped to the slot budget);
-- falls back to the current defaults only when the saved shape is invalid.
-- Returns true when the reader table was rewritten.
local function migrate_quick_actions(reader, order, default, max)
    order = order or READER_QUICK_ACTION_ORDER
    default = default or READER_QUICK_ACTION_DEFAULT
    max = max or READER_QUICK_ACTION_MAX
    if tonumber(reader.quick_actions_layout_version) == 3 then return false end
    local actions = type(reader.quick_actions) == "table" and reader.quick_actions or nil
    local list = type(reader.quick_action_order) == "table" and reader.quick_action_order or nil
    local known = {}
    for _, key in ipairs(order) do known[key] = true end
    local valid = actions ~= nil and list ~= nil
    if valid then
        for _, key in ipairs(list) do
            if known[key] ~= true or actions[key] ~= true then valid = false break end
        end
        for key, value in pairs(actions) do
            if known[key] ~= true or (value ~= true and value ~= false) then valid = false break end
        end
    end
    if not valid then
        reader.quick_actions = U.copy(default)
        reader.quick_action_order = {}
        for _, key in ipairs(order) do
            if default[key] == true then reader.quick_action_order[#reader.quick_action_order + 1] = key end
        end
    else
        actions.more = true
        local merged, seen = {"more"}, {more = true}
        for _, key in ipairs(list) do
            if key ~= "more" then
                if actions[key] == true then merged[#merged + 1] = key end
                seen[key] = true
            end
        end
        for _, key in ipairs(order) do
            if not seen[key] and actions[key] == true and #merged < max then
                merged[#merged + 1] = key
            end
        end
        -- Items beyond the slot budget become hidden, never lost.
        for index = #merged, max + 1, -1 do
            actions[merged[index]] = false
            merged[index] = nil
        end
        for _, key in ipairs(order) do
            if actions[key] == nil then actions[key] = default[key] == true end
        end
        reader.quick_actions = actions
        reader.quick_action_order = merged
    end
    reader.quick_actions_layout_version = 3
    return true
end

local ok_socket, socket = pcall(require, "socket")
local function monotonic_wall_time()
    if ok_socket and socket and type(socket.gettime) == "function" then return socket.gettime() end
    return os.time()
end

local Session = require("miuread.session_state")
local function home_session() return Session.home() end
local function reader_close_active() return Session.reader_close_active() end

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ConfirmBox = gesture_aware_class(RawConfirmBox, {_miuread_transient=true, _miuread_modal_surface=true})
local InputDialog = gesture_aware_class(RawInputDialog, {_miuread_transient=true, _miuread_modal_surface=true})

local Plugin = {}

function Plugin:_reader_preferences()
    local preferences=self.store:preferences()
    local reader=type(preferences.reader_ui)=="table" and preferences.reader_ui or {}
    local changed=false
    if reader.enabled==nil then reader.enabled=true; changed=true end
    if reader.plugin_mode_enabled~=false then reader.plugin_mode_enabled=false; changed=true end
    -- beta.11 keeps the reading surface completely clean while the panel is hidden.
    -- All reader controls live in the transient quick panel or the complete MiuRead menu.
    if reader.show_title~=false then reader.show_title=false; changed=true end
    if reader.show_status~=false then reader.show_status=false; changed=true end
    if reader.show_recent~=false then reader.show_recent=false; changed=true end
    if type(reader.recent_actions)~="table" or #reader.recent_actions>0 then reader.recent_actions={}; changed=true end
    if reader.edge_guard_enabled==nil then reader.edge_guard_enabled=true; changed=true end
    local edge_percent=tonumber(reader.edge_guard_percent)
    if edge_percent~=5 and edge_percent~=10 and edge_percent~=15 and edge_percent~=20 then
        reader.edge_guard_percent=10
        changed=true
    end

    if reader.selection_menu==nil then reader.selection_menu=false; changed=true end
    local fixed_order={"toc","progress","search","back","font","spacing","page","comments","bookmark","highlight","thought"}
    local fixed_items={toc=true,progress=true,search=true,back=true,font=true,spacing=true,page=true,comments=true,bookmark=true,highlight=true,thought=true}
    local order_ok=type(reader.quick_order)=="table" and #reader.quick_order==#fixed_order
    if order_ok then
        for index,key in ipairs(fixed_order) do
            if reader.quick_order[index]~=key then order_ok=false; break end
        end
    end
    local items_ok=type(reader.quick_items)=="table"
    if items_ok then
        local count=0
        for key,value in pairs(reader.quick_items) do
            if value==true then
                count=count+1
                if fixed_items[key]~=true then items_ok=false; break end
            end
        end
        if count~=#fixed_order then items_ok=false end
    end
    if tonumber(reader.quick_layout_version)~=12 or not order_ok or not items_ok then
        reader.quick_layout_version=12
        reader.quick_order=U.copy(fixed_order)
        reader.quick_items=U.copy(fixed_items)
        changed=true
    end

    -- P2 alignment: the quick action row leads with the WeRead five groups
    -- (更多/目录/进度 first, 字体/亮度 are dedicated rows below). The pure
    -- migration preserves user order/visibility and only inserts 更多 first.
    if migrate_quick_actions(reader) then changed = true end

    -- Reader quick-panel shortcut keys are stored as an ordered list of the
    -- currently visible keys. The full catalog and the default visible set are
    -- defined next to the home action bar defaults.
    local quick_actions_ok=type(reader.quick_actions)=="table"
        and type(reader.quick_action_order)=="table"
    if quick_actions_ok then
        local known={}
        for _,key in ipairs(READER_QUICK_ACTION_ORDER) do known[key]=true end
        local seen={}
        local count=0
        for _,key in ipairs(reader.quick_action_order) do
            if known[key]~=true or seen[key] then
                quick_actions_ok=false
                break
            end
            seen[key]=true
            count=count+1
            if reader.quick_actions[key]~=true then
                quick_actions_ok=false
                break
            end
        end
        if count<1 or count>READER_QUICK_ACTION_MAX then quick_actions_ok=false end
        if quick_actions_ok then
            for _,key in ipairs(READER_QUICK_ACTION_ORDER) do
                local value=reader.quick_actions[key]
                if value==nil then quick_actions_ok=false; break end
                if value~=true and value~=false then quick_actions_ok=false; break end
            end
        end
    end
    if not quick_actions_ok then
        reader.quick_actions=U.copy(READER_QUICK_ACTION_DEFAULT)
        reader.quick_action_order={}
        for _,key in ipairs(READER_QUICK_ACTION_ORDER) do
            if READER_QUICK_ACTION_DEFAULT[key]==true then
                reader.quick_action_order[#reader.quick_action_order+1]=key
            end
        end
        changed=true
    end

    preferences.reader_ui=reader
    if changed then self.store:save_preferences(preferences) end
    return reader,preferences
end

function Plugin:_reader_panel_active()
    local reader=self:_reader_preferences()
    return self:_home_enabled() and reader.enabled~=false
end

function Plugin:_save_reader_preferences(reader,preferences)
    preferences=preferences or self.store:preferences()
    preferences.reader_ui=reader
    self.store:save_preferences(preferences)
end

function Plugin:_reader_quick_actions(definitions, reader)
    reader=reader or self:_reader_preferences()
    local actions={}
    for _,key in ipairs(reader.quick_action_order or {}) do
        local definition=definitions and definitions[key] or nil
        if reader.quick_actions and reader.quick_actions[key]==true and definition then
            local action_key=key
            local entry={}
            for field,value in pairs(definition) do entry[field]=value end
            -- Long-press usually opens the shortcut manager. The silent sync
            -- shortcut is the one exception: long-press opens diagnostics.
            if action_key == "sync" then
                entry.hold_callback = function()
                    self:_sync_shortcut_diagnostics()
                end
            else
                entry.hold_callback=function(anchor)
                    self:_show_reader_quick_action_manage_popup(action_key,anchor)
                end
            end
            actions[#actions+1]=entry
            if #actions>=READER_QUICK_ACTION_MAX then break end
        end
    end
    return actions
end

function Plugin:_refresh_reader_quick_panel()
    UIManager:scheduleIn(.05,function() self:show_reader_quick_panel() end)
end

function Plugin:_reader_quick_action_move(key,direction)
    local reader,preferences=self:_reader_preferences()
    local order=reader.quick_action_order or {}
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local target=index+(direction<0 and -1 or 1)
    if target<1 or target>#order then return false end
    order[index],order[target]=order[target],order[index]
    self:_save_reader_preferences(reader,preferences)
    self:_refresh_reader_quick_panel()
    return true
end

function Plugin:_show_reader_quick_action_replace_popup(key)
    local reader=self:_reader_preferences()
    local candidates={}
    for _,candidate in ipairs(READER_QUICK_ACTION_ORDER) do
        if candidate~=key and reader.quick_actions[candidate]~=true then
            local replacement=candidate
            candidates[#candidates+1]={
                icon="↔",
                label=READER_QUICK_ACTION_LABELS[replacement] or replacement,
                detail="替换当前快捷按键",
                callback=function()
                    local current,preferences=self:_reader_preferences()
                    current.quick_actions[key]=false
                    current.quick_actions[replacement]=true
                    for i,name in ipairs(current.quick_action_order) do
                        if name==key then
                            current.quick_action_order[i]=replacement
                            break
                        end
                    end
                    self:_save_reader_preferences(current,preferences)
                    self:_refresh_reader_quick_panel()
                end,
            }
        end
    end
    if #candidates==0 then
        self:info("没有可替换的隐藏功能")
        return false
    end
    return ActionSheet.show{
        cache_key="reader_quick_action_replace_"..tostring(key),
        preferred_direction="below",width_ratio=.70,
        title="替换快捷按键",subtitle="当前："..tostring(READER_QUICK_ACTION_LABELS[key] or key),
        actions=candidates,
    }
end

function Plugin:_show_reader_quick_action_restore_popup(key)
    local reader=self:_reader_preferences()
    local visible_count=self:_reader_quick_action_visible_count(reader)
    local candidates={}
    for _,candidate in ipairs(READER_QUICK_ACTION_ORDER) do
        if reader.quick_actions[candidate]~=true then
            local restore_key=candidate
            candidates[#candidates+1]={
                icon="↺",
                label=READER_QUICK_ACTION_LABELS[restore_key] or restore_key,
                detail=visible_count<READER_QUICK_ACTION_MAX and "添加到菜单栏末尾" or "菜单栏已满，点击替换当前按键",
                callback=function()
                    local current,preferences=self:_reader_preferences()
                    local count=self:_reader_quick_action_visible_count(current)
                    if count<READER_QUICK_ACTION_MAX then
                        current.quick_actions[restore_key]=true
                        current.quick_action_order[#current.quick_action_order+1]=restore_key
                    else
                        current.quick_actions[key]=false
                        current.quick_actions[restore_key]=true
                        for i,name in ipairs(current.quick_action_order) do
                            if name==key then
                                current.quick_action_order[i]=restore_key
                                break
                            end
                        end
                    end
                    self:_save_reader_preferences(current,preferences)
                    self:_refresh_reader_quick_panel()
                end,
            }
        end
    end
    if #candidates==0 then
        self:info("没有隐藏的功能")
        return false
    end
    return ActionSheet.show{
        cache_key="reader_quick_action_restore_"..tostring(key),
        preferred_direction="below",width_ratio=.70,
        title="恢复隐藏功能",subtitle="选择要恢复的功能",
        actions=candidates,
    }
end

function Plugin:_show_reader_quick_action_manage_popup(key,anchor)
    local reader=self:_reader_preferences()
    local order=reader.quick_action_order or {}
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local can_left=index>1
    local can_right=index<#order

    local definitions=self:_reader_quick_definitions()
    local definition=definitions and definitions[key] or nil
    local hidden_count=0
    for _,candidate in ipairs(READER_QUICK_ACTION_ORDER) do
        if reader.quick_actions[candidate]~=true then hidden_count=hidden_count+1 end
    end
    local actions={
        {
            icon="undo",
            label="恢复隐藏功能",
            detail=hidden_count>0 and ("当前有 "..tostring(hidden_count).." 个隐藏功能") or "所有功能都已显示",
            enabled=hidden_count>0,
            callback=function() self:_show_reader_quick_action_restore_popup(key) end,
        },
    }
    if definition and type(definition.hold_callback)=="function" then
        actions[#actions+1]={
            icon=definition.icon or definition.icon_key or "•",
            label="原长按功能",
            detail="执行该按键原有的长按动作",
            callback=function() definition.hold_callback() end,
        }
    end

    local manage={
        {label="← 左移",enabled=can_left,callback=function() self:_reader_quick_action_move(key,-1) end},
        {label="右移 →",enabled=can_right,callback=function() self:_reader_quick_action_move(key,1) end},
        {label="隐藏",callback=function()
            local ok,err=self:_toggle_reader_quick_action(key)
            if not ok and err then self:toast(err,3) end
            if ok then
                self:toast("已隐藏「"..tostring(READER_QUICK_ACTION_LABELS[key] or key).."」，长按其他快捷按键可恢复",3)
                self:_refresh_reader_quick_panel()
            end
        end},
        {label="替换",callback=function() self:_show_reader_quick_action_replace_popup(key) end},
    }
    return ActionSheet.show{
        cache_key="reader_quick_action_manage_"..tostring(key),
        anchor=anchor,preferred_direction="below",width_ratio=.80,
        title=tostring(READER_QUICK_ACTION_LABELS[key] or key),
        subtitle="点击使用主功能 · 长按扩展与管理",
        actions=actions,wide_last=(#actions%2==1),footer_actions=manage,
    }
end

function Plugin:_reader_quick_action_visible_count(reader)
    reader=reader or self:_reader_preferences()
    local count=0
    for _,key in ipairs(reader.quick_action_order or {}) do
        if reader.quick_actions and reader.quick_actions[key]==true then count=count+1 end
    end
    return count
end

function Plugin:_toggle_reader_quick_action(key)
    if READER_QUICK_ACTION_DEFAULT[key]==nil then return false,"未知快捷按键" end
    local reader,preferences=self:_reader_preferences()
    local enabled=reader.quick_actions[key]==true
    if enabled then
        local count=self:_reader_quick_action_visible_count(reader)
        if count<=1 then return false,"至少保留 1 个快捷按键" end
        reader.quick_actions[key]=false
        for i=#reader.quick_action_order,1,-1 do
            if reader.quick_action_order[i]==key then
                table.remove(reader.quick_action_order,i)
                break
            end
        end
    else
        local count=self:_reader_quick_action_visible_count(reader)
        if count>=READER_QUICK_ACTION_MAX then
            return false,"最多显示 "..tostring(READER_QUICK_ACTION_MAX).." 个快捷按键，请先关闭一个"
        end
        reader.quick_actions[key]=true
        reader.quick_action_order[#reader.quick_action_order+1]=key
    end
    self:_save_reader_preferences(reader,preferences)
    return true,nil
end

function Plugin:reader_quick_actions_menu()
    local rows={}
    for _,key in ipairs(READER_QUICK_ACTION_ORDER) do
        local action_key=key
        rows[#rows+1]={
            text=READER_QUICK_ACTION_LABELS[action_key] or action_key,
            checked_func=function() return self:_reader_preferences().quick_actions[action_key]==true end,
            keep_menu_open=true,
            callback=function()
                local ok,err=self:_toggle_reader_quick_action(action_key)
                if not ok and err then self:toast(err,3) end
            end,
        }
    end
    rows[#rows+1]={text="恢复默认快捷按键",callback=function()
        local reader,preferences=self:_reader_preferences()
        reader.quick_actions=U.copy(READER_QUICK_ACTION_DEFAULT)
        reader.quick_action_order={}
        for _,key in ipairs(READER_QUICK_ACTION_ORDER) do
            if READER_QUICK_ACTION_DEFAULT[key]==true then
                reader.quick_action_order[#reader.quick_action_order+1]=key
            end
        end
        self:_save_reader_preferences(reader,preferences)
        self:toast("阅读快捷按键已恢复默认")
    end}
    rows[#rows+1]={text="使用提示：在阅读菜单栏长按任意快捷按键，可排序、隐藏、替换或恢复",enabled=false}
    return rows
end

function Plugin:_reader_edge_guard_state()
    local reader=self:_reader_preferences()
    local percent=tonumber(reader.edge_guard_percent) or 10
    if percent~=5 and percent~=10 and percent~=15 and percent~=20 then percent=10 end
    return reader.edge_guard_enabled~=false,percent
end

function Plugin:_reader_toggle_edge_guard()
    local reader,preferences=self:_reader_preferences()
    reader.edge_guard_enabled=reader.edge_guard_enabled==false
    self:_save_reader_preferences(reader,preferences)
    return reader.edge_guard_enabled~=false
end

function Plugin:_reader_set_edge_guard_percent(percent)
    percent=tonumber(percent)
    if percent~=5 and percent~=10 and percent~=15 and percent~=20 then return false end
    local reader,preferences=self:_reader_preferences()
    reader.edge_guard_percent=percent
    self:_save_reader_preferences(reader,preferences)
    return true
end

function Plugin:reader_quick_panel_settings_menu()
    return {
        {text="启用觅阅阅读控制中心",checked_func=function() return self:_reader_preferences().enabled~=false end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.enabled=reader.enabled==false; self:_save_reader_preferences(reader,preferences)
        end},
        {text="快捷按键",post_text=string.format("已显示 %d/%d",self:_reader_quick_action_visible_count(),READER_QUICK_ACTION_MAX),sub_item_table_func=function() return self:reader_quick_actions_menu() end},
        {text="想法",post_text=self:_thoughts_enabled_label(),checked_func=function() return self:_thoughts_enabled() end,keep_menu_open=true,callback=function() self:_toggle_thoughts_enabled() end},
        {text="想法显示设置",post_text=self:_thought_font_size_label(),sub_item_table_func=function() return self:thought_font_settings_menu() end},
        {text="默认划线样式",post_text=function()
            local ok, saved = pcall(G_reader_settings.readSetting, G_reader_settings, "highlight_drawer")
            return HighlightPolicy.style_label(ok and saved or "underscore")
        end,sub_item_table_func=function()
            local rows={}
            for _, style in ipairs(HighlightPolicy.STYLES) do
                local target=style
                rows[#rows+1]={text=HighlightPolicy.style_label(target),radio=true,checked_func=function()
                    local ok,saved=pcall(G_reader_settings.readSetting,G_reader_settings,"highlight_drawer")
                    return tostring(ok and saved or "underscore")==target
                end,callback=function()
                    if not HighlightPolicy.is_style(target) then return end
                    -- Global seed for new books + per-book doc_settings as the
                    -- single live writer; redraw existing highlights so the
                    -- style change applies mid-reading (architect/backend review).
                    pcall(G_reader_settings.saveSetting,G_reader_settings,"highlight_drawer",target)
                    local ui=self.ui
                    if ui and ui.doc_settings and type(ui.doc_settings.saveSetting)=="function" then
                        pcall(ui.doc_settings.saveSetting,ui.doc_settings,"highlight_drawer",target)
                    end
                    if ui and ui.view and ui.view.highlight then
                        ui.view.highlight.saved_drawer=target
                        if type(ui.view.highlight.updateHighlightDrawer)=="function" then
                            pcall(ui.view.highlight.updateHighlightDrawer,ui.view.highlight,target)
                        end
                    end
                    -- Repaint the reading surface so the new style is visible on
                    -- e-ink, but debounced and partial: cycling styles inside the
                    -- open menu must not full-screen flash on every selection
                    -- (fluency review). updateHighlightDrawer already applied the
                    -- new drawer state; one "ui" repaint lands after the clicks
                    -- settle, and the menu close repaints its covered area anyway.
                    if self._style_repaint_task then
                        UIManager:unschedule(self._style_repaint_task)
                        self._style_repaint_task = nil
                    end
                    self._style_repaint_task = UIManager:scheduleIn(.25, function()
                        self._style_repaint_task = nil
                        if self.ui and self.ui.view then
                            UIManager:setDirty(self.ui, "ui")
                        end
                    end)
                end}
            end
            return rows
        end},
        {text="选词后显示选择菜单",post_text="复制 / 查词 / 划线",checked_func=function() return self:_reader_preferences().selection_menu==true end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.selection_menu=not reader.selection_menu; self:_save_reader_preferences(reader,preferences)
            -- Apply immediately so a toggle takes effect mid-reading, not only
            -- on the next book open (backend review).
            local highlight=self.ui and self.ui.highlight or nil
            if highlight then highlight._miuread_force_direct_highlight=nil end
            if self.ui and self.ui.document then
                if reader.selection_menu then
                    self:_restore_miuread_highlight_action_policy()
                else
                    pcall(function() self:_apply_miuread_highlight_defaults(self:_current_book_record()) end)
                end
            end
            self:toast(reader.selection_menu and "已开启：选词显示复制/查词/划线菜单" or "已关闭：选词直接划线",2)
        end},
    }
end

-- Reader quick panel / control methods. Reader navigation and lifecycle
-- methods stay in main.lua.

function Plugin:_schedule_reader_interaction_resume(target)
    self._reader_interaction_resume_generation=(tonumber(self._reader_interaction_resume_generation) or 0)+1
    local generation=self._reader_interaction_resume_generation
    if self._reader_interaction_resume_task then
        UIManager:unschedule(self._reader_interaction_resume_task)
        self._reader_interaction_resume_task=nil
    end
    local task
    task=function()
        if self._reader_interaction_resume_task~=task
            or generation~=self._reader_interaction_resume_generation then return end
        if self._miuread_suspended==true or home_session().suspended==true then
            self._reader_interaction_resume_task=nil
            return
        end
        local now=os.time()
        local deadline=math.max(tonumber(target) or 0,tonumber(self._reader_busy_until or 0) or 0)
        if deadline>now then
            UIManager:scheduleIn(math.max(.25,deadline-now+.15),task)
            return
        end
        self._reader_interaction_resume_task=nil
        if self.download_task then self.download_task:resume("reader_interaction") end
    end
    self._reader_interaction_resume_task=task
    UIManager:scheduleIn(math.max(.25,(tonumber(target) or os.time())-os.time()+.15),task)
end

function Plugin:_mark_reader_busy(seconds,share_report)
    local path=tostring(self._reader_busy_path or "")
    if path=="" then return false end
    self._reader_last_interaction_clock=os.clock()
    local now=os.time()
    local target=math.max(now+math.max(1,tonumber(seconds) or 4),tonumber(self._reader_busy_until or 0) or 0)
    self._reader_busy_until=target
    local active_download=(self.download_task and self.download_task:busy()) or self._download_runtime~=nil
    local wrote=true
    -- Keep page turns memory-only in the normal case. The shared /tmp marker is
    -- written only when a visible panel gesture specifically asks the report
    -- subprocess to yield, or while a download is already competing for I/O.
    if active_download or share_report==true then wrote=U.atomic_write(path,tostring(target),true)==true end
    -- Reading interaction always wins over background generation. This used to
    -- happen only in optional lightweight mode, which is why active downloads
    -- could still make the first page turn or pull-down panel feel sticky.
    if active_download and self.download_task then
        self.download_task:pause("reader_interaction")
        self:_schedule_reader_interaction_resume(target)
    end
    return wrote
end

function Plugin:_reader_background_idle()
    if os.time()<(tonumber(self._reader_busy_until) or 0) then return false end
    local quiet=self:_lightweight_enabled()
        and (tonumber(Config.LIGHTWEIGHT_READER_IDLE_SECONDS) or 1.5) or .80
    return os.clock()-(tonumber(self._reader_last_interaction_clock) or 0)>=quiet
end

function Plugin:_reader_toolbar_cache()
    local session=tonumber(home_session().reader_session_generation or 0) or 0
    local cache=self._reader_toolbar_state_cache
    if type(cache)~="table" or tonumber(cache.session or -1)~=session then
        cache={session=session,page=nil,total=nil,chapter="",updated_at=0}
        self._reader_toolbar_state_cache=cache
    end
    return cache
end

function Plugin:_reset_reader_toolbar_state_cache()
    if self._reader_toolbar_state_task then
        UIManager:unschedule(self._reader_toolbar_state_task)
        self._reader_toolbar_state_task=nil
    end
    self._reader_toolbar_state_cache={
        session=tonumber(home_session().reader_session_generation or 0) or 0,
        page=nil,total=nil,chapter="",updated_at=0,
    }
end

function Plugin:_refresh_reader_toolbar_state_cache(page)
    if not (self.ui and self.ui.document) then return false end
    local started=os.clock()
    local cache=self:_reader_toolbar_cache()
    local current=tonumber(page)
    if not current then current=self:_reader_current_page() end
    if current then cache.page=current end

    if not tonumber(cache.total) or tonumber(cache.total)<=0 then
        local document=self.ui.document
        local total
        if type(document.getPageCount)=="function" then
            local ok,value=pcall(document.getPageCount,document)
            if ok then total=tonumber(value) end
        end
        total=total or (document.info and tonumber(document.info.number_of_pages)) or nil
        if total and total>0 then cache.total=total end
    end

    local chapter_started=os.clock()
    if current then
        local toc=self.ui and self.ui.toc or nil
        local chapter=""
        if toc and type(toc.getTocTitleByPage)=="function" then
            local ok,value=pcall(toc.getTocTitleByPage,toc,current)
            if ok and value then chapter=U.trim(tostring(value)) end
        end
        if chapter~="" then cache.chapter=chapter elseif tostring(cache.chapter or "")=="" then cache.chapter="当前章节" end
    end
    cache.updated_at=os.time()
    local chapter_ms=math.floor((os.clock()-chapter_started)*1000+.5)
    local total_ms=math.floor((os.clock()-started)*1000+.5)
    if total_ms>=20 or chapter_ms>=15 then
        logger.info("[MiuRead][ReaderToolbarState] refreshed",
            "page=",tostring(cache.page or ""),"chapter_ms=",tostring(chapter_ms),"total_ms=",tostring(total_ms))
    end
    return true
end

function Plugin:_schedule_reader_toolbar_state_refresh(page,delay)
    if self._reader_toolbar_state_task then UIManager:unschedule(self._reader_toolbar_state_task) end
    local session=tonumber(home_session().reader_session_generation or 0) or 0
    local requested=tonumber(page)
    local task
    task=function()
        if self._reader_toolbar_state_task~=task then return end
        if self._miuread_suspended==true or home_session().suspended==true then
            self._reader_toolbar_state_task=nil
            return
        end
        if not self:_reader_background_idle() then
            UIManager:scheduleIn(.35,task)
            return
        end
        self._reader_toolbar_state_task=nil
        if self.ui and self.ui.document and not reader_close_active()
            and tonumber(home_session().reader_session_generation or 0)==session then
            self:_refresh_reader_toolbar_state_cache(requested)
        end
    end
    self._reader_toolbar_state_task=task
    UIManager:scheduleIn(tonumber(delay) or .05,task)
    return true
end

function Plugin:_reader_toolbar_cached_percent()
    local cache=self:_reader_toolbar_cache()
    local page,total=tonumber(cache.page),tonumber(cache.total)
    if page and total and total>0 then return math.max(0,math.min(100,page/total*100)) end
    return nil
end

function Plugin:_reader_progress_percent()
    local ui=self.ui
    local document=ui and ui.document
    if not ui or not document then return nil end
    local current,total
    if type(ui.getCurrentPage)=="function" and type(document.getPageCount)=="function" then
        local ok_current,value_current=pcall(ui.getCurrentPage,ui)
        local ok_total,value_total=pcall(document.getPageCount,document)
        if ok_current and ok_total then current,total=tonumber(value_current),tonumber(value_total) end
    end
    if current and total and total>0 then
        return math.max(0,math.min(100,current/total*100))
    end
    local rolling=ui.rolling
    local pos=rolling and tonumber(rolling.current_page or rolling.current_pos)
    local pages=rolling and tonumber(rolling.page_count or rolling.full_height)
    if pos and pages and pages>0 then return math.max(0,math.min(100,pos/pages*100)) end
    return nil
end

function Plugin:_reader_jump_percent(delta)
    local current=self:_reader_progress_percent()
    if not current then self:info("当前文档暂时无法按百分比调整进度"); return false end
    local target=math.max(0,math.min(100,current+(tonumber(delta) or 0)))
    self:_mark_reader_busy(4)
    self.ui:handleEvent(Event:new("GotoPercent",target))
    return true
end

function Plugin:_reader_adjust_font_size(delta)
    local ui=self.ui
    local font=ui and ui.font
    local configurable=ui and ui.document and ui.document.configurable or nil
    local current=font and tonumber(font.font_size)
        or (ui and ui.rolling and tonumber(ui.rolling.font_size))
        or (configurable and tonumber(configurable.font_size))
    if not current then
        self:info("当前文档暂时无法直接调整字号")
        return false
    end
    local target=math.max(12,math.min(72,current+(tonumber(delta) or 0)))
    self:_mark_reader_busy(5)
    if font and type(font.onSetFontSize)=="function" then
        local ok=pcall(font.onSetFontSize,font,target)
        if ok then return true end
    end
    if ui and type(ui.handleEvent)=="function" then
        ui:handleEvent(Event:new("SetFontSize",target))
        return true
    end
    return false
end

function Plugin:_reader_goto_percent(target)
    target=math.max(0,math.min(100,tonumber(target) or 0))
    if not (self.ui and type(self.ui.handleEvent)=="function") then return false end
    self:_mark_reader_busy(5)
    self.ui:handleEvent(Event:new("GotoPercent",target))
    return true
end

function Plugin:_reader_previous_chapter()
    local ui=self.ui
    if not (ui and ui.document and type(ui.handleEvent)=="function") then return false end
    self:_mark_reader_busy(5)
    ui:handleEvent(Event:new("GotoPrevChapter"))
    return true
end

function Plugin:_reader_next_chapter()
    local ui=self.ui
    if not (ui and ui.document and type(ui.handleEvent)=="function") then return false end
    self:_mark_reader_busy(5)
    ui:handleEvent(Event:new("GotoNextChapter"))
    return true
end

function Plugin:_show_reader_progress_control(back_callback)
    if not (self.ui and self.ui.document) then return false end
    self:_mark_reader_busy(8)
    ReaderProgressDialog.show{
        percent=self:_reader_progress_percent() or 0,
        on_goto_percent=function(target) self:_reader_goto_percent(target) end,
        on_adjust=function(delta) self:_reader_jump_percent(delta) end,
        on_jump=function() self:_show_reader_position_jump() end,
        on_prev_chapter=function() self:_reader_previous_chapter() end,
        on_next_chapter=function() self:_reader_next_chapter() end,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
    }
    return true
end

function Plugin:_show_reader_position_jump(back_callback)
    local ui=self.ui
    local gotopage=ui and ui.gotopage
    if gotopage and type(gotopage.onShowGotoDialog)=="function" then
        self:_mark_reader_busy(5)
        return self:_reader_open_native_page("页面跳转",function()
            gotopage:onShowGotoDialog()
            return true
        end,back_callback or function() self:show_reader_quick_panel() end)
    end
    self:info("当前文档暂时无法跳转位置")
    return false
end
function Plugin:_reader_current_page()
    local ui=self.ui
    if ui and type(ui.getCurrentPage)=="function" then
        local ok,value=pcall(ui.getCurrentPage,ui)
        if ok and tonumber(value) then return tonumber(value) end
    end
    local rolling=ui and ui.rolling or nil
    return tonumber(rolling and (rolling.current_page or rolling.current_pos))
end

function Plugin:_reader_toc_items()
    local ui=self.ui
    local toc=ui and ui.toc or nil
    if not toc then return {},nil end
    if type(toc.fillToc)=="function" then pcall(toc.fillToc,toc) end
    local source=type(toc.toc)=="table" and toc.toc or {}
    local current_index
    local current_page=self:_reader_current_page()
    if current_page and type(toc.getTocIndexByPage)=="function" then
        local ok,value=pcall(toc.getTocIndexByPage,toc,current_page)
        if ok then current_index=tonumber(value) end
    end
    -- Some document backends do not expose getTocIndexByPage reliably.
    -- Fall back to the nearest preceding ToC entry so opening the directory
    -- still follows the actual reading position.
    if current_page and not current_index then
        local nearest_page=-math.huge
        for index,entry in ipairs(source) do
            local page=tonumber(entry.page or entry.pageno)
            if page and page<=current_page and page>=nearest_page then
                current_index=index
                nearest_page=page
            end
        end
    end
    local items={}
    for index,entry in ipairs(source) do
        local item=entry
        local title=U.trim(tostring(item.title or item.text or item.name or ""))
        if title=="" then title="未命名章节" end
        local page=tonumber(item.page or item.pageno)
        local xpointer=item.xpointer or item.xp
        local destination_page=page
        local destination_xpointer=xpointer
        items[#items+1]={
            title=title,
            depth=tonumber(item.depth or item.level) or 1,
            page=page,
            page_label=item.page_label or (page and tostring(page) or ""),
            current=current_index==index,
            callback=function()
                local current_ui=self.ui
                if not (current_ui and current_ui.document) then return false end
                local link=current_ui.link
                if link and type(link.addCurrentLocationToStack)=="function" then
                    pcall(link.addCurrentLocationToStack,link)
                end
                self:_mark_reader_busy(5)
                if destination_xpointer then
                    current_ui:handleEvent(Event:new("GotoXPointer",destination_xpointer,destination_xpointer))
                    return true
                end
                if destination_page then
                    current_ui:handleEvent(Event:new("GotoPage",destination_page))
                    return true
                end
                return false
            end,
        }
    end
    return items,current_index
end

function Plugin:_show_reader_toc(back_callback)
    local items=self:_reader_toc_items()
    if #items>0 then
        self:_mark_reader_busy(6)
        local dialog,err=ReaderTocDialog.show{
            title="目录",
            items=items,
            auto_follow=true,
            on_back=back_callback or function() self:show_reader_quick_panel() end,
            on_home=function() return self:return_to_miuread_home("reader surface") end,
        }
        if dialog then return true end
        logger.warn("[MiuRead][ReaderToc] custom dialog unavailable",tostring(err or "unknown"))
    end
    -- A native full-screen ToC is an acceptable compatibility fallback; it is
    -- intentionally different from the native bottom configuration strip.
    local toc=self.ui and self.ui.toc
    if toc and type(toc.onShowToc)=="function" then
        self:_mark_reader_busy(5)
        return self:_reader_open_native_page("目录",function()
            toc:onShowToc()
            return true
        end,back_callback or function() self:show_reader_quick_panel() end)
    end
    self:info("当前书籍没有可用目录")
    return false
end

function Plugin:_reader_line_spacing_value()
    local ui=self.ui
    local font=ui and ui.font or nil
    local configurable=ui and ui.document and ui.document.configurable or nil
    return tonumber((font and font.configurable and font.configurable.line_spacing)
        or (configurable and configurable.line_spacing)
        or (font and font.line_space_percent)) or 100
end

function Plugin:_reader_set_line_spacing(value)
    local font=self.ui and self.ui.font or nil
    local target=math.max(50,math.min(200,math.floor((tonumber(value) or 100)+.5)))
    if font and type(font.onSetLineSpace)=="function" then
        self:_mark_reader_busy(5)
        local ok=pcall(font.onSetLineSpace,font,target)
        if ok then return true end
    end
    self:info("当前文档暂时无法直接调整行距")
    return false
end

function Plugin:_reader_adjust_line_spacing(delta)
    return self:_reader_set_line_spacing(self:_reader_line_spacing_value()+(tonumber(delta) or 0))
end

function Plugin:_reader_font_weight_value()
    local ui=self.ui
    local font=ui and ui.font or nil
    local configurable=ui and ui.document and ui.document.configurable or nil
    return tonumber((font and font.configurable and font.configurable.font_base_weight)
        or (configurable and configurable.font_base_weight)) or 0
end

function Plugin:_reader_font_weight_label()
    local value=self:_reader_font_weight_value()
    if value<=-.5 then return "较细" end
    if value>=1.5 then return "很粗" end
    if value>=.5 then return "较粗" end
    return "默认"
end

function Plugin:_reader_set_font_weight(value)
    local font=self.ui and self.ui.font or nil
    local target=math.max(-1,math.min(3,tonumber(value) or 0))
    target=math.floor(target*4+.5)/4
    if font and type(font.onSetFontBaseWeight)=="function" then
        self:_mark_reader_busy(5)
        local ok=pcall(font.onSetFontBaseWeight,font,target)
        if ok then return true end
    end
    self:info("当前文档暂时无法直接调整字体粗细")
    return false
end

function Plugin:_reader_adjust_font_weight(delta)
    return self:_reader_set_font_weight(self:_reader_font_weight_value()+(tonumber(delta) or 0))
end

function Plugin:_show_reader_font_face_menu(back_callback)
    local font=self.ui and self.ui.font or nil
    if not font then self:info("当前文档暂时无法选择字体"); return false end
    if type(font.setupFaceMenuTable)=="function" then pcall(font.setupFaceMenuTable,font) end
    local items=font.face_table
    if type(items)=="table" and #items>0 then
        return self:_show_reader_menu_table("正文字体",items,back_callback)
    end
    self:info("当前 KOReader 版本没有提供可供觅阅读取的字体列表")
    return false
end
function Plugin:_show_reader_spacing_panel(back_callback)
    ReaderSettingsDialog.show{
        title="行距",
        subtitle=function() return "当前行距："..tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%" end,
        hero=function()
            return {
                value=tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%",
                on_decrease=function() self:_reader_adjust_line_spacing(-5) end,
                on_increase=function() self:_reader_adjust_line_spacing(5) end,
            }
        end,
        on_back=back_callback,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local current=math.floor(self:_reader_line_spacing_value()+.5)
            return {
                {title="常用预设",rows={
                    {label="紧凑",value="100%",checked=current==100,keep_open=true,callback=function() self:_reader_set_line_spacing(100) end},
                    {label="标准",value="120%",checked=current==120,keep_open=true,callback=function() self:_reader_set_line_spacing(120) end},
                    {label="舒展",value="140%",checked=current==140,keep_open=true,callback=function() self:_reader_set_line_spacing(140) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_weight_panel(back_callback)
    ReaderSettingsDialog.show{
        title="字体粗细",
        subtitle=function() return "当前粗细："..self:_reader_font_weight_label() end,
        hero=function()
            return {
                value=self:_reader_font_weight_label(),
                on_decrease=function() self:_reader_adjust_font_weight(-.25) end,
                on_increase=function() self:_reader_adjust_font_weight(.25) end,
            }
        end,
        on_back=back_callback,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local current=self:_reader_font_weight_value()
            return {
                {title="常用预设",rows={
                    {label="较细",value="-0.5",checked=math.abs(current+.5)<.01,keep_open=true,callback=function() self:_reader_set_font_weight(-.5) end},
                    {label="默认",value="0",checked=math.abs(current)<.01,keep_open=true,callback=function() self:_reader_set_font_weight(0) end},
                    {label="较粗",value="0.5",checked=math.abs(current-.5)<.01,keep_open=true,callback=function() self:_reader_set_font_weight(.5) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_thoughts_enabled()
    return (self.store:preferences().thoughts or {}).enabled~=false
end

function Plugin:_set_thoughts_enabled(enabled)
    enabled=enabled~=false
    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
    if (p.thoughts.enabled~=false)==enabled then return true end
    p.thoughts.enabled=enabled
    self:_save_ui_preferences(p,"thoughts_enabled")
    local current=self.sync and self.sync.current or nil
    local record=current and current.record or {}
    local variant=tostring(current and (current.variant or record.variant) or "")
    local annotation_book=current and (record.annotation_requested==true or variant:find("notes",1,true))
    if enabled then
        if annotation_book then self:_setup_thought_tap() end
        self:toast("想法已开启",1.5)
    else
        self:_close_active_thought_popup("comments disabled")
        -- Keep the MiuRead internal-link guard installed. Hiding comments must
        -- not hand #miuthought links back to KOReader as invalid external links.
        if annotation_book then self:_setup_thought_tap() end
        self:toast("想法已关闭，划线和想法数据不会删除",2)
    end
    return true
end

function Plugin:_toggle_thoughts_enabled()
    return self:_set_thoughts_enabled(not self:_thoughts_enabled())
end

function Plugin:_thoughts_enabled_label()
    return self:_thoughts_enabled() and "已开启" or "已关闭"
end

function Plugin:_thought_font_size_value(prefs)
    prefs=prefs or (self.store:preferences().thoughts or {})
    local numeric=tonumber(prefs.font_size)
    if numeric then return math.max(12,math.min(48,math.floor(numeric+.5))) end
    local legacy={small=18,standard=22,large=26,xlarge=30}
    return legacy[tostring(prefs.font or "standard")] or 22
end

function Plugin:_thought_font_size_label()
    return tostring(self:_thought_font_size_value())
end

function Plugin:_set_thought_font_size(value,quiet)
    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
    local target=math.max(12,math.min(48,math.floor((tonumber(value) or self:_thought_font_size_value(p.thoughts))+.5)))
    p.thoughts.font_size=target
    -- Keep the legacy field readable for one compatibility cycle, but the
    -- continuous numeric value is authoritative from beta.8 onward.
    p.thoughts.font=nil
    self:_save_ui_preferences(p,"thought_font_size")
    self:_refresh_thought_display(p.thoughts)
    if quiet~=true then self:toast("评论字号："..tostring(target),1.2) end
    return true
end

function Plugin:_adjust_thought_font_size(delta)
    return self:_set_thought_font_size(self:_thought_font_size_value()+(tonumber(delta) or 0),true)
end

function Plugin:_refresh_thought_display(prefs)
    prefs=prefs or (self.store:preferences().thoughts or {})
    if ThoughtNativePopup and type(ThoughtNativePopup.refresh_font)=="function" then
        pcall(ThoughtNativePopup.refresh_font,
            self:_thought_font_size(self:_thought_font_size_value(prefs)),
            self:_thought_font_name(prefs))
    end
end

function Plugin:_toggle_thought_follow_body_font()
    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
    p.thoughts.follow_body_font=p.thoughts.follow_body_font~=true
    self:_save_ui_preferences(p,"thought_font_follow")
    self:_refresh_thought_display(p.thoughts)
    return true
end

function Plugin:_show_reader_comment_settings(back_callback)
    local return_to_comments=function() self:_show_reader_comment_settings(back_callback) end
    local function comment_preview_text()
        return "这是一段评论文字，用来预览当前字体、字号和实际阅读效果。"
    end
    ReaderTypographyDialog.show{
        title="想法显示",
        subtitle=function()
            if not self:_thoughts_enabled() then return "想法已关闭 · 划线与想法数据仍保留" end
            local prefs=self.store:preferences().thoughts or {}
            return (prefs.follow_body_font==true and "字体跟随正文" or self:_thought_font_face_label(prefs)).." · 字号 "..self:_thought_font_size_label()
        end,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        controls=function()
            local prefs=self.store:preferences().thoughts or {}
            local follow=prefs.follow_body_font==true
            return {
                {kind="select",label="想法",value=self:_thoughts_enabled_label(),value_bold=true,callback=function() self:_toggle_thoughts_enabled() end},
                {kind="select",label="评论字体",value=follow and ("跟随正文 · "..self:_reader_font_label()) or self:_thought_font_face_label(prefs),close=true,callback=function()
                    self:_show_reader_menu_table("评论字体",self:thought_font_face_menu(),return_to_comments)
                end},
                {kind="step",label="字号",value=function() return self:_thought_font_size_label() end,
                    on_decrease=function() self:_adjust_thought_font_size(-1) end,
                    on_increase=function() self:_adjust_thought_font_size(1) end,
                    on_decrease_hold=function() self:_adjust_thought_font_size(-3) end,
                    on_increase_hold=function() self:_adjust_thought_font_size(3) end},
                {kind="select",label="跟随正文字体",value=follow and "已开启" or "已关闭",value_bold=true,callback=function() self:_toggle_thought_follow_body_font() end},
            }
        end,
        preview_label="评论预览",
        preview_text=comment_preview_text,
        preview_font=function() return self:_thought_font_name(self.store:preferences().thoughts or {}) end,
        preview_size=function() return self:_thought_font_size_value() end,
        preview_line_height=.18,
        actions=function()
            return {
                {label="恢复默认",callback=function()
                    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
                    p.thoughts.font_size=22; p.thoughts.font=nil; p.thoughts.font_face=""; p.thoughts.follow_body_font=false
                    self:_save_ui_preferences(p,"thought_font_reset")
                    self:_refresh_thought_display(p.thoughts)
                    self:toast("想法显示已恢复默认",1.5)
                end},
                {label="应用到全部评论",primary=true,callback=function()
                    -- 评论显示偏好本身就是觅阅全局偏好；这里显式保存并
                    -- 给用户一个明确的“应用到全部”操作，而不再另造一份状态。
                    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
                    self:_save_ui_preferences(p,"thought_font_global")
                    self:toast("已应用到全部评论",1.5)
                end},
            }
        end,
    }
    return true
end

function Plugin:_reader_font_label()
    local ui=self.ui
    local font=ui and ui.font
    local configurable=ui and ui.document and ui.document.configurable or nil
    local name=font and font.font_face or (configurable and (configurable.font_face or configurable.font))
    name=U.trim(tostring(name or ""))
    return name~="" and name or "KOReader 默认"
end

function Plugin:_reader_font_size_value()
    local ui=self.ui
    local font=ui and ui.font
    local configurable=ui and ui.document and ui.document.configurable or nil
    return font and tonumber(font.font_size)
        or (ui and ui.rolling and tonumber(ui.rolling.font_size))
        or (configurable and tonumber(configurable.font_size))
end

function Plugin:_reader_font_size_label()
    local current=self:_reader_font_size_value()
    return current and tostring(math.floor(current+.5)) or "未知"
end

function Plugin:_reader_toolbar_title()
    -- Never reload Store on a swipe. Sync already owns the current book record.
    local current=self.sync and self.sync:record() or nil
    local title=current and current.book and current.book.title or nil
    if not title or title=="" then
        local path=self:_current_document_path()
        title=path and path:match("([^/]+)$") or "正在阅读"
    end
    local percent=self:_reader_toolbar_cached_percent()
    local progress=percent and (tostring(math.floor(percent+.5)).."%") or "位置未知"
    local status=progress.." · "..tostring(self:progress_sync_label())
    return tostring(title),status,progress,percent
end

function Plugin:_reader_current_wifi_name(max_chars)
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr or type(NetworkMgr.getCurrentNetwork)~="function" then return nil end
    local ok,current=pcall(NetworkMgr.getCurrentNetwork,NetworkMgr)
    if not ok or type(current)~="table" then return nil end
    local ssid=U.trim(tostring(current.ssid or current.name or ""))
    if ssid=="" then return nil end
    return U.utf8_truncate(ssid,tonumber(max_chars) or 18,"…")
end

function Plugin:_reader_wifi_summary()
    local state=HomeData.cached_device_state() or {}
    if state.wifi_on==false then return "Wi-Fi关",false end
    if state.wifi_on==nil then return "Wi-Fi",true end
    local ssid=U.trim(tostring(state.wifi_name or ""))
    if ssid~="" then return ssid,false end
    if state.online==true then return "已连接",false end
    return "Wi-Fi!",true
end

function Plugin:_reader_battery_label()
    local state=HomeData.cached_device_state() or {}
    local value=tonumber(state.battery)
    if not value then return "" end
    return tostring(math.max(0,math.min(100,math.floor(value+.5)))).."%"
end

function Plugin:_reader_toolbar_header(title)
    local started=os.clock()
    local device_started=os.clock()
    local wifi_label,wifi_alert=self:_reader_wifi_summary()
    local wifi_text=wifi_label
    if wifi_label=="Wi-Fi关" then wifi_text="已关闭"
    elseif wifi_label=="Wi-Fi!" then wifi_text="未连接"
    elseif wifi_label=="Wi-Fi" then wifi_text="状态未知" end
    local battery=self:_reader_battery_label()
    local bluetooth_state=self:_bluetooth_state(false)
    -- G3: today's reading time from the same ledger as the 我的页 card, so the
    -- reader surface and the external UI share one duration source.
    local duration_label=""
    local saved_ledger=self.store:get("read_time_ledger")
    if type(saved_ledger)=="table" then
        local today=ReadTimeLedger.today(saved_ledger)
        if today>0 then duration_label="今日 "..ReadTimeLedger.format_compact(today) end
    end
    local device_ms=math.floor((os.clock()-device_started)*1000+.5)

    local state_started=os.clock()
    local cache=self:_reader_toolbar_cache()
    local page,total=tonumber(cache.page),tonumber(cache.total)
    local chapter=U.trim(tostring(cache.chapter or ""))
    if chapter=="" then chapter="当前章节" end
    local progress_text=""
    if page and total and total>0 then
        local remaining=math.max(0,math.floor(total+.5)-math.floor(page+.5))
        progress_text=tostring(math.floor(page+.5)).." / "..tostring(math.floor(total+.5))
        if remaining>0 then progress_text=progress_text.." · 剩 "..tostring(remaining).." 页" end
    else
        local percent=self:_reader_toolbar_cached_percent()
        progress_text=percent and (tostring(math.floor(percent+.5)).."%") or "阅读进度"
    end
    local state_ms=math.floor((os.clock()-state_started)*1000+.5)
    self._reader_toolbar_header_perf={
        device_ms=device_ms,
        state_ms=state_ms,
        chapter_cached=chapter~="当前章节" or tostring(cache.chapter or "")~="",
        cache_age=math.max(0,os.time()-(tonumber(cache.updated_at) or os.time())),
        total_ms=math.floor((os.clock()-started)*1000+.5),
    }
    return {
        title=tostring(title or "正在阅读"),
        home_label="首页",
        home_callback=function() return self:return_to_miuread_home("reader surface") end,
        book_callback=function() return self:_show_reader_current_book_panel(function() self:show_reader_quick_panel() end) end,
        wifi_label=wifi_text,wifi_alert=wifi_alert,
        wifi_callback=function() return self:_show_reader_wifi_quick_panel(function() self:show_reader_quick_panel() end) end,
        wifi_hold_callback=function() return self:_reader_wifi_settings(function() self:show_reader_quick_panel() end) end,
        bluetooth_visible=bluetooth_state.supported==true,
        bluetooth_label=bluetooth_state.enabled==true and "蓝牙开" or "蓝牙关",
        bluetooth_callback=bluetooth_state.supported==true and function() return self:_bluetooth_toggle() end or nil,
        battery_label=battery,
        duration_label=duration_label,
        more_label="更多",
        more_callback=function() return self:show_reader_control_center("reading") end,
        chapter_label=chapter,
        chapter_callback=function() return self:_show_reader_toc(function() self:show_reader_quick_panel() end) end,
        progress_label=progress_text,
        progress_callback=function() return self:_show_reader_progress_control(function() self:show_reader_quick_panel() end) end,
    }
end

function Plugin:_reader_record_recent_action() return false end

function Plugin:_reader_night_enabled()
    local enabled=false
    if G_reader_settings and type(G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(G_reader_settings.readSetting,G_reader_settings,"night_mode")
        if ok then enabled=value==true end
    end
    return enabled
end

function Plugin:_reader_night_label()
    return self:_reader_night_enabled() and "已开启" or "已关闭"
end

function Plugin:_reader_rotation_label()
    return Orientation.status_label()
end

function Plugin:_reader_status_bar_label()
    local ui=self.ui
    local footer=ui and ui.view and ui.view.footer or (ui and ui.footer) or nil
    if footer then
        if footer.disabled~=nil then return footer.disabled and "已关闭" or "已开启" end
        if footer.visible~=nil then return footer.visible and "已开启" or "已关闭" end
    end
    return "点击切换"
end

function Plugin:_reader_toggle_status_bar()
    local ui=self.ui
    local footer=ui and ui.view and ui.view.footer or (ui and ui.footer) or nil
    if footer then
        for _,method in ipairs({"onToggleFooter","toggleFooter","onToggleVisibility"}) do
            if type(footer[method])=="function" then
                local ok=pcall(footer[method],footer)
                if ok then return true end
            end
        end
    end
    if ui and type(ui.handleEvent)=="function" then
        ui:handleEvent(Event:new("ToggleFooter"))
        return true
    end
    self:info("当前 KOReader 版本暂时无法直接切换状态栏")
    return false
end

function Plugin:_reader_open_footer_settings()
    local ui=self.ui
    local footer=ui and ui.view and ui.view.footer or (ui and ui.footer) or nil
    if footer then
        for _,method in ipairs({"onShowFooterMenu","onShowFooterSettings","showSettings"}) do
            if type(footer[method])=="function" then
                local ok=pcall(footer[method],footer)
                if ok then return true end
            end
        end
    end
    self:info("当前 KOReader 版本暂时无法直接打开状态栏设置")
    return false
end

function Plugin:_reader_menu_rows_from_table(source,title,back_callback)
    local rows={}
    for _,item in ipairs(type(source)=="table" and source or {}) do
        if type(item)=="table" then
            local visible=true
            if type(item.show_func)=="function" then
                local ok,value=pcall(item.show_func)
                visible=ok and value~=false
            end
            if visible then
                local label=item.text
                if type(item.text_func)=="function" then
                    local ok,value=pcall(item.text_func)
                    if ok then label=value end
                end
                label=U.trim(tostring(label or ""))
                if label~="" then
                    local value=item.post_text
                    if type(item.post_text_func)=="function" then
                        local ok,result=pcall(item.post_text_func)
                        if ok then value=result end
                    end
                    local checked=false
                    if type(item.checked_func)=="function" then
                        local ok,result=pcall(item.checked_func)
                        checked=ok and result==true
                    elseif item.checked==true then checked=true end
                    local enabled=item.enabled~=false
                    if type(item.enabled_func)=="function" then
                        local ok,result=pcall(item.enabled_func)
                        enabled=ok and result~=false
                    end
                    local submenu=item.sub_item_table
                    if type(item.sub_item_table_func)=="function" then
                        local ok,result=pcall(item.sub_item_table_func)
                        if ok then submenu=result end
                    end
                    local row={
                        label=label,
                        value=checked and ((value and tostring(value)~="") and (tostring(value).." · ✓") or "✓") or tostring(value or ""),
                        checked=checked, enabled=enabled,
                        keep_open=item.keep_menu_open==true,
                    }
                    if type(submenu)=="table" then
                        row.callback=function()
                            self:_show_reader_menu_table(label,submenu,function()
                                self:_show_reader_menu_table(title,source,back_callback)
                            end)
                        end
                    elseif type(item.callback)=="function" then
                        row.callback=item.callback
                    else
                        row.arrow=false
                    end
                    rows[#rows+1]=row
                end
            end
        end
    end
    return rows
end

function Plugin:_show_reader_menu_table(title,source,back_callback)
    ReaderListDialog.show{
        title=tostring(title or "阅读界面设置"),
        items=function() return self:_reader_menu_rows_from_table(source,title,back_callback) end,
        page_size=tonumber(type(source)=="table" and source.max_per_page) or 6,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
    }
    return true
end

function Plugin:_reader_annotation_type(item)
    return LocalAnnotationDatabase.annotation_kind(item)
end

function Plugin:_reader_annotation_xpointer(item)
    if type(item)~="table" then return nil end
    local xp=item.pos0 or item.start or item.xpointer
    if (xp==nil or xp=="") and type(item.page)=="string" and tonumber(item.page)==nil then
        xp=item.page
    end
    if type(xp)=="string" and xp~="" then return xp end
    return nil
end

function Plugin:_reader_annotation_page(item)
    if type(item)~="table" then return nil end
    local page=tonumber(item.page or item.pageno)
    if page then return math.floor(page+.5) end
    local xp=self:_reader_annotation_xpointer(item)
    local doc=self.ui and self.ui.document or nil
    if xp and doc and type(doc.getPageFromXPointer)=="function" then
        -- Memoize per-book xpointer→page conversions: the records dialog
        -- builds rows for every mirror/native row and would otherwise repeat
        -- CREngine calls for the same positions (fluency review).
        local book_id = self:_annotation_current_book_id()
        local key = tostring(book_id or "") .. "|" .. xp
        local memo = self._reader_page_memo
        if memo and memo[key] ~= nil then
            local hit = memo[key]
            return hit or nil
        end
        local ok,value=pcall(doc.getPageFromXPointer,doc,xp)
        local converted = ok and tonumber(value) and math.floor(tonumber(value)+.5) or nil
        if not memo then memo = {}; self._reader_page_memo = memo end
        memo[key] = converted or false
        return converted
    end
    return nil
end

function Plugin:_reader_current_xpointer()
    local ui = self.ui
    local doc = ui and ui.document or nil
    if not doc then return nil end
    if ui.rolling and type(ui.rolling.xpointer) == "string" and ui.rolling.xpointer ~= "" then
        return ui.rolling.xpointer
    end
    if type(doc.getXPointer) == "function" then
        local ok, value = pcall(doc.getXPointer, doc)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

function Plugin:_progress_anchor_item()
    local xp = self:_reader_current_xpointer()
    if not xp then return nil end
    local page
    local doc = self.ui and self.ui.document or nil
    if doc and type(doc.getPageFromXPointer) == "function" then
        local ok, value = pcall(doc.getPageFromXPointer, doc, xp)
        if ok and tonumber(value) then page = math.floor(tonumber(value) + .5) end
    end
    return {
        id = "miu-progress-anchor",
        xpointer = xp,
        page = page,
        text = "",
        note = "",
        datetime = "0",
    }
end

local function annotation_doc_text(doc, first_xp, last_xp)
    if not (doc and type(doc.getTextFromXPointers)=="function") then return "" end
    if type(first_xp)~="string" or first_xp=="" or type(last_xp)~="string" or last_xp=="" then return "" end
    local ok,text=pcall(doc.getTextFromXPointers,doc,first_xp,last_xp,false)
    if not ok then return "" end
    if type(text)=="table" then text=text.text or text[1] end
    return tostring(text or "")
end

function Plugin:_reader_annotation_selection_context(item,kind)
    if type(item)~="table" or (kind~="highlight" and kind~="thought") then
        return "", "", ""
    end
    local doc=self.ui and self.ui.document or nil
    local pos0=type(item.pos0)=="string" and item.pos0 or (type(item.start)=="string" and item.start or nil)
    local pos1=type(item.pos1)=="string" and item.pos1 or (type(item["end"])=="string" and item["end"] or nil)
    local selected=U.trim(tostring(item.text or item.notes or ""))

    -- Prefer the actual CREngine selection over the list label. This preserves
    -- the text the XPointer really covers when KOReader normalized the display.
    if doc and pos0 and pos1 then
        local extracted=U.trim(annotation_doc_text(doc,pos0,pos1))
        if extracted~="" then selected=extracted end
    end

    local before,after="",""
    if not (doc and pos0 and pos1) then return selected,before,after end

    -- Context is captured only for a manual sync. It is intentionally bounded:
    -- enough to distinguish repeated quotes without doing heavy work while the
    -- user is creating the annotation.
    local before_xp=pos0
    if type(doc.getPrevVisibleWordStart)=="function" then
        for _=1,12 do
            local ok,next_xp=pcall(doc.getPrevVisibleWordStart,doc,before_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==before_xp then break end
            before_xp=next_xp
        end
    elseif type(doc.getPrevVisibleChar)=="function" then
        for _=1,48 do
            local ok,next_xp=pcall(doc.getPrevVisibleChar,doc,before_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==before_xp then break end
            before_xp=next_xp
        end
    end
    local raw_before=annotation_doc_text(doc,before_xp,pos0)
    local before_len=U.utf8_len(raw_before)
    if before_len>0 then before=U.utf8_sub(raw_before,math.max(1,before_len-63),before_len) end

    local after_xp=pos1
    if type(doc.getNextVisibleWordEnd)=="function" then
        for _=1,12 do
            local ok,next_xp=pcall(doc.getNextVisibleWordEnd,doc,after_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==after_xp then break end
            after_xp=next_xp
        end
    elseif type(doc.getNextVisibleChar)=="function" then
        for _=1,48 do
            local ok,next_xp=pcall(doc.getNextVisibleChar,doc,after_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==after_xp then break end
            after_xp=next_xp
        end
    end
    local raw_after=annotation_doc_text(doc,pos1,after_xp)
    if raw_after~="" then after=U.utf8_sub(raw_after,1,64) end
    return selected,before,after
end

function Plugin:_reader_bookmark_anchor_text(item)
    local doc=self.ui and self.ui.document or nil
    local xp=self:_reader_annotation_xpointer(item)
    if not (doc and xp and type(doc.getTextFromXPointers)=="function") then return "" end
    if type(doc.isXPointerInDocument)=="function" then
        local ok,valid=pcall(doc.isXPointerInDocument,doc,xp)
        if ok and valid==false then return "" end
    end

    -- KOReader rolling bookmarks store the page XPointer itself. Build a short
    -- text anchor starting exactly at that XPointer, rather than using the
    -- bookmark list label (which is usually only the chapter name).
    local end_xp=xp
    local steps=0
    if type(doc.getNextVisibleWordEnd)=="function" then
        for _=1,24 do
            local ok,next_xp=pcall(doc.getNextVisibleWordEnd,doc,end_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==end_xp then break end
            end_xp=next_xp
            steps=steps+1
        end
    end
    if steps==0 and type(doc.getNextVisibleChar)=="function" then
        for _=1,32 do
            local ok,next_xp=pcall(doc.getNextVisibleChar,doc,end_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==end_xp then break end
            end_xp=next_xp
            steps=steps+1
        end
    end
    if steps==0 then return "" end

    local ok,text=pcall(doc.getTextFromXPointers,doc,xp,end_xp,false)
    if not ok then return "" end
    if type(text)=="table" then text=text.text or text[1] end
    text=U.trim(tostring(text or ""):gsub("%s+"," "))
    if text=="" then return "" end
    return U.utf8_truncate(text,96)
end

function Plugin:_reader_annotation_excerpt(item,kind)
    if type(item)~="table" then return "" end
    local text
    if kind=="thought" then text=item.note or item.text or item.notes
    elseif kind=="highlight" then text=item.text or item.notes
    else text=item.text end
    text=U.trim(tostring(text or ""):gsub("%s+"," "))
    if text=="" and kind=="bookmark" then text=AnnotationKinds.BOOKMARK_FALLBACK end
    text=U.utf8_truncate(text,120)
    return text
end

function Plugin:_reader_goto_annotation(item)
    local ui=self.ui
    local bookmark=ui and ui.bookmark or nil
    if bookmark and type(bookmark.gotoBookmark)=="function" then
        local primary
        if ui and ui.paging then
            primary=item and (tonumber(item.page) or item.page or item.pos0 or item.start or item.xpointer) or nil
        else
            primary=item and (item.pos0 or item.start or item.xpointer or item.page) or nil
        end
        local marker=item and (item.pos0 or item.start or item.xpointer) or nil
        local ok,result=pcall(bookmark.gotoBookmark,bookmark,primary,marker)
        if ok and result~=false and primary~=nil and primary~="" then return true end
    end
    local target=item and (item.pos0 or item.start or item.xpointer)
    if ui and type(ui.handleEvent)=="function" then
        if type(target)=="string" and target~="" then ui:handleEvent(Event:new("GotoXPointer",target)); return true end
        local page=self:_reader_annotation_page(item)
        if page then ui:handleEvent(Event:new("GotoPage",page)); return true end
    end
    self:info("当前记录暂时无法定位")
    return false
end


function Plugin:_reader_annotation_index(item)
    local annotations=(self.ui and self.ui.annotation and self.ui.annotation.annotations)
        or (self.ui and self.ui.bookmark and self.ui.bookmark.bookmarks) or {}
    for index,candidate in ipairs(type(annotations)=="table" and annotations or {}) do
        if candidate==item then return index end
    end
    local target_pos=tostring(item and (item.pos0 or item.start or item.xpointer) or "")
    local target_date=tostring(item and (item.datetime or item.date) or "")
    for index,candidate in ipairs(type(annotations)=="table" and annotations or {}) do
        local pos=tostring(candidate and (candidate.pos0 or candidate.start or candidate.xpointer) or "")
        local date=tostring(candidate and (candidate.datetime or candidate.date) or "")
        if target_pos~="" and pos==target_pos and (target_date=="" or date==target_date) then return index end
    end
    return nil
end

function Plugin:_reader_annotation_changed(reason,refresh_callback)
    -- The KOReader mutation is authoritative. Refresh the local mirror only
    -- after it has changed so the existing upload/delete state machine sees
    -- exactly the same edit as one made from the page itself. Editing note text
    -- does not always emit AnnotationsModified, so explicitly checkpoint too.
    self._reader_checkpoint_dirty=true
    self:_schedule_reader_checkpoint(reason or "annotation_manage",.25)
    self:_capture_local_annotation_snapshot(reason or "annotation_manage")
    if refresh_callback then UIManager:scheduleIn(.08,refresh_callback) end
    return true
end

function Plugin:_reader_edit_annotation_note(item,is_new,refresh_callback)
    local bookmark=self.ui and self.ui.bookmark or nil
    local index=self:_reader_annotation_index(item)
    if not (bookmark and index and type(bookmark.setBookmarkNote)=="function") then
        self:info("当前版本暂时无法从这里编辑想法")
        if refresh_callback then UIManager:scheduleIn(.05,refresh_callback) end
        return false
    end
    local completed=false
    local function after_edit()
        if completed then return end
        completed=true
        self:_reader_annotation_changed(is_new and "annotation_add_note" or "annotation_edit_note",refresh_callback)
    end
    local ok,err=pcall(bookmark.setBookmarkNote,bookmark,index,false,nil,after_edit)
    if not ok then
        self:info("无法打开想法编辑：\n"..U.first_line(err,120))
        if refresh_callback then UIManager:scheduleIn(.05,refresh_callback) end
        return false
    end
    return true
end

function Plugin:_reader_delete_annotation_note(item,refresh_callback)
    local bookmark=self.ui and self.ui.bookmark or nil
    if not (bookmark and type(bookmark.deleteItemNote)=="function") then
        self:info("当前版本暂时无法单独删除想法")
        if refresh_callback then UIManager:scheduleIn(.05,refresh_callback) end
        return false
    end
    local ok,err=pcall(bookmark.deleteItemNote,bookmark,item)
    if not ok then
        self:info("删除想法失败：\n"..U.first_line(err,120))
        if refresh_callback then UIManager:scheduleIn(.05,refresh_callback) end
        return false
    end
    return self:_reader_annotation_changed("annotation_delete_note",refresh_callback)
end

function Plugin:_reader_delete_annotation_item(item,refresh_callback)
    local bookmark=self.ui and self.ui.bookmark or nil
    local index=self:_reader_annotation_index(item)
    if not bookmark then
        self:info("当前版本暂时无法从这里删除批注")
        if refresh_callback then UIManager:scheduleIn(.05,refresh_callback) end
        return false
    end
    local ok,err
    if type(bookmark.removeItem)=="function" then
        ok,err=pcall(bookmark.removeItem,bookmark,item,index)
    elseif item and item.drawer and self.ui and self.ui.highlight and type(self.ui.highlight.deleteHighlight)=="function" and index then
        ok,err=pcall(self.ui.highlight.deleteHighlight,self.ui.highlight,index)
    elseif type(bookmark.removeItemByIndex)=="function" and index then
        ok,err=pcall(bookmark.removeItemByIndex,bookmark,index)
    else
        ok,err=false,"没有可用的删除入口"
    end
    if not ok then
        self:info("删除批注失败：\n"..U.first_line(err,120))
        if refresh_callback then UIManager:scheduleIn(.05,refresh_callback) end
        return false
    end
    return self:_reader_annotation_changed("annotation_delete_item",refresh_callback)
end

function Plugin:_reader_confirm_annotation_action(text,ok_text,action,refresh_callback)
    UIManager:show(ConfirmBox:new{
        text=text,ok_text=ok_text or "删除",cancel_text="取消",
        ok_callback=action,
        cancel_callback=refresh_callback,
    })
    return true
end

function Plugin:_show_reader_annotation_actions(item,kind,anchor,refresh_callback)
    if type(item)~="table" then return false end
    kind=kind or self:_reader_annotation_type(item)
    local excerpt=self:_reader_annotation_excerpt(item,kind)
    if excerpt=="" then excerpt=kind=="bookmark" and AnnotationKinds.BOOKMARK_FALLBACK or AnnotationKinds.TEXT_FALLBACK end
    local function refresh()
        if refresh_callback then refresh_callback() end
    end
    local actions={}
    if kind=="highlight" then
        actions[#actions+1]={icon="thought",label="添加想法",detail="保留当前划线并写下想法",callback=function()
            self:_reader_edit_annotation_note(item,true,refresh_callback)
        end}
        actions[#actions+1]={icon="!",label="删除划线",detail="从本书移除这条划线",danger=true,callback=function()
            self:_reader_confirm_annotation_action("删除这条划线？","删除划线",function()
                self:_reader_delete_annotation_item(item,refresh_callback)
            end,refresh_callback)
        end}
    elseif kind=="thought" then
        actions[#actions+1]={icon="thought",label="修改想法",detail="编辑当前想法内容",callback=function()
            self:_reader_edit_annotation_note(item,false,refresh_callback)
        end}
        actions[#actions+1]={icon="×",label="删除想法",detail="只删除想法，保留原划线",danger=true,callback=function()
            self:_reader_confirm_annotation_action("删除这条想法？\n\n原划线会继续保留。","删除想法",function()
                self:_reader_delete_annotation_note(item,refresh_callback)
            end,refresh_callback)
        end}
        actions[#actions+1]={icon="!",label="删除整条批注",detail="划线和想法都会删除",danger=true,callback=function()
            self:_reader_confirm_annotation_action("删除整条批注？\n\n划线和想法都会被删除。","全部删除",function()
                self:_reader_delete_annotation_item(item,refresh_callback)
            end,refresh_callback)
        end}
    else
        actions[#actions+1]={icon="!",label="删除书签",detail="从当前书籍移除这枚书签",danger=true,callback=function()
            self:_reader_confirm_annotation_action("删除这枚书签？","删除书签",function()
                self:_reader_delete_annotation_item(item,refresh_callback)
            end,refresh_callback)
        end}
    end
    actions[#actions+1]={icon="×",label="取消",detail="返回批注列表",callback=refresh}
    ActionSheet.show{
        anchor=anchor,preferred_direction="above",width_ratio=.66,
        title=kind=="thought" and "管理想法" or (kind=="highlight" and "管理划线" or "管理书签"),
        subtitle=U.utf8_truncate(excerpt,80,"…"),actions=actions,
    }
    return true
end

function Plugin:_reader_record_inline_actions(item,kind,back_callback)
    local function refresh_records()
        local next_kind=self:_reader_annotation_type(item) or kind
        self:_show_reader_records(next_kind,back_callback)
    end
    local actions={{label="跳转正文",close=true,callback=function() self:_reader_goto_annotation(item) end}}
    if kind=="highlight" then
        actions[#actions+1]={label="添加想法",callback=function()
            self:_reader_edit_annotation_note(item,true,refresh_records)
        end}
        actions[#actions+1]={label="删除划线",danger=true,callback=function()
            self:_reader_confirm_annotation_action("删除这条划线？","删除划线",function()
                self:_reader_delete_annotation_item(item,refresh_records)
            end,refresh_records)
        end}
    elseif kind=="thought" then
        actions[#actions+1]={label="修改想法",callback=function()
            self:_reader_edit_annotation_note(item,false,refresh_records)
        end}
        actions[#actions+1]={label="删除想法",danger=true,callback=function()
            self:_reader_confirm_annotation_action("删除这条想法？\n\n原划线会继续保留。","删除想法",function()
                self:_reader_delete_annotation_note(item,refresh_records)
            end,refresh_records)
        end}
        actions[#actions+1]={label="删除全部",danger=true,callback=function()
            self:_reader_confirm_annotation_action("删除整条批注？\n\n划线和想法都会被删除。","全部删除",function()
                self:_reader_delete_annotation_item(item,refresh_records)
            end,refresh_records)
        end}
    else
        actions[#actions+1]={label="删除书签",danger=true,callback=function()
            self:_reader_confirm_annotation_action("删除这枚书签？","删除书签",function()
                self:_reader_delete_annotation_item(item,refresh_records)
            end,refresh_records)
        end}
    end
    return actions
end

function Plugin:_reader_record_rows(kind,back_callback)
    local annotations=(self.ui and self.ui.annotation and self.ui.annotation.annotations)
        or (self.ui and self.ui.bookmark and self.ui.bookmark.bookmarks) or {}
    local rows={}
    local seen={}
    -- Position-based dedupe: the mirror rows are snapshots of the same native
    -- highlights (identical pos0), so without a shared key the list shows every
    -- highlight twice (device feedback: 37 native + 37 mirrored = 19 pages).
    local seen_pos={}
    for _,item in ipairs(type(annotations)=="table" and annotations or {}) do
        local id=tostring(item.uuid or item.id or item.bookmarkId or "")
        if id~="" then seen[id]=true end
        local pos_key=tostring(item.pos0 or item.start or item.xpointer or "")
        if pos_key~="" then seen_pos[pos_key]=true end
        if self:_reader_annotation_type(item)==kind then
            local page=self:_reader_annotation_page(item)
            local excerpt=self:_reader_annotation_excerpt(item,kind)
            local target=item
            rows[#rows+1]={
                label=excerpt~="" and excerpt or (kind=="bookmark" and AnnotationKinds.BOOKMARK_FALLBACK or AnnotationKinds.TEXT_FALLBACK),
                value=page and ("第 "..tostring(page).." 页") or "",
                detail=tostring(item.datetime or item.date or ""),
                inline_actions=function() return self:_reader_record_inline_actions(target,kind,back_callback) end,
            }
        end
    end
    -- Merge the locally mirrored annotations (synced bookmarks/highlights and
    -- thoughts). They live in the SQLite mirror, not in KOReader's native
    -- annotation list, so they would otherwise never appear here.
    local book_id=self:_annotation_current_book_id()
    if book_id~="" then
        local db_rows,err=LocalAnnotationDatabase.list(self.store,book_id,400)
        if type(db_rows)=="table" then
            for _,row in ipairs(db_rows) do
                if tostring(row.kind or "")==kind then
                    local local_id=tostring(row.local_id or "")
                    local pos_key=tostring(row.pos0 or "")
                    if pos_key~="" and seen_pos[pos_key] then
                        -- Same native highlight already shown from KOReader's
                        -- own list (which carries a live page); skip the mirror.
                    else
                    seen[local_id]=true
                    if pos_key~="" then seen_pos[pos_key]=true end
                    local page=tonumber(row.page)
                    local excerpt=self:_reader_annotation_excerpt(row,kind)
                    local row_target=row
                    rows[#rows+1]={
                        label=excerpt~="" and excerpt or (kind=="bookmark" and AnnotationKinds.BOOKMARK_FALLBACK or AnnotationKinds.TEXT_FALLBACK),
                        value=page and ("第 "..tostring(page).." 页") or "",
                        detail=tostring(row.datetime or row.updated_at or ""),
                        inline_actions=function()
                            local actions={{label="跳转正文",close=true,callback=function()
                                local ui=self.ui
                                if not ui then return end
                                -- Mirror rows store local pos0 (snapshot of the
                                -- native highlight); xpointer is usually empty or
                                -- a WeRead server range. Resolve via the helper so
                                -- local coordinates jump correctly.
                                local xp=self:_reader_annotation_xpointer(row_target) or ""
                                -- Cloud-only rows carry WeRead server coordinates that
                                -- rarely resolve in the local EPUB. Pre-check before
                                -- jumping so a failed GotoXPointer is not silent.
                                local ok_pos=false
                                if xp~="" and ui.document and type(ui.document.getPosFromXPointer)=="function" then
                                    local ok,pos=pcall(ui.document.getPosFromXPointer,ui.document,xp)
                                    ok_pos=ok and tonumber(pos)~=nil
                                end
                                if xp~="" and ok_pos and type(ui.handleEvent)=="function" then
                                    ui:handleEvent(Event:new("GotoXPointer",xp))
                                elseif page and type(ui.handleEvent)=="function" then
                                    ui:handleEvent(Event:new("GotoPage",page))
                                else
                                    self:toast("该划线来自云端，本机暂未定位到对应位置",2.5)
                                end
                            end}}
                            return actions
                        end,
                    }
                end
            end
            end
        else
            logger.warn("[MiuRead][Records] local annotation mirror read failed",tostring(err or "unknown"))
        end
    end
    return rows
end

function Plugin:_reader_annotation_counts()
    local annotations=(self.ui and self.ui.annotation and self.ui.annotation.annotations)
        or (self.ui and self.ui.bookmark and self.ui.bookmark.bookmarks) or {}
    local counts={bookmark=0,highlight=0,thought=0,total=0}
    for _,item in ipairs(type(annotations)=="table" and annotations or {}) do
        local kind=self:_reader_annotation_type(item)
        if counts[kind]~=nil then
            counts[kind]=counts[kind]+1
            counts.total=counts.total+1
        end
    end
    return counts
end

function Plugin:_reader_annotation_summary_label()
    local counts=self:_reader_annotation_counts()
    return AnnotationKinds.summary(counts)
end

function Plugin:_enable_annotation_sync_and_sync_current()
    -- Compatibility shim for older callbacks. Manual sync is an explicit
    -- command and no longer changes a persistent enable/disable switch.
    UIManager:scheduleIn(.08,function()
        if self.ui and self.ui.document then self:sync_local_annotations_now() end
    end)
    return true
end

function Plugin:_show_reader_annotation_panel(back_callback)
    if not (self.ui and self.ui.document) then return false end
    -- Refresh only the local mirror when the user explicitly opens this panel.
    -- No network/range work runs during a normal highlight gesture or page turn.
    -- The mirror upsert is deferred off the open path so the panel renders
    -- immediately; mutation snapshots keep the mirror fresh meanwhile and
    -- main.lua throttles repeated explicit refreshes (fluency review).
    if self._annotation_panel_snapshot_task then
        UIManager:unschedule(self._annotation_panel_snapshot_task)
        self._annotation_panel_snapshot_task = nil
    end
    self._annotation_panel_snapshot_task = UIManager:scheduleIn(.15, function()
        self._annotation_panel_snapshot_task = nil
        self:_capture_local_annotation_snapshot("annotation_panel")
    end)
    local current=(self.sync and self.sync:record()) or self:_current_book_record()
    local book_id=current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    local summary=book_id~="" and LocalAnnotationDatabase.summary(self.store,book_id) or nil
    summary=type(summary)=="table" and summary or {
        total=0,bookmark=0,highlight=0,thought=0,pending=0,synced=0,
        delete_pending=0,locate_failed=0,metadata_failed=0,coord_failed=0,unknown=0,legacy_synced=0,
    }
    local title=current and current.book and U.trim(tostring(current.book.title or "")) or ""
    if title=="" then title="当前书籍" end
    local function return_to_panel() self:_show_reader_annotation_panel(back_callback) end
    local visible_counts=self:_reader_annotation_counts()
    local pending_upload=tonumber(summary.pending or 0) or 0
    local pending_delete=tonumber(summary.delete_pending or 0) or 0
    local pending_work=pending_upload+pending_delete
    local failed=(tonumber(summary.locate_failed or 0) or 0)+(tonumber(summary.metadata_failed or 0) or 0)
        +(tonumber(summary.coord_failed or 0) or 0)+(tonumber(summary.unknown or 0) or 0)
    local legacy_synced=tonumber(summary.legacy_synced or 0) or 0
    ReaderSettingsDialog.show{
        title="批注",
        subtitle=U.utf8_truncate(title,42,"…").." · 书签 划线 想法统一管理",
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            return {
                {title="本书批注",rows={
                    {icon="bookmark",label=AnnotationKinds.label("bookmark"),value=tostring(visible_counts.bookmark or 0),callback=function() self:_show_reader_records("bookmark",return_to_panel) end},
                    {icon="highlight",label=AnnotationKinds.label("highlight"),value=tostring(visible_counts.highlight or 0),callback=function() self:_show_reader_records("highlight",return_to_panel) end},
                    {icon="thought",label=AnnotationKinds.label("thought"),value=tostring(visible_counts.thought or 0),callback=function() self:_show_reader_records("thought",return_to_panel) end},
                    {icon="search",label="搜索全部批注",value="划线 想法 书签",callback=function() self:show_annotation_search_dialog(return_to_panel) end},
                }},
                self:annotation_sync_diagnostic_only() and {title="批注坐标诊断",rows={
                    {icon="warning",label="云端批注写入",value="已暂停 · 防止错误 range",value_bold=true,enabled=false},
                    {icon="diagnostics",label="生成本书坐标诊断",value="导出 raw / coord / range",value_bold=true,callback=function()
                        self:sync_local_annotations_now()
                    end},
                    {label="诊断内容",value="含已同步与待同步本地批注",enabled=false},
                    {label="文件位置",value="books/<bookId>/annotation-coordinate-diagnostics",enabled=false},
                }} or nil,
            }
        end,
    }
    return true
end

function Plugin:_show_reader_records(initial_kind,back_callback)
    local labels=AnnotationKinds.LABELS
    ReaderListDialog.show{
        title="阅读记录",
        subtitle="点击记录展开操作 · 跳转、修改与删除都在当前列表完成",
        initial_category=labels[initial_kind] and initial_kind or "bookmark",
        categories=function()
            return {
                {key="bookmark",label=labels.bookmark,items=self:_reader_record_rows("bookmark",back_callback),empty_text="当前书籍还没有" .. labels.bookmark},
                {key="highlight",label=labels.highlight,items=self:_reader_record_rows("highlight",back_callback),empty_text="当前书籍还没有" .. labels.highlight},
                {key="thought",label=labels.thought,items=self:_reader_record_rows("thought",back_callback),empty_text="当前书籍还没有自己的想法"},
            }
        end,
        page_size=4,
        on_back=back_callback or (self:_home_enabled() and function() self:show_reader_quick_panel() end or function() self:_show_koreader_reader_menu() end),
        on_home=self:_home_enabled() and function() return self:return_to_miuread_home("reader surface") end or nil,
    }
    return true
end

function Plugin:_reader_show_bookmarks(back_callback)
    return self:_show_reader_records("bookmark",back_callback)
end

-- G6 (B10): 章末想法聚合——当前章已同步的划线与想法，按章内位置排序。
-- 只聚合已拉取数据；空态按语义分流（未同步 vs 无想法）。
function Plugin:_show_reader_chapter_thoughts(back_callback)
    if not (self.ui and self.ui.document) then return false end
    local position
    if self.sync and type(self.sync.local_position) == "function" then
        position = self.sync:local_position()
    end
    local uid = tostring(position and position.chapter_uid or "")
    local chapter_idx = tonumber(position and position.chapter_idx)
    local path = self:_current_document_path()
    local records = {}
    if self.external_annotations_db and path then
        local entry = self.external_annotations_db:getDocument(path) or {}
        records = type(entry.records) == "table" and entry.records or {}
    end
    -- 本机镜像合入（架构师 R5）：镜像行的 chapter_uid 可为空串，按
    -- chapter_idx 兜底纳入同章记录；filter 负责 uid 精确/idx 兜底与排序。
    local current = self.sync and self.sync:record() or self:_current_book_record()
    local book_id = current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id ~= "" and LocalAnnotationDatabase then
        local mirror, merr = LocalAnnotationDatabase.list(self.store, book_id, 200)
        if type(mirror) == "table" then
            for _, row in ipairs(mirror) do
                local kind = tostring(row.kind or "")
                if kind == "thought" or kind == "highlight" then
                    local selected = U.trim(tostring(row.selected_text or row.text or ""))
                    local note = U.trim(tostring(row.note or ""))
                    local items = {}
                    if kind == "thought" then
                        items[#items + 1] = { text = note ~= "" and note or selected }
                    end
                    records[#records + 1] = {
                        chapter_uid = tostring(row.chapter_uid or ""),
                        chapter_idx = tonumber(row.chapter_idx),
                        pos0 = tostring(row.pos0 or ""),
                        range = tostring(row.range_key or row.local_id or ""),
                        text = selected,
                        items = items,
                        mirror = true,
                    }
                end
            end
        else
            logger.warn("[MiuRead][ChapterThoughts] mirror read failed", tostring(merr or "unknown"))
        end
    end
    local filtered = ExternalAnnotationParse.filter_records_by_chapter(records, uid, chapter_idx)
    local rows = {}
    for _, record in ipairs(filtered) do
        local text = U.utf8_truncate(U.trim(tostring(record.text or "")), 48, "…")
        local item_count = type(record.items) == "table" and #record.items or 0
        local target = record
        rows[#rows + 1] = {
            icon = item_count > 0 and "thought" or "highlight",
            label = text ~= "" and text or "（无文字）",
            detail = item_count > 0 and ("想法 " .. tostring(item_count) .. " · 划线") or "划线",
            callback = function()
                local xp = tostring(target.pos0 or "")
                if xp ~= "" and type(self.ui.handleEvent) == "function" then
                    self.ui:handleEvent(Event:new("GotoXPointer", xp))
                end
            end,
        }
    end
    local empty_text = uid == "" and "无法定位当前章节"
        or (#records == 0 and "本章尚未同步想法，随阅读进度自动拉取" or "本章暂无想法")
    ReaderListDialog.show{
        title="本章想法",
        subtitle=uid ~= "" and ("已同步 " .. tostring(#filtered) .. " 条 · 点击跳转") or "无法定位当前章节",
        items=rows, page_size=5, empty_text=empty_text,
        on_back=back_callback or function() self:show_reader_control_center("reading") end,
        on_home=self:_home_enabled() and function() return self:return_to_miuread_home("reader surface") end or nil,
    }
    return true
end

function Plugin:_reader_search_results(query,results,back_callback)
    local rows={}
    for _,item in ipairs(type(results)=="table" and results or {}) do
        local excerpt=table.concat({
            tostring(item.prev_text or ""), tostring(item.matched_word_prefix or ""),
            tostring(item.matched_text or ""), tostring(item.matched_word_suffix or ""),
            tostring(item.next_text or ""),
        },"")
        excerpt=U.trim(excerpt:gsub("%s+"," "))
        if excerpt=="" then excerpt="匹配结果" end
        excerpt=U.utf8_truncate(excerpt,150)
        local start_pos=item.start
        local page
        local doc=self.ui and self.ui.document or nil
        if tonumber(start_pos) then page=math.floor(tonumber(start_pos)+.5)
        elseif start_pos and doc and type(doc.getPageFromXPointer)=="function" then
            local ok,value=pcall(doc.getPageFromXPointer,doc,start_pos)
            if ok and tonumber(value) then page=math.floor(tonumber(value)+.5) end
        end
        local target=start_pos
        rows[#rows+1]={label=excerpt,value=page and ("第 "..page.." 页") or "",callback=function()
            local link=self.ui and self.ui.link or nil
            if link and type(link.addCurrentLocationToStack)=="function" then pcall(link.addCurrentLocationToStack,link) end
            local ui=self.ui
            if ui and type(ui.handleEvent)=="function" then
                if type(target)=="string" then ui:handleEvent(Event:new("GotoXPointer",target))
                elseif tonumber(target) then ui:handleEvent(Event:new("GotoPage",tonumber(target))) end
            end
        end}
    end
    ReaderListDialog.show{
        title="搜索结果",
        subtitle="“"..tostring(query).."” · "..tostring(#rows).." 处",
        items=rows,page_size=5,
        empty_text="没有找到匹配内容",
        on_back=function() self:_reader_show_search(back_callback) end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
    }
    return true
end

function Plugin:_reader_run_search(query,back_callback)
    local doc=self.ui and self.ui.document or nil
    if not doc or type(doc.findAllText)~="function" then
        self:info("当前书籍暂不支持全文搜索")
        if back_callback then UIManager:scheduleIn(.05,back_callback) end
        return false
    end
    local results
    local search=self.ui and self.ui.search or nil
    local context=tonumber(search and search.findall_nb_context_words) or 6
    local maximum=tonumber(search and search.findall_max_hits) or 100
    local flags=search and search.current_search_type and search.current_search_type.flags or nil
    local ok,value=pcall(doc.findAllText,doc,query,true,context,maximum,false,flags)
    if not ok then ok,value=pcall(doc.findAllText,doc,query,true,context,maximum) end
    if ok and type(value)=="table" then results=value else results={} end
    return self:_reader_search_results(query,results,back_callback)
end

function Plugin:_reader_show_search(back_callback)
    local dialog
    dialog=InputDialog:new{
        title="书内搜索",
        description="搜索当前书籍正文",
        input=tostring(self._reader_last_search or ""),
        buttons={{
            {text="取消",id="close",callback=function()
                UIManager:close(dialog)
                if back_callback then UIManager:scheduleIn(.05,back_callback) end
            end},
            {text="搜索",is_enter_default=true,callback=function()
                local query=U.trim(dialog:getInputText())
                UIManager:close(dialog)
                if query=="" then
                    if back_callback then UIManager:scheduleIn(.05,back_callback) end
                    return
                end
                self._reader_last_search=query
                self:status_toast("书内搜索","正在查找“"..query.."”",2)
                UIManager:nextTick(function() self:_reader_run_search(query,back_callback) end)
            end},
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

function Plugin:_reader_go_back_location()
    local link=self.ui and self.ui.link or nil
    if link then
        for _,method in ipairs({"onGoBackLink","onGoBack","goBack"}) do
            if type(link[method])=="function" then
                local ok=pcall(link[method],link)
                if ok then return true end
            end
        end
    end
    local ui=self.ui
    if ui and type(ui.handleEvent)=="function" then
        ui:handleEvent(Event:new("GoBackLink"))
        return true
    end
    return false
end

function Plugin:_reader_show_history(back_callback)
    local link=self.ui and self.ui.link or nil
    if not link then self:info("当前 KOReader 版本暂时无法直接打开阅读历史"); return false end
    return self:_reader_open_native_page("阅读历史",function()
        for _,method in ipairs({"onShowLinkHistory","onShowHistory","showHistory"}) do
            if type(link[method])=="function" then
                local ok=pcall(link[method],link)
                if ok then return true end
            end
        end
        return false
    end,back_callback or function() self:show_reader_quick_panel() end)
end
function Plugin:_reader_apply_typography_defaults()
    if not (G_reader_settings and type(G_reader_settings.saveSetting)=="function") then
        self:info("当前 KOReader 暂时无法保存全局排版默认")
        return false
    end
    local face=self:_reader_font_label()
    local size=self:_reader_font_size_value()
    local weight=self:_reader_font_weight_value()
    local spacing=self:_reader_line_spacing_value()
    if face and face~="" and face~="KOReader 默认" then G_reader_settings:saveSetting("cre_font",face) end
    if size then G_reader_settings:saveSetting("copt_font_size",size) end
    G_reader_settings:saveSetting("copt_font_base_weight",weight)
    G_reader_settings:saveSetting("copt_line_spacing",spacing)
    if type(G_reader_settings.flush)=="function" then pcall(G_reader_settings.flush,G_reader_settings) end
    self:toast("已设为 KOReader 全部书籍默认",1.8)
    return true
end

function Plugin:_reader_restore_typography_defaults()
    local size=G_reader_settings and tonumber(G_reader_settings:readSetting("copt_font_size")) or nil
    local weight=G_reader_settings and tonumber(G_reader_settings:readSetting("copt_font_base_weight")) or nil
    local spacing=G_reader_settings and tonumber(G_reader_settings:readSetting("copt_line_spacing")) or nil
    if size then
        local current=self:_reader_font_size_value()
        if current then self:_reader_adjust_font_size(size-current) end
    end
    if weight then self:_reader_set_font_weight(weight) end
    if spacing then self:_reader_set_line_spacing(spacing) end
    local default_face=G_reader_settings and tostring(G_reader_settings:readSetting("cre_font") or "") or ""
    local font=self.ui and self.ui.font or nil
    if default_face~="" and font and type(font.onSetFont)=="function" then pcall(font.onSetFont,font,default_face) end
    self:toast("已恢复 KOReader 默认排版",1.5)
    return true
end

function Plugin:_show_reader_font_panel(back_callback)
    local return_to_font=function() self:_show_reader_font_panel(back_callback) end
    ReaderTypographyDialog.show{
        title="字体与排版",
        subtitle=function() return self:_reader_font_label().." · 字号 "..self:_reader_font_size_label() end,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        controls=function()
            return {
                {kind="select",label="字体",value=self:_reader_font_label(),close=true,callback=function() self:_show_reader_font_face_menu(return_to_font) end},
                {kind="step",label="字号",value=function() return self:_reader_font_size_label() end,
                    on_decrease=function() self:_reader_adjust_font_size(-1) end,on_increase=function() self:_reader_adjust_font_size(1) end,
                    on_decrease_hold=function() self:_reader_adjust_font_size(-3) end,on_increase_hold=function() self:_reader_adjust_font_size(3) end},
                {kind="step",label="字重",value=function() return string.format("%.2f",self:_reader_font_weight_value()) end,
                    on_decrease=function() self:_reader_adjust_font_weight(-.25) end,on_increase=function() self:_reader_adjust_font_weight(.25) end,
                    on_decrease_hold=function() self:_reader_adjust_font_weight(-.5) end,on_increase_hold=function() self:_reader_adjust_font_weight(.5) end},
                {kind="step",label="行距",value=function() return tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%" end,
                    on_decrease=function() self:_reader_adjust_line_spacing(-5) end,on_increase=function() self:_reader_adjust_line_spacing(5) end,
                    on_decrease_hold=function() self:_reader_adjust_line_spacing(-10) end,on_increase_hold=function() self:_reader_adjust_line_spacing(10) end},
                {kind="select",label="高级排版",value="字符间距与更多版式",close=true,callback=function() self:_show_reader_advanced_typeset_panel(return_to_font) end},
            }
        end,
        preview_label="正文预览",
        preview_text="阅读是一件很私人的事情。合适的字体、字号和行距，会直接影响长时间阅读体验。",
        preview_font=function()
            local font=self.ui and self.ui.font or nil
            return font and font.font_face or nil
        end,
        preview_size=function() return math.max(12,math.min(48,self:_reader_font_size_value() or 22)) end,
        preview_line_height=function()
            local spacing=self:_reader_line_spacing_value()
            return math.max(.05,math.min(.60,(spacing-100)/180+.12))
        end,
        actions=function()
            return {
                {label="恢复当前书籍",callback=function() self:_reader_restore_typography_defaults() end},
                {label="设为全部书籍默认",primary=true,callback=function() self:_reader_apply_typography_defaults() end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_current_book_panel(back_callback)
    return self:_show_reader_menu_table("当前书籍",self:current_book_menu(),back_callback)
end
function Plugin:_show_koreader_reader_menu(back_callback)
    local current_ui=self.ui
    if not (current_ui and current_ui.document) then return false end
    if self._reader_native_menu_opening then return true end
    self._reader_native_menu_opening=true
    return self:_reader_open_native_page("KOReader 高级菜单",function()
        local ui=self.ui
        local menu=ui and ui.menu or nil
        if not (ui and ui.document) then self._reader_native_menu_opening=false; return false end
        local ok,err=xpcall(function()
            if menu and type(menu.onShowMenu)=="function" then menu:onShowMenu()
            else ui:handleEvent(Event:new("ShowMenu")) end
        end,debug.traceback)
        self._reader_native_menu_opening=false
        if not ok then
            logger.warn("[MiuRead][Reader] native menu open failed",tostring(err))
            self:info("KOReader 菜单暂时无法打开")
            return false
        end
        return true
    end,back_callback or function() self:show_reader_quick_panel(true) end)
end
function Plugin:_reader_power_device()
    if not Device:hasFrontlight() or type(Device.getPowerDevice)~="function" then return nil end
    local ok,powerd=pcall(Device.getPowerDevice,Device)
    if ok then return powerd end
    return nil
end

function Plugin:_reader_frontlight_value()
    local powerd=self:_reader_power_device()
    if not powerd then return nil end
    local current
    if type(powerd.frontlightIntensity)=="function" then
        local ok,value=pcall(powerd.frontlightIntensity,powerd)
        if ok then current=tonumber(value) end
    end
    return current or tonumber(powerd.fl_intensity or powerd.hw_intensity) or tonumber(powerd.fl_min) or 0
end

function Plugin:_reader_frontlight_bounds()
    local powerd=self:_reader_power_device()
    if not powerd then return 0,100 end
    local minimum=tonumber(powerd.fl_min) or 0
    local maximum=tonumber(powerd.fl_max) or 100
    if maximum<=minimum then maximum=minimum+100 end
    return minimum,maximum
end

function Plugin:_reader_frontlight_enabled()
    local powerd=self:_reader_power_device()
    if not powerd then return false end
    if type(powerd.isFrontlightOn)=="function" then
        local ok,value=pcall(powerd.isFrontlightOn,powerd)
        if ok then return value==true end
    end
    local minimum=self:_reader_frontlight_bounds()
    return (self:_reader_frontlight_value() or minimum)>minimum
end

function Plugin:_reader_set_frontlight(value)
    local listener=self:_koreader_device_listener()
    if not (listener and type(listener.onSetFlIntensity)=="function") then
        self:info("当前 KOReader 暂时无法调整前光")
        return false
    end
    local minimum,maximum=self:_reader_frontlight_bounds()
    local target=math.max(minimum,math.min(maximum,math.floor((tonumber(value) or minimum)+.5)))
    local ok,err=pcall(listener.onSetFlIntensity,listener,target)
    if not ok then
        logger.warn("[MiuRead][Frontlight] native intensity failed",tostring(err))
        self:info("前光调整失败")
        return false
    end
    return true
end

function Plugin:_reader_toggle_frontlight()
    local listener=self:_koreader_device_listener()
    if not (listener and type(listener.onToggleFrontlight)=="function") then
        self:info("当前 KOReader 暂时无法切换前光")
        return false
    end
    local ok,err=pcall(listener.onToggleFrontlight,listener)
    if not ok then
        logger.warn("[MiuRead][Frontlight] native toggle failed",tostring(err))
        self:info("前光切换失败")
        return false
    end
    return true
end

function Plugin:_reader_adjust_frontlight(delta)
    local minimum,maximum=self:_reader_frontlight_bounds()
    local current=self:_reader_frontlight_value() or minimum
    local stride=math.max(1,math.ceil((maximum-minimum+1)/25))
    return self:_reader_set_frontlight(current+(tonumber(delta) or 0)*stride)
end

function Plugin:_reader_warmth_state()
    local powerd=self:_reader_power_device()
    local has_natural=type(Device.hasNaturalLight)=="function" and Device:hasNaturalLight()
    if not (powerd and has_natural) then return nil end
    local minimum=tonumber(powerd.fl_warmth_min) or 0
    local maximum=tonumber(powerd.fl_warmth_max) or 100
    local value
    if type(powerd.frontlightWarmth)=="function" then
        local ok,current=pcall(powerd.frontlightWarmth,powerd)
        if ok then value=tonumber(current) end
    end
    value=value or tonumber(powerd.fl_warmth) or minimum
    if type(powerd.toNativeWarmth)=="function" then
        local ok,native=pcall(powerd.toNativeWarmth,powerd,value)
        if ok and tonumber(native) then value=tonumber(native) end
    end
    value=math.max(minimum,math.min(maximum,value))
    return {min=minimum,max=maximum,value=value}
end

function Plugin:_reader_set_warmth(value)
    local state=self:_reader_warmth_state()
    local listener=self:_koreader_device_listener()
    if not (state and listener and type(listener.onSetFlWarmth)=="function") then return false end
    local target=math.max(state.min,math.min(state.max,math.floor((tonumber(value) or state.value)+.5)))
    local ok,err=pcall(listener.onSetFlWarmth,listener,target)
    if not ok then
        logger.warn("[MiuRead][Frontlight] native warmth failed",tostring(err))
        return false
    end
    return true
end

function Plugin:_reader_adjust_warmth(delta)
    local state=self:_reader_warmth_state()
    if not state then return false end
    local stride=math.max(1,math.ceil((state.max-state.min+1)/25))
    return self:_reader_set_warmth(state.value+(tonumber(delta) or 0)*stride)
end

function Plugin:_show_frontlight_panel(options)
    options=type(options)=="table" and options or {}
    if not Device:hasFrontlight() then self:info("当前设备没有前光"); return false end
    local minimum,maximum=self:_reader_frontlight_bounds()
    local warmth=self:_reader_warmth_state()
    local dialog,err=ReaderFrontlightDialog.show{
        title="前光",
        placement=options.placement or "top",
        toggle=function()
            local enabled=self:_reader_frontlight_enabled()
            return {
                label="前光",
                value=enabled and "开" or "关",
                selected=enabled,
                callback=function() self:_reader_toggle_frontlight() end,
            }
        end,
        brightness=function()
            return {
                label="亮度",
                min=minimum,
                max=maximum,
                value=self:_reader_frontlight_value() or minimum,
                on_decrease=function() self:_reader_adjust_frontlight(-1) end,
                on_increase=function() self:_reader_adjust_frontlight(1) end,
                on_set=function(value)
                    if not self:_reader_set_frontlight(value) then return false end
                    return self:_reader_frontlight_value() or value
                end,
            }
        end,
        warmth=warmth and function()
            local current=self:_reader_warmth_state() or warmth
            return {
                label="色温",
                min=current.min,
                max=current.max,
                value=current.value,
                on_decrease=function() self:_reader_adjust_warmth(-1) end,
                on_increase=function() self:_reader_adjust_warmth(1) end,
                on_set=function(value)
                    if not self:_reader_set_warmth(value) then return false end
                    local state=self:_reader_warmth_state()
                    return state and state.value or value
                end,
            }
        end or nil,
        actions={
            {label="最低",callback=function() self:_reader_set_frontlight(math.min(maximum,minimum+1)) end},
            {
                label=function() return "夜间模式 · "..(self:_reader_night_enabled() and "开" or "关") end,
                selected=function() return self:_reader_night_enabled() end,
                callback=function() self:_home_toggle_night() end,
            },
            {label="最高",callback=function() self:_reader_set_frontlight(maximum) end},
        },
        on_back=options.on_back,
    }
    if not dialog then
        logger.warn("[MiuRead][ReaderFrontlight] custom dialog unavailable",tostring(err or "unknown"))
        return false
    end
    return true
end

function Plugin:_show_reader_frontlight_panel(back_callback)
    return self:_show_frontlight_panel{
        placement="top",
        on_back=back_callback or function() self:show_reader_quick_panel() end,
    }
end

function Plugin:_reader_footer()
    local ui=self.ui
    return ui and ui.view and ui.view.footer or (ui and ui.footer) or nil
end

function Plugin:_reader_footer_setting_label(key,inverted)
    local footer=self:_reader_footer()
    local settings=footer and footer.settings or nil
    if type(settings)~="table" then return "不可用" end
    local enabled=settings[key]==true
    if inverted then enabled=not (settings[key]==true) end
    return enabled and "已开启" or "已关闭"
end

function Plugin:_reader_refresh_footer()
    local footer=self:_reader_footer()
    if footer then
        if type(footer.updateFooterTextGenerator)=="function" then pcall(footer.updateFooterTextGenerator,footer) end
        if type(footer.refreshFooter)=="function" then pcall(footer.refreshFooter,footer,true,true) end
        if type(footer.updateFooter)=="function" then pcall(footer.updateFooter,footer,true) end
        if G_reader_settings and type(G_reader_settings.saveSetting)=="function" and type(footer.settings)=="table" then
            pcall(G_reader_settings.saveSetting,G_reader_settings,"footer",footer.settings)
        end
    end
    if self.ui and type(self.ui.handleEvent)=="function" then
        pcall(self.ui.handleEvent,self.ui,Event:new("UpdateFooter",true,true))
    end
    return true
end

function Plugin:_reader_toggle_footer_setting(key,inverted)
    local footer=self:_reader_footer()
    if not (footer and type(footer.settings)=="table") then
        self:info("当前文档暂时无法直接调整状态栏项目")
        return false
    end
    footer.settings[key]=not (footer.settings[key]==true)
    self:_reader_refresh_footer()
    return true
end

function Plugin:_reader_refresh_rate_label()
    local rate=tonumber(UIManager.FULL_REFRESH_COUNT)
    if not rate and type(UIManager.getRefreshRate)=="function" then
        local ok,value=pcall(UIManager.getRefreshRate,UIManager)
        if ok then rate=tonumber(value) end
    end
    if not rate then return "系统默认" end
    if rate==0 then return "从不" end
    if rate<0 then return "每章" end
    if rate<=1 then return "每页" end
    return "每 "..tostring(math.floor(rate+.5)).." 页"
end

function Plugin:_reader_refresh_rates()
    local day,night
    if type(UIManager.getRefreshRate)=="function" then
        local ok,a,b=pcall(UIManager.getRefreshRate,UIManager)
        if ok then day,night=tonumber(a),tonumber(b) end
    end
    if day==nil then day=tonumber(UIManager.FULL_REFRESH_COUNT) end
    if night==nil then night=day end
    return day,night
end

function Plugin:_reader_set_refresh_rates(day,night)
    if UIManager and type(UIManager.broadcastEvent)=="function" then
        UIManager:broadcastEvent(Event:new("SetRefreshRates",day,night))
        return true
    end
    return false
end

function Plugin:_reader_set_both_refresh_rates(rate)
    if UIManager and type(UIManager.broadcastEvent)=="function" then
        UIManager:broadcastEvent(Event:new("SetBothRefreshRates",rate))
        return true
    end
    return false
end

function Plugin:_reader_refresh_custom_values(index)
    index=math.max(1,math.min(3,math.floor(tonumber(index) or 1)))
    local key="refresh_rate_"..tostring(index)
    local defaults={12,22,99}
    local day=G_reader_settings and tonumber(G_reader_settings:readSetting(key)) or nil
    local night=G_reader_settings and tonumber(G_reader_settings:readSetting("night_"..key)) or nil
    day=day or defaults[index]
    night=night or day
    return day,night,key
end

function Plugin:_reader_edit_refresh_custom(index,back_callback)
    local day,night,key=self:_reader_refresh_custom_values(index)
    local ok,DoubleSpinWidget=pcall(require,"ui/widget/doublespinwidget")
    if not ok or not DoubleSpinWidget then self:info("当前 KOReader 暂时无法编辑自定义刷新频率"); return false end
    local widget
    widget=DoubleSpinWidget:new{
        title_text="自定义刷新 "..tostring(index),
        info_text="普通与夜间模式分别设置全刷间隔；-1 表示每章。",
        left_value=day,left_min=-1,left_max=200,left_step=1,left_hold_step=10,left_text="普通",
        right_value=night,right_min=-1,right_max=200,right_step=1,right_hold_step=10,right_text="夜间",
        ok_text="保存",
        callback=function(left,right)
            if G_reader_settings then
                G_reader_settings:saveSetting(key,left)
                G_reader_settings:saveSetting("night_"..key,right)
            end
            self:_reader_set_refresh_rates(left,right)
        end,
        close_callback=function() if back_callback then UIManager:scheduleIn(.05,back_callback) end end,
    }
    UIManager:show(widget)
    return true
end

function Plugin:_show_reader_refresh_settings(back_callback)
    local return_to_refresh=function() self:_show_reader_refresh_settings(back_callback) end
    ReaderSettingsDialog.show{
        title="刷新设置",
        subtitle=function()
            local day,night=self:_reader_refresh_rates()
            local function label(v)
                if v==nil then return "默认" end
                if v==0 then return "从不" end
                if v<0 then return "每章" end
                if v==1 then return "每页" end
                return "每 "..tostring(math.floor(v+.5)).." 页"
            end
            return "普通 "..label(day).." · 夜间 "..label(night)
        end,
        on_back=back_callback or function() self:_show_reader_page_display_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local day,night=self:_reader_refresh_rates()
            local rows={
                {label="从不全刷",value="0",checked=day==0 and night==0,keep_open=true,callback=function() self:_reader_set_both_refresh_rates(0) end},
                {label="每页",value="1",checked=day==1 and night==1,keep_open=true,callback=function() self:_reader_set_both_refresh_rates(1) end},
                {label="每 6 页",value="6",checked=day==6 and night==6,keep_open=true,callback=function() self:_reader_set_both_refresh_rates(6) end},
            }
            for index=1,3 do
                local d,n=self:_reader_refresh_custom_values(index)
                local i=index
                rows[#rows+1]={label="自定义 "..tostring(i),value=tostring(d).." / "..tostring(n),checked=day==d and night==n,callback=function()
                    self:_reader_edit_refresh_custom(i,return_to_refresh)
                end}
            end
            rows[#rows+1]={label="每章",value="-1",checked=day==-1 and night==-1,keep_open=true,callback=function() self:_reader_set_both_refresh_rates(-1) end}
            local chapter=G_reader_settings and G_reader_settings:isTrue("refresh_on_chapter_boundaries") or false
            local second=G_reader_settings and G_reader_settings:isTrue("no_refresh_on_second_chapter_page") or false
            local images=G_reader_settings and G_reader_settings:nilOrTrue("refresh_on_pages_with_images") or true
            return {
                {title="全刷频率",rows=rows},
                {title="附加规则",rows={
                    {label="章节开始始终全刷",value=chapter and "已开启" or "已关闭",keep_open=true,callback=function() UIManager:broadcastEvent(Event:new("ToggleFlashOnChapterBoundaries")) end},
                    {label="新章节第二页不全刷",value=second and "已开启" or "已关闭",keep_open=true,callback=function() UIManager:broadcastEvent(Event:new("ToggleNoFlashOnSecondChapterPage")) end},
                    {label="含图片页面始终全刷",value=images and "已开启" or "已关闭",keep_open=true,callback=function() UIManager:broadcastEvent(Event:new("ToggleFlashOnPagesWithImages")) end},
                    {label="立即全屏刷新",value="清除当前残影",callback=function() self:_home_full_refresh() end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_reader_cycle_refresh_rate()
    -- Kept for compatibility with old dispatcher callbacks. The visible entry
    -- now opens the complete KOReader-compatible refresh settings page.
    return self:_show_reader_refresh_settings()
end

function Plugin:_show_reader_page_display_panel(back_callback)
    ReaderSettingsDialog.show{
        title="页面显示",
        subtitle="阅读中的常用显示项目",
        on_back=back_callback or function() self:show_reader_quick_panel(true) end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local info_rows={
                {label="状态栏",value=self:_reader_status_bar_label(),value_bold=true,keep_open=true,callback=function() self:_reader_toggle_status_bar() end},
                {label="阅读进度条",value=self:_reader_footer_setting_label("disable_progress_bar",true),keep_open=true,callback=function() self:_reader_toggle_footer_setting("disable_progress_bar",true) end},
                {label="阅读百分比",value=self:_reader_footer_setting_label("percentage"),keep_open=true,callback=function() self:_reader_toggle_footer_setting("percentage") end},
                {label="当前时间",value=self:_reader_footer_setting_label("time"),keep_open=true,callback=function() self:_reader_toggle_footer_setting("time") end},
                {label="剩余时间",value=self:_reader_footer_setting_label("chapter_time_to_read"),keep_open=true,callback=function() self:_reader_toggle_footer_setting("chapter_time_to_read") end},
            }
            local has_battery=type(Device.hasBattery)~="function" or Device:hasBattery()
            if has_battery then
                info_rows[#info_rows+1]={label="电量",value=self:_reader_footer_setting_label("battery"),keep_open=true,callback=function() self:_reader_toggle_footer_setting("battery") end}
            end
            local behavior_rows={
                {label="刷新频率",value=self:_reader_refresh_rate_label(),value_bold=true,callback=function() self:_show_reader_refresh_settings(function() self:_show_reader_page_display_panel(back_callback) end) end},
                {label="全屏刷新",value="立即执行",callback=function() self:_home_full_refresh() end},
                {label="屏幕方向",value=self:_reader_rotation_label(),callback=function() self:_show_orientation_panel() end},
                {label="夜间模式",value=self:_reader_night_label(),keep_open=true,callback=function() self:_home_toggle_night() end},
            }
            if Device:hasFrontlight() then
                behavior_rows[#behavior_rows+1]={label="前光与色温",value=tostring(math.floor((self:_reader_frontlight_value() or 0)+.5)),callback=function()
                    self:_show_reader_frontlight_panel(function() self:_show_reader_page_display_panel(back_callback) end)
                end}
            end
            return {
                {title="页面信息",rows=info_rows},
                {title="页面行为",rows=behavior_rows},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_page_panel(back_callback)
    local return_to_page=function() self:_show_reader_page_panel(back_callback) end
    ReaderSettingsDialog.show{
        title="页面",
        subtitle="版面, 显示和刷新集中在这里",
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            return {
                {label="页边距",value=self:_reader_margin_label(),value_bold=true,callback=function() self:_show_reader_margin_panel(return_to_page) end},
                {label="页面显示",value="状态栏与阅读信息",callback=function() self:_show_reader_page_display_panel(return_to_page) end},
                {label="刷新与夜间",value=self:_reader_refresh_rate_label(),callback=function() self:_show_reader_refresh_panel(return_to_page) end},
            }
        end,
    }
    return true
end

function Plugin:_reader_recent_action_definitions()
    return {
        night={icon="☾",label="夜间模式",callback=function() self:_home_toggle_night() end},
        full_refresh={icon="↻",label="页面刷新",callback=function() self:_home_full_refresh() end},
        bookmark={icon="▯",label="书签",callback=function() self:_reader_show_bookmarks(function() self:show_reader_quick_panel() end) end},
        search={icon="⌕",label="全文搜索",callback=function() self:_reader_show_search(function() self:show_reader_quick_panel() end) end},
        frontlight={icon="☼",label="前光",enabled=Device:hasFrontlight(),callback=function() self:_show_reader_frontlight_panel() end},
        page_display={icon="▤",label="页面显示",callback=function() self:_show_reader_page_display_panel() end},
        current_book={icon="□",label="当前书籍",callback=function() self:_show_reader_current_book_panel(function() self:show_reader_quick_panel() end) end},
        downloads={icon="⇩",label="下载管理",callback=function() self:show_downloads(function() self:show_reader_quick_panel() end) end},
        rotation={icon=self:_orientation_icon_key(),label="屏幕方向",callback=function() self:_orientation_toggle_lock() end,hold_callback=function() self:_show_orientation_panel() end},
    }
end

function Plugin:_reader_recent_buttons()
    local reader=self:_reader_preferences()
    if reader.show_recent==false then return {} end
    local definitions=self:_reader_recent_action_definitions()
    local keys={}
    for _,key in ipairs(reader.recent_actions or {}) do
        if definitions[key] and definitions[key].enabled~=false then keys[#keys+1]=key end
        if #keys>=3 then break end
    end
    if #keys==0 then keys={"night","full_refresh","bookmark"} end
    local buttons={}
    for _,key in ipairs(keys) do
        local item_key=key
        local source=definitions[item_key]
        if source and source.enabled~=false then
            local action=source.callback
            buttons[#buttons+1]={
                icon=source.icon,
                label=source.label,
                callback=function()
                    self:_reader_record_recent_action(item_key)
                    return action()
                end,
            }
        end
    end
    return buttons
end

function Plugin:_reader_config_value(name)
    local configurable=self.ui and self.ui.document and self.ui.document.configurable or nil
    return configurable and configurable[name] or nil
end

function Plugin:_reader_emit_config(event,value,value2)
    local ui=self.ui
    if not (ui and type(ui.handleEvent)=="function") then return false end
    self:_mark_reader_busy(5)
    if value2~=nil then ui:handleEvent(Event:new(event,value,value2))
    else ui:handleEvent(Event:new(event,value)) end
    return true
end

function Plugin:_reader_default(name,fallback)
    if G_defaults and type(G_defaults.readSetting)=="function" then
        local ok,value=pcall(G_defaults.readSetting,G_defaults,name)
        if ok and value~=nil then return value end
    end
    return fallback
end

function Plugin:_reader_margin_label()
    local h=self:_reader_config_value("h_page_margins")
    local t=tonumber(self:_reader_config_value("t_page_margin"))
    local b=tonumber(self:_reader_config_value("b_page_margin"))
    local left,right
    if type(h)=="table" then left=tonumber(h[1]); right=tonumber(h[2]) end
    if left and right and t and b then
        return string.format("左右 %d/%d · 上下 %d/%d",left,right,t,b)
    end
    return "使用当前书籍设置"
end

function Plugin:_reader_apply_margin_preset(kind)
    local presets={
        compact={h=self:_reader_default("DCREREADER_CONFIG_H_MARGIN_SIZES_SMALL",{5,5}),t=self:_reader_default("DCREREADER_CONFIG_T_MARGIN_SIZES_SMALL",5),b=self:_reader_default("DCREREADER_CONFIG_B_MARGIN_SIZES_SMALL",5)},
        standard={h=self:_reader_default("DCREREADER_CONFIG_H_MARGIN_SIZES_MEDIUM",{10,10}),t=self:_reader_default("DCREREADER_CONFIG_T_MARGIN_SIZES_LARGE",15),b=self:_reader_default("DCREREADER_CONFIG_B_MARGIN_SIZES_LARGE",15)},
        wide={h=self:_reader_default("DCREREADER_CONFIG_H_MARGIN_SIZES_XX_LARGE",{30,30}),t=self:_reader_default("DCREREADER_CONFIG_T_MARGIN_SIZES_XX_LARGE",30),b=self:_reader_default("DCREREADER_CONFIG_B_MARGIN_SIZES_XX_LARGE",30)},
    }
    local preset=presets[kind] or presets.standard
    self:_reader_emit_config("SetPageHorizMargins",preset.h)
    self:_reader_emit_config("SetPageTopMargin",preset.t)
    self:_reader_emit_config("SetPageBottomMargin",preset.b)
    return true
end

function Plugin:_reader_adjust_horizontal_margin(delta)
    local h=self:_reader_config_value("h_page_margins")
    local left,right=10,10
    if type(h)=="table" then left=tonumber(h[1]) or left; right=tonumber(h[2]) or right end
    delta=tonumber(delta) or 0
    return self:_reader_emit_config("SetPageHorizMargins",{math.max(0,math.min(140,left+delta)),math.max(0,math.min(140,right+delta))})
end

function Plugin:_reader_adjust_vertical_margin(delta)
    local t=tonumber(self:_reader_config_value("t_page_margin")) or 15
    local b=tonumber(self:_reader_config_value("b_page_margin")) or 15
    delta=tonumber(delta) or 0
    self:_reader_emit_config("SetPageTopMargin",math.max(0,math.min(140,t+delta)))
    self:_reader_emit_config("SetPageBottomMargin",math.max(0,math.min(140,b+delta)))
    return true
end

function Plugin:_show_reader_margin_panel(back_callback)
    local return_here=function() self:_show_reader_margin_panel(back_callback) end
    ReaderSettingsDialog.show{
        title="页边距",
        subtitle=function() return self:_reader_margin_label() end,
        on_back=back_callback or function() self:show_reader_control_center("typeset") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            return {
                {title="常用预设",rows={
                    {label="紧凑",value="更多正文空间",keep_open=true,callback=function() self:_reader_apply_margin_preset("compact") end},
                    {label="标准",value="推荐",value_bold=true,keep_open=true,callback=function() self:_reader_apply_margin_preset("standard") end},
                    {label="宽松",value="更大留白",keep_open=true,callback=function() self:_reader_apply_margin_preset("wide") end},
                }},
                {title="精细调整",rows={
                    {label="左右边距 -5",value="缩小",keep_open=true,callback=function() self:_reader_adjust_horizontal_margin(-5) end},
                    {label="左右边距 +5",value="增大",keep_open=true,callback=function() self:_reader_adjust_horizontal_margin(5) end},
                    {label="上下边距 -5",value="缩小",keep_open=true,callback=function() self:_reader_adjust_vertical_margin(-5) end},
                    {label="上下边距 +5",value="增大",keep_open=true,callback=function() self:_reader_adjust_vertical_margin(5) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_reader_word_spacing_value()
    local value=self:_reader_config_value("word_spacing")
    if type(value)=="table" then return tonumber(value[1]) or 100,tonumber(value[2]) or 75 end
    return 100,75
end

function Plugin:_reader_word_spacing_label()
    local scaling,reduction=self:_reader_word_spacing_value()
    return tostring(math.floor(scaling+.5)).."% / "..tostring(math.floor(reduction+.5)).."%"
end

function Plugin:_reader_set_word_spacing(kind)
    local presets={
        small=self:_reader_default("DCREREADER_CONFIG_WORD_SPACING_SMALL",{90,75}),
        medium=self:_reader_default("DCREREADER_CONFIG_WORD_SPACING_MEDIUM",{100,75}),
        large=self:_reader_default("DCREREADER_CONFIG_WORD_SPACING_LARGE",{110,75}),
    }
    return self:_reader_emit_config("SetWordSpacing",presets[kind] or presets.medium)
end

function Plugin:_reader_adjust_cjk_width(delta)
    local current=tonumber(self:_reader_config_value("cjk_width_scaling")) or 100
    local target=math.max(100,math.min(150,current+(tonumber(delta) or 0)))
    return self:_reader_emit_config("SetCJKWidthScaling",target)
end

function Plugin:_show_reader_word_spacing_panel(back_callback)
    ReaderSettingsDialog.show{
        title="字符间距（高级）",
        subtitle=function() return "空格缩放/压缩 "..self:_reader_word_spacing_label() end,
        on_back=back_callback or function() self:show_reader_control_center("typeset") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local cjk=tonumber(self:_reader_config_value("cjk_width_scaling")) or 100
            return {
                {title="空格",rows={
                    {label="紧凑",value="小",keep_open=true,callback=function() self:_reader_set_word_spacing("small") end},
                    {label="标准",value="推荐",value_bold=true,keep_open=true,callback=function() self:_reader_set_word_spacing("medium") end},
                    {label="宽松",value="大",keep_open=true,callback=function() self:_reader_set_word_spacing("large") end},
                }},
                {title="中文字符宽度",rows={
                    {label="当前宽度",value=tostring(math.floor(cjk+.5)).."%",value_bold=true,arrow=false},
                    {label="字符宽度 -5",value="缩小",keep_open=true,callback=function() self:_reader_adjust_cjk_width(-5) end},
                    {label="字符宽度 +5",value="增大",keep_open=true,callback=function() self:_reader_adjust_cjk_width(5) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_refresh_panel(back_callback)
    ReaderSettingsDialog.show{
        title="刷新与显示",
        subtitle="只保留阅读过程中真正需要的显示控制",
        on_back=back_callback or function() self:show_reader_control_center("typeset") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            return {
                {label="刷新频率",value=self:_reader_refresh_rate_label(),value_bold=true,callback=function() self:_show_reader_refresh_settings(function() self:_show_reader_refresh_panel(back_callback) end) end},
                {label="全屏刷新",value="立即执行",callback=function() self:_home_full_refresh() end},
                {label="夜间模式",value=self:_reader_night_label(),keep_open=true,callback=function() self:_home_toggle_night() end},
                {label="页面显示",value="状态栏与阅读信息",callback=function() self:_show_reader_page_display_panel(function() self:_show_reader_refresh_panel(back_callback) end) end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_advanced_typeset_panel(back_callback)
    ReaderSettingsDialog.show{
        title="高级排版",
        subtitle="常用高级选项仍由觅阅直接提供, 不进入 KOReader 总菜单",
        on_back=back_callback or function() self:show_reader_control_center("typeset") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            local mode=tonumber(self:_reader_config_value("block_rendering_mode")) or 2
            local mode_labels={[0]="兼容",[1]="平面",[2]="书籍",[3]="网页"}
            return {
                {label="渲染模式",value=mode_labels[mode] or tostring(mode),value_bold=true,keep_open=true,callback=function()
                    self:_reader_emit_config("SetBlockRenderingMode",(mode+1)%4)
                end},
                {label="字符间距（高级）",value=self:_reader_word_spacing_label(),callback=function() self:_show_reader_word_spacing_panel(function() self:_show_reader_advanced_typeset_panel(back_callback) end) end},
                {label="页边距",value=self:_reader_margin_label(),callback=function() self:_show_reader_margin_panel(function() self:_show_reader_advanced_typeset_panel(back_callback) end) end},
                {label="页面显示",value="状态栏、进度与刷新",callback=function() self:_show_reader_page_display_panel(function() self:_show_reader_advanced_typeset_panel(back_callback) end) end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_wifi_quick_panel(back_callback)
    ReaderSettingsDialog.show{
        title="Wi-Fi",
        subtitle=function()
            local label=self:_reader_wifi_summary()
            return tostring(label)
        end,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            local on=self:_reader_wifi_state()==true
            return {
                {label="Wi-Fi",value=on and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function() self:_reader_wifi_toggle() end},
                {label="选择网络",value="打开网络列表",callback=function() self:_reader_wifi_settings(back_callback or function() self:show_reader_quick_panel() end) end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_gesture_panel(back_callback)
    ReaderSettingsDialog.show{
        title="手势与按键",
        subtitle="桌面模式只接管顶部下滑阅读面板, 正文阅读手势继续交给阅读器",
        on_back=back_callback or function() self:show_reader_control_center("device") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            return {
                {label="顶部下滑",value="觅阅阅读快捷面板",arrow=false},
                {label="向上滑动",value="收起快捷面板",arrow=false},
                {label="正文区域",value="保持翻页与选词手势",arrow=false},
                {label="想法",value=self:_thoughts_enabled_label(),keep_open=true,callback=function() self:_toggle_thoughts_enabled() end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_device_compat_panel(back_callback)
    ReaderSettingsDialog.show{
        title="系统与兼容",
        subtitle="日常阅读不需要进入 KOReader 原菜单",
        on_back=back_callback or function() self:show_reader_control_center("device") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            return {
                {label="KOReader 原生菜单",value="仅用于未覆盖功能与故障排查",callback=function()
                    self:_show_koreader_reader_menu(function() self:_show_reader_device_compat_panel(back_callback) end)
                end},
                {label="觅阅阅读界面设置",value="评论与控制中心",callback=function()
                    self:_show_reader_menu_table("阅读界面",self:reader_quick_panel_settings_menu(),function() self:_show_reader_device_compat_panel(back_callback) end)
                end},
            }
        end,
    }
    return true
end

function Plugin:_reader_control_categories()
    local function back_to(key) return function() self:show_reader_control_center(key) end end
    return {
        {key="reading",label="阅读",sections={{items={
            {icon="toc",label="目录",value="当前章节",callback=function() self:_show_reader_toc(back_to("reading")) end},
            {icon="progress",label="阅读进度",value=(self:_reader_progress_percent() and (tostring(math.floor(self:_reader_progress_percent()+.5)).."%") or ""),callback=function() self:_show_reader_progress_control(back_to("reading")) end},
            {icon="search",label="书内搜索",value="搜索当前书籍",callback=function() self:_reader_show_search(back_to("reading")) end},
            {icon="undo",label="回到阅读处",value="返回跳转前位置",callback=function() self:_reader_go_back_location() end},
            {icon="highlight",label="批注",value=self:_reader_annotation_summary_label(),callback=function() self:_show_reader_annotation_panel(back_to("reading")) end},
            {icon="comment",label="想法",value=self:_thoughts_enabled_label(),value_bold=true,callback=function() self:_show_reader_comment_settings(back_to("reading")) end},
            {icon="thought",label="本章想法",value="划线与想法",callback=function() self:_show_reader_chapter_thoughts(back_to("reading")) end},
        }}}},
        {key="typeset",label="排版",sections={{items={
            {icon="font",label="字体与字号",value=self:_reader_font_label().." · "..self:_reader_font_size_label(),callback=function() self:_show_reader_font_panel(back_to("typeset")) end},
            {icon="line-spacing",label="行距",value=tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%",callback=function() self:_show_reader_spacing_panel(back_to("typeset")) end},
            {icon="display",label="页面",value="页边距与阅读信息",callback=function() self:_show_reader_page_panel(back_to("typeset")) end},
            {icon="settings",label="高级排版",value="字符间距与更多版式",callback=function() self:_show_reader_advanced_typeset_panel(back_to("typeset")) end},
        }}}},
        {key="book",label="书籍",sections={{items={
            {icon="current-book",label="当前书籍",value="信息与本地状态",callback=function() self:_show_reader_current_book_panel(back_to("book")) end},
            {icon="download",label="下载与生成",value="任务、失败重试与重新生成",callback=function() self:show_downloads(back_to("book")) end},
            {icon="comment",label="评论数据",value="迁移与显示设置",callback=function()
                self:_show_reader_menu_table("评论数据",self:book_repair_settings_menu(),back_to("book"))
            end},
            {icon="repair",label="检查与修复",value="书籍与阅读同步",callback=function() self:check_and_repair_current() end},
        }}}},
        {key="device",label="设备",sections={{items={
            {icon="frontlight",label="前光与色温",value=Device:hasFrontlight() and "直接调节" or "当前设备不支持",enabled=Device:hasFrontlight(),callback=function() self:_show_reader_frontlight_panel(back_to("device")) end},
            {icon="wifi",label="Wi-Fi",value=(self:_reader_wifi_summary()),callback=function() self:_show_reader_wifi_quick_panel(back_to("device")) end},
            {icon=self:_orientation_icon_key(),label="屏幕方向",value=self:_reader_rotation_label(),callback=function() self:_show_orientation_panel() end},
            {icon="screenshot",label="截图",value="截取当前屏幕",callback=function() ScreenshotMode.start(self) end},
            {icon="full-refresh",label="全屏刷新",value="清除残影",callback=function() self:_home_full_refresh() end},
            {icon="sleep",label="休眠",value="立即休眠",enabled=Device:canSuspend(),callback=function() self:_home_sleep() end},
            {icon="settings",label="阅读界面设置",value="评论与快捷控制",callback=function() self:_show_reader_menu_table("阅读界面",self:reader_quick_panel_settings_menu(),back_to("device")) end},
            {icon="tools",label="手势与按键",value="阅读手势说明",callback=function() self:_show_reader_gesture_panel(back_to("device")) end},
            {icon="settings",label="系统与兼容",value="高级与故障排查",callback=function() self:_show_reader_device_compat_panel(back_to("device")) end},
        }}}},
    }
end

function Plugin:show_reader_control_center(initial_category)
    if not (self.ui and self.ui.document) then return false end
    self:_mark_reader_busy(8)
    local panel,err=ReaderControlCenter.show{
        title="全部阅读功能",
        categories=self:_reader_control_categories(),
        initial_category=tostring(initial_category or "reading"),
        on_back=function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
    }
    if not panel then
        logger.warn("[MiuRead][ReaderControlCenter] unavailable",tostring(err or "unknown"))
        return false
    end
    return true
end

function Plugin:_show_reader_edge_guard_panel(back_callback)
    ReaderSettingsDialog.show{
        title="边缘翻页防误触",
        subtitle="左右边缘点击优先翻页，避免划线评论抢占翻页操作",
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local enabled,percent=self:_reader_edge_guard_state()
            local rows={
                {label="边缘翻页防误触",value=enabled and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function()
                    self:_reader_toggle_edge_guard()
                end},
            }
            local range_rows={}
            for _,value in ipairs({5,10,15,20}) do
                local selected=value
                range_rows[#range_rows+1]={
                    label=tostring(selected).."%",
                    value=selected==10 and "推荐" or "左右各占屏幕宽度",
                    value_bold=percent==selected,
                    checked=percent==selected,
                    enabled=enabled,
                    keep_open=true,
                    callback=function() self:_reader_set_edge_guard_percent(selected) end,
                }
            end
            return {
                {title="状态",rows=rows},
                {title="保护范围",rows=range_rows},
            }
        end,
    }
    return true
end

function Plugin:_reader_quick_definitions()
    local edge_enabled=self:_reader_edge_guard_state()
    return {
        more={key="more",icon="menu",label="更多",callback=function() self:show_reader_more_panel() end},
        toc={key="toc",icon="toc",label="目录",callback=function() self:_show_reader_toc(function() self:show_reader_quick_panel() end) end},
        progress={key="progress",icon="progress",label="进度",callback=function() self:_show_reader_progress_control(function() self:show_reader_quick_panel() end) end},
        search={key="search",icon="search",label="搜索",icon_scale=.94,callback=function() self:_reader_show_search(function() self:show_reader_quick_panel() end) end},
        back={key="back",icon="undo",label="回到阅读",icon_scale=.98,callback=function() self:_reader_go_back_location() end},
        font={key="font",icon="font",label="字体",callback=function() self:_show_reader_font_panel(function() self:show_reader_quick_panel() end) end},
        spacing={key="spacing",icon="line-spacing",label="行距",callback=function() self:_show_reader_spacing_panel(function() self:show_reader_quick_panel() end) end},
        page={key="page",icon="display",label="页面",callback=function() self:_show_reader_page_panel(function() self:show_reader_quick_panel() end) end},
        comments={key="comments",icon="comment",label="想法",icon_scale=1.16,icon_nudge_y=-1,active=self:_thoughts_enabled(),callback=function()
            self:_show_reader_comment_settings(function() self:show_reader_quick_panel() end)
        end,hold_callback=function()
            self:_toggle_thoughts_enabled()
            UIManager:scheduleIn(.05,function() self:show_reader_quick_panel() end)
        end},
        annotations={key="annotations",icon="highlight",label="批注",icon_scale=1.28,icon_nudge_y=-2,callback=function() self:_show_reader_annotation_panel(function() self:show_reader_quick_panel() end) end},
        toggle_annotations={key="toggle_annotations",icon="highlight",label="显隐划线",icon_scale=1.12,active=self:_external_annotations_visible(),callback=function()
            self:toggle_external_annotations()
            UIManager:scheduleIn(.05,function() self:show_reader_quick_panel() end)
        end},
        nearest_annotation={key="nearest_annotation",icon="locate",label="最近批注",icon_scale=1.04,active=self:_external_annotations_visible(),callback=function()
            self:_show_nearest_external_annotation()
        end},
        edge_guard={key="edge_guard",icon=edge_enabled and "edge-guard" or "edge-guard-off",label="防误触",icon_scale=1.02,active=edge_enabled,callback=function()
            self:_show_reader_edge_guard_panel(function() self:show_reader_quick_panel() end)
        end},
    }
end

function Plugin:show_reader_more_panel()
    return self:show_reader_control_center("reading")
end

function Plugin:_reader_quick_panel_options()
    if not (self.ui and self.ui.document) then return nil end
    local started=os.clock()
    local title_started=os.clock()
    local title=self:_reader_toolbar_title()
    local title_ms=math.floor((os.clock()-title_started)*1000+.5)
    local header=self:_reader_toolbar_header(title)
    local reader=self:_reader_preferences()
    local definitions=self:_reader_quick_definitions()

    local actions=self:_reader_quick_actions(definitions,reader)

    local typeset={
        font={
            label="字体",value=self:_reader_font_size_label(),
            callback=function() self:_show_reader_font_panel(function() self:show_reader_quick_panel() end) end,
            on_decrease=function()
                if self:_reader_adjust_font_size(-1) then return self:_reader_font_size_label() end
                return false
            end,
            on_increase=function()
                if self:_reader_adjust_font_size(1) then return self:_reader_font_size_label() end
                return false
            end,
        },
        spacing={
            label="行距",value=tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%",
            callback=function() self:_show_reader_spacing_panel(function() self:show_reader_quick_panel() end) end,
            on_decrease=function()
                if self:_reader_adjust_line_spacing(-5) then return tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%" end
                return false
            end,
            on_increase=function()
                if self:_reader_adjust_line_spacing(5) then return tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%" end
                return false
            end,
        },
        page={label="页面",callback=function() self:_show_reader_page_panel(function() self:show_reader_quick_panel() end) end},
    }

    local frontlight
    local warmth
    if Device:hasFrontlight() then
        local minimum,maximum=self:_reader_frontlight_bounds()
        frontlight={
            icon="frontlight",label="前光",min=minimum,max=maximum,value=self:_reader_frontlight_value() or minimum,
            on_set=function(value)
                if not self:_reader_set_frontlight(value) then return false end
                return self:_reader_frontlight_value() or value
            end,
            on_decrease=function()
                if not self:_reader_adjust_frontlight(-1) then return false end
                return self:_reader_frontlight_value() or minimum
            end,
            on_increase=function()
                if not self:_reader_adjust_frontlight(1) then return false end
                return self:_reader_frontlight_value() or minimum
            end,
        }
        local state=self:_reader_warmth_state()
        if state then
            warmth={
                icon="warmth",label="色温",min=state.min,max=state.max,value=state.value,
                on_set=function(value)
                    if not self:_reader_set_warmth(value) then return false end
                    local current=self:_reader_warmth_state()
                    return current and current.value or value
                end,
                on_decrease=function()
                    if not self:_reader_adjust_warmth(-1) then return false end
                    local current=self:_reader_warmth_state()
                    return current and current.value or state.value
                end,
                on_increase=function()
                    if not self:_reader_adjust_warmth(1) then return false end
                    local current=self:_reader_warmth_state()
                    return current and current.value or state.value
                end,
            }
        end
    end

    local device_actions={
        {icon="night",label="夜间模式",active=self:_reader_night_enabled(),callback=function() self:_home_toggle_night() end},
        {icon=self:_orientation_icon_key(),label="方向锁定",active=Orientation.is_session_locked(),callback=function() self:_orientation_toggle_lock() end,hold_callback=function() self:_show_orientation_panel() end},
        {icon="screenshot",label="截图",callback=function() ScreenshotMode.start(self) end},
        {icon="full-refresh",label="全屏刷新",callback=function() self:_home_full_refresh(true) end},
        {icon="menu",label="KO菜单",callback=function() self:_show_koreader_reader_menu() end},
    }

    self._reader_toolbar_options_perf={
        title_ms=title_ms,
        options_ms=math.floor((os.clock()-started)*1000+.5),
    }
    return {
        header=header,
        actions=actions,
        typeset=typeset,
        frontlight=frontlight,
        warmth=warmth,
        device_actions=device_actions,
    }
end

function Plugin:_schedule_reader_toolbar_prewarm(_session,_delay)
    -- beta.18 avoids building reader UI in the background. The toolbar is
    -- created fresh on demand so an idle prewarm cannot contend with paging.
    if self._reader_toolbar_prewarm_task then
        UIManager:unschedule(self._reader_toolbar_prewarm_task)
        self._reader_toolbar_prewarm_task=nil
    end
    return false
end

function Plugin:_maybe_show_selection_menu_hint()
    if self:_selection_menu_enabled() then return end
    -- Safe read: this runs inside the direct-highlight wrapper, which tests
    -- drive with a stub plugin that has no store.
    local ok, reader, preferences = pcall(function() return self:_reader_preferences() end)
    if not ok or type(reader) ~= "table" then return end
    if reader.selection_menu_hint_shown == true then return end
    reader.selection_menu_hint_shown = true
    self:_save_reader_preferences(reader, preferences)
    self:toast("选词直接划线；如需复制/查词，可在 阅读界面设置 开启「选词后显示选择菜单」", 4)
end

function Plugin:_maybe_show_reader_quick_panel_hint()
    if self._reader_quick_panel_hint_shown==true then return false end
    self._reader_quick_panel_hint_shown=true
    local reader,preferences=self:_reader_preferences()
    if reader.quick_panel_hint_shown==true then return false end
    reader.quick_panel_hint_shown=true
    self:_save_reader_preferences(reader,preferences)
    self:toast("长按快捷按键可排序、隐藏、替换或恢复",3)
    return true
end

function Plugin:_show_reader_quick_panel_now()
    if not (self.ui and self.ui.document) then return false end
    local started=monotonic_wall_time()
    self:_mark_reader_busy(2)
    local options=self:_reader_quick_panel_options()
    local options_done=monotonic_wall_time()
    if not options then return false end
    local panel,err=ReaderToolbar.show(options,tostring(home_session().reader_session_generation or 0))
    local shown=monotonic_wall_time()
    if not panel then
        logger.warn("[MiuRead][ReaderToolbar] unavailable",tostring(err or "unknown"))
        return false
    end
    self:_maybe_show_reader_quick_panel_hint()
    local header_perf=self._reader_toolbar_header_perf or {}
    local options_perf=self._reader_toolbar_options_perf or {}
    local total_ms=math.floor((shown-started)*1000+.5)
    logger.info("[MiuRead][ReaderToolbarPerf]",
        "title_ms=",tostring(options_perf.title_ms or 0),
        "device_ms=",tostring(header_perf.device_ms or 0),
        "state_ms=",tostring(header_perf.state_ms or 0),
        "options_ms=",tostring(math.floor((options_done-started)*1000+.5)),
        "show_ms=",tostring(math.floor((shown-options_done)*1000+.5)),
        "cache_age_s=",tostring(header_perf.cache_age or 0),
        "chapter_cached=",tostring(header_perf.chapter_cached==true),
        "total_ms=",tostring(total_ms))
    self:_record_performance("reader_toolbar",total_ms)
    return true
end

function Plugin:show_reader_quick_panel()
    -- UiScale is already applied when preferences are loaded/saved. Re-reading
    -- and normalizing the whole home preference tree on every swipe needlessly
    -- adds work to the most latency-sensitive reader gesture.
    if not (self.ui and self.ui.document) then return false end
    -- Only the visible downward-swipe path publishes a short shared busy marker
    -- for the read-report subprocess. Page turns themselves stay memory-only.
    self:_mark_reader_busy(2,true)
    if self._reader_quick_panel_pending==true then return true end
    self._reader_quick_panel_pending=true
    UIManager:nextTick(function()
        self._reader_quick_panel_pending=false
        if self.ui and self.ui.document then self:_show_reader_quick_panel_now() end
    end)
    return true
end

function Plugin:_close_miuread_transients()
    HomeQuickPanel.close()
    ReaderToolbar.close()
    ReaderListDialog.close()
    ReaderControlCenter.close()
    ReaderProgressDialog.close()
    ReaderSettingsDialog.close()
    ReaderTocDialog.close()
    ReaderFrontlightDialog.close()
    local pending={}
    for index=#(UIManager._window_stack or {}),1,-1 do
        local window=UIManager._window_stack[index]
        local widget=window and window.widget or nil
        if widget and widget~=HomeView.current() and widget._miuread_transient==true
            and widget._miuread_recovery_surface~=true and UIManager:isWidgetShown(widget) then
            pending[#pending+1]=widget
        end
    end
    for _,widget in ipairs(pending) do pcall(function() UIManager:close(widget) end) end
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

M.QUICK_ACTION_MAX = READER_QUICK_ACTION_MAX

M.migrate_quick_actions = migrate_quick_actions
M.highlight_selection_policy = HighlightPolicy.policy
M.STYLES = HighlightPolicy.STYLES
M.style_label = HighlightPolicy.style_label
M.is_style = HighlightPolicy.is_style

-- Pure: the default visible quick-action order (WeRead five groups lead).
M.QUICK_DEFAULT_VISIBLE = function()
    local order = {}
    for _, key in ipairs(READER_QUICK_ACTION_ORDER) do
        if READER_QUICK_ACTION_DEFAULT[key] == true then
            order[#order + 1] = key
        end
    end
    return order
end

return M
