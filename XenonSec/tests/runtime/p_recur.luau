local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end
print(fib(20))
local ok, err = pcall(function() error("boom") end)
print(ok, string.find(tostring(err), "boom") ~= nil)
