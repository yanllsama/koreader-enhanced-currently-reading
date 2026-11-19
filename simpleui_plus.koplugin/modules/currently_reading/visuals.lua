-- modules/currently_reading/visuals.lua — Progress visuals (15 Futuristic Ring, 15 Vertical Bar, 15 Horizontal Bar variants).

local Blitbuffer      = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")

local C               = require("modules/currently_reading/config")
local CFG             = C.CFG
local _               = C._
local getSUIModule    = C.getSUIModule
local getSUIStyle     = C.getSUIStyle
local resolveFontFace = C.resolveFontFace

local M = {}

local _ring_mask_cache = {}
local _ring_mask_cache_keys = {}
local _RING_MASK_CACHE_MAX = 128
local _fit_vis_face_cache = {}
local _fit_vis_face_count = 0
local _GRAY8_LUT = nil

local function getGray8(val)
    if not _GRAY8_LUT then
        _GRAY8_LUT = {}
        for i = 0, 255 do
            _GRAY8_LUT[i] = Blitbuffer.Color8(i)
        end
    end
    return _GRAY8_LUT[val] or Blitbuffer.Color8(val)
end

function M.clearRingMaskCache()
    for _, bb in pairs(_ring_mask_cache) do
        if type(bb) == "table" and type(bb.free) == "function" then
            pcall(function() bb:free() end)
        end
    end
    _ring_mask_cache = {}
    _ring_mask_cache_keys = {}
    _fit_vis_face_cache = {}
    _fit_vis_face_count = 0
end

local TWO_PI = math.pi * 2

local function aaBlend(bb, px, py, cov, d)
    if cov <= 0 then return end
    if px < 0 or px >= d or py < 0 or py >= d then return end
    if cov >= 0.996 then
        bb:setPixel(px, py, getGray8(0))
        return
    end
    local g = bb:getPixel(px, py):getColor8().a
    local v = math.floor(g * (1 - cov) + 0.5)
    bb:setPixel(px, py, getGray8(v < 0 and 0 or (v > 255 and 255 or v)))
end

local function aaBlendRaw(data, stride, px, py, cov, d)
    if cov <= 0 then return end
    if px < 0 or px >= d or py < 0 or py >= d then return end
    local idx = py * stride + px
    if cov >= 0.996 then
        data[idx].a = 0
        return
    end
    local g = data[idx].a
    local v = math.floor(g * (1 - cov) + 0.5)
    data[idx].a = v < 0 and 0 or (v > 255 and 255 or v)
end

local function aaDisc(bb, cx, cy, r, d, weight)
    if r <= 0 then return end
    local w = weight or 1.0
    local r_max2 = (r + 1.0) * (r + 1.0)
    local minx = math.max(0, math.floor(cx - r - 1))
    local maxx = math.min(d - 1, math.ceil(cx + r + 1))
    local miny = math.max(0, math.floor(cy - r - 1))
    local maxy = math.min(d - 1, math.ceil(cy + r + 1))
    local data = bb.data
    local stride = tonumber(bb.stride)
    if data and stride then
        local r_in = r - 0.5
        local r_in2 = (r_in > 0) and (r_in * r_in) or -1
        for py = miny, maxy do
            local dy = py + 0.5 - cy
            local dy2 = dy * dy
            local row_off = py * stride
            for px = minx, maxx do
                local dx = px + 0.5 - cx
                local r2 = dx * dx + dy2
                if r2 <= r_max2 then
                    local cov
                    if r2 <= r_in2 then
                        cov = w
                    else
                        cov = (r + 0.5 - math.sqrt(r2)) * w
                    end
                    if cov > 0 then
                        local idx = row_off + px
                        if cov >= 0.996 then
                            data[idx].a = 0
                        else
                            local v = math.floor(data[idx].a * (1 - cov) + 0.5)
                            data[idx].a = v < 0 and 0 or (v > 255 and 255 or v)
                        end
                    end
                end
            end
        end
        return
    end
    for py = miny, maxy do
        local dy = py + 0.5 - cy
        local dy2 = dy * dy
        for px = minx, maxx do
            local dx = px + 0.5 - cx
            local r2 = dx * dx + dy2
            if r2 <= r_max2 then
                local dist = math.sqrt(r2)
                aaBlend(bb, px, py, (r + 0.5 - dist) * w, d)
            end
        end
    end
end

local function aaSegment(bb, ax, ay, bx, by, half_w, d, weight)
    local w = weight or 1.0
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local inv_len2 = (len2 > 0) and (1.0 / len2) or 0
    local max_dist2 = (half_w + 1.0) * (half_w + 1.0)
    local minx = math.max(0, math.floor(math.min(ax, bx) - half_w - 2))
    local maxx = math.min(d - 1, math.ceil(math.max(ax, bx) + half_w + 2))
    local miny = math.max(0, math.floor(math.min(ay, by) - half_w - 2))
    local maxy = math.min(d - 1, math.ceil(math.max(ay, by) + half_w + 2))
    local data = bb.data
    local stride = tonumber(bb.stride)
    for py = miny, maxy do
        local pyc = py + 0.5
        local pay = pyc - ay
        for px = minx, maxx do
            local pxc = px + 0.5
            local t = (inv_len2 > 0) and (((pxc - ax) * dx + pay * dy) * inv_len2) or 0
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local ddx = pxc - (ax + t * dx)
            local ddy = pyc - (ay + t * dy)
            local dist2 = ddx * ddx + ddy * ddy
            if dist2 <= max_dist2 then
                local cov = (half_w + 0.5 - math.sqrt(dist2)) * w
                if cov > 0 then
                    if data and stride then
                        aaBlendRaw(data, stride, px, py, cov, d)
                    else
                        aaBlend(bb, px, py, cov, d)
                    end
                end
            end
        end
    end
end

local function aaArc(bb, cx, cy, r_mid, sw_half, start_a, span, round_caps, d, weight)
    if span <= 0 or r_mid <= 0 or sw_half <= 0 then return end
    local w = weight or 1.0
    local is_full = (span >= TWO_PI - 1e-4)
    local reach = r_mid + sw_half + 2
    local band = sw_half + 1.5
    local r_min = math.max(0, r_mid - band)
    local r_max = r_mid + band
    local inner_r2 = r_min * r_min
    local outer_r2 = r_max * r_max
    local data = bb.data
    local stride = tonumber(bb.stride)

    -- Fast path: full centered ring uses exact 4-quadrant symmetry + direct BB8 writes
    if is_full and data and stride and math.abs(cx - d * 0.5) < 1e-4 and math.abs(cy - d * 0.5) < 1e-4 then
        local solid_in = r_mid - (sw_half - 0.5)
        local solid_out = r_mid + (sw_half - 0.5)
        local solid_in2 = (solid_in > 0 and sw_half >= 0.5) and (solid_in * solid_in) or -1
        local solid_out2 = (sw_half >= 0.5) and (solid_out * solid_out) or -1
        local half_y = math.floor((d - 1) / 2)
        local half_x = math.floor((d - 1) / 2)
        local miny = math.max(0, math.floor(cy - reach))
        local minx = math.max(0, math.floor(cx - reach))
        for py = miny, half_y do
            local dy = py + 0.5 - cy
            local dy2 = dy * dy
            local my = d - 1 - py
            local r1 = py * stride
            local r2_off = my * stride
            local diff_y = (my ~= py)
            for px = minx, half_x do
                local dx = px + 0.5 - cx
                local r2 = dx * dx + dy2
                if r2 >= inner_r2 and r2 <= outer_r2 then
                    local cov
                    if r2 >= solid_in2 and r2 <= solid_out2 then
                        cov = w
                    else
                        local radial_cov = sw_half + 0.5 - math.abs(math.sqrt(r2) - r_mid)
                        if radial_cov <= 0 then
                            cov = 0
                        elseif radial_cov >= 1.0 then
                            cov = w
                        else
                            cov = radial_cov * w
                        end
                    end
                    if cov > 0 then
                        local mx = d - 1 - px
                        local diff_x = (mx ~= px)
                        if cov >= 0.996 then
                            data[r1 + px].a = 0
                            if diff_x then data[r1 + mx].a = 0 end
                            if diff_y then
                                data[r2_off + px].a = 0
                                if diff_x then data[r2_off + mx].a = 0 end
                            end
                        else
                            local keep = 1.0 - cov
                            local i1 = r1 + px
                            local v1 = math.floor(data[i1].a * keep + 0.5)
                            data[i1].a = v1 < 0 and 0 or (v1 > 255 and 255 or v1)
                            if diff_x then
                                local i2 = r1 + mx
                                local v2 = math.floor(data[i2].a * keep + 0.5)
                                data[i2].a = v2 < 0 and 0 or (v2 > 255 and 255 or v2)
                            end
                            if diff_y then
                                local i3 = r2_off + px
                                local v3 = math.floor(data[i3].a * keep + 0.5)
                                data[i3].a = v3 < 0 and 0 or (v3 > 255 and 255 or v3)
                                if diff_x then
                                    local i4 = r2_off + mx
                                    local v4 = math.floor(data[i4].a * keep + 0.5)
                                    data[i4].a = v4 < 0 and 0 or (v4 > 255 and 255 or v4)
                                end
                            end
                        end
                    end
                end
            end
        end
        return
    end

    local end_a = start_a + span
    local s_dx, s_dy = math.cos(start_a), math.sin(start_a)
    local e_dx, e_dy = math.cos(end_a), math.sin(end_a)
    local sx, sy = cx + r_mid * s_dx, cy + r_mid * s_dy
    local ex, ey = cx + r_mid * e_dx, cy + r_mid * e_dy
    -- Normals pointing INTO the arc at each radial cut
    local snx, sny = -s_dy, s_dx
    local enx, eny = e_dy, -e_dx
    local small_span = (span <= math.pi)
    local cap_r2 = (sw_half + 1.0) * (sw_half + 1.0)

    local minx = math.max(0, math.floor(cx - reach))
    local maxx = math.min(d - 1, math.ceil(cx + reach))
    local miny = math.max(0, math.floor(cy - reach))
    local maxy = math.min(d - 1, math.ceil(cy + reach))

    for py = miny, maxy do
        local pyc = py + 0.5
        local dy = pyc - cy
        local dy2 = dy * dy
        local row_off = stride and (py * stride) or 0
        for px = minx, maxx do
            local pxc = px + 0.5
            local dx = pxc - cx
            local r2 = dx * dx + dy2
            if r2 >= inner_r2 and r2 <= outer_r2 then
                local cov = 0
                if is_full then
                    cov = sw_half + 0.5 - math.abs(math.sqrt(r2) - r_mid)
                else
                    local ds = dx * snx + dy * sny
                    local de = dx * enx + dy * eny
                    local in_arc = small_span and (ds >= 0 and de >= 0) or ((not small_span) and (ds >= 0 or de >= 0))
                    if in_arc then
                        local radial_cov = sw_half + 0.5 - math.abs(math.sqrt(r2) - r_mid)
                        if radial_cov > 0 then
                            if round_caps then
                                cov = radial_cov
                            else
                                local end_cov = 1.0
                                if small_span then
                                    local md = (ds < de) and ds or de
                                    if md < 0.5 then end_cov = md + 0.5 end
                                elseif ds >= 0 and de < 0 then
                                    if ds < 0.5 then end_cov = ds + 0.5 end
                                elseif de >= 0 and ds < 0 then
                                    if de < 0.5 then end_cov = de + 0.5 end
                                end
                                cov = (end_cov < radial_cov) and end_cov or radial_cov
                            end
                        end
                    elseif round_caps then
                        local sdx, sdy = pxc - sx, pyc - sy
                        local sd2 = sdx * sdx + sdy * sdy
                        local edx, edy = pxc - ex, pyc - ey
                        local ed2 = edx * edx + edy * edy
                        local min_d2 = (sd2 < ed2) and sd2 or ed2
                        if min_d2 < cap_r2 then
                            cov = sw_half + 0.5 - math.sqrt(min_d2)
                        end
                    elseif ds > -0.6 or de > -0.6 then
                        local radial_cov = sw_half + 0.5 - math.abs(math.sqrt(r2) - r_mid)
                        if radial_cov > 0 then
                            local c1 = (ds > -0.6 and (dx * s_dx + dy * s_dy) > 0) and (ds + 0.5) or 0
                            local c2 = (de > -0.6 and (dx * e_dx + dy * e_dy) > 0) and (de + 0.5) or 0
                            local end_cov = (c1 > c2) and c1 or c2
                            if end_cov > 0 then
                                cov = (end_cov < radial_cov) and end_cov or radial_cov
                            end
                        end
                    end
                end
                if cov > 0 then
                    local c_w = cov * w
                    if data and stride then
                        local idx = row_off + px
                        if c_w >= 0.996 then
                            data[idx].a = 0
                        else
                            local v = math.floor(data[idx].a * (1 - c_w) + 0.5)
                            data[idx].a = v < 0 and 0 or (v > 255 and 255 or v)
                        end
                    else
                        aaBlend(bb, px, py, c_w, d)
                    end
                end
            end
        end
    end
end

local function paintRingSegmentVariant(mask, cx, cy, outer_r, thick, fraction, is_track, variant, d)
    if (not is_track) and fraction <= 0 then return end
    local frac = is_track and 1.0 or math.max(0.0, math.min(1.0, fraction or 0))
    local r_mid = math.max(1.5, outer_r - thick * 0.5)
    local sw_half = math.max(0.6, thick * 0.5)
    local start_a = -math.pi * 0.5

    if variant == "flat_arc" then
        aaArc(mask, cx, cy, r_mid, sw_half, start_a, frac * TWO_PI, false, d)
    elseif variant == "hairline_track" then
        if is_track then
            aaArc(mask, cx, cy, r_mid, math.max(0.65, math.min(sw_half * 0.32, 1.35)), 0, TWO_PI, false, d)
        else
            aaArc(mask, cx, cy, r_mid, sw_half, start_a, frac * TWO_PI, true, d)
        end
    elseif variant == "double_ring" then
        if is_track then
            local rw = math.max(0.65, math.min(1.3, thick * 0.17))
            aaArc(mask, cx, cy, math.max(1.5, outer_r - rw), rw, 0, TWO_PI, false, d)
            aaArc(mask, cx, cy, math.max(1.5, outer_r - thick + rw), rw, 0, TWO_PI, false, d)
        else
            aaArc(mask, cx, cy, r_mid, math.max(0.75, sw_half * 0.58), start_a, frac * TWO_PI, true, d)
        end
    elseif variant == "gauge" then
        local g_start, g_span = math.pi * 0.75, math.pi * 1.5
        if is_track then
            aaArc(mask, cx, cy, r_mid, sw_half, g_start, g_span, true, d)
        else
            aaArc(mask, cx, cy, r_mid, sw_half, g_start, math.max(0.02, frac * g_span), true, d)
        end
    elseif variant == "hud_220" then
        local h_span = math.rad(220)
        local h_start = -math.pi * 0.5 - h_span * 0.5
        if is_track then
            aaArc(mask, cx, cy, r_mid, math.max(0.7, sw_half * 0.55), h_start, h_span, false, d)
            aaDisc(mask, cx, cy, math.max(1.2, sw_half * 0.40), d, 0.75)
        else
            aaArc(mask, cx, cy, r_mid, sw_half, h_start, math.max(0.02, frac * h_span), false, d)
        end
    elseif variant == "orbit_node" then
        if is_track then
            aaArc(mask, cx, cy, r_mid, math.max(0.65, sw_half * 0.30), 0, TWO_PI, false, d)
        else
            local span = frac * TWO_PI
            aaArc(mask, cx, cy, r_mid, math.max(0.85, sw_half * 0.65), start_a, span, true, d)
            local tip_a = start_a + span
            aaDisc(mask, cx + r_mid * math.cos(tip_a), cy + r_mid * math.sin(tip_a), math.max(1.6, sw_half * 1.15), d)
        end
    elseif variant == "reticle" then
        if is_track then
            local tr = math.max(1.5, r_mid - 1.0)
            aaArc(mask, cx, cy, tr, math.max(0.65, sw_half * 0.34), 0, TWO_PI, false, d)
            local tick_sw = math.max(0.6, sw_half * 0.25)
            local r_in = math.max(1, tr - sw_half * 0.9)
            local r_out = math.min(d * 0.5 - 0.8, outer_r + 0.5)
            for k = 0, 3 do
                local a = k * (math.pi * 0.5)
                local ca, sa = math.cos(a), math.sin(a)
                aaSegment(mask, cx + r_in * ca, cy + r_in * sa, cx + r_out * ca, cy + r_out * sa, tick_sw, d)
            end
            aaDisc(mask, cx, cy, math.max(1.1, sw_half * 0.35), d)
        else
            aaArc(mask, cx, cy, math.max(1.5, r_mid - 1.0), math.max(0.9, sw_half * 0.85), start_a, frac * TWO_PI, true, d)
        end
    elseif variant == "halo_glow" then
        if is_track then
            aaArc(mask, cx, cy, r_mid, sw_half * 1.10, 0, TWO_PI, false, d, 0.45)
            aaArc(mask, cx, cy, r_mid, math.max(0.65, sw_half * 0.35), 0, TWO_PI, false, d, 1.0)
        else
            local span = frac * TWO_PI
            aaArc(mask, cx, cy, r_mid, math.max(0.85, sw_half * 0.72), start_a, span, true, d)
            local tip_a = start_a + span
            aaDisc(mask, cx + r_mid * math.cos(tip_a), cy + r_mid * math.sin(tip_a), math.max(1.4, sw_half * 0.95), d)
        end
    elseif variant == "telemetry_dial" then
        local t_span = math.rad(260)
        local t_start = -math.pi * 0.5 - t_span * 0.5
        local r_inner = math.max(1.5, outer_r - thick * 1.25)
        if is_track then
            aaArc(mask, cx, cy, r_mid, math.max(0.8, sw_half * 0.75), t_start, t_span, false, d)
            aaArc(mask, cx, cy, r_inner, 0.75, t_start, t_span, false, d, 0.75)
        else
            local span = math.max(0.02, frac * t_span)
            aaArc(mask, cx, cy, r_mid, math.max(0.9, sw_half * 0.85), t_start, span, false, d)
            local tip_a = t_start + span
            local ca, sa = math.cos(tip_a), math.sin(tip_a)
            aaSegment(mask, cx + (r_inner * 0.55) * ca, cy + (r_inner * 0.55) * sa, cx + (outer_r * 0.98) * ca, cy + (outer_r * 0.98) * sa, math.max(0.75, sw_half * 0.35), d)
            aaDisc(mask, cx, cy, math.max(1.3, sw_half * 0.45), d)
        end
    elseif variant == "reactor_core" then
        if is_track then
            local outer_sw = math.max(0.8, sw_half * 0.42)
            aaArc(mask, cx, cy, math.max(1.5, outer_r - outer_sw), outer_sw, 0, TWO_PI, false, d)
            aaArc(mask, cx, cy, math.max(1.5, outer_r - thick * 1.35), 0.75, 0, TWO_PI, false, d, 0.7)
        else
            aaArc(mask, cx, cy, math.max(1.5, r_mid - thick * 0.14), math.max(0.9, sw_half * 0.72), start_a, frac * TWO_PI, false, d)
        end
    elseif variant == "cyber_crescent" then
        if is_track then
            aaArc(mask, cx, cy, r_mid, math.max(0.65, sw_half * 0.28), 0, TWO_PI, false, d)
        else
            local span = frac * TWO_PI
            aaArc(mask, cx, cy, math.max(1.5, outer_r - sw_half * 0.82), sw_half * 0.82, start_a, span, false, d)
            local tip_a = start_a + span
            local ca, sa = math.cos(tip_a), math.sin(tip_a)
            aaSegment(mask, cx + math.max(1, outer_r - thick * 1.2) * ca, cy + math.max(1, outer_r - thick * 1.2) * sa, cx + outer_r * ca, cy + outer_r * sa, math.max(0.8, sw_half * 0.32), d)
        end
    elseif variant == "chronometer" then
        local bezel_r = math.max(1.5, outer_r - 0.9)
        if is_track then
            aaArc(mask, cx, cy, bezel_r, 0.85, 0, TWO_PI, false, d)
            for k = 0, 3 do
                local a = start_a + k * (math.pi * 0.5)
                local ca, sa = math.cos(a), math.sin(a)
                aaSegment(mask, cx + (bezel_r - 3.2) * ca, cy + (bezel_r - 3.2) * sa, cx + bezel_r * ca, cy + bezel_r * sa, 0.8, d)
            end
        else
            local span = frac * TWO_PI
            local arc_r = math.max(1.5, bezel_r - math.max(1.6, thick * 0.52))
            aaArc(mask, cx, cy, arc_r, math.max(0.75, sw_half * 0.58), start_a, span, false, d)
            local tip_a = start_a + span
            aaSegment(mask, cx, cy, cx + (arc_r + sw_half * 0.4) * math.cos(tip_a), cy + (arc_r + sw_half * 0.4) * math.sin(tip_a), math.max(0.65, sw_half * 0.25), d)
            aaDisc(mask, cx, cy, math.max(1.2, sw_half * 0.40), d)
        end
    elseif variant == "sonar_pulse" then
        if is_track then
            aaArc(mask, cx, cy, math.max(1.5, outer_r - 0.8), 0.70, 0, TWO_PI, false, d, 0.55)
            aaArc(mask, cx, cy, math.max(1.5, r_mid - 1.2), math.max(0.65, sw_half * 0.32), 0, TWO_PI, false, d, 1.0)
        else
            local span = frac * TWO_PI
            local sr = math.max(1.5, r_mid - 1.2)
            aaArc(mask, cx, cy, sr, math.max(0.85, sw_half * 0.65), start_a, span, true, d)
            local tip_a = start_a + span
            aaDisc(mask, cx + sr * math.cos(tip_a), cy + sr * math.sin(tip_a), math.max(1.8, sw_half * 1.22), d)
        end
    elseif variant == "eclipse_rim" then
        if is_track then
            local inner_trk_r = math.max(1.5, outer_r - thick * 0.90)
            aaArc(mask, cx, cy, inner_trk_r, math.max(0.65, sw_half * 0.32), 0, TWO_PI, false, d)
        else
            local span = frac * TWO_PI
            local rim_sw = math.max(0.9, sw_half * 0.82)
            local rim_r = math.max(1.5, outer_r - rim_sw)
            aaArc(mask, cx, cy, rim_r, rim_sw, start_a, span, true, d)
            local tip_a = start_a + span
            aaDisc(mask, cx + rim_r * math.cos(tip_a), cy + rim_r * math.sin(tip_a), rim_sw * 1.08, d)
        end
    else
        -- Default "classic"
        if is_track then
            aaArc(mask, cx, cy, r_mid, sw_half, 0, TWO_PI, false, d)
        else
            aaArc(mask, cx, cy, r_mid, sw_half, start_a, frac * TWO_PI, true, d)
        end
    end
end

local function getInvertedRingMask(d, thick, pct_val, is_track, variant)
    local step_pct = is_track and 100 or math.floor(pct_val * 180 + 0.5)
    local key = string.format("%d_%d_%d_%s_%s", d, thick, step_pct, is_track and "t" or "f", tostring(variant or "classic"))
    if _ring_mask_cache[key] then
        return _ring_mask_cache[key]
    end
    local cx, cy  = d * 0.5, d * 0.5
    local outer_r = math.max(3, d * 0.5 - 1.5)
    local mask = Blitbuffer.new(d, d, Blitbuffer.TYPE_BB8)
    mask:fill(Blitbuffer.COLOR_WHITE)
    paintRingSegmentVariant(mask, cx, cy, outer_r, thick, is_track and 1.0 or pct_val, is_track, variant, d)
    mask:invertRect(0, 0, d, d)

    if #_ring_mask_cache_keys >= _RING_MASK_CACHE_MAX then
        local old_k = table.remove(_ring_mask_cache_keys, 1)
        if old_k and _ring_mask_cache[old_k] then
            local old_bb = _ring_mask_cache[old_k]
            if type(old_bb) == "table" and type(old_bb.free) == "function" then
                pcall(function() old_bb:free() end)
            end
            _ring_mask_cache[old_k] = nil
        end
    end
    _ring_mask_cache[key] = mask
    table.insert(_ring_mask_cache_keys, key)
    return mask
end

local function blitRingMask(bb, x, y, mask, d, color)
    if not mask then return end
    if type(bb.colorblitFromRGB32) == "function" then
        bb:colorblitFromRGB32(mask, x, y, 0, 0, d, d, color)
        return
    end
    for py = 0, d - 1 do
        for px = 0, d - 1 do
            local a = mask:getPixel(px, py):getColor8().a
            if a >= 128 then
                bb:setPixel(x + px, y + py, color)
            end
        end
    end
end

local SingleRingWidget = Widget:extend{
    dimen = nil,
    pct = 0.0,
    thick = 6,
    variant = "classic",
    fg = Blitbuffer.COLOR_BLACK,
    track_c = Blitbuffer.COLOR_GRAY_E,
}

function SingleRingWidget:paintTo(bb, x, y)
    local d = self.dimen.w
    if not d or d <= 0 then return end
    local thick = self.thick or 6
    local variant = self.variant or "classic"
    local p_val = math.max(0.0, math.min(1.0, self.pct or 0.0))

    local trk_mask = getInvertedRingMask(d, thick, 1.0, true, variant)
    blitRingMask(bb, x, y, trk_mask, d, self.track_c)

    if p_val > 0 then
        local fg_mask = getInvertedRingMask(d, thick, p_val, false, variant)
        blitRingMask(bb, x, y, fg_mask, d, self.fg)
    end
end

-- Formats cur_mins / goal_mins concisely for rings & compact bars
local function fmtGoalTimePair(cur_mins, goal_mins)
    cur_mins  = math.max(0, math.floor((tonumber(cur_mins) or 0) + 0.5))
    goal_mins = math.max(1, math.floor((tonumber(goal_mins) or 1) + 0.5))
    if goal_mins >= 180 and (cur_mins >= 60 or goal_mins >= 600) then
        local ch = cur_mins / 60
        local gh = goal_mins / 60
        local c_str = (ch >= 10 or math.floor(ch) == ch) and string.format("%d", math.floor(ch + 0.5)) or string.format("%.1f", ch)
        local g_str = (math.floor(gh) == gh) and string.format("%d", math.floor(gh)) or string.format("%.1f", gh)
        return string.format("%s/%s%s", c_str, g_str, _("h"))
    end
    return string.format("%d/%d%s", cur_mins, goal_mins, _("m"))
end

local function parseNumStat(val)
    if type(val) == "number" then return val end
    if type(val) == "table" and val.value then
        local str = tostring(val.value):gsub("[^%d]", "")
        return tonumber(str) or 0
    end
    return tonumber(val) or 0
end

-- Computes normalized { id, pct, val_text, label_text } for an active visual item
function M.computeVisualItem(id, stats, bd, pfx)
    stats = stats or {}
    bd = bd or {}

    if id == "book_progress" then
        local bp = stats.real_pct
        if not bp or bp <= 0 then
            local cp = stats.cur_page or bd.cur_page
            local tp = stats.total_pages or bd.pages
            if cp and tp and cp > 0 and tp > 0 then bp = cp / tp else bp = bd.percent or 0 end
        end
        bp = math.min(1.0, math.max(0.0, bp or 0))
        local disp = math.floor(bp * 100 + 0.5)
        return {
            id         = id,
            pct        = bp,
            val_text   = string.format("%d%%", disp),
            label_text = _("Book"),
        }
    elseif id == "daily_page" then
        local goal = CFG.getDailyPageGoal(pfx)
        local cur = stats.today_pages_num or parseNumStat(stats.today_pages)
        return {
            id         = id,
            pct        = math.min(1.0, math.max(0.0, cur / goal)),
            val_text   = string.format("%d / %d", cur, goal),
            label_text = _("Daily Pg"),
        }
    elseif id == "daily_time" then
        local goal = CFG.getDailyTimeGoal(pfx)
        local cur = stats.today_time_mins or 0
        return {
            id         = id,
            pct        = math.min(1.0, math.max(0.0, cur / goal)),
            val_text   = fmtGoalTimePair(cur, goal),
            label_text = _("Daily Min"),
        }
    elseif id == "week_pages" then
        local goal = CFG.getWeekPageGoal(pfx)
        local cur = stats.week_pages_num or parseNumStat(stats.week_pages)
        return {
            id         = id,
            pct        = math.min(1.0, math.max(0.0, cur / goal)),
            val_text   = string.format("%d / %d", cur, goal),
            label_text = _("Week Pg"),
        }
    elseif id == "week_time" then
        local goal = CFG.getWeekTimeGoal(pfx)
        local cur = stats.week_time_mins or 0
        return {
            id         = id,
            pct        = math.min(1.0, math.max(0.0, cur / goal)),
            val_text   = fmtGoalTimePair(cur, goal),
            label_text = _("Week Min"),
        }
    elseif id == "month_pages" then
        local goal = CFG.getMonthPageGoal(pfx)
        local cur = stats.month_pages_num or parseNumStat(stats.month_pages)
        return {
            id         = id,
            pct        = math.min(1.0, math.max(0.0, cur / goal)),
            val_text   = string.format("%d / %d", cur, goal),
            label_text = _("Month Pg"),
        }
    elseif id == "month_time" then
        local goal = CFG.getMonthTimeGoal(pfx)
        local cur = stats.month_time_mins or 0
        return {
            id         = id,
            pct        = math.min(1.0, math.max(0.0, cur / goal)),
            val_text   = fmtGoalTimePair(cur, goal),
            label_text = _("Month Min"),
        }
    elseif id == "year_pages" then
        local goal = CFG.getYearPageGoal(pfx)
        local cur = stats.year_pages_num or parseNumStat(stats.year_pages)
        return {
            id         = id,
            pct        = math.min(1.0, math.max(0.0, cur / goal)),
            val_text   = string.format("%d / %d", cur, goal),
            label_text = _("Year Pg"),
        }
    elseif id == "year_time" then
        local goal = CFG.getYearTimeGoal(pfx)
        local cur = stats.year_time_mins or 0
        return {
            id         = id,
            pct        = math.min(1.0, math.max(0.0, cur / goal)),
            val_text   = fmtGoalTimePair(cur, goal),
            label_text = _("Year Min"),
        }
    elseif id == "year_books" then
        local goal = CFG.getYearBookGoal(pfx)
        local cur = stats.year_books_num or parseNumStat(stats.year_books)
        return {
            id         = id,
            pct        = math.min(1.0, math.max(0.0, cur / goal)),
            val_text   = string.format("%d / %d", cur, goal),
            label_text = _("Year Books"),
        }
    end
    return nil
end

function M.resolveVisualItems(pfx, stats, bd)
    local ids = CFG.getActiveVisuals(pfx)
    local out = {}
    for _, id in ipairs(ids) do
        local entry = M.computeVisualItem(id, stats, bd, pfx)
        if entry then out[#out + 1] = entry end
    end
    return out
end

-- Computes ring diameter:
--   When any border is enabled around stats or visuals (has_border == true),
--   clamps smoothly at the column/border boundary.
--   When no borders are enabled (has_border == false), allows scaling freely up to 150%
--   (bounded only by the available right-of-cover canvas width max_free_w).
function M.calcRingDiameter(scale, rings_col_w, size_mult, has_border, max_free_w)
    local min_d = math.floor(20 * scale)
    local eff_mult = math.max(0.15, math.min(1.5, size_mult or 1.0))
    local raw_d = math.floor(210 * scale * eff_mult)
    if has_border then
        local max_by_col = math.max(min_d, math.floor((rings_col_w or 260) * 0.96))
        return math.max(min_d, math.min(max_by_col, raw_d))
    end
    local max_free = math.max(min_d, math.floor((max_free_w or math.max(rings_col_w or 260, 440 * scale)) * 0.98))
    return math.max(min_d, math.min(max_free, raw_d))
end

M.HBAR_H_12 = { 3, 4, 6, 8, 10, 12, 14, 17, 20, 24, 28, 32 }

-- Fits text within `max_w` pixels using BAR_LBL_FONT, returning fitted FontFace
local function fitVisualTextFace(pfx, is_bold, target_fs, text, max_w, fallback_face)
    local fs = target_fs
    local font_fam = CFG.getBarLblFont(pfx)
    local face = Font:getFace(resolveFontFace(font_fam, is_bold), fs) or fallback_face
    if not text or text == "" or not max_w or max_w <= 0 then return face, fs end
    local ckey = string.format("%s|%s|%d|%d|%s", tostring(font_fam), is_bold and "1" or "0", target_fs, math.floor(max_w), text)
    local cached_fs = _fit_vis_face_cache[ckey]
    if cached_fs then
        if cached_fs == target_fs then return face, fs end
        return Font:getFace(resolveFontFace(font_fam, is_bold), cached_fs) or face, cached_fs
    end
    local tw = TextWidget:new{ text = text, face = face }
    local w_px = tw:getSize().w
    if type(tw.free) == "function" then tw:free() end
    while w_px > max_w and fs > 6 do
        fs = fs - 1
        face = Font:getFace(resolveFontFace(font_fam, is_bold), fs) or face
        tw = TextWidget:new{ text = text, face = face }
        w_px = tw:getSize().w
        if type(tw.free) == "function" then tw:free() end
    end
    if _fit_vis_face_count >= 64 then
        _fit_vis_face_cache = {}
        _fit_vis_face_count = 0
    end
    _fit_vis_face_cache[ckey] = fs
    _fit_vis_face_count = _fit_vis_face_count + 1
    return face, fs
end

-- Builds right-column widget (Rings stacked vertically OR Vertical Bars side-by-side)
function M.buildSideVisuals(opts)
    local pfx                 = opts.pfx
    local stats               = opts.stats
    local bd                  = opts.bd
    local scale               = opts.scale
    local rings_col_w         = opts.rings_col_w
    local stats_grid_h        = opts.stats_grid_h
    local size_mult           = opts.size_mult
    local show_visuals_border = opts.show_visuals_border
    local border_bw           = opts.border_bw
    local val_fg_color        = opts.val_fg_color
    local lbl_fg_color        = opts.lbl_fg_color
    local bar_val_color       = opts.bar_val_color or val_fg_color
    local bar_lbl_color       = opts.bar_lbl_color or lbl_fg_color
    local clr_fg              = opts.clr_fg
    local clr_bg              = opts.vis_track_color or opts.clr_bg
    local vis_colors          = opts.vis_colors
    local face_v              = opts.face_v
    local face_l              = opts.face_l

    local function getItemColors(idx)
        local c = vis_colors and vis_colors[idx]
        local item_fg = c or clr_fg
        local accent_c = c or opts.clr_dark_eff or item_fg
        local core_c = c and C.darkenColor(c, 0.58) or accent_c
        return item_fg, clr_bg, accent_c, core_c
    end

    local items = M.resolveVisualItems(pfx, stats, bd)
    if #items == 0 then return nil end

    local bar_style = CFG.getBarStyle(pfx)
    local UI = getSUIModule("sui_core", "infra")
    local SS = getSUIStyle()

    local is_bar_lbl_bold = CFG.getBarLblBold(pfx)
    local chosen_fs       = CFG.getBarLblFs(pfx)

    if bar_style == "rings" then
        local RING_THICK_6 = { 0.025, 0.042, 0.060, 0.110, 0.175, 0.235 }
        local ring_thick_lvl = CFG.getRingThickness(pfx)
        local thick_mult = RING_THICK_6[ring_thick_lvl] or 0.110
        local has_border = opts.has_border == true
        local border_bound_w = opts.ring_border_w or rings_col_w
        local ring_d = M.calcRingDiameter(scale, border_bound_w, size_mult, has_border, opts.max_free_w)
        local effective_col_w = has_border and rings_col_w or math.max(rings_col_w, ring_d)
        local ring_variant = CFG.getRingVariant(pfx)
        local show_ring_lbl = CFG.getShowRingLabels(pfx)
        local rings_gap_y = math.max(0, math.floor(CFG.getBarGap(pfx) * scale))

        local function makeRingBlock(entry, idx)
            local item_fg, item_bg = getItemColors(idx)
            local ring_thick = math.max(1, math.floor(ring_d * thick_mult + 0.5))
            local max_ring_thick = math.max(3, math.floor(ring_d * 0.28))
            if ring_thick > max_ring_thick then ring_thick = max_ring_thick end

            local ring = SingleRingWidget:new{
                dimen   = Geom:new{ w = ring_d, h = ring_d },
                pct     = entry.pct,
                thick   = ring_thick,
                variant = ring_variant,
                fg      = item_fg,
                track_c = item_bg,
            }

            local inner_d = ring_d - (ring_thick * 2)
            local face_center = fitVisualTextFace(pfx, is_bar_lbl_bold, math.max(6, math.floor(chosen_fs * scale)), entry.val_text, math.max(8, inner_d - 4), face_v)
            local center_label = UI.makeColoredText{
                text    = entry.val_text,
                face    = face_center,
                fgcolor = bar_val_color,
                bold    = is_bar_lbl_bold,
            }

            local ring_overlap = OverlapGroup:new{
                dimen = Geom:new{ w = ring_d, h = ring_d },
                ring,
                CenterContainer:new{
                    dimen = Geom:new{ w = ring_d, h = ring_d },
                    center_label,
                },
            }

            if show_ring_lbl then
                local bot_lbl_fs = math.max(7, math.floor(chosen_fs * 0.85 * scale))
                local face_bot_lbl = fitVisualTextFace(pfx, is_bar_lbl_bold, bot_lbl_fs, entry.label_text, math.max(20, effective_col_w - 4), face_l)
                local bot_lbl_wid = UI.makeColoredText{
                    text    = entry.label_text,
                    face    = face_bot_lbl,
                    fgcolor = bar_lbl_color,
                    bold    = is_bar_lbl_bold,
                }
                return VerticalGroup:new{
                    align = "center",
                    ring_overlap,
                    VerticalSpan:new{ width = math.max(2, math.floor(4 * scale)) },
                    bot_lbl_wid,
                }
            else
                return ring_overlap
            end
        end

        local col_children = { align = "center" }
        for idx, entry in ipairs(items) do
            local blk = makeRingBlock(entry, idx)
            local wrapper = CenterContainer:new{
                dimen = Geom:new{ w = effective_col_w, h = blk:getSize().h },
                [1] = blk,
            }
            col_children[#col_children + 1] = wrapper
            if idx < #items and rings_gap_y > 0 then
                col_children[#col_children + 1] = VerticalSpan:new{ width = rings_gap_y }
            end
        end
        return VerticalGroup:new(col_children)
    end

    -- Vertical Bars mode: up to 3 bars side by side
    local VBAR_THICK_12 = {
        0.022, 0.034, 0.047, 0.060, 0.110, 0.180,
        0.240, 0.285, 0.330, 0.375, 0.425, 0.480,
    }
    local vbar_thick_lvl = CFG.getVBarThickness(pfx)
    local thick_mult = VBAR_THICK_12[vbar_thick_lvl] or 0.110
    local vbar_variant = CFG.getVBarVariant(pfx)
    local vbar_gap = math.max(0, math.floor(CFG.getVBarGap(pfx) * scale))
    local n_bars = #items
    local base_target_h = math.max(math.floor(130 * scale), stats_grid_h - math.floor(25 * scale))
    local bar_h = math.max(40, math.floor(base_target_h * size_mult))
    local usable_col_w = math.max(12, rings_col_w - (show_visuals_border and (border_bw * 2 + 4) or 4))
    local raw_bar_w = math.max(3, math.floor(20 * scale * (thick_mult / 0.11) * math.max(0.75, math.min(1.35, math.sqrt(size_mult))) + 0.5))
    local max_bar_w = math.max(5, math.floor((usable_col_w - vbar_gap * math.max(0, n_bars - 1)) / n_bars))
    local bar_w = math.min(raw_bar_w, max_bar_w)
    local per_col_w = math.max(bar_w, math.floor((usable_col_w - vbar_gap * math.max(0, n_bars - 1)) / n_bars))

    local radius = (vbar_variant == "flat") and 0
                or (vbar_variant == "rounded" and math.max(1, math.min(6, math.floor(bar_w * 0.22))))
                or math.max(1, math.floor(bar_w / 2))

    local function makeVBarPiece(w, h, color, rad_override)
        local r = (rad_override ~= nil) and rad_override or radius
        return C.makeColorFill(w, h, color, r)
    end

    local val_fs_scaled = math.max(8, math.floor(chosen_fs * scale))
    local surface_c = (type(opts.surface_color) ~= "nil" and opts.surface_color)
                   or (SS and SS.COLOR and SS.COLOR.surface)
                   or Blitbuffer.COLOR_WHITE

    local function makeFramedVBar(pct, inset_pad, item_fg)
        local bw = math.max(1, math.min(3, math.floor(bar_w * 0.12) + 1))
        local pad = inset_pad
        if (bar_w - (bw + pad) * 2) < 2 then pad = 0 end
        if (bar_w - bw * 2) < 2 then bw = 1 end
        local inner_w = math.max(1, bar_w - (bw + pad) * 2)
        local inner_h = math.max(2, bar_h - (bw + pad) * 2)
        local fh = (pct <= 0) and 0 or math.max(1, math.min(inner_h, math.floor(inner_h * pct + 0.5)))
        local inner_r = (pad > 0) and math.max(1, math.floor(inner_w / 2)) or 1
        local inner_wid
        if fh > 0 then
            inner_wid = OverlapGroup:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                makeVBarPiece(inner_w, inner_h, surface_c, inner_r),
                BottomContainer:new{
                    dimen = Geom:new{ w = inner_w, h = inner_h },
                    makeVBarPiece(inner_w, fh, item_fg, inner_r),
                },
            }
        else
            inner_wid = makeVBarPiece(inner_w, inner_h, surface_c, inner_r)
        end
        local outer_r = (pad > 0) and math.max(2, math.floor(bar_w / 2)) or 2
        return C.makeColorStrokeBox(bar_w, bar_h, bw, item_fg, outer_r, inner_wid, surface_c)
    end

    local function makeSolidVBar(pct, bar_rad, item_fg, item_bg)
        local track = makeVBarPiece(bar_w, bar_h, item_bg, bar_rad)
        local fill_h = (pct <= 0) and 0 or math.max(1, math.min(bar_h, math.floor(bar_h * pct + 0.5)))
        if fill_h <= 0 then return track end
        local fill_rad = (bar_rad > 0 and fill_h < (bar_rad * 2)) and math.floor(fill_h / 2) or bar_rad
        return OverlapGroup:new{
            dimen = Geom:new{ w = bar_w, h = bar_h },
            track,
            BottomContainer:new{
                dimen = Geom:new{ w = bar_w, h = bar_h },
                makeVBarPiece(bar_w, fill_h, item_fg, fill_rad),
            },
        }
    end

    local function makeSingleVBar(entry, idx)
        local pct = math.max(0.0, math.min(1.0, entry.pct or 0.0))
        local item_fg, item_bg, accent_c, core_c = getItemColors(idx)
        local bar_stack
        if vbar_variant == "outlined" then
            bar_stack = makeFramedVBar(pct, 0, item_fg)
        elseif vbar_variant == "double_frame" then
            bar_stack = makeFramedVBar(pct, math.max(1, math.floor(bar_w * 0.14)), item_fg)
        elseif vbar_variant == "needle" then
            local track_w = math.max(2, math.min(bar_w, math.floor(bar_w * 0.24)))
            local track_x = math.floor((bar_w - track_w) / 2)
            local track = makeVBarPiece(track_w, bar_h, item_bg, math.floor(track_w / 2))
            track.overlap_offset = { track_x, 0 }
            local fh = (pct <= 0) and 0 or math.max(2, math.min(bar_h, math.floor(bar_h * pct + 0.5)))
            local items_ov = { dimen = Geom:new{ w = bar_w, h = bar_h }, track }
            if fh > 0 then
                local fill = makeVBarPiece(track_w, fh, item_fg, math.floor(track_w / 2))
                fill.overlap_offset = { track_x, bar_h - fh }
                table.insert(items_ov, fill)
            end
            local knob_h = math.max(4, math.min(math.floor(bar_h * 0.08), math.max(5, math.floor(bar_w * 0.85))))
            local knob_y = math.max(0, math.min(bar_h - knob_h, bar_h - fh - math.floor(knob_h / 2)))
            local knob = makeVBarPiece(bar_w, knob_h, accent_c, math.floor(math.min(bar_w, knob_h) / 2))
            knob.overlap_offset = { 0, knob_y }
            table.insert(items_ov, knob)
            bar_stack = OverlapGroup:new(items_ov)
        elseif vbar_variant == "ruler" then
            local track = makeVBarPiece(bar_w, bar_h, item_bg, 2)
            local fh = (pct <= 0) and 0 or math.max(1, math.min(bar_h, math.floor(bar_h * pct + 0.5)))
            local items_ov = { dimen = Geom:new{ w = bar_w, h = bar_h }, track }
            if fh > 0 then
                local fill = makeVBarPiece(bar_w, fh, item_fg, 2)
                fill.overlap_offset = { 0, bar_h - fh }
                table.insert(items_ov, fill)
            end
            local tick_h = math.max(1, math.floor(scale))
            local tick_w = math.max(3, math.floor(bar_w * 0.50))
            for q = 1, 3 do
                local tick = C.makeColorFill(tick_w, tick_h, surface_c, 0)
                tick.overlap_offset = { 0, math.floor(bar_h * (q / 4)) }
                table.insert(items_ov, tick)
            end
            bar_stack = OverlapGroup:new(items_ov)
        elseif vbar_variant == "spine_core" then
            local outer = makeVBarPiece(bar_w, bar_h, item_bg, math.max(1, math.floor(bar_w / 2)))
            local core_w = math.max(2, math.floor(bar_w * 0.44))
            local core_x = math.floor((bar_w - core_w) / 2)
            local fh = (pct <= 0) and 0 or math.max(2, math.min(bar_h, math.floor(bar_h * pct + 0.5)))
            local items_ov = { dimen = Geom:new{ w = bar_w, h = bar_h }, outer }
            if fh > 0 then
                local core = makeVBarPiece(core_w, fh, accent_c, math.max(1, math.floor(core_w / 2)))
                core.overlap_offset = { core_x, bar_h - fh }
                table.insert(items_ov, core)
            end
            bar_stack = OverlapGroup:new(items_ov)
        elseif vbar_variant == "horizon_cap" then
            local slim_w = math.max(2, math.floor(bar_w * 0.72))
            local slim_x = math.floor((bar_w - slim_w) / 2)
            local track = makeVBarPiece(slim_w, bar_h, item_bg, 0)
            track.overlap_offset = { slim_x, 0 }
            local fh = (pct <= 0) and 0 or math.max(1, math.min(bar_h, math.floor(bar_h * pct + 0.5)))
            local items_ov = { dimen = Geom:new{ w = bar_w, h = bar_h }, track }
            if fh > 0 then
                local fill = makeVBarPiece(slim_w, fh, item_fg, 0)
                fill.overlap_offset = { slim_x, bar_h - fh }
                table.insert(items_ov, fill)
            end
            local cap_h = math.max(2, math.floor(scale * 2.5))
            local cap_y = math.max(0, math.min(bar_h - cap_h, bar_h - fh - math.floor(cap_h / 2)))
            local cap = makeVBarPiece(bar_w, cap_h, accent_c, 0)
            cap.overlap_offset = { 0, cap_y }
            table.insert(items_ov, cap)
            bar_stack = OverlapGroup:new(items_ov)
        elseif vbar_variant == "orbit_pin" then
            local rail_w = math.max(1, math.floor(bar_w * 0.16))
            local rail_x = math.floor((bar_w - rail_w) / 2)
            local rail = makeVBarPiece(rail_w, bar_h, item_bg, 0)
            rail.overlap_offset = { rail_x, 0 }
            local fh = (pct <= 0) and 0 or math.max(2, math.min(bar_h, math.floor(bar_h * pct + 0.5)))
            local items_ov = { dimen = Geom:new{ w = bar_w, h = bar_h }, rail }
            if fh > 0 then
                local fw = math.max(2, math.floor(bar_w * 0.52))
                local fill = makeVBarPiece(fw, fh, item_fg, math.max(1, math.floor(fw / 2)))
                fill.overlap_offset = { math.floor((bar_w - fw) / 2), bar_h - fh }
                table.insert(items_ov, fill)
            end
            local pin_d = math.max(4, math.min(bar_w, math.floor(bar_w * 0.92)))
            local pin_y = math.max(0, math.min(bar_h - pin_d, bar_h - fh - math.floor(pin_d / 2)))
            local pin = makeVBarPiece(pin_d, pin_d, accent_c, math.floor(pin_d / 2))
            pin.overlap_offset = { math.floor((bar_w - pin_d) / 2), pin_y }
            table.insert(items_ov, pin)
            bar_stack = OverlapGroup:new(items_ov)
        elseif vbar_variant == "split_rail" then
            local gap = math.max(2, math.floor(bar_w * 0.20))
            local rw = math.max(1, math.floor((bar_w - gap) / 2))
            local rad = math.max(0, math.floor(rw / 2))
            local fh = (pct <= 0) and 0 or math.max(1, math.min(bar_h, math.floor(bar_h * pct + 0.5)))
            local function makeRailColumn()
                local trk = makeVBarPiece(rw, bar_h, item_bg, rad)
                if fh <= 0 then return trk end
                local f = makeVBarPiece(rw, fh, item_fg, math.min(rad, math.floor(fh / 2)))
                return OverlapGroup:new{
                    dimen = Geom:new{ w = rw, h = bar_h },
                    trk,
                    BottomContainer:new{ dimen = Geom:new{ w = rw, h = bar_h }, f },
                }
            end
            bar_stack = HorizontalGroup:new{
                align = "center",
                makeRailColumn(),
                HorizontalSpan:new{ width = gap },
                makeRailColumn(),
            }
        elseif vbar_variant == "bracket_hud" then
            local cap_h = math.max(2, math.floor(scale * 2))
            local pillar_pad = cap_h + math.max(2, math.floor(scale * 2))
            local ph = math.max(4, bar_h - pillar_pad * 2)
            local pw = math.max(2, math.floor(bar_w * 0.64))
            local px = math.floor((bar_w - pw) / 2)
            local trk = makeVBarPiece(pw, ph, item_bg, 0)
            trk.overlap_offset = { px, pillar_pad }
            local top_b = makeVBarPiece(bar_w, cap_h, accent_c, 0)
            top_b.overlap_offset = { 0, 0 }
            local bot_b = makeVBarPiece(bar_w, cap_h, accent_c, 0)
            bot_b.overlap_offset = { 0, bar_h - cap_h }
            local items_ov = { dimen = Geom:new{ w = bar_w, h = bar_h }, trk, top_b, bot_b }
            local fh = (pct <= 0) and 0 or math.max(1, math.min(ph, math.floor(ph * pct + 0.5)))
            if fh > 0 then
                local fill = makeVBarPiece(pw, fh, item_fg, 0)
                fill.overlap_offset = { px, pillar_pad + ph - fh }
                table.insert(items_ov, fill)
            end
            bar_stack = OverlapGroup:new(items_ov)
        elseif vbar_variant == "prism_taper" then
            local track = makeVBarPiece(bar_w, bar_h, item_bg, 2)
            local items_ov = { dimen = Geom:new{ w = bar_w, h = bar_h }, track }
            local fh = (pct <= 0) and 0 or math.max(2, math.min(bar_h, math.floor(bar_h * pct + 0.5)))
            if fh > 0 then
                local outer_f = makeVBarPiece(bar_w, fh, item_fg, 1)
                outer_f.overlap_offset = { 0, bar_h - fh }
                table.insert(items_ov, outer_f)
                local core_w = math.max(1, math.floor(bar_w * 0.42))
                local core_f = makeVBarPiece(core_w, fh, core_c, 0)
                core_f.overlap_offset = { math.floor((bar_w - core_w) / 2), bar_h - fh }
                table.insert(items_ov, core_f)
                local tip_h = math.max(2, math.floor(scale * 2))
                local tip = C.makeColorFill(bar_w, tip_h, surface_c, 0)
                tip.overlap_offset = { 0, math.max(0, bar_h - fh) }
                table.insert(items_ov, tip)
            end
            bar_stack = OverlapGroup:new(items_ov)
        elseif vbar_variant == "crosshair_bar" then
            local track = makeVBarPiece(bar_w, bar_h, item_bg, 0)
            local items_ov = { dimen = Geom:new{ w = bar_w, h = bar_h }, track }
            local fh = (pct <= 0) and 0 or math.max(1, math.min(bar_h, math.floor(bar_h * pct + 0.5)))
            if fh > 0 then
                local fw = math.max(2, math.floor(bar_w * 0.72))
                local f = makeVBarPiece(fw, fh, accent_c, 0)
                f.overlap_offset = { math.floor((bar_w - fw) / 2), bar_h - fh }
                table.insert(items_ov, f)
            end
            local mid_line = C.makeColorFill(bar_w, math.max(1, math.floor(scale)), surface_c, 0)
            mid_line.overlap_offset = { 0, math.floor(bar_h / 2) }
            table.insert(items_ov, mid_line)
            bar_stack = OverlapGroup:new(items_ov)
        elseif vbar_variant == "neon_edge" then
            local edge_w = math.max(1, math.floor(bar_w * 0.22))
            local body_w = math.max(2, bar_w - edge_w - 1)
            local trk = makeVBarPiece(body_w, bar_h, item_bg, 0)
            trk.overlap_offset = { edge_w + 1, 0 }
            local spine = makeVBarPiece(edge_w, bar_h, item_fg, 0)
            spine.overlap_offset = { 0, 0 }
            local items_ov = { dimen = Geom:new{ w = bar_w, h = bar_h }, spine, trk }
            local fh = (pct <= 0) and 0 or math.max(1, math.min(bar_h, math.floor(bar_h * pct + 0.5)))
            if fh > 0 then
                local body_f = makeVBarPiece(body_w, fh, accent_c, 0)
                body_f.overlap_offset = { edge_w + 1, bar_h - fh }
                table.insert(items_ov, body_f)
            end
            bar_stack = OverlapGroup:new(items_ov)
        else
            -- "capsule", "flat", "rounded"
            bar_stack = makeSolidVBar(pct, radius, item_fg, item_bg)
        end

        local face_val = fitVisualTextFace(pfx, is_bar_lbl_bold, val_fs_scaled, entry.val_text, math.max(8, per_col_w - 2), face_v)
        local val_wid = UI.makeColoredText{
            text                   = entry.val_text,
            face                   = face_val,
            fgcolor                = bar_val_color,
            bold                   = is_bar_lbl_bold,
            max_width              = math.max(8, per_col_w - 2),
            truncate_with_ellipsis = true,
        }
        local col_grp = VerticalGroup:new{
            align = "center",
            bar_stack,
            VerticalSpan:new{ width = math.max(3, math.floor(6 * scale)) },
            val_wid,
        }
        return CenterContainer:new{
            dimen = Geom:new{ w = per_col_w, h = col_grp:getSize().h },
            [1] = col_grp,
        }
    end

    local hg_children = { align = "top" }
    for idx, entry in ipairs(items) do
        hg_children[#hg_children + 1] = makeSingleVBar(entry, idx)
        if idx < n_bars and vbar_gap > 0 then
            hg_children[#hg_children + 1] = HorizontalSpan:new{ width = vbar_gap }
        end
    end

    local bars_group = HorizontalGroup:new(hg_children)
    return CenterContainer:new{
        dimen = Geom:new{ w = rings_col_w, h = bars_group:getSize().h },
        bars_group,
    }
end

-- Builds Horizontal Bars stacked vertically below the stats grid
function M.buildHorizontalVisuals(opts)
    local pfx            = opts.pfx
    local stats          = opts.stats
    local bd             = opts.bd
    local scale          = opts.scale
    local mid_w          = opts.mid_w
    local target_total_w = opts.target_total_w
    local val_fg_color   = opts.bar_val_color or opts.val_fg_color
    local clr_fg         = opts.clr_fg
    local clr_bg         = opts.vis_track_color or opts.clr_bg
    local vis_colors     = opts.vis_colors
    local face_l         = opts.face_l

    local function getHItemColors(idx)
        local c = vis_colors and vis_colors[idx]
        local item_fg = c or clr_fg
        local accent_c = c or opts.clr_dark_eff or item_fg
        return item_fg, clr_bg, accent_c
    end

    local items = M.resolveVisualItems(pfx, stats, bd)
    if #items == 0 then return nil, 0 end

    local UI = getSUIModule("sui_core", "infra")
    local SS = getSUIStyle()

    local thick_level = CFG.getHBarThickness(pfx)
    local hbar_h = math.max(2, math.floor((M.HBAR_H_12[thick_level] or 10) * scale))
    local hbar_variant = CFG.getHBarVariant(pfx)
    local is_bar_lbl_bold = CFG.getBarLblBold(pfx)
    local bar_lbl_fs = math.max(10, math.floor(CFG.getBarLblFs(pfx) * scale))
    local face_bar_lbl = Font:getFace(resolveFontFace(CFG.getBarLblFont(pfx), is_bar_lbl_bold), bar_lbl_fs) or face_l

    local function make_val_tw(txt)
        if UI and UI.makeColoredText then
            return UI.makeColoredText{
                text    = txt,
                face    = face_bar_lbl,
                fgcolor = val_fg_color,
                bold    = true,
            }
        else
            return TextWidget:new{
                text    = txt,
                face    = face_bar_lbl,
                fgcolor = val_fg_color,
                bold    = true,
            }
        end
    end

    local val_wids = {}
    local max_val_w = 0
    for i, entry in ipairs(items) do
        local wid = make_val_tw(entry.val_text)
        val_wids[i] = wid
        local w = wid:getSize().w
        if w > max_val_w then max_val_w = w end
    end

    local bg_pad = (type(opts.bg_color) ~= "nil") and (opts.bg_pad or 0) or 0
    local num_gap = math.max(4, math.floor(6 * scale))
    local full_bar_w = math.max(20, target_total_w - (bg_pad * 2) - max_val_w - num_gap)
    local length_pct = CFG.getHBarLengthPct(pfx)
    local bar_w = math.max(20, math.floor(full_bar_w * (length_pct / 100)))

    local surface_c = (type(opts.surface_color) ~= "nil" and opts.surface_color)
                   or (SS and SS.COLOR and SS.COLOR.surface)
                   or Blitbuffer.COLOR_WHITE

    local function makeHBarPiece(w, h, color, rad)
        return C.makeColorFill(w, h, color, rad or 0)
    end

    local function makeFramedHBar(pct, inset_pad, item_fg)
        local bw = math.max(1, math.min(2, math.floor(hbar_h * 0.14) + 1))
        local pad = inset_pad
        if (hbar_h - (bw + pad) * 2) < 2 then pad = 0 end
        if (hbar_h - bw * 2) < 2 then bw = 1 end
        local inner_w = math.max(4, bar_w - (bw + pad) * 2)
        local inner_h = math.max(1, hbar_h - (bw + pad) * 2)
        local fw = (pct <= 0) and 0 or math.max(1, math.min(inner_w, math.floor(inner_w * pct + 0.5)))
        local ir = (pad > 0) and math.max(1, math.floor(inner_h / 2)) or 1
        local inner_wid
        if fw > 0 then
            inner_wid = OverlapGroup:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                makeHBarPiece(inner_w, inner_h, surface_c, ir),
                makeHBarPiece(fw, inner_h, item_fg, ir),
            }
        else
            inner_wid = makeHBarPiece(inner_w, inner_h, surface_c, ir)
        end
        local outer_r = (pad > 0) and math.max(2, math.floor(hbar_h / 2)) or 2
        return C.makeColorStrokeBox(bar_w, hbar_h, bw, item_fg, outer_r, inner_wid, surface_c)
    end

    local function makeSingleHBar(pct, idx)
        pct = math.max(0.0, math.min(1.0, pct or 0.0))
        local item_fg, item_bg, accent_c = getHItemColors(idx)
        if hbar_variant == "rounded" or hbar_variant == "flat" then
            local r = (hbar_variant == "rounded") and math.max(1, math.min(6, math.floor(hbar_h * 0.28))) or 0
            local track = makeHBarPiece(bar_w, hbar_h, item_bg, r)
            local fw = (pct <= 0) and 0 or math.max(1, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
            if fw > 0 then
                local fr = (r > 0 and fw < (r * 2)) and math.floor(fw / 2) or r
                return OverlapGroup:new{
                    dimen = Geom:new{ w = bar_w, h = hbar_h },
                    track,
                    makeHBarPiece(fw, hbar_h, item_fg, fr),
                }
            end
            return track
        elseif hbar_variant == "outlined" then
            return makeFramedHBar(pct, 0, item_fg)
        elseif hbar_variant == "inset_frame" then
            return makeFramedHBar(pct, math.max(1, math.floor(hbar_h * 0.14)), item_fg)
        elseif hbar_variant == "thin_track" then
            local trk_h = math.max(1, math.floor(hbar_h * 0.30))
            local trk = makeHBarPiece(bar_w, trk_h, item_bg, math.floor(trk_h / 2))
            trk.overlap_offset = { 0, math.floor((hbar_h - trk_h) / 2) }
            local items_ov = { dimen = Geom:new{ w = bar_w, h = hbar_h }, trk }
            local fw = (pct <= 0) and 0 or math.max(2, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
            if fw > 0 then
                table.insert(items_ov, makeHBarPiece(fw, hbar_h, item_fg, math.max(1, math.floor(hbar_h / 2))))
            end
            return OverlapGroup:new(items_ov)
        elseif hbar_variant == "slider_dot" then
            local trk_h = math.max(2, math.min(hbar_h, math.floor(hbar_h * 0.28)))
            local trk_y = math.floor((hbar_h - trk_h) / 2)
            local trk = makeHBarPiece(bar_w, trk_h, item_bg, math.floor(trk_h / 2))
            trk.overlap_offset = { 0, trk_y }
            local items_ov = { dimen = Geom:new{ w = bar_w, h = hbar_h }, trk }
            local fw = (pct <= 0) and 0 or math.max(2, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
            if fw > 0 then
                local f = makeHBarPiece(fw, trk_h, item_fg, math.floor(trk_h / 2))
                f.overlap_offset = { 0, trk_y }
                table.insert(items_ov, f)
            end
            local knob_w = math.max(5, math.min(math.floor(bar_w * 0.10), math.max(6, math.floor(hbar_h * 0.85))))
            local knob_x = math.max(0, math.min(bar_w - knob_w, fw - math.floor(knob_w / 2)))
            local knob = makeHBarPiece(knob_w, hbar_h, accent_c, math.floor(math.min(knob_w, hbar_h) / 2))
            knob.overlap_offset = { knob_x, 0 }
            table.insert(items_ov, knob)
            return OverlapGroup:new(items_ov)
        elseif hbar_variant == "ruler" then
            local track = makeHBarPiece(bar_w, hbar_h, item_bg, 2)
            local fw = (pct <= 0) and 0 or math.max(1, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
            local items_ov = { dimen = Geom:new{ w = bar_w, h = hbar_h }, track }
            if fw > 0 then
                table.insert(items_ov, makeHBarPiece(fw, hbar_h, item_fg, 2))
            end
            local tick_w = math.max(1, math.floor(scale))
            local tick_h = math.max(2, math.floor(hbar_h * 0.50))
            local tick_y = hbar_h - tick_h
            for q = 1, 3 do
                local tick = C.makeColorFill(tick_w, tick_h, surface_c, 0)
                tick.overlap_offset = { math.floor(bar_w * (q / 4)), tick_y }
                table.insert(items_ov, tick)
            end
            return OverlapGroup:new(items_ov)
        elseif hbar_variant == "horizon_tip" then
            local slim_h = math.max(2, math.floor(hbar_h * 0.72))
            local slim_y = math.floor((hbar_h - slim_h) / 2)
            local trk = makeHBarPiece(bar_w, slim_h, item_bg, 0)
            trk.overlap_offset = { 0, slim_y }
            local items_ov = { dimen = Geom:new{ w = bar_w, h = hbar_h }, trk }
            local fw = (pct <= 0) and 0 or math.max(1, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
            if fw > 0 then
                local fill = makeHBarPiece(fw, slim_h, item_fg, 0)
                fill.overlap_offset = { 0, slim_y }
                table.insert(items_ov, fill)
            end
            local tip_w = math.max(2, math.floor(scale * 2.5))
            local tip_x = math.max(0, math.min(bar_w - tip_w, fw - math.floor(tip_w / 2)))
            local tip = makeHBarPiece(tip_w, hbar_h, accent_c, 0)
            tip.overlap_offset = { tip_x, 0 }
            table.insert(items_ov, tip)
            return OverlapGroup:new(items_ov)
        elseif hbar_variant == "twin_rail" then
            local gap = math.max(2, math.floor(hbar_h * 0.22))
            local rh = math.max(1, math.floor((hbar_h - gap) / 2))
            local rad = math.max(0, math.floor(rh / 2))
            local fw = (pct <= 0) and 0 or math.max(1, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
            local function makeHRail()
                local trk = makeHBarPiece(bar_w, rh, item_bg, rad)
                if fw <= 0 then return trk end
                return OverlapGroup:new{
                    dimen = Geom:new{ w = bar_w, h = rh },
                    trk,
                    makeHBarPiece(fw, rh, item_fg, math.min(rad, math.floor(fw / 2))),
                }
            end
            return VerticalGroup:new{
                align = "left",
                makeHRail(),
                VerticalSpan:new{ width = gap },
                makeHRail(),
            }
        elseif hbar_variant == "bracket_hud" then
            local cap_w = math.max(2, math.floor(scale * 2))
            local inner_pad = cap_w + math.max(2, math.floor(scale * 2))
            local iw = math.max(8, bar_w - inner_pad * 2)
            local ih = math.max(2, math.floor(hbar_h * 0.62))
            local iy = math.floor((hbar_h - ih) / 2)
            local trk = makeHBarPiece(iw, ih, item_bg, 0)
            trk.overlap_offset = { inner_pad, iy }
            local lb = makeHBarPiece(cap_w, hbar_h, accent_c, 0)
            lb.overlap_offset = { 0, 0 }
            local rb = makeHBarPiece(cap_w, hbar_h, accent_c, 0)
            rb.overlap_offset = { bar_w - cap_w, 0 }
            local items_ov = { dimen = Geom:new{ w = bar_w, h = hbar_h }, trk, lb, rb }
            local fw = (pct <= 0) and 0 or math.max(1, math.min(iw, math.floor(iw * pct + 0.5)))
            if fw > 0 then
                local f = makeHBarPiece(fw, ih, item_fg, 0)
                f.overlap_offset = { inner_pad, iy }
                table.insert(items_ov, f)
            end
            return OverlapGroup:new(items_ov)
        elseif hbar_variant == "plasma_core" then
            local chan = makeHBarPiece(bar_w, hbar_h, item_bg, math.max(1, math.floor(hbar_h / 2)))
            local core_h = math.max(2, math.floor(hbar_h * 0.44))
            local core_y = math.floor((hbar_h - core_h) / 2)
            local fw = (pct <= 0) and 0 or math.max(2, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
            local items_ov = { dimen = Geom:new{ w = bar_w, h = hbar_h }, chan }
            if fw > 0 then
                local core = makeHBarPiece(fw, core_h, accent_c, math.max(1, math.floor(core_h / 2)))
                core.overlap_offset = { 0, core_y }
                table.insert(items_ov, core)
            end
            return OverlapGroup:new(items_ov)
        elseif hbar_variant == "target_node" then
            local wire_h = math.max(1, math.floor(hbar_h * 0.20))
            local wire_y = math.floor((hbar_h - wire_h) / 2)
            local wire = makeHBarPiece(bar_w, wire_h, item_bg, 0)
            wire.overlap_offset = { 0, wire_y }
            local items_ov = { dimen = Geom:new{ w = bar_w, h = hbar_h }, wire }
            local fw = (pct <= 0) and 0 or math.max(2, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
            if fw > 0 then
                local fh = math.max(2, math.floor(hbar_h * 0.48))
                local fill = makeHBarPiece(fw, fh, item_fg, math.max(1, math.floor(fh / 2)))
                fill.overlap_offset = { 0, math.floor((hbar_h - fh) / 2) }
                table.insert(items_ov, fill)
            end
            local node_d = math.max(5, math.min(bar_w, hbar_h))
            local node_x = math.max(0, math.min(bar_w - node_d, fw - math.floor(node_d / 2)))
            local node = makeHBarPiece(node_d, node_d, accent_c, math.floor(node_d / 2))
            node.overlap_offset = { node_x, math.floor((hbar_h - node_d) / 2) }
            table.insert(items_ov, node)
            return OverlapGroup:new(items_ov)
        elseif hbar_variant == "visor_strip" then
            local top_rail_h = math.max(1, math.floor(hbar_h * 0.22))
            local body_h = math.max(2, hbar_h - top_rail_h - 1)
            local rail = makeHBarPiece(bar_w, top_rail_h, item_fg, 0)
            rail.overlap_offset = { 0, 0 }
            local chan = makeHBarPiece(bar_w, body_h, item_bg, 0)
            chan.overlap_offset = { 0, top_rail_h + 1 }
            local items_ov = { dimen = Geom:new{ w = bar_w, h = hbar_h }, rail, chan }
            local fw = (pct <= 0) and 0 or math.max(1, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
            if fw > 0 then
                local fill = makeHBarPiece(fw, body_h, accent_c, 0)
                fill.overlap_offset = { 0, top_rail_h + 1 }
                table.insert(items_ov, fill)
            end
            return OverlapGroup:new(items_ov)
        elseif hbar_variant == "neon_chamber" then
            local rail_h = math.max(1, math.floor(scale))
            local inner_h = math.max(2, hbar_h - rail_h * 2 - 2)
            local inner_y = rail_h + 1
            local top_r = makeHBarPiece(bar_w, rail_h, item_fg, 0)
            top_r.overlap_offset = { 0, 0 }
            local bot_r = makeHBarPiece(bar_w, rail_h, item_fg, 0)
            bot_r.overlap_offset = { 0, hbar_h - rail_h }
            local trk = makeHBarPiece(bar_w, inner_h, item_bg, 0)
            trk.overlap_offset = { 0, inner_y }
            local items_ov = { dimen = Geom:new{ w = bar_w, h = hbar_h }, top_r, bot_r, trk }
            local fw = (pct <= 0) and 0 or math.max(1, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
            if fw > 0 then
                local fill = makeHBarPiece(fw, inner_h, accent_c, 0)
                fill.overlap_offset = { 0, inner_y }
                table.insert(items_ov, fill)
            end
            return OverlapGroup:new(items_ov)
        else
            -- "sui"
            if (vis_colors and vis_colors[idx]) or opts.vis_track_color then
                local trk = makeHBarPiece(bar_w, hbar_h, item_bg, 0)
                local fw = (pct <= 0) and 0 or math.max(1, math.min(bar_w, math.floor(bar_w * pct + 0.5)))
                if fw <= 0 then return trk end
                return OverlapGroup:new{
                    dimen = Geom:new{ w = bar_w, h = hbar_h },
                    trk,
                    makeHBarPiece(fw, hbar_h, item_fg, 0),
                }
            end
            return UI.progressBar(bar_w, pct, hbar_h, item_fg, item_bg)
        end
    end

    local row_h = hbar_h
    for _, wid in ipairs(val_wids) do
        local h = wid:getSize().h
        if h > row_h then row_h = h end
    end

    local inter_bar_gap = math.max(0, math.floor(CFG.getHBarGap(pfx) * scale))
    local v_children = { align = "left" }
    for i, entry in ipairs(items) do
        local bar_wid = makeSingleHBar(entry.pct, i)
        local row_wid = HorizontalGroup:new{
            align = "center",
            bar_wid,
            HorizontalSpan:new{ width = num_gap },
            RightContainer:new{
                dimen = Geom:new{ w = max_val_w, h = row_h },
                val_wids[i],
            },
        }
        v_children[#v_children + 1] = row_wid
        if i < #items and inter_bar_gap > 0 then
            v_children[#v_children + 1] = VerticalSpan:new{ width = inter_bar_gap }
        end
    end

    local hbar_inner = VerticalGroup:new(v_children)
    local hb_sz = hbar_inner:getSize()
    local h_box_h = hb_sz.h + (bg_pad * 2)
    local hbar_left_aligned
    if type(opts.bg_color) ~= "nil" then
        local inner_aligned = LeftContainer:new{
            dimen = Geom:new{ w = math.max(1, mid_w - (bg_pad * 2)), h = hb_sz.h },
            [1] = hbar_inner,
        }
        hbar_left_aligned = OverlapGroup:new{
            dimen = Geom:new{ w = mid_w, h = h_box_h },
            C.makeColorFill(mid_w, h_box_h, opts.bg_color, opts.bg_radius or 0),
            CenterContainer:new{
                dimen = Geom:new{ w = mid_w, h = h_box_h },
                inner_aligned,
            },
        }
    else
        hbar_left_aligned = LeftContainer:new{
            dimen = Geom:new{ w = mid_w, h = hb_sz.h },
            [1] = hbar_inner,
        }
    end
    local hbar_container = InputContainer:new{
        dimen = Geom:new{ w = target_total_w, h = h_box_h },
        [1] = hbar_left_aligned,
    }
    local extra_h = math.max(4, math.floor(6 * scale)) + hbar_container:getSize().h
    return hbar_container, extra_h
end

return M
