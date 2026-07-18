-- Waste analysis of avon's emitted Lua: which prelude shims a module carries
-- vs which its body references, orphaned continue labels, and what the waste
-- costs after load() (parens and labels are free; dead shims are not).
-- Usage, from anywhere: lua playground/waste.lua file.nova [more.nova ...]
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local root = here .. "/.."
package.path = root .. "/lang/?.lua;" .. root .. "/codegen/?.lua;" .. package.path
local Parser = require("parser")
local Avon = require("avon")

local SHIMS = {
	"__idiv",
	"__imod",
	"__fmod",
	"__floor",
	"__ceil",
	"__pack",
	"__unpack",
	"__ZERO",
	"__NORET",
	"bit",
}

for _, path in ipairs(arg) do
	local fh = assert(io.open(path, "r"))
	local src = fh:read("*a")
	fh:close()
	local out = Avon.compile(Parser:new(src):parse().body)

	-- the prelude is the leading run of shim definitions: `local __...` /
	-- `local bit` lines plus the indented bodies and `end`s of the shim fns.
	-- Everything after is module body.
	local prelude, body = {}, {}
	local in_prelude = true
	for line in (out .. "\n"):gmatch("([^\n]*)\n") do
		if
			in_prelude
			and not (
				line:match("^local __")
				or line:match("^local function __")
				or line:match("^local bit")
				or line:match("^  ")
				or line == "end"
			)
		then
			in_prelude = false
		end
		local t = in_prelude and prelude or body
		t[#t + 1] = line
	end
	local ptext = table.concat(prelude, "\n")
	local btext = table.concat(body, "\n")

	local carried, dead = {}, {}
	for _, s in ipairs(SHIMS) do
		if ptext:find(s, 1, true) then
			carried[#carried + 1] = s
			-- dead = unreferenced by the body AND by other shims' bodies
			-- (one prelude occurrence is the shim's own definition)
			local _, prefs = ptext:gsub(s, "")
			if not btext:find(s, 1, true) and prefs <= 1 then
				dead[#dead + 1] = s
			end
		end
	end

	local orphans = 0
	for label in out:gmatch("::(__cont%d+)::") do
		if not out:find("goto " .. label, 1, true) then orphans = orphans + 1 end
	end

	print(string.format("== %s ==", path))
	print(
		string.format(
			"  emitted %d bytes -> %d bytecode stripped, prelude %d lines",
			#out,
			#string.dump(load(out), true),
			#prelude
		)
	)
	print(
		string.format(
			"  shims carried: %s",
			#carried > 0 and table.concat(carried, " ") or "(none)"
		)
	)
	print(
		string.format(
			"  shims dead:    %s",
			#dead > 0 and table.concat(dead, " ") or "(none)"
		)
	)
	print(string.format("  orphan continue labels: %d (free after load)", orphans))
end

-- fixed costs, measured once
local empty = Avon.compile(Parser:new("fn int main() { return 0 }"):parse().body)
print(
	string.format(
		"\nempty-module floor: %d bytes emitted, %d bytecode",
		#empty,
		#string.dump(load(empty), true)
	)
)
local a = string.dump(load("local x,y=1,2 return ((x)+((y)))"), true)
local b = string.dump(load("local x,y=1,2 return x+y"), true)
print(
	string.format(
		"paren-heavy vs bare bytecode: %d vs %d (%s)",
		#a,
		#b,
		#a == #b and "identical -- parens are free" or "DIFFER"
	)
)
