-- The ./nova runner CLI, driven as a real child process: default entry,
-- --entry selection, integer args, the missing-arg -> 0 padding, and the
-- helpful failure for a bogus entry. Uses the same interpreter running this
-- test (arg[-1]); assumes the project-root cwd like every other test.
local lua = arg[-1] or "lua5.4"

local function run(args)
	local fh = assert(io.popen(lua .. " ./nova " .. args .. " 2>&1"))
	local out = fh:read("*a")
	local ok = fh:close()
	return out, ok
end

local function eq(got, expected, label)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, got))
	end
end

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. root))
local prog = root .. "/cli.nova"
local fh = assert(io.open(prog, "w"))
fh:write([[
fn int add(int a, int b) { return a + b }
fn int main() { return 42 }
]])
fh:close()

-- default entry is main; the primary result prints
local out, ok = run(prog)
if not ok then error("runner failed: " .. out) end
eq(out, "42\n", "default entry main")

-- --entry picks another function; int args pass through argv
out, ok = run(prog .. " --entry add 30 12")
if not ok then error("runner --entry failed: " .. out) end
eq(out, "42\n", "--entry with int args")

-- missing trailing args pad to 0
out, ok = run(prog .. " --entry add 7")
if not ok then error("runner padding failed: " .. out) end
eq(out, "7\n", "missing arg pads to 0")

-- a bogus entry lists what is available and exits non-zero
out, ok = run(prog .. " --entry nope")
if ok then error("bogus entry: expected failure, got: " .. out) end
if not out:find("no function 'nope'", 1, true) then
	error("bogus entry: unexpected message: " .. out)
end

-- compile errors keep their line:col tag through the runner's prefix strip
local bad = root .. "/bad.nova"
fh = assert(io.open(bad, "w"))
fh:write("fn int main() {\n\treturn oops\n}\n")
fh:close()
out, ok = run(bad)
if ok then error("bad program: expected failure, got: " .. out) end
if not out:find("2:9: unknown name 'oops'", 1, true) then
	error("bad program: expected positional error, got: " .. out)
end

os.execute("rm -rf " .. root)
print("ok")
