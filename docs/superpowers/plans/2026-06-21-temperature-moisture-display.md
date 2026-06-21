# Temperature + Moisture sub-rings & display polish — Implementation Plan (v2026.13)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add on-demand temperature + moisture teammate sub-rings (around the HP ring), a consolidated hover detail panel, and three display-QoL options (compact/detail toggle, hide-HUD toggle, name font size) — shipping the temp/moisture data over new netvars + a backward-tolerant codec v3.

**Architecture:** Server reads each player's owner-only `temperature` + `moisture` and broadcasts them like the existing HP/hunger/sanity netvars; the cross-shard codec bumps v2→v3 (extra fields, v2-tolerant decode). PURE decision logic (`temp_popup` / `moisture_popup`, record normalize, codec, layout) lives in busted-tested `scripts/partyhud_*.lua` modules; the engine-bound widget + modmain read live state and delegate. Spec: `docs/superpowers/specs/2026-06-21-temperature-moisture-display.md`.

**Tech Stack:** Lua 5.1 (DST mod). Pure modules tested with the local busted shim; engine-bound code verified by luacheck + StyLua + an in-engine modtest smoke (no headless DST client for widgets).

## Global Constraints

- Lua 5.1 only — no `goto`, no bitwise ops, no `<const>`; bit work via arithmetic.
- `scripts/*` run in full `_G` (bare globals); `modmain.lua` runs the RESTRICTED sandbox (use `GLOBAL.<fn>` for non-whitelisted globals: `tonumber`, `pcall`, `unpack`, `GetModConfigData`, `TheInput`, `KEY_*`, …). Never `GLOBAL.X` inside `scripts/`.
- Pure modules (`partyhud_status` / `partyhud_statuscodec` / `partyhud_record` / `partyhud_layout`) keep ZERO engine deps — numbers/booleans/strings only.
- **Temperature is a plain `N°`** (no C/F suffix — DST's value is an internal scale, vanilla shows no number). Freeze threshold `< 0`, overheat `> 70` are UNIVERSAL (per dst-scripts) — use fixed constants + a comment that a future char-specific threshold would switch to each player's broadcast `overheattemp`.
- **Keybinds are rebindable config spinners** with a `None` (`data = -1`) option + a registration guard `if key ~= -1 then TheInput:AddKeyDownHandler(key, fn) end`. Collision is non-fatal (all handlers fire), so this is the only mitigation needed.
- Codec stays **backward-tolerant**: a v2 peer's record yields nil for v3 fields → those sub-rings render off.
- Static gates: `luajit spec/run_local.lua` (busted, incl. layout-snapshot), `docker run --rm -v "$PWD":/data -w /data pipelinecomponents/luacheck luacheck .` (0/0), `docker run --rm -v "$PWD":/data --entrypoint /stylua johnnymorganz/stylua --check /data`.
- Work on `master`; commit lowercase + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; push SSH-over-443.
- **Autonomy bound:** Tasks 1–5 + 9 are headless/mechanical (fully verifiable). Tasks 6–8 are engine-bound — implement to luacheck/StyLua-green but their visual/runtime correctness + any tag/ship REQUIRE an in-engine modtest pass with the user. Do NOT claim visual correctness or ship autonomously.

---

### Task 1: Pure popup decisions — `temp_popup` + `moisture_popup`

**Files:**
- Modify: `scripts/partyhud_status.lua` (add after `sanity_ratescale`)
- Test: `spec/status_spec.lua` (add a `describe` block)

**Interfaces:**
- Consumes: nothing (pure leaf functions).
- Produces:
  - `M.temp_popup(current, rate, cold_show, hot_show, rate_fast)` → `show (bool), kind ("cold"|"hot"|nil)`. Shows when `current ≤ cold_show` (kind "cold") OR `current ≥ hot_show` (kind "hot") OR `rate` magnitude ≥ `rate_fast` toward an extreme (cold if rate<0, hot if rate>0). Defaults: `cold_show = M.TEMP_COLD_SHOW (10)`, `hot_show = M.TEMP_HOT_SHOW (60)`, `rate_fast = M.TEMP_RATE_FAST (1)`. nil current → not shown.
  - `M.moisture_popup(moisture)` → `bool` — true iff `(moisture or 0) > 0`.
  - Constants `M.TEMP_COLD_SHOW=10`, `M.TEMP_HOT_SHOW=60`, `M.TEMP_RATE_FAST=1` (provisional, tuned in-engine).

- [ ] **Step 1: Write the failing tests** — add to `spec/status_spec.lua`:

```lua
describe("partyhud_status — temp_popup", function()
  it("comfortable band -> hidden", function()
    local show = M.temp_popup(35, 0)
    assert.is_false(show)
  end)
  it("cold danger band -> shown, kind cold", function()
    local show, kind = M.temp_popup(5, 0)
    assert.is_true(show); assert.are.equal("cold", kind)
  end)
  it("hot danger band -> shown, kind hot", function()
    local show, kind = M.temp_popup(65, 0)
    assert.is_true(show); assert.are.equal("hot", kind)
  end)
  it("fast cooling in the comfortable band -> shown cold", function()
    local show, kind = M.temp_popup(35, -2)
    assert.is_true(show); assert.are.equal("cold", kind)
  end)
  it("fast warming -> shown hot", function()
    local show, kind = M.temp_popup(35, 2)
    assert.is_true(show); assert.are.equal("hot", kind)
  end)
  it("nil current -> hidden", function()
    assert.is_false((M.temp_popup(nil, 0)))
  end)
  it("explicit thresholds override defaults", function()
    assert.is_false((M.temp_popup(20, 0, 10, 60, 1)))
    assert.is_true((M.temp_popup(20, 0, 25, 60, 1)))
  end)
end)

describe("partyhud_status — moisture_popup", function()
  it("dry (0) -> hidden", function() assert.is_false(M.moisture_popup(0)) end)
  it("nil -> hidden", function() assert.is_false(M.moisture_popup(nil)) end)
  it("wet (>0) -> shown", function() assert.is_true(M.moisture_popup(1)) end)
end)
```

- [ ] **Step 2: Run to verify fail** — `luajit spec/run_local.lua` → FAIL (`attempt to call field 'temp_popup'`).

- [ ] **Step 3: Implement** — in `scripts/partyhud_status.lua`, after `sanity_ratescale`:

```lua
-- Temperature danger-band + fast-rate popup. current/rate from the broadcast (rate sign: <0 cooling,
-- >0 warming). Show when at/over a danger threshold OR changing fast toward an extreme.
-- THRESHOLDS ARE FIXED CONSTANTS: per dst-scripts (components/temperature.lua) freeze is hardcoded
-- current<0 and overheat is current>70 (TUNING.OVERHEAT_TEMP), universal across all characters as of
-- 2026-06. If a future DST update makes the threshold character-specific, switch cold_show/hot_show to
-- be derived from each player's broadcast temperature.overheattemp instead of these constants.
M.TEMP_COLD_SHOW = 10
M.TEMP_HOT_SHOW = 60
M.TEMP_RATE_FAST = 1

function M.temp_popup(current, rate, cold_show, hot_show, rate_fast)
  if current == nil then
    return false, nil
  end
  cold_show = cold_show or M.TEMP_COLD_SHOW
  hot_show = hot_show or M.TEMP_HOT_SHOW
  rate_fast = rate_fast or M.TEMP_RATE_FAST
  rate = rate or 0
  if current <= cold_show or (rate <= -rate_fast) then
    return true, "cold"
  elseif current >= hot_show or (rate >= rate_fast) then
    return true, "hot"
  end
  return false, nil
end

-- Moisture popup: show the moisture sub-ring only when the teammate is wet at all (mirrors vanilla
-- moisturemeter, which hides at moisture 0). nil -> dry.
function M.moisture_popup(moisture)
  return (moisture or 0) > 0
end
```

- [ ] **Step 4: Run to verify pass** — `luajit spec/run_local.lua` → all green (`N passed, 0 failed`).

- [ ] **Step 5: luacheck + stylua + commit**

```bash
docker run --rm -v "$PWD":/data -w /data pipelinecomponents/luacheck luacheck scripts/partyhud_status.lua spec/status_spec.lua
docker run --rm -v "$PWD":/data --entrypoint /stylua johnnymorganz/stylua --check /data
git add scripts/partyhud_status.lua spec/status_spec.lua
git commit -m "status: add temp_popup + moisture_popup decision logic

Pure danger-band + fast-rate popup for the temperature sub-ring (fixed
constants per dst-scripts universal thresholds) and a moisture>0 popup, both
busted-tested.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Codec v3 — temperature + moisture fields (backward-tolerant)

**Files:**
- Modify: `scripts/partyhud_statuscodec.lua` (bump v2→v3: `PROTOCOL_VERSION`, the per-version field count, the `NUMERIC` field-name list, `SUPPORTED`, the require-time self-check)
- Test: `spec/statuscodec_spec.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: codec records now carry `temp`, `temp_rate`, `moisture`, `moisture_rate` (4 new numeric fields, appended after `origin`). `M.PROTOCOL_VERSION = 3`. `M.encode(records, version)` emits v3 field count when version=3; `M.decode` is version-aware: a v3 payload parses the 4 new fields, a v2/v1 payload leaves them nil. The new fields are non-negative small ints (temp is the +20-offset byte 0..110; rates are 0..2 buckets; moisture 0..100).

- [ ] **Step 1: Write the failing tests** — add to `spec/statuscodec_spec.lua`:

```lua
describe("partyhud_statuscodec — v3 temp/moisture", function()
  local rec = {
    userid = "KU_v3", hp_cur = 90, hp_max = 150, hp_penalty = 0,
    hunger = 80, hunger_max = 150, sanity = 70, sanity_max = 200,
    sanity_penalty = 0, flags = 0, origin = 1,
    temp = 75, temp_rate = 1, moisture = 42, moisture_rate = 0,
  }
  it("v3 round-trips temp + moisture fields", function()
    local out, ver = M.decode(M.encode({ rec }, 3))
    assert.are.equal(3, ver)
    assert.are.equal(75, out[1].temp)
    assert.are.equal(1, out[1].temp_rate)
    assert.are.equal(42, out[1].moisture)
    assert.are.equal(0, out[1].moisture_rate)
  end)
  it("a v2 payload decodes with nil temp/moisture (backward tolerant)", function()
    local out, ver = M.decode(M.encode({ rec }, 2))
    assert.are.equal(2, ver)
    assert.is_nil(out[1].temp)
    assert.is_nil(out[1].moisture)
    assert.are.equal(1, out[1].origin) -- v2 fields still intact
  end)
  it("PROTOCOL_VERSION is 3", function()
    assert.are.equal(3, M.PROTOCOL_VERSION)
  end)
end)
```

- [ ] **Step 2: Run to verify fail** — `luajit spec/run_local.lua` → FAIL (decoded `temp` is nil under v3 / version ≠ 3).

- [ ] **Step 3: Implement** — read the current `scripts/partyhud_statuscodec.lua`. Apply the v2→v3 extension following the EXACT pattern v1→v2 used for `origin`:
  - `M.PROTOCOL_VERSION = 3`.
  - Add `3` to the `SUPPORTED` set.
  - In `M.encode`: when `version >= 3`, append the four fields after `origin`, each `math.floor((r.<field> or 0) + 0.5)`, in the order `temp, temp_rate, moisture, moisture_rate`.
  - In `M.decode`: extend the version-aware `NUMERIC` list — when the payload's version is 3, append `"temp", "temp_rate", "moisture", "moisture_rate"` after `"origin"` (a v2 payload omits them → nil keys, exactly like v1 omits origin).
  - Update the require-time self-check record + assertions to include `temp = 75` (assert `out[1].temp == 75` round-trips under the default version).
  - Keep the decode numeric clamps tolerant of the new fields.

- [ ] **Step 4: Run to verify pass** — `luajit spec/run_local.lua` → green (the v3 + v2-tolerant tests pass, self-check passes at require time).

- [ ] **Step 5: luacheck + stylua + commit** (`scripts/partyhud_statuscodec.lua spec/statuscodec_spec.lua`; message `statuscodec: bump to v3 with temp + moisture fields (v2-tolerant)`).

---

### Task 3: Record normalize — carry temp + moisture

**Files:**
- Modify: `scripts/partyhud_record.lua` (`normalize_local` + `normalize_foreign`)
- Test: `spec/record_spec.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `normalize_local(raw)` + `normalize_foreign(rec, flags)` outputs now include `temp` (number or nil), `temp_rate` (−1/0/1 or 0), `moisture` (0..100), `moisture_rate` (−1/0/1 or 0). Far players keep the existing live-thermal-flag neutralisation (fire/overheat/freeze forced false) but DO carry `temp`/`moisture` values from the broadcast (a far teammate's temp/moisture is still useful).

- [ ] **Step 1: Write the failing tests** — add to `spec/record_spec.lua`:

```lua
describe("partyhud_record — temp/moisture passthrough", function()
  it("normalize_local carries temp + moisture", function()
    local n = M.normalize_local({ hpcur = 50, maxhp = 100, temp = 12, temp_rate = -1, moisture = 30, moisture_rate = 1 })
    assert.are.equal(12, n.temp)
    assert.are.equal(-1, n.temp_rate)
    assert.are.equal(30, n.moisture)
    assert.are.equal(1, n.moisture_rate)
  end)
  it("normalize_foreign carries temp + moisture but forces thermal flags off", function()
    local n = M.normalize_foreign({ hp_cur = 50, hp_max = 100, temp = 72, moisture = 80 }, { dead = false })
    assert.are.equal(72, n.temp)
    assert.are.equal(80, n.moisture)
    assert.is_false(n.onfire); assert.is_false(n.overheating); assert.is_false(n.freezing)
  end)
end)
```

- [ ] **Step 2: Run to verify fail** — `luajit spec/run_local.lua` → FAIL (`n.temp` nil).

- [ ] **Step 3: Implement** — read `scripts/partyhud_record.lua`; add `temp = raw.temp`, `temp_rate = raw.temp_rate or 0`, `moisture = raw.moisture or 0`, `moisture_rate = raw.moisture_rate or 0` to the `normalize_local` return table, and `temp = rec.temp`, `temp_rate = rec.temp_rate or 0`, `moisture = rec.moisture or 0`, `moisture_rate = rec.moisture_rate or 0` to `normalize_foreign` (leaving the existing forced-false thermal flags untouched). `temp` stays nil-tolerant (a v2 record has no temp → sub-ring stays off).

- [ ] **Step 4: Run to verify pass** — `luajit spec/run_local.lua` → green.

- [ ] **Step 5: luacheck + stylua + commit** (message `record: carry temp + moisture through normalize_local/foreign`).

---

### Task 4: Layout — `name_size` grows the vertical step

**Files:**
- Modify: `scripts/partyhud_layout.lua` (`compute_badge_positions` + a name-size→extra-gap helper)
- Test: `spec/layout_spec.lua` + re-bless `spec/snapshots/*.json`

**Interfaces:**
- Consumes: nothing.
- Produces: `M.NAME_GAP = { small = 0, medium = 6, large = 14 }` (extra vertical px per badge by name size; provisional, tuned in-engine). `compute_badge_positions(opts)` reads `opts.name_size` (`"small"|"medium"|"large"`, default `"medium"`) and, in the VERTICAL layout only, adds `M.NAME_GAP[name_size]` to the per-badge vertical step so larger names don't overlap. Horizontal layout is unchanged.

- [ ] **Step 1: Write the failing test** — add to `spec/layout_spec.lua`:

```lua
describe("partyhud_layout — name_size vertical gap", function()
  local base = { layout = 2, count = 4, position = 2 } -- vertical (adapt keys to compute_badge_positions' opts)
  it("large name spaces vertical badges further apart than small", function()
    local function ys(sz)
      local o = {}
      for k, v in pairs(base) do o[k] = v end
      o.name_size = sz
      local pos = M.compute_badge_positions(o)
      return pos
    end
    local small = ys("small")
    local large = ys("large")
    -- the vertical gap between consecutive badges in a column must be larger for "large"
    local function col_gap(pos)
      -- find two badges in the same column and return |y diff|
      for i = 1, #pos do
        for j = i + 1, #pos do
          if pos[i].col == pos[j].col and math.abs(pos[i].row - pos[j].row) == 1 then
            return math.abs(pos[i].y - pos[j].y)
          end
        end
      end
    end
    assert.is_true(col_gap(large) > col_gap(small))
  end)
  it("name_size defaults to medium and horizontal layout is unaffected", function()
    local h = { layout = 1, count = 4, position = 2 } -- horizontal
    local a = M.compute_badge_positions(h)
    h.name_size = "large"; local b = M.compute_badge_positions(h)
    assert.are.same(a, b)
  end)
end)
```

> NOTE to implementer: adapt the `opts` keys (`layout`/`count`/`position`/…) to the ACTUAL `compute_badge_positions` signature in `scripts/partyhud_layout.lua` (read it first); the assertions (larger vertical gap for "large"; horizontal identical) are the contract.

- [ ] **Step 2: Run to verify fail** — `luajit spec/run_local.lua` → FAIL.

- [ ] **Step 3: Implement** — add `M.NAME_GAP` + read `opts.name_size` (default `"medium"`) in `compute_badge_positions`; in the vertical branch add `M.NAME_GAP[name_size] or 0` to the per-badge vertical step/pitch. Horizontal branch untouched. Comment why (larger names need more room above each badge in a column).

- [ ] **Step 4: Run + re-bless snapshots** — `luajit spec/run_local.lua`. The 14 layout-snapshot goldens use the default name_size (medium) → they should be UNCHANGED if medium's gap is 0... if `NAME_GAP.medium = 6` shifts the default, the goldens move: **review the diff, then re-bless** `UPDATE_SNAPSHOTS=1 luajit spec/run_local.lua` and EYEBALL the regenerated `spec/snapshots/*.json`. (Keep `NAME_GAP.medium = 0` if you want the existing goldens to stay put and only large/small to differ — decide from the in-engine tuning; default medium=0 is the lower-churn choice. Provisional.)

- [ ] **Step 5: luacheck + stylua + commit** (include the re-blessed snapshots if changed; message `layout: name_size grows the vertical per-badge step (horizontal unaffected)`).

---

### Task 5: modinfo — five new config options

**Files:**
- Modify: `modinfo.lua` (`configuration_options`)

**Interfaces:**
- Produces: `show_temperature` (data 1=On-demand / 0=Off, default 1), `show_moisture` (same, default 1), `name_size` (data "small"/"medium"/"large", default "medium"), `key_compact` (KEY_* spinner + None=-1, default `KEY_O`), `key_hide_hud` (KEY spinner + None=-1, default `KEY_H`). Modmain reads them via `GetModConfigData(<name>)`.

- [ ] **Step 1: Add the options** — append to `modinfo.lua`'s `configuration_options`. KEY constants: in modinfo, the engine exposes `KEY_*` globals (e.g. `KEY_O`, `KEY_H`, …). Provide a short free-key spinner (researched-free: O, P, N, B, K, L) + `{ description = "None", data = -1 }`:

```lua
  {
    name = "show_temperature",
    label = "Teammate Temperature",
    hover = "Show a temperature sub-ring on a teammate's badge when they get dangerously cold or hot (or are heating/cooling fast). Off hides it.",
    options = { { description = "On-demand", data = 1 }, { description = "Off", data = 0 } },
    default = 1, client = true,
  },
  {
    name = "show_moisture",
    label = "Teammate Moisture",
    hover = "Show a moisture (wetness) sub-ring on a teammate's badge while they are wet. Off hides it.",
    options = { { description = "On-demand", data = 1 }, { description = "Off", data = 0 } },
    default = 1, client = true,
  },
  {
    name = "name_size",
    label = "Teammate Name Size",
    hover = "Font size of teammate names. Larger sizes add vertical spacing in the Vertical layout.",
    options = { { description = "Small", data = "small" }, { description = "Medium", data = "medium" }, { description = "Large", data = "large" } },
    default = "medium", client = true,
  },
  {
    name = "key_compact",
    label = "Compact/Detail toggle key",
    hover = "Key to flip all teammate badges between compact (HP ring + name) and full detail. None disables it.",
    options = { { description = "None", data = -1 }, { description = "O", data = KEY_O }, { description = "P", data = KEY_P }, { description = "N", data = KEY_N }, { description = "B", data = KEY_B }, { description = "K", data = KEY_K }, { description = "L", data = KEY_L } },
    default = KEY_O, client = true,
  },
  {
    name = "key_hide_hud",
    label = "Hide PartyHUD key",
    hover = "Key to hide/show the whole party HUD. None disables it.",
    options = { { description = "None", data = -1 }, { description = "H", data = KEY_H }, { description = "P", data = KEY_P }, { description = "N", data = KEY_N }, { description = "B", data = KEY_B }, { description = "K", data = KEY_K }, { description = "L", data = KEY_L } },
    default = KEY_H, client = true,
  },
```

- [ ] **Step 2: Verify** — `luacheck modinfo.lua` (0/0). modinfo isn't busted-tested; confirm Lua parses (`luajit -e 'assert(loadfile("modinfo.lua"))'`). NOTE: `KEY_*` are engine globals available in the modinfo eval context; luacheck may flag them — add to `.luacheckrc` `read_globals` if needed (mirror how existing modinfo globals are handled).

- [ ] **Step 3: Commit** (message `modinfo: temperature/moisture/name-size options + compact/hide-HUD keybinds`).

---

### Task 6: modmain — broadcast temp/moisture + wire keybinds (ENGINE-BOUND)

**Files:**
- Modify: `modmain.lua` (the per-tick broadcast/netvar block; `attach_carrier`/codec call sites; the `customhpbadge*` netvar set; a new keybind-registration block; config reads)

**Interfaces:**
- Consumes: `record.normalize_*` (temp/moisture fields), `codec.encode/decode` (v3), `status.temp_popup`/`moisture_popup` (the widget uses these — modmain just broadcasts raw values), the modinfo config names.
- Produces: per-player netvars carrying temperature (`+20` offset byte) + temp-rate (tinybyte 0/1/2 = steady/warming/cooling) + moisture (byte) + moisture-rate (tinybyte); passes these into the cross-shard blob via codec v3; passes temp/moisture + the config to the widgets via the existing `SetStatus`/a new setter; registers the two keybinds.

- [ ] **Step 1** — Read modmain's existing status-broadcast (`customhpbadge*` netvar declarations + the periodic task that sets them + the `attach_carrier` codec usage). Add, following the exact existing pattern:
  - New netvars on the player (`net_byte` for temp with `+20` offset on set / `-20` on read; `net_byte` moisture; `net_tinybyte` temp_rate + moisture_rate) declared alongside the current `customhpbadge*` ones.
  - Read `inst.components.temperature` (GetCurrent / rate) + the player's moisture (the broadcast runs server-side on the master sim, where the component is readable) in the periodic broadcast task; `math.floor` + clamp to the netvar range; set the netvars. Derive temp_rate / moisture_rate sign → 0/1/2 bucket.
  - Feed temp/moisture/rates into the cross-shard record (so codec v3 carries them) at the same place the other stats are gathered.
  - In `UpdateBadges`, pass temp/moisture (+ rates) to the badge widget (extend the `SetStatus` call or add `b:SetThermal(temp, temp_rate, moisture, moisture_rate)`) for BOTH local and foreign branches, plus the `show_temperature`/`show_moisture`/`name_size` config (read once via `GetModConfigData`).
- [ ] **Step 2** — Keybinds: read `key_compact` / `key_hide_hud` via `GLOBAL.GetModConfigData`; register guarded:

```lua
-- luacheck: push ignore 122
local function register_partyhud_keys()
  local kc = GLOBAL.GetModConfigData("key_compact")
  if kc ~= nil and kc ~= -1 then
    GLOBAL.TheInput:AddKeyDownHandler(kc, function() PartyHud_ToggleCompact() end)
  end
  local kh = GLOBAL.GetModConfigData("key_hide_hud")
  if kh ~= nil and kh ~= -1 then
    GLOBAL.TheInput:AddKeyDownHandler(kh, function() PartyHud_ToggleHidden() end)
  end
end
-- luacheck: pop
```
  where `PartyHud_ToggleCompact` / `PartyHud_ToggleHidden` flip a flag on the status widget + re-layout/hide (client-only; guard `ThePlayer`/HUD nil). Register on player-postinit (client only, like the existing client-side listeners; guard `TheNet:IsDedicated()`).
- [ ] **Step 3** — `luacheck modmain.lua` (0/0) + `stylua --check`. **No busted** (engine-bound). Confirm `luajit spec/run_local.lua` still green (pure suite unaffected).
- [ ] **Step 4: Commit** (message `modmain: broadcast temp + moisture (codec v3) + compact/hide-HUD keybinds`). **In-engine verification deferred to the user (Task 10).**

---

### Task 7: Widget — temperature + moisture sub-rings (ENGINE-BOUND)

**Files:**
- Modify: `scripts/widgets/partybadge.lua` (two new sub-ring children + on-demand show/hide + visuals; new geometry constants)

**Interfaces:**
- Consumes: `status.temp_popup` / `status.moisture_popup`; the temp/moisture/rate values from modmain (Task 6's setter); `statusmath`/`avatarmath` patterns already in the file.
- Produces: `PartyBadge:SetThermal(temp, temp_rate, moisture, moisture_rate)` (or fold into `SetStatus`) that shows/hides + drives the two sub-rings.

- [ ] **Step 1** — Add two sub-ring children mirroring the existing hunger/sanity sub-rings (`Badge(nil, owner, TINT, build, …)` at `SUB_SCALE`):
  - **Moisture** (top-LEFT, hugging the HP ring, just up-and-left of hunger): reuse the vanilla moisturemeter look — `OverrideSymbol("icon", "status_wet", "icon")` for the water drop, blue tint `{48/255, 97/255, 169/255, 1}`. Position `(-SUB_X, +SUB_Y_TOP)` tuned in-engine.
  - **Temperature** (top-RIGHT, up-and-right of sanity): `temperature_meter` build for the icon, `SetMultColour` cyan `{0.4,0.8,1,1}` when kind="cold" / red-orange `{1,0.4,0.1,1}` when kind="hot". Position `(+SUB_X, +SUB_Y_TOP)`.
  - New constants `SUB_Y_TOP` (+ optional separate X) — provisional, tuned in-engine; keep tucked against the HP ring (clustered), clearing the name label + corner avatar.
- [ ] **Step 2** — On-demand show/hide: in the setter, call `status.moisture_popup(moisture)` and `status.temp_popup(temp, temp_rate)`; show the ring + drive its rate arrow (the `sanity_arrow` build, anims `arrow_loop_increase[_more/_most]` / `_decrease[...]` / `neutral`, gated by the rate bucket) when true, else hide. Respect the `show_temperature`/`show_moisture` config (Off → never show). Lazy-create the children (an Off/unused badge pays nothing).
- [ ] **Step 3** — `luacheck` + `stylua --check` (0/0). Confirm `luajit spec/run_local.lua` still green (layout-snapshot unaffected — these are intra-badge). **No busted for the widget.**
- [ ] **Step 4: Commit** (message `partybadge: temperature + moisture on-demand sub-rings around the HP ring`). **In-engine deferred (Task 10).**

---

### Task 8: Widget — hover detail panel + compact/detail + name size (ENGINE-BOUND)

**Files:**
- Modify: `scripts/widgets/partybadge.lua`

**Interfaces:**
- Consumes: all current badge stats + temp/moisture; `name_size` config; the `PartyHud_ToggleCompact`/`PartyHud_ToggleHidden` flags from modmain.
- Produces: `PartyBadge:SetCompact(bool)` (hide sub-rings + numbers + avatar when compact, restore when detail), `PartyBadge:SetNameSize(size)` (apply the font size to `self.name` + the foreign label), and a hover detail-panel child shown on focus.

- [ ] **Step 1** — Hover detail panel: a `Text`/panel child shown on the badge's focus (reuse the existing focus handler), listing HP `cur/max` (+penalty), hunger, sanity (+rate), `temp°`, `moisture%`, and active fire/overheat/freeze flags. Built from the cached stat values the badge already holds.
- [ ] **Step 2** — `SetCompact(b)`: when compact, hide the hunger/sanity/temp/moisture sub-rings + the HP number + avatar, keep the main ring + name; when detail, restore per the static config. `SetNameSize(size)`: `self.name:SetSize(M.NAME_PX[size])` (e.g. small 16 / medium 20 / large 26) + same on the foreign label.
- [ ] **Step 3** — `luacheck` + `stylua --check` (0/0); pure suite still green.
- [ ] **Step 4: Commit** (message `partybadge: hover detail panel + compact/detail + name-size`). **In-engine deferred (Task 10).**

---

### Task 9: Dogfood — update the dst-game-update-compat dependency surface

**Files:**
- Modify: `.claude/skills/dst-game-update-compat/references/dependency-surface.md`

- [ ] **Step 1** — Add rows for the NEW dependencies this release introduced, each with the `Symbol | Used in | We assume | Ground truth (dst-scripts) | Break risk & symptom | Verify after a DST update` columns (match the file's format):
  - `components.temperature:GetCurrent()` / `.rate` / `.overheattemp`; `IsFreezing` (`current<0`) / `IsOverheating` (`current>overheattemp`) — ground truth `components/temperature.lua` (freeze hardcoded `<0`, overheat `>overheattemp` default `TUNING.OVERHEAT_TEMP=70`).
  - the moisture source (`player_classified.moisture` / the moisture replica) + the `moisturedelta` event.
  - `TUNING.OVERHEAT_TEMP` / `MIN_ENTITY_TEMP` / `MAX_ENTITY_TEMP` (tuning.lua).
  - `TheInput:AddKeyDownHandler` + `KEY_*` constants + `GetModConfigData` (the keybinds); ground truth `input.lua` (handlers are a set, all fire — collision non-fatal).
  - the `status_wet` / `temperature_meter` / `sanity_arrow` builds + `OverrideSymbol`/`SetPercent`/`SetMultColour` widget methods used by the new sub-rings.
- [ ] **Step 2: Commit** (message `compat surface: add v2026.13 temperature/moisture/keybind deps`).

---

### Task 10: In-engine verification — USER-DRIVEN (do NOT do autonomously)

This task is the gate the autonomous run must STOP at. Surface to the user the exact checks (from the spec §7): beta-upload + modtest 2-player/2-shard — temp sub-ring danger band (`dst-thermal cold`/`hot`) + cold=cyan/hot=red; moisture sub-ring on rain; hover panel; compact (`O`)/hide (`H`) keybinds + rebind via config; `name_size` vertical spacing (eyeball no overlap, tune `NAME_GAP`); cross-shard temp/moisture (codec v3) + a v2-peer graceful degrade; the sub-ring offset + `SUB_Y_TOP` tuning; crash-audit + visual-audit of the diff. Then preflight (incl. gate 4 dst-game-update-compat) → tag v2026.13 → ship. **Requires the user.**

---

## Self-Review

**Spec coverage:** data layer (netvars+codec v3) → Tasks 2/3/6 ✓; temp+moisture sub-rings + visuals → Tasks 1/7 ✓; hover panel → Task 8 ✓; compact/hide keybinds (rebindable + None guard) → Tasks 5/6/8 ✓; name size + vertical layout → Tasks 4/5/8 ✓; char-threshold constants+comment → Task 1 ✓; dogfood surface → Task 9 ✓; in-engine + ship → Task 10 (user) ✓; plain `°` unit → Tasks 1/8 (display) ✓.

**Placeholder scan:** the only "tuned in-engine" values (popup thresholds, NAME_GAP, SUB_Y_TOP, NAME_PX) are deliberate in-engine tuning constants with shipped provisional defaults (same pattern as v2026.11/12) — not gaps. Task 4's test adapts opts keys to the real signature (flagged). No TBD/TODO.

**Type consistency:** `temp_popup(current,rate,...) -> show,kind`; `moisture_popup(moisture) -> bool`; record/codec field names `temp / temp_rate / moisture / moisture_rate` consistent across Tasks 2/3/6/7; config names `show_temperature/show_moisture/name_size/key_compact/key_hide_hud` consistent across Tasks 5/6/8; `name_size` values `small/medium/large` consistent (Tasks 4/5/8).
