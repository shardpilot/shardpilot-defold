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
--   * 304 Not Modified — the cached snapshot is served (`from_cache = true`).
--   * A transient failure (offline, 429, 5xx, malformed body) — the cached
--     snapshot is served with `from_cache = true` and `error` carrying the
--     reason; with no usable cache the fetch fails.
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
-- successful fetch. There is no experiment assignment, no exposure events,
-- and no automatic refresh here by design — the game triggers every fetch.

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

-- The endpoint answers `{ "version": <number>, "values": { key: value } }`.
-- The configuration map served to getters is the `values` object; a body that
-- is a JSON object WITHOUT a `values` member is served as the map itself, so
-- an unwrapped payload (fixtures, older servers) still works. A wrapper whose
-- `values` member is present but not a keyed object (a string, number,
-- boolean, or a positional array — e.g. after a server-side schema bug) is
-- MALFORMED: falling back to serving the wrapper would expose wrapper fields
-- as configuration and overwrite the last-known-good cache. Returns
-- (values, version), or nil for a malformed wrapper.
local function extract(decoded)
	local version = type(decoded.version) == "number" and decoded.version or nil
	local values = decoded.values
	if values ~= nil then
		if type(values) ~= "table" or values[1] ~= nil then
			return nil
		end
		return values, version
	end
	return decoded, version
end

-- Parse a configuration body end-to-end: a JSON object whose configuration
-- map is usable. Returns (values, version), or nil when the body cannot
-- supply one. Never throws.
local function parse_config(body)
	local decoded = decode_object(body)
	if not decoded then
		return nil
	end
	return extract(decoded)
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
-- (result, new_cache, authoritative):
--   * `new_cache` non-nil means "persist this record"; it exists only for a
--     fresh 200, so no failure — unauthorized, permanent, malformed — and no
--     cache-served outcome ever disturbs the last-known-good record.
--   * `authoritative` marks the outcomes that settle the request fence: a
--     fresh 200, an unauthorized response, and a permanent HTTP error. A
--     transient/cache fallback is NOT authoritative — it says nothing about
--     the current configuration, so it must not fence off a fresh response
--     still in flight.
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
			return {
				ok = true,
				from_cache = true,
				values = values,
				version = version,
			}, nil, false
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
	-- no connection, backpressure, or a server-side error. Any other status —
	-- a 404 for a removed environment, an unexpected redirect, other 4xx — is
	-- an authoritative "this configuration is not being served here", so the
	-- fetch fails instead of reporting stale values as a healthy `ok = true`
	-- (the cache record and the getter snapshot stay untouched).
	if status == 0 then
		return serve_cache_or_fail(cache, "http_0"), nil, false
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
		-- Requests are numbered, and `settled_seq` is the highest sequence
		-- whose AUTHORITATIVE outcome has landed: a fresh 200, an
		-- unauthorized response, or a permanent HTTP error. Only a fetch
		-- newer than every settled one may install: with two fetches in
		-- flight, responses can arrive out of order, and an older success
		-- must neither roll back a newer configuration nor sneak values in
		-- after a newer fail-closed outcome. Non-authoritative outcomes
		-- (a transient failure, a cache-served fallback) do not settle —
		-- they say nothing about the current configuration, so they must
		-- not fence off a fresh response still in flight.
		fetch_seq = 0,
		settled_seq = 0,
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

-- The usable cache record for THIS scope, or nil. The in-process record is
-- preferred (it is the freshest served configuration even when a durable
-- write failed); the durable store is read when the in-process record is
-- absent or scoped elsewhere. A record without an identity scope, or written
-- for any other (workspace, environment, client, url) tuple, is a miss: its
-- values are never served and its ETag is never sent. So is a record whose
-- body no longer decodes — it could neither be served offline nor recovered
-- from after the 304 its ETag would provoke. The next successful fetch for
-- this scope overwrites it.
function RemoteConfig:load_cache(client_id)
	if not client_id then
		return nil
	end
	local scope = self:scope_for(client_id)
	if self.cache and self.cache.scope == scope then
		-- In-process records only ever hold a body that decoded when they
		-- were installed, so no re-check is needed here.
		return self.cache
	end
	local record = storage.load_remote_config(self.config)
	if not record or record.scope ~= scope then
		return nil
	end
	if not parse_config(record.body) then
		return nil
	end
	return record
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
--   * only AUTHORITATIVE outcomes settle the fence (fresh 200,
--     unauthorized, permanent error); a transient/cache fallback says
--     nothing about the current configuration and must not fence off a
--     fresh response still in flight;
--   * only a fresh 200 installs anything (`new_cache` exists exactly then);
--     a cache-served outcome re-serves content the snapshot already holds,
--     and installing it could roll back a fresher body installed while it
--     was in flight;
--   * the scope must still be current — an identity rotated while the
--     response was in flight makes the response another client's
--     configuration (a different rollout bucket), which must not be served
--     or persisted.
-- The snapshot is a defensive copy: the result table is handed to game code,
-- and a callback that mutates `result.values` must not corrupt what later
-- getters read.
function RemoteConfig:install(seq, result, new_cache, scope, authoritative)
	if seq <= self.settled_seq then
		return
	end
	if authoritative then
		self.settled_seq = seq
	end
	if not result.ok or not new_cache then
		return
	end
	local current_id = self:client_id()
	if not current_id or self:scope_for(current_id) ~= scope then
		return
	end
	new_cache.scope = scope
	-- The in-process record is updated even when the durable write fails:
	-- the freshest served configuration stays the offline fallback for this
	-- process either way.
	self.cache = new_cache
	if not storage.save_remote_config(self.config, new_cache) then
		-- An older durable record may still be on disk, and a restart would
		-- revive it OVER the newer configuration just served. Clear it
		-- (best-effort — with the storage backend itself down this fails too
		-- and the stale record is at least superseded in this process): a
		-- restart then starts from the game's defaults rather than from
		-- rolled-back values.
		storage.clear_remote_config(self.config)
		self:diagnose("cache_persist_failed")
	end
	self.values = copy_value(result.values, 0)
	self.version = result.version
end

-- Fetch the configuration. `callback(result)` receives
-- { ok, from_cache, error?, values?, version? }; it is optional and — like
-- every http.request callback — fires asynchronously on the real runtime.
-- A successful result (fresh OR cached) also updates the getter snapshot;
-- a failed one leaves it untouched. Returns true when the request was
-- dispatched, false (with the callback already invoked) when it could not be.
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
		return false
	end
	if not json or type(json.decode) ~= "function" then
		-- Without a decoder neither a fresh body nor the cache can produce
		-- values, so there is nothing to serve.
		finish({ ok = false, from_cache = false, error = "json_unavailable" })
		return false
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
		finish(serve_cache_or_fail(cache, "http_unavailable"))
		return false
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
		local result, new_cache, authoritative = M.apply(cache, response, clock.unix_ms())
		self:install(seq, result, new_cache, scope, authoritative)
		finish(result)
	end, headers, nil, options)
	return true
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
-- when unknown (no configuration yet, or an unwrapped payload without one).
function RemoteConfig:get_version()
	return self.version
end

M.RemoteConfig = RemoteConfig

return M
