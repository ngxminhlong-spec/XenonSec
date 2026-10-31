--------------------------------------------------------------------
-- XenonSec :: obfuscator/minify.lua
-- Token-aware minifier for the engine templates. Comments are dropped (except
-- the --[[Protected ...]] watermark comment), whitespace is reduced to the
-- spaces Lua needs to keep two tokens apart, and integer literals of 1000 or
-- more are masked as arithmetic (((n+k)-k)) with a per-build key k. %name%
-- placeholders are kept as single tokens so template substitution still works.
--------------------------------------------------------------------

local MASK_MIN = 1000
local OPS2 = { [".."] = true, ["=="] = true, ["~="] = true, ["<="] = true, [">="] = true,
  ["//"] = true, ["::"] = true, ["<<"] = true, [">>"] = true }

local function tokenize(s)
  local toks, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif s:sub(i, i + 1) == "--" then
      local eq = s:match("^%-%-%[(=*)%[", i)
      if eq then
        local _, e = s:find("]" .. eq .. "]", i, true)
        e = e or n
        local body = s:sub(i, e)
        if body:sub(1, 13) == "--[[Protected" then toks[#toks + 1] = { t = "com", v = body } end
        i = e + 1
      else
        i = (s:find("\n", i, true) or n) + 1
      end
    elseif s:match("^%[=*%[", i) then
      local eq = s:match("^%[(=*)%[", i)
      local _, e = s:find("]" .. eq .. "]", i + #eq + 2, true)
      e = e or n
      toks[#toks + 1] = { t = "str", v = s:sub(i, e) }
      i = e + 1
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = s:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c then break
        else j = j + 1 end
      end
      toks[#toks + 1] = { t = "str", v = s:sub(i, j) }
      i = j + 1
    else
      local ph = s:match("^%%[%a_][%w_]*%%", i)
      local name = (not ph) and s:match("^[%a_][%w_]*", i)
      local num = (not ph and not name) and (s:match("^0[xX]%x+", i)
        or s:match("^%d+%.?%d*[eE][+-]?%d+", i) or s:match("^%d+%.?%d*", i)
        or ((c == "." and s:sub(i + 1, i + 1):match("%d")) and s:match("^%.%d+[eE][+-]?%d+", i) or s:match("^%.%d+", i)))
      if ph then
        toks[#toks + 1] = { t = "word", v = ph }; i = i + #ph
      elseif name then
        toks[#toks + 1] = { t = "word", v = name }; i = i + #name
      elseif num then
        toks[#toks + 1] = { t = "num", v = num }; i = i + #num
      else
        local op = s:sub(i, i + 2) == "..." and "..." or (OPS2[s:sub(i, i + 1)] and s:sub(i, i + 1)) or c
        toks[#toks + 1] = { t = "op", v = op }; i = i + #op
      end
    end
  end
  return toks
end

-- True when two adjacent token texts would otherwise merge or change meaning.
local function needsSpace(a, b)
  local x, y = a:sub(-1), b:sub(1, 1)
  if x:match("[%w_%%]") and y:match("[%w_%%]") then return true end
  if x == "-" and y == "-" then return true end
  if x == "[" and (y == "[" or y == "=") then return true end
  if x:match("%d") and y == "." then return true end
  if x == "." and y:match("[%.%d]") then return true end
  return false
end

local function minify(text, maskKey)
  local toks = tokenize(text)
  local out, prev = {}, nil
  for _, tk in ipairs(toks) do
    local v = tk.v
    if tk.t == "num" and v:match("^%d+$") and tonumber(v) >= MASK_MIN and maskKey then
      local k = math.random(1000, 99999)
      v = string.format("((%d+%d)-%d)", tonumber(v), k, k)
    end
    if tk.t == "com" then
      out[#out + 1] = v .. "\n"
      prev = nil
    else
      if prev and needsSpace(prev, v) then out[#out + 1] = " " end
      out[#out + 1] = v
      prev = v
    end
  end
  return table.concat(out)
end

return { minify = minify, tokenize = tokenize }
