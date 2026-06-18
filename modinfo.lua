name="PartyHud 2026"
description= "A DST mod that displays the health, hunger, sanity, on-fire and temperature (overheating/freezing) status of other players. Set Position and layout in config."
author="iblislin (DST 2026 port); original PartyHUD by brianchenito"
version="2026.9"
forumthread=""

api_version = 10-- the current version of the modding api




dont_starve_compatible = true
reign_of_giants_compatible = true
dst_compatible = true
all_clients_require_mod = true
client_only_mod = false
priority = -1000-- low priority mod, loads last ish
icon_atlas = "modicon.xml" -- for when we get custom icons
icon = "modicon.tex" -- some really bizzare binary encoding of an image, just send psds to brian or something

server_filter_tags = {"party hud"}

configuration_options=
{
	{
	name="layout",
	label="HUD Layout",
	hover="Choose the Layout of the health indicators",
	options={
			{description = "Horizontal", data = 1},
			{description = "Vertical", data = 2}
		},
	default=2,
	client = true,
	},
		{
	name="position",
	label="HUD Position",
	hover="Choose the placement of the health indicators. Minimap settings are compatible with Squeek's minimap HUD",
	options={
			{description = "Minimap", data = 0},
			{description = "Minimap XL", data = 1},
			{description = "Standard", data = 2}
		},
	default=2,
	client = true,
	},
		{
	name="show_self",
	label="Show Your Own Badge",
	hover="Show a badge for yourself too, or skip it (you already have your own status meters)",
	options={
			{description = "Show", data = 1},
			{description = "Skip", data = 0}
		},
	default=1,
	client = true,
	},
		{
	name="show_substatus",
	label="Hunger/Sanity Sub-gauges",
	hover="Show the small hunger and sanity rings on each badge, or hide them for a compact HP-only badge",
	options={
			{description = "Show", data = 1},
			{description = "Hide", data = 0}
		},
	default=1,
	client = true,
	},
		{
	name="hp_number",
	label="Teammate HP Number",
	hover="Show each teammate's HP number always, or only when you hover their badge",
	options={
			{description = "On hover", data = 0},
			{description = "Always", data = 1}
		},
	default=0,
	client = true,
	},
		{
	name="show_crossshard",
	label="Show Cross-Shard Teammates",
	hover="Show teammates who are on the other shard (Caves/Surface) or out of network range, via the always-replicated broadcast. Hide to render only locally-visible players",
	options={
			{description = "Show", data = 1},
			{description = "Hide", data = 0}
		},
	default=1,
	client = true,
	},
		{
	name="debug_showall",
	label="[Test] Show mock badges",
	hover="Fill empty slots with fake teammates to preview the HUD layout. Only you see this; it does not affect other players.",
	options={
			{description = "Off", data = 0},
			{description = "On", data = 1}
		},
	default=0,
	client = true,
	},
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
}