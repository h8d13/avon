-- The ./nova runner CLI, driven as a real child process: default entry,
-- --entry selection, integer args, the missing-arg -> 0 padding, and the
-- helpful failure for a bogus entry. Uses the same interpreter running this
-- test (arg[-1]); assumes the project-root cwd like every other test.
local lua = arg[-1]
	or (
		rawget(_G, "jit") and "luajit"
		or "lua" .. _VERSION:match("%d+%.%d+")
	)

-- the entry's return value is the exit status, so the assertions below are
-- about $? rather than stdout. io.popen's close returns the status only on
-- 5.2+, so the shell echoes it into the captured stream instead -- one code
-- path across every supported interpreter.
local function run(args)
	local cmd = lua .. " ./nova " .. args .. ' 2>&1; echo "__exit=$?"'
	local fh = assert(io.popen(cmd))
	local out = fh:read("*a")
	fh:close()
	local code = tonumber(out:match("__exit=(%d+)%s*$"))
	return (out:gsub("__exit=%d+%s*$", "")), code
end

local function eq(got, expected, label)
	if got ~= expected then
		error(
			string.format(
				"%s: expected %q, got %q",
				label,
				expected,
				got
			)
		)
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

-- default entry is main; its return value is the exit status, and the
-- runner itself writes nothing
local out, code = run(prog)
eq(code, 42, "default entry main exit status")
eq(out, "", "runner prints nothing of its own")

-- --entry picks another function; int args pass through argv
out, code = run(prog .. " --entry add 30 12")
eq(code, 42, "--entry with int args")
eq(out, "", "--entry prints nothing either")

-- missing trailing args pad to 0
out, code = run(prog .. " --entry add 7")
eq(code, 7, "missing arg pads to 0")
eq(out, "", "padding path prints nothing")

-- a return the OS cannot represent keeps only its low 8 bits, and a float
-- entry truncates on the way out -- both are exit()'s rules, not ours
local wide = root .. "/wide.nova"
fh = assert(io.open(wide, "w"))
fh:write("fn float main() { return 300.9 }\n")
fh:close()
out, code = run(wide)
eq(code, 44, "float truncates and wraps to the low 8 bits") -- 300 % 256
eq(out, "", "a float entry prints nothing either")

-- an entry that returns nothing is success
local void = root .. "/void.nova"
fh = assert(io.open(void, "w"))
fh:write('fn int main() { print("hi") }\n')
fh:close()
out, code = run(void)
eq(code, 0, "missing return exits 0")
eq(out, "hi\n", "the program's own output still reaches stdout")

-- a bogus entry lists what is available and exits non-zero
out, code = run(prog .. " --entry nope")
if code == 0 then error("bogus entry: expected failure, got: " .. out) end
if not out:find("no function 'nope'", 1, true) then
	error("bogus entry: unexpected message: " .. out)
end

-- compile errors keep their line:col tag through the runner's prefix strip
local bad = root .. "/bad.nova"
fh = assert(io.open(bad, "w"))
fh:write("fn int main() {\n\treturn oops\n}\n")
fh:close()
out, code = run(bad)
if code == 0 then error("bad program: expected failure, got: " .. out) end
if not out:find("2:9: unknown name 'oops'", 1, true) then
	error("bad program: expected positional error, got: " .. out)
end

os.execute("rm -rf " .. root)
print("ok")
