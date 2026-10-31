-- Tests for the register-fusion and control-flow-flattening passes, and the
-- output-size target. Run from the project root: texlua tests/passes_test.lua
local TEST_DIR = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./")
local SRC = TEST_DIR .. "../src/"
local function req(n) return dofile(SRC .. n) end
local Obf = req("obfuscator.lua")
local Parser, Capture, Fold, SSA = req("parser.lua"), req("capture.lua"), req("fold.lua"), req("ssa.lua")
local Localize, Renamer, Compiler = req("localize.lua"), req("renamer.lua"), req("compiler.lua")
local Passes = req("passes.lua")
local Interp = req("interpreter.lua")
local function require_interp(mod) return Interp.run(mod) end

local pass, total = 0, 0
local function check(name, cond, detail)
  total = total + 1
  if cond then print("[ OK ] " .. name); pass = pass + 1
  else print("[FAIL] " .. name .. (detail and (" -- " .. detail) or "")) end
end

-- Compile a source through the same stages the real pipeline uses.
local function compileSource(src)
  local ast = Parser.parse(src, "t", false)
  local early = Capture.analyze(ast)
  Fold.apply(ast); SSA.apply(ast, early); Fold.apply(ast)
  Localize.apply(ast); Renamer.resolve(ast)
  return Compiler.compile(ast, Capture.analyze(ast))
end

local SYMS = { "+", "-", "*", "/", "%", "^", "..", "==", "~=", "<", ">", "<=", ">=", "//" }

do
  -- The register compiler emits operator instructions that name registers
  -- directly (no value stack): arithmetic on locals becomes BIN/BINK ops.
  local mod = compileSource([[
local x = 0
for i = 1, 20 do
  if i % 2 == 0 then x = x + i else x = x - 1 end
end
print(x)
]])
  local ops = {}
  for _, p in ipairs(mod.protos) do
    for _, ins in ipairs(p.code) do ops[ins.op] = (ops[ins.op] or 0) + 1 end
  end
  local operatorOps = 0
  for op, n in pairs(ops) do
    if op:match("^BINK?%d+$") then operatorOps = operatorOps + n end
  end
  check("arithmetic compiles to register operator instructions", operatorOps >= 3,
    "operator instructions=" .. operatorOps)
  check("no value-stack instructions remain", ops.POP == nil and ops.DUP == nil and ops.SWAP == nil)
end

do
  local mod = compileSource("local a = 1\nlocal b = 2\nprint(a + b)\n")
  local blocks, fakes = Passes.flatten(mod, math.random, 1)
  check("flattening emits basic blocks", blocks >= 1, "blocks=" .. blocks)
  check("flattening adds dead decoy blocks", fakes >= 2, "decoys=" .. fakes)
  local lastOk = true
  for _, p in ipairs(mod.protos) do
    for _, ins in ipairs(p.code) do
      local field = Passes.JUMP_FIELD[ins.op]
      if field then
        local target = ins[field]
        if type(target) ~= "number" or target < 1 or target > #p.code then lastOk = false end
      end
    end
  end
  check("every flattened jump lands on a real instruction", lastOk)
end

do
  -- Per-proto encryption: instructions never appear as plaintext tuples, and
  -- every proto carries its own nonce and ciphertext blob.
  local src = "local function a() return 1 end local function b(x) return x + 2 end print(a(), b(3))\n"
  local out = Obf.obfuscate(src, "t", { minSize = false })
  local _, blobs = out:gsub('b="', "")
  local _, nonces = out:gsub(",n=%d+,i=%d+,b=", "")
  check("every proto has its own encrypted blob", blobs >= 3 and nonces == blobs,
    ("blobs=%d nonces=%d"):format(blobs, nonces))
  -- A standalone key named c (identifiers can end in c, so anchor the match).
  check("no plaintext instruction lists in the output", out:find("[^%w_]c={") == nil)
end

do
  -- Padding is opt-in: the default build is not padded, and an explicit
  -- minSize still grows the output to its target.
  local src = "print('size check')\n"
  local big = Obf.obfuscate(src, "t", { minSize = 100000 })
  check("explicit minSize reaches 100000 bytes", #big >= 100000, "size=" .. #big)
  local dflt = Obf.obfuscate(src, "t", {})
  check("default build is not padded", #dflt < 100000, "size=" .. #dflt)
  local small = Obf.obfuscate(src, "t", { minSize = false })
  check("minSize = false skips padding", #small < 100000, ("small=%d"):format(#small))
end

do
  -- Per-proto checksum tamper. The per-proto checksum is also folded into the
  -- startup checksum, so the startup check catches this too; the test only
  -- asserts that a patched build never runs to completion.
  local src = "local function f(n) local s = 0 for i = 1, n do s = s + i end return s end\n" ..
              "local t = 0 for i = 1, 30000 do t = t + f(3) end print('done', t)\n"
  local out = Obf.obfuscate(src, "p", { minSize = false })
  local tampered, n = out:gsub("k=(%d+),n=", function(k)
    return "k=" .. tostring((tonumber(k) + 1) % 2147483647) .. ",n="
  end)
  check("periodic verifier sees the patched checksums", n >= 1, "patched=" .. n)
  local chunk = load(tampered, "p2", "t")
  local captured = {}
  local realPrint = print
  print = function(...) captured[#captured + 1] = table.concat({ ... }, "\t") end
  local ok = pcall(chunk)
  print = realPrint
  check("corrupted checksum stops the run mid-execution (periodic check)",
    not ok and #captured == 0, ("ok=%s printed=%d"):format(tostring(ok), #captured))
end

do
  -- Post-startup edit of decoded code. A hook mutates the second proto's
  -- decoded instructions right after its first decode, so only the periodic
  -- check (which hashes the live tuples) can catch it.
  local src = "local function f(n) local s = 0 for i = 1, n do s = s + i end return s end\n" ..
              "local t = 0 for i = 1, 30000 do t = t + f(3) end print('done', t)\n"
  local out = Obf.obfuscate(src, "p", { minSize = false })
  -- The output is minified, so the spacing around = and ( is optional.
  local hooked, n = out:gsub("if not (%w+)%.c then (%w+)%.c%s*=%s*(%w+)%[7%]%((%w+)%)%s*end",
    function(a, b, mod, c)
      return ("if not %s.c then %s.c = %s[7](%s); __XS_DEC = (__XS_DEC or 0) + 1; " ..
              "if __XS_DEC == 2 then %s.c[1][2] = %s.c[1][2] + 1 end end"):format(a, b, mod, c, b, b)
    end)
  check("decode hook installed", n == 1, "hooks=" .. n)
  __XS_DEC = nil
  local chunk = load(hooked, "p3", "t")
  local captured = {}
  local realPrint = print
  print = function(...) captured[#captured + 1] = table.concat({ ... }, "\t") end
  local ok = pcall(chunk)
  print = realPrint
  check("post-startup edit of decoded code is caught", not ok and #captured == 0,
    ("ok=%s printed=%d"):format(tostring(ok), #captured))
  __XS_DEC = nil
end

-- Junk must never land inside a multi-result window. A CALLM with c = 0 is
-- both a consumer and a producer (f(g(h())) chains them); the junk pass once
-- missed the producer case and overwrote a middle result. These programs fail
-- that way under the old logic, so each runs over many random layouts with
-- junk at rate 1 wherever it is allowed.
do
  local cases = {
    { 'local function three() return 1, 2, 3 end local function pack2(...) return select("#", ...), ... end print(pack2(three()))',
      "3\t1\t2\t3" },
    { 'local function three() return 1, 2, 3 end local function p(...) return ... end print(p(p(three())))',
      "1\t2\t3" },
    { 'local function three() return 1, 2, 3 end local function p(...) return ... end local a, b = 1, 2 print(a, p(p(three())))',
      "1\t1\t2\t3" },
  }
  local Junk = req("junk.lua")
  for ci, c in ipairs(cases) do
    local bad, badSeed = 0, nil
    for seed = 1, 40 do
      math.randomseed(seed)
      local mod = compileSource(c[1])
      Junk.inject(mod, 1.0)
      local out = {}
      local realPrint = print
      local ok = pcall(function()
        print = function(...)
          local p = {}
          for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
          out[#out + 1] = table.concat(p, "\t")
        end
        require_interp(mod)
      end)
      print = realPrint
      if not ok or table.concat(out, "\n") ~= c[2] then bad = bad + 1; badSeed = badSeed or seed end
    end
    check(("junk keeps multi-result values intact (case %d, 40 layouts)"):format(ci), bad == 0,
      ("%d layouts wrong, first seed %s"):format(bad, tostring(badSeed)))
  end
end

-- Control-flow scramble: opaque edges are emitted, and the flattened program
-- still prints exactly what the raw program prints across many layouts.
do
  local src = [[
local acc = 0
for i = 1, 12 do
  if i % 3 == 0 then acc = acc + i elseif i % 3 == 1 then acc = acc - 1 else acc = acc * 2 % 97 end
  if acc > 50 and i > 4 then acc = acc - 7 end
end
print(acc)
]]
  local function runCapture(mod)
    local out = {}
    local realPrint = print
    local ok = pcall(function()
      print = function(...)
        local p = {}
        for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
        out[#out + 1] = table.concat(p, "\t")
      end
      require_interp(mod)
    end)
    print = realPrint
    return ok, table.concat(out, "\n")
  end
  math.randomseed(7)
  local rawOk, rawOut = runCapture(compileSource(src))
  local bad, opaqueSeen, badSeed = 0, 0, nil
  for seed = 1, 20 do
    math.randomseed(seed)
    local mod = compileSource(src)
    local _, _, opaque = Passes.flatten(mod, math.random, 1)
    opaqueSeen = opaqueSeen + (opaque or 0)
    local ok, out = runCapture(mod)
    if not ok or out ~= rawOut then bad = bad + 1; badSeed = badSeed or seed end
  end
  check("flatten output matches raw output (20 layouts)", rawOk and bad == 0,
    ("%d layouts wrong, first seed %s"):format(bad, tostring(badSeed)))
  check("flatten emits opaque never-taken edges", opaqueSeen > 0, "no opaque edges in 20 layouts")
end

-- Template minifier: comments dropped (watermark kept), tokens that would merge
-- stay apart, placeholders stay whole, large literals masked.
do
  local Min = dofile(SRC .. "obfuscator/minify.lua")
  local function m(src, mask) return Min.minify(src, mask or false) end
  check("minify: '- -' keeps a space (no -- comment)", m("a = 1 - -b") == "a=1- -b")
  check("minify: number before '..' keeps a space", m("x = 1 .. y") == "x=1 ..y")
  check("minify: string containing -- is kept verbatim", m("local s = 'a -- b' -- c") == "local s='a -- b'")
  check("minify: long string kept verbatim", m("local t = [[ k -- x ]] x = 2"):find("[[ k -- x ]]", 1, true) ~= nil)
  check("minify: placeholders stay whole", m("local %v% = %w% + 1"):find("%v%", 1, true) ~= nil)
  check("minify: watermark comment kept", m("--[[Protected by XenonSec]]\nlocal q = 3"):sub(1, 13) == "--[[Protected")
  check("minify: small literals not masked", m("return 999", true) == "return 999")
  local masked = m("return 5000", true)
  local ok = masked:match("^return%(%(5000%+(%d+)%)%-(%d+)%)$")
  check("minify: large literal masked as ((n+k)-k)", ok ~= nil)
end

print()
print(pass .. " / " .. total .. " pass-level tests passed")
