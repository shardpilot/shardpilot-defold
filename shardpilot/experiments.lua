-- Experiment-assignment fetch client (GAP-017, ADR-0259): GETs the runtime
-- assignment for one (app, environment, experiment, subject) scope from the
-- control-plane assignment endpoint and serves the decision to game code,
-- with a durable last-known-good cache per scope so a restart or an offline
-- launch still sees the previously fetched assignment. Deliberately separate
-- from the analytics transport (shardpilot/transport.lua) and from the
-- remote-config client (shardpilot/remote_config.lua): an assignment is
-- FETCHED (a GET of one resource), never batched, and authenticates with the
-- publishable api_key only — a Mode B ingest token cannot authenticate this
-- endpoint (see client.lua's auth validation).
--
-- The subject of every fetch is the client's dedicated `spcid_...`
-- installation id (minted and persisted by client.lua; grammar
-- `^spcid_[A-Za-z0-9_-]{20,64}$`). It is a separate identifier from the
-- anonymous id: never derived from it, never replacing it.
--
-- Fetch semantics (one fetch = one HTTP GET, decided by M.apply — the same
-- per-fetch classification canon as the remote-config client, ported, with
-- the two assignment-plane extras from ADR-0259 Amendment 2):
--   * 200 with a JSON assignment body — the decision is served and the cache
--     is overwritten. All three not-assigned shapes are valid 200s,
--     distinguished by `reason`: absent (the deterministic traffic gate),
--     "kill_switch" (an operator kill), "targeting_unmatched".
--   * A transient failure (offline, a request timeout (408), 429, 5xx —
--     including the endpoint's 503 kill-switch-state-unavailable — or a
--     malformed body) — the cached assignment is served with
--     `from_cache = true` and `error` carrying the reason; with no usable
--     cache the fetch fails.
--   * 401/403 — fails CLOSED for THAT fetch (`error = "unauthorized"`,
--     classified by HTTP status alone): the cached assignment is not served
--     as this fetch's outcome, but there is NO cross-fetch latch — the cache
--     record and the getter snapshot are left untouched, a later fetch
--     classifies independently, and getters keep serving last-known-good.
--   * Amendment-2 Extra 1 — the ONE exception to "cache untouched": a 403
--     whose JSON body `error` equals exactly
--     "experiment real-subject assignment is disabled" (the flag-off
--     sentinel) DROPS this scope's cached assignment record and its
--     subject_fact_key — a client must not keep honoring a cached
--     assignment for a surface flipped back off. An unparseable 403 body,
--     or any other 403 body, is a GENERIC 403: fail-closed per fetch, no
--     drop. Never dropped on 401, never on 404.
--   * Amendment-2 Extra 2 — after ANY authoritative 401/403 the AUTOMATIC
--     assignment lane halts (`auth_refused`; read it through
--     `automatic_fetch_allowed()`): an unattended loop must not keep
--     re-asking an endpoint that authoritatively refused it. This SDK
--     schedules no automatic assignment fetch itself today — every fetch
--     here is host-triggered, classifies per fetch, and is never blocked by
--     the halt. The flag resets only with a new client (re-init / config
--     change).
--   * Any other status (404 for an unknown experiment, an unexpected 3xx,
--     other 4xx) is a PERMANENT failure (`http_<status>`): the fetch fails
--     rather than serving the cached assignment as `ok = true`. The cache
--     record and the getter snapshot are left untouched.
--
-- The cache is stamped with the (app_key, environment_key, experiment_key,
-- subject_key, url) scope it was fetched for; a record written for any other
-- scope is a miss and is overwritten by the next successful fetch for its
-- scope. The endpoint itself sets no ETag/Cache-Control and never answers
-- 304, so — unlike the remote-config fetch — there is no revalidation
-- header; the record refreshes only by a full re-fetch.

local clock = require "shardpilot.clock"
local storage = require "shardpilot.storage"

local M = {}

local assignment_route = "/api/cp/v1/runtime/experiments/assignment"

-- The exact flag-off sentinel body `error` value (control-plane
-- ErrExperimentRealSubjectsDisabled). Matched by string EQUALITY on the
-- parsed JSON `error` field — never by substring, never on any other status.
local sentinel_error = "experiment real-subject assignment is disabled"

local scope_separator = "\31"

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

-- Percent-escape everything outside the RFC 3986 unreserved set (the same
-- injective escaping the remote-config client uses for path segments), so an
-- identifier containing "&", "=", "%", or spaces cannot smuggle extra query
-- parameters into the fetch URL.
local function escape_component(value)
	return (value:gsub("[^%w%-%._~]", function(ch)
		return string.format("%%%02X", string.byte(ch))
	end))
end

-- The client id subject grammar the endpoint enforces server-side:
-- `^spcid_[A-Za-z0-9_-]{20,64}$`.
function M.valid_spcid(value)
	if type(value) ~= "string" then
		return false
	end
	local suffix = value:match("^spcid_([A-Za-z0-9_%-]+)$")
	return suffix ~= nil and #suffix >= 20 and #suffix <= 64
end

-- The derived analytics fact subject for client_id-unit assignments:
-- `^sfk1_[0-9a-f]{64}$`. This — never the raw spcid — is the only value
-- permitted as `assignment_key` on experiment_exposure / experiment_outcome
-- props (see client.lua's producers).
function M.valid_subject_fact_key(value)
	if type(value) ~= "string" then
		return false
	end
	local hex = value:match("^sfk1_([0-9a-f]+)$")
	return hex ~= nil and #hex == 64
end

-- Production SDKs target the endpoint under the public identity prefix:
-- GET {experiments_url}/api/cp/v1/runtime/experiments/assignment. The four
-- routing parameters are all required server-side; only they are sent — this
-- SDK exposes no targeting-attribute surface (parity with its remote-config
-- fetch, which sends none either).
function M.build_url(base_url, app_key, environment_key, experiment_key, subject_key)
	return trim_slash(base_url) .. assignment_route
		.. "?app_key=" .. escape_component(app_key)
		.. "&environment_key=" .. escape_component(environment_key)
		.. "&experiment_key=" .. escape_component(experiment_key)
		.. "&subject_key=" .. escape_component(subject_key)
end

-- Scope components are escaped and joined with a separator no escaped
-- component can contain, exactly like the remote-config scope: two distinct
-- (app, environment, experiment, subject, url) tuples can never collide into
-- one scope string, and equivalent spellings of the same endpoint cannot
-- split one scope into two.
function M.build_scope(app_key, environment_key, experiment_key, subject_key, base_url)
	return escape_component(app_key or "") .. scope_separator
		.. escape_component(environment_key or "") .. scope_separator
		.. escape_component(experiment_key or "") .. scope_separator
		.. escape_component(subject_key or "") .. scope_separator
		.. trim_slash(base_url or "")
end

-- Decode a JSON object body. Returns the decoded table, or nil for anything
-- unusable: no decoder on this runtime, unparseable text, or a non-object
-- payload (objectness is checked on the TEXT — an empty array decodes to the
-- same Lua table as an empty object). Never throws.
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

-- The first significant character of the top-level `member`'s value in the
-- body TEXT ("{" for an object, "[" for an array, "n" for null, and so on),
-- or nil when the body has no such member — adapted from the remote-config
-- client's `values`-member scan. The decoded Lua value cannot answer this
-- alone: an empty array decodes to the same Lua table as an empty object,
-- and a JSON null is commonly decoded to nil — identical to the member
-- being absent. The scan is string- and depth-aware, so a nested member or
-- a string value spelling the member name cannot be mistaken for the
-- top-level member; escaped key spellings are not decoded and read as
-- not-found, which fails toward malformed (the safe direction).
local function top_level_member_char(body, member)
	local depth = 0
	local i = 1
	local n = #body
	while i <= n do
		local ch = body:sub(i, i)
		if ch == '"' then
			local start = i + 1
			local j = start
			local plain = true
			while j <= n do
				local c = body:sub(j, j)
				if c == "\\" then
					plain = false
					j = j + 2
				elseif c == '"' then
					break
				else
					j = j + 1
				end
			end
			if depth == 1 and plain and body:sub(start, j - 1) == member then
				local k = j + 1
				while k <= n and body:sub(k, k):match("%s") do
					k = k + 1
				end
				-- Only a KEY is followed by a colon; a string VALUE that
				-- happens to spell the member name is followed by "," or "}".
				if body:sub(k, k) == ":" then
					k = k + 1
					while k <= n and body:sub(k, k):match("%s") do
						k = k + 1
					end
					if k <= n then
						return body:sub(k, k)
					end
					return nil
				end
			end
			i = j + 1
		elseif ch == "{" or ch == "[" then
			depth = depth + 1
			i = i + 1
		elseif ch == "}" or ch == "]" then
			depth = depth - 1
			i = i + 1
		else
			i = i + 1
		end
	end
	return nil
end

-- Parse an assignment body end-to-end into the snapshot shape the SDK serves
-- and the producers read. Strict on the fields the contract pins — a body
-- this cannot parse is MALFORMED (a transient outcome), so a garbled payload
-- can neither overwrite a good cache nor feed the producers:
--   * `assigned` boolean, `version` number, `assignment_key` non-empty
--     string, and `boundary.assignment_unit` one of the two published units
--     are always required;
--   * an assigned decision requires `variant_key`;
--   * a client_id-unit body requires a grammar-valid `subject_fact_key` —
--     it is the only permitted analytics fact subject, so a body without
--     one must not be cached as an assignment.
-- Returns the snapshot table, or nil. Never throws.
local function parse_assignment(body)
	local decoded = decode_object(body)
	if not decoded then
		return nil
	end
	if type(decoded.assigned) ~= "boolean" then
		return nil
	end
	-- The published version is a positive integer. Anything else — a
	-- fractional value, zero/negative, an out-of-int-range magnitude, or a
	-- non-finite number — is a body this build cannot attribute facts to
	-- (experiment_version rides the producer props verbatim): malformed.
	-- The NaN self-inequality check runs before math.floor so floor is only
	-- ever applied to a finite in-range number.
	local version = decoded.version
	if type(version) ~= "number" or version ~= version
		or version < 1 or version > 2147483647
		or version ~= math.floor(version) then
		return nil
	end
	if type(decoded.experiment_key) ~= "string" or decoded.experiment_key == "" then
		return nil
	end
	if type(decoded.assignment_key) ~= "string" or decoded.assignment_key == "" then
		return nil
	end
	local boundary = decoded.boundary
	local unit = type(boundary) == "table" and boundary.assignment_unit or nil
	if unit ~= "synthetic_subject_key" and unit ~= "client_id" then
		return nil
	end
	-- Only the two published refusal reasons exist — absence is the third
	-- (deterministic traffic gate) shape. Any other value is a body this
	-- build cannot interpret: malformed, so it can neither overwrite the
	-- last-known-good cache nor feed the producers.
	local reason = nil
	if decoded.reason ~= nil then
		if decoded.reason ~= "kill_switch" and decoded.reason ~= "targeting_unmatched" then
			return nil
		end
		reason = decoded.reason
	end
	local subject_fact_key = nil
	if unit == "client_id" then
		if not M.valid_subject_fact_key(decoded.subject_fact_key) then
			return nil
		end
		subject_fact_key = decoded.subject_fact_key
	end
	local variant_key = nil
	local variant_payload = nil
	if decoded.assigned then
		if type(decoded.variant_key) ~= "string" or decoded.variant_key == "" then
			return nil
		end
		variant_key = decoded.variant_key
		-- The author-defined payload must be a JSON OBJECT when present.
		-- Object-ness is decided on the body TEXT (the remote-config
		-- `values`-member precedent): a payload the decoder delivered as a
		-- non-table (string/number), a non-object payload text (an array,
		-- empty or not), or a null-bearing member all read as MALFORMED —
		-- installing a mangled payload would hand the game a shape the
		-- author never published, and cache it over the last-known-good
		-- decision.
		local payload_char = top_level_member_char(body, "variant_payload")
		if decoded.variant_payload ~= nil then
			if type(decoded.variant_payload) ~= "table" or payload_char ~= "{" then
				return nil
			end
			variant_payload = decoded.variant_payload
		elseif payload_char ~= nil then
			-- The body HAS a variant_payload member the decoder could not
			-- deliver as a table (a JSON null, or a value the runtime maps
			-- to nil): malformed, not an absent payload.
			return nil
		end
	end
	return {
		experiment_key = decoded.experiment_key,
		version = decoded.version,
		assigned = decoded.assigned,
		reason = reason,
		assignment_key = decoded.assignment_key,
		variant_key = variant_key,
		variant_payload = variant_payload,
		assignment_unit = unit,
		subject_fact_key = subject_fact_key,
	}
end

M.parse_assignment = parse_assignment

-- Depth-bounded copy of a decoded value, so a table handed to the game can
-- be mutated freely without corrupting the snapshot later reads serve.
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

-- One result/snapshot copy: the assignment fields only (never ok /
-- from_cache / error), with the author-defined variant_payload defensively
-- copied.
local function copy_snapshot(snapshot)
	return {
		experiment_key = snapshot.experiment_key,
		version = snapshot.version,
		assigned = snapshot.assigned,
		reason = snapshot.reason,
		assignment_key = snapshot.assignment_key,
		variant_key = snapshot.variant_key,
		variant_payload = copy_value(snapshot.variant_payload, 0),
		assignment_unit = snapshot.assignment_unit,
		subject_fact_key = snapshot.subject_fact_key,
	}
end

local function result_from_snapshot(snapshot, from_cache, error_code)
	local result = copy_snapshot(snapshot)
	result.ok = true
	result.from_cache = from_cache
	result.error = error_code
	return result
end

-- Serve the cached assignment for a transient failure, or fail when no
-- usable cache exists. A served snapshot is still a SUCCESS (`ok = true`)
-- with `from_cache = true` and `error` carrying why the network could not
-- refresh it. A cached body naming a DIFFERENT experiment than the one
-- fetched (a corrupted or foreign write) is a miss, never served.
local function serve_cache_or_fail(cache, error_code, expected_experiment_key)
	if cache then
		local snapshot = parse_assignment(cache.body)
		if snapshot and (expected_experiment_key == nil
			or snapshot.experiment_key == expected_experiment_key) then
			return result_from_snapshot(snapshot, true, error_code)
		end
	end
	return { ok = false, from_cache = false, error = error_code }
end

-- Decide one fetch outcome from the transport response and the cached
-- record. Pure (no IO, no state) so tests can drive every branch — a direct
-- port of the remote-config classifier, minus the ETag/304 lane (this
-- endpoint has neither) and plus the two Amendment-2 extras.
-- `experiment_key` is the experiment the fetch ASKED for: a 200 body naming
-- any other experiment is MALFORMED (transient) — installing it would
-- misattribute another experiment's decision (and its exposures) to this
-- scope. The same check guards the cached body on the serve-cache path.
-- Returns (result, new_cache, authoritative, drop_cache, auth_refused):
--   * `new_cache` non-nil means "persist this record"; it exists only for a
--     parsed fresh 200, so no failure and no cache-served outcome ever
--     disturbs the last-known-good record.
--   * `authoritative` marks the outcomes that settle the per-scope request
--     fence: a fresh 200, an unauthorized response, and a permanent HTTP
--     error. A transient/cache fallback is NOT authoritative.
--   * `drop_cache` is true exactly for the sentinel 403 (Extra 1): the one
--     outcome that removes this scope's cached record and its
--     subject_fact_key. Generic 401/403 NEVER set it.
--   * `auth_refused` is true for every 401/403 (sentinel or generic): the
--     signal the automatic-lane halt (Extra 2) latches on. It has no other
--     side effect — classification stays per fetch.
function M.apply(cache, response, now_ms, experiment_key)
	local status = type(response) == "table" and response.status or 0

	if type(response) == "table" and status == 200 then
		local snapshot = parse_assignment(response.response)
		if snapshot and (experiment_key == nil
			or snapshot.experiment_key == experiment_key) then
			return result_from_snapshot(snapshot, false, nil), {
				body = response.response,
				fetched_at_ms = now_ms,
			}, true, false, false
		end
		return serve_cache_or_fail(cache, "malformed_response", experiment_key), nil, false, false, false
	end

	-- An unauthorized response is an authoritative "this key may not read
	-- this assignment" FOR THIS FETCH, classified by HTTP status alone: fail
	-- closed, serve nothing. It settles the fence and nothing else — no
	-- cross-fetch latch, no getter clearing. The one exception is the exact
	-- sentinel body (Extra 1), which additionally drops this scope's cached
	-- record: an unparseable body, or any other 403 body — including the
	-- generic "experimentation runtime is disabled" and "experiment
	-- assignment fetch is disabled" flag-off truths — is a generic 403 with
	-- NO drop.
	if type(response) == "table" and (status == 401 or status == 403) then
		local drop = false
		if status == 403 then
			local decoded = decode_object(response.response)
			drop = decoded ~= nil and decoded.error == sentinel_error
		end
		return { ok = false, from_cache = false, error = "unauthorized" }, nil, true, drop, true
	end

	-- The cache fallback is reserved for failures a retry can plausibly fix.
	-- The endpoint's own 503 ("kill switch state unavailable") lands in the
	-- 5xx arm — transient by contract. Any other status is an authoritative
	-- "this assignment is not being served here": the fetch fails instead of
	-- reporting a stale decision as a healthy `ok = true`.
	if status == 0 then
		return serve_cache_or_fail(cache, "http_0", experiment_key), nil, false, false, false
	elseif status == 408 then
		return serve_cache_or_fail(cache, "transient_408", experiment_key), nil, false, false, false
	elseif status == 429 then
		return serve_cache_or_fail(cache, "transient_429", experiment_key), nil, false, false, false
	elseif status >= 500 then
		return serve_cache_or_fail(cache, "transient_" .. tostring(status), experiment_key), nil, false, false, false
	end
	return { ok = false, from_cache = false, error = "http_" .. tostring(status) }, nil, true, false, false
end

local Experiments = {}
Experiments.__index = Experiments

-- `config` is the client's normalized configuration (experiments_url,
-- experiments_app_key, experiments_environment_key, api_key,
-- publish_timeout_seconds, diagnostics). `subject` is a function returning
-- the CURRENT spcid: read at every fetch (and cache read) rather than
-- captured once, mirroring the remote-config identity closure.
function M.new(config, subject)
	local ex = setmetatable({
		config = config,
		subject = subject,
		-- In-memory assignment snapshots served to getters and producers:
		-- experiment_key -> { scope, data }. Installed by successful fetches
		-- and, below, from the durable cache at construction.
		snapshots = {},
		-- In-process cache records by scope ({scope, experiment_key, body,
		-- fetched_at_ms}), updated on every applied fetch even when the
		-- durable write fails, so a later offline fetch falls back to the
		-- FRESHEST served assignment.
		cache = {},
		-- The per-scope sequence fence, ported from the remote-config
		-- client: only a fetch newer than every settled one for ITS scope
		-- may install, and only AUTHORITATIVE outcomes settle.
		fetch_seq = 0,
		settled = {},
		-- Per-scope sentinel tombstones: set when a sentinel drop's DURABLE
		-- clear failed (storage writes down while reads still work), so the
		-- surviving disk record can never be reloaded and re-served by a
		-- later transient fetch. While a scope is tombstoned, load_cache()
		-- refuses its durable record (and retries the owed clear); only a
		-- successful durable clear — or a newer fresh decision durably
		-- overwriting the record — lifts it. Process-local by design: a
		-- relaunch before the clear lands re-adopts the record until its
		-- next sentinel (best-effort, like every failed durable write here).
		tombstones = {},
		-- Amendment-2 Extra 2 (assignment plane only): true once ANY
		-- authoritative 401/403 landed. An automatic assignment lane must
		-- consult automatic_fetch_allowed() before scheduling a fetch; this
		-- SDK ships no such lane today, host-triggered fetches never check
		-- it, and the flag resets only with a new client (re-init / config
		-- change) — never on a later per-fetch success.
		auth_refused = false,
	}, Experiments)
	-- Serve the persisted last-known-good assignments immediately after a
	-- restart: getters and producers work before (and without) any fetch for
	-- every record stamped with this exact configuration + subject scope.
	local subject_key = ex:subject_key()
	if subject_key then
		local records = storage.load_experiment_assignments(config)
		for i = 1, #records do
			local record = records[i]
			local scope = ex:scope_for(record.experiment_key, subject_key)
			if record.scope == scope then
				local snapshot = parse_assignment(record.body)
				if snapshot and snapshot.experiment_key == record.experiment_key then
					ex.cache[scope] = record
					ex.snapshots[record.experiment_key] = { scope = scope, data = snapshot }
				end
			end
		end
	end
	return ex
end

function Experiments:subject_key()
	local value = self.subject()
	if not M.valid_spcid(value) then
		return nil
	end
	return value
end

function Experiments:scope_for(experiment_key, subject_key)
	return M.build_scope(
		self.config.experiments_app_key,
		self.config.experiments_environment_key,
		experiment_key,
		subject_key,
		self.config.experiments_url)
end

-- True while no authoritative 401/403 has halted the automatic assignment
-- lane. Host-triggered fetches never consult this; an automatic scheduler
-- (none ships in this SDK today) must.
function Experiments:automatic_fetch_allowed()
	return not self.auth_refused
end

-- The usable durable record for the given scope, or nil. A record written
-- for any other scope is a miss; so is one whose body no longer parses.
function Experiments:durable_record(scope)
	local records = storage.load_experiment_assignments(self.config)
	for i = 1, #records do
		if records[i].scope == scope then
			if parse_assignment(records[i].body) then
				return records[i]
			end
			return nil
		end
	end
	return nil
end

-- The usable cache record for this scope, or nil — the FRESHEST of the
-- in-process record and the durable record, compared by their fetched-at
-- stamps; the in-process record wins ties (ported from the remote-config
-- cache read).
function Experiments:load_cache(experiment_key, subject_key)
	local scope = self:scope_for(experiment_key, subject_key)
	if self.tombstones[scope] then
		-- A sentinel drop is still owed durably for this scope: retry the
		-- clear, and refuse the durable record either way — only the
		-- in-process record (nil until a newer fresh decision installs) may
		-- serve while the disk copy is untrusted.
		if storage.clear_experiment_assignment(self.config, scope) then
			self.tombstones[scope] = nil
		else
			return self.cache[scope]
		end
	end
	local held = self.cache[scope]
	local record = self:durable_record(scope)
	if held and (not record or record.fetched_at_ms <= held.fetched_at_ms) then
		return held
	end
	return record
end

-- Freshness stamps order the records for a scope and the wall clock can move
-- backward: raise the stamp above every record this install supersedes so a
-- later offline fetch cannot roll back to them (ported from the
-- remote-config client).
function Experiments:raise_stamp_above_superseded(record, scope, served_cache, durable)
	local floor = 0
	if served_cache and served_cache.fetched_at_ms > floor then
		floor = served_cache.fetched_at_ms
	end
	local held = self.cache[scope]
	if held and held.fetched_at_ms > floor then
		floor = held.fetched_at_ms
	end
	if durable and durable.fetched_at_ms > floor then
		floor = durable.fetched_at_ms
	end
	if record.fetched_at_ms <= floor then
		record.fetched_at_ms = floor + 1
	end
end

function Experiments:diagnose(status)
	local hook = self.config.diagnostics
	if type(hook) == "function" then
		-- The hook is integrator code; never let it break the fetch path.
		pcall(hook, { scope = "experiments", status = status })
	end
end

-- Settle an authoritative fetch outcome and, when it may, install it —
-- ported from the remote-config install, minus the 304/revalidation lane and
-- plus the sentinel drop. The gates, in order: the scope must still be
-- current; the per-scope sequence fence; only authoritative outcomes settle;
-- the sentinel drop (fence-guarded like any install, so an out-of-order
-- stale sentinel cannot erase a fresher assignment installed after it); a
-- fresh 200 installs and persists; a cache-served outcome installs only by
-- ADOPTION when the served record is fresher than the held one.
function Experiments:install(seq, experiment_key, scope, result, new_cache, authoritative, served_cache, drop_cache)
	local subject_key = self:subject_key()
	if not subject_key or self:scope_for(experiment_key, subject_key) ~= scope then
		return
	end
	if seq <= (self.settled[scope] or 0) then
		return
	end
	if authoritative then
		self.settled[scope] = seq
	end
	if drop_cache then
		-- Amendment-2 Extra 1: the sentinel 403 drops this scope's cached
		-- assignment record AND its subject_fact_key (the sfk lives in the
		-- record and the snapshot; both go). Other scopes' records are
		-- untouched. The scope is tombstoned BEFORE the durable clear is
		-- attempted: should the clear fail (storage writes down while reads
		-- still work), the surviving disk record must not be reloaded and
		-- re-served by a later transient fetch — load_cache() refuses it and
		-- keeps retrying the owed clear while the tombstone stands.
		self.cache[scope] = nil
		local held = self.snapshots[experiment_key]
		if held and held.scope == scope then
			self.snapshots[experiment_key] = nil
		end
		self.tombstones[scope] = true
		if storage.clear_experiment_assignment(self.config, scope) then
			self.tombstones[scope] = nil
		else
			self:diagnose("assignment_cache_drop_failed")
		end
		return
	end
	if not result.ok then
		return
	end
	local record = new_cache
	local durable = record and self:durable_record(scope) or nil
	if record then
		record.scope = scope
		record.experiment_key = experiment_key
		-- Stamped with the wall clock alone, a backward clock jump could
		-- rank this record below the very records it supersedes; raise the
		-- stamp above them first.
		self:raise_stamp_above_superseded(record, scope, served_cache, durable)
		-- The in-process record is updated even when the durable write
		-- fails: the freshest served assignment stays the offline fallback
		-- for this process either way.
		self.cache[scope] = record
		if storage.save_experiment_assignment(self.config, record) then
			-- A durably persisted fresh decision overwrites whatever record
			-- an owed sentinel drop left on disk, so the tombstone lifts. On
			-- a FAILED save it deliberately stands: the disk still holds the
			-- sentinel-disabled record, and the in-process record above
			-- serves this process meanwhile.
			self.tombstones[scope] = nil
		else
			-- The stale durable record this fetch captured may still be on
			-- disk, and a restart would revive it OVER the assignment just
			-- served. Clear it (best-effort) when it is no fresher than the
			-- record this fetch captured — a FRESHER record persisted
			-- meanwhile by another same-app client is left in place.
			durable = self:durable_record(scope)
			if durable and served_cache
				and durable.fetched_at_ms <= served_cache.fetched_at_ms then
				storage.clear_experiment_assignment(self.config, scope)
			end
			self:diagnose("assignment_cache_persist_failed")
		end
	elseif served_cache and (not self.cache[scope]
		or served_cache.fetched_at_ms > self.cache[scope].fetched_at_ms) then
		self.cache[scope] = served_cache
	else
		return
	end
	self.snapshots[experiment_key] = { scope = scope, data = copy_snapshot(result) }
end

-- Fetch the assignment for one experiment. `callback(result)` receives
-- { ok, from_cache, error?, assigned?, reason?, experiment_key?, version?,
--   assignment_key?, variant_key?, variant_payload?, assignment_unit?,
--   subject_fact_key? }; it is optional and — like every http.request
-- callback — fires asynchronously on the real runtime. A successful result
-- (fresh OR cached) also updates the getter/producer snapshot; a failed one
-- leaves it untouched. Returns true when the request was dispatched, or
-- (false, error_code) — with the callback already invoked — when it could
-- not be. Host-triggered by design: this method never consults the
-- automatic-lane halt.
function Experiments:fetch(experiment_key, callback)
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
	local subject_key = self:subject_key()
	if not subject_key then
		finish({ ok = false, from_cache = false, error = "spcid_unavailable" })
		return false, "spcid_unavailable"
	end
	if not json or type(json.decode) ~= "function" then
		-- Without a decoder neither a fresh body nor the cache can produce
		-- an assignment, so there is nothing to serve.
		finish({ ok = false, from_cache = false, error = "json_unavailable" })
		return false, "json_unavailable"
	end

	self.fetch_seq = self.fetch_seq + 1
	local seq = self.fetch_seq

	-- Capture the subject ONCE per fetch: the URL and the scope stamped on
	-- the resulting cache describe the same subject even if the identity
	-- store rotates while the request is in flight.
	local scope = self:scope_for(experiment_key, subject_key)
	local cache = self:load_cache(experiment_key, subject_key)

	if not http or not http.request then
		-- No transport on this runtime is a transient failure like any
		-- other: serve the last-known-good assignment when one exists.
		local result = serve_cache_or_fail(cache, "http_unavailable", experiment_key)
		self:install(seq, experiment_key, scope, result, nil, false, cache, false)
		finish(result)
		return false, "http_unavailable"
	end

	local headers = {
		["Authorization"] = "Bearer " .. self.config.api_key,
	}
	local url = M.build_url(
		self.config.experiments_url,
		self.config.experiments_app_key,
		self.config.experiments_environment_key,
		experiment_key,
		subject_key)
	local options = {
		timeout = self.config.publish_timeout_seconds,
	}

	http.request(url, "GET", function(_, _, response)
		local result, new_cache, authoritative, drop_cache, auth_refused =
			M.apply(cache, response, clock.unix_ms(), experiment_key)
		if auth_refused then
			-- Amendment-2 Extra 2: the automatic lane halts after any
			-- authoritative 401/403 until re-init/config change. Deliberately
			-- NOT fence-guarded — halting is conservative, never an install.
			self.auth_refused = true
		end
		self:install(seq, experiment_key, scope, result, new_cache, authoritative, cache, drop_cache)
		finish(result)
	end, headers, nil, options)
	return true
end

-- A defensive copy of the last served assignment snapshot for this
-- experiment under the CURRENT scope, or nil when none has been served (no
-- fetch and no usable cache) or the scope moved. Never touches the network,
-- never throws.
function Experiments:get_assignment(experiment_key)
	local held = self:assignment_snapshot(experiment_key)
	if not held then
		return nil
	end
	return copy_snapshot(held)
end

-- The raw snapshot for internal readers (the client's exposure/outcome
-- producers), scope-checked like the public getter. Callers only read.
function Experiments:assignment_snapshot(experiment_key)
	if type(experiment_key) ~= "string" or experiment_key == "" then
		return nil
	end
	local held = self.snapshots[experiment_key]
	if not held then
		return nil
	end
	local subject_key = self:subject_key()
	if not subject_key or held.scope ~= self:scope_for(experiment_key, subject_key) then
		return nil
	end
	return held.data
end

M.Experiments = Experiments

return M
