--------------------------------------------------------------------
-- XenonSec :: obfuscator/typemangler.lua
-- TypeMangler (Luau output only). The parser throws every type annotation
-- away, so no user type ever reaches the output. This emits a random block
-- of Luau type aliases (unions, intersections, function types, generic
-- aliases, mangled field names). None of it runs: type declarations have no
-- runtime effect. It only makes the file look like a typed Luau module.
-- Plain Lua 5.1 output gets nothing.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local load = dofile(dir .. "loader.lua")
local _util = load("util")
local randomIdent = _util.randomIdent

local TM_PRIMS = { "number", "string", "boolean", "any" }

-- Chunk-level decoy type block.
local function buildTypeMangler()
  local aliases = {}
  local function prim() return TM_PRIMS[math.random(1, #TM_PRIMS)] end
  local function tyExpr(depth)
    local choice = math.random(1, depth >= 3 and 3 or 8)
    if choice == 1 then return prim()
    elseif choice == 2 then
      if #aliases > 0 then return aliases[math.random(1, #aliases)] end
      return prim()
    elseif choice == 3 then
      return "{ " .. randomIdent() .. ": " .. tyExpr(depth + 1) .. " }"
    elseif choice == 4 then
      return "(" .. tyExpr(depth + 1) .. " | " .. tyExpr(depth + 1) .. ")"
    elseif choice == 5 then
      return "(" .. tyExpr(depth + 1) .. " & " .. tyExpr(depth + 1) .. ")"
    elseif choice == 6 then
      return "((" .. tyExpr(depth + 1) .. ") -> " .. tyExpr(depth + 1) .. ")"
    elseif choice == 7 then
      return "{ [string]: " .. tyExpr(depth + 1) .. " }"
    else
      return "{ " .. randomIdent() .. ": " .. tyExpr(depth + 1) .. ", " ..
             randomIdent() .. ": " .. tyExpr(depth + 1) .. " }"
    end
  end
  local out = {}
  for _ = 1, math.random(6, 12) do
    local name = randomIdent()
    if math.random() < 0.25 then
      local param = randomIdent()
      out[#out + 1] = string.format("type %s<%s> = { %s: %s, %s: %s }", name, param,
        randomIdent(), param, randomIdent(), tyExpr(1))
    else
      out[#out + 1] = string.format("type %s = %s", name, tyExpr(0))
      aliases[#aliases + 1] = name
    end
  end
  return table.concat(out, "\n")
end

-- One small type declaration, scattered between the handler definitions.
-- Only primitives that are not standard-library names: this text goes through
-- the engine rewrite, which would turn `string` into a table lookup.
local SCATTER_PRIMS = { "number", "boolean", "any" }
local function scatterType()
  return string.format("type %s = %s | %s", randomIdent(),
    SCATTER_PRIMS[math.random(1, #SCATTER_PRIMS)], SCATTER_PRIMS[math.random(1, #SCATTER_PRIMS)])
end

return { buildTypeMangler = buildTypeMangler, scatterType = scatterType }
