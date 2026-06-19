-- spec/support/json.lua
--
-- Pure-Lua (Lua 5.1 / LuaJIT, no external deps, no `require`) CANONICAL JSON encoder.
-- Used by the spec suite to serialize layout-snapshot tables into DETERMINISTIC JSON so
-- golden snapshots diff cleanly across runs.
--
-- Determinism guarantees:
--   * Object keys are emitted in ASCENDING string order (table.sort on the stringified key).
--   * Floats are ROUNDED to opts.float_dp decimal places (default 2) to kill float jitter.
--   * Output is pretty-printed (2-space indent, newlines) for human-readable golden diffs.
--
-- Lua 5.1 only: no `goto`, no `//`, no `bit` lib. Only string.format / table.concat /
-- table.sort / pairs / ipairs are used.
--
-- Usage:
--   local json = require("support.json")   -- or dofile("spec/support/json.lua")
--   local s = json.encode(snapshot, { float_dp = 2 })

local M = {}

-- Sentinel a caller can use to force an explicit JSON `null` in a map value position
-- (a plain Lua `nil` value cannot live in a table, so this is the only way to express it).
M.null = setmetatable({}, {
  __tostring = function()
    return "null"
  end,
})

-- ---- number rounding -------------------------------------------------------
--
-- Round-half-AWAY-from-zero to `dp` decimal places. We add 0.5 toward the sign of x
-- before flooring the absolute value, so 0.185 -> 0.19 and -0.185 -> -0.19 symmetrically.
-- (Plain `math.floor(x*p + 0.5)` would round -0.185 toward zero, which is asymmetric.)
local function round(x, dp)
  local p = 10 ^ dp
  if x >= 0 then
    return math.floor(x * p + 0.5) / p
  else
    return -math.floor(-x * p + 0.5) / p
  end
end

-- Format a number deterministically:
--   * non-finite (nan / inf) is not valid JSON -> emit `null` (defensive; snapshots shouldn't hit this).
--   * integral values print with no decimal point (5, -130) regardless of float_dp.
--   * otherwise round to float_dp places and strip trailing-zero / trailing-dot noise
--     (0.184 with dp=2 -> "0.18", 1.50 -> "1.5", 2.00 -> "2").
local function format_number(x, dp)
  -- NaN is the only value not equal to itself; +/-inf compares == to itself but overflows here.
  if x ~= x or x == math.huge or x == -math.huge then
    return "null"
  end
  local r = round(x, dp)
  -- Integral after rounding? print as a bare integer. %d would overflow/garble large or
  -- fractional-origin values, so format with enough precision then trim.
  if r == math.floor(r) and math.abs(r) < 1e15 then
    return string.format("%d", r)
  end
  -- Fixed-precision then strip trailing zeros and any dangling decimal point.
  local s = string.format("%." .. dp .. "f", r)
  s = s:gsub("0+$", "")
  s = s:gsub("%.$", "")
  return s
end

-- ---- string escaping -------------------------------------------------------
local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escape_string(s)
  -- Escape the named controls first, then any remaining control char (< 0x20) as \uXXXX.
  return '"'
    .. s:gsub('["\\%c]', function(c)
      local mapped = ESCAPES[c]
      if mapped then
        return mapped
      end
      return string.format("\\u%04x", string.byte(c))
    end)
    .. '"'
end

-- ---- array vs object classification ----------------------------------------
--
-- A table is an ARRAY iff it has n>0 contiguous integer keys 1..n and NO other keys.
-- Empty tables are treated as OBJECTS (emit `{}`) by default; opts.empty_array flips that.
local function array_length(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  local count = 0
  for _ in ipairs(t) do
    count = count + 1
  end
  -- ipairs stops at the first nil; if its count equals the total pair count and is > 0,
  -- the keys are exactly the contiguous run 1..count -> it's a clean array.
  if count > 0 and count == n then
    return count
  end
  return nil
end

-- ---- core encoder ----------------------------------------------------------
local encode_value -- forward declaration

local function indent_str(depth)
  return string.rep("  ", depth) -- 2-space indent
end

local function encode_table(t, depth, opts, out)
  local arrlen = array_length(t)

  if arrlen then
    -- JSON array
    out[#out + 1] = "[\n"
    for i = 1, arrlen do
      out[#out + 1] = indent_str(depth + 1)
      encode_value(t[i], depth + 1, opts, out)
      if i < arrlen then
        out[#out + 1] = ","
      end
      out[#out + 1] = "\n"
    end
    out[#out + 1] = indent_str(depth)
    out[#out + 1] = "]"
    return
  end

  -- JSON object. Collect string-coerced keys and sort ascending for determinism.
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end

  if #keys == 0 then
    if opts.empty_array then
      out[#out + 1] = "[]"
    else
      out[#out + 1] = "{}"
    end
    return
  end

  -- Sort by the stringified key so numeric and string keys order deterministically.
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  out[#out + 1] = "{\n"
  for i = 1, #keys do
    local k = keys[i]
    out[#out + 1] = indent_str(depth + 1)
    out[#out + 1] = escape_string(tostring(k))
    out[#out + 1] = ": "
    encode_value(t[k], depth + 1, opts, out)
    if i < #keys then
      out[#out + 1] = ","
    end
    out[#out + 1] = "\n"
  end
  out[#out + 1] = indent_str(depth)
  out[#out + 1] = "}"
end

encode_value = function(v, depth, opts, out)
  local tv = type(v)
  if v == nil or v == M.null then
    out[#out + 1] = "null"
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    out[#out + 1] = format_number(v, opts.float_dp)
  elseif tv == "string" then
    out[#out + 1] = escape_string(v)
  elseif tv == "table" then
    encode_table(v, depth, opts, out)
  else
    -- functions / userdata / threads are not JSON-encodable; fail loudly so a snapshot
    -- bug surfaces in the spec rather than silently producing garbage.
    error("json.encode: cannot encode value of type '" .. tv .. "'")
  end
end

-- M.encode(value, opts) -> string
--   opts.float_dp    number of decimal places to round floats to (default 2)
--   opts.empty_array if true, an empty table encodes as `[]` (default: `{}`)
function M.encode(value, opts)
  opts = opts or {}
  if opts.float_dp == nil then
    opts.float_dp = 2
  end
  local out = {}
  encode_value(value, 0, opts, out)
  return table.concat(out)
end

return M
