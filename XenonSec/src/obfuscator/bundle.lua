--------------------------------------------------------------------
-- XenonSec :: obfuscator/bundle.lua
-- Turns a compiled module into the encrypted, randomized payload that the header and engine templates consume: constant pool encryption, opcode and operator renumbering, key vault, field masks and checksums.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local load = dofile(dir .. "loader.lua")
local _crypto = load("crypto")
local cipherEncrypt = _crypto.cipherEncrypt
local CIPHER = _crypto.CIPHER
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

-- Anti-debug names live in the encrypted constant pool, never as plaintext.
local ANTI_NAMES = { "debug", "gethook", "getinfo", "coroutine", "running" }

local function xor8(x, y)
  local r, bit = 0, 1
  for _ = 1, 8 do
    if x % 2 ~= y % 2 then r = r + bit end
    x = math.floor(x / 2); y = math.floor(y / 2); bit = bit * 2
  end
  return r
end

-- Key vault. Each key byte becomes three XOR shares; each share is stored at
-- a shuffled position in one masked table, with decoy bytes filling the rest.
-- Position k holds (share + pad(k)) mod 256 where pad(k) = (k*sm1 + sm2) mod 256.
local function buildVault(key)
  local n = #key
  local sm1, sm2 = math.random(2, 250), math.random(0, 255)
  local size = 3 * n + math.max(16, n)
  local perm = shuffledRange(size)
  local vault = {}
  for p = 1, size do vault[p] = math.random(0, 255) end
  local kmap = {}
  local function pad(p) return (p * sm1 + sm2) % 256 end
  for i = 1, n do
    local a = math.random(0, 255)
    local b = math.random(0, 255)
    local c = xor8(xor8(key[i], a), b)
    local shares = { a, b, c }
    for j = 1, 3 do
      local pos = perm[(j - 1) * n + i]
      kmap[(j - 1) * n + i] = pos
      vault[pos] = (shares[j] + pad(pos)) % 256
    end
  end
  local vsum = 0
  for p = 1, size do vsum = (vsum + vault[p] * (p % 7 + 1)) % 2147483647 end
  return { vault = vault, kmap = kmap, sm1 = sm1, sm2 = sm2, vsum = vsum }
end

-- Keyed finalizer, mirroring %fin% in the header. The checksum is folded
-- through the key, so it only matches while the key itself is intact.
local function keyedFinal(h, k)
  local a, b = 1, 0
  for i = 1, #k do
    a = (a * 131 + k[i] * 17 + i) % 1048573
    b = (b * 29 + k[i] * (i + 3)) % 2147483647
  end
  return (h * (a + 1) + b) % 2147483647
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
  local antiPre = {}
  if opts.antiDebug then
    for _, nm in ipairs(ANTI_NAMES) do antiPre[nm] = addConst(mod, nm) end
  end
  -- The handler self-test needs a constant 3 to drive the BINK check.
  local threePre = addConst(mod, 3)

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
  local antiIdx = {}
  for nm, idx in pairs(antiPre) do antiIdx[nm] = perm[idx] end
  local threeIdx = perm[threePre]


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
  -- Equivalent opcodes: each opcode gets one or two extra keys, all mapped to
  -- its handler at runtime. Each instruction is encoded with one of its keys
  -- picked at random, so one opcode shows up under several numbers.
  local aliasCount, aliasTotal = {}, 0
  for _, name in ipairs(OPCODES) do
    aliasCount[name] = math.random(1, 2)
    aliasTotal = aliasTotal + aliasCount[name]
  end
  local pool = shuffledRange(realCount + decoyCount + aliasTotal)
  local poolNext = 0
  local function freeKey()
    poolNext = poolNext + 1
    assert(poolNext <= #pool, "XenonSec: handler key pool exhausted")
    return pool[poolNext]
  end
  local OPNUM, opGroups = {}, {}
  for _, name in ipairs(OPCODES) do
    OPNUM[name] = freeKey()
    local group = { OPNUM[name] }
    for _ = 1, aliasCount[name] do group[#group + 1] = freeKey() end
    opGroups[name] = group
  end
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
  -- Per-build tag bytes for the constant type marks (N = number, S = string).
  local tagPerm = shuffledRange(255)
  local tagN, tagS = tagPerm[1], tagPerm[2]
  local tagF, tagZ, tagNaN = tagPerm[3], tagPerm[4], tagPerm[5]
  local vaultData = buildVault(key)
  local cipherConsts = {}
  -- Number encoding is lossless. tostring() keeps only 14 digits and drops the
  -- sign of -0.0, so:
  --   tagN: integer, stored as (v + maskA) with %.17g, decoded back by - maskA
  --   tagF: float, %.17g (17 digits round-trip a double); integral forms get ".0"
  --         so Lua 5.3 keeps them as floats
  --   tagZ: -0.0      tagNaN: nan      (inf is tagF as 1e999 / -1e999)
  local function formatFloat(x)
    if x == math.huge then return "1e999" end
    if x == -math.huge then return "-1e999" end
    local s = string.format("%.17g", x)
    if not s:find("[%.eE]") then s = s .. ".0" end
    return s
  end
  local function isInteger(x)
    if math.type then return math.type(x) == "integer" end
    return x == math.floor(x) and x > -2^53 and x < 2^53
  end
  for i, v in ipairs(shuffledConsts) do
    local tagged
    if type(v) == "number" then
      if v ~= v then
        tagged = string.char(tagNaN)
      elseif v == 0 and 1 / v < 0 then
        tagged = string.char(tagZ)
      elseif math.type and isInteger(v) and v > -2^62 and v < 2^62 then
        -- Lua 5.3: format the masked integer exactly. %.17g would convert it
        -- through a double and round values near 2^53.
        tagged = string.char(tagN) .. string.format("%d", v + maskA)
      elseif isInteger(v) and v > -2^52 and v < 2^52 then
        -- Lua 5.1 (no integer subtype): every number is a double, and the
        -- masked sum stays exact in this range.
        tagged = string.char(tagN) .. string.format("%.17g", v + maskA)
      else
        tagged = string.char(tagF) .. formatFloat(v)
      end
    else
      tagged = string.char(tagS) .. v
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
  -- Decode state: each field's mask also depends on a running state value.
  -- The state advances from every instruction's opcode and is reset by jumps
  -- and returns. The runtime dispatcher mirrors these constants exactly.
  local saltM3 = math.random(2, MOD - 2)
  local stepA = math.random(2, MOD - 2)
  local stepB = math.random(2, MOD - 2)
  local stepC = math.random(0, MOD - 1)
  -- The mask for one field depends on that instruction's own random seed
  -- and the field's slot (1 = opcode, 2..4 = operands). There is no
  -- position-only pattern to recover.
  local function fieldMask(seed, slot, st)
    return (seed * saltM1 + slot * saltM2 + st * saltM3) % MOD
  end
  local function encodeField(v, seed, slot, st)
    assert(type(v) == "number" and v >= 0 and v < MOD and v == math.floor(v),
      "XenonSec: instruction field out of encodable range: " .. tostring(v))
    return (v + fieldMask(seed, slot, st)) % MOD
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

  -- Per-proto encryption. Each proto's instructions are packed into 15 bytes
  -- (five 3-byte fields: masked opcode, a, b, c, seed). The packed bytes are
  -- encrypted with a key derived from the build key and the proto's own
  -- nonce, and the proto stores only that ciphertext. The engine decrypts a
  -- proto the first time it is called (%dproto% in the header), so protos
  -- that never run are never decrypted.
  local function deriveProtoKey(nonce)
    local s = (CIPHER.basis + nonce) % 16777216
    local out = {}
    for i = 1, #key do
      s = (s * CIPHER.mult + CIPHER.add) % 16777216
      out[i] = xor8(key[i], math.floor(s / 65536) % 256)
    end
    return out
  end

  local function packInstr(eop, ea, eb, ec, seed)
    local parts = {}
    for _, v in ipairs({ eop, ea, eb, ec, seed }) do
      parts[#parts + 1] = string.char(math.floor(v / 65536) % 256,
                                      math.floor(v / 256) % 256, v % 256)
    end
    return table.concat(parts)
  end

  -- Lua string literal with bytes >= 128 written as decimal escapes, so the
  -- output stays pure ASCII.
  local function luaBytes(str)
    return (string.format("%q", str):gsub("[\128-\255]", function(ch)
      return string.format("\\%03d", ch:byte())
    end))
  end

  -- Opcodes after which the decode state resets to 0 (mirrors Passes.STATE_RESET).
  local STATE_RESET = { JMP = true, JF = true, JT = true, JNIL = true, RET = true, RETM = true }
  local protoLits = {}
  for _, proto in ipairs(mod.protos) do
    local nonce = math.random(1, MOD - 1)
    local hasV = proto.hasVararg and 1 or 0
    checksum = mixChecksum(checksum, hasV)
    local psum = mixChecksum(5381, hasV)

    local plain = {}
    local ih = 5381
    local cur = 0 -- decode state seen by the next instruction
    for _, instr in ipairs(proto.code) do
      local seed = math.random(0, MOD - 1)
      local group = opGroups[instr.op]
      local opn = group[math.random(1, #group)]
      local a = instr.a or 0
      local b = instr.b or 0
      local c = instr.c or 0
      local eop, ea = encodeField(opn, seed, 1, cur), encodeField(a, seed, 2, cur)
      local eb, ec = encodeField(b, seed, 3, cur), encodeField(c, seed, 4, cur)
      plain[#plain + 1] = packInstr(eop, ea, eb, ec, seed)
      -- Same order the runtime hashes decoded tuples: seed, op, a, b, c.
      ih = mixChecksum(ih, seed); ih = mixChecksum(ih, eop); ih = mixChecksum(ih, ea)
      ih = mixChecksum(ih, eb); ih = mixChecksum(ih, ec)
      if STATE_RESET[instr.op] then cur = 0 else cur = (cur * stepA + opn * stepB + stepC) % MOD end
    end
    local blob = cipherEncrypt(table.concat(plain), deriveProtoKey(nonce))

    -- Integrity: the nonce and every ciphertext byte are covered, in the same
    -- order the runtime's %verify% and %vp% use.
    checksum = mixChecksum(checksum, nonce)
    psum = mixChecksum(psum, nonce)
    for i = 1, #blob do
      local bv = blob:byte(i)
      checksum = mixChecksum(checksum, bv)
      psum = mixChecksum(psum, bv)
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
      "{p={%s},v=%s,k=%d,n=%d,i=%d,b=%s}",
      table.concat(paramParts, ","),
      proto.hasVararg and "true" or "false",
      psum, nonce, ih, luaBytes(blob)
    )
  end
  checksum = keyedFinal(checksum, key)

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
    opGroups = opGroups,
    BINNUM = BINNUM,
    UNNUM = UNNUM,
    freeKey = freeKey,
    decoyCount = decoyCount,
    checksum = checksum,
    watermarkIdx = watermarkIdx,
    vault = vaultData.vault,
    kmap = vaultData.kmap,
    sm1 = vaultData.sm1,
    sm2 = vaultData.sm2,
    vsum = vaultData.vsum,
    tagN = tagN, tagF = tagF, tagZ = tagZ, tagNaN = tagNaN,
    tagS = tagS,
    antiIdx = antiIdx,
    saltM3 = saltM3, stepA = stepA, stepB = stepB, stepC = stepC,
    threeIdx = threeIdx,
  }
end

return {
  ENV_CHECK_NAMES = ENV_CHECK_NAMES,
  buildBundle = buildBundle,
}
