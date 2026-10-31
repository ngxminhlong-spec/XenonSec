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

local OPAQUE_IDENTITIES = {
  "((V*V-V)%2==0)",                          -- v^2 - v is always even
  "(((V+1)*(V+1)-V*V-2*V-1)==0)",             -- (v+1)^2 - v^2 - 2v - 1 == 0
  "((V%2)*(V%2)==(V%2))",                     -- v mod 2 is idempotent under squaring
  "(((V*V)%4)~=2)",                           -- v^2 mod 4 is never 2
  "(((V-V)*(V+7))==0)",                       -- v - v is always 0
  "((V*3-V*2-V)==0)",                         -- 3v - 2v - v == 0
  "(((V*V+V)%2)==0)",                         -- v^2 + v is always even
  "(((V*(V+1)*(V+2))%6)==0)",                 -- product of 3 consecutive ints divisible by 6
  "((((V*V*V)-V)%6)==0)",                     -- v^3 - v divisible by 6 (v(v-1)(v+1))
  "(((V+V)%2)==0)",                           -- v + v is always even
  "((V*V)>=0)",                               -- a square is never negative
  "((V==V))",                                 -- reflexivity
  "(not (V~=V))",                             -- negated-inequality reflexivity
  "(((V*5-V*4-V))==0)",                       -- 5v - 4v - v == 0
  "(((V*V-V*V))==0)",                         -- v^2 - v^2 == 0
}

-- Logical negations of the same identities, for decoy branches that
-- must NEVER be taken (see genAlwaysFalsePredicate below).
local FALSE_IDENTITIES = {
  "((V*V-V)%2==1)",
  "(((V+1)*(V+1)-V*V-2*V-1)~=0)",
  "(((V*V)%4)==2)",
  "(((V-V)*(V+7))~=0)",
  "((V*3-V*2-V)~=0)",
  "(((V*V+V)%2)==1)",
  "(((V*(V+1)*(V+2))%6)==1)",
  "((V*V)<0)",
  "((V~=V))",
}

local function genOpaquePredicate(probeName, depth)
  local pool = {}
  for i, v in ipairs(OPAQUE_IDENTITIES) do pool[i] = v end
  local chosen = {}
  for _ = 1, depth do
    local idx = math.random(1, #pool)
    chosen[#chosen + 1] = (pool[idx]:gsub("V", probeName))
    table.remove(pool, idx)
  end
  local expr = chosen[#chosen]
  for i = #chosen - 1, 1, -1 do
    expr = "(" .. chosen[i] .. " and " .. expr .. ")"
  end
  return expr
end

-- A provably-never-true guard for decoy dispatch branches: the body
-- behind it is genuine, syntactically valid Lua that a static reader
-- has to spend time understanding, but it can never execute -- an
-- always-false identity ANDed with an always-true one (so it's not
-- trivially a single obviously-negated check sitting alone).
local function genAlwaysFalsePredicate(probeName)
  local falseIdx = math.random(1, #FALSE_IDENTITIES)
  local trueIdx = math.random(1, #OPAQUE_IDENTITIES)
  local f = (FALSE_IDENTITIES[falseIdx]:gsub("V", probeName))
  local t = (OPAQUE_IDENTITIES[trueIdx]:gsub("V", probeName))
  return "(" .. f .. " and " .. t .. ")"
end

return {
  genAlwaysFalsePredicate = genAlwaysFalsePredicate,
  genOpaquePredicate = genOpaquePredicate,
}
