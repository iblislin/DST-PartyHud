-- [PATCHED for DST 736959] ported to modern circular Badge widget.
-- Original (brianchenito/PartyHud v0.985, 2016) used Badge._ctor(self,"health",owner)
-- which loaded a now-renamed build ("health" -> "status_health") => invisible heart.
-- v2026.6: added hunger/sanity sub-rings (status_hunger gold, status_sanity orange) in a
-- small row below the main HP ring, plus an on-fire warning pulse on the main ring.
local Badge = require("widgets/badge")
local Text = require("widgets/text")
local Image = require("widgets/image")
local UIAnim = require("widgets/uianim")
-- v2026.11: pure badge colour / predicate math (frame_colour + is_low_hp + the colour constants),
-- extracted so it can be busted-tested with zero engine deps. The widget reads its live state and
-- delegates the arithmetic here, keeping ownership of the engine calls.
local badgemath = require("partyhud_badge")
-- v2026.11: pure avatar / name-colour decision logic (classify + atlas/tex fallback + idflags +
-- name_colour reconciliation), extracted so it can be busted-tested with zero engine deps. The widget
-- reads its live state (player colour, foreign flag) and delegates the arithmetic here.
local avatarmath = require("partyhud_avatar")

-- canonical DST badge tints (from widgets/healthbadge.lua, hungerbadge.lua, sanitybadge.lua):
-- health red, hunger gold, sanity ORANGE (the blue {191,232,240} is the lunacy variant, not normal sanity)
local HEALTHBADGE_TINT = { 174 / 255, 21 / 255, 21 / 255, 1 }
local HUNGER_TINT = { 255 / 255, 204 / 255, 51 / 255, 1 }
local SANITY_TINT = { 232 / 255, 123 / 255, 15 / 255, 1 }
-- main-ring warning-pulse colours, by priority (a player can't be in two of these at once)
local ONFIRE_TINT = { 1, 0.45, 0, 1 } -- on fire (orange)
local OVERHEAT_TINT = { 1, 0.1, 0.1, 1 } -- overheating (red)
local FREEZE_TINT = { 0.4, 0.8, 1, 1 } -- freezing (cyan)

-- sanity rate (RATE_SCALE enum) -> sanity_arrow animation; NEUTRAL(0) shows no arrow
local SANITY_RATE_ANIM = {
  [1] = "arrow_loop_increase_most", -- INCREASE_HIGH
  [2] = "arrow_loop_increase_more", -- INCREASE_MED
  [3] = "arrow_loop_increase", -- INCREASE_LOW
  [4] = "arrow_loop_decrease_most", -- DECREASE_HIGH
  [5] = "arrow_loop_decrease_more", -- DECREASE_MED
  [6] = "arrow_loop_decrease", -- DECREASE_LOW
}

-- sub-ring layout (relative to the main HP ring at 0,0)
local SUB_SCALE = 0.5
local SUB_Y = -42
local SUB_X = 17

-- v2026.11 corner avatar: a small flat head inset in the badge's top-LEFT corner so it does not collide
-- with the HP number (centre) or the sub-rings (bottom). Scale + offset visually tuned to sit just
-- inside the ring backing. The foreign-label (+50) / name (+40) sit above and do not overlap.
local AVATAR_CORNER_SCALE = 0.45
local AVATAR_CORNER_X = -20
local AVATAR_CORNER_Y = 18

-- v2026.11 flat-avatar centre preset: a non-renderable (mod/unknown) character cannot build the
-- animated head, so in the CENTRE style it shows the flat atlas image scaled up + centred (vs the
-- corner preset above). Provisional; the common case (base/random characters) uses the animated head.
local AVATAR_FLAT_CENTRE_SCALE = 1.0
local AVATAR_FLAT_CENTRE_Y = -4

local PartyBadge = Class(Badge, function(self, owner)
  -- modern health badge: anim=nil -> status_meter path; iconbuild "status_health"
  -- overrides the heart icon onto the frame; red tint; dont_update_while_paused=true
  Badge._ctor(self, nil, owner, HEALTHBADGE_TINT, "status_health", nil, nil, true)

  -- player name label above the badge
  self.name = self:AddChild(Text(BODYTEXTFONT, 20))
  self.name:SetHAlign(ANCHOR_MIDDLE)
  self.name:SetPosition(0, 40, 0)
  self.name:SetString("--")

  -- v2026.6 hunger sub-ring (gold), below-left of the main ring.
  -- Its absolute number is shown only on hover (default Badge focus behaviour).
  self.hungerbadge = self:AddChild(Badge(nil, owner, HUNGER_TINT, "status_hunger", nil, nil, true))
  self.hungerbadge:SetScale(SUB_SCALE)
  self.hungerbadge:SetPosition(-SUB_X, SUB_Y, 0)

  -- v2026.6 sanity sub-ring (orange), below-right of the main ring
  self.sanitybadge = self:AddChild(Badge(nil, owner, SANITY_TINT, "status_sanity", nil, nil, true))
  self.sanitybadge:SetScale(SUB_SCALE)
  self.sanitybadge:SetPosition(SUB_X, SUB_Y, 0)

  -- max-sanity penalty blackout overlay on the sanity sub-ring (same mechanism as the HP ring).
  self.sanitytopper = self.sanitybadge.underNumber:AddChild(UIAnim())
  self.sanitytopper:GetAnimState():SetBank("status_meter")
  self.sanitytopper:GetAnimState():SetBuild("status_meter")
  self.sanitytopper:GetAnimState():PlayAnimation("anim")
  self.sanitytopper:GetAnimState():SetMultColour(0, 0, 0, 1)
  self.sanitytopper:SetScale(1, -1, 1)
  self.sanitytopper:SetClickable(false)
  self.sanitytopper:GetAnimState():AnimateWhilePaused(false)
  self.sanitytopper:GetAnimState():SetPercent("anim", 1)

  -- v2026.6 sanity rate arrow (mirrors the game's sanity gauge up/down indicator)
  -- centered on the sanity sub-ring. Parented to the sub-ring's underNumber (NOT the badge
  -- directly) so it draws UNDER the sanity number -- the number stays readable on hover, exactly
  -- like the vanilla badges (healthbadge.lua:41 / sanitybadge.lua:37 add their arrow to underNumber).
  self.sanityarrow = self.sanitybadge.underNumber:AddChild(UIAnim())
  self.sanityarrow:GetAnimState():SetBank("sanity_arrow")
  self.sanityarrow:GetAnimState():SetBuild("sanity_arrow")
  self.sanityarrow:GetAnimState():PlayAnimation("neutral")
  self.sanityarrow:GetAnimState():AnimateWhilePaused(false)
  self.sanityarrow:SetClickable(false)
  self.sanityarrow:SetPosition(0, 0, 0)
  self.sanityarrow:Hide()
  self.sanityarrow_cur = nil

  -- max-HP penalty "blackout" overlay (mirrors vanilla healthbadge.topperanim): a black,
  -- vertically-flipped status_meter that darkens the lost-max region from the TOP. Driven in
  -- SetPercent. SetScale(1,-1,1) does the flip; SetPercent("anim",1) = no penalty initially.
  -- Created BEFORE hparrow so the arrow draws on top of the blackout (vanilla draw order:
  -- fill < topper < arrow < number).
  self.hptopper = self.underNumber:AddChild(UIAnim())
  self.hptopper:GetAnimState():SetBank("status_meter")
  self.hptopper:GetAnimState():SetBuild("status_meter")
  self.hptopper:GetAnimState():PlayAnimation("anim")
  self.hptopper:GetAnimState():SetMultColour(0, 0, 0, 1)
  self.hptopper:SetScale(1, -1, 1)
  self.hptopper:SetClickable(false)
  self.hptopper:GetAnimState():AnimateWhilePaused(false)
  self.hptopper:GetAnimState():SetPercent("anim", 1)

  -- v2026.7 HP rate arrow on the main ring: a down-arrow when losing HP to fire/overheat/
  -- freeze, shown together with the colour pulse (mirrors the game's heart badge arrow for
  -- those states). Independent of the sub-gauges toggle (this is HP, not a sub-gauge).
  -- Parented to underNumber so it draws UNDER the HP number (readable on hover), matching vanilla.
  self.hparrow = self.underNumber:AddChild(UIAnim())
  self.hparrow:GetAnimState():SetBank("sanity_arrow")
  self.hparrow:GetAnimState():SetBuild("sanity_arrow")
  self.hparrow:GetAnimState():PlayAnimation("neutral")
  self.hparrow:GetAnimState():AnimateWhilePaused(false)
  self.hparrow:SetClickable(false)
  -- scale 1.0 (full ring scale) to match the vanilla health badge's rate arrow, which is added
  -- at default scale (healthbadge.lua:41 -- no SetScale). 0.7 rendered visibly smaller than the
  -- game's arrow; align with the game UI.
  self.hparrow:SetScale(1)
  self.hparrow:SetPosition(0, 0, 0)
  self.hparrow:Hide()
  self.hparrow_cur = nil

  -- dead indicator
  self.dead = self:AddChild(Image("images/hud.xml", "tab_arcane.tex"))
  -- tab_arcane.tex draws its skull glyph off-center within its own texture bounds, so the geometric
  -- center (x=0) looks shifted right; nudge left to visually center it. Scale kept a touch under the
  -- ring so it doesn't overflow the backing. Both visually tuned.
  self.dead:SetPosition(-6, 0, 0)
  self.dead:SetScale(0.5)
  self.dead:Hide()

  -- whether the hunger/sanity sub-rings are shown (driven by the show_substatus config)
  self.subvisible = true

  -- HP number visibility flag (client config hp_number); real value applied via
  -- SetHPNumberAlways right after construct. Default true = always shown.
  self.hp_number_always = true

  -- v2026.8 cross-shard "elsewhere" treatment state. self.foreign tracks whether this slot is
  -- currently showing a far (other-shard) player; the label Text is created lazily by SetForeign.
  self.foreign = false
  self.foreignlabel = nil

  -- v2026.9 low-HP alert state. low_hp_threshold (0..1, 0 = disabled) is set after construct from
  -- the low_hp_alert config; the rest are driven by _set_low_hp / the blink task.
  self.low_hp_threshold = 0
  self.low_hp = false
  self._blink_t = 0 -- pulse phase accumulator (seconds); advanced in OnUpdate while low

  -- v2026.11 avatar + name-colour state. player_colour is the teammate's {r,g,b,a} (local
  -- v.playercolour, or the GetClientTable colour for a foreign player); nil until set per refresh.
  -- name_colour_enabled gates the feature (config name_colour); when false the name stays white-at-alpha
  -- exactly like pre-v2026.11. avatar_style is "off"/"corner"/"centre"; the avatar children are created
  -- lazily by SetAvatar. _avatar_identity caches the last-rendered {prefab, idflags} snapshot so
  -- SetAvatar can skip a rebuild when identity is unchanged (avatarmath.identity_changed). NOTE:
  -- identity_changed also accepts a base_skin field (future-proofing), but PartyHud does NOT track
  -- per-teammate skins -- base_build is derived as prefab.."_none", so a base-build change only happens
  -- on a prefab change (which IS in the snapshot); base_skin stays nil-vs-nil here (a no-op compare).
  self.player_colour = nil
  self.name_colour_enabled = false
  -- avatar_style_config is the CONFIGURED style (off/corner/centre) chosen via SetAvatarStyle;
  -- avatar_style is the EFFECTIVE (rendered) style SetAvatar reads. They differ only in the
  -- centre-config case while a thermal arrow is active: effective flips to "corner" so the head
  -- vacates the centre and the HP-rate arrow (self.hparrow) becomes visible. _apply_effective_style
  -- reconciles the two (avatarmath.effective_avatar_style); _thermal_active tracks the live thermal
  -- state (set in SetStatus); _last_avatar_args caches the last SetAvatar args so SetStatus can
  -- re-render the head<->corner swap the moment thermal toggles.
  self.avatar_style_config = "off"
  self.avatar_style = "off"
  self._thermal_active = false
  self._last_avatar_args = nil
  self.avatar_corner = nil -- flat Image child (corner style)
  self.avatar_head = nil -- animated UIAnim child (centre style)
  self._avatar_identity = nil
  self._hp_number_was_hover = false -- centre style forces the HP number hover-only; this tracks it
end)

-- v2026.8: dim alpha applied to every visible badge element when the slot shows a FOREIGN
-- (other-shard) player, so it reads as "muted / data is ~1s stale". RGB stays at each element's
-- base tint -- only alpha drops -- so hue (red HP / gold hunger / orange sanity) is preserved.
-- FOREIGN_ALPHA / FULL_ALPHA now live in partyhud_badge (busted-tested); aliased here for SetForeign.
local FOREIGN_ALPHA = badgemath.FOREIGN_ALPHA
local FULL_ALPHA = badgemath.FULL_ALPHA

-- v2026.9 low-HP alert: a blinking red ring border (circleframe) when a teammate's HP drops below a
-- player-chosen threshold. Distinct from the thermal warning pulse (self.warning) so both cues can
-- show at once. LOW_HP_TINT is brighter than the HP fill {174,21,21}/255 so it pops against the red
-- ring underneath. NOTE: circleframe's animstate also carries the heart ICON glyph
-- (OverrideSymbol("icon",...) in Badge._ctor), so SetMultColour tints the heart red too during the
-- alarm phase -- intended (a red heart reads as a health alarm). The low-HP constants + the breathe
-- arithmetic now live in partyhud_badge.frame_colour (busted-tested).

-- Apply a uniform alpha to a UIAnim's animstate while keeping its existing RGB. We re-assert the
-- base RGB explicitly (mult-colour is absolute, not cumulative) so a restore can't leave a stale
-- tint behind. r,g,b default to white for elements drawn untinted (the frame).
local function set_anim_alpha(uianim, a, r, g, b)
  if uianim == nil then
    return
  end
  uianim:GetAnimState():SetMultColour(r or 1, g or 1, b or 1, a)
end

-- Toggle the hunger/sanity sub-rings on/off (client config show_substatus). When disabled,
-- the badge collapses to the HP-only layout: both sub-rings + their numbers are hidden now.
function PartyBadge:SetSubGauges(enabled)
  self.subvisible = enabled
  if enabled then
    self.hungerbadge:Show()
    self.sanitybadge:Show()
  else
    self.hungerbadge:Hide()
    self.sanitybadge:Hide()
    self.sanityarrow:Hide()
    self.sanityarrow_cur = nil
  end
end

-- v2026.11: single-writer for the HP number's visibility, reconciling {hp_number_always config,
-- centre-style forced-hover-only}. Every site that wants to reveal/hide the HP number for this reason
-- routes through here (same single-writer model as _apply_name_colour / _apply_frame_colour) so the
-- guard `hp_number_always and not _hp_number_was_hover` can never be open-coded inconsistently again.
--   allow_hide=true  -> full apply: Show when the decision is "show", else Hide (the SetHPNumberAlways
--                       / leaving-centre / centre-forces-hover sites, which used to Show OR Hide).
--   allow_hide=false -> show-only: Show when the decision is "show", do NOTHING otherwise (the
--                       SetPercent / ShowBadge sites, which only ever :Show()'d and left the prior
--                       hover/default hide in place -- preserving that exact effect, no new forced Hide).
-- The dead-state hide in ShowDead is a separate concern (not driven by these flags) and stays inline.
function PartyBadge:_apply_hp_number_visibility(allow_hide)
  if self.num == nil then
    return
  end
  if self.hp_number_always and not self._hp_number_was_hover then
    self.num:Show()
  elseif allow_hide then
    self.num:Hide()
  end
end

-- Whether the main HP number is always shown, or only on hover (client config hp_number).
-- The HP ring fill is always visible either way; this only gates the number.
function PartyBadge:SetHPNumberAlways(always)
  self.hp_number_always = always
  self:_apply_hp_number_visibility(true) -- full apply: Show when configured-on, else Hide
end

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

-- v2026.11: hide both avatar children if they exist. The same two-line idiom appeared in SetAvatar's
-- "off" branch, HideBadge, and ShowDead; centralized here (behaviour-identical). Each child is created
-- lazily so the nil-guards stay.
function PartyBadge:_HideAvatars()
  if self.avatar_corner ~= nil then
    self.avatar_corner:Hide()
  end
  if self.avatar_head ~= nil then
    self.avatar_head:Hide()
  end
end

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
    -- INVARIANT: geometry lives inside `changed` because a style flip (centre<->corner) always arrives
    -- with changed=true -- _apply_effective_style nils _avatar_identity before re-rendering, so the head
    -- is always re-laid-out at the new style. If a future style change path skips that nil, move the
    -- geometry out of `changed` instead.
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

-- v2026.11: reconcile the EFFECTIVE (rendered) style from {configured style, thermal active} and apply
-- the side effects of a style CHANGE. The effective style is "corner" while centre-config + a thermal
-- arrow is active (so the head vacates the centre for the HP-rate arrow), else the configured style
-- (avatarmath.effective_avatar_style). Returns true iff the effective style actually changed (callers
-- use this to decide whether to re-render). When it changes: force a rebuild next SetAvatar by clearing
-- the cached identity, hide whichever child the new style does not use, and -- when leaving centre --
-- restore the configured HP-number visibility (centre forced it hover-only). This body is the old
-- SetAvatarStyle body, now keyed on the new EFFECTIVE self.avatar_style.
function PartyBadge:_apply_effective_style()
  local eff = avatarmath.effective_avatar_style(self.avatar_style_config, self._thermal_active)
  if eff == self.avatar_style then
    return false
  end
  self.avatar_style = eff
  self._avatar_identity = nil -- force the next SetAvatar to rebuild the texture/anim
  -- NOTE: since the v2026.11 unify, either child can serve either style (a mod/unknown char uses the flat
  -- avatar_corner even in centre; a renderable char uses avatar_head even in corner), so these hides NO
  -- LONGER mean "hide the unused child". They are a cheap pre-clean; SetAvatar is the AUTHORITATIVE
  -- show/hide -- it always re-runs after a style change (identity was nil'd -> changed) and unconditionally
  -- hides the non-active child for the resolved render path. Kept (not dropped) so the console
  -- SetAvatarStyle path, which need not be immediately followed by a refresh, never leaves a stale child up.
  if self.avatar_style ~= "corner" and self.avatar_corner ~= nil then
    self.avatar_corner:Hide()
  end
  if self.avatar_style ~= "centre" and self.avatar_head ~= nil then
    self.avatar_head:Hide()
  end
  -- leaving the centre style: restore the configured HP-number visibility (centre forced it hover-only).
  -- Clear the flag, then full-apply through the single-writer (Show when configured-on, else Hide) --
  -- same effect as the old SetHPNumberAlways(self.hp_number_always) call, without re-setting the config.
  if self.avatar_style ~= "centre" and self._hp_number_was_hover then
    self._hp_number_was_hover = false
    self:_apply_hp_number_visibility(true)
  end
  return true
end

-- v2026.11: set the CONFIGURED avatar render style ("off"/"corner"/"centre") from the client config,
-- then reconcile the effective style. With no thermal active this is behaviour-identical to the old
-- direct-set SetAvatarStyle (effective == config); while a centre-config teammate has thermal active,
-- _apply_effective_style yields "corner" so the head does not cover the HP-rate arrow.
function PartyBadge:SetAvatarStyle(style)
  self.avatar_style_config = style or "off"
  self:_apply_effective_style()
end

-- v2026.11 centre-avatar head-fit overrides (CLASS-level statics, shared by every badge). nil means
-- "use avatar_head_geom's constant defaults" (M.AVATAR_HEAD_FIT / M.AVATAR_HEAD_Y_NUDGE). The
-- PartyHud_AvatarHeadFit console fn sets these via SetHeadFitOverride to tune the centre head's size /
-- vertical placement in-engine without a reconnect; the centre rebuild path (SetAvatar's `changed`
-- block) re-reads them, so clearing each badge's _avatar_identity is enough to apply a new value.
PartyBadge._head_fit = nil
PartyBadge._head_ynudge = nil

-- Static setter for the centre-head fit overrides (called by modmain's debug console fn). Passing nil
-- for either argument restores that override to the helper's constant default. Class-level on purpose:
-- the fit is a global render-tuning knob, not per-teammate state.
function PartyBadge.SetHeadFitOverride(fit, ynudge)
  PartyBadge._head_fit = fit
  PartyBadge._head_ynudge = ynudge
end

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

-- cur = current HP (absolute), max = FULL max HP, penaltypercent = max-HP penalty (0..1).
-- The ring fills cur/FULLmax, so a penalized player no longer looks 100% full. The max-HP
-- penalty is drawn by the hptopper overlay (a black, vertically-flipped status_meter that
-- blacks out the lost-max region from the TOP, mirroring the vanilla heart badge) rather than
-- the base Badge bonusval/anim_bonus white-from-bottom arc.
function PartyBadge:SetPercent(cur, max, penaltypercent)
  cur = cur or 0 -- normalize once: cur feeds the ring fill AND the low-HP threshold compare below
  local m = (max ~= nil and max > 0) and max or 1
  Badge.SetPercent(self, cur / m, max)
  self.hptopper:GetAnimState():SetPercent("anim", 1 - (penaltypercent or 0))
  if self.num ~= nil then
    self.num:SetString(tostring(math.floor(cur + 0.5)))
  end
  -- honour the centre style's forced-hover-only: the single-writer re-shows the HP number only when
  -- hp_number_always and not _hp_number_was_hover, so a per-refresh SetPercent can't reveal it over the
  -- centre head (cleared by SetAvatarStyle when leaving centre, so corner/off get the number back).
  -- show-only (allow_hide=false): preserves the old site's "only ever :Show()'d" effect -- the focus/
  -- hover or config-off hide stays in place; no new forced Hide is introduced.
  self:_apply_hp_number_visibility(false)
  -- v2026.9 low-HP alert: blink the border below the configured threshold (fraction of max HP).
  -- 0 threshold = disabled. Runs for BOTH the local and the foreign path (the foreign render also
  -- calls SetPercent with the relayed hp_cur/hp_max), so far/cross-shard badges blink for free.
  -- The predicate is the pure badgemath.is_low_hp (cur/max already normalized above, but it re-applies
  -- the same nil/<=0 coercion so it stays correct in isolation).
  self:_set_low_hp(badgemath.is_low_hp(cur, max, self.low_hp_threshold))
end

-- v2026.6: hunger_cur/sanity_cur are absolute current values (the displayed number);
-- *_max give the absolute scale. The ring fill is computed from cur/max, and the sub-ring
-- number reads as the in-game absolute value (e.g. 113/150 -> "113"), matching the HP badge
-- and the game's own meters instead of a 0-100 percent.
-- onfire/overheating/freezing are bools -> a colour-coded warning pulse on the main HP
-- ring, by priority (mutually exclusive in practice). Sub-rings hide their number until hover.
function PartyBadge:SetStatus(
  hunger_cur,
  hunger_max,
  sanity_cur,
  sanity_max,
  onfire,
  overheating,
  freezing,
  sanity_penalty
)
  -- only update the sub-rings when enabled; the on-fire/overheat/freeze pulse on the main
  -- ring runs regardless (handled below). Sub-ring numbers stay hidden until hover.
  if self.subvisible then
    local hm = (hunger_max ~= nil and hunger_max > 0) and hunger_max or 1
    local sm = (sanity_max ~= nil and sanity_max > 0) and sanity_max or 1
    self.hungerbadge:SetPercent((hunger_cur or 0) / hm, hunger_max or 100)
    self.sanitybadge:SetPercent((sanity_cur or 0) / sm, sanity_max or 100)
    -- sanity_penalty (0..1) drives the sanitytopper blackout overlay (black-from-top), the
    -- same mechanism as the HP main ring, instead of the base Badge bonusval white arc.
    self.sanitytopper:GetAnimState():SetPercent("anim", 1 - (sanity_penalty or 0))
    if self.hungerbadge.num ~= nil then
      self.hungerbadge.num:SetString(tostring(math.floor((hunger_cur or 0) + 0.5)))
    end
    if self.sanitybadge.num ~= nil then
      self.sanitybadge.num:SetString(tostring(math.floor((sanity_cur or 0) + 0.5)))
    end
  end

  local tint = (onfire and ONFIRE_TINT) or (overheating and OVERHEAT_TINT) or (freezing and FREEZE_TINT) or nil
  if tint ~= nil then
    self:StartWarning(unpack(tint)) -- StartWarning re-applies the colour each call
  else
    self:StopWarning()
  end

  -- HP rate arrow: a fast down-arrow whenever HP is draining from fire/overheat/freeze
  -- (shown alongside the pulse). Hidden otherwise.
  local hparrowanim = (onfire or overheating or freezing) and "arrow_loop_decrease_most" or nil
  if hparrowanim == nil then
    self.hparrow:Hide()
    self.hparrow_cur = nil
  else
    if self.hparrow_cur ~= hparrowanim then
      self.hparrow_cur = hparrowanim
      self.hparrow:GetAnimState():PlayAnimation(hparrowanim, true)
    end
    self.hparrow:Show()
  end

  -- v2026.11: the centre head sits in the ring centre and covers self.hparrow, so while a thermal
  -- arrow is active a centre-config teammate must render as "corner" (head -> top-left inset) to free
  -- the centre, then restore "centre" when thermal clears. Track the live thermal state regardless;
  -- only re-render when the effective style actually changed (i.e. the centre-config case) and we have
  -- args to re-render with. UpdateBadges calls SetAvatar BEFORE SetStatus each refresh, so this corrects
  -- the avatar within the same pass.
  local thermal = (onfire or overheating or freezing) and true or false
  if thermal ~= self._thermal_active then
    self._thermal_active = thermal
    if self:_apply_effective_style() and self._last_avatar_args ~= nil then
      local a = self._last_avatar_args
      self:SetAvatar(a.prefab, a.idflags, a.is_foreign, a.base_skin)
    end
  end
end

-- ratescale = RATE_SCALE enum (0 neutral / 1-3 increase / 4-6 decrease). Hidden when neutral
-- or when the sub-gauges are disabled.
function PartyBadge:SetSanityRate(ratescale)
  local anim = (self.subvisible and ratescale ~= nil) and SANITY_RATE_ANIM[ratescale] or nil
  if anim == nil then
    self.sanityarrow:Hide()
    self.sanityarrow_cur = nil
    return
  end
  if self.sanityarrow_cur ~= anim then
    self.sanityarrow_cur = anim
    self.sanityarrow:GetAnimState():PlayAnimation(anim, true)
  end
  self.sanityarrow:Show()
end

-- v2026.9: single source of truth for the ring-border (circleframe) colour. Both the low-HP blink
-- and the foreign-dim want to write circleframe; routing every write through here keeps them from
-- desyncing (same idea as the v2026.8 "one cache-syncing relayout fn" fix).
function PartyBadge:_apply_frame_colour()
  if self.circleframe == nil then
    return
  end
  -- Delegate the breathe / dim-baseline arithmetic to the pure module (single writer -> the low-HP
  -- blink and the foreign dim coexist without desyncing); apply the result via the same engine call.
  self.circleframe:GetAnimState():SetMultColour(badgemath.frame_colour(self.low_hp, self.foreign, self._blink_t))
end

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

-- v2026.9: enter/leave the low-HP pulsing state. Idempotent. Uses the widget per-frame update loop
-- (StartUpdating/StopUpdating + OnUpdate) so the border can fade smoothly; Widget:Kill stops updates.
function PartyBadge:_set_low_hp(islow)
  islow = islow and true or false
  if islow == self.low_hp then
    return
  end
  self.low_hp = islow
  if islow then
    self._blink_t = 0 -- begin the breathe from the rest phase
    self:StartUpdating() -- per-frame OnUpdate advances the sine pulse
  else
    self:StopUpdating()
  end
  self:_apply_frame_colour()
end

-- v2026.9: advance the low-HP pulse each frame. Only does work while low; StartUpdating/StopUpdating
-- (in _set_low_hp) gate when this even runs, and the guard is belt-and-suspenders.
-- INVARIANT: every path that hides this badge MUST call _set_low_hp(false) first (HideBadge/ShowDead
-- already do). The engine's FrontEnd update loop gates on `enabled`, not `shown`, so a hide path that
-- forgets to stop the pulse would keep firing OnUpdate every frame on a hidden badge (wasted work).
function PartyBadge:OnUpdate(dt)
  if not self.low_hp then
    return
  end
  self._blink_t = self._blink_t + (dt or 0)
  self:_apply_frame_colour()
end

-- v2026.8 cross-shard: give this badge the "this teammate is elsewhere / data is ~1s stale" look.
-- isforeign=true  -> dim every element (alpha down, hue preserved), show a small shard label
--                    (e.g. "Caves"/"Surface") above the name, and force-hide the live-only rate
--                    arrows so a stale arrow from a previous LOCAL use of this slot can't linger.
-- isforeign=false -> restore full opacity and hide the label (the slot is being re-used for a local
--                    player or cleared). Cheap + idempotent: safe to call every refresh.
-- sameshard=true  -> this teammate is on the SAME shard but out of network view-range (not cross-shard);
--                    override the label to read "far" instead of a shard name. nil/false for the
--                    cross-shard case, so existing 2-arg callers keep their "Caves"/"Surface" label.
function PartyBadge:SetForeign(isforeign, label, sameshard)
  self.foreign = isforeign and true or false
  local a = self.foreign and FOREIGN_ALPHA or FULL_ALPHA

  -- main HP ring (red fill) + dark backing + frame (both untinted) + sub-rings (gold hunger /
  -- orange sanity). RGB is re-asserted at each element's base tint so a foreign->local restore
  -- returns to full colour; only alpha changes.
  set_anim_alpha(self.anim, a, HEALTHBADGE_TINT[1], HEALTHBADGE_TINT[2], HEALTHBADGE_TINT[3])
  set_anim_alpha(self.backing, a) -- dark background ring (untinted)
  -- circleframe (the ring border) is owned by _apply_frame_colour: it reconciles the foreign dim
  -- (self.foreign, set above) with the low-HP blink, so a foreign<->local flip can't strand a
  -- stale border tint. (Replaces the direct set_anim_alpha(self.circleframe, a) call.)
  self:_apply_frame_colour()
  if self.hungerbadge ~= nil then
    set_anim_alpha(self.hungerbadge.anim, a, HUNGER_TINT[1], HUNGER_TINT[2], HUNGER_TINT[3])
    set_anim_alpha(self.hungerbadge.backing, a)
    set_anim_alpha(self.hungerbadge.circleframe, a)
  end
  if self.sanitybadge ~= nil then
    set_anim_alpha(self.sanitybadge.anim, a, SANITY_TINT[1], SANITY_TINT[2], SANITY_TINT[3])
    set_anim_alpha(self.sanitybadge.backing, a)
    set_anim_alpha(self.sanitybadge.circleframe, a)
  end
  -- text elements: name + the HP / sub-ring numbers. The NAME is owned by _apply_name_colour
  -- (reconciles the player colour with the foreign dim); call it after self.foreign is set above.
  self:_apply_name_colour()
  if self.num ~= nil then
    self.num:SetColour(1, 1, 1, a)
  end
  if self.hungerbadge ~= nil and self.hungerbadge.num ~= nil then
    self.hungerbadge.num:SetColour(1, 1, 1, a)
  end
  if self.sanitybadge ~= nil and self.sanitybadge.num ~= nil then
    self.sanitybadge.num:SetColour(1, 1, 1, a)
  end

  if self.foreign then
    -- live-only extras OFF defensively (caller already passes false flags + neutral rate, but a
    -- stale arrow shown the last time this slot rendered a LOCAL player must not linger).
    self.hparrow:Hide()
    self.hparrow_cur = nil
    self.sanityarrow:Hide()
    self.sanityarrow_cur = nil

    -- shard label, created lazily. Parented to the badge AFTER the ctor children so it draws on
    -- top (z-order: later AddChild = above), placed above the name label so the two don't overlap.
    if self.foreignlabel == nil then
      self.foreignlabel = self:AddChild(Text(BODYTEXTFONT, 16))
      self.foreignlabel:SetHAlign(ANCHOR_MIDDLE)
      self.foreignlabel:SetPosition(0, 50, 0)
      self.foreignlabel:SetColour(0.7, 0.85, 1, 1) -- soft blue marker, fully opaque (it IS the "elsewhere" cue)
    end
    self.foreignlabel:SetString(sameshard and "far" or (label or "elsewhere"))
    self.foreignlabel:Show()
  elseif self.foreignlabel ~= nil then
    self.foreignlabel:Hide()
  end
end

function PartyBadge:HideBadge()
  self:_set_low_hp(false) -- stop any blink task before hiding a departed / empty slot
  self:_HideAvatars()
  self:Hide()
end

function PartyBadge:ShowBadge()
  self:Show()
  if self.anim ~= nil then
    self.anim:Show()
  end
  if self.circleframe ~= nil then
    self.circleframe:Show()
  end
  self:_apply_frame_colour() -- reconcile the border tint on reveal, so it never depends on a
  -- caller happening to run SetPercent right after ShowBadge
  -- honour the centre style's forced-hover-only here too: the single-writer re-shows the HP number only
  -- when hp_number_always and not _hp_number_was_hover, so ShowBadge can't reveal it over the centre head
  -- (cleared by SetAvatarStyle on leaving centre). show-only (allow_hide=false): same as the old site,
  -- which only ever :Show()'d -- the focus/hover or config-off hide is left untouched.
  self:_apply_hp_number_visibility(false)
  self.name:Show()
  -- only reveal the sub-rings when they're enabled (their numbers stay hover-only)
  if self.subvisible then
    self.hungerbadge:Show()
    self.sanitybadge:Show()
  else
    self.hungerbadge:Hide()
    self.sanitybadge:Hide()
  end
  self.dead:Hide()
end

function PartyBadge:ShowDead()
  self:Show()
  self:_set_low_hp(false) -- a dead/ghost teammate shows the skull, not a low-HP blink; stop it
  -- (SetPercent ran before ShowDead and may have started the blink at hp 0)
  if self.anim ~= nil then
    self.anim:Hide()
  end
  if self.circleframe ~= nil then
    self.circleframe:Hide()
  end
  if self.num ~= nil then
    self.num:Hide()
  end
  self.name:Show()
  self.hungerbadge:Hide()
  self.sanitybadge:Hide()
  self.sanityarrow:Hide()
  self.sanityarrow_cur = nil
  self:StopWarning()
  self.hparrow:Hide()
  self.hparrow_cur = nil
  -- a dead teammate shows the skull, which is mutually exclusive with the centre/corner avatar.
  self:_HideAvatars()
  self.dead:Show()
end

return PartyBadge
