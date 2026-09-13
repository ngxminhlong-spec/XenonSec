local Parser = dofile("parser.lua")
local Fold = dofile("fold.lua")
local SSA = dofile("ssa.lua")
local Capture = dofile("capture.lua")

local function captureNative(src)
  local out = {}
  local chunk = assert(load(src, "native", "t"))
  local oldPrint = _G.print
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local ok, err = pcall(chunk)
  _G.print = oldPrint
  if not ok then error(err) end
  return table.concat(out, "\n")
end

-- Round-trips src through Parser -> Fold -> SSA -> Fold -> a crude
-- AST-to-source printer, then executes the regenerated source. This
-- exercises SSA at the AST level without needing the full compiler.
local printExpr, printStat, printBlock

local function q(s) return string.format("%q", s) end

function printExpr(n)
  local k = n.kind
  if k == "Number" then return tostring(n.value)
  elseif k == "String" then return q(n.value)
  elseif k == "Nil" then return "nil"
  elseif k == "True" then return "true"
  elseif k == "False" then return "false"
  elseif k == "Vararg" then return "..."
  elseif k == "Name" then return n.name
  elseif k == "Index" then
    if n.key.kind == "String" then return printExpr(n.obj) .. "[" .. q(n.key.value) .. "]" end
    return printExpr(n.obj) .. "[" .. printExpr(n.key) .. "]"
  elseif k == "Paren" then return "(" .. printExpr(n.expr) .. ")"
  elseif k == "Table" then
    local parts = {}
    for _, f in ipairs(n.fields) do
      if f.type == "keyed" then parts[#parts+1] = "[" .. printExpr(f.key) .. "]=" .. printExpr(f.value)
      else parts[#parts+1] = printExpr(f.value) end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif k == "Function" then
    return "function(" .. table.concat(n.params, ",") .. ") " .. printBlock(n.body) .. " end"
  elseif k == "Call" then
    local a = {}
    for _, x in ipairs(n.args) do a[#a+1] = printExpr(x) end
    return printExpr(n.fn) .. "(" .. table.concat(a, ",") .. ")"
  elseif k == "MethodCall" then
    local a = {}
    for _, x in ipairs(n.args) do a[#a+1] = printExpr(x) end
    return printExpr(n.obj) .. ":" .. n.method .. "(" .. table.concat(a, ",") .. ")"
  elseif k == "Binop" then return "(" .. printExpr(n.lhs) .. n.op .. printExpr(n.rhs) .. ")"
  elseif k == "Unop" then
    local sp = (n.op == "not") and " " or ""
    return "(" .. n.op .. sp .. printExpr(n.operand) .. ")"
  else error("printExpr: " .. tostring(k)) end
end

function printStat(n)
  local k = n.kind
  if k == "Local" then
    local vs = {}
    for _, v in ipairs(n.values) do vs[#vs+1] = printExpr(v) end
    local suffix = #vs > 0 and (" = " .. table.concat(vs, ",")) or ""
    return "local " .. table.concat(n.names, ",") .. suffix
  elseif k == "LocalFunction" then
    return "local function " .. n.name .. "(" .. table.concat(n.func.params, ",") .. ") " .. printBlock(n.func.body) .. " end"
  elseif k == "Assign" then
    local ts, vs = {}, {}
    for _, t in ipairs(n.targets) do ts[#ts+1] = printExpr(t) end
    for _, v in ipairs(n.values) do vs[#vs+1] = printExpr(v) end
    return table.concat(ts, ",") .. " = " .. table.concat(vs, ",")
  elseif k == "ExprStat" then return printExpr(n.expr)
  elseif k == "Do" then return "do " .. printBlock(n.body) .. " end"
  elseif k == "If" then
    local parts = {}
    for i, c in ipairs(n.clauses) do
      parts[#parts+1] = (i == 1 and "if " or "elseif ") .. printExpr(c.cond) .. " then " .. printBlock(c.body)
    end
    if n.elseBody then parts[#parts+1] = "else " .. printBlock(n.elseBody) end
    parts[#parts+1] = "end"
    return table.concat(parts, " ")
  elseif k == "While" then return "while " .. printExpr(n.cond) .. " do " .. printBlock(n.body) .. " end"
  elseif k == "Repeat" then return "repeat " .. printBlock(n.body) .. " until " .. printExpr(n.cond)
  elseif k == "Break" then return "break"
  elseif k == "NumericFor" then
    local step = n.step and ("," .. printExpr(n.step)) or ""
    return "for " .. n.var .. "=" .. printExpr(n.start) .. "," .. printExpr(n.limit) .. step .. " do " .. printBlock(n.body) .. " end"
  elseif k == "GenericFor" then
    local es = {}
    for _, e in ipairs(n.exprs) do es[#es+1] = printExpr(e) end
    return "for " .. table.concat(n.names, ",") .. " in " .. table.concat(es, ",") .. " do " .. printBlock(n.body) .. " end"
  elseif k == "Return" then
    local a = {}
    for _, x in ipairs(n.args) do a[#a+1] = printExpr(x) end
    return "return " .. table.concat(a, ",")
  else error("printStat: " .. tostring(k)) end
end

function printBlock(b)
  local parts = {}
  for _, s in ipairs(b.body) do parts[#parts+1] = printStat(s) end
  return table.concat(parts, "\n")
end

local pass, total = 0, 0
local function t(name, src)
  total = total + 1
  local nativeOut = captureNative(src)

  local ast = Parser.parse(src, name)
  local captured = Capture.analyze(ast)
  Fold.apply(ast)
  SSA.apply(ast, captured)
  Fold.apply(ast)
  local regenerated = printBlock(ast)

  local ok, optOut = pcall(captureNative, regenerated)
  if not ok then
    print("[FAIL] " .. name .. " -- regenerated code errored: " .. tostring(optOut))
    print("  regenerated:\n" .. regenerated)
    return
  end
  if optOut ~= nativeOut then
    print("[FAIL] " .. name)
    print("  native: " .. nativeOut)
    print("  opt   : " .. optOut)
    print("  regenerated:\n" .. regenerated)
    return
  end
  print("[ OK ] " .. name)
  pass = pass + 1
  return regenerated
end

t("copy + constant propagation folds fully", [[
local a = 5
local b = a + 2
local c = b * 3
print(c)
]])

t("dead store with pure RHS is fully removed", [[
local unused = 1 + 2
local x = 10
print(x)
]])

t("dead store with side-effecting RHS keeps the call", [[
local function sideEffect() print("called"); return 99 end
local unused = sideEffect()
print("done")
]])

t("reassignment invalidates tracked value", [[
local x = 5
x = x + 1
print(x)
]])

t("closure capture pins the local alive (no elimination, no propagation)", [[
local x = 5
local function f() return x end
x = x + 1
print(f())
]])

t("propagation does not cross into nested if/while bodies", [[
local x = 5
if true then
  x = x + 100
end
print(x)
]])

t("propagation stops at reassignment inside straight-line run", [[
local a = 1
local b = a
a = 2
print(b, a)
]])

t("string concatenation propagation", [[
local greeting = "hello"
local name = "world"
local msg = greeting .. ", " .. name .. "!"
print(msg)
]])

t("unary minus and not tracked", [[
local a = 5
local b = -a
local c = not false
print(b, c)
]])

t("multi-assignment locals are not tracked (left untouched, still correct)", [[
local a, b = 1, 2
print(a, b)
local c, d = 10, 20
c, d = d, c
print(c, d)
]])

t("REGRESSION: function call can mutate a captured var via closure", [[
local calls = 0
local function getTable()
  calls = calls + 1
  return { x = 10 }
end
local t = getTable()
print(t.x, calls)
]])

t("REGRESSION: captured var read again after an unrelated call", [[
local counter = 0
local function bump() counter = counter + 1 end
bump()
print(counter)
print("unrelated") -- another call; counter must still be re-read, not cached
bump()
print(counter)
]])

t("REGRESSION: uncaptured var survives calls fine (no false invalidation)", [[
local x = 5
print("hello")
local y = x + 1
print(y)
]])

t("REGRESSION: call through a table method can also mutate captured state", [[
local total = 0
local obj = {}
function obj.add(n) total = total + n end
obj.add(5)
print(total)
obj.add(3)
print(total)
]])

t("loop body reassigning an outer local across iterations", [[
local total = 0
for i = 1, 5 do
  total = total + i
end
print(total)
]])

t("value read only inside a later nested if must not be eliminated", [[
local x = 42
if true then
  print(x)
end
]])

t("value read only inside a later while-loop must not be eliminated", [[
local n = 3
local i = 0
while i < n do
  i = i + 1
end
print(i)
]])

t("chained propagation through several straight-line copies", [[
local a = 2
local b = a
local c = b
local d = c
local e = a + b + c + d
print(e)
]])

t("propagated value used as a table constructor field", [[
local w = 10
local h = 20
local rect = { width = w, height = h, area = w * h }
print(rect.width, rect.height, rect.area)
]])

t("propagated value used as function call argument", [[
local base = "user_"
local id = 7
print(base .. tostring(id))
]])

t("repeat-until condition must not use pre-loop value", [[
local i = 0
repeat
  i = i + 1
until i >= 5
print(i)
]])

t("nested while loops, inner reassigns, outer cond must stay live", [[
local i = 0
while i < 3 do
  local j = 0
  while j < 2 do
    j = j + 1
  end
  i = i + 1
end
print(i)
]])

t("loop-invariant value in while cond CAN still propagate safely", [[
local limit = 5
local i = 0
while i < limit do
  i = i + 1
end
print(i, limit)
]])

t("break inside while after propagated value", [[
local x = 10
local i = 0
while true do
  i = i + 1
  if i >= x then break end
end
print(i)
]])

t("for loop reading outer propagated constant (safe, no reassignment)", [[
local step = 2
local total = 0
for i = 1, 10, step do
  total = total + i
end
print(total)
]])

print()
print(pass .. " / " .. total .. " ssa tests passed")
