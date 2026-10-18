-- Experiment-assignment consumer: GETs the server-evaluated
-- assignment for one (app, environment, experiment, subject) tuple from the
-- server's assignment endpoint and serves the assigned variant to game
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
--   GET {app_url}/api/cp/v1/runtime/experiments/assignment
--     ?app_key=&environment_key=&experiment_key=&subject_key=&<attributes>
--   Authorization: Bearer <publishable publishable_key>   (same credential as the
--   remote-config fetch; the endpoint requires the experiment-assignment
--   read scope on that key, granted server-side)
-- The base URL is the configured `app_url` — the remote-config
-- host — with the path swapped; no new endpoint configuration exists.
--
-- Outcomes (decided by M.apply, pure):
--   * 200 assigned — the variant is served and cached (memory + durable).
--     Assignment stickiness is entirely the server's deterministic hash; the
--     cache is a latency/offline device, never an assignment authority, and
--     this client never re-buckets locally.
--   * 200 not-assigned — four shapes distinguished only by `reason`, a
--     CLOSED vocabulary: absent (deterministic traffic-gate miss),
--     "targeting_unmatched" (may change when attributes change),
--     "kill_switch" (operator kill), "age_ineligible" (no eligible adult
--     declaration). All four drop the cached assignment
--     for the experiment; a kill stops new applications. An age refusal
--     also WITHDRAWS the subject's owed
--     applications for the experiment — owed exposures and every fact
--     accepted but not yet delivered — where the other three keep them
--     (see apply_age_withdrawal). A host fetch that DECLARES a non-adult age
--     stops a client-id experiment serving until it ends, and withdraws it
--     the same way when it ends without the server's answer applied (see
--     begin_host_declaration). Future reason strings become unknown and
--     install not-assigned; malformed types and cross-scope answers remain
--     transient. Unsupported units cannot authorize a treatment.
--   * 401/403 — fail CLOSED: the result never serves a cached assignment,
--     in-memory serving stops (getters return nil) and revalidation halts
--     until re-init or a later successful, authorized fetch. The durable
--     cache record itself is left untouched (remote-config parity) EXCEPT
--     for exact error.code real_subjects_disabled, which drops the durable record
--     — the platform flipped the real-subjects flag back off, and the cached
--     assignment plus its subject-fact key must not outlive that.
--   * 404 — permanent for the experiment: treated as not-assigned, the
--     cached assignment is dropped and never served stale, and revalidation
--     stops asking for that key (the drop removes it from the cache).
--   * 400 — permanent except subject_id_invalid or subject_pii_marker:
--     those codes with an SDK-minted subject id re-mint the id ONCE
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
-- it egresses ONLY to the configured remote-config host as subject_key in assignment and apply
-- requests — never in analytics events, props or envelope identity.
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
-- strict server-side props allowlist.
-- Explicit application records exposure once per (experiment, version, subject,
-- session). Fetch/getter/restore never applies. Owed applications pin serving
-- inputs, then become byte-preserved signed facts after the apply hop.
-- The existing analytics lane carries the sealed fact and analytics identity.
-- Raw subject identity stays on the configured remote-config host.

local clock = require "shardpilot.clock"
local id = require "shardpilot.id"
local random = require "shardpilot.random"
local storage = require "shardpilot.storage"
local enums = require "shardpilot.experiment_enums"

local facts = require "shardpilot.experiment_facts"
local experiment_http = require "shardpilot.experiment_http"
local sdk_header = require "shardpilot.sdk_header"
local retry_after = require "shardpilot.retry_after"

local M = {}

local assignment_route = "/api/cp/v1/runtime/experiments/assignment"

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

-- Codes are exact and paired with their route/status by each caller.
local function feature_disabled(code, apply)
	return code == "runtime_disabled" or code == "experiments_disabled"
		or code == (apply and "experiment_apply_disabled" or "experiment_assignment_disabled")
end

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

-- Pure-arithmetic 32-bit rolling hash (shared by the credential fingerprint
-- and attribution tuples).
local function hash32(text, seed, mult)
	local hash = seed
	for i = 1, #text do
		hash = (hash * mult + text:byte(i)) % 4294967296
	end
	return hash
end

-- Non-secret fingerprint of the publishable credential: 8 lowercase hex
-- chars of a pure-arithmetic rolling hash — NEVER the raw key, and not
-- reversible to it. It rides the cache scope so the durable record is
-- keyed by the credential that fetched it: the server resolves the TENANT
-- from the Bearer key, and an in-place key swap with unchanged
-- workspace/app/environment must make the previous tenant's cached
-- assignments (and their subject-fact keys) a safe scope-miss, never a
-- serve.
function M.credential_fingerprint(credential)
	return string.format("%08x", hash32(tostring(credential or ""), 2166136261, 131))
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
-- escaped and joined with a separator no escaped component can contain, so
-- two distinct (workspace, environment, subject, url, credential) tuples can
-- never collide into one scope string. The experiment key is deliberately
-- NOT part of the base scope — entries are keyed by it inside the record, so
-- the full cache key is the (scope, experiment_key) pair. The CREDENTIAL
-- rides as a non-secret fingerprint (never the raw key): the tenant resolves
-- server-side from the Bearer key, so a swapped key with unchanged
-- workspace/app/environment is another tenant's plane and its cache must
-- scope-miss.
function M.build_scope(workspace_id, environment_id, subject_id, base_url, credential)
	return escape_component(workspace_id or "") .. scope_separator
		.. escape_component(environment_id or "") .. scope_separator
		.. escape_component(subject_id or "") .. scope_separator
		.. trim_slash(base_url or "") .. scope_separator
		.. M.credential_fingerprint(credential)
end

-- A rollback can omit the assignment endpoint and credential. Compare the
-- complete stored tuple against every component still known; an unknown
-- component cannot disprove the recorded withdrawal.
function M.declaration_covers_scope(config, subject, scope)
	local parts = storage.experiment_scope_components(scope)
	if not parts then return true end
	local expected = {
		config.workspace_id and escape_component(config.workspace_id),
		config.environment_id and escape_component(config.environment_id),
		M.valid_subject_id(subject) and escape_component(subject) or nil,
		type(config.app_url) == "string" and config.app_url ~= "" and trim_slash(config.app_url) or nil,
		type(config.publishable_key) == "string" and config.publishable_key ~= ""
			and M.credential_fingerprint(config.publishable_key) or nil,
	}
	for i = 1, 5 do
		if expected[i] ~= nil and expected[i] ~= parts[i] then return false end
	end
	return true
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

-- Age is admission input, not optional targeting. Never trim a refusal into
-- adult, discard it in favour of an adult alias, or lose it at the cap.
local function is_age_attribute(name)
	return name == "age_band" or name == "custom_attribute_age_band"
end

-- Whether a stored attribute list carries an age declaration under either
-- spelling, whatever its value: the server decided admission on it.
local function has_age_declaration(list)
	if type(list) ~= "table" then return false end
	for i = 1, #list do
		local pair = list[i]
		if type(pair) == "table" and is_age_attribute(pair.name) then
			return true
		end
	end
	return false
end

local function age_attribute_value(value)
	if type(value) ~= "string" or #value > max_attribute_value_bytes then
		return "unknown"
	end
	return value
end

function M.normalize_assignment_attributes(attributes)
	if type(attributes) ~= "table" then return {}, 0 end
	local other, age = {}, {}
	for name, value in pairs(attributes) do
		if is_age_attribute(name) then
			age[#age + 1] = { name = name, value = age_attribute_value(value) }
		else
			other[name] = value
		end
	end
	local normalized, dropped = M.normalize_attributes(other)
	while #normalized > max_attributes - #age do
		table.remove(normalized)
		dropped = dropped + 1
	end
	for _, pair in ipairs(age) do normalized[#normalized + 1] = pair end
	table.sort(normalized, function(a, b) return a.name < b.name end)
	return normalized, dropped
end

-- Restored declarations use the same admission rules. Corrupt duplicate age
-- entries keep any refusal; neither an adult duplicate nor a cap erases it.
local function sanitize_restored_attributes(list)
	if type(list) ~= "table" then return nil end
	local attributes = {}
	for i = 1, #list do
		local pair = list[i]
		if type(pair) == "table" then
			if is_age_attribute(pair.name) then
				local value = age_attribute_value(pair.value)
				local previous = attributes[pair.name]
				if previous == nil or previous == "adult" then
					attributes[pair.name] = value
				end
			elseif valid_attribute_name(pair.name) and type(pair.value) == "string" then
				attributes[pair.name] = pair.value
			end
		end
	end
	local normalized = M.normalize_assignment_attributes(attributes)
	if #normalized == 0 then return nil end
	return normalized
end

-- Whether a host fetch's attributes declare an age other than adult under
-- either spelling, read the way the request sends it: only an exact "adult"
-- admits, so an unknown, under-threshold, empty, padded, oversized or
-- non-string value is non-adult. An absent declaration declares nothing.
local function declares_non_adult_age(attributes)
	if type(attributes) ~= "table" then return false end
	for _, name in ipairs({ "age_band", "custom_attribute_age_band" }) do
		local value = attributes[name]
		if value ~= nil and age_attribute_value(value) ~= "adult" then
			return true
		end
	end
	return false
end

-- Whether a host fetch's attributes declare adult under every age spelling
-- they carry, and carry at least one.
local function declares_adult_age(attributes)
	if type(attributes) ~= "table" then return false end
	local declared = false
	for _, name in ipairs({ "age_band", "custom_attribute_age_band" }) do
		local value = attributes[name]
		if value ~= nil then
			if age_attribute_value(value) ~= "adult" then
				return false
			end
			declared = true
		end
	end
	return declared
end

-- A synthetic-subject assignment has no age gate: the server assigns it
-- whatever age is declared, so a pending non-adult declaration neither hides
-- nor withdraws it. Anything else is treated as age-gated.
local function age_exempt(entry)
	return type(entry) == "table" and entry.assignment_unit == "synthetic_subject_key"
end

-- This fetch-scoped declaration does not change consent or the caller's map.
function M.attributes_with_age_band(band, attributes)
	if band ~= "unknown" and band ~= "under_threshold" and band ~= "adult" then
		return nil, "invalid_experiment_age_band"
	end
	if attributes ~= nil and type(attributes) ~= "table" then
		return nil, "invalid_experiment_attributes"
	end
	if attributes and attributes.age_band ~= nil and attributes.age_band ~= band then
		return nil, "invalid_experiment_age_band"
	end
	local declared = {}
	for name, value in pairs(attributes or {}) do declared[name] = value end
	declared.age_band = band
	return declared
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

local retry_after_seconds = retry_after.seconds

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

-- Only a complete, unambiguous envelope grants a code-specific action.
-- The bounded object reader rejects duplicate members, including escaped keys.
-- Human messages and unknown members never select an action.
local function response_error(response)
	local decoded, fields = facts.object(type(response) == "table" and response.response or nil)
	local raw = fields and fields.error
	local err = decoded and decoded.error
	if not raw or not raw.fields or type(err) ~= "table" or type(err.code) ~= "string" then
		return nil, false
	end
	local age = false
	local details = raw.fields.details
	if details and details.raw:sub(1, 1) == "[" and type(err.details) == "table" then
		for _, detail in ipairs(err.details) do
			if type(detail) == "table" and detail.field == "reason" and detail.code == "age_ineligible" then
				age = true
			end
		end
	end
	return err.code, age
end

-- The same strict reader for remote config: the envelope's `error.code`, or
-- nil when the body is not a complete, unambiguous envelope.
function M.error_code(response)
	return (response_error(response))
end

-- Order-insensitive-in-effect equality of two normalized attribute sets
-- (both are name-sorted { name, value } arrays — the dispatch normalizer
-- sorts, the entry stores the dispatched set, and the restore sanitizer
-- preserves stored order — so pairwise comparison suffices; nil means the
-- empty set).
local function attributes_match(requested, stored)
	local a = requested or {}
	local b = stored or {}
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i].name ~= b[i].name or a[i].value ~= b[i].value then
			return false
		end
	end
	return true
end

-- Serve the cached entry for a transient failure, or fail when none exists. A
-- served entry is still a SUCCESS (`ok = true`) — the game has a usable
-- assignment — with `from_cache = true` and `error` carrying why the network
-- could not refresh it. Only assigned entries are ever cached, so a cache
-- serve always carries a variant.
--
-- The serve is honest only for the SAME targeting context: targeting is
-- server-evaluated, and the entry stores the normalized attribute set it was
-- evaluated under. A request carrying a DIFFERENT set (geo=CA against a
-- geo=US-evaluated cache) cannot be answered by this entry — a variant whose
-- targeting condition the requested attributes may not match must not apply
-- — so a mismatch gets the closed transient-failure result instead. The
-- serving GETTERS are unaffected: they report the last APPLIED state, not an
-- attribute-bearing request; the revalidation cadence re-sends the entry's
-- own remembered set, so cadence serves always match.
local function serve_entry_or_fail(entry, error_code, requested)
	if entry and attributes_match(requested, entry.attributes) then
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
--     not-assigned shape, 404, and non-grammar 400s — a permanently
--     rejected input set must not serve stale forever) / drop the whole
--     durable record (the real-subjects kill sentinel);
--   * auth_blocked — 401/403: stop serving and stop revalidating, fail
--     closed;
--   * remint — the subject-grammar 400 sentinel: the caller may re-mint the
--     subject id once and retry;
--   * close_entry — a terminal 3xx or other 4xx: stop serving the
--     experiment's cached assignment and stop revalidating it until an
--     explicit fetch for it is answered or the next session;
--   * transient + retry_after_seconds — pace the revalidation backoff and
--     honor a server Retry-After (429 and 5xx alike).
-- A response scope echo is INVALID when the field is PRESENT but not a
-- string (a wrong-typed echo must never "agree with the request" by type
-- accident — the same presence/type split the not-assigned reason uses), or
-- when it is a non-empty string that disagrees with what the request asked
-- for. Absent fields and empty strings/expectations validate nothing.
local function echo_invalid(echoed, expected)
	if echoed == nil then
		return false
	end
	if type(echoed) ~= "string" then
		return true
	end
	return echoed ~= "" and type(expected) == "string" and expected ~= ""
		and echoed ~= expected
end

-- The positive wire grammar for a server-minted subject-fact key (go
-- parity: sfk1_ + exactly 64 lowercase hex). The negative rule it enforces
-- is the no-egress contract: a fact key that is actually the dispatched
-- SDK subject id (a buggy server echo) must never install — it would ride
-- props.assignment_key onto the analytics plane, the exact leak the sfk1_
-- namespace exists to prevent.
local function valid_subject_fact_key(value)
	if type(value) ~= "string" or #value ~= 69 then
		return false
	end
	return value:match("^sfk1_[0-9a-f]+$") ~= nil
end

-- The positive wire grammar for an experiment version: a positive, finite
-- integer. The version drives the exposure de-dupe tuple and the
-- attribution inputs, so a garbled value — negative, fractional, NaN —
-- must read as MALFORMED: it never installs, and it never executes the
-- not-assigned path's authoritative durable drop on garbage input (the
-- closed-vocabulary rule, applied to the version field).
local function valid_wire_version(value)
	return type(value) == "number" and value > 0 and value < math.huge
		and value % 1 == 0
end

-- Strip everything nested below the ROOT object from a JSON body (string-
-- aware: quotes and escapes tracked, so braces inside string values cannot
-- skew the depth), leaving only the top-level keys and scalar values. The
-- null-presence scan runs on this projection so a legitimate nested
-- `"app_key": null` inside a variant payload can never read as a malformed
-- top-level scope echo. Deterministic plain-Lua chars walk — identical on
-- every interpreter.
local function top_level_projection(body, nested_value)
	if type(body) ~= "string" then
		return ""
	end
	local out = {}
	local depth = 0
	local in_string = false
	local escaped = false
	for i = 1, #body do
		local ch = body:sub(i, i)
		if in_string then
			if depth == 1 then
				out[#out + 1] = ch
			end
			if escaped then
				escaped = false
			elseif ch == "\\" then
				escaped = true
			elseif ch == '"' then
				in_string = false
			end
		elseif ch == '"' then
			in_string = true
			if depth == 1 then
				out[#out + 1] = ch
			end
		elseif ch == "{" or ch == "[" then
			depth = depth + 1
			if depth == 1 then
				out[#out + 1] = ch
			elseif depth == 2 and nested_value then
				out[#out + 1] = nested_value
			end
		elseif ch == "}" or ch == "]" then
			if depth == 1 then
				out[#out + 1] = ch
			end
			depth = depth - 1
		elseif depth == 1 then
			out[#out + 1] = ch
		end
	end
	return table.concat(out)
end

-- JSON lets any character of a KEY be spelled as a \uXXXX escape, so a
-- valid body's `"reason": null` DECODES to reason while a literal
-- raw-text scan sees only the escaped spelling — the present-null would
-- slip to the ABSENT path (authoritative drops included) on null→nil
-- runtimes. Normalize, SCAN-SCOPED, only the escapes landing in the
-- scanned keys' alphabet ([a-z_]): structural characters (quotes, braces,
-- colons) never materialize, so the projection this feeds cannot be
-- reshaped, and the parse path is untouched. An escape inside a string
-- VALUE can at worst manufacture the literal false-positive the scan
-- already accepts — toward MALFORMED, the safe direction.
local function unescape_scanned_keys(text)
	return (text:gsub("\\u(%x%x%x%x)", function(hex)
		local code = tonumber(hex, 16)
		if code == 0x5f or (code >= 0x61 and code <= 0x7a) then
			return string.char(code)
		end
	end))
end

-- Defold's decoder (and the plain-Lua fallback) maps JSON null to Lua nil,
-- which makes a present `"field": null` indistinguishable from an ABSENT
-- field by table lookup alone — and the presence/type split treats those
-- very differently (a PRESENT reason outside the closed vocabulary is
-- malformed; an absent one is the deterministic traffic-gate miss). On
-- runtimes whose decoder yields a null SENTINEL (json.null), the ordinary
-- type checks already catch present-null as a wrong type; for null→nil
-- decoders this raw-body scan restores field PRESENCE. It runs on the
-- key-unescaped projection (see unescape_scanned_keys) so an escaped key
-- spelling is recognized too. Terminator-guarded; a literal
-- '"field":null' inside a string VALUE can false-positive toward
-- MALFORMED, which is the safe direction (serve-stale, never a directive
-- misread).
local function body_field_is_null(body_text, field)
	if type(body_text) ~= "string" then
		return false
	end
	return body_text:find('"' .. field .. '"%s*:%s*null%s*[,}%]]') ~= nil
end

-- A future unit cannot authorize a treatment or a new exposure. Preserve
-- other boundary members for introspection while exposing its known fallback.
local function unknown_unit_result(decoded, boundary)
	local normalized = copy_value(boundary, 0)
	normalized.assignment_unit = "unknown"
	return { ok = true, from_cache = false, assigned = false, reason = "unknown",
		version = decoded.version, boundary = normalized },
		{ authoritative = true, drop_entry = true }
end

-- `requested_attributes` is the normalized attribute set THIS request
-- dispatched: every stale-cache serve inside is fenced on it matching the
-- entry's stored set (see serve_entry_or_fail).
function M.apply(entry, response, now_ms, experiment_key, app_key, environment_key, requested_attributes)
	local status = type(response) == "table" and response.status or 0

	if status == 200 then
		local body_text = type(response) == "table"
			and type(response.response) == "string" and response.response or ""
		-- Null-presence scans run on the TOP-LEVEL projection only: a
		-- nested "app_key": null inside a legitimate variant payload must
		-- not read as a malformed scope echo. The projection walks the
		-- PRISTINE body (its string-awareness stays exact), then the
		-- scan-scoped key unescape restores escaped spellings of the
		-- scanned keys.
		local body_scan = unescape_scanned_keys(top_level_projection(body_text))
		local decoded = decode_object(type(response) == "table" and response.response or nil)
		if not decoded then
			return serve_entry_or_fail(entry, "malformed_response", requested_attributes), { transient = true }
		end
		if echo_invalid(decoded.experiment_key, experiment_key)
			or echo_invalid(decoded.app_key, app_key)
			or echo_invalid(decoded.environment_key, environment_key)
			or (decoded.experiment_key == nil and body_field_is_null(body_scan, "experiment_key"))
			or (decoded.app_key == nil and body_field_is_null(body_scan, "app_key"))
			or (decoded.environment_key == nil and body_field_is_null(body_scan, "environment_key")) then
			-- A 200 whose body names ANOTHER experiment, app, or environment
			-- is routing/proxy confusion, not an answer to this request:
			-- malformed BEFORE anything installs — never cache (or drop)
			-- under the current scope on another scope's payload or
			-- subject-fact key. A PRESENT-NULL scope echo is the same
			-- class: present and wrong, invisible only to null→nil
			-- decoders — the body scan restores its presence.
			return serve_entry_or_fail(entry, "malformed_response", requested_attributes), { transient = true }
		end
		local boundary = type(decoded.boundary) == "table" and decoded.boundary or nil
		local assignment_unit = boundary and boundary.assignment_unit or nil
		if decoded.assigned == true
			and type(decoded.assignment_key) == "string" and decoded.assignment_key ~= ""
			and type(decoded.variant_key) == "string" and decoded.variant_key ~= ""
			and valid_wire_version(decoded.version)
			and type(assignment_unit) == "string" then
			if assignment_unit == "client_id"
				and not valid_subject_fact_key(decoded.subject_fact_key) then
				-- A client_id-unit assignment WITHOUT a server-minted
				-- subject-fact key would serve a treatment whose exposure
				-- and outcome facts are all terminally skipped (the facts
				-- contract requires the key; the SDK subject id never
				-- egresses): users silently land in a variant with ZERO
				-- reporting, biasing the experiment's results. The key is
				-- REQUIRED for client_id units — absent, mistyped, or
				-- OUTSIDE the positive sfk1_ grammar means the response is
				-- malformed and nothing installs (serve-stale transient).
				-- The grammar check also rejects a buggy server echo of
				-- the dispatched spcid_ subject id: installing that would
				-- ride the SDK subject onto the analytics plane as
				-- props.assignment_key — the exact no-egress breach the
				-- sfk1_ namespace exists to prevent. Synthetic units
				-- legitimately carry none and keep the documented no-fact
				-- posture.
				return serve_entry_or_fail(entry, "malformed_response",
					requested_attributes), { transient = true }
			end
			local _, fields = facts.object(top_level_projection(body_text, "null"))
			if not fields then
				return serve_entry_or_fail(entry, "malformed_response", requested_attributes), { transient = true }
			end
			local has_pins = fields.served_revision or fields.served_kill_gate or fields.served_at
			local version_wire = fields and facts.integer(fields.version, 1)
			local revision_wire = fields and facts.integer(fields.served_revision, 0)
			if has_pins and (not version_wire or not revision_wire
				or type(decoded.served_kill_gate) ~= "boolean"
				or type(decoded.served_at) ~= "string" or decoded.served_at == "") then
				return serve_entry_or_fail(entry, "malformed_response", requested_attributes), { transient = true }
			end
			if not enums.known_unit(assignment_unit) then
				return unknown_unit_result(decoded, boundary)
			end
			local new_entry = {
				assignment_key = decoded.assignment_key,
				variant_key = decoded.variant_key,
				variant_payload = copy_value(decoded.variant_payload, 0),
				version = decoded.version,
				version_wire = version_wire,
				served_revision_wire = revision_wire,
				served_kill_gate = decoded.served_kill_gate,
				served_at = decoded.served_at,
				assignment_unit = assignment_unit,
				subject_fact_key = valid_subject_fact_key(decoded.subject_fact_key)
					and decoded.subject_fact_key or nil,
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
			if (decoded.version ~= nil and not valid_wire_version(decoded.version))
				or (decoded.version == nil
					and body_field_is_null(body_scan, "version")) then
				-- A PRESENT version failing the wire grammar (negative,
				-- fractional, NaN, or mistyped) is a garbled answer: it
				-- must not execute the authoritative durable drop below —
				-- the same rule as an unknown reason. A PRESENT-NULL
				-- version is the same class on null→nil decoders (the
				-- raw-body top-level presence scan restores it, exactly
				-- like the reason and scope-echo scans). Absent stays fine
				-- (the reason-only shapes carry none).
				return serve_entry_or_fail(entry, "malformed_response",
					requested_attributes), { transient = true }
			end
			-- Unknown strings are an authoritative not-assigned verdict.
			-- Types/nulls remain malformed; enum openness changes no shape rule.
			local reason = decoded.reason
			if (reason ~= nil and type(reason) ~= "string")
				or (reason == nil and body_field_is_null(body_scan, "reason")) then
				return serve_entry_or_fail(entry, "malformed_response",
					requested_attributes), { transient = true }
			end
			if type(assignment_unit) == "string" and not enums.known_unit(assignment_unit) then
				return unknown_unit_result(decoded, boundary)
			end
			if reason ~= nil and reason ~= "kill_switch"
				and reason ~= "targeting_unmatched" and reason ~= "age_ineligible" then
				reason = "unknown"
			end
			local outcome = { authoritative = true, drop_entry = true }
			if reason == "age_ineligible" then
				-- The one refusal that also WITHDRAWS what the subject still
				-- owes for this experiment (install routes it to
				-- apply_age_withdrawal instead of apply_entry_drop). The
				-- body's subject-fact key names the refused subject's facts;
				-- a key outside the sfk1_ grammar is simply not used.
				outcome.withdraw_owed = true
				outcome.refused_fact_key = valid_subject_fact_key(decoded.subject_fact_key)
					and decoded.subject_fact_key or nil
			end
			return {
				ok = true,
				from_cache = false,
				assigned = false,
				reason = reason,
				version = type(decoded.version) == "number" and decoded.version or nil,
				boundary = copy_value(boundary, 0),
			}, outcome
		end
		return serve_entry_or_fail(entry, "malformed_response", requested_attributes), { transient = true }
	end

	-- Unauthorized / forbidden fail CLOSED (a dark server, a revoked or
	-- unscoped key, a suspended tenant — diagnostics distinguish codes; all must
	-- stop serving): the cached record is never served for this outcome and
	-- revalidation halts. The durable record is kept EXCEPT under the
	-- real-subjects kill sentinel, which drops it — the assignment and its
	-- subject-fact key must not outlive the platform flipping that flag off.
	local code = response_error(response)
	if status == 401 or status == 403 then
		local outcome = { authoritative = true, auth_blocked = true }
		if status == 403 and code == "real_subjects_disabled" then
			outcome.drop_all = true
		elseif status == 403 and feature_disabled(code, false) then
			outcome.disabled_code = code
		end
		return { ok = false, from_cache = false,
			error = outcome.disabled_code and "disabled" or "unauthorized" }, outcome
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
	-- help. The two self-healing codes identify an invalid SDK-minted subject
	-- or a PII-marker collision; the caller re-mints once
	-- (fresh-install semantics) and retries — deliberately NOT a drop: the
	-- assignment itself was never rejected, the subject id was. Every OTHER
	-- 400 fails closed for the experiment: a cached assignment whose
	-- revalidation is permanently rejected must not keep serving stale
	-- forever while the cadence re-sends the same invalid input set, so the
	-- entry drops (durably, with the usual decision-time stamp raise).
	if status == 400 then
		if code == "subject_id_invalid" or code == "subject_pii_marker" then
			return { ok = false, from_cache = false, error = "bad_request" },
				{ authoritative = true, remint = true }
		end
		return { ok = false, from_cache = false, error = "bad_request" },
			{ authoritative = true, drop_entry = true }
	end

	-- Transient bucket: no connection, timeout, backpressure, or any server
	-- error — including the 503 the endpoint answers when its kill-state read
	-- fails (an explicit serve-stale-and-retry case). Retry-After is honored
	-- on 429 and 5xx alike.
	if status == 0 then
		return serve_entry_or_fail(entry, "http_0", requested_attributes),
			{ transient = true }
	elseif status == 408 then
		return serve_entry_or_fail(entry, "transient_408", requested_attributes),
			{ transient = true }
	elseif status == 429 or status >= 500 then
		return serve_entry_or_fail(entry, "transient_" .. tostring(status),
				requested_attributes),
			{ transient = true, retry_after_seconds = retry_after_seconds(response) }
	end

	-- Anything else (an unexpected redirect, another 4xx, a non-200 2xx) is
	-- an authoritative "no assignment is served here" FOR THIS CALL: fail
	-- without serving stale values. A 3xx or another 4xx is terminal, so it
	-- also CLOSES the experiment: the getters serve the host's default and
	-- the cadence stops probing it until an explicit fetch for it is
	-- answered or the next session. The record itself is kept (semantics
	-- this client cannot classify never earn a blind drop), so the next
	-- session serves and revalidates it again. A non-200 2xx is not
	-- terminal and leaves the entry serving. The outcome is UNPROVEN for
	-- the auth latch: unlike a parsed 200/404/400 — proof the credential was
	-- accepted and processed — a stray redirect or conflict says nothing
	-- about authorization, so it settles its sequence fence but must not
	-- unlatch a fail-closed plane (see install).
	local outcome = { authoritative = true, unproven = true }
	if status >= 300 and status < 500 then
		outcome.close_entry = true
	end
	return { ok = false, from_cache = false, error = "http_" .. tostring(status) }, outcome
end

-- ── the consumer ──────────────────────────────────────────────────────────────

local Experiments = {}
Experiments.__index = Experiments

-- The fact-key history's two shapes: memory holds experiment_key →
-- { [fact_key] = true }; the durable section (and every read of it) holds
-- experiment_key → a sorted list of fact keys. Fold a durable-shaped
-- `lists` into memory's `history`.
local function add_fact_keys(history, lists)
	if type(lists) ~= "table" then
		return
	end
	for experiment_key, keys in pairs(lists) do
		for i = 1, #keys do
			local set = history[experiment_key] or {}
			set[keys[i]] = true
			history[experiment_key] = set
		end
	end
end

-- Memory's history in the durable shape: sorted lists, empty sets left out.
local function listed_fact_keys(history)
	local out = {}
	for experiment_key, set in pairs(history) do
		local list = {}
		for key in pairs(set) do
			list[#list + 1] = key
		end
		if list[1] then
			table.sort(list)
			out[experiment_key] = list
		end
	end
	return out
end

-- True when two durable-shaped histories hold the same keys.
local function same_fact_keys(a, b)
	for experiment_key, list in pairs(a) do
		local other = b[experiment_key]
		if other == nil or #other ~= #list then
			return false
		end
		for i = 1, #list do
			if other[i] ~= list[i] then
				return false
			end
		end
	end
	for experiment_key in pairs(b) do
		if a[experiment_key] == nil then
			return false
		end
	end
	return true
end

-- `config` is the client's normalized configuration. `deps` wires the client
-- without import cycles:
--   * subject_id()          — the persisted subject-id candidate (raw; the
--                             accessor re-reads the identity record at
--                             mint-decision time so sibling clients converge
--                             on one minted subject);
--   * store_subject_id(v)   — adopt + persist a minted id (returns success);
--   * consent()             — the CURRENT analytics consent state;
--   * analytics_session()   — the CURRENT analytics session id (nil before
--                             one exists);
--   * analytics_anonymous_id() — the CURRENT analytics anonymous id;
--   * emit(name, props, id, overrides) — enqueue one experiment fact on the
--                             analytics pipeline (consent-gated there,
--                             identity rules applied there). `overrides`
--                             carries the ARM-TIME identity of an owed fact
--                             ({ session_id, anonymous_id, event_ts }); a
--                             missing field means "stamp the current value";
--   * live_fact_keys(key)   — the set of subject-fact keys this experiment's
--                             facts on the analytics pipeline still carry
--                             (the fact-key history's liveness question).
function M.new(config, deps)
	local condemned_stamp, condemned_scope, condemned_miss, declarations = storage.load_experiments_clear(config)
	local ex = setmetatable({
		config = config,
		deps = deps,
		http_transport = experiment_http.new(),
		-- In-memory serving cache: experiment_key → entry. Only assigned
		-- entries exist here; every not-assigned outcome drops its key.
		entries = {},
		-- Per-experiment bounded FIFO: first pinned applications, then sealed
		-- facts owed to analytics. New serving state never rewrites a record.
		pending_exposure = {},
		-- Durable-write convergence: (scope\31key) composite →
		-- { key, scope, as_of, drop } for an OWED sync (memory changed,
		-- disk did not), retried every tick; plus an owed whole-record
		-- clear stamped by its resolution. Intents carry the SCOPE they
		-- were decided under: a subject re-mint cancels owed writes (their
		-- source data dies with the rotation) while owed drops still land
		-- against the retired record, and combined-record saves only fold
		-- intents of their own scope. The recorded drop/write intent also
		-- lets an ordinary fail-closed latch cancel owed WRITES (the
		-- 401/403 canon retains the durable record) while authoritative
		-- drops still land.
		durable_pending = {},
		-- The FACT-KEY HISTORY of one scope (one subject's record):
		-- experiment_key → { [fact_key] = true } for subject-fact keys that
		-- live facts of the experiment may still carry although no cached
		-- entry does. The server rotates the key on every published
		-- version, and a drop deletes the entry, so a fact built under an
		-- earlier entry (queued, in flight, spooled, owed) would otherwise
		-- be unmatchable by a later age refusal. Keys ENTER at the durable
		-- write that retires them (sync_durable_entry) and LEAVE when no
		-- live fact references them (prune_history). Mirrored in the
		-- durable record's `fact_key_history` section.
		fact_key_history = {},
		fact_key_history_scope = nil,
		-- experiment_key → the subject-fact key of the entry the last
		-- durable sync of that key converged toward (same scope as the
		-- history). A sync toward another key retires this one even when
		-- the disk never held it (a failed or cap-evicted write).
		synced_fact_keys = {},
		-- Liveness is unknown until the client restored its spool: until
		-- then the history only grows, never prunes (a restored chunk may
		-- still carry a retired key).
		fact_keys_restored = false,
		-- Facts left the pipeline outside a settle or a durable write (cap
		-- eviction, a consent or sentinel purge): the next tick prunes.
		fact_key_prune_owed = false,
		durable_clear_pending = false,
		-- The SCOPE the owed whole-record clear was decided for: the record
		-- file is shared across assignment scopes in this app namespace,
		-- and a sentinel for one environment/credential must never condemn
		-- another scope's entries. Set and cleared with the pending clear.
		durable_clear_scope = nil,
		-- In-memory mirror of the DURABLE condemnation marker ({stamp,
		-- scope} or nil). Outlives a demotion: the demoted per-key drops
		-- are memory intents until their syncs land, and an exit in that
		-- window must still find the durable refusal — the marker retires
		-- only when nothing it condemns remains on disk.
		clear_marker = nil,
		-- Set by teardown(): an in-flight response landing afterwards must
		-- not install, persist, pace, or call back into game code.
		torn_down = false,
		-- Session-scoped tuple -> original application, and the last applied
		-- value per experiment for outcomes (independent of newer fetches).
		exposed = {},
		applications = {},
		-- Per-process session marker scopes application deduplication.
		session_marker = id.uuid(),
		-- Per-(scope, experiment) sequence fence for out-of-order responses,
		-- remote-config discipline: only an outcome newer than every settled
		-- one for its key may install.
		fetch_seq = 0,
		fetch_started = {},
		settled = {},
		-- experiment_key → seq of the latest HOST fetch still in flight, and
		-- the apply-mismatch refetch waiting for it to end (see
		-- refetch_stale_assignment): a host request outranks an SDK
		-- correction, a cadence attempt does not.
		host_fetch = {},
		refetch_owed = {},
		-- The host's non-adult age declarations whose fetch has not ended:
		-- experiment_key → { fence_seq, seq, decided } (see
		-- begin_host_declaration). While one stands the experiment is not
		-- served and the revalidation cadence leaves it alone; a fetch that
		-- ends without the server's answer applied withdraws the experiment
		-- (end_non_adult_declaration). A later host declaration replaces it.
		declaring = {},
		declaration_writes = {},
		recovered_declarations = {},
		declaration_prune_pending = next(declarations) ~= nil,
		-- experiment_key → true for an experiment a terminal 3xx or 4xx
		-- closed: it is not served and the cadence leaves it alone until an
		-- answered fetch for it installs, drops or withdraws its entry. In
		-- memory only, so the next session serves the kept record again.
		closed_keys = {},
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
		-- Counts consent-state TRANSITIONS (the client bumps it on every
		-- actual state change): a response whose dispatch-time epoch went
		-- stale raced a consent change — the deny→re-grant window
		-- included, where the plain current-state check reads granted
		-- again — and its constructive half must not install.
		consent_epoch = 0,
		-- Revalidation cadence state.
		revalidate_at_ms = nil,
		retry_after_ms = nil,
		backoff_attempt = 0,
		-- One-shot grammar re-mint guard (per process).
		reminted = false,
		-- Bumped whenever the serving cache is wholesale replaced under a
		-- NEW subject (the grammar re-mint's adopt): a synchronous
		-- transport can land that mid-way through a cadence batch, and
		-- the remaining PRE-remint keys must not dispatch as
		-- revalidations for the fresh subject (assignments the host never
		-- requested, with no restored attributes). The cadence loop
		-- captures this counter and stops when it moves.
		cache_generation = 0,
	}, Experiments)
	-- Serve the persisted last-known-good assignments immediately after a
	-- restart when a stored subject id exists and the record matches this
	-- exact scope. Restoration records no application and mints no subject.
	-- A durable condemnation outlives the process: a real-subjects
	-- sentinel clear that could not land before an exit left its stamp
	-- AND scope in the sidecar marker. Re-arm the clear here and REFUSE
	-- everything it covers — serving the withdrawn record until its
	-- first probe would defeat the sentinel. Loaded WITHOUT a subject
	-- gate: the marker file needs no subject to read, and its whole
	-- machinery (partition, retire, spool-load condemnation) operates on
	-- the scope string STORED IN the marker — an identity record that
	-- lost its subject field must not make the condemnation invisible
	-- while spooled withdrawn facts await re-send. The condemnation
	-- applies ONLY to the scope it was decided for (a legacy marker
	-- without one condemns conservatively): another scope's record is
	-- untouched, and the first tick settles such a stale marker. Entries
	-- stamped strictly after the condemnation are a sibling's
	-- post-sentinel authorized state and restore normally (the same
	-- survivor partition the clear itself applies); the first tick lands
	-- the clear.
	if condemned_stamp then
		ex.durable_clear_pending = condemned_stamp
		ex.durable_clear_scope = condemned_scope
		ex.clear_marker = { stamp = condemned_stamp, scope = condemned_scope }
	elseif condemned_miss == "unreadable" then
		-- The sidecar READ failed: an armed condemnation may be sitting in
		-- the unreadable file, and reading that as "no marker" would
		-- restore and serve a withdrawn record (and let a readable spool
		-- replay condemned facts). Fail CLOSED: arm the clear in its
		-- UNKNOWN form — boolean pending, stampless scope-less marker —
		-- which condemns conservatively everywhere (restores refused
		-- below, the spool filter blanket-drops, retire checks hold) and
		-- can neither demote nor partition until the sync pass re-reads
		-- the sidecar and either adopts the real stamp/scope or disproves
		-- it with a readable miss.
		ex.durable_clear_pending = true
		ex.durable_clear_scope = nil
		ex.clear_marker = { unreadable = true }
	end
	local subject = ex:current_subject_id()
	if subject then ex.recovered_declarations = declarations[ex:scope_for(subject)] or {} end
	if subject then
		local record = storage.load_experiments(config)
		if record and record.scope == ex:scope_for(subject) then
			-- The history is this subject's whatever the entries' fate
			-- below: it names facts, not assignments to serve, and the
			-- first prune (after the spool restore) keeps only keys a live
			-- fact still carries.
			ex:history_of(record.scope)
			add_fact_keys(ex.fact_key_history, record.fact_key_history)
			local record_condemned = (condemned_stamp ~= nil
				and (condemned_scope == nil or condemned_scope == record.scope))
				or condemned_miss == "unreadable"
			for key, entry in pairs(record.entries) do
				-- Memory's side of the retirement starts from the key the
				-- record holds (sync_durable_entry): a later replace or drop
				-- retires it even when the disk that write diffs against no
				-- longer shows it (the size cap evicted it, or a read came
				-- back empty).
				ex.synced_fact_keys[key] = entry.subject_fact_key
				local stored_at = type(entry.fetched_at_ms) == "number"
					and entry.fetched_at_ms or 0
				-- A client-id assignment stored without an age declaration
				-- (a release that had none, or a fetch that declared none)
				-- is neither served nor exposed: client-id admission
				-- requires a declaration. The next fetch, carrying the
				-- host's current declaration, decides the experiment and
				-- replaces this durable entry. Synthetic-subject
				-- assignments have no age gate and restore.
				local undeclared = entry.assignment_unit == "client_id"
					and not has_age_declaration(entry.attributes)
				local pending = ex.recovered_declarations[key]
				if pending and not age_exempt(entry) and entry.subject_fact_key then
					pending.fact_keys[#pending.fact_keys + 1] = entry.subject_fact_key
				end
				if not undeclared and (not pending or age_exempt(entry)) and (not record_condemned
					or (type(condemned_stamp) == "number"
						and stored_at > condemned_stamp)) then
					-- Restored attributes re-validate against the live
					-- fetch vocabulary before any revalidation can send
					-- them; malformed age declarations remain refusals,
					-- never a missing value beside an adult alias.
					entry.attributes = sanitize_restored_attributes(entry.attributes)
					entry.subject_key = entry.subject_key or subject
					ex.entries[key] = entry

				end
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
	self.http_transport:teardown()
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
	local old_subject = self:current_subject_id()
	local old_scope = old_subject and self:scope_for(old_subject) or nil
	local retired_entries = {}
	for key, held in pairs(self.entries) do
		retired_entries[key] = held
	end
	-- A new subject is a new cache scope AND a new exposure subject:
	-- assignments fetched for the old subject must neither serve nor
	-- expose GOING FORWARD, and the session's exposure de-dupe resets —
	-- the Q4 tuple is per (experiment, version, SUBJECT), so the new
	-- subject's first application must emit even where the old subject's
	-- already did. Owed exposure snapshots are deliberately RETAINED: a
	-- treatment that already ran under the old subject is a fact about the
	-- past, its fact carries the server-minted fact key (never the subject
	-- id), and its tuple — old subject included — stays distinct from
	-- anything the new subject arms.
	self.entries = {}
	-- The serving cache was wholesale replaced under a NEW subject: any
	-- cadence batch mid-iteration must stop dispatching its pre-remint
	-- keys (see tick's generation check).
	self.cache_generation = self.cache_generation + 1
	self.exposed = {}
	self.applications = {}
	-- Owed durable WRITE intents die with the rotation: their source
	-- entries were just cleared, and the retired subject's record must not
	-- be reshaped from another subject's memory. Owed DROPS survive — they
	-- carry the scope they were decided under and still land against the
	-- retired record (a failed subject persist could otherwise resurrect a
	-- kill at the next launch).
	for pending_composite, pending in pairs(self.durable_pending) do
		if not pending.drop then
			self.durable_pending[pending_composite] = nil
		end
	end
	-- The OLD scope's durable record must not outlive the rotation as
	-- reload truth: the server just rejected this subject's grammar, but
	-- the identity persist below is best-effort — if it FAILS, a relaunch
	-- restores the OLD subject and would serve the very assignments the
	-- re-mint retired. Mint decisive per-key DROPS against the old scope
	-- (stamped above each entry, rollback-proof) — they land through the
	-- foreign-scope drop retries whether or not the identity write
	-- succeeds (a healthy remint's old record is dead weight anyway).
	-- The tombstones come from live memory UNION the old durable scope,
	-- read HERE at remint time: an ordinary 401/403 latch clears live
	-- memory while intentionally RETAINING the cache file, so live
	-- entries alone would cover nothing exactly when the durable record
	-- still holds the rejected subject's assignments. An UNREADABLE read
	-- arms a conservative whole-old-scope drop instead — STAMPLESS, by
	-- design: a grammar-rejected subject's scope must never serve again,
	-- so no survivor class exists to partition for. It stays owed over
	-- unreadable passes (the fail-closed canon) and lands as a wholesale
	-- clear on the first readable one, leaving only the storage-dead-
	-- through-exit window as the documented residual.
	if old_scope then
		local now_ms = clock.unix_ms()
		local record, record_miss = storage.load_experiments(self.config)
		if record == nil and record_miss == "unreadable" then
			self.durable_pending[old_scope .. scope_separator] = {
				key = "",
				scope = old_scope,
				as_of = now_ms,
				drop = true,
				scope_wide = true,
			}
		else
			if record ~= nil and record.scope == old_scope then
				for key, stored in pairs(record.entries) do
					if retired_entries[key] == nil then
						retired_entries[key] = stored
					end
				end
			end
			for key, held in pairs(retired_entries) do
				local held_at = type(held) == "table"
					and type(held.fetched_at_ms) == "number"
					and held.fetched_at_ms or 0
				local drop_as_of = now_ms
				if held_at >= drop_as_of then
					drop_as_of = held_at + 1
				end
				self.durable_pending[old_scope .. scope_separator .. key] = {
					key = key,
					scope = old_scope,
					as_of = drop_as_of,
					drop = true,
				}
			end
		end
	end
	if not self.deps.store_subject_id(minted) then
		self:diagnose("persist_failed", "subject_id")
	end
	return minted
end

-- An end closes deduplication and outcome attribution. Existing owed records
-- retain the session in which the host applied them.
function Experiments:on_session_ended(ended_session_id)
	if type(ended_session_id) == "string" and ended_session_id ~= "" then
		for _, list in pairs(self.pending_exposure) do
			for i = 1, #list do
				if list[i].session_id == nil and list[i].session == self.session_marker then
					list[i].session_id = ended_session_id
				end
			end
		end
	end
	self.session_marker = id.uuid()
	self.exposed = {}
	self.applications = {}
end

-- A renewed session accepts a new explicit application of every tuple.
function Experiments:on_session_renewed()
	self.session_marker = id.uuid()
	self.exposed = {}
	self.applications = {}
end

-- Consent denial withdraws both application stages and last-applied state.
-- A later grant requires another explicit application.
function Experiments:on_analytics_purge()
	self.pending_exposure = {}
	self.exposed = {}
	self.applications = {}
	-- The purged facts no longer hold their history keys.
	self.fact_key_prune_owed = true
end

function Experiments:scope_for(subject_id)
	return M.build_scope(
		self.config.workspace_id,
		self.config.environment_id,
		subject_id,
		self.config.app_url,
		self.config.publishable_key)
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
-- any other scope is dead weight and is overwritten by the next write). The
-- second return is "unreadable" when the store ERRORED on the read: the
-- collapse to an empty record is then a blind guess, not a decided miss, and
-- callers that would treat "absent" as "already converged" must be able to
-- tell the difference. The corrupt-is-a-miss canon is untouched — a record
-- that read but failed sanitation stays a plain miss (same bytes parse the
-- same way forever), and so does a readable record another scope replaced.
function Experiments:durable_record_for(scope)
	local record, miss = storage.load_experiments(self.config)
	if record and record.scope == scope then
		return record
	end
	return { scope = scope, entries = {} },
		record == nil and miss == "unreadable" and "unreadable" or nil
end

-- ── the fact-key history ──────────────────────────────────────────────────────
--
-- Per (experiment, subject): the subject-fact keys that live facts may still
-- carry after the entry that minted them left the record. The server rotates
-- the key on every published version, so a republish replaces it; a drop
-- deletes it, and a kill switch's drop-time capture is a plain envelope whose
-- key is all that ties it to the subject. An age refusal withdraws facts
-- under these keys too (apply_age_withdrawal). A key stays while any live
-- fact references it — queued, in the retained or on-the-wire batch, in a
-- loaded spool chunk, in the durable spool less its settled entries, or in an
-- owed exposure snapshot — and is pruned once the last one is delivered,
-- dropped or withdrawn. No count bound: the spool's own caps bound it. The
-- record is one subject's, so memory holds one scope's history at a time.

-- Memory's history for `scope`. Another scope (a re-mint) starts empty: the
-- retired subject can no longer be refused, every outcome being scope-fenced.
function Experiments:history_of(scope)
	if self.fact_key_history_scope ~= scope then
		self.fact_key_history_scope = scope
		self.fact_key_history = {}
		self.synced_fact_keys = {}
	end
	return self.fact_key_history
end

-- Retire `fact_key` of `experiment_key` into `scope`'s history.
function Experiments:retire_fact_key(scope, experiment_key, fact_key)
	if type(fact_key) ~= "string" or fact_key == "" then
		return
	end
	local history = self:history_of(scope)
	local set = history[experiment_key] or {}
	set[fact_key] = true
	history[experiment_key] = set
end

-- Drop from `history` every key no live fact references any more: the
-- client's pipeline surfaces (deps.live_fact_keys) plus this consumer's owed
-- snapshots. A no-op until the spool is restored — pruning earlier would
-- forget a key that a chunk about to be restored still carries.
function Experiments:prune_history(history)
	if not self.fact_keys_restored or not self.deps.live_fact_keys then
		return
	end
	for experiment_key, set in pairs(history) do
		local live = self.deps.live_fact_keys(experiment_key) or {}
		local owed = self.pending_exposure[experiment_key]
		if type(owed) == "table" then
			for i = 1, #owed do
				local held = owed[i].entry
				if held and type(held.subject_fact_key) == "string" then
					live[held.subject_fact_key] = true
				end
			end
		end
		for key in pairs(set) do
			if not live[key] then
				set[key] = nil
			end
		end
		if next(set) == nil then
			history[experiment_key] = nil
		end
	end
end

-- The history a durable write of `scope`'s record carries: memory's plus the
-- record's own section (`on_disk`, durable shape), pruned. Memory adopts the
-- result whether or not the write then lands, so a failed write loses no key.
function Experiments:settle_fact_key_history(scope, on_disk)
	local history = self:history_of(scope)
	add_fact_keys(history, on_disk)
	self:prune_history(history)
	return listed_fact_keys(history)
end

-- Write `record` (the durable record of the history's scope, or a fresh
-- stub for it) when its section differs from the settled history. A stub
-- is written only when a history remains to carry. Returns false when that
-- write failed: the key stays in memory for the next write that lands, and
-- the caller decides whether the write is owed.
function Experiments:save_fact_key_history(record)
	local on_disk = record.fact_key_history or {}
	local settled = self:settle_fact_key_history(record.scope, on_disk)
	if not same_fact_keys(settled, on_disk) then
		record.fact_key_history = settled
		return (storage.save_experiments(self.config, record))
	end
	return true
end

-- Return the journal justified by the actual cache and live fact references.
-- This also runs for a rollback without constructing an experiment consumer.
function M.settled_declarations(config, live_fact_keys, active)
	local records, miss = storage.load_experiment_declarations(config)
	if miss then return nil, false, miss end
	if next(records) == nil then return records, false end
	local cached, cache_miss = storage.load_experiments(config)
	if cache_miss == "unreadable" then return nil, false, cache_miss end
	local changed = false
	for scope, experiments in pairs(records) do
		for key, marker in pairs(experiments) do
			if not (active and active(scope, key)) then
				local entry = cached and cached.scope == scope and cached.entries[key]
				local guarded = entry and not age_exempt(entry)
				local live = live_fact_keys(key) or {}
				local kept = {}
				for _, fact_key in ipairs(marker.fact_keys) do
					if live[fact_key] or (guarded and entry.subject_fact_key == fact_key) then kept[#kept + 1] = fact_key end
				end
				if not guarded and #kept == 0 then experiments[key] = nil; changed = true
				elseif #kept ~= #marker.fact_keys then marker.fact_keys = kept; changed = true end
			end
		end
		if next(experiments) == nil then records[scope] = nil end
	end
	return records, changed
end

function Experiments:prune_declaration_markers()
	if not self.declaration_prune_pending or not self.fact_keys_restored or not self.deps.live_fact_keys then return end
	if self.deps.withdrawal_persist_pending and self.deps.withdrawal_persist_pending() then return end
	local records, changed = M.settled_declarations(self.config, function(key)
		local live = self.deps.live_fact_keys(key) or {}
		for _, owed in ipairs(self.pending_exposure[key] or {}) do
			local entry = owed.entry
			if entry and type(entry.subject_fact_key) == "string" then live[entry.subject_fact_key] = true end
		end
		return live
	end, function(scope, key)
		local declaration = self.declaring[key]
		return self.declaration_writes[scope .. scope_separator .. key] ~= nil
			or (declaration and declaration.scope == scope)
	end)
	if not records then return end
	self.declaration_prune_owed = changed and not storage.save_experiment_declarations(self.config, records) or false
	self.declaration_prune_pending = next(records) ~= nil or self.declaration_prune_owed
end

-- Prune the current subject's history, and rewrite the durable section when
-- it changed. Runs after a publish settles, after an age withdrawal, at load
-- once the spool is restored, and on the tick after a cap eviction or a
-- purge. Best-effort: a failed save leaves a key on disk that the next write
-- or prune removes, and nothing is owed. Only an existing record of this
-- scope is rewritten; creating one is the durable write's business.
function Experiments:prune_fact_key_history()
	self:prune_declaration_markers()
	self.fact_key_prune_owed = false
	if next(self.fact_key_history) == nil then
		-- The common case, answered without a read: memory holds every key
		-- this process retired or loaded.
		return
	end
	local subject = self:current_subject_id()
	if not subject then
		return
	end
	local scope = self:scope_for(subject)
	if next(self:history_of(scope)) == nil then
		return
	end
	local record = storage.load_experiments(self.config)
	local on_disk = record and record.scope == scope
		and record.fact_key_history or nil
	local settled = self:settle_fact_key_history(scope, on_disk)
	if on_disk and not same_fact_keys(settled, on_disk) then
		record.fact_key_history = settled
		storage.save_experiments(self.config, record)
	end
end

-- The client restored its spool (or had none to restore): liveness is known
-- from here on, and the history loaded with the record prunes now.
function Experiments:on_spool_restored()
	self.fact_keys_restored = true
	local subject = self:current_subject_id()
	if subject then
		local scope = self:scope_for(subject)
		for key, marker in pairs(self.recovered_declarations) do
			-- The spool now exists, so the normal withdrawal reaches durable
			-- accepted facts as well as the withheld assignment and history.
			self:apply_age_withdrawal(scope, key, clock.unix_ms(), marker.fact_keys,
				age_exempt(self.entries[key]))
			self:write_declaration_marker(scope, key, nil, age_exempt(self.entries[key]))
		end
	end
	self.recovered_declarations = {}
	self:prune_fact_key_history()
end

-- Converge one experiment's durable entry to the in-memory truth: an entry
-- present in memory is written, an absent one is dropped. `as_of_ms` stamps
-- the state change (the entry's own fetch time for a write, the resolution
-- time for a drop) and drives the sibling freshness fence. `is_retry` marks
-- an owed-sync retry: only there does the fence apply to DROPS — at decision
-- time a drop resolves whatever the shared record holds, clock rollbacks
-- included, and its stamp is raised ABOVE that record; a retry may instead
-- run after a sibling client persisted a genuinely newer assignment the
-- drop never saw, and yields to it. Returns true when the disk agrees with
-- memory (written, already-agreeing, or outranked by a fresher sibling
-- state — all settled); false marks the key owed with the raised stamp and
-- the intent (a later ordinary fail-closed latch cancels owed WRITES but
-- must let owed authoritative DROPS land).
function Experiments:sync_durable_entry(scope, experiment_key, as_of_ms, is_retry)
	local composite = scope .. scope_separator .. experiment_key
	local prior = self.durable_pending[composite]
	local entry = self.entries[experiment_key]
	if entry == nil and prior ~= nil and not prior.drop
		and prior.entry ~= nil then
		-- A sentinel wiped this post-dispatch survivor from memory while
		-- its install save was still owed: the intent carries the entry
		-- snapshot, and the write lands from it.
		entry = prior.entry
	end
	-- Memory's side of the fact-key retirement: the key memory converged
	-- this experiment toward last time leaves when this sync converges
	-- toward another key or none. Retired before any early return below,
	-- so a write that yields, fails, or finds nothing stored to drop still
	-- keeps it for the next write that lands.
	self:history_of(scope)
	local converging = entry and entry.subject_fact_key or nil
	if self.synced_fact_keys[experiment_key] ~= converging then
		self:retire_fact_key(scope, experiment_key,
			self.synced_fact_keys[experiment_key])
		self.synced_fact_keys[experiment_key] = converging
	end
	local record, record_miss = self:durable_record_for(scope)
	-- The durable side: every entry's key as the record holds it now,
	-- diffed below against what this write leaves.
	local stored_fact_keys = {}
	for key, held in pairs(record.entries) do
		stored_fact_keys[key] = held.subject_fact_key
	end
	local stored = record.entries[experiment_key]
	local as_of = type(as_of_ms) == "number" and as_of_ms or 0
	if entry then
		if stored and type(stored.fetched_at_ms) == "number"
			and stored.fetched_at_ms > entry.fetched_at_ms then
			if is_retry then
				-- A same-namespace sibling persisted a FRESHER entry after
				-- this write was decided: never roll the shared record
				-- back.
				self.durable_pending[composite] = nil
				return true
			end
			-- At DECISION time a fresh authoritative write supersedes the
			-- stored record exactly like a drop does: the wall clock can
			-- move backward across a refresh, and yielding on raw stamps
			-- would leave the SUPERSEDED variant as reload truth while
			-- memory serves the new one. Raise the entry's stamp above the
			-- record instead — memory and disk stay consistent, and an
			-- owed retry of this write still outranks the superseded
			-- record while yielding to genuinely newer sibling writes.
			entry.fetched_at_ms = stored.fetched_at_ms + 1
		end
		record.entries[experiment_key] = entry
	else
		if stored == nil then
			if record_miss == "unreadable" then
				-- The store ERRORED on the read: the absent stored entry
				-- proves nothing — the old on-disk record may still hold
				-- this experiment, and settling the drop over a blind read
				-- would let any launch that reads the file again restore
				-- and serve the killed assignment. The drop stays OWED
				-- instead, as an OPEN decision: the decision-time raise
				-- over the stored record (the rollback guard below) is
				-- part of deciding, so the first READABLE pass re-runs
				-- decision semantics (the `undecided` mark), never the
				-- retry fence that yields to rollback-inflated stamps. No
				-- blind write is forced either: unlike an owed WRITE —
				-- which converges the disk to live memory and whose worst
				-- case (an unreadable sibling entry overwritten) is
				-- refetch-safe absence — a drop expresses itself BY
				-- absence, so a blind near-empty save buys nothing the
				-- owed retry does not while wiping every sibling entry
				-- the failed read hid. Permanently unreadable storage
				-- keeps the key owed — persist()/shutdown() report it
				-- honestly — and a death in that window is the documented
				-- storage-down-through-exit residual.
				self.durable_pending[composite] = {
					key = experiment_key,
					scope = scope,
					as_of = as_of,
					drop = true,
					undecided = true,
				}
				if not is_retry then
					self:diagnose("persist_failed", "cache_unreadable")
				end
				return false
			end
			-- Nothing is stored to drop: the entry never reached the disk
			-- (its own write failed, or the size cap evicted it). The key
			-- this sync just retired can still name spooled facts, so the
			-- record's section takes it now; otherwise a relaunch would
			-- have no key to withdraw them by. That write is the drop's
			-- durable work: when it fails, the drop stays owed, so the
			-- retry lands the section and persist() reports it meanwhile.
			if self:save_fact_key_history(record) then
				self.durable_pending[composite] = nil
				return true
			end
			self.durable_pending[composite] = {
				key = experiment_key,
				scope = scope,
				as_of = as_of,
				drop = true,
			}
			if not is_retry then
				self:diagnose("persist_failed", "cache")
			end
			return false
		end
		local deciding = not is_retry
			or (prior ~= nil and prior.undecided == true)
		local stored_at = type(stored.fetched_at_ms) == "number"
			and stored.fetched_at_ms or 0
		if not deciding and stored_at > as_of then
			-- The RETRY of an owed drop found an entry stamped after the
			-- drop was decided: a sibling client persisted a newer
			-- assignment this drop never resolved. Deleting it would lose
			-- newer valid state, so the outranked drop settles instead.
			self.durable_pending[composite] = nil
			return true
		end
		if deciding and stored_at >= as_of then
			-- At DECISION time a drop always wins over the stored record it
			-- resolves: the wall clock can move backward, and fencing the
			-- delete on raw stamps would let a rollback revive a killed
			-- variant at the next launch. Raise the drop's effective stamp
			-- above the record instead — the kill lands now, and an owed
			-- retry yields only to entries genuinely written AFTER this
			-- decision. A drop held open by an unreadable read (`undecided`)
			-- completes its decision HERE, on its first readable pass — the
			-- fence was never fair while the comparator was blind. A failed
			-- save below re-records the pending with the raised stamp and
			-- without the mark: the decision is complete either way.
			as_of = stored_at + 1
		end
		record.entries[experiment_key] = nil
	end
	-- Owed intents for OTHER keys of THIS scope ride every combined-record
	-- save — the record is one file, so a save that reloaded the disk copy
	-- would otherwise re-persist a sibling entry whose authoritative DROP
	-- is still owed (resurrecting a kill at the next launch) or a sibling's
	-- STALE variant whose refreshed WRITE is still owed (rolling the reload
	-- truth back). Drops fold when memory holds no live entry, honoring
	-- their retry fence (a sibling record stamped strictly after the drop's
	-- decision is newer state, left for that drop's own retry); writes fold
	-- from the LIVE in-memory entry, honoring the write fence the same way.
	-- Intents decided under ANOTHER scope never fold into this record.
	local swept = nil
	for pending_composite, pending in pairs(self.durable_pending) do
		if pending.scope == scope and pending.key ~= experiment_key then
			local live = self.entries[pending.key]
			local sibling = record.entries[pending.key]
			local sibling_at = sibling ~= nil
				and type(sibling.fetched_at_ms) == "number"
				and sibling.fetched_at_ms or 0
			local folded = false
			if pending.drop and live == nil then
				if sibling == nil or sibling_at <= pending.as_of then
					record.entries[pending.key] = nil
					folded = true
				end
			elseif not pending.drop and live ~= nil
				and type(live.fetched_at_ms) == "number" then
				if sibling == nil or sibling_at <= live.fetched_at_ms then
					record.entries[pending.key] = live
					folded = true
				end
			end
			if folded then
				swept = swept or {}
				swept[#swept + 1] = pending_composite
			end
		end
	end
	-- A key that leaves the record's entries in this write — replaced by an
	-- install under another version's key, or deleted by any drop (a kill
	-- switch's included: its drop body is untouched, it reaches the disk
	-- only through here) — is retired into the fact-key history IN THIS
	-- SAME WRITE, and the section the record carries is settled with it.
	for key, fact_key in pairs(stored_fact_keys) do
		local kept = record.entries[key]
		if kept == nil or kept.subject_fact_key ~= fact_key then
			self:retire_fact_key(scope, key, fact_key)
		end
	end
	record.fact_key_history = self:settle_fact_key_history(scope,
		record.fact_key_history)
	local record_saved, cap_evicted = storage.save_experiments(self.config, record)
	if record_saved then
		if type(cap_evicted) == "number" and cap_evicted > 0 then
			-- Cap-evicted entries are terminally non-durable: the size
			-- bound is deterministic, so this is a settled outcome, not an
			-- owed retry — memory serves the evicted entries for this
			-- process and the next launch refetches them. Surfaced once
			-- per save so the durability gap is observable.
			self:diagnose("persist_failed", "cache_record_oversize_evicted")
		end
		self.durable_pending[composite] = nil
		if swept then
			for i = 1, #swept do
				self.durable_pending[swept[i]] = nil
			end
		end
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
	self.durable_pending[composite] = {
		key = experiment_key,
		scope = scope,
		as_of = as_of,
		drop = entry == nil,
		-- A snapshot-backed write (its key absent from live memory) keeps
		-- its source data across failed retries.
		entry = (entry ~= nil and self.entries[experiment_key] == nil)
			and entry or nil,
	}
	self:diagnose("persist_failed", "cache")
	return false
end

-- Demote an owed whole-record clear into per-key drops for exactly the keys
-- the clear still covers — disk entries memory does not hold whose stamps do
-- NOT outrank the clear. The clear's stamp was raised at decision time above
-- everything the sentinel withdrew, so an entry stamped STRICTLY after it
-- can only be a post-sentinel authorized write (a same-app sibling's fresh
-- assignment): those SURVIVE — the owed clear covers only the record that
-- existed when the sentinel landed, never state written after it. Covered
-- keys become per-key drops stamped by the clear (already decisive over
-- them), and the per-key sync converges those. Runs from the retry tick AND
-- at fresh-install time:
-- a fresh authorized assignment landing after the failed clear supersedes
-- the whole-record form immediately, so a later ordinary auth latch —
-- which empties memory while RETAINING the durable record — can never
-- leave the stale clear armed to wipe state written after it.
function Experiments:demote_owed_clear()
	if not self.durable_clear_pending then
		return
	end
	if self.durable_clear_pending == true then
		-- The clear is armed in its UNKNOWN form (an unreadable sidecar:
		-- stamp and scope unrecoverable): nothing can be demoted on it —
		-- there is no stamp to partition covered keys by. The sync pass
		-- re-reads the sidecar and settles the form first; until then the
		-- intent stays owed and conservative.
		return
	end
	local clear_as_of = type(self.durable_clear_pending) == "number"
		and self.durable_clear_pending or 0
	local clear_scope = self.durable_clear_scope
	local record, record_miss = storage.load_experiments(self.config)
	if record == nil and record_miss == "unreadable" then
		-- The record READ failed: the demotion cannot prove which covered
		-- keys remain, so consuming the whole-record intent here would
		-- leave NOTHING owed in this process — has_owed_durable_sync()
		-- would report clean, persist()/shutdown() would claim safety, and
		-- the retries would stop while condemned entries still sit in the
		-- (currently unreadable) file. The sidecar marker alone is an
		-- exit-time guard, not a convergence engine. Keep the intent
		-- pending; the next readable pass demotes it into per-key drops
		-- (or settles it) with real evidence.
		return
	end
	self.durable_clear_pending = false
	self.durable_clear_scope = nil
	-- The durable condemnation marker is deliberately NOT retired here:
	-- the per-key drops this demotion mints are memory intents until
	-- their syncs land, and an exit in that window must still find the
	-- durable refusal — otherwise a restart would restore the covered
	-- stale entries the sentinel withdrew. The marker retires at the
	-- durable-state check once nothing it condemns remains on disk.
	if not record then
		return
	end
	if clear_scope and record.scope ~= clear_scope then
		-- Another scope's record replaced the condemned one wholesale:
		-- nothing the clear covered remains, so no drops are minted and
		-- the marker retires with the vanished target.
		self:retire_clear_marker()
		return
	end
	for key, stored in pairs(record.entries) do
		local stored_at = type(stored) == "table"
			and type(stored.fetched_at_ms) == "number"
			and stored.fetched_at_ms or 0
		if self.entries[key] == nil and stored_at <= clear_as_of then
			-- The conversion drops target the RECORD's scope — the state
			-- the clear was decided over — which may already be a retired
			-- subject's. Entries stamped strictly after the clear are a
			-- sibling's post-sentinel authorized state and get no drop.
			self.durable_pending[record.scope .. scope_separator .. key] = {
				key = key,
				scope = record.scope,
				as_of = clear_as_of,
				drop = true,
			}
		end
	end
end

-- Retry every owed durable write (and an owed whole-record clear) so the
-- disk converges as soon as storage recovers, instead of waiting for an
-- unrelated write or a relaunch. Local disk housekeeping only: no network,
-- no serving decisions, so it runs regardless of the consent state — a
-- kill drop decided under grant must land durably even if consent flips.
function Experiments:retry_durable_sync()
	self:prune_declaration_markers()
	local writes = {}
	for composite, pending in pairs(self.declaration_writes) do
		writes[#writes + 1] = { composite = composite, pending = pending }
	end
	for i = 1, #writes do
		local pending = writes[i].pending
		self:write_declaration_marker(pending.scope, pending.key, pending.marker, pending.keep_assignment)
	end
	if self.durable_clear_pending == true then
		-- The clear is armed in its UNKNOWN form (the sidecar was
		-- unreadable at construction): re-read it each pass. A healed read
		-- adopts the real stamp/scope — the normal demote/retry machinery
		-- resumes on the next pass with real evidence. A READABLE miss
		-- (absent file, or parsed-corrupt — the corrupt-is-a-miss canon
		-- read positively) disproves the marker: disarm, and retire
		-- through the chokepoint (which overwrites the garbled sidecar,
		-- and still holds while condemned spool debt is owed — an
		-- unretired marker file then keeps the next launch fail-closed,
		-- exactly as intended). Still-unreadable stays armed and owed.
		local stamp, marker_scope, marker_miss =
			storage.load_experiments_clear(self.config)
		if stamp then
			self.durable_clear_pending = stamp
			self.durable_clear_scope = marker_scope
			self.clear_marker = { stamp = stamp, scope = marker_scope }
		elseif marker_miss ~= "unreadable" then
			self.durable_clear_pending = false
			self.durable_clear_scope = nil
			self:retire_clear_marker()
		end
	elseif self.durable_clear_pending then
		if next(self.entries) ~= nil then
			-- Newer authorized state was installed after the failed clear:
			-- the epoch-scoped clear must not wipe it — demote it to the
			-- per-key drops it still covers.
			self:demote_owed_clear()
		else
			-- Local memory is empty (latched) — but the DISK is inspected
			-- before anything clears: a same-app sibling may have persisted
			-- fresh authorized state since the sentinel landed, and the
			-- owed clear covers only the record that existed then.
			self:retry_owed_clear()
		end
	end
	if next(self.durable_pending) == nil then
		self:retire_clear_marker_if_settled()
		return
	end
	local subject = self:current_subject_id()
	if not subject then
		self:retire_clear_marker_if_settled()
		return
	end
	local scope = self:scope_for(subject)
	local composites = {}
	for pending_composite in pairs(self.durable_pending) do
		composites[#composites + 1] = pending_composite
	end
	table.sort(composites)
	for i = 1, #composites do
		-- An earlier iteration's combined-record save may have SWEPT this
		-- intent along with it (settling the pending): skip what already
		-- converged.
		local pending = self.durable_pending[composites[i]]
		if pending then
			if pending.scope == scope then
				self:sync_durable_entry(scope, pending.key, pending.as_of, true)
			elseif pending.drop then
				-- Decided under a RETIRED scope (the subject re-minted
				-- while the drop was owed): the kill must still land
				-- against THAT record — current memory is another
				-- subject's truth and is never consulted for it.
				self:retry_foreign_scope_drop(composites[i], pending)
			else
				-- A foreign-scope WRITE intent has no source data left
				-- (the rotation cleared the retired subject's entries;
				-- rotation also cancels these — this is the belt).
				self.durable_pending[composites[i]] = nil
			end
		end
	end
	self:retire_clear_marker_if_settled()
end

-- Retry an owed whole-record clear while local memory is EMPTY (this
-- instance is latched). Never a blind whole-file clear: the disk record is
-- partitioned by the clear's raised stamp — entries stamped STRICTLY after
-- it can only be post-sentinel authorized writes (a same-app sibling's
-- fresh assignment) and SURVIVE; covered entries are removed. The whole
-- file clears only when nothing survives (an unreadable record included:
-- corrupt is a miss everywhere else, and the sentinel's mandate stands for
-- it). Consistent with the foreign-scope drop retry below: stamp-fenced
-- per-key convergence against the record actually on disk.
-- Retire the durable condemnation marker (best-effort: a lingering marker
-- is harmless — nothing it condemns remains when this is called, so a
-- failed delete just means a later pass, or the next construction's first
-- tick, retries it).
function Experiments:retire_clear_marker()
	if self.deps.spool_condemned_pending and self.deps.spool_condemned_pending() then
		-- Condemned spool content is still on disk (a condemnation-filter
		-- or purge rewrite that could not land): the marker is the only
		-- durable refusal that survives an exit, and retiring it now —
		-- from ANY settle path: the record clear landing, a demotion's
		-- vanished target, the periodic settled check — would let the
		-- launch after next replay the withdrawn facts from the stale
		-- file. Held until the spool clear lands; a lingering marker over
		-- settled record state condemns nothing meanwhile (the stamp
		-- partition spares post-sentinel facts), and the settled check
		-- retires it once the debt clears.
		return
	end
	if storage.clear_experiments_clear(self.config) then
		self.clear_marker = nil
	end
end

-- Settle the owed whole-record clear: the state it condemned no longer
-- exists on disk (just cleared, rewritten to survivors only, or replaced
-- wholesale by another scope's record), so the durable marker retires with
-- it.
function Experiments:settle_owed_clear()
	self.durable_clear_pending = false
	self.durable_clear_scope = nil
	self:retire_clear_marker()
end

function Experiments:retry_owed_clear()
	local clear_as_of = type(self.durable_clear_pending) == "number"
		and self.durable_clear_pending or 0
	local clear_scope = self.durable_clear_scope
	local record, record_miss = storage.load_experiments(self.config)
	if record == nil and record_miss == "unreadable" then
		-- The record could not be READ: nothing is proved, so nothing may
		-- be consumed (the demotion rule, applied to the whole-record
		-- form). The old blind whole-file clear here would delete a
		-- POST-SENTINEL sibling assignment the dispatch-bound partition
		-- exists to preserve — and then retire the marker over that loss.
		-- The clear stays owed and armed; only a readable pass partitions
		-- survivors, and a still-unreadable store keeps the state honest
		-- (has_owed_durable_sync true, marker held).
		return
	end
	if record and clear_scope and record.scope ~= clear_scope then
		-- Another scope's write replaced the condemned record wholesale:
		-- the clear's target no longer exists, and a sentinel for one
		-- environment/credential never condemns another scope's entries —
		-- settle without touching the foreign record.
		self:settle_owed_clear()
		return
	end
	local survivors = nil
	local covered = false
	if record then
		for key, stored in pairs(record.entries) do
			local stored_at = type(stored) == "table"
				and type(stored.fetched_at_ms) == "number"
				and stored.fetched_at_ms or 0
			if stored_at > clear_as_of then
				survivors = survivors or {}
				survivors[key] = stored
			else
				covered = true
			end
		end
	end
	if not survivors then
		if storage.clear_experiments(self.config) then
			-- The cleared file settles the owed DROPS (their stored
			-- targets are gone with it) — but a SNAPSHOT-BACKED write is a
			-- post-dispatch survivor whose landing is still owed: the
			-- sentinel's clear never covered it, and wiping its intent
			-- here would lose the authorized assignment the dispatch-bound
			-- partition preserved through the memory wipe. It stays owed
			-- and lands on this same sync pass.
			for pending_composite, pending in pairs(self.durable_pending) do
				if pending.drop or pending.entry == nil then
					self.durable_pending[pending_composite] = nil
				end
			end
			self:settle_owed_clear()
		end
		return
	end
	if not covered then
		-- Everything on disk postdates the sentinel: the clear's targets
		-- are already gone (a refreshed record replaced the file
		-- wholesale) and the clear settles without touching the sibling's
		-- state. Per-key owed intents stay to converge on their own
		-- fences.
		self:settle_owed_clear()
		return
	end
	record.entries = survivors
	if storage.save_experiments(self.config, record) then
		-- The covered keys are gone; the sibling's post-sentinel state
		-- stays. Per-key owed intents are NOT wiped with the settled
		-- clear — drops for covered keys settle on their own retries
		-- (the stored entry is gone), and anything targeting a survivor
		-- is protected by the usual strictly-fresher retry fences.
		self:settle_owed_clear()
	end
end

-- Retire a demotion-outlived condemnation marker once NOTHING it condemns
-- remains durable: the demoted per-key drops (or the replacement record)
-- must actually be on disk before the durable refusal may disappear —
-- retiring at the demotion decision would leave an exit window in which a
-- restart restores the withdrawn variants. Runs after every durable-sync
-- pass and after an install's combined save.
function Experiments:retire_clear_marker_if_settled()
	if not self.clear_marker or self.durable_clear_pending then
		return
	end
	if self.deps.spool_condemned_pending and self.deps.spool_condemned_pending() then
		-- Condemned spool content still on disk: not settled — "record
		-- clean" is half the condition (retire_clear_marker enforces the
		-- same rule as the chokepoint; this early-out just skips the
		-- record read).
		return
	end
	local record, miss = storage.load_experiments(self.config)
	if record == nil and miss == "unreadable" then
		-- The record could not be READ — the store errored, which is
		-- distinct from a readable miss or a parsed-but-corrupt record.
		-- What the marker condemns may still sit on disk (especially with
		-- demoted drops still owed), so this is NOT settled: retiring here
		-- and exiting would lose the only durable refusal and the next
		-- launch would serve the withdrawn record until its first probe.
		-- Keep the marker; a later pass retires it once a readable state
		-- (or a successful rewrite) proves nothing condemned remains.
		return
	end
	local remaining = false
	if record and (self.clear_marker.scope == nil
		or record.scope == self.clear_marker.scope) then
		-- A STAMPLESS marker (the unreadable-sidecar form held alive by
		-- spool debt) condemns conservatively: any in-scope entry counts
		-- as remaining, so it retires only over a genuinely empty record.
		local marker_stamp = type(self.clear_marker.stamp) == "number"
			and self.clear_marker.stamp or math.huge
		for _, stored in pairs(record.entries) do
			local stored_at = type(stored) == "table"
				and type(stored.fetched_at_ms) == "number"
				and stored.fetched_at_ms or 0
			if stored_at <= marker_stamp then
				remaining = true
			end
		end
	end
	if not remaining then
		self:retire_clear_marker()
	end
end

-- Land an owed DROP decided under a scope the subject has since rotated
-- away from. The retired record must still lose the killed entry — a failed
-- subject-id persist can put the OLD subject back at the next launch, and
-- the kill must not resurrect — but current memory belongs to the NEW
-- subject and is never consulted. A new-scope write replaces the record
-- file wholesale, so a scope mismatch on load means the retired record no
-- longer exists and the drop settles; the usual retry fence still yields to
-- an old-scope sibling instance's strictly fresher write.
function Experiments:retry_foreign_scope_drop(composite, pending)
	local record, miss = storage.load_experiments(self.config)
	if record == nil and miss == "unreadable" then
		-- The store ERRORED on the read (same rule as the in-scope sync):
		-- "no record" is a blind guess, not proof the retired record is
		-- gone — settling here would let a later readable launch resurrect
		-- the killed entry under the restored old subject. The drop stays
		-- owed for the next pass.
		return
	end
	if not record or record.scope ~= pending.scope then
		self.durable_pending[composite] = nil
		return
	end
	if pending.scope_wide then
		-- The remint's unreadable-fallback condemnation: this record IS the
		-- rejected subject's (a scope mismatch settled above), and the whole
		-- scope is dead — stampless by design, no survivor class exists for
		-- a scope that must never serve again. A wholesale clear lands it;
		-- the unreadable pass above kept it owed.
		if storage.clear_experiments(self.config) then
			self.durable_pending[composite] = nil
		end
		return
	end
	local stored = record.entries[pending.key]
	if stored == nil then
		self.durable_pending[composite] = nil
		return
	end
	local stored_at = type(stored.fetched_at_ms) == "number"
		and stored.fetched_at_ms or 0
	if stored_at > pending.as_of then
		self.durable_pending[composite] = nil
		return
	end
	record.entries[pending.key] = nil
	if storage.save_experiments(self.config, record) then
		self.durable_pending[composite] = nil
	end
end

-- The Q4 de-dupe tuple: (experiment, version, subject) — exactly the
-- documented contract, nothing more. The assignment key is deliberately NOT
-- part of it: it is normally deterministic for this tuple anyway, and a
-- regenerated key for the same tuple must not over-count exposures. The
-- emitted fact still carries the current fact key as a PROP.
local function exposure_tuple(experiment_key, entry)
	return experiment_key .. "\31" .. (entry.version_wire or string.format("%.0f", entry.version))
		.. "\31" .. tostring(entry.subject_key)
end

-- Each experiment's owed exposures are a small FIFO of applied-entry
-- snapshots (bounded; overflowing drops the OLDEST with a diagnostic), so a
-- new application displacing the slot cannot silently lose the previous
-- application's still-unemitted fact.
local max_owed_exposures = 8

-- A host application pins the serving inputs and its analytics identity once.
-- Fetches, getters and cache restoration never call this path.
function Experiments:exposure_snapshot(entry)
	local at = clock.iso_utc()
	return {
		entry = copy_value(entry, 0),
		session = self.session_marker,
		session_id = self.deps.analytics_session and self.deps.analytics_session() or nil,
		anonymous_id = self.deps.analytics_anonymous_id and self.deps.analytics_anonymous_id() or nil,
		application_id = random.hex(32),
		applied_at = at,
		event_ts = at,
	}
end

function Experiments:queue_application(experiment_key, record)
	local list = self.pending_exposure[experiment_key] or {}
	self.pending_exposure[experiment_key] = list
	list[#list + 1] = record
	if #list > max_owed_exposures then
		table.remove(list, 1)
		self:diagnose("fact_skipped", "owed_overflow")
	end
end

local function serving_pins(entry)
	return facts.integer(entry.version_wire, 1)
		and facts.integer(entry.served_revision_wire, 0)
		and type(entry.served_kill_gate) == "boolean"
		and type(entry.served_at) == "string" and entry.served_at ~= ""
end

function Experiments:pace_apply(retry_after)
	self:pace_transient(retry_after)
	-- Assignment fetch allows an immediate first retry; update-driven apply
	-- work needs a floor so offline/malformed responses cannot spin each frame.
	if not self.retry_after_ms or self.retry_after_ms <= clock.unix_ms() then
		self:defer_revalidation(backoff_base_seconds)
	end
end

-- The callback owns a record only while that exact object remains at the
-- queue head. Purges, age withdrawals, overflow and teardown invalidate it.
function Experiments:seal_application(experiment_key, record)
	local entry = record.entry
	local request = {
		app_key = self.config.app_id, environment_key = self.config.environment_id,
		experiment_key = experiment_key, variant_key = entry.variant_key,
		subject_key = entry.subject_key, served_kill_gate = entry.served_kill_gate,
		served_at = entry.served_at, applied_at = record.applied_at,
	}
	local raw_members = {
		experiment_version = entry.version_wire, served_revision = entry.served_revision_wire,
	}
	local attributes = {}
	for _, attribute in ipairs(entry.attributes or {}) do
		attributes[#attributes + 1] = json.encode(attribute.name) .. ":" .. json.encode(attribute.value)
	end
	raw_members.attributes = "{" .. table.concat(attributes, ",") .. "}"
	local event_name = "experiment_exposure"
	local route = "/api/cp/v1/runtime/experiments/exposures"
	if record.outcome_key then
		event_name = "experiment_outcome"
		route = "/api/cp/v1/runtime/experiments/outcomes"
		request.outcome_id = record.application_id
		request.occurred_at = record.event_ts
		request.outcome_key = record.outcome_key
		raw_members.outcome_value = record.outcome_value_wire
	else
		request.exposure_id = record.application_id
	end
	local members = {}
	for key, value in pairs(request) do members[#members + 1] = json.encode(key) .. ":" .. json.encode(value) end
	for key, value in pairs(raw_members) do members[#members + 1] = json.encode(key) .. ":" .. value end
	table.sort(members)
	local body = "{" .. table.concat(members, ",") .. "}"
	local flight = {}
	local epoch = self.consent_epoch
	local auth_epoch = self.auth_epoch
	local dispatched = clock.unix_ms()
	local scope = self:scope_for(entry.subject_key)
	local assignment_at_dispatch = self.entries[experiment_key]
	record.flight = flight
	record.deadline = dispatched + self.config.http_timeout_seconds * 1000
	local function complete(_, _, response)
		if record.flight ~= flight then return end
		record.flight = nil
		record.complete = nil
		local list = self.pending_exposure[experiment_key]
		if self.torn_down or not list or list[1] ~= record
			or epoch ~= self.consent_epoch or consent_refusal(self.deps.consent()) then return end
		response = type(response) == "table" and response or {}
		local status = tonumber(response.status) or 0
		local code, age_refusal = response_error(response)
		if status == 403 and code == "real_subjects_disabled" then
			self.blocked_error = "unauthorized"
			self.auth_blocked = true
			self.auth_epoch = self.auth_epoch + 1
			self:apply_sentinel_withdrawal(scope, clock.unix_ms(), dispatched)
			self:diagnose("fact_skipped", "real_subjects_disabled")
			return
		end
		if auth_epoch ~= self.auth_epoch then return end
		if status == 200 then
			local sealed, err = facts.decode(response.response, {
				workspace_key = self.config.workspace_id, app_key = self.config.app_id,
				environment_key = self.config.environment_id, event_name = event_name,
				experiment_key = experiment_key, version_wire = entry.version_wire,
				variant_key = entry.variant_key, outcome_key = record.outcome_key,
				outcome_value_wire = record.outcome_value_wire, subject_key = entry.subject_key,
			})
			if sealed then
				-- Retain both keys until the fact leaves every analytics store:
				-- an age refusal must find a key newly returned by apply too.
				record.sealed_fact = sealed
				record.entry = {
					subject_fact_key = sealed.props.assignment_key,
					assignment_unit = sealed.props.assignment_unit,
				}
				if sealed.props.assignment_key ~= entry.subject_fact_key
					and scope == self:scope_for(self:current_subject_id()) then
					self:retire_fact_key(scope, experiment_key, sealed.props.assignment_key)
					local durable = self:durable_record_for(scope)
					if not self:save_fact_key_history(durable) then
						-- Never publish a new attribution key that a later
						-- launch cannot withdraw. Retry the same occurrence.
						record.sealed_fact, record.entry = nil, entry
						self:diagnose("fact_deferred", "fact_key_unsaved")
						self:pace_apply(nil)
						return
					end
				end
				self.backoff_attempt = 0
				return
			end
			self:diagnose("fact_deferred", err)
		elseif status == 401 or status == 403 then
			local disabled = status == 403 and feature_disabled(code, true)
			self.blocked_error = disabled and "disabled" or "unauthorized"
			self.auth_blocked = true
			self.auth_epoch = self.auth_epoch + 1
			self.entries = {}
			for key, pending in pairs(self.durable_pending) do
				if not pending.drop then self.durable_pending[key] = nil end
			end
			self:diagnose(disabled and "disabled" or "fact_deferred", disabled and code or "apply_" .. tostring(status))
			return
		elseif status >= 400 and status < 500 and status ~= 408 and status ~= 429 then
			if status == 409 and code == "not_assigned" and age_refusal then
				self:apply_age_withdrawal(scope, experiment_key, clock.unix_ms(), entry.subject_fact_key)
			else
				table.remove(list, 1)
				if not list[1] then self.pending_exposure[experiment_key] = nil end
				if status == 409 and (code == "version_mismatch" or code == "variant_mismatch" or code == "unit_not_recordable")
					and scope == self:scope_for(self:current_subject_id())
					and self.entries[experiment_key] == assignment_at_dispatch then
					-- The refused occurrence's assignment is still the
					-- installed one: no newer assignment, host or cadence,
					-- has superseded it. A cadence attempt that failed or is
					-- still in flight supersedes nothing, so it never
					-- suppresses this refetch. Reuse current targeting.
					self:refetch_stale_assignment(scope, experiment_key, assignment_at_dispatch,
						(assignment_at_dispatch or entry).attributes)
				end
			end
			self:diagnose("fact_skipped", "apply_" .. tostring(status))
			return
		end
		self:pace_apply(retry_after_seconds(response))
	end
	record.complete = complete
	if not self.http_transport:available() then complete(nil, nil, { status = 0 }); return end
	local ok = pcall(self.http_transport.request, self.http_transport, trim_slash(self.config.app_url) .. route, "POST", complete,
		{ Authorization = "Bearer " .. self.config.publishable_key, ["Content-Type"] = "application/json",
			[sdk_header.NAME] = sdk_header.VALUE, },
		body, { timeout = self.config.http_timeout_seconds })
	if not ok then complete(nil, nil, { status = 0 }) end
end

-- An apply refused the occurrence's assignment as stale (version, variant or
-- unit mismatch): fetch it again with the targeting it was served under. A
-- host request still in flight for the experiment outranks this correction
-- (its answer may install the newer assignment, and this refetch would fence
-- it out), so the refetch is owed until that request ends instead.
function Experiments:refetch_stale_assignment(scope, experiment_key, applied, attributes)
	if self.host_fetch[experiment_key] then
		self.refetch_owed[experiment_key] = { scope = scope, applied = applied, attributes = attributes }
		return
	end
	self.refetch_owed[experiment_key] = nil
	self:fetch(experiment_key, nil, nil, true, attributes)
end

-- A host fetch for the experiment ended, whatever its outcome. The latest
-- one in flight releases the owed refetch, which is sent once — unless a
-- newer assignment installed meanwhile or the subject changed.
function Experiments:end_host_fetch(experiment_key, seq)
	if self.host_fetch[experiment_key] ~= seq then
		return
	end
	self.host_fetch[experiment_key] = nil
	local owed = self.refetch_owed[experiment_key]
	self.refetch_owed[experiment_key] = nil
	if owed and self.entries[experiment_key] == owed.applied
		and owed.scope == self:scope_for(self:current_subject_id()) then
		self:refetch_stale_assignment(owed.scope, experiment_key, owed.applied, owed.attributes)
	end
end

-- Drain in FIFO order. Sealing runs only from background/final sweeps, never
-- inside an application or outcome call. A full analytics queue keeps the
-- sealed record, without repeating the apply hop.
-- The same declaration controls retirement and intake loss accounting.
local terminal_emit_errors = { event_too_large = true }

function Experiments:sweep_pending(experiment_key, mode)
	local list = self.pending_exposure[experiment_key]
	if type(list) ~= "table" then return end
	while list[1] do
		local record = list[1]
		if self.declaring[experiment_key] or (self.auth_blocked and not record.sealed_fact) then return end
		if record.flight then
			if clock.unix_ms() < record.deadline then return end
			record.complete(nil, nil, { status = 0 })
		end
		if not record.sealed_fact then
			if mode ~= "background" and mode ~= "final" then return end
			if self.retry_after_ms and clock.unix_ms() < self.retry_after_ms then return end
			self:seal_application(experiment_key, record)
			if self.pending_exposure[experiment_key] ~= list then return end
			if list[1] == record and not record.sealed_fact then return end
		end
		if list[1] == record and record.sealed_fact then
			local sealed = record.sealed_fact
			local ok, err = self.deps.emit(sealed.event_name, sealed.props, sealed.event_id, {
				session_id = record.session_id, anonymous_id = record.anonymous_id,
				event_ts = sealed.event_ts, sealed_fact = sealed, retryable = true,
				terminal_errors = terminal_emit_errors,
			})
			if self.pending_exposure[experiment_key] ~= list then return end
			-- A complete event over the fixed cap cannot succeed on a later
			-- attempt. Retire that fact so it cannot block valid neighbours;
			-- capacity and unavailable encoding still keep their retry posture.
			if not ok and not terminal_emit_errors[err] then return end
			table.remove(list, 1)
		end
	end
	self.pending_exposure[experiment_key] = nil
end

-- Drain every experiment's owed exposures in per-experiment order,
-- granted-plane only: a non-granted state leaves everything armed. Driven
-- by the tick, and once more by the client's successful shutdown after the
-- final flush frees queue room — a treatment applied under a FULL queue
-- must not exit without its fact.
function Experiments:sweep_owed(network)
	if consent_refusal(self.deps.consent()) then
		return
	end
	if not next(self.pending_exposure) then
		return
	end
	local keys = {}
	for key in pairs(self.pending_exposure) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for i = 1, #keys do
		self:sweep_pending(keys[i], network and "background" or "local")
	end
end

-- True while any application's exposure fact is still owed (armed but not
-- yet enqueued). The client's shutdown loop and persist snapshot consult
-- this to decide whether the process may claim every fact is captured.
function Experiments:has_owed_exposures()
	return next(self.pending_exposure) ~= nil
end

-- True while a real-subjects condemnation is armed durably — an owed
-- whole-record clear, or its sidecar marker surviving a demotion — AND it
-- covers the CURRENT scope. The client's spool restore consults this at
-- load: spooled experiment facts carry withdrawn subject-fact keys under
-- an armed condemnation (a purge's failed spool rewrite followed by a
-- process death leaves them on disk), and re-sending them would defeat
-- the kill switch across the restart. Scope-gated like every other use of
-- the marker: a STALE marker from a retired environment/credential/
-- subject must not drop the current scope's valid facts at launch — it
-- settles through the normal retire path instead. A legacy marker without
-- a scope condemns conservatively (constructor parity). The old-scope
-- facts corner — envelopes carry no scope, so facts spooled under the
-- marker's own scope escape the load filter once the subject rotated —
-- narrows to sentinel + failed rewrite + death + rotation-before-relaunch
-- and stays in the documented storage-down-through-exit family.
function Experiments:condemnation_covers_current_scope()
	local armed = false
	local condemned_scope = nil
	if self.durable_clear_pending then
		armed = true
		condemned_scope = self.durable_clear_scope
	elseif self.clear_marker then
		armed = true
		condemned_scope = self.clear_marker.scope
	end
	if not armed then
		return false
	end
	if condemned_scope == nil then
		return true
	end
	local subject = self:current_subject_id()
	if not subject then
		-- NO provable current scope (the identity record lost its subject
		-- field, or none was ever minted): the SDK cannot demonstrate the
		-- marker stale, and envelopes carry no scope of their own — fail
		-- CLOSED and condemn conservatively, exactly like the legacy
		-- scope-less marker. After a sentinel + failed spool rewrite +
		-- identity loss, the withdrawn keys must not replay just because
		-- the comparator went blind; a later mint (a fresh subject = a
		-- fresh scope) settles the stale marker through the normal retire
		-- path. (The spool filter still stamp-partitions what it drops —
		-- post-sentinel facts survive even blind, the record partition's
		-- rule.)
		return true
	end
	return self:scope_for(subject) == condemned_scope
end

-- The armed condemnation's stamp, formatted for comparison against envelope
-- event_ts values (the clock's own second-granular ISO shape, so plain
-- string comparison is chronological). The spool filter partitions by it:
-- the sentinel's authority is bounded by its stamp, so a fact minted
-- strictly after it is post-sentinel state the condemnation never covered.
-- Nil while nothing is armed.
function Experiments:condemnation_stamp_iso()
	local stamp = nil
	if type(self.durable_clear_pending) == "number" then
		stamp = self.durable_clear_pending
	elseif self.clear_marker and type(self.clear_marker.stamp) == "number" then
		stamp = self.clear_marker.stamp
	end
	if not stamp then
		return nil
	end
	return clock.iso_utc(stamp)
end

-- True while any durable cache write, drop, or whole-record clear is still
-- owed: the disk does not yet reflect a decided state, so an app death now
-- would revive a revoked assignment (or lose a refresh) at the next launch.
function Experiments:has_owed_durable_sync()
	if self.durable_clear_pending or self.declaration_prune_owed or next(self.declaration_writes) ~= nil then
		return true
	end
	return next(self.durable_pending) ~= nil
end

-- The real-subjects sentinel's WITHDRAWAL half: wipe served and owed
-- state, purge pipeline-resident facts, and land (or durably mark) the
-- stamped whole-record clear. Factored out of the latch path so a
-- sentinel that arrives with its constructive half SUPPRESSED — stale by
-- auth epoch after a mid-batch latch, or answering a request whose
-- consent was revoked mid-flight — still applies the platform's
-- destructive directive: it never unlatches, never bumps the epoch, and
-- installs nothing (the latch path sets its own latch state before
-- calling in here).
function Experiments:apply_sentinel_withdrawal(scope, resolved_at_ms, dispatched_at_ms)
	local withdrawn_stamp_max = 0
	local sentinel_dispatch_bound = nil
	-- The clear's stamp must be decisively ABOVE the state it
	-- withdraws (the drop rule: the wall clock can move backward,
	-- and a rollback must not let withdrawn entries outrank their
	-- own clear). Capture the withdrawn stamps BEFORE memory is
	-- wiped. The DISK record is deliberately NOT folded in: an
	-- entry there stamped after the dispatch bound is a sibling's
	-- post-sentinel write the partition must see as a survivor,
	-- not withdrawn state (same-clock best-effort, like every
	-- write fence; a rollback-backdated withdrawn disk-only entry
	-- surviving until its own next probe is the accepted corner).
	-- The MEMORY scan honors the same dispatch bound: an entry
	-- fetched AFTER this sentinel's request was dispatched is
	-- post-sentinel authorized state, not withdrawn state — in a
	-- revalidation batch where a sibling key's fresh 200 lands
	-- before this sentinel's callback, folding that entry into the
	-- scan would raise the clear stamp above the survivor and the
	-- partition below would delete it as covered. Only entries
	-- at/before the dispatch bound may raise the stamp (an
	-- exactly-adjacent-millisecond tie stays the same-clock
	-- best-effort corner every fence accepts).
	sentinel_dispatch_bound = type(dispatched_at_ms) == "number"
		and dispatched_at_ms
		or (type(resolved_at_ms) == "number" and resolved_at_ms or 0)
	for _, held in pairs(self.entries) do
		if type(held) == "table"
			and type(held.fetched_at_ms) == "number"
			and held.fetched_at_ms <= sentinel_dispatch_bound
			and held.fetched_at_ms > withdrawn_stamp_max then
			withdrawn_stamp_max = held.fetched_at_ms
		end
	end
	-- Owed WRITE intents partition by the same dispatch bound as
	-- everything else. A POST-DISPATCH entry whose install save failed is
	-- a survivor whose ONLY copy lives in memory: wiping it below would
	-- leave the intent source-less and the durable-sync retry would decay
	-- it into a drop — silently losing the post-sentinel authorized state
	-- the partition exists to preserve. Snapshot the live entry INTO the
	-- intent (the retry lands the write from it). Pre-dispatch owed
	-- writes are withdrawn state and cancel, the ordinary latch's rule.
	for pending_composite, pending in pairs(self.durable_pending) do
		if not pending.drop then
			if pending.entry ~= nil then
				-- A snapshot preserved through an EARLIER sentinel's wipe
				-- partitions under THIS sentinel exactly like live state: a
				-- snapshot at/before this sentinel's dispatch bound is state
				-- the newer sentinel withdraws — leaving it owed would let
				-- retry_durable_sync() write it back AFTER this clear
				-- settles, resurrecting the assignment and its subject-fact
				-- key. Its write half cancels here (owed DROPS are untouched
				-- by this loop and still land, as always); a post-dispatch
				-- snapshot stays a preserved survivor, and another scope's
				-- snapshot is not this sentinel's to judge. A snapshot with
				-- no readable stamp cannot prove it postdates the dispatch
				-- and cancels conservatively.
				if pending.scope == scope
					and (type(pending.entry.fetched_at_ms) ~= "number"
						or pending.entry.fetched_at_ms
							<= sentinel_dispatch_bound) then
					self.durable_pending[pending_composite] = nil
				end
			else
				local live = self.entries[pending.key]
				if pending.scope == scope
					and live ~= nil and type(live.fetched_at_ms) == "number"
					and live.fetched_at_ms > sentinel_dispatch_bound then
					pending.entry = live
				else
					self.durable_pending[pending_composite] = nil
				end
			end
		end
	end
	self.entries = {}
	-- The sentinel withdraws both application stages, deduplication and
	-- last-applied state. A later explicit application gets a new occurrence.
	self.pending_exposure = {}
	self.exposed = {}
	self.applications = {}
	-- Queue-resident facts die with the snapshots: exposure and
	-- outcome facts ALREADY ACCEPTED into the analytics pipeline
	-- (queued below batch size, retained behind a publish retry
	-- backoff, or spooled durably) carry the withdrawn subject-fact
	-- keys verbatim, and shipping them on the next flush would keep
	-- egressing what the platform just killed. The client purges
	-- them from every pipeline surface — memory queue, retained
	-- batch, loaded spool chunks, durable spool record (that
	-- removal converging through the spool-rewrite machinery when
	-- the store is down). Only a batch actually ON THE WIRE at this
	-- instant is past recall — the same publish-in-flight carve-out
	-- the consent purge accepts — and if that publish fails and
	-- retains, the client filters the batch at settle time.
	if self.deps.purge_facts then
		self.deps.purge_facts()
	end
	-- The clear's authority is bounded by WHEN THIS FETCH ASKED:
	-- the flag state this answer reports is no newer than the
	-- request's dispatch, so an entry written while the sentinel
	-- was in flight (a sibling's fresh 200 — the flag flipped back
	-- on) postdates the directive and must survive. Stamp = the
	-- dispatch bound, raised above the withdrawn memory image.
	local stamp = sentinel_dispatch_bound
	if withdrawn_stamp_max >= stamp then
		stamp = withdrawn_stamp_max + 1
	end
	self.durable_clear_pending = stamp
	-- The clear condemns only THE SCOPE it was decided for: the
	-- record file is shared across assignment scopes, and another
	-- environment/credential's entries must never be pruned on
	-- this sentinel's stamp.
	self.durable_clear_scope = scope
	-- The SUCCESS path partitions exactly like the retry — a stale
	-- in-flight sentinel must not erase a sibling's newer
	-- post-sentinel write even when storage works — so the clear
	-- goes through the one stamped implementation immediately.
	self:retry_owed_clear()
	if self.durable_clear_pending then
		-- Still owed: the in-memory intent would die with the
		-- process and the next launch would serve the withdrawn
		-- record until its first probe. Make the condemnation
		-- DURABLE — the sidecar tombstone carries the clear's
		-- stamp AND scope, the constructor refuses what it covers
		-- and re-arms the clear. Best-effort in the double-failure
		-- corner (record AND sidecar stores down), diagnosed:
		-- that corner is the documented storage-down-through-exit
		-- residual.
		if storage.save_experiments_clear(self.config, stamp, scope) then
			self.clear_marker = { stamp = stamp, scope = scope }
		else
			self:diagnose("persist_failed", "cache_clear_tombstone")
		end
		self:diagnose("persist_failed", "cache_clear")
	elseif not self.clear_marker
		and self.deps.spool_condemned_pending
		and self.deps.spool_condemned_pending() then
		-- The cache side SETTLED, but condemned facts remain on
		-- the durable spool (the purge's removal write could not
		-- land): that debt is memory-only, and an exit before the
		-- rewrite retries would leave the next launch with no
		-- durable condemnation over the stale file — the
		-- withdrawn facts would simply resend. Persist the marker
		-- for the SPOOL's sake: the retire rule (record clean AND
		-- spool clean) governs its lifetime, and the stamp
		-- partition keeps it harmless to post-sentinel facts
		-- meanwhile. Best-effort like the tombstone above —
		-- both-stores-down stays the documented residual.
		if storage.save_experiments_clear(self.config, stamp, scope) then
			self.clear_marker = { stamp = stamp, scope = scope }
		else
			self:diagnose("persist_failed", "cache_clear_tombstone")
		end
	end
end

-- An authoritative per-key drop's WITHDRAWAL half (kill switch, 404, a
-- permanent bad-request, an authoritative not-assigned): remove the
-- served entry, durably capture the owed exposure snapshots the delete
-- would orphan, and converge the durable record with the decision-time
-- stamp raise. Shared by the normal install flow and the destructive
-- partitions (stale-epoch / revoked-consent), which apply the server's
-- withdrawal while suppressing every constructive effect.
function Experiments:apply_entry_drop(scope, experiment_key, resolved_at_ms)
	local dropped = self.entries[experiment_key]
	self.entries[experiment_key] = nil
	-- A treatment already applied remains owed after an ordinary kill.
	-- Sealed facts can be captured through the existing spool; unsealed
	-- applications remain memory-only until their apply hop completes.
	local owed = self.pending_exposure[experiment_key]
	if owed and self.deps.capture_fact then
		for _, record in ipairs(owed) do
			local sealed = record.sealed_fact
			if sealed then
				self.deps.capture_fact(sealed.event_name, sealed.props, sealed.event_id, {
					session_id = record.session_id, anonymous_id = record.anonymous_id,
					event_ts = sealed.event_ts, sealed_fact = sealed,
				})
			end
		end
	end
	-- The drop's effective stamp is raised above the entry it
	-- resolves: the wall clock can move backward, and a drop for X
	-- must always outrank X's own stamp.
	local as_of = type(resolved_at_ms) == "number" and resolved_at_ms or 0
	if dropped and type(dropped.fetched_at_ms) == "number"
		and dropped.fetched_at_ms >= as_of then
		as_of = dropped.fetched_at_ms + 1
	end
	self:sync_durable_entry(scope, experiment_key, as_of)
end

-- An authoritative `age_ineligible` refusal's WITHDRAWAL: the per-key drop
-- PLUS the withdrawal of every application the refused subject still owes
-- for this experiment. The server just said this subject may not take part
-- (no eligible adult declaration), so what the subject still owes is not a
-- fact to preserve: it is the data the platform refused. Selected by the
-- parser's `withdraw_owed` flag; every other not-assigned reason keeps
-- apply_entry_drop, whose owed exposures survive the drop and are captured
-- durably. The steps:
--   * the served entry leaves memory, so serving stops and a new
--     track_outcome for the key is refused locally (no_assignment);
--   * the subject's owed records and last-applied state are discarded;
--   * deduplication resets, so readmission can record a fresh random occurrence;
--   * the client withdraws the key's facts already accepted into the
--     analytics pipeline — memory queue, retained batch, loaded spool
--     chunks, durable spool record (Client:withdraw_experiment_facts);
--   * the durable entry drop converges exactly as apply_entry_drop's does.
-- SCOPE: this experiment key and this subject, never plane-wide — other
-- experiments' owed facts are legitimate and untouched. The subject's facts
-- are named by its server-minted fact keys: the dropped entry's, the refusal
-- body's (`refused_fact_key`, one key or a list: an unconfirmed
-- declaration's end may name two), that of any owed snapshot of this same
-- subject, and the ones the
-- fact-key history retired for this experiment (an earlier version's, or an
-- entry a kill switch deleted). When none is
-- known, no accepted fact is withdrawn: the experiment key alone would take
-- another subject's legitimate facts with it. Owed snapshots are told apart
-- by their own subject and need no fact key (one restored without a subject
-- key, by being the dropped entry or carrying a refused fact key). A batch
-- already ON THE WIRE is past recall (the consent purge's carve-out): it is
-- neither re-sent nor counted as withdrawn.
-- `keep_assignment` (an unanswered non-adult declaration keeping a
-- synthetic-subject assignment): the entry and its durable copy stay,
-- and only the subject's owed
-- CLIENT-ID applications of the experiment are withdrawn with their facts.
function Experiments:apply_age_withdrawal(scope, experiment_key, resolved_at_ms, refused_fact_key, keep_assignment)
	local dropped = nil
	if not keep_assignment then
		dropped = self.entries[experiment_key]
		self.entries[experiment_key] = nil
	end
	-- A kept synthetic assignment's own explicit
	-- application is not among the withdrawn: only age-gated ones are.
	local function withdrawable(held)
		return not (keep_assignment and age_exempt(held))
	end
	local subject = self:current_subject_id()
	local fact_keys = nil
	local function refuse_fact_key(value)
		if type(value) == "string" and value ~= "" then
			fact_keys = fact_keys or {}
			fact_keys[value] = true
		end
	end
	refuse_fact_key(dropped and dropped.subject_fact_key)
	if type(refused_fact_key) == "table" then
		for i = 1, #refused_fact_key do
			refuse_fact_key(refused_fact_key[i])
		end
	else
		refuse_fact_key(refused_fact_key)
	end
	-- The fact-key history: this subject's keys of the experiment that no
	-- entry carries any more — a republish rotated the key, or a drop (a
	-- kill switch's included) deleted the entry — while facts under them are
	-- still queued, spooled or captured.
	for fact_key in pairs(self:history_of(scope)[experiment_key] or {}) do
		refuse_fact_key(fact_key)
	end
	local owed = self.pending_exposure[experiment_key]
	if type(owed) == "table" then
		for i = 1, #owed do
			local held = owed[i].entry
			if held and subject and held.subject_key == subject and withdrawable(held) then
				refuse_fact_key(held.subject_fact_key)
			end
		end
		-- Only the refused subject's snapshots are withdrawn, told apart by
		-- the snapshot's OWN subject: another subject's (a re-minted
		-- predecessor's) stay owed whether or not any fact key is known. An
		-- entry cached without a subject key (an older record) was restored
		-- under the record's scoped subject: its snapshot is the refused
		-- subject's when its entry IS the dropped one, or when it carries
		-- one of the refused subject's server-minted fact keys.
		local function refused(held)
			if held == nil or not withdrawable(held) then
				return false
			end
			if subject and held.subject_key == subject then
				return true
			end
			return held.subject_key == nil and (held == dropped
				or (fact_keys ~= nil and fact_keys[held.subject_fact_key] == true))
		end
		local kept = {}
		for i = 1, #owed do
			if not refused(owed[i].entry) then
				kept[#kept + 1] = owed[i]
			end
		end
		self.pending_exposure[experiment_key] = kept[1] and kept or nil
	end
	local application = self.applications[experiment_key]
	if application and withdrawable(application.entry) then self.applications[experiment_key] = nil end
	if subject then
		local prefix = experiment_key .. "\31"
		local suffix = "\31" .. subject
		for tuple in pairs(self.exposed) do
			if tuple:sub(1, #prefix) == prefix and tuple:sub(-#suffix) == suffix then self.exposed[tuple] = nil end
		end
	end
	if self.deps.withdraw_facts then
		self.deps.withdraw_facts(experiment_key, fact_keys)
	end
	if not keep_assignment then
		local as_of = type(resolved_at_ms) == "number" and resolved_at_ms or 0
		if dropped and type(dropped.fetched_at_ms) == "number"
			and dropped.fetched_at_ms >= as_of then
			as_of = dropped.fetched_at_ms + 1
		end
		self:sync_durable_entry(scope, experiment_key, as_of)
	end
	-- The withdrawn facts are gone: their keys leave the history, durably,
	-- even when the sync above found nothing stored to write (a kill switch
	-- already dropped the entry). A fact the withdrawal could not recall (a
	-- batch on the wire) keeps its key until that batch settles.
	self:prune_fact_key_history()
end

-- Apply ONLY the destructive half of an authoritative server outcome —
-- the durable withdrawal — for a response whose CONSTRUCTIVE half a gate
-- suppressed: a stale auth epoch (a fail-closed latch raced the batch)
-- or a mid-flight consent revocation. The request was dispatched under
-- grant and the server withdrew the assignment; discarding the directive
-- with the rest of the response would RETAIN the condemned durable cache
-- (the ordinary latch keeps the record by design, and denial retains the
-- cache for re-grant), so the next init or re-grant would restore and
-- serve what the platform already killed. Nothing here unlatches,
-- installs, arms exposures, paces, or reaches the public callback — the
-- constructive fences are untouched. Scope still fences every directive;
-- key order fences per-key drops, while plane-wide withdrawal remains effective.
function Experiments:apply_destructive_outcome(seq, scope, experiment_key, outcome, resolved_at_ms, dispatched_at_ms)
	if not (outcome.drop_all
		or (outcome.authoritative and outcome.drop_entry)) then
		return
	end
	local subject = self:current_subject_id()
	if not subject or self:scope_for(subject) ~= scope then
		return
	end
	local fence_key = scope .. scope_separator .. experiment_key
	local settled = self.settled[fence_key] or 0
	if seq <= settled and not outcome.drop_all then
		return
	end
	local declaration = self.declaring[experiment_key]
	if not outcome.drop_all and declaration and seq <= declaration.fence_seq then return end
	self.settled[fence_key] = math.max(settled, seq)
	if outcome.drop_all then
		self:apply_sentinel_withdrawal(scope, resolved_at_ms, dispatched_at_ms)
		return
	end
	if outcome.withdraw_owed then
		-- An age refusal withdraws the subject's owed applications on these
		-- partitions too (a later explicit application may be owed).
		self:apply_age_withdrawal(scope, experiment_key, resolved_at_ms,
			outcome.refused_fact_key)
		return
	end
	self:apply_entry_drop(scope, experiment_key, resolved_at_ms)
end

function Experiments:write_declaration_marker(scope, experiment_key, marker, keep_assignment)
	self.declaration_prune_pending = true
	local composite = scope .. scope_separator .. experiment_key
	local records, miss = storage.load_experiment_declarations(self.config)
	if not miss then
		local pending = records[scope] or {}
		if marker == nil and not pending[experiment_key] then
			self.declaration_writes[composite] = nil
			return true
		end
		local blocked = marker == nil and (self.durable_pending[composite] ~= nil
			or (self.deps.withdrawal_persist_pending and self.deps.withdrawal_persist_pending()))
		if marker == nil and not keep_assignment then
			local record, record_miss = storage.load_experiments(self.config)
			local stored = record and record.scope == scope and record.entries[experiment_key]
			blocked = blocked or record_miss == "unreadable" or (stored and not age_exempt(stored))
		end
		if not blocked then
			pending[experiment_key] = marker
			records[scope] = next(pending) ~= nil and pending or nil
			if storage.save_experiment_declarations(self.config, records) then
				self.declaration_writes[composite] = nil
				return true
			end
		end
	end
	self.declaration_writes[composite] = { scope = scope, key = experiment_key, marker = marker, keep_assignment = keep_assignment }
	self:diagnose("persist_failed", "pending_declaration")
	return false
end

-- Record a HOST fetch's age declaration for one experiment, before any
-- consent gate. A non-adult declaration stops the experiment serving at
-- once (served_entry) and keeps the revalidation cadence from re-sending the
-- entry's remembered adult declaration while its fetch is in flight; owed
-- applications are left for the server's answer. `fence_seq` is the last
-- fetch dispatched before the declaration: every fetch at or below it left
-- with an earlier one. `seq` is the declaring fetch's own, once dispatched,
-- and `decided` is set when the server's answer to it was applied. An adult
-- declaration replaces a pending non-adult one (the later declaration
-- decides afresh); a fetch that declares no age changes nothing. Returns the
-- non-adult declaration, or nil.
function Experiments:begin_host_declaration(experiment_key, attributes)
	if declares_non_adult_age(attributes) then
		local declaration = { fence_seq = self.fetch_seq, seq = nil, decided = false }
		-- Only an age-gated entry's key can name facts to withdraw. The end
		-- may find neither the entry (an auth latch clears it) nor the key
		-- in the durable record (the entry's own write failed, or an older
		-- entry is stored), while facts under it are still queued.
		local live = self.entries[experiment_key]
		if live and not age_exempt(live) and type(live.subject_fact_key) == "string" then
			declaration.fact_key = live.subject_fact_key
			declaration.subject = self:current_subject_id()
		end
		self.declaring[experiment_key] = declaration
		local subject = self:current_subject_id()
		if subject then
			declaration.scope = self:scope_for(subject)
			local keys, seen = {}, {}
			local function note(value)
				if type(value) == "string" and not seen[value] then
					seen[value] = true
					keys[#keys + 1] = value
				end
			end
			if live and not age_exempt(live) then note(live.subject_fact_key) end
			for key in pairs(self:history_of(declaration.scope)[experiment_key] or {}) do note(key) end
			for _, owed in ipairs(self.pending_exposure[experiment_key] or {}) do
				local entry = owed.entry
				if entry and entry.subject_key == subject and not age_exempt(entry) then note(entry.subject_fact_key) end
			end
			local record = storage.load_experiments(self.config)
			local stored = record and record.scope == declaration.scope and record.entries[experiment_key]
			if stored and not age_exempt(stored) then note(stored.subject_fact_key) end
			table.sort(keys)
			self:write_declaration_marker(declaration.scope, experiment_key, { fact_keys = keys })
		end
		return declaration
	end
	if declares_adult_age(attributes) then
		self.declaring[experiment_key] = nil
		local subject = self:current_subject_id()
		if subject then self:write_declaration_marker(self:scope_for(subject), experiment_key, nil, true) end
	end
	return nil
end

-- End a non-adult declaration when its fetch ends, on every path. When the
-- server's answer was applied (`decided`) that answer governs, as it always
-- has: an age_ineligible refusal withdraws, a kill switch keeps what is owed,
-- an assignment installs. Otherwise the server has not confirmed the
-- declaration (a transient failure, an auth latch, which retains the durable
-- record for a later init, a consent refusal, a fenced-out or stale-scope
-- answer), and the declaration alone makes the subject ineligible for a
-- client-id assignment, so it is not held for a later answer. It is the
-- age_ineligible refusal's package, as if the server had refused with no
-- fact key of its own (apply_age_withdrawal): the entry stops serving and its
-- durable drop converges, and every application the subject owes for the
-- experiment is withdrawn with its accepted facts. The key's sequence fence
-- is raised past every fetch dispatched before the declaration, the way a
-- newer settled answer raises it, so an adult answer or revalidation that
-- left earlier installs nothing when it lands. A later host declaration
-- replaced this one: nothing happens here. A synthetic-subject assignment
-- has no age gate and is kept; only what the subject owes for the
-- experiment is withdrawn. Nothing is minted: with no subject there is
-- nothing cached or owed. Returns true when it withdrew the entry.
function Experiments:end_non_adult_declaration(experiment_key, declaration)
	if self.declaring[experiment_key] ~= declaration then
		return false
	end
	self.declaring[experiment_key] = nil
	if declaration.decided or self.torn_down then
		if declaration.decided and declaration.scope then
			self:write_declaration_marker(declaration.scope, experiment_key, nil, true)
		end
		return false
	end
	local subject = self:current_subject_id()
	if not subject then
		return false
	end
	local scope = self:scope_for(subject)
	local fence_key = scope .. scope_separator .. experiment_key
	if (self.settled[fence_key] or 0) < declaration.fence_seq then
		self.settled[fence_key] = declaration.fence_seq
	end
	-- No echo from the server names the subject's facts. The served entry
	-- does; an auth latch clears it from memory while retaining the durable
	-- record, which then does.
	local entry = self.entries[experiment_key]
	local fact_key = nil
	if not entry then
		local stored = self:durable_record_for(scope).entries[experiment_key]
		if type(stored) == "table" then
			entry = stored
			if not age_exempt(stored) and type(stored.subject_fact_key) == "string" then
				fact_key = stored.subject_fact_key
			end
		end
	end
	-- The key the live entry carried when the declaration was made, for the
	-- same subject: the entry is gone, and the record names no key or an
	-- older one.
	if not self.entries[experiment_key] and declaration.fact_key
		and declaration.subject == subject and declaration.fact_key ~= fact_key then
		fact_key = fact_key and { fact_key, declaration.fact_key } or declaration.fact_key
	end
	self:diagnose("withdrawn", "age_declaration_unconfirmed")
	if age_exempt(entry) then
		-- A synthetic-subject assignment has no age gate: it keeps serving.
		-- The client-id applications the subject still owes for the
		-- experiment from before it are withdrawn all the same.
		self:apply_age_withdrawal(scope, experiment_key, clock.unix_ms(), fact_key, true)
		if declaration.scope then self:write_declaration_marker(declaration.scope, experiment_key, nil, true) end
		return false
	end
	self:apply_age_withdrawal(scope, experiment_key, clock.unix_ms(), fact_key)
	if declaration.scope then self:write_declaration_marker(declaration.scope, experiment_key, nil) end
	return true
end

-- Whether `outcome`, landing now for fetch `seq`, is the server's answer to
-- the pending non-adult `declaration` and is about to be applied to the
-- assignment state: a not-assigned verdict of any reason, a permanent drop,
-- the real-subjects sentinel, or an install (`installs` false when the auth
-- epoch or a consent refusal strips the constructive half). It must be the
-- declaring fetch's own answer, for the current scope, and not fenced out. A
-- transient, an auth latch and an unproven status are not answers: they
-- leave the declaration unconfirmed. Evaluated before the outcome applies.
function Experiments:answers_declaration(declaration, seq, scope, experiment_key, outcome, installs)
	if not declaration or declaration.seq ~= seq
		or self.declaring[experiment_key] ~= declaration then
		return false
	end
	local subject = self:current_subject_id()
	if not subject or self:scope_for(subject) ~= scope
		or seq <= (self.settled[scope .. scope_separator .. experiment_key] or 0) then
		return false
	end
	if outcome.drop_all then
		return true
	end
	if outcome.transient or outcome.auth_blocked then
		return false
	end
	if outcome.authoritative and outcome.drop_entry then
		return true
	end
	return installs and outcome.new_entry ~= nil
end

-- End every pending non-adult declaration as unconfirmed. The client's
-- shutdown abandons the fetches still in flight (a torn-down consumer
-- discards their answers), so each is aborted, not answered, and ends now,
-- before the final flush and sweep, as a fetch that ends unanswered does.
function Experiments:abort_declarations()
	local keys = {}
	for key in pairs(self.declaring) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for i = 1, #keys do
		self:end_non_adult_declaration(keys[i], self.declaring[keys[i]])
	end
end

-- The entry the getters serve and record against: none while a terminal
-- answer has closed the experiment, nor while a non-adult declaration of it
-- is pending, unless it is age-exempt.
function Experiments:served_entry(experiment_key)
	if self.closed_keys[experiment_key] then
		return nil
	end
	local entry = self.entries[experiment_key]
	if entry and self.declaring[experiment_key] and not age_exempt(entry) then
		return nil
	end
	return entry
end

-- Settle an authoritative fetch outcome and, when it may, install it. Gates,
-- in remote-config order: the auth epoch must still be current (an outcome
-- whose fetch was already in flight when a fail-closed latch landed is
-- discarded outright — it must neither unlatch nor reinstall revoked
-- assignments), the scope must still be current (a subject re-minted while
-- the response was in flight makes it another subject's assignment), then
-- key order fences local results; authorization still governs the whole plane.
function Experiments:install(seq, scope, experiment_key, outcome, auth_epoch, resolved_at_ms, dispatched_at_ms)
	if auth_epoch ~= self.auth_epoch then
		-- A stale-epoch response is discarded from CONSTRUCTIVE state — no
		-- install, no unlatch (only a post-latch fetch may unlatch) — but a
		-- destructive directive it carries still lands its withdrawal: the
		-- latch retained the durable record, so dropping a kill/404/
		-- sentinel answered to a sibling key of the same batch would
		-- restore the withdrawn assignment at the next init.
		self:apply_destructive_outcome(seq, scope, experiment_key, outcome,
			resolved_at_ms, dispatched_at_ms)
		return
	end
	local subject = self:current_subject_id()
	if not subject or self:scope_for(subject) ~= scope then
		return
	end
	local fence_key = scope .. scope_separator .. experiment_key
	local settled = self.settled[fence_key] or 0
	-- Authorization governs the plane even when this key has a newer answer.
	if seq <= settled and not outcome.auth_blocked then
		return
	end
	if outcome.authoritative and seq > settled then
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
		self.blocked_error = outcome.disabled_code and "disabled" or "unauthorized"
		if outcome.disabled_code then self:diagnose("disabled", outcome.disabled_code) end
		if outcome.drop_all then
			self:apply_sentinel_withdrawal(scope, resolved_at_ms,
				dispatched_at_ms)
		else
			self.entries = {}
			-- An ORDINARY 401/403 retains the durable record — and the
			-- owed EXPOSURE snapshots: a treatment that already ran is a
			-- fact about the past, and the latch stops future serving, not
			-- the reporting of what happened (the tick sweep keeps
			-- draining them while consent is granted). An owed cache WRITE
			-- whose entry this latch just cleared from memory must not
			-- decay into a delete at the next retry — absence in memory
			-- here is fail-closed serving, not a drop decision — so owed
			-- writes are cancelled (their source data is gone; the disk
			-- keeps its last-known record). Owed DROPS were authoritative
			-- server decisions and still land.
			for key, pending in pairs(self.durable_pending) do
				if not pending.drop then
					self.durable_pending[key] = nil
				end
			end
		end
		return
	end
	if outcome.authoritative and not outcome.unproven then
		-- An authoritative, authorized outcome of a post-latch fetch (the
		-- epoch gate above guarantees that) proves the credential works
		-- again: unlatch and let revalidation resume. An UNPROVEN
		-- authoritative outcome — the unexpected-status fallthrough — is
		-- excluded: a captive-portal 302 or a gateway 409 answering a
		-- post-latch fetch carries no authorization proof, and unlatching
		-- on it would resume serving a fail-closed plane on noise. It still
		-- settles its fence above (the newest server word stands for
		-- ordering) — only the latch is untouched.
		self.auth_blocked = false
	end
	if outcome.transient then
		return
	end
	local declaration = self.declaring[experiment_key]
	if declaration and seq <= declaration.fence_seq and not age_exempt(outcome.new_entry) then
		-- Older per-key answers cannot replace, drop or close exempt serving state.
		return
	end
	-- A settled authoritative answer resets the consecutive-failure counter.
	-- A server-set Retry-After deadline is deliberately NOT cleared here:
	-- the pacing is shared by every cached entry, and one admitted request
	-- for an unrelated entry does not rescind the server's wait for the
	-- plane — the deadline simply expires on its own (clamped to a day; the
	-- deferral setter already keeps only the LATEST deadline).
	self.backoff_attempt = 0
	if outcome.close_entry then
		self.closed_keys[experiment_key] = true
		return
	end
	if outcome.withdraw_owed or outcome.drop_entry or outcome.new_entry then
		-- The server answered for this experiment: a closed one reopens.
		self.closed_keys[experiment_key] = nil
	end
	if outcome.withdraw_owed then
		self:apply_age_withdrawal(scope, experiment_key, resolved_at_ms,
			outcome.refused_fact_key)
		return
	end
	if outcome.drop_entry then
		self:apply_entry_drop(scope, experiment_key, resolved_at_ms)
		return
	end
	if outcome.new_entry then
		local entry = outcome.new_entry
		entry.subject_key = subject
		entry.attributes = outcome.attributes
		-- A pending whole-record clear (or its durable sidecar marker) may
		-- still carry a stamp at/above this fresh entry's — the wall clock
		-- moved backward across the sentinel, or the fetch stamp only
		-- reached the old stored bound. The demotion below protects the
		-- entry in MEMORY, but the constructor's partition refuses any
		-- restored entry stamped at/below the marker, so without a raise
		-- the fresh authorized assignment would be refused and cleared on
		-- the NEXT launch. Decisive-raise rule, applied against the pending
		-- clear exactly as installs already apply it against stored
		-- records: this authorized install postdates the sentinel by
		-- causality (it answered a post-sentinel fetch), so its stamp must
		-- outrank the clear's. Scope-gated like the clear itself — another
		-- scope's marker never inflates this scope's stamps.
		local clear_floor = nil
		if type(self.durable_clear_pending) == "number"
			and (self.durable_clear_scope == nil
				or self.durable_clear_scope == scope) then
			clear_floor = self.durable_clear_pending
		end
		if self.clear_marker
			and type(self.clear_marker.stamp) == "number"
			and (self.clear_marker.scope == nil
				or self.clear_marker.scope == scope)
			and (clear_floor == nil or self.clear_marker.stamp > clear_floor) then
			clear_floor = self.clear_marker.stamp
		end
		if clear_floor and type(entry.fetched_at_ms) == "number"
			and entry.fetched_at_ms <= clear_floor then
			entry.fetched_at_ms = clear_floor + 1
		end
		self.entries[experiment_key] = entry
		-- A fresh authorized assignment supersedes any owed whole-record
		-- clear RIGHT NOW, not at the next tick: waiting would leave the
		-- stale clear armed across an ordinary auth latch (which empties
		-- memory while retaining the durable record), and the retention
		-- canon must never let that clear delete state written after it.
		self:demote_owed_clear()
		self:sync_durable_entry(scope, experiment_key, entry.fetched_at_ms)
		-- The combined save above may have just landed the demoted drops:
		-- retire a demotion-outlived condemnation marker as soon as its
		-- covered state is durably gone (no-op unless a marker is owed).
		self:retire_clear_marker_if_settled()
		self:arm_revalidation(clock.unix_ms())
		-- Fetch installs serving state only. The host records an application.

	end
end

function Experiments:arm_revalidation(now_ms)
	local jitter = 1 + (random.unit() * 2 - 1) * revalidate_jitter
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
	-- Pacing may SHORTEN the next attempt, never merely lengthen it: the
	-- cadence deadline was already re-armed a full interval out when the
	-- failing batch DISPATCHED, so without this pull-down a short
	-- Retry-After or backoff window would be dead code — the `now <
	-- revalidate_at_ms` gate would suppress the retry until the full
	-- cadence anyway. The effective next attempt becomes min(cadence,
	-- pacing window); retry_after_ms above still lower-bounds it, so a
	-- server wait LONGER than the cadence holds exactly as before. The
	-- min rule applies FROM BIRTH: with no cadence armed yet (a restored
	-- assignment before its first tick), the pacing deadline becomes the
	-- cadence — otherwise the first tick after the window would arm a
	-- fresh full interval and delay the probe by the whole cadence.
	if not self.revalidate_at_ms or deadline < self.revalidate_at_ms then
		self.revalidate_at_ms = deadline
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
		backoff_base_seconds + random.unit() * (ceiling - backoff_base_seconds))
end

-- One assignment fetch. `attributes` is optional; `callback(result)` receives
-- { ok, assigned, variant_key?, variant_payload?, version?, reason?,
--   boundary?, from_cache, error? } and — like every request callback — fires
-- exactly once, pcall-guarded. Returns true when a request was dispatched, or
-- (false, error_code) with the callback already invoked when it could not be.
-- `carried_declaration` is internal: the grammar re-mint retry carries the
-- rejected request's pending non-adult declaration, so it ends with the retry.
function Experiments:fetch(experiment_key, attributes, callback, is_revalidation, preset_attributes, carried_declaration, original_seq)
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
	-- A HOST fetch's age declaration is recorded before any consent gate: a
	-- non-adult declaration made while the plane refuses still withdraws when
	-- its fetch ends, or a re-grant would serve the assignment the host has
	-- declared the subject ineligible for. The cadence and the re-mint retry
	-- re-send an earlier declaration and are not new ones.
	local declaration = carried_declaration
	local own_declaration = false
	if not is_revalidation and preset_attributes == nil then
		declaration = self:begin_host_declaration(experiment_key, attributes)
		own_declaration = declaration ~= nil
	end
	-- Every path that ends this fetch ends its declaration first, so the
	-- caller sees the state the declaration left. A cache serve the
	-- unconfirmed declaration just withdrew is not handed back. A host
	-- fetch then releases any apply-mismatch refetch that waited for it.
	local host_seq
	local function conclude(result)
		if declaration and self:end_non_adult_declaration(experiment_key, declaration)
			and result.from_cache then
			result = { ok = false, from_cache = false, error = result.error }
		end
		local concluded = finish(result)
		if host_seq then
			self:end_host_fetch(experiment_key, host_seq)
		end
		return concluded
	end
	if is_revalidation and self.declaring[experiment_key] then
		-- A revalidation re-sends an earlier declaration — the cadence's
		-- remembered attributes, or a grammar re-mint retry's preset set —
		-- and must not leave while the host's non-adult declaration of the
		-- experiment is pending: its answer would outrank the declaration's
		-- fence. Only a host fetch's own retry, carrying its declaration,
		-- proceeds.
		finish({ ok = false, from_cache = false, error = "declaration_pending" })
		return false, "declaration_pending"
	end
	-- GRANTED-ONLY plane (see the module header): while consent is unknown or
	-- denied — the forced-minor state included — no request leaves the
	-- device, nothing is minted, nothing is served.
	local refusal = consent_refusal(self.deps.consent())
	if refusal then
		conclude({ ok = false, from_cache = false, error = refusal })
		return false, refusal
	end
	if not json or type(json.decode) ~= "function" then
		-- Without a decoder neither a fresh body nor a cached entry could be
		-- interpreted when it was stored; nothing can be served.
		conclude({ ok = false, from_cache = false, error = "json_unavailable" })
		return false, "json_unavailable"
	end

	local subject = self:ensure_subject_id()
	self.fetch_seq = self.fetch_seq + 1
	-- A retry is still its original call, behind any later host declaration.
	local seq = original_seq or self.fetch_seq
	self.fetch_started[experiment_key] = math.max(self.fetch_started[experiment_key] or 0, seq)
	if not is_revalidation then
		host_seq = seq
		self.host_fetch[experiment_key] = math.max(self.host_fetch[experiment_key] or 0, seq)
	end
	if own_declaration and self.declaring[experiment_key] == declaration then
		declaration.seq = seq
	elseif preset_attributes ~= nil and not is_revalidation
		and declares_non_adult_age(attributes) then
		-- A declaring host fetch's grammar re-mint retry: its answer is the
		-- answer to the pending declaration.
		local pending = self.declaring[experiment_key]
		if pending then
			pending.seq = seq
		end
	end

	-- Capture the scope and the auth epoch ONCE per fetch: the URL, the
	-- served cache, and the installed entry all describe the same subject
	-- even if the id re-mints while the request is in flight, and an
	-- outcome that raced a fail-closed latch is discarded by the epoch gate
	-- at install time.
	local scope = self:scope_for(subject)
	local auth_epoch = self.auth_epoch
	local consent_epoch = self.consent_epoch
	local entry = self.entries[experiment_key]

	local normalized_attributes, dropped
	if preset_attributes ~= nil then
		-- Internal grammar-remint retry only: the EXACT normalized set of
		-- the rejected request rides the retry verbatim — the subject
		-- rotation cleared the cached entry the cadence would have re-read
		-- them from, and a targeted assignment must be retried with the
		-- same input set, not un-targeted.
		normalized_attributes = preset_attributes
	elseif attributes ~= nil then
		normalized_attributes, dropped = M.normalize_assignment_attributes(attributes)
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

	if not self.http_transport:available() then
		local result = serve_entry_or_fail(
			not self.closed_keys[experiment_key] and entry or nil,
			"http_unavailable", normalized_attributes)
		conclude(result)
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
	local url = M.build_url(self.config.app_url, query)
	local headers = {
		["Authorization"] = "Bearer " .. self.config.publishable_key,
		[sdk_header.NAME] = sdk_header.VALUE,
	}
	local options = {
		timeout = self.config.http_timeout_seconds,
	}

	-- The dispatch bound: the server truth any answer to THIS request can
	-- carry is no newer than the moment it was asked. The real-subjects
	-- sentinel's whole-record clear stamps its authority by it (see the
	-- drop_all install), so state written while the sentinel was in flight
	-- — a sibling's fresh 200, meaning the flag flipped back on — postdates
	-- the directive and survives its partition.
	local dispatched_at_ms = clock.unix_ms()
	self.http_transport:request(url, "GET", function(_, _, response)
		-- A torn-down consumer discards in-flight responses outright:
		-- nothing installs, persists, or paces, and game code is not
		-- called back after shutdown (the documented teardown contract).
		if self.torn_down then
			if declaration then
				self:end_non_adult_declaration(experiment_key, declaration)
			end
			return
		end
		-- The consent re-check comes next: a revocation while the request
		-- was in flight closes the plane. Nothing installs, nothing paces,
		-- nothing re-mints, and the caller receives the refusal — never a
		-- healthy assignment fetched under a consent that no longer holds.
		local refusal_now = consent_refusal(self.deps.consent())
		if refusal_now == nil and consent_epoch ~= self.consent_epoch then
			-- The plane LOOKS open, but the consent epoch moved while this
			-- request was in flight: a deny→re-grant raced the response,
			-- and the current-state check alone would install (serve,
			-- expose, persist) an assignment fetched under a consent that
			-- was since revoked. Same partition as the refusal below —
			-- constructive suppressed, destructive still lands.
			refusal_now = "consent_changed"
		end
		if refusal_now then
			-- The plane is closed, but the request was DISPATCHED under
			-- grant: a destructive directive in this answer (kill switch,
			-- 404, authoritative not-assigned, the real-subjects sentinel)
			-- still applies its local withdrawal — the cache is retained
			-- across denial by design, so discarding the directive would
			-- let a later re-grant re-serve the assignment (with explicit
			-- facts for a subject-fact key) the server already withdrew.
			-- Constructive results stay suppressed, no subject id is ever
			-- minted here (the grammar re-mint is NOT destructive and is
			-- discarded), the owed-exposure capture inside the drop no-ops
			-- (the denial purge already discarded the snapshots), and the
			-- caller still receives the refusal.
			local revoked_resolved_at_ms = clock.unix_ms()
			local _, closed_outcome = M.apply(nil, response,
				revoked_resolved_at_ms, experiment_key, self.config.app_id,
				self.config.environment_id, normalized_attributes)
			-- Only the destructive half can answer a declaration here: the
			-- install a consent refusal strips leaves it unconfirmed.
			local answers = self:answers_declaration(declaration, seq, scope,
				experiment_key, closed_outcome, false)
			self:apply_destructive_outcome(seq, scope, experiment_key,
				closed_outcome, revoked_resolved_at_ms, dispatched_at_ms)
			if answers then
				declaration.decided = true
			end
			conclude({ ok = false, from_cache = false, error = refusal_now })
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
			if subject_now and self:scope_for(subject_now) == scope
				and not self.closed_keys[experiment_key] then
				entry_now = self.entries[experiment_key]
			end
		end
		local resolved_at_ms = clock.unix_ms()
		local result, outcome = M.apply(entry_now, response, resolved_at_ms,
			experiment_key, self.config.app_id, self.config.environment_id,
			normalized_attributes)
		outcome.attributes = normalized_attributes
		-- Captured BEFORE install (which may settle this very seq): true
		-- when a NEWER outcome for this key already settled while this
		-- response was in flight, i.e. the install below discards it.
		local fenced_out =
			seq <= (self.settled[scope .. scope_separator .. experiment_key] or 0)
		if outcome.remint and not self.reminted
			and not fenced_out and auth_epoch == self.auth_epoch then
			-- The persisted subject id failed the wire grammar (storage
			-- corruption this client could not detect locally): re-mint
			-- once per process and retry as a fresh subject — from the
			-- revalidation path too, or a rejected cached subject would
			-- never heal until an explicit host fetch happens to run. A
			-- second grammar reject with a freshly minted id is a bug,
			-- never a loop. (Never reached under a mid-flight revocation:
			-- the consent gate above returns first, so no id is minted
			-- post-revocation.) The re-mint honors the SAME fences as any
			-- other outcome — a grammar reject that is fenced out, stale
			-- by epoch, or stale by scope must not rotate the persisted
			-- subject, wipe entries, or consume the one-shot budget: it
			-- falls through and is discarded like the stale outcome it is.
			local subject_now = self:current_subject_id()
			if subject_now and self:scope_for(subject_now) == scope then
				self.reminted = true
				self:diagnose("reminted", "subject_id")
				self:adopt_minted_subject_id()
				-- The retry carries the SAME normalized attribute set the
				-- rejected request sent: the adopt above cleared the cached
				-- entry, so the cadence path could no longer recover its
				-- saved attributes on its own.
				self:fetch(experiment_key, attributes, callback,
					is_revalidation, normalized_attributes, declaration, seq)
				return
			end
		end
		if outcome.remint and self.reminted then
			-- The one-shot re-mint budget is already spent: this grammar
			-- reject is now a PERMANENT 400 for the current subject/input
			-- set, and the cached assignment must not keep serving
			-- indefinitely against it — fail closed exactly like every
			-- other permanent bad-request (durable drop, decision-time
			-- stamp raise, closed result). The carve-out covers only the
			-- path that actually re-mints; fenced/stale rejects are still
			-- discarded whole by the install gates.
			outcome.drop_entry = true
		end
		if outcome.transient and auth_epoch == self.auth_epoch then
			-- Pacing is gated on scope currency exactly like the install:
			-- a transient answer for a RE-MINTED-AWAY subject is discarded
			-- from state, and its Retry-After must be discarded with it —
			-- a stale 429/5xx must not park the CURRENT subject's
			-- revalidation (and kill checks) for up to the day clamp.
			local pace_subject = self:current_subject_id()
			if pace_subject and self:scope_for(pace_subject) == scope then
				-- And on the per-key SEQUENCE fence, completing the gate
				-- set: an older in-flight fetch's transient that settles
				-- AFTER a newer same-key authoritative response is stale
				-- truth — the server has already answered newer — and its
				-- Retry-After must not install plane-wide pacing.
				-- Transients never settle the fence themselves, so two
				-- out-of-order transients both pace (both are live truth;
				-- the deferral setter keeps the furthest deadline).
				local fence_key = scope .. scope_separator .. experiment_key
				if seq > (self.settled[fence_key] or 0) then
					self:pace_transient(outcome.retry_after_seconds)
				end
			end
		end
		local answers = self:answers_declaration(declaration, seq, scope,
			experiment_key, outcome, auth_epoch == self.auth_epoch)
		self:install(seq, scope, experiment_key, outcome, auth_epoch,
			resolved_at_ms, dispatched_at_ms)
		if answers then
			declaration.decided = true
		end
		-- The epoch re-check guards the PUBLIC callback like the install:
		-- a response that raced a fail-closed latch was discarded from
		-- state above, and its caller must not receive a healthy
		-- assignment either — it gets the closed result. (The
		-- latch-setting response itself re-derives its own identical
		-- closed result here.)
		if auth_epoch ~= self.auth_epoch then
			conclude({ ok = false, from_cache = false, error = self.blocked_error or "unauthorized" })
			return
		end
		-- The subject-scope re-check guards the callback the same way: a
		-- subject re-minted while this response was in flight makes it
		-- ANOTHER subject's assignment — the install discarded it, and the
		-- caller must receive the miss, never the discarded variant.
		local subject_now = self:current_subject_id()
		if not subject_now or self:scope_for(subject_now) ~= scope then
			conclude({ ok = false, from_cache = false, error = "stale_subject" })
			return
		end
		-- And the per-key sequence fence guards it last: an older
		-- AUTHORITATIVE response that a newer settled outcome already
		-- fenced out was discarded by the install, and its caller must
		-- receive the SETTLED current state — the cached assignment the
		-- getters serve, or the miss — never the fenced-out variant.
		-- Transient results already derive from the current fenced entry
		-- and pass through untouched.
		if fenced_out and outcome.authoritative then
			-- The superseded serve honors the SAME attribute fence as the
			-- transient serves: the newer settled entry may have been
			-- evaluated under a different targeting context than THIS
			-- older request carried, and the race loser's callback must
			-- not receive a mismatched variant as a successful cache
			-- serve — it gets the closed superseded result instead.
			conclude(serve_entry_or_fail(self:served_entry(experiment_key),
				"superseded", normalized_attributes))
			return
		end
		-- A non-adult declaration of the experiment pending since this fetch
		-- left (another fetch's): its caller receives no variant, a cache
		-- serve included, whatever this answer installed. The getters serve
		-- none either. The result's source (the cached entry for a cache
		-- serve, the installed one otherwise) decides: an age-exempt one is
		-- handed back as before.
		local pending = self.declaring[experiment_key]
		local source = result.from_cache and entry_now or outcome.new_entry
		if pending and pending.seq ~= seq and result.assigned
			and not age_exempt(source) then
			conclude({ ok = false, from_cache = false, error = "superseded" })
			return
		end
		conclude(result)
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
	self.http_transport:tick()
	-- Owed durable writes retry FIRST and regardless of consent: this is
	-- local disk housekeeping (no network, no serving decisions), and a
	-- kill drop decided under grant must land durably even if consent
	-- flipped meanwhile.
	self:retry_durable_sync()
	if self.fact_key_prune_owed then
		-- Facts left the pipeline outside a settle (cap eviction, a purge):
		-- the same housekeeping, whatever the consent state.
		self:prune_fact_key_history()
	end
	if consent_refusal(self.deps.consent()) then
		return
	end
	-- Owed-exposure sweep: cache-restored applications, locally failed
	-- emissions, and later explicit applications all
	-- drain here, in per-experiment order, while consent is granted.
	self:sweep_owed(true)
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
		-- A key with a pending non-adult declaration is left alone: its
		-- remembered attributes declare the earlier age. So is a key a
		-- terminal answer closed: only an explicit fetch or the next
		-- session asks for it again.
		if not self.declaring[key] and not self.closed_keys[key] then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	local generation = self.cache_generation
	for i = 1, #keys do
		-- Batched per tick: one GET per cached entry, each re-sending its
		-- last host-supplied attributes. Outcomes apply at resolution.
		-- The latch is re-checked before EACH dispatch: a transport that
		-- completes SYNCHRONOUSLY can land an earlier key's 401 mid-loop,
		-- and the remaining keys must not dispatch as NEW post-latch
		-- fetches — their authorized answers would be epoch-current and
		-- unlatch/reinstall, defeating the halt (the epoch gate only
		-- discards flights that were already in the air when the latch
		-- landed). The GENERATION is re-checked for the same reason: a
		-- synchronous grammar-400 re-mints mid-loop (adopt wipes the
		-- cache under a NEW subject and retries its own key), and the
		-- remaining pre-remint keys must not dispatch as revalidations
		-- for the fresh subject — assignments the host never requested,
		-- with no restored attributes.
		if self.auth_blocked or self.cache_generation ~= generation then
			break
		end
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
	local entry = self:served_entry(experiment_key)
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
	local entry = self:served_entry(experiment_key)
	if not entry then
		return nil
	end
	return copy_value(entry.variant_payload, 0)
end

-- Applying a variant is the host's statement that it acted on the value.
-- The once-per-tuple record is independent of how often it fetched or read it.
function Experiments:record_application(experiment_key, extra)
	if type(experiment_key) ~= "string" or experiment_key == "" then return nil, "experiment_key_required" end
	local refusal = consent_refusal(self.deps.consent())
	if refusal then return nil, refusal end
	local entry = self:served_entry(experiment_key)
	if not entry then return nil, "no_assignment" end
	if not valid_subject_fact_key(entry.subject_fact_key) then
		self:diagnose("fact_skipped", "no_subject_fact_key")
		return entry.variant_key, "exposure_no_subject_fact_key"
	end
	if not serving_pins(entry) then
		self:diagnose("fact_skipped", "serving_pins_missing")
		return entry.variant_key, "serving_pins_missing"
	end
	if self.deps.open_owed_session then
		local opened, err = self.deps.open_owed_session()
		if not opened then return nil, err end
	end
	local tuple = exposure_tuple(experiment_key, entry)
	local previous = self.exposed[tuple]
	if previous and not extra then
		self.applications[experiment_key] = copy_value(previous, 0)
		return entry.variant_key
	end
	local record = self:exposure_snapshot(entry)
	if type(record.anonymous_id) ~= "string" or record.anonymous_id == "" then
		return entry.variant_key, "anonymous_id_required"
	end
	self.applications[experiment_key] = copy_value(record, 0)
	if not extra then self.exposed[tuple] = copy_value(record, 0) end
	self:queue_application(experiment_key, record)
	return entry.variant_key
end

function Experiments:apply_variant(experiment_key)
	return self:record_application(experiment_key, false)
end

-- Compatibility API for an additional explicit application in this session.
function Experiments:track_exposure(experiment_key)
	local variant, err = self:record_application(experiment_key, true)
	return variant ~= nil and err == nil, err
end

function Experiments:track_outcome(experiment_key, outcome_key, outcome_value)
	if type(experiment_key) ~= "string" or experiment_key == "" then return false, "experiment_key_required" end
	local refusal = consent_refusal(self.deps.consent())
	if refusal then return false, refusal end
	if type(outcome_key) ~= "string" or #outcome_key < 1 or #outcome_key > 128
		or not outcome_key:match("^[%w._:%-]+$") then return false, "invalid_outcome_key" end
	if type(outcome_value) ~= "number" or outcome_value ~= outcome_value
		or math.abs(outcome_value) > 9007199254740992 or outcome_value % 1 ~= 0 then
		return false, "invalid_outcome_value"
	end
	local application = self.applications[experiment_key]
	if self.auth_blocked or self.declaring[experiment_key] or self.closed_keys[experiment_key]
		or not application then return false, "no_assignment" end
	local record = copy_value(application, 0)
	record.application_id = random.hex(32)
	record.event_ts = clock.iso_utc()
	record.outcome_key = outcome_key
	record.outcome_value_wire = string.format("%.0f", outcome_value == 0 and 0 or outcome_value)
	self:queue_application(experiment_key, record)
	return true
end

return M
