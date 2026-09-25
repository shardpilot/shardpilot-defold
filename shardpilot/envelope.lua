local clock = require "shardpilot.clock"
local id = require "shardpilot.id"
local utf8 = require "shardpilot.utf8"

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
	local props = copy_table(event.props)
	-- Omission is unambiguous even when the host encodes an empty table as [].
	if props and next(props) == nil then
		props = nil
	end
	local context = copy_table(event.context)

	return {
		event_id = event.event_id or id.uuid(),
		schema_version = 1,
		event_name = event.event_name,
		source = config.source,
		event_ts = event.event_ts or clock.iso_utc(),
		workspace_id = config.workspace_id,
		app_id = config.app_id,
		environment_id = config.environment_id,
		user_id = event.user_id,
		anonymous_id = event.anonymous_id,
		session_id = event.session_id,
		session_sequence = event.session_sequence,
		platform = config.platform,
		app_version = utf8.repair(config.app_version),
		app_build = utf8.repair(config.app_build),
		props = props,
		context = context,
	}
end

return M
