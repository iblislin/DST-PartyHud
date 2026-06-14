-- [PATCHED for DST 736959] ported to modern circular Badge widget.
-- Original (brianchenito/PartyHud v0.985, 2016) used Badge._ctor(self,"health",owner)
-- which loaded a now-renamed build ("health" -> "status_health") => invisible heart.
local Badge = require "widgets/badge"
local Text  = require "widgets/text"
local Image = require "widgets/image"

local HEALTHBADGE_TINT = { 174/255, 21/255, 21/255, 1 }

local PartyBadge = Class(Badge, function(self, owner)
    -- modern health badge: anim=nil -> status_meter path; iconbuild "status_health"
    -- overrides the heart icon onto the frame; red tint; dont_update_while_paused=true
    Badge._ctor(self, nil, owner, HEALTHBADGE_TINT, "status_health", nil, nil, true)

    -- player name label above the badge
    self.name = self:AddChild(Text(BODYTEXTFONT, 20))
    self.name:SetHAlign(ANCHOR_MIDDLE)
    self.name:SetPosition(0, 40, 0)
    self.name:SetString("--")

    -- dead indicator
    self.dead = self:AddChild(Image("images/hud.xml", "tab_arcane.tex"))
    self.dead:SetPosition(-10, 0, 0)
    self.dead:SetScale(0.7)
    self.dead:Hide()

    -- party badges always show the HP number (status badges hide it until hover)
    if self.num ~= nil then self.num:Show() end
end)

function PartyBadge:SetName(namestring)
    self.name:SetString(namestring)
end

-- val = current hp fraction (0..1), max = max hp
function PartyBadge:SetPercent(val, max, penaltypercent)
    Badge.SetPercent(self, val, max)
    if self.num ~= nil then self.num:Show() end
end

function PartyBadge:HideBadge()
    self:Hide()
end

function PartyBadge:ShowBadge()
    self:Show()
    if self.anim ~= nil then self.anim:Show() end
    if self.circleframe ~= nil then self.circleframe:Show() end
    if self.num ~= nil then self.num:Show() end
    self.name:Show()
    self.dead:Hide()
end

function PartyBadge:ShowDead()
    self:Show()
    if self.anim ~= nil then self.anim:Hide() end
    if self.circleframe ~= nil then self.circleframe:Hide() end
    if self.num ~= nil then self.num:Hide() end
    self.name:Show()
    self.dead:Show()
end

return PartyBadge
