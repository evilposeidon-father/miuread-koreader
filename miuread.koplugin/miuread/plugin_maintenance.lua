local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local Config = require("miuread.config")
local HomeData = require("miuread.home_data")
local Json = require("miuread.json")
local U = require("miuread.util")
local UiScale = require("miuread.ui_scale")

local Screen = Device.screen

local function human_size(bytes)
    bytes=tonumber(bytes) or 0
    if bytes>=1024*1024*1024 then return string.format("%.2f GB",bytes/(1024*1024*1024)) end
    if bytes>=1024*1024 then return string.format("%.1f MB",bytes/(1024*1024)) end
    if bytes>=1024 then return string.format("%.1f KB",bytes/1024) end
    return tostring(bytes).." B"
end

local function path_name(path) return tostring(path or ""):match("([^/]+)$") or "" end

local Plugin = {}

function Plugin:export_diagnostic_bundle()
    local stamp = os.date("%Y%m%d-%H%M%S")
    local root = self.store.temp_dir .. "/miuread-diagnostic-" .. stamp
    local ok = U.mkdir(root)
    if not ok then
        self:info("无法创建诊断目录：\n" .. tostring(root))
        return false
    end

    local function write(name, value)
        if value and tostring(value) ~= "" then
            local written, err = U.atomic_write(root .. "/" .. name, tostring(value), true)
            if not written then
                logger.warn("[MiuRead][Diagnostic] write failed", tostring(name), tostring(err))
            end
        end
    end

    write("version.txt", table.concat({
        "MiuRead " .. tostring(Config.VERSION),
        "schema=" .. tostring(Config.SCHEMA),
        "channel=" .. tostring(Config.UPDATE_CHANNEL),
        "runtime=" .. tostring(self._runtime_mode or "unknown"),
        "home_enabled=" .. tostring(self:_home_enabled()),
        "logged_in=" .. tostring(self:logged_in() == true),
        "performance=" .. tostring((self.performance_mode and self.performance_mode:enabled() == true) and "lightweight" or "standard"),
        "time=" .. os.date("%Y-%m-%d %H:%M:%S"),
    }, "\n"))

    write("device.txt", table.concat({
        "model=" .. tostring(Device.model or "unknown"),
        "firmware=" .. tostring(Device.firmware_rev or "unknown"),
        "screen=" .. tostring(Screen:getWidth()) .. "x" .. tostring(Screen:getHeight()),
        "frontlight=" .. tostring(Device:hasFrontlight()),
        "suspend=" .. tostring(Device:canSuspend()),
        "touch=" .. tostring(Device:isTouchDevice()),
        "keys=" .. tostring(Device:hasKeys()),
        "display=" .. tostring(UiScale.getDisplayMode and UiScale.getDisplayMode() or "standard"),
    }, "\n"))

    local preferences = self.store:preferences()
    local safe_preferences = U.copy(preferences)
    if type(safe_preferences) == "table" then
        for key, value in pairs(safe_preferences) do
            local lower = tostring(key):lower()
            if lower:find("cookie", 1, true) or lower:find("token", 1, true)
                or lower:find("secret", 1, true) or lower:find("api_key", 1, true)
                or lower:find("credential", 1, true) then
                safe_preferences[key] = "[redacted]"
            end
        end
    end
    local ok_encode, encoded = pcall(Json.encode, safe_preferences)
    write("preferences-redacted.json", ok_encode and tostring(encoded) or ("encode failed: " .. tostring(encoded)))

    local diag_dir = root .. "/download-diagnostics"
    local copied = 0
    for file in lfs.dir(self.store.temp_dir) do
        if file and file:match("^download%-diagnostic%-.*%.txt$") then
            local source = self.store.temp_dir .. "/" .. file
            if U.file_exists(source) then
                U.mkdir(diag_dir)
                local target = diag_dir .. "/" .. file
                local copy_ok = U.copy_file(source, target)
                if copy_ok then copied = copied + 1 end
            end
        end
    end
    write("download-diagnostics.txt", "copied=" .. tostring(copied))

    self:info("诊断包已生成：\n" .. root)
    logger.info("[MiuRead][Diagnostic] bundle exported", root, "download_diag=", tostring(copied))
    return true
end

function Plugin:_backup_latest_dir()
    return self.store.data_dir .. "/backup/latest"
end

function Plugin:export_config_backup()
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请稍后再备份。") return false end
    if self.download_task and self.download_task:busy() then self:info("下载任务正在运行，请稍后再备份。") return false end
    self.store:flush()
    local latest = self:_backup_latest_dir()
    U.mkdir(latest)
    local copied = 0
    if U.file_exists(self.store.settings_path) and U.copy_file(self.store.settings_path, latest .. "/miuread.lua") then copied = copied + 1 end
    if U.file_exists(self.store.download_database_path) and U.copy_file(self.store.download_database_path, latest .. "/download-database.sqlite3") then copied = copied + 1 end
    local book_data_root = latest .. "/book-data"
    local db_count = 0
    for _, book_path in ipairs(U.list(self.store.cache_books_dir)) do
        if lfs.attributes(book_path,"mode")=="directory" then
            local folder = path_name(book_path)
            local thoughts = book_path .. "/thoughts.sqlite3"
            local local_ann = book_path .. "/local_annotations.sqlite3"
            if U.file_exists(thoughts) or U.file_exists(local_ann) then
                local target_dir = book_data_root .. "/" .. folder
                U.mkdir(target_dir)
                if U.file_exists(thoughts) and U.copy_file(thoughts, target_dir .. "/thoughts.sqlite3") then db_count = db_count + 1 end
                if U.file_exists(local_ann) and U.copy_file(local_ann, target_dir .. "/local_annotations.sqlite3") then db_count = db_count + 1 end
            end
        end
    end
    U.atomic_write(latest .. "/backup-info.txt", table.concat({
        "MiuRead backup",
        "version=" .. tostring(Config.VERSION),
        "created=" .. os.date("%Y-%m-%d %H:%M:%S"),
        "config_copied=" .. tostring(copied),
        "database_files=" .. tostring(db_count),
    }, "\n"), true)
    self:info("备份完成：\n" .. latest .. "\n\n已备份配置、下载断点和 " .. tostring(db_count) .. " 个本地数据库文件。")
    logger.info("[MiuRead][Backup] exported", latest, "db_files=", tostring(db_count))
    return true
end

function Plugin:restore_config_backup()
    local latest = self:_backup_latest_dir()
    if not U.file_exists(latest .. "/miuread.lua") then
        self:info("没有可恢复的备份。\n请先执行一次“立即备份配置与数据”。")
        return false
    end
    if self.download_task and self.download_task:busy() then self:info("下载任务正在运行，请稍后再恢复。") return false end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请稍后再恢复。") return false end
    UIManager:show(ConfirmBox:new{text="恢复最近备份？\n\n当前配置、登录状态、下载断点会被备份内容替换；本地书库文件不会被删除。\n\n恢复完成后自动重启 KOReader。",ok_callback=function()
        self.store:flush()
        local failed = {}
        if not U.copy_file(latest .. "/miuread.lua", self.store.settings_path) then failed[#failed + 1] = "配置文件" end
        if U.file_exists(latest .. "/download-database.sqlite3") and not U.copy_file(latest .. "/download-database.sqlite3", self.store.download_database_path) then
            failed[#failed + 1] = "下载断点"
        end
        local book_data_root = latest .. "/book-data"
        for _, folder in ipairs(U.list(book_data_root)) do
            if lfs.attributes(book_data_root .. "/" .. folder, "mode") == "directory" then
                local target_dir = self.store.cache_books_dir .. "/" .. folder
                U.mkdir(target_dir)
                for _, db in ipairs({"thoughts.sqlite3", "local_annotations.sqlite3"}) do
                    local source = book_data_root .. "/" .. folder .. "/" .. db
                    if U.file_exists(source) and not U.copy_file(source, target_dir .. "/" .. db) then
                        failed[#failed + 1] = folder .. "/" .. db
                    end
                end
            end
        end
        if #failed > 0 then
            self:info("恢复未完全完成：\n" .. table.concat(failed, "、") .. "\n\n请重新备份或手动复制。")
            return
        end
        self:status_toast("备份恢复", "已恢复，正在重启 KOReader", 3)
        UIManager:scheduleIn(.4, function() self:_restart_koreader("restore-backup") end)
    end})
    return true
end

function Plugin:show_reading_report()
    local stats = HomeData.reading_stats(true)
    if not stats then
        self:info("暂时没有阅读统计数据。\n\n开始阅读后，KOReader 会自动记录阅读时长和页数。")
        return false
    end
    local week_seconds = tonumber(stats.week_seconds or 0) or 0
    local today_seconds = tonumber(stats.today_seconds or 0) or 0
    local today_pages = tonumber(stats.today_pages or 0) or 0
    local week_pages = tonumber(stats.week_pages or 0) or 0
    self:info("阅读周报\n\n本周阅读时长：" .. HomeData.format_duration(week_seconds)
        .. "\n本周阅读页数：" .. tostring(week_pages) .. " 页"
        .. "\n\n今日阅读时长：" .. HomeData.format_duration(today_seconds)
        .. "\n今日阅读页数：" .. tostring(today_pages) .. " 页"
        .. "\n\n数据来源：KOReader 阅读统计")
    return true
end

function Plugin:show_cache_health()
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请稍候。") return end
    local dialog=InfoMessage:new{text="正在体检缓存，请稍候……"}
    UIManager:show(dialog)
    local function done(result)
        local ok,unexpected=xpcall(function()
            pcall(function() UIManager:close(dialog) end)
            if not (result and result.ok==true and type(result.sizes)=="table") then
                self:info("缓存体检失败：\n"..U.first_line(result and result.error or "未知错误",220))
                return
            end
            local size=result.sizes
            local cleanable=(tonumber(size.partial) or 0)+(tonumber(size.covers) or 0)+(tonumber(size.temp) or 0)
            local summary="已下载书籍："..human_size(size.books)
                .."\n下载断点："..human_size(size.partial)
                .."\n想法与章节数据（受保护）："..human_size(size.protected)
                .."\n封面缓存："..human_size(size.covers)
                .."\n临时与待安装文件："..human_size(size.temp)
                .."\n\n可清理空间约："..human_size(cleanable)
            dialog=ButtonDialog:new{title="缓存体检\n\n"..summary,title_align="center",buttons={
                {{text="一键清理可清理项",callback=function() UIManager:close(dialog); self:_clear_all_safe_cache() end}},
                {{text="仅清理下载临时文件",callback=function() UIManager:close(dialog); self:_clear_download_residue() end}},
                {{text="仅清理封面缓存",callback=function() UIManager:close(dialog); self:_clear_cover_cache() end}},
                {{text="取消",callback=function() UIManager:close(dialog) end}},
            }}
            UIManager:show(dialog)
        end,debug.traceback)
        if not ok then
            pcall(function() UIManager:close(dialog) end)
            logger.err("[MiuRead][CacheHealth] result handling failed",tostring(unexpected))
            pcall(function() self:info("缓存体检结果显示失败。") end)
        end
    end
    local started,err=self.cache_cleanup_task:start_scan(self:_storage_categories(),done)
    if not started then pcall(function() UIManager:close(dialog) end); self:info("无法开始体检：\n"..tostring(err)) end
end

function Plugin:_clear_all_safe_cache()
    if self:_cache_action_blocked() then return end
    local paths={}
    for _,path in ipairs(self:_download_residue_paths()) do paths[#paths+1]=path end
    paths[#paths+1]=self.store.covers_dir
    UIManager:show(ConfirmBox:new{text="一键清理可清理项？\n\n将清理下载断点、失败任务残留和封面缓存；不会删除已下载书籍、想法、章节数据与阅读记录。",ok_callback=function()
        self:_run_cache_cleanup(paths,{
            progress_text="正在一键清理……",
            done_text="可清理缓存已清理",
            operation="缓存体检一键清理",
            policy={mode="cache_health_clean_all"},
            commit=function()
                U.mkdir(self.store.temp_dir); U.mkdir(self.store.covers_dir)
                self.store:set("cover_index",{})
                self.store:prune_missing_files()
                local state=self.store:download_state()
                if state.status=="failed" or state.status=="interrupted" then self.store:clear_download_state() end
            end,
        })
    end})
end

local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
