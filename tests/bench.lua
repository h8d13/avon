-- Fair A/B benchmark. The SAME bench.nova AST compiles twice: baseline
-- emission (table arrays + a fresh closure per try entry) vs current
-- emission (ffi fixed arrays and chunk-level try bodies where the analysis
-- proves them safe), plus the hand-written Lua ceiling. Fairness rules:
--   - every variant gets one full warmup call before timing, so JIT trace
--     compilation is charged to no one
--   - timings are min-of-R with a full GC between reps (min, not mean:
--     the floor is the code's cost, the rest is scheduler/GC noise)
--   - all three variants must agree on results, and each workload declares
--     an expectation -- "faster" must beat baseline by >= 5%, "par" must
--     stay within 20% -- so a regression fails the run, loudly
-- Usage from the project root: `luajit tests/bench.lua` (or `lua5.4`,
-- where the ffi emission is off and only the try hoist differs).
local Parser = require("lang/parser")
local Avon = require("codegen/avon")

local JIT = rawget(_G, "jit") ~= nil
local R = 7

local fh = assert(io.open("tests/bench.nova", "r"))
local src = fh:read("*a")
fh:close()
local ast = Parser:new(src):parse()

-- one AST, two emissions: compile does not mutate the AST (verified by the
-- result cross-check below agreeing across variants)
local base = Avon.load(ast.body, {}, { ffi = false, tryhoist = false })
local new = Avon.load(ast.body, {})

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
local function nat_sparse(reps)
	local s = 0
	for _ = 1, reps do
		local xs = {}
		for i = 0, 999 do
			xs[i] = 0
		end
		for i = 0, 99 do
			xs[i * 10] = 1
		end
		for j = 0, 999 do
			s = s + xs[j]
		end
	end
	return s
end
local nat_acc = 0
local function nat_guarded(x)
	if x % 97 == 0 then error("boom", 0) end
	return x * 2
end
local function nat_trysum(n)
	nat_acc = 0
	for i = 1, n do
		local ok, v = pcall(nat_guarded, i)
		if ok then
			nat_acc = nat_acc + v
		else
			nat_acc = nat_acc + 1
		end
	end
	return nat_acc
end

-- expect "faster": the new emission targets this workload and must win.
-- expect "par": untouched emission, must not regress. The ffi array path
-- only exists under LuaJIT, so those two are "par" on PUC Lua.
local work = {
	{ name = "fib(32)", entry = "fib", arg = 32, native = nat_fib, expect = "par" },
	{
		name = "loopsum(2e6)",
		entry = "loopsum",
		arg = 2000000,
		native = nat_loopsum,
		expect = "par",
	},
	{
		name = "arraywork(2000)",
		entry = "arraywork",
		arg = 2000,
		native = nat_array,
		expect = JIT and "faster" or "par",
	},
	{
		name = "sparse(2000)",
		entry = "sparse",
		arg = 2000,
		native = nat_sparse,
		expect = JIT and "faster" or "par",
	},
	{
		name = "trysum(2e5)",
		entry = "trysum",
		arg = 200000,
		native = nat_trysum,
		expect = "faster",
	},
}

local function time(fn, arg)
	local r = fn(arg) -- warmup: JIT compiles traces here, not on the clock
	local best = math.huge
	for _ = 1, R do
		collectgarbage("collect")
		local t0 = os.clock()
		fn(arg)
		local dt = os.clock() - t0
		if dt < best then best = dt end
	end
	return best, r
end

local function fmt(s) return string.format("%9.3f", s * 1000) end

print(
	string.format(
		"%-16s %10s %10s %10s   %9s %9s",
		"workload",
		"base(ms)",
		"new(ms)",
		"lua(ms)",
		"base/new",
		"new/lua"
	)
)
print(string.rep("-", 72))

local failures = {}
for _, w in ipairs(work) do
	local tb, rb = time(base[w.entry], w.arg)
	local tn, rn = time(new[w.entry], w.arg)
	local tl, rl = time(w.native, w.arg)

	if rb ~= rn or rn ~= rl then
		error(
			string.format(
				"%s MISMATCH: base=%s new=%s lua=%s",
				w.name,
				tostring(rb),
				tostring(rn),
				tostring(rl)
			)
		)
	end

	print(
		string.format(
			"%-16s %10s %10s %10s   %8.2fx %8.2fx",
			w.name,
			fmt(tb),
			fmt(tn),
			fmt(tl),
			tn > 0 and tb / tn or 0,
			tl > 0 and tn / tl or 0
		)
	)

	if w.expect == "faster" and tn > tb * 0.95 then
		failures[#failures + 1] = string.format(
			"%s: expected new to beat base by >=5%%, got %.3fms vs %.3fms",
			w.name,
			tn * 1000,
			tb * 1000
		)
	elseif w.expect == "par" and tn > tb * 1.20 then
		failures[#failures + 1] = string.format(
			"%s: new regressed past par margin: %.3fms vs %.3fms",
			w.name,
			tn * 1000,
			tb * 1000
		)
	end
end

-- startup A/B: full pipeline (parse + transpile + load + .novac write) vs
-- a .novac hit (validate + load bytecode). Same fairness: min-of-R, cold
-- removes the cache before every rep so each one pays the whole pipeline.
package.path = "lang/?.lua;codegen/?.lua;" .. package.path
local Loader = require("loader")
local cachefile = "tests/bench.novac"

local tcold = math.huge
for _ = 1, R do
	os.remove(cachefile)
	collectgarbage("collect")
	local t0 = os.clock()
	Loader.run("tests/bench.nova")
	local dt = os.clock() - t0
	if dt < tcold then tcold = dt end
end
local twarm = math.huge -- cache exists from the last cold rep
for _ = 1, R do
	collectgarbage("collect")
	local t0 = os.clock()
	Loader.run("tests/bench.nova")
	local dt = os.clock() - t0
	if dt < twarm then twarm = dt end
end
os.remove(cachefile)

print(
	string.format(
		"\nstartup: cold %s ms   .novac %s ms   %8.2fx",
		fmt(tcold),
		fmt(twarm),
		twarm > 0 and tcold / twarm or 0
	)
)
if twarm > tcold * 0.5 then
	failures[#failures + 1] = string.format(
		"startup: expected .novac to halve cold start, got %.3fms vs %.3fms",
		twarm * 1000,
		tcold * 1000
	)
end

if #failures > 0 then
	error("\nA/B expectations failed:\n  " .. table.concat(failures, "\n  "))
end
print("\nresults match across base/new/native; A/B expectations hold.")
