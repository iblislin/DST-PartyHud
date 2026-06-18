-- [PartyHud 2026 v2026.7] modernized fork of brianchenito/PartyHud v0.985.
-- v2026.6 richer status: broadcasts each teammate's current HP/hunger/sanity (net_ushortint,
-- the exact integer the game's own meters display = ceil(GetPercent()*max)) plus their max, and
-- on-fire/overheating/freezing (net_bool), via the same server-hook + custom-GUID-netvar pattern.
-- NOTE: player_classified is owner-target-scoped (player_common.lua:1016), so a teammate's
-- hunger/sanity/fire is NOT readable client-side -- the server hook is mandatory, not optional.
--
-- ============================================================================================
-- SHARD / CAVE INVARIANTS (verified against the DST scripts 2026-06-15; audited pre-v2026.6 ship)
-- This mod has crashed several times on cave entry / Master<->Caves migration; the data layer
-- below depends on the following assumptions. A future DST/server update that breaks one will
-- break this feature -- check here first:
--   1. `TheWorld.ismastersim` is true on BOTH shards (Master AND Caves) -- each is the authoritative
--      sim for its own world. The server hooks + seed run under it, so a player's badge data is
--      driven on whichever shard hosts them; on migration the old entity is Remove()'d (all its
--      ListenForEvents die with it) and AddPlayerPostInit re-runs on the destination shard,
--      re-binding fresh netvars. Do NOT assume a single shard, and do NOT add per-player timers
--      that could outlive the entity.
--   2. On the server a player ALWAYS has components health/hunger/sanity/temperature -- added
--      unconditionally in player_common.lua master_postinit (AddComponent ~2741/2766/2773/2781,
--      before AddPlayerPostInit). Ghosts RETAIN them (never RemoveComponent'd, only invincible).
--      => the unguarded `health:DoDelta(0)` seed is safe even for migrating ghosts.
--   3. Every server hook is `inst:ListenForEvent(..., handler)` on the PLAYER inst (never TheWorld)
--      and reads that same player's components. (The v2026.3 crash was a handler whose listener
--      source was TheWorld, so `inst.<field>` was nil.) Keep new hooks bound to the player.
--   4. `AllPlayers` is the client's set of players whose ENTITIES are currently networked to you
--      -- it is BOTH shard-local AND network-view-range-limited. A teammate in caves, or on the
--      same shard but too far away, has no local entity here, so no badge. Showing them needs an
--      always-networked broadcast carrier (the future v2026.8 "all teammates regardless of range /
--      shard" feature), not AllPlayers -- not a bug. The render loop stays bounded by #badgearray.
--   5. Netvar ranges: current HP/hunger/sanity + their max use net_ushortint (0..65535; WX-78's
--      400 HP fits, never negative); sanity rate is RATE_SCALE 0..6 in net_tinybyte (0..7). Never
--      feed a wider/negative value into these.
--   6. Client refresh paths (refresh_local_hud, the playerentered/playerexited presence listeners, the DoTaskInTime relayout, the
--      refreshhudsize listener) are nil-guarded against a mid-migration nil ThePlayer / torn-down
--      HUD. The refreshhudsize + playerentered/playerexited listeners are registered on the
--      statusdisplays widget's own self.inst (with TheWorld / HUD.inst as the event source), so
--      Widget:Kill on HUD rebuild tears them down -- no stale closure on a killed badgearray.
-- ============================================================================================
_G = GLOBAL

-- pulls setting for hud configs from modinfo. These are all client=true options, so read with
-- get_local_config=true -- otherwise GetModConfigData returns the server-synced value
-- (saved_server) and the player's own local choice (saved_client) is ignored (modutil.lua:34).
local layout=GetModConfigData("layout", true)
local positional=GetModConfigData("position", true)
local skip_self = (GetModConfigData("show_self", true) == 0) -- if true, don't draw a badge for yourself
local show_substatus = (GetModConfigData("show_substatus", true) ~= 0) -- if false, hide the hunger/sanity sub-rings
local hp_number_always = (GetModConfigData("hp_number", true) == 1) -- false = HP number shows only on hover
-- CLIENT-render-only toggle: when false, UpdateBadges renders ONLY local players (the foreign-append
-- block is skipped). Does NOT gate the server-side send/publish -- other clients may still want it on.
-- ~=0 makes a missing/older config default to shown.
local show_crossshard = (GetModConfigData("show_crossshard", true) ~= 0)
local DEBUG_SHOWALL = (GetModConfigData("debug_showall", true) == 1) -- [TEST] client option: mock-fill empty slots to preview layout (only this client sees it)
local low_hp_threshold = (GetModConfigData("low_hp_alert", true) or 0) / 100 -- v2026.9: 0 = disabled; fraction of max HP
-- [vertical layout tunables] edit these then restart client; only used when layout=Vertical
local VERT_X    = 0    -- horizontal pos (more negative = further left)
local VERT_Y    = -130 -- y of the FIRST (top) badge; lower number = lower on screen
local VERT_GAP  = -120 -- gap between badges (negative = each next one goes DOWN; sized so a badge's
                       -- name no longer overlaps the hunger/sanity sub-rings of the badge above)
local VERT_GAP_COMPACT = -90 -- tighter gap for the HP-only (no sub-rings) badge; pre-sub-ring spacing
local VERT_COL_W = 80  -- horizontal spacing when the column wraps to a new one (see compute_percol)
local VERT_BOTTOM_RESERVE = 65 -- badge-local units kept clear at the bottom for the game's map(M)
                                -- button. FIXED (not per-row): the compact gap is tighter, so a
                                -- per-row reserve would pack an extra badge into the button. Larger
                                -- = wraps a column one badge sooner.
local VERT_BOTTOM_RESERVE_FREE = 40 -- bottom keep-out for columns 2+ (further LEFT than the rightmost
                                    -- column): the game's Map(M) button only sits under the FIRST
                                    -- column, so later columns have a clear bottom and extend nearly to
                                    -- the screen edge (just this small margin). Smaller = reach further down.
local MOISTURE_TOP_RESERVE = 75 -- badge-local units to push the dodged column(s)' top DOWN for the moisture (rain) meter (y-115) or Wendy's Abigail badge (y-100, shallower). Visually tuned.
local INSPIRATION_TOP_RESERVE = 90 -- bigger top push when Wigfrid's inspiration badge (y-130, deeper than the moisture meter) is present -- it needs more clearance than the moisture/Abigail case. Visually tuned.
local BACKPACK_SHIFT_X = 100 -- badge-local units to shift ALL columns LEFT when a NON-integrated (side)
                            -- backpack is equipped: its floating container hugs the right screen edge
                            -- and would cover our badges. Visually tuned.
local BACKPACK_BOTTOM_EXTRA = 20 -- extra badge-local units added to the columns-2+ bottom reserve when an
                                 -- INTEGRATED backpack is equipped (the bottom inventory bar grows taller).
local second_row_cols = 0 -- client-local: how many of OUR leading columns the top-right status second-row band spans (0/1/2; see status_second_row). Those columns get their top pushed down to dodge the band (moisture meter / Abigail / inspiration).
local second_row_reserve = 0 -- client-local: how far down to push those columns (= the DEEPEST active second-row badge's need; MOISTURE_TOP_RESERVE, or INSPIRATION_TOP_RESERVE when Wigfrid's deeper inspiration badge is present).
local last_bpmode = -1 -- client-local: last applied backpack UI mode (see backpack_layout_mode); a 0.5s poll re-lays-out on change (right-click open/close + the integrated-backpack setting toggle fire NO event).

--imports partybadge
local phud_custombadge= _G.require "widgets/partybadge"
local phud_xpos
local phud_ypos

-- v2026.8 cross-shard: codec + the client-side foreign-records accessor are DEFINED far below
-- (after this point in the chunk), but UpdateBadges -- created inside onstatusdisplaysconstruct
-- right below -- must reference them. A Lua local declared later in the chunk is NOT an upvalue
-- of an earlier-defined closure, so forward-declare them here and assign the accessor at its
-- real definition site. codec is required here too (require is memoised; the later require returns
-- the same table) so UpdateBadges can unpack the flag int.
local codec_client = _G.require "partyhud_statuscodec"
local get_client_foreign_records -- forward decl; assigned where the client store lives (see below)

if positional==0 then -- standard with minimap
	phud_xpos= (-100)
	phud_ypos= (-70)
elseif positional==1 then --extra large minimap
	phud_xpos= (-650)
	phud_ypos= (50)
else--no minimap
	phud_xpos= (-100)
	phud_ypos= (120)
end

-- Vertical layout wrap: how many badges fit in one column before running off the
-- screen bottom. Badges live in the statusdisplays space (scaled 1.4 in controls.lua),
-- itself under topleft_root (scaled by GetHUDScale() AND SCALEMODE_PROPORTIONAL), so the visible
-- height in badge-local units = screenheight / (hudscale * 1.4 * prop). Detect it so small screens /
-- large HUD-size settings wrap to a second column instead of overflowing off-screen.
local function compute_percol(vy, bottom_reserve)
	local scrnw, scrnh
	if GLOBAL.TheSim ~= nil and GLOBAL.TheSim.GetScreenSize ~= nil then
		scrnw, scrnh = GLOBAL.TheSim:GetScreenSize()
	end
	local hudscale = 1
	if GLOBAL.TheFrontEnd ~= nil and GLOBAL.TheFrontEnd.GetHUDScale ~= nil then
		hudscale = GLOBAL.TheFrontEnd:GetHUDScale() or 1
	end
	if scrnh == nil or scrnh <= 0 or scrnw == nil or scrnw <= 0 or hudscale <= 0 then
		if DEBUG_SHOWALL then
			print("[PartyHud DEBUG] compute_percol fallback: scrnh="..tostring(scrnh).." hudscale="..tostring(hudscale))
		end
		return 6 -- safe fallback if the screen/HUD scale can't be read
	end
	local STATUS_SCALE = 1.4               -- statusdisplays default scale (controls.lua:155)
	-- topleft_root (parent of statusdisplays) is BOTH SCALEMODE_PROPORTIONAL and SetScale(hudscale)
	-- (controls.lua:503/559). The engine's proportional factor scales the badge relative to the
	-- 1280x720 reference (min of the width/height ratios), capped at MAX_HUD_SCALE=1.25 on upscale
	-- (controls.lua:506 SetMaxPropUpscale). So a badge's PIXEL height = local * STATUS_SCALE *
	-- hudscale * prop. We used to OMIT `prop`: on a sub-720 window prop<1 shrinks the real badges but
	-- `usable` didn't follow, so the column collapsed to a single badge. Divide it out so `usable`
	-- (screen height in badge-local units) tracks the real badge size -> per-column stays stable as
	-- the window resizes (and grows correctly on >1080p screens up to the 1.25 cap).
	local REF_W, REF_H, MAX_PROP = 1280, 720, 1.25 -- RESOLUTION_X / RESOLUTION_Y / MAX_HUD_SCALE (constants.lua)
	local prop = math.min(scrnw / REF_W, scrnh / REF_H)
	if prop > MAX_PROP then prop = MAX_PROP end
	if prop <= 0 then prop = 1 end
	local usable = scrnh / (hudscale * STATUS_SCALE * prop)
	local vgap = show_substatus and VERT_GAP or VERT_GAP_COMPACT -- effective gap (tighter when sub-rings hidden)
	local rowpitch = -vgap                 -- positive distance between rows
	-- reserve a FIXED keep-out zone at the bottom for the game's map (M) button. It must be a
	-- fixed absolute distance, NOT the row pitch: the compact (sub-gauges off) gap is tighter, so
	-- a per-row reserve packs an extra badge into the button. Fixed keeps equal clearance in both modes.
	bottom_reserve = bottom_reserve or VERT_BOTTOM_RESERVE -- default = full Map(M)-button keep-out (col 0); later columns pass a smaller value
	-- last visible row: badge origin minus ~60 (its sub-ring bottom) must stay above the
	-- reserved bottom zone.
	local n = math.floor((vy - 60 + usable - bottom_reserve) / rowpitch) + 1
	if n < 1 then n = 1 end
	if DEBUG_SHOWALL then
		print(string.format("[PartyHud DEBUG] scrnw=%.0f scrnh=%.0f hudscale=%.3f prop=%.3f usable=%.0f vy=%.0f gap=%.0f per_col=%d",
			scrnw, scrnh, hudscale, prop, usable, vy, vgap, n))
	end
	return n
end

-- v2026.8: which backpack UI is active for the LOCAL player? 0=none, 1=side floating (covers our
-- right-side badges), 2=integrated (taller bottom inventory bar). Client-only; everything nil-guarded.
local function backpack_layout_mode()
	local p = _G.ThePlayer
	if p == nil or p.replica == nil or p.replica.inventory == nil then return 0 end
	local eslot = (_G.EQUIPSLOTS ~= nil and _G.EQUIPSLOTS.BODY) or "body"
	local body = p.replica.inventory:GetEquippedItem(eslot)
	local cont = (body ~= nil and body.replica ~= nil) and body.replica.container or nil
	if cont == nil then return 0 end
	-- "Open" = the backpack UI is up. cont.opener is set synchronously in AttachOpener the moment the
	-- opener entity replicates -- one frame BEFORE _isopen/IsOpenedBy -- so it avoids the post-swap race
	-- where the equipped item already flipped to the new pack but its open-state has not gone live yet.
	-- Fallbacks: the HUD open-widget map (normal side widget) and inventorybar.backpack (integrated mode,
	-- which never populates controls.containers).
	local ctrls = (p.HUD ~= nil) and p.HUD.controls or nil
	local open = (cont.opener ~= nil)
		or (ctrls ~= nil and ctrls.containers ~= nil and ctrls.containers[body] ~= nil)
		or (ctrls ~= nil and ctrls.inv ~= nil and ctrls.inv.backpack == body)
	if not open then return 0 end
	local integrated = (_G.TheInput ~= nil and _G.TheInput:ControllerAttached())
		or (_G.Profile ~= nil and _G.Profile.GetIntegratedBackpack ~= nil and _G.Profile:GetIntegratedBackpack())
	return integrated and 2 or 1
end

-- v2026.8: does the top-right status cluster have a LOW second-row badge that pushes its bottom into
-- where col 0's top sits? That band holds the moisture (rain) meter (when wet), Wendy's Abigail
-- pet-health badge, and Wigfrid's inspiration badge (game y -115 / -100 / -130). `sd` is the vanilla
-- StatusDisplays widget (our postconstruct's self); pethealthbadge/inspirationbadge are non-nil only
-- for those characters. Boat/mightiness/pet-hunger/wereness sit in the normal cluster height -> ignored.
-- Returns how many of OUR columns the top-right status "second row" band spans: 0, 1, or 2.
-- Each low-band badge (moisture meter when wet, Wendy's Abigail pet-health, Wigfrid's inspiration)
-- counts as one. 1 => a single badge over col 0. 2 => the band is WIDE: a character badge DISPLACES
-- the moisture meter onto a neighbouring column (game: statusdisplays moves the moisture meter to
-- column2/column1 when pethealth/inspiration is present), so it covers col 0 AND col 1. The first
-- N columns then get their top pushed down.
-- Returns (cols, reserve): how many leading columns the band spans (0/1/2, see above) AND how far
-- down to push them = the DEEPEST active badge's need (Wigfrid inspiration y-130 needs more than the
-- moisture meter y-115 / Abigail y-100, which the smaller MOISTURE_TOP_RESERVE covers).
local function status_second_row(sd)
    if sd == nil then return 0, 0 end
    local n, reserve = 0, 0
    local p = sd.owner
    if p ~= nil and p.GetMoisture ~= nil and (p:GetMoisture() or 0) > 0 then
        n = n + 1; if MOISTURE_TOP_RESERVE > reserve then reserve = MOISTURE_TOP_RESERVE end
    end
    if sd.pethealthbadge ~= nil then -- Abigail (y-100), shallower than moisture -> MOISTURE_TOP_RESERVE covers it
        n = n + 1; if MOISTURE_TOP_RESERVE > reserve then reserve = MOISTURE_TOP_RESERVE end
    end
    if sd.inspirationbadge ~= nil then -- Wigfrid inspiration (y-130), the deepest -> needs more
        n = n + 1; if INSPIRATION_TOP_RESERVE > reserve then reserve = INSPIRATION_TOP_RESERVE end
    end
    return (n > 2 and 2 or n), reserve
end

-- Position every badge. Vertical layout wraps into columns sized by the live screen height.
local function layout_badges(badgearray)
	if badgearray == nil then return end
	if layout ~= 2 then
		--horizontal row
		for i = 1, #badgearray do
			badgearray[i]:SetPosition(phud_xpos + (-70*i), phud_ypos, 0)
		end
		return
	end
	-- vertical: Minimap/XL reuse the phud anchor; Standard uses VERT_X/VERT_Y. Stack down by
	-- VERT_GAP, wrapping to a new column to the LEFT every per_col badges (the list is anchored
	-- to the right edge of the screen, so extra columns must grow leftward to stay on-screen).
	local vstartx, vstarty = VERT_X, VERT_Y
	if positional==0 or positional==1 then vstartx, vstarty = phud_xpos, phud_ypos end
	local vgap = show_substatus and VERT_GAP or VERT_GAP_COMPACT -- effective gap (tighter when sub-rings hidden)
	-- v2026.8: an equipped backpack overlaps our HUD differently per UI mode (see backpack_layout_mode):
	--  * Mode A (1, side/floating): its container hugs the right screen edge over our badges -> shift ALL
	--    columns LEFT (done here, before per-column x is computed). That moves col 0 off the Map(M) button,
	--    so col 0 then uses the small `free` reserve like the other columns instead of the full Map reserve.
	--  * Mode B (2, integrated): the bottom inventory bar grows taller -> reserve extra bottom space on the
	--    columns-2+ `free` keep-out (those columns extend toward the screen bottom).
	local bpmode = backpack_layout_mode()
	if bpmode == 1 then vstartx = vstartx - BACKPACK_SHIFT_X end
	-- v2026.8: each column's available height differs by its on-screen obstacles, so capacities are
	-- computed PER COLUMN (no longer a uniform per_col):
	--  * TOP: the top-right status "second row" (moisture meter / Abigail / inspiration) sits exactly
	--    where the leading column(s)' top would be, so push the first `dodge_cols` columns' TOP down by
	--    `second_row_reserve` (the deepest active badge's need -- bigger for Wigfrid's y-130 inspiration
	--    than the moisture meter/Abigail). `dodge_cols` is `second_row_cols` (0/1/2 -- it's 2 when rain +
	--    Abigail/inspiration widens the band, displacing the moisture meter onto col 1). This top dodge
	--    applies in EVERY mode -- Mode A's left shift clears the backpack, not the status cluster.
	--  * BOTTOM: ONLY col 0 sits under the Map(M) button -> full VERT_BOTTOM_RESERVE (unless Mode A
	--    shifted it off); later columns extend toward the screen bottom (`free`, +BACKPACK_BOTTOM_EXTRA
	--    in Mode B's taller-bar case).
	local free = VERT_BOTTOM_RESERVE_FREE + ((bpmode == 2) and BACKPACK_BOTTOM_EXTRA or 0)
	-- The top dodge (status second row) is separate from the Mode-A left shift (backpack). In Mode A the
	-- columns shift LEFT ~BACKPACK_SHIFT_X, so the (fixed, top-right) status band covers FEWER of them:
	-- a single home-column badge (moisture alone, or a resting char badge) is cleared by the shift; only
	-- the WIDE case (rain + Abigail/inspiration DISPLACES the moisture meter left) still lands one badge
	-- under the shifted col 0 -> dodge just col 0 there (col 1 has moved left, now clear -- no gap).
	-- Outside Mode A the band covers `second_row_cols` (0/1/2) columns directly.
	local dodge_cols = (bpmode == 1) and ((second_row_cols >= 2) and 1 or 0) or second_row_cols
	-- Fill top-to-bottom, wrapping LEFTWARD (right-anchored list). compute_percol always returns >=1 so
	-- col advances and i grows each pass; `col <= n` is a belt-and-suspenders bound on the loop.
	local n = #badgearray
	local i, col = 1, 0
	while i <= n and col <= n do
		local top    = (col < dodge_cols) and (vstarty - second_row_reserve) or vstarty
		local bottom = (col == 0 and bpmode ~= 1) and VERT_BOTTOM_RESERVE or free
		local cap = compute_percol(top, bottom)
		for row = 0, cap - 1 do
			if i > n then break end
			badgearray[i]:SetPosition(vstartx - VERT_COL_W*col, top + vgap*row, 0)
			i = i + 1
		end
		col = col + 1
	end
end

-- Single re-layout path for DYNAMIC state (backpack mode / second-row band). Recomputes the cached
-- comparison state AND lays out only when it changed -- so every trigger goes through here and the
-- cache can never desync (the swap bug was a trigger that laid out directly without updating the cache,
-- which then fooled the poll's change-check into "no change" forever).
local function relayout_if_changed(self)
	if self == nil or self.badgearray == nil then return end
	local m = backpack_layout_mode()
	local c, r = status_second_row(self)
	if m ~= last_bpmode or c ~= second_row_cols or r ~= second_row_reserve then
		last_bpmode, second_row_cols, second_row_reserve = m, c, r
		layout_badges(self.badgearray)
	end
end

-- [DEBUG/util] runtime layout switch from the client console, no reconnect needed:
--   PartyHud_Layout()  -> toggle Vertical <-> Horizontal
--   PartyHud_Layout(1) -> Horizontal,  PartyHud_Layout(2) -> Vertical
-- Reassigns the `layout` upvalue (which layout_badges reads) and re-lays-out the live badges.
-- Client-only effect (no-op on a dedicated server: ThePlayer/HUD are nil there). Returns the new value.
-- luacheck: push ignore 122
-- (122 = "setting read-only field of GLOBAL"; intentional — we expose a console-callable global.)
GLOBAL.PartyHud_Layout = function(n)
	if n == nil then layout = (layout == 2) and 1 or 2 else layout = n end
	local p = _G.ThePlayer
	local sd = p ~= nil and p.HUD ~= nil and p.HUD.controls ~= nil and p.HUD.controls.status or nil
	if sd ~= nil and sd.badgearray ~= nil then layout_badges(sd.badgearray) end
	print("[PartyHud] layout = " .. tostring(layout) .. (layout == 2 and " (Vertical)" or " (Horizontal)"))
	return layout
end
-- luacheck: pop

--constructor for badge array
local function onstatusdisplaysconstruct(self)

	self.badgearray = {}
	--instance one badge per slot
	for i = 1, GLOBAL.TheNet:GetDefaultMaxPlayers(), 1 do
		self.badgearray[i]=self:AddChild(phud_custombadge(self,self.owner))
		self.badgearray[i]:SetSubGauges(show_substatus) -- apply the sub-gauge config at construct time
		self.badgearray[i]:SetHPNumberAlways(hp_number_always)
		self.badgearray[i].low_hp_threshold = low_hp_threshold -- v2026.9 low-HP alert threshold
	end

	-- v2026.8: re-layout on the dynamic state that changes the backpack mode / second-row dodge.
	-- Event-driven (instant) + a slow safety-net poll. The equip-netvar and the container-open channels
	-- settle on DIFFERENT frames, so on an equip/swap we re-sample ONE frame later (DoStaticTaskInTime 0)
	-- after both settle -- a same-frame read hits the race. "refreshinventory" is guaranteed to fire on a
	-- backpack swap (it drives the stock inventory bar rebuild); equip/unequip cover the BODY slot.
	-- moisturedelta has no two-channel race, so it samples immediately. ALL paths go through
	-- relayout_if_changed so the cache stays consistent.
	if self.inst ~= nil and self.owner ~= nil then
		local BODY = (_G.EQUIPSLOTS ~= nil and _G.EQUIPSLOTS.BODY) or "body"
		local function deferred()
			if self.inst ~= nil and self.inst.DoStaticTaskInTime ~= nil then
				self.inst:DoStaticTaskInTime(0, function() relayout_if_changed(self) end)
			elseif self.inst ~= nil and self.inst.DoTaskInTime ~= nil then
				self.inst:DoTaskInTime(0, function() relayout_if_changed(self) end)
			end
		end
		relayout_if_changed(self) -- initial: set the cache + first layout
		self.inst:ListenForEvent("refreshinventory", deferred, self.owner)
		self.inst:ListenForEvent("equip", function(_, d) if d == nil or d.eslot == nil or d.eslot == BODY then deferred() end end, self.owner)
		self.inst:ListenForEvent("unequip", function(_, d) if d == nil or d.eslot == nil or d.eslot == BODY then deferred() end end, self.owner)
		self.inst:ListenForEvent("moisturedelta", function() relayout_if_changed(self) end, self.owner)
		if self.inst.DoPeriodicTask ~= nil then
			self.inst:DoPeriodicTask(1.0, function() relayout_if_changed(self) end) -- safety net (integrated-setting toggle fires no event)
		end
	end

	-- Lay out now (best-effort), then again next frame: this postconstruct runs BEFORE
	-- controls.lua applies the HUD scale / first SetHUDSize, so screen-size detection at
	-- construct time can be stale and mis-size the columns. Re-laying out on DoTaskInTime(0)
	-- (scale is live by then) and on every "refreshhudsize" event keeps the wrap correct,
	-- including when the player resizes the game window.
	layout_badges(self.badgearray)
	if self.owner ~= nil and self.owner.DoTaskInTime ~= nil then
		self.owner:DoTaskInTime(0, function()
			layout_badges(self.badgearray)
			if self.inst ~= nil and self.owner.HUD ~= nil and self.owner.HUD.inst ~= nil then
				-- register on self.inst (the widget) with HUD.inst as the source, so this listener
				-- is torn down with the widget on HUD rebuild (no stale closure on a killed badgearray).
				self.inst:ListenForEvent("refreshhudsize", function()
					layout_badges(self.badgearray)
				end, self.owner.HUD.inst)
			end
		end)
	end

	-- Presence refresh: re-run UpdateBadges whenever a player enters/leaves local network view
	-- (join, disconnect, or shard migration). playerentered/playerexited fire on TheWorld for BOTH
	-- server and client (ms_playerjoined/ms_playerleft are server-only). Registered on self.inst
	-- (the widget) so they're cleaned up when the HUD is rebuilt, e.g. on your own migration.
	if self.inst ~= nil and GLOBAL.TheWorld ~= nil then
		local function on_presence_changed()
			-- Defer one beat so AllPlayers / GetClientTable have settled after the entered/exited
			-- event. Scheduled on self.inst (the widget), NOT TheWorld: TheWorld outlives a HUD
			-- rebuild, so a task parked on it could fire against this already-killed widget; parked
			-- on self.inst, Widget:Kill's CancelAllPendingTasks tears it down. (The fire-time
			-- self.owner guard is still kept as belt-and-suspenders.)
			if self.inst ~= nil then
				self.inst:DoTaskInTime(0.1, function()
					if self.owner ~= nil and self.owner.UpdateBadges ~= nil then
						self.owner.UpdateBadges()
					end
				end)
			end
		end
		self.inst:ListenForEvent("playerentered", on_presence_changed, GLOBAL.TheWorld)
		self.inst:ListenForEvent("playerexited", on_presence_changed, GLOBAL.TheWorld)
	end

	-- single authoritative refresh: bounded by badge count (no nil-index crash),
	-- stable userid ordering (no badge<->player desync), name+HP+visibility in one pass,
	-- trailing slots cleared (no stale departed-player names).
	self.owner.UpdateBadges = function()
		local maxbadges = #self.badgearray
		-- when skipping your own badge, at most maxbadges-1 OTHER players can ever show; cap the
		-- DEBUG mock fill to match (real players are never capped -- they can't exceed this anyway).
		local visible_cap = maxbadges - (skip_self and 1 or 0)
		local players = {}
		for _, v in ipairs(_G.AllPlayers) do
			if not (skip_self and v == _G.ThePlayer) then players[#players+1] = v end
		end
		-- your own badge always sorts to slot 1 (client-side ThePlayer); everyone else by userid
		-- for a stable order that doesn't shuffle as AllPlayers reindexes on join/leave.
		local me = _G.ThePlayer
		table.sort(players, function(a, b)
			-- irreflexive guard: never report an element < itself. Without it, when ThePlayer is
			-- in the list (show_self) and lands on the sort pivot, comp(me,me)=true breaks Lua 5.1
			-- table.sort's sentinel -> "invalid order function for sorting" error.
			if a == b then return false end
			if a == me then return true end -- your own badge sorts to slot 1
			if b == me then return false end
			return (a.userid or "") < (b.userid or "")
		end)
		-- v2026.8 cross-shard: track which userids are rendered as LOCAL entities this pass, so the
		-- foreign blob can never double-draw a player who is also local (e.g. mid-migration the player
		-- briefly exists on both shards). A local entity ALWAYS wins. Built as we assign local slots.
		local local_userids = {}
		-- next_slot is the first badge index NOT consumed by a local player; the foreign loop starts here.
		local next_slot = maxbadges + 1
		for i = 1, maxbadges do
			local b = self.badgearray[i]
			if b == nil then break end
			local v = players[i]
			if v ~= nil then
				-- real player: show live HP/hunger/sanity/fire/temperature
				local isdead = (v.customisdead ~= nil and v.customisdead:value()) or false
				local hpcur = (v.customhpbadgepercent ~= nil and v.customhpbadgepercent:value()) or 0
				local maxhp = (v.customhpbadgemax ~= nil and v.customhpbadgemax:value()) or 0
				local hppenalty = (v.customhpbadgedebuff ~= nil and v.customhpbadgedebuff:value()/100) or 0
				local hunger = (v.customhunger ~= nil and v.customhunger:value()) or 0
				local hungermax = (v.customhungermax ~= nil and v.customhungermax:value()) or 100
				local sanity = (v.customsanity ~= nil and v.customsanity:value()) or 0
				local sanitymax = (v.customsanitymax ~= nil and v.customsanitymax:value()) or 100
				local sanitypenalty = (v.customsanitydebuff ~= nil and v.customsanitydebuff:value()/100) or 0
				local onfire = (v.customonfire ~= nil and v.customonfire:value()) or false
				local overheating = (v.customoverheating ~= nil and v.customoverheating:value()) or false
				local freezing = (v.customfreezing ~= nil and v.customfreezing:value()) or false
				if hungermax <= 0 then hungermax = 100 end
				if sanitymax <= 0 then sanitymax = 100 end
				if v.userid ~= nil and v.userid ~= "" then local_userids[v.userid] = true end
				b:SetForeign(false) -- this slot is a LOCAL player: reset any "elsewhere" treatment
				b:SetName(v:GetDisplayName())
				b:SetPercent(hpcur, maxhp, hppenalty)
				b:SetStatus(hunger, hungermax, sanity, sanitymax, onfire, overheating, freezing, sanitypenalty)
				local sanityrate = (v.customsanityrate ~= nil and v.customsanityrate:value()) or 0
				b:SetSanityRate(sanityrate)
				if isdead then b:ShowDead() else b:ShowBadge() end
			elseif DEBUG_SHOWALL and i <= visible_cap then
				-- [TEST ONLY] empty seat -> mock placeholder so the full layout stays visible
				b:SetForeign(false)
				b:SetName("Player"..i)
				b:SetPercent((i*17)%150, 150, (i % 3 == 0) and 0.25 or 0)
				b:SetStatus((i*23)%150, 150, (i*41)%200, 200, (i%4)==0, (i%4)==1, (i%4)==2, (i % 3 == 0) and 0.25 or 0)
				b:SetSanityRate((i*5)%7)
				b:ShowBadge()
			else
				-- first empty slot marks where foreign players begin; remember it then stop the local pass.
				next_slot = i
				break
			end
		end

		-- v2026.8 cross-shard: append the FOREIGN players (the other shard + out-of-range) after the
		-- locals, into the remaining badge slots (still bounded by maxbadges). Foreign records carry
		-- only integers + userid; names come from the cluster-wide roster (TheNet:GetClientTable()).
		-- DEBUG_SHOWALL fills every slot with mock locals, so there is no room for foreign there -- skip.
		-- show_crossshard (client option) additionally gates this: when off, only local players render.
		-- The trailing-slot clear below still runs, so a slot that WAS foreign last refresh gets
		-- SetForeign(false) + HideBadge() (next_slot stays = the first non-local slot here).
		if show_crossshard and not DEBUG_SHOWALL and next_slot <= maxbadges then
			-- userid -> display name, built once per refresh from the cluster roster.
			local namebyuserid = {}
			local clienttable = _G.TheNet ~= nil and _G.TheNet:GetClientTable() or nil
			if clienttable ~= nil then
				for _, c in ipairs(clienttable) do
					if c.userid ~= nil and c.userid ~= "" then namebyuserid[c.userid] = c.name end
				end
			end

			-- This client's shard determines the label for the foreign one (2-shard cluster): if we
			-- are in the Caves the others are on the Surface, and vice versa.
			local foreign_label = (_G.TheWorld ~= nil and _G.TheWorld:HasTag("cave")) and "Surface" or "Caves"
			-- this client's own shard id (NUMBER, matching the codec v2 `origin` field). A foreign
			-- record whose origin == my_shard is a SAME-shard teammate that fell out of network
			-- view-range -- rendered "far" rather than with the cross-shard label below.
			-- IMPORTANT: TheShard:GetShardId() is UNRELIABLE on a pure client -- it does NOT return the
			-- server shard's id (observed: master server id 1, but the client's call yields a non-matching
			-- value, so every same-shard-far teammate wrongly got the cross-shard "Caves"/"Surface" label).
			-- Derive it from this client's OWN record in the carrier blob instead: the server stamps every
			-- local player -- INCLUDING ThePlayer -- with this shard's origin, so ThePlayer's record origin
			-- IS my shard id. nil until the first blob carrying ThePlayer arrives (-> records fall to the
			-- cross-shard label for that brief window, self-correcting on the next refresh).
			local my_shard = nil
			if _G.ThePlayer ~= nil and _G.ThePlayer.userid ~= nil then
				for _, r in ipairs(get_client_foreign_records()) do
					if r.userid == _G.ThePlayer.userid and r.origin ~= nil then
						my_shard = r.origin
						break
					end
				end
			end

			local slot = next_slot
			for _, rec in ipairs(get_client_foreign_records()) do
				if slot > maxbadges then break end
				-- a local entity always wins: never double-draw a userid already shown as local.
				if not (rec.userid ~= nil and local_userids[rec.userid]) then
					local b = self.badgearray[slot]
					if b == nil then break end
					-- foreign records carry no hunger MAX, only the current hunger value -- default the
					-- scale so the ring still reads sensibly (matches the local-path hungermax<=0 default).
					local hungermax = 100
					local sanitymax = (rec.sanity_max ~= nil and rec.sanity_max > 0) and rec.sanity_max or 100
					local flags = codec_client.unpackflags(rec.flags)
					-- origin nil/0 (a v1 peer, or unresolved shard) -> same_shard false -> cross-shard
					-- label, preserving pre-v2 behaviour.
					local same_shard = (my_shard ~= nil and rec.origin ~= nil and rec.origin == my_shard)
					if same_shard then
						b:SetForeign(true, nil, true)        -- same-shard out-of-view -> dimmed + "far"
					else
						b:SetForeign(true, foreign_label)    -- cross-shard -> "Caves"/"Surface"
					end
					b:SetName(namebyuserid[rec.userid] or "?")
					b:SetPercent(rec.hp_cur or 0, rec.hp_max, (rec.hp_penalty or 0) / 100)
					-- SIMPLIFIED status: hunger/sanity + penalty shown, but NO live thermal pulse for far
					-- players (fire/overheat/freeze forced false -- misleading at ~1s lag).
					b:SetStatus(rec.hunger, hungermax, rec.sanity_cur, sanitymax, false, false, false, (rec.sanity_penalty or 0) / 100)
					b:SetSanityRate(0) -- neutral: no rate arrow for far players
					if flags.dead then b:ShowDead() else b:ShowBadge() end
					slot = slot + 1
				end
			end
			next_slot = slot
		end

		-- trailing-slot clear: any badge past the last assigned (local OR foreign) slot is hidden,
		-- so departed players leave no stale name/ring behind.
		for i = next_slot, maxbadges do
			local b = self.badgearray[i]
			if b == nil then break end
			b:SetForeign(false)
			b:HideBadge()
		end
	end
	-- visibility is folded into UpdateBadges; keep the old name as an alias for safety
	self.owner.UpdateBadgeVisibility = self.owner.UpdateBadges

end

-- Apply function on construction of class statusdisplays
AddClassPostConstruct("widgets/statusdisplays", onstatusdisplaysconstruct)

--server functions: drive the netvars from real health/death events
local function onhealthdelta(inst, data)
	local setpercent = data.newpercent and data.newpercent or 0  -- GetPercent() = current / FULL max
	local fullmax = inst.components.health.maxhealth              -- FULL max; the penalty is shown separately
	inst.customhpbadgepercent:set(math.ceil(setpercent * fullmax))                  -- absolute current HP
	inst.customhpbadgemax:set(math.floor(fullmax + 0.5))                            -- FULL max (ring is relative to this)
	inst.customhpbadgedebuff:set(math.floor(inst.components.health:GetPenaltyPercent() * 100 + 0.5)) -- max-HP penalty, 0-100
	if inst:HasTag('playerghost') then
		inst.customisdead:set(true)
	end
end

-- v2026.7: ghost state from the authoritative lifecycle events (ms_becameghost /
-- ms_respawnedfromghost, pushed on the player) instead of the intent events death/
-- respawnfromghost -- death can fire without the player actually becoming a ghost.
local function onbecameghost(inst,data)
	inst.customisdead:set(true)
end

local function onrespawnedfromghost(inst,data)
	inst.customisdead:set(false)
end

-- v2026.6 richer status: hunger/sanity current value + on-fire flag, same server-hook pattern as health.
local function onhungerdelta(inst, data)
	local p = data and data.newpercent or 0
	if inst.components.hunger ~= nil then
		local hmax = inst.components.hunger.max
		inst.customhunger:set(math.ceil(p * hmax))
		inst.customhungermax:set(math.floor(hmax + 0.5))
	end
end

-- Mirror widgets/sanitybadge.lua:OnUpdate so the broadcast rate matches the game's own brain
-- arrow -- in particular its SLEEP special-case (GetRateScale() is NEUTRAL while sleeping, but
-- the game still shows a rising arrow from the fixed sleep regen rate), plus the "no increase at
-- full / no decrease at empty" guards.
local function compute_sanity_ratescale(inst)
	local sanity = inst.components.sanity
	if sanity == nil then return GLOBAL.RATE_SCALE.NEUTRAL end
	if inst:HasTag("sleeping") then
		if sanity:GetPercentWithPenalty() < 1 then
			local rate = GLOBAL.TUNING.SLEEP_SANITY_PER_TICK / GLOBAL.TUNING.SLEEP_TICK_PERIOD
			return (rate > .2 and GLOBAL.RATE_SCALE.INCREASE_HIGH)
				or (rate > .1 and GLOBAL.RATE_SCALE.INCREASE_MED)
				or (rate > .01 and GLOBAL.RATE_SCALE.INCREASE_LOW)
				or GLOBAL.RATE_SCALE.NEUTRAL
		end
		return GLOBAL.RATE_SCALE.NEUTRAL
	end
	local rs = sanity:GetRateScale()
	local pct = sanity:GetPercentWithPenalty()
	if rs == GLOBAL.RATE_SCALE.INCREASE_HIGH or rs == GLOBAL.RATE_SCALE.INCREASE_MED or rs == GLOBAL.RATE_SCALE.INCREASE_LOW then
		return (pct < 1) and rs or GLOBAL.RATE_SCALE.NEUTRAL
	elseif rs == GLOBAL.RATE_SCALE.DECREASE_HIGH or rs == GLOBAL.RATE_SCALE.DECREASE_MED or rs == GLOBAL.RATE_SCALE.DECREASE_LOW then
		return (pct > 0) and rs or GLOBAL.RATE_SCALE.NEUTRAL
	end
	return GLOBAL.RATE_SCALE.NEUTRAL
end

local function onsanitydelta(inst, data)
	local p = data and data.newpercent or 0
	if inst.components.sanity ~= nil then
		local sanity = inst.components.sanity
		local smax = sanity.max                                            -- FULL max; penalty shown separately
		inst.customsanity:set(math.ceil(p * smax))                         -- absolute current sanity
		inst.customsanitymax:set(math.floor(smax + 0.5))                   -- FULL max (ring relative to this)
		inst.customsanitydebuff:set(math.floor(sanity:GetPenaltyPercent() * 100 + 0.5)) -- max-sanity penalty 0-100
		-- SANITY RATE ARROW (event-driven, no poll). ASSUMPTION: Sanity:DoDelta UNCONDITIONALLY
		-- pushes "sanitydelta" on EVERY sanity update tick (sanity.lua:405, called from Recalc at
		-- :609 each StartUpdatingComponent tick), carrying the freshly recomputed ratescale incl. the
		-- settle to NEUTRAL (:599-606). That is why hooking here is enough and no DoPeriodicTask is
		-- needed; net_tinybyte:set only transmits on an actual change. IF a future game update makes
		-- sanitydelta fire only on value change, the arrow would stop clearing to neutral -> then
		-- revert to a periodic poll of sanity:GetRateScale().
		-- Use compute_sanity_ratescale (not raw GetRateScale): it mirrors the game's brain-arrow
		-- logic incl. the sleep special-case (GetRateScale() is NEUTRAL while sleeping) and the
		-- no-increase-at-full / no-decrease-at-empty guards from sanitybadge.lua:OnUpdate.
		inst.customsanityrate:set(compute_sanity_ratescale(inst))
	end
end

local function onstartfire(inst, data)
	inst.customonfire:set(true)
end

local function onstopfire(inst, data)
	inst.customonfire:set(false)
end

local function onstartoverheating(inst, data)
	inst.customoverheating:set(true)
end

local function onstopoverheating(inst, data)
	inst.customoverheating:set(false)
end

local function onstartfreezing(inst, data)
	inst.customfreezing:set(true)
end

local function onstopfreezing(inst, data)
	inst.customfreezing:set(false)
end

-- client refresh, guarded against nil ThePlayer / not-yet-attached UpdateBadges
-- (ThePlayer/HUD may not exist yet during early join or your own shard migration)
local function refresh_local_hud()
	if _G.ThePlayer ~= nil and _G.ThePlayer.UpdateBadges ~= nil then
		_G.ThePlayer.UpdateBadges()
	end
end

local function oncustomhpbadgedirty(inst)
	refresh_local_hud()
end

local function ondeathdeltadirty(inst)
	refresh_local_hud()
end

local function customhppostinit(inst)
	-- per-entity netvars (ushortint current/max, byte, bool); 3rd arg is the dirty-event name
	inst.customhpbadgepercent = GLOBAL.net_ushortint(inst.GUID, "customhpbadge.percent", "customhpbadgedirty") -- holds current HP (absolute integer the game would display)
	inst.customhpbadgemax = GLOBAL.net_ushortint(inst.GUID,"customhpbadge.max","customhpbadgedirty") -- ushort: max HP can exceed 255 (e.g. WX-78 400)
	-- max-HP penalty as a 0-100 int (set in onhealthdelta via math.floor(GetPenaltyPercent()*100+0.5),
	-- read in UpdateBadges:224 and passed to PartyBadge:SetPercent -> drives the darkened penalty
	-- topper on the HP ring). Stored as an int (NOT the raw 0..1 float, which would truncate to 0 in a
	-- net_byte). Do NOT remove -- the penalty arc depends on it.
	inst.customhpbadgedebuff = GLOBAL.net_byte(inst.GUID,"customhpbadge.debuff","customhpbadgedirty")
	inst.customisdead = GLOBAL.net_bool(inst.GUID,"customhpbadge.isdead","ondeathdeltadirty")
	-- v2026.6: hunger/sanity (absolute current value) + on-fire; share the customhpbadgedirty event so the
	-- existing client listener triggers a refresh on any of them changing.
	inst.customhunger = GLOBAL.net_ushortint(inst.GUID,"customhpbadge.hunger","customhpbadgedirty") -- holds current hunger (absolute)
	inst.customhungermax = GLOBAL.net_ushortint(inst.GUID,"customhpbadge.hungermax","customhpbadgedirty")
	inst.customsanity = GLOBAL.net_ushortint(inst.GUID,"customhpbadge.sanity","customhpbadgedirty") -- holds current sanity (absolute)
	inst.customsanitymax = GLOBAL.net_ushortint(inst.GUID,"customhpbadge.sanitymax","customhpbadgedirty")
	inst.customsanitydebuff = GLOBAL.net_byte(inst.GUID,"customhpbadge.sanitydebuff","customhpbadgedirty") -- max-sanity penalty, 0-100
	inst.customsanityrate = GLOBAL.net_tinybyte(inst.GUID,"customhpbadge.sanityrate","customhpbadgedirty")
	inst.customonfire = GLOBAL.net_bool(inst.GUID,"customhpbadge.onfire","customhpbadgedirty")
	inst.customoverheating = GLOBAL.net_bool(inst.GUID,"customhpbadge.overheating","customhpbadgedirty")
	inst.customfreezing = GLOBAL.net_bool(inst.GUID,"customhpbadge.freezing","customhpbadgedirty")

	-- Server (master sim) reacts to health/death and updates the netvars
	if GLOBAL.TheWorld.ismastersim then
		inst:ListenForEvent("healthdelta", onhealthdelta)
		inst:ListenForEvent("ms_respawnedfromghost", onrespawnedfromghost)
		inst:ListenForEvent("ms_becameghost", onbecameghost)
		inst:ListenForEvent("hungerdelta", onhungerdelta)
		inst:ListenForEvent("sanitydelta", onsanitydelta)
		inst:ListenForEvent("startfiredamage", onstartfire)
		inst:ListenForEvent("stopfiredamage", onstopfire)
		inst:ListenForEvent("startoverheating", onstartoverheating)
		inst:ListenForEvent("stopoverheating", onstopoverheating)
		inst:ListenForEvent("startfreezing", onstartfreezing)
		inst:ListenForEvent("stopfreezing", onstopfreezing)

		-- seed dead/ghost state for players (re)spawning here, incl. ghosts arriving via shard migration
		if inst:HasTag("playerghost") or (inst.components.health ~= nil and inst.components.health:IsDead()) then
			inst.customisdead:set(true)
		end
		inst.components.health:DoDelta(0)
		-- seed hunger/sanity so badges are populated before the first delta event fires
		if inst.components.hunger ~= nil then
			local hmax = inst.components.hunger.max
			inst.customhunger:set(math.ceil(inst.components.hunger:GetPercent() * hmax))
			inst.customhungermax:set(math.floor(hmax + 0.5))
		end
		if inst.components.sanity ~= nil then
			local smax = inst.components.sanity.max
			inst.customsanity:set(math.ceil(inst.components.sanity:GetPercent() * smax))
			inst.customsanitymax:set(math.floor(smax + 0.5))
			inst.customsanitydebuff:set(math.floor(inst.components.sanity:GetPenaltyPercent() * 100 + 0.5))
			-- seed the rate once; thereafter it's updated event-driven in onsanitydelta (no poll).
			-- compute_sanity_ratescale mirrors the game's brain-arrow logic incl. the sleep
			-- special-case + the no-increase-at-full / no-decrease-at-empty guards.
			inst.customsanityrate:set(compute_sanity_ratescale(inst))
		end
		if inst.components.temperature ~= nil then
			local t = inst.components.temperature:GetCurrent()
			inst.customfreezing:set(t < 0)
			inst.customoverheating:set(t > inst.components.temperature.overheattemp)
		end
	end

	-- Clients react to this player's own netvar changes. Presence (join / disconnect / shard
	-- migration) is handled centrally by playerentered/playerexited on TheWorld in
	-- onstatusdisplaysconstruct, so no per-entity onremove refresh is needed here.
	if not GLOBAL.TheNet:IsDedicated() then
		inst:ListenForEvent("customhpbadgedirty", oncustomhpbadgedirty)
		inst:ListenForEvent("ondeathdeltadirty", ondeathdeltadirty)
	end
end
AddPlayerPostInit(customhppostinit)

-- ============================================================================================
-- v2026.8 CROSS-SHARD STATUS TRANSPORT (T3 of the cross-shard feature)
--
-- AllPlayers is shard-local + network-view-range-limited (SHARD INVARIANT #4), so a teammate in
-- the caves (a SEPARATE shard) has no entity on this server and never gets a badge. To show them,
-- each shard's SERVER batches its LOCAL players' status (the same integers the per-player netvars
-- above already carry) and ships it to the other shard(s) over the engine's shard mod RPC. The
-- receiving shard STOREs the foreign snapshot. Publishing the foreign data to clients + rendering
-- it are LATER tasks (T4/T5); T3 is purely the server<->server transport + store-on-receive.
--
-- All of this is SERVER-only and runs on BOTH shards (ismastersim is true on Master AND Caves --
-- SHARD INVARIANT #1). The receive handler ONLY stores: a shard RPC handler that sends a shard RPC
-- in the same frame gets dropped (networkclientrpc.lua), so sending lives in a separate periodic
-- task, never inside the handler.
-- ============================================================================================
local codec = _G.require "partyhud_statuscodec"
local crossshard = _G.require "partyhud_crossshard"

-- DEBUG: print a sentinel on every send + receive so the round-trip is visible in the shard logs.
-- Default true for T3 verification; flipped to false (or wired to a config) in a later task.
local DEBUG_XSHARD = false -- gates the per-tick [PartyHud] [XSHARD] log spam; off for normal play

-- Foreign-entry expiry TTL (seconds). The send is a fixed ~2 Hz unconditional full snapshot, so a
-- healthy peer refreshes every entry's timestamp ~every 0.5s. If a peer shard CRASHES / stops
-- sending, its players stop being refreshed and age out after ~3s (6 missed sends) rather than
-- lingering forever. Must be comfortably larger than the 0.5s send period.
local XSHARD_TTL = 3

-- The mod RPC namespace/name pair. Namespace is the mod's folder; any stable string works as long
-- as both shards (running the same mod build) agree on it.
local XSHARD_RPC_NAMESPACE = "partyhud"
local XSHARD_RPC_NAME = "status"

-- ONE module-level store of the OTHER shards' players, keyed by userid. Filled by the receive
-- handler; read by T4/T5 (not here).
local foreign_store = crossshard.new()

-- CLIENT-side store of the foreign players, as a plain array of codec records (NOT a crossshard
-- store -- the server already did the upsert/dedup; the client just receives the cleaned snapshot).
-- Replaced wholesale each time the carrier net_string goes dirty (see attach_carrier below). T5 will
-- call get_client_foreign_records() from UpdateBadges to render these. Starts empty so a client that
-- never receives a blob (e.g. single-shard world) reads a harmless empty table.
local client_foreign_records = {}
-- assign the forward-declared accessor (declared near the top so UpdateBadges can capture it as an
-- upvalue). T5's UpdateBadges integration reads this to render the foreign players.
get_client_foreign_records = function()
	return client_foreign_records
end

-- Build the local-player status records the SAME way UpdateBadges reads them: straight off the
-- per-player netvars the server hooks already :set(). Returns an array of codec records (8 ints +
-- userid). Players with a nil/"" userid are skipped (they can't be keyed in the store).
local function build_local_records()
	local records = {}
	-- This shard's id, stamped onto every record we emit (codec v2 `origin` field). NOTE:
	-- TheShard:GetShardId() returns a STRING, not a number (SHARDID.MASTER == "1", constants.lua:2482)
	-- -- which is why the send loop below tostring()s it to match Shard_GetConnectedShards()'s string
	-- keys. Here we go the OTHER way and coerce to a NUMBER, so the in-memory origin type matches what
	-- the client ultimately compares against: every origin the client sees has been through codec
	-- encode->decode (math.floor on encode, tonumber on decode) and is therefore a number. Normalizing
	-- here removes a latent "1" == 1 -> false trap if a future path ever compared a freshly-built
	-- record's origin before re-encoding. Falls back to 0 if TheShard isn't resolvable yet.
	-- IMPORTANT: use GLOBAL.tonumber, NOT bare tonumber -- the DST modmain sandbox env (mods.lua)
	-- whitelists tostring but NOT tonumber, so a bare tonumber is nil here and crashes the shard the
	-- moment this 0.5s task fires. That only happens once a player is online (pause_when_empty masks
	-- it in any no-player load-smoke), which is why 2026.8b28 / v2026.8 shipped with the crash latent.
	local my_origin = GLOBAL.tonumber((GLOBAL.TheShard ~= nil and GLOBAL.TheShard:GetShardId()) or 0) or 0
	for _, v in ipairs(_G.AllPlayers) do
		local userid = v.userid
		if userid ~= nil and userid ~= "" then
			-- pack the boolean status into the codec's flag int (fire/overheat/freeze/dead;
			-- ghost is folded into dead here -- the badge only distinguishes alive vs dead).
			local flags = codec.packflags({
				fire     = (v.customonfire ~= nil and v.customonfire:value()) or false,
				overheat = (v.customoverheating ~= nil and v.customoverheating:value()) or false,
				freeze   = (v.customfreezing ~= nil and v.customfreezing:value()) or false,
				dead     = (v.customisdead ~= nil and v.customisdead:value()) or false,
			})
			records[#records + 1] = {
				userid         = userid,
				hp_cur         = (v.customhpbadgepercent ~= nil and v.customhpbadgepercent:value()) or 0,
				hp_max         = (v.customhpbadgemax ~= nil and v.customhpbadgemax:value()) or 0,
				hp_penalty     = (v.customhpbadgedebuff ~= nil and v.customhpbadgedebuff:value()) or 0,
				hunger         = (v.customhunger ~= nil and v.customhunger:value()) or 0,
				sanity_cur     = (v.customsanity ~= nil and v.customsanity:value()) or 0,
				sanity_max     = (v.customsanitymax ~= nil and v.customsanitymax:value()) or 0,
				sanity_penalty = (v.customsanitydebuff ~= nil and v.customsanitydebuff:value()) or 0,
				flags          = flags,
				origin         = my_origin,
			}
		end
	end
	return records
end

-- RECEIVE handler + RPC handle obtained at MOD-LOAD (top-level), NOT deferred. The shard mod RPC
-- namespace must be registered during mod init -- if you register it later (e.g. inside
-- AddSimPostInit) the engine can't encode the namespace on send and logs "Error encoding lua RPC
-- mod namespace", so the RPC silently never transmits. Registering a handler needs no TheWorld
-- (it just installs a callback that fires when an RPC arrives, which is after the worlds are up),
-- so it belongs here at load time. Only the SEND loop below needs TheWorld/TheShard.
-- The handler ONLY stores; it must NOT send a shard RPC (same-frame self-send is dropped).
GLOBAL.AddShardModRPCHandler(XSHARD_RPC_NAMESPACE, XSHARD_RPC_NAME, function(sender_shard_id, payload)
	local version, records = codec.decode(payload)
	if version == nil then
		-- `records` carries the decode error message on failure. Log + drop, never throw, so a
		-- version-skewed / garbled payload from a hot-reloaded peer can't crash the sim.
		print("[PartyHud] [XSHARD] dropped malformed payload from shard "
			.. tostring(sender_shard_id) .. ": " .. tostring(records))
		return
	end
	-- DEFENSIVE BACKFILL for a v1 peer mid-upgrade: v1 records decode with origin == nil. The sender
	-- is the shard those records came from, so stamp its id (numeric -- the handler's first arg) as
	-- their origin. A v2 sender already carries origin, so this is a no-op for the steady state.
	for _, rec in ipairs(records) do
		if rec.origin == nil then rec.origin = sender_shard_id end
	end
	crossshard.upsert(foreign_store, records, GLOBAL.GetTime())
	if DEBUG_XSHARD then
		print("[PartyHud] [XSHARD] recv " .. #records .. " records from shard " .. tostring(sender_shard_id))
	end
end)
local xshard_rpc_handle = GLOBAL.GetShardModRPC(XSHARD_RPC_NAMESPACE, XSHARD_RPC_NAME)

-- SEND loop: needs TheWorld/TheShard, which do NOT exist at modmain top-level (created during
-- PopulateWorld, BEFORE ModManager:SimPostInit -- gamelogic.lua), so it's deferred to
-- AddSimPostInit. ismastersim is true on BOTH shards, which is what we want (each shard sends its
-- own roster and receives the other's via the handler registered above).
AddSimPostInit(function()
	if GLOBAL.TheWorld == nil or not GLOBAL.TheWorld.ismastersim then return end
	-- ~2 Hz; for T3 sends UNCONDITIONALLY every tick (even an empty roster) so the transport can be
	-- proven headless with no players online. The dirty-coalescing / burst / keepalive cadence
	-- optimization is a LATER task (T6) -- intentionally not built here.
	GLOBAL.TheWorld:DoPeriodicTask(0.5, function()
		-- Recompute each tick so it resolves once TheShard is ready. tostring() is REQUIRED:
		-- Shard_GetConnectedShards() keys are STRINGS but GetShardId() returns a NUMBER, so without
		-- coercion `"1" ~= 1` is always true and the shard would fail to exclude itself (sending its
		-- own roster back to itself -> duplicate players in foreign_store under real multiplayer).
		local my_shard_id = GLOBAL.TheShard ~= nil and tostring(GLOBAL.TheShard:GetShardId()) or nil
		if my_shard_id == nil then return end -- shard id not resolvable yet; skip send AND publish this tick (foreign_store is still empty then, so the skipped publish is a no-op)
		local records = build_local_records()
		local payload = codec.encode(records)
		-- Shard_GetConnectedShards() is keyed by world/shard id. Send to each id that is NOT this
		-- shard and is currently available (gating avoids RPCs into a down shard). EXPLICIT target
		-- shard id -- a nil target leaks the RPC to clients (known bug).
		for world_id in pairs(GLOBAL.Shard_GetConnectedShards()) do
			if world_id ~= my_shard_id and GLOBAL.Shard_IsWorldAvailable(world_id) then
				GLOBAL.SendModRPCToShard(xshard_rpc_handle, world_id, payload)
				if DEBUG_XSHARD then
					print("[PartyHud] [XSHARD] sent " .. #records .. " records to shard " .. tostring(world_id))
				end
			end
		end
		-- STALE-ENTRY CLEANUP (before publishing). Two independent passes:
		--   (1) EXPIRE: age out entries no longer being refreshed -- catches a peer shard that
		--       CRASHED / stopped sending (its players stop refreshing and age past XSHARD_TTL).
		crossshard.expire(foreign_store, GLOBAL.GetTime(), XSHARD_TTL)
		--   (2) RECONCILE against the CLUSTER roster: drop any foreign player who has left the cluster
		--       entirely. TheNet:GetClientTable() is cluster-wide (covers BOTH shards), so it's the
		--       authoritative live set. Nil-guard it: if unavailable this tick, SKIP reconcile -- never
		--       reconcile against an empty set (that would wipe everything).
		if GLOBAL.TheNet ~= nil and GLOBAL.TheNet.GetClientTable ~= nil then
			local clienttable = GLOBAL.TheNet:GetClientTable()
			-- Guard BOTH nil AND empty: GetClientTable() can transiently return {} (e.g. mid-handshake),
			-- and reconcile against an empty live_set would wipe every foreign player for that tick
			-- (the badges flicker out and back ~0.5s later). The engine's own consumers guard `#t > 0`
			-- too (playerhistory.lua). expire() still runs independently, so a truly-gone peer is caught.
			if clienttable ~= nil and #clienttable > 0 then
				local live_set = {}
				for _, c in ipairs(clienttable) do
					if c.userid ~= nil and c.userid ~= "" then live_set[c.userid] = true end
				end
				crossshard.reconcile(foreign_store, live_set)
			end
		end
		-- HOP-2 PUBLISH: push the CURRENT foreign players (this shard's view of the OTHER shard's
		-- roster, accumulated by the receive handler) onto the carrier net_string so this shard's
		-- CLIENTS get them. crossshard.active() returns the cleaned, userid-sorted record array.
		-- net_string:set only transmits on an actual value change, so re-setting an unchanged blob
		-- each tick is cheap (no wire traffic). Nil-guard TheWorld.net + the netvar: the carrier is
		-- attached in AddPrefabPostInit which runs before the worlds finish coming up, but guard
		-- anyway so an unexpected ordering can never nil-index here.
		if GLOBAL.TheWorld.net ~= nil and GLOBAL.TheWorld.net.partyhud_foreignblob ~= nil then
			local foreign = crossshard.active(foreign_store)
			-- v2026.8 SAME-SHARD-FAR FIX: also merge THIS shard's own players (server's AllPlayers is
			-- shard-complete, unlike a client's view-range-limited AllPlayers) so a same-shard teammate
			-- out of network view-range still reaches every client via the carrier. `records` is the
			-- build_local_records() result already computed earlier this tick for the outbound RPC --
			-- REUSE it (do NOT rebuild). userid-deduped, LOCAL wins over a foreign copy of the same user
			-- (e.g. a player mid-migration briefly present in both sets).
			local merged, seen = {}, {}
			for _, r in ipairs(records) do            -- this shard's own players (server-complete AllPlayers)
				if r.userid ~= nil and r.userid ~= "" and not seen[r.userid] then
					seen[r.userid] = true
					merged[#merged + 1] = r
				end
			end
			for _, r in ipairs(foreign) do            -- other shards' players
				if r.userid ~= nil and not seen[r.userid] then
					seen[r.userid] = true
					merged[#merged + 1] = r
				end
			end
			GLOBAL.TheWorld.net.partyhud_foreignblob:set(codec.encode(merged))
			if DEBUG_XSHARD then
				print("[PartyHud] [XSHARD] published " .. #merged .. " records to carrier (" .. #foreign .. " foreign)")
			end
		end
	end)
end)

-- HOP-2 CARRIER: a net_string on the shard's network entity (TheWorld.net), which is ALWAYS
-- replicated to every client on the shard regardless of player view-range/shard (this is exactly how
-- the Global Positions mod attaches its component). The server :set()s the foreign-player blob onto
-- it from the periodic task above; clients decode it on dirty into client_foreign_records.
-- The net_string DECLARATION must be IDENTICAL on server AND client (same GUID, name, dirty event)
-- or deserialization fails -- so it is NOT guarded by ismastersim; only the client-side decode
-- listener is. forest_network is the surface carrier, cave_network the caves carrier; each shard has
-- exactly one of them and TheWorld.net points at it.
local function attach_carrier(inst)
	inst.partyhud_foreignblob = GLOBAL.net_string(inst.GUID, "partyhud.foreignblob", "partyhud_foreignblobdirty")
	if not GLOBAL.TheWorld.ismastersim then
		-- CLIENT: decode the blob into the client-side store whenever the server pushes a new one.
		-- Never throw on a bad/version-skewed blob -- log + keep the previous value, mirroring the
		-- server-side receive handler's fail-soft contract.
		inst:ListenForEvent("partyhud_foreignblobdirty", function()
			local blob = inst.partyhud_foreignblob:value()
			-- net_string starts nil before the server's first :set(); a connect-time sync can fire
			-- the dirty event with that nil. Skip it (codec.decode is nil-safe, but this avoids a
			-- spurious "malformed blob" log line before the first publish).
			if blob == nil or blob == "" then return end
			local version, records = codec.decode(blob)
			if version == nil then
				-- `records` carries the decode error message on failure here.
				print("[PartyHud] [XSHARD] client dropped malformed carrier blob: " .. tostring(records))
				return
			end
			client_foreign_records = records
			if DEBUG_XSHARD then
				print("[PartyHud] [XSHARD] client got " .. #records .. " foreign records")
			end
			-- A far teammate reaches this client ONLY via the blob -- there is no `playerentered` event
			-- for an out-of-view player -- so the blob update MUST itself drive a badge refresh, or the
			-- new foreign record never renders until some unrelated local event happens to fire
			-- UpdateBadges. (Same guarded accessor as the client refresh path elsewhere.)
			if _G.ThePlayer ~= nil and _G.ThePlayer.UpdateBadges ~= nil then
				_G.ThePlayer.UpdateBadges()
			end
		end)
	end
end
AddPrefabPostInit("forest_network", attach_carrier)
AddPrefabPostInit("cave_network", attach_carrier)
