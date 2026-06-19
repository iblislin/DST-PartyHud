-- spec/support/layout_capture.lua
--
-- Turns an `opts` table into a DETERMINISTIC layout snapshot. `M.capture(opts)` runs the pure
-- `compute_badge_positions` and returns a canonical array (one entry per slot, sorted by index,
-- each carrying exactly { index, x, y, col, row }). `M.to_json(opts)` serializes that snapshot
-- via the canonical JSON encoder (sorted keys, rounded floats) so goldens diff byte-for-byte.
--
-- Logical-offscreen model: the captured x/y are badge-LOCAL computed coordinates straight out of
-- the layout math -- NOT engine pixels. That is the whole point: it pins the position MODEL so
-- layout tuning regressions surface as a deterministic JSON diff.

local layout = require("partyhud_layout")
local json = require("support.json")

local M = {}

-- M.capture(opts) -> array sorted by index; each entry = { index, x, y, col, row }.
-- compute_badge_positions already returns slots 1..badge_count in index order, but we rebuild
-- each entry with an explicit field set (and copy in index order) so the snapshot is minimal
-- and never carries any incidental extra fields a future layout change might tack on.
function M.capture(opts)
  local raw = layout.compute_badge_positions(opts)
  local snapshot = {}
  for i = 1, #raw do
    local e = raw[i]
    snapshot[i] = {
      index = e.index,
      x = e.x,
      y = e.y,
      col = e.col,
      row = e.row,
    }
  end
  return snapshot
end

-- M.to_json(opts) -> canonical JSON string (2dp floats, sorted keys).
function M.to_json(opts)
  return json.encode(M.capture(opts), { float_dp = 2 })
end

return M
