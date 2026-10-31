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

%CORE_HANDLERS%

%DECOY_HANDLERS%

%HANDLER_SELFTEST%

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
