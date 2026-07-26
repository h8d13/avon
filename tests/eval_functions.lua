-- Function edge cases: multiple return + destructuring, missing-arg default,
-- single-expression bodies, recursion, entry args, and call ordering.
local E = require("tests/eval")

local function eq(src, expected, label, entry, args)
	local got = E.run(src, entry, args)
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

-- multiple return values, destructured into two decls
eq(
	[[
  fn int, int divmod(int a, int b) return a / b, a % b;
  fn int main() {
    int q, r = divmod(17, 5);
    return q * 10 + r
  }
]],
	32,
	"destructure multi-return (q=3,r=2)"
)

-- only the primary return is kept when destructuring fewer names
eq(
	[[
  fn int, int two() return 7, 9;
  fn int main() { int a = two(); return a }
]],
	7,
	"single name takes primary return"
)

-- a trailing call in a `return` fills the declared slots left after it, the
-- way Lua expands the last expression of a list. Clamping it (what expression
-- position does) would nil-fill everything past the first value.
eq(
	[[
  fn int, int two() return 3, 4;
  fn int, int fwd() { return two() }
  fn int main() { int a, b = fwd(); return a * 10 + b }
]],
	34,
	"a return forwards every value of a trailing call"
)

-- only the LAST expression expands, so the leading values keep their slots
eq(
	[[
  fn int, int two() return 3, 4;
  fn int, int, int mixed() { return 9, two() }
  fn int main() { int a, b, c = mixed(); return a * 100 + b * 10 + c }
]],
	934,
	"a leading value keeps its slot ahead of an expanding call"
)

-- forwarding stops at the declared arity: a callee returning more than the
-- caller declares must not leak the extra values
eq(
	[[
  fn int, int, int three() return 1, 2, 5;
  fn int, int narrow() { return three() }
  fn int main() { int a, b = narrow(); return a * 10 + b }
]],
	12,
	"forwarding respects the caller's declared arity"
)

-- a host callee has not narrowed anything on its own way out, so its values
-- are captured and narrowed per declared slot -- modf returns 3.0 and 0.7
eq(
	[[
  import math
  fn int, int split() { return math.modf(3.7) }
  fn int main() { int a, b = split(); return a * 10 + b }
]],
	30, -- 3 and 0.7 -> 0
	"a host multi-return narrows into int slots"
)
eq(
	[[
  import math
  fn int, float keep() { return math.modf(3.7) }
  fn int main() {
    float a, b = keep();
    return a * 10 + (b > 0.5 ? 1 : 0)
  }
]],
	31, -- slot 1 narrowed to 3, slot 2 kept 0.7
	"only the int slots of a host multi-return narrow"
)

-- an int param narrows its argument at the call site, so the body's int tag
-- describes what the parameter actually holds
eq(
	[[
  import _G
  fn int takes(int n) { return n * 10 + 1 }
  fn int main() { return takes(_G.rawequal(1, 2)) }
]],
	1,
	"a host boolean narrows into an int param"
)
eq(
	[[
  import math
  fn int div(int a, int b) { return a / b }
  fn int main() { return div(math.sqrt(100), 3) }
]],
	3, -- 10 / 3 truncating, not 10.0 / 3
	"a host float narrows into an int param before int division"
)

-- missing trailing arg defaults to 0
eq(
	[[
  fn int add(int a, int b) return a + b;
  fn int main() { return add(5) }
]],
	5,
	"missing arg defaults to 0"
)

-- single-expression (brace-less) function body
eq(
	[[
  fn int id(int x) return x;
  fn int main() { return id(42) }
]],
	42,
	"brace-less single-expr body"
)

-- recursion: factorial 5 = 120
eq(
	[[
  fn int fact(int n) {
    if n <= 1 { return 1 }
    return n * fact(n - 1)
  }
  fn int main() { return fact(5) }
]],
	120,
	"recursion"
)

-- nested calls evaluate inner first; arg order preserved
eq(
	[[
  fn int sub(int a, int b) return a - b;
  fn int main() { return sub(sub(10, 3), 2) }
]],
	5,
	"nested calls, left arg order"
)

-- entry-point integer args are bound positionally
eq(
	[[
  fn int main(int x, int y) { return x * 100 + y }
]],
	304,
	"entry args bound",
	"main",
	{ 3, 4 }
)

print("ok")
