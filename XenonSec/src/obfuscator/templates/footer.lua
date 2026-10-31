--------------------------------------------------------------------
-- XenonSec :: obfuscator/templates/footer.lua
-- Output footer: integrity check and the engine call.
--------------------------------------------------------------------

return [===[
if not %verify%() then %corrupt%() end
return (%engine%)({ %consts%, %protos%, __XS_MAIN__, %adHook%, %GETG%, %SETG%, %dproto%, %poison% }, ...)]===]
