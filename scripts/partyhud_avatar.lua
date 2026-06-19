-- partyhud_avatar.lua
-- Pure avatar / name-colour decision logic, extracted so it can be busted-tested with zero engine
-- deps (same pattern as partyhud_badge / partyhud_layout / partyhud_record / partyhud_crossshard).
-- The widget + modmain read live engine state (entity prefab/colour/tags, or the GetClientTable
-- record fields) and DELEGATE the arithmetic here; they keep ownership of the engine calls
-- (SetTexture / GetPlayerBadgeData / SetSkinsOnAnim / SetColour).
--
-- Engine references (dst-scripts, verified 2026-06-19):
--   classify / atlas_and_tex mirror GetCharacterAvatarTextureLocation (characterutil.lua:72-90)
--   USERFLAGS bits          constants.lua:2381-2391 (IS_GHOST=1, CHARACTER_STATE_1=4, _2=8, _3=32)
--   DEFAULT_PLAYER_COLOUR   constants.lua:1765 = RGB(153,153,153) = {0.6,0.6,0.6} GREY
local M = {}

-- The base avatar atlas, always loaded by the game (SetTexture is synchronous, no mod Asset needed),
-- so even a far modded teammate whose mod the receiver lacks shows a generic head, never a crash.
M.DEFAULT_ATLAS = "images/avatars.xml"

-- table.contains without the engine global (zero-dep): is `needle` in array `t`?
local function contains(t, needle)
  if t == nil then
    return false
  end
  for _, v in ipairs(t) do
    if v == needle then
      return true
    end
  end
  return false
end

-- Classify a prefab into one of five buckets, mirroring characterutil.lua:75-88:
--   "base"          : a real DST character (in dst_charlist)
--   "random"        : the "random" pseudo-character (rendered like a real one)
--   "mod"           : a registered mod character (in mod_charlist) -> its own avatar atlas
--   "unknown_named" : a non-empty name that is NOT registered -> the generic avatar_mod.tex head
--   "unknown"       : nil or "" -> avatar_unknown.tex
function M.classify(prefab, dst_charlist, mod_charlist)
  if prefab == "random" or contains(dst_charlist, prefab) then
    return (prefab == "random") and "random" or "base"
  elseif contains(mod_charlist, prefab) then
    return "mod"
  elseif prefab ~= nil and prefab ~= "" then
    return "unknown_named"
  end
  return "unknown"
end

-- Resolve (atlas, tex) for a prefab + its classify bucket, mirroring characterutil.lua:73-89.
-- mod_avatar_locations is the engine's MOD_AVATAR_LOCATIONS map ({ [prefab]=dir, Default=dir });
-- only consulted for the "mod" bucket. nil-tolerant for the non-mod buckets.
function M.atlas_and_tex(prefab, classify_result, mod_avatar_locations)
  if classify_result == "mod" then
    local loc = (mod_avatar_locations ~= nil and (mod_avatar_locations[prefab] or mod_avatar_locations["Default"]))
      or ""
    return string.format("%savatar_%s.xml", loc, prefab), string.format("avatar_%s.tex", prefab)
  elseif classify_result == "unknown_named" then
    return M.DEFAULT_ATLAS, "avatar_mod.tex"
  elseif classify_result == "unknown" then
    return M.DEFAULT_ATLAS, "avatar_unknown.tex"
  end
  -- base / random
  return M.DEFAULT_ATLAS, string.format("avatar_%s.tex", prefab)
end

-- USERFLAGS bits we care about for the animated head (constants.lua:2381-2391). We intentionally
-- ignore IS_AFK(2) / IS_LOADING(16): they affect the scoreboard avatar bg/frame, not the head pose
-- PartyHud renders. Stored in a SEPARATE int from the codec status flags (no overlap, no wire use).
M.IDFLAG_GHOST = 1 -- USERFLAGS.IS_GHOST
M.IDFLAG_STATE1 = 4 -- USERFLAGS.CHARACTER_STATE_1
M.IDFLAG_STATE2 = 8 -- USERFLAGS.CHARACTER_STATE_2
M.IDFLAG_STATE3 = 32 -- USERFLAGS.CHARACTER_STATE_3

-- Lua 5.1 has no bit ops; do it with arithmetic. Each flag is a distinct power of two, so a plain
-- add (when present) packs them, and an integer divide + odd-test unpacks. Values stay well within
-- Lua 5.1's exact-integer float range.
local function has_bit(n, bit)
  return (math.floor(n / bit) % 2) == 1
end

-- Pack the animated-head identity bits into one int. `t` keys: ghost, state1, state2, state3 (bools).
-- nil table -> 0. Mirrors the existing codec packflags style.
function M.packidflags(t)
  if t == nil then
    return 0
  end
  local n = 0
  if t.ghost then
    n = n + M.IDFLAG_GHOST
  end
  if t.state1 then
    n = n + M.IDFLAG_STATE1
  end
  if t.state2 then
    n = n + M.IDFLAG_STATE2
  end
  if t.state3 then
    n = n + M.IDFLAG_STATE3
  end
  return n
end

-- Inverse of packidflags. Accepts a raw engine userflags int directly (extra bits like IS_AFK /
-- IS_LOADING are simply not tested), so the foreign path can feed GetClientTable().userflags in raw.
function M.unpackidflags(n)
  n = n or 0
  return {
    ghost = has_bit(n, M.IDFLAG_GHOST),
    state1 = has_bit(n, M.IDFLAG_STATE1),
    state2 = has_bit(n, M.IDFLAG_STATE2),
    state3 = has_bit(n, M.IDFLAG_STATE3),
  }
end

-- Cheap per-refresh change-gate for the badge's avatar rebuild. prev/new are { prefab, idflags }
-- snapshots; a base_skin field is also accepted (future-proofing) and compared with an "" coercion
-- so nil-vs-nil and nil-vs-"" read equal (a base char with no skin set). PartyHud does NOT track
-- per-teammate skins -- the widget snapshots only {prefab, idflags} and derives base_build as
-- prefab.."_none", so base_skin is always nil-vs-nil here (a no-op) and a base-build change only
-- happens on a prefab change, which IS compared. nil prev (first build) -> always changed.
function M.identity_changed(prev, new)
  if prev == nil then
    return true
  end
  return prev.prefab ~= new.prefab or prev.idflags ~= new.idflags or (prev.base_skin or "") ~= (new.base_skin or "")
end

-- Map the avatar_style config int to the internal style string. Anything unrecognised (nil, an out-of
-- range int, a wrong type, or any future-removed value) falls to "off" so the badge never tries to
-- render the dropped head-corner combo. Centred (flat) is intentionally NOT mapped here yet (deferred).
function M.resolve_avatar_style(config_value)
  if config_value == 1 then
    return "corner"
  elseif config_value == 2 then
    return "centre"
  end
  return "off"
end

-- Centre-avatar head fit. GetPlayerBadgeData (skinsutils.lua:1903) returns scale (~0.23) / y_offset
-- (~-50) TUNED FOR THE VANILLA SCOREBOARD avatar, where the head is nested under an icon scaled .8
-- (playerbadge.lua:16 `self.icon:SetScale(.8)`) inside the scoreboard frame. PartyHud draws the head
-- DIRECTLY on the smaller HP ring with NO .8 parent and a different frame, so the raw engine values
-- overflow the ring. AVATAR_HEAD_FIT shrinks both scale and y_offset proportionally to fit; the final
-- value is tuned IN-ENGINE (these are provisional defaults). AVATAR_HEAD_Y_NUDGE is an absolute,
-- unscaled y tweak applied after the proportional shrink, also tuned in-engine.
M.AVATAR_HEAD_FIT = 0.6
M.AVATAR_HEAD_Y_NUDGE = 0

-- Pure geometry for the centre animated head. Takes the engine's raw base_scale / base_y_offset from
-- GetPlayerBadgeData and returns the (scale, y_offset) PartyHud should actually apply to its smaller,
-- .8-parent-less ring. Formula:
--   scale    = base_scale    * fit
--   y_offset = base_y_offset * fit + y_nudge
-- `fit` falls back to M.AVATAR_HEAD_FIT, `y_nudge` to M.AVATAR_HEAD_Y_NUDGE when nil. nil base inputs
-- are treated as 0 so the widget can pass through whatever GetPlayerBadgeData yields without guarding.
function M.avatar_head_geom(base_scale, base_y_offset, fit, y_nudge)
  base_scale = base_scale or 0
  base_y_offset = base_y_offset or 0
  fit = fit or M.AVATAR_HEAD_FIT
  y_nudge = y_nudge or M.AVATAR_HEAD_Y_NUDGE
  return base_scale * fit, base_y_offset * fit + y_nudge
end

-- DEFAULT_PLAYER_COLOUR (constants.lua:1765) = RGB(153,153,153) = {0.6,0.6,0.6} GREY. Used when the
-- player colour is not yet known. Kept as a module constant so the widget + specs agree on it without
-- depending on the engine global.
M.GREY = { 0.6, 0.6, 0.6 }

-- Pure form of the widget's _apply_name_colour. Reconcile the player colour with the foreign dim:
--   * a real colour      -> {r,g,b, a*foreign_dim_or_1}        (hue preserved; only alpha dims)
--   * nil                -> GREY at the same alpha
--   * not-ready white     -> GREY (server assigns the join-order colour shortly after connect; until
--     then GetClientTable / playercolour reads pure white {1,1,1,1}, which would be illegible as a
--     "real" colour, so treat it as not-ready and fall to GREY -- mirrors playerlist.lua using
--     DEFAULT_PLAYER_COLOUR for the empty/not-ready case).
-- foreign_dim is the badge's FOREIGN_ALPHA (e.g. 0.45) for a far player, or pass 1 (or nil) for local.
function M.name_colour(playercolour, is_foreign, foreign_dim)
  local dim = is_foreign and (foreign_dim or 1) or 1
  local function is_not_ready(c)
    return c == nil or (c[1] == 1 and c[2] == 1 and c[3] == 1 and (c[4] == nil or c[4] == 1))
  end
  if is_not_ready(playercolour) then
    return { M.GREY[1], M.GREY[2], M.GREY[3], 1 * dim }
  end
  local a = playercolour[4] or 1
  return { playercolour[1], playercolour[2], playercolour[3], a * dim }
end

-- OPTIONAL: true only for the 3 low-luminance warm-palette colours (BROWN / VIOLETRED / DARKPLUM),
-- where the name text leans on its drop shadow for legibility. Pure luminance threshold (Rec.601-ish
-- weighting) so a contrast decision can be tested + wired without a palette table. Ship the widget use
-- only if an in-game contrast tweak actually lands; the math is here either way. nil colour -> false.
function M.is_low_contrast(playercolour)
  if playercolour == nil then
    return false
  end
  local lum = 0.299 * playercolour[1] + 0.587 * playercolour[2] + 0.114 * playercolour[3]
  return lum < 0.45
end

return M
