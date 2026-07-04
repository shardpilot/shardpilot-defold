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
		-- A best-effort, in-session-only fallback store of encoded report bodies that
		-- could not be persisted to the on-disk sidecar (storage quota / failure /
		-- oversize). Keyed by an in-memory token, it lets an in-session resend pass
		-- retry the report. It does NOT survive a process restart — disk persistence
		-- is the durable path; this only avoids dropping a report outright.
		in_memory_pending = {},
		in_memory_pending_seq = 0,
		-- Count of crash POSTs whose async transport callback has not yet fired.
		-- shutdown() waits (bounded, host-retried) for this to reach zero so a fatal
		-- report in flight is not lost when the client is discarded.
		in_flight = 0,
		-- True while a serial resend pass over the pending sidecar is running
		-- (one pass at a time; each pass sends strictly one report at a time).
		resend_active = false,
		stats = {
			emitted = 0,
			sampled_out = 0,
			accepted = 0,
			-- Crashes the server ACCEPTED (2xx) but did NOT store because the actor
			-- withheld consent; counted separately from accepted-and-stored.
			suppressed = 0,
			failed = 0,
			dropped = 0,
			rejected = 0,
			-- Reports persisted write-ahead to the pending sidecar / reports that
			-- could not be persisted (memory-only fallback; ≠ durable).
			persisted = 0,
			persist_failed = 0,
			last_error = nil,
			last_issue = nil,
			-- Last non-fatal processing notice and last server-instructed Retry-After
			-- (whole seconds, from a 429/503), surfaced via snapshot() for observability.
			last_warning = nil,
			last_retry_after = nil,
			-- When a resend pass found pending reports but a stored backpressure
			-- deadline (ms epoch) is still in the future, the pass defers and the
			-- deadline is surfaced here.
			resend_deferred_until_ms = nil,
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

local max_in_memory_pending = 8
local max_in_memory_body_bytes = 64 * 1024
local max_in_memory_total_bytes = 384 * 1024

-- Retain a pending entry ({ body, crash_id, fatal }) in the in-session
-- fallback store (used only when on-disk persistence failed) and return its
-- in-memory token, or nil when the entry was not admitted. The token is
-- distinct from on-disk tokens so the two stores never collide. The store
-- is BOUNDED with the sidecar's own retention policy — at most 8 entries /
-- 64 KB per body / 384 KB total, oldest non-fatal evicted first, a fatal
-- entry never evicted to admit a non-fatal one — so a session-long
-- persist-failure loop (or a few reports with very large raw text) can
-- never accumulate unbounded encoded bodies in memory.
function Client:retain_in_memory_pending(entry)
	if type(entry.body) ~= "string" or #entry.body > max_in_memory_body_bytes then
		-- An oversized body was already refused by the durable store for
		-- the same reason; the fallback honors the same per-record cap.
		return nil
	end
	local function seq_of(token)
		return tonumber(token:match("^mem:(%d+)$")) or 0
	end
	local count = 0
	local total_bytes = #entry.body
	for _, held in pairs(self.in_memory_pending) do
		count = count + 1
		total_bytes = total_bytes + (type(held.body) == "string" and #held.body or 0)
	end
	while count >= max_in_memory_pending or total_bytes > max_in_memory_total_bytes do
		local victim, victim_seq = nil, nil
		for held_token, held in pairs(self.in_memory_pending) do
			if held.fatal ~= true and (victim_seq == nil or seq_of(held_token) < victim_seq) then
				victim, victim_seq = held_token, seq_of(held_token)
			end
		end
		if not victim then
			if entry.fatal ~= true then
				-- Only fatal entries remain and the newcomer is non-fatal:
				-- the newcomer is the lowest-value report — drop it.
				return nil
			end
			for held_token in pairs(self.in_memory_pending) do
				if victim_seq == nil or seq_of(held_token) < victim_seq then
					victim, victim_seq = held_token, seq_of(held_token)
				end
			end
		end
		if not victim then
			break
		end
		local evicted = self.in_memory_pending[victim]
		total_bytes = total_bytes - (type(evicted.body) == "string" and #evicted.body or 0)
		self.in_memory_pending[victim] = nil
		count = count - 1
	end
	self.in_memory_pending_seq = self.in_memory_pending_seq + 1
	local token = "mem:" .. tostring(self.in_memory_pending_seq)
	self.in_memory_pending[token] = entry
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
-- resent — the guarantee holds for both stores. `clear_retry_after` additionally
-- drops the stored backpressure deadline (used for an ACCEPTED send).
function Client:remove_pending(token, clear_retry_after)
	if type(token) ~= "string" then
		return
	end
	if token:sub(1, 4) == "mem:" then
		self:remove_in_memory_pending(token)
		if clear_retry_after == true then
			storage.set_pending_crash_retry_after(self:pending_scope(), nil)
		end
	else
		storage.remove_pending_crash(self:pending_scope(), token, clear_retry_after == true)
	end
end

-- Decode a server JSON body when a decoder is available (the real Defold runtime
-- exposes json.decode; the test stub may not). Returns the decoded table or nil;
-- never throws — a 2xx with an unparseable body is still an accepted crash.
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

-- Surface the server's per-crash response from an accepted (2xx) send instead of
-- discarding it: a `suppressed` crash was accepted but NOT stored (the actor withheld
-- consent), and `warnings` are non-fatal processing notices. Both are exposed via
-- snapshot(). Returns true iff the crash was suppressed, so the caller keeps it OUT of
-- the accepted (delivered-and-stored) total. A 2xx with an unparseable body is not
-- suppressed (returns false) and counts as a normal acceptance.
function Client:record_accepted_response(response)
	local result = decode_body(type(response) == "table" and response.response or nil)
	if not result then
		return false
	end
	if type(result.warnings) == "table" and type(result.warnings[1]) == "string" then
		self.stats.last_warning = result.warnings[1]
	end
	if result.suppressed == true then
		self.stats.suppressed = self.stats.suppressed + 1
		return true
	end
	return false
end

-- Record a server-instructed Retry-After (whole seconds, from a 429/503) for
-- observability. A pending report is resent on a later launch, well past any
-- seconds-scale wait, so this is surfaced via snapshot() rather than used as an
-- in-process backoff.
function Client:record_retry_after(retry_after)
	if type(retry_after) == "number" and retry_after >= 0 then
		self.stats.last_retry_after = retry_after
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
	if not fatal and not should_emit(self, prepared) then
		self.stats.sampled_out = self.stats.sampled_out + 1
		return true
	end
	-- Write-ahead durability for EVERY report that reached dispatch (a fatal
	-- crash, a sampled-in non-fatal, a one-shot dump forward alike): encode
	-- the wire body ONCE and persist it to the per-app sidecar BEFORE the
	-- send attempt — the process may die during (or before) the send, and a
	-- dump-sourced report is already consumed from the engine's store. The
	-- entry is removed only once the send is accepted or terminally
	-- rejected; a retryable failure leaves it persisted, and the next launch
	-- resends the SAME bytes (the stable crash_id embedded in the body lets
	-- the crash ingest service de-duplicate a report that was delivered but
	-- not observed as acknowledged).
	local entry = { report = prepared, fatal = fatal == true, crash_id = prepared.crash_id }
	local body = transport.encode(prepared)
	local pending_token = nil
	if body then
		entry.body = body
		pending_token = storage.save_pending_crash(self:pending_scope(), entry)
		if pending_token then
			self.stats.persisted = self.stats.persisted + 1
		else
			-- On-disk persistence can fail durably (storage quota / failure /
			-- an oversized body / no save-file API on this host). Dropping
			-- the report here would lose it permanently if the send below
			-- also fails. Fall back to a BOUNDED in-session in-memory pending
			-- entry so an in-session resend pass can still retry it.
			-- (Best-effort: the in-memory copy does NOT survive a process
			-- restart, and a non-fatal newcomer may not be admitted at all;
			-- disk is the durable path.) The report is still dispatched below
			-- either way.
			self.stats.persist_failed = self.stats.persist_failed + 1
			pending_token = self:retain_in_memory_pending(entry)
		end
	end
	-- (When no JSON encoder is available, nothing can be persisted OR sent;
	-- the dispatch below routes through the transport so the failure is
	-- accounted exactly as before.)
	entry.token = pending_token
	if merged_options.defer_dispatch == true and pending_token then
		-- The caller runs the serial resend pass next: the report is queued
		-- (durably, or in the session fallback) and dispatches IN ORDER
		-- behind any older backlog, under the same one-at-a-time
		-- backpressure discipline — never concurrently with it.
		return true
	end
	return self:dispatch_pending(entry)
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
	local event = dump.load_previous_event(crash_module)
	if not event then
		-- No new dump: just resend whatever a previous launch left pending.
		self:resend_pending()
		return true, false
	end
	-- Dump frames carry no symbols (native addresses) and the modules come from
	-- the trusted engine module list, so the function-scrub tier is irrelevant
	-- here; forward as a fatal report so it is never sampled away. The dump is from
	-- the DEAD previous session and carries no breadcrumbs of its own — suppress
	-- attaching the current session's breadcrumb ring, which would otherwise
	-- misattribute this session's breadcrumbs to the previous crash.
	--
	-- The prepared report persists write-ahead (the dump is one-shot and
	-- already consumed, so this is the only copy) and defer_dispatch QUEUES
	-- it behind any older pending backlog: the single serial pass below
	-- sends everything oldest-first, one report at a time — the transport is
	-- async, so dispatching the dump directly here would race the pass and
	-- escape the one-at-a-time backpressure discipline.
	local ok, err = self:emit_internal(event, true, true,
		{ skip_breadcrumb_ring = true, defer_dispatch = true })
	if not ok then
		self:resend_pending()
		return false, err
	end
	self:resend_pending()
	return true, true
end

-- Resend the crash reports persisted by an earlier launch (or retained
-- in-session after a failed persist), STRICTLY ONE AT A TIME, oldest first:
-- the next report is dispatched only from the previous one's settlement, so
-- a 429/Retry-After (or any retryable failure) stops the whole pass instead
-- of racing every pending report into backpressure. Each entry is already
-- durable (persisted before its first dispatch); it is dispatched in place
-- and removed only once the resend is accepted or terminally rejected, so an
-- app kill mid-pass loses nothing and a partial delivery resumes on the next
-- launch. A stored Retry-After deadline (persisted when the server throttled
-- an earlier send) defers the pass until it expires — it survives relaunches
-- and self-cleans when spent or absurd. One pass runs at a time.
function Client:resend_pending()
	if not self.initialized then
		return false, "shutdown"
	end
	if self.resend_active then
		-- A pass is already running; it covers the current backlog.
		return true
	end
	local queue = {}
	local entries, deadline = storage.load_pending_entries(self:pending_scope())
	if type(entries) == "table" then
		for _, entry in ipairs(entries) do
			if type(entry) == "table" and type(entry.token) == "string" and
				(type(entry.body) == "string" or type(entry.report) == "table") then
				queue[#queue + 1] = entry
			end
		end
	end
	-- In-session in-memory fallback entries (reports that could not be
	-- persisted to disk) go after the on-disk backlog: the disk entries are
	-- from earlier launches and therefore older. Snapshot the tokens before
	-- dispatching: a synchronous transport stub may settle and remove the
	-- entry mid-iteration.
	local mem_tokens = {}
	for token in pairs(self.in_memory_pending) do
		mem_tokens[#mem_tokens + 1] = token
	end
	-- Numeric order by the minted sequence: a lexicographic sort would send
	-- "mem:10" before "mem:3" and let a mid-pass 429 skip older reports.
	table.sort(mem_tokens, function(left, right)
		return (tonumber(left:match("^mem:(%d+)$")) or 0) < (tonumber(right:match("^mem:(%d+)$")) or 0)
	end)
	for _, token in ipairs(mem_tokens) do
		local entry = self.in_memory_pending[token]
		if type(entry) == "table" then
			queue[#queue + 1] = {
				token = token,
				body = entry.body,
				report = entry.report,
				fatal = entry.fatal,
			}
		end
	end
	if #queue == 0 then
		-- Nothing pending: any surfaced deferral is over too.
		self.stats.resend_deferred_until_ms = nil
		return true
	end
	if type(deadline) == "number" then
		-- Server backpressure from an earlier send is still in force (the
		-- stored deadline reads as nil once spent): defer the whole pass and
		-- surface the deadline. The reports stay durable; a later
		-- resend_pending() — typically the next launch — retries.
		self.stats.resend_deferred_until_ms = deadline
		return true
	end
	self.stats.resend_deferred_until_ms = nil
	self.resend_active = true
	local index = 0
	local function step()
		index = index + 1
		if index > #queue then
			self.resend_active = false
			return
		end
		local entry = queue[index]
		-- The settlement callback fires exactly once on EVERY dispatch path
		-- — an async transport answer and a synchronous setup failure alike
		-- — and is the ONLY thing that advances or stops the pass. Acting on
		-- the return value as well would race it: a synchronous failure has
		-- already advanced the chain (possibly starting the next async POST)
		-- by the time dispatch_pending returns.
		self:dispatch_pending(entry, function(stop_pass)
			if stop_pass then
				-- Retryable failure (or a client no longer able to send):
				-- keep this and every remaining report durable for a later
				-- pass.
				self.resend_active = false
				return
			end
			step()
		end)
	end
	step()
	return true
end

-- Dispatch one pending entry — the exact persisted wire body when present
-- (byte-identical to the original attempt), or a legacy prepared-report
-- table encoded at dispatch. Mirrors the in-flight bookkeeping and stats of
-- a fresh emit. `entry.token` (when set) addresses the pending copy: it is
-- removed once the send is accepted (clearing any stored backpressure
-- deadline — the endpoint is taking traffic again) or terminally rejected,
-- and left in place on a retryable failure so a later pass resends it; a
-- server Retry-After on a retryable failure is persisted with the pending
-- record so the backpressure window survives a relaunch. `on_settled`
-- (optional) is invoked from the transport callback with stop_pass=true on a
-- retryable failure and false otherwise — the serial resend pass uses it to
-- advance or stop.
function Client:dispatch_pending(entry, on_settled)
	if not self.initialized or type(entry) ~= "table" then
		-- The settlement contract holds on every path: stop the pass (the
		-- client cannot send anymore, or the entry is unusable) so a serial
		-- pass never wedges with its active flag set.
		if on_settled then
			on_settled(true)
		end
		return false, "invalid_event"
	end
	local pending_token = entry.token
	-- ADOPT a legacy entry (a prepared-report table persisted by an older
	-- build) into the byte-identical contract at its FIRST resend: encode
	-- once and refresh the stored entry in place under the same token, so a
	-- retryable failure retries the SAME bytes on every later attempt
	-- instead of re-encoding the table each time (table key order is not
	-- guaranteed stable across encodes/runtimes). A failed refresh only
	-- costs that guarantee for this entry — the dispatch below proceeds
	-- with the just-encoded body either way.
	if type(entry.body) ~= "string" and type(entry.report) == "table" then
		local adopted = transport.encode(entry.report)
		if adopted then
			entry.body = adopted
			local crash_id = entry.crash_id
			if type(crash_id) ~= "string" then
				crash_id = type(entry.report.crash_id) == "string" and entry.report.crash_id or nil
			end
			if type(pending_token) == "string" and pending_token:sub(1, 4) ~= "mem:" then
				storage.save_pending_crash(self:pending_scope(),
					{ body = adopted, crash_id = crash_id, fatal = entry.fatal == true },
					pending_token)
			end
		end
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

	local function handle(ok, transport_err, unauthorized, retryable, response, retry_after)
		settle()
		if ok then
			if not self:record_accepted_response(response) then
				self.stats.accepted = self.stats.accepted + 1
			end
			-- The send was accepted: the pending copy is no longer needed,
			-- and any stored backpressure window is over — the endpoint just
			-- took traffic. The window clears even for a TOKENLESS send
			-- (one whose write-ahead persist was rejected outright): a stale
			-- window left behind would keep deferring resend passes the
			-- server is ready for.
			if pending_token then
				self:remove_pending(pending_token, true)
			else
				storage.set_pending_crash_retry_after(self:pending_scope(), nil)
			end
			if on_settled then
				on_settled(false)
			end
			return
		end
		self.stats.failed = self.stats.failed + 1
		self.stats.last_error = transport_err
		if not unauthorized and not retryable then
			self.stats.rejected = self.stats.rejected + 1
		end
		self:record_retry_after(retry_after)
		-- A retryable failure leaves the pending copy in place (on-disk for a
		-- later launch, or in-memory for an in-session pass). A server
		-- Retry-After is persisted with the pending record so the
		-- backpressure window survives a relaunch (clamped to one day; only
		-- an explicit server hint is persisted). A non-retryable reject is
		-- terminal: remove the pending copy so it is not retried forever.
		if retryable then
			if type(retry_after) == "number" and retry_after > 0 then
				storage.set_pending_crash_retry_after(self:pending_scope(), retry_after)
			end
		elseif pending_token then
			self:remove_pending(pending_token)
		end
		diagnose(self, {
			scope = "crash",
			status = unauthorized and "unauthorized" or "rejected",
			code = transport_err,
			retryable = retryable,
			retry_after = type(retry_after) == "number" and retry_after or nil,
			response = type(response) == "table" and response.status or nil,
		})
		if on_settled then
			on_settled(retryable == true)
		end
	end

	local dispatched
	if type(entry.body) == "string" and entry.body ~= "" then
		dispatched = transport.ingest_body(self.config, self.config.crash_api_key, entry.body, handle)
	else
		-- A legacy pending entry (or a fresh report whose encode failed —
		-- the transport then reports the same setup failure it always did).
		dispatched = transport.ingest(self.config, self.config.crash_api_key, entry.report, handle)
	end
	if not dispatched then
		-- The transport reported a synchronous setup failure (no http/json,
		-- encode error). Every transport path invokes the callback (which
		-- already settled the in-flight count and recorded the error), but
		-- call settle() once more as a guarded no-op so a missed callback can
		-- never wedge the count and block shutdown forever.
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
