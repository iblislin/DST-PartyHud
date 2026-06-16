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
-- where each <rec> is 9 fields joined by ":" --
--   userid:hp_cur:hp_max:hp_penalty:hunger:sanity_cur:sanity_max:sanity_penalty:flags
--
-- Separators ("|" and ":") are safe because DST userids are "KU_" + base64-ish [A-Za-z0-9_-] and
-- never contain them (decode still validates and rejects a userid carrying a separator).
--
-- The leading version byte lets a receiver drop payloads it doesn't understand (version skew when
-- one shard hot-reloads a newer build) and gives a no-break upgrade path to a binary format later.

local M = {}

M.PROTOCOL_VERSION = 1
local SUPPORTED = { [1] = true }

-- status flag bits (a single 0..255 integer field)
M.FLAGS = {
	fire      = 1,
	overheat  = 2,
	freeze    = 4,
	dead      = 8,
	ghost     = 16,
}

-- pack a {fire=true, dead=true, ...} table into the integer field
function M.packflags(t)
	local n = 0
	if t ~= nil then
		for name, bit in pairs(M.FLAGS) do
			if t[name] then n = n + bit end
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

local FIELD_SEP  = ":"
local REC_SEP    = "|"
local NUM_FIELDS = 9 -- userid + 8 numerics

-- encode(records [, version]) -> string
-- records: array of { userid=string, hp_cur, hp_max, hp_penalty, hunger,
--                     sanity_cur, sanity_max, sanity_penalty, flags } (8 small ints + userid)
function M.encode(records, version)
	version = version or M.PROTOCOL_VERSION
	local parts = { tostring(version), tostring(#records) }
	for _, r in ipairs(records) do
		local uid = tostring(r.userid or "")
		-- guard: a userid must never carry a separator or it would corrupt the stream
		assert(not uid:find(FIELD_SEP, 1, true) and not uid:find(REC_SEP, 1, true),
			"userid contains a reserved separator: " .. uid)
		parts[#parts + 1] = table.concat({
			uid,
			math.floor((r.hp_cur or 0) + 0.5),
			math.floor((r.hp_max or 0) + 0.5),
			math.floor((r.hp_penalty or 0) + 0.5),
			math.floor((r.hunger or 0) + 0.5),
			math.floor((r.sanity_cur or 0) + 0.5),
			math.floor((r.sanity_max or 0) + 0.5),
			math.floor((r.sanity_penalty or 0) + 0.5),
			math.floor((r.flags or 0) + 0.5),
		}, FIELD_SEP)
	end
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

	local records = {}
	for i = 3, #fields do
		local f = {}
		for tok in (fields[i] .. FIELD_SEP):gmatch("(.-)" .. FIELD_SEP) do
			f[#f + 1] = tok
		end
		if #f ~= NUM_FIELDS then
			return nil, "record " .. (i - 2) .. " has " .. #f .. " fields, expected " .. NUM_FIELDS
		end
		-- Validate each numeric field as we parse it. NOTE the Lua 5.1 trap: assigning a field to
		-- nil (a failed tonumber) just makes the key absent, so a post-hoc `pairs` scan can NEVER
		-- see a nil field. Check inline instead. (This bug was caught by the busted spec.)
		local NUMERIC = { "hp_cur", "hp_max", "hp_penalty", "hunger",
			"sanity_cur", "sanity_max", "sanity_penalty", "flags" }
		local rec = { userid = f[1] }
		for j, name in ipairs(NUMERIC) do
			local x = tonumber(f[j + 1])
			if x == nil then
				return nil, "record " .. (i - 2) .. " field '" .. name .. "' is not a number"
			end
			rec[name] = x
		end
		records[#records + 1] = rec
	end

	return version, records
end

return M
