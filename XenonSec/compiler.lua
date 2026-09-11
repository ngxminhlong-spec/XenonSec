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
	mod.protos[#mod.protos + 1] = { params = params, hasVararg = hasVararg, code = {} }
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
		emit(ctx, "GETVAR", k(ctx, node.name))
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
		local protoIndex = newProto(ctx.mod, node.params, node.hasVararg)
		local subCtx = newCtx(ctx.mod, protoIndex)
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
			emit(ctx, "BINOP", k(ctx, node.op))
		end
	elseif kind == "Unop" then
		compileExpr(node.operand, ctx, false)
		emit(ctx, "UNOP", k(ctx, node.op))
	else
		error("XenonSec compiler: unknown expression kind '" .. tostring(kind) .. "'")
	end
end

--------------------------------------------------------------------
-- Statements
--------------------------------------------------------------------

local function declareTargetsReverse(names, ctx, declMode)
	-- names: array of constant-indices for identifier names (already `k()`-resolved)
	for i = #names, 1, -1 do
		if declMode then
			emit(ctx, "DECLLOCAL", names[i])
		else
			emit(ctx, "SETVAR", names[i])
		end
	end
end

local function compileAssignTargetsReverse(targets, ctx)
	for i = #targets, 1, -1 do
		local tgt = targets[i]
		if tgt.kind == "Name" then
			emit(ctx, "SETVAR", k(ctx, tgt.name))
		else -- Index
			local tmp = k(ctx, tempName(ctx))
			emit(ctx, "DECLLOCAL", tmp) -- pops value V, stores as temp local
			compileExpr(tgt.obj, ctx, false)
			compileExpr(tgt.key, ctx, false)
			emit(ctx, "GETVAR", tmp)
			emit(ctx, "SETINDEX")
		end
	end
end

function compileStat(node, ctx)
	local kind = node.kind
	if kind == "Local" then
		compileExprListExactN(node.values, #node.names, ctx)
		local nameIdx = {}
		for i, n in ipairs(node.names) do nameIdx[i] = k(ctx, n) end
		declareTargetsReverse(nameIdx, ctx, true)
	elseif kind == "LocalFunction" then
		local nameK = k(ctx, node.name)
		emit(ctx, "LOADNIL")
		emit(ctx, "DECLLOCAL", nameK)
		compileExpr(node.func, ctx, false)
		emit(ctx, "SETVAR", nameK)
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
		ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, baseDepth = ctx.scopeDepth }
		compileBlockScoped(node.body, ctx)
		emit(ctx, "JMP", top)
		local endHere = here(ctx)
		patchTo(ctx, exit, endHere)
		local loop = table.remove(ctx.loopStack)
		for _, j in ipairs(loop.breaks) do patchTo(ctx, j, endHere) end
	elseif kind == "Repeat" then
		local top = here(ctx)
		ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, baseDepth = ctx.scopeDepth }
		pushScope(ctx)
		compileBlockBare(node.body, ctx)
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
	-- inside the body each capture their own value of it. `counterK` is
	-- an internal-only counter (never visible to user code / closures);
	-- `varK` is re-declared into a brand new per-iteration scope each
	-- pass and is what the loop body actually sees and can close over.
	local startK, limitK, stepK, counterK = tempName(ctx), tempName(ctx), tempName(ctx), tempName(ctx)
	local varK = k(ctx, node.var)
	startK, limitK, stepK, counterK = k(ctx, startK), k(ctx, limitK), k(ctx, stepK), k(ctx, counterK)

	pushScope(ctx)
	compileExpr(node.start, ctx, false); emit(ctx, "DECLLOCAL", startK)
	compileExpr(node.limit, ctx, false); emit(ctx, "DECLLOCAL", limitK)
	if node.step then compileExpr(node.step, ctx, false) else emit(ctx, "LOADK", k(ctx, 1)) end
	emit(ctx, "DECLLOCAL", stepK)
	emit(ctx, "GETVAR", startK)
	emit(ctx, "DECLLOCAL", counterK)

	local top = here(ctx)
	-- condition: (step > 0 and counter <= limit) or (step <= 0 and counter >= limit)
	emit(ctx, "GETVAR", stepK); emit(ctx, "LOADK", k(ctx, 0)); emit(ctx, "BINOP", k(ctx, ">"))
	local elseJ = emit(ctx, "JMPIFNOT", 0)
	emit(ctx, "GETVAR", counterK); emit(ctx, "GETVAR", limitK); emit(ctx, "BINOP", k(ctx, "<="))
	local doneJ = emit(ctx, "JMP", 0)
	patchTo(ctx, elseJ, here(ctx))
	emit(ctx, "GETVAR", counterK); emit(ctx, "GETVAR", limitK); emit(ctx, "BINOP", k(ctx, ">="))
	patchTo(ctx, doneJ, here(ctx))
	local exit = emit(ctx, "JMPIFNOT", 0)

	ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, baseDepth = ctx.scopeDepth }
	pushScope(ctx)
	emit(ctx, "GETVAR", counterK); emit(ctx, "DECLLOCAL", varK)
	compileBlockBare(node.body, ctx)
	popScope(ctx)
	emit(ctx, "GETVAR", counterK); emit(ctx, "GETVAR", stepK); emit(ctx, "BINOP", k(ctx, "+"))
	emit(ctx, "SETVAR", counterK)
	emit(ctx, "JMP", top)

	local endHere = here(ctx)
	patchTo(ctx, exit, endHere)
	local loop = table.remove(ctx.loopStack)
	for _, j in ipairs(loop.breaks) do patchTo(ctx, j, endHere) end
	popScope(ctx)
end

function compileGenericFor(node, ctx)
	local fK, sK, cK = k(ctx, tempName(ctx)), k(ctx, tempName(ctx)), k(ctx, tempName(ctx))
	pushScope(ctx)
	compileExprListExactN(node.exprs, 3, ctx)
	emit(ctx, "DECLLOCAL", cK)
	emit(ctx, "DECLLOCAL", sK)
	emit(ctx, "DECLLOCAL", fK)

	local nameKs = {}
	for i, n in ipairs(node.names) do nameKs[i] = k(ctx, n) end

	local top = here(ctx)
	emit(ctx, "GETVAR", fK)
	emit(ctx, "GETVAR", sK)
	emit(ctx, "GETVAR", cK)
	emit(ctx, "CALL", 2, 0, 1) -- fixed 2 args (s, ctrl), multi result
	emit(ctx, "ADJUSTMULTI", #node.names)
	pushScope(ctx)
	declareTargetsReverse(nameKs, ctx, true)
	emit(ctx, "GETVAR", nameKs[1])
	local exit = emit(ctx, "JMPIFNIL", 0)
	emit(ctx, "GETVAR", nameKs[1])
	emit(ctx, "SETVAR", cK)

	ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, baseDepth = ctx.scopeDepth }
	compileBlockBare(node.body, ctx)
	popScope(ctx)
	emit(ctx, "JMP", top)

	local endHere = here(ctx)
	patchTo(ctx, exit, endHere)
	popScope(ctx) -- the inner per-iteration scope on the failed-test path
	local loop = table.remove(ctx.loopStack)
	for _, j in ipairs(loop.breaks) do patchTo(ctx, j, endHere) end
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

function Compiler.compile(ast)
	local mod = newModule()
	local mainProto = newProto(mod, {}, true)
	local ctx = newCtx(mod, mainProto)
	compileBlockBare(ast, ctx)
	emit(ctx, "RETURN", 0, 0)
	mod.mainProto = mainProto
	return mod
end

return Compiler
