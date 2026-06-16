local Codegen = {}
Codegen.__index = Codegen

local WORD = 4 -- element size; arrays are word-addressed

function Codegen.new()
  return setmetatable({
    instructions = {},
    regCount = 0,
    env = {},     -- varName -> register
    consts = {},  -- enum variant -> integer value (global)
    labelCount = 0,
  }, Codegen)
end

function Codegen:next_reg()
  self.regCount = self.regCount + 1
  return "r"..self.regCount
end

function Codegen:emit(instr)
  table.insert(self.instructions, instr)
end

function Codegen:new_label(prefix)
  prefix = prefix or "L"
  self.labelCount = self.labelCount + 1
  return prefix .. tostring(self.labelCount)
end

function Codegen:gen_expression(node)
  if node.type == "literal" then
    if type(node.value) ~= "number" then
      error("Unsupported literal value: "..tostring(node.value))
    end
    local r = self:next_reg()
    self:emit(string.format("MOV %s, %s", r, node.value))
    return r
  elseif node.type == "identifier" then
    local c = self.consts[node.name]
    if c ~= nil then -- enum constant: materialize the literal
      local r = self:next_reg()
      self:emit(string.format("MOV %s, %s", r, c))
      return r
    end
    local r = self.env[node.name]
    if not r then
      error("Undefined identifier: "..tostring(node.name))
    end
    if type(r) == "table" then -- bare array name has no scalar value
      error("Cannot use array '"..node.name.."' as a value")
    end
    return r
  elseif node.type == "index" then
    local addr = self:gen_index_addr(node)
    local dst = self:next_reg()
    self:emit(string.format("LOAD %s, [%s]", dst, addr))
    return dst
  elseif node.type == "unary" then
    local r = self:gen_expression(node.right)
    local dst = self:next_reg()
    self:emit(string.format("MOV %s, 0", dst))
    if node.op == "!" then
      self:emit(string.format("EQ %s, %s", dst, r)) -- !x == (x == 0)
    elseif node.op == "~" then
      self:emit(string.format("SUB %s, %s", dst, r)) -- ~x == -x - 1
      self:emit(string.format("SUB %s, 1", dst))
    else
      self:emit(string.format("SUB %s, %s", dst, r)) -- -x == (0 - x)
    end
    return dst
  elseif node.type == "ternary" then
    local c = self:gen_expression(node.cond)
    local dst = self:next_reg()
    local elsel = self:new_label("telse")
    local endl = self:new_label("tend")
    self:emit(string.format("JZ %s, %s", c, elsel))
    self:emit(string.format("MOV %s, %s", dst, self:gen_expression(node.thenE)))
    self:emit(string.format("JMP %s", endl))
    self:emit(elsel .. ":")
    self:emit(string.format("MOV %s, %s", dst, self:gen_expression(node.elseE)))
    self:emit(endl .. ":")
    return dst
  elseif node.type == "call" then
    -- evaluate every argument first, then push them contiguously so a
    -- nested call's ARGs cannot interleave with this one's
    local argregs = {}
    for _, a in ipairs(node.args) do
      argregs[#argregs + 1] = self:gen_expression(a)
    end
    for _, r in ipairs(argregs) do
      self:emit("ARG " .. r)
    end
    local dst = self:next_reg()
    self:emit(string.format("CALL %s, %s", dst, node.name))
    return dst
  elseif node.type == "binary" then
    if node.op == "=" then
      return self:gen_assign(node)
    end

    local left = self:gen_expression(node.left)
    local right = self:gen_expression(node.right)
    local op_map = {
      ["+"]="ADD", ["-"]="SUB", ["*"]="MUL", ["/"]="DIV", ["%"]="MOD",
      ["<"]="LT", ["<="]="LE", [">"]="GT", [">="]="GE",
      ["=="]="EQ", ["!="]="NE", ["&&"]="AND", ["||"]="OR",
      ["&"]="BAND", ["|"]="BOR", ["^"]="BXOR", ["<<"]="SHL", [">>"]="SHR",
    }
    local op = op_map[node.op]
    if not op then
      error("Unsupported binary operator: "..tostring(node.op))
    end
    -- Write to a fresh register: the operands may be live variables, so the
    -- 2-operand in-place op must not clobber left.
    local dst = self:next_reg()
    self:emit(string.format("MOV %s, %s", dst, left))
    self:emit(string.format("%s %s, %s", op, dst, right))
    return dst
  else
    error("Unsupported expression type: "..tostring(node.type))
  end
end

-- Resolve a named array to its env entry {array, base, size}.
function Codegen:array_of(node)
  if node.type ~= "identifier" then
    -- nested indexing (m[i][j]) needs per-dimension strides we do not track
    error("Array base must be a named array, got "..tostring(node.type))
  end
  local a = self.env[node.name]
  if type(a) ~= "table" or not a.array then
    error("Not an array: "..tostring(node.name))
  end
  return a
end

-- Lower a 1-D index node to a register holding the element address:
-- addr = base + index * WORD. Leaves base and index registers intact.
function Codegen:gen_index_addr(node)
  local arr = self:array_of(node.array)
  local idx = self:gen_expression(node.index)
  local off = self:next_reg()
  self:emit(string.format("MOV %s, %d", off, WORD))
  self:emit(string.format("MUL %s, %s", off, idx))
  local addr = self:next_reg()
  self:emit(string.format("MOV %s, %s", addr, arr.base))
  self:emit(string.format("ADD %s, %s", addr, off))
  return addr
end

-- Assignment: scalar target is a register move, index target a STORE.
function Codegen:gen_assign(node)
  local target = node.left
  if target.type == "index" then
    local addr = self:gen_index_addr(target)
    local right = self:gen_expression(node.right)
    self:emit(string.format("STORE [%s], %s", addr, right))
    return right
  elseif target.type == "identifier" then
    local dest = self.env[target.name]
    if not dest then
      error("Undefined identifier: "..tostring(target.name))
    end
    if type(dest) == "table" then
      error("Cannot assign to array: "..tostring(target.name))
    end
    local right = self:gen_expression(node.right)
    self:emit(string.format("MOV %s, %s", dest, right))
    return dest
  end
  error("Assignment target must be an identifier or index")
end

-- `int a, b = f()` destructures when there are 2+ names, only the last
-- carries an initializer, and that initializer is a call.
function Codegen:is_destructure(decls)
  if #decls < 2 then return false end
  local last = decls[#decls]
  if not (last.value and last.value.type == "call") then return false end
  for i = 1, #decls - 1 do
    if decls[i].value then return false end -- leading vars must be uninit
  end
  return true
end

-- Run the call once, then pull result slot i into each declared name.
function Codegen:gen_destructure(decls)
  local call = decls[#decls].value
  local argregs = {}
  for _, arg in ipairs(call.args) do
    argregs[#argregs + 1] = self:gen_expression(arg)
  end
  for _, r in ipairs(argregs) do self:emit("ARG " .. r) end
  local tmp = self:next_reg()
  self:emit(string.format("CALL %s, %s", tmp, call.name))
  for i, decl in ipairs(decls) do
    local r = self:next_reg()
    self.env[decl.name] = r
    self:emit(string.format("RESULT %s, %d", r, i - 1)) -- slot i-1 of last call
  end
end

function Codegen:gen_declaration(node)
  if node.varType and node.varType.type == "arraytype" then
    if node.value then
      error("Array initializers are not supported: "..tostring(node.name))
    end
    local base = self:next_reg()
    self.env[node.name] = {array=true, base=base, size=node.varType.size}
    self:emit(string.format("ALLOC %s, %d", base, node.varType.size * WORD))
    return
  end
  local r = self:next_reg()
  self.env[node.name] = r
  if node.value then
    local val_reg = self:gen_expression(node.value)
    self:emit(string.format("MOV %s, %s", r, val_reg))
  else
    self:emit(string.format("MOV %s, 0", r)) -- default init 0
  end
end

function Codegen:gen_if(node)
  local cond_reg = self:gen_expression(node.cond)
  local else_label = self:new_label("else")
  local end_label = self:new_label("endif")

  self:emit(string.format("JZ %s, %s", cond_reg, else_label))
  local then_returns = self:gen_block(node.thenBranch)
  self:emit(string.format("JMP %s", end_label))
  self:emit(else_label .. ":")
  local else_returns = false
  if node.elseBranch then
    else_returns = self:gen_block(node.elseBranch)
  end
  self:emit(end_label .. ":")
  return then_returns and else_returns
end

-- Lower `for init; cond; update { body }` to a cond-tested loop. init and
-- update are statements (init may be a decl list); cond is an expression.
function Codegen:gen_for(node)
  self:gen_statement(node.init)
  local top = self:new_label("for")
  local done = self:new_label("endfor")
  self:emit(top .. ":")
  local cond_reg = self:gen_expression(node.cond)
  self:emit(string.format("JZ %s, %s", cond_reg, done))
  self:gen_block(node.body)
  self:gen_statement(node.update)
  self:emit(string.format("JMP %s", top))
  self:emit(done .. ":")
end

-- Lower switch to a compare chain: subject == case ? run body : next.
-- No fall-through; an unmatched value runs the default (if any).
function Codegen:gen_switch(node)
  local subj = self:gen_expression(node.subject)
  local endl = self:new_label("endsw")
  for _, c in ipairs(node.cases) do
    local cval = self:gen_expression(c.value)
    local t = self:next_reg()
    self:emit(string.format("MOV %s, %s", t, subj)) -- keep subj intact
    self:emit(string.format("EQ %s, %s", t, cval))
    local nextl = self:new_label("case")
    self:emit(string.format("JZ %s, %s", t, nextl))
    self:gen_block(c.body)
    self:emit(string.format("JMP %s", endl))
    self:emit(nextl .. ":")
  end
  if node.default then
    self:gen_block(node.default)
  end
  self:emit(endl .. ":")
end

function Codegen:gen_block(block)
  local returns = false
  for _, stmt in ipairs(block) do
    returns = self:gen_statement(stmt) or false
  end
  return returns
end

function Codegen:gen_statement(node)
  if not node.type then
    -- a decl list; `int a, b = f()` (leading vars uninit, last is a call)
    -- destructures the call's multiple return values across all the names
    if self:is_destructure(node) then
      self:gen_destructure(node)
      return false
    end
    local returns = false
    for _, stmt in ipairs(node) do
      returns = self:gen_statement(stmt) or false
    end
    return returns
  elseif node.type == "decl" then
    self:gen_declaration(node)
  elseif node.type == "expression" then
    self:gen_expression(node.expr)
  elseif node.type == "binary" or node.type == "call"
      or node.type == "index" or node.type == "identifier"
      or node.type == "literal" then
    self:gen_expression(node) -- bare expression statement (e.g. `xs[0] = 7`)
  elseif node.type == "if" then
    return self:gen_if(node)
  elseif node.type == "for" then
    self:gen_for(node)
  elseif node.type == "switch" then
    self:gen_switch(node)
  elseif node.type == "typedef" or node.type == "struct"
      or node.type == "enum" then
    -- type-level only, emits no code (enums registered in the pre-pass)
  elseif node.type == "block" then
    self:gen_block(node.statements)
    local ret_reg = self:gen_expression(node.value)
    self:emit(string.format("MOV r0, %s", ret_reg)) -- r0 = return register
  elseif node.type == "return" then
    if node.values then
      -- primary result stays in r0; extra results go to RETV slots 1..N
      self:emit(string.format("MOV r0, %s",
        self:gen_expression(node.values[1])))
      for i = 2, #node.values do
        self:emit(string.format("RETV %d, %s", i - 1,
          self:gen_expression(node.values[i])))
      end
    end
    self:emit("RET")
    return true
  elseif node.type == "function" then
    self.env = {}   -- clear env for new func
    self.regCount = 0
    self:emit(node.name .. ":")
    for _, param in ipairs(node.params) do
      local r = self:next_reg()
      self.env[param.name] = r
      -- assume parameters are passed in registers r1..rN
      self:emit(string.format("MOV %s, arg_%s", r, param.name))
    end
    if not self:gen_block(node.body) then
      self:emit("RET")
    end
  else
    error("Unknown statement type: "..tostring(node.type))
  end
  return false
end

function Codegen:generate(ast)
  -- pre-pass: register enum constants so they resolve regardless of order
  for _, node in ipairs(ast) do
    if node.type == "enum" then
      for i, variant in ipairs(node.variants) do
        self.consts[variant] = i - 1
      end
    end
  end
  for _, node in ipairs(ast) do
    self:gen_statement(node)
  end
  return self.instructions
end

return Codegen
