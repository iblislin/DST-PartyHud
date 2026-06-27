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
      local sub720 = M.percol_count(1024, 576, 0.8, -130, 65, -120)
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
      local big = M.percol_count(1280, 720, 1.0, -130, 200, -120)
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

  describe("compute_badge_positions", function()
    -- The fixed layout constants modmain passes in (VERT_*, BACKPACK_*, horizontal step). A baseline
    -- vertical scenario: 1280x720 @ hudscale 1.0, no-minimap position (2 -> uses vert_x/vert_y as anchor),
    -- sub-rings shown (vgap = -120 -> rowpitch 120), no backpack, no second-row band. With percol_count
    -- baseline = 3 (see the percol_count specs above), col 0/1/2 each hold 3 badges then wrap LEFT by
    -- vert_col_w=80; col 0/1 bottom differs (65 full vs 40 free) but both still size to 3 here.
    local function base(badge_count, over)
      local o = {
        layout_mode = 2,
        position_mode = 2,
        phud_xpos = -100,
        phud_ypos = 120,
        badge_count = badge_count,
        show_substatus = true,
        screen_w = 1280,
        screen_h = 720,
        hudscale = 1.0,
        bpmode = 0,
        second_row_cols = 0,
        second_row_reserve = 0,
        vert_x = 0,
        vert_y = -130,
        vert_gap = -120,
        vert_gap_compact = -90,
        vert_col_w = 80,
        vert_bottom_reserve = 65,
        vert_bottom_reserve_free = 40,
        backpack_shift_x = 100,
        backpack_bottom_extra = 20,
        horizontal_step = -70,
      }
      if over then
        for k, v in pairs(over) do
          o[k] = v
        end
      end
      return o
    end

    it("zero / nil badge_count -> empty array", function()
      assert.are.same({}, M.compute_badge_positions(base(0)))
      assert.are.same({}, M.compute_badge_positions(base(nil)))
    end)

    it("horizontal row (layout_mode ~= 2): x = phud_xpos + step*i, y = phud_ypos", function()
      -- horizontal_step = -70, phud_xpos = -100, phud_ypos = 120. i = 1..3.
      -- i1: -100 + (-70*1) = -170; i2: -240; i3: -310. y is always phud_ypos; col 0, row i-1.
      local r = M.compute_badge_positions(base(3, { layout_mode = 0 }))
      assert.are.equal(3, #r)
      assert.are.same({ index = 1, x = -170, y = 120, col = 0, row = 0 }, r[1])
      assert.are.same({ index = 2, x = -240, y = 120, col = 0, row = 1 }, r[2])
      assert.are.same({ index = 3, x = -310, y = 120, col = 0, row = 2 }, r[3])
    end)

    it("vertical 1 badge -> single slot at the anchor", function()
      local r = M.compute_badge_positions(base(1))
      assert.are.equal(1, #r)
      assert.are.same({ index = 1, x = 0, y = -130, col = 0, row = 0 }, r[1])
    end)

    it("vertical 2 badges -> stack down col 0 by vert_gap", function()
      local r = M.compute_badge_positions(base(2))
      assert.are.equal(2, #r)
      assert.are.same({ index = 1, x = 0, y = -130, col = 0, row = 0 }, r[1])
      -- y = vstarty + vert_gap*1 = -130 + (-120) = -250
      assert.are.same({ index = 2, x = 0, y = -250, col = 0, row = 1 }, r[2])
    end)

    it("vertical 8 badges -> wraps col 0 (3) | col 1 (3) | col 2 (2)", function()
      -- percol_count = 3 per column at the baseline. 8 badges => 3 + 3 + 2.
      local r = M.compute_badge_positions(base(8))
      assert.are.equal(8, #r)
      -- col 0: x 0
      assert.are.same({ index = 1, x = 0, y = -130, col = 0, row = 0 }, r[1])
      assert.are.same({ index = 3, x = 0, y = -370, col = 0, row = 2 }, r[3])
      -- col 1 wraps LEFT by vert_col_w (80): x = 0 - 80*1 = -80, top resets to vstarty
      assert.are.same({ index = 4, x = -80, y = -130, col = 1, row = 0 }, r[4])
      assert.are.same({ index = 6, x = -80, y = -370, col = 1, row = 2 }, r[6])
      -- col 2: x = -160, only 2 badges left
      assert.are.same({ index = 7, x = -160, y = -130, col = 2, row = 0 }, r[7])
      assert.are.same({ index = 8, x = -160, y = -250, col = 2, row = 1 }, r[8])
    end)

    it("vertical 10 badges -> spills into a 4th column (one badge)", function()
      local r = M.compute_badge_positions(base(10))
      assert.are.equal(10, #r)
      -- 3 + 3 + 3 = 9 in cols 0-2; badge 10 opens col 3 at x = -240.
      assert.are.same({ index = 9, x = -160, y = -370, col = 2, row = 2 }, r[9])
      assert.are.same({ index = 10, x = -240, y = -130, col = 3, row = 0 }, r[10])
    end)

    it("backpack Mode A (bpmode 1) shifts every column LEFT by backpack_shift_x and frees col 0's bottom", function()
      -- vstartx = vert_x(0) - backpack_shift_x(100) = -100. col 0 bottom uses `free` (40) not full(65)
      -- because bpmode==1; cap still 3 (bottom 40 -> percol 3). col 1 at x = -100 - 80 = -180.
      local r = M.compute_badge_positions(base(4, { bpmode = 1 }))
      assert.are.equal(4, #r)
      assert.are.same({ index = 1, x = -100, y = -130, col = 0, row = 0 }, r[1])
      assert.are.same({ index = 3, x = -100, y = -370, col = 0, row = 2 }, r[3])
      assert.are.same({ index = 4, x = -180, y = -130, col = 1, row = 0 }, r[4])
    end)

    it("backpack Mode B (bpmode 2) adds backpack_bottom_extra to the columns-2+ bottom keep-out", function()
      -- free = vert_bottom_reserve_free(40) + backpack_bottom_extra(20) = 60. At the baseline geometry
      -- percol_count(...,-130,60,-120) = floor((-130-60+514.2857-60)/120)+1 = floor(2.202)+1 = 3 -- the
      -- extra 20 is not enough to drop a row here, so x/y match the bpmode-0 wrap. (Behaviour-neutral:
      -- the +extra is plumbed through column_reserve's `free` exactly as in modmain; the on-screen wrap
      -- only differs from bpmode 0 when the extra reserve actually crosses a row-pitch boundary.)
      local r = M.compute_badge_positions(base(8, { bpmode = 2 }))
      assert.are.equal(8, #r)
      assert.are.same({ index = 1, x = 0, y = -130, col = 0, row = 0 }, r[1])
      assert.are.same({ index = 4, x = -80, y = -130, col = 1, row = 0 }, r[4])
      assert.are.same({ index = 7, x = -160, y = -130, col = 2, row = 0 }, r[7])
    end)

    it("second-row dodge (second_row_cols 1) pushes col 0's top DOWN by second_row_reserve", function()
      -- dodge = dodge_cols(0, 1) = 1. col 0 < dodge -> top = vstarty - reserve = -130 - 75 = -205, and
      -- it keeps the FULL bottom reserve (65) -> percol_count(...,-205,65,-120) = floor(1.5357)+1 = 2.
      -- col 1 (1 not < 1) -> top back to vstarty(-130), free bottom. So col 0 holds 2, col 1 the rest.
      local r = M.compute_badge_positions(base(4, { second_row_cols = 1, second_row_reserve = 75 }))
      assert.are.equal(4, #r)
      assert.are.same({ index = 1, x = 0, y = -205, col = 0, row = 0 }, r[1])
      -- y = -205 + (-120) = -325
      assert.are.same({ index = 2, x = 0, y = -325, col = 0, row = 1 }, r[2])
      -- col 1 top is NOT dodged -> back to vstarty
      assert.are.same({ index = 3, x = -80, y = -130, col = 1, row = 0 }, r[3])
      assert.are.same({ index = 4, x = -80, y = -250, col = 1, row = 1 }, r[4])
    end)

    it("position_mode 0/1 reuse the phud anchor instead of vert_x/vert_y", function()
      -- position_mode 0 -> vstartx/vstarty = phud_xpos(-100)/phud_ypos(120). y stacks down by vert_gap.
      local r = M.compute_badge_positions(base(2, { position_mode = 0 }))
      assert.are.same({ index = 1, x = -100, y = 120, col = 0, row = 0 }, r[1])
      assert.are.same({ index = 2, x = -100, y = 0, col = 0, row = 1 }, r[2])
    end)

    it("show_substatus false selects the compact gap (vert_gap_compact) for the row pitch", function()
      -- vgap = vert_gap_compact = -90. rowpitch 90 -> percol_count(...,-130,65,-90) = 3. y steps by -90.
      local r = M.compute_badge_positions(base(4, { show_substatus = false }))
      assert.are.same({ index = 1, x = 0, y = -130, col = 0, row = 0 }, r[1])
      assert.are.same({ index = 2, x = 0, y = -220, col = 0, row = 1 }, r[2])
      assert.are.same({ index = 3, x = 0, y = -310, col = 0, row = 2 }, r[3])
      -- 4th wraps to col 1 at the un-pushed top
      assert.are.same({ index = 4, x = -80, y = -130, col = 1, row = 0 }, r[4])
    end)
  end)

  describe("cs_compensated_vstartx", function()
    local function r2(x)
      return math.floor(x * 100 + 0.5) / 100
    end
    -- Invariance: factor * (cs_sp_x + comp) = CS_SIDEPANEL_X + vstartx
    -- → comp = (CS_SIDEPANEL_X + vstartx) / factor - cs_sp_x
    -- cs_sp_x=nil defaults to CS_SIDEPANEL_X (vanilla sidepanel; only scale compensation)
    -- cs_sp_x=-100 = CS case (CS moves sidepanel from -80 to -100)
    it("factor nil / <=0 -> unchanged", function()
      assert.are.equal(0, M.cs_compensated_vstartx(0, nil))
      assert.are.equal(-100, M.cs_compensated_vstartx(-100, 0))
      assert.are.equal(-100, M.cs_compensated_vstartx(-100, -0.5))
    end)
    it("factor 1 + vanilla sp_x (nil) -> unchanged (no CS effect)", function()
      assert.are.equal(0, M.cs_compensated_vstartx(0, 1))
      assert.are.equal(-100, M.cs_compensated_vstartx(-100, 1))
    end)
    it("factor 1 + CS sp_x (-100) -> compensates +20 for sidepanel shift alone", function()
      -- CS moves sidepanel -80 -> -100 even at HUDSCALEFACTOR=1
      -- target = (-80 + 0)/1 - (-100) = 20; result = 0 + 20 = 20
      assert.are.equal(20, r2(M.cs_compensated_vstartx(0, 1, -100)))
    end)
    it("factor 1.25 + vanilla sp_x: scale only compensation", function()
      -- target = (-80+0)/1.25 - (-80) = -64+80 = 16
      assert.are.equal(16, r2(M.cs_compensated_vstartx(0, 1.25, -80)))
    end)
    it("factor 1.25 + CS sp_x (-100): scale + position compensation", function()
      -- target = (-80+0)/1.25 - (-100) = -64+100 = 36
      assert.are.equal(36, r2(M.cs_compensated_vstartx(0, 1.25, -100)))
    end)
    it("factor 0.75 + vanilla sp_x: scale compensation LEFT", function()
      -- target = (-80+0)/0.75 - (-80) = -106.67+80 = -26.67
      assert.are.equal(-26.67, r2(M.cs_compensated_vstartx(0, 0.75, -80)))
    end)
    it("fudge scales the correction", function()
      -- factor=1.25, cs_sp_x=-80: target=16, delta=16; fudge=2 -> 0+16*2=32
      assert.are.equal(32, r2(M.cs_compensated_vstartx(0, 1.25, -80, 2)))
    end)
    it("non-zero vstartx (Minimap anchor)", function()
      -- factor=1.25, cs_sp_x=-100: target=(-80-100)/1.25-(-100)=-144+100=-44; result=-100+56=-44
      assert.are.equal(-44, r2(M.cs_compensated_vstartx(-100, 1.25, -100)))
    end)
    it("screen-x INVARIANCE: compensated column lands at SAME screen x as vanilla, any F and cs_sp_x", function()
      local function screen_x_vanilla(vstartx)
        return M.CS_SIDEPANEL_X + vstartx
      end
      local function screen_x_cs(vstartx, factor, cs_sp_x)
        return factor * (cs_sp_x + vstartx)
      end
      for _, F in ipairs({ 0.75, 1.0, 1.1, 1.25, 1.5 }) do
        for _, csx in ipairs({ -80, -100 }) do -- vanilla sp_x and CS sp_x
          for _, vanilla_vstartx in ipairs({ 0, -100, -650 }) do
            local comp = M.cs_compensated_vstartx(vanilla_vstartx, F, csx)
            assert.are.equal(r2(screen_x_vanilla(vanilla_vstartx)), r2(screen_x_cs(comp, F, csx)))
          end
        end
      end
    end)
  end)

  describe("CS + backpack Mode A interaction in compute_badge_positions", function()
    -- Core assertion: in Mode A (bpmode=1), CS cs_vstartx_override is IGNORED.
    -- The shifted column lands at the same x as vanilla (vert_x - backpack_shift_x),
    -- regardless of heart_x / cs_vstartx_override.
    local function make_opts(overrides)
      local base = {
        layout_mode = 2, position_mode = 2,
        phud_xpos = 0, phud_ypos = 0,
        badge_count = 1, show_substatus = false,
        screen_w = 1280, screen_h = 720, hudscale = 1,
        bpmode = 0, second_row_cols = 0, second_row_reserve = 0,
        vert_x = 0, vert_y = -130,
        vert_gap = -120, vert_gap_compact = -90, vert_col_w = 80,
        vert_bottom_reserve = 65, vert_bottom_reserve_free = 40,
        backpack_shift_x = 100, backpack_bottom_extra = 20,
        horizontal_step = -70,
        cs_factor = nil, cs_sp_x = nil, cs_fudge = 1,
        cs_vstartx_override = nil,
      }
      for k, v in pairs(overrides) do base[k] = v end
      return base
    end

    it("vanilla no-backpack: x = vert_x = 0", function()
      local r = M.compute_badge_positions(make_opts({}))
      assert.are.equal(0, r[1].x)
    end)

    it("vanilla Mode A: x = vert_x - backpack_shift_x = -100", function()
      local r = M.compute_badge_positions(make_opts({ bpmode = 1 }))
      assert.are.equal(-100, r[1].x)
    end)

    it("CS no-backpack: x = cs_vstartx_override (heart_x=40)", function()
      local r = M.compute_badge_positions(make_opts({ cs_vstartx_override = 40 }))
      assert.are.equal(40, r[1].x)
    end)

    it("CS Mode A: x = vert_x - backpack_shift_x = -100 (same as vanilla, NOT 40-100=-60)", function()
      -- cs_vstartx_override must be IGNORED in Mode A
      local r = M.compute_badge_positions(make_opts({ bpmode = 1, cs_vstartx_override = 40 }))
      assert.are.equal(-100, r[1].x)
    end)

    it("CS Mode A result equals vanilla Mode A (shift clears backpack identically)", function()
      local vanilla = M.compute_badge_positions(make_opts({ bpmode = 1 }))
      local cs      = M.compute_badge_positions(make_opts({ bpmode = 1, cs_vstartx_override = 40 }))
      assert.are.equal(vanilla[1].x, cs[1].x)
    end)
  end)
end)
