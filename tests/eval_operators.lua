-- Operator edge cases: precedence, truncation, short-circuit shape, bitwise,
-- unary, ternary. Run end-to-end and assert the returned int.
local E = require("tests/eval")

local function eq(src, expected, label)
	local got = E.run(src)
	if got ~= expected then
		error(
			string.format(
				"%s: expected %q, got %q",
				label,
				expected,
				got
			)
		)
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
		error(
			"short-circuit: RHS ran, saw output: "
				.. table.concat(out, ",")
		)
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

-- A ternary compiles to `c and (A) or (B)` when A is provably a number or
-- string. That shape silently returns B for a falsy A, so these pin the arms
-- Nova cannot prove: `null` is Lua nil, and a host predicate hands back a Lua
-- boolean. Taking the then-branch must win regardless of what is in it.
eq(
	"fn int main() { return 1 ? null : 5 }",
	0, -- null reaches the int return and narrows to 0, NOT the else 5
	"ternary with null in the then-branch takes the then-branch"
)
eq(
	"fn int main() { return 0 ? null : 5 }",
	5,
	"ternary with null still takes the else-branch when false"
)
eq(
	[[
  import _G
  fn int main() { return 1 ? _G.rawequal(1, 2) : 9 }
]],
	0, -- false narrows to 0; the else 9 would mean the arm was skipped
	"ternary with a host boolean in the then-branch"
)
-- a non-int slot does not narrow, so a falsy host value reaches it intact:
-- the then-arm was taken iff the string "else" did NOT land in s
eq(
	[[
  import _G
  fn int main() {
    str s = 1 ? _G.rawequal(1, 2) : "else";
    if s { return 1 }
    return 0
  }
]],
	0,
	"a falsy host value in a ternary arm is not replaced by the else"
)

-- exactly one arm is evaluated: the untaken side must not run. `10 / x` would
-- raise on x = 0 if the ternary lost its short-circuit
eq(
	[[
  fn int safediv(int x) { return x != 0 ? 10 / x : -1 }
  fn int main() { return safediv(0) * 100 + safediv(5) }
]],
	-98, -- -1 * 100 + 2
	"ternary evaluates only the taken arm"
)

-- `null` is false in a condition, as in C, and as Nova's own 0-is-false rule
-- implies. A bare `(v) ~= 0` would call nil truthy
eq(
	"fn int main() { if null { return 1 } return 0 }",
	0,
	"null is false in a condition"
)
eq(
	[[
  import _G
  fn int main() { if _G.rawequal(1, 2) { return 1 } return 0 }
]],
	0,
	"a host false is false in a condition"
)
eq(
	[[
  import _G
  fn int main() { if _G.rawequal(1, 1) { return 1 } return 0 }
]],
	1,
	"a host true is true in a condition"
)

-- a declared int narrows on assignment, not only at its declaration, so the
-- typeenv tag every later is_int decision reads stays honest
eq(
	[[
  import _G
  fn int main() { int x = 0; x = _G.rawequal(1, 2); return x }
]],
	0,
	"assignment into an int slot narrows"
)
eq(
	[[
  import _G
  fn int main() { int[4] xs; xs[1] = _G.rawequal(1, 2); return xs[1] }
]],
	0,
	"assignment into an int array cell narrows"
)
eq(
	[[
  import math
  fn int main() { int x = 0; x = math.sqrt(10); return x * 10 }
]],
	30,
	"assignment truncates a host float"
)

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
