local TEST_DIR = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./")
local SRC_DIR = TEST_DIR .. "../src/"
local Obf = dofile(SRC_DIR .. 'obfuscator.lua')

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

  -- Tamper a character inside the first proto's encrypted code blob (b="...").
  -- Code is stored only as ciphertext, so this is the bytecode to attack.
  local blobStart = out:find('b="', 1, true)
  check("found an encrypted code blob to tamper", blobStart ~= nil)
  local tuplePos = blobStart and out:find("[%w]", blobStart + 3)
  if tuplePos then
    local c = out:sub(tuplePos, tuplePos)
    local r
    if c:match("%d") then r = tostring((tonumber(c) + 1) % 10)
    elseif c == "z" then r = "a" elseif c == "Z" then r = "A"
    else r = string.char(c:byte() + 1) end
    local tampered = out:sub(1, tuplePos - 1) .. r .. out:sub(tuplePos + 1)
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

--------------------------------------------------------------------
-- Watermark: exactly one readable phrase, and it's load-bearing
--------------------------------------------------------------------

do
  local src = 'print("hi")'
  local out = Obf.obfuscate(src, "t", {})
  local occurrences = select(2, out:gsub("Protected by XenonSec", ""))
  check("watermark phrase appears (comment + gsub-check source)", occurrences >= 1,
    "occurrences=" .. tostring(occurrences))
  check("no other internal field names leak (vars/parent/opcode)",
    not out:find("%f[%a]vars%f[%A]") and not out:find("%f[%a]parent%f[%A]") and not out:find("bad opcode"),
    "one of vars/parent/'bad opcode' was found in output")

  local ok, err, _, output = run(src, {})
  check("watermark-checked build still runs correctly", ok and output == "hi",
    ("ok=%s output=%s err=%s"):format(tostring(ok), tostring(output), tostring(err)))
end


--------------------------------------------------------------------
-- Heavy hardening: decoy dead-code dispatch branches, expanded/deeper
-- opaque predicates, and the CPLX complex junk opcode must all be
-- completely invisible to program behavior.
--------------------------------------------------------------------

do
  local src = [[
local function fib(n) if n<2 then return n end return fib(n-1)+fib(n-2) end
local t = {}
for i=1,8 do t[i] = fib(i) end
print(table.concat(t, ","))
]]
  local ok, err, out, output = run(src, { junkRate = 0.5 })
  check("heavy junk rate (many CPLX + junk instructions) still correct",
    ok and output == "1,1,2,3,5,8,13,21",
    ("ok=%s output=%s err=%s"):format(tostring(ok), tostring(output), tostring(err)))
  -- Handler-table entries: 32 real opcodes plus decoys. A count above 32 means
  -- decoy handlers were emitted (they are never reachable at runtime).
  local _, handlerEntries = out:gsub("%] = function%(", "")
  check("decoy handlers present in output", handlerEntries > 32,
    ("handler entries=%d"):format(handlerEntries))
end

do
  local src = [[
local acc = 0
for i = 1, 20 do
  if i % 3 == 0 then acc = acc + i end
end
local t = {}
for i = 1, 5 do t[i] = function() return i * acc end end
print(acc, t[1](), t[3](), t[5]())
]]
  local allOk = true
  for _ = 1, 8 do
    local ok, err, _, output = run(src, {})
    if not (ok and output == "63\t63\t189\t315") then
      allOk = false
      print("  mismatch: ok=" .. tostring(ok) .. " output=" .. tostring(output) .. " err=" .. tostring(err))
    end
  end
  check("8 independent randomized builds all agree with each other", allOk)
end


do
  -- A debugger attached AFTER startup must still be caught: the periodic
  -- check in the dispatch loop, not just the one-shot startup probe.
  local src = [[
    local n = 0
    for i = 1, 20000 do n = n + i end
    debug.sethook(function() end, "", 1000000)
    local m = 0
    for i = 1, 20000 do m = m + i end
    debug.sethook()
    print("finished", n, m)
  ]]
  local out = Obf.obfuscate(src, "t", { antiDebug = true })
  local captured = {}
  local realPrint = print
  print = function(...)
    local p = {}
    for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
    captured[#captured + 1] = table.concat(p, "\t")
  end
  local chunk = load(out, "t")
  local ok, err = pcall(chunk)
  debug.sethook()
  print = realPrint
  check("mid-run debugger attach is detected (periodic check)", not ok and #captured == 0,
    ("ok=%s captured=%d err=%s"):format(tostring(ok), #captured, tostring(err)))
end

do
  -- Regression: a long single-frame loop used to abort with a bad opcode
  -- once the opaque predicates' probe counter passed ~2^17 (cubic terms
  -- stopped being exact in doubles). Must run to completion in both modes.
  local src = "local t = 0 for i = 1, 200000 do t = t + i end print(t)"
  local expected = "20000100000"
  for _, opts in ipairs({ {}, { antiDebug = true } }) do
    local ok, err, _, output = run(src, opts)
    check("long loop (200k iterations) completes correctly, antiDebug="
      .. tostring(opts.antiDebug == true), ok and output == expected,
      ("ok=%s output=%s err=%s"):format(tostring(ok), tostring(output), tostring(err)))
  end
end

-- Keyed checks (see the anti-debug block in the header). Each case sets up one
-- kind of debugger or tampering; detection means no program output and a
-- failing run, because a fired check changes the decoded key.
local function detectCase(name, src, setup, teardown)
  local out = Obf.obfuscate(src, "t", { antiDebug = true })
  local chunk = load(out, "t")
  local captured = {}
  local realPrint = print
  print = function(...)
    local p = {}
    for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
    captured[#captured + 1] = table.concat(p, "\t")
  end
  local ok, err = pcall(function()
    local runner = setup(chunk)
    if runner then return runner() end
  end)
  if teardown then teardown() end
  print = realPrint
  check(name, not ok and #captured == 0,
    ("ok=%s captured=%d err=%s"):format(tostring(ok), #captured, tostring(err)))
end

do
  -- Check 3: a wrapper around debug.gethook installed BEFORE load is caught
  -- by the native check, because the captured hook probe is a Lua function.
  local src = 'print("wrapped")'
  local realGethook = debug.gethook
  detectCase("a wrapped debug.gethook (installed before load) is detected", src,
    function(chunk)
      debug.gethook = function(...) return realGethook(...) end
      local out = Obf.obfuscate(src, "t", { antiDebug = true })
      return load(out, "t")
    end,
    function() debug.gethook = realGethook end)
end

do
  -- Check 2: a hook on a running coroutine (not the main thread) is caught.
  local src = 'print("in coroutine")'
  detectCase("a debug hook on a coroutine is detected", src,
    function(chunk)
      local co = coroutine.create(chunk)
      debug.sethook(co, function() end, "", 1000000)
      return function() local okc, errc = coroutine.resume(co); if not okc then error(errc) end; return errc end
    end,
    nil)
end

do
  -- Check 4: the debug library's fields are compared with what was captured at
  -- load. Replacing one after load is caught by the periodic checks.
  local src = "local n = 0 for i = 1, 50000 do n = n + i end print('done', n)"
  local realGethook = debug.gethook
  detectCase("a debug field replaced after load is detected (cross-check)", src,
    function(chunk)
      return function()
        debug.gethook = function(...) return realGethook(...) end
        local r = chunk()
        return r
      end
    end,
    function() debug.gethook = realGethook end)
end

do
  -- Placement: the periodic checks are emitted at several points, and the
  -- rest of the build is unchanged when anti-debug is off.
  local src = "local t = 0 for i = 1, 3000 do t = t + i end print(t)"
  -- Names are randomized, so match the shape: "if <counter> % <period> ==
  -- <residue> then <name>(<index>) end" (the minifier may drop spaces).
  local shape = "if [%w_%.]+%s*%%%s*%d+%s*==%s*%d+%s*then%s*[%w_]+%(%d%)%s*end"
  local out = Obf.obfuscate(src, "t", { antiDebug = true })
  local _, calls = out:gsub(shape, "")
  check("anti-debug build places several periodic checks", calls >= 3, "placements=" .. calls)
  local plain = Obf.obfuscate(src, "t", {})
  local _, plainCalls = plain:gsub(shape, "")
  check("antiDebug off places no periodic checks", plainCalls == 0, "placements=" .. plainCalls)
end

do
  -- Code check: editing one anti-debug check's code is caught even with no
  -- debugger attached. The build hashes each check's stripped bytecode, and
  -- the run compares it with the hash the build recorded (Lua 5.3 builds).
  if _VERSION == "Lua 5.3" then
    local src = 'print("clean run")'
    local out = Obf.obfuscate(src, "t", { antiDebug = true })
    local clean = load(out, "t")
    local captured = {}
    local realPrint = print
    print = function(...) captured[#captured + 1] = table.concat({ ... }, "\t") end
    local okClean = pcall(clean)
    print = realPrint
    check("unedited anti-debug build runs with no debugger", okClean and #captured == 1)
    local tampered, n = out:gsub("return 53", "return 54", 1)
    check("tamper target found in the output", n == 1, "n=" .. n)
    local bad = load(tampered, "t")
    captured = {}
    print = function(...) captured[#captured + 1] = table.concat({ ... }, "\t") end
    local okBad = pcall(bad)
    print = realPrint
    check("an edited check is caught with no debugger attached", not okBad and #captured == 0,
      ("ok=%s captured=%d"):format(tostring(okBad), #captured))
  end
end

print()
print(pass .. " / " .. total .. " anti-tamper/anti-debug tests passed")
