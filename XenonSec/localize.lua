local Localize = {}

local function pushFrame(stack) stack[#stack + 1] = {}; return stack[#stack] end
local function popFrame(stack) stack[#stack] = nil end
local function declare(stack, name) stack[#stack][name] = true end
local function isLocal(stack, name)
  for i = #stack, 1, -1 do
    if stack[i][name] then return true end
  end
  return false
end

local walkExpr, walkStat, walkBlockBare, walkBlockScoped, walkFunction

local function markRead(name, stack, reads)
  if not isLocal(stack, name) then reads[name] = true end
end
local function markWrite(name, stack, writes)
  if not isLocal(stack, name) then writes[name] = true end
end

function walkExpr(node, stack, reads, writes)
  local kind = node.kind
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" then
  elseif kind == "Name" then
    markRead(node.name, stack, reads)
  elseif kind == "Index" then
    walkExpr(node.obj, stack, reads, writes)
    walkExpr(node.key, stack, reads, writes)
  elseif kind == "Paren" then
    walkExpr(node.expr, stack, reads, writes)
  elseif kind == "Table" then
    for _, field in ipairs(node.fields) do
      if field.type == "keyed" then walkExpr(field.key, stack, reads, writes) end
      walkExpr(field.value, stack, reads, writes)
    end
  elseif kind == "Function" then
    walkFunction(node, stack, reads, writes)
  elseif kind == "Call" then
    walkExpr(node.fn, stack, reads, writes)
    for _, a in ipairs(node.args) do walkExpr(a, stack, reads, writes) end
  elseif kind == "MethodCall" then
    walkExpr(node.obj, stack, reads, writes)
    for _, a in ipairs(node.args) do walkExpr(a, stack, reads, writes) end
  elseif kind == "Binop" then
    walkExpr(node.lhs, stack, reads, writes)
    walkExpr(node.rhs, stack, reads, writes)
  elseif kind == "Unop" then
    walkExpr(node.operand, stack, reads, writes)
  else
    error("XenonSec localize: unknown expression kind '" .. tostring(kind) .. "'")
  end
end

function walkFunction(node, stack, reads, writes)
  pushFrame(stack)
  for _, p in ipairs(node.params) do declare(stack, p) end
  walkBlockBare(node.body, stack, reads, writes)
  popFrame(stack)
end

function walkStat(node, stack, reads, writes)
  local kind = node.kind
  if kind == "Local" then
    for _, v in ipairs(node.values) do walkExpr(v, stack, reads, writes) end
    for _, n in ipairs(node.names) do declare(stack, n) end
  elseif kind == "LocalFunction" then
    declare(stack, node.name)
    walkExpr(node.func, stack, reads, writes)
  elseif kind == "Assign" then
    for _, v in ipairs(node.values) do walkExpr(v, stack, reads, writes) end
    for _, tgt in ipairs(node.targets) do
      if tgt.kind == "Name" then
        markWrite(tgt.name, stack, writes)
      else
        walkExpr(tgt.obj, stack, reads, writes)
        walkExpr(tgt.key, stack, reads, writes)
      end
    end
  elseif kind == "ExprStat" then
    walkExpr(node.expr, stack, reads, writes)
  elseif kind == "Do" then
    walkBlockScoped(node.body, stack, reads, writes)
  elseif kind == "If" then
    for _, clause in ipairs(node.clauses) do
      walkExpr(clause.cond, stack, reads, writes)
      walkBlockScoped(clause.body, stack, reads, writes)
    end
    if node.elseBody then walkBlockScoped(node.elseBody, stack, reads, writes) end
  elseif kind == "While" then
    walkExpr(node.cond, stack, reads, writes)
    walkBlockScoped(node.body, stack, reads, writes)
  elseif kind == "Repeat" then
    pushFrame(stack)
    walkBlockBare(node.body, stack, reads, writes)
    walkExpr(node.cond, stack, reads, writes)
    popFrame(stack)
  elseif kind == "Break" or kind == "Continue" then
  elseif kind == "NumericFor" then
    walkExpr(node.start, stack, reads, writes)
    walkExpr(node.limit, stack, reads, writes)
    if node.step then walkExpr(node.step, stack, reads, writes) end
    pushFrame(stack)
    declare(stack, node.var)
    walkBlockBare(node.body, stack, reads, writes)
    popFrame(stack)
  elseif kind == "GenericFor" then
    for _, e in ipairs(node.exprs) do walkExpr(e, stack, reads, writes) end
    pushFrame(stack)
    for _, n in ipairs(node.names) do declare(stack, n) end
    walkBlockBare(node.body, stack, reads, writes)
    popFrame(stack)
  elseif kind == "Return" then
    for _, a in ipairs(node.args) do walkExpr(a, stack, reads, writes) end
  else
    error("XenonSec localize: unknown statement kind '" .. tostring(kind) .. "'")
  end
end

function walkBlockBare(block, stack, reads, writes)
  for _, stat in ipairs(block.body) do walkStat(stat, stack, reads, writes) end
end

function walkBlockScoped(block, stack, reads, writes)
  pushFrame(stack)
  walkBlockBare(block, stack, reads, writes)
  popFrame(stack)
end

function Localize.apply(ast)
  local stack = {}
  pushFrame(stack)
  local reads, writes = {}, {}
  walkBlockBare(ast, stack, reads, writes)
  popFrame(stack)

  local order = {}
  for name in pairs(reads) do
    if not writes[name] then order[#order + 1] = name end
  end
  table.sort(order)

  local prelude = {}
  for _, name in ipairs(order) do
    prelude[#prelude + 1] = {
      kind = "Local",
      names = { name },
      values = { { kind = "Name", name = name } },
    }
  end

  local newBody = {}
  for _, s in ipairs(prelude) do newBody[#newBody + 1] = s end
  for _, s in ipairs(ast.body) do newBody[#newBody + 1] = s end
  ast.body = newBody

  return ast
end

return Localize
