-- MiuRead home customization controller, split from main.lua.
local Device = require("device")
local UIManager = require("ui/uimanager")
local U = require("miuread.util")
local Text = require("miuread.text")
local HomeView = require("miuread.home_view")
local HomeLayouts = require("miuread.home_layout_constants")
local GestureBridge = require("miuread.gesture_bridge")
local RawButtonDialog = require("ui/widget/buttondialog")

local HOME_ACTION_ITEM_ORDER = HomeLayouts.HOME_ACTION_ITEM_ORDER
local HOME_ACTION_ITEM_DEFAULT = HomeLayouts.HOME_ACTION_ITEM_DEFAULT
local HOME_ACTION_LAYOUT_VERSION = HomeLayouts.HOME_ACTION_LAYOUT_VERSION
local HOME_PANEL_ITEM_ORDER = HomeLayouts.HOME_PANEL_ITEM_ORDER
local HOME_PANEL_ITEM_DEFAULT = HomeLayouts.HOME_PANEL_ITEM_DEFAULT
local HOME_PANEL_LAYOUT_VERSION = HomeLayouts.HOME_PANEL_LAYOUT_VERSION
local HOME_SECTION_ORDER = HomeLayouts.HOME_SECTION_ORDER

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ButtonDialog = gesture_aware_class(RawButtonDialog, {_miuread_transient=true, _miuread_modal_surface=true})

local _ = Text.tr

local Plugin = {}

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

local HOME_SOURCE_LABELS = HomeLayouts.HOME_SOURCE_LABELS

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

local HOME_SOURCE_LABELS = HomeLayouts.HOME_SOURCE_LABELS
local HOME_ACTION_LABELS = HomeLayouts.HOME_ACTION_LABELS
local HOME_PANEL_LABELS = HomeLayouts.HOME_PANEL_LABELS

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



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
