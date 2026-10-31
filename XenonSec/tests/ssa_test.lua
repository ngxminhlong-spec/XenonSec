local TEST_DIR = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./")
local SRC_DIR = TEST_DIR .. "../src/"
local Parser = dofile(SRC_DIR .. 'parser.lua')
local Fold = dofile(SRC_DIR .. 'fold.lua')
local SSA = dofile(SRC_DIR .. 'ssa.lua')
local Capture = dofile(SRC_DIR .. 'capture.lua')

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

-- Structural checks on top of the output check: the regenerated source
-- must (tHas) or must not (tNo) contain a fragment. t() counts the test
-- itself, so a failed structural check moves it from pass to fail here.
local function tHas(name, src, fragment)
  local regen = t(name, src)
  if regen and not regen:find(fragment, 1, true) then
    pass = pass - 1
    print("[FAIL] " .. name .. " -- regenerated code lacks: " .. fragment)
    print("  regenerated:\n" .. regen)
  end
end
local function tNo(name, src, fragment)
  local regen = t(name, src)
  if regen and regen:find(fragment, 1, true) then
    pass = pass - 1
    print("[FAIL] " .. name .. " -- regenerated code still contains: " .. fragment)
    print("  regenerated:\n" .. regen)
  end
end

-- Regressions found while building cross-branch propagation.
t("REGRESSION: multi-name redeclaration clears the older tracked value", [[
local x = 1
local x, y = 2, 3
print(x, y)
]])

t("REGRESSION: repeat-until reads its body-local, not the outer value", [[
local x = 1
local n = 0
repeat
  local x = 2
  n = n + 1
until x == 2
print("done", n)
]])

t("REGRESSION: call in the same statement can change a captured value", [[
local x = 1
local function f() x = 2; return 0 end
print(f(), x)
]])

-- Cross-branch propagation.
tHas("phi: identical literals on every falling-through path stay known", [[
local x = 0
if os.time() > 0 then x = 1 else x = 1 end
print(x)
]], "print(1)")

tHas("phi: implicit else leaves a value known when the then-branch agrees", [[
local x = 1
if os.time() > 0 then x = 1 end
print(x)
]], "print(1)")

t("phi: disagreeing branches do not leak a value", [[
local x = 0
if os.time() > 0 then x = 1 else x = 2 end
print(x)
]])

t("phi: a branch that returns does not block the merge", [[
local function f()
  local x = 5
  if os.time() < 0 then return 0 end
  print(x)
  return x
end
print(f())
]])

tHas("values flow into an if body", [[
local n = 3
if os.time() > 0 then print(n) end
]], "print(3)")

tHas("values flow into a loop body that does not change them", [[
local k = 5
for i = 1, 2 do print(k) end
]], "print(5)")

t("loop variable shadows an outer tracked name", [[
local i = 99
for i = 1, 2 do print(i) end
print(i)
]])

t("branch-local declaration does not leak out of its branch", [[
local x = 1
if os.time() > 0 then
  local x = 5
  print(x)
end
print(x)
]])


t("do-block assignment is visible after the block", [[
local x = 1
do x = 2 end
print(x)
]])

t("break from a branch is not a fall-through path", [[
local x = 1
while true do
  if os.time() > 0 then x = 2; break end
end
print(x)
]])

tNo("constant false condition removes its branch", [[
local DEBUG = false
if DEBUG then print("debug-only") end
print("ok")
]], "debug-only")

tNo("constant true condition collapses to its body", [[
local FAST = true
if FAST then print("fast") else print("slow") end
]], "slow")

t("constant condition with an elseif chain", [[
local MODE = 2
if MODE == 1 then print("one")
elseif MODE == 2 then print("two")
else print("other") end
]])

t("repeat body local shadows a tracked name in a closure", [[
local x = 7
local n = 0
repeat
  local x = n
  local function get() return x end
  n = n + 1
until get() >= 2
print(n)
]])

t("REGRESSION: a dead local whose name is later reassigned must not leak a global", [[
local x = 1
x = 2
print("end", rawget(_G, "x"))
]])

print()
print(pass .. " / " .. total .. " ssa tests passed")
