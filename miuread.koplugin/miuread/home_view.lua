local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local GestureBridge = require("miuread.gesture_bridge")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local U = require("miuread.util")
local UiScale = require("miuread.ui_scale")
local Ui = require("miuread.ui_components")
local Cards = require("miuread.home_cards")

local Screen = Device.screen
local live_widget
local home_generation = 0

local function face(name, nominal, maximum, minimum)
    return Ui.face(name, nominal, maximum, minimum)
end

local OffsetContainer = Ui.OffsetContainer
local fixed_frame = Ui.frame
local TapBox = Ui.TapBox

local function tappable(width, height, child, callback, hold_callback)
    return Ui.tappable(width, height, child, callback, hold_callback, {tap_guard = true})
end

local text_button = Cards.text_button

local HomeWidget = InputContainer:extend{
    name = "miuread_home",
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    dimen = nil,
    header_dimen = nil,
    content_dimen = nil,
    section_dimen = nil,
    _miu_closed = false,
    _quick_panel_pending = false,
}

function HomeWidget:_notify_resume_interaction(kind)
    local callback=self._miu_resume_interaction_callback
    if not callback then return end
    local now=os.clock()
    if now-(tonumber(self._miu_last_interaction_at) or 0)<.06 then return end
    self._miu_last_interaction_at=now
    local first=self._miu_resume_waiting_interaction==true
    self._miu_resume_waiting_interaction=false
    pcall(callback,first,tostring(kind or "input"))
end

function HomeWidget:handleEvent(event)
    -- ReaderUI may keep the already-built home underneath the document during
    -- page transitions. A parked home must be completely inert so its gesture
    -- ranges and child TapBoxes can never compete with the reader.
    if self._miu_input_suspended==true then return true end
    if event and event.handler=="onGesture" then
        self:_notify_resume_interaction("gesture")
        local ges=event.args and event.args[1]
        local direction=ges and ges.direction
        local gesture=ges and ges.ges
        local pos=ges and (ges.start_pos or ges.pos)
        local shelf_owned=(direction=="west" or direction=="east") and pos and self.section_dimen
            and pos.x>=self.section_dimen.x and pos.x<=self.section_dimen.x+self.section_dimen.w
            and pos.y>=self.section_dimen.y and pos.y<=self.section_dimen.y+self.section_dimen.h
        local top_owned=direction=="south" and pos and self.top_swipe_dimen
            and pos.x>=self.top_swipe_dimen.x and pos.x<=self.top_swipe_dimen.x+self.top_swipe_dimen.w
            and pos.y>=self.top_swipe_dimen.y and pos.y<=self.top_swipe_dimen.y+self.top_swipe_dimen.h
        if top_owned and (gesture == "swipe" or gesture == "pan_release")
            and self:_open_quick_panel_from_gesture(ges) then
            return true
        end
        local pointer_action=gesture=="tap" or gesture=="hold" or gesture=="hold_release"
            or gesture=="double_tap" or gesture=="two_finger_tap"

        -- Visible MiuRead controls get pointer input first. If no child consumes
        -- the pointer gesture, hand it to KOReader's configured Gesture Manager
        -- before this fullscreen page stops propagation.
        if pointer_action then
            if self:propagateEvent(event) then return true end
            if GestureBridge.dispatch(ges) then return true end
            return true
        end

        -- Configured edge/corner gestures take priority over the shelf's broad
        -- horizontal swipe area. This keeps left/right edge actions available
        -- without letting ordinary shelf swipes leak through to KOReader.
        if GestureBridge.dispatchEdge and GestureBridge.dispatchEdge(ges) then return true end
        if not shelf_owned and GestureBridge.dispatch(ges) then return true end
    end
    return InputContainer.handleEvent(self,event)
end

function HomeWidget:_add(children, x, y, widget)
    children[#children + 1] = OffsetContainer:new{x_off = x, y_off = y, widget}
end

function HomeWidget:_metrics()
    local scale = UiScale.metrics()
    local sw, sh = scale.sw, scale.sh
    local portrait = scale.portrait
    local margin = math.max(UiScale.dp(7, 7, 15), math.min(UiScale.dp(12, 9, 18), math.floor(scale.short * .016)))
    local header_h = portrait
        and math.max(UiScale.dp(42, 42, 58), math.min(UiScale.dp(56, 48, 64), math.floor(sh * .052)))
        or math.max(UiScale.dp(38, 38, 52), math.min(UiScale.dp(48, 42, 56), math.floor(sh * .068)))
    local gap = math.max(UiScale.dp(4, 4, 8), math.min(UiScale.dp(7, 5, 10), math.floor(sh * .006)))
    local line = UiScale.line("thin")
    return {
        sw = sw,
        sh = sh,
        portrait = portrait,
        margin = margin,
        gap = gap,
        line = line,
        content_w = sw - margin * 2,
        header_h = header_h,
        body_y = margin + header_h + line + gap,
        body_h = sh - (margin + header_h + line + gap) - margin,
    }
end

function HomeWidget:_register_top_swipe(m)
    if not Device:isTouchDevice() then self.ges_events={}; return end
    -- Own only the true status/header strip. The previous 18–26% zone
    -- overlapped the recent-reading card and competed with KOReader gestures,
    -- which made a pull-down feel delayed on Kindle.
    local top_h = math.max(m.header_h + m.margin + m.gap, math.floor(m.sh * .10))
    top_h = math.min(math.floor(m.sh * .14), math.max(top_h, UiScale.dp(82, 72, 118)))
    self.top_swipe_dimen = Geom:new{x = 0, y = 0, w = m.sw, h = math.min(m.sh, top_h)}
    self.ges_events={
        HomeQuickPanelSwipe={GestureRange:new{
            ges="swipe",
            range=function() return self.top_swipe_dimen end,
        }},
        HomeQuickPanelPanRelease={GestureRange:new{
            ges="pan_release",
            range=function() return self.top_swipe_dimen end,
        }},
        HomeShelfSwipe={GestureRange:new{
            ges="swipe",
            range=function() return self.section_dimen or self.content_dimen end,
        }},
    }
end

function HomeWidget:_open_quick_panel_from_gesture(ges)
    local direction = ges and ges.direction
    local start = ges and (ges.start_pos or ges.pos)
    local in_top = start and self.top_swipe_dimen
        and start.x >= self.top_swipe_dimen.x and start.x <= self.top_swipe_dimen.x + self.top_swipe_dimen.w
        and start.y >= self.top_swipe_dimen.y and start.y <= self.top_swipe_dimen.y + self.top_swipe_dimen.h
    if direction == "south" and in_top and self.opts and self.opts.on_quick_panel then
        if self._quick_panel_pending then return true end
        self._quick_panel_pending=true
        -- Finish the gesture dispatch before building the panel. This avoids
        -- competing with the underlying Gesture Manager in the same event.
        UIManager:nextTick(function()
            if self._miu_closed then return end
            self._quick_panel_pending=false
            if self.opts and self.opts.on_quick_panel then self.opts.on_quick_panel() end
        end)
        return true
    end
    return false
end
function HomeWidget:onHomeQuickPanelSwipe(_, ges)
    return self:_open_quick_panel_from_gesture(ges)
end
function HomeWidget:onHomeQuickPanelPanRelease(_, ges)
    return self:_open_quick_panel_from_gesture(ges)
end

function HomeWidget:onHomeShelfSwipe(_,ges)
    if not (ges and self.opts and self.opts.on_shelf_page) then return false end
    if ges.direction=="west" then self.opts.on_shelf_page(1); return true end
    if ges.direction=="east" then self.opts.on_shelf_page(-1); return true end
    return false
end

function HomeWidget:_build_header(children, m)
    -- Independent compact groups: account | Wi-Fi/SSID | sync | time | battery.
    -- Keep direct references to the text widgets so minute/device updates can
    -- repaint only the changed header field instead of rebuilding the home.
    local gap = math.max(UiScale.dp(2, 2, 4), math.floor(m.content_w * .003))
    local title_w = math.max(UiScale.dp(66, 58, 86), math.floor(m.content_w * .10))
    local account_w = math.max(UiScale.dp(112, 98, 145), math.floor(m.content_w * .15))
    local sync_w = math.max(UiScale.dp(94, 82, 124), math.floor(m.content_w * .13))
    local time_w = math.max(UiScale.dp(57, 51, 74), math.floor(m.content_w * .075))
    local battery_w = math.max(UiScale.dp(78, 69, 102), math.floor(m.content_w * .10))
    local menu_w = math.max(UiScale.dp(62, 55, 82), math.floor(m.content_w * .085))
    local wifi_w = math.max(UiScale.dp(132, 116, 176),
        m.content_w - title_w - account_w - sync_w - time_w - battery_w - menu_w - gap * 6)
    local used = title_w + account_w + wifi_w + sync_w + time_w + battery_w + menu_w + gap * 6
    if used > m.content_w then
        wifi_w = math.max(UiScale.dp(92, 82, 122), wifi_w - (used - m.content_w))
    end
    local account_text=tostring(self.opts.account_name or "")
    if account_text=="" then account_text="未登录" end
    local wifi_text=tostring(self.opts.wifi_text or "")
    if wifi_text=="" then wifi_text="Wi-Fi" end
    local sync_text=tostring(self.opts.sync_text or "已同步")

    local account_cell=Ui.textbox(account_text,
        account_w, m.header_h, face("smallinfofont", 10.8, 14.8), {
            bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis = true,
        })
    local wifi_value_cell=Ui.textbox(wifi_text,math.max(1,wifi_w-UiScale.dp(24,21,33)),m.header_h,
        face("smallinfofont",10.5,14.5),{
            bold=true,alignment="left",halign="left",fgcolor=Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis=true,
        })
    local sync_value_cell=Ui.textbox(sync_text,math.max(1,sync_w-UiScale.dp(22,19,30)),m.header_h,
        face("smallinfofont",10.1,14),{
            bold=true,alignment="left",halign="left",fgcolor=Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis=true,
        })
    local time_cell=Ui.textbox(tostring(self.opts.time_text or "--:--"),time_w,m.header_h,
        face("smallinfofont",10.6,14.6),{
            bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
        })
    local battery_value_cell=Ui.textbox(tostring(self.opts.battery_text or "--%"),math.max(1,battery_w-UiScale.dp(24,21,33)),m.header_h,
        face("smallinfofont",10.6,14.6),{
            bold=true,alignment="left",halign="left",fgcolor=Blitbuffer.COLOR_BLACK,
        })

    local header = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = title_w, h = m.header_h}, TextWidget:new{
            text = self.opts.title or "觅阅",
            face = face("cfont", 16.8, 21),
            bold = true,
        }},
        HorizontalSpan:new{width = gap},
        tappable(account_w, m.header_h, account_cell, self.opts.on_account),
        HorizontalSpan:new{width = gap},
        tappable(wifi_w, m.header_h, LeftContainer:new{
            dimen=Geom:new{w=wifi_w,h=m.header_h},
            HorizontalGroup:new{
                align="center",
                Ui.icon("wifi",UiScale.dp(22,19,29),m.header_h,UiScale.dp(18,16,24),{icon_key="wifi"}),
                HorizontalSpan:new{width=UiScale.dp(2,2,4)},
                wifi_value_cell,
            },
        }, self.opts.on_quick_panel),
        HorizontalSpan:new{width = gap},
        tappable(sync_w, m.header_h, LeftContainer:new{
            dimen=Geom:new{w=sync_w,h=m.header_h},
            HorizontalGroup:new{
                align="center",
                Ui.icon("sync",UiScale.dp(20,18,27),m.header_h,UiScale.dp(16,14,21),{icon_key="sync"}),
                HorizontalSpan:new{width=UiScale.dp(2,1,3)},
                sync_value_cell,
            },
        }, self.opts.on_sync or self.opts.on_quick_panel, self.opts.on_sync_hold),
        HorizontalSpan:new{width = gap},
        time_cell,
        HorizontalSpan:new{width = gap},
        CenterContainer:new{
            dimen=Geom:new{w=battery_w,h=m.header_h},
            HorizontalGroup:new{
                align="center",
                Ui.icon("battery",UiScale.dp(22,19,29),m.header_h,UiScale.dp(17,15,22),{icon_key="battery"}),
                HorizontalSpan:new{width=UiScale.dp(2,1,3)},
                battery_value_cell,
            },
        },
        HorizontalSpan:new{width = gap},
        tappable(menu_w, m.header_h,
            fixed_frame(menu_w, m.header_h, {bordersize = 0, background = Blitbuffer.COLOR_WHITE},
                Ui.text("更多", menu_w, m.header_h, face("smallinfofont", 10.8, 14.8), {bold = true})), function()
            logger.info("[MiuRead][Home] more menu tapped")
            if self.opts and self.opts.on_menu then self.opts.on_menu()
            elseif self.opts and self.opts.on_quick_panel then self.opts.on_quick_panel() end
        end),
    }

    self._header_text_refs={
        account=account_cell[1],
        wifi=wifi_value_cell[1],
        sync=sync_value_cell[1],
        time=time_cell[1],
        battery=battery_value_cell[1],
    }
    local field_x=m.margin+title_w+gap
    self._header_field_dimens={}
    self._header_field_dimens.account=Geom:new{x=field_x,y=m.margin,w=account_w,h=m.header_h}
    field_x=field_x+account_w+gap
    self._header_field_dimens.wifi=Geom:new{x=field_x,y=m.margin,w=wifi_w,h=m.header_h}
    field_x=field_x+wifi_w+gap
    self._header_field_dimens.sync=Geom:new{x=field_x,y=m.margin,w=sync_w,h=m.header_h}
    field_x=field_x+sync_w+gap
    self._header_field_dimens.time=Geom:new{x=field_x,y=m.margin,w=time_w,h=m.header_h}
    field_x=field_x+time_w+gap
    self._header_field_dimens.battery=Geom:new{x=field_x,y=m.margin,w=battery_w,h=m.header_h}

    self:_add(children, m.margin, m.margin, header)
    self:_add(children, m.margin, m.margin + m.header_h,
        LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{w = m.content_w, h = m.line or UiScale.line("thin")},
        })
end

function HomeWidget:_grid_geometry(m, width, available_h, count, force_rows)
    local columns = 4
    -- Keep every page on the same 4×2 grid. The last page leaves empty
    -- slots instead of enlarging the remaining covers.
    local rows = force_rows or 2
    rows = math.max(1, math.min(rows, 2))
    local col_gap = math.max(UiScale.dp(2, 2, 4), math.floor(m.gap * .55))
    local row_gap = math.max(UiScale.dp(3, 2, 5), math.floor(m.gap * .65))
    if rows == 2 and math.floor((available_h - row_gap) / 2) < UiScale.dp(118, 96, 170) then rows = 1 end
    local card_w = math.max(1, math.floor((width - col_gap * (columns - 1)) / columns))
    local raw_card_h = math.max(1, math.floor((available_h - row_gap * (rows - 1)) / rows))
    local preferred_card_h = math.max(UiScale.dp(160, 132, 228), math.floor(card_w * 1.80))
    local card_h = math.min(raw_card_h, preferred_card_h)
    return columns, rows, col_gap, row_gap, card_w, card_h
end

local function shelf_book_key(book)
    if type(book) ~= "table" then return "" end
    local id = tostring(book.bookId or book.book_id or "")
    if id ~= "" then return id end
    local file = tostring(book.file or "")
    if file ~= "" then return "file:" .. file end
    return ""
end

function HomeWidget:_render_grid(children, m, x, y, width, height, books, on_open, on_hold, force_rows)
    if #books == 0 then return 0 end
    local columns, rows, col_gap, row_gap, card_w, card_h = self:_grid_geometry(m, width, height, #books, force_rows)
    local capacity = columns * rows
    local slot = 0
    for _,book in ipairs(books) do
        local folder=book and (book.local_folder==true or book.kind=="folder")
        local weight=folder and 2 or 1
        if folder and slot%columns==columns-1 then slot=slot+1 end
        if slot+weight>capacity then break end
        local row = math.floor(slot / columns)
        local col = slot % columns
        local item_w = folder and (card_w * 2 + col_gap) or card_w
        local item_x = x + col * (card_w + col_gap)
        local item_y = y + row * (card_h + row_gap)
        self:_add(children,item_x,item_y,Cards.shelf_book_card(book, item_w, card_h, on_open, on_hold))
        if self._building_shelf_slots and not folder then
            local key=shelf_book_key(book)
            if key~="" then
                self._building_shelf_slots[key]={
                    parent=children,index=#children,x=item_x,y=item_y,w=item_w,h=card_h,book=book,
                }
            end
        end
        slot = slot + weight
    end
    return rows * card_h + math.max(0, rows - 1) * row_gap
end

local function page_footer(width, height, page, pages, on_page)
    page = math.max(1, tonumber(page) or 1)
    pages = math.max(1, tonumber(pages) or 1)
    local arrow_w = math.max(UiScale.dp(54, 48, 88), math.floor(width * .18))
    local middle_w = math.max(1, width - arrow_w * 2)
    local row = HorizontalGroup:new{align = "center"}
    table.insert(row, text_button("‹", arrow_w, height, page > 1 and function() on_page(-1) end or nil, {
        borderless = true, font = "cfont", size = 17, maximum = 21,
        fgcolor = page > 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }))
    table.insert(row, CenterContainer:new{dimen = Geom:new{w = middle_w, h = height}, TextWidget:new{
        text = tostring(page) .. " / " .. tostring(pages),
        face = face("smallinfofont", 9, 12),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }})
    table.insert(row, text_button("›", arrow_w, height, page < pages and function() on_page(1) end or nil, {
        borderless = true, font = "cfont", size = 17, maximum = 21,
        fgcolor = page < pages and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }))
    return row
end

function HomeWidget:_build_sections(children, m, compact, mode)
    local build_static = mode ~= "section"
    local build_section = mode ~= "static"
    local x, y, w, gap = m.margin, m.body_y, m.content_w, m.gap
    local bottom = m.body_y + m.body_h
    local notice = (self.opts.alerts or {})[1] or self.opts.download_notice
    if notice then
        local h = math.max(42, math.min(52, math.floor(m.body_h * .07)))
        if build_static then self:_add(children, x, y, Cards.notice_strip(notice, w, h)) end
        y = y + h + gap
    end

    local action_h = math.max(UiScale.dp(58, 54, 76), math.min(UiScale.dp(76, 64, 86), math.floor(m.body_h * .070)))
    local actions = self.opts.home_actions or {}
    local tabs_h = math.max(UiScale.dp(34, 31, 44), math.min(UiScale.dp(46, 37, 52), math.floor(m.body_h * .050)))
    local books = self.opts.shelf_books or {}
    local title = tostring(self.opts.shelf_title or "")
    local section_h = title ~= "" and math.max(UiScale.dp(22, 20, 30), math.min(UiScale.dp(29, 25, 35), math.floor(m.body_h * .031))) or 0

    if not m.portrait then
        if #actions > 0 and y + action_h < bottom then
            if build_static then self:_add(children, x, y, Cards.action_bar(actions, w, action_h)) end
            y = y + action_h + gap
        end
        local available_h = math.max(1, bottom - y)
        local hero_w = math.max(UiScale.dp(230, 205, 360), math.min(math.floor(w * .33), UiScale.dp(390, 330, 520)))
        local shelf_x = x + hero_w + gap
        local shelf_w = math.max(1, w - hero_w - gap)
        if build_static then
            if self.opts.hero then
                self:_add(children, x, y, Cards.hero_card(self.opts.hero, hero_w, available_h, self.opts.hero.on_tap, compact, self.opts.on_hold_book))
            else
                self:_add(children, x, y, Cards.welcome_card(hero_w, available_h, self.opts.on_empty_account))
            end
        end
        self.section_dimen = Geom:new{x = shelf_x, y = y, w = shelf_w, h = available_h}
        if build_section then
            self:_add(children, shelf_x, y, Cards.category_tabs(self.opts.tabs, shelf_w, tabs_h, self.opts.on_shelf_all))
            local sy = y + tabs_h + math.max(3, math.floor(gap * .35))
            if section_h > 0 then
                self:_add(children, shelf_x, sy, Cards.section_header(title, shelf_w, section_h, nil))
                sy = sy + section_h + math.max(2, math.floor(gap * .25))
            end
            local footer_h = math.max(34, math.min(44, math.floor(available_h * .10)))
            local grid_h = math.max(1, bottom - sy - footer_h)
            if #books > 0 then
                self:_render_grid(children, m, shelf_x, sy, shelf_w, grid_h, books, self.opts.on_open_book, self.opts.on_hold_book, 2)
            else
                self:_add(children, shelf_x, sy, Cards.empty_section(shelf_w, grid_h, self.opts.empty_text or "暂时没有内容", self.opts.on_shelf_all))
            end
            self:_add(children, shelf_x, bottom - footer_h, page_footer(shelf_w, footer_h, self.opts.shelf_page, self.opts.shelf_pages, self.opts.on_shelf_page or function() end))
        end
        return
    end

    local has_description = self.opts.hero and U.trim(tostring(self.opts.hero.description or self.opts.hero.intro or self.opts.hero.summary or "")) ~= ""
    local hero_ratio = has_description and .285 or .235
    local hero_h = compact
        and math.max(UiScale.dp(190, 180, 245), math.min(UiScale.dp(250, 220, 285), math.floor(m.body_h * .205)))
        or math.max(UiScale.dp(245, 230, 315), math.min(UiScale.dp(330, 275, 360), math.floor(m.body_h * hero_ratio)))
    if y + hero_h < bottom then
        if build_static then
            if self.opts.hero then
                self:_add(children, x, y, Cards.hero_card(self.opts.hero, w, hero_h, self.opts.hero.on_tap, compact, self.opts.on_hold_book))
            else
                self:_add(children, x, y, Cards.welcome_card(w, hero_h, self.opts.on_empty_account))
            end
        end
        y = y + hero_h + gap
    end
    if #actions > 0 and y + action_h < bottom then
        if build_static then self:_add(children, x, y, Cards.action_bar(actions, w, action_h)) end
        y = y + action_h + gap
    end
    self.section_dimen = Geom:new{x = x, y = y, w = w, h = math.max(1, bottom - y)}
    if not build_section then return end
    if y + tabs_h < bottom then
        self:_add(children, x, y, Cards.category_tabs(self.opts.tabs, w, tabs_h, self.opts.on_shelf_all))
        y = y + tabs_h + math.max(3, math.floor(gap * .35))
    end
    if section_h > 0 and y + section_h < bottom then
        self:_add(children, x, y, Cards.section_header(title, w, section_h, nil))
        y = y + section_h + math.max(2, math.floor(gap * .25))
    end
    local footer_h = math.max(36, math.min(48, math.floor(m.body_h * .045)))
    local grid_h = math.max(1, bottom - y - footer_h)
    if #books > 0 then
        self:_render_grid(children, m, x, y, w, grid_h, books, self.opts.on_open_book, self.opts.on_hold_book, 2)
    else
        self:_add(children, x, y, Cards.empty_section(w, grid_h, self.opts.empty_text or "暂时没有内容", self.opts.on_shelf_all))
    end
    self:_add(children, x, bottom - footer_h, page_footer(w, footer_h, self.opts.shelf_page, self.opts.shelf_pages, self.opts.on_shelf_page or function() end))
end

function HomeWidget:_section_cache_id(opts)
    opts=opts or self.opts or {}
    local key=tostring(opts.section_cache_key or "")
    local revision=tostring(opts.section_revision or "")
    if key=="" or revision=="" then return nil end
    return key.."|"..revision
end

function HomeWidget:_clear_inactive_section_cache()
    local cache=self._section_layer_cache
    if type(cache)~="table" then return end
    for _,entry in pairs(cache) do
        local layer=type(entry)=="table" and entry.layer or nil
        if layer and layer~=self._section_layer and layer.free then pcall(layer.free,layer) end
    end
    self._section_layer_cache=nil
    self._section_cache_clock=0
end

function HomeWidget:_remember_section_layer(cache_id,layer,region,slots)
    if not cache_id or not layer then return end
    self._section_layer_cache=type(self._section_layer_cache)=="table" and self._section_layer_cache or {}
    self._section_cache_clock=(tonumber(self._section_cache_clock) or 0)+1
    self._section_layer_cache[cache_id]={
        layer=layer,
        region=region and region:copy() or nil,
        slots=slots,
        used=self._section_cache_clock,
    }
    local count=0
    for _ in pairs(self._section_layer_cache) do count=count+1 end
    while count>8 do
        local oldest_id,oldest_entry
        for id,entry in pairs(self._section_layer_cache) do
            if entry.layer~=self._section_layer
                and (not oldest_entry or (tonumber(entry.used) or 0)<(tonumber(oldest_entry.used) or 0)) then
                oldest_id,oldest_entry=id,entry
            end
        end
        if not oldest_id then break end
        self._section_layer_cache[oldest_id]=nil
        if oldest_entry.layer and oldest_entry.layer.free then pcall(oldest_entry.layer.free,oldest_entry.layer) end
        count=count-1
    end
end

function HomeWidget:_rebuild()
    self:_clear_inactive_section_cache()
    UiScale.setDisplayMode(self.opts and self.opts.display_size or "standard")
    local m = self:_metrics()
    self._last_screen_w, self._last_screen_h = m.sw, m.sh
    self._last_rotation = Screen.getRotationMode and Screen:getRotationMode() or nil
    self._metrics_cache = m
    self.dimen = Geom:new{x = 0, y = 0, w = m.sw, h = m.sh}
    self.header_dimen = Geom:new{x = 0, y = 0, w = m.sw, h = math.min(m.sh, m.body_y)}
    self.content_dimen = Geom:new{x = 0, y = m.body_y, w = m.sw, h = math.max(1, m.sh - m.body_y)}
    self.section_dimen = self.content_dimen:copy()
    self:_register_top_swipe(m)
    local children = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    children[#children + 1] = Cards.background(m.sw, m.sh)
    self:_build_header(children, m)
    local compact = tostring(self.opts.layout_style or "standard") == "compact"
    local static_body_layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_build_sections(static_body_layer, m, compact, "static")
    children[#children + 1] = static_body_layer
    self._static_body_layer = static_body_layer
    self._static_body_layer_index = #children
    local section_layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self._building_shelf_slots={}
    self:_build_sections(section_layer, m, compact, "section")
    local section_slots=self._building_shelf_slots
    self._building_shelf_slots=nil
    children[#children + 1] = section_layer
    self._section_layer = section_layer
    self._section_book_slots=section_slots
    self._section_layer_index = #children
    self:_remember_section_layer(self:_section_cache_id(self.opts),section_layer,self.section_dimen,section_slots)
    local previous = self[1]
    self[1] = children
    if previous and previous ~= children and previous.free then pcall(previous.free, previous) end
end

function HomeWidget:_mark_dirty(kind, previous_region)
    local region
    if kind == "section" then region = self.section_dimen
    elseif kind == "header" then region = self.header_dimen
    elseif kind == "content" then region = self.content_dimen
    elseif kind == "page" then region = self.dimen
    else
        UIManager:setDirty(self, "full")
        return
    end
    if previous_region and region then region = previous_region:combine(region)
    else region = region or previous_region end
    if region then
        local safety=UiScale.dp(4,3,7)
        local x=math.max(0,(region.x or 0)-safety)
        local y=math.max(0,(region.y or 0)-safety)
        local right=math.min(Screen:getWidth(),(region.x or 0)+(region.w or 1)+safety)
        local bottom=math.min(Screen:getHeight(),(region.y or 0)+(region.h or 1)+safety)
        region=Geom:new{x=x,y=y,w=math.max(1,right-x),h=math.max(1,bottom-y)}
        UIManager:setDirty(self, function() return "ui", region end)
    else
        UIManager:setDirty(self, "full")
    end
end

function HomeWidget:update(opts, refresh_kind)
    local previous_region
    if refresh_kind == "section" and self.section_dimen then previous_region = self.section_dimen:copy()
    elseif refresh_kind == "header" and self.header_dimen then previous_region = self.header_dimen:copy()
    elseif refresh_kind == "content" and self.content_dimen then previous_region = self.content_dimen:copy()
    elseif refresh_kind == "page" and self.dimen then previous_region = self.dimen:copy() end
    self.opts = opts or self.opts or {}
    if type(self.opts.on_interaction)=="function" then
        self._miu_resume_interaction_callback=self.opts.on_interaction
    end
    self:_rebuild()
    self:_mark_dirty(refresh_kind or "full", previous_region)
    return self
end

function HomeWidget:updateHeader(fields)
    fields=type(fields)=="table" and fields or {}
    self.opts=self.opts or {}
    local refs=type(self._header_text_refs)=="table" and self._header_text_refs or {}
    local dimens=type(self._header_field_dimens)=="table" and self._header_field_dimens or {}
    local mapping={
        account_name={ref="account",default="未登录"},
        wifi_text={ref="wifi",default="Wi-Fi"},
        sync_text={ref="sync",default="已同步"},
        time_text={ref="time",default="--:--"},
        battery_text={ref="battery",default="--%"},
    }
    local changed_region
    local changed=false
    local fallback=false
    for key,spec in pairs(mapping) do
        if fields[key]~=nil then
            local value=tostring(fields[key] or "")
            local display=value~="" and value or spec.default
            if tostring(self.opts[key] or "")~=value then
                self.opts[key]=value
                changed=true
                local ref=refs[spec.ref]
                if ref and type(ref.setText)=="function" then
                    ref:setText(display)
                    local region=dimens[spec.ref]
                    if region then changed_region=changed_region and changed_region:combine(region) or region:copy() end
                else
                    fallback=true
                end
            end
        end
    end
    if not changed then return true end
    if fallback or not changed_region then return self:update(self.opts,"header") end
    local safety=UiScale.dp(3,2,5)
    local x=math.max(0,(changed_region.x or 0)-safety)
    local y=math.max(0,(changed_region.y or 0)-safety)
    local right=math.min(Screen:getWidth(),(changed_region.x or 0)+(changed_region.w or 1)+safety)
    local bottom=math.min(Screen:getHeight(),(changed_region.y or 0)+(changed_region.h or 1)+safety)
    local region=Geom:new{x=x,y=y,w=math.max(1,right-x),h=math.max(1,bottom-y)}
    UIManager:setDirty(self,function() return "ui",region end)
    return true
end

function HomeWidget:updateSection(opts)
    local started=os.clock()
    opts = opts or {}
    self.opts.tabs = opts.tabs or self.opts.tabs
    self.opts.shelf_title = opts.shelf_title or self.opts.shelf_title
    self.opts.shelf_books = opts.shelf_books or {}
    self.opts.empty_text = opts.empty_text or self.opts.empty_text
    self.opts.on_open_book = opts.on_open_book or self.opts.on_open_book
    self.opts.on_hold_book = opts.on_hold_book or self.opts.on_hold_book
    self.opts.home_actions = opts.home_actions or self.opts.home_actions
    self.opts.on_shelf_all = opts.on_shelf_all or self.opts.on_shelf_all
    self.opts.on_shelf_page = opts.on_shelf_page or self.opts.on_shelf_page
    self.opts.shelf_page = opts.shelf_page or self.opts.shelf_page
    self.opts.shelf_pages = opts.shelf_pages or self.opts.shelf_pages
    self.opts.section_cache_key = opts.section_cache_key or self.opts.section_cache_key
    self.opts.section_revision = opts.section_revision or self.opts.section_revision

    local m = self._metrics_cache
    local root = self[1]
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if not m or not root or sw ~= self._last_screen_w or sh ~= self._last_screen_h
        or not self._section_layer_index then
        return self:update(self.opts, "section")
    end
    local previous_region = self.section_dimen and self.section_dimen:copy() or nil
    local cache_id=self:_section_cache_id(self.opts)
    local cache=type(self._section_layer_cache)=="table" and self._section_layer_cache or {}
    local cached=cache_id and cache[cache_id] or nil
    local section_layer=cached and cached.layer or nil
    local cache_hit=section_layer~=nil
    local section_slots
    if not section_layer then
        section_layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
        self._building_shelf_slots={}
        self:_build_sections(section_layer, m, tostring(self.opts.layout_style or "standard") == "compact", "section")
        section_slots=self._building_shelf_slots
        self._building_shelf_slots=nil
        self:_remember_section_layer(cache_id,section_layer,self.section_dimen,section_slots)
    else
        section_slots=cached.slots
        if cached.region then
            self.section_dimen=cached.region:copy()
            self._section_cache_clock=(tonumber(self._section_cache_clock) or 0)+1
            cached.used=self._section_cache_clock
        end
    end
    local old = root[self._section_layer_index]
    root[self._section_layer_index] = section_layer
    self._section_layer = section_layer
    self._section_book_slots=section_slots
    -- Old layers stay alive in the bounded cache. They are freed on eviction,
    -- full rebuild or home close, so switching back does not recreate covers.
    self:_mark_dirty("section", previous_region)
    logger.info("[MiuRead][HomeSwitch] layer",
        "key=",tostring(cache_id or "none"),"cache_hit=",tostring(cache_hit),
        "ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
    return self
end


function HomeWidget:updateHero(hero)
    self.opts = self.opts or {}
    self.opts.hero = hero
    local m = self._metrics_cache
    local root = self[1]
    if not m or not root or not self._static_body_layer_index
        or Screen:getWidth() ~= self._last_screen_w or Screen:getHeight() ~= self._last_screen_h then
        return self:update(self.opts, "content")
    end
    local previous_region = self.content_dimen and self.content_dimen:copy() or nil
    local previous_section = self.section_dimen and self.section_dimen:copy() or nil
    local layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_build_sections(layer, m, tostring(self.opts.layout_style or "standard") == "compact", "static")
    local current_section = self.section_dimen and self.section_dimen:copy() or nil
    local same_geometry = previous_section and current_section
        and previous_section.x == current_section.x and previous_section.y == current_section.y
        and previous_section.w == current_section.w and previous_section.h == current_section.h
    if not same_geometry then
        if layer.free then pcall(layer.free, layer) end
        return self:update(self.opts, "content")
    end
    local old = root[self._static_body_layer_index]
    root[self._static_body_layer_index] = layer
    self._static_body_layer = layer
    if old and old ~= layer and old.free then pcall(old.free, old) end
    self:_mark_dirty("content", previous_region)
    return self
end

function HomeWidget:updateBook(book_id)
    local key=tostring(book_id or "")
    if key=="" then return false end
    local slots=type(self._section_book_slots)=="table" and self._section_book_slots or {}
    local slot=slots[key]
    if not slot or not slot.parent or not slot.index then return false end
    local book
    for _,candidate in ipairs(self.opts.shelf_books or {}) do
        if shelf_book_key(candidate)==key then book=candidate; break end
    end
    if not book then return false end
    local old=slot.parent[slot.index]
    local replacement=OffsetContainer:new{
        x_off=slot.x,y_off=slot.y,
        Cards.shelf_book_card(book,slot.w,slot.h,self.opts.on_open_book,self.opts.on_hold_book),
    }
    slot.parent[slot.index]=replacement
    slot.book=book
    if old and old~=replacement and old.free then pcall(old.free,old) end
    local safety=UiScale.dp(3,2,5)
    local x=math.max(0,slot.x-safety)
    local y=math.max(0,slot.y-safety)
    local right=math.min(Screen:getWidth(),slot.x+slot.w+safety)
    local bottom=math.min(Screen:getHeight(),slot.y+slot.h+safety)
    local region=Geom:new{x=x,y=y,w=math.max(1,right-x),h=math.max(1,bottom-y)}
    UIManager:setDirty(self,function() return "ui",region end)
    logger.info("[MiuRead][HomeBook] updated", "book=",key,"w=",tostring(slot.w),"h=",tostring(slot.h))
    return true
end

function HomeWidget:init()
    self.key_events = self.key_events or {}
    if Device:hasKeys() then
        if Device.input and Device.input.group and Device.input.group.Back then
            self.key_events.Back = {{Device.input.group.Back}}
        end
        self.key_events.Menu = {{"Menu"}}
        self.key_events.Home = {{"Home"}}
        if Device.input and Device.input.group then
            if Device.input.group.PgFwd then self.key_events.ShelfNext = {{Device.input.group.PgFwd}} end
            if Device.input.group.PgBack then self.key_events.ShelfPrevious = {{Device.input.group.PgBack}} end
        end
    end
    self:_rebuild()
end

function HomeWidget:onShelfNext()
    self:_notify_resume_interaction("page-next")
    if self.opts and self.opts.on_shelf_page then self.opts.on_shelf_page(1) end
    return true
end
function HomeWidget:onShelfPrevious()
    self:_notify_resume_interaction("page-previous")
    if self.opts and self.opts.on_shelf_page then self.opts.on_shelf_page(-1) end
    return true
end

function HomeWidget:onMenu()
    self:_notify_resume_interaction("menu")
    logger.info("[MiuRead][Home] physical menu")
    if self.opts and self.opts.on_menu then self.opts.on_menu() end
    return true
end
function HomeWidget:onBack()
    self:_notify_resume_interaction("back")
    if self.opts and self.opts.on_back then
        local ok,handled=pcall(self.opts.on_back)
        if ok and handled==true then
            logger.info("[MiuRead][Home] back handled by current section")
            return true
        end
    end
    -- The MiuRead home is the root page. Back must not leak to FileManager.
    logger.info("[MiuRead][Home] back consumed at root")
    return true
end
function HomeWidget:onHome()
    self:_notify_resume_interaction("home")
    logger.info("[MiuRead][Home] home consumed at root")
    return true
end

function HomeWidget:onSetDimensions()
    return self:_schedule_dimension_refresh()
end
function HomeWidget:_close_rotation_transients()
    local stack = UIManager._window_stack or {}
    for index = #stack, 1, -1 do
        local widget = stack[index] and stack[index].widget or nil
        if widget and widget ~= self and widget._miuread_transient == true
            and widget.name ~= "miuread_full_shelf"
            and UIManager:isWidgetShown(widget) then
            pcall(UIManager.close, UIManager, widget)
        end
    end
end

function HomeWidget:_capture_pending_dimensions()
    self._pending_screen_w=Screen:getWidth()
    self._pending_screen_h=Screen:getHeight()
    self._pending_rotation=Screen.getRotationMode and Screen:getRotationMode() or nil
    self._pending_dimension_refresh=true
    return true
end

function HomeWidget:_commit_pending_dimensions(force_rebuild)
    local sw,sh=Screen:getWidth(),Screen:getHeight()
    local rotation=Screen.getRotationMode and Screen:getRotationMode() or nil
    self._pending_screen_w,self._pending_screen_h=sw,sh
    self._pending_rotation=rotation
    local changed=force_rebuild==true or sw~=self._last_screen_w or sh~=self._last_screen_h
        or rotation~=self._last_rotation
    self._pending_dimension_refresh=false
    if not changed then return false end
    self:_close_rotation_transients()
    self:_clear_inactive_section_cache()
    self:_rebuild()
    return true
end

function HomeWidget:_schedule_dimension_refresh()
    self._dimension_refresh_generation = (tonumber(self._dimension_refresh_generation) or 0) + 1
    local generation = self._dimension_refresh_generation
    if self._dimension_refresh_task then
        UIManager:unschedule(self._dimension_refresh_task)
        self._dimension_refresh_task=nil
    end
    self:_capture_pending_dimensions()

    -- Parked Home and the lock-screen path must stay completely passive. The
    -- latest geometry is applied once, immediately before Home becomes active.
    if self._miu_input_suspended==true or self._miu_device_suspended==true then
        return true
    end

    local last_w,last_h,last_rotation,stable,attempts=nil,nil,nil,0,0
    local task
    task=function()
        if self._miu_closed or self._dimension_refresh_task~=task
            or generation ~= self._dimension_refresh_generation then return end
        if self._miu_input_suspended==true or self._miu_device_suspended==true then
            self._dimension_refresh_task=nil
            self:_capture_pending_dimensions()
            return
        end
        attempts=attempts+1
        local sw,sh=Screen:getWidth(),Screen:getHeight()
        local rotation=Screen.getRotationMode and Screen:getRotationMode() or nil
        if sw==last_w and sh==last_h and rotation==last_rotation then
            stable=stable+1
        else
            last_w,last_h,last_rotation,stable=sw,sh,rotation,0
        end
        if stable<2 and attempts<8 then
            UIManager:scheduleIn(.12,task)
            return
        end
        self._dimension_refresh_task=nil
        local changed=self:_commit_pending_dimensions(false)
        if changed then UIManager:setDirty(self,"full") end
        logger.info("[MiuRead][Rotation] home committed",
            "samples=",tostring(attempts),"changed=",tostring(changed),
            "size=",tostring(sw).."x"..tostring(sh),"rotation=",tostring(rotation))
    end
    self._dimension_refresh_task=task
    UIManager:scheduleIn(.30,task)
    return true
end
function HomeWidget:onScreenResize() return self:_schedule_dimension_refresh() end
function HomeWidget:onRotation() return self:_schedule_dimension_refresh() end

function HomeWidget:onCloseWidget()
    self._miu_closed = true
    self._dimension_refresh_generation=(tonumber(self._dimension_refresh_generation) or 0)+1
    if self._dimension_refresh_task then UIManager:unschedule(self._dimension_refresh_task); self._dimension_refresh_task=nil end
    self:_clear_inactive_section_cache()
    if live_widget == self then live_widget = nil end
    if self.opts and self.opts.on_close then pcall(self.opts.on_close, self) end
end

local HomeView = {}
local function stacked_home_widgets()
    local rows = {}
    for _, window in ipairs(UIManager._window_stack or {}) do
        local widget = window and window.widget or nil
        if widget and widget.name == "miuread_home" and not widget._miu_closed then rows[#rows + 1] = widget end
    end
    return rows
end
function HomeView.prune_duplicates()
    local rows = stacked_home_widgets()
    if #rows == 0 then
        if live_widget and (live_widget._miu_closed or not UIManager:isWidgetShown(live_widget)) then live_widget = nil end
        return 0
    end
    local keep = nil
    if live_widget and not live_widget._miu_closed and UIManager:isWidgetShown(live_widget) then keep = live_widget end
    if not keep then keep = rows[#rows]; live_widget = keep end
    local closed = 0
    for _, widget in ipairs(rows) do
        if widget ~= keep then
            widget._miu_superseded = true
            widget._miu_suppress_restore = true
            pcall(UIManager.close, UIManager, widget)
            closed = closed + 1
        end
    end
    if closed > 0 then logger.warn("[MiuRead][Home] duplicate roots removed", tostring(closed)) end
    return closed
end
function HomeView.current() return live_widget end
function HomeView.is_shown()
    HomeView.prune_duplicates()
    return live_widget and not live_widget._miu_closed and UIManager:isWidgetShown(live_widget)
end
function HomeView.is_parked()
    return HomeView.is_shown() and live_widget._miu_input_suspended==true
end
-- Keep the rendered home in UIManager's stack while ReaderUI owns the screen.
-- This avoids briefly exposing FileManager during open/close, while disabling
-- all home input prevents the stale gesture-zone issue seen in older builds.
function HomeView.park()
    if not HomeView.is_shown() then return false end
    live_widget._miu_input_suspended=true
    live_widget._miu_resume_interaction_callback=nil
    live_widget._miu_resume_waiting_interaction=false
    return true
end
function HomeView.suspend()
    if not HomeView.is_shown() then return false end
    live_widget._miu_device_suspended=true
    live_widget._dimension_refresh_generation=(tonumber(live_widget._dimension_refresh_generation) or 0)+1
    if live_widget._dimension_refresh_task then
        UIManager:unschedule(live_widget._dimension_refresh_task)
        live_widget._dimension_refresh_task=nil
    end
    live_widget:_capture_pending_dimensions()
    return true
end
function HomeView.unpark(skip_dirty,opts)
    if not HomeView.is_shown() then return false end
    opts=type(opts)=="table" and opts or {}
    live_widget._miu_device_suspended=false
    local rebuilt=live_widget:_commit_pending_dimensions(false)
    live_widget._miu_input_suspended=false
    if type(opts.on_interaction)=="function" then
        live_widget._miu_resume_interaction_callback=opts.on_interaction
        live_widget._miu_resume_waiting_interaction=true
        live_widget._miu_last_interaction_at=0
    end
    if live_widget._metrics_cache then live_widget:_register_top_swipe(live_widget._metrics_cache) end
    if skip_dirty~=true then UIManager:setDirty(live_widget,rebuilt and "full" or "ui")
    elseif rebuilt then UIManager:setDirty(live_widget,"full") end
    return true
end
-- FileManager is recreated after ReaderUI closes so KOReader's docless
-- plugins (including Gesture Manager) remain alive beneath MiuRead. Move the
-- already-built home above that native base without closing/rebuilding it.
function HomeView.raise(skip_dirty)
    HomeView.prune_duplicates()
    if not HomeView.is_shown() then return false end
    local stack = UIManager._window_stack or {}
    local window, index
    for i = #stack, 1, -1 do
        if stack[i] and stack[i].widget == live_widget then
            window, index = stack[i], i
            break
        end
    end
    if not window then return false end
    table.remove(stack, index)
    local insert_at = 1
    -- Match UIManager:show ordering for a standard non-modal widget: below
    -- modal dialogs/toasts, above the uppermost normal page.
    for i = #stack, 0, -1 do
        local top = stack[i]
        if top and top.widget and top.widget.toast then
            -- Keep looking below the toast group.
        elseif not top or not top.widget or not top.widget.modal then
            insert_at = i + 1
            break
        end
    end
    table.insert(stack, insert_at, window)
    if skip_dirty~=true then UIManager:setDirty(live_widget, "ui") end
    return true
end
function HomeView.resume(opts)
    if not HomeView.is_shown() then return false end
    opts=opts or {}
    live_widget._miu_device_suspended=false
    local rebuilt=live_widget:_commit_pending_dimensions(opts.rebuild_visual==true)
    live_widget._miu_input_suspended=false
    live_widget._miu_resume_interaction_callback=opts.on_interaction
    live_widget._miu_resume_waiting_interaction=true
    live_widget._miu_last_interaction_at=0
    if live_widget._metrics_cache then live_widget:_register_top_swipe(live_widget._metrics_cache) end
    -- Resume never reorders UIManager._window_stack. If the long-sleep visual
    -- geometry is stale, rebuild this existing widget in place and repaint it.
    UIManager:setDirty(live_widget,rebuilt and "full" or "ui")
    return true
end

function HomeView.close(full_refresh)
    HomeView.prune_duplicates()
    if live_widget and not live_widget._miu_closed then UIManager:close(live_widget) end
    live_widget = nil
    if full_refresh == true then
        UIManager:scheduleIn(.04, function()
            if UIManager._exit_code == nil then UIManager:setDirty("all", "full") end
        end)
    end
end
function HomeView.refresh(kind)
    if not HomeView.is_shown() then return false end
    local ok, err = pcall(live_widget.update, live_widget, live_widget.opts or {}, kind or "content")
    if not ok then logger.warn("[MiuRead][Home] refresh failed", tostring(err)); return false end
    return true
end
function HomeView.update_header(fields)
    if not HomeView.is_shown() or not live_widget.updateHeader then return false end
    local ok, updated = pcall(live_widget.updateHeader, live_widget, fields or {})
    if not ok then logger.warn("[MiuRead][Home] header update failed", tostring(updated)); return false end
    return updated~=false
end
function HomeView.update_time(text)
    return HomeView.update_header{time_text=tostring(text or "--:--")}
end
function HomeView.update_section(opts)
    if not HomeView.is_shown() or not live_widget.updateSection then return false end
    local ok, err = pcall(live_widget.updateSection, live_widget, opts or {})
    if not ok then logger.warn("[MiuRead][Home] section update failed", tostring(err)); return false end
    return true
end
function HomeView.update_book(book_id)
    if not HomeView.is_shown() or not live_widget.updateBook then return false end
    local ok, updated = pcall(live_widget.updateBook, live_widget, book_id)
    if not ok then logger.warn("[MiuRead][Home] book update failed", tostring(updated)); return false end
    return updated==true
end
function HomeView.update_hero(hero)
    if not HomeView.is_shown() or not live_widget.updateHero then return false end
    local ok, updated = pcall(live_widget.updateHero, live_widget, hero)
    if not ok then logger.warn("[MiuRead][Home] hero update failed", tostring(updated)); return false end
    return updated~=false
end
function HomeView.show(opts, refresh_kind)
    opts = opts or {}
    HomeView.prune_duplicates()
    if HomeView.is_shown() then
        local ok, err = pcall(live_widget.update, live_widget, opts, refresh_kind)
        if ok then return live_widget end
        logger.warn("[MiuRead][Home] in-place update failed", tostring(err))
    end
    if live_widget and not live_widget._miu_closed then
        live_widget._miu_superseded = true
        live_widget._miu_suppress_restore = true
        UIManager:close(live_widget)
    end
    local ok, widget = pcall(HomeWidget.new, HomeWidget, {opts = opts})
    if not ok or not widget then
        logger.err("[MiuRead][Home] build failed", tostring(widget))
        return nil, tostring(widget)
    end
    home_generation = home_generation + 1
    widget._miu_home_generation = home_generation
    widget._miu_resume_interaction_callback=opts.on_interaction
    widget._miu_resume_waiting_interaction=false
    live_widget = widget
    UIManager:show(widget, "ui", widget.dimen)
    HomeView.prune_duplicates()
    return widget
end
return HomeView
