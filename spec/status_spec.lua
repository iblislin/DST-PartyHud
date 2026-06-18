-- spec/status_spec.lua — pure status-display decision logic (partyhud_status)
local M = require("partyhud_status")

-- mirror the game's RATE_SCALE enum (constants.lua:2402)
local RS = {
	NEUTRAL = 0,
	INCREASE_HIGH = 1, INCREASE_MED = 2, INCREASE_LOW = 3,
	DECREASE_HIGH = 4, DECREASE_MED = 5, DECREASE_LOW = 6,
}

describe("partyhud status — sanity_ratescale", function()

	describe("asleep (GetRateScale reads NEUTRAL; level synthesized from the sleep gain rate)", function()
		-- raw_rs is passed as NEUTRAL while asleep (ignored by the sleep branch); pct < 1.
		it("rate > .2 -> INCREASE_HIGH", function()
			assert.are.equal(RS.INCREASE_HIGH, M.sanity_ratescale(true, 0.5, RS.NEUTRAL, 0.5, RS))
		end)
		it("rate in (.1, .2] -> INCREASE_MED", function()
			assert.are.equal(RS.INCREASE_MED, M.sanity_ratescale(true, 0.15, RS.NEUTRAL, 0.5, RS))
			assert.are.equal(RS.INCREASE_MED, M.sanity_ratescale(true, 0.2, RS.NEUTRAL, 0.5, RS)) -- boundary: .2 is NOT > .2
		end)
		it("rate in (.01, .1] -> INCREASE_LOW", function()
			assert.are.equal(RS.INCREASE_LOW, M.sanity_ratescale(true, 0.05, RS.NEUTRAL, 0.5, RS))
			assert.are.equal(RS.INCREASE_LOW, M.sanity_ratescale(true, 0.1, RS.NEUTRAL, 0.5, RS)) -- boundary
		end)
		it("rate <= .01 -> NEUTRAL", function()
			assert.are.equal(RS.NEUTRAL, M.sanity_ratescale(true, 0.005, RS.NEUTRAL, 0.5, RS))
			assert.are.equal(RS.NEUTRAL, M.sanity_ratescale(true, 0, RS.NEUTRAL, 0.5, RS))
		end)
		it("at full sanity (pct >= 1) -> NEUTRAL even with a high sleep rate", function()
			assert.are.equal(RS.NEUTRAL, M.sanity_ratescale(true, 0.5, RS.NEUTRAL, 1, RS))
			assert.are.equal(RS.NEUTRAL, M.sanity_ratescale(true, 0.5, RS.NEUTRAL, 1.0, RS))
		end)
	end)

	describe("awake (use the game's rate enum, clamped at the extremes)", function()
		it("an INCREASE level shows when not full, NEUTRAL at full", function()
			assert.are.equal(RS.INCREASE_HIGH, M.sanity_ratescale(false, 0, RS.INCREASE_HIGH, 0.5, RS))
			assert.are.equal(RS.INCREASE_MED,  M.sanity_ratescale(false, 0, RS.INCREASE_MED,  0.99, RS))
			assert.are.equal(RS.INCREASE_LOW,  M.sanity_ratescale(false, 0, RS.INCREASE_LOW,  0.01, RS))
			-- no rising arrow at full
			assert.are.equal(RS.NEUTRAL, M.sanity_ratescale(false, 0, RS.INCREASE_HIGH, 1, RS))
		end)
		it("a DECREASE level shows when not empty, NEUTRAL at empty", function()
			assert.are.equal(RS.DECREASE_HIGH, M.sanity_ratescale(false, 0, RS.DECREASE_HIGH, 0.5, RS))
			assert.are.equal(RS.DECREASE_MED,  M.sanity_ratescale(false, 0, RS.DECREASE_MED,  0.01, RS))
			assert.are.equal(RS.DECREASE_LOW,  M.sanity_ratescale(false, 0, RS.DECREASE_LOW,  1, RS))
			-- no falling arrow at empty
			assert.are.equal(RS.NEUTRAL, M.sanity_ratescale(false, 0, RS.DECREASE_HIGH, 0, RS))
		end)
		it("a NEUTRAL game rate -> NEUTRAL", function()
			assert.are.equal(RS.NEUTRAL, M.sanity_ratescale(false, 0, RS.NEUTRAL, 0.5, RS))
		end)
	end)
end)
