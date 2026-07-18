-- File-scope variables: top-level decls become chunk locals every function
-- closes over. Initializers run after the function definitions (so they may
-- call user functions); params and locals shadow. Also covers the optional
-- declaration semicolon, since file scope is where it reads most natural.
local E = require("tests/eval")

local function eq(src, expected, label)
	local got = E.run(src)
	if got ~= expected then
		error(string.format("%s: expected %s, got %s", label, expected, got))
	end
end

local function fails(src, label)
	if not E.fails(src) then
		error(label .. ": expected a compile error, but it ran")
	end
end

-- a file-scope int is visible in every function
eq(
	[[
  int times = 10;
  fn int main() { return 40 * times + 20 }
]],
	420,
	"file-scope int read"
)

-- mutable: one function writes, another observes the write
eq(
	[[
  int count = 0;
  fn int bump() { count = count + 1; return count }
  fn int main() { bump(); bump(); return count }
]],
	2,
	"file-scope mutation across functions"
)

-- str file var keeps string typing (`+` concatenates, not adds)
eq(
	[[
  str greet = "hi ";
  fn str main() { return greet + "there" }
]],
	"hi there",
	"file-scope str concatenation"
)

-- initializers run after function definitions: calling a user fn is fine,
-- including the destructuring form
eq(
	[[
  int a, b = pair();
  fn int, int pair() { return 3, 4 }
  fn int main() { return a * 10 + b }
]],
	34,
	"file-scope destructure from user fn"
)

-- file-scope arrays work like local ones (element default-read is 0)
eq(
	[[
  int[4] xs;
  fn int fill() { xs[0] = 7; return 0 }
  fn int main() { fill(); return xs[0] + xs[1] }
]],
	7,
	"file-scope array"
)

-- params and locals shadow the file var; the file var survives underneath
eq(
	[[
  int x = 100;
  fn int shadow(int x) { return x }
  fn int main() { int r = shadow(5); return r + x }
]],
	105,
	"param shadows file var"
)

-- an unknown type name defaults to int (`local` is not special)
eq(
	[[
  local times = 10;
  fn int main() { return 40 * times + 20 }
]],
	420,
	"unknown type name defaults to int"
)

-- declaration semicolons are optional, and several decls share a line
eq(
	[[
  int fourty = 40 int twenty = 20
  fn int main() {
    int two = 2
    return fourty * 10 + twenty + two
  }
]],
	422,
	"optional decl semicolons"
)

-- writing through a call result (`slot()[0] = v`) after another statement:
-- the emitted '('-led lvalue must not glue onto the previous line as a call
eq(
	[[
  int[2] cells;
  fn int slot() { return cells }
  fn int main() {
    int lo = 5;
    slot()[0] = lo;
    slot()[1] = lo + 2;
    return cells[0] * 10 + cells[1]
  }
]],
	57,
	"paren-led index assignment after a statement"
)

-- the unbound-name check still fires on a typo'd file var read
fails(
	[[
  int count = 5;
  fn int main() { return cnt }
]],
	"typo of a file-scope name"
)

print("ok")
