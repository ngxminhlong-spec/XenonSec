local Obf = dofile("obfuscate.lua")

local pass, total = 0, 0
local function check(name, cond, detail)
  total = total + 1
  if cond then
    print("[ OK ] " .. name)
    pass = pass + 1
  else
    print("[FAIL] " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

local function run(src, opts)
  local out = Obf.obfuscate(src, "t", opts)
  local chunk, loadErr = load(out, "t")
  if not chunk then return nil, "LOAD_FAILED: " .. tostring(loadErr), out end
  local captured = {}
  local oldPrint = print
  print = function(...)
    local p = {}
    for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
    captured[#captured + 1] = table.concat(p, "\t")
  end
  local ok, err = pcall(chunk)
  print = oldPrint
  return ok, err, out, table.concat(captured, "\n")
end

--------------------------------------------------------------------
-- Anti-tamper
--------------------------------------------------------------------

do
  local src = [[
print("hello world")
local x = 40 + 2
print(x)
]]
  local out = Obf.obfuscate(src, "t", {})
  local ok1, err1, _, output1 = run(src, {})
  check("untampered output runs correctly", ok1 and output1 == "hello world\n42",
    ("ok=%s output=%s"):format(tostring(ok1), tostring(output1)))

  -- Tamper a byte squarely inside the first bytecode instruction tuple.
  local tuplePos = out:find("{%d+,%d+,%d+,%d+}")
  check("found a bytecode tuple to tamper", tuplePos ~= nil)
  if tuplePos then
    local pos = tuplePos -- position of the opening '{'... flip the char right after it
    local origByte = out:byte(pos + 2)
    local tampered = out:sub(1, pos + 1) .. string.char((origByte + 5) % 256) .. out:sub(pos + 3)
    local chunk, loadErr = load(tampered, "t2")
    if not chunk then
      check("tampered bytecode fails safely (load-time)", true)
    else
      local ok, err = pcall(chunk)
      check("tampered bytecode fails safely (runtime)", not ok,
        "tampering was NOT caught -- ran successfully with ok=" .. tostring(ok))
    end
  end
end

do
  -- With antiTamper explicitly disabled, the checksum check must not fire.
  local src = 'print("still works")'
  local ok, err, _, output = run(src, { antiTamper = false })
  check("antiTamper=false still runs correctly (no false trip)", ok and output == "still works",
    ("ok=%s output=%s err=%s"):format(tostring(ok), tostring(output), tostring(err)))
end

--------------------------------------------------------------------
-- Anti-debug: must have zero effect on normal execution when enabled,
-- and must not accidentally activate when disabled (the default).
--------------------------------------------------------------------

do
  local src = [[
print("a")
local t = {1,2,3}
for k,v in pairs(t) do print(k,v) end
local ok = pcall(function() error("x") end)
print(ok)
]]
  local ok, err, _, output = run(src, { antiDebug = true })
  local expected = "a\n1\t1\n2\t2\n3\t3\nfalse"
  check("antiDebug=true has zero effect on normal execution", ok and output == expected,
    ("ok=%s output=%q err=%s"):format(tostring(ok), tostring(output), tostring(err)))
end

do
  -- Simulate an env-logger: replace print with a __call-metatable proxy.
  local src = 'print("secret")'
  local out = Obf.obfuscate(src, "t", { antiDebug = true })
  local realPrint = print
  local logged = {}
  _G.print = setmetatable({}, { __call = function(_, ...)
    logged[#logged + 1] = table.concat({ ... }, " ")
    return realPrint(...)
  end })
  local chunk = load(out, "t")
  local ok, err = pcall(chunk)
  _G.print = realPrint
  check("env-logger proxy is detected and neutralized", not ok and #logged == 0,
    ("ok=%s logged=%d err=%s"):format(tostring(ok), #logged, tostring(err)))
end

do
  -- debug.sethook simulates an attached debugger; must be caught.
  local src = 'print("secret2")'
  local out = Obf.obfuscate(src, "t", { antiDebug = true })
  local captured = {}
  local realPrint = print
  print = function(...)
    local p = {}
    for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
    captured[#captured + 1] = table.concat(p, "\t")
  end
  debug.sethook(function() end, "", 1000000) -- a real, if trivial, hook
  local chunk = load(out, "t")
  local ok, err = pcall(chunk)
  debug.sethook()
  print = realPrint
  check("an active debug hook is detected and neutralized", not ok and #captured == 0,
    ("ok=%s captured=%d err=%s"):format(tostring(ok), #captured, tostring(err)))
end

do
  -- Without --antidebug (the default), a hook must NOT trigger anything --
  -- avoiding false positives is the whole reason it's opt-in.
  local src = 'print("normal")'
  local out = Obf.obfuscate(src, "t", {}) -- antiDebug defaults to false
  local captured = {}
  local realPrint = print
  print = function(...)
    local p = {}
    for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
    captured[#captured + 1] = table.concat(p, "\t")
  end
  debug.sethook(function() end, "", 1000000)
  local chunk = load(out, "t")
  local ok = pcall(chunk)
  debug.sethook()
  print = realPrint
  check("antiDebug default (off) does not false-positive on a hook", ok and captured[1] == "normal",
    ("ok=%s captured=%s"):format(tostring(ok), tostring(captured[1])))
end

--------------------------------------------------------------------
-- No plaintext operator tables
--------------------------------------------------------------------

do
  local src = [[
local a = 1 + 2 - 3 * 4 / 5 % 6 ^ 7 // 2
local b = "x" .. "y"
local c = (a == 1) and (a ~= 1) or (a < 1) and (a > 1) and (a <= 1) and (a >= 1)
local d = -a
local e = not c
local f = #"hello"
print(a, b, c, d, e, f)
]]
  local out = Obf.obfuscate(src, "t", {})
  local leaked = {}
  for _, sym in ipairs({ "+", "-", "*", "/", "%", "^", "%.%.", "==", "~=", "<=", ">=", "not", "#" }) do
    local pat = '%["' .. sym:gsub("(%p)", "%%%1") .. '"%]%s*='
    if out:find(pat) then leaked[#leaked + 1] = sym end
  end
  check("no operator-symbol table keys anywhere in output", #leaked == 0,
    "found: " .. table.concat(leaked, ","))

  local ok, err, _, output = run(src, {})
  check("full operator sweep still executes correctly", ok, tostring(err))
end

print()
print(pass .. " / " .. total .. " anti-tamper/anti-debug tests passed")
