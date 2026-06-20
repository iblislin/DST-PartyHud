# PartyHud 2026 v2026.13 — Temperature + Moisture sub-rings & display polish

**Status:** design approved (co-designed 2026-06-21). One release, v2026.13.

## Goal

Add two new on-demand teammate status sub-rings — **temperature** and **moisture** — plus a
consolidated **hover detail panel**, and three pure-client display QoL options (a compact/detail badge
toggle, a hide-HUD toggle, and a name font-size choice). This release also **dogfoods the
`dst-game-update-compat` skill** (it introduces new DST engine dependencies — see §8).

## Scope decision

The user chose to ship the "richer status data" (temperature + moisture, which need new netvars +
cross-shard codec work — the crash-prone surface) together with the "display & density" QoL in ONE
release. So v2026.13 spans a data layer (B) and a display layer (A); each component is described below.

---

## 1. Data layer — temperature + moisture broadcast (new netvars + codec v3)

Temperature and moisture are **owner-only** (they live on `player_classified`, broadcast only to the
owning client — confirmed in the dependency surface). To show a teammate's values we must broadcast
them server-side, exactly as the mod already does for HP/hunger/sanity.

**Per-player broadcast (same pattern as the existing `customhpbadge*` netvars):**
- **Temperature**: the player's `components.temperature:GetCurrent()` (a float, engine-clamped to
  `MIN_ENTITY_TEMP=-20 .. MAX_ENTITY_TEMP=90`), rounded to an integer degree, encoded with a **+20
  offset → 0..110 → `net_byte`** (0-255 range, never overflows). Plus a **rate descriptor** (steady /
  warming / cooling, optionally fast variants) in a `net_tinybyte`, read from `temperature.rate`, for
  the "changing fast" popup condition and a rate arrow.
- **Moisture**: `0..100` (from the moisture replica / classified), a `net_byte`. Plus a **wetting /
  drying rate direction** (`net_tinybyte`) for the moisture rate arrow.
- These are written in the existing periodic broadcast task (which already runs per server tick) +
  optionally nudged on `temperaturedelta` / `moisturedelta` events; both events are already known to
  the mod. No new event-hook machinery beyond reading two more component values per cycle.

**Cross-shard: bump the codec `v2 → v3`** (`partyhud_statuscodec`). Add the temperature, temp-rate,
moisture, and moisture-rate fields to the serialized record. Decode stays **backward-tolerant**: a v2
peer's record yields nil for the new fields → the receiver renders those sub-rings as "off" (graceful
degrade), exactly as the v1→v2 `origin`-field addition did.

**Popup decisions are PURE client modules** (busted-testable, zero engine deps), fed the broadcast
values:
- `temp_popup(current, rate, cold_show, hot_show, rate_fast)` → `{show, kind}` where kind ∈
  {cold, hot} — show when `current ≤ cold_show` OR `current ≥ hot_show` (danger band) OR the rate is
  fast toward an extreme.
- `moisture_popup(moisture)` → show when `moisture > 0`.

---

## 2. Sub-rings — four around the main HP ring (on-demand)

The badge already has two sub-rings below the main HP ring: **hunger (bottom-left)** and **sanity
(bottom-right)**. Add the two new sub-rings **hugging the HP ring's perimeter**, each tucked **closely
aside its existing neighbour**: moisture just **up-and-left of hunger**, temperature just
**up-and-right of sanity** — so the four ride the ring's edge as a clustered arc, NOT floating at the
top of the badge:

```
   moisture                    temperature
       \  ·  (  HP ring  )  ·  /
   hunger ·                · sanity
```

- **Moisture** sub-ring: **closely aside the top-left of hunger**, hugging the HP ring edge, blue.
  Appears when `moisture_popup` is true.
- **Temperature** sub-ring: **closely aside the top-right of sanity**, hugging the HP ring edge,
  **cold = cyan / hot = red-orange**. Appears when `temp_popup` is true.
- Both are the same small `SUB_SCALE` ring style as hunger/sanity (a `Badge(nil, …, build, …)` like the
  existing sub-rings). The intent is each new ring sits **adjacent to its neighbour along the ring's
  curve** (a short arc up from hunger / sanity), not a vertical mirror at the badge top: moisture near
  hunger's upper-left, temp near sanity's upper-right. Exact offsets tuned in-engine — keep them tucked
  against the HP ring (so the four read as one cluster) while clearing the name label above and the
  corner avatar.
- **On-demand**: shown only when their popup predicate is true; hidden otherwise (like the vanilla
  `moisturemeter` / the thermal arrow). Each carries a small **rate arrow** (reuse the sanity-rate
  arrow mechanism) when its rate descriptor is non-steady.
- **Hover** a sub-ring shows its number (existing per-ring hover behaviour); the consolidated panel
  (§3) shows all at once.

**Config:** two new per-player options, each `On-demand / Off` (default **On-demand** — this is the
release's headline). `Off` hides that sub-ring entirely (and the broadcast can still run; the client
just doesn't render it).

**Layout impact:** the four-around-the-ring arrangement keeps each badge within its existing footprint
(no new sub-row), so the **column/wrap layout math is unaffected** — `compute_badge_positions` and the
backpack/dodge logic do not change. The **layout-snapshot goldens should not move** (they capture
badge POSITIONS, not intra-badge sub-ring geometry); confirm they stay green. The intra-badge sub-ring
offsets are new constants, tuned in-engine.

---

## 3. Hover detail panel

Hovering a teammate's badge pops a consolidated **detail panel** (a text block / tooltip) showing every
current stat at once, so a player can read the full picture without hovering each ring:
- HP `cur / max` (+ max-penalty if any)
- Hunger, Sanity (+ sanity rate)
- **Temperature °**, **Moisture %**
- Active flags: on-fire / overheating / freezing
Built with the standard widget focus handler (the badge is already a focusable widget). For a far /
cross-shard teammate the panel shows what the broadcast carries (temp/moisture included; the live
thermal flags are forced-neutral for far players as today).

---

## 4. Display QoL (pure client)

- **Compact / detail toggle** — a keybind that flips ALL badges between **compact** (main HP ring +
  name only; hide the sub-rings + numbers + avatar) and **detail** (the full badge). Complements the
  existing static `show_substatus` config (that's the persistent default; this is a runtime flip).
  Keybind is a **rebindable config spinner** (`configuration_options` with `KEY_*` data values +
  `TheInput:AddKeyDownHandler(GetModConfigData(...), fn)`), default **`KEY_O`** (free by default in DST;
  away from the WASD/F combat cluster), with a **None** option to disable.
- **Hide-HUD toggle** — a keybind to hide/show the whole party HUD. Same rebindable-config-spinner
  pattern, default **`KEY_H`** (free by default), with **None** to disable.
- **Name font size** — a per-player config: **Small / Medium / Large**. The name `Text` widget's
  hard-coded `SetSize(20)` becomes the chosen size. Note: a larger name needs the badge's vertical
  reservation to account for it so it does not overlap the row above — but with the four-around-the-ring
  sub-ring layout the name still sits above the badge as today, so this is a contained tweak; the
  cross-shard "elsewhere" label (`SetForeign`'s soft-blue label) should use the same size.

DST key facts (researched 2026-06-21 vs dst-scripts): occupied default single keys are
WASD / Q / E / F / I / M / Y / U / Tab / backtick / Backspace / Esc / Enter / Space / 1-0 / `/`. Free
single keys include B C G H J K L N O P R T V X Z — hence the O / H defaults (both free, ergonomic).

---

## 5. Character-specific thresholds (research note — keep universal for now)

Researched vs `dst-scripts` (`components/temperature.lua`): freezing is hardcoded
`temperature.current < 0` and overheating is `current > temperature.overheattemp` (default
`TUNING.OVERHEAT_TEMP = 70`), **universal across all characters** — only insulation (rate) and hurt-rate
differ per character/item; no base-game character changes the THRESHOLD. So the temp danger-band uses
**fixed constants** (cold-show / hot-show anchored to 0 / 70 with a lead margin, tuned in-engine), with
a code comment: *if a future DST update or mod makes the freeze/overheat threshold character-specific,
switch from the constants to each player's broadcast `temperature.overheattemp`.* (This is recorded in
the `dst-game-update-compat` dependency surface.)

---

## 6. Pure modules / files touched

- `scripts/partyhud_status.lua` (or a new pure module): `temp_popup` + `moisture_popup` decision logic
  + the temp/moisture clamps; add specs.
- `scripts/partyhud_statuscodec.lua`: codec **v3** — add temp / temp-rate / moisture / moisture-rate
  fields; backward-tolerant decode; bump the protocol version byte; extend the round-trip self-check +
  the codec spec.
- `scripts/partyhud_record.lua`: `normalize_local` / `normalize_foreign` carry the new fields (clamps;
  far players keep live thermal-flag neutralisation but DO carry temp/moisture values).
- `scripts/widgets/partybadge.lua`: the two new sub-rings (top-left moisture / top-right temp) + their
  on-demand show/hide + rate arrows + colours; the hover detail panel; the compact/detail apply; the
  name font-size apply. New intra-badge geometry constants.
- `modmain.lua`: read + broadcast temperature + moisture in the periodic task (and on
  `temperaturedelta` / `moisturedelta`); wire the two keybinds via `TheInput:AddKeyDownHandler` +
  `GetModConfigData`; pass the new values to the widgets.
- `modinfo.lua`: new config options — `show_temperature` (On-demand/Off), `show_moisture`
  (On-demand/Off), `key_compact` (KEY spinner + None, default O), `key_hide_hud` (KEY spinner + None,
  default H), `name_size` (Small/Medium/Large).
- `spec/*`: specs for `temp_popup` / `moisture_popup` / codec v3 / record fields; layout-snapshot goldens
  re-confirmed unchanged.
- `.claude/skills/dst-game-update-compat/references/dependency-surface.md`: **add rows** for the new
  dependencies (see §8).

---

## 7. Testing & verification

- **Unit (busted):** `temp_popup`, `moisture_popup`, codec v3 round-trip + backward-tolerant v2 decode,
  record normalize of the new fields. Layout-snapshot goldens must stay green (no badge-position change).
- **In-engine (modtest, 2-player + 2-shard — the crash-prone surface):**
  1. Temperature sub-ring appears when a teammate enters the danger band (use `dst-thermal cold`/`hot`)
     and when temp changes fast; cold = cyan / hot = red; hides in the comfortable band.
  2. Moisture sub-ring appears when a teammate is wet (rain / `ms_forceprecipitation`) and hides when dry.
  3. Hover detail panel shows HP/hunger/sanity/temp°/moisture% + flags together.
  4. Compact/detail toggle (`O`) flips all badges; hide-HUD (`H`) toggles the whole HUD; both rebind via
     the mod config; `name_size` changes the name without breaking layout.
  5. Cross-shard: a teammate on the other shard reflects temp/moisture (codec v3); a v2 (old) peer
     degrades gracefully (sub-rings off, no crash).
  6. Crash-safety audit (`dst-mod-crash-audit`) of the diff + visual audit (`dst-badge-visual-audit`)
     for the new sub-rings; the modmain/netvar/codec changes get the connected-player tick smoke.

## 8. Dogfood `dst-game-update-compat` (first use of the new skill)

This release adds new DST engine dependencies — **add their rows to
`references/dependency-surface.md`** as part of the work:
- `components.temperature:GetCurrent()` / `.rate` / `.overheattemp`; `IsFreezing` (`current < 0`) /
  `IsOverheating` (`current > overheattemp`) semantics.
- the moisture source (`components.moisture` / `player_classified.moisture`) + the `moisturedelta` event.
- `TUNING.OVERHEAT_TEMP` / `MIN_ENTITY_TEMP` / `MAX_ENTITY_TEMP`.
- `TheInput:AddKeyDownHandler` + the `KEY_*` constants used for the keybinds; `GetModConfigData` for the
  key spinners.
Each row carries its dst-scripts ground-truth + a verify check, per the surface format. Running the
preflight gate 4 on this release is the skill's first real exercise.

## 9. Out of scope

- Per-character special-status bars (Tier 4 / FEATURE-IDEAS §5) — not this release.
- Boat-hull HP, equipment peek, AFK indicator, distance/direction, click→ping — backlog.
- Making the temp danger threshold character-specific — deferred unless DST changes the engine threshold.
