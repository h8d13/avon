-- Tokenizer and Pratt Parser for a C-like language in Lua

local Object = {}

function Object:new(o)
	o = o or {}
	setmetatable(o, self)
	self.__index = self
	return o
end

-- Lexer: returns tokens as {type=..., value=...}

local Tokenizer = Object:new()

-- `prelude` is an optional project-wide source of `__` directives (`.novapre`);
-- its aliases seed this file's table, then file-local directives add to them.
-- Only the file's own text becomes self.input, so error line:col is unshifted.
function Tokenizer:new(input, prelude)
	local o = Object.new(self)
	o.aliases = {}
	if prelude then o:extract_pragmas(prelude) end
	o.input = o:extract_pragmas(input)
	o.i, o.len = 1, #o.input
	return o
end

-- Token types
local TokenType = {
	Number = "number",
	String = "string",
	Ident = "identifier",
	Symbol = "symbol",
	Keyword = "keyword",
	EOF = "eof",
}

-- Operator precedence levels
local Precedence = {
	["="] = 1,
	["+="] = 1,
	["-="] = 1,
	["*="] = 1,
	["/="] = 1,
	["%="] = 1,
	["?"] = 1.5, -- ternary, above assignment, below ||
	["||"] = 2,
	["&&"] = 3,
	-- bitwise sit between && and == (C order |, ^, & ascending)
	["|"] = 3.2,
	["^"] = 3.4,
	["&"] = 3.6,
	["=="] = 4,
	["!="] = 4,
	["<"] = 5,
	["<="] = 5,
	[">"] = 5,
	[">="] = 5,
	["<<"] = 5.5,
	[">>"] = 5.5, -- shifts above comparison, below +
	["+"] = 6,
	["-"] = 6,
	["*"] = 7,
	["/"] = 7,
	["%"] = 7,
	["("] = 8, -- function calls
	["["] = 8, -- array subscript
	["."] = 8, -- member access on a call/index result (postfix)
}

local keywords = {
	["fn"] = true,
	["if"] = true,
	["else"] = true,
	["for"] = true,
	["return"] = true,
	["typedef"] = true,
	["switch"] = true,
	["case"] = true,
	["default"] = true,
	["enum"] = true,
	["break"] = true,
	["continue"] = true,
	["try"] = true,
	["catch"] = true,
	["except"] = true,
	["throw"] = true,
	["import"] = true,
}

-- `__<target> = <alias>` lines register a per-file word rewrite (`alias` ->
-- `target`) and are blanked out (not deleted) so downstream byte offsets and
-- line:col reporting stay accurate. Runs once at construction, before scanning.
-- `target` may be a keyword (rewrite classifies as that keyword) or any other
-- identifier such as a host/user function name (rewrite stays an identifier);
-- non-keyword targets are unchecked, so a typo surfaces as a runtime nil-call.
function Tokenizer:extract_pragmas(input)
	return (
		input:gsub("[^\n]*", function(line)
			local target, alias = line:match("^%s*__(%w+)%s*=%s*(%w+)%s*$")
			if not target then return line end
			if keywords[alias] then
				error("alias shadows keyword: " .. alias, 0)
			end
			self.aliases[alias] = target
			return ""
		end)
	)
end

local function is_space(c) return c == " " or c == "\n" or c == "\r" or c == "\t" end
local function is_alpha(c) return c:match("%a") ~= nil or c == "_" end
local function is_digit(c) return c:match("%d") ~= nil end

-- Main scan: skip whitespace/comments in place, then hand a token-producing
-- character to the matching scanner. Each scanner reads/advances self.i and
-- returns one token, so this loop stays a flat dispatch.
function Tokenizer:next()
	local input, len = self.input, self.len
	local i = self.i
	while i <= len do
		local c = input:sub(i, i)
		if is_space(c) then
			i = i + 1
		elseif c == "/" and input:sub(i + 1, i + 1) == "/" then
			i = self:skip_line_comment(i)
		elseif c == "/" and input:sub(i + 1, i + 1) == "*" then
			i = self:skip_block_comment(i)
		else
			self.i = i -- scanners pick up from here
			if is_digit(c) then return self:scan_number() end
			if is_alpha(c) then return self:scan_ident() end
			if c == '"' then return self:scan_string() end
			if c == "'" then return self:scan_char() end
			return self:scan_symbol()
		end
	end
	self.i = i
	return { type = TokenType.EOF, value = "" }
end

-- advance past a `//` line comment; returns the index at end-of-line
function Tokenizer:skip_line_comment(i)
	local input, len = self.input, self.len
	i = i + 2
	while i <= len and input:sub(i, i) ~= "\n" do
		i = i + 1
	end
	return i
end

-- advance past a `/* ... */` block comment; returns the index after `*/`
function Tokenizer:skip_block_comment(i)
	local input, len = self.input, self.len
	i = i + 2
	while
		i <= len
		and not (input:sub(i, i) == "*" and input:sub(i + 1, i + 1) == "/")
	do
		i = i + 1
	end
	return i + 2
end

function Tokenizer:scan_number()
	local input, len = self.input, self.len
	local i = self.i
	self.last_pos = i
	local start = i
	while i <= len and is_digit(input:sub(i, i)) do
		i = i + 1
	end
	-- fractional part: a '.' then at least one digit makes it a float. Tag it:
	-- under Lua 5.1/LuaJIT every number is a double, so the value alone cannot
	-- tell int from float; the backend needs this for typing.
	local isFloat = false
	if input:sub(i, i) == "." and is_digit(input:sub(i + 1, i + 1)) then
		isFloat = true
		i = i + 1
		while i <= len and is_digit(input:sub(i, i)) do
			i = i + 1
		end
	end
	self.i = i
	return {
		type = TokenType.Number,
		value = tonumber(input:sub(start, i - 1)),
		isFloat = isFloat,
	}
end

function Tokenizer:scan_ident()
	local input, len = self.input, self.len
	local i = self.i
	self.last_pos = i
	local start = i
	while i <= len and input:sub(i, i):match("[%w_]") do
		i = i + 1
	end
	local word = input:sub(start, i - 1)
	word = self.aliases[word] or word -- rewrite alias to its canonical keyword
	self.i = i
	local kind = keywords[word] and TokenType.Keyword or TokenType.Ident
	return { type = kind, value = word }
end

function Tokenizer:scan_string()
	local input, len = self.input, self.len
	local i = self.i
	self.last_pos = i
	i = i + 1
	local start = i
	while i <= len and input:sub(i, i) ~= '"' do
		i = i + 1
	end
	self.i = i + 1
	return { type = TokenType.String, value = input:sub(start, i - 1) }
end

-- char literal: 'c' or an escape like '\n'; value is the byte code
function Tokenizer:scan_char()
	local input = self.input
	local i = self.i
	self.last_pos = i
	local ch = input:sub(i + 1, i + 1)
	local code, after
	if ch == "\\" then
		local esc = input:sub(i + 2, i + 2)
		local map = { n = 10, t = 9, r = 13, ["0"] = 0, ["\\"] = 92, ["'"] = 39 }
		code = map[esc] or string.byte(esc)
		after = i + 3 -- '\x
	else
		code = string.byte(ch)
		after = i + 2 -- 'x
	end
	if input:sub(after, after) ~= "'" then
		local l, col = self:linecol()
		error(string.format("%d:%d: unterminated char literal", l, col), 0)
	end
	self.i = after + 1
	return { type = TokenType.Number, value = code }
end

-- one- or two-char operator/punctuation token (==, +=, <<, &&, ...)
function Tokenizer:scan_symbol()
	local input = self.input
	local i = self.i
	self.last_pos = i
	local c = input:sub(i, i)
	local n = input:sub(i + 1, i + 1)
	local sym = c
	if (c == "=" or c == "!" or c == "<" or c == ">") and n == "=" then
		sym = c .. "="
		i = i + 1
	elseif
		(c == "+" or c == "-" or c == "*" or c == "/" or c == "%")
		and n == "="
	then
		sym = c .. "=" -- compound assignment
		i = i + 1
	elseif c == "+" and n == "+" then
		sym, i = "++", i + 1
	elseif c == "&" and n == "&" then
		sym, i = "&&", i + 1
	elseif c == "|" and n == "|" then
		sym, i = "||", i + 1
	elseif c == "<" and n == "<" then
		sym, i = "<<", i + 1
	elseif c == ">" and n == ">" then
		sym, i = ">>", i + 1
	end
	self.i = i + 1
	return { type = TokenType.Symbol, value = sym }
end

function Tokenizer:peek()
	local i = self.i
	local token = self:next()
	self.i = i
	return token
end

-- Backtracking support: capture/restore scan state so callers do not
-- depend on the internal layout of the tokenizer.
function Tokenizer:mark() return self.i end
function Tokenizer:reset(m) self.i = m end

-- 1-based line and column of byte offset `pos`. Defaults to the start of the
-- most recently scanned token (set in next()), so an error points at the token
-- itself, not the whitespace after it.
function Tokenizer:linecol(pos)
	pos = pos or self.last_pos or self.i
	local line, last = 1, 0
	for at in self.input:sub(1, pos):gmatch("()\n") do
		line = line + 1
		last = at
	end
	return line, pos - last
end

local Parser = Object:new()

function Parser:new(input, prelude)
	local o = Object.new(self)
	o.tokens = Tokenizer:new(input, prelude)
	return o
end

function Parser:peek() return self.tokens:peek() end
function Parser:next() return self.tokens:next() end

-- raise a parse error tagged with line:col (level 0 = no Lua location prefix)
function Parser:err(msg)
	local line, col = self.tokens:linecol()
	error(string.format("%d:%d: %s", line, col, msg), 0)
end

function Parser:expect(type_or_val)
	local tok = self:next()
	if tok.type ~= type_or_val and tok.value ~= type_or_val then
		self:err("Expected " .. type_or_val .. ", got " .. tok.value)
	end
	return tok
end

-- Pratt parser entry point
function Parser:parse_expression(precedence)
	precedence = precedence or 0
	local t = self:next()
	local left = self:nud(t)
	while
		Precedence[self:peek().value]
		and Precedence[self:peek().value] > precedence
	do
		local op = self:next()
		left = self:led(op, left)
	end
	return left
end

-- Null denotation (prefix, literals)
function Parser:nud(tok)
	if tok.type == TokenType.Number or tok.type == TokenType.String then
		return { type = "literal", value = tok.value, isFloat = tok.isFloat }
	elseif tok.type == TokenType.Ident then
		if tok.value == "true" then return { type = "literal", value = 1 } end
		if tok.value == "false" then return { type = "literal", value = 0 } end
		-- qualified name: module.func (e.g. math.sqrt, cjson.encode)
		local name = tok.value
		while self:peek().value == "." do
			self:next()
			name = name .. "." .. self:expect(TokenType.Ident).value
		end
		if self:peek().value == "(" then return self:parse_call(name) end
		return { type = "identifier", name = name }
	elseif tok.value == "(" then
		local expr = self:parse_expression()
		self:expect(")")
		return expr
	elseif tok.value == "-" then
		-- unary minus binds looser than !/~ (level 6, not *): harmless
		-- since -(a*b) == (-a)*b and int /,% truncate the same either way
		local right = self:parse_expression(Precedence["-"])
		return { type = "unary", op = "-", right = right }
	elseif tok.value == "!" or tok.value == "~" then
		local right = self:parse_expression(Precedence["*"]) -- tight prefix bind
		return { type = "unary", op = tok.value, right = right }
	elseif tok.value == "++" then
		-- prefix ++: desugar `++x` to `x = x + 1`. (`--` is a comment, not a
		-- decrement; use `x -= 1` to subtract.)
		local target = self:parse_expression(Precedence["*"])
		return {
			type = "binary",
			op = "=",
			left = target,
			right = {
				type = "binary",
				op = "+",
				left = target,
				right = { type = "literal", value = 1 },
			},
		}
	end
	self:err("Unexpected token: " .. tok.value)
end

-- compound assignment ops desugar `a OP= b` to `a = a OP b`
local compound = { ["+="] = "+", ["-="] = "-", ["*="] = "*", ["/="] = "/", ["%="] = "%" }

-- Left denotation (binary infix)
function Parser:led(op_tok, left)
	if op_tok.value == "[" then
		local index = self:parse_expression()
		self:expect("]")
		return { type = "index", array = left, index = index }
	end
	if op_tok.value == "." then
		-- postfix member access: fires only when `.` follows a non-identifier
		-- result (a call/index/group); plain `a.b.c` is folded into a dotted
		-- name string in nud and never reaches here.
		local field = self:expect(TokenType.Ident).value
		return { type = "member", obj = left, field = field }
	end
	if op_tok.value == "(" then
		-- postfix call of an arbitrary callee: `f()()`, `obj.m()`, `g[i]()`.
		-- The opening `(` is already consumed by the Pratt loop.
		return { type = "call", callee = left, args = self:parse_args_rest() }
	end
	if op_tok.value == "?" then
		local then_e = self:parse_expression(0) -- delimited by ':'
		self:expect(":")
		local else_e = self:parse_expression(0) -- right-assoc: binds rest
		return { type = "ternary", cond = left, thenE = then_e, elseE = else_e }
	end
	local cop = compound[op_tok.value]
	if cop then
		-- right-assoc
		local rhs = self:parse_expression(Precedence[op_tok.value] - 1)
		return {
			type = "binary",
			op = "=",
			left = left,
			right = { type = "binary", op = cop, left = left, right = rhs },
		}
	end
	local right = self:parse_expression(Precedence[op_tok.value])
	return { type = "binary", op = op_tok.value, left = left, right = right }
end

-- parse `arg, arg, ...)` after the opening `(` has been consumed
function Parser:parse_args_rest()
	local args = {}
	if self:peek().value ~= ")" then
		repeat
			args[#args + 1] = self:parse_expression()
		until self:peek().value ~= "," or not self:next()
	end
	self:expect(")")
	return args
end

-- a call by name: `name(...)`. `name` is the dotted-string callee built in nud
-- (math.sqrt, a user fn); the name-string form keeps the int-return inference
-- keyed on the function name. Chained callees (require("m").sqrt) come through
-- the `(` led instead, carrying a `callee` expression rather than a name.
function Parser:parse_call(name)
	self:expect("(")
	return { type = "call", name = name, args = self:parse_args_rest() }
end

-- Lookahead: is this Ident-led statement a declaration (`T name` /
-- `T[N] name`) rather than an expression (`arr[i] = x`, `x = 5`)?
-- Both forms start `Ident [ ... ]`; the closing `]` is followed by the
-- variable name in a decl, by an operator in an lvalue index.
function Parser:looks_like_decl()
	local save = self.tokens:mark()
	self:next() -- the leading type identifier
	local result = false
	local t1 = self:peek()
	if t1.type == TokenType.Ident then
		result = true -- `T name`
	elseif t1.value == "[" then
		self:next()
		local depth = 1
		while depth > 0 do
			local t = self:next()
			if t.type == TokenType.EOF then break end
			if t.value == "[" then
				depth = depth + 1
			elseif t.value == "]" then
				depth = depth - 1
			end
		end
		result = self:peek().type == TokenType.Ident -- `T[N] name`
	end
	self.tokens:reset(save)
	return result
end

-- keyword -> Parser method that parses that statement form. Resolved by name
-- at call time, so the methods can be defined further down.
local STMT = {
	fn = "parse_function",
	["if"] = "parse_if",
	["for"] = "parse_for",
	typedef = "parse_typedef",
	switch = "parse_switch",
	enum = "parse_enum",
	["try"] = "parse_try",
	["break"] = "parse_break",
	["continue"] = "parse_continue",
	throw = "parse_throw",
	import = "parse_import",
	["return"] = "parse_return",
}

function Parser:parse_statement()
	local tok = self:peek()
	if tok.type == TokenType.Keyword then
		local m = STMT[tok.value]
		if m then return self[m](self) end
	elseif tok.type == TokenType.Ident and self:looks_like_decl() then
		return self:parse_declaration()
	end
	return self:parse_expression()
end

function Parser:parse_break()
	self:next()
	return { type = "break" }
end

function Parser:parse_continue()
	self:next()
	return { type = "continue" }
end

function Parser:parse_throw()
	self:next()
	return { type = "throw", value = self:parse_expression() }
end

function Parser:parse_import()
	self:next()
	-- dotted module path: `import a.b.c` -> "a.b.c" (a nested .nova file or a
	-- nested host module). Same `.`-loop as a qualified call name.
	local module = self:expect(TokenType.Ident).value
	while self:peek().value == "." do
		self:next()
		module = module .. "." .. self:expect(TokenType.Ident).value
	end
	-- optional `as <alias>`: bind the module under a different name. `as` is
	-- contextual (a plain ident), so it stays usable as a name.
	local alias = module
	if self:peek().value == "as" then
		self:next()
		alias = self:expect(TokenType.Ident).value
	end
	return { type = "import", module = module, alias = alias }
end

function Parser:parse_return()
	self:next()
	local values = { self:parse_expression() }
	while self:peek().value == "," do
		self:next()
		values[#values + 1] = self:parse_expression()
	end
	return { type = "return", values = values }
end

-- enum variants become auto-incrementing integer constants from 0
function Parser:parse_enum()
	self:expect("enum")
	local name = self:expect(TokenType.Ident).value
	self:expect("{")
	local variants = {}
	while self:peek().value ~= "}" do
		variants[#variants + 1] = self:expect(TokenType.Ident).value
		if self:peek().value == "," then self:next() end
	end
	self:expect("}")
	return { type = "enum", name = name, variants = variants }
end

-- try { body } catch e { handler } -- `except` accepted as a synonym
function Parser:parse_try()
	self:expect("try")
	local body = self:parse_block()
	local kw = self:peek().value
	if kw ~= "catch" and kw ~= "except" then
		self:err("Expected catch/except after try, got " .. kw)
	end
	self:next()
	local var = self:expect(TokenType.Ident).value
	local handler = self:parse_block()
	return { type = "try", body = body, catchVar = var, handler = handler }
end

function Parser:parse_switch()
	self:expect("switch")
	local subject = self:parse_expression()
	self:expect("{")
	local cases = {}
	local default_body = nil
	while self:peek().value ~= "}" do
		if self:peek().value == "case" then
			self:next()
			local value = self:parse_expression()
			self:expect(":")
			cases[#cases + 1] =
				{ value = value, body = self:parse_case_body() }
		elseif self:peek().value == "default" then
			self:next()
			self:expect(":")
			default_body = self:parse_case_body()
		else
			self:err(
				"Expected case or default in switch, got "
					.. self:peek().value
			)
		end
	end
	self:expect("}")
	return {
		type = "switch",
		subject = subject,
		cases = cases,
		default = default_body,
	}
end

-- case body runs until the next case/default or the closing brace; no
-- fall-through, so no `break` is needed
function Parser:parse_case_body()
	local body = {}
	while true do
		local v = self:peek().value
		if v == "case" or v == "default" or v == "}" then break end
		body[#body + 1] = self:parse_statement()
		if self:peek().value == ";" then self:next() end
	end
	return body
end

function Parser:parse_block()
	local one = self:peek().value ~= "{"
	if not one then self:expect("{") end

	local body = {}
	while self:peek().value ~= "}" do
		body[#body + 1] = self:parse_statement()
		if self:peek().value == ";" then
			self:next()
			if one then break end
		end
	end
	if not one then self:expect("}") end
	return body
end

function Parser:parse_type()
	local base = self:expect(TokenType.Ident).value
	if self:peek().value == "[" then
		self:next()
		local size = self:expect(TokenType.Number).value
		self:expect("]")
		return { type = "arraytype", base = base, size = tonumber(size) }
	end
	return { type = "type", name = base }
end

function Parser:parse_typedef()
	self:expect("typedef")
	local base = self:parse_type()
	local alias = self:expect(TokenType.Ident).value
	self:expect(";")
	return { type = "typedef", alias = alias, base = base }
end

-- Parse `T a, b = expr, ...` into a list of decl nodes, sharing one type.
-- Does not consume the terminating ';' so a for-init can reuse it.
function Parser:parse_decl_list()
	local var_type = self:parse_type()
	local decls = {}
	repeat
		local var_name = self:expect(TokenType.Ident).value
		local init = nil
		if self:peek().value == "=" then
			self:next() -- consume '='
			init = self:parse_expression()
		end
		decls[#decls + 1] = {
			type = "decl",
			varType = var_type,
			name = var_name,
			value = init,
		}
	until self:peek().value ~= "," or not self:next()
	return decls
end

function Parser:parse_declaration()
	local decls = self:parse_decl_list()
	self:expect(";")
	return decls -- a list (no .type); gen_statement walks / destructures it
end

function Parser:parse_function()
	self:expect("fn")

	-- return types: comma-separated identifiers, before the name
	local return_types = {}
	repeat
		local tok = self:expect(TokenType.Ident)
		return_types[#return_types + 1] = tok.value
	until self:peek().value ~= "," or not self:next()

	local name = self:expect(TokenType.Ident).value

	self:expect("(")
	local params = {}
	if self:peek().value ~= ")" then
		repeat
			local param_type = self:expect(TokenType.Ident).value
			local param_name = self:expect(TokenType.Ident).value
			params[#params + 1] = { type = param_type, name = param_name }
		until self:peek().value ~= "," or not self:next()
	end
	self:expect(")")

	local body = self:parse_block()

	return {
		type = "function",
		name = name,
		returnTypes = return_types,
		params = params,
		body = body,
	}
end

function Parser:parse_if()
	self:expect("if")
	local cond = self:parse_expression()
	local then_branch = self:parse_block()
	local else_branch = nil
	if self:peek().value == "else" then
		self:next()
		else_branch = self:parse_block()
	end
	return {
		type = "if",
		cond = cond,
		thenBranch = then_branch,
		elseBranch = else_branch,
	}
end

-- Two forms share the `for` keyword:
--   C-style:   for init; cond; update { body }
--   iterator:  for T name = expr { body }   (no `;` -- a `{` follows init)
-- The init is parsed without its trailing ';'; the token after it (`;` vs
-- `{`) selects the form.
function Parser:parse_for()
	self:expect("for")

	local init
	if self:peek().type == TokenType.Ident and self:looks_like_decl() then
		init = self:parse_decl_list() -- decl list, no ';' consumed
	else
		init = self:parse_expression()
	end

	-- iterator form: re-evaluates `expr` each pass, binds it to the loop
	-- variable, runs the body while the value is non-zero (0 = exhausted)
	if self:peek().value == "{" then
		return { type = "forin", init = init, body = self:parse_block() }
	end

	self:expect(";")
	local cond = self:parse_expression()
	self:expect(";")
	local update = self:parse_statement() -- e.g. an assignment
	local body = self:parse_block()
	return { type = "for", init = init, cond = cond, update = update, body = body }
end

function Parser:parse()
	local program = {}
	while self:peek().type ~= TokenType.EOF do
		program[#program + 1] = self:parse_statement()
		if self:peek().value == ";" then self:next() end
	end
	return { type = "program", body = program }
end

return Parser
