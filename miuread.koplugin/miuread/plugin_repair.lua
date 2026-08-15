-- MiuRead repair / migration controller, split from main.lua.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local U = require("miuread.util")
local Text = require("miuread.text")
local BookIntegrity = require("miuread.book_integrity")
local DownloadDatabase = require("miuread.download_database")
local MigrationProgress = require("miuread.migration_progress")
local Thoughts = require("miuread.thoughts")
local Lazy = require("miuread.lazy")
local GestureBridge = require("miuread.gesture_bridge")
local RawButtonDialog = require("ui/widget/buttondialog")
local RawConfirmBox = require("ui/widget/confirmbox")

local function gesture_aware_class(base, attributes)
    local class = base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ButtonDialog = gesture_aware_class(RawButtonDialog, {_miuread_transient=true, _miuread_modal_surface=true})
local ConfirmBox = gesture_aware_class(RawConfirmBox, {_miuread_transient=true, _miuread_modal_surface=true})

local ThoughtNativePopup = Lazy("miuread.thought_native_popup")
local _ = Text.tr

local Plugin = {}

function Plugin:redownload_current()
    local r=self:_current_book_record()
    if not r or not r.book then self:info(_("No matching MiuRead book is open.")); return end
    local b={bookId=r.book.book_id,title=r.book.title,author=r.book.author,cover=r.book.cover}
    local dialog
    local buttons={}
    buttons[#buttons+1]={{text="生成纯净版",callback=function() UIManager:close(dialog); self:choose_download_mode(b,{annotations=false},false) end}}
    buttons[#buttons+1]={{text="生成划线与想法版",callback=function() UIManager:close(dialog); self:choose_download_mode(b,{annotations=true},false) end}}
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title="重新生成《"..tostring(b.title or "本书").."》",title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:_repair_preferences()
    local preferences=self.store:preferences()
    preferences.repair=type(preferences.repair)=="table" and preferences.repair or {}
    if preferences.repair.auto_check==nil then preferences.repair.auto_check=true end
    return preferences.repair,preferences
end

function Plugin:_repair_context(current)
    if type(current)=="table" and current.book then
        return {
            book=current.book,
            record=current.record or {},
            variant=current.variant,
            path=current.path,
            title=current.book and current.book.title,
        }
    end
    local row=self:_current_book_record()
    if not row then return nil end
    return {
        book=row.book,
        record=row.record or {},
        variant=row.variant,
        path=row.path,
        title=row.book and row.book.title,
    }
end

function Plugin:_repair_state()
    local state=self.store:get("book_repair_state",{})
    return type(state)=="table" and state or {}
end

function Plugin:_save_repair_state(book_id,row)
    local state=self:_repair_state()
    state[tostring(book_id or "")]=row
    self.store:set("book_repair_state",state)
end

function Plugin:_record_repair_history(result,status)
    local history=self.store:get("book_repair_history",{})
    if type(history)~="table" then history={} end
    table.insert(history,1,{
        at=os.time(),
        title=tostring(result and result.title or "书籍"),
        book_id=tostring(result and result.book_id or ""),
        status=tostring(status or ((result and result.ok) and "已完成" or "失败")),
    })
    while #history>20 do table.remove(history) end
    self.store:set("book_repair_history",history)
end

function Plugin:_repair_message(report)
    local lines={"检测到本书仍有旧版 JSON 想法与评论数据。"}
    lines[#lines+1]=""
    lines[#lines+1]="迁移后将直接使用 SQLite，旧评论索引不再需要。"
    lines[#lines+1]="迁移不会重新下载书籍，也不会改动 EPUB 正文。"
    if tonumber(report and report.pending or 0)>0 then
        lines[#lines+1]=""
        lines[#lines+1]="待迁移章节："..tostring(report.pending)
    end
    return table.concat(lines,"\n")
end

function Plugin:_close_migration_progress(token)
    if token and self._migration_token~=token then return end
    if self._migration_progress_poll then
        UIManager:unschedule(self._migration_progress_poll)
        self._migration_progress_poll=nil
    end
    if self._migration_progress_delay then
        UIManager:unschedule(self._migration_progress_delay)
        self._migration_progress_delay=nil
    end
    if self._migration_progress_widget then
        self._migration_progress_widget:close()
        self._migration_progress_widget=nil
    end
    local active_token=self._migration_token
    if active_token then DownloadDatabase.clear_task(DownloadDatabase.runtime_path(self.store),active_token) end
    self._migration_token=nil
end

function Plugin:_schedule_migration_progress(token,title)
    self:_close_migration_progress()
    self._migration_token=token
    local path=DownloadDatabase.runtime_path(self.store)
    local function poll()
        if self._migration_token~=token then return end
        local state=DownloadDatabase.get_task_value(path,token,"migration_progress",nil)
        if self._migration_progress_widget and type(state)=="table" then
            self._migration_progress_widget:set_state(state)
        end
        if self.repair_async and self.repair_async:busy() then
            self._migration_progress_poll=poll
            UIManager:scheduleIn(.7,poll)
        end
    end
    local delay
    delay=function()
        if self._migration_token~=token or not (self.repair_async and self.repair_async:busy()) then return end
        self._migration_progress_delay=nil
        local widget=MigrationProgress:new{
            title="正在迁移《"..tostring(title or "当前书籍").."》",
            on_cancel=function()
                DownloadDatabase.set_cancelled(path,token,true)
            end,
        }
        self._migration_progress_widget=widget
        widget:show()
        local state=DownloadDatabase.get_task_value(path,token,"migration_progress",nil)
        if type(state)=="table" then widget:set_state(state) end
        poll()
    end
    self._migration_progress_delay=delay
    UIManager:scheduleIn(1.0,delay)
end

function Plugin:_run_book_repair(context,report,force)
    context=context or self:_repair_context()
    if not context or not context.book then self:info("当前没有可迁移的觅阅书籍"); return false end
    if self.repair_async and self.repair_async:busy() then self:toast("已有迁移任务正在进行"); return false end
    if type(report)~="table" then
        local repair=self.book_repair
        self:toast("正在检查本书旧评论数据",2)
        local started,err=self.repair_async:run("book-migration-check",function()
            return repair:inspect(context)
        end,function(result)
            if not result or result.ok~=true or type(result.value)~="table" then
                self:info("检查失败：\n"..tostring(result and result.error or "未知原因")); return
            end
            self:_run_book_repair(context,result.value,force)
        end,120)
        if not started then self:info("无法开始检查：\n"..tostring(err or "未知原因")) end
        return started
    end
    if #(report.issues or {})==0 then
        self:info("当前书籍已经使用 SQLite，无需迁移。")
        return true
    end
    local title=tostring((context.book or {}).title or context.title or "当前书籍")
    local token="migration-"..tostring(os.time()).."-"..tostring(math.random(10000,99999))
    local path=DownloadDatabase.runtime_path(self.store)
    DownloadDatabase.clear_task(path,token)
    self:_schedule_migration_progress(token,title)
    local repair=self.book_repair
    local started,err=self.repair_async:run("book-data-migration",function()
        return repair:migrate(context,report,{
            force=force==true,
            archive_legacy=false,
            progress=function(state)
                DownloadDatabase.set_task_value(path,token,"migration_progress",state)
            end,
            cancelled=function()
                return DownloadDatabase.is_cancelled(path,token)
            end,
        })
    end,function(result)
        self:_close_migration_progress(token)
        if not result or result.ok~=true or type(result.value)~="table" then
            local message=tostring(result and result.error or "迁移任务未完成")
            self:_record_repair_history({title=title,book_id=(context.book or {}).book_id},"失败")
            self:info("迁移失败：\n"..message)
            return
        end
        local value=result.value
        local status=value.cancelled and "已停止" or (value.ok and "已完成" or "部分失败")
        self:_record_repair_history(value,status)
        self:_save_repair_state(value.book_id,{
            signature=value.signature,
            status=value.ok and "fixed" or (value.cancelled and "pending" or "failed"),
            checked_at=os.time(),
        })
        Thoughts.clear_memory_cache()
        if ThoughtNativePopup and type(ThoughtNativePopup.clear_cache)=="function" then
            pcall(ThoughtNativePopup.clear_cache)
        end
        if value.cancelled then
            self:info("迁移已停止。已完成的章节会保留，下次可继续。")
        elseif value.ok then
            self:info("迁移完成。\n\n已处理 "..tostring(value.processed or 0).." 个章节、新迁移 "
                ..tostring(value.comments or 0).." 条评论。以后将直接使用 SQLite。")
        else
            self:info("部分章节迁移失败，成功数据已保留，可稍后继续迁移。")
        end
    end,900)
    if not started then
        self:_close_migration_progress(token)
        self:info("无法开始迁移：\n"..tostring(err or "未知原因"))
        return false
    end
    return true
end

function Plugin:_show_book_repair_prompt(context,report)
    if self._repair_prompt_open then return end
    self._repair_prompt_open=true
    local book_id=tostring(report and report.book_id or ((context.book or {}).book_id or ""))
    local signature=tostring(report and report.signature or self.book_repair:signature(context))
    local dialog
    dialog=ButtonDialog:new{title=self:_repair_message(report),title_align="center",buttons={
        {{text="立即迁移",callback=function()
            UIManager:close(dialog); self._repair_prompt_open=false
            self:_run_book_repair(context,report,false)
        end}},
        {{text="稍后处理",callback=function()
            UIManager:close(dialog); self._repair_prompt_open=false
        end}},
        {{text="本书不再自动提示",callback=function()
            UIManager:close(dialog); self._repair_prompt_open=false
            self:_save_repair_state(book_id,{signature=signature,status="ignored",checked_at=os.time()})
        end}},
    }}
    UIManager:show(dialog)
end

function Plugin:_schedule_current_book_repair_check(current,urgent)
    local prefs=self:_repair_preferences()
    if prefs.auto_check==false then return false end
    local context=self:_repair_context(current)
    if not context or not context.book then return false end
    local book_id=tostring((context.book or {}).book_id or (context.book or {}).bookId or "")
    if book_id=="" then return false end
    local previous=self:_repair_state()[book_id]
    if urgent~=true and type(previous)=="table"
        and (previous.status=="ok" or previous.status=="fixed" or previous.status=="ignored")
        and os.time()-(tonumber(previous.checked_at) or 0)<7*24*60*60 then
        return false
    end
    if self.repair_async and self.repair_async:busy() then return false end
    local repair=self.book_repair
    local delay=urgent==true and .05 or 1.4
    UIManager:scheduleIn(delay,function()
        local active=self:_current_document_path()
        if tostring(active or "")~=tostring(context.path or "") then return end
        if self.repair_async:busy() then return end
        local started=self.repair_async:run("book-migration-check",function()
            return repair:inspect(context)
        end,function(result)
            if not result or result.ok~=true or type(result.value)~="table" then return end
            local report=result.value
            if tostring(self:_current_document_path() or "")~=tostring(context.path or "") then return end
            if #(report.issues or {})==0 then
                self:_save_repair_state(book_id,{signature=report.signature,status="ok",checked_at=os.time()})
                return
            end
            local row=self:_repair_state()[book_id]
            if urgent~=true and type(row)=="table" and tostring(row.signature or "")==tostring(report.signature or "")
                and row.status=="ignored" then return end
            self:_show_book_repair_prompt(context,report)
        end,120)
        if not started then logger.dbg("[MiuRead][Migration] check deferred") end
    end)
    return true
end

function Plugin:_repair_partial_download(book_id,repair,confirmed)
    local id=tostring(book_id or "")
    if id=="" or type(repair)~="table" then self:info("没有找到可继续修复的下载断点") return false end
    self.store:reload()
    local stored=self.store:book(id)
    if not stored then self:info("这本书的下载记录已经不存在") return false end
    if type(repair.options)~="table" then
        self:info("这个旧下载断点缺少必要信息，无法安全地只补缺失内容。\n\n现有缓存没有删除，可以保留后重新下载。")
        return false
    end
    local title=tostring(stored.title or "本书")
    if confirmed~=true then
        local progress=""
        if tonumber(repair.total or 0)>0 then
            progress="\n\n已完成 "..tostring(repair.complete or 0).." / "..tostring(repair.total).." 个章节"
            if tonumber(repair.failed or 0)>0 then progress=progress.."，仍有 "..tostring(repair.failed).." 个章节待补" end
        end
        UIManager:show(ConfirmBox:new{
            text="《"..title.."》存在未完成下载。"..progress
                .."\n\n修复时会复用现有断点，只重新获取缺失内容；新文件验证成功前不会替换原文件。",
            ok_text="开始修复",cancel_text="取消",
            ok_callback=function() self:_repair_partial_download(id,repair,true) end,
        })
        return true
    end
    if self.download_task and self.download_task:busy() then
        self:info("已有下载或修复任务正在进行，请完成后再试。")
        return false
    end
    local book={bookId=id,title=stored.title,author=stored.author,cover=stored.cover}
    local options=U.copy(repair.options)
    options.repair_only=true
    options.repair_source="partial_cache"
    self:status_toast("修复书籍","正在复用断点并补全缺失内容",4)
    return self:download(book,options,false,function(new_record)
        self.store:reload()
        if type(new_record)=="table" and new_record.pending_install==true then
            self.store:save_session(id,{book_integrity_repaired_at=os.time(),book_integrity_pending_install=true})
            self:info("修复内容已经生成。\n\n当前正在阅读这本书，新文件会在关闭本书后自动替换；原文件目前没有改变。")
            self:_notify_home_data_changed("content")
            return
        end
        local remaining=BookIntegrity.partial_repairs(self.store,id)
        local same_pending=false
        for _,row in ipairs(remaining) do
            if tostring(row.root or "")==tostring(repair.root or "") then same_pending=true break end
        end
        if same_pending then
            self.store:save_session(id,{book_integrity_error="partial_pending",book_integrity_checked_at=os.time()})
            self:info("书籍仍有未完成内容。\n\n已完成章节和下载断点继续保留，下次使用“修复书籍”会从现有进度继续。")
        else
            self.store:save_session(id,{book_integrity_repaired_at=os.time(),book_integrity_error=false})
            local reused=tonumber(repair.complete or 0) or 0
            local suffix=reused>0 and ("\n\n已复用 "..tostring(reused).." 个已完成章节，没有重新下载整本书。") or ""
            self:info("书籍修复完成。\n\n缺失内容已经补全，新文件通过检查后才替换原文件。"..suffix)
        end
        self:_notify_home_data_changed("content")
    end,false)
end

function Plugin:_repair_downloaded_book(book_ref,confirmed)
    local id=tostring(type(book_ref)=="table" and (book_ref.bookId or book_ref.book_id) or book_ref or "")
    if id=="" then self:info("没有找到可修复的书籍") return false end
    self.store:reload()
    local stored=self.store:book(id)
    if not stored then self:info("这本书还没有可修复的下载记录") return false end

    local partials=BookIntegrity.partial_repairs(self.store,id)
    if #partials==1 then return self:_repair_partial_download(id,partials[1],confirmed) end
    if #partials>1 then
        local rows={}
        for _,candidate in ipairs(partials) do
            local repair=candidate
            local detail=tonumber(repair.total or 0)>0
                and (tostring(repair.complete or 0).."/"..tostring(repair.total).." 章已完成") or "可继续修复"
            rows[#rows+1]={text=repair.label or "未完成缓存",post_text=detail,
                callback=function() self:_repair_partial_download(id,repair) end}
        end
        self:list("选择要修复的未完成下载",rows)
        return true
    end

    local record=self:_preferred_record(id)
    if not record then self:info("这本书还没有可修复的已下载版本") return false end
    local report=BookIntegrity.inspect(self.store,id,record)
    if report.repair_kind=="none" then
        local session=self.store:session(id) or {}
        if session.sync_repair_required==true then
            self:info("书籍内容完整。\n\n当前异常来自阅读同步，请打开这本书后使用“修复同步”。")
        else
            self:info("检查完成，没有发现需要修复的书籍内容或批注。")
        end
        return true
    end
    local annotations_only=report.repair_kind=="annotations"
    local title=tostring(stored.title or record.title or "本书")
    if confirmed~=true then
        local text
        if annotations_only then
            text="《"..title.."》正文已经生成，但部分划线与想法未完整下载。\n\n修复时只补缺失内容，已完成正文和阅读位置会保留。"
        else
            text="《"..title.."》的书籍内容或章节映射需要修复。\n\n将优先使用现有断点，只补缺失内容；新文件验证成功前不会替换原文件。"
        end
        UIManager:show(ConfirmBox:new{
            text=text,ok_text="开始修复",cancel_text="取消",
            ok_callback=function() self:_repair_downloaded_book(id,true) end,
        })
        return true
    end
    if self.download_task and self.download_task:busy() then
        self:info("已有下载或修复任务正在进行，请完成后再试。")
        return false
    end
    local book={bookId=id,title=stored.title or record.title,author=stored.author or record.author,cover=stored.cover}
    local options=BookIntegrity.repair_options(record)
    self:status_toast("修复书籍",annotations_only and "正在补全缺失的划线与想法" or "正在检查并补全书籍内容",4)
    return self:download(book,options,false,function(new_record)
        self.store:reload()
        if type(new_record)=="table" and new_record.pending_install==true then
            self.store:save_session(id,{book_integrity_repaired_at=os.time(),book_integrity_pending_install=true})
            self:info("修复内容已经生成。\n\n当前正在阅读这本书，新文件会在关闭本书后自动替换；替换后阅读同步会重新验证。")
            self:_notify_home_data_changed("content")
            return
        end
        local refreshed=self:_preferred_record(id) or new_record
        local checked=BookIntegrity.inspect(self.store,id,refreshed)
        if checked.repair_kind=="none" then
            self.store:save_session(id,{book_integrity_repaired_at=os.time(),book_integrity_error=false})
            local session=self.store:session(id) or {}
            local extra=session.sync_repair_required==true and "\n\n书籍已修复。阅读同步仍需在打开本书后重新验证。" or ""
            self:info((annotations_only and "书籍修复完成。\n\n已补全缺失的划线与想法，正文和阅读位置未重新下载。"
                or "书籍修复完成。\n\n缺失内容已补全，新文件已经通过检查。")..extra)
        else
            self.store:save_session(id,{book_integrity_error=checked.error or checked.repair_kind,book_integrity_checked_at=os.time()})
            self:info("书籍仍有未完成内容：\n"..tostring(checked.error or (checked.annotation_pending and "部分划线与想法仍待修复" or "完整性检查未通过")))
        end
        self:_notify_home_data_changed("content")
    end,false)
end

function Plugin:repair_current_book()
    local current=self:_current_book_record()
    if not current or not current.book then self:info("请先打开一本觅阅书籍") return false end
    return self:_repair_downloaded_book(current.book.book_id)
end

function Plugin:check_and_repair_current()
    local current=self:_current_book_record()
    if not current or not current.book then self:info("请先打开一本觅阅书籍") return false end
    local id=tostring(current.book.book_id or current.book.bookId or "")
    if id=="" then self:info("当前书籍无法识别") return false end

    self.store:reload()
    local partials=BookIntegrity.partial_repairs(self.store,id)
    local record=self:_preferred_record(id) or current.record
    local report=record and BookIntegrity.inspect(self.store,id,record) or nil
    if #partials>0 or (report and report.repair_kind~="none") then
        return self:_repair_downloaded_book(id)
    end

    local session=self.store:session(id) or {}
    local repair_kind=tostring(session.sync_repair_kind or "")
    if session.sync_repair_required==true and (repair_kind=="context" or repair_kind=="position") then
        return self:repair_current_sync()
    end

    if self.sync:is_current_verified() then
        if report and report.annotation_unresolved==true then
            self:info("检查完成。\n\n书籍内容和阅读同步正常。少量旧批注无法可靠恢复，已保留现状，不会因此反复要求修复。")
        else
            self:info("检查完成。\n\n书籍内容、批注和阅读同步都正常，无需修复。")
        end
        return true
    end

    self:status_toast("检查与修复","书籍内容正常，正在核对阅读位置",3)
    return self:manual_sync()
end

function Plugin:scan_downloaded_books_for_integrity_repair()
    self.store:reload()
    local rows={}
    for _,book in ipairs(self.store:all_books()) do
        local id=tostring(book.book_id or book.bookId or "")
        if id~="" then
            local partials=BookIntegrity.partial_repairs(self.store,id)
            local record=self:_preferred_record(id)
            local book_id=id
            if #partials>0 then
                rows[#rows+1]={text=tostring(book.title or (record and record.title) or id),
                    post_text=tostring(#partials).." 个未完成断点",
                    callback=function() self:_repair_downloaded_book(book_id) end}
            elseif record then
                local report=BookIntegrity.inspect(self.store,id,record)
                if report.repair_kind~="none" then
                    local label=report.repair_kind=="annotations" and "批注待修复" or "书籍待修复"
                    rows[#rows+1]={text=tostring(book.title or record.title or id),post_text=label,
                        callback=function() self:_repair_downloaded_book(book_id) end}
                end
            end
        end
    end
    if #rows==0 then self:info("检查完成，没有发现需要修复的已下载书籍或未完成下载。") return true end
    self:list("需要修复的书籍 · "..tostring(#rows).." 本",rows)
    return true
end

function Plugin:migrate_current_book_comments(confirmed)
    local context=self:_repair_context()
    if not context then self:info("请先打开一本觅阅书籍"); return end
    if confirmed~=true and self:_active_reader_ui() and self:_notice_enabled("repair_while_reading") then
        local dialog
        dialog=ButtonDialog:new{title="迁移会读取本书旧评论数据。大书可能短暂变慢，但不会重新下载正文。",title_align="center",buttons={
            {{text="继续迁移",callback=function() UIManager:close(dialog); self:migrate_current_book_comments(true) end}},
            {{text="继续并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("repair_while_reading",false); self:migrate_current_book_comments(true) end}},
            {{text="稍后处理",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
        return
    end
    self:_run_book_repair(context,nil,true)
end

function Plugin:scan_downloaded_books_for_repair(confirmed)
    if confirmed~=true and self:_notice_enabled("library_scan") then
        self:_confirm_library_scan(function() self:scan_downloaded_books_for_repair(true) end)
        return
    end
    if self.repair_async:busy() then self:toast("已有检查或迁移任务正在进行"); return end
    self:toast("正在检查已下载书籍",2)
    local repair=self.book_repair
    local started,err=self.repair_async:run("scan-book-migration",function()
        return repair:scan_downloaded()
    end,function(result)
        if not result or result.ok~=true or type(result.value)~="table" then
            self:info("检查失败：\n"..tostring(result and result.error or "未知原因")); return
        end
        local scan=result.value
        if tonumber(scan.affected or 0)==0 then
            self:info("检查完成，没有发现需要迁移的已下载书籍。")
            return
        end
        UIManager:show(ConfirmBox:new{
            text="发现 "..tostring(scan.affected).." 本书仍有旧版评论数据。\n\n是否全部迁移到 SQLite？",
            ok_text="全部迁移",cancel_text="暂不处理",
            ok_callback=function()
                if self.repair_async:busy() then self:toast("已有迁移任务正在进行"); return end
                local token="migration-batch-"..tostring(os.time()).."-"..tostring(math.random(10000,99999))
                local path=DownloadDatabase.runtime_path(self.store)
                DownloadDatabase.clear_task(path,token)
                self:_schedule_migration_progress(token,"已下载书籍评论")
                local ok_start,error_start=self.repair_async:run("migrate-downloaded-books",function()
                    local output={checked=0,migrated=0,failed=0,cancelled=false,details={},groups=0,comments=0}
                    local total_chapters=0
                    for _,row in ipairs(scan.contexts or {}) do
                        total_chapters=total_chapters+#((row.report or {}).files or {})
                    end
                    local completed=0
                    for _,row in ipairs(scan.contexts or {}) do
                        if DownloadDatabase.is_cancelled(path,token) then output.cancelled=true; break end
                        local book_title=tostring(((row.context or {}).book or {}).title or (row.context or {}).title or "书籍")
                        local value=repair:migrate(row.context,row.report,{
                            archive_legacy=false,
                            cancelled=function() return DownloadDatabase.is_cancelled(path,token) end,
                            progress=function(state)
                                state=type(state)=="table" and state or {}
                                DownloadDatabase.set_task_value(path,token,"migration_progress",{
                                    current=completed+(tonumber(state.current) or 0),
                                    total=total_chapters,
                                    chapter=book_title.." · "..tostring(state.chapter or ""),
                                    groups=output.groups+(tonumber(state.groups) or 0),
                                    comments=output.comments+(tonumber(state.comments) or 0),
                                    percent=total_chapters>0 and (completed+(tonumber(state.current) or 0))/total_chapters or 1,
                                })
                            end,
                        })
                        output.checked=output.checked+1
                        output.groups=output.groups+(tonumber(value.groups) or 0)
                        output.comments=output.comments+(tonumber(value.comments) or 0)
                        completed=completed+#((row.report or {}).files or {})
                        if value.cancelled then output.cancelled=true end
                        if value.ok then output.migrated=output.migrated+1 else output.failed=output.failed+1 end
                        output.details[#output.details+1]=value
                        if output.cancelled then break end
                    end
                    output.ok=output.failed==0 and output.cancelled~=true
                    return output
                end,function(fixed)
                    self:_close_migration_progress(token)
                    if not fixed or fixed.ok~=true or type(fixed.value)~="table" then
                        self:info("批量迁移失败：\n"..tostring(fixed and fixed.error or "未知原因")); return
                    end
                    local value=fixed.value
                    local status=value.cancelled and "已停止" or (value.ok and "已完成" or "部分失败")
                    self:_record_repair_history({title="批量迁移",book_id=""},status)
                    if value.cancelled then
                        self:info("批量迁移已停止。已完成的数据会保留，下次可继续。")
                    elseif value.ok then
                        self:info("全部迁移完成。\n\n新迁移 "..tostring(value.comments or 0).." 条评论。")
                    else
                        self:info("部分书籍迁移失败，可稍后重试。")
                    end
                end,1800)
                if not ok_start then
                    self:_close_migration_progress(token)
                    self:info("无法开始批量迁移：\n"..tostring(error_start or "未知原因"))
                end
            end,
        })
    end,240)
    if not started then self:info("无法开始检查：\n"..tostring(err or "未知原因")) end
end

function Plugin:clear_invalid_comment_indexes()
    if self.repair_async:busy() then self:toast("已有检查或迁移任务正在进行"); return end
    local repair=self.book_repair
    local started,err=self.repair_async:run("clear-legacy-comment-data",function()
        return repair:remove_verified_legacy_downloaded()
    end,function(result)
        if result and result.ok==true then
            self:info("已清理 "..tostring(result.value or 0).." 本书的旧 JSON 备份。SQLite 数据不会受到影响。")
        else
            self:info("清理失败：\n"..tostring(result and result.error or "未知原因"))
        end
    end,300)
    if not started then self:info("无法开始清理：\n"..tostring(err or "未知原因")) end
end

function Plugin:show_repair_history()
    local history=self.store:get("book_repair_history",{})
    local items={}
    for _,row in ipairs(type(history)=="table" and history or {}) do
        items[#items+1]={text=tostring(row.title or "书籍"),
            post_text=self:_display_time("%m-%d %H:%M",tonumber(row.at) or os.time()).." · "..tostring(row.status or ""),enabled=false}
    end
    if #items==0 then items[1]={text="还没有迁移记录",enabled=false} end
    self:list("迁移记录",items)
end

function Plugin:_confirm_library_scan(callback)
    if not self:_notice_enabled("library_scan") then callback(); return true end
    local dialog
    dialog=ButtonDialog:new{title="扫描大量本地书籍可能暂时增加耗电，并使主页响应变慢。",title_align="center",buttons={
        {{text="开始扫描",callback=function() UIManager:close(dialog); callback() end}},
        {{text="开始并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("library_scan",false); callback() end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
    return true
end

function Plugin:book_repair_settings_menu()
    return {
        {text="打开书籍时检查旧评论数据",checked_func=function()
            return (self.store:preferences().repair or {}).auto_check~=false
        end,keep_menu_open=true,callback=function()
            local p=self.store:preferences(); p.repair=p.repair or {}
            p.repair.auto_check=p.repair.auto_check==false
            self.store:save_preferences(p)
        end},
        {text="迁移当前书籍评论",callback=function() self:migrate_current_book_comments() end},
        {text="扫描所有待迁移书籍",callback=function() self:scan_downloaded_books_for_repair() end},
        {text="重新扫描本地书籍与封面",callback=function() self:show_miuread_home(true) end},
        {text="清理已验证的旧 JSON 备份",callback=function() self:clear_invalid_comment_indexes() end},
        {text="迁移记录",callback=function() self:show_repair_history() end},
        {text="重置迁移提示状态",callback=function()
            self.store:set("book_repair_state",{})
            self:toast("已重置评论迁移提示状态")
        end},
    }
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
