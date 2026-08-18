local UIManager = require("ui/uimanager")
local U = require("miuread.util")
local Text = require("miuread.text")
local _ = Text.tr

local M = {}

-- auto_underline = 选词直接划线（默认）；native_menu = 保留 KOReader 原生
-- 选择菜单（复制/查词/划线）。
function M.policy(selection_menu)
    return selection_menu == true and "native_menu" or "auto_underline"
end

-- G5: highlight drawer styles on grayscale e-ink (WeRead 下划线/高亮/波浪
-- 的灰阶降级——波浪线 KOReader 无，用反白替代，靠齐）。
M.STYLES = {"underscore", "lighten", "invert"}
M.STYLE_LABELS = {underscore = "下划线", lighten = "浅底", invert = "反白"}

function M.style_label(style)
    return M.STYLE_LABELS[tostring(style or "")] or "下划线"
end

function M.is_style(style)
    return M.STYLE_LABELS[tostring(style or "")] ~= nil
end

local Plugin = {}

-- Pure policy lives here; the Plugin method is a thin delegate so existing
-- callers/tests keep working.
function Plugin:highlight_selection_policy(selection_menu)
    return M.policy(selection_menu)
end

-- Safe preference read: book-open paths may run under stubs without a store;
-- a missing preference simply means auto-underline (the default).
function Plugin:_selection_menu_enabled()
    local ok, reader = pcall(function() return self:_reader_preferences() end)
    return ok and type(reader) == "table" and reader.selection_menu == true or false
end

function Plugin:_restore_miuread_highlight_action_policy()
    if self._miuread_highlight_action_owned ~= true then return false end
    self._miuread_highlight_action_owned = false
    local previous_action=self._miuread_previous_highlight_action
    local previous_single_word=self._miuread_previous_highlight_single_word
    self._miuread_previous_highlight_action=nil
    self._miuread_previous_highlight_single_word=nil
    local settings=G_reader_settings
    if not (settings and type(settings.delSetting)=="function"
        and type(settings.saveSetting)=="function") then return false end
    if previous_action==nil then
        pcall(settings.delSetting,settings,"default_highlight_action")
    else
        pcall(settings.saveSetting,settings,"default_highlight_action",previous_action)
    end
    if previous_single_word==nil then
        pcall(settings.delSetting,settings,"highlight_action_on_single_word")
    else
        pcall(settings.saveSetting,settings,"highlight_action_on_single_word",previous_single_word)
    end
    if type(settings.flush)=="function" then pcall(settings.flush,settings) end
    return true
end

function Plugin:_apply_miuread_highlight_action_policy()
    -- MiuRead books highlight on selection. KOReader only calls
    -- showHighlightPrompt automatically when default_highlight_action is
    -- "highlight"; with the factory "ask" default the selection menu is shown
    -- instead, so the direct-under-line wrapper below would never run.
    if self:_selection_menu_enabled() then
        -- B12 mitigation: keep KOReader's native selection menu (复制/查词/划线).
        -- Undo any forced policy from a previous book with auto-underline.
        self:_restore_miuread_highlight_action_policy()
        return true
    end
    local settings=G_reader_settings
    if not (settings and type(settings.readSetting)=="function"
        and type(settings.saveSetting)=="function") then return false end
    if self._miuread_highlight_action_owned ~= true then
        self._miuread_previous_highlight_action=settings:readSetting("default_highlight_action")
        self._miuread_previous_highlight_single_word=settings:readSetting("highlight_action_on_single_word")
        self._miuread_highlight_action_owned=true
    end
    pcall(settings.saveSetting,settings,"default_highlight_action","highlight")
    pcall(settings.saveSetting,settings,"highlight_action_on_single_word",true)
    return true
end

function Plugin:_apply_miuread_highlight_defaults(book)
    -- Only for books MiuRead can identify. The default is a direct underline:
    -- no style/color prompt after selection, and tapping an existing highlight
    -- keeps KOReader's native edit/note/delete dialog.
    if not (book and self.ui and self.ui.view and self.ui.highlight
        and type(self.ui.doc_settings)=="table") then return false end
    local view=self.ui.view
    if type(view.highlight)~="table" then return false end
    local settings=self.ui.doc_settings
    local marker="miuread_highlight_underline_applied"
    local ok_has=pcall(settings.has,settings,marker)
    if not ok_has or not settings:has(marker) then
        -- Default seed: respect the user-chosen global drawer style on the
        -- first apply instead of hard-coding underscore (architect/backend
        -- review: single writer for the seed; later applies keep the per-book
        -- doc_settings value).
        local ok_default, default_drawer = pcall(G_reader_settings.readSetting, G_reader_settings, "highlight_drawer")
        local seed = ok_default and tostring(default_drawer or "") or ""
        if not M.is_style(seed) then seed = "underscore" end
        pcall(settings.saveSetting,settings,"highlight_drawer",seed)
        pcall(settings.saveSetting,settings,marker,true)
    end
    local ok_read,saved=pcall(settings.readSetting,settings,"highlight_drawer")
    view.highlight.saved_drawer = ok_read and tostring(saved or "underscore") or "underscore"
    if view.highlight.saved_drawer=="" then view.highlight.saved_drawer="underscore" end
    if view.highlight.disabled~=false then view.highlight.disabled=false end

    local highlight=self.ui.highlight
    if self:_selection_menu_enabled() then
        -- Native selection menu stays intact (copy/lookup/highlight prompt).
        -- Restore any previously installed direct-save patch so toggling the
        -- setting mid-reading takes effect immediately (architect review).
        if highlight._miuread_force_direct_highlight==true and highlight._miuread_orig_show_highlight_prompt then
            highlight.showHighlightPrompt=highlight._miuread_orig_show_highlight_prompt
            highlight._miuread_force_direct_highlight=nil
            highlight._miuread_orig_show_highlight_prompt=nil
        end
    elseif type(highlight.showHighlightPrompt)=="function" and highlight._miuread_force_direct_highlight~=true then
        highlight._miuread_orig_show_highlight_prompt=highlight.showHighlightPrompt
        highlight.showHighlightPrompt=function(this,caller_callback)
            -- Always take the direct-save path. Passing `false` to KOReader's
            -- native implementation is not enough: `prompt = prompt or
            -- G_reader_settings:readSetting("highlight_prompt")` treats false
            -- as absent and falls back to the user's global prompt preference,
            -- which can still open the style/color selector.
            if this.highlight_dialog then
                UIManager:close(this.highlight_dialog)
                this.highlight_dialog=nil
            end
            if this.hold_pos and not this.selected_text then
                this:highlightFromHoldPos()
            end
            if not (this.selected_text and this.selected_text.pos0 and this.selected_text.pos1) then return end
            if type(this.saveHighlight) ~= "function" then return end
            local index=this:saveHighlight(true)
            this:clear()
            if caller_callback then caller_callback(index) end
            self:_maybe_show_selection_menu_hint()
        end
        highlight._miuread_force_direct_highlight=true
    end

    self:_apply_miuread_highlight_action_policy()
    return true
end

function M.install(target)
    for name, func in pairs(Plugin) do
        target[name] = func
    end
end

return M

