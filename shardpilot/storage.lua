-- Durable persistence for the identity record (anonymous ID + consent state).
-- This is the only SDK module allowed to call Defold sys persistence. Every
-- call is pcall-guarded so plain Lua hosts without the Defold `sys` API
-- degrade gracefully to in-memory state for the process lifetime.

local M = {}

local memory_record = nil

local function clone(record)
	if type(record) ~= "table" then
		return nil
	end
	local out = {}
	for key, value in pairs(record) do
		out[key] = value
	end
	return out
end

local function save_path()
	if type(sys) ~= "table" then
		return nil
	end
	if type(sys.get_save_file) ~= "function" or type(sys.save) ~= "function" or type(sys.load) ~= "function" then
		return nil
	end
	local ok, path = pcall(sys.get_save_file, "shardpilot", "identity")
	if not ok or type(path) ~= "string" or path == "" then
		return nil
	end
	return path
end

function M.load()
	local path = save_path()
	if not path then
		return clone(memory_record)
	end
	local ok, record = pcall(sys.load, path)
	if not ok or type(record) ~= "table" then
		return clone(memory_record)
	end
	return record
end

function M.save(record)
	if type(record) ~= "table" then
		return false
	end
	memory_record = clone(record)
	local path = save_path()
	if not path then
		return true
	end
	local ok, saved = pcall(sys.save, path, record)
	return ok and saved == true
end

-- Clears the in-memory fallback record only; intended for tests.
function M.reset()
	memory_record = nil
end

return M
