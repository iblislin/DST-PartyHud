-- spec/record_spec.lua — pure record-normalization logic (partyhud_record)
local M = require("partyhud_record")

-- Helper: a complete `raw` table for normalize_local with sensible defaults; callers override fields.
local function localraw(over)
  local r = {
    isdead = false,
    hpcur = 100,
    maxhp = 150,
    hppenalty = 0,
    hunger = 80,
    hungermax = 150,
    sanity = 120,
    sanitymax = 200,
    sanitypenalty = 0,
    onfire = false,
    overheating = false,
    freezing = false,
    sanityrate = 0,
  }
  if over ~= nil then
    for k, v in pairs(over) do
      r[k] = v
    end
  end
  return r
end

-- Helper: a foreign codec record; callers override fields. To override a field TO nil (i.e. make it
-- absent, e.g. a record that carries no sanity_max), pass the NIL sentinel as its value -- a plain
-- nil in the `over` table is invisible to pairs() and would silently keep the base value.
local NIL = {}
local function foreignrec(over)
  local r = {
    userid = "KU_far",
    hp_cur = 90,
    hp_max = 150,
    hp_penalty = 0,
    hunger = 75,
    sanity_cur = 110,
    sanity_max = 200,
    sanity_penalty = 0,
    origin = 2,
  }
  if over ~= nil then
    for k, v in pairs(over) do
      r[k] = (v ~= NIL) and v or nil
    end
  end
  return r
end

describe("partyhud record — normalize_local", function()
  describe("hunger-max clamp", function()
    it("hungermax == 0 -> 100", function()
      assert.are.equal(100, M.normalize_local(localraw({ hungermax = 0 })).hungermax)
    end)
    it("hungermax negative -> 100", function()
      assert.are.equal(100, M.normalize_local(localraw({ hungermax = -5 })).hungermax)
    end)
    it("a positive hungermax passes through unchanged", function()
      assert.are.equal(150, M.normalize_local(localraw({ hungermax = 150 })).hungermax)
    end)
  end)

  describe("sanity-max clamp", function()
    it("sanitymax == 0 -> 100", function()
      assert.are.equal(100, M.normalize_local(localraw({ sanitymax = 0 })).sanitymax)
    end)
    it("sanitymax negative -> 100", function()
      assert.are.equal(100, M.normalize_local(localraw({ sanitymax = -1 })).sanitymax)
    end)
    it("a positive sanitymax passes through unchanged", function()
      assert.are.equal(200, M.normalize_local(localraw({ sanitymax = 200 })).sanitymax)
    end)
  end)

  describe("penalties pass straight through (already /100 by the caller's read)", function()
    -- the local read divides the netvar by 100 BEFORE building raw; normalize_local does not touch it.
    it("penalty 0 -> 0", function()
      local n = M.normalize_local(localraw({ hppenalty = 0, sanitypenalty = 0 }))
      assert.are.equal(0, n.hppenalty)
      assert.are.equal(0, n.sanitypenalty)
    end)
    it("penalty 0.25 -> 0.25", function()
      local n = M.normalize_local(localraw({ hppenalty = 0.25, sanitypenalty = 0.25 }))
      assert.are.equal(0.25, n.hppenalty)
      assert.are.equal(0.25, n.sanitypenalty)
    end)
    it("penalty 1.0 -> 1.0", function()
      local n = M.normalize_local(localraw({ hppenalty = 1.0, sanitypenalty = 1.0 }))
      assert.are.equal(1.0, n.hppenalty)
      assert.are.equal(1.0, n.sanitypenalty)
    end)
  end)

  describe("HP max is NOT clamped (WX-78 high max)", function()
    it("a 400-HP max passes through unchanged", function()
      assert.are.equal(400, M.normalize_local(localraw({ maxhp = 400 })).maxhp)
    end)
    it("hp current and a 0 max both pass through (no clamp on the HP ring inputs)", function()
      local n = M.normalize_local(localraw({ hpcur = 0, maxhp = 0 }))
      assert.are.equal(0, n.hpcur)
      assert.are.equal(0, n.maxhp) -- the badge's SetPercent owns the max<=0 -> 1 fallback, not this module
    end)
  end)

  describe("pass-through fields", function()
    it("preserves the live thermal flags + sanity rate + dead state verbatim", function()
      local n = M.normalize_local(localraw({
        onfire = true,
        overheating = true,
        freezing = true,
        sanityrate = 4,
        isdead = true,
      }))
      assert.is_true(n.onfire)
      assert.is_true(n.overheating)
      assert.is_true(n.freezing)
      assert.are.equal(4, n.sanityrate)
      assert.is_true(n.isdead)
    end)
    it("preserves hp/hunger/sanity current values", function()
      local n = M.normalize_local(localraw({ hpcur = 37, hunger = 12, sanity = 55 }))
      assert.are.equal(37, n.hpcur)
      assert.are.equal(12, n.hunger)
      assert.are.equal(55, n.sanity)
    end)
  end)
end)

describe("partyhud record — normalize_foreign", function()
  -- minimal flag tables (the dead state is the only flag normalize_foreign reads).
  local alive = { fire = false, overheat = false, freeze = false, dead = false }
  local dead = { fire = false, overheat = false, freeze = false, dead = true }

  describe("forces the live-only fields neutral (data is ~1s stale)", function()
    it("thermal flags forced false + sanity rate 0 even when set", function()
      -- pass flag table WITH every thermal bit true; normalize_foreign must still emit false/0
      -- (the foreign path never reads them; it only reads `dead`).
      local hot = { fire = true, overheat = true, freeze = true, dead = false }
      local n = M.normalize_foreign(foreignrec(), hot)
      assert.is_false(n.onfire)
      assert.is_false(n.overheating)
      assert.is_false(n.freezing)
      assert.are.equal(0, n.sanityrate)
    end)
  end)

  describe("hunger-max is HARD-CODED 100 (foreign records carry none)", function()
    it("a record with NO hunger-max field still yields hungermax 100", function()
      local n = M.normalize_foreign(foreignrec(), alive)
      assert.are.equal(100, n.hungermax)
    end)
    it("hunger-max stays 100 even if a hunger field is present at any value", function()
      local n = M.normalize_foreign(foreignrec({ hunger = 999 }), alive)
      assert.are.equal(100, n.hungermax)
    end)
  end)

  describe("sanity-max guard", function()
    it("a positive relayed sanity_max is used", function()
      assert.are.equal(200, M.normalize_foreign(foreignrec({ sanity_max = 200 }), alive).sanitymax)
    end)
    it("sanity_max == 0 -> 100", function()
      assert.are.equal(100, M.normalize_foreign(foreignrec({ sanity_max = 0 }), alive).sanitymax)
    end)
    it("sanity_max negative -> 100", function()
      assert.are.equal(100, M.normalize_foreign(foreignrec({ sanity_max = -5 }), alive).sanitymax)
    end)
    it("sanity_max nil -> 100", function()
      assert.are.equal(100, M.normalize_foreign(foreignrec({ sanity_max = NIL }), alive).sanitymax)
    end)
  end)

  describe("penalty /100 rescale (relayed as a 0..100 integer)", function()
    it("hp_penalty 25 -> 0.25, sanity_penalty 25 -> 0.25", function()
      local n = M.normalize_foreign(foreignrec({ hp_penalty = 25, sanity_penalty = 25 }), alive)
      assert.are.equal(0.25, n.hppenalty)
      assert.are.equal(0.25, n.sanitypenalty)
    end)
    it("hp_penalty 100 -> 1.0", function()
      assert.are.equal(1.0, M.normalize_foreign(foreignrec({ hp_penalty = 100 }), alive).hppenalty)
    end)
    it("nil penalties -> 0 (default-then-divide)", function()
      local n = M.normalize_foreign(foreignrec({ hp_penalty = NIL, sanity_penalty = NIL }), alive)
      assert.are.equal(0, n.hppenalty)
      assert.are.equal(0, n.sanitypenalty)
    end)
  end)

  describe("current-value pass-through + nil hp_cur default", function()
    it("hp_cur / hunger / sanity_cur / hp_max pass through", function()
      local n = M.normalize_foreign(foreignrec({ hp_cur = 42, hunger = 8, sanity_cur = 33, hp_max = 250 }), alive)
      assert.are.equal(42, n.hpcur)
      assert.are.equal(8, n.hunger)
      assert.are.equal(33, n.sanity)
      assert.are.equal(250, n.maxhp)
    end)
    it("nil hp_cur -> 0 (matches `rec.hp_cur or 0`)", function()
      assert.are.equal(0, M.normalize_foreign(foreignrec({ hp_cur = NIL }), alive).hpcur)
    end)
  end)

  describe("dead state comes from the flags table, not rec", function()
    it("flags.dead true -> isdead true", function()
      assert.is_true(M.normalize_foreign(foreignrec(), dead).isdead)
    end)
    it("flags.dead false -> isdead false", function()
      assert.is_false(M.normalize_foreign(foreignrec(), alive).isdead)
    end)
  end)
end)

describe("partyhud record — local-vs-foreign hunger-max divergence (intended)", function()
  -- This is the load-bearing behavioural difference between the two paths, pinned here so a future
  -- "unify the two functions" refactor that erases it fails loudly.
  it("local DEFAULTS-then-CLAMPS hunger-max; foreign HARD-CODES 100", function()
    -- local: a real positive hunger-max survives (e.g. 150).
    assert.are.equal(150, M.normalize_local(localraw({ hungermax = 150 })).hungermax)
    -- local: a 0/negative hunger-max clamps up to 100.
    assert.are.equal(100, M.normalize_local(localraw({ hungermax = 0 })).hungermax)
    -- foreign: ALWAYS 100, regardless of any field on the record (records carry no hunger-max).
    assert.are.equal(100, M.normalize_foreign(foreignrec(), { dead = false }).hungermax)
  end)
end)

describe("partyhud_record — temp/moisture passthrough", function()
  it("normalize_local carries temp + moisture", function()
    local n = M.normalize_local(localraw({ temp = 12, temp_rate = -1, moisture = 30, moisture_rate = 1 }))
    assert.are.equal(12, n.temp)
    assert.are.equal(-1, n.temp_rate)
    assert.are.equal(30, n.moisture)
    assert.are.equal(1, n.moisture_rate)
  end)
  it("normalize_foreign carries temp + moisture but forces thermal flags off", function()
    local n = M.normalize_foreign(foreignrec({ temp = 72, moisture = 80 }), { dead = false })
    assert.are.equal(72, n.temp)
    assert.are.equal(80, n.moisture)
    assert.is_false(n.onfire)
    assert.is_false(n.overheating)
    assert.is_false(n.freezing)
  end)
end)
