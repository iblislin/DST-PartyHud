-- [PATCHED for DST 736959] ported to modern circular Badge widget.
-- Original (brianchenito/PartyHud v0.985, 2016) used Badge._ctor(self,"health",owner)
-- which loaded a now-renamed build ("health" -> "status_health") => invisible heart.
-- v2026.6: added hunger/sanity sub-rings (status_hunger gold, status_sanity orange) in a
-- small row below the main HP ring, plus an on-fire warning pulse on the main ring.
local Badge = require "widgets/badge"
local Text  = require "widgets/text"
local Image = require "widgets/image"
local UIAnim = require "widgets/uianim"

-- canonical DST badge tints (from widgets/healthbadge.lua, hungerbadge.lua, sanitybadge.lua):
-- health red, hunger gold, sanity ORANGE (the blue {191,232,240} is the lunacy variant, not normal sanity)
local HEALTHBADGE_TINT = { 174/255, 21/255, 21/255, 1 }
local HUNGER_TINT      = { 255/255, 204/255, 51/255, 1 }
local SANITY_TINT      = { 232/255, 123/255, 15/255, 1 }
-- main-ring warning-pulse colours, by priority (a player can't be in two of these at once)
local ONFIRE_TINT      = { 1, 0.45, 0, 1 }    -- on fire (orange)
local OVERHEAT_TINT    = { 1, 0.1, 0.1, 1 }   -- overheating (red)
local FREEZE_TINT      = { 0.4, 0.8, 1, 1 }   -- freezing (cyan)

-- sanity rate (RATE_SCALE enum) -> sanity_arrow animation; NEUTRAL(0) shows no arrow
local SANITY_RATE_ANIM = {
    [1] = "arrow_loop_increase_most",  -- INCREASE_HIGH
    [2] = "arrow_loop_increase_more",  -- INCREASE_MED
    [3] = "arrow_loop_increase",       -- INCREASE_LOW
    [4] = "arrow_loop_decrease_most",  -- DECREASE_HIGH
    [5] = "arrow_loop_decrease_more",  -- DECREASE_MED
    [6] = "arrow_loop_decrease",       -- DECREASE_LOW
}

-- sub-ring layout (relative to the main HP ring at 0,0)
local SUB_SCALE = 0.5
local SUB_Y     = -42
local SUB_X     = 17

local PartyBadge = Class(Badge, function(self, owner)
    -- modern health badge: anim=nil -> status_meter path; iconbuild "status_health"
    -- overrides the heart icon onto the frame; red tint; dont_update_while_paused=true
    Badge._ctor(self, nil, owner, HEALTHBADGE_TINT, "status_health", nil, nil, true)

    -- player name label above the badge
    self.name = self:AddChild(Text(BODYTEXTFONT, 20))
    self.name:SetHAlign(ANCHOR_MIDDLE)
    self.name:SetPosition(0, 40, 0)
    self.name:SetString("--")

    -- v2026.6 hunger sub-ring (gold), below-left of the main ring.
    -- Its absolute number is shown only on hover (default Badge focus behaviour).
    self.hungerbadge = self:AddChild(Badge(nil, owner, HUNGER_TINT, "status_hunger", nil, nil, true))
    self.hungerbadge:SetScale(SUB_SCALE)
    self.hungerbadge:SetPosition(-SUB_X, SUB_Y, 0)

    -- v2026.6 sanity sub-ring (orange), below-right of the main ring
    self.sanitybadge = self:AddChild(Badge(nil, owner, SANITY_TINT, "status_sanity", nil, nil, true))
    self.sanitybadge:SetScale(SUB_SCALE)
    self.sanitybadge:SetPosition(SUB_X, SUB_Y, 0)

    -- v2026.6 sanity rate arrow (mirrors the game's sanity gauge up/down indicator)
    -- centered on the sanity sub-ring (child of it), mirroring the game's sanity gauge arrow
    self.sanityarrow = self.sanitybadge:AddChild(UIAnim())
    self.sanityarrow:GetAnimState():SetBank("sanity_arrow")
    self.sanityarrow:GetAnimState():SetBuild("sanity_arrow")
    self.sanityarrow:GetAnimState():PlayAnimation("neutral")
    self.sanityarrow:GetAnimState():AnimateWhilePaused(false)
    self.sanityarrow:SetClickable(false)
    self.sanityarrow:SetPosition(0, 0, 0)
    self.sanityarrow:Hide()
    self.sanityarrow_cur = nil

    -- dead indicator
    self.dead = self:AddChild(Image("images/hud.xml", "tab_arcane.tex"))
    self.dead:SetPosition(-10, 0, 0)
    self.dead:SetScale(0.7)
    self.dead:Hide()

    -- whether the hunger/sanity sub-rings are shown (driven by the show_substatus config)
    self.subvisible = true

    -- HP number visibility flag (client config hp_number); real value applied via
    -- SetHPNumberAlways right after construct. Default true = always shown.
    self.hp_number_always = true
end)

-- Toggle the hunger/sanity sub-rings on/off (client config show_substatus). When disabled,
-- the badge collapses to the HP-only layout: both sub-rings + their numbers are hidden now.
function PartyBadge:SetSubGauges(enabled)
    self.subvisible = enabled
    if enabled then
        self.hungerbadge:Show()
        self.sanitybadge:Show()
    else
        self.hungerbadge:Hide()
        self.sanitybadge:Hide()
        self.sanityarrow:Hide()
        self.sanityarrow_cur = nil
    end
end

-- Whether the main HP number is always shown, or only on hover (client config hp_number).
-- The HP ring fill is always visible either way; this only gates the number.
function PartyBadge:SetHPNumberAlways(always)
    self.hp_number_always = always
    if self.num ~= nil then
        if always then self.num:Show() else self.num:Hide() end
    end
end

function PartyBadge:SetName(namestring)
    self.name:SetString(namestring)
end

-- cur = current HP (absolute), max = max HP
function PartyBadge:SetPercent(cur, max, penaltypercent)
    local m = (max ~= nil and max > 0) and max or 1
    Badge.SetPercent(self, cur / m, max)
    if self.num ~= nil then
        self.num:SetString(tostring(math.floor((cur or 0) + 0.5)))
        if self.hp_number_always then self.num:Show() end
    end
end

-- v2026.6: hunger_cur/sanity_cur are absolute current values (the displayed number);
-- *_max give the absolute scale. The ring fill is computed from cur/max, and the sub-ring
-- number reads as the in-game absolute value (e.g. 113/150 -> "113"), matching the HP badge
-- and the game's own meters instead of a 0-100 percent.
-- onfire/overheating/freezing are bools -> a colour-coded warning pulse on the main HP
-- ring, by priority (mutually exclusive in practice). Sub-rings hide their number until hover.
function PartyBadge:SetStatus(hunger_cur, hunger_max, sanity_cur, sanity_max, onfire, overheating, freezing)
    -- only update the sub-rings when enabled; the on-fire/overheat/freeze pulse on the main
    -- ring runs regardless (handled below). Sub-ring numbers stay hidden until hover.
    if self.subvisible then
        local hm = (hunger_max ~= nil and hunger_max > 0) and hunger_max or 1
        local sm = (sanity_max ~= nil and sanity_max > 0) and sanity_max or 1
        self.hungerbadge:SetPercent((hunger_cur or 0) / hm, hunger_max or 100)
        self.sanitybadge:SetPercent((sanity_cur or 0) / sm, sanity_max or 100)
        if self.hungerbadge.num ~= nil then self.hungerbadge.num:SetString(tostring(math.floor((hunger_cur or 0) + 0.5))) end
        if self.sanitybadge.num ~= nil then self.sanitybadge.num:SetString(tostring(math.floor((sanity_cur or 0) + 0.5))) end
    end

    local tint = (onfire and ONFIRE_TINT)
        or (overheating and OVERHEAT_TINT)
        or (freezing and FREEZE_TINT)
        or nil
    if tint ~= nil then
        self:StartWarning(unpack(tint)) -- StartWarning re-applies the colour each call
    else
        self:StopWarning()
    end
end

-- ratescale = RATE_SCALE enum (0 neutral / 1-3 increase / 4-6 decrease). Hidden when neutral
-- or when the sub-gauges are disabled.
function PartyBadge:SetSanityRate(ratescale)
    local anim = (self.subvisible and ratescale ~= nil) and SANITY_RATE_ANIM[ratescale] or nil
    if anim == nil then
        self.sanityarrow:Hide()
        self.sanityarrow_cur = nil
        return
    end
    if self.sanityarrow_cur ~= anim then
        self.sanityarrow_cur = anim
        self.sanityarrow:GetAnimState():PlayAnimation(anim, true)
    end
    self.sanityarrow:Show()
end

function PartyBadge:HideBadge()
    self:Hide()
end

function PartyBadge:ShowBadge()
    self:Show()
    if self.anim ~= nil then self.anim:Show() end
    if self.circleframe ~= nil then self.circleframe:Show() end
    if self.num ~= nil and self.hp_number_always then self.num:Show() end
    self.name:Show()
    -- only reveal the sub-rings when they're enabled (their numbers stay hover-only)
    if self.subvisible then
        self.hungerbadge:Show()
        self.sanitybadge:Show()
    else
        self.hungerbadge:Hide()
        self.sanitybadge:Hide()
    end
    self.dead:Hide()
end

function PartyBadge:ShowDead()
    self:Show()
    if self.anim ~= nil then self.anim:Hide() end
    if self.circleframe ~= nil then self.circleframe:Hide() end
    if self.num ~= nil then self.num:Hide() end
    self.name:Show()
    self.hungerbadge:Hide()
    self.sanitybadge:Hide()
    self.sanityarrow:Hide()
    self.sanityarrow_cur = nil
    self:StopWarning()
    self.dead:Show()
end

return PartyBadge
