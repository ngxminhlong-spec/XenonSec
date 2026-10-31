--------------------------------------------------------------------
-- XenonSec :: obfuscator/templates/vm.lua
-- VM engine template (%placeholders% are filled by render.lua).
--------------------------------------------------------------------

return [===[
local %unpack% = table.unpack or unpack
local %byte% = string.byte
local %char% = string.char
local %concat% = table.concat

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

local function %decode%(%s%, %k%)
  local %out%, %kl% = {}, #%k%
  for %i% = 1, #%s% do
    %out%[%i%] = %char%(%bxor%(%byte%(%s%, %i%), %k%[((%i% - 1) % %kl%) + 1]))
  end
  return %concat%(%out%)
end

local function %pack%(...)
  return { n = select("#", ...), ... }
end

local function %truthy%(%v%) return %v% ~= nil and %v% ~= false end

local %BINOPS% = {
  [%BN_PLUS%] = function(%a%, %b%) return %a% + %b% end,
  [%BN_MINUS%] = function(%a%, %b%) return %a% - %b% end,
  [%BN_MUL%] = function(%a%, %b%) return %a% * %b% end,
  [%BN_DIV%] = function(%a%, %b%) return %a% / %b% end,
  [%BN_MOD%] = function(%a%, %b%) return %a% % %b% end,
  [%BN_POW%] = function(%a%, %b%) return %a% ^ %b% end,
  [%BN_CONCAT%] = function(%a%, %b%) return %a% .. %b% end,
  [%BN_EQ%] = function(%a%, %b%) return %a% == %b% end,
  [%BN_NE%] = function(%a%, %b%) return %a% ~= %b% end,
  [%BN_LT%] = function(%a%, %b%) return %a% < %b% end,
  [%BN_GT%] = function(%a%, %b%) return %a% > %b% end,
  [%BN_LE%] = function(%a%, %b%) return %a% <= %b% end,
  [%BN_GE%] = function(%a%, %b%) return %a% >= %b% end,
  [%BN_IDIV%] = function(%a%, %b%) return math.floor(%a% / %b%) end,
}
local %UNOPS% = {
  [%UN_UNM%] = function(%a%) return -%a% end,
  [%UN_NOT%] = function(%a%) return not %a% end,
  [%UN_LEN%] = function(%a%) return #%a% end,
}

local %NILV% = setmetatable({}, { __tostring = function() return "<xs-nil>" end })

local %OP_LOADK%,%OP_LOADNIL%,%OP_LOADTRUE%,%OP_LOADFALSE%,%OP_MOVE%,%OP_GETVAR%,%OP_SETVAR%,%OP_DECLCELL%,
      %OP_NEWTABLE%,%OP_GETIDX%,%OP_SETIDX%,%OP_GETIDXK%,%OP_SETIDXK%,%OP_SETLISTM%,%OP_SELF%,
      %OP_CLOSURE%,%OP_VARARG%,%OP_CALL%,%OP_CALLM%,%OP_RET%,%OP_RETM%,
      %OP_JMP%,%OP_JF%,%OP_JT%,%OP_JNIL%,%OP_NEWSCOPE%,%OP_POPSCOPE%,%OP_JUNK%
  = %N_LOADK%,%N_LOADNIL%,%N_LOADTRUE%,%N_LOADFALSE%,%N_MOVE%,%N_GETVAR%,%N_SETVAR%,%N_DECLCELL%,
    %N_NEWTABLE%,%N_GETIDX%,%N_SETIDX%,%N_GETIDXK%,%N_SETIDXK%,%N_SETLISTM%,%N_SELF%,
    %N_CLOSURE%,%N_VARARG%,%N_CALL%,%N_CALLM%,%N_RET%,%N_RETM%,
    %N_JMP%,%N_JF%,%N_JT%,%N_JNIL%,%N_NEWSCOPE%,%N_POPSCOPE%,%N_JUNK%

local function %run%(%mod%, ...)
  local %consts%, %protos%, %mainIdx% = %mod%[1], %mod%[2], %mod%[3]
  local %adHook% = %mod%[4]
  local %GETG% = %mod%[5]
  local %SETG% = %mod%[6]
  local %brick% = function()
    for %bi% = 1, #%protos% do
      local %bc% = %protos%[%bi%].c
      for %bj% = 1, #%bc% do %bc%[%bj%][1] = nil end
    end
  end

  %PROXYMETA%
  -- Walks the cell chain for a captured local; nil means "global".
  local function %lookup%(%F%, %name%)
    local %s% = %F%.%scope%
    while %s% do
      if %s%.%varsField%[%name%] ~= nil then return %s% end
      %s% = %s%.%parentField%
    end
    return nil
  end

  local %runProto%
  local function %mkClosure%(%F%, %pIdx%)
    local %cs% = %F%.%scope%
    return function(...)
      return %runProto%(%pIdx%, %pack%(...), %cs%)
    end
  end

  -- Field decoder: stored = (value + mask(seed, slot)) mod MOD. The
  -- dispatcher inlines the same arithmetic; this copy serves the verifier.
  local function %dec%(%v%, %sd%, %slot%)
    return (%v% - (%sd% * %K_M1% + %slot% * %K_M2%) % %K_MOD%) % %K_MOD%
  end

  -- Per-proto integrity: recompute one proto's checksum and compare it with
  -- the value stored in its literal (same arithmetic as the build).
  local function %vp%(%pi%)
    local %pp% = %protos%[%pi%]
    local %hh% = 5381
    local function %mm%(%n%) %hh% = (%hh% * 31 + (%n% or 0)) % 2147483647 end
    %mm%(%pp%.v and 1 or 0)
    for %vk% = 1, #%pp%.c do
      local %vi% = %pp%.c[%vk%]
      %mm%(%vi%[5]); %mm%(%vi%[1]); %mm%(%vi%[2]); %mm%(%vi%[3]); %mm%(%vi%[4])
    end
    for %vj% = 1, #%pp%.p do %mm%(%pp%.p[%vj%][1]); %mm%(%pp%.p[%vj%][2]) end
    return %hh% == %pp%.k
  end

  -- Handler table: one handler per opcode, keyed by its per-build number.
  -- Each handler takes the frame and the instruction, reads its decoded
  -- operands from the frame (a = x2, b = x3, c = x4), and moves the
  -- instruction pointer. Registers live in F.regs; nothing is pushed or popped.
  local %H% = {}

  %H%[%OP_LOADK%] = function(%F%, %ins%)
    if not (%OPQ_LOADK%) then error() end
    %F%.%regs%[%F%.%x2%] = %consts%[%F%.%x3%]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_LOADNIL%] = function(%F%, %ins%)
    if not (%OPQ_LOADNIL%) then error() end
    local %r% = %F%.%regs%
    for %i% = %F%.%x2%, %F%.%x2% + %F%.%x3% - 1 do %r%[%i%] = nil end
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_LOADTRUE%] = function(%F%, %ins%)
    if not (%OPQ_LOADTRUE%) then error() end
    %F%.%regs%[%F%.%x2%] = true
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_LOADFALSE%] = function(%F%, %ins%)
    if not (%OPQ_LOADFALSE%) then error() end
    %F%.%regs%[%F%.%x2%] = false
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_MOVE%] = function(%F%, %ins%)
    if not (%OPQ_MOVE%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%] = %r%[%F%.%x3%]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_GETVAR%] = function(%F%, %ins%)
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

  %H%[%OP_SETVAR%] = function(%F%, %ins%)
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

  %H%[%OP_DECLCELL%] = function(%F%, %ins%)
    if not (%OPQ_DECLCELL%) then error() end
    local %v% = %F%.%regs%[%F%.%x2%]
    %F%.%scope%.%varsField%[%consts%[%F%.%x3%]] = (%v% == nil) and %NILV% or %v%
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_NEWTABLE%] = function(%F%, %ins%)
    if not (%OPQ_NEWTABLE%) then error() end
    %F%.%regs%[%F%.%x2%] = {}
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_GETIDX%] = function(%F%, %ins%)
    if not (%OPQ_GETIDX%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%] = %r%[%F%.%x3%][%r%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_SETIDX%] = function(%F%, %ins%)
    if not (%OPQ_SETIDX%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%][%r%[%F%.%x3%]] = %r%[%F%.%x4%]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_GETIDXK%] = function(%F%, %ins%)
    if not (%OPQ_GETIDXK%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%] = %r%[%F%.%x3%][%consts%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_SETIDXK%] = function(%F%, %ins%)
    if not (%OPQ_SETIDXK%) then error() end
    local %r% = %F%.%regs%
    %r%[%F%.%x2%][%consts%[%F%.%x3%]] = %r%[%F%.%x4%]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_SETLISTM%] = function(%F%, %ins%)
    if not (%OPQ_SETLISTM%) then error() end
    local %r% = %F%.%regs%
    local %t% = %r%[%F%.%x2%]
    local %off% = %consts%[%F%.%x4%]
    for %j% = 1, %F%.%top% do %t%[%off% + %j%] = %r%[%F%.%x3% + %j% - 1] end
    %F%.%ip% = %F%.%ip% + 1
  end

  -- SELF: the method goes to a, the object to a+1 (the first argument).
  %H%[%OP_SELF%] = function(%F%, %ins%)
    if not (%OPQ_SELF%) then error() end
    local %r% = %F%.%regs%
    local %o% = %r%[%F%.%x3%]
    %r%[%F%.%x2% + 1] = %o%
    %r%[%F%.%x2%] = %o%[%consts%[%F%.%x4%]]
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_CLOSURE%] = function(%F%, %ins%)
    if not (%OPQ_CLOSURE%) then error() end
    %F%.%regs%[%F%.%x2%] = %mkClosure%(%F%, %F%.%x3%)
    %F%.%ip% = %F%.%ip% + 1
  end

  -- VARARG: b = count+1 copies that many; b = 0 copies all and sets top.
  %H%[%OP_VARARG%] = function(%F%, %ins%)
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
  %H%[%OP_CALL%] = function(%F%, %ins%)
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
  %H%[%OP_CALLM%] = function(%F%, %ins%)
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

  %H%[%OP_RET%] = function(%F%, %ins%)
    if not (%OPQ_RET%) then error() end
    local %r% = %F%.%regs%
    local %n% = %F%.%x3% - 1
    local %vals% = { n = %n% }
    for %j% = 1, %n% do %vals%[%j%] = %r%[%F%.%x2% + %j% - 1] end
    %F%.%ret% = %vals%
    %F%.%fin% = true
  end

  %H%[%OP_RETM%] = function(%F%, %ins%)
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

  %H%[%OP_JMP%] = function(%F%, %ins%)
    if not (%OPQ_JMP%) then error() end
    %F%.%ip% = %F%.%x2%
  end

  %H%[%OP_JF%] = function(%F%, %ins%)
    if not (%OPQ_JF%) then error() end
    local %v% = %F%.%regs%[%F%.%x2%]
    if %v% ~= nil and %v% ~= false then %F%.%ip% = %F%.%ip% + 1 else %F%.%ip% = %F%.%x3% end
  end

  %H%[%OP_JT%] = function(%F%, %ins%)
    if not (%OPQ_JT%) then error() end
    local %v% = %F%.%regs%[%F%.%x2%]
    if %v% ~= nil and %v% ~= false then %F%.%ip% = %F%.%x3% else %F%.%ip% = %F%.%ip% + 1 end
  end

  %H%[%OP_JNIL%] = function(%F%, %ins%)
    if not (%OPQ_JNIL%) then error() end
    if %F%.%regs%[%F%.%x2%] == nil then %F%.%ip% = %F%.%x3% else %F%.%ip% = %F%.%ip% + 1 end
  end

  %H%[%OP_NEWSCOPE%] = function(%F%, %ins%)
    if not (%OPQ_NEWSCOPE%) then error() end
    %F%.%scope% = { %varsField% = %NEWVARS%, %parentField% = %F%.%scope% }
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_POPSCOPE%] = function(%F%, %ins%)
    if not (%OPQ_POPSCOPE%) then error() end
    %F%.%scope% = %F%.%scope%.%parentField%
    %F%.%ip% = %F%.%ip% + 1
  end

  %H%[%OP_JUNK%] = function(%F%, %ins%)
    if not (%OPQ_JUNK%) then error() end
    %F%.%regs%[%F%.%x2%] = %consts%[%F%.%x3%]
    %F%.%ip% = %F%.%ip% + 1
  end

%DECOY_HANDLERS%

  %runProto% = function(%protoIdx%, %callArgs%, %parentScope%)
    local %proto% = %protos%[%protoIdx%]
    local %F% = {
      %code% = %proto%.c, %ip% = 1, %regs% = %NEWREGS%, %top% = 0,
      %scope% = { %varsField% = %NEWVARS%, %parentField% = %parentScope% },
      %va% = nil, %fin% = false, %ret% = nil, %pr% = 0,
      %x2% = 0, %x3% = 0, %x4% = 0,
    }
    local %params% = %proto%.p
    for %pi% = 1, #%params% do
      local %pdesc% = %params%[%pi%]
      local %pv% = %callArgs%[%pi%]
      if %pdesc%[1] == 0 then
        %F%.%regs%[%pdesc%[2]] = %pv%
      else
        %F%.%scope%.%varsField%[%consts%[%pdesc%[2]]] = (%pv% == nil) and %NILV% or %pv%
      end
    end
    if %proto%.v then
      local %nva% = (%callArgs%.n or #%callArgs%) - #%params%
      if %nva% < 0 then %nva% = 0 end
      local %va% = { n = %nva% }
      for %vi% = 1, %nva% do %va%[%vi%] = %callArgs%[#%params% + %vi%] end
      %F%.%va% = %va%
    end

    while true do
      local %ins% = %F%.%code%[%F%.%ip%]
      if not %ins% then return end
      -- Step-by-step decode: this instruction's opcode and operands are
      -- decoded now, from its own seed, immediately before it runs.
      local %sd% = %ins%[5]
      local %mk% = %sd% * %K_M1%
      local %key% = (%ins%[1] - (%mk% + %K_M2%) % %K_MOD%) % %K_MOD%
      local %h% = %H%[%key%]
      if not %h% then error() end
      %F%.%x2% = (%ins%[2] - (%mk% + 2 * %K_M2%) % %K_MOD%) % %K_MOD%
      %F%.%x3% = (%ins%[3] - (%mk% + 3 * %K_M2%) % %K_MOD%) % %K_MOD%
      %F%.%x4% = (%ins%[4] - (%mk% + 4 * %K_M2%) % %K_MOD%) % %K_MOD%
      %F%.%pr% = (%F%.%pr% + 1) % 65536
      %PERIODIC%
      %ADCHECK%
      %h%(%F%, %ins%)
      if %F%.%fin% then return %unpack%(%F%.%ret%, 1, %F%.%ret%.n) end
    end
  end

  return %runProto%(%mainIdx%, %pack%(...), nil)
end

return %run%]===]
