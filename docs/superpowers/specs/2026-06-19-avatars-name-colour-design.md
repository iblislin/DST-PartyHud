# PartyHud 2026 v2026.11 — Character Avatars + Name Colouring — Design

**Status:** approved (brainstorm + research workflow `w7w2yuxlh`, 2026-06-19), pending spec review →
implementation plan.

**Goal:** Give each teammate badge per-player identity — the character's avatar in the badge, and the
teammate's name in their own player colour — so PartyHud stops looking identical to every other
PartyHUD mod. **Almost entirely client-side render**: cross-shard identity rides an existing
cluster-wide channel (`GetClientTable`), so there is **no wire-protocol change**.

**Why:** FEATURE-IDEAS Top-5 #3. The badge centre today is generic (HP number + a faint heart glyph).
Avatars + name colour are the highest-value visual differentiator and a common community ask.

---

## Locked decisions

1. **Avatar render styles, user-selectable via one curated dropdown:** `Off / Corner / Centred head`.
   - `Corner` — a small flat avatar `Image` inset in a badge corner; HP fill ring + number unchanged.
   - `Centred head` — an animated character head (Klei scoreboard style) in the ring centre; the HP
     number becomes hover-only so the face shows.
   - Optional 4th entry `Centred (flat)` (flat image in the centre, no animation) — deferred
     nice-to-have, ship only if wanted. **`head+corner` is dropped** (illegible at inset size + pays
     per-frame anim cost a tiny corner can't justify). SOURCE×POSITION are technically independent
     (all 4 combos render), but only 3 are useful.
   - A **debug console fn** switches styles instantly in modtest; the user picks the ship default after
     an in-game compare.
2. **Cross-shard identity comes from `TheNet:GetClientTable()` client-side — ZERO new wire data.** The
   table is cluster-wide and already carries `{prefab, colour, base_skin, userflags, name, userid}` for
   every player on both shards; the mod already reads it (`modmain.lua:540-545`) to build
   `namebyuserid`. Build `prefabbyuserid` / `colourbyuserid` / `userflagsbyuserid` the same way and join
   by `userid` in `UpdateBadges`. **No codec bump, no new netvar/RPC/store.** (Codec v3 with a per-record
   `prefab` is demoted to a documented contingency — see Out of scope.)
3. **Name colour** applies to local AND cross-shard teammates, reconciled with foreign-dim via a
   single-writer helper. Default On (config toggle).
4. **Config:** dropdown `Teammate avatar: Off / Corner / Centred head` + toggle `Name colour: On/Off`
   (default On). Both client options.

---

## Data sources (all client-side reads — no server hook, no netvar)

| What | Local teammate (`AllPlayers` entity `v`) | Cross-shard / foreign teammate |
|---|---|---|
| Character prefab | `v.prefab` | `GetClientTable()[i].prefab` (cluster-wide) |
| Avatar texture | `GetCharacterAvatarTextureLocation(prefab)` → `(atlas, tex)` | same fn on the table prefab |
| Player colour | `v.playercolour` | `GetClientTable()[i].colour` |
| ghost / were / stage (animated head) | entity tags / `GetPlayerBadgeData` | `GetClientTable()[i].userflags` bits |

- Player colour is **server-assigned in join order** from a fixed 24-colour warm palette
  (`GetAvailablePlayerColours`, `networking.lua:671-714`) — not user-chosen, not name-hashed; stable
  within a session. Both reads are `{r,g,b,a}` 0-1 tables, directly usable in `SetColour`.
- `GetCharacterAvatarTextureLocation` (`characterutil.lua:72-90`) resolves base/registered-mod/random
  chars and falls back to `avatar_mod.tex` (named-but-unregistered) / `avatar_unknown.tex` (empty/nil) —
  in the base `images/avatars.xml` atlas (already loaded; `SetTexture` is synchronous, no mod `Asset`).
  So even a far modded teammate whose mod the receiver lacks shows a generic mod head, never a crash.

---

## Components / files

### New pure module `scripts/partyhud_avatar.lua` (busted-tested)
Pure, engine-free decision logic (same pattern as `partyhud_layout`/`_record`/etc.):
- `M.classify(prefab, dst_charlist, mod_charlist)` → `"base"|"mod"|"random"|"unknown"` — mirrors
  `characterutil.lua:82-87` (non-empty unknown name → the `mod` fallback bucket; nil/`""` → `unknown`).
- `M.atlas_and_tex(prefab, classify_result, mod_avatar_locations)` → `(atlas, tex)` — the fallback
  table (base/random→`images/avatars.xml`+`avatar_<p>.tex`; registered-mod→`mod_loc`+`avatar_<p>.tex`;
  unregistered→`avatar_mod.tex`; unknown→`avatar_unknown.tex`).
- `M.packidflags{ghost,were1,were2,stage3}` / `M.unpackidflags(n)` — bit round-trip for the animated
  head state, sourced from `GetClientTable().userflags` (USERFLAGS `IS_GHOST=1`/`CHARACTER_STATE_1=4`/
  `_2=8`/`_3=32`, `constants.lua:2383-2388`). Mirrors the existing `packflags`/`unpackflags`.
- `M.identity_changed(prev, new)` → bool — prev-vs-new identity (prefab + idflags + optional base_skin)
  → whether the badge avatar needs a refresh (the cheap change-gate for the per-refresh join).
- `M.resolve_avatar_style(config_value)` → `"off"|"corner"|"centre"` — config→style; unknown/nil → `off`;
  never yields the dropped `head-corner`.
- `M.name_colour(playercolour, is_foreign, foreign_dim)` → `{r,g,b,a}` — the `_apply_name_colour`
  reconciliation as a pure fn: local → `{r,g,b,1}`; foreign → `{r,g,b, a*foreign_dim}`; **nil or a
  not-ready `{1,1,1,1}` → GREY `{0.6,0.6,0.6,a}`** (= `DEFAULT_PLAYER_COLOUR`, NOT white).
- `M.is_low_contrast(playercolour)` → bool (OPTIONAL) — true only for BROWN/VIOLETRED/DARKPLUM
  (the 3 low-luminance palette colours); ship only if a contrast decision actually lands in code.

### `scripts/widgets/partybadge.lua`
- `PartyBadge:SetAvatar(prefab, idflags, is_foreign)` — per-refresh; sets/clears the avatar for the
  current style. `prefab == nil` → unknown avatar.
  - `corner`: a flat `Image` child, `SetTexture` from the resolved atlas/tex; HP ring + number untouched.
  - `centre`: an animated head `UIAnim` child — port `playerbadge.lua`: `GetPlayerBadgeData(character,
    ghost, state_1, state_2, state_3)` (`skinsutils.lua:1903-1947`) → bank/anim/skin_mode/scale/y_offset,
    then `SetSkinsOnAnim(animstate, prefab, base_build, {}, nil, skin_mode)` (**`components/skinner.lua:11`**
    — NOT skinsutils). HP number forced hover-only while this style is active. Consider honouring
    `Profile:GetAnimatedHeadsEnabled()` for per-badge perf parity across N badges.
- `_apply_name_colour()` — **single-writer** for `self.name`'s colour, reconciling {player colour,
  foreign-dim}. `SetForeign`/`SetName` route through it; it REPLACES the current hard
  `self.name:SetColour(1,1,1,a)` at `partybadge.lua:376`. Keep the font drop shadow (the badge name uses
  the non-outline `BODYTEXTFONT`, so the shadow carries the 3 low-contrast colours — vanilla-consistent).
- Coexistence: a centre avatar collides ONLY with the optional HP number (→ hover-only) and the dead
  skull (mutually exclusive, shown via `ShowDead`). Sub-rings (`SUB_Y=-42`), name (+40), foreign label
  (+50), low-HP ring-border breathe (on `circleframe`), HP fill arc (on `self.anim`) all coexist.

### `modmain.lua` (client-side only)
- In the refresh path, build `prefabbyuserid` / `colourbyuserid` / `userflagsbyuserid` from
  `GetClientTable()` alongside the existing `namebyuserid` (~`modmain.lua:540-545`). In `UpdateBadges`,
  for each badge join the per-tick **status** (HP/hunger/sanity, unchanged) to **identity** by `userid`
  (local: read the entity; foreign: read these tables) and call `b:SetAvatar(...)` + the name-colour set.
- **Debug console fn** `PartyHud_AvatarStyle("off"|"corner"|"centre")` — module-level current style +
  relayout, for instant modtest comparison. Any non-whitelisted global it uses must be `GLOBAL.*`.
- Config read for `avatar_style` + `name_colour`, applied per-badge like the existing `low_hp_threshold`.
- **No change to `build_local_records` / the codec / the broadcast task** — identity does not ride the
  wire. (This is why the feature does not touch the cross-shard crash path.)

### Event-driven identity (why GetClientTable is the right source)
Identity is static for a session, changing only on discrete events: join/character-select, `ms_becameghost`/
`ms_respawnedfromghost`, woodie weremode / wormwood stage, skin change, migration, and the rare prefab
swap (wonkey/monkey-curse). The engine already maintains `GetClientTable()` on-change cluster-wide — so
reading it per-refresh (cheap; or gated by `identity_changed`) IS the event-driven design, with no mod
machinery. Decision ladder: (1) **GetClientTable client-side join** [chosen]; (2) a separate on-change
identity channel (a 2nd `net_string` carrier + identity shard-RPC mirroring the status topology) ONLY if
a real gap appears; (3) folding identity into the per-tick codec — **avoid** (pays per-tick cost + can't
carry ghost/were without more bytes).

### `modinfo.lua`
- `version` → `2026.11`.
- `avatar_style` dropdown (Off / Corner / Centred head; optionally + Centred (flat)); default = the
  chosen ship style. `name_colour` toggle (On/Off, default On). Both `client = true`.

---

## Testing & safety
1. **busted** (pure modules): `partyhud_avatar` — classify; atlas_and_tex fallback table;
   packidflags/unpackidflags bit round-trip; `identity_changed` (change vs no-change);
   `resolve_avatar_style` (each value + unknown→off + never head-corner); `name_colour` (local; foreign
   dim; nil/`{1,1,1,1}`→GREY). Optional `is_low_contrast` (exactly the 3 colours). (Codec round-trip
   specs only if the contingency codec route is ever taken.)
2. **luacheck 0/0** + **stylua --check**.
3. **`dst-mod-crash-audit`** — lighter than usual: the feature adds CLIENT-side render only (no server
   hook, no wire change), so the blast radius is the local client, not the shard. Still sweep the new
   `UpdateBadges` identity-join + `SetAvatar` for nil/wrong-inst.
4. **`partyhud-release-preflight`** before tagging — incl. the in-engine load-smoke with a connected
   player, and a **2-shard in-game test** to confirm a far teammate's avatar + colour + ghost state
   render correctly from `GetClientTable`.
5. Ship **v2026.11** via the release CI (with the crash-guard, per its own spec).

## Out of scope / deferred
- **Codec-v3 prefab field** — kept as a *documented contingency* only for a same-shard mod-character
  peer whose mod the receiver lacks (which itself degrades to `avatar_mod.tex`). Not implemented unless
  the GetClientTable path proves insufficient in testing.
- Full skin fidelity (`base_skin` clothing) on the animated head — start with the plain character head.
- Colourblind remap / per-colour luminance clamp — DST has no colourblind mode to inherit; the drop
  shadow suffices for the 3 low-contrast colours. Audio / non-visual cues. Changing existing behaviour.

## Open questions
- Ship-default avatar style (after the in-game compare) — user decides.
- Whether to ship the optional `Centred (flat)` 4th dropdown entry.
