# DST Protocol-Design Gotchas — catalog

Reference for `dst-mod-protocol-audit`. DST networking facts (verify against the extracted game source,
commonly `~/code/dst/dst-scripts/scripts/`) + the worked PartyHud examples this skill generalizes from.
Citations are file:line as of the 2026 client; re-verify against the installed source.

## Contents
1. Channels that already replicate data (dim 1)
2. Static vs dynamic data + event-driven delivery (dim 2)
3. Versioning & rolling-update compatibility (dim 3)
4. Netvar types & ranges; encoding compactness vs robustness (dim 4)
5. Malformed / empty / sandbox robustness (dim 5)
6. Single source of truth & testing (dim 6)
7. Worked PartyHud examples

---

## 1. Channels that already replicate data (dim 1)

Before adding ANY wire data, check whether the client can already read it. The most common audit win is
"this protocol change is unnecessary."

- **`TheNet:GetClientTable()` — cluster-wide, on-change, free.** Returns one row per connected player
  **across BOTH shards** (not shard-local), each carrying at least `{userid, name, prefab, colour,
  base_skin, userflags, admin, ...}` (`networking.lua`; the game's own `playerstatusscreen.lua` /
  `redux/playerlist.lua` feed `PlayerBadge` straight from these rows). The engine maintains it on-change,
  so reading it per-refresh IS event-driven delivery with zero mod machinery. Caveat: it does NOT give a
  far player's *entity* (`AllPlayers` is shard-local) — but it gives their identity row.
  - **`userflags` is a bitmask of free state.** It carries `USERFLAGS.IS_AFK=2`, `IS_GHOST=1`, and the
    Woodie weremode / Wormwood stage bits (`constants.lua:2383-2388`) — decode with `checkbit` (the game
    does exactly this at `widgets/playerbadge.lua:IsAFK()`). So **AFK and ghost ride GetClientTable for
    free** — a teammate-HUD AFK/ghost indicator needs no new wire. Caveat: the engine sets these in C++
    (Lua never `AddUserFlag(IS_AFK)`), so they are readable but not script-settable/verifiable, and a
    remote shard row's accuracy is engine behaviour — confirm in a 2-shard test before relying on it.
- **The player entity (client-side).** For a player on THIS shard (`AllPlayers`), public fields are
  readable client-side: `inst.prefab` (character), `inst.playercolour` (`{r,g,b,a}` 0-1, from
  `player_common.lua:1013`). NOT owner-only-classified — unlike HP/hunger/sanity, which ARE
  `player_classified` (owner-only) and is why PartyHud needs broadcast netvars for those. **Another
  player's equipped item is the same way — owner-only `inventory_classified`** (`SetClassifiedTarget(inst)`;
  the item is `RemoveFromScene`d on equip, so a non-owner sees only the character's anim/symbol overlay,
  never a queryable item entity or its prefab). A naive dev assumes the visible held weapon is readable —
  it is not; an equipped-item-of-a-teammate feature needs a broadcast channel, like HP.
- **Existing netvars.** Data the game already syncs to clients (tags via `inst:HasTag` replicas,
  component replicas) may not need a parallel mod channel.

**Player colour specifics (a frequent "already free" case):** server-assigned in **join order** from a
fixed 24-colour warm palette (`GetAvailablePlayerColours`, `networking.lua:671-714`) — not user-chosen,
not name-hashed; stable within a session, reclaimed on rejoin. Missing/again-not-ready colour →
`DEFAULT_PLAYER_COLOUR` = **GREY `RGB(153,153,153)`** (`constants.lua:1763`), **not white**; a `{1,1,1,1}`
read on a freshly-spawned local entity means "not ready yet," not a real choice.

## 2. Static vs dynamic data + event-driven delivery (dim 2)

Classify each field by VALUE-change frequency:

- **Static / identity / config** — character prefab, player colour, a config choice. Changes only on
  discrete events: join / character-select, `ms_becameghost` / `ms_respawnedfromghost`, Woodie weremode
  / Wormwood stage (`USERFLAGS` bits), skin change, shard migration, and rare prefab swaps
  (wonkey/monkey-curse). Deliver **event-driven** (on join + on those events) or read from an already-
  on-change channel (§1). Never fold into a per-tick blob.
- **Dynamic** — HP/hunger/sanity/position/countdowns. Belongs in a periodic broadcast + reconcile/TTL.
- **The trap:** a static field sharing a record with a per-tick-changing field. A `net_string` carrier
  `:set()` only transmits on value *change*, but if the record also holds HP (which drifts every tick),
  the whole record re-transmits ~2 Hz and drags the static field along **forever** — plus per-tick
  encode/decode CPU. Cost is usually minor (e.g. ~N×8B×2Hz) but it is pure waste and muddies the design.

## 3. Versioning & rolling-update compatibility (dim 3)

Peers on different mod versions are the NORM, not an edge case: a Workshop update reaches subscribers at
different times, and a Master/Caves restart updates the shards minutes apart (a rolling update where one
shard runs vN and the other vN-1).

- **Version field, checked.** Lead the payload with a protocol-version token; the decoder branches on it.
- **Decode older gracefully** — fields that didn't exist in vN-1 get sensible defaults (e.g. `nil` /
  `0`), never an error.
- **Decode unknown/newer gracefully** — a vN+1 payload arriving at a vN decoder must be **ignored/skipped,
  never crash** (an unsupported-version guard that drops the record).
- **Append-only.** Add new fields at the END. Never reorder, remove, or repurpose an existing field
  position — an old peer reads positions, so a reorder silently misassigns values.
- **Bump the version on ANY wire change**, even an "additive" one, so peers can tell.
- **Ask explicitly:** what does last release's shard do with this new payload, and what does this release
  do with last release's payload? If either answer is "crash" or "misreads," it's a blocker.

## 4. Netvar types & ranges; compactness vs robustness (dim 4)

From `netvars.lua` — match every `:set()` value to its declared type's range:

| netvar | range | overflow behaviour |
|---|---|---|
| `net_bool` | 0/1 | — |
| `net_tinybyte` | 0..7 | wraps |
| `net_smallbyte` | 0..63 (6-bit unsigned) | wraps |
| `net_byte` | 0..255 | **wraps** (e.g. WX-78 400 HP → 144) |
| `net_ushortint` | 0..65535 | wraps |
| `net_shortint` | signed ~±32767 | — |
| `net_int` / `net_uint` | 32-bit | — |
| `net_float` / `net_string` / `net_hash` / `net_entity` | — | type-specific |

- A **float into an integer netvar truncates**; a **value > range wraps**; a **negative into an unsigned
  wraps**. Round/clamp before `:set()`, and pick a type wide enough (PartyHud uses `net_ushortint` for
  HP/hunger/sanity precisely to fit WX-78's 400).
- **Compactness vs robustness:** an integer index into a list (e.g. a char-id into `DST_CHARACTERLIST`)
  is smaller but **breaks for mod content** whose list position differs across clients/mod-sets. Prefer
  the stable STRING (the prefab name) when ids aren't globally stable — the few bytes are worth the
  correctness.
- **Delimited records** (`:` field-sep, `|` record-sep): confirm no field value can contain the
  separator (prefabs/userids are safe lowercase/identifier strings; free text is not).

## 5. Malformed / empty / sandbox robustness (dim 5)

A decoder is an attack surface for corrupt, truncated, or cross-version payloads — it must never throw.

- **Guard the decode, log-and-drop.** The shard-RPC handler and the broadcast-decode run as **naked**
  engine callbacks (`scheduler.lua` / `entityscript.lua` dispatch them with no pcall); an uncaught throw
  there halts the shard. Validate field count before indexing; `tonumber`/type-check decoded fields
  (never trust the wire); on any anomaly, drop the record and `print` a log line — do not error.
- **Empty-not-nil.** `TheNet:GetClientTable()` can transiently return a non-nil **empty** table; a
  destructive reconcile must guard `#t > 0` (a prune that runs on the empty table wipes live state).
- **Partial/truncated payloads** — handle a record with too few/many fields without indexing past the end.
- **modmain sandbox trap.** If codec/handler code runs in `modmain.lua`, the env whitelists only
  `pairs/ipairs/print/math/table/type/string/tostring/require` — bare `tonumber`/`pcall`/`select`/
  `unpack`/`error` are **nil** (→ runtime crash that luacheck can't see). Use `GLOBAL.*`. Code in
  required `scripts/*` modules gets the full `_G`, so put codec logic THERE and keep modmain a thin caller.

## 6. Single source of truth & testing (dim 6)

- The **codec is the single source of truth** for the wire format: encode + decode live together, stay
  symmetric, and the field order/meaning is documented at the codec; the protocol-version constant is
  the one knob.
- **Round-trip ≠ compatibility.** A busted `encode→decode == identity` test only proves the codec agrees
  with ITSELF. You also need **cross-version decode** tests: a v(N-1) payload decodes correctly with the
  new decoder (defaults for new fields); an unknown/newer-version payload is **ignored, not crashed**.
- Keep codec logic in an **engine-free pure module** so these run under plain busted with no game runtime
  (PartyHud: `partyhud_statuscodec.lua` + `spec/statuscodec_spec.lua`).

## 7. Worked PartyHud examples

- **Cross-shard avatars rode an existing channel (dim 1 win).** v2026.11 first proposed a codec **v3**
  with a per-record `prefab`; the audit found `GetClientTable()` already carries `prefab`/`colour`/
  `userflags` cluster-wide and the mod already read it for `namebyuserid` — so identity needs **zero new
  wire** (build `prefabbyuserid`/`colourbyuserid`, join by userid). The codec change was deleted.
- **Static-in-per-tick waste avoided (dim 2).** Folding `prefab` into the 0.5s status record would have
  re-transmitted an immutable value ~2 Hz forever; identity is event-driven (from GetClientTable's
  on-change rows) instead.
- **The status codec is versioned + append-only (dim 3).** `partyhud_statuscodec` leads with a
  protocol-version byte; v2 appended a numeric `origin` field after the v1 fields (append-only); the
  decoder branches per version and an unsupported version is dropped.
- **A naked decode-path crash (dim 5).** A bare `tonumber(...)` in the server-side broadcast builder
  (modmain sandbox) was `nil` → an uncaught throw in the 0.5s task halted the master shard the moment a
  player connected. Fix: `GLOBAL.tonumber`; the durable fix is wrapping naked server callbacks (the
  crash guard) + a sandbox-global grep gate + a player-connected smoke test.
- **GetClientTable empty-not-nil reconcile (dim 5).** The cross-shard prune guards
  `clienttable ~= nil and #clienttable > 0` before deleting stale entries.
- **SHARDID is a STRING.** `TheShard:GetShardId()` / `SHARDID.MASTER` are strings (`"1"`,
  `constants.lua:2482`); coerce once with `GLOBAL.tonumber` at the boundary if comparing numerically, and
  derive my-shard from the client's own broadcast record rather than a client-side `GetShardId`.
