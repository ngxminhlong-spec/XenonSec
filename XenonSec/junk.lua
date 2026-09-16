--------------------------------------------------------------------
-- XenonSec :: junk.lua
-- Sprinkles stack-neutral "junk" instructions (push a throwaway value,
-- immediately pop it) throughout each proto's compiled bytecode. Every
-- junk sequence has net-zero stack effect and touches no existing
-- stack slot, so it is safe to insert *anywhere* between two real
-- instructions regardless of what they are -- the only bookkeeping
-- required is remapping every jump target to the instruction's new
-- position, which this module does precisely.
--
-- This raises the cost of pattern-matching the instruction stream
-- (e.g. "GETVAR,GETVAR,BINOP always means a binary op") since real
-- patterns now have random noise instructions spliced through them,
-- and makes instruction-count/position-based fingerprinting across
-- builds useless (every build injects junk at different points).
--------------------------------------------------------------------

local Junk = {}

-- Instructions that need zero operands to push a value, paired with a
-- matching POP. (No LOADK here on purpose -- it would need a valid
-- const-pool index, and this pass runs before the pool is finalized.)
local JUNK_PUSH_OPS = { "LOADNIL", "LOADTRUE", "LOADFALSE", "NEWTABLE" }

local JUMP_OPS = {
  JMP = true, JMPIFNOT = true, JMPIFNIL = true, TESTANDJMP = true, TESTORJMP = true,
}

function Junk.inject(mod, rate)
  rate = rate or 0.12
  for _, proto in ipairs(mod.protos) do
    local old = proto.code
    local newCode = {}
    local map = {} -- map[oldIndex] = position that old instruction now occupies

    for i = 1, #old do
      if math.random() < rate then
        if math.random() < 0.3 then
          -- The richer, "complex" junk instruction: still net-zero
          -- stack effect (it pushes then immediately pops its own
          -- computed value), but does real internal work rather than
          -- a trivial push+pop pair -- harder to dismiss as obviously
          -- fake at a glance. Its operands are just noise; CPLX never
          -- reads real program state, so any values here are safe.
          newCode[#newCode + 1] = { op = "CPLX", a = math.random(0, 20), b = math.random(0, 999) }
        else
          local pushOp = JUNK_PUSH_OPS[math.random(1, #JUNK_PUSH_OPS)]
          newCode[#newCode + 1] = { op = pushOp }
          newCode[#newCode + 1] = { op = "POP", a = 1 }
          -- occasionally a slightly longer chain for more noise
          if math.random() < 0.35 then
            local pushOp2 = JUNK_PUSH_OPS[math.random(1, #JUNK_PUSH_OPS)]
            newCode[#newCode + 1] = { op = pushOp2 }
            newCode[#newCode + 1] = { op = "POP", a = 1 }
          end
        end
      end
      map[i] = #newCode + 1
      newCode[#newCode + 1] = old[i]
    end
    map[#old + 1] = #newCode + 1 -- one-past-the-end target (loop/if exits jump here)

    for _, instr in ipairs(newCode) do
      if JUMP_OPS[instr.op] then
        instr.a = map[instr.a]
      end
    end

    proto.code = newCode
  end
end

return Junk
