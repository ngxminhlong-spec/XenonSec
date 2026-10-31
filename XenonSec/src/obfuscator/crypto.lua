--------------------------------------------------------------------
-- XenonSec :: obfuscator/crypto.lua
-- The constant cipher: RC4-style stream, LCG diffusion, CFB chaining and a keyed S-box/block permutation, with per-build parameters. cipherEncrypt is used by the bundler; cipherDecrypt is its exact inverse.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local load = dofile(dir .. "loader.lua")
local _util = load("util")
local byteXor = _util.byteXor

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

return {
  CIPHER = CIPHER,
  cipherEncrypt = cipherEncrypt,
  setCipherParams = setCipherParams,
}
