local Parser = require("lang/parser")
local Codegen = require("codegen/codegen")

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label, expected, actual))
  end
end

-- 1-D array: declare, store, load. Address is base + index * WORD(4).
local code = [[
  fn int main() {
    int[4] xs;
    xs[0] = 7;
    return xs[0]
  }
]]

local ast = Parser:new(code):parse()
local insns = Codegen.new():generate(ast.body)

local expected = {
  "main:",
  "ALLOC r1, 16",   -- 4 elements * 4 bytes
  "MOV r2, 0",      -- index 0
  "MOV r3, 4",      -- WORD
  "MUL r3, r2",     -- offset = WORD * index
  "MOV r4, r1",     -- addr = base
  "ADD r4, r3",     -- addr += offset
  "MOV r5, 7",      -- value
  "STORE [r4], r5",
  "MOV r6, 0",      -- reload index 0
  "MOV r7, 4",
  "MUL r7, r6",
  "MOV r8, r1",
  "ADD r8, r7",
  "LOAD r9, [r8]",
  "MOV r0, r9",     -- return value
  "RET",
}

assert_equal(#insns, #expected, "instruction count")
for i, expected_insn in ipairs(expected) do
  assert_equal(insns[i], expected_insn, "instruction " .. i)
end

-- index-as-lvalue is reachable; multidim and array-as-value are rejected.
local function rejects(src, label)
  local ok = pcall(function() Codegen.new():generate(Parser:new(src):parse().body) end)
  if ok then error(label .. ": expected codegen to reject") end
end

rejects("fn int f() { int a = m[i][j]; return a }", "nested index")
rejects("fn int f() { int[2] xs; return xs }", "array as value")

print("ok")
