-- Control-flow edge cases: if/else (braced and brace-less), else-if chains,
-- C-style for (incl. zero-iteration and break/continue), iterator-form for
-- (`for T x = expr { ... }`, looping while expr is non-zero), switch (match,
-- default, no fall-through, enum subject).
local E = require("tests/eval")

local function eq(src, expected, label)
	local got = E.run(src)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, got))
	end
end

-- if/else with optional braces and optional parens on the condition
eq("fn int main() { if 1 > 0 { return 10 } else { return 20 } }", 10, "if braced true")
eq("fn int main() { if 1 < 0 { return 10 } else { return 20 } }", 20, "else branch")
eq("fn int main() { if 1 > 0 return 10; return 20 }", 10, "if braceless single stmt")
-- a brace-less branch is exactly one statement, terminator or not: the `;` is
-- optional and the branch never swallows the statement that follows it
eq(
	[[
  fn int fact(int n) {
    if n <= 1 return 1
    return n * fact(n - 1)
  }
  fn int main() { return fact(5) }
]],
	120,
	"brace-less if does not swallow the next statement"
)
-- brace-less `if ... else` works without a `;` before `else`
eq(
	[[
  fn int m(int x) {
    if x > 0 return 1
    else return 0
  }
  fn int main() { return m(5) * 10 + m(-3) }
]],
	10,
	"brace-less if/else without semicolon"
)
eq(
	[[
  fn int classify(int x) {
    if x > 0 return 1;
    else if x < 0 return 2;
    else return 0;
  }
  fn int main() { return classify(0) * 100 + classify(-4) * 10 + classify(9) }
]],
	21,
	"else-if chain picks right arm"
)

-- for: sum 0..9, classic accumulation
eq(
	[[
  fn int main() {
    int s = 0;
    for int i = 0; i < 10; ++i { s += i }
    return s
  }
]],
	45,
	"for accumulate"
)

-- for with a condition false on entry runs zero times
eq(
	[[
  fn int main() {
    int s = 100;
    for int i = 0; i < 0; ++i { s += 1 }
    return s
  }
]],
	100,
	"for zero iterations"
)

-- break exits early; sum stops at i==5
eq(
	[[
  fn int main() {
    int s = 0;
    for int i = 0; i < 10; ++i {
      if i == 5 { break }
      s += i
    }
    return s
  }
]],
	10,
	"break exits loop (0+1+2+3+4)"
)

-- continue skips the rest of the body; sum only odd indices < 10
eq(
	[[
  fn int main() {
    int s = 0;
    for int i = 0; i < 10; ++i {
      if i % 2 == 0 { continue }
      s += i
    }
    return s
  }
]],
	25,
	"continue skips evens (1+3+5+7+9)"
)

-- iterator-form for: re-evaluates the init expr each pass, binds it, runs the
-- body while non-zero. A generator holds state in a heap cell reached through
-- a pointer arg (arrays pass by base address), yielding ...,2,1 then 0 = stop.
eq(
	[[
  fn int next(int box) { int v = box[0]; box[0] = v - 1; return v }
  fn int main() {
    int[1] c; c[0] = 5;
    int sum = 0;
    for int x = next(c) { sum += x }
    return sum
  }
]],
	15,
	"iterator for sums 5+4+3+2+1, stops at 0"
)

-- break leaves the iterator loop early
eq(
	[[
  fn int next(int box) { int v = box[0]; box[0] = v - 1; return v }
  fn int main() {
    int[1] c; c[0] = 9;
    int last = 0;
    for int x = next(c) {
      if x == 6 { break }
      last = x
    }
    return last
  }
]],
	7,
	"iterator for break (last body-visited x is 7)"
)

-- a generator that is empty on entry (yields 0 first) runs the body zero times
eq(
	[[
  fn int next(int box) { int v = box[0]; box[0] = v - 1; return v }
  fn int main() {
    int[1] c; c[0] = 0;
    int n = 100;
    for int x = next(c) { n = 1 }
    return n
  }
]],
	100,
	"iterator for zero iterations when first yield is 0"
)

-- switch: matching case, default fallback, and no implicit fall-through
eq(
	[[
  fn int pick(int x) {
    switch x {
      case 1: return 10
      case 2: return 20
      default: return 99
    }
  }
  fn int main() { return pick(2) }
]],
	20,
	"switch matches case"
)
eq(
	[[
  fn int pick(int x) {
    switch x {
      case 1: return 10
      default: return 99
    }
  }
  fn int main() { return pick(7) }
]],
	99,
	"switch default"
)

-- switch over enum variant values
eq(
	[[
  enum Color { Red, Green, Blue }
  fn int main() {
    int c = Blue;
    switch c {
      case Red: return 1
      case Green: return 2
      case Blue: return 3
      default: return 0
    }
  }
]],
	3,
	"switch on enum value"
)

print("ok")
