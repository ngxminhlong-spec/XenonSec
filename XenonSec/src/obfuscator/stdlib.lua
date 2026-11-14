--------------------------------------------------------------------
-- XenonSec :: obfuscator/stdlib.lua
-- Standard-library call renaming: the generated code never names a standard function directly; lookups are rewritten into a per-build encoded table that the header fills at startup.
--------------------------------------------------------------------

--------------------------------------------------------------------
-- Standard-library lookups. The generated code never names a standard
-- library function directly: every whitelisted name (setmetatable,
-- string.format, pcall, math.random, ...) is rewritten to an index into
-- a table that is filled at startup. Each name is stored as bytes offset
-- by a per-build constant, so the file has no readable `string.format`-
-- style reference left. Names are not secret; this just removes the
-- readable tells. The bootstrap names (string.byte, string.char,
-- table.concat) stay literal, because the decoder needs them first.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local load = dofile(dir .. "loader.lua")
local _util = load("util")
local numExpr, randomIdent = _util.numExpr, _util.randomIdent

-- Each name is encoded with a keystream seeded per name (see keystream below).
-- The seeds are chosen once per build, so every reference to a name agrees.
local seeds = {}
local function resetSeeds() seeds = {} end
local function seedFor(s)
  if not seeds[s] then seeds[s] = math.random(1, 2147483646) end
  return seeds[s]
end

-- Keystream: S = S * 16807 mod (2^31 - 1), key byte = floor(S / 65536) % 256.
-- The runtime decoder runs the same recurrence, so it needs only the seed.
local function keystream(seed, n)
  local ks, s = {}, seed
  for j = 1, n do
    s = (s * 16807) % 2147483647
    ks[j] = math.floor(s / 65536) % 256
  end
  return ks
end

local STD_BARE = {
  pairs = true, ipairs = true, next = true, select = true, type = true,
  tonumber = true, tostring = true, error = true, pcall = true, xpcall = true,
  setmetatable = true, getmetatable = true, rawget = true, rawset = true,
  rawequal = true, print = true, unpack = true, os = true, debug = true,
  string = true, table = true, math = true,
}
local STD_DOTTED = {
  ["string.format"] = true, ["string.sub"] = true, ["string.rep"] = true,
  ["string.len"] = true, ["table.remove"] = true, ["table.unpack"] = true,
  ["math.floor"] = true, ["math.max"] = true, ["math.random"] = true,
  ["os.clock"] = true, ["debug.gethook"] = true,
}

-- Rewrites standard-library references in `text` to `tabName[k]`, skipping
-- string literals, comments, field names (`x.error`, `{ error = ... }`) and
-- declarations (`local type = ...`). `list` collects the paths in order of
-- first use; `index` maps a path to its k.
local function rewriteStd(text, tabName, list, index)
  local out, i, n = {}, 1, #text
  local function prevNonSpace(pos)
    local j = pos - 1
    while j >= 1 and text:sub(j, j):match("%s") do j = j - 1 end
    return j >= 1 and text:sub(j, j) or ""
  end
  while i <= n do
    local c = text:sub(i, i)
    if text:sub(i, i + 1) == "--" then
      local eq = text:match("^%-%-%[(=*)%[", i)
      local j
      if eq then
        local _, e = text:find("]" .. eq .. "]", i, true)
        j = e or n
      else
        j = text:find("\n", i, true) or n
      end
      out[#out + 1] = text:sub(i, j); i = j + 1
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = text:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c then break
        else j = j + 1 end
      end
      out[#out + 1] = text:sub(i, j); i = j + 1
    elseif text:match("^%[=*%[", i) then
      local eq = text:match("^%[(=*)%[", i)
      local _, e = text:find("]" .. eq .. "]", i, true)
      local j = e or n
      out[#out + 1] = text:sub(i, j); i = j + 1
    elseif c:match("[%a_]") and not text:sub(i - 1, i - 1):match("[%w_]") then
      local name = text:match("^[%a_][%w_]*", i)
      local after = text:match("^%.([%a_][%w_]*)", i + #name)
      local prev = prevNonSpace(i)
      local before = text:sub(math.max(1, i - 12), i - 1)
      local isField = prev == "." or prev == ":"
      -- `type Name = ...` is a Luau type alias keyword, not the std `type` call.
      local isTypeAlias = name == "type" and text:match("^%s+[%a_]", i + #name) ~= nil
      local isDecl = before:match("local%s+$") or before:match("function%s+$") or isTypeAlias
      local nextTok = text:match("^%s*(.)", i + #name)
      local isKey = nextTok == "=" and text:match("^%s*==", i + #name) == nil
      local path
      if not isField and not isDecl and not isKey then
        if after and STD_DOTTED[name .. "." .. after] then
          path = name .. "." .. after
        elseif not after and STD_BARE[name] then
          path = name
        end
      end
      if path then
        local k = index[path]
        if not k then
          list[#list + 1] = path
          k = #list
          index[path] = k
        end
        out[#out + 1] = tabName .. "[" .. numExpr(k) .. "]"
        i = i + #path
      else
        out[#out + 1] = name
        i = i + #name
      end
    else
      out[#out + 1] = c; i = i + 1
    end
  end
  return table.concat(out)
end

-- Builds the startup block that fills tabName from the collected paths.
-- Names are stored as (byte + salt) % 256, decoded by `dec` with the
-- header's own char/concat locals. `names` gives the local identifiers.
-- Encodes a name as a decode call in the generated code: names.dec({...}).
-- Encodes `s` for the runtime decoder: the bytes plus the masked seed.
local function encBytes(s)
  local seed = seedFor(s)
  local ks = keystream(seed, #s)
  local t = {}
  for j = 1, #s do t[j] = (s:byte(j) + ks[j]) % 256 end
  return "{" .. table.concat(t, ",") .. "}, " .. numExpr(seed)
end

local function encName(names, s)
  return names.dec .. "(" .. encBytes(s) .. ")"
end

local function buildStdBlock(tabName, list, names)
  local function enc(s) return encBytes(s) end
  local seedVar = randomIdent()
  local lines = {}
  -- Root of the lookups: on Lune and some sandboxes _G is an empty table, but
  -- getfenv(0) still reaches the globals; plain Lua has no getfenv, so _G there.
  lines[#lines + 1] = string.format("local %s, %s = {}, (getfenv and getfenv(0)) or _G", tabName, names.G)
  -- Bootstrap, found by behaviour rather than by name. Only string.char and
  -- string.byte are called here: probing every string function with arbitrary
  -- arguments at program start is unsafe (it corrupted memory in practice).
  -- The string library is
  -- reached through the string metatable, and string.char is the function that
  -- gives "AB" for (65, 66); string.byte gives 65, 66 for ("AB", 1, 2).
  lines[#lines + 1] = string.format(
    'local %s, %s; do local %s, %s = __PCALL__, __GETMT__("").__index for _, %s in __PAIRS__({%s.char, %s.byte}) do if __TYPE__(%s) == "function" then local %s, %s = %s(%s, 65, 66) if %s and %s == "AB" then %s = %s end local %s, %s, %s = %s(%s, "AB", 1, 2) if %s and %s == 65 and %s == 66 then %s = %s end end end end',
    names.byte, names.char,
    names.pc, names.sm, names.f, names.sm, names.sm, names.f,
    names.ok, names.r, names.pc, names.f, names.ok, names.r, names.char, names.f,
    names.ok, names.r, names.j, names.pc, names.f, names.ok, names.r, names.j, names.byte, names.f)
  -- Builtins the bootstrap needs are read from the root table with escaped
  -- keys, so their names are not plain text in the output.
  local BOOT_BUILTINS = { __PCALL__ = "pcall", __GETMT__ = "getmetatable", __PAIRS__ = "pairs", __TYPE__ = "type" }
  lines[#lines] = lines[#lines]:gsub("__%u+__", function(tok)
    local name = BOOT_BUILTINS[tok]
    return names.G .. "[" .. ('"' .. name:gsub(".", function(c) return string.format("\\%03d", c:byte()) end) .. '"') .. "]"
  end)
  -- Name decoder: builds the string byte by byte, so it needs no table library.
  -- Same recurrence as keystream() above: the state advances once per byte.
  local decTpl = "local function %s(%s, %s) local %s = \"\" for %s = 1, #%s do %s = (%s * 16807) %% 2147483647 %s = %s .. %s((%s[%s] - (%s - %s %% 65536) / 65536) %% 256) end return %s end"
  -- The two Park-Miller constants are masked like every other integer constant.
  decTpl = decTpl:gsub("16807", function() return numExpr(16807) end)
  decTpl = decTpl:gsub("2147483647", function() return numExpr(2147483647) end)
  lines[#lines + 1] = string.format(decTpl,
    names.dec, names.t, seedVar, names.o, names.j, names.t, seedVar, seedVar,
    names.o, names.o, names.char, names.t, names.j, seedVar, seedVar, names.o)
  -- table.concat, resolved through the same encoded lookup as everything else.
  lines[#lines + 1] = string.format("local %s = %s[%s(%s)][%s(%s)]",
    names.concat, names.G, names.dec, enc("table"), names.dec, enc("concat"))
  for k, path in ipairs(list) do
    local expr = names.G
    for part in path:gmatch("[^%.]+") do
      expr = expr .. "[" .. names.dec .. "(" .. enc(part) .. ")]"
    end
    lines[#lines + 1] = string.format("%s[%s] = %s", tabName, numExpr(k), expr)
  end
  return table.concat(lines, " ")
end

return {
  buildStdBlock = buildStdBlock,
  encName = encName,
  resetSeeds = resetSeeds,
  rewriteStd = rewriteStd,
}
