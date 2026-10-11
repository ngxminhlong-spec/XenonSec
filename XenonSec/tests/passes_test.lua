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
  -- Default builds meet the 100 KB size target; minSize = false disables it.
  local src = "print('size check')\n"
  local big = Obf.obfuscate(src, "t", { luau = true })
  check("default build is at least 100000 bytes", #big >= 100000, "size=" .. #big)
  local small = Obf.obfuscate(src, "t", { minSize = false })
  check("minSize = false skips padding", #small < #big, ("small=%d big=%d"):format(#small, #big))
end

do
  -- Periodic anti-tamper: corrupt only the per-proto checksums (the startup
  -- check does not read them), so only the rolling verifier can catch it.
  local src = "local function f(n) local s = 0 for i = 1, n do s = s + i end return s end\n" ..
              "local t = 0 for i = 1, 30000 do t = t + f(3) end print('done', t)\n"
  local out = Obf.obfuscate(src, "p", { minSize = false })
  local tampered, n = out:gsub("k=(%d+),c=", function(k)
    return "k=" .. tostring((tonumber(k) + 1) % 2147483647) .. ",c="
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

print()
print(pass .. " / " .. total .. " pass-level tests passed")
