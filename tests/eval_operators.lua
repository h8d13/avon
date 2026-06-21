-- Operator edge cases: precedence, truncation, short-circuit shape, bitwise,
-- unary, ternary. Run end-to-end and assert the returned int.
local E = require("tests/eval")

local function eq(src, expected, label)
	local got = E.run(src)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, got))
	end
end

local function main(expr) return "fn int main() { return " .. expr .. " }" end

-- arithmetic precedence: * before +, then - left-assoc
eq(main("2 + 3 * 4"), 14, "mul before add")
eq(main("20 - 5 - 3"), 12, "sub left assoc")
eq(main("(2 + 3) * 4"), 20, "parens override")

-- integer division truncates toward zero; modulo sign follows dividend. The
-- helpers inline the sign-aware round (no __trunc hop), so the negative cases
-- below pin that truncation -- not flooring -- survives in every sign quadrant.
eq(main("7 / 2"), 3, "int div trunc")
eq(main("-7 / 2"), -3, "neg int div trunc toward zero")
eq(main("7 / -2"), -3, "pos/neg div trunc toward zero")
eq(main("-7 / -2"), 3, "neg/neg div trunc toward zero")
eq(main("7 % 3"), 1, "mod")
eq(main("-7 % 3"), -1, "neg mod follows dividend")
eq(main("7 % -3"), 1, "pos mod neg divisor follows dividend")
eq(main("-7 % -3"), -1, "neg mod neg divisor follows dividend")

-- comparison yields 1/0, usable as int
eq(main("3 < 5"), 1, "lt true is 1")
eq(main("5 < 3"), 0, "lt false is 0")
eq(main("4 == 4"), 1, "eq")
eq(main("4 != 4"), 0, "ne")

-- logical: result is 1/0
eq(main("1 && 0"), 0, "and")
eq(main("0 || 5"), 1, "or coerces truthy to 1")
eq(main("!0"), 1, "not zero")
eq(main("!5"), 0, "not nonzero")

-- short-circuit: the RHS is skipped once the result is decided, so a throwing
-- RHS is never reached
eq(
	[[
  fn int crash() { throw 1 }
  fn int main() { return 1 || crash() }
]],
	1,
	"|| skips RHS when LHS is true"
)
eq(
	[[
  fn int crash() { throw 1 }
  fn int main() { return 0 && crash() }
]],
	0,
	"&& skips RHS when LHS is false"
)

-- the RHS still runs when the result is undecided
eq(
	[[
  fn int crash() { throw 1 }
  fn int main() {
    int r = 0;
    try { r = 1 && crash() } catch e { r = 42 }
    return r
  }
]],
	42,
	"&& evaluates RHS when LHS is true"
)

-- the practical payoff: a guard `cond && use(p)` where use(p) faults on a bad
-- p. The guard being false skips use(p), so no fault -- the whole point.
eq(
	[[
  fn int strict(int p) { if p == 0 { throw 1 } return p }
  fn int main() {
    int p = 0;
    int ok = 5;
    if p != 0 && strict(p) > 0 { ok = 1 }
    return ok
  }
]],
	5,
	"&& guards a faulting RHS (strict not called when p == 0)"
)

-- prove no side effect fires on the skipped branch (neither RHS runs)
do
	local _, out = E.run([[
    fn int noise() { print("ran"); return 1 }
    fn int main() { int a = 1 || noise(); int b = 0 && noise(); return a + b }
  ]])
	if #out ~= 0 then
		error("short-circuit: RHS ran, saw output: " .. table.concat(out, ","))
	end
end

-- bitwise
eq(main("1 << 4"), 16, "shl")
eq(main("255 >> 4"), 15, "shr")
eq(main("6 & 3"), 2, "band")
eq(main("6 | 1"), 7, "bor")
eq(main("6 ^ 3"), 5, "bxor")
eq(main("~0"), -1, "bnot")

-- unary minus binds tighter than binary
eq(main("-3 + 5"), 2, "unary minus then add")
eq(main("- -4"), 4, "double negate")

-- ternary, including nesting
eq(main("3 > 7 ? 1 : 2"), 2, "ternary false")
eq(main("7 > 3 ? 1 : 2"), 1, "ternary true")
eq(main("1 ? 2 ? 10 : 20 : 30"), 10, "nested ternary")

-- compound assignment desugars and returns updated value via the var
eq(
	"fn int main() { int x = 10; x += 5; x *= 2; x -= 3; return x }",
	27,
	"compound assign chain"
)
eq("fn int main() { int x = 17; x %= 5; return x }", 2, "compound mod assign")
eq("fn int main() { int x = 20; x /= 4; return x }", 5, "compound div assign")

-- prefix ++ mutates in place; there is no `--` (it lexes as a comment), so
-- decrement is `-= 1`
eq("fn int main() { int x = 5; ++x; ++x; return x }", 7, "prefix incr")
eq("fn int main() { int x = 5; x -= 1; return x }", 4, "decrement via -= 1")

print("ok")
