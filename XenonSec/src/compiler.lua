--------------------------------------------------------------------
-- XenonSec :: compiler.lua
-- Compiles an AST (see parser.lua) into per-function register code.
--
-- Machine model
-- -------------
-- * Every running function has a register file (`regs`, 1-based) and a
--   `top` count for variable-length results. There is no value stack:
--   each instruction names the registers it reads and writes.
-- * Uncaptured locals live in fixed registers. Captured locals (ones a
--   nested closure refers to) live in scope cells, so closures capture
--   them by reference. Globals are read and written by name, after
--   walking the cell chain.
-- * Expressions compile straight into a destination register. Temporaries
--   are allocated above the current top and released at the end of each
--   statement (or block).
-- * Calls and returns with a variable number of values use the `top`
--   count: the producer sets it, the consumer (CALLM / RETM / SETLISTM)
--   reads it. Fixed-count forms need no count.
--
-- Instruction format: { op = <name>, a = <int>, b = <int>, c = <int> }.
-- Operand meanings are documented next to each emitter below.
--------------------------------------------------------------------

local Compiler = {}

-- Binary and unary operator symbols, in the order their instruction names
-- are numbered: BIN<k> / BINK<k> for BINOP_SYMBOLS[k], UN<k> for UNOP_SYMBOLS[k].
local BINOP_SYMBOLS = { "+", "-", "*", "/", "%", "^", "..", "==", "~=", "<", ">", "<=", ">=", "//" }
local UNOP_SYMBOLS = { "-", "not", "#" }
Compiler.BINOP_SYMBOLS = BINOP_SYMBOLS
Compiler.UNOP_SYMBOLS = UNOP_SYMBOLS

local BINOP_INDEX, UNOP_INDEX = {}, {}
for i, s in ipairs(BINOP_SYMBOLS) do BINOP_INDEX[s] = i end
for i, s in ipairs(UNOP_SYMBOLS) do UNOP_INDEX[s] = i end

local function newModule()
	return { consts = {}, constIndex = {}, protos = {} }
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

local function newCtx(mod, protoIndex)
	return {
		mod = mod,
		protoIndex = protoIndex,
		code = mod.protos[protoIndex].code,
		loopStack = {},
		tempCounter = 0,
		scopeDepth = 0,
		regMap = {},  -- local token -> register (uncaptured locals only)
		top = 0,      -- highest register currently allocated
		maxReg = 0,   -- highest register ever allocated in this function
	}
end

local function emit(ctx, op, a, b, c)
	local code = ctx.code
	code[#code + 1] = { op = op, a = a, b = b, c = c }
	return #code
end

local function here(ctx) return #ctx.code + 1 end

-- JMP keeps its target in `a`; the conditional jumps keep their register in
-- `a` and their target in `b`.
local function patchJump(ctx, idx, target)
	local ins = ctx.code[idx]
	if ins.op == "JMP" then ins.a = target else ins.b = target end
end

local function k(ctx, value) return addConst(ctx.mod, value) end

local function allocReg(ctx)
	ctx.top = ctx.top + 1
	if ctx.top > ctx.maxReg then ctx.maxReg = ctx.top end
	return ctx.top
end

-- Scopes exist only for captured-local cells. The depth counter keeps
-- `break` and `continue` unwinding exactly balanced.
local function pushScope(ctx)
	emit(ctx, "NEWSCOPE")
	ctx.scopeDepth = ctx.scopeDepth + 1
end

local function popScope(ctx)
	emit(ctx, "POPSCOPE")
	ctx.scopeDepth = ctx.scopeDepth - 1
end

local function isLocalToken(name)
	return type(name) == "string" and name:sub(1, 1) == "\1"
end

local function isCaptured(ctx, name)
	return ctx.mod.capturedSet ~= nil and ctx.mod.capturedSet[name] == true
end

-- True when this name is an uncaptured local held in a register.
local function inRegister(ctx, name)
	return isLocalToken(name) and not isCaptured(ctx, name) and ctx.regMap[name] ~= nil
end

local function isLiteral(node)
	return node.kind == "Number" or node.kind == "String"
end

local function isMulti(node)
	return node.kind == "Call" or node.kind == "MethodCall" or node.kind == "Vararg"
end

-- Expressions whose instruction reads all its operands before it writes its
-- destination, so they may target a live local's register directly.
local function isSafeDirect(node)
	local kind = node.kind
	if kind == "Number" or kind == "String" or kind == "Nil" or kind == "True" or kind == "False" then
		return true
	elseif kind == "Name" or kind == "Index" or kind == "Unop" or kind == "Vararg" then
		return true
	elseif kind == "Binop" then
		return node.op ~= "and" and node.op ~= "or"
	elseif kind == "Paren" then
		return isSafeDirect(node.expr)
	end
	return false
end

-- Whether a block declares a captured local directly, so it needs a scope of
-- its own at run time. Other blocks reuse the enclosing scope: renamer tokens
-- are unique, so nothing is shadowed.
local function declaresCaptured(ctx, block)
	for _, stat in ipairs(block.body) do
		if stat.kind == "LocalFunction" and isCaptured(ctx, stat.name) then return true end
		if stat.kind == "Local" then
			for _, name in ipairs(stat.names) do
				if isCaptured(ctx, name) then return true end
			end
		end
	end
	return false
end

-- Forward declarations
local compileExprTo, compileExprReg, compileMultiTo, compileExprListTo
local compileCall, compileFunction, compileStat, compileBlockBare, compileBlockScoped

--------------------------------------------------------------------
-- Expressions
--------------------------------------------------------------------

-- compileExprTo(node, ctx, dst): writes exactly one value into register dst.
function compileExprTo(node, ctx, dst)
	local kind = node.kind
	if kind == "Number" or kind == "String" then
		-- LOADK a=dst, b=constant
		emit(ctx, "LOADK", dst, k(ctx, node.value))
	elseif kind == "Nil" then
		-- LOADNIL a=first, b=count
		emit(ctx, "LOADNIL", dst, 1)
	elseif kind == "True" then
		emit(ctx, "LOADTRUE", dst)
	elseif kind == "False" then
		emit(ctx, "LOADFALSE", dst)
	elseif kind == "Vararg" then
		-- VARARG a=first, b=count+1 (one value here)
		emit(ctx, "VARARG", dst, 2)
	elseif kind == "Name" then
		if inRegister(ctx, node.name) then
			local r = ctx.regMap[node.name]
			if r ~= dst then emit(ctx, "MOVE", dst, r) end
		else
			-- GETVAR a=dst, b=name constant (cell chain, then global)
			emit(ctx, "GETVAR", dst, k(ctx, node.name))
		end
	elseif kind == "Index" then
		local obj = compileExprReg(node.obj, ctx)
		if isLiteral(node.key) then
			-- GETIDXK a=dst, b=object register, c=constant key
			emit(ctx, "GETIDXK", dst, obj, k(ctx, node.key.value))
		else
			local key = compileExprReg(node.key, ctx)
			-- GETIDX a=dst, b=object register, c=key register
			emit(ctx, "GETIDX", dst, obj, key)
		end
	elseif kind == "Paren" then
		compileExprTo(node.expr, ctx, dst)
	elseif kind == "Table" then
		-- NEWTABLE a=dst
		emit(ctx, "NEWTABLE", dst)
		local auto = 0
		local fields = node.fields
		for i, field in ipairs(fields) do
			if field.type == "keyed" then
				if isLiteral(field.key) then
					local v = compileExprReg(field.value, ctx)
					-- SETIDXK a=table, b=constant key, c=value register
					emit(ctx, "SETIDXK", dst, k(ctx, field.key.value), v)
				else
					local kr = compileExprReg(field.key, ctx)
					local v = compileExprReg(field.value, ctx)
					-- SETIDX a=table, b=key register, c=value register
					emit(ctx, "SETIDX", dst, kr, v)
				end
			elseif i == #fields and isMulti(field.value) then
				local base = allocReg(ctx)
				compileMultiTo(field.value, ctx, base, -1)
				-- SETLISTM a=table, b=first value register, c=constant offset:
				-- the j-th value of `top` is stored at key offset + j
				emit(ctx, "SETLISTM", dst, base, k(ctx, auto))
			else
				auto = auto + 1
				local v = compileExprReg(field.value, ctx)
				emit(ctx, "SETIDXK", dst, k(ctx, auto), v)
			end
		end
	elseif kind == "Function" then
		compileFunction(node, ctx, dst)
	elseif kind == "Call" or kind == "MethodCall" then
		if dst == ctx.top then
			compileCall(node, ctx, dst, 1)
			ctx.top = dst
		else
			local base = allocReg(ctx)
			compileCall(node, ctx, base, 1)
			emit(ctx, "MOVE", dst, base)
			ctx.top = base - 1
		end
	elseif kind == "Binop" then
		if node.op == "and" or node.op == "or" then
			compileExprTo(node.lhs, ctx, dst)
			-- JF/JT a=register, b=target: short-circuit on falsy (and) or truthy (or)
			local jmp = emit(ctx, node.op == "and" and "JF" or "JT", dst, 0)
			compileExprTo(node.rhs, ctx, dst)
			patchJump(ctx, jmp, here(ctx))
		else
			local idx = BINOP_INDEX[node.op]
			assert(idx, "XenonSec compiler: unknown binary operator " .. tostring(node.op))
			local l = compileExprReg(node.lhs, ctx)
			if isLiteral(node.rhs) then
				-- BINK<k> a=dst, b=lhs register, c=constant rhs
				emit(ctx, "BINK" .. idx, dst, l, k(ctx, node.rhs.value))
			else
				local r = compileExprReg(node.rhs, ctx)
				-- BIN<k> a=dst, b=lhs register, c=rhs register
				emit(ctx, "BIN" .. idx, dst, l, r)
			end
		end
	elseif kind == "Unop" then
		local idx = UNOP_INDEX[node.op]
		assert(idx, "XenonSec compiler: unknown unary operator " .. tostring(node.op))
		local s = compileExprReg(node.operand, ctx)
		-- UN<k> a=dst, b=operand register
		emit(ctx, "UN" .. idx, dst, s)
	else
		error("XenonSec compiler: unknown expression kind '" .. tostring(kind) .. "'")
	end
end

-- compileExprReg(node, ctx): returns a register holding the value. A live
-- uncaptured local is used in place; anything else goes into a new temp.
function compileExprReg(node, ctx)
	if node.kind == "Name" and inRegister(ctx, node.name) then
		return ctx.regMap[node.name]
	end
	local t = allocReg(ctx)
	compileExprTo(node, ctx, t)
	return t
end

-- compileMultiTo(node, ctx, base, nres): places the values of a multi-capable
-- expression starting at register `base`. nres = how many are wanted, or -1
-- for all (the count then lives in `top` at run time).
function compileMultiTo(node, ctx, base, nres)
	if node.kind == "Call" or node.kind == "MethodCall" then
		ctx.top = base - 1
		allocReg(ctx) -- `base` becomes the newest register
		compileCall(node, ctx, base, nres)
	elseif node.kind == "Vararg" then
		-- VARARG a=first, b=0 for all (sets top), or count+1
		emit(ctx, "VARARG", base, nres == -1 and 0 or (nres + 1))
	else
		ctx.top = base - 1
		allocReg(ctx)
		compileExprTo(node, ctx, base)
	end
end

-- compileExprListTo(exprs, ctx, base, want): evaluates `exprs` into base,
-- base+1, ... `want` is how many values the consumer needs (-1 = all).
-- Returns true when the last value is a multi tail (its count is in `top`),
-- along with the number of fixed values before it.
function compileExprListTo(exprs, ctx, base, want)
	local n = #exprs
	local size = (want >= 0) and math.max(n, want) or n
	ctx.top = base - 1
	for _ = 1, size do allocReg(ctx) end
	if n == 0 then
		if want > 0 then emit(ctx, "LOADNIL", base, want) end
		return false, 0
	end
	for i = 1, n - 1 do
		compileExprTo(exprs[i], ctx, base + i - 1)
	end
	local last = exprs[n]
	local slot = base + n - 1
	if isMulti(last) and (want == -1 or want >= n) then
		local nres = (want == -1) and -1 or (want - (n - 1))
		compileMultiTo(last, ctx, slot, nres)
		if want == -1 then return true, n - 1 end
		return false, 0
	end
	compileExprTo(last, ctx, slot)
	if want > n then
		emit(ctx, "LOADNIL", base + n, want - n)
	end
	return false, 0
end

-- compileCall(node, ctx, base, nres): base is the newest register. The
-- function value (or, for a method call, the method) goes there.
--   CALL  a=base, b=nargs+1, c=nres+1 (c=0: all results, count in top)
--   CALLM a=base, b=fixed args+1 (the rest are at top), c as above
--   SELF  a=base, b=object register, c=constant method name:
--         base = method, base+1 = object (the first argument)
function compileCall(node, ctx, base, nres)
	ctx.top = base
	local selfCount = 0
	if node.kind == "MethodCall" then
		allocReg(ctx) -- base+1 holds the object
		compileExprTo(node.obj, ctx, base + 1)
		emit(ctx, "SELF", base, base + 1, k(ctx, node.method))
		selfCount = 1
		ctx.top = base + 1
	else
		compileExprTo(node.fn, ctx, base)
		ctx.top = base
	end

	local args = node.args
	local n = #args
	local tailMulti = false
	for i = 1, n do
		local slot = base + selfCount + i
		ctx.top = slot - 1
		allocReg(ctx)
		if i == n and isMulti(args[i]) then
			compileMultiTo(args[i], ctx, slot, -1)
			tailMulti = true
		else
			compileExprTo(args[i], ctx, slot)
		end
	end

	local cField = (nres == -1) and 0 or (nres + 1)
	if tailMulti then
		local fixed = selfCount + n - 1
		emit(ctx, "CALLM", base, fixed + 1, cField)
	else
		emit(ctx, "CALL", base, selfCount + n + 1, cField)
	end
	if nres == -1 then
		ctx.top = base
	else
		ctx.top = base + math.max(nres, 1) - 1
	end
end

-- compileFunction(node, ctx, dst): a new proto, then CLOSURE dst, proto.
function compileFunction(node, ctx, dst)
	local protoIndex = newProto(ctx.mod, {}, node.hasVararg)
	local sub = newCtx(ctx.mod, protoIndex)
	local paramDescs = {}
	for i, pname in ipairs(node.params) do
		if isCaptured(sub, pname) then
			paramDescs[i] = { reg = false, name = pname }
		else
			local r = allocReg(sub)
			sub.regMap[pname] = r
			paramDescs[i] = { reg = true, slot = r }
		end
	end
	ctx.mod.protos[protoIndex].params = paramDescs
	ctx.mod.protos[protoIndex].nparams = #node.params
	compileBlockBare(node.body, sub)
	-- RET a=first, b=count+1: return nothing (falling off the end does this too)
	emit(sub, "RET", 1, 1)
	ctx.mod.protos[protoIndex].nregs = sub.maxReg
	emit(ctx, "CLOSURE", dst, protoIndex)
end

--------------------------------------------------------------------
-- Statements
--------------------------------------------------------------------

-- Stores the value in register `src` into an assignment target.
local function storeTo(tgt, ctx, src)
	if tgt.kind == "Name" then
		if inRegister(ctx, tgt.name) then
			emit(ctx, "MOVE", ctx.regMap[tgt.name], src)
		else
			-- SETVAR a=source register, b=name constant
			emit(ctx, "SETVAR", src, k(ctx, tgt.name))
		end
	else
		local obj = compileExprReg(tgt.obj, ctx)
		if isLiteral(tgt.key) then
			emit(ctx, "SETIDXK", obj, k(ctx, tgt.key.value), src)
		else
			local key = compileExprReg(tgt.key, ctx)
			emit(ctx, "SETIDX", obj, key, src)
		end
	end
end

function compileStat(node, ctx)
	local kind = node.kind
	local mark = ctx.top
	local keepTop = false

	if kind == "Local" then
		keepTop = true
		local base = ctx.top + 1
		compileExprListTo(node.values, ctx, base, #node.names)
		for i, name in ipairs(node.names) do
			if isCaptured(ctx, name) then
				-- DECLCELL a=source register, b=name constant
				emit(ctx, "DECLCELL", base + i - 1, k(ctx, name))
			else
				ctx.regMap[name] = base + i - 1
			end
		end
	elseif kind == "LocalFunction" then
		keepTop = true
		if isCaptured(ctx, node.name) then
			-- The cell must exist before the closure is made, so the function can see itself.
			local r = allocReg(ctx)
			emit(ctx, "LOADNIL", r, 1)
			emit(ctx, "DECLCELL", r, k(ctx, node.name))
			compileFunction(node.func, ctx, r)
			emit(ctx, "SETVAR", r, k(ctx, node.name))
		else
			local r = allocReg(ctx)
			ctx.regMap[node.name] = r
			compileFunction(node.func, ctx, r)
		end
	elseif kind == "Assign" then
		local single = #node.targets == 1 and #node.values == 1
		local tgt = single and node.targets[1]
		if single and tgt.kind == "Name" and inRegister(ctx, tgt.name) and isSafeDirect(node.values[1]) then
			compileExprTo(node.values[1], ctx, ctx.regMap[tgt.name])
		else
			local n = #node.targets
			local base = ctx.top + 1
			compileExprListTo(node.values, ctx, base, n)
			-- Targets are assigned right to left, as before.
			for i = n, 1, -1 do
				storeTo(node.targets[i], ctx, base + i - 1)
			end
		end
	elseif kind == "ExprStat" then
		local base = ctx.top + 1
		ctx.top = base - 1
		allocReg(ctx)
		compileMultiTo(node.expr, ctx, base, 0)
	elseif kind == "Do" then
		compileBlockScoped(node.body, ctx)
	elseif kind == "If" then
		local endJumps = {}
		for _, clause in ipairs(node.clauses) do
			local m = ctx.top
			local c = compileExprReg(clause.cond, ctx)
			local skip = emit(ctx, "JF", c, 0)
			ctx.top = m
			compileBlockScoped(clause.body, ctx)
			endJumps[#endJumps + 1] = emit(ctx, "JMP", 0)
			patchJump(ctx, skip, here(ctx))
		end
		if node.elseBody then
			compileBlockScoped(node.elseBody, ctx)
		end
		local endHere = here(ctx)
		for _, j in ipairs(endJumps) do patchJump(ctx, j, endHere) end
	elseif kind == "While" then
		local top = here(ctx)
		local m = ctx.top
		local c = compileExprReg(node.cond, ctx)
		local exit = emit(ctx, "JF", c, 0)
		ctx.top = m
		ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, continues = {}, baseDepth = ctx.scopeDepth, continueBaseDepth = ctx.scopeDepth }
		compileBlockScoped(node.body, ctx)
		local continueHere = here(ctx)
		emit(ctx, "JMP", top)
		local endHere = here(ctx)
		patchJump(ctx, exit, endHere)
		local loop = table.remove(ctx.loopStack)
		for _, j in ipairs(loop.breaks) do patchJump(ctx, j, endHere) end
		for _, j in ipairs(loop.continues) do patchJump(ctx, j, continueHere) end
	elseif kind == "Repeat" then
		local top = here(ctx)
		local baseDepthForBreak = ctx.scopeDepth
		-- The until-test can see the body's locals, so the body's scope (when it
		-- has one) stays open through the test.
		local scoped = declaresCaptured(ctx, node.body)
		if scoped then pushScope(ctx) end
		ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, continues = {}, baseDepth = baseDepthForBreak, continueBaseDepth = ctx.scopeDepth }
		compileBlockBare(node.body, ctx)
		local continueHere = here(ctx)
		for _, j in ipairs(ctx.loopStack[#ctx.loopStack].continues) do patchJump(ctx, j, continueHere) end
		local c = compileExprReg(node.cond, ctx)
		if scoped then popScope(ctx) end
		-- JF a=condition register, b=back-edge target
		emit(ctx, "JF", c, top)
		local endHere = here(ctx)
		local loop = table.remove(ctx.loopStack)
		for _, j in ipairs(loop.breaks) do patchJump(ctx, j, endHere) end
	elseif kind == "Break" then
		if #ctx.loopStack == 0 then
			error("XenonSec compiler: 'break' used outside a loop (line " .. tostring(node.line) .. ")")
		end
		local loop = ctx.loopStack[#ctx.loopStack]
		for _ = 1, ctx.scopeDepth - loop.baseDepth do emit(ctx, "POPSCOPE") end
		local j = emit(ctx, "JMP", 0)
		loop.breaks[#loop.breaks + 1] = j
	elseif kind == "Continue" then
		if #ctx.loopStack == 0 then
			error("XenonSec compiler: 'continue' used outside a loop (line " .. tostring(node.line) .. ")")
		end
		local loop = ctx.loopStack[#ctx.loopStack]
		for _ = 1, ctx.scopeDepth - loop.continueBaseDepth do emit(ctx, "POPSCOPE") end
		local j = emit(ctx, "JMP", 0)
		loop.continues[#loop.continues + 1] = j
	elseif kind == "NumericFor" then
		-- The hidden state (start, limit, step, counter) lives in registers for
		-- the whole loop. The loop variable is a fresh binding each iteration,
		-- and a fresh cell when a closure captures it.
		local startR = allocReg(ctx)
		compileExprTo(node.start, ctx, startR)
		local limitR = allocReg(ctx)
		compileExprTo(node.limit, ctx, limitR)
		local stepR = allocReg(ctx)
		if node.step then
			compileExprTo(node.step, ctx, stepR)
		else
			emit(ctx, "LOADK", stepR, k(ctx, 1))
		end
		local counterR = allocReg(ctx)
		emit(ctx, "MOVE", counterR, startR)
		local condR = allocReg(ctx)

		local top = here(ctx)
		-- (step > 0 and counter <= limit) or (step <= 0 and counter >= limit)
		emit(ctx, "BINK" .. BINOP_INDEX[">"], condR, stepR, k(ctx, 0))
		local elseJ = emit(ctx, "JF", condR, 0)
		emit(ctx, "BIN" .. BINOP_INDEX["<="], condR, counterR, limitR)
		local doneJ = emit(ctx, "JMP", 0)
		patchJump(ctx, elseJ, here(ctx))
		emit(ctx, "BIN" .. BINOP_INDEX[">="], condR, counterR, limitR)
		patchJump(ctx, doneJ, here(ctx))
		local exit = emit(ctx, "JF", condR, 0)

		ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, continues = {}, baseDepth = ctx.scopeDepth, continueBaseDepth = ctx.scopeDepth }
		local scoped = isCaptured(ctx, node.var) or declaresCaptured(ctx, node.body)
		if scoped then pushScope(ctx) end
		if isCaptured(ctx, node.var) then
			emit(ctx, "DECLCELL", counterR, k(ctx, node.var))
		else
			local v = allocReg(ctx)
			emit(ctx, "MOVE", v, counterR)
			ctx.regMap[node.var] = v
		end
		compileBlockBare(node.body, ctx)
		if scoped then popScope(ctx) end
		local continueHere = here(ctx)
		emit(ctx, "BIN" .. BINOP_INDEX["+"], counterR, counterR, stepR)
		emit(ctx, "JMP", top)

		local endHere = here(ctx)
		patchJump(ctx, exit, endHere)
		local loop = table.remove(ctx.loopStack)
		for _, j in ipairs(loop.breaks) do patchJump(ctx, j, endHere) end
		for _, j in ipairs(loop.continues) do patchJump(ctx, j, continueHere) end
	elseif kind == "GenericFor" then
		local nNames = #node.names
		-- The iterator function, state, and control value stay in registers.
		local tb = ctx.top + 1
		compileExprListTo(node.exprs, ctx, tb, 3)
		local fR, sR, cR = allocReg(ctx), allocReg(ctx), allocReg(ctx)
		emit(ctx, "MOVE", fR, tb)
		emit(ctx, "MOVE", sR, tb + 1)
		emit(ctx, "MOVE", cR, tb + 2)
		-- The call block: the loop variables' registers, reused every iteration.
		local nb = ctx.top + 1
		for _ = 1, math.max(3, nNames) do allocReg(ctx) end

		local top = here(ctx)
		emit(ctx, "MOVE", nb, fR)
		emit(ctx, "MOVE", nb + 1, sR)
		emit(ctx, "MOVE", nb + 2, cR)
		-- CALL a=nb, b=2 args+1, c=names+1
		emit(ctx, "CALL", nb, 3, nNames + 1)
		local exit = emit(ctx, "JNIL", nb, 0)
		emit(ctx, "MOVE", cR, nb)

		ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, continues = {}, baseDepth = ctx.scopeDepth, continueBaseDepth = ctx.scopeDepth }
		local scoped = declaresCaptured(ctx, node.body)
		for _, name in ipairs(node.names) do
			if isCaptured(ctx, name) then scoped = true end
		end
		if scoped then pushScope(ctx) end
		for i, name in ipairs(node.names) do
			if isCaptured(ctx, name) then
				emit(ctx, "DECLCELL", nb + i - 1, k(ctx, name))
			else
				ctx.regMap[name] = nb + i - 1
			end
		end
		compileBlockBare(node.body, ctx)
		if scoped then popScope(ctx) end
		local continueHere = here(ctx)
		emit(ctx, "JMP", top)

		local endHere = here(ctx)
		patchJump(ctx, exit, endHere)
		local loop = table.remove(ctx.loopStack)
		for _, j in ipairs(loop.breaks) do patchJump(ctx, j, endHere) end
		for _, j in ipairs(loop.continues) do patchJump(ctx, j, continueHere) end
	elseif kind == "Return" then
		local n = #node.args
		local base = ctx.top + 1
		local multi, fixed = compileExprListTo(node.args, ctx, base, -1)
		if multi then
			-- RETM a=first, b=fixed+1 (the rest are at top)
			emit(ctx, "RETM", base, fixed + 1)
		else
			-- RET a=first, b=count+1
			emit(ctx, "RET", base, n + 1)
		end
	else
		error("XenonSec compiler: unknown statement kind '" .. tostring(kind) .. "'")
	end

	if not keepTop then
		ctx.top = mark
	end
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
	local mark = ctx.top
	local scoped = declaresCaptured(ctx, block)
	if scoped then pushScope(ctx) end
	compileBlockBare(block, ctx)
	if scoped then popScope(ctx) end
	ctx.top = mark
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
	emit(ctx, "RET", 1, 1)
	mod.protos[mainProto].nregs = ctx.maxReg
	mod.mainProto = mainProto
	return mod
end

return Compiler
