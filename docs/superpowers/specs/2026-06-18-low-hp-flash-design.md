# PartyHud 2026 — Low-HP border alert (v2026.9) — design spec

**Date:** 2026-06-18
**Status:** approved (brainstorming), pending spec review → writing-plans
**Scope:** small, **client-only** feature. Touches `scripts/widgets/partybadge.lua`, `modmain.lua`, `modinfo.lua` only. No codec / server-hook / cross-shard-transport changes.

## Goal

Flash a **blinking red ring border** on a teammate's badge when their HP drops below a player-chosen threshold, so "who's about to die" is obvious at a glance. This is a genuine differentiator — no existing DST teammate-HUD mod does a low-HP alert.

## Decisions (locked in brainstorming)

1. **Channel = the ring border (`circleframe`), as a distinct visual element.** The badge's single continuous warning-pulse channel (`self.warning`, driven by `Badge:StartWarning`) is already used by the thermal cue (fire/overheat/freeze). The low-HP alert must **coexist** with it — a teammate who is both on fire *and* low-HP shows both cues — so it uses a *different* element: the `circleframe` border. (Verified in `dst-scripts/widgets/badge.lua`: `self.warning` is the only continuous pulse; `self.pulse` is a one-shot used by `PulseGreen`/`PulseRed`. The border is independent of both.)
2. **Look = a blinking red border.** Toggle between an alarm red and the badge's baseline border, on a **0.6 s** period (→ 1.2 s full on/off cycle, a calm alarm cadence). Blink (two-state toggle) reads as an alarm and is rhythmically distinct from the steady thermal pulse.
3. **Threshold = percent of *max* HP** (not absolute) so it behaves correctly for Wanda (age-as-health), WX-78 (high max), and endless-mode max-HP penalty.
4. **Config = a single per-player dropdown** `Low-HP Alert: Off / 40% / 25% (default) / 15%`. `Off` disables the feature; the other values set the threshold. One option does both enable/disable and threshold.
5. **Far / cross-shard teammates flash too.** The relayed codec record already carries `hp_cur`/`hp_max`, and a teammate dying out of view / on the other shard is the *highest-value* alert. The threshold applies to every badge (local, far "far", and cross-shard "Caves"/"Surface").
6. **No audio.** Visual-only. The blink is attention-grabbing enough, and audio in co-op risks spam (HP oscillating around the threshold; many teammates low at once).

## Architecture

Drive the blink with a lightweight per-badge timer, and resolve the `circleframe`-sharing between the blink and the existing foreign-dim through a **single source of truth** so the two writers never desync (the same lesson as the v2026.8 "route all re-layout through one cache-syncing fn" fix — see the `dst-badge-visual-audit` skill §15).

### New per-badge state (`PartyBadge`, set in `_ctor`)

- `self.low_hp_threshold` — number in `0..1`; `0` means the feature is **disabled** for this badge. Set after construct from config (like `self.hp_number_always`).
- `self.low_hp` — bool, whether the badge is currently in the low-HP (alive) state.
- `self._blink_on` — bool, the current blink phase (alarm vs rest).
- `self._blink_task` — the `DoPeriodicTask` handle, `nil` when not blinking.

### Constants (`partybadge.lua`, near `FOREIGN_ALPHA`)

- `LOW_HP_TINT = {1, 0.15, 0.15}` — alarm red (brighter than the HP fill's `{174,21,21}/255` so it pops against the red ring underneath).
- `LOW_HP_BLINK_PERIOD = 0.6` — seconds per toggle.

### Single source of truth — `PartyBadge:_apply_frame_colour()`

Computes and sets the `circleframe` MultColour from `(self.low_hp, self._blink_on, self.foreign)`. **Every** writer of the border colour goes through here.

```
function PartyBadge:_apply_frame_colour()
    if self.circleframe == nil then return end
    if self.low_hp and self._blink_on then
        -- alarm phase: red at FULL alpha, so the alert stays visible even on a
        -- dimmed far/cross-shard badge (the alert outranks the "stale" dim cue
        -- during its on-phase).
        self.circleframe:GetAnimState():SetMultColour(LOW_HP_TINT[1], LOW_HP_TINT[2], LOW_HP_TINT[3], 1)
    else
        -- rest phase, or not low: baseline border = white at the badge's current
        -- alpha (FOREIGN_ALPHA if this slot is a far teammate, else full).
        local a = self.foreign and FOREIGN_ALPHA or FULL_ALPHA
        self.circleframe:GetAnimState():SetMultColour(1, 1, 1, a)
    end
end
```

A far + low teammate therefore blinks **alarm-red ↔ dim-white** — reading as both "alert!" and "far" at once.

### Blink lifecycle — `PartyBadge:_set_low_hp(islow)`

Idempotent; starts/stops the timer.

```
function PartyBadge:_set_low_hp(islow)
    islow = islow and true or false
    if islow == self.low_hp then return end          -- no-op on no change
    self.low_hp = islow
    if islow then
        self._blink_on = true                         -- go red immediately
        if self._blink_task == nil and self.inst ~= nil then
            self._blink_task = self.inst:DoPeriodicTask(LOW_HP_BLINK_PERIOD, function()
                self._blink_on = not self._blink_on
                self:_apply_frame_colour()
            end)
        end
    else
        if self._blink_task ~= nil then self._blink_task:Cancel(); self._blink_task = nil end
        self._blink_on = false
    end
    self:_apply_frame_colour()
end
```

The task is parked on `self.inst` (the widget entity) → torn down by `Widget:Kill` (`RemoveAllEventCallbacks` + `CancelAllPendingTasks`). The closure only touches `self` (long-lived; the badge persists in `badgearray`), and `_apply_frame_colour` nil-guards `circleframe` at fire time.

### Integration points

- **`SetPercent(cur, max, penalty)`** — after the existing ring update, compute and apply the low state. `m` is the already-guarded max (`> 0`).
  ```
  local pct = cur / m
  self:_set_low_hp(self.low_hp_threshold > 0 and pct < self.low_hp_threshold)
  ```
  `SetPercent` runs for **both** the local path and the foreign path (which passes `rec.hp_cur`, `rec.hp_max`), so far/cross-shard badges get the same threshold check for free — **no separate code**.
- **`SetForeign(isforeign, label, sameshard)`** — set `self.foreign` as today, but the `circleframe` line now routes through the helper instead of a direct `set_anim_alpha`. Replace `set_anim_alpha(self.circleframe, a)` with `self:_apply_frame_colour()`. All other elements (`anim`, `backing`, sub-rings, text) keep their existing `set_anim_alpha`/`SetColour`. This makes `_apply_frame_colour` the *only* writer of the border colour, so a foreign↔local change while blinking can't leave a stale tint.
- **`ShowDead()`** — a dead/ghost teammate shows the skull and hides `circleframe`; they are not a "low-HP alert". Call `self:_set_low_hp(false)` (stops the blink, no task left toggling a hidden frame). (`SetPercent` is called before `ShowDead` in `UpdateBadges`, so a dead player with `hp_cur 0` would transiently start the blink; `ShowDead` cancels it.)
- **`HideBadge()`** — call `self:_set_low_hp(false)` (the trailing-slot clear hides departed/empty badges; don't leave a blink task running on a hidden slot).
- **`ShowBadge()`** — no special action; the next `SetPercent` re-establishes the correct low state. (`ShowBadge` re-shows `circleframe`; `_apply_frame_colour` runs on the next `SetPercent`.)

### Config wiring (`modmain.lua` + `modinfo.lua`)

- **`modinfo.lua`** — add a `configuration_options` entry (same format as the others, `client = true`), `data` = the threshold percent, `0` = Off:
  ```
  { name="low_hp_alert", label="Low-HP Alert",
    hover="Blink a red border on a teammate's badge when their HP drops below this level (percent of their max HP). Off disables it.",
    options={ {description="Off", data=0}, {description="40%", data=40},
              {description="25%", data=25}, {description="15%", data=15} },
    default=25, client=true },
  ```
- **`modmain.lua`** — read with `get_local_config=true` and convert to a fraction (near the other reads, ~line 54):
  ```
  local low_hp_threshold = (GetModConfigData("low_hp_alert", true) or 0) / 100  -- 0 = disabled
  ```
- Apply per badge alongside the existing config (after `SetSubGauges`/`SetHPNumberAlways`, ~line 310):
  ```
  self.badgearray[i].low_hp_threshold = low_hp_threshold
  ```

## Edge cases (all handled by the above)

- **Threshold = Off (0):** `self.low_hp_threshold > 0` is false → `_set_low_hp(false)` always → never blinks; baseline border. No timer ever starts.
- **Dead / ghost:** `ShowDead` stops the blink; the skull conveys death. A teammate who dies *while* blinking has the blink cancelled by the same `ShowDead`.
- **Far + low:** blinks alarm-red ↔ dim-white (handled by `_apply_frame_colour` reading `self.foreign`).
- **Foreign state flips while low** (walk into view / migrate): `SetForeign` calls `_apply_frame_colour`, which recomputes the rest-phase alpha; the alarm phase is unaffected. No stale tint.
- **`max <= 0`** (mid-spawn / missing netvar): `SetPercent` already clamps `m = (max>0) and max or 1`; `pct = cur/1` — a real `cur` would read as "not low" unless `cur` is also tiny. Acceptable; the next refresh with a real max corrects it.
- **Mock/DEBUG badges:** `SetPercent` runs for them too; they'll honour the threshold (fine for previewing the alert).
- **Task teardown:** parked on `self.inst`; `_set_low_hp(false)` cancels explicitly; `Widget:Kill` covers any residual. No leak across HUD rebuild.

## Out of scope (YAGNI)

- Audio cue (decided against).
- Configurable blink colour / rhythm (fixed red, 0.6 s).
- Edge-trigger announcements / chat ("X is low") — that's the separate ping/announce idea in FEATURE-IDEAS.
- Any change to the cross-shard codec or server hooks — the HP needed is already relayed.

## Verification

Pure-Lua busted doesn't exercise widgets, so verify on `dst-modtest` (2 players, the `dstc`/`dst-heal`/`dst-fire`/`dst-cave` helpers):

1. **Threshold on/off:** `dst-heal` a teammate to full, then drop their HP across each configured level (40/25/15) → border starts/stops blinking at the right point; set config to **Off** → never blinks.
2. **Coexist with thermal:** make a low-HP teammate also burn (`dst-fire`) → red border blink **and** the orange fire pulse show simultaneously.
3. **Far / cross-shard:** with a teammate out of view or in caves (`dst-cave`), drop their HP → the dimmed far/"Caves" badge blinks alarm-red ↔ dim-white.
4. **Death transition:** kill a blinking teammate → blink stops, skull shows (no lingering blink); revive → border returns to baseline.
5. **Config levels + restore:** switch the dropdown across all four values mid-session (rejoin to apply) and confirm the rest-phase border returns to the correct (foreign-aware) baseline when HP recovers.

Run the two in-repo review skills before shipping: **`dst-badge-visual-audit`** (SetMultColour usage, blink-vs-dim coexistence, z-order, the single-writer rule) and **`dst-mod-crash-audit`** (the new `DoPeriodicTask` fire-time guard + teardown, nil-guards). Gate locally with `luajit -e "assert(loadfile(...))"` + `luajit spec/run_local.lua` (codec specs unaffected) + luacheck `0/0` on hub.

## Release pipeline

Same as v2026.8: edit local → parse/busted → scp to `~/partyhud-fork` → luacheck `0/0` → commit (⚠️ no apostrophes in the `-m` message inside the ssh single-quote) → push via hub (local HTTPS push has no token). Beta-test on item `3746763879` (bump the beta `version=` to `2026.9b1`+, copy to modtest local folder, restart, in-game verify). When approved: bump `modinfo` 2026.8 → **2026.9**, README changelog + bilingual Steam BBCode (add the Low-HP Alert option), merge → master, tag `v2026.9`, push; user uploads public Workshop `3744675705`; sync prod via the `-only_update_server_mods` updater. (Pipeline details: memory `partyhud-beta-uploader` + `dst-server-deployment`.)
