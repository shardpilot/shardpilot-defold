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

function M.identify(user_id)
	return default():identify(user_id)
end

function M.set_anonymous_id(anonymous_id)
	return default():set_anonymous_id(anonymous_id)
end

function M.session_start(props)
	return default():session_start(props)
end

function M.screen_view(screen_name, props)
	return default():screen_view(screen_name, props)
end

function M.track(event_name, props, context)
	return default():track(event_name, props, context)
end

function M.update(dt)
	return default():update(dt)
end

function M.observe_ping_ms(ms)
	return default():observe_ping_ms(ms)
end

function M.observe_disconnect(reason)
	return default():observe_disconnect(reason)
end

function M.flush()
	return default():flush()
end

function M.shutdown(reason)
	local client = default()
	default_client = nil
	return client:shutdown(reason)
end

function M.snapshot()
	return default():snapshot()
end

return M
