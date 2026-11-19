return [===[
-- Hook check (hookCheck builds only). Reads debug.gethook and debug.sethook once,
-- at load. A foreign hook is reported by check 1 (see %ck1%). A deobfuscator
-- that replaces debug.gethook can make that read clean, so the sentinel test
-- below installs a hook of its own and reads it back: a replacement that
-- disagrees with itself is caught there.
%NM%.debug = %dname%(__XS_NM_DEBUG__)
%NM%.gethook = %dname%(__XS_NM_GETHOOK__)
%NM%.sethook = %dname%(__XS_NM_SETHOOK__)
local %hookGet% = nil
local %hookSet% = nil
do
  local %dok%, %dlib% = %pcallC%(function() return %base%[%NM%.debug] end)
  if %dok% and %dlib% then
    local %gok%, %gf% = %pcallC%(function() return %dlib%[%NM%.gethook] end)
    local %sok%, %sf% = %pcallC%(function() return %dlib%[%NM%.sethook] end)
    if %gok% and %gf% then %hookGet% = %gf% end
    if %sok% and %sf% then %hookSet% = %sf% end
  end
end

-- Returns the number of disagreements: 0 on a clean run, and 0 when the
-- library is absent. The count mask never fires in the few steps it is set.
local %hookST% = function()
  local %set% = %hookSet%
  local %get% = %hookGet%
  if not %set% or not %get% then return 0 end
  local %bad% = 0
  local %sent% = function() end
  %set%(%sent%, "", 1000000)
  if %get%() ~= %sent% then %bad% = %bad% + 1 end
  %set%()
  if %get%() ~= nil then %bad% = %bad% + 1 end
  return %bad%
end
]===]
