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
-- Targets both PUC Lua and LuaJIT (Lua 5.1 + the `bit` library). Which one is
-- detected from the host running the compiler (the `jit` global), never from a
-- version number, so a new PUC release needs no change here: bitwise ops emit
-- native operators on PUC and bit.* calls on LuaJIT.
--
-- That detection happens at COMPILE time, so the emitted chunk is specific to
-- the host that produced it: bit.* output cannot load on PUC, which has no
-- `bit` module. The invariant that makes this safe is that nothing outlives
-- the process -- avon compiles and runs under the same interpreter, so the two
-- always agree. The one feature that ever broke it was the .novac bytecode
-- cache, which handled it by keying each entry on the runtime and refusing a
-- mismatch. Any future ahead-of-time mode that writes emission to disk needs
-- the same guard; without one, a cross-host artifact fails at load.
--
-- try/catch is a pcall around the body. Where the body proves safe
-- (try_hoist_params) it compiles to a chunk-level function called with its
-- free locals -- created once at load, so a try in a hot loop stays on
-- trace (closure creation is NYI in LuaJIT); otherwise it falls back to an
-- inline closure per entry. A `return` inside the try BODY is captured (the
-- __NORET sentinel) and re-returned from the function, so try bodies can
-- return. The only residue: a `break`/`continue` in a try body that targets
-- a loop OUTSIDE the try cannot cross the pcalled function -- Lua rejects it
-- at load (a loud error, never a silent miscompile); break/continue to a
-- loop that is itself inside the body work fine.
--
-- Provably simple `int[N]`/`float[N]` locals compile to ffi double[N] under
-- LuaJIT (scan_ffi_arrays); everything unproven keeps the __ZERO table.
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

-- ffi fixed arrays are only worth emitting where the JIT compiles them
local FFI_OK = JIT and pcall(require, "ffi")

-- Deterministic per-source chunk name. Runtime errors are prefixed with it
-- ("<id>:<generated line>:"), and the emitted __SRC shim matches its OWN
-- chunk's prefix only -- so an error crossing module boundaries is never
-- mistranslated through the wrong module's line map. Derived from the
-- source text (not a counter) so the same module always gets the same name,
-- independent of load order.
local function chunk_id(src)
	local sum = 0
	for i = 1, #src, 17 do
		sum = (sum * 31 + src:byte(i)) % 1000003
	end
	return "nova#" .. #src .. "_" .. sum
end

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
local E, E_binary, Econd, is_int, is_str, is_truthy, args_str, raw_call
local E_typed
local emit_decl, emit_decl_list, emit_for_init, emit_assign, emit_for
local emit_stmt, emit_switch, emit_try, block

-- append one source line at the current indent, recording which Nova source
-- line it came from (cx.srcline, maintained by emit_stmt) in the parallel
-- cx.map -- the raw material for the runtime error line map
local function push(cx, s)
	local n = #cx.buf + 1
	cx.buf[n] = string.rep("  ", cx.ind) .. s
	cx.map[n] = cx.srcline
end

-- append `lines` (and their map, when given) to the current buffer
local function append_buf(cx, lines, map)
	local buf, mp, n = cx.buf, cx.map, #cx.buf
	for i, line in ipairs(lines) do
		buf[n + i] = line
		mp[n + i] = map and map[i] or nil
	end
end

-- mint a fresh `continue`-target label
local function newcont(cx)
	cx.labelc = cx.labelc + 1
	return "__cont" .. cx.labelc
end

-- mint a fresh prefill-loop counter
local function newprefill(cx)
	cx.prefillc = cx.prefillc + 1
	return "__p" .. cx.prefillc
end

-- mint a fresh capture temporary
local function newtmp(cx)
	cx.tmpc = cx.tmpc + 1
	return "__t" .. cx.tmpc
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

-- Argument list for a call. When the callee is a user function, each argument
-- lands in a slot with a declared type, so an int param narrows its argument
-- exactly as a decl or an assignment would -- otherwise a host value passed
-- into `fn f(int n)` leaves `n` int-tagged while holding a boolean, and every
-- is_int decision in that body reads a tag the value does not honour.
function args_str(cx, list, fname)
	local ps = fname and cx.paramtypes[fname]
	local t = {}
	for i, a in ipairs(list) do
		local p = ps and ps[i]
		t[i] = p and E_typed(cx, p.type, a) or E(cx, a)
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

-- 1-based line:col of byte offset `pos` in `src` (mirrors Tokenizer:linecol)
local function linecol(src, pos)
	local line, last = 1, 0
	for at in src:sub(1, pos):gmatch("()\n") do
		line = line + 1
		last = at
	end
	return line, pos - last
end

-- "L:C: " prefix for a node's source offset; "" when the source or the
-- offset is not wired (a direct Avon.compile without opts.src)
local function at(cx, pos)
	if not (cx.src and pos) then return "" end
	local l, c = linecol(cx.src, pos)
	return l .. ":" .. c .. ": "
end

-- earliest source offset carried anywhere in a statement's subtree: the
-- statement's own line for the runtime error map
local function first_pos(node)
	if type(node) ~= "table" then return nil end
	local best = node.pos
	for _, v in pairs(node) do
		if type(v) == "table" then
			local p = first_pos(v)
			if p and (not best or p < best) then best = p end
		end
	end
	return best
end

-- memoized source line of a byte offset
local function src_line(cx, pos)
	local c = cx.linecache[pos]
	if c then return c end
	local l = linecol(cx.src, pos)
	cx.linecache[pos] = l
	return l
end

-- a bare Nova name must resolve to something real: a local/param/loop/catch
-- var, an enum constant, a user function, or a host name reachable through the
-- compile env (which chains to _G). Anything else is a typo that would otherwise
-- read as a silent nil -- a nil value, or a nil-call -- at run time, so reject
-- it at compile time. Only the leading segment of a dotted name is checked:
-- `a.b.c` rides on `a` resolving to a module/table. Skips entirely when no env
-- is wired (a direct Avon.compile with no host environment to check against).
-- `pos` (the node's source offset) tags the error with line:col; level 0
-- keeps the message free of Lua's own file:line prefix.
local function check_name(cx, name, pos)
	if not cx.env then return end
	local base = name:match("^[^.]+")
	if cx.bound[base] or cx.consts[base] ~= nil or cx.funcs[base] then
		return
	end
	if cx.env[base] ~= nil then return end
	error(at(cx, pos) .. "unknown name '" .. base .. "'", 0)
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
		check_name(cx, node.name, node.pos)
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
		if node.op == "!" then
			return "((" .. r .. ") == 0 and 1 or 0)"
		end
		if node.op == "~" then
			if JIT then
				cx.used.bit = true
				return "bit.bnot(" .. r .. ")"
			end
			return "(~(" .. r .. "))"
		end
		return "(-(" .. r .. "))"
	elseif t == "ternary" then
		-- `c and (A) or (B)` returns B whenever A is falsy, whatever c was,
		-- so it is only sound when A cannot be nil or false. That holds for
		-- any number or string (is_truthy), which is nearly all real code.
		-- Otherwise -- `null`, a host call, a host field -- wrap the arms in
		-- tables: `and`/`or` still constructs exactly one, so evaluation stays
		-- short-circuit, and a table is always truthy. The table form is free
		-- under LuaJIT (allocation sinking) but ~6x the bare form on PUC,
		-- which is why it is not emitted unconditionally.
		local c = Econd(cx, node.cond)
		local a, b = E(cx, node.thenE), E(cx, node.elseE)
		if is_truthy(cx, node.thenE) then
			return "("
				.. c
				.. " and ("
				.. a
				.. ") or ("
				.. b
				.. "))"
		end
		return "((" .. c .. " and {" .. a .. "} or {" .. b .. "})[1])"
	elseif t == "call" then
		-- parenthesize so a multi-return call yields only its primary value in
		-- expression position (matches the VM taking result slot 0);
		-- destructure, bare-call-statement and a trailing `return` call use
		-- raw_call instead and keep all values
		return "(" .. raw_call(cx, node) .. ")"
	elseif t == "member" then
		return E(cx, node.obj) .. "." .. node.field
	elseif t == "binary" then
		return E_binary(cx, node)
	end
	error("transpile expr: unhandled " .. tostring(t))
end

-- call text with no wrapping parens, so a multi-return callee keeps every
-- value. Expression position needs the parens (E adds them) to clamp to the
-- primary value; the list positions Lua expands into do not.
function raw_call(cx, node)
	if node.name then check_name(cx, node.name, node.pos) end
	local fn = node.name or ("(" .. E(cx, node.callee) .. ")")
	return fn .. "(" .. args_str(cx, node.args, node.name) .. ")"
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
			and (is_str(cx, node.left) or is_str(cx, node.right))
		then
			return false -- string concatenation
		end
		return is_int(cx, node.left) and is_int(cx, node.right)
	end
	return false
end

-- narrow `src` (the emission of `e`) into an int slot. A value whose static
-- type is already int needs nothing; one Nova cannot prove int (a host call,
-- a host field, a float source) goes through __toint, so a declared `int`
-- constrains the value instead of merely documenting it.
local function wrap_int(cx, e, src)
	-- a provably-string value can never inhabit an int slot. __toint would pass
	-- it straight through (int is the numeric catch-all, so the shim leaves
	-- non-numbers alone rather than stringify or parse them), so the mismatch
	-- would otherwise surface as garbage far from its cause -- e.g. a `fn int`
	-- that returns "x" printing "x". Reject it here, at its source position,
	-- with the same line:col diagnostic the frontend gives an unbound name.
	-- Only PROVABLE strings are caught: host calls and array/table returns have
	-- is_str = false, so the catch-all int return still admits them unchanged.
	if is_str(cx, e) then
		error(
			at(cx, first_pos(e))
				.. "type error: string value where int is expected",
			0
		)
	end
	if is_int(cx, e) then return src end
	cx.used.__toint = true
	return "__toint(" .. src .. ")"
end

-- Emit `e` for a slot declared with type name `tn`. Non-int slots are emitted
-- verbatim: only int narrows.
function E_typed(cx, tn, e)
	local src = E(cx, e)
	if tn == nil or not is_int_type(cx, tn) then return src end
	return wrap_int(cx, e, src)
end

-- Emit `e` for a slot already carrying a typeenv tag (a bound name or an
-- array cell), rather than a written-out type name.
local function E_tagged(cx, tag, e)
	local src = E(cx, e)
	if tag ~= "int" then return src end
	return wrap_int(cx, e, src)
end

-- Can `e` never evaluate to nil or false? Every Nova literal is a number or a
-- string (`true`/`false` parse to 1/0), and is_int proves a number; both are
-- truthy in Lua, 0 and "" included. `null`, host calls and host fields are
-- exactly what this fails on, which is what the ternary needs to know.
function is_truthy(cx, e)
	if e.type == "literal" then return true end
	return is_int(cx, e)
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
	-- a bare `(v) ~= 0` calls nil truthy, since nil is not equal to 0 -- so
	-- `if null` would take the then-branch, against both C (NULL is false)
	-- and Nova's own rule that 0 is false. Folding nil/false to 0 first
	-- settles it; provably-numeric values skip the extra `or`.
	local v = E(cx, node)
	if is_truthy(cx, node) then return "((" .. v .. ") ~= 0)" end
	return "(((" .. v .. ") or 0) ~= 0)"
end

function E_binary(cx, node)
	local op = node.op
	if op == "=" then
		error(
			"transpile: assignment in expression position unsupported"
		)
	end
	-- boolean-valued ops: build the Lua boolean, then materialize to 1/0
	if op == "&&" or op == "||" or cmp[op] then
		return "(" .. Econd(cx, node) .. " and 1 or 0)"
	end
	local L, R = E(cx, node.left), E(cx, node.right)
	if op == "+" then
		if is_str(cx, node.left) or is_str(cx, node.right) then
			return "(tostring("
				.. L
				.. ") .. tostring("
				.. R
				.. "))"
		end
		return "((" .. L .. ") + (" .. R .. "))"
	end
	if op == "-" or op == "*" then
		return "((" .. L .. ") " .. op .. " (" .. R .. "))"
	end
	-- int/int truncates toward zero; otherwise real division (static choice)
	if op == "/" then
		if is_int(cx, node.left) and is_int(cx, node.right) then
			cx.used.__idiv = true
			return "__idiv(" .. L .. ", " .. R .. ")"
		end
		return "((" .. L .. ") / (" .. R .. "))"
	end
	if op == "%" then
		if is_int(cx, node.left) and is_int(cx, node.right) then
			cx.used.__imod = true
			return "__imod(" .. L .. ", " .. R .. ")"
		end
		cx.used.__fmod = true
		return "__fmod(" .. L .. ", " .. R .. ")"
	end
	-- bitwise: native operators on PUC Lua, the `bit` library on LuaJIT
	if JIT then
		local jb = {
			["&"] = "band",
			["|"] = "bor",
			["^"] = "bxor",
			["<<"] = "lshift",
			[">>"] = "rshift",
		}
		if jb[op] then
			cx.used.bit = true
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

function emit_decl(cx, d)
	-- file-scope decls are forward-declared locals: assign, don't re-declare
	local pre = cx.filedecl and "" or "local "
	if d.varType and d.varType.type == "arraytype" then
		cx.typeenv[d.name] = is_int_type(cx, d.varType.base)
				and "arr:int"
			or "arr:float"
		local sz = cx.ffiarr and cx.ffiarr[d.name]
		if sz then
			-- proven numeric, bounded, non-escaping (scan_ffi_arrays):
			-- ffi fixed array, zero-filled by construction
			cx.arrsizes[sz] = true
			push(cx, pre .. d.name .. " = __arr" .. sz .. "()")
		else
			cx.used.__ZERO = true
			push(cx, pre .. d.name .. " = setmetatable({}, __ZERO)")
			-- reads cover [0,N): materialise it so they hit the array part
			-- instead of faulting through __ZERO one call at a time. The
			-- metatable stays for anything indexed past N.
			local dn = cx.densearr and cx.densearr[d.name]
			if dn then
				local v = newprefill(cx)
				push(
					cx,
					"for "
						.. v
						.. " = 0, "
						.. (dn - 1)
						.. " do "
						.. d.name
						.. "["
						.. v
						.. "] = 0 end"
				)
			end
		end
	else
		local tn = d.varType and d.varType.name
		local tag = scalar_tag(cx, tn)
		cx.typeenv[d.name] = tag
		-- uninitialized scalars zero-fill; an uninitialized string starts empty
		local default = tag == "str" and '""' or "0"
		-- the declared type narrows the initializer: `int n = host.call()`
		-- stores an int, so the typeenv tag it seeds stays truthful for every
		-- is_int decision downstream
		push(
			cx,
			pre
				.. d.name
				.. " = "
				.. (
					d.value
						and E_typed(cx, tn, d.value)
					or default
				)
		)
	end
end

-- a bare decl list (no .type): `int a, b = f()` destructures when it fits the
-- shape, otherwise each decl emits on its own line.
function emit_decl_list(cx, decls)
	if is_destructure(decls) then
		local call = decls[#decls].value
		local ns = {}
		for i, d in ipairs(decls) do
			ns[i] = d.name
			cx.typeenv[d.name] =
				scalar_tag(cx, d.varType and d.varType.name)
		end
		push(
			cx,
			(cx.filedecl and "" or "local ")
				.. table.concat(ns, ", ")
				.. " = "
				.. raw_call(cx, call)
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
		if type(v) == "table" and assigns_name(v, names) then
			return true
		end
	end
	return false
end

-- the ffi analysis' view of a counting loop: literal bounds only, counter
-- declared once and never reassigned in the body. Returns the counter name
-- and its inclusive upper bound, or nil.
local function lite_counter(node)
	local init = node.init
	if init.type or #init ~= 1 then return nil end
	local d, c, u = init[1], node.cond, node.update
	local v = d.value
	if
		not (
			v
			and v.type == "literal"
			and type(v.value) == "number"
			and v.value >= 0
		)
	then
		return nil
	end
	if not (c and c.type == "binary" and (c.op == "<" or c.op == "<=")) then
		return nil
	end
	if c.left.type ~= "identifier" or c.left.name ~= d.name then
		return nil
	end
	if c.right.type ~= "literal" or type(c.right.value) ~= "number" then
		return nil
	end
	if not (u and u.type == "binary" and u.op == "=") then return nil end
	if u.left.type ~= "identifier" or u.left.name ~= d.name then
		return nil
	end
	local r = u.right
	local plus_one = r.type == "binary"
		and r.op == "+"
		and (
			(
				r.left.type == "identifier"
				and r.left.name == d.name
				and r.right.type == "literal"
				and r.right.value == 1
			)
			or (
				r.right.type == "identifier"
				and r.right.name == d.name
				and r.left.type == "literal"
				and r.left.value == 1
			)
		)
	if not plus_one then return nil end
	if assigns_name(node.body, { [d.name] = true }) then return nil end
	return d.name, c.op == "<" and c.right.value - 1 or c.right.value
end

-- ffi fixed-array analysis. An `int[N]`/`float[N]` local can compile to an
-- ffi `double[N]` instead of a `__ZERO`-metatabled table: zero-filled by
-- construction, no rehash growth, raw loads/stores on trace. But Nova
-- arrays are more permissive than a typed array: cells may hold row
-- pointers (jagged grids), indices may run past N (the table just grows),
-- and the array may escape to code this pass cannot see. So a local gets
-- the ffi form only when, within its function, every use proves out:
--   - no escape: the name never appears outside index-base position (a
--     call arg, return value, RHS, ternary arm, or rebind disqualifies)
--   - every store is a provably numeric value (literal, arithmetic over
--     safe operands, or a scalar only ever assigned such values)
--   - every index is a literal in [0,N) or the counter of an enclosing
--     lite_counter loop whose range fits [0,N)
-- Anything unproven keeps the table emission: semantics never change, only
-- the representation of the provably-simple case does.
local function scan_ffi_arrays(cx, params, body)
	if not cx.opts.ffi then return {} end
	local cand, declc, scalars = {}, {}, {}
	local function collect(node)
		if type(node) ~= "table" then return end
		if node.type == "decl" then
			declc[node.name] = (declc[node.name] or 0) + 1
			local vt = node.varType
			if vt and vt.type == "arraytype" then
				if
					type(vt.size) == "number"
					and vt.size > 0
					and not is_str_type(cx, vt.base)
				then
					cand[node.name] = vt.size
				end
			else
				local vs = scalars[node.name] or {}
				scalars[node.name] = vs
				if node.value then vs[#vs + 1] = node.value end
			end
		elseif
			node.type == "binary"
			and node.op == "="
			and node.left.type == "identifier"
		then
			local vs = scalars[node.left.name]
			if vs then vs[#vs + 1] = node.right end
		end
		for _, v in pairs(node) do
			collect(v)
		end
	end
	collect(body)
	for name in pairs(cand) do
		if declc[name] > 1 then cand[name] = nil end -- shadowed: ambiguous
	end
	for _, p in ipairs(params) do
		cand[p.name] = nil -- a param may hold an array; don't reason about it
	end
	if not next(cand) then return cand end

	-- scalar value safety: greatest fixpoint. Start every declared scalar
	-- safe, drop any with a value expression not provably numeric, repeat
	-- until stable so unsafety propagates through scalar-to-scalar copies.
	-- (Reads of array cells are conservatively unsafe: values only.)
	local safe = {}
	for name in pairs(scalars) do
		safe[name] = true
	end
	local function numval(e)
		local t = e.type
		if t == "literal" then return type(e.value) == "number" end
		if t == "identifier" then
			return safe[e.name] == true or cx.consts[e.name] ~= nil
		end
		if t == "unary" then return numval(e.right) end
		if t == "ternary" then
			return numval(e.thenE) and numval(e.elseE)
		end
		if t == "binary" then
			return e.op ~= "="
				and numval(e.left)
				and numval(e.right)
		end
		return false
	end
	repeat
		local changed = false
		for name, vs in pairs(scalars) do
			if safe[name] then
				for _, e in ipairs(vs) do
					if not numval(e) then
						safe[name], changed =
							false, true
						break
					end
				end
			end
		end
	until not changed

	-- value range of an index expression: literals, bounded counters
	-- (over-approximated to [0, hi]), and + / * over nonnegative ranges
	-- (monotone, so endpoints multiply/add). nil = unknown.
	local function range(e, bounds)
		if e.type == "literal" then
			if type(e.value) ~= "number" then return nil end
			return e.value, e.value
		end
		if e.type == "identifier" then
			local hi = bounds[e.name]
			if hi ~= nil then return 0, hi end
			return nil
		end
		if e.type == "binary" and (e.op == "+" or e.op == "*") then
			local llo, lhi = range(e.left, bounds)
			if llo == nil or llo < 0 then return nil end
			local rlo, rhi = range(e.right, bounds)
			if rlo == nil or rlo < 0 then return nil end
			if e.op == "+" then return llo + rlo, lhi + rhi end
			return llo * rlo, lhi * rhi
		end
		return nil
	end

	-- index expression provably inside [0, size)?
	local function bounded(e, size, bounds)
		local lo, hi = range(e, bounds)
		return lo ~= nil and lo >= 0 and hi < size
	end

	-- walk the body carrying the enclosing bounded-counter environment;
	-- disqualify candidates on the first unproven use
	local walk
	local function walk_index(node, bounds)
		local a = node.array
		if a.type == "identifier" then
			local sz = cand[a.name]
			if sz and not bounded(node.index, sz, bounds) then
				cand[a.name] = nil
			end
		else
			walk(a, bounds)
		end
		walk(node.index, bounds)
	end
	function walk(node, bounds)
		if type(node) ~= "table" or not next(cand) then return end
		local t = node.type
		if t == "identifier" then
			cand[node.name] = nil -- bare reference = escape
			return
		elseif t == "index" then
			walk_index(node, bounds)
			return
		elseif
			t == "binary"
			and node.op == "="
			and node.left.type == "index"
		then
			local tgt = node.left
			local a = tgt.array
			if a.type == "identifier" then
				local sz = cand[a.name]
				if
					sz
					and not (
						bounded(tgt.index, sz, bounds)
						and numval(node.right)
					)
				then
					cand[a.name] = nil
				end
			else
				walk(a, bounds)
			end
			walk(tgt.index, bounds)
			walk(node.right, bounds)
			return
		elseif t == "for" then
			local var, hi = lite_counter(node)
			if var and (declc[var] or 0) <= 1 then
				local nb = setmetatable(
					{ [var] = hi },
					{ __index = bounds }
				)
				walk(node.init, bounds)
				walk(node.cond, nb)
				walk(node.update, nb)
				walk(node.body, nb)
				return
			end
		end
		for _, v in pairs(node) do
			walk(v, bounds)
		end
	end
	walk(body, {})
	return cand
end

-- Prefill analysis, for the table emission only (the ffi form is already
-- zero-filled by its constructor). An unwritten cell reads 0 through the
-- __ZERO metamethod, which on PUC Lua is a Lua call per miss: the sparse
-- bench writes 100 of 1000 cells and reads all 1000, so 900 misses a rep
-- cost it 2.2x hand-written Lua. Materialising [0,N) at construction turns
-- those misses into ordinary array-part hits.
--
-- Worth it only when the reads really do cover the range. Prefilling an
-- array that is barely touched buys N stores for nothing, and the bill grows
-- with N (a declared 65536 with three live cells measured ~2000x the lazy
-- form), so a candidate has to prove coverage before opting in: some read
-- must index it with the counter of an enclosing loop running exactly
-- [0, N-1]. Stores do not count, since a store already materialises the cell
-- it touches.
--
-- The prefill is invisible to Nova code either way (a cell reads 0 with or
-- without it), but the table's length and key set are not the same, so an
-- array reaching a host module could tell. Escaping candidates drop out for
-- the same reason the ffi analysis drops them.
local function scan_dense_arrays(cx, params, body)
	if not cx.opts.prefill then return {} end
	local cand, declc = {}, {}
	local function collect(node)
		if type(node) ~= "table" then return end
		if node.type == "decl" then
			declc[node.name] = (declc[node.name] or 0) + 1
			local vt = node.varType
			if
				vt
				and vt.type == "arraytype"
				and type(vt.size) == "number"
				and vt.size > 0
				and not is_str_type(cx, vt.base)
			then
				cand[node.name] = vt.size
			end
		end
		for _, v in pairs(node) do
			collect(v)
		end
	end
	collect(body)
	for name in pairs(cand) do
		if declc[name] > 1 then cand[name] = nil end -- shadowed: ambiguous
	end
	for _, p in ipairs(params) do
		cand[p.name] = nil -- a param may hold an array; don't reason about it
	end
	if not next(cand) then return {} end

	-- dense: some read covers [0,N). filled: some store already does,
	-- making a prefill pure duplicate work (arraywork writes every cell
	-- before summing it, and prefilling there cost 1.34x native)
	local dense, filled, walk = {}, {}, nil
	-- does `idx` step over the whole of [0,sz) under `bounds`?
	local function covers(idx, sz, bounds)
		return idx.type == "identifier" and bounds[idx.name] == sz - 1
	end
	local function walk_index(node, bounds)
		local a = node.array
		if a.type == "identifier" then
			local sz = cand[a.name]
			-- read at [0,N-1] via a counter: full coverage
			if sz and covers(node.index, sz, bounds) then
				dense[a.name] = true
			end
		else
			walk(a, bounds)
		end
		walk(node.index, bounds)
	end
	function walk(node, bounds)
		if type(node) ~= "table" then return end
		local t = node.type
		if t == "identifier" then
			cand[node.name] = nil -- bare reference = escape
			return
		elseif t == "index" then
			walk_index(node, bounds)
			return
		elseif
			t == "binary"
			and node.op == "="
			and node.left.type == "index"
		then
			-- store: the cell materialises itself, so this is not
			-- evidence for prefilling. A store over the whole range
			-- is evidence AGAINST it. Still walked for escapes.
			local tgt = node.left
			if tgt.array.type == "identifier" then
				local sz = cand[tgt.array.name]
				if sz and covers(tgt.index, sz, bounds) then
					filled[tgt.array.name] = true
				end
			else
				walk(tgt.array, bounds)
			end
			walk(tgt.index, bounds)
			walk(node.right, bounds)
			return
		elseif t == "for" then
			local var, hi = lite_counter(node)
			local init = node.init[1]
			local lo = init and init.value
			if
				var
				and (declc[var] or 0) <= 1
				and lo
				and lo.value == 0
			then
				local mt = { __index = bounds }
				local nb = setmetatable({ [var] = hi }, mt)
				walk(node.init, bounds)
				walk(node.cond, nb)
				walk(node.update, nb)
				walk(node.body, nb)
				return
			end
		end
		for _, v in pairs(node) do
			walk(v, bounds)
		end
	end
	walk(body, {})

	local out = {}
	for name in pairs(dense) do
		if cand[name] and not filled[name] then
			out[name] = cand[name]
		end
	end
	return out
end

-- every base name an expression subtree references: identifier nodes plus
-- named-call heads; a dotted name rides on its leading segment
local function collect_refs(node, out)
	if type(node) ~= "table" then return out end
	if node.type == "identifier" then
		out[node.name:match("^[^.]+")] = true
	end
	if node.type == "call" and node.name then
		out[node.name:match("^[^.]+")] = true
	end
	for _, v in pairs(node) do
		collect_refs(v, out)
	end
	return out
end

-- direct rebinding (`name = ...`; ++/+= desugar to `=`) of a name in `names`
local function assigns_direct(node, names)
	if type(node) ~= "table" then return false end
	if
		node.type == "binary"
		and node.op == "="
		and node.left.type == "identifier"
		and names[node.left.name]
	then
		return true
	end
	for _, v in pairs(node) do
		if type(v) == "table" and assigns_direct(v, names) then
			return true
		end
	end
	return false
end

-- decl multiplicity per name (catch vars count), for shadow detection
local function count_decls(node, out)
	if type(node) ~= "table" then return out end
	if node.type == "decl" then
		out[node.name] = (out[node.name] or 0) + 1
	end
	if node.type == "try" and node.catchVar then
		out[node.catchVar] = (out[node.catchVar] or 0) + 1
	end
	for _, v in pairs(node) do
		count_decls(v, out)
	end
	return out
end

-- Can this try body compile as a chunk-level function instead of a fresh
-- closure per entry? Closure creation (FNEW) is NYI in LuaJIT, so a try
-- inside a hot loop aborts the whole trace back to the interpreter; a
-- chunk-level function is created once at load and pcall of it stays on
-- trace. Free function-locals pass as arguments (sorted, stable output);
-- file vars and user functions are chunk locals either way, so the body
-- still reads AND writes those as upvalues. Returns the argument list, or
-- nil to fall back to the inline closure when the body rebinds a free
-- local (the argument copy would go stale) or shadows a name also bound
-- outside the body (a read before the inner decl would resolve differently
-- at chunk level).
local function try_hoist_params(cx, node)
	local refs = collect_refs(node.body, {})
	local inner, bodyc = {}, count_decls(node.body, {})
	collect_bound(node.body, inner)
	local free, fset = {}, {}
	for name in pairs(refs) do
		if cx.fnbound[name] and not inner[name] then
			free[#free + 1] = name
			fset[name] = true
		end
	end
	for name in pairs(inner) do
		if (bodyc[name] or 0) < (cx.fndecls[name] or 0) then
			return nil
		end
	end
	if assigns_direct(node.body, fset) then return nil end
	table.sort(free)
	return free
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
	if c.type ~= "binary" or (c.op ~= "<" and c.op ~= "<=") then
		return nil
	end
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
-- A '('-led statement glues onto the previous line as a call: `x = lo` then
-- `(f())[i] = v` parses as `lo(f())`. Wrapping the statement in `do ... end`
-- puts a keyword in front of the paren, which splits them on every target --
-- a leading ';' does the same only from 5.2 on, where the empty statement
-- exists, and LuaJIT would reject it.
local function unglue(stmt)
	if stmt:sub(1, 1) ~= "(" then return stmt end
	return "do " .. stmt .. " end"
end

-- a declared `int` narrows on every store, not only at its declaration:
-- otherwise `int x = 0; x = host.call()` leaves a boolean in an int-tagged
-- slot, and every is_int decision downstream (truncating division, the
-- ternary fast path) is then reasoning from a tag the value does not honour
function emit_assign(cx, node)
	local tgt = node.left
	if tgt.type ~= "index" then
		local tag = cx.typeenv[tgt.name]
		local rhs = E_tagged(cx, tag, node.right)
		push(cx, tgt.name .. " = " .. rhs)
		return
	end
	local lhs = E(cx, tgt.array) .. "[" .. E(cx, tgt.index) .. "]"
	-- an int array's cells are int slots too
	local atag = tgt.array.type == "identifier"
		and cx.typeenv[tgt.array.name]
	local etag = atag == "arr:int" and "int" or nil
	push(cx, unglue(lhs .. " = " .. E_tagged(cx, etag, node.right)))
end

-- `return`, with the declared return types narrowing each value.
--
-- Lua expands only the LAST expression of a list, so when the declared arity
-- leaves slots after it, a trailing call fills them. E parenthesizes a call to
-- clamp it to its primary value, which is right in expression position and
-- wrong here: `fn int, int fwd() { return two() }` would return 3, nil.
--
-- A Nova callee forwards directly, since it already narrowed its own returns
-- on the way out and the tail call is worth keeping. A host callee has not
-- been through anything, so its values are captured first and narrowed one
-- slot at a time -- the same contract a single-value return gets.
local function emit_return(cx, node)
	local vals = node.values or {}
	local n, retc = #vals, cx.fnretc or 0
	local rts = cx.fnrettypes
	if n == 0 then
		push(cx, "return 0")
		return
	end
	local vs = {}
	for i = 1, n - 1 do
		vs[i] = E_typed(cx, rts and rts[i], vals[i])
	end
	local last = vals[n]
	if last.type ~= "call" or retc <= n then
		vs[n] = E_typed(cx, rts and rts[n], last)
		push(cx, "return " .. table.concat(vs, ", "))
		return
	end
	if last.name and cx.funcs[last.name] then
		vs[n] = raw_call(cx, last)
		push(cx, "return " .. table.concat(vs, ", "))
		return
	end
	local tmps = {}
	for _ = n, retc do
		tmps[#tmps + 1] = newtmp(cx)
	end
	push(
		cx,
		"local "
			.. table.concat(tmps, ", ")
			.. " = "
			.. raw_call(cx, last)
	)
	for i, name in ipairs(tmps) do
		local tn = rts and rts[n + i - 1]
		if tn and is_int_type(cx, tn) then
			cx.used.__toint = true
			vs[n + i - 1] = "__toint(" .. name .. ")"
		else
			vs[n + i - 1] = name
		end
	end
	push(cx, "return " .. table.concat(vs, ", "))
end

function emit_stmt(cx, node, cl)
	-- keep cx.srcline on this statement's source line while it emits;
	-- position-less statements (bare break/return 0) inherit the last one
	if cx.src then
		local p = first_pos(node)
		if p then cx.srcline = src_line(cx, p) end
	end
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
		-- same '('-glue hazard as emit_assign for a callee expression
		push(cx, unglue(raw_call(cx, node)))
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
		emit_return(cx, node)
	elseif t == "throw" then
		push(
			cx,
			"error({nova=true, value="
				.. E(cx, node.value)
				.. "}, 0)"
		)
	elseif t == "try" then
		emit_try(cx, node, cl)
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

function emit_for(cx, node, cl)
	local var, start, limit, op = counting_loop(cx, node)
	if var then
		-- numeric for: faster FORLOOP opcode. `<` is exclusive but Lua's for is
		-- inclusive, so cap at limit-1 (safe: int counter, +1 step).
		local hi = E(cx, limit)
		if op == "<" then hi = "(" .. hi .. ") - 1" end
		cx.typeenv[var] = "int" -- counter type, for is_int in the body
		push(
			cx,
			"for "
				.. var
				.. " = "
				.. E(cx, start)
				.. ", "
				.. hi
				.. " do"
		)
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

-- pcall the body. A `return` inside the body returns from the pcalled
-- function; we capture those values and re-return them from the real
-- function, so try bodies can return. __NORET marks "fell through" (no
-- return). The `do ... end` lets a body return be the last statement and
-- still allow the trailing `return __NORET` fallthrough.
--
-- pcall results capture into plain locals, as many as the ENCLOSING
-- function's declared return arity (return types are required, so the most
-- a body `return` can yield is known statically): no table.pack round-trip,
-- so a try on the hot path allocates nothing. Where the body also proves
-- hoistable (try_hoist_params), the pcalled function is chunk-level too,
-- and the whole try compiles allocation-free.
function emit_try(cx, node, cl)
	cx.tryc = cx.tryc + 1
	cx.used.__NORET = true
	local n = cx.tryc
	local ok = "__ok" .. n
	local vs = {}
	for i = 1, math.max(1, cx.fnretc or 1) do
		vs[i] = "__tv" .. n .. "_" .. i
	end
	local rets = table.concat(vs, ", ")
	local free = cx.opts.tryhoist and try_hoist_params(cx, node) or nil
	if free then
		cx.tbc = cx.tbc + 1
		local fn = "__tb" .. cx.tbc
		local ps = table.concat(free, ", ")
		-- render the body function into cx.trybuf (spliced at chunk level
		-- by compile); a nested hoisted try appends its own def first, so
		-- inner defs always precede the outer def that calls them
		local sbuf, smap, sind = cx.buf, cx.map, cx.ind
		cx.buf, cx.map, cx.ind = {}, {}, 0
		push(cx, "local function " .. fn .. "(" .. ps .. ")")
		cx.ind = 1
		push(cx, "do")
		cx.ind = 2
		block(cx, node.body, nil)
		cx.ind = 1
		push(cx, "end")
		push(cx, "return __NORET")
		cx.ind = 0
		push(cx, "end")
		local def, defmap = cx.buf, cx.map
		cx.buf, cx.map, cx.ind = sbuf, smap, sind
		local base = #cx.trybuf
		for i, line in ipairs(def) do
			cx.trybuf[base + i] = line
			cx.trymap[base + i] = defmap[i]
		end
		push(
			cx,
			"local "
				.. ok
				.. ", "
				.. rets
				.. " = pcall("
				.. fn
				.. (#free > 0 and ", " .. ps or "")
				.. ")"
		)
	else
		push(
			cx,
			"local " .. ok .. ", " .. rets .. " = pcall(function()"
		)
		cx.ind = cx.ind + 1
		push(cx, "do")
		cx.ind = cx.ind + 1
		block(cx, node.body, nil)
		cx.ind = cx.ind - 1
		push(cx, "end")
		push(cx, "return __NORET")
		cx.ind = cx.ind - 1
		push(cx, "end)")
	end
	push(cx, "if " .. ok .. " then")
	cx.ind = cx.ind + 1
	push(cx, "if " .. vs[1] .. " ~= __NORET then return " .. rets .. " end")
	cx.ind = cx.ind - 1
	push(cx, "else")
	cx.ind = cx.ind + 1
	-- a Nova throw unwraps to its payload; a host/Lua error carries this
	-- chunk's "name:line:" prefix in GENERATED coordinates -- __SRC rewrites
	-- it to the Nova source line (needs opts.src for the line map)
	local raw = vs[1]
	if cx.src then
		cx.used.__SRC = true
		raw = "__SRC(" .. vs[1] .. ")"
	end
	push(
		cx,
		"local "
			.. node.catchVar
			.. " = ((type("
			.. vs[1]
			.. ") == 'table' and "
			.. vs[1]
			.. ".nova) and "
			.. vs[1]
			.. ".value or "
			.. raw
			.. ")"
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
local function emit_function(cx, n, min_args, fwd)
	-- fresh scalar-type scope; param types seed is_int (param.type is a bare
	-- type-name string in the parser). File-scope vars seed both scopes:
	-- visible everywhere, params/locals shadow them
	cx.typeenv = {}
	cx.srcline = nil -- scaffolding lines before the first statement: unmapped
	cx.bound = {} -- fresh bound-name scope for the unbound-name check
	for k, v in pairs(cx.filevars) do
		cx.typeenv[k] = v
		cx.bound[k] = true
	end
	-- fnbound/fndecls: names bound by THIS function only (no file vars),
	-- for the try-hoist free-local computation and its shadow check
	cx.fnbound, cx.fndecls = {}, {}
	local ps = {}
	for i, p in ipairs(n.params) do
		ps[i] = p.name
		cx.typeenv[p.name] = scalar_tag(cx, p.type)
		cx.bound[p.name] = true
		cx.fnbound[p.name] = true
		cx.fndecls[p.name] = (cx.fndecls[p.name] or 0) + 1
	end
	collect_bound(n.body, cx.bound)
	collect_bound(n.body, cx.fnbound)
	count_decls(n.body, cx.fndecls)
	cx.ffiarr = scan_ffi_arrays(cx, n.params, n.body)
	cx.densearr = scan_dense_arrays(cx, n.params, n.body)
	-- declared return arity: how many pcall results a try must capture.
	-- the types themselves drive the int coercion on the way out
	cx.fnretc = n.returnTypes and #n.returnTypes or 0
	cx.fnrettypes = n.returnTypes
	-- fwd-declared names assign into their chunk local; the rest are
	-- `local function` (immutable self-upvalue: direct recursive dispatch)
	local head = fwd and "function " or "local function "
	push(cx, head .. n.name .. "(" .. table.concat(ps, ", ") .. ")")
	cx.ind = cx.ind + 1
	-- default a missing arg to 0 (the VM zero-filled unbound params), but only
	-- for params some call under-supplies: saturated params skip it. `or 0`
	-- only rewrites nil; numbers (incl. 0), strings, arrays pass thru.
	local ma = min_args[n.name]
	for idx, p in ipairs(ps) do
		if ma ~= nil and ma < idx then
			push(cx, p .. " = " .. p .. " or 0")
		end
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

-- emit the prelude: semantic shims, as upvalues (not globals). Rendered AFTER
-- the body (then spliced in front of it), so only shims the emitters actually
-- referenced (cx.used) exist in the chunk -- an unused shim is dead weight in
-- every module's bytecode and heap.
local function emit_prelude(cx)
	local u = cx.used
	if u.bit then push(cx, "local bit = require('bit')") end
	-- one ffi constructor per distinct declared array size (sorted: stable)
	if next(cx.arrsizes) then
		push(cx, "local ffi = require('ffi')")
		local sizes = {}
		for n in pairs(cx.arrsizes) do
			sizes[#sizes + 1] = n
		end
		table.sort(sizes)
		for _, n in ipairs(sizes) do
			push(
				cx,
				"local __arr"
					.. n
					.. " = ffi.typeof('double["
					.. n
					.. "]')"
			)
		end
	end
	if u.__idiv or u.__imod or u.__toint then
		u.__floor, u.__ceil = true, true
	end
	local ns, vs = {}, {}
	for _, m in ipairs({ "floor", "ceil", "fmod" }) do
		if u["__" .. m] then
			ns[#ns + 1] = "__" .. m
			vs[#vs + 1] = "math." .. m
		end
	end
	if #ns > 0 then
		push(
			cx,
			"local "
				.. table.concat(ns, ", ")
				.. " = "
				.. table.concat(vs, ", ")
		)
	end
	-- round toward zero, inlined into both helpers: a separate __trunc would add
	-- a Lua call to every int / and % (3-deep chain vs 2), and on the
	-- interpreted PUC Lua path that is ~a third of the calls on div/mod-heavy
	-- code. q >= 0 picks floor, else ceil -- truncation toward zero, the C `/`.
	if u.__idiv then
		push(cx, "local function __idiv(a, b)")
		push(cx, "  local q = a / b")
		push(
			cx,
			"  if q >= 0 then return __floor(q) else return __ceil(q) end"
		)
		push(cx, "end")
	end
	if u.__imod then
		push(cx, "local function __imod(a, b)")
		push(cx, "  local q = a / b")
		push(cx, "  local t = q >= 0 and __floor(q) or __ceil(q)")
		push(cx, "  return a - t * b")
		push(cx, "end")
	end
	-- coerce a value of unknown provenance into an int slot. Only reachable
	-- where the static type is NOT already int, which in practice means a
	-- host call, a host field, or a float source -- pure Nova expressions
	-- prove int-ness at compile time and pay nothing here.
	--
	-- Numbers truncate toward zero (C's rule, matching __idiv/__imod) and a
	-- boolean folds to 1/0 (Nova's own truth representation), so a host
	-- predicate cannot leak a Lua boolean past an `int` signature. Anything
	-- else passes through untouched: `int` doubles as this language's
	-- catch-all declared type, and arrays are returned from `fn int`
	-- signatures on purpose (see the store.nova example in README), so
	-- narrowing tables or strings here would break working programs.
	if u.__toint then
		push(cx, "local function __toint(v)")
		push(cx, "  local t = type(v)")
		push(cx, "  if t == 'number' then")
		push(
			cx,
			"    if v >= 0 then return __floor(v) else return __ceil(v) end"
		)
		push(cx, "  elseif t == 'boolean' then return v and 1 or 0")
		push(cx, "  elseif v == nil then return 0 end")
		push(cx, "  return v")
		push(cx, "end")
	end
	-- table.pack/unpack are 5.2+; LuaJIT (5.1) needs the fallbacks
	if u.__pack then
		push(
			cx,
			"local __pack = table.pack or "
				.. "function(...) return {n = select('#', ...), ...} end"
		)
	end
	if u.__unpack then
		push(cx, "local __unpack = table.unpack or unpack")
	end
	if u.__ZERO then
		push(cx, "local __ZERO = {__index = function() return 0 end}")
	end
	-- sentinel: a try body that returned no value
	if u.__NORET then push(cx, "local __NORET = {}") end
	-- runtime error translation: rewrite this chunk's own "name:line:"
	-- prefix (generated coordinates) to the Nova source line via __MAP,
	-- which compile fills in at the chunk bottom (known only post-assembly)
	if u.__SRC then
		push(cx, "local __MAP = {}")
		push(cx, "local function __SRC(m)")
		push(cx, "  if type(m) ~= 'string' then return m end")
		push(
			cx,
			'  local ln, rest = m:match("^'
				.. cx.chunkname
				.. ':(%d+): (.*)")'
		)
		push(cx, "  ln = ln and __MAP[tonumber(ln)]")
		push(cx, "  if ln then return ln .. ': ' .. rest end")
		push(cx, "  return m")
		push(cx, "end")
	end
end

function Avon.compile(body, env, opts)
	opts = opts or {}
	local cx = {
		buf = {},
		ind = 0,
		consts = {}, -- enum variant -> integer value
		typedefs = {}, -- typedef alias -> base type name
		ret_int = {}, -- user function name -> first return type is int?
		ret_str = {}, -- user function name -> first return type is str?
		typeenv = {}, -- per-function scalar types, reset before each function
		funcs = {}, -- every user function name (for the unbound-name check)
		rettypes = {}, -- user function name -> declared return type names
		paramtypes = {}, -- user function name -> declared params
		bound = {}, -- names bound in the current function, reset per function
		env = env, -- host environment (chains to _G); nil = skip name checks
		used = {}, -- shims the emitters referenced; prelude emits only these
		opts = { -- emission choices, overridable for A/B benching
			ffi = opts.ffi == nil and FFI_OK or opts.ffi,
			tryhoist = opts.tryhoist ~= false,
			prefill = opts.prefill ~= false,
		},
		src = opts.src, -- Nova source text: line:col in compile errors
		chunkname = opts.src and chunk_id(opts.src) or "nova",
		map = {}, -- generated line -> source line, parallel to buf
		trymap = {}, -- ditto for trybuf
		linecache = {}, -- byte offset -> source line memo
		arrsizes = {}, -- ffi array sizes referenced; prelude emits ctors
		trybuf = {}, -- hoisted try-body functions, spliced at chunk level
		labelc = 0,
		prefillc = 0,
		tmpc = 0,
		subjc = 0,
		tryc = 0,
		tbc = 0,
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
			cx.rettypes[n.name] = n.returnTypes
			cx.paramtypes[n.name] = n.params
		end
	end

	-- Which functions are referenced before their definition point in the
	-- emitted chunk: an earlier function's body (call-before-def, mutual
	-- recursion), or any try body (hoisted try functions splice ahead of
	-- every definition, so be conservative about anything a try touches)?
	-- Those keep the forward-decl + assignment form. Everything else emits
	-- as `local function`, whose self-reference upvalue is immutable --
	-- LuaJIT then treats the recursive call target as a constant (direct
	-- dispatch), worth ~20% on call-heavy recursion.
	local needs_fwd = {}
	do
		local seen = {}
		local function mark_refs(node)
			for name in pairs(collect_refs(node, {})) do
				if cx.funcs[name] and not seen[name] then
					needs_fwd[name] = true
				end
			end
		end
		-- try bodies may hoist to chunk level AHEAD of every definition,
		-- so any function they reference needs the fwd form no matter
		-- where it is defined -- the `seen` order filter does not apply
		local function scan_trys(node)
			if type(node) ~= "table" then return end
			if node.type == "try" then
				for name in pairs(collect_refs(node.body, {})) do
					if cx.funcs[name] then
						needs_fwd[name] = true
					end
				end
			end
			for _, v in pairs(node) do
				scan_trys(v)
			end
		end
		for _, n in ipairs(body) do
			if n.type == "function" then
				seen[n.name] = true -- self-calls don't force the fwd form
				mark_refs(n.body)
				scan_trys(n.body)
			end
		end
	end

	-- forward-declare the functions that need it, so call order / mutual
	-- recursion work; file-scope var names always join them so function
	-- bodies capture them as upvalues (a top-level decl list is a body
	-- entry with no .type)
	local names, fwd = {}, {}
	for _, n in ipairs(body) do
		if n.type == "function" then
			names[#names + 1] = n.name
			if needs_fwd[n.name] then fwd[#fwd + 1] = n.name end
		elseif not n.type then
			for _, d in ipairs(n) do
				fwd[#fwd + 1] = d.name
			end
		end
	end
	-- rendered at assembly time: the forward decls must precede the hoisted
	-- try-body functions (which reference user functions and file vars)
	local fwd_line = #fwd > 0 and ("local " .. table.concat(fwd, ", "))
		or nil

	-- file-scope decls render into a side buffer FIRST (fills typeenv/bound
	-- so function bodies type them), but splice into the chunk AFTER the
	-- function definitions, so an initializer may call user functions
	for _, n in ipairs(body) do
		if not n.type then collect_bound(n, cx.bound) end
	end
	local chunk, chunk_map = cx.buf, cx.map
	cx.buf, cx.map = {}, {}
	cx.filedecl = true
	for _, n in ipairs(body) do
		if not n.type then emit_decl_list(cx, n) end
	end
	cx.filedecl = nil
	local decl_lines, decl_map = cx.buf, cx.map
	cx.buf, cx.map = chunk, chunk_map
	cx.filevars = cx.typeenv

	local min_args = scan_min_args(body)
	for _, n in ipairs(body) do
		if n.type == "function" then
			emit_function(cx, n, min_args, needs_fwd[n.name])
		end
	end
	append_buf(cx, decl_lines, decl_map)

	-- prelude renders last (cx.used is complete by now) but lands first;
	-- then forward decls, hoisted try bodies, functions, file-var inits
	local body_lines, body_map = cx.buf, cx.map
	cx.buf, cx.map, cx.srcline = {}, {}, nil
	emit_prelude(cx)
	if fwd_line then push(cx, fwd_line) end
	append_buf(cx, cx.trybuf, cx.trymap)
	append_buf(cx, body_lines, body_map)

	-- final line numbers are now fixed: fill the runtime error map (read by
	-- the __SRC shim), then close with the export table
	if cx.used.__SRC then
		local gls = {}
		for gl in pairs(cx.map) do
			gls[#gls + 1] = gl
		end
		table.sort(gls)
		local kvs = {}
		for i, gl in ipairs(gls) do
			kvs[i] = "[" .. gl .. "]=" .. cx.map[gl]
		end
		push(cx, "__MAP = {" .. table.concat(kvs, ",") .. "}")
	end
	local kv = {}
	for _, nm in ipairs(names) do
		kv[#kv + 1] = nm .. " = " .. nm
	end
	push(cx, "return {" .. table.concat(kv, ", ") .. "}")

	-- hand back the chunk name and final generated-line -> source-line map
	-- alongside the source: Avon.load turns them into a translator that maps
	-- an uncaught runtime error's position back to Nova coordinates (the same
	-- mapping the in-chunk __SRC shim does for try-caught errors)
	return table.concat(cx.buf, "\n"), cx.chunkname, cx.map
end

-- Build a translator for a chunk's uncaught runtime errors: rewrite a Lua
-- error whose prefix is this chunk's own "<chunkname>:<generated line>:" to the
-- Nova source line via the compile-time line map. Mirrors the in-chunk __SRC
-- shim (which handles try-caught errors), but runs host-side for errors that
-- propagate all the way out. Returns nil when the prefix is not this chunk's,
-- so a caller can try each module's translator until one claims the error.
local function make_translator(chunkname, map)
	-- chunk_id yields only pattern-safe chars (letters, digits, '#', '_'),
	-- so the name splices into a Lua pattern without escaping -- same as __SRC
	local prefix = "^" .. chunkname .. ":(%d+): (.*)"
	return function(msg)
		if type(msg) ~= "string" then return nil end
		local ln, rest = msg:match(prefix)
		local srcline = ln and map[tonumber(ln)]
		if srcline then return srcline .. ": " .. rest end
		return nil
	end
end

-- Compile Nova `body` and load it. `env` supplies builtins/imports (and falls
-- back to globals); returns a table mapping function name -> Lua function, the
-- generated Lua source, and (when opts.src is set) a runtime-error translator.
-- `opts` (optional) selects emission choices, see Avon.compile.
function Avon.load(body, env, opts)
	env = setmetatable(env or {}, { __index = _G })
	local src, chunkname, map = Avon.compile(body, env, opts)
	-- the chunkname must match what the emitted __SRC shim expects (same
	-- chunk_id derivation), or runtime error prefixes would not translate
	local name = "=" .. (opts and opts.src and chunk_id(opts.src) or "nova")
	local chunk, err
	if setfenv then -- Lua 5.1 / LuaJIT: no env arg on load, set it explicitly
		chunk, err = load(src, name)
		if chunk then setfenv(chunk, env) end
	else -- Lua 5.2+: pass the environment to load
		chunk, err = load(src, name, "t", env)
	end
	if not chunk then error("transpile load failed: " .. tostring(err)) end
	-- only wire a translator when a source is available: without opts.src the
	-- chunkname is the generic "nova" and the map has no source lines to hit
	local translate = (opts and opts.src)
			and make_translator(chunkname, map)
		or nil
	return chunk(), src, translate
end

return Avon
