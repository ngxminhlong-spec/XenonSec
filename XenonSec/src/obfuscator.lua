--------------------------------------------------------------------
-- XenonSec :: obfuscator.lua
-- Turns a Lua 5.1 source file into a single self-contained, obfuscated
-- output file that runs on a randomized-opcode bytecode VM embedded
-- in the output itself.
--
-- This file is the pipeline entry point: it runs the AST passes, then
-- hands the compiled module to the bundler and template renderer. The
-- heavy lifting lives in src/obfuscator/ (see the README for the map).
--------------------------------------------------------------------

local scriptDir = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./")
local function req(name) return dofile(scriptDir .. name) end
local load = dofile(scriptDir .. "obfuscator/loader.lua")

local Parser = req("parser.lua")
local Fold = req("fold.lua")
local SSA = req("ssa.lua")
local Localize = req("localize.lua")
local Renamer = req("renamer.lua")
local Capture = req("capture.lua")
local Compiler = req("compiler.lua")
local Junk = req("junk.lua")
local Passes = req("passes.lua")

local _bundle = load("bundle")
local _crypto = load("crypto")
local _render = load("render")
local _stdlib = load("stdlib")
local _util = load("util")
local ENV_CHECK_NAMES, buildBundle = _bundle.ENV_CHECK_NAMES, _bundle.buildBundle
local CIPHER, setCipherParams = _crypto.CIPHER, _crypto.setCipherParams
local renderTemplate = _render.renderTemplate
local buildStdBlock, encName, rewriteStd = _stdlib.buildStdBlock, _stdlib.encName, _stdlib.rewriteStd
local minifyTemplateText, randomIdent, substitute = _util.minifyTemplateText, _util.randomIdent, _util.substitute
local FOOTER_TEMPLATE = load("templates/footer")
local HEADER_TEMPLATE = load("templates/header")
local VM_TEMPLATE = load("templates/vm")
local CORE_BLOCKS = load("templates/core_handlers")
local _tm = load("typemangler")
local buildTypeMangler, scatterType = _tm.buildTypeMangler, _tm.scatterType

math.randomseed(os.time() + (tonumber(tostring({}):match("0x(%x+)"), 16) or 0))
-- burn a few values; Lua's stock PRNG is weak but this is for build-time
-- diversification (opcode shuffles / keys), not cryptographic security.
for _ = 1, 8 do math.random() end

--------------------------------------------------------------------
-- Public entry point
--------------------------------------------------------------------

local DEFAULTS = {
  minify = true,
  junkRate = 0.22, -- only used if size-based auto-scaling is somehow bypassed; see obfuscate()
  decoyConstants = nil, -- nil => auto-scaled to input size, see obfuscate()
  localizeGlobals = true,
  fold = true,
  ssa = true,
  luau = false,
  antiTamper = true,   -- checksum-verified payload; zero false-positive risk, on by default
  flushConsts = true,  -- periodic flush of the decoded-constant cache (see PERIODIC)
  flushEvery = 65536,  -- steps between flushes: a dump sees only recently used constants
  antiDebug = false,   -- debug-hook, native-hook and env-logger checks; false-positive risk, opt-in
  proxify = false,     -- ProxifyLocal: registers and captured locals live in proxy objects (slower)
  strength = 2,        -- 1..4: scales decoy handlers and decoy constants (size vs. clutter)
}

local function obfuscateOnce(source, chunkname, opts)
  opts = opts or {}
  setCipherParams() -- fresh cipher constants for every build (before any encryption)
  -- A leading shebang line (`#!/usr/bin/env lute`) is skipped, the same
  -- way the standard Lua loader skips it for files. It's blanked rather
  -- than removed, so every later line keeps its original line number.
  if source:sub(1, 1) == "#" then
    source = source:gsub("^[^\n]*", "", 1)
  end
  -- Captured BEFORE the defaults fill below, so we can tell "caller
  -- explicitly asked for this" apart from "fell through to a default"
  -- -- auto-scaling (below) only kicks in for the latter.
  local explicitJunkRate = opts.junkRate
  local explicitDecoys = opts.decoyConstants
  for k, v in pairs(DEFAULTS) do
    if opts[k] == nil then opts[k] = v end
  end

  local ast = Parser.parse(source, chunkname or "input", opts.luau)
  -- Computed on the pristine AST (capture analysis only cares about
  -- lexical structure, which Fold/SSA never change) so SSA can safely
  -- know which names are reachable-via-closure and must never be
  -- treated as safe-to-cache across a function call.
  local earlyCaptured = Capture.analyze(ast)
  if opts.fold then Fold.apply(ast) end
  if opts.ssa then
    SSA.apply(ast, earlyCaptured)
    if opts.fold then Fold.apply(ast) end -- a second fold pass catches arithmetic SSA just exposed
  end
  if opts.localizeGlobals then Localize.apply(ast) end
  Renamer.resolve(ast)
  local captured = Capture.analyze(ast)
  local mod = Compiler.compile(ast, captured)

  -- Auto-scale hardening density to the size of the *real* program
  -- (measured before junk is injected, so the decision isn't fed by
  -- its own output). A flat rate/count tuned for an "average" script
  -- makes small scripts look thin and leaves large scripts under-
  -- hardened relative to how much real structure they have to hide
  -- noise inside -- so both ends scale instead of using one constant.
  -- An explicit --junk/--decoys value from the caller always wins.
  local totalInstr = 0
  for _, proto in ipairs(mod.protos) do totalInstr = totalInstr + #proto.code end
  local totalConsts = #mod.consts

  if explicitJunkRate == nil then
    -- Tiny scripts (few real instructions) get a much higher junk
    -- *percentage*, since a flat rate barely adds any real bulk to
    -- them; the rate settles toward a lower floor as the program's
    -- own size grows and starts pulling its own weight.
    local scaled = 0.55 - (totalInstr / 500)
    if scaled < 0.20 then scaled = 0.20 end
    if scaled > 0.55 then scaled = 0.55 end
    opts.junkRate = scaled
  end

  if explicitDecoys == nil then
    -- Grows with both the real constant pool and the real instruction
    -- count, plus a floor so even a near-empty script still ships a
    -- meaningful amount of decoy noise, and a cap so a huge input
    -- doesn't blow the decoy pool up past the point of diminishing
    -- returns.
    local scaled = math.floor(totalConsts * 1.5 + totalInstr / 8) + 16 + math.random(0, 24)
    scaled = scaled * (opts.strength or 1)
    if scaled > 500 * (opts.strength or 1) then scaled = 500 * (opts.strength or 1) end
    opts.decoyConstants = scaled
  end

  if opts.junkRate and opts.junkRate > 0 then Junk.inject(mod, opts.junkRate) end
  if opts.flatten ~= false then Passes.flatten(mod, math.random, opts.strength or 1) end
  Passes.insertStateBarriers(mod)
  local bundle = buildBundle(mod, opts)
  -- Luau type syntax (TypeMangler decoys, frame annotations) is emitted only
  -- for Luau output that wants it. typeMangler = false keeps Luau output
  -- plain-Lua-parseable, for hosts that aren't Luau.
  local useTypes = (opts.luau and opts.typeMangler ~= false) and true or false

  local vmSrc = opts.minify and minifyTemplateText(VM_TEMPLATE) or VM_TEMPLATE
  -- ProxifyLocal register map: i -> (i*PA + PB) % PM. PA is odd, so the map is
  -- a bijection on [0, PM). Chosen per build.
  local PROXY_M = 1048576
  local proxyA = 2 * math.random(0, 524287) + 1
  local proxyB = math.random(0, PROXY_M - 1)
  local engineSrc = renderTemplate(vmSrc, bundle.OPNUM, bundle.BINNUM, bundle.UNNUM, totalInstr, opts.antiDebug,
    { M1 = bundle.saltM1, M2 = bundle.saltM2, M3 = bundle.saltM3, SA = bundle.stepA, SB = bundle.stepB, SC = bundle.stepC, MOD = bundle.mod, strength = opts.strength or 1,
      proxify = opts.proxify and true or false, PA = proxyA, PB = proxyB, PM = PROXY_M,
      freeKey = bundle.freeKey, decoyCount = bundle.decoyCount,
      flush = opts.flushConsts and true or false, flushEvery = opts.flushEvery or 65536,
      coreBlocks = CORE_BLOCKS, wm = bundle.watermarkIdx, three = bundle.threeIdx,
      minifyFn = opts.minify and minifyTemplateText or nil, luauTypes = useTypes,
      scatterType = scatterType })

  local vaultLit = table.concat(bundle.vault, ",")
  local kmapLit = table.concat(bundle.kmap, ",")
  local cipherLits = {}
  for i, c in ipairs(bundle.cipherConsts) do
    -- %q leaves bytes >= 128 raw, which makes the file invalid UTF-8.
    -- Escape them as 3-digit decimal escapes so the output is pure ASCII
    -- (valid Lua 5.1 / 5.3 / Luau, and accepted by strict UTF-8 hosts).
    cipherLits[i] = string.format("%q", c):gsub("[\128-\255]", function(ch)
      return string.format("\\%03d", ch:byte())
    end)
  end
  local ciphersLit = table.concat(cipherLits, ",")

  -- Env-logger check: one direct read per builtin name (see the header).
  local protosLit = table.concat(bundle.protoLits, ",")

  -- Shared names between header and footer (consts/protos locals) must
  -- match, so render both from one nameCache.
  local nameCache = {}
  local function resolveShared(tok)
    if tok == "engine" then return nil end -- filled per-template below
    if not nameCache[tok] then nameCache[tok] = randomIdent() end
    return nameCache[tok]
  end

  local headerTpl = opts.minify and minifyTemplateText(HEADER_TEMPLATE) or HEADER_TEMPLATE
  local footerTpl = opts.minify and minifyTemplateText(FOOTER_TEMPLATE) or FOOTER_TEMPLATE

  local header = substitute(headerTpl, resolveShared)
  -- Standard-library references: rewrite to indexes into one table that
  -- the header fills at startup (see rewriteStd / buildStdBlock).
  local stdTab = resolveShared("stdtab")
  local stdList, stdIndex = {}, {}
  local stdSalt = math.random(1, 200)
  local stdNames = {
    G = resolveShared("stdG"), dec = resolveShared("stdDec"), t = resolveShared("stdT"),
    o = resolveShared("stdO"), j = resolveShared("stdJ"),
    char = resolveShared("char"), concat = resolveShared("concat"),
    base = resolveShared("base"),
  }
  header = rewriteStd(header, stdTab, stdList, stdIndex)
  header = header:gsub("__XS_VAULT__", vaultLit)
  header = header:gsub("__XS_KMAP__", kmapLit)
  header = header:gsub("__XS_SM1__", tostring(bundle.sm1))
  header = header:gsub("__XS_SM2__", tostring(bundle.sm2))
  header = header:gsub("__XS_VSUM__", tostring(bundle.vsum))
  header = header:gsub("__XS_TAGN__", tostring(bundle.tagN))
  header = header:gsub("__XS_TAGS__", tostring(bundle.tagS))
  for nm, idx in pairs(bundle.antiIdx) do
    header = header:gsub("__XS_NM_" .. nm:upper() .. "__", tostring(idx))
  end
  header = header:gsub("__XS_SB__", tostring(CIPHER.basis))
  header = header:gsub("__XS_LM__", tostring(CIPHER.mult))
  header = header:gsub("__XS_LA__", tostring(CIPHER.add))
  header = header:gsub("__XS_RM__", tostring(CIPHER.rcMult))
  header = header:gsub("__XS_MASKA__", tostring(bundle.maskA))
  header = header:gsub("__XS_CIPHERS__", (ciphersLit:gsub("%%", "%%%%")))
  header = header:gsub("__XS_PROTOS__", (protosLit:gsub("%%", "%%%%")))
  header = header:gsub("__XS_CHECKSUM__", tostring(bundle.checksum))
  header = header:gsub("__XS_ANTITAMPER_ON__", tostring(opts.antiTamper))
  header = header:gsub("__XS_ANTIDEBUG__", tostring(opts.antiDebug))
  header = header:gsub("__XS_WMIDX__", tostring(bundle.watermarkIdx))
  -- Built here, after resolveShared exists, so the corrupt() helper is
  -- emitted under its renamed identifier like everything else in the header.
  -- Live getters for the standard builtins (see %LIVE% in the header).
  -- Live getter keys are encoded. The values stay bare global reads: only a
  -- bare identifier sees a global assigned by name on every runtime (on Lute
  -- _G does not reflect those), so the getter must read the name directly.
  header = header:gsub("__XS_LIVE__", function()
    local parts, seen = {}, {}
    local function add(name)
      if seen[name] then return end
      seen[name] = true
      parts[#parts + 1] = string.format("[%s] = function() return %s end",
        encName(stdNames, stdSalt, name), name)
    end
    for _, name in ipairs(ENV_CHECK_NAMES) do add(name) end
    for _, name in ipairs(bundle.liveNames) do add(name) end
    return table.concat(parts, ", ")
  end)
  header = header:gsub("__XS_ENVCHECK__", function()
    if not opts.antiDebug then return "" end
    local corrupt = resolveShared("corrupt")
    local parts = {}
    for _, name in ipairs(ENV_CHECK_NAMES) do
      -- A bare read on purpose: it sees the live global, so a logger installed
      -- before the protected code is caught (see the env-logger test). These
      -- names therefore stay readable in the output.
      parts[#parts + 1] = string.format('if type(%s) ~= "function" then %s() end', name, corrupt)
    end
    return table.concat(parts, " ")
  end)

  local footer = substitute(footerTpl, function(tok)
    if tok == "engine" then return "(function()\n" .. engineSrc .. "\nend)()" end
    return resolveShared(tok)
  end)
  footer = rewriteStd(footer, stdTab, stdList, stdIndex)
  local tmText = useTypes and buildTypeMangler() or nil
  header = header:gsub("__XS_TYPEMANGLER__", function() return tmText or "" end)
  header = header:gsub("__XS_STD__", function()
    if #stdList == 0 then return "" end
    return buildStdBlock(stdTab, stdList, stdNames, stdSalt)
  end)
  footer = footer:gsub("__XS_MAIN__", tostring(bundle.mainProto))

  -- Wrap the ENTIRE output (header locals: key/decode/consts/protos,
  -- plus the engine call) inside one outer closure, so the finished
  -- file is a single `return (function(...) ... end)(...)` expression
  -- -- nothing (opcode numbers, decode key, helper names, consts,
  -- protos) sits at the chunk's top level at all.
  local combined = header .. "\n" .. footer
  return "return (function(...)\n" .. combined .. "\nend)(...)\n"
end

-- Public entry point. Builds the protected file and, if the result is smaller
-- than opts.minSize, rebuilds with a bigger `strength` (decoy handler and
-- dead-block multiplier) until it is. Off by default: padding is dead code,
-- so it only makes a paste larger and adds no secrecy. Opt in with a size
-- (the CLI's --min-size) when a minimum file size is actually needed.
local function obfuscate(source, chunkname, opts)
  opts = opts or {}
  local target = opts.minSize
  if target == nil or target == false then target = 0 end
  local strength = opts.strength or 1
  local out
  -- Output size is noisy from one build to the next (decoy counts are
  -- random), so aim 10% over the target and allow a dozen attempts.
  for _ = 1, 12 do
    local attempt = {}
    for k, v in pairs(opts) do attempt[k] = v end
    attempt.strength = strength
    out = obfuscateOnce(source, chunkname, attempt)
    if #out >= target then break end
    strength = strength * math.max(1.25, 1.1 * target / #out)
  end
  return out
end

return { obfuscate = obfuscate }
