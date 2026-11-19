-- Installed by the test runner BEFORE the protected code runs: an
-- attacker-style logger that wraps the builtin @NAME@ in a callable table
-- which counts every call and forwards it to the real function.
local __realPrint = print
local __realPcall = pcall
local __logged = 0
local __real = @NAME@
@NAME@ = setmetatable({}, { __call = function(_, ...) __logged = __logged + 1; return __real(...) end })
