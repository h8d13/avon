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

-- ===== .novac bytecode cache =====
-- A compiled module's chunk is string.dump()ed next to its source
-- (foo.nova -> foo.novac). The cache embeds the exact runtime version,
-- prelude and source it was built from, so validation is a straight string
-- compare (no stat/mtime): any mismatch falls through to a full compile
-- that rewrites the cache. Alongside the dump it stores the import list
-- and the function names/arities -- everything the loader and runner
-- otherwise take from the AST -- so a hit skips parse and transpile
-- entirely. Blocks are length-prefixed ("<len>\n<bytes>").
local RUNTIME = rawget(_G, "jit") and jit.version or _VERSION

local function cache_path(path)
	if path:sub(-5) == ".nova" then return path .. "c" end
	return path .. ".novac"
end

local function wblock(parts, s) parts[#parts + 1] = #s .. "\n" .. s end

local function rblock(data, pos)
	local nl = data:find("\n", pos, true)
	if not nl then return nil end
	local len = tonumber(data:sub(pos, nl - 1), 10)
	if not len then return nil end
	local s = data:sub(nl + 1, nl + len)
	if #s ~= len then return nil end
	return s, nl + len + 1
end

-- valid cache for (path, prelude, src) -> { imports, funcs, dump }, or nil
local function cache_load(path, prelude, src)
	local fh = io.open(cache_path(path), "rb")
	if not fh then return nil end
	local data = fh:read("*a")
	fh:close()
	if data:sub(1, 7) ~= "NOVAC1\n" then return nil end
	local pos, rt, pre, cs, metasrc, dump = 8, nil, nil, nil, nil, nil
	rt, pos = rblock(data, pos)
	if rt ~= RUNTIME then return nil end -- bytecode is not portable
	pre, pos = rblock(data, pos)
	if pre ~= (prelude or "") then return nil end
	cs, pos = rblock(data, pos)
	if cs ~= src then return nil end
	metasrc, pos = rblock(data, pos)
	if not metasrc then return nil end
	dump = rblock(data, pos)
	if not dump then return nil end
	local mf = load(metasrc, "=novac-meta")
	if not mf then return nil end
	local ok, meta = pcall(mf)
	if not ok or type(meta) ~= "table" then return nil end
	meta.dump = dump
	return meta
end

local function cache_save(path, prelude, src, ast, chunk)
	local okd, dump = pcall(string.dump, chunk)
	if not okd then return end
	local meta = { "return {imports={" }
	for _, node in ipairs(ast.body) do
		if node.type == "import" then
			meta[#meta + 1] = string.format(
				"{module=%q,alias=%q},",
				node.module,
				node.alias or node.module
			)
		end
	end
	meta[#meta + 1] = "},funcs={"
	for _, node in ipairs(ast.body) do
		if node.type == "function" then
			meta[#meta + 1] = string.format(
				"{name=%q,nparams=%d},",
				node.name,
				#node.params
			)
		end
	end
	meta[#meta + 1] = "}}"
	local parts = { "NOVAC1\n" }
	wblock(parts, RUNTIME)
	wblock(parts, prelude or "")
	wblock(parts, src)
	wblock(parts, table.concat(meta))
	wblock(parts, dump)
	local fh = io.open(cache_path(path), "wb")
	if not fh then return end -- read-only tree: cold path every run
	fh:write(table.concat(parts))
	fh:close()
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

local load_file

-- resolve one import and bind it into `env`: a Nova module (.nova or
-- extensionless) loads recursively, anything else is a host module. Shared
-- by the parsed path and the .novac cached path.
local function bind_import(env, module, alias, root, cache, stack, prelude)
	local file = module_to_file(root, module)
	local value
	if file then
		value = load_file(file, root, cache, stack, prelude)
	else
		value = _G[module] or require(module)
	end
	if alias ~= module then
		-- `as`: bind under the alias name
		env[alias] = value
	else
		-- namespaced by dotted path
		bind_nested(env, module, value)
	end
end

-- compile one file, recursively loading its Nova imports. `root` is the entry
-- directory all dotted paths resolve against; `cache` memoizes by path (so a
-- shared dependency compiles once); `stack` detects import cycles.
function load_file(path, root, cache, stack, prelude)
	if cache[path] then return cache[path] end
	if stack[path] then error("circular import at " .. path) end
	stack[path] = true

	local fh, oerr = io.open(path, "r")
	if not fh then error("cannot open module: " .. tostring(oerr)) end
	local src = fh:read("*a")
	fh:close()

	-- cache hit: bind imports from the recorded list, load the dumped
	-- bytecode, and hand the runner an AST stub carrying the recorded
	-- function names/arities -- no parse, no transpile
	local hit = cache_load(path, prelude, src)
	if hit then
		local env = host_env()
		for _, imp in ipairs(hit.imports) do
			bind_import(
				env,
				imp.module,
				imp.alias,
				root,
				cache,
				stack,
				prelude
			)
		end
		env = setmetatable(env, { __index = _G })
		local chunk
		if setfenv then -- Lua 5.1 / LuaJIT
			chunk = load(hit.dump, "=nova", "b")
			if chunk then setfenv(chunk, env) end
		else
			chunk = load(hit.dump, "=nova", "b", env)
		end
		if chunk then
			local mods = chunk()
			cache[path] = mods
			stack[path] = nil
			local body = {}
			for _, f in ipairs(hit.funcs) do
				local params = {}
				for i = 1, f.nparams do
					params[i] = {}
				end
				body[#body + 1] = {
					type = "function",
					name = f.name,
					params = params,
				}
			end
			return mods, { body = body }
		end
		-- undumpable/corrupt bytecode: fall through to a full compile
	end

	local ast = Parser:new(src, prelude):parse()
	local env = host_env()
	for _, node in ipairs(ast.body) do
		if node.type == "import" then
			bind_import(
				env,
				node.module,
				node.alias or node.module,
				root,
				cache,
				stack,
				prelude
			)
		end
	end

	local mods, _, chunk = Avon.load(ast.body, env, { src = src })
	cache_save(path, prelude, src, ast, chunk)
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
