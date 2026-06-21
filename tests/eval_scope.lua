-- Unbound-name detection: a bare name that resolves to nothing (a typo) is a
-- compile error, not a silent nil read / nil-call at run time. The check clears
-- every real binding form, so these also guard against false positives -- the
-- failure mode that would reject valid programs.
local E = require("tests/eval")

local function eq(src, expected, label)
	local got = E.run(src)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, got))
	end
end

local function fails(src, label)
	if not E.fails(src) then
		error(label .. ": expected a compile error, but it ran")
	end
end

-- typo in a variable read: `cnt` was never declared
fails("fn int main() { int count = 5; return cnt }", "unknown variable read")

-- typo in a function call: `helpr` is not a function
fails(
	[[
  fn int helper(int x) { return x }
  fn int main() { return helpr(3) }
]],
	"unknown function call"
)

-- an alias whose target is a nonexistent function: the pre-tokenize rewrite
-- turns the call into one on `foo`, which is now caught at compile time instead
-- of surfacing as a runtime nil-call (the old, documented behavior)
fails(
	[[
  __foo = bar
  fn int main() { return bar(3) }
]],
	"aliased target to a missing function"
)

-- ---- false-positive guards: every real binding form must pass ----

-- a function may be called before it is declared (names are collected up front)
eq(
	[[
  fn int main() { return helper(21) }
  fn int helper(int x) { return x * 2 }
]],
	42,
	"forward function reference"
)

-- a catch variable is bound inside its handler
eq("fn int main() { try { throw 7 } catch e { return e } return 0 }", 7, "catch var")

-- an iterator-form loop variable is bound in the body
eq(
	[[
  fn int next(int box) { int v = box[0]; box[0] = v - 1; return v }
  fn int main() {
    int[1] c; c[0] = 3;
    int s = 0;
    for int x = next(c) { s += x }
    return s
  }
]],
	6,
	"forin loop var (3+2+1)"
)

-- enum constants resolve as bound names
eq("enum C { Red, Green } fn int main() { return Green }", 1, "enum const")

-- a qualified host call rides on its base resolving through the env/_G chain
eq(
	[[
  import math
  fn int main() { return math.floor(9.9) }
]],
	9,
	"qualified host name (math.floor)"
)

print("ok")
