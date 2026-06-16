-- spec/run_local.lua
--
-- Minimal busted-compatible shim so the *_spec.lua files run on a plain lua/luajit when busted
-- isn't installed (e.g. this dev box, where installing luarocks/busted would need network access).
-- It implements only the subset of the busted/luassert API the specs use. In CI, ignore this file
-- and run real busted (`busted spec/`, see .busted) -- the spec files are unchanged either way.
--
-- Usage from the repo root:  luajit spec/run_local.lua   (or: lua spec/run_local.lua)

package.path = "scripts/?.lua;spec/?.lua;" .. package.path

-- ---- deep equality (for assert.are.same) ----
local function deepeq(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if not deepeq(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function show(v) return type(v) == "table" and "<table>" or tostring(v) end

-- ---- luassert subset: a callable table (so codec's assert(cond,msg) still works) ----
local asrt = {}
setmetatable(asrt, { __call = function(_, v, msg)
	if not v then error(msg or "assertion failed", 2) end
	return v
end })
asrt.are = {
	same  = function(a, b) if not deepeq(a, b) then error("are.same failed", 2) end end,
	equal = function(a, b) if a ~= b then error("are.equal failed: " .. show(a) .. " ~= " .. show(b), 2) end end,
}
asrt.is_nil    = function(v) if v ~= nil then error("is_nil failed: got " .. show(v), 2) end end
asrt.is_true   = function(v) if v ~= true then error("is_true failed: got " .. show(v), 2) end end
asrt.is_false  = function(v) if v ~= false then error("is_false failed: got " .. show(v), 2) end end
asrt.is_truthy = function(v) if not v then error("is_truthy failed", 2) end end
asrt.is_string = function(v) if type(v) ~= "string" then error("is_string failed", 2) end end
asrt.has_error = function(fn) if pcall(fn) then error("has_error failed: expected an error", 2) end end
_G.assert = asrt

-- ---- describe / it runner ----
local stack, pass, fail, failures = {}, 0, 0, {}
function _G.describe(name, fn) stack[#stack + 1] = name; fn(); stack[#stack] = nil end
function _G.before_each() end -- no-op stub (unused by these specs)
function _G.it(name, fn)
	local full = table.concat(stack, " › ") .. " :: " .. name
	local ok, err = pcall(fn)
	if ok then
		pass = pass + 1
		print("  ok   " .. full)
	else
		fail = fail + 1
		failures[#failures + 1] = full .. "\n        " .. tostring(err)
		print("  FAIL " .. full)
	end
end

-- ---- load + run the spec(s) ----
dofile("spec/statuscodec_spec.lua")

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then
	print("\nfailures:")
	for _, f in ipairs(failures) do print("  - " .. f) end
	os.exit(1)
end
os.exit(0)
