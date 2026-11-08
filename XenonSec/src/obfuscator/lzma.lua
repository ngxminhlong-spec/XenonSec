-- Pure-Lua LZMA1 encoder used at build time (the runtime decoder lives in
-- templates/header.lua as %lzd%). Output is a standard LZMA1 raw stream with
-- lc=3, lp=0, pb=2 and no end marker: the caller stores the raw length.
--
-- Parsing is greedy with a hash chain. Only literals and simple matches are
-- emitted; the decoder also handles rep matches, which real encoders use.
-- Arithmetic only (no bit operations), so it runs on Lua 5.1 - 5.4.
--
-- Probability layout (shared with %lzd% in the header; keep them in sync):
--   isMatch       0   (12 states x 16 pos states)
--   isRep         192 (12)     isRepG0 204   isRepG1 216   isRepG2 228
--   isRep0Long    240 (12 x 16)
--   posSlot       432 (4 len states x 64)
--   posDecoders   688 (115 used, reserved 128)
--   align         832 (16)
--   matchLen      848 (514: choice, choice2, low 16x8, mid 16x8, high 256)
--   repLen        1362 (514)
--   literal       1876 (8 contexts x 0x300)

local function compress(s)
  local n = #s
  local d = {}
  for i = 1, n do d[i] = s:byte(i) end

  local P = setmetatable({}, { __index = function() return 1024 end })
  local low, range, cacheSize, cache = 0, 4294967295, 1, 0
  local out = {}
  local TWO24 = 16777216
  local TWO32 = 4294967296

  local function shiftLow()
    local low32 = low % TWO32
    if low32 < 4278190080 or low >= TWO32 then
      local carry = low >= TWO32 and 1 or 0
      local temp = cache
      repeat
        out[#out + 1] = string.char((temp + carry) % 256)
        temp = 255
        cacheSize = cacheSize - 1
      until cacheSize == 0
      cache = math.floor(low32 / TWO24)
    end
    cacheSize = cacheSize + 1
    low = (low32 % TWO24) * 256
  end

  local function normalize()
    while range < TWO24 do
      range = range * 256
      shiftLow()
    end
  end

  local function encBit(i, b)
    local pr = P[i]
    local bound = math.floor(range / 2048) * pr
    if b == 0 then
      range = bound
      P[i] = pr + math.floor((2048 - pr) / 32)
    else
      low = low + bound
      range = range - bound
      P[i] = pr - math.floor(pr / 32)
    end
    normalize()
  end

  local function encDirect(value, nbits)
    for i = nbits - 1, 0, -1 do
      range = math.floor(range / 2)
      local b = math.floor(value / 2 ^ i) % 2
      if b == 1 then low = low + range end
      normalize()
    end
  end

  local function encTree(base, nbits, sym)
    local m = 1
    for i = nbits - 1, 0, -1 do
      local b = math.floor(sym / 2 ^ i) % 2
      encBit(base + m, b)
      m = m * 2 + b
    end
  end

  local function encRTree(base, nbits, sym)
    local m = 1
    for i = 0, nbits - 1 do
      local b = math.floor(sym / 2 ^ i) % 2
      encBit(base + m, b)
      m = m * 2 + b
    end
  end

  local function encLen(base, len0, ps)
    if len0 < 8 then
      encBit(base, 0)
      encTree(base + 2 + ps * 8, 3, len0)
    elseif len0 < 16 then
      encBit(base, 1)
      encBit(base + 1, 0)
      encTree(base + 130 + ps * 8, 3, len0 - 8)
    else
      encBit(base, 1)
      encBit(base + 1, 1)
      encTree(base + 258, 8, len0 - 16)
    end
  end

  local function encDist(dist0, len0)
    local ls = len0 < 3 and len0 or 3
    local slot
    if dist0 < 4 then
      slot = dist0
    else
      local nb = 0
      while 2 ^ (nb + 1) <= dist0 do nb = nb + 1 end
      slot = 2 * nb + math.floor(dist0 / 2 ^ (nb - 1)) % 2
    end
    encTree(432 + ls * 64, 6, slot)
    if slot >= 4 then
      local nd = math.floor(slot / 2) - 1
      local base = (2 + slot % 2) * 2 ^ nd
      local rem = dist0 - base
      if slot < 14 then
        encRTree(688 + base - slot, nd, rem)
      else
        encDirect(math.floor(rem / 16), nd - 4)
        encRTree(832, 4, rem % 16)
      end
    end
  end

  -- Hash chains over 3-byte prefixes, most recent position last.
  local heads = {}
  local function insert(p)
    if p + 2 <= n then
      local key = s:sub(p, p + 2)
      local list = heads[key]
      if not list then list = {}; heads[key] = list end
      list[#list + 1] = p
    end
  end

  local state, r0, p = 0, 0, 1
  while p <= n do
    local ps = (p - 1) % 4
    -- Longest match among recent candidates. Source index is cand, the
    -- distance is p - cand, and dist0 = distance - 1 is what gets coded.
    local bestLen, bestCand = 0, 0
    if p + 2 <= n then
      local list = heads[s:sub(p, p + 2)]
      if list then
        for k = #list, math.max(1, #list - 31), -1 do
          local cand = list[k]
          local l = 0
          while l < 273 and p + l <= n and d[cand + l] == d[p + l] do l = l + 1 end
          if l > bestLen then bestLen, bestCand = l, cand end
        end
      end
    end

    if bestLen >= 3 then
      encBit(state * 16 + ps, 1)
      encBit(192 + state, 0)
      encLen(848, bestLen - 2, ps)
      local dist0 = p - bestCand - 1
      encDist(dist0, bestLen - 2)
      state = state < 7 and 7 or 10
      r0 = dist0
      for q = p, p + bestLen - 1 do insert(q) end
      p = p + bestLen
    else
      encBit(state * 16 + ps, 0)
      local prev = p > 1 and d[p - 1] or 0
      local base = 1876 + 768 * math.floor(prev / 32)
      local byte = d[p]
      local sym = 1
      if state < 7 then
        for i = 7, 0, -1 do
          local b = math.floor(byte / 2 ^ i) % 2
          encBit(base + sym, b)
          sym = sym * 2 + b
        end
      else
        local mb = d[p - r0 - 1]
        local matching = true
        for i = 7, 0, -1 do
          local b = math.floor(byte / 2 ^ i) % 2
          if matching then
            local mbit = math.floor(mb / 2 ^ i) % 2
            encBit(base + (1 + mbit) * 256 + sym, b)
            if mbit ~= b then matching = false end
          else
            encBit(base + sym, b)
          end
          sym = sym * 2 + b
        end
      end
      state = state < 4 and 0 or (state < 10 and state - 3 or state - 6)
      insert(p)
      p = p + 1
    end
  end

  for _ = 1, 5 do shiftLow() end

  local header = string.char(math.floor(n / TWO24) % 256, math.floor(n / 65536) % 256,
                             math.floor(n / 256) % 256, n % 256)
  return header .. table.concat(out)
end

return { compress = compress }
