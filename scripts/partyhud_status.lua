-- partyhud_status.lua
-- Pure status-display decision logic, extracted from modmain so it can be busted-tested with zero
-- engine deps (same pattern as partyhud_statuscodec / partyhud_crossshard / partyhud_layout). modmain
-- reads the live component/tag values + the engine enums and delegates the decision here.
local M = {}

-- v2026.11 (extracted for test): the sanity rate arrow's RATE_SCALE, mirroring the game's brain-badge
-- logic (widgets/sanitybadge.lua OnUpdate). Pure -- the caller passes the engine-read inputs + the
-- RATE_SCALE enum:
--   is_sleeping : inst:HasTag("sleeping")
--   sleep_rate  : TUNING.SLEEP_SANITY_PER_TICK / TUNING.SLEEP_TICK_PERIOD (sanity gained per tick asleep)
--   raw_rs      : sanity:GetRateScale() (the game's current rate enum; it reads NEUTRAL while sleeping)
--   pct         : sanity:GetPercentWithPenalty() (0..1)
--   RS          : the RATE_SCALE enum table (NEUTRAL / INCREASE_HIGH|MED|LOW / DECREASE_HIGH|MED|LOW)
-- While sleeping GetRateScale() reads NEUTRAL, so we synthesize a rising level from the sleep gain rate
-- (the game shows a rising arrow when asleep). Awake we clamp: no rising arrow at full sanity, no
-- falling arrow at empty -- matching the vanilla badge.
function M.sanity_ratescale(is_sleeping, sleep_rate, raw_rs, pct, RS)
  if is_sleeping then
    if pct < 1 then
      return (sleep_rate > 0.2 and RS.INCREASE_HIGH)
        or (sleep_rate > 0.1 and RS.INCREASE_MED)
        or (sleep_rate > 0.01 and RS.INCREASE_LOW)
        or RS.NEUTRAL
    end
    return RS.NEUTRAL
  end
  if raw_rs == RS.INCREASE_HIGH or raw_rs == RS.INCREASE_MED or raw_rs == RS.INCREASE_LOW then
    return (pct < 1) and raw_rs or RS.NEUTRAL
  elseif raw_rs == RS.DECREASE_HIGH or raw_rs == RS.DECREASE_MED or raw_rs == RS.DECREASE_LOW then
    return (pct > 0) and raw_rs or RS.NEUTRAL
  end
  return RS.NEUTRAL
end

-- Temperature danger-band + fast-rate popup. current/rate from the broadcast (rate sign: <0 cooling,
-- >0 warming). Show when at/over a danger threshold OR changing fast toward an extreme.
-- THRESHOLDS ARE FIXED CONSTANTS: per dst-scripts (components/temperature.lua) freeze is hardcoded
-- current<0 and overheat is current>70 (TUNING.OVERHEAT_TEMP), universal across all characters as of
-- 2026-06. If a future DST update makes the threshold character-specific, switch cold_show/hot_show to
-- be derived from each player's broadcast temperature.overheattemp instead of these constants.
M.TEMP_COLD_SHOW = 10
M.TEMP_HOT_SHOW = 60
M.TEMP_RATE_FAST = 1

function M.temp_popup(current, rate, cold_show, hot_show, rate_fast)
  if current == nil then
    return false, nil
  end
  cold_show = cold_show or M.TEMP_COLD_SHOW
  hot_show = hot_show or M.TEMP_HOT_SHOW
  rate_fast = rate_fast or M.TEMP_RATE_FAST
  rate = rate or 0
  if current <= cold_show or (rate <= -rate_fast) then
    return true, "cold"
  elseif current >= hot_show or (rate >= rate_fast) then
    return true, "hot"
  end
  return false, nil
end

-- Moisture popup: show the moisture sub-ring only when the teammate is wet at all (mirrors vanilla
-- moisturemeter, which hides at moisture 0). nil -> dry.
function M.moisture_popup(moisture)
  return (moisture or 0) > 0
end

return M
