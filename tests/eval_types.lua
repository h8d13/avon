-- Type-name features: `typedef` aliasing a base type (as a var type, a param
-- type and a return type), and enum variants auto-numbering from 0. Both are
-- erased to plain ints at runtime -- these pin that the names parse and the
-- values land where the README documents them.
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

-- typedef as a local var's type: `myint` is just `int`
eq(
	"typedef int myint; fn int main() { myint x = 5; return x + 1 }",
	6,
	"typedef as var type"
)

-- typedef as both the return type and a parameter type across a call boundary
eq(
	[[
  typedef int num;
  fn num dbl(num x) { return x * 2 }
  fn int main() { return dbl(21) }
]],
	42,
	"typedef as param and return type"
)

-- enum variants number from 0 in declaration order (Red=0, Green=1, Blue=2)
eq(
	"enum C { Red, Green, Blue } fn int main() { return Red }",
	0,
	"enum first is 0"
)
eq(
	"enum C { Red, Green, Blue } fn int main() { return Green }",
	1,
	"enum second is 1"
)
eq(
	"enum C { Red, Green, Blue } fn int main() { return Blue }",
	2,
	"enum third is 2"
)

-- read together so the ordering is pinned as one value, and a trailing comma
-- after the last variant (the README spelling) is accepted
eq(
	"enum C { Red, Green, Blue, } fn int main() { return Red * 100 + Green * 10 + Blue }",
	12,
	"enum order with trailing comma"
)

-- uninitialized scalars default by type: numerics read 0, strings read ""
eq("fn int main() { int x; return x }", 0, "uninitialized int reads 0")
eq("fn float main() { float f; return f }", 0, "uninitialized float reads 0")
eq(
	[[
  fn str tag() { str s; return s + "empty" }
  fn str main() { return tag() }
]],
	"empty",
	"uninitialized str reads empty string"
)

-- A declared `int` constrains the value at the boundary, it does not merely
-- document it. Inside Nova the static type is already known, so these pin the
-- cases it cannot prove: values arriving from a host module, and float sources
-- narrowing into an int slot.
eq(
	[[
  import math
  fn int hyp(int a, int b) { return math.sqrt(a * a + b * b) }
  fn int main() { return hyp(2, 5) }
]],
	5, -- sqrt(29) = 5.385...
	"host float truncates into an int return"
)

-- a host predicate hands back a Lua boolean; Nova's own truth values are 1/0,
-- so an `int` signature must not leak one through
eq(
	[[
  import _G
  fn int same(int a, int b) { return _G.rawequal(a, b) }
  fn int main() { return same(3, 3) * 10 + same(3, 4) }
]],
	10,
	"host boolean folds to 1/0 through an int return"
)

-- truncation is toward zero (C's rule, matching int `/`), not floor
eq(
	"fn int trunc() { float f = -3.9; return f } fn int main() { return trunc() }",
	-3,
	"int return truncates toward zero"
)

-- the declared type of a local narrows its initializer too, so the type tag it
-- seeds stays truthful for later arithmetic
eq(
	[[
  import math
  fn int main() { int n = math.sqrt(10); return n * 10 }
]],
	30, -- 3, not 3.162...
	"host float truncates into an int local"
)

-- narrowing is int-only: a float slot keeps its fraction
eq(
	[[
  import math
  fn float main() { float f = math.sqrt(2); return f > 1.414 && f < 1.415 }
]],
	1,
	"float slot is not narrowed"
)

-- `int` doubles as this language's catch-all declared type: the README's
-- store.nova returns an array from `fn int`, so non-numeric values must pass
-- through the coercion untouched
eq(
	[[
  int[4] cells;
  fn int slot() return cells
  fn int main() { slot()[2] = 9; return slot()[2] }
]],
	9,
	"an array still returns through an int signature"
)

-- but a PROVABLY-string value in an int slot is a static type error, not a
-- silent pass-through: `fn int` returning a string and `int x = "..."` are both
-- rejected at compile time with a positioned message. The annotation is
-- load-bearing wherever the value's type is statically known (unlike the array
-- above, whose type the frontend cannot prove, so it still rides through).
local function type_error(src, label)
	local ok, err = pcall(E.run, src)
	if ok then
		error(label .. ": expected a type error, but it compiled")
	end
	if
		not tostring(err):find(
			"type error: string value where int",
			1,
			true
		)
	then
		error(label .. ": unexpected message: " .. tostring(err))
	end
end

type_error(
	'fn int who() { return "nope" } fn int main() { return who() }',
	"string returned from fn int"
)
type_error(
	'fn int main() { int x = "nope"; return x }',
	"string assigned to an int local"
)

print("ok")
