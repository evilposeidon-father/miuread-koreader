-- Download state/queue reader for the Store facade.
-- store.lua merges these methods onto Store at load time, so every existing
-- store:download_state()/store:download_queue() call site is unchanged.
local DownloadDatabase = require("miuread.download_database")
local Json = require("miuread.json")
local U = require("miuread.util")

local StoreDownloads = {}

function StoreDownloads:download_state()
    local value=DownloadDatabase.get_download_state(self)
    if type(value)=="table" and next(value)~=nil then return value end
    local legacy_path=tostring(self.legacy_download_state_path or "")
    local raw=legacy_path~="" and U.read_file(legacy_path,true) or nil
    if raw and raw~="" then
        local ok,legacy=pcall(Json.decode,raw)
        if ok and type(legacy)=="table" then
            DownloadDatabase.set_download_state(self,legacy)
            os.remove(legacy_path)
            return legacy
        end
    end
    return {}
end
function StoreDownloads:save_download_state(value)
    return DownloadDatabase.set_download_state(self,value or {})
end
function StoreDownloads:clear_download_state()
    if self.legacy_download_state_path then os.remove(self.legacy_download_state_path) end
    return DownloadDatabase.clear_download_state(self)
end
function StoreDownloads:download_queue()
    local queue=DownloadDatabase.get_download_queue(self)
    if type(queue)~="table" or next(queue)==nil then
        local legacy=self:get("download_queue",{})
        if type(legacy)=="table" and #legacy>0 then
            DownloadDatabase.set_download_queue(self,legacy)
            self:set("download_queue",{})
            queue=legacy
        end
    end
    if type(queue)~="table" then return {} end
    if #queue<=1 then return queue end
    return {queue[1]}
end
function StoreDownloads:save_download_queue(queue)
    queue=type(queue)=="table" and queue or {}
    local kept={}
    if type(queue[1])=="table" then kept[1]=U.copy(queue[1]) end
    return DownloadDatabase.set_download_queue(self,kept)
end
function StoreDownloads:enqueue_download(job)
    local queue=self:download_queue()
    if #queue>=1 then return nil,"full" end
    queue[1]=U.copy(job or {})
    self:save_download_queue(queue)
    return 1
end
function StoreDownloads:dequeue_download()
    local queue=self:download_queue(); if #queue==0 then return nil end
    local job=table.remove(queue,1); self:save_download_queue(queue); return job
end
function StoreDownloads:remove_queued_download(index)
    local queue=self:download_queue(); index=tonumber(index); if not index or not queue[index] then return false end
    table.remove(queue,index); self:save_download_queue(queue); return true
end


return StoreDownloads
