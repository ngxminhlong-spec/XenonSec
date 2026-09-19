local Junk = {}

local JUNK_PUSH_OPS = { "LOADNIL", "LOADTRUE", "LOADFALSE", "NEWTABLE" }

local JUMP_OPS = {
  JMP = true, JMPIFNOT = true, JMPIFNIL = true, TESTANDJMP = true, TESTORJMP = true,
}

local BINOPS_LIST = { "+", "-", "*", "/", "%", ".." }

function Junk.inject(mod, rate)
  rate = rate or 0.15
  for _, proto in ipairs(mod.protos) do
    local old = proto.code
    local newCode = {}
    local map = {}

    for i = 1, #old do
      local r = math.random()
      
      if r < rate then
        local junkType = math.random(1, 3)

        if junkType == 1 then
          
          newCode[#newCode + 1] = { op = "CPLX", a = math.random(0, 50), b = math.random(100, 999) }

        elseif junkType == 2 then
          -- Opaque-predicate branch: LOADTRUE then TESTORJMP (which PEEKs,
          -- it never pops). The truthy path must therefore land on the POP
          -- so the pushed value gets cleaned up -- jumping past the POP
          -- would leak one stack slot every time. The JMP is only
          -- reachable on the (impossible-here) falsy path. Net stack
          -- effect: zero.
          newCode[#newCode + 1] = { op = "LOADTRUE" }
          local testJmpIdx = #newCode + 1
          newCode[#newCode + 1] = { op = "TESTORJMP", a = 0, fixed = true }
          newCode[#newCode + 1] = { op = "JMP", a = #newCode + 3, fixed = true }
          newCode[#newCode + 1] = { op = "POP", a = 1 }
          newCode[testJmpIdx].a = #newCode -- -> the POP above, keeping the stack neutral

        elseif junkType == 3 then
          
          local pushOp = JUNK_PUSH_OPS[math.random(1, #JUNK_PUSH_OPS)]
          newCode[#newCode + 1] = { op = pushOp }
          newCode[#newCode + 1] = { op = "DUP" }
          newCode[#newCode + 1] = { op = "POP", a = 1 }
          newCode[#newCode + 1] = { op = "POP", a = 1 }
        end
      end

      
      map[i] = #newCode + 1
      newCode[#newCode + 1] = old[i]
    end

    
    map[#old + 1] = #newCode + 1

    
    for _, instr in ipairs(newCode) do
      if JUMP_OPS[instr.op] and not instr.fixed then
        -- injected junk jumps carry absolute newCode positions already
        -- (marked fixed); remapping them through `map` would retarget
        -- them at whatever old instruction happens to share the number.
        if map[instr.a] then
          instr.a = map[instr.a]
        end
      end
    end

    proto.code = newCode
  end
end

return Junk
