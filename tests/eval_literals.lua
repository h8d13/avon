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

-- boolean literals lower to 1/0 and stay usable as ints and as conditions
eq("fn int main() { return true }", 1, "true is 1")
eq("fn int main() { return false }", 0, "false is 0")
eq("fn int main() { return !false }", 1, "not false")
eq("fn int main() { if true { return 5 } return 9 }", 5, "true as condition")

-- `null` has no literal token: it resolves as an unbound name, i.e. Lua nil.
-- The entry's `or 0` would mask that, so assert through a captured print.
do
	local _, out = E.run("fn int main() { print(null); return 0 }")
	if out[1] ~= "nil" then error("null prints nil: got " .. tostring(out[1])) end
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
-- concat of str *variables* (no literal present): needs string-type tracking,
-- not the old literal-spotting proxy
do
	local _, out = E.run([[
    fn int main() { str a = "foo"; str b = "bar"; print(a + b); return 0 }
  ]])
	if out[1] ~= "foobar" then error("str var concat: got " .. tostring(out[1])) end
end
-- accumulation loop and a str-returning function compose without a literal
do
	local _, out = E.run([[
    fn str rep(str s) { str r = ""; r = r + s; r = r + s; return r }
    fn int main() { str x = "ab"; print(rep(x) + "!"); return 0 }
  ]])
	if out[1] ~= "abab!" then error("str fn compose: got " .. tostring(out[1])) end
end

-- both comment forms are skipped by the lexer: slash line and block
eq(
	[[
  // slash line comment
  /* block
     comment */
  fn int main() { return 7 /* trailing */ }
]],
	7,
	"comments ignored"
)

print("ok")
