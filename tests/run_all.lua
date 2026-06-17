-- Run every test file from the project root: `lua5.4 tests/run_all.lua`.
-- Each test prints "ok" on success and error()s on failure; this runs them in
-- child processes so one failure does not abort the rest, and reports a tally.
local tests = {
	"tests/eval_operators.lua",
	"tests/eval_control.lua",
	"tests/eval_functions.lua",
	"tests/eval_arrays.lua",
	"tests/eval_exceptions.lua",
	"tests/eval_literals.lua",
	"tests/eval_imports.lua",
	"tests/eval_unsupported.lua",
}

local lua = arg[-1] or "lua5.4"
local passed, failed = 0, {}
for _, t in ipairs(tests) do
	-- capture output so a passing test stays quiet; show it only on failure
	local fh = io.popen(lua .. " " .. t .. " 2>&1")
	local out = fh:read("*a")
	local ok = fh:close()
	if ok then
		passed = passed + 1
		io.write(string.format("PASS %s\n", t))
	else
		failed[#failed + 1] = t
		io.write(string.format("FAIL %s\n%s\n", t, out))
	end
end

io.write(string.format("\n%d/%d passed\n", passed, #tests))
if #failed > 0 then os.exit(1) end
