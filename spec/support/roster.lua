-- spec/support/roster.lua
--
-- Scenario builder for the layout-snapshot suite. `M.scenario(overrides)` returns a COMPLETE,
-- self-contained `opts` table ready for `partyhud_layout.compute_badge_positions`, with the
-- canonical defaults baked in (so a scenario in the spec matrix is a one-liner of just the
-- overrides that matter, e.g. `roster.scenario{ badge_count = 10, bpmode = 1 }`).
--
-- The defaults mirror modmain's live values:
--   * vertical layout (layout_mode = 2), Standard/no-minimap position (position_mode = 2,
--     which anchors on vert_x/vert_y rather than the phud anchor),
--   * 4 badges, sub-rings shown, 1920x1080 @ hudscale 1, no backpack, no second-row band,
--   * the VERT_* / BACKPACK_* / horizontal-step constants from modmain ~lines 61-83.
-- phud_xpos / phud_ypos default to the no-minimap (positional == 2) preset (-100, 120) from
-- modmain ~lines 193-202; they only feed the horizontal row and the Minimap/XL vertical anchor.

local M = {}

-- The canonical default opts. A fresh copy is produced on every call so callers can never
-- mutate the shared defaults through their returned table.
local function defaults()
  return {
    -- layout / position selectors
    layout_mode = 2, -- 2 = vertical column-wrap
    position_mode = 2, -- 2 = Standard / no-minimap (anchors on vert_x/vert_y)
    phud_xpos = -100, -- no-minimap (positional == 2) preset; horizontal + Minimap/XL anchor
    phud_ypos = 120,
    -- roster / display
    badge_count = 4,
    show_substatus = true,
    -- live engine geometry
    screen_w = 1920,
    screen_h = 1080,
    hudscale = 1,
    -- backpack + second-row dodge
    bpmode = 0,
    second_row_cols = 0,
    second_row_reserve = 0,
    -- layout constants (modmain SoT values)
    vert_x = 0,
    vert_y = -130,
    vert_gap = -120,
    vert_gap_compact = -90,
    vert_col_w = 80,
    vert_bottom_reserve = 65,
    vert_bottom_reserve_free = 40,
    backpack_shift_x = 100,
    backpack_bottom_extra = 20,
    horizontal_step = -70,
  }
end

-- M.scenario(overrides) -> opts table (defaults merged with a shallow copy of `overrides`).
function M.scenario(overrides)
  local o = defaults()
  if overrides then
    for k, v in pairs(overrides) do
      o[k] = v
    end
  end
  return o
end

return M
