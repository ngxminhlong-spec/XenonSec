--------------------------------------------------------------------
-- XenonSec :: obfuscator/templates/header.lua
-- Output header: key vault, decrypted constant pool and proto table (__XS_*__ placeholders are filled by obfuscator.lua).
--------------------------------------------------------------------

return [===[
--[[Protected by XenonSec]]
local %byte% = string.byte
local %char% = string.char
local %concat% = table.concat
__XS_STD__
local function %bxor%(%a%, %b%)
  local %r%, %bit%, %x%, %y% = 0, 1, %a%, %b%
  while %x% > 0 or %y% > 0 do
    local %xb%, %yb% = %x% % 2, %y% % 2
    if %xb% ~= %yb% then %r% = %r% + %bit% end
    %x% = (%x% - %xb%) / 2
    %y% = (%y% - %yb%) / 2
    %bit% = %bit% * 2
  end
  return %r%
end
local %key% = __XS_KEY__
local %maskA% = __XS_MASKA__

-- Four-layer decrypt, undone in reverse order of how it was applied:
-- the keyed S-box/block-permutation layer, then CFB-unchain, then the
-- LCG-keyed rotation/XOR diffusion layer, then RC4. See obfuscate.lua's
-- cipherEncrypt/cipherDecrypt for why each layer is there -- this is
-- the exact same construction, just spelled out with per-build
-- randomized names.
local function %rotr8%(%rb%, %rn%)
  %rn% = %rn% % 8
  if %rn% == 0 then return %rb% end
  return ((%rb% * (2 ^ (8 - %rn%))) % 256) + math.floor(%rb% / (2 ^ %rn%))
end

local function %deriveIV%()
  local %ivv% = 0
  for %ivi% = 1, #%key% do %ivv% = %bxor%(%ivv%, %key%[%ivi%]) end
  return %ivv%
end

local function %cfbUnchain%(%s%)
  local %out%, %prev% = {}, %deriveIV%()
  for %oi% = 1, #%s% do
    local %cc% = %byte%(%s%, %oi%)
    %out%[%oi%] = %char%(%bxor%(%cc%, %prev%))
    %prev% = %cc%
  end
  return %concat%(%out%)
end

-- Key-derived LCG seed. Mirrors deriveSeed in obfuscate.lua; the constants
-- are this build's own (see CIPHER there), not textbook values.
local function %keySeed%()
  local %kd% = __XS_SB__
  for %ki% = 1, #%key% do
    %kd% = %bxor%(%kd%, %key%[%ki%])
    %kd% = (%kd% * __XS_LM__ + __XS_LA__) % 16777216
  end
  return %kd%
end

local function %diffuseDecrypt%(%s%)
  local %seed% = %keySeed%()
  local %out% = {}
  for %oi% = 1, #%s% do
    %seed% = (%seed% * __XS_LM__ + __XS_LA__) % 16777216
    local %lkbyte% = math.floor(%seed% / 65536) % 256
    local %lb% = %rotr8%(%byte%(%s%, %oi%), (%oi% % 5) + 1)
    %out%[%oi%] = %char%(%bxor%(%lb%, %lkbyte%))
  end
  return %concat%(%out%)
end

local function %rc4Decrypt%(%s%)
  local %S% = {}
  for %si% = 0, 255 do %S%[%si%] = %si% end
  local %sj%, %kl% = 0, #%key%
  for %si% = 0, 255 do
    %sj% = (%sj% * __XS_RM__ + %S%[%si%] + %key%[(%si% % %kl%) + 1]) % 256
    %S%[%si%], %S%[%sj%] = %S%[%sj%], %S%[%si%]
  end
  local %ri%, %rj% = 0, 0
  local %out% = {}
  for %oi% = 1, #%s% do
    %ri% = (%ri% + 1) % 256
    %rj% = (%rj% * __XS_RM__ + %S%[%ri%]) % 256
    %S%[%ri%], %S%[%rj%] = %S%[%rj%], %S%[%ri%]
    local %kbyte% = %S%[(%S%[%ri%] + %S%[%rj%]) % 256]
    %out%[%oi%] = %char%(%bxor%(%byte%(%s%, %oi%), %kbyte%))
  end
  return %concat%(%out%)
end

-- Layer 4 (runtime side): a keyed S-box substitution plus a keyed
-- within-block permutation, both derived from %key% alone. Exact
-- mirror of obfuscate.lua's deriveSbox/deriveBlockOrder/blockPermute
-- -- see there for why each step is there.
local function %spnDecrypt%(%ssIn%)
  local %sSeed% = %keySeed%()
  local %sBox% = {}
  for %sbi% = 0, 255 do %sBox%[%sbi%] = %sbi% end
  for %sbj% = 255, 1, -1 do
    %sSeed% = (%sSeed% * __XS_LM__ + __XS_LA__) % 16777216
    local %sbr% = (math.floor(%sSeed% / 65536) % 256) % (%sbj% + 1)
    %sBox%[%sbj%], %sBox%[%sbr%] = %sBox%[%sbr%], %sBox%[%sbj%]
  end
  local %sInv% = {}
  for %sii% = 0, 255 do %sInv%[%sBox%[%sii%]] = %sii% end

  local %bSeed% = %keySeed%()
  %bSeed% = (%bSeed% * __XS_LM__ + __XS_LA__) % 16777216
  local %sOrder% = { 1, 2, 3, 4, 5, 6, 7, 8 }
  for %soi% = 8, 2, -1 do
    %bSeed% = (%bSeed% * __XS_LM__ + __XS_LA__) % 16777216
    local %sor% = ((math.floor(%bSeed% / 65536) % 256) % %soi%) + 1
    %sOrder%[%soi%], %sOrder%[%sor%] = %sOrder%[%sor%], %sOrder%[%soi%]
  end
  local %sInvOrd% = {}
  for %sioi% = 1, 8 do %sInvOrd%[%sOrder%[%sioi%]] = %sioi% end

  local %sLen% = #%ssIn%
  local %sFull% = %sLen% - (%sLen% % 8)
  local %sPerm% = {}
  for %spi% = 1, %sFull%, 8 do
    for %spk% = 1, 8 do
      %sPerm%[%spi% + %spk% - 1] = %byte%(%ssIn%, %spi% + %sInvOrd%[%spk%] - 1)
    end
  end
  for %spj% = %sFull% + 1, %sLen% do %sPerm%[%spj%] = %byte%(%ssIn%, %spj%) end

  local %sOut% = {}
  for %soj% = 1, %sLen% do %sOut%[%soj%] = %char%(%sInv%[%sPerm%[%soj%]]) end
  return %concat%(%sOut%)
end

local function %decode%(%s%)
  return %rc4Decrypt%(%diffuseDecrypt%(%cfbUnchain%(%spnDecrypt%(%s%))))
end
local %raw% = { __XS_CIPHERS__ }
local %protos% = { __XS_PROTOS__ }

--------------------------------------------------------------------
-- Anti-tamper: a checksum computed at build time over every byte of
-- the ciphertext pool and every opcode/operand in every proto is
-- re-verified here, BEFORE anything gets decoded. On mismatch the key
-- is silently corrupted rather than raising an obvious error -- the
-- script keeps running and fails somewhere downstream with a
-- confusing, unrelated-looking error instead of pointing straight at
-- the check that caught it.
--------------------------------------------------------------------

local %corrupt% = function()
  for %kci% = 1, #%key% do %key%[%kci%] = (%key%[%kci%] + 97) % 256 end
  -- The key only protects the encrypted string/number pool -- the
  -- proto/bytecode table itself is plain literal Lua data, never
  -- decrypted via the key at all. So a tamper landing purely inside
  -- the bytecode wouldn't be neutralized by corrupting the key alone.
  -- Force EVERY instruction in EVERY proto to an opcode number that
  -- can never match any real one, so the very first instruction any
  -- proto executes fails immediately, no matter where the tamper was.
  for %cpi% = 1, #%protos% do
    local %cpc% = %protos%[%cpi%].c
    for %cpj% = 1, #%cpc% do %cpc%[%cpj%][1] = nil end
  end
end

local function %verify%()
  local %h% = 5381
  local function %mix%(%n%) %h% = (%h% * 31 + (%n% or 0)) % 2147483647 end
  for %vci% = 1, #%raw% do
    local %vs% = %raw%[%vci%]
    for %vcj% = 1, #%vs% do %mix%(%byte%(%vs%, %vcj%)) end
  end
  for %vpi% = 1, #%protos% do
    local %vpr% = %protos%[%vpi%]
    %mix%(%vpr%.v and 1 or 0)
    local %vpc% = %vpr%.c
    for %vpk% = 1, #%vpc% do
      local %vins% = %vpc%[%vpk%]
      %mix%(%vins%[5]); %mix%(%vins%[1]); %mix%(%vins%[2]); %mix%(%vins%[3]); %mix%(%vins%[4])
    end
    local %vpp% = %vpr%.p
    for %vpj% = 1, #%vpp% do %mix%(%vpp%[%vpj%][1]); %mix%(%vpp%[%vpj%][2]) end
    %mix%(%vpr%.k)
  end
  return (not __XS_ANTITAMPER_ON__) or (%h% == __XS_CHECKSUM__)
end

if not %verify%() then %corrupt%() end

--------------------------------------------------------------------
-- Anti-debug (opt-in, see --antidebug): a debug hook set on this
-- coroutine is a strong signal of an attached debugger/profiler --
-- normal execution never sets one itself. A tight-loop timing check
-- backs it up (single-stepping/breakpoints make trivial work take
-- implausibly long). Both are guarded so a host without `debug`/`os`
-- (common in sandboxed embeddings) just skips them, no error either way.
--------------------------------------------------------------------

-- Global access, chosen once at startup:
--  * If the real environment is writable (Lua 5.1 getfenv(0), Lua 5.3 _G,
--    Lune), globals go straight to it, so program semantics are exactly
--    the raw ones. The probe key is set and removed again.
--  * If it isn't (Lute: `_G` is read-only and doesn't track assignments),
--    writes go to a private table and reads fall back to the standard
--    builtins read live (so a host's replacement of print is seen), then
--    to the `_G` snapshot of host globals.
-- Either way the names are encrypted constants, never plaintext.
local %base% = (getfenv and getfenv(0)) or _G
local %LIVE% = { __XS_LIVE__ }
local %priv% = {}
local %NILH% = {}
local %probeKey% = tostring(%priv%)
local %writable% = pcall(function()
  %base%[%probeKey%] = true
  %base%[%probeKey%] = nil
end)
local %GETG% = function(%k%)
  if %writable% then return %base%[%k%] end
  local %pv% = %priv%[%k%]
  if %pv% ~= nil then
    if %pv% == %NILH% then return nil end
    return %pv%
  end
  local %lf% = %LIVE%[%k%]
  if %lf% then return %lf%() end
  return %base%[%k%]
end
local %SETG% = function(%k%, %v%)
  if %writable% then %base%[%k%] = %v%
  else %priv%[%k%] = (%v% == nil) and %NILH% or %v% end
end

local %dbgLib% = nil
if __XS_ANTIDEBUG__ then
  local %dok%, %dlib% = pcall(function() return debug end)
  if %dok% and %dlib% and %dlib%.gethook then %dbgLib% = %dlib% end
end

-- Hook probe shared by the startup check and the periodic check that
-- runs inside the VM dispatch loop (see %ADCHECK% in VM_TEMPLATE).
local %adHook% = function()
  if not %dbgLib% then return false end
  local %hok%, %hfn% = pcall(%dbgLib%.gethook)
  return (%hok% and %hfn% ~= nil) and true or false
end

if __XS_ANTIDEBUG__ then
  if %adHook%() then %corrupt%() end
  local %ook%, %olib% = pcall(function() return os end)
  if %ook% and %olib% and %olib%.clock then
    local %t0% = %olib%.clock()
    local %junk% = 0
    for %ji% = 1, 30000 do %junk% = %junk% + %ji% end
    if (%olib%.clock() - %t0%) > 0.35 then %corrupt%() end
  end
end

-- Constants are decrypted on first use and cached, so a constant the
-- program never touches is never decrypted at all.
local %consts% = setmetatable({}, { __index = function(%ct%, %i2%)
  local %dv% = %decode%(%raw%[%i2%])
  local %tg% = %dv%:sub(1, 1)
  local %val%
  if %tg% == "N" then %val% = tonumber(%dv%:sub(2)) - %maskA% else %val% = %dv%:sub(2) end
  rawset(%ct%, %i2%, %val%)
  return %val%
end })

-- Watermark integrity: the decoded copy must gsub-match the exact
-- expected text. This can only ever fail alongside the checksum
-- failing too (both are reading the same encrypted payload) -- it's
-- not an independent detector, just one more thing that has to keep
-- adding up for execution to continue past this point.
do
  local %wmVal% = %consts%[__XS_WMIDX__]
  local %wmChecked%, %wmCount% = %wmVal%:gsub("Protected by XenonSec", "Protected by XenonSec")
  if %wmCount% ~= 1 or %wmChecked% ~= "Protected by XenonSec" then %corrupt%() end
end

if __XS_ANTIDEBUG__ then
  -- Anti-env-logger: a common instrumentation trick is replacing a
  -- global like `print` or `pairs` with a table carrying a `__call`
  -- metamethod, so every call gets logged before it's forwarded to the
  -- real function. `type()` on such a proxy reports "table", never
  -- "function" -- a cheap, zero-false-positive tell, since nothing
  -- legitimate has a reason to make these anything but real functions.
  -- The names checked are standard builtins; the engine already names
  -- them in plain text, so reading them directly reveals nothing new.
  __XS_ENVCHECK__
end]===]
