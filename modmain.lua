-- [PATCHED for DST 736959] fix1: dctoggle->customexitdelta (crash on playerexit); fix2: removed debug print. See PartyHUD orig brianchenito/PartyHud v0.985.
_G = GLOBAL
--_G.CHEATS_ENABLED = true--disable for push to live
--_G.require( 'debugkeys' )--disable for push to live

--print(AllPlayers[1]:HasTag("playerghost"))

--AllPlayers[1]:PushEvent("respawnfromghost")
--print(AllPlayers[1].components.health:IsDead())


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
local phud_xpos=0
local phud_ypos=0

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


--local scale=_G
--constructor for badge array
local function onstatusdisplaysconstruct(self)

	self.badgearray = {}
		--instance badges for players. 
	for i = 1, GLOBAL.TheNet:GetDefaultMaxPlayers(), 1 do
		self.badgearray[i]=self:AddChild(phud_custombadge(self,self.owner))
		
		if layout==2 then
			--[patched] vertical: anchor follows position. Minimap/XL use the same phud anchor as horizontal; Standard uses VERT_X/VERT_Y. Stacks down by VERT_GAP.
			local vx, vy = VERT_X, VERT_Y
			if positional==0 or positional==1 then vx, vy = phud_xpos, phud_ypos end
			self.badgearray[i]:SetPosition(vx, vy + VERT_GAP*(i-1), 0)
		else
			--horizontal row
			self.badgearray[i]:SetPosition(phud_xpos+(-70*i),phud_ypos,0)
		end
	end

	self.owner.UpdateBadgeVisibility = function()
		if DEBUG_SHOWALL then
			for i = 1, GLOBAL.TheNet:GetDefaultMaxPlayers(), 1 do
				self.badgearray[i]:SetName("Player"..i)
				self.badgearray[i]:SetPercent(((i*17)%100)/100, 100, 0)
				self.badgearray[i]:ShowBadge()
			end
			return
		end
		for i = 1, GLOBAL.TheNet:GetDefaultMaxPlayers(), 1 do
			self.badgearray[i]:HideBadge()
			--self.badgearray[i]:ShowBadge()

		end
		for i, v in ipairs(_G.AllPlayers) do
			local isdead = (v.customisdead and v.customisdead:value() or false)

-- [patched] 			print("Player "..tostring(i).." Should be "..tostring(isdead).." bruh")
			if isdead==true then 
				self.badgearray[i]:ShowDead()
			else
				self.badgearray[i]:ShowBadge()
			end

		end
	end


	--call upon any player healthdelta
	self.owner.UpdateBadges= function()
		if DEBUG_SHOWALL then GLOBAL.ThePlayer.UpdateBadgeVisibility() return end
		--update badges
		for i, v in ipairs(_G.AllPlayers) do
			local percent = v.customhpbadgepercent and (v.customhpbadgepercent:value())/100 or 0
			local max = v.customhpbadgemax and v.customhpbadgemax:value() or 0
			local debuff = v.customhpbadgedebuff and v.customhpbadgedebuff:value() or 0
			self.badgearray[i]:SetPercent(percent,max,0)
			self.badgearray[i]:SetName(v:GetDisplayName())
		end
		GLOBAL.ThePlayer.UpdateBadgeVisibility()
	end


end

-- Apply function on construction of class statusdisplays
AddClassPostConstruct("widgets/statusdisplays", onstatusdisplaysconstruct)

--server functions
local function onhealthdelta(inst, data)
	--get health of char
	local setpercent = data.newpercent and data.newpercent or 0
	inst.customhpbadgepercent:set(math.floor(setpercent * 100+0.5))--potatoey rounding to push shorts
	--get max health of char
	inst.customhpbadgemax:set(inst.components.health:GetMaxWithPenalty())
	--get debuff of char health
	inst.customhpbadgedebuff:set(inst.components.health:GetPenaltyPercent())
	-- forcible is dead check
	if(inst:HasTag('playerghost')) then
	inst.customisdead:set(true)
	end
end

local function ondisconnect(inst,data)
	inst.customexitdelta:set(true)
end

local function ondeath(inst,data)
	inst.customisdead:set(true)
end

local function onrespawn(inst,data)
	inst.customisdead:set(false)
end

--network functions


-- When somebody's health changes, it triggers the badges health update
local function oncustomhpbadgedirty(inst)
	GLOBAL.ThePlayer.UpdateBadges()
end

--when someone dies or revives, it triggers badge visibility toggle
local function ondeathdeltadirty(inst)
	GLOBAL.ThePlayer.UpdateBadgeVisibility()
end
--when someone leaves the server, it triggers badge visibility toggle
local function ondiconnectdirty( inst )
	GLOBAL.ThePlayer.UpdateBadgeVisibility()
end

local function customhppostinit(inst)
	-- Net variable that stores between 0-255; more info in netvars.lua
	-- GUID of entity, unique identifier of variable, event pushed when variable changes
	-- Event is pushed to the entity it refers to, server and client side wise

	inst.customhpbadgepercent = GLOBAL.net_byte(inst.GUID, "customhpbadge.percent", "customhpbadgedirty")
	inst.customhpbadgemax = GLOBAL.net_byte(inst.GUID,"customhpbadge.max","customhpbadgedirty")
	inst.customhpbadgedebuff = GLOBAL.net_byte(inst.GUID,"customhpbadge.debuff","customhpbadgedirty")
	inst.customisdead=GLOBAL.net_bool(inst.GUID,"customhpbadge.isdead","ondeathdeltadirty")
	inst.customexitdelta=GLOBAL.net_bool(inst.GUID,"customhpbadge.dctoggle","ondiconnectdirty")


	-- Server (master simulation) reacts to health and changes the net variable
	if GLOBAL.TheWorld.ismastersim then
		inst:ListenForEvent("healthdelta", onhealthdelta)
		inst:ListenForEvent("respawnfromghost", onrespawn)
		inst:ListenForEvent("death", ondeath)
		inst:ListenForEvent("playerexited",ondisconnect, GLOBAL.TheWorld)

		inst.components.health:DoDelta(0)

	end

	-- Dedicated server is dummy player, only players hosting or clients have the badges
	-- Only them react to the event pushed when the net variable changes
	if not GLOBAL.TheNet:IsDedicated() then
		inst:ListenForEvent("customhpbadgedirty", oncustomhpbadgedirty)
		inst:ListenForEvent("ondeathdeltadirty", ondeathdeltadirty)
		inst:ListenForEvent("ondiconnectdirty",ondiconnectdirty)
	end
end
-- Apply function on player entity post initialization
AddPlayerPostInit(customhppostinit)