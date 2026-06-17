-- Literal + string edge cases: char literals as int codes (incl. escapes),
-- float arithmetic, string concatenation with mixed operands, and comment
-- forms (//, /* */) being ignored by the lexer.
local E = require("tests/eval")

local function eq(src, expected, label)
  local got = E.run(src)
  if got ~= expected then
    error(string.format("%s: expected %q, got %q", label, expected, got))
  end
end

-- char literals lower to their integer code
eq("fn int main() { return 'A' }", 65, "char code A")
eq("fn int main() { return 'a' - 'A' }", 32, "char arithmetic")
eq("fn int main() { return '\\n' }", 10, "escape newline code")
eq("fn int main() { return '\\0' }", 0, "escape nul code")

-- float result flows through to the primary return verbatim
eq("fn float main() { return 3.0 / 2.0 }", 1.5, "float division")
eq("fn float main() { return 0.1 + 0.2 }", 0.1 + 0.2, "float add matches host")

-- string concat: string + string, and string + int (int stringified)
do
  local _, out = E.run([[
    fn int main() { print("a" + "b" + "c"); return 0 }
  ]])
  if out[1] ~= "abc" then error("string+string: got " .. tostring(out[1])) end
end
do
  local _, out = E.run([[
    fn int main() { print("n=" + 42); return 0 }
  ]])
  if out[1] ~= "n=42" then error("string+int: got " .. tostring(out[1])) end
end

-- both comment forms are skipped by the lexer: slash line and block
eq([[
  // slash line comment
  /* block
     comment */
  fn int main() { return 7 /* trailing */ }
]], 7, "comments ignored")

print("ok")
