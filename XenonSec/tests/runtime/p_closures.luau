local fns = {}
for i = 1, 3 do fns[i] = function() return i end end
print(fns[1](), fns[2](), fns[3]())
local calls = 0
local function getT() calls = calls + 1 return { x = 10 } end
local t = getT()
print(t.x, calls)
