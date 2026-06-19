-- luacheck config for the PartyHud 2026 DST mod.
-- DST runs Lua 5.1 and injects mod-environment globals via the Klei mod loader.
std = "lua51"
max_line_length = false

-- Unused args / loop vars are idiomatic in DST event handlers (inst, data) -> don't flag.
ignore = {
  "212", -- unused argument
  "213", -- unused loop variable
}

-- Globals available in mod scope (injected by the game / mod loader).
read_globals = {
  "GLOBAL",
  "Class",
  "GetModConfigData",
  "AddClassPostConstruct",
  "AddPlayerPostInit",
  "AddPrefabPostInit",
  "AddComponentPostInit",
  "AddSimPostInit",
  "STRINGS",
  "BODYTEXTFONT", "TALKINGFONT", "TITLEFONT", "NEWFONT", "CHATFONT",
  "ANCHOR_MIDDLE", "ANCHOR_LEFT", "ANCHOR_RIGHT", "ANCHOR_TOP", "ANCHOR_BOTTOM",
  "Lerp", -- DST math global (mathutil.lua), injected into the mod env
  "DST_CHARACTERLIST", "MODCHARACTERLIST", "MOD_AVATAR_LOCATIONS", -- character lists / mod avatar dirs (avatar render)
  "GetPlayerBadgeData", "SetSkinsOnAnim", "GetSkinData", -- animated-head helpers (skinsutils / components/skinner)
  "FACING_DOWN", -- UIAnim facing constant (animated head)
  "Profile", -- client save-data global (Profile:GetAnimatedHeadsEnabled for the animated-head perf parity)
}

-- modmain.lua does `_G = GLOBAL`
globals = { "_G" }

-- modinfo.lua assigns the mod-metadata globals.
files["modinfo.lua"] = {
  globals = {
    "name", "author", "version", "description", "api_version",
    "dst_compatible", "dont_starve_compatible",
    "reign_of_giants_compatible", "shipwrecked_compatible",
    "hamlet_compatible", "forge_compatible", "gorge_compatible",
    "all_clients_require_mod", "client_only_mod",
    "priority", "server_filter_tags", "configuration_options",
    "icon", "icon_atlas", "forumthread", "folder_name",
    "mod_dependencies", "standalone",
  },
}
