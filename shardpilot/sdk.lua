local facade = require "shardpilot.internal.facade"
local client_mod = require "shardpilot.client"

local M = {}
local default_client = nil
local initializing = false
local pending_init_flush = nil
local active_init_drain = nil

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
	-- Engine builds do not declare a schema-set revision.
	schema_revision_declaration = false,
	-- The experiment-assignment consumer exists: the config knob
	-- `experiments_enabled` (default false — dark) and the
	-- fetch_experiment_assignment / experiment_variant / experiment_payload /
	-- track_exposure / track_outcome surface. Detectable here because a
	-- config field unknown to an older SDK would be silently ignored, and
	-- the enablement preconditions live server-side.
	experiments_assignment = true,
	-- The declared-age fetch method is separate from the original consumer.
	experiments_age_band = true,
	-- track() takes a fourth options argument whose schema_version selects
	-- the event's contract version, kept through serialization and retry.
	event_schema_version = true,
}

function M.supports(capability)
	return capabilities[capability] == true
end

local instance_methods = {
	identify = 1,
	set_anonymous_id = 1,
	get_session_id = 0,
	get_anonymous_id = 0,
	get_consent_state = 0,
	set_consent = 2,
	fetch_remote_config = 1,
	set_remote_config_attributes = 1,
	remote_config_value = 1,
	remote_config_string = 2,
	remote_config_number = 2,
	remote_config_boolean = 2,
	remote_config_values = 0,
	remote_config_version = 0,
	fetch_experiment_assignment = 3,
	fetch_experiment_assignment_with_age_band = 4,
	experiment_variant = 1,
	experiment_payload = 1,
	apply_experiment_variant = 1,
	track_exposure = 1,
	track_outcome = 3,
	session_start = 1,
	session_end = 1,
	screen_view = 2,
	track = 4,
	track_level_start = 3,
	track_level_complete = 5,
	track_level_fail = 5,
	track_ad_impression_revenue = 8,
	update = 1,
	observe_ping_ms = 1,
	observe_disconnect = 1,
	flush = { 2, "bounded_flush" },
	on_window_event = 1,
	persist = 0,
	shutdown = { 2, "bounded_shutdown" },
	get_rejections = 0,
	snapshot = 0,
}

function M.new(config)
	local client, err = client_mod.new(config)
	if not client then return nil, err end
	return facade.new(client, instance_methods)
end


function M.init(config)
	if default_client or initializing then
		return false, "already_initialized"
	end
	-- Reserve the singleton before construction can invoke a host hook.
	initializing = true
	local constructed, client, err, flush_init_diagnostics = pcall(client_mod.new, config, true)
	initializing = false
	if not constructed then error(client, 0) end
	if not client then
		return false, err
	end
	default_client = client
	pending_init_flush = flush_init_diagnostics
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

-- A VALUE read, not a command: with_default answers `false, "not_initialized"`
-- when there is no default client, which is the right shape for an action that
-- could not be performed but the wrong shape for a getter whose contract is a
-- nullable value. A caller writing the documented `if id ~= nil then …` would
-- treat that `false` as a present id and pass a boolean downstream.
local function value_from_default(method)
	local client = default()
	if not client then
		return nil
	end
	return client[method](client)
end

-- The current analytics session id, or nil when none is open — including before
-- init() and after shutdown(), not only between session_end and session_start.
function M.get_session_id()
	return value_from_default("get_session_id")
end

function M.get_anonymous_id()
	return value_from_default("get_anonymous_id")
end

function M.get_consent_state()
	local client = default()
	if not client then return "unknown" end
	return client:get_consent_state()
end

-- Record an explicit analytics consent decision: true (granted), false
-- (denied), or the string "denied_forced_minor" — a band-forced denial that
-- gates analytics exactly like denied and differs only in the reason its
-- receipt records. See docs/privacy.md.
function M.set_consent(decision, notice)
	return with_default("set_consent", decision, notice)
end

-- Remote config stays available without a grant, omitting identity and
-- targeting attributes. `fetch_remote_config` reports "not_initialized" through the
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

-- Targeting attributes for the opt-in ride with_default: storing a
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

function M.fetch_experiment_assignment_with_age_band(experiment_key, band, attributes, callback)
	if type(attributes) == "function" and callback == nil then
		callback, attributes = attributes, nil
	end
	local client = default()
	if not client then
		if type(callback) == "function" then
			pcall(callback, { ok = false, from_cache = false, error = "not_initialized" })
		end
		return false, "not_initialized"
	end
	return client:fetch_experiment_assignment_with_age_band(experiment_key, band, attributes, callback)
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

function M.apply_experiment_variant(experiment_key)
	local client = default()
	if not client then return nil, "not_initialized" end
	return client:apply_experiment_variant(experiment_key)
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

function M.session_end(reason)
	return with_default("session_end", reason)
end

function M.screen_view(screen_name, props)
	return with_default("screen_view", screen_name, props)
end

function M.track(event_name, props, context, options)
	return with_default("track", event_name, props, context, options)
end

function M.track_level_start(level_id, attempt, props)
	return with_default("track_level_start", level_id, attempt, props)
end

function M.track_level_complete(level_id, attempt, duration_ms, score, props)
	return with_default("track_level_complete", level_id, attempt, duration_ms, score, props)
end

function M.track_level_fail(level_id, attempt, duration_ms, fail_reason, props)
	return with_default("track_level_fail", level_id, attempt, duration_ms, fail_reason, props)
end

function M.track_ad_impression_revenue(
	impression_id,
	network,
	revenue_micros,
	currency,
	revenue_precision,
	ad_unit,
	ad_format,
	placement
)
	return with_default(
		"track_ad_impression_revenue",
		impression_id,
		network,
		revenue_micros,
		currency,
		revenue_precision,
		ad_unit,
		ad_format,
		placement
	)
end

function M.update(dt)
	-- A boot callback cannot start another drain or pump, even after re-init.
	if active_init_drain then return end
	local client = default()
	if not client then return false, "not_initialized" end
	local flush = pending_init_flush
	pending_init_flush = nil
	if flush then
		local drain = { cancelled = false }
		active_init_drain = drain
		flush(function() return default_client == client and not drain.cancelled end)
		active_init_drain = nil
		-- Check after the final callback too: it may have removed this client.
		if default_client ~= client or drain.cancelled then return end
	end
	return client:update(dt)
end

function M.observe_ping_ms(ms)
	return with_default("observe_ping_ms", ms)
end

function M.observe_disconnect(reason)
	return with_default("observe_disconnect", reason)
end

-- Deliver what is queued now, within timeout_seconds (default 10). The
-- callback runs once, on the main loop, with (true) or (false, code); see
-- docs/configuration.md. Without an initialized client it is told at once.
function M.flush(timeout_seconds, callback)
	if not default() then
		if type(callback) == "function" then
			pcall(callback, false, "not_initialized")
		end
		return false, "not_initialized"
	end
	return with_default("bounded_flush", timeout_seconds, callback)
end

-- Forward every window event the host's listener receives (the engine allows
-- one listener). A background signal snapshots like persist() and records a
-- pause; a foreground signal ends a session paused for session_timeout_seconds
-- or longer and starts the next one.
function M.on_window_event(event)
	return with_default("on_window_event", event)
end

-- Snapshot undelivered events into the durable offline spool without sending
-- or tearing down. on_window_event does this on a background signal; call it
-- directly only where the host has no window listener to forward.
function M.persist()
	return with_default("persist")
end

-- End the session, deliver what is held within timeout_seconds (default 10),
-- and tear the client down; the callback runs once, on the main loop, with
-- (true) or (false, code). See docs/configuration.md. The default client is
-- released when it is torn down, so a later init() starts a new one.
function M.shutdown(timeout_seconds, callback)
	-- Refused before the wrapper below, which would make any callback valid.
	if callback ~= nil and type(callback) ~= "function" then
		return false, "invalid_callback"
	end
	local client = default()
	if not client then
		if callback then
			pcall(callback, false, "not_initialized")
		end
		return false, "not_initialized"
	end
	local function release()
		-- A shutdown response hook may have adopted another client.
		if not client.initialized and default_client == client then
			default_client = nil
			pending_init_flush = nil
		end
	end
	local ok, err = client:bounded_shutdown(timeout_seconds, function(done, code)
		release()
		if callback then
			callback(done, code)
		end
	end)
	-- A shutdown the client takes ends the current boot delivery attempt; a
	-- refused one changes nothing.
	if active_init_drain and err ~= "invalid_timeout_seconds" then
		active_init_drain.cancelled = true
	end
	release()
	return ok, err
end

function M.get_rejections()
	return with_default("get_rejections")
end

function M.snapshot()
	return with_default("snapshot")
end

return M
