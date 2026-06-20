---
name: dst-game-update-compat
description: >
  Compatibility check that catches DON'T STARVE TOGETHER (the GAME) updates breaking the PartyHud mod.
  Use this WHENEVER DST has been patched by Klei (a new game build), OR before tagging a PartyHud
  release if DST updated since the last compat-verify, OR when someone reports the mod broke after a
  game update. It diffs the mod's DST DEPENDENCY SURFACE (every engine API / build / event / netvar /
  TUNING / behavioural assumption the mod relies on) against the refreshed decompiled game source, to
  catch GAME-SIDE changes — a renamed build (the original PartyHUD died when `health` became
  `status_health`), a changed component API or threshold, a GetClientTable field rename, an event/tag
  rename, a TUNING value change — that the crash / visual / protocol audits CANNOT see because those
  review only OUR code. Trigger on any suspicion that DST changed under the mod; under-triggering ships
  a silent in-game break.
---

# DST Game-Update Compatibility Check

## Why this exists

The three review skills (`dst-mod-crash-audit`, `dst-badge-visual-audit`, `dst-mod-protocol-audit`)
and the release pre-flight all review **our own code** against how DST behaves *right now*. None of
them tracks **DST drifting underneath us**: Klei patches the game regularly, and a patch can rename a
build, change a component's API or a threshold, drop or rename a `GetClientTable` field, rename an
event or a tag, or change a `TUNING` value. The mod keeps passing its static gates (luacheck / busted
run on our source, not the game) and then **fails or mis-renders in a live game** the first time the
changed surface is hit.

This is not hypothetical — it is exactly how the *original* PartyHUD broke: the engine renamed the
`health` badge build to `status_health`, and the unmaintained mod rendered an invisible heart until the
2026 port re-pointed it. The temperature research for v2026.13 surfaced the same fragility class: our
"danger band" assumes freeze `< 0` / overheat `> 70` are universal — true today, but a game update
that made the overheat threshold character-specific would silently mis-trigger the cue.

So this skill keeps a **dependency surface** — a catalogue of every DST engine touchpoint the mod
relies on, each with the exact ground-truth location in the decompiled scripts and a one-line check —
and re-verifies it whenever the game updates.

## When to run

- **DST got a game update** (Klei pushed a new build) — the primary trigger.
- **Before tagging a release** if DST has patched since the last compat-verify (fold into
  `partyhud-release-preflight`).
- **A teammate reports a break / wrong render after a game update** — run this first to localise it.

## Procedure

### 0. Refresh the ground-truth source

The dependency surface is diffed against the local decompiled scripts at
**`/home/iblis/code/dst/dst-scripts/scripts`**. Update that checkout to the **new** game build before
diffing (re-extract / re-sync however it was sourced — confirm the build matches the updated game).
Note the build you are verifying against so the next run knows the baseline.

### 1. Diff the dependency surface

Open **`references/dependency-surface.md`** — it catalogues every engine API / asset / build / event /
netvar / TUNING / behavioural assumption the mod depends on, grouped into six sections (engine
singletons & entities; identity/avatar/skins; status components; wire/netvars/shard-RPC/events; badge
widgets/builds/UI; sandbox/TUNING/enums/Lua). Each row carries a **Verify after a DST update** cell
with the exact `grep`/check to run against the refreshed `dst-scripts`.

Run each row's Verify check. Work section by section (the file is large); the high-risk sections are
**status components** (the temperature/moisture thresholds + classified fields) and **badge widgets /
builds** (the build/atlas/anim names — the original break class).

### 2. Flag and assess mismatches

Any check that no longer matches = a likely break. Read that row's **Break risk & symptom** column to
judge severity:
- **Crash** (renamed/removed function with no nil-guard) — hard ship-blocker.
- **Silent wrong render / vanished badge** (renamed field/build/event behind an or-fallback or
  nil-guard) — equally important, harder to notice; these are the ones a no-player smoke misses.

Fix the mod against the new surface, then update the affected rows in
`references/dependency-surface.md` to the new ground truth.

### 3. Static gates

`luajit spec/run_local.lua` (busted) + `luacheck .` (0/0). These prove our pure logic still holds, but
they run on our source — they do **not** exercise the changed game surface, so they are necessary, not
sufficient.

### 4. In-engine load-smoke (with a player)

Push to the beta/modtest channel (`partyhud-beta-upload`) and connect a player — a no-player smoke
freezes the per-tick path (`pause_when_empty`) and misses tick-path breaks. Exercise the surfaces the
update touched (e.g. if a status component changed: stand in the danger band, go ghost, migrate shard).
See `partyhud-release-preflight` gate 5 for the per-feature smoke list.

## Maintaining the dependency surface

`references/dependency-surface.md` is only as good as it is current. **Add a row whenever a feature
introduces a new engine dependency.** Concretely, the in-flight **v2026.13** (temperature + moisture
sub-rings) adds: `components.temperature:GetCurrent()` / `.overheattemp` / `.rate`,
`components.moisture` / `player_classified.moisture`, the `moisturedelta` event, and
`TUNING.OVERHEAT_TEMP` / `MIN_ENTITY_TEMP` / `MAX_ENTITY_TEMP` — add these with their ground truth and
verify checks as that release lands (it is the planned first dogfood of this skill).

**Character-specific-threshold watch:** the surface records that freeze (`current < 0`) and overheat
(`current > overheattemp`, default `TUNING.OVERHEAT_TEMP = 70`) are universal across characters today —
only insulation (rate) and hurt-rate differ. If a DST update ever makes the freeze/overheat THRESHOLD
character-specific, the temperature-danger logic must move from fixed constants to each player's
broadcast `temperature.overheattemp`; flag it loudly here.

## How the surface was built (provenance)

`references/dependency-surface.md` was generated from the mod at master HEAD via a fan-out map of
mod-code ↔ `dst-scripts` (175 raw touchpoints → 137 deduped rows across the six sections). It is a
snapshot, not magic — trust a row only as far as its cited `dst-scripts` file:line, and re-derive when
in doubt.

## Related

`dst-mod-crash-audit` (runtime crash classes in OUR diffs), `dst-badge-visual-audit` (visual parity),
`dst-mod-protocol-audit` (wire design), `partyhud-release-preflight` (ship checklist — this skill is a
precondition when DST patched since the last release). Memory: `dst-headless-testing-research`,
`partyhud-2026-mod`.
