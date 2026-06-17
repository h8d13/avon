-- avon: the Nova -> Lua transpiler. The "hand it all to Lua" backend. Instead
-- of lowering to an IR and interpreting it, emit Lua text and let load()
-- compile it to bytecode. Nova functions become Lua functions, Nova arithmetic
-- becomes Lua arithmetic -- no dispatch loop, no per-node walk at run time.
--
-- The only shims are where Nova and Lua semantics differ:
--   - 0 is false in Nova but truthy in Lua  -> conditions test `~= 0`, and
--     comparisons/logicals yield 1/0
--   - int `/` and `%` truncate toward zero   -> __idiv / __imod, chosen at
--     compile time from a static int/float type (is_int); Lua 5.1/LuaJIT has
--     no integer subtype, so this cannot be decided at run time
--   - `+` concatenates if either side is a string literal
--   - array elements default-read as 0       -> __ZERO metatable
--
-- Targets both Lua 5.3/5.4 and LuaJIT (Lua 5.1 + the `bit` library), detected
-- from the host running the compiler (`jit` global). Bitwise ops emit operators
-- on 5.4 and bit.* calls on LuaJIT.
--
-- try/catch is a pcall around a closure. A `return` inside the try BODY is
-- captured (the __NORET sentinel) and re-returned from the function, so try
-- bodies can return. The only residue: a `break`/`continue` in a try body that
-- targets a loop OUTSIDE the try cannot cross the closure -- Lua rejects it at
-- load (a loud error, never a silent miscompile); break/continue to a loop that
-- is itself inside the body work fine.
local Avon = {}

local function is_strlit(n) return n.type == "literal" and type(n.value) == "string" end

-- `int a, b = f()` destructures (mirror Codegen:is_destructure)
local function is_destructure(decls)
	if #decls < 2 then return false end
	local last = decls[#decls]
	if not (last.value and last.value.type == "call") then return false end
	for i = 1, #decls - 1 do
		if decls[i].value then return false end
	end
	return true
end

-- emit LuaJIT-compatible code when the compiler runs under LuaJIT
local JIT = rawget(_G, "jit") ~= nil

local cmp = {
	["<"] = "<",
	["<="] = "<=",
	[">"] = ">",
	[">="] = ">=",
	["=="] = "==",
	["!="] = "~=",
}

function Avon.compile(body)
	-- declaration-level maps used for typing and constant inlining
	local consts = {} -- enum variant -> integer value
	local typedefs = {} -- typedef alias -> base type name
	local ret_int = {} -- user function name -> first return type is int?
	for _, n in ipairs(body) do
		if n.type == "enum" then
			for i, v in ipairs(n.variants) do
				consts[v] = i - 1
			end
		elseif n.type == "typedef" then
			typedefs[n.alias] = n.base and n.base.name or nil
		end
	end
	-- a Nova type name is int unless it (after following typedefs) is `float`
	local function is_int_type(name)
		local seen = 0
		while typedefs[name] and seen < 16 do
			name = typedefs[name]
			seen = seen + 1
		end
		return name ~= "float"
	end
	for _, n in ipairs(body) do
		if n.type == "function" then
			ret_int[n.name] = is_int_type(n.returnTypes and n.returnTypes[1])
		end
	end

	local buf, ind = {}, 0
	local function push(s) buf[#buf + 1] = string.rep("  ", ind) .. s end
	local labelc, subjc, tryc = 0, 0, 0
	local function newcont()
		labelc = labelc + 1
		return "__cont" .. labelc
	end

	-- per-function scalar type map (name -> "int" | "float" | "arr:int" | ...);
	-- set when each function is emitted, read by is_int.
	local typeenv = {}
	local E, E_binary, Econd, emit_stmt, emit_decl, block, is_int

	local function args_str(list)
		local t = {}
		for i, a in ipairs(list) do
			t[i] = E(a)
		end
		return table.concat(t, ", ")
	end

	E = function(node)
		local t = node.type
		if t == "literal" then
			if type(node.value) == "string" then
				return string.format("%q", node.value)
			end
			return tostring(node.value)
		elseif t == "identifier" then
			local c = consts[node.name]
			if c ~= nil then return tostring(c) end
			return node.name
		elseif t == "index" then
			-- E(array) is already a valid Lua prefix (a name, a chained
			-- index, or a parenthesized call), so no extra parens: a
			-- leading '(' here would glue onto the previous statement as
			-- a call.
			return E(node.array) .. "[" .. E(node.index) .. "]"
		elseif t == "unary" then
			local r = E(node.right)
			if node.op == "!" then
				return "((" .. r .. ") == 0 and 1 or 0)"
			end
			if node.op == "~" then
				return JIT and ("bit.bnot(" .. r .. ")")
					or ("(~(" .. r .. "))")
			end
			return "(-(" .. r .. "))"
		elseif t == "ternary" then
			return "("
				.. Econd(node.cond)
				.. " and ("
				.. E(node.thenE)
				.. ") or ("
				.. E(node.elseE)
				.. "))"
		elseif t == "call" then
			-- parenthesize so a multi-return call yields only its primary
			-- value in expression position (matches the VM taking result
			-- slot 0); destructure and bare-call-statement build their own
			-- call text and keep all values
			return "(" .. node.name .. "(" .. args_str(node.args) .. "))"
		elseif t == "binary" then
			return E_binary(node)
		end
		error("transpile expr: unhandled " .. tostring(t))
	end

	-- is_int(node): does this expression have Nova int type? Drives truncating
	-- vs real division, decided statically because LuaJIT has no int subtype.
	-- Unknowns default conservatively: undeclared names -> int (Nova's default),
	-- unknown calls / non-named array bases -> not int (real division).
	is_int = function(node)
		local t = node.type
		if t == "literal" then
			return type(node.value) ~= "string" and not node.isFloat
		elseif t == "identifier" then
			if consts[node.name] ~= nil then return true end
			local ty = typeenv[node.name]
			return ty == nil or ty == "int"
		elseif t == "index" then
			return node.array.type == "identifier"
				and typeenv[node.array.name] == "arr:int"
		elseif t == "call" then
			return ret_int[node.name] == true
		elseif t == "unary" then
			if node.op == "!" or node.op == "~" then return true end
			return is_int(node.right) -- unary minus
		elseif t == "ternary" then
			return is_int(node.thenE) and is_int(node.elseE)
		elseif t == "binary" then
			local op = node.op
			if op == "&&" or op == "||" or cmp[op] then return true end
			if
				op == "&"
				or op == "|"
				or op == "^"
				or op == "<<"
				or op == ">>"
			then
				return true
			end
			if
				op == "+"
				and (is_strlit(node.left) or is_strlit(node.right))
			then
				return false -- string concatenation
			end
			return is_int(node.left) and is_int(node.right)
		end
		return false
	end

	-- Econd(node): a Lua boolean expression for `node` tested as a Nova truth
	-- value (non-zero). Comparisons and && / || stay boolean and short-circuit;
	-- anything else falls back to `(value) ~= 0`. In a condition the `1/0`
	-- round-trip is wasted (it was the top line in every loop under the profiler).
	Econd = function(node)
		if node.type == "binary" then
			local op = node.op
			if op == "&&" then
				return "("
					.. Econd(node.left)
					.. " and "
					.. Econd(node.right)
					.. ")"
			elseif op == "||" then
				return "("
					.. Econd(node.left)
					.. " or "
					.. Econd(node.right)
					.. ")"
			elseif cmp[op] then
				return "(("
					.. E(node.left)
					.. ") "
					.. cmp[op]
					.. " ("
					.. E(node.right)
					.. "))"
			end
		elseif node.type == "unary" and node.op == "!" then
			return "((" .. E(node.right) .. ") == 0)"
		end
		return "((" .. E(node) .. ") ~= 0)"
	end

	E_binary = function(node)
		local op = node.op
		if op == "=" then
			error("transpile: assignment in expression position unsupported")
		end
		-- boolean-valued ops: build the Lua boolean, then materialize to 1/0
		if op == "&&" or op == "||" or cmp[op] then
			return "(" .. Econd(node) .. " and 1 or 0)"
		end
		local L, R = E(node.left), E(node.right)
		if op == "+" then
			if is_strlit(node.left) or is_strlit(node.right) then
				return "(tostring(" .. L .. ") .. tostring(" .. R .. "))"
			end
			return "((" .. L .. ") + (" .. R .. "))"
		end
		if op == "-" or op == "*" then
			return "((" .. L .. ") " .. op .. " (" .. R .. "))"
		end
		-- int/int truncates toward zero; otherwise real division (static choice)
		if op == "/" then
			if is_int(node.left) and is_int(node.right) then
				return "__idiv(" .. L .. ", " .. R .. ")"
			end
			return "((" .. L .. ") / (" .. R .. "))"
		end
		if op == "%" then
			if is_int(node.left) and is_int(node.right) then
				return "__imod(" .. L .. ", " .. R .. ")"
			end
			return "__fmod(" .. L .. ", " .. R .. ")"
		end
		-- bitwise: operators on 5.3/5.4, the `bit` library on LuaJIT
		if JIT then
			local jb = {
				["&"] = "band",
				["|"] = "bor",
				["^"] = "bxor",
				["<<"] = "lshift",
				[">>"] = "rshift",
			}
			if jb[op] then
				return "bit." .. jb[op] .. "(" .. L .. ", " .. R .. ")"
			end
		else
			local lb = {
				["&"] = "&",
				["|"] = "|",
				["^"] = "~",
				["<<"] = "<<",
				[">>"] = ">>",
			}
			if lb[op] then
				return "((" .. L .. ") " .. lb[op] .. " (" .. R .. "))"
			end
		end
		error("transpile binary: unhandled " .. tostring(op))
	end

	emit_decl = function(d)
		if d.varType and d.varType.type == "arraytype" then
			typeenv[d.name] = is_int_type(d.varType.base) and "arr:int"
				or "arr:float"
			push("local " .. d.name .. " = setmetatable({}, __ZERO)")
		else
			typeenv[d.name] = is_int_type(d.varType and d.varType.name)
					and "int"
				or "float"
			push(
				"local "
					.. d.name
					.. " = "
					.. (d.value and E(d.value) or "0")
			)
		end
	end

	emit_stmt = function(node, cl)
		if not node.type then -- decl list
			if is_destructure(node) then
				local call = node[#node].value
				local ns = {}
				for i, d in ipairs(node) do
					ns[i] = d.name
				end
				push(
					"local "
						.. table.concat(ns, ", ")
						.. " = "
						.. call.name
						.. "("
						.. args_str(call.args)
						.. ")"
				)
			else
				for _, d in ipairs(node) do
					emit_decl(d)
				end
			end
			return
		end

		local t = node.type
		if t == "decl" then
			emit_decl(node)
		elseif t == "binary" then
			if node.op == "=" then
				local tgt = node.left
				if tgt.type == "index" then
					push(
						E(tgt.array)
							.. "["
							.. E(tgt.index)
							.. "] = "
							.. E(node.right)
					)
				else
					push(tgt.name .. " = " .. E(node.right))
				end
			else
				push("local _ = " .. E(node)) -- bare expression (rare)
			end
		elseif t == "call" then
			push(node.name .. "(" .. args_str(node.args) .. ")")
		elseif t == "index" or t == "identifier" or t == "literal" then
			push("local _ = " .. E(node))
		elseif t == "if" then
			push("if " .. Econd(node.cond) .. " then")
			ind = ind + 1
			block(node.thenBranch, cl)
			ind = ind - 1
			if node.elseBranch then
				push("else")
				ind = ind + 1
				block(node.elseBranch, cl)
				ind = ind - 1
			end
			push("end")
		elseif t == "for" then
			push("do")
			ind = ind + 1
			if not node.init.type then
				for _, d in ipairs(node.init) do
					emit_decl(d)
				end
			else
				emit_stmt(node.init, cl)
			end
			local mycl = newcont()
			push("while " .. Econd(node.cond) .. " do")
			ind = ind + 1
			push("do")
			ind = ind + 1 -- body scope: keeps goto legal
			block(node.body, mycl)
			ind = ind - 1
			push("end")
			push("::" .. mycl .. "::")
			emit_stmt(node.update, cl)
			ind = ind - 1
			push("end")
			ind = ind - 1
			push("end")
		elseif t == "forin" then
			local decl = node.init[1]
			push("do")
			ind = ind + 1
			push("local " .. decl.name)
			local mycl = newcont()
			push("while true do")
			ind = ind + 1
			push(decl.name .. " = " .. E(decl.value))
			push("if " .. decl.name .. " == 0 then break end")
			push("do")
			ind = ind + 1
			block(node.body, mycl)
			ind = ind - 1
			push("end")
			push("::" .. mycl .. "::")
			ind = ind - 1
			push("end")
			ind = ind - 1
			push("end")
		elseif t == "switch" then
			subjc = subjc + 1
			local sv = "__subj" .. subjc
			push("do")
			ind = ind + 1
			push("local " .. sv .. " = " .. E(node.subject))
			local first = true
			for _, c in ipairs(node.cases) do
				push(
					(first and "if " or "elseif ")
						.. sv
						.. " == ("
						.. E(c.value)
						.. ") then"
				)
				first = false
				ind = ind + 1
				block(c.body, cl)
				ind = ind - 1
			end
			if node.default then
				push(first and "if true then" or "else")
				ind = ind + 1
				block(node.default, cl)
				ind = ind - 1
				push("end")
			elseif not first then
				push("end")
			end
			ind = ind - 1
			push("end")
		elseif t == "break" then
			push("break")
		elseif t == "continue" then
			if not cl then error("transpile: continue outside loop") end
			push("goto " .. cl)
		elseif t == "return" then
			local vs = {}
			for i, e in ipairs(node.values or {}) do
				vs[i] = E(e)
			end
			push(
				#vs == 0 and "return 0"
					or ("return " .. table.concat(vs, ", "))
			)
		elseif t == "throw" then
			push("error({nova=true, value=" .. E(node.value) .. "}, 0)")
		elseif t == "try" then
			-- pcall the body in a closure. A `return` inside the body
			-- returns from the closure; we capture those values
			-- (table.pack) and re-return them from the real function, so
			-- try bodies can return. __NORET marks "fell through" (no
			-- return). The `do ... end` lets a body return be the last
			-- statement and still allow the trailing `return __NORET`
			-- fallthrough.
			tryc = tryc + 1
			local r = "__try" .. tryc
			push("local " .. r .. " = __pack(pcall(function()")
			ind = ind + 1
			push("do")
			ind = ind + 1
			block(node.body, nil)
			ind = ind - 1
			push("end")
			push("return __NORET")
			ind = ind - 1
			push("end))")
			push("if " .. r .. "[1] then")
			ind = ind + 1
			push(
				"if "
					.. r
					.. "[2] ~= __NORET then return __unpack("
					.. r
					.. ", 2, "
					.. r
					.. ".n) end"
			)
			ind = ind - 1
			push("else")
			ind = ind + 1
			push(
				"local "
					.. node.catchVar
					.. " = ((type("
					.. r
					.. "[2]) == 'table' and "
					.. r
					.. "[2].nova) and "
					.. r
					.. "[2].value or "
					.. r
					.. "[2])"
			)
			block(node.handler, cl)
			ind = ind - 1
			push("end")
		elseif
			t == "typedef"
			or t == "enum"
			or t == "import"
			or t == "function"
		then
		-- declaration-level: no statement-position effect
		else
			error("transpile stmt: unhandled " .. tostring(t))
		end
	end

	block = function(list, cl)
		for _, st in ipairs(list) do
			emit_stmt(st, cl)
			local tt = st.type
			if tt == "return" or tt == "break" or tt == "continue" then
				break -- Lua requires these terminal in their block
			end
		end
	end

	-- prelude: semantic shims, emitted as upvalues (not globals). int division
	-- and mod are pre-selected by is_int, so these helpers are unconditional.
	if JIT then push("local bit = require('bit')") end
	push("local __floor, __ceil, __fmod = math.floor, math.ceil, math.fmod")
	push("local function __trunc(x)")
	push("  if x >= 0 then return __floor(x) else return __ceil(x) end")
	push("end")
	push("local function __idiv(a, b) return __trunc(a / b) end")
	push("local function __imod(a, b) return a - __trunc(a / b) * b end")
	-- table.pack/unpack are 5.2+; LuaJIT (5.1) needs the fallbacks
	push(
		"local __pack = table.pack or "
			.. "function(...) return {n = select('#', ...), ...} end"
	)
	push("local __unpack = table.unpack or unpack")
	push("local __ZERO = {__index = function() return 0 end}")
	push("local __NORET = {}") -- sentinel: a try body that returned no value

	-- forward-declare every function name so call order / mutual recursion work
	local names = {}
	for _, n in ipairs(body) do
		if n.type == "function" then names[#names + 1] = n.name end
	end
	if #names > 0 then push("local " .. table.concat(names, ", ")) end

	-- Per-function minimum arg count over all internal call sites. Calls are
	-- always by name (Nova has no first-class functions), so this is a complete
	-- static view. A parameter needs its `or 0` default only if some call passes
	-- fewer args than its position; a function never called internally has no
	-- entry here and is treated as saturated (the runner pads entry args to 0).
	local min_args = {}
	local function scan(node)
		if type(node) ~= "table" then return end
		if node.type == "call" then
			local cur = min_args[node.name]
			if cur == nil or #node.args < cur then
				min_args[node.name] = #node.args
			end
		end
		for _, v in pairs(node) do
			scan(v)
		end
	end
	scan(body)

	for _, n in ipairs(body) do
		if n.type == "function" then
			-- fresh scalar-type scope for this function; param types
			-- seed is_int
			-- (param.type is a bare type-name string in the parser)
			typeenv = {}
			local ps = {}
			for i, p in ipairs(n.params) do
				ps[i] = p.name
				typeenv[p.name] = is_int_type(p.type) and "int" or "float"
			end
			push(
				"function "
					.. n.name
					.. "("
					.. table.concat(ps, ", ")
					.. ")"
			)
			ind = ind + 1
			-- default a missing arg to 0 (the VM zero-filled unbound
			-- params), but only for params some call under-supplies:
			-- saturated params skip it. `or 0` only rewrites nil; numbers
			-- (incl. 0), strings, arrays pass thru.
			local ma = min_args[n.name]
			for idx, p in ipairs(ps) do
				if ma ~= nil and ma < idx then
					push(p .. " = " .. p .. " or 0")
				end
			end
			push("do") -- wrap body so a fall-through can `return 0`
			ind = ind + 1
			block(n.body, nil)
			ind = ind - 1
			push("end")
			push("return 0")
			ind = ind - 1
			push("end")
		end
	end

	local kv = {}
	for _, nm in ipairs(names) do
		kv[#kv + 1] = nm .. " = " .. nm
	end
	push("return {" .. table.concat(kv, ", ") .. "}")

	return table.concat(buf, "\n")
end

-- Compile Nova `body` and load it. `env` supplies builtins/imports (and falls
-- back to globals); returns a table mapping function name -> Lua function.
function Avon.load(body, env)
	env = setmetatable(env or {}, { __index = _G })
	local src = Avon.compile(body)
	local chunk, err
	if setfenv then -- Lua 5.1 / LuaJIT: no env arg on load, set it explicitly
		chunk, err = load(src, "=nova")
		if chunk then setfenv(chunk, env) end
	else -- Lua 5.2+: pass the environment to load
		chunk, err = load(src, "=nova", "t", env)
	end
	if not chunk then error("transpile load failed: " .. tostring(err)) end
	return chunk(), src
end

return Avon
