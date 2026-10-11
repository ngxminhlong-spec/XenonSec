--------------------------------------------------------------------
-- XenonSec :: interpreter.lua (reference interpreter)
-- Executes register code produced by compiler.lua, with the canonical
-- (string) opcode names. It defines the semantics the obfuscated runtime
-- must reproduce; tests/difftest.lua compares the two. The shipped output
-- uses randomized numeric opcodes and encoded fields instead.
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
	["//"] = function(a, b) return math.floor(a / b) end,
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

-- Lookup for a captured local: walks the cell chain. nil means "global".
local function lookup(scope, name)
	local s = scope
	while s do
		if s.vars[name] ~= nil then return s end
		s = s.parent
	end
	return nil
end

local runProto

local function mkClosure(mod, scope, pIdx)
	return function(...)
		return runProto(mod, pIdx, pack(...), scope)
	end
end

function runProto(mod, protoIndex, callArgs, parentScope)
	local proto = mod.protos[protoIndex]
	local consts = mod.consts
	local code = proto.code

	local scope = { vars = {}, parent = parentScope }
	local regs = {}
	local nparams = proto.nparams or #proto.params
	for i = 1, nparams do
		local pdesc = proto.params[i]
		local v = callArgs[i]
		if pdesc.reg then
			regs[pdesc.slot] = v
		else
			scope.vars[pdesc.name] = (v == nil) and NILV or v
		end
	end
	local varargs = nil
	if proto.hasVararg then
		local nva = (callArgs.n or #callArgs) - nparams
		if nva < 0 then nva = 0 end
		varargs = { n = nva }
		for i = 1, nva do varargs[i] = callArgs[nparams + i] end
	end

	local top = 0
	local ip = 1
	while true do
		local ins = code[ip]
		if not ins then return end
		local op, a, b, c = ins.op, ins.a, ins.b, ins.c

		if op == "LOADK" then
			regs[a] = consts[b]; ip = ip + 1
		elseif op == "LOADNIL" then
			for i = a, a + b - 1 do regs[i] = nil end
			ip = ip + 1
		elseif op == "LOADTRUE" then
			regs[a] = true; ip = ip + 1
		elseif op == "LOADFALSE" then
			regs[a] = false; ip = ip + 1
		elseif op == "MOVE" then
			regs[a] = regs[b]; ip = ip + 1
		elseif op == "GETVAR" then
			local nm = consts[b]
			local sc = lookup(scope, nm)
			if sc then
				local v = sc.vars[nm]
				if v == NILV then regs[a] = nil else regs[a] = v end
			else
				regs[a] = _G[nm]
			end
			ip = ip + 1
		elseif op == "SETVAR" then
			local nm = consts[b]
			local v = regs[a]
			local sc = lookup(scope, nm)
			if sc then
				sc.vars[nm] = (v == nil) and NILV or v
			else
				_G[nm] = v
			end
			ip = ip + 1
		elseif op == "DECLCELL" then
			local v = regs[a]
			scope.vars[consts[b]] = (v == nil) and NILV or v
			ip = ip + 1
		elseif op == "NEWTABLE" then
			regs[a] = {}; ip = ip + 1
		elseif op == "GETIDX" then
			regs[a] = regs[b][regs[c]]; ip = ip + 1
		elseif op == "SETIDX" then
			regs[a][regs[b]] = regs[c]; ip = ip + 1
		elseif op == "GETIDXK" then
			regs[a] = regs[b][consts[c]]; ip = ip + 1
		elseif op == "SETIDXK" then
			regs[a][consts[b]] = regs[c]; ip = ip + 1
		elseif op == "SETLISTM" then
			local t = regs[a]
			local off = consts[c]
			for j = 1, top do t[off + j] = regs[b + j - 1] end
			ip = ip + 1
		elseif op == "SELF" then
			local o = regs[b]
			regs[a + 1] = o
			regs[a] = o[consts[c]]
			ip = ip + 1
		elseif op == "CLOSURE" then
			regs[a] = mkClosure(mod, scope, b); ip = ip + 1
		elseif op == "VARARG" then
			if b == 0 then
				local n = varargs and varargs.n or 0
				for j = 1, n do regs[a + j - 1] = varargs[j] end
				top = n
			else
				for j = 1, b - 1 do
					local v = nil
					if varargs then v = varargs[j] end
					regs[a + j - 1] = v
				end
			end
			ip = ip + 1
		elseif op == "CALL" then
			local fn = regs[a]
			local n = b - 1
			local args = {}
			for j = 1, n do args[j] = regs[a + j] end
			local res = pack(fn(unpack(args, 1, n)))
			if c == 0 then
				for j = 1, res.n do regs[a + j - 1] = res[j] end
				top = res.n
			else
				for j = 1, c - 1 do regs[a + j - 1] = res[j] end
			end
			ip = ip + 1
		elseif op == "CALLM" then
			local fn = regs[a]
			local fixed = b - 1
			local args = {}
			for j = 1, fixed do args[j] = regs[a + j] end
			for j = 1, top do args[fixed + j] = regs[a + fixed + j] end
			local res = pack(fn(unpack(args, 1, fixed + top)))
			if c == 0 then
				for j = 1, res.n do regs[a + j - 1] = res[j] end
				top = res.n
			else
				for j = 1, c - 1 do regs[a + j - 1] = res[j] end
			end
			ip = ip + 1
		elseif op == "RET" then
			local n = b - 1
			local vals = { n = n }
			for j = 1, n do vals[j] = regs[a + j - 1] end
			return unpack(vals, 1, vals.n)
		elseif op == "RETM" then
			local fixed = b - 1
			local vals = {}
			for j = 1, fixed do vals[j] = regs[a + j - 1] end
			for j = 1, top do vals[fixed + j] = regs[a + fixed + j - 1] end
			vals.n = fixed + top
			return unpack(vals, 1, vals.n)
		elseif op == "JMP" then
			ip = a
		elseif op == "JF" then
			if truthy(regs[a]) then ip = ip + 1 else ip = b end
		elseif op == "JT" then
			if truthy(regs[a]) then ip = b else ip = ip + 1 end
		elseif op == "JNIL" then
			if regs[a] == nil then ip = b else ip = ip + 1 end
		elseif op == "NEWSCOPE" then
			scope = { vars = {}, parent = scope }; ip = ip + 1
		elseif op == "POPSCOPE" then
			scope = scope.parent; ip = ip + 1
		elseif op == "JUNK" then
			regs[a] = consts[b]; ip = ip + 1
		else
			local bi = op:match("^BINK?(%d+)$")
			local ui = op:match("^UN(%d+)$")
			if bi then
				local sym = mod.binSymbols[tonumber(bi)]
				if op:sub(1, 4) == "BINK" then
					regs[a] = BINOPS[sym](regs[b], consts[c])
				else
					regs[a] = BINOPS[sym](regs[b], regs[c])
				end
				ip = ip + 1
			elseif ui then
				regs[a] = UNOPS[mod.unSymbols[tonumber(ui)]](regs[b])
				ip = ip + 1
			else
				error("unknown opcode " .. tostring(op))
			end
		end
	end
end

-- Operator symbol order, shared with the compiler.
local BIN_ORDER = { "+", "-", "*", "/", "%", "^", "..", "==", "~=", "<", ">", "<=", ">=", "//" }
local UN_ORDER = { "-", "not", "#" }

local function run(mod, ...)
	mod.binSymbols = BIN_ORDER
	mod.unSymbols = UN_ORDER
	return runProto(mod, mod.mainProto, pack(...), nil)
end

return { run = run }
