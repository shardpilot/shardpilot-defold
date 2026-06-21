local envelope = require "shardpilot.envelope"
local clock = require "shardpilot.clock"
local id = require "shardpilot.id"
local platform = require "shardpilot.platform"
local queue = require "shardpilot.queue"
local sampling = require "shardpilot.sampling"
local storage = require "shardpilot.storage"
local transport = require "shardpilot.transport"

local M = {}

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

local function local_http_host(host)
	return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function parse_authority(authority)
	if authority == "" or authority:find("@", 1, true) then
		return nil
	end
	local host = nil
	if authority:sub(1, 1) == "[" then
		local rest = nil
		host, rest = authority:match("^%[([^%]]+)%](.*)$")
		if not host then
			return nil
		end
		if rest ~= "" and not rest:match("^:%d+$") then
			return nil
		end
	else
		local colon = authority:find(":", 1, true)
		if colon then
			host = authority:sub(1, colon - 1)
			local port = authority:sub(colon + 1)
			if port == "" or not port:match("^%d+$") then
				return nil
			end
		else
			host = authority
		end
		if host:find(":", 1, true) then
			return nil
		end
	end
	if not host or host == "" or host:match("%s") then
		return nil
	end
	return host
end

local function valid_ingest_url(value)
	if type(value) ~= "string" or value == "" then
		return false
	end
	if value:find("?", 1, true) or value:find("#", 1, true) then
		return false
	end
	local scheme, rest = value:match("^(https?)://(.+)$")
	if not scheme then
		return false
	end
	local authority = rest
	local path = nil
	local slash = rest:find("/", 1, true)
	if slash then
		authority = rest:sub(1, slash - 1)
		path = rest:sub(slash)
	end
	if path and path ~= "/" then
		return false
	end
	local host = parse_authority(authority or "")
	if not host then
		return false
	end
	if scheme == "https" then
		return true
	end
	return local_http_host(host)
end

local max_snapshot_depth = 4

local function copy_value(value, depth, seen)
	if type(value) ~= "table" then
		return value, nil
	end
	if depth >= max_snapshot_depth or seen[value] then
		return nil, "invalid_table"
	end
	seen[value] = true
	local out = {}
	for k, v in pairs(value) do
		if type(k) == "table" then
			seen[value] = nil
			return nil, "invalid_table"
		end
		local copied, err = copy_value(v, depth + 1, seen)
		if err then
			seen[value] = nil
			return nil, err
		end
		out[k] = copied
	end
	seen[value] = nil
	return out, nil
end

local function copy_table(value, error_code)
	if value == nil or type(value) ~= "table" then
		return nil, nil
	end
	local copied, err = copy_value(value, 0, {})
	if err then
		return nil, error_code
	end
	return copied, nil
end

local function valid_identity(value)
	return type(value) == "string" and value ~= ""
end

-- Decode a server JSON body when a decoder is available (the real Defold
-- runtime exposes json.decode; the test stub may not). Returns the decoded
-- table or nil; never throws.
local function decode_body(body)
	if type(body) ~= "string" or body == "" then
		return nil
	end
	if not json or type(json.decode) ~= "function" then
		return nil
	end
	local ok, decoded = pcall(json.decode, body)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function to_count(value)
	if type(value) == "number" and value >= 0 then
		return math.floor(value)
	end
	return 0
end

-- Defer the next publish attempt by at least the given whole seconds. Clamped
-- to a sane upper bound so a hostile/garbage header cannot park the client for
-- a month; a missing value leaves the deadline untouched.
local max_publish_defer_seconds = 86400

local function defer_publish(client, seconds)
	if type(seconds) ~= "number" or seconds <= 0 then
		return
	end
	if seconds > max_publish_defer_seconds then
		seconds = max_publish_defer_seconds
	end
	local deadline = clock.unix_ms() + math.floor(seconds * 1000)
	if not client.publish_retry_after_ms or deadline > client.publish_retry_after_ms then
		client.publish_retry_after_ms = deadline
	end
end

local function normalize_integer(value, default_value, min_value, max_value, error_code)
	if value == nil then
		return default_value
	end
	if type(value) ~= "number" or value ~= math.floor(value) or value < min_value then
		return nil, error_code
	end
	if max_value and value > max_value then
		return nil, error_code
	end
	return value
end

local function normalize_positive_number(value, default_value, error_code)
	if value == nil then
		return default_value
	end
	if type(value) ~= "number" or value <= 0 then
		return nil, error_code
	end
	return value
end

local function normalize_non_negative_number(value, default_value, error_code)
	if value == nil then
		return default_value
	end
	if type(value) ~= "number" or value < 0 then
		return nil, error_code
	end
	return value
end

local function validate_config(config)
	if type(config) ~= "table" then
		return nil, "config_required"
	end
	local required = { "ingest_url", "workspace_id", "app_id", "environment_id" }
	for _, key in ipairs(required) do
		if config[key] == nil or config[key] == "" then
			return nil, key .. "_required"
		end
		if type(config[key]) ~= "string" then
			return nil, "invalid_" .. key
		end
	end
	if not valid_ingest_url(config.ingest_url) then
		return nil, "invalid_ingest_url"
	end
	-- Dual-mode auth. EITHER a Mode B async `token_provider` (a
	-- per-tenant ingest JWT minted by the host) OR a Mode A `api_key` (the
	-- non-secret publishable `sp_ingest_...` key, safe to embed client-side)
	-- satisfies the config. Mode is selected by presence: a configured
	-- `token_provider` yields the Bearer (Mode B); otherwise the `api_key` is
	-- the Bearer (Mode A). Configuring both is rejected so the auth source is
	-- never ambiguous.
	if config.token_provider ~= nil and type(config.token_provider) ~= "function" then
		return nil, "invalid_token_provider"
	end
	if config.api_key ~= nil and type(config.api_key) ~= "string" then
		return nil, "invalid_api_key"
	end
	local has_token_provider = type(config.token_provider) == "function"
	local has_api_key = type(config.api_key) == "string" and config.api_key ~= ""
	if has_token_provider and has_api_key then
		return nil, "auth_mode_conflict"
	end
	if not has_token_provider and not has_api_key then
		return nil, "auth_required"
	end
	local source = config.source or "client"
	if source ~= "client" and source ~= "server" and source ~= "backend" then
		return nil, "invalid_source"
	end
	local batch_size, batch_size_err = normalize_integer(config.batch_size, 25, 1, 100, "invalid_batch_size")
	if not batch_size then
		return nil, batch_size_err
	end
	local buffer_size, buffer_size_err = normalize_integer(config.buffer_size, 200, 1, nil, "invalid_buffer_size")
	if not buffer_size then
		return nil, buffer_size_err
	end
	local flush_interval_seconds, flush_interval_err =
		normalize_positive_number(config.flush_interval_seconds, 1, "invalid_flush_interval_seconds")
	if not flush_interval_seconds then
		return nil, flush_interval_err
	end
	local publish_timeout_seconds, publish_timeout_err =
		normalize_positive_number(config.publish_timeout_seconds, 2, "invalid_publish_timeout_seconds")
	if not publish_timeout_seconds then
		return nil, publish_timeout_err
	end
	local token_refresh_lead_ms, token_refresh_lead_err =
		normalize_non_negative_number(config.token_refresh_lead_ms, 60000, "invalid_token_refresh_lead_ms")
	if token_refresh_lead_ms == nil then
		return nil, token_refresh_lead_err
	end
	if config.diagnostics ~= nil and type(config.diagnostics) ~= "function" then
		return nil, "invalid_diagnostics"
	end
	local out = {
		ingest_url = trim_slash(config.ingest_url),
		workspace_id = config.workspace_id,
		app_id = config.app_id,
		environment_id = config.environment_id,
		app_version = config.app_version,
		app_build = config.app_build,
		source = source,
		platform = config.platform or platform.detect(),
		transport = config.transport,
		token_provider = config.token_provider,
		api_key = has_api_key and config.api_key or nil,
		diagnostics = config.diagnostics,
		batch_size = batch_size,
		buffer_size = buffer_size,
		flush_interval_seconds = flush_interval_seconds,
		publish_timeout_seconds = publish_timeout_seconds,
		token_refresh_lead_ms = token_refresh_lead_ms,
	}
	return out
end

local Client = {}
Client.__index = Client

function M.new(config)
	local normalized, err = validate_config(config)
	if not normalized then
		return nil, err
	end
	local stored = storage.load(normalized) or {}
	local anonymous_id
	if valid_identity(config.anonymous_id) then
		anonymous_id = config.anonymous_id
	elseif valid_identity(stored.anonymous_id) then
		anonymous_id = stored.anonymous_id
	else
		anonymous_id = id.uuid_v7()
	end
	local consent_state = "unknown"
	if stored.consent_analytics == "granted" or stored.consent_analytics == "denied" then
		consent_state = stored.consent_analytics
	end
	local client = setmetatable({
		config = normalized,
		queue = queue.new(normalized.buffer_size),
		stats = {
			enqueued = 0,
			dropped = 0,
			published = 0,
			failed_batches = 0,
			accepted = 0,
			rejected = 0,
			duplicates = 0,
			observed = 0,
			suppressed = 0,
			consent_recorded = 0,
			consent_failed = 0,
			consent_persist_failed = 0,
			last_consent_error = nil,
			last_error = nil,
			last_event_issue = nil,
		},
		token = nil,
		token_expires_at_ms = nil,
		token_request_in_flight = false,
		in_flight_batch = nil,
		publish_in_flight = false,
		publish_retry_after_ms = nil,
		publish_backoff_attempt = 0,
		user_id = valid_identity(config.user_id) and config.user_id or nil,
		anonymous_id = anonymous_id,
		consent_state = consent_state,
		consent_decision_seq = 0,
		session_id = nil,
		session_sequence = 0,
		session_active = false,
		perf = sampling.new_perf(),
		network = sampling.new_network(),
		flush_elapsed_seconds = 0,
		initialized = true,
	}, Client)
	if stored.anonymous_id ~= anonymous_id then
		client:persist_identity()
	end
	return client
end

function Client:persist_identity()
	local record = { anonymous_id = self.anonymous_id }
	if self.consent_state == "granted" or self.consent_state == "denied" then
		record.consent_analytics = self.consent_state
	end
	return storage.save(self.config, record)
end

function Client:identify(user_id)
	if not valid_identity(user_id) then
		return false, "invalid_user_id"
	end
	self.user_id = user_id
	return true
end

function Client:set_anonymous_id(anonymous_id)
	if not valid_identity(anonymous_id) then
		return false, "invalid_anonymous_id"
	end
	-- Mode B: the host's token_provider mints `bind_anon` from the
	-- anonymous_id returned by get_anonymous_id() at flush time, while events
	-- already queued (or in flight) carry the previous anon snapshot taken at
	-- track() time. Rotating the anon while a batch is pending would bind the
	-- token to the new anon but ship a payload carrying the old one, and the
	-- server rejects the whole batch. Require the host to flush first so the
	-- queued/in-flight anon and the next minted bind_anon stay aligned.
	-- Block rotation while any work bound to the OLD anon is pending, or a later
	-- mint/send would pair the new anon with old-anon data and be rejected:
	--   * queued / in-flight events carry the old anon snapshot;
	--   * token_request_in_flight: an async mint (e.g. a set_consent receipt) is
	--     running with the old anon and its callback would cache a stale-bind_anon
	--     JWT after we rotate;
	--   * pending_consent: a retained consent receipt carries the old anon
	--     actor_identifier and survives even after the token request settles (e.g.
	--     a token_provider error leaves it queued); its retry would mint for the
	--     new anon but send the old actor.
	-- The host retries the rotation once the pending work clears.
	local rotating = self.config.token_provider and anonymous_id ~= self.anonymous_id
	if rotating and (queue.size(self.queue) > 0 or self.in_flight_batch ~= nil
		or self.token_request_in_flight or self.pending_consent ~= nil) then
		return false, "events_pending"
	end
	self.anonymous_id = anonymous_id
	self:persist_identity()
	if rotating then
		-- A cached Mode B JWT was minted with bind_anon = the OLD anon. Even with
		-- the queue drained, can_publish() would reuse that still-valid token on
		-- the next flush, shipping the NEW anon under a Bearer bound to the old
		-- one (server rejects). Drop the cached token so the next publish mints a
		-- fresh one bound to the new anon.
		self.token = nil
		self.token_expires_at_ms = nil
	end
	return true
end

-- Expose the persisted anonymous ID so the host can hand it to its own backend
-- at JWT-mint time (the backend signs `bind_anon` = this value). The SDK
-- guarantees CONSISTENCY — it always sends, on the wire, the same anonymous_id
-- it returns here — but it does not itself verify the bind.
function Client:get_anonymous_id()
	return self.anonymous_id
end

function Client:set_consent(analytics_granted)
	if not self.initialized then
		return false, "shutdown"
	end
	if type(analytics_granted) ~= "boolean" then
		return false, "invalid_consent"
	end
	self.consent_state = analytics_granted and "granted" or "denied"
	if not analytics_granted then
		local cleared = queue.size(self.queue)
		if cleared > 0 then
			queue.drain(self.queue, cleared)
		end
		if self.in_flight_batch and not self.publish_in_flight then
			cleared = cleared + #self.in_flight_batch
			self.in_flight_batch = nil
		end
		if cleared > 0 then
			self.stats.dropped = self.stats.dropped + cleared
		end
		-- Any 429/transport backoff deferral was set for the now-discarded batch,
		-- so it is stale. Clear it (and the backoff attempt count) or a later
		-- granted batch queued before the old deadline would be blocked until it
		-- expires — up to a 24h Retry-After — even though that batch is gone.
		self.publish_retry_after_ms = nil
		self.publish_backoff_attempt = 0
	end
	local persisted = self:persist_identity()
	if not persisted then
		self.stats.consent_persist_failed = self.stats.consent_persist_failed + 1
		self.stats.last_consent_error = "consent_persist_failed"
	end
	self:send_consent_decision()
	if not persisted then
		-- The decision is applied in memory and reported to the wire, but
		-- the durable write failed: surface it like track does (ok, err).
		-- Calling set_consent again retries persistence.
		return false, "consent_persist_failed"
	end
	return true
end

function Client:send_consent_decision()
	-- Snapshot the decision at decision time; a later set_consent call
	-- replaces the pending payload (the latest decision wins). The sequence
	-- lets async result callbacks detect that their decision is stale.
	self.consent_decision_seq = self.consent_decision_seq + 1
	self.pending_consent = {
		workspace_id = self.config.workspace_id,
		app_id = self.config.app_id,
		environment_id = self.config.environment_id,
		actor_identifier = valid_identity(self.user_id) and self.user_id or self.anonymous_id,
		categories = { analytics = self.consent_state == "granted" },
		decided_at = clock.iso_utc(),
		idempotency_key = id.uuid_v7(),
	}
	local sent = self:try_send_pending_consent()
	if not sent and self.pending_consent then
		-- No token yet (for example an async token_provider still in flight):
		-- the decision stays retained and is retried at the next dispatch
		-- point (update/flush/shutdown) without another set_consent call.
		self.stats.consent_failed = self.stats.consent_failed + 1
		self.stats.last_consent_error = self.stats.last_error or "token_unavailable"
	end
	return sent
end

function Client:try_send_pending_consent()
	local payload = self.pending_consent
	if not payload then
		return true
	end
	if not self:can_publish() then
		return false
	end
	local decision_seq = self.consent_decision_seq
	self.pending_consent = nil
	return transport.send_consent(self.config, self.token, payload, function(ok, err, unauthorized)
		if ok then
			self.stats.consent_recorded = self.stats.consent_recorded + 1
			return
		end
		self.stats.consent_failed = self.stats.consent_failed + 1
		self.stats.last_consent_error = err
		if unauthorized then
			self.token = nil
			self.token_expires_at_ms = nil
			-- A Mode B auth failure must not lose the decision: retain it for a
			-- retry with a freshly minted token at the next dispatch point —
			-- unless a newer set_consent decision superseded it meanwhile (the
			-- latest decision wins; a stale payload is never resurrected). In
			-- Mode A the static key cannot change, so a 401 is terminal: drop the
			-- decision rather than replaying it forever against the same key.
			if self.config.token_provider ~= nil
				and self.consent_decision_seq == decision_seq and self.pending_consent == nil then
				self.pending_consent = payload
			end
		end
	end)
end

function Client:session_start(props)
	local previous_session_id = self.session_id
	local previous_session_sequence = self.session_sequence
	local previous_session_active = self.session_active

	self.session_id = "session-" .. id.uuid()
	self.session_sequence = 0
	self.session_active = true
	local ok, err = self:track("app.session_started", props)
	if not ok then
		self.session_id = previous_session_id
		self.session_sequence = previous_session_sequence
		self.session_active = previous_session_active
		return false, err
	end
	return true
end

function Client:session_end(reason)
	if not self.initialized then
		return false, "shutdown"
	end
	if self.consent_state == "denied" then
		-- Consent denied: suppress the wire event but still complete the
		-- local session teardown (the same posture as shutdown) so session
		-- state never stays stuck active for a denied user.
		self.session_active = false
		return true
	end
	local ok, err = self:track("session_end", { reason = reason or "session_end" })
	if not ok then
		return false, err
	end
	self.session_active = false
	return true
end

function Client:screen_view(screen_name, props)
	local out = {}
	if type(props) == "table" then
		for key, value in pairs(props) do
			out[key] = value
		end
	end
	out.screen_name = screen_name
	return self:track("app.screen_view", out)
end

function Client:tutorial_start(tutorial_id)
	return self:track("tutorial_start", { tutorial_id = tutorial_id })
end

function Client:tutorial_step_complete(tutorial_id, step_id)
	return self:track("tutorial_step_complete", { tutorial_id = tutorial_id, step_id = step_id })
end

function Client:tutorial_complete(tutorial_id)
	return self:track("tutorial_complete", { tutorial_id = tutorial_id })
end

function Client:track(event_name, props, context)
	if not self.initialized then
		self.stats.dropped = self.stats.dropped + 1
		return false, "shutdown"
	end
	if type(event_name) ~= "string" or event_name == "" then
		self.stats.dropped = self.stats.dropped + 1
		return false, "event_name_required"
	end
	if self.consent_state == "denied" then
		self.stats.dropped = self.stats.dropped + 1
		return false, "consent_denied"
	end
	if not valid_identity(self.user_id) and not valid_identity(self.anonymous_id) then
		self.stats.dropped = self.stats.dropped + 1
		self.stats.last_error = "identity_required"
		return false, "identity_required"
	end
	local props_snapshot, props_err = copy_table(props, "invalid_props")
	if props_err then
		self.stats.dropped = self.stats.dropped + 1
		return false, props_err
	end
	local context_snapshot, context_err = copy_table(context, "invalid_context")
	if context_err then
		self.stats.dropped = self.stats.dropped + 1
		return false, context_err
	end
	-- The server requires session_id for non-backend sources; an event tracked
	-- before session_start() would otherwise ship with no session_id and the
	-- whole batch would be 400-rejected. Lazily open a session so a session_id
	-- is always present. An explicit session_start() still renews the session.
	local opened_lazy_session = false
	if self.session_id == nil and self.config.source ~= "backend" then
		self.session_id = "session-" .. id.uuid()
		self.session_sequence = 0
		self.session_active = true
		opened_lazy_session = true
	end
	local event = {
		event_id = id.uuid(),
		event_name = event_name,
		event_ts = clock.iso_utc(),
		user_id = self.user_id,
		anonymous_id = self.anonymous_id,
		session_id = self.session_id,
		session_sequence = self.session_sequence + 1,
		props = props_snapshot,
		context = context_snapshot,
	}
	local ok = queue.push(self.queue, event)
	if not ok then
		-- The lazy session above was committed before the push. If the push
		-- fails the event never enters the queue, so roll the session back —
		-- otherwise update()/shutdown() would later sample or emit a
		-- session_end for a session that carries no events.
		if opened_lazy_session then
			self.session_id = nil
			self.session_sequence = 0
			self.session_active = false
		end
		self.stats.dropped = self.stats.dropped + 1
		return false, "queue_full"
	end
	self.session_sequence = event.session_sequence
	self.stats.enqueued = self.stats.enqueued + 1
	return true
end

function Client:update(dt)
	if not self.initialized then
		return
	end
	if type(dt) == "number" and dt > 0 then
		self.flush_elapsed_seconds = self.flush_elapsed_seconds + dt
	end
	if self.session_active and type(dt) == "number" then
		sampling.sample_frame(self.perf, dt)
	end
	if queue.size(self.queue) >= self.config.batch_size or self.flush_elapsed_seconds >= self.config.flush_interval_seconds then
		self.flush_elapsed_seconds = 0
		self:flush({ include_summaries = false })
	end
end

function Client:observe_ping_ms(ms)
	sampling.sample_ping(self.network, ms)
end

function Client:observe_disconnect(reason)
	sampling.disconnect(self.network, reason)
end

function Client:enqueue_summaries()
	local perf = sampling.perf_summary(self.perf)
	if perf then
		self:track("perf_summary", perf)
	end
	local network = sampling.network_summary(self.network, self.config.transport)
	if network then
		self:track("network_summary", network)
	end
end

function Client:refresh_token()
	-- Mode A: no async token_provider is configured, so the standing
	-- Bearer is the non-secret publishable `api_key`. It never expires and is
	-- restored synchronously here (including after a 401 clears self.token), so
	-- the publish/consent paths treat the api_key exactly like a yielded JWT.
	if self.config.api_key then
		self.token = self.config.api_key
		self.token_expires_at_ms = nil
		return true
	end
	if self.token_request_in_flight then
		return false
	end
	self.token_request_in_flight = true
	local ok, err = pcall(self.config.token_provider, function(new_token, new_expires_at, callback_error)
		self.token_request_in_flight = false
		if callback_error or type(new_token) ~= "string" or new_token == "" then
			self.token = nil
			self.token_expires_at_ms = nil
			self.stats.last_error = "token_unavailable"
			return
		end
		if new_expires_at ~= nil and type(new_expires_at) ~= "number" then
			self.token = nil
			self.token_expires_at_ms = nil
			self.stats.last_error = "token_unavailable"
			return
		end
		self.token = new_token
		self.token_expires_at_ms = new_expires_at
	end)
	if not ok then
		self.token_request_in_flight = false
		self.token = nil
		self.token_expires_at_ms = nil
		self.stats.last_error = "token_unavailable"
		return false
	end
	return self.token ~= nil
end

function Client:can_publish()
	if not valid_identity(self.user_id) and not valid_identity(self.anonymous_id) then
		self.stats.last_error = "identity_required"
		return false
	end
	local needs_token = not self.token
	if self.token and self.token_expires_at_ms then
		needs_token = clock.unix_ms() >= self.token_expires_at_ms - self.config.token_refresh_lead_ms
	end
	if needs_token and not self:refresh_token() then
		return false
	end
	return true
end

local function is_retryable_publish_failure(err, unauthorized, retryable, mode_b)
	-- An auth failure's retryability is a mode concern and overrides any
	-- transport-supplied `retryable` hint (the transport is mode-agnostic and
	-- flags every 401 as retryable). A 401 is only worth retrying when a
	-- token_provider (Mode B) can mint a fresh JWT on the next attempt; in
	-- Mode A the Bearer is the static publishable key, so a retry would replay
	-- the same unauthorized request forever and wedge the retained batch —
	-- treat it as terminal and drop.
	if unauthorized or err == "unauthorized" then
		return mode_b == true
	end
	if retryable ~= nil then
		return retryable
	end
	return err == "http_0" or err == "http_unavailable" or err == "transient_429" or
		(type(err) == "string" and err:match("^transient_5%d%d$") ~= nil)
end

-- diag_field coerces a server-supplied diagnostic field (status/code) to a safe
-- string for the snapshot. These values come straight from the ingest response,
-- so a malformed or proxy-mangled body could carry a non-string (number/boolean/
-- table). Concatenating a non-scalar raises a Lua error, which — happening inside
-- the batch callback — would abort flush(); coerce scalars and drop the rest.
local function diag_field(value)
	local t = type(value)
	if t == "string" then
		return value
	elseif t == "number" or t == "boolean" then
		return tostring(value)
	end
	return ""
end

-- Surface a per-event or batch issue through the optional diagnostics hook and
-- record it on the snapshot so an integrator learns their events were
-- observed/rejected/suppressed inside an otherwise "successful" 202.
function Client:diagnose(issue)
	local status = diag_field(issue.status)
	local code = diag_field(issue.code)
	if code ~= "" then
		self.stats.last_event_issue = status .. ":" .. code
	else
		self.stats.last_event_issue = status
	end
	local hook = self.config.diagnostics
	if type(hook) == "function" then
		-- The hook is integrator code; never let it break the publish path.
		pcall(hook, issue)
	end
end

-- Parse a 202 batch body: keep the aggregate counters and surface every
-- non-accepted per-event outcome (observed / duplicate / rejected /
-- suppressed_no_consent). A 202 is NOT treated as full per-event success.
-- "duplicate" is terminal, not retryable: the batch is already cleared by the
-- success path, so nothing is re-sent here.
function Client:apply_batch_response(body, batch_count)
	local decoded = decode_body(body)
	if not decoded then
		-- No parseable body (or no decoder in this runtime): fall back to the
		-- legacy aggregate assumption so counters never regress.
		self.stats.accepted = self.stats.accepted + batch_count
		return
	end
	local accepted = to_count(decoded.accepted)
	local rejected = to_count(decoded.rejected)
	local duplicates = to_count(decoded.duplicates)
	self.stats.accepted = self.stats.accepted + accepted
	self.stats.rejected = self.stats.rejected + rejected
	self.stats.duplicates = self.stats.duplicates + duplicates
	if type(decoded.events) ~= "table" then
		return
	end
	for _, entry in ipairs(decoded.events) do
		if type(entry) == "table" then
			local status = entry.status
			if status == "observed" then
				self.stats.observed = self.stats.observed + 1
			elseif status == "suppressed_no_consent" then
				self.stats.suppressed = self.stats.suppressed + 1
			end
			if status ~= nil and status ~= "accepted" then
				self:diagnose({
					scope = "event",
					event_id = entry.event_id,
					status = status,
					code = entry.code,
					message = entry.message,
				})
			end
		end
	end
end

-- Parse the { error: { code, message, details:[{field,code,message}] } }
-- envelope on a non-2xx response and surface error.code plus the detail codes
-- through diagnostics, instead of leaving only the bare transport status. Any
-- token material stays out of the issue (only server-returned fields are read).
function Client:apply_error_envelope(err, response)
	local body = type(response) == "table" and response.response or nil
	local decoded = decode_body(body)
	local error_obj = decoded and decoded.error
	if type(error_obj) ~= "table" then
		return
	end
	local detail_codes = nil
	if type(error_obj.details) == "table" then
		for _, detail in ipairs(error_obj.details) do
			if type(detail) == "table" and detail.code then
				detail_codes = detail_codes or {}
				detail_codes[#detail_codes + 1] = detail.code
			end
		end
	end
	if error_obj.code then
		self.stats.last_error = err .. ":" .. tostring(error_obj.code)
	end
	self:diagnose({
		scope = "batch",
		status = "rejected",
		code = error_obj.code,
		message = error_obj.message,
		detail_codes = detail_codes,
	})
end

-- Exponential-backoff-with-jitter fallback used when a retryable transport /
-- backpressure failure carries no Retry-After header. The first failure
-- retries on the next flush cadence without an extra wait; sustained failures
-- back off (doubling per consecutive failure up to a cap). A successful
-- publish resets the attempt counter.
local backoff_base_seconds = 1
local backoff_cap_seconds = 60

function Client:defer_backoff()
	self.publish_backoff_attempt = self.publish_backoff_attempt + 1
	if self.publish_backoff_attempt < 2 then
		-- First consecutive failure: retry on the next dispatch without a wait.
		return
	end
	local exp = self.publish_backoff_attempt - 2
	if exp > 16 then
		exp = 16
	end
	local ceiling = backoff_base_seconds * (2 ^ exp)
	if ceiling > backoff_cap_seconds then
		ceiling = backoff_cap_seconds
	end
	-- Full jitter in [base, ceiling]; never below the base so we always wait.
	local seconds = backoff_base_seconds + math.random() * (ceiling - backoff_base_seconds)
	defer_publish(self, seconds)
end

function Client:publish_deferred()
	return self.publish_retry_after_ms ~= nil and clock.unix_ms() < self.publish_retry_after_ms
end

function Client:start_publish_batch()
	if self.publish_in_flight or not self.in_flight_batch or #self.in_flight_batch == 0 then
		return true, false, true
	end
	-- Backpressure: a 429 Retry-After (or backoff) deferral is still in effect.
	-- Hold the batch (it stays retained in in_flight_batch) and report
	-- not-dispatched so flush returns without republishing before the deadline.
	if self:publish_deferred() then
		return false, false, false
	end
	local events = self.in_flight_batch
	if not events.payload then
		local envelopes = {}
		for i, event in ipairs(events) do
			envelopes[i] = envelope.build(self.config, self, event)
		end
		events.payload = { events = envelopes }
	end
	self.publish_in_flight = true
	local completed = false
	local succeeded = false
	local batch_count = #events
	local dispatched = transport.publish(self.config, self.token, events.payload, function(ok, err, unauthorized, retryable, response, retry_after)
		completed = true
		succeeded = ok == true
		self.publish_in_flight = false
		if ok then
			self.stats.published = self.stats.published + batch_count
			-- A successful publish clears any backpressure deferral/backoff.
			self.publish_retry_after_ms = nil
			self.publish_backoff_attempt = 0
			-- A 202 is NOT full per-event success: parse the body so observed /
			-- rejected / suppressed_no_consent outcomes are surfaced instead of
			-- silently counted as accepted. Duplicates are terminal; the batch
			-- is cleared here either way and never re-sent.
			local body = type(response) == "table" and response.response or nil
			self:apply_batch_response(body, batch_count)
			if self.in_flight_batch == events then
				self.in_flight_batch = nil
			end
			return
		end
		self.stats.failed_batches = self.stats.failed_batches + 1
		self.stats.last_error = err
		-- Surface the server error envelope (error.code + detail codes) on a
		-- non-2xx instead of leaving only the bare transport status.
		self:apply_error_envelope(err, response)
		-- Backpressure: honor a 429 Retry-After (whole seconds) by deferring the
		-- next publish attempt at least that long. Absent a header, fall back to
		-- exponential backoff with jitter on a transient transport/backpressure
		-- failure. A 401 is an auth problem, not backpressure: in Mode B it drops
		-- the stale JWT and retries immediately with a freshly minted one (never
		-- deferred); in Mode A the static key cannot change, so it is terminal.
		local mode_b = self.config.token_provider ~= nil
		-- A batch is retained for retry only when the failure is retryable AND
		-- consent has not been denied meanwhile; a denial recorded while the
		-- publish was in flight must drop the batch instead of republishing it. A
		-- Mode A 401 is non-retryable, so the batch is dropped here too. Compute
		-- this FIRST so the deferral below is only set for a batch we keep.
		local retain = is_retryable_publish_failure(err, unauthorized, retryable, mode_b) and self.consent_state ~= "denied"
		if unauthorized then
			self.token = nil
			self.token_expires_at_ms = nil
		-- Defer the next publish ONLY for a retained batch. Deferring for a batch
		-- about to be dropped (denied meanwhile) would leave a stale deadline that
		-- blocks a later granted batch for the whole Retry-After/backoff window
		-- (up to the 24h clamp). A 401 is never deferred (handled above).
		elseif retain and retry_after and retry_after > 0 then
			defer_publish(self, retry_after)
		elseif retain and is_retryable_publish_failure(err, unauthorized, retryable, mode_b) then
			self:defer_backoff()
		end
		if not retain and self.in_flight_batch == events then
			self.stats.dropped = self.stats.dropped + batch_count
			self.in_flight_batch = nil
		end
	end)
	if not dispatched and self.publish_in_flight then
		self.publish_in_flight = false
	end
	return dispatched, completed, succeeded
end

function Client:flush(options)
	if type(options) ~= "table" then
		options = {}
	end
	-- A consent decision retained while no token was available rides the
	-- same dispatch cadence as queued events; its outcome never affects the
	-- flush result.
	self:try_send_pending_consent()
	if options.include_summaries ~= false then
		self:enqueue_summaries()
	end
	self.flush_elapsed_seconds = 0
	if self.publish_in_flight then
		if self.in_flight_batch or queue.size(self.queue) > 0 then
			return false, "pending"
		end
		return true
	end

	while true do
		local token_ready = false
		if not self.in_flight_batch then
			if queue.size(self.queue) == 0 then
				return true
			end
			if not self:can_publish() then
				return false
			end
			token_ready = true
			self.in_flight_batch = queue.drain(self.queue, self.config.batch_size)
		end
		if not token_ready and not self:can_publish() then
			return false
		end
		local dispatched, completed, succeeded = self:start_publish_batch()
		if not dispatched or (completed and not succeeded) then
			return false
		end
		if self.publish_in_flight then
			return false, "pending"
		end
	end
end

function Client:shutdown(reason)
	local denied = self.consent_state == "denied"
	if self.session_active then
		-- session_end completes the local teardown even while consent is
		-- denied (the wire event is suppressed inside session_end); summary
		-- events are suppressed below via include_summaries.
		local session_ok, session_err = self:session_end(reason or "app_final")
		if not session_ok then
			return false, session_err
		end
	end
	local ok, err = self:flush({ include_summaries = not denied })
	if not ok then
		return false, err
	end
	if self.pending_consent then
		-- A consent decision deferred behind an async token participates in
		-- shutdown's wait semantics the same way queued events do: keep the
		-- client alive so the host can retry shutdown once the token lands,
		-- instead of silently dropping the decision at teardown.
		return false, "consent_pending"
	end
	self.initialized = false
	return true
end

function Client:snapshot()
	local out = {}
	for key, value in pairs(self.stats) do
		out[key] = value
	end
	return out
end

M.Client = Client

return M
