--------------------------------------------------------------------
-- XenonSec :: interpreter.lua (development/reference interpreter)
-- Executes the IR produced by compiler.lua directly, using canonical
-- string opcode names. Used for testing the compiler; the real
-- obfuscator (obfuscate.lua) emits a self-contained variant of this
-- same logic with randomized numeric opcodes into the output file.
--------------------------------------------------------------------

local unpack = table.unpack or unpack

local function pack(...)
	return { n = select("#", ...), ... }
end

local function truthy(v) return v ~= nil and v ~= false end

local BINOPS = {
	["+"] = function(a, b) return a + b end,
	["-"] = function(a, b) return a - b end,
	["*"] = function(a, b) return a * b end,
	["/"] = function(a, b) return a / b end,
	["%"] = function(a, b) return a % b end,
	["^"] = function(a, b) return a ^ b end,
	[".."] = function(a, b) return a .. b end,
	["=="] = function(a, b) return a == b end,
	["~="] = function(a, b) return a ~= b end,
	["<"] = function(a, b) return a < b end,
	[">"] = function(a, b) return a > b end,
	["<="] = function(a, b) return a <= b end,
	[">="] = function(a, b) return a >= b end,
}
local UNOPS = {
	["-"] = function(a) return -a end,
	["not"] = function(a) return not a end,
	["#"] = function(a) return #a end,
}

local NILV = setmetatable({}, { __tostring = function() return "<xs-nil>" end })

local function runProto(mod, protoIndex, callArgs, parentScope)
	local proto = mod.protos[protoIndex]
	local consts = mod.consts
	local code = proto.code

	local scope = { vars = {}, parent = parentScope }
	for i, pname in ipairs(proto.params) do
		local v = callArgs[i]
		scope.vars[pname] = (v == nil) and NILV or v
	end
	local varargs = nil
	if proto.hasVararg then
		local n = (callArgs.n or #callArgs) - #proto.params
		if n < 0 then n = 0 end
		local va = { n = n }
		for i = 1, n do va[i] = callArgs[#proto.params + i] end
		varargs = va
	end

	local function lookup(name)
		local s = scope
		while s do
			if s.vars[name] ~= nil then return s end
			s = s.parent
		end
		return nil
	end

	local stack, sp = {}, 0
	local function push(v) sp = sp + 1; stack[sp] = v end
	local function pop() local v = stack[sp]; stack[sp] = nil; sp = sp - 1; return v end
	local function peek() return stack[sp] end

	local function mkClosure(pIdx)
		local capturedScope = scope
		return function(...)
			return runProto(mod, pIdx, pack(...), capturedScope)
		end
	end

	local ip = 1
	while true do
		local instr = code[ip]
		if not instr then return end
		local op = instr.op

		if op == "LOADK" then
			push(consts[instr.a]); ip = ip + 1
		elseif op == "LOADNIL" then
			push(nil); ip = ip + 1
		elseif op == "LOADTRUE" then
			push(true); ip = ip + 1
		elseif op == "LOADFALSE" then
			push(false); ip = ip + 1
		elseif op == "GETVAR" then
			local name = consts[instr.a]
			local s = lookup(name)
			if s then
				local v = s.vars[name]
				if v == NILV then push(nil) else push(v) end
			else
				push(_G[name])
			end
			ip = ip + 1
		elseif op == "SETVAR" then
			local name = consts[instr.a]
			local v = pop()
			local s = lookup(name)
			if s then
				s.vars[name] = (v == nil) and NILV or v
			else
				_G[name] = v
			end
			ip = ip + 1
		elseif op == "DECLLOCAL" then
			local name = consts[instr.a]
			local v = pop()
			scope.vars[name] = (v == nil) and NILV or v
			ip = ip + 1
		elseif op == "NEWTABLE" then
			push({}); ip = ip + 1
		elseif op == "GETINDEX" then
			local key = pop(); local obj = pop()
			push(obj[key]); ip = ip + 1
		elseif op == "SETINDEX" then
			local val = pop(); local key = pop(); local obj = pop()
			obj[key] = val; ip = ip + 1
		elseif op == "SETLIST" then
			local base = instr.a
			local cnt = pop()
			local arr = {}
			for i = cnt, 1, -1 do arr[i] = pop() end
			local tbl = pop()
			for i = 1, cnt do tbl[base + i] = arr[i] end
			ip = ip + 1
		elseif op == "DUP" then
			push(peek()); ip = ip + 1
		elseif op == "SWAP" then
			local b = pop(); local a = pop(); push(b); push(a); ip = ip + 1
		elseif op == "POP" then
			for _ = 1, instr.a do pop() end
			ip = ip + 1
		elseif op == "BINOP" then
			local opname = consts[instr.a]
			local b = pop(); local a = pop()
			push(BINOPS[opname](a, b))
			ip = ip + 1
		elseif op == "UNOP" then
			local opname = consts[instr.a]
			local a = pop()
			push(UNOPS[opname](a))
			ip = ip + 1
		elseif op == "JMP" then
			ip = instr.a
		elseif op == "JMPIFNOT" then
			local v = pop()
			if truthy(v) then ip = ip + 1 else ip = instr.a end
		elseif op == "JMPIFNIL" then
			local v = pop()
			if v == nil then ip = instr.a else ip = ip + 1 end
		elseif op == "TESTANDJMP" then
			local v = peek()
			if truthy(v) then ip = ip + 1 else ip = instr.a end
		elseif op == "TESTORJMP" then
			local v = peek()
			if truthy(v) then ip = instr.a else ip = ip + 1 end
		elseif op == "CLOSURE" then
			push(mkClosure(instr.a)); ip = ip + 1
		elseif op == "NEWSCOPE" then
			scope = { vars = {}, parent = scope }; ip = ip + 1
		elseif op == "POPSCOPE" then
			scope = scope.parent; ip = ip + 1
		elseif op == "VARARGONE" then
			if varargs then push(varargs[1]) else push(nil) end
			ip = ip + 1
		elseif op == "VARARGMULTI" then
			local n = varargs and varargs.n or 0
			for i = 1, n do push(varargs[i]) end
			push(n)
			ip = ip + 1
		elseif op == "ADJUSTMULTI" then
			local n = instr.a
			local cnt = pop()
			local arr = {}
			for i = cnt, 1, -1 do arr[i] = pop() end
			for i = 1, n do
				if i <= cnt then push(arr[i]) else push(nil) end
			end
			ip = ip + 1
		elseif op == "CALL" then
			local nstatic, argKind, resultMulti = instr.a, instr.b, instr.c
			local args, nargsTotal = {}, 0
			if argKind == 1 then
				local cnt = pop()
				local trailing = {}
				for i = cnt, 1, -1 do trailing[i] = pop() end
				local fixed = {}
				for i = nstatic, 1, -1 do fixed[i] = pop() end
				for i = 1, nstatic do args[i] = fixed[i] end
				for i = 1, cnt do args[nstatic + i] = trailing[i] end
				nargsTotal = nstatic + cnt
			else
				local fixed = {}
				for i = nstatic, 1, -1 do fixed[i] = pop() end
				args = fixed
				nargsTotal = nstatic
			end
			local fn = pop()
			local results = pack(fn(unpack(args, 1, nargsTotal)))
			if resultMulti == 1 then
				for i = 1, results.n do push(results[i]) end
				push(results.n)
			else
				push(results[1])
			end
			ip = ip + 1
		elseif op == "RETURN" then
			local nstatic, argKind = instr.a, instr.b
			if argKind == 1 then
				local cnt = pop()
				local trailing = {}
				for i = cnt, 1, -1 do trailing[i] = pop() end
				local fixed = {}
				for i = nstatic, 1, -1 do fixed[i] = pop() end
				local all = {}
				for i = 1, nstatic do all[i] = fixed[i] end
				for i = 1, cnt do all[nstatic + i] = trailing[i] end
				return unpack(all, 1, nstatic + cnt)
			else
				local vals = {}
				for i = nstatic, 1, -1 do vals[i] = pop() end
				return unpack(vals, 1, nstatic)
			end
		else
			error("XenonSec VM: unknown opcode '" .. tostring(op) .. "'")
		end
	end
end

local function run(mod, ...)
	return runProto(mod, mod.mainProto, pack(...), nil)
end

return { run = run }
