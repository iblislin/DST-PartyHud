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
local DEBUG_SHOWALL = false -- [TEST ONLY] fill all badge slots so layout is visible solo
-- [vertical layout tunables] edit these then restart client; only used when layout=Vertical
local VERT_X    = 0    -- horizontal pos (more negative = further left)
local VERT_Y    = -130 -- y of the FIRST (top) badge; lower number = lower on screen
local VERT_GAP  = -120 -- gap between badges (negative = each next one goes DOWN; sized so a badge's
                       -- name no longer overlaps the hunger/sanity sub-rings of the badge above)
local VERT_GAP_COMPACT = -90 -- tighter gap for the HP-only (no sub-rings) badge; pre-sub-ring spacing
local VERT_COL_W = 80  -- horizontal spacing when the column wraps to a new one (see compute_percol)
local VERT_BOTTOM_RESERVE = 190 -- badge-local units kept clear at the bottom for the game's map(M)
                                -- button. FIXED (not per-row): the compact gap is tighter, so a
                                -- per-row reserve would pack an extra badge into the button. Larger
                                -- = wraps a column one badge sooner.

--imports partybadge
local phud_custombadge= _G.require "widgets/partybadge"
local phud_xpos
local phud_ypos

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
-- itself under topleft_root (scaled by TheFrontEnd:GetHUDScale()), so the visible height
-- in badge-local units = screenheight / (hudscale * 1.4). Detect it so small screens /
-- large HUD-size settings wrap to a second column instead of overflowing off-screen.
local function compute_percol(vy)
	local scrnh
	if GLOBAL.TheSim ~= nil and GLOBAL.TheSim.GetScreenSize ~= nil then
		local _, h = GLOBAL.TheSim:GetScreenSize()
		scrnh = h
	end
	local hudscale = 1
	if GLOBAL.TheFrontEnd ~= nil and GLOBAL.TheFrontEnd.GetHUDScale ~= nil then
		hudscale = GLOBAL.TheFrontEnd:GetHUDScale() or 1
	end
	if scrnh == nil or scrnh <= 0 or hudscale <= 0 then
		if DEBUG_SHOWALL then
			print("[PartyHud DEBUG] compute_percol fallback: scrnh="..tostring(scrnh).." hudscale="..tostring(hudscale))
		end
		return 6 -- safe fallback if the screen/HUD scale can't be read
	end
	local STATUS_SCALE = 1.4               -- statusdisplays default scale (controls.lua:155)
	local usable = scrnh / (hudscale * STATUS_SCALE)
	local vgap = show_substatus and VERT_GAP or VERT_GAP_COMPACT -- effective gap (tighter when sub-rings hidden)
	local rowpitch = -vgap                 -- positive distance between rows
	-- reserve a FIXED keep-out zone at the bottom for the game's map (M) button. It must be a
	-- fixed absolute distance, NOT the row pitch: the compact (sub-gauges off) gap is tighter, so
	-- a per-row reserve packs an extra badge into the button. Fixed keeps equal clearance in both modes.
	local bottom_reserve = VERT_BOTTOM_RESERVE
	-- last visible row: badge origin minus ~60 (its sub-ring bottom) must stay above the
	-- reserved bottom zone.
	local n = math.floor((vy - 60 + usable - bottom_reserve) / rowpitch) + 1
	if n < 1 then n = 1 end
	if DEBUG_SHOWALL then
		print(string.format("[PartyHud DEBUG] scrnh=%.0f hudscale=%.3f usable=%.0f vy=%.0f gap=%.0f per_col=%d",
			scrnh, hudscale, usable, vy, vgap, n))
	end
	return n
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
	local per_col = compute_percol(vstarty)
	for i = 1, #badgearray do
		local col = math.floor((i-1)/per_col)
		local row = (i-1) % per_col
		badgearray[i]:SetPosition(vstartx - VERT_COL_W*col, vstarty + vgap*row, 0)
	end
end

--constructor for badge array
local function onstatusdisplaysconstruct(self)

	self.badgearray = {}
	--instance one badge per slot
	for i = 1, GLOBAL.TheNet:GetDefaultMaxPlayers(), 1 do
		self.badgearray[i]=self:AddChild(phud_custombadge(self,self.owner))
		self.badgearray[i]:SetSubGauges(show_substatus) -- apply the sub-gauge config at construct time
		self.badgearray[i]:SetHPNumberAlways(hp_number_always)
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
			if GLOBAL.TheWorld ~= nil then
				GLOBAL.TheWorld:DoTaskInTime(0.1, function()
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
				b:SetName(v:GetDisplayName())
				b:SetPercent(hpcur, maxhp, hppenalty)
				b:SetStatus(hunger, hungermax, sanity, sanitymax, onfire, overheating, freezing, sanitypenalty)
				local sanityrate = (v.customsanityrate ~= nil and v.customsanityrate:value()) or 0
				b:SetSanityRate(sanityrate)
				if isdead then b:ShowDead() else b:ShowBadge() end
			elseif DEBUG_SHOWALL and i <= visible_cap then
				-- [TEST ONLY] empty seat -> mock placeholder so the full layout stays visible
				b:SetName("Player"..i)
				b:SetPercent((i*17)%150, 150, (i % 3 == 0) and 0.25 or 0)
				b:SetStatus((i*23)%150, 150, (i*41)%200, 200, (i%4)==0, (i%4)==1, (i%4)==2, (i % 3 == 0) and 0.25 or 0)
				b:SetSanityRate((i*5)%7)
				b:ShowBadge()
			else
				b:HideBadge()
			end
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
