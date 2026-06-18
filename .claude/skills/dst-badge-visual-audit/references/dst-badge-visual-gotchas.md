# DST badge / HUD visual-parity gotchas — verified reference

Detailed backing for the checklist in `../SKILL.md`. Every claim here was verified against the
extracted game scripts at `~/code/dst/dst-scripts/scripts/` (build 736959). File\:line anchors
drift between game versions — re-confirm against the extracted copy you're auditing rather than
trusting these numbers blindly.

## Table of contents
1. Base `Badge` child order & `SetPercent` — the layering foundation
2. Build / bank names (invisible-badge trap)
3. Tints & colour variants
4. Widget scale
5. Draw order / z-order (number readability)
6. Penalty / lost-max overlay (the topper)
7. Meter fill direction
8. Layout timing (HUD scale)
9. Anchor-aware growth
10. Multi-state coexistence
11. Coexistence with OTHER vanilla HUD widgets (positioning / collision)
12. Proportional HUD scale in layout math (resized-window collapse)
13. Exact pixel size of an atlas element (not in the Lua scripts)

---

## 1. Base `Badge` child order & `SetPercent` — the layering foundation

`widgets/badge.lua` ctor `Class(Widget, function(self, anim, owner, tint, iconbuild,
circular_meter, use_clear_bg, dont_update_while_paused, bonustint))`. When `anim == nil` (the
`status_meter` path every status badge uses) the children are added in this order:

```
pulse, warning            -- effect overlays
backing                   -- the empty-meter background
anim                      -- the coloured FILL meter (tinted by `tint`)
anim_bonus                -- a SECOND meter, tinted by `bonustint`, fills from the bottom
circular_meter (optional) -- if circular_meter arg is set
underNumber  = AddChild(Widget("undernumber"))   -- a container, added BEFORE num
num          = AddChild(Text(...))               -- the number, added LAST -> draws on TOP
```

Two facts that drive everything else:
- **Draw order = AddChild order; later children draw on top.** `num` is added last, so it's on
  top of every ctor child. Anything you `AddChild` to the badge *after* construction draws on
  top of `num` (covering it). Anything you add to `underNumber` draws *under* `num`.
- `Badge:SetPercent(val, max, bonusval)`:
  ```lua
  self.anim:GetAnimState():SetPercent("anim", 1 - val)         -- FILL, from the bottom
  if self.anim_bonus then
      if bonusval then self.anim_bonus:...:SetPercent("anim", 1 - bonusval); self.anim_bonus:Show()
      else self.anim_bonus:Hide() end
  end
  self.num:SetString(tostring(math.ceil(val * max)))
  ```
  `anim_bonus` is **white-ish (its `bonustint`, default none → white), fills from the bottom**,
  and is meant for a *bonus* overlay — NOT the vanilla "lost max" penalty look. See §6.

## 2. Build / bank names (invisible-badge trap)

Status badges use `SetBank/SetBuild("status_health" | "status_hunger" | "status_sanity")` for
the icon build, and `"status_meter"` for the meter anim. The 2016-era build name `"health"` was
**renamed** to `"status_health"`; a mod still asking for `"health"` loads with no Lua error and
draws an **invisible** badge. Whenever you copy an old mod or a wiki snippet, verify the build
string against the current `widgets/*badge.lua` ctor. Rate arrows use bank/build
`"sanity_arrow"` (shared by health & sanity badges).

## 3. Tints & colour variants

- Health: `HEALTHBADGE_TINT = {174/255, 21/255, 21/255, 1}` (red) — `healthbadge.lua` top.
- Sanity normal: **orange `{232/255, 123/255, 15/255, 1}`**. The blue `{191,232,240}` is the
  **lunacy** variant (`sanitybadge.lua` swaps tints by `GetSanityMode()`). Using the lunacy blue
  for a normal sanity ring is a colour-parity bug.
- Hunger: gold.

Pick the colour the vanilla widget shows in the *default* state, and replicate state-dependent
swaps only if you actually track that state.

## 4. Widget scale

Vanilla rate arrows are added at **default scale 1.0** — `healthbadge.lua` adds
`self.sanityarrow = self.underNumber:AddChild(UIAnim())` with **no `SetScale`**; same in
`sanitybadge.lua`. The penalty topper is also default scale on the X/Y magnitude
(`SetScale(1,-1,1)` only flips Y). So:
- On a **full-size** ring, an arrow/overlay should be `SetScale(1)` (or no SetScale). A guessed
  `0.7` renders ~30% too small vs the game.
- On a **scaled sub-ring** (e.g. a 0.5-scale sanity sub-badge), the child should **inherit** the
  parent's scale — add it with no explicit scale (or `SetScale(1)` local) so its *proportion to
  its own ring* matches the game. Don't multiply the 0.5 in by hand.

The arrow-anim magnitude (`arrow_loop_decrease` / `_more` / `_most`) is a **different**
animation, not a scale — `_most` is the "large/fast" arrow art. Vanilla health uses `_most` for
fire/freeze/starving/acid/corrosive and overheat (without heat-resist gear),
`arrow_loop_decrease_more` for overheat *with* heat-resist (`healthbadge.lua` OnUpdate). If you
only track the thermal flags, `_most` is a fair approximation.

## 5. Draw order / z-order (number readability)

The symptom: hovering the badge shows the number, but it's drawn **behind** the rate arrow /
overlay and unreadable. Vanilla avoids this by parenting the rate arrow (and the penalty topper)
to **`underNumber`**, which the base `Badge` adds *before* `num` — so they're under the number.

Wrong (covers the number): `self.arrow = self:AddChild(UIAnim())` (added after the base ctor →
on top of `num`).

Right (vanilla): `self.arrow = self.underNumber:AddChild(UIAnim())` — and for a sub-ring,
`self.subbadge.underNumber:AddChild(...)`.

Within `underNumber`, AddChild order still matters: add the **penalty topper before the arrow**
so the arrow draws on top of the blackout. Canonical bottom→top stack:

```
backing < anim (fill) < [underNumber: topper < arrow] < num
```

So when penalty + on-fire coincide, you see: fill, then the black lost-max region, then the
down-arrow on top of it, then the readable number on top of everything.

## 6. Penalty / lost-max overlay (the topper) — do NOT use `bonusval`

Endless-mode resurrection reduces max HP/sanity; the game shows the lost max as a **darkened arc
from the top**. Vanilla draws it with a dedicated overlay, NOT the `Badge` `bonusval` path.

`healthbadge.lua` ctor:
```lua
self.topperanim = self.underNumber:AddChild(UIAnim())
self.topperanim:GetAnimState():SetBank("status_meter")
self.topperanim:GetAnimState():SetBuild("status_meter")
self.topperanim:GetAnimState():PlayAnimation("anim")
self.topperanim:GetAnimState():SetMultColour(0, 0, 0, 1)   -- BLACK
self.topperanim:SetScale(1, -1, 1)                          -- vertical FLIP -> fills from TOP
self.topperanim:GetAnimState():SetPercent("anim", 1)        -- 1 => no blackout
```
`healthbadge.lua` / `sanitybadge.lua` `SetPercent(val, max, penaltypercent)`:
```lua
Badge.SetPercent(self, val, max)
self.topperanim:GetAnimState():SetPercent("anim", 1 - penaltypercent)
```
`statusdisplays.lua` drives it with `self.brain:SetPercent(pct, sanity:Max(),
GetPenaltyPercent())` (`SetSanityPercent`, ~`statusdisplays.lua:864`) and the heart equivalent
`self.heart:SetPercent(pct, health:Max(), penalty)` (`SetHealthPercent`, ~`:632`) — i.e. **ring
fill is relative to the FULL max** (`health:Max()` / `sanity:Max()`, not the penalized max),
penalty passed separately (0..1). Cross-check the mod's broadcast: it should send current
against the FULL max so a penalized player isn't drawn as 100% full.

Penalty 0 → `SetPercent("anim", 1)` → no black; 0.5 → `0.5` → top half black; 1 → `0` → fully
black. The **vertical flip is what makes `1 - penalty` black the TOP**; without it you'd black
the bottom.

The bug to avoid: reusing `Badge:SetPercent(val, max, bonusval)` with `bonusval = penalty`. That
drives `anim_bonus`, which is **white (no bonustint) and fills from the bottom** → 50% penalty
renders as bottom-half-white instead of top-half-black: reversed direction AND wrong colour. Add
your own black, Y-flipped topper to `underNumber` and stop passing the third `bonusval` arg.

Note vanilla draws the data number relative to FULL max too (so a penalized player isn't shown
as 100% full); broadcast/compute current against the **full** max, not the penalized max — that
data side is covered in the crash-audit / netvar notes, but it's part of looking right.

## 7. Meter fill direction

All meter anims use the `SetPercent("anim", 1 - x)` convention (full = anim percent 0, empty =
1). If you set a meter or overlay's percent directly, keep `1 - x`. For the penalty topper, the
`1 - penalty` value combined with the `SetScale(1,-1,1)` flip yields "black from the top by
`penalty`" — the flip and the `1 -` must travel together; changing one without the other
inverts the result.

## 8. Layout timing (HUD scale)

`TheSim:GetScreenSize()` is available early, but **`TheFrontEnd:GetHUDScale()` and the final
laid-out badge size are NOT ready inside a widget ctor / `AddClassPostConstruct`**. Layout math
that divides screen height by the HUD scale (column wrap, keep-out reserves, screen-relative
offsets) must run in `inst:DoTaskInTime(0, ...)` (next frame) and re-run on the
`"refreshhudsize"` event (fired on resolution / HUD-scale change). Computing it at construct
time gives a layout that's right at one scale and wrong after a resize, or wrong on first frame.

## 9. Anchor-aware growth

A badge list anchored to a screen edge must grow **away** from that edge. A right-anchored
vertical list that wraps into columns must place each new column at `x - column_width`
(leftward); using `+` sends new columns off the right edge → "the wrapped column never shows".
Match the growth direction to the anchor. Same logic for top/bottom anchors and the keep-out
reserve for fixed HUD buttons (e.g. the map button) — reserve space on the anchored side.

## 10. Multi-state coexistence

Each visual state can be correct alone yet break when stacked. Explicitly verify:
- **penalty + thermal arrow**: arrow draws above the black topper (§5 ordering), both visible.
- **dead / ghost**: rate arrows and (usually) the live overlays are hidden; the dead indicator
  shows. Make sure your `ShowDead`/equivalent hides the arrows/toppers you added.
- **sub-gauges toggled off**: a child overlay (arrow/topper) parented to a sub-ring hides when
  the sub-ring hides — but if you also explicitly `:Hide()` the sub-ring's children on toggle,
  keep that list in sync with everything you added.
- **hover vs idle**: numbers often only show on focus; confirm the number is both *present on
  hover* and *on top* (§5).
- **empty / max gauge**: rate arrows should settle to neutral at full (no-increase-at-full) /
  empty (no-decrease-at-empty), mirroring the vanilla badge OnUpdate guards.

## 11. Coexistence with OTHER vanilla HUD widgets (positioning / collision)

Mirroring the widget you imitate (the One Principle) is not enough: a HUD element placed near a
screen edge must also **dodge the *other* vanilla widgets sharing that region — including
CONDITIONAL ones that pop up only in certain states.** Positioning only against the
always-present UI is the trap. The verified RIGHT-side catalog for a right-anchored
teammate-badge column (file\:line in the current scripts):

- **Top-right status cluster** — `controls.lua` `sidepanel` under `topright_root`
  (ANCHOR_RIGHT/TOP): the player's own HP/hunger/sanity badges + the clock/moon/season ring
  (`uiclock.lua`). Always present.
- **Moisture (rain) meter** — `statusdisplays.lua` `moisturemeter` (y≈-115). Shown only when wet
  (`MoistureMeter:SetValue` sets `.active` when moisture>0). Detect: `ThePlayer:GetMoisture() > 0`;
  reacts to the `moisturedelta` event on the player.
- **Character/state "second-row" badges** in that cluster that extend its BOTTOM into a lower
  band: **Wendy Abigail pet-health** (`pethealthbadge`, y≈-100) and **Wigfrid inspiration**
  (`inspirationbadge`, y≈-130). Detect via the vanilla `ThePlayer.HUD.controls.status.<field>`
  being non-nil (created per-character at HUD construct) or tags (`battlesinger`). NB the others
  (boat meter y-40; Wolfgang mightiness / Woby pet-hunger / wereness at +20) sit WITHIN the normal
  cluster height and do NOT push the bottom down — don't dodge them.
- **Side-container floating panel** — `controls.lua` `containerroot_side` (ANCHOR_RIGHT/MIDDLE,
  mid-right edge). An equipped body container shown when OPEN: backpack / krampus_sack / piggyback
  / icepack / spicepack / seedpouch / candybag — all `issidewidget=true` in `containers.lua`, all
  **2 columns wide** (krampus/seedpouch/candybag are TALLER `2x8` but same width). Detect
  generically (NOT by prefab name): the BODY-slot item has `.replica.container` AND
  `:IsOpenedBy(ThePlayer)`. Right-click toggles open/close → **no event** → poll.
- **Integrated backpack** — `Profile:GetIntegratedBackpack()` (a controller forces it on; OR them).
  The bottom-center inventory bar grows taller by `(W+YSEP)/2 ≈ 38` inv-local units → reserve extra
  BOTTOM space, not a side shift.
- **Map(M) button cluster** — `controls.lua` `bottomright_root` `mapcontrols` (bottom-right):
  reserve bottom space on the **rightmost column only**.
- **Does NOT collide** (don't waste effort): boss health bars (none in base DST — festival modes
  only), mounts/Beefalo (no HUD widget), toasts + the desync/host-perf indicator (top-LEFT),
  scoreboard (Tab, centre fullscreen).

Detection is client-side. React on the events that fire (`equip`/`unequip` on `ThePlayer` with
`data.eslot`; `moisturedelta`) PLUS a light **~0.5s poll** for states that fire NO event (container
open/close, the integrated-backpack setting toggle, character badges). Two coordinate facts make
this tractable: **(a)** these roots share the SAME `hudscale × proportional` chain as your widget's
root, so a *fixed* offset / reserve gives **constant visual clearance at every resolution** — only
the per-widget base scale differs (inventory bar `0.6` vs statusdisplays `1.4`; convert a distance
by the constant ratio `0.6/1.4 ≈ 0.43`); **(b)** in these right-anchored roots **negative x = toward
the right screen edge**, same sign convention as a leftward-growing column.

## 12. Proportional HUD scale in layout math (resized-window collapse)

Roots like `topleft_root` / `bottom_root` / `containerroot_side` are scaled by BOTH
`SetScale(GetHUDScale())` AND `SCALEMODE_PROPORTIONAL` (+ `SetMaxPropUpscale(MAX_HUD_SCALE)`,
`controls.lua`). The proportional factor ≈ `min(screenW/1280, screenH/720)` capped at
`MAX_HUD_SCALE = 1.25` (RESOLUTION_X/Y = 1280/720, `constants.lua`). So a widget's PIXEL size =
`local × widget_scale × hudscale × prop`. Column-wrap / keep-out math that converts screen height
into widget-local units **must divide by `prop` too**:
`usable = screenH / (hudscale × widget_scale × prop)`. Omitting `prop` makes the count wrong
off the reference resolution: on a window smaller than 1280×720, `prop < 1` shrinks the real
widgets but `usable` doesn't follow → **the column collapses to a single item with lots of empty
space** (and over-counts above 1080p). Dividing `prop` out makes per-column count
resolution-stable (and grow correctly above 1080p up to the 1.25 cap). Distinct from §8 (timing):
even computed at the right time, the formula itself must include `prop`.

## 13. Exact pixel size of an atlas element (it is NOT in the Lua scripts)

Icon/element pixel dimensions live in the **texture atlas**, not the extracted scripts. When you
need them (to centre an off-centre glyph, or size an icon to a ring):
- The element's UV rect is in the atlas XML, e.g. `images/hud.xml`:
  `<Element name="tab_arcane.tex" u1=.. u2=.. v1=.. v2=.. />`.
- The atlas pixel size is in the matching `.tex` (KTEX): the first mipmap entry's width/height —
  after the 8-byte `KTEX`+header, read `width,height` as little-endian `u16` at offset 8 / 10.
- `element_px = (u2 − u1) × atlas_width`.
- On a dedicated server these are zipped in `data/databundles/images.zip` (the bundle still
  contains the atlas even when unpacked assets are stripped). Extract with Python `zipfile`.

Worked example (this project): `tab_arcane.tex` UV Δ = 0.0620 on a 2048² atlas → **127×127 px
native**. **CAVEAT:** a square UV element can still draw its visible glyph **off-centre inside its
own bounds** — the atlas gives the element BOX, not the glyph's optical centre — so final centring
still needs an in-game eyeball: **bracket** the offset (find the value that reads left and the one
that reads right; the centre is between them).
