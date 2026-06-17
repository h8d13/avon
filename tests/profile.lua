-- Line-level profiler for avon-generated Lua. Since avon emits real Lua, the
-- only code running under each workload is the generated chunk (plus C builtins
-- like math.floor, which raise no line events). So a line hook over the chunk
-- attributes execution directly to emitted constructs -- which shim costs what.
-- Usage from the project root: `lua5.4 tests/profile.lua`
local Parser = require("lang/parser")
local Avon = require("codegen/avon")

local fh = assert(io.open("tests/bench.nova", "r"))
local nova_src = fh:read("*a")
fh:close()
local ast = Parser:new(nova_src):parse()

-- compile once; keep the source so we can annotate hot lines with their text
local lua_src = Avon.compile(ast.body)
local srclines = {}
for line in (lua_src .. "\n"):gmatch("(.-)\n") do
	srclines[#srclines + 1] = line
end

local env = setmetatable({ pow = function(a, b) return a ^ b end }, { __index = _G })
for _, name in ipairs({ "sqrt", "floor", "ceil", "sin", "cos", "log" }) do
	env[name] = math[name]
end
local mods = assert(load(lua_src, "=nova", "t", env))()

-- profile one entry: a line hook tallies every emitted line executed
local function profile(entry, arg)
	local hits, total = {}, 0
	local function hook(_, line)
		hits[line] = (hits[line] or 0) + 1
		total = total + 1
	end
	debug.sethook(hook, "l")
	mods[entry](arg)
	debug.sethook()

	local order = {}
	for ln in pairs(hits) do
		order[#order + 1] = ln
	end
	table.sort(order, function(a, b) return hits[a] > hits[b] end)

	print(string.format("\n== %s(%d) -- %d line-events ==", entry, arg, total))
	print(string.format("%6s %5s   %s", "hits", "%", "emitted line"))
	for i = 1, math.min(10, #order) do
		local ln = order[i]
		print(
			string.format(
				"%6d %4.1f%%   %3d| %s",
				hits[ln],
				100 * hits[ln] / total,
				ln,
				(srclines[ln] or ""):gsub("^%s+", "")
			)
		)
	end
end

-- smaller args than the bench: the distribution is what matters, and the line
-- hook fires on every line so we keep the run short
profile("fib", 28)
profile("loopsum", 300000)
profile("arraywork", 50)
