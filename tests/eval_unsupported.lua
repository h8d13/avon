-- Pins features that are still not implemented, so the gap stays visible and a
-- future implementation flips a failing assertion. (Now-implemented and thus
-- REMOVED from here: `--` line comments, iterator-form for, nested index
-- g[a][b], call-result index row()[0] -- all have positive tests now.)
-- Remaining gap:
--   - brace-less `if` then-branch with no `;` before the next statement: the
--     following statement is mis-parsed (silent wrong result, see below)
local E = require("tests/eval")

local function fails(src, label)
	if not E.fails(src) then
		error(label .. ": expected failure but it ran (gap closed?)")
	end
end

-- asserts the program runs but returns the wrong value (silent mis-parse, not
-- a hard error) -- the worst failure kind, so it is pinned explicitly.
local function wrong(src, bad, label)
	local got = E.run(src)
	if got ~= bad then
		error(
			string.format(
				"%s: expected the known-bad %q, got %q (behavior "
					.. "changed -- update tests)",
				label,
				bad,
				got
			)
		)
	end
end

-- brace-less `if ... else` needs a `;` before `else`
fails(
	[[
  fn int m(int x) {
    if x > 0 return 1
    else return 0
  }
  fn int main() { return m(5) }
]],
	"brace-less if/else without semicolon"
)

-- brace-less `if` then-branch with no `;`, followed by another statement:
-- parses, but the trailing statement is lost. fact(5) should be 120; the
-- un-terminated base case makes it return 0.
wrong(
	[[
  fn int fact(int n) {
    if n <= 1 return 1
    return n * fact(n - 1)
  }
  fn int main() { return fact(5) }
]],
	0,
	"brace-less if swallows next statement"
)

print("ok")
