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
--   - `+` concatenates if either side has string type (is_str)
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
--
-- The emitters below take a compile context `cx` (buffer, indent, type maps,
-- label counters) instead of capturing it as upvalues, so they live at file
-- scope and each stays shallow rather than nesting inside one big compile().
local Avon = {}

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

-- mutually recursive emitters (E <-> E_binary <-> Econd, emit_stmt <-> block),
-- forward-declared so the bodies below can reference each other.
local E, E_binary, Econd, is_int, is_str, args_str
local emit_decl, emit_decl_list, emit_for_init, emit_assign, emit_for
local emit_stmt, emit_switch, emit_try, block

-- append one source line at the current indent
local function push(cx, s) cx.buf[#cx.buf + 1] = string.rep("  ", cx.ind) .. s end

-- mint a fresh `continue`-target label
local function newcont(cx)
	cx.labelc = cx.labelc + 1
	return "__cont" .. cx.labelc
end

-- resolve a type name through any typedef chain to its underlying builtin
local function resolve_type(cx, name)
	local seen = 0
	while cx.typedefs[name] and seen < 16 do
		name = cx.typedefs[name]
		seen = seen + 1
	end
	return name
end

-- `str`/`string` are the Nova string type; everything else is numeric
local function is_str_type(cx, name)
	name = resolve_type(cx, name)
	return name == "str" or name == "string"
end

-- a Nova type name is int unless it resolves to `float` or a string type
local function is_int_type(cx, name)
	name = resolve_type(cx, name)
	return name ~= "float" and name ~= "str" and name ~= "string"
end

-- the per-variable typeenv tag for a scalar type name: drives is_int/is_str
local function scalar_tag(cx, name)
	if is_str_type(cx, name) then return "str" end
	return is_int_type(cx, name) and "int" or "float"
end

function args_str(cx, list)
	local t = {}
	for i, a in ipairs(list) do
		t[i] = E(cx, a)
	end
	return table.concat(t, ", ")
end

-- collect every name a function binds: params (added by the caller) plus every
-- `decl` -- locals, array decls, for-/forin-init and decl-list members are all
-- stamped type="decl" by the parser -- and every catch variable, walked deep so
-- names bound inside nested blocks count. Function-wide rather than block-scoped
-- on purpose: that leniency can only MISS a stale-use error, never wrongly
-- reject a name that is in fact bound somewhere in the function.
local function collect_bound(node, set)
	if type(node) ~= "table" then return end
	if node.type == "decl" then set[node.name] = true end
	if node.type == "try" then set[node.catchVar] = true end
	for _, v in pairs(node) do
		collect_bound(v, set)
	end
end

-- a bare Nova name must resolve to something real: a local/param/loop/catch
-- var, an enum constant, a user function, or a host name reachable through the
-- compile env (which chains to _G). Anything else is a typo that would otherwise
-- read as a silent nil -- a nil value, or a nil-call -- at run time, so reject
-- it at compile time. Only the leading segment of a dotted name is checked:
-- `a.b.c` rides on `a` resolving to a module/table. Skips entirely when no env
-- is wired (a direct Avon.compile with no host environment to check against).
local function check_name(cx, name)
	if not cx.env then return end
	local base = name:match("^[^.]+")
	if cx.bound[base] or cx.consts[base] ~= nil or cx.funcs[base] then return end
	if cx.env[base] ~= nil then return end
	error("unknown name '" .. base .. "'")
end

function E(cx, node)
	local t = node.type
	if t == "literal" then
		if type(node.value) == "string" then
			return string.format("%q", node.value)
		end
		return tostring(node.value)
	elseif t == "null" then
		return "nil"
	elseif t == "identifier" then
		check_name(cx, node.name)
		local c = cx.consts[node.name]
		if c ~= nil then return tostring(c) end
		return node.name
	elseif t == "index" then
		-- E(array) is already a valid Lua prefix (a name, a chained index, or
		-- a parenthesized call), so no extra parens: a leading '(' here would
		-- glue onto the previous statement as a call.
		return E(cx, node.array) .. "[" .. E(cx, node.index) .. "]"
	elseif t == "unary" then
		local r = E(cx, node.right)
		if node.op == "!" then return "((" .. r .. ") == 0 and 1 or 0)" end
		if node.op == "~" then
			return JIT and ("bit.bnot(" .. r .. ")") or ("(~(" .. r .. "))")
		end
		return "(-(" .. r .. "))"
	elseif t == "ternary" then
		return "("
			.. Econd(cx, node.cond)
			.. " and ("
			.. E(cx, node.thenE)
			.. ") or ("
			.. E(cx, node.elseE)
			.. "))"
	elseif t == "call" then
		-- parenthesize so a multi-return call yields only its primary value in
		-- expression position (matches the VM taking result slot 0);
		-- destructure and bare-call-statement build their own call text and
		-- keep all values
		if node.name then check_name(cx, node.name) end
		local fn = node.name or ("(" .. E(cx, node.callee) .. ")")
		return "(" .. fn .. "(" .. args_str(cx, node.args) .. "))"
	elseif t == "member" then
		return E(cx, node.obj) .. "." .. node.field
	elseif t == "binary" then
		return E_binary(cx, node)
	end
	error("transpile expr: unhandled " .. tostring(t))
end

-- is_int(node): does this expression have Nova int type? Drives truncating vs
-- real division, decided statically because LuaJIT has no int subtype. Unknowns
-- default conservatively: undeclared names -> int (Nova's default), unknown
-- calls / non-named array bases -> not int (real division).
function is_int(cx, node)
	local t = node.type
	if t == "literal" then
		return type(node.value) ~= "string" and not node.isFloat
	elseif t == "identifier" then
		if cx.consts[node.name] ~= nil then return true end
		local ty = cx.typeenv[node.name]
		return ty == nil or ty == "int"
	elseif t == "index" then
		return node.array.type == "identifier"
			and cx.typeenv[node.array.name] == "arr:int"
	elseif t == "member" then
		return false -- host field access: unknown type, treat as real
	elseif t == "call" then
		return node.name ~= nil and cx.ret_int[node.name] == true
	elseif t == "unary" then
		if node.op == "!" or node.op == "~" then return true end
		return is_int(cx, node.right) -- unary minus
	elseif t == "ternary" then
		return is_int(cx, node.thenE) and is_int(cx, node.elseE)
	elseif t == "binary" then
		local op = node.op
		if op == "&&" or op == "||" or cmp[op] then return true end
		if op == "&" or op == "|" or op == "^" or op == "<<" or op == ">>" then
			return true
		end
		if op == "+" and (is_str(cx, node.left) or is_str(cx, node.right)) then
			return false -- string concatenation
		end
		return is_int(cx, node.left) and is_int(cx, node.right)
	end
	return false
end

-- is_str(node): does this expression have Nova string type? Drives `+`
-- concatenation vs numeric add. String-ness propagates through `+` (so chained
-- builds stay strings) and the two branches of a ternary; everything else
-- (numbers, host field access, unknown calls) is treated as non-string.
function is_str(cx, node)
	local t = node.type
	if t == "literal" then
		return type(node.value) == "string"
	elseif t == "identifier" then
		return cx.typeenv[node.name] == "str"
	elseif t == "call" then
		return node.name ~= nil and cx.ret_str[node.name] == true
	elseif t == "ternary" then
		return is_str(cx, node.thenE) or is_str(cx, node.elseE)
	elseif t == "binary" then
		return node.op == "+"
			and (is_str(cx, node.left) or is_str(cx, node.right))
	end
	return false
end

-- Econd(node): a Lua boolean expression for `node` tested as a Nova truth value
-- (non-zero). Comparisons and && / || stay boolean and short-circuit; anything
-- else falls back to `(value) ~= 0`. In a condition the `1/0` round-trip is
-- wasted (it was the top line in every loop under the profiler).
function Econd(cx, node)
	if node.type == "binary" then
		local op = node.op
		if op == "&&" then
			return "("
				.. Econd(cx, node.left)
				.. " and "
				.. Econd(cx, node.right)
				.. ")"
		elseif op == "||" then
			return "("
				.. Econd(cx, node.left)
				.. " or "
				.. Econd(cx, node.right)
				.. ")"
		elseif cmp[op] then
			return "(("
				.. E(cx, node.left)
				.. ") "
				.. cmp[op]
				.. " ("
				.. E(cx, node.right)
				.. "))"
		end
	elseif node.type == "unary" and node.op == "!" then
		return "((" .. E(cx, node.right) .. ") == 0)"
	end
	return "((" .. E(cx, node) .. ") ~= 0)"
end

function E_binary(cx, node)
	local op = node.op
	if op == "=" then
		error("transpile: assignment in expression position unsupported")
	end
	-- boolean-valued ops: build the Lua boolean, then materialize to 1/0
	if op == "&&" or op == "||" or cmp[op] then
		return "(" .. Econd(cx, node) .. " and 1 or 0)"
	end
	local L, R = E(cx, node.left), E(cx, node.right)
	if op == "+" then
		if is_str(cx, node.left) or is_str(cx, node.right) then
			return "(tostring(" .. L .. ") .. tostring(" .. R .. "))"
		end
		return "((" .. L .. ") + (" .. R .. "))"
	end
	if op == "-" or op == "*" then
		return "((" .. L .. ") " .. op .. " (" .. R .. "))"
	end
	-- int/int truncates toward zero; otherwise real division (static choice)
	if op == "/" then
		if is_int(cx, node.left) and is_int(cx, node.right) then
			return "__idiv(" .. L .. ", " .. R .. ")"
		end
		return "((" .. L .. ") / (" .. R .. "))"
	end
	if op == "%" then
		if is_int(cx, node.left) and is_int(cx, node.right) then
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
		if jb[op] then return "bit." .. jb[op] .. "(" .. L .. ", " .. R .. ")" end
	else
		local lb = {
			["&"] = "&",
			["|"] = "|",
			["^"] = "~",
			["<<"] = "<<",
			[">>"] = ">>",
		}
		if lb[op] then return "((" .. L .. ") " .. lb[op] .. " (" .. R .. "))" end
	end
	error("transpile binary: unhandled " .. tostring(op))
end

function emit_decl(cx, d)
	-- file-scope decls are forward-declared locals: assign, don't re-declare
	local pre = cx.filedecl and "" or "local "
	if d.varType and d.varType.type == "arraytype" then
		cx.typeenv[d.name] = is_int_type(cx, d.varType.base) and "arr:int"
			or "arr:float"
		push(cx, pre .. d.name .. " = setmetatable({}, __ZERO)")
	else
		local tag = scalar_tag(cx, d.varType and d.varType.name)
		cx.typeenv[d.name] = tag
		-- uninitialized scalars zero-fill; an uninitialized string starts empty
		local default = tag == "str" and '""' or "0"
		push(
			cx,
			pre .. d.name .. " = " .. (d.value and E(cx, d.value) or default)
		)
	end
end

-- a bare decl list (no .type): `int a, b = f()` destructures when it fits the
-- shape, otherwise each decl emits on its own line.
function emit_decl_list(cx, decls)
	if is_destructure(decls) then
		local call = decls[#decls].value
		if call.name then check_name(cx, call.name) end
		local ns = {}
		for i, d in ipairs(decls) do
			ns[i] = d.name
			cx.typeenv[d.name] = scalar_tag(cx, d.varType and d.varType.name)
		end
		push(
			cx,
			(cx.filedecl and "" or "local ")
				.. table.concat(ns, ", ")
				.. " = "
				.. (call.name or ("(" .. E(cx, call.callee) .. ")"))
				.. "("
				.. args_str(cx, call.args)
				.. ")"
		)
	else
		for _, d in ipairs(decls) do
			emit_decl(cx, d)
		end
	end
end

-- collect every identifier name referenced in an expression subtree
local function expr_names(node, out)
	if type(node) ~= "table" then return out end
	if node.type == "identifier" then out[node.name] = true end
	for _, v in pairs(node) do
		expr_names(v, out)
	end
	return out
end

-- does any assignment in this AST subtree target a name in `names`? (`++`/`+=`
-- desugar to `=` at parse, so this also catches those.)
local function assigns_name(node, names)
	if type(node) ~= "table" then return false end
	if node.type == "binary" and node.op == "=" then
		local tgt = node.left
		local nm = tgt.type == "identifier" and tgt.name
			or (
				tgt.type == "index"
				and tgt.array.type == "identifier"
				and tgt.array.name
			)
		if nm and names[nm] then return true end
	end
	for _, v in pairs(node) do
		if type(v) == "table" and assigns_name(v, names) then return true end
	end
	return false
end

-- recognize the canonical counting loop `for int i = a; i < b; ++i` so it can
-- map to Lua's numeric for (a dedicated, faster opcode). Returns var, start,
-- limit, op or nil. Conservative: numeric for fixes the counter and limit at
-- entry, so require an int counter stepping by +1 and a body that assigns
-- neither the counter nor any variable in the limit.
local function counting_loop(cx, node)
	local init = node.init
	if init.type or #init ~= 1 then return nil end -- one decl, not an expr
	local d = init[1]
	if not d.value then return nil end
	if not is_int_type(cx, d.varType and d.varType.name) then return nil end
	local var = d.name

	local c = node.cond -- var < limit  /  var <= limit
	if c.type ~= "binary" or (c.op ~= "<" and c.op ~= "<=") then return nil end
	if c.left.type ~= "identifier" or c.left.name ~= var then return nil end
	local limit = c.right
	if not is_int(cx, limit) then return nil end

	local u = node.update -- var = var + 1  (also ++var, var += 1)
	if u.type ~= "binary" or u.op ~= "=" then return nil end
	if u.left.type ~= "identifier" or u.left.name ~= var then return nil end
	local r = u.right
	if r.type ~= "binary" or r.op ~= "+" then return nil end
	local plus_one = (
		r.left.type == "identifier"
		and r.left.name == var
		and r.right.type == "literal"
		and r.right.value == 1
	)
		or (
			r.right.type == "identifier"
			and r.right.name == var
			and r.left.type == "literal"
			and r.left.value == 1
		)
	if not plus_one then return nil end

	local names = expr_names(limit, { [var] = true })
	if assigns_name(node.body, names) then return nil end
	return var, d.value, limit, c.op
end

-- a for-init is either a decl list (looped, never destructured) or one statement
function emit_for_init(cx, init, cl)
	if not init.type then
		for _, d in ipairs(init) do
			emit_decl(cx, d)
		end
	else
		emit_stmt(cx, init, cl)
	end
end

-- assignment statement: `arr[i] = v` indexes the target, plain `x = v` names it
function emit_assign(cx, node)
	local tgt = node.left
	if tgt.type == "index" then
		push(
			cx,
			E(cx, tgt.array)
				.. "["
				.. E(cx, tgt.index)
				.. "] = "
				.. E(cx, node.right)
		)
	else
		push(cx, tgt.name .. " = " .. E(cx, node.right))
	end
end

function emit_stmt(cx, node, cl)
	if not node.type then return emit_decl_list(cx, node) end -- decl list

	local t = node.type
	if t == "decl" then
		emit_decl(cx, node)
	elseif t == "binary" then
		if node.op == "=" then
			emit_assign(cx, node)
		else
			push(cx, "local _ = " .. E(cx, node)) -- bare expression (rare)
		end
	elseif t == "call" then
		if node.name then check_name(cx, node.name) end
		local fn = node.name or ("(" .. E(cx, node.callee) .. ")")
		push(cx, fn .. "(" .. args_str(cx, node.args) .. ")")
	elseif t == "index" or t == "identifier" or t == "literal" then
		push(cx, "local _ = " .. E(cx, node))
	elseif t == "if" then
		push(cx, "if " .. Econd(cx, node.cond) .. " then")
		cx.ind = cx.ind + 1
		block(cx, node.thenBranch, cl)
		cx.ind = cx.ind - 1
		if node.elseBranch then
			push(cx, "else")
			cx.ind = cx.ind + 1
			block(cx, node.elseBranch, cl)
			cx.ind = cx.ind - 1
		end
		push(cx, "end")
	elseif t == "for" then
		emit_for(cx, node, cl)
	elseif t == "forin" then
		local decl = node.init[1]
		push(cx, "do")
		cx.ind = cx.ind + 1
		push(cx, "local " .. decl.name)
		local mycl = newcont(cx)
		push(cx, "while true do")
		cx.ind = cx.ind + 1
		push(cx, decl.name .. " = " .. E(cx, decl.value))
		push(cx, "if " .. decl.name .. " == 0 then break end")
		push(cx, "do")
		cx.ind = cx.ind + 1
		block(cx, node.body, mycl)
		cx.ind = cx.ind - 1
		push(cx, "end")
		push(cx, "::" .. mycl .. "::")
		cx.ind = cx.ind - 1
		push(cx, "end")
		cx.ind = cx.ind - 1
		push(cx, "end")
	elseif t == "switch" then
		emit_switch(cx, node, cl)
	elseif t == "break" then
		push(cx, "break")
	elseif t == "continue" then
		if not cl then error("transpile: continue outside loop") end
		push(cx, "goto " .. cl)
	elseif t == "return" then
		local vs = {}
		for i, e in ipairs(node.values or {}) do
			vs[i] = E(cx, e)
		end
		push(cx, #vs == 0 and "return 0" or ("return " .. table.concat(vs, ", ")))
	elseif t == "throw" then
		push(cx, "error({nova=true, value=" .. E(cx, node.value) .. "}, 0)")
	elseif t == "try" then
		emit_try(cx, node, cl)
	elseif t == "typedef" or t == "enum" or t == "import" or t == "function" then
		-- declaration-level: no statement-position effect
	else
		error("transpile stmt: unhandled " .. tostring(t))
	end
end

function emit_for(cx, node, cl)
	local var, start, limit, op = counting_loop(cx, node)
	if var then
		-- numeric for: faster FORLOOP opcode. `<` is exclusive but Lua's for is
		-- inclusive, so cap at limit-1 (safe: int counter, +1 step).
		local hi = E(cx, limit)
		if op == "<" then hi = "(" .. hi .. ") - 1" end
		cx.typeenv[var] = "int" -- counter type, for is_int in the body
		push(cx, "for " .. var .. " = " .. E(cx, start) .. ", " .. hi .. " do")
		cx.ind = cx.ind + 1
		local mycl = newcont(cx)
		push(cx, "do") -- body scope: keeps a continue's goto legal
		cx.ind = cx.ind + 1
		block(cx, node.body, mycl)
		cx.ind = cx.ind - 1
		push(cx, "end")
		push(cx, "::" .. mycl .. "::") -- continue lands here; for then steps
		cx.ind = cx.ind - 1
		push(cx, "end")
		return
	end

	-- general C-style loop: a while with the init/update spelled out
	push(cx, "do")
	cx.ind = cx.ind + 1
	emit_for_init(cx, node.init, cl)
	local mycl = newcont(cx)
	push(cx, "while " .. Econd(cx, node.cond) .. " do")
	cx.ind = cx.ind + 1
	push(cx, "do")
	cx.ind = cx.ind + 1 -- body scope: keeps goto legal
	block(cx, node.body, mycl)
	cx.ind = cx.ind - 1
	push(cx, "end")
	push(cx, "::" .. mycl .. "::")
	emit_stmt(cx, node.update, cl)
	cx.ind = cx.ind - 1
	push(cx, "end")
	cx.ind = cx.ind - 1
	push(cx, "end")
end

function emit_switch(cx, node, cl)
	cx.subjc = cx.subjc + 1
	local sv = "__subj" .. cx.subjc
	push(cx, "do")
	cx.ind = cx.ind + 1
	push(cx, "local " .. sv .. " = " .. E(cx, node.subject))
	local first = true
	for _, c in ipairs(node.cases) do
		push(
			cx,
			(first and "if " or "elseif ")
				.. sv
				.. " == ("
				.. E(cx, c.value)
				.. ") then"
		)
		first = false
		cx.ind = cx.ind + 1
		block(cx, c.body, cl)
		cx.ind = cx.ind - 1
	end
	if node.default then
		push(cx, first and "if true then" or "else")
		cx.ind = cx.ind + 1
		block(cx, node.default, cl)
		cx.ind = cx.ind - 1
		push(cx, "end")
	elseif not first then
		push(cx, "end")
	end
	cx.ind = cx.ind - 1
	push(cx, "end")
end

-- pcall the body in a closure. A `return` inside the body returns from the
-- closure; we capture those values (table.pack) and re-return them from the
-- real function, so try bodies can return. __NORET marks "fell through" (no
-- return). The `do ... end` lets a body return be the last statement and still
-- allow the trailing `return __NORET` fallthrough.
function emit_try(cx, node, cl)
	cx.tryc = cx.tryc + 1
	local r = "__try" .. cx.tryc
	push(cx, "local " .. r .. " = __pack(pcall(function()")
	cx.ind = cx.ind + 1
	push(cx, "do")
	cx.ind = cx.ind + 1
	block(cx, node.body, nil)
	cx.ind = cx.ind - 1
	push(cx, "end")
	push(cx, "return __NORET")
	cx.ind = cx.ind - 1
	push(cx, "end))")
	push(cx, "if " .. r .. "[1] then")
	cx.ind = cx.ind + 1
	push(
		cx,
		"if "
			.. r
			.. "[2] ~= __NORET then return __unpack("
			.. r
			.. ", 2, "
			.. r
			.. ".n) end"
	)
	cx.ind = cx.ind - 1
	push(cx, "else")
	cx.ind = cx.ind + 1
	push(
		cx,
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
	block(cx, node.handler, cl)
	cx.ind = cx.ind - 1
	push(cx, "end")
end

function block(cx, list, cl)
	for _, st in ipairs(list) do
		emit_stmt(cx, st, cl)
		local tt = st.type
		if tt == "return" or tt == "break" or tt == "continue" then
			break -- Lua requires these terminal in their block
		end
	end
end

-- emit one Nova function: signature, missing-arg defaults, body, fallthrough
local function emit_function(cx, n, min_args)
	-- fresh scalar-type scope; param types seed is_int (param.type is a bare
	-- type-name string in the parser). File-scope vars seed both scopes:
	-- visible everywhere, params/locals shadow them
	cx.typeenv = {}
	cx.bound = {} -- fresh bound-name scope for the unbound-name check
	for k, v in pairs(cx.filevars) do
		cx.typeenv[k] = v
		cx.bound[k] = true
	end
	local ps = {}
	for i, p in ipairs(n.params) do
		ps[i] = p.name
		cx.typeenv[p.name] = scalar_tag(cx, p.type)
		cx.bound[p.name] = true
	end
	collect_bound(n.body, cx.bound)
	push(cx, "function " .. n.name .. "(" .. table.concat(ps, ", ") .. ")")
	cx.ind = cx.ind + 1
	-- default a missing arg to 0 (the VM zero-filled unbound params), but only
	-- for params some call under-supplies: saturated params skip it. `or 0`
	-- only rewrites nil; numbers (incl. 0), strings, arrays pass thru.
	local ma = min_args[n.name]
	for idx, p in ipairs(ps) do
		if ma ~= nil and ma < idx then push(cx, p .. " = " .. p .. " or 0") end
	end
	push(cx, "do") -- wrap body so a fall-through can `return 0`
	cx.ind = cx.ind + 1
	block(cx, n.body, nil)
	cx.ind = cx.ind - 1
	push(cx, "end")
	push(cx, "return 0")
	cx.ind = cx.ind - 1
	push(cx, "end")
end

-- the minimum arg count seen at any internal call site, per function name.
-- Nova functions are always called by name (no first-class functions), so this
-- is a complete static view of them; chained host calls (a `callee`, no name)
-- are skipped. A parameter needs its `or 0` default only if some call passes
-- fewer args than its position; a function never called internally has no entry
-- and is treated as saturated (the runner pads entry args to 0).
local function scan_min_args(body)
	local min_args = {}
	local function scan(node)
		if type(node) ~= "table" then return end
		if node.type == "call" and node.name then
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
	return min_args
end

-- emit the prelude: semantic shims, as upvalues (not globals). int division and
-- mod are pre-selected by is_int, so these helpers are unconditional.
local function emit_prelude(cx)
	if JIT then push(cx, "local bit = require('bit')") end
	push(cx, "local __floor, __ceil, __fmod = math.floor, math.ceil, math.fmod")
	-- round toward zero, inlined into both helpers: a separate __trunc would add
	-- a Lua call to every int / and % (3-deep chain vs 2), and on the
	-- interpreted 5.3/5.4 path that is ~a third of the calls on div/mod-heavy
	-- code. q >= 0 picks floor, else ceil -- truncation toward zero, the C `/`.
	push(cx, "local function __idiv(a, b)")
	push(cx, "  local q = a / b")
	push(cx, "  if q >= 0 then return __floor(q) else return __ceil(q) end")
	push(cx, "end")
	push(cx, "local function __imod(a, b)")
	push(cx, "  local q = a / b")
	push(cx, "  local t = q >= 0 and __floor(q) or __ceil(q)")
	push(cx, "  return a - t * b")
	push(cx, "end")
	-- table.pack/unpack are 5.2+; LuaJIT (5.1) needs the fallbacks
	push(
		cx,
		"local __pack = table.pack or "
			.. "function(...) return {n = select('#', ...), ...} end"
	)
	push(cx, "local __unpack = table.unpack or unpack")
	push(cx, "local __ZERO = {__index = function() return 0 end}")
	push(cx, "local __NORET = {}") -- sentinel: a try body that returned no value
end

function Avon.compile(body, env)
	local cx = {
		buf = {},
		ind = 0,
		consts = {}, -- enum variant -> integer value
		typedefs = {}, -- typedef alias -> base type name
		ret_int = {}, -- user function name -> first return type is int?
		ret_str = {}, -- user function name -> first return type is str?
		typeenv = {}, -- per-function scalar types, reset before each function
		funcs = {}, -- every user function name (for the unbound-name check)
		bound = {}, -- names bound in the current function, reset per function
		env = env, -- host environment (chains to _G); nil = skip name checks
		labelc = 0,
		subjc = 0,
		tryc = 0,
	}
	for _, n in ipairs(body) do
		if n.type == "enum" then
			for i, v in ipairs(n.variants) do
				cx.consts[v] = i - 1
			end
		elseif n.type == "typedef" then
			cx.typedefs[n.alias] = n.base and n.base.name or nil
		end
	end
	for _, n in ipairs(body) do
		if n.type == "function" then
			local rt = n.returnTypes and n.returnTypes[1]
			cx.ret_int[n.name] = is_int_type(cx, rt)
			cx.ret_str[n.name] = is_str_type(cx, rt)
			cx.funcs[n.name] = true
		end
	end

	emit_prelude(cx)

	-- forward-declare every function name so call order / mutual recursion
	-- work; file-scope var names join them so function bodies capture them
	-- as upvalues (a top-level decl list is a body entry with no .type)
	local names, fwd = {}, {}
	for _, n in ipairs(body) do
		if n.type == "function" then
			names[#names + 1] = n.name
			fwd[#fwd + 1] = n.name
		elseif not n.type then
			for _, d in ipairs(n) do
				fwd[#fwd + 1] = d.name
			end
		end
	end
	if #fwd > 0 then push(cx, "local " .. table.concat(fwd, ", ")) end

	-- file-scope decls render into a side buffer FIRST (fills typeenv/bound
	-- so function bodies type them), but splice into the chunk AFTER the
	-- function definitions, so an initializer may call user functions
	for _, n in ipairs(body) do
		if not n.type then collect_bound(n, cx.bound) end
	end
	local chunk = cx.buf
	cx.buf = {}
	cx.filedecl = true
	for _, n in ipairs(body) do
		if not n.type then emit_decl_list(cx, n) end
	end
	cx.filedecl = nil
	local decl_lines = cx.buf
	cx.buf = chunk
	cx.filevars = cx.typeenv

	local min_args = scan_min_args(body)
	for _, n in ipairs(body) do
		if n.type == "function" then emit_function(cx, n, min_args) end
	end
	for _, line in ipairs(decl_lines) do
		cx.buf[#cx.buf + 1] = line
	end

	local kv = {}
	for _, nm in ipairs(names) do
		kv[#kv + 1] = nm .. " = " .. nm
	end
	push(cx, "return {" .. table.concat(kv, ", ") .. "}")

	return table.concat(cx.buf, "\n")
end

-- Compile Nova `body` and load it. `env` supplies builtins/imports (and falls
-- back to globals); returns a table mapping function name -> Lua function.
function Avon.load(body, env)
	env = setmetatable(env or {}, { __index = _G })
	local src = Avon.compile(body, env)
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
