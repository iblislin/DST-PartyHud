-- partyhud_layout.lua
-- Pure layout / dodge math, extracted from modmain so it can be busted-tested with zero engine deps
-- (same pattern as partyhud_statuscodec / partyhud_crossshard). modmain reads the live engine values
-- (screen size, HUD scale, widget presence, backpack mode) and delegates the arithmetic here.
local M = {}

M.STATUS_SCALE = 1.4 -- statusdisplays default scale (controls.lua:155)
M.REF_W, M.REF_H = 1280, 720 -- RESOLUTION_X / RESOLUTION_Y reference
M.MAX_PROP = 1.25 -- MAX_HUD_SCALE upscale cap
M.BADGE_BOTTOM = 60 -- a badge's sub-ring bottom, below its origin
M.PERCOL_FALLBACK = 6 -- safe per-column count if screen/HUD scale is unreadable

-- Real vanilla widget tree (non-splitscreen, controls.lua verified):
--   Widget("side")  [SCALEMODE_PROPORTIONAL]
--   └── tr_scale_root ("tr_scale_root")  [SetScale(hudscale) in SetHUDSize; = self.topright_root]
--       └── sidepanel ("sidepanel")  [vanilla pos=(-80,-60,0); CS moves to (-100,-70,0)]
--           └── StatusDisplays  [pos=(0,-110,0), no SetScale → local scale=1]
--               └── our badge
-- CS makes TWO changes (Combined-Status/modmain.lua verified):
--   1. self.topright_root:SetScale(GetHUDScale() * HUDSCALEFACTOR)  → cs_factor = HUDSCALEFACTOR
--   2. self.sidepanel:SetPosition(-100, -70)                        → sidepanel moves left by 20
-- cs_factor = tr_scale_root UITransform:GetScale() / GetHUDScale() = HUDSCALEFACTOR.
-- cs_sp_x   = live sidepanel UITransform:GetLocalPosition().x  (= -80 vanilla, -100 with CS).
-- Widget("side") carries a SCALEMODE_PROPORTIONAL engine scale; use UITransform:GetScale() (local)
-- not Widget:GetScale() (compound) on tr_scale_root to avoid absorbing it into cs_factor.
M.CS_SIDEPANEL_X = -80 -- sidepanel local X vanilla (controls.lua:135 SetPosition(-80,-60,0))

-- Re-anchor the vertical column's start-x for the two Combined Status changes.
-- Invariance: factor * (cs_sp_x + comp_vstartx) = CS_SIDEPANEL_X + vstartx (vanilla screen pos)
-- → comp_vstartx = (CS_SIDEPANEL_X + vstartx) / factor - cs_sp_x
-- cs_sp_x nil → defaults to CS_SIDEPANEL_X (vanilla sidepanel pos → no position delta).
-- factor nil / <= 0 → no compensation. fudge scales the entire correction (1 = full).
-- NOTE: topright_root rescale also drifts Y; that compensation is DEFERRED.
function M.cs_compensated_vstartx(vstartx, factor, cs_sp_x, fudge)
  if factor == nil or factor <= 0 then
    return vstartx
  end
  local eff_sp_x = cs_sp_x ~= nil and cs_sp_x or M.CS_SIDEPANEL_X
  -- no change needed: vanilla scale + vanilla sidepanel position
  if factor == 1 and eff_sp_x == M.CS_SIDEPANEL_X then
    return vstartx
  end
  local target = (M.CS_SIDEPANEL_X + vstartx) / factor - eff_sp_x
  return vstartx + (target - vstartx) * (fudge or 1)
end

-- badges that fit in one column given screen geometry. >= 1 (or PERCOL_FALLBACK if screen/scale
-- unreadable). vgap is the NEGATIVE row gap (rows go down); bottom_reserve is the bottom keep-out.
-- Dividing by `prop` is the v2026.8 proportional-scale fix: a sub-720 window shrinks the real badges,
-- so `usable` (screen height in badge-local units) must track it or the column collapses to 1 badge.
function M.percol_count(scrnw, scrnh, hudscale, vy, bottom_reserve, vgap)
  if scrnh == nil or scrnh <= 0 or scrnw == nil or scrnw <= 0 or hudscale == nil or hudscale <= 0 then
    return M.PERCOL_FALLBACK
  end
  local prop = math.min(scrnw / M.REF_W, scrnh / M.REF_H)
  if prop > M.MAX_PROP then
    prop = M.MAX_PROP
  end
  if prop <= 0 then
    prop = 1
  end
  local usable = scrnh / (hudscale * M.STATUS_SCALE * prop)
  local rowpitch = -vgap
  local n = math.floor((vy - M.BADGE_BOTTOM + usable - bottom_reserve) / rowpitch) + 1
  if n < 1 then
    n = 1
  end
  return n
end

-- how many leading columns the top-right status second-row band spans (0/1/2) + how far down to push
-- them (= the deepest active badge's reserve). moisture/abigail/inspiration are booleans.
function M.second_row_span(moisture, abigail, inspiration, moisture_reserve, inspiration_reserve)
  local n, reserve = 0, 0
  if moisture then
    n = n + 1
    if moisture_reserve > reserve then
      reserve = moisture_reserve
    end
  end
  if abigail then
    n = n + 1
    if moisture_reserve > reserve then
      reserve = moisture_reserve
    end
  end
  if inspiration then
    n = n + 1
    if inspiration_reserve > reserve then
      reserve = inspiration_reserve
    end
  end
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

-- M.compute_badge_positions(opts) -> array of { index, x, y, col, row } for slots 1..badge_count.
--
-- PURE extraction of modmain's layout_badges position math (behaviour-neutral): reproduces the exact
-- horizontal-row formula AND the vertical column-wrap/dodge/reserve loop, but instead of calling
-- :SetPosition on widgets it RETURNS the (x, y, col, row) each slot would have been placed at. modmain
-- does the engine reads (screen size, HUD scale, backpack mode, second-row band, position/layout config)
-- and passes them all in via opts; this module stays engine-free (bare globals only -> busted-testable).
--
-- opts fields (the caller supplies the current live/config values -- NOTHING is hardcoded here):
--   layout_mode        number  the `layout` config: 2 = vertical (column wrap); anything else = horizontal row.
--   position_mode      number  the `position` config (`positional` in modmain): 0 = standard+minimap,
--                              1 = XL minimap (both reuse phud_xpos/phud_ypos as the vertical anchor),
--                              2 = no-minimap (uses VERT_X/VERT_Y as the anchor).
--   phud_xpos          number  horizontal anchor used by the horizontal row AND by the vertical anchor
--                              when position_mode is 0 or 1.
--   phud_ypos          number  vertical anchor (same dual use as phud_xpos).
--   badge_count        number  how many badge slots to place (== #badgearray).
--   show_substatus     bool    sub-rings visible? selects the vertical row gap (VERT_GAP vs VERT_GAP_COMPACT).
--   screen_w,screen_h  number  live screen size (passed straight to percol_count; nil/<=0 -> fallback).
--   hudscale           number  live HUD scale (ditto).
--   bpmode             number  backpack UI mode 0/1/2 (1 shifts all columns left + frees col 0's bottom;
--                              2 adds backpack_bottom_extra to the columns-2+ bottom reserve).
--   second_row_cols    number  how many leading columns the top-right status band spans (0/1/2).
--   second_row_reserve number  how far down to push those dodged columns' top.
--   -- layout constants (caller passes modmain's current values; NOT hardcoded so they stay the SoT):
--   vert_x, vert_y             number  standard (no-minimap) vertical anchor (VERT_X / VERT_Y).
--   vert_gap, vert_gap_compact number  vertical row gaps (negative; VERT_GAP / VERT_GAP_COMPACT).
--   vert_col_w                 number  horizontal spacing per wrapped column (VERT_COL_W).
--   vert_bottom_reserve        number  col-0 full Map(M)-button bottom keep-out (VERT_BOTTOM_RESERVE).
--   vert_bottom_reserve_free   number  columns-2+ bottom keep-out (VERT_BOTTOM_RESERVE_FREE).
--   backpack_shift_x           number  left shift applied to all columns in Mode A (BACKPACK_SHIFT_X).
--   backpack_bottom_extra      number  extra columns-2+ bottom in Mode B (BACKPACK_BOTTOM_EXTRA).
--   horizontal_step            number  per-badge x step in the horizontal row (modmain's literal -70).
function M.compute_badge_positions(opts)
  local out = {}
  local n = opts.badge_count
  if n == nil or n <= 0 then
    return out
  end

  if opts.layout_mode ~= 2 then
    -- horizontal row: x = phud_xpos + (horizontal_step * i), y = phud_ypos, for i = 1..n. No real
    -- column/row structure here -> report col 0, row i-1 so every slot still carries a col/row field.
    for i = 1, n do
      out[i] = {
        index = i,
        x = opts.phud_xpos + (opts.horizontal_step * i),
        y = opts.phud_ypos,
        col = 0,
        row = i - 1,
      }
    end
    return out
  end

  -- vertical: Minimap/XL reuse the phud anchor; Standard uses vert_x/vert_y. Stack down by vgap,
  -- wrapping to a new column to the LEFT every per-col badges (right-anchored list -> grow leftward).
  local vstartx, vstarty = opts.vert_x, opts.vert_y
  if opts.position_mode == 0 or opts.position_mode == 1 then
    vstartx, vstarty = opts.phud_xpos, opts.phud_ypos
  end
  local vgap = opts.show_substatus and opts.vert_gap or opts.vert_gap_compact
  local bpmode = opts.bpmode
  -- mod-aware re-anchor (CS rescales tr_scale_root AND repositions sidepanel); no-op when cs_factor nil.
  -- cs_vstartx_override: CS heart-relative alignment (beats the analytical formula when set).
  -- EXCEPTION: Mode A (bpmode==1) skips the CS override — the backpack shift goal is an absolute
  -- screen position (clear the floating backpack container) that is independent of CS's X alignment.
  -- Applying cs_vstartx_override (heart_x=40) then shifting left by backpack_shift_x=100 gives -60
  -- instead of the vanilla -100, leaving badges under the backpack. Use vanilla vert_x in Mode A so
  -- the shift produces the same result as without CS.
  if bpmode ~= 1 and opts.cs_vstartx_override ~= nil then
    vstartx = opts.cs_vstartx_override
  elseif bpmode ~= 1 and opts.cs_factor ~= nil then
    vstartx = M.cs_compensated_vstartx(vstartx, opts.cs_factor, opts.cs_sp_x, opts.cs_fudge)
  end
  if bpmode == 1 then
    vstartx = vstartx - opts.backpack_shift_x
  end
  local free = opts.vert_bottom_reserve_free + ((bpmode == 2) and opts.backpack_bottom_extra or 0)
  local dodge = M.dodge_cols(bpmode, opts.second_row_cols)

  -- Fill top-to-bottom, wrapping LEFTWARD. percol_count always returns >= 1 so col advances and i grows
  -- each pass; `col <= n` is the same belt-and-suspenders bound modmain's loop carries.
  local i, col = 1, 0
  while i <= n and col <= n do
    local top, bottom =
      M.column_reserve(col, dodge, bpmode, vstarty, opts.second_row_reserve, opts.vert_bottom_reserve, free)
    -- compute_percol in modmain reads the live screen geometry then delegates to percol_count with the
    -- SAME vgap as the layout loop; here we call percol_count directly with the passed-in geometry.
    local cap = M.percol_count(opts.screen_w, opts.screen_h, opts.hudscale, top, bottom, vgap)
    for row = 0, cap - 1 do
      if i > n then
        break
      end
      out[i] = {
        index = i,
        x = vstartx - opts.vert_col_w * col,
        y = top + vgap * row,
        col = col,
        row = row,
      }
      i = i + 1
    end
    col = col + 1
  end
  return out
end

return M
