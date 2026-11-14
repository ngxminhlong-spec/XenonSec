--------------------------------------------------------------------
-- XenonSec :: obfuscator/minify.lua
-- Minifier for the engine templates. A tokenizer splits the text, a
-- recursive-descent parser (Lua 5.1-5.4 and Luau syntax) finds where every
-- statement starts and ends, and the emitter writes the tokens back with the
-- spacing Lua needs and a `;` between consecutive statements. Comments are
-- dropped except the --[[Protected ...]] watermark. When masking is on (engine
-- templates), every integer literal is written in a random form that never
-- shows its value: (n), ((V)-k) with V = n+k, or a parenthesised ((V)-k). Some
-- statement boundaries get a junk statement (`do end`, or an `if` whose
-- condition is always false), so the code is harder to follow.
--
-- Placeholders (%name%, __XS_*__) are opaque words. They may expand to nothing
-- or to whole statements, so no `;` is ever written next to one.
--
-- If the parser meets syntax it does not know, the text is emitted with
-- spacing only (no separators) and M.stats.fallback is counted, so a template
-- that the parser cannot read is visible in the tests rather than silent.
--------------------------------------------------------------------

-- Luau compound assignment operators (two and three characters).
local COMPOUND = { ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true, ["%="] = true,
  ["^="] = true, ["//="] = true, ["..="] = true }
local OPS2 = { [".."] = true, ["=="] = true, ["~="] = true, ["<="] = true, [">="] = true,
  ["//"] = true, ["::"] = true, ["<<"] = true, [">>"] = true }
local KEYWORDS = {}
for w in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%a+") do
  KEYWORDS[w] = true
end
local BLOCK_END = { ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true }
-- Binary operators: { left priority, right priority } (Lua 5.4 table).
local BIN = {
  ["or"] = { 1, 1 }, ["and"] = { 2, 2 },
  ["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 }, [">="] = { 3, 3 }, ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
  ["|"] = { 4, 4 }, ["~"] = { 5, 5 }, ["&"] = { 6, 6 }, ["<<"] = { 7, 7 }, [">>"] = { 7, 7 },
  [".."] = { 9, 8 }, ["+"] = { 10, 10 }, ["-"] = { 10, 10 },
  ["*"] = { 11, 11 }, ["/"] = { 11, 11 }, ["//"] = { 11, 11 }, ["%"] = { 11, 11 },
  ["^"] = { 14, 13 },
}
local UNARY_PRI = 12

local stats = { parsed = 0, fallback = 0, lastError = nil }

--------------------------------------------------------------------
-- Tokenizer. Comments are kept only when they are the watermark; strings and
-- long strings are single tokens; %name% and __XS_*__ placeholders are words.
--------------------------------------------------------------------

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
    elseif c == "`" then
      -- Luau interpolated string: `text {expr} text`. Braces are counted so a
      -- closing backtick inside an interpolation does not end the string.
      local j, depth = i + 1, 0
      while j <= n do
        local d = s:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == "{" then depth = depth + 1; j = j + 1
        elseif d == "}" then depth = depth - 1; j = j + 1
        elseif d == "`" and depth == 0 then break
        else j = j + 1 end
      end
      toks[#toks + 1] = { t = "str", v = s:sub(i, j) }
      i = j + 1
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
        if COMPOUND[s:sub(i, i + 3)] then op = s:sub(i, i + 3)
        elseif COMPOUND[s:sub(i, i + 2)] then op = s:sub(i, i + 2)
        elseif COMPOUND[s:sub(i, i + 1)] then op = s:sub(i, i + 1) end
        toks[#toks + 1] = { t = "op", v = op }; i = i + #op
      end
    end
  end
  return toks
end

--------------------------------------------------------------------
-- Parser. Recognises the whole grammar well enough to find statement
-- boundaries and to reject what it does not understand. It builds no tree:
-- it returns, for each code token that starts a statement inside a block
-- (other than the first), a flag saying a separator belongs before it.
--------------------------------------------------------------------

local function parse(ts)
  local i, n = 1, #ts
  local sep, drop = {}, {}

  local function tok(k) return ts[i + (k or 0)] end
  local function isOp(t, v) return t ~= nil and t.t == "op" and t.v == v end
  local function isKw(t, v) return t ~= nil and t.t == "word" and t.v == v end
  local function isName(t) return t ~= nil and t.t == "word" and not KEYWORDS[t.v] end
  local function fail(msg) error("minify: " .. msg .. " at token " .. i, 0) end
  local function expectOp(v) if not isOp(tok(), v) then fail("expected '" .. v .. "'") end i = i + 1 end
  local function expectKw(v) if not isKw(tok(), v) then fail("expected '" .. v .. "'") end i = i + 1 end
  local function expectName() if not isName(tok()) then fail("expected name") end i = i + 1 end

  -- Skips a balanced group starting at the current token. `>>` closes two
  -- angle brackets (nested generics), so it is counted as two.
  local function skipBalanced(open, close)
    if not isOp(tok(), open) then fail("expected '" .. open .. "'") end
    local depth = 0
    repeat
      local t = tok()
      if not t then fail("unbalanced '" .. open .. "'") end
      if t.t == "op" then
        if t.v == open then depth = depth + 1
        elseif t.v == close then depth = depth - 1
        elseif close == ">" and t.v == ">>" then depth = depth - 2 end
      end
      i = i + 1
    until depth <= 0
  end

  local expr, explist, suffixedexp, tableCons, funcBody, block

  -- Luau type syntax, skipped structurally.
  local function simpleType()
    local t = tok()
    if isOp(t, "<") then
      -- generic function type: <T>(T) -> T
      skipBalanced("<", ">")
      return simpleType()
    end
    if isOp(t, "{") then skipBalanced("{", "}")
    elseif isOp(t, "(") then skipBalanced("(", ")")
    elseif t and (t.t == "str" or t.t == "num") then i = i + 1
    elseif isKw(t, "typeof") then i = i + 1; skipBalanced("(", ")")
    elseif isKw(t, "nil") or isKw(t, "true") or isKw(t, "false") then i = i + 1
    elseif isName(t) then
      i = i + 1
      while isOp(tok(), ".") do i = i + 1; expectName() end
      if isOp(tok(), "<") then skipBalanced("<", ">") end
    else
      fail("expected type")
    end
  end
  local function typ()
    simpleType()
    while true do
      local t = tok()
      if isOp(t, "|") or isOp(t, "&") then i = i + 1; simpleType()
      elseif isOp(t, "?") then i = i + 1
      elseif isOp(t, "-") and isOp(ts[i + 1], ">") then i = i + 2; typ()
      else break end
    end
  end

  -- Parameter list up to (not including) `)`. Placeholders may sit next to
  -- names (annotations expand into them), so any word is accepted here.
  local function params()
    while true do
      local t = tok()
      if not t then fail("unterminated parameter list") end
      if isOp(t, ")") then return end
      if isOp(t, ",") then i = i + 1
      elseif isOp(t, ":") then i = i + 1; typ()
      elseif t.t == "word" or isOp(t, "...") then i = i + 1
      else fail("bad parameter") end
    end
  end

  funcBody = function()
    if isOp(tok(), "<") then skipBalanced("<", ">") end
    expectOp("(")
    params()
    expectOp(")")
    if isOp(tok(), ":") then i = i + 1; typ() end
    block()
    expectKw("end")
  end

  tableCons = function()
    expectOp("{")
    while not isOp(tok(), "}") do
      local t = tok()
      if not t then fail("unterminated table") end
      if isOp(t, "[") then
        i = i + 1; expr(0); expectOp("]"); expectOp("="); expr(0)
      elseif isName(t) and isOp(ts[i + 1], "=") then
        i = i + 2; expr(0)
      else
        expr(0)
      end
      local s = tok()
      if isOp(s, ",") or isOp(s, ";") then i = i + 1
      elseif not isOp(s, "}") then fail("bad table field") end
    end
    i = i + 1
  end

  local function args()
    local t = tok()
    if t and t.t == "str" then i = i + 1
    elseif isOp(t, "{") then tableCons()
    else
      expectOp("(")
      if not isOp(tok(), ")") then explist() end
      expectOp(")")
    end
  end

  local function primary()
    local t = tok()
    if isName(t) then i = i + 1
    elseif isOp(t, "(") then i = i + 1; expr(0); expectOp(")")
    else fail("expected expression") end
  end

  suffixedexp = function()
    primary()
    while true do
      local t = tok()
      if isOp(t, ".") then i = i + 1; expectName()
      elseif isOp(t, "[") then i = i + 1; expr(0); expectOp("]")
      elseif isOp(t, ":") then i = i + 1; expectName(); args()
      elseif isOp(t, "(") or isOp(t, "{") or (t and t.t == "str") then args()
      else break end
    end
  end

  local function simpleExpr()
    local t = tok()
    if not t then fail("expected expression") end
    if t.t == "num" or t.t == "str" then i = i + 1
    elseif isKw(t, "nil") or isKw(t, "true") or isKw(t, "false") then i = i + 1
    elseif isOp(t, "...") then i = i + 1
    elseif isKw(t, "function") then i = i + 1; funcBody()
    elseif isKw(t, "if") then
      -- Luau if-expression
      i = i + 1; expr(0); expectKw("then"); expr(0)
      while isKw(tok(), "elseif") do i = i + 1; expr(0); expectKw("then"); expr(0) end
      expectKw("else"); expr(0)
    elseif isOp(t, "{") then tableCons()
    else suffixedexp() end
  end

  expr = function(limit)
    local t = tok()
    if isKw(t, "not") or isOp(t, "-") or isOp(t, "#") or isOp(t, "~") then
      i = i + 1; expr(UNARY_PRI)
    else
      simpleExpr()
    end
    if isOp(tok(), "::") then i = i + 1; typ() end
    while true do
      local b = tok()
      local pr
      if b and (b.t == "op" or (b.t == "word" and (b.v == "and" or b.v == "or"))) then pr = BIN[b.v] end
      if not pr or pr[1] <= limit then break end
      i = i + 1
      expr(pr[2])
    end
  end

  explist = function()
    expr(0)
    while isOp(tok(), ",") do i = i + 1; expr(0) end
  end

  local function localNames()
    while true do
      expectName()
      if isOp(tok(), "<") then skipBalanced("<", ">") end
      if isOp(tok(), ":") then i = i + 1; typ() end
      if isOp(tok(), ",") then i = i + 1 else break end
    end
  end

  local function exprStat()
    suffixedexp()
    local t = tok()
    if t and t.t == "op" and COMPOUND[t.v] then
      i = i + 1
      explist()
    elseif isOp(t, "=") or isOp(t, ",") then
      while isOp(tok(), ",") do i = i + 1; suffixedexp() end
      expectOp("=")
      explist()
    end
  end

  local statement
  statement = function()
    local t = tok()
    if isOp(t, "::") then
      i = i + 1; expectName(); expectOp("::")
    elseif not t or t.t ~= "word" then
      exprStat()
    elseif t.v == "local" then
      i = i + 1
      if isKw(tok(), "function") then
        i = i + 1; expectName(); funcBody()
      else
        localNames()
        if isOp(tok(), "=") then i = i + 1; explist() end
      end
    elseif t.v == "function" then
      i = i + 1; expectName()
      while isOp(tok(), ".") do i = i + 1; expectName() end
      if isOp(tok(), ":") then i = i + 1; expectName() end
      funcBody()
    elseif t.v == "if" then
      i = i + 1; expr(0); expectKw("then"); block()
      while isKw(tok(), "elseif") do i = i + 1; expr(0); expectKw("then"); block() end
      if isKw(tok(), "else") then i = i + 1; block() end
      expectKw("end")
    elseif t.v == "while" then
      i = i + 1; expr(0); expectKw("do"); block(); expectKw("end")
    elseif t.v == "do" then
      i = i + 1; block(); expectKw("end")
    elseif t.v == "for" then
      i = i + 1; expectName()
      if isOp(tok(), ":") then i = i + 1; typ() end
      if isOp(tok(), "=") then
        i = i + 1; expr(0); expectOp(","); expr(0)
        if isOp(tok(), ",") then i = i + 1; expr(0) end
      else
        while isOp(tok(), ",") do
          i = i + 1; expectName()
          if isOp(tok(), ":") then i = i + 1; typ() end
        end
        expectKw("in"); explist()
      end
      expectKw("do"); block(); expectKw("end")
    elseif t.v == "repeat" then
      i = i + 1; block(); expectKw("until"); expr(0)
    elseif t.v == "return" then
      i = i + 1
      local nt = tok()
      if not (nt == nil or isOp(nt, ";") or (nt.t == "word" and BLOCK_END[nt.v])) then explist() end
      if isOp(tok(), ";") then drop[i] = true; i = i + 1 end
      return true
    elseif t.v == "break" then
      i = i + 1
    elseif t.v == "goto" then
      i = i + 1; expectName()
    elseif t.v == "type" and isName(ts[i + 1]) and (isOp(ts[i + 2], "=") or isOp(ts[i + 2], "<")) then
      i = i + 1; expectName()
      if isOp(tok(), "<") then skipBalanced("<", ">") end
      expectOp("="); typ()
    elseif t.v == "export" and isKw(ts[i + 1], "type") then
      i = i + 1
      return statement()
    else
      exprStat()
    end
    return false
  end

  block = function()
    local first, returned = true, false
    while true do
      local t = tok()
      if t == nil or (t.t == "word" and BLOCK_END[t.v]) then return end
      if isOp(t, ";") then
        drop[i] = true
        i = i + 1
      else
        if returned then fail("statement after return") end
        -- Every statement after the first in its block is preceded by a separator.
        if not first then sep[i] = true end
        first = false
        returned = statement()
      end
    end
  end

  block()
  if i <= n then fail("unexpected token") end
  return sep, drop
end

--------------------------------------------------------------------
-- Emitter
--------------------------------------------------------------------

-- An integer written as arithmetic: V = n+k is written, then k, so the value n
-- never appears. Used for every integer literal in masked output.
local function maskInt(n)
  local k = math.random(1000, 99999)
  return string.format("((%d)-%d)", n + k, k)
end

-- A random form for one integer literal (see the header comment).
local function wrapInt(v)
  local n = tonumber(v)
  local form = math.random(1, 3)
  if form == 1 then return "(" .. v .. ")" end
  if form == 2 then return maskInt(n) end
  return "(" .. maskInt(n) .. ")"
end

-- A statement that never does anything: either an empty block, or an `if`
-- whose condition is always false. n*(n+1) is even for every integer n.
local function junkStatement()
  if math.random(1, 2) == 1 then return "do end" end
  local n = math.random(2, 99999)
  return string.format("if (%s*(%s+1))%%2==1 then end", maskInt(n), maskInt(n))
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

local function isPlaceholder(v)
  return v:sub(1, 1) == "%" or v:match("^__XS_.*__$") ~= nil
end

local function emit(code, tail, sep, drop, maskKey)
  local out, prev, prevTok = {}, nil, nil
  local carry = {}   -- comments that belonged to a dropped `;`
  for idx, tk in ipairs(code) do
    if drop and drop[idx] then
      for _, c in ipairs(tk.pre or {}) do carry[#carry + 1] = c end
    else
      local v = tk.v
      if tk.t == "num" and maskKey and v:match("^%d+$") then
        v = wrapInt(v)
      end
      -- The separator goes before the comments, so a comment never sits between
      -- a statement and the `;` that ends it.
      local needSep = sep and sep[idx] and prevTok and not isPlaceholder(prevTok.v) and not isPlaceholder(tk.v)
      if needSep then
        out[#out + 1] = ";"
        prev = ";"
        if maskKey and math.random() < 0.3 then
          out[#out + 1] = junkStatement() .. ";"
        end
      end
      local comments = {}
      for _, c in ipairs(carry) do comments[#comments + 1] = c end
      for _, c in ipairs(tk.pre or {}) do comments[#comments + 1] = c end
      carry = {}
      for _, c in ipairs(comments) do
        out[#out + 1] = c.v .. "\n"
        prev = nil
      end
      if not needSep and prev and needsSpace(prev, v) then out[#out + 1] = " " end
      out[#out + 1] = v
      prev, prevTok = v, tk
    end
  end
  for _, c in ipairs(carry) do out[#out + 1] = c.v .. "\n" end
  for _, c in ipairs(tail) do out[#out + 1] = c.v .. "\n" end
  return table.concat(out)
end

-- Splits the tokens into code and comments: a watermark comment is attached to
-- the code token after it; any trailing comment is returned separately.
local function splitTokens(text)
  local code, pending = {}, {}
  for _, tk in ipairs(tokenize(text)) do
    if tk.t == "com" then
      pending[#pending + 1] = tk
    else
      if #pending > 0 then tk.pre = pending; pending = {} end
      code[#code + 1] = tk
    end
  end
  return code, pending
end

local function minify(text, maskKey)
  local code, tail = splitTokens(text)
  local ok, sep, drop = pcall(parse, code)
  if ok then
    stats.parsed = stats.parsed + 1
  else
    stats.fallback = stats.fallback + 1
    stats.lastError = sep
    sep, drop = nil, nil
  end
  return emit(code, tail, sep, drop, maskKey)
end

return { minify = minify, tokenize = tokenize, stats = stats }
