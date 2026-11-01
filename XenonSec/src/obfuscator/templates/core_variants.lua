--------------------------------------------------------------------
-- XenonSec :: obfuscator/templates/core_variants.lua
-- Metamorphic alternatives for core handlers. Each entry maps an opcode
-- placeholder (OP_NAME) to extra bodies that do exactly what the default
-- block in core_handlers.lua does, written with different statement order,
-- local aliases, and expression shapes. Each build picks one of the default
-- and its alternatives at random, so two builds of the same script expose
-- different handler code. The handler self-test runs the chosen body, so a
-- variant that changed behavior would brick the build instead of passing
-- silently.
--
-- Every alternative keeps the same wrapper: the opaque-predicate gate first,
-- and ip + 1 (or the jump target) last.
--------------------------------------------------------------------

return {
OP_LOADK = {
[==[
  %H%[%OP_LOADK%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_LOADK%) then error() end
    %F%.%ip% = %F%.%ip% + 1
    %F%.%regs%[%F%.%x2%] = %consts%[%F%.%x3%]
  end
]==],
[==[
  %H%[%OP_LOADK%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_LOADK%) then error() end
    local %r%, %k% = %F%.%regs%, %consts%[%F%.%x3%]
    %r%[%F%.%x2%] = %k%
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
},
OP_LOADTRUE = {
[==[
  %H%[%OP_LOADTRUE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_LOADTRUE%) then error() end
    %F%.%regs%[%F%.%x2%] = (1 == 1)
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
},
OP_LOADFALSE = {
[==[
  %H%[%OP_LOADFALSE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_LOADFALSE%) then error() end
    %F%.%regs%[%F%.%x2%] = (1 ~= 1)
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
},
OP_MOVE = {
[==[
  %H%[%OP_MOVE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_MOVE%) then error() end
    local %r% = %F%.%regs%
    local %v% = %r%[%F%.%x3%]
    %r%[%F%.%x2%] = %v%
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
},
OP_NEWTABLE = {
[==[
  %H%[%OP_NEWTABLE%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_NEWTABLE%) then error() end
    local %t% = {}
    %F%.%regs%[%F%.%x2%] = %t%
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
},
OP_GETIDX = {
[==[
  %H%[%OP_GETIDX%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_GETIDX%) then error() end
    local %r% = %F%.%regs%
    local %o% = %r%[%F%.%x3%]
    %r%[%F%.%x2%] = %o%[%r%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
},
OP_SETIDX = {
[==[
  %H%[%OP_SETIDX%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_SETIDX%) then error() end
    local %r% = %F%.%regs%
    local %o% = %r%[%F%.%x2%]
    %o%[%r%[%F%.%x3%]] = %r%[%F%.%x4%]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
},
OP_GETIDXK = {
[==[
  %H%[%OP_GETIDXK%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_GETIDXK%) then error() end
    local %r% = %F%.%regs%
    local %o% = %r%[%F%.%x3%]
    %r%[%F%.%x2%] = %o%[%consts%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
},
OP_SETIDXK = {
[==[
  %H%[%OP_SETIDXK%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_SETIDXK%) then error() end
    local %r% = %F%.%regs%
    local %o% = %r%[%F%.%x2%]
    %o%[%consts%[%F%.%x3%]] = %r%[%F%.%x4%]
    %F%.%ip% = %F%.%ip% + 1
  end
]==],
},
OP_JMP = {
[==[
  %H%[%OP_JMP%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_JMP%) then error() end
    %F%.%st% = 0
    %F%.%ip% = 0 + %F%.%x2%
  end
]==],
},
OP_JF = {
[==[
  %H%[%OP_JF%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_JF%) then error() end
    %F%.%st% = 0
    if %F%.%regs%[%F%.%x2%] then %F%.%ip% = %F%.%ip% + 1 else %F%.%ip% = %F%.%x3% end
  end
]==],
},
OP_JT = {
[==[
  %H%[%OP_JT%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_JT%) then error() end
    %F%.%st% = 0
    if %F%.%regs%[%F%.%x2%] then %F%.%ip% = %F%.%x3% else %F%.%ip% = %F%.%ip% + 1 end
  end
]==],
},
OP_JNIL = {
[==[
  %H%[%OP_JNIL%] = function(%F%%ANN_F%, %ins%%ANN_I%)
    if not (%OPQ_JNIL%) then error() end
    %F%.%st% = 0
    if %F%.%regs%[%F%.%x2%] ~= nil then %F%.%ip% = %F%.%ip% + 1 else %F%.%ip% = %F%.%x3% end
  end
]==],
},
}
