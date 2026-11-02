--------------------------------------------------------------------
-- XenonSec :: obfuscator/minify.lua
-- Token-aware minifier for the engine templates. Comments are dropped (except
-- the --[[Protected ...]] watermark comment), whitespace is reduced to the
-- spaces Lua needs to keep two tokens apart, and integer literals of 1000 or
-- more are masked as arithmetic (((n+k)-k)) with a per-build key k. %name%
-- placeholders are kept as single tokens so template substitution still works.
--------------------------------------------------------------------

local MASK_MIN = 1000
local KEYWORDS = {}
for w in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%a+") do KEYWORDS[w] = true end
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

-- Keywords that can end a complete statement or expression.
local ENDS_EXPR = { ["end"] = true, ["nil"] = true, ["true"] = true, ["false"] = true, ["break"] = true }
-- Keywords that can start a statement. `do` and `then` are left out on purpose:
-- they close a loop or if header, and `;` before them would break the header.
local STARTS_STAT = { ["local"] = true, ["if"] = true, ["for"] = true, ["while"] = true,
  ["repeat"] = true, ["return"] = true, ["function"] = true, ["break"] = true, ["goto"] = true }

-- True when the token can end a complete statement, so a new one may follow it.
-- Values, `end` and the closing `)` of a call qualify. Other names are left out:
-- in Luau a name can end a type (`function f(): number` is followed by its body),
-- and a `)` that closes a parameter list is followed by the body too.
local function endsStatement(tk)
  if tk.t == "num" or tk.t == "str" then return true end
  if tk.t == "word" then return ENDS_EXPR[tk.v] == true and tk.v:sub(1, 1) ~= "%" end
  return tk.t == "op" and tk.v == ")" and tk.closesCall == true
end

-- True when the token can only begin a statement: an identifier, or a keyword
-- that starts one. Operators, `(` and `do`/`then` never qualify.
local function startsStatement(tk)
  if tk.t ~= "word" or tk.v:sub(1, 1) == "%" then return false end
  if KEYWORDS[tk.v] then return STARTS_STAT[tk.v] == true end
  return true
end

local function minify(text, maskKey)
  local toks = tokenize(text)
  local out, prev, prevTok = {}, nil, nil
  local parens, lastWord, beforeWord = {}, nil, nil
  for _, tk in ipairs(toks) do
    local v = tk.v
    -- Track what each `(` opens: a parameter list (after `function` or a name
    -- that follows it) or a call. Only the close of a call may end a statement.
    if tk.t == "op" and v == "(" then
      local isParams = (prevTok and prevTok.t == "word" and prevTok.v == "function")
        or (prevTok and prevTok.t == "word" and beforeWord and beforeWord.t == "word" and beforeWord.v == "function")
      parens[#parens + 1] = isParams and "params" or "call"
    elseif tk.t == "op" and v == ")" then
      local kind = table.remove(parens)
      tk.closesCall = kind == "call"
    end
    if tk.t == "num" and v:match("^%d+$") and tonumber(v) >= MASK_MIN and maskKey then
      local k = math.random(1000, 99999)
      v = string.format("((%d+%d)-%d)", tonumber(v), k, k)
    end
    if tk.t == "com" then
      out[#out + 1] = v .. "\n"
      prev, prevTok = nil, nil
    else
      if prevTok and endsStatement(prevTok) and startsStatement(tk) then
        out[#out + 1] = ";"
        prev = ";"
      elseif prev and needsSpace(prev, v) then
        out[#out + 1] = " "
      end
      out[#out + 1] = v
      beforeWord = prevTok
      prev, prevTok = v, tk
    end
  end
  return table.concat(out)
end

return { minify = minify, tokenize = tokenize }
