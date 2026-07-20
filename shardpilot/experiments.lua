-- Experiment-assignment consumer (ADR-0259 SDK leg): GETs the server-evaluated
-- assignment for one (app, environment, experiment, subject) tuple from the
-- control-plane assignment endpoint and serves the assigned variant to game
-- code, with a durable last-known-good cache, periodic revalidation (the
-- SDK-side kill-switch reach), and an exposure-fact lane riding the normal
-- analytics pipeline. Deliberately separate from shardpilot/remote_config.lua
-- (a different endpoint with different fail-closed rules) but mirroring its
-- transport discipline: publishable-key bearer auth, injective percent
-- escaping, scope-stamped cache with corrupt = miss, per-key sequence fencing
-- for out-of-order responses, and exactly-once pcall-guarded callbacks.
--
-- DARK BY DEFAULT. This module is constructed only when the config sets
-- `experiments_enabled = true`; the flag defaults to false and while it is
-- off ZERO experiment code paths execute — no subject-id mint, no assignment
-- fetch, no revalidation timer, no exposure emit, no new persistence keys.
-- The server side is equally dark: while the platform flags are off the
-- endpoint answers 403, which this client treats fail-closed exactly like bad
-- auth. Flipping the SDK flag on for real traffic is governed by the platform
-- flag-flip registry preconditions, not by this module.
--
-- Wire contract (assignment fetch):
--   GET {remote_config_url}/api/v1/runtime/experiments/assignment
--     ?app_key=&environment_key=&experiment_key=&subject_key=&<attributes>
--   Authorization: Bearer <publishable api_key>   (same credential as the
--   remote-config fetch; the endpoint requires the experiment-assignment
--   read scope on that key, granted server-side)
-- The base URL is the configured `remote_config_url` — the control-plane
-- host — with the path swapped; no new endpoint configuration exists.
--
-- Outcomes (decided by M.apply, pure):
--   * 200 assigned — the variant is served and cached (memory + durable).
--     Assignment stickiness is entirely the server's deterministic hash; the
--     cache is a latency/offline device, never an assignment authority, and
--     this client never re-buckets locally.
--   * 200 not-assigned — three shapes distinguished only by `reason`:
--     absent (deterministic traffic-gate miss), "targeting_unmatched" (may
--     change when attributes change), "kill_switch" (operator kill). All
--     three drop the cached assignment for the experiment; a kill
--     additionally guarantees no exposure is emitted for it.
--   * 401/403 — fail CLOSED: the result never serves a cached assignment,
--     in-memory serving stops (getters return nil) and revalidation halts
--     until re-init or a later successful, authorized fetch. The durable
--     cache record itself is left untouched (remote-config parity) EXCEPT
--     for the server's real-subjects kill sentinel ("experiment real-subject
--     assignment is disabled"), which additionally drops the durable record
--     — the platform flipped the real-subjects flag back off, and the cached
--     assignment plus its subject-fact key must not outlive that.
--   * 404 — permanent for the experiment: treated as not-assigned, the
--     cached assignment is dropped and never served stale, and revalidation
--     stops asking for that key (the drop removes it from the cache).
--   * 400 — permanent for this input set. One special case: the subject-id
--     grammar sentinel with an SDK-minted subject id re-mints the id ONCE
--     per process and retries (a conforming mint that still 400s is a bug,
--     surfaced through diagnostics, never a retry loop).
--   * 503 / 429 / 5xx / offline / timeout / malformed — transient: the
--     cached assignment is served (`from_cache = true`, `error` carrying the
--     reason) and the revalidation cadence backs off; `Retry-After` is
--     honored on 429 AND 5xx exactly like the batch/receipt transports. An
--     offline client keeps its last-known-good variant indefinitely — the
--     documented kill-latency caveat.
--
-- Subject id (`spcid_`): SDK-minted and SDK-managed — "spcid_" plus the 32
-- lowercase hex chars of a UUIDv7 with the dashes removed. There is NO host
-- override path: no public setter and no config field is read for it. It is
-- persisted in the durable identity record, minted lazily the first time a
-- fetch needs it, validated against the wire grammar on load, and re-minted
-- only on storage loss/corruption (re-bucketing, same as a fresh install).
-- It is NOT the anonymous id (the remote-config identity is unchanged), and
-- it egresses ONLY as the assignment fetch's subject_key — never in
-- analytics events, in any props, or as an envelope identity.
--
-- Consent posture (assignment plane): fetches are GRANTED-ONLY — while
-- analytics consent is unknown or denied (either denial flavor, including
-- the age-gate-forced one) no assignment request is made, no subject id is
-- minted, nothing is served (getters return nil) and the revalidation timer
-- does not run, so a forced-minor session produces ZERO experiment traffic
-- on both planes. Experiments therefore require analytics consent by
-- design: an assignment whose exposure can structurally never land is dead
-- weight, and serving it would corrupt experiment population integrity.
-- This is deliberately stricter than the remote-config fetch (which is not
-- consent-gated). A consent downgrade mid-session stops fetching and
-- serving; the durable cache record is retained but not served (the same
-- posture as the remote-config 401/403 rule: fail closed without destroying
-- the record), and a later re-grant serves it again.
--
-- Exposure lane (analytics plane): `experiment_exposure` facts ride the
-- normal event pipeline (queue → batch → spool → consent gates) with the
-- strict server-side props allowlist. Emission timing is a PROPOSED SDK
-- convention pending platform ratification: at most once per
-- (experiment_key, experiment_version, subject) per session, emitted when
-- the assigned variant is first applied (a fresh fetch resolution, or the
-- first tick serving a cache-restored assignment), with a deterministic
-- event_id so at-least-once retries collapse server-side as duplicates.
-- `track_exposure` is the explicit re-arm escape hatch (a re-arm mints a
-- distinct deterministic id). The `assignment_key` prop carries the
-- server-minted subject-fact key VERBATIM for client_id-unit assignments
-- (the raw subject id is structurally rejected there) and the subject key
-- for synthetic-unit ones. NOTE: the analytics service currently rejects
-- these event names from game-embedded publishable keys by design; until
-- the platform's producer-lane decision lands, an emitted exposure is
-- expected to come back as a per-event reject, surfaced through diagnostics
-- and tolerated silently otherwise. That server-side block is load-bearing
-- and this SDK deliberately relies on it staying authoritative.

local clock = require "shardpilot.clock"
local id = require "shardpilot.id"
local storage = require "shardpilot.storage"

local M = {}

local assignment_route = "/api/v1/runtime/experiments/assignment"

local scope_separator = "\31"

-- Revalidation cadence (the SDK's contribution to the kill-switch reach):
-- re-issue the assignment GET for every cached entry, batched per tick, every
-- 300 seconds with ±10% uniform jitter. The endpoint has no conditional
-- requests (no ETag), so revalidation is a plain re-fetch. 300s aligns with
-- the remote-config max-age default; the kill latency this cadence bounds is
-- stated honestly: an offline client keeps its variant indefinitely.
local revalidate_interval_seconds = 300
local revalidate_jitter = 0.1

-- Transient-failure backoff for the revalidation cadence (transport parity
-- with the batch/receipt paths): full jitter in [base, ceiling], ceiling
-- doubling per consecutive failure up to the cap; a server Retry-After
-- (clamped to one day) overrides the computed wait.
local backoff_base_seconds = 1
local backoff_cap_seconds = 60
local max_defer_seconds = 86400

-- The server-evaluated targeting attribute vocabulary: the fixed allowlist
-- plus the custom_attribute_<name> family (suffix 1-64 chars). Names outside
-- it are never sent (the client must not invent attribute names); values are
-- trimmed and bounded to 512 bytes, and at most 64 attributes ride one fetch
-- (sorted-key order, matching the server's own consideration order). All
-- targeting is server-evaluated; supplying attributes is the client's whole
-- obligation.
local allowed_attributes = {
	geo = true,
	app_version = true,
	device_type = true,
	install_date = true,
	user_segment = true,
}
local custom_attribute_prefix = "custom_attribute_"
local max_attribute_value_bytes = 512
local max_attributes = 64

-- Server error sentinels this client reacts to by text (the error contract
-- distinguishes same-status outcomes only by the body's `error` string).
local sentinel_real_subjects_disabled = "experiment real-subject assignment is disabled"
local sentinel_subject_grammar = "experiment metadata must use synthetic local-safe identifiers only"

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

-- Percent-escape everything outside the RFC 3986 unreserved set (injective;
-- shared discipline with the remote-config URL builder) so an identifier or
-- attribute value cannot smuggle extra query structure into the fetch URL.
local function escape_component(value)
	return (value:gsub("[^%w%-%._~]", function(ch)
		return string.format("%%%02X", string.byte(ch))
	end))
end

-- ── subject id ────────────────────────────────────────────────────────────────

-- The wire grammar for a client subject id. Accepting the full grammar on
-- load (not just the SDK's own 32-hex body) keeps a stored id sticky across
-- SDK upgrades: re-minting re-buckets, so an id that is still wire-valid is
-- never discarded.
function M.valid_subject_id(value)
	if type(value) ~= "string" then
		return false
	end
	if #value < 26 or #value > 70 then
		return false
	end
	return value:match("^spcid_[%w_%-]+$") ~= nil
end

-- Mint a fresh subject id: "spcid_" + the SDK's UUIDv7 with dashes removed
-- (32 lowercase hex chars, 38 chars total — inside the wire grammar's 20-64
-- body bound and charset).
function M.mint_subject_id()
	return "spcid_" .. (id.uuid_v7():gsub("%-", ""))
end

-- ── URL, scope, attributes ────────────────────────────────────────────────────

-- `query` is an ordered array of { name, value } pairs; both sides are
-- escaped, so a value containing "&", "=", or "#" cannot restructure the
-- query string.
function M.build_url(base_url, query)
	local parts = {}
	for i = 1, #query do
		parts[#parts + 1] = escape_component(query[i].name) .. "=" .. escape_component(query[i].value)
	end
	return trim_slash(base_url) .. assignment_route .. "?" .. table.concat(parts, "&")
end

-- Cache-scope discipline shared with the remote-config client: components are
-- escaped and joined with a separator no escaped component can contain, so two
-- distinct (workspace, environment, subject, url) tuples can never collide
-- into one scope string. The experiment key is deliberately NOT part of the
-- base scope — entries are keyed by it inside the record, so the full cache
-- key is the (scope, experiment_key) pair.
function M.build_scope(workspace_id, environment_id, subject_id, base_url)
	return escape_component(workspace_id or "") .. scope_separator
		.. escape_component(environment_id or "") .. scope_separator
		.. escape_component(subject_id or "") .. scope_separator
		.. trim_slash(base_url or "")
end

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function valid_attribute_name(name)
	if type(name) ~= "string" then
		return false
	end
	if allowed_attributes[name] then
		return true
	end
	if name:sub(1, #custom_attribute_prefix) == custom_attribute_prefix then
		local suffix = #name - #custom_attribute_prefix
		return suffix >= 1 and suffix <= 64
	end
	return false
end

-- Normalize host-supplied targeting attributes into the ordered { name,
-- value } pairs a fetch sends: names outside the vocabulary and unusable
-- values are DROPPED (counted for diagnostics), never sent — an invented name
-- would be ignored server-side at best, and an oversized value would fail the
-- whole fetch whenever the experiment carries a targeting condition. Dropping
-- fails toward targeting_unmatched, the safe direction. Values are trimmed;
-- strings stay verbatim, numbers and booleans are stringified. The surviving
-- pairs are sorted by name and capped at 64 (drop beyond the cap, in that
-- same order — mirroring the server's sorted-key consideration).
function M.normalize_attributes(attributes)
	local pairs_out = {}
	local dropped = 0
	if type(attributes) ~= "table" then
		return pairs_out, 0
	end
	local names = {}
	for name in pairs(attributes) do
		names[#names + 1] = name
	end
	table.sort(names, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for i = 1, #names do
		local name = names[i]
		local value = attributes[name]
		local value_type = type(value)
		local text = nil
		if value_type == "string" then
			text = trim(value)
		elseif value_type == "number" or value_type == "boolean" then
			text = tostring(value)
		end
		if not valid_attribute_name(name) or text == nil or text == ""
			or #text > max_attribute_value_bytes then
			dropped = dropped + 1
		elseif #pairs_out >= max_attributes then
			dropped = dropped + 1
		else
			pairs_out[#pairs_out + 1] = { name = name, value = text }
		end
	end
	return pairs_out, dropped
end

-- ── response handling ─────────────────────────────────────────────────────────

-- Decode a JSON object body; nil for anything unusable. Objectness is checked
-- on the text (an empty array decodes to the same Lua table as an empty
-- object). Never throws.
local function decode_object(body)
	if type(body) ~= "string" or body == "" then
		return nil
	end
	if not body:match("^%s*{") then
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

-- The real Defold http API lowercases response header keys; the test mock may
-- not. Returns the Retry-After header as non-negative whole seconds, or nil.
local function retry_after_seconds(response)
	if type(response) ~= "table" or type(response.headers) ~= "table" then
		return nil
	end
	local value = response.headers["retry-after"] or response.headers["Retry-After"]
	if type(value) == "number" then
		if value < 0 then
			return nil
		end
		return math.floor(value)
	end
	if type(value) ~= "string" then
		return nil
	end
	local seconds = tonumber(value:match("^%s*(%d+)%s*$"))
	if not seconds then
		return nil
	end
	return math.floor(seconds)
end

-- Depth-bounded copy of a decoded JSON value, so a table handed to game code
-- can be mutated freely without corrupting the cached entry later reads use.
local function copy_value(value, depth)
	if type(value) ~= "table" then
		return value
	end
	if depth >= 16 then
		return nil
	end
	local out = {}
	for key, child in pairs(value) do
		out[key] = copy_value(child, depth + 1)
	end
	return out
end

-- The body `error` string of a non-2xx answer, or nil.
local function response_error_text(response)
	local decoded = decode_object(type(response) == "table" and response.response or nil)
	if decoded and type(decoded.error) == "string" then
		return decoded.error
	end
	return nil
end

-- Serve the cached entry for a transient failure, or fail when none exists. A
-- served entry is still a SUCCESS (`ok = true`) — the game has a usable
-- assignment — with `from_cache = true` and `error` carrying why the network
-- could not refresh it. Only assigned entries are ever cached, so a cache
-- serve always carries a variant.
local function serve_entry_or_fail(entry, error_code)
	if entry then
		return {
			ok = true,
			from_cache = true,
			assigned = true,
			variant_key = entry.variant_key,
			variant_payload = copy_value(entry.variant_payload, 0),
			version = entry.version,
			error = error_code,
		}
	end
	return { ok = false, from_cache = false, error = error_code }
end

-- Decide one fetch outcome from the transport response and the cached entry.
-- Pure (no IO, no state) so tests can drive every branch. Returns
-- (result, outcome) where outcome directs the stateful install:
--   * authoritative — settles the per-key sequence fence (a fresh 200 in any
--     shape, 401/403, 404, and other permanent errors); transient/cache
--     outcomes do not, so they cannot fence off a fresh response in flight;
--   * new_entry — cache this assignment (exists exactly for 200 assigned);
--   * drop_entry / drop_all — drop the experiment's cached assignment (every
--     not-assigned shape, 404) / drop the whole durable record (the
--     real-subjects kill sentinel);
--   * auth_blocked — 401/403: stop serving and stop revalidating, fail
--     closed;
--   * remint — the subject-grammar 400 sentinel: the caller may re-mint the
--     subject id once and retry;
--   * transient + retry_after_seconds — pace the revalidation backoff and
--     honor a server Retry-After (429 and 5xx alike).
function M.apply(entry, response, now_ms)
	local status = type(response) == "table" and response.status or 0

	if status == 200 then
		local decoded = decode_object(type(response) == "table" and response.response or nil)
		if not decoded then
			return serve_entry_or_fail(entry, "malformed_response"), { transient = true }
		end
		local boundary = type(decoded.boundary) == "table" and decoded.boundary or nil
		local assignment_unit = boundary and boundary.assignment_unit or nil
		if decoded.assigned == true
			and type(decoded.assignment_key) == "string" and decoded.assignment_key ~= ""
			and type(decoded.variant_key) == "string" and decoded.variant_key ~= ""
			and type(decoded.version) == "number"
			and type(assignment_unit) == "string" and assignment_unit ~= "" then
			local new_entry = {
				assignment_key = decoded.assignment_key,
				variant_key = decoded.variant_key,
				variant_payload = copy_value(decoded.variant_payload, 0),
				version = decoded.version,
				assignment_unit = assignment_unit,
				subject_fact_key = type(decoded.subject_fact_key) == "string"
					and decoded.subject_fact_key ~= "" and decoded.subject_fact_key or nil,
				fetched_at_ms = now_ms,
			}
			return {
				ok = true,
				from_cache = false,
				assigned = true,
				variant_key = decoded.variant_key,
				variant_payload = copy_value(decoded.variant_payload, 0),
				version = decoded.version,
				boundary = copy_value(boundary, 0),
			}, { authoritative = true, new_entry = new_entry }
		end
		if decoded.assigned == false then
			-- The three not-assigned shapes, distinguished only by `reason`
			-- (absent = deterministic traffic-gate miss; unknown reason
			-- strings pass through untouched — additive evolution). Every
			-- shape drops the cached assignment: the server just said this
			-- subject has no variant NOW, and a kill in particular must stop
			-- applying at the next safe point and emit no exposure.
			return {
				ok = true,
				from_cache = false,
				assigned = false,
				reason = type(decoded.reason) == "string" and decoded.reason or nil,
				version = type(decoded.version) == "number" and decoded.version or nil,
				boundary = copy_value(boundary, 0),
			}, { authoritative = true, drop_entry = true }
		end
		return serve_entry_or_fail(entry, "malformed_response"), { transient = true }
	end

	-- Unauthorized / forbidden fail CLOSED (a dark server, a revoked or
	-- unscoped key, a suspended tenant — indistinguishable here, all must
	-- stop serving): the cached record is never served for this outcome and
	-- revalidation halts. The durable record is kept EXCEPT under the
	-- real-subjects kill sentinel, which drops it — the assignment and its
	-- subject-fact key must not outlive the platform flipping that flag off.
	if status == 401 or status == 403 then
		local outcome = { authoritative = true, auth_blocked = true }
		if status == 403 and response_error_text(response) == sentinel_real_subjects_disabled then
			outcome.drop_all = true
		end
		return { ok = false, from_cache = false, error = "unauthorized" }, outcome
	end

	-- Unknown experiment key or nothing published in scope: permanent for
	-- this key. Treated as a first-class not-assigned answer (the host's
	-- actionable outcome is identical: no variant), with `error` carrying the
	-- diagnosis; the cached assignment is dropped, never served stale, and
	-- the drop stops revalidation from re-asking.
	if status == 404 then
		return {
			ok = true,
			from_cache = false,
			assigned = false,
			error = "not_found",
		}, { authoritative = true, drop_entry = true }
	end

	-- Bad inputs are permanent for this input set — retrying unchanged cannot
	-- help. The one self-healing case: the subject-grammar sentinel with an
	-- SDK-minted id means the persisted id went bad; the caller re-mints once
	-- (fresh-install semantics) and retries.
	if status == 400 then
		local outcome = { authoritative = true }
		if response_error_text(response) == sentinel_subject_grammar then
			outcome.remint = true
		end
		return { ok = false, from_cache = false, error = "bad_request" }, outcome
	end

	-- Transient bucket: no connection, timeout, backpressure, or any server
	-- error — including the 503 the endpoint answers when its kill-state read
	-- fails (an explicit serve-stale-and-retry case). Retry-After is honored
	-- on 429 and 5xx alike.
	if status == 0 then
		return serve_entry_or_fail(entry, "http_0"), { transient = true }
	elseif status == 408 then
		return serve_entry_or_fail(entry, "transient_408"), { transient = true }
	elseif status == 429 or status >= 500 then
		return serve_entry_or_fail(entry, "transient_" .. tostring(status)),
			{ transient = true, retry_after_seconds = retry_after_seconds(response) }
	end

	-- Anything else (an unexpected redirect, another 4xx) is an authoritative
	-- "no assignment is served here": fail without serving stale values; the
	-- cached record stays untouched.
	return { ok = false, from_cache = false, error = "http_" .. tostring(status) },
		{ authoritative = true }
end

-- ── exposure event id ─────────────────────────────────────────────────────────

local function hash32(text, seed, mult)
	local hash = seed
	for i = 1, #text do
		hash = (hash * mult + text:byte(i)) % 4294967296
	end
	return hash
end

-- Deterministic exposure event id (PROPOSED convention, see the module
-- header): a stable digest of (session marker, subject, experiment, version,
-- arm counter) — exactly the de-dupe tuple plus the session marker and the
-- re-arm counter, so the id-uniqueness domain and the de-dupe domain
-- coincide. The same tuple always derives the same id, so an accidental
-- double emission inside one session collapses server-side as a duplicate
-- even if the assignment key was regenerated between the two; an explicit
-- re-arm bumps the counter, and a rotated session marker or re-minted
-- subject derives a distinct id. Retries of one emitted fact are idempotent
-- regardless — the id is stamped once at enqueue and the spool re-sends it
-- verbatim.
function M.exposure_event_id(session_marker, subject_key, experiment_key, version, arm)
	local text = table.concat({
		"exposure",
		tostring(session_marker),
		tostring(subject_key),
		tostring(experiment_key),
		string.format("%.0f", version),
		string.format("%.0f", arm),
	}, "\31")
	return string.format("%08x-%04x-%04x-%04x-%08x%04x",
		hash32(text, 2166136261, 131),
		hash32(text, 5381, 33) % 65536,
		hash32(text, 0, 65599) % 65536,
		hash32(text, 40503, 257) % 65536,
		hash32(text, 8675309, 131),
		hash32(text, 1013904223, 33) % 65536)
end

-- ── the consumer ──────────────────────────────────────────────────────────────

local Experiments = {}
Experiments.__index = Experiments

-- `config` is the client's normalized configuration. `deps` wires the client
-- without import cycles:
--   * subject_id()          — the persisted subject-id candidate (raw);
--   * store_subject_id(v)   — adopt + persist a minted id (returns success);
--   * consent()             — the CURRENT analytics consent state;
--   * emit(name, props, id) — enqueue one experiment fact on the analytics
--                             pipeline (consent-gated there, identity rules
--                             applied there).
function M.new(config, deps)
	local ex = setmetatable({
		config = config,
		deps = deps,
		-- In-memory serving cache: experiment_key → entry. Only assigned
		-- entries exist here; every not-assigned outcome drops its key.
		entries = {},
		-- Applications whose exposure fact is still OWED this session:
		-- experiment_key → the applied entry snapshot. Swept on tick while
		-- consent is granted. The snapshot — not the serving cache — is the
		-- emission source, so an owed fact for a variant that really ran
		-- survives a later drop of the live entry (a kill stops future
		-- serving, not the record of an application that already happened).
		pending_exposure = {},
		-- Durable-write convergence: experiment_key → as-of stamp of an
		-- OWED write (memory changed, disk did not), retried every tick;
		-- plus an owed whole-record clear.
		durable_pending = {},
		durable_clear_pending = false,
		-- Set by teardown(): an in-flight response landing afterwards must
		-- not install, persist, pace, or call back into game code.
		torn_down = false,
		-- Session-scoped exposure dedup: tuple key → { arm }.
		exposed = {},
		-- One marker per constructed consumer (= per SDK session): part of
		-- the deterministic exposure id, so each session's first application
		-- emits its own fact while duplicates within the session collapse.
		session_marker = id.uuid(),
		-- Per-(scope, experiment) sequence fence for out-of-order responses,
		-- remote-config discipline: only an outcome newer than every settled
		-- one for its key may install.
		fetch_seq = 0,
		settled = {},
		-- Fail-closed latch: set by 401/403, cleared by re-init or a later
		-- authoritative, authorized outcome of a fetch STARTED AFTER the
		-- latch was set. While set, nothing is served and revalidation
		-- halts; an explicit host fetch stays allowed (the user-triggered
		-- path) and its success unlatches. `auth_epoch` counts latch events:
		-- every fetch captures it at dispatch and an outcome whose captured
		-- epoch is stale is discarded outright — with a batch of
		-- revalidations in flight, one 401 must not be undone (and revoked
		-- assignments must not be reinstalled) by a sibling response that
		-- was already in flight when the latch landed.
		auth_blocked = false,
		auth_epoch = 0,
		-- Revalidation cadence state.
		revalidate_at_ms = nil,
		retry_after_ms = nil,
		backoff_attempt = 0,
		-- One-shot grammar re-mint guard (per process).
		reminted = false,
	}, Experiments)
	-- Serve the persisted last-known-good assignments immediately after a
	-- restart when a stored subject id exists and the record matches this
	-- exact scope; their exposures re-arm for this session and are emitted by
	-- the first granted tick. No subject id is minted here.
	local subject = ex:current_subject_id()
	if subject then
		local record = storage.load_experiments(config)
		if record and record.scope == ex:scope_for(subject) then
			for key, entry in pairs(record.entries) do
				ex.entries[key] = entry
				ex.pending_exposure[key] = { entry }
			end
		end
	end
	return ex
end

-- Stop everything: called by the client at teardown. An in-flight response
-- landing afterwards is discarded outright — nothing installs, persists,
-- paces, or reaches game code (the fetch docs promise no late callbacks
-- after shutdown).
function Experiments:teardown()
	self.torn_down = true
end

function Experiments:diagnose(status, code)
	local hook = self.config.diagnostics
	if type(hook) == "function" then
		-- The hook is integrator code; never let it break the fetch path.
		pcall(hook, { scope = "experiments", status = status, code = code })
	end
end

-- The stored subject id when it is wire-valid, else nil. Never mints.
function Experiments:current_subject_id()
	local value = self.deps.subject_id()
	if M.valid_subject_id(value) then
		return value
	end
	return nil
end

-- The subject id a fetch uses: the persisted one, or a lazy first-need mint.
-- A missing, corrupt, or non-conforming stored value re-mints (fresh-install
-- semantics: the subject re-buckets). A failed persist is diagnosed and the
-- minted id still rules this process, so one session stays self-consistent.
function Experiments:ensure_subject_id()
	local existing = self:current_subject_id()
	if existing then
		return existing
	end
	return self:adopt_minted_subject_id()
end

function Experiments:adopt_minted_subject_id()
	local minted = M.mint_subject_id()
	-- A new subject is a new cache scope AND a new exposure subject:
	-- assignments fetched for the old subject must neither serve nor
	-- expose, and the session's exposure de-dupe resets — the Q4 tuple is
	-- per (experiment, version, SUBJECT), so the new subject's first
	-- application must emit even where the old subject's already did.
	self.entries = {}
	self.pending_exposure = {}
	self.exposed = {}
	if not self.deps.store_subject_id(minted) then
		self:diagnose("persist_failed", "subject_id")
	end
	return minted
end

-- A renewed analytics session (an explicit session_start) re-arms the
-- once-per-SESSION exposure contract: the session marker rotates so each
-- session derives its own deterministic ids, the de-dupe map resets, and
-- every still-applied assignment re-exposes on its next application sweep —
-- exactly like a cache-restored assignment does at launch.
function Experiments:on_session_renewed()
	self.session_marker = id.uuid()
	self.exposed = {}
	for key, entry in pairs(self.entries) do
		self:arm_exposure(key, entry)
	end
end

-- A consent denial purges queued-but-unpublished analytics facts — exposure
-- facts included. Those facts never reached the server, so the session's
-- emissions re-arm: a later re-grant of the retained assignment emits the
-- exposure again instead of silently under-counting real treatment. Facts
-- that HAD already published simply collapse server-side as duplicates of
-- their deterministic event ids, so the blanket re-arm is safe.
function Experiments:on_analytics_purge()
	self.exposed = {}
	for key, entry in pairs(self.entries) do
		self:arm_exposure(key, entry)
	end
end

function Experiments:scope_for(subject_id)
	return M.build_scope(
		self.config.workspace_id,
		self.config.environment_id,
		subject_id,
		self.config.remote_config_url)
end

local function consent_refusal(state)
	if state == "granted" then
		return nil
	end
	if state == "denied" or state == "denied_forced_minor" then
		return "consent_denied"
	end
	return "consent_unknown"
end

-- The durable record is maintained INCREMENTALLY, decoupled from the
-- in-memory serving set: a fail-closed latch clears serving while the disk
-- deliberately retains the record, so writing `self.entries` wholesale would
-- clobber retained sibling entries and a permanent drop landing while
-- nothing is served in memory would never reach the disk at all. The
-- in-memory state is the truth the disk CONVERGES to: a failed write marks
-- the key OWED and every tick retries it until it lands (kill drops in
-- particular must land durably), and a failed REFRESH write additionally
-- tombstones the superseded stored entry best-effort — a smaller record
-- often still saves when the refreshed one could not — so the disk never
-- keeps serving a variant memory has already replaced. Writes carry a
-- freshness fence for same-namespace sibling clients: a stored entry
-- stamped FRESHER than this client's knowledge is never overwritten or
-- deleted (stamps order same-clock writes only — the fence is a
-- best-effort guard, not a distributed clock).

-- The stored record for `scope`, or a fresh empty one (a record stamped for
-- any other scope is dead weight and is overwritten by the next write).
function Experiments:durable_record_for(scope)
	local record = storage.load_experiments(self.config)
	if record and record.scope == scope then
		return record
	end
	return { scope = scope, entries = {} }
end

-- Converge one experiment's durable entry to the in-memory truth: an entry
-- present in memory is written, an absent one is dropped. `as_of_ms` stamps
-- the state change (the entry's own fetch time for a write, the resolution
-- time for a drop) and drives the sibling freshness fence. Returns true when
-- the disk agrees with memory (written, already-agreeing, or outranked by a
-- fresher sibling write — all settled states); false marks the key owed.
function Experiments:sync_durable_entry(scope, experiment_key, as_of_ms)
	local entry = self.entries[experiment_key]
	local record = self:durable_record_for(scope)
	local stored = record.entries[experiment_key]
	if entry then
		if stored and type(stored.fetched_at_ms) == "number"
			and stored.fetched_at_ms > entry.fetched_at_ms then
			-- A same-namespace sibling persisted a FRESHER entry after this
			-- client's state formed: never roll the shared record back.
			self.durable_pending[experiment_key] = nil
			return true
		end
		record.entries[experiment_key] = entry
	else
		if stored == nil then
			self.durable_pending[experiment_key] = nil
			return true
		end
		-- A drop ALWAYS wins over the stored record it resolves: the
		-- decision came from a server response that postdates any stored
		-- copy of this key visible here, and the wall clock can move
		-- backward — fencing deletes on stamps would let a clock rollback
		-- revive a killed variant at the next launch. The freshness fence
		-- protects sibling WRITES only.
		record.entries[experiment_key] = nil
	end
	if storage.save_experiments(self.config, record) then
		self.durable_pending[experiment_key] = nil
		return true
	end
	if entry and stored then
		-- The refresh write failed with a superseded entry still stored:
		-- tombstone it best-effort (the smaller record often fits where the
		-- refreshed one did not), so a relaunch starts clean rather than
		-- serving the variant memory already replaced. The owed retry below
		-- still converges the disk to the full entry when storage recovers.
		record.entries[experiment_key] = nil
		storage.save_experiments(self.config, record)
	end
	self.durable_pending[experiment_key] = type(as_of_ms) == "number" and as_of_ms or 0
	self:diagnose("persist_failed", "cache")
	return false
end

-- Retry every owed durable write (and an owed whole-record clear) so the
-- disk converges as soon as storage recovers, instead of waiting for an
-- unrelated write or a relaunch. Local disk housekeeping only: no network,
-- no serving decisions, so it runs regardless of the consent state — a
-- kill drop decided under grant must land durably even if consent flips.
function Experiments:retry_durable_sync()
	if self.durable_clear_pending then
		if next(self.entries) ~= nil then
			-- Newer authorized state was installed after the failed clear:
			-- the epoch-scoped clear must not wipe it. Convert the owed
			-- whole-record clear into per-key drops for exactly the keys
			-- the clear still covers — everything on disk that memory no
			-- longer holds — and let the per-key sync converge those.
			self.durable_clear_pending = false
			local record = storage.load_experiments(self.config)
			if record then
				for key in pairs(record.entries) do
					if self.entries[key] == nil then
						self.durable_pending[key] = 0
					end
				end
			end
		elseif storage.clear_experiments(self.config) then
			self.durable_clear_pending = false
			self.durable_pending = {}
		end
	end
	if next(self.durable_pending) == nil then
		return
	end
	local subject = self:current_subject_id()
	if not subject then
		return
	end
	local scope = self:scope_for(subject)
	local keys = {}
	for key in pairs(self.durable_pending) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for i = 1, #keys do
		self:sync_durable_entry(scope, keys[i], self.durable_pending[keys[i]])
	end
end

-- The Q4 de-dupe tuple: (experiment, version, subject) — exactly the
-- documented contract, nothing more. The assignment key is deliberately NOT
-- part of it: it is normally deterministic for this tuple anyway, and a
-- regenerated key for the same tuple must not over-count exposures. The
-- emitted fact still carries the current fact key as a PROP.
local function exposure_tuple(experiment_key, entry)
	return experiment_key .. "\31" .. string.format("%.0f", entry.version)
		.. "\31" .. tostring(entry.subject_key)
end

-- Each experiment's owed exposures are a small FIFO of applied-entry
-- snapshots (bounded; overflowing drops the OLDEST with a diagnostic), so a
-- new application displacing the slot cannot silently lose the previous
-- application's still-unemitted fact.
local max_owed_exposures = 8

-- Arm one application snapshot for emission. A same-tuple snapshot already
-- armed at the tail is refreshed in place (renewals and purges re-arm the
-- same application; the de-dupe collapses same-tuple emissions anyway), so
-- the queue only grows across genuinely distinct applications.
function Experiments:arm_exposure(experiment_key, entry)
	local list = self.pending_exposure[experiment_key]
	if type(list) ~= "table" then
		list = {}
		self.pending_exposure[experiment_key] = list
	end
	local tail = list[#list]
	if tail and exposure_tuple(experiment_key, tail) == exposure_tuple(experiment_key, entry) then
		list[#list] = entry
		return
	end
	list[#list + 1] = entry
	if #list > max_owed_exposures then
		table.remove(list, 1)
		self:diagnose("exposure_skipped", "owed_overflow")
	end
end

-- Emit one exposure fact for one applied-entry snapshot. Returns:
--   true                      — emitted, or already emitted this session;
--   false, code, true         — terminally skipped (no server-safe fact
--                               key; the SDK subject id never egresses);
--   false, code               — retryable (consent closed, queue full):
--                               the armed snapshot stays for a later sweep.
function Experiments:emit_entry_exposure(experiment_key, entry, rearm)
	local refusal = consent_refusal(self.deps.consent())
	if refusal then
		return false, refusal
	end
	local tuple = exposure_tuple(experiment_key, entry)
	local exposed = self.exposed[tuple]
	if exposed and not rearm then
		return true
	end
	-- Facts carry ONLY the server-minted subject-fact key as the
	-- assignment_key prop (opaque, verbatim — the ingest service
	-- structurally requires it for client_id-unit facts). The SDK-minted
	-- subject id NEVER egresses on the analytics plane, so an assignment
	-- without a subject-fact key — a synthetic-unit answer included —
	-- emits NO fact: skipped terminally, surfaced through diagnostics.
	local fact_key = entry.subject_fact_key
	if type(fact_key) ~= "string" or fact_key == "" then
		self:diagnose("exposure_skipped", "no_subject_fact_key")
		return false, "exposure_no_subject_fact_key", true
	end
	local arm = 0
	if exposed then
		arm = exposed.arm + 1
	end
	local event_id = M.exposure_event_id(
		self.session_marker, entry.subject_key, experiment_key, entry.version, arm)
	local ok, err = self.deps.emit("experiment_exposure", {
		experiment_key = experiment_key,
		experiment_version = entry.version,
		assignment_key = fact_key,
		variant_key = entry.variant_key,
		assignment_unit = entry.assignment_unit,
	}, event_id)
	if not ok then
		return false, err
	end
	self.exposed[tuple] = { arm = arm }
	return true
end

-- Drain one experiment's owed-exposure queue in order: emitted and
-- terminally skipped snapshots leave the queue; a retryable failure (queue
-- full, consent closed) stops the drain and keeps the remainder armed for a
-- later sweep, so an older application's fact is never leapfrogged or lost.
function Experiments:sweep_pending(experiment_key)
	local list = self.pending_exposure[experiment_key]
	if type(list) ~= "table" then
		self.pending_exposure[experiment_key] = nil
		return
	end
	while list[1] do
		local ok, _, terminal = self:emit_entry_exposure(experiment_key, list[1])
		if ok or terminal then
			table.remove(list, 1)
		else
			return
		end
	end
	self.pending_exposure[experiment_key] = nil
end

-- Settle an authoritative fetch outcome and, when it may, install it. Gates,
-- in remote-config order: the auth epoch must still be current (an outcome
-- whose fetch was already in flight when a fail-closed latch landed is
-- discarded outright — it must neither unlatch nor reinstall revoked
-- assignments), the scope must still be current (a subject re-minted while
-- the response was in flight makes it another subject's assignment), then
-- the per-key sequence fence, then the outcome's own directives.
function Experiments:install(seq, scope, experiment_key, outcome, auth_epoch, resolved_at_ms)
	if auth_epoch ~= self.auth_epoch then
		return
	end
	local subject = self:current_subject_id()
	if not subject or self:scope_for(subject) ~= scope then
		return
	end
	local fence_key = scope .. scope_separator .. experiment_key
	if seq <= (self.settled[fence_key] or 0) then
		return
	end
	if outcome.authoritative then
		self.settled[fence_key] = seq
	end
	if outcome.auth_blocked then
		-- Fail closed: stop serving every cached assignment (the getters
		-- return nil), halt revalidation, and open a new auth epoch so
		-- every response still in flight is discarded — only a fetch
		-- started AFTER this moment may unlatch. The durable record is
		-- retained (a re-init may serve it and re-probe) unless the
		-- real-subjects sentinel says the platform withdrew the
		-- assignments outright.
		self.auth_blocked = true
		self.auth_epoch = self.auth_epoch + 1
		self.entries = {}
		self.pending_exposure = {}
		if outcome.drop_all then
			if storage.clear_experiments(self.config) then
				self.durable_pending = {}
			else
				-- The withdrawn assignments are still on disk: mark the
				-- clear OWED and retry it every tick until it lands.
				self.durable_clear_pending = true
				self:diagnose("persist_failed", "cache_clear")
			end
		end
		return
	end
	if outcome.authoritative then
		-- An authoritative, authorized outcome of a post-latch fetch (the
		-- epoch gate above guarantees that) proves the credential works
		-- again: unlatch and let revalidation resume.
		self.auth_blocked = false
	end
	if outcome.transient then
		return
	end
	-- A settled authoritative answer resets the consecutive-failure counter.
	-- A server-set Retry-After deadline is deliberately NOT cleared here:
	-- the pacing is shared by every cached entry, and one admitted request
	-- for an unrelated entry does not rescind the server's wait for the
	-- plane — the deadline simply expires on its own (clamped to a day; the
	-- deferral setter already keeps only the LATEST deadline).
	self.backoff_attempt = 0
	if outcome.drop_entry then
		local dropped = self.entries[experiment_key]
		self.entries[experiment_key] = nil
		-- The OWED exposures deliberately survive the drop: an application
		-- that already happened is a fact — the drop stops future serving,
		-- not the record of real treatment. The sweep emits them from the
		-- retained snapshots. The durable drop converges keyed on the DISK
		-- state (a latch may have cleared serving while the record retains
		-- the entry) and is retried until it lands — the kill rule demands
		-- the drop reach the disk. The drop's effective stamp is raised
		-- above the entry it resolves: the wall clock can move backward,
		-- and a drop for X must always outrank X's own stamp.
		local as_of = type(resolved_at_ms) == "number" and resolved_at_ms or 0
		if dropped and type(dropped.fetched_at_ms) == "number"
			and dropped.fetched_at_ms >= as_of then
			as_of = dropped.fetched_at_ms + 1
		end
		self:sync_durable_entry(scope, experiment_key, as_of)
		return
	end
	if outcome.new_entry then
		local entry = outcome.new_entry
		entry.subject_key = subject
		entry.attributes = outcome.attributes
		self.entries[experiment_key] = entry
		self:sync_durable_entry(scope, experiment_key, entry.fetched_at_ms)
		self:arm_revalidation(clock.unix_ms())
		-- The variant takes effect at this resolution (a variant change on
		-- republish applies here too — no mid-session flapping guard beyond
		-- the fetch cadence): the application point. The snapshot is ARMED
		-- behind any still-owed earlier applications (the queue preserves
		-- them — a full analytics queue must not cost the previous
		-- treatment its fact) and the sweep drains in order; a locally
		-- failed emit is retried by the tick sweep instead of being lost.
		self:arm_exposure(experiment_key, entry)
		self:sweep_pending(experiment_key)
	end
end

function Experiments:arm_revalidation(now_ms)
	local jitter = 1 + (math.random() * 2 - 1) * revalidate_jitter
	self.revalidate_at_ms = now_ms + math.floor(revalidate_interval_seconds * jitter * 1000)
end

function Experiments:defer_revalidation(seconds)
	if type(seconds) ~= "number" or seconds <= 0 then
		return
	end
	if seconds > max_defer_seconds then
		seconds = max_defer_seconds
	end
	local deadline = clock.unix_ms() + math.floor(seconds * 1000)
	if not self.retry_after_ms or deadline > self.retry_after_ms then
		self.retry_after_ms = deadline
	end
end

-- Transient-failure pacing for the revalidation cadence: a server Retry-After
-- wins; otherwise exponential backoff with full jitter (transport parity).
function Experiments:pace_transient(retry_after)
	if retry_after and retry_after > 0 then
		self:defer_revalidation(retry_after)
		return
	end
	self.backoff_attempt = self.backoff_attempt + 1
	if self.backoff_attempt < 2 then
		return
	end
	local exp = self.backoff_attempt - 2
	if exp > 16 then
		exp = 16
	end
	local ceiling = backoff_base_seconds * (2 ^ exp)
	if ceiling > backoff_cap_seconds then
		ceiling = backoff_cap_seconds
	end
	self:defer_revalidation(
		backoff_base_seconds + math.random() * (ceiling - backoff_base_seconds))
end

-- One assignment fetch. `attributes` is optional; `callback(result)` receives
-- { ok, assigned, variant_key?, variant_payload?, version?, reason?,
--   boundary?, from_cache, error? } and — like every request callback — fires
-- exactly once, pcall-guarded. Returns true when a request was dispatched, or
-- (false, error_code) with the callback already invoked when it could not be.
function Experiments:fetch(experiment_key, attributes, callback, is_revalidation)
	local function finish(result)
		if type(callback) == "function" then
			-- The callback is game code; never let it break the SDK.
			pcall(callback, result)
		end
		return result
	end

	if type(experiment_key) ~= "string" or experiment_key == "" then
		finish({ ok = false, from_cache = false, error = "experiment_key_required" })
		return false, "experiment_key_required"
	end
	-- GRANTED-ONLY plane (see the module header): while consent is unknown or
	-- denied — the forced-minor state included — no request leaves the
	-- device, nothing is minted, nothing is served.
	local refusal = consent_refusal(self.deps.consent())
	if refusal then
		finish({ ok = false, from_cache = false, error = refusal })
		return false, refusal
	end
	if not json or type(json.decode) ~= "function" then
		-- Without a decoder neither a fresh body nor a cached entry could be
		-- interpreted when it was stored; nothing can be served.
		finish({ ok = false, from_cache = false, error = "json_unavailable" })
		return false, "json_unavailable"
	end

	local subject = self:ensure_subject_id()
	self.fetch_seq = self.fetch_seq + 1
	local seq = self.fetch_seq

	-- Capture the scope and the auth epoch ONCE per fetch: the URL, the
	-- served cache, and the installed entry all describe the same subject
	-- even if the id re-mints while the request is in flight, and an
	-- outcome that raced a fail-closed latch is discarded by the epoch gate
	-- at install time.
	local scope = self:scope_for(subject)
	local auth_epoch = self.auth_epoch
	local entry = self.entries[experiment_key]

	local normalized_attributes, dropped
	if attributes ~= nil then
		normalized_attributes, dropped = M.normalize_attributes(attributes)
		if dropped > 0 then
			self:diagnose("dropped", "attributes")
		end
	elseif is_revalidation and entry and entry.attributes then
		-- A revalidation re-sends the attributes of the last host-supplied
		-- fetch for this experiment (one targeting vocabulary, one value
		-- set), so a server-evaluated condition keeps seeing the same
		-- subject it matched before. Only the CADENCE reuses them: a
		-- host-triggered fetch that omits attributes means what it says —
		-- it sends none, and none become the entry's remembered set.
		normalized_attributes = entry.attributes
	else
		normalized_attributes = {}
	end

	if not http or not http.request then
		local result = serve_entry_or_fail(entry, "http_unavailable")
		finish(result)
		return false, "http_unavailable"
	end

	local query = {
		{ name = "app_key", value = self.config.app_id },
		{ name = "environment_key", value = self.config.environment_id },
		{ name = "experiment_key", value = experiment_key },
		{ name = "subject_key", value = subject },
	}
	for i = 1, #normalized_attributes do
		query[#query + 1] = normalized_attributes[i]
	end
	local url = M.build_url(self.config.remote_config_url, query)
	local headers = {
		["Authorization"] = "Bearer " .. self.config.api_key,
	}
	local options = {
		timeout = self.config.publish_timeout_seconds,
	}

	http.request(url, "GET", function(_, _, response)
		-- A torn-down consumer discards in-flight responses outright:
		-- nothing installs, persists, or paces, and game code is not
		-- called back after shutdown (the documented teardown contract).
		if self.torn_down then
			return
		end
		-- The consent re-check comes next: a revocation while the request
		-- was in flight closes the plane. Nothing installs, nothing paces,
		-- nothing re-mints, and the caller receives the refusal — never a
		-- healthy assignment fetched under a consent that no longer holds.
		local refusal_now = consent_refusal(self.deps.consent())
		if refusal_now then
			finish({ ok = false, from_cache = false, error = refusal_now })
			return
		end
		-- Transient serves come from the CURRENT fenced entry, not the one
		-- captured at dispatch: a kill or supersede that resolved while
		-- this request was in flight must not be undone in the RESULT
		-- either — a caller must never be handed a variant the fenced
		-- state no longer serves. Stale epoch/scope reads as no entry.
		local entry_now = nil
		if auth_epoch == self.auth_epoch then
			local subject_now = self:current_subject_id()
			if subject_now and self:scope_for(subject_now) == scope then
				entry_now = self.entries[experiment_key]
			end
		end
		local resolved_at_ms = clock.unix_ms()
		local result, outcome = M.apply(entry_now, response, resolved_at_ms)
		outcome.attributes = normalized_attributes
		if outcome.remint and not self.reminted then
			-- The persisted subject id failed the wire grammar (storage
			-- corruption this client could not detect locally): re-mint
			-- once per process and retry as a fresh subject — from the
			-- revalidation path too, or a rejected cached subject would
			-- never heal until an explicit host fetch happens to run. A
			-- second grammar reject with a freshly minted id is a bug,
			-- never a loop. (Never reached under a mid-flight revocation:
			-- the consent gate above returns first, so no id is minted
			-- post-revocation.)
			self.reminted = true
			self:diagnose("reminted", "subject_id")
			self:adopt_minted_subject_id()
			self:fetch(experiment_key, attributes, callback, is_revalidation)
			return
		end
		if outcome.transient and auth_epoch == self.auth_epoch then
			self:pace_transient(outcome.retry_after_seconds)
		end
		self:install(seq, scope, experiment_key, outcome, auth_epoch, resolved_at_ms)
		-- The epoch re-check guards the PUBLIC callback like the install:
		-- a response that raced a fail-closed latch was discarded from
		-- state above, and its caller must not receive a healthy
		-- assignment either — it gets the closed result. (The
		-- latch-setting response itself re-derives its own identical
		-- closed result here.)
		if auth_epoch ~= self.auth_epoch then
			finish({ ok = false, from_cache = false, error = "unauthorized" })
			return
		end
		-- The subject-scope re-check guards the callback the same way: a
		-- subject re-minted while this response was in flight makes it
		-- ANOTHER subject's assignment — the install discarded it, and the
		-- caller must receive the miss, never the discarded variant.
		local subject_now = self:current_subject_id()
		if not subject_now or self:scope_for(subject_now) ~= scope then
			finish({ ok = false, from_cache = false, error = "stale_subject" })
			return
		end
		finish(result)
	end, headers, nil, options)
	return true
end

-- The revalidation tick, driven from the client's update(). Runs only while
-- consent is granted (the plane is granted-only end to end), not auth
-- latched, and at least one assignment is cached; a parked revalidation
-- never blocks anything — there is no pending state to drain at shutdown.
function Experiments:tick(_)
	if self.torn_down then
		return
	end
	-- Owed durable writes retry FIRST and regardless of consent: this is
	-- local disk housekeeping (no network, no serving decisions), and a
	-- kill drop decided under grant must land durably even if consent
	-- flipped meanwhile.
	self:retry_durable_sync()
	if consent_refusal(self.deps.consent()) then
		return
	end
	-- Owed-exposure sweep: cache-restored applications, locally failed
	-- emissions, and applications whose facts a consent purge re-armed all
	-- drain here, in per-experiment order, while consent is granted.
	if next(self.pending_exposure) then
		local keys = {}
		for key in pairs(self.pending_exposure) do
			keys[#keys + 1] = key
		end
		table.sort(keys)
		for i = 1, #keys do
			self:sweep_pending(keys[i])
		end
	end
	if self.auth_blocked or not next(self.entries) then
		return
	end
	local now = clock.unix_ms()
	if self.retry_after_ms then
		if now < self.retry_after_ms then
			return
		end
		self.retry_after_ms = nil
	end
	if not self.revalidate_at_ms then
		self:arm_revalidation(now)
		return
	end
	if now < self.revalidate_at_ms then
		return
	end
	self:arm_revalidation(now)
	local keys = {}
	for key in pairs(self.entries) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for i = 1, #keys do
		-- Batched per tick: one GET per cached entry, each re-sending its
		-- last host-supplied attributes. Outcomes apply at resolution.
		self:fetch(keys[i], nil, nil, true)
	end
end

-- ── getters and fact producers ────────────────────────────────────────────────

-- Cached-variant getters. They never touch the network and serve nil while
-- no assignment is cached — or while consent is not granted: the plane is
-- granted-only, so a non-granted session sees no variants at all (the cache
-- record is retained, unserved, until a re-grant).
function Experiments:variant(experiment_key)
	if type(experiment_key) ~= "string" or experiment_key == "" then
		return nil
	end
	if consent_refusal(self.deps.consent()) then
		return nil
	end
	local entry = self.entries[experiment_key]
	if not entry then
		return nil
	end
	return entry.variant_key
end

function Experiments:payload(experiment_key)
	if type(experiment_key) ~= "string" or experiment_key == "" then
		return nil
	end
	if consent_refusal(self.deps.consent()) then
		return nil
	end
	local entry = self.entries[experiment_key]
	if not entry then
		return nil
	end
	return copy_value(entry.variant_payload, 0)
end

-- Explicit exposure re-arm: emits one more exposure fact for the cached
-- assignment (a distinct deterministic id per arm), for hosts that want
-- session-scoped re-exposure semantics on top of the automatic
-- once-per-session emission.
function Experiments:track_exposure(experiment_key)
	if type(experiment_key) ~= "string" or experiment_key == "" then
		return false, "experiment_key_required"
	end
	-- The explicit re-arm targets the LIVE assignment only.
	local entry = self.entries[experiment_key]
	if not entry then
		return false, "no_assignment"
	end
	local ok, err = self:emit_entry_exposure(experiment_key, entry, true)
	return ok, err
end

-- Host-triggered outcome fact: stamps the same per-unit props from the
-- cached assignment plus the outcome key/value pair. Each call is a distinct
-- fact (a fresh event id); consent gating and identity rules apply on the
-- analytics pipeline like any other event.
function Experiments:track_outcome(experiment_key, outcome_key, outcome_value)
	if type(experiment_key) ~= "string" or experiment_key == "" then
		return false, "experiment_key_required"
	end
	if type(outcome_key) ~= "string" or outcome_key == "" then
		return false, "invalid_outcome_key"
	end
	if type(outcome_value) ~= "number" then
		return false, "invalid_outcome_value"
	end
	local entry = self.entries[experiment_key]
	if not entry then
		return false, "no_assignment"
	end
	-- Same egress rule as the exposure lane: the server-minted subject-fact
	-- key or nothing — the SDK-minted subject id never rides an analytics
	-- fact.
	local fact_key = entry.subject_fact_key
	if type(fact_key) ~= "string" or fact_key == "" then
		return false, "exposure_no_subject_fact_key"
	end
	return self.deps.emit("experiment_outcome", {
		experiment_key = experiment_key,
		experiment_version = entry.version,
		assignment_key = fact_key,
		variant_key = entry.variant_key,
		assignment_unit = entry.assignment_unit,
		outcome_key = outcome_key,
		outcome_value = outcome_value,
	}, id.uuid())
end

M.Experiments = Experiments

return M
