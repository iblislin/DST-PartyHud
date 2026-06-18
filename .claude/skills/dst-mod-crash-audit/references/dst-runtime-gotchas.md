# DST runtime gotchas — checklist seed for the crash-safety audit

Verify every claim here against the **extracted game scripts** (it drifts across game updates;
file:line refs are approximate and from a 2026 build). This is the knowledge seed for the 6
audit dimensions in `../SKILL.md`. Don't trust wikis or memory for DST internals.

**Language baseline: DST runs Lua 5.1** (Klei's engine embeds a Lua 5.1 VM; the mod environment
is a sandbox over it — the `.luacheckrc` should declare `std = lua51`). Assume 5.1, never 5.2/5.3.
Several gotchas below follow directly from 5.1 semantics:
- **No integer type** — every number is a double. Integer-ness and ranges come from the netvar
  type, which is exactly why a float into a `net_byte` truncates and why values are `ceil`/`floor`'d
  before `:set()` (§6).
- **`unpack` is a global** (not `table.unpack`, which is 5.2+).
- **`#` on a sequence with nil holes is undefined**, and **`table.sort`'s comparator must be a
  strict weak ordering** (irreflexive) or it errors (§3, §8).
- No `goto`/`_ENV` (5.2), no integer `//` or bitwise operators (5.3); `os`/`io`/arbitrary
  `require` are restricted in the mod sandbox (use `modimport`/`GLOBAL`, not raw `require`).

## Contents
1. Shard / cave model
2. `player_classified` is owner-only (teammate data isn't client-readable)
3. Guaranteed-present components on the server
4. Lifecycle events (server-only vs client+server; intent vs authoritative)
5. Listener source & cleanup
6. Netvar types & ranges
7. Widgets / HUD coordinates
8. `table.sort` comparator validity
9. Event cadence (event-driven vs poll)
10. Mod config reads (client options)
11. Historical bug catalog (the bugs that actually shipped)
12. Testing layers

---

## 1. Shard / cave model
- A DST cluster with caves is **two shards** (Master = surface, Caves), each a separate process
  with its own world. `TheWorld.ismastersim` is **true on BOTH** — each shard is authoritative
  for its own world. Server-side mod logic gated on `ismastersim` runs on whichever shard
  currently hosts the player. Don't write code that assumes a single shard.
- **Entering/leaving caves = a Master<->Caves migration**: the player entity is `Remove()`'d on
  the old shard and a fresh one spawns on the destination (so `AddPlayerPostInit` runs again per
  shard, re-binding fresh netvars/listeners; anything on the old entity dies with it).
- **`AllPlayers` is SHARD-LOCAL** — it only contains players on the current shard. A teammate in
  caves is NOT in your surface shard's `AllPlayers`. Showing cross-shard players requires
  syncing over the shard network (see the Global Positions mod, workshop 378160973), not reading
  `AllPlayers`.
- **`TheShard:GetShardId()` returns a STRING, not a number.** `SHARDID = { INVALID = "0",
  MASTER = "1" }` (`constants.lua`, string values; secondary shards get a numeric-looking string
  id). The engine's own code stringifies the OTHER operand to compare (`tostring(sender) ~=
  TheShard:GetShardId()`, networkclientrpc.lua) and `Shard_GetConnectedShards()` is keyed by these
  STRING ids. So `world_id ~= tostring(GetShardId())` is the correct self-exclusion in a send loop.
  The trap: if you stamp a shard id into a record/netvar as the raw `GetShardId()` (a string) and
  later compare it `==` against a number (e.g. one that round-tripped through a numeric codec /
  `tonumber`), `"1" == 1` is **false** and the comparison silently never matches. Pick ONE type at
  a single chokepoint — coerce with `tonumber()` on the way in (or `tostring()` everywhere) — and
  say which in a comment. A codec that `math.floor`s on encode + `tonumber`s on decode will mask
  the bug (both ends become numbers), leaving a latent trap for the next refactor that compares
  a pre-encode value. → dimension 4 + 6. (PartyHud v2026.8 hit exactly this: `origin` stamped as
  the string `"1"`, rescued only by codec coercion.)

## 2. `player_classified` is owner-only
- `player_common.lua` does `inst.player_classified.Network:SetClassifiedTarget(inst)` (~:1016).
  A targeted classified entity is replicated **only to its owning client**.
- `health`, `hunger`, `sanity` (+ builder/combat/rider) replica components read from that
  classified (`player_classified.lua` `TryAttachClassifiedToReplicaComponent`, ~:253). The
  `*delta`/`*dirty` events that `player_classified` re-fires on the player entity fire **only on
  the owner's own client**.
- Therefore a remote teammate's exact HP/hunger/sanity/temperature is **NOT readable on your
  client**. To show it you must broadcast it yourself: a server hook (under `ismastersim`) writes
  custom per-player netvars declared with `net_*(inst.GUID, ...)` on the PLAYER entity (those DO
  broadcast to all clients). "Just read the replica/classified on the client" is a trap for
  teammate data — it works only for your own player.

## 3. Guaranteed-present components on the server
- On the server, every player ALWAYS has `health`, `hunger`, `sanity`, `temperature` — added
  unconditionally in `player_common.lua` master_postinit (`AddComponent`, ~:2741/2766/2773/2781),
  which runs before any `AddPlayerPostInit`. **Ghosts retain them** (never `RemoveComponent`'d,
  only set invincible). So an unguarded `inst.components.health:DoDelta(0)` seed is safe under
  `ismastersim`, even for a ghost arriving via migration. (Still nil-guard hunger/sanity/
  temperature reads as cheap insurance, and NEVER assume these exist on the client.)

## 4. Lifecycle events
- **`TheNet:GetClientTable()` can return non-nil-but-EMPTY transiently** (e.g. mid-handshake), not
  just `nil`. Any logic that treats it as the authoritative live roster and REMOVES things absent
  from it (a reconcile / prune / "drop everyone not in the table" pass) must guard `clienttable ~=
  nil AND #clienttable > 0` — a `~= nil`-only guard still lets an empty table wipe the whole set
  for that tick (badges flicker out then back). The engine's own consumers guard `#t > 0` too
  (playerhistory.lua). A read-only use (building a name lookup) is fine with just the nil-guard;
  it's the destructive reconcile that needs the empty-guard. → dimension 2/6. (PartyHud v2026.8
  shipped the comment "never reconcile against an empty set" but the code only nil-guarded — caught
  by the audit.)
- **Presence, server-only**: `ms_playerjoined` / `ms_playerleft` — `TheWorld:PushEvent(..., player)`
  inside `if TheWorld.ismastersim` (player_common.lua ~:853/:1195). Not visible to clients.
- **Presence, client+server**: `playerentered` / `playerexited` — `TheWorld:PushEvent(..., player)`
  on BOTH server and client, when a player entity enters/leaves local network view (covers join,
  disconnect, AND shard migration). **Use these for a client HUD presence refresh**, not the
  ms_ ones.
- **Ghost, authoritative**: `ms_becameghost` / `ms_respawnedfromghost` — pushed on the PLAYER
  (player_common_extensions.lua ~:738/:793 and ~:430/:479; optional `{corpse=...}` data). These
  are the real "is now a ghost / revived" state changes.
- **Ghost, intent (weaker)**: `death` / `respawnfromghost` — fire on the death/respawn attempt;
  `death` can fire without the player actually becoming a ghost. Prefer the `ms_` events for
  ghost state.
- **Migration**: `ms_playerdespawnandmigrate` — `TheWorld:PushEvent(..., {player=, worldid=, ...})`
  (teleporter/worldmigrator/death paths). On the destination, `player.migration ~= nil` indicates
  arrival via migration (set in `playerspawner.lua` ~:87, cleared ~:260). `ms_playerdespawnanddelete`
  / `ms_playerleft` = a real leave. Distinguishing migrate-vs-disconnect only matters for
  cross-shard features; shard-local code treats both as "player left this shard".

## 5. Listener source & cleanup
- `inst:ListenForEvent(event, fn, source)`: `fn` is invoked as `fn(source, data)` — **the first
  arg is the event SOURCE, not necessarily the player.** If you `ListenForEvent("x", fn, TheWorld)`
  then `fn`'s `inst` is `TheWorld`; `inst.<player-field>` is nil → crash. (This is the canonical
  cave-entry crash.) Bind player hooks with the player as both listener and source.
- `RemoveAllEventCallbacks` (on entity Remove / `Widget:Kill`) is **bidirectional**: it removes
  callbacks the entity registered on OTHER sources too. So to make a listener self-cleaning,
  register it on the entity whose lifecycle should own it (e.g. a widget's `self.inst`) with the
  real event source passed as the 3rd arg — then `Widget:Kill` tears it down even though the
  source is `TheWorld`/`HUD.inst`. Registering directly on a long-lived source (TheWorld) without
  this can leak across rebuilds.
- Deferred work (`DoTaskInTime`, event callbacks) can fire after its target is gone — guard
  `ThePlayer`/`self.owner`/`TheWorld`/`HUD` at FIRE time, not just at registration.

## 6. Netvar types & ranges
- `net_bool`; `net_tinybyte` (0..7); `net_byte` (0..255); `net_shortint`/`net_ushortint`
  (~0..65535); etc. A **float** into an integer netvar truncates (e.g. `GetPenaltyPercent()`
  returns 0..1 → `net_byte` stores 0). A value **over the max** wraps (e.g. WX-78's 400 max HP
  into a `net_byte` → 144). A negative into an unsigned wraps. Match the type to the real range:
  HP/hunger/sanity current & max can exceed 255 → use `net_ushortint`; `RATE_SCALE` (0..6) fits
  `net_tinybyte`. The game itself uses `net_ushortint` for health/hunger/sanity current+max.
- Multiple netvars may share one dirty-event name (e.g. `"customhpbadgedirty"`) so one client
  listener covers them all.

## 7. Widgets / HUD coordinates
- Modern circular `Badge` uses anim build `"status_health"` / `"status_hunger"` / `"status_sanity"`
  (the 2016 `"health"` build was renamed — a 2016-era mod loading `"health"` shows an invisible
  badge). Tints (from the game's badges): health red `{174,21,21}/255`, hunger gold
  `{255,204,51}/255`, sanity ORANGE `{232,123,15}/255` (the blue `{191,232,240}` is the lunacy
  variant). `Badge.SetPercent(val,max)` sets the ring AND `num = ceil(val*max)`.
- `statusdisplays` is added to `controls.lua`'s `topleft_root` and `SetScale(1.4)`'d; `topleft_root`
  is scaled by `TheFrontEnd:GetHUDScale()`. So a child badge's visible vertical extent in its
  local units ≈ `screenheight / (hudscale * 1.4)`. Screen size: `TheSim:GetScreenSize()`; HUD
  scale: `TheFrontEnd:GetHUDScale()`; resize event on the HUD: `"refreshhudsize"`.

## 8. `table.sort` comparator validity
- The comparator MUST be a strict weak ordering, in particular **irreflexive**: `comp(x,x)` must
  return `false`. A "pin element X first" comparator like `if a==pinned then return true` violates
  this when `pinned` is in the list and lands on the sort pivot — `comp(pinned,pinned)=true`
  breaks Lua 5.1 `table.sort`'s sentinel → "invalid order function for sorting" error (or a
  corrupt/out-of-bounds partition). Fix: guard `if a == b then return false end` first, or filter
  the pinned element out and place it separately.

## 9. Event cadence (event-driven vs poll)
- `Sanity:DoDelta` pushes `sanitydelta` **unconditionally on every sanity update tick** (it
  `StartUpdatingComponent`s and `Recalc`s each tick, pushing even at rate≈0), carrying the freshly
  computed `ratescale` (RATE_SCALE 0..6) — so a rate indicator can be **event-driven** off
  `sanitydelta` (no separate `DoPeriodicTask` poll), and it still catches the settle-to-neutral.
  If a future update makes `sanitydelta` fire only on change, revert to polling `GetRateScale()`.
  Similar `*delta` events exist for hunger/health. (`net:set` only transmits on an actual change,
  so frequent re-sets of an unchanged value are cheap.)

## 10. Mod config reads (client options)
- For a `client = true` option on a server-required mod, `GetModConfigData("name")` returns the
  **server-synced** value (`saved_server`/`saved`/`default`) and ignores the player's local choice.
  To honor the per-client setting, read with `GetModConfigData("name", true)` (the
  `get_local_config` arg — see `modutil.lua`). Symptom: a client option appears to do nothing.

## 11. Historical bug catalog (these actually shipped / were caught)
- **TheWorld-as-inst (cave-entry crash, v2026.3)**: a `playerexited`/disconnect handler whose
  listener source was `TheWorld`, so `inst.customexitdelta` was nil → master-shard LUA ERROR →
  disconnect on cave entry. → dimension 1/5.
- **Badge mapping (v2026.5)**: unbounded badge index, AllPlayers reindex desync, stale departed
  names → fixed with bounded `#badgearray` + `userid`-stable order + trailing-slot clear; plus
  guarding refresh handlers against nil `ThePlayer`/not-yet-attached refresh during your own
  migration. → dimensions 3/1.
- **Owner-only classified mistaken for broadcast**: a "skip the server hook, read it on the
  client" recommendation that was wrong because the data was owner-only `classified`. Caught by
  verifying against source. → dimension 6 + §2.
- **Off-by-one numbers**: broadcasting a quantized 0–100 percent then reconstructing absolute
  values gave numbers 1–2 off from the game's own meters. Fix: broadcast the exact integer the
  game displays (`ceil(GetPercent()*max)`) via a wide-enough netvar. → dimension 6.
- **`table.sort` irreflexivity**: a self-first comparator without an `a==b` guard → potential
  "invalid order function". → dimension 3 + §8.
- **Client-config not applied**: `GetModConfigData` without `get_local_config=true`. → §10.
- **Shard-id string-vs-number (cross-shard, v2026.8)**: a per-record `origin` field stamped with the
  raw `TheShard:GetShardId()` (a STRING, `"1"`) then compared `==` against a number that had
  round-tripped through a numeric codec — `"1" == 1` is false. It happened to work only because the
  codec floored/`tonumber`'d both ends; a latent trap for any future pre-encode compare. Fix:
  `tonumber()` at the stamp chokepoint. → dimension 4 + §1.
- **Empty (not nil) GetClientTable reconcile (v2026.8)**: a roster-reconcile that pruned every
  foreign player absent from `GetClientTable()` guarded only `~= nil`, not `#t > 0`; a transient
  empty roster would wipe all cross-shard badges for a tick. The code even carried a comment
  promising the empty-set protection it didn't implement. → dimension 2 + §4.
- **Client-side `TheShard:GetShardId()` unreliable (v2026.8)**: on a pure client the call did not
  return the server shard's id (so a same-shard-far teammate got the cross-shard label). Fix: derive
  "my shard" from the client's OWN record in the broadcast blob (the server stamps every local
  player with this shard's origin) rather than trusting the client-side shard-id API. → dimension 2/6.

## 12. Testing layers (this audit is one of four gates)
1. **luacheck** — load-time only (syntax / undefined & accidental globals). Cheap first gate.
2. **This crash-safety audit** — the runtime bug classes luacheck can't see.
3. **Dedicated-server load smoke test** — boot an isolated throwaway server, load the mod, gen a
   world, assert mod-registered + no Lua errors. Catches bad `require`/missing-API/startup crash.
4. **Multi-player + 2-shard in-game test** — real join/leave/death/cave-migration behaviour. The
   only thing that exercises the client widgets, the netvar round-trip, and the shard paths.
Audit findings about behaviour (not just load) ultimately need gate 4 to confirm.
