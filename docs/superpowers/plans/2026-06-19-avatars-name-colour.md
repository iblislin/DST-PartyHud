# Character Avatars + Name Colouring Implementation Plan

For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to dispatch and verify each task. Steps use checkbox (- [ ]) syntax; check each off as you complete it. Every task ends green (luacheck 0/0 + stylua --check + busted) before its commit.

**Goal:** Give each teammate badge per-player identity — the character's avatar in the badge and the
teammate's name in their own player colour — driven entirely client-side. Cross-shard identity rides the
existing cluster-wide `TheNet:GetClientTable()` channel, so there is **ZERO wire-protocol change** (no
codec bump, no new netvar/RPC/store). Ships as **v2026.11** alongside the separate crash-guard plan.

**Architecture:** Same split as every prior version — pure decision logic in an engine-free
`scripts/partyhud_avatar.lua` module (busted-tested), the widget (`scripts/widgets/partybadge.lua`) owning
the engine calls and delegating arithmetic, and `modmain.lua` reading live engine state + wiring config.
The new identity data is joined by `userid` in `UpdateBadges`: a LOCAL teammate reads its entity
(`v.prefab`, `v.playercolour`, tags); a FOREIGN teammate reads three tables built from `GetClientTable()`
(`prefabbyuserid` / `colourbyuserid` / `userflagsbyuserid`) the same way `namebyuserid` is already built.
Two new single-writer widget methods — `SetAvatar` (avatar render for the active style) and
`_apply_name_colour` (reconciles player-colour × foreign-dim) — mirror the existing `_apply_frame_colour`
single-writer pattern so the name colour and the foreign dim can never desync.

**Tech Stack:** Lua 5.1 (DST). StyLua 2-space indent (`.stylua.toml`; CI `stylua --check` is blocking).
luacheck `std=lua51` (`.luacheckrc`; CI must be 0 warnings / 0 errors). busted specs in `spec/*_spec.lua`,
run locally via the no-luarocks shim `luajit spec/run_local.lua` (CI uses real busted). `modmain.lua` runs
in a RESTRICTED sandbox (only `pairs/ipairs/print/math/table/type/string/tostring/require` whitelisted) so
any other global MUST be `GLOBAL.<fn>` (`tonumber`/`pcall`/`unpack`/`checkbit`/etc.) — and a module used in
an early closure (`UpdateBadges`) MUST be forward-required at the TOP of modmain as an upvalue (the prod
crash lesson). Engine API facts verified against `/home/iblis/code/dst/dst-scripts/scripts`:

- `GetCharacterAvatarTextureLocation(character)` → `(atlas, "avatar_<char>.tex")` with mod/unknown
  fallback — `characterutil.lua:72-90`.
- `GetPlayerBadgeData(character, ghost, state_1, state_2, state_3)` → `bank, anim, skin_mode, scale,
  y_offset` — `skinsutils.lua:1903-1947`.
- `SetSkinsOnAnim(anim_state, prefab, base_skin, clothing_names, monkey_curse, skintype, default_build)` —
  **`components/skinner.lua:11`** (a GLOBAL, not on skinsutils).
- `USERFLAGS = { IS_GHOST=1, IS_AFK=2, CHARACTER_STATE_1=4, CHARACTER_STATE_2=8, IS_LOADING=16,
  CHARACTER_STATE_3=32 }` — `constants.lua:2381-2391`.
- `GetClientTable()` records carry `userid`, `prefab`, `colour`, `userflags`, `name`, `base_skin` —
  confirmed in `widgets/redux/playerlist.lua:71-102` (`v.colour or DEFAULT_PLAYER_COLOUR`, `v.userflags or
  0`, `GetCharacterPrefab(v)` reads `v.prefab`).
- `DEFAULT_PLAYER_COLOUR = RGB(153, 153, 153)` = GREY = `{0.6, 0.6, 0.6}` (153/255 = 0.6) —
  `constants.lua:1765`. The not-ready/nil colour falls back to this, NOT white.
- The vanilla name-colour idiom: `self.name:SetColour(unpack(not empty and v.colour or
  DEFAULT_PLAYER_COLOUR))` — `playerlist.lua:156`.

> **All absolute modmain.lua line numbers in this plan assume a PRE-crash-guard tree.** The crash-guard
> plan lands FIRST and inserts top-of-file upvalue blocks (the `guarded()` helper + the Q5 staleness
> heartbeat consts), which shift every anchor below them by ~+40 lines. Before executing any modmain task
> here, re-grep the live anchors and trust the grep, not the printed line numbers.

**Sequencing vs the crash-guard plan (shared working tree):** this plan touches modmain.lua only in:
(a) the **forward-require block** near the top (~lines 93-112) — ADD one new `require("partyhud_avatar")`
upvalue; (b) the **config-read block** (~lines 45-55) — ADD two `GetModConfigData` reads; (c) the badge
construct loop in `onstatusdisplaysconstruct` (~lines 339-344) — ADD per-badge config application;
(d) the **`UpdateBadges` closure** local + foreign render blocks (~lines 433-630) — ADD identity-join +
`SetAvatar`/`_apply_name_colour` calls; (e) ONE new console fn `GLOBAL.PartyHud_AvatarStyle` added beside
the existing `GLOBAL.PartyHud_Layout` (~lines 312-333). The crash-guard plan wraps server-side runtime
**callbacks** (`onhealthdelta`/`onhungerdelta`/the periodic send task, ~lines 639-1040), and additionally
adds a Q5 **freshness clause** to the foreign-append guard at **line 538**
(`if show_crossshard and not DEBUG_SHOWALL and next_slot <= maxbadges then`).

**The concrete collision is in `UpdateBadges`:** the crash-guard plan adds a `foreign_fresh` clause to the
**line-538** `if`, and THIS plan hoists the `namebyuserid` build out of **lines 540-548** (which sit INSIDE
that same `if`) to the top of `UpdateBadges` (Task 8 step 5) and deletes the inner duplicate. Both plans
therefore edit the line-538 region. **Crash-guard lands FIRST** (mechanical wrapping + additive upvalues,
smaller diff). When THIS plan then edits the foreign-append guard, it **MUST PRESERVE the `foreign_fresh`
clause** crash-guard added to line 538 — do not revert it back to the bare
`if show_crossshard and not DEBUG_SHOWALL and next_slot <= maxbadges then`; keep the
`and foreign_fresh` term and only hoist the `namebyuserid` build out of 540-548. Whichever lands second
re-bases over the other with a follow-up merge commit (never rebase). partybadge.lua, partyhud_avatar.lua,
avatar_spec.lua, and modinfo.lua are exclusive to THIS plan.

---

## File Structure

**Create:**
- `scripts/partyhud_avatar.lua` — pure avatar/name-colour decision logic (engine-free).
- `spec/avatar_spec.lua` — busted specs for `partyhud_avatar`.

**Modify:**
- `scripts/widgets/partybadge.lua` — add `SetAvatar` + `_apply_name_colour`; route `SetForeign`/`SetName`
  through `_apply_name_colour`; replace the hard `self.name:SetColour(1,1,1,a)` at ~line 376.
- `modmain.lua` — forward-require `partyhud_avatar`; read `avatar_style`/`name_colour` config; build
  `prefabbyuserid`/`colourbyuserid`/`userflagsbyuserid`; join by userid in `UpdateBadges`; add
  `GLOBAL.PartyHud_AvatarStyle`.
- `modinfo.lua` — `version` → `2026.11`; add `avatar_style` dropdown + `name_colour` toggle.

---

## Task 1 — `partyhud_avatar.classify` + `atlas_and_tex` (avatar resolution, pure)

Mirrors `characterutil.lua:72-90`. Decides which bucket a prefab falls into and resolves the
`(atlas, tex)` pair with the full base/mod/unknown fallback table.

**Files:**
- Create: `scripts/partyhud_avatar.lua`
- Test: `spec/avatar_spec.lua`

**Steps:**

- [ ] 1. Write the failing test file `spec/avatar_spec.lua` with the `classify` + `atlas_and_tex` cases:

```lua
-- spec/avatar_spec.lua — pure avatar / name-colour decision logic (partyhud_avatar)
local M = require("partyhud_avatar")

-- minimal fixtures mirroring the engine's DST_CHARACTERLIST / MODCHARACTERLIST / MOD_AVATAR_LOCATIONS
local DST = { "wilson", "willow", "wx78" }
local MODCHARS = { "fakemod" }
local MOD_LOC = { fakemod = "../mods/fakemod/", Default = "../mods/default/" }

describe("partyhud_avatar — classify", function()
  it("a base character -> 'base'", function()
    assert.are.equal("base", M.classify("wilson", DST, MODCHARS))
  end)

  it("'random' -> 'random' (treated like a real character for display)", function()
    assert.are.equal("random", M.classify("random", DST, MODCHARS))
  end)

  it("a registered mod character -> 'mod'", function()
    assert.are.equal("mod", M.classify("fakemod", DST, MODCHARS))
  end)

  it("a non-empty unregistered name -> 'unknown_named' (the generic mod head bucket)", function()
    -- characterutil.lua:82-84: a valid-but-unregistered name renders avatar_mod.tex
    assert.are.equal("unknown_named", M.classify("notamod", DST, MODCHARS))
  end)

  it("nil or empty prefab -> 'unknown'", function()
    assert.are.equal("unknown", M.classify(nil, DST, MODCHARS))
    assert.are.equal("unknown", M.classify("", DST, MODCHARS))
  end)
end)

describe("partyhud_avatar — atlas_and_tex", function()
  it("base char -> images/avatars.xml + avatar_<prefab>.tex", function()
    local atlas, tex = M.atlas_and_tex("wilson", "base", MOD_LOC)
    assert.are.equal("images/avatars.xml", atlas)
    assert.are.equal("avatar_wilson.tex", tex)
  end)

  it("'random' -> images/avatars.xml + avatar_random.tex", function()
    local atlas, tex = M.atlas_and_tex("random", "random", MOD_LOC)
    assert.are.equal("images/avatars.xml", atlas)
    assert.are.equal("avatar_random.tex", tex)
  end)

  it("registered mod char -> mod location atlas + avatar_<prefab>.tex", function()
    local atlas, tex = M.atlas_and_tex("fakemod", "mod", MOD_LOC)
    assert.are.equal("../mods/fakemod/avatar_fakemod.xml", atlas)
    assert.are.equal("avatar_fakemod.tex", tex)
  end)

  it("registered mod char with no specific MOD_AVATAR_LOCATIONS entry -> Default location", function()
    local atlas, tex = M.atlas_and_tex("othermod", "mod", MOD_LOC)
    assert.are.equal("../mods/default/avatar_othermod.xml", atlas)
    assert.are.equal("avatar_othermod.tex", tex)
  end)

  it("unknown_named -> images/avatars.xml + avatar_mod.tex (generic mod head, never crashes)", function()
    local atlas, tex = M.atlas_and_tex("notamod", "unknown_named", MOD_LOC)
    assert.are.equal("images/avatars.xml", atlas)
    assert.are.equal("avatar_mod.tex", tex)
  end)

  it("unknown -> images/avatars.xml + avatar_unknown.tex", function()
    local atlas, tex = M.atlas_and_tex(nil, "unknown", MOD_LOC)
    assert.are.equal("images/avatars.xml", atlas)
    assert.are.equal("avatar_unknown.tex", tex)
  end)

  it("nil mod_avatar_locations is tolerated for non-mod buckets", function()
    local atlas, tex = M.atlas_and_tex("wilson", "base", nil)
    assert.are.equal("images/avatars.xml", atlas)
    assert.are.equal("avatar_wilson.tex", tex)
  end)
end)
```

- [ ] 2. Run it to confirm it fails (module does not exist yet):

```
luajit spec/run_local.lua
```
Expected: a failure such as `module 'partyhud_avatar' not found` (or the runner reporting 0 passed / errored on require).

- [ ] 3. Create `scripts/partyhud_avatar.lua` with the minimal `classify` + `atlas_and_tex` impl:

```lua
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

-- Classify a prefab into one of four buckets, mirroring characterutil.lua:75-88:
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

return M
```

- [ ] 4. Run the spec to confirm green:

```
luajit spec/run_local.lua
```
Expected: all `classify` + `atlas_and_tex` cases pass (the runner prints `OK` / `N passed, 0 failed`).

- [ ] 5. Gate + commit:

```
luacheck scripts/partyhud_avatar.lua spec/avatar_spec.lua
stylua --check scripts/partyhud_avatar.lua spec/avatar_spec.lua
luajit spec/run_local.lua
```
Expected: luacheck `0 warnings / 0 errors`; stylua prints nothing (exit 0); specs green. Then:

```
git add scripts/partyhud_avatar.lua spec/avatar_spec.lua
git commit -m "PARTY-2026.11 add partyhud_avatar classify + atlas_and_tex

- pure avatar texture resolution mirroring characterutil.lua fallback table
- base/random/mod/unknown_named/unknown buckets; busted specs"
```

---

## Task 2 — `packidflags` / `unpackidflags` (USERFLAGS bit round-trip, pure)

The animated head needs ghost + the 3 character-state bits, sourced from `GetClientTable().userflags`
(or, for a local teammate, packed from entity tags). Pure bit math, mirroring the existing
`packflags`/`unpackflags` in `partyhud_statuscodec`.

**Files:**
- Modify: `scripts/partyhud_avatar.lua`
- Test: `spec/avatar_spec.lua`

**Steps:**

- [ ] 1. Append the failing `packidflags`/`unpackidflags` describe block to `spec/avatar_spec.lua`:

```lua
describe("partyhud_avatar — packidflags / unpackidflags", function()
  -- USERFLAGS bits (constants.lua:2381-2391): IS_GHOST=1, CHARACTER_STATE_1=4, _2=8, _3=32
  it("all false -> 0", function()
    assert.are.equal(0, M.packidflags({ ghost = false, state1 = false, state2 = false, state3 = false }))
  end)

  it("ghost only -> 1", function()
    assert.are.equal(1, M.packidflags({ ghost = true }))
  end)

  it("state1+state2+state3 -> 4+8+32 = 44", function()
    assert.are.equal(44, M.packidflags({ state1 = true, state2 = true, state3 = true }))
  end)

  it("ghost + all states -> 1+4+8+32 = 45", function()
    assert.are.equal(45, M.packidflags({ ghost = true, state1 = true, state2 = true, state3 = true }))
  end)

  it("unpack is the inverse of pack (round-trip)", function()
    for _, t in ipairs({
      { ghost = false, state1 = false, state2 = false, state3 = false },
      { ghost = true, state1 = false, state2 = false, state3 = false },
      { ghost = false, state1 = true, state2 = false, state3 = false },
      { ghost = true, state1 = true, state2 = true, state3 = true },
    }) do
      local n = M.packidflags(t)
      local u = M.unpackidflags(n)
      assert.are.equal(t.ghost or false, u.ghost)
      assert.are.equal(t.state1 or false, u.state1)
      assert.are.equal(t.state2 or false, u.state2)
      assert.are.equal(t.state3 or false, u.state3)
    end
  end)

  it("unpackidflags reads a raw engine userflags int (ignores IS_AFK=2 / IS_LOADING=16)", function()
    -- IS_GHOST(1) + IS_AFK(2) + IS_LOADING(16) = 19; we only care about ghost + the 3 states
    local u = M.unpackidflags(19)
    assert.is_true(u.ghost)
    assert.is_false(u.state1)
    assert.is_false(u.state2)
    assert.is_false(u.state3)
  end)

  it("nil flags table packs to 0", function()
    assert.are.equal(0, M.packidflags(nil))
  end)
end)
```

- [ ] 2. Run to confirm the new cases fail (the prior tasks' cases still pass):

```
luajit spec/run_local.lua
```
Expected: failures only in the `packidflags / unpackidflags` block (`attempt to call field 'packidflags' (a nil value)`).

- [ ] 3. Add the bit constants + `packidflags`/`unpackidflags` to `scripts/partyhud_avatar.lua` (insert
      before the final `return M`). Uses pure arithmetic (no `bit` library, no engine `checkbit`):

```lua
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
```

- [ ] 4. Run the spec to confirm all green:

```
luajit spec/run_local.lua
```
Expected: every `partyhud_avatar` case passes including the new bit round-trip block.

- [ ] 5. Gate + commit:

```
luacheck scripts/partyhud_avatar.lua spec/avatar_spec.lua
stylua --check scripts/partyhud_avatar.lua spec/avatar_spec.lua
luajit spec/run_local.lua
```
Expected: luacheck 0/0; stylua exit 0; specs green. Then:

```
git add scripts/partyhud_avatar.lua spec/avatar_spec.lua
git commit -m "PARTY-2026.11 add packidflags/unpackidflags USERFLAGS bit round-trip

- ghost + 3 character-state bits for the animated head, pure arithmetic (Lua 5.1, no bit lib)
- accepts a raw GetClientTable userflags int; busted round-trip specs"
```

---

## Task 3 — `identity_changed` + `resolve_avatar_style` (the change-gate + config map, pure)

`identity_changed` is the cheap per-refresh change-gate so the badge only rebuilds its avatar when the
prefab / idflags / base_skin actually changed. `resolve_avatar_style` maps the config int to the internal
style string, never yielding the dropped `head-corner`.

**Files:**
- Modify: `scripts/partyhud_avatar.lua`
- Test: `spec/avatar_spec.lua`

**Steps:**

- [ ] 1. Append the failing describe blocks to `spec/avatar_spec.lua`:

```lua
describe("partyhud_avatar — identity_changed", function()
  it("nil prev vs any new -> changed (first ever build)", function()
    assert.is_true(M.identity_changed(nil, { prefab = "wilson", idflags = 0, base_skin = "" }))
  end)

  it("identical prefab + idflags + base_skin -> NOT changed", function()
    local a = { prefab = "wilson", idflags = 0, base_skin = "wilson_none" }
    local b = { prefab = "wilson", idflags = 0, base_skin = "wilson_none" }
    assert.is_false(M.identity_changed(a, b))
  end)

  it("prefab differs -> changed", function()
    assert.is_true(M.identity_changed({ prefab = "wilson", idflags = 0 }, { prefab = "willow", idflags = 0 }))
  end)

  it("idflags differ (e.g. became ghost) -> changed", function()
    assert.is_true(M.identity_changed({ prefab = "wilson", idflags = 0 }, { prefab = "wilson", idflags = 1 }))
  end)

  it("base_skin differs -> changed", function()
    assert.is_true(M.identity_changed(
      { prefab = "wilson", idflags = 0, base_skin = "wilson_none" },
      { prefab = "wilson", idflags = 0, base_skin = "wilson_formal" }
    ))
  end)

  it("nil-vs-nil base_skin treated as equal", function()
    assert.is_false(M.identity_changed({ prefab = "wilson", idflags = 0 }, { prefab = "wilson", idflags = 0 }))
  end)
end)

describe("partyhud_avatar — resolve_avatar_style", function()
  -- config data ints (modinfo avatar_style dropdown): 0=Off, 1=Corner, 2=Centred head
  it("0 -> off", function()
    assert.are.equal("off", M.resolve_avatar_style(0))
  end)

  it("1 -> corner", function()
    assert.are.equal("corner", M.resolve_avatar_style(1))
  end)

  it("2 -> centre", function()
    assert.are.equal("centre", M.resolve_avatar_style(2))
  end)

  it("nil -> off (missing/older config defaults to off)", function()
    assert.are.equal("off", M.resolve_avatar_style(nil))
  end)

  it("unknown value -> off (never the dropped head-corner combo)", function()
    assert.are.equal("off", M.resolve_avatar_style(7))
    assert.are.equal("off", M.resolve_avatar_style(-1))
    assert.are.equal("off", M.resolve_avatar_style("corner")) -- wrong type -> off
  end)
end)
```

- [ ] 2. Run to confirm the new cases fail:

```
luajit spec/run_local.lua
```
Expected: failures only in `identity_changed` + `resolve_avatar_style` (`attempt to call field ... (a nil value)`).

- [ ] 3. Add both fns to `scripts/partyhud_avatar.lua` (before `return M`):

```lua
-- Cheap per-refresh change-gate for the badge's avatar rebuild. prev/new are
-- { prefab, idflags, base_skin } snapshots. nil prev (first build) -> always changed. base_skin is
-- compared with an "" coercion so nil-vs-nil and nil-vs-"" read equal (a base char with no skin set).
function M.identity_changed(prev, new)
  if prev == nil then
    return true
  end
  return prev.prefab ~= new.prefab
    or prev.idflags ~= new.idflags
    or (prev.base_skin or "") ~= (new.base_skin or "")
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
```

- [ ] 4. Run the spec to confirm green:

```
luajit spec/run_local.lua
```
Expected: all `partyhud_avatar` cases pass.

- [ ] 5. Gate + commit:

```
luacheck scripts/partyhud_avatar.lua spec/avatar_spec.lua
stylua --check scripts/partyhud_avatar.lua spec/avatar_spec.lua
luajit spec/run_local.lua
```
Expected: luacheck 0/0; stylua exit 0; specs green. Then:

```
git add scripts/partyhud_avatar.lua spec/avatar_spec.lua
git commit -m "PARTY-2026.11 add identity_changed + resolve_avatar_style

- identity_changed: cheap prefab/idflags/base_skin change-gate for the per-refresh avatar rebuild
- resolve_avatar_style: config int -> off/corner/centre; unknown -> off (never head-corner)"
```

---

## Task 4 — `name_colour` (+ optional `is_low_contrast`) — the single-writer arithmetic, pure

`name_colour` is the pure form of the widget's `_apply_name_colour`: reconcile the player colour with the
foreign dim, falling back to GREY for a nil / not-ready white colour. `is_low_contrast` is OPTIONAL and is
only shipped if a contrast decision actually lands in widget code; the spec covers it so it is ready.

**Files:**
- Modify: `scripts/partyhud_avatar.lua`
- Test: `spec/avatar_spec.lua`

**Steps:**

- [ ] 1. Append the failing describe blocks to `spec/avatar_spec.lua`:

```lua
-- float-tolerant compare for the alpha arithmetic
local function near(a, b)
  return math.abs(a - b) <= 1e-9
end

describe("partyhud_avatar — name_colour", function()
  -- DEFAULT_PLAYER_COLOUR (constants.lua:1765) = RGB(153,153,153) = {0.6,0.6,0.6} GREY
  it("local player colour -> {r,g,b,1} (full opacity)", function()
    local c = M.name_colour({ 0.9, 0.2, 0.2, 1 }, false, 0.45)
    assert.is_true(near(c[1], 0.9))
    assert.is_true(near(c[2], 0.2))
    assert.is_true(near(c[3], 0.2))
    assert.is_true(near(c[4], 1))
  end)

  it("foreign player -> alpha scaled by foreign_dim, hue preserved", function()
    local c = M.name_colour({ 0.9, 0.2, 0.2, 1 }, true, 0.45)
    assert.is_true(near(c[1], 0.9))
    assert.is_true(near(c[2], 0.2))
    assert.is_true(near(c[3], 0.2))
    assert.is_true(near(c[4], 0.45)) -- 1 * foreign_dim
  end)

  it("foreign with an explicit input alpha -> input_alpha * foreign_dim", function()
    local c = M.name_colour({ 0.9, 0.2, 0.2, 0.8 }, true, 0.5)
    assert.is_true(near(c[4], 0.4)) -- 0.8 * 0.5
  end)

  it("nil colour -> GREY {0.6,0.6,0.6} at the right alpha (NOT white)", function()
    local c = M.name_colour(nil, false, 0.45)
    assert.is_true(near(c[1], 0.6))
    assert.is_true(near(c[2], 0.6))
    assert.is_true(near(c[3], 0.6))
    assert.is_true(near(c[4], 1))
  end)

  it("not-ready white {1,1,1,1} -> GREY (the join-order colour has not been assigned yet)", function()
    local c = M.name_colour({ 1, 1, 1, 1 }, false, 0.45)
    assert.is_true(near(c[1], 0.6))
    assert.is_true(near(c[2], 0.6))
    assert.is_true(near(c[3], 0.6))
    assert.is_true(near(c[4], 1))
  end)

  it("nil/white colour on a foreign badge -> GREY dimmed", function()
    local c = M.name_colour(nil, true, 0.45)
    assert.is_true(near(c[1], 0.6))
    assert.is_true(near(c[4], 0.45))
  end)

  it("a real grey-ish colour that is NOT pure white is kept (not coerced)", function()
    local c = M.name_colour({ 0.6, 0.6, 0.6, 1 }, false, 0.45)
    assert.is_true(near(c[1], 0.6)) -- already grey; unchanged
    assert.is_true(near(c[4], 1))
  end)
end)

describe("partyhud_avatar — is_low_contrast (optional)", function()
  -- true ONLY for the 3 low-luminance palette colours: BROWN, VIOLETRED, DARKPLUM
  it("BROWN-ish is low contrast", function()
    assert.is_true(M.is_low_contrast({ 0.5, 0.32, 0.18, 1 }))
  end)

  it("a bright warm colour is NOT low contrast", function()
    assert.is_false(M.is_low_contrast({ 0.9, 0.7, 0.2, 1 }))
  end)

  it("nil colour -> false (no decision)", function()
    assert.is_false(M.is_low_contrast(nil))
  end)
end)
```

- [ ] 2. Run to confirm the new cases fail:

```
luajit spec/run_local.lua
```
Expected: failures only in `name_colour` + `is_low_contrast`.

- [ ] 3. Add both fns to `scripts/partyhud_avatar.lua` (before `return M`):

```lua
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
```

- [ ] 4. Run the spec to confirm green:

```
luajit spec/run_local.lua
```
Expected: every `partyhud_avatar` case passes (full Q4 list now covered).

- [ ] 5. Gate + commit:

```
luacheck scripts/partyhud_avatar.lua spec/avatar_spec.lua
stylua --check scripts/partyhud_avatar.lua spec/avatar_spec.lua
luajit spec/run_local.lua
```
Expected: luacheck 0/0; stylua exit 0; specs green. Then:

```
git add scripts/partyhud_avatar.lua spec/avatar_spec.lua
git commit -m "PARTY-2026.11 add name_colour + is_low_contrast

- name_colour: reconcile player colour x foreign-dim; nil/not-ready-white -> GREY (not white)
- is_low_contrast: optional luminance threshold for the 3 low-contrast palette colours; busted specs"
```

---

## Task 5 — `partybadge.lua`: `_apply_name_colour` single-writer (replace the hard SetColour)

Introduce the single-writer name-colour helper and route `SetForeign`/`SetName` through it, replacing the
hard `self.name:SetColour(1, 1, 1, a)` at `partybadge.lua:376`. This is behaviour-additive: with no player
colour set, the helper still produces `{1,1,1,a}` — wait, no: the avatar module returns GREY for nil. To
stay behaviour-neutral until modmain feeds a colour (Task 8), default `self.player_colour = nil` AND keep
name colouring OFF by a `self.name_colour_enabled` flag (default false) so existing visuals are unchanged
until config turns it on.

**Files:**
- Modify: `scripts/widgets/partybadge.lua`
- (No new spec — the pure arithmetic is already covered by `avatar_spec`; the widget is engine-bound.)

**Steps:**

- [ ] 1. Add the avatar-module require near the top of `partybadge.lua`, right after the existing
      `badgemath` require (line 13):

```lua
-- v2026.11: pure avatar / name-colour decision logic (classify + atlas/tex fallback + idflags +
-- name_colour reconciliation), extracted so it can be busted-tested with zero engine deps. The widget
-- reads its live state (player colour, foreign flag) and delegates the arithmetic here.
local avatarmath = require("partyhud_avatar")
```

- [ ] 2. Add the new per-badge identity state to the ctor, right after the low-HP block
      (`self._blink_t = 0` at line 145, before the closing `end)` at line 146):

```lua
  -- v2026.11 avatar + name-colour state. player_colour is the teammate's {r,g,b,a} (local
  -- v.playercolour, or the GetClientTable colour for a foreign player); nil until set per refresh.
  -- name_colour_enabled gates the feature (config name_colour); when false the name stays white-at-alpha
  -- exactly like pre-v2026.11. avatar_style is "off"/"corner"/"centre"; the avatar children are created
  -- lazily by SetAvatar. _avatar_identity caches the last-rendered {prefab,idflags,base_skin} snapshot
  -- so SetAvatar can skip a rebuild when identity is unchanged (avatarmath.identity_changed).
  self.player_colour = nil
  self.name_colour_enabled = false
  self.avatar_style = "off"
  self.avatar_corner = nil -- flat Image child (corner style)
  self.avatar_head = nil -- animated UIAnim child (centre style)
  self._avatar_identity = nil
```

- [ ] 3. Add the `_apply_name_colour` single-writer method, immediately after `_apply_frame_colour`
      (after line 311, before `_set_low_hp`):

```lua
-- v2026.11: single-writer for self.name's colour, reconciling {player colour, foreign-dim}. Both
-- SetForeign and SetName route through here so the player colour and the foreign dim can never desync
-- (same single-writer model as _apply_frame_colour). When name_colour_enabled is false, the name keeps
-- the pre-v2026.11 white-at-alpha look (so the feature is a no-op until config turns it on). The pure
-- reconciliation (nil/not-ready-white -> GREY, alpha = base*dim) lives in avatarmath.name_colour.
function PartyBadge:_apply_name_colour()
  if self.name == nil then
    return
  end
  local a = self.foreign and FOREIGN_ALPHA or FULL_ALPHA
  if not self.name_colour_enabled then
    self.name:SetColour(1, 1, 1, a)
    return
  end
  local c = avatarmath.name_colour(self.player_colour, self.foreign, FOREIGN_ALPHA)
  self.name:SetColour(c[1], c[2], c[3], c[4])
end
```

- [ ] 4. Replace the hard name colour write inside `SetForeign` (line 376) with the single-writer call:

```lua
  -- text elements: name + the HP / sub-ring numbers. The NAME is owned by _apply_name_colour
  -- (reconciles the player colour with the foreign dim); call it after self.foreign is set above.
  self:_apply_name_colour()
```
(Leave the `self.num` / `hungerbadge.num` / `sanitybadge.num` `SetColour(1,1,1,a)` lines below it
unchanged — those are number tints, not the name.)

- [ ] 5. Add a public setter so modmain can push the colour + toggle, plus route `SetName` through the
      helper. Replace the existing `SetName` (lines 201-203):

```lua
function PartyBadge:SetName(namestring)
  self.name:SetString(namestring)
  self:_apply_name_colour() -- re-assert the colour after a string change (string set does not touch colour)
end

-- v2026.11: set this badge's teammate player colour + whether name colouring is enabled, then
-- re-apply. colour is {r,g,b,a} or nil (not-ready -> GREY). Called per refresh from UpdateBadges.
function PartyBadge:SetPlayerColour(colour, enabled)
  self.player_colour = colour
  self.name_colour_enabled = enabled and true or false
  self:_apply_name_colour()
end
```

- [ ] 6. Sanity-load the widget module in plain Lua to catch a syntax/typo error before committing
      (it requires the engine `Class`/widgets, so a full require will error on those — instead just
      byte-compile it):

```
luajit -bl scripts/widgets/partybadge.lua /dev/null && echo "partybadge.lua compiles"
```
Expected: prints `partybadge.lua compiles` (no syntax error). (If `luajit -bl` is unavailable, use
`luac -p scripts/widgets/partybadge.lua` and expect no output + exit 0.)

- [ ] 7. Gate + commit. busted only covers the pure modules, so run the full suite to confirm nothing
      regressed, plus luacheck/stylua on the widget:

```
luacheck scripts/widgets/partybadge.lua
stylua --check scripts/widgets/partybadge.lua
luajit spec/run_local.lua
```
Expected: luacheck 0/0; stylua exit 0; all specs still green. Then:

```
git add scripts/widgets/partybadge.lua
git commit -m "PARTY-2026.11 partybadge _apply_name_colour single-writer

- replace the hard self.name:SetColour(1,1,1,a) with a single-writer reconciling player colour x dim
- SetName/SetForeign route through it; SetPlayerColour pushes the colour + toggle; off until config on"
```

---

## Task 6 — `partybadge.lua`: `SetAvatar` corner style (flat Image)

Add the corner-avatar render: a flat `Image` child inset in a badge corner, textured from the resolved
atlas/tex. HP fill ring + number untouched in this style. Lazily created; idempotent per refresh.

**Files:**
- Modify: `scripts/widgets/partybadge.lua`

**Steps:**

- [ ] 1. Add the corner-position constant near the other layout constants (after `SUB_X = 17`, line 38):

```lua
-- v2026.11 corner avatar: a small flat head inset in the badge's top-LEFT corner so it does not collide
-- with the HP number (centre) or the sub-rings (bottom). Scale + offset visually tuned to sit just
-- inside the ring backing. The foreign-label (+50) / name (+40) sit above and do not overlap.
local AVATAR_CORNER_SCALE = 0.45
local AVATAR_CORNER_X = -20
local AVATAR_CORNER_Y = 18
```

- [ ] 2. Add the `SetAvatar` method (corner branch only for now; centre is Task 7) after
      `SetPlayerColour` (added in Task 5). Place it before `SetPercent`:

```lua
-- v2026.11: render the teammate's avatar for the current style. Called per refresh from UpdateBadges.
--   prefab    : character prefab string (local v.prefab, or the GetClientTable record prefab); nil -> unknown
--   idflags   : packed ghost + character-state bits (avatarmath.packidflags / a raw userflags int)
--   is_foreign: dims to FOREIGN_ALPHA (data ~1s stale), matching the rest of the badge
-- style is set separately via SetAvatarStyle (config-driven); SetAvatar is a no-op when style == "off".
-- The avatar children are created lazily so an "off" badge pays nothing. identity_changed gates the
-- (cheaper-to-skip) texture/anim rebuild; alpha is always re-asserted (foreign flip is cheap).
function PartyBadge:SetAvatar(prefab, idflags, is_foreign)
  if self.avatar_style == "off" then
    if self.avatar_corner ~= nil then
      self.avatar_corner:Hide()
    end
    if self.avatar_head ~= nil then
      self.avatar_head:Hide()
    end
    return
  end
  local a = (is_foreign and FOREIGN_ALPHA) or FULL_ALPHA
  local new_identity = { prefab = prefab, idflags = idflags or 0 }
  local changed = avatarmath.identity_changed(self._avatar_identity, new_identity)

  if self.avatar_style == "corner" then
    if self.avatar_head ~= nil then
      self.avatar_head:Hide()
    end
    if self.avatar_corner == nil then
      self.avatar_corner = self:AddChild(Image(avatarmath.DEFAULT_ATLAS, "avatar_unknown.tex"))
      self.avatar_corner:SetScale(AVATAR_CORNER_SCALE)
      self.avatar_corner:SetPosition(AVATAR_CORNER_X, AVATAR_CORNER_Y, 0)
      self.avatar_corner:SetClickable(false)
    end
    if changed then
      -- classify needs the engine character lists / mod avatar locations; read them here (engine
      -- side) and delegate the bucket + atlas/tex to the pure module.
      local cls = avatarmath.classify(prefab, DST_CHARACTERLIST, MODCHARACTERLIST)
      local atlas, tex = avatarmath.atlas_and_tex(prefab, cls, MOD_AVATAR_LOCATIONS)
      self.avatar_corner:SetTexture(atlas, tex)
    end
    self.avatar_corner:SetTint(1, 1, 1, a)
    self.avatar_corner:Show()
  end
  self._avatar_identity = new_identity
end

-- v2026.11: set the avatar render style ("off"/"corner"/"centre"). Forces a rebuild next SetAvatar by
-- clearing the cached identity, and hides whichever child the new style does not use. The HP number's
-- hover-only override (centre style) is applied by SetAvatar/SetHPNumberAlways interplay in Task 7.
function PartyBadge:SetAvatarStyle(style)
  self.avatar_style = style or "off"
  self._avatar_identity = nil -- force the next SetAvatar to rebuild the texture/anim
  if self.avatar_style ~= "corner" and self.avatar_corner ~= nil then
    self.avatar_corner:Hide()
  end
  if self.avatar_style ~= "centre" and self.avatar_head ~= nil then
    self.avatar_head:Hide()
  end
end
```

- [ ] 3. Ensure the avatar children are hidden on `HideBadge`/`ShowDead` (a dead teammate shows the skull,
      not the avatar). In `HideBadge` (line 410-413) and `ShowDead` (line 440-462), add the hides. For
      `HideBadge`, before `self:Hide()`:

```lua
  if self.avatar_corner ~= nil then
    self.avatar_corner:Hide()
  end
  if self.avatar_head ~= nil then
    self.avatar_head:Hide()
  end
```
And the same two-block hide inside `ShowDead`, before `self.dead:Show()`.

- [ ] 4. Byte-compile to confirm no syntax error:

```
luac -p scripts/widgets/partybadge.lua && echo "partybadge.lua compiles"
```
Expected: prints `partybadge.lua compiles` (exit 0, no output from luac).

- [ ] 5. Gate + commit:

```
luacheck scripts/widgets/partybadge.lua
stylua --check scripts/widgets/partybadge.lua
luajit spec/run_local.lua
```
Expected: luacheck 0/0 (note: `DST_CHARACTERLIST` / `MODCHARACTERLIST` / `MOD_AVATAR_LOCATIONS` are
engine globals — add them to `read_globals` in `.luacheckrc` if luacheck flags them; see Task 6a below);
stylua exit 0; specs green. Then:

```
git add scripts/widgets/partybadge.lua
git commit -m "PARTY-2026.11 partybadge SetAvatar corner style (flat Image)

- lazy corner Image textured via avatarmath.classify + atlas_and_tex; identity_changed gates rebuild
- SetAvatarStyle clears the cache + hides unused children; avatar hidden on HideBadge/ShowDead"
```

- [ ] 6. **(Task 6a, do as part of step 5 if needed)** If luacheck flags `DST_CHARACTERLIST` /
      `MODCHARACTERLIST` / `MOD_AVATAR_LOCATIONS` as undefined globals, add them to the `read_globals`
      list in `.luacheckrc` (after the `"Lerp",` line):

```lua
  "DST_CHARACTERLIST", "MODCHARACTERLIST", "MOD_AVATAR_LOCATIONS", -- character lists / mod avatar dirs (avatar render)
  "GetPlayerBadgeData", "SetSkinsOnAnim", "GetSkinData", -- animated-head helpers (skinsutils / components/skinner)
```
Re-run `luacheck scripts/widgets/partybadge.lua` and confirm 0/0, then include `.luacheckrc` in the
commit from step 5.

---

## Task 7 — `partybadge.lua`: `SetAvatar` centre style (animated head)

Add the `centre` branch: an animated character head (`UIAnim`) in the ring centre, ported from
`playerbadge.lua:82-113`. While the centre style is active the HP number is forced hover-only so the face
shows. The centre avatar is mutually exclusive with the dead skull (shown via `ShowDead`).

**Files:**
- Modify: `scripts/widgets/partybadge.lua`

**Steps:**

- [ ] 1. Add the `centre` branch into `SetAvatar`, after the `corner` block (before
      `self._avatar_identity = new_identity`):

```lua
  if self.avatar_style == "centre" then
    if self.avatar_corner ~= nil then
      self.avatar_corner:Hide()
    end
    if self.avatar_head == nil then
      -- animated head child, ported from playerbadge.lua:_SetupHeads + Set. Parented to the badge
      -- (not underNumber) so it draws above the ring fill; clickable off (purely cosmetic).
      self.avatar_head = self:AddChild(UIAnim())
      self.avatar_head:GetAnimState():SetFacing(FACING_DOWN)
      self.avatar_head:GetAnimState():Hide("ARM_carry")
      self.avatar_head:GetAnimState():Hide("HAIR_HAT")
      self.avatar_head:GetAnimState():Hide("HEAD_HAT")
      self.avatar_head:GetAnimState():Hide("HEAD_HAT_NOHELM")
      self.avatar_head:GetAnimState():Hide("HEAD_HAT_HELM")
      self.avatar_head:SetClickable(false)
    end
    if changed then
      local f = avatarmath.unpackidflags(idflags)
      -- GetPlayerBadgeData (skinsutils.lua:1903) -> bank/anim/skin_mode/scale/y_offset for this
      -- character's ghost / were / stage pose. nil prefab -> "wilson" default head (the engine fn
      -- branches only on known characters, so an unknown prefab takes the generic else branch).
      local bank, animation, skin_mode, scale, y_offset =
        GetPlayerBadgeData(prefab, f.ghost, f.state1, f.state2, f.state3)
      local hs = self.avatar_head:GetAnimState()
      hs:SetBank(bank)
      hs:PlayAnimation(animation, true)
      -- per-badge perf parity with the vanilla scoreboard: animate only if the profile enables it,
      -- else freeze on frame 0 (N badges animating is the cost the dropped head-corner combo avoided).
      if Profile ~= nil and Profile.GetAnimatedHeadsEnabled ~= nil and Profile:GetAnimatedHeadsEnabled() then
        hs:SetTime(math.random() * 1.5)
      else
        hs:SetTime(0)
        hs:Pause()
      end
      self.avatar_head:SetScale(scale)
      self.avatar_head:SetPosition(0, y_offset, 0)
      -- base build / skin: GetSkinData(base_skin or prefab.."_none") -> skins[skin_mode]; SetSkinsOnAnim
      -- (components/skinner.lua:11, a GLOBAL) puts the base build on the anim. base_skin defaults handled
      -- by SetSkinsOnAnim; pass the plain character head (full skin fidelity is out of scope).
      local prefabname = (prefab ~= nil and prefab ~= "" and prefab) or "wilson"
      local skindata = GetSkinData((prefab and (prefab .. "_none")) or "wilson_none")
      local base_build = prefabname
      if skindata ~= nil and skindata.skins ~= nil then
        base_build = skindata.skins[skin_mode] or prefabname
      end
      SetSkinsOnAnim(hs, prefabname, base_build, {}, nil, skin_mode)
    end
    self.avatar_head:GetAnimState():SetMultColour(1, 1, 1, a)
    self.avatar_head:Show()
    -- HP number is hover-only while the centre head is up, so the face is unobstructed. Restored by
    -- SetAvatarStyle("off"/"corner") via the hp_number_always reset below.
    if self.num ~= nil and not self._hp_number_was_hover then
      self._hp_number_was_hover = true
      self.num:Hide()
    end
  end
```

- [ ] 2. Make the HP-number hover-only override reversible. In `SetAvatarStyle`, when leaving the centre
      style, restore the configured HP-number visibility. Add to `SetAvatarStyle` (after the head-hide
      block):

```lua
  -- leaving the centre style: restore the configured HP-number visibility (centre forced it hover-only)
  if self.avatar_style ~= "centre" and self._hp_number_was_hover then
    self._hp_number_was_hover = false
    self:SetHPNumberAlways(self.hp_number_always)
  end
```
And initialise `self._hp_number_was_hover = false` in the ctor block from Task 5 step 2 (add the line
alongside `self._avatar_identity = nil`).

- [ ] 3. Add the engine globals used here to `.luacheckrc` `read_globals` if not already added in Task 6a:
      `FACING_DOWN` and `Profile`, plus `GetPlayerBadgeData`, `SetSkinsOnAnim`, `GetSkinData` (Task 6a added
      the latter three). Add:

```lua
  "FACING_DOWN", -- UIAnim facing constant (animated head)
  "Profile", -- client save-data global (Profile:GetAnimatedHeadsEnabled for the animated-head perf parity)
```
NOTE: the centre-head code uses bare `Profile` (NOT `GLOBAL.Profile`) because `partybadge.lua` is a widget
file running in full `_G`, where `GLOBAL` is not defined (`GLOBAL` is a modmain-sandbox alias only) — a
`GLOBAL.Profile` reference would be a nil-index crash. This matches the widget's existing bare-global
convention (it already uses bare `Image`/`Text`/`Badge`/`Lerp`).

- [ ] 4. Byte-compile to confirm no syntax error:

```
luac -p scripts/widgets/partybadge.lua && echo "partybadge.lua compiles"
```
Expected: prints `partybadge.lua compiles`.

- [ ] 5. Gate + commit:

```
luacheck scripts/widgets/partybadge.lua .luacheckrc
stylua --check scripts/widgets/partybadge.lua
luajit spec/run_local.lua
```
Expected: luacheck 0/0; stylua exit 0; specs green. Then:

```
git add scripts/widgets/partybadge.lua .luacheckrc
git commit -m "PARTY-2026.11 partybadge SetAvatar centre style (animated head)

- animated UIAnim head ported from playerbadge.lua (GetPlayerBadgeData + SetSkinsOnAnim)
- HP number forced hover-only while centre is active; honours Profile:GetAnimatedHeadsEnabled
- ghost/were/stage pose from unpackidflags; engine globals declared in .luacheckrc"
```

---

## Task 8 — `modmain.lua`: identity-join + render wiring in `UpdateBadges`

Forward-require the avatar module, read the new config, build the `GetClientTable`-derived identity tables,
and join by userid in `UpdateBadges` to call `SetAvatar` + `SetPlayerColour` for both the local and the
foreign render blocks. Apply the per-badge style/colour at construct time. **Touches only the modmain
regions listed in the header sequencing note** — coordinate with the crash-guard plan, which lands FIRST.

**Concrete collision with the crash-guard plan (re-read the header note):** crash-guard adds a
`foreign_fresh` freshness clause to the **line-538** foreign-append guard
(`if show_crossshard and not DEBUG_SHOWALL and next_slot <= maxbadges then`), and step 5 below hoists the
`namebyuserid` build out of **lines 540-548** (which sit INSIDE that same `if`) and deletes the inner
duplicate. Because crash-guard lands first, by the time you execute this task line 538 already reads
`if show_crossshard and not DEBUG_SHOWALL and foreign_fresh and next_slot <= maxbadges then` — **PRESERVE
the `and foreign_fresh` term**, do not revert it. You only hoist the 540-548 `namebyuserid` build out; you
do not touch the freshness clause.

**Files:**
- Modify: `modmain.lua`

**Steps:**

- [ ] 0. **Re-grep the live anchors BEFORE editing — do NOT trust the absolute line numbers in this task**
      (538 / 540-548 / 498 / 594, and the construct/forward-require/config anchors). Crash-guard's
      top-of-file upvalue blocks (the `guarded()` helper + the Q5 staleness heartbeat consts) have already
      landed and shifted every anchor below them by ~+40 lines. Locate the real positions with:

```
grep -n 'local namebyuserid = {}' modmain.lua          # the build to hoist (was ~540-548)
grep -n 'if show_crossshard and not DEBUG_SHOWALL' modmain.lua   # the line-538 foreign-append guard (now carries foreign_fresh)
grep -n 'b:SetName(v:GetDisplayName())' modmain.lua     # the LOCAL render block anchor (was ~498)
grep -n 'b:SetName(namebyuserid\[rec.userid\]' modmain.lua  # the FOREIGN render block anchor (was ~594)
grep -n 'local get_client_foreign_records' modmain.lua  # forward-require block anchor (was ~111-112)
```
Use the grep output, not the printed numbers, for every edit below.

- [ ] 1. Add the config reads in the config-read block, after `low_hp_threshold` (line 55). All
      client-only options, read with `get_local_config=true`:

```lua
-- v2026.11 avatar + name colour (both client-render-only). avatar_style: 0=Off/1=Corner/2=Centred head
-- (resolved to "off"/"corner"/"centre" by avatarmath). name_colour: ~=0 = On (default On).
local avatar_style_cfg = GetModConfigData("avatar_style", true)
local name_colour_on = (GetModConfigData("name_colour", true) ~= 0)
```

- [ ] 2. Forward-require the avatar module in the top forward-require block, after the `record` require
      (line 111), so the early `UpdateBadges` closure captures it as an upvalue (the prod crash lesson):

```lua
-- pure avatar / name-colour decision logic (classify + atlas/tex + idflags + name_colour) -- forward
-- required since UpdateBadges (defined inside onstatusdisplaysconstruct, above the later require blocks)
-- uses it; a local declared later in the chunk is NOT an upvalue of that earlier closure (would resolve
-- to a nil global and crash the render path). Same forward-require discipline as layoutmath/record/etc.
local avatarmath = _G.require("partyhud_avatar")
```

- [ ] 3. Add a module-level current avatar style (resolved from config), and apply both the style and the
      name-colour toggle per-badge at construct. In `onstatusdisplaysconstruct`, inside the badge loop
      (after `self.badgearray[i].low_hp_threshold = low_hp_threshold`, line 343):

```lua
    self.badgearray[i]:SetAvatarStyle(avatarmath.resolve_avatar_style(current_avatar_style)) -- v2026.11
```
And add the module-level upvalue near the other client-local state (after `local last_bpmode = -1`,
line 80):

```lua
local current_avatar_style = nil -- v2026.11: resolved avatar style int; nil = use config. The
-- PartyHud_AvatarStyle console fn overrides it at runtime (modtest compare). resolve_avatar_style maps
-- nil/this int -> "off"/"corner"/"centre"; default starts from the config read below.
```
Then set its initial value right after the config read in step 1:

```lua
current_avatar_style = avatar_style_cfg -- v2026.11: seed the runtime style from config
```

- [ ] 4. In the **LOCAL** render block of `UpdateBadges`, after `b:SetName(v:GetDisplayName())`
      (line 498), add the identity-join for a local entity. Implement step 5 FIRST (it builds the
      `prefabbyuserid`/`colourbyuserid`/`userflagsbyuserid` tables once per refresh), because the
      authoritative were/stage state for ALL teammates (local and foreign) is the
      `GetClientTable().userflags` int — NOT entity tags (which vary by character). The local block reads
      prefab/colour off the entity (with a table fallback for the brief pre-populate window) and the
      idflags from the cluster `userflagsbyuserid` table. The exact local-block code is given in step 5
      below (it depends on the step-5 tables); add it here once step 5 has built them.

- [ ] 5. Build the identity tables once per refresh from `GetClientTable()`, alongside the existing
      `namebyuserid`. The cleanest seam: hoist the client-table read to the TOP of `UpdateBadges` (before
      the local loop) so BOTH the local and foreign blocks can use it. Add this near the start of the
      `UpdateBadges` closure (after `local players = {}` setup, before the local render loop, ~line 462):

```lua
    -- v2026.11: cluster-wide identity from GetClientTable(), keyed by userid. Built ONCE per refresh and
    -- read by BOTH the local block (authoritative were/stage userflags) and the foreign block (which has
    -- no local entity at all). ZERO wire change -- the table is already maintained cluster-wide.
    local prefabbyuserid, colourbyuserid, userflagsbyuserid = {}, {}, {}
    do
      local ct = _G.TheNet ~= nil and _G.TheNet:GetClientTable() or nil
      if ct ~= nil then
        for _, c in ipairs(ct) do
          if c.userid ~= nil and c.userid ~= "" then
            prefabbyuserid[c.userid] = c.prefab
            colourbyuserid[c.userid] = c.colour
            userflagsbyuserid[c.userid] = c.userflags or 0
          end
        end
      end
    end
```
Then replace the local-block idflags (from step 4) with the table-derived values (authoritative for
were/stage), keeping the entity prefab/colour as the primary local source with a table fallback:

```lua
        -- v2026.11 identity (local): prefab + colour off the entity; ghost/were/stage from the
        -- cluster userflags (authoritative; the entity tags vary by character). Table fallback covers
        -- the brief window before the entity's playercolour/prefab are populated.
        b:SetPlayerColour(v.playercolour or colourbyuserid[v.userid], name_colour_on)
        b:SetAvatar(v.prefab or prefabbyuserid[v.userid], userflagsbyuserid[v.userid] or 0, false)
```

- [ ] 6. In the **FOREIGN** render block, after `b:SetName(namebyuserid[rec.userid] or "?")` (line 594),
      add the identity-join (read from the tables — there is no local entity). Reuse the
      `namebyuserid`/`prefabbyuserid`/... tables built in step 5; remove the now-redundant inner
      `namebyuserid` build at lines 540-548 (it is superseded by the hoisted block) OR keep `namebyuserid`
      where it is and only add the three new tables there — choose the hoisted approach from step 5 and
      delete the inner duplicate `namebyuserid` build. Then:

```lua
          -- v2026.11 identity (foreign): all from the cluster roster (no local entity exists).
          b:SetPlayerColour(colourbyuserid[rec.userid], name_colour_on)
          b:SetAvatar(prefabbyuserid[rec.userid], userflagsbyuserid[rec.userid] or 0, true)
```

- [ ] 7. Add the debug console fn `GLOBAL.PartyHud_AvatarStyle`, modelled on `GLOBAL.PartyHud_Layout`
      (lines 317-333), so styles switch instantly in modtest. Place it right after `PartyHud_Layout`'s
      `-- luacheck: pop` (line 333):

```lua
-- [DEBUG/util] runtime avatar-style switch from the client console, no reconnect needed:
--   PartyHud_AvatarStyle("off"|"corner"|"centre")  -> set the style and relayout the live badges
-- Sets the module-level current_avatar_style (UpdateBadges + SetAvatarStyle read it) and re-applies to
-- every live badge, then forces a refresh so the avatars rebuild. Client-only (ThePlayer/HUD nil on a
-- dedicated server -> no-op). Returns the style string applied.
-- luacheck: push ignore 122
GLOBAL.PartyHud_AvatarStyle = function(style)
  local map = { off = 0, corner = 1, centre = 2 }
  current_avatar_style = map[style] or 0
  local resolved = avatarmath.resolve_avatar_style(current_avatar_style)
  local p = _G.ThePlayer
  local sd = p ~= nil and p.HUD ~= nil and p.HUD.controls ~= nil and p.HUD.controls.status or nil
  if sd ~= nil and sd.badgearray ~= nil then
    for _, b in ipairs(sd.badgearray) do
      b:SetAvatarStyle(resolved)
    end
    if p.UpdateBadges ~= nil then
      p.UpdateBadges()
    end
  end
  print("[PartyHud] avatar style = " .. resolved)
  return resolved
end
-- luacheck: pop
```

- [ ] 8. Byte-compile modmain to confirm no syntax error (it requires the engine, so only byte-compile):

```
luac -p modmain.lua && echo "modmain.lua compiles"
```
Expected: prints `modmain.lua compiles`.

- [ ] 9. Gate + commit:

```
luacheck modmain.lua
stylua --check modmain.lua
luajit spec/run_local.lua
```
Expected: luacheck 0/0; stylua exit 0; specs green (modmain has no specs but the suite must stay green).
Then:

```
git add modmain.lua
git commit -m "PARTY-2026.11 modmain identity-join + avatar/name-colour render wiring

- forward-require partyhud_avatar (upvalue for the early UpdateBadges closure)
- build prefab/colour/userflags-by-userid from GetClientTable once per refresh
- join by userid: local reads entity + cluster userflags, foreign reads the tables
- per-badge SetAvatar + SetPlayerColour; PartyHud_AvatarStyle console fn; no wire change"
```

---

## Task 9 — `modinfo.lua`: version bump + config options

Bump the version and add the two config entries the wiring reads.

**Files:**
- Modify: `modinfo.lua`

**Steps:**

- [ ] 1. Bump the version (line 5):

```lua
version = "2026.11"
```

- [ ] 2. Add the `avatar_style` dropdown + `name_colour` toggle into `configuration_options`, after the
      `low_hp_alert` block (after line 112, before the closing `}` of the table):

```lua
  {
    name = "avatar_style",
    label = "Teammate Avatar",
    hover = "Show each teammate's character avatar on their badge: a small head in the corner, or an animated head in the ring centre (the HP number then shows only on hover). Off keeps the plain HP ring.",
    options = {
      { description = "Off", data = 0 },
      { description = "Corner", data = 1 },
      { description = "Centred head", data = 2 },
    },
    default = 1,
    client = true,
  },
  {
    name = "name_colour",
    label = "Name Colour",
    hover = "Colour each teammate's name in their own player colour (the colour the server assigns them). Off shows all names in white.",
    options = {
      { description = "On", data = 1 },
      { description = "Off", data = 0 },
    },
    default = 1,
    client = true,
  },
```
NOTE: `default = 1` (Corner) for `avatar_style` is a provisional ship default; the user picks the final
ship default after the in-game compare (open question in the spec). The `Centred (flat)` 4th entry is
deferred and intentionally NOT added.

- [ ] 3. Byte-compile to confirm valid Lua:

```
luac -p modinfo.lua && echo "modinfo.lua compiles"
```
Expected: prints `modinfo.lua compiles`.

- [ ] 4. Gate + commit:

```
luacheck modinfo.lua
stylua --check modinfo.lua
```
Expected: luacheck 0/0; stylua exit 0. Then:

```
git add modinfo.lua
git commit -m "PARTY-2026.11 modinfo version 2026.11 + avatar_style/name_colour options

- version -> 2026.11
- avatar_style dropdown (Off/Corner/Centred head, default Corner) + name_colour toggle (default On)
- both client = true; Centred (flat) 4th entry deferred"
```

---

## Task 10 — Gate + audit + release pre-flight

Full-suite gate, a (lighter, client-side) crash-safety audit of the new identity-join + `SetAvatar`,
a visual-parity audit of the badge, and the release pre-flight reminder. No new code unless an audit
surfaces a fix.

**Files:**
- (Read-only review of all v2026.11 changes; fixes only if an audit finds one.)

**Steps:**

- [ ] 1. Run the full gate one more time across every changed file:

```
luacheck scripts/partyhud_avatar.lua spec/avatar_spec.lua scripts/widgets/partybadge.lua modmain.lua modinfo.lua .luacheckrc
stylua --check scripts/partyhud_avatar.lua spec/avatar_spec.lua scripts/widgets/partybadge.lua modmain.lua modinfo.lua
luajit spec/run_local.lua
```
Expected: luacheck `0 warnings / 0 errors`; stylua exit 0 (no diff); the full spec suite green
(`avatar_spec` + the 6 pre-existing specs).

- [ ] 2. Run a **`dst-mod-crash-audit`** pass (lighter than usual — the feature is CLIENT render only:
      no server hook, no wire change, blast radius is the local client not the shard). Sweep specifically:
      the new identity-join (`GetClientTable()` nil-guard already present; `c.userid`/`c.prefab`/`c.colour`
      nil tolerance), `SetAvatar` (nil prefab -> unknown path; `GetPlayerBadgeData`/`SetSkinsOnAnim`
      receiving nil/"" prefab -> the engine `else` branch returns the wilson default, never nil-indexes),
      and the forward-require upvalue (`avatarmath` MUST be the top forward-require, not a later local —
      verify `UpdateBadges` captures it). Record findings; apply only real fixes, each as its own
      TDD-gated commit.

```
# invoke the dst-mod-crash-audit review skill on the v2026.11 diff
git diff HEAD~7..HEAD -- scripts/ modmain.lua modinfo.lua .luacheckrc
```
Expected: a clean audit (or a short fix list, each fixed + re-gated + committed).

- [ ] 3. Run a **`dst-badge-visual-audit`** pass on `partybadge.lua`: confirm the corner avatar does not
      collide with the HP number / sub-rings / foreign label; the centre head is mutually exclusive with
      the dead skull (`ShowDead` hides both avatar children); the centre style forces the HP number
      hover-only and restores it on style change; the foreign dim reaches the avatar (alpha == FOREIGN_ALPHA)
      and the name colour (via `_apply_name_colour`); the font drop shadow is preserved for the
      low-contrast colours. Record findings; apply only real fixes (TDD-gated).

- [ ] 4. **`partyhud-release-preflight`** reminder (before tagging — surface to the user, do NOT tag
      autonomously): the skill's checklist incl. (a) the in-engine load-smoke with a CONNECTED player
      (the prod-crash class only triggers once a player is online — a no-player load-smoke masks it), and
      (b) a **2-shard in-game test** confirming a FAR teammate's avatar + name colour + ghost state render
      correctly from `GetClientTable()` (the zero-wire identity path). Also do the `PartyHud_AvatarStyle`
      modtest compare (off/corner/centre) so the user can pick the ship default for the `avatar_style`
      config (open question). This task ENDS with a summary handed to the user; shipping v2026.11 via the
      release CI (with the crash-guard, per its own spec) is the user's call.

```
# surface the preflight checklist; do not tag.
echo "v2026.11 ready for partyhud-release-preflight: connected-player load-smoke + 2-shard avatar/colour/ghost test + PartyHud_AvatarStyle compare for the ship default."
```
Expected: the preflight checklist surfaced to the user; no autonomous tag/ship.
