-- End-to-end harness: run Nova source the way the `nova` runner does -- parse,
-- transpile to Lua, load() it -- but capture print() output and return the
-- entry function's primary result, so feature tests assert real behavior.
local Parser = require("lang/parser")
local Avon = require("codegen/avon")

-- run(src[, entry[, args]]) -> result, lines
--   result : the entry's primary return value, or 0 if none
--   lines  : array of captured print() lines (args joined by tab, like print)
local function run(src, entry, args)
	entry = entry or "main"
	local ast = Parser:new(src):parse()

	local lines = {}
	local env = { pow = function(a, b) return a ^ b end }
	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring((select(i, ...)))
		end
		lines[#lines + 1] = table.concat(parts, "\t")
		return 0
	end
	for _, name in ipairs({ "sqrt", "floor", "ceil", "sin", "cos", "log" }) do
		env[name] = math[name]
	end
	-- imports: same require()-based wiring as the runner (honors `as` alias);
	-- the module table is bound under its prefix so module.fn is Lua indexing
	for _, node in ipairs(ast.body) do
		if node.type == "import" then
			env[node.alias or node.module] = _G[node.module]
				or require(node.module)
		end
	end

	local mods = Avon.load(ast.body, env, { src = src })
	local fn = mods[entry]
	if not fn then error("no function '" .. tostring(entry) .. "'") end
	-- pad missing entry args to the entry's arity with 0 (mirrors the runner;
	-- avon relies on this to drop saturated params' defaults soundly)
	args = args or {}
	for _, node in ipairs(ast.body) do
		if node.type == "function" and node.name == entry then
			for i = #args + 1, #node.params do
				args[i] = 0
			end
			break
		end
	end
	local unpack = table.unpack or unpack -- 5.2+ vs 5.1/LuaJIT
	local rets = { fn(unpack(args, 1, #args)) }
	return rets[1] or 0, lines
end

-- runs the whole pipeline and returns true only if it errored (parse,
-- transpile/load, or run -- e.g. an uncaught throw).
local function fails(src, entry, args) return not pcall(run, src, entry, args) end

return { run = run, fails = fails }
