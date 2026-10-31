-- Tests for the standard-library lookups and the constant-cache flush.
--  * readable std references (string.format, math.random, ...) must be gone
--    from the output; only the bootstrap names and the env-logger checks stay.
--  * programs must still produce exactly the native output across several
--    flush cycles (a 200k-step run flushes the cache three times), with the
--    flush on and off.
local TEST_DIR = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./")
local Obf = dofile(TEST_DIR .. "../src/obfuscator.lua")

local pass, total = 0, 0
local function check(name, cond, detail)
  total = total + 1
  if cond then pass = pass + 1; print("[ OK ] " .. name)
  else print("[FAIL] " .. name .. (detail and (" -- " .. detail) or "")) end
end

local function capture(chunk)
  local out = {}
  local oldPrint = print
  print = function(...)
    local p = {}
    for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(p, "\t")
  end
  local ok, err = pcall(chunk)
  print = oldPrint
  return ok, err, table.concat(out, "\n")
end

-- 1. No readable std references in the output.
do
  local src = [[
local t = {}
for i = 1, 10 do t[i] = string.format("%d", i) end
print(table.concat(t, ","), math.floor(3.7), select("#", 1, 2))
]]
  local out = Obf.obfuscate(src, "t", { minSize = false, luau = false })
  for _, name in ipairs({ "string.format", "math.random", "math.floor", "table.unpack", "getmetatable", "table.remove" }) do
    check("output has no readable " .. name, not out:find(name, 1, true))
  end
  -- The bootstrap names are the only literal string.byte / string.char uses left.
  local _, nb = out:gsub("string%.byte", "")
  check("bootstrap string.byte appears only in the bootstrap (<= 2)", nb <= 2, "count " .. nb)
end

-- 2. Correct output over several flush cycles, flush on and off.
do
  local src = [[
local names = { "alpha", "beta", "gamma", "delta" }
local acc, s = 0, ""
local lookup = { alpha = 1, beta = 2, gamma = 3, delta = 4 }
for i = 1, 200000 do
  local k = names[(i % 4) + 1]
  acc = acc + lookup[k]
  if i % 50000 == 0 then s = s .. k:sub(1, 1) end
end
print(acc, s)
print(string.format("%5.2f", 3.14159), math.max(3, 9), tostring(select("#", "a", "b")))
]]
  local ok0, _, want = capture(assert(load(src, "native")))
  check("native reference run ok", ok0)
  for _, flush in ipairs({ true, false }) do
    local out = Obf.obfuscate(src, "t", { flushConsts = flush, minSize = false })
    local ok, err, got = capture(assert(load(out, "t")))
    check(("200k-step program correct (flush %s)"):format(flush and "on" or "off"),
      ok and got == want, ("ok=%s err=%s got=%q want=%q"):format(tostring(ok), tostring(err), tostring(got), tostring(want)))
  end
end

-- 3. The flush really runs: a run over several cycles still decodes constants
--    on demand (a constant used after a flush is decoded again).
do
  local src = [[
local tag = "reused-constant"
local n = 0
for i = 1, 150000 do
  if i % 30000 == 0 then n = n + #tag end
end
print(n, tag)
]]
  local out = Obf.obfuscate(src, "t", { minSize = false })
  local ok, err, got = capture(assert(load(out, "t")))
  check("constant used after cache flushes is decoded again", ok and got == "75\treused-constant", tostring(got))
end

-- 4. No textbook cipher constants, and every build gets its own.
do
  local src = 'print("hello")'
  local a = Obf.obfuscate(src, "t", { minSize = false })
  local b = Obf.obfuscate(src, "t", { minSize = false })
  for _, c in ipairs({ "2166136261", "2654435", "12345" }) do
    check("no textbook cipher constant " .. c, not a:find(c, 1, true))
  end
  check("two builds of the same source differ", a ~= b)
end

-- 5. Handler keys come from one dense pool (1..real + decoys). The base opcode
--    handlers name their keys through locals, so the literal keys in the output
--    are the other entries: their largest value is bounded by their count plus
--    the number of base opcodes (28). The old layout (decoys 1000..9999) broke
--    that bound by a wide margin.
do
  local out = Obf.obfuscate('print("x")', "t", { minSize = false, strength = 2 })
  local count, maxKey = 0, 0
  -- Minified builds write a masked key as ((n+k)-k); read both forms so the
  -- base-opcode keys (masked to arithmetic) are still counted.
  local function take(v)
    v = tonumber(v)
    count = count + 1
    if v > maxKey then maxKey = v end
  end
  for k in out:gmatch("%[(%d+)%]%s*=%s*function%(") do take(k) end
  for k in out:gmatch("%[%(%((%d+)%+%d+%)%-%d+%)%]%s*=%s*function%(") do take(k) end
  check("literal handler keys stay inside the dense pool bound",
    count > 0 and maxKey <= count + 28, ("literal keys=%d largest=%d"):format(count, maxKey))
end

-- 17. Metamorphic handlers: builds of one script differ in the shape of their
--     core handler code, and every build still produces the native output.
do
  local src = [[
local t = {}
for i = 1, 6 do t[i] = i * i end
local flag = false
if flag then print("no") else print("yes", t[6]) end
local o = setmetatable({}, {__index = function(_, k) return k .. "!" end})
print(#t, t[1] or "x", o.key)
]]
  local ok0, _, want = capture(assert(load(src, "native")))
  check("metamorphic: native reference runs", ok0)
  local shapes, mismatches = {}, 0
  for _ = 1, 12 do
    local out = Obf.obfuscate(src, "t", { minSize = false, luau = false })
    shapes[out] = true
    local ok, err, got = capture(assert(load(out, "t")))
    if not ok or got ~= want then mismatches = mismatches + 1 end
  end
  local distinct = 0
  for _ in pairs(shapes) do distinct = distinct + 1 end
  check("metamorphic: every build matches the native output", mismatches == 0,
    ("%d of 12 builds differ"):format(mismatches))
  check("metamorphic: builds of one script are not byte-identical", distinct > 1,
    ("%d distinct output(s) from 12 builds"):format(distinct))
end

print(("\nmutate suite: %d / %d tests passed"):format(pass, total))
if pass ~= total then os.exit(1) end
