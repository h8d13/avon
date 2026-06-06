local Codegen = {}
Codegen.__index = Codegen

function Codegen.new()
  return setmetatable({
    instructions = {},
    regCount = 0,
    env = {},   -- varName -> register
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
    local r = self.env[node.name]
    if not r then
      error("Undefined identifier: "..tostring(node.name))
    end
    return r
  elseif node.type == "binary" then
    if node.op == "=" then
      if node.left.type ~= "identifier" then
        error("Assignment target must be an identifier")
      end
      local dest = self.env[node.left.name]
      if not dest then
        error("Undefined identifier: "..tostring(node.left.name))
      end
      local right = self:gen_expression(node.right)
      self:emit(string.format("MOV %s, %s", dest, right))
      return dest
    end

    local left = self:gen_expression(node.left)
    local right = self:gen_expression(node.right)
    -- Assume left is dest, operate on it with right
    local op_map = {["+"]="ADD", ["-"]="SUB", ["*"]="MUL", ["/"]="DIV"}
    local op = op_map[node.op]
    if not op then
      error("Unsupported binary operator: "..tostring(node.op))
    end
    self:emit(string.format("%s %s, %s", op, left, right))
    return left
  else
    error("Unsupported expression type: "..tostring(node.type))
  end
end

function Codegen:gen_declaration(node)
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

function Codegen:gen_block(block)
  local returns = false
  for _, stmt in ipairs(block) do
    returns = self:gen_statement(stmt) or false
  end
  return returns
end

function Codegen:gen_statement(node)
  if not node.type then
    local returns = false
    for _, stmt in ipairs(node) do
      returns = self:gen_statement(stmt) or false
    end
    return returns
  elseif node.type == "decl" then
    self:gen_declaration(node)
  elseif node.type == "expression" then
    self:gen_expression(node.expr)
  elseif node.type == "if" then
    return self:gen_if(node)
  elseif node.type == "block" then
    self:gen_block(node.statements)
    local ret_reg = self:gen_expression(node.value)
    self:emit(string.format("MOV r0, %s", ret_reg)) -- r0 = return register
  elseif node.type == "return" then
    if node.value then
      local ret_reg = self:gen_expression(node.value)
      self:emit(string.format("MOV r0, %s", ret_reg))
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
  for _, node in ipairs(ast) do
    self:gen_statement(node)
  end
  return self.instructions
end

return Codegen
