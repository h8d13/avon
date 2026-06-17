-- Shared filesystem probes for the loader and the check tool. POSIX trick:
-- opening "<path>/." succeeds only for a directory (a file gives ENOTDIR), so
-- file vs dir can be told apart without a stat call.
local fs = {}

function fs.exists(p)
	local f = io.open(p, "r")
	if f then
		f:close()
		return true
	end
	return false
end

function fs.is_dir(p)
	local f = io.open(p .. "/.")
	if f then
		f:close()
		return true
	end
	return false
end

return fs
