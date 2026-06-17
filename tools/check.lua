-- Nova syntax checker. Parses and transpiles each given .nova file and reports
-- errors as `file:line:col: message`. Exit status is non-zero if any file
-- failed, so it drops straight into pre-commit hooks and CI.
--   lua5.4 tools/check.lua FILE...   (or pass a dir to check *.nova under it)
package.path = "lang/?.lua;codegen/?.lua;" .. package.path
local Parser = require("parser")
local Avon = require("avon")

-- a Nova error is "L:C: msg" (parser) or a bare message (transpile); keep the
-- L:C if present and let the caller prepend the filename.
local function check_one(path)
  local fh, oerr = io.open(path, "r")
  if not fh then return false, "cannot open: " .. tostring(oerr) end
  local src = fh:read("*a"); fh:close()

  local ok, err = pcall(function()
    local ast = Parser:new(src):parse()
    Avon.compile(ast.body) -- also catches codegen-level rejections
  end)
  if ok then return true end
  return false, tostring(err)
end

-- POSIX trick: opening "<path>/." succeeds only for directories (a file
-- gives ENOTDIR), so we can tell dirs from files without a stat call.
local function is_dir(path)
  local f = io.open(path .. "/.")
  if f then f:close(); return true end
  return false
end

-- directory args expand to the .nova files under them; file args (any
-- extension) are checked directly.
local function gather(args)
  local files = {}
  for _, a in ipairs(args) do
    if is_dir(a) then
      local p = io.popen('find "' .. a .. '" -name "*.nova" 2>/dev/null')
      if p then
        for line in p:lines() do files[#files + 1] = line end
        p:close()
      end
    else
      files[#files + 1] = a
    end
  end
  return files
end

local files = gather(arg)
if #files == 0 then
  io.stderr:write("usage: check.lua <file.nova | dir>...\n")
  os.exit(2)
end

local failed = 0
for _, path in ipairs(files) do
  local ok, err = check_one(path)
  if ok then
    io.write("ok   " .. path .. "\n")
  else
    failed = failed + 1
    io.write(string.format("FAIL %s:%s\n", path, err))
  end
end

io.write(string.format("\n%d checked, %d failed\n", #files, failed))
os.exit(failed == 0 and 0 or 1)
