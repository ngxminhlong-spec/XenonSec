--------------------------------------------------------------------
-- XenonSec :: obfuscator/predicates.lua
-- Opaque predicates: number-theoretic identities that are always true (or always false) for every integer, used to guard dispatch branches.
--------------------------------------------------------------------

-- Nested opaque predicates: boolean expressions built from small
-- number-theoretic identities that are true for EVERY integer V (not
-- probabilistically true -- provably true for all V), so ANDing one
-- into a dispatch check never changes behavior. Genuinely nested
-- (each predicate is threaded inside the next via `and`, not just a
-- flat AND-list), and a fresh combination is picked per opcode per
-- build, so the exact expression differs both across opcodes within
-- one build and across builds of the same script.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local load = dofile(dir .. "loader.lua")
local numExpr = load("util").numExpr

-- Identity families. Each generator takes the probe expression p (a runtime
-- counter, always an integer in 0..65535) and returns one predicate with
-- fresh random constants. Every instance is true (or false) for every such
-- p, so the gate never changes behaviour. The constants differ per gate and
-- per build, so no fixed text pattern matches them.
local function K(n) return numExpr(n) end

local TRUE_FAMILIES = {
  -- p*(p+k) is even when k is odd
  function(p)
    local k = 2 * math.random(0, 49) + 1
    return string.format("((%s*(%s+%s))%%2==0)", p, p, K(k))
  end,
  -- (p+k)^2 - p*(p+2k) == k^2
  function(p)
    local k = math.random(1, 99)
    return string.format("(((%s+%s)*(%s+%s)-%s*(%s+%s))==%s)", p, K(k), p, K(k), p, p, K(2 * k), K(k * k))
  end,
  -- (k+1)p - kp - p == 0
  function(p)
    local k = math.random(2, 99)
    return string.format("((%s*%s-%s*%s-%s)==0)", K(k + 1), p, K(k), p, p)
  end,
  -- p mod m is below m
  function(p)
    local m = math.random(2, 999)
    return string.format("((%s%%%s)<%s)", p, K(m), K(m))
  end,
  -- p*p is never negative
  function(p)
    return string.format("((%s*%s)>=0)", p, p)
  end,
  -- (p-p)*k == 0
  function(p)
    local k = math.random(2, 99)
    return string.format("(((%s-%s)*%s)==0)", p, p, K(k))
  end,
}

-- Negations of the same families, for decoy branches that must never run.
local FALSE_FAMILIES = {
  function(p)
    local k = 2 * math.random(0, 49) + 1
    return string.format("((%s*(%s+%s))%%2==1)", p, p, K(k))
  end,
  function(p)
    local k = math.random(1, 99)
    return string.format("(((%s+%s)*(%s+%s)-%s*(%s+%s))~=%s)", p, K(k), p, K(k), p, p, K(2 * k), K(k * k))
  end,
  function(p)
    local k = math.random(2, 99)
    return string.format("((%s*%s-%s*%s-%s)~=0)", K(k + 1), p, K(k), p, p)
  end,
  function(p)
    local m = math.random(2, 999)
    return string.format("((%s%%%s)>=%s)", p, K(m), K(m))
  end,
  function(p)
    return string.format("((%s*%s)<0)", p, p)
  end,
}

local function pick(list) return list[math.random(1, #list)] end

-- Nested opaque predicate: `depth` identities joined with `and`, each one
-- drawn fresh (families may repeat with different constants).
local function genOpaquePredicate(probeName, depth)
  local chosen = {}
  for i = 1, depth do chosen[i] = pick(TRUE_FAMILIES)(probeName) end
  local expr = chosen[#chosen]
  for i = #chosen - 1, 1, -1 do
    expr = "(" .. chosen[i] .. " and " .. expr .. ")"
  end
  return expr
end

-- A provably-never-true guard for decoy dispatch branches: an always-false
-- identity ANDed with an always-true one.
local function genAlwaysFalsePredicate(probeName)
  local f = pick(FALSE_FAMILIES)(probeName)
  local t = pick(TRUE_FAMILIES)(probeName)
  return "(" .. f .. " and " .. t .. ")"
end

return {
  genAlwaysFalsePredicate = genAlwaysFalsePredicate,
  genOpaquePredicate = genOpaquePredicate,
}
