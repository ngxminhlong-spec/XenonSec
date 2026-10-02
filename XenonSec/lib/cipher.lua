--------------------------------------------------------------------
-- XenonSec :: lib/cipher.lua
-- Encryption layer: RC4 + Diffuse + CFB + SPN (4-layer construction)
--------------------------------------------------------------------

local Cipher = {}

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
-- RC4 Key Scheduling + Stream Cipher
--------------------------------------------------------------------

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

function Cipher.rc4Crypt(data, key)
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

--------------------------------------------------------------------
-- LCG-based Diffusion Layer
--------------------------------------------------------------------

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

function Cipher.diffuseEncrypt(data, key)
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

function Cipher.diffuseDecrypt(data, key)
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

--------------------------------------------------------------------
-- CFB Chaining Mode
--------------------------------------------------------------------

local function deriveIV(key)
  local iv = 0
  for i = 1, #key do iv = byteXor(iv, key[i]) end
  return iv
end

function Cipher.cfbChain(data, iv)
  local out, prev = {}, iv
  for i = 1, #data do
    local c = byteXor(data:byte(i), prev)
    out[i] = string.char(c)
    prev = c
  end
  return table.concat(out)
end

function Cipher.cfbUnchain(data, iv)
  local out, prev = {}, iv
  for i = 1, #data do
    local c = data:byte(i)
    out[i] = string.char(byteXor(c, prev))
    prev = c
  end
  return table.concat(out)
end

--------------------------------------------------------------------
-- SPN Layer: S-box Substitution + Block Permutation
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

function Cipher.spnEncrypt(data, key)
  local box = deriveSbox(key)
  local subbed = {}
  for i = 1, #data do subbed[i] = string.char(box[data:byte(i)]) end
  return blockPermute(table.concat(subbed), deriveBlockOrder(key))
end

function Cipher.spnDecrypt(data, key)
  local unpermuted = blockPermute(data, invertOrder(deriveBlockOrder(key)))
  local invBox = invertSbox(deriveSbox(key))
  local out = {}
  for i = 1, #unpermuted do out[i] = string.char(invBox[unpermuted:byte(i)]) end
  return table.concat(out)
end

--------------------------------------------------------------------
-- Public API: 4-layer composite cipher
--------------------------------------------------------------------

function Cipher.encrypt(plaintext, key)
  local a = Cipher.rc4Crypt(plaintext, key)
  local b = Cipher.diffuseEncrypt(a, key)
  local c = Cipher.cfbChain(b, deriveIV(key))
  local d = Cipher.spnEncrypt(c, key)
  return d
end

function Cipher.decrypt(ciphertext, key)
  local c = Cipher.spnDecrypt(ciphertext, key)
  local b = Cipher.cfbUnchain(c, deriveIV(key))
  local a = Cipher.diffuseDecrypt(b, key)
  local plaintext = Cipher.rc4Crypt(a, key)
  return plaintext
end

return Cipher
