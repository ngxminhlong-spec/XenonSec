--------------------------------------------------------------------
-- XenonSec :: renamer.lua
-- Walks the AST performing REAL static lexical scope resolution
-- (mirroring Lua's binding rules exactly, including closures) and
-- replaces every identifier that resolves to a local binding with a
-- fresh, unique, meaningless token. Identifiers that never resolve to
-- a local anywhere in their scope chain are left completely alone,
-- since they must remain the real global name (e.g. "print", "pairs",
-- a global module table, etc).
--
-- This is a pure alpha-renaming pass: it never changes program
-- behaviour. It only strips away meaningful source identifiers so the
-- compiled bytecode/constant pool that follows contains no trace of
-- the original variable names.
--------------------------------------------------------------------

local Renamer = {}

local counter = 0
local function freshToken()
  counter = counter + 1
  return "\1xs" .. counter -- \1 prefix: cannot collide with any valid Lua source identifier or global name
end

local function pushFrame(stack)
  stack[#stack + 1] = {}
  return stack[#stack]
end

local function popFrame(stack)
  stack[#stack] = nil
end

local function declare(stack, name)
  local tok = freshToken()
  stack[#stack][name] = tok
  return tok
end

local function lookup(stack, name)
  for i = #stack, 1, -1 do
    local tok = stack[i][name]
    if tok then return tok end
  end
  return nil
end

local resolveExpr, resolveStat, resolveBlockBare, resolveBlockScoped, resolveFunction

function resolveExpr(node, stack)
  local kind = node.kind
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" then
    -- nothing to resolve
  elseif kind == "Name" then
    local tok = lookup(stack, node.name)
    if tok then node.name = tok end -- else: genuine global, leave spelling untouched
  elseif kind == "Index" then
    resolveExpr(node.obj, stack)
    resolveExpr(node.key, stack) -- dot-keys are String literals already; bracket-keys are real exprs
  elseif kind == "Paren" then
    resolveExpr(node.expr, stack)
  elseif kind == "Table" then
    for _, field in ipairs(node.fields) do
      if field.type == "keyed" then
        resolveExpr(field.key, stack)
        resolveExpr(field.value, stack)
      else
        resolveExpr(field.value, stack)
      end
    end
  elseif kind == "Function" then
    resolveFunction(node, stack)
  elseif kind == "Call" then
    resolveExpr(node.fn, stack)
    for _, a in ipairs(node.args) do resolveExpr(a, stack) end
  elseif kind == "MethodCall" then
    resolveExpr(node.obj, stack)
    for _, a in ipairs(node.args) do resolveExpr(a, stack) end
  elseif kind == "Binop" then
    resolveExpr(node.lhs, stack)
    resolveExpr(node.rhs, stack)
  elseif kind == "Unop" then
    resolveExpr(node.operand, stack)
  else
    error("XenonSec renamer: unknown expression kind '" .. tostring(kind) .. "'")
  end
end

-- Function body gets exactly one fresh frame that holds its params;
-- the body's own statements share that same frame unless a nested
-- block introduces its own (matching compiler.lua's compileBlockBare).
function resolveFunction(node, stack)
  pushFrame(stack)
  for i, pname in ipairs(node.params) do
    node.params[i] = declare(stack, pname)
  end
  resolveBlockBare(node.body, stack)
  popFrame(stack)
end

function resolveStat(node, stack)
  local kind = node.kind
  if kind == "Local" then
    for _, v in ipairs(node.values) do resolveExpr(v, stack) end
    for i, n in ipairs(node.names) do node.names[i] = declare(stack, n) end
  elseif kind == "LocalFunction" then
    node.name = declare(stack, node.name)
    resolveExpr(node.func, stack)
  elseif kind == "Assign" then
    for _, v in ipairs(node.values) do resolveExpr(v, stack) end
    for _, tgt in ipairs(node.targets) do
      if tgt.kind == "Name" then
        local tok = lookup(stack, tgt.name)
        if tok then tgt.name = tok end
      else
        resolveExpr(tgt.obj, stack)
        resolveExpr(tgt.key, stack)
      end
    end
  elseif kind == "ExprStat" then
    resolveExpr(node.expr, stack)
  elseif kind == "Do" then
    resolveBlockScoped(node.body, stack)
  elseif kind == "If" then
    for _, clause in ipairs(node.clauses) do
      resolveExpr(clause.cond, stack)
      resolveBlockScoped(clause.body, stack)
    end
    if node.elseBody then resolveBlockScoped(node.elseBody, stack) end
  elseif kind == "While" then
    resolveExpr(node.cond, stack)
    resolveBlockScoped(node.body, stack)
  elseif kind == "Repeat" then
    -- body and the `until` condition share one scope (until can see body locals)
    pushFrame(stack)
    resolveBlockBare(node.body, stack)
    resolveExpr(node.cond, stack)
    popFrame(stack)
  elseif kind == "Break" then
    -- nothing
  elseif kind == "NumericFor" then
    resolveExpr(node.start, stack)
    resolveExpr(node.limit, stack)
    if node.step then resolveExpr(node.step, stack) end
    pushFrame(stack)
    node.var = declare(stack, node.var)
    resolveBlockScoped(node.body, stack)
    popFrame(stack)
  elseif kind == "GenericFor" then
    for _, e in ipairs(node.exprs) do resolveExpr(e, stack) end
    pushFrame(stack)
    for i, n in ipairs(node.names) do node.names[i] = declare(stack, n) end
    resolveBlockBare(node.body, stack)
    popFrame(stack)
  elseif kind == "Return" then
    for _, a in ipairs(node.args) do resolveExpr(a, stack) end
  else
    error("XenonSec renamer: unknown statement kind '" .. tostring(kind) .. "'")
  end
end

function resolveBlockBare(block, stack)
  for _, stat in ipairs(block.body) do resolveStat(stat, stack) end
end

function resolveBlockScoped(block, stack)
  pushFrame(stack)
  resolveBlockBare(block, stack)
  popFrame(stack)
end

-- Public entry point. Mutates and returns the same AST.
function Renamer.resolve(ast)
  local stack = {}
  pushFrame(stack) -- main chunk acts like a vararg function with no params
  resolveBlockBare(ast, stack)
  popFrame(stack)
  return ast
end

return Renamer
