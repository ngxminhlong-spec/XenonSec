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
-- What this deliberately does NOT do: build phi-functions at the
-- merge points of if/while/for (that's full whole-function SSA with
-- control-flow-graph construction -- a materially bigger project).
-- Every nested control-flow construct (if/while/for/repeat/do/
-- function) is treated as an opacity barrier: propagation never
-- crosses into or out of one. This is what keeps the pass simple
-- *and* unconditionally safe -- it only ever reasons about code that
-- really does execute as one straight, unbranching sequence.
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

local function exprContainsCall(node)
  local kind = node.kind
  if kind == "Call" or kind == "MethodCall" then return true end
  if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True"
    or kind == "False" or kind == "Vararg" or kind == "Name" or kind == "Function" then
    return false
  elseif kind == "Index" then
    return exprContainsCall(node.obj) or exprContainsCall(node.key)
  elseif kind == "Paren" then
    return exprContainsCall(node.expr)
  elseif kind == "Table" then
    for _, f in ipairs(node.fields) do
      if f.type == "keyed" and exprContainsCall(f.key) then return true end
      if exprContainsCall(f.value) then return true end
    end
    return false
  elseif kind == "Binop" then
    return exprContainsCall(node.lhs) or exprContainsCall(node.rhs)
  elseif kind == "Unop" then
    return exprContainsCall(node.operand)
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
      if t.kind == "Index" and (exprContainsCall(t.obj) or exprContainsCall(t.key)) then return true end
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

local function recurseIntoNestedBlocks(stat)
  local kind = stat.kind
  if kind == "Do" then
    optimizeBlock(stat.body)
  elseif kind == "If" then
    for _, clause in ipairs(stat.clauses) do optimizeBlock(clause.body) end
    if stat.elseBody then optimizeBlock(stat.elseBody) end
  elseif kind == "While" then
    optimizeBlock(stat.body)
  elseif kind == "Repeat" then
    optimizeBlock(stat.body)
  elseif kind == "NumericFor" then
    optimizeBlock(stat.body)
  elseif kind == "GenericFor" then
    optimizeBlock(stat.body)
  elseif kind == "LocalFunction" then
    if stat.func.kind == "Function" then optimizeBlock(stat.func.body) end
  end
  -- Function-literal RHS values inside Local/Assign/ExprStat/Return/Table
  -- are reached via a generic sweep below (walkFunctionsIn), since they
  -- can appear anywhere an expression can.
end

local function walkFunctionsInExpr(node)
  local kind = node.kind
  if kind == "Function" then
    optimizeBlock(node.body)
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

local function invalidateFromNested(stat, env)
  local names = {}
  collectAssignTargetsStat(stat, names)
  for name in pairs(names) do env[name] = nil end
end

function optimizeBlock(block)
  local env = {} -- name -> tracked pure expr, only while provably still valid
  local stmts = block.body
  local out = {}

  for i = 1, #stmts do
    local s = stmts[i]

    -- Propagate known values into this statement's own expressions
    -- BEFORE interpreting what it defines/invalidates.
    --
    -- IMPORTANT: a `while`/`repeat` condition re-evaluates on every
    -- iteration, seeing whatever the body most recently assigned --
    -- so it must never be substituted using a value the body itself
    -- reassigns (that would freeze a loop-carried variable at its
    -- pre-loop value forever, e.g. turning `while i < n` into a
    -- permanently-true `while 0 < 3`). NumericFor/GenericFor's
    -- start/limit/step/exprs, by contrast, really do only evaluate
    -- once at loop entry, so substituting the current env there is
    -- correct. Likewise every If clause's cond only ever evaluates
    -- once, before this If's own body has had a chance to run.
    if s.kind == "Local" then
      substList(s.values, env)
    elseif s.kind == "LocalFunction" then
      -- name is bound before the body per Lua semantics; body is a
      -- barrier anyway (handled by walkFunctionsIn / recurse below)
    elseif s.kind == "Assign" then
      substList(s.values, env)
      for _, tgt in ipairs(s.targets) do
        if tgt.kind == "Index" then
          tgt.obj = substExpr(tgt.obj, env)
          tgt.key = substExpr(tgt.key, env)
        end
      end
    elseif s.kind == "ExprStat" then
      s.expr = substExpr(s.expr, env)
    elseif s.kind == "If" then
      for _, c in ipairs(s.clauses) do c.cond = substExpr(c.cond, env) end
    elseif s.kind == "While" then
      local loopSafeEnv = {}
      for k, v in pairs(env) do loopSafeEnv[k] = v end
      local assigned = {}
      collectAssignTargetsBlock(s.body, assigned)
      for name in pairs(assigned) do loopSafeEnv[name] = nil end
      s.cond = substExpr(s.cond, loopSafeEnv)
    elseif s.kind == "NumericFor" then
      s.start = substExpr(s.start, env)
      s.limit = substExpr(s.limit, env)
      if s.step then s.step = substExpr(s.step, env) end
    elseif s.kind == "GenericFor" then
      substList(s.exprs, env)
    elseif s.kind == "Return" then
      substList(s.args, env)
    end
    -- Repeat's cond is handled after recursing into its body (it can
    -- read the body's own locals); Do/Break need no substitution here.

    -- Now recurse into any nested block/function bodies (each gets its
    -- own fresh environment -- propagation never crosses this line).
    recurseIntoNestedBlocks(s)
    walkFunctionsInStat(s)
    if s.kind == "Repeat" then
      -- Same loop-carried hazard as While: repeat's `until` condition
      -- re-evaluates every iteration too, after the body has already
      -- run at least once, so it must not see pre-loop values for
      -- anything the body reassigns.
      local loopSafeEnv = {}
      for k, v in pairs(env) do loopSafeEnv[k] = v end
      local assigned = {}
      collectAssignTargetsBlock(s.body, assigned)
      for name in pairs(assigned) do loopSafeEnv[name] = nil end
      s.cond = substExpr(s.cond, loopSafeEnv)
    end

    -- Anything reassigned anywhere inside a nested body can no longer
    -- be trusted to hold its previously-tracked value from here on.
    if s.kind == "If" or s.kind == "While" or s.kind == "Repeat"
      or s.kind == "NumericFor" or s.kind == "GenericFor" or s.kind == "Do" then
      invalidateFromNested(s, env)
    end

    -- A function call anywhere in this statement could, through a
    -- closure, mutate any variable that's captured anywhere in the
    -- program -- even ones with no visible call between their tracked
    -- definition and here. See the module banner comment for why this
    -- check exists (it's fixing a real bug that was found here).
    invalidateCapturedAfterCall(s, env)

    -- Decide what this statement does to `env` going forward, and
    -- whether a dead `local` can be eliminated.
    local handled = false
    if s.kind == "Local" and #s.names == 1 and #s.values <= 1 then
      local name = s.names[1]
      local val = s.values[1]
      local isDead = not blockHasRead({ body = sliceFrom(stmts, i + 1) }, name)
        and not restOfBlockCaptures(stmts, i + 1, name)

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
      if s.kind == "Local" then
        -- multi-name local decl: conservatively invalidate anything
        -- these names might have shadowed/aliased, but we never track
        -- multi-name decls to begin with, so nothing to invalidate.
      elseif s.kind == "Assign" then
        for _, tgt in ipairs(s.targets) do
          if tgt.kind == "Name" then env[tgt.name] = nil end
        end
      end
      out[#out + 1] = s
    end
  end

  block.body = out
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
