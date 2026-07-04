local client_mod = require "shardpilot.client"

local M = {}
local default_client = nil

function M.new(config)
	return client_mod.new(config)
end

function M.init(config)
	local client, err = client_mod.new(config)
	if not client then
		return false, err
	end
	default_client = client
	return true
end

local function default()
	return default_client
end

local function with_default(method, ...)
	local client = default()
	if not client then
		return false, "not_initialized"
	end
	return client[method](client, ...)
end

function M.identify(user_id)
	return with_default("identify", user_id)
end

function M.set_anonymous_id(anonymous_id)
	return with_default("set_anonymous_id", anonymous_id)
end

function M.get_anonymous_id()
	return with_default("get_anonymous_id")
end

function M.set_consent(analytics_granted)
	return with_default("set_consent", analytics_granted)
end

-- Remote config. `fetch_remote_config` reports "not_initialized" through the
-- result callback too, so a game that only reads the callback still learns
-- why nothing was fetched. The value getters deliberately do NOT use
-- with_default: they must return the caller's DEFAULT when the SDK is not
-- initialized — with_default's `false, "not_initialized"` would be
-- indistinguishable from a legitimate false flag value.
function M.fetch_remote_config(callback)
	local client = default()
	if not client then
		if type(callback) == "function" then
			pcall(callback, { ok = false, from_cache = false, error = "not_initialized" })
		end
		return false, "not_initialized"
	end
	return client:fetch_remote_config(callback)
end

function M.remote_config_value(key)
	local client = default()
	if not client then
		return nil
	end
	return client:remote_config_value(key)
end

function M.remote_config_string(key, default_value)
	local client = default()
	if not client then
		return default_value
	end
	return client:remote_config_string(key, default_value)
end

function M.remote_config_number(key, default_value)
	local client = default()
	if not client then
		return default_value
	end
	return client:remote_config_number(key, default_value)
end

function M.remote_config_boolean(key, default_value)
	local client = default()
	if not client then
		return default_value
	end
	return client:remote_config_boolean(key, default_value)
end

function M.remote_config_values()
	local client = default()
	if not client then
		return nil
	end
	return client:remote_config_values()
end

function M.remote_config_version()
	local client = default()
	if not client then
		return nil
	end
	return client:remote_config_version()
end

function M.session_start(props)
	return with_default("session_start", props)
end

function M.screen_view(screen_name, props)
	return with_default("screen_view", screen_name, props)
end

function M.track(event_name, props, context)
	return with_default("track", event_name, props, context)
end

function M.update(dt)
	return with_default("update", dt)
end

function M.observe_ping_ms(ms)
	return with_default("observe_ping_ms", ms)
end

function M.observe_disconnect(reason)
	return with_default("observe_disconnect", reason)
end

function M.flush()
	return with_default("flush")
end

-- Snapshot undelivered events into the durable offline spool without sending
-- or tearing down — wire this to a window focus-lost/iconify listener.
function M.persist()
	return with_default("persist")
end

function M.shutdown(reason)
	local client = default()
	if not client then
		return false, "not_initialized"
	end
	local ok, err = client:shutdown(reason)
	if ok then
		default_client = nil
	end
	return ok, err
end

function M.snapshot()
	return with_default("snapshot")
end

return M
