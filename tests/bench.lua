-- Benchmark: run each bench.nova workload through avon (transpiled to Lua)
-- and against the same algorithm hand-written in Lua (the ceiling). Reports
-- the avon/lua slowdown -- the residual is just the semantic shims.
-- Usage from the project root: `lua5.4 tests/bench.lua`
local Parser = require("lang/parser")
local Avon = require("codegen/avon")

local fh = assert(io.open("tests/bench.nova", "r"))
local src = fh:read("*a")
fh:close()
local ast = Parser:new(src):parse()

-- transpile once to Lua and load it; emit.fib etc. are real Lua functions
local emit = Avon.load(ast.body, {})

local function time(fn)
	local t0 = os.clock()
	local r = fn()
	return os.clock() - t0, r
end

-- native Lua equivalents (must match bench.nova exactly)
local function nat_fib(n)
	if n < 2 then return n end
	return nat_fib(n - 1) + nat_fib(n - 2)
end
local function nat_loopsum(n)
	local s = 0
	for i = 0, n - 1 do
		s = s + i * 2 - 1
	end
	return s
end
local function nat_array(reps)
	local s = 0
	for _ = 1, reps do
		local xs = {}
		for i = 0, 999 do
			xs[i] = i * i
		end
		for j = 0, 999 do
			s = s + xs[j]
		end
	end
	return s
end

local work = {
	{ name = "fib(32)", entry = "fib", arg = 32, native = nat_fib },
	{
		name = "loopsum(2e6)",
		entry = "loopsum",
		arg = 2000000,
		native = nat_loopsum,
	},
	{
		name = "arraywork(200)",
		entry = "arraywork",
		arg = 200,
		native = nat_array,
	},
}

local function fmt(s) return string.format("%8.3f", s * 1000) end

print(
	string.format(
		"%-16s %10s %10s   %10s",
		"workload",
		"avon(ms)",
		"lua(ms)",
		"avon/lua"
	)
)
print(string.rep("-", 52))

for _, w in ipairs(work) do
	local te = time(function() return emit[w.entry](w.arg) end)
	local tl = time(function() return w.native(w.arg) end)
	print(
		string.format(
			"%-16s %10s %10s   %8.1fx",
			w.name,
			fmt(te),
			fmt(tl),
			tl > 0 and te / tl or 0
		)
	)

	local re, rl = emit[w.entry](w.arg), w.native(w.arg)
	if re ~= rl then
		error(
			string.format(
				"%s MISMATCH: avon=%s lua=%s",
				w.name,
				tostring(re),
				tostring(rl)
			)
		)
	end
end

print("\n(times in ms) avon results match native Lua.")
