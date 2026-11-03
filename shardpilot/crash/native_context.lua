-- Opt-in engine user fields; the host refreshes these before lifecycle changes.
local event = require "shardpilot.crash.event"
local sanitize = require "shardpilot.crash.sanitize"
local M = {}
local owner = setmetatable({}, { __mode = "v" })

function M.marker(app, scope)
	for _, value in ipairs({app or false, scope or false}) do
		if type(value) ~= "string" or #value == 0 or #value > 96
			or not value:match("^[A-Za-z0-9._:-]+$") then return nil end
	end
	return "spn1:" .. #app .. ":" .. app .. ":" .. scope
end

local function clear(engine)
	-- Invalidate first and commit last: a dump between writes has no snapshot.
	for index = 27, 31 do engine.set_user_field(index, "") end
end

local function bounded(value)
	return #value <= 255 and value or ""
end

function M.clear(client)
	if owner[1] ~= client then return true end
	local ok = pcall(clear, client.native_engine)
	return ok, not ok and "native_snapshot_write_failed" or nil
end

function M.write(client, context)
	if owner[1] ~= client then return false, "native_snapshot_unavailable" end
	local ok = pcall(function()
		local engine = client.native_engine
		clear(engine)
		if not client.enabled then return end
		local granted = type(context) == "table" and rawget(context, "consent") == "granted"
		engine.set_user_field(28, bounded(sanitize.sanitize_version(client.config.app_version)))
		engine.set_user_field(29, bounded(sanitize.sanitize_version(client.config.app_build)))
		if granted then
			engine.set_user_field(30, bounded(event.normalize_actor_identifier(rawget(context, "anonymous_id"))))
			engine.set_user_field(31, bounded(event.normalize_actor_identifier(rawget(context, "session_id"))))
		end
		engine.set_user_field(27, M.marker(client.config.app_id, client.config.native_snapshot_scope) .. (granted and ":g" or ":n"))
	end)
	return ok, not ok and "native_snapshot_write_failed" or nil
end

function M.bind(client)
	if owner[1] then return false, "native_snapshot_in_use" end
	local engine = _G.crash
	if type(engine) ~= "table" or type(engine.set_user_field) ~= "function"
		or type(engine.get_user_field) ~= "function" then return false, "native_snapshot_unavailable" end
	owner[1], client.native_engine = client, engine
	return M.write(client, nil)
end

function M.release(client)
	if owner[1] == client then owner[1] = nil end
end

function M.read(engine, handle, config)
	if not config or not config.native_snapshot_enabled then return nil end
	local ok, snapshot = pcall(function()
		local marker = M.marker(config.app_id, config.native_snapshot_scope)
		local stored = engine.get_user_field(handle, 27)
		if stored ~= marker .. ":g" and stored ~= marker .. ":n" then return nil end
		local values = {}
		for index = 28, 31 do
			local value = engine.get_user_field(handle, index)
			if type(value) ~= "string" or #value > 255 then return nil end
			values[index] = value
		end
		return { app_version=values[28], app_build=values[29],
			anonymous_id=stored == marker .. ":g" and values[30] or "",
			session_id=stored == marker .. ":g" and values[31] or "" }
	end)
	return ok and snapshot or nil
end

return M
