# Teammate Avatar Skin Reflection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the teammate avatar reflect each player's chosen character skin (`base_skin`) in both the centre and corner avatar styles, replacing the hard-coded `prefab.."_none"` head.

**Architecture:** Unify the avatar on one animated `UIAnim` head with two geometry presets (centre = large/centred, corner = small/top-left); a renderable character (`classify ∈ {base, random}`) uses the animated head with its `base_skin` build in either style, while a non-renderable (mod/unknown) character falls back to the always-loaded flat-atlas image for crash-proofing. `base_skin` flows in cluster-wide from `TheNet:GetClientTable()`.

**Tech Stack:** Lua 5.1 (DST mod sandbox). Pure decision logic in `scripts/partyhud_avatar.lua` (busted-tested via `luajit spec/run_local.lua`); engine-bound widget/modmain code verified by luacheck + an in-engine smoke on the hub `dst-modtest` server (no headless DST client exists for widgets).

## Global Constraints

- Lua 5.1 only — no `goto`, no bitwise operators, no `const`; bit work via arithmetic (see existing `has_bit`).
- `scripts/*` modules run in full `_G` (bare globals); `modmain.lua` runs the restricted sandbox (use `GLOBAL.<fn>`). Do NOT write `GLOBAL.X` inside `scripts/` files.
- The pure module `scripts/partyhud_avatar.lua` must keep ZERO engine dependencies (busted runs it with no engine) — it returns numbers/booleans/strings only; the widget owns every engine call (`GetPlayerBadgeData` / `GetSkinData` / `SetSkinsOnAnim` / `SetTexture` / `classify` list reads).
- No new `modinfo.lua` config option. The avatar-style dropdown (off=0 / corner=1 / centre=2, default 2) is unchanged.
- `base_skin` rendering must never require the receiver to OWN the skin and must never crash on an invalid/unresolvable skin (fall back to `prefab.."_none"`, then `wilson_none`).
- Static gates that must stay green: `luacheck .` (0/0), `luajit spec/run_local.lua` (N passed, 0 failed, incl. the layout-snapshot goldens), `stylua --check .`.
- Work on `master` (the entire v2026.11 line is committed directly to master; user consented to this branch for this feature).

---

### Task 1: Pure helpers — `head_renderable` + `avatar_head_corner_geom`

Add the two pure functions (and their constants) that let the widget decide anim-vs-flat and compute the corner head geometry. These are the only unit-testable pieces of the feature.

**Files:**
- Modify: `scripts/partyhud_avatar.lua` (add after `avatar_head_geom`, ~line 179)
- Test: `spec/avatar_spec.lua` (add two new `describe` blocks)

**Interfaces:**
- Consumes: nothing (pure module, leaf functions).
- Produces:
  - `M.head_renderable(classify_result)` → `boolean` — `true` iff `classify_result == "base"` or `"random"`.
  - `M.avatar_head_corner_geom(base_scale, corner_fit, corner_x, corner_y)` → `scale, x, y` (three numbers). `corner_fit` defaults to `M.AVATAR_HEAD_CORNER_FIT`, `corner_x` to `M.AVATAR_HEAD_CORNER_X`, `corner_y` to `M.AVATAR_HEAD_CORNER_Y`. `base_scale` nil → 0.
  - Constants `M.AVATAR_HEAD_CORNER_FIT` (0.35), `M.AVATAR_HEAD_CORNER_X` (-20), `M.AVATAR_HEAD_CORNER_Y` (18) — provisional, tuned in-engine in Task 4.

- [ ] **Step 1: Write the failing tests**

Add to `spec/avatar_spec.lua` (after the `avatar_head_geom` describe block, ~line 253). The `near(a, b)` float-compare helper is already defined at the top of the file and used by the existing `avatar_head_geom` tests.

```lua
describe("partyhud_avatar — head_renderable", function()
  -- The animated head can only be built/skinned for a real character build; mod/unknown prefabs
  -- have no resolvable build on the receiver, so the widget falls back to the flat atlas image.
  it("base character -> true", function()
    assert.is_true(M.head_renderable("base"))
  end)
  it("'random' -> true (rendered like a real character)", function()
    assert.is_true(M.head_renderable("random"))
  end)
  it("mod character -> false (flat-atlas fallback)", function()
    assert.is_false(M.head_renderable("mod"))
  end)
  it("unknown_named -> false", function()
    assert.is_false(M.head_renderable("unknown_named"))
  end)
  it("unknown -> false", function()
    assert.is_false(M.head_renderable("unknown"))
  end)
  it("nil -> false", function()
    assert.is_false(M.head_renderable(nil))
  end)
end)

describe("partyhud_avatar — avatar_head_corner_geom", function()
  -- Corner preset for the animated head: shrink the raw GetPlayerBadgeData scale by corner_fit and
  -- place the head at an absolute (corner_x, corner_y) top-left inset (NOT derived from the scoreboard
  -- y_offset, unlike the centre geom). Defaults: FIT 0.35, X -20, Y 18.
  it("defaults are applied when fit/x/y are nil", function()
    local s, x, y = M.avatar_head_corner_geom(0.23)
    assert.is_true(near(s, 0.23 * 0.35)) -- 0.0805
    assert.is_true(near(x, -20))
    assert.is_true(near(y, 18))
  end)
  it("explicit fit/x/y override the defaults", function()
    local s, x, y = M.avatar_head_corner_geom(0.23, 0.4, -15, 22)
    assert.is_true(near(s, 0.23 * 0.4)) -- 0.092
    assert.is_true(near(x, -15))
    assert.is_true(near(y, 22))
  end)
  it("nil base_scale -> scale 0, position still applied", function()
    local s, x, y = M.avatar_head_corner_geom(nil, 0.4, -15, 22)
    assert.is_true(near(s, 0))
    assert.is_true(near(x, -15))
    assert.is_true(near(y, 22))
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `luajit spec/run_local.lua`
Expected: FAIL — `attempt to call field 'head_renderable' (a nil value)` (and likewise `avatar_head_corner_geom`).

- [ ] **Step 3: Implement the helpers**

In `scripts/partyhud_avatar.lua`, insert immediately after the `avatar_head_geom` function (after line 179, before the `M.GREY` block):

```lua
-- Whether a classify bucket yields a build the animated head can render. Only "base" / "random"
-- characters have a resolvable character build (+ skin) on the receiver; "mod" / "unknown_named" /
-- "unknown" do not (a mod character the receiver lacks, or no character at all), so the widget falls
-- back to the always-loaded flat avatar atlas for those. Pure boolean; nil -> false.
function M.head_renderable(classify_result)
  return classify_result == "base" or classify_result == "random"
end

-- Corner preset for the animated head. Unlike avatar_head_geom (centre), the corner position is an
-- absolute top-left inset, NOT derived from the scoreboard y_offset: the corner head just needs to sit
-- inside the ring's top-left, so we take only the raw base_scale (shrunk by corner_fit) and place it at
-- (corner_x, corner_y). Returns scale, x, y. nil base_scale -> 0; nil fit/x/y -> the module constants.
M.AVATAR_HEAD_CORNER_FIT = 0.35
M.AVATAR_HEAD_CORNER_X = -20
M.AVATAR_HEAD_CORNER_Y = 18

function M.avatar_head_corner_geom(base_scale, corner_fit, corner_x, corner_y)
  base_scale = base_scale or 0
  corner_fit = corner_fit or M.AVATAR_HEAD_CORNER_FIT
  corner_x = corner_x or M.AVATAR_HEAD_CORNER_X
  corner_y = corner_y or M.AVATAR_HEAD_CORNER_Y
  return base_scale * corner_fit, corner_x, corner_y
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `luajit spec/run_local.lua`
Expected: PASS — all new assertions green, full suite still `N passed, 0 failed` (including the layout-snapshot goldens, which this change does not touch).

- [ ] **Step 5: luacheck + stylua, then commit**

Run: `luacheck scripts/partyhud_avatar.lua spec/avatar_spec.lua` (expect 0 warnings / 0 errors) and `stylua --check scripts/partyhud_avatar.lua spec/avatar_spec.lua` (expect exit 0; if not, run `stylua` on them and re-review).

```bash
git add scripts/partyhud_avatar.lua spec/avatar_spec.lua
git commit -m "avatars: add head_renderable + avatar_head_corner_geom pure helpers

Decision + geometry for the unified animated-head avatar: head_renderable
gates anim-vs-flat (base/random vs mod/unknown), avatar_head_corner_geom
gives the corner preset (scale shrink + absolute top-left inset). Constants
provisional, tuned in-engine.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Widget — unify `SetAvatar` on the animated head + `base_skin`

Restructure `PartyBadge:SetAvatar` so a renderable character renders the animated head (skinned via `base_skin`) at the active style's geometry, and a non-renderable character renders the flat atlas image at the active style's geometry. Thread `base_skin` through identity + build. This is engine-bound (no busted); it is verified by luacheck here and the in-engine smoke in Task 4.

**Files:**
- Modify: `scripts/widgets/partybadge.lua` — the constants block (~line 44-49), the `SetAvatar` function (lines 286-394), and the class-static head-fit overrides + `SetHeadFitOverride` (~line 436+).

**Interfaces:**
- Consumes: `partyhud_avatar.head_renderable`, `partyhud_avatar.avatar_head_corner_geom`, `partyhud_avatar.avatar_head_geom`, `partyhud_avatar.classify`, `partyhud_avatar.atlas_and_tex`, `partyhud_avatar.identity_changed` (all from `avatarmath`, already `require`d at line 17). Engine globals already used in this file: `GetPlayerBadgeData`, `GetSkinData`, `SetSkinsOnAnim`, `Profile`, `DST_CHARACTERLIST`, `MODCHARACTERLIST`, `MOD_AVATAR_LOCATIONS`, `UIAnim`, `Image`, `FACING_DOWN`.
- Produces: `PartyBadge:SetAvatar(prefab, idflags, is_foreign, base_skin)` — a NEW 4th param `base_skin` (string|nil). Task 3 (modmain) calls it with this signature. Also new class statics `PartyBadge._head_corner_fit/_head_corner_x/_head_corner_y` and `PartyBadge.SetHeadCornerOverride(fit, x, y)` consumed by Task 3's console tuner.

- [ ] **Step 1: Add the flat-in-centre geometry constants**

In `scripts/widgets/partybadge.lua`, after the existing corner constants (line 49), add:

```lua
-- v2026.11 flat-avatar centre preset: a non-renderable (mod/unknown) character cannot build the
-- animated head, so in the CENTRE style it shows the flat atlas image scaled up + centred (vs the
-- corner preset above). Provisional; the common case (base/random characters) uses the animated head.
local AVATAR_FLAT_CENTRE_SCALE = 1.0
local AVATAR_FLAT_CENTRE_Y = -4
```

- [ ] **Step 2: Replace the `SetAvatar` body**

Replace the entire `SetAvatar` function (lines 286-394, from `function PartyBadge:SetAvatar(prefab, idflags, is_foreign)` through its closing `end` at line 394) with the unified version below. It keeps the lazy-create + alpha + `identity_changed` gating, but routes by `head_renderable` instead of by style, and applies style-specific geometry inside each render path. The centre HP-number / z-order handling is hoisted out so it applies whenever the avatar occupies the centre, regardless of anim-or-flat.

```lua
-- v2026.11: render the teammate's avatar for the current style, reflecting their base_skin. Called per
-- refresh from UpdateBadges.
--   prefab    : character prefab string (local v.prefab, or the GetClientTable record prefab); nil -> unknown
--   idflags   : packed ghost + character-state bits (avatarmath.packidflags / a raw userflags int)
--   is_foreign: dims to FOREIGN_ALPHA (data ~1s stale), matching the rest of the badge
--   base_skin : the player's character skin id (GetClientTable().base_skin), e.g. "wilson_formal";
--               nil/"" -> the plain prefab.."_none" head. Reflected in BOTH centre and corner styles.
-- A renderable character (classify base/random) uses the animated head at the active style's geometry;
-- a non-renderable one (mod/unknown) uses the flat atlas image (crash-proof always-loaded fallback) at
-- the active style's geometry. SetAvatar is a no-op when style == "off". Children are created lazily so
-- an "off" badge pays nothing. identity_changed (which already compares base_skin) gates the texture/anim
-- rebuild; alpha is always re-asserted (foreign flip is cheap).
function PartyBadge:SetAvatar(prefab, idflags, is_foreign, base_skin)
  self._last_avatar_args = { prefab = prefab, idflags = idflags, is_foreign = is_foreign, base_skin = base_skin }
  if self.avatar_style == "off" then
    self:_HideAvatars()
    return
  end
  local a = (is_foreign and FOREIGN_ALPHA) or FULL_ALPHA
  local new_identity = { prefab = prefab, idflags = idflags or 0, base_skin = base_skin }
  local changed = avatarmath.identity_changed(self._avatar_identity, new_identity)
  local style = self.avatar_style

  -- classify (engine character lists) decides anim-vs-flat; delegate the bucket -> boolean to the module.
  local cls = avatarmath.classify(prefab, DST_CHARACTERLIST, MODCHARACTERLIST)
  if avatarmath.head_renderable(cls) then
    self:_RenderAvatarHead(prefab, idflags, base_skin, a, changed, style)
    if self.avatar_corner ~= nil then
      self.avatar_corner:Hide()
    end
  else
    self:_RenderAvatarFlat(prefab, cls, a, changed, style)
    if self.avatar_head ~= nil then
      self.avatar_head:Hide()
    end
  end

  -- Centre occupancy: whichever child is in the centre covers self.num + the thermal arrow. Keep the HP
  -- number drawn ABOVE the avatar (MoveToFront re-appends it to the end of the shared parent's child list)
  -- and force it hover-only so the face is unobstructed. The corner styles leave the centre clear, so the
  -- HP number follows its configured visibility (restored on leaving centre by _apply_effective_style).
  -- Source of truth for the centre stack: partyhud_badge.layer_order("centre").
  if style == "centre" then
    self.num:MoveToFront()
    if not self._hp_number_was_hover then
      self._hp_number_was_hover = true
      self:_apply_hp_number_visibility(true)
    end
  end
  self._avatar_identity = new_identity
end

-- v2026.11: build/show the animated UIAnim head, skinned via base_skin, at the active style's geometry
-- (centre = avatar_head_geom; corner = avatar_head_corner_geom). Lazy-creates the child on first use.
function PartyBadge:_RenderAvatarHead(prefab, idflags, base_skin, a, changed, style)
  if self.avatar_head == nil then
    -- animated head child, ported from playerbadge.lua:_SetupHeads + Set. Parented to the badge so it
    -- draws above the ring fill; clickable off (purely cosmetic). SetFacing is a UIAnim method; the
    -- symbol Hide() calls are on the animstate (matches playerbadge.lua:36-42).
    self.avatar_head = self:AddChild(UIAnim())
    self.avatar_head:SetFacing(FACING_DOWN)
    self.avatar_head:GetAnimState():Hide("ARM_carry")
    self.avatar_head:GetAnimState():Hide("HAIR_HAT")
    self.avatar_head:GetAnimState():Hide("HEAD_HAT")
    self.avatar_head:GetAnimState():Hide("HEAD_HAT_NOHELM")
    self.avatar_head:GetAnimState():Hide("HEAD_HAT_HELM")
    self.avatar_head:SetClickable(false)
  end
  if changed then
    local f = avatarmath.unpackidflags(idflags)
    -- GetPlayerBadgeData (skinsutils.lua:1903) -> bank/anim/skin_mode/scale/y_offset for this character's
    -- ghost / were / stage pose. nil/unknown prefab is not reached here (head_renderable gated it out).
    local bank, animation, skin_mode, scale, y_offset =
      GetPlayerBadgeData(prefab, f.ghost, f.state1, f.state2, f.state3)
    local hs = self.avatar_head:GetAnimState()
    hs:SetBank(bank)
    hs:PlayAnimation(animation, true)
    -- per-badge perf parity with the vanilla scoreboard: animate only if the profile enables it, else
    -- freeze on frame 0. bare Profile (NOT GLOBAL.Profile): partybadge runs in full _G.
    if Profile ~= nil and Profile.GetAnimatedHeadsEnabled ~= nil and Profile:GetAnimatedHeadsEnabled() then
      hs:SetTime(math.random() * 1.5)
    else
      hs:SetTime(0)
      hs:Pause()
    end
    -- geometry per style: centre shrinks scale + scoreboard y_offset to fit the ring; corner shrinks
    -- scale + places the head at an absolute top-left inset. Re-read the class overrides each rebuild so
    -- a console tuner change is picked up (this block runs when _avatar_identity was cleared -> changed).
    if style == "corner" then
      local s, x, y = avatarmath.avatar_head_corner_geom(
        scale,
        PartyBadge._head_corner_fit,
        PartyBadge._head_corner_x,
        PartyBadge._head_corner_y
      )
      self.avatar_head:SetScale(s)
      self.avatar_head:SetPosition(x, y, 0)
    else
      local s, yo = avatarmath.avatar_head_geom(scale, y_offset, PartyBadge._head_fit, PartyBadge._head_ynudge)
      self.avatar_head:SetScale(s)
      self.avatar_head:SetPosition(0, yo, 0)
    end
    -- base build / skin: GetSkinData(base_skin or prefab.."_none") -> skins[skin_mode]; SetSkinsOnAnim
    -- (components/skinner.lua:11, a GLOBAL) puts the base build on the anim. An invalid/unresolvable skin
    -- -> GetSkinData nil -> base_build stays prefabname (today's safe fallback). Skin builds are shipped
    -- assets, so rendering does not require owning the skin.
    local prefabname = (prefab ~= nil and prefab ~= "" and prefab) or "wilson"
    local skin = (base_skin ~= nil and base_skin ~= "" and base_skin) or (prefabname .. "_none")
    local skindata = GetSkinData(skin)
    local base_build = prefabname
    if skindata ~= nil and skindata.skins ~= nil then
      base_build = skindata.skins[skin_mode] or prefabname
    end
    SetSkinsOnAnim(hs, prefabname, base_build, {}, nil, skin_mode)
  end
  self.avatar_head:GetAnimState():SetMultColour(1, 1, 1, a)
  self.avatar_head:Show()
end

-- v2026.11: build/show the flat atlas image (crash-proof fallback for mod/unknown characters) at the
-- active style's geometry (corner = small top-left inset; centre = scaled-up + centred). Lazy-creates.
function PartyBadge:_RenderAvatarFlat(prefab, cls, a, changed, style)
  if self.avatar_corner == nil then
    self.avatar_corner = self:AddChild(Image(avatarmath.DEFAULT_ATLAS, "avatar_unknown.tex"))
    self.avatar_corner:SetClickable(false)
  end
  if changed then
    -- classify already computed by the caller; resolve atlas/tex via the pure module (the flat atlas is
    -- always loaded, so a far/mod teammate shows a generic head, never blank/crash).
    local atlas, tex = avatarmath.atlas_and_tex(prefab, cls, MOD_AVATAR_LOCATIONS)
    self.avatar_corner:SetTexture(atlas, tex)
  end
  if style == "centre" then
    self.avatar_corner:SetScale(AVATAR_FLAT_CENTRE_SCALE)
    self.avatar_corner:SetPosition(0, AVATAR_FLAT_CENTRE_Y, 0)
  else
    self.avatar_corner:SetScale(AVATAR_CORNER_SCALE)
    self.avatar_corner:SetPosition(AVATAR_CORNER_X, AVATAR_CORNER_Y, 0)
  end
  self.avatar_corner:SetTint(1, 1, 1, a)
  self.avatar_corner:Show()
end
```

- [ ] **Step 3: Add the corner head-fit class statics + override setter**

Find the existing centre head-fit override block (`PartyBadge._head_fit` / `_head_ynudge` + `function PartyBadge.SetHeadFitOverride`, ~line 436-460). Immediately after the `SetHeadFitOverride` function, add the corner equivalents:

```lua
-- v2026.11 corner-avatar head geometry overrides (CLASS-level statics, shared by every badge). nil ->
-- avatar_head_corner_geom's constant defaults. Tuned at runtime via PartyHud_AvatarHeadCornerFit.
PartyBadge._head_corner_fit = nil
PartyBadge._head_corner_x = nil
PartyBadge._head_corner_y = nil

function PartyBadge.SetHeadCornerOverride(fit, x, y)
  PartyBadge._head_corner_fit = fit
  PartyBadge._head_corner_x = x
  PartyBadge._head_corner_y = y
end
```

- [ ] **Step 4: luacheck**

Run: `luacheck scripts/widgets/partybadge.lua`
Expected: 0 warnings / 0 errors. (If luacheck flags `_RenderAvatarHead`/`_RenderAvatarFlat` as defined-but-unused, ignore — they are methods called via `self:`. If it flags the `style`/`a` params, confirm they are used; they are.)

- [ ] **Step 5: stylua + busted regression, then commit**

Run: `stylua --check scripts/widgets/partybadge.lua` (exit 0; else `stylua` it and re-review) and `luajit spec/run_local.lua` (the pure suite must still be `N passed, 0 failed` — the widget is not unit-tested but the layout-snapshot goldens must remain green since geometry constants for layout are untouched).

```bash
git add scripts/widgets/partybadge.lua
git commit -m "avatars: unify SetAvatar on the animated head + reflect base_skin

Renderable characters (base/random) now render the animated head in BOTH
styles via base_skin (centre = avatar_head_geom, corner = corner preset);
mod/unknown fall back to the flat atlas image at the style's geometry. HP
number / z-order centre handling hoisted to apply for anim or flat. Adds the
corner head-fit class statics + SetHeadCornerOverride. Engine-bound; verified
by luacheck + the in-engine smoke.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: modmain wiring — gather `base_skin` + console tuner

Read `base_skin` from the cluster roster and pass it to both `SetAvatar` call sites; add the runtime corner-geometry tuner. Engine-bound (modmain sandbox); verified by luacheck + the in-engine smoke.

**Files:**
- Modify: `modmain.lua` — the cluster-roster gather (~line 568-580), the local `SetAvatar` call (~line 617), the foreign `SetAvatar` call (~line 717), and a new console fn near `PartyHud_AvatarHeadFit` (~line 412-426).

**Interfaces:**
- Consumes: `PartyBadge.SetHeadCornerOverride(fit, x, y)` and the new `SetAvatar(prefab, idflags, is_foreign, base_skin)` signature from Task 2; `phud_custombadge` is the badge class alias already in scope (used by `PartyHud_AvatarHeadFit` via `phud_custombadge.SetHeadFitOverride`).
- Produces: `GLOBAL.PartyHud_AvatarHeadCornerFit(fit, x, y)` console fn.

- [ ] **Step 1: Gather `base_skin` into the cluster roster**

In `modmain.lua`, the roster maps are declared at line 568:

```lua
local namebyuserid, prefabbyuserid, colourbyuserid, userflagsbyuserid = {}, {}, {}, {}
```

Change it to add `base_skinbyuserid`:

```lua
local namebyuserid, prefabbyuserid, colourbyuserid, userflagsbyuserid, base_skinbyuserid = {}, {}, {}, {}, {}
```

Then inside the `for _, c in ipairs(ct) do` loop (after line 577 `userflagsbyuserid[c.userid] = c.userflags or 0`), add:

```lua
            base_skinbyuserid[c.userid] = c.base_skin
```

- [ ] **Step 2: Pass `base_skin` to the local SetAvatar call**

At ~line 617, change:

```lua
        b:SetAvatar(v.prefab or prefabbyuserid[v.userid], userflagsbyuserid[v.userid] or 0, false)
```

to:

```lua
        b:SetAvatar(v.prefab or prefabbyuserid[v.userid], userflagsbyuserid[v.userid] or 0, false, base_skinbyuserid[v.userid])
```

- [ ] **Step 3: Pass `base_skin` to the foreign SetAvatar call**

At ~line 717, change:

```lua
          b:SetAvatar(prefabbyuserid[rec.userid], userflagsbyuserid[rec.userid] or 0, true)
```

to:

```lua
          b:SetAvatar(prefabbyuserid[rec.userid], userflagsbyuserid[rec.userid] or 0, true, base_skinbyuserid[rec.userid])
```

- [ ] **Step 4: Add the `PartyHud_AvatarHeadCornerFit` console tuner**

After the `PartyHud_AvatarHeadFit` function + its closing `-- luacheck: pop` (~line 427), add:

```lua
-- [DEBUG/util] runtime corner-avatar head geometry tuner from the client console, no reconnect needed:
--   PartyHud_AvatarHeadCornerFit(fit, x, y)  -> scale + position the corner head inside the ring corner
-- Mirrors PartyHud_AvatarHeadFit. `fit` multiplies the raw GetPlayerBadgeData scale; x/y is the absolute
-- top-left inset. All nil -> avatar_head_corner_geom's constant defaults. Clears each live badge's cached
-- avatar identity so the next UpdateBadges rebuilds with the new geom. Client-only (no-op on a dedicated
-- server where ThePlayer/HUD are nil). Returns fit, x, y.
-- luacheck: push ignore 122
GLOBAL.PartyHud_AvatarHeadCornerFit = function(fit, x, y)
  phud_custombadge.SetHeadCornerOverride(fit, x, y)
  local p = _G.ThePlayer
  local sd = p ~= nil and p.HUD ~= nil and p.HUD.controls ~= nil and p.HUD.controls.status or nil
  if sd ~= nil and sd.badgearray ~= nil then
    for _, b in ipairs(sd.badgearray) do
      b._avatar_identity = nil -- force SetAvatar to re-run its `changed` block and re-apply the geom
    end
    if p.UpdateBadges ~= nil then
      p.UpdateBadges()
    end
  end
  print("[PartyHud] avatar corner fit = " .. tostring(fit) .. " x = " .. tostring(x) .. " y = " .. tostring(y))
  return fit, x, y
end
-- luacheck: pop
```

- [ ] **Step 5: luacheck + stylua, then commit**

Run: `luacheck modmain.lua` (0/0) and `stylua --check modmain.lua` (exit 0; else `stylua` it).

```bash
git add modmain.lua
git commit -m "avatars: wire base_skin from cluster roster + corner geom tuner

Gather base_skinbyuserid from GetClientTable and pass it to both SetAvatar
call sites (local + foreign) so the avatar reflects each teammate's skin
cluster-wide. Add PartyHud_AvatarHeadCornerFit console tuner mirroring
PartyHud_AvatarHeadFit for in-engine corner-head positioning.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Static gates + in-engine smoke on modtest

Prove the full suite is green and verify the engine-bound behaviour on the live test server (the only way to test the widget half). This task has no code of its own unless the smoke surfaces a defect (then fix + re-verify).

**Files:**
- None (verification). Any fix lands in the relevant file from Tasks 1-3 with its own commit.

**Interfaces:**
- Consumes: the committed Tasks 1-3 changes.
- Produces: a verified, ship-ready avatar-skin feature on `master`.

- [ ] **Step 1: Full static gates**

Run from the repo root:
- `luacheck .` → expect `0 warnings / 0 errors`.
- `luajit spec/run_local.lua` → expect `N passed, 0 failed` (the new pure tests + the unchanged layout-snapshot goldens).
- `stylua --check .` → expect exit 0.

If `stylua --check` must run on the hub host, use a modern container with seccomp disabled (old Docker 18.09 panics the threadpool otherwise):
`docker run --rm -v "$PWD":/w -w /w --security-opt seccomp=unconfined ubuntu:22.04 bash -c '<stylua install/run>'`.

- [ ] **Step 2: Crash-safety audit of the diff**

Invoke the repo skill `.claude/skills/dst-mod-crash-audit/SKILL.md` against `git diff <last-task-base>..HEAD` for the three changed files, and `.claude/skills/dst-badge-visual-audit/SKILL.md` (this changed badge/HUD visuals). Resolve any HIGH-confidence finding before the smoke.

- [ ] **Step 3: Push the build to the beta/modtest channel**

Use skill `partyhud-beta-upload` (`/home/iblis/code/dst/.claude/skills/partyhud-beta-upload/SKILL.md`): sync `~/partyhud-fork` to the current master, copy the WHOLE `scripts/` tree (not cherry-picked — a missing `require`d module fails the load), bump `version=` in the beta content's `modinfo.lua` to a fresh `2026.11bN`, and upload via the cached SteamCMD login. Then sync the modtest server's local mod copy + restart the shard if needed (per memory `dst-modtest-console-tools`).

- [ ] **Step 4: In-engine verification (connected player, per spec §Testing)**

With a player connected to `dst-modtest`, exercise each behaviour (use the hub console tools — `tools/dst-thermal`, the dummy-spawn recipe, and `PartyHud_AvatarStyle`/`PartyHud_AvatarHeadCornerFit` from the client console):

1. **corner style + skin** — `PartyHud_AvatarStyle("corner")`: the animated head shows in the corner; equip a character skin on a connected player (or set `base_skin`) → the corner head reflects it.
2. **mod/unknown in corner** — a dummy/teammate with a mod or unknown prefab still shows the flat generic head (no blank/crash).
3. **centre style** — `PartyHud_AvatarStyle("centre")`: pose/scale unchanged from before (regression) AND the skin reflects.
4. **thermal flip** — in centre style, `dst-thermal <idx> cold` (or fire): the head moves to the corner (skinned), the centre frees for the HP-rate arrow; clears back to centre when thermal ends.
5. **foreign/cross-shard** — a teammate on the other shard reflects their skin (base_skin from the cluster roster).
6. **tune** — adjust the corner head with `PartyHud_AvatarHeadCornerFit(fit, x, y)` until it sits cleanly inside the top-left of the ring. If the provisional constants in Task 1 (`AVATAR_HEAD_CORNER_FIT/X/Y`) or Task 2 (`AVATAR_FLAT_CENTRE_SCALE/Y`) need changing, update them in source, commit, and re-smoke.

- [ ] **Step 5: Record the verified state**

Confirm: full suite green, all six in-engine checks pass, working tree clean on `master`. The feature is then ready to fold into the v2026.11 ship (Task #93 — preflight → tag → public Workshop + prod). Note any final tuned constant values in the commit message.

---

## Self-Review

**1. Spec coverage:**
- "reflect base_skin in both styles" → Tasks 2 (`_RenderAvatarHead` uses base_skin in centre+corner) + 3 (plumbing). ✓
- "unify on animated head, flat fallback for mod/unknown" → Task 2 (`head_renderable` routing). ✓
- "base_skin cluster-wide from GetClientTable, foreign too" → Task 3 (gather + both call sites). ✓
- "defensive skin resolution, no crash, no ownership needed" → Task 2 Step 2 (`GetSkinData` nil → fallback). ✓
- "corner geometry helper + console tuner" → Task 1 (`avatar_head_corner_geom`) + Task 3 (`PartyHud_AvatarHeadCornerFit`). ✓
- "head_renderable predicate" → Task 1. ✓
- "no new config; centre default unchanged" → Global Constraints + no modinfo task. ✓
- "z-order/HP-number: centre unchanged, corner follows config" → Task 2 Step 2 (centre block hoisted). ✓
- "layout snapshot unaffected" → Task 1 Step 4 / Task 2 Step 5 assert goldens stay green. ✓
- "verification: unit for pure, in-engine for widget" → Task 1 (busted) + Task 4 (in-engine). ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows full code; provisional constants are explicitly tuned in Task 4 Step 6 (not a placeholder gap — a deliberate in-engine tuning loop). ✓

**3. Type consistency:** `SetAvatar(prefab, idflags, is_foreign, base_skin)` used identically in Task 2 (def) and Task 3 (both calls). `head_renderable` / `avatar_head_corner_geom` / `SetHeadCornerOverride` names match between defining and consuming tasks. `_RenderAvatarHead`/`_RenderAvatarFlat` defined and called in Task 2. ✓
