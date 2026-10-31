-- Long-running code across several protos. The periodic check verifies and
-- rekeys one proto every 4096 steps, so this run cycles through all of them
-- many times; output must match the raw run exactly.
local function step(a, b)
  local t = a * 3 + b
  if t % 2 == 0 then t = t // 2 else t = t + 1 end
  return t % 100003
end

local function accumulate(n)
  local acc = 0
  for i = 1, n do
    acc = (acc + step(i, acc % 7)) % 1000003
  end
  return acc
end

local function label(v)
  return "v" .. tostring(v)
end

local total = 0
for round = 1, 12 do
  total = (total + accumulate(3000 + round)) % 1000003
end
print("total", total)
print(label(total), select("#", accumulate(10)))

local t = {}
for i = 1, 500 do t[i] = step(i, i) end
local s = 0
for _, v in ipairs(t) do s = s + v end
print("sum", s)
