--------------------------------------------------------------------
-- XenonSec :: obfuscator/templates/footer.lua
-- Output footer: integrity check and the engine call.
--------------------------------------------------------------------

return [===[
if not %verify%() then %corrupt%() end
%ENG% = %engine%
return %ENG%({ %consts%, %protos%, __XS_MAIN__, %adStep%, %GETG%, %SETG%, %dproto%, %poison% }, ...)]===]
