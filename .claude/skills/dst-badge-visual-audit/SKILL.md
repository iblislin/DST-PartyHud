---
name: dst-badge-visual-audit
description: Visual-parity review for Don't Starve Together (DST) mod HUD / badge / status-widget code. Use this WHENEVER you add or change a custom Badge, UIAnim overlay, status meter, rate arrow, icon, or any HUD widget in a DST mod — and whenever the user reports a widget that "looks wrong", "doesn't match the game UI", "is the wrong colour", "the arrow is too small/big", "the number is covered / unreadable", "the penalty arc is reversed / filling the wrong way", "the badge is invisible", "the layout overlaps / new column doesn't show", "a column collapses to one badge after resizing the window", or "the HUD covers the game's own moisture meter / backpack / status badges". Trigger even when the user just says "review the UI", "check the visuals", or names one symptom (covered number, wrong colour, reversed arc, overlaps a game meter, wrong on resize) without saying "audit". Catches the visual-parity bugs that luacheck and the crash-audit CANNOT: wrong build/bank name, wrong tint variant, wrong widget scale, wrong draw order (z-order), penalty/lost-max overlay direction, meter fill direction, layout-timing, anchor-aware growth, collision with other (conditional) vanilla HUD widgets, and the proportional-HUD-scale wrap miscount.
---

# DST Badge / HUD Visual-Parity Audit

## Why this exists

DST HUD code is thin Lua over the engine's animation/widget system, and a widget can load
with **zero Lua errors yet render completely wrong**: an invisible badge, a number hidden
behind an arrow, a penalty arc filling from the wrong end in the wrong colour, an arrow that's
visibly the wrong size. `luacheck` is blind to all of this (it's not a syntax problem), and the
[`dst-mod-crash-audit`](../dst-mod-crash-audit/SKILL.md) skill is about *crashes*, not
*appearance*. This skill is the visual counterpart: it encodes the rendering pitfalls we've
actually hit building badge widgets, and — crucially — the principle that fixes almost all of
them.

**The one principle:** a custom HUD widget should be built by **mirroring the vanilla widget it
imitates, element-for-element** — same build/bank name, same tint, same scale, same parent and
draw order, same fill direction. The bugs below all came from *improvising* instead of copying
vanilla: reaching for a base-class shortcut (`Badge` `bonusval`) that doesn't match vanilla
semantics, guessing a scale, or `AddChild`-ing in an order that breaks the z-stack. When in
doubt, open the vanilla widget and do exactly what it does.

This audit is **not** a substitute for an actual in-game look. The pipeline is: luacheck →
crash-audit → **this visual audit** → **in-game visual test** (see the last section).

## Before you start — get ground truth

You cannot audit visual parity without the vanilla widget to compare against. Read the real
source; do NOT trust wikis or memory for DST widget internals.

1. **The mod widget(s)** you changed (e.g. `scripts/widgets/<yourbadge>.lua`).
2. **The vanilla widgets you're mirroring**, from the extracted game scripts (commonly at
   `~/code/dst/dst-scripts/scripts/`; if absent, extract per the crash-audit skill's
   ground-truth step). The ones that matter for badges:
   - `widgets/badge.lua` — the base `Badge` class: its ctor child order (`backing` → `anim` →
     `anim_bonus` → `circular_meter` → `underNumber` → `num`), and `Badge:SetPercent(val, max,
     bonusval)`.
   - `widgets/healthbadge.lua`, `widgets/sanitybadge.lua`, `widgets/hungerbadge.lua` — the
     real heart / brain / belly badges: how they build the penalty topper, the rate arrow, the
     tints, the icon builds.
   - `widgets/statusdisplays.lua` — how those badges are assembled, scaled, and driven
     (`SetHealthPercent`/`SetSanityPercent`, the `health:Max()` + penalty calls).
   - **For POSITIONING / layout changes** (not just one widget's appearance): `widgets/controls.lua`
     — the HUD roots, their anchors and the `GetHUDScale()` + `SCALEMODE_PROPORTIONAL` scale chain
     (`topleft_root`, `bottomright_root`, `containerroot_side`, `bottom_root`) — plus the
     *conditional* vanilla widgets that share your screen region (moisture meter, side-pack
     containers, character second-row badges, the Map button). See references §11 (coexistence) +
     §12 (proportional scale). An exact icon/element PIXEL size (for centring or sizing) is **not**
     in the scripts — extract it from the game's image bundle per references §13.

For every element you draw, find the vanilla equivalent and diff the construction. The
[`references/dst-badge-visual-gotchas.md`](references/dst-badge-visual-gotchas.md) file has the
verified file\:line anchors and code snippets for each item below.

## The checklist

Run every item against each custom widget element you added or changed. Create a TodoWrite item
per check that's relevant to your change.

**Composed / nested badges:** a widget often nests one or more vanilla-style `Badge`s as
*children* (e.g. a main HP ring with scaled-down hunger/sanity sub-rings), and re-implements a
sub-ring's own topper / rate arrow on that child. When it does, run items **3, 5, 6, and 10
against the *sub-badge's* own `underNumber` and its own show/hide path**, not just the top-level
badge — the sub-ring's overlays ride the sub-ring's z-stack, scale, and visibility, so each
nested badge needs its own pass.

1. **Build / bank name** — does the `SetBank`/`SetBuild` string match the *current* vanilla
   asset? Asset builds get **renamed** between game versions; a stale name loads with no error
   and renders **nothing**. (The 2016 heart build `"health"` → modern `"status_health"`: a
   wrong name = invisible badge.)

2. **Tint / colour** — does `SetMultColour`/the tint constant match the vanilla element, and the
   *right variant*? Several gauges have multiple colour states. (Sanity's normal ring is
   **orange `{232,123,15}/255`**; the blue `{191,232,240}` is the *lunacy* variant — using it
   makes a normal sanity ring look wrong.)

3. **Scale** — does the widget's scale match vanilla? Vanilla rate arrows and toppers are added
   at **default scale 1.0 (no `SetScale`)**. A guessed `SetScale(0.7)` renders visibly smaller
   than the game's element. **Do NOT bake a scale into a child of an already-scaled parent**: an
   arrow on a 0.5-scaled sub-ring should inherit that 0.5 (no explicit scale) so its proportion
   matches the game — set scale only to express the *vanilla* ratio relative to its own ring.

4. **Position / centering** — does it sit where vanilla puts it (usually centered,
   `SetPosition(0,0,0)` relative to the ring)? An off-centre arrow/icon reads as a different
   widget.

5. **Draw order / z-order (THE subtle one)** — within a parent, **children draw in `AddChild`
   order: later = on top**. The base `Badge` adds `underNumber` *before* `num`, so anything
   parented to `underNumber` draws **under the number**, and anything `AddChild`'d to the badge
   *after* construction draws **over the number** (covering it). Vanilla parents its rate arrow
   and penalty topper to `underNumber` precisely so the **number stays readable on top**. The
   canonical badge layering, bottom→top, is: **fill `anim` < penalty topper < rate arrow <
   number**. Verify: the number is on top; the arrow is above the penalty blackout; nothing the
   player needs to read is occluded — *including on hover*.

6. **Penalty / "lost-max" overlay** — the darkened arc for reduced max HP/sanity (endless
   resurrection) is drawn by vanilla as a **separate topper overlay**: a `status_meter` `"anim"`
   UIAnim, **`SetMultColour(0,0,0,1)` (black)**, **`SetScale(1,-1,1)` (vertical flip, so it
   fills from the TOP)**, parented to `underNumber`, driven by `SetPercent("anim", 1 -
   penalty)`. **Do NOT reuse the base `Badge:SetPercent` `bonusval`/`anim_bonus` path for this**
   — that arc is white and fills from the *bottom*, i.e. reversed direction and wrong colour.
   (This exact bug: 50% penalty showed as bottom-half-white instead of top-half-black.)

7. **Meter fill direction** — `Badge:SetPercent` drives the fill with `SetPercent("anim", 1 -
   val)` (full=percent 0). If you set a meter/overlay directly, keep the `1 - x` convention or
   it fills inverted. The penalty topper's vertical flip (`SetScale(1,-1,1)`) is what makes
   `1 - penalty` black from the top rather than the bottom — keep both together.

8. **Layout timing** — `TheFrontEnd:GetHUDScale()` / final screen size are **not ready inside a
   widget ctor / PostConstruct**. Any layout math that depends on HUD scale (column wrap,
   screen-relative positions) must run in a `DoTaskInTime(0, ...)` (and re-run on the
   `"refreshhudsize"` event), not at construct time, or it computes against a stale scale.

9. **Anchor-aware growth** — a list anchored to the right edge must grow **leftward** (new
   columns at `x - col_width`, not `+`); a bottom-anchored list grows up; etc. Growing in the
   wrong direction sends new items off-screen and "the new column never shows".

10. **Multi-state coexistence** — check the states that stack: penalty **and** on-fire/cold at
    once (does the arrow still show above the blackout?), dead/ghost (are arrows + toppers
    hidden?), sub-gauges toggled off (do child overlays hide with the ring?), hover vs non-hover
    (number visibility), and **empty / full gauge** (rate arrows should settle to neutral at full
    — no-increase-at-full — and at empty — no-decrease-at-empty — mirroring the vanilla badge
    OnUpdate guards). A fix that's correct in isolation can break when two states overlap.

11. **Coexistence with OTHER vanilla HUD widgets (positioning)** — *only when your change moves /
    sizes the HUD near a screen edge.* It must dodge the *other* vanilla widgets in that region,
    **including conditional ones that pop up** — the rain/moisture meter, an opened side backpack,
    Wendy's Abigail badge, Wigfrid's inspiration badge — not just the always-present UI you can see
    while testing. Detect them client-side and shift / reserve space, reacting on the firing events
    (`equip`/`unequip`, `moisturedelta`) **plus a ~0.5s poll** for state that fires no event
    (container open/close, the integrated-backpack setting). See references §11 for the verified
    right-side catalog + per-widget detection signals. (Things that do NOT collide, so don't chase
    them: bosses, mounts, top-left toasts/desync, the centre scoreboard.)

12. **Proportional HUD scale in wrap / keep-out math** — a column-count or keep-out reserve that
    converts screen height into widget-local units must divide by the `SCALEMODE_PROPORTIONAL`
    factor (`min(w/1280, h/720)`, capped at `MAX_HUD_SCALE=1.25`) **as well as** `GetHUDScale()`
    and the widget's own scale. Omitting it makes the count collapse to a single item (with lots of
    empty space) on a window smaller than 1280×720, and over-count above 1080p. See references §12.
    (Distinct from item 8: item 8 is *when* you compute; this is *the formula* you compute.)

## Red flags (stop and re-check vanilla)

| Symptom | Almost always |
|---|---|
| Badge / icon invisible, no Lua error | Stale `SetBuild`/`SetBank` name (asset renamed) — item 1 |
| Number unreadable / covered by an arrow or overlay | Element `AddChild`'d to the badge after `num` instead of to `underNumber` — item 5 |
| Penalty arc reversed (fills wrong end) and/or white not black | Used `Badge` `bonusval` instead of the black, vertically-flipped topper — item 6 |
| Arrow/overlay visibly smaller/larger than the game's | Guessed `SetScale`; vanilla uses default 1.0 / a different ratio — item 3 |
| Colour subtly wrong | Picked the wrong colour *variant* (e.g. lunacy blue vs sanity orange) — item 2 |
| "New column / wrapped item never appears" | Growing toward the anchored edge (off-screen) — item 9 |
| Layout right at first frame, wrong after, or vice-versa | HUD scale read at construct instead of `DoTaskInTime(0)` / `refreshhudsize` — item 8 |
| "I reused a base-class `SetPercent`/helper to save code" | The base shortcut rarely matches vanilla's overlay semantics — mirror the vanilla element instead |
| HUD overlaps a vanilla meter that appears only *sometimes* (rain / opened backpack / Abigail / inspiration) | You positioned against the always-present UI only — account for the *conditional* vanilla widgets — item 11 |
| Per-column count collapses to 1 (lots of empty space) on a small / resized window | Wrap math omitted the `SCALEMODE_PROPORTIONAL` factor — item 12 |
| Need an icon's exact pixel size to centre / size it, but it's not in the scripts | It's in the texture atlas — extract `hud.xml` UVs + the `.tex` KTEX dims — references §13 |
| HUD shifts to dodge one obstacle but then covers a *different* one; or a "wide" dodge over-pads after a shift; or one badge state under-clears | Obstacles are independent, a shift changes how many columns a band spans, and the dodge amount = the deepest active badge — references §14 |
| Re-layout fix "works sometimes" / the layout stays wrong for many seconds after a state change (equip/swap, open/close) until you re-toggle | A change-gated poll desynced because a different re-layout path didn't update the cached state; and/or `IsOpenedBy` lagged a swap — route all re-layout through one cache-syncing fn; detect "open" via `HUD.controls.containers` — references §15 |

## After the audit — the in-game visual test

Static review + luacheck + a clean dedicated-server load do **not** prove appearance. Look at it:

- Deploy to the modtest server + rebuild the client bundle (per the project's release/deploy
  procedure), connect, and **eyeball every changed element**.
- Drive the hard-to-reach states from the admin console so you actually see them: e.g.
  `ConsoleCommandPlayer().components.health:SetPenalty(0.5)` then `:DoDelta(0)` for the HP
  penalty arc; `:AddSanityPenalty("test", 0.5)` for sanity; fire/cold/overheat for the rate
  arrows. (Run these as **remote/server** console commands — admin, Ctrl+Enter — since
  components are server-side.)
- Check **hover** explicitly (numbers often only show on focus) and **stacked states** (item 10).
- A `DEBUG_SHOWALL`-style mock mode that fills slots with synthetic values (including a non-zero
  penalty and each thermal flag) lets you verify every visual state solo, without a second
  player — but confirm it's **off** before shipping.
- **For coexistence / positioning (item 11)** drive the conditional vanilla widgets from the
  server console: force rain (`TheWorld:PushEvent("ms_forceprecipitation", true)`) for the
  moisture meter; give + open a `backpack` for the side panel; toggle the **Integrated Backpack**
  client setting for the bottom-bar variant; switch to **Wendy** / **Wigfrid** for the
  Abigail / inspiration second-row badges; and **resize the window** (item 12) to confirm the
  per-column count stays stable. (Spawn `c_spawn("wilson")` dummies to populate enough badges to
  actually wrap into the columns you're checking.)
