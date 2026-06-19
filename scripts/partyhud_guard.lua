-- partyhud_guard.lua
--
-- PURE guard decision logic for the v2026.11 server-side crash guard. ZERO engine dependencies:
-- it takes pcall/xpcall/unpack/tostring/traceback/error/print/state/dev_reraise as INJECTED deps,
-- so it is busted-tested on plain luajit (spec/guard_spec.lua) with stubs. modmain.lua wires it with
-- the GLOBAL.-bound builtins (GLOBAL.pcall/xpcall/unpack/tostring/error + GLOBAL.debug.traceback +
-- GLOBAL.print) because modmain's restricted sandbox (mods.lua:302-331) does NOT whitelist them.
--
-- deps = {
--   pcall, xpcall, unpack, tostring, traceback, error, print,  -- builtins
--   state = { logged = {} },   -- de-dup set, one stack logged per label (not per tick)
--   dev_reraise = function() return <bool> end,  -- when true, re-raise after logging (CI/dogfood)
-- }
--
-- make(deps) -> guarded(label, fn) -> function(...) that runs fn(...) under xpcall, logs the
-- traceback ONCE per label on a throw, swallows, and (if dev_reraise) re-raises. Returns nothing
-- on either path (the engine discards callback returns on all three dispatch paths).

local M = {}

function M.make(deps)
  local xpcall = deps.xpcall
  local unpack = deps.unpack
  local tostring = deps.tostring
  local traceback = deps.traceback
  local error = deps.error
  local print = deps.print
  local state = deps.state
  local dev_reraise = deps.dev_reraise

  local function handler(err)
    return traceback and traceback(err) or tostring(err)
  end

  return function(label, fn)
    return function(...)
      local args = { ... }
      local ok, err = xpcall(function()
        return fn(unpack(args))
      end, handler)
      if not ok then
        if not state.logged[label] then
          state.logged[label] = true
          print("[PartyHud] GUARD caught error in " .. label .. " (further repeats suppressed):\n" .. tostring(err))
        end
        if dev_reraise() then
          error(err, 0)
        end
      end
      return
    end
  end
end

return M
