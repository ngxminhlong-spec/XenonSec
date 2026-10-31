--------------------------------------------------------------------
-- XenonSec :: obfuscator/handlers.lua
-- Generators for the extra handler code emitted into the VM: decoy handlers that can never run, and real operator handlers that dispatch through the per-build BINOPS/UNOPS tables.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local load = dofile(dir .. "loader.lua")
local _opcodes = load("opcodes")
local BINOP_SYMBOLS, UNOP_SYMBOLS = _opcodes.BINOP_SYMBOLS, _opcodes.UNOP_SYMBOLS
local _predicates = load("predicates")
local genAlwaysFalsePredicate, genOpaquePredicate = _predicates.genAlwaysFalsePredicate, _predicates.genOpaquePredicate

-- Safe placeholder-token names for operator symbols (can't embed "+"
-- etc directly in a %word% token).
local BINOP_TOKEN_NAMES = {
  ["+"] = "PLUS", ["-"] = "MINUS", ["*"] = "MUL", ["/"] = "DIV",
  ["%"] = "MOD", ["^"] = "POW", [".."] = "CONCAT",
  ["=="] = "EQ", ["~="] = "NE", ["<"] = "LT", [">"] = "GT",
  ["<="] = "LE", [">="] = "GE", ["//"] = "IDIV",
}
local UNOP_TOKEN_NAMES = { ["-"] = "UNM", ["not"] = "NOT", ["#"] = "LEN" }

-- Decoy dispatch branches: syntactically real Lua, guarded by an
-- always-false predicate so they can never execute (a static reader
-- can't tell that from reading the condition alone -- same shape as
-- the real, always-true guards on every genuine branch). Pure
-- analysis noise: inflates the apparent opcode count and makes a
-- purely-structural read of the dispatch chain unreliable.
local function genDecoyHandlers(ensureName, count, probeExpr, freeKey)
  local H, F, ins = ensureName("H"), ensureName("F"), ensureName("ins")
  local ip, regsF = ensureName("ip"), ensureName("regs")
  local x2, x3, x4 = ensureName("x2"), ensureName("x3"), ensureName("x4")
  local BINOPS, consts = ensureName("BINOPS"), ensureName("consts")

  -- Plausible bodies over the real frame fields. They are never reachable:
  -- their keys come from the same pool as the real opcodes but are never
  -- assigned to one, so no encoded instruction decodes to them. Each one
  -- is written in the same wrapper as a real handler (gate, body, ip + 1),
  -- so a reader can't tell the two apart by shape.
  local flavors = {
    function()
      local dv = ensureName("dv" .. tostring(math.random(1, 99999)))
      return string.format("local %s = %s.%s[%s.%s]; %s.%s[%s.%s] = %s", dv, F, regsF, F, x2, F, regsF, F, x2, dv)
    end,
    function()
      return string.format("local r = %s.%s; r[%s.%s] = %s[%s.%s]", F, regsF, F, x2, consts, F, x4)
    end,
    function()
      local tv = ensureName("tv" .. tostring(math.random(1, 99999)))
      return string.format("local %s = %s.%s[%s.%s] or 0; %s.%s[%s.%s] = %s * 2",
        tv, F, regsF, F, x3, F, regsF, F, x2, tv)
    end,
    function(key)
      return string.format("local r = %s.%s; r[%s.%s] = %s[%d](r[%s.%s], r[%s.%s])",
        F, regsF, F, x2, BINOPS, key, F, x3, F, x4)
    end,
  }

  local lines = {}
  for _ = 1, count do
    local key = freeKey()
    local cond = genAlwaysFalsePredicate(probeExpr())
    local body = flavors[math.random(1, #flavors)](key)
    lines[#lines + 1] = string.format(
      "%s[%d] = function(%s, %s) if not (%s) then error() end %s %s.%s = %s.%s + 1 end",
      H, key, F, ins, cond, body, F, ip, F, ip)
  end
  return table.concat(lines, "\n")
end

-- Handlers for the operator opcodes. Each reads its operands from the frame
-- (a = x2 destination, b = x3, c = x4) and writes the destination register.
local function genOpHandlers(ensureName, probeExpr, OPNUM, BINNUM, UNNUM)
  local H, F, ins = ensureName("H"), ensureName("F"), ensureName("ins")
  local regsF, ipF = ensureName("regs"), ensureName("ip")
  local x2, x3, x4 = ensureName("x2"), ensureName("x3"), ensureName("x4")
  local BINOPS, UNOPS, consts = ensureName("BINOPS"), ensureName("UNOPS"), ensureName("consts")
  local lines = {}
  local function handler(opnum, body)
    local gate = genOpaquePredicate(probeExpr(), 3)
    lines[#lines + 1] = string.format(
      "%s[%d] = function(%s, %s) if not (%s) then error() end %s %s.%s = %s.%s + 1 end",
      H, opnum, F, ins, gate, body, F, ipF, F, ipF)
  end
  for k, sym in ipairs(BINOP_SYMBOLS) do
    local num = BINNUM[sym]
    handler(OPNUM["BIN" .. k], string.format(
      "local r = %s.%s; r[%s.%s] = %s[%d](r[%s.%s], r[%s.%s]);",
      F, regsF, F, x2, BINOPS, num, F, x3, F, x4))
    handler(OPNUM["BINK" .. k], string.format(
      "local r = %s.%s; r[%s.%s] = %s[%d](r[%s.%s], %s[%s.%s]);",
      F, regsF, F, x2, BINOPS, num, F, x3, consts, F, x4))
  end
  for k, sym in ipairs(UNOP_SYMBOLS) do
    local num = UNNUM[sym]
    handler(OPNUM["UN" .. k], string.format(
      "local r = %s.%s; r[%s.%s] = %s[%d](r[%s.%s]);",
      F, regsF, F, x2, UNOPS, num, F, x3))
  end
  return table.concat(lines, "\n")
end

return {
  BINOP_TOKEN_NAMES = BINOP_TOKEN_NAMES,
  UNOP_TOKEN_NAMES = UNOP_TOKEN_NAMES,
  genDecoyHandlers = genDecoyHandlers,
  genOpHandlers = genOpHandlers,
}
