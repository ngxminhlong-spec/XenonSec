--------------------------------------------------------------------
-- XenonSec :: obfuscator/selftest.lua
-- Plan for the handler self-test. Each check runs one simple handler on a
-- synthetic frame and folds the frame into a digest. The expected total is
-- computed here, at build time, from the same operator semantics. It is
-- known before anything is encoded, so it can be part of the key material.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local load = dofile(dir .. "loader.lua")
local _opcodes = load("opcodes")
local BINOP_SYMBOLS, UNOP_SYMBOLS = _opcodes.BINOP_SYMBOLS, _opcodes.UNOP_SYMBOLS

local DIGEST_P = 2147483647

local BIN_EVAL = {
  ["+"] = function(a, b) return a + b end,
  ["-"] = function(a, b) return a - b end,
  ["*"] = function(a, b) return a * b end,
  ["/"] = function(a, b) return a / b end,
  ["%"] = function(a, b) return a % b end,
  ["^"] = function(a, b) return a ^ b end,
  [".."] = function(a, b) return a .. b end,
  ["=="] = function(a, b) return a == b end,
  ["~="] = function(a, b) return a ~= b end,
  ["<"] = function(a, b) return a < b end,
  [">"] = function(a, b) return a > b end,
  ["<="] = function(a, b) return a <= b end,
  [">="] = function(a, b) return a >= b end,
  ["//"] = function(a, b) return math.floor(a / b) end,
}
local UN_EVAL = {
  ["-"] = function(a) return -a end,
  ["not"] = function(a) return not a end,
  ["#"] = function(a) return #a end,
}

-- One value's contribution to the digest. The engine's vl() does the same:
-- numbers as their integer part, strings by length, booleans and nil by code.
local function foldValue(x)
  if type(x) == "number" then return x - x % 1 end
  if type(x) == "string" then return #x + 100 end
  if x == true then return 11 end
  if x == false then return 12 end
  return 13
end

-- Returns { groups = { {op, a2, a3, a4, init, w1, w2, w3} ... }, expected }.
-- a3 may be "@wm" or "@three": the renderer writes the constant index there.
local function plan(wmText)
  local groups, expected = {}, 0
  local function add(op, a2, a3, a4, init, e1, e2, e3)
    local w1, w2, w3 = math.random(1, 97), math.random(1, 97), math.random(1, 97)
    expected = expected + w1 * foldValue(e1) + w2 * foldValue(e2) + w3 * foldValue(e3)
    groups[#groups + 1] = { op = op, a2 = a2, a3 = a3, a4 = a4, init = init or "{}", w1 = w1, w2 = w2, w3 = w3 }
  end
  add("LOADTRUE", "1", "0", "0", nil, true, nil, 2)
  add("LOADFALSE", "1", "0", "0", nil, false, nil, 2)
  add("LOADNIL", "1", "2", "0", "{[1]=5,[2]=6}", nil, nil, 2)
  add("MOVE", "1", "2", "0", "{[2]=9}", 9, 9, 2)
  add("JMP", "40", "0", "0", nil, nil, nil, 40)
  add("JF", "1", "40", "0", "{[1]=false}", false, nil, 40)
  add("JF", "1", "40", "0", "{[1]=0}", 0, nil, 2)
  add("JT", "1", "40", "0", "{[1]=0}", 0, nil, 40)
  add("JT", "1", "40", "0", "{[1]=false}", false, nil, 2)
  add("JNIL", "1", "40", "0", "{}", nil, nil, 40)
  add("JNIL", "1", "40", "0", "{[1]=false}", false, nil, 2)
  for k, sym in ipairs(BINOP_SYMBOLS) do
    local r = BIN_EVAL[sym](7, 3)
    add("BIN" .. k, "1", "2", "3", "{[2]=7,[3]=3}", r, 7, 2)
  end
  for k, sym in ipairs(UNOP_SYMBOLS) do
    local v = (sym == "#") and "abc" or 5
    local vText = (sym == "#") and '"abc"' or "5"
    add("UN" .. k, "1", "2", "0", "{[2]=" .. vText .. "}", UN_EVAL[sym](v), v, 2)
  end
  return { groups = groups, expected = math.floor(expected % DIGEST_P) }
end

return { plan = plan, DIGEST_P = DIGEST_P }
