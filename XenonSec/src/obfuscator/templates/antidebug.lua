--------------------------------------------------------------------
-- XenonSec :: obfuscator/templates/antidebug.lua
-- Anti-debug machinery (checks, self-test, code-hash test, placement entry
-- point). Inserted into the header only when antiDebug is on; the header
-- places it at __XS_ADBLOCK__ and it uses the header's names via %placeholders%.
--------------------------------------------------------------------

return [===[
-- Captured at load, before any program code runs. The checks compare against
-- these values, not against whatever the globals hold later.
local %pcallC% = pcall
-- Builtins the hash check uses, captured here so a program that rebinds a
-- global (type, string, ...) cannot make the check throw. %byte% above is the
-- captured string.byte.
local %typeC% = type
local %dbgLib% = nil
local %hookFn% = nil
local %infoFn% = nil
local %coRunFn% = nil
-- Names used by the checks, decoded once here so a check costs table lookups
-- and no decoding.
local %NM% = {}
if __XS_ANTIDEBUG__ then
  %NM%.debug = %dname%(__XS_NM_DEBUG__)
  %NM%.gethook = %dname%(__XS_NM_GETHOOK__)
  %NM%.getinfo = %dname%(__XS_NM_GETINFO__)
  %NM%.coroutine = %dname%(__XS_NM_COROUTINE__)
  %NM%.running = %dname%(__XS_NM_RUNNING__)
  local %dok%, %dlib% = %pcallC%(function() return %base%[%NM%.debug] end)
  if %dok% and %dlib% then
    local %gok%, %gfn% = %pcallC%(function() return %dlib%[%NM%.gethook] end)
    local %iok%, %ifn% = %pcallC%(function() return %dlib%[%NM%.getinfo] end)
    if %gok% and %gfn% and %iok% and %ifn% then
      %dbgLib% = %dlib%; %hookFn% = %gfn%; %infoFn% = %ifn%
    end
  end
  local %cok%, %cof% = %pcallC%(function() return %base%[%NM%.coroutine][%NM%.running] end)
  if %cok% and %cof% then %coRunFn% = %cof% end
end

-- Each check returns a number: 0 when it sees nothing, nonzero when it does.
-- Nothing branches on a check's outcome. The result is summed into %adMix%
-- and the key is derived from it, so removing one check's effect changes the
-- decoded values, not just one flag. Each check takes its inputs as a table,
-- so the same code runs on the live environment and on the mocks below.
-- 1: a debug hook is set on the main thread.
local %ck1% = function(%e%)
  if not %e%.hook then return 0 end
  local %ok%, %h%  = %pcallC%(%e%.hook)
  if %ok% and %h% ~= nil then return 53 end
  return 0
end
-- 2: a debug hook is set on the running coroutine.
local %ck2% = function(%e%)
  if not (%e%.hook and %e%.coRun) then return 0 end
  local %ok%, %co% = %pcallC%(%e%.coRun)
  if not (%ok% and %co%) then return 0 end
  local %gok%, %gh% = %pcallC%(%e%.hook, %co%)
  if %gok% and %gh% ~= nil then return 61 end
  return 0
end
-- 3: the captured debug functions must themselves be the engine's C functions
-- (a wrapper installed before load is a Lua function).
local %ck3% = function(%e%)
  if not (%e%.dbg and %e%.hook and %e%.info) then return 0 end
  local %a%, %ai% = %pcallC%(%e%.info, %e%.info, "S")
  if %a% and %ai% and %ai%.what ~= "C" then return 71 end
  local %b%, %bi% = %pcallC%(%e%.info, %e%.hook, "S")
  if %b% and %bi% and %bi%.what ~= "C" then return 89 end
  return 0
end
-- 4: the debug library and its fields still hold what was captured at load.
local %ck4% = function(%e%)
  if not %e%.dbg then return 0 end
  if %e%.liveDbg ~= %e%.dbg then return 97 end
  if %e%.liveHook ~= %e%.hook then return 41 end
  if %e%.liveInfo ~= %e%.info then return 13 end
  return 0
end
local %CKS% = { %ck1%, %ck2%, %ck3%, %ck4% }

-- Live inputs for the checks, read now. Without a debug library every live
-- value equals its captured value, so the comparisons agree. One table is
-- reused for every call.
local %RE% = { }
local %realEnv% = function()
  local %e% = %RE%
  %e%.hook = %hookFn%; %e%.coRun = %coRunFn%; %e%.info = %infoFn%; %e%.dbg = %dbgLib%
  if %dbgLib% then
    %e%.liveDbg = %base%[%NM%.debug]
    %e%.liveHook = %dbgLib%[%NM%.gethook]
    %e%.liveInfo = %dbgLib%[%NM%.getinfo]
  else
    %e%.liveDbg, %e%.liveHook, %e%.liveInfo = nil, %hookFn%, %infoFn%
  end
  return %e%
end

-- Known-answer self-test (works on every Lua version and on Luau). Each check
-- runs on mock inputs whose correct result is known. A check that was patched
-- to return something else disagrees with at least one mock. The mocks and
-- their expected results are built once, at load. %selfTest% returns the
-- number of disagreements.
local %hookOn% = function() return true end
local %hookOff% = function() return nil end
local %coHook% = function(%th%) if %th% then return true end end
local %coStub% = function() return "co" end
local %infoLua% = function() return { what = "Lua" } end
local %infoC% = function() return { what = "C" } end
local %dd% = {}
local %STC% = {
  { %ck1%, { hook = %hookOn% }, 53 },
  { %ck1%, { hook = %hookOff% }, 0 },
  { %ck2%, { hook = %coHook%, coRun = %coStub% }, 61 },
  { %ck2%, { hook = %hookOff%, coRun = %coStub% }, 0 },
  { %ck3%, { dbg = %dd%, hook = %hookOff%, info = %infoLua% }, 71 },
  { %ck3%, { dbg = %dd%, hook = %hookOff%, info = %infoC% }, 0 },
  { %ck4%, { dbg = %dd%, hook = %hookOff%, info = %infoC%,
      liveDbg = {}, liveHook = %hookOff%, liveInfo = %infoC% }, 97 },
  { %ck4%, { dbg = %dd%, hook = %hookOff%, info = %infoC%,
      liveDbg = %dd%, liveHook = %hookOff%, liveInfo = %infoC% }, 0 },
}
local %selfTest% = function()
  local %bad% = 0
  for %ti% = 1, #%STC% do
    local %t% = %STC%[%ti%]
    if %t%[1](%t%[2]) ~= %t%[3] then %bad% = %bad% + 1 end
  end
  return %bad%
end

-- Code check: each check's string.dump (stripped) hashed at build time. The
-- build fills %CKH% and %DPFX%; a zero hash disables that check (Luau, or a
-- build made without a Lua 5.3 probe). A dump of another Lua version or
-- platform does not start with %DPFX%, so the test is skipped there.
local %CKH% = { __XS_CKH__ }
local %DPFX% = __XS_DPFX__
local %sdump% = string and string.dump
local function %ckDump%(%f%)
  if not %sdump% then return nil end
  local %ok%, %s% = %pcallC%(%sdump%, %f%, true)
  if not %ok% or %typeC%(%s%) ~= "string" then return nil end
  for %j% = 1, #%DPFX% do
    if %byte%(%s%, %j%) ~= %byte%(%DPFX%, %j%) then return nil end
  end
  local %h% = 5381
  for %j% = 1, #%s% do %h% = (%h% * 31 + %byte%(%s%, %j%)) % 2147483647 end
  return %h%
end

-- Index 1-4: run a check on the live inputs. Index 5: the known-answer
-- self-test. Index 11-14: the code hash of check 1-4 (kept off the decoders'
-- path, since hashing is much more work than a live check). A disagreement
-- adds to the state.
%adStep% = function(%si%)
  if not __XS_ANTIDEBUG__ then return end
  if %si% > 10 then
    local %k% = %si% - 10
    local %want% = %CKH%[%k%]
    if %want% and %want% ~= 0 then
      local %got% = %ckDump%(%CKS%[%k%])
      if %got% and %got% ~= %want% then %adMix% = (%adMix% + 113) % 65521 end
    end
    return
  end
  if %si% == 5 then
    %adMix% = (%adMix% + %selfTest%() * 127) % 65521
    return
  end
  %adMix% = (%adMix% + %CKS%[%si%](%realEnv%())) % 65521
end
if __XS_ANTIDEBUG__ then
  for %sk% = 1, 5 do %adStep%(%sk%) end
  for %sk% = 11, 14 do %adStep%(%sk%) end
end

]===]
