-- Durable persistence for the identity record (anonymous ID + consent state).
-- This is the only SDK module allowed to call Defold sys persistence. Every
-- call is pcall-guarded so plain Lua hosts without the Defold `sys` API
-- degrade gracefully to in-memory state for the process lifetime.
--
-- Records are namespaced per configured app identity
-- (`shardpilot.<workspace_id>.<app_id>`, segments sanitized) so two games on
-- the same device never share an anonymous ID or consent decision. The bare
-- `shardpilot` namespace is only used when no scope is configured.

local M = {}

local memory_records = {}

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

local function sanitize(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return (value:gsub("[^%w%-_]", "_"))
end

local function namespace(scope)
	local workspace = sanitize(type(scope) == "table" and scope.workspace_id or nil)
	local app = sanitize(type(scope) == "table" and scope.app_id or nil)
	if workspace and app then
		return "shardpilot." .. workspace .. "." .. app
	end
	return "shardpilot"
end

local function save_path(ns)
	if type(sys) ~= "table" then
		return nil
	end
	if type(sys.get_save_file) ~= "function" or type(sys.save) ~= "function" or type(sys.load) ~= "function" then
		return nil
	end
	local ok, path = pcall(sys.get_save_file, ns, "identity")
	if not ok or type(path) ~= "string" or path == "" then
		return nil
	end
	return path
end

function M.load(scope)
	local ns = namespace(scope)
	local path = save_path(ns)
	if not path then
		return clone(memory_records[ns])
	end
	local ok, record = pcall(sys.load, path)
	if not ok or type(record) ~= "table" then
		return clone(memory_records[ns])
	end
	return record
end

function M.save(scope, record)
	if type(record) ~= "table" then
		return false
	end
	local ns = namespace(scope)
	memory_records[ns] = clone(record)
	local path = save_path(ns)
	if not path then
		return true
	end
	local ok, saved = pcall(sys.save, path, record)
	return ok and saved == true
end

-- Clears the in-memory fallback records only; intended for tests.
function M.reset()
	memory_records = {}
end

return M
