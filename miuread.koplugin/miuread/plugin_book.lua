-- MiuRead book popup menu / details controller, split from main.lua.
local U = require("miuread.util")
local Protocol = require("miuread.protocol")

-- Mirrors main.lua's local normalize; main.lua keeps its copy for shelf code.
local function normalize(v) local b=v.bookInfo or v.book or v; return {bookId=tostring(b.bookId or v.bookId or ""),title=b.title or v.title or "未命名",author=b.author or v.author or "",cover=b.cover or v.cover,category=b.category or v.category,progress=tonumber(v.progress or b.progress or 0) or 0,updateTime=tonumber(v.updateTime or b.updateTime or 0) or 0} end

local Plugin = {}

function Plugin:book_menu(b)
    local original=type(b)=="table" and b or {}
    b=U.merge(original,normalize(original))
    if Protocol.is_mp_account(b.bookId) then self:mp_account(b); return end
    local items={}
    local records={{kind="clean",label="纯净版"},{kind="notes",label="划线与想法版"},
        {kind="range_clean",label="章节版 · 纯净版"},{kind="range_notes",label="章节版 · 划线与想法版"},
        {kind="preview_clean",label="试读版 · 纯净版"},{kind="preview_notes",label="试读版 · 划线与想法版"}}
    for _,entry in ipairs(records) do
        local record=self:_variant_exists(b.bookId,entry.kind)
        if record then
            items[#items+1]={text="打开"..entry.label,callback=function() self:open_file(record.file) end}
        end
    end
    items[#items+1]={text="生成／更新书籍",callback=function() self:choose_download(b,nil,false) end}
    items[#items+1]={text="按章节下载",callback=function() self:chapters(b) end}
    if self:_has_range_variant(b.bookId) then
        items[#items+1]={text="扩展已有章节版",sub_item_table_func=function() return self:range_extend_menu(b) end}
    end
    if self:_book_has_cache(b.bookId) or self.store:book_has_partial_cache(b.bookId) then
        items[#items+1]={text="管理本书文件",callback=function() self:downloaded_book_menu(tostring(b.bookId)) end}
    end
    items[#items+1]={text="书籍详情",callback=function() self:book_details(b) end}
    self:list(b.title,items)
end

function Plugin:book_details(b)
    b=U.copy(b or {})
    local id=tostring(b.bookId or b.book_id or "")
    if id=="" then self:info("当前书籍缺少可查询的图书编号。") return false end
    local auth=U.copy(self.store:auth())
    local data_dir,temp_dir=self.store.data_dir,self.store.temp_dir
    local context=self:_interactive_network_context()
    return self:_run_interactive_network("book-details:"..id,"details",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local child_store=interactive_child_store(auth,data_dir,temp_dir)
        local child_api=ApiChild:new(HttpChild:new(child_store),child_store)
        local request_ok,detail=pcall(child_api.book,child_api,id)
        local child_auth,auth_changed=child_store:snapshot()
        return {request_ok=request_ok,detail=request_ok and detail or nil,error=request_ok and nil or tostring(detail),
            auth=child_auth,auth_changed=auth_changed}
    end,function(result)
        if not result or result.ok~=true then
            self:info(self:_friendly_remote_error(result and result.error or "未知错误","书籍详情加载"))
            return
        end
        local payload=type(result.value)=="table" and result.value or {}
        if payload.auth_changed==true then self:_apply_interactive_auth{auth=payload.auth,changed=true} end
        if payload.request_ok~=true then
            self:info(self:_friendly_remote_error(payload.error or "未知错误","书籍详情加载"))
            return
        end
        local x=type(payload.detail)=="table" and payload.detail or {}
        local z=normalize(x)
        local title=z.title~="" and z.title or tostring(b.title or "书籍详情")
        local author=z.author~="" and z.author or tostring(b.author or "")
        self:info(title.."\n"..author.."\n\n"..tostring(x.intro or x.description or b.intro or b.description or "暂无简介"))
    end,{context=context,timeout=28,status_title="书籍详情",status_text="正在后台获取书籍信息…"})
end


local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
