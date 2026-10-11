--------------------------------------------------------------------
-- XenonSec :: lexer.lua
-- Tokenizer for Lua 5.1 source code.
--------------------------------------------------------------------

local Lexer = {}
Lexer.__index = Lexer

local KEYWORDS = {}
for _, k in ipairs({
	"and","break","do","else","elseif","end","false","for","function",
	"if","in","local","nil","not","or","repeat","return","then","true",
	"until","while",
}) do KEYWORDS[k] = true end

local function isDigit(c) return c ~= nil and c >= "0" and c <= "9" end
local function isAlpha(c)
	return c ~= nil and ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_")
end
local function isAlphaNum(c) return isAlpha(c) or isDigit(c) end

function Lexer.new(src, chunkname, luau)
	local self = setmetatable({}, Lexer)
	self.src = src
	self.len = #src
	self.pos = 1
	self.line = 1
	self.chunkname = chunkname or "?"
	self.luau = luau or false
	return self
end

function Lexer:error(msg)
	error(string.format("XenonSec lexer error (%s:%d): %s", self.chunkname, self.line, msg), 0)
end

function Lexer:peekChar(o)
	local p = self.pos + (o or 0)
	if p > self.len then return nil end
	return self.src:sub(p, p)
end

function Lexer:advance()
	local c = self:peekChar()
	if c == "\n" then self.line = self.line + 1 end
	self.pos = self.pos + 1
	return c
end

-- Try to read a long bracket [[ ]], [=[ ]=], etc. starting at self.pos which
-- must be at the first '['. Returns the enclosed string and level, or nil if
-- this isn't actually a valid long-bracket opener.
function Lexer:tryLongBracket()
	local start = self.pos
	if self:peekChar() ~= "[" then return nil end
	local p = start + 1
	local level = 0
	while self.src:sub(p, p) == "=" do
		level = level + 1
		p = p + 1
	end
	if self.src:sub(p, p) ~= "[" then return nil end
	-- consume opener
	self.pos = p + 1
	-- skip first newline immediately following opener
	if self:peekChar() == "\r" then self:advance() end
	if self:peekChar() == "\n" then self:advance() end
	local buf = {}
	local closer = "]" .. string.rep("=", level) .. "]"
	while true do
		if self.pos > self.len then
			self:error("unterminated long bracket")
		end
		if self:peekChar() == "]" then
			local candidate = self.src:sub(self.pos, self.pos + #closer - 1)
			if candidate == closer then
				for _ = 1, #closer do self:advance() end
				return table.concat(buf)
			end
		end
		local c = self:advance()
		buf[#buf + 1] = c
	end
end

function Lexer:skipWhitespaceAndComments()
	while true do
		local c = self:peekChar()
		if c == nil then return end
		if c == " " or c == "\t" or c == "\r" or c == "\n" then
			self:advance()
		elseif c == "-" and self:peekChar(1) == "-" then
			self:advance(); self:advance()
			if self:peekChar() == "[" then
				local saved = self.pos
				local long = self:tryLongBracket()
				if long ~= nil then
					-- consumed as long comment
				else
					self.pos = saved
					while self:peekChar() ~= nil and self:peekChar() ~= "\n" do self:advance() end
				end
			else
				while self:peekChar() ~= nil and self:peekChar() ~= "\n" do self:advance() end
			end
		else
			return
		end
	end
end

local ESCAPES = {
	a = "\a", b = "\b", f = "\f", n = "\n", r = "\r",
	t = "\t", v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n",
}

-- Encodes a Unicode codepoint as UTF-8 bytes, for Luau's `\u{XXXX}`
-- string escape. Written from scratch rather than relying on a host
-- `utf8.char` -- the tool itself may be running on a plain Lua 5.1
-- host with no `utf8` library at all.
local function utf8EncodeCodepoint(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(
			0xC0 + math.floor(cp / 0x40),
			0x80 + (cp % 0x40))
	elseif cp < 0x10000 then
		return string.char(
			0xE0 + math.floor(cp / 0x1000),
			0x80 + (math.floor(cp / 0x40) % 0x40),
			0x80 + (cp % 0x40))
	else
		return string.char(
			0xF0 + math.floor(cp / 0x40000),
			0x80 + (math.floor(cp / 0x1000) % 0x40),
			0x80 + (math.floor(cp / 0x40) % 0x40),
			0x80 + (cp % 0x40))
	end
end

-- Same escape set as ESCAPES above, but backtick strings additionally
-- support `\`` (literal backtick) and `\{` (literal `{`, so it isn't
-- read as the start of an interpolation segment).
local INTERP_ESCAPES = {
	a = "\a", b = "\b", f = "\f", n = "\n", r = "\r",
	t = "\t", v = "\v", ["\\"] = "\\", ["`"] = "`", ["{"] = "{", ["\n"] = "\n",
}

function Lexer:readString(quote)
	local buf = {}
	self:advance() -- opening quote
	while true do
		local c = self:peekChar()
		if c == nil or c == "\n" then
			self:error("unterminated string")
		end
		if c == quote then
			self:advance()
			break
		elseif c == "\\" then
			self:advance()
			local e = self:peekChar()
			if e == "z" then
				self:advance()
				while self:peekChar() and self:peekChar():match("%s") do self:advance() end
			elseif isDigit(e) then
				local digits = ""
				for _ = 1, 3 do
					if isDigit(self:peekChar()) then digits = digits .. self:advance() else break end
				end
				buf[#buf + 1] = string.char(tonumber(digits) % 256)
			elseif e == "x" then
				self:advance()
				local hex = ""
				for _ = 1, 2 do
					if self:peekChar() and self:peekChar():match("%x") then hex = hex .. self:advance() end
				end
				buf[#buf + 1] = string.char(tonumber(hex, 16) or 0)
			elseif e == "u" and self.luau then
				self:advance() -- 'u'
				if self:peekChar() ~= "{" then self:error("missing '{' after \\u") end
				self:advance() -- '{'
				local hex = ""
				while self:peekChar() and self:peekChar():match("%x") do hex = hex .. self:advance() end
				if self:peekChar() ~= "}" then self:error("missing '}' in \\u escape") end
				self:advance() -- '}'
				local cp = tonumber(hex, 16)
				if not cp or cp > 0x7FFFFFFF then self:error("invalid unicode codepoint in \\u escape") end
				buf[#buf + 1] = utf8EncodeCodepoint(cp)
			elseif ESCAPES[e] ~= nil then
				self:advance()
				buf[#buf + 1] = ESCAPES[e]
			else
				self:advance()
				buf[#buf + 1] = e or ""
			end
		else
			buf[#buf + 1] = self:advance()
		end
	end
	return table.concat(buf)
end

-- Skips over a nested string literal (quoted or long-bracket) starting
-- at the current position, without producing a token -- used while
-- scanning for an interpolated expression's closing `}` so a `}`
-- *inside* a nested string can never be mistaken for it.
function Lexer:skipNestedStringLiteral()
	local q = self:peekChar()
	if q == "[" and (self:peekChar(1) == "[" or self:peekChar(1) == "=") then
		local saved = self.pos
		local long = self:tryLongBracket()
		if long ~= nil then return end
		self.pos = saved
		return
	end
	if q ~= '"' and q ~= "'" then return end
	self:advance()
	while true do
		local c = self:peekChar()
		if c == nil or c == "\n" then self:error("unterminated string") end
		if c == q then self:advance(); return end
		if c == "\\" then
			self:advance()
			if self:peekChar() then self:advance() end
		else
			self:advance()
		end
	end
end

-- Reads the raw source text of a `{ ... }` interpolation segment (the
-- opening `{` has already been consumed by the caller). Balances
-- nested `{`/`}` and skips over nested string literals so a brace
-- inside a string never miscounts, stopping at the `}` that matches
-- the opener. Returns the raw expression text, not yet tokenized --
-- the parser tokenizes and parses each one as a standalone expression,
-- reusing the full recursive-descent parser rather than anything
-- lexer-level, so every Luau expression form (including nested
-- interpolated strings) is supported with no separate implementation.
function Lexer:readInterpExprSrc()
	local start = self.pos
	local depth = 1
	while true do
		local c = self:peekChar()
		if c == nil then self:error("unterminated interpolated expression") end
		if c == '"' or c == "'" or (c == "[" and (self:peekChar(1) == "[" or self:peekChar(1) == "=")) then
			self:skipNestedStringLiteral()
		elseif c == "{" then
			depth = depth + 1; self:advance()
		elseif c == "}" then
			depth = depth - 1
			if depth == 0 then
				local src = self.src:sub(start, self.pos - 1)
				self:advance() -- consume the closing '}'
				return src
			end
			self:advance()
		elseif c == "`" then
			-- A nested interpolated string inside this expression --
			-- skip it the same way the top-level reader would (it can
			-- itself contain `{`/`}`/quoted strings, all of which must
			-- not perturb this depth count).
			self:advance()
			while true do
				local ic = self:peekChar()
				if ic == nil or ic == "\n" then self:error("unterminated interpolated string") end
				if ic == "`" then self:advance(); break end
				if ic == "\\" then
					self:advance()
					if self:peekChar() then self:advance() end
				elseif ic == "{" then
					self:advance()
					self:readInterpExprSrc() -- discard; just need position advanced past it
				else
					self:advance()
				end
			end
		else
			self:advance()
		end
	end
end

-- Reads a Luau interpolated string, e.g. `hello {name}, you are {age}`.
-- The opening backtick has already been confirmed by the caller (not
-- yet consumed). Returns an array of parts, each either
-- `{kind="str", value=...}` (literal text, escapes already resolved)
-- or `{kind="expr", src=..., line=...}` (raw source of one `{...}`
-- segment, parsed later by the caller).
function Lexer:readInterpString()
	self:advance() -- opening `
	local parts = {}
	local buf = {}
	while true do
		local c = self:peekChar()
		if c == nil or c == "\n" then self:error("unterminated interpolated string") end
		if c == "`" then
			self:advance()
			parts[#parts + 1] = { kind = "str", value = table.concat(buf) }
			break
		elseif c == "{" then
			parts[#parts + 1] = { kind = "str", value = table.concat(buf) }
			buf = {}
			self:advance() -- opening '{'
			local exprLine = self.line
			local exprSrc = self:readInterpExprSrc()
			parts[#parts + 1] = { kind = "expr", src = exprSrc, line = exprLine }
		elseif c == "\\" then
			self:advance()
			local e = self:peekChar()
			if e == "z" then
				self:advance()
				while self:peekChar() and self:peekChar():match("%s") do self:advance() end
			elseif isDigit(e) then
				local digits = ""
				for _ = 1, 3 do
					if isDigit(self:peekChar()) then digits = digits .. self:advance() else break end
				end
				buf[#buf + 1] = string.char(tonumber(digits) % 256)
			elseif e == "x" then
				self:advance()
				local hex = ""
				for _ = 1, 2 do
					if self:peekChar() and self:peekChar():match("%x") then hex = hex .. self:advance() end
				end
				buf[#buf + 1] = string.char(tonumber(hex, 16) or 0)
			elseif e == "u" then
				self:advance() -- 'u'
				if self:peekChar() ~= "{" then self:error("missing '{' after \\u") end
				self:advance() -- '{'
				local hex = ""
				while self:peekChar() and self:peekChar():match("%x") do hex = hex .. self:advance() end
				if self:peekChar() ~= "}" then self:error("missing '}' in \\u escape") end
				self:advance() -- '}'
				local cp = tonumber(hex, 16)
				if not cp or cp > 0x7FFFFFFF then self:error("invalid unicode codepoint in \\u escape") end
				buf[#buf + 1] = utf8EncodeCodepoint(cp)
			elseif INTERP_ESCAPES[e] ~= nil then
				self:advance()
				buf[#buf + 1] = INTERP_ESCAPES[e]
			else
				self:advance()
				buf[#buf + 1] = e or ""
			end
		else
			buf[#buf + 1] = self:advance()
		end
	end
	return parts
end

function Lexer:readNumber()
	local start = self.pos
	if self:peekChar() == "0" and (self:peekChar(1) == "x" or self:peekChar(1) == "X") then
		self:advance(); self:advance()
		while self:peekChar() and (self:peekChar():match("[%x]") or (self.luau and self:peekChar() == "_")) do
			self:advance()
		end
	elseif self.luau and self:peekChar() == "0" and (self:peekChar(1) == "b" or self:peekChar(1) == "B") then
		-- Luau binary literal: 0b1010, optionally with `_` separators.
		self:advance(); self:advance()
		while self:peekChar() and (self:peekChar() == "0" or self:peekChar() == "1" or self:peekChar() == "_") do
			self:advance()
		end
	else
		while isDigit(self:peekChar()) or (self.luau and self:peekChar() == "_") do self:advance() end
		if self:peekChar() == "." then
			self:advance()
			while isDigit(self:peekChar()) or (self.luau and self:peekChar() == "_") do self:advance() end
		end
		if self:peekChar() == "e" or self:peekChar() == "E" then
			self:advance()
			if self:peekChar() == "+" or self:peekChar() == "-" then self:advance() end
			while isDigit(self:peekChar()) do self:advance() end
		end
	end
	local text = self.src:sub(start, self.pos - 1)
	-- Luau allows `_` as a digit-group separator anywhere in a numeral
	-- (`1_000_000`, `0xFF_FF`, `0b1010_1010`) -- strip it before parsing,
	-- it carries no value of its own.
	if self.luau then text = text:gsub("_", "") end
	local n
	if text:match("^0[bB]") then
		n = tonumber(text:sub(3), 2)
	else
		n = tonumber(text)
	end
	if not n then self:error("malformed number near '" .. text .. "'") end
	return n
end

local SYMBOLS_3 = { ["..."] = true, ["//="] = true, ["..="] = true }
local SYMBOLS_2 = {
	["=="]=true, ["~="]=true, ["<="]=true, [">="]=true, [".."]=true, ["//"]=true,
	["+="]=true, ["-="]=true, ["*="]=true, ["/="]=true, ["%="]=true, ["^="]=true,
}

function Lexer:next()
	self:skipWhitespaceAndComments()
	local line = self.line
	local c = self:peekChar()
	if c == nil then
		return { type = "eof", line = line }
	end

	if isAlpha(c) then
		local start = self.pos
		while isAlphaNum(self:peekChar()) do self:advance() end
		local word = self.src:sub(start, self.pos - 1)
		if KEYWORDS[word] or (self.luau and word == "continue") then
			return { type = "keyword", value = word, line = line }
		end
		return { type = "name", value = word, line = line }
	end

	if isDigit(c) or (c == "." and isDigit(self:peekChar(1))) then
		local n = self:readNumber()
		return { type = "number", value = n, line = line }
	end

	if c == '"' or c == "'" then
		local s = self:readString(c)
		return { type = "string", value = s, line = line }
	end

	if c == "`" and self.luau then
		local parts = self:readInterpString()
		return { type = "interpstring", parts = parts, line = line }
	end

	if c == "[" and (self:peekChar(1) == "[" or self:peekChar(1) == "=") then
		local saved = self.pos
		local long = self:tryLongBracket()
		if long ~= nil then
			return { type = "string", value = long, line = line }
		end
		self.pos = saved
	end

	local three = self.src:sub(self.pos, self.pos + 2)
	if SYMBOLS_3[three] then
		self.pos = self.pos + 3
		return { type = "symbol", value = three, line = line }
	end
	local two = self.src:sub(self.pos, self.pos + 1)
	if SYMBOLS_2[two] then
		self.pos = self.pos + 2
		return { type = "symbol", value = two, line = line }
	end
	self:advance()
	return { type = "symbol", value = c, line = line }
end

-- Tokenize the whole source into an array, ending with an 'eof' token.
function Lexer.tokenize(src, chunkname, luau)
	local lx = Lexer.new(src, chunkname, luau)
	local tokens = {}
	while true do
		local tok = lx:next()
		tokens[#tokens + 1] = tok
		if tok.type == "eof" then break end
	end
	return tokens
end

return Lexer
