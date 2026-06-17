-- Exception edge cases: throw across a call boundary, catch binding the
-- thrown value, `except` as a catch synonym, normal (non-throwing) path skips
-- the handler, and an uncaught throw propagates out as a failure.
local E = require("tests/eval")

local function eq(src, expected, label)
	local got = E.run(src)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, got))
	end
end

-- throw inside a callee is caught in the caller's try; handler runs
eq(
	[[
  fn int risky() { throw 42 }
  fn int main() {
    try { risky() } catch e { return e }
    return 0
  }
]],
	42,
	"throw caught across call, value bound"
)

-- string payload, concatenated in the handler (asserts via captured print)
do
	local _, out = E.run([[
    fn int risky() { throw "boom" }
    fn int main() {
      try { risky() } catch e { print("got " + e) }
      return 0
    }
  ]])
	if out[1] ~= "got boom" then
		error(
			"string throw payload: expected 'got boom', got "
				.. tostring(out[1])
		)
	end
end

-- `except` is an accepted spelling of `catch`
eq(
	[[
  fn int main() {
    try { throw 5 } except e { return e * 2 }
    return 0
  }
]],
	10,
	"except alias"
)

-- no throw: handler body is skipped entirely
eq(
	[[
  fn int main() {
    int x = 1;
    try { x = 2 } catch e { x = 99 }
    return x
  }
]],
	2,
	"no throw skips handler"
)

-- a `return` inside the try body returns from the function (not swallowed)
eq(
	[[
  fn int pick(int x) {
    try {
      if x > 0 { return 10 }
      return 20
    } catch e { return 30 }
  }
  fn int main() { return pick(5) }
]],
	10,
	"return inside try body propagates"
)

-- multi-value return inside a try body keeps both values
eq(
	[[
  fn int, int two() {
    try { return 7, 9 } catch e { return 0, 0 }
  }
  fn int main() { int a, b = two(); return a * 10 + b }
]],
	79,
	"multi-return inside try body"
)

-- uncaught throw propagates out of the program as an error
if not E.fails("fn int main() { throw 1 }") then
	error("uncaught throw: expected failure")
end

print("ok")
