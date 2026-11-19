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
local _               = require("gettext")

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

function WizardDialog:buildUI()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    local scale = math.max(1.0, math.min(1.8, sw / 800))
    local card_w = math.min(sw - Screen:scaleBySize(60), Screen:scaleBySize(500))
    local pad = Screen:scaleBySize(16)
    local inner_w = card_w - (pad * 2)

    local title_fs = math.max(18, math.floor(21 * scale))
    local sub_fs   = math.max(12, math.floor(13 * scale))
    local item_fs  = math.max(14, math.floor(16 * scale))
    local desc_fs  = math.max(11, math.floor(13 * scale))

    local wizard = self
    local card_content

    if self._detail_mod then
        -- ── IN-CARD DETAIL VIEW ──────────────────────────────────────────────
        local mod = self._detail_mod
        local title_tw = TextWidget:new{
            text = mod.name or mod.id,
            face = Font:getFace("cfont", title_fs),
            bold = true,
        }
        local subtitle_tw = TextWidget:new{
            text = _("Modül Detayı ve Bilgisi"),
            face = Font:getFace("tfont", sub_fs),
            fgcolor = Blitbuffer.COLOR_GRAY_3,
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

        local detail_text = ""
        if mod.description and mod.description ~= "" then
            detail_text = detail_text .. mod.description
        end
        if mod.how_to_use and mod.how_to_use ~= "" then
            if detail_text ~= "" then detail_text = detail_text .. "\n\n" end
            detail_text = detail_text .. mod.how_to_use
        end
        if detail_text == "" then
            detail_text = _("Bu modül için detaylı açıklama bulunmuyor.")
        end

        local text_box = TextBoxWidget:new{
            text = detail_text,
            face = Font:getFace("tfont", desc_fs),
            width = inner_w,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local btn_back = Button:new{
            text = _("← Geri"),
            bordersize = math.max(1, Screen:scaleBySize(1)),
            radius = math.max(2, Screen:scaleBySize(4)),
            padding_h = Screen:scaleBySize(16),
            padding_v = Screen:scaleBySize(6),
            text_font_size = item_fs,
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

        card_content = VerticalGroup:new{
            align = "center",
            header,
            text_box,
            VerticalSpan:new{ width = math.max(8, math.floor(12 * scale)) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = 1 },
                background = Blitbuffer.COLOR_GRAY_C,
            },
            VerticalSpan:new{ width = math.max(6, math.floor(8 * scale)) },
            footer,
        }
    else
        -- ── MAIN MODULE SELECTION VIEW ──────────────────────────────────────
        local title_tw = TextWidget:new{
            text = _("SimpleUI Plus"),
            face = Font:getFace("cfont", title_fs),
            bold = true,
        }
        local subtitle_tw = TextWidget:new{
            text = _("Kurulum Sihirbazı & Modül Seçimi"),
            face = Font:getFace("tfont", sub_fs),
            fgcolor = Blitbuffer.COLOR_GRAY_3,
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

        local intro_tbw = TextBoxWidget:new{
            text = _("SimpleUI ana ekranında kullanmak istediğiniz modülleri seçin:"),
            face = Font:getFace("tfont", desc_fs),
            width = inner_w,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_GRAY_3,
        }

        local module_list_group = VerticalGroup:new{ align = "left" }

        if #self.modules == 0 then
            table.insert(module_list_group, TextWidget:new{
                text = _("Henüz yüklü modül bulunamadı."),
                face = Font:getFace("tfont", item_fs),
            })
        else
            local btn_info_w = Screen:scaleBySize(72)
            local check_btn_w = inner_w - btn_info_w - Screen:scaleBySize(10)

            for idx, mod in ipairs(self.modules) do
                local mod_id = mod.id
                local is_checked = (self._selected[mod_id] == true)
                local check_box_str = is_checked and "[ ✔ ]  " or "[     ]  "

                local btn_select = Button:new{
                    text = check_box_str .. (mod.name or mod_id),
                    width = check_btn_w,
                    align = "left",
                    bordersize = 0,
                    margin = 0,
                    padding_h = Screen:scaleBySize(4),
                    padding_v = Screen:scaleBySize(6),
                    text_font_bold = is_checked,
                    text_font_size = item_fs,
                    callback = function()
                        wizard._selected[mod_id] = not wizard._selected[mod_id]
                        wizard:buildUI()
                        UIManager:setDirty(wizard, "ui")
                    end,
                }

                local btn_info = Button:new{
                    text = _("Detay"),
                    width = btn_info_w,
                    align = "center",
                    bordersize = math.max(1, Screen:scaleBySize(1)),
                    radius = math.max(2, Screen:scaleBySize(4)),
                    margin = 0,
                    padding_h = Screen:scaleBySize(6),
                    padding_v = Screen:scaleBySize(4),
                    text_font_size = desc_fs,
                    callback = function()
                        wizard._detail_mod = mod
                        wizard:buildUI()
                        UIManager:setDirty(wizard, "ui")
                    end,
                }

                local row = HorizontalGroup:new{
                    align = "center",
                    btn_select,
                    HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                    btn_info,
                }

                table.insert(module_list_group, row)

                if idx < #self.modules then
                    table.insert(module_list_group, VerticalSpan:new{ width = math.max(2, math.floor(4 * scale)) })
                    table.insert(module_list_group, LineWidget:new{
                        dimen = Geom:new{ w = inner_w, h = 1 },
                        background = Blitbuffer.COLOR_GRAY_E,
                    })
                    table.insert(module_list_group, VerticalSpan:new{ width = math.max(2, math.floor(4 * scale)) })
                end
            end
        end

        local btn_cancel = Button:new{
            text = _("Daha Sonra"),
            bordersize = math.max(1, Screen:scaleBySize(1)),
            margin = math.max(2, Screen:scaleBySize(3)),
            padding_h = Screen:scaleBySize(10),
            padding_v = Screen:scaleBySize(6),
            radius = math.max(2, Screen:scaleBySize(4)),
            text_font_size = desc_fs,
            callback = function()
                wizard:onClose()
            end,
        }

        local btn_toggle_all = Button:new{
            text = _("Tümünü Seç / Kaldır"),
            bordersize = math.max(1, Screen:scaleBySize(1)),
            margin = math.max(2, Screen:scaleBySize(3)),
            padding_h = Screen:scaleBySize(8),
            padding_v = Screen:scaleBySize(6),
            radius = math.max(2, Screen:scaleBySize(4)),
            text_font_size = desc_fs,
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
            text = _("Kurulumu Tamamla"),
            bordersize = math.max(1, Screen:scaleBySize(2)),
            margin = math.max(2, Screen:scaleBySize(3)),
            padding_h = Screen:scaleBySize(12),
            padding_v = Screen:scaleBySize(6),
            radius = math.max(2, Screen:scaleBySize(4)),
            text_font_bold = true,
            text_font_size = item_fs,
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
            HorizontalSpan:new{ width = math.max(4, math.floor(6 * scale)) },
            btn_toggle_all,
            HorizontalSpan:new{ width = math.max(4, math.floor(6 * scale)) },
            btn_finish,
        }

        card_content = VerticalGroup:new{
            align = "center",
            header,
            intro_tbw,
            VerticalSpan:new{ width = math.max(6, math.floor(10 * scale)) },
            module_list_group,
            VerticalSpan:new{ width = math.max(8, math.floor(12 * scale)) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = 1 },
                background = Blitbuffer.COLOR_GRAY_C,
            },
            VerticalSpan:new{ width = math.max(6, math.floor(8 * scale)) },
            footer,
        }
    end

    local card_frame = FrameContainer:new{
        bordersize = math.max(2, Screen:scaleBySize(2)),
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        radius = math.max(6, Screen:scaleBySize(8)),
        padding = pad,
        [1] = card_content,
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
