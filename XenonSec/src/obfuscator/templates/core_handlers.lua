--------------------------------------------------------------------
-- XenonSec :: obfuscator/templates/core_handlers.lua
-- Core handler definitions, one string per handler. The renderer emits them
-- in a random order each build; each is a plain assignment into the handler
-- table %H%. ANN_F / ANN_I are Luau annotations, empty in plain Lua output.
--------------------------------------------------------------------

return {
[==[
  %H%[%OP_LOADK%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_LOADK%) then error() end
    %F%.%regs%[%F%.%x2%] = %consts%[%F%.%x3%]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_LOADNIL%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_LOADNIL%) then error() end
    local %r% = %F%.%regs%
    for %i% = %F%.%x2%, %F%.%x2% + %F%.%x3% - 1 do %r%[%i%] = nil end
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_LOADTRUE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_LOADTRUE%) then error() end
    %F%.%regs%[%F%.%x2%] = true
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_LOADFALSE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_LOADFALSE%) then error() end
    %F%.%regs%[%F%.%x2%] = false
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_MOVE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_MOVE%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%] = %r%[%F%.%x3%]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_GETVAR%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_GETVAR%) then error() end
    local %nm% = %consts%[%F%.%x3%]
    local %sc% = %lookup%(%F%, %nm%)
    local %r% = %F%.%regs%
    if %sc% then
      local %v% = %sc%.%varsField%[%nm%]
      if %v% == %NILV% then %r%[%F%.%x2%] = nil else %r%[%F%.%x2%] = %v% end
    else
      %r%[%F%.%x2%] = %GETG%(%nm%)
    end
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_SETVAR%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_SETVAR%) then error() end
    local %nm% = %consts%[%F%.%x3%]
    local %v% = %F%.%regs%[%F%.%x2%]
    local %sc% = %lookup%(%F%, %nm%)
    if %sc% then
      %sc%.%varsField%[%nm%] = (%v% == nil) and %NILV% or %v%
    else
      %SETG%(%nm%, %v%)
    end
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_DECLCELL%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_DECLCELL%) then error() end
    local %v% = %F%.%regs%[%F%.%x2%]
    %F%.%scope%.%varsField%[%consts%[%F%.%x3%]] = (%v% == nil) and %NILV% or %v%
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_NEWTABLE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_NEWTABLE%) then error() end
    %F%.%regs%[%F%.%x2%] = {}
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_GETIDX%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_GETIDX%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%] = %r%[%F%.%x3%][%r%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_SETIDX%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_SETIDX%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%][%r%[%F%.%x3%]] = %r%[%F%.%x4%]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_GETIDXK%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_GETIDXK%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%] = %r%[%F%.%x3%][%consts%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_SETIDXK%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_SETIDXK%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%][%consts%[%F%.%x3%]] = %r%[%F%.%x4%]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_SETLISTM%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_SETLISTM%) then error() end
    local %r% = %F%.%regs%
    local %t% = %r%[%F%.%x2%]
    local %off% = %consts%[%F%.%x4%]
    for %j% = 1, %F%.%top% do %t%[%off% + %j%] = %r%[%F%.%x3% + %j% - 1] end
    %F%.%ip% = %F%.%ip% + 1
  end

  -- SELF: the method goes to a, the object to a+1 (the first argument).
]==],
[==[
  %H%[%OP_SELF%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_SELF%) then error() end
    local %r% = %F%.%regs%
    local %o% = %r%[%F%.%x3%]
    %r%[%F%.%x2% + 1] = %o%
    %r%[%F%.%x2%] = %o%[%consts%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_CLOSURE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_CLOSURE%) then error() end
    %F%.%regs%[%F%.%x2%] = %mkClosure%(%F%, %F%.%x3%)
    %F%.%ip% = %F%.%ip% + 1
  end

  -- VARARG: b = count+1 copies that many; b = 0 copies all and sets top.
]==],
[==[
  %H%[%OP_VARARG%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_VARARG%) then error() end
    local %r% = %F%.%regs%
    local %vav% = %F%.%va%
    local %a% = %F%.%x2%
    if %F%.%x3% == 0 then
      local %n% = %vav% and %vav%.n or 0
      for %j% = 1, %n% do %r%[%a% + %j% - 1] = %vav%[%j%] end
      %F%.%top% = %n%
    else
      for %j% = 1, %F%.%x3% - 1 do
        local %vv% = nil
        if %vav% then %vv% = %vav%[%j%] end
        %r%[%a% + %j% - 1] = %vv%
      end
    end
    %F%.%ip% = %F%.%ip% + 1
  end

  -- CALL: fn = r[a], args = r[a+1 .. a+b-1]; results to r[a ..] (c-1 of them,
  -- or all with the count in top when c = 0).
]==],
[==[
  %H%[%OP_CALL%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_CALL%) then error() end
    local %r% = %F%.%regs%
    local %a% = %F%.%x2%
    local %fn% = %r%[%a%]
    local %n% = %F%.%x3% - 1
    local %args% = {}
    for %j% = 1, %n% do %args%[%j%] = %r%[%a% + %j%] end
    local %res% = %pack%(%fn%(%unpack%(%args%, 1, %n%)))
    local %c% = %F%.%x4%
    if %c% == 0 then
      for %j% = 1, %res%.n do %r%[%a% + %j% - 1] = %res%[%j%] end
      %F%.%top% = %res%.n
    else
      for %j% = 1, %c% - 1 do %r%[%a% + %j% - 1] = %res%[%j%] end
    end
    %F%.%ip% = %F%.%ip% + 1
  end

  -- CALLM: like CALL, but the arguments after the fixed ones come from top.
]==],
[==[
  %H%[%OP_CALLM%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_CALLM%) then error() end
    local %r% = %F%.%regs%
    local %a% = %F%.%x2%
    local %fn% = %r%[%a%]
    local %fx% = %F%.%x3% - 1
    local %tp% = %F%.%top%
    local %args% = {}
    for %j% = 1, %fx% do %args%[%j%] = %r%[%a% + %j%] end
    for %j% = 1, %tp% do %args%[%fx% + %j%] = %r%[%a% + %fx% + %j%] end
    local %res% = %pack%(%fn%(%unpack%(%args%, 1, %fx% + %tp%)))
    local %c% = %F%.%x4%
    if %c% == 0 then
      for %j% = 1, %res%.n do %r%[%a% + %j% - 1] = %res%[%j%] end
      %F%.%top% = %res%.n
    else
      for %j% = 1, %c% - 1 do %r%[%a% + %j% - 1] = %res%[%j%] end
    end
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_RET%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_RET%) then error() end
    local %r% = %F%.%regs%
    local %n% = %F%.%x3% - 1
    local %vals% = { n = %n% }
    for %j% = 1, %n% do %vals%[%j%] = %r%[%F%.%x2% + %j% - 1] end
    %F%.%ret% = %vals%
    %F%.%fin% = true
  end
]==],
[==[
  %H%[%OP_RETM%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_RETM%) then error() end
    local %r% = %F%.%regs%
    local %a% = %F%.%x2%
    local %fx% = %F%.%x3% - 1
    local %tp% = %F%.%top%
    local %vals% = {}
    for %j% = 1, %fx% do %vals%[%j%] = %r%[%a% + %j% - 1] end
    for %j% = 1, %tp% do %vals%[%fx% + %j%] = %r%[%a% + %fx% + %j% - 1] end
    %vals%.n = %fx% + %tp%
    %F%.%ret% = %vals%
    %F%.%fin% = true
  end
]==],
[==[
  %H%[%OP_JMP%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_JMP%) then error() end
    %F%.%ip% = %F%.%x2%
  end
]==],
[==[
  %H%[%OP_JF%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_JF%) then error() end
    local %v% = %F%.%regs%[%F%.%x2%]
    if %v% ~= nil and %v% ~= false then %F%.%ip% = %F%.%ip% + 1 else %F%.%ip% = %F%.%x3% end
  end
]==],
[==[
  %H%[%OP_JT%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_JT%) then error() end
    local %v% = %F%.%regs%[%F%.%x2%]
    if %v% ~= nil and %v% ~= false then %F%.%ip% = %F%.%x3% else %F%.%ip% = %F%.%ip% + 1 end
  end
]==],
[==[
  %H%[%OP_JNIL%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_JNIL%) then error() end
    if %F%.%regs%[%F%.%x2%] == nil then %F%.%ip% = %F%.%x3% else %F%.%ip% = %F%.%ip% + 1 end
  end
]==],
[==[
  %H%[%OP_NEWSCOPE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_NEWSCOPE%) then error() end
    %F%.%scope% = { %varsField% = %NEWVARS%, %parentField% = %F%.%scope% }
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_POPSCOPE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_POPSCOPE%) then error() end
    %F%.%scope% = %F%.%scope%.%parentField%
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
[==[
  %H%[%OP_JUNK%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_JUNK%) then error() end
    %F%.%regs%[%F%.%x2%] = %consts%[%F%.%x3%]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
}
