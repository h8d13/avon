local Parser = require("lang/parser")
local Codegen = require("codegen/codegen")

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label, expected, actual))
  end
end

local code = [[
  fn int test(int x) {
    return x + 2
  }
]]

local parser = Parser:new(code)
local ast = parser:parse()

local codegen = Codegen:new()
local insns = codegen:generate(ast.body)

local expected = {
  "test:",
  "MOV r1, arg_x",
  "MOV r2, 2",
  "ADD r1, r2",
  "MOV r0, r1",
  "RET",
}

assert_equal(#insns, #expected, "instruction count")
for i, expected_insn in ipairs(expected) do
  assert_equal(insns[i], expected_insn, "instruction " .. i)
end

print("ok")
