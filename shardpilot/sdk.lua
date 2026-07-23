local client_mod = require "shardpilot.client"

local M = {}
local default_client = nil

-- Capability discovery. Lets an integration feature-detect SDK abilities that
-- are not new functions (and so cannot be detected by their presence, the way
-- `crash.set_enabled` can) — usable BEFORE init() and without version
-- parsing. Unknown capability names return false on older and newer SDKs
-- alike, so a game can gate new call shapes safely:
--
--   if shardpilot.supports("consent_state_denied_forced_minor") then
--     shardpilot.set_consent("denied_forced_minor")
--   else
--     shardpilot.set_consent(false)
--   end
local capabilities = {
	-- Consent receipts are retained in a durable per-app outbox, survive
	-- process death, and retry until the server acknowledges them.
	consent_receipt_outbox = true,
	-- set_consent accepts the "denied_forced_minor" decision (an age-gate-
	-- forced denial whose receipt records reason = "denied_forced_minor").
	consent_state_denied_forced_minor = true,
	-- Every events:batch request declares the SDK's schema-set revision in
	-- the X-ShardPilot-Schema-Revision request header, and the config knob
	-- `schema_revision` exists (a string overrides the declared value;
	-- `false` or `""` stops declaring). Detectable here because a config
	-- field unknown to an older SDK would be silently ignored.
	schema_revision_declaration = true,
	-- The experiment-assignment consumer exists: the config knob
	-- `experiments_enabled` (default false — dark) and the
	-- fetch_experiment_assignment / experiment_variant / experiment_payload /
	-- track_exposure / track_outcome surface. Detectable here because a
	-- config field unknown to an older SDK would be silently ignored, and
	-- the enablement preconditions live server-side.
	experiments_assignment = true,
}

function M.supports(capability)
	return capabilities[capability] == true
end

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

-- Record an explicit analytics consent decision: true (granted), false
-- (denied), or the string "denied_forced_minor" — a band-forced denial that
-- gates analytics exactly like denied and differs only in the reason its
-- receipt records. See docs/privacy.md.
function M.set_consent(decision)
	return with_default("set_consent", decision)
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

-- Targeting attributes for the ADR-0310 opt-in ride with_default: storing a
-- set is an action with a real failure mode ("not_initialized" /
-- "remote_config_not_configured"), not a value read.
function M.set_remote_config_attributes(attributes)
	return with_default("set_remote_config_attributes", attributes)
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

-- Experiments (dark behind `experiments_enabled`, default false).
-- `fetch_experiment_assignment` reports "not_initialized" through the result
-- callback too, mirroring fetch_remote_config. The getters serve nil when
-- the SDK is not initialized (indistinguishable from "no assignment" — game
-- code treats both as the control experience). `attributes` is optional:
-- (key, callback) is accepted.
function M.fetch_experiment_assignment(experiment_key, attributes, callback)
	if type(attributes) == "function" and callback == nil then
		callback = attributes
		attributes = nil
	end
	local client = default()
	if not client then
		if type(callback) == "function" then
			pcall(callback, { ok = false, from_cache = false, error = "not_initialized" })
		end
		return false, "not_initialized"
	end
	return client:fetch_experiment_assignment(experiment_key, attributes, callback)
end

function M.experiment_variant(experiment_key)
	local client = default()
	if not client then
		return nil
	end
	return client:experiment_variant(experiment_key)
end

function M.experiment_payload(experiment_key)
	local client = default()
	if not client then
		return nil
	end
	return client:experiment_payload(experiment_key)
end

function M.track_exposure(experiment_key)
	return with_default("track_exposure", experiment_key)
end

function M.track_outcome(experiment_key, outcome_key, outcome_value)
	return with_default("track_outcome", experiment_key, outcome_key, outcome_value)
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
