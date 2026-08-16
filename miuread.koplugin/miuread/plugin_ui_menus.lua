-- MiuRead notices / menu framework / reader native page controller.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local U = require("miuread.util")
local Text = require("miuread.text")
local Session = require("miuread.session_state")
local HOME_SESSION = Session.home()
local unpack_args = unpack or table.unpack
local HomeView = require("miuread.home_view")
local HomeData = require("miuread.home_data")
local HomeQuickPanel = require("miuread.home_quick_panel")
local ActionSheet = require("miuread.action_sheet")
local Orientation = require("miuread.orientation_controller")
local TransientGuard = require("miuread.transient_guard")
local Lazy = require("miuread.lazy")
local ReaderListDialog = Lazy("miuread.reader_list_dialog")
local GestureBridge = require("miuread.gesture_bridge")
local RawButtonDialog = require("ui/widget/buttondialog")
local RawMenu = require("ui/widget/menu")

local function reader_close_active()
    return Session.reader_close_active()
end

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ButtonDialog = gesture_aware_class(RawButtonDialog, {_miuread_transient=true, _miuread_modal_surface=true})
local Menu = gesture_aware_class(RawMenu, {_miuread_transient=true, _miuread_modal_surface=true})

local _ = Text.tr

local Plugin = {}

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



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
