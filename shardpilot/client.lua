local envelope = require "shardpilot.envelope"
local clock = require "shardpilot.clock"
local experiments_mod = require "shardpilot.experiments"
local id = require "shardpilot.id"
local platform = require "shardpilot.platform"
local queue = require "shardpilot.queue"
local remote_config_mod = require "shardpilot.remote_config"
local sampling = require "shardpilot.sampling"
local schema_revision_mod = require "shardpilot.schema_revision"
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

-- Host-supplied identifiers (user_id / anonymous_id — and therefore every
-- consent receipt's actor_identifier and anonymous_id snapshot, which copy
-- them) are accepted only up to this many bytes. The bound is a persistence
-- budget, not a format rule: identifiers land VERBATIM in durable records
-- written through Defold's save-file API — the identity record, and up to
-- 32 retained consent receipts whose outbox deliberately has no byte budget
-- or failed-write eviction of its own — and the engine caps a saved record
-- at 512 KB, so before this clamp a few oversized identifiers could
-- persistently fail those writes and wedge shutdown() in consent_pending.
-- At 512 bytes the worst-case outbox (32 receipts x two clamped identifiers
-- plus the fixed receipt fields) stays around ~46 KB, far under the cap and
-- in line with the storage layer's other working budgets
-- (max_spool_file_bytes, max_pending_total_bytes = 384 KB), while staying
-- generous for real identifiers: UUIDs are 36 bytes, emails at most 254,
-- opaque backend tokens a few hundred. Oversized input is REJECTED (same
-- surface as empty/non-string identity), never truncated — truncation could
-- collide distinct identities and mis-attribute events or consent decisions.
-- The bound is defined once, in the storage layer next to the other
-- persistence budgets: storage's outbox sanitizer enforces it on records
-- written before the clamp existed (legacy oversized receipts are dropped at
-- load), and this acceptance gate keeps new identifiers inside it.
local max_identifier_bytes = storage.max_identifier_bytes

local function valid_identity(value)
	return type(value) == "string" and value ~= "" and #value <= max_identifier_bytes
end

-- Both explicit denial flavors close the analytics pipeline identically. The
-- forced-minor state exists so an age-gate-forced denial is distinguishable
-- ON ITS RECEIPT (reason = "denied_forced_minor") from a denial the player
-- chose; every analytics gate treats the two as the same denied state.
local function consent_denied_state(state)
	return state == "denied" or state == "denied_forced_minor"
end

-- Canonical-actor selection for consent receipts (ADR-0222 §1, the ADR-0202
-- 2026-07-20 amendment), mirroring how the event plane binds identity in
-- Mode B: a host-supplied user_id is an identity the SDK can stand behind
-- only when a Mode B token_provider backs the session — the per-tenant JWT
-- the host mints is the credential that vouches for it. So the receipt keys
-- to the verified user identity (kind "user_verified") only under a
-- configured token_provider with an identified user; in every other case —
-- Mode A, or a Mode B decision made before identify() — it keys to the
-- SDK-managed anonymous_id with kind "anon". A Mode A self-asserted user_id
-- is NEVER the receipt actor (that class is spoofable by any caller, and
-- the publishable-key ingress binds the write to the caller's own anon
-- scope regardless — a user-keyed receipt could misrecord the decision
-- under an actor the server never consults). This deliberately supersedes
-- the v0.9.1 user-first snapshot. Returns actor_identifier, kind — the
-- only kinds the SDK ever produces are "anon" and "user_verified", never
-- "user_unverified".
local function receipt_actor(client)
	if client.config.token_provider and valid_identity(client.user_id) then
		return client.user_id, "user_verified"
	end
	return client.anonymous_id, "anon"
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
	-- Experiments (dark by default): `experiments_enabled = true` opts into
	-- the assignment consumer. The assignment endpoint lives on the same
	-- control-plane host as the remote-config fetch and authenticates with
	-- the same publishable api_key, so the flag requires `remote_config_url`
	-- (which in turn requires the api_key). Default false — and while false,
	-- zero experiment code paths execute.
	if config.experiments_enabled ~= nil and type(config.experiments_enabled) ~= "boolean" then
		return nil, "invalid_experiments_enabled"
	end
	local experiments_enabled = config.experiments_enabled == true
	if experiments_enabled and not has_remote_config then
		return nil, "experiments_requires_remote_config_url"
	end
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
	-- Schema-revision declaration (GAP-036). Default (nil): every
	-- events:batch request declares the SDK's built-in schema-set revision
	-- (shardpilot/schema_revision.lua) in the X-ShardPilot-Schema-Revision
	-- request header. A non-empty string overrides the declared value (e.g.
	-- matched to a self-hosted analytics-service build); `false` or `""`
	-- stops declaring entirely — the escape hatch the server contract
	-- documents: an undeclared batch always passes the server's check, in
	-- every handshake mode. The header rides only on batches, and only ones
	-- that already passed the consent gate — declaring is orthogonal to the
	-- consent-first semantics.
	local declared_schema_revision
	if config.schema_revision == nil then
		declared_schema_revision = schema_revision_mod.REVISION
	elseif config.schema_revision == false or config.schema_revision == "" then
		declared_schema_revision = nil
	elseif type(config.schema_revision) == "string" then
		declared_schema_revision = config.schema_revision
	else
		return nil, "invalid_schema_revision"
	end
	-- Consent-receipt `kind` emission (ADR-0202 2026-07-20 amendment).
	-- Default (nil/true): every `POST /v1/consent` body carries the
	-- receipt's stored actor class next to `actor_identifier`. `false` is
	-- the escape hatch for a deployment whose ingest service still runs the
	-- pre-amendment `INGEST_CONSENT_KIND_MODE=off` strict decoder, which
	-- 400-rejects a kind-bearing body as an unknown field — a terminal
	-- outcome that would drop the receipt, denials included. Suppression is
	-- wire-build-time only: the kind is always chosen, persisted with the
	-- receipt, and used for dispatch-credential selection.
	if config.consent_kind_emission_enabled ~= nil
		and type(config.consent_kind_emission_enabled) ~= "boolean" then
		return nil, "invalid_consent_kind_emission_enabled"
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
		schema_revision = declared_schema_revision,
		consent_kind_emission_enabled = config.consent_kind_emission_enabled ~= false,
		platform = config.platform or platform.detect(),
		transport = config.transport,
		token_provider = config.token_provider,
		api_key = has_api_key and config.api_key or nil,
		experiments_enabled = experiments_enabled,
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
	-- A configured anonymous_id override that REPLACES a different valid
	-- persisted actor boots a FRESH IDENTITY: the persisted consent decision
	-- belongs to the actor that made it and is never applied to the new one.
	-- Restoring it would launder consent across actors — the new actor would
	-- boot "granted" without ever deciding, load the old actor's spool, and
	-- the identity rewrite below would durably re-record the old actor's
	-- decision under the new id. A MATCHING override restores unchanged.
	local override_replaced_actor = false
	if valid_identity(config.anonymous_id) then
		anonymous_id = config.anonymous_id
		override_replaced_actor = valid_identity(stored.anonymous_id)
			and stored.anonymous_id ~= config.anonymous_id
	elseif valid_identity(stored.anonymous_id) then
		anonymous_id = stored.anonymous_id
	else
		anonymous_id = id.uuid_v7()
	end
	local consent_state = "unknown"
	if not override_replaced_actor
		and (stored.consent_analytics == "granted" or consent_denied_state(stored.consent_analytics)) then
		-- The persisted decision is restored only for the actor that made it
		-- (no override, a matching override, or a freshly minted/self-healed
		-- anon inheriting this install's record). On an override mismatch the
		-- new actor starts "unknown": the untouched-on-disk decision is
		-- ignored, the identity rewrite below persists the override WITHOUT a
		-- consent key (persist_identity writes one only for explicit states),
		-- and the "unknown" state routes init through the non-granted spool
		-- purge — the old actor's envelopes never load for the new actor, and
		-- a failed purge fails closed exactly like every other non-granted
		-- init (spool_purge_pending). Retained consent RECEIPTS are not
		-- consent state and keep their own load rules below: they document
		-- the OLD actor's decisions and still deliver (or drop/park) under
		-- the per-receipt credential rules.
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
		-- Identity epoch for Mode B mints: bumped when identify() changes the
		-- user, so a mint still in flight for the PREVIOUS session discards
		-- its result instead of installing a token that cannot vouch for the
		-- current one (refresh_token fences its callback on this).
		token_epoch = 0,
		in_flight_batch = nil,
		-- Set when a sentinel fact purge finds a publish mid-flight: the
		-- batch on the wire is past recall, but if it fails and is
		-- retained, the settle path filters the withdrawn facts before any
		-- retry or spool capture.
		experiment_purge_awaited = false,
		-- Set while CONDEMNED experiment facts remain on the durable spool
		-- because their removal write failed (the sentinel purge's rewrite,
		-- or the relaunch condemnation filter): durable work still owed.
		-- The condemnation marker's retire check consults this — the
		-- marker must outlive the stale file, or the launch after next
		-- replays the withdrawn keys. Cleared by any successful spool
		-- write (the whole file is rewritten from the filtered state).
		condemned_spool_pending = false,
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
		-- plane's publish deferral. While a dispatch is in flight,
		-- consent_in_flight_key holds that receipt's idempotency_key (parked
		-- receipts are skipped, so the in-flight receipt is not always the
		-- head — the grant-dispatch gate releases by key identity).
		consent_outbox = {},
		consent_outbox_dirty = false,
		consent_send_in_flight = false,
		consent_in_flight_key = nil,
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
	-- The experiments subject id is loaded BEFORE any identity rewrite below:
	-- persist_identity carries it forward, so a rewrite triggered by a
	-- changed anonymous id can never drop a previously minted id (dropping
	-- would silently re-bucket the subject on a later re-enable). Loaded
	-- regardless of the experiments flag — but VALIDATED, never verbatim: a
	-- grammar-invalid or oversized stored value would otherwise ride every
	-- later identity write (consent saves included, even with experiments
	-- off), and an oversized one could permanently fail those unrelated
	-- writes. Invalid reads as absent — the consumer mints a fresh subject
	-- at first need, exactly like any other corrupt identity field.
	client.experiments_client_id = experiments_mod.valid_subject_id(
			stored.experiments_client_id)
		and stored.experiments_client_id or nil
	if stored.anonymous_id ~= anonymous_id then
		client:persist_identity()
	end
	if override_replaced_actor then
		-- Surface the fresh-identity reset: the persisted decision was NOT
		-- carried over to the overriding actor (distinct from the load-time
		-- "identity_changed" receipt/spool drops — nothing here was sent or
		-- deleted, the old decision simply does not apply to the new actor).
		client:diagnose({
			scope = "consent",
			status = "dropped",
			code = "identity_override_changed",
		})
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
	-- Experiment-assignment consumer (dark unless `experiments_enabled`).
	-- Constructed only when the flag is on — while off there is no subject-id
	-- mint, no fetch, no revalidation, no exposure and no new persistence
	-- keys. The subject id is SDK-managed: it is loaded from the identity
	-- record above (never from config — no host override path exists),
	-- minted lazily by the consumer at first need, and persisted through
	-- persist_identity. Experiment facts are enqueued through the normal
	-- analytics pipeline with the envelope identity rules the facts contract
	-- requires (no user_id; the standard anonymous_id — never the
	-- experiments subject id).
	if normalized.experiments_enabled then
		client.experiments = experiments_mod.new(normalized, {
			subject_id = function()
				if not experiments_mod.valid_subject_id(client.experiments_client_id) then
					-- No USABLE captured subject — nil, or a stored value
					-- that fails the wire grammar. Either way a sibling
					-- client in this process may have minted (or healed)
					-- AND persisted a valid subject since this client
					-- captured its copy: re-read the identity record at
					-- mint-decision time and adopt it — one install
					-- converges on ONE subject id (and one cache scope)
					-- instead of the second client re-minting over the
					-- sibling's. Gating on VALIDITY, not nilness, matters:
					-- a captured corrupt string must not block the reload
					-- while the consumer treats it as absent and mints. A
					-- raw field copy (the consumer validates the grammar);
					-- a sibling whose mint could not persist stays
					-- process-local by the documented failed-persist rule,
					-- so there is nothing on disk to adopt in that case.
					local persisted = storage.load(normalized) or {}
					-- Adopt only a VALID sibling value: copying a corrupt
					-- or oversized field would poison this client's
					-- identity writes the same way the init-time load
					-- guard prevents.
					if experiments_mod.valid_subject_id(persisted.experiments_client_id) then
						client.experiments_client_id = persisted.experiments_client_id
					end
				end
				return client.experiments_client_id
			end,
			store_subject_id = function(value)
				client.experiments_client_id = value
				return client:persist_identity()
			end,
			consent = function()
				return client.consent_state
			end,
			analytics_session = function()
				return client.session_id
			end,
			analytics_anonymous_id = function()
				return client.anonymous_id
			end,
			emit = function(event_name, props, event_id, overrides)
				-- `overrides` is the ARM-TIME identity of an owed fact
				-- (an exposure drained late must ride the session, the
				-- anonymous id, and the timestamp of the moment its
				-- treatment applied — not the current ones); absent
				-- fields mean "current".
				overrides = overrides or {}
				return client:enqueue_event(event_name, props, nil, {
					event_id = event_id,
					omit_user_id = true,
					session_id = overrides.session_id,
					anonymous_id = overrides.anonymous_id,
					event_ts = overrides.event_ts,
					retryable = overrides.retryable,
				})
			end,
			purge_facts = function()
				-- The real-subjects sentinel withdrew the assignments AND
				-- their subject-fact keys: experiment facts already
				-- accepted into the analytics pipeline carry those keys
				-- verbatim and must not egress on a later flush.
				return client:purge_experiment_facts()
			end,
			capture_fact = function(event_name, props, event_id, overrides)
				-- Drop-time durable capture: a durable entry delete with
				-- an exposure still owed must not let a process kill lose
				-- the fact — the spool copy replays it at the next launch.
				return client:capture_experiment_fact(
					event_name, props, event_id, overrides)
			end,
			spool_condemned_pending = function()
				-- Condemned facts still on the durable spool (a removal
				-- write that could not land): the condemnation marker
				-- must not retire over them.
				return client.condemned_spool_pending == true
			end,
		})
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
		local spooled, stored_deadline, spool_miss = storage.load_spool(normalized)
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
		local condemned = 0
		local condemnation_covers = false
		local condemnation_stamp_iso = nil
		if #spooled > 0 or spool_miss == "unreadable" then
			if client.experiments then
				condemnation_covers =
					client.experiments:condemnation_covers_current_scope()
				if condemnation_covers then
					condemnation_stamp_iso =
						client.experiments:condemnation_stamp_iso()
				end
			else
				-- Experiments DISABLED (the dark default, or a rollback
				-- launch after an enabled run): the consumer is not
				-- constructed, but the SPOOL is still live — and a prior
				-- enabled run's real-subjects condemnation may still be
				-- armed. A sentinel + failed spool rewrite + death leaves
				-- the sidecar marker as the ONLY guard against replaying
				-- the withdrawn subject-fact keys, so the marker is
				-- honored INDEPENDENTLY of the flag: the sidecar file is
				-- read directly, and with no subject/scope machinery
				-- constructed to disprove it, it condemns conservatively —
				-- the same fail-closed rule the consumer applies when its
				-- comparator goes blind. The marker is deliberately NEVER
				-- retired here: retiring requires proving the covered
				-- record AND spool durably clean, which only the full
				-- machinery can do — a marker whose facts are all
				-- post-stamp condemns nothing below and retires in the
				-- next ENABLED launch's first tick.
				local marker_stamp, _, marker_miss =
					storage.load_experiments_clear(normalized)
				if marker_stamp then
					condemnation_covers = true
					condemnation_stamp_iso = clock.iso_utc(marker_stamp)
				elseif marker_miss == "unreadable" then
					-- The sidecar READ failed: an armed condemnation may
					-- sit in the unreadable file. Fail closed exactly like
					-- the consumer's unknown-form marker — condemn with no
					-- stamp, which blanket-filters the experiment facts
					-- below (no partition is possible without the stamp).
					condemnation_covers = true
				end
			end
		end
		if spool_miss == "unreadable" and condemnation_covers then
			-- The spool READ failed while a condemnation is armed: spool
			-- cleanliness is UNPROVEN, not clean — the unreadable file may
			-- still hold pre-sentinel facts carrying withdrawn subject-fact
			-- keys, and nothing was filtered or rewritten this launch.
			-- Record the debt so the marker cannot retire on this launch's
			-- evidence (the retire chokepoint consults this flag); any
			-- later successful whole-file spool write proves cleanliness
			-- and clears it, and an unhealed file simply leaves the marker
			-- armed for the next launch's readable pass.
			client.condemned_spool_pending = true
		end
		if condemnation_covers then
			-- A real-subjects condemnation survived the exit (the sentinel's
			-- clear or its sidecar marker is still armed) AND covers the
			-- current scope: spooled experiment facts carrying the withdrawn
			-- subject-fact keys — a sentinel purge's failed spool rewrite
			-- followed by a process death leaves them here — must not
			-- re-send. The drop is PARTITIONED by the marker's own stamp,
			-- the record partition's dispatch-bound rule extended to the
			-- spool: a fact whose event_ts is STRICTLY AFTER the stamp
			-- postdates the sentinel's authority (a flip-back re-exposure
			-- captured before the exit) and SURVIVES; a fact at/before it
			-- is what the sentinel withdrew and drops. A marker whose
			-- in-scope facts are ALL post-stamp therefore condemns nothing
			-- — the settled-but-unretired sidecar case — and retires on
			-- the first tick instead of eating fresh facts. A stale marker
			-- from a retired environment/credential/subject never reaches
			-- this branch at all (fail-closed when nothing can disprove it:
			-- a blind consumer comparator, or no consumer at all).
			local stamp_iso = condemnation_stamp_iso
			local kept = {}
			for i = 1, #spooled do
				local env = spooled[i]
				local name = env.event_name
				local is_fact = name == "experiment_exposure"
					or name == "experiment_outcome"
				-- The boundary is biased to SURVIVE: envelope timestamps
				-- are second-granular while the marker stamp is
				-- milliseconds, so a fact captured in the SAME UTC second
				-- as the sentinel compares EQUAL — dropping it would eat a
				-- legitimate post-sentinel fact. Equal-or-after survives;
				-- the residual is the mirror-image ≤1s window in which a
				-- pre-sentinel fact shares the sentinel's second and
				-- escapes the drop — accepted and documented (the fact was
				-- real treatment reporting; the deterministic id keeps it
				-- collapsible server-side).
				if is_fact and not (stamp_iso ~= nil
					and type(env.event_ts) == "string"
					and env.event_ts >= stamp_iso) then
					condemned = condemned + 1
				else
					kept[#kept + 1] = env
				end
			end
			if condemned > 0 then
				spooled = kept
				client:diagnose({
					scope = "spool",
					status = "dropped",
					code = "experiments_condemned",
					count = condemned,
				})
			end
		end
		if #spooled > 0 or mismatched > 0 or condemned > 0 then
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
			elseif condemned > 0 then
				-- The CONDEMNATION could not land durably: the stale file
				-- still carries the withdrawn facts, and with everything
				-- condemned there may be nothing left to resend/ack that
				-- would ever rewrite it. This is durable work — record the
				-- debt so the rewrite retries at every dispatch point, and
				-- so the condemnation marker stays alive (the retire check
				-- consults it) until the file is actually clean; a retired
				-- marker over a stale file would replay the withdrawn keys
				-- at the launch after next.
				client.spool_rewrite_pending = true
				client.condemned_spool_pending = true
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
	if normalized.token_provider and not normalized.api_key
		and #client.consent_outbox > 0 then
		-- The narrow could-never-send anti-wedge drop, scoped to the ONE
		-- configuration where it is true: Mode B with no publishable key.
		-- Mode B tokens are minted bound to the CURRENT anonymous ID, so an
		-- ANON-keyed receipt whose decision-time anon snapshot no longer
		-- matches would pair the old actor with a token bound to the new
		-- anon and be rejected on every retry — a wedged head that blocks
		-- the rest of the trail forever. Drop exactly those at load —
		-- deterministic, surfaced via diagnostics — like the event spool's
		-- identity_changed rule above. The same rule covers the ACTOR
		-- itself: with no publishable key the minted token is the only
		-- credential, and it vouches solely for the current anon (or a
		-- user_verified receipt's verified user) — an anon-KIND receipt
		-- whose actor_identifier is NOT the current anon (a legacy pre-kind
		-- entry that stored v0.9.1's user-first actor and backfilled to
		-- anon, its anon snapshot still current) has no credential that
		-- could ever lawfully carry it: dispatched under the token it would
		-- be terminally rejected on the actor/subject mismatch or land the
		-- decision under the wrong actor, and retained it would hold
		-- set_anonymous_id's rotation guard in events_pending for as long
		-- as it sat anon-keyed in the outbox. With a publishable api_key
		-- configured (Mode A, or Mode B + api_key), anon-keyed receipts
		-- dispatch under the key instead — the historic actor is the
		-- correct subject of those decisions — so nothing is dropped there.
		-- And a user_verified-keyed receipt is NEVER dropped for a
		-- merely-absent identity: it may be the only record of that actor's
		-- consent change (worst case an undelivered withdrawal), so it
		-- parks instead (receipt_parked) until a Mode B session vouches for
		-- its actor.
		local kept_receipts = {}
		local mismatched_receipts = 0
		for i = 1, #client.consent_outbox do
			local receipt = client.consent_outbox[i]
			if receipt.kind == "user_verified"
				or (receipt.anonymous_id == client.anonymous_id
					and receipt.actor_identifier == client.anonymous_id) then
				kept_receipts[#kept_receipts + 1] = receipt
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
	-- The experiments subject id rides the identity record whenever one is
	-- held — including when the experiments flag is currently off — so an
	-- identity rewrite can never drop a previously minted id (dropping would
	-- silently re-bucket the subject on a later re-enable).
	if type(self.experiments_client_id) == "string" and self.experiments_client_id ~= "" then
		record.experiments_client_id = self.experiments_client_id
	end
	return storage.save(self.config, record)
end

-- True while undrained event work — queued, in an in-flight batch, or
-- reloaded on the durable spool — carries a USER identity snapshot other
-- than `user_id`. Events snapshot the identity in force at enqueue time
-- (and spooled envelopes re-send verbatim), so this is exactly the work a
-- credential minted after identifying as `user_id` could not vouch for: a
-- flush after the switch would ship the previous user's events under the
-- new user's Bearer — the event-plane twin of the consent actor/subject
-- mismatch. Anon-snapshotted work (a nil user snapshot: pre-identify
-- events, and facts under the omit_user_id contract) never counts — the
-- mint binds the CURRENT anon as bind_anon regardless of the verified
-- subject, so those envelopes stay vouched for across an identify. Spool
-- entries already settled (delivered or terminally rejected, awaiting only
-- their removal rewrite) can never re-send, so they never count either.
function Client:user_events_pending_for_other(user_id)
	for i = 1, #self.queue.items do
		local snapshot = self.queue.items[i].user_id
		if snapshot ~= nil and snapshot ~= user_id then
			return true
		end
	end
	if self.in_flight_batch then
		for i = 1, #self.in_flight_batch do
			local snapshot = self.in_flight_batch[i].user_id
			if snapshot ~= nil and snapshot ~= user_id then
				return true
			end
		end
	end
	for i = 1, #self.spool_record do
		local env = self.spool_record[i]
		if env.user_id ~= nil and env.user_id ~= user_id
			and not self.spool_settled[env.event_id] then
			return true
		end
	end
	return false
end

function Client:identify(user_id)
	if not valid_identity(user_id) then
		return false, "invalid_user_id"
	end
	local identity_changed = user_id ~= self.user_id
	-- A Mode B identity CHANGE is REFUSED while event work snapshotted to
	-- another verified user remains undrained (queued, in flight, or on the
	-- durable spool) — the event-plane twin of set_anonymous_id's rotation
	-- guard below, and the same pending-work refusal family. Accepting the
	-- switch would drop the cached token that vouches for that work (the
	-- invalidation below), and the next flush would mint for the NEW user
	-- and ship the previous user's events under a Bearer that cannot vouch
	-- for those envelopes — a rejected batch, or worse a misattributed one.
	-- The host flushes first, then re-identifies. Anon-snapshotted work
	-- never blocks (the mint's bind_anon vouches for it regardless of the
	-- verified subject), so the common track-then-first-identify flow is
	-- untouched — and Mode A is untouched wholesale: with no per-session
	-- credential there is nothing a switch could strand.
	if identity_changed and self.config.token_provider
		and self:user_events_pending_for_other(user_id) then
		return false, "events_pending"
	end
	self.user_id = user_id
	if identity_changed and self.config.token_provider then
		-- A cached Mode B JWT vouches for the session it was minted in — the
		-- anonymous session, or a previously identified user. Reusing it for
		-- work unlocked by THIS identity change (most immediately the parked
		-- user_verified receipt dispatch below) would send the new actor
		-- under a credential that cannot vouch for it: the consent route
		-- rejects an actor/subject mismatch terminally, dropping the receipt
		-- — a retained withdrawal included. Drop the cached token so the next
		-- dispatch mints one bound to the just-identified session (mirroring
		-- the anon-rotation token drop below), and bump the epoch so a mint
		-- already in flight discards its stale result on arrival. The
		-- pending-events refusal above guarantees the drop runs only when no
		-- other user's event work is still undrained, so it can never strand
		-- a previous user's envelopes under the next session's mint; the
		-- epoch fence keeps its own job — stale-mint protection — either way.
		self.token = nil
		self.token_expires_at_ms = nil
		self.token_epoch = self.token_epoch + 1
	end
	-- A newly presentable verified identity is a consent dispatch point: a
	-- user_verified receipt parked for exactly this actor (receipt_parked)
	-- becomes dispatchable the moment a Mode B session can vouch for it, so
	-- attempt delivery immediately instead of waiting for the next cadence.
	-- Cheap when nothing is parked for this actor: an empty or fully
	-- undispatchable outbox returns before any credential work.
	self:try_send_consent_outbox()
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
	--   * retained ANON-KEYED consent receipts (the durable outbox — including
	--     receipts reloaded from a previous launch) carry the old anon
	--     actor_identifier and survive even after the token request settles
	--     (e.g. a token_provider error leaves them queued); their retry would
	--     mint for the new anon but send the old actor. A user_verified-keyed
	--     receipt never blocks rotation: it keys to the verified user and
	--     dispatches only under a JWT vouching for that user, so the anon id
	--     never enters its dispatch — and a PARKED one can outlive its
	--     actor's session indefinitely, so blocking on it would wedge
	--     rotation for as long as that user stays signed out
	--     (consent_outbox_anon_pending; an owed durable rewrite still
	--     blocks).
	--   * spooled envelopes loaded from a previous launch carry their historic
	--     anonymous_id snapshot; re-sending them under a token minted for the
	--     NEW anon would be rejected the same way, so rotation waits until the
	--     spool has drained.
	--   * OWED experiment-exposure snapshots are pending old-anon work that
	--     sits OUTSIDE the queue: their arm-time anonymous_id enters the
	--     envelope only when the sweep finally enqueues them, so a flushed
	--     queue does not mean the old anon is drained — rotating first would
	--     send the old-anon fact under a token minted for the new anon and
	--     the bind_anon check would reject the whole batch.
	-- The host retries the rotation once the pending work clears.
	local rotating = self.config.token_provider and anonymous_id ~= self.anonymous_id
	if rotating and (queue.size(self.queue) > 0 or self.in_flight_batch ~= nil
		or self.token_request_in_flight or self:consent_outbox_anon_pending()
		or self:spool_pending()
		or (self.experiments and self.experiments:has_owed_exposures())) then
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

-- ── experiments ───────────────────────────────────────────────────────────────
--
-- Thin delegates over the experiment-assignment consumer
-- (shardpilot/experiments.lua), present only when `experiments_enabled` is
-- configured true. Unlike the remote-config fetch, the assignment plane IS
-- consent-gated (granted-only, forced-minor fully off — see the module
-- header); the getters serve nil rather than failing, so game code can ship
-- one code path with the control experience as its default.

function Client:fetch_experiment_assignment(experiment_key, attributes, callback)
	-- `attributes` is optional: (key, callback) is accepted too.
	if type(attributes) == "function" and callback == nil then
		callback = attributes
		attributes = nil
	end
	-- The callback is game code; never let it break the SDK.
	if not self.initialized then
		-- No request is dispatched on a torn-down client, nothing is
		-- written, game code is not called back later.
		if type(callback) == "function" then
			pcall(callback, { ok = false, from_cache = false, error = "shutdown" })
		end
		return false, "shutdown"
	end
	if not self.experiments then
		if type(callback) == "function" then
			pcall(callback, {
				ok = false,
				from_cache = false,
				error = "experiments_not_configured",
			})
		end
		return false, "experiments_not_configured"
	end
	return self.experiments:fetch(experiment_key, attributes, callback)
end

function Client:experiment_variant(experiment_key)
	if not self.experiments then
		return nil
	end
	return self.experiments:variant(experiment_key)
end

function Client:experiment_payload(experiment_key)
	if not self.experiments then
		return nil
	end
	return self.experiments:payload(experiment_key)
end

function Client:track_exposure(experiment_key)
	if not self.initialized then
		return false, "shutdown"
	end
	if not self.experiments then
		return false, "experiments_not_configured"
	end
	return self.experiments:track_exposure(experiment_key)
end

function Client:track_outcome(experiment_key, outcome_key, outcome_value)
	if not self.initialized then
		return false, "shutdown"
	end
	if not self.experiments then
		return false, "experiments_not_configured"
	end
	return self.experiments:track_outcome(experiment_key, outcome_key, outcome_value)
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
	local state_changed = self.consent_state ~= next_state
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
	-- GRANT-APPEND FAILS CLOSED ON A DENIAL-FULL OUTBOX: when appending this
	-- grant's receipt would overflow the cap with no pre-existing pure grant
	-- for the denial-preferring eviction to take, the loop's only candidates
	-- are denial-carrying receipts — or the just-appended grant itself.
	-- Neither is acceptable: a recorded denial is the legal record and is
	-- never traded for a grant, and a grant receipt evicted before its
	-- DISPATCH would silently open the local pipeline with no grant row ever
	-- reaching the server (the grant-dispatch gate's release condition is
	-- dispatch — on a strict-consent workspace every later batch would be
	-- terminally suppressed). So the grant is REFUSED, extending the floor's
	-- fail-closed family (a grant is refused while a spool wipe is owed,
	-- above; it is equally refused while its receipt cannot be durably
	-- retained): the state does not flip, nothing is evicted, every denial
	-- stays, and the host retries once the outbox drains below the cap.
	-- Denial appends keep the shipped eviction semantics unchanged (oldest
	-- pure grant first; an all-denials overflow evicts the oldest denial —
	-- a fresh denial outranks a stale one).
	if granted and self:consent_outbox_denial_full() then
		return false, "consent_outbox_full"
	end
	self.consent_state = next_state
	if state_changed and self.experiments then
		-- Every consent TRANSITION opens a new consent epoch: responses
		-- dispatched before it must not install their constructive half
		-- (destructive directives still land — the R22 partition). A
		-- repeated same-state call is not a transition and fences nothing.
		self.experiments.consent_epoch = self.experiments.consent_epoch + 1
	end
	if granted and self.experiments then
		-- Purge/denied-restore re-arm intents materialize AT THE GRANT:
		-- serving resumes this instant, so the replacement snapshots
		-- capture this exact moment's identity — and has_owed_exposures()
		-- reflects the owed automatic facts immediately, before any Mode B
		-- rotation can be requested in the regrant window.
		self.experiments:on_consent_granted()
	end
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
			-- An emptied durable spool proves cleanliness exactly like a
			-- whole-file write does: nothing condemned can remain in a
			-- cleared record, so the condemnation debt settles with it and
			-- the fail-closed marker may retire once the record side is
			-- clean — instead of surviving the whole process on a stale
			-- flag.
			self.condemned_spool_pending = false
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
		if self.experiments then
			-- The purge above discarded any queued-but-unpublished
			-- experiment exposure facts: re-arm this session's emissions so
			-- a later re-grant of a retained assignment emits its exposure
			-- again (already-published facts collapse server-side on their
			-- deterministic event ids) instead of under-counting treatment.
			self.experiments:on_analytics_purge()
		end
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
	if self.experiments then
		-- The exposure contract is once per (experiment, version, subject)
		-- per SESSION: an explicit session renewal re-arms it, so a
		-- still-applied assignment emits one exposure into the new session
		-- (with its own deterministic id) on the next application sweep.
		-- Whether this start is a genuine RENEWAL (any session — lazy or
		-- explicit — existed before it) decides what happens to owed
		-- pre-session exposure snapshots: the first real session adopts
		-- them; a renewal preserves them as prior sessions' facts — and
		-- stamps any still-unattributed pre-session snapshot with the
		-- PREVIOUS session's id (the lazy first session it lived through),
		-- which the renewal path needs the id itself for.
		self.experiments:on_session_renewed(
			previous_session_id ~= nil, previous_session_id)
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
	return self:enqueue_event(event_name, props, context, nil)
end

-- The shared enqueue path behind track() and the SDK-internal experiment
-- facts. `fact` (internal only — never host-supplied) carries the two
-- deviations an experiment fact needs from an ordinary event: a
-- pre-derived `event_id` (the deterministic exposure id, so at-least-once
-- retries and same-session double emissions collapse server-side) and
-- `omit_user_id` (the facts contract forbids user_id on the envelope; the
-- identity is the standard anonymous_id alone). Everything else — the
-- consent-first gates, identity requirement, lazy session, queue caps —
-- applies to facts exactly as to events.
function Client:enqueue_event(event_name, props, context, fact)
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
	local user_id = self.user_id
	local event_id = nil
	local session_override = nil
	local anonymous_override = nil
	local ts_override = nil
	if fact then
		event_id = fact.event_id
		if fact.omit_user_id then
			user_id = nil
		end
		-- An owed experiment fact enqueued LATE carries the identity of
		-- the moment its treatment applied. The full envelope audit for a
		-- late-drained fact, field by field: event_id — deterministic,
		-- derived from the arm-time snapshot; event_ts — the arm moment
		-- (overridden here); user_id — omitted by the facts contract;
		-- anonymous_id — the arm moment's (overridden here); session_id —
		-- the session the application belonged to (overridden here);
		-- props — the arm-time entry snapshot. The ONE enqueue-time field
		-- is session_sequence: it stays the enqueue-stream's counter — a
		-- documented residual, because back-numbering a foreign session's
		-- sequence would need a per-session counter registry, and the
		-- server's cross-session ordering key is the timestamp.
		if type(fact.session_id) == "string" and fact.session_id ~= "" then
			session_override = fact.session_id
		end
		if type(fact.anonymous_id) == "string" and fact.anonymous_id ~= "" then
			anonymous_override = fact.anonymous_id
		end
		if type(fact.event_ts) == "string" and fact.event_ts ~= "" then
			ts_override = fact.event_ts
		end
	end
	local event = {
		event_id = event_id or id.uuid(),
		event_name = event_name,
		event_ts = ts_override or clock.iso_utc(),
		user_id = user_id,
		anonymous_id = anonymous_override or self.anonymous_id,
		session_id = session_override or self.session_id,
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
		-- A RETRYABLE fact refusal is not a dropped event: the owed-snapshot
		-- machinery keeps the fact armed and re-enqueues it once the queue
		-- has room, so counting every full-queue sweep attempt would inflate
		-- the dropped stat with events that eventually deliver. Terminal
		-- outcomes (host events, immediate host-retried facts) still count.
		if not (fact and fact.retryable) then
			self.stats.dropped = self.stats.dropped + 1
		end
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
	if self.experiments then
		-- Revalidation cadence + the cache-restored exposure sweep. Runs
		-- before the flush check so a fact enqueued by this tick can ride
		-- this same update's flush; internally a no-op unless consent is
		-- granted and an assignment is cached.
		self.experiments:tick(dt)
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
	-- The mint is fenced to the identity epoch it was requested under: the
	-- host mints for its CURRENT session, so a callback landing after
	-- identify() changed the user would install a token vouching for the
	-- previous identity. Such a late callback still settles the in-flight
	-- flag but discards its result — the next dispatch point mints fresh.
	local epoch = self.token_epoch
	local ok, err = pcall(self.config.token_provider, function(new_token, new_expires_at, callback_error)
		self.token_request_in_flight = false
		if epoch ~= self.token_epoch then
			return
		end
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
	if error_obj.code == "schema_revision_mismatch" then
		-- Terminal by server contract (GAP-036): the declared schema
		-- revision no longer matches the schema set the ingest service
		-- serves, and retrying the same batch from the same build can never
		-- succeed (the 409 carries no Retry-After). The batch takes the
		-- normal terminal-failure path — dropped, never retried or spooled —
		-- and this log line makes the fix actionable. Discrimination is by
		-- error.code, never the bare 409 status: the other ingest 409 codes
		-- keep their existing handling. While armed, the service answers
		-- with its own revision in the same header (the real Defold http
		-- API lowercases response header keys); include it when present.
		local served
		if type(response) == "table" and type(response.headers) == "table" then
			served = response.headers["x-shardpilot-schema-revision"]
				or response.headers["X-ShardPilot-Schema-Revision"]
		end
		print("[shardpilot] schema revision mismatch: this build declares "
			.. tostring(self.config.schema_revision)
			.. (served ~= nil and (" but the ingest service serves " .. tostring(served)) or "")
			.. "; the batch is dropped (terminal, never retried)."
			.. " Update the SDK (re-sync shardpilot/schema_revision.lua)"
			.. " or stop declaring (config schema_revision = false).")
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
-- Each receipt is keyed to the canonical actor chosen at decision time
-- (receipt_actor above) and carries that actor's class as `kind`; delivery
-- selects the dispatch credential PER RECEIPT, most-vouching first — the
-- minted Mode B token whenever it vouches for the receipt's actor (current
-- verified user, or current-anon subject in the dual configuration; grants
-- stay deliverable there), the publishable api_key only for receipts the
-- token cannot vouch for (historic-anon) and in pure Mode A.
-- user_verified-keyed receipts dispatch only under a Mode B minted token,
-- never a publishable fallback: the route binds the actor to the token
-- subject, and a publishable-key dispatch would rebind or reject the write. A
-- user_verified receipt whose actor the current session cannot vouch for
-- PARKS (receipt_parked below) rather than dropping or dispatching wrong.

-- True while any consent-receipt state is still unsettled: a receipt awaiting
-- server acknowledgment (including receipts reloaded from a previous launch),
-- OR an owed durable rewrite. The dirty case matters even with an empty
-- mirror — a failed post-delivery prune leaves the acknowledged receipt on
-- disk, where the next launch reloads and re-sends it — so teardown's
-- consent_pending contract and the anon-rotation guard both wait for that
-- rewrite (the guard through consent_outbox_anon_pending below).
function Client:consent_outbox_pending()
	return #self.consent_outbox > 0 or self.consent_outbox_dirty
end

-- The anon-rotation guard's view of the outbox: only work BOUND TO THE OLD
-- ANON blocks a rotation. That is every ANON-KEYED retained receipt (its
-- actor IS the old anon — a post-rotation retry would mint for the new anon
-- and send the old actor) and any owed durable rewrite (a stale on-disk
-- record could replay an old-anon receipt on the next launch). A
-- user_verified-keyed receipt never blocks: it keys to the verified user,
-- dispatches only under a JWT vouching for that user, and survives anon
-- changes by design — a PARKED one (its actor signed out) could otherwise
-- hold set_anonymous_id in events_pending indefinitely.
function Client:consent_outbox_anon_pending()
	if self.consent_outbox_dirty then
		return true
	end
	for i = 1, #self.consent_outbox do
		if self.consent_outbox[i].kind ~= "user_verified" then
			return true
		end
	end
	return false
end

-- True when appending ONE more receipt would push the outbox over the cap
-- with fewer pre-existing pure grants than the overflow needs: the
-- denial-preferring eviction loop would then reach denial-carrying
-- receipts — or the incoming receipt itself, appended newest and therefore
-- the LAST pure grant it scans. set_consent(true) consults this to refuse
-- the grant (`consent_outbox_full`) instead of letting either happen;
-- see the gate there for the full rationale. Uses the storage layer's own
-- cap and pure-grant predicate so this prediction and the eviction loop
-- can never disagree.
function Client:consent_outbox_denial_full()
	local overflow = #self.consent_outbox + 1 - storage.max_consent_outbox_entries
	if overflow < 1 then
		return false
	end
	local evictable_grants = 0
	for i = 1, #self.consent_outbox do
		if storage.receipt_is_pure_grant(self.consent_outbox[i]) then
			evictable_grants = evictable_grants + 1
			if evictable_grants >= overflow then
				return false
			end
		end
	end
	return true
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

-- A user_verified-keyed receipt PARKS while the current session cannot
-- VOUCH FOR ITS ACTOR: it is dispatchable only when a Mode B
-- token_provider is configured AND the session's identified user is
-- exactly the receipt's actor. Everything else parks it — no
-- token_provider (a signed-out relaunch under the publishable key alone),
-- no identify() yet, or a DIFFERENT user signed in: the minted token
-- vouches for the current user, so dispatching another actor's receipt
-- under it would retry forever on the auth mismatch or be terminally
-- rejected — and dispatching under the publishable key would rebind or
-- reject the actor server-side. Either way an undelivered verified
-- decision (worst case a withdrawal) would be lost or wedge the trail.
-- A parked receipt is retained and persisted — still counted toward the
-- outbox cap and eviction — but excluded from dispatch selection and from
-- the grant-dispatch gate; it delivers verbatim, same idempotency_key, the
-- moment a Mode B session identifies as its actor again (identify() is a
-- consent dispatch point for exactly this reason). Parked-ness is DERIVED
-- here from the receipt's kind/actor and the current session, never
-- persisted as its own field.
-- NOTE: an explicit host API for discarding parked receipts (and the
-- verified-login re-key enqueue with its once-per-decision ledger) is
-- deliberately deferred pending godot-package ratification; until it
-- lands, a parked receipt's only exits are a vouching Mode B session or
-- cap eviction.
function Client:receipt_parked(receipt)
	if receipt.kind ~= "user_verified" then
		return false
	end
	return not (self.config.token_provider
		and self.user_id == receipt.actor_identifier)
end

-- True when some configured credential can lawfully carry this receipt's
-- actor: the minted Mode B token (it vouches for the current verified user
-- and for the CURRENT anon it binds as its subject) or the publishable
-- api_key (anon-keyed receipts, historic actors included). The Mode-B-only
-- load drop already removes anon receipts with a never-vouchable actor, so
-- this is the dispatch-side BELT for the same rule: a receipt nothing
-- vouches for is SKIPPED by selection — never handed to the token as a
-- fall-through non-vouching credential. user_verified receipts answer true
-- here by construction: receipt_parked (above) is the vouching gate for
-- that kind, and only the minted token ever carries it.
function Client:receipt_credential_available(receipt)
	if receipt.kind == "user_verified" then
		return true
	end
	return self.config.api_key ~= nil
		or (self.config.token_provider ~= nil
			and receipt.actor_identifier == self.anonymous_id)
end

-- The oldest receipt eligible for dispatch under the current credential
-- configuration: parked receipts — and receipts no configured credential
-- vouches for — are skipped, never head-blocking, and deliverable receipts
-- behind them deliver (delivery order stays FIFO per actor, which is the
-- ordering guarantee the server relies on).
function Client:next_dispatchable_receipt()
	for i = 1, #self.consent_outbox do
		local receipt = self.consent_outbox[i]
		if not self:receipt_parked(receipt)
			and self:receipt_credential_available(receipt) then
			return receipt
		end
	end
	return nil
end

-- True while the durable outbox retains an analytics GRANT receipt that has
-- NOT yet been handed to the transport. Delivery is serial and in decision
-- order, so the only receipt that can have been handed over is the one
-- currently in flight — a grant anywhere else (held behind a deferral or
-- backoff window, queued behind another receipt, or simply not yet
-- dispatched, e.g. right after a relaunch that reloaded the durable outbox)
-- is still awaiting its handoff, and an event batch dispatched meanwhile
-- would overtake it on the wire: on a strict-enforce workspace those
-- post-grant events reach the server before the grant row exists and are
-- terminally suppressed. The condition is DISPATCH, never acknowledgment: a
-- grant in flight (handed to the transport, response pending) does not hold
-- events — its request already precedes any batch dispatched after it.
-- PARKED grants are skipped: a parked receipt is not dispatchable on this
-- launch at all, and holding the batch leg for it would wedge every flush
-- (and teardown's final flush) for as long as the credential stays absent.
function Client:grant_receipt_pending_dispatch()
	for i = 1, #self.consent_outbox do
		local receipt = self.consent_outbox[i]
		if not self:receipt_parked(receipt)
			and type(receipt.categories) == "table" and receipt.categories.analytics == true then
			-- The receipt being handed over right now releases the gate only
			-- for ITSELF (matched by key identity — with parked receipts
			-- skipped the in-flight receipt is not always the head): a later
			-- grant queued behind it (grant→deny→grant toggling before the
			-- first receipt settles) still holds events until its own
			-- handoff.
			if not (self.consent_send_in_flight
				and receipt.idempotency_key == self.consent_in_flight_key) then
				return true
			end
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
	local actor, kind = receipt_actor(self)
	local payload = {
		workspace_id = self.config.workspace_id,
		app_id = self.config.app_id,
		environment_id = self.config.environment_id,
		actor_identifier = actor,
		-- The actor's ADR-0222 identity class, chosen by the same canonical
		-- selection as the actor itself. Persisted with the receipt and
		-- re-sent verbatim; it also drives the per-receipt dispatch
		-- credential and the parked predicate.
		kind = kind,
		categories = { analytics = self.consent_state == "granted" },
		decided_at = clock.iso_utc(),
		idempotency_key = id.uuid_v7(),
		-- Retention metadata, never sent on the wire: the decision-time
		-- anonymous id, so a later Mode B launch whose identity changed can
		-- recognize (and drop) an anon-keyed receipt its minted token could
		-- never send.
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

-- Deliver the outbox serially, oldest dispatchable receipt first — one
-- receipt in flight at a time, so receipts arrive in DECISION ORDER (parked
-- receipts are skipped, which per-actor FIFO makes safe) and a
-- grant-then-deny can never settle deny-then-grant. Returns true when
-- nothing is dispatchable (empty, or every retained receipt is parked or
-- has no vouching credential) or a
-- dispatch was started (transport failures are counted inside the result
-- callback); false while delivery is blocked — a receipt already in flight,
-- an open backoff window, or no usable credential yet. The dispatch
-- credential is selected PER RECEIPT, most-vouching first: the minted
-- Mode B token whenever it vouches for the receipt's actor (the current
-- verified user, or the current anon the mint binds as its subject — so
-- current-anon grants stay deliverable in the dual configuration), the
-- publishable api_key only for receipts the token cannot vouch for
-- (historic-anon actors) and in pure Mode A. Failure handling mirrors
-- the publish path: retryable outcomes keep the receipt for the next
-- dispatch point (a Retry-After or backoff paces the retry; a 401 under a
-- minted token re-mints and retries immediately), while terminal outcomes —
-- including a 401 on a dispatch that used the publishable key, whose static
-- credential cannot change — drop the receipt (surfaced through
-- diagnostics) rather than wedging every receipt queued behind it. A 401 is
-- classified by the credential the dispatch ACTUALLY USED: a
-- publishable-key 401 is terminal even in a dual-credential configuration,
-- and never invalidates the cached Mode B token.
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
	local payload = self:next_dispatchable_receipt()
	if not payload then
		return true
	end
	if self.consent_send_in_flight or self:consent_send_deferred() then
		return false
	end
	local credential
	-- MOST-VOUCHING credential selection: the receipt rides the minted
	-- Mode B token whenever that token vouches for the receipt's ACTOR —
	-- the current verified user (a dispatchable user_verified receipt has
	-- already passed the vouching predicate), or the CURRENT anonymous id,
	-- which the mint binds as the token's subject — so in the dual
	-- token_provider + api_key configuration a current-anon receipt may
	-- carry a GRANT the publishable key terminally could not (the route
	-- accepts grants only from a credential bound to the actor). Only a
	-- receipt the token cannot vouch for falls back to the publishable key
	-- where one is configured: the HISTORIC-anon receipt, whose actor this
	-- session can no longer mint for — the key needs no mint and no
	-- identity gate and is the one credential that can still carry it (a
	-- historic-anon pure grant takes the documented terminal grant 403;
	-- the one-way anon-scope outcome) — and every anon receipt in pure
	-- Mode A, where no token exists.
	local vouched_by_token = self.config.token_provider ~= nil
		and (payload.kind == "user_verified"
			or payload.actor_identifier == self.anonymous_id)
	local used_publishable_key = not vouched_by_token and self.config.api_key ~= nil
	if used_publishable_key then
		credential = self.config.api_key
	else
		if not self:can_publish() then
			return false
		end
		credential = self.token
	end
	-- The stored entry carries retention metadata (the decision-time
	-- anonymous_id snapshot read by the Mode B identity check at load); the
	-- wire payload is the receipt's contract fields only. `kind` rides the
	-- body by default; consent_kind_emission_enabled = false suppresses the
	-- field for deployments whose ingest still strict-decodes the
	-- pre-amendment schema (see validate_config).
	local wire = {
		workspace_id = payload.workspace_id,
		app_id = payload.app_id,
		environment_id = payload.environment_id,
		actor_identifier = payload.actor_identifier,
		kind = self.config.consent_kind_emission_enabled and payload.kind or nil,
		categories = payload.categories,
		decided_at = payload.decided_at,
		idempotency_key = payload.idempotency_key,
		reason = payload.reason,
	}
	self.consent_send_in_flight = true
	self.consent_in_flight_key = payload.idempotency_key
	local dispatched = transport.send_consent(self.config, credential, wire,
		function(ok, err, unauthorized, retryable, _, retry_after)
			self.consent_send_in_flight = false
			self.consent_in_flight_key = nil
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
			if unauthorized and not used_publishable_key then
				-- Only the credential that failed is invalidated: a minted
				-- token is dropped for a fresh mint, while a publishable-key
				-- 401 must not clear a cached Mode B token that was never on
				-- this request.
				self.token = nil
				self.token_expires_at_ms = nil
			end
			if is_retryable_publish_failure(err, unauthorized, retryable,
				not used_publishable_key and self.config.token_provider ~= nil) then
				-- The receipt stays retained in the durable outbox for the
				-- next dispatch point. A 401 is an auth problem, not
				-- backpressure — never deferred (a minted-token dispatch
				-- re-mints and retries immediately); transport transients
				-- honor a Retry-After or back off so a dead endpoint is not
				-- hammered every tick.
				if not unauthorized then
					if retry_after and retry_after > 0 then
						self:defer_consent(retry_after)
					else
						self:defer_consent_backoff()
					end
				end
				return
			end
			-- Terminal: the server will never accept this payload (or the
			-- static publishable key can never authorize it). Drop it —
			-- surfaced through diagnostics — so the receipts queued behind it
			-- still deliver.
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
		self.consent_in_flight_key = nil
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

-- The experiments plane's two fact shapes on the analytics pipeline. Queue
-- items and wire envelopes both carry event_name, so one predicate serves
-- every surface.
local function is_experiment_fact(event)
	local name = type(event) == "table" and event.event_name or nil
	return name == "experiment_exposure" or name == "experiment_outcome"
end

-- Remove experiment facts from a batch IN PLACE and rebuild its cached wire
-- payload (the payload snapshots the envelopes at first attempt — a filtered
-- batch resending the unfiltered capture would defeat the purge). Returns
-- the number removed.
local function filter_batch_facts(batch)
	local kept = {}
	for i = 1, #batch do
		if not is_experiment_fact(batch[i]) then
			kept[#kept + 1] = batch[i]
		end
	end
	local removed = #batch - #kept
	if removed == 0 then
		return 0
	end
	for i = #batch, 1, -1 do
		batch[i] = nil
	end
	for i = 1, #kept do
		batch[i] = kept[i]
	end
	if batch.payload then
		if batch.spool_origin then
			-- Spool-origin batches carry the persisted envelopes verbatim
			-- as BOTH the array part and the payload: rebuild the payload
			-- from the filtered array (the envelopes must survive
			-- unrebuilt — event_id/event_ts round-trip intact).
			local envelopes = {}
			for i = 1, #kept do
				envelopes[i] = kept[i]
			end
			batch.payload = { events = envelopes }
		else
			-- Queue-origin batches rebuild lazily at the next dispatch
			-- (ensure_batch_payload); envelope.build is deterministic over
			-- the immutable event snapshots, so the kept envelopes are
			-- bit-identical to the first attempt's.
			batch.payload = nil
		end
	end
	return removed
end

-- Purge experiment facts from every analytics pipeline surface. Invoked by
-- the experiments consumer when the real-subjects sentinel lands: the
-- withdrawn subject-fact keys ride these facts verbatim, and a fact that
-- ships after the platform flipped real subjects off keeps egressing what
-- the kill switch killed. SELECTIVE by event name — the host's events are
-- untouched (unlike the consent purge, which closes the whole plane).
-- Surfaces, in pipeline order: the memory queue (accepted facts below batch
-- size); the retained in-flight batch — only between attempts; a batch
-- actually ON THE WIRE is past recall (the consent purge's
-- publish-in-flight carve-out), and if that publish fails and retains, the
-- settle path filters it via experiment_purge_awaited; the in-memory spool
-- chunks awaiting re-send; and the durable spool record, converging through
-- the settled/rewrite machinery when the store is down. A failed rewrite
-- followed by process death before the retry lands re-sends those spooled
-- facts on the next launch — the documented storage-down-through-exit
-- residual family.
function Client:purge_experiment_facts()
	local purged = queue.remove_matching(self.queue, is_experiment_fact)
	if self.in_flight_batch then
		if self.publish_in_flight then
			self.experiment_purge_awaited = true
		else
			purged = purged + filter_batch_facts(self.in_flight_batch)
			if #self.in_flight_batch == 0 then
				self.in_flight_batch = nil
				-- The armed backpressure deferral belonged to the batch the
				-- purge just emptied — the consent-purge stale-deadline
				-- rule: leaving it would block the next granted batch for a
				-- window the server set for discarded work.
				self.publish_retry_after_ms = nil
				self.publish_backoff_attempt = 0
				self.spool_retry_after_ms = nil
			end
		end
	end
	if #self.spool_batches > 0 then
		local kept_chunks = {}
		for i = 1, #self.spool_batches do
			local chunk = self.spool_batches[i]
			local kept = {}
			for j = 1, #chunk do
				if is_experiment_fact(chunk[j]) then
					purged = purged + 1
				else
					kept[#kept + 1] = chunk[j]
				end
			end
			if #kept > 0 then
				kept_chunks[#kept_chunks + 1] = kept
			end
		end
		self.spool_batches = kept_chunks
	end
	-- Durable spool: mark the fact envelopes settled — every successful
	-- write drops settled entries — and attempt the rewrite immediately; a
	-- failed write leaves spool_rewrite_pending for the normal retry
	-- cadence (flush/persist/shutdown dispatch points). The facts marked
	-- here are the durable shadows of copies already counted on the memory
	-- surfaces (or of prior-launch chunks counted above), so they do not
	-- bump the purged count again.
	local marked = false
	for i = 1, #self.spool_record do
		local env = self.spool_record[i]
		if is_experiment_fact(env) and type(env.event_id) == "string" then
			self.spool_settled[env.event_id] = true
			marked = true
		end
	end
	if marked and not self:write_spool_record(self.spool_record) then
		self.spool_rewrite_pending = true
		-- The withdrawn facts are still on disk: durable debt — the
		-- condemnation marker must not retire until a write lands.
		self.condemned_spool_pending = true
	end
	if purged > 0 then
		-- Terminal non-delivery by server mandate: counted like the
		-- consent purge counts its clears, never like a retryable sweep
		-- refusal.
		self.stats.dropped = self.stats.dropped + purged
	end
	return purged
end

-- Durably capture ONE experiment fact straight into the spool, bypassing the
-- memory queue. Invoked by the experiments consumer when a durable entry
-- DROP lands while that entry's exposure is still owed in memory: the delete
-- removes the only persisted source the fact could re-arm from, so a process
-- KILL before the next sweep/persist would lose it — the spool copy makes a
-- relaunch replay it. NARROW by contract: only drop-time capture — owed
-- facts whose entries live on stay memory-only until the ordinary
-- dispatch-point captures (persist/shutdown/failed publish). The snapshot
-- stays armed in memory afterwards: the live process still emits it through
-- the normal sweep, and the deterministic event_id makes the pair collapse —
-- a successful publish acks the spool copy away, a replayed copy after a
-- kill dedups server-side. Fails (false) without a durable write when the
-- spool is disabled, consent is not granted, storage is down (the
-- storage-down-through-exit residual), or no session identity exists to
-- stamp — a background capture must not lazily open a session any more than
-- the background sweep may.
function Client:capture_experiment_fact(event_name, props, event_id, overrides)
	if not self.initialized or self.consent_state ~= "granted" then
		return false
	end
	overrides = overrides or {}
	local session_id = overrides.session_id or self.session_id
	if type(session_id) ~= "string" or session_id == "" then
		session_id = nil
		-- Mirror the enqueue path's source-conditional session rule: a
		-- backend-source client legitimately ships sessionless envelopes
		-- (enqueue never lazily opens a session for it), so its drop-time
		-- capture must not refuse for lacking one — a backend owed fact
		-- behind a full queue would otherwise die with the entry on a
		-- kill. Every OTHER source still requires a session identity: a
		-- background capture opens no phantom session.
		if self.config.source ~= "backend" then
			return false
		end
	end
	local props_snapshot = copy_table(props, "invalid_props")
	local event = {
		event_id = event_id,
		event_name = event_name,
		event_ts = overrides.event_ts or clock.iso_utc(),
		user_id = nil,
		anonymous_id = overrides.anonymous_id or self.anonymous_id,
		session_id = session_id,
		session_sequence = self.session_sequence + 1,
		props = props_snapshot,
		context = nil,
	}
	self.session_sequence = event.session_sequence
	return self:spool_envelopes({ envelope.build(self.config, self, event) })
end

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
	-- The whole file was just rewritten from the filtered state: no
	-- condemned content can remain on disk.
	self.condemned_spool_pending = false
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
		-- The emptied spool also settles any condemnation debt: an empty
		-- durable record proves cleanliness exactly like a successful
		-- whole-file write proves it, so the fail-closed marker may retire
		-- once the record side settles.
		self.condemned_spool_pending = false
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
	local replaced = false
	local replaced_ids = nil
	for i = 1, #envelopes do
		local env = envelopes[i]
		local event_id = type(env) == "table" and env.event_id or nil
		if type(event_id) == "string" and event_id ~= "" then
			if self.spool_settled[event_id] then
				-- A replacement fact re-derived a deterministic id whose
				-- prior copy a sentinel purge condemned while the removal
				-- rewrite is still owed: capturing the replacement
				-- RE-LEGITIMIZES the id — clear the settled mark — and
				-- the stored envelope is ALWAYS overwritten with the
				-- replacement's bytes. The pre-sentinel copy can differ
				-- in props (a reissued subject-fact key: the withdrawn
				-- key must never resend) OR only in identity fields — and
				-- the identity matters just as much: the old copy carries
				-- a PRE-sentinel event_ts, which the relaunch's stamp
				-- partition would drop as withdrawn while this capture
				-- had reported the fact durable. The replacement's
				-- post-sentinel identity is the durable form, full stop.
				-- The write below must land (else the deferred-rewrite
				-- machinery converges the mirror and the capture reports
				-- not-yet-durable). Where a condemnation marker survives
				-- to the next launch, the scope-gated stamp partition
				-- governs every spooled fact equally. (An acked-but-
				-- unrewritten published id re-captured this way just
				-- resurrects a delivered envelope with fresher identity;
				-- the deterministic id collapses the re-send server-side.)
				self.spool_settled[event_id] = nil
				if self.spool_index[event_id] then
					for j = 1, #self.spool_record do
						local stored = self.spool_record[j]
						if type(stored) == "table"
							and stored.event_id == event_id then
							self.spool_record[j] = env
							replaced = true
							replaced_ids = replaced_ids or {}
							replaced_ids[event_id] = true
							break
						end
					end
				end
			end
			if not self.spool_index[event_id] and not seen[event_id] then
				seen[event_id] = true
				fresh[#fresh + 1] = env
			end
		end
	end
	if #fresh == 0 and not replaced then
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
		if replaced then
			-- The disk still carries the superseded (withdrawn-key) bytes
			-- while the mirror holds the replacement: converge through the
			-- deferred-rewrite machinery at the next dispatch point.
			self.spool_rewrite_pending = true
		end
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
	if replaced_ids then
		-- An in-place replacement sits at its ORIGINAL position, so the
		-- caps' oldest-first eviction can reach it exactly like any old
		-- entry: a replacement that did not survive into the saved record
		-- was NOT captured, and a durability-dependent caller must not
		-- report it safe on the strength of the overwrite alone.
		for event_id in pairs(replaced_ids) do
			if not self.spool_index[event_id] then
				return false
			end
		end
	end
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
			local env = payload.events[i]
			-- A sentinel purge that found this batch ON THE WIRE could not
			-- touch it (past recall) — the settle callback filters it at
			-- retention. But a persist/shutdown snapshot BEFORE the settle
			-- must not capture the withdrawn facts into the durable spool:
			-- a crash pre-settle would replay them at the next launch. The
			-- QUEUE part below is deliberately unfiltered — facts there
			-- postdate the purge (a flip-back re-exposure) and are
			-- legitimate.
			if not (self.experiment_purge_awaited and is_experiment_fact(env)) then
				envelopes[#envelopes + 1] = env
			end
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
	if self.experiments then
		-- Owed durable experiment syncs share the snapshot moment too, and
		-- like the consent outbox they are independent of event spooling
		-- (consent-independent local disk state): a kill drop or refresh
		-- write still owed when the OS kills the app would leave a revoked
		-- assignment as reload truth. Retried before the spool gates below
		-- so even a spool-less configuration converges its cache here.
		self.experiments:retry_durable_sync()
	end
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
		-- "unknown" client never queued anything to capture. A still-owed
		-- durable cache sync is the one exception worth reporting: it is
		-- consent-independent disk state an app death would leave stale.
		if self.experiments and self.experiments:has_owed_durable_sync() then
			return false, "experiments_pending"
		end
		return true
	end
	if self.experiments then
		-- Owed exposure facts join the snapshot: the sweep is their normal
		-- emission (they enter the queue, stay queued for regular delivery,
		-- and ride the spool capture below — ack-based removal applies as
		-- to any spooled event). A fact the full queue still refuses stays
		-- owed and is reported below.
		self.experiments:sweep_owed()
	end
	if not self:spool_undelivered() then
		return false, "spool_persist_failed"
	end
	if self.experiments and (self.experiments:has_owed_exposures()
		or self.experiments:has_owed_durable_sync()) then
		-- Something owed was NOT captured (a full queue denied a swept
		-- fact, or the cache write is still failing): an OS kill right
		-- now would lose it, so the app-may-die snapshot must not claim
		-- safety. The host's recourse is a flush() and another persist().
		return false, "experiments_pending"
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
		-- A sentinel purge that ran while this batch was ON THE WIRE could
		-- not touch it (the attempt itself is past recall); settle the
		-- deferred recall now, whatever the outcome — a successful publish
		-- means the facts egressed with the attempt (the accepted
		-- carve-out), a retained failure filters them below.
		local purge_awaited = self.experiment_purge_awaited
		self.experiment_purge_awaited = false
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
		if retain and purge_awaited then
			-- The failed batch is retained for retry, but a sentinel purge
			-- ran mid-flight: the withdrawn facts must not ride the next
			-- attempt or the spool capture below. Filter them now (their
			-- spool shadows were already marked settled by the purge); an
			-- emptied batch has nothing left to retain, defer, or spool —
			-- and its facts were counted dropped per-item here, so the
			-- terminal not-retained accounting below must not run for it.
			local removed = filter_batch_facts(events)
			if removed > 0 then
				self.stats.dropped = self.stats.dropped + removed
			end
			if #events == 0 then
				if self.in_flight_batch == events then
					self.in_flight_batch = nil
				end
				retain = false
				-- Nothing is retained, so no deferral may arm below — and
				-- any deadline a previous attempt of this batch armed is
				-- stale now (the consent-purge rule).
				self.publish_retry_after_ms = nil
				self.publish_backoff_attempt = 0
				self.spool_retry_after_ms = nil
			end
		end
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
			-- ensure_batch_payload: a mid-flight fact purge invalidates a
			-- queue-origin batch's cached payload; rebuild it here so the
			-- spool captures exactly the kept envelopes.
			self:spool_envelopes(self:ensure_batch_payload(events).events)
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
	-- this flush is held while the outbox retains a DISPATCHABLE analytics
	-- GRANT receipt that has not yet been HANDED TO THE TRANSPORT (the
	-- dispatch above may have started only one receipt, and http.request is
	-- asynchronous — a grant held behind a deferral/backoff window, queued
	-- behind another receipt, or awaiting its first post-relaunch dispatch
	-- has not been handed over yet). Publishing meanwhile would invert the
	-- receipt-before-batch ordering and hand a strict-enforce workspace
	-- post-grant events with no consent row to admit them (terminal
	-- suppressed_no_consent). The condition is dispatch, NOT acknowledgment
	-- (the rejected ack-gating variant): a grant in flight releases the gate
	-- with its response still pending. The gate only fires when there ARE
	-- events to hold: an empty pipeline must keep returning success so a
	-- durably-retained undispatched receipt alone never blocks teardown
	-- (shutdown's outbox-durability contract). PARKED verified-keyed grants
	-- never gate — they cannot dispatch on this launch at all, and holding
	-- the batch leg for them would wedge every flush until the Mode B
	-- credential returns (grant_receipt_pending_dispatch skips them).
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
	local session_end_owed = false
	if self.session_active then
		-- session_end completes the local teardown even while consent is
		-- denied or unknown (the wire event is suppressed inside session_end);
		-- summary events are suppressed below via include_summaries.
		local session_ok, session_err = self:session_end(reason or "app_final")
		if not session_ok then
			if session_err == "queue_full" then
				-- A FULL queue is exactly the scenario the flush below
				-- exists to drain (and the one that leaves an exposure
				-- owed): it must not short-circuit shutdown's last-chance
				-- housekeeping. The session end is retried after the flush
				-- frees the room, best-effort like the rest of the exit
				-- path.
				session_end_owed = true
			else
				return false, session_err
			end
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
		-- The remnant is now durably on disk: EVICT it from the in-memory
		-- queue so the post-flush housekeeping (the deferred session end,
		-- owed exposure facts) has room to enqueue. The spooled envelopes
		-- re-send at the next launch; keeping the memory copies would both
		-- wedge that housekeeping behind a still-full queue and double-send.
		queue.drain(self.queue, queue.size(self.queue))
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
	-- Post-flush housekeeping LOOP: the flush freed queue room, so the
	-- deferred session end and the owed exposure facts get their chance to
	-- enqueue — in PASSES, because the freed room may be as small as one
	-- slot (buffer_size = 1 is a valid config): each pass enqueues what
	-- fits (the session end first), then delivers or durably spools the
	-- just-queued events to free room for the next pass. The loop ends
	-- when nothing deliverable is owed, or when a pass moves nothing —
	-- and the shutdown contract governs throughout: every owed fact is
	-- SENT, durably SPOOLED, or shutdown stays retryable, never dropped
	-- by a "successful" teardown. Owed durable cache syncs are disk-side
	-- housekeeping (no queue room involved): they get a retry each pass
	-- and deliberately stay a non-blocker — a still-failing cache write
	-- re-converges from the durable machinery at the next launch.
	local owed_session_end = session_end_owed
	while true do
		local enqueued_any = false
		if owed_session_end and self.session_active then
			-- The room the full queue denied session_end() may exist now:
			-- complete the session teardown. Only a STILL-full queue is
			-- retryable by a later pass; any other failure keeps the old
			-- contract — report it and stay alive for a host retry.
			local retry_ok, retry_err = self:session_end(reason or "app_final")
			if retry_ok then
				owed_session_end = false
				enqueued_any = true
			elseif retry_err ~= "queue_full" then
				return false, retry_err
			end
		end
		if self.experiments then
			self.experiments:retry_durable_sync()
			-- Sweep owed exposure facts — as many as the queue admits this
			-- pass — so a treatment applied under a FULL queue does not
			-- exit without its fact. FINAL sweep: pre-session snapshots the
			-- tick sweep held for their first-session attribution drain
			-- here too — no later session_start can double-arm at
			-- teardown, and the fact must not exit unemitted (it rides the
			-- exit-time session, lazily opened at the very end when none
			-- ever existed).
			local before_sweep = queue.size(self.queue)
			self.experiments:sweep_owed(true)
			if queue.size(self.queue) > before_sweep then
				enqueued_any = true
			end
		end
		if self.consent_state == "granted" and self.session_active
			and not owed_session_end then
			-- The final drain lazily opened a session (a pre-session owed
			-- fact with no session ever started rides the exit-time
			-- session): it must close like every session this shutdown
			-- finalizes. Pick it up as an owed session_end so the next
			-- pass enqueues and delivers it — tearing down here would
			-- leave session_active with no session_end on the wire. Only
			-- reachable for drain-opened sessions: a session active at
			-- shutdown entry either ended before the loop (inactive now)
			-- or is already carried by owed_session_end.
			owed_session_end = true
		end
		-- Owed exposures count as deliverable only on the granted plane:
		-- a non-granted state cannot enqueue them (the purge/consent canon
		-- governs those snapshots, not the exit path).
		local still_owed = (owed_session_end and self.session_active)
			or (self.consent_state == "granted" and self.experiments ~= nil
				and self.experiments:has_owed_exposures())
		if enqueued_any then
			local sent, send_err = self:flush({ include_summaries = false })
			if not sent then
				-- Same posture as the first flush: a terminal rejection
				-- dropped the batch (no remnant), and a vacuous capture
				-- must not upgrade that failure.
				local has_remnant = self.in_flight_batch ~= nil
					or queue.size(self.queue) > 0 or self:spool_pending()
				if not has_remnant or not self:spool_undelivered() then
					return false, send_err
				end
				-- Durably captured: EVICT the remnant so the next pass has
				-- room (the spooled envelopes re-send at the next launch;
				-- memory copies kept would wedge the loop and double-send).
				queue.drain(self.queue, queue.size(self.queue))
			end
		end
		if not still_owed then
			break
		end
		if not enqueued_any then
			-- A full pass moved nothing into the queue while something is
			-- still owed: no forward progress is possible, and finalizing
			-- would silently drop the owed facts — stay retryable.
			return false, "queue_full"
		end
	end
	if self.experiments then
		-- Owed durable cache syncs got a retry on every housekeeping pass;
		-- if the store is STILL failing here, the per-key intents (a kill
		-- drop, a refresh write, an owed whole-record clear) are memory-
		-- only and a teardown now would leave a revoked assignment as
		-- reload truth at the next launch. Stay retryable instead —
		-- persist() parity. (This supersedes the earlier best-effort
		-- posture for the FAILING-store case; a healthy store never
		-- reaches this point owed.)
		self.experiments:retry_durable_sync()
		if self.experiments:has_owed_durable_sync() then
			return false, "experiments_pending"
		end
		-- Stop the experiments consumer WITH the successful teardown (a
		-- failed shutdown keeps the client — and the consumer — alive for
		-- a host retry): an assignment response still in flight must not
		-- install, persist, or call back into game code from now on.
		self.experiments:teardown()
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
