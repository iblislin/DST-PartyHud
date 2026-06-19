-- spec/avatar_spec.lua — pure avatar / name-colour decision logic (partyhud_avatar)
local M = require("partyhud_avatar")

-- minimal fixtures mirroring the engine's DST_CHARACTERLIST / MODCHARACTERLIST / MOD_AVATAR_LOCATIONS
local DST = { "wilson", "willow", "wx78" }
local MODCHARS = { "fakemod" }
local MOD_LOC = { fakemod = "../mods/fakemod/", Default = "../mods/default/" }

describe("partyhud_avatar — classify", function()
  it("a base character -> 'base'", function()
    assert.are.equal("base", M.classify("wilson", DST, MODCHARS))
  end)

  it("'random' -> 'random' (treated like a real character for display)", function()
    assert.are.equal("random", M.classify("random", DST, MODCHARS))
  end)

  it("a registered mod character -> 'mod'", function()
    assert.are.equal("mod", M.classify("fakemod", DST, MODCHARS))
  end)

  it("a non-empty unregistered name -> 'unknown_named' (the generic mod head bucket)", function()
    -- characterutil.lua:82-84: a valid-but-unregistered name renders avatar_mod.tex
    assert.are.equal("unknown_named", M.classify("notamod", DST, MODCHARS))
  end)

  it("nil or empty prefab -> 'unknown'", function()
    assert.are.equal("unknown", M.classify(nil, DST, MODCHARS))
    assert.are.equal("unknown", M.classify("", DST, MODCHARS))
  end)
end)

describe("partyhud_avatar — atlas_and_tex", function()
  it("base char -> images/avatars.xml + avatar_<prefab>.tex", function()
    local atlas, tex = M.atlas_and_tex("wilson", "base", MOD_LOC)
    assert.are.equal("images/avatars.xml", atlas)
    assert.are.equal("avatar_wilson.tex", tex)
  end)

  it("'random' -> images/avatars.xml + avatar_random.tex", function()
    local atlas, tex = M.atlas_and_tex("random", "random", MOD_LOC)
    assert.are.equal("images/avatars.xml", atlas)
    assert.are.equal("avatar_random.tex", tex)
  end)

  it("registered mod char -> mod location atlas + avatar_<prefab>.tex", function()
    local atlas, tex = M.atlas_and_tex("fakemod", "mod", MOD_LOC)
    assert.are.equal("../mods/fakemod/avatar_fakemod.xml", atlas)
    assert.are.equal("avatar_fakemod.tex", tex)
  end)

  it("registered mod char with no specific MOD_AVATAR_LOCATIONS entry -> Default location", function()
    local atlas, tex = M.atlas_and_tex("othermod", "mod", MOD_LOC)
    assert.are.equal("../mods/default/avatar_othermod.xml", atlas)
    assert.are.equal("avatar_othermod.tex", tex)
  end)

  it("unknown_named -> images/avatars.xml + avatar_mod.tex (generic mod head, never crashes)", function()
    local atlas, tex = M.atlas_and_tex("notamod", "unknown_named", MOD_LOC)
    assert.are.equal("images/avatars.xml", atlas)
    assert.are.equal("avatar_mod.tex", tex)
  end)

  it("unknown -> images/avatars.xml + avatar_unknown.tex", function()
    local atlas, tex = M.atlas_and_tex(nil, "unknown", MOD_LOC)
    assert.are.equal("images/avatars.xml", atlas)
    assert.are.equal("avatar_unknown.tex", tex)
  end)

  it("nil mod_avatar_locations is tolerated for non-mod buckets", function()
    local atlas, tex = M.atlas_and_tex("wilson", "base", nil)
    assert.are.equal("images/avatars.xml", atlas)
    assert.are.equal("avatar_wilson.tex", tex)
  end)
end)

describe("partyhud_avatar — packidflags / unpackidflags", function()
  -- USERFLAGS bits (constants.lua:2381-2391): IS_GHOST=1, CHARACTER_STATE_1=4, _2=8, _3=32
  it("all false -> 0", function()
    assert.are.equal(0, M.packidflags({ ghost = false, state1 = false, state2 = false, state3 = false }))
  end)

  it("ghost only -> 1", function()
    assert.are.equal(1, M.packidflags({ ghost = true }))
  end)

  it("state1+state2+state3 -> 4+8+32 = 44", function()
    assert.are.equal(44, M.packidflags({ state1 = true, state2 = true, state3 = true }))
  end)

  it("ghost + all states -> 1+4+8+32 = 45", function()
    assert.are.equal(45, M.packidflags({ ghost = true, state1 = true, state2 = true, state3 = true }))
  end)

  it("unpack is the inverse of pack (round-trip)", function()
    for _, t in ipairs({
      { ghost = false, state1 = false, state2 = false, state3 = false },
      { ghost = true, state1 = false, state2 = false, state3 = false },
      { ghost = false, state1 = true, state2 = false, state3 = false },
      { ghost = true, state1 = true, state2 = true, state3 = true },
    }) do
      local n = M.packidflags(t)
      local u = M.unpackidflags(n)
      assert.are.equal(t.ghost or false, u.ghost)
      assert.are.equal(t.state1 or false, u.state1)
      assert.are.equal(t.state2 or false, u.state2)
      assert.are.equal(t.state3 or false, u.state3)
    end
  end)

  it("unpackidflags reads a raw engine userflags int (ignores IS_AFK=2 / IS_LOADING=16)", function()
    -- IS_GHOST(1) + IS_AFK(2) + IS_LOADING(16) = 19; we only care about ghost + the 3 states
    local u = M.unpackidflags(19)
    assert.is_true(u.ghost)
    assert.is_false(u.state1)
    assert.is_false(u.state2)
    assert.is_false(u.state3)
  end)

  it("nil flags table packs to 0", function()
    assert.are.equal(0, M.packidflags(nil))
  end)
end)

describe("partyhud_avatar — identity_changed", function()
  it("nil prev vs any new -> changed (first ever build)", function()
    assert.is_true(M.identity_changed(nil, { prefab = "wilson", idflags = 0, base_skin = "" }))
  end)

  it("identical prefab + idflags + base_skin -> NOT changed", function()
    local a = { prefab = "wilson", idflags = 0, base_skin = "wilson_none" }
    local b = { prefab = "wilson", idflags = 0, base_skin = "wilson_none" }
    assert.is_false(M.identity_changed(a, b))
  end)

  it("prefab differs -> changed", function()
    assert.is_true(M.identity_changed({ prefab = "wilson", idflags = 0 }, { prefab = "willow", idflags = 0 }))
  end)

  it("idflags differ (e.g. became ghost) -> changed", function()
    assert.is_true(M.identity_changed({ prefab = "wilson", idflags = 0 }, { prefab = "wilson", idflags = 1 }))
  end)

  it("base_skin differs -> changed", function()
    assert.is_true(
      M.identity_changed(
        { prefab = "wilson", idflags = 0, base_skin = "wilson_none" },
        { prefab = "wilson", idflags = 0, base_skin = "wilson_formal" }
      )
    )
  end)

  it("nil-vs-nil base_skin treated as equal", function()
    assert.is_false(M.identity_changed({ prefab = "wilson", idflags = 0 }, { prefab = "wilson", idflags = 0 }))
  end)
end)

describe("partyhud_avatar — resolve_avatar_style", function()
  -- config data ints (modinfo avatar_style dropdown): 0=Off, 1=Corner, 2=Centred head
  it("0 -> off", function()
    assert.are.equal("off", M.resolve_avatar_style(0))
  end)

  it("1 -> corner", function()
    assert.are.equal("corner", M.resolve_avatar_style(1))
  end)

  it("2 -> centre", function()
    assert.are.equal("centre", M.resolve_avatar_style(2))
  end)

  it("nil -> off (missing/older config defaults to off)", function()
    assert.are.equal("off", M.resolve_avatar_style(nil))
  end)

  it("unknown value -> off (never the dropped head-corner combo)", function()
    assert.are.equal("off", M.resolve_avatar_style(7))
    assert.are.equal("off", M.resolve_avatar_style(-1))
    assert.are.equal("off", M.resolve_avatar_style("corner")) -- wrong type -> off
  end)
end)

describe("partyhud_avatar — effective_avatar_style", function()
  -- The centre head covers the thermal (HP-rate) arrow, so a LOCAL teammate whose thermal is active
  -- temporarily renders as "corner" (head moves to the top-left inset) while configured as "centre".
  it("centre config + thermal active -> corner (head moves out of the way of the arrow)", function()
    assert.are.equal("corner", M.effective_avatar_style("centre", true))
  end)

  it("centre config + no thermal -> centre (the normal centred head)", function()
    assert.are.equal("centre", M.effective_avatar_style("centre", false))
  end)

  it("corner config + thermal active -> corner (config wins; no flip, centre is already clear)", function()
    assert.are.equal("corner", M.effective_avatar_style("corner", true))
  end)

  it("off config + thermal active -> off (never shows a head)", function()
    assert.are.equal("off", M.effective_avatar_style("off", true))
  end)

  it("nil config -> off (nil-tolerant default)", function()
    assert.are.equal("off", M.effective_avatar_style(nil, false))
    assert.are.equal("off", M.effective_avatar_style(nil, true))
  end)
end)

-- float-tolerant compare for the alpha arithmetic
local function near(a, b)
  return math.abs(a - b) <= 1e-9
end

describe("partyhud_avatar — avatar_head_geom", function()
  -- raw GetPlayerBadgeData values are tuned for the vanilla scoreboard (.8 parent + bigger frame);
  -- avatar_head_geom shrinks scale + y_offset proportionally by `fit` to fit PartyHud's smaller ring,
  -- then adds an absolute y_nudge. M.AVATAR_HEAD_FIT default = 0.6, M.AVATAR_HEAD_Y_NUDGE default = 0.
  it("default fit (0.6) is applied to both scale and y_offset when fit is nil", function()
    local s, yo = M.avatar_head_geom(0.23, -50)
    assert.is_true(near(s, 0.23 * 0.6)) -- 0.138
    assert.is_true(near(yo, -50 * 0.6)) -- -30 (y_nudge default 0)
  end)

  it("an explicit fit overrides the default for both scale and y_offset", function()
    local s, yo = M.avatar_head_geom(0.23, -50, 0.5)
    assert.is_true(near(s, 0.23 * 0.5)) -- 0.115
    assert.is_true(near(yo, -50 * 0.5)) -- -25
  end)

  it("y_nudge is added as an absolute (unscaled) offset after the proportional shrink", function()
    local s, yo = M.avatar_head_geom(0.23, -50, 0.5, 4)
    assert.is_true(near(s, 0.23 * 0.5)) -- nudge does NOT touch scale
    assert.is_true(near(yo, -50 * 0.5 + 4)) -- -25 + 4 = -21
  end)

  it("y_offset scales proportionally with fit (the bug: raw -50 overflows; fit pulls it in)", function()
    local _, yo_full = M.avatar_head_geom(0.23, -50, 1.0)
    local _, yo_half = M.avatar_head_geom(0.23, -50, 0.5)
    assert.is_true(near(yo_full, -50)) -- fit=1 is a no-op (matches raw engine value)
    assert.is_true(near(yo_half, -25)) -- half the fit -> half the offset
  end)

  it("nil base_scale / base_y_offset are treated as 0", function()
    local s, yo = M.avatar_head_geom(nil, nil, 0.6, 3)
    assert.is_true(near(s, 0)) -- 0 * 0.6
    assert.is_true(near(yo, 3)) -- 0 * 0.6 + 3
  end)

  it("explicit fit + explicit y_nudge with nil base inputs -> just the nudge on y, 0 on scale", function()
    local s, yo = M.avatar_head_geom(nil, nil, 0.5, -2)
    assert.is_true(near(s, 0))
    assert.is_true(near(yo, -2))
  end)
end)

describe("partyhud_avatar — name_colour", function()
  -- DEFAULT_PLAYER_COLOUR (constants.lua:1765) = RGB(153,153,153) = {0.6,0.6,0.6} GREY
  it("local player colour -> {r,g,b,1} (full opacity)", function()
    local c = M.name_colour({ 0.9, 0.2, 0.2, 1 }, false, 0.45)
    assert.is_true(near(c[1], 0.9))
    assert.is_true(near(c[2], 0.2))
    assert.is_true(near(c[3], 0.2))
    assert.is_true(near(c[4], 1))
  end)

  it("foreign player -> alpha scaled by foreign_dim, hue preserved", function()
    local c = M.name_colour({ 0.9, 0.2, 0.2, 1 }, true, 0.45)
    assert.is_true(near(c[1], 0.9))
    assert.is_true(near(c[2], 0.2))
    assert.is_true(near(c[3], 0.2))
    assert.is_true(near(c[4], 0.45)) -- 1 * foreign_dim
  end)

  it("foreign with an explicit input alpha -> input_alpha * foreign_dim", function()
    local c = M.name_colour({ 0.9, 0.2, 0.2, 0.8 }, true, 0.5)
    assert.is_true(near(c[4], 0.4)) -- 0.8 * 0.5
  end)

  it("nil colour -> GREY {0.6,0.6,0.6} at the right alpha (NOT white)", function()
    local c = M.name_colour(nil, false, 0.45)
    assert.is_true(near(c[1], 0.6))
    assert.is_true(near(c[2], 0.6))
    assert.is_true(near(c[3], 0.6))
    assert.is_true(near(c[4], 1))
  end)

  it("not-ready white {1,1,1,1} -> GREY (the join-order colour has not been assigned yet)", function()
    local c = M.name_colour({ 1, 1, 1, 1 }, false, 0.45)
    assert.is_true(near(c[1], 0.6))
    assert.is_true(near(c[2], 0.6))
    assert.is_true(near(c[3], 0.6))
    assert.is_true(near(c[4], 1))
  end)

  it("nil/white colour on a foreign badge -> GREY dimmed", function()
    local c = M.name_colour(nil, true, 0.45)
    assert.is_true(near(c[1], 0.6))
    assert.is_true(near(c[4], 0.45))
  end)

  it("a real grey-ish colour that is NOT pure white is kept (not coerced)", function()
    local c = M.name_colour({ 0.6, 0.6, 0.6, 1 }, false, 0.45)
    assert.is_true(near(c[1], 0.6)) -- already grey; unchanged
    assert.is_true(near(c[4], 1))
  end)
end)

describe("partyhud_avatar — is_low_contrast (optional)", function()
  -- true ONLY for the 3 low-luminance palette colours: BROWN, VIOLETRED, DARKPLUM
  it("BROWN-ish is low contrast", function()
    assert.is_true(M.is_low_contrast({ 0.5, 0.32, 0.18, 1 }))
  end)

  it("a bright warm colour is NOT low contrast", function()
    assert.is_false(M.is_low_contrast({ 0.9, 0.7, 0.2, 1 }))
  end)

  it("nil colour -> false (no decision)", function()
    assert.is_false(M.is_low_contrast(nil))
  end)
end)
