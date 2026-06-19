# PartyHud 2026 v2026.11 — Character Avatars + Name Colouring — Design

**Status:** approved (brainstorm 2026-06-19), pending spec review → implementation plan.

**Goal:** Give each teammate badge per-player identity — the character's avatar in the badge, and the
teammate's name rendered in their own player colour — so PartyHud stops looking identical to every
other PartyHUD mod. Client-side render feature; cross-shard avatar support needs one wire-protocol bump.

**Why:** FEATURE-IDEAS Top-5 #3. The badge centre today is generic (HP number + a faint heart glyph).
Avatars + name colour are the single highest-value visual differentiator and a common community ask.

---

## Locked decisions (from the brainstorm)

1. **Two avatar render styles, both shipped, user-selectable:**
   - `corner` — a small flat avatar image inset in a badge corner; the HP fill ring + number stay
     exactly as today.
   - `centre` — an animated character head in the ring centre (Klei scoreboard style, skin/ghost
     aware); the HP number becomes hover-only so the face is visible.
   - A **debug console function** switches them instantly in modtest; the shipped control is a config
     dropdown (below). The user compares both in-game and picks the default to ship.
2. **Cross-shard avatars: extend the wire codec to protocol v3** with a per-record `prefab` string, so
   far/other-shard teammates also show their real avatar (not a generic head).
3. **Name colour** applies to local AND cross-shard teammates (colour is already client-readable
   cluster-wide); reconciled with the foreign-dim via a single-writer helper.
4. **Config:** one dropdown `Teammate avatar: Off / Corner / Centred head` + one toggle
   `Name colour: On / Off` (default On). Both client options.

---

## Data sources

| What | Local teammate (`AllPlayers` entity `v`) | Cross-shard / foreign teammate |
|---|---|---|
| Character prefab | `v.prefab` (public client field) | **NEW:** carried in the codec v3 `prefab` field |
| Avatar texture | `GetCharacterAvatarTextureLocation(prefab)` → `(atlas, tex)` | same fn, on the received prefab |
| Player colour | `v.playercolour` (`{r,g,b,a}` 0-1) | `TheNet:GetClientTable()[i].colour` (cluster-wide) |

- `GetCharacterAvatarTextureLocation` (game `characterutil.lua`) resolves base chars, registered mod
  chars, and falls back to `avatar_mod.tex` / `avatar_unknown.tex` (in the base `images/avatars.xml`)
  for unknown/unregistered — so a modded far teammate whose mod the receiver lacks shows a generic mod
  head, never a crash / missing texture.
- `images/avatars.xml` is a base-game atlas — **no mod `Asset` declaration needed**, and `SetTexture`
  against an already-loaded base atlas is synchronous.
- Name colour is **not** owner-only classified data (unlike HP/hunger/sanity) — it is public client
  data, so name colour needs **no new server hook / netvar**. Only the cross-shard *avatar* needs new
  wire data.

---

## Components / files

### New pure module `scripts/partyhud_avatar.lua` (busted-tested)
Pure prefab→avatar decision logic, no engine deps (same pattern as `partyhud_layout`/`_record`/etc.).
The widget/modmain read engine values and delegate. Functions:
- `M.classify(prefab, dst_charlist, mod_charlist)` → `"base" | "mod" | "random" | "unknown"` — mirrors
  the game's `playerbadge.lua` classification (which list the prefab belongs to). The caller passes the
  game's `DST_CHARACTERLIST` / `MODCHARACTERLIST` so the module stays engine-free and testable.
- `M.atlas_and_tex(prefab, classify_result, mod_avatar_locations)` → `(atlas, tex)` — the same mapping
  `GetCharacterAvatarTextureLocation` does, but as a pure function we can unit-test the fallback table
  (unknown→`avatar_unknown.tex`, unregistered-mod→`avatar_mod.tex`, base→`images/avatars.xml`).
  (Implementation note: the widget MAY call the game `GetCharacterAvatarTextureLocation` directly and
  this module exists to pin the fallback decisions in tests; final split decided in the plan, but the
  fallback rules MUST be busted-covered.)

### `scripts/partyhud_statuscodec.lua` — protocol v3
- `PROTOCOL_VERSION` → `3`. Encoder appends a `prefab` string field after `origin`.
- Decoder handles **v1 / v2 / v3**: v3 record = v2 fields + `prefab`; v1/v2 records decode with
  `prefab = nil` (→ receiver falls back to unknown avatar). Unknown/unsupported version → ignored
  (existing behaviour, unchanged).
- Field-count guard updated per version (`NUM_FIELDS` math already version-branched for v2; add the v3
  branch). Prefab is a lowercase identifier — safe inside the `:`-delimited record (no separator clash).

### `scripts/widgets/partybadge.lua`
- `PartyBadge:SetAvatar(prefab, is_foreign)` — called per-refresh; sets/clears the avatar for the
  current style. `prefab == nil` (a v1/v2 foreign peer) → unknown avatar.
- **Style `corner`:** a flat `Image` child (lazily created) positioned in a corner; `SetTexture`
  from the resolved atlas/tex. HP ring + number untouched.
- **Style `centre`:** an animated head `UIAnim` child in the ring centre — port the
  `playerbadge.lua` pattern (`GetPlayerBadgeData(character, ghost, …)` + `SetSkinsOnAnim`); HP number
  forced hover-only while this style is active.
- `_apply_name_colour()` — **single-writer** for `self.name`'s colour, reconciling {player colour,
  foreign-dim alpha}. `SetForeign` and `SetName` route through it (today `SetForeign` hard-sets the
  name to `{1,1,1,a}`; it must instead re-assert `{r,g,b,a*dim}`). Mirrors the existing
  `_apply_frame_colour` discipline exactly. Keep the font's existing drop shadow for dark-colour
  legibility.
- Foreign-dim, low-HP red-heart breathe (on `circleframe`), HP fill arc (on `self.anim`), skull/dead,
  and the sub-rings all coexist: the avatar occupies the centre hole (centre style) or a corner
  (corner style) and does not overlap the HP arc or the ring-border breathe.

### `modmain.lua`
- **Refresh loop (`UpdateBadges`):** local path passes `v.prefab` + `v.playercolour`; foreign path
  passes the record's `prefab` (codec v3) + a new `colourbyuserid[userid]` built from
  `GetClientTable()` alongside the existing `namebyuserid`. Calls `b:SetAvatar(...)` and the
  name-colour set. (The prefab/colour read stays in modmain; the badge delegates the rendering.)
- **`build_local_records`:** add `prefab` to each record (server-side, from the player entity's
  `prefab`). This is the only server-touching change; it feeds the codec v3 encoder.
- **Debug console fn** `PartyHud_AvatarStyle("corner"|"centre"|"off")` — sets a module-level current
  style + relayouts, for instant modtest comparison (no resubscribe). Sandbox rule: any non-whitelisted
  global it uses must be `GLOBAL.*`.
- Config read for the new options (the dropdown + the name-colour toggle), per-badge applied like the
  existing `low_hp_threshold`.

### `modinfo.lua`
- `version` → `2026.11`.
- New client options: `avatar_style` (dropdown: Off / Corner / Centred head; default = the chosen
  ship style) and `name_colour` (On/Off, default On). Both `client = true`.

---

## Testing & safety (the gate sequence)

1. **busted** (pure modules — the regression net for the fiddly bits):
   - `partyhud_avatar`: classify + atlas/tex fallback table (base / mod / unregistered-mod→`avatar_mod`
     / unknown→`avatar_unknown` / random).
   - `partyhud_statuscodec` v3: round-trip a record WITH `prefab`; v1/v2 payloads decode with
     `prefab = nil`; a v3 payload's prefab survives encode→decode; version-branch field-count guards.
   - the `_apply_name_colour` reconciliation if extracted (colour × foreign-dim).
2. **luacheck 0/0** + **stylua --check** (the new CI gates).
3. **`dst-mod-crash-audit` (full 6-dimension)** — codec v3 touches the cross-shard path that crashed
   before (the bare-`tonumber` incident lived in this exact area), so a full re-audit is mandatory;
   pay special attention to D4 (sandbox globals in the new modmain code + the debug fn) and D6 (the
   prefab string field doesn't break decode / no owner-only-classified read for colour).
4. **`partyhud-release-preflight` skill** before tagging — incl. the in-engine load-smoke **with a
   connected player** (the `pause_when_empty` masking rule) and a **2-shard in-game test** to verify a
   far teammate's real avatar arrives over the v3 blob and renders dimmed-but-correct.
5. Ship **v2026.11** via the release CI (tag `v2026.11` → zip/tar.gz + GitHub Release), then public
   Workshop upload + prod sync.

---

## Out of scope / deferred

- Animated-head skin fidelity beyond the base character head (full `base_skin` plumbing) — start with
  what `GetPlayerBadgeData` gives; richer skin handling is a follow-up only if it looks wrong.
- Audio / any non-visual cue.
- Changing the existing HP/hunger/sanity/low-HP/cross-shard behaviour — this feature is additive.

## Open questions

None blocking. The ship-default avatar style is chosen by the user after the in-game comparison; both
styles ship as config options regardless.
