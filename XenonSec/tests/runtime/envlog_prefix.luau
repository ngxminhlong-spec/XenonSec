-- Installed by the test runner BEFORE the protected code runs: an
-- attacker-style logger that wraps print in a callable table.
local __realPrint = print
local __logged = 0
print = setmetatable({}, { __call = function(_, ...) __logged = __logged + 1; __realPrint(...) end })
local __ok, __err = pcall(function(...)
