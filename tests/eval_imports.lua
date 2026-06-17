-- Import edge cases: `import math` exposes host functions as math.fn(...).
-- Only the stdlib `math` module is asserted here so the test has no external
-- (luarocks) dependency; the wiring is identical for require()-able rocks.
local E = require("tests/eval")

local function eq(src, expected, label)
	local got = E.run(src)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, got))
	end
end

-- qualified call into an imported module
eq(
	[[
  import math
  fn int main() { return math.floor(3.9) }
]],
	3,
	"math.floor"
)

eq(
	[[
  import math
  fn int main() { return math.ceil(3.1) }
]],
	4,
	"math.ceil"
)

-- imported function used inside an expression
eq(
	[[
  import math
  fn int hypot(int a, int b) { return math.sqrt(a * a + b * b) }
  fn int main() { return hypot(3, 4) }
]],
	5,
	"math.sqrt in expression (3,4,5)"
)

-- `as` binds the module under an alias prefix
eq(
	[[
  import math as m
  fn int main() { return m.floor(3.9) }
]],
	3,
	"import math as m"
)

-- avon binds modules as Lua globals, so `math` (a real Lua global) stays
-- reachable even when imported under an alias -- you cannot hide it. A
-- non-global luarocks module would only be reachable under its bound name.
eq(
	[[
  import math as m
  fn int main() { return m.floor(3.9) + math.ceil(0.1) }
]],
	4,
	"original math still reachable as a Lua global"
)

print("ok")
