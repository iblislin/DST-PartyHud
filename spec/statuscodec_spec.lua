-- spec/statuscodec_spec.lua
--
-- busted unit tests for the v2026.8 cross-shard status codec (Tier-0 spike).
-- Real busted syntax -- runs in CI via dstmodders/action (`busted spec/`), and locally via
-- spec/run_local.lua on plain luajit/lua when busted isn't installed.

local codec = require("partyhud_statuscodec")

local function sample(n)
  local recs = {}
  for i = 1, n do
    recs[i] = {
      userid = "KU_test" .. i,
      hp_cur = 100 + i,
      hp_max = 150,
      hp_penalty = (i % 2 == 0) and 25 or 0,
      hunger = 80 + i,
      sanity_cur = 120 + i,
      sanity_max = 200,
      sanity_penalty = (i % 3 == 0) and 50 or 0,
      flags = 0,
      -- origin (numeric shard id) is part of the v2 wire format (the current default
      -- PROTOCOL_VERSION), so the default-version round-trip preserves it exactly.
      origin = (i % 2 == 0) and 2 or 1,
    }
  end
  return recs
end

describe("partyhud status codec", function()
  describe("round-trip", function()
    it("preserves a single record exactly", function()
      local recs = sample(1)
      local ver, out = codec.decode(codec.encode(recs))
      assert.are.equal(codec.PROTOCOL_VERSION, ver)
      assert.are.same(recs, out)
    end)

    it("preserves multiple records (prod N=6)", function()
      local recs = sample(6)
      local ver, out = codec.decode(codec.encode(recs))
      assert.are.equal(codec.PROTOCOL_VERSION, ver)
      assert.are.same(recs, out)
    end)

    it("preserves the modded ceiling (N=64)", function()
      local recs = sample(64)
      local _, out = codec.decode(codec.encode(recs))
      assert.are.same(recs, out)
    end)

    it("handles an empty roster", function()
      local ver, out = codec.decode(codec.encode({}))
      assert.are.equal(codec.PROTOCOL_VERSION, ver)
      assert.are.same({}, out)
    end)

    it("preserves extreme numeric values (WX-78 400 HP, 75% penalty)", function()
      local recs = {
        {
          userid = "KU_wx78",
          hp_cur = 400,
          hp_max = 400,
          hp_penalty = 75,
          hunger = 150,
          sanity_cur = 0,
          sanity_max = 200,
          sanity_penalty = 95,
          flags = 0,
          origin = 1,
        },
      }
      local _, out = codec.decode(codec.encode(recs))
      assert.are.same(recs, out)
    end)
  end)

  describe("protocol version byte", function()
    it("prefixes the encoded payload with the version", function()
      local s = codec.encode(sample(2))
      assert.are.equal("2|", s:sub(1, 2))
    end)

    it("rejects an unsupported version", function()
      local s = codec.encode(sample(1))
      local bumped = s:gsub("^2|", "9|")
      local ver, err = codec.decode(bumped)
      assert.is_nil(ver)
      assert.is_truthy(err:find("unsupported protocol version"))
    end)
  end)

  describe("flags bit-packing", function()
    it("round-trips a set of flags", function()
      local packed = codec.packflags({ fire = true, freeze = true, ghost = true })
      local t = codec.unpackflags(packed)
      assert.is_true(t.fire)
      assert.is_true(t.freeze)
      assert.is_true(t.ghost)
      assert.is_false(t.overheat)
      assert.is_false(t.dead)
    end)

    it("survives encode/decode inside a record", function()
      local flags = codec.packflags({ overheat = true, dead = true })
      local recs = {
        {
          userid = "KU_onfire",
          hp_cur = 1,
          hp_max = 150,
          hp_penalty = 0,
          hunger = 0,
          sanity_cur = 0,
          sanity_max = 200,
          sanity_penalty = 0,
          flags = flags,
        },
      }
      local _, out = codec.decode(codec.encode(recs))
      local t = codec.unpackflags(out[1].flags)
      assert.is_true(t.overheat)
      assert.is_true(t.dead)
      assert.is_false(t.fire)
    end)

    it("empty flags table packs to 0", function()
      assert.are.equal(0, codec.packflags(nil))
      assert.are.equal(0, codec.packflags({}))
    end)
  end)

  describe("malformed input is rejected gracefully (never throws)", function()
    it("nil / empty string", function()
      assert.is_nil((codec.decode(nil)))
      assert.is_nil((codec.decode("")))
    end)

    it("garbage", function()
      assert.is_nil((codec.decode("not a payload")))
    end)

    it("count mismatch", function()
      -- header claims 5 records but supplies none
      assert.is_nil((codec.decode("1|5")))
    end)

    it("wrong field count in a record", function()
      assert.is_nil((codec.decode("1|1|KU_x:1:2:3")))
    end)

    it("non-numeric field", function()
      assert.is_nil((codec.decode("1|1|KU_x:abc:2:3:4:5:6:7:8")))
    end)
  end)

  describe("encoder guards", function()
    it("refuses a userid containing a separator", function()
      assert.has_error(function()
        codec.encode({
          {
            userid = "KU_b:ad",
            hp_cur = 1,
            hp_max = 1,
            hp_penalty = 0,
            hunger = 0,
            sanity_cur = 0,
            sanity_max = 0,
            sanity_penalty = 0,
            flags = 0,
          },
        })
      end)
    end)
  end)

  describe("protocol v2 origin field", function()
    it("defaults to version 2", function()
      assert.are.equal(2, codec.PROTOCOL_VERSION)
      local s = codec.encode(sample(1))
      assert.are.equal("2|", s:sub(1, 2))
    end)

    it("round-trips origin on the default (v2) version", function()
      local recs = {
        {
          userid = "KU_caves",
          hp_cur = 90,
          hp_max = 150,
          hp_penalty = 0,
          hunger = 75,
          sanity_cur = 110,
          sanity_max = 200,
          sanity_penalty = 0,
          flags = 0,
          origin = 7,
        },
      }
      local ver, out = codec.decode(codec.encode(recs))
      assert.are.equal(2, ver)
      assert.are.equal(7, out[1].origin)
      assert.are.same(recs, out)
    end)

    it("origin defaults to 0 when omitted from a v2 record", function()
      -- explicitly omit origin (sample() now sets it, so hand-build here)
      local recs = {
        {
          userid = "KU_noorigin",
          hp_cur = 100,
          hp_max = 150,
          hp_penalty = 0,
          hunger = 80,
          sanity_cur = 120,
          sanity_max = 200,
          sanity_penalty = 0,
          flags = 0,
        },
      }
      local _, out = codec.decode(codec.encode(recs))
      assert.are.equal(0, out[1].origin)
    end)

    it("round-trips a representative mixed record set with distinct origins", function()
      local recs = {
        {
          userid = "KU_master",
          hp_cur = 100,
          hp_max = 150,
          hp_penalty = 0,
          hunger = 80,
          sanity_cur = 120,
          sanity_max = 200,
          sanity_penalty = 0,
          flags = codec.packflags({ fire = true }),
          origin = 1,
        },
        {
          userid = "KU_caves",
          hp_cur = 50,
          hp_max = 100,
          hp_penalty = 50,
          hunger = 10,
          sanity_cur = 0,
          sanity_max = 200,
          sanity_penalty = 95,
          flags = codec.packflags({ ghost = true, dead = true }),
          origin = 2,
        },
        {
          userid = "KU_wx",
          hp_cur = 400,
          hp_max = 400,
          hp_penalty = 0,
          hunger = 150,
          sanity_cur = 200,
          sanity_max = 200,
          sanity_penalty = 0,
          flags = 0,
          origin = 0,
        },
      }
      local ver, out = codec.decode(codec.encode(recs))
      assert.are.equal(2, ver)
      assert.are.same(recs, out)
      assert.are.equal(1, out[1].origin)
      assert.are.equal(2, out[2].origin)
      assert.are.equal(0, out[3].origin)
    end)

    it("decodes a v1 payload with origin absent (nil)", function()
      -- encode with an explicit version 1 -> 9 fields, origin is NOT emitted even though
      -- the sample records carry one. The v1 wire format has no slot for it.
      local recs = sample(2)
      local v1str = codec.encode(recs, 1)
      assert.are.equal("1|", v1str:sub(1, 2))
      local ver, out = codec.decode(v1str)
      assert.are.equal(1, ver)
      assert.is_nil(out[1].origin)
      assert.is_nil(out[2].origin)
      -- every non-origin field round-trips exactly; origin is intentionally dropped by v1.
      for i = 1, #recs do
        local expected = {}
        for k, v in pairs(recs[i]) do
          if k ~= "origin" then
            expected[k] = v
          end
        end
        assert.are.same(expected, out[i])
      end
    end)

    it("decodes a hand-written v1 string with origin absent", function()
      local ver, out = codec.decode("1|1|KU_x:1:2:3:4:5:6:7:8")
      assert.are.equal(1, ver)
      assert.are.equal("KU_x", out[1].userid)
      assert.are.equal(1, out[1].hp_cur)
      assert.are.equal(8, out[1].flags)
      assert.is_nil(out[1].origin)
    end)

    it("rejects a v2 record missing the origin field (9 fields, expected 10)", function()
      assert.is_nil((codec.decode("2|1|KU_x:1:2:3:4:5:6:7:8")))
    end)

    it("rejects a non-numeric origin in a v2 record", function()
      assert.is_nil((codec.decode("2|1|KU_x:1:2:3:4:5:6:7:8:abc")))
    end)
  end)

  describe("startup self-check (Q4)", function()
    it("the current PROTOCOL_VERSION is in SUPPORTED", function()
      -- require-time assert(SUPPORTED[PROTOCOL_VERSION]) guards a version bump without a SUPPORTED entry
      local ver = codec.decode(codec.encode({}))
      assert.are.equal(codec.PROTOCOL_VERSION, ver)
    end)

    it("a probe record survives an encode->decode round-trip at the default version", function()
      local probe = {
        {
          userid = "KU_selfcheck",
          hp_cur = 100,
          hp_max = 150,
          hp_penalty = 0,
          hunger = 80,
          sanity_cur = 120,
          sanity_max = 200,
          sanity_penalty = 0,
          flags = 0,
          origin = 1,
        },
      }
      local ver, out = codec.decode(codec.encode(probe))
      assert.are.equal(codec.PROTOCOL_VERSION, ver)
      assert.are.same(probe, out)
    end)
  end)

  describe("decode-boundary numeric clamps (Q3)", function()
    it("clamps a negative hp_cur to 0 and KEEPS the record", function()
      -- v1 hand-built string with hp_cur = -5 (field 1 after userid)
      local ver, out = codec.decode("1|1|KU_x:-5:150:0:80:120:200:0:0")
      assert.are.equal(1, ver)
      assert.is_truthy(out)
      assert.are.equal(0, out[1].hp_cur)
    end)

    it("clamps a negative hunger and sanity_cur to 0", function()
      local _, out = codec.decode("1|1|KU_x:100:150:0:-3:-7:200:0:0")
      assert.are.equal(0, out[1].hunger)
      assert.are.equal(0, out[1].sanity_cur)
    end)

    it("leaves an in-range record untouched", function()
      local _, out = codec.decode("1|1|KU_x:90:150:0:80:120:200:0:0")
      assert.are.equal(90, out[1].hp_cur)
      assert.are.equal(80, out[1].hunger)
      assert.are.equal(120, out[1].sanity_cur)
    end)

    it("does NOT reject the whole payload on an out-of-range value", function()
      -- structural errors still return nil; a clamped value must NOT
      local ver = codec.decode("1|1|KU_x:-5:150:0:80:120:200:0:0")
      assert.are.equal(1, ver)
    end)
  end)
end)
