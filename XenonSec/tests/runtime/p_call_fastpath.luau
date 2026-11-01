-- Call and return shapes that the CALL / RET fast paths handle.
local function one(a) return a end
local function none() end
local function nilret() return nil end
local function two(a, b) return a, b end
local function three(a, b, c) return a, b, c end
local function va(...) return select("#", ...), ... end

local out = {}
local function put(...) out[#out + 1] = table.concat({ tostring(...) }, " ") end

put(one(7), one(nil), none(), nilret())
local x, y = two(1, 2)
put(x, y)
local p, q = two(nil, "z")
put(tostring(p), q)
local a, b, c = three(1, 2, 3)
put(a, b, c)
local n, first = va(10, 20, 30)
put(n, first)
local k, v = pcall(one, "ok")
put(k, v)
local ok = pcall(function() local f; f(1) end)
put(ok)

local s = 0
for i = 1, 50 do s = s + one(i) + select(2, two(i, i)) end
put(s)

local t = { alpha = 1, beta = 2 }
local keys = {}
for kk, vv in pairs(t) do keys[#keys + 1] = kk .. "=" .. vv end
table.sort(keys)
put(table.concat(keys, ","))

for _, line in ipairs(out) do print(line) end
