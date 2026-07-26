-- Static checks for the toolchain's own Lua (not for generated output).
-- Run: luacheck . -- the .githooks/pre-commit hook runs it on every commit.
--
-- The default std is deliberately wide: this code runs under PUC Lua and
-- LuaJIT alike and feature-detects between them, so `setfenv` and `jit` are
-- legitimate reads on one interpreter and legitimately absent on the other.
-- Pinning a single std would turn that portability into a warning wall.
std = "max"

files["codegen/avon.lua"] = {
	-- the statement dispatch has a deliberately empty arm: typedef/enum/
	-- import/function are declaration-level and emit nothing in statement
	-- position, and saying so beats falling through to the unhandled error
	ignore = { "542" },
}

exclude_files = { "playground" }
