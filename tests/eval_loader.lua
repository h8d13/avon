-- Loader/linker features that the in-process `eval.lua` harness cannot reach
-- (it wires imports via require()/_G and applies no prelude). These exercise
-- the real Loader against files on disk: importing another Nova file, dotted
-- (nested-folder) paths, the project-wide `.novapre` prelude, and the rule that
-- per-file `__` aliases do NOT leak across an import.
package.path = "lang/?.lua;codegen/?.lua;" .. package.path
local Loader = require("loader")

-- write `files` (relative path -> source) under a fresh temp root, run the
-- entry file through the Loader with print() captured, then remove the tree.
-- Returns the entry's primary result and the captured print lines.
local function run_tree(files, entry_rel)
	local root = os.tmpname()
	os.remove(root) -- tmpname makes a file; we want a dir of that name
	assert(os.execute("mkdir -p " .. root))

	for rel, src in pairs(files) do
		local path = root .. "/" .. rel
		local dir = path:match("^(.*)/[^/]*$")
		if dir then assert(os.execute("mkdir -p " .. dir)) end
		local fh = assert(io.open(path, "w"))
		fh:write(src)
		fh:close()
	end

	local lines = {}
	local real_print = print
	_G.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring((select(i, ...)))
		end
		lines[#lines + 1] = table.concat(parts, "\t")
	end
	local ok, mods = pcall(Loader.run, root .. "/" .. entry_rel)
	local result
	if ok then
		local rets = { mods.main() }
		result = rets[1] or 0
	end
	_G.print = real_print

	os.execute("rm -rf " .. root)
	if not ok then error(mods, 2) end
	return result, lines
end

local function eq(got, expected, label)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, got))
	end
end

-- import another Nova file: `import geom` resolves to <root>/geom.nova and the
-- module's functions are reachable as geom.fn(...)
eq(
	run_tree({
		["geom.nova"] = "fn int area(int s) { return s * s }\n",
		["main.nova"] = "import geom\nfn int main() { return geom.area(4) }\n",
	}, "main.nova"),
	16,
	"import a Nova file (geom.area)"
)

-- dotted path resolves through nested folders: a.b.c -> <root>/a/b/c.nova,
-- and `as` rebinds the namespace to a single prefix
eq(
	run_tree({
		["a/b/c.nova"] = "fn int answer() { return 7 }\n",
		["main.nova"] = "import a.b.c as g\nfn int main() { return g.answer() }\n",
	}, "main.nova"),
	7,
	"dotted import a.b.c as g"
)

-- a `.novapre` at the entry root supplies `__` aliases to every compiled file
-- (entry and imports alike), so an alias declared once works project-wide
eq(
	run_tree({
		[".novapre"] = "__fn = f\n__return = r\n",
		["main.nova"] = "f int main() { r 99 }\n",
	}, "main.nova"),
	99,
	".novapre prelude aliases the entry file"
)

-- the prelude reaches imported modules too, not just the entry
eq(
	run_tree({
		[".novapre"] = "__fn = f\n__return = r\n",
		["lib.nova"] = "f int val() { r 8 }\n",
		["main.nova"] = "import lib\nfn int main() { return lib.val() }\n",
	}, "main.nova"),
	8,
	".novapre prelude reaches imports"
)

-- per-file `__` aliases do NOT leak across an import. The module aliases the
-- `return` keyword to `ret`; the importer reuses `ret` as a plain variable
-- name. A leak would rewrite the importer's `ret` into the `return` keyword
-- (`int return = ...` -> a parse error), so the importer compiling and reading
-- `ret` back as a value is the proof the alias stayed local to the module.
eq(
	run_tree({
		["mod.nova"] = "__return = ret\nfn int helper() { ret 3 }\n",
		["main.nova"] = "import mod\nfn int main() { int ret = mod.helper(); return ret }\n",
	}, "main.nova"),
	3,
	"module alias does not leak into the importer"
)

-- the converse direction: the importer's own alias does not reach the module.
-- The importer aliases `return` to `ret`; the module reuses `ret` as a plain
-- variable and still works, proving the importer's alias stayed local.
eq(
	run_tree({
		["mod.nova"] = "fn int helper() { int ret = 4; return ret }\n",
		["main.nova"] = "__return = ret\nimport mod\nfn int main() { ret mod.helper() }\n",
	}, "main.nova"),
	4,
	"importer alias does not leak into the module"
)

-- Loader.run returns the entry AST alongside the modules, and parses the entry
-- exactly once -- the runner reuses that AST for entry validation rather than
-- parsing the file a second time at startup.
do
	local Parser = require("parser")
	local real_parse = Parser.parse
	local parses = 0
	Parser.parse = function(self)
		parses = parses + 1
		return real_parse(self)
	end

	local root = os.tmpname()
	os.remove(root)
	assert(os.execute("mkdir -p " .. root))
	local fh = assert(io.open(root .. "/main.nova", "w"))
	fh:write("fn int main() { return 7 }\n")
	fh:close()

	local ok, mods, ast = pcall(Loader.run, root .. "/main.nova")
	Parser.parse = real_parse -- restore before any assert can abort
	os.execute("rm -rf " .. root)

	if not ok then error("Loader.run failed: " .. tostring(mods)) end
	if parses ~= 1 then error("entry parsed " .. parses .. " times, expected 1") end
	if not (ast and ast.body) then
		error("Loader.run did not return the entry AST")
	end
	if mods.main() ~= 7 then error("entry not callable from Loader.run mods") end
end

-- an import with no matching .nova file falls back to require(): a
-- luarocks-installed rock and a preloaded module take the same path
do
	package.preload["fakerock"] = function()
		return { triple = function(x) return x * 3 end }
	end
	local r = run_tree({
		["main.nova"] = "import fakerock\n"
			.. "fn int main() { return fakerock.triple(5) }\n",
	}, "main.nova")
	package.preload["fakerock"] = nil
	package.loaded["fakerock"] = nil
	eq(r, 15, "import falls back to require() for host rocks")
end

-- .novac bytecode cache: the first run writes it, a second run loads the
-- dumped bytecode without parsing, and editing the source invalidates it
do
	local Parser = require("parser")
	local root = os.tmpname()
	os.remove(root)
	assert(os.execute("mkdir -p " .. root))
	local main = root .. "/main.nova"
	local fh = assert(io.open(main, "w"))
	fh:write("fn int main() { return 11 }\n")
	fh:close()

	local mods = Loader.run(main)
	eq(mods.main(), 11, "novac: cold run result")
	local cf = io.open(main .. "c", "rb")
	if not cf then error("novac: cache file not written") end
	cf:close()

	-- warm: the parser must not run at all
	local real_parse = Parser.parse
	local parses = 0
	Parser.parse = function(self)
		parses = parses + 1
		return real_parse(self)
	end
	local ok, warm, wast = pcall(Loader.run, main)
	Parser.parse = real_parse
	if not ok then error("novac: warm run failed: " .. tostring(warm)) end
	eq(warm.main(), 11, "novac: warm run result")
	eq(parses, 0, "novac: warm run parse count")
	if not (wast and wast.body and wast.body[1].name == "main") then
		error("novac: warm AST stub missing the entry function")
	end

	-- invalidation: change the source, expect a recompile with the new result
	fh = assert(io.open(main, "w"))
	fh:write("fn int main() { return 22 }\n")
	fh:close()
	eq(Loader.run(main).main(), 22, "novac: edit invalidates cache")

	os.execute("rm -rf " .. root)
end

print("ok")
