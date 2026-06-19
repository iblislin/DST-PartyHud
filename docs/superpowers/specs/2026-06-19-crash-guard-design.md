# PartyHud 2026 v2026.11 — Server-Side Crash Guard — Design

**Status:** approved (research workflow `wruf4uvg9`, 2026-06-19), pending spec review → implementation plan.
**Ships in:** v2026.11, alongside the avatars + name-colour feature (separate concern, same release).

**Goal:** A single PartyHud runtime error must never halt the dedicated-server master shard. Convert a
shard-fatal uncaught throw in our server-side callbacks into a logged, skipped tick/event — the server
keeps running, PartyHud degrades.

**Why:** The bare-`tonumber` incident took the master shard down the instant a player connected. The
research below proves that was not bad luck — our server-side runtime callbacks are dispatched by the
engine with **no pcall**, and a dedicated server has **no error screen and no runtime mod-disable**. A
guard is the safety net for the crash classes that luacheck and no-player smoke tests structurally miss.

---

## Verified fault model (engine source, file:line)

| Phase | Dispatch | Protected by engine? | Evidence |
|---|---|---|---|
| modmain top-level | `RunInEnvironmentSafe` (xpcall) | ✅ mod disabled, server survives | `mods.lua:606` |
| post-init bodies (`AddSimPostInit`/`AddPlayerPostInit`/…) | `runmodfn` (xpcall + RemoveBadMod) | ✅ mod disabled, server survives | `mods.lua:192-205` |
| **`DoPeriodicTask`/`DoTaskInTime` body** | `Scheduler:OnTick` bare `k.fn(...)` | ❌ **NAKED** | `scheduler.lua:184-190` |
| **`ListenForEvent` handler** | `PushEvent_Internal` bare `fn(self,data)` | ❌ **NAKED** | `entityscript.lua:1298-1300` |
| `StartThread` coroutine | `coroutine.resume` + KillTask | isolated (PartyHud uses none) | `scheduler.lua:230,247-251` |
| Shard-RPC handler | crosses into C++ `CallShardRPC` | unverifiable → treat as naked | `networkclientrpc.lua:1783` |

Cementing facts: no Lua-level recovery in `Update`/`RunScheduler` (`update.lua:229,240`); the error
screen is client-only (`SetGlobalErrorWidget`/error-UI gated behind `not TheNet:IsDedicated()`,
`gamelogic.lua:42,56-63`; driven via `TheFrontEnd`, `update.lua:91-93`); no runtime auto-disable (the
bad-load flag scheme is load-time only). **Result:** a server-side runtime throw → master shard halts,
no UI, repeats until the mod is fixed/removed.

**Sandbox constraint (root cause + a constraint on the fix):** modmain's env (`mods.lua:302-331`)
whitelists `pairs/ipairs/print/math/table/type/string/tostring/require/Class/TUNING/GLOBAL` — **not**
`tonumber`, **not** `pcall`/`xpcall`/`error`. A bare `pcall` in the guard is `nil` → it crashes exactly
where it should protect. **The guard MUST use `GLOBAL.pcall`/`GLOBAL.xpcall`/`GLOBAL.debug.traceback`.**

**Current exposure (verified):** `grep pcall|xpcall` across the mod = NONE. The broadcast task
(`modmain.lua:971`) and the 11 server hooks (`779-789`) are unwrapped. The shard-RPC handler
(`932-957`) is already hand-written fail-soft (decode-guard, log-and-drop) — correct discipline, but
ad-hoc.

---

## The guard

A thin wrapper mirroring the engine's own `runmodfn` idiom (`mods.lua:195`). Place near the top of
`modmain.lua` (a candidate for extraction into a tiny `partyhud_guard` shape, but it depends on
`GLOBAL` so it lives in modmain; the *decision logic* is trivial, the value is the wiring).

```lua
-- Sandbox-correct: bare pcall/xpcall/debug are nil in modmain's env (mods.lua:302-331).
local pcall     = GLOBAL.pcall
local xpcall    = GLOBAL.xpcall
local unpack    = GLOBAL.unpack
local traceback = GLOBAL.debug and GLOBAL.debug.traceback

-- Flip true in modmain while developing / in CI / dogfood so crashes still surface loudly.
local PARTYHUD_DEV_RERAISE = false

local _logged = {}  -- de-dup: one stack per label, not one per 0.5s tick

local function guarded(label, fn)
  return function(...)
    local args = { ... }
    local ok, err = xpcall(function() return fn(unpack(args)) end, traceback or GLOBAL.tostring)
    if not ok then
      if not _logged[label] then
        _logged[label] = true
        GLOBAL.print("[PartyHud] GUARD caught error in " .. label ..
                     " (further repeats suppressed):\n" .. GLOBAL.tostring(err))
      end
      if PARTYHUD_DEV_RERAISE then GLOBAL.error(err, 0) end
      -- DEGRADE: skip THIS tick/event only. The periodic task is re-listed by the
      -- scheduler (period-driven, not return-driven) so the broadcast resumes next tick.
      -- Do NOT serve stale netvars as fresh.
    end
    return  -- engine discards callback returns on all three dispatch paths (verified)
  end
end
```

### Wrap sites, ranked by blast radius (server-side first)
1. **The 0.5s broadcast task** — `modmain.lua:971`. The incident site; widest API surface
   (`build_local_records`, `codec.encode`, `Shard_GetConnectedShards`, `crossshard.*`, carrier `:set`).
   `TheWorld:DoPeriodicTask(0.5, guarded("broadcast", function() ... end))`. Idempotent + re-runs in
   0.5s, so skip-this-tick is the correct degrade.
2. **The 11 server event hooks** — `modmain.lua:779-789`. Wrap at bind:
   `inst:ListenForEvent("healthdelta", guarded("ev:healthdelta", onhealthdelta))`, etc.
3. **`crossshard.upsert`** invoked from the shard-RPC handler — defense-in-depth behind the C++ boundary.

### Client-side (separate, lower priority — an error here kills only one client, never the shard)
`UpdateBadges` (`modmain.lua:433`), `onstatusdisplaysconstruct` (`AddClassPostConstruct`, dispatched
bare by `modutil.lua:153`), the netvar-dirty handlers, `PartyBadge:OnUpdate`. Optional `guarded()` on
`UpdateBadges` hardens the local HUD cheaply — polish, not a server-safety item. Include if low-cost.

### Foreign-data staleness heartbeat (Q5 — hide stale cross-shard badges) — FOLD IN
A guard catches a *throw*; it does NOT catch a broadcast task that wedges/stops silently — and that case
actively misinforms (stale HP is worse than no badge). Verified: LOCAL badges read live per-player
netvars every refresh, independent of the broadcast (a guarded broadcast-skip leaves them correct; a
guarded *event-hook* skip freezes one field on one player, bounded + self-healing on the next delta — so
**leave local badges always-on**). But FOREIGN badges FREEZE if the broadcast task stops: the TTL
`crossshard.expire` (`XSHARD_TTL=3`) AND the carrier `:set` both live INSIDE the 0.5s task
(`modmain.lua:996`/`1034`), so a wedged task means `expire` never runs, the `net_string` never changes
(no dirty event), and `client_foreign_records` (written only at `modmain.lua:1070`) stays frozen at stale
HP for minutes.
- **Fix (~6 lines, client-only, cannot crash the shard):** stamp `last_foreign_blob_time = GLOBAL.GetTime()`
  where the carrier-dirty handler sets `client_foreign_records` (`modmain.lua:1070`); add a freshness
  clause to the foreign-append guard (`modmain.lua:538`):
  `(GLOBAL.GetTime() - last_foreign_blob_time) <= FOREIGN_STALE_SECS`, with `FOREIGN_STALE_SECS = 5`
  (10× the 0.5s cadence, > the 3s server TTL — biased against false-positive hiding). When the block is
  skipped, the EXISTING trailing-slot clear (`modmain.lua:622-629`) runs `SetForeign(false)`/`HideBadge()`
  on those slots, so stale foreign badges vanish with NO new clear code. Log once (`_logged`-style):
  "PartyHud foreign data stale, hiding cross-shard badges".
- This **complements** `guarded()` (catches throws); the heartbeat catches the silently-stopped publish a
  throw-guard cannot. Why NOT a server `net_bool` "degraded" flag: see Out of scope.

### What NOT to guard
Post-init bodies (engine already xpcall-wraps them — redundant); the pure busted-tested modules
(`partyhud_record`/`_crossshard`/`_badge`/`_layout`/`_status` — guard their *callers*, not the leaves);
`StartThread` (none used); `modassert`/`moderror` (they re-raise — wrong tool for keep-running).

### Decode-boundary value validation (Q3 — clamp surprise values, never throw) — FOLD IN
The decoder is where untrusted cross-shard bytes enter. It already validates STRUCTURE (field count,
version, `tonumber`) and returns `nil + reason` (never throws). Add value-range clamping for the fields
whose out-of-range value would misrender — but **clamp-and-log-once and KEEP the record**; reserve
whole-payload rejection for the structural errors decode already handles.
- **Do (real exposure):** clamp the numerics — `hp_cur`/`hunger`/`sanity_cur` to `>= 0`, penalties to
  `0..100` (mostly already done by `record.normalize_*`'s `max>0` clamp; add the `cur>=0`). A small
  `clamp_num(v, lo, hi)` helper inline at the decode boundary (`partyhud_statuscodec.lua` after
  `rec[name]=x`), with the same `_logged` de-dup as the guard.
- **Skip (already safe — log-noise only):** `flags` (`unpackflags` reads only the 5 defined bits, ignores
  the rest); `sanity rate` (an out-of-set value already yields `nil` from `SANITY_RATE_ANIM[]` → arrow
  hidden); `origin` (leave `nil` — a v1 peer legitimately has none).
- **Trust-model caveat:** both shards `require` the same module and encode from the server's own netvars
  — no malicious/divergent producer — so this is belt-and-suspenders, not correctness. The numeric clamps
  are the only part with real yield; the enum/flags clamp-logging is out of scope (below).

### Surfacing on a dedicated server (no screen)
`GLOBAL.print` reaches the server log. Optionally a fire-once `GLOBAL.TheNet:Announce("PartyHud
degraded — see server log")` from the master sim. Do NOT route through the engine error widget (absent
on a dedicated server).

---

## Trade-offs (be honest)

- **Buys:** one shard-fatal throw → a skipped tick/event; the other players keep playing while PartyHud
  degrades. Large, real win for a mod running on other people's servers.
- **A guard is weaker than the gates that would have *prevented* the incident** — it is a net, not a
  substitute. The durable fixes (both fold into the release process, see below) are: (a) a crash-audit
  grep gate flagging every bare `_G` builtin in modmain (`tonumber`/`pcall`/`select`/`unpack`/`next`/
  `assert`/`error`) demanding a `GLOBAL.` prefix; (b) a smoke test **with a connected player** (or
  `pause_when_empty=false`) so periodic-task bodies actually execute.
- **Hides bugs if logging is weak** → the `_logged` de-dup + `PARTYHUD_DEV_RERAISE` are load-bearing:
  dev/CI/dogfood must keep crashing loudly.
- **Not a state-correctness fix** — "behaviour-safe" is verified only against the engine caller (all
  three paths discard the return; none depend on the throw). Internal coherence relies on the broadcast
  task being idempotent.

---

## Testing & process

1. **busted** `spec/guard_spec.lua`: `guarded()` returns a function that (a) calls through and returns
   nothing on success, (b) swallows + logs ONCE on a throwing fn (second throw not re-logged),
   (c) re-raises when `DEV_RERAISE` is set. (Test the wrapper logic with injected pcall/print stubs so
   it stays engine-free — or test the pure de-dup/log-once decision.)
2. **luacheck 0/0** + **stylua --check**.
3. **`dst-mod-crash-audit` (full 6-dimension)** — the guard touches the exact server-side path that
   crashed before; D4 especially (the guard helper must be `GLOBAL.`-prefixed, not bare).
4. **`partyhud-release-preflight`** — the in-engine load-smoke MUST run **with a connected player** to
   exercise the previously-masked broadcast path; confirm a deliberately-injected throw is caught +
   logged + the shard stays up (temporarily, in modtest).
5. **Skill update:** fold into `dst-mod-crash-audit` the rule **"every mod-owned runtime callback
   registered on the sim-time scheduler or the event bus must be wrapped at the point it is
   registered — being inside a (protected) post-init does not protect the (naked) closures it
   installs."** Plus the player-connected-smoke requirement.
6. **Startup codec self-check (Q4 — code + gate, ~6 lines).** At the bottom of
   `partyhud_statuscodec.lua` (before `return M`): `assert(SUPPORTED[PROTOCOL_VERSION])` + an
   `encode→decode` round-trip on a probe record asserting it survives. A broken codec build (someone
   edits `NUM_FIELDS`/`NUMERIC`/`FLAGS`/`SUPPORTED`) then fails LOUDLY at require-time — inside the
   engine's xpcall (`mods.lua`), so the mod disables cleanly + logs — instead of silently inside the
   now-`guarded()` 2 Hz task (which would swallow it). Bare `assert`/`tonumber` are safe here: the codec
   is `require`d into full `_G`, not modmain's sandbox. Pairs with `spec/statuscodec_spec.lua` (the same
   round-trip, run under busted).

## Out of scope / deferred
- **Auto-disabling the mod on repeated errors** — the engine offers no runtime hook; de-dup logging + the
  Q5 staleness heartbeat (which hides the misleading data) suffice.
- **A server-signalled `net_bool` "degraded" kill switch** — you cannot reliably `:set()` a flag from
  inside the very task that wedged (the signal you need most is the one you can't send); the client-side
  staleness heartbeat supersedes it and adds no new netvar surface (which would also have to be declared
  identically on server + client).
- **`readonly()` proxy on the `FLAGS`/`PROTOCOL_VERSION`/`SUPPORTED` constant tables (Q1/Q2)** — they are
  defined-once + never mutated; DST freezes none of its own constant tables. Zero safety gain. Lua 5.1
  has no `const` for locals (that's 5.4), so the `GLOBAL.pcall`/`xpcall`/`traceback` aliases stay plain
  locals — luacheck `std="lua51"` (already in the 0/0 gate) covers accidental reassignment.
- **Full per-message / per-field range validation + sampling (Q4)** — defends a threat the same-module
  same-cluster deployment doesn't have; pure 2 Hz cost. The cheap boundary checks (already present) + the
  startup self-check are the right amount.
- **enum/flags clamp-logging (Q3)** — the renderer already degrades safely on a bad rate/flag, so this is
  log-noise; only the numeric clamps have real yield.
- Any change to the avatars/name-colour feature (orthogonal; same release only).
