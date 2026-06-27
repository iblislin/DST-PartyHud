name = "PartyHud 2026"
description =
  "A DST mod that displays the health, hunger, sanity, on-fire and temperature (overheating/freezing) status of other players. Set Position and layout in config."
author = "iblislin (DST 2026 port); original PartyHUD by brianchenito"
version = "2026.13csx12"
forumthread = ""

api_version = 10 -- the current version of the modding api

dont_starve_compatible = true
reign_of_giants_compatible = true
dst_compatible = true
all_clients_require_mod = true
client_only_mod = false
priority = -1000 -- low priority mod, loads last ish
icon_atlas = "modicon.xml" -- for when we get custom icons
icon = "modicon.tex" -- some really bizzare binary encoding of an image, just send psds to brian or something

server_filter_tags = { "party hud" }

configuration_options = {
  {
    name = "layout",
    label = "HUD Layout",
    hover = "Choose the Layout of the health indicators",
    options = {
      { description = "Horizontal", data = 1 },
      { description = "Vertical", data = 2 },
    },
    default = 2,
    client = true,
  },
  {
    name = "position",
    label = "HUD Position",
    hover = "Choose the placement of the health indicators. Minimap settings are compatible with Squeek's minimap HUD",
    options = {
      { description = "Minimap", data = 0 },
      { description = "Minimap XL", data = 1 },
      { description = "Standard", data = 2 },
    },
    default = 2,
    client = true,
  },
  {
    name = "show_self",
    label = "Show Your Own Badge",
    hover = "Show a badge for yourself too, or skip it (you already have your own status meters)",
    options = {
      { description = "Show", data = 1 },
      { description = "Skip", data = 0 },
    },
    default = 1,
    client = true,
  },
  {
    name = "show_substatus",
    label = "Hunger/Sanity Sub-gauges",
    hover = "Show the small hunger and sanity rings on each badge, or hide them for a compact HP-only badge",
    options = {
      { description = "Show", data = 1 },
      { description = "Hide", data = 0 },
    },
    default = 1,
    client = true,
  },
  {
    name = "hp_number",
    label = "Teammate HP Number",
    hover = "Show each teammate's HP number always, or only when you hover their badge",
    options = {
      { description = "On hover", data = 0 },
      { description = "Always", data = 1 },
    },
    default = 0,
    client = true,
  },
  {
    name = "show_crossshard",
    label = "Show Cross-Shard Teammates",
    hover = "Show teammates who are on the other shard (Caves/Surface) or out of network range, via the always-replicated broadcast. Hide to render only locally-visible players",
    options = {
      { description = "Show", data = 1 },
      { description = "Hide", data = 0 },
    },
    default = 1,
    client = true,
  },
  {
    name = "low_hp_alert",
    label = "Low-HP Alert",
    hover = "Blink a red border on a teammate's badge when their HP drops below this level (percent of their max HP). Off disables it.",
    options = {
      { description = "Off", data = 0 },
      { description = "40%", data = 40 },
      { description = "25%", data = 25 },
      { description = "15%", data = 15 },
    },
    default = 25,
    client = true,
  },
  {
    name = "avatar_style",
    label = "Teammate avatar",
    hover = "Show each teammate's character avatar on their badge. Corner is a small flat head in the badge corner; Centred head is the animated character face in the ring centre (HP number becomes hover-only).",
    options = {
      { description = "Off", data = 0 },
      { description = "Corner", data = 1 },
      { description = "Centred head", data = 2 },
    },
    default = 2,
    client = true,
  },
  {
    name = "name_colour",
    label = "Colour Teammate Names",
    hover = "Tint each teammate's name in their own player colour. Off keeps names plain white.",
    options = {
      { description = "On", data = 1 },
      { description = "Off", data = 0 },
    },
    default = 1,
    client = true,
  },
}

-- The "[Test] Show mock badges" option (debug_showall) is DEV-ONLY. Discriminator: a RELEASE version
-- is purely numeric + dots (e.g. "2026.13", "2026.14", a patch "2026.13.1"); a dev/beta/rc build carries
-- an ALPHABETIC suffix (e.g. "2026.14dev2", "2026.13rc1", "2026.12b1"). So "version contains a letter"
-- == dev build. (We use letter-presence rather than a "^%d+%.%d+$" shape so a patch release like
-- "2026.13.1" is still treated as a release. Assumes release tags stay letter-free, which our YYYY.N(.P)
-- convention guarantees.) This logic is busted-tested in scripts/partyhud_version.lua (is_dev_build);
-- modinfo can't require(), so the one-liner below MIRRORS it -- keep the two in sync. On a RELEASE
-- build we OMIT the option entirely, which both:
--   (1) HIDES it from the mod-config UI, so a player can't enable it by accident (the "mock HUD popup"
--       complaint = a teammate-less player who toggled this on and saw fake "PlayerN" badges), and
--   (2) FORCE-DISABLES it even for a player who previously turned it on: GetModConfigData is driven by
--       the configuration_options list, so an unknown option name returns nil (orphaned saved values
--       are never resurfaced) -> modmain's `GetModConfigData("debug_showall", true) == 1` is false.
-- Only dev/beta builds expose it (for our own layout preview). `version` is the global set at the top
-- of this same modinfo chunk.
if version:match("%a") ~= nil then
  configuration_options[#configuration_options + 1] = {
    name = "debug_showall",
    label = "[Test] Show mock badges",
    hover = "Fill empty slots with fake teammates to preview the HUD layout. Only you see this; it does not affect other players.",
    options = {
      { description = "Off", data = 0 },
      { description = "On", data = 1 },
    },
    default = 0,
    client = true,
  }
end
