--------------------------------------------------------------------
-- XenonSec :: obfuscator/opcodes.lua
-- The canonical opcode list (must match the names compiler.lua emits), the operator symbols taken from compiler.lua, and which operand field of each opcode holds a constant-pool index.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local Compiler = dofile(dir .. "../compiler.lua")

--------------------------------------------------------------------
-- Opcode list -- MUST exactly match the opcode names compiler.lua
-- emits. Order here doesn't matter; numbers are assigned randomly.
--------------------------------------------------------------------

local OPCODES = {
  "LOADK", "LOADNIL", "LOADTRUE", "LOADFALSE", "MOVE",
  "GETVAR", "SETVAR", "DECLCELL",
  "NEWTABLE", "GETIDX", "SETIDX", "GETIDXK", "SETIDXK", "SETLISTM", "SELF",
  "CLOSURE", "VARARG", "CALL", "CALLM", "RET", "RETM",
  "JMP", "JF", "JT", "JNIL", "NEWSCOPE", "POPSCOPE", "JUNK",
}

-- Instructions whose `a` field is a constant-pool index (everything
-- else's a/b/c fields are raw integers: jump targets, proto indices,
-- register slot numbers, argument counts, etc.)
local BINOP_SYMBOLS = Compiler.BINOP_SYMBOLS
local UNOP_SYMBOLS = Compiler.UNOP_SYMBOLS
-- One opcode per binary operator (register and constant right-hand forms)
-- and per unary operator.
for k = 1, #BINOP_SYMBOLS do
  OPCODES[#OPCODES + 1] = "BIN" .. k
  OPCODES[#OPCODES + 1] = "BINK" .. k
end
for k = 1, #UNOP_SYMBOLS do
  OPCODES[#OPCODES + 1] = "UN" .. k
end

-- Which operand field of each opcode holds a constant-pool index (the rest
-- are raw integers: registers, counts, jump targets, proto indices).
local CONST_FIELD = {
  LOADK = "b", GETVAR = "b", SETVAR = "b", DECLCELL = "b", SETIDXK = "b",
  GETIDXK = "c", SELF = "c", SETLISTM = "c", JUNK = "b",
}
local function constField(op)
  if CONST_FIELD[op] then return CONST_FIELD[op] end
  if op:sub(1, 4) == "BINK" then return "c" end
  return nil
end

return {
  BINOP_SYMBOLS = BINOP_SYMBOLS,
  OPCODES = OPCODES,
  UNOP_SYMBOLS = UNOP_SYMBOLS,
  constField = constField,
}
