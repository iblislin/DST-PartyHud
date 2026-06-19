-- partyhud_badge.lua
-- Pure badge colour / predicate math, extracted from widgets/partybadge.lua so it can be
-- busted-tested with zero engine deps (same pattern as partyhud_layout / partyhud_status /
-- partyhud_crossshard / partyhud_statuscodec). The widget reads its live state (self.foreign,
-- self.low_hp, self._blink_t and the SetPercent cur/max/threshold) and DELEGATES the arithmetic
-- here; it keeps ownership of the engine calls (SetMultColour / SetPercent / Show / Hide).
local M = {}

-- v2026.8: dim alpha applied to a badge when the slot shows a FOREIGN (other-shard / far) player,
-- so it reads as "muted / data is ~1s stale". FULL_ALPHA is the local-player baseline. Only alpha
-- drops in the dim path; hue is preserved by re-asserting each element's base RGB at the call site.
M.FOREIGN_ALPHA = 0.45
M.FULL_ALPHA = 1

-- v2026.9 low-HP alert: the alarm-red ring-border tint, brighter than the HP fill {174,21,21}/255 so
-- it pops against the red ring underneath. LOW_HP_PULSE_SECS is one full breathe cycle
-- (rest -> alarm -> rest); LOW_HP_PULSE_W is the matching angular speed for the sine pulse.
M.LOW_HP_TINT = { 1, 0.15, 0.15 }
M.LOW_HP_PULSE_SECS = 1.2
M.LOW_HP_PULSE_W = (2 * math.pi) / M.LOW_HP_PULSE_SECS

-- local reimplementation of the engine's Lerp (mathutil.lua): a + (b - a) * t. Kept here so the
-- module has ZERO engine deps -- the widget's _apply_frame_colour used the GLOBAL Lerp before.
local function lerp(a, b, t)
  return a + (b - a) * t
end

-- v2026.9: the ring-border (circleframe) colour, as r, g, b, a. Single source of truth so the
-- low-HP blink and the foreign-dim can't desync. Inputs are the widget's live state:
--   low_hp  : whether the low-HP breathe is active
--   foreign : whether this slot shows a far / other-shard player (drops the baseline alpha)
--   blink_t : the OnUpdate-advanced pulse phase accumulator (seconds)
-- Baseline border = white at the badge's current alpha (dimmed if foreign). While low, a sine on
-- blink_t gives k in 0..1; each RGB channel lerps white -> LOW_HP_TINT and alpha lerps baseline -> 1
-- so the alert stays visible even on a dimmed far badge.
function M.frame_colour(low_hp, foreign, blink_t)
  local base_a = foreign and M.FOREIGN_ALPHA or M.FULL_ALPHA
  if low_hp then
    local k = 0.5 + 0.5 * math.sin(blink_t * M.LOW_HP_PULSE_W)
    return lerp(1, M.LOW_HP_TINT[1], k), lerp(1, M.LOW_HP_TINT[2], k), lerp(1, M.LOW_HP_TINT[3], k), lerp(base_a, 1, k)
  end
  return 1, 1, 1, base_a
end

-- v2026.9: the low-HP-alert predicate from SetPercent. threshold is a fraction of max HP (0..1),
-- 0 (or any <= 0) disables the alert. cur nil -> 0; max nil or <= 0 -> coerced to 1 (matching the
-- SetPercent normalization, so the ring fill and this compare see the same denominator). Returns
-- true only when threshold > 0 and the strict ratio (cur/max) < threshold (equality is NOT low).
function M.is_low_hp(cur, max, threshold)
  if threshold == nil or threshold <= 0 then
    return false
  end
  cur = cur or 0
  local m = (max ~= nil and max > 0) and max or 1
  return (cur / m) < threshold
end

-- v2026.11: the intended badge child-draw order, BACK to FRONT, for a given avatar style. This captures
-- the INTENT that the live widget enforces (the widget tree itself is verified in-engine, not here):
--   "centre" -> { "ring_art", "avatar_head", "hp_number" }: the centre style adds an animated head over
--     the ring, which (being AddChild'd after the Badge base created self.num) would otherwise draw over
--     the HP number. The widget restores number-on-top via self.num:MoveToFront() right after showing the
--     head, so the number is ALWAYS the front-most element.
--   any other style ("corner", "off", nil) -> { "ring_art", "hp_number" }: no centre head in the stack
--     (corner uses a separate top-left inset, off has none), so the number simply sits over the ring.
-- The hp_number is the LAST (front) element in every case -- the property the centre z-order bug violated.
function M.layer_order(style)
  if style == "centre" then
    return { "ring_art", "avatar_head", "hp_number" }
  end
  return { "ring_art", "hp_number" }
end

return M
