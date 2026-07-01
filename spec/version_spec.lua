-- busted spec for partyhud_version.is_dev_build -- the gate that decides whether modinfo exposes the
-- dev-only "[Test] Show mock badges" option. Release versions hide it; dev/beta/rc versions show it.
local M = require("partyhud_version")

describe("partyhud_version — is_dev_build", function()
  it("release versions (numeric + dots) are NOT dev (option hidden)", function()
    assert.is_false(M.is_dev_build("2026.13"))
    assert.is_false(M.is_dev_build("2026.14"))
    assert.is_false(M.is_dev_build("2026.13.1")) -- patch release (two dots) still counts as release
    assert.is_false(M.is_dev_build("2025.42"))
    assert.is_false(M.is_dev_build("2027.0"))
  end)

  it("dev / beta / rc versions (alphabetic suffix) ARE dev (option shown)", function()
    assert.is_true(M.is_dev_build("2026.14dev2"))
    assert.is_true(M.is_dev_build("2026.13rc1"))
    assert.is_true(M.is_dev_build("2026.12b1"))
    assert.is_true(M.is_dev_build("2026.14-wip"))
  end)

  it("nil / non-string / empty -> treated as release (safe default: hide the option)", function()
    assert.is_false(M.is_dev_build(nil))
    assert.is_false(M.is_dev_build(""))
    assert.is_false(M.is_dev_build(123))
  end)
end)
