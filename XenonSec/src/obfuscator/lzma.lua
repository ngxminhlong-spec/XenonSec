-- LZMA-style compressor for proto records.
--
-- A range coder with adaptive binary probabilities (11-bit, shift 5) codes a
-- stream of literals and matches, using the same model shape as LZMA: a
-- state machine, a length coder (choice bits plus low/mid/high bit trees), and
-- a distance coder (6-bit slot tree per length state, direct footer bits).
-- It is LZMA-style, not the .lzma/.xz format: only the arithmetic and the
-- model have to match between this encoder and the runtime decoder in the
-- header. Matches are at least 3 bytes and reach back 65536 bytes.
--
-- Arithmetic only (no bit operations), so the decoder runs on Lua 5.1, 5.3 and
-- Luau. Every value stays below 2^53, so doubles hold it exactly.
--
-- Format: 4-byte big-endian raw length, then the range-coder stream.

local Lzma = {}

local K_TOP = 16777216        -- 2^24
local K_PROB_INIT = 1024      -- 2^10, probability one half
local K_MAX_MATCH = 273
local K_MIN_MATCH = 3
local K_WINDOW = 65536
local K_CHAIN = 32            -- candidates examined per position

local floor = math.floor

-- Probability adaptation divisor (2^shift). Chosen per build by the caller;
-- the decoder template must use the same value.
local ADAPT = 32

-- Probability models ------------------------------------------------------

local function newModel()
  local function probs(n)
    local t = {}
    for i = 1, n do t[i] = K_PROB_INIT end
    return t
  end
  return {
    isMatch = probs(12),
    lit = probs(256),
    lenChoice = probs(2),
    lenLow = probs(8 * 2),       -- 3-bit tree per position group
    lenMid = probs(8 * 2),
    lenHigh = probs(256),
    posSlot = { probs(64), probs(64), probs(64), probs(64) },
  }
end

-- Range encoder ------------------------------------------------------------

local function newEncoder()
  return { low = 0, range = 4294967295, cache = 0, cacheSize = 1, out = {} }
end

local function shiftLow(rc)
  local low = rc.low
  if low < 4278190080 or low >= 4294967296 then   -- below 0xFF000000 or carry
    local carry = (low >= 4294967296) and 1 or 0
    local temp = rc.cache
    repeat
      rc.out[#rc.out + 1] = (temp + carry) % 256
      temp = 255
      rc.cacheSize = rc.cacheSize - 1
    until rc.cacheSize == 0
    rc.cache = floor(low / K_TOP) % 256
  end
  rc.cacheSize = rc.cacheSize + 1
  rc.low = (low % K_TOP) * 256
end

local function normalize(rc)
  while rc.range < K_TOP do
    rc.range = rc.range * 256
    shiftLow(rc)
  end
end

local function encBit(rc, probs, idx, bit)
  local p = probs[idx]
  local bound = floor(rc.range / 2048) * p
  if bit == 0 then
    rc.range = bound
    probs[idx] = p + floor((2048 - p) / ADAPT)
  else
    rc.low = rc.low + bound
    rc.range = rc.range - bound
    probs[idx] = p - floor(p / ADAPT)
  end
  normalize(rc)
end

local function encDirect(rc, value, nbits)
  for i = nbits - 1, 0, -1 do
    rc.range = floor(rc.range / 2)
    if floor(value / 2 ^ i) % 2 == 1 then rc.low = rc.low + rc.range end
    normalize(rc)
  end
end

local function encTree(rc, probs, base, value, nbits)
  local m = 1
  for i = nbits - 1, 0, -1 do
    local bit = floor(value / 2 ^ i) % 2
    encBit(rc, probs, base + m, bit)
    m = m * 2 + bit
  end
end

local function encFlush(rc)
  for _ = 1, 5 do shiftLow(rc) end
end

-- Symbol coders (shared shape with the decoder) ------------------------------

local function encLength(rc, m, len)          -- len in 2..273
  local l = len - 2
  if l < 8 then
    encBit(rc, m.lenChoice, 1, 0)
    encTree(rc, m.lenLow, 0, l, 3)
  elseif l < 16 then
    encBit(rc, m.lenChoice, 1, 1)
    encBit(rc, m.lenChoice, 2, 0)
    encTree(rc, m.lenMid, 0, l - 8, 3)
  else
    encBit(rc, m.lenChoice, 1, 1)
    encBit(rc, m.lenChoice, 2, 1)
    encTree(rc, m.lenHigh, 0, l - 16, 8)
  end
end

local function encDistance(rc, m, lenState, d)   -- d = distance - 1
  local slot
  if d < 4 then
    slot = d
  else
    local n = 0
    while floor(d / 2 ^ (n + 1)) > 0 do n = n + 1 end
    slot = 2 * n + floor(d / 2 ^ (n - 1)) % 2
  end
  encTree(rc, m.posSlot[lenState + 1], 0, slot, 6)
  if slot >= 4 then
    local nd = floor(slot / 2) - 1
    local base = (2 + slot % 2) * 2 ^ nd
    encDirect(rc, d - base, nd)
  end
end

local function nextState(state, isMatch)
  if isMatch then return state < 7 and 7 or 10 end
  if state < 4 then return 0 end
  if state < 10 then return state - 3 end
  return state - 6
end

-- Compressor ----------------------------------------------------------------

function Lzma.compress(s, adapt)
  ADAPT = adapt or 32
  local n = #s
  local rc = newEncoder()
  local m = newModel()
  local heads = {}            -- 3-byte key -> list of positions (ascending)

  local function insert(p)
    if p + 2 > n then return end
    local key = s:sub(p, p + 2)
    local list = heads[key]
    if not list then list = {}; heads[key] = list end
    list[#list + 1] = p
  end

  local pos, state = 1, 0
  while pos <= n do
    local bestLen, bestDist = 0, 0
    if pos + 2 <= n then
      local list = heads[s:sub(pos, pos + 2)]
      if list then
        local maxLen = math.min(K_MAX_MATCH, n - pos + 1)
        for k = #list, math.max(1, #list - K_CHAIN + 1), -1 do
          local cand = list[k]
          local dist = pos - cand
          if dist > K_WINDOW then break end
          local l = 0
          while l < maxLen and s:byte(cand + l) == s:byte(pos + l) do l = l + 1 end
          if l > bestLen then bestLen, bestDist = l, dist end
        end
      end
    end

    if bestLen >= K_MIN_MATCH then
      encBit(rc, m.isMatch, state + 1, 1)
      encLength(rc, m, bestLen)
      encDistance(rc, m, math.min(bestLen - 2, 3), bestDist - 1)
      for p = pos, pos + bestLen - 1 do insert(p) end
      pos = pos + bestLen
      state = nextState(state, true)
    else
      encBit(rc, m.isMatch, state + 1, 0)
      encTree(rc, m.lit, 0, s:byte(pos), 8)
      insert(pos)
      pos = pos + 1
      state = nextState(state, false)
    end
  end
  encFlush(rc)

  local header = string.char(floor(n / 16777216) % 256, floor(n / 65536) % 256,
                             floor(n / 256) % 256, n % 256)
  local body = {}
  for i, b in ipairs(rc.out) do body[i] = string.char(b) end
  return header .. table.concat(body)
end

-- Decompressor (reference for the runtime decoder in the header) -----------

function Lzma.decompress(z, adapt)
  ADAPT = adapt or 32
  local n = z:byte(1) * 16777216 + z:byte(2) * 65536 + z:byte(3) * 256 + z:byte(4)
  local p = 5
  local function nextByte()
    local b = z:byte(p) or 0
    p = p + 1
    return b
  end
  local code, range = 0, 4294967295
  for _ = 1, 5 do code = code * 256 + nextByte() end

  local function normalize()
    while range < K_TOP do
      range = range * 256
      code = code * 256 + nextByte()
    end
  end
  local function decBit(probs, idx)
    local pr = probs[idx]
    local bound = floor(range / 2048) * pr
    local bit
    if code < bound then
      range = bound
      probs[idx] = pr + floor((2048 - pr) / ADAPT)
      bit = 0
    else
      code = code - bound
      range = range - bound
      probs[idx] = pr - floor(pr / ADAPT)
      bit = 1
    end
    normalize()
    return bit
  end
  local function decDirect(nbits)
    local v = 0
    for _ = 1, nbits do
      range = floor(range / 2)
      local bit = 0
      if code >= range then code = code - range; bit = 1 end
      v = v * 2 + bit
      normalize()
    end
    return v
  end
  local function decTree(probs, base, nbits)
    local mm = 1
    for _ = 1, nbits do mm = mm * 2 + decBit(probs, base + mm) end
    return mm - 2 ^ nbits
  end

  local m = newModel()
  local out, count, state = {}, 0, 0
  while count < n do
    if decBit(m.isMatch, state + 1) == 0 then
      local byte = decTree(m.lit, 0, 8)
      count = count + 1
      out[count] = byte
      state = nextState(state, false)
    else
      local len
      if decBit(m.lenChoice, 1) == 0 then
        len = decTree(m.lenLow, 0, 3) + 2
      elseif decBit(m.lenChoice, 2) == 0 then
        len = decTree(m.lenMid, 0, 3) + 10
      else
        len = decTree(m.lenHigh, 0, 8) + 18
      end
      local lenState = math.min(len - 2, 3)
      local slot = decTree(m.posSlot[lenState + 1], 0, 6)
      local d
      if slot < 4 then
        d = slot
      else
        local nd = floor(slot / 2) - 1
        d = (2 + slot % 2) * 2 ^ nd + decDirect(nd)
      end
      local dist = d + 1
      for _ = 1, len do
        count = count + 1
        out[count] = out[count - dist]
      end
      state = nextState(state, true)
    end
  end
  local chars = {}
  for i = 1, count do chars[i] = string.char(out[i]) end
  return table.concat(chars)
end

return Lzma
