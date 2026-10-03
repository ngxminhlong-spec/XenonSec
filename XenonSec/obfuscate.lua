--------------------------------------------------------------------
-- XenonSec :: public API
-- Stable root entrypoint; implementation lives in src/obfuscator.lua.
--------------------------------------------------------------------
local scriptDir = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./")
return dofile(scriptDir .. "src/obfuscator.lua")
