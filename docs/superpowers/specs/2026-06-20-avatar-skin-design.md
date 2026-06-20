# PartyHud 2026 v2026.11 — Teammate avatar reflects player skin (base_skin)

**Status:** design approved (co-designed 2026-06-20). Ships in v2026.11.

## Goal

Make the teammate avatar reflect each player's chosen character skin (`base_skin`,
e.g. `wilson_formal`) instead of the hard-coded plain `prefab.."_none"` head — in
**both** the centre and corner avatar styles.

## Background — current architecture

The avatar widget (`scripts/widgets/partybadge.lua`, `SetAvatar`) currently renders
two *different* things depending on the configured style:

- **centre** — an animated `UIAnim` head (`avatar_head`) in the ring centre, built via
  `GetPlayerBadgeData` + `SetSkinsOnAnim`. Its base build is hard-coded to
  `prefab.."_none"` (the default skin), so it never reflects a player's skin.
- **corner** — a *flat* `Image` (`avatar_corner`) drawn from the always-loaded
  `images/avatars.xml` atlas (`avatar_<prefab>.tex`). It is a static KTEX, not the
  animated head, so it inherently cannot show a skin. The always-loaded atlas is what
  makes a far / mod-character teammate show *something* (a generic head) instead of
  crashing or rendering blank.

The `effective_avatar_style` thermal flip (centre-config + a local thermal arrow →
effective "corner") exists because the centre head covers the HP-rate arrow; flipping
to corner frees the centre for the arrow.

`base_skin` is available cluster-wide from `TheNet:GetClientTable()[i].base_skin`
(verified on the live modtest server: `wathgrithr_none`, `wilson_none` for unskinned
players; would be `*_formal` etc. for a skinned player). So foreign / cross-shard
teammates carry it too — zero new wire data needed. The pure module
`partyhud_avatar.identity_changed` already accepts a `base_skin` snapshot field.

A DST character's **head appearance (face / hair) is determined by `base_skin`** alone.
Clothing items (torso / hand / legs / feet) are body slots that do not show on a
head-only avatar, and hats are already `Hide()`d. So "reflect the full outfit, head
only" reduces to "apply `base_skin` as the head's base build".

## Design — unify on the animated head, with a flat fallback

Replace the two-widget split with **one animated head** that has two geometry presets,
plus a flat-image fallback for characters whose head cannot be built:

- The avatar render is decided by (1) the effective style (`off` / `corner` / `centre`)
  and (2) whether the prefab's head is **renderable** as an animated head —
  `classify(prefab) ∈ {base, random}`.
- **Renderable character** → animated `UIAnim` head in *either* style, with a
  style-specific geometry preset (centre = large + centred; corner = small + top-left).
  The base build is the validated `base_skin`, so the skin shows in **both** styles.
- **Non-renderable character** (`mod` / `unknown_named` / `unknown`) → the flat
  `Image` from the always-loaded atlas, positioned per style. Preserves the crash-proof
  fallback (a teammate playing a mod character the receiver lacks still shows a generic
  head, never blank / crash).

### Behaviour matrix

| character | centre style | corner style |
|---|---|---|
| base / random (renderable) | animated head, **skin**, centre geom (UNCHANGED from today for the common case) | animated head, **skin**, corner geom (NEW — was flat) |
| mod / unknown (non-renderable) | flat image, centred geom (CHANGE: was wilson-default animated head) | flat image, corner geom (UNCHANGED) |

The only change on the **default + common** path (renderable character in centre style)
is the base build switching from `prefab.."_none"` to `base_skin` — i.e. it now shows
the skin. The animated-head geometry / pose / z-order on the centre path is otherwise
identical to today's verified behaviour. The one edge-case change is a mod/unknown
character in *centre* style now showing the flat generic head instead of a wilson-default
animated head — arguably more correct, and a rare case on this server.

### `base_skin` plumbing

- `modmain.lua` cluster-roster gather: add `base_skinbyuserid[c.userid] = c.base_skin`
  alongside the existing `name/prefab/colour/userflags` byuserid maps.
- `SetAvatar` gains a 4th parameter `base_skin`. Both call sites pass it:
  - local (≈ line 617): `b:SetAvatar(v.prefab or prefabbyuserid[v.userid], userflagsbyuserid[v.userid] or 0, false, base_skinbyuserid[v.userid])`
  - foreign (≈ line 717): `b:SetAvatar(prefabbyuserid[rec.userid], userflagsbyuserid[rec.userid] or 0, true, base_skinbyuserid[rec.userid])`
- In `SetAvatar`, `new_identity` includes `base_skin` so a skin change re-triggers the
  rebuild (the pure `identity_changed` already compares it with `""`-coercion).
- The animated build resolves the skin defensively:
  `skin = (base_skin ~= nil and base_skin ~= "" and base_skin) or (prefabname.."_none")`,
  then `GetSkinData(skin)`. An invalid / unresolvable skin → `GetSkinData` nil → fall
  back to `prefabname` build (today's safe path). Skin builds are shipped game assets,
  so rendering does **not** require the receiver to *own* the skin.

### Geometry — corner animated head

The animated head's `GetPlayerBadgeData` scale/y_offset are tuned for the vanilla
scoreboard; the centre path already shrinks them via the pure `avatar_head_geom`
(`AVATAR_HEAD_FIT = 0.6`). The corner preset needs its **own** smaller scale + a
top-left position (the flat `AVATAR_CORNER_SCALE/X/Y` were tuned for the flat image, not
the animated head, so the corner head needs fresh values tuned in-engine).

- Add a pure helper `partyhud_avatar.avatar_head_corner_geom(base_scale, corner_fit,
  corner_x, corner_y)` → `(scale, x, y)`, mirroring the `avatar_head_geom` pattern, with
  module-constant defaults `AVATAR_HEAD_CORNER_FIT` / `AVATAR_HEAD_CORNER_X` /
  `AVATAR_HEAD_CORNER_Y` (provisional; tuned in-engine).
- Add a runtime tuner `PartyHud_AvatarHeadCornerFit(fit, x, y)` in `modmain.lua`,
  mirroring the existing `PartyHud_AvatarHeadFit`, so the corner head can be positioned
  without a reconnect.

### Renderable predicate

Add a pure `partyhud_avatar.head_renderable(classify_result)` → `true` iff the result is
`"base"` or `"random"`. The widget reads `classify(prefab, ...)` (engine lists) and
delegates the boolean here, keeping the anim-vs-flat decision unit-testable.

### Z-order / HP number

- centre: unchanged — head covers the centre, `self.num:MoveToFront()` keeps the HP
  number above it, and the HP number is forced hover-only (existing
  `_hp_number_was_hover` logic).
- corner: the head/flat sits top-left and does not overlap the centre HP number, so no
  `MoveToFront` and the HP number follows its configured visibility — same as the flat
  corner today. `partyhud_badge.layer_order` stays `centre = {ring_art, avatar_head,
  hp_number}` / `corner = {ring_art, hp_number}`.

### Config

No new config option. The avatar style dropdown (off / corner / centre) is unchanged;
the centre default stays. Skin reflection is always-on for renderable characters in
whichever style is active — strictly a more faithful render, and `base_skin` defaults to
`*_none` so unskinned players look identical to today.

## Files touched

- `scripts/partyhud_avatar.lua` — add `head_renderable`; add `avatar_head_corner_geom`
  + the corner constants. (`identity_changed` base_skin support already present.)
- `scripts/widgets/partybadge.lua` — restructure `SetAvatar` to the unified
  anim-or-flat model; add the `base_skin` param + identity field; corner animated-head
  render path + corner geometry; flat fallback for non-renderable in both styles.
  Extend the head-fit override plumbing for the corner preset.
- `modmain.lua` — gather `base_skinbyuserid`; pass `base_skin` to both `SetAvatar`
  calls; add the `PartyHud_AvatarHeadCornerFit` console tuner.
- `spec/avatar_spec.lua` — cover `head_renderable`, `avatar_head_corner_geom`, and the
  `identity_changed` base_skin case (if not already asserted).
- `modinfo.lua` — no change.
- `spec/snapshots/*.json` — no change expected (avatar geometry is not part of the
  layout snapshot, which captures badge positions only). Confirm the suite stays green.

## Testing & verification

- **Unit (busted):** `head_renderable`, `avatar_head_corner_geom`, `identity_changed`
  base_skin. Layout-snapshot goldens must stay green (no layout change).
- **In-engine (modtest, the only way to test the widget half):**
  1. corner style — animated head shows in the corner; equip a character skin on a
     connected player and confirm the corner head reflects it.
  2. mod / unknown character in corner — flat generic head fallback still shows (no
     blank / crash).
  3. centre style — unchanged pose/scale (regression check) **and** skin reflects.
  4. thermal flip — in centre style, trigger a thermal arrow (`dst-thermal`): the head
     moves to the corner (skinned), the centre frees for the HP-rate arrow; clears back
     to centre when thermal ends.
  5. foreign / cross-shard teammate — skin reflects from the `GetClientTable` base_skin.
  6. tune the corner head geometry via `PartyHud_AvatarHeadCornerFit` until it sits
     cleanly inside the top-left of the ring.

## Out of scope

- Per-item clothing reflection (torso / hand / legs / feet). Not visible on a head-only
  avatar, and not carried cluster-wide for foreign players — `base_skin` is the complete
  answer for the head.
- Skinned *flat* corner textures for mod/unknown characters (no always-loaded skinned
  atlas; would break the crash-proof guarantee).
