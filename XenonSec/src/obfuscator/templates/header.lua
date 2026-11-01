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
__XS_TYPEMANGLER__
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
local %maskA% = __XS_MASKA__
local %tagN% = __XS_TAGN__
local %tagS% = __XS_TAGS__

-- Key vault. The key is never stored as a list. Each key byte is split into
-- three XOR shares; every share sits at a shuffled position in one masked
-- table, with decoy bytes filling the rest. %buildKey% rebuilds the key from
-- those positions on each use, so the key is never held in a variable.
local %vault% = { __XS_VAULT__ }
local %kmap% = { __XS_KMAP__ }
local %sm1%, %sm2% = __XS_SM1__, __XS_SM2__
local %vsum% = __XS_VSUM__
local %kbad% = false
-- Anti-debug state. %adMix% is the sum of the check results (0 while nothing
-- is seen); %buildKey% folds it into the key. %adStep% is assigned in the
-- anti-debug block below and called from several places in the code.
local %adMix% = 0
local %adStep% = function() end

-- Tripwire: a weighted sum over the whole vault. Editing any byte changes it,
-- which marks the key bad (see %corrupt%).
local function %vaultOk%()
  local %vs% = 0
  for %vi% = 1, #%vault% do %vs% = (%vs% + %vault%[%vi%] * (%vi% % 7 + 1)) % 2147483647 end
  return %vs% == %vsum%
end

local function %buildKey%()
  local %n% = math.floor(#%kmap% / 3)
  local %k% = {}
  for %i% = 1, %n% do
    local %pa% = %kmap%[%i%]
    local %pb% = %kmap%[%n% + %i%]
    local %pc% = %kmap%[2 * %n% + %i%]
    local %a% = (%vault%[%pa%] - (%pa% * %sm1% + %sm2%) % 256) % 256
    local %b% = (%vault%[%pb%] - (%pb% * %sm1% + %sm2%) % 256) % 256
    local %c% = (%vault%[%pc%] - (%pc% * %sm1% + %sm2%) % 256) % 256
    %k%[%i%] = %bxor%(%bxor%(%a%, %b%), %c%)
  end
  -- Clean builds: the state is zero and the key is unchanged. Otherwise the
  -- shift is 1..255, and XOR with a nonzero value changes every byte, so no
  -- state value (even a multiple of 256) can leave the key clean.
  local %st% = %adMix% + (%kbad% and 1 or 0)
  if %st% ~= 0 then
    local %sh% = (%st% % 255) + 1
    for %i% = 1, %n% do %k%[%i%] = %bxor%(%k%[%i%], %sh%) end
  end
  return %k%
end

-- Keyed finalizer: the checksum is folded through the key, so it only
-- matches while the key is intact. Mirrors keyedFinal in bundle.lua.
local function %fin%(%h%, %k%)
  local %fa%, %fb% = 1, 0
  for %fi% = 1, #%k% do
    %fa% = (%fa% * 131 + %k%[%fi%] * 17 + %fi%) % 1048573
    %fb% = (%fb% * 29 + %k%[%fi%] * (%fi% + 3)) % 2147483647
  end
  return (%h% * (%fa% + 1) + %fb%) % 2147483647
end

if not %vaultOk%() then %kbad% = true end

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

local function %deriveIV%(%key%)
  local %ivv% = 0
  for %ivi% = 1, #%key% do %ivv% = %bxor%(%ivv%, %key%[%ivi%]) end
  return %ivv%
end

local function %cfbUnchain%(%s%, %key%)
  local %out%, %prev% = {}, %deriveIV%(%key%)
  for %oi% = 1, #%s% do
    local %cc% = %byte%(%s%, %oi%)
    %out%[%oi%] = %char%(%bxor%(%cc%, %prev%))
    %prev% = %cc%
  end
  return %concat%(%out%)
end

-- Key-derived LCG seed. Mirrors deriveSeed in obfuscate.lua; the constants
-- are this build's own (see CIPHER there), not textbook values.
local function %keySeed%(%key%)
  local %kd% = __XS_SB__
  for %ki% = 1, #%key% do
    %kd% = %bxor%(%kd%, %key%[%ki%])
    %kd% = (%kd% * __XS_LM__ + __XS_LA__) % 16777216
  end
  return %kd%
end

local function %diffuseDecrypt%(%s%, %key%)
  local %seed% = %keySeed%(%key%)
  local %out% = {}
  for %oi% = 1, #%s% do
    %seed% = (%seed% * __XS_LM__ + __XS_LA__) % 16777216
    local %lkbyte% = math.floor(%seed% / 65536) % 256
    local %lb% = %rotr8%(%byte%(%s%, %oi%), (%oi% % 5) + 1)
    %out%[%oi%] = %char%(%bxor%(%lb%, %lkbyte%))
  end
  return %concat%(%out%)
end

local function %rc4Decrypt%(%s%, %key%)
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
local function %spnDecrypt%(%ssIn%, %key%)
  local %sSeed% = %keySeed%(%key%)
  local %sBox% = {}
  for %sbi% = 0, 255 do %sBox%[%sbi%] = %sbi% end
  for %sbj% = 255, 1, -1 do
    %sSeed% = (%sSeed% * __XS_LM__ + __XS_LA__) % 16777216
    local %sbr% = (math.floor(%sSeed% / 65536) % 256) % (%sbj% + 1)
    %sBox%[%sbj%], %sBox%[%sbr%] = %sBox%[%sbr%], %sBox%[%sbj%]
  end
  local %sInv% = {}
  for %sii% = 0, 255 do %sInv%[%sBox%[%sii%]] = %sii% end

  local %bSeed% = %keySeed%(%key%)
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

local function %decodeK%(%s%, %key%)
  return %rc4Decrypt%(%diffuseDecrypt%(%cfbUnchain%(%spnDecrypt%(%s%, %key%), %key%), %key%), %key%)
end
local function %decode%(%s%)
  return %decodeK%(%s%, %buildKey%())
end
local %raw% = { __XS_CIPHERS__ }
local %protos% = { __XS_PROTOS__ }
-- Anti-debug names are encrypted constants, decoded only when used.
local function %dname%(%di%) return (%decode%(%raw%[%di%]):sub(2)) end

-- Per-proto key: the build key mixed with the proto's nonce, using the same
-- LCG as the key seed. Mirrors deriveProtoKey in bundle.lua.
local function %pkey%(%key%, %nn%)
  local %ps% = (__XS_SB__ + %nn%) % 16777216
  local %pko% = {}
  for %pki% = 1, #%key% do
    %ps% = (%ps% * __XS_LM__ + __XS_LA__) % 16777216
    %pko%[%pki%] = %bxor%(%key%[%pki%], math.floor(%ps% / 65536) % 256)
  end
  return %pko%
end

-- LZSS decoder, mirror of lzCompress in bundle.lua: a 4-byte raw length, then
-- flag-byte groups of literals (bit clear) and 2-byte matches (bit set).
local function %lzd%(%s%)
  local %n% = %byte%(%s%, 1) * 16777216 + %byte%(%s%, 2) * 65536 + %byte%(%s%, 3) * 256 + %byte%(%s%, 4)
  local %out% = {}
  local %len% = 0
  local %p% = 5
  while %len% < %n% do
    local %fl% = %byte%(%s%, %p%)
    %p% = %p% + 1
    for %bit% = 0, 7 do
      if %len% >= %n% then break end
      if math.floor(%fl% / 2 ^ %bit%) % 2 == 0 then
        %len% = %len% + 1
        %out%[%len%] = %byte%(%s%, %p%)
        %p% = %p% + 1
      else
        local %b1% = %byte%(%s%, %p%)
        local %b2% = %byte%(%s%, %p% + 1)
        %p% = %p% + 2
        local %dist% = %b1% + math.floor(%b2% / 16) * 256 + 1
        for %k% = 1, %b2% % 16 + 3 do
          %len% = %len% + 1
          %out%[%len%] = %out%[%len% - %dist%]
        end
      end
    end
  end
  local %chars% = {}
  for %i% = 1, %n% do %chars%[%i%] = %char%(%out%[%i%]) end
  return %concat%(%chars%)
end

-- Lazy proto decode, called by the engine the first time a proto runs. The
-- blob is decrypted, decompressed and unpacked into instructions. Each record
-- is 12 bytes of raw fields; seeds are regenerated from the nonce with the
-- build's Park-Miller step, and the fields are masked with the same formula
-- the dispatcher inverts. The decoded tuples are hashed and compared with the
-- proto's stored hash (field i) before anything can run them; a mismatch
-- leaves no usable opcodes.
local function %dproto%(%pr%)
  local %pk% = %pkey%(%buildKey%(), %pr%.n)
  if __XS_ANTIDEBUG__ then %adStep%(%pr%.n % 5 + 1) end
  local %plain% = %lzd%(%decodeK%(%pr%.b, %pk%))
  local %code% = {}
  local %dh% = 5381
  local function %hm%(%n%) %dh% = (%dh% * 31 + (%n% or 0)) % 2147483647 end
  local %st% = %pr%.n
  for %ci% = 1, math.floor(#%plain% / 12) do
    local %base% = (%ci% - 1) * 12
    %st% = (%st% * 16807) % 2147483647
    local %sd% = %st% % __XS_FMOD__
    local %mk% = %sd% * __XS_FM1__
    local %f% = {}
    for %fi% = 1, 4 do
      local %o% = %base% + (%fi% - 1) * 3
      local %v% = %byte%(%plain%, %o% + 1) * 65536 + %byte%(%plain%, %o% + 2) * 256 + %byte%(%plain%, %o% + 3)
      %f%[%fi%] = (%v% + (%mk% + %fi% * __XS_FM2__) % __XS_FMOD__) % __XS_FMOD__
    end
    %f%[5] = %sd%
    %hm%(%f%[5]); %hm%(%f%[1]); %hm%(%f%[2]); %hm%(%f%[3]); %hm%(%f%[4])
    %code%[%ci%] = %f%
  end
  if %dh% ~= %pr%.i then
    for %ci% = 1, #%code% do %code%[%ci%][1] = nil end
  end
  return %code%
end

-- Called by the engine on tamper: the key goes bad, so every proto decoded
-- after this point comes out with unusable opcodes.
local function %poison%()
  %kbad% = true
end

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
  %kbad% = true
  -- The key only protects the encrypted string/number pool -- the
  -- proto/bytecode table itself is plain literal Lua data, never
  -- decrypted via the key at all. So a tamper landing purely inside
  -- the bytecode wouldn't be neutralized by corrupting the key alone.
  -- Force EVERY instruction in EVERY proto to an opcode number that
  -- can never match any real one, so the very first instruction any
  -- proto executes fails immediately, no matter where the tamper was.
  -- Poison a random third of the instructions, not all: the failure then
  -- lands at a point that depends on the run rather than on the tamper site.
  for %cpi% = 1, #%protos% do
    local %cpc% = %protos%[%cpi%].c
    if %cpc% then
      for %cpj% = 1, #%cpc% do
        if math.random(1, 3) == 1 then %cpc%[%cpj%][1] = nil end
      end
    end
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
    %mix%(%vpr%.n)
    local %vpb% = %vpr%.b
    for %vbj% = 1, #%vpb% do %mix%(%byte%(%vpb%, %vbj%)) end
    local %vpp% = %vpr%.p
    for %vpj% = 1, #%vpp% do %mix%(%vpp%[%vpj%][1]); %mix%(%vpp%[%vpj%][2]) end
    %mix%(%vpr%.k)
  end
  return (not __XS_ANTITAMPER_ON__) or (%fin%(%h%, %buildKey%()) == __XS_CHECKSUM__)
end

if not %verify%() then %corrupt%() end

--------------------------------------------------------------------
-- Anti-debug (opt-in, see --antidebug): a debug hook set on this
-- thread (or the running coroutine) is a strong signal of an attached
-- debugger/profiler -- normal execution never sets one itself. The probe
-- must also be the engine's own C function. A host without `debug`
-- (common in sandboxed embeddings) just skips these checks, no error.
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

__XS_ADBLOCK__

-- Constants are decrypted on first use and cached, so a constant the
-- program never touches is never decrypted at all.
local %consts% = setmetatable({}, { __index = function(%ct%, %i2%)
  if __XS_ANTIDEBUG__ then %adStep%(%i2% % 5 + 1) end
  local %dv% = %decode%(%raw%[%i2%])
  local %tg% = %dv%:byte(1)
  local %val%
  if %tg% == %tagN% then %val% = tonumber(%dv%:sub(2)) - %maskA% else %val% = %dv%:sub(2) end
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
