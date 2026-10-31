--------------------------------------------------------------------
-- XenonSec :: obfuscator/bundle.lua
-- Turns a compiled module into the encrypted, randomized payload that the header and engine templates consume: constant pool encryption, opcode and operator renumbering, key vault, field masks and checksums.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local load = dofile(dir .. "loader.lua")
local _crypto = load("crypto")
local cipherEncrypt = _crypto.cipherEncrypt
local _opcodes = load("opcodes")
local BINOP_SYMBOLS, OPCODES, UNOP_SYMBOLS, constField = _opcodes.BINOP_SYMBOLS, _opcodes.OPCODES, _opcodes.UNOP_SYMBOLS, _opcodes.constField
local _util = load("util")
local randomByteKey, randomIdent, shuffledRange = _util.randomByteKey, _util.randomIdent, _util.shuffledRange

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

local ENV_CHECK_NAMES = {
  "print", "pairs", "ipairs", "type", "tostring", "tonumber", "pcall",
  "xpcall", "error", "setmetatable", "rawget", "rawset", "rawequal",
  "select", "next",
}

-- How many decoy handlers a build gets. Scales with program size, so a big
-- real program earns a proportionally bigger decoy dispatch chain. Decided
-- in buildBundle so the key pool can be sized to hold real keys and decoys.
local function decoyHandlerCount(totalInstr, strength)
  local mult = strength or 1
  local base = (10 + math.floor((totalInstr or 0) / 15)) * mult
  if base > 60 * mult then base = 60 * mult end
  return math.floor(base + math.random(0, 10) * mult)
end

local function buildBundle(mod, opts)
  opts = opts or {}
  local decoyCount = opts.decoyConstants or (16 + math.random(0, 24))

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

  -- 1.4. Intern the anti-env-logger check names into the SAME
  --      encrypted pool as everything else -- these must never appear
  --      as plaintext in the shipped file either.
  -- (The env-logger check now reads these builtins directly by name; see
  -- the header. They are standard globals the engine already names.)

  -- 1.45. The watermark: unlike the inert `--[[Protected by XenonSec]]`
  --       comment (which is genuinely just decoration -- Lua comments
  --       never execute, so nothing can make a comment's *survival*
  --       runtime-checkable), THIS copy is a real encrypted constant
  --       that gets decoded and re-verified with gsub every run. It's
  --       covered by the exact same checksum as everything else, so if
  --       it doesn't decode back to exactly the right text, that's the
  --       same signal as any other tamper -- not a separate mechanism.
  local watermarkIdx = addConst(mod, "Protected by XenonSec")

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

  -- Host globals read by the program (never written by it) get a live getter
  -- in the header, so runtimes whose globals are not reachable through a
  -- table (Lute, Roblox) still resolve them. Names are host API names, not
  -- secrets; names the program writes stay in encrypted constants.
  local readNames, writtenNames = {}, {}
  for _, proto in ipairs(mod.protos) do
    for _, instr in ipairs(proto.code) do
      if instr.op == "GETVAR" then readNames[mod.consts[instr.b]] = true end
      if instr.op == "SETVAR" then writtenNames[mod.consts[instr.b]] = true end
    end
  end
  local liveNames = {}
  for name in pairs(readNames) do
    if type(name) == "string" and name:match("^[%a_][%w_]*$") and not writtenNames[name] then
      liveNames[#liveNames + 1] = name
    end
  end
  table.sort(liveNames)

  for _, proto in ipairs(mod.protos) do
    for _, instr in ipairs(proto.code) do
      local cf = constField(instr.op)
      if cf then instr[cf] = perm[instr[cf]] end
    end
    for _, pair in ipairs(proto.paramIdx) do
      if pair[1] == 1 then pair[2] = perm[pair[2]] end
    end
  end

  watermarkIdx = perm[watermarkIdx]


  -- 3. Randomize opcode numbers for this build. Binary/unary operator
  --    symbols get their OWN randomized integer IDs too, so BINOP/UNOP
  --    instructions embed a plain per-build integer directly -- no
  --    "+"/"-"/"=="-keyed lookup table needs to exist anywhere in the
  --    shipped file (previously the runtime carried a small literal
  --    table mapping each operator symbol string to a fixed ID, which
  --    leaked the VM's own operator model in plaintext even though the
  --    compiled PROGRAM's use of it was already encrypted).
  -- Every opcode, operator and decoy key is a distinct random number in one
  -- wide range. Real keys used to be a dense 1..n block and decoys a sparse
  -- block of 4-digit numbers, which separated them on sight.
  -- The pool is a random permutation of 1..(real + decoys), so the handler
  -- table is dense: array-speed lookups, and no key range that separates
  -- decoys from real opcodes.
  local totalInstrB = 0
  for _, proto in ipairs(mod.protos) do totalInstrB = totalInstrB + #proto.code end
  local decoyCount = decoyHandlerCount(totalInstrB, opts.strength or 1)
  local realCount = #OPCODES + #BINOP_SYMBOLS + #UNOP_SYMBOLS
  local pool = shuffledRange(realCount + decoyCount)
  local poolNext = 0
  local function freeKey()
    poolNext = poolNext + 1
    assert(poolNext <= #pool, "XenonSec: handler key pool exhausted")
    return pool[poolNext]
  end
  local OPNUM = {}
  for _, name in ipairs(OPCODES) do OPNUM[name] = freeKey() end
  local BINNUM = {}
  for _, sym in ipairs(BINOP_SYMBOLS) do BINNUM[sym] = freeKey() end
  local UNNUM = {}
  for _, sym in ipairs(UNOP_SYMBOLS) do UNNUM[sym] = freeKey() end

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
    cipherConsts[i] = cipherEncrypt(tagged, key)
  end

  -- 4.5. Opcode encoding. Every stored opcode is (key + salt(ip)) mod MOD,
  --       where salt(ip) = (ip * saltA + saltB) mod MOD depends on the
  --       instruction's position. Equal opcodes therefore look different
  --       on disk, and the runtime undoes it with the same constants.
  local MOD = 1048573
  local saltM1 = math.random(2, MOD - 2)
  local saltM2 = math.random(2, MOD - 2)
  -- The mask for one field depends on that instruction's own random seed
  -- and the field's slot (1 = opcode, 2..4 = operands). There is no
  -- position-only pattern to recover.
  local function fieldMask(seed, slot)
    return (seed * saltM1 + slot * saltM2) % MOD
  end
  local function encodeField(v, seed, slot)
    assert(type(v) == "number" and v >= 0 and v < MOD and v == math.floor(v),
      "XenonSec: instruction field out of encodable range: " .. tostring(v))
    return (v + fieldMask(seed, slot)) % MOD
  end

  -- 5. Serialize protos as compact arrays: code[i] = {op, a, b, c}.
  --    Also fold every number that ends up in the output (ciphertext
  --    bytes + every opcode/operand in every proto) into one checksum,
  --    computed with the exact same arithmetic the runtime will use to
  --    recompute it -- this is the anti-tamper integrity value.
  local function mixChecksum(h, n) return (h * 31 + (n or 0)) % 2147483647 end
  local checksum = 5381
  for _, c in ipairs(cipherConsts) do
    for i = 1, #c do checksum = mixChecksum(checksum, c:byte(i)) end
  end

  local protoLits = {}
  for _, proto in ipairs(mod.protos) do
    checksum = mixChecksum(checksum, proto.hasVararg and 1 or 0)
    local psum = mixChecksum(5381, proto.hasVararg and 1 or 0)
    local codeParts = {}
    for ipIdx, instr in ipairs(proto.code) do
      local seed = math.random(0, MOD - 1)
      local opn = OPNUM[instr.op]
      local a = instr.a or 0
      local b = instr.b or 0
      local c = instr.c or 0
      local eop = encodeField(opn, seed, 1)
      local ea = encodeField(a, seed, 2)
      local eb = encodeField(b, seed, 3)
      local ec = encodeField(c, seed, 4)
      checksum = mixChecksum(checksum, seed)
      checksum = mixChecksum(checksum, eop)
      checksum = mixChecksum(checksum, ea)
      checksum = mixChecksum(checksum, eb)
      checksum = mixChecksum(checksum, ec)
      psum = mixChecksum(psum, seed)
      psum = mixChecksum(psum, eop)
      psum = mixChecksum(psum, ea)
      psum = mixChecksum(psum, eb)
      psum = mixChecksum(psum, ec)
      codeParts[#codeParts + 1] = string.format("{%d,%d,%d,%d,%d}", eop, ea, eb, ec, seed)
    end
    local paramParts = {}
    for _, pair in ipairs(proto.paramIdx) do
      checksum = mixChecksum(checksum, pair[1])
      checksum = mixChecksum(checksum, pair[2])
      psum = mixChecksum(psum, pair[1])
      psum = mixChecksum(psum, pair[2])
      paramParts[#paramParts + 1] = string.format("{%d,%d}", pair[1], pair[2])
    end
    checksum = mixChecksum(checksum, psum)
    protoLits[#protoLits + 1] = string.format(
      "{p={%s},v=%s,k=%d,c={%s}}",
      table.concat(paramParts, ","),
      proto.hasVararg and "true" or "false",
      psum,
      table.concat(codeParts, ",")
    )
  end

  return {
    cipherConsts = cipherConsts,
    liveNames = liveNames,
    saltM1 = saltM1,
    saltM2 = saltM2,
    mod = MOD,
    key = key,
    maskA = maskA,
    protoLits = protoLits,
    mainProto = mod.mainProto,
    OPNUM = OPNUM,
    BINNUM = BINNUM,
    UNNUM = UNNUM,
    freeKey = freeKey,
    decoyCount = decoyCount,
    checksum = checksum,
    watermarkIdx = watermarkIdx,
  }
end

return {
  ENV_CHECK_NAMES = ENV_CHECK_NAMES,
  buildBundle = buildBundle,
}
