--------------------------------------------------------------------
-- XenonSec :: parser.lua
-- Recursive-descent parser: tokens -> AST
--------------------------------------------------------------------

local Lexer = dofile((debug.getinfo(1, "S").source:match("@?(.*/)") or "") .. "lexer.lua")

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens, chunkname)
	local self = setmetatable({}, Parser)
	self.toks = tokens
	self.pos = 1
	self.chunkname = chunkname or "?"
	return self
end

function Parser:cur() return self.toks[self.pos] end
function Parser:lookahead(o) return self.toks[self.pos + o] end

function Parser:error(msg)
	local t = self:cur()
	error(string.format("XenonSec parse error (%s:%d): %s (got %s '%s')",
		self.chunkname, t and t.line or -1, msg,
		t and t.type or "?", t and tostring(t.value) or "?"), 0)
end

function Parser:advance()
	local t = self:cur()
	self.pos = self.pos + 1
	return t
end

function Parser:isKw(kw)
	local t = self:cur()
	return t.type == "keyword" and t.value == kw
end

function Parser:isSym(s)
	local t = self:cur()
	return t.type == "symbol" and t.value == s
end

function Parser:checkKw(kw)
	if not self:isKw(kw) then self:error("expected keyword '" .. kw .. "'") end
	return self:advance()
end

function Parser:checkSym(s)
	if not self:isSym(s) then self:error("expected '" .. s .. "'") end
	return self:advance()
end

function Parser:checkName()
	local t = self:cur()
	if t.type ~= "name" then self:error("expected identifier") end
	return self:advance().value
end

--------------------------------------------------------------------
-- Blocks / statements
--------------------------------------------------------------------

local BLOCK_END = {
	["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true,
}

function Parser:parseChunk()
	local block = self:parseBlock()
	if self:cur().type ~= "eof" then
		self:error("unexpected token at top level")
	end
	return block
end

function Parser:blockFollow()
	local t = self:cur()
	if t.type == "eof" then return true end
	if t.type == "keyword" and BLOCK_END[t.value] then return true end
	return false
end

function Parser:parseBlock()
	local stmts = {}
	while not self:blockFollow() do
		if self:isKw("return") then
			stmts[#stmts + 1] = self:parseReturn()
			break
		end
		local s = self:parseStatement()
		if s then stmts[#stmts + 1] = s end
	end
	return { kind = "Block", body = stmts }
end

function Parser:parseReturn()
	local line = self:cur().line
	self:checkKw("return")
	local exprs = {}
	if not self:blockFollow() and not self:isSym(";") then
		exprs = self:parseExprList()
	end
	if self:isSym(";") then self:advance() end
	return { kind = "Return", args = exprs, line = line }
end

function Parser:parseStatement()
	local t = self:cur()
	if self:isSym(";") then
		self:advance()
		return nil
	elseif self:isKw("if") then
		return self:parseIf()
	elseif self:isKw("while") then
		return self:parseWhile()
	elseif self:isKw("do") then
		self:advance()
		local body = self:parseBlock()
		self:checkKw("end")
		return { kind = "Do", body = body }
	elseif self:isKw("for") then
		return self:parseFor()
	elseif self:isKw("repeat") then
		return self:parseRepeat()
	elseif self:isKw("function") then
		return self:parseFunctionStat()
	elseif self:isKw("local") then
		return self:parseLocal()
	elseif self:isKw("break") then
		self:advance()
		return { kind = "Break", line = t.line }
	else
		return self:parseExprStat()
	end
end

function Parser:parseIf()
	local line = self:cur().line
	self:checkKw("if")
	local clauses = {}
	local cond = self:parseExpr()
	self:checkKw("then")
	local body = self:parseBlock()
	clauses[#clauses + 1] = { cond = cond, body = body }
	while self:isKw("elseif") do
		self:advance()
		local c = self:parseExpr()
		self:checkKw("then")
		local b = self:parseBlock()
		clauses[#clauses + 1] = { cond = c, body = b }
	end
	local elseBody = nil
	if self:isKw("else") then
		self:advance()
		elseBody = self:parseBlock()
	end
	self:checkKw("end")
	return { kind = "If", clauses = clauses, elseBody = elseBody, line = line }
end

function Parser:parseWhile()
	local line = self:cur().line
	self:checkKw("while")
	local cond = self:parseExpr()
	self:checkKw("do")
	local body = self:parseBlock()
	self:checkKw("end")
	return { kind = "While", cond = cond, body = body, line = line }
end

function Parser:parseRepeat()
	local line = self:cur().line
	self:checkKw("repeat")
	local body = self:parseBlock()
	self:checkKw("until")
	local cond = self:parseExpr()
	return { kind = "Repeat", cond = cond, body = body, line = line }
end

function Parser:parseFor()
	local line = self:cur().line
	self:checkKw("for")
	local firstName = self:checkName()
	if self:isSym("=") then
		self:advance()
		local start = self:parseExpr()
		self:checkSym(",")
		local limit = self:parseExpr()
		local step = nil
		if self:isSym(",") then
			self:advance()
			step = self:parseExpr()
		end
		self:checkKw("do")
		local body = self:parseBlock()
		self:checkKw("end")
		return { kind = "NumericFor", var = firstName, start = start, limit = limit, step = step, body = body, line = line }
	else
		local names = { firstName }
		while self:isSym(",") do
			self:advance()
			names[#names + 1] = self:checkName()
		end
		self:checkKw("in")
		local exprs = self:parseExprList()
		self:checkKw("do")
		local body = self:parseBlock()
		self:checkKw("end")
		return { kind = "GenericFor", names = names, exprs = exprs, body = body, line = line }
	end
end

function Parser:parseFunctionStat()
	local line = self:cur().line
	self:checkKw("function")
	-- funcname ::= Name {'.' Name} [':' Name]
	local base = { kind = "Name", name = self:checkName(), line = line }
	local isMethod = false
	while self:isSym(".") or self:isSym(":") do
		local isColon = self:isSym(":")
		self:advance()
		local key = self:checkName()
		base = { kind = "Index", obj = base, key = { kind = "String", value = key }, line = line }
		if isColon then isMethod = true; break end
	end
	local func = self:parseFunctionBody(isMethod, line)
	return { kind = "Assign", targets = { base }, values = { func }, line = line }
end

function Parser:parseLocal()
	local line = self:cur().line
	self:checkKw("local")
	if self:isKw("function") then
		self:advance()
		local name = self:checkName()
		local func = self:parseFunctionBody(false, line)
		return { kind = "LocalFunction", name = name, func = func, line = line }
	end
	local names = { self:checkName() }
	if self:isSym("<") then -- ignore Lua 5.4 attribs defensively; not in 5.1 but harmless
		self:advance(); self:checkName(); self:checkSym(">")
	end
	while self:isSym(",") do
		self:advance()
		names[#names + 1] = self:checkName()
		if self:isSym("<") then
			self:advance(); self:checkName(); self:checkSym(">")
		end
	end
	local values = {}
	if self:isSym("=") then
		self:advance()
		values = self:parseExprList()
	end
	return { kind = "Local", names = names, values = values, line = line }
end

function Parser:parseExprStat()
	local line = self:cur().line
	local expr = self:parseSuffixedExpr()
	if self:isSym("=") or self:isSym(",") then
		local targets = { expr }
		while self:isSym(",") do
			self:advance()
			targets[#targets + 1] = self:parseSuffixedExpr()
		end
		self:checkSym("=")
		local values = self:parseExprList()
		for _, tgt in ipairs(targets) do
			if tgt.kind ~= "Name" and tgt.kind ~= "Index" then
				self:error("cannot assign to this expression")
			end
		end
		return { kind = "Assign", targets = targets, values = values, line = line }
	end
	if expr.kind ~= "Call" and expr.kind ~= "MethodCall" then
		self:error("syntax error: expression statement must be a function call")
	end
	return { kind = "ExprStat", expr = expr, line = line }
end

--------------------------------------------------------------------
-- Expressions (precedence climbing)
--------------------------------------------------------------------

function Parser:parseExprList()
	local list = { self:parseExpr() }
	while self:isSym(",") do
		self:advance()
		list[#list + 1] = self:parseExpr()
	end
	return list
end

-- binary operator priority: {left, right}
local BINPRI = {
	["or"] = {1,1}, ["and"] = {2,2},
	["<"]={3,3}, [">"]={3,3}, ["<="]={3,3}, [">="]={3,3}, ["~="]={3,3}, ["=="]={3,3},
	[".."]={5,4}, -- right assoc
	["+"]={6,6}, ["-"]={6,6},
	["*"]={7,7}, ["/"]={7,7}, ["%"]={7,7},
	["^"]={10,9}, -- right assoc
}
local UNARY_PRI = 8

local function tokBinOp(t)
	if t.type == "symbol" and BINPRI[t.value] then return t.value end
	if t.type == "keyword" and (t.value == "and" or t.value == "or") then return t.value end
	return nil
end

function Parser:parseExpr(limit)
	limit = limit or 0
	local line = self:cur().line
	local left
	if self:isKw("not") or self:isSym("-") or self:isSym("#") then
		local op = self:advance().value
		local operand = self:parseExpr(UNARY_PRI)
		left = { kind = "Unop", op = op, operand = operand, line = line }
	else
		left = self:parseSimpleExpr()
	end
	while true do
		local t = self:cur()
		local op = tokBinOp(t)
		if not op or BINPRI[op][1] <= limit then break end
		self:advance()
		local right = self:parseExpr(BINPRI[op][2])
		left = { kind = "Binop", op = op, lhs = left, rhs = right, line = t.line }
	end
	return left
end

function Parser:parseSimpleExpr()
	local t = self:cur()
	if t.type == "number" then
		self:advance(); return { kind = "Number", value = t.value, line = t.line }
	elseif t.type == "string" then
		self:advance(); return { kind = "String", value = t.value, line = t.line }
	elseif t.type == "keyword" and t.value == "nil" then
		self:advance(); return { kind = "Nil", line = t.line }
	elseif t.type == "keyword" and t.value == "true" then
		self:advance(); return { kind = "True", line = t.line }
	elseif t.type == "keyword" and t.value == "false" then
		self:advance(); return { kind = "False", line = t.line }
	elseif t.type == "symbol" and t.value == "..." then
		self:advance(); return { kind = "Vararg", line = t.line }
	elseif t.type == "symbol" and t.value == "{" then
		return self:parseTableConstructor()
	elseif t.type == "keyword" and t.value == "function" then
		self:advance()
		return self:parseFunctionBody(false, t.line)
	else
		return self:parseSuffixedExpr()
	end
end

function Parser:parsePrimaryExpr()
	local t = self:cur()
	if t.type == "symbol" and t.value == "(" then
		self:advance()
		local e = self:parseExpr()
		self:checkSym(")")
		return { kind = "Paren", expr = e, line = t.line }
	elseif t.type == "name" then
		self:advance()
		return { kind = "Name", name = t.value, line = t.line }
	else
		self:error("unexpected symbol")
	end
end

function Parser:parseArgs()
	local t = self:cur()
	if t.type == "symbol" and t.value == "(" then
		self:advance()
		local args = {}
		if not self:isSym(")") then args = self:parseExprList() end
		self:checkSym(")")
		return args
	elseif t.type == "string" then
		self:advance()
		return { { kind = "String", value = t.value, line = t.line } }
	elseif t.type == "symbol" and t.value == "{" then
		return { self:parseTableConstructor() }
	else
		self:error("function arguments expected")
	end
end

function Parser:parseSuffixedExpr()
	local expr = self:parsePrimaryExpr()
	while true do
		local t = self:cur()
		if t.type == "symbol" and t.value == "." then
			self:advance()
			local key = self:checkName()
			expr = { kind = "Index", obj = expr, key = { kind = "String", value = key }, line = t.line }
		elseif t.type == "symbol" and t.value == "[" then
			self:advance()
			local key = self:parseExpr()
			self:checkSym("]")
			expr = { kind = "Index", obj = expr, key = key, line = t.line }
		elseif t.type == "symbol" and t.value == ":" then
			self:advance()
			local method = self:checkName()
			local args = self:parseArgs()
			expr = { kind = "MethodCall", obj = expr, method = method, args = args, line = t.line }
		elseif (t.type == "symbol" and (t.value == "(" or t.value == "{")) or t.type == "string" then
			local args = self:parseArgs()
			expr = { kind = "Call", fn = expr, args = args, line = t.line }
		else
			break
		end
	end
	return expr
end

function Parser:parseTableConstructor()
	local line = self:cur().line
	self:checkSym("{")
	local fields = {}
	while not self:isSym("}") do
		if self:isSym("[") then
			self:advance()
			local key = self:parseExpr()
			self:checkSym("]")
			self:checkSym("=")
			local value = self:parseExpr()
			fields[#fields + 1] = { type = "keyed", key = key, value = value }
		elseif self:cur().type == "name" and self:lookahead(1).type == "symbol" and self:lookahead(1).value == "=" then
			local key = self:advance().value
			self:advance() -- '='
			local value = self:parseExpr()
			fields[#fields + 1] = { type = "keyed", key = { kind = "String", value = key }, value = value }
		else
			local value = self:parseExpr()
			fields[#fields + 1] = { type = "positional", value = value }
		end
		if self:isSym(",") or self:isSym(";") then
			self:advance()
		else
			break
		end
	end
	self:checkSym("}")
	return { kind = "Table", fields = fields, line = line }
end

function Parser:parseFunctionBody(isMethod, line)
	self:checkSym("(")
	local params = {}
	local hasVararg = false
	if isMethod then params[#params + 1] = "self" end
	if not self:isSym(")") then
		while true do
			if self:isSym("...") then
				self:advance()
				hasVararg = true
				break
			end
			params[#params + 1] = self:checkName()
			if self:isSym(",") then self:advance() else break end
		end
	end
	self:checkSym(")")
	local body = self:parseBlock()
	self:checkKw("end")
	return { kind = "Function", params = params, hasVararg = hasVararg, body = body, line = line }
end

--------------------------------------------------------------------

local function parse(src, chunkname)
	local tokens = Lexer.tokenize(src, chunkname)
	local p = Parser.new(tokens, chunkname)
	return p:parseChunk()
end

return { parse = parse, Parser = Parser }
