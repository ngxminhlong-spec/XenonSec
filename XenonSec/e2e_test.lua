local Obf = dofile("obfuscate.lua")

local function captureNative(src)
  local out = {}
  local env_print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local chunk = assert(load(src, "native", "t"))
  local oldPrint = _G.print
  _G.print = env_print
  local ok, err = pcall(chunk)
  _G.print = oldPrint
  if not ok then return nil, err end
  return table.concat(out, "\n")
end

local function captureObfuscated(src, name)
  local ok1, outSrc = pcall(Obf.obfuscate, src, name)
  if not ok1 then return nil, "obfuscate failed: " .. tostring(outSrc) end
  local chunk, loadErr = load(outSrc, name)
  if not chunk then return nil, "generated file failed to load: " .. tostring(loadErr) end
  local out = {}
  local env_print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local oldPrint = _G.print
  _G.print = env_print
  local ok, err = pcall(chunk)
  _G.print = oldPrint
  if not ok then return nil, err end
  return table.concat(out, "\n")
end

local pass, total = 0, 0
local function t(name, src)
  total = total + 1
  local nativeOut, nativeErr = captureNative(src)
  local obfOut, obfErr = captureObfuscated(src, name)
  if nativeErr and not obfErr then
    print("[FAIL] " .. name .. " -- native errored but obfuscated build didn't: " .. tostring(nativeErr))
    return
  end
  if nativeOut ~= obfOut then
    print("[FAIL] " .. name)
    print("  native: " .. tostring(nativeOut))
    print("  obf   : " .. tostring(obfOut))
    if obfErr then print("  obf err: " .. tostring(obfErr)) end
    return
  end
  print("[ OK ] " .. name)
  pass = pass + 1
end

t("basic arithmetic", [[
print(1+2, 3*4, 10/4, 10%3, 2^10)
]])

t("closures capturing loop var per-iteration", [[
local fns = {}
for i = 1, 3 do fns[i] = function() return i end end
print(fns[1](), fns[2](), fns[3]())
]])

t("break inside nested numeric for with closures surviving", [[
local saved
for i = 1, 5 do
  if i == 3 then
    saved = function() return i end
    break
  end
end
print(saved())
local y = 7
print(y * 2)
]])

t("recursion + method calls + tables", [[
local function fact(n) if n <= 1 then return 1 end return n * fact(n-1) end
local obj = {}
function obj:greet(name) return self.prefix .. name end
obj.prefix = "hi "
print(fact(6), obj:greet("bob"))
]])

t("varargs and multiple returns", [[
local function f(...) return select("#", ...), ... end
print(f(1,2,3))
local function g() return 1,2,3 end
local a,b,c = g()
print(a,b,c)
local t = {g()}
print(#t)
]])

t("string library interop and pattern matching", [[
local s = "  hello world  "
print(s:gsub("%s+", "_"))
print(string.format("%05d|%s", 7, "ok"))
]])

t("pcall + error handling interop", [[
local ok, err = pcall(function() error("boom") end)
print(ok, err ~= nil)
local ok2, v = pcall(function() return 1+1 end)
print(ok2, v)
]])

t("generic for with pairs, table constructor with trailing call", [[
local function multi() return 10,20,30 end
local t = {1,2,multi()}
for i,v in ipairs(t) do print(i,v) end
]])

t("shadowing stdlib global with local", [[
local function f()
  local pairs = function(t) return "fake" end
  return pairs({1,2,3})
end
print(f())
local t = {10,20}
for k,v in pairs(t) do print(k,v) end
]])

t("nested loops with inner break, and metatables", [[
for i = 1, 2 do
  for j = 1, 5 do
    if j == 2 then break end
    print("ij", i, j)
  end
end
local mt = { __index = function(t,k) return "default:" .. k end }
local obj = setmetatable({}, mt)
print(obj.missing)
]])

t("constant folding of literal arithmetic", [[
print(2 + 3 * 4, (10 - 2) / 4, 2^10, -(-5), 7 % 3)
local x = 100
print(x + (5*5-25) + 1)
]])

t("global write must NOT be localized (real global mutation)", [[
counter = 0
local function bump() counter = counter + 1 end
bump(); bump(); bump()
print(counter)
print(_G.counter)
]])

t("many stdlib globals used repeatedly (localize stress)", [[
for i = 1, 3 do
  print(string.upper("go"), math.floor(3.7), table.concat({1,2,3}, "-"))
end
print(type(1), type("s"), type({}), type(print))
print(tostring(42), tonumber("42") + 1)
]])

t("deeply nested junk-safe control flow", [[
local acc = 0
for i = 1, 4 do
  if i % 2 == 0 then
    local j = 0
    while j < i do
      acc = acc + j
      j = j + 1
    end
  else
    do
      acc = acc + i
    end
  end
end
print(acc)
]])

t("SSA: propagation + dead store + while loop through full pipeline", [[
local unused = 1 + 2
local a = 5
local b = a + 2
print(b)

local n = 5
local i = 0
while i < n do
  i = i + 1
end
print(i)

local k = 0
repeat
  k = k + 1
until k >= 3
print(k)
]])

t("SSA: closure capturing a would-be-propagated local", [[
local x = 5
local function getX() return x end
x = x + 10
print(getX(), x)
]])

print()
print(pass .. " / " .. total .. " end-to-end obfuscated tests passed")
