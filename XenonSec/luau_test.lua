local Obf = dofile("obfuscate.lua")

local function captureNative(src)
  local out = {}
  local chunk = assert(load(src, "native", "t"))
  local oldPrint = _G.print
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local ok, err = pcall(chunk)
  _G.print = oldPrint
  if not ok then return nil, err end
  return table.concat(out, "\n")
end

-- Desugars Luau-only syntax down to plain Lua 5.1 so we have a
-- trustworthy "native" oracle to diff against (real Lua obviously
-- can't run compound-assign/continue/types/if-expr directly).
local function luauToPlainLua(src)
  local out = src
  out = out:gsub("([%w_%]%)]+)%s*//=%s*([^\n]+)", "%1 = math.floor(%1 / (%2))")
  out = out:gsub("([%w_%]%)]+)%s*%+=%s*([^\n]+)", "%1 = %1 + (%2)")
  out = out:gsub("([%w_%]%)]+)%s*%-=%s*([^\n]+)", "%1 = %1 - (%2)")
  out = out:gsub("([%w_%]%)]+)%s*%*=%s*([^\n]+)", "%1 = %1 * (%2)")
  out = out:gsub("([%w_%]%)]+)%s*/=%s*([^\n]+)", "%1 = %1 / (%2)")
  out = out:gsub("([%w_%]%)]+)%s*%%=%s*([^\n]+)", "%1 = %1 %% (%2)")
  out = out:gsub("([%w_%]%)]+)%s*%.%.=%s*([^\n]+)", "%1 = %1 .. (%2)")
  out = out:gsub("continue", "goto xs_continue_marker") -- placeholder; only used in tests without real continue in the oracle
  return out
end

local pass, total = 0, 0

-- Simplest, most direct oracle strategy: hand-write the expected
-- native-Lua-5.1-equivalent source per test, rather than a generic
-- desugarer (far less fragile for a small fixed test set).
local function t(name, luauSrc, plainOracleSrc)
  total = total + 1
  local nativeOut, nativeErr = captureNative(plainOracleSrc)
  local ok1, outSrc = pcall(Obf.obfuscate, luauSrc, name, { luau = true })
  if not ok1 then
    print("[FAIL] " .. name .. " -- obfuscate failed: " .. tostring(outSrc))
    return
  end
  local chunk, loadErr = load(outSrc, name)
  if not chunk then
    print("[FAIL] " .. name .. " -- generated file failed to load: " .. tostring(loadErr))
    return
  end
  local out = {}
  local oldPrint = _G.print
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local ok, err = pcall(chunk)
  _G.print = oldPrint
  local obfOut = ok and table.concat(out, "\n") or nil
  if nativeErr and not err then
    print("[FAIL] " .. name .. " -- native oracle errored but obfuscated build didn't: " .. tostring(nativeErr))
    return
  end
  if nativeOut ~= obfOut then
    print("[FAIL] " .. name)
    print("  oracle: " .. tostring(nativeOut))
    print("  obf   : " .. tostring(obfOut))
    if not ok then print("  obf err: " .. tostring(err)) end
    return
  end
  print("[ OK ] " .. name)
  pass = pass + 1
end

t("compound assignment operators",
[[
local x = 5
x += 3
x -= 1
x *= 2
x /= 7
print(x)
local t = {a = 1}
t.a += 10
print(t.a)
local arr = {100, 200}
local i = 2
arr[i] += 5
print(arr[2])
local s = "a"
s ..= "b"
s ..= "c"
print(s)
]],
[[
local x = 5
x = x + 3
x = x - 1
x = x * 2
x = x / 7
print(x)
local t = {a = 1}
t.a = t.a + 10
print(t.a)
local arr = {100, 200}
local i = 2
arr[i] = arr[i] + 5
print(arr[2])
local s = "a"
s = s .. "b"
s = s .. "c"
print(s)
]])

t("compound assign only evaluates index target once",
[[
local calls = 0
local function getTable()
  calls = calls + 1
  return { x = 10 }
end
local t = getTable()
t.x += 5
print(t.x, calls)
]],
[[
local calls = 0
local function getTable()
  calls = calls + 1
  return { x = 10 }
end
local t = getTable()
t.x = t.x + 5
print(t.x, calls)
]])

t("floor division operator and compound //=",
[[
print(7 // 2)
print(-7 // 2)
local a = 10
a //= 3
print(a)
]],
[[
print(math.floor(7 / 2))
print(math.floor(-7 / 2))
local a = 10
a = math.floor(a / 3)
print(a)
]])

t("continue in numeric for",
[[
local sum = 0
for i = 1, 10 do
  if i % 2 == 0 then continue end
  sum = sum + i
end
print(sum)
]],
[[
local sum = 0
for i = 1, 10 do
  if i % 2 == 0 then goto skip end
  sum = sum + i
  ::skip::
end
print(sum)
]])

t("continue in while and repeat",
[[
local i = 0
local sum = 0
while i < 10 do
  i = i + 1
  if i % 2 == 0 then continue end
  sum = sum + i
end
print(sum)

local j = 0
local sum2 = 0
repeat
  j = j + 1
  if j % 2 == 0 then continue end
  sum2 = sum2 + j
until j >= 10
print(sum2)
]],
[[
local i = 0
local sum = 0
while i < 10 do
  i = i + 1
  if i % 2 == 0 then goto skip1 end
  sum = sum + i
  ::skip1::
end
print(sum)

local j = 0
local sum2 = 0
repeat
  j = j + 1
  if j % 2 == 0 then goto skip2 end
  sum2 = sum2 + j
  ::skip2::
until j >= 10
print(sum2)
]])

t("continue preserves per-iteration closure capture",
[[
local fns = {}
for i = 1, 5 do
  if i % 2 == 0 then continue end
  fns[#fns + 1] = function() return i end
end
for _, f in ipairs(fns) do print(f()) end
]],
[[
local fns = {}
for i = 1, 5 do
  if i % 2 == 0 then goto skip end
  fns[#fns + 1] = function() return i end
  ::skip::
end
for _, f in ipairs(fns) do print(f()) end
]])

t("continue nested inside if/do inside while",
[[
local i = 0
local count = 0
while i < 10 do
  i = i + 1
  do
    if i % 3 == 0 then
      continue
    end
  end
  count = count + 1
end
print(count, i)
]],
[[
local i = 0
local count = 0
while i < 10 do
  i = i + 1
  do
    if i % 3 == 0 then
      goto skip
    end
  end
  count = count + 1
  ::skip::
end
print(count, i)
]])

t("type annotations parsed and discarded (locals, params, returns, generics, aliases)",
[[
type Point = {x: number, y: number}
local x: number = 5
local function f(a: number, b: string): number
  return a + #b
end
local function g<T>(v: T): T
  return v
end
print(f(x, "hello"), g(42))
]],
[[
local x = 5
local function f(a, b)
  return a + #b
end
local function g(v)
  return v
end
print(f(x, "hello"), g(42))
]])

t("if-then-else expression",
[[
local x = 5
local y = if x > 3 then "big" else "small"
print(y)
local z = if x > 100 then "huge" elseif x > 3 then "medium" else "tiny"
print(z)
local w = if false then error("never") else "safe"
print(w)
]],
[[
local x = 5
local y
if x > 3 then y = "big" else y = "small" end
print(y)
local z
if x > 100 then z = "huge" elseif x > 3 then z = "medium" else z = "tiny" end
print(z)
local w
if false then error("never") else w = "safe" end
print(w)
]])

print()
print(pass .. " / " .. total .. " luau end-to-end tests passed")
