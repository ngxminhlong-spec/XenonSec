--------------------------------------------------------------------
-- XenonSec :: obfuscate.lua
-- Turns a Lua 5.1 source file into a single self-contained, obfuscated
-- output file that runs on a randomized-opcode bytecode VM embedded
-- in the output itself.
--------------------------------------------------------------------

local scriptDir = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./")
local function req(name) return dofile(scriptDir .. name) end

local Parser = req("parser.lua")
local Fold = req("fold.lua")
local SSA = req("ssa.lua")
local Localize = req("localize.lua")
local Renamer = req("renamer.lua")
local Capture = req("capture.lua")
local Compiler = req("compiler.lua")
local Junk = req("junk.lua")

math.randomseed(os.time() + (tonumber(tostring({}):match("0x(%x+)"), 16) or 0))
-- burn a few values; Lua's stock PRNG is weak but this is for build-time
-- diversification (opcode shuffles / keys), not cryptographic security.
for _ = 1, 8 do math.random() end

--------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------

local ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
local function randomIdent(len)
  len = len or (6 + math.random(0, 5))
  local chars = {}
  for i = 1, len do
    local idx = math.random(1, #ALPHABET)
    chars[i] = ALPHABET:sub(idx, idx)
  end
  return "_" .. table.concat(chars)
end

local function shuffledRange(n)
  local t = {}
  for i = 1, n do t[i] = i end
  for i = n, 2, -1 do
    local j = math.random(1, i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

local function randomByteKey(len)
  local bytes = {}
  for i = 1, len do bytes[i] = math.random(1, 255) end
  return bytes
end

--------------------------------------------------------------------
-- XOR without relying on Lua 5.3 bitwise operators, so the OBFUSCATOR
-- ITSELF stays runnable under plain Lua 5.1 (the bit32/bitwise-operator
-- support differs across 5.1/5.2/5.3). We implement byte-xor manually.
--------------------------------------------------------------------

local function byteXor(a, b)
  local result, bit, x, y = 0, 1, a, b
  while x > 0 or y > 0 do
    local xb, yb = x % 2, y % 2
    if xb ~= yb then result = result + bit end
    x = (x - xb) / 2
    y = (y - yb) / 2
    bit = bit * 2
  end
  return result
end

local function xorEncode(str, key)
  local out = {}
  local klen = #key
  for i = 1, #str do
    out[i] = string.char(byteXor(str:byte(i), key[((i - 1) % klen) + 1]))
  end
  return table.concat(out)
end

--------------------------------------------------------------------
-- Opcode list -- MUST exactly match the opcode names compiler.lua
-- emits. Order here doesn't matter; numbers are assigned randomly.
--------------------------------------------------------------------

local OPCODES = {
  "LOADK", "LOADNIL", "LOADTRUE", "LOADFALSE", "GETVAR", "SETVAR", "DECLLOCAL",
  "NEWTABLE", "GETINDEX", "SETINDEX", "SETLIST", "DUP", "SWAP", "POP",
  "BINOP", "UNOP", "JMP", "JMPIFNOT", "JMPIFNIL", "TESTANDJMP", "TESTORJMP",
  "CLOSURE", "NEWSCOPE", "POPSCOPE", "VARARGONE", "VARARGMULTI",
  "ADJUSTMULTI", "CALL", "RETURN", "GETREG", "SETREG",
}

-- Instructions whose `a` field is a constant-pool index (everything
-- else's a/b/c fields are raw integers: jump targets, proto indices,
-- register slot numbers, argument counts, etc.)
local CONST_REF_OPS = {
  LOADK = true, GETVAR = true, SETVAR = true, DECLLOCAL = true,
  BINOP = true, UNOP = true,
}

--------------------------------------------------------------------
-- Local addConst helper mirroring compiler.lua's, so we can also fold
-- proto parameter names into the very same interned constant pool.
--------------------------------------------------------------------

local function addConst(mod, value)
  local key = type(value) .. ":" .. tostring(value)
  local existing = mod.constIndex[key]
  if existing then return existing end
  mod.consts[#mod.consts + 1] = value
  local idx = #mod.consts
  mod.constIndex[key] = idx
  return idx
end

--------------------------------------------------------------------
-- Build the obfuscated bundle from a compiled `mod`.
--------------------------------------------------------------------

local function buildBundle(mod, opts)
  opts = opts or {}
  local decoyCount = opts.decoyConstants or (6 + math.random(0, 10))

  -- 1. Fold every proto's CELL-based parameter names (reg=false) into
  --    the shared constant pool, replacing them with const indices.
  --    Register-based params (reg=true) already just carry a raw slot
  --    number and need no interning at all.
  for _, proto in ipairs(mod.protos) do
    local paramIdx = {}
    for i, pdesc in ipairs(proto.params) do
      if pdesc.reg then
        paramIdx[i] = { 0, pdesc.slot }
      else
        paramIdx[i] = { 1, addConst(mod, pdesc.name) }
      end
    end
    proto.paramIdx = paramIdx
  end

  -- 1.5. Sprinkle in decoy constants: random junk strings/numbers that
  --      no instruction ever references. They shuffle in among the
  --      real constants below, indistinguishable at rest, and inflate
  --      the pool so its size no longer correlates with how much the
  --      program actually does.
  for _ = 1, decoyCount do
    if math.random() < 0.5 then
      mod.consts[#mod.consts + 1] = randomIdent(4 + math.random(0, 12))
    else
      mod.consts[#mod.consts + 1] = math.random(-100000, 100000) + (math.random() * 0.0)
    end
  end

  -- 2. Shuffle the constant pool order and remap every reference to it
  --    (LOADK/GETVAR/SETVAR/DECLLOCAL/BINOP/UNOP `a` fields, plus the
  --    proto parameter indices we just created).
  local n = #mod.consts
  local perm = shuffledRange(n) -- perm[oldIndex] = newIndex
  local shuffledConsts = {}
  for oldIdx = 1, n do shuffledConsts[perm[oldIdx]] = mod.consts[oldIdx] end

  for _, proto in ipairs(mod.protos) do
    for _, instr in ipairs(proto.code) do
      if CONST_REF_OPS[instr.op] then
        instr.a = perm[instr.a]
      end
    end
    for _, pair in ipairs(proto.paramIdx) do
      if pair[1] == 1 then pair[2] = perm[pair[2]] end
    end
  end

  -- 3. Randomize opcode numbers for this build.
  local opNums = shuffledRange(#OPCODES)
  local OPNUM = {}
  for i, name in ipairs(OPCODES) do OPNUM[name] = opNums[i] end

  -- 4. Encrypt every constant. Each entry becomes a ciphertext string;
  --    a 1-byte tag ('N' or 'S') on the plaintext records its original
  --    Lua type so the runtime can decode both uniformly. Numbers get
  --    an extra reversible additive mask (v + A) applied BEFORE
  --    encryption -- "number-expression" style obfuscation, layered
  --    underneath the XOR cipher rather than instead of it. Deliberately
  --    additive-only (no multiply/divide): division always produces a
  --    float in Lua, which would silently turn integer constants into
  --    floats on 5.2+ hosts (invisible on 5.1, which has no int/float
  --    distinction, but needless fragility elsewhere).
  local key = randomByteKey(12 + math.random(0, 8))
  local maskA = math.random(-999999, 999999)
  local cipherConsts = {}
  for i, v in ipairs(shuffledConsts) do
    local tagged
    if type(v) == "number" then
      tagged = "N" .. tostring(v + maskA)
    else
      tagged = "S" .. v
    end
    cipherConsts[i] = xorEncode(tagged, key)
  end

  -- 5. Serialize protos as compact arrays: code[i] = {op, a, b, c}.
  local protoLits = {}
  for _, proto in ipairs(mod.protos) do
    local codeParts = {}
    for _, instr in ipairs(proto.code) do
      codeParts[#codeParts + 1] = string.format(
        "{%d,%s,%s,%s}",
        OPNUM[instr.op],
        instr.a and tostring(instr.a) or "0",
        instr.b and tostring(instr.b) or "0",
        instr.c and tostring(instr.c) or "0"
      )
    end
    local paramParts = {}
    for _, pair in ipairs(proto.paramIdx) do
      paramParts[#paramParts + 1] = string.format("{%d,%d}", pair[1], pair[2])
    end
    protoLits[#protoLits + 1] = string.format(
      "{p={%s},v=%s,c={%s}}",
      table.concat(paramParts, ","),
      proto.hasVararg and "true" or "false",
      table.concat(codeParts, ",")
    )
  end

  return {
    cipherConsts = cipherConsts,
    key = key,
    maskA = maskA,
    protoLits = protoLits,
    mainProto = mod.mainProto,
    OPNUM = OPNUM,
  }
end

--------------------------------------------------------------------
-- Runtime VM template. %PLACEHOLDER% tokens are substituted with
-- randomly generated identifiers (per build, for signature diversity)
-- and with this build's randomized opcode numbers.
--------------------------------------------------------------------

local VM_TEMPLATE = [===[
local %unpack% = table.unpack or unpack
local %byte% = string.byte
local %char% = string.char
local %concat% = table.concat

local function %bxor%(%a%, %b%)
  local %r%, %bit%, %x%, %y% = 0, 1, %a%, %b%
  while %x% > 0 or %y% > 0 do
    local %xb%, %yb% = %x% % 2, %y% % 2
    if %xb% ~= %yb% then %r% = %r% + %bit% end
    %x% = (%x% - %xb%) / 2
    %y% = (%y% - %yb%) / 2
    %bit% = %bit% * 2
  end
  return %r%
end

local function %decode%(%s%, %k%)
  local %out%, %kl% = {}, #%k%
  for %i% = 1, #%s% do
    %out%[%i%] = %char%(%bxor%(%byte%(%s%, %i%), %k%[((%i% - 1) % %kl%) + 1]))
  end
  return %concat%(%out%)
end

local function %pack%(...)
  return { n = select("#", ...), ... }
end

local function %truthy%(%v%) return %v% ~= nil and %v% ~= false end

local %BINOPS% = {
  [1] = function(%a%, %b%) return %a% + %b% end,
  [2] = function(%a%, %b%) return %a% - %b% end,
  [3] = function(%a%, %b%) return %a% * %b% end,
  [4] = function(%a%, %b%) return %a% / %b% end,
  [5] = function(%a%, %b%) return %a% % %b% end,
  [6] = function(%a%, %b%) return %a% ^ %b% end,
  [7] = function(%a%, %b%) return %a% .. %b% end,
  [8] = function(%a%, %b%) return %a% == %b% end,
  [9] = function(%a%, %b%) return %a% ~= %b% end,
  [10] = function(%a%, %b%) return %a% < %b% end,
  [11] = function(%a%, %b%) return %a% > %b% end,
  [12] = function(%a%, %b%) return %a% <= %b% end,
  [13] = function(%a%, %b%) return %a% >= %b% end,
  [14] = function(%a%, %b%) return math.floor(%a% / %b%) end,
}
local %BINOP_ID% = {
  ["+"]=1, ["-"]=2, ["*"]=3, ["/"]=4, ["%"]=5, ["^"]=6, [".."]=7,
  ["=="]=8, ["~="]=9, ["<"]=10, [">"]=11, ["<="]=12, [">="]=13, ["//"]=14,
}
local %UNOPS% = {
  [1] = function(%a%) return -%a% end,
  [2] = function(%a%) return not %a% end,
  [3] = function(%a%) return #%a% end,
}
local %UNOP_ID% = { ["-"]=1, ["not"]=2, ["#"]=3 }

local %NILV% = setmetatable({}, { __tostring = function() return "<xs-nil>" end })

local %OP_LOADK%,%OP_LOADNIL%,%OP_LOADTRUE%,%OP_LOADFALSE%,%OP_GETVAR%,%OP_SETVAR%,%OP_DECLLOCAL%,
      %OP_NEWTABLE%,%OP_GETINDEX%,%OP_SETINDEX%,%OP_SETLIST%,%OP_DUP%,%OP_SWAP%,%OP_POP%,
      %OP_BINOP%,%OP_UNOP%,%OP_JMP%,%OP_JMPIFNOT%,%OP_JMPIFNIL%,%OP_TESTANDJMP%,%OP_TESTORJMP%,
      %OP_CLOSURE%,%OP_NEWSCOPE%,%OP_POPSCOPE%,%OP_VARARGONE%,%OP_VARARGMULTI%,
      %OP_ADJUSTMULTI%,%OP_CALL%,%OP_RETURN%,%OP_GETREG%,%OP_SETREG%
  = %N_LOADK%,%N_LOADNIL%,%N_LOADTRUE%,%N_LOADFALSE%,%N_GETVAR%,%N_SETVAR%,%N_DECLLOCAL%,
    %N_NEWTABLE%,%N_GETINDEX%,%N_SETINDEX%,%N_SETLIST%,%N_DUP%,%N_SWAP%,%N_POP%,
    %N_BINOP%,%N_UNOP%,%N_JMP%,%N_JMPIFNOT%,%N_JMPIFNIL%,%N_TESTANDJMP%,%N_TESTORJMP%,
    %N_CLOSURE%,%N_NEWSCOPE%,%N_POPSCOPE%,%N_VARARGONE%,%N_VARARGMULTI%,
    %N_ADJUSTMULTI%,%N_CALL%,%N_RETURN%,%N_GETREG%,%N_SETREG%

local function %run%(%mod%, ...)
  local %consts%, %protos%, %mainIdx% = %mod%[1], %mod%[2], %mod%[3]

  local %runProto%
  %runProto% = function(%protoIdx%, %callArgs%, %parentScope%)
    local %proto% = %protos%[%protoIdx%]
    local %code% = %proto%.c

    local %scope% = { vars = {}, parent = %parentScope% }
    local %regs% = {}
    local %params% = %proto%.p
    for %pi% = 1, #%params% do
      local %pdesc% = %params%[%pi%]
      local %pv% = %callArgs%[%pi%]
      if %pdesc%[1] == 0 then
        %regs%[%pdesc%[2]] = %pv%
      else
        %scope%.vars[%consts%[%pdesc%[2]]] = (%pv% == nil) and %NILV% or %pv%
      end
    end
    local %varargs% = nil
    if %proto%.v then
      local %nva% = (%callArgs%.n or #%callArgs%) - #%params%
      if %nva% < 0 then %nva% = 0 end
      local %va% = { n = %nva% }
      for %vi% = 1, %nva% do %va%[%vi%] = %callArgs%[#%params% + %vi%] end
      %varargs% = %va%
    end

    local function %lookup%(%name%)
      local %s% = %scope%
      while %s% do
        if %s%.vars[%name%] ~= nil then return %s% end
        %s% = %s%.parent
      end
      return nil
    end

    local %stack%, %sp% = {}, 0
    local function %push%(%v%) %sp% = %sp% + 1; %stack%[%sp%] = %v% end
    local function %pop%() local %v% = %stack%[%sp%]; %stack%[%sp%] = nil; %sp% = %sp% - 1; return %v% end
    local function %peek%() return %stack%[%sp%] end

    local function %mkClosure%(%pIdx%)
      local %capturedScope% = %scope%
      return function(...)
        return %runProto%(%pIdx%, %pack%(...), %capturedScope%)
      end
    end

    local %ip% = 1
    local %probe% = 0
    while true do
      local %instr% = %code%[%ip%]
      if not %instr% then return end
      local %op% = %instr%[1]
      %probe% = %probe% + 1

      if %op% == %OP_LOADK% and %OPQ_LOADK% then
        %push%(%consts%[%instr%[2]]); %ip% = %ip% + 1
      elseif %op% == %OP_LOADNIL% and %OPQ_LOADNIL% then
        %push%(nil); %ip% = %ip% + 1
      elseif %op% == %OP_LOADTRUE% and %OPQ_LOADTRUE% then
        %push%(true); %ip% = %ip% + 1
      elseif %op% == %OP_LOADFALSE% and %OPQ_LOADFALSE% then
        %push%(false); %ip% = %ip% + 1
      elseif %op% == %OP_GETVAR% and %OPQ_GETVAR% then
        local %nm% = %consts%[%instr%[2]]
        local %sc% = %lookup%(%nm%)
        if %sc% then
          local %v% = %sc%.vars[%nm%]
          if %v% == %NILV% then %push%(nil) else %push%(%v%) end
        else
          %push%(_G[%nm%])
        end
        %ip% = %ip% + 1
      elseif %op% == %OP_SETVAR% and %OPQ_SETVAR% then
        local %nm% = %consts%[%instr%[2]]
        local %v% = %pop%()
        local %sc% = %lookup%(%nm%)
        if %sc% then
          %sc%.vars[%nm%] = (%v% == nil) and %NILV% or %v%
        else
          _G[%nm%] = %v%
        end
        %ip% = %ip% + 1
      elseif %op% == %OP_DECLLOCAL% and %OPQ_DECLLOCAL% then
        local %nm% = %consts%[%instr%[2]]
        local %v% = %pop%()
        %scope%.vars[%nm%] = (%v% == nil) and %NILV% or %v%
        %ip% = %ip% + 1
      elseif %op% == %OP_GETREG% and %OPQ_GETREG% then
        %push%(%regs%[%instr%[2]]); %ip% = %ip% + 1
      elseif %op% == %OP_SETREG% and %OPQ_SETREG% then
        %regs%[%instr%[2]] = %pop%(); %ip% = %ip% + 1
      elseif %op% == %OP_NEWTABLE% and %OPQ_NEWTABLE% then
        %push%({}); %ip% = %ip% + 1
      elseif %op% == %OP_GETINDEX% and %OPQ_GETINDEX% then
        local %key% = %pop%(); local %obj% = %pop%()
        %push%(%obj%[%key%]); %ip% = %ip% + 1
      elseif %op% == %OP_SETINDEX% and %OPQ_SETINDEX% then
        local %val% = %pop%(); local %key% = %pop%(); local %obj% = %pop%()
        %obj%[%key%] = %val%; %ip% = %ip% + 1
      elseif %op% == %OP_SETLIST% and %OPQ_SETLIST% then
        local %base% = %instr%[2]
        local %cnt% = %pop%()
        local %arr% = {}
        for %ii% = %cnt%, 1, -1 do %arr%[%ii%] = %pop%() end
        local %tbl% = %pop%()
        for %ii% = 1, %cnt% do %tbl%[%base% + %ii%] = %arr%[%ii%] end
        %ip% = %ip% + 1
      elseif %op% == %OP_DUP% and %OPQ_DUP% then
        %push%(%peek%()); %ip% = %ip% + 1
      elseif %op% == %OP_SWAP% and %OPQ_SWAP% then
        local %b2% = %pop%(); local %a2% = %pop%(); %push%(%b2%); %push%(%a2%); %ip% = %ip% + 1
      elseif %op% == %OP_POP% and %OPQ_POP% then
        for %ii% = 1, %instr%[2] do %pop%() end
        %ip% = %ip% + 1
      elseif %op% == %OP_BINOP% and %OPQ_BINOP% then
        local %bid% = %BINOP_ID%[%consts%[%instr%[2]]]
        local %b3% = %pop%(); local %a3% = %pop%()
        %push%(%BINOPS%[%bid%](%a3%, %b3%))
        %ip% = %ip% + 1
      elseif %op% == %OP_UNOP% and %OPQ_UNOP% then
        local %uid% = %UNOP_ID%[%consts%[%instr%[2]]]
        local %a4% = %pop%()
        %push%(%UNOPS%[%uid%](%a4%))
        %ip% = %ip% + 1
      elseif %op% == %OP_JMP% and %OPQ_JMP% then
        %ip% = %instr%[2]
      elseif %op% == %OP_JMPIFNOT% and %OPQ_JMPIFNOT% then
        local %v2% = %pop%()
        if %truthy%(%v2%) then %ip% = %ip% + 1 else %ip% = %instr%[2] end
      elseif %op% == %OP_JMPIFNIL% and %OPQ_JMPIFNIL% then
        local %v3% = %pop%()
        if %v3% == nil then %ip% = %instr%[2] else %ip% = %ip% + 1 end
      elseif %op% == %OP_TESTANDJMP% and %OPQ_TESTANDJMP% then
        local %v4% = %peek%()
        if %truthy%(%v4%) then %ip% = %ip% + 1 else %ip% = %instr%[2] end
      elseif %op% == %OP_TESTORJMP% and %OPQ_TESTORJMP% then
        local %v5% = %peek%()
        if %truthy%(%v5%) then %ip% = %instr%[2] else %ip% = %ip% + 1 end
      elseif %op% == %OP_CLOSURE% and %OPQ_CLOSURE% then
        %push%(%mkClosure%(%instr%[2])); %ip% = %ip% + 1
      elseif %op% == %OP_NEWSCOPE% and %OPQ_NEWSCOPE% then
        %scope% = { vars = {}, parent = %scope% }; %ip% = %ip% + 1
      elseif %op% == %OP_POPSCOPE% and %OPQ_POPSCOPE% then
        %scope% = %scope%.parent; %ip% = %ip% + 1
      elseif %op% == %OP_VARARGONE% and %OPQ_VARARGONE% then
        if %varargs% then %push%(%varargs%[1]) else %push%(nil) end
        %ip% = %ip% + 1
      elseif %op% == %OP_VARARGMULTI% and %OPQ_VARARGMULTI% then
        local %nv% = %varargs% and %varargs%.n or 0
        for %vj% = 1, %nv% do %push%(%varargs%[%vj%]) end
        %push%(%nv%)
        %ip% = %ip% + 1
      elseif %op% == %OP_ADJUSTMULTI% and %OPQ_ADJUSTMULTI% then
        local %wn% = %instr%[2]
        local %cnt2% = %pop%()
        local %arr2% = {}
        for %ii2% = %cnt2%, 1, -1 do %arr2%[%ii2%] = %pop%() end
        for %ii2% = 1, %wn% do
          if %ii2% <= %cnt2% then %push%(%arr2%[%ii2%]) else %push%(nil) end
        end
        %ip% = %ip% + 1
      elseif %op% == %OP_CALL% and %OPQ_CALL% then
        local %nstatic%, %argKind%, %resMulti% = %instr%[2], %instr%[3], %instr%[4]
        local %cargs%, %ntotal% = {}, 0
        if %argKind% == 1 then
          local %cnt3% = %pop%()
          local %trail% = {}
          for %ii3% = %cnt3%, 1, -1 do %trail%[%ii3%] = %pop%() end
          local %fix% = {}
          for %ii3% = %nstatic%, 1, -1 do %fix%[%ii3%] = %pop%() end
          for %ii3% = 1, %nstatic% do %cargs%[%ii3%] = %fix%[%ii3%] end
          for %ii3% = 1, %cnt3% do %cargs%[%nstatic% + %ii3%] = %trail%[%ii3%] end
          %ntotal% = %nstatic% + %cnt3%
        else
          local %fix2% = {}
          for %ii3% = %nstatic%, 1, -1 do %fix2%[%ii3%] = %pop%() end
          %cargs% = %fix2%
          %ntotal% = %nstatic%
        end
        local %fn% = %pop%()
        local %results% = %pack%(%fn%(%unpack%(%cargs%, 1, %ntotal%)))
        if %resMulti% == 1 then
          for %ri% = 1, %results%.n do %push%(%results%[%ri%]) end
          %push%(%results%.n)
        else
          %push%(%results%[1])
        end
        %ip% = %ip% + 1
      elseif %op% == %OP_RETURN% and %OPQ_RETURN% then
        local %nstatic2%, %argKind2% = %instr%[2], %instr%[3]
        if %argKind2% == 1 then
          local %cnt4% = %pop%()
          local %trail2% = {}
          for %ii4% = %cnt4%, 1, -1 do %trail2%[%ii4%] = %pop%() end
          local %fix3% = {}
          for %ii4% = %nstatic2%, 1, -1 do %fix3%[%ii4%] = %pop%() end
          local %all% = {}
          for %ii4% = 1, %nstatic2% do %all%[%ii4%] = %fix3%[%ii4%] end
          for %ii4% = 1, %cnt4% do %all%[%nstatic2% + %ii4%] = %trail2%[%ii4%] end
          return %unpack%(%all%, 1, %nstatic2% + %cnt4%)
        else
          local %vals% = {}
          for %ii4% = %nstatic2%, 1, -1 do %vals%[%ii4%] = %pop%() end
          return %unpack%(%vals%, 1, %nstatic2%)
        end
      else
        error("bad opcode")
      end
    end
  end

  return %runProto%(%mainIdx%, %pack%(...), nil)
end

return %run%]===]

--------------------------------------------------------------------
-- Substitute %name% placeholders. Placeholders starting with "N_" get
-- this build's randomized opcode NUMBER; everything else gets a fresh
-- random identifier (the same placeholder always maps to the same
-- generated name within one build).
--------------------------------------------------------------------

-- Generic %name% substitution. `resolve(tok)` returns the replacement
-- string for a placeholder token, or nil to leave it as an error.
local function substitute(template, resolve)
  return (template:gsub("%%([%a_][%w_]*)%%", function(tok)
    local v = resolve(tok)
    assert(v ~= nil, "unresolved template placeholder %" .. tok .. "%")
    return v
  end))
end

-- Renders the VM engine template: any %N_OPNAME% becomes this build's
-- randomized opcode number; every other %ident% becomes a fresh random
-- identifier (memoized so the same placeholder always maps to the same
-- generated name within this one render).
--------------------------------------------------------------------
-- Nested opaque predicates: boolean expressions built from small
-- number-theoretic identities that are true for EVERY integer V (not
-- probabilistically true -- provably true for all V), so ANDing one
-- into a dispatch check never changes behavior. Genuinely nested
-- (each predicate is threaded inside the next via `and`, not just a
-- flat AND-list), and a fresh combination is picked per opcode per
-- build, so the exact expression differs both across opcodes within
-- one build and across builds of the same script.
--------------------------------------------------------------------

local OPAQUE_IDENTITIES = {
  "((V*V-V)%2==0)",                          -- v^2 - v is always even
  "(((V+1)*(V+1)-V*V-2*V-1)==0)",             -- (v+1)^2 - v^2 - 2v - 1 == 0
  "((V%2)*(V%2)==(V%2))",                     -- v mod 2 is idempotent under squaring
  "(((V*V)%4)~=2)",                           -- v^2 mod 4 is never 2
  "(((V-V)*(V+7))==0)",                       -- v - v is always 0
  "((V*3-V*2-V)==0)",                         -- 3v - 2v - v == 0
  "(((V*V+V)%2)==0)",                         -- v^2 + v is always even
}

local function genOpaquePredicate(probeName, depth)
  local pool = {}
  for i, v in ipairs(OPAQUE_IDENTITIES) do pool[i] = v end
  local chosen = {}
  for _ = 1, depth do
    local idx = math.random(1, #pool)
    chosen[#chosen + 1] = (pool[idx]:gsub("V", probeName))
    table.remove(pool, idx)
  end
  local expr = chosen[#chosen]
  for i = #chosen - 1, 1, -1 do
    expr = "(" .. chosen[i] .. " and " .. expr .. ")"
  end
  return expr
end

local function renderTemplate(template, OPNUM)
  local nameCache = {}
  local function ensureName(tok)
    if not nameCache[tok] then nameCache[tok] = randomIdent() end
    return nameCache[tok]
  end
  return substitute(template, function(tok)
    if tok:sub(1, 2) == "N_" then
      local opname = tok:sub(3)
      assert(OPNUM[opname], "unknown opcode placeholder " .. tok)
      return tostring(OPNUM[opname])
    end
    if tok:sub(1, 4) == "OPQ_" then
      -- A fresh nested opaque predicate per opcode, referencing the
      -- shared per-call `probe` counter (always some changing integer
      -- at the point it's checked -- the identities hold for any V).
      local probe = ensureName("probe")
      return genOpaquePredicate(probe, 2 + math.random(0, 1))
    end
    return ensureName(tok)
  end)
end

--------------------------------------------------------------------
-- Header template: XOR/decode helpers + the decrypted constant pool
-- + the literal proto table, all with randomized local names.
--------------------------------------------------------------------

local HEADER_TEMPLATE = [===[
--[[
  Protected by XenonSec :: VM-based Lua obfuscator (5.1 target)
--]]
local %byte% = string.byte
local %char% = string.char
local %concat% = table.concat
local function %bxor%(%a%, %b%)
  local %r%, %bit%, %x%, %y% = 0, 1, %a%, %b%
  while %x% > 0 or %y% > 0 do
    local %xb%, %yb% = %x% % 2, %y% % 2
    if %xb% ~= %yb% then %r% = %r% + %bit% end
    %x% = (%x% - %xb%) / 2
    %y% = (%y% - %yb%) / 2
    %bit% = %bit% * 2
  end
  return %r%
end
local %key% = __XS_KEY__
local %maskA% = __XS_MASKA__
local function %decode%(%s%)
  local %out%, %kl% = {}, #%key%
  for %i% = 1, #%s% do
    %out%[%i%] = %char%(%bxor%(%byte%(%s%, %i%), %key%[((%i% - 1) % %kl%) + 1]))
  end
  return %concat%(%out%)
end
local %raw% = { __XS_CIPHERS__ }
local %consts% = {}
for %i2% = 1, #%raw% do
  local %dv% = %decode%(%raw%[%i2%])
  local %tg% = %dv%:sub(1, 1)
  if %tg% == "N" then %consts%[%i2%] = tonumber(%dv%:sub(2)) - %maskA% else %consts%[%i2%] = %dv%:sub(2) end
end
local %protos% = { __XS_PROTOS__ }]===]

local FOOTER_TEMPLATE = [===[
return (%engine%)({ %consts%, %protos%, __XS_MAIN__ }, ...)]===]

--------------------------------------------------------------------
-- Minification: strips comments/leading-trailing whitespace and blank
-- lines from our OWN template skeletons, before any generated payload
-- (ciphertext / proto literals) is spliced in. Safe specifically
-- because at this point the template text contains no multi-line
-- string payloads yet -- only hand-written template source we control.
--------------------------------------------------------------------

local function minifyTemplateText(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and not (trimmed:sub(1, 2) == "--" and trimmed:sub(1, 4) ~= "--[[" and trimmed:sub(1, 4) ~= "--]]") then
      trimmed = trimmed:gsub("%s+", " ")
      lines[#lines + 1] = trimmed
    end
  end
  -- Heavy mode: join every statement with a single space instead of a
  -- newline, collapsing the whole template to one dense line. A plain
  -- space is always a safe token separator in Lua regardless of what
  -- the two adjacent tokens are, so this can never glue two tokens
  -- together incorrectly -- it just removes every newline/indent byte
  -- that isn't doing any syntactic work.
  return table.concat(lines, " ")
end

--------------------------------------------------------------------
-- Public entry point
--------------------------------------------------------------------

local DEFAULTS = {
  minify = true,
  junkRate = 0.12,
  decoyConstants = nil, -- nil => randomized count, see buildBundle
  localizeGlobals = true,
  fold = true,
  ssa = true,
  luau = false,
}

local function obfuscate(source, chunkname, opts)
  opts = opts or {}
  for k, v in pairs(DEFAULTS) do
    if opts[k] == nil then opts[k] = v end
  end

  local ast = Parser.parse(source, chunkname or "input", opts.luau)
  -- Computed on the pristine AST (capture analysis only cares about
  -- lexical structure, which Fold/SSA never change) so SSA can safely
  -- know which names are reachable-via-closure and must never be
  -- treated as safe-to-cache across a function call.
  local earlyCaptured = Capture.analyze(ast)
  if opts.fold then Fold.apply(ast) end
  if opts.ssa then
    SSA.apply(ast, earlyCaptured)
    if opts.fold then Fold.apply(ast) end -- a second fold pass catches arithmetic SSA just exposed
  end
  if opts.localizeGlobals then Localize.apply(ast) end
  Renamer.resolve(ast)
  local captured = Capture.analyze(ast)
  local mod = Compiler.compile(ast, captured)
  if opts.junkRate and opts.junkRate > 0 then Junk.inject(mod, opts.junkRate) end
  local bundle = buildBundle(mod, opts)

  local vmSrc = opts.minify and minifyTemplateText(VM_TEMPLATE) or VM_TEMPLATE
  local engineSrc = renderTemplate(vmSrc, bundle.OPNUM)

  local keyLit = "{" .. table.concat(bundle.key, ",") .. "}"
  local cipherLits = {}
  for i, c in ipairs(bundle.cipherConsts) do
    cipherLits[i] = string.format("%q", c)
  end
  local ciphersLit = table.concat(cipherLits, ",")
  local protosLit = table.concat(bundle.protoLits, ",")

  -- Shared names between header and footer (consts/protos locals) must
  -- match, so render both from one nameCache.
  local nameCache = {}
  local function resolveShared(tok)
    if tok == "engine" then return nil end -- filled per-template below
    if not nameCache[tok] then nameCache[tok] = randomIdent() end
    return nameCache[tok]
  end

  local headerTpl = opts.minify and minifyTemplateText(HEADER_TEMPLATE) or HEADER_TEMPLATE
  local footerTpl = opts.minify and minifyTemplateText(FOOTER_TEMPLATE) or FOOTER_TEMPLATE

  local header = substitute(headerTpl, resolveShared)
  header = header:gsub("__XS_KEY__", keyLit)
  header = header:gsub("__XS_MASKA__", tostring(bundle.maskA))
  header = header:gsub("__XS_CIPHERS__", (ciphersLit:gsub("%%", "%%%%")))
  header = header:gsub("__XS_PROTOS__", (protosLit:gsub("%%", "%%%%")))

  local footer = substitute(footerTpl, function(tok)
    if tok == "engine" then return "(function()\n" .. engineSrc .. "\nend)()" end
    return resolveShared(tok)
  end)
  footer = footer:gsub("__XS_MAIN__", tostring(bundle.mainProto))

  -- Wrap the ENTIRE output (header locals: key/decode/consts/protos,
  -- plus the engine call) inside one outer closure, so the finished
  -- file is a single `return (function(...) ... end)(...)` expression
  -- -- nothing (opcode numbers, decode key, helper names, consts,
  -- protos) sits at the chunk's top level at all.
  local combined = header .. "\n" .. footer
  return "return (function(...)\n" .. combined .. "\nend)(...)\n"
end

return { obfuscate = obfuscate }
