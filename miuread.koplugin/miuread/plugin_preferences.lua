-- MiuRead settings / preferences controller, split from main.lua.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local U = require("miuread.util")
local Text = require("miuread.text")
local Lazy = require("miuread.lazy")
local HomeView = Lazy("miuread.home_view")
local LocalLibrary = Lazy("miuread.local_library")
local PluginSettings = require("miuread.plugin_settings")
local PluginReader = require("miuread.plugin_reader")
local TimeZone = require("miuread.timezone")
local GestureBridge = require("miuread.gesture_bridge")
local RawButtonDialog = require("ui/widget/buttondialog")
local RawConfirmBox = require("ui/widget/confirmbox")
local RawInputDialog = require("ui/widget/inputdialog")
local RawPathChooser = require("ui/widget/pathchooser")

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ButtonDialog = gesture_aware_class(RawButtonDialog, {_miuread_transient=true, _miuread_modal_surface=true})
local ConfirmBox = gesture_aware_class(RawConfirmBox, {_miuread_transient=true, _miuread_modal_surface=true})
local InputDialog = gesture_aware_class(RawInputDialog, {_miuread_transient=true, _miuread_modal_surface=true})
local PathChooser = gesture_aware_class(RawPathChooser, {_miuread_transient=true, _miuread_modal_surface=true})

local _ = Text.tr

-- Bridges to the shared home session owned by miuread.session_state.
local Session = require("miuread.session_state")
local function home_session() return Session.home() end
local function home_exiting() return Session.home_exiting() end
local function reader_close_active() return Session.reader_close_active() end

-- Mirrors main.lua's HOME_ACTION_ITEM_ORDER; main.lua owns the home surface
-- and keeps the authoritative copy for its own home menu code.
local HOME_ACTION_ITEM_ORDER={"refresh","search","downloads","sync","sleep","miuread_settings","all_books","history","file_manager","screenshot"}

local Plugin = {}

function Plugin:_toggle_preference(key)
    local p=self.store:preferences(); p[key]=not p[key]; self.store:save_preferences(p)
end




function Plugin:_thought_display_label()
    return self:_thoughts_enabled() and ("已开启 · "..self:_thought_font_size_label()) or "已关闭"
end

function Plugin:_toggle_home_network_metadata()
    local home,preferences=self:_home_preferences()
    home.network_metadata=home.network_metadata==false
    home.network_metadata_user_set=true
    home.network_metadata_defaults_version=2
    self:_save_home_preferences(home,preferences)
    if home.network_metadata and self._home_hero then
        self:_home_schedule_network_metadata(self._home_hero,true,true,nil,true)
    end
    self:toast(home.network_metadata and "已开启网络补全图书信息" or "已关闭网络补全图书信息",2)
end

function Plugin:_local_root_index(path)
    path=LocalLibrary.normalize(path)
    local home,preferences=self:_home_preferences()
    for index,root in ipairs(home.local_roots or {}) do
        if LocalLibrary.normalize(root.path)==path then return index,root,home,preferences end
    end
    return nil,nil,home,preferences
end

function Plugin:_save_local_roots(home,preferences)
    home.local_root=(home.local_roots and home.local_roots[1] and home.local_roots[1].path) or ""
    local enabled={}
    for _,root in ipairs(home.local_roots or {}) do if root.enabled~=false then enabled[#enabled+1]=root end end
    local current=LocalLibrary.normalize(home.local_inline_path or "")
    local matched=self:_home_local_root_for_path(current,enabled)
    if not matched then
        if #enabled==1 then home.local_inline_path=enabled[1].path; home.local_inline_root=enabled[1].path
        else home.local_inline_path=""; home.local_inline_root="" end
    end
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_notify_home_data_changed("content") end
end

function Plugin:_validate_local_root(path)
    path=LocalLibrary.normalize(path)
    if path=="" or path:sub(1,1)~="/" then return nil,"路径无效" end
    if path=="/" or path=="/mnt" or path=="/mnt/us" then return nil,"请选择实际存放书籍的子文件夹" end
    if lfs.attributes(path,"mode")~="directory" then return nil,"文件夹不存在" end
    for _,root in ipairs(self:_home_local_roots(false)) do
        local existing=LocalLibrary.normalize(root.path)
        if existing==path then return nil,"这个目录已经添加" end
        if path:sub(1,#existing+1)==existing.."/" or existing:sub(1,#path+1)==path.."/" then
            return nil,"这个目录与现有书库目录重叠"
        end
    end
    return true,path
end

function Plugin:_add_local_root_path(path)
    local ok,normalized_or_error=self:_validate_local_root(path)
    if not ok then self:info("无法添加此目录：\n"..tostring(normalized_or_error)); return false end
    path=normalized_or_error
    local function save()
        local home,preferences=self:_home_preferences()
        home.local_roots=type(home.local_roots)=="table" and home.local_roots or {}
        home.local_roots[#home.local_roots+1]={path=path,name=LocalLibrary.basename(path),enabled=true,readonly=true}
        self:_save_local_roots(home,preferences)
        self:toast("已添加本地书库目录",2)
        if home.local_library_mode=="direct" then
            self:_home_refresh_local_directory(path,function()
                if HomeView.is_shown() then self:_notify_home_data_changed("content") end
            end,true)
        elseif home.local_library_mode=="auto" then
            UIManager:scheduleIn(.35,function() self:_home_scan_local(true) end)
        end
    end
    if path=="/mnt/us/documents" or path=="/mnt/onboard" then
        local dialog
        dialog=ConfirmBox:new{
            text=(self:_home_preferences().local_library_mode=="direct"
                and "这个目录可能包含很多文件。文件夹浏览只读取当前层，但仍建议选择实际存放书籍的子文件夹。"
                or "这个目录可能包含很多文件。建立书库索引时耗时会更长，更建议选择实际存放书籍的子文件夹。"),
            ok_text="仍然添加",ok_callback=function() UIManager:close(dialog); save() end,
        }
        UIManager:show(dialog)
        return true
    end
    save(); return true
end

function Plugin:add_local_root_dialog()
    local current="/mnt/us/documents"
    if lfs.attributes(current,"mode")~="directory" then
        current=lfs.attributes("/mnt/onboard","mode")=="directory" and "/mnt/onboard" or "/mnt/us"
    end
    local chooser=PathChooser:new{
        title="选择本地书库目录",select_directory=true,select_file=false,show_files=false,path=current,
        onConfirm=function(path) self:_add_local_root_path(path) end,
    }
    UIManager:show(chooser)
end

function Plugin:rename_local_root(path)
    local index,root,home,preferences=self:_local_root_index(path)
    if not index then return end
    local dialog
    dialog=InputDialog:new{
        title="书库显示名称",input=tostring(root.name or LocalLibrary.basename(path)),
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(dialog) end},
            {text="保存",is_enter_default=true,callback=function()
                local name=U.trim(dialog:getInputText())
                if name=="" then return end
                UIManager:close(dialog)
                home.local_roots[index].name=name
                self:_save_local_roots(home,preferences)
            end},
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Plugin:remove_local_root(path)
    local index,root,home,preferences=self:_local_root_index(path)
    if not index then return end
    local dialog
    dialog=ConfirmBox:new{
        text="从觅阅中移除“"..tostring(root.name or LocalLibrary.basename(path)).."”？\n\n不会删除目录或其中的书籍。",
        ok_text="移除",ok_callback=function()
            UIManager:close(dialog)
            table.remove(home.local_roots,index)
            self:_save_local_roots(home,preferences)
            local tree=self:_home_local_tree_cache()
            local prefix=LocalLibrary.normalize(path).."/"
            for key in pairs(tree.dirs or {}) do
                local normalized=LocalLibrary.normalize(key)
                if normalized==LocalLibrary.normalize(path) or normalized:sub(1,#prefix)==prefix then tree.dirs[key]=nil end
            end
            self.store:set("home_local_tree_index",tree)
            local index_cache=self:_home_local_cache()
            local kept={}
            local normalized_root=LocalLibrary.normalize(path)
            for _,book in ipairs(index_cache.books or {}) do
                if LocalLibrary.normalize(book.library_root or index_cache.root or "")~=normalized_root then
                    kept[#kept+1]=book
                end
            end
            index_cache.books=kept
            self.store:set("home_local_index",index_cache)
            self:toast("已移除本地书库目录",2)
        end,
    }
    UIManager:show(dialog)
end

function Plugin:local_root_settings_menu(path)
    local _,root=self:_local_root_index(path)
    if not root then return {{text="目录已不存在",enabled=false}} end
    return {
        {text="浏览此目录",post_text=tostring(root.path),callback=function() self:show_local_browser(root.path,root,{},false) end},
        {text="启用此目录",checked_func=function()
            local _,current=self:_local_root_index(path); return current and current.enabled~=false
        end,keep_menu_open=true,callback=function()
            local index,current,home,preferences=self:_local_root_index(path); if not index then return end
            home.local_roots[index].enabled=current.enabled==false
            self:_save_local_roots(home,preferences)
        end},
        {text="修改显示名称",callback=function() self:rename_local_root(path) end},
        {text="刷新当前层",callback=function()
            self:_home_refresh_local_directory(path,function() self:toast("当前层已刷新",2) end,true)
        end},
        {text="从觅阅移除",callback=function() self:remove_local_root(path) end},
    }
end

local LOCAL_LIBRARY_MODE_LABELS={auto="自动管理",manual="手动扫描",direct="文件夹浏览"}

function Plugin:_local_library_mode_label(mode)
    return LOCAL_LIBRARY_MODE_LABELS[tostring(mode or self:_home_preferences().local_library_mode or "direct")] or "文件夹浏览"
end

function Plugin:_set_local_library_mode(mode)
    if mode~="auto" and mode~="manual" and mode~="direct" then return false end
    local home,preferences=self:_home_preferences()
    if home.local_library_mode==mode then return true end
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    if self.home_async then self.home_async:cancel("local library mode changed") end
    self:_cancel_home_directory_request("local library mode changed")
    self._home_refreshing=false
    home.local_library_mode=mode
    home.auto_scan=mode=="auto"
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_notify_home_data_changed("content") end
    self:toast("本地书籍已切换为"..self:_local_library_mode_label(mode),2)
    if mode=="auto" then
        UIManager:scheduleIn(.35,function()
            if not self:_active_reader_ui() and home_session().suspended~=true then self:_home_scan_local(true) end
        end)
    end
    return true
end

function Plugin:local_library_mode_menu()
    local rows={}
    local details={
        auto="自动维护索引，适合书籍较少",
        manual="只在点击扫描时更新，推荐大书库",
        direct="不递归扫描，按文件夹直接查看",
    }
    for _,mode in ipairs({"auto","manual","direct"}) do
        local key=mode
        rows[#rows+1]={
            text=self:_local_library_mode_label(key),post_text=details[key],radio=true,
            checked_func=function() return self:_home_preferences().local_library_mode==key end,
            callback=function() self:_set_local_library_mode(key) end,
        }
    end
    return rows
end

function Plugin:_toggle_local_library_auto_update()
    local home,preferences=self:_home_preferences()
    home.local_auto_update=home.local_auto_update~=true
    home.auto_scan=home.local_auto_update==true
    self:_save_home_preferences(home,preferences)
    self:toast(home.local_auto_update and "本地书库自动更新已开启" or "本地书库自动更新已关闭",2)
    if home.local_auto_update and HomeView.is_shown() then
        UIManager:scheduleIn(.25,function() self:_home_scan_local(false) end)
    end
    return home.local_auto_update
end

function Plugin:local_library_settings_menu()
    local home=self:_home_preferences()
    local items={
        {text="自动更新本地书库",post_text=home.local_auto_update==true and "已开启" or "已关闭",
            checked_func=function() return self:_home_preferences().local_auto_update==true end,keep_menu_open=true,
            callback=function() self:_toggle_local_library_auto_update() end},
        {text="按文件夹浏览",post_text="书籍与文件夹分开查看",callback=function() self:_open_local_library_folders() end},
    }
    for _,root in ipairs(self:_home_local_roots(false)) do
        local path=root.path
        items[#items+1]={
            text=tostring(root.name or LocalLibrary.basename(path)),post_text=root.enabled~=false and "已启用" or "已停用",
            sub_item_table_func=function() return self:local_root_settings_menu(path) end,
        }
    end
    if #self:_home_local_roots(false)==0 then items[#items+1]={text="尚未添加本地书库目录",enabled=false} end
    items[#items+1]={text="添加本地书库目录",post_text="选择实际存放书籍的文件夹",callback=function() self:add_local_root_dialog() end}
    local cache=self:_home_local_cache()
    local scanned=tonumber(cache.scanned_at or 0) or 0
    items[#items+1]={text="上次更新",post_text=scanned>0 and self:_display_time("%m-%d %H:%M",scanned) or "尚未更新",enabled=false}
    items[#items+1]={text="说明",post_text="主页只显示书籍 文件夹浏览不会混进书架",enabled=false}
    return items
end

function Plugin:display_settings_menu()
    local home=self:_home_preferences()
    local size_labels={compact="紧凑",standard="标准",large="大号"}
    return {
        {text="页面布局",post_text=(home.layout_style=="compact" and "紧凑布局" or "标准布局"),sub_item_table_func=function() return self:home_layout_settings_menu() end},
        {text="觅阅显示大小",post_text=size_labels[home.display_size] or "标准",sub_item_table_func=function() return self:home_display_size_menu() end},
        {text="觅阅界面字体",post_text=self:_home_ui_font_label(home),sub_item_table_func=function() return self:home_ui_font_menu() end},
        {text="首页书架来源",post_text="选择显示项目",sub_item_table_func=function() return self:home_source_settings_menu() end},
        {text="本地书籍",post_text=home.local_auto_update==true and "自动更新" or "手动更新",sub_item_table_func=function() return self:local_library_settings_menu() end},
        {text="公众号阅读",post_text="图片与缓存",sub_item_table_func=function() return self:mp_settings_menu() end},
        {text="主页菜单栏",post_text="最多六项",sub_item_table_func=function() return self:home_action_settings_menu() end},
        {text="下滑工具栏",post_text="设备与 KOReader",sub_item_table_func=function() return self:home_panel_settings_menu() end},
        {text="网络补全图书信息",post_text="只补充缺失资料",checked_func=function() return self:_home_preferences().network_metadata~=false end,keep_menu_open=true,callback=function() self:_toggle_home_network_metadata() end},
        {text="主页锁屏显示最近阅读封面",checked_func=function() return self:_home_preferences().lockscreen_recent~=false end,keep_menu_open=true,callback=function() self:_toggle_home_lockscreen() end},
        {text="显示书架封面",checked_func=function() return self.store:preferences().shelf_covers~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("shelf_covers") end},
    }
end

function Plugin:_performance_mode_label()
    local status=self.performance_mode:status()
    return status.enabled and "轻量模式" or "标准模式"
end

function Plugin:_lightweight_enabled()
    return self.performance_mode and self.performance_mode:enabled() or false
end

function Plugin:_set_performance_mode(enabled)
    self.performance_mode:set_enabled(enabled==true)
    if enabled then
        if self.ui and self.ui.document then self:_mark_reader_busy(3) end
        self:info("轻量模式已开启。\n\n阅读和菜单操作会优先；后台下载、封面、书籍资料和自动更新会更保守地执行。阅读、下载和同步功能不会关闭。")
    else
        if self.download_task then self.download_task:resume("reader_interaction") end
        self:info("已恢复标准模式。")
    end
end

function Plugin:_toggle_performance_auto_detect()
    local status=self.performance_mode:status()
    self.performance_mode:set_auto_detect(not status.auto_detect)
    self:toast((not status.auto_detect) and "性能问题检测已开启" or "性能问题检测已关闭",2)
end

function Plugin:_record_performance(kind,elapsed_ms)
    if not self.performance_mode then return nil end
    local result=self.performance_mode:record(kind,elapsed_ms)
    if result then self._performance_prompt_pending=result end
    return result
end

function Plugin:_schedule_performance_prompt(delay)
    if not self._performance_prompt_pending then return false end
    local pending=self._performance_prompt_pending
    local attempts=0
    local task
    task=function()
        if self._performance_prompt_pending~=pending then return end
        if home_exiting() or UIManager._exit_code~=nil
            or home_session().suspended==true or self._miuread_suspended==true then return end
        if reader_close_active() or self._thought_popup_busy==true then
            attempts=attempts+1
            if attempts<8 then UIManager:scheduleIn(.6,task) end
            return
        end
        self:_show_performance_prompt()
    end
    UIManager:scheduleIn(math.max(.25,tonumber(delay) or .9),task)
    return true
end

function Plugin:_show_performance_prompt()
    local pending=self._performance_prompt_pending
    if not pending or not self.performance_mode then return false end
    self._performance_prompt_pending=nil
    if self.performance_mode:enabled() then return false end
    if self._performance_prompt_dialog then
        pcall(UIManager.close,UIManager,self._performance_prompt_dialog)
        self._performance_prompt_dialog=nil
    end
    local dialog
    dialog=ButtonDialog:new{
        title="检测到运行较慢\n\n觅阅检测到近期多次明显操作延迟。开启轻量模式后，阅读和菜单操作会优先，后台下载、封面、书籍资料和自动更新会更保守地执行；阅读、下载和同步功能不会关闭。",
        title_align="center",
        buttons={
            {{text="开启轻量模式",callback=function()
                UIManager:close(dialog); self._performance_prompt_dialog=nil
                self:_set_performance_mode(true)
            end}},
            {{text="暂不开启",callback=function()
                UIManager:close(dialog); self._performance_prompt_dialog=nil
            end}},
            {{text="不再提醒",callback=function()
                UIManager:close(dialog); self._performance_prompt_dialog=nil
                self.performance_mode:disable_reminders()
                self:toast("已关闭性能问题提醒",2)
            end}},
        },
    }
    self._performance_prompt_dialog=dialog
    UIManager:show(dialog)
    return true
end

function Plugin:performance_settings_menu()
    local status=self.performance_mode:status()
    local memory_status=self.memory_mode:status()
    local items={
        {text="轻量模式",post_text=self:_performance_mode_label(),checked_func=function()
            return self.performance_mode:enabled()
        end,callback=function() self:_set_performance_mode(not self.performance_mode:enabled()) end},
        {text="自动检测性能问题",post_text=status.reminders_disabled and "不再提醒" or nil,
            checked_func=function() return self.performance_mode:status().auto_detect end,
            keep_menu_open=true,callback=function() self:_toggle_performance_auto_detect() end},
        {text="低内存保护",post_text=self:_memory_mode_label(),checked_func=function()
            return (self.store:preferences().memory_mode or {}).enabled==true
        end,callback=function() self:toggle_memory_mode() end},
    }
    if memory_status.enabled or memory_status.residual then
        items[#items+1]={text="恢复缓存设置",callback=function() self:restore_memory_mode() end}
    end
    items[#items+1]={text="模式说明",callback=function()
        self:info("轻量模式用于改善明显卡顿：阅读操作优先，后台下载更保守。\n\n低内存保护用于避免内存不足：会减少 KOReader 页面缓存，可能让 PDF、漫画和快速跳页稍慢。两个模式可以独立开启。")
    end}
    return items
end

function Plugin:_memory_mode_label()
    local status=self.memory_mode:status()
    if not status.available then return status.enabled and "配置异常" or "不可用" end
    if status.enabled then return status.matches and "已开启" or "配置异常" end
    if status.residual then return "外部或残留设置" end
    return "关闭"
end

function Plugin:_set_memory_mode(enabled)
    local ok,result_or_error=self.memory_mode:set_enabled(enabled)
    if not ok then
        self:info("无法修改低内存保护：\n"..tostring(result_or_error))
        return
    end
    local result=result_or_error or {}
    if enabled then
        self:info("低内存保护已开启。\n\n完整退出并重新启动 KOReader 后生效。PDF、漫画和快速跳页可能稍慢。")
    elseif result.external_change then
        self:info("低内存保护已关闭。\n\n检测到缓存设置已被其他配置修改，因此没有覆盖当前值。完整重启 KOReader 后生效。")
    else
        self:info("低内存保护已关闭，原有缓存设置已恢复。\n\n完整退出并重新启动 KOReader 后生效。")
    end
end


function Plugin:restore_memory_mode()
    local status=self.memory_mode:status()
    if not status.enabled and not status.residual then
        self:info("当前没有检测到低内存设置，无需恢复。")
        return
    end
    local text
    if status.enabled then
        text="恢复开启低内存保护前的缓存设置？\n\n恢复后需要完整重启 KOReader。卸载觅阅前建议先执行恢复。"
    else
        text="检测到外部或旧版本遗留的低内存设置。是否恢复缓存策略？\n\n无法确认它是否由觅阅写入；恢复后需要完整重启 KOReader。"
    end
    UIManager:show(ConfirmBox:new{
        text=text,ok_text="恢复",ok_callback=function()
            if status.enabled then self:_set_memory_mode(false); return end
            local ok,result_or_error=self.memory_mode:restore_detected()
            if not ok then self:info("无法恢复缓存设置：\n"..tostring(result_or_error)); return end
            local result=result_or_error or {}
            self:info(result.used_default and "低内存设置已清除，将恢复 KOReader 默认缓存策略。\n\n完整重启 KOReader 后生效。"
                or "低内存设置已恢复。\n\n完整重启 KOReader 后生效。")
        end,
    })
end

function Plugin:toggle_memory_mode()
    local status=self.memory_mode:status()
    local state=(self.store:preferences().memory_mode or {}).enabled==true
    if state then
        self:_set_memory_mode(false)
        return
    end
    if status.residual then
        self:info("检测到外部或旧版本遗留的低内存设置。请先使用“恢复缓存设置”，再由觅阅重新开启。")
        return
    end
    UIManager:show(ConfirmBox:new{
        text="低内存保护适合下载大书时容易闪退或卡死的设备。\n\n开启后会减少 KOReader 页面缓存，PDF、漫画和快速跳页可能稍慢。需要完整重启 KOReader 后生效。",
        ok_text="开启",
        ok_callback=function() self:_set_memory_mode(true) end,
    })
end

function Plugin:download_settings_menu()
    local policy=tostring(self.store:preferences().download_reader_policy or "ask")
    local policy_label=policy=="allow" and "允许后台下载" or (policy=="after_reading" and "退出阅读后下载" or "每次询问")
    local items={
        {text="阅读时下载策略",post_text=policy_label,sub_item_table_func=function() return self:download_reader_policy_menu() end},
        {text="下载网络",post_text=self:_download_network_mode_label(),sub_item_table_func=function() return self:download_network_mode_menu() end},
        {text="下载关键进度提示",checked_func=function() return self.store:preferences().download_notice_enabled~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_notice_enabled") end},
        {text="下载完成提醒",checked_func=function() return self.store:preferences().download_complete_notice~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_complete_notice") end},
    }
    items[#items+1]={text="下载目录",post_text=self:_download_dir_label(),callback=function() self:directory_dialog() end}
    items[#items+1]={text="存储清理",post_text="临时文件与失效封面",callback=function() self:show_download_cleanup_dialog() end}
    return items
end
function Plugin:mp_settings_menu()
    return {
        {text="下载文章图片",checked_func=function() return self.store:preferences().mp_images==true end,keep_menu_open=true,callback=function() self:_toggle_preference("mp_images") end},
        {text="公众号缓存管理",sub_item_table_func=function() return self:mp_global_cache_menu() end},
    }
end
function Plugin:account_sync_settings_menu()
    -- Keep desktop mode and plugin mode on the same settings source.  beta.7
    -- had a second desktop-only menu here, so the annotation-sync controls
    -- added in plugin_settings.lua were invisible from the desktop UI.
    return PluginSettings.account_sync(self)
end

function Plugin:more_settings_menu()
    return {
        {text="提醒与确认",sub_item_table_func=function() return self:notice_settings_menu() end},
        {text="评论数据迁移",sub_item_table_func=function() return self:book_repair_settings_menu() end},
        {text="更新设置",sub_item_table_func=function() return self:update_settings_menu() end},
        {text="关于觅阅",callback=self:safe("about",function() self:show_about() end)},
    }
end

function Plugin:_download_settings_summary()
    local state=self:_download_state()
    local queue=self.store:download_queue()
    if state.status=="active" then return tostring(self:_download_percent(state)).."%" end
    if self:_has_download_status() then return self:_download_status_label():gsub("^后台下载%s*[·：]?%s*","") end
    if #queue>0 then return tostring(#queue).." 项等待" end
    return nil
end

function Plugin:menu_shortcuts_settings_menu()
    local home=self:_home_preferences()
    local home_visible=0
    for _,key in ipairs(home.action_order or HOME_ACTION_ITEM_ORDER) do
        if home.action_items and home.action_items[key]==true then home_visible=home_visible+1 end
    end
    local reader_visible=self:_reader_quick_action_visible_count()
    return {
        {text="主页菜单栏",post_text=string.format("已显示 %d/6",home_visible),sub_item_table_func=function() return self:home_action_settings_menu() end},
        {text="主页下滑工具栏",post_text="设备与 KOReader",sub_item_table_func=function() return self:home_panel_settings_menu() end},
        {text="阅读菜单栏",post_text=string.format("已显示 %d/%d",reader_visible,PluginReader.QUICK_ACTION_MAX),sub_item_table_func=function() return self:reader_quick_actions_menu() end},
        {text="阅读界面",post_text="显示与快捷控制",sub_item_table_func=function() return self:reader_quick_panel_settings_menu() end},
    }
end

function Plugin:settings_menu()
    -- "更多" is the complete MiuRead menu.  It may point to the same
    -- underlying pages as home shortcuts, but it never owns a second copy of
    -- those settings.
    local rows={
        {text="运行模式",post_text=self:_home_mode_label(),sub_item_table_func=function() return self:home_mode_menu() end},
    }
    if self:_home_enabled() then
        rows[#rows+1]={text="首页与书架",post_text="布局 书架与快捷入口",sub_item_table_func=function() return self:display_settings_menu() end}
        rows[#rows+1]={text="菜单与快捷按键",post_text="主页与阅读菜单栏",sub_item_table_func=function() return self:menu_shortcuts_settings_menu() end}
        rows[#rows+1]={text="阅读界面",post_text="显示与快捷控制",sub_item_table_func=function() return self:reader_quick_panel_settings_menu() end}
    end
    rows[#rows+1]={text="评论 划线与想法",post_text=self:_thought_display_label(),sub_item_table_func=function() return PluginSettings.comments(self) end}
    rows[#rows+1]={text="本地书库",post_text=(self:_home_preferences().local_auto_update==true and "自动更新" or "手动更新"),sub_item_table_func=function() return self:local_library_settings_menu() end}
    rows[#rows+1]={text="账户",post_text=self:logged_in() and "已登录" or "未登录",callback=function() self:show_account_status() end}
    rows[#rows+1]={text="阅读同步",post_text=self:_home_sync_status_label(),sub_item_table_func=function() return self:sync_settings_menu() end}
    rows[#rows+1]={text="下载管理",post_text=self:_download_menu_text(),callback=function() self:show_downloads() end}
    rows[#rows+1]={text="时间与时区",post_text=TimeZone.label((self:_time_preferences())),sub_item_table_func=function() return self:time_display_settings_menu() end}
    rows[#rows+1]={text="性能与兼容性",post_text=self:_performance_mode_label(),sub_item_table_func=function() return self:performance_settings_menu() end}
    rows[#rows+1]={text="公众号阅读",sub_item_table_func=function() return self:mp_settings_menu() end}
    rows[#rows+1]={text="更新与关于",sub_item_table_func=function() return PluginSettings.update_about(self) end}
    rows[#rows+1]={text="工具与维护",sub_item_table_func=function() return self:maintenance_menu() end}
    return rows
end

function Plugin:thought_font_settings_menu()
    local prefs=self.store:preferences().thoughts or {}
    return {
        {text="阅读评论",post_text=self:_thoughts_enabled_label(),checked_func=function() return self:_thoughts_enabled() end,keep_menu_open=true,callback=function() self:_toggle_thoughts_enabled() end},
        {text="评论字体跟随正文",checked_func=function()
            return (self.store:preferences().thoughts or {}).follow_body_font==true
        end,keep_menu_open=true,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}
            p.thoughts.follow_body_font=p.thoughts.follow_body_font~=true
            self.store:save_preferences(p)
            self:_refresh_thought_display(p.thoughts)
            if p.thoughts.follow_body_font then
                self:toast("评论字体将跟随正文")
            else
                self:toast("评论字体已改为固定字体")
            end
        end},
        {text="固定字体",post_text=self:_thought_font_face_label(prefs),enabled_func=function()
            return (self.store:preferences().thoughts or {}).follow_body_font~=true
        end,sub_item_table_func=function() return self:thought_font_face_menu() end},
        {text="字体大小",post_text=self:_thought_font_size_label(),sub_item_table_func=function() return self:thought_font_menu() end},
    }
end

function Plugin:_thought_font_face_label(prefs)
    prefs=prefs or (self.store:preferences().thoughts or {})
    local name=U.trim(tostring(prefs.font_face or ""))
    return name~="" and name or "KOReader 默认"
end
function Plugin:_reader_font_face_choices()
    local choices={}
    local seen={}
    local font=self.ui and self.ui.font or nil
    if font and type(font.setupFaceMenuTable)=="function" then
        pcall(font.setupFaceMenuTable,font)
    end
    for _,item in ipairs(font and type(font.face_table)=="table" and font.face_table or {}) do
        local name=U.trim(tostring(item.menu_item_id or ""))
        if name~="" and not seen[name] then
            seen[name]=true
            local label=name
            if type(item.text_func)=="function" then
                local ok,value=pcall(item.text_func)
                if ok and U.trim(tostring(value or ""))~="" then label=tostring(value) end
            elseif U.trim(tostring(item.text or ""))~="" then
                label=tostring(item.text)
            end
            choices[#choices+1]={name=name,label=label,font_func=item.font_func}
        end
    end
    if #choices>0 then return choices end

    -- Compatibility fallback for older KOReader versions that do not expose
    -- ReaderFont.face_table. This is the same CRE font source used by KOReader.
    local ok,faces=pcall(function()
        local cre=require("document/credocument"):engineInit()
        return cre and cre.getFontFaces and cre.getFontFaces() or {}
    end)
    if ok and type(faces)=="table" then
        for _,value in ipairs(faces) do
            local name=U.trim(tostring(value or ""))
            if name~="" and not seen[name] then
                seen[name]=true
                choices[#choices+1]={name=name,label=name}
            end
        end
        table.sort(choices,function(a,b) return a.name:lower()<b.name:lower() end)
    end
    return choices
end

function Plugin:thought_font_face_menu()
    local rows={
        {text="KOReader 默认字体",radio=true,menu_item_id="__default__",checked_func=function()
            return U.trim(tostring((self.store:preferences().thoughts or {}).font_face or ""))==""
        end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}
            p.thoughts.font_face=""; p.thoughts.follow_body_font=false
            self.store:save_preferences(p)
            self:_refresh_thought_display(p.thoughts)
            self:toast("评论字体已设为 KOReader 默认字体")
        end},
    }
    local choices=self:_reader_font_face_choices()
    if #choices==0 then
        rows[#rows+1]={text="无法读取正文字体列表",enabled=false}
        return rows
    end
    for _,choice in ipairs(choices) do
        local selected=choice.name
        rows[#rows+1]={
            text=choice.label,
            font_func=choice.font_func,
            radio=true,
            menu_item_id=selected,
            checked_func=function()
                return tostring((self.store:preferences().thoughts or {}).font_face or "")==selected
            end,
            callback=function()
                local p=self.store:preferences(); p.thoughts=p.thoughts or {}
                p.thoughts.font_face=selected; p.thoughts.follow_body_font=false
                self.store:save_preferences(p)
                self:_refresh_thought_display(p.thoughts)
                self:toast("评论字体已设为："..selected)
            end,
        }
    end
    rows.max_per_page=5
    rows.open_on_menu_item_id_func=function()
        local face=U.trim(tostring((self.store:preferences().thoughts or {}).font_face or ""))
        return face~="" and face or "__default__"
    end
    return rows
end
function Plugin:thought_font_menu()
    local choices={18,22,26,30}
    local rows={}
    for _,value in ipairs(choices) do
        local target=value
        rows[#rows+1]={text=tostring(target),radio=true,checked_func=function() return self:_thought_font_size_value()==target end,callback=function()
            self:_set_thought_font_size(target)
        end}
    end
    rows[#rows+1]={text="阅读界面可用 − / + 精细调整",enabled=false}
    return rows
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
