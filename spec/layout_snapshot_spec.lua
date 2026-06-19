-- spec/layout_snapshot_spec.lua
--
-- LAYOUT SNAPSHOT (golden) regression guard for compute_badge_positions. Each scenario captures
-- the COMPUTED position model (index/x/y/col/row per slot) to a deterministic golden JSON under
-- spec/snapshots/<name>.json and diffs the freshly-computed JSON against it byte-for-byte.
--
-- Logical-offscreen, NOT pixels: the captured x/y are badge-local layout-math coordinates. This is
-- the FAST regression guard for layout tuning -- tweak a VERT_* constant or the wrap math and any
-- scenario whose computed positions shifted fails loudly, with the scenario name in the message.
--
-- Workflow:
--   * Regenerate goldens (first run / after an intentional layout change you've reviewed):
--       UPDATE_SNAPSHOTS=1 luajit spec/run_local.lua
--     writes spec/snapshots/<name>.json for every scenario and passes.
--   * Normal run (diff mode): luajit spec/run_local.lua
--     reads each golden; a missing golden FAILS with a hint to run with UPDATE_SNAPSHOTS=1; a present
--     golden must byte-match the freshly-captured JSON or the scenario fails.

local roster = require("support.roster")
local capture = require("support.layout_capture")

-- ---- scenario matrix -------------------------------------------------------
-- Each entry: { name = <filename-safe stable id>, opts = roster.scenario{...} }.
-- The name doubles as the golden filename (spec/snapshots/<name>.json), so keep it stable.
local SCENARIOS = {
  -- vertical standard, varying roster size to exercise the column-wrap thresholds at 1920x1080.
  { name = "vertical_01", opts = roster.scenario({ badge_count = 1 }) },
  { name = "vertical_02", opts = roster.scenario({ badge_count = 2 }) },
  { name = "vertical_04", opts = roster.scenario({ badge_count = 4 }) },
  { name = "vertical_08", opts = roster.scenario({ badge_count = 8 }) },
  { name = "vertical_10", opts = roster.scenario({ badge_count = 10 }) },

  -- horizontal layout: single row, x = phud_xpos + step*i, y = phud_ypos.
  { name = "horizontal", opts = roster.scenario({ layout_mode = 1, badge_count = 8 }) },

  -- backpack modes at a full 10-badge roster.
  -- Mode A (1): side pack -> all columns shift LEFT by backpack_shift_x, col 0 bottom freed.
  { name = "backpack_mode_a_10", opts = roster.scenario({ badge_count = 10, bpmode = 1 }) },
  -- Mode B (2): integrated pack -> columns-2+ bottom reserve grows by backpack_bottom_extra.
  { name = "backpack_mode_b_10", opts = roster.scenario({ badge_count = 10, bpmode = 2 }) },

  -- second-row dodge band at 10 badges: leading column(s) pushed DOWN to clear the top-right band.
  {
    name = "second_row_1col_10",
    opts = roster.scenario({ badge_count = 10, second_row_cols = 1, second_row_reserve = 75 }),
  },
  {
    name = "second_row_2col_10",
    opts = roster.scenario({ badge_count = 10, second_row_cols = 2, second_row_reserve = 90 }),
  },

  -- position modes that anchor on the phud preset instead of vert_x/vert_y.
  -- Minimap (0): preset (-100, -70). XL minimap (1): preset (-650, 50).
  {
    name = "position_minimap_10",
    opts = roster.scenario({ badge_count = 10, position_mode = 0, phud_xpos = -100, phud_ypos = -70 }),
  },
  {
    name = "position_xl_10",
    opts = roster.scenario({ badge_count = 10, position_mode = 1, phud_xpos = -650, phud_ypos = 50 }),
  },

  -- HP-only (no sub-rings) uses the tighter compact vgap -> packs more per column.
  { name = "compact_gap_08", opts = roster.scenario({ badge_count = 8, show_substatus = false }) },

  -- small screen + large HUD scale: shrinks usable height -> columns wrap sooner (column growth).
  {
    name = "small_screen_hudscale_10",
    opts = roster.scenario({ badge_count = 10, screen_h = 720, screen_w = 1280, hudscale = 1.5 }),
  },
}

-- ---- golden file helpers ---------------------------------------------------
local SNAP_DIR = "spec/snapshots"

local function golden_path(name)
  return SNAP_DIR .. "/" .. name .. ".json"
end

-- Truthy if UPDATE_SNAPSHOTS is set to anything non-empty (so `UPDATE_SNAPSHOTS=1` / `=true` work).
local function update_mode()
  local v = os.getenv("UPDATE_SNAPSHOTS")
  return v ~= nil and v ~= ""
end

local function read_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local data = fh:read("*a")
  fh:close()
  return data
end

-- Write to spec/snapshots/<name>.json, creating the dir first (idempotent; `mkdir -p` swallows
-- "already exists"). LuaJIT has no portable mkdir, so shell out -- this path only runs under
-- UPDATE_SNAPSHOTS, never in the normal diff-mode CI run.
local function write_golden(path, data)
  os.execute("mkdir -p " .. SNAP_DIR)
  local fh = assert(io.open(path, "wb"), "cannot open golden for write: " .. path)
  fh:write(data)
  fh:close()
end

-- ---- the spec --------------------------------------------------------------
describe("layout snapshot", function()
  for _, sc in ipairs(SCENARIOS) do
    it(sc.name, function()
      local fresh = capture.to_json(sc.opts)
      local path = golden_path(sc.name)

      if update_mode() then
        write_golden(path, fresh)
        -- pass: golden (re)written for this scenario.
        assert.is_true(true)
        return
      end

      local golden = read_file(path)
      assert(
        golden ~= nil,
        "missing golden for scenario '"
          .. sc.name
          .. "' ("
          .. path
          .. "); "
          .. "run with UPDATE_SNAPSHOTS=1 to (re)generate"
      )
      assert(
        fresh == golden,
        "layout snapshot diverged for scenario '"
          .. sc.name
          .. "' ("
          .. path
          .. "); "
          .. "review the position change, then re-run with UPDATE_SNAPSHOTS=1 to bless it"
      )
    end)
  end
end)
