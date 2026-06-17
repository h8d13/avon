-- Function edge cases: multiple return + destructuring, missing-arg default,
-- single-expression bodies, recursion, entry args, and call ordering.
local E = require("tests/eval")

local function eq(src, expected, label, entry, args)
	local got = E.run(src, entry, args)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, got))
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
