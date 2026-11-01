--------------------------------------------------------------------
-- XenonSec :: obfuscator/templates/lzdec.lua
-- Runtime LZMA-style decoder for the proto records. This is source text:
-- the build substitutes __LZ_D__ (the per-build adaptation divisor, 2^shift)
-- and compiles the result through the same VM pipeline as user code, so the
-- decoder ships as encrypted bytecode, not as readable Lua. It mirrors
-- Lzma.decompress in lzma.lua; the two must stay in step.
--------------------------------------------------------------------

return [===[
return function(z, maxn)
  local D = __LZ_D__
  local n = string.byte(z, 1) * 16777216 + string.byte(z, 2) * 65536 + string.byte(z, 3) * 256 + string.byte(z, 4)
  if n > maxn then return "" end
  local p = 5
  local rg = 4294967295
  local cd = 0
  local function nx()
    local b = string.byte(z, p) or 0
    p = p + 1
    return b
  end
  for _ = 1, 5 do cd = cd * 256 + nx() end
  local function norm()
    while rg < 16777216 do
      rg = rg * 256
      cd = cd * 256 + nx()
    end
  end
  local function bit(pb, ix)
    local pr = pb[ix]
    local bd = math.floor(rg / 2048) * pr
    local bt = 0
    if cd < bd then
      rg = bd
      pb[ix] = pr + math.floor((2048 - pr) / D)
    else
      cd = cd - bd
      rg = rg - bd
      pb[ix] = pr - math.floor(pr / D)
      bt = 1
    end
    norm()
    return bt
  end
  local function tree(pb, nb)
    local m = 1
    for _ = 1, nb do m = m * 2 + bit(pb, m) end
    return m - 2 ^ nb
  end
  local function direct(nb)
    local v = 0
    for _ = 1, nb do
      rg = math.floor(rg / 2)
      local bt = 0
      if cd >= rg then
        cd = cd - rg
        bt = 1
      end
      v = v * 2 + bt
      norm()
    end
    return v
  end
  local function probs(k)
    local t = {}
    for i = 1, k do t[i] = 1024 end
    return t
  end
  local isM = probs(12)
  local lit = probs(256)
  local lc = probs(2)
  local ll = probs(16)
  local lm = probs(16)
  local lh = probs(256)
  local ps = { probs(64), probs(64), probs(64), probs(64) }
  local out = {}
  local cnt = 0
  local lzs = 0
  while cnt < n do
    if bit(isM, lzs + 1) == 0 then
      cnt = cnt + 1
      out[cnt] = tree(lit, 8)
      if lzs < 4 then lzs = 0 elseif lzs < 10 then lzs = lzs - 3 else lzs = lzs - 6 end
    else
      local len
      if bit(lc, 1) == 0 then
        len = tree(ll, 3) + 2
      elseif bit(lc, 2) == 0 then
        len = tree(lm, 3) + 10
      else
        len = tree(lh, 8) + 18
      end
      local slot = tree(ps[math.min(len - 2, 3) + 1], 6)
      local d
      if slot < 4 then
        d = slot
      else
        local nd = math.floor(slot / 2) - 1
        d = (2 + slot % 2) * 2 ^ nd + direct(nd)
      end
      local dist = d + 1
      for _ = 1, len do
        cnt = cnt + 1
        out[cnt] = out[cnt - dist]
      end
      if lzs < 7 then lzs = 7 else lzs = 10 end
    end
  end
  local parts = {}
  for i = 1, cnt do parts[i] = string.char(out[i]) end
  return table.concat(parts)
end
]===]
