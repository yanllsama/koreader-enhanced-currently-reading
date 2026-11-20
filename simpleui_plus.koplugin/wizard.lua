-- wizard.lua — SimpleUI Plus Setup Wizard
-- Clean, modern popup dialog for SimpleUI Plus module selection.

local InputContainer  = require("ui/widget/container/inputcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local VerticalSpan    = require("ui/widget/verticalspan")
local LineWidget      = require("ui/widget/linewidget")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local Button          = require("ui/widget/button")
local GestureRange    = require("ui/gesturerange")
local Geom            = require("ui/geometry")
local Font            = require("ui/font")
local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Screen          = Device.screen
local UIManager       = require("ui/uimanager")
local _               = require("infra/plus_i18n").translate

local WizardDialog = InputContainer:extend{
    modal          = true,
    modules        = nil,   -- Array of { id, name, description, how_to_use, default_enabled }
    current_states = nil,   -- Table of { [mod_id] = boolean }
    on_apply       = nil,   -- Function(selected_dict)
    on_cancel      = nil,   -- Function()
    _selected      = nil,   -- Internal selection state: { [mod_id] = boolean }
    _card_frame    = nil,   -- Reference to the dialog card FrameContainer
    _detail_mod    = nil,   -- Module currently viewed in detail mode (in-card)
}

function WizardDialog:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self.modules = self.modules or {}
    self._selected = self._selected or {}

    -- Prioritize currently_yanllsama at index 1, then sort the rest by name/id
    table.sort(self.modules, function(a, b)
        local a_top = (a.id == "currently_yanllsama")
        local b_top = (b.id == "currently_yanllsama")
        if a_top and not b_top then return true end
        if not a_top and b_top then return false end
        return tostring(a.name or a.id) < tostring(b.name or b.id)
    end)

    -- Initialize selected states
    for _idx, mod in ipairs(self.modules) do
        if self._selected[mod.id] == nil then
            if self.current_states and self.current_states[mod.id] ~= nil then
                self._selected[mod.id] = self.current_states[mod.id]
            else
                self._selected[mod.id] = (mod.default_enabled ~= false)
            end
        end
    end

    if Device:isTouchDevice() then
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = sw,
                        h = sh,
                    }
                }
            }
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } }
        }
    end

    self:buildUI()
end

function WizardDialog:onClose()
    UIManager:close(self, "full")
    if self.on_cancel then
        self.on_cancel()
    end
    return true
end

function WizardDialog:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

function WizardDialog:onTapClose(arg, ges)
    if ges and ges.pos and self._card_frame and self._card_frame.dimen then
        if ges.pos:notIntersectWith(self._card_frame.dimen) then
            self:onClose()
            return true
        end
    end
    return true
end

local function fitFontSize(text, font_name, is_bold, max_w, start_fs, min_fs)
    local fs = start_fs
    local lo = min_fs or 8
    if not text or text == "" or not max_w or max_w <= 0 then
        return fs
    end
    while fs > lo do
        local face = Font:getFace(font_name, fs)
        local tw = TextWidget:new{
            text = text,
            face = face,
            bold = is_bold,
            padding = 0,
        }
        local w = tw:getSize().w
        if type(tw.free) == "function" then tw:free() end
        if w <= max_w then
            break
        end
        fs = fs - 1
    end
    return fs
end

function WizardDialog:buildUI()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    local is_landscape = sw > sh
    local base_dim = math.min(sw, sh)
    local scale = math.max(1.0, math.min(1.6, base_dim / 800))

    -- Fixed outer card dimensions that stay identical across all languages & fit any orientation
    local margin_x = Screen:scaleBySize(20)
    local margin_y = Screen:scaleBySize(20)
    local card_w = math.min(sw - margin_x * 2, math.max(math.floor(sw * (is_landscape and 0.68 or 0.86)), Screen:scaleBySize(440)))
    local card_h = math.min(sh - margin_y * 2, math.max(math.floor(sh * (is_landscape and 0.82 or 0.64)), Screen:scaleBySize(360)))
    local border_sz = math.max(2, Screen:scaleBySize(2))
    local pad = Screen:scaleBySize(14)
    local inner_w = math.max(120, card_w - (pad * 2) - (border_sz * 2))
    local inner_h = math.max(120, card_h - (pad * 2) - (border_sz * 2))

    local title_fs = math.max(16, math.floor(20 * scale))
    local sub_fs   = math.max(11, math.floor(13 * scale))
    local item_fs  = math.max(13, math.floor(15 * scale))
    local desc_fs  = math.max(11, math.floor(13 * scale))

    local wizard = self
    local card_content

    if self._detail_mod then
        -- ── IN-CARD DETAIL VIEW ──────────────────────────────────────────────
        local mod = self._detail_mod
        local mod_title = mod.name or mod.id
        local fit_title_fs = fitFontSize(mod_title, "cfont", true, inner_w, title_fs, 11)
        local sub_txt = _("Module Details & Information")
        local fit_sub_fs = fitFontSize(sub_txt, "tfont", false, inner_w, sub_fs, 9)

        local title_tw = TextWidget:new{
            text = mod_title,
            face = Font:getFace("cfont", fit_title_fs),
            bold = true,
            max_width = inner_w,
            truncate_with_ellipsis = true,
        }
        local subtitle_tw = TextWidget:new{
            text = sub_txt,
            face = Font:getFace("tfont", fit_sub_fs),
            fgcolor = Blitbuffer.COLOR_GRAY_3,
            max_width = inner_w,
            truncate_with_ellipsis = true,
        }
        local header = VerticalGroup:new{
            align = "center",
            title_tw,
            VerticalSpan:new{ width = math.max(2, math.floor(3 * scale)) },
            subtitle_tw,
            VerticalSpan:new{ width = math.max(6, math.floor(8 * scale)) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = math.max(1, Screen:scaleBySize(1)) },
                background = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = math.max(6, math.floor(8 * scale)) },
        }

        local back_txt = _("← Back")
        local back_pad_h = Screen:scaleBySize(16)
        local back_w = math.min(inner_w, math.max(Screen:scaleBySize(120), math.floor(inner_w * 0.42)))
        local fit_back_fs = fitFontSize(back_txt, "cfont", true, back_w - back_pad_h * 2, item_fs, 10)
        local btn_back = Button:new{
            text = back_txt,
            width = back_w,
            bordersize = math.max(1, Screen:scaleBySize(1)),
            radius = math.max(2, Screen:scaleBySize(4)),
            padding_h = back_pad_h,
            padding_v = Screen:scaleBySize(6),
            text_font_size = fit_back_fs,
            text_font_bold = true,
            callback = function()
                wizard._detail_mod = nil
                wizard:buildUI()
                UIManager:setDirty(wizard, "ui")
            end,
        }

        local footer = HorizontalGroup:new{
            align = "center",
            btn_back,
        }

        local sep_span_top = math.max(6, math.floor(8 * scale))
        local sep_span_bot = math.max(6, math.floor(8 * scale))
        local footer_h = footer:getSize().h
        local header_h = header:getSize().h
        local sep_h = 1 + sep_span_top + sep_span_bot
        local avail_body_h = math.max(40, inner_h - header_h - footer_h - sep_h)

        local detail_text = ""
        if mod.description and mod.description ~= "" then
            detail_text = detail_text .. mod.description
        end
        if mod.how_to_use and mod.how_to_use ~= "" then
            if detail_text ~= "" then detail_text = detail_text .. "\n\n" end
            detail_text = detail_text .. mod.how_to_use
        end
        if detail_text == "" then
            detail_text = _("No detailed description is available for this module.")
        end

        local cur_desc_fs = desc_fs
        local text_box
        while cur_desc_fs >= 9 do
            text_box = TextBoxWidget:new{
                text = detail_text,
                face = Font:getFace("tfont", cur_desc_fs),
                width = inner_w,
                alignment = "left",
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            if text_box:getSize().h <= avail_body_h or cur_desc_fs == 9 then
                break
            end
            if type(text_box.free) == "function" then text_box:free() end
            cur_desc_fs = cur_desc_fs - 1
        end
        if text_box:getSize().h > avail_body_h then
            if type(text_box.free) == "function" then text_box:free() end
            text_box = TextBoxWidget:new{
                text = detail_text,
                face = Font:getFace("tfont", 9),
                width = inner_w,
                height = avail_body_h,
                alignment = "left",
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        end

        local body_box = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = avail_body_h },
            text_box,
        }

        card_content = VerticalGroup:new{
            align = "center",
            header,
            body_box,
            VerticalSpan:new{ width = sep_span_top },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = 1 },
                background = Blitbuffer.COLOR_GRAY_C,
            },
            VerticalSpan:new{ width = sep_span_bot },
            footer,
        }
    else
        -- ── MAIN MODULE SELECTION VIEW ──────────────────────────────────────
        local main_title = _("SimpleUI Plus")
        local fit_title_fs = fitFontSize(main_title, "cfont", true, inner_w, title_fs, 11)
        local sub_txt = _("Setup Wizard & Module Selection")
        local fit_sub_fs = fitFontSize(sub_txt, "tfont", false, inner_w, sub_fs, 9)

        local title_tw = TextWidget:new{
            text = main_title,
            face = Font:getFace("cfont", fit_title_fs),
            bold = true,
            max_width = inner_w,
            truncate_with_ellipsis = true,
        }
        local subtitle_tw = TextWidget:new{
            text = sub_txt,
            face = Font:getFace("tfont", fit_sub_fs),
            fgcolor = Blitbuffer.COLOR_GRAY_3,
            max_width = inner_w,
            truncate_with_ellipsis = true,
        }
        local header = VerticalGroup:new{
            align = "center",
            title_tw,
            VerticalSpan:new{ width = math.max(2, math.floor(3 * scale)) },
            subtitle_tw,
            VerticalSpan:new{ width = math.max(6, math.floor(8 * scale)) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = math.max(1, Screen:scaleBySize(1)) },
                background = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = math.max(6, math.floor(8 * scale)) },
        }

        local btn_gap = Screen:scaleBySize(6)
        local avail_btn_w = inner_w - (btn_gap * 2)
        local w_cancel = math.floor(avail_btn_w * 0.25)
        local w_toggle = math.floor(avail_btn_w * 0.40)
        local w_finish = math.max(Screen:scaleBySize(60), avail_btn_w - w_cancel - w_toggle)

        local pad_cancel = Screen:scaleBySize(6)
        local pad_toggle = Screen:scaleBySize(6)
        local pad_finish = Screen:scaleBySize(8)

        local cancel_txt = _("Later")
        local toggle_txt = _("Select / Deselect All")
        local finish_txt = _("Finish Setup")

        local fs_cancel = fitFontSize(cancel_txt, "cfont", true, w_cancel - pad_cancel * 2, desc_fs, 8)
        local fs_toggle = fitFontSize(toggle_txt, "cfont", true, w_toggle - pad_toggle * 2, desc_fs, 8)
        local fs_finish = fitFontSize(finish_txt, "cfont", true, w_finish - pad_finish * 2, item_fs, 8)

        local btn_cancel = Button:new{
            text = cancel_txt,
            width = w_cancel,
            bordersize = math.max(1, Screen:scaleBySize(1)),
            margin = 0,
            padding_h = pad_cancel,
            padding_v = Screen:scaleBySize(6),
            radius = math.max(2, Screen:scaleBySize(4)),
            text_font_size = fs_cancel,
            callback = function()
                wizard:onClose()
            end,
        }

        local btn_toggle_all = Button:new{
            text = toggle_txt,
            width = w_toggle,
            bordersize = math.max(1, Screen:scaleBySize(1)),
            margin = 0,
            padding_h = pad_toggle,
            padding_v = Screen:scaleBySize(6),
            radius = math.max(2, Screen:scaleBySize(4)),
            text_font_size = fs_toggle,
            callback = function()
                local any_unchecked = false
                for _idx, m in ipairs(wizard.modules) do
                    if not wizard._selected[m.id] then
                        any_unchecked = true
                        break
                    end
                end
                for _idx, m in ipairs(wizard.modules) do
                    wizard._selected[m.id] = any_unchecked
                end
                wizard:buildUI()
                UIManager:setDirty(wizard, "ui")
            end,
        }

        local btn_finish = Button:new{
            text = finish_txt,
            width = w_finish,
            bordersize = math.max(1, Screen:scaleBySize(2)),
            margin = 0,
            padding_h = pad_finish,
            padding_v = Screen:scaleBySize(6),
            radius = math.max(2, Screen:scaleBySize(4)),
            text_font_bold = true,
            text_font_size = fs_finish,
            callback = function()
                UIManager:close(wizard, "full")
                if wizard.on_apply then
                    wizard.on_apply(wizard._selected)
                end
            end,
        }

        local footer = HorizontalGroup:new{
            align = "center",
            btn_cancel,
            HorizontalSpan:new{ width = btn_gap },
            btn_toggle_all,
            HorizontalSpan:new{ width = btn_gap },
            btn_finish,
        }

        local sep_span_top = math.max(6, math.floor(8 * scale))
        local sep_span_bot = math.max(6, math.floor(8 * scale))
        local sep_h = 1 + sep_span_top + sep_span_bot
        local avail_body_h = math.max(60, inner_h - header:getSize().h - footer:getSize().h - sep_h)

        local intro_txt = _("Select the modules you want to use on your SimpleUI home screen:")
        local info_txt  = _("Details")
        local info_pad_h = Screen:scaleBySize(6)
        local row_gap    = Screen:scaleBySize(8)
        local btn_info_w = math.min(Screen:scaleBySize(110), math.max(Screen:scaleBySize(76), math.floor(inner_w * 0.23)))
        local check_btn_w = math.max(80, inner_w - btn_info_w - row_gap)

        local function buildMainBody(cur_item_fs, cur_desc_fs, cur_row_pad_v)
            local intro_tbw = TextBoxWidget:new{
                text = intro_txt,
                face = Font:getFace("tfont", cur_desc_fs),
                width = inner_w,
                alignment = "left",
                fgcolor = Blitbuffer.COLOR_GRAY_3,
            }
            local list_vg = VerticalGroup:new{ align = "left" }
            if #self.modules == 0 then
                local empty_txt = _("No installed modules found.")
                local fit_emp = fitFontSize(empty_txt, "tfont", false, inner_w, cur_item_fs, 9)
                table.insert(list_vg, TextWidget:new{
                    text = empty_txt,
                    face = Font:getFace("tfont", fit_emp),
                    max_width = inner_w,
                    truncate_with_ellipsis = true,
                })
            else
                local fit_info_fs = fitFontSize(info_txt, "cfont", true, btn_info_w - info_pad_h * 2, cur_desc_fs, 8)
                local sel_pad_h = Screen:scaleBySize(4)
                for idx, mod in ipairs(self.modules) do
                    local mod_id = mod.id
                    local is_checked = (self._selected[mod_id] == true)
                    local check_box_str = is_checked and "[ ✔ ]  " or "[     ]  "
                    local full_lbl = check_box_str .. (mod.name or mod_id)
                    local fit_row_fs = fitFontSize(full_lbl, "cfont", is_checked, check_btn_w - sel_pad_h * 2, cur_item_fs, 8)

                    local btn_select = Button:new{
                        text = full_lbl,
                        width = check_btn_w,
                        align = "left",
                        bordersize = 0,
                        margin = 0,
                        padding_h = sel_pad_h,
                        padding_v = cur_row_pad_v,
                        text_font_bold = is_checked,
                        text_font_size = fit_row_fs,
                        callback = function()
                            wizard._selected[mod_id] = not wizard._selected[mod_id]
                            wizard:buildUI()
                            UIManager:setDirty(wizard, "ui")
                        end,
                    }

                    local btn_info = Button:new{
                        text = info_txt,
                        width = btn_info_w,
                        align = "center",
                        bordersize = math.max(1, Screen:scaleBySize(1)),
                        radius = math.max(2, Screen:scaleBySize(4)),
                        margin = 0,
                        padding_h = info_pad_h,
                        padding_v = math.max(2, cur_row_pad_v - Screen:scaleBySize(2)),
                        text_font_size = fit_info_fs,
                        callback = function()
                            wizard._detail_mod = mod
                            wizard:buildUI()
                            UIManager:setDirty(wizard, "ui")
                        end,
                    }

                    table.insert(list_vg, HorizontalGroup:new{
                        align = "center",
                        btn_select,
                        HorizontalSpan:new{ width = row_gap },
                        btn_info,
                    })

                    if idx < #self.modules then
                        table.insert(list_vg, VerticalSpan:new{ width = math.max(2, math.floor(3 * scale)) })
                        table.insert(list_vg, LineWidget:new{
                            dimen = Geom:new{ w = inner_w, h = 1 },
                            background = Blitbuffer.COLOR_GRAY_E,
                        })
                        table.insert(list_vg, VerticalSpan:new{ width = math.max(2, math.floor(3 * scale)) })
                    end
                end
            end

            return VerticalGroup:new{
                align = "left",
                intro_tbw,
                VerticalSpan:new{ width = math.max(4, math.floor(8 * scale)) },
                list_vg,
            }
        end

        local body_vg
        local step_i, step_d, step_pv = item_fs, desc_fs, Screen:scaleBySize(6)
        for attempt = 1, 6 do
            body_vg = buildMainBody(step_i, step_d, step_pv)
            if body_vg:getSize().h <= avail_body_h or attempt == 6 then
                break
            end
            if type(body_vg.free) == "function" then body_vg:free() end
            step_i  = math.max(9, step_i - 1)
            step_d  = math.max(8, step_d - 1)
            step_pv = math.max(2, step_pv - Screen:scaleBySize(1))
        end

        local body_box = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = avail_body_h },
            body_vg,
        }

        card_content = VerticalGroup:new{
            align = "center",
            header,
            body_box,
            VerticalSpan:new{ width = sep_span_top },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = 1 },
                background = Blitbuffer.COLOR_GRAY_C,
            },
            VerticalSpan:new{ width = sep_span_bot },
            footer,
        }
    end

    local card_frame = FrameContainer:new{
        bordersize = border_sz,
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        radius = math.max(6, Screen:scaleBySize(8)),
        padding = pad,
        [1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            card_content,
        },
    }

    self._card_frame = card_frame

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        card_frame,
    }
end

function WizardDialog:onShow()
    UIManager:setDirty(self, function()
        return "full", self.dimen
    end)
end

return WizardDialog
