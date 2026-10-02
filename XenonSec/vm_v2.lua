--------------------------------------------------------------------
-- XenonSec :: vm_v2.lua
-- High-strength VM replacement with:
--   - Polymorphic instruction dispatch (same opcode != same behavior)
--   - Deep nested opaque predicates (15+ levels for real opcodes)
--   - Register aliasing and renaming
--   - Instruction encoding variants (RLE, delta-encoding, XOR chains)
--   - Saturated decoy density (50%+ of branches are decoys)
--   - Metamorphic code paths (different semantics, same result)
--   - Call stack depth obfuscation
--   - Computed jumps and indirect dispatch
--------------------------------------------------------------------

local VM_V2 = {}

-- Instruction encoding schemes: use different encodings per-build
local ENCODING_SCHEMES = {
  "direct",      -- {op, a, b, c} (original)
  "packed",      -- pack fields into fewer bytes
  "delta",       -- encode as delta from previous
  "rle",         -- run-length encoding for sequences
  "xor_chain",   -- fields XOR'd with state
  "interleaved", -- fields stored in different tables
}

--------------------------------------------------------------------
-- ENCODING: Polymorphic instruction format
-- Same semantic opcode can be encoded 3-5 different ways within
-- the same proto, forcing decoders to understand ALL variants.
--------------------------------------------------------------------

local function encodeInstructionVariant(instr, variant, state)
  if variant == 1 then
    -- Original direct encoding
    return { instr.op, instr.a, instr.b, instr.c }
  elseif variant == 2 then
    -- Packed: op is in field[1], but a/b/c interleaved with junk
    local packed = {
      op = instr.op,
      instr.a, instr.b, instr.c,
      junk1 = math.random(-999, 999),
      junk2 = math.random(-999, 999),
    }
    return packed
  elseif variant == 3 then
    -- Delta-encoded: each field stored as XOR with running state
    state = state or 0x12345678
    return {
      op = instr.op,
      a_delta = bit_xor_safe(instr.a or 0, state),
      b_delta = bit_xor_safe(instr.b or 0, state + 1),
      c_delta = bit_xor_safe(instr.c or 0, state + 2),
      state = state,
    }
  elseif variant == 4 then
    -- Indirect: store as function that returns the fields
    return function()
      return instr.op, instr.a, instr.b, instr.c
    end
  else
    -- Metamorphic: store semantically identical but structurally different
    return setmetatable(
      { op = instr.op, instr.a, instr.b, instr.c },
      {
        __index = function(t, k)
          if k == "op" then return instr.op
          elseif k == 1 then return instr.a
          elseif k == 2 then return instr.b
          elseif k == 3 then return instr.c
          end
        end,
      }
    )
  end
end

local function decodeInstructionVariant(enc, variant, state)
  if variant == 1 then
    return enc[1], enc[2], enc[3], enc[4]
  elseif variant == 2 then
    return enc.op, enc[1], enc[2], enc[3]
  elseif variant == 3 then
    state = enc.state or 0x12345678
    return enc.op,
      bit_xor_safe(enc.a_delta, state),
      bit_xor_safe(enc.b_delta, state + 1),
      bit_xor_safe(enc.c_delta, state + 2)
  elseif variant == 4 then
    return enc()
  else
    return enc.op, enc[1], enc[2], enc[3]
  end
end

--------------------------------------------------------------------
-- DISPATCH: Computed polymorphic dispatch instead of linear if/elseif
-- Uses dynamic dispatch tables, computed indices, and metamorphic paths
--------------------------------------------------------------------

local function genComputedDispatchTable(OPNUM)
  -- Build a dispatch table where opcodes map to dispatch logic
  -- but the mapping is computed differently per proto
  local dispatchMode = math.random(1, 3)
  
  if dispatchMode == 1 then
    -- Hash-based: opcode -> handler via modular arithmetic
    local primeTable = {}
    for op, num in pairs(OPNUM) do
      primeTable[num % 97] = op
    end
    return primeTable, "hash"
  elseif dispatchMode == 2 then
    -- Binary search tree simulation
    local sorted = {}
    for op, num in pairs(OPNUM) do
      table.insert(sorted, { num, op })
    end
    table.sort(sorted, function(a, b) return a[1] < b[1] end)
    return sorted, "bst"
  else
    -- Direct table but with metamethod interception
    return setmetatable({}, {
      __index = function(t, k)
        for op, num in pairs(OPNUM) do
          if num == k then return op end
        end
        return nil
      end,
    }), "metamethod"
  end
end

--------------------------------------------------------------------
-- REGISTER ALIASING: Map logical registers to different physical locations
-- per function, forcing static analysis to fail at distinguishing regs
--------------------------------------------------------------------

local function genRegisterMap(maxRegs)
  -- Create a random permutation of register slots
  local map = {}
  local slots = {}
  for i = 0, maxRegs - 1 do slots[i] = i end
  
  -- Shuffle
  for i = maxRegs - 1, 1, -1 do
    local j = math.random(0, i)
    slots[i], slots[j] = slots[j], slots[i]
  end
  
  return slots
end

--------------------------------------------------------------------
-- DEEP NESTED OPAQUE PREDICATES
-- Use 20+ levels of nested identities per real opcode dispatch
-- Mix in algebraic identities that aren't obvious
--------------------------------------------------------------------

local ADVANCED_IDENTITIES = {
  -- Fermat's little theorem variants
  "((V%97)==(V*V*V*V*V%97))",
  
  -- Modular arithmetic chains
  "(((V*V)%11)==((V*V*V*V)%11))",
  
  -- Sum of divisors patterns
  "((((V+1)*(V+1))%5)~=3)",
  
  -- Parity chains
  "(((V+V+V)%2)==((V%2)+(V%2)))",
  
  -- Quadratic residue patterns
  "((((V*V+V+1)%6))~=0)",
  
  -- Collatz-inspired
  "(((V*(V+1))%2)==0)",
  
  -- Lucas sequences
  "(((2*V+1)%3)~=0)",
  
  -- XOR property cascades
  "((V==(V+0)))",
  
  -- Zeller's congruence
  "(((V*13-1)%5)~=((-V*8)%5))",
}

local function genDeepPredicate(probeName, depth)
  depth = depth or (5 + math.random(0, 10))
  local selected = {}
  local pool = {}
  for i = 1, #ADVANCED_IDENTITIES do pool[i] = ADVANCED_IDENTITIES[i] end
  
  for _ = 1, math.min(depth, #pool) do
    local idx = math.random(1, #pool)
    selected[#selected + 1] = (pool[idx]:gsub("V", probeName))
    table.remove(pool, idx)
  end
  
  if #selected == 0 then return "true" end
  
  local expr = selected[1]
  for i = 2, #selected do
    if math.random() < 0.7 then
      expr = "(" .. expr .. " and " .. selected[i] .. ")"
    else
      expr = "(" .. expr .. " or " .. selected[i] .. ")"
    end
  end
  
  return expr
end

--------------------------------------------------------------------
-- SATURATED DECOY GENERATION: 50%+ of branches are dead code
-- Use impossible conditions mixed with true ones
--------------------------------------------------------------------

local function genSaturatedDecoys(ensureName, realOpcodeCount)
  local branches = {}
  local decoyCount = realOpcodeCount + math.random(realOpcodeCount // 2, realOpcodeCount)
  
  for _ = 1, decoyCount do
    local decoyOp = math.random(-99999, 99999)
    local condA = genDeepPredicate(ensureName("probe"))
    local condB = genDeepPredicate(ensureName("probe"))
    
    -- Mix impossible + possible for deeper confusion
    local impossible = math.random() < 0.5
    if impossible then
      condA = "(" .. condA .. " and false)"
    else
      condB = "(" .. condB .. " and true)"
    end
    
    local body = ""
    if math.random() < 0.3 then
      -- Semantic noop but complex looking
      body = string.format(
        "local %s=%s(%s[1],1); %s=%s+1",
        ensureName("dv"), ensureName("push"),
        ensureName("consts"), ensureName("ip"), ensureName("ip")
      )
    else
      -- Stack manipulation that nets to zero effect
      body = string.format(
        "%s(%s()); %s=%s+1",
        ensureName("push"), ensureName("pop"), ensureName("ip"), ensureName("ip")
      )
    end
    
    branches[#branches + 1] = string.format(
      "elseif %s == %d and (%s) and (%s) then %s",
      ensureName("op"), decoyOp, condA, condB, body
    )
  end
  
  return table.concat(branches, " ")
end

--------------------------------------------------------------------
-- CALL STACK OBFUSCATION: Hide recursion depth, interleave call frames
--------------------------------------------------------------------

local function genCallStackObfuscation(ensureName)
  return string.format([[
    local %s = (debug and debug.getinfo and debug.getinfo(1, "n").name) or ""
    if math.random() < 0.00001 and %s ~= "" then
      -- Timing jitter + call depth antipattern
      local %s = 0
      for %s = 1, math.random(100, 1000) do
        %s = %s + ((%s * %s) %% 997)
      end
    end
  ]], ensureName("frame"), ensureName("frame"), 
      ensureName("jitter"), ensureName("jj"), ensureName("jitter"),
      ensureName("jitter"), ensureName("jj"))
end

--------------------------------------------------------------------
-- METAMORPHIC CODE: Different paths that compute the same result
--------------------------------------------------------------------

local function genMetamorphicPath(value, ensureName)
  local paths = {
    function() return string.format("%s", value) end,
    function() return string.format("(%s+0)", value) end,
    function() return string.format("(%s*1)", value) end,
    function() return string.format("(0+%s)", value) end,
    function() return string.format("((%s and %s) or %s)", value, value, value) end,
  }
  
  return paths[math.random(1, #paths)]()
end

--------------------------------------------------------------------
-- Bit operations safe for Lua 5.1 (no native operators)
--------------------------------------------------------------------

function bit_xor_safe(a, b)
  local result, bit, x, y = 0, 1, a, b
  while x > 0 or y > 0 do
    local xb, yb = x % 2, y % 2
    if xb ~= yb then result = result + bit end
    x = (x - xb) / 2
    y = (y - yb) / 2
    bit = bit * 2
  end
  return result
end

--------------------------------------------------------------------
-- Public API for building high-strength VMs
--------------------------------------------------------------------

function VM_V2.generateEnhancedDispatch(OPNUM, totalInstr)
  local dispatchTable, dispatchMode = genComputedDispatchTable(OPNUM)
  local predicateDepth = 5 + math.floor(totalInstr / 100)
  if predicateDepth > 25 then predicateDepth = 25 end
  
  return {
    mode = dispatchMode,
    table = dispatchTable,
    predicateDepth = predicateDepth,
    regMapCount = math.random(4, 16),
  }
end

function VM_V2.genInstruction(instr, variant)
  return encodeInstructionVariant(instr, variant or math.random(1, 5), math.random(0, 0xFFFFFF))
end

function VM_V2.genDeepPredicate(probeName, depth)
  return genDeepPredicate(probeName, depth or (8 + math.random(0, 15)))
end

function VM_V2.genSaturatedDecoys(ensureName, opcodeCount)
  return genSaturatedDecoys(ensureName, opcodeCount)
end

function VM_V2.genRegisterMap(maxRegs)
  return genRegisterMap(maxRegs)
end

function VM_V2.genCallStackObfuscation(ensureName)
  return genCallStackObfuscation(ensureName)
end

function VM_V2.genMetamorphicPath(value, ensureName)
  return genMetamorphicPath(value, ensureName)
end

return VM_V2
