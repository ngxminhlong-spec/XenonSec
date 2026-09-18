--------------------------------------------------------------------
-- XenonSec :: compiler.lua
-- Compiles an AST (see parser.lua) into a flat instruction list for
-- the XenonSec stack-based virtual machine.
--
-- Design notes
-- ------------
-- * Variables are NOT statically resolved to registers. Instead each
--   running function frame is a chain of "scope" tables:
--       scope = { vars = {}, parent = <scope or nil> }
--   Reads walk the chain; if not found anywhere, the global table is
--   used. This keeps the compiler simple while still producing fully
--   correct closures/upvalues, because a closure captures the scope
--   table *by reference* exactly like real Lua captures upvalues.
-- * Values that can yield a variable number of results (function
--   calls, method calls) carry a "multi" flag through the compiler.
--   At runtime, a multi-producing CALL pushes its result values in
--   order followed by a trailing count. Consumers that need an exact
--   number of values (ADJUSTMULTI) or a dynamic prefix (CALL/RETURN/
--   SETLIST argument gathering) pop that count first.
--------------------------------------------------------------------

local Compiler = {}

local function newModule()
	return {
		consts = {},           -- array of literal constants (numbers/strings)
		constIndex = {},       -- value -> index memoization (strings/numbers only)
		protos = {},           -- array of function prototypes
	}
end

local function addConst(mod, value)
	local key = type(value) .. ":" .. tostring(value)
	local existing = mod.constIndex[key]
	if existing then return existing end
	mod.consts[#mod.consts + 1] = value
	local idx = #mod.consts
	mod.constIndex[key] = idx
	return idx
end

local function newProto(mod, params, hasVararg)
	mod.protos[#mod.protos + 1] = { params = params, nparams = #params, hasVararg = hasVararg, code = {} }
	return #mod.protos
end

-- Per-function compile context.
local function newCtx(mod, protoIndex)
	return {
		mod = mod,
		protoIndex = protoIndex,
		code = mod.protos[protoIndex].code,
		loopStack = {},
		tempCounter = 0,
		scopeDepth = 0,
		regMap = {},  -- name -> register slot, scoped to THIS proto only
		nextReg = 0,
	}
end

local function emit(ctx, op, a, b, c)
	local code = ctx.code
	code[#code + 1] = { op = op, a = a, b = b, c = c }
	return #code
end

-- NEWSCOPE/POPSCOPE must always go through these two so ctx.scopeDepth
-- stays accurate; `break` uses it to unwind exactly the right number of
-- scopes that are open at the break point but wouldn't otherwise be
-- closed by the loop's normal (non-break) exit path.
local function pushScope(ctx)
	emit(ctx, "NEWSCOPE")
	ctx.scopeDepth = ctx.scopeDepth + 1
end

local function popScope(ctx)
	emit(ctx, "POPSCOPE")
	ctx.scopeDepth = ctx.scopeDepth - 1
end

local function here(ctx) return #ctx.code + 1 end

local function patchTo(ctx, idx, target)
	ctx.code[idx].a = target
end

local function k(ctx, value) return addConst(ctx.mod, value) end

local function tempName(ctx)
	ctx.tempCounter = ctx.tempCounter + 1
	return "__xs_t" .. ctx.tempCounter .. "_" .. tostring(math.random(100000, 999999))
end

--------------------------------------------------------------------
-- Register vs. scope-chain decision.
--
-- renamer.lua tags every genuine local binding with a "\1xs<N>" token;
-- anything else reaching a Name node is a real global (left alone by
-- renamer). capture.lua then marks which of those local tokens are
-- ever referenced from inside a nested closure -- those MUST keep
-- using the proven scope-chain/cell mechanism (a closure captures the
-- scope chain by reference; a flat register slot has no such capture
-- story). Everything else -- the common case -- gets a flat per-call
-- register slot instead of a scope-chain dictionary walk.
--
-- Compiler-internal temporaries (from tempName()) are never visible
-- to user code, so they can never be captured by a user closure --
-- always safe to register-allocate directly.
--------------------------------------------------------------------

local function isLocalToken(name)
	return type(name) == "string" and name:sub(1, 1) == "\1"
end

local function isCaptured(ctx, name)
	return ctx.mod.capturedSet ~= nil and ctx.mod.capturedSet[name] == true
end

local function regSlotFor(ctx, name)
	local r = ctx.regMap[name]
	if not r then
		r = ctx.nextReg
		ctx.nextReg = ctx.nextReg + 1
		ctx.regMap[name] = r
	end
	return r
end

-- Reads a name (local-or-global), pushing exactly one value.
local function emitGet(ctx, name)
	if isLocalToken(name) and not isCaptured(ctx, name) then
		emit(ctx, "GETREG", regSlotFor(ctx, name))
	else
		emit(ctx, "GETVAR", k(ctx, name))
	end
end

-- Writes to an EXISTING binding (reassignment), or a real global if
-- `name` was never declared local at all. Consumes the stack top.
local function emitSet(ctx, name)
	if isLocalToken(name) and not isCaptured(ctx, name) then
		emit(ctx, "SETREG", regSlotFor(ctx, name))
	else
		emit(ctx, "SETVAR", k(ctx, name))
	end
end

-- Declares a BRAND NEW local binding (Local/params/for-vars are
-- always renamer tokens by construction). Consumes the stack top.
-- For the register path, "declare" and "reassign" are the same
-- operation (each declaration site already owns a dedicated slot
-- number, so there's no separate chain entry to create).
local function emitDeclare(ctx, name)
	if isCaptured(ctx, name) then
		emit(ctx, "DECLLOCAL", k(ctx, name))
	else
		emit(ctx, "SETREG", regSlotFor(ctx, name))
	end
end

-- Compiler-internal temporaries: always registers, no checks needed.
local function emitTempDeclare(ctx, name) emit(ctx, "SETREG", regSlotFor(ctx, name)) end
local function emitTempGet(ctx, name) emit(ctx, "GETREG", regSlotFor(ctx, name)) end
local function emitTempSet(ctx, name) emit(ctx, "SETREG", regSlotFor(ctx, name)) end

--------------------------------------------------------------------
-- Forward decls
--------------------------------------------------------------------
local compileExpr, compileStat, compileBlockScoped, compileBlockBare
local compileExprListExactN, compileExprListVariadic, compileCallLike

--------------------------------------------------------------------
-- Helpers for multi-value expression classification
--------------------------------------------------------------------

local function isMultiCapable(node)
	return node.kind == "Call" or node.kind == "MethodCall" or node.kind == "Vararg"
end

--------------------------------------------------------------------
-- compileExprListVariadic(exprs, ctx)
--   Pushes as many values as `exprs` naturally yields:
--     - all but the last are truncated to exactly 1 value each
--     - the last, if it's a call/methodcall/vararg, contributes ALL
--       of its results (trailing multi group + count marker)
--   Returns: fixedCount (values pushed before any trailing group),
--            hasTrailing (bool)
--------------------------------------------------------------------
function compileExprListVariadic(exprs, ctx)
	if #exprs == 0 then return 0, false end
	for i = 1, #exprs - 1 do
		compileExpr(exprs[i], ctx, false)
	end
	local last = exprs[#exprs]
	if isMultiCapable(last) then
		compileExpr(last, ctx, true)
		return #exprs - 1, true
	else
		compileExpr(last, ctx, false)
		return #exprs, false
	end
end

--------------------------------------------------------------------
-- compileExprListExactN(exprs, n, ctx)
--   Leaves exactly n values on the stack (bottom..top = value1..valueN)
--   regardless of how many expressions were supplied.
--------------------------------------------------------------------
function compileExprListExactN(exprs, n, ctx)
	if #exprs == 0 then
		for _ = 1, n do emit(ctx, "LOADNIL") end
		return
	end
	local fixedCount, hasTrailing = compileExprListVariadic(exprs, ctx)
	local total
	if hasTrailing then
		local wanted = n - fixedCount
		if wanted < 0 then wanted = 0 end
		emit(ctx, "ADJUSTMULTI", wanted)
		total = fixedCount + wanted
	else
		total = fixedCount
	end
	if total > n then
		emit(ctx, "POP", total - n)
	elseif total < n then
		for _ = 1, n - total do emit(ctx, "LOADNIL") end
	end
end

--------------------------------------------------------------------
-- Call / method-call compilation
-- prefixCount: number of values already pushed on the stack that must
--              be treated as leading fixed arguments (1 for method
--              calls -- the "self" object -- 0 for plain calls).
--------------------------------------------------------------------
function compileCallLike(prefixCount, argExprs, ctx, resultMulti)
	local fixedFromArgs, hasTrailing = compileExprListVariadic(argExprs, ctx)
	local nargsStatic = prefixCount + fixedFromArgs
	emit(ctx, "CALL", nargsStatic, hasTrailing and 1 or 0, resultMulti and 1 or 0)
end

--------------------------------------------------------------------
-- compileExpr(node, ctx, wantMulti)
--   Pushes exactly 1 value, UNLESS wantMulti is true and node is
--   multi-capable, in which case it pushes a trailing multi group.
--------------------------------------------------------------------
function compileExpr(node, ctx, wantMulti)
	local kind = node.kind
	if kind == "Number" then
		emit(ctx, "LOADK", k(ctx, node.value))
	elseif kind == "String" then
		emit(ctx, "LOADK", k(ctx, node.value))
	elseif kind == "Nil" then
		emit(ctx, "LOADNIL")
	elseif kind == "True" then
		emit(ctx, "LOADTRUE")
	elseif kind == "False" then
		emit(ctx, "LOADFALSE")
	elseif kind == "Vararg" then
		if wantMulti then
			emit(ctx, "VARARGMULTI")
		else
			emit(ctx, "VARARGONE")
		end
	elseif kind == "Name" then
		emitGet(ctx, node.name)
	elseif kind == "Index" then
		compileExpr(node.obj, ctx, false)
		compileExpr(node.key, ctx, false)
		emit(ctx, "GETINDEX")
	elseif kind == "Paren" then
		compileExpr(node.expr, ctx, false)
	elseif kind == "Table" then
		emit(ctx, "NEWTABLE")
		local autoIndex = 0
		for i, field in ipairs(node.fields) do
			local isLast = (i == #node.fields)
			if field.type == "keyed" then
				emit(ctx, "DUP")
				compileExpr(field.key, ctx, false)
				compileExpr(field.value, ctx, false)
				emit(ctx, "SETINDEX")
			else
				if isLast and isMultiCapable(field.value) then
					emit(ctx, "DUP")
					compileExpr(field.value, ctx, true)
					emit(ctx, "SETLIST", autoIndex)
				else
					autoIndex = autoIndex + 1
					emit(ctx, "DUP")
					emit(ctx, "LOADK", k(ctx, autoIndex))
					compileExpr(field.value, ctx, false)
					emit(ctx, "SETINDEX")
				end
			end
		end
	elseif kind == "Function" then
		local protoIndex = newProto(ctx.mod, {}, node.hasVararg)
		local subCtx = newCtx(ctx.mod, protoIndex)
		local paramDescs = {}
		for i, pname in ipairs(node.params) do
			if isCaptured(subCtx, pname) then
				paramDescs[i] = { reg = false, name = pname }
			else
				paramDescs[i] = { reg = true, slot = regSlotFor(subCtx, pname) }
			end
		end
		ctx.mod.protos[protoIndex].params = paramDescs
		ctx.mod.protos[protoIndex].nparams = #node.params
		compileBlockBare(node.body, subCtx)
		emit(subCtx, "RETURN", 0, 0) -- implicit return
		emit(ctx, "CLOSURE", protoIndex)
	elseif kind == "Call" then
		compileExpr(node.fn, ctx, false)
		compileCallLike(0, node.args, ctx, wantMulti and true or false)
	elseif kind == "MethodCall" then
		compileExpr(node.obj, ctx, false)
		emit(ctx, "DUP")
		emit(ctx, "LOADK", k(ctx, node.method))
		emit(ctx, "GETINDEX")
		emit(ctx, "SWAP")
		compileCallLike(1, node.args, ctx, wantMulti and true or false)
	elseif kind == "Binop" then
		if node.op == "and" then
			compileExpr(node.lhs, ctx, false)
			local jmp = emit(ctx, "TESTANDJMP", 0)
			emit(ctx, "POP", 1)
			compileExpr(node.rhs, ctx, false)
			patchTo(ctx, jmp, here(ctx))
		elseif node.op == "or" then
			compileExpr(node.lhs, ctx, false)
			local jmp = emit(ctx, "TESTORJMP", 0)
			emit(ctx, "POP", 1)
			compileExpr(node.rhs, ctx, false)
			patchTo(ctx, jmp, here(ctx))
		else
			compileExpr(node.lhs, ctx, false)
			compileExpr(node.rhs, ctx, false)
			emit(ctx, "BINOP", node.op)
		end
	elseif kind == "Unop" then
		compileExpr(node.operand, ctx, false)
		emit(ctx, "UNOP", node.op)
	else
		error("XenonSec compiler: unknown expression kind '" .. tostring(kind) .. "'")
	end
end

--------------------------------------------------------------------
-- Statements
--------------------------------------------------------------------

local function declareTargetsReverse(names, ctx, declMode)
	-- names: array of raw name tokens (not yet const-resolved)
	for i = #names, 1, -1 do
		if declMode then
			emitDeclare(ctx, names[i])
		else
			emitSet(ctx, names[i])
		end
	end
end

local function compileAssignTargetsReverse(targets, ctx)
	for i = #targets, 1, -1 do
		local tgt = targets[i]
		if tgt.kind == "Name" then
			emitSet(ctx, tgt.name)
		else -- Index
			local tmp = tempName(ctx)
			emitTempDeclare(ctx, tmp) -- pops value V, stores as temp register
			compileExpr(tgt.obj, ctx, false)
			compileExpr(tgt.key, ctx, false)
			emitTempGet(ctx, tmp)
			emit(ctx, "SETINDEX")
		end
	end
end

function compileStat(node, ctx)
	local kind = node.kind
	if kind == "Local" then
		compileExprListExactN(node.values, #node.names, ctx)
		declareTargetsReverse(node.names, ctx, true)
	elseif kind == "LocalFunction" then
		emit(ctx, "LOADNIL")
		emitDeclare(ctx, node.name)
		compileExpr(node.func, ctx, false)
		emitSet(ctx, node.name)
	elseif kind == "Assign" then
		compileExprListExactN(node.values, #node.targets, ctx)
		compileAssignTargetsReverse(node.targets, ctx)
	elseif kind == "ExprStat" then
		compileExpr(node.expr, ctx, false)
		emit(ctx, "POP", 1)
	elseif kind == "Do" then
		compileBlockScoped(node.body, ctx)
	elseif kind == "If" then
		local endJumps = {}
		for _, clause in ipairs(node.clauses) do
			compileExpr(clause.cond, ctx, false)
			local skip = emit(ctx, "JMPIFNOT", 0)
			compileBlockScoped(clause.body, ctx)
			endJumps[#endJumps + 1] = emit(ctx, "JMP", 0)
			patchTo(ctx, skip, here(ctx))
		end
		if node.elseBody then
			compileBlockScoped(node.elseBody, ctx)
		end
		local endHere = here(ctx)
		for _, j in ipairs(endJumps) do patchTo(ctx, j, endHere) end
	elseif kind == "While" then
		local top = here(ctx)
		compileExpr(node.cond, ctx, false)
		local exit = emit(ctx, "JMPIFNOT", 0)
		ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, continues = {}, baseDepth = ctx.scopeDepth, continueBaseDepth = ctx.scopeDepth }
		compileBlockScoped(node.body, ctx)
		local continueHere = here(ctx)
		emit(ctx, "JMP", top)
		local endHere = here(ctx)
		patchTo(ctx, exit, endHere)
		local loop = table.remove(ctx.loopStack)
		for _, j in ipairs(loop.breaks) do patchTo(ctx, j, endHere) end
		for _, j in ipairs(loop.continues) do patchTo(ctx, j, continueHere) end
	elseif kind == "Repeat" then
		local top = here(ctx)
		local baseDepthForBreak = ctx.scopeDepth
		pushScope(ctx)
		-- `continue` in a repeat-loop must land right before the `until`
		-- condition (which can still see the body's own locals), NOT at
		-- the same depth `break` unwinds to (which pops this frame too).
		ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, continues = {}, baseDepth = baseDepthForBreak, continueBaseDepth = ctx.scopeDepth }
		compileBlockBare(node.body, ctx)
		local continueHere = here(ctx)
		for _, j in ipairs(ctx.loopStack[#ctx.loopStack].continues) do patchTo(ctx, j, continueHere) end
		compileExpr(node.cond, ctx, false)
		popScope(ctx)
		local backEdge = emit(ctx, "JMPIFNOT", top)
		local endHere = here(ctx)
		local loop = table.remove(ctx.loopStack)
		for _, j in ipairs(loop.breaks) do patchTo(ctx, j, endHere) end
	elseif kind == "Break" then
		if #ctx.loopStack == 0 then
			error("XenonSec compiler: 'break' used outside a loop (line " .. tostring(node.line) .. ")")
		end
		local loop = ctx.loopStack[#ctx.loopStack]
		-- Unwind any scopes opened since the loop's normal exit point so
		-- the scope-chain stays perfectly balanced no matter where the
		-- break was nested inside the body (if/do/nested loops, etc).
		for _ = 1, ctx.scopeDepth - loop.baseDepth do
			emit(ctx, "POPSCOPE")
		end
		local j = emit(ctx, "JMP", 0)
		loop.breaks[#loop.breaks + 1] = j
	elseif kind == "Continue" then
		if #ctx.loopStack == 0 then
			error("XenonSec compiler: 'continue' used outside a loop (line " .. tostring(node.line) .. ")")
		end
		local loop = ctx.loopStack[#ctx.loopStack]
		for _ = 1, ctx.scopeDepth - loop.continueBaseDepth do
			emit(ctx, "POPSCOPE")
		end
		local j = emit(ctx, "JMP", 0)
		loop.continues[#loop.continues + 1] = j
	elseif kind == "NumericFor" then
		compileNumericFor(node, ctx)
	elseif kind == "GenericFor" then
		compileGenericFor(node, ctx)
	elseif kind == "Return" then
		local fixedCount, hasTrailing = compileExprListVariadic(node.args, ctx)
		emit(ctx, "RETURN", fixedCount, hasTrailing and 1 or 0)
	else
		error("XenonSec compiler: unknown statement kind '" .. tostring(kind) .. "'")
	end
end

function compileNumericFor(node, ctx)
	-- NOTE: the loop control variable must be a *fresh* local binding on
	-- every iteration (real Lua 5.1 semantics), so that closures created
	-- inside the body each capture their own value of it. `counterT` is
	-- an internal-only counter (never visible to user code / closures,
	-- always a register); `varName` is re-declared each iteration and is
	-- what the loop body actually sees -- register if never captured,
	-- fresh scope-chain cell each pass if it is.
	local startT, limitT, stepT, counterT = tempName(ctx), tempName(ctx), tempName(ctx), tempName(ctx)
	local varName = node.var

	pushScope(ctx)
	compileExpr(node.start, ctx, false); emitTempDeclare(ctx, startT)
	compileExpr(node.limit, ctx, false); emitTempDeclare(ctx, limitT)
	if node.step then compileExpr(node.step, ctx, false) else emit(ctx, "LOADK", k(ctx, 1)) end
	emitTempDeclare(ctx, stepT)
	emitTempGet(ctx, startT)
	emitTempDeclare(ctx, counterT)

	local top = here(ctx)
	-- condition: (step > 0 and counter <= limit) or (step <= 0 and counter >= limit)
	emitTempGet(ctx, stepT); emit(ctx, "LOADK", k(ctx, 0)); emit(ctx, "BINOP", ">")
	local elseJ = emit(ctx, "JMPIFNOT", 0)
	emitTempGet(ctx, counterT); emitTempGet(ctx, limitT); emit(ctx, "BINOP", "<=")
	local doneJ = emit(ctx, "JMP", 0)
	patchTo(ctx, elseJ, here(ctx))
	emitTempGet(ctx, counterT); emitTempGet(ctx, limitT); emit(ctx, "BINOP", ">=")
	patchTo(ctx, doneJ, here(ctx))
	local exit = emit(ctx, "JMPIFNOT", 0)

	ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, continues = {}, baseDepth = ctx.scopeDepth, continueBaseDepth = ctx.scopeDepth }
	pushScope(ctx)
	emitTempGet(ctx, counterT); emitDeclare(ctx, varName)
	compileBlockBare(node.body, ctx)
	popScope(ctx)
	local continueHere = here(ctx)
	emitTempGet(ctx, counterT); emitTempGet(ctx, stepT); emit(ctx, "BINOP", "+")
	emitTempSet(ctx, counterT)
	emit(ctx, "JMP", top)

	local endHere = here(ctx)
	patchTo(ctx, exit, endHere)
	local loop = table.remove(ctx.loopStack)
	for _, j in ipairs(loop.breaks) do patchTo(ctx, j, endHere) end
	for _, j in ipairs(loop.continues) do patchTo(ctx, j, continueHere) end
	popScope(ctx)
end

function compileGenericFor(node, ctx)
	local fT, sT, cT = tempName(ctx), tempName(ctx), tempName(ctx)
	pushScope(ctx)
	compileExprListExactN(node.exprs, 3, ctx)
	emitTempDeclare(ctx, cT)
	emitTempDeclare(ctx, sT)
	emitTempDeclare(ctx, fT)

	local top = here(ctx)
	emitTempGet(ctx, fT)
	emitTempGet(ctx, sT)
	emitTempGet(ctx, cT)
	emit(ctx, "CALL", 2, 0, 1) -- fixed 2 args (s, ctrl), multi result
	emit(ctx, "ADJUSTMULTI", #node.names)
	local continueBaseDepth = ctx.scopeDepth -- before the per-iteration scope below
	pushScope(ctx)
	declareTargetsReverse(node.names, ctx, true)
	emitGet(ctx, node.names[1])
	local exit = emit(ctx, "JMPIFNIL", 0)
	emitGet(ctx, node.names[1])
	emitTempSet(ctx, cT)

	ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, continues = {}, baseDepth = ctx.scopeDepth, continueBaseDepth = continueBaseDepth }
	compileBlockBare(node.body, ctx)
	popScope(ctx)
	local continueHere = here(ctx)
	emit(ctx, "JMP", top)

	local endHere = here(ctx)
	patchTo(ctx, exit, endHere)
	popScope(ctx) -- the inner per-iteration scope on the failed-test path
	local loop = table.remove(ctx.loopStack)
	for _, j in ipairs(loop.breaks) do patchTo(ctx, j, endHere) end
	for _, j in ipairs(loop.continues) do patchTo(ctx, j, continueHere) end
	popScope(ctx) -- the outer f/s/ctrl scope
end

--------------------------------------------------------------------
-- Blocks
--------------------------------------------------------------------

function compileBlockBare(block, ctx)
	for _, stat in ipairs(block.body) do
		compileStat(stat, ctx)
	end
end

function compileBlockScoped(block, ctx)
	pushScope(ctx)
	compileBlockBare(block, ctx)
	popScope(ctx)
end

--------------------------------------------------------------------
-- Public entry point
--------------------------------------------------------------------

function Compiler.compile(ast, capturedSet)
	local mod = newModule()
	mod.capturedSet = capturedSet or {}
	local mainProto = newProto(mod, {}, true)
	local ctx = newCtx(mod, mainProto)
	compileBlockBare(ast, ctx)
	emit(ctx, "RETURN", 0, 0)
	mod.mainProto = mainProto
	return mod
end

return Compiler
