-- MiuRead thought popup / tap controller, split from main.lua.
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Config = require("miuread.config")
local U = require("miuread.util")
local Json = require("miuread.json")
local GestureBridge = require("miuread.gesture_bridge")
local Thoughts = require("miuread.thoughts")
local Lazy = require("miuread.lazy")

local ThoughtNativePopup = Lazy("miuread.thought_native_popup")

local ok_socket, socket = pcall(require, "socket")
local function monotonic_wall_time()
    if ok_socket and socket and type(socket.gettime) == "function" then return socket.gettime() end
    return os.time()
end

local Plugin = {}

local function extract_thought_href(value,seen,depth)
    if depth>4 or value==nil then return nil end
    if type(value)=="string" then return value:match("(#?miuthought%-[%x%.]+)") end
    if type(value)~="table" then return nil end
    seen=seen or {}; if seen[value] then return nil end; seen[value]=true
    for _,key in ipairs({"href","url","target","link","uri","dest","destination"}) do local found=extract_thought_href(value[key],seen,depth+1); if found then return found end end
    for _,child in pairs(value) do local found=extract_thought_href(child,seen,depth+1); if found then return found end end
end
function Plugin:_teardown_thought_tap()
    if self._thought_tap_setup and self.ui and self.ui.unRegisterTouchZones then pcall(function() self.ui:unRegisterTouchZones({{id="miuread_thought_popup",overrides={"tap_link"}}}) end) end
    self._thought_tap_setup=nil
end
function Plugin:_thought_font_size(value)
    -- The native comment popup uses this same final size for layout metrics and
    -- glyph rendering. The popup explicitly uses ThoughtFaceFactory:getFinalFace()
    -- so the device scale is applied exactly once. UI preview callers stay logical.
    local logical
    if tonumber(value) then logical=math.max(12,math.min(48,math.floor(tonumber(value)+.5)))
    else
        local legacy={small=18,standard=22,large=26,xlarge=30}
        logical=legacy[tostring(value or "standard")] or 22
    end
    local scaled=logical
    if Device and Device.screen and type(Device.screen.scaleBySize)=="function" then
        local ok,result=pcall(Device.screen.scaleBySize,Device.screen,logical)
        if ok and tonumber(result) then scaled=math.max(logical,math.floor(tonumber(result)+.5)) end
    end
    return scaled
end

local function usable_font_name(value)
    if type(value)~="string" then return nil end
    value=value:match("^%s*(.-)%s*$")
    if value=="" then return nil end
    return value
end
function Plugin:_thought_font_name(prefs)
    prefs=prefs or (self.store:preferences().thoughts or {})
    if prefs.follow_body_font~=true then
        return usable_font_name(prefs.font_face)
    end
    local doc=self.ui and self.ui.document
    if doc and type(doc.getFontFace)=="function" then
        local ok,value=pcall(doc.getFontFace,doc)
        if ok then
            name=usable_font_name(value)
            if name then return name end
        end
    end

    local name=usable_font_name(self.ui and self.ui.font and self.ui.font.font_face)
    if name then return name end

    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font")
        if ok then return usable_font_name(value) end
    end
    return nil
end
function Plugin:_write_thought_popup_marker(stage, info, extra)
    local path=tostring(self._thought_popup_marker_path or "")
    if path=="" then return false end
    local payload={
        version=tostring(self.version or Config.VERSION),
        stage=tostring(stage or "unknown"),
        timestamp=os.time(),
        book_id=info and tostring(info.book_id or "") or nil,
        chapter_uid=info and tostring(info.chapter_uid or "") or nil,
        range=info and tostring(info.range or "") or nil,
    }
    for key,value in pairs(type(extra)=="table" and extra or {}) do payload[key]=value end
    local ok,encoded=pcall(Json.encode,payload)
    if not ok then return false end
    return U.atomic_write(path,encoded,true)==true
end

function Plugin:_clear_thought_popup_marker()
    local path=tostring(self._thought_popup_marker_path or "")
    if path~="" then os.remove(path) end
end

function Plugin:_flush_reader_checkpoint(reason, force)
    if not (self.ui and self.ui.document) then return false end
    -- KOReader already saves the current reading position during its own
    -- suspend/close lifecycle. MiuRead only needs an additional full settings
    -- flush when annotations or document settings actually changed. Avoiding a
    -- redundant save removes the most visible lock/close pause.
    if self._reader_checkpoint_dirty~=true and force~=true then
        logger.dbg("[MiuRead][ReaderCheckpoint] clean; extra save skipped","reason=",tostring(reason or "unspecified"))
        return true
    end
    local now=os.time()
    if force~=true and now-(tonumber(self._reader_checkpoint_last) or 0)<1 then return true end
    local ok,err=xpcall(function()
        if type(self.ui.saveSettings)=="function" then
            self.ui:saveSettings()
        elseif type(self.ui.handleEvent)=="function" then
            self.ui:handleEvent(Event:new("SaveSettings"))
            if self.ui.doc_settings and type(self.ui.doc_settings.flush)=="function" then
                self.ui.doc_settings:flush()
            end
        end
    end,debug.traceback)
    if ok then
        self._reader_checkpoint_last=now
        self._reader_checkpoint_dirty=false
        logger.info("[MiuRead][ReaderCheckpoint] saved","reason=",tostring(reason or "unspecified"))
        return true
    end
    logger.warn("[MiuRead][ReaderCheckpoint] save failed","reason=",tostring(reason or "unspecified"),tostring(err))
    return false
end

function Plugin:_schedule_reader_checkpoint(reason, delay)
    if not (self.ui and self.ui.document) then return false end
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    local task
    task=function()
        if self._reader_checkpoint_task~=task then return end
        self._reader_checkpoint_task=nil
        self:_flush_reader_checkpoint(reason,false)
    end
    self._reader_checkpoint_task=task
    UIManager:scheduleIn(math.max(.2,tonumber(delay) or 2.0),task)
    return true
end

function Plugin:_finish_thought_popup(generation)
    if generation and generation~=self._thought_popup_generation then return end
    self._thought_popup=nil
    self._miuread_thought_popup_busy=false
    self:_clear_thought_popup_marker()
    if self.download_task then self.download_task:resume("thought_popup") end
    self:_mark_reader_busy(2)
    if self._performance_prompt_pending then
        UIManager:scheduleIn(.45,function() self:_show_performance_prompt() end)
    end
    UIManager:scheduleIn(1.2,function() collectgarbage("step",48) end)
end

function Plugin:_close_active_thought_popup(reason)
    local popup=self._thought_popup
    self._thought_popup_generation=(tonumber(self._thought_popup_generation) or 0)+1
    self._thought_popup=nil
    self._miuread_thought_popup_busy=false
    self:_clear_thought_popup_marker()
    if self.download_task then self.download_task:resume("thought_popup") end
    if popup and popup~=true then
        pcall(UIManager.close,UIManager,popup)
        logger.info("[MiuRead][ThoughtPopup] closed","reason=",tostring(reason or "forced"))
    end
end

function Plugin:_open_thought_info(info,generation)
    if generation~=self._thought_popup_generation or not (self.ui and self.ui.document) then
        self:_finish_thought_popup(generation)
        return
    end
    local started=monotonic_wall_time()
    local popup,notice
    local ok,unexpected=xpcall(function()
        -- The tap marker already proves a popup was active if KOReader exits
        -- abnormally. Keep intermediate stages in the log instead of rewriting
        -- the same flash file several times during one visible tap.
        local lookup_started=monotonic_wall_time()
        local group,err,token=Thoughts.find(self.store,info.book_id,info.chapter_uid,info.range)
        local lookup_ms=math.floor((monotonic_wall_time()-lookup_started)*1000+.5)
        if not group then notice=tostring(err or "没有想法内容"); return end
        local prefs=self.store:preferences().thoughts or {}
        local function on_close() self:_finish_thought_popup(generation) end
        local parts_started=monotonic_wall_time()
        local source,comments,count,native_cache_hit,native_signature=Thoughts.native_parts_cached(
            self.store,info.book_id,info.chapter_uid,info.range,group,token
        )
        local parts_ms=math.floor((monotonic_wall_time()-parts_started)*1000+.5)
        if tostring(source or "")=="" and #(comments or {})==0 then notice="没有想法内容"; return end
        local show_started=monotonic_wall_time()
        popup=ThoughtNativePopup.show{
            source_text=source,
            comments=comments,
            cache_key=table.concat({
                tostring(info.book_id or ""), tostring(info.chapter_uid or ""),
                tostring(info.range or ""), tostring(native_signature or ""),
            }, "|"),
            font_size=self:_thought_font_size(self:_thought_font_size_value(prefs)),
            font_name=self:_thought_font_name(prefs),
            width_ratio=tonumber(prefs.width_ratio) or 0.91,
            height_ratio=tonumber(prefs.height_ratio) or 0.55,
            on_close=on_close,
            on_interact=function() self:_mark_reader_busy(30) end,
            on_error=function()
                self:info("评论显示失败，窗口已安全关闭。当前阅读位置不会丢失。")
            end,
        }
        local show_ms=math.floor((monotonic_wall_time()-show_started)*1000+.5)
        local elapsed_ms=math.floor((monotonic_wall_time()-started)*1000+.5)
        logger.info("[MiuRead][ThoughtPopup] opened",
            "mode=","native_rounded_paged_swipe",
            "book=",tostring(info.book_id),"chapter=",tostring(info.chapter_uid),
            "comments=",tostring(count or 0),
            "source=",token and token.index_hit and "compact_index" or "chapter_cache",
            "cache=",token and token.cache_hit and "hit" or "miss",
            "native_cache=",native_cache_hit and "hit" or "miss",
            "lookup_ms=",tostring(lookup_ms),
            "parts_ms=",tostring(parts_ms),
            "show_ms=",tostring(show_ms),
            "elapsed_ms=",tostring(elapsed_ms))
        if not popup then error("评论窗口未能加入界面") end
        self._thought_popup=popup
        self:_record_performance("thought_popup",elapsed_ms)
        if token and token.index_hit~=true then
            UIManager:scheduleIn(.2,function() self:_schedule_current_book_repair_check(nil,true) end)
        end
    end,debug.traceback)
    if not ok then
        logger.err("[MiuRead][ThoughtPopup] open failed",tostring(unexpected))
        self:_finish_thought_popup(generation)
        self:info("评论暂时无法显示。当前阅读批注已先保存，请稍后重试。")
    elseif not popup then
        self:_finish_thought_popup(generation)
        if notice then self:info(notice) end
    end
end

function Plugin:_show_thought_href(href)
    local info=Thoughts.parse_href(href); if not info then return false end
    -- A disabled comment layer still owns its internal links. Consume them
    -- silently instead of letting KOReader report #miuthought as invalid.
    if not self:_thoughts_enabled() then return true end
    if self._miuread_thought_popup_busy or self._thought_popup then return true end
    local runtime=self._download_runtime
    if runtime and self.download_task and self.download_task:busy() and runtime.comment_slow_notice~=true then
        runtime.comment_slow_notice=true
        self:status_toast("后台正在下载","评论打开和翻页可能稍慢",3)
    end
    self._thought_popup_generation=(tonumber(self._thought_popup_generation) or 0)+1
    local generation=self._thought_popup_generation
    self._miuread_thought_popup_busy=true
    self:_write_thought_popup_marker("tap",info)
    if self.download_task then self.download_task:pause("thought_popup") end
    self:_mark_reader_busy(30)
    -- Only write document metadata here when annotations really changed.
    -- Repeatedly opening comments must not force a storage flush every time.
    if self._reader_checkpoint_dirty and os.time()-(tonumber(self._reader_checkpoint_last) or 0)>=5 then
        self:_flush_reader_checkpoint("before_thought_popup",false)
    end
    UIManager:nextTick(function()
        self:_open_thought_info(info,generation)
    end)
    return true
end

function Plugin:_thought_edge_page_turn(ges)
    local enabled,percent=self:_reader_edge_guard_state()
    if not enabled then return false end
    local pos=ges and ges.pos
    local x=pos and tonumber(pos.x)
    local width=Device.screen and Device.screen:getWidth()
    if not x or not width or width<=0 then return false end

    local ratio=math.max(.05,math.min(.20,(tonumber(percent) or 10)/100))
    local inverse=self.ui and self.ui.view and self.ui.view.inverse_reading_order==true
    local diff
    if x<=width*ratio then
        diff=inverse and 1 or -1
    elseif x>=width*(1-ratio) then
        diff=inverse and -1 or 1
    else
        return false
    end

    -- Keep KOReader's own tap-turn preference authoritative. The guard only
    -- resolves a collision between an edge annotation link and a page turn.
    if _G.G_reader_settings and type(G_reader_settings.nilOrFalse)=="function"
        and not G_reader_settings:nilOrFalse("page_turns_disable_tap") then
        return false
    end
    if not self.ui or type(self.ui.handleEvent)~="function" then return false end

    local ok,handled=pcall(self.ui.handleEvent,self.ui,Event:new("GotoViewRel",diff))
    if not ok or handled~=true then return false end
    self:_mark_reader_busy(2)
    logger.dbg("[MiuRead][ThoughtPopup] edge annotation tap converted to page turn",
        "percent=",tostring(percent),"direction=",diff<0 and "backward" or "forward")
    return true
end

function Plugin:_on_thought_tap(ges)
    -- Reader Gesture Manager keeps priority in configured corner regions.
    -- This prevents the annotation edge guard from turning a corner action
    -- into a page turn when a comment link happens to sit under that corner.
    if GestureBridge.dispatch(ges) then return true end
    if not self.ui or not self.ui.link or not self.ui.link.getLinkFromGes then return false end
    local ok,link=pcall(self.ui.link.getLinkFromGes,self.ui.link,ges); if not ok or not link then return false end
    local href=extract_thought_href(link,{},0); if not href then return false end
    if self:_thought_edge_page_turn(ges) then return true end
    return self:_show_thought_href(href)
end
function Plugin:_setup_thought_tap()
    if self._thought_tap_setup or not self.ui or not self.ui.registerTouchZones then return end
    local ok,Device=pcall(require,"device"); if ok and Device.isTouchDevice and not Device:isTouchDevice() then return end
    self.ui:registerTouchZones({{id="miuread_thought_popup",ges="tap",screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},overrides={"tap_link"},handler=function(ges) return self:_on_thought_tap(ges) end}})
    self._thought_tap_setup=true
end



local M = {}

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M
