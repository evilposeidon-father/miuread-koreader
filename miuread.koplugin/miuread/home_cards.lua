local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local U = require("miuread.util")
local UiScale = require("miuread.ui_scale")
local Ui = require("miuread.ui_components")

local function face(name, nominal, maximum, minimum)
    return Ui.face(name, nominal, maximum, minimum)
end

local OffsetContainer = Ui.OffsetContainer

local RoundedImageContainer = WidgetContainer:extend{width = 1, height = 1, radius = 0, ink_boost = 0}
function RoundedImageContainer:getSize()
    return Geom:new{w = self.width, h = self.height}
end
function RoundedImageContainer:paintTo(bb, x, y)
    if self[1] then self[1]:paintTo(bb, x, y) end
    local boost = math.max(0, math.min(.18, tonumber(self.ink_boost) or 0))
    if boost > 0 and bb and type(bb.darkenRect) == "function" then
        -- A light contrast lift keeps pale covers legible on e-ink without
        -- turning dark covers into solid blocks.
        pcall(bb.darkenRect, bb, x, y, self.width, self.height, boost)
    end
    local r = math.max(0, math.min(math.floor(self.radius or 0), math.floor(math.min(self.width, self.height) / 2)))
    if r <= 1 or not bb or type(bb.paintRect) ~= "function" then return end
    -- Mask only the four corner pixels. This keeps the image flush with its
    -- box while giving the cover itself rounded corners, without a padded frame.
    for row = 0, r - 1 do
        local dy = r - row
        local inside = math.sqrt(math.max(0, r * r - dy * dy))
        local inset = math.max(0, math.floor(r - inside + .5))
        if inset > 0 then
            bb:paintRect(x, y + row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + self.width - inset, y + row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x, y + self.height - 1 - row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + self.width - inset, y + self.height - 1 - row, inset, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

local Skin = require("miuread.reader_skin")
local UiRows = require("miuread.ui_rows")
local fixed_frame = Skin.frame

local function background(width, height)
    return fixed_frame(width, height, {background = Blitbuffer.COLOR_WHITE})
end

local TapBox = Ui.TapBox

local function tappable(width, height, child, callback, hold_callback)
    return Ui.tappable(width, height, child, callback, hold_callback, {tap_guard = true})
end

local function text_button(text, width, height, callback, options)
    options = options or {}
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = options.borderless and 0 or Skin.line("thin"),
        padding = UiScale.dp(3, 2, 6),
        background = Blitbuffer.COLOR_WHITE,
    }, TextWidget:new{
        text = tostring(text or ""),
        face = face(options.font or "smallinfofont", options.size or 12, options.maximum or 16),
        bold = options.bold ~= false,
        fgcolor = options.fgcolor or Blitbuffer.COLOR_BLACK,
    }), callback)
end

local function image_widget(path, width, height, ink_boost)
    if not path or path == "" then return nil end
    local image
    local ok = pcall(function()
        image = ImageWidget:new{
            file = path,
            width = width,
            height = height,
            -- Stretch into the cover box. Book covers are already close to the
            -- target ratio, and this avoids the visible inner blank frame that
            -- scale-to-fit produced on Kindle.
            scale_factor = nil,
            -- Always use MuPDF scaling for covers. Legacy scaling is faster on
            -- a few old devices but visibly softer at small e-ink sizes.
            use_legacy_image_scaling = false,
            file_do_cache = true,
        }
        image:getSize()
    end)
    if ok and image then
        return RoundedImageContainer:new{
            width = width,
            height = height,
            radius = Skin.radius(7, 5, 13),
            ink_boost = tonumber(ink_boost) or .08,
            image,
        }
    end
    if image and image.free then pcall(image.free, image) end
    return nil
end

local function placeholder(width, height, title, author)
    title = U.trim(tostring(title or "未命名"))
    author = U.trim(tostring(author or ""))
    if title == "" then title = "未命名" end
    local pad = UiScale.dp(3, 2, 5)
    local content_w = math.max(1, width - pad * 2)
    local content_h = math.max(1, height - pad * 2)
    local title_h = math.max(1, math.floor(content_h * (author ~= "" and .58 or .78)))
    local author_h = math.max(1, content_h - title_h)
    local body = VerticalGroup:new{
        align = "center",
        TextBoxWidget:new{
            text = U.utf8_truncate(title, 24, "…"),
            face = face("cfont", 10.8, 15.5), bold = true,
            width = math.max(1, content_w - UiScale.dp(4, 3, 7)), height = title_h,
            height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center",
        },
    }
    if author ~= "" then
        body[#body + 1] = TextBoxWidget:new{
            text = U.utf8_truncate(author, 18, "…"),
            face = face("smallinfofont", 7.8, 10.8),
            width = math.max(1, content_w - UiScale.dp(4, 3, 7)), height = author_h,
            height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    end
    return fixed_frame(width, height, {
        bordersize = Skin.line("thin"),
        radius = Skin.radius(6, 4, 12),
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_GRAY,
    }, body)
end

local function solid_bar(width, height, color)
    return fixed_frame(width, height, {background = color or Blitbuffer.COLOR_BLACK})
end

local function progress_bar(width, height, progress)
    progress = math.max(0, math.min(1, tonumber(progress) or 0))
    local filled = math.floor(width * progress + .5)
    local rest = math.max(0, width - filled)
    local row = HorizontalGroup:new{align = "center"}
    if filled > 0 then table.insert(row, solid_bar(filled, height, Blitbuffer.COLOR_BLACK)) end
    if rest > 0 then table.insert(row, solid_bar(rest, height, Blitbuffer.COLOR_GRAY)) end
    return row
end

local function section_header(title, width, height, on_more)
    -- Keep the full-shelf function without letting a large “全部” label steal
    -- cover space. The grid icon opens the same 4-column full-screen shelf.
    local right_w = on_more and math.max(UiScale.dp(38, 34, 56), math.floor(width * .075)) or 0
    local left_w = width - right_w
    local row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = left_w, h = height}, TextWidget:new{
            text = tostring(title or ""),
            face = face("cfont", 15, 19),
            bold = true,
        }},
    }
    if on_more then
        table.insert(row, tappable(right_w, height,
            Ui.icon("grid", right_w, height, UiScale.dp(21, 18, 28), {
                face = UiScale.iconFace("cfont", 16, 22, 13),
            }), on_more))
    end
    return row
end

local function notice_strip(item, width, height)
    local pad = UiScale.dp(6, 5, 10)
    local progress_w = item.progress and math.max(92, math.floor(width * .20)) or 0
    local detail_w = math.max(1, width - progress_w - pad * 3)
    local text = tostring(item.title or "")
    if item.detail and tostring(item.detail) ~= "" then
        text = text .. "　" .. tostring(item.detail)
    end
    local row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = detail_w, h = height - pad * 2}, TextBoxWidget:new{
            text = text,
            face = face("smallinfofont", 10.5, 15),
            bold = true,
            width = detail_w,
            height = height - pad * 2,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }},
    }
    if progress_w > 0 then
        table.insert(row, HorizontalSpan:new{width = pad})
        table.insert(row, progress_bar(progress_w, UiScale.dp(3, 2, 5), item.progress))
    end
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = item.important == true and Skin.line("thick") or Skin.line("thin"),
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
    }, row), item.on_tap)
end

local function hero_card(book, width, height, callback, compact, hold_callback)
    -- Draw the border inside the card's refresh rectangle. A line exactly on
    -- the outer edge is clipped on a few Kindle/Kobo framebuffer paths.
    local frame_inset = math.max(1, UiScale.dp(2, 2, 3))
    local frame_w = math.max(1, width - frame_inset * 2)
    local frame_h = math.max(1, height - frame_inset * 2)
    local pad = math.max(UiScale.dp(7, 6, 12), math.min(UiScale.dp(12, 10, 18), math.floor(math.min(frame_w, frame_h) * .030)))
    local inner_w = math.max(1, frame_w - pad * 2)
    local inner_h = math.max(1, frame_h - pad * 2)
    local cover_w = math.max(UiScale.dp(76, 64, 110), math.min(
        math.floor(inner_w * (compact and .24 or .27)),
        math.floor(inner_h * .82)
    ))
    local cover_h = math.max(UiScale.dp(108, 92, 155), math.min(inner_h, math.floor(cover_w / .68)))
    local cover = image_widget(book.home_cover_path or book.cover_path, cover_w, cover_h, .05) or placeholder(cover_w, cover_h, book.title, book.author)
    local gap = math.max(UiScale.dp(9, 7, 14), math.floor(width * .014))
    local text_w = math.max(1, inner_w - cover_w - gap)
    local heading_h = UiScale.dp(22, 20, 30)
    local refresh_w = book.on_refresh_metadata and math.max(UiScale.dp(28, 25, 40), heading_h) or 0
    local heading_text_w = math.max(1, text_w - (refresh_w > 0 and refresh_w + UiScale.dp(3, 2, 5) or 0))
    local title_h = UiScale.dp(compact and 44 or 54, compact and 40 or 48, compact and 64 or 76)
    local line_h = UiScale.dp(27, 23, 36)
    local bar_h = math.max(3, UiScale.dp(6, 5, 9))
    local description_h = math.max(UiScale.dp(52, 44, 78), inner_h - heading_h - title_h - line_h * 3 - bar_h)
    local progress_value = math.max(0, math.min(100, tonumber(book.progress) or 0))
    local progress_text = progress_value > 0
        and ("阅读至 " .. tostring(math.floor(progress_value + .5)) .. "%")
        or "尚未开始"
    if book.last_read_text and tostring(book.last_read_text) ~= "" then
        progress_text = progress_text .. " · " .. tostring(book.last_read_text)
    end
    local author = U.trim(tostring(book.author or ""))
    local source = U.trim(tostring(book.source_text or ""))
    local category = U.trim(tostring(book.category or ""))
    local publisher = U.trim(tostring(book.publisher or ""))
    local published_date = U.trim(tostring(book.published_date or book.publish_date or ""))
    published_date = published_date:match("^(%d%d%d%d)") or published_date
    local meta = {}
    for _, value in ipairs({author, category}) do
        if value ~= "" then meta[#meta + 1] = value end
    end
    local source_meta = {}
    for _, value in ipairs({source, publisher, published_date}) do
        if value ~= "" then source_meta[#source_meta + 1] = value end
    end
    local description = U.trim(tostring(book.description or book.intro or book.summary or ""))
    if description == "" then
        local substitutes = {}
        for _, value in ipairs({book.translator, book.series, book.language}) do
            value = U.trim(tostring(value or ""))
            if value ~= "" then substitutes[#substitutes + 1] = value end
        end
        description = #substitutes > 0 and table.concat(substitutes, " · ") or "点击查看详情或继续阅读"
    end

    local text = VerticalGroup:new{align = "left"}
    table.insert(text, TextBoxWidget:new{
        text = tostring(book.heading or "最近阅读"),
        face = face("smallinfofont", 10.5, 15), bold = true,
        width = heading_text_w, height = heading_h, height_adjust = false,
        height_overflow_show_ellipsis = true, fgcolor = Blitbuffer.COLOR_BLACK,
    })
    table.insert(text, TextBoxWidget:new{
        text = tostring(book.title or "未命名"),
        face = face("cfont", compact and 17 or 19, compact and 22 or 25), bold = true,
        width = text_w, height = title_h, height_adjust = false,
        height_overflow_show_ellipsis = true,
    })
    table.insert(text, TextBoxWidget:new{
        text = table.concat(meta, " · "),
        face = face("smallinfofont", 10.5, 15),
        width = text_w, height = line_h, height_adjust = false,
        height_overflow_show_ellipsis = true, fgcolor = Blitbuffer.COLOR_BLACK,
    })
    table.insert(text, TextBoxWidget:new{
        text = progress_text,
        face = face("smallinfofont", 10.5, 15), bold = true,
        width = text_w, height = line_h, height_adjust = false,
        height_overflow_show_ellipsis = true, fgcolor = Blitbuffer.COLOR_BLACK,
    })
    -- WeRead-style progress bar under the progress line.
    table.insert(text, progress_bar(text_w, bar_h, progress_value / 100))
    table.insert(text, TextBoxWidget:new{
        text = table.concat(source_meta, " · "),
        face = face("smallinfofont", 10, 14),
        width = text_w, height = line_h, height_adjust = false,
        height_overflow_show_ellipsis = true, fgcolor = Blitbuffer.COLOR_BLACK,
    })
    table.insert(text, TextBoxWidget:new{
        text = description,
        face = face("smallinfofont", 11.5, 17),
        width = text_w, height = description_h, height_adjust = false,
        height_overflow_show_ellipsis = true, fgcolor = Blitbuffer.COLOR_BLACK,
    })

    local content = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    content[#content + 1] = OffsetContainer:new{
        x_off = frame_inset,
        y_off = frame_inset,
        fixed_frame(frame_w, frame_h, {
            bordersize = math.max(Skin.line("thin"), 1),
            radius = Skin.radius(9, 6, 15),
            padding = pad,
            background = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_DARK_GRAY,
        }, HorizontalGroup:new{
            align = "center",
            cover,
            HorizontalSpan:new{width = gap},
            text,
        }),
    }
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    -- Paint the card once, then place small transparent input zones over it.
    -- The refresh zone is registered before the full-card zone so tapping the
    -- icon cannot accidentally open the book underneath.
    layers[#layers + 1] = content
    if refresh_w > 0 then
        local refresh_x = frame_inset + pad + cover_w + gap + math.max(0, text_w - refresh_w)
        local refresh_y = frame_inset + pad
        layers[#layers + 1] = OffsetContainer:new{
            x_off = refresh_x, y_off = refresh_y,
            tappable(refresh_w, heading_h, Ui.icon("refresh", refresh_w, heading_h,
                math.max(UiScale.dp(17, 15, 24), math.floor(heading_h * .72)), {
                    face = UiScale.iconFace("cfont", 14, 19, 11),
                }), function()
                if book.on_refresh_metadata then book.on_refresh_metadata() end
            end),
        }
    end
    layers[#layers + 1] = tappable(width, height, Widget:new{dimen = Geom:new{w = width, h = height}}, callback, function(anchor)
        if hold_callback then hold_callback(book, anchor) end
    end)
    return layers
end

local function welcome_card(width, height, callback)
    local inset = math.max(1, UiScale.dp(2, 2, 3))
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layers[#layers + 1] = OffsetContainer:new{
        x_off = inset, y_off = inset,
        fixed_frame(math.max(1, width - inset * 2), math.max(1, height - inset * 2), {
            bordersize = math.max(Skin.line("thin"), 1),
            radius = Skin.radius(9, 6, 15),
            background = Blitbuffer.COLOR_WHITE,
        }, VerticalGroup:new{
            align = "center",
            TextWidget:new{text = "开始阅读", face = UiScale.iconFace("cfont", 18, 24), bold = true},
            VerticalSpan:new{height = UiScale.dp(7, 5, 10)},
            TextWidget:new{
                text = "从微信书架选择一本书",
                face = face("smallinfofont", 11, 14),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        }),
    }
    return tappable(width, height, layers, callback)
end

local function shelf_folder_card(folder, width, height, callback)
    local inner_w = math.max(1, width - UiScale.dp(8, 6, 12))
    local icon_h = math.max(UiScale.dp(52, 44, 72), math.floor(height * .48))
    local title_h = math.max(UiScale.dp(30, 26, 42), math.floor(height * .24))
    local detail_h = math.max(UiScale.dp(20, 17, 28), height - icon_h - title_h - UiScale.dp(10, 8, 15))
    local icon_key = folder.local_parent==true and "back" or "folder"
    local body = VerticalGroup:new{
        align = "center",
        Ui.icon(icon_key, inner_w, icon_h, UiScale.dp(34, 29, 48), {
            face = UiScale.iconFace("cfont", 24, 34),
        }),
        TextBoxWidget:new{
            text = tostring(folder.title or "文件夹"), face = face("cfont", 11.8, 16.5), bold = true,
            width = inner_w, height = title_h, height_adjust = false,
            height_overflow_show_ellipsis = true, alignment = "center",
        },
        TextBoxWidget:new{
            text = tostring(folder.status_text or "文件夹"), face = face("smallinfofont", 8.7, 12),
            width = inner_w, height = detail_h, height_adjust = false,
            height_overflow_show_ellipsis = true, alignment = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        },
    }
    local card = fixed_frame(width, height, {
        bordersize = Skin.line("thin"), padding = UiScale.dp(4, 3, 7),
        radius = Skin.radius(8, 6, 13), background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_GRAY,
    }, body)
    return tappable(width, height, card, function(anchor)
        if callback then callback(folder, anchor) end
    end)
end

local function outlined_badge_text(text, width, height, badge_face)
    local layer = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    local radius = math.max(2, UiScale.dp(2, 2, 3))
    local offsets = {
        {-radius,0},{radius,0},{0,-radius},{0,radius},
        {-radius,-radius},{-radius,radius},{radius,-radius},{radius,radius},
    }
    for _, off in ipairs(offsets) do
        layer[#layer + 1] = OffsetContainer:new{
            x_off = off[1], y_off = off[2],
            CenterContainer:new{dimen = Geom:new{w = width, h = height}, TextWidget:new{
                text = text, face = badge_face, bold = true, fgcolor = Blitbuffer.COLOR_WHITE,
            }},
        }
    end
    layer[#layer + 1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, TextWidget:new{
        text = text, face = badge_face, bold = true, fgcolor = Blitbuffer.COLOR_BLACK,
    }}
    return layer
end

local function shelf_book_card(book, width, height, callback, hold_callback)
    if book and (book.local_folder==true or book.kind=="folder") then
        return shelf_folder_card(book,width,height,callback)
    end
    local pad = math.max(UiScale.dp(1, 0, 2), math.floor(width * .004))
    local inner_w = math.max(1, width - pad * 2)
    local progress = math.max(0, math.min(100, tonumber(book.progress) or 0))
    local status = U.trim(tostring(book.status_text or ""))
    local downloaded = status == "已生成" or status == "已下载" or book.generated == true
        or book.downloaded == true or tostring(book.shelf_section or "") == "generated"
        or (book.file and tostring(book.file) ~= "" and U.file_exists(tostring(book.file)))
    local reading_badge = ""
    if progress >= 100 then reading_badge = "已读"
    elseif progress > 0 then reading_badge = tostring(math.floor(progress + .5)) .. "%" end

    local download_active = book.download_active == true
    local download_progress = math.max(0, math.min(1, tonumber(book.download_progress) or 0))
    if status == "已生成" or status == "已下载" or status == "未生成" or status == "未开始"
        or status == "已读完" or status:match("^阅读%s+%d+%%$")
        or status:match("下载中") or status:match("生成中") then
        status = ""
    end
    status = U.utf8_truncate(status, 10, "")
    local status_important = status == "失败" or status == "待修复" or status == "排队中"
        or status == "批注待修复"
    if not status_important then status = "" end

    local title_h = math.max(UiScale.dp(29, 25, 40), math.min(UiScale.dp(39, 32, 47), math.floor(height * .155)))
    local status_h = status ~= "" and UiScale.dp(18, 15, 25) or 0
    local download_h = download_active and UiScale.dp(4, 3, 6) or 0
    local vgap = UiScale.dp(2, 2, 4)
    local extra_h = status_h + download_h
    local extra_gaps = (status_h > 0 and 1 or 0) + (download_h > 0 and 1 or 0)
    local cover_h = math.max(UiScale.dp(78, 64, 108), height - title_h - extra_h - vgap * (1 + extra_gaps))
    local cover_w = math.max(UiScale.dp(54, 46, 78), math.min(math.floor(inner_w * .995), math.floor(cover_h * .715)))
    local cover = image_widget(book.home_cover_path or book.cover_path, cover_w, cover_h, .06) or placeholder(cover_w, cover_h, book.title, book.author)

    local cover_layer = OverlapGroup:new{dimen = Geom:new{w = cover_w, h = cover_h}, allow_mirroring = false}
    cover_layer[#cover_layer + 1] = cover
    if downloaded then
        local badge = UiScale.dp(20, 17, 27)
        local inset = UiScale.dp(2, 1, 4)
        cover_layer[#cover_layer + 1] = OffsetContainer:new{
            x_off = inset, y_off = inset,
            outlined_badge_text("✓", badge, badge, face("cfont", 9.4, 13.5)),
        }
    end
    if reading_badge ~= "" then
        local chars = math.max(2, U.utf8_len(reading_badge))
        local badge_w = math.max(UiScale.dp(31, 26, 45), UiScale.dp(9, 8, 14) + chars * UiScale.dp(7, 6, 10))
        local badge_h = UiScale.dp(20, 17, 27)
        local inset = UiScale.dp(2, 1, 4)
        cover_layer[#cover_layer + 1] = OffsetContainer:new{
            x_off = math.max(0, cover_w - badge_w - inset), y_off = inset,
            outlined_badge_text(reading_badge, badge_w, badge_h, face("smallinfofont", 9.2, 13)),
        }
    end

    local body = VerticalGroup:new{align = "center", cover_layer, VerticalSpan:new{height = vgap}}
    body[#body + 1] = TextBoxWidget:new{
        text = tostring(book.title or "未命名"),
        face = face("cfont", 11.5, 16), bold = true, width = inner_w, height = title_h,
        height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center",
    }
    if download_h > 0 then
        body[#body + 1] = VerticalSpan:new{height = vgap}
        body[#body + 1] = CenterContainer:new{
            dimen = Geom:new{w = inner_w, h = download_h},
            progress_bar(math.max(UiScale.dp(44, 38, 68), math.floor(cover_w * .86)), download_h, download_progress),
        }
    elseif status_h > 0 then
        body[#body + 1] = TextBoxWidget:new{
            text = status, face = face("smallinfofont", 8.5, 12), bold = true, width = inner_w, height = status_h,
            height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center", fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    return tappable(width, height, CenterContainer:new{dimen = Geom:new{w = width, h = height}, body},
        function(anchor) if callback then callback(book, anchor) end end,
        function(anchor) if hold_callback then hold_callback(book, anchor) end end)
end

local function home_action_icon(icon, width, height, enabled)
    local size = math.min(width, height, UiScale.dp(25, 22, 34))
    return Ui.icon(icon, width, height, size, {
        icon_key = icon,
        face = UiScale.iconFace("cfont", 20, 27, 17),
        fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
end

local function action_button(entry, width, height)
    local enabled = entry.enabled ~= false
    local icon_h = math.max(UiScale.dp(24, 21, 33), math.floor(height * .42))
    local gap_h = UiScale.dp(2, 1, 4)
    local label_h = math.max(UiScale.dp(17, 15, 23), math.floor(height * .27))
    local body = VerticalGroup:new{
        align = "center",
        home_action_icon(tostring(entry.icon_key or entry.icon or "•"), width, icon_h, enabled),
        VerticalSpan:new{height = gap_h},
        CenterContainer:new{
            dimen = Geom:new{w = width, h = label_h},
            TextWidget:new{
                text = tostring(entry.label or ""),
                face = face("smallinfofont", 9.5, 13),
                bold = true,
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            },
        },
    }
    local child = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    child[#child + 1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, body}
    if entry.badge and tostring(entry.badge) ~= "" then
        local badge_w = math.max(UiScale.dp(22, 18, 32), math.min(UiScale.dp(42, 34, 56), UiScale.dp(12, 10, 18) + U.utf8_len(tostring(entry.badge)) * UiScale.dp(8, 6, 10)))
        local badge_h = math.max(UiScale.dp(18, 15, 24), math.floor(height * .24))
        child[#child + 1] = OffsetContainer:new{
            x_off = math.max(0, width - badge_w - UiScale.dp(4, 3, 7)), y_off = UiScale.dp(2, 1, 4),
            fixed_frame(badge_w, badge_h, {
                bordersize = Skin.line("thin"),
                radius = Skin.radius(4, 3, 7),
                padding = UiScale.dp(1, 1, 3),
                background = Blitbuffer.COLOR_WHITE,
            }, TextWidget:new{text = tostring(entry.badge), face = face("smallinfofont", 9, 11), bold = true}),
        }
    end
    return tappable(width, height, child, enabled and entry.callback or nil, enabled and entry.hold_callback or nil)
end

local function action_bar(actions, width, height)
    actions = actions or {}
    if #actions == 0 then return fixed_frame(width, height, {background = Blitbuffer.COLOR_WHITE}) end
    local gap = UiScale.dp(2, 2, 5)
    local item_w = math.floor((width - gap * (#actions - 1)) / #actions)
    local row = HorizontalGroup:new{align = "center"}
    for index, entry in ipairs(actions) do
        row[#row + 1] = action_button(entry, item_w, height)
        if index < #actions then row[#row + 1] = HorizontalSpan:new{width = gap} end
    end
    local layered = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layered[#layered + 1] = row
    layered[#layered + 1] = OffsetContainer:new{
        x_off = 0, y_off = math.max(0, height - Skin.line("thin")),
        LineWidget:new{background = Blitbuffer.COLOR_GRAY, dimen = Geom:new{w = width, h = Skin.line("thin")}},
    }
    return layered
end

local function category_tabs(tabs, width, height, on_more)
    tabs = tabs or {}
    if #tabs == 0 then return fixed_frame(width, height, {background = Blitbuffer.COLOR_WHITE}) end
    local gap = UiScale.dp(3, 2, 6)
    local more_w = on_more and math.max(UiScale.dp(34, 30, 50), math.floor(width * .055)) or 0
    local tabs_w = math.max(1, width - (more_w > 0 and more_w + gap or 0))
    local item_w = math.floor((tabs_w - gap * (#tabs - 1)) / #tabs)
    local row = HorizontalGroup:new{align = "center"}
    for index, tab in ipairs(tabs) do
        local label = tostring(tab.title or "")
        if tonumber(tab.count) then label = label .. " " .. tostring(tab.count) end
        local item = OverlapGroup:new{dimen = Geom:new{w = item_w, h = height}, allow_mirroring = false}
        item[#item + 1] = Ui.textbox(label, math.max(1, item_w - 8), height,
            face("smallinfofont", 10.8, 15), {
                bold = true, alignment = "center", halign = "center",
                fgcolor = Blitbuffer.COLOR_BLACK,
            })
        if tab.selected then
            local line_w = math.max(28, math.floor(item_w * .54))
            item[#item + 1] = OffsetContainer:new{
                x_off = math.floor((item_w - line_w) / 2),
                y_off = math.max(0, height - Skin.line("thick")),
                LineWidget:new{background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{w = line_w, h = Skin.line("thick")}},
            }
        end
        row[#row + 1] = tappable(item_w, height, item, tab.on_tap)
        if index < #tabs then row[#row + 1] = HorizontalSpan:new{width = gap} end
    end
    if on_more then
        row[#row + 1] = HorizontalSpan:new{width = gap}
        row[#row + 1] = tappable(more_w, height,
            Ui.icon("grid", more_w, height, UiScale.dp(20, 17, 27), {
                face = UiScale.iconFace("cfont", 15, 21, 12),
            }), on_more)
    end
    return row
end

local function empty_section(width, height, text, callback)
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = 0,
        padding = UiScale.dp(7, 6, 12),
        background = Blitbuffer.COLOR_WHITE,
    }, Ui.textbox(tostring(text or "暂时没有内容"), math.max(1, width - 32),
        math.max(1, height - UiScale.dp(14, 12, 24)), face("smallinfofont", 11, 15), {
            bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
        })), callback)
end


-- Bottom three-tab bar (书架/书城/我的). Selected tab: bold + thick underline
-- (grayscale emphasis; no color on e-ink).
local function tab_bar(tabs, width, height)
    tabs = tabs or {}
    if #tabs == 0 then return fixed_frame(width, height, {background = Blitbuffer.COLOR_WHITE}) end
    local item_w = math.max(1, math.floor(width / #tabs))
    local row = HorizontalGroup:new{align = "center"}
    for _, tab in ipairs(tabs) do
        local label = tostring(tab.title or "")
        local item = OverlapGroup:new{dimen = Geom:new{w = item_w, h = height}, allow_mirroring = false}
        item[#item + 1] = Ui.textbox(label, math.max(1, item_w - 8), height,
            face("cfont", 13.4, 18), {
                bold = tab.selected == true, alignment = "center", halign = "center",
                fgcolor = tab.selected == true and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            })
        if tab.selected then
            local line_w = math.max(24, math.floor(item_w * .4))
            item[#item + 1] = OffsetContainer:new{
                x_off = math.floor((item_w - line_w) / 2),
                y_off = math.max(0, height - Skin.line("thick")),
                LineWidget:new{background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{w = line_w, h = Skin.line("thick")}},
            }
        end
        row[#row + 1] = tappable(item_w, height, item, tab.on_tap)
    end
    local layered = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layered[#layered + 1] = fixed_frame(width, height, {bordersize = 0, background = Blitbuffer.COLOR_WHITE}, row)
    layered[#layered + 1] = OffsetContainer:new{
        x_off = 0, y_off = 0,
        LineWidget:new{background = Blitbuffer.COLOR_GRAY, dimen = Geom:new{w = width, h = Skin.line("thin")}},
    }
    return layered
end

-- Generic list/menu row: [icon] title + subtitle + chevron. Shared skeleton
-- with the reader control center rows (miuread.ui_rows) so the external and
-- reading surfaces stay visually identical.
local function entry_row(title, subtitle, width, height, on_tap, icon_text)
    local inner = UiRows.build({
        icon = icon_text or "",
        label = title or "",
        subtitle = subtitle or "",
        arrow = true,
        callback = on_tap,
    }, width, height)
    local card = fixed_frame(width, height, {bordersize = 0, background = Blitbuffer.COLOR_WHITE}, inner)
    if on_tap then return tappable(width, height, card, on_tap) end
    return card
end

-- Reading-duration card (今日 / 本周), WeRead "我的" style. Optional
-- right-aligned hint line (e.g. "阅读周报 ›"). Data source note: local
-- KOReader statistics, not the WeRead cloud counter (see design doc A16).
local function duration_card(today_text, week_text, width, height, on_tap, hint)
    local gap = UiScale.dp(8, 6, 14)
    local half = math.max(1, math.floor((width - gap) / 2))
    local hint_h = hint and hint ~= "" and math.max(UiScale.dp(18, 15, 24), math.floor(height * .24)) or 0
    local cell_h = math.max(1, height - hint_h)
    local cell = function(label, value)
        local box = VerticalGroup:new{align = "center"}
        box[#box + 1] = Ui.textbox(tostring(value or "—"), half, math.floor(cell_h * .55),
            face("cfont", 14.5, 19), {bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK})
        box[#box + 1] = Ui.text(tostring(label or ""), half, math.max(1, math.floor(cell_h * .38)),
            face("smallinfofont", 9.6, 13), {bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY})
        return box
    end
    local row = HorizontalGroup:new{align = "center"}
    row[#row + 1] = cell("今日阅读", today_text)
    row[#row + 1] = HorizontalSpan:new{width = gap}
    row[#row + 1] = cell("本周阅读", week_text)
    local body = VerticalGroup:new{align = "center"}
    body[#body + 1] = row
    if hint_h > 0 then
        body[#body + 1] = Ui.textbox(tostring(hint), width, hint_h,
            face("smallinfofont", 9.2, 13), {bold = true, alignment = "right", halign = "right", fgcolor = Blitbuffer.COLOR_DARK_GRAY})
    end
    local card = fixed_frame(width, height, {bordersize = 0, background = Blitbuffer.COLOR_WHITE}, body)
    if on_tap then return tappable(width, height, card, on_tap) end
    return card
end

local Cards = {
    face = face,
    background = background,
    text_button = text_button,
    image_widget = image_widget,
    placeholder = placeholder,
    solid_bar = solid_bar,
    progress_bar = progress_bar,
    section_header = section_header,
    notice_strip = notice_strip,
    hero_card = hero_card,
    welcome_card = welcome_card,
    shelf_folder_card = shelf_folder_card,
    outlined_badge_text = outlined_badge_text,
    shelf_book_card = shelf_book_card,
    home_action_icon = home_action_icon,
    action_button = action_button,
    action_bar = action_bar,
    category_tabs = category_tabs,
    empty_section = empty_section,
    tab_bar = tab_bar,
    entry_row = entry_row,
    duration_card = duration_card,
}
return Cards
