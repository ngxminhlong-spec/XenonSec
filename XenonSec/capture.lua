local Capture = {}

local function pushFrame(stack, funcDepth)
  stack[#stack + 1] = { funcDepth = funcDepth, names = {} }
  return stack[#stack]
end
local function popFrame(stack) stack[#stack] = nil end
local function declare(stack, name) stack[#stack].names[name] = true end

local function resolveAndMark(stack, name, currentFuncDepth, captured)
  for i = #stack, 1, -1 do
    local frame = stack[i]
    if frame.names[name] then
      if frame.funcDepth < currentFuncDepth then
        captured[name] = true
      end
      return
    end
  end
end

local walkExpr, walkStat, walkBlockBare, walkBlockScoped, walkFunction

function walkExpr(node, stack, depth, captured)
  local kind = node.kind
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" then
    -- Nothing
  elseif kind == "Name" then
    resolveAndMark(stack, node.name, depth, captured)
  elseif kind == "Index" then
    walkExpr(node.obj, stack, depth, captured)
    walkExpr(node.key, stack, depth, captured)
  elseif kind == "Paren" then
    walkExpr(node.expr, stack, depth, captured)
  elseif kind == "Table" then
    for _, field in ipairs(node.fields) do
      if field.type == "keyed" then walkExpr(field.key, stack, depth, captured) end
      walkExpr(field.value, stack, depth, captured)
    end
  elseif kind == "Function" then
    walkFunction(node, stack, depth, captured)
  elseif kind == "Call" then
    walkExpr(node.fn, stack, depth, captured)
    for _, a in ipairs(node.args) do walkExpr(a, stack, depth, captured) end
  elseif kind == "MethodCall" then
    walkExpr(node.obj, stack, depth, captured)
    for _, a in ipairs(node.args) do walkExpr(a, stack, depth, captured) end
  elseif kind == "Binop" then
    walkExpr(node.lhs, stack, depth, captured)
    walkExpr(node.rhs, stack, depth, captured)
  elseif kind == "Unop" then
    walkExpr(node.operand, stack, depth, captured)
  else
    error("XenonSec capture: unknown expression kind '" .. tostring(kind) .. "'")
  end
end

function walkFunction(node, stack, depth, captured)
  local newDepth = depth + 1
  pushFrame(stack, newDepth)
  for _, p in ipairs(node.params) do declare(stack, p) end
  walkBlockBare(node.body, stack, newDepth, captured)
  popFrame(stack)
end

function walkStat(node, stack, depth, captured)
  local kind = node.kind
  if kind == "Local" then
    for _, v in ipairs(node.values) do walkExpr(v, stack, depth, captured) end
    for _, n in ipairs(node.names) do declare(stack, n) end
  elseif kind == "LocalFunction" then
    -- Declare FIRST so recursive calls inside func can resolve correctly
    declare(stack, node.name)
    walkExpr(node.func, stack, depth, captured)
  elseif kind == "Assign" then
    for _, v in ipairs(node.values) do walkExpr(v, stack, depth, captured) end
    for _, tgt in ipairs(node.targets) do
      if tgt.kind == "Name" then
        resolveAndMark(stack, tgt.name, depth, captured)
      else
        walkExpr(tgt.obj, stack, depth, captured)
        walkExpr(tgt.key, stack, depth, captured)
      end
    end
  elseif kind == "ExprStat" then
    walkExpr(node.expr, stack, depth, captured)
  elseif kind == "Do" then
    walkBlockScoped(node.body, stack, depth, captured)
  elseif kind == "If" then
    for _, clause in ipairs(node.clauses) do
      walkExpr(clause.cond, stack, depth, captured)
      walkBlockScoped(clause.body, stack, depth, captured)
    end
    if node.elseBody then walkBlockScoped(node.elseBody, stack, depth, captured) end
  elseif kind == "While" then
    walkExpr(node.cond, stack, depth, captured)
    walkBlockScoped(node.body, stack, depth, captured)
  elseif kind == "Repeat" then
    pushFrame(stack, depth)
    walkBlockBare(node.body, stack, depth, captured)
    walkExpr(node.cond, stack, depth, captured)
    popFrame(stack)
  elseif kind == "NumericFor" then
    walkExpr(node.start, stack, depth, captured)
    walkExpr(node.limit, stack, depth, captured)
    if node.step then walkExpr(node.step, stack, depth, captured) end
    pushFrame(stack, depth)
    declare(stack, node.var)
    walkBlockBare(node.body, stack, depth, captured) -- Dùng Bare thay vì Scoped để tránh lặp Frame
    popFrame(stack)
  elseif kind == "GenericFor" then
    for _, e in ipairs(node.exprs) do walkExpr(e, stack, depth, captured) end
    pushFrame(stack, depth)
    for _, n in ipairs(node.names) do declare(stack, n) end
    walkBlockBare(node.body, stack, depth, captured)
    popFrame(stack)
  elseif kind == "Return" then
    for _, a in ipairs(node.args) do walkExpr(a, stack, depth, captured) end
  end
end

function walkBlockBare(block, stack, depth, captured)
  for _, stat in ipairs(block.body) do walkStat(stat, stack, depth, captured) end
end

function walkBlockScoped(block, stack, depth, captured)
  pushFrame(stack, depth)
  walkBlockBare(block, stack, depth, captured)
  popFrame(stack)
end

function Capture.analyze(ast)
  local stack = {}
  local captured = {}
  pushFrame(stack, 1)
  walkBlockBare(ast, stack, 1, captured)
  popFrame(stack)
  return captured
end

return Capture
