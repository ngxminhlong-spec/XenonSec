--------------------------------------------------------------------
-- XenonSec :: parser.lua
-- Recursive-descent parser: tokens -> AST
--------------------------------------------------------------------

local Lexer = dofile((debug.getinfo(1, "S").source:match("@?(.*/)") or "") .. "lexer.lua")

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens, chunkname, luau)
	local self = setmetatable({}, Parser)
	self.toks = tokens
	self.pos = 1
	self.chunkname = chunkname or "?"
	self.luau = luau or false
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
-- Luau: type annotations are parsed and fully discarded (this is a
-- runtime obfuscator, not a type checker -- types have zero effect on
-- compiled behavior). This is a heuristic balanced-bracket skip rather
-- than a full type-grammar parser: it tracks (),{},[],<> nesting and
-- treats |, &, ?, ., ->, : as "the type continues" tokens, stopping at
-- the first real terminator seen at nesting depth 0.
--------------------------------------------------------------------

local TYPE_STOP_KEYWORDS = {
	["do"]=true, ["then"]=true, ["end"]=true, ["local"]=true, ["return"]=true,
	["if"]=true, ["for"]=true, ["while"]=true, ["repeat"]=true, ["break"]=true,
	["until"]=true, ["else"]=true, ["elseif"]=true, ["in"]=true,
}

function Parser:skipTypeExpr()
	local depth = 0
	local lastWasMinus = false
	while true do
		local t = self:cur()
		if t.type == "eof" then break end
		local isMinus = false
		if t.type == "symbol" then
			local v = t.value
			if v == "(" or v == "{" or v == "[" or v == "<" then
				depth = depth + 1; self:advance()
			elseif v == ")" or v == "}" or v == "]" then
				if depth == 0 then break end
				depth = depth - 1; self:advance()
			elseif v == ">" then
				if depth == 0 and not lastWasMinus then break end
				if depth > 0 then depth = depth - 1 end
				self:advance()
			elseif depth == 0 and (v == "," or v == "=" or v == ";") then
				break
			elseif v == "|" or v == "&" or v == "?" or v == "." or v == ":" then
				self:advance()
			elseif v == "-" then
				isMinus = true; self:advance()
			else
				if depth == 0 then break end
				self:advance()
			end
		elseif t.type == "keyword" then
			if depth == 0 and TYPE_STOP_KEYWORDS[t.value] then break end
			if t.value == "function" and depth == 0 then
				-- rare: a function-type spelled with the `function` keyword
				self:advance()
			else
				self:advance() -- e.g. `nil` as a literal type
			end
		else
			self:advance() -- name/number/string content of the type
		end
		lastWasMinus = isMinus
	end
end

-- Consumes `: Type` if present (Luau) and self.luau is on; no-op otherwise.
function Parser:maybeSkipTypeAnnotation()
	if self.luau and self:isSym(":") then
		self:advance()
		self:skipTypeExpr()
	end
end

-- Consumes a `<T, U, ...>` generic parameter list if present.
function Parser:maybeSkipGenerics()
	if self.luau and self:isSym("<") then
		self:advance()
		local depth = 1
		while depth > 0 do
			local t = self:cur()
			if t.type == "eof" then break end
			if t.type == "symbol" and t.value == "<" then depth = depth + 1
			elseif t.type == "symbol" and t.value == ">" then depth = depth - 1
			end
			self:advance()
		end
	end
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
	elseif self.luau and self:isKw("continue") then
		self:advance()
		return { kind = "Continue", line = t.line }
	elseif self.luau and t.type == "name" and t.value == "type"
		and self:lookahead(1) and self:lookahead(1).type == "name" then
		-- `type NAME = ...` or `type NAME<T> = ...` type-alias
		-- declaration: parsed and fully discarded, zero runtime effect.
		self:advance() -- 'type'
		self:advance() -- alias name
		self:maybeSkipGenerics()
		self:checkSym("=")
		self:skipTypeExpr()
		return { kind = "Do", body = { kind = "Block", body = {} } } -- no-op
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
	self:maybeSkipGenerics()
	local func = self:parseFunctionBody(isMethod, line)
	return { kind = "Assign", targets = { base }, values = { func }, line = line }
end

function Parser:parseLocal()
	local line = self:cur().line
	self:checkKw("local")
	if self:isKw("function") then
		self:advance()
		local name = self:checkName()
		self:maybeSkipGenerics()
		local func = self:parseFunctionBody(false, line)
		return { kind = "LocalFunction", name = name, func = func, line = line }
	end
	local names = { self:checkName() }
	self:maybeSkipTypeAnnotation()
	if self:isSym("<") then -- ignore Lua 5.4 attribs defensively; not in 5.1 but harmless
		self:advance(); self:checkName(); self:checkSym(">")
	end
	while self:isSym(",") do
		self:advance()
		names[#names + 1] = self:checkName()
		self:maybeSkipTypeAnnotation()
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

local COMPOUND_OPS = {
	["+="] = "+", ["-="] = "-", ["*="] = "*", ["/="] = "/",
	["//="] = "//", ["%="] = "%", ["^="] = "^", ["..="] = "..",
}

local compoundTempCounter = 0
local function freshCompoundTemp()
	compoundTempCounter = compoundTempCounter + 1
	return "\3ca" .. compoundTempCounter -- control-char prefix: can't collide with real source identifiers
end

function Parser:isCompoundAssignSym()
	local t = self:cur()
	return self.luau and t.type == "symbol" and COMPOUND_OPS[t.value] ~= nil
end

function Parser:parseExprStat()
	local line = self:cur().line
	local expr = self:parseSuffixedExpr()

	if self:isCompoundAssignSym() then
		local op = COMPOUND_OPS[self:cur().value]
		self:advance()
		local rhs = self:parseExpr()
		if expr.kind ~= "Name" and expr.kind ~= "Index" then
			self:error("cannot compound-assign to this expression")
		end

		if expr.kind == "Name" then
			-- Reading a plain variable twice has no side effects, so this
			-- desugars directly with no temps needed.
			local lhsCopy = { kind = "Name", name = expr.name, line = line }
			return {
				kind = "Assign",
				targets = { expr },
				values = { { kind = "Binop", op = op, lhs = lhsCopy, rhs = rhs, line = line } },
				line = line,
			}
		else
			-- Index target: evaluate the object/key exactly once each,
			-- via temp locals, so `getTable()[computeKey()] += v` never
			-- re-runs those side-effecting expressions a second time.
			local tmpObj, tmpKey = freshCompoundTemp(), freshCompoundTemp()
			local tmpObjRef = { kind = "Name", name = tmpObj, line = line }
			local tmpKeyRef = { kind = "Name", name = tmpKey, line = line }
			local idxRead = { kind = "Index", obj = tmpObjRef, key = tmpKeyRef, line = line }
			local idxWrite = { kind = "Index", obj = { kind = "Name", name = tmpObj, line = line },
				key = { kind = "Name", name = tmpKey, line = line }, line = line }
			return {
				kind = "Do",
				body = { kind = "Block", body = {
					{ kind = "Local", names = { tmpObj }, values = { expr.obj }, line = line },
					{ kind = "Local", names = { tmpKey }, values = { expr.key }, line = line },
					{ kind = "Assign", targets = { idxWrite },
						values = { { kind = "Binop", op = op, lhs = idxRead, rhs = rhs, line = line } },
						line = line },
				} },
			}
		end
	end

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
	["*"]={7,7}, ["/"]={7,7}, ["%"]={7,7}, ["//"]={7,7},
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
	elseif self.luau and t.type == "keyword" and t.value == "if" then
		return self:parseIfExpr()
	else
		return self:parseSuffixedExpr()
	end
end

-- Luau if-then-else EXPRESSION: `if C then E elseif C2 then E2 else E3`.
-- Desugared into `(function() if C then return E ... end end)()` --
-- reusing only already-supported AST node kinds (Function/Call/If/
-- Return), so none of the analysis passes need to know a ternary
-- expression exists at all. This is semantically exact (a real
-- conditional, unlike the classic `cond and a or b` trick, which
-- breaks when `a` is falsy).
function Parser:parseIfExpr()
	local line = self:cur().line
	self:checkKw("if")
	local clauses = {}
	local cond = self:parseExpr()
	self:checkKw("then")
	local thenExpr = self:parseExpr()
	clauses[#clauses + 1] = { cond = cond, body = { kind = "Block", body = {
		{ kind = "Return", args = { thenExpr }, line = line },
	} } }
	while self:isKw("elseif") do
		self:advance()
		local c = self:parseExpr()
		self:checkKw("then")
		local e = self:parseExpr()
		clauses[#clauses + 1] = { cond = c, body = { kind = "Block", body = {
			{ kind = "Return", args = { e }, line = line },
		} } }
	end
	self:checkKw("else") -- mandatory in Luau if-expressions (no implicit nil branch)
	local elseExpr = self:parseExpr()
	local elseBody = { kind = "Block", body = { { kind = "Return", args = { elseExpr }, line = line } } }

	local ifStat = { kind = "If", clauses = clauses, elseBody = elseBody, line = line }
	local func = { kind = "Function", params = {}, hasVararg = false,
		body = { kind = "Block", body = { ifStat } }, line = line }
	return { kind = "Call", fn = { kind = "Paren", expr = func, line = line }, args = {}, line = line }
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
				self:maybeSkipTypeAnnotation() -- Luau: `...: T`
				break
			end
			params[#params + 1] = self:checkName()
			self:maybeSkipTypeAnnotation()
			if self:isSym(",") then self:advance() else break end
		end
	end
	self:checkSym(")")
	self:maybeSkipTypeAnnotation() -- Luau: function return type, e.g. `function f(): number`
	local body = self:parseBlock()
	self:checkKw("end")
	return { kind = "Function", params = params, hasVararg = hasVararg, body = body, line = line }
end

--------------------------------------------------------------------

local function parse(src, chunkname, luau)
	local tokens = Lexer.tokenize(src, chunkname, luau)
	local p = Parser.new(tokens, chunkname, luau)
	return p:parseChunk()
end

return { parse = parse, Parser = Parser }
