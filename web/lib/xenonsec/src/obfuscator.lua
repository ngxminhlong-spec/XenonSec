--------------------------------------------------------------------
-- XenonSec :: obfuscator.lua
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
local Passes = req("passes.lua")

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

--------------------------------------------------------------------
-- A proper stream cipher (RC4-style key-scheduling + pseudo-random
-- generation) rather than a plain repeating-key XOR. A repeating-key
-- XOR is a Vigenere cipher -- textbook-breakable by frequency analysis
-- once there's enough ciphertext, since the keystream repeats with a
-- short, fixed period. This doesn't: the keystream is derived from a
-- key-dependent permutation of a 256-entry state table that mutates on
-- every byte, so it never repeats with any short period (verified
-- empirically against 2000 bytes of keystream, checked against every
-- period up to 64, during development -- no repetition found).
--------------------------------------------------------------------

-- Per-build cipher parameters. Nothing here is a textbook constant: the
-- seed basis, the LCG multiplier/addend and the RC4-variant multiplier are
-- drawn for every build, and the runtime header is emitted with the same
-- values (see obfuscateOnce). Set by setCipherParams before any encryption.
local CIPHER = {}
local function setCipherParams()
  CIPHER.basis = math.random(0, 16777215)
  CIPHER.mult = 4 * math.random(0, 4194303) + 1 -- = 1 (mod 4): full LCG period mod 2^24
  CIPHER.add = 2 * math.random(0, 8388607) + 1  -- odd, as the full-period condition needs
  CIPHER.rcMult = 2 * math.random(0, 127) + 1   -- odd multiplier for the RC4-style step
end

local function rc4Ksa(key)
  local S = {}
  for i = 0, 255 do S[i] = i end
  local j = 0
  local keylen = #key
  for i = 0, 255 do
    j = (j * CIPHER.rcMult + S[i] + key[(i % keylen) + 1]) % 256
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
    j = (j * CIPHER.rcMult + S[i]) % 256
    S[i], S[j] = S[j], S[i]
    local K = S[(S[i] + S[j]) % 256]
    out[n] = string.char(byteXor(data:byte(n), K))
  end
  return table.concat(out)
end

local function xorEncode(str, key)
  return rc4Crypt(str, key)
end

--------------------------------------------------------------------
-- Two further layers on top of RC4, so the cipher isn't "just RC4":
--
-- Layer 2: a keyed integer-only LCG drives a per-byte XOR + rotation.
-- All intermediate values are kept well under 2^53 (Lua's exact-
-- integer double range) so results are bit-for-bit identical on any
-- IEEE-754 platform -- unlike a floating-point chaotic map (a
-- documented source of cross-platform divergence in the chaos-based-
-- crypto literature, and a real risk here specifically since this
-- output has to run correctly on whatever mix of stock Lua/LuaJIT/
-- Luau the end user has, not just the machine that built it).
--
-- Layer 3: CFB-style chaining, where each byte's transform depends on
-- the previous ciphertext byte. This removes RC4's property that one
-- ciphertext byte maps to exactly one plaintext byte via a fixed
-- keystream value -- a structurally different transform an attacker
-- has to separately reverse, not just "more of the same XOR".
--------------------------------------------------------------------

local SEED_MOD = 16777216

local function deriveSeed(key)
  local seed = CIPHER.basis
  for i = 1, #key do
    seed = byteXor(seed, key[i])
    seed = (seed * CIPHER.mult + CIPHER.add) % SEED_MOD
  end
  return seed
end

local function lcgNext(seed)
  seed = (seed * CIPHER.mult + CIPHER.add) % SEED_MOD
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

--------------------------------------------------------------------
-- Layer 4 (XenonSec's own construction, not a variant of any of the
-- three above): a keyed substitution-permutation step.
--   - Substitution: every one of the 256 possible byte values is
--     remapped through a key-dependent permutation (a proper S-box,
--     built with the same LCG this file already uses elsewhere --
--     not the identity table, not a static lookup).
--   - Permutation: bytes are then shuffled *within* fixed 8-byte
--     blocks according to a second, independent key-dependent
--     permutation. A trailing partial block is left in place (nothing
--     unsafe about that -- ciphertext length already equals plaintext
--     length, so block-alignment reveals nothing new).
-- Both permutations are derived from the key alone, so nothing extra
-- needs to be embedded in the output beyond the same key the other
-- three layers already carry.
--------------------------------------------------------------------

local SPN_BLOCK = 8

local function deriveSbox(key)
  local box = {}
  for i = 0, 255 do box[i] = i end
  local seed = deriveSeed(key)
  for i = 255, 1, -1 do
    local r
    seed, r = lcgNext(seed)
    local j = r % (i + 1)
    box[i], box[j] = box[j], box[i]
  end
  return box
end

local function invertSbox(box)
  local inv = {}
  for i = 0, 255 do inv[box[i]] = i end
  return inv
end

local function deriveBlockOrder(key)
  local seed = deriveSeed(key)
  -- Burn one LCG step first so this permutation doesn't start from the
  -- exact same state the S-box shuffle started from.
  local _
  seed, _ = lcgNext(seed)
  local order = { 1, 2, 3, 4, 5, 6, 7, 8 }
  for i = SPN_BLOCK, 2, -1 do
    local r
    seed, r = lcgNext(seed)
    local j = (r % i) + 1
    order[i], order[j] = order[j], order[i]
  end
  return order
end

local function invertOrder(order)
  local inv = {}
  for i = 1, #order do inv[order[i]] = i end
  return inv
end

-- Gather: out[k] = data[order[k]] within every full SPN_BLOCK-byte
-- block; a trailing partial block passes through unchanged. Passing
-- the forward order performs the permutation; passing its inverse
-- undoes it -- same function, either direction.
local function blockPermute(data, order)
  local len = #data
  local full = len - (len % SPN_BLOCK)
  local out = {}
  for i = 1, full, SPN_BLOCK do
    for k = 1, SPN_BLOCK do
      out[i + k - 1] = data:sub(i + order[k] - 1, i + order[k] - 1)
    end
  end
  for i = full + 1, len do out[i] = data:sub(i, i) end
  return table.concat(out)
end

local function spnEncrypt(data, key)
  local box = deriveSbox(key)
  local subbed = {}
  for i = 1, #data do subbed[i] = string.char(box[data:byte(i)]) end
  return blockPermute(table.concat(subbed), deriveBlockOrder(key))
end

local function spnDecrypt(data, key)
  local unpermuted = blockPermute(data, invertOrder(deriveBlockOrder(key)))
  local invBox = invertSbox(deriveSbox(key))
  local out = {}
  for i = 1, #unpermuted do out[i] = string.char(invBox[unpermuted:byte(i)]) end
  return table.concat(out)
end

-- The single entry point used everywhere else in this file: four
-- layers, applied in order. Every obfuscated program decodes its constants
-- through the matching runtime code, so the suites exercise the round trip
-- on every build (any mismatch fails at the first constant read).
local function cipherEncrypt(plaintext, key)
  local a = rc4Crypt(plaintext, key)
  local b = diffuseEncrypt(a, key)
  local c = cfbChain(b, deriveIV(key))
  local d = spnEncrypt(c, key)
  return d
end

local function cipherDecrypt(ciphertext, key)
  local c = spnDecrypt(ciphertext, key)
  local b = cfbUnchain(c, deriveIV(key))
  local a = diffuseDecrypt(b, key)
  local plaintext = rc4Crypt(a, key)
  return plaintext
end

--------------------------------------------------------------------
-- Opcode list -- MUST exactly match the opcode names compiler.lua
-- emits. Order here doesn't matter; numbers are assigned randomly.
--------------------------------------------------------------------

local OPCODES = {
  "LOADK", "LOADNIL", "LOADTRUE", "LOADFALSE", "MOVE",
  "GETVAR", "SETVAR", "DECLCELL",
  "NEWTABLE", "GETIDX", "SETIDX", "GETIDXK", "SETIDXK", "SETLISTM", "SELF",
  "CLOSURE", "VARARG", "CALL", "CALLM", "RET", "RETM",
  "JMP", "JF", "JT", "JNIL", "NEWSCOPE", "POPSCOPE", "JUNK",
}

-- Instructions whose `a` field is a constant-pool index (everything
-- else's a/b/c fields are raw integers: jump targets, proto indices,
-- register slot numbers, argument counts, etc.)
local BINOP_SYMBOLS = Compiler.BINOP_SYMBOLS
local UNOP_SYMBOLS = Compiler.UNOP_SYMBOLS
-- One opcode per binary operator (register and constant right-hand forms)
-- and per unary operator.
for k = 1, #BINOP_SYMBOLS do
  OPCODES[#OPCODES + 1] = "BIN" .. k
  OPCODES[#OPCODES + 1] = "BINK" .. k
end
for k = 1, #UNOP_SYMBOLS do
  OPCODES[#OPCODES + 1] = "UN" .. k
end

-- Which operand field of each opcode holds a constant-pool index (the rest
-- are raw integers: registers, counts, jump targets, proto indices).
local CONST_FIELD = {
  LOADK = "b", GETVAR = "b", SETVAR = "b", DECLCELL = "b", SETIDXK = "b",
  GETIDXK = "c", SELF = "c", SETLISTM = "c", JUNK = "b",
}
local function constField(op)
  if CONST_FIELD[op] then return CONST_FIELD[op] end
  if op:sub(1, 4) == "BINK" then return "c" end
  return nil
end

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

local %OP_LOADK%,%OP_LOADNIL%,%OP_LOADTRUE%,%OP_LOADFALSE%,%OP_MOVE%,%OP_GETVAR%,%OP_SETVAR%,%OP_DECLCELL%,
      %OP_NEWTABLE%,%OP_GETIDX%,%OP_SETIDX%,%OP_GETIDXK%,%OP_SETIDXK%,%OP_SETLISTM%,%OP_SELF%,
      %OP_CLOSURE%,%OP_VARARG%,%OP_CALL%,%OP_CALLM%,%OP_RET%,%OP_RETM%,
      %OP_JMP%,%OP_JF%,%OP_JT%,%OP_JNIL%,%OP_NEWSCOPE%,%OP_POPSCOPE%,%OP_JUNK%
  = %N_LOADK%,%N_LOADNIL%,%N_LOADTRUE%,%N_LOADFALSE%,%N_MOVE%,%N_GETVAR%,%N_SETVAR%,%N_DECLCELL%,
    %N_NEWTABLE%,%N_GETIDX%,%N_SETIDX%,%N_GETIDXK%,%N_SETIDXK%,%N_SETLISTM%,%N_SELF%,
    %N_CLOSURE%,%N_VARARG%,%N_CALL%,%N_CALLM%,%N_RET%,%N_RETM%,
    %N_JMP%,%N_JF%,%N_JT%,%N_JNIL%,%N_NEWSCOPE%,%N_POPSCOPE%,%N_JUNK%

local function %run%(%mod%, ...)
  local %consts%, %protos%, %mainIdx% = %mod%[1], %mod%[2], %mod%[3]
  local %adHook% = %mod%[4]
  local %GETG% = %mod%[5]
  local %SETG% = %mod%[6]
  local %brick% = function()
    for %bi% = 1, #%protos% do
      local %bc% = %protos%[%bi%].c
      for %bj% = 1, #%bc% do %bc%[%bj%][1] = nil end
    end
  end

  %PROXYMETA%
  -- Walks the cell chain for a captured local; nil means "global".
  local function %lookup%(%F%, %name%)
    local %s% = %F%.%scope%
    while %s% do
      if %s%.%varsField%[%name%] ~= nil then return %s% end
      %s% = %s%.%parentField%
    end
    return nil
  end

  local %runProto%
  local function %mkClosure%(%F%, %pIdx%)
    local %cs% = %F%.%scope%
    return function(...)
      return %runProto%(%pIdx%, %pack%(...), %cs%)
    end
  end

  -- Field decoder: stored = (value + mask(seed, slot)) mod MOD. The
  -- dispatcher inlines the same arithmetic; this copy serves the verifier.
  local function %dec%(%v%, %sd%, %slot%)
    return (%v% - (%sd% * %K_M1% + %slot% * %K_M2%) % %K_MOD%) % %K_MOD%
  end

  -- Per-proto integrity: recompute one proto's checksum and compare it with
  -- the value stored in its literal (same arithmetic as the build).
  local function %vp%(%pi%)
    local %pp% = %protos%[%pi%]
    local %hh% = 5381
    local function %mm%(%n%) %hh% = (%hh% * 31 + (%n% or 0)) % 2147483647 end
    %mm%(%pp%.v and 1 or 0)
    for %vk% = 1, #%pp%.c do
      local %vi% = %pp%.c[%vk%]
      %mm%(%vi%[5]); %mm%(%vi%[1]); %mm%(%vi%[2]); %mm%(%vi%[3]); %mm%(%vi%[4])
    end
    for %vj% = 1, #%pp%.p do %mm%(%pp%.p[%vj%][1]); %mm%(%pp%.p[%vj%][2]) end
    return %hh% == %pp%.k
  end

  -- Handler table: one handler per opcode, keyed by its per-build number.
  -- Each handler takes the frame and the instruction, reads its decoded
  -- operands from the frame (a = x2, b = x3, c = x4), and moves the
  -- instruction pointer. Registers live in F.regs; nothing is pushed or popped.
  local %H% = {}

  %H%[%OP_LOADK%] = function(%F%, %ins%)
    if not (%OPQ_LOADK%) then error() end
    %F%.%regs%[%F%.%x2%] = %consts%[%F%.%x3%]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_LOADNIL%] = function(%F%, %ins%)
    if not (%OPQ_LOADNIL%) then error() end
    local %r% = %F%.%regs%
    for %i% = %F%.%x2%, %F%.%x2% + %F%.%x3% - 1 do %r%[%i%] = nil end
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_LOADTRUE%] = function(%F%, %ins%)
    if not (%OPQ_LOADTRUE%) then error() end
    %F%.%regs%[%F%.%x2%] = true
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_LOADFALSE%] = function(%F%, %ins%)
    if not (%OPQ_LOADFALSE%) then error() end
    %F%.%regs%[%F%.%x2%] = false
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_MOVE%] = function(%F%, %ins%)
    if not (%OPQ_MOVE%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%] = %r%[%F%.%x3%]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_GETVAR%] = function(%F%, %ins%)
    if not (%OPQ_GETVAR%) then error() end
    local %nm% = %consts%[%F%.%x3%]
    local %sc% = %lookup%(%F%, %nm%)
    local %r% = %F%.%regs%
    if %sc% then
      local %v% = %sc%.%varsField%[%nm%]
      if %v% == %NILV% then %r%[%F%.%x2%] = nil else %r%[%F%.%x2%] = %v% end
    else
      %r%[%F%.%x2%] = %GETG%(%nm%)
    end
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_SETVAR%] = function(%F%, %ins%)
    if not (%OPQ_SETVAR%) then error() end
    local %nm% = %consts%[%F%.%x3%]
    local %v% = %F%.%regs%[%F%.%x2%]
    local %sc% = %lookup%(%F%, %nm%)
    if %sc% then
      %sc%.%varsField%[%nm%] = (%v% == nil) and %NILV% or %v%
    else
      %SETG%(%nm%, %v%)
    end
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_DECLCELL%] = function(%F%, %ins%)
    if not (%OPQ_DECLCELL%) then error() end
    local %v% = %F%.%regs%[%F%.%x2%]
    %F%.%scope%.%varsField%[%consts%[%F%.%x3%]] = (%v% == nil) and %NILV% or %v%
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_NEWTABLE%] = function(%F%, %ins%)
    if not (%OPQ_NEWTABLE%) then error() end
    %F%.%regs%[%F%.%x2%] = {}
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_GETIDX%] = function(%F%, %ins%)
    if not (%OPQ_GETIDX%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%] = %r%[%F%.%x3%][%r%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_SETIDX%] = function(%F%, %ins%)
    if not (%OPQ_SETIDX%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%][%r%[%F%.%x3%]] = %r%[%F%.%x4%]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_GETIDXK%] = function(%F%, %ins%)
    if not (%OPQ_GETIDXK%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%] = %r%[%F%.%x3%][%consts%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_SETIDXK%] = function(%F%, %ins%)
    if not (%OPQ_SETIDXK%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%][%consts%[%F%.%x3%]] = %r%[%F%.%x4%]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_SETLISTM%] = function(%F%, %ins%)
    if not (%OPQ_SETLISTM%) then error() end
    local %r% = %F%.%regs%
    local %t% = %r%[%F%.%x2%]
    local %off% = %consts%[%F%.%x4%]
    for %j% = 1, %F%.%top% do %t%[%off% + %j%] = %r%[%F%.%x3% + %j% - 1] end
    %F%.%ip% = %F%.%ip% + 1
  end

  -- SELF: the method goes to a, the object to a+1 (the first argument).
  %H%[%OP_SELF%] = function(%F%, %ins%)
    if not (%OPQ_SELF%) then error() end
    local %r% = %F%.%regs%
    local %o% = %r%[%F%.%x3%]
    %r%[%F%.%x2% + 1] = %o%
    %r%[%F%.%x2%] = %o%[%consts%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_CLOSURE%] = function(%F%, %ins%)
    if not (%OPQ_CLOSURE%) then error() end
    %F%.%regs%[%F%.%x2%] = %mkClosure%(%F%, %F%.%x3%)
    %F%.%ip% = %F%.%ip% + 1
  end

  -- VARARG: b = count+1 copies that many; b = 0 copies all and sets top.
  %H%[%OP_VARARG%] = function(%F%, %ins%)
    if not (%OPQ_VARARG%) then error() end
    local %r% = %F%.%regs%
    local %vav% = %F%.%va%
    local %a% = %F%.%x2%
    if %F%.%x3% == 0 then
      local %n% = %vav% and %vav%.n or 0
      for %j% = 1, %n% do %r%[%a% + %j% - 1] = %vav%[%j%] end
      %F%.%top% = %n%
    else
      for %j% = 1, %F%.%x3% - 1 do
        local %vv% = nil
        if %vav% then %vv% = %vav%[%j%] end
        %r%[%a% + %j% - 1] = %vv%
      end
    end
    %F%.%ip% = %F%.%ip% + 1
  end

  -- CALL: fn = r[a], args = r[a+1 .. a+b-1]; results to r[a ..] (c-1 of them,
  -- or all with the count in top when c = 0).
  %H%[%OP_CALL%] = function(%F%, %ins%)
    if not (%OPQ_CALL%) then error() end
    local %r% = %F%.%regs%
    local %a% = %F%.%x2%
    local %fn% = %r%[%a%]
    local %n% = %F%.%x3% - 1
    local %args% = {}
    for %j% = 1, %n% do %args%[%j%] = %r%[%a% + %j%] end
    local %res% = %pack%(%fn%(%unpack%(%args%, 1, %n%)))
    local %c% = %F%.%x4%
    if %c% == 0 then
      for %j% = 1, %res%.n do %r%[%a% + %j% - 1] = %res%[%j%] end
      %F%.%top% = %res%.n
    else
      for %j% = 1, %c% - 1 do %r%[%a% + %j% - 1] = %res%[%j%] end
    end
    %F%.%ip% = %F%.%ip% + 1
  end

  -- CALLM: like CALL, but the arguments after the fixed ones come from top.
  %H%[%OP_CALLM%] = function(%F%, %ins%)
    if not (%OPQ_CALLM%) then error() end
    local %r% = %F%.%regs%
    local %a% = %F%.%x2%
    local %fn% = %r%[%a%]
    local %fx% = %F%.%x3% - 1
    local %tp% = %F%.%top%
    local %args% = {}
    for %j% = 1, %fx% do %args%[%j%] = %r%[%a% + %j%] end
    for %j% = 1, %tp% do %args%[%fx% + %j%] = %r%[%a% + %fx% + %j%] end
    local %res% = %pack%(%fn%(%unpack%(%args%, 1, %fx% + %tp%)))
    local %c% = %F%.%x4%
    if %c% == 0 then
      for %j% = 1, %res%.n do %r%[%a% + %j% - 1] = %res%[%j%] end
      %F%.%top% = %res%.n
    else
      for %j% = 1, %c% - 1 do %r%[%a% + %j% - 1] = %res%[%j%] end
    end
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_RET%] = function(%F%, %ins%)
    if not (%OPQ_RET%) then error() end
    local %r% = %F%.%regs%
    local %n% = %F%.%x3% - 1
    local %vals% = { n = %n% }
    for %j% = 1, %n% do %vals%[%j%] = %r%[%F%.%x2% + %j% - 1] end
    %F%.%ret% = %vals%
    %F%.%fin% = true
  end

  %H%[%OP_RETM%] = function(%F%, %ins%)
    if not (%OPQ_RETM%) then error() end
    local %r% = %F%.%regs%
    local %a% = %F%.%x2%
    local %fx% = %F%.%x3% - 1
    local %tp% = %F%.%top%
    local %vals% = {}
    for %j% = 1, %fx% do %vals%[%j%] = %r%[%a% + %j% - 1] end
    for %j% = 1, %tp% do %vals%[%fx% + %j%] = %r%[%a% + %fx% + %j% - 1] end
    %vals%.n = %fx% + %tp%
    %F%.%ret% = %vals%
    %F%.%fin% = true
  end

  %H%[%OP_JMP%] = function(%F%, %ins%)
    if not (%OPQ_JMP%) then error() end
    %F%.%ip% = %F%.%x2%
  end

  %H%[%OP_JF%] = function(%F%, %ins%)
    if not (%OPQ_JF%) then error() end
    local %v% = %F%.%regs%[%F%.%x2%]
    if %v% ~= nil and %v% ~= false then %F%.%ip% = %F%.%ip% + 1 else %F%.%ip% = %F%.%x3% end
  end

  %H%[%OP_JT%] = function(%F%, %ins%)
    if not (%OPQ_JT%) then error() end
    local %v% = %F%.%regs%[%F%.%x2%]
    if %v% ~= nil and %v% ~= false then %F%.%ip% = %F%.%x3% else %F%.%ip% = %F%.%ip% + 1 end
  end

  %H%[%OP_JNIL%] = function(%F%, %ins%)
    if not (%OPQ_JNIL%) then error() end
    if %F%.%regs%[%F%.%x2%] == nil then %F%.%ip% = %F%.%x3% else %F%.%ip% = %F%.%ip% + 1 end
  end

  %H%[%OP_NEWSCOPE%] = function(%F%, %ins%)
    if not (%OPQ_NEWSCOPE%) then error() end
    %F%.%scope% = { %varsField% = %NEWVARS%, %parentField% = %F%.%scope% }
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_POPSCOPE%] = function(%F%, %ins%)
    if not (%OPQ_POPSCOPE%) then error() end
    %F%.%scope% = %F%.%scope%.%parentField%
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_JUNK%] = function(%F%, %ins%)
    if not (%OPQ_JUNK%) then error() end
    %F%.%regs%[%F%.%x2%] = %consts%[%F%.%x3%]
    %F%.%ip% = %F%.%ip% + 1
  end

%DECOY_HANDLERS%

  %runProto% = function(%protoIdx%, %callArgs%, %parentScope%)
    local %proto% = %protos%[%protoIdx%]
    local %F% = {
      %code% = %proto%.c, %ip% = 1, %regs% = %NEWREGS%, %top% = 0,
      %scope% = { %varsField% = %NEWVARS%, %parentField% = %parentScope% },
      %va% = nil, %fin% = false, %ret% = nil, %pr% = 0,
      %x2% = 0, %x3% = 0, %x4% = 0,
    }
    local %params% = %proto%.p
    for %pi% = 1, #%params% do
      local %pdesc% = %params%[%pi%]
      local %pv% = %callArgs%[%pi%]
      if %pdesc%[1] == 0 then
        %F%.%regs%[%pdesc%[2]] = %pv%
      else
        %F%.%scope%.%varsField%[%consts%[%pdesc%[2]]] = (%pv% == nil) and %NILV% or %pv%
      end
    end
    if %proto%.v then
      local %nva% = (%callArgs%.n or #%callArgs%) - #%params%
      if %nva% < 0 then %nva% = 0 end
      local %va% = { n = %nva% }
      for %vi% = 1, %nva% do %va%[%vi%] = %callArgs%[#%params% + %vi%] end
      %F%.%va% = %va%
    end

    while true do
      local %ins% = %F%.%code%[%F%.%ip%]
      if not %ins% then return end
      -- Step-by-step decode: this instruction's opcode and operands are
      -- decoded now, from its own seed, immediately before it runs.
      local %sd% = %ins%[5]
      local %mk% = %sd% * %K_M1%
      local %key% = (%ins%[1] - (%mk% + %K_M2%) % %K_MOD%) % %K_MOD%
      local %h% = %H%[%key%]
      if not %h% then error() end
      %F%.%x2% = (%ins%[2] - (%mk% + 2 * %K_M2%) % %K_MOD%) % %K_MOD%
      %F%.%x3% = (%ins%[3] - (%mk% + 3 * %K_M2%) % %K_MOD%) % %K_MOD%
      %F%.%x4% = (%ins%[4] - (%mk% + 4 * %K_M2%) % %K_MOD%) % %K_MOD%
      %F%.%pr% = (%F%.%pr% + 1) % 65536
      %PERIODIC%
      %ADCHECK%
      %h%(%F%, %ins%)
      if %F%.%fin% then return %unpack%(%F%.%ret%, 1, %F%.%ret%.n) end
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
  "(((V*(V+1)*(V+2))%6)==0)",                 -- product of 3 consecutive ints divisible by 6
  "((((V*V*V)-V)%6)==0)",                     -- v^3 - v divisible by 6 (v(v-1)(v+1))
  "(((V+V)%2)==0)",                           -- v + v is always even
  "((V*V)>=0)",                               -- a square is never negative
  "((V==V))",                                 -- reflexivity
  "(not (V~=V))",                             -- negated-inequality reflexivity
  "(((V*5-V*4-V))==0)",                       -- 5v - 4v - v == 0
  "(((V*V-V*V))==0)",                         -- v^2 - v^2 == 0
}

-- Logical negations of the same identities, for decoy branches that
-- must NEVER be taken (see genAlwaysFalsePredicate below).
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

-- A provably-never-true guard for decoy dispatch branches: the body
-- behind it is genuine, syntactically valid Lua that a static reader
-- has to spend time understanding, but it can never execute -- an
-- always-false identity ANDed with an always-true one (so it's not
-- trivially a single obviously-negated check sitting alone).
local function genAlwaysFalsePredicate(probeName)
  local falseIdx = math.random(1, #FALSE_IDENTITIES)
  local trueIdx = math.random(1, #OPAQUE_IDENTITIES)
  local f = (FALSE_IDENTITIES[falseIdx]:gsub("V", probeName))
  local t = (OPAQUE_IDENTITIES[trueIdx]:gsub("V", probeName))
  return "(" .. f .. " and " .. t .. ")"
end

-- Safe placeholder-token names for operator symbols (can't embed "+"
-- etc directly in a %word% token).
local BINOP_TOKEN_NAMES = {
  ["+"] = "PLUS", ["-"] = "MINUS", ["*"] = "MUL", ["/"] = "DIV",
  ["%"] = "MOD", ["^"] = "POW", [".."] = "CONCAT",
  ["=="] = "EQ", ["~="] = "NE", ["<"] = "LT", [">"] = "GT",
  ["<="] = "LE", [">="] = "GE", ["//"] = "IDIV",
}
local UNOP_TOKEN_NAMES = { ["-"] = "UNM", ["not"] = "NOT", ["#"] = "LEN" }

-- Decoy dispatch branches: syntactically real Lua, guarded by an
-- always-false predicate so they can never execute (a static reader
-- can't tell that from reading the condition alone -- same shape as
-- the real, always-true guards on every genuine branch). Pure
-- analysis noise: inflates the apparent opcode count and makes a
-- purely-structural read of the dispatch chain unreliable.
local function genDecoyHandlers(ensureName, count, probeExpr, freeKey)
  local H, F, ins = ensureName("H"), ensureName("F"), ensureName("ins")
  local ip, regsF = ensureName("ip"), ensureName("regs")
  local x2, x3, x4 = ensureName("x2"), ensureName("x3"), ensureName("x4")
  local BINOPS, consts = ensureName("BINOPS"), ensureName("consts")

  -- Plausible bodies over the real frame fields. They are never reachable:
  -- their keys come from the same pool as the real opcodes but are never
  -- assigned to one, so no encoded instruction decodes to them. Each one
  -- is written in the same wrapper as a real handler (gate, body, ip + 1),
  -- so a reader can't tell the two apart by shape.
  local flavors = {
    function()
      local dv = ensureName("dv" .. tostring(math.random(1, 99999)))
      return string.format("local %s = %s.%s[%s.%s]; %s.%s[%s.%s] = %s", dv, F, regsF, F, x2, F, regsF, F, x2, dv)
    end,
    function()
      return string.format("local r = %s.%s; r[%s.%s] = %s[%s.%s]", F, regsF, F, x2, consts, F, x4)
    end,
    function()
      local tv = ensureName("tv" .. tostring(math.random(1, 99999)))
      return string.format("local %s = %s.%s[%s.%s] or 0; %s.%s[%s.%s] = %s * 2",
        tv, F, regsF, F, x3, F, regsF, F, x2, tv)
    end,
    function(key)
      return string.format("local r = %s.%s; r[%s.%s] = %s[%d](r[%s.%s], r[%s.%s])",
        F, regsF, F, x2, BINOPS, key, F, x3, F, x4)
    end,
  }

  local lines = {}
  for _ = 1, count do
    local key = freeKey()
    local cond = genAlwaysFalsePredicate(probeExpr())
    local body = flavors[math.random(1, #flavors)](key)
    lines[#lines + 1] = string.format(
      "%s[%d] = function(%s, %s) if not (%s) then error() end %s %s.%s = %s.%s + 1 end",
      H, key, F, ins, cond, body, F, ip, F, ip)
  end
  return table.concat(lines, "\n")
end

-- Handlers for the operator opcodes. Each reads its operands from the frame
-- (a = x2 destination, b = x3, c = x4) and writes the destination register.
local function genOpHandlers(ensureName, probeExpr, OPNUM, BINNUM, UNNUM)
  local H, F, ins = ensureName("H"), ensureName("F"), ensureName("ins")
  local regsF, ipF = ensureName("regs"), ensureName("ip")
  local x2, x3, x4 = ensureName("x2"), ensureName("x3"), ensureName("x4")
  local BINOPS, UNOPS, consts = ensureName("BINOPS"), ensureName("UNOPS"), ensureName("consts")
  local lines = {}
  local function handler(opnum, body)
    local gate = genOpaquePredicate(probeExpr(), 3)
    lines[#lines + 1] = string.format(
      "%s[%d] = function(%s, %s) if not (%s) then error() end %s %s.%s = %s.%s + 1 end",
      H, opnum, F, ins, gate, body, F, ipF, F, ipF)
  end
  for k, sym in ipairs(BINOP_SYMBOLS) do
    local num = BINNUM[sym]
    handler(OPNUM["BIN" .. k], string.format(
      "local r = %s.%s; r[%s.%s] = %s[%d](r[%s.%s], r[%s.%s]);",
      F, regsF, F, x2, BINOPS, num, F, x3, F, x4))
    handler(OPNUM["BINK" .. k], string.format(
      "local r = %s.%s; r[%s.%s] = %s[%d](r[%s.%s], %s[%s.%s]);",
      F, regsF, F, x2, BINOPS, num, F, x3, consts, F, x4))
  end
  for k, sym in ipairs(UNOP_SYMBOLS) do
    local num = UNNUM[sym]
    handler(OPNUM["UN" .. k], string.format(
      "local r = %s.%s; r[%s.%s] = %s[%d](r[%s.%s]);",
      F, regsF, F, x2, UNOPS, num, F, x3))
  end
  return table.concat(lines, "\n")
end

local function renderTemplate(template, OPNUM, BINNUM, UNNUM, totalInstr, antiDebug, KV)
  local nameCache = {}
  local function ensureName(tok)
    if not nameCache[tok] then nameCache[tok] = randomIdent() end
    return nameCache[tok]
  end
  -- The probe counter lives on the frame, so handlers reach it as F.pr.
  local function probeExpr()
    return ensureName("F") .. "." .. ensureName("pr")
  end
  return substitute(template, function(tok)
    if tok == "ADCHECK" then
      if not antiDebug then return "" end
      -- Every 2048 dispatched instructions, re-probe for an attached hook.
      -- Cheap (one modulo + one gethook call), and it catches debuggers
      -- attached AFTER startup, which the one-shot check alone never sees.
      return "if " .. probeExpr() .. " % 2048 == 0 and " ..
             ensureName("adHook") .. "() then " .. ensureName("brick") .. "() end"
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
      local verify = "if " .. probeExpr() .. " % 4096 == 0 then local " .. pidx .. " = (" ..
             probeExpr() .. " / 4096) % #" .. ensureName("protos") .. " + 1; if not " ..
             ensureName("vp") .. "(" .. pidx .. ") then " .. ensureName("brick") .. "() end end"
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
  end)
end

--------------------------------------------------------------------
-- Header template: XOR/decode helpers + the decrypted constant pool
-- + the literal proto table, all with randomized local names.
--------------------------------------------------------------------

local HEADER_TEMPLATE = [===[
--[[Protected by XenonSec]]
local %byte% = string.byte
local %char% = string.char
local %concat% = table.concat
__XS_STD__
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

-- Four-layer decrypt, undone in reverse order of how it was applied:
-- the keyed S-box/block-permutation layer, then CFB-unchain, then the
-- LCG-keyed rotation/XOR diffusion layer, then RC4. See obfuscate.lua's
-- cipherEncrypt/cipherDecrypt for why each layer is there -- this is
-- the exact same construction, just spelled out with per-build
-- randomized names.
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

-- Key-derived LCG seed. Mirrors deriveSeed in obfuscate.lua; the constants
-- are this build's own (see CIPHER there), not textbook values.
local function %keySeed%()
  local %kd% = __XS_SB__
  for %ki% = 1, #%key% do
    %kd% = %bxor%(%kd%, %key%[%ki%])
    %kd% = (%kd% * __XS_LM__ + __XS_LA__) % 16777216
  end
  return %kd%
end

local function %diffuseDecrypt%(%s%)
  local %seed% = %keySeed%()
  local %out% = {}
  for %oi% = 1, #%s% do
    %seed% = (%seed% * __XS_LM__ + __XS_LA__) % 16777216
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
    %sj% = (%sj% * __XS_RM__ + %S%[%si%] + %key%[(%si% % %kl%) + 1]) % 256
    %S%[%si%], %S%[%sj%] = %S%[%sj%], %S%[%si%]
  end
  local %ri%, %rj% = 0, 0
  local %out% = {}
  for %oi% = 1, #%s% do
    %ri% = (%ri% + 1) % 256
    %rj% = (%rj% * __XS_RM__ + %S%[%ri%]) % 256
    %S%[%ri%], %S%[%rj%] = %S%[%rj%], %S%[%ri%]
    local %kbyte% = %S%[(%S%[%ri%] + %S%[%rj%]) % 256]
    %out%[%oi%] = %char%(%bxor%(%byte%(%s%, %oi%), %kbyte%))
  end
  return %concat%(%out%)
end

-- Layer 4 (runtime side): a keyed S-box substitution plus a keyed
-- within-block permutation, both derived from %key% alone. Exact
-- mirror of obfuscate.lua's deriveSbox/deriveBlockOrder/blockPermute
-- -- see there for why each step is there.
local function %spnDecrypt%(%ssIn%)
  local %sSeed% = %keySeed%()
  local %sBox% = {}
  for %sbi% = 0, 255 do %sBox%[%sbi%] = %sbi% end
  for %sbj% = 255, 1, -1 do
    %sSeed% = (%sSeed% * __XS_LM__ + __XS_LA__) % 16777216
    local %sbr% = (math.floor(%sSeed% / 65536) % 256) % (%sbj% + 1)
    %sBox%[%sbj%], %sBox%[%sbr%] = %sBox%[%sbr%], %sBox%[%sbj%]
  end
  local %sInv% = {}
  for %sii% = 0, 255 do %sInv%[%sBox%[%sii%]] = %sii% end

  local %bSeed% = %keySeed%()
  %bSeed% = (%bSeed% * __XS_LM__ + __XS_LA__) % 16777216
  local %sOrder% = { 1, 2, 3, 4, 5, 6, 7, 8 }
  for %soi% = 8, 2, -1 do
    %bSeed% = (%bSeed% * __XS_LM__ + __XS_LA__) % 16777216
    local %sor% = ((math.floor(%bSeed% / 65536) % 256) % %soi%) + 1
    %sOrder%[%soi%], %sOrder%[%sor%] = %sOrder%[%sor%], %sOrder%[%soi%]
  end
  local %sInvOrd% = {}
  for %sioi% = 1, 8 do %sInvOrd%[%sOrder%[%sioi%]] = %sioi% end

  local %sLen% = #%ssIn%
  local %sFull% = %sLen% - (%sLen% % 8)
  local %sPerm% = {}
  for %spi% = 1, %sFull%, 8 do
    for %spk% = 1, 8 do
      %sPerm%[%spi% + %spk% - 1] = %byte%(%ssIn%, %spi% + %sInvOrd%[%spk%] - 1)
    end
  end
  for %spj% = %sFull% + 1, %sLen% do %sPerm%[%spj%] = %byte%(%ssIn%, %spj%) end

  local %sOut% = {}
  for %soj% = 1, %sLen% do %sOut%[%soj%] = %char%(%sInv%[%sPerm%[%soj%]]) end
  return %concat%(%sOut%)
end

local function %decode%(%s%)
  return %rc4Decrypt%(%diffuseDecrypt%(%cfbUnchain%(%spnDecrypt%(%s%))))
end
local %raw% = { __XS_CIPHERS__ }
local %protos% = { __XS_PROTOS__ }

--------------------------------------------------------------------
-- Anti-tamper: a checksum computed at build time over every byte of
-- the ciphertext pool and every opcode/operand in every proto is
-- re-verified here, BEFORE anything gets decoded. On mismatch the key
-- is silently corrupted rather than raising an obvious error -- the
-- script keeps running and fails somewhere downstream with a
-- confusing, unrelated-looking error instead of pointing straight at
-- the check that caught it.
--------------------------------------------------------------------

local %corrupt% = function()
  for %kci% = 1, #%key% do %key%[%kci%] = (%key%[%kci%] + 97) % 256 end
  -- The key only protects the encrypted string/number pool -- the
  -- proto/bytecode table itself is plain literal Lua data, never
  -- decrypted via the key at all. So a tamper landing purely inside
  -- the bytecode wouldn't be neutralized by corrupting the key alone.
  -- Force EVERY instruction in EVERY proto to an opcode number that
  -- can never match any real one, so the very first instruction any
  -- proto executes fails immediately, no matter where the tamper was.
  for %cpi% = 1, #%protos% do
    local %cpc% = %protos%[%cpi%].c
    for %cpj% = 1, #%cpc% do %cpc%[%cpj%][1] = nil end
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
      %mix%(%vins%[5]); %mix%(%vins%[1]); %mix%(%vins%[2]); %mix%(%vins%[3]); %mix%(%vins%[4])
    end
    local %vpp% = %vpr%.p
    for %vpj% = 1, #%vpp% do %mix%(%vpp%[%vpj%][1]); %mix%(%vpp%[%vpj%][2]) end
    %mix%(%vpr%.k)
  end
  return (not __XS_ANTITAMPER_ON__) or (%h% == __XS_CHECKSUM__)
end

if not %verify%() then %corrupt%() end

--------------------------------------------------------------------
-- Anti-debug (opt-in, see --antidebug): a debug hook set on this
-- coroutine is a strong signal of an attached debugger/profiler --
-- normal execution never sets one itself. A tight-loop timing check
-- backs it up (single-stepping/breakpoints make trivial work take
-- implausibly long). Both are guarded so a host without `debug`/`os`
-- (common in sandboxed embeddings) just skips them, no error either way.
--------------------------------------------------------------------

-- Global access, chosen once at startup:
--  * If the real environment is writable (Lua 5.1 getfenv(0), Lua 5.3 _G,
--    Lune), globals go straight to it, so program semantics are exactly
--    the raw ones. The probe key is set and removed again.
--  * If it isn't (Lute: `_G` is read-only and doesn't track assignments),
--    writes go to a private table and reads fall back to the standard
--    builtins read live (so a host's replacement of print is seen), then
--    to the `_G` snapshot of host globals.
-- Either way the names are encrypted constants, never plaintext.
local %base% = (getfenv and getfenv(0)) or _G
local %LIVE% = { __XS_LIVE__ }
local %priv% = {}
local %NILH% = {}
local %probeKey% = tostring(%priv%)
local %writable% = pcall(function()
  %base%[%probeKey%] = true
  %base%[%probeKey%] = nil
end)
local %GETG% = function(%k%)
  if %writable% then return %base%[%k%] end
  local %pv% = %priv%[%k%]
  if %pv% ~= nil then
    if %pv% == %NILH% then return nil end
    return %pv%
  end
  local %lf% = %LIVE%[%k%]
  if %lf% then return %lf%() end
  return %base%[%k%]
end
local %SETG% = function(%k%, %v%)
  if %writable% then %base%[%k%] = %v%
  else %priv%[%k%] = (%v% == nil) and %NILH% or %v% end
end

local %dbgLib% = nil
if __XS_ANTIDEBUG__ then
  local %dok%, %dlib% = pcall(function() return debug end)
  if %dok% and %dlib% and %dlib%.gethook then %dbgLib% = %dlib% end
end

__XS_ENVGUARD__

-- Hook probe shared by the startup check and the periodic check that
-- runs inside the VM dispatch loop (see %ADCHECK% in VM_TEMPLATE).
local %adHook% = function()
  if %envTampered%() then return true end
  if not %dbgLib% then return false end
  local %hok%, %hfn% = pcall(%dbgLib%.gethook)
  return (%hok% and %hfn% ~= nil) and true or false
end

if __XS_ANTIDEBUG__ then
  if %adHook%() then %corrupt%() end
  local %ook%, %olib% = pcall(function() return os end)
  if %ook% and %olib% and %olib%.clock then
    local %t0% = %olib%.clock()
    local %junk% = 0
    for %ji% = 1, 30000 do %junk% = %junk% + %ji% end
    if (%olib%.clock() - %t0%) > 0.35 then %corrupt%() end
  end
end

-- Constants are decrypted on first use and cached, so a constant the
-- program never touches is never decrypted at all.
local %consts% = setmetatable({}, { __index = function(%ct%, %i2%)
  local %dv% = %decode%(%raw%[%i2%])
  local %tg% = %dv%:sub(1, 1)
  local %val%
  if %tg% == "N" then %val% = tonumber(%dv%:sub(2)) - %maskA% else %val% = %dv%:sub(2) end
  rawset(%ct%, %i2%, %val%)
  return %val%
end })

-- Watermark integrity: the decoded copy must gsub-match the exact
-- expected text. This can only ever fail alongside the checksum
-- failing too (both are reading the same encrypted payload) -- it's
-- not an independent detector, just one more thing that has to keep
-- adding up for execution to continue past this point.
do
  local %wmVal% = %consts%[__XS_WMIDX__]
  local %wmChecked%, %wmCount% = %wmVal%:gsub("Protected by XenonSec", "Protected by XenonSec")
  if %wmCount% ~= 1 or %wmChecked% ~= "Protected by XenonSec" then %corrupt%() end
end

]===]

local FOOTER_TEMPLATE = [===[
if not %verify%() then %corrupt%() end
return (%engine%)({ %consts%, %protos%, __XS_MAIN__, %adHook%, %GETG%, %SETG% }, ...)]===]

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
  junkRate = 0.22, -- only used if size-based auto-scaling is somehow bypassed; see obfuscate()
  decoyConstants = nil, -- nil => auto-scaled to input size, see obfuscate()
  localizeGlobals = true,
  fold = true,
  ssa = true,
  luau = false,
  antiTamper = true,   -- checksum-verified payload; zero false-positive risk, on by default
  flushConsts = true,  -- periodic flush of the decoded-constant cache (see PERIODIC)
  flushEvery = 65536,  -- steps between flushes: a dump sees only recently used constants
  antiDebug = false,   -- debug.gethook + timing checks; real false-positive risk, opt-in
  proxify = false,     -- ProxifyLocal: registers and captured locals live in proxy objects (slower)
  strength = 2,        -- 1..4: scales decoy handlers and decoy constants (size vs. clutter)
}

--------------------------------------------------------------------
-- Standard-library lookups. The generated code never names a standard
-- library function directly: every whitelisted name (setmetatable,
-- string.format, pcall, math.random, ...) is rewritten to an index into
-- a table that is filled at startup. Each name is stored as bytes offset
-- by a per-build constant, so the file has no readable `string.format`-
-- style reference left. Names are not secret; this just removes the
-- readable tells. The bootstrap names (string.byte, string.char,
-- table.concat) stay literal, because the decoder needs them first.
--------------------------------------------------------------------

local STD_BARE = {
  pairs = true, ipairs = true, next = true, select = true, type = true,
  tonumber = true, tostring = true, error = true, pcall = true, xpcall = true,
  setmetatable = true, getmetatable = true, rawget = true, rawset = true,
  rawequal = true, print = true, unpack = true, os = true, debug = true,
  string = true, table = true, math = true,
}
local STD_DOTTED = {
  ["string.format"] = true, ["string.sub"] = true, ["string.rep"] = true,
  ["string.len"] = true, ["table.remove"] = true, ["table.unpack"] = true,
  ["math.floor"] = true, ["math.max"] = true, ["math.random"] = true,
  ["os.clock"] = true, ["debug.gethook"] = true,
}

-- Rewrites standard-library references in `text` to `tabName[k]`, skipping
-- string literals, comments, field names (`x.error`, `{ error = ... }`) and
-- declarations (`local type = ...`). `list` collects the paths in order of
-- first use; `index` maps a path to its k.
local function rewriteStd(text, tabName, list, index)
  local out, i, n = {}, 1, #text
  local function prevNonSpace(pos)
    local j = pos - 1
    while j >= 1 and text:sub(j, j):match("%s") do j = j - 1 end
    return j >= 1 and text:sub(j, j) or ""
  end
  while i <= n do
    local c = text:sub(i, i)
    if text:sub(i, i + 1) == "--" then
      local eq = text:match("^%-%-%[(=*)%[", i)
      local j
      if eq then
        local _, e = text:find("]" .. eq .. "]", i, true)
        j = e or n
      else
        j = text:find("\n", i, true) or n
      end
      out[#out + 1] = text:sub(i, j); i = j + 1
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = text:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c then break
        else j = j + 1 end
      end
      out[#out + 1] = text:sub(i, j); i = j + 1
    elseif text:match("^%[=*%[", i) then
      local eq = text:match("^%[(=*)%[", i)
      local _, e = text:find("]" .. eq .. "]", i, true)
      local j = e or n
      out[#out + 1] = text:sub(i, j); i = j + 1
    elseif c:match("[%a_]") and not text:sub(i - 1, i - 1):match("[%w_]") then
      local name = text:match("^[%a_][%w_]*", i)
      local after = text:match("^%.([%a_][%w_]*)", i + #name)
      local prev = prevNonSpace(i)
      local before = text:sub(math.max(1, i - 12), i - 1)
      local isField = prev == "." or prev == ":"
      local isDecl = before:match("local%s+$") or before:match("function%s+$")
      local nextTok = text:match("^%s*(.)", i + #name)
      local isKey = nextTok == "=" and text:match("^%s*==", i + #name) == nil
      local path
      if not isField and not isDecl and not isKey then
        if after and STD_DOTTED[name .. "." .. after] then
          path = name .. "." .. after
        elseif not after and STD_BARE[name] then
          path = name
        end
      end
      if path then
        local k = index[path]
        if not k then
          list[#list + 1] = path
          k = #list
          index[path] = k
        end
        out[#out + 1] = tabName .. "[" .. k .. "]"
        i = i + #path
      else
        out[#out + 1] = name
        i = i + #name
      end
    else
      out[#out + 1] = c; i = i + 1
    end
  end
  return table.concat(out)
end

-- Builds the startup block that fills tabName from the collected paths.
-- Names are stored as (byte + salt) % 256, decoded by `dec` with the
-- header's own char/concat locals. `names` gives the local identifiers.
-- Encodes a name as a decode call in the generated code: names.dec({...}).
local function encName(names, salt, s)
  local t = {}
  for j = 1, #s do t[j] = (s:byte(j) + salt) % 256 end
  return names.dec .. "({" .. table.concat(t, ",") .. "})"
end

local function buildStdBlock(tabName, list, names, salt)
  local function enc(s)
    local t = {}
    for j = 1, #s do t[j] = (s:byte(j) + salt) % 256 end
    return "{" .. table.concat(t, ",") .. "}"
  end
  local lines = {}
  -- Root of the lookups: on Lune and some sandboxes _G is an empty table, but
  -- getfenv(0) still reaches the globals; plain Lua has no getfenv, so _G there.
  lines[#lines + 1] = string.format("local %s, %s = {}, (getfenv and getfenv(0)) or _G", tabName, names.G)
  lines[#lines + 1] = string.format(
    "local function %s(%s) local %s = {} for %s = 1, #%s do %s[%s] = %s((%s[%s] - %d) %% 256) end return %s(%s) end",
    names.dec, names.t, names.o, names.j, names.t, names.o, names.j, names.char,
    names.t, names.j, salt, names.concat, names.o)
  for k, path in ipairs(list) do
    local expr = names.G
    for part in path:gmatch("[^%.]+") do
      expr = expr .. "[" .. names.dec .. "(" .. enc(part) .. ")]"
    end
    lines[#lines + 1] = string.format("%s[%d] = %s", tabName, k, expr)
  end
  return table.concat(lines, " ")
end

local function obfuscateOnce(source, chunkname, opts)
  opts = opts or {}
  setCipherParams() -- fresh cipher constants for every build (before any encryption)
  -- A leading shebang line (`#!/usr/bin/env lute`) is skipped, the same
  -- way the standard Lua loader skips it for files. It's blanked rather
  -- than removed, so every later line keeps its original line number.
  if source:sub(1, 1) == "#" then
    source = source:gsub("^[^\n]*", "", 1)
  end
  -- Captured BEFORE the defaults fill below, so we can tell "caller
  -- explicitly asked for this" apart from "fell through to a default"
  -- -- auto-scaling (below) only kicks in for the latter.
  local explicitJunkRate = opts.junkRate
  local explicitDecoys = opts.decoyConstants
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

  -- Auto-scale hardening density to the size of the *real* program
  -- (measured before junk is injected, so the decision isn't fed by
  -- its own output). A flat rate/count tuned for an "average" script
  -- makes small scripts look thin and leaves large scripts under-
  -- hardened relative to how much real structure they have to hide
  -- noise inside -- so both ends scale instead of using one constant.
  -- An explicit --junk/--decoys value from the caller always wins.
  local totalInstr = 0
  for _, proto in ipairs(mod.protos) do totalInstr = totalInstr + #proto.code end
  local totalConsts = #mod.consts

  if explicitJunkRate == nil then
    -- Tiny scripts (few real instructions) get a much higher junk
    -- *percentage*, since a flat rate barely adds any real bulk to
    -- them; the rate settles toward a lower floor as the program's
    -- own size grows and starts pulling its own weight.
    local scaled = 0.55 - (totalInstr / 500)
    if scaled < 0.20 then scaled = 0.20 end
    if scaled > 0.55 then scaled = 0.55 end
    opts.junkRate = scaled
  end

  if explicitDecoys == nil then
    -- Grows with both the real constant pool and the real instruction
    -- count, plus a floor so even a near-empty script still ships a
    -- meaningful amount of decoy noise, and a cap so a huge input
    -- doesn't blow the decoy pool up past the point of diminishing
    -- returns.
    local scaled = math.floor(totalConsts * 1.5 + totalInstr / 8) + 16 + math.random(0, 24)
    scaled = scaled * (opts.strength or 1)
    if scaled > 500 * (opts.strength or 1) then scaled = 500 * (opts.strength or 1) end
    opts.decoyConstants = scaled
  end

  if opts.junkRate and opts.junkRate > 0 then Junk.inject(mod, opts.junkRate) end
  if opts.flatten ~= false then Passes.flatten(mod, math.random, opts.strength or 1) end
  local bundle = buildBundle(mod, opts)

  local vmSrc = opts.minify and minifyTemplateText(VM_TEMPLATE) or VM_TEMPLATE
  -- ProxifyLocal register map: i -> (i*PA + PB) % PM. PA is odd, so the map is
  -- a bijection on [0, PM). Chosen per build.
  local PROXY_M = 1048576
  local proxyA = 2 * math.random(0, 524287) + 1
  local proxyB = math.random(0, PROXY_M - 1)
  local engineSrc = renderTemplate(vmSrc, bundle.OPNUM, bundle.BINNUM, bundle.UNNUM, totalInstr, opts.antiDebug,
    { M1 = bundle.saltM1, M2 = bundle.saltM2, MOD = bundle.mod, strength = opts.strength or 1,
      proxify = opts.proxify and true or false, PA = proxyA, PB = proxyB, PM = PROXY_M,
      freeKey = bundle.freeKey, decoyCount = bundle.decoyCount,
      flush = opts.flushConsts and true or false, flushEvery = opts.flushEvery or 65536 })

  local keyLit = "{" .. table.concat(bundle.key, ",") .. "}"
  local cipherLits = {}
  for i, c in ipairs(bundle.cipherConsts) do
    -- %q leaves bytes >= 128 raw, which makes the file invalid UTF-8.
    -- Escape them as 3-digit decimal escapes so the output is pure ASCII
    -- (valid Lua 5.1 / 5.3 / Luau, and accepted by strict UTF-8 hosts).
    cipherLits[i] = string.format("%q", c):gsub("[\128-\255]", function(ch)
      return string.format("\\%03d", ch:byte())
    end)
  end
  local ciphersLit = table.concat(cipherLits, ",")

  -- Env-logger check: one direct read per builtin name (see the header).
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
  -- Standard-library references: rewrite to indexes into one table that
  -- the header fills at startup (see rewriteStd / buildStdBlock).
  local stdTab = resolveShared("stdtab")
  local stdList, stdIndex = {}, {}
  local stdSalt = math.random(1, 200)
  local stdNames = {
    G = resolveShared("stdG"), dec = resolveShared("stdDec"), t = resolveShared("stdT"),
    o = resolveShared("stdO"), j = resolveShared("stdJ"),
    char = resolveShared("char"), concat = resolveShared("concat"),
    base = resolveShared("base"),
  }
  header = rewriteStd(header, stdTab, stdList, stdIndex)
  header = header:gsub("__XS_KEY__", keyLit)
  header = header:gsub("__XS_SB__", tostring(CIPHER.basis))
  header = header:gsub("__XS_LM__", tostring(CIPHER.mult))
  header = header:gsub("__XS_LA__", tostring(CIPHER.add))
  header = header:gsub("__XS_RM__", tostring(CIPHER.rcMult))
  header = header:gsub("__XS_MASKA__", tostring(bundle.maskA))
  header = header:gsub("__XS_CIPHERS__", (ciphersLit:gsub("%%", "%%%%")))
  header = header:gsub("__XS_PROTOS__", (protosLit:gsub("%%", "%%%%")))
  header = header:gsub("__XS_CHECKSUM__", tostring(bundle.checksum))
  header = header:gsub("__XS_ANTITAMPER_ON__", tostring(opts.antiTamper))
  header = header:gsub("__XS_ANTIDEBUG__", tostring(opts.antiDebug))
  header = header:gsub("__XS_WMIDX__", tostring(bundle.watermarkIdx))
  -- Built here, after resolveShared exists, so the corrupt() helper is
  -- emitted under its renamed identifier like everything else in the header.
  -- Live getters for the standard builtins (see %LIVE% in the header).
  -- Live getter keys are encoded. The values stay bare global reads: only a
  -- bare identifier sees a global assigned by name on every runtime (on Lute
  -- _G does not reflect those), so the getter must read the name directly.
  header = header:gsub("__XS_LIVE__", function()
    local parts, seen = {}, {}
    local function add(name)
      if seen[name] then return end
      seen[name] = true
      parts[#parts + 1] = string.format("[%s] = function() return %s end",
        encName(stdNames, stdSalt, name), name)
    end
    for _, name in ipairs(ENV_CHECK_NAMES) do add(name) end
    if opts.antiDebug then add("debug") end
    for _, name in ipairs(bundle.liveNames) do add(name) end
    return table.concat(parts, ", ")
  end)
  -- Env-logger guard (see the header). Bare reads on purpose: they see the
  -- live globals, so a logger installed before the protected code is caught.
  -- The builtin names therefore stay readable in the output.
  --  * startup: each builtin must be a real function, and a C function. A
  --    logger that wraps one in a Lua closure is caught here, by debug info.
  --  * periodic (via adHook, every 2048 instructions): the builtin must still
  --    be the very value captured at startup, and the raw _G entry must match
  --    the bare read. This catches a logger installed after startup.
  -- The periodic part is identity-only so it stays cheap.
  header = header:gsub("__XS_ENVGUARD__", function()
    local envTampered = resolveShared("envTampered")
    if not opts.antiDebug then
      return "local " .. envTampered .. " = function() return false end"
    end
    local corrupt = resolveShared("corrupt")
    local getg = resolveShared("GETG")
    local pc, ty = resolveShared("pc"), resolveShared("ty")
    local egi, edi = resolveShared("egi"), resolveShared("edi")
    local gok, gd = resolveShared("gok"), resolveShared("gd")
    local isLua, ef = resolveShared("isLua"), resolveShared("ef")
    local iok, inf = resolveShared("iok"), resolveShared("inf")
    local sok, src = resolveShared("sok"), resolveShared("src")
    local keys, snapv = resolveShared("envKeys"), resolveShared("envSnap")
    local ii, vv = resolveShared("ei"), resolveShared("ev")
    -- Every name the guard touches is an encoded lookup (see encName): the
    -- source never contains a plain builtin name. The decoded strings only
    -- exist in memory, in the KEYS table, at runtime.
    local out = {}
    local function emit(s) out[#out + 1] = s end
    emit(string.format("local %s, %s = %s(%s), %s(%s)", pc, ty,
      getg, encName(stdNames, stdSalt, "pcall"), getg, encName(stdNames, stdSalt, "type")))
    emit(string.format("local %s, %s = nil, nil", egi, edi))
    emit("do")
    emit(string.format("  local %s, %s = %s(function() return %s(%s) end)", gok, gd, pc,
      getg, encName(stdNames, stdSalt, "debug")))
    emit(string.format("  if %s and %s then %s = %s[%s]; %s = %s[%s] end", gok, gd,
      egi, gd, encName(stdNames, stdSalt, "getinfo"), edi, gd, encName(stdNames, stdSalt, "info")))
    emit("end")
    emit(string.format("local %s = function(%s)", isLua, ef))
    emit(string.format("  if %s then", egi))
    emit(string.format('    local %s, %s = %s(%s, %s, "S")', iok, inf, pc, egi, ef))
    emit(string.format('    if %s and %s and %s.what then return %s.what ~= "C" end', iok, inf, inf, inf))
    emit("  end")
    emit(string.format("  if %s then", edi))
    emit(string.format('    local %s, %s = %s(%s, %s, "s")', sok, src, pc, edi, ef))
    emit(string.format('    if %s and %s then return %s ~= "[C]" end', sok, src, src))
    emit("  end")
    emit("  return false")
    emit("end")
    local keyParts = {}
    for _, name in ipairs(ENV_CHECK_NAMES) do
      keyParts[#keyParts + 1] = encName(stdNames, stdSalt, name)
    end
    emit(string.format("local %s = { %s }", keys, table.concat(keyParts, ", ")))
    emit(string.format("local %s = {}", snapv))
    emit(string.format("for %s = 1, #%s do %s[%s] = %s(%s[%s]) end", ii, keys, snapv, ii, getg, keys, ii))
    emit(string.format("for %s = 1, #%s do", ii, keys))
    emit(string.format('  local %s = %s[%s]', vv, snapv, ii))
    emit(string.format('  if %s(%s) ~= "function" or %s(%s) then %s() end', ty, vv, isLua, vv, corrupt))
    emit("end")
    emit(string.format("local %s = function()", envTampered))
    emit(string.format("  for %s = 1, #%s do", ii, keys))
    emit(string.format("    if %s(%s[%s]) ~= %s[%s] then return true end", getg, keys, ii, snapv, ii))
    emit("  end")
    emit("  return false")
    emit("end")
    return table.concat(out, "\n")
  end)

  local footer = substitute(footerTpl, function(tok)
    if tok == "engine" then return "(function()\n" .. engineSrc .. "\nend)()" end
    return resolveShared(tok)
  end)
  footer = rewriteStd(footer, stdTab, stdList, stdIndex)
  header = header:gsub("__XS_STD__", function()
    if #stdList == 0 then return "" end
    return buildStdBlock(stdTab, stdList, stdNames, stdSalt)
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

-- Public entry point. Builds the protected file and, if the result is smaller
-- than opts.minSize (default 100000 bytes), rebuilds with a bigger `strength`
-- (decoy handler and dead-block multiplier) until it is. Pass minSize = false
-- to disable. Padding is dead code: it makes a single paste too large for a
-- one-shot read, and adds no secrecy to the logic itself.
local function obfuscate(source, chunkname, opts)
  opts = opts or {}
  local target = opts.minSize
  if target == nil then target = 100000 end
  if target == false then target = 0 end
  local strength = opts.strength or 1
  local out
  -- Output size is noisy from one build to the next (decoy counts are
  -- random), so aim 10% over the target and allow a dozen attempts.
  for _ = 1, 12 do
    local attempt = {}
    for k, v in pairs(opts) do attempt[k] = v end
    attempt.strength = strength
    out = obfuscateOnce(source, chunkname, attempt)
    if #out >= target then break end
    strength = strength * math.max(1.25, 1.1 * target / #out)
  end
  return out
end

return { obfuscate = obfuscate }
