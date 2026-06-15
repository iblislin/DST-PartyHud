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
