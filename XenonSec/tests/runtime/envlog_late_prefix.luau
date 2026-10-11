-- Installed by the test runner, but NOT activated yet: the protected program
-- calls __swapLogger() partway through its run, so the logger goes in AFTER
-- startup. Only the periodic identity check can catch this.
local __realPrint = print
local __logged = 0
__swapLogger = function()
  print = function(...) __logged = __logged + 1; __realPrint(...) end
end
local __ok, __err = pcall(function(...)
