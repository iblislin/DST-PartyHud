# Server-Side Crash Guard + Hardening Implementation Plan

For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan. Steps use checkbox (- [ ]) syntax.

## Goal

A single PartyHud runtime error must never halt the dedicated-server master shard. Convert a shard-fatal uncaught throw in our server-side callbacks into a logged, skipped tick/event — the server keeps running, PartyHud degrades. Plus four hardening items the same incident exposed: a startup codec self-check, decode-boundary numeric clamps, a client-side foreign-data staleness heartbeat, and folding the durable lessons into the `dst-mod-crash-audit` skill.

Approved spec: `docs/superpowers/specs/2026-06-19-crash-guard-design.md` (research workflow `wruf4uvg9`).

## Architecture

The engine dispatches PartyHud's server-side runtime callbacks with **no pcall** on three paths, all verified against the extracted game source:

- `DoPeriodicTask`/`DoTaskInTime` body — `Scheduler:OnTick` calls `k.fn(unpack(k.arg))` bare (`scheduler.lua:184-190`).
- `ListenForEvent` handler — `PushEvent_Internal` calls `fn(self, data)` bare (`entityscript.lua:1298-1300`).
- Shard-RPC handler — crosses into C++ `CallShardRPC` (`networkclientrpc.lua:1783`); unverifiable, treat as naked.

A dedicated server has **no error screen** (`SetGlobalErrorWidget` is gated behind `not TheNet:IsDedicated()`, `gamelogic.lua:42,56-63`) and **no runtime mod-disable**, so a throw on any of these paths halts the shard and repeats forever. The fix is a thin `guarded(label, fn)` wrapper mirroring the engine's own `runmodfn` idiom (`mods.lua:195`): `xpcall` the body, log the traceback once per label, swallow, and let the next tick/event run.

**Sandbox constraint (root cause + a constraint on the fix):** modmain's env (`mods.lua:302-331`) whitelists `pairs/ipairs/print/math/table/type/string/tostring/require/Class/TUNING/GLOBAL` — it does **NOT** whitelist `tonumber`, `pcall`, `xpcall`, `error`, `unpack`, or `debug`. A bare `pcall` inside the guard is `nil` and crashes exactly where it should protect. The guard MUST use `GLOBAL.pcall` / `GLOBAL.xpcall` / `GLOBAL.debug.traceback` / `GLOBAL.unpack` / `GLOBAL.tostring` / `GLOBAL.error`. Verified against the whitelist above.

Two hardening items live in the engine-free codec module (`partyhud_statuscodec.lua`), which is `require`d into full `_G` (NOT the sandbox), so bare `assert`/`tonumber` are safe there:
- **Startup self-check** at require-time runs inside the engine's `xpcall` (`mods.lua`), so a broken codec build disables the mod cleanly instead of silently failing inside the now-`guarded()` 2 Hz task.
- **Decode-boundary numeric clamps** clamp-and-log-once but KEEP the record (structural rejection stays reserved for the existing `nil + reason` returns).

One hardening item is client-only and cannot crash the shard: the **foreign-data staleness heartbeat** catches a broadcast task that wedges/stops *silently* (a guard catches a throw, not a silent stop), hiding stale cross-shard badges via the existing trailing-slot clear.

## Tech Stack

- Lua 5.1 (LuaJIT runtime in DST).
- Pure-logic modules in `scripts/partyhud_*.lua` (zero engine deps), tested with busted in `spec/*_spec.lua`. Run locally via `luajit spec/run_local.lua` (the no-luarocks shim — supports `describe`/`it`/`before_each`/`assert.are.same`/`assert.are.equal`/`assert.is_nil`/`assert.is_true`/`assert.is_false`/`assert.is_truthy`/`assert.has_error`; NO `spy`/`stub`, so use plain injected function tables). CI uses real busted (`.busted` → `busted spec/`).
- Engine wiring lives in `modmain.lua` (the restricted sandbox; use `GLOBAL.<fn>` for non-whitelisted builtins).
- Formatting: StyLua 2-space (`.stylua.toml`, `column_width=120`, `call_parentheses="Always"`); CI `stylua --check` is blocking.
- Linting: luacheck `std="lua51"`; CI requires 0 warnings / 0 errors.

**Gates before EVERY commit (all three must pass):**
1. `luacheck modmain.lua scripts/ spec/` → `0 warnings / 0 errors`.
2. `stylua --check .` → clean (no diff).
3. `luajit spec/run_local.lua` → all specs pass (CI runs real `busted spec/`).

**DRY/YAGNI/TDD/frequent commits.** One logical change per commit, ticket-number-first (`PHUD-` style prefix or per repo convention). Write the failing test first where a pure-logic test is possible.

### modinfo is NOT bumped by this plan

This plan does **NOT** edit `modinfo.lua` / bump the version. The v2026.11 **avatars + name-colour** plan owns the `version = "2026.11"` bump (currently `2026.10`). The two plans ship in the same release; sequence the modinfo bump with the avatars plan, not here.

---

## Coordination with the concurrent avatars plan (shared working tree)

Both v2026.11 plans edit `modmain.lua`. The regions this crash-guard plan touches, named so the two plans can be sequenced without stepping on each other:

| Region (current line range) | What this plan does | Function / anchor |
|---|---|---|
| Top of modmain, the forward-require block ~`82-112` | ADD: `GLOBAL.pcall/xpcall/unpack/tostring/error` aliases, `traceback`, `PARTYHUD_DEV_RERAISE`, `_logged`, `guarded()` | new upvalue block, placed AFTER `local crossshard = ...` and the other forward-requires, BEFORE `if positional == 0` (~114). Self-contained insert; no existing line edited. |
| `UpdateBadges` closure `433-630`, foreign-append guard at `538`, trailing-slot clear at `622-629` | MODIFY: add freshness clause to the `if show_crossshard and ...` condition at `538`; add `last_foreign_blob_time` upvalue + `FOREIGN_STALE_SECS`. Trailing-slot clear unchanged (it does the hiding). | `UpdateBadges` |
| Server hooks bind block `778-789` (inside `customhppostinit`) | MODIFY: wrap each of the 11 `inst:ListenForEvent(..., handler)` registrations in `guarded("ev:<name>", handler)` | `customhppostinit` |
| Shard-RPC handler `932-957` | MODIFY: wrap the `crossshard.upsert(...)` call in `guarded("xshard:upsert", ...)()` (defense-in-depth behind the C++ boundary) | `AddShardModRPCHandler` callback |
| 0.5s broadcast task `971-1039` | MODIFY: wrap the whole `function() ... end` body passed to `DoPeriodicTask` in `guarded("broadcast", ...)` | `AddSimPostInit` body |
| Carrier-dirty handler `1056-1081`, write site `1070` | MODIFY: stamp `last_foreign_blob_time = GLOBAL.GetTime()` where `client_foreign_records = records` is set | `attach_carrier` client branch |

The avatars plan will add: a name-colour read in `UpdateBadges` (the local + foreign render passes ~`494-501` / `594-608`), an avatar widget call in `partybadge.lua`, and possibly a new netvar in `customhppostinit`. **Conflict-prone shared anchors:** (a) `UpdateBadges` line `538` and the local/foreign render passes — both plans edit `UpdateBadges`; (b) `customhppostinit` — avatars may add a netvar near `757-775`, this plan wraps the listener binds at `778-789`. **Recommended sequencing:** land this crash-guard plan FIRST (it is mechanical wrapping + additive upvalues, smaller diff surface), then the avatars plan merges/rebases on top and benefits from `guarded()` already existing (it can wrap its own new callbacks). If the avatars plan lands first, this plan merges `origin/master` with a follow-up merge commit per the repo's concurrent-MR rule and re-applies the wraps.

---

## File Structure

**Modify:**
- `modmain.lua` — Tasks 1, 2, 3, 4, 7 (regions above).
- `scripts/partyhud_statuscodec.lua` — Tasks 5 (startup self-check), 6 (decode clamps).
- `spec/statuscodec_spec.lua` — Tasks 5, 6 (matching busted assertions).
- `.claude/skills/dst-mod-crash-audit/SKILL.md` — Task 9 (fold in the wrap-at-registration rule + connected-player smoke).

**Create:**
- `spec/guard_spec.lua` — Task 8 (busted spec for the `guarded()` decision logic, engine-free via injected stubs).
- `scripts/partyhud_guard.lua` — Task 8 (a tiny pure factory holding the testable guard decision logic, injected with `pcall`/`print` so it stays engine-free; modmain's `guarded()` is the thin `GLOBAL.`-bound wiring around it). See Task 1 + Task 8 for the split.

---

## Task 1: The `guarded()` helper + GLOBAL aliases at the top of modmain

The incident's root cause was a bare builtin in the sandbox. The guard itself MUST avoid that trap. This task adds the helper as a self-contained upvalue block; no existing modmain line is edited. The *decision logic* (call-through / swallow+log-once / re-raise) is extracted to a pure module in Task 8 and required here, so the thing we unit-test and the thing modmain runs are the same code.

**Files:**
- Modify: `modmain.lua` (insert after the forward-require block ~line 112, before `if positional == 0` ~line 114)
- Create: `scripts/partyhud_guard.lua` (the pure factory — written in Task 8 first; this task wires it)
- Test: covered by `spec/guard_spec.lua` (Task 8)

**Steps:**

- [ ] 1. Confirm Task 8 has landed `scripts/partyhud_guard.lua` (the pure factory) and `spec/guard_spec.lua` green. If executing strictly in order, do Task 8 BEFORE this task — the module must exist to require it. Run:

  ```
  luajit spec/run_local.lua
  ```

  Expected output ends with a line like `OK  <N> tests passed` and exit 0. If `partyhud_guard.lua` does not exist yet, switch to Task 8 first.

- [ ] 2. Add the guard block to `modmain.lua`. Insert this block immediately AFTER the `local get_client_foreign_records -- forward decl ...` line (currently line 112) and BEFORE the `if positional == 0 then` block (currently line 114):

  ```lua
  -- ============================================================================================
  -- v2026.11 SERVER-SIDE CRASH GUARD (design: docs/superpowers/specs/2026-06-19-crash-guard-design.md)
  --
  -- The engine dispatches our server-side runtime callbacks with NO pcall on three paths:
  --   * DoPeriodicTask/DoTaskInTime body  -- Scheduler:OnTick, bare k.fn(unpack(k.arg))  (scheduler.lua:184-190)
  --   * ListenForEvent handler            -- PushEvent_Internal, bare fn(self, data)     (entityscript.lua:1298-1300)
  --   * Shard-RPC handler                 -- crosses into C++ CallShardRPC                (networkclientrpc.lua:1783)
  -- A dedicated server has NO error screen and NO runtime mod-disable, so a throw on any of these
  -- HALTS the master shard and repeats forever (the bare-tonumber incident). guarded() converts a
  -- shard-fatal throw into a logged, skipped tick/event.
  --
  -- SANDBOX-CORRECT: bare pcall/xpcall/unpack/error/debug are nil in modmain's env (mods.lua:302-331,
  -- whitelists tostring but NOT these) -- a bare pcall here would crash exactly where it must protect.
  -- These aliases stay plain locals; Lua 5.1 has no `const`, and luacheck std="lua51" (in the 0/0
  -- gate) catches accidental reassignment.
  local pcall = GLOBAL.pcall
  local xpcall = GLOBAL.xpcall
  local unpack = GLOBAL.unpack
  local tostring_g = GLOBAL.tostring
  local error_g = GLOBAL.error
  local traceback = GLOBAL.debug and GLOBAL.debug.traceback

  -- Flip true while developing / in CI / dogfood so crashes still surface LOUDLY (the de-dup +
  -- re-raise are load-bearing: a guard that hides bugs silently is worse than the crash). Ship false.
  local PARTYHUD_DEV_RERAISE = false

  -- The pure decision logic (call-through / swallow+log-once / re-raise) lives in partyhud_guard so it
  -- is busted-tested engine-free (spec/guard_spec.lua). modmain only supplies the GLOBAL.-bound wiring.
  local guardlogic = _G.require("partyhud_guard")
  local _guard_state = { logged = {} } -- de-dup: one stack per label, not one per 0.5s tick
  local guard_runner = guardlogic.make({
    pcall = pcall,
    xpcall = xpcall,
    unpack = unpack,
    tostring = tostring_g,
    traceback = traceback,
    error = error_g,
    print = GLOBAL.print,
    state = _guard_state,
    dev_reraise = function()
      return PARTYHUD_DEV_RERAISE
    end,
  })

  -- guarded(label, fn) -> a function that runs fn(...) under xpcall; on a throw it logs the traceback
  -- ONCE per label and swallows (engine discards callback returns on all three dispatch paths). The
  -- periodic task is re-listed by the scheduler (period-driven, not return-driven) so a skipped tick
  -- resumes next tick; an event handler resumes on the next event. Do NOT serve stale netvars as fresh.
  local function guarded(label, fn)
    return guard_runner(label, fn)
  end
  ```

- [ ] 3. Run the full gate (no behaviour wired yet, so the only risk is a syntax/lint/format slip in the new block):

  ```
  luacheck modmain.lua scripts/ spec/ && stylua --check . && luajit spec/run_local.lua
  ```

  Expected: luacheck `0 warnings / 0 errors`, `stylua --check` prints nothing (exit 0), specs end `OK`. If luacheck flags `pcall`/`xpcall`/`unpack` as unused, that is expected ONLY until Task 2-4 use them via `guarded`; since `guard_runner` captures them they are used immediately — confirm 0/0. If StyLua reformats, accept its formatting and re-run.

- [ ] 4. Commit:

  ```
  git add modmain.lua && git commit -m "PHUD-CG add guarded() helper + GLOBAL builtin aliases at top of modmain

  - wire the pure partyhud_guard factory with GLOBAL.pcall/xpcall/unpack/tostring/error + debug.traceback
  - PARTYHUD_DEV_RERAISE=false (ship), _logged de-dup state
  - sandbox-correct: no bare pcall/xpcall (mods.lua:302-331 whitelists neither)
  - no wrap sites yet (Tasks 2-4 attach guarded() to the broadcast task, 11 event hooks, shard-RPC)"
  ```

---

## Task 2: Wrap the 0.5s broadcast task

The incident site and widest API surface (`build_local_records`, `codec.encode`, `Shard_GetConnectedShards`, `crossshard.*`, carrier `:set`). Idempotent + re-runs in 0.5s, so skip-this-tick is the correct degrade.

**Files:**
- Modify: `modmain.lua` (the `DoPeriodicTask` call in the `AddSimPostInit` body, currently line 971)

**Steps:**

- [ ] 1. Read the current task registration to confirm the exact text. The body is a multi-line anonymous function passed to `DoPeriodicTask`:

  ```
  grep -n "GLOBAL.TheWorld:DoPeriodicTask(0.5, function()" modmain.lua
  ```

  Expected: one match at the broadcast task (currently `971`).

- [ ] 2. Wrap the body. Change the opening line of the periodic task from:

  ```lua
  GLOBAL.TheWorld:DoPeriodicTask(0.5, function()
  ```

  to:

  ```lua
  GLOBAL.TheWorld:DoPeriodicTask(
    0.5,
    guarded("broadcast", function()
  ```

  and change the closing of the task from:

  ```lua
  end)
  end)
  ```

  (the inner `end)` closes the `DoPeriodicTask` anonymous function, the outer `end)` closes the `AddSimPostInit`) to:

  ```lua
    end)
  )
  end)
  ```

  i.e. the inner `function()...end` is now `guarded("broadcast", function()...end)`, so it needs `end)` to close the function-literal-inside-guarded, then `)` to close the `DoPeriodicTask(0.5, ...)` call. StyLua will normalise the indentation — do not hand-fight it.

- [ ] 3. Run the gate:

  ```
  luacheck modmain.lua scripts/ spec/ && stylua --check . && luajit spec/run_local.lua
  ```

  Expected: 0/0, clean format, specs `OK`. If `stylua --check` shows a diff, run `stylua .` to apply, re-read the region to confirm the wrap is structurally intact (`guarded("broadcast", function()` opens, the matching `end)` and `)` close), then re-run `--check`.

- [ ] 4. Commit:

  ```
  git add modmain.lua && git commit -m "PHUD-CG wrap the 0.5s cross-shard broadcast task in guarded()

  - the bare-tonumber incident site; widest server-side API surface
  - a throw now logs once + skips THIS tick; the period-driven scheduler resumes in 0.5s
  - skip-this-tick is the correct degrade (the task is idempotent + re-runs)"
  ```

---

## Task 3: Wrap the 11 server event hooks at bind

Wrap each `inst:ListenForEvent(..., handler)` in `customhppostinit` so a throwing handler logs once and the player's badge keeps the previous field value (bounded + self-healing on the next delta).

**Files:**
- Modify: `modmain.lua` (the server-hook bind block inside `customhppostinit`, currently lines 778-789)

**Steps:**

- [ ] 1. Confirm the 11 binds. Run:

  ```
  grep -n 'inst:ListenForEvent("' modmain.lua | sed -n '1,40p'
  ```

  Expected: the block at `779-789` shows exactly these 11 (in this order): `healthdelta`, `ms_respawnedfromghost`, `ms_becameghost`, `hungerdelta`, `sanitydelta`, `startfiredamage`, `stopfiredamage`, `startoverheating`, `stopoverheating`, `startfreezing`, `stopfreezing`. (The client-side binds at `823-824` and the presence binds at `426-427` are NOT in this block and are NOT wrapped here — they are client-side, lower priority per the spec.)

- [ ] 2. Replace the 11 bind lines (currently 779-789) with their guarded forms. The label is `ev:<eventname>` so the de-dup keys per-event:

  ```lua
      inst:ListenForEvent("healthdelta", guarded("ev:healthdelta", onhealthdelta))
      inst:ListenForEvent("ms_respawnedfromghost", guarded("ev:ms_respawnedfromghost", onrespawnedfromghost))
      inst:ListenForEvent("ms_becameghost", guarded("ev:ms_becameghost", onbecameghost))
      inst:ListenForEvent("hungerdelta", guarded("ev:hungerdelta", onhungerdelta))
      inst:ListenForEvent("sanitydelta", guarded("ev:sanitydelta", onsanitydelta))
      inst:ListenForEvent("startfiredamage", guarded("ev:startfiredamage", onstartfire))
      inst:ListenForEvent("stopfiredamage", guarded("ev:stopfiredamage", onstopfire))
      inst:ListenForEvent("startoverheating", guarded("ev:startoverheating", onstartoverheating))
      inst:ListenForEvent("stopoverheating", guarded("ev:stopoverheating", onstopoverheating))
      inst:ListenForEvent("startfreezing", guarded("ev:startfreezing", onstartfreezing))
      inst:ListenForEvent("stopfreezing", guarded("ev:stopfreezing", onstopfreezing))
  ```

  Note: `guarded` is a module-level upvalue (Task 1), and `customhppostinit` is defined far below where `guarded` is in scope, so it captures it as an upvalue — no forward-decl problem (the closure is defined after the upvalue, the correct direction).

- [ ] 3. Run the gate:

  ```
  luacheck modmain.lua scripts/ spec/ && stylua --check . && luajit spec/run_local.lua
  ```

  Expected: 0/0, clean, `OK`.

- [ ] 4. Commit:

  ```
  git add modmain.lua && git commit -m "PHUD-CG wrap the 11 server event hooks in guarded() at bind

  - healthdelta/hunger/sanity/fire/overheat/freeze/ghost handlers on the player inst
  - a throwing handler logs once (per-event label) + skips that event; the field self-heals on next delta
  - per spec, the WRAP is at registration -- being inside a (protected) postinit does not protect the (naked) closures it installs"
  ```

---

## Task 4: Wrap `crossshard.upsert` behind the shard-RPC handler

Defense-in-depth behind the C++ `CallShardRPC` boundary (`networkclientrpc.lua:1783`, unverifiable → treat as naked). The handler is already hand-written fail-soft on decode (log-and-drop); this wraps the one call that touches mutable state.

**Files:**
- Modify: `modmain.lua` (the `AddShardModRPCHandler` callback body, the `crossshard.upsert(...)` call currently line 953)

**Steps:**

- [ ] 1. Confirm the call site:

  ```
  grep -n "crossshard.upsert(foreign_store" modmain.lua
  ```

  Expected: one match (currently `953`), inside the RPC handler after the v1-backfill loop.

- [ ] 2. Replace the bare call:

  ```lua
    crossshard.upsert(foreign_store, records, GLOBAL.GetTime())
  ```

  with a guarded immediate-invoke (the handler is not itself wrapped at registration — `AddShardModRPCHandler` takes a callback we cannot re-wrap as cleanly, and the decode-guard already protects the parse; only the state mutation needs the net):

  ```lua
    -- defense-in-depth behind the C++ CallShardRPC boundary (networkclientrpc.lua:1783, unverifiable
    -- => treat as naked): a throw inside upsert must not propagate back across the boundary.
    guarded("xshard:upsert", function()
      crossshard.upsert(foreign_store, records, GLOBAL.GetTime())
    end)()
  ```

  Note the trailing `()` — `guarded` RETURNS a function; we invoke it immediately here (unlike the periodic-task and event-bind sites, which hand the returned function to the engine to call later).

- [ ] 3. Run the gate:

  ```
  luacheck modmain.lua scripts/ spec/ && stylua --check . && luajit spec/run_local.lua
  ```

  Expected: 0/0, clean, `OK`.

- [ ] 4. Commit:

  ```
  git add modmain.lua && git commit -m "PHUD-CG guard crossshard.upsert behind the shard-RPC handler

  - defense-in-depth behind the C++ CallShardRPC boundary (treat as naked)
  - the decode-guard already log-and-drops a bad payload; this nets a throw in the state mutation
  - immediate-invoke form: guarded(...)() since the handler is not wrapped at registration"
  ```

---

## Task 5: Q4 startup codec round-trip self-check

A broken codec build (someone edits `NUM_FIELDS`/`NUMERIC`/`FLAGS`/`SUPPORTED`/`PROTOCOL_VERSION`) should fail LOUDLY at require-time — inside the engine's `xpcall` (`mods.lua`), so the mod disables cleanly + logs — instead of silently inside the now-`guarded()` 2 Hz task (which would swallow it). Bare `assert`/`tonumber` are safe here: the codec is `require`d into full `_G`, not modmain's sandbox.

**Files:**
- Modify: `scripts/partyhud_statuscodec.lua` (bottom, before `return M`, currently line 180)
- Test: `spec/statuscodec_spec.lua` (matching busted assertion)

**Steps:**

- [ ] 1. Write the failing test first. Add this `describe` block to `spec/statuscodec_spec.lua`, immediately before the final `end)` that closes the top-level `describe("partyhud status codec", ...)` (currently line 309):

  ```lua
    describe("startup self-check (Q4)", function()
      it("the current PROTOCOL_VERSION is in SUPPORTED", function()
        -- require-time assert(SUPPORTED[PROTOCOL_VERSION]) guards a version bump without a SUPPORTED entry
        local ver = codec.decode(codec.encode({}))
        assert.are.equal(codec.PROTOCOL_VERSION, ver)
      end)

      it("a probe record survives an encode->decode round-trip at the default version", function()
        local probe = {
          {
            userid = "KU_selfcheck",
            hp_cur = 100,
            hp_max = 150,
            hp_penalty = 0,
            hunger = 80,
            sanity_cur = 120,
            sanity_max = 200,
            sanity_penalty = 0,
            flags = 0,
            origin = 1,
          },
        }
        local ver, out = codec.decode(codec.encode(probe))
        assert.are.equal(codec.PROTOCOL_VERSION, ver)
        assert.are.same(probe, out)
      end)
    end)
  ```

- [ ] 2. Run it — it must PASS already at the test level (the round-trip is the codec's existing contract); the new SAFETY is at require-time. To see the require-time check actually fire, the test step here is the require-itself: if the self-check throws, `require("partyhud_statuscodec")` at the top of the spec throws and the WHOLE spec errors. Run:

  ```
  luajit spec/run_local.lua
  ```

  Expected: the spec loads (require succeeds) and the two new `it` blocks pass. This confirms the existing codec is self-consistent; the next step adds the require-time guard that makes a FUTURE broken edit fail here loudly.

- [ ] 3. Add the require-time self-check to `scripts/partyhud_statuscodec.lua`. Insert immediately BEFORE the final `return M` (currently line 180):

  ```lua
  -- ============================================================================================
  -- STARTUP SELF-CHECK (Q4). Runs at require-time, inside the engine's xpcall (mods.lua), so a
  -- broken codec build (a bad NUM_FIELDS / NUMERIC / FLAGS / SUPPORTED / PROTOCOL_VERSION edit) fails
  -- LOUDLY here and disables the mod cleanly -- instead of failing silently inside the guarded() 2 Hz
  -- broadcast task, which would swallow it. Bare assert/tonumber are safe: this module is required into
  -- full _G, NOT modmain's restricted sandbox.
  -- ============================================================================================
  assert(SUPPORTED[M.PROTOCOL_VERSION], "PROTOCOL_VERSION " .. tostring(M.PROTOCOL_VERSION) .. " is not in SUPPORTED")
  do
    -- encode->decode a probe record and assert it survives, so the wire format is provably coherent
    -- before the first real broadcast.
    local probe = {
      {
        userid = "KU_selfcheck",
        hp_cur = 100,
        hp_max = 150,
        hp_penalty = 0,
        hunger = 80,
        sanity_cur = 120,
        sanity_max = 200,
        sanity_penalty = 0,
        flags = 0,
        origin = 1,
      },
    }
    local ver, out = M.decode(M.encode(probe))
    assert(ver == M.PROTOCOL_VERSION, "self-check: decoded version mismatch")
    assert(out ~= nil and out[1] ~= nil, "self-check: probe failed to round-trip")
    assert(out[1].userid == "KU_selfcheck" and out[1].hp_cur == 100 and out[1].origin == 1, "self-check: probe field mismatch")
  end
  ```

- [ ] 4. Run the gate (the self-check now runs every time the module is required, including under the spec's top-level `require`):

  ```
  luacheck modmain.lua scripts/ spec/ && stylua --check . && luajit spec/run_local.lua
  ```

  Expected: 0/0, clean, `OK`. If the self-check throws, the spec errors at require — which would mean the existing codec is inconsistent (it is not, verified). To confirm the guard BITES on a broken build, temporarily change `M.PROTOCOL_VERSION = 2` to `= 9` and re-run: expect a require-time `assert` failure mentioning "not in SUPPORTED"; then REVERT to `2` before committing.

- [ ] 5. Commit:

  ```
  git add scripts/partyhud_statuscodec.lua spec/statuscodec_spec.lua && git commit -m "PHUD-CG add Q4 startup codec round-trip self-check

  - require-time assert(SUPPORTED[PROTOCOL_VERSION]) + encode->decode probe
  - a broken NUM_FIELDS/NUMERIC/FLAGS/SUPPORTED edit now fails LOUDLY inside the engine xpcall (mod disables clean)
  - instead of silently inside the guarded() 2 Hz task; bare assert safe (full _G, not the modmain sandbox)
  - matching busted assertions in statuscodec_spec.lua"
  ```

---

## Task 6: Q3 decode-boundary numeric clamps

The decoder is where untrusted cross-shard bytes enter. It already validates STRUCTURE and returns `nil + reason` (never throws). Add value-range clamping for the numerics whose out-of-range value would misrender — but **clamp-and-log-once and KEEP the record** (structural rejection stays reserved for the existing returns). Clamp `hp_cur`/`hunger`/`sanity_cur` to `>= 0`; the `*_max`/`*_penalty` fields are already clamped by `record.normalize_*`'s `max>0` clamp, so the new yield here is the `cur >= 0` floor. Skip `flags`/`sanity rate`/`origin` (the renderer already degrades safely — log-noise only, per spec Out-of-scope).

**Files:**
- Modify: `scripts/partyhud_statuscodec.lua` (a `clamp_num` helper + the decode loop, currently the `for j, name in ipairs(NUMERIC)` block at lines 167-173)
- Test: `spec/statuscodec_spec.lua`

**Steps:**

- [ ] 1. Write the failing tests first. Add this `describe` block to `spec/statuscodec_spec.lua`, before the final top-level `end)` (after the Task-5 block):

  ```lua
    describe("decode-boundary numeric clamps (Q3)", function()
      it("clamps a negative hp_cur to 0 and KEEPS the record", function()
        -- v1 hand-built string with hp_cur = -5 (field 1 after userid)
        local ver, out = codec.decode("1|1|KU_x:-5:150:0:80:120:200:0:0")
        assert.are.equal(1, ver)
        assert.is_truthy(out)
        assert.are.equal(0, out[1].hp_cur)
      end)

      it("clamps a negative hunger and sanity_cur to 0", function()
        local _, out = codec.decode("1|1|KU_x:100:150:0:-3:-7:200:0:0")
        assert.are.equal(0, out[1].hunger)
        assert.are.equal(0, out[1].sanity_cur)
      end)

      it("leaves an in-range record untouched", function()
        local _, out = codec.decode("1|1|KU_x:90:150:0:80:120:200:0:0")
        assert.are.equal(90, out[1].hp_cur)
        assert.are.equal(80, out[1].hunger)
        assert.are.equal(120, out[1].sanity_cur)
      end)

      it("does NOT reject the whole payload on an out-of-range value", function()
        -- structural errors still return nil; a clamped value must NOT
        local ver = codec.decode("1|1|KU_x:-5:150:0:80:120:200:0:0")
        assert.are.equal(1, ver)
      end)
    end)
  ```

- [ ] 2. Run them — they must FAIL (no clamp yet, so `hp_cur` round-trips as `-5`):

  ```
  luajit spec/run_local.lua
  ```

  Expected: failures in the new "clamps a negative ..." cases reporting `are.equal failed: -5 ~= 0` (or similar). This confirms the test exercises real behaviour.

- [ ] 3. Add the clamp. In `scripts/partyhud_statuscodec.lua`, add the helper near the top of the module (after the `NUM_FIELDS` local, currently line 68):

  ```lua
  -- A de-dup set so a surprise out-of-range value logs ONCE per field name, not once per 0.5s payload.
  local _clamp_logged = {}

  -- clamp_num(v, lo, hi, name) -> clamped value, logging once if it was out of range. hi may be nil
  -- (no upper bound). Used at the decode boundary for the numerics whose out-of-range value would
  -- misrender. Clamps + KEEPS the record (structural rejection stays the job of the nil+reason returns).
  local function clamp_num(v, lo, hi, name)
    local c = v
    if lo ~= nil and c < lo then
      c = lo
    end
    if hi ~= nil and c > hi then
      c = hi
    end
    if c ~= v and not _clamp_logged[name] then
      _clamp_logged[name] = true
      print("[PartyHud] codec clamped out-of-range '" .. name .. "' (" .. tostring(v) .. " -> " .. tostring(c) .. "); further repeats suppressed")
    end
    return c
  end
  ```

  Then in the decode loop, replace the field-assign at the bottom of the `for j, name in ipairs(NUMERIC)` block (currently `rec[name] = x` at line 172) with a clamp for the three current-value fields, keeping every other field as-is:

  ```lua
      if name == "hp_cur" or name == "hunger" or name == "sanity_cur" then
        rec[name] = clamp_num(x, 0, nil, name)
      else
        rec[name] = x
      end
  ```

- [ ] 4. Run the gate (the new cases now pass; the existing round-trip cases still pass because their values are all in range):

  ```
  luacheck modmain.lua scripts/ spec/ && stylua --check . && luajit spec/run_local.lua
  ```

  Expected: 0/0, clean, `OK`. NOTE: the existing "preserves extreme numeric values (WX-78 400 HP, ...)" test has `sanity_cur = 0` which the clamp leaves as `0` (no change), so it still round-trips exactly — confirm it stays green.

- [ ] 5. Commit:

  ```
  git add scripts/partyhud_statuscodec.lua spec/statuscodec_spec.lua && git commit -m "PHUD-CG add Q3 decode-boundary numeric clamps (cur>=0, keep record)

  - clamp_num helper clamps hp_cur/hunger/sanity_cur to >=0 and logs once per field
  - clamp-and-KEEP: structural rejection stays reserved for the existing nil+reason returns
  - skip flags/rate/origin (renderer already degrades safely -- log-noise only, per spec)"
  ```

---

## Task 7: Q5 client-side foreign-data staleness heartbeat

A guard catches a *throw*; it does NOT catch a broadcast task that wedges/stops *silently* — and that case actively misinforms (stale HP is worse than no badge). The TTL `expire` AND the carrier `:set` both live INSIDE the 0.5s task, so a wedged task freezes `client_foreign_records` at stale HP for minutes. Fix (client-only, cannot crash the shard): stamp `last_foreign_blob_time` on each carrier-dirty update; add a freshness clause to the foreign-append guard; the EXISTING trailing-slot clear hides the skipped badges with no new clear code.

> **Coordination with the concurrent avatars plan (this is the conflict-prone anchor):** this task adds the
> `and foreign_fresh` clause to the **line-538** foreign-append guard. The avatars plan (Task 8 step 5)
> deletes the `namebyuserid` build at **lines 540-548**, which sits INSIDE this very `if` block, and hoists
> it to the top of `UpdateBadges`. Both plans therefore edit the line-538 region. This crash-guard plan is
> sequenced to land **FIRST**; if for any reason it lands SECOND (after avatars), the avatars plan will
> have moved the `namebyuserid` build away but left the `if show_crossshard and not DEBUG_SHOWALL and
> next_slot <= maxbadges then` guard in place — so re-applying this task's freshness clause is still the
> same edit. Conversely, when avatars lands second it MUST PRESERVE the `and foreign_fresh` clause this task
> adds (do not let it revert the guard to its bare pre-crash-guard form). Re-grep the guard line before
> editing — see Step 2.

**Files:**
- Modify: `modmain.lua` (the foreign-append guard at line 538; the carrier-dirty write at line 1070; a `last_foreign_blob_time` upvalue + `FOREIGN_STALE_SECS` const)

**Steps:**

- [ ] 1. Add the upvalue + const. Insert immediately AFTER the `local get_client_foreign_records -- forward decl ...` line (currently 112) and BEFORE the Task-1 guard block:

  ```lua
  -- v2026.11 Q5 FOREIGN-DATA STALENESS HEARTBEAT (client-only; cannot crash the shard).
  -- guarded() catches a THROW; it does NOT catch a broadcast task that wedges/stops SILENTLY. The TTL
  -- expire + the carrier :set both live inside the 0.5s task (modmain ~996/~1034), so a wedged task
  -- freezes client_foreign_records at stale HP for minutes. Stamp the receive time on every carrier-
  -- dirty update; the foreign-append render block checks freshness and, when stale, SKIPS appending --
  -- the existing trailing-slot clear (~622-629) then runs SetForeign(false)/HideBadge() so the stale
  -- cross-shard badges vanish with NO new clear code. FOREIGN_STALE_SECS = 5 is 10x the 0.5s cadence
  -- and > the 3s server TTL, biased against false-positive hiding.
  local FOREIGN_STALE_SECS = 5
  local last_foreign_blob_time = 0 -- GetTime() of the last carrier-dirty update; 0 = none yet
  local _foreign_stale_logged = false -- log-once when we start hiding stale foreign badges
  ```

  (Place this block ahead of the guard block so both are at the top; ordering between them does not matter, but keep both before `if positional == 0`.)

- [ ] 2. Add the freshness clause to the foreign-append guard. The condition currently at line 538 is:

  ```lua
    if show_crossshard and not DEBUG_SHOWALL and next_slot <= maxbadges then
  ```

  Change it to gate on freshness too, and log-once when the heartbeat trips:

  ```lua
    -- Q5 freshness: if the carrier blob has not refreshed within FOREIGN_STALE_SECS, the server's
    -- broadcast task has likely wedged -- the foreign HP is stale and misleading, so SKIP the append.
    -- The trailing-slot clear below then hides those slots. last_foreign_blob_time == 0 (no blob yet)
    -- is treated as stale, which is correct: nothing to show until the first real publish arrives.
    local foreign_fresh = last_foreign_blob_time > 0
      and (GLOBAL.GetTime() - last_foreign_blob_time) <= FOREIGN_STALE_SECS
    if not foreign_fresh and last_foreign_blob_time > 0 and not _foreign_stale_logged then
      _foreign_stale_logged = true
      GLOBAL.print("[PartyHud] foreign data stale, hiding cross-shard badges (further repeats suppressed)")
    end
    if show_crossshard and not DEBUG_SHOWALL and foreign_fresh and next_slot <= maxbadges then
  ```

  IMPORTANT: do NOT touch the trailing-slot clear at 622-629 — it already runs unconditionally with `next_slot` unchanged when the block is skipped, which is exactly the hide we want. Verify by reading lines 620-629 after the edit that the `for i = next_slot, maxbadges do ... b:SetForeign(false); b:HideBadge() end` loop is intact and still outside the skipped block.

- [ ] 3. Stamp the receive time. In the carrier-dirty handler (the client branch of `attach_carrier`), the write currently at line 1070 is:

  ```lua
        client_foreign_records = records
  ```

  Change it to also stamp the freshness clock and reset the log-once latch (a fresh blob means we are healthy again, so allow a future stale-log):

  ```lua
        client_foreign_records = records
        last_foreign_blob_time = GLOBAL.GetTime()
        _foreign_stale_logged = false -- a fresh blob arrived; re-arm the stale-log for the next outage
  ```

  Note `last_foreign_blob_time` / `_foreign_stale_logged` are module-level upvalues (Step 1), and both `UpdateBadges` (defined in `onstatusdisplaysconstruct`, above) and this `attach_carrier` closure (below) capture them — the upvalue is declared before both, so the capture is correct in both directions.

- [ ] 4. Run the gate:

  ```
  luacheck modmain.lua scripts/ spec/ && stylua --check . && luajit spec/run_local.lua
  ```

  Expected: 0/0, clean, `OK`. luacheck must not flag `FOREIGN_STALE_SECS` / `last_foreign_blob_time` / `_foreign_stale_logged` as unused (all three are read in `UpdateBadges` and/or written in `attach_carrier`).

- [ ] 5. Commit:

  ```
  git add modmain.lua && git commit -m "PHUD-CG add Q5 client-side foreign-data staleness heartbeat

  - stamp last_foreign_blob_time on every carrier-dirty update; FOREIGN_STALE_SECS=5
  - UpdateBadges foreign-append guard now also requires freshness; stale => skip append
  - the existing trailing-slot clear hides the skipped foreign badges (no new clear code)
  - catches a SILENTLY-wedged broadcast task (guarded() catches throws, not silent stops); client-only"
  ```

---

## Task 8: busted spec for `guarded()` (engine-free, injected stubs)

Test the wrapper's decision logic — call-through, swallow + log-once, re-raise under `DEV_RERAISE` — with injected `pcall`/`print` stubs so it stays engine-free. This is why Task 1 extracted the logic into `scripts/partyhud_guard.lua`: the module is pure (takes its `pcall`/`xpcall`/`print`/`state`/`dev_reraise` as injected deps), so busted can drive it on plain luajit with no DST runtime. Per the run_local shim's API (no `spy`/`stub`), use plain function tables that record calls.

**Files:**
- Create: `scripts/partyhud_guard.lua`
- Create: `spec/guard_spec.lua`

**Steps:**

- [ ] 1. Write the failing spec FIRST. Create `spec/guard_spec.lua`:

  ```lua
  -- spec/guard_spec.lua
  --
  -- busted unit tests for the pure guard decision logic (scripts/partyhud_guard.lua). The module is
  -- engine-free: it takes pcall/xpcall/unpack/tostring/traceback/error/print/state/dev_reraise as
  -- INJECTED deps, so these tests drive it with plain stubs on luajit -- no DST runtime, no GLOBAL.
  -- modmain.lua wires the same module with the real GLOBAL.-bound builtins.

  local guardlogic = require("partyhud_guard")

  -- Build a guard runner over a real (Lua) xpcall/pcall + recording print + a fresh state, with a
  -- toggleable dev_reraise. Returns the runner + the captured logs for assertions.
  local function make_runner(dev_reraise)
    local logs = {}
    local reraise = dev_reraise or false
    local runner = guardlogic.make({
      pcall = pcall,
      xpcall = xpcall,
      unpack = unpack or table.unpack, -- luajit: unpack; 5.2+: table.unpack
      tostring = tostring,
      traceback = function(e)
        return "TB:" .. tostring(e)
      end,
      error = error,
      print = function(s)
        logs[#logs + 1] = s
      end,
      state = { logged = {} },
      dev_reraise = function()
        return reraise
      end,
    })
    return runner, logs
  end

  describe("guarded()", function()
    it("calls through and the wrapped fn runs with its args", function()
      local runner = make_runner(false)
      local seen
      local wrapped = runner("ok", function(a, b)
        seen = a + b
      end)
      wrapped(2, 3)
      assert.are.equal(5, seen)
    end)

    it("returns nothing (engine discards callback returns)", function()
      local runner = make_runner(false)
      local wrapped = runner("ret", function()
        return 42
      end)
      local r = wrapped()
      assert.is_nil(r)
    end)

    it("swallows a throw and the wrapper does NOT propagate it", function()
      local runner, logs = make_runner(false)
      local wrapped = runner("boom", function()
        error("kaboom")
      end)
      -- must NOT throw out of wrapped()
      assert.has_no_error_local(function()
        wrapped()
      end)
      assert.are.equal(1, #logs)
      assert.is_truthy(logs[1]:find("boom"))
      assert.is_truthy(logs[1]:find("GUARD caught"))
    end)

    it("logs ONCE per label even when the fn throws repeatedly", function()
      local runner, logs = make_runner(false)
      local wrapped = runner("dup", function()
        error("again")
      end)
      wrapped()
      wrapped()
      wrapped()
      assert.are.equal(1, #logs)
    end)

    it("logs separately for distinct labels", function()
      local runner, logs = make_runner(false)
      runner("a", function()
        error("x")
      end)()
      runner("b", function()
        error("y")
      end)()
      assert.are.equal(2, #logs)
    end)

    it("re-raises when dev_reraise is true", function()
      local runner = make_runner(true)
      local wrapped = runner("dev", function()
        error("surface me")
      end)
      assert.has_error(function()
        wrapped()
      end)
    end)
  end)
  ```

  Note: `assert.has_no_error_local` does not exist in the run_local shim. Use a local helper instead — replace the `assert.has_no_error_local(function() wrapped() end)` line with:

  ```lua
      local ok = pcall(function()
        wrapped()
      end)
      assert.is_true(ok)
  ```

  (so the spec relies only on the shim's documented API: `is_true`, `is_nil`, `is_truthy`, `are.equal`, `has_error`).

- [ ] 2. Run it — it must FAIL because `scripts/partyhud_guard.lua` does not exist yet:

  ```
  luajit spec/run_local.lua
  ```

  Expected: an error like `module 'partyhud_guard' not found` (the require at the top of the spec fails). This is the red state.

- [ ] 3. Write the minimal implementation. Create `scripts/partyhud_guard.lua`:

  ```lua
  -- partyhud_guard.lua
  --
  -- PURE guard decision logic for the v2026.11 server-side crash guard. ZERO engine dependencies:
  -- it takes pcall/xpcall/unpack/tostring/traceback/error/print/state/dev_reraise as INJECTED deps,
  -- so it is busted-tested on plain luajit (spec/guard_spec.lua) with stubs. modmain.lua wires it with
  -- the GLOBAL.-bound builtins (GLOBAL.pcall/xpcall/unpack/tostring/error + GLOBAL.debug.traceback +
  -- GLOBAL.print) because modmain's restricted sandbox (mods.lua:302-331) does NOT whitelist them.
  --
  -- deps = {
  --   pcall, xpcall, unpack, tostring, traceback, error, print,  -- builtins
  --   state = { logged = {} },   -- de-dup set, one stack logged per label (not per tick)
  --   dev_reraise = function() return <bool> end,  -- when true, re-raise after logging (CI/dogfood)
  -- }
  --
  -- make(deps) -> guarded(label, fn) -> function(...) that runs fn(...) under xpcall, logs the
  -- traceback ONCE per label on a throw, swallows, and (if dev_reraise) re-raises. Returns nothing
  -- on either path (the engine discards callback returns on all three dispatch paths).

  local M = {}

  function M.make(deps)
    local xpcall = deps.xpcall
    local unpack = deps.unpack
    local tostring = deps.tostring
    local traceback = deps.traceback
    local error = deps.error
    local print = deps.print
    local state = deps.state
    local dev_reraise = deps.dev_reraise

    local function handler(err)
      return traceback and traceback(err) or tostring(err)
    end

    return function(label, fn)
      return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
          return fn(unpack(args))
        end, handler)
        if not ok then
          if not state.logged[label] then
            state.logged[label] = true
            print("[PartyHud] GUARD caught error in " .. label .. " (further repeats suppressed):\n" .. tostring(err))
          end
          if dev_reraise() then
            error(err, 0)
          end
        end
        return
      end
    end
  end

  return M
  ```

- [ ] 4. Run the spec — it must now PASS:

  ```
  luajit spec/run_local.lua
  ```

  Expected: all `guard_spec` cases pass, all other specs still pass, ends `OK`.

- [ ] 5. Run the full gate:

  ```
  luacheck modmain.lua scripts/ spec/ && stylua --check . && luajit spec/run_local.lua
  ```

  Expected: 0/0, clean, `OK`. (luacheck: `partyhud_guard.lua` shadows `pcall`/`xpcall`/`error`/`unpack`/`tostring` as locals — that is intentional dependency injection, std="lua51" treats them as read_globals so re-localising is fine; confirm 0/0.)

- [ ] 6. Commit:

  ```
  git add scripts/partyhud_guard.lua spec/guard_spec.lua && git commit -m "PHUD-CG add pure guard decision logic + busted spec

  - partyhud_guard.make(deps) -> guarded(label, fn): call-through / swallow+log-once / re-raise
  - engine-free via injected pcall/xpcall/unpack/print/state/dev_reraise (busted-tested on luajit)
  - modmain wires it with the GLOBAL.-bound builtins (Task 1)
  - covers: call-through with args, returns-nothing, swallow, log-once per label, distinct labels, dev re-raise"
  ```

  NOTE: if executing in order, this Task 8 must complete BEFORE Task 1 (Task 1 requires `partyhud_guard`). Reorder execution so the module + spec land first, then Task 1 wires it. The plan lists it as Task 8 only to keep the modmain-touching tasks contiguous; the dependency is Task 8 → Task 1 → Tasks 2/3/4/7.

---

## Task 9: Gate, full crash-audit, and skill update

The guard is a net, not a substitute for the gates that would have PREVENTED the incident. This task runs the full verification and folds the two durable lessons into the `dst-mod-crash-audit` skill so the next reviewer catches an unwrapped callback / unexercised periodic task.

**Files:**
- Modify: `.claude/skills/dst-mod-crash-audit/SKILL.md`

**Steps:**

- [ ] 1. Run the full gate one more time on the whole tree to confirm the accumulated changes are clean:

  ```
  luacheck modmain.lua scripts/ spec/ && stylua --check . && luajit spec/run_local.lua
  ```

  Expected: `0 warnings / 0 errors`, no StyLua diff, specs `OK`.

- [ ] 2. Run a full `dst-mod-crash-audit` pass (the 6-dimension fan-out) on the changed code, focusing on the server-side path that crashed before — D4 (sandbox: the guard helper must be `GLOBAL.`-prefixed, NOT bare) and D5 (listener lifecycle: the wrap is at registration). Invoke the skill per its method (dispatch read-only subagents per dimension, then audit the auditors against `~/code/dst/dst-scripts/scripts`). Confirm: every `pcall`/`xpcall`/`unpack`/`error`/`tostring`/`debug.traceback` reference reached from modmain resolves through `GLOBAL.`; no bare builtin survives in the new modmain blocks. Capture the verdict. There is no commit for this step unless the audit surfaces a fix (if it does, fix + re-gate + commit before proceeding).

- [ ] 3. Fold the wrap-at-registration rule into the skill's D5 dimension. In `.claude/skills/dst-mod-crash-audit/SKILL.md`, the D5 bullet currently reads (lines 100-104):

  ```
  5. **Event / listener lifecycle.** Double-registration (a per-entity postinit vs a per-HUD
     postconstruct); listeners that leak across HUD/entity rebuilds; callbacks/`DoTaskInTime`
     closures that fire after their target is removed (guard at FIRE time, not just registration);
     and **listener source correctness** — register on the entity whose removal should clean it up,
     with the right event source (this is both the v2026.3 crash and the clean-teardown pattern).
  ```

  Append this sentence to the end of that bullet (before the blank line at 105):

  ```
     **Wrap-at-registration (crash-guard) rule:** every mod-owned runtime callback registered on the
     sim-time scheduler (`DoPeriodicTask`/`DoTaskInTime`) or the event bus (`ListenForEvent`) is
     dispatched by the engine with NO pcall (`scheduler.lua:184-190`, `entityscript.lua:1298-1300`),
     and a shard-RPC handler crosses into C++ (`networkclientrpc.lua:1783`) — a throw there HALTS the
     dedicated-server shard (no error screen, no runtime mod-disable). Being inside a (engine-xpcall-
     protected) post-init body does NOT protect the (naked) closures it installs. Flag any such
     server-side callback that is not wrapped in a `GLOBAL.xpcall`-based guard at the point it is
     registered (v2026.11 crash-guard pattern; the bare-`tonumber` incident is the precedent).
  ```

- [ ] 4. Fold the connected-player smoke requirement into the existing load-smoke note. The note at lines 148-153 already explains `pause_when_empty=true` masks tick code. Strengthen its closing instruction. Change the last sentence (lines 151-153):

  ```
  changes any periodic/tick task, the smoke is not enough — temporarily `pause_when_empty=false`
  (or connect a client) and watch for several task periods, or in-game test with a real player.
  ```

  to:

  ```
  changes any periodic/tick task, the smoke is not enough — the load-smoke MUST be run **with a
  connected player** (or temporarily set `pause_when_empty=false`) and watched for several task
  periods, because the periodic-task body only executes once the sim is unpaused. For a crash-guard
  change specifically, additionally inject a deliberate throw into a guarded callback in modtest and
  confirm it is caught + logged + the shard stays up, then revert the injected throw.
  ```

- [ ] 5. Run the gate (the skill is Markdown, not Lua, but run anyway to confirm nothing else drifted, and to keep the per-commit discipline):

  ```
  luacheck modmain.lua scripts/ spec/ && stylua --check . && luajit spec/run_local.lua
  ```

  Expected: 0/0, clean, `OK`.

- [ ] 6. Commit:

  ```
  git add .claude/skills/dst-mod-crash-audit/SKILL.md && git commit -m "PHUD-CG fold wrap-at-registration + connected-player smoke into dst-mod-crash-audit

  - D5: every server-side scheduler/event-bus callback must be GLOBAL.xpcall-guarded AT registration
  - a (protected) post-init does NOT protect the (naked) closures it installs (scheduler/entityscript/RPC evidence)
  - load-smoke MUST run with a connected player (or pause_when_empty=false); the crash-guard modtest injects a throw to prove catch+log+survive"
  ```

---

## Done criteria

- `luacheck modmain.lua scripts/ spec/` = 0/0; `stylua --check .` clean; `luajit spec/run_local.lua` (and CI `busted spec/`) green — at every commit.
- All three naked server-side dispatch paths (`DoPeriodicTask` body, the 11 `ListenForEvent` hooks, the shard-RPC `upsert`) are wrapped in `guarded()`, which uses only `GLOBAL.`-bound builtins.
- The codec self-checks at require-time; a broken wire-format edit fails LOUDLY inside the engine xpcall.
- A negative `hp_cur`/`hunger`/`sanity_cur` from the wire is clamped to 0, logged once, and the record is KEPT.
- A silently-wedged broadcast task → foreign badges go stale → hidden within `FOREIGN_STALE_SECS`.
- `guarded()`'s decision logic is busted-tested engine-free.
- The `dst-mod-crash-audit` skill carries the wrap-at-registration rule + the connected-player smoke requirement.
- `modinfo.lua` is UNCHANGED (the avatars plan owns the v2026.11 bump).
