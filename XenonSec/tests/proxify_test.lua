-- ProxifyLocal tests: every program runs natively and obfuscated with
-- proxify=true (alone, with antiDebug, and with a size target), and the
-- captured output must match exactly. Also checks that proxify really
-- changes the emitted engine (proxy metatables present) and that tampering
-- with a protected build is still caught.
local TEST_DIR = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./")
local Obf = dofile(TEST_DIR .. "../src/obfuscator.lua")

local pass, total = 0, 0
local function check(name, cond, detail)
  total = total + 1
  if cond then pass = pass + 1; print("[ OK ] " .. name)
  else print("[FAIL] " .. name .. (detail and (" -- " .. detail) or "")) end
end

local Iso = dofile(TEST_DIR .. "isolate.lua")
-- Runs the source in its own process (see isolate.lua), so the harness never
-- replaces print inside the process running the protected code.
local function capture(src)
  return Iso.exec(src)
end

local function runNative(src)
  return capture(src)
end

local function runObf(src, opts)
  local out = Obf.obfuscate(src, "t", opts)
  local chunk, lerr = load(out, "t")
  if not chunk then return false, "LOAD_FAILED: " .. tostring(lerr), nil, out end
  local ok, err, text = capture(out)
  return ok, err, text, out
end

local programs = {
  { "captured counter", [[
local n = 0
local function inc() n = n + 1; return n end
inc(); inc()
print(inc(), n)
]] },
  { "closures sharing upvalue", [[
local function mk()
  local v = 10
  return function() v = v + 1; return v end, function() return v end
end
local a, b = mk()
a(); a()
print(b(), a())
]] },
  { "recursion with locals", [[
local function fib(k)
  if k < 2 then return k end
  local a = fib(k - 1)
  local b = fib(k - 2)
  return a + b
end
print(fib(15))
]] },
  { "varargs and multiple returns", [[
local function three() return 1, 2, 3 end
local function pack2(...) return select("#", ...), ... end
local t = { three() }
print(#t, pack2(three()))
print(pack2(nil, nil))
]] },
  { "table and string ops", [[
local t = {}
for i = 1, 20 do t[#t + 1] = i * i end
local s = {}
for i, v in ipairs(t) do if i % 5 == 0 then s[#s + 1] = tostring(v) end end
print(table.concat(s, ","), #t)
print(("abc"):upper(), string.rep("x", 3))
]] },
  { "nested captured loops", [[
local fs = {}
for i = 1, 3 do
  for j = 1, 2 do
    fs[#fs + 1] = function() return i * 10 + j end
  end
end
local out = {}
for _, f in ipairs(fs) do out[#out + 1] = f() end
print(table.concat(out, " "))
]] },
  { "many locals (register pressure)", [[
local a1, a2, a3, a4, a5, a6, a7, a8 = 1, 2, 3, 4, 5, 6, 7, 8
local b1 = a1 + a2 * a3 - a4
local b2 = a5 .. a6
local c = { a7, a8, b1, b2 }
print(a1 + a8, b1, b2, #c, c[4])
]] },
  { "pcall and error", [[
local ok, err = pcall(function() local x = nil; return x.y end)
print(ok, type(err))
local ok2, v = pcall(function() return 7 end)
print(ok2, v)
]] },
  { "goto-free while with break", [[
local i, acc = 0, 0
while true do
  i = i + 1
  if i > 50 then break end
  if i % 3 == 0 then acc = acc + i end
end
print(i, acc)
]] },
}

-- 1. Each program, proxify alone and with antiDebug.
for _, p in ipairs(programs) do
  local name, src = p[1], p[2]
  local nok, nerr, nout = runNative(src)
  for _, opts in ipairs({ { proxify = true, minSize = false },
                          { proxify = true, antiDebug = true, minSize = false },
                          { proxify = true, luau = false, minSize = 100000 } }) do
    local label = ("%s [proxify%s%s]"):format(name,
      opts.antiDebug and "+antidebug" or "", opts.minSize and "+size" or "")
    local ok, err, text, out = runObf(src, opts)
    check(label, ok == nok and text == nout,
      ("ok=%s/%s text=%q want=%q err=%s"):format(tostring(ok), tostring(nok),
        tostring(text), tostring(nout), tostring(err)))
  end
end

-- 2. Proxify must actually be in the emitted engine.
do
  local src = "local x = 1; local function f() return x end; print(f())"
  local plain = Obf.obfuscate(src, "t", { minSize = false })
  local px = Obf.obfuscate(src, "t", { minSize = false, proxify = true })
  check("proxify off: no proxy constructors emitted", not plain:find("[0] = {}}", 1, true))
  check("proxify on: proxy constructors emitted", px:find("[0] = {}}", 1, true) ~= nil)
end

-- 3. Tampering a protected proxify build must be caught (no silent wrong output).
do
  local src = 'print("hello world")\nlocal x = 40 + 2\nprint(x)\n'
  local out = Obf.obfuscate(src, "t", { proxify = true, minSize = false })
  local ok0, _, text0 = capture(out)
  check("proxify untampered build is correct", ok0 and text0 == "hello world\n42")
  -- Flip one character inside the first numeric tuple, the same way
  -- protection_test does for the plain build.
  local pos = out:find("{%d+,%d+,%d+,%d+,%d+}")
  if pos then
    local b = out:byte(pos + 2)
    local bad = out:sub(1, pos + 1) .. string.char((b + 5) % 256) .. out:sub(pos + 3)
    local chunk = load(bad, "t2")
    if not chunk then check("proxify tampered build fails safely (load)", true)
    else
      local ok, _, text = capture(bad)
      check("proxify tampered build does not run clean", not (ok and text == "hello world\n42"),
        "tamper went unnoticed")
    end
  else
    check("found a tuple to tamper", false)
  end
end

print(("\nproxify suite: %d / %d tests passed"):format(pass, total))
if pass ~= total then os.exit(1) end
