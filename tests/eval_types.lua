-- Type-name features: `typedef` aliasing a base type (as a var type, a param
-- type and a return type), and enum variants auto-numbering from 0. Both are
-- erased to plain ints at runtime -- these pin that the names parse and the
-- values land where the README documents them.
local E = require("tests/eval")

local function eq(src, expected, label)
	local got = E.run(src)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, got))
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
eq("enum C { Red, Green, Blue } fn int main() { return Red }", 0, "enum first is 0")
eq("enum C { Red, Green, Blue } fn int main() { return Green }", 1, "enum second is 1")
eq("enum C { Red, Green, Blue } fn int main() { return Blue }", 2, "enum third is 2")

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

print("ok")
