--------------------------------------------------------------------
-- XenonSec :: obfuscator/util.lua
-- Shared build-time helpers: randomized identifiers, shuffles, random byte keys, a Lua-5.1-safe XOR, %name% template substitution, and template minification.
--------------------------------------------------------------------

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

return {
  byteXor = byteXor,
  minifyTemplateText = minifyTemplateText,
  randomByteKey = randomByteKey,
  randomIdent = randomIdent,
  shuffledRange = shuffledRange,
  substitute = substitute,
}
