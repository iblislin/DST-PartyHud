---
name: dst-mod-crash-audit
description: Crash-safety / runtime-robustness review for Don't Starve Together (DST) Lua mods. Use this BEFORE shipping a DST mod to the Steam Workshop or deploying to a dedicated/prod server, and whenever the user asks to "audit", "review for crashes/bugs", "is this cave-safe", "check shard migration", or "safety-check" a DST mod. Catches the runtime crash classes luacheck CANNOT — nil / wrong-`inst` access, cave & Master<->Caves shard-migration faults, ghost/death state, array indexing & `table.sort` comparator validity, Lua-semantics traps (truthiness, globals, format/concat, div-by-zero), event-listener lifecycle (leaks / fire-on-dead / wrong listener source), client-vs-server context, and netvar type/range overflow. Trigger even when the user just says "review my mod" or names a specific worry (caves, ghosts, disconnect) without saying "audit".
---

# DST Mod Crash-Safety Audit

## Why this exists

DST mods are thin Lua glue over the game engine, and the bugs that actually take a server
down are **runtime** bugs, not load-time ones. `luacheck` (and the `.luacheckrc` you should
still run first) catches syntax errors, undefined globals, and accidental globals — but it is
blind to the failures that have historically crashed real mods: indexing a field on the wrong
`inst`, a handler firing during a shard migration when `ThePlayer` is nil, a `table.sort`
comparator that isn't a valid ordering, reading owner-only `player_classified` data for a
teammate, or a `net_byte` silently truncating a value. This skill encodes a repeatable review
that finds those, and the DST-specific facts you need to judge them.

`luacheck` is the cheap first gate, **not** a substitute for this. And this audit is not a
substitute for the runtime checks that follow it: a dedicated-server **load smoke test** (does
the mod boot cleanly?) and **multi-player + 2-shard in-game testing** (does it behave when
players join/leave/die/enter caves?). The pipeline is: luacheck → this audit → load smoke →
in-game test.

## Before you start — get ground truth

1. **The mod source** to audit (the `.lua` files).
2. **The game's own scripts**, extracted, to verify every API claim against. Do NOT trust
   3rd-party wikis or memory for DST internals — they're often stale. If an extracted copy
   isn't already available (commonly at `~/code/dst/dst-scripts/scripts/`), get one: `docker cp`
   `scripts.zip` out of the DST server image (`/home/steam/dst/game/data/databundles/scripts.zip`)
   and unzip it. Read `prefabs/player_common.lua`, `prefabs/player_common_extensions.lua`,
   `prefabs/player_classified.lua`, `components/*.lua`, `widgets/*.lua` as needed.

See `references/dst-runtime-gotchas.md` for the catalog of DST invariants, the historical bug
patterns, and the exact APIs/events — load it before auditing; it is the seed for the checklist
below.

## Method: fan out by dimension, then verify

Review breadth beats depth-in-one-pass here, because the bug classes are largely independent
and each wants a different lens. The proven approach:

1. **Dispatch one READ-ONLY subagent per dimension** (the 6 below), in parallel. Give each the
   mod files, the path to the extracted game scripts, and its dimension's checklist. Tell each
   to verify claims against the game source and to report:
   - every **finding** with: severity (crash / latent-crash / leak / cosmetic / none),
     `file:line`, the exact runtime scenario that triggers it, the game-source evidence, and a
     concrete fix; and
   - for every checked item it found **safe**, a one-line note saying so *with the reason* —
     so you know it was actually verified, not skipped. (A report that only lists problems
     can't be distinguished from a lazy one.)
2. **Audit the auditors.** Do not paste subagent findings through. Re-read the cited
   `file:line` and re-check the load-bearing claims against the actual game source yourself.
   Subagent reports are leads, not verdicts — the whole point is to catch the subtle ones, and
   subtle claims are exactly the ones that are sometimes wrong. (Past real example: a confident
   "this is replicated to all clients, you can skip the server hook" was flat wrong — the data
   was owner-only `classified`. Verifying against source caught it.)
3. **Synthesize one report** (template below): the verified must-fix items first, then
   nice-to-haves, then a short "verified safe" list so the user sees coverage, then a verdict.

If subagents aren't available, walk the 6 dimensions yourself in sequence — the checklist is
the same; you just lose the parallelism and the independent second opinion.

## The 6 dimensions (the checklist)

Pair each with the matching section of `references/dst-runtime-gotchas.md`.

1. **Nil / wrong-`inst` access.** Every `inst.field` / `inst.components.X` / `:method()` —
   can `inst` be the wrong entity (a handler whose `ListenForEvent` source is `TheWorld`, so
   `inst` is the world, not the player — the classic cave-entry crash), or can the field/
   component be nil at that moment (early join, ghost, mid-migration)? Are refresh paths
   guarded against a nil `ThePlayer` / not-yet-built HUD?

2. **Cave / shard migration & ghost/death state.** Master<->Caves migration removes the player
   entity on one shard and respawns it on the other. Does anything assume a single shard, leak
   a per-player timer that outlives the entity, or mis-handle a ghost (use the authoritative
   `ms_becameghost`/`ms_respawnedfromghost`, not the intent events `death`/`respawnfromghost`)?
   Is `AllPlayers` (shard-local) used as if it were global? Is the unguarded component access
   on a (re)spawning/ghost player actually safe (see gotchas: which components are guaranteed)?

3. **Array / table indexing & iteration.** Off-by-one / out-of-range / 0 / negative indices;
   `#t` on a table that may have nil holes (undefined); `ipairs` stopping early on a hole;
   modify-during-iteration; and **`table.sort` comparator validity** — it MUST be a strict weak
   ordering (irreflexive: `comp(x,x)` is false), or Lua 5.1 throws "invalid order function for
   sorting" / corrupts the partition. Self-first / pinned-element comparators are a common trap.

4. **Lua-semantics traps.** The `cond and X or Y` idiom breaks when `X` can legitimately be
   `false`/`nil` (it falls through to `Y`); `0` and `""` are truthy. Accidental globals;
   `local function` referenced before its declaration (captures nil/global); closures capturing
   a loop variable; `string.format` arg/type mismatch and `..` with nil/table; `tonumber`/
   `tostring` on nil; division by zero; multi-return used mid-arglist. **modmain sandbox env:**
   `modmain.lua` runs in a restricted env that whitelists only some standard globals (`tostring`,
   `pairs`, `ipairs`, `print`, `math`, `table`, `type`, `string`, `require`) — a bare call to a
   NON-whitelisted global (notably **`tonumber`**, also `pcall`/`error`/`assert`/`select`/
   `setmetatable`/`unpack`/…) is nil → runtime "attempt to call global 'X'" that luacheck+loadfile
   miss. Use `GLOBAL.X`. (Required `scripts/*` modules get the full env, so it's a modmain-only
   trap.) See references Language-baseline note + §11.

5. **Event / listener lifecycle.** Double-registration (a per-entity postinit vs a per-HUD
   postconstruct); listeners that leak across HUD/entity rebuilds; callbacks/`DoTaskInTime`
   closures that fire after their target is removed (guard at FIRE time, not just registration);
   and **listener source correctness** — register on the entity whose removal should clean it up,
   with the right event source (this is both the v2026.3 crash and the clean-teardown pattern).

6. **Client / server context & netvar ranges.** Server-only work under `TheWorld.ismastersim`,
   client-only under `not TheNet:IsDedicated()` / guarded by `ThePlayer`; no server-only
   component method on a client path, no client-only API (TheFrontEnd, widgets) on a dedicated
   server. Every `net_*` declaration vs every `:set()` — can the value exceed the netvar's range
   or be the wrong type (a float into `net_byte`/`net_ushortint` truncates; a value > 255 into
   `net_byte` wraps; negative into an unsigned)? Cross-check that any "read teammate status on
   the client" path is actually replicated and not owner-only `classified`.

## Output: the audit report

Structure the synthesized report like this:

```
# Crash-safety audit — <mod name> @ <version/commit>

## Must-fix (crash / latent-crash), verified
- [<dimension>] <file:line> — <what happens, in which scenario> — <fix>. Evidence: <game-source ref>.

## Nice-to-fix (leak / cosmetic / dead code)
- ...

## Verified safe (so coverage is visible, not just problems)
- <dimension>: <what was checked and why it's safe>

## Verdict
<Is it crash-safe to ship for the cave/shard/ghost case? Any blocking item? What runtime test still has to happen (load smoke + multi-player + 2-shard)?>
```

Severity guide: **crash** = will error in a normal scenario; **latent-crash** = errors only on a
specific (but reachable) path; **leak** = accumulates listeners/tasks, no crash; **cosmetic /
dead** = wrong-but-harmless or unused. Be honest about probability — "latent, low-probability"
is more useful than crying wolf.

## After the audit

State plainly what this audit does and does NOT cover. It does not replace: running `luacheck`
(do it first), the dedicated-server **load smoke test** (clean boot), and **multi-player +
2-shard in-game testing** (real join/leave/death/cave behaviour). Recommend those as the next
gates, and — when an assumption the mod relies on is non-obvious or could be broken by a future
game update — suggest recording it as an inline "INVARIANTS" comment in the mod so the next
maintainer (or game patch) is flagged.

**The load-smoke does NOT exercise sim-tick code** (a hard lesson from the v2026.9 incident — see
references §12.4). With no players, `pause_when_empty=true` freezes the sim, so any
`DoPeriodicTask`/`DoTaskInTime`/per-tick logic never runs and a latent crash in it (e.g. the bare
`tonumber`) passes the smoke, then detonates the moment a player connects. If the mod adds or
changes any periodic/tick task, the smoke is not enough — temporarily `pause_when_empty=false`
(or connect a client) and watch for several task periods, or in-game test with a real player.
