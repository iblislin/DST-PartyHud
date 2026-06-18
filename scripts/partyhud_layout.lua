-- partyhud_layout.lua
-- Pure layout / dodge math, extracted from modmain so it can be busted-tested with zero engine deps
-- (same pattern as partyhud_statuscodec / partyhud_crossshard). modmain reads the live engine values
-- (screen size, HUD scale, widget presence, backpack mode) and delegates the arithmetic here.
local M = {}

M.STATUS_SCALE   = 1.4          -- statusdisplays default scale (controls.lua:155)
M.REF_W, M.REF_H = 1280, 720    -- RESOLUTION_X / RESOLUTION_Y reference
M.MAX_PROP       = 1.25         -- MAX_HUD_SCALE upscale cap
M.BADGE_BOTTOM   = 60           -- a badge's sub-ring bottom, below its origin
M.PERCOL_FALLBACK = 6           -- safe per-column count if screen/HUD scale is unreadable

-- badges that fit in one column given screen geometry. >= 1 (or PERCOL_FALLBACK if screen/scale
-- unreadable). vgap is the NEGATIVE row gap (rows go down); bottom_reserve is the bottom keep-out.
-- Dividing by `prop` is the v2026.8 proportional-scale fix: a sub-720 window shrinks the real badges,
-- so `usable` (screen height in badge-local units) must track it or the column collapses to 1 badge.
function M.percol_count(scrnw, scrnh, hudscale, vy, bottom_reserve, vgap)
    if scrnh == nil or scrnh <= 0 or scrnw == nil or scrnw <= 0 or hudscale == nil or hudscale <= 0 then
        return M.PERCOL_FALLBACK
    end
    local prop = math.min(scrnw / M.REF_W, scrnh / M.REF_H)
    if prop > M.MAX_PROP then prop = M.MAX_PROP end
    if prop <= 0 then prop = 1 end
    local usable = scrnh / (hudscale * M.STATUS_SCALE * prop)
    local rowpitch = -vgap
    local n = math.floor((vy - M.BADGE_BOTTOM + usable - bottom_reserve) / rowpitch) + 1
    if n < 1 then n = 1 end
    return n
end

-- how many leading columns the top-right status second-row band spans (0/1/2) + how far down to push
-- them (= the deepest active badge's reserve). moisture/abigail/inspiration are booleans.
function M.second_row_span(moisture, abigail, inspiration, moisture_reserve, inspiration_reserve)
    local n, reserve = 0, 0
    if moisture     then n = n + 1; if moisture_reserve     > reserve then reserve = moisture_reserve     end end
    if abigail      then n = n + 1; if moisture_reserve     > reserve then reserve = moisture_reserve     end end
    if inspiration  then n = n + 1; if inspiration_reserve  > reserve then reserve = inspiration_reserve  end end
    return (n > 2 and 2 or n), reserve
end

-- how many leading columns dodge the band, per backpack mode. Mode A (1, side pack) shifts everything
-- left, so a 1-badge band (cols<2) no longer overlaps -> 0; a wide band (cols>=2) still clips col 1 -> 1.
function M.dodge_cols(bpmode, second_row_cols)
    return (bpmode == 1) and ((second_row_cols >= 2) and 1 or 0) or second_row_cols
end

-- per-column top push + bottom keep-out. col < dodge -> top pushed down by reserve. col 0 reserves the
-- full Map(M)-button keep-out ONLY when not in Mode A (Mode A already shifted it off the button) ->
-- else the small free reserve.
function M.column_reserve(col, dodge, bpmode, vstarty, second_row_reserve, full_bottom, free_bottom)
    local top = (col < dodge) and (vstarty - second_row_reserve) or vstarty
    local bottom = (col == 0 and bpmode ~= 1) and full_bottom or free_bottom
    return top, bottom
end

return M
