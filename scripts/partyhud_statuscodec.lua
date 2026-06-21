-- partyhud_statuscodec.lua
--
-- v2026.8 cross-shard status payload codec (Tier-0 spike).
--
-- Pure Lua, ZERO engine dependencies (no GLOBAL / net_* / TheWorld) so it can be unit-tested
-- under busted with nothing mocked. modmain.lua will `require` this and feed it the same integer
-- status values the existing per-player netvar hooks already compute.
--
-- WIRE FORMAT (custom-text + protocol version byte, chosen over JSON: ~3.7x smaller, ~7-8x faster
-- to encode/decode on LuaJIT, human-readable for logging/debugging; see the v2026.8 research memo):
--
--   <version>|<count>|<rec>|<rec>|...
--
-- where each <rec> is a version-dependent number of fields joined by ":" --
--   v1 (9 fields):  userid:hp_cur:hp_max:hp_penalty:hunger:sanity_cur:sanity_max:sanity_penalty:flags
--   v2 (10 fields): ...:flags:origin   (origin = the numeric shard id the record came from)
--   v3 (14 fields): ...:origin:temp:temp_rate:moisture:moisture_rate
--
-- The per-record field count is therefore version-aware: v1=9, v2=10, v3=14. v2 appends a single
-- numeric `origin` field after `flags`; v3 further appends temp, temp_rate, moisture, moisture_rate
-- after origin. A v1 payload omits origin (nil); a v2 payload omits temp/moisture (nil).
-- All new numeric fields are NEVER stringified.
--
-- Separators ("|" and ":") are safe because DST userids are "KU_" + base64-ish [A-Za-z0-9_-] and
-- never contain them (decode still validates and rejects a userid carrying a separator).
--
-- The leading version byte lets a receiver drop payloads it doesn't understand (version skew when
-- one shard hot-reloads a newer build) and gives a no-break upgrade path to a binary format later.
-- Both v1 and v2 payloads are accepted on decode for backward compatibility.

local M = {}

M.PROTOCOL_VERSION = 3
local SUPPORTED = { [1] = true, [2] = true, [3] = true }

-- status flag bits (a single 0..255 integer field)
M.FLAGS = {
  fire = 1,
  overheat = 2,
  freeze = 4,
  dead = 8,
  ghost = 16,
}

-- pack a {fire=true, dead=true, ...} table into the integer field
function M.packflags(t)
  local n = 0
  if t ~= nil then
    for name, bit in pairs(M.FLAGS) do
      if t[name] then
        n = n + bit
      end
    end
  end
  return n
end

-- unpack the integer field back into a {fire=bool, overheat=bool, ...} table
function M.unpackflags(n)
  n = n or 0
  local t = {}
  for name, bit in pairs(M.FLAGS) do
    t[name] = (math.floor(n / bit) % 2) == 1
  end
  return t
end

local FIELD_SEP = ":"
local REC_SEP = "|"
local NUM_FIELDS = 9 -- v1 baseline: userid + 8 numerics (v2 = NUM_FIELDS+1, adds origin; v3 = NUM_FIELDS+5)

-- A de-dup set so a surprise out-of-range value logs ONCE per field name, not once per 0.5s payload.
local _clamp_logged = {}

-- clamp_num(v, lo, hi, name) -> clamped value, logging once if it was out of range. hi may be nil
-- (no upper bound). Used at the decode boundary for the numerics whose out-of-range value would
-- misrender. Clamps + KEEPS the record (structural rejection stays the job of the nil+reason returns).
local function clamp_num(v, lo, hi, name)
  local c = v
  if lo ~= nil and c < lo then
    c = lo
  end
  if hi ~= nil and c > hi then
    c = hi
  end
  if c ~= v and not _clamp_logged[name] then
    _clamp_logged[name] = true
    print(
      "[PartyHud] codec clamped out-of-range '"
        .. name
        .. "' ("
        .. tostring(v)
        .. " -> "
        .. tostring(c)
        .. "); further repeats suppressed"
    )
  end
  return c
end

-- encode(records [, version]) -> string
-- records: array of { userid=string, hp_cur, hp_max, hp_penalty, hunger,
--                     sanity_cur, sanity_max, sanity_penalty, flags [, origin]
--                     [, temp, temp_rate, moisture, moisture_rate] }
--   8 small ints + userid for v1; v2 additionally emits the numeric `origin` (shard id);
--   v3 additionally emits temp, temp_rate, moisture, moisture_rate after origin.
-- version defaults to M.PROTOCOL_VERSION; the field count emitted matches the version
--   (v1=9, v2=10, v3=14).
function M.encode(records, version)
  version = version or M.PROTOCOL_VERSION
  -- The count header MUST match the records the body actually emits. ipairs (correctly) stops at
  -- the first nil hole, while `#records` on a sparse array is undefined in Lua 5.1 -- so deriving
  -- the header from `#records` could disagree with the body and make the receiver reject the whole
  -- payload. Count what the loop emits instead (index 2 is a placeholder, patched after the loop).
  local parts = { tostring(version), "0" }
  local count = 0
  for _, r in ipairs(records) do
    local uid = tostring(r.userid or "")
    -- guard: a userid must never carry a separator or it would corrupt the stream
    assert(
      not uid:find(FIELD_SEP, 1, true) and not uid:find(REC_SEP, 1, true),
      "userid contains a reserved separator: " .. uid
    )
    count = count + 1
    -- The field count emitted MUST match the version: v1 = 9 fields, v2 = 10 (appends origin).
    local rec = {
      uid,
      math.floor((r.hp_cur or 0) + 0.5),
      math.floor((r.hp_max or 0) + 0.5),
      math.floor((r.hp_penalty or 0) + 0.5),
      math.floor((r.hunger or 0) + 0.5),
      math.floor((r.sanity_cur or 0) + 0.5),
      math.floor((r.sanity_max or 0) + 0.5),
      math.floor((r.sanity_penalty or 0) + 0.5),
      math.floor((r.flags or 0) + 0.5),
    }
    if version >= 2 then
      -- origin is NUMERIC (the shard id the record came from); never stringify it.
      rec[#rec + 1] = math.floor((r.origin or 0) + 0.5)
    end
    if version >= 3 then
      -- v3 appends temp, temp_rate, moisture, moisture_rate after origin.
      rec[#rec + 1] = math.floor((r.temp or 0) + 0.5)
      rec[#rec + 1] = math.floor((r.temp_rate or 0) + 0.5)
      rec[#rec + 1] = math.floor((r.moisture or 0) + 0.5)
      rec[#rec + 1] = math.floor((r.moisture_rate or 0) + 0.5)
    end
    parts[#parts + 1] = table.concat(rec, FIELD_SEP)
  end
  parts[2] = tostring(count)
  return table.concat(parts, REC_SEP)
end

-- decode(str) -> version, records   OR   nil, errmsg
-- Never throws on malformed input -- returns nil + a reason so a receiving handler can log & drop.
function M.decode(str)
  if type(str) ~= "string" or str == "" then
    return nil, "empty or non-string payload"
  end

  local fields = {}
  for tok in (str .. REC_SEP):gmatch("(.-)" .. REC_SEP) do
    fields[#fields + 1] = tok
  end
  if #fields < 2 then
    return nil, "truncated header"
  end

  local version = tonumber(fields[1])
  if version == nil then
    return nil, "non-numeric version"
  end
  if not SUPPORTED[version] then
    return nil, "unsupported protocol version " .. tostring(version)
  end

  local count = tonumber(fields[2])
  if count == nil then
    return nil, "non-numeric count"
  end
  if #fields - 2 ~= count then
    return nil, "record count mismatch (header says " .. count .. ", got " .. (#fields - 2) .. ")"
  end

  -- Per-record field count is version-aware:
  --   v1 = NUM_FIELDS (9), v2 = NUM_FIELDS+1 (adds origin), v3 = NUM_FIELDS+5 (adds temp/moisture).
  local nfields
  if version >= 3 then
    nfields = NUM_FIELDS + 5
  elseif version >= 2 then
    nfields = NUM_FIELDS + 1
  else
    nfields = NUM_FIELDS
  end

  -- Numeric field names (parsed in order from f[2..]). v2 appends "origin" after "flags";
  -- v3 further appends "temp", "temp_rate", "moisture", "moisture_rate" after "origin".
  -- A v1 payload omits origin entirely (nil); a v2 payload omits temp/moisture (nil).
  local NUMERIC = { "hp_cur", "hp_max", "hp_penalty", "hunger", "sanity_cur", "sanity_max", "sanity_penalty", "flags" }
  if version >= 2 then
    NUMERIC[#NUMERIC + 1] = "origin"
  end
  if version >= 3 then
    NUMERIC[#NUMERIC + 1] = "temp"
    NUMERIC[#NUMERIC + 1] = "temp_rate"
    NUMERIC[#NUMERIC + 1] = "moisture"
    NUMERIC[#NUMERIC + 1] = "moisture_rate"
  end

  local records = {}
  for i = 3, #fields do
    local f = {}
    for tok in (fields[i] .. FIELD_SEP):gmatch("(.-)" .. FIELD_SEP) do
      f[#f + 1] = tok
    end
    if #f ~= nfields then
      return nil, "record " .. (i - 2) .. " has " .. #f .. " fields, expected " .. nfields
    end
    -- Validate each numeric field as we parse it. NOTE the Lua 5.1 trap: assigning a field to
    -- nil (a failed tonumber) just makes the key absent, so a post-hoc `pairs` scan can NEVER
    -- see a nil field. Check inline instead. (This bug was caught by the busted spec.)
    local rec = { userid = f[1] }
    for j, name in ipairs(NUMERIC) do
      local x = tonumber(f[j + 1])
      if x == nil then
        return nil, "record " .. (i - 2) .. " field '" .. name .. "' is not a number"
      end
      -- Decode-boundary clamp (Q3): the current-value fields would misrender if negative. Clamp them
      -- to >= 0 and KEEP the record (structural rejection stays the job of the nil+reason returns).
      -- Skip flags (unpackflags ignores undefined bits), sanity rate, origin, and the *_max/*_penalty
      -- fields (already clamped by record.normalize_*'s max>0 clamp) -- the new yield is the cur>=0 floor.
      if name == "hp_cur" or name == "hunger" or name == "sanity_cur" then
        rec[name] = clamp_num(x, 0, nil, name)
      else
        rec[name] = x
      end
    end
    records[#records + 1] = rec
  end

  return version, records
end

-- ============================================================================================
-- STARTUP SELF-CHECK (Q4). Runs at require-time, inside the engine's xpcall (mods.lua), so a
-- broken codec build (a bad NUM_FIELDS / NUMERIC / FLAGS / SUPPORTED / PROTOCOL_VERSION edit) fails
-- LOUDLY here and disables the mod cleanly -- instead of failing silently inside the guarded() 2 Hz
-- broadcast task, which would swallow it. Bare assert/tonumber are safe: this module is required into
-- full _G, NOT modmain's restricted sandbox.
-- ============================================================================================
assert(SUPPORTED[M.PROTOCOL_VERSION], "PROTOCOL_VERSION " .. tostring(M.PROTOCOL_VERSION) .. " is not in SUPPORTED")
do
  -- encode->decode a probe record and assert it survives, so the wire format is provably coherent
  -- before the first real broadcast.
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
      temp = 75,
    },
  }
  local ver, out = M.decode(M.encode(probe))
  assert(ver == M.PROTOCOL_VERSION, "self-check: decoded version mismatch")
  assert(out ~= nil and out[1] ~= nil, "self-check: probe failed to round-trip")
  assert(
    out[1].userid == "KU_selfcheck" and out[1].hp_cur == 100 and out[1].origin == 1 and out[1].temp == 75,
    "self-check: probe field mismatch"
  )
end

return M
