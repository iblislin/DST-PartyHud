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
			userid         = "KU_test" .. i,
			hp_cur         = 100 + i,
			hp_max         = 150,
			hp_penalty     = (i % 2 == 0) and 25 or 0,
			hunger         = 80 + i,
			sanity_cur     = 120 + i,
			sanity_max     = 200,
			sanity_penalty = (i % 3 == 0) and 50 or 0,
			flags          = 0,
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
			local recs = { {
				userid = "KU_wx78", hp_cur = 400, hp_max = 400, hp_penalty = 75,
				hunger = 150, sanity_cur = 0, sanity_max = 200, sanity_penalty = 95, flags = 0,
			} }
			local _, out = codec.decode(codec.encode(recs))
			assert.are.same(recs, out)
		end)
	end)

	describe("protocol version byte", function()
		it("prefixes the encoded payload with the version", function()
			local s = codec.encode(sample(2))
			assert.are.equal("1|", s:sub(1, 2))
		end)

		it("rejects an unsupported version", function()
			local s = codec.encode(sample(1))
			local bumped = s:gsub("^1|", "9|")
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
			local recs = { {
				userid = "KU_onfire", hp_cur = 1, hp_max = 150, hp_penalty = 0,
				hunger = 0, sanity_cur = 0, sanity_max = 200, sanity_penalty = 0, flags = flags,
			} }
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
				codec.encode({ {
					userid = "KU_b:ad", hp_cur = 1, hp_max = 1, hp_penalty = 0,
					hunger = 0, sanity_cur = 0, sanity_max = 0, sanity_penalty = 0, flags = 0,
				} })
			end)
		end)
	end)
end)
