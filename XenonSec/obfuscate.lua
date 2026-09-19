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
for _ = 1, 8 do math.random() end

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

local function rc4Ksa(key)
  local S = {}
  for i = 0, 255 do S[i] = i end
  local j = 0
  local keylen = #key
  for i = 0, 255 do
    j = (j + S[i] + key[(i % keylen) + 1]) % 256
    S[i], S[j] = S[j], S[i]
  end
  return S
end

local function rc4Crypt(data, key)
  local S = rc4Ksa(key)
  local i, j = 0, 0
  local out = {}
  for n = 1, #data do
    i = (i + 1) % 256
    j = (j + S[i]) % 256
    S[i], S[j] = S[j], S[i]
    local K = S[(S[i] + S[j]) % 256]
    out[n] = string.char(byteXor(data:byte(n), K))
  end
  return table.concat(out)
end

local SEED_MOD, LCG_MULT, LCG_ADD = 16777216, 2654435, 12345

local function deriveSeed(key)
  local seed = 2166136261 % SEED_MOD
  for i = 1, #key do
    seed = byteXor(seed, key[i])
    seed = (seed * LCG_MULT + LCG_ADD) % SEED_MOD
  end
  return seed
end

local function lcgNext(seed)
  seed = (seed * LCG_MULT + LCG_ADD) % SEED_MOD
  return seed, math.floor(seed / 65536) % 256
end

local function rotl8(b, n)
  n = n % 8
  if n == 0 then return b end
  return ((b * (2 ^ n)) % 256) + math.floor(b / (2 ^ (8 - n)))
end
local function rotr8(b, n) return rotl8(b, 8 - (n % 8)) end

local function diffuseEncrypt(data, key)
  local seed = deriveSeed(key)
  local out = {}
  for i = 1, #data do
    local kbyte
    seed, kbyte = lcgNext(seed)
    local b = byteXor(data:byte(i), kbyte)
    out[i] = string.char(rotl8(b, (i % 5) + 1))
  end
  return table.concat(out)
end

local function diffuseDecrypt(data, key)
  local seed = deriveSeed(key)
  local out = {}
  for i = 1, #data do
    local kbyte
    seed, kbyte = lcgNext(seed)
    local b = rotr8(data:byte(i), (i % 5) + 1)
    out[i] = string.char(byteXor(b, kbyte))
  end
  return table.concat(out)
end

local function deriveIV(key)
  local iv = 0
  for i = 1, #key do iv = byteXor(iv, key[i]) end
  return iv
end

local function cfbChain(data, iv)
  local out, prev = {}, iv
  for i = 1, #data do
    local c = byteXor(data:byte(i), prev)
    out[i] = string.char(c)
    prev = c
  end
  return table.concat(out)
end

local function cfbUnchain(data, iv)
  local out, prev = {}, iv
  for i = 1, #data do
    local c = data:byte(i)
    out[i] = string.char(byteXor(c, prev))
    prev = c
  end
  return table.concat(out)
end

local function cipherEncrypt(plaintext, key)
  local a = rc4Crypt(plaintext, key)
  local b = diffuseEncrypt(a, key)
  local c = cfbChain(b, deriveIV(key))
  return c
end

local function cipherDecrypt(ciphertext, key)
  local b = cfbUnchain(ciphertext, deriveIV(key))
  local a = diffuseDecrypt(b, key)
  local plaintext = rc4Crypt(a, key)
  return plaintext
end

local OPCODES = {
  "LOADK", "LOADNIL", "LOADTRUE", "LOADFALSE", "GETVAR", "SETVAR", "DECLLOCAL",
  "NEWTABLE", "GETINDEX", "SETINDEX", "SETLIST", "DUP", "SWAP", "POP",
  "BINOP", "UNOP", "JMP", "JMPIFNOT", "JMPIFNIL", "TESTANDJMP", "TESTORJMP",
  "CLOSURE", "NEWSCOPE", "POPSCOPE", "VARARGONE", "VARARGMULTI",
  "ADJUSTMULTI", "CALL", "RETURN", "GETREG", "SETREG", "CPLX",
}

local CONST_REF_OPS = {
  LOADK = true, GETVAR = true, SETVAR = true, DECLLOCAL = true,
}

local BINOP_SYMBOLS = { "+", "-", "*", "/", "%", "^", "..", "==", "~=", "<", ">", "<=", ">=", "//" }
local UNOP_SYMBOLS = { "-", "not", "#" }

local function addConst(mod, value)
  local key = type(value) .. ":" .. tostring(value)
  local existing = mod.constIndex[key]
  if existing then return existing end
  mod.consts[#mod.consts + 1] = value
  local idx = #mod.consts
  mod.constIndex[key] = idx
  return idx
end

local ENV_CHECK_NAMES = {
  "print", "pairs", "ipairs", "type", "tostring", "tonumber", "pcall",
  "xpcall", "error", "setmetatable", "rawget", "rawset", "rawequal",
  "select", "next",
}

local function buildBundle(mod, opts)
  opts = opts or {}
  local decoyCount = opts.decoyConstants or (6 + math.random(0, 10))

  for _, proto in ipairs(mod.protos) do
    local paramIdx = {}
    for i, pdesc in ipairs(proto.params) do
      if pdesc.reg then
        paramIdx[i] = { 0, pdesc.slot }
      else
        -- compiler.lua already pooled (and mangled) the captured-param name
        -- and recorded its index as pdesc.ci; reusing it avoids re-mangling.
        paramIdx[i] = { 1, pdesc.ci or addConst(mod, pdesc.name) }
      end
    end
    proto.paramIdx = paramIdx
  end

  local envCheckIdx = {}
  if opts.antiDebug then
    for i, name in ipairs(ENV_CHECK_NAMES) do
      envCheckIdx[i] = addConst(mod, name)
    end
  end

  local watermarkIdx = addConst(mod, "Protected by XenonSec")

  for _ = 1, decoyCount do
    if math.random() < 0.5 then
      mod.consts[#mod.consts + 1] = randomIdent(4 + math.random(0, 12))
    else
      mod.consts[#mod.consts + 1] = math.random(-100000, 100000) + (math.random() * 0.0)
    end
  end

  local n = #mod.consts
  local perm = shuffledRange(n)
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

  for i, oldIdx in ipairs(envCheckIdx) do envCheckIdx[i] = perm[oldIdx] end
  watermarkIdx = perm[watermarkIdx]

  local opNums = shuffledRange(#OPCODES)
  local OPNUM = {}
  for i, name in ipairs(OPCODES) do OPNUM[name] = opNums[i] end

  local binNums = shuffledRange(#BINOP_SYMBOLS)
  local BINNUM = {}
  for i, sym in ipairs(BINOP_SYMBOLS) do BINNUM[sym] = binNums[i] end

  local unNums = shuffledRange(#UNOP_SYMBOLS)
  local UNNUM = {}
  for i, sym in ipairs(UNOP_SYMBOLS) do UNNUM[sym] = unNums[i] end

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
    cipherConsts[i] = cipherEncrypt(tagged, key)
  end

  local function mixChecksum(h, n) return (h * 31 + (n or 0)) % 2147483647 end
  local checksum = 5381
  for _, c in ipairs(cipherConsts) do
    for i = 1, #c do checksum = mixChecksum(checksum, c:byte(i)) end
  end

  local protoLits = {}
  for _, proto in ipairs(mod.protos) do
    checksum = mixChecksum(checksum, proto.hasVararg and 1 or 0)
    local codeParts = {}
    for _, instr in ipairs(proto.code) do
      local opn = OPNUM[instr.op]
      local a
      if instr.op == "BINOP" then
        a = BINNUM[instr.a]
      elseif instr.op == "UNOP" then
        a = UNNUM[instr.a]
      else
        a = instr.a or 0
      end
      local b = instr.b or 0
      local c = instr.c or 0
      checksum = mixChecksum(checksum, opn)
      checksum = mixChecksum(checksum, a)
      checksum = mixChecksum(checksum, b)
      checksum = mixChecksum(checksum, c)
      codeParts[#codeParts + 1] = string.format("{%d,%s,%s,%s}", opn, tostring(a), tostring(b), tostring(c))
    end
    local paramParts = {}
    for _, pair in ipairs(proto.paramIdx) do
      checksum = mixChecksum(checksum, pair[1])
      checksum = mixChecksum(checksum, pair[2])
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
    BINNUM = BINNUM,
    UNNUM = UNNUM,
    checksum = checksum,
    envCheckIdx = envCheckIdx,
    watermarkIdx = watermarkIdx,
  }
end

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
  [%BN_PLUS%] = function(%a%, %b%) return %a% + %b% end,
  [%BN_MINUS%] = function(%a%, %b%) return %a% - %b% end,
  [%BN_MUL%] = function(%a%, %b%) return %a% * %b% end,
  [%BN_DIV%] = function(%a%, %b%) return %a% / %b% end,
  [%BN_MOD%] = function(%a%, %b%) return %a% % %b% end,
  [%BN_POW%] = function(%a%, %b%) return %a% ^ %b% end,
  [%BN_CONCAT%] = function(%a%, %b%) return %a% .. %b% end,
  [%BN_EQ%] = function(%a%, %b%) return %a% == %b% end,
  [%BN_NE%] = function(%a%, %b%) return %a% ~= %b% end,
  [%BN_LT%] = function(%a%, %b%) return %a% < %b% end,
  [%BN_GT%] = function(%a%, %b%) return %a% > %b% end,
  [%BN_LE%] = function(%a%, %b%) return %a% <= %b% end,
  [%BN_GE%] = function(%a%, %b%) return %a% >= %b% end,
  [%BN_IDIV%] = function(%a%, %b%) return math.floor(%a% / %b%) end,
}
local %UNOPS% = {
  [%UN_UNM%] = function(%a%) return -%a% end,
  [%UN_NOT%] = function(%a%) return not %a% end,
  [%UN_LEN%] = function(%a%) return #%a% end,
}

local %NILV% = setmetatable({}, { __tostring = function() return "<xs-nil>" end })

local %OP_LOADK%,%OP_LOADNIL%,%OP_LOADTRUE%,%OP_LOADFALSE%,%OP_GETVAR%,%OP_SETVAR%,%OP_DECLLOCAL%,
      %OP_NEWTABLE%,%OP_GETINDEX%,%OP_SETINDEX%,%OP_SETLIST%,%OP_DUP%,%OP_SWAP%,%OP_POP%,
      %OP_BINOP%,%OP_UNOP%,%OP_JMP%,%OP_JMPIFNOT%,%OP_JMPIFNIL%,%OP_TESTANDJMP%,%OP_TESTORJMP%,
      %OP_CLOSURE%,%OP_NEWSCOPE%,%OP_POPSCOPE%,%OP_VARARGONE%,%OP_VARARGMULTI%,
      %OP_ADJUSTMULTI%,%OP_CALL%,%OP_RETURN%,%OP_GETREG%,%OP_SETREG%,%OP_CPLX%
  = %N_LOADK%,%N_LOADNIL%,%N_LOADTRUE%,%N_LOADFALSE%,%N_GETVAR%,%N_SETVAR%,%N_DECLLOCAL%,
    %N_NEWTABLE%,%N_GETINDEX%,%N_SETINDEX%,%N_SETLIST%,%N_DUP%,%N_SWAP%,%N_POP%,
    %N_BINOP%,%N_UNOP%,%N_JMP%,%N_JMPIFNOT%,%N_JMPIFNIL%,%N_TESTANDJMP%,%N_TESTORJMP%,
    %N_CLOSURE%,%N_NEWSCOPE%,%N_POPSCOPE%,%N_VARARGONE%,%N_VARARGMULTI%,
    %N_ADJUSTMULTI%,%N_CALL%,%N_RETURN%,%N_GETREG%,%N_SETREG%,%N_CPLX%

local function %run%(%mod%, ...)
  local %consts%, %protos%, %mainIdx% = %mod%[1], %mod%[2], %mod%[3]

  local %runProto%
  %runProto% = function(%protoIdx%, %callArgs%, %parentScope%)
    local %proto% = %protos%[%protoIdx%]
    local %code% = %proto%.c

    local %scope% = { %varsField% = {}, %parentField% = %parentScope% }
    local %regs% = {}
    local %params% = %proto%.p
    for %pi% = 1, #%params% do
      local %pdesc% = %params%[%pi%]
      local %pv% = %callArgs%[%pi%]
      if %pdesc%[1] == 0 then
        %regs%[%pdesc%[2]] = %pv%
      else
        %scope%.%varsField%[%consts%[%pdesc%[2]]] = (%pv% == nil) and %NILV% or %pv%
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
        if %s%.%varsField%[%name%] ~= nil then return %s% end
        %s% = %s%.%parentField%
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
          local %v% = %sc%.%varsField%[%nm%]
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
          %sc%.%varsField%[%nm%] = (%v% == nil) and %NILV% or %v%
        else
          _G[%nm%] = %v%
        end
        %ip% = %ip% + 1
      elseif %op% == %OP_DECLLOCAL% and %OPQ_DECLLOCAL% then
        local %nm% = %consts%[%instr%[2]]
        local %v% = %pop%()
        %scope%.%varsField%[%nm%] = (%v% == nil) and %NILV% or %v%
        %ip% = %ip% + 1
      elseif %op% == %OP_GETREG% and %OPQ_GETREG% then
        %push%(%regs%[%instr%[2]]); %ip% = %ip% + 1
      elseif %op% == %OP_SETREG% and %OPQ_SETREG% then
        %regs%[%instr%[2]] = %pop%(); %ip% = %ip% + 1
      elseif %op% == %OP_CPLX% and %OPQ_CPLX% then
        local %cxN% = (%instr%[2] or 3) % 7
        local %cxAcc% = 0
        for %cxI% = 1, %cxN% do
          %cxAcc% = %cxAcc% + (%cxI% * %cxI%)
          if (%cxAcc% % 2) == 0 then %cxAcc% = %cxAcc% - %cxI% else %cxAcc% = %cxAcc% + 0 end
        end
        local %cxTbl% = { %cxAcc%, %instr%[3] or 0 }
        %push%(%cxTbl%[1] + %cxTbl%[2])
        %pop%()
        %ip% = %ip% + 1
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
        local %b3% = %pop%(); local %a3% = %pop%()
        %push%(%BINOPS%[%instr%[2]](%a3%, %b3%))
        %ip% = %ip% + 1
      elseif %op% == %OP_UNOP% and %OPQ_UNOP% then
        local %a4% = %pop%()
        %push%(%UNOPS%[%instr%[2]](%a4%))
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
        %scope% = { %varsField% = {}, %parentField% = %scope% }; %ip% = %ip% + 1
      elseif %op% == %OP_POPSCOPE% and %OPQ_POPSCOPE% then
        %scope% = %scope%.%parentField%; %ip% = %ip% + 1
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
      %DECOY_BRANCHES%
      else
        error()
      end
    end
  end

  return %runProto%(%mainIdx%, %pack%(...), nil)
end

return %run%]===]

local function substitute(template, resolve)
  return (template:gsub("%%([%a_][%w_]*)%%", function(tok)
    local v = resolve(tok)
    assert(v ~= nil, "unresolved template placeholder %" .. tok .. "%")
    return v
  end))
end

local OPAQUE_IDENTITIES = {
  "((V*V-V)%2==0)",
  "(((V+1)*(V+1)-V*V-2*V-1)==0)",
  "((V%2)*(V%2)==(V%2))",
  "(((V*V)%4)~=2)",
  "(((V-V)*(V+7))==0)",
  "((V*3-V*2-V)==0)",
  "(((V*V+V)%2)==0)",
  "(((V*(V+1)*(V+2))%6)==0)",
  "((((V*V*V)-V)%6)==0)",
  "(((V+V)%2)==0)",
  "((V*V)>=0)",
  "((V==V))",
  "(not (V~=V))",
  "(((V*5-V*4-V))==0)",
  "(((V*V-V*V))==0)",
}

local FALSE_IDENTITIES = {
  "((V*V-V)%2==1)",
  "(((V+1)*(V+1)-V*V-2*V-1)~=0)",
  "(((V*V)%4)==2)",
  "(((V-V)*(V+7))~=0)",
  "((V*3-V*2-V)~=0)",
  "(((V*V+V)%2)==1)",
  "(((V*(V+1)*(V+2))%6)==1)",
  "((V*V)<0)",
  "((V~=V))",
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

local function genAlwaysFalsePredicate(probeName)
  local falseIdx = math.random(1, #FALSE_IDENTITIES)
  local trueIdx = math.random(1, #OPAQUE_IDENTITIES)
  local f = (FALSE_IDENTITIES[falseIdx]:gsub("V", probeName))
  local t = (OPAQUE_IDENTITIES[trueIdx]:gsub("V", probeName))
  return "(" .. f .. " and " .. t .. ")"
end

local BINOP_TOKEN_NAMES = {
  ["+"] = "PLUS", ["-"] = "MINUS", ["*"] = "MUL", ["/"] = "DIV",
  ["%"] = "MOD", ["^"] = "POW", [".."] = "CONCAT",
  ["=="] = "EQ", ["~="] = "NE", ["<"] = "LT", [">"] = "GT",
  ["<="] = "LE", [">="] = "GE", ["//"] = "IDIV",
}
local UNOP_TOKEN_NAMES = { ["-"] = "UNM", ["not"] = "NOT", ["#"] = "LEN" }

local function genDecoyBranches(ensureName, count)
  local push, pop, peek = ensureName("push"), ensureName("pop"), ensureName("peek")
  local stack, sp, ip = ensureName("stack"), ensureName("sp"), ensureName("ip")
  local consts, instr = ensureName("consts"), ensureName("instr")
  local probe = ensureName("probe")

  local flavors = {
    function()
      return string.format(
        "%s(%s(%s[1] or 0, 1)); %s = %s + 1",
        push, "(function(a,b) return a+b end)", consts, ip, ip)
    end,
    function()
      return string.format(
        "local %s = %s(); if %s then %s(%s) end; %s = %s + 1",
        ensureName("dv" .. tostring(math.random(1, 99999))), pop, peek, push, peek, ip, ip)
    end,
    function()
      return string.format(
        "%s(#%s + %s[2]); %s = %s + 1",
        push, stack, instr, ip, ip)
    end,
    function()
      return string.format(
        "local %s = %s[%s] or 0; %s(%s * 2); %s = %s + 1",
        ensureName("tmpr" .. tostring(math.random(1, 99999))), stack, sp, push, sp, ip, ip)
    end,
  }

  local branches = {}
  for i = 1, count do
    local decoyNum = math.random(-9999, 9999)
    local cond = genAlwaysFalsePredicate(probe)
    local body = flavors[math.random(1, #flavors)]()
    branches[#branches + 1] = string.format(
      "elseif %s == %d and %s then %s",
      ensureName("op"), decoyNum, cond, body
    )
  end
  return table.concat(branches, "\n      ")
end

local function renderTemplate(template, OPNUM, BINNUM, UNNUM)
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
      local probe = ensureName("probe")
      return genOpaquePredicate(probe, 2 + math.random(0, 2))
    end
    if tok == "DECOY_BRANCHES" then
      return genDecoyBranches(ensureName, 3 + math.random(0, 4))
    end
    return ensureName(tok)
  end)
end

local HEADER_TEMPLATE = [===[
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

local function %rotr8%(%rb%, %rn%)
  %rn% = %rn% % 8
  if %rn% == 0 then return %rb% end
  return ((%rb% * (2 ^ (8 - %rn%))) % 256) + math.floor(%rb% / (2 ^ %rn%))
end

local function %deriveIV%()
  local %ivv% = 0
  for %ivi% = 1, #%key% do %ivv% = %bxor%(%ivv%, %key%[%ivi%]) end
  return %ivv%
end

local function %cfbUnchain%(%s%)
  local %out%, %prev% = {}, %deriveIV%()
  for %oi% = 1, #%s% do
    local %cc% = %byte%(%s%, %oi%)
    %out%[%oi%] = %char%(%bxor%(%cc%, %prev%))
    %prev% = %cc%
  end
  return %concat%(%out%)
end

local function %diffuseDecrypt%(%s%)
  local %seed% = 2166136261 % 16777216
  for %dki% = 1, #%key% do
    %seed% = %bxor%(%seed%, %key%[%dki%])
    %seed% = (%seed% * 2654435 + 12345) % 16777216
  end
  local %out% = {}
  for %oi% = 1, #%s% do
    %seed% = (%seed% * 2654435 + 12345) % 16777216
    local %lkbyte% = math.floor(%seed% / 65536) % 256
    local %lb% = %rotr8%(%byte%(%s%, %oi%), (%oi% % 5) + 1)
    %out%[%oi%] = %char%(%bxor%(%lb%, %lkbyte%))
  end
  return %concat%(%out%)
end

local function %rc4Decrypt%(%s%)
  local %S% = {}
  for %si% = 0, 255 do %S%[%si%] = %si% end
  local %sj%, %kl% = 0, #%key%
  for %si% = 0, 255 do
    %sj% = (%sj% + %S%[%si%] + %key%[(%si% % %kl%) + 1]) % 256
    %S%[%si%], %S%[%sj%] = %S%[%sj%], %S%[%si%]
  end
  local %ri%, %rj% = 0, 0
  local %out% = {}
  for %oi% = 1, #%s% do
    %ri% = (%ri% + 1) % 256
    %rj% = (%rj% + %S%[%ri%]) % 256
    %S%[%ri%], %S%[%rj%] = %S%[%rj%], %S%[%ri%]
    local %kbyte% = %S%[(%S%[%ri%] + %S%[%rj%]) % 256]
    %out%[%oi%] = %char%(%bxor%(%byte%(%s%, %oi%), %kbyte%))
  end
  return %concat%(%out%)
end

local function %decode%(%s%)
  return %rc4Decrypt%(%diffuseDecrypt%(%cfbUnchain%(%s%)))
end
local %raw% = { __XS_CIPHERS__ }
local %protos% = { __XS_PROTOS__ }

local %corrupt% = function()
  for %kci% = 1, #%key% do %key%[%kci%] = (%key%[%kci%] + 97) % 256 end
  for %cpi% = 1, #%protos% do
    local %cpc% = %protos%[%cpi%].c
    for %cpj% = 1, #%cpc% do %cpc%[%cpj%][1] = -1 end
  end
end

local function %verify%()
  local %h% = 5381
  local function %mix%(%n%) %h% = (%h% * 31 + (%n% or 0)) % 2147483647 end
  for %vci% = 1, #%raw% do
    local %vs% = %raw%[%vci%]
    for %vcj% = 1, #%vs% do %mix%(%byte%(%vs%, %vcj%)) end
  end
  for %vpi% = 1, #%protos% do
    local %vpr% = %protos%[%vpi%]
    %mix%(%vpr%.v and 1 or 0)
    local %vpc% = %vpr%.c
    for %vpk% = 1, #%vpc% do
      local %vins% = %vpc%[%vpk%]
      %mix%(%vins%[1]); %mix%(%vins%[2]); %mix%(%vins%[3]); %mix%(%vins%[4])
    end
    local %vpp% = %vpr%.p
    for %vpj% = 1, #%vpp% do %mix%(%vpp%[%vpj%][1]); %mix%(%vpp%[%vpj%][2]) end
  end
  return (not __XS_ANTITAMPER_ON__) or (%h% == __XS_CHECKSUM__)
end

if not %verify%() then %corrupt%() end

if __XS_ANTIDEBUG__ then
  local %dok%, %dlib% = pcall(function() return debug end)
  if %dok% and %dlib% and %dlib%.gethook then
    local %hok%, %hfn% = pcall(%dlib%.gethook)
    if %hok% and %hfn% ~= nil then %corrupt%() end
  end
  local %ook%, %olib% = pcall(function() return os end)
  if %ook% and %olib% and %olib%.clock then
    local %t0% = %olib%.clock()
    local %junk% = 0
    for %ji% = 1, 30000 do %junk% = %junk% + %ji% end
    if (%olib%.clock() - %t0%) > 0.35 then %corrupt%() end
  end
end

local %consts% = {}
for %i2% = 1, #%raw% do
  local %dv% = %decode%(%raw%[%i2%])
  local %tg% = %dv%:sub(1, 1)
  if %tg% == "N" then %consts%[%i2%] = tonumber(%dv%:sub(2)) - %maskA% else %consts%[%i2%] = %dv%:sub(2) end
end

do
  local %wmVal% = %consts%[__XS_WMIDX__]
  local %wmChecked%, %wmCount% = %wmVal%:gsub("Protected by XenonSec", "Protected by XenonSec")
  if %wmCount% ~= 1 or %wmChecked% ~= "Protected by XenonSec" then %corrupt%() end
end

if __XS_ANTIDEBUG__ then
  local %envIdx% = { __XS_ENVIDX__ }
  for %eni% = 1, #%envIdx% do
    local %enName% = %consts%[%envIdx%[%eni%]]
    local %enok%, %enfn% = pcall(function() return _G[%enName%] end)
    if %enok% and %enfn% ~= nil and type(%enfn%) ~= "function" then %corrupt%() end
  end
end]===]

local FOOTER_TEMPLATE = [===[
if not %verify%() then %corrupt%() end
return (%engine%)({ %consts%, %protos%, __XS_MAIN__ }, ...)]===]

local function minifyTemplateText(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and not (trimmed:sub(1, 2) == "--" and trimmed:sub(1, 4) ~= "--[[" and trimmed:sub(1, 4) ~= "--]]") then
      lines[#lines + 1] = trimmed
    end
  end
  return table.concat(lines, "\n")
end

-- Replaces EVERY occurrence (some placeholders, e.g. __XS_ANTIDEBUG__,
-- appear more than once in the header template; a single-shot replace
-- would leave the later ones as raw identifiers in the emitted code).
local function plainReplace(str, target, replacement)
  local out, pos = {}, 1
  while true do
    local s, e = str:find(target, pos, true)
    if not s then
      out[#out + 1] = str:sub(pos)
      break
    end
    out[#out + 1] = str:sub(pos, s - 1)
    out[#out + 1] = replacement
    pos = e + 1
  end
  return table.concat(out)
end

local DEFAULTS = {
  minify = true,
  junkRate = 0.12,
  decoyConstants = nil,
  localizeGlobals = true,
  fold = true,
  ssa = true,
  luau = false,
  antiTamper = true,
  antiDebug = false,
}

local function obfuscate(source, chunkname, opts)
  opts = opts or {}
  for k, v in pairs(DEFAULTS) do
    if opts[k] == nil then opts[k] = v end
  end

  local ast = Parser.parse(source, chunkname or "input", opts.luau)
  local earlyCaptured = Capture.analyze(ast)
  if opts.fold then Fold.apply(ast) end
  if opts.ssa then
    SSA.apply(ast, earlyCaptured)
    if opts.fold then Fold.apply(ast) end
  end
  if opts.localizeGlobals then Localize.apply(ast) end
  Renamer.resolve(ast)
  local captured = Capture.analyze(ast)
  local mod = Compiler.compile(ast, captured)
  if opts.junkRate and opts.junkRate > 0 then Junk.inject(mod, opts.junkRate) end
  local bundle = buildBundle(mod, opts)

  local vmSrc = opts.minify and minifyTemplateText(VM_TEMPLATE) or VM_TEMPLATE
  local engineSrc = renderTemplate(vmSrc, bundle.OPNUM, bundle.BINNUM, bundle.UNNUM)

  local keyLit = "{" .. table.concat(bundle.key, ",") .. "}"
  local cipherLits = {}
  for i, c in ipairs(bundle.cipherConsts) do
    cipherLits[i] = string.format("%q", c)
  end
  local ciphersLit = table.concat(cipherLits, ",")
  local protosLit = table.concat(bundle.protoLits, ",")

  local nameCache = {}
  local function resolveShared(tok)
    if tok == "engine" then return nil end
    if not nameCache[tok] then nameCache[tok] = randomIdent() end
    return nameCache[tok]
  end

  local headerTpl = opts.minify and minifyTemplateText(HEADER_TEMPLATE) or HEADER_TEMPLATE
  local footerTpl = opts.minify and minifyTemplateText(FOOTER_TEMPLATE) or FOOTER_TEMPLATE

  local header = substitute(headerTpl, resolveShared)
  header = plainReplace(header, "__XS_KEY__", keyLit)
  header = plainReplace(header, "__XS_MASKA__", tostring(bundle.maskA))
  header = plainReplace(header, "__XS_CIPHERS__", ciphersLit)
  header = plainReplace(header, "__XS_PROTOS__", protosLit)
  header = plainReplace(header, "__XS_CHECKSUM__", tostring(bundle.checksum))
  header = plainReplace(header, "__XS_ANTITAMPER_ON__", tostring(opts.antiTamper))
  header = plainReplace(header, "__XS_ANTIDEBUG__", tostring(opts.antiDebug))
  header = plainReplace(header, "__XS_ENVIDX__", table.concat(bundle.envCheckIdx, ","))
  header = plainReplace(header, "__XS_WMIDX__", tostring(bundle.watermarkIdx))

  local footer = substitute(footerTpl, function(tok)
    if tok == "engine" then return "(function()\n" .. engineSrc .. "\nend)()" end
    return resolveShared(tok)
  end)
  footer = plainReplace(footer, "__XS_MAIN__", tostring(bundle.mainProto))

  local combined = header .. "\n" .. footer
  return "return (function(...)\n" .. combined .. "\nend)(...)\n"
end

return { obfuscate = obfuscate }
