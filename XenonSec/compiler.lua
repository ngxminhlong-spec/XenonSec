--------------------------------------------------------------------
-- XenonSec :: compiler.lua (Hardened & Patched Version)
-- Fixes: Multi-assign stack inversion, GenericFor var order & scope leak,
--        Repeat-until scope unrolling, Vararg/Multi-return stack alignment.
-- Security: Dynamic instruction mangling & Random Key Generation.
--------------------------------------------------------------------

local Compiler = {}

local function getRandomByteString(len)
	local t = {}
	for i = 1, len or 8 do
		t[i] = string.char(math.random(1, 255))
	end
	return table.concat(t)
end

local function newModule()
	return {
		consts = {},           -- Array of literal constants
		constIndex = {},       -- Value -> index memoization
		protos = {},           -- Array of function prototypes
		mangledMap = {},       -- Obfuscated name mapping
	}
end

-- Mã hóa tên hằng số / tên biến trước khi ghi vào Const Table
local function addConst(mod, value)
	local key = type(value) .. ":" .. tostring(value)
	local existing = mod.constIndex[key]
	if existing then return existing end

	local finalVal = value
	if type(value) == "string" and value:sub(1, 1) == "\1" then
		-- Tên biến local đã rename: Biến thành chuỗi rác ngẫu nhiên
		if not mod.mangledMap[value] then
			mod.mangledMap[value] = "\1xs_" .. getRandomByteString(12)
		end
		finalVal = mod.mangledMap[value]
	end

	mod.consts[#mod.consts + 1] = finalVal
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
		regMap = {},
		nextReg = 0,
	}
end

local function emit(ctx, op, a, b, c)
	local code = ctx.code
	code[#code + 1] = { op = op, a = a, b = b, c = c }
	return #code
end

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
	return "\1__temp_" .. ctx.tempCounter .. "_" .. getRandomByteString(6)
end

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

local function emitGet(ctx, name)
	if isLocalToken(name) and not isCaptured(ctx, name) then
		emit(ctx, "GETREG", regSlotFor(ctx, name))
	else
		emit(ctx, "GETVAR", k(ctx, name))
	end
end

local function emitSet(ctx, name)
	if isLocalToken(name) and not isCaptured(ctx, name) then
		emit(ctx, "SETREG", regSlotFor(ctx, name))
	else
		emit(ctx, "SETVAR", k(ctx, name))
	end
end

local function emitDeclare(ctx, name)
	if isCaptured(ctx, name) then
		emit(ctx, "DECLLOCAL", k(ctx, name))
	else
		emit(ctx, "SETREG", regSlotFor(ctx, name))
	end
end

local function emitTempDeclare(ctx, name) emit(ctx, "SETREG", regSlotFor(ctx, name)) end
local function emitTempGet(ctx, name) emit(ctx, "GETREG", regSlotFor(ctx, name)) end
local function emitTempSet(ctx, name) emit(ctx, "SETREG", regSlotFor(ctx, name)) end

--------------------------------------------------------------------
-- Forward Declarations
--------------------------------------------------------------------
local compileExpr, compileStat, compileBlockScoped, compileBlockBare
local compileExprListExactN, compileExprListVariadic, compileCallLike
local compileNumericFor, compileGenericFor

local function isMultiCapable(node)
	return node.kind == "Call" or node.kind == "MethodCall" or node.kind == "Vararg"
end

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

function compileCallLike(prefixCount, argExprs, ctx, resultMulti)
	local fixedFromArgs, hasTrailing = compileExprListVariadic(argExprs, ctx)
	local nargsStatic = prefixCount + fixedFromArgs
	emit(ctx, "CALL", nargsStatic, hasTrailing and 1 or 0, resultMulti and 1 or 0)
end

function compileExpr(node, ctx, wantMulti)
	local kind = node.kind
	if kind == "Number" or kind == "String" then
		emit(ctx, "LOADK", k(ctx, node.value))
	elseif kind == "Nil" then
		emit(ctx, "LOADNIL")
	elseif kind == "True" then
		emit(ctx, "LOADTRUE")
	elseif kind == "False" then
		emit(ctx, "LOADFALSE")
	elseif kind == "Vararg" then
		emit(ctx, wantMulti and "VARARGMULTI" or "VARARGONE")
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
				-- Captured params live on the scope chain under the SAME
				-- constant-pool name the body's GETVAR/SETVAR reference, so
				-- resolve the pool entry here (addConst applies the name
				-- mangling) instead of keeping the raw renamed token, which
				-- would never match the mangled pool string at runtime.
				local ci = k(ctx, pname)
				paramDescs[i] = { reg = false, name = ctx.mod.consts[ci], ci = ci }
			else
				paramDescs[i] = { reg = true, slot = regSlotFor(subCtx, pname) }
			end
		end
		ctx.mod.protos[protoIndex].params = paramDescs
		ctx.mod.protos[protoIndex].nparams = #node.params
		compileBlockBare(node.body, subCtx)
		emit(subCtx, "RETURN", 0, 0)
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
-- FIX LOGIC GÁN ĐA BIẾN (ASSIGNMENT FIX)
--------------------------------------------------------------------
local function compileAssignTargets(targets, ctx, declMode)
	-- Dùng Register tạm để buffer các giá trị từ Stack trước khi gán
	-- Tránh lỗi đảo giá trị khi gán a, b = b, a
	local temps = {}
	for i = #targets, 1, -1 do
		local tReg = tempName(ctx)
		emitTempDeclare(ctx, tReg)
		temps[i] = tReg
	end

	for i = 1, #targets do
		local tgt = targets[i]
		emitTempGet(ctx, temps[i])
		if declMode then
			emitDeclare(ctx, tgt)
		else
			if type(tgt) == "string" or tgt.kind == "Name" then
				local name = type(tgt) == "string" and tgt or tgt.name
				emitSet(ctx, name)
			else -- Index target
				compileExpr(tgt.obj, ctx, false)
				compileExpr(tgt.key, ctx, false)
				emitTempGet(ctx, temps[i])
				emit(ctx, "SETINDEX")
			end
		end
	end
end

function compileStat(node, ctx)
	local kind = node.kind
	if kind == "Local" then
		compileExprListExactN(node.values, #node.names, ctx)
		compileAssignTargets(node.names, ctx, true)
	elseif kind == "LocalFunction" then
		emit(ctx, "LOADNIL")
		emitDeclare(ctx, node.name)
		compileExpr(node.func, ctx, false)
		emitSet(ctx, node.name)
	elseif kind == "Assign" then
		compileExprListExactN(node.values, #node.targets, ctx)
		compileAssignTargets(node.targets, ctx, false)
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
		ctx.loopStack[#ctx.loopStack + 1] = { breaks = {}, continues = {}, baseDepth = baseDepthForBreak, continueBaseDepth = ctx.scopeDepth }
		compileBlockBare(node.body, ctx)
		local continueHere = here(ctx)
		compileExpr(node.cond, ctx, false)
		popScope(ctx)
		emit(ctx, "JMPIFNOT", top)
		local endHere = here(ctx)
		local loop = table.remove(ctx.loopStack)
		for _, j in ipairs(loop.breaks) do patchTo(ctx, j, endHere) end
		for _, j in ipairs(loop.continues) do patchTo(ctx, j, continueHere) end
	elseif kind == "Break" or kind == "Continue" then
		if #ctx.loopStack == 0 then error("XenonSec: break/continue outside loop") end
		local loop = ctx.loopStack[#ctx.loopStack]
		local targetDepth = (kind == "Break") and loop.baseDepth or loop.continueBaseDepth
		for _ = 1, ctx.scopeDepth - targetDepth do
			emit(ctx, "POPSCOPE")
		end
		local j = emit(ctx, "JMP", 0)
		if kind == "Break" then
			loop.breaks[#loop.breaks + 1] = j
		else
			loop.continues[#loop.continues + 1] = j
		end
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

--------------------------------------------------------------------
-- FIX LOGIC GENERIC FOR (SWAP VARIABLES & SCOPE CLEANUP)
--------------------------------------------------------------------
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
	emit(ctx, "CALL", 2, 0, 1)
	emit(ctx, "ADJUSTMULTI", #node.names)
	
	local continueBaseDepth = ctx.scopeDepth
	pushScope(ctx)
	
	-- FIX: Gán đúng thứ tự các biến iterator trả về
	compileAssignTargets(node.names, ctx, true)
	
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
	popScope(ctx) -- FIX: Cleanup scope nếu JMPIFNIL nhảy thoát
	
	local loop = table.remove(ctx.loopStack)
	for _, j in ipairs(loop.breaks) do patchTo(ctx, j, endHere) end
	for _, j in ipairs(loop.continues) do patchTo(ctx, j, continueHere) end
	popScope(ctx)
end

function compileBlockBare(block, ctx)
	for _, stat in ipairs(block.body) do compileStat(stat, ctx) end
end

function compileBlockScoped(block, ctx)
	pushScope(ctx)
	compileBlockBare(block, ctx)
	popScope(ctx)
end

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
