-- The crash ingest client: a dedicated client that POSTs crash reports to
-- {crash_ingest_url}/api/v1/crashes/ingest with a `crash:write` API key, stamps
-- the component-slug `source` on every report, samples NON-fatal reports, and
-- ALWAYS sends a fatal crash (emit_fatal bypasses the sampler). Behavior is
-- consistent across our SDKs.
local breadcrumbs = require "shardpilot.crash.breadcrumbs"
local event_mod = require "shardpilot.crash.event"
local sanitize = require "shardpilot.crash.sanitize"
local transport = require "shardpilot.crash.transport"
local dump = require "shardpilot.crash.dump"
local storage = require "shardpilot.storage"
local platform = require "shardpilot.platform"

local M = {}

local default_sample_every = 10
local default_publish_timeout_seconds = 30

-- Reuse the analytics URL shape rules: absolute http(s) base, https required
-- outside loopback, no path/query/fragment/userinfo. The crash route is appended
-- by the transport, so the configured URL must be the bare crash ingest base.
local function local_http_host(host)
	return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function parse_authority(authority)
	if authority == "" or authority:find("@", 1, true) then
		return nil
	end
	local host = nil
	if authority:sub(1, 1) == "[" then
		local rest
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

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

local function non_empty_string(value)
	return type(value) == "string" and value ~= ""
end

local function normalize_integer(value, default_value, min_value, error_code)
	if value == nil then
		return default_value
	end
	if type(value) ~= "number" or value ~= math.floor(value) or value < min_value then
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

local function validate_config(config)
	if type(config) ~= "table" then
		return nil, "config_required"
	end
	local required = { "crash_ingest_url", "app_id" }
	for _, key in ipairs(required) do
		if config[key] == nil or config[key] == "" then
			return nil, key .. "_required"
		end
		if type(config[key]) ~= "string" then
			return nil, "invalid_" .. key
		end
	end
	if not valid_ingest_url(config.crash_ingest_url) then
		return nil, "invalid_crash_ingest_url"
	end
	-- app_id is operator-set product scope, validated here at init time so a
	-- misconfiguration is surfaced as a clear config error instead of silently
	-- dropping every report later. A legitimate scope whose slug begins with an
	-- actor-style prefix ("user_app", "customer_portal") survives the structured
	-- scrub; a value that carries real PII/secret content (an email, an IP, a
	-- token, a digit-bearing raw actor id like "user_4242") scrubs empty and is
	-- rejected NOW, so it can never reach emit and drop a fatal crash.
	if sanitize.sanitize_structured(config.app_id) == "" then
		return nil, "invalid_app_id"
	end
	-- Crash ingest authenticates with a STATIC `crash:write` API key. There is no
	-- token_provider / dual-mode here: the key is the standing Bearer.
	if not non_empty_string(config.crash_api_key) then
		return nil, "crash_api_key_required"
	end
	-- Component slug stamped on every report. Mirrors how the analytics `source`
	-- is configured (a config field defaulted onto every event), but the VALUE
	-- space is the component slug, not the analytics client/server/backend enum.
	-- Empty/absent = bare app.
	local crash_source = config.crash_source or ""
	if not event_mod.valid_source(crash_source) then
		return nil, "invalid_crash_source"
	end
	local sample_every, sample_err =
		normalize_integer(config.sample_every, default_sample_every, 1, "invalid_sample_every")
	if not sample_every then
		return nil, sample_err
	end
	local publish_timeout_seconds, timeout_err = normalize_positive_number(
		config.publish_timeout_seconds, default_publish_timeout_seconds, "invalid_publish_timeout_seconds")
	if not publish_timeout_seconds then
		return nil, timeout_err
	end
	-- Resolve the platform once, at init time. Every crash report requires a
	-- platform (the server rejects one without it). When the caller omits
	-- config.platform AND auto-detection cannot identify the runtime
	-- (platform.detect() returns nil — e.g. an unmapped system or sys info
	-- unavailable), creating the client would otherwise succeed but every emit
	-- would fail platform_required. Fail crash.new() with a clear config error here
	-- instead of handing back a client that can never send a crash.
	local resolved_platform = config.platform or platform.detect()
	if not non_empty_string(resolved_platform) then
		return nil, "platform_required"
	end
	-- The platform is scrubbed on every emit. A caller-set platform that carries
	-- PII/secret content (an email, a raw actor id like "user_123", an IP) scrubs
	-- empty, after which every emit — including a fatal crash — would fail
	-- platform_required. Validate the SANITIZED platform here so such a value is
	-- rejected at config time rather than handing back a client that can never send.
	if sanitize.sanitize_string(resolved_platform) == "" then
		return nil, "platform_required"
	end
	if config.diagnostics ~= nil and type(config.diagnostics) ~= "function" then
		return nil, "invalid_diagnostics"
	end
	if config.sampler ~= nil and type(config.sampler) ~= "function" then
		return nil, "invalid_sampler"
	end
	return {
		crash_ingest_url = trim_slash(config.crash_ingest_url),
		crash_api_key = config.crash_api_key,
		app_id = config.app_id,
		app_version = config.app_version,
		app_build = config.app_build,
		crash_source = crash_source ~= "" and crash_source or nil,
		platform = resolved_platform,
		sample_every = sample_every,
		publish_timeout_seconds = publish_timeout_seconds,
		diagnostics = config.diagnostics,
		sampler = config.sampler,
	}
end

local Client = {}
Client.__index = Client

function M.new(config)
	local normalized, err = validate_config(config)
	if not normalized then
		return nil, err
	end
	return setmetatable({
		config = normalized,
		breadcrumbs = breadcrumbs.new(),
		sample_counter = 0,
		-- A best-effort, in-session-only fallback store of prepared reports that could
		-- not be persisted to the on-disk sidecar (storage quota / failure / oversize).
		-- Keyed by an in-memory token, it lets an in-session retryable failure resend
		-- the report. It does NOT survive a process restart — disk persistence is the
		-- durable path; this only avoids dropping a consumed one-shot dump outright.
		in_memory_pending = {},
		in_memory_pending_seq = 0,
		-- Count of crash POSTs whose async transport callback has not yet fired.
		-- shutdown() waits (bounded, host-retried) for this to reach zero so a fatal
		-- report in flight is not lost when the client is discarded.
		in_flight = 0,
		stats = {
			emitted = 0,
			sampled_out = 0,
			accepted = 0,
			failed = 0,
			dropped = 0,
			rejected = 0,
			last_error = nil,
			last_issue = nil,
		},
		initialized = true,
	}, Client)
end

-- Record a breadcrumb. Names are scrubbed; an invalid name is dropped.
function Client:record_breadcrumb(name)
	return self.breadcrumbs:record(name)
end

-- The persistence scope for this client's pending crash reports — namespaced per
-- configured app so two games on the same device never share a pending file.
function Client:pending_scope()
	return { app_id = self.config.app_id }
end

-- Retain a prepared report in the in-session fallback store (used only when on-disk
-- persistence failed) and return its in-memory token. The token is distinct from
-- on-disk tokens so the two stores never collide.
function Client:retain_in_memory_pending(prepared)
	self.in_memory_pending_seq = self.in_memory_pending_seq + 1
	local token = "mem:" .. tostring(self.in_memory_pending_seq)
	self.in_memory_pending[token] = prepared
	return token
end

-- Remove an in-memory fallback entry by its token. A no-op for an on-disk token or
-- an already-removed entry.
function Client:remove_in_memory_pending(token)
	if type(token) == "string" then
		self.in_memory_pending[token] = nil
	end
end

-- Remove a settled report's pending copy, routing to the in-memory fallback store
-- for an in-memory token ("mem:" prefix) and to the on-disk sidecar otherwise. A
-- SETTLED report (accepted or terminally rejected) is always removed so it is not
-- resent — the guarantee holds for both stores.
function Client:remove_pending(token)
	if type(token) ~= "string" then
		return
	end
	if token:sub(1, 4) == "mem:" then
		self:remove_in_memory_pending(token)
	else
		storage.remove_pending_crash(self:pending_scope(), token)
	end
end

local function diagnose(self, issue)
	if issue.code then
		self.stats.last_issue = tostring(issue.status or "") .. ":" .. tostring(issue.code)
	elseif issue.status then
		self.stats.last_issue = tostring(issue.status)
	end
	local hook = self.config.diagnostics
	if type(hook) == "function" then
		pcall(hook, issue)
	end
end

-- Decide whether a NON-fatal report is sampled in. A fatal report never reaches
-- here (emit_fatal bypasses the sampler). A custom sampler returns a boolean;
-- the default is deterministic 1-in-N (sample_every).
local function should_emit(self, event)
	local custom = self.config.sampler
	if type(custom) == "function" then
		-- The report has already been sanitized and validated. Hand the sampler a
		-- clone so any field it mutates (e.g. attaching its own unsanitized
		-- metadata) stays on the throwaway copy and can never reach the wire
		-- unscrubbed — the privacy boundary holds regardless of what the sampler does.
		local view = event_mod.clone_event(event) or event
		local ok, keep = pcall(custom, view)
		if not ok then
			-- A throwing sampler must not lose the report: fail open (keep it).
			return true
		end
		return keep ~= false
	end
	if self.config.sample_every <= 1 then
		return true
	end
	self.sample_counter = self.sample_counter + 1
	return (self.sample_counter % self.config.sample_every) == 0
end

-- Core emit. `fatal` bypasses the sampler (a fatal crash is ALWAYS sent).
-- `trusted_frame_functions` marks frame functions as trusted
-- code symbols (the dump-forward path). Returns (true) on dispatch / sampled-out,
-- (false, error_code) on a prepare or transport-setup failure.
function Client:emit_internal(event, fatal, trusted_frame_functions, prepare_options)
	if not self.initialized then
		return false, "shutdown"
	end
	if type(event) ~= "table" then
		return false, "invalid_event"
	end
	-- Thread the fatal flag into prepare so an invalid per-report source omits the
	-- source (and still sends) for a fatal crash, but is rejected for a non-fatal one.
	local merged_options = {}
	if type(prepare_options) == "table" then
		for key, value in pairs(prepare_options) do
			merged_options[key] = value
		end
	end
	merged_options.fatal = fatal == true
	local prepared, prepare_err = event_mod.prepare(self, event, trusted_frame_functions == true, merged_options)
	if not prepared then
		self.stats.dropped = self.stats.dropped + 1
		self.stats.last_error = prepare_err
		return false, prepare_err
	end
	-- A report sourced from a one-shot previous-session dump cannot be regenerated
	-- if a temporary send failure drops it (the dump is already consumed). When the
	-- caller marks it for persistence, the prepared report is persisted to the
	-- per-app sidecar BEFORE dispatch, so a second crash / app kill during the
	-- in-flight window cannot lose it. It is removed only once the send is accepted
	-- or terminally rejected; a retryable failure leaves it persisted for the next
	-- launch to resend.
	local persist_on_retry = merged_options.persist_on_retry == true
	if not fatal and not should_emit(self, prepared) then
		self.stats.sampled_out = self.stats.sampled_out + 1
		return true
	end
	local pending_token = nil
	if persist_on_retry then
		pending_token = storage.save_pending_crash(self:pending_scope(), prepared)
		-- On-disk persistence can fail durably (storage quota / failure / an oversized
		-- prepared report). A DUMP-sourced report is a consumed one-shot — dropping it
		-- here would lose it permanently. Fall back to an in-session in-memory pending
		-- entry so an in-session retryable failure can still resend it. (Best-effort:
		-- the in-memory copy does not survive a process restart; disk is the durable
		-- path.) The report is still dispatched below either way.
		if not pending_token then
			pending_token = self:retain_in_memory_pending(prepared)
		end
	end
	self.stats.emitted = self.stats.emitted + 1

	-- Track this send as in flight until its async callback fires. The
	-- callback decrements exactly once whether the transport completes
	-- synchronously (test stub) or on a later frame (real runtime); a `done` guard
	-- protects against a transport that double-invokes the callback.
	self.in_flight = self.in_flight + 1
	local settled = false
	local function settle()
		if settled then
			return
		end
		settled = true
		if self.in_flight > 0 then
			self.in_flight = self.in_flight - 1
		end
	end

	local dispatched = transport.ingest(self.config, self.config.crash_api_key, prepared,
		function(ok, transport_err, unauthorized, retryable, response)
			settle()
			if ok then
				self.stats.accepted = self.stats.accepted + 1
				-- The send was accepted: the pre-dispatch pending copy (on-disk or the
				-- in-memory fallback) is no longer needed.
				if pending_token then
					self:remove_pending(pending_token)
				end
				return
			end
			self.stats.failed = self.stats.failed + 1
			self.stats.last_error = transport_err
			if not unauthorized and not retryable then
				self.stats.rejected = self.stats.rejected + 1
			end
			-- A retryable failure leaves the pre-dispatch pending copy in place (on-disk
			-- for a later launch, or in-memory for an in-session resend) so it can be
			-- retried. A non-retryable reject (a 4xx other than rate-limit) is terminal:
			-- remove the pending copy so it is not retried.
			if pending_token and not retryable then
				self:remove_pending(pending_token)
			end
			diagnose(self, {
				scope = "crash",
				status = unauthorized and "unauthorized" or "rejected",
				code = transport_err,
				retryable = retryable,
				response = type(response) == "table" and response.status or nil,
			})
		end)
	if not dispatched then
		-- The transport reported a synchronous setup failure (no http/json, encode
		-- error). Every transport path invokes the callback (which already settled
		-- the in-flight count and recorded the error), but call settle() once more as
		-- a guarded no-op so a missed callback can never wedge the count and block
		-- shutdown forever. Surface the last error.
		settle()
		return false, self.stats.last_error or "not_dispatched"
	end
	return true
end

-- Emit a non-fatal crash report (subject to sampling).
function Client:emit(event)
	return self:emit_internal(event, false, false)
end

-- Emit a FATAL crash report. NEVER sampled away — a fatal crash is always sent.
function Client:emit_fatal(event)
	return self:emit_internal(event, true, false)
end

-- Read a previous-session native crash dump (if any) via Defold's built-in
-- `crash` module and forward it as a FATAL report. Returns (true, sent) where
-- `sent` is true only when a dump existed and was dispatched; (true, false) when
-- there was no dump; (false, err) on a forward failure. `crash_module` is
-- injectable for testing.
function Client:capture_previous(crash_module)
	if not self.initialized then
		return false, "shutdown"
	end
	-- First, try to resend any reports a previous launch persisted after a
	-- temporary send failure (offline / rate-limited / server error). A dump is
	-- one-shot, so this is the only way such a crash is not permanently lost.
	self:resend_pending()
	local event = dump.load_previous_event(crash_module)
	if not event then
		return true, false
	end
	-- Dump frames carry no symbols (native addresses) and the modules come from
	-- the trusted engine module list, so the function-scrub tier is irrelevant
	-- here; forward as a fatal report so it is never sampled away. The dump is from
	-- the DEAD previous session and carries no breadcrumbs of its own — suppress
	-- attaching the current session's breadcrumb ring, which would otherwise
	-- misattribute this session's breadcrumbs to the previous crash.
	local ok, err = self:emit_internal(event, true, true,
		{ skip_breadcrumb_ring = true, persist_on_retry = true })
	if not ok then
		return false, err
	end
	return true, true
end

-- Resend any crash reports persisted by a previous launch after a temporary send
-- failure. Each entry is already on disk (it was persisted before its first
-- dispatch), so it is dispatched in place and removed only once the resend is
-- accepted or terminally rejected; a retryable failure leaves it persisted for a
-- later launch. The entry is never cleared up front, so an app kill mid-resend
-- cannot lose a still-pending report.
function Client:resend_pending()
	if not self.initialized then
		return
	end
	-- First, resend any in-session in-memory fallback entries (reports that could not
	-- be persisted to disk). Snapshot the tokens before dispatching: a synchronous
	-- transport stub may settle and remove the entry mid-iteration.
	local mem_tokens = {}
	for token in pairs(self.in_memory_pending) do
		mem_tokens[#mem_tokens + 1] = token
	end
	for _, token in ipairs(mem_tokens) do
		local report = self.in_memory_pending[token]
		if type(report) == "table" then
			self:dispatch_prepared(report, token)
		end
	end
	local entries = storage.load_pending_entries(self:pending_scope())
	if type(entries) ~= "table" or #entries == 0 then
		return
	end
	for _, entry in ipairs(entries) do
		if type(entry) == "table" and type(entry.report) == "table" and type(entry.token) == "string" then
			self:dispatch_prepared(entry.report, entry.token)
		end
	end
end

-- Dispatch an ALREADY-PREPARED crash report (skipping prepare/sanitize/validate,
-- which already ran when it was first built). Mirrors the in-flight bookkeeping
-- and stats of emit_internal. `pending_token` (when set) addresses the on-disk
-- copy persisted for this report: it is removed once the send is accepted or
-- terminally rejected, and left in place on a retryable failure so a later launch
-- resends it.
function Client:dispatch_prepared(prepared, pending_token)
	if not self.initialized or type(prepared) ~= "table" then
		return false, "invalid_event"
	end
	self.stats.emitted = self.stats.emitted + 1
	self.in_flight = self.in_flight + 1
	local settled = false
	local function settle()
		if settled then
			return
		end
		settled = true
		if self.in_flight > 0 then
			self.in_flight = self.in_flight - 1
		end
	end

	local dispatched = transport.ingest(self.config, self.config.crash_api_key, prepared,
		function(ok, transport_err, unauthorized, retryable, response)
			settle()
			if ok then
				self.stats.accepted = self.stats.accepted + 1
				if pending_token then
					self:remove_pending(pending_token)
				end
				return
			end
			self.stats.failed = self.stats.failed + 1
			self.stats.last_error = transport_err
			if not unauthorized and not retryable then
				self.stats.rejected = self.stats.rejected + 1
			end
			-- Leave a retryable failure pending (on-disk or in-memory); remove a terminal
			-- (non-retryable) reject so it is not retried forever.
			if pending_token and not retryable then
				self:remove_pending(pending_token)
			end
			diagnose(self, {
				scope = "crash",
				status = unauthorized and "unauthorized" or "rejected",
				code = transport_err,
				retryable = retryable,
				response = type(response) == "table" and response.status or nil,
			})
		end)
	if not dispatched then
		settle()
		return false, self.stats.last_error or "not_dispatched"
	end
	return true
end

function Client:snapshot()
	local out = {}
	for key, value in pairs(self.stats) do
		out[key] = value
	end
	return out
end

-- Tear down the client. A crash POST dispatched in the real runtime completes via
-- an async http callback on a LATER frame; returning success immediately would
-- let the host discard the client (and stop pumping http.update) before the POST
-- finishes, losing a fatal report. So while any send is still in flight
-- shutdown reports (false, "pending") — the same wait posture the analytics client
-- uses — and the host retries shutdown (pumping http.update between attempts) until
-- the callbacks have settled. Once nothing is in flight the client finalizes.
-- `initialized` is left true until then so emit() during teardown is not
-- silently misrouted as a post-shutdown call.
function Client:shutdown()
	if self.in_flight > 0 then
		return false, "pending"
	end
	self.initialized = false
	return true
end

M.Client = Client

return M
