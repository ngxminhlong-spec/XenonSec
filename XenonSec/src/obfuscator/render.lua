--------------------------------------------------------------------
-- XenonSec :: obfuscator/render.lua
-- Renders the VM engine template: substitutes every %placeholder% with a per-build random identifier, opcode number or generated block.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local load = dofile(dir .. "loader.lua")
local _handlers = load("handlers")
local BINOP_TOKEN_NAMES, UNOP_TOKEN_NAMES, genDecoyHandlers, genOpHandlers = _handlers.BINOP_TOKEN_NAMES, _handlers.UNOP_TOKEN_NAMES, _handlers.genDecoyHandlers, _handlers.genOpHandlers
local _predicates = load("predicates")
local genOpaquePredicate = _predicates.genOpaquePredicate
local _util = load("util")
local randomIdent, substitute, shuffledRange = _util.randomIdent, _util.substitute, _util.shuffledRange

-- Handler self-test. Runs each simple handler against a synthetic frame with
-- known inputs and checks the frame it leaves behind. Numbers are written as
-- arithmetic, and the checks are emitted in a random order. Handlers that
-- depend on scopes, calls or globals are not covered.
local function renderSelfTest(ensureName, OPNUM, BINNUM, UNNUM, KV)
  local _opcodes = load("opcodes")
  local BINOP_SYMBOLS, UNOP_SYMBOLS = _opcodes.BINOP_SYMBOLS, _opcodes.UNOP_SYMBOLS
  local H = ensureName("H")
  local regsF, ipF = ensureName("regs"), ensureName("ip")
  local x2, x3, x4, prF = ensureName("x2"), ensureName("x3"), ensureName("x4"), ensureName("pr")
  local BINOPS, UNOPS = ensureName("BINOPS"), ensureName("UNOPS")
  local run, hc, brick = ensureName("hrun"), ensureName("hcheck"), ensureName("brick")
  local out = {}
  out[#out + 1] = string.format("local function %s(num, a2, a3, a4, init)", run)
  out[#out + 1] = string.format("  local f = { %s = {}, %s = a2, %s = a3, %s = a4, %s = 1, %s = 7 }",
    regsF, x2, x3, x4, ipF, prF)
  out[#out + 1] = string.format("  for i, v in pairs(init) do f.%s[i] = v end", regsF)
  out[#out + 1] = string.format("  %s[num](f, nil)", H)
  out[#out + 1] = string.format("  return f.%s, f.%s", regsF, ipF)
  out[#out + 1] = "end"
  out[#out + 1] = string.format("local function %s()", hc)
  local groups = {}
  local function enc(n)
    local k = math.random(1000, 99999)
    return string.format("((%d + %d) - %d)", n, k, k)
  end
  local function call(num, a2, a3, a4, init)
    return string.format("%s(%s, %s, %s, %s, %s)", run, enc(num), a2, a3, a4, init or "{}")
  end
  local function group(callStr, cond)
    groups[#groups + 1] = { "    r, ip = " .. callStr, "    if not (" .. cond .. ") then return false end" }
  end
  group(call(OPNUM.LOADK, "1", tostring(KV.wm), "0"), 'r[1] == "Protected by XenonSec" and ip == 2')
  group(call(OPNUM.LOADTRUE, "1", "0", "0"), "r[1] == true and ip == 2")
  group(call(OPNUM.LOADFALSE, "1", "0", "0"), "r[1] == false and ip == 2")
  group(call(OPNUM.LOADNIL, "1", "2", "0", "{[1]=5,[2]=6}"), "r[1] == nil and r[2] == nil and ip == 2")
  group(call(OPNUM.MOVE, "1", "2", "0", "{[2]=9}"), "r[1] == 9 and ip == 2")
  group(call(OPNUM.JMP, "40", "0", "0"), "ip == 40")
  group(call(OPNUM.JF, "1", "40", "0", "{[1]=false}"), "ip == 40")
  group(call(OPNUM.JF, "1", "40", "0", "{[1]=0}"), "ip == 2")
  group(call(OPNUM.JT, "1", "40", "0", "{[1]=0}"), "ip == 40")
  group(call(OPNUM.JT, "1", "40", "0", "{[1]=false}"), "ip == 2")
  group(call(OPNUM.JNIL, "1", "40", "0", "{}"), "ip == 40")
  group(call(OPNUM.JNIL, "1", "40", "0", "{[1]=false}"), "ip == 2")
  for k, sym in ipairs(BINOP_SYMBOLS) do
    local num = BINNUM[sym]
    group(call(OPNUM["BIN" .. k], "1", "2", "3", "{[2]=7,[3]=3}"),
      string.format("r[1] == %s[%s](7, 3) and ip == 2", BINOPS, enc(num)))
    group(call(OPNUM["BINK" .. k], "1", "2", tostring(KV.three), "{[2]=7}"),
      string.format("r[1] == %s[%s](7, 3) and ip == 2", BINOPS, enc(num)))
  end
  for k, sym in ipairs(UNOP_SYMBOLS) do
    local v = (sym == "#") and '"abc"' or "5"
    group(call(OPNUM["UN" .. k], "1", "2", "0", "{[2]=" .. v .. "}"),
      string.format("r[1] == %s[%s](%s) and ip == 2", UNOPS, enc(UNNUM[sym]), v))
  end
  out[#out + 1] = "  local r, ip"
  for _, gi in ipairs(shuffledRange(#groups)) do
    out[#out + 1] = groups[gi][1]
    out[#out + 1] = groups[gi][2]
  end
  out[#out + 1] = "    return true"
  out[#out + 1] = "end"
  out[#out + 1] = string.format("if not %s() then %s() end", hc, brick)
  return table.concat(out, "\n")
end

-- Renders the VM engine template: any %N_OPNAME% becomes this build's
-- randomized opcode number; every other %ident% becomes a fresh random
-- identifier (memoized so the same placeholder always maps to the same
-- generated name within this one render).

-- Metamorphic choice: a core handler is the default block or one of its
-- alternatives from templates/core_variants.lua, picked uniformly per build.
local function pickCoreVariant(block, variants)
  local op = variants and block:match("%%H%%%[%%(OP_[%w_]+)%%%]")
  local alts = op and variants[op]
  if not alts then return block end
  local n = math.random(0, #alts)
  if n == 0 then return block end
  return alts[n]
end

local function renderTemplate(template, OPNUM, BINNUM, UNNUM, totalInstr, antiDebug, KV)
  local nameCache = {}
  local function ensureName(tok)
    if not nameCache[tok] then nameCache[tok] = randomIdent() end
    return nameCache[tok]
  end
  local resolve -- forward: core blocks are substituted with the same resolver
  -- Equivalent opcodes. Every extra key is pointed at its opcode's handler,
  -- and the group table RK.g lists all keys of one opcode. RK.rekey, called
  -- from PERIODIC, re-encodes one proto's decoded tuples: each instruction
  -- gets a fresh seed and one of its equivalent keys, and the proto's hash is
  -- updated to match. A dump taken earlier no longer lines up with memory.
  local function renderOpAliases()
    local groups = KV and KV.opGroups
    if not groups then return "" end
    local H, RK = ensureName("H"), ensureName("RK")
    local names = {}
    for name in pairs(groups) do names[#names + 1] = name end
    table.sort(names, function(x, y) return groups[x][1] < groups[y][1] end)
    local stmts, tbl = {}, {}
    for _, name in ipairs(names) do
      local g = groups[name]
      local list = {}
      for i, k in ipairs(g) do list[#list + 1] = tostring(k) end
      for i, k in ipairs(g) do
        if i > 1 then stmts[#stmts + 1] = string.format("%s[%d] = %s[%d]", H, k, H, g[1]) end
        tbl[#tbl + 1] = string.format("[%d] = {%s}", k, table.concat(list, ", "))
      end
    end
    local M, M1, M2 = tostring(KV.MOD), tostring(KV.M1), tostring(KV.M2)
    local dec, pr = ensureName("dec"), ensureName("protos")
    local seed = KV.rekeySeed or 1
    local rekeyFn = table.concat({
      "local " .. RK .. " = { g = {" .. table.concat(tbl, ", ") .. "}, s = " .. seed .. " }",
      RK .. ".rekey = function(pi)",
      "  local pp = " .. pr .. "[pi]",
      "  local code = pp.c",
      "  if not code then return end",
      "  local dh = 5381",
      "  local function hm(n) dh = (dh * 31 + (n or 0)) % 2147483647 end",
      "  for ci = 1, #code do",
      "    local t = code[ci]",
      "    local sd = t[5]",
      "    local key = " .. dec .. "(t[1], sd, 1)",
      "    local a2, a3, a4 = " .. dec .. "(t[2], sd, 2), " .. dec .. "(t[3], sd, 3), " .. dec .. "(t[4], sd, 4)",
      "    local grp = " .. RK .. ".g[key] or { key }",
      "    " .. RK .. ".s = (" .. RK .. ".s * 16807) % 2147483647",
      "    local nk = grp[(" .. RK .. ".s % #grp) + 1]",
      "    " .. RK .. ".s = (" .. RK .. ".s * 16807) % 2147483647",
      "    local ns = " .. RK .. ".s % " .. M,
      "    t[5] = ns",
      "    t[1] = (nk + (ns * " .. M1 .. " + " .. M2 .. ") % " .. M .. ") % " .. M,
      "    t[2] = (a2 + (ns * " .. M1 .. " + 2 * " .. M2 .. ") % " .. M .. ") % " .. M,
      "    t[3] = (a3 + (ns * " .. M1 .. " + 3 * " .. M2 .. ") % " .. M .. ") % " .. M,
      "    t[4] = (a4 + (ns * " .. M1 .. " + 4 * " .. M2 .. ") % " .. M .. ") % " .. M,
      "    hm(ns); hm(t[1]); hm(t[2]); hm(t[3]); hm(t[4])",
      "  end",
      "  pp.i = dh",
      "end",
    }, "\n")
    return table.concat(stmts, "\n") .. "\n" .. rekeyFn
  end
  -- Core handlers, shuffled per build. In Luau output each build also gets a
  -- frame type that lists the VM's real frame fields, and scattered decoy types.
  local function renderCoreHandlers()
    local parts = {}
    if KV.luauTypes then
      parts[#parts + 1] = string.format("type %s = { %s: { number }, %s: number, %s: { [number]: any }, %s: number, %s: %s, %s: any, %s: boolean, %s: any, %s: number, %s: number, %s: number, %s: number, %s: any, %s: boolean, %s: number }",
        ensureName("FrameT"), ensureName("code"), ensureName("ip"), ensureName("regs"), ensureName("top"),
        ensureName("scope"), ensureName("ScopeT"), ensureName("va"), ensureName("fin"), ensureName("ret"),
        ensureName("pr"), ensureName("x2"), ensureName("x3"), ensureName("x4"), ensureName("rv"), ensureName("rn"), ensureName("st"))
      parts[#parts + 1] = string.format("type %s = { %s: { [any]: any }, %s: any }", ensureName("ScopeT"),
        ensureName("varsField"), ensureName("parentField"))
    end
    for _, bi in ipairs(shuffledRange(#KV.coreBlocks)) do
      local blk = pickCoreVariant(KV.coreBlocks[bi], KV.coreVariants)
      if KV.minifyFn then blk = KV.minifyFn(blk) end
      parts[#parts + 1] = substitute(blk, resolve)
      if KV.luauTypes and math.random() < 0.6 then parts[#parts + 1] = KV.scatterType() end
    end
    return table.concat(parts, "\n")
  end
  -- The probe counter lives on the frame, so handlers reach it as F.pr.
  local function probeExpr()
    return ensureName("F") .. "." .. ensureName("pr")
  end
  resolve = function(tok)
    if tok == "ANN_F" then
      return KV.luauTypes and (": " .. ensureName("FrameT")) or ""
    end
    if tok == "ANN_I" then
      return KV.luauTypes and ": { number }" or ""
    end
    if tok == "CORE_HANDLERS" then return renderCoreHandlers() end
    -- MBA (mixed Boolean-arithmetic) for + and -. For non-negative integers
    -- below 2^26 the operator is computed from bitwise identities, so the
    -- dispatcher never holds a plain + or - for those operands:
    --   a + b = (a ^ b) + 2*(a & b)
    --   a - b = (a ^ b) - 2*b + 2*(a & b)
    -- Every other operand (floats, negatives, huge values, strings, tables with
    -- metamethods) takes the real operator, so Lua semantics are unchanged.
    -- The "+ a*0 + b*0" term keeps float results as floats on Lua 5.3.
    if tok == "MBA_HELPERS" then
      if not (KV and KV.mba) then return "" end
      local BX, BA = ensureName("bxor"), ensureName("band")
      local OK, AD, SB = ensureName("mbaOk"), ensureName("mbaAdd"), ensureName("mbaSub")
      return table.concat({
        "local function " .. BA .. "(x, y)",
        "  local r, bit = 0, 1",
        "  while x > 0 and y > 0 do",
        "    local xb, yb = x % 2, y % 2",
        "    if xb == 1 and yb == 1 then r = r + bit end",
        "    x = (x - xb) / 2; y = (y - yb) / 2; bit = bit * 2",
        "  end",
        "  return r",
        "end",
        "local function " .. OK .. "(x, y)",
        -- -0.0 is excluded: it passes the range checks, but the helpers return +0,
        -- and later code can tell the signs apart with 1 / result.
        "  if type(x) ~= 'number' or type(y) ~= 'number' then return false end",
        "  if x < 0 or y < 0 or x >= 67108864 or y >= 67108864 then return false end",
        "  if x % 1 ~= 0 or y % 1 ~= 0 then return false end",
        "  return (x ~= 0 or 1 / x > 0) and (y ~= 0 or 1 / y > 0)",
        "end",
        "local function " .. AD .. "(x, y) return " .. BX .. "(x, y) + 2 * " .. BA .. "(x, y) end",
        "local function " .. SB .. "(x, y) return " .. BX .. "(x, y) - 2 * y + 2 * " .. BA .. "(x, y) end",
      }, "\n")
    end
    if tok == "ARITH_ADD" or tok == "ARITH_SUB" then
      local a, b = ensureName("a"), ensureName("b")
      local op = (tok == "ARITH_ADD") and "+" or "-"
      if not (KV and KV.mba) then return "return " .. a .. " " .. op .. " " .. b end
      local OK = ensureName("mbaOk")
      local fn = ensureName(tok == "ARITH_ADD" and "mbaAdd" or "mbaSub")
      return string.format("if %s(%s, %s) then return %s(%s, %s) + %s * 0 + %s * 0 end return %s %s %s",
        OK, a, b, fn, a, b, a, b, a, op, b)
    end
    if tok == "HANDLER_SELFTEST" then return renderSelfTest(ensureName, OPNUM, BINNUM, UNNUM, KV) end
    if tok == "OPALIASES" then return renderOpAliases() end
    if tok == "ADCHECK" then
      if not antiDebug then return "" end
      -- Three anti-debug checks in the dispatch loop, each at its own random
      -- period and residue of the step counter, so the points where the checks
      -- run differ from build to build. Each one calls adStep with a random
      -- check index (see the anti-debug block in the header).
      local step = ensureName("adStep")
      local out = {}
      for _ = 1, 3 do
        local period = math.random(257, 1499)
        local residue = math.random(0, period - 1)
        -- Indexes 1-5 are live checks and the self-test; 11-14 are code hashes.
        local index = math.random(1, 9)
        if index > 5 then index = index + 5 end
        out[#out + 1] = string.format("if %s %% %d == %d then %s(%d) end",
          probeExpr(), period, residue, step, index)
      end
      return table.concat(out, " ")
    end
    if tok:sub(1, 2) == "N_" then
      local opname = tok:sub(3)
      assert(OPNUM[opname], "unknown opcode placeholder " .. tok)
      return tostring(OPNUM[opname])
    end
    if tok:sub(1, 3) == "BN_" then
      local tokenName = tok:sub(4)
      for sym, name in pairs(BINOP_TOKEN_NAMES) do
        if name == tokenName then return tostring(BINNUM[sym]) end
      end
      error("unknown binop placeholder " .. tok)
    end
    if tok:sub(1, 3) == "UN_" then
      local tokenName = tok:sub(4)
      for sym, name in pairs(UNOP_TOKEN_NAMES) do
        if name == tokenName then return tostring(UNNUM[sym]) end
      end
      error("unknown unop placeholder " .. tok)
    end
    if tok:sub(1, 4) == "OPQ_" then
      -- A fresh nested opaque predicate per opcode, referencing the
      -- shared per-call `probe` counter (always some changing integer
      -- at the point it's checked -- the identities hold for any V).
      -- Depth scales with program size too, same reasoning as the
      -- decoy branches below: a tiny script can afford to spend more
      -- relative weight per dispatch since it has so few of them, while
      -- a huge script keeps depth modest since this cost is paid on
      -- every single opcode dispatch at runtime. Capped at 8 well
      -- below the 15-identity pool so genOpaquePredicate never has to
      -- draw more unique identities than exist.
      local probe = probeExpr()
      local depthBase = 3 + math.floor(2000 / ((totalInstr or 0) + 400))
      if depthBase > 8 then depthBase = 8 end
      return genOpaquePredicate(probe, depthBase + math.random(0, 2))
    end
    if tok:sub(1, 2) == "K_" then
      return tostring(KV[tok:sub(3)])
    end
    if tok == "NEWREGS" then
      if KV and KV.proxify then return "setmetatable({[0] = {}}, " .. ensureName("RMETA") .. ")" end
      return "{}"
    end
    if tok == "NEWVARS" then
      if KV and KV.proxify then return "setmetatable({[0] = {}}, " .. ensureName("VMETA") .. ")" end
      return "{}"
    end
    if tok == "PROXYMETA" then
      if not (KV and KV.proxify) then return "" end
      -- ProxifyLocal. A proxy keeps its real storage in slot [0] (a raw key, so
      -- it never reaches __index). Each stored value sits in a fresh box {v}, so
      -- a register or local never holds a value directly.
      --   RMETA: register i lives at store[(i*PA + PB) % PM]: the register number
      --          never appears as a table key.
      --   VMETA: captured local `name` lives at store[name].
      local RM, VM = ensureName("RMETA"), ensureName("VMETA")
      local pt, pk, pv, pb = ensureName("pxt"), ensureName("pxk"), ensureName("pxv"), ensureName("pxb")
      local A, B, M = tostring(KV.PA), tostring(KV.PB), tostring(KV.PM)
      return table.concat({
        "local " .. RM .. " = {}",
        RM .. ".__index = function(" .. pt .. ", " .. pk .. ") local " .. pb .. " = " .. pt .. "[0][(" .. pk .. " * " .. A .. " + " .. B .. ") % " .. M .. "]; if " .. pb .. " then return " .. pb .. "[1] end return nil end",
        RM .. ".__newindex = function(" .. pt .. ", " .. pk .. ", " .. pv .. ") " .. pt .. "[0][(" .. pk .. " * " .. A .. " + " .. B .. ") % " .. M .. "] = { " .. pv .. " } end",
        "local " .. VM .. " = {}",
        VM .. ".__index = function(" .. pt .. ", " .. pk .. ") local " .. pb .. " = " .. pt .. "[0][" .. pk .. "]; if " .. pb .. " then return " .. pb .. "[1] end return nil end",
        VM .. ".__newindex = function(" .. pt .. ", " .. pk .. ", " .. pv .. ") " .. pt .. "[0][" .. pk .. "] = { " .. pv .. " } end",
      }, "\n")
    end
    if tok == "PERIODIC" then
      -- Every 4096 steps, verify one proto (rotating through them), so an
      -- edit made after startup is caught as well.
      local pidx = ensureName("pidx")
      -- With equivalent opcodes on, a proto that passes its check is then
      -- rekeyed (see OPALIASES). A failed check bricks and is not rekeyed.
      local onFail = "if not " .. ensureName("vp") .. "(" .. pidx .. ") then " .. ensureName("brick") .. "()"
      if KV and KV.opGroups then
        onFail = onFail .. " else " .. ensureName("RK") .. ".rekey(" .. pidx .. ")"
      end
      onFail = onFail .. " end"
      local verify = "if " .. probeExpr() .. " % 4096 == 0 then local " .. pidx .. " = (" ..
             probeExpr() .. " / 4096) % #" .. ensureName("protos") .. " + 1; " .. onFail .. " end"
      -- Decoded constants are cached in a plain table. Flush that cache now and
      -- then, so a dump of the table sees only the constants used lately; each
      -- one is decoded again on its next use.
      local flush = ""
      if KV and KV.flush then
        flush = " if " .. probeExpr() .. " % " .. tostring(KV.flushEvery or 65536) .. " == 0 then for " ..
                ensureName("fk") .. " in pairs(" .. ensureName("consts") .. ") do rawset(" ..
                ensureName("consts") .. ", " .. ensureName("fk") .. ", nil) end end"
      end
      return verify .. flush
    end
    if tok == "DECOY_HANDLERS" then
      -- Scale with program size too: a big real program earns a
      -- proportionally bigger decoy dispatch chain, not just the same
      -- flat handful a one-liner gets.
      return genDecoyHandlers(ensureName, KV.decoyCount, probeExpr, KV.freeKey) .. "\n" ..
             genOpHandlers(ensureName, probeExpr, OPNUM, BINNUM, UNNUM)
    end
    return ensureName(tok)
  end
  return substitute(template, resolve)
end

return {
  renderTemplate = renderTemplate,
}
