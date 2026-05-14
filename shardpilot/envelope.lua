local clock = require "shardpilot.clock"
local id = require "shardpilot.id"

local M = {}

local function copy_table(value)
	if type(value) ~= "table" then
		return nil
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = v
	end
	return out
end

function M.build(config, state, event)
	local props = copy_table(event.props) or {}
	local context = copy_table(event.context)

	state.session_sequence = state.session_sequence + 1

	return {
		event_id = event.event_id or id.uuid(),
		schema_version = 1,
		event_name = event.event_name,
		source = config.source,
		event_ts = event.event_ts or clock.iso_utc(),
		workspace_id = config.workspace_id,
		app_id = config.app_id,
		environment_id = config.environment_id,
		user_id = state.user_id,
		anonymous_id = state.anonymous_id,
		session_id = state.session_id,
		session_sequence = state.session_sequence,
		platform = config.platform,
		app_version = config.app_version,
		app_build = config.app_build,
		props = props,
		context = context,
	}
end

return M
