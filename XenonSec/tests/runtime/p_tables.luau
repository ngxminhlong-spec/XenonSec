local m = setmetatable({}, { __index = function(_, k) return k .. "!" end })
print(m.hi, rawget(m, "hi"))
local arr = {}
for i = 1, 5 do arr[#arr + 1] = i * i end
print(table.concat(arr, " "), #arr)
