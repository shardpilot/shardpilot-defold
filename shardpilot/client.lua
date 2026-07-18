local envelope = require "shardpilot.envelope"
local clock = require "shardpilot.clock"
local id = require "shardpilot.id"
local platform = require "shardpilot.platform"
local queue = require "shardpilot.queue"
local remote_config_mod = require "shardpilot.remote_config"
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

-- Both explicit denial flavors close the analytics pipeline identically. The
-- forced-minor state exists so an age-gate-forced denial is distinguishable
-- ON ITS RECEIPT (reason = "denied_forced_minor") from a denial the player
-- chose; every analytics gate treats the two as the same denied state.
local function consent_denied_state(state)
	return state == "denied" or state == "denied_forced_minor"
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
	-- Optional remote config: `remote_config_url` is the base URL of the
	-- remote-config endpoint (a separate service from the ingest endpoint),
	-- validated with the same URL shape rules. Omit the field to disable
	-- remote config; a configured value must be a valid base URL.
	if config.remote_config_url ~= nil and not valid_ingest_url(config.remote_config_url) then
		return nil, "invalid_remote_config_url"
	end
	local has_remote_config = config.remote_config_url ~= nil
	-- Dual-mode auth. EITHER a Mode B async `token_provider` (a
	-- per-tenant ingest JWT minted by the host) OR a Mode A `api_key` (the
	-- non-secret publishable `sp_ingest_...` key, safe to embed client-side)
	-- satisfies the config. Mode is selected by presence: a configured
	-- `token_provider` yields the ingest Bearer (Mode B); otherwise the
	-- `api_key` is the ingest Bearer (Mode A).
	--
	-- Remote config is the one exception to "configure exactly one". The
	-- remote-config endpoint authenticates with the publishable api_key
	-- only — a Mode B ingest token is scoped to event ingest and the
	-- remote-config endpoint rejects it. So with remote_config_url set, an
	-- api_key is required even in Mode B, and configuring both credentials
	-- becomes valid: the token_provider keeps the ingest Bearer, the
	-- api_key authenticates only the remote-config fetch. Without remote
	-- config, configuring both stays rejected so the ingest auth source is
	-- never ambiguous.
	if config.token_provider ~= nil and type(config.token_provider) ~= "function" then
		return nil, "invalid_token_provider"
	end
	if config.api_key ~= nil and type(config.api_key) ~= "string" then
		return nil, "invalid_api_key"
	end
	local has_token_provider = type(config.token_provider) == "function"
	local has_api_key = type(config.api_key) == "string" and config.api_key ~= ""
	if has_token_provider and has_api_key and not has_remote_config then
		return nil, "auth_mode_conflict"
	end
	if not has_token_provider and not has_api_key then
		return nil, "auth_required"
	end
	if has_remote_config and not has_api_key then
		return nil, "remote_config_api_key_required"
	end
	local source = config.source or "client"
	if source ~= "client" and source ~= "server" and source ~= "backend" then
		return nil, "invalid_source"
	end
	local batch_size, batch_size_err = normalize_integer(config.batch_size, 25, 1, 100, "invalid_batch_size")
	if not batch_size then
		return nil, batch_size_err
	end
	-- 1000 is the cross-SDK canonical default (SP-059): the Go, Unity, and
	-- Unreal SDKs and the platform docs all use a 1000-event in-memory queue.
	local buffer_size, buffer_size_err = normalize_integer(config.buffer_size, 1000, 1, nil, "invalid_buffer_size")
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
	if config.spool_enabled ~= nil and type(config.spool_enabled) ~= "boolean" then
		return nil, "invalid_spool_enabled"
	end
	local spool_max_events, spool_max_events_err =
		normalize_integer(config.spool_max_events, 500, 1, nil, "invalid_spool_max_events")
	if not spool_max_events then
		return nil, spool_max_events_err
	end
	-- The spool is persisted through the runtime save-file API, which caps a
	-- saved table at 512 KB; the byte budget is capped at 384 KB so the
	-- approximate size estimate plus serialization overhead stays clear of it.
	local spool_max_bytes, spool_max_bytes_err =
		normalize_integer(config.spool_max_bytes, 262144, 1024, 393216, "invalid_spool_max_bytes")
	if not spool_max_bytes then
		return nil, spool_max_bytes_err
	end
	local out = {
		ingest_url = trim_slash(config.ingest_url),
		remote_config_url = has_remote_config and trim_slash(config.remote_config_url) or nil,
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
		spool_enabled = config.spool_enabled ~= false,
		spool_max_events = spool_max_events,
		spool_max_bytes = spool_max_bytes,
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
	if stored.consent_analytics == "granted" or consent_denied_state(stored.consent_analytics) then
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
			consent_outbox_evicted = 0,
			consent_outbox_persist_failed = 0,
			spooled = 0,
			spool_resent = 0,
			spool_evicted = 0,
			spool_persist_failed = 0,
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
		-- Durable consent-receipt outbox (mirror of the persisted record,
		-- oldest receipt first). Receipts are delivered serially, strictly in
		-- decision order; consent_outbox_dirty marks a durable write that is
		-- still owed (retried at every consent dispatch point), and the
		-- consent deferral fields pace retries independently of the events
		-- plane's publish deferral.
		consent_outbox = {},
		consent_outbox_dirty = false,
		consent_send_in_flight = false,
		consent_retry_after_ms = nil,
		consent_backoff_attempt = 0,
		spool_record = {},
		spool_index = {},
		spool_batches = {},
		-- Deferred durable-spool work (retried at later dispatch points):
		-- entries acknowledged/terminally-rejected whose removal rewrite is
		-- still owed, and a denied/disabled purge that has not landed yet.
		spool_settled = {},
		spool_rewrite_pending = false,
		spool_purge_pending = false,
		-- Server-requested backpressure deadline (epoch ms) stored with the
		-- record; spool_disk_deadline_ms mirrors what the record carries.
		spool_retry_after_ms = nil,
		spool_disk_deadline_ms = nil,
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
	-- Remote config rides the client's identity: the persisted anonymous id
	-- is the client id every fetch is scoped by, read through the accessor at
	-- fetch time so a later set_anonymous_id is naturally picked up (and the
	-- old identity's cache becomes a scope miss). Constructed here — after the
	-- anonymous id is resolved — so a cached snapshot for this exact scope is
	-- served by the getters immediately, before any fetch.
	if normalized.remote_config_url then
		client.remote_config = remote_config_mod.new(normalized, function()
			return client.anonymous_id
		end)
	end
	-- Offline event spool: re-load the envelopes a previous launch could not
	-- deliver so they re-send (chunked to batch_size) before fresh events. The
	-- consent decision is rechecked first, and ONLY a launch that starts with
	-- a persisted GRANT loads the record for re-send. In every other state the
	-- record is purged at init, without sending:
	--   * a persisted denial — events captured before a revocation never
	--     outlive it (the documented denied semantics);
	--   * a disabled spool — envelopes persisted by an earlier configuration
	--     must not linger on disk, nor resend if the spool is later
	--     re-enabled;
	--   * an "unknown" consent state — the record cannot be PROVEN to have
	--     been written under a grant: a v0.5 install spooled while "unknown"
	--     was still open, an identity record that failed to read may have
	--     carried a denial whose purge is still owed (and init above already
	--     re-wrote the identity record without it), and a lost identity file
	--     leaves the same ambiguity. Without an affirmative persisted grant
	--     NOW, the envelopes are dropped rather than held for a later grant —
	--     the consent-first contract is that a grant opens the pipeline for
	--     FUTURE events only.
	-- The purge is attempted unconditionally and fails closed
	-- (spool_purge_pending) until it lands, so a failed purge is retried at
	-- every later dispatch point and at every later non-granted launch.
	if consent_state ~= "granted" or not normalized.spool_enabled then
		-- Attempt the purge UNCONDITIONALLY: gating it on a successful read
		-- would let a failed/corrupt read masquerade as "nothing to purge"
		-- and leave the stale file to replay after a later grant/re-enable.
		-- Clearing an absent record is an idempotent no-op.
		if not storage.clear_spool(normalized) then
			-- The purge itself failed. Fail closed: the record is never
			-- loaded or re-sent while the purge is owed, and later
			-- dispatch points keep retrying it until it lands.
			client.stats.spool_persist_failed = client.stats.spool_persist_failed + 1
			client.spool_purge_pending = true
		end
	else
		local spooled, stored_deadline = storage.load_spool(normalized)
		-- Server-requested backpressure survives a relaunch: when the record
		-- carries a still-future Retry-After deadline, seed the publish
		-- deferral so the startup resend waits out the remaining window
		-- (defer_publish's 24h clamp bounds wall-clock skew). An expired
		-- deadline is dropped by the rewrite below.
		if #spooled > 0 and type(stored_deadline) == "number" then
			local remaining_ms = stored_deadline - clock.unix_ms()
			if remaining_ms > 0 then
				defer_publish(client, remaining_ms / 1000)
				client.spool_retry_after_ms = client.publish_retry_after_ms
			end
		end
		local mismatched = 0
		if normalized.token_provider and #spooled > 0 then
			-- Mode B tokens are minted bound to the CURRENT anonymous ID. When a
			-- configured anonymous_id override changed the identity at init,
			-- spooled envelopes carrying the previous one would be rejected
			-- server-side on every re-send. Drop them from the record at load —
			-- deterministic, and surfaced via diagnostics — instead of replaying
			-- them into a guaranteed rejection. Mode A has no token binding, so
			-- historic-identity envelopes re-send unchanged there (the historic
			-- actor is the correct one for those events).
			local kept = {}
			for i = 1, #spooled do
				if spooled[i].anonymous_id == client.anonymous_id then
					kept[#kept + 1] = spooled[i]
				else
					mismatched = mismatched + 1
				end
			end
			if mismatched > 0 then
				spooled = kept
				client:diagnose({
					scope = "spool",
					status = "dropped",
					code = "identity_changed",
					count = mismatched,
				})
			end
		end
		if #spooled > 0 or mismatched > 0 then
			if #spooled == 0 then
				client.spool_retry_after_ms = nil
			end
			-- One durable rewrite: persists the identity drop and reapplies
			-- the CURRENT caps — a configuration that lowered the budgets
			-- trims an over-budget old record at load, oldest first (counted
			-- in spool_evicted) — and re-stamps or drops the stored deadline.
			-- Should this write fail, the raw list is used for this process
			-- and the caps apply on the next successful write.
			if client:write_spool_record(spooled) then
				spooled = client.spool_record
			end
		end
		if #spooled > 0 then
			client.spool_record = spooled
			local chunk = nil
			for i = 1, #spooled do
				client.spool_index[spooled[i].event_id] = true
				if not chunk or #chunk >= normalized.batch_size then
					chunk = {}
					client.spool_batches[#client.spool_batches + 1] = chunk
				end
				chunk[#chunk + 1] = spooled[i]
			end
		end
	end
	-- Durable consent-receipt outbox: reload the receipts a previous launch
	-- could not deliver and attempt delivery immediately. Deliberately
	-- UNCONDITIONAL on the consent state — the exact opposite of the event
	-- spool above: a receipt documents an explicit decision, so delivering it
	-- is permitted (and is the record's whole legal point) precisely when the
	-- analytics pipeline is closed. It still costs a fresh consent-first
	-- install nothing: an empty outbox returns before any token is minted, so
	-- an undecided client stays fully dark.
	client.consent_outbox = storage.load_consent_outbox(normalized)
	if normalized.token_provider and #client.consent_outbox > 0 then
		-- Mode B tokens are minted bound to the CURRENT anonymous ID.
		-- Retained receipts carry their decision-time anon snapshot; after an
		-- init-time anonymous_id override changed the identity, re-sending
		-- one would pair the old actor with a token bound to the new anon and
		-- be rejected on every retry — a wedged head that blocks the rest of
		-- the trail forever. Drop them at load — deterministic, surfaced via
		-- diagnostics — exactly like the event spool's identity_changed rule
		-- above. Mode A has no token binding, so historic-identity receipts
		-- re-send unchanged there (the historic actor is the correct subject
		-- of those decisions).
		local kept_receipts = {}
		local mismatched_receipts = 0
		for i = 1, #client.consent_outbox do
			if client.consent_outbox[i].anonymous_id == client.anonymous_id then
				kept_receipts[#kept_receipts + 1] = client.consent_outbox[i]
			else
				mismatched_receipts = mismatched_receipts + 1
			end
		end
		if mismatched_receipts > 0 then
			client.consent_outbox = kept_receipts
			client:persist_consent_outbox()
			client:diagnose({
				scope = "consent",
				status = "dropped",
				code = "identity_changed",
				count = mismatched_receipts,
			})
		end
	end
	client:try_send_consent_outbox()
	return client
end

function Client:persist_identity()
	local record = { anonymous_id = self.anonymous_id }
	if self.consent_state == "granted" or consent_denied_state(self.consent_state) then
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
	--   * retained consent receipts (the durable outbox — including receipts
	--     reloaded from a previous launch) carry the old anon actor_identifier
	--     and survive even after the token request settles (e.g. a
	--     token_provider error leaves them queued); their retry would mint for
	--     the new anon but send the old actor.
	--   * spooled envelopes loaded from a previous launch carry their historic
	--     anonymous_id snapshot; re-sending them under a token minted for the
	--     NEW anon would be rejected the same way, so rotation waits until the
	--     spool has drained.
	-- The host retries the rotation once the pending work clears.
	local rotating = self.config.token_provider and anonymous_id ~= self.anonymous_id
	if rotating and (queue.size(self.queue) > 0 or self.in_flight_batch ~= nil
		or self.token_request_in_flight or self:consent_outbox_pending()
		or self:spool_pending()) then
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

-- ── remote config ─────────────────────────────────────────────────────────────
--
-- Thin delegates over the remote-config client (shardpilot/remote_config.lua),
-- present only when `remote_config_url` is configured. The fetch is always an
-- explicit game-triggered call — the SDK never fetches configuration on its
-- own — and it is deliberately NOT consent-gated: configuration delivery
-- carries no analytics payload (the client id in the URL only scopes which
-- configuration to serve), so a denied analytics consent does not block it.
-- The typed getters never fail: without configuration (or without remote
-- config at all) they serve the caller's default.

function Client:fetch_remote_config(callback)
	-- The callback is game code; never let it break the SDK.
	if not self.initialized then
		-- Like every other network-producing call on a torn-down client: no
		-- request is dispatched, nothing is written, game code is not called
		-- back later. The read-only getters below stay usable, like
		-- snapshot().
		if type(callback) == "function" then
			pcall(callback, { ok = false, from_cache = false, error = "shutdown" })
		end
		return false, "shutdown"
	end
	if not self.remote_config then
		if type(callback) == "function" then
			pcall(callback, {
				ok = false,
				from_cache = false,
				error = "remote_config_not_configured",
			})
		end
		return false, "remote_config_not_configured"
	end
	return self.remote_config:fetch(callback)
end

function Client:remote_config_value(key)
	if not self.remote_config then
		return nil
	end
	return self.remote_config:get_value(key)
end

function Client:remote_config_string(key, default)
	if not self.remote_config then
		return default
	end
	return self.remote_config:get_string(key, default)
end

function Client:remote_config_number(key, default)
	if not self.remote_config then
		return default
	end
	return self.remote_config:get_number(key, default)
end

function Client:remote_config_boolean(key, default)
	if not self.remote_config then
		return default
	end
	return self.remote_config:get_boolean(key, default)
end

function Client:remote_config_values()
	if not self.remote_config then
		return nil
	end
	return self.remote_config:get_values()
end

function Client:remote_config_version()
	if not self.remote_config then
		return nil
	end
	return self.remote_config:get_version()
end

function Client:set_consent(decision)
	if not self.initialized then
		return false, "shutdown"
	end
	-- Accepted decisions: the two booleans (true = granted, false = denied)
	-- plus the one string state "denied_forced_minor" — an age-gate-forced
	-- denial that is analytics-wise IDENTICAL to denied (drop + purge + zero
	-- analytics egress) and differs only in the reason its receipt records,
	-- so the backend per-actor gate can tell a band-forced denial from a
	-- chosen one. Feature-detect with sdk.supports("consent_state_denied_forced_minor").
	local next_state
	if decision == true then
		next_state = "granted"
	elseif decision == false then
		next_state = "denied"
	elseif decision == "denied_forced_minor" then
		next_state = "denied_forced_minor"
	else
		return false, "invalid_consent"
	end
	local granted = next_state == "granted"
	-- Revocation cleanup completes before a new grant takes effect. The
	-- purge-owed flag is memory-only: if a grant were applied (and persisted)
	-- while the purge of an earlier revocation is still owed, a relaunch
	-- would see the granted decision and replay the pre-revocation record.
	-- Retry the purge here; while it keeps failing, the grant is NOT applied
	-- — the persisted decision stays denied, so every relaunch re-runs the
	-- purge at init and stays fail-closed until the stale record is gone.
	if granted and self.spool_purge_pending and not self:retry_spool_purge() then
		return false, "spool_purge_failed"
	end
	self.consent_state = next_state
	local purged = true
	if not granted then
		local cleared = queue.size(self.queue)
		if cleared > 0 then
			queue.drain(self.queue, cleared)
		end
		if self.in_flight_batch and not self.publish_in_flight then
			cleared = cleared + #self.in_flight_batch
			self.in_flight_batch = nil
		end
		if #self.spool_batches > 0 then
			for i = 1, #self.spool_batches do
				cleared = cleared + #self.spool_batches[i]
			end
			self.spool_batches = {}
		end
		if cleared > 0 then
			self.stats.dropped = self.stats.dropped + cleared
		end
		-- Revoked consent also purges the durable spool: envelopes captured
		-- before the denial must not survive it on disk or be re-sent on a
		-- later launch. Cleared unconditionally (even with the spool disabled)
		-- so a record left by an earlier configuration cannot linger. If the
		-- durable purge fails, the spool goes fail-closed (no appends, loads,
		-- or resends) and the purge is retried at later dispatch points; the
		-- failure is surfaced to the caller below so it can also retry.
		self.spool_record = {}
		self.spool_index = {}
		self.spool_settled = {}
		self.spool_rewrite_pending = false
		self.spool_retry_after_ms = nil
		if storage.clear_spool(self.config) then
			self.spool_purge_pending = false
			self.spool_disk_deadline_ms = nil
		else
			if not self.spool_purge_pending then
				self.stats.spool_persist_failed = self.stats.spool_persist_failed + 1
			end
			self.spool_purge_pending = true
			purged = false
		end
		-- Any 429/transport backoff deferral was set for the now-discarded batch,
		-- so it is stale. Clear it (and the backoff attempt count) or a later
		-- granted batch queued before the old deadline would be blocked until it
		-- expires — up to a 24h Retry-After — even though that batch is gone.
		self.publish_retry_after_ms = nil
		self.publish_backoff_attempt = 0
		-- Sampled-but-not-yet-summarized runtime signals are in-memory
		-- analytics data too: drop them with the queue, or the first flush
		-- after a re-grant would summarize pre-denial activity.
		self.perf = sampling.new_perf()
		self.network = sampling.new_network()
	end
	local persisted = self:persist_identity()
	if not persisted then
		self.stats.consent_persist_failed = self.stats.consent_persist_failed + 1
		self.stats.last_consent_error = "consent_persist_failed"
	end
	local receipt_safe = self:send_consent_decision()
	if not persisted then
		-- The decision is applied in memory and reported to the wire, but
		-- the durable write failed: surface it like track does (ok, err).
		-- Calling set_consent again retries persistence.
		return false, "consent_persist_failed"
	end
	if not purged then
		-- The denial applied (and persisted), but the durable spool purge
		-- failed: previously spooled envelopes are still on disk. Calling
		-- set_consent(false) again retries it, and later dispatch points
		-- keep retrying on their own.
		return false, "spool_purge_failed"
	end
	if not receipt_safe then
		-- The decision applied and persisted, and its receipt is queued and
		-- delivering — but the receipt's durable append failed and delivery
		-- has not yet acknowledged it: until the retried write (or the
		-- delivery) lands, the receipt exists only in memory and a process
		-- death would lose it. Surfaced so the host knows the offline-commit
		-- durability guarantee is not yet in effect; the write itself is
		-- retried automatically at every dispatch point.
		return false, "consent_outbox_persist_failed"
	end
	return true
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
	if self.consent_state ~= "granted" then
		-- Consent denied — or still unknown, which transmits nothing —
		-- suppress the wire event but still complete the local session
		-- teardown (the same posture as shutdown) so session state never
		-- stays stuck active for a consent-blocked user.
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
	if consent_denied_state(self.consent_state) then
		self.stats.dropped = self.stats.dropped + 1
		return false, "consent_denied"
	end
	-- Consent-first: while the decision is still "unknown" (no persisted
	-- grant — a fresh install, or an identity record that could not be read)
	-- the client transmits nothing. The event is DROPPED, not held: nothing
	-- is queued, nothing reaches the durable spool, so no pre-consent data
	-- exists at rest. set_consent(true) opens the pipeline for FUTURE events
	-- only.
	if self.consent_state ~= "granted" then
		self.stats.dropped = self.stats.dropped + 1
		return false, "consent_unknown"
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
	if self.session_active and self.consent_state == "granted" and type(dt) == "number" then
		-- Frame samples are analytics data: a session kept active through a
		-- denial must not keep feeding the perf sampler.
		sampling.sample_frame(self.perf, dt)
	end
	if queue.size(self.queue) >= self.config.batch_size or self.flush_elapsed_seconds >= self.config.flush_interval_seconds then
		self.flush_elapsed_seconds = 0
		self:flush({ include_summaries = false })
	end
end

function Client:observe_ping_ms(ms)
	-- Consent-first: runtime samples are analytics data, dropped at the
	-- source while the pipeline is closed — they would otherwise surface in
	-- the first summary emitted after a later grant.
	if self.consent_state ~= "granted" then
		return
	end
	sampling.sample_ping(self.network, ms)
end

function Client:observe_disconnect(reason)
	if self.consent_state ~= "granted" then
		return
	end
	sampling.disconnect(self.network, reason)
end

function Client:enqueue_summaries()
	-- Summary events ride the same consent gate as track(). While the
	-- pipeline is closed the accumulated samples are DROPPED, not held — the
	-- samplers are reset so runtime signals observed before a grant (or
	-- through a denial) can never surface in a summary emitted after a later
	-- grant.
	if self.consent_state ~= "granted" then
		self.perf = sampling.new_perf()
		self.network = sampling.new_network()
		return
	end
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
	-- The token_provider check keeps the precedence explicit for the one
	-- configuration where both credentials are present (remote config in
	-- Mode B): the ingest Bearer stays the minted token, never the api_key —
	-- the api_key authenticates only the remote-config fetch there.
	if self.config.api_key and not self.config.token_provider then
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

-- The wait for the given consecutive-failure attempt: nil for the first
-- failure (retry on the next dispatch without a wait), then full jitter in
-- [base, ceiling] with the ceiling doubling per attempt up to the cap —
-- never below the base so we always wait. Shared by the publish and
-- consent-receipt retry paths.
local function backoff_delay_seconds(attempt)
	if attempt < 2 then
		return nil
	end
	local exp = attempt - 2
	if exp > 16 then
		exp = 16
	end
	local ceiling = backoff_base_seconds * (2 ^ exp)
	if ceiling > backoff_cap_seconds then
		ceiling = backoff_cap_seconds
	end
	return backoff_base_seconds + math.random() * (ceiling - backoff_base_seconds)
end

function Client:defer_backoff()
	self.publish_backoff_attempt = self.publish_backoff_attempt + 1
	local seconds = backoff_delay_seconds(self.publish_backoff_attempt)
	if seconds then
		defer_publish(self, seconds)
	end
end

function Client:publish_deferred()
	return self.publish_retry_after_ms ~= nil and clock.unix_ms() < self.publish_retry_after_ms
end

-- ── consent-receipt outbox ────────────────────────────────────────────────────
--
-- Every explicit set_consent decision becomes exactly ONE receipt — the
-- `POST /v1/consent` payload snapshotted at decision time — appended to a
-- small durable outbox (storage.lua, per-app record "consent-outbox") so it
-- survives process death and offline play, and retried until the server
-- acknowledges it. The outbox is CONSENT-PLANE ONLY: it never carries event
-- envelopes, and — unlike the event spool — it is never consent-purged, and
-- its delivery is permitted while analytics consent is denied or unknown: a
-- receipt documents the decision itself, which is its legal purpose.
-- Receipts deliver serially, strictly in decision order (FIFO), so the
-- server applies the decision trail exactly as the player produced it.

-- True while any consent-receipt state is still unsettled: a receipt awaiting
-- server acknowledgment (including receipts reloaded from a previous launch),
-- OR an owed durable rewrite. The dirty case matters even with an empty
-- mirror — a failed post-delivery prune leaves the acknowledged receipt on
-- disk, where the next launch reloads and re-sends it; a Mode B anon rotation
-- must wait for that rewrite too, or the stale receipt would replay an old
-- actor under a token minted for the new one.
function Client:consent_outbox_pending()
	return #self.consent_outbox > 0 or self.consent_outbox_dirty
end

-- Consent-receipt delivery paces its retries independently of the events
-- plane: the publish deferral belongs to event batches (and a denial
-- deliberately clears it), while receipt retries must keep backing off even
-- when the analytics pipeline is closed.
function Client:defer_consent(seconds)
	if type(seconds) ~= "number" or seconds <= 0 then
		return
	end
	if seconds > max_publish_defer_seconds then
		seconds = max_publish_defer_seconds
	end
	local deadline = clock.unix_ms() + math.floor(seconds * 1000)
	if not self.consent_retry_after_ms or deadline > self.consent_retry_after_ms then
		self.consent_retry_after_ms = deadline
	end
end

function Client:defer_consent_backoff()
	self.consent_backoff_attempt = self.consent_backoff_attempt + 1
	local seconds = backoff_delay_seconds(self.consent_backoff_attempt)
	if seconds then
		self:defer_consent(seconds)
	end
end

function Client:consent_send_deferred()
	return self.consent_retry_after_ms ~= nil and clock.unix_ms() < self.consent_retry_after_ms
end

-- True while the durable outbox retains an analytics GRANT receipt that has
-- NOT yet been handed to the transport. Delivery is serial and in decision
-- order, so the only receipt that can have been handed over is the head
-- currently in flight — a grant anywhere else (parked behind a deferral or
-- backoff window, queued behind another receipt, or simply not yet
-- dispatched, e.g. right after a relaunch that reloaded the durable outbox)
-- is still awaiting its handoff, and an event batch dispatched meanwhile
-- would overtake it on the wire: on a strict-enforce workspace those
-- post-grant events reach the server before the grant row exists and are
-- terminally suppressed. The condition is DISPATCH, never acknowledgment: a
-- grant in flight (handed to the transport, response pending) does not hold
-- events — its request already precedes any batch dispatched after it.
function Client:grant_receipt_pending_dispatch()
	for i = 1, #self.consent_outbox do
		local receipt = self.consent_outbox[i]
		if type(receipt.categories) == "table" and receipt.categories.analytics == true then
			if i == 1 and self.consent_send_in_flight then
				-- The grant itself is the receipt being handed over right
				-- now: receipt-before-batch ordering is already secured.
				return false
			end
			return true
		end
	end
	return false
end

-- Rewrite the durable outbox record from the in-memory mirror. On a failed
-- write the mirror keeps ruling this process (retained receipts still
-- deliver), the write is marked owed (consent_outbox_dirty) and retried at
-- every consent dispatch point. On success the mirror adopts what storage
-- actually kept: the fixed entry cap evicts the OLDEST receipts first, and an
-- eviction of a still-undelivered receipt is counted and surfaced through
-- diagnostics. Returns true when the record matches the mirror.
function Client:persist_consent_outbox()
	local saved = storage.save_consent_outbox(self.config, self.consent_outbox)
	if not saved then
		self.stats.consent_outbox_persist_failed = self.stats.consent_outbox_persist_failed + 1
		self.consent_outbox_dirty = true
		return false
	end
	if #self.consent_outbox > #saved then
		local evicted = #self.consent_outbox - #saved
		self.stats.consent_outbox_evicted = self.stats.consent_outbox_evicted + evicted
		self:diagnose({
			scope = "consent",
			status = "dropped",
			code = "outbox_overflow",
			count = evicted,
		})
	end
	self.consent_outbox = saved
	self.consent_outbox_dirty = false
	return true
end

-- Retry an owed durable outbox write (a failed enqueue persist or a failed
-- post-delivery prune) so the record converges as soon as storage recovers,
-- instead of waiting for the next decision or a relaunch.
function Client:retry_consent_outbox_persist()
	if not self.consent_outbox_dirty then
		return true
	end
	return self:persist_consent_outbox()
end

-- Drop one delivered (or terminally rejected) receipt from the mirror and
-- prune it from the durable record. A failed prune never blocks the rest of
-- the trail: the mirror already dropped the entry (it cannot re-send this
-- process) and the rewrite is retried at later dispatch points; should the
-- app die first, the next launch re-sends the stale entry and the server
-- de-duplicates it on its idempotency_key.
function Client:remove_consent_receipt(idempotency_key)
	local kept = {}
	for i = 1, #self.consent_outbox do
		if self.consent_outbox[i].idempotency_key ~= idempotency_key then
			kept[#kept + 1] = self.consent_outbox[i]
		end
	end
	self.consent_outbox = kept
	self:persist_consent_outbox()
end

-- Snapshot the decision into a receipt and enqueue it for durable, ordered
-- delivery. Called from set_consent only — receipts exist for explicit
-- decisions, never for the undecided state. Returns true when this receipt
-- needs no further durability guarantee — durably appended, or already
-- acknowledged by a synchronous delivery — and false when it is still
-- undelivered with the durable append owed (a process death would lose it);
-- set_consent surfaces that as consent_outbox_persist_failed.
function Client:send_consent_decision()
	local payload = {
		workspace_id = self.config.workspace_id,
		app_id = self.config.app_id,
		environment_id = self.config.environment_id,
		actor_identifier = valid_identity(self.user_id) and self.user_id or self.anonymous_id,
		categories = { analytics = self.consent_state == "granted" },
		decided_at = clock.iso_utc(),
		idempotency_key = id.uuid_v7(),
		-- Retention metadata, never sent on the wire: the decision-time
		-- anonymous id, so a later Mode B launch whose identity changed can
		-- recognize (and drop) a receipt its minted token could never send.
		anonymous_id = self.anonymous_id,
	}
	if self.consent_state == "denied_forced_minor" then
		-- AC-8: the receipt itself records that this denial was band-forced,
		-- not chosen — the reason is the only difference from a plain denial.
		payload.reason = "denied_forced_minor"
	end
	-- Append via a fresh list: the mirror may alias the list held by the
	-- storage layer's in-process shadow (persist adopts the saved list), and
	-- an in-place append would mutate that shadow ahead of — and regardless
	-- of — the durable write.
	local appended = {}
	for i = 1, #self.consent_outbox do
		appended[i] = self.consent_outbox[i]
	end
	appended[#appended + 1] = payload
	self.consent_outbox = appended
	self:persist_consent_outbox()
	local attempted = self:try_send_consent_outbox()
	if not attempted and not self.consent_send_in_flight then
		-- Never dispatched: no usable token yet (e.g. an async Mode B mint
		-- still in flight) or an open backoff window. The receipt stays
		-- durably retained and is retried at the next dispatch point
		-- (init/update/flush/shutdown) without another set_consent call.
		self.stats.consent_failed = self.stats.consent_failed + 1
		self.stats.last_consent_error = self.stats.last_error or "token_unavailable"
	end
	-- Report on the CURRENT durability state, not the first write attempt:
	-- the dispatch path retries an owed write, so an append whose first write
	-- failed may already be durable by now. A failure is surfaced only when
	-- the record is still owed (dirty) AND this receipt is still awaiting
	-- delivery — a receipt the synchronous ack path already delivered and
	-- pruned has nothing left to lose (delivery is always attempted: the
	-- server-side record is the receipt's purpose; durability is the
	-- backstop for process death).
	if not self.consent_outbox_dirty then
		return true
	end
	for i = 1, #self.consent_outbox do
		if self.consent_outbox[i].idempotency_key == payload.idempotency_key then
			return false
		end
	end
	return true
end

-- Deliver the outbox serially, oldest receipt first — one receipt in flight
-- at a time, so receipts arrive in DECISION ORDER and a grant-then-deny can
-- never settle deny-then-grant. Returns true when the outbox is empty or a
-- dispatch was started (transport failures are counted inside the result
-- callback); false while delivery is blocked — a receipt already in flight,
-- an open backoff window, or no usable token yet. Failure handling mirrors
-- the publish path: retryable outcomes keep the receipt at the head (a
-- Retry-After or backoff paces the retry; a Mode B 401 retries immediately
-- with a freshly minted token), while terminal outcomes — including a Mode A
-- 401, whose static key cannot change — drop the receipt (surfaced through
-- diagnostics) rather than wedging every receipt queued behind it.
function Client:try_send_consent_outbox()
	-- A torn-down client dispatches nothing: a late async ack from a receipt
	-- that was in flight at shutdown() must not chain further /v1/consent
	-- traffic after the host tore the SDK down — the remaining durable
	-- receipts re-send at the next launch instead.
	if not self.initialized then
		return false
	end
	-- An owed durable write is retried on the same cadence as delivery.
	self:retry_consent_outbox_persist()
	local payload = self.consent_outbox[1]
	if not payload then
		return true
	end
	if self.consent_send_in_flight or self:consent_send_deferred() then
		return false
	end
	if not self:can_publish() then
		return false
	end
	-- The stored entry carries retention metadata (the decision-time
	-- anonymous_id snapshot read by the Mode B identity check at load); the
	-- wire payload is the receipt's contract fields only.
	local wire = {
		workspace_id = payload.workspace_id,
		app_id = payload.app_id,
		environment_id = payload.environment_id,
		actor_identifier = payload.actor_identifier,
		categories = payload.categories,
		decided_at = payload.decided_at,
		idempotency_key = payload.idempotency_key,
		reason = payload.reason,
	}
	self.consent_send_in_flight = true
	local dispatched = transport.send_consent(self.config, self.token, wire,
		function(ok, err, unauthorized, retryable, _, retry_after)
			self.consent_send_in_flight = false
			if ok then
				self.stats.consent_recorded = self.stats.consent_recorded + 1
				self.consent_retry_after_ms = nil
				self.consent_backoff_attempt = 0
				self:remove_consent_receipt(payload.idempotency_key)
				-- Chain the next retained receipt immediately (bounded by the
				-- outbox cap) so one healthy dispatch point drains the whole
				-- trail.
				self:try_send_consent_outbox()
				return
			end
			self.stats.consent_failed = self.stats.consent_failed + 1
			self.stats.last_consent_error = err
			if unauthorized then
				self.token = nil
				self.token_expires_at_ms = nil
			end
			local mode_b = self.config.token_provider ~= nil
			if is_retryable_publish_failure(err, unauthorized, retryable, mode_b) then
				-- The receipt stays at the head of the durable outbox for the
				-- next dispatch point. A 401 is an auth problem, not
				-- backpressure — never deferred (Mode B re-mints and retries
				-- immediately); transport transients honor a Retry-After or
				-- back off so a dead endpoint is not hammered every tick.
				if not unauthorized then
					if retry_after and retry_after > 0 then
						self:defer_consent(retry_after)
					else
						self:defer_consent_backoff()
					end
				end
				return
			end
			-- Terminal: the server will never accept this payload (or the Mode
			-- A key can never authorize it). Drop it — surfaced through
			-- diagnostics — so the receipts queued behind it still deliver.
			self:remove_consent_receipt(payload.idempotency_key)
			self:diagnose({
				scope = "consent",
				status = "dropped",
				code = err,
			})
			self:try_send_consent_outbox()
		end)
	if not dispatched then
		-- The transport reported synchronously through the callback
		-- (http/json unavailable): the failure is already counted and the
		-- receipt retained per its retryability, so the dispatch counts as
		-- attempted either way.
		self.consent_send_in_flight = false
	end
	return true
end

-- ── offline event spool ───────────────────────────────────────────────────────
--
-- Envelopes the client could not deliver are persisted (see storage.lua) and
-- re-sent on a later launch through the normal publish machinery. Spooled
-- envelopes are stored and re-sent VERBATIM — the event_id and event_ts
-- stamped at track() time are never rebuilt or re-stamped, so the ingest
-- service can de-duplicate a re-send that raced an original delivery.
-- `spool_record` mirrors the persisted list and `spool_index` its event_ids,
-- so appends are de-duplicated and acknowledged batches are removed cheaply.

-- True while envelopes loaded from a previous launch still await re-send.
function Client:spool_pending()
	return #self.spool_batches > 0
end

-- Build (once) and return the batch's wire payload. A retained batch keeps its
-- payload so retries and the spool always carry the exact envelopes of the
-- first attempt.
function Client:ensure_batch_payload(batch)
	if not batch.payload then
		local envelopes = {}
		for i, event in ipairs(batch) do
			envelopes[i] = envelope.build(self.config, self, event)
		end
		batch.payload = { events = envelopes }
	end
	return batch.payload
end

-- Replace the persisted spool with `events` and refresh the client mirror
-- from what storage actually kept after cap eviction. Every write drops the
-- entries marked settled (acknowledged/terminally rejected but whose earlier
-- removal rewrite failed), so any successful write doubles as the deferred
-- removal; the record also carries the current backpressure deadline.
function Client:write_spool_record(events)
	local target = events
	if next(self.spool_settled) ~= nil then
		target = {}
		for i = 1, #events do
			if not self.spool_settled[events[i].event_id] then
				target[#target + 1] = events[i]
			end
		end
	end
	local saved = storage.save_spool(self.config, target,
		self.config.spool_max_events, self.config.spool_max_bytes, self.spool_retry_after_ms)
	if not saved then
		self.stats.spool_persist_failed = self.stats.spool_persist_failed + 1
		if next(self.spool_settled) ~= nil then
			-- The settled entries are still on disk: keep them marked and
			-- retry the rewrite at the next dispatch point.
			self.spool_rewrite_pending = true
		end
		return false
	end
	if #target > #saved then
		self.stats.spool_evicted = self.stats.spool_evicted + (#target - #saved)
	end
	self.spool_record = saved
	self.spool_index = {}
	for i = 1, #saved do
		self.spool_index[saved[i].event_id] = true
	end
	self.spool_settled = {}
	self.spool_rewrite_pending = false
	self.spool_disk_deadline_ms = self.spool_retry_after_ms
	return true
end

-- Retry a denied/disabled purge that could not land. While the purge is owed
-- the spool is fail-closed (nothing appended, loaded, or re-sent). Invoked on
-- the flush cadence (update-driven), from persist()/shutdown(), and before
-- any append.
function Client:retry_spool_purge()
	if not self.spool_purge_pending then
		return true
	end
	if storage.clear_spool(self.config) then
		self.spool_purge_pending = false
		-- Nothing can be owed beneath a completed purge.
		self.spool_settled = {}
		self.spool_rewrite_pending = false
		self.spool_disk_deadline_ms = nil
		return true
	end
	return false
end

-- Retry the removal rewrite for settled entries: the mirror still holds them
-- (a failed write never mutates it), and write_spool_record's settled filter
-- drops them from what reaches the disk — so the record converges as soon as
-- storage recovers instead of waiting for an unrelated write or a relaunch.
function Client:retry_spool_rewrite()
	if not self.spool_rewrite_pending then
		return true
	end
	return self:write_spool_record(self.spool_record)
end

-- Append envelopes to the durable spool, skipping any already persisted — so
-- a batch that fails transiently more than once is spooled exactly once, and a
-- re-loaded spool batch is never appended again. Returns true when everything
-- new is durably recorded (vacuously true when nothing new).
function Client:spool_envelopes(envelopes)
	-- Only a granted actor's envelopes are ever written to disk: denied purges
	-- the record, and a consent-first "unknown" client never captured anything
	-- to spool in the first place.
	if not self.config.spool_enabled or self.consent_state ~= "granted" then
		return false
	end
	-- Fail-closed while a purge of the record is owed: retry it first, and
	-- never append to (or resurrect) a record that must be cleared.
	if self.spool_purge_pending and not self:retry_spool_purge() then
		return false
	end
	local fresh = {}
	local seen = {}
	for i = 1, #envelopes do
		local env = envelopes[i]
		local event_id = type(env) == "table" and env.event_id or nil
		if type(event_id) == "string" and event_id ~= ""
			and not self.spool_index[event_id] and not seen[event_id] then
			seen[event_id] = true
			fresh[#fresh + 1] = env
		end
	end
	if #fresh == 0 then
		return true
	end
	local combined = {}
	for i = 1, #self.spool_record do
		combined[#combined + 1] = self.spool_record[i]
	end
	for i = 1, #fresh do
		combined[#combined + 1] = fresh[i]
	end
	if not self:write_spool_record(combined) then
		return false
	end
	-- Cap eviction may have discarded some of THESE envelopes: the caps evict
	-- oldest-first across the whole record, and once the older entries are
	-- gone the eviction reaches into the batch being appended. Evicting OLDER
	-- entries to make room is the documented FIFO; but an envelope from the
	-- CURRENT batch that did not survive into the saved record was NOT
	-- captured — count only survivors and report failure so a
	-- durability-dependent caller (shutdown/persist) does not claim the whole
	-- remnant is safe on disk.
	local survivors = 0
	for i = 1, #fresh do
		if self.spool_index[fresh[i].event_id] then
			survivors = survivors + 1
		end
	end
	self.stats.spooled = self.stats.spooled + survivors
	return survivors == #fresh
end

-- Ack-based removal: once the server acknowledged a batch (2xx) — or the batch
-- was terminally rejected — its envelopes leave the persisted spool, keyed by
-- their stable event_id. Returns how many entries the batch settled.
function Client:clear_spooled_batch(events)
	if next(self.spool_index) == nil then
		return 0
	end
	local payload = events.payload
	local sent = payload and payload.events or nil
	if type(sent) ~= "table" then
		return 0
	end
	local remove = nil
	local count = 0
	for i = 1, #sent do
		local env = sent[i]
		local event_id = type(env) == "table" and env.event_id or nil
		if event_id and self.spool_index[event_id] then
			remove = remove or {}
			remove[event_id] = true
			count = count + 1
		end
	end
	if not remove then
		return 0
	end
	-- Mark the entries settled, then rewrite the record without them. When
	-- the rewrite fails, the mirror keeps the entries and the removal stays
	-- pending: it is retried at the next dispatch point (and any later
	-- successful write settles it via write_spool_record's filter), so the
	-- disk converges as soon as storage recovers. Should the app relaunch
	-- first, the re-sent envelopes are de-duplicated by the ingest service on
	-- their event_id — but convergence does not depend on that: the retried
	-- rewrite is what removes them.
	for event_id in pairs(remove) do
		self.spool_settled[event_id] = true
	end
	self:write_spool_record(self.spool_record)
	return count
end

-- Persist every not-yet-acknowledged envelope: the retained/in-flight batch
-- and the queued events. (Loaded spool chunks are already persisted; the
-- append de-duplicates by event_id either way.) Returns true only when the
-- whole undelivered remnant is DURABLY recorded — a memory-only fallback
-- write or a remnant partially evicted by the caps does not qualify.
function Client:spool_undelivered()
	if not self.config.spool_enabled or self.consent_state ~= "granted" then
		return false
	end
	-- The in-memory fallback (hosts without the save-file API) keeps the
	-- in-process spool behavior working, but it dies with the process: a
	-- teardown or snapshot must never report those events as safe on disk.
	if not storage.spool_is_durable(self.config) then
		return false
	end
	local envelopes = {}
	if self.in_flight_batch then
		local payload = self:ensure_batch_payload(self.in_flight_batch)
		for i = 1, #payload.events do
			envelopes[#envelopes + 1] = payload.events[i]
		end
	end
	for i = 1, #self.queue.items do
		envelopes[#envelopes + 1] = envelope.build(self.config, self, self.queue.items[i])
	end
	return self:spool_envelopes(envelopes)
end

-- Snapshot every undelivered event into the durable spool while the client
-- keeps running — intended for a host window focus-lost/iconify listener, so
-- an app kill right after cannot lose the tail. Nothing is sent here, and the
-- events stay queued for normal delivery; a later acknowledged publish removes
-- its entries from the spool (ack-based, keyed by event_id).
function Client:persist()
	if not self.initialized then
		return false, "shutdown"
	end
	-- An owed durable consent-outbox write shares the snapshot moment: persist
	-- is the host's "the app may die now" signal, and the consent outbox is
	-- independent of event spooling — so this retry runs BEFORE the
	-- spool-disabled return below, or a spool-less configuration could never
	-- recover a failed receipt write from its focus-loss listener.
	-- Best-effort — the persist result stays about the EVENT snapshot.
	self:retry_consent_outbox_persist()
	if not self.config.spool_enabled then
		return false, "spool_disabled"
	end
	-- A pending denied/disabled purge takes priority over any snapshot: retry
	-- it, and report it while the spool stays fail-closed.
	if self.spool_purge_pending and not self:retry_spool_purge() then
		return false, "spool_purge_failed"
	end
	if self.consent_state ~= "granted" then
		-- A consent-blocked client leaves nothing spoolable: denied already
		-- cleared the queue (and the spool stays purged), and a consent-first
		-- "unknown" client never queued anything to capture.
		return true
	end
	if not self:spool_undelivered() then
		return false, "spool_persist_failed"
	end
	return true
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
	self:ensure_batch_payload(events)
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
			-- The server accepted a batch, so any stored backpressure window
			-- is over too: the next durable write drops it from the record.
			self.publish_retry_after_ms = nil
			self.publish_backoff_attempt = 0
			self.spool_retry_after_ms = nil
			-- A 202 is NOT full per-event success: parse the body so observed /
			-- rejected / suppressed_no_consent outcomes are surfaced instead of
			-- silently counted as accepted. Duplicates are terminal; the batch
			-- is cleared here either way and never re-sent.
			local body = type(response) == "table" and response.response or nil
			self:apply_batch_response(body, batch_count)
			if events.spool_origin then
				self.stats.spool_resent = self.stats.spool_resent + batch_count
			end
			-- Ack-based spool removal: the server owns these events now, so
			-- any persisted copies (a spooled re-send, a transiently failed
			-- batch, or a persist() snapshot) leave the durable record.
			self:clear_spooled_batch(events)
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
		local retain = is_retryable_publish_failure(err, unauthorized, retryable, mode_b)
			and not consent_denied_state(self.consent_state)
		if unauthorized then
			self.token = nil
			self.token_expires_at_ms = nil
		-- Defer the next publish ONLY for a retained batch. Deferring for a batch
		-- about to be dropped (denied meanwhile) would leave a stale deadline that
		-- blocks a later granted batch for the whole Retry-After/backoff window
		-- (up to the 24h clamp). A 401 is never deferred (handled above).
		elseif retain and retry_after and retry_after > 0 then
			defer_publish(self, retry_after)
			-- A server-requested delay survives a relaunch: remember the
			-- (clamped) deadline so the spool write below stores it and a
			-- startup resend waits out the remaining window.
			self.spool_retry_after_ms = self.publish_retry_after_ms
		elseif retain and is_retryable_publish_failure(err, unauthorized, retryable, mode_b) then
			self:defer_backoff()
		end
		if retain then
			-- Durably spool a transiently failed batch (appended once — the
			-- event_id index de-duplicates repeats) so an app kill before the
			-- in-process retry succeeds cannot lose it. Permanent rejects are
			-- NEVER spooled: they would fail forever on every later launch.
			self:spool_envelopes(events.payload.events)
			-- The append is a no-op when every envelope is already persisted
			-- (a spooled re-send failing again); an extended server-requested
			-- deadline must still reach the record.
			if self.spool_retry_after_ms and #self.spool_record > 0
				and self.spool_retry_after_ms ~= self.spool_disk_deadline_ms then
				self:write_spool_record(self.spool_record)
			end
		end
		if not retain and self.in_flight_batch == events then
			self.stats.dropped = self.stats.dropped + batch_count
			self.in_flight_batch = nil
			-- A terminally rejected batch also leaves the spool, or it would
			-- be re-sent (and re-rejected) on every later launch. Surfaced via
			-- diagnostics so the drop of durable entries is observable.
			local removed = self:clear_spooled_batch(events)
			if removed > 0 then
				self:diagnose({
					scope = "spool",
					status = "dropped",
					code = err,
					count = removed,
				})
			end
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
	-- Retry deferred durable-spool work first — before any other spool
	-- operation: a failed denied/disabled purge keeps the spool fail-closed
	-- until it lands, and a failed ack-removal rewrite must settle as soon as
	-- storage recovers. Both ride the flush cadence (update-driven).
	self:retry_spool_purge()
	self:retry_spool_rewrite()
	-- Retained consent receipts (the durable outbox) ride the same dispatch
	-- cadence as queued events and are handed to the transport strictly
	-- BEFORE this cycle's event batch; their outcome never affects the flush
	-- result. The order is load-bearing on strict-enforce workspaces
	-- (GAP-041): dispatching the receipt first shrinks the window in which a
	-- post-grant batch reaches the server before the grant's /v1/consent row
	-- exists and is terminally suppressed (per-event suppressed_no_consent).
	-- Sequencing only — the batch never waits on the receipt's
	-- acknowledgment.
	self:try_send_consent_outbox()
	if options.include_summaries ~= false then
		self:enqueue_summaries()
	end
	self.flush_elapsed_seconds = 0
	if self.publish_in_flight then
		if self.in_flight_batch or queue.size(self.queue) > 0 or self:spool_pending() then
			return false, "pending"
		end
		return true
	end

	-- Strict-enforce hardening (audit 3a follow-up): the event-batch leg of
	-- this flush is held while the outbox retains an analytics GRANT receipt
	-- that has not yet been HANDED TO THE TRANSPORT (the dispatch above may
	-- have started only the head, and http.request is asynchronous — a grant
	-- parked behind a deferral/backoff window, queued behind another
	-- receipt, or awaiting its first post-relaunch dispatch has not been
	-- handed over yet). Publishing meanwhile would invert the
	-- receipt-before-batch ordering and hand a strict-enforce workspace
	-- post-grant events with no consent row to admit them (terminal
	-- suppressed_no_consent). The condition is dispatch, NOT acknowledgment
	-- (the rejected ack-gating variant): a grant in flight releases the gate
	-- with its response still pending. The gate only fires when there ARE
	-- events to hold: an empty pipeline must keep returning success so a
	-- durably-retained undispatched receipt alone never blocks teardown
	-- (shutdown's outbox-durability contract).
	if self:grant_receipt_pending_dispatch()
		and (self.in_flight_batch ~= nil or queue.size(self.queue) > 0 or self:spool_pending()) then
		return false, "consent_receipt_pending"
	end

	while true do
		local token_ready = false
		if not self.in_flight_batch then
			local resend_spool = self:spool_pending()
			if not resend_spool and queue.size(self.queue) == 0 then
				return true
			end
			if not self:can_publish() then
				return false
			end
			token_ready = true
			if resend_spool then
				-- Envelopes spooled by an earlier launch re-send BEFORE the
				-- fresh queue drains, through the same token/consent/deferral
				-- gates. The payload is the persisted envelopes verbatim —
				-- never rebuilt — so event_id/event_ts survive the round trip.
				local chunk = table.remove(self.spool_batches, 1)
				local batch = { spool_origin = true, payload = { events = chunk } }
				for i = 1, #chunk do
					batch[i] = chunk[i]
				end
				self.in_flight_batch = batch
			else
				self.in_flight_batch = queue.drain(self.queue, self.config.batch_size)
			end
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
	-- One more chance for an owed denied/disabled purge to land before
	-- teardown (flush below retries it too; a still-failing purge is re-run
	-- at the next launch by the persisted denial/disabled configuration).
	self:retry_spool_purge()
	local suppress_wire = self.consent_state ~= "granted"
	if self.session_active then
		-- session_end completes the local teardown even while consent is
		-- denied or unknown (the wire event is suppressed inside session_end);
		-- summary events are suppressed below via include_summaries.
		local session_ok, session_err = self:session_end(reason or "app_final")
		if not session_ok then
			return false, session_err
		end
	end
	local ok, err = self:flush({ include_summaries = not suppress_wire })
	if not ok then
		-- The final flush could not deliver everything. When the durable spool
		-- captures the whole undelivered remnant, teardown completes anyway:
		-- the envelopes are safe on disk and re-send on the next launch, so a
		-- host retry loop is no longer needed for events. With the spool
		-- disabled (or the remnant not durably saved) the old contract holds:
		-- report the failure and stay alive for a host retry.
		--
		-- A terminal rejection during the final flush DROPS the batch: there
		-- is no remnant left, and a vacuously "successful" capture of nothing
		-- must not upgrade that failure to a clean teardown. Surface the old
		-- (false, err) contract instead; a repeated shutdown() call then
		-- completes normally — the queue is already clean — exactly as before
		-- the spool existed. Pending spool chunks count as a remnant: they
		-- are already durably persisted, so finalizing over them is safe.
		local has_remnant = self.in_flight_batch ~= nil
			or queue.size(self.queue) > 0 or self:spool_pending()
		if not has_remnant or not self:spool_undelivered() then
			return false, err
		end
	end
	if self:consent_outbox_pending() then
		-- Undelivered consent receipts behave like the event spool at
		-- teardown: when every retained receipt is durably on disk, the
		-- client tears down — the receipts survive the process and re-send at
		-- the next launch (that durability is the outbox's whole point).
		-- Without a durable backend, or while the durable write itself is
		-- still owed, the old contract holds: report consent_pending and stay
		-- alive so the host can retry shutdown once a token or storage
		-- recovers, instead of silently dropping a decision at teardown.
		self:retry_consent_outbox_persist()
		if self.consent_outbox_dirty or not storage.consent_outbox_is_durable(self.config) then
			return false, "consent_pending"
		end
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
