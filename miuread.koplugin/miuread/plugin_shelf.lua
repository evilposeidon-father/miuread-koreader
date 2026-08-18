-- MiuRead shelf controller, split from main.lua.
local UIManager = require("ui/uimanager")
local Lazy = require("miuread.lazy")
local logger = require("logger")
local U = require("miuread.util")
local Text = require("miuread.text")
local Http = require("miuread.http")
local Protocol = require("miuread.protocol")
local HomeView = require("miuread.home_view")
local ShelfView = require("miuread.shelf_view")
local DownloadResult = require("miuread.download_result")
local GestureBridge = require("miuread.gesture_bridge")
local RawInfoMessage = require("ui/widget/infomessage")
local RawInputDialog = require("ui/widget/inputdialog")

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local InfoMessage = gesture_aware_class(RawInfoMessage, {_miuread_transient=true, _miuread_modal_surface=true})
local InputDialog = gesture_aware_class(RawInputDialog, {_miuread_transient=true, _miuread_modal_surface=true})

local _ = Text.tr

local SHELF_CACHE_TTL=15*60
local SHELF_DIRECT_CACHE_TTL=6*60*60

-- Mirrors main.lua's local normalize.
local function normalize(v) local b=v.bookInfo or v.book or v; return {bookId=tostring(b.bookId or v.bookId or ""),title=b.title or v.title or "未命名",author=b.author or v.author or "",cover=b.cover or v.cover,category=b.category or v.category,progress=tonumber(v.progress or b.progress or 0) or 0,updateTime=tonumber(v.updateTime or b.updateTime or 0) or 0} end

local Plugin = {}

function Plugin:_save_shelf_context(section,mp_mode)
    section=section=="generated" and "generated" or "account"
    local p=self.store:preferences()
    local changed=p.shelf_section~=section
    p.shelf_section=section
    if section=="account" and mp_mode~=nil then
        local kind=mp_mode==true and "mp" or "books"
        if p.account_shelf_kind~=kind then changed=true end
        p.account_shelf_kind=kind
    end
    if changed then self.store:save_preferences(p) end
    self._last_shelf_section=section
    if section=="account" then self._last_shelf_mode=mp_mode==true end
end


function Plugin:_friendly_remote_error(err, context)
    local text=tostring(err or "未知错误")
    local lower=text:lower()
    if text:find("[MiuReadMPNoAccount]",1,true) then
        return "微信读书书架暂时没有返回可用的公众号。"
    end
    if text:find("[MiuReadMPInvalidAccount]",1,true) then
        return "公众号信息无效，请刷新微信读书书架。"
    end
    if lower:find("参数格式错误",1,true) or lower:find("params error",1,true)
        or lower:find("parameter format",1,true) then
        return "公众号数据暂时无法读取，请刷新后重试。"
    end
    if Http.is_auth_error(text) or lower:find("api key",1,true)
        or lower:find("authorization",1,true) then
        return "登录凭证已失效或被拒绝，请在账户设置中重新扫码登录。"
    end
    if Http.is_rate_limit_error and Http.is_rate_limit_error(text) then
        return "请求频率暂时受限，请稍后重试。"
    end
    if Http.is_forbidden_error and Http.is_forbidden_error(text) then
        return "当前账号暂时无法访问该内容，请稍后重试或重新登录。"
    end
    if Http.is_network_error and Http.is_network_error(text) then
        return "网络连接失败，请检查 Wi-Fi 后重试。"
    end
    if lower:find("timeout",1,true) then return "网络请求超时，请检查 Wi-Fi 后重试。" end
    if lower:find("network request failed",1,true) then return "网络连接失败，请检查 Wi-Fi 后重试。" end
    if lower:find("%.lua:%d+:") or lower:find("stack traceback",1,true) then
        return tostring(context or "请求").."失败，请稍后重试。"
    end
    return tostring(context or "请求").."失败：\n"..U.first_line(text,120)
end

function Plugin:_friendly_action_error(err, context, kind)
    local message = self:_friendly_remote_error(err, context)
    if kind == "download" then
        return message .. "\n\n建议：检查网络后重试；已下载章节和断点会保留。"
    elseif kind == "update" then
        return message .. "\n\n建议：检查网络后重试；当前版本不受影响。"
    elseif kind == "sync" then
        return message .. "\n\n建议：检查登录与网络后重试；本地阅读记录不会丢失。"
    elseif kind == "annotations" then
        return message .. "\n\n建议：本地批注已保留，可稍后重试。"
    end
    return message
end

function Plugin:_refresh_shelf_async(on_ready,silent)
    local function fail(err)
        if Http.is_auth_error(err) then self:_mark_auth_problem("shelf",err,true) end
        local message=self:_friendly_remote_error(err,"书架加载")
        if on_ready then
            on_ready({}, {}, message)
        elseif not silent or message:find("重新扫码登录",1,true) then
            self:toast(message,4)
        end
        return false,err
    end
    if not self:is_online() then
        return fail("network request failed: offline")
    end

    local async_available=self.shelf_async and self.shelf_async:available()
    if async_available then
        if self.shelf_async:busy() then return fail("书架正在刷新，请稍后重试。") end
    elseif self._shelf_main_busy then
        return fail("书架正在刷新，请稍后重试。")
    end

    self._miuread_shelf_refresh_generation=(tonumber(self._miuread_shelf_refresh_generation) or 0)+1
    local generation=self._miuread_shelf_refresh_generation
    local function succeed(data,mode)
        if generation~=self._miuread_shelf_refresh_generation then return end
        self:_mark_auth_channel_ok("shelf")
        local books,mp=self.library:normalize(data or {})
        self.store:save_shelf_cache({books=books,mp=mp,updated_at=os.time()})
        logger.info("[MiuRead][Shelf] refresh completed","mode=",tostring(mode),
            "books=",tostring(#books),"mp=",tostring(#mp))
        if on_ready then on_ready(books,mp,nil) end
    end

    if not async_available then
        self._shelf_main_busy=true
        local loading
        if on_ready and not silent then
            loading=InfoMessage:new{text="正在加载书架……"}
            UIManager:show(loading)
        end
        logger.info("[MiuRead][Shelf] refresh started","mode=direct")
        UIManager:scheduleIn(.05,function()
            local handled,unexpected=xpcall(function()
                if generation~=self._miuread_shelf_refresh_generation then return end
                local ok,data=pcall(self.api.shelf,self.api,{retries=0,timeout={7,12}})
                if not ok then error(tostring(data)) end
                if loading then pcall(function() UIManager:close(loading) end); loading=nil end
                succeed(data,"direct")
            end,debug.traceback)
            self._shelf_main_busy=false
            if loading then pcall(function() UIManager:close(loading) end) end
            if not handled and generation==self._miuread_shelf_refresh_generation then fail(unexpected) end
        end)
        return true
    end

    local auth=U.copy(self.store:auth())
    logger.info("[MiuRead][Shelf] refresh started","mode=subprocess")
    local started,err=self.shelf_async:run("shelf_refresh",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local UtilChild=require("miuread.util")
        local child_store={
            auth=function() return UtilChild.copy(auth) end,
            save_auth=function() end,
        }
        return ApiChild:new(HttpChild:new(child_store),child_store):shelf({retries=1,timeout={10,18}})
    end,function(result)
        if generation~=self._miuread_shelf_refresh_generation then return end
        if result and result.ok==true then
            succeed(result.value or {},"subprocess")
            return
        end
        fail(result and result.error or "未知错误")
    end,32)
    if not started then return fail(err or "无法启动异步任务") end
    return true
end

function Plugin:load_shelf(cb,force_remote,section)
    section=section=="generated" and "generated" or "account"
    local cached_books,cached_mp,cached_updated=self.library:cached()
    local library_snapshot=self.store:library()
    local local_books,local_mp=self.library:local_books(library_snapshot,self.store:get("sessions",{}))
    local cached_count=#cached_books+#cached_mp
    local local_count=#local_books+#local_mp
    local cache_age=math.max(0,os.time()-(tonumber(cached_updated) or 0))
    local background_available=self.shelf_async and self.shelf_async:available()

    if not force_remote then
        if cached_count>0 then
            cb(cached_books,cached_mp,nil)
            local refresh_after=background_available and SHELF_CACHE_TTL or SHELF_DIRECT_CACHE_TTL
            if self:logged_in() and cache_age>refresh_after then
                self:_refresh_shelf_async(function(_,_,err)
                    if not err and self._shelf_view and not self._shelf_view._miu_closed then
                        self:_reopen_shelf(self._last_shelf_mode,self._last_shelf_section)
                    end
                end,true)
            end
            return
        end
        if local_count>0 then
            if section=="account" and self:logged_in() then
                self:toast("正在加载账号书架…",2)
                self:_refresh_shelf_async(function(books,mp,err)
                    cb(books,mp,err)
                end,false)
                return
            end
            self:toast("账号书架暂未加载，可先查看“已生成书籍”。",3)
            cb({}, {}, "账号书架正在后台加载。")
            if self:logged_in() then
                self:_refresh_shelf_async(function(_,_,err)
                    if not err and self._shelf_view and not self._shelf_view._miu_closed then
                        self:_reopen_shelf(self._last_shelf_mode,self._last_shelf_section)
                    end
                end,true)
            end
            return
        end
    end
    if not self:logged_in() then
        cb(cached_books,cached_mp,"当前未登录，仅使用已缓存的账号书架和已生成书籍。")
        return
    end
    self:_refresh_shelf_async(function(books,mp,err)
        if err and cached_count>0 then cb(cached_books,cached_mp,err) else cb(books,mp,err) end
    end,false)
end

function Plugin:_shelf_rows(section,mp_mode,remote_books,remote_mp,remote_status_known)
    if remote_books==nil or remote_mp==nil then remote_books,remote_mp=self.library:cached() end
    local library_snapshot=self.store:library()
    local sessions=self.store:get("sessions",{})
    local local_books,local_mp=self.library:local_books(library_snapshot,sessions)
    section=section=="generated" and "generated" or "account"
    if section=="generated" then
        -- Public-account articles are standalone HTML files and no longer
        -- participate in the generated EPUB shelf.
        local rows=self.library:generated_rows(remote_books or {},{},local_books,{},remote_status_known)
        for _,row in ipairs(rows) do row.shelf_section="generated" end
        return rows
    end
    local remote_rows=mp_mode and (remote_mp or {}) or (remote_books or {})
    local local_rows=mp_mode and local_mp or local_books
    local rows=self.library:account_rows(remote_rows,local_rows)
    for _,row in ipairs(rows) do row.shelf_section="account" end
    return rows
end

function Plugin:_prepare_shelf_rows(rows)
    local cover_index=self.store:get("cover_index",{})
    for id,path in pairs(self._cover_index_pending or {}) do cover_index[id]=path end
    local cover_index_changed=false
    local download_state=self:_download_state()
    for _,b in ipairs(rows or {}) do
        b.download_active=false
        b.download_progress=nil
        local id=tostring(b.bookId or b.book_id or "")
        if id~="" then
            local session=self.store:session(id) or {}
            local snapshot=type(session.local_position_snapshot)=="table" and session.local_position_snapshot or {}
            local effective=tonumber(session.progress_local_percent)
                or (snapshot.safe==true and tonumber(snapshot.progress) or nil)
                or tonumber(session.verified_local_percent)
            if effective~=nil then b.progress=math.max(0,math.min(100,effective)) end
        end
        local removed
        b.cover_path,removed=self.library:cached_cover_path(b.bookId,cover_index)
        if removed then
            cover_index_changed=true
            if self._cover_index_pending then self._cover_index_pending[tostring(b.bookId)]=nil end
        end
        if b.annotation_pending==true or b.annotation_fallback==true then
            b.download_status=DownloadResult.shelf_status({
                annotation_pending=b.annotation_pending==true,
                annotation_fallback=b.annotation_fallback==true,
            },false)
        else
            b.download_status=nil
        end
        if tostring(download_state.book_id or "")~="" and tostring(download_state.book_id)==tostring(b.bookId or "") then
            if download_state.status=="active" then
                b.download_active=true
                b.download_progress=math.max(0,math.min(1,self:_download_percent(download_state)/100))
                b.download_status=nil
            elseif download_state.status=="pending_install" then
                b.download_status=DownloadResult.shelf_status(download_state,true)
            elseif download_state.status=="failed" or download_state.status=="interrupted" then b.download_status="生成未完成"
            elseif download_state.status=="annotation_pending" then b.download_status="批注待修复"
            elseif download_state.status=="completed" and download_state.annotation_fallback==true then b.download_status="已生成"
            elseif download_state.status=="completed" and download_state.seen~=true then b.download_status="刚刚生成完成" end
        end
        b.status_text=self:_shelf_status_text(b)
    end
    if cover_index_changed then self.store:set("cover_index",cover_index) end
    return rows
end

function Plugin:_home_mutate_book_rows(book_id,mutator)
    book_id=tostring(book_id or "")
    if book_id=="" or type(mutator)~="function" then return false end
    local changed=false
    for _,section in pairs(self._home_sections or {}) do
        for _,book in ipairs(section.rows or {}) do
            if tostring(book.bookId or book.book_id or "")==book_id then
                mutator(book)
                changed=true
            end
        end
    end
    return changed
end

function Plugin:_home_update_download_card(runtime,state)
    local book_id=tostring(runtime and runtime.book and runtime.book.bookId or state and state.book_id or "")
    if book_id=="" then return false end
    local ratio=math.max(0,math.min(1,self:_download_percent(state)/100))
    local changed=self:_home_mutate_book_rows(book_id,function(book)
        book.download_active=true
        book.download_progress=ratio
        book.download_status=nil
        book.status_text=self:_shelf_status_text(book)
    end)
    if changed and HomeView.is_shown() and not self:_active_reader_ui() then
        local updated=HomeView.update_book(book_id)
        logger.info("[MiuRead][HomeDownload] card update",
            "book=",book_id,"percent=",tostring(math.floor(ratio*100+.5)),
            "visible=",tostring(updated==true))
        return updated==true
    end
    return false
end

function Plugin:_flush_cover_index()
    if self._cover_index_flush_task then
        UIManager:unschedule(self._cover_index_flush_task)
        self._cover_index_flush_task=nil
    end
    local pending=self._cover_index_pending or {}
    if not next(pending) then return end
    local index=self.store:get("cover_index",{})
    for id,path in pairs(pending) do index[id]=path end
    self.store:set("cover_index",index)
    self._cover_index_pending={}
end

function Plugin:_remember_cover_path(id,path)
    if not id or not path then return end
    self._cover_index_pending=self._cover_index_pending or {}
    self._cover_index_pending[tostring(id)]=path
    if self._cover_index_flush_task then return end
    local task
    task=function()
        if self._cover_index_flush_task~=task then return end
        self._cover_index_flush_task=nil
        self:_flush_cover_index()
    end
    self._cover_index_flush_task=task
    UIManager:scheduleIn(.75,task)
end

function Plugin:_shelf_status_text(b)
    if b.download_status and b.download_status~="" then return b.download_status end
    if tostring(b.content_type or "")=="mp_account" then return "公众号" end
    local state
    if b.shelf_section=="generated" then
        if b.remote_status_known~=true then state="本地书籍"
        elseif b.in_account_shelf==true then state="账号书架中"
        else state="已移出账号书架 · 本地可读" end
        if b.hasClean and b.hasNotes then state=state.." · 两个版本"
        elseif b.hasNotes then state=state.." · 划线与想法版"
        elseif b.hasClean then state=state.." · 纯净版" end
    else
        state=b.downloaded and "已生成" or "未生成"
        if b.isTop then state="置顶 · "..state end
    end
    local progress=tonumber(b.progress or 0) or 0
    if progress>=100 then return state.." · 已读完" end
    if progress>0 then return state.." · "..tostring(math.floor(progress+.5)).."%" end
    return state
end

function Plugin:_shelf_select(b)
    local id=tostring(b and (b.bookId or b.book_id) or "")
    if id=="" then return end
    if Protocol.is_mp_account(id) then self:mp_account(b); return end
    local record=self:_preferred_record(id)
    if record and record.file and U.file_exists(record.file) then
        self:open_file(record.file)
    else
        self:book_menu(b)
    end
end
function Plugin:_shelf_hold(b)
    local id=tostring(b and (b.bookId or b.book_id) or "")
    if id=="" then return end
    if Protocol.is_mp_account(id) then self:mp_account(b); return end
    self:book_menu(b)
end

function Plugin:show_shelf_search_dialog(mp_mode,source_rows,section)
    section=section=="generated" and "generated" or "account"
    if not source_rows then
        local remote_books,remote_mp=self.library:cached()
        source_rows=self:_shelf_rows(section,mp_mode,remote_books,remote_mp,#remote_books+#remote_mp>0)
    end
    local d
    d=InputDialog:new{
        title=section=="generated" and "搜索已生成书籍" or "搜索账号书架",input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local q=U.trim(d:getInputText())
                UIManager:close(d)
                if q=="" then return end
                local results=self.library:search(source_rows,q)
                if #results==0 then self:info("没有找到相关书籍") return end
                self:_prepare_shelf_rows(results)
                local prefs=self.store:preferences()
                local show_covers=self:_shelf_covers_enabled(prefs)
                if show_covers then self:_begin_cover_guard("shelf_search_open") end
                local ok,view=pcall(ShelfView.show,{
                    title=(section=="generated" and "已生成书籍 · " or "账号书架 · ").."搜索 “"..q.."” · "..tostring(#results).."本",
                    books=results,
                    show_actions=false,
                    show_tabs=false,
                    show_covers=show_covers,
                    on_select=function(b) self:_shelf_select(b) end,
                    on_hold=function(b) self:_shelf_hold(b) end,
                    on_page_changed=function(page,first,last,current)
                        if show_covers then self:_on_shelf_page(results,current,page,first,last) end
                    end,
                    on_rendered=function() self:_clear_cover_guard() end,
                    on_close=function()
                        self:_cancel_cover_loading()
                        collectgarbage("step",120)
                    end,
                })
                if ok and view then return end
                self:_clear_cover_guard()
                logger.warn("[MiuRead][ShelfSearch] custom view unavailable",tostring(view))
                local items={}
                for _,book in ipairs(results) do
                    local b=book
                    items[#items+1]={
                        text=(b.downloaded and "✓ " or "")..tostring(b.title or "未命名"),
                        post_text=(tostring(b.author or "")~="" and (tostring(b.author).." · ") or "")..self:_shelf_status_text(b),
                        callback=function() self:_shelf_select(b) end,
                    }
                end
                self:list("搜索书架 · "..q,items)
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end
function Plugin:_cancel_cover_loading()
    self._cover_generation=(tonumber(self._cover_generation) or 0)+1
    if self.cover_async then self.cover_async:cancel("shelf page changed") end
    if self._cover_refresh_task then
        UIManager:unschedule(self._cover_refresh_task)
        self._cover_refresh_task=nil
    end
    self:_clear_cover_guard()
end
function Plugin:_schedule_shelf_cover_refresh(view,generation,delay)
    if self._cover_refresh_task then return end
    local task
    task=function()
        if self._cover_refresh_task~=task then return end
        self._cover_refresh_task=nil
        if generation~=self._cover_generation or not view or view._miu_closed then return end
        self:_begin_cover_guard("shelf_cover_refresh")
        view._suppress_page_callback=true
        local ok,err=pcall(view.updateItems,view,nil,true)
        view._suppress_page_callback=false
        if ok then
            self:_clear_cover_guard()
            collectgarbage("step",160)
        else
            self._cover_safe_mode=true
            logger.warn("[MiuRead][Cover] shelf refresh failed",tostring(err))
        end
    end
    self._cover_refresh_task=task
    UIManager:scheduleIn(delay or .18,task)
end
function Plugin:_schedule_cover_continue(rows,view,page,first,last,generation,index,delay)
    UIManager:scheduleIn(delay or .06,function()
        self:_cache_shelf_page_covers(rows,view,page,first,last,generation,index)
    end)
end
function Plugin:_cache_shelf_page_covers(rows,view,page,first,last,generation,index)
    index=index or first
    if generation~=self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1)~=tonumber(page) then return end
    if index>last then return end
    local book=rows[index]
    if not book or not book.cover or book.cover=="" then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,.04)
        return
    end
    local cached=book.cover_path or self.library:cached_cover_path(book.bookId)
    if cached then
        book.cover_path=cached
        local changed=false
        for _,entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id)==tostring(book.bookId) then
                if entry.cover_path~=cached then entry.cover_path=cached; changed=true end
                break
            end
        end
        if changed then self:_schedule_shelf_cover_refresh(view,generation,.12) end
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,.04)
        return
    end
    if not self.cover_async then return end
    if self.cover_async:busy() then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index,.25)
        return
    end
    local background_available=self.cover_async:available()
    local download_options=background_available
        and {retries=1,timeout={8,15}}
        or {retries=0,timeout={4,7}}
    local book_copy={bookId=book.bookId,cover=book.cover}
    local worker
    if background_available then
        local covers_dir=self.store.covers_dir
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
            local http=HttpChild:new(store)
            local options={
                retries=download_options.retries,
                timeout=download_options.timeout,
                persist_index=false,
                skip_index_lookup=true,
            }
            return LibraryChild:new(nil,http,store):cache_cover(book_copy,options)
        end
    else
        worker=function() return self.library:cache_cover(book_copy,download_options) end
    end
    local started=self.cover_async:run("shelf_cover_page",worker,function(result)
        if generation~=self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1)~=tonumber(page) then return end
        if result and result.ok and result.value then
            if background_available then self:_remember_cover_path(book.bookId,result.value) end
            book.cover_path=result.value
            for _,entry in ipairs(view.item_table or {}) do
                if tostring(entry.book_id)==tostring(book.bookId) then entry.cover_path=result.value; break end
            end
            self:_schedule_shelf_cover_refresh(view,generation,.18)
        elseif result and result.error then
            logger.warn("[MiuRead][Cover] download failed","book_id=",tostring(book.bookId),
                "error=",U.first_line(result.error,160))
        end
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,background_available and .06 or .18)
    end,background_available and 35 or 14)
    if not started then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index,.3)
    end
end
function Plugin:_on_shelf_page(rows,view,page,first,last)
    self:_cancel_cover_loading()
    local generation=self._cover_generation
    self:_cache_shelf_page_covers(rows,view,page,first,last,generation,first)
end
function Plugin:_cancel_shelf_refresh(reason)
    self._miuread_shelf_refresh_generation=(tonumber(self._miuread_shelf_refresh_generation) or 0)+1
    self._shelf_main_busy=false
    if self.shelf_async then self.shelf_async:cancel(reason or "shelf closed") end
end

function Plugin:_close_current_shelf()
    local view=self._shelf_view
    self._shelf_view=nil
    self:_cancel_cover_loading()
    self:_cancel_shelf_refresh("shelf replaced")
    if view and not view._miu_closed then pcall(function() UIManager:close(view) end) end
end
function Plugin:_reopen_shelf(mp_mode,section,force_remote)
    section=section=="generated" and "generated" or "account"
    self:_save_shelf_context(section,mp_mode)
    UIManager:scheduleIn(0,function()
        self:_close_current_shelf()
        self:show_shelf(mp_mode,force_remote,section)
    end)
end

function Plugin:_shelf_tabs(selected)
    return {
        {id="books",label="书籍",callback=function()
            if selected~="books" then self:_reopen_shelf(false,"account") end
        end},
        {id="mp",label="公众号",callback=function()
            if selected~="mp" then self:_reopen_shelf(true,"account") end
        end},
        {id="generated",label="已生成",callback=function()
            if selected~="generated" then self:_reopen_shelf(false,"generated") end
        end},
    }
end

function Plugin:_refresh_mp_accounts(on_done,silent)
    if not self:logged_in() then
        if not silent then self.auth_flow:start() end
        if on_done then on_done(nil,"尚未登录") end
        return false
    end
    if not self:is_online() then
        if on_done then on_done(nil,"网络不可用") end
        if not silent then self:info(_("Network unavailable")) end
        return false
    end
    if self.mp_async:busy() then
        if on_done then on_done(nil,"另一项公众号任务正在进行中") end
        if not silent then self:info("另一项公众号任务正在进行中。") end
        return false
    end
    if not silent then self:status_toast("公众号","正在获取公众号列表",2) end
    local started,err=self.mp_async:run("mp-accounts",function()
        return self.mp:accounts({force=true})
    end,function(result)
        self.store:reload()
        if result and result.ok and type(result.value)=="table" then
            if on_done then on_done(result.value,nil) end
        else
            local cached=self.mp:cached_accounts()
            local message=result and result.error or "公众号列表加载失败"
            logger.warn("[MiuRead][MP] account list refresh failed",tostring(message))
            if on_done then on_done(#cached>0 and cached or nil,message) end
        end
    end,60)
    if not started then
        if on_done then on_done(nil,err or "无法启动公众号列表任务") end
        if not silent then self:info(self:_friendly_remote_error(err or "无法启动公众号列表任务","公众号列表加载")) end
    end
    return started
end

function Plugin:show_mp_shelf(force_remote)
    self:_save_shelf_context("account", true)

    local function render(accounts, remote_error)
        accounts = type(accounts) == "table" and accounts or {}
        local rows = {}
        for _, account in ipairs(accounts) do
            local row = self:_mp_normalize_book(account)
            if Protocol.is_mp_account(row.bookId) then
                row.content_type = "mp_account"
                row.author = row.author ~= "" and row.author or "公众号"
                row.status_text = "点击查看文章"
                row.show_cover = false
                rows[#rows + 1] = row
            end
        end

        local function refresh()
            self:_refresh_mp_accounts(function(value, err)
                if value then self:show_mp_shelf(false)
                elseif err then self:info(self:_friendly_remote_error(err, "公众号列表加载")) end
            end, false)
        end

        local function search()
            local dialog
            dialog = InputDialog:new{
                title="搜索公众号", input="",
                buttons={{
                    {text=_("Cancel"), id="close", callback=function() UIManager:close(dialog) end},
                    {text=_("Search"), is_enter_default=true, callback=function()
                        local query=U.trim(dialog:getInputText()):lower()
                        UIManager:close(dialog)
                        if query=="" then return end
                        local found={}
                        for _, row in ipairs(rows) do
                            local hay=(tostring(row.title or "").." "..tostring(row.author or "")):lower()
                            if hay:find(query,1,true) then found[#found+1]=row end
                        end
                        if #found==0 then self:info("没有找到相关公众号")
                        elseif #found==1 then self:mp_account(found[1])
                        else
                            local items={}
                            for _, row in ipairs(found) do
                                local account=row
                                items[#items+1]={text=account.title,post_text=account.author,callback=function() self:mp_account(account) end}
                            end
                            self:list("公众号 · 搜索结果",items)
                        end
                    end},
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end

        if #rows == 0 then
            local items={
                {text="书籍",callback=function() self:_reopen_shelf(false,"account") end},
                {text="公众号",enabled=false},
                {text="已生成",callback=function() self:_reopen_shelf(false,"generated") end},
                {text="刷新公众号",enabled=self:logged_in(),callback=refresh},
            }
            if not self:logged_in() then
                items[#items+1]={text="扫码登录",callback=function() self.auth_flow:start() end}
            end
            if remote_error then
                items[#items+1]={text=self:_friendly_remote_error(remote_error,"公众号列表加载"),enabled=false}
            else
                items[#items+1]={text="仅显示微信读书书架返回的公众号",enabled=false}
            end
            self:list("我的书架 · 公众号",items,"暂未识别到公众号")
            return
        end

        local ok, view = pcall(ShelfView.show, {
            title="我的书架 · 公众号 · "..tostring(#rows).."个",
            books=rows, selected_tab="mp", tabs=self:_shelf_tabs("mp"),
            show_covers=false, on_search=search, on_refresh=refresh,
            on_select=function(book) self:mp_account(book) end,
            on_close=function(current)
                if self._shelf_view==current then self._shelf_view=nil end
            end,
        })
        if ok and view then self._shelf_view=view; return end
        logger.warn("[MiuRead][MP] shelf view unavailable",tostring(view))
        local items={
            {text="书籍",callback=function() self:_reopen_shelf(false,"account") end},
            {text="公众号",enabled=false},
            {text="已生成",callback=function() self:_reopen_shelf(false,"generated") end},
            {text="搜索",callback=search},
            {text="刷新公众号",callback=refresh},
        }
        for _,row in ipairs(rows) do
            local account=row
            items[#items+1]={text=account.title,post_text=account.author,callback=function() self:mp_account(account) end}
        end
        self:list("我的书架 · 公众号",items)
    end

    local cached=self.mp:cached_accounts()
    if not force_remote and #cached>0 then
        render(cached,nil)
        if self.mp:accounts_stale() and self:logged_in() and self:is_online() and not self.mp_async:busy() then
            self:_refresh_mp_accounts(function(value)
                if value and self._shelf_view and not self._shelf_view._miu_closed then
                    self:_reopen_shelf(true,"account")
                end
            end,true)
        end
        return
    end
    self:_refresh_mp_accounts(function(value,err)
        if value then render(value,err) else render(cached,err) end
    end,false)
end

function Plugin:show_shelf(mp_mode,force_remote,section)
    local prefs=self.store:preferences()
    section=section or prefs.shelf_section or "account"
    section=section=="generated" and "generated" or "account"
    if mp_mode==nil then mp_mode=tostring(prefs.account_shelf_kind or "books")=="mp" end
    self:_save_shelf_context(section,mp_mode)
    if section=="account" and mp_mode==true then
        return self:show_mp_shelf(force_remote==true)
    end
    self:load_shelf(function(remote_books,remote_mp,remote_error)
        local remote_known=remote_error==nil and (self:logged_in() or (#remote_books+#remote_mp)>0)
        local all_rows=self:_shelf_rows(section,mp_mode,remote_books,remote_mp,remote_known)
        local rows=self.library:sort_filter(all_rows,{section=section})
        self:_prepare_shelf_rows(rows)
        local show_covers=self:_shelf_covers_enabled(self.store:preferences())
        local title=section=="generated" and "已生成书籍" or (mp_mode and "公众号" or "账号书架")
        if remote_error and #rows>0 then self:toast(remote_error,3) end
        local function open_account()
            if section=="account" and not mp_mode then return end
            self:_reopen_shelf(false,"account")
        end
        local function open_generated()
            if section=="generated" then return end
            self:_reopen_shelf(mp_mode,"generated")
        end
        local function refresh()
            if not self:logged_in() then self.auth_flow:start(); return end
            self:_reopen_shelf(mp_mode,section,true)
        end
        if #rows==0 then
            local items={
                {text=(section=="account" and "✓ " or "").."书籍",callback=open_account},
                {text="公众号",callback=function() self:_reopen_shelf(true,"account") end},
                {text=(section=="generated" and "✓ " or "").."已生成",callback=open_generated},
                {text="搜索",callback=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end},
                {text="刷新书架",enabled=self:logged_in(),callback=refresh},
            }
            if not self:logged_in() then items[#items+1]={text="扫码登录",callback=function() self.auth_flow:start() end} end
            if remote_error then table.insert(items,3,{text=remote_error,enabled=false}) end
            self:list(title,items,"书架为空")
            return
        end
        if show_covers then self:_begin_cover_guard("shelf_open") end
        local ok,view=pcall(ShelfView.show,{
            title="我的书架 · "..(section=="generated" and "已生成" or "书籍").." · "..tostring(#rows).."本",
            books=rows,selected_tab=section=="generated" and "generated" or "books",
            tabs=self:_shelf_tabs(section=="generated" and "generated" or "books"),
            show_covers=show_covers,
            on_search=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end,
            on_refresh=refresh,on_select=function(b) self:_shelf_select(b) end,
            on_hold=function(b) self:_shelf_hold(b) end,
            on_page_changed=function(page,first,last,current)
                if show_covers then self:_on_shelf_page(rows,current,page,first,last) end
            end,
            on_rendered=function() self:_clear_cover_guard() end,
            on_close=function(current)
                if self._shelf_view==current then self._shelf_view=nil end
                self:_cancel_cover_loading(); self:_cancel_shelf_refresh("shelf closed"); collectgarbage("step",160)
            end,
        })
        if ok and view then self._shelf_view=view; return end
        self:_clear_cover_guard()
        logger.warn("[MiuRead][Shelf] custom view unavailable",tostring(view))
        local items={
            {text=(section=="account" and "✓ " or "").."书籍",callback=open_account},
            {text="公众号",callback=function() self:_reopen_shelf(true,"account") end},
            {text=(section=="generated" and "✓ " or "").."已生成",callback=open_generated},
            {text="搜索",callback=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end},
            {text="刷新书架",enabled=self:logged_in(),callback=refresh},
        }
        for _,b in ipairs(rows) do local book=b; items[#items+1]={text=book.title,post_text=self:_shelf_status_text(book),callback=function() self:_shelf_select(book) end} end
        self:list(title,items)
    end,force_remote,section)
end




local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
