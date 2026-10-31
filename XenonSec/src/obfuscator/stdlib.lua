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
        out[#out + 1] = tabName .. "[" .. k .. "]"
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
local function encName(names, salt, s)
  local t = {}
  for j = 1, #s do t[j] = (s:byte(j) + salt) % 256 end
  return names.dec .. "({" .. table.concat(t, ",") .. "})"
end

local function buildStdBlock(tabName, list, names, salt)
  local function enc(s)
    local t = {}
    for j = 1, #s do t[j] = (s:byte(j) + salt) % 256 end
    return "{" .. table.concat(t, ",") .. "}"
  end
  local lines = {}
  -- Root of the lookups: on Lune and some sandboxes _G is an empty table, but
  -- getfenv(0) still reaches the globals; plain Lua has no getfenv, so _G there.
  lines[#lines + 1] = string.format("local %s, %s = {}, (getfenv and getfenv(0)) or _G", tabName, names.G)
  lines[#lines + 1] = string.format(
    "local function %s(%s) local %s = {} for %s = 1, #%s do %s[%s] = %s((%s[%s] - %d) %% 256) end return %s(%s) end",
    names.dec, names.t, names.o, names.j, names.t, names.o, names.j, names.char,
    names.t, names.j, salt, names.concat, names.o)
  for k, path in ipairs(list) do
    local expr = names.G
    for part in path:gmatch("[^%.]+") do
      expr = expr .. "[" .. names.dec .. "(" .. enc(part) .. ")]"
    end
    lines[#lines + 1] = string.format("%s[%d] = %s", tabName, k, expr)
  end
  return table.concat(lines, " ")
end

return {
  buildStdBlock = buildStdBlock,
  encName = encName,
  rewriteStd = rewriteStd,
}
