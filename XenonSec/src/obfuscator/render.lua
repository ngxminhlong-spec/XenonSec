--------------------------------------------------------------------
-- XenonSec :: obfuscator/render.lua
-- Renders the VM engine template: substitutes every %placeholder% with a per-build random identifier, opcode number or generated block.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local load = dofile(dir .. "loader.lua")
local _handlers = load("handlers")
local BINOP_TOKEN_NAMES, UNOP_TOKEN_NAMES, genDecoyHandlers, genOpHandlers = _handlers.BINOP_TOKEN_NAMES, _handlers.UNOP_TOKEN_NAMES, _handlers.genDecoyHandlers, _handlers.genOpHandlers
local _predicates = load("predicates")
local genOpaquePredicate = _predicates.genOpaquePredicate
local _util = load("util")
local randomIdent, substitute = _util.randomIdent, _util.substitute

-- Renders the VM engine template: any %N_OPNAME% becomes this build's
-- randomized opcode number; every other %ident% becomes a fresh random
-- identifier (memoized so the same placeholder always maps to the same
-- generated name within this one render).

local function renderTemplate(template, OPNUM, BINNUM, UNNUM, totalInstr, antiDebug, KV)
  local nameCache = {}
  local function ensureName(tok)
    if not nameCache[tok] then nameCache[tok] = randomIdent() end
    return nameCache[tok]
  end
  -- The probe counter lives on the frame, so handlers reach it as F.pr.
  local function probeExpr()
    return ensureName("F") .. "." .. ensureName("pr")
  end
  return substitute(template, function(tok)
    if tok == "ADCHECK" then
      if not antiDebug then return "" end
      -- Every 2048 dispatched instructions, re-probe for an attached hook.
      -- Cheap (one modulo + one gethook call), and it catches debuggers
      -- attached AFTER startup, which the one-shot check alone never sees.
      return "if " .. probeExpr() .. " % 2048 == 0 and " ..
             ensureName("adHook") .. "() then " .. ensureName("brick") .. "() end"
    end
    if tok:sub(1, 2) == "N_" then
      local opname = tok:sub(3)
      assert(OPNUM[opname], "unknown opcode placeholder " .. tok)
      return tostring(OPNUM[opname])
    end
    if tok:sub(1, 3) == "BN_" then
      local tokenName = tok:sub(4)
      for sym, name in pairs(BINOP_TOKEN_NAMES) do
        if name == tokenName then return tostring(BINNUM[sym]) end
      end
      error("unknown binop placeholder " .. tok)
    end
    if tok:sub(1, 3) == "UN_" then
      local tokenName = tok:sub(4)
      for sym, name in pairs(UNOP_TOKEN_NAMES) do
        if name == tokenName then return tostring(UNNUM[sym]) end
      end
      error("unknown unop placeholder " .. tok)
    end
    if tok:sub(1, 4) == "OPQ_" then
      -- A fresh nested opaque predicate per opcode, referencing the
      -- shared per-call `probe` counter (always some changing integer
      -- at the point it's checked -- the identities hold for any V).
      -- Depth scales with program size too, same reasoning as the
      -- decoy branches below: a tiny script can afford to spend more
      -- relative weight per dispatch since it has so few of them, while
      -- a huge script keeps depth modest since this cost is paid on
      -- every single opcode dispatch at runtime. Capped at 8 well
      -- below the 15-identity pool so genOpaquePredicate never has to
      -- draw more unique identities than exist.
      local probe = probeExpr()
      local depthBase = 3 + math.floor(2000 / ((totalInstr or 0) + 400))
      if depthBase > 8 then depthBase = 8 end
      return genOpaquePredicate(probe, depthBase + math.random(0, 2))
    end
    if tok:sub(1, 2) == "K_" then
      return tostring(KV[tok:sub(3)])
    end
    if tok == "NEWREGS" then
      if KV and KV.proxify then return "setmetatable({[0] = {}}, " .. ensureName("RMETA") .. ")" end
      return "{}"
    end
    if tok == "NEWVARS" then
      if KV and KV.proxify then return "setmetatable({[0] = {}}, " .. ensureName("VMETA") .. ")" end
      return "{}"
    end
    if tok == "PROXYMETA" then
      if not (KV and KV.proxify) then return "" end
      -- ProxifyLocal. A proxy keeps its real storage in slot [0] (a raw key, so
      -- it never reaches __index). Each stored value sits in a fresh box {v}, so
      -- a register or local never holds a value directly.
      --   RMETA: register i lives at store[(i*PA + PB) % PM]: the register number
      --          never appears as a table key.
      --   VMETA: captured local `name` lives at store[name].
      local RM, VM = ensureName("RMETA"), ensureName("VMETA")
      local pt, pk, pv, pb = ensureName("pxt"), ensureName("pxk"), ensureName("pxv"), ensureName("pxb")
      local A, B, M = tostring(KV.PA), tostring(KV.PB), tostring(KV.PM)
      return table.concat({
        "local " .. RM .. " = {}",
        RM .. ".__index = function(" .. pt .. ", " .. pk .. ") local " .. pb .. " = " .. pt .. "[0][(" .. pk .. " * " .. A .. " + " .. B .. ") % " .. M .. "]; if " .. pb .. " then return " .. pb .. "[1] end return nil end",
        RM .. ".__newindex = function(" .. pt .. ", " .. pk .. ", " .. pv .. ") " .. pt .. "[0][(" .. pk .. " * " .. A .. " + " .. B .. ") % " .. M .. "] = { " .. pv .. " } end",
        "local " .. VM .. " = {}",
        VM .. ".__index = function(" .. pt .. ", " .. pk .. ") local " .. pb .. " = " .. pt .. "[0][" .. pk .. "]; if " .. pb .. " then return " .. pb .. "[1] end return nil end",
        VM .. ".__newindex = function(" .. pt .. ", " .. pk .. ", " .. pv .. ") " .. pt .. "[0][" .. pk .. "] = { " .. pv .. " } end",
      }, "\n")
    end
    if tok == "PERIODIC" then
      -- Every 4096 steps, verify one proto (rotating through them), so an
      -- edit made after startup is caught as well.
      local pidx = ensureName("pidx")
      local verify = "if " .. probeExpr() .. " % 4096 == 0 then local " .. pidx .. " = (" ..
             probeExpr() .. " / 4096) % #" .. ensureName("protos") .. " + 1; if not " ..
             ensureName("vp") .. "(" .. pidx .. ") then " .. ensureName("brick") .. "() end end"
      -- Decoded constants are cached in a plain table. Flush that cache now and
      -- then, so a dump of the table sees only the constants used lately; each
      -- one is decoded again on its next use.
      local flush = ""
      if KV and KV.flush then
        flush = " if " .. probeExpr() .. " % " .. tostring(KV.flushEvery or 65536) .. " == 0 then for " ..
                ensureName("fk") .. " in pairs(" .. ensureName("consts") .. ") do rawset(" ..
                ensureName("consts") .. ", " .. ensureName("fk") .. ", nil) end end"
      end
      return verify .. flush
    end
    if tok == "DECOY_HANDLERS" then
      -- Scale with program size too: a big real program earns a
      -- proportionally bigger decoy dispatch chain, not just the same
      -- flat handful a one-liner gets.
      return genDecoyHandlers(ensureName, KV.decoyCount, probeExpr, KV.freeKey) .. "\n" ..
             genOpHandlers(ensureName, probeExpr, OPNUM, BINNUM, UNNUM)
    end
    return ensureName(tok)
  end)
end

return {
  renderTemplate = renderTemplate,
}
