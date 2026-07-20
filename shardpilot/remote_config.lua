-- Remote-config fetch client: GETs the published configuration for this
-- (workspace, environment, client) scope from the remote-config endpoint and
-- serves typed values to game code, with a durable last-known-good cache so a
-- restart or an offline launch still gets the previously fetched
-- configuration. Deliberately separate from the analytics transport
-- (shardpilot/transport.lua): configuration is FETCHED (a GET of one
-- resource, ETag-revalidated), never batched, and authenticates with the
-- publishable api_key only — a Mode B ingest token cannot authenticate the
-- remote-config endpoint (see client.lua's auth validation).
--
-- Fetch semantics (one fetch = one HTTP GET, decided by M.apply):
--   * 200 with a JSON object body — fresh values are served and the cache is
--     overwritten (body + response ETag).
--   * 304 Not Modified — the cached snapshot is served (`from_cache = true`)
--     and the record's freshness stamp is renewed, in memory and
--     (best-effort) in the durable record: the endpoint confirmed the body
--     as current, so the record outranks same-scope records stamped while
--     the request was in flight. The one exception is a FRESHER record
--     carrying a DIFFERENT body — a 304 validates at server handling time,
--     not delivery time, so it never displaces content it cannot be
--     ordered against (see install).
--   * A transient failure (offline, a request timeout (408), 429, 5xx,
--     malformed body) — the cached snapshot is served with
--     `from_cache = true` and `error` carrying the reason; with no usable
--     cache the fetch fails.
--   * 401/403 — fails CLOSED: the cached snapshot is never served for this
--     outcome (a revoked or wrong key must not keep supplying configuration),
--     but the cache file itself is left untouched.
--   * Any other status (a 404 for a removed environment, an unexpected 3xx,
--     other 4xx) is a PERMANENT failure: the fetch fails rather than serving
--     the cached snapshot as `ok = true` — retrying cannot help and stale
--     values must not masquerade as a healthy fetch. As with 401/403, the
--     cache record and the getter snapshot are left untouched.
--
-- The cache is stamped with the (workspace, environment, client, url) scope
-- it was fetched for; a cache written by any other scope is a miss (its ETag
-- is never sent, its values never served) and is overwritten by the next
-- successful fetch. There is no experiment assignment and no exposure event
-- here (that surface lives in shardpilot/experiments.lua), and this module
-- never schedules a fetch on its own — by default the game triggers every
-- fetch. The one exception is the OPT-IN periodic revalidation timer
-- (config `remote_config_revalidate`, default off; the timer itself lives
-- in client.lua's update tick): when enabled, the client calls fetch() on an
-- interval derived from the server's Cache-Control max-age (floored at 60s,
-- 300s when unknown — see revalidate_interval_seconds), each tick a plain
-- conditional GET riding the same If-None-Match/304 lane as a host fetch.
-- That automatic lane HALTS after any authoritative 401/403 (`auth_refused`)
-- until a new client is constructed; host-triggered fetches never consult
-- the flag and keep classifying per fetch, and no classification or cache
-- behavior changes with the timer on.

local clock = require "shardpilot.clock"
local storage = require "shardpilot.storage"

local M = {}

local config_route_prefix = "/config/v1/"

local scope_separator = "\31"

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

-- Percent-escape everything outside the RFC 3986 unreserved set, so an
-- identifier containing "/", "%", or spaces cannot smuggle extra path
-- segments into the fetch URL. The escaping is injective (every escaped
-- character has exactly one spelling, "%" itself included), so two distinct
-- raw strings can never escape to the same output.
local function escape_segment(value)
	return (value:gsub("[^%w%-%._~]", function(ch)
		return string.format("%%%02X", string.byte(ch))
	end))
end

function M.build_url(base_url, workspace_id, environment_id, client_id)
	return trim_slash(base_url) .. config_route_prefix
		.. escape_segment(workspace_id) .. "/"
		.. escape_segment(environment_id) .. "/"
		.. escape_segment(client_id)
end

-- Scope components are escaped like URL segments — the identifiers are only
-- validated as non-empty strings, so a raw join would be ambiguous when a
-- component itself contains the separator byte — and then joined with a
-- separator no escaped component can contain. Two distinct (workspace,
-- environment, client, url) tuples therefore can never collide into one
-- scope string. The base URL is re-trimmed here (client.lua already
-- normalizes it once) so equivalent spellings of the same endpoint can never
-- produce distinct scopes.
function M.build_scope(workspace_id, environment_id, client_id, base_url)
	return escape_segment(workspace_id or "") .. scope_separator
		.. escape_segment(environment_id or "") .. scope_separator
		.. escape_segment(client_id or "") .. scope_separator
		.. trim_slash(base_url or "")
end

-- Decode a JSON object body. Returns the decoded table, or nil for anything
-- unusable: no decoder on this runtime, unparseable text, or a non-object
-- payload. Objectness is checked on the TEXT (the first significant
-- character must be "{") because it cannot be told from the decoded value —
-- an empty array decodes to the same Lua table as an empty object, and
-- accepting `[]` would overwrite a good cache with an empty configuration.
-- Never throws.
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

-- The first significant character of the top-level `values` member's value
-- in the body TEXT ("{" for an object, "[" for an array, "n" for null, and
-- so on), or nil when the body has no such member. The decoded Lua value
-- cannot answer this alone: an empty array decodes to the same table as an
-- empty object, and a JSON null is commonly decoded to nil — identical to
-- the member being absent. The scan is string- and depth-aware, so a nested
-- `values` key or a string value spelled "values" cannot be mistaken for
-- the top-level member; escaped key spellings are not decoded and read as
-- not-found, which fails toward `malformed_response` (the safe direction).
local function top_level_values_char(body)
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
			if depth == 1 and plain and body:sub(start, j - 1) == "values" then
				local k = j + 1
				while k <= n and body:sub(k, k):match("%s") do
					k = k + 1
				end
				-- Only a KEY is followed by a colon; a string VALUE that
				-- happens to spell "values" is followed by "," or "}".
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

-- The endpoint answers `{ "version": <number>, "values": { key: value } }`.
-- The configuration map served to getters is the `values` object; a body that
-- is a JSON object WITHOUT a `values` member is served as the map itself, so
-- an unwrapped payload (fixtures, older servers) still works. A wrapper whose
-- `values` member is present but not a keyed object (a string, number,
-- boolean, null, or an array — e.g. after a server-side schema bug) is
-- MALFORMED: falling back to serving the wrapper would expose wrapper fields
-- as configuration and overwrite the last-known-good cache. The two shapes
-- the decoded value cannot settle on its own are re-checked on the body
-- text: an empty array (it decodes to the same Lua table as an empty
-- object) and a JSON null (commonly decoded to nil, identical to an absent
-- member). Returns (values, version) — the version read from the wrapper
-- only — or nil for a malformed wrapper.
local function extract(decoded, body)
	local values = decoded.values
	if values ~= nil then
		-- Object-ness is decided on the body TEXT, not the decoded table: an
		-- empty array decodes to the same table as an empty object, and a
		-- sparse array (`[null, 1]` under a decoder that maps null to nil)
		-- can dodge any positional-index probe. A JSON object can only carry
		-- string keys, so the text check subsumes them all.
		if type(values) ~= "table" or top_level_values_char(body) ~= "{" then
			return nil
		end
		-- The published version is wrapper metadata, so it is read only
		-- here: in an unwrapped payload a config key named "version" is
		-- configuration, not a revision marker.
		local version = type(decoded.version) == "number" and decoded.version or nil
		return values, version
	end
	if top_level_values_char(body) ~= nil then
		-- The body HAS a `values` member the decoder could not deliver as a
		-- table (a JSON null, or a value the runtime maps to nil): malformed,
		-- not an unwrapped payload.
		return nil
	end
	return decoded, nil
end

-- Parse a configuration body end-to-end: a JSON object whose configuration
-- map is usable. Returns (values, version), or nil when the body cannot
-- supply one. Never throws.
local function parse_config(body)
	local decoded = decode_object(body)
	if not decoded then
		return nil
	end
	return extract(decoded, body)
end

-- The real Defold http API lowercases response header keys; the test mock
-- may not. Returns the response ETag string or nil.
local function response_etag(response)
	if type(response) ~= "table" or type(response.headers) ~= "table" then
		return nil
	end
	local value = response.headers["etag"] or response.headers["ETag"]
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return value
end

-- The Cache-Control max-age of a response (whole seconds), or nil when the
-- response carries none. Only the client `max-age` directive is read — it is
-- what the opt-in revalidation interval anchors on. The header is parsed as
-- comma-separated directives with the directive NAME matched whole, so a
-- shared-cache or lookalike directive (`s-maxage`, or any name merely ending
-- in `max-age`) can never be misread as the client freshness window.
function M.cache_max_age_seconds(response)
	if type(response) ~= "table" or type(response.headers) ~= "table" then
		return nil
	end
	local value = response.headers["cache-control"] or response.headers["Cache-Control"]
	if type(value) ~= "string" then
		return nil
	end
	for directive in value:lower():gmatch("[^,]+") do
		local seconds = directive:match("^%s*max%-age%s*=%s*(%d+)%s*$")
		if seconds then
			return tonumber(seconds)
		end
	end
	return nil
end

-- Serve the cached snapshot for a transient failure, or fail when no usable
-- cache exists. A served snapshot is still a SUCCESS (`ok = true`) — the game
-- has usable configuration — with `from_cache = true` and `error` carrying
-- why the network could not refresh it.
local function serve_cache_or_fail(cache, error_code)
	if cache then
		local values, version = parse_config(cache.body)
		if values then
			return {
				ok = true,
				from_cache = true,
				error = error_code,
				values = values,
				version = version,
			}
		end
	end
	return { ok = false, from_cache = false, error = error_code }
end

-- Decide one fetch outcome from the transport response and the cached
-- snapshot. Pure (no IO, no state) so tests can drive every branch. Returns
-- (result, new_cache, authoritative, revalidated_cache):
--   * `new_cache` non-nil means "persist this record"; it exists only for a
--     fresh 200, so no failure — unauthorized, permanent, malformed — and no
--     cache-served outcome ever disturbs the last-known-good record.
--   * `authoritative` marks the outcomes that settle the request fence: a
--     fresh 200, a successful 304 revalidation, an unauthorized response,
--     and a permanent HTTP error. A transient/cache fallback is NOT
--     authoritative — it says nothing about the current configuration, so
--     it must not fence off a fresh response still in flight.
--   * `revalidated_cache` non-nil exists exactly for a successful 304
--     revalidation: the cached record with its freshness stamp renewed to
--     the revalidation time. The body is unchanged (a 304 carries none);
--     only the stamp says something new — the endpoint just confirmed this
--     body as current, so the record outranks same-scope records stamped
--     while the request was in flight. Whether the renewal may land is
--     decided at install time: it never displaces a fresher record carrying
--     a different body.
function M.apply(cache, response, now_ms)
	local status = type(response) == "table" and response.status or 0

	if type(response) == "table" and status == 200 then
		local values, version = parse_config(response.response)
		if values then
			return {
				ok = true,
				from_cache = false,
				values = values,
				version = version,
			}, {
				etag = response_etag(response) or "",
				body = response.response,
				fetched_at_ms = now_ms,
			}, true
		end
		return serve_cache_or_fail(cache, "malformed_response"), nil, false
	end

	if type(response) == "table" and status == 304 and cache then
		local values, version = parse_config(cache.body)
		if values then
			-- A successful revalidation is authoritative: the endpoint just
			-- confirmed the cached ETag as CURRENT, so an older in-flight
			-- response must not overwrite it afterwards. The body is
			-- unchanged (a 304 carries none), but the record's freshness
			-- stamp is renewed — the confirmation is NEW information about
			-- how current this body is.
			return {
				ok = true,
				from_cache = true,
				values = values,
				version = version,
			}, nil, true, {
				etag = cache.etag,
				body = cache.body,
				fetched_at_ms = now_ms,
			}
		end
		-- The revalidated cache turned out unreadable: there is nothing left
		-- to serve (the 304 carries no body), so this fails rather than
		-- re-serving the very cache that just failed to decode.
		return serve_cache_or_fail(nil, "cache_unreadable_after_304"), nil, false
	end

	-- An unauthorized response is an authoritative "this key may not read
	-- this configuration", not a transient outage: serving the cached
	-- snapshot would keep a revoked or wrong key supplied with configuration
	-- indefinitely. Fail closed; the cache file is kept untouched but is
	-- never served for this outcome.
	if type(response) == "table" and (status == 401 or status == 403) then
		return { ok = false, from_cache = false, error = "unauthorized" }, nil, true
	end

	-- The cache fallback is reserved for failures a retry can plausibly fix:
	-- no connection, a request timeout, backpressure, or a server-side
	-- error. Any other status — a 404 for a removed environment, an
	-- unexpected redirect, other 4xx — is an authoritative "this
	-- configuration is not being served here", so the fetch fails instead of
	-- reporting stale values as a healthy `ok = true` (the cache record and
	-- the getter snapshot stay untouched).
	if status == 0 then
		return serve_cache_or_fail(cache, "http_0"), nil, false
	elseif status == 408 then
		return serve_cache_or_fail(cache, "transient_408"), nil, false
	elseif status == 429 then
		return serve_cache_or_fail(cache, "transient_429"), nil, false
	elseif status >= 500 then
		return serve_cache_or_fail(cache, "transient_" .. tostring(status)), nil, false
	end
	return { ok = false, from_cache = false, error = "http_" .. tostring(status) }, nil, true
end

-- Depth-bounded copy of a decoded configuration value, so a table handed to
-- the game can be mutated freely without corrupting the snapshot later
-- getters read. Decoded JSON is acyclic; the depth cap only bounds the walk.
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

local RemoteConfig = {}
RemoteConfig.__index = RemoteConfig

-- `config` is the client's normalized configuration (remote_config_url,
-- api_key, workspace_id, environment_id, publish_timeout_seconds,
-- diagnostics). `identity` is a function returning the CURRENT anonymous id:
-- it is read at every fetch (and cache read) rather than captured once, so a
-- later set_anonymous_id naturally invalidates the cache through the scope
-- check instead of silently fetching configuration for a stale client id.
function M.new(config, identity)
	local rc = setmetatable({
		config = config,
		identity = identity,
		values = nil,
		version = nil,
		-- The in-process cache record (`{scope, etag, body, fetched_at_ms}`).
		-- It is updated on every applied fetch even when the durable write
		-- fails, so a later offline fetch falls back to the FRESHEST served
		-- configuration rather than reviving an older on-disk record.
		cache = nil,
		-- Requests are numbered, and `settled` maps a scope to the highest
		-- sequence whose AUTHORITATIVE outcome has landed for it — a fresh
		-- 200, a 304 revalidation, an unauthorized response, or a permanent
		-- HTTP error. Only a fetch newer than every settled one for ITS
		-- scope may install: with two fetches in flight, responses can
		-- arrive out of order, and an older success must neither roll back
		-- a newer configuration nor sneak values in after a newer
		-- fail-closed outcome. The fence is kept per scope — never reset —
		-- so rotating identities can neither leak one scope's fence into
		-- another nor forget a scope's history on re-entry (the map stays
		-- bounded by the identities this instance has actually used).
		-- Non-authoritative outcomes (a transient failure, a cache-served
		-- fallback) do not settle — they say nothing about the current
		-- configuration, so they must not fence off a fresh response still
		-- in flight.
		fetch_seq = 0,
		settled = {},
		-- The last observed Cache-Control max-age (seconds), captured from
		-- any response carrying one; nil until then. Read only by the opt-in
		-- revalidation interval below.
		max_age_seconds = nil,
		-- Automatic-lane halt (assignment-plane Extra 2 mirrored onto the
		-- opt-in RC revalidation TIMER; pending coordinator ratification —
		-- see client.lua): true once ANY authoritative 401/403 landed on
		-- this plane. The update-tick timer stops scheduling fetches while
		-- set; host-triggered fetches never consult it and keep classifying
		-- per fetch (no latch on classification, cache, or getters). Resets
		-- only with a new client (re-init / config change).
		auth_refused = false,
		-- Count of fetches whose RESPONSE has been processed (any lane, any
		-- outcome). The opt-in revalidation timer re-arms its interval from
		-- the latest completed fetch, so a freshly observed (e.g. shorter)
		-- Cache-Control max-age governs the NEXT tick instead of a stale
		-- previously-armed deadline firing first.
		fetches_completed = 0,
	}, RemoteConfig)
	-- Serve the persisted last-known-good snapshot immediately after a
	-- restart: getters work before (and without) any fetch when a cache for
	-- this exact scope exists.
	local cache = rc:load_cache(rc:client_id())
	if cache then
		local values, version = parse_config(cache.body)
		if values then
			rc.cache = cache
			rc.values, rc.version = values, version
		end
	end
	return rc
end

function RemoteConfig:client_id()
	local value = self.identity()
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return value
end

function RemoteConfig:scope_for(client_id)
	return M.build_scope(
		self.config.workspace_id,
		self.config.environment_id,
		client_id,
		self.config.remote_config_url)
end

-- The usable durable record for the given scope, or nil. A record without
-- an identity scope, or written for any other (workspace, environment,
-- client, url) tuple, is a miss: its values are never served and its ETag is
-- never sent. So is a record whose body no longer decodes — it could neither
-- be served offline nor recovered from after the 304 its ETag would provoke.
-- The next successful fetch for this scope overwrites it.
function RemoteConfig:durable_record(scope)
	local record = storage.load_remote_config(self.config)
	if not record or record.scope ~= scope or not parse_config(record.body) then
		return nil
	end
	return record
end

-- The usable cache record for THIS scope, or nil — the FRESHEST of the
-- in-process record (which survives a failed durable write) and the durable
-- record (which another same-app client may have refreshed since this
-- instance last installed), compared by their fetched-at stamps; the
-- in-process record wins ties, being known-good and already backing the
-- getters.
function RemoteConfig:load_cache(client_id)
	if not client_id then
		return nil
	end
	local scope = self:scope_for(client_id)
	local held = nil
	if self.cache and self.cache.scope == scope then
		-- In-process records only ever hold a body that decoded when they
		-- were installed, so no re-check is needed for this one.
		held = self.cache
	end
	local record = self:durable_record(scope)
	if held and (not record or record.fetched_at_ms <= held.fetched_at_ms) then
		return held
	end
	return record
end

-- Freshness stamps order the records for a scope, and the wall clock can
-- move backward (an NTP correction, a user time change): stamped naively, a
-- record being installed could rank BELOW the stale records it supersedes,
-- and a later offline fetch would roll back to them. So the stamp is raised
-- to one millisecond above every record this install supersedes — the
-- record captured at fetch time, the held record, and the durable record
-- for the scope (pre-read by the caller). Only the relative order of stamps
-- matters, so comparisons stay meaningful across restarts.
function RemoteConfig:raise_stamp_above_superseded(record, scope, served_cache, durable)
	local floor = 0
	if served_cache and served_cache.fetched_at_ms > floor then
		floor = served_cache.fetched_at_ms
	end
	if self.cache and self.cache.scope == scope and self.cache.fetched_at_ms > floor then
		floor = self.cache.fetched_at_ms
	end
	if durable and durable.fetched_at_ms > floor then
		floor = durable.fetched_at_ms
	end
	if record.fetched_at_ms <= floor then
		record.fetched_at_ms = floor + 1
	end
end

function RemoteConfig:diagnose(status)
	local hook = self.config.diagnostics
	if type(hook) == "function" then
		-- The hook is integrator code; never let it break the fetch path.
		pcall(hook, { scope = "remote_config", status = status })
	end
end

-- Settle an authoritative fetch outcome and, when it may, install it: the
-- in-process cache record, the durable copy (best-effort), and the getter
-- snapshot. The gates, in order:
--   * the sequence fence — an outcome older than the newest settled one is
--     dropped, so an older success can neither roll back a newer
--     configuration nor sneak values in after a newer fail-closed outcome;
--   * only AUTHORITATIVE outcomes settle the fence (fresh 200, 304
--     revalidation, unauthorized, permanent error); a transient/cache
--     fallback says nothing about the current configuration and must not
--     fence off a fresh response still in flight;
--   * a fresh 200 (`new_cache` exists exactly then) always installs, and so
--     does a successful 304 revalidation (`revalidated_cache` exists exactly
--     then) — the captured record with its freshness stamp renewed; a
--     cache-served outcome installs only by ADOPTION — when the record it
--     served is FRESHER than what this instance holds (or the instance
--     holds nothing for the scope), e.g. it was discovered at fetch time
--     after being written by an earlier launch or another same-app client.
--     A served record no fresher than the held one is never adopted: its
--     content came from (or predates) the held record, and adopting a
--     captured older record could roll back a fresher body installed while
--     the response was in flight;
--   * the scope must still be current — checked BEFORE anything settles: an
--     identity rotated while the response was in flight makes the response
--     another client's configuration (a different rollout bucket), which
--     must not be served or persisted — and it says nothing about the
--     CURRENT scope's configuration either, so it must not settle the fence
--     (after a rotation there and back, a stale-scope outcome would
--     otherwise fence off a still-in-flight response for the scope rotated
--     back to).
-- The snapshot is a defensive copy: the result table is handed to game code,
-- and a callback that mutates `result.values` must not corrupt what later
-- getters read.
function RemoteConfig:install(seq, result, new_cache, scope, authoritative, served_cache, revalidated_cache)
	local current_id = self:client_id()
	if not current_id or self:scope_for(current_id) ~= scope then
		return
	end
	-- The per-scope fence: an outcome settled under another identity never
	-- fences this one, and a scope's own history survives a rotation away
	-- and back.
	if seq <= (self.settled[scope] or 0) then
		return
	end
	if authoritative then
		self.settled[scope] = seq
	end
	if not result.ok then
		return
	end
	local record = new_cache or revalidated_cache
	local durable = record and self:durable_record(scope) or nil
	if revalidated_cache and durable and served_cache
		and durable.body ~= revalidated_cache.body
		and durable.fetched_at_ms > served_cache.fetched_at_ms then
		-- A 304 validates the captured body at SERVER handling time, and
		-- responses arrive in no particular order: a DIFFERENT body,
		-- persisted by another same-app client after this fetch captured
		-- its record, may reflect a newer server state than this
		-- revalidation — the two cannot be ordered from here. Renewing the
		-- stamp over it could roll the durable configuration back to the
		-- old body for restarts and siblings, so the renewal is skipped
		-- (the revalidated values are still served to this fetch's caller).
		-- A different-body record NO fresher than the captured one is
		-- outranked as usual — that is the lingering leftover of a failed
		-- overwrite, healed by this revalidation.
		record = nil
	end
	if record then
		record.scope = scope
		-- Stamped with the wall clock alone, a backward clock jump could
		-- rank this record below the very records it supersedes; raise the
		-- stamp above them first.
		self:raise_stamp_above_superseded(record, scope, served_cache, durable)
		-- The in-process record is updated even when the durable write
		-- fails: the freshest served configuration stays the offline
		-- fallback for this process either way.
		self.cache = record
		if not storage.save_remote_config(self.config, record) then
			-- The stale durable record this fetch captured may still be on
			-- disk, and a restart would revive it OVER the configuration
			-- just served. Clear it (best-effort — with the storage backend
			-- itself down this fails too and the stale record is at least
			-- superseded in this process): a restart then starts from the
			-- game's defaults rather than from rolled-back values. Only a
			-- record no fresher than the one this fetch captured is cleared
			-- — another same-app client may have persisted a FRESHER record
			-- while this response was in flight, and deleting that would
			-- lose the freshest successfully persisted configuration (with
			-- nothing captured at fetch time there is nothing stale to
			-- clear: any record on disk now is such a newer write). After a
			-- revalidation, a durable record carrying the SAME body needs
			-- no clearing either — only its stamp is stale, and trading the
			-- just-confirmed body for a tombstone would be worse. The
			-- record is re-read here: the failed write may have disturbed
			-- what the pre-save read saw.
			durable = self:durable_record(scope)
			if durable and served_cache
				and durable.fetched_at_ms <= served_cache.fetched_at_ms
				and (new_cache ~= nil or durable.body ~= record.body) then
				storage.clear_remote_config(self.config)
			end
			self:diagnose("cache_persist_failed")
		end
	elseif served_cache and (not self.cache or self.cache.scope ~= scope
		or served_cache.fetched_at_ms > self.cache.fetched_at_ms) then
		self.cache = served_cache
	else
		return
	end
	self.values = copy_value(result.values, 0)
	self.version = result.version
end

-- Fetch the configuration. `callback(result)` receives
-- { ok, from_cache, error?, values?, version? }; it is optional and — like
-- every http.request callback — fires asynchronously on the real runtime.
-- A successful result (fresh OR cached) also updates the getter snapshot;
-- a failed one leaves it untouched. Returns true when the request was
-- dispatched, or (false, error_code) — with the callback already invoked —
-- when it could not be.
function RemoteConfig:fetch(callback)
	local function finish(result)
		if type(callback) == "function" then
			-- The callback is game code; never let it break the SDK.
			pcall(callback, result)
		end
		return result
	end

	local client_id = self:client_id()
	if not client_id then
		finish({ ok = false, from_cache = false, error = "client_id_unavailable" })
		return false, "client_id_unavailable"
	end
	if not json or type(json.decode) ~= "function" then
		-- Without a decoder neither a fresh body nor the cache can produce
		-- values, so there is nothing to serve.
		finish({ ok = false, from_cache = false, error = "json_unavailable" })
		return false, "json_unavailable"
	end

	self.fetch_seq = self.fetch_seq + 1
	local seq = self.fetch_seq

	-- Capture the identity ONCE per fetch: the URL, the ETag revalidation,
	-- and the scope stamped on the resulting cache all describe the same
	-- client id even if the identity rotates while the request is in flight.
	local scope = self:scope_for(client_id)
	local cache = self:load_cache(client_id)

	if not http or not http.request then
		-- No transport on this runtime is a transient failure like any
		-- other: serve the last-known-good snapshot when one exists.
		local result = serve_cache_or_fail(cache, "http_unavailable")
		self:install(seq, result, nil, scope, false, cache)
		finish(result)
		return false, "http_unavailable"
	end

	local headers = {
		["Authorization"] = "Bearer " .. self.config.api_key,
	}
	if cache and cache.etag ~= "" then
		headers["If-None-Match"] = cache.etag
	end
	local url = M.build_url(
		self.config.remote_config_url,
		self.config.workspace_id,
		self.config.environment_id,
		client_id)
	local options = {
		timeout = self.config.publish_timeout_seconds,
	}

	http.request(url, "GET", function(_, _, response)
		local result, new_cache, authoritative, revalidated_cache = M.apply(cache, response, clock.unix_ms())
		-- Revalidation bookkeeping, both deliberately outside the install
		-- gates (they are not installs): remember the server's freshness
		-- window when the response names one, and halt the opt-in automatic
		-- revalidation timer on an authoritative auth refusal — per-fetch
		-- classification and the cache are untouched either way.
		local max_age = M.cache_max_age_seconds(response)
		if max_age then
			self.max_age_seconds = max_age
		end
		if authoritative and not result.ok and result.error == "unauthorized" then
			self.auth_refused = true
		end
		self.fetches_completed = self.fetches_completed + 1
		self:install(seq, result, new_cache, scope, authoritative, cache, revalidated_cache)
		finish(result)
	end, headers, nil, options)
	return true
end

-- The opt-in periodic revalidation interval (seconds): the server's last
-- observed Cache-Control max-age, floored at 60s to respect the per-scope
-- server rate limiter, 300s while no max-age has been observed. [Interval
-- anchoring pends coordinator ratification; ADR-0259 pins no numbers.]
local default_revalidate_interval_seconds = 300
local min_revalidate_interval_seconds = 60

function RemoteConfig:revalidate_interval_seconds()
	local interval = self.max_age_seconds or default_revalidate_interval_seconds
	if interval < min_revalidate_interval_seconds then
		interval = min_revalidate_interval_seconds
	end
	return interval
end

-- ── typed value getters ───────────────────────────────────────────────────────
--
-- Getters read the in-memory snapshot: the last successful fetch (fresh or
-- cached), or the disk cache loaded at construction. They never touch the
-- network, never throw, and serve the caller's default until configuration
-- is available. Typed getters return the default on a missing key AND on a
-- type mismatch, so game code always receives the type it asked for. The
-- snapshot is last-served-wins: an identity rotation does not clear it (a
-- mid-session rotation must not blank the game's tuning) — the next fetch,
-- scoped to the new identity, replaces it.

-- The snapshot value for a getter key, or nil. Written with explicit
-- branches — an and/or chain would collapse a stored `false` into nil and
-- make get_boolean unable to serve a false flag.
local function lookup(rc, key)
	if type(key) ~= "string" or key == "" or type(rc.values) ~= "table" then
		return nil
	end
	return rc.values[key]
end

-- The raw value for `key` (any JSON type), or nil when absent. Tables are
-- returned as depth-bounded copies so the caller may mutate them freely.
function RemoteConfig:get_value(key)
	return copy_value(lookup(self, key), 0)
end

function RemoteConfig:get_string(key, default)
	local value = lookup(self, key)
	if type(value) == "string" then
		return value
	end
	return default
end

function RemoteConfig:get_number(key, default)
	local value = lookup(self, key)
	if type(value) == "number" then
		return value
	end
	return default
end

function RemoteConfig:get_boolean(key, default)
	local value = lookup(self, key)
	if type(value) == "boolean" then
		return value
	end
	return default
end

-- A copy of the whole configuration map, or nil when no configuration has
-- been served yet (no fetch and no usable cache).
function RemoteConfig:get_values()
	if type(self.values) ~= "table" then
		return nil
	end
	return copy_value(self.values, 0)
end

-- The published configuration version from the last served payload, or nil
-- when unknown (no configuration yet, or an unwrapped payload — the version
-- is wrapper metadata, so an unwrapped payload never carries one).
function RemoteConfig:get_version()
	return self.version
end

M.RemoteConfig = RemoteConfig

return M
