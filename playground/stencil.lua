-- Pour a Nova program into an art stencil, keeping the art's glyphs and
-- SPREADING the code through the whole picture (not clustered at the top).
-- Each contiguous run of ink becomes either:
--   * a CODE run: whole tokens (blank-separated so words can't merge), leftover
--     cells wrapped as /* <original glyphs> */ so they stay drawn; or
--   * an ART run: the original glyphs wrapped in /* ... */ (inert, visible).
-- Tokens are placed on a pace (placed ~= T * run/total) so they scatter top to
-- bottom while staying in reading (= program) order. A token never straddles a
-- gap, and block glyphs only ever live inside comments, so the picture survives
-- and the source parses (Nova ignores whitespace except word<->word).
--   lua5.4 stencil.lua <art> <code.nova>  > shaped.nova
local function slurp(p)
	local f = assert(io.open(p, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

local function tokenize(s)
	local two = {}
	for op in ("<= >= == != && || << >> += -= *= /= %= ++"):gmatch("%S+") do
		two[op] = true
	end
	local t, i, n = {}, 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c:match("%s") then
			i = i + 1
		elseif c == '"' or c == "'" then -- string/char literal: one atomic token
			local j = i + 1
			while j <= n and s:sub(j, j) ~= c do
				j = j + 1
			end
			t[#t + 1] = s:sub(i, j) -- include the closing quote
			i = j + 1
		elseif c:match("[%w_]") then
			local j = i
			while j <= n and s:sub(j, j):match("[%w_]") do
				j = j + 1
			end
			-- keep a float literal whole: digits '.' digits is one token
			if
				c:match("%d")
				and s:sub(j, j) == "."
				and s:sub(j + 1, j + 1):match("%d")
			then
				j = j + 1
				while j <= n and s:sub(j, j):match("%d") do
					j = j + 1
				end
			end
			t[#t + 1] = s:sub(i, j - 1)
			i = j
		elseif two[s:sub(i, i + 1)] then
			t[#t + 1] = s:sub(i, i + 1)
			i = i + 2
		else
			t[#t + 1] = c
			i = i + 1
		end
	end
	return t
end

local art = slurp(arg[1])
local tokens = tokenize(slurp(arg[2]))

-- pass 1: split the art into lines of segments (space-runs and ink-runs),
-- collecting every ink run's glyphs so pass 2 can fill them in order.
local seg_lines, runs = {}, {}
for line in (art .. "\n"):gmatch("(.-)\n") do
	local segs, cur, sp = {}, nil, 0
	local function flush_sp()
		if sp > 0 then
			segs[#segs + 1] = { sp = sp }
			sp = 0
		end
	end
	local function flush_ink()
		if cur then
			runs[#runs + 1] = cur
			segs[#segs + 1] = { ink = #runs }
			cur = nil
		end
	end
	for _, cp in utf8.codes(line) do
		if cp == 32 then
			flush_ink()
			sp = sp + 1
		else
			flush_sp()
			cur = cur or {}
			cur[#cur + 1] = utf8.char(cp)
		end
	end
	flush_sp()
	flush_ink()
	seg_lines[#seg_lines + 1] = segs
end

-- pass 2: assign text to each run. Pace tokens across all runs so they spread.
local T, R = #tokens, #runs
local placed = 0
local function midwrap(g, a, b) -- "/*" + glyphs[a..b] + "*/"
	return "/*" .. (b >= a and table.concat(g, "", a, b) or "") .. "*/"
end
local run_text = {}
for idx = 1, R do
	local g, L = runs[idx], #runs[idx]
	-- pace placement so tokens scatter top-to-bottom (placed ~= T * run/total),
	-- staying in reading (= program) order
	local target = math.ceil(T * idx / R)
	local out = ""
	while placed < T and placed < target do
		local tok = tokens[placed + 1]
		local sep = (out == "") and 0 or 1
		if #out + sep + #tok > L then break end
		out = out .. (sep == 1 and " " or "") .. tok
		placed = placed + 1
	end
	-- fill leftover ink with a dot comment (no block glyphs): the eye stays
	-- solid -- code where tokens land, /*...*/ dots elsewhere.
	local rem = L - #out
	if out ~= "" then
		if rem >= 5 then
			out = out .. " /*" .. ("."):rep(rem - 5) .. "*/"
		else
			out = out .. (" "):rep(rem)
		end
		run_text[idx] = out
	elseif L >= 4 then
		run_text[idx] = "/*" .. ("."):rep(L - 4) .. "*/"
	else
		run_text[idx] = (" "):rep(L)
	end
end
assert(placed == T, "program did not fully fit (a token found no run wide enough)")

-- render
local lines = {}
for _, segs in ipairs(seg_lines) do
	local buf = {}
	for _, s in ipairs(segs) do
		buf[#buf + 1] = s.sp and (" "):rep(s.sp) or run_text[s.ink]
	end
	lines[#lines + 1] = table.concat(buf)
end
io.write(table.concat(lines, "\n"), "\n")
