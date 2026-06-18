-- spec/layout_spec.lua
--
-- busted unit tests for the pure layout / dodge math (partyhud_layout), extracted from modmain so the
-- arithmetic can be exercised with zero engine deps. Real busted syntax -- runs in CI via
-- dstmodders/action (`busted spec/`), and locally via spec/run_local.lua on plain luajit/lua.

local M = require("partyhud_layout")

describe("partyhud layout math", function()

	describe("percol_count", function()
		it("returns the safe fallback (6) when the screen / HUD scale is unreadable", function()
			-- nil or <= 0 on any of scrnw / scrnh / hudscale -> PERCOL_FALLBACK, never the wrap math.
			assert.are.equal(M.PERCOL_FALLBACK, M.percol_count(nil, 720, 1.0, -130, 65, -120))
			assert.are.equal(M.PERCOL_FALLBACK, M.percol_count(1280, nil, 1.0, -130, 65, -120))
			assert.are.equal(M.PERCOL_FALLBACK, M.percol_count(1280, 720, nil, -130, 65, -120))
			assert.are.equal(M.PERCOL_FALLBACK, M.percol_count(0, 720, 1.0, -130, 65, -120))
			assert.are.equal(M.PERCOL_FALLBACK, M.percol_count(1280, -1, 1.0, -130, 65, -120))
			assert.are.equal(M.PERCOL_FALLBACK, M.percol_count(1280, 720, 0, -130, 65, -120))
			assert.are.equal(6, M.PERCOL_FALLBACK) -- documents the contracted value
		end)

		it("computes the baseline 1280x720 @ hudscale 1.0 exactly", function()
			-- prop = min(1,1) = 1; usable = 720/(1.0*1.4*1) = 514.2857...
			-- n = floor((-130 - 60 + 514.2857 - 65)/120) + 1 = floor(2.1607) + 1 = 3
			assert.are.equal(3, M.percol_count(1280, 720, 1.0, -130, 65, -120))
		end)

		it("does NOT collapse on a sub-720 window (the proportional-scale regression)", function()
			-- 1024x576 @ hudscale 0.8: prop = min(0.8, 0.8) = 0.8; usable = 576/(0.8*1.4*0.8) = 642.857
			-- n = floor((-130 - 60 + 642.857 - 65)/120) + 1 = floor(3.232) + 1 = 4
			local sub720   = M.percol_count(1024, 576, 0.8, -130, 65, -120)
			-- same hudscale at the 720 baseline: prop = 1; usable = 720/(0.8*1.4*1) = 642.857 (== above)
			local baseline = M.percol_count(1280, 720, 0.8, -130, 65, -120)
			assert.are.equal(4, baseline)
			assert.are.equal(4, sub720)
			-- the bug being guarded: sub720 must NOT collapse to 1 -- it tracks the baseline (prop fix).
			assert.is_true(sub720 >= baseline)
			assert.is_true(sub720 > 1)
		end)

		it("caps the upscale prop at 1.25 (raw width/height ratio past 1.25 is ignored)", function()
			-- 3840x2160 @ hudscale 1.0: raw prop = min(3, 3) = 3, capped to MAX_PROP = 1.25.
			-- usable = 2160/(1.0*1.4*1.25) = 1234.2857. n = floor((-130-60+1234.2857-65)/120)+1
			--        = floor(8.157) + 1 = 9.   (NOTE: `usable` still tracks raw scrnh in the numerator;
			-- only the prop DIVISOR is capped, so the cap RAISES usable vs an uncapped prop=3 would give.)
			local fourk = M.percol_count(3840, 2160, 1.0, -130, 65, -120)
			assert.are.equal(9, fourk)
			-- The cap means the prop is pinned at 1.25 once the raw ratio exceeds it. Hold scrnh fixed and
			-- widen the screen well past the cap point: min() already picks the (capped) height ratio, so a
			-- wider 4800x2160 gives the IDENTICAL usable/divisor -> identical count. (If prop were NOT
			-- capped, width vs height min() still picks height here, so this also proves the cap path is
			-- the one taken: both raw ratios >= 1.25 collapse to the same 1.25.)
			assert.are.equal(fourk, M.percol_count(4800, 2160, 1.0, -130, 65, -120))
			-- Prove the cap actually bit (prop was raised to 1.25, not left at raw 3): an uncapped prop=3
			-- would give usable = 2160/(1.4*3) = 514.28 -> n = floor((-130-60+514.28-65)/120)+1 = 3. The
			-- capped result (9) is strictly larger, confirming prop was clamped DOWN to 1.25.
			assert.is_true(fourk > 3)
		end)

		it("a bigger bottom_reserve yields <= per-col than a smaller one (monotone)", function()
			local small = M.percol_count(1280, 720, 1.0, -130, 20, -120)
			local big   = M.percol_count(1280, 720, 1.0, -130, 200, -120)
			assert.is_true(big <= small)
		end)

		it("always returns at least 1 even when geometry leaves no room", function()
			-- a tiny usable height + a huge bottom_reserve would drive n negative -> clamped to 1.
			assert.is_true(M.percol_count(1280, 720, 1.0, -130, 100000, -120) >= 1)
			assert.are.equal(1, M.percol_count(1280, 720, 1.0, -130, 100000, -120))
		end)
	end)

	describe("second_row_span", function()
		local MR, IR = 75, 90 -- sample moisture_reserve / inspiration_reserve

		it("none active -> {0, 0}", function()
			local cols, reserve = M.second_row_span(false, false, false, MR, IR)
			assert.are.equal(0, cols)
			assert.are.equal(0, reserve)
		end)

		it("moisture only -> {1, moisture_reserve}", function()
			local cols, reserve = M.second_row_span(true, false, false, MR, IR)
			assert.are.equal(1, cols)
			assert.are.equal(MR, reserve)
		end)

		it("inspiration only -> {1, inspiration_reserve}", function()
			local cols, reserve = M.second_row_span(false, false, true, MR, IR)
			assert.are.equal(1, cols)
			assert.are.equal(IR, reserve)
		end)

		it("moisture + abigail -> {2, moisture_reserve}", function()
			local cols, reserve = M.second_row_span(true, true, false, MR, IR)
			assert.are.equal(2, cols)
			assert.are.equal(MR, reserve)
		end)

		it("abigail + inspiration -> {2, inspiration_reserve} (deepest wins)", function()
			local cols, reserve = M.second_row_span(false, true, true, MR, IR)
			assert.are.equal(2, cols)
			assert.are.equal(IR, reserve)
		end)

		it("all three -> cols capped at 2, reserve = deepest (inspiration)", function()
			local cols, reserve = M.second_row_span(true, true, true, MR, IR)
			assert.are.equal(2, cols) -- 3 active badges, but the band only ever spans 2 columns
			assert.are.equal(IR, reserve) -- inspiration (y-130) is deeper than moisture/Abigail
		end)
	end)

	describe("dodge_cols", function()
		it("bpmode 0 (no backpack) -> passthrough", function()
			assert.are.equal(0, M.dodge_cols(0, 0))
			assert.are.equal(1, M.dodge_cols(0, 1))
			assert.are.equal(2, M.dodge_cols(0, 2))
		end)

		it("bpmode 2 (integrated) -> passthrough", function()
			assert.are.equal(0, M.dodge_cols(2, 0))
			assert.are.equal(1, M.dodge_cols(2, 1))
			assert.are.equal(2, M.dodge_cols(2, 2))
		end)

		it("bpmode 1 (Mode A, side pack) -> a 1-badge band clears, a wide band still clips col 1", function()
			assert.are.equal(0, M.dodge_cols(1, 0)) -- nothing to dodge
			assert.are.equal(0, M.dodge_cols(1, 1)) -- left shift clears the single home-column badge
			assert.are.equal(1, M.dodge_cols(1, 2)) -- wide band still lands one badge under shifted col 0
		end)
	end)

	describe("column_reserve", function()
		local vstarty, reserve, full, free = -130, 75, 65, 40

		it("col 0, bpmode 0, dodge 0 -> top = vstarty, bottom = full_bottom", function()
			local top, bottom = M.column_reserve(0, 0, 0, vstarty, reserve, full, free)
			assert.are.equal(vstarty, top)
			assert.are.equal(full, bottom)
		end)

		it("col 0, bpmode 1 (Mode A) -> bottom = free_bottom (shifted off the Map button)", function()
			local _, bottom = M.column_reserve(0, 0, 1, vstarty, reserve, full, free)
			assert.are.equal(free, bottom)
		end)

		it("col < dodge -> top pushed down by the reserve", function()
			local top, _ = M.column_reserve(0, 1, 0, vstarty, reserve, full, free)
			assert.are.equal(vstarty - reserve, top)
		end)

		it("col >= dodge -> top = vstarty (no push)", function()
			local top, _ = M.column_reserve(1, 1, 0, vstarty, reserve, full, free)
			assert.are.equal(vstarty, top)
		end)

		it("a non-zero column always gets free_bottom (only col 0 holds the Map keep-out)", function()
			local _, b0 = M.column_reserve(1, 0, 0, vstarty, reserve, full, free)
			assert.are.equal(free, b0)
			local _, b2 = M.column_reserve(2, 0, 2, vstarty, reserve, full, free)
			assert.are.equal(free, b2)
		end)
	end)
end)
