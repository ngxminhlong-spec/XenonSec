local T = dofile("difftest.lua")
local pass, total = 0, 0
local function t(name, src)
	total = total + 1
	if T.test(name, src) then pass = pass + 1 end
end

t("shadowing a stdlib global with a local", [[
local function f()
  local pairs = function(t) return "fake" end
  return pairs({1,2,3})
end
print(f())
local t = {10,20}
for k,v in pairs(t) do print(k,v) end
]])

t("shadowing across sibling scopes with same spelling", [[
do local x = 1; print(x) end
do local x = "two"; print(x) end
local x = 3
print(x)
]])

t("closures capturing loop variable per-iteration", [[
local fns = {}
for i = 1, 3 do
  fns[i] = function() return i end
end
print(fns[1](), fns[2](), fns[3]())
]])

t("recursive local function", [[
local function fact(n)
  if n <= 1 then return 1 end
  return n * fact(n - 1)
end
print(fact(6))
]])

t("method definition sugar and dotted function statement", [[
local obj = {}
function obj:greet(name)
  return self.prefix .. name
end
obj.prefix = "hi "
print(obj:greet("bob"))

Mod = {}
function Mod.util(x) return x * 2 end
print(Mod.util(21))
]])

t("generic for with custom stateless iterator", [[
local function range(n)
  local i = 0
  return function()
    i = i + 1
    if i <= n then return i end
  end
end
for v in range(3) do print(v) end
]])

t("break from nested if inside while, then more code runs correctly", [[
local i = 0
while true do
  i = i + 1
  if i == 3 then
    do
      break
    end
  end
end
print("stopped at", i)
local x = 100
print(x + 1)
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

t("break inside generic for followed by more locals", [[
local t = {"a","b","c","d"}
for i,v in ipairs(t) do
  if v == "c" then break end
  print(i, v)
end
local z = "after"
print(z)
]])

t("nested loops: inner break only exits inner loop", [[
for i = 1, 3 do
  for j = 1, 5 do
    if j == 2 then break end
    print("i,j", i, j)
  end
end
print("done")
]])

t("many uncaptured locals across sibling blocks (register reuse safety)", [[
local function f()
  local total = 0
  do local a = 1; total = total + a end
  do local a = 2; total = total + a end
  do local a = 3; total = total + a end
  return total
end
print(f())
]])

t("mix of captured and uncaptured locals in same function", [[
local function make()
  local captured_val = 100
  local plain_val = 5
  local getter = function() return captured_val end
  plain_val = plain_val + 1
  captured_val = captured_val + 1
  return getter(), plain_val
end
print(make())
]])

t("deeply nested functions with mixed capture depths", [[
local function outer()
  local a = 1
  local function mid()
    local b = 2
    local function inner()
      return a + b
    end
    b = b + 10
    return inner()
  end
  a = a + 100
  return mid()
end
print(outer())
]])

t("recursive function with uncaptured local accumulator", [[
local function sumTo(n)
  local acc = 0
  local function step(i)
    if i > n then return acc end
    acc = acc + i
    return step(i + 1)
  end
  return step(1)
end
print(sumTo(10))
]])

t("register reuse across many sequential locals in one function", [[
local function f()
  local a = 1
  local b = 2
  local c = 3
  local d = a + b + c
  local e = d * 2
  local g = e - 1
  return g
end
print(f())
]])

t("uncaptured for-loop variable never observably shared across iterations", [[
local results = {}
for i = 1, 5 do
  results[i] = i * i
end
print(table.concat(results, ","))
]])

t("captured for-loop variable still gets fresh binding per iteration", [[
local fns = {}
for i = 1, 3 do
  local doubled = i * 2
  fns[i] = function() return i, doubled end
end
for k = 1, 3 do print(fns[k]()) end
]])

t("basic arithmetic", [[
print(1+2, 3*4, 10/4, 10%3, 2^10)
]])

t("string concat and length", [[
local s = "hello" .. " " .. "world"
print(s, #s)
]])

t("if/elseif/else", [[
for i = 1, 5 do
  if i == 1 then print("one")
  elseif i == 2 then print("two")
  elseif i == 3 then print("three")
  else print("other", i)
  end
end
]])

t("while and break", [[
local i = 0
while true do
  i = i + 1
  if i > 5 then break end
  print("w", i)
end
]])

t("repeat until", [[
local i = 0
repeat
  i = i + 1
  print("r", i)
until i >= 3
]])

t("numeric for with step", [[
for i = 10, 1, -2 do print(i) end
]])

t("generic for pairs", [[
local t = {10,20,30}
local sum = 0
for i, v in ipairs(t) do sum = sum + v end
print(sum)
]])

t("recursion (factorial)", [[
local function fact(n)
  if n <= 1 then return 1 end
  return n * fact(n - 1)
end
print(fact(10))
]])

t("closures / upvalues", [[
local function counter()
  local n = 0
  return function()
    n = n + 1
    return n
  end
end
local c1 = counter()
local c2 = counter()
print(c1(), c1(), c1(), c2())
]])

t("tables and methods", [[
local obj = { value = 10 }
function obj:add(x)
  self.value = self.value + x
  return self.value
end
print(obj:add(5), obj:add(1))
]])

t("multiple return + multiple assign", [[
local function two() return 1, 2 end
local a, b, c = two()
print(a, b, c)
local d, e = two(), 100
print(d, e)
print(two())
local t = {two(), two()}
print(t[1], t[2], t[3])
]])

t("varargs", [[
local function sum(...)
  local s = 0
  local n = select("#", ...)
  for i = 1, n do s = s + select(i, ...) end
  return s, n
end
print(sum(1,2,3,4))
]])

t("and/or short circuit", [[
local a = nil
print(a and a.x or "default")
local b = 5
print(b and "yes" or "no")
print(false or nil or 3)
]])

t("string library interop", [[
print(string.upper("hi"), ("abc"):sub(1,2), string.format("%d-%s", 5, "x"))
]])

t("nested tables and multiple assignment swap", [[
local a, b = 1, 2
a, b = b, a
print(a, b)
local t = {}
t.x, t.y = 1, 2
print(t.x, t.y)
]])

t("table constructor with trailing call expansion", [[
local function three() return 7, 8, 9 end
local t = {1, 2, three()}
print(#t, t[1], t[2], t[3], t[4])
]])

t("pcall + error handling interop", [[
local ok, err = pcall(function() error("boom") end)
print(ok, err ~= nil)
]])

t("do block scoping", [[
local x = 1
do
  local x = 2
  print("inner", x)
end
print("outer", x)
]])

t("unary ops", [[
local t = {1,2,3}
print(-5, not false, #t, not nil)
]])

t("string.gsub with pattern (stdlib passthrough)", [[
print((("hello world"):gsub("o", "0")))
]])

t("metatables passthrough", [[
local mt = { __index = function(t,k) return "missing:"..k end }
local t = setmetatable({}, mt)
print(t.foo)
]])

print(string.format("\n%d / %d tests passed", pass, total))
if pass ~= total then os.exit(1) end
