-- XenonSec full test suite runner.
-- Run from the repository root with:
--   lua XenonSec/test_all.lua
-- or from inside the XenonSec directory with:
--   lua test_all.lua

local script_path = arg and arg[0] or ""
local script_dir = script_path:match("^(.*)[/\\]") or "."
if script_dir ~= "." then
  local ok, err = os.chdir(script_dir)
  if not ok then
    error("failed to enter XenonSec dir: " .. tostring(err))
  end
end

local suites = {
  "run_tests.lua",
  "ssa_test.lua",
  "e2e_test.lua",
  "luau_test.lua",
  "protection_test.lua",
}

print("=== XenonSec full suite ===")
for _, name in ipairs(suites) do
  print("\n--- running " .. name .. " ---")
  local ok, err = pcall(dofile, name)
  if not ok then
    print("[FAIL] " .. name .. " failed to execute: " .. tostring(err))
    os.exit(1)
  end
end

print("\n=== all XenonSec test suites completed ===")
