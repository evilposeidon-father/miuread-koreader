-- Shared lifecycle skeleton for MiuRead reader panel dialogs.
-- Each reader dialog extends this base and only implements its own
-- content builder; dismiss, close, key handling and dirty-region refresh
-- stay identical across all reader panels.
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Skin = require("miuread.reader_skin")

local PanelBase = InputContainer:extend{
    _miuread_transient = true,
    _miuread_modal_surface = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    closed = false,
    pending_action = nil,
}

function PanelBase:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

function PanelBase:_close(action, cancel_pending)
    if cancel_pending then
        self.pending_action = nil
    elseif action and not self.pending_action then
        self.pending_action = action
    end
    if self.closed then return true end
    self.closed = true
    UIManager:close(self)
    return true
end

function PanelBase:_init_dismiss()
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end
end

function PanelBase:_region_dimen()
    return self._panel_dimen or self.frame_dimen or self.panel_dimen
end

function PanelBase:onTapDismiss(_, ges)
    local d = self:_region_dimen()
    local pos = ges and ges.pos
    if pos and d and (pos.y < d.y or pos.y > d.y + d.h
        or pos.x < d.x or pos.x > d.x + d.w) then
        return self:_close(nil, true)
    end
    return false
end

function PanelBase:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then return self:_close(nil, true) end
    return false
end

function PanelBase:onShow()
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(self:_region_dimen()) end)
end

function PanelBase:finish_close_widget(clear_live, log_name)
    local d = self:_region_dimen()
    local region = d and Skin.expand_region(d) or nil
    local action = self.pending_action
    self.pending_action = nil
    self.closed = true
    if clear_live then clear_live(self) end
    if region then UIManager:setDirty(nil, function() return "ui", region end) end
    if action then
        UIManager:scheduleIn(.04, function()
            local ok, err = pcall(action)
            if not ok then
                logger.warn(tostring(log_name or "[MiuRead][ReaderPanel] action failed"), tostring(err))
            end
        end)
    end
end

return PanelBase
