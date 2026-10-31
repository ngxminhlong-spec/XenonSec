--------------------------------------------------------------------
-- XenonSec :: obfuscator/util.lua
-- Shared build-time helpers: randomized identifiers, shuffles, random byte keys, a Lua-5.1-safe XOR, %name% template substitution, and template minification.
--------------------------------------------------------------------

--------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------

-- Generated names use only letters and digits, never underscores, and
-- always start with a letter. Mixed case and digits keep them from reading
-- as words.
local ALPHABET = "qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM0123456789"
local FIRST = "qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM"
local function randomIdent(len)
  len = len or (6 + math.random(0, 5))
  local chars = {}
  local f = math.random(1, #FIRST)
  chars[1] = FIRST:sub(f, f)
  for i = 2, len do
    local idx = math.random(1, #ALPHABET)
    chars[i] = ALPHABET:sub(idx, idx)
  end
  return table.concat(chars)
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

-- Generic %name% substitution. `resolve(tok)` returns the replacement
-- string for a placeholder token, or nil to leave it as an error.
local function substitute(template, resolve)
  return (template:gsub("%%([%a_][%w_]*)%%", function(tok)
    local v = resolve(tok)
    assert(v ~= nil, "unresolved template placeholder %" .. tok .. "%")
    return v
  end))
end

--------------------------------------------------------------------

local minifyMod = dofile((debug.getinfo(1, "S").source:match("@?(.*/)") or "./") .. "minify.lua")

-- Token-aware template minifier (see minify.lua). Integer literals of 1000 or
-- more are masked as arithmetic with a fresh per-call key.
local function minifyTemplateText(text)
  return minifyMod.minify(text, true)
end

return {
  byteXor = byteXor,
  minifyTemplateText = minifyTemplateText,
  randomByteKey = randomByteKey,
  randomIdent = randomIdent,
  shuffledRange = shuffledRange,
  substitute = substitute,
}
