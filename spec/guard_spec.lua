-- spec/guard_spec.lua
--
-- busted unit tests for the pure guard decision logic (scripts/partyhud_guard.lua). The module is
-- engine-free: it takes pcall/xpcall/unpack/tostring/traceback/error/print/state/dev_reraise as
-- INJECTED deps, so these tests drive it with plain stubs on luajit -- no DST runtime, no GLOBAL.
-- modmain.lua wires the same module with the real GLOBAL.-bound builtins.

local guardlogic = require("partyhud_guard")

-- Build a guard runner over a real (Lua) xpcall/pcall + recording print + a fresh state, with a
-- toggleable dev_reraise. Returns the runner + the captured logs for assertions.
local function make_runner(dev_reraise)
  local logs = {}
  local reraise = dev_reraise or false
  local runner = guardlogic.make({
    pcall = pcall,
    xpcall = xpcall,
    unpack = unpack, -- global unpack: present on LuaJIT + the Lua 5.1 std the repo targets
    tostring = tostring,
    traceback = function(e)
      return "TB:" .. tostring(e)
    end,
    error = error,
    print = function(s)
      logs[#logs + 1] = s
    end,
    state = { logged = {} },
    dev_reraise = function()
      return reraise
    end,
  })
  return runner, logs
end

describe("guarded()", function()
  it("calls through and the wrapped fn runs with its args", function()
    local runner = make_runner(false)
    local seen
    local wrapped = runner("ok", function(a, b)
      seen = a + b
    end)
    wrapped(2, 3)
    assert.are.equal(5, seen)
  end)

  it("returns nothing (engine discards callback returns)", function()
    local runner = make_runner(false)
    local wrapped = runner("ret", function()
      return 42
    end)
    local r = wrapped()
    assert.is_nil(r)
  end)

  it("swallows a throw and the wrapper does NOT propagate it", function()
    local runner, logs = make_runner(false)
    local wrapped = runner("boom", function()
      error("kaboom")
    end)
    -- must NOT throw out of wrapped()
    local ok = pcall(function()
      wrapped()
    end)
    assert.is_true(ok)
    assert.are.equal(1, #logs)
    assert.is_truthy(logs[1]:find("boom"))
    assert.is_truthy(logs[1]:find("GUARD caught"))
  end)

  it("logs ONCE per label even when the fn throws repeatedly", function()
    local runner, logs = make_runner(false)
    local wrapped = runner("dup", function()
      error("again")
    end)
    wrapped()
    wrapped()
    wrapped()
    assert.are.equal(1, #logs)
  end)

  it("logs separately for distinct labels", function()
    local runner, logs = make_runner(false)
    runner("a", function()
      error("x")
    end)()
    runner("b", function()
      error("y")
    end)()
    assert.are.equal(2, #logs)
  end)

  it("re-raises when dev_reraise is true", function()
    local runner = make_runner(true)
    local wrapped = runner("dev", function()
      error("surface me")
    end)
    assert.has_error(function()
      wrapped()
    end)
  end)
end)
