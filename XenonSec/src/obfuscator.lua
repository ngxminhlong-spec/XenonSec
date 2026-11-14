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
local numExpr = _util.numExpr

-- A name as a Lua string literal of decimal byte escapes: the name never
-- appears as plain text in the output.
local function escStr(name)
  return '"' .. name:gsub(".", function(c) return string.format("\\%03d", c:byte()) end) .. '"'
end

-- Integer constants go through numExpr so their literal value never appears.
local function numOr(v)
  if math.type(v) == "integer" then return numExpr(v) end
  return tostring(v)
end

-- A boolean written as arithmetic: n*(n+1) is even for every integer n, so
-- the remainder is 0 (true) or 1 (false, never reached). Both n and the
-- literals are masked, so the output has no plain true/false gate.
-- Two identities with the same always-even product, picked per gate, so the
-- gates do not all share one shape: n*(n+1) and n*(n-1) are both even.
local OPAQUE_FORMS = { "+1", "-1" }
local function opaqueBool(b)
  local n = math.random(2, 99999)
  local product = "(" .. numExpr(n) .. "*(" .. numExpr(n) .. OPAQUE_FORMS[math.random(1, #OPAQUE_FORMS)] .. "))"
  return "(" .. product .. " % 2" .. (b and " == 0" or " == 1") .. ")"
end
local FOOTER_TEMPLATE = load("templates/footer")
local HEADER_TEMPLATE = load("templates/header")
local ANTIDEBUG_TEMPLATE = load("templates/antidebug")
local VM_TEMPLATE = load("templates/vm")
local CORE_BLOCKS = load("templates/core_handlers")
local CORE_VARIANTS = load("templates/core_variants")
local LZDEC_TEMPLATE = load("templates/lzdec")
local _tm = load("typemangler")
local buildTypeMangler, scatterType = _tm.buildTypeMangler, _tm.scatterType

-- Seed from the OS entropy pool: six bytes of /dev/urandom (48 bits, the most a
-- Lua double holds exactly). The old seed, os.time() plus a table address, had
-- about 30 bits per second and could be reproduced from a timestamp guess.
-- Without /dev/urandom we fall back to that seed and say so (weakSeed).
local function entropySeed()
  local f = io.open("/dev/urandom", "rb")
  if f then
    local bytes = f:read(6)
    f:close()
    if bytes and #bytes == 6 then
      local v = 0
      for i = 1, 6 do v = v * 256 + bytes:byte(i) end
      return v, false
    end
  end
  return os.time() + (tonumber(tostring({}):match("0x(%x+)"), 16) or 0), true
end
local seedValue, weakSeed = entropySeed()
math.randomseed(seedValue)
-- burn a few values; the build's layout and keys are drawn from this stream.
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

-- mbaLimit is written into generated Lua source, so it must be a plain number.
-- Anything else (for example a string holding code) is rejected up front.
local function checkMbaLimit(v)
  if v == nil then return nil end
  local n = type(v) == "number" and v or nil
  if not n or n ~= math.floor(n) or n < 1 or n > 4503599627370496 then
    error("mbaLimit must be an integer in [1, 2^52]", 3)
  end
  return n
end

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

  -- The LZMA decoder that unpacks the protos ships as bytecode of this same
  -- VM, not as readable Lua. It is compiled into the module as its own unit,
  -- and its protos are stored raw (cipher only), because they are what the
  -- runtime needs to decode everything else. The adaptation rate is chosen per
  -- build, and the compressor is told the same value.
  mod.lzD = ({ 16, 32 })[math.random(1, 2)]
  local decAst = Parser.parse(LZDEC_TEMPLATE:gsub("__LZ_D__", tostring(mod.lzD)), "=xenon-decoder", false)
  Renamer.resolve(decAst)
  local decMain, decFirst, decLast = Compiler.compileInto(mod, decAst, Capture.analyze(decAst))
  mod.decMain, mod.rawFirst, mod.rawLast = decMain, decFirst, decLast

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
  -- Shared identifiers: the engine uses the same byte/char/concat locals as the
  -- header's standard-library bootstrap, so it resolves them through this cache.
  local nameCache = {}
  local function resolveShared(tok)
    if tok == "engine" then return nil end -- filled per-template below
    if not nameCache[tok] then nameCache[tok] = randomIdent() end
    return nameCache[tok]
  end
  local engineSrc = renderTemplate(vmSrc, bundle.OPNUM, bundle.BINNUM, bundle.UNNUM, totalInstr, opts.antiDebug,
    { mba = opts.mba ~= false, mbaLimit = checkMbaLimit(opts.mbaLimit), M1 = bundle.saltM1, M2 = bundle.saltM2, M3 = bundle.saltM3, SA = bundle.stepA, SB = bundle.stepB, SC = bundle.stepC, MOD = bundle.mod, strength = opts.strength or 1,
      proxify = opts.proxify and true or false, PA = proxyA, PB = proxyB, PM = PROXY_M,
      freeKey = bundle.freeKey, decoyCount = bundle.decoyCount,
      flush = opts.flushConsts and true or false, flushEvery = opts.flushEvery or 65536,
      coreBlocks = CORE_BLOCKS, coreVariants = CORE_VARIANTS,
      wm = bundle.watermarkIdx, three = bundle.threeIdx,
      minifyFn = opts.minify and minifyTemplateText or nil, luauTypes = useTypes,
      scatterType = scatterType,
      opGroups = bundle.opGroups, rekeySeed = math.random(1, 2147483646),
      shared = function(tok) return resolveShared(tok) end })
  -- Hash constants used by the engine's own checksum functions, masked the
  -- same way as the header's.
  for tok, val in pairs({ __XS_MH__ = 2147483647, __XS_LCG__ = 16807, __XS_H31__ = 31 }) do
    engineSrc = engineSrc:gsub(tok, function() return numExpr(val) end)
  end

  local vaultLit = table.concat(bundle.vault, ",")
  local kmapLit = table.concat(bundle.kmap, ",")
  -- Constant pool: base85 text, so no escapes are needed (the alphabet has no
  -- quote or backslash). Lengths go in a separate list.
  local cipherLits = {}
  for i, t in ipairs(bundle.cipherText) do cipherLits[i] = '"' .. t .. '"' end
  local ciphersLit = table.concat(cipherLits, ",")
  local cipherLensLit = table.concat(bundle.cipherLens, ",")

  -- Env-logger check: one direct read per builtin name (see the header).
  local protosLit = table.concat(bundle.protoLits, ",")

  -- Shared names between header and footer (consts/protos locals) must
  -- match, so render both from one nameCache.
  local headerTpl = opts.minify and minifyTemplateText(HEADER_TEMPLATE) or HEADER_TEMPLATE
  local footerTpl = opts.minify and minifyTemplateText(FOOTER_TEMPLATE) or FOOTER_TEMPLATE

  local header = substitute(headerTpl, resolveShared)
  -- Anti-debug machinery is emitted only for anti-debug builds.
  if opts.antiDebug then
    local adTpl = opts.minify and minifyTemplateText(ANTIDEBUG_TEMPLATE) or ANTIDEBUG_TEMPLATE
    local adText = substitute(adTpl, resolveShared)
    header = header:gsub("__XS_ADBLOCK__", function() return adText end)
  else
    header = header:gsub("__XS_ADBLOCK__", function() return "" end)
  end
  -- Standard-library references: rewrite to indexes into one table that
  -- the header fills at startup (see rewriteStd / buildStdBlock).
  local stdTab = resolveShared("stdtab")
  local stdList, stdIndex = {}, {}
  _stdlib.resetSeeds()
  local stdNames = {
    G = resolveShared("stdG"), dec = resolveShared("stdDec"), t = resolveShared("stdT"),
    o = resolveShared("stdO"), j = resolveShared("stdJ"),
    char = resolveShared("char"), byte = resolveShared("byte"), concat = resolveShared("concat"),
    base = resolveShared("base"), sm = resolveShared("bsm"), f = resolveShared("bf"),
    ok = resolveShared("bok"), r = resolveShared("br"), pc = resolveShared("bpc"),
  }
  header = rewriteStd(header, stdTab, stdList, stdIndex)
  header = header:gsub("__XS_VAULT__", vaultLit)
  header = header:gsub("__XS_KMAP__", kmapLit)
  header = header:gsub("__XS_SM1__", numOr(bundle.sm1))
  header = header:gsub("__XS_SM2__", numOr(bundle.sm2))
  header = header:gsub("__XS_VSUM__", numOr(bundle.vsum))
  header = header:gsub("__XS_TAGN__", numOr(bundle.tagN))
  header = header:gsub("__XS_TAGS__", numOr(bundle.tagS))
  header = header:gsub("__XS_TAGF__", numOr(bundle.tagF))
  header = header:gsub("__XS_TAGZ__", numOr(bundle.tagZ))
  header = header:gsub("__XS_TAGNAN__", numOr(bundle.tagNaN))
  header = header:gsub("__XS_TAGI__", numOr(bundle.tagI))
  for nm, idx in pairs(bundle.antiIdx) do
    header = header:gsub("__XS_NM_" .. nm:upper() .. "__", numExpr(idx))
  end
  header = header:gsub("__XS_SB__", numOr(CIPHER.basis))
  header = header:gsub("__XS_LM__", numOr(CIPHER.mult))
  header = header:gsub("__XS_LA__", numOr(CIPHER.add))
  header = header:gsub("__XS_RM__", numOr(CIPHER.rcMult))
  header = header:gsub("__XS_FMOD__", function() return numExpr(bundle.mod) end)
  header = header:gsub("__XS_FM1__", function() return numExpr(bundle.saltM1) end)
  header = header:gsub("__XS_FM2__", function() return numExpr(bundle.saltM2) end)
  header = header:gsub("__XS_FM3__", function() return numExpr(bundle.saltM3) end)
  header = header:gsub("__XS_FSA__", function() return numExpr(bundle.stepA) end)
  local CONST_TOKENS = { __XS_KA__ = 131, __XS_KB__ = 17, __XS_KC__ = 29, __XS_KD__ = 3, __XS_KE__ = 2147483647,
    __XS_MH__ = 2147483647, __XS_LCG__ = 16807, __XS_H31__ = 31 }
  for tok, val in pairs(CONST_TOKENS) do
    header = header:gsub(tok, function() return numExpr(val) end)
  end
  header = header:gsub("__XS_STA__", numOr(bundle.stepA))
  header = header:gsub("__XS_STB__", numOr(bundle.stepB))
  header = header:gsub("__XS_STC__", numOr(bundle.stepC))
  do
    -- alias -> canonical opcode, and the canonical opcodes that reset the state
    local canonParts, resetParts = {}, {}
    for _, group in pairs(bundle.opGroups) do
      for _, k in ipairs(group) do canonParts[#canonParts + 1] = string.format("[%s]=%s", numExpr(k), numExpr(group[1])) end
    end
    for _, name in ipairs({ "JMP", "JF", "JT", "JNIL", "RET", "RETM" }) do
      if bundle.OPNUM[name] then resetParts[#resetParts + 1] = string.format("[%s]=true", numExpr(bundle.OPNUM[name])) end
    end
    header = header:gsub("__XS_CANONH__", "{" .. table.concat(canonParts, ",") .. "}")
    header = header:gsub("__XS_RESETH__", "{" .. table.concat(resetParts, ",") .. "}")
  end
  header = header:gsub("__XS_MASKA__", numOr(bundle.maskA))
  header = header:gsub("__XS_CIPHERS__", (ciphersLit:gsub("%%", "%%%%")))
  header = header:gsub("__XS_CLENS__", cipherLensLit)
  local escLit = table.concat(bundle.escEntries, ",")
  header = header:gsub("__XS_ESC__", function() return escLit end)
  header = header:gsub("__XS_PROTOS__", (protosLit:gsub("%%", "%%%%")))
  header = header:gsub("__XS_CHECKSUM__", numOr(bundle.checksum))
  -- Anti-debug boot tokens by check index (empty when anti-debug is off).
  local adTokParts = {}
  for ci = 1, 14 do
    if bundle.adTokens[ci] then adTokParts[#adTokParts + 1] = "[" .. numExpr(ci) .. "]=" .. numOr(bundle.adTokens[ci]) end
  end
  local adTokLit = "({" .. table.concat(adTokParts, ",") .. "})"
  header = header:gsub("__XS_ADTOKS__", function() return adTokLit end)
  header = header:gsub("__XS_ANTITAMPER_ON__", function() return opaqueBool(opts.antiTamper and true or false) end)
  header = header:gsub("__XS_ANTIDEBUG__", function() return opaqueBool(opts.antiDebug and true or false) end)
  header = header:gsub("__XS_WMIDX__", numExpr(bundle.watermarkIdx))
  header = header:gsub("__XS_WMTEXT__", function() return '"' .. _util.watermark() .. '"' end)
  header = header:gsub("__XS_DECMAIN__", numExpr(bundle.decMain))
  header = header:gsub("__XS_GROOT__", function() return resolveShared("stdG") end)
  header = header:gsub("__XS_NSTATIC__", numExpr(bundle.nStatic))
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
      parts[#parts + 1] = string.format("[%s] = function() return %s[%s] end",
        encName(stdNames, name), resolveShared("base"), escStr(name))
    end
    for _, name in ipairs(ENV_CHECK_NAMES) do add(name) end
    for _, name in ipairs(bundle.liveNames) do add(name) end
    return table.concat(parts, ", ")
  end)
  header = header:gsub("__XS_ENVCHECK__", function()
    if not opts.antiDebug then return "" end
    local corrupt = resolveShared("corrupt")
    -- Each getter reads its global bare, inside its own closure, so a logger
    -- installed before the protected code is still caught (see the env-logger
    -- test). The names therefore stay readable, but only in these closures:
    -- the check itself is one loop with a single type() call.
    local getters = {}
    for _, name in ipairs(ENV_CHECK_NAMES) do
      getters[#getters + 1] = "function() return " .. resolveShared("base") .. "[" .. escStr(name) .. "] end"
    end
    -- Local names are per-build random identifiers, and the block is scoped
    -- with do ... end so none of them outlives the check.
    local tyName, listName, idxName = randomIdent(), randomIdent(), randomIdent()
    return string.format('do local %s = %s[__XS_KS_type__] local %s = {%s} for %s = 1, #%s do if %s(%s[%s]()) ~= "function" then %s() end end end',
      tyName, resolveShared("base"), listName, table.concat(getters, ", "),
      idxName, listName, tyName, listName, idxName, corrupt)
  end)

  local footer = substitute(footerTpl, function(tok)
    if tok == "engine" then return "(function()\n" .. engineSrc .. "\nend)()" end
    return resolveShared(tok)
  end)
  footer = rewriteStd(footer, stdTab, stdList, stdIndex)
  local tmText = useTypes and buildTypeMangler() or nil
  header = header:gsub("__XS_TYPEMANGLER__", function() return tmText or "" end)
  -- Always emitted: the header needs byte/char/concat even when no library
  -- name is referenced directly.
  header = header:gsub("__XS_STD__", function()
    return buildStdBlock(stdTab, stdList, stdNames)
  end)
  -- Builtin and library names used by the anti-debug and writable-probe code,
  -- written as escaped keys (__XS_KS_<name>__ -> "\ddd...").
  header = header:gsub("__XS_KS_(%w+)__", function(name) return escStr(name) end)
  footer = footer:gsub("__XS_MAIN__", numExpr(bundle.mainProto))

  -- Wrap the ENTIRE output (header locals: key/decode/consts/protos,
  -- plus the engine call) inside one outer closure, so the finished
  -- file is a single `return (function(...) ... end)(...)` expression
  -- -- nothing (opcode numbers, decode key, helper names, consts,
  -- protos) sits at the chunk's top level at all.
  -- Build-time hashes for the anti-debug code check (see ckDump in the header).
  -- The header is run once inside the same wrapper as the output, with the
  -- hash placeholders zeroed, and string.dump(check, true) is taken of each
  -- check. Lua 5.3 only; Luau builds (useTypes) and other hosts keep zeros.
  local function luaQuote(str)
    return '"' .. str:gsub("[%c\"\\\128-\255]", function(c) return string.format("\\%03d", c:byte()) end) .. '"'
  end
  -- The outer wrapper is written in one of several equivalent spellings,
  -- chosen per build, so the file does not start with the same text every time.
  local wrapForms = {
    { "return (function(...)\n", "\nend)(...)\n" },
    { "return(function(...)\n", "\nend)(...)\n" },
    { "return (function( ... )\n", "\nend ) ( ... )\n" },
  }
  local wrapForm = wrapForms[math.random(1, #wrapForms)]
  local wrapHead, wrapTail = wrapForm[1], wrapForm[2]
  local ckHashes, dumpPrefix = { 0, 0, 0, 0 }, ""
  if opts.antiDebug and not useTypes and _VERSION == "Lua 5.3" then
    local zeroed = (header:gsub("__XS_CKH__", "0,0,0,0"))
    zeroed = (zeroed:gsub("__XS_DPFX__", '""'))
    local probeSrc = wrapHead .. zeroed .. "\nreturn " ..
      resolveShared("CKS") .. wrapTail
    local fn, loadErr = _G.load(probeSrc, "=probe")
    assert(fn, "XenonSec: anti-debug probe failed to load: " .. tostring(loadErr))
    local okRun, checks = pcall(fn)
    assert(okRun and type(checks) == "table", "XenonSec: anti-debug probe did not run: " .. tostring(checks))
    local function hashOf(str)
      local h = 5381
      for j = 1, #str do h = (h * 31 + str:byte(j)) % 2147483647 end
      return h
    end
    for i = 1, 4 do
      local dump = string.dump(checks[i], true)
      ckHashes[i] = hashOf(dump)
      if i == 1 then dumpPrefix = dump:sub(1, 33) end
    end
  end
  header = header:gsub("__XS_CKH__", (table.concat(ckHashes, ","):gsub("%%", "%%%%")))
  header = header:gsub("__XS_DPFX__", (luaQuote(dumpPrefix):gsub("%%", "%%%%")))

  local combined = header .. "\n" .. footer
  return wrapHead .. combined .. wrapTail
end

-- Public entry point. Builds the protected file and, if the result is smaller
-- than opts.minSize, rebuilds with a bigger `strength` (decoy handler and
-- dead-block multiplier) until it is. Off by default: padding is dead code,
-- so it only makes a paste larger and adds no secrecy. Opt in with a size
-- (the CLI's --min-size) when a minimum file size is actually needed.
local function obfuscate(source, chunkname, opts)
  opts = opts or {}
  _util.newWatermark()  -- fresh watermark text for this build
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

return { obfuscate = obfuscate, weakSeed = weakSeed }
