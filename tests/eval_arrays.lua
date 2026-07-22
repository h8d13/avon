-- Array edge cases (runtime): fixed-size 1-D arrays, plus the pointer model
-- that makes an array value its base address -- so arrays return from / pass
-- to functions, a returned pointer indexes (row()[0]), and a chain indexes a
-- stored row pointer (grid[a][b]). Index by expression, fill/sum in loops.
local E = require("tests/eval")

local function eq(src, expected, label)
	local got = E.run(src)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, got))
	end
end

-- write a cell, read it back
eq(
	[[
  fn int main() {
    int[4] xs;
    xs[0] = 7;
    return xs[0]
  }
]],
	7,
	"store then load"
)

-- index by a computed expression
eq(
	[[
  fn int main() {
    int[8] xs;
    int i = 2;
    xs[i + 1] = 99;
    return xs[3]
  }
]],
	99,
	"index by expression"
)

-- fill in a loop, then sum in a loop
eq(
	[[
  fn int main() {
    int[5] xs;
    for int i = 0; i < 5; ++i { xs[i] = i * i }
    int s = 0;
    for int j = 0; j < 5; ++j { s += xs[j] }
    return s
  }
]],
	30,
	"fill and sum (0+1+4+9+16)"
)

-- distinct cells do not alias
eq(
	[[
  fn int main() {
    int[3] xs;
    xs[0] = 1; xs[1] = 2; xs[2] = 3;
    return xs[0] * 100 + xs[1] * 10 + xs[2]
  }
]],
	123,
	"cells independent"
)

-- pointer model: index a returned array directly
eq(
	[[
  fn int row() { int[2] r; r[0] = 7; r[1] = 8; return r }
  fn int main() { return row()[1] }
]],
	8,
	"index a returned array (row()[1])"
)

-- jagged grid: each cell holds a row pointer, indexed as grid[a][b]
eq(
	[[
  fn int mk(int v) { int[2] r; r[0] = v; r[1] = v + 1; return r }
  fn int main() {
    int[2] grid;
    grid[0] = mk(10);
    grid[1] = mk(20);
    return grid[0][1] + grid[1][0]
  }
]],
	31,
	"jagged grid[a][b] via stored row pointers (11 + 20)"
)

-- arrays pass by pointer: a callee mutates the caller's array through it
eq(
	[[
  fn int fill(int p) { p[0] = 42; return 0 }
  fn int main() { int[1] a; fill(a); return a[0] }
]],
	42,
	"array passed by pointer, mutated in callee"
)

-- unwritten cells read as 0. This shape (bounded counters, numeric stores,
-- no escape) takes the ffi representation under LuaJIT, the table under PUC
eq(
	[[
  fn int main() {
    int[8] xs;
    for int i = 0; i < 4; ++i { xs[i] = 5 }
    int s = 0;
    for int j = 0; j < 8; ++j { s += xs[j] }
    return s
  }
]],
	20,
	"unwritten cells default to 0"
)

-- the same default through the table (__ZERO) representation: escaping to a
-- callee disqualifies the ffi form on any runtime
eq(
	[[
  fn int sum(int p) {
    int s = 0;
    for int j = 0; j < 8; ++j { s += p[j] }
    return s
  }
  fn int main() { int[8] xs; xs[0] = 5; return sum(xs) }
]],
	5,
	"unwritten cells default to 0 (escaping array, table form)"
)

print("ok")
