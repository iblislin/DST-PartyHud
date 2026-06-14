-- [PartyHud 2026 v2026.5] modernized fork of brianchenito/PartyHud v0.985.
-- Robustness pass: guarded HUD-refresh handlers, bounded + userid-stable badge mapping,
-- trailing-slot clearing, ghost-state seeding on (re)spawn/shard-migration, and removal of
-- the dead playerexited/customexitdelta path (onremove covers leave-refresh).
_G = GLOBAL

-- pulls setting for hud configs from modinfo
local layout=GetModConfigData("layout")
local positional=GetModConfigData("position")
local DEBUG_SHOWALL = false -- [TEST ONLY] fill all badge slots so layout is visible solo
-- [vertical layout tunables] edit these then restart client; only used when layout=Vertical
local VERT_X   = 0  -- horizontal pos (more negative = further left)
local VERT_Y   = -130  -- y of the FIRST (top) badge; lower number = lower on screen
local VERT_GAP = -90   -- gap between badges (negative = each next one goes DOWN, under the previous)

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

--constructor for badge array
local function onstatusdisplaysconstruct(self)

	self.badgearray = {}
	--instance one badge per slot
	for i = 1, GLOBAL.TheNet:GetDefaultMaxPlayers(), 1 do
		self.badgearray[i]=self:AddChild(phud_custombadge(self,self.owner))

		if layout==2 then
			--vertical: Minimap/XL use the phud anchor (same start as horizontal); Standard uses VERT_X/VERT_Y. Stacks down by VERT_GAP.
			local vx, vy = VERT_X, VERT_Y
			if positional==0 or positional==1 then vx, vy = phud_xpos, phud_ypos end
			self.badgearray[i]:SetPosition(vx, vy + VERT_GAP*(i-1), 0)
		else
			--horizontal row
			self.badgearray[i]:SetPosition(phud_xpos+(-70*i),phud_ypos,0)
		end
	end

	-- single authoritative refresh: bounded by badge count (no nil-index crash),
	-- stable userid ordering (no badge<->player desync), name+HP+visibility in one pass,
	-- trailing slots cleared (no stale departed-player names).
	self.owner.UpdateBadges = function()
		local maxbadges = #self.badgearray
		if DEBUG_SHOWALL then
			for i = 1, maxbadges do
				self.badgearray[i]:SetName("Player"..i)
				self.badgearray[i]:SetPercent(((i*17)%100)/100, 100, 0)
				self.badgearray[i]:ShowBadge()
			end
			return
		end
		local players = {}
		for _, v in ipairs(_G.AllPlayers) do players[#players+1] = v end
		table.sort(players, function(a, b) return (a.userid or "") < (b.userid or "") end)
		for i = 1, maxbadges do
			local b = self.badgearray[i]
			if b == nil then break end
			local v = players[i]
			if v == nil then
				b:HideBadge()
			else
				local isdead = (v.customisdead ~= nil and v.customisdead:value()) or false
				local percent = (v.customhpbadgepercent ~= nil and v.customhpbadgepercent:value()/100) or 0
				local maxhp = (v.customhpbadgemax ~= nil and v.customhpbadgemax:value()) or 0
				b:SetName(v:GetDisplayName())
				b:SetPercent(percent, maxhp, 0)
				if isdead then b:ShowDead() else b:ShowBadge() end
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
	local setpercent = data.newpercent and data.newpercent or 0
	inst.customhpbadgepercent:set(math.floor(setpercent * 100+0.5))
	inst.customhpbadgemax:set(inst.components.health:GetMaxWithPenalty())
	inst.customhpbadgedebuff:set(inst.components.health:GetPenaltyPercent())
	if inst:HasTag('playerghost') then
		inst.customisdead:set(true)
	end
end

local function ondeath(inst,data)
	inst.customisdead:set(true)
end

local function onrespawn(inst,data)
	inst.customisdead:set(false)
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
	-- per-entity netvars (byte 0-255 / bool); 3rd arg is the dirty-event name
	inst.customhpbadgepercent = GLOBAL.net_byte(inst.GUID, "customhpbadge.percent", "customhpbadgedirty")
	inst.customhpbadgemax = GLOBAL.net_byte(inst.GUID,"customhpbadge.max","customhpbadgedirty")
	inst.customhpbadgedebuff = GLOBAL.net_byte(inst.GUID,"customhpbadge.debuff","customhpbadgedirty")
	inst.customisdead = GLOBAL.net_bool(inst.GUID,"customhpbadge.isdead","ondeathdeltadirty")

	-- Server (master sim) reacts to health/death and updates the netvars
	if GLOBAL.TheWorld.ismastersim then
		inst:ListenForEvent("healthdelta", onhealthdelta)
		inst:ListenForEvent("respawnfromghost", onrespawn)
		inst:ListenForEvent("death", ondeath)

		-- seed dead/ghost state for players (re)spawning here, incl. ghosts arriving via shard migration
		if inst:HasTag("playerghost") or (inst.components.health ~= nil and inst.components.health:IsDead()) then
			inst.customisdead:set(true)
		end
		inst.components.health:DoDelta(0)
	end

	-- Clients react to netvar changes + refresh on any player removal (leave / migration teardown)
	if not GLOBAL.TheNet:IsDedicated() then
		inst:ListenForEvent("customhpbadgedirty", oncustomhpbadgedirty)
		inst:ListenForEvent("ondeathdeltadirty", ondeathdeltadirty)
		inst:ListenForEvent("onremove", function()
			if GLOBAL.TheWorld ~= nil then
				GLOBAL.TheWorld:DoTaskInTime(0.1, refresh_local_hud)
			end
		end)
	end
end
AddPlayerPostInit(customhppostinit)
