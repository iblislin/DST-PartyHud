# Low-HP Border Alert (v2026.9) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Blink a red ring border on a teammate's PartyHud badge when their HP drops below a per-player threshold (`Off / 40% / 25% / 15%` of max HP), for local, far, and cross-shard badges alike.

**Architecture:** Pure client-side. The blink lives on the badge's `circleframe` (ring border) — a separate element from the thermal warning pulse (`self.warning`), so a low-HP-and-on-fire teammate shows both. A single `_apply_frame_colour` method is the *only* writer of the border colour, reconciling the low-HP blink with the existing foreign-dim so they never desync. A 0.6 s `DoPeriodicTask` toggles the blink phase. Config flows from a `modinfo` dropdown → `modmain` reads it (`get_local_config`) → sets each badge's `low_hp_threshold`.

**Tech Stack:** DST mod (Lua 5.1 / LuaJIT). Widgets: `widgets/badge.lua` (base). Spec: `docs/superpowers/specs/2026-06-18-low-hp-flash-design.md`.

**Testing reality:** DST widget code needs the game engine, so there are **no busted unit tests** for this (the existing `spec/` suite covers only the pure-Lua codec/store and is unaffected). The per-task gate is **`luajit -e "assert(loadfile(...))"` (parse) + luacheck `0/0`**; behaviour is verified **in-game on `dst-modtest`** (Task 6) and via the two in-repo review skills (Task 5).

**Git reality:** The working copy `/home/iblis/code/dst/partyhud-src` is a real clone but **cannot push** (HTTPS, no token). Subagents **edit + parse-check + commit locally** per task. The controller pushes via the hub fork `~/partyhud-fork` (SSH key authorized) at Task 4 (gate) and Task 7 (ship), then realigns local with `git fetch && git reset --hard origin/master`. ⚠️ No apostrophes in any `-m`/commit-message-file text that goes through an ssh single-quote.

**Run all `luajit`/`luacheck`-local commands from** `/home/iblis/code/dst/partyhud-src`.

---

### Task 1: Add the `low_hp_alert` config option

**Files:**
- Modify: `modinfo.lua` (insert a new entry at the end of `configuration_options`, after the `debug_showall` block)

- [ ] **Step 1: Add the dropdown option**

In `modinfo.lua`, the `configuration_options` table currently ends with the `debug_showall` block followed by the closing `}`. Insert a new block immediately after the `debug_showall` block's closing `},` (and before the table's final `}`):

```lua
		{
		name="low_hp_alert",
		label="Low-HP Alert",
		hover="Blink a red border on a teammate's badge when their HP drops below this level (percent of their max HP). Off disables it.",
		options={
				{description = "Off", data = 0},
				{description = "40%", data = 40},
				{description = "25%", data = 25},
				{description = "15%", data = 15}
			},
		default=25,
		client = true,
		},
```

- [ ] **Step 2: Parse-check**

Run: `luajit -e "assert(loadfile('modinfo.lua'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify the option is well-formed**

Run: `luajit -e "local ok,t=pcall(dofile,'modinfo.lua')" 2>/dev/null; grep -c 'low_hp_alert' modinfo.lua`
Expected: `1` (the option name appears once). Also eyeball that `default=25` and the four `data` values are `0/40/25/15`.

- [ ] **Step 4: Commit (local)**

```bash
git add modinfo.lua
git commit -m "v2026.9 add low_hp_alert client config option (Off/40/25/15)"
```

---

### Task 2: Implement the blink mechanism in `partybadge.lua`

**Files:**
- Modify: `scripts/widgets/partybadge.lua` (constants, `_ctor` state, two new methods, `SetPercent`, `SetForeign`, `ShowDead`, `HideBadge`)

This is one coherent edit to one file. Do all sub-steps, then parse-check once, then commit.

- [ ] **Step 1: Add constants**

Find:
```lua
local FOREIGN_ALPHA = 0.45
local FULL_ALPHA    = 1
```
Replace with:
```lua
local FOREIGN_ALPHA = 0.45
local FULL_ALPHA    = 1

-- v2026.9 low-HP alert: a blinking red ring border (circleframe) when a teammate's HP drops
-- below a player-chosen threshold. Distinct from the thermal warning pulse (self.warning) so both
-- cues can show at once. LOW_HP_TINT is brighter than the HP fill {174,21,21}/255 so it pops
-- against the red ring underneath.
local LOW_HP_TINT         = { 1, 0.15, 0.15 }
local LOW_HP_BLINK_PERIOD = 0.6 -- seconds per toggle (1.2s full on/off cycle)
```

- [ ] **Step 2: Add `_ctor` state**

Find (end of the constructor):
```lua
    -- v2026.8 cross-shard "elsewhere" treatment state. self.foreign tracks whether this slot is
    -- currently showing a far (other-shard) player; the label Text is created lazily by SetForeign.
    self.foreign = false
    self.foreignlabel = nil
end)
```
Replace with:
```lua
    -- v2026.8 cross-shard "elsewhere" treatment state. self.foreign tracks whether this slot is
    -- currently showing a far (other-shard) player; the label Text is created lazily by SetForeign.
    self.foreign = false
    self.foreignlabel = nil

    -- v2026.9 low-HP alert state. low_hp_threshold (0..1, 0 = disabled) is set after construct from
    -- the low_hp_alert config; the rest are driven by _set_low_hp / the blink task.
    self.low_hp_threshold = 0
    self.low_hp = false
    self._blink_on = false
    self._blink_task = nil
end)
```

- [ ] **Step 3: Add the two methods (single-writer + blink lifecycle)**

Find the start of the SetForeign documentation block:
```lua
-- v2026.8 cross-shard: give this badge the "this teammate is elsewhere / data is ~1s stale" look.
```
Insert the following two methods immediately ABOVE that comment line:
```lua
-- v2026.9: single source of truth for the ring-border (circleframe) colour. Both the low-HP blink
-- and the foreign-dim want to write circleframe; routing every write through here keeps them from
-- desyncing (same idea as the v2026.8 "one cache-syncing relayout fn" fix).
function PartyBadge:_apply_frame_colour()
    if self.circleframe == nil then return end
    if self.low_hp and self._blink_on then
        -- alarm phase: red at FULL alpha so the alert stays visible even on a dimmed far badge.
        self.circleframe:GetAnimState():SetMultColour(LOW_HP_TINT[1], LOW_HP_TINT[2], LOW_HP_TINT[3], 1)
    else
        -- rest phase / not low: baseline white border at the badge's current alpha (dim if foreign).
        local a = self.foreign and FOREIGN_ALPHA or FULL_ALPHA
        self.circleframe:GetAnimState():SetMultColour(1, 1, 1, a)
    end
end

-- v2026.9: enter/leave the low-HP blinking state. Idempotent. The 0.6s toggle task is parked on
-- self.inst (the widget entity) so Widget:Kill tears it down; we also cancel it explicitly here.
function PartyBadge:_set_low_hp(islow)
    islow = islow and true or false
    if islow == self.low_hp then return end
    self.low_hp = islow
    if islow then
        self._blink_on = true -- go red immediately, then toggle
        if self._blink_task == nil and self.inst ~= nil then
            self._blink_task = self.inst:DoPeriodicTask(LOW_HP_BLINK_PERIOD, function()
                self._blink_on = not self._blink_on
                self:_apply_frame_colour()
            end)
        end
    else
        if self._blink_task ~= nil then
            self._blink_task:Cancel()
            self._blink_task = nil
        end
        self._blink_on = false
    end
    self:_apply_frame_colour()
end
```

- [ ] **Step 4: Hook the threshold check into `SetPercent`**

Find:
```lua
    if self.num ~= nil then
        self.num:SetString(tostring(math.floor((cur or 0) + 0.5)))
        if self.hp_number_always then self.num:Show() end
    end
end
```
Replace with:
```lua
    if self.num ~= nil then
        self.num:SetString(tostring(math.floor((cur or 0) + 0.5)))
        if self.hp_number_always then self.num:Show() end
    end
    -- v2026.9 low-HP alert: blink the border below the configured threshold (fraction of max HP).
    -- 0 threshold = disabled. Runs for BOTH the local and the foreign path (the foreign render also
    -- calls SetPercent with the relayed hp_cur/hp_max), so far/cross-shard badges blink for free.
    self:_set_low_hp(self.low_hp_threshold > 0 and (cur / m) < self.low_hp_threshold)
end
```
(Note: `m` is the guarded max from the top of `SetPercent`: `local m = (max ~= nil and max > 0) and max or 1`. `cur` is always a number here — the existing `Badge.SetPercent(self, cur / m, max)` line above already assumes it.)

- [ ] **Step 5: Reroute the `circleframe` write in `SetForeign` through the helper**

Find:
```lua
    set_anim_alpha(self.backing, a)     -- dark background ring (untinted)
    set_anim_alpha(self.circleframe, a) -- frame draws untinted (white)
```
Replace with:
```lua
    set_anim_alpha(self.backing, a)     -- dark background ring (untinted)
    -- circleframe (the ring border) is owned by _apply_frame_colour: it reconciles the foreign dim
    -- (self.foreign, set above) with the low-HP blink, so a foreign<->local flip can't strand a
    -- stale border tint. (Replaces the direct set_anim_alpha(self.circleframe, a) call.)
    self:_apply_frame_colour()
```
(`self.foreign` is set at the top of `SetForeign` before this point, so `_apply_frame_colour` reads the correct value.)

- [ ] **Step 6: Stop the blink in `ShowDead`**

Find:
```lua
function PartyBadge:ShowDead()
    self:Show()
```
Replace with:
```lua
function PartyBadge:ShowDead()
    self:Show()
    self:_set_low_hp(false) -- a dead/ghost teammate shows the skull, not a low-HP blink; stop it
                            -- (SetPercent ran before ShowDead and may have started the blink at hp 0)
```

- [ ] **Step 7: Stop the blink in `HideBadge`**

Find:
```lua
function PartyBadge:HideBadge()
    self:Hide()
end
```
Replace with:
```lua
function PartyBadge:HideBadge()
    self:_set_low_hp(false) -- stop any blink task before hiding a departed / empty slot
    self:Hide()
end
```

- [ ] **Step 8: Parse-check**

Run: `luajit -e "assert(loadfile('scripts/widgets/partybadge.lua'))" && echo OK`
Expected: `OK` (a syntax error here means a mis-pasted block — fix and re-run).

- [ ] **Step 9: Commit (local)**

```bash
git add scripts/widgets/partybadge.lua
git commit -m "v2026.9 low-HP blinking border on partybadge (circleframe channel)"
```

---

### Task 3: Wire the config into `modmain.lua`

**Files:**
- Modify: `modmain.lua` (one config read near line 54; one per-badge assignment in the construct loop near line 310)

- [ ] **Step 1: Read the config**

Find:
```lua
local DEBUG_SHOWALL = (GetModConfigData("debug_showall", true) == 1) -- [TEST] client option: mock-fill empty slots to preview layout (only this client sees it)
```
Add immediately after it:
```lua
local low_hp_threshold = (GetModConfigData("low_hp_alert", true) or 0) / 100 -- v2026.9: 0 = disabled; fraction of max HP
```

- [ ] **Step 2: Apply the threshold to each badge at construct**

Find:
```lua
		self.badgearray[i]:SetSubGauges(show_substatus) -- apply the sub-gauge config at construct time
		self.badgearray[i]:SetHPNumberAlways(hp_number_always)
	end
```
Replace with:
```lua
		self.badgearray[i]:SetSubGauges(show_substatus) -- apply the sub-gauge config at construct time
		self.badgearray[i]:SetHPNumberAlways(hp_number_always)
		self.badgearray[i].low_hp_threshold = low_hp_threshold -- v2026.9 low-HP alert threshold
	end
```

- [ ] **Step 3: Parse-check**

Run: `luajit -e "assert(loadfile('modmain.lua'))" && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit (local)**

```bash
git add modmain.lua
git commit -m "v2026.9 wire low_hp_alert config to per-badge threshold"
```

---

### Task 4: Full local gate + luacheck on hub (controller)

**Files:** none (verification only)

- [ ] **Step 1: Parse all touched files + confirm busted still green**

Run:
```bash
for f in modmain.lua scripts/widgets/partybadge.lua modinfo.lua; do luajit -e "assert(loadfile('$f'))" && echo "parse OK: $f"; done
luajit spec/run_local.lua 2>&1 | tail -1
```
Expected: three `parse OK` lines + `51 passed, 0 failed` (the codec/store specs are unaffected by this client-only change).

- [ ] **Step 2: Sync the three changed files to the hub fork**

Run:
```bash
scp modmain.lua hub.iottalk.tw:~/partyhud-fork/modmain.lua
scp scripts/widgets/partybadge.lua hub.iottalk.tw:~/partyhud-fork/scripts/widgets/partybadge.lua
scp modinfo.lua hub.iottalk.tw:~/partyhud-fork/modinfo.lua
```

- [ ] **Step 3: luacheck on hub (must be 0/0)**

Run:
```bash
ssh hub.iottalk.tw 'cd ~/partyhud-fork && docker run --rm -v "$PWD":/code pipelinecomponents/luacheck luacheck . 2>&1 | tail -1'
```
Expected: `Total: 0 warnings / 0 errors in 8 files`. (If luacheck flags an unused local / global, fix it in the local file, re-scp, re-run.)

---

### Task 5: Code review via the two in-repo skills (controller dispatches)

**Files:** none (review only; fixes loop back into Tasks 2/3)

- [ ] **Step 1: Visual-parity review**

Invoke the **`dst-badge-visual-audit`** skill (read-only) against the changed `scripts/widgets/partybadge.lua`. Focus it on: the `circleframe` `SetMultColour` usage (alpha/RGB correctness), the low-HP-blink vs foreign-dim coexistence, the single-writer rule (`_apply_frame_colour` is the only circleframe colour writer), draw order, and that the alarm red is distinct from the thermal pulse and the red HP fill.

- [ ] **Step 2: Crash-safety review**

Invoke the **`dst-mod-crash-audit`** skill (read-only, 6 dimensions) against `partybadge.lua` + `modmain.lua`, emphasising the NEW code: the `DoPeriodicTask` blink (fire-time `circleframe` nil-guard, `self.inst` nil-guard, explicit Cancel + Widget:Kill teardown, no leak across HUD rebuild / re-entry), `_set_low_hp` idempotence, and the `cur / m` division (m is guarded `> 0`).

- [ ] **Step 3: Apply any must-fix findings**

Loop fixes back into Task 2/3 (edit local → parse-check → re-scp → re-luacheck). Re-run the relevant review. Only proceed when both reviews are clean (or findings are cosmetic and acknowledged).

---

### Task 6: Beta build + modtest in-game verification (controller + user/friend)

**Files:** beta uploader `work/content` + `work/beta.vdf`; modtest local mod folder (per memory `partyhud-beta-uploader`)

- [ ] **Step 1: Commit + push the code via hub, realign local**

On hub (`~/partyhud-fork`): `git add -A`, commit (message file via heredoc; **no apostrophes**), `git push origin master`. Locally: `git fetch origin && git reset --hard origin/master`. (Suggested message: `v2026.9 low-HP blinking border alert (config + partybadge circleframe blink)`.)

- [ ] **Step 2: Build beta `2026.9b1` + deploy to modtest**

Follow the `partyhud-beta-upload` skill / memory: sync fork → `work/content`, `sed` name to "PartyHud 2026 Beta", bump `version=` to `2026.9b1`, set `beta.vdf` changenote, upload via SteamCMD (account from `config.vdf`, scrubbed), then copy `work/content` to the modtest local folder `~/dst-modtest/dst/mods/workshop-3746763879` via a root steamcmd container, `docker-compose restart`, and confirm both shards log `Loading mod: workshop-3746763879 ... Version:2026.9b1` with 0 LUA errors.

- [ ] **Step 3: In-game verify (the 5 spec scenarios)**

With 2 players on modtest (`dstc`/`dst-heal`/`dst-fire`/`dst-cave` helpers):
1. Threshold on/off: drop a teammate's HP across 40/25/15 → border starts/stops blinking at the right point; set config **Off** → never blinks.
2. Coexist: low-HP + `dst-fire` → red border blink AND orange fire pulse simultaneously.
3. Far/cross-shard: teammate out of view / in caves (`dst-cave`) at low HP → dimmed far/"Caves" badge blinks alarm-red ↔ dim-white.
4. Death transition: kill a blinking teammate → blink stops, skull shows; revive → border back to baseline.
5. Config levels + restore: switch the dropdown across all four values (rejoin to apply); border returns to the correct foreign-aware baseline when HP recovers.

- [ ] **Step 4: Fix-and-reverify loop**

Any visual/behaviour issue → fix in the local file → re-gate (Task 4) → bump beta `2026.9b2`+ → redeploy → re-verify. Repeat until all 5 scenarios pass.

---

### Task 7: Ship v2026.9 (controller + user)

**Files:** `modinfo.lua` (version), `README.md` (changelog + BBCode)

- [ ] **Step 1: Bump version + README**

Edit local: `modinfo.lua` `version="2026.8"` → `version="2026.9"`. `README.md`: add a "New in 2026.9" entry (human section + both the English and zh-TW Steam BBCode blocks) describing the Low-HP Alert option, and add it to the Settings lists. Parse-check + scp to hub.

- [ ] **Step 2: Merge to master, tag, push (via hub)**

On hub `~/partyhud-fork`: commit the version+README, `git checkout master && git merge --ff-only <branch>` (or commit straight on master if working there), `git tag -a v2026.9 -m "PartyHud 2026.9 -- low-HP border alert"`, `git push origin master && git push origin v2026.9`. Realign local (`git fetch && git reset --hard origin/master`).

- [ ] **Step 3: User uploads + prod sync**

The USER uploads the public Workshop item `3744675705` to v2026.9. Then sync prod via the `-only_update_server_mods` updater (memory `dst-server-deployment`): `docker-compose down` → updater container (save mount + `-persistent_storage_root /home/steam/dst -conf_dir save -cluster Cluster_1`) → verify `modinfo` version `2026.9` in `ugc_mods` → `docker-compose up -d` → confirm both shards load v2026.9 with 0 LUA errors.

- [ ] **Step 4: Update memory**

Update `partyhud-2026-mod` (new v2026.9 shipped entry), `dst-server-deployment` (prod version), `partyhud-beta-uploader` (latest beta build).

---

## Notes for executors

- **Tasks 1-3 are subagent-implementable** (self-contained file edits + parse-check + local commit). **Tasks 4-7 are controller/user** (gate, review-skill dispatch, Steam upload, in-game testing, prod sync) — they can't be done blind by an implementer subagent.
- Dispatch Tasks 1-3 sequentially (they touch different files except 2/3 which are independent files — no conflict, but keep the order for clean history). Audit each subagent's diff against this plan before moving on.
- The whole feature is reversible and low-risk (client-only, no codec/server/transport change); the real gate is the in-game pass on modtest (Task 6).
