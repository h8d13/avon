-- Tokenizer lookahead cache: peek() scans each token once and next() serves
-- it from the cache. Guards the scan-per-token ratio (pre-cache it was ~2.9x:
-- the Pratt loop peeked twice and next() scanned a third time) and the error
-- line:col that must survive cache-served tokens.
local Parser = require("lang/parser")

local fh = assert(io.open("hello.nova", "r"))
local src = fh:read("*a")
fh:close()

-- token count: drain a raw tokenizer without the parser in the way
local n = 0
do
	local t = Parser:new(src).tokens
	while t:next().type ~= "eof" do
		n = n + 1
	end
end

-- scans during a real parse: wrap Tokenizer:next (reached via the instance
-- metatable) and count only calls that miss the `ahead` cache. The field name
-- is the mechanism under test; if a rewrite renames it, every call counts as
-- a scan and the bound below fails, flagging this test for update.
local p = Parser:new(src)
local Tok = getmetatable(p.tokens)
local orig_next = Tok.next
local scans = 0
Tok.next = function(s)
	if not s.ahead then scans = scans + 1 end
	return orig_next(s)
end
local ok, err = pcall(function() return p:parse() end)
Tok.next = orig_next
if not ok then error(err, 0) end

-- floor is n+1 (every token + EOF); looks_like_decl backtracking legitimately
-- rescans a few, so allow headroom up to 1.5x before calling it a regression
local ratio = scans / n
if ratio > 1.5 then
	error(
		string.format(
			"lookahead cache regressed: %d scans for %d tokens (%.2fx > 1.5x)",
			scans,
			n,
			ratio
		)
	)
end
if scans < n + 1 then
	error(string.format("impossible: %d scans for %d tokens", scans, n))
end

-- parse errors must keep pointing at the offending token when it was served
-- from the cache: the `}` after the dangling `+` sits at line 3, col 1
local bad = "fn int main() {\n\treturn 1 +\n}"
local ok2, err2 = pcall(function() return Parser:new(bad):parse() end)
if ok2 then error("dangling operator: expected a parse error, but it parsed") end
if not tostring(err2):find("^3:1: ") then
	error("expected error tagged 3:1, got " .. tostring(err2))
end

print("ok")
