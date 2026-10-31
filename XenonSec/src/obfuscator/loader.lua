--------------------------------------------------------------------
-- XenonSec :: obfuscator/loader.lua
-- Memoized dofile() for the obfuscator's own modules. Modules are cached in
-- package.loaded, so each one is loaded exactly once per process. This
-- matters for crypto.lua: its per-build CIPHER parameters are module state,
-- and every user must see the same table.
--------------------------------------------------------------------

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"

return function(name)
  local key = "xenonsec.obfuscator." .. name
  local m = package.loaded[key]
  if m == nil then
    m = dofile(dir .. name .. ".lua")
    package.loaded[key] = m
  end
  return m
end
