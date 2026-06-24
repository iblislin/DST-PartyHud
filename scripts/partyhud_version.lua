-- v2026.x: pure version-string classification, extracted so it can be busted-tested with zero engine
-- deps. NOTE: modinfo.lua CANNOT require() this (modinfo runs in DST's restricted pre-environment
-- sandbox, which has no require) -- modinfo MIRRORS M.is_dev_build's one-line expression inline. Keep
-- the two in sync; this module + its spec are the canonical, tested proof of the logic.
local M = {}

-- A RELEASE version is purely numeric + dots (e.g. "2026.13", "2026.14", a patch "2026.13.1",
-- "2025.42"). A DEV / beta / rc build carries an ALPHABETIC suffix (e.g. "2026.14dev2", "2026.13rc1",
-- "2026.12b1"). So "the version string contains a letter" == a dev build. A nil / non-string / empty
-- version is treated as a RELEASE (the safe default -> hide the dev-only [Test] option) rather than
-- erroring. Used to gate the "[Test] Show mock badges" config option: shown on dev builds only.
function M.is_dev_build(version)
  if type(version) ~= "string" then
    return false
  end
  return version:match("%a") ~= nil
end

return M
