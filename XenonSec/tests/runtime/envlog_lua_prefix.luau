-- Installed by the test runner BEFORE the protected code runs: a logger that
-- wraps print in a plain Lua closure. type() still says "function", so only
-- the C-function identity check can catch it.
local __realPrint = print
local __logged = 0
print = function(...) __logged = __logged + 1; __realPrint(...) end
local __ok, __err = pcall(function(...)
