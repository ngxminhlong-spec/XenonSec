type Pt = { x: number, y: number }
local function add(a: Pt, b: Pt): Pt return { x = a.x + b.x, y = a.y + b.y } end
local p = add({ x = 1, y = 2 }, { x = 3, y = 4 })
print(`p = {p.x},{p.y}`)
local n = 0
for i = 1, 10 do
  if i % 2 == 0 then continue end
  n += i
end
local t = { 1, 2, 3 }
t[2] *= 10
print(n, t[2], 17 // 5)
local v = if n > 20 then "big" else "small"
print(v)
for k, x in t do print(k, x) end
print(0b1010, 1_000, "\u{41}")
