local clock = require "shardpilot.clock"
local analytics_retry = require "shardpilot.analytics_retry"
local experiment_facts = require "shardpilot.experiment_facts"
local id = require "shardpilot.id"
local utf8 = require "shardpilot.utf8"

local M = {}

-- The event contract version an event uses when the host selects none.
M.DEFAULT_SCHEMA_VERSION = 1

-- The version a track() options table selects: nil for the default, the
-- selected integer, or false when the options are not a table whose only key
-- is schema_version with an integer value from 1 through 65535. Nothing is
-- coerced: strings, booleans, fractions and non-finite numbers are refused.
-- Only the table's own entries count: __index and __pairs are not consulted.
function M.selected_schema_version(options)
	if options == nil then return nil end
	if type(options) ~= "table" then return false end
	local value
	for key, item in next, options do
		if key ~= "schema_version" then return false end
		value = item
	end
	if value == nil then return nil end
	if type(value) ~= "number" or value ~= math.floor(value) or value < 1 or value > 65535 then
		return false
	end
	-- An integral float becomes an integer, so the wire never carries "7.0".
	return math.floor(value)
end

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

	local out = {
		event_id = event.event_id or id.uuid(),
		schema_version = event.schema_version or M.DEFAULT_SCHEMA_VERSION,
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
	if event.sealed_fact then
		local fact = event.sealed_fact
		out.schema_version, out.source, out.user_id = 2, "client", nil
		out.workspace_id, out.app_id, out.environment_id = nil, nil, nil
		out.workspace_key, out.app_key, out.environment_key = fact.workspace_key, fact.app_key, fact.environment_key
		out.event_id, out.event_name, out.event_ts, out.props = fact.event_id, fact.event_name, fact.event_ts, fact.props
		out.attestation_seal, out.sealed_fact = fact.seal, fact
	end
	analytics_retry.bind(out, event)
	return out
end

-- Measure the complete raw element with the same encoder as batch transport.
-- In particular, sealed facts retain their signed bytes and interior spacing.
function M.admission_error(config, state, event)
	if not json or type(json.encode) ~= "function" then return "json_unavailable" end
	local ok, encoded = pcall(function()
		return experiment_facts.encode_event(M.build(config, state, event))
	end)
	if not ok or type(encoded) ~= "string" then return "json_encode_failed" end
	local trimmed = encoded:match("^%s*(.-)%s*$")
	if #trimmed > 2048 then return "event_too_large" end
	return nil
end

return M
