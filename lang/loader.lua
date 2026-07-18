-- Module loader / linker. Resolves a Nova program's `import`s, recursively
-- compiles the files they name, and binds each compiled module into the
-- importer's environment so calls like `geom.area(...)` work as plain Lua
-- table indexing -- the same shape as a host module's `math.sqrt(...)`.
--
-- Dotted paths are root-relative: they resolve from the entry file's directory
-- (the project root), the same from any importer, so `import a.b.c` always
-- means the same module:
--   import geom        -> <root>/geom.nova        (flat)
--   import math.vec    -> <root>/math/vec.nova     (nested)
--   import a.b.c       -> <root>/a/b/c.nova        (double nested)
-- A path that resolves to no .nova file falls back to Lua `require` (a host
-- module), so one `import` keyword serves both Nova libraries and host modules.
--
-- Access is namespaced by the full dotted path (`a.b.c.fn`); `as` rebinds it
-- to a single name (`import a.b.c as v` -> `v.fn`). Each module compiles with
-- its own environment, so its functions resolve their own imports in isolation.
local Parser = require("parser")
local Avon = require("avon")
local fs = require("fs")

local Loader = {}

local function dirname(p) return p:match("^(.*)/[^/]*$") or "." end

-- Optional project-wide prelude of `__` keyword-alias directives. Lives at the
-- entry directory root; its aliases apply to every compiled file (the entry and
-- all imports), so an alias declared once is seen project-wide.
function Loader.prelude(root)
	local fh = io.open(root .. "/.novapre", "r")
	if not fh then return nil end
	local src = fh:read("*a")
	fh:close()
	return src
end

-- Resolve a dotted module to a Nova source file under `base`: prefer the
-- `.nova` file, then an extensionless file of the same name (not a directory).
-- Returns nil if neither exists (the caller then treats it as a host module).
local function module_to_file(base, dotted)
	local stem = base .. "/" .. dotted:gsub("%.", "/")
	if fs.exists(stem .. ".nova") then return stem .. ".nova" end
	if fs.exists(stem) and not fs.is_dir(stem) then return stem end
	return nil
end

-- bind value at a dotted path, creating intermediate tables: a.b.c = value
local function bind_nested(env, dotted, value)
	local parts = {}
	for seg in dotted:gmatch("[^.]+") do
		parts[#parts + 1] = seg
	end
	local t = env
	for i = 1, #parts - 1 do
		local k = parts[i]
		if type(t[k]) ~= "table" then t[k] = {} end
		t = t[k]
	end
	t[parts[#parts]] = value
end

-- the ambient builtins every module sees unqualified. Kept deliberately small:
-- the rest of Lua's stdlib is reached qualified via `import` (e.g. `import math`
-- -> `math.sqrt(...)`), so only names with no qualified home live here.
local function host_env()
	local env = { pow = function(a, b) return a ^ b end }
	env.print = function(...)
		print(...)
		return 0
	end
	return env
end

-- compile one file, recursively loading its Nova imports. `root` is the entry
-- directory all dotted paths resolve against; `cache` memoizes by path (so a
-- shared dependency compiles once); `stack` detects import cycles.
local function load_file(path, root, cache, stack, prelude)
	if cache[path] then return cache[path] end
	if stack[path] then error("circular import at " .. path) end
	stack[path] = true

	local fh, oerr = io.open(path, "r")
	if not fh then error("cannot open module: " .. tostring(oerr)) end
	local src = fh:read("*a")
	fh:close()
	local ast = Parser:new(src, prelude):parse()

	local env = host_env()
	for _, node in ipairs(ast.body) do
		if node.type == "import" then
			local file = module_to_file(root, node.module)
			local value
			if file then
				-- a Nova module (.nova or extensionless)
				value = load_file(file, root, cache, stack, prelude)
			else
				-- a host module
				value = _G[node.module] or require(node.module)
			end
			if node.alias ~= node.module then
				-- `as`: bind under the alias name
				env[node.alias] = value
			else
				-- namespaced by dotted path
				bind_nested(env, node.module, value)
			end
		end
	end

	local mods = Avon.load(ast.body, env)
	cache[path] = mods
	stack[path] = nil
	-- also hand back the parsed AST: the entry caller (Loader.run) reuses it for
	-- entry validation instead of parsing the file a second time. Recursive
	-- callers above take only the first return (mods) and ignore it.
	return mods, ast
end

-- Load `path` and all its transitive Nova imports. Returns the entry file's
-- table of functions (name -> Lua function) AND its parsed AST, so the runner
-- can validate the entry point without re-parsing. Dotted imports resolve from
-- the entry file's directory.
function Loader.run(path)
	local root = dirname(path)
	return load_file(path, root, {}, {}, Loader.prelude(root))
end

return Loader
