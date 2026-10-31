--------------------------------------------------------------------
-- XenonSec :: ssa.lua
-- A real SSA-flavored optimizer, scoped honestly:
--
--   * Every `local x = <pure expr>` is treated as x's single static
--     definition (true SSA discipline: one name, one value, for as
--     long as it isn't reassigned or captured by a closure).
--   * That value is VALUE-NUMBERED: as long as it stays live and
--     un-reassigned, every subsequent read of x within the same
--     straight-line run of statements is replaced with a copy of its
--     recorded value expression (copy propagation / constant
--     propagation).
--   * If x is never read again before it goes out of scope, the
--     declaration is dead-code-eliminated -- its side-effecting RHS
--     (if any) is kept as a bare statement, a side-effect-free RHS is
--     dropped entirely.
--
-- Propagation crosses control flow in the following ways, all
-- conservative (see "Cross-branch propagation" below): values flow into
-- if/do/loop bodies, a merge after an if keeps only the values that every
-- falling-through branch agrees on (a phi of identical inputs), and an
-- if whose condition is a literal after propagation is collapsed. Loops
-- get a phi at the header: a value survives into the loop only if every
-- back edge, continue and break still carries it, found by a fixed point
-- over trial copies of the body. Loops nested deeper than MAX_PHI_DEPTH use
-- the plainer rule that drops everything the loop assigns.
--
-- Any operation that can run Lua code (a call, indexing, or an operator
-- that may reach a metamethod) invalidates captured names it might change.
--
-- Run this AFTER fold.lua (so literal arithmetic is already reduced)
-- and run fold.lua again afterward (propagating a copied literal into
-- an expression frequently creates new foldable arithmetic).
--------------------------------------------------------------------

local SSA = {}

--------------------------------------------------------------------
-- Global captured-variable set (from capture.lua, computed once on the
-- pristine pre-transform AST). A function call ANYWHERE can, through a
-- closure that captured one of these names, mutate it -- even if no
-- call is textually visible between the tracked definition and the
-- current point. Any statement containing a call must therefore
-- invalidate every tracked value for a name that's ever captured
-- anywhere in the program. Names that are NEVER captured by any
-- closure can't be touched this way (nothing else holds a reference to
-- them), so they stay safely trackable across calls.
--------------------------------------------------------------------

local capturedNames = {}

-- Can evaluating this expression run Lua code that might change a captured
-- local? Calls obviously can. So can indexing and most operators, through
-- __index, __add, __concat, __eq, __len and the rest of the metamethods, and a
-- metamethod can call a closure that assigns a captured name. Only `and`,
-- `or` and `not` are known to run no code.
local function exprContainsCall(node)
  local kind = node.kind
  if kind == "Call" or kind == "MethodCall" then return true end
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" or kind == "Name" or kind == "Function" then
    return false
  elseif kind == "Index" then
    return true
  elseif kind == "Paren" then
    return exprContainsCall(node.expr)
  elseif kind == "Table" then
    for _, f in ipairs(node.fields) do
      if f.type == "keyed" and exprContainsCall(f.key) then return true end
      if exprContainsCall(f.value) then return true end
    end
    return false
  elseif kind == "Binop" then
    if node.op == "and" or node.op == "or" then
      return exprContainsCall(node.lhs) or exprContainsCall(node.rhs)
    end
    return true
  elseif kind == "Unop" then
    if node.op == "not" then return exprContainsCall(node.operand) end
    return true
  end
  return false
end

local function listContainsCall(list)
  for _, e in ipairs(list) do if exprContainsCall(e) then return true end end
  return false
end

local function statementContainsCall(s)
  local kind = s.kind
  if kind == "Local" or kind == "Return" then
    return listContainsCall(s.values or s.args)
  elseif kind == "LocalFunction" then
    return false -- defining a closure doesn't call it
  elseif kind == "Assign" then
    if listContainsCall(s.values) then return true end
    for _, t in ipairs(s.targets) do
      -- Storing through an index can run __newindex, so it always counts.
      if t.kind == "Index" then return true end
    end
    return false
  elseif kind == "ExprStat" then
    return exprContainsCall(s.expr)
  elseif kind == "If" then
    for _, c in ipairs(s.clauses) do if exprContainsCall(c.cond) then return true end end
    return false
  elseif kind == "While" then
    return exprContainsCall(s.cond)
  elseif kind == "NumericFor" then
    if exprContainsCall(s.start) or exprContainsCall(s.limit) then return true end
    if s.step and exprContainsCall(s.step) then return true end
    return false
  elseif kind == "GenericFor" then
    return listContainsCall(s.exprs)
  end
  return false
end

local function invalidateCapturedAfterCall(s, env)
  if statementContainsCall(s) then
    for name in pairs(capturedNames) do env[name] = nil end
  end
end

--------------------------------------------------------------------
-- Deep-copy of an expression subtree (needed because we splice the
-- same "known value" into multiple use sites).
--------------------------------------------------------------------

local function cloneExpr(node)
  local kind = node.kind
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" then
    return { kind = kind, value = node.value, line = node.line }
  elseif kind == "Name" then
    return { kind = "Name", name = node.name, line = node.line }
  elseif kind == "Binop" then
    return { kind = "Binop", op = node.op, lhs = cloneExpr(node.lhs), rhs = cloneExpr(node.rhs), line = node.line }
  elseif kind == "Unop" then
    return { kind = "Unop", op = node.op, operand = cloneExpr(node.operand), line = node.line }
  elseif kind == "Paren" then
    return { kind = "Paren", expr = cloneExpr(node.expr), line = node.line }
  else
    error("XenonSec ssa: cloneExpr called on non-clonable kind '" .. tostring(kind) .. "'")
  end
end

-- Only these shapes are ever tracked as a "known SSA value": literals,
-- and pure arithmetic/concat/unary combinations of already-tracked
-- values. Tables, function literals, calls, indexing, etc. are never
-- tracked -- too easy to get aliasing/mutation/side-effects wrong.
local PURE_BINOPS = {
  ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true, ["^"] = true, [".."] = true,
}

local function isTrackable(node)
  local kind = node.kind
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True" or kind == "False" then
    return true
  elseif kind == "Binop" then
    return PURE_BINOPS[node.op] and isTrackable(node.lhs) and isTrackable(node.rhs)
  elseif kind == "Unop" then
    return (node.op == "-" or node.op == "#") and isTrackable(node.operand)
  else
    return false
  end
end

--------------------------------------------------------------------
-- Substitute tracked names into an expression (copy/constant
-- propagation), returning a possibly-new node.
--------------------------------------------------------------------

local substExpr

local function substList(list, env)
  for i, e in ipairs(list) do list[i] = substExpr(e, env) end
end

function substExpr(node, env)
  local kind = node.kind
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" then
    return node
  elseif kind == "Name" then
    local known = env[node.name]
    if known then return cloneExpr(known) end
    return node
  elseif kind == "Index" then
    node.obj = substExpr(node.obj, env)
    node.key = substExpr(node.key, env)
    return node
  elseif kind == "Paren" then
    node.expr = substExpr(node.expr, env)
    return node
  elseif kind == "Table" then
    for _, field in ipairs(node.fields) do
      if field.type == "keyed" then field.key = substExpr(field.key, env) end
      field.value = substExpr(field.value, env)
    end
    return node
  elseif kind == "Function" then
    -- opacity barrier: do NOT propagate current values into a nested
    -- function body (it may run later, after the values here change).
    return node
  elseif kind == "Call" then
    node.fn = substExpr(node.fn, env)
    substList(node.args, env)
    return node
  elseif kind == "MethodCall" then
    node.obj = substExpr(node.obj, env)
    substList(node.args, env)
    return node
  elseif kind == "Binop" then
    node.lhs = substExpr(node.lhs, env)
    node.rhs = substExpr(node.rhs, env)
    return node
  elseif kind == "Unop" then
    node.operand = substExpr(node.operand, env)
    return node
  else
    error("XenonSec ssa: unknown expression kind '" .. tostring(kind) .. "'")
  end
end

--------------------------------------------------------------------
-- Does `name` occur as a READ (expression-position Name, including
-- inside nested control-flow and function bodies) anywhere in this
-- list of statements? Assignment TARGETS (the `x` in `x = ...`) don't
-- count as a read; everything else that mentions the name does.
--------------------------------------------------------------------

local exprHasRead, statHasRead, blockHasRead
local optimizeBlock, sliceFrom, restOfBlockCaptures, statMentionsInsideFunction, blockMentionsName
local collectAssignTargetsExpr, collectAssignTargetsStat, collectAssignTargetsBlock

local function listHasRead(list, name)
  for _, e in ipairs(list) do if exprHasRead(e, name) then return true end end
  return false
end

function exprHasRead(node, name)
  local kind = node.kind
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" then
    return false
  elseif kind == "Name" then
    return node.name == name
  elseif kind == "Index" then
    return exprHasRead(node.obj, name) or exprHasRead(node.key, name)
  elseif kind == "Paren" then
    return exprHasRead(node.expr, name)
  elseif kind == "Table" then
    for _, field in ipairs(node.fields) do
      if field.type == "keyed" and exprHasRead(field.key, name) then return true end
      if exprHasRead(field.value, name) then return true end
    end
    return false
  elseif kind == "Function" then
    -- a closure that reads `name` keeps it alive (it's captured as an
    -- upvalue -- eliminating/propagating past this point is unsafe).
    return blockHasRead(node.body, name)
  elseif kind == "Call" then
    if exprHasRead(node.fn, name) then return true end
    return listHasRead(node.args, name)
  elseif kind == "MethodCall" then
    if exprHasRead(node.obj, name) then return true end
    return listHasRead(node.args, name)
  elseif kind == "Binop" then
    return exprHasRead(node.lhs, name) or exprHasRead(node.rhs, name)
  elseif kind == "Unop" then
    return exprHasRead(node.operand, name)
  else
    error("XenonSec ssa: unknown expression kind '" .. tostring(kind) .. "'")
  end
end

function statHasRead(node, name)
  local kind = node.kind
  if kind == "Local" then
    return listHasRead(node.values, name)
  elseif kind == "LocalFunction" then
    return exprHasRead(node.func, name)
  elseif kind == "Assign" then
    if listHasRead(node.values, name) then return true end
    for _, tgt in ipairs(node.targets) do
      if tgt.kind == "Index" and exprHasRead(tgt, name) then return true end
    end
    return false
  elseif kind == "ExprStat" then
    return exprHasRead(node.expr, name)
  elseif kind == "Do" then
    return blockHasRead(node.body, name)
  elseif kind == "If" then
    for _, clause in ipairs(node.clauses) do
      if exprHasRead(clause.cond, name) or blockHasRead(clause.body, name) then return true end
    end
    if node.elseBody and blockHasRead(node.elseBody, name) then return true end
    return false
  elseif kind == "While" then
    return exprHasRead(node.cond, name) or blockHasRead(node.body, name)
  elseif kind == "Repeat" then
    return blockHasRead(node.body, name) or exprHasRead(node.cond, name)
  elseif kind == "Break" then
    return false
  elseif kind == "Continue" then
    return false
  elseif kind == "NumericFor" then
    if exprHasRead(node.start, name) or exprHasRead(node.limit, name) then return true end
    if node.step and exprHasRead(node.step, name) then return true end
    return blockHasRead(node.body, name)
  elseif kind == "GenericFor" then
    if listHasRead(node.exprs, name) then return true end
    return blockHasRead(node.body, name)
  elseif kind == "Return" then
    return listHasRead(node.args, name)
  else
    error("XenonSec ssa: unknown statement kind '" .. tostring(kind) .. "'")
  end
end

function blockHasRead(block, name)
  for _, s in ipairs(block.body) do
    if statHasRead(s, name) then return true end
  end
  return false
end

--------------------------------------------------------------------
-- Is an expression free of observable side effects, so that a dead
-- assignment's RHS can be dropped entirely rather than kept as a bare
-- statement? Conservative: only literals/Name reads/pure arithmetic
-- qualify (a Call might do I/O, error, mutate something -- always
-- keep it).
--------------------------------------------------------------------

local function isSideEffectFree(node)
  local kind = node.kind
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" or kind == "Name" then
    return true
  elseif kind == "Paren" then
    return isSideEffectFree(node.expr)
  elseif kind == "Binop" then
    return isSideEffectFree(node.lhs) and isSideEffectFree(node.rhs)
  elseif kind == "Unop" then
    return isSideEffectFree(node.operand)
  else
    return false -- Index (metamethods), Table, Call, MethodCall, Function: assume effectful
  end
end

--------------------------------------------------------------------
-- Optimize one straight-line block. Recurses into nested blocks with
-- their own fresh (empty) environment, since propagation never
-- crosses a control-flow barrier.
--------------------------------------------------------------------

local function paramSet(params)
  local set = {}
  for _, p in ipairs(params or {}) do set[p] = true end
  return set
end

local function walkFunctionsInExpr(node)
  local kind = node.kind
  if kind == "Function" then
    optimizeBlock(node.body, nil, nil, paramSet(node.params))
  elseif kind == "Index" then
    walkFunctionsInExpr(node.obj); walkFunctionsInExpr(node.key)
  elseif kind == "Paren" then
    walkFunctionsInExpr(node.expr)
  elseif kind == "Table" then
    for _, f in ipairs(node.fields) do
      if f.type == "keyed" then walkFunctionsInExpr(f.key) end
      walkFunctionsInExpr(f.value)
    end
  elseif kind == "Call" then
    walkFunctionsInExpr(node.fn)
    for _, a in ipairs(node.args) do walkFunctionsInExpr(a) end
  elseif kind == "MethodCall" then
    walkFunctionsInExpr(node.obj)
    for _, a in ipairs(node.args) do walkFunctionsInExpr(a) end
  elseif kind == "Binop" then
    walkFunctionsInExpr(node.lhs); walkFunctionsInExpr(node.rhs)
  elseif kind == "Unop" then
    walkFunctionsInExpr(node.operand)
  end
  -- Number/String/Nil/True/False/Vararg/Name: nothing to recurse into
end

local function walkFunctionsInStat(stat)
  local kind = stat.kind
  if kind == "Local" or kind == "Return" then
    for _, v in ipairs(stat.values or stat.args) do walkFunctionsInExpr(v) end
  elseif kind == "Assign" then
    for _, v in ipairs(stat.values) do walkFunctionsInExpr(v) end
    for _, t in ipairs(stat.targets) do if t.kind == "Index" then walkFunctionsInExpr(t) end end
  elseif kind == "ExprStat" then
    walkFunctionsInExpr(stat.expr)
  elseif kind == "If" then
    for _, c in ipairs(stat.clauses) do walkFunctionsInExpr(c.cond) end
  elseif kind == "While" then
    walkFunctionsInExpr(stat.cond)
  elseif kind == "Repeat" then
    walkFunctionsInExpr(stat.cond)
  elseif kind == "NumericFor" then
    walkFunctionsInExpr(stat.start); walkFunctionsInExpr(stat.limit)
    if stat.step then walkFunctionsInExpr(stat.step) end
  elseif kind == "GenericFor" then
    for _, e in ipairs(stat.exprs) do walkFunctionsInExpr(e) end
  end
end

--------------------------------------------------------------------
-- After recursing into a nested control-flow body (if/while/for/
-- repeat/do), any name reassigned ANYWHERE inside it (at any depth,
-- including inside further-nested closures, conservatively) can no
-- longer be trusted to still hold its previously-tracked value once
-- we're back in the straight-line run that follows. This walks the
-- whole subtree collecting every `Assign` target name.
--------------------------------------------------------------------

function collectAssignTargetsExpr(node, into)
  local kind = node.kind
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" or kind == "Name" then
    return
  elseif kind == "Index" then
    collectAssignTargetsExpr(node.obj, into); collectAssignTargetsExpr(node.key, into)
  elseif kind == "Paren" then
    collectAssignTargetsExpr(node.expr, into)
  elseif kind == "Table" then
    for _, f in ipairs(node.fields) do
      if f.type == "keyed" then collectAssignTargetsExpr(f.key, into) end
      collectAssignTargetsExpr(f.value, into)
    end
  elseif kind == "Function" then
    collectAssignTargetsBlock(node.body, into)
  elseif kind == "Call" then
    collectAssignTargetsExpr(node.fn, into)
    for _, a in ipairs(node.args) do collectAssignTargetsExpr(a, into) end
  elseif kind == "MethodCall" then
    collectAssignTargetsExpr(node.obj, into)
    for _, a in ipairs(node.args) do collectAssignTargetsExpr(a, into) end
  elseif kind == "Binop" then
    collectAssignTargetsExpr(node.lhs, into); collectAssignTargetsExpr(node.rhs, into)
  elseif kind == "Unop" then
    collectAssignTargetsExpr(node.operand, into)
  end
end

function collectAssignTargetsStat(stat, into)
  local kind = stat.kind
  if kind == "Local" then
    for _, v in ipairs(stat.values) do collectAssignTargetsExpr(v, into) end
  elseif kind == "LocalFunction" then
    collectAssignTargetsExpr(stat.func, into)
  elseif kind == "Assign" then
    for _, v in ipairs(stat.values) do collectAssignTargetsExpr(v, into) end
    for _, t in ipairs(stat.targets) do
      if t.kind == "Name" then into[t.name] = true else collectAssignTargetsExpr(t, into) end
    end
  elseif kind == "ExprStat" then
    collectAssignTargetsExpr(stat.expr, into)
  elseif kind == "Do" then
    collectAssignTargetsBlock(stat.body, into)
  elseif kind == "If" then
    for _, c in ipairs(stat.clauses) do
      collectAssignTargetsExpr(c.cond, into)
      collectAssignTargetsBlock(c.body, into)
    end
    if stat.elseBody then collectAssignTargetsBlock(stat.elseBody, into) end
  elseif kind == "While" then
    collectAssignTargetsExpr(stat.cond, into); collectAssignTargetsBlock(stat.body, into)
  elseif kind == "Repeat" then
    collectAssignTargetsBlock(stat.body, into); collectAssignTargetsExpr(stat.cond, into)
  elseif kind == "NumericFor" then
    collectAssignTargetsExpr(stat.start, into); collectAssignTargetsExpr(stat.limit, into)
    if stat.step then collectAssignTargetsExpr(stat.step, into) end
    collectAssignTargetsBlock(stat.body, into)
  elseif kind == "GenericFor" then
    for _, e in ipairs(stat.exprs) do collectAssignTargetsExpr(e, into) end
    collectAssignTargetsBlock(stat.body, into)
  elseif kind == "Return" then
    for _, a in ipairs(stat.args) do collectAssignTargetsExpr(a, into) end
  end
end

function collectAssignTargetsBlock(block, into)
  for _, s in ipairs(block.body) do collectAssignTargetsStat(s, into) end
end


--------------------------------------------------------------------
-- Cross-branch propagation. Values flow into nested blocks and back
-- out, under these rules (each one is conservative):
--
--   * A nested block starts from the environment that is valid at its
--     entry point.
--   * An if/elseif/else, and a do-block, leaves behind the phi of its
--     branches: a name keeps a tracked value only if every branch that
--     can fall through ends with the same literal for it. An implicit
--     empty else counts as a branch that changes nothing.
--   * A loop header starts from the entry environment minus the loop
--     variables, names the body declares, and captured names when the
--     loop runs code. Then names whose value differs on some back edge,
--     continue or break are dropped, repeating until nothing changes
--     (loopHeaderEnv). The header environment is also the environment
--     after the loop, so every route out of the loop has been checked.
--   * A condition that is a literal after propagation decides its if:
--     dead clauses are dropped, and a surviving first clause collapses
--     the whole statement into a do-block.
--------------------------------------------------------------------

local function copyEnv(env)
  local out = {}
  for k, v in pairs(env) do out[k] = v end
  return out
end

-- The environment for a statement that calls something: a call can
-- change captured names before a later part of the same statement reads
-- them, so those reads are left alone.
local function withoutCaptured(env)
  local out = {}
  for k, v in pairs(env) do
    if not capturedNames[k] then out[k] = v end
  end
  return out
end

-- Canonical text of a tracked value, so two branch results can be
-- compared. Anything untrackable gets a unique key and never compares equal.
local function valueKey(node)
  if node == nil then return nil end
  local kind = node.kind
  if kind == "Number" then return "N" .. tostring(node.value)
  elseif kind == "String" then return "S" .. string.format("%q", node.value)
  elseif kind == "Nil" then return "nil"
  elseif kind == "True" then return "true"
  elseif kind == "False" then return "false"
  elseif kind == "Paren" then return "(" .. tostring(valueKey(node.expr)) .. ")"
  elseif kind == "Binop" then
    return "(" .. tostring(valueKey(node.lhs)) .. node.op .. tostring(valueKey(node.rhs)) .. ")"
  elseif kind == "Unop" then
    return "(" .. node.op .. tostring(valueKey(node.operand)) .. ")"
  end
  return "?" .. tostring(node)
end

-- Names a block declares at its top level. They shadow outer names, so
-- their values must never leak out of the block.
local function declaredNames(block)
  local names = {}
  for _, s in ipairs(block.body) do
    if s.kind == "Local" then
      for _, n in ipairs(s.names) do names[n] = true end
    elseif s.kind == "LocalFunction" then
      names[s.name] = true
    end
  end
  return names
end

-- true or false when a literal decides a condition; nil otherwise.
local function constTruth(node)
  local kind = node.kind
  if kind == "Nil" or kind == "False" then return false end
  if kind == "Number" or kind == "String" or kind == "True" then return true end
  return nil
end

local blockContainsCall
local function statContainsCallDeep(s)
  if statementContainsCall(s) then return true end
  local kind = s.kind
  if kind == "Repeat" then
    return exprContainsCall(s.cond) or blockContainsCall(s.body)
  elseif kind == "Do" or kind == "While" or kind == "NumericFor" or kind == "GenericFor" then
    return blockContainsCall(s.body)
  elseif kind == "If" then
    for _, c in ipairs(s.clauses) do
      if blockContainsCall(c.body) then return true end
    end
    return s.elseBody ~= nil and blockContainsCall(s.elseBody)
  end
  return false
end

function blockContainsCall(block)
  for _, s in ipairs(block.body) do
    if statContainsCallDeep(s) then return true end
  end
  return false
end

-- Deep copy of an AST subtree, so a trial optimization of a loop body can
-- never leave changes behind when its result is thrown away.
local function deepCopy(node, seen)
  if type(node) ~= "table" then return node end
  seen = seen or {}
  if seen[node] then return seen[node] end
  local out = {}
  seen[node] = out
  for k, v in pairs(node) do out[k] = deepCopy(v, seen) end
  return out
end

-- One frame per loop body being optimized. Break and Continue record the
-- environment at their own point, so the loop fixed point can check every
-- route back to the header and every route out of the loop.
local loopFrames = {}
-- Loops currently nested inside each other. Past MAX_PHI_DEPTH the loop
-- uses the conservative entry environment, which keeps the work bounded.
local loopDepth = 0
local MAX_PHI_DEPTH = 3

-- Can control fall off the end of this block (into the next iteration)?
local function fallsThrough(block)
  local last = block.body[#block.body]
  return not (last ~= nil and (last.kind == "Return" or last.kind == "Break"
    or last.kind == "Continue"))
end

-- Optimizes a trial copy of a loop body and returns its exit environment
-- and the environments recorded at its break and continue statements.
local function trialLoopBody(body, entry, tail, scope)
  local frame = { breaks = {}, continues = {} }
  loopFrames[#loopFrames + 1] = frame
  local exit = optimizeBlock(body, entry, tail, scope)
  loopFrames[#loopFrames] = nil
  return exit, frame
end

-- The environment that is valid at the header of EVERY iteration of a loop,
-- found as a fixed point. It starts from the environment before the loop,
-- minus what the loop cannot keep (loop variables, names the body declares,
-- and captured names when the loop calls anything). It then drops each name
-- whose value at some back edge, continue, or break differs from it, and
-- repeats until nothing changes. A name that survives is a phi of identical
-- inputs: the value before the loop and the value on every route back.
-- Names only ever leave the set, so this terminates.
local function loopHeaderEnv(env, s, tail, scope, loopVars)
  local header = copyEnv(env)
  for _, name in ipairs(loopVars) do header[name] = nil end
  for name in pairs(declaredNames(s.body)) do header[name] = nil end
  if statContainsCallDeep(s) then
    for name in pairs(capturedNames) do header[name] = nil end
  end
  while true do
    local exit, frame = trialLoopBody(deepCopy(s.body), header, tail, scope)
    local bad = {}
    local function check(e)
      for name, v in pairs(header) do
        if valueKey(e[name]) ~= valueKey(v) then bad[name] = true end
      end
    end
    if fallsThrough(s.body) then check(exit) end
    for _, e in ipairs(frame.continues) do check(e) end
    for _, e in ipairs(frame.breaks) do check(e) end
    if next(bad) == nil then return header end
    for name in pairs(bad) do header[name] = nil end
  end
end

-- The environment that is valid at the start of EVERY iteration of a loop.
-- Conservative: drops every name the loop assigns.
local function loopEntryEnv(env, body, cond, loopVars)
  local e = copyEnv(env)
  local assigned = {}
  collectAssignTargetsBlock(body, assigned)
  for name in pairs(assigned) do e[name] = nil end
  for name in pairs(declaredNames(body)) do e[name] = nil end
  for _, name in ipairs(loopVars) do e[name] = nil end
  if blockContainsCall(body) or (cond ~= nil and exprContainsCall(cond)) then
    for name in pairs(capturedNames) do e[name] = nil end
  end
  return e
end

-- What one branch of a construct leaves behind: its exit environment,
-- whether it can fall through, and the names it declares at top level.
local function branchResult(block, entry, scope)
  local kill = declaredNames(block)
  local exit = optimizeBlock(block, entry, nil, scope)
  local last = block.body[#block.body]
  local terminates = last ~= nil and (last.kind == "Return" or last.kind == "Break"
    or last.kind == "Continue")
  return { env = exit, kill = kill, terminates = terminates }
end

-- Replaces env with the phi of the branches (all entered with `pre`):
-- a name keeps its value only where every falling-through branch agrees.
local function mergeBranches(env, pre, branches)
  local fall = {}
  for _, b in ipairs(branches) do
    if not b.terminates then fall[#fall + 1] = b end
  end
  for k in pairs(env) do env[k] = nil end
  if #fall == 0 then return end -- every path leaves: nothing after this point runs
  for name in pairs(pre) do
    local first, agreed = nil, true
    for idx, b in ipairs(fall) do
      local v = (not b.kill[name]) and b.env[name] or nil
      if idx == 1 then
        first = v
      elseif valueKey(v) ~= valueKey(first) then
        agreed = false
        break
      end
    end
    if agreed and first ~= nil then env[name] = first end
  end
end

local function emptyDo(s)
  return { kind = "Do", body = { kind = "Block", body = {} }, line = s.line }
end

-- Drops clauses whose condition is a false literal, and collapses the if
-- when a true literal decides it. Returns the statement that replaces s.
local function simplifyIf(s)
  local kept = {}
  for _, c in ipairs(s.clauses) do
    local t = constTruth(c.cond)
    if t == true then
      if #kept == 0 then return { kind = "Do", body = c.body, line = s.line } end
      return { kind = "If", clauses = kept, elseBody = c.body, line = s.line }
    elseif t == nil then
      kept[#kept + 1] = c
    end
  end
  if #kept == 0 then
    if s.elseBody then return { kind = "Do", body = s.elseBody, line = s.line } end
    return emptyDo(s)
  end
  return { kind = "If", clauses = kept, elseBody = s.elseBody, line = s.line }
end

--------------------------------------------------------------------
-- Optimize one block. `entryEnv` is the environment valid where the
-- block starts (nil for a function body, which starts fresh). `tail`
-- lists statements that run inside this block's scope after its last
-- statement (a repeat-until condition), so they count as reads. Returns
-- the environment valid where the block ends.
--------------------------------------------------------------------

function optimizeBlock(block, entryEnv, tail, scope)
  local env = entryEnv and copyEnv(entryEnv) or {}
  -- Names that are locals at this point. Only these may be tracked on
  -- assignment: an assigned global can be changed by code this pass
  -- never sees, so it is never a candidate.
  local locals = copyEnv(scope or {})
  local stmts = block.body
  local out = {}

  for i = 1, #stmts do
    local s = stmts[i]
    local subEnv = statementContainsCall(s) and withoutCaptured(env) or env

    if (s.kind == "Break" or s.kind == "Continue") and #loopFrames > 0 then
      local frame = loopFrames[#loopFrames]
      local list = (s.kind == "Break") and frame.breaks or frame.continues
      list[#list + 1] = copyEnv(env)
    end

    -- Propagate known values into this statement's own expressions
    -- BEFORE interpreting what it defines or invalidates. A while or
    -- repeat condition re-evaluates every iteration, so it only sees
    -- values the loop cannot change (see loopEntryEnv).
    if s.kind == "Local" then
      substList(s.values, subEnv)
    elseif s.kind == "Assign" then
      substList(s.values, subEnv)
      for _, tgt in ipairs(s.targets) do
        if tgt.kind == "Index" then
          tgt.obj = substExpr(tgt.obj, subEnv)
          tgt.key = substExpr(tgt.key, subEnv)
        end
      end
    elseif s.kind == "ExprStat" then
      s.expr = substExpr(s.expr, subEnv)
    elseif s.kind == "If" then
      for _, c in ipairs(s.clauses) do c.cond = substExpr(c.cond, subEnv) end
    elseif s.kind == "While" then
      s.cond = substExpr(s.cond, loopEntryEnv(env, s.body, s.cond, {}))
    elseif s.kind == "NumericFor" then
      s.start = substExpr(s.start, subEnv)
      s.limit = substExpr(s.limit, subEnv)
      if s.step then s.step = substExpr(s.step, subEnv) end
    elseif s.kind == "GenericFor" then
      substList(s.exprs, subEnv)
    elseif s.kind == "Return" then
      substList(s.args, subEnv)
    end

    -- A condition that became a literal decides its if (or while).
    if s.kind == "If" then
      s = simplifyIf(s)
    elseif s.kind == "While" and constTruth(s.cond) == false then
      s = emptyDo(s)
    end

    -- Closures get their own fresh environment; the expression sweep
    -- also reaches closures in conditions and headers.
    walkFunctionsInStat(s)
    if s.kind == "LocalFunction" and s.func.kind == "Function" then
      optimizeBlock(s.func.body, nil, nil, paramSet(s.func.params))
    end

    if s.kind == "If" then
      invalidateCapturedAfterCall(s, env)
      local pre = copyEnv(env)
      local branches = {}
      for _, c in ipairs(s.clauses) do branches[#branches + 1] = branchResult(c.body, pre, locals) end
      if s.elseBody then
        branches[#branches + 1] = branchResult(s.elseBody, pre, locals)
      else
        branches[#branches + 1] = { env = copyEnv(pre), kill = {}, terminates = false }
      end
      mergeBranches(env, pre, branches)
      out[#out + 1] = s
    elseif s.kind == "Do" then
      local pre = copyEnv(env)
      mergeBranches(env, pre, { branchResult(s.body, pre, locals) })
      out[#out + 1] = s
    elseif s.kind == "While" or s.kind == "Repeat" or s.kind == "NumericFor" or s.kind == "GenericFor" then
      invalidateCapturedAfterCall(s, env)
      local loopVars = {}
      if s.kind == "NumericFor" then
        loopVars[1] = s.var
      elseif s.kind == "GenericFor" then
        loopVars = s.names
      end
      local cond = (s.kind == "While") and s.cond or nil
      local tail = nil
      if s.kind == "Repeat" then tail = { { kind = "ExprStat", expr = s.cond } } end
      local inner = copyEnv(locals)
      for _, name in ipairs(loopVars) do inner[name] = true end

      loopDepth = loopDepth + 1
      local header
      if loopDepth <= MAX_PHI_DEPTH then
        header = loopHeaderEnv(env, s, tail, inner, loopVars)
      else
        header = loopEntryEnv(env, s.body, cond, loopVars)
      end
      -- The real pass, over the original body, with the agreed header.
      trialLoopBody(s.body, header, tail, inner)
      loopDepth = loopDepth - 1
      -- The condition (re-evaluated at every header, and after the body for
      -- repeat) only sees names whose value the loop cannot change.
      if s.kind == "While" or s.kind == "Repeat" then
        s.cond = substExpr(s.cond, header)
      end
      -- Leaving the loop, every name in the header set still has its value:
      -- it was checked at every back edge, continue, and break.
      for k in pairs(env) do env[k] = nil end
      for k, v in pairs(header) do env[k] = v end
      out[#out + 1] = s
    else
      -- A function call anywhere in this statement could, through a
      -- closure, mutate any variable captured anywhere in the program.
      invalidateCapturedAfterCall(s, env)

      local handled = false
      if s.kind == "Local" and #s.names == 1 and #s.values <= 1 then
        local name = s.names[1]
        local val = s.values[1]
        locals[name] = true
        local later = sliceFrom(stmts, i + 1)
        for _, t in ipairs(tail or {}) do later[#later + 1] = t end
        -- A later reassignment counts as a mention: if the declaration were
        -- removed, the assignment would silently write a global instead.
        local isDead = not blockMentionsName({ body = later }, name)
          and not restOfBlockCaptures(later, 1, name)

        if isDead then
          if val ~= nil and not isSideEffectFree(val) then
            out[#out + 1] = { kind = "ExprStat", expr = val, line = s.line }
          end
          -- else: fully removable, no observable effect lost
          handled = true
        else
          if val and isTrackable(val) then
            env[name] = val
          else
            env[name] = nil
          end
          out[#out + 1] = s
          handled = true
        end
      end

      if not handled then
        -- A declaration that is not tracked shadows whatever was known
        -- about the same name, so forget it.
        if s.kind == "Local" then
          for _, n in ipairs(s.names) do env[n] = nil; locals[n] = true end
        elseif s.kind == "LocalFunction" then
          env[s.name] = nil
          locals[s.name] = true
        elseif s.kind == "Assign" then
          for _, tgt in ipairs(s.targets) do
            if tgt.kind == "Name" then env[tgt.name] = nil end
          end
          -- A plain assignment of a literal to a local re-establishes its value.
          local tgt = s.targets[1]
          if #s.targets == 1 and tgt.kind == "Name" and locals[tgt.name]
            and #s.values == 1 and isTrackable(s.values[1]) and not statementContainsCall(s) then
            env[tgt.name] = s.values[1]
          end
        end
        out[#out + 1] = s
      end
    end
  end

  block.body = out
  return env
end

-- Does the name get captured by a nested Function literal anywhere
-- in the given tail of statements? (A closure could read it *later*
-- at call time even if no textual "read" appears to run before the
-- closure is created and escapes -- treat any mention inside a nested
-- Function, as either read or write, as pinning it alive.)
function restOfBlockCaptures(stmts, fromIdx, name)
  for i = fromIdx, #stmts do
    if statMentionsInsideFunction(stmts[i], name) then return true end
  end
  return false
end

function sliceFrom(list, fromIdx)
  local out = {}
  for i = fromIdx, #list do out[#out + 1] = list[i] end
  return out
end

function statMentionsInsideFunction(stat, name)
  -- Reuse exprHasRead's Function-case (it already descends into
  -- function bodies looking for reads); a write-only mention inside a
  -- closure is rare enough, and still-conservative-safe, to fold into
  -- the same "any occurrence" check via a simple textual scan.
  local found = false
  local function scanExpr(node)
    if found or node == nil then return end
    local kind = node.kind
    if kind == "Function" then
      -- any occurrence of `name` anywhere inside this closure's body
      -- pins the outer local alive.
      if blockMentionsName(node.body, name) then found = true end
      return
    elseif kind == "Index" then scanExpr(node.obj); scanExpr(node.key)
    elseif kind == "Paren" then scanExpr(node.expr)
    elseif kind == "Table" then
      for _, f in ipairs(node.fields) do
        if f.type == "keyed" then scanExpr(f.key) end
        scanExpr(f.value)
      end
    elseif kind == "Call" then
      scanExpr(node.fn); for _, a in ipairs(node.args) do scanExpr(a) end
    elseif kind == "MethodCall" then
      scanExpr(node.obj); for _, a in ipairs(node.args) do scanExpr(a) end
    elseif kind == "Binop" then scanExpr(node.lhs); scanExpr(node.rhs)
    elseif kind == "Unop" then scanExpr(node.operand)
    end
  end
  local kind = stat.kind
  if kind == "Local" then for _, v in ipairs(stat.values) do scanExpr(v) end
  elseif kind == "LocalFunction" then scanExpr(stat.func)
  elseif kind == "Assign" then
    for _, v in ipairs(stat.values) do scanExpr(v) end
    for _, t in ipairs(stat.targets) do if t.kind == "Index" then scanExpr(t) end end
  elseif kind == "ExprStat" then scanExpr(stat.expr)
  elseif kind == "Do" then found = blockMentionsName(stat.body, name)
  elseif kind == "If" then
    for _, c in ipairs(stat.clauses) do
      scanExpr(c.cond)
      if blockMentionsName(c.body, name) then found = true end
    end
    if stat.elseBody and blockMentionsName(stat.elseBody, name) then found = true end
  elseif kind == "While" then scanExpr(stat.cond); if blockMentionsName(stat.body, name) then found = true end
  elseif kind == "Repeat" then if blockMentionsName(stat.body, name) then found = true end; scanExpr(stat.cond)
  elseif kind == "NumericFor" then
    scanExpr(stat.start); scanExpr(stat.limit); if stat.step then scanExpr(stat.step) end
    if blockMentionsName(stat.body, name) then found = true end
  elseif kind == "GenericFor" then
    for _, e in ipairs(stat.exprs) do scanExpr(e) end
    if blockMentionsName(stat.body, name) then found = true end
  elseif kind == "Return" then for _, a in ipairs(stat.args) do scanExpr(a) end
  end
  return found
end

function blockMentionsName(block, name)
  for _, s in ipairs(block.body) do
    if statHasRead(s, name) then return true end
    if statMentionsInsideFunction(s, name) then return true end
    -- also count plain reassignment targets as a mention (pins it, safest)
    if s.kind == "Assign" then
      for _, t in ipairs(s.targets) do
        if t.kind == "Name" and t.name == name then return true end
      end
    end
  end
  return false
end

function SSA.apply(ast, capturedSet)
  capturedNames = capturedSet or {}
  optimizeBlock(ast)
  return ast
end

return SSA
