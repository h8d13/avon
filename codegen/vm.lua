-- Interpreter for the codegen pseudo-IR. Executes the register-machine
-- instructions directly so Nova programs can run without a native backend.
-- Instruction forms produced by codegen.lua:
--   name:              label
--   MOV d, s           d = s
--   ADD/SUB/MUL/DIV/MOD/LT/LE/GT/GE/EQ/NE/AND/OR d, s   d = d <op> s
--   JZ r, label        if r == 0 goto label
--   JMP label
--   ALLOC d, bytes     d = fresh heap address; bump heap
--   LOAD d, [a]        d = mem[a]
--   STORE [a], s       mem[a] = s
--   ARG s              queue s as the next call argument
--   CALL d, fname      d = fname(queued args)
--   RET                return r0

local VM = {}
VM.__index = VM

local function trunc(x) -- C-style integer division truncates toward zero
  return x >= 0 and math.floor(x) or math.ceil(x)
end

local function b2i(c) return c and 1 or 0 end

local function both_int(a, b)
  return math.type(a) == "integer" and math.type(b) == "integer"
end

local binops = {
  ADD = function(a, b) return a + b end,
  SUB = function(a, b) return a - b end,
  MUL = function(a, b) return a * b end,
  -- int / int truncates (C semantics); a float operand does real division
  DIV = function(a, b) return both_int(a, b) and trunc(a / b) or a / b end,
  MOD = function(a, b)
    return both_int(a, b) and a - trunc(a / b) * b or math.fmod(a, b)
  end,
  LT  = function(a, b) return b2i(a < b) end,
  LE  = function(a, b) return b2i(a <= b) end,
  GT  = function(a, b) return b2i(a > b) end,
  GE  = function(a, b) return b2i(a >= b) end,
  EQ  = function(a, b) return b2i(a == b) end,
  NE  = function(a, b) return b2i(a ~= b) end,
  AND = function(a, b) return b2i(a ~= 0 and b ~= 0) end,
  OR  = function(a, b) return b2i(a ~= 0 or b ~= 0) end,
  BAND = function(a, b) return a & b end,
  BOR  = function(a, b) return a | b end,
  BXOR = function(a, b) return a ~ b end,
  SHL  = function(a, b) return a << b end,
  SHR  = function(a, b) return a >> b end,
}

-- Split one IR line into {op, args} (or {op="LABEL", name=...}).
local function parse_insn(line)
  if line:sub(-1) == ":" then
    return {op = "LABEL", name = line:sub(1, -2)}
  end
  local op, rest = line:match("^(%S+)%s*(.*)$")
  local args = {}
  for raw in rest:gmatch("[^,]+") do
    local tok = raw:gsub("[%s%[%]]", "") -- drop spaces and memory brackets
    if tok ~= "" then args[#args + 1] = tok end
  end
  return {op = op, args = args}
end

function VM.new(insns)
  local self = setmetatable({
    code = {}, labels = {}, mem = {}, heap = 4,
  }, VM)
  for _, line in ipairs(insns) do
    local ins = parse_insn(line)
    self.code[#self.code + 1] = ins
    if ins.op == "LABEL" then
      self.labels[ins.name] = #self.code
    end
  end
  return self
end

-- An operand is an int literal, an `arg_<name>` (the Nth incoming argument,
-- bound positionally on first use), or a register name.
local function resolve(fr, o)
  local n = tonumber(o)
  if n then return n end
  if o:match("^arg_") then
    if fr.argmap[o] == nil then
      fr.nextarg = fr.nextarg + 1
      fr.argmap[o] = fr.args[fr.nextarg] or 0 -- missing arg defaults to 0
    end
    return fr.argmap[o]
  end
  return fr.reg[o]
end

-- Calls return a list of results: [1] is the primary (r0), [2..] are the
-- RETV slots used by multi-value `return a, b`.
function VM:call(fn, args)
  if fn == "print" then
    print(table.unpack(args))
    return {0}
  end
  return self:run(fn, args)
end

function VM:run(name, argvals)
  local ip = self.labels[name]
  if not ip then error("no such function: " .. tostring(name)) end
  local fr = {reg = {}, args = argvals or {}, argmap = {}, nextarg = 0,
             pending = {}, retv = {}, lastrets = {}}
  ip = ip + 1 -- skip the label line
  while true do
    local ins = self.code[ip]
    if not ins then error("execution ran off the end of " .. name) end
    local op, a = ins.op, ins.args
    if op == "LABEL" then
      ip = ip + 1
    elseif op == "MOV" then
      fr.reg[a[1]] = resolve(fr, a[2]); ip = ip + 1
    elseif binops[op] then
      fr.reg[a[1]] = binops[op](fr.reg[a[1]], resolve(fr, a[2])); ip = ip + 1
    elseif op == "JZ" then
      ip = resolve(fr, a[1]) == 0 and self.labels[a[2]] or ip + 1
    elseif op == "JMP" then
      ip = self.labels[a[1]]
    elseif op == "ALLOC" then
      fr.reg[a[1]] = self.heap; self.heap = self.heap + tonumber(a[2])
      ip = ip + 1
    elseif op == "LOAD" then
      fr.reg[a[1]] = self.mem[fr.reg[a[2]]] or 0; ip = ip + 1
    elseif op == "STORE" then
      self.mem[fr.reg[a[1]]] = resolve(fr, a[2]); ip = ip + 1
    elseif op == "ARG" then
      fr.pending[#fr.pending + 1] = resolve(fr, a[1]); ip = ip + 1
    elseif op == "CALL" then
      local res = self:call(a[2], fr.pending)
      fr.lastrets = res
      fr.reg[a[1]] = res[1] or 0
      fr.pending = {}; ip = ip + 1
    elseif op == "RESULT" then -- pull slot N of the most recent call
      fr.reg[a[1]] = fr.lastrets[tonumber(a[2]) + 1] or 0; ip = ip + 1
    elseif op == "RETV" then -- extra return value into slot N
      fr.retv[tonumber(a[1])] = resolve(fr, a[2]); ip = ip + 1
    elseif op == "RET" then
      local rets = {fr.reg["r0"] or 0}
      for slot, v in pairs(fr.retv) do rets[slot + 1] = v end
      return rets
    else
      error("VM: unknown instruction '" .. tostring(op) .. "'")
    end
  end
end

return VM
