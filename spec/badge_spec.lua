-- spec/badge_spec.lua — pure badge colour / predicate math (partyhud_badge)
local M = require("partyhud_badge")

-- exact peak / trough of the breathe phase k = 0.5 + 0.5*sin(blink_t * LOW_HP_PULSE_W):
--   k = 1 (alarm peak)  when sin = 1  -> blink_t * W = pi/2  -> blink_t = LOW_HP_PULSE_SECS/4
--   k = 0 (rest trough) when sin = -1 -> blink_t * W = 3pi/2 -> blink_t = 3*LOW_HP_PULSE_SECS/4
local PEAK_T = M.LOW_HP_PULSE_SECS / 4
local TROUGH_T = 3 * M.LOW_HP_PULSE_SECS / 4

-- float-tolerant compare (the lerp / sin arithmetic introduces tiny FP error)
local EPS = 1e-9
local function near(a, b)
  return math.abs(a - b) <= EPS
end

describe("partyhud badge — frame_colour", function()
  it("local + healthy -> exactly white at FULL_ALPHA", function()
    local r, g, b, a = M.frame_colour(false, false, 0)
    assert.are.equal(1, r)
    assert.are.equal(1, g)
    assert.are.equal(1, b)
    assert.are.equal(M.FULL_ALPHA, a)
  end)

  it("foreign + healthy -> white at FOREIGN_ALPHA (hue preserved, only alpha dims)", function()
    local r, g, b, a = M.frame_colour(false, true, 0)
    assert.are.equal(1, r)
    assert.are.equal(1, g)
    assert.are.equal(1, b)
    assert.are.equal(M.FOREIGN_ALPHA, a)
    -- blink_t is ignored when not low: same result at any phase
    local _, _, _, a2 = M.frame_colour(false, true, 12.34)
    assert.are.equal(M.FOREIGN_ALPHA, a2)
  end)

  it("low-HP at the alarm PEAK -> exactly LOW_HP_TINT rgb + alpha 1", function()
    local r, g, b, a = M.frame_colour(true, false, PEAK_T)
    assert.is_true(near(r, M.LOW_HP_TINT[1]))
    assert.is_true(near(g, M.LOW_HP_TINT[2]))
    assert.is_true(near(b, M.LOW_HP_TINT[3]))
    assert.is_true(near(a, 1))
  end)

  it("low-HP at the alarm PEAK -> alpha 1 even on a foreign (dimmed) badge", function()
    -- the alert must stay fully visible at the peak regardless of the foreign baseline
    local r, g, b, a = M.frame_colour(true, true, PEAK_T)
    assert.is_true(near(r, M.LOW_HP_TINT[1]))
    assert.is_true(near(g, M.LOW_HP_TINT[2]))
    assert.is_true(near(b, M.LOW_HP_TINT[3]))
    assert.is_true(near(a, 1))
  end)

  it("low-HP at the rest TROUGH -> white rgb + alpha back at the local baseline", function()
    local r, g, b, a = M.frame_colour(true, false, TROUGH_T)
    assert.is_true(near(r, 1))
    assert.is_true(near(g, 1))
    assert.is_true(near(b, 1))
    assert.is_true(near(a, M.FULL_ALPHA))
  end)

  it("low-HP at the rest TROUGH (foreign) -> white rgb + alpha back at FOREIGN_ALPHA", function()
    local r, g, b, a = M.frame_colour(true, true, TROUGH_T)
    assert.is_true(near(r, 1))
    assert.is_true(near(g, 1))
    assert.is_true(near(b, 1))
    assert.is_true(near(a, M.FOREIGN_ALPHA))
  end)

  it("alpha never drops below the baseline across a full cycle (alert never dimmer than rest)", function()
    for _, foreign in ipairs({ false, true }) do
      local baseline = foreign and M.FOREIGN_ALPHA or M.FULL_ALPHA
      -- sample finely across more than one full breathe period
      local n = 240
      for i = 0, n do
        local t = (i / n) * (M.LOW_HP_PULSE_SECS * 2)
        local _, _, _, a = M.frame_colour(true, foreign, t)
        assert.is_true(a >= baseline - EPS)
        assert.is_true(a <= 1 + EPS)
      end
    end
  end)

  it("every rgb/alpha factor stays within [0,1] for arbitrary blink_t", function()
    local samples = { -1000, -3.7, -0.3, 0, 0.123, PEAK_T, TROUGH_T, 5, 42.5, 100000 }
    for _, foreign in ipairs({ false, true }) do
      for _, t in ipairs(samples) do
        local r, g, b, a = M.frame_colour(true, foreign, t)
        for _, v in ipairs({ r, g, b, a }) do
          assert.is_true(v >= 0 - EPS)
          assert.is_true(v <= 1 + EPS)
        end
      end
    end
  end)

  it("blink_t = 0 -> the breathe starts at the rest phase (k = 0.5, mid-lerp)", function()
    -- _set_low_hp resets _blink_t to 0 on entry; document the exact start colour.
    local r, g, b, a = M.frame_colour(true, false, 0)
    assert.is_true(near(r, 1 + (M.LOW_HP_TINT[1] - 1) * 0.5))
    assert.is_true(near(g, 1 + (M.LOW_HP_TINT[2] - 1) * 0.5))
    assert.is_true(near(b, 1 + (M.LOW_HP_TINT[3] - 1) * 0.5))
    assert.is_true(near(a, M.FULL_ALPHA + (1 - M.FULL_ALPHA) * 0.5))
  end)
end)

describe("partyhud badge — is_low_hp", function()
  it("threshold 0 (or <= 0) -> disabled, always false", function()
    assert.is_false(M.is_low_hp(1, 100, 0))
    assert.is_false(M.is_low_hp(1, 100, -0.5))
    assert.is_false(M.is_low_hp(0, 100, 0)) -- empty HP still false when the alert is off
    assert.is_false(M.is_low_hp(1, 100, nil)) -- nil threshold == off
  end)

  it("equality boundary cur/max == threshold -> false (strict <)", function()
    assert.is_false(M.is_low_hp(30, 100, 0.3)) -- 0.30 == 0.30, not below
    assert.is_false(M.is_low_hp(50, 100, 0.5))
  end)

  it("just-below the threshold -> true", function()
    assert.is_true(M.is_low_hp(29, 100, 0.3))
    assert.is_true(M.is_low_hp(1, 100, 0.3))
  end)

  it("full HP (cur == max) -> false", function()
    assert.is_false(M.is_low_hp(100, 100, 0.3))
    assert.is_false(M.is_low_hp(150, 150, 0.99))
  end)

  it("empty HP (cur 0, threshold > 0) -> true", function()
    assert.is_true(M.is_low_hp(0, 100, 0.3))
  end)

  it("cur nil -> coerced to 0 -> true when threshold > 0", function()
    assert.is_true(M.is_low_hp(nil, 100, 0.3))
  end)

  it("max nil or <= 0 -> coerced to 1 (same denominator as SetPercent)", function()
    -- with max -> 1: cur/1 = cur. cur 0.2 < 0.3 -> true; cur 0.5 < 0.3 -> false.
    assert.is_true(M.is_low_hp(0.2, nil, 0.3))
    assert.is_false(M.is_low_hp(0.5, nil, 0.3))
    assert.is_true(M.is_low_hp(0.2, 0, 0.3))
    assert.is_true(M.is_low_hp(0.2, -10, 0.3))
  end)

  it("cur > max -> ratio > 1 -> false", function()
    assert.is_false(M.is_low_hp(120, 100, 0.3))
    assert.is_false(M.is_low_hp(120, 100, 0.99))
  end)
end)
