local Fold = {}

local ARITH = {
  ["+"]  = function(a, b) return a + b end,
  ["-"]  = function(a, b) return a - b end,
  ["*"]  = function(a, b) return a * b end,
  ["/"]  = function(a, b) return a / b end,
  ["%"]  = function(a, b) return a % b end,
  ["^"]  = function(a, b) return a ^ b end,
  [".."] = function(a, b) return tostring(a) .. tostring(b) end,
}

local foldExpr, foldStat, foldBlock

function foldExpr(node)
  local kind = node.kind
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" or kind == "Name" then
    return node
  elseif kind == "Index" then
    node.obj = foldExpr(node.obj)
    node.key = foldExpr(node.key)
    return node
  elseif kind == "Paren" then
    node.expr = foldExpr(node.expr)
    -- Nếu bên trong Paren chỉ là hằng số đơn thuần, tháo bọc Paren
    local innerKind = node.expr.kind
    if innerKind == "Number" or innerKind == "String" or innerKind == "True" or innerKind == "False" or innerKind == "Nil" then
      return node.expr
    end
    return node
  elseif kind == "Table" then
    for _, field in ipairs(node.fields) do
      if field.type == "keyed" then field.key = foldExpr(field.key) end
      field.value = foldExpr(field.value)
    end
    return node
  elseif kind == "Function" then
    node.body = foldBlock(node.body)
    return node
  elseif kind == "Call" then
    node.fn = foldExpr(node.fn)
    for i, a in ipairs(node.args) do node.args[i] = foldExpr(a) end
    return node
  elseif kind == "MethodCall" then
    node.obj = foldExpr(node.obj)
    for i, a in ipairs(node.args) do node.args[i] = foldExpr(a) end
    return node
  elseif kind == "Binop" then
    node.lhs = foldExpr(node.lhs)
    node.rhs = foldExpr(node.rhs)

    -- 1. Nối chuỗi String .. String hoặc Number .. String
    if node.op == ".." then
      if (node.lhs.kind == "String" or node.lhs.kind == "Number") and
         (node.rhs.kind == "String" or node.rhs.kind == "Number") then
        return { kind = "String", value = tostring(node.lhs.value) .. tostring(node.rhs.value), line = node.line }
      end
    end

    -- 2. Phép toán số học (Arithmetic)
    local fn = ARITH[node.op]
    if fn and node.lhs.kind == "Number" and node.rhs.kind == "Number" then
      local ok, result = pcall(fn, node.lhs.value, node.rhs.value)
      if ok and type(result) == "number" and result == result
        and result ~= math.huge and result ~= -math.huge then
        return { kind = "Number", value = result, line = node.line }
      end
    end

    -- 3. Phép so sánh hằng số (Comparison)
    if node.lhs.kind == node.rhs.kind and (node.lhs.kind == "Number" or node.lhs.kind == "String") then
      if node.op == "==" then return { kind = node.lhs.value == node.rhs.value and "True" or "False", line = node.line } end
      if node.op == "~=" then return { kind = node.lhs.value ~= node.rhs.value and "True" or "False", line = node.line } end
    end

    return node
  elseif kind == "Unop" then
    node.operand = foldExpr(node.operand)
    
    -- Số âm: -Number
    if node.op == "-" and node.operand.kind == "Number" then
      return { kind = "Number", value = -node.operand.value, line = node.line }
    end
    
    -- Phủ định Logic: not True / not False
    if node.op == "not" then
      if node.operand.kind == "True" then return { kind = "False", line = node.line } end
      if node.operand.kind == "False" then return { kind = "True", line = node.line } end
      if node.operand.kind == "Nil" then return { kind = "True", line = node.line } end
      if node.operand.kind == "Number" or node.operand.kind == "String" then return { kind = "False", line = node.line } end
    end

    -- Độ dài chuỗi: #String
    if node.op == "#" and node.operand.kind == "String" then
      return { kind = "Number", value = #node.operand.value, line = node.line }
    end

    return node
  else
    error("XenonSec fold: unknown expression kind '" .. tostring(kind) .. "'")
  end
end

function foldStat(node)
  local kind = node.kind
  if kind == "Local" then
    for i, v in ipairs(node.values) do node.values[i] = foldExpr(v) end
  elseif kind == "LocalFunction" then
    node.func = foldExpr(node.func)
  elseif kind == "Assign" then
    for i, v in ipairs(node.values) do node.values[i] = foldExpr(v) end
    for _, tgt in ipairs(node.targets) do
      if tgt.kind == "Index" then
        tgt.obj = foldExpr(tgt.obj)
        tgt.key = foldExpr(tgt.key)
      end
    end
  elseif kind == "ExprStat" then
    node.expr = foldExpr(node.expr)
  elseif kind == "Do" then
    node.body = foldBlock(node.body)
  elseif kind == "If" then
    for _, clause in ipairs(node.clauses) do
      clause.cond = foldExpr(clause.cond)
      clause.body = foldBlock(clause.body)
    end
    if node.elseBody then node.elseBody = foldBlock(node.elseBody) end
  elseif kind == "While" then
    node.cond = foldExpr(node.cond)
    node.body = foldBlock(node.body)
  elseif kind == "Repeat" then
    node.body = foldBlock(node.body)
    node.cond = foldExpr(node.cond)
  elseif kind == "Break" or kind == "Continue" then
    -- Nothing
  elseif kind == "NumericFor" then
    node.start = foldExpr(node.start)
    node.limit = foldExpr(node.limit)
    if node.step then node.step = foldExpr(node.step) end
    node.body = foldBlock(node.body)
  elseif kind == "GenericFor" then
    for i, e in ipairs(node.exprs) do node.exprs[i] = foldExpr(e) end
    node.body = foldBlock(node.body)
  elseif kind == "Return" then
    for i, a in ipairs(node.args) do node.args[i] = foldExpr(a) end
  else
    error("XenonSec fold: unknown statement kind '" .. tostring(kind) .. "'")
  end
  return node
end

function foldBlock(block)
  for i, stat in ipairs(block.body) do block.body[i] = foldStat(stat) end
  return block
end

function Fold.apply(ast)
  return foldBlock(ast)
end

return Fold
