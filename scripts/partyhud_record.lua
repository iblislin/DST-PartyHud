-- partyhud_record.lua
-- Pure record-normalization logic, extracted from modmain's UpdateBadges so it can be busted-tested
-- with zero engine deps (same pattern as partyhud_layout / partyhud_status / partyhud_crossshard /
-- partyhud_statuscodec / partyhud_badge). modmain reads the live netvars / foreign-record fields and
-- DELEGATES the clamp/default/rescale arithmetic here; it keeps ownership of the engine reads and of
-- feeding the returned values to the badge (SetPercent / SetStatus / SetSanityRate).
--
-- Two SEPARATE entry points -- one per render path -- because the local and foreign paths apply
-- DIFFERENT rules and unifying them would change behaviour. The most load-bearing divergence is
-- hunger-max: the LOCAL path defaults a missing/zero hunger-max to 100 then clamps it, whereas the
-- FOREIGN path HARD-CODES 100 (foreign records carry no hunger-max at all). This divergence is
-- intentional and pinned by a spec; do NOT "simplify" the two into one function.
local M = {}

-- normalize_local(raw) -> normalized table
-- `raw` is a plain table of the already-read local netvar values (modmain applied each netvar's own
-- read-time `or` default, e.g. hungermax defaults to 100, the penalties were already divided by 100).
-- This mirrors the local render path: clamp a non-positive hunger-max / sanity-max back up to 100
-- (a player with a transient 0/negative max would otherwise divide-by-zero the ring), then hand the
-- values straight through. The returned table's fields feed the badge call site verbatim.
--   raw fields  : hpcur, maxhp, hppenalty, hunger, hungermax, sanity, sanitymax, sanitypenalty,
--                 onfire, overheating, freezing, sanityrate, isdead
function M.normalize_local(raw)
  local hungermax = raw.hungermax
  if hungermax <= 0 then
    hungermax = 100
  end
  local sanitymax = raw.sanitymax
  if sanitymax <= 0 then
    sanitymax = 100
  end
  return {
    hpcur = raw.hpcur,
    maxhp = raw.maxhp,
    hppenalty = raw.hppenalty,
    hunger = raw.hunger,
    hungermax = hungermax,
    sanity = raw.sanity,
    sanitymax = sanitymax,
    sanitypenalty = raw.sanitypenalty,
    onfire = raw.onfire,
    overheating = raw.overheating,
    freezing = raw.freezing,
    sanityrate = raw.sanityrate,
    isdead = raw.isdead,
  }
end

-- normalize_foreign(rec, flags) -> normalized table
-- `rec` is a foreign (other-shard / out-of-view) status record (the codec record built server-side);
-- `flags` is the already-unpacked flag table (codec.unpackflags(rec.flags), carrying `dead`). This
-- mirrors the foreign render path:
--   * hunger-max is HARD-CODED to 100 -- foreign records carry only the current hunger value, no max,
--     so the ring is scaled against a sensible default (matches the local-path hungermax<=0 default).
--   * sanity-max guards a missing/non-positive relayed value back to 100.
--   * hp / sanity penalties are rescaled from the relayed 0..100 integer to the badge's 0..1 fraction.
--   * the live-only thermal flags (onfire / overheat / freeze) are FORCED false and the sanity rate
--     to 0 -- far data is ~1s stale, so a pulse/arrow from it would be misleading.
-- `flags` (not `rec.flags`) is the only place the dead state comes from; everything else is on `rec`.
function M.normalize_foreign(rec, flags)
  local sanitymax = (rec.sanity_max ~= nil and rec.sanity_max > 0) and rec.sanity_max or 100
  return {
    hpcur = rec.hp_cur or 0,
    maxhp = rec.hp_max,
    hppenalty = (rec.hp_penalty or 0) / 100,
    hunger = rec.hunger,
    hungermax = 100, -- hard 100: foreign records carry no hunger-max (see header)
    sanity = rec.sanity_cur,
    sanitymax = sanitymax,
    sanitypenalty = (rec.sanity_penalty or 0) / 100,
    -- live-only fields forced neutral for far players (~1s stale):
    onfire = false,
    overheating = false,
    freezing = false,
    sanityrate = 0,
    isdead = flags.dead,
  }
end

return M
