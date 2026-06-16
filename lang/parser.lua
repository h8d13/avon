-- Tokenizer and Pratt Parser for a C-like language in Lua

local Object = {}

function Object:new(o)
   o = o or {}
   setmetatable(o, self)
   self.__index = self
   return o
end


-- Lexer: returns tokens as {type=..., value=...}

Tokenizer = Object:new()

function Tokenizer:new(input)
  o = Object.new(self)
  o.input = input
  o.i, o.len = 1, #input
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
  ["+="] = 1, ["-="] = 1, ["*="] = 1, ["/="] = 1, ["%="] = 1,
  ["?"] = 1.5, -- ternary, above assignment, below ||
  ["||"] = 2,
  ["&&"] = 3,
  -- bitwise sit between && and == (C order |, ^, & ascending)
  ["|"] = 3.2, ["^"] = 3.4, ["&"] = 3.6,
  ["=="] = 4, ["!="] = 4,
  ["<"] = 5, ["<="] = 5, [">"] = 5, [">="] = 5,
  ["<<"] = 5.5, [">>"] = 5.5, -- shifts above comparison, below +
  ["+"] = 6, ["-"] = 6,
  ["*"] = 7, ["/"] = 7, ["%"] = 7,
  ["("] = 8, -- function calls
  ["["] = 8, -- array subscript
}

local keywords = {
  ["fn"]=true, ["if"]=true, ["else"]=true, ["for"]=true, ["return"]=true,
  ["typedef"]=true, ["struct"]=true,
  ["switch"]=true, ["case"]=true, ["default"]=true, ["enum"]=true,
}

local function is_space(c) return c == ' ' or c == '\n' or c == '\r' or c == '\t' end
local function is_alpha(c) return c:match("%a") or c == "_" end
local function is_digit(c) return c:match("%d") end

function Tokenizer:next()
  local input, i, len = self.input, self.i, self.len
  while i <= len do
    local c = input:sub(i, i)

    if is_space(c) then
      i = i + 1

    -- line comment
    elseif c == "/" and input:sub(i+1, i+1) == "/" then
      i = i + 2
      while i <= len and input:sub(i, i) ~= "\n" do i = i + 1 end

    -- block comment
    elseif c == "/" and input:sub(i+1, i+1) == "*" then
      i = i + 2
      while i <= len and not (input:sub(i,i) == "*" and input:sub(i+1,i+1) == "/") do
        i = i + 1
      end
      i = i + 2 -- skip closing */

    elseif is_digit(c) then
      local start = i
      while i <= len and is_digit(input:sub(i, i)) do i = i + 1 end
      -- fractional part: a '.' followed by at least one digit makes it a float
      if input:sub(i, i) == "." and is_digit(input:sub(i+1, i+1)) then
        i = i + 1
        while i <= len and is_digit(input:sub(i, i)) do i = i + 1 end
      end
      self.i = i
      return {type=TokenType.Number, value=tonumber(input:sub(start, i-1))}

    elseif is_alpha(c) then
      local start = i
      while i <= len and input:sub(i, i):match("[%w_]") do i = i + 1 end
      local word = input:sub(start, i-1)
      local type = keywords[word] and TokenType.Keyword or TokenType.Ident
      self.i = i
      return {type=type, value=word}

    elseif c == '"' then
      i = i + 1
      local start = i
      while i <= len and input:sub(i, i) ~= '"' do i = i + 1 end
      local str = input:sub(start, i-1)
      self.i = i + 1
      return {type=TokenType.String, value=str}

    -- char literal: 'c' or an escape like '\n'; value is the byte code
    elseif c == "'" then
      local ch = input:sub(i+1, i+1)
      local code, after
      if ch == "\\" then
        local esc = input:sub(i+2, i+2)
        local map = {n=10, t=9, r=13, ["0"]=0, ["\\"]=92, ["'"]=39}
        code = map[esc] or string.byte(esc)
        after = i + 3 -- '\x
      else
        code = string.byte(ch)
        after = i + 2 -- 'x
      end
      if input:sub(after, after) ~= "'" then
        error("unterminated char literal")
      end
      self.i = after + 1
      return {type=TokenType.Number, value=code}

    else
      local sym = c
      local n = input:sub(i+1, i+1)
      if (c == '=' or c == '!' or c == '<' or c == '>') and n == '=' then
        sym = c .. '='
        i = i + 1
      elseif (c == '+' or c == '-' or c == '*' or c == '/' or c == '%')
          and n == '=' then
        sym = c .. '='; i = i + 1 -- compound assignment
      elseif c == '+' and n == '+' then
        sym = '++'; i = i + 1
      elseif c == '-' and n == '-' then
        sym = '--'; i = i + 1
      elseif c == '&' and n == '&' then
        sym = '&&'; i = i + 1
      elseif c == '|' and n == '|' then
        sym = '||'; i = i + 1
      elseif c == '<' and n == '<' then
        sym = '<<'; i = i + 1
      elseif c == '>' and n == '>' then
        sym = '>>'; i = i + 1
      end
      self.i = i + 1
     return {type=TokenType.Symbol, value=sym}
    end
  end

  self.i = i
  return {type=TokenType.EOF, value=""}
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

Parser = Object:new()

  function Parser:new(input)
    local o = Object.new(self)
    o.tokens = Tokenizer:new(input)
    return o
  end

  function Parser:peek() return self.tokens:peek() end
  function Parser:next() return self.tokens:next() end

  function Parser:expect(type_or_val)
    local tok = self:next()
    if tok.type ~= type_or_val and tok.value ~= type_or_val then
      error("Expected " .. type_or_val .. ", got " .. tok.value)
    end
    return tok
  end

  -- Pratt parser entry point
  function Parser:parse_expression(precedence)
    precedence = precedence or 0
    local t = self:next()
    local left = self:nud(t)
    while Precedence[self:peek().value] and Precedence[self:peek().value] > precedence do
      local op = self:next()
      left = self:led(op, left)
    end
    return left
  end

  -- Null denotation (prefix, literals)
  function Parser:nud(tok)
    if tok.type == TokenType.Number or tok.type == TokenType.String then
      return {type="literal", value=tok.value}
    elseif tok.type == TokenType.Ident then
      if tok.value == "true" then return {type="literal", value=1} end
      if tok.value == "false" then return {type="literal", value=0} end
      if self:peek().value == "(" then
        return self:parse_call(tok.value)
      end
      return {type="identifier", name=tok.value}
    elseif tok.value == "(" then
      local expr = self:parse_expression()
      self:expect(")")
      return expr
    elseif tok.value == "-" then
      local right = self:parse_expression(Precedence["-"])
      return {type="unary", op="-", right=right}
    elseif tok.value == "!" or tok.value == "~" then
      local right = self:parse_expression(Precedence["*"]) -- tight prefix bind
      return {type="unary", op=tok.value, right=right}
    elseif tok.value == "++" or tok.value == "--" then
      -- prefix ++/--: desugar `++x` to `x = x + 1`
      local target = self:parse_expression(Precedence["*"])
      local bop = tok.value == "++" and "+" or "-"
      return {type="binary", op="=", left=target,
              right={type="binary", op=bop, left=target,
                     right={type="literal", value=1}}}
    end
    error("Unexpected token: " .. tok.value)
  end

  -- compound assignment ops desugar `a OP= b` to `a = a OP b`
  local compound = {["+="]="+", ["-="]="-", ["*="]="*", ["/="]="/", ["%="]="%"}

  -- Left denotation (binary infix)
  function Parser:led(op_tok, left)
    if op_tok.value == "[" then
      local index = self:parse_expression()
      self:expect("]")
      return {type="index", array=left, index=index}
    end
    if op_tok.value == "?" then
      local then_e = self:parse_expression(0) -- delimited by ':'
      self:expect(":")
      local else_e = self:parse_expression(0) -- right-assoc: binds rest
      return {type="ternary", cond=left, thenE=then_e, elseE=else_e}
    end
    local cop = compound[op_tok.value]
    if cop then
      local rhs = self:parse_expression(Precedence[op_tok.value] - 1) -- right-assoc
      return {type="binary", op="=", left=left,
              right={type="binary", op=cop, left=left, right=rhs}}
    end
    local right = self:parse_expression(Precedence[op_tok.value])
    return {type="binary", op=op_tok.value, left=left, right=right}
  end

  function Parser:parse_call(name)
    self:expect("(")
    local args = {}
    if self:peek().value ~= ")" then
      repeat
        table.insert(args, self:parse_expression())
      until self:peek().value ~= "," or not self:next()
    end
    self:expect(")")
    return {type="call", name=name, args=args}
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
        if t.value == "[" then depth = depth + 1
        elseif t.value == "]" then depth = depth - 1 end
      end
      result = self:peek().type == TokenType.Ident -- `T[N] name`
    end
    self.tokens:reset(save)
    return result
  end

  function Parser:parse_statement()
    local tok = self:peek()

    if tok.type == TokenType.Keyword and tok.value == "fn" then
     return self:parse_function()
    elseif tok.type == TokenType.Keyword and tok.value == "if" then
      return self:parse_if()
    elseif tok.type == TokenType.Keyword and tok.value == "for" then
      return self:parse_for()
    elseif tok.type == TokenType.Keyword and tok.value == "typedef" then
      return self:parse_typedef()
    elseif tok.type == TokenType.Keyword and tok.value == "struct" then
      return self:parse_struct()
    elseif tok.type == TokenType.Keyword and tok.value == "switch" then
      return self:parse_switch()
    elseif tok.type == TokenType.Keyword and tok.value == "enum" then
      return self:parse_enum()
    elseif tok.type == TokenType.Keyword and tok.value == "return" then
      self:next()
      local values = {self:parse_expression()}
      while self:peek().value == "," do
        self:next()
        table.insert(values, self:parse_expression())
      end
      return {type="return", values=values}
    elseif tok.type == TokenType.Ident then
      if self:looks_like_decl() then
        return self:parse_declaration()
      end
    end

    return self:parse_expression()
  end

  -- enum variants become auto-incrementing integer constants from 0
  function Parser:parse_enum()
    self:expect("enum")
    local name = self:expect(TokenType.Ident).value
    self:expect("{")
    local variants = {}
    while self:peek().value ~= "}" do
      table.insert(variants, self:expect(TokenType.Ident).value)
      if self:peek().value == "," then self:next() end
    end
    self:expect("}")
    return {type="enum", name=name, variants=variants}
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
        table.insert(cases, {value=value, body=self:parse_case_body()})
      elseif self:peek().value == "default" then
        self:next()
        self:expect(":")
        default_body = self:parse_case_body()
      else
        error("Expected case or default in switch, got " .. self:peek().value)
      end
    end
    self:expect("}")
    return {type="switch", subject=subject, cases=cases, default=default_body}
  end

  -- case body runs until the next case/default or the closing brace; no
  -- fall-through, so no `break` is needed
  function Parser:parse_case_body()
    local body = {}
    while true do
      local v = self:peek().value
      if v == "case" or v == "default" or v == "}" then break end
      table.insert(body, self:parse_statement())
      if self:peek().value == ";" then self:next() end
    end
    return body
  end

  function Parser:parse_block()
    local one = self:peek().value ~= "{"
    if not one then self:expect("{") end

    local body = {}
    while self:peek().value ~= "}" do
      table.insert(body, self:parse_statement())
      if self:peek().value == ";" then
        self:next()
        if one then break end
      end
    end
    if not one then self:expect("}") end
    return body
  end

  function Parser:parse_struct()
    self:expect("struct")
    local name = self:expect(TokenType.Ident).value
    self:expect("{")

    local fields = {}
    while self:peek().value ~= "}" do
      local field_type = self:parse_type()

    -- Parse multiple field names separated by commas
      repeat
        local field_name = self:expect(TokenType.Ident).value
        table.insert(fields, {type=field_type, name=field_name})
      until self:peek().value ~= "," or not self:next()
      self:expect(";")
    end

    self:expect("}")

    return {type = "struct",name=name, fields=fields}
  end

  function Parser:parse_type()
    local base = self:expect(TokenType.Ident).value
    if self:peek().value == "[" then
      self:next()
      local size = self:expect(TokenType.Number).value
      self:expect("]")
      return {type = "arraytype", base = base, size = tonumber(size)}
    end
    return {type="type", name=base}
  end

  function Parser:parse_typedef()
    self:expect("typedef")
    local base = self:parse_type()
    local alias = self:expect(TokenType.Ident).value
    self:expect(";")
    return {type="typedef",alias=alias,base=base}
  end

  function Parser:parse_declaration()
    -- Parse the common type for all vars
    local var_type = self:parse_type()
    local decls = {}

    repeat
      -- Parse variable name
      local var_name = self:expect(TokenType.Ident).value

      -- Optional initializer for this variable
      local init = nil
      if self:peek().value == "=" then
        self:next() -- consume '='
        init = self:parse_expression()
      end

      table.insert(decls, {type = "decl", varType = var_type, name = var_name, value = init})
    until self:peek().value ~= "," or not self:next()

    self:expect(";")

    -- Return all declarations as a block or list
    return decls
  end

  function Parser:parse_function()
    -- 1. Match the 'fn' keyword
    self:expect("fn")

    -- 2. Parse return types (comma-separated identifiers)
    local return_types = {}
    repeat
      local tok = self:expect(TokenType.Ident)
      table.insert(return_types, tok.value)
    until self:peek().value ~= "," or not self:next()

    -- 3. Parse function name
    local name = self:expect(TokenType.Ident).value

    -- 4. Parse parameter list
    self:expect("(")
    local params = {}
    if self:peek().value ~= ")" then
      repeat
        local param_type = self:expect(TokenType.Ident).value
        local param_name = self:expect(TokenType.Ident).value
        table.insert(params, { type = param_type, name = param_name })
      until self:peek().value ~= "," or not self:next()
    end
    self:expect(")")

    -- 5. Parse function body
    local body = self:parse_block()

    return {type="function", name=name, returnTypes=return_types, params=params, body=body}
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
    return {type="if", cond=cond, thenBranch=then_branch, elseBranch=else_branch}
  end

  function Parser:parse_for()
    self:expect("for")

    -- Parse init statement. A declaration init already consumes its own
    -- terminating ';' (and returns a decl list with no .type); an expression
    -- init does not, so only expect ';' in that case.
    local init = self:parse_statement()
    if init.type then self:expect(";") end

    -- Parse condition
    local cond = self:parse_expression()
    self:expect(";")
    -- Parse update expression (treat as a statement, e.g., assignment)
    local update = self:parse_statement()
    -- Parse body
    local body = self:parse_block()
    return {type="for", init=init, cond=cond, update=update, body=body}
  end

  function Parser:parse()
    local program = {}
    while self:peek().type ~= TokenType.EOF do
      table.insert(program, self:parse_statement())
      if self:peek().value == ";" then self:next() end
    end
    return {type="program", body=program}
  end

return Parser
