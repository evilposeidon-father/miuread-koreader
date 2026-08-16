-- MiuRead search + 公众号(MP) controller, split from main.lua.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local U = require("miuread.util")
local Text = require("miuread.text")
local Protocol = require("miuread.protocol")
local GestureBridge = require("miuread.gesture_bridge")
local RawButtonDialog = require("ui/widget/buttondialog")
local RawConfirmBox = require("ui/widget/confirmbox")
local RawInputDialog = require("ui/widget/inputdialog")

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

local _ = Text.tr

-- Mirrors main.lua's local normalize; book_details stays in main.lua and keeps
-- its own copy there.
local function normalize(v) local b=v.bookInfo or v.book or v; return {bookId=tostring(b.bookId or v.bookId or ""),title=b.title or v.title or "未命名",author=b.author or v.author or "",cover=b.cover or v.cover,category=b.category or v.category,progress=tonumber(v.progress or b.progress or 0) or 0,updateTime=tonumber(v.updateTime or b.updateTime or 0) or 0} end

local Plugin = {}

function Plugin:search_dialog(title)
    if not self:require_login() then return end
    local d
    d=InputDialog:new{
        title=tostring(title or _("Search books")), input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local q=U.trim(d:getInputText())
                UIManager:close(d)
                if q~="" then self:search(q) end
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end

function Plugin:_cancel_search(reason)
    self._search_generation=(tonumber(self._search_generation) or 0)+1
    if self.search_async then self.search_async:cancel(reason or "cancelled") end
    local dialog=self._search_dialog
    self._search_dialog=nil
    if dialog then pcall(UIManager.close,UIManager,dialog) end
end

function Plugin:search(q)
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    if self.search_async and self.search_async:busy() then self:_cancel_search("new_search") end

    self._search_generation=(tonumber(self._search_generation) or 0)+1
    local generation=self._search_generation
    local closing=false
    local dialog
    dialog=ButtonDialog:new{
        title="正在搜索《"..tostring(q).."》……\n\n可按返回键或点击取消。",
        title_align="center",
        close_callback=function()
            if closing then return end
            closing=true
            if generation==self._search_generation and self.search_async then
                self.search_async:cancel("search_dialog_closed")
                self._search_generation=self._search_generation+1
            end
            self._search_dialog=nil
        end,
        buttons={
            {{text="取消搜索",callback=function()
                if closing then return end
                closing=true
                if generation==self._search_generation and self.search_async then
                    self.search_async:cancel("user_cancelled")
                end
                self._search_generation=self._search_generation+1
                self._search_dialog=nil
                UIManager:close(dialog)
            end}},
        },
    }
    self._search_dialog=dialog
    UIManager:show(dialog)

    local function finish(result)
        if generation~=self._search_generation then return end
        closing=true
        self._search_dialog=nil
        UIManager:close(dialog)
        if not result or result.ok~=true then
            self:info(self:_friendly_remote_error(result and result.error or "未知错误","搜索"))
            return
        end
        local data=result.value or {}
        local items={}
        local function add(r)
            local b=normalize(r)
            if b.bookId~="" then
                items[#items+1]={text=b.title,post_text=b.author,callback=function() self:book_menu(b) end}
            end
        end
        for _,g in ipairs(data.results or data.books or {}) do
            if g.books then for _,r in ipairs(g.books) do add(r) end else add(g) end
        end
        self:list(_("Search").." · "..q,items,"没有找到相关书籍")
    end

    local function run_on_main_thread()
        UIManager:scheduleIn(.10,function()
            if generation~=self._search_generation then return end
            local ok,value=xpcall(function() return self.api:search(q,0,40) end,debug.traceback)
            finish(ok and {ok=true,value=value} or {ok=false,error=tostring(value)})
        end)
    end

    if not self.search_async or not self.search_async:available() then
        run_on_main_thread()
        return
    end

    local auth=U.copy(self.store:auth())
    local started,err=self.search_async:run("book_search",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local UtilChild=require("miuread.util")
        local child_store={
            auth=function() return UtilChild.copy(auth) end,
            save_auth=function() end,
        }
        local api=ApiChild:new(HttpChild:new(child_store),child_store)
        return api:search(q,0,40)
    end,finish,32)
    if not started then
        logger.warn("[MiuRead][Search] async unavailable; falling back",tostring(err or "worker busy"))
        run_on_main_thread()
    end
end
function Plugin:_variant_exists(book_id,kind)
    local r=self.store:variant(book_id,kind)
    return r and r.file and U.file_exists(r.file) and r or nil
end
function Plugin:_book_has_cache(book_id)
    local stored=self.store:book(book_id)
    if not stored then return false end
    for _,r in pairs(stored.variants or {}) do if r.file and U.file_exists(r.file) then return true end end
    for _,row in pairs(stored.chapters or {}) do for _,r in pairs(row or {}) do if r.file and U.file_exists(r.file) then return true end end end
    return false
end
function Plugin:_preferred_record(book_id)
    local session=self.store:session(book_id) or {}
    local last=tostring(session.last_read_path or "")
    local b=self.store:book(book_id)
    local fallback
    if not b then return nil end
    local function consider(record)
        if type(record)~="table" or not record.file then return end
        if tostring(record.file)==last or tostring(record.original_file or "")==last then fallback=record; return true end
        if not fallback then fallback=record end
    end
    for _,kind in ipairs({"notes","clean","range_notes","range_clean","preview_notes","preview_clean"}) do
        if consider(b.variants and b.variants[kind]) then return fallback end
    end
    for _,row in pairs(b.chapters or {}) do
        for _,kind in ipairs({"notes","clean","range_notes","range_clean","preview_notes","preview_clean"}) do
            if consider(row and row[kind]) then return fallback end
        end
    end
    return fallback
end
local function mp_date(value)
    value=tonumber(value or 0) or 0
    return value>0 and os.date("%Y-%m-%d",value) or ""
end

function Plugin:_mp_normalize_book(book)
    local original=type(book)=="table" and book or {}
    local normalized=U.merge(original,normalize(original))
    normalized.bookId=tostring(normalized.bookId or normalized.book_id or "")
    return normalized
end

function Plugin:_refresh_mp_articles(book,silent,on_done)
    book=self:_mp_normalize_book(book)
    if not self:logged_in() then
        if not silent then self.auth_flow:start() end
        if on_done then on_done(nil,"尚未登录") end
        return false
    end
    if not self:is_online() then
        if not silent then self:info(_("Network unavailable")) end
        if on_done then on_done(nil,"网络不可用") end
        return false
    end
    if self.mp_async:busy() then
        if not silent then self:info("另一项公众号任务正在进行中。") end
        return false
    end
    if not silent then self:status_toast("公众号","正在刷新文章列表",2) end
    local book_copy=U.copy(book)
    local started,err=self.mp_async:run("mp-articles",function()
        return self.mp:articles(book_copy.bookId,{force=true,title=book_copy.title})
    end,function(result)
        self.store:reload()
        if result and result.ok and type(result.value)=="table" then
            if on_done then on_done(result.value,nil) end
            if not silent then self:show_mp_articles(book_copy,result.value) end
        else
            local cached=self.mp:cached_articles(book_copy.bookId)
            local message=result and result.error or "文章列表刷新失败"
            logger.warn("[MiuRead][MP] article list refresh failed",tostring(message))
            if on_done then on_done(#cached>0 and cached or nil,message) end
            if not silent then
                if #cached>0 then self:toast("刷新失败，继续显示本地文章列表",3); self:show_mp_articles(book_copy,cached)
                else self:info(self:_friendly_remote_error(message,"公众号文章列表加载")) end
            end
        end
    end,75)
    if not started and not silent then self:info(self:_friendly_remote_error(err or "无法启动文章列表任务","公众号文章列表加载")) end
    return started
end

function Plugin:mp_account(book)
    book=self:_mp_normalize_book(book)
    if not Protocol.is_mp_account(book.bookId) then
        self:info("微信读书书架没有返回可用的公众号。")
        return
    end
    book.content_type="mp_account"
    self.store:save_book(book.bookId,{
        book_id=book.bookId,title=book.title,author=book.author,cover=book.cover,
        content_type="mp_account",updated_at=os.time(),
    })
    local cached=self.mp:cached_articles(book.bookId)
    if #cached>0 then
        self:show_mp_articles(book,cached)
        if self.mp:list_stale(book.bookId) and self:logged_in() and self:is_online() and not self.mp_async:busy() then
            self:_refresh_mp_articles(book,true)
        end
    else
        self:_refresh_mp_articles(book,false)
    end
end

function Plugin:open_mp_account_by_id(book_id,title)
    local found
    local accounts=self.mp:cached_accounts()
    for _,book in ipairs(accounts or {}) do
        if tostring(book.bookId or book.book_id)==tostring(book_id) then found=book; break end
    end
    if not found then
        local _,cached_mp=self.library:cached()
        for _,book in ipairs(cached_mp or {}) do
            if tostring(book.bookId or book.book_id)==tostring(book_id) then found=book; break end
        end
    end
    found=found or {bookId=book_id,title=title or "公众号",author="公众号",content_type="mp_account"}
    self:mp_account(found)
end

function Plugin:show_mp_articles(book,articles,title_suffix)
    book=self:_mp_normalize_book(book)
    articles=type(articles)=="table" and articles or {}
    local items={
        {text="搜索文章",callback=function() self:mp_search_dialog(book,articles) end},
        {text="刷新文章列表",post_text="最近 100 篇",callback=function() self:_refresh_mp_articles(book,false) end},
        {text="管理本号缓存",callback=function()
            self:list("缓存管理 · "..tostring(book.title or "公众号"),self:mp_cache_menu(book,self.mp:cached_articles(book.bookId)),"暂无缓存")
        end},
    }
    for _,row in ipairs(articles) do
        local article=U.copy(row)
        local record=self.mp:article_record(book.bookId,article)
        local post=mp_date(article.createTime)
        if record then post=(post~="" and (post.." · ") or "").."已缓存" end
        items[#items+1]={
            text=tostring(article.title or "文章"),post_text=post,
            callback=function() self:open_or_download_mp_article(book,article) end,
        }
    end
    local title=tostring(book.title or "公众号").." · "..tostring(#articles).."篇"
    if title_suffix then title=title.." · "..tostring(title_suffix) end
    self:list(title,items,"暂无文章")
end

function Plugin:mp_search_dialog(book,articles)
    local dialog
    dialog=InputDialog:new{
        title="搜索本号文章",input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(dialog) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local query=U.trim(dialog:getInputText()):lower()
                UIManager:close(dialog)
                if query=="" then return end
                local results={}
                for _,article in ipairs(articles or {}) do
                    if tostring(article.title or ""):lower():find(query,1,true) then results[#results+1]=article end
                end
                if #results==0 then self:info("没有找到相关文章") else self:show_mp_articles(book,results,"搜索结果") end
            end},
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Plugin:_close_mp_download_dialog()
    local dialog=self._mp_download_dialog
    self._mp_download_dialog=nil
    if dialog then pcall(function() UIManager:close(dialog) end) end
end

function Plugin:_start_mp_article_download(book,article,force)
    if self.mp_async:busy() then self:info("另一项公众号任务正在进行中。") return false end
    local title=tostring(article.title or "文章")
    local cancelled=false
    local dialog
    dialog=ButtonDialog:new{
        title="正在下载公众号文章\n\n"..title.."\n\n文章通常较小，下载完成后会自动打开。",
        title_align="left",
        buttons={{{text="取消下载",callback=function()
            cancelled=true
            if self.mp_async and self.mp_async:busy() then self.mp_async:cancel("user_cancelled") end
            self:_close_mp_download_dialog()
            self:status_toast("公众号","已取消下载",3)
        end}}},
    }
    self._mp_download_dialog=dialog
    UIManager:show(dialog)

    local book_copy,article_copy=U.copy(book),U.copy(article)
    local prefs=self.store:preferences()
    local started,err=self.mp_async:run("mp-article",function()
        return self.mp:fetch_article(book_copy,article_copy,{images=prefs.mp_images==true,force=force==true})
    end,function(result)
        self:_close_mp_download_dialog()
        if cancelled then return end
        self.store:reload()
        if result and result.ok and type(result.value)=="table" and result.value.file then
            self:open_file(result.value.file)
            return
        end
        local fallback=self.mp:article_record(book_copy.bookId,article_copy)
        if fallback then
            self:status_toast("公众号","下载未完整完成，已打开原缓存",4)
            self:open_file(fallback.file)
        else
            logger.warn("[MiuRead][MP] article download failed",tostring(result and result.error))
            self:info("文章下载失败：\n"..U.first_line(result and result.error or "未知错误",180))
        end
    end,120)
    if not started then
        self:_close_mp_download_dialog()
        self:info("无法启动文章下载：\n"..tostring(err))
        return false
    end
    return true
end

function Plugin:open_or_download_mp_article(book,article,force)
    local record=self.mp:article_record(book.bookId,article)
    if record and force~=true then self:open_file(record.file); return end
    if not self:require_login() then return end
    if not self:is_online() then
        if record then self:open_file(record.file) else self:info(_("Network unavailable")) end
        return
    end
    if force==true then
        self:_start_mp_article_download(book,article,true)
        return
    end
    UIManager:show(ConfirmBox:new{
        text="《"..tostring(article.title or "文章").."》尚未缓存。\n\n是否下载并打开？公众号文章通常只需几秒。",
        ok_text="下载并打开",
        ok_callback=function() self:_start_mp_article_download(book,article,false) end,
    })
end

function Plugin:mp_cache_menu(book,articles)
    local items={}
    local cached_count=0
    for _,article in ipairs(articles or {}) do
        if self.mp:article_record(book.bookId,article) then cached_count=cached_count+1 end
    end
    items[#items+1]={text="已缓存文章",post_text=tostring(cached_count).." 篇",enabled=false}
    for _,row in ipairs(articles or {}) do
        local article=U.copy(row)
        if self.mp:article_record(book.bookId,article) then
            items[#items+1]={text=tostring(article.title or "文章"),post_text=mp_date(article.createTime),callback=function()
                self:mp_article_cache_menu(book,article)
            end}
        end
    end
    items[#items+1]={text="清理本号文章缓存",callback=function()
        UIManager:show(ConfirmBox:new{text="清理《"..tostring(book.title or "公众号").."》的文章列表和单篇缓存？",ok_callback=function()
            local ok,err=self.mp:clear_account(book.bookId)
            if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
            self:status_toast("公众号","本号缓存已清理",4)
            UIManager:scheduleIn(.15,function() self:show_mp_articles(book,articles,"缓存已清理") end)
        end})
    end}
    return items
end

function Plugin:mp_article_cache_menu(book,article)
    local items={
        {text="打开文章",callback=function() self:open_or_download_mp_article(book,article) end},
        {text="重新下载文章",callback=function() self:open_or_download_mp_article(book,article,true) end},
        {text="删除单篇缓存",callback=function()
            UIManager:show(ConfirmBox:new{text="删除《"..tostring(article.title or "文章").."》的单篇缓存？",ok_callback=function()
                local ok,err=self.mp:clear_article(book.bookId,article)
                if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
                self:status_toast("公众号","本篇缓存已删除",4)
                UIManager:scheduleIn(.15,function()
                    self:list("缓存管理 · "..tostring(book.title or "公众号"),self:mp_cache_menu(book,self.mp:cached_articles(book.bookId)),"暂无缓存")
                end)
            end})
        end},
    }
    self:list(article.title or "文章",items)
end

function Plugin:mp_global_cache_menu()
    return {
        {text="清理全部公众号缓存",callback=function()
            UIManager:show(ConfirmBox:new{text="清理全部公众号列表和单篇文章缓存？",ok_callback=function()
                local ok,err=U.remove_tree(self.store:mp_root())
                if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
                if not U.mkdir(self.store:mp_root()) then self:info("缓存目录重建失败，请重启 KOReader。") return end
                self:status_toast("公众号","全部缓存已清理",4)
            end})
        end},
    }
end

function Plugin:open_mp_neighbor(delta)
    local context=self.mp:identify_path(self:_current_document_path())
    if not context then self:info("当前不是觅阅公众号文章。") return end
    local articles=self.mp:cached_articles(context.bookId)
    local index
    for i,article in ipairs(articles or {}) do
        if tostring(article.reviewId or article.originalId)==tostring(context.reviewId) then index=i; break end
    end
    if not index then self:info("本地文章列表中找不到当前位置。") return end
    local target=articles[index+(tonumber(delta) or 0)]
    if not target then self:toast((delta or 0)<0 and "已经是第一篇" or "已经是最后一篇",2); return end
    self:open_or_download_mp_article({bookId=context.bookId,title=context.account_title or "公众号",author="公众号"},target)
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
