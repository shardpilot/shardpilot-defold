package.path = "./?.lua;./?/init.lua;" .. package.path

socket = {
	now = 1000,
	gettime = function()
		socket.now = socket.now + 0.1
		return socket.now
	end,
}

sys = {
	get_sys_info = function()
		return { system_name = "Linux" }
	end,
}

local requests = {}
local next_status = 200
local next_response_body = nil
local next_response_headers = nil

http = {
	request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = {
			url = url,
			method = method,
			headers = headers,
			body = body,
			options = options,
		}
		local response = { status = next_status, response = next_response_body }
		if next_response_headers then
			response.headers = next_response_headers
		end
		callback(nil, nil, response)
	end,
}

-- The same minimal JSON encoder/decoder the analytics harness uses. Real
-- Defold ships json.encode/json.decode; the SDK uses them only when present.
local function encode_string(value)
	return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function encode_value(value)
	local value_type = type(value)
	if value_type == "table" then
		local is_array = true
		local max = 0
		for key in pairs(value) do
			if type(key) ~= "number" then
				is_array = false
				break
			end
			if key > max then
				max = key
			end
		end
		local parts = {}
		if is_array then
			for i = 1, max do
				parts[#parts + 1] = encode_value(value[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for key in pairs(value) do
			keys[#keys + 1] = key
		end
		table.sort(keys)
		for _, key in ipairs(keys) do
			if value[key] ~= nil then
				parts[#parts + 1] = encode_string(key) .. ":" .. encode_value(value[key])
			end
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif value_type == "string" then
		return encode_string(value)
	elseif value_type == "number" or value_type == "boolean" then
		return tostring(value)
	elseif value == nil then
		return "null"
	end
	return encode_string(value)
end

local function json_decode(text)
	local pos = 1
	local parse_value

	local function skip_ws()
		local _, stop = string.find(text, "^[ \t\r\n]*", pos)
		pos = stop + 1
	end

	local function parse_string()
		pos = pos + 1 -- opening quote
		local parts = {}
		while pos <= #text do
			local ch = string.sub(text, pos, pos)
			if ch == '"' then
				pos = pos + 1
				return table.concat(parts)
			elseif ch == "\\" then
				local esc = string.sub(text, pos + 1, pos + 1)
				local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
				parts[#parts + 1] = map[esc] or esc
				pos = pos + 2
			else
				parts[#parts + 1] = ch
				pos = pos + 1
			end
		end
		error("unterminated string")
	end

	local function parse_object()
		pos = pos + 1 -- {
		local out = {}
		skip_ws()
		if string.sub(text, pos, pos) == "}" then
			pos = pos + 1
			return out
		end
		while true do
			skip_ws()
			local key = parse_string()
			skip_ws()
			pos = pos + 1 -- :
			skip_ws()
			out[key] = parse_value()
			skip_ws()
			local ch = string.sub(text, pos, pos)
			pos = pos + 1
			if ch == "}" then
				return out
			end
		end
	end

	local function parse_array()
		pos = pos + 1 -- [
		local out = {}
		skip_ws()
		if string.sub(text, pos, pos) == "]" then
			pos = pos + 1
			return out
		end
		while true do
			skip_ws()
			out[#out + 1] = parse_value()
			skip_ws()
			local ch = string.sub(text, pos, pos)
			pos = pos + 1
			if ch == "]" then
				return out
			end
		end
	end

	parse_value = function()
		skip_ws()
		local ch = string.sub(text, pos, pos)
		if ch == "{" then
			return parse_object()
		elseif ch == "[" then
			return parse_array()
		elseif ch == '"' then
			return parse_string()
		elseif ch == "t" then
			pos = pos + 4
			return true
		elseif ch == "f" then
			pos = pos + 5
			return false
		elseif ch == "n" then
			pos = pos + 4
			return nil
		else
			local number = string.match(text, "^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
			pos = pos + #number
			return tonumber(number)
		end
	end

	local parsed = parse_value()
	skip_ws()
	if pos <= #text then
		error("trailing content")
	end
	return parsed
end

json = {
	encode = encode_value,
	decode = json_decode,
}

local sdk = require "shardpilot.sdk"
local remote_config = require "shardpilot.remote_config"
local storage = require "shardpilot.storage"

local function assert_true(value, message)
	if not value then
		error(message or "expected true", 2)
	end
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local function assert_nil(value, message)
	if value ~= nil then
		error((message or "expected nil") .. ": got " .. tostring(value), 2)
	end
end

local function reset()
	requests = {}
	next_status = 200
	next_response_body = nil
	next_response_headers = nil
	storage.reset()
end

-- A fake sys persistence layer (mirrors shardpilot/storage.lua's contract) so
-- restart-shaped tests exercise the real durable path, not just the memory
-- fallback. Returns (restore, stores).
local function install_fake_sys_storage()
	local stores = {}
	local saved_get = sys.get_save_file
	local saved_save = sys.save
	local saved_load = sys.load
	sys.get_save_file = function(application_id, file_name)
		return application_id .. "/" .. file_name
	end
	sys.save = function(path, record)
		stores[path] = record
		return true
	end
	sys.load = function(path)
		return stores[path]
	end
	return function()
		sys.get_save_file = saved_get
		sys.save = saved_save
		sys.load = saved_load
	end, stores
end

-- A Mode A (publishable-key) config with remote config enabled — the default
-- shape for these tests.
local function config(overrides)
	local out = {
		ingest_url = "http://localhost:8080",
		remote_config_url = "http://localhost:18081",
		workspace_id = "workspace-test",
		app_id = "app-test",
		environment_id = "develop",
		anonymous_id = "anon-client",
		api_key = "sp_ingest_publishable_key",
		flush_interval_seconds = 1,
		publish_timeout_seconds = 2,
	}
	for key, value in pairs(overrides or {}) do
		out[key] = value
	end
	return out
end

local function values_body(values, version)
	return json.encode({ version = version or 1, values = values })
end

-- Drive one fetch to completion (the http stub answers synchronously) and
-- return the result the callback received.
local function fetch(client)
	local result = nil
	client:fetch_remote_config(function(value)
		result = value
	end)
	assert_true(result ~= nil, "the fetch callback must have been invoked")
	return result
end

local function last_request()
	return requests[#requests]
end

-- ── URL and scope building ────────────────────────────────────────────────────

local function test_build_url_joins_and_escapes_segments()
	assert_equal(
		remote_config.build_url("http://localhost:18081/", "ws 1", "env/dev", "anon+id"),
		"http://localhost:18081/config/v1/ws%201/env%2Fdev/anon%2Bid")
end

local function test_build_scope_keeps_distinct_tuples_distinct()
	assert_true(
		remote_config.build_scope("ws", "env-a", "anon", "http://localhost:18081")
			~= remote_config.build_scope("ws", "env", "a-anon", "http://localhost:18081"),
		"shifting one identifier boundary must not collide two scopes")
	assert_true(
		remote_config.build_scope("ws", "env", "anon", "http://localhost:18081")
			~= remote_config.build_scope("ws", "env", "anon", "http://localhost:28081"),
		"the same identity against two endpoints must not share one scope")
	assert_true(
		remote_config.build_scope("ws\31env", "x", "anon", "http://localhost:18081")
			~= remote_config.build_scope("ws", "env\31x", "anon", "http://localhost:18081"),
		"a separator byte inside a component must not shift the tuple boundaries")
	assert_equal(
		remote_config.build_scope("ws", "env", "anon", "http://localhost:18081"),
		remote_config.build_scope("ws", "env", "anon", "http://localhost:18081/"),
		"a trailing slash must not split one endpoint into two scopes")
end

-- ── configuration validation ──────────────────────────────────────────────────

local function test_config_validation()
	reset()
	local invalid_cases = {
		{ { remote_config_url = 42 }, "invalid_remote_config_url" },
		{ { remote_config_url = "" }, "invalid_remote_config_url" },
		{ { remote_config_url = "https://config.example.com/path" }, "invalid_remote_config_url" },
		{ { remote_config_url = "https://config.example.com?x" }, "invalid_remote_config_url" },
		{ { remote_config_url = "http://example.com" }, "invalid_remote_config_url" },
	}
	for _, entry in ipairs(invalid_cases) do
		local client, err = sdk.new(config(entry[1]))
		assert_equal(client, nil, entry[2])
		assert_equal(err, entry[2])
	end

	-- Remote config authenticates with the publishable api_key only, so a
	-- Mode B config that enables it must also carry the key...
	-- (Overriding with nil through config() is a no-op in Lua, so absent
	-- fields are removed explicitly.)
	local mode_b_only = config({
		token_provider = function(callback)
			callback("client-token-placeholder", nil, nil)
		end,
	})
	mode_b_only.api_key = nil
	local client, err = sdk.new(mode_b_only)
	assert_equal(client, nil)
	assert_equal(err, "remote_config_api_key_required")

	-- ...and that is the ONE configuration where both credentials are valid
	-- together. Without remote config, both-set stays rejected.
	client, err = sdk.new(config({
		token_provider = function(callback)
			callback("client-token-placeholder", nil, nil)
		end,
	}))
	assert_true(client, err)
	local both_without_rc = config({
		token_provider = function(callback)
			callback("client-token-placeholder", nil, nil)
		end,
	})
	both_without_rc.remote_config_url = nil
	client, err = sdk.new(both_without_rc)
	assert_equal(client, nil)
	assert_equal(err, "auth_mode_conflict")

	-- Mode A with remote config is the plain single-credential shape.
	client, err = sdk.new(config())
	assert_true(client, err)
end

local function test_mode_b_with_remote_config_splits_credentials()
	reset()
	-- Consent-first: the event publish below only flows under a persisted
	-- grant (the fetch itself is not consent-gated).
	storage.save({ workspace_id = "workspace-test", app_id = "app-test" }, { consent_analytics = "granted" })
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			callback("minted-ingest-token", nil, nil)
		end,
	})))

	-- The ingest publish keeps the minted token as its Bearer...
	next_status = 202
	next_response_body = '{"accepted":1}'
	assert_true(client:track("boot"))
	client:flush({ include_summaries = false })
	local publish = last_request()
	assert_equal(publish.method, "POST")
	assert_equal(publish.headers["Authorization"], "Bearer minted-ingest-token",
		"the ingest Bearer must stay the minted token when both credentials are set")

	-- ...and the remote-config fetch uses the publishable key.
	next_status = 200
	next_response_body = values_body({ flag_x = true })
	local result = fetch(client)
	assert_true(result.ok, result.error)
	local request = last_request()
	assert_equal(request.method, "GET")
	assert_equal(request.headers["Authorization"], "Bearer sp_ingest_publishable_key",
		"the remote-config Bearer must be the publishable api_key, never the ingest token")
end

-- ── fetch outcomes ────────────────────────────────────────────────────────────

local function test_fresh_fetch_serves_values_and_writes_cache()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ flag_x = true, limit = 5 }, 3)
	next_response_headers = { etag = '"rcfg-3-abc"' }

	local result = fetch(client)

	assert_true(result.ok, result.error)
	assert_equal(result.from_cache, false)
	assert_nil(result.error)
	assert_equal(result.values.flag_x, true)
	assert_equal(result.values.limit, 5)
	assert_equal(result.version, 3)

	local request = last_request()
	assert_equal(request.method, "GET")
	assert_equal(request.url, "http://localhost:18081/config/v1/workspace-test/develop/anon-client")
	assert_equal(request.headers["Authorization"], "Bearer sp_ingest_publishable_key")
	assert_nil(request.headers["If-None-Match"], "the first fetch must not revalidate")
	-- The schema-revision declaration (GAP-036) belongs to events:batch
	-- ingest only; the remote-config fetch must never carry it.
	assert_nil(request.headers["X-ShardPilot-Schema-Revision"],
		"the remote-config fetch must not carry the schema-revision header")
	assert_nil(request.body, "a config fetch carries no request body")
	assert_equal(request.options.timeout, 2)

	-- The getter snapshot serves the fetched values...
	assert_equal(client:remote_config_boolean("flag_x", false), true)
	assert_equal(client:remote_config_number("limit", 0), 5)
	assert_equal(client:remote_config_version(), 3)

	-- ...and the cache record was persisted for this exact scope.
	local record = storage.load_remote_config(client.config)
	assert_true(record ~= nil, "the fetch must persist a cache record")
	assert_equal(record.etag, '"rcfg-3-abc"')
	assert_equal(record.scope,
		remote_config.build_scope("workspace-test", "develop", "anon-client", "http://localhost:18081"))
end

local function test_revalidation_304_serves_cached_snapshot()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 }, 7)
	next_response_headers = { etag = '"v7"' }
	fetch(client)

	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	local result = fetch(client)

	assert_equal(last_request().headers["If-None-Match"], '"v7"',
		"a fetch with a cached snapshot must revalidate by ETag")
	assert_true(result.ok, result.error)
	assert_equal(result.from_cache, true)
	assert_nil(result.error)
	assert_equal(result.values.a, 1)
	assert_equal(result.version, 7)
end

local function test_transient_failure_serves_cache_with_error()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	fetch(client)

	local transient_cases = {
		{ 0, "http_0" },
		{ 408, "transient_408" },
		{ 429, "transient_429" },
		{ 503, "transient_503" },
	}
	for _, entry in ipairs(transient_cases) do
		next_status = entry[1]
		next_response_body = nil
		local result = fetch(client)
		assert_true(result.ok, "a transient failure with a cache must serve the snapshot")
		assert_equal(result.from_cache, true)
		assert_equal(result.error, entry[2])
		assert_equal(result.values.a, 1)
	end
end

local function test_transient_failure_without_cache_fails()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 0
	local result = fetch(client)

	assert_equal(result.ok, false)
	assert_equal(result.from_cache, false)
	assert_equal(result.error, "http_0")
	assert_nil(result.values)
	assert_nil(client:remote_config_values(), "no snapshot may appear out of a failed fetch")
end

local function test_timeout_408_is_transient()
	reset()
	local client = assert(sdk.new(config()))

	-- With no cache, a request timeout fails like any other transient...
	next_status = 408
	local result = fetch(client)
	assert_equal(result.ok, false)
	assert_equal(result.error, "transient_408")

	-- ...and with one it serves the last-known-good snapshot: a timed-out
	-- refresh is exactly the moment the cached configuration is needed, and
	-- retrying can plausibly fix it — it must not fail like a permanent 4xx.
	next_status = 200
	next_response_body = values_body({ a = 1 }, 1)
	fetch(client)
	next_status = 408
	next_response_body = nil
	result = fetch(client)
	assert_true(result.ok, "a request timeout with a cache must serve the snapshot")
	assert_equal(result.from_cache, true)
	assert_equal(result.error, "transient_408")
	assert_equal(result.values.a, 1)
end

local function test_unauthorized_fails_closed_and_never_serves_cache()
	reset()
	for _, status in ipairs({ 401, 403 }) do
		storage.reset()
		local client = assert(sdk.new(config()))
		next_status = 200
		next_response_body = values_body({ a = 1 })
		fetch(client)

		next_status = status
		next_response_body = nil
		local result = fetch(client)

		assert_equal(result.ok, false, "an unauthorized fetch must fail closed")
		assert_equal(result.from_cache, false)
		assert_equal(result.error, "unauthorized")
		assert_nil(result.values, "a revoked or wrong key must not keep serving cached config")

		-- The cache FILE is untouched — only the fetch outcome fails closed:
		-- the earlier snapshot still backs the getters, and a later
		-- authorized fetch can revalidate against the kept ETag.
		assert_true(storage.load_remote_config(client.config) ~= nil,
			"an unauthorized response must not delete the cache record")
		assert_equal(client:remote_config_number("a", 0), 1,
			"the getter snapshot keeps the last served values")
	end
end

local function test_malformed_response_serves_cache_or_fails()
	reset()
	local client = assert(sdk.new(config()))

	-- With no cache, a 200 whose body is not a JSON object fails...
	for _, body in ipairs({ "not json", "[1,2]", "[]", "" }) do
		next_status = 200
		next_response_body = body
		local result = fetch(client)
		assert_equal(result.ok, false, "a malformed body with no cache must fail")
		assert_equal(result.error, "malformed_response")
	end

	-- ...and with a cache it degrades to the snapshot, like any transient —
	-- including `[]`, which decodes to the same Lua table as an empty object
	-- and must not be accepted as a fresh empty configuration.
	next_status = 200
	next_response_body = values_body({ a = 2 })
	fetch(client)
	for _, body in ipairs({ "garbage", "[]" }) do
		next_status = 200
		next_response_body = body
		local result = fetch(client)
		assert_true(result.ok)
		assert_equal(result.from_cache, true)
		assert_equal(result.error, "malformed_response")
		assert_equal(result.values.a, 2,
			"a malformed body must not overwrite the last-known-good configuration")
	end
end

local function test_permanent_http_error_fails_without_serving_cache()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	fetch(client)

	-- A 404/410/other-4xx is authoritative, not transient: retrying cannot
	-- help, so stale values must not masquerade as a healthy `ok = true`.
	for _, status in ipairs({ 400, 404, 410 }) do
		next_status = status
		next_response_body = nil
		local result = fetch(client)
		assert_equal(result.ok, false, "a permanent HTTP error must fail the fetch")
		assert_equal(result.from_cache, false)
		assert_equal(result.error, "http_" .. tostring(status))
		assert_nil(result.values)
	end

	-- Like the unauthorized outcome, the record and the getter snapshot are
	-- left untouched, and a later healthy fetch revalidates as usual.
	assert_equal(client:remote_config_number("a", 0), 1)
	assert_true(storage.load_remote_config(client.config) ~= nil,
		"a permanent error must not delete the cache record")
	next_status = 304
	local revalidated = fetch(client)
	assert_true(revalidated.ok, revalidated.error)
	assert_equal(revalidated.from_cache, true)
	assert_equal(revalidated.values.a, 1)
end

local function test_out_of_order_responses_do_not_install_stale_config()
	reset()
	local client = assert(sdk.new(config()))

	-- Hold the http callbacks so two fetches are in flight at once and the
	-- responses can be delivered out of order.
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers }
		held[#held + 1] = callback
	end
	local results = {}
	client:fetch_remote_config(function(result)
		results.older = result
	end)
	client:fetch_remote_config(function(result)
		results.newer = result
	end)
	http.request = saved_request
	assert_equal(#held, 2)

	-- The NEWER request answers first...
	held[2](nil, nil, {
		status = 200,
		response = values_body({ v = 2 }, 2),
		headers = { etag = '"v2"' },
	})
	assert_equal(client:remote_config_number("v", 0), 2)

	-- ...then the older one completes late with an older body: its caller
	-- still receives that response, but nothing is installed over the newer
	-- configuration.
	held[1](nil, nil, {
		status = 200,
		response = values_body({ v = 1 }, 1),
		headers = { etag = '"v1"' },
	})
	assert_true(results.older.ok)
	assert_equal(results.older.values.v, 1, "the older fetch still reports its own response")
	assert_equal(client:remote_config_number("v", 0), 2,
		"an out-of-order response must not roll the snapshot back")
	assert_equal(client:remote_config_version(), 2)

	-- The kept cache is the newer one: the next fetch revalidates its ETag.
	next_status = 304
	next_response_body = nil
	local result = fetch(client)
	assert_equal(last_request().headers["If-None-Match"], '"v2"',
		"the stale response must not have overwritten the cache record")
	assert_true(result.ok, result.error)
	assert_equal(result.values.v, 2)
end

local function test_fail_closed_fences_older_inflight_success()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	fetch(client)

	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		held[#held + 1] = callback
	end
	local results = {}
	client:fetch_remote_config(function(result)
		results.older = result
	end)
	client:fetch_remote_config(function(result)
		results.newer = result
	end)
	http.request = saved_request

	-- The NEWER fetch fails closed first (a revoked key)...
	held[2](nil, nil, { status = 401 })
	assert_equal(results.newer.ok, false)
	assert_equal(results.newer.error, "unauthorized")

	-- ...so the older in-flight success must not install after it: the
	-- latest outcome for this configuration was "you may not read it".
	held[1](nil, nil, {
		status = 200,
		response = values_body({ a = 99 }, 9),
		headers = { etag = '"late"' },
	})
	assert_true(results.older.ok, "the older fetch still reports its own response")
	assert_equal(client:remote_config_number("a", 0), 1,
		"values must not sneak in after a newer fail-closed outcome")
	assert_equal(client:remote_config_version(), 1)
end

local function test_identity_rotation_drops_inflight_response()
	reset()
	local client = assert(sdk.new(config()))
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		held[#held + 1] = callback
	end
	local result = nil
	client:fetch_remote_config(function(value)
		result = value
	end)
	http.request = saved_request

	-- The identity rotates while the GET for the previous client id is in
	-- flight; that response is another client's rollout bucket.
	assert_true(client:set_anonymous_id("anon-other"))
	held[1](nil, nil, {
		status = 200,
		response = values_body({ bucket = "old" }),
		headers = { etag = '"old"' },
	})

	assert_true(result.ok, "the caller still receives the response it asked for")
	assert_nil(client:remote_config_values(),
		"a response for the previous identity must not be served after rotation")
	assert_nil(storage.load_remote_config(client.config),
		"a response for the previous identity must not be persisted after rotation")
end

local function test_transient_cache_hit_does_not_fence_inflight_fresh()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 }, 1)
	fetch(client)

	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		held[#held + 1] = callback
	end
	local results = {}
	client:fetch_remote_config(function(result)
		results.older = result
	end)
	client:fetch_remote_config(function(result)
		results.newer = result
	end)
	http.request = saved_request

	-- The NEWER fetch hits a transient error first and serves the cache;
	-- that fallback is not authoritative and must not fence anything.
	held[2](nil, nil, { status = 0 })
	assert_true(results.newer.ok)
	assert_equal(results.newer.from_cache, true)
	assert_equal(results.newer.values.a, 1)

	-- The OLDER fetch then lands a fresh 200: it must still install.
	held[1](nil, nil, {
		status = 200,
		response = values_body({ a = 7 }, 7),
		headers = { etag = '"v7"' },
	})
	assert_true(results.older.ok)
	assert_equal(client:remote_config_number("a", 0), 7,
		"a cache-served fallback must not block a fresh response still in flight")
	assert_equal(client:remote_config_version(), 7)
end

local function test_malformed_wrapped_values_member_is_rejected()
	reset()
	local client = assert(sdk.new(config()))

	-- With no cache, a wrapper whose `values` member is not a keyed object
	-- must fail rather than serve the wrapper itself as configuration.
	-- `[null,1]` is the decoder-hostile shape: a decoder that maps null to
	-- nil leaves index 1 empty, so only the body text can call it an array.
	for _, body in ipairs({
		'{"version":3,"values":"oops"}',
		'{"version":3,"values":42}',
		'{"version":3,"values":[1,2]}',
		'{"version":3,"values":[null,1]}',
	}) do
		next_status = 200
		next_response_body = body
		local result = fetch(client)
		assert_equal(result.ok, false, "a malformed wrapper must fail: " .. body)
		assert_equal(result.error, "malformed_response")
	end
	assert_nil(client:remote_config_value("version"),
		"wrapper fields must never surface as configuration values")

	-- ...and with a cache it degrades to the snapshot without overwriting it.
	next_status = 200
	next_response_body = values_body({ a = 2 }, 2)
	fetch(client)
	next_status = 200
	next_response_body = '{"version":9,"values":"oops"}'
	local result = fetch(client)
	assert_true(result.ok)
	assert_equal(result.from_cache, true)
	assert_equal(result.error, "malformed_response")
	assert_equal(result.values.a, 2)
	assert_equal(client:remote_config_version(), 2,
		"a malformed wrapper must not overwrite the last-known-good configuration")
end

local function test_null_values_member_is_malformed()
	reset()
	local client = assert(sdk.new(config()))

	-- With no cache, a wrapper whose `values` member is null must fail: the
	-- decoder maps null to nil, which looks like an absent member, and the
	-- unwrapped fallback would otherwise serve wrapper fields as config.
	next_status = 200
	next_response_body = '{"version":3,"values":null}'
	local result = fetch(client)
	assert_equal(result.ok, false)
	assert_equal(result.error, "malformed_response")
	assert_nil(client:remote_config_value("version"),
		"wrapper fields must never surface as configuration values")

	-- With a cache it degrades to the snapshot without overwriting it.
	next_response_body = values_body({ a = 2 }, 2)
	fetch(client)
	next_response_body = '{"version":9,"values":null}'
	result = fetch(client)
	assert_true(result.ok)
	assert_equal(result.from_cache, true)
	assert_equal(result.error, "malformed_response")
	assert_equal(client:remote_config_number("a", 0), 2)
end

local function test_stale_scope_response_does_not_fence_current_scope()
	reset()
	local client = assert(sdk.new(config()))
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		held[#held + 1] = callback
	end

	-- Fetch for the original identity, rotate away, fetch again, rotate
	-- back: two requests in flight, one per scope.
	local results = {}
	client:fetch_remote_config(function(result)
		results.original = result
	end)
	assert_true(client:set_anonymous_id("anon-other"))
	client:fetch_remote_config(function(result)
		results.other = result
	end)
	assert_true(client:set_anonymous_id("anon-client"))
	http.request = saved_request

	-- The stale-scope request fails closed AFTER the rotation back. It is
	-- void end-to-end: it must not settle the fence for the current scope.
	held[2](nil, nil, { status = 401 })
	assert_equal(results.other.ok, false)

	-- The current-scope response — an older sequence — must still install.
	held[1](nil, nil, {
		status = 200,
		response = values_body({ a = 3 }, 3),
		headers = { etag = '"v3"' },
	})
	assert_true(results.original.ok)
	assert_equal(client:remote_config_number("a", 0), 3,
		"a stale-scope outcome must not fence off the current scope's fetch")
	assert_equal(client:remote_config_version(), 3)
end

local function test_304_revalidation_fences_older_inflight_response()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ v = 2 }, 2)
	next_response_headers = { etag = '"v2"' }
	fetch(client)

	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		held[#held + 1] = callback
	end
	local results = {}
	client:fetch_remote_config(function(result)
		results.older = result
	end)
	client:fetch_remote_config(function(result)
		results.newer = result
	end)
	http.request = saved_request

	-- The NEWER fetch revalidates: the endpoint just confirmed the cached
	-- ETag as current...
	held[2](nil, nil, { status = 304 })
	assert_true(results.newer.ok)
	assert_equal(results.newer.from_cache, true)

	-- ...so an older in-flight 200 carrying a different body must not
	-- overwrite what was just confirmed.
	held[1](nil, nil, {
		status = 200,
		response = values_body({ v = 1 }, 1),
		headers = { etag = '"v1"' },
	})
	assert_equal(client:remote_config_number("v", 0), 2,
		"a stale 200 must not overwrite a configuration a newer 304 just confirmed")
	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	local revalidated = fetch(client)
	assert_true(revalidated.ok, revalidated.error)
	assert_equal(last_request().headers["If-None-Match"], '"v2"',
		"the cache record must still carry the confirmed ETag")
end

local function test_scope_fence_survives_rotation_cycle()
	reset()
	local client = assert(sdk.new(config()))
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		held[#held + 1] = callback
	end

	-- Two fetches in flight for the original identity; the newer installs.
	local results = {}
	client:fetch_remote_config(function(result)
		results.stale = result
	end)
	client:fetch_remote_config(function(result)
		results.fresh = result
	end)
	held[2](nil, nil, {
		status = 200,
		response = values_body({ v = 2 }, 2),
		headers = { etag = '"v2"' },
	})
	assert_equal(client:remote_config_number("v", 0), 2)

	-- Rotate away, settle something under the intermediate identity, and
	-- rotate back: the original scope's own fence must survive the cycle.
	assert_true(client:set_anonymous_id("anon-other"))
	client:fetch_remote_config(function() end)
	held[3](nil, nil, {
		status = 200,
		response = values_body({ bucket = "other" }),
		headers = { etag = '"other"' },
	})
	assert_true(client:set_anonymous_id("anon-client"))
	http.request = saved_request

	-- The stale original-scope response is still OLDER than the response
	-- already installed for that scope, so it stays dropped.
	held[1](nil, nil, {
		status = 200,
		response = values_body({ v = 1 }, 1),
		headers = { etag = '"v1"' },
	})
	assert_nil(client:remote_config_value("v"),
		"a scope's fence must survive a rotation away and back")
	assert_equal(client:remote_config_string("bucket", "?"), "other",
		"the last served configuration stays until a newer one installs")
end

local function test_newer_durable_record_from_sibling_client_is_preferred()
	reset()
	local first = assert(sdk.new(config()))
	local second = assert(sdk.new(config()))

	next_status = 200
	next_response_body = values_body({ v = 1 }, 1)
	next_response_headers = { etag = '"v1"' }
	fetch(first)
	assert_equal(first:remote_config_number("v", 0), 1)

	-- A sibling client for the same scope fetches and persists a newer
	-- configuration...
	next_response_body = values_body({ v = 2 }, 2)
	next_response_headers = { etag = '"v2"' }
	fetch(second)

	-- ...so the first client's next offline fetch serves the per-app
	-- FRESHEST record, not the older one it still holds in-process.
	next_status = 0
	next_response_body = nil
	next_response_headers = nil
	local offline = fetch(first)
	assert_true(offline.ok)
	assert_equal(offline.from_cache, true)
	assert_equal(offline.values.v, 2,
		"the freshest per-app record must win over an older in-process one")
	assert_equal(first:remote_config_number("v", 0), 2,
		"the adopted record must also reach the getters")
end

local function test_intermediate_scope_outcome_does_not_fence_original_scope()
	reset()
	local client = assert(sdk.new(config()))
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		held[#held + 1] = callback
	end

	-- Fetch for the original identity, rotate away and fetch again; the
	-- second response lands WHILE its scope is current, so it installs and
	-- raises the fence.
	local results = {}
	client:fetch_remote_config(function(result)
		results.original = result
	end)
	assert_true(client:set_anonymous_id("anon-other"))
	client:fetch_remote_config(function(result)
		results.other = result
	end)
	held[2](nil, nil, {
		status = 200,
		response = values_body({ bucket = "other" }, 2),
		headers = { etag = '"other"' },
	})
	assert_equal(client:remote_config_string("bucket", "?"), "other")

	-- Rotating back re-enters the original scope: the fence settled for the
	-- intermediate identity must not drop the original response.
	assert_true(client:set_anonymous_id("anon-client"))
	http.request = saved_request
	held[1](nil, nil, {
		status = 200,
		response = values_body({ bucket = "original" }, 1),
		headers = { etag = '"original"' },
	})
	assert_true(results.original.ok)
	assert_equal(client:remote_config_string("bucket", "?"), "original",
		"an outcome settled under an intermediate identity must not fence the scope rotated back to")
end

local function test_cache_discovered_at_fetch_time_is_adopted()
	reset()
	-- Two same-app clients exist before any configuration is cached...
	local writer = assert(sdk.new(config()))
	local reader = assert(sdk.new(config()))
	assert_nil(reader:remote_config_values())

	-- ...one fetches fresh and persists the record...
	next_status = 200
	next_response_body = values_body({ a = 5 }, 5)
	next_response_headers = { etag = '"v5"' }
	fetch(writer)

	-- ...and the other's next fetch discovers that record: the 304 serves
	-- it, and the getters must agree with what the callback just reported.
	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	local result = fetch(reader)
	assert_true(result.ok, result.error)
	assert_equal(result.from_cache, true)
	assert_equal(last_request().headers["If-None-Match"], '"v5"')
	assert_equal(reader:remote_config_number("a", 0), 5,
		"a cache discovered at fetch time must reach the getter snapshot")
	assert_equal(reader:remote_config_version(), 5)
end

local function test_304_revalidation_renews_the_records_freshness()
	reset()
	local restore = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ v = 1 }, 1)
	next_response_headers = { etag = '"v1"' }
	fetch(client)
	local before = storage.load_remote_config(client.config)

	-- A revalidation confirms the cached body as current NOW: the renewed
	-- stamp is persisted (best-effort), so restarts and same-app clients
	-- rank the record by its latest confirmation, not by its first fetch.
	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	local result = fetch(client)

	assert_true(result.ok, result.error)
	assert_equal(result.from_cache, true)
	local after = storage.load_remote_config(client.config)
	assert_equal(after.etag, '"v1"')
	assert_equal(after.body, before.body,
		"a revalidation renews the stamp; the body is unchanged")
	assert_true(after.fetched_at_ms > before.fetched_at_ms,
		"a 304 must renew the durable record's freshness stamp")

	restore()
end

local function test_delayed_304_does_not_restamp_over_a_newer_body()
	reset()
	local restore = install_fake_sys_storage()
	local first = assert(sdk.new(config()))
	local second = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ v = 1 }, 1)
	next_response_headers = { etag = '"v1"' }
	fetch(first)

	-- Hold a revalidation in flight on the first client...
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers }
		held[#held + 1] = callback
	end
	local result = nil
	first:fetch_remote_config(function(value)
		result = value
	end)
	http.request = saved_request
	assert_equal(last_request().headers["If-None-Match"], '"v1"')

	-- ...while a sibling client fetches and persists a DIFFERENT body...
	next_response_body = values_body({ v = 2 }, 2)
	next_response_headers = { etag = '"v2"' }
	fetch(second)

	-- ...and the held 304 then arrives late. It validated the OLD body at
	-- server handling time — possibly BEFORE the sibling's fetch was served
	-- — and delivery order cannot order the two. The revalidated values are
	-- still served to this fetch's caller, but the fresher different-body
	-- record keeps the durable slot: restamping the old body over it could
	-- roll the configuration back for restarts and siblings.
	held[1](nil, nil, { status = 304 })
	assert_true(result.ok, result.error)
	assert_equal(result.from_cache, true)
	assert_equal(result.values.v, 1, "the caller still receives its own fetch's outcome")
	local durable = storage.load_remote_config(first.config)
	assert_equal(durable.etag, '"v2"',
		"a delayed revalidation must not displace a fresher different-body record")
	local relaunched = assert(sdk.new(config()))
	assert_equal(relaunched:remote_config_number("v", 0), 2,
		"a restart keeps the freshest different-body configuration")

	restore()
end

local function test_failed_304_restamp_keeps_the_same_body_durable()
	reset()
	local restore = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ v = 1 }, 1)
	next_response_headers = { etag = '"v1"' }
	fetch(client)

	-- The disk still accepts a tiny tombstone write but refuses the record
	-- write, so the revalidation serves and renews the stamp in memory only.
	-- The durable record carries the SAME body the endpoint just confirmed —
	-- only its stamp is stale — so it must survive: trading the confirmed
	-- body for a tombstone would be worse.
	local fake_save = sys.save
	sys.save = function(path, record)
		if record ~= nil and record.body ~= nil then
			return false
		end
		return fake_save(path, record)
	end
	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	local result = fetch(client)
	sys.save = fake_save

	assert_true(result.ok, result.error)
	assert_equal(result.from_cache, true)
	assert_true(storage.load_remote_config(client.config) ~= nil,
		"a failed restamp must not delete the record whose body was just confirmed")
	local relaunched = assert(sdk.new(config()))
	assert_equal(relaunched:remote_config_number("v", 0), 1)

	restore()
end

local function test_failed_304_restamp_clears_a_lingering_stale_body()
	reset()
	local restore = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ v = 1 }, 1)
	next_response_headers = { etag = '"v1"' }
	fetch(client)

	-- The disk dies entirely: a fresh configuration is served but neither
	-- persists nor clears the older durable record, which lingers.
	local fake_save = sys.save
	sys.save = function()
		return false
	end
	next_response_body = values_body({ v = 2 }, 2)
	next_response_headers = { etag = '"v2"' }
	fetch(client)

	-- The disk now accepts the tiny tombstone write but still refuses the
	-- record write; a revalidation confirms the SECOND body as current. The
	-- lingering record carries a DIFFERENT, no-fresher body than the one
	-- just confirmed: a restart would revive it over the confirmed
	-- configuration, so it must be cleared.
	sys.save = function(path, record)
		if record ~= nil and record.body ~= nil then
			return false
		end
		return fake_save(path, record)
	end
	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	local result = fetch(client)
	sys.save = fake_save

	assert_true(result.ok, result.error)
	assert_equal(result.from_cache, true)
	assert_nil(storage.load_remote_config(client.config),
		"a lingering stale body must not survive the revalidation that outdated it")
	local relaunched = assert(sdk.new(config()))
	assert_nil(relaunched:remote_config_values(),
		"a restart starts from the game's defaults, not the rolled-back configuration")

	restore()
end

local function test_backward_clock_jump_cannot_rank_fresh_config_below_stale()
	reset()
	local restore = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ v = 1 }, 1)
	next_response_headers = { etag = '"v1"' }
	fetch(client)

	-- The wall clock jumps backward (an NTP correction, a user time change)
	-- and the disk dies, so the fresher configuration can neither carry a
	-- naturally newer stamp nor displace the durable record.
	socket.now = socket.now - 600
	local saved_save = sys.save
	sys.save = function()
		return false
	end
	next_response_body = values_body({ v = 2 }, 2)
	next_response_headers = { etag = '"v2"' }
	local fresh = fetch(client)
	assert_true(fresh.ok, fresh.error)
	assert_equal(client:remote_config_number("v", 0), 2)

	-- Offline now: the fallback must be the configuration just served — its
	-- stamp was raised above the records it superseded — not the older
	-- durable record the clock jump left with a higher wall-clock stamp.
	next_status = 0
	next_response_body = nil
	next_response_headers = nil
	local offline = fetch(client)
	sys.save = saved_save
	restore()

	assert_true(offline.ok)
	assert_equal(offline.from_cache, true)
	assert_equal(offline.values.v, 2,
		"a backward clock jump must not rank the fresh configuration below the stale one")
end

local function test_failed_write_tombstone_spares_a_fresher_sibling_record()
	reset()
	local restore = install_fake_sys_storage()
	local first = assert(sdk.new(config()))
	local second = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ v = 1 }, 1)
	next_response_headers = { etag = '"v1"' }
	fetch(first)

	-- Hold a fetch in flight on the first client...
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		held[#held + 1] = callback
	end
	local result = nil
	first:fetch_remote_config(function(value)
		result = value
	end)
	http.request = saved_request

	-- ...while a sibling client persists a FRESHER configuration...
	next_response_body = values_body({ v = 2 }, 2)
	next_response_headers = { etag = '"v2"' }
	fetch(second)

	-- ...and the held fetch then lands fresh values too large for the
	-- save-file budget: served, but they cannot persist.
	held[1](nil, nil, {
		status = 200,
		response = values_body({ v = 3, blob = string.rep("x", 400000) }, 3),
		headers = { etag = '"v3"' },
	})
	assert_true(result.ok, result.error)
	assert_equal(first:remote_config_number("v", 0), 3,
		"the served configuration still backs the getters in this process")

	-- The tombstone must spare the sibling's record: it is FRESHER than the
	-- record this fetch captured, and clearing it would lose the freshest
	-- successfully persisted configuration.
	local durable = storage.load_remote_config(first.config)
	assert_true(durable ~= nil, "the sibling's fresher record must survive the failed write")
	assert_equal(durable.etag, '"v2"')
	local relaunched = assert(sdk.new(config()))
	assert_equal(relaunched:remote_config_number("v", 0), 2,
		"a restart falls back to the freshest persisted record, not to defaults")

	restore()
end

local function test_empty_array_values_member_is_malformed()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 2 }, 2)
	fetch(client)

	-- `{"values":[]}` decodes to the same Lua table as `{"values":{}}`; the
	-- body text disambiguates, and the array form must not overwrite the
	-- last-known-good configuration with an empty one.
	next_status = 200
	next_response_body = '{"version":9,"values":[]}'
	local result = fetch(client)
	assert_true(result.ok)
	assert_equal(result.from_cache, true)
	assert_equal(result.error, "malformed_response")
	assert_equal(client:remote_config_number("a", 0), 2)

	-- A string value spelled "values" must not decoy the scan.
	next_response_body = '{"a":"values","values":[]}'
	result = fetch(client)
	assert_equal(result.error, "malformed_response")
	assert_equal(client:remote_config_number("a", 0), 2)

	-- The empty OBJECT form is a legitimate (cleared) configuration...
	next_response_body = '{"version":9,"values":{}}'
	result = fetch(client)
	assert_true(result.ok, result.error)
	assert_equal(result.from_cache, false)
	assert_nil(result.error)
	assert_equal(client:remote_config_number("a", 42), 42)
	assert_equal(client:remote_config_version(), 9)

	-- ...and a nested key named "values" inside the map is ordinary data,
	-- untouched by the top-level scan.
	next_response_body = '{"version":10,"values":{"ui":{"values":[1,2]}}}'
	result = fetch(client)
	assert_true(result.ok, result.error)
	local ui = client:remote_config_value("ui")
	assert_equal(ui.values[1], 1)
	assert_equal(client:remote_config_version(), 10)
end

local function test_fetch_after_shutdown_is_rejected()
	reset()
	next_status = 200
	next_response_body = values_body({ a = 1 })
	local client = assert(sdk.new(config()))
	fetch(client)

	next_status = 202
	next_response_body = '{"accepted":0}'
	assert_true(client:shutdown("test_teardown"))

	-- Like every other network-producing call on a torn-down client.
	local result = nil
	local requests_before = #requests
	local ok, err = client:fetch_remote_config(function(value)
		result = value
	end)
	assert_equal(ok, false)
	assert_equal(err, "shutdown")
	assert_equal(result.error, "shutdown")
	assert_equal(#requests, requests_before, "no request may be dispatched after shutdown")

	-- The read-only getters stay usable, like snapshot().
	assert_equal(client:remote_config_number("a", 0), 1)
end

local function test_callback_mutation_cannot_corrupt_the_snapshot()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ limit = 5 })
	local seen = nil
	client:fetch_remote_config(function(result)
		-- Game code may normalize or strip the result it was handed...
		result.values.limit = 99
		result.values.injected = true
		seen = result
	end)
	assert_equal(seen.values.limit, 99)

	-- ...without corrupting what later getters read.
	assert_equal(client:remote_config_number("limit", 0), 5,
		"a callback mutation must not reach the getter snapshot")
	assert_nil(client:remote_config_value("injected"))
end

local function test_unwrapped_payload_is_served_as_the_map()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = '{"flag_x":true,"limit":5}'
	local result = fetch(client)

	assert_true(result.ok, result.error)
	assert_equal(result.values.flag_x, true)
	assert_nil(result.version, "an unwrapped payload carries no version")
	assert_equal(client:remote_config_number("limit", 0), 5)
end

local function test_unwrapped_version_key_is_configuration_not_metadata()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = '{"version":42,"flag_x":true}'
	local result = fetch(client)

	-- The published version is metadata of the `{version, values}` wrapper;
	-- in an unwrapped payload a config key named "version" is ordinary
	-- configuration and must not masquerade as a revision marker.
	assert_true(result.ok, result.error)
	assert_nil(result.version,
		"an unwrapped payload's version key must not be read as wrapper metadata")
	assert_nil(client:remote_config_version())
	assert_equal(client:remote_config_number("version", 0), 42,
		"an unwrapped config key named version is served as configuration")
	assert_equal(client:remote_config_boolean("flag_x", false), true)
end

-- ── cache scope ───────────────────────────────────────────────────────────────

local function test_cache_from_another_scope_is_a_miss_and_gets_overwritten()
	reset()
	local restore, stores = install_fake_sys_storage()

	local original = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	next_response_headers = { etag = '"scope-a"' }
	fetch(original)

	-- Another environment must not read this scope's cache: no snapshot at
	-- construction, no ETag on its fetch.
	local other = assert(sdk.new(config({ environment_id = "production" })))
	assert_nil(other:remote_config_values(), "another scope must not serve this cache")
	next_status = 200
	next_response_body = values_body({ b = 2 })
	next_response_headers = { etag = '"scope-b"' }
	local result = fetch(other)
	assert_nil(last_request().headers["If-None-Match"],
		"a different scope must not revalidate with the previous scope's ETag")
	assert_true(result.ok, result.error)
	assert_equal(result.from_cache, false)

	-- The successful fetch overwrote the record with the new scope, so the
	-- original scope now misses it.
	local reborn = assert(sdk.new(config()))
	assert_nil(reborn:remote_config_values(),
		"the original scope must miss the overwritten cache")

	restore()
end

local function test_transient_failure_never_serves_another_scopes_cache()
	reset()
	local restore = install_fake_sys_storage()

	local original = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	fetch(original)

	local other = assert(sdk.new(config({ environment_id = "production" })))
	next_status = 0
	next_response_body = nil
	local result = fetch(other)

	assert_equal(result.ok, false, "the other scope has no usable cache, so the fetch must fail")
	assert_nil(result.values)

	restore()
end

local function test_restart_serves_last_known_good_and_offline_fetch_uses_it()
	reset()
	local restore = install_fake_sys_storage()

	local first_launch = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ spawn_rate = 2.5 }, 4)
	next_response_headers = { etag = '"v4"' }
	fetch(first_launch)

	-- "Restart": a new client for the same scope serves the persisted
	-- snapshot immediately, before any fetch...
	local second_launch = assert(sdk.new(config()))
	assert_equal(second_launch:remote_config_number("spawn_rate", 1.0), 2.5,
		"the cached snapshot must survive a restart")
	assert_equal(second_launch:remote_config_version(), 4)

	-- ...and an offline fetch degrades to that snapshot.
	next_status = 0
	next_response_body = nil
	next_response_headers = nil
	local result = fetch(second_launch)
	assert_true(result.ok)
	assert_equal(result.from_cache, true)
	assert_equal(result.error, "http_0")
	assert_equal(result.values.spawn_rate, 2.5)

	restore()
end

local function test_corrupt_cache_record_reads_as_a_miss()
	reset()
	local restore, stores = install_fake_sys_storage()

	-- Prime a valid record to learn its path, then corrupt it in place.
	local seed = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	fetch(seed)
	local record_path = nil
	for path in pairs(stores) do
		if path:find("remote-config", 1, true) then
			assert_nil(record_path, "the cache record must live in its own save file")
			record_path = path
		end
	end
	assert_true(record_path ~= nil)

	-- A record missing its required fields is a miss...
	storage.reset()
	stores[record_path] = { body = "" }
	local client = assert(sdk.new(config()))
	assert_nil(client:remote_config_values(), "a corrupt record must read as a miss")
	next_status = 0
	local result = fetch(client)
	assert_equal(result.ok, false, "a corrupt record must not be served offline")

	-- ...and so is a well-shaped record whose body no longer decodes: it
	-- must not contribute an If-None-Match either, or the 304 it provokes
	-- would have no body to recover from.
	storage.reset()
	stores[record_path] = {
		scope = remote_config.build_scope(
			"workspace-test", "develop", "anon-client", "http://localhost:18081"),
		etag = '"stale-etag"',
		body = "garbage",
		fetched_at_ms = 1,
	}
	local reborn = assert(sdk.new(config()))
	assert_nil(reborn:remote_config_values(), "an undecodable record must read as a miss")
	next_status = 200
	next_response_body = values_body({ b = 2 })
	local refreshed = fetch(reborn)
	assert_nil(last_request().headers["If-None-Match"],
		"an undecodable record must not contribute its ETag")
	assert_true(refreshed.ok, refreshed.error)
	assert_equal(refreshed.from_cache, false)

	restore()
end

local function test_failed_cache_write_keeps_the_freshest_fallback()
	reset()
	local restore = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ v = 1 }, 1)
	next_response_headers = { etag = '"v1"' }
	fetch(client)

	-- The disk dies; a newer configuration is served but cannot persist.
	local saved_save = sys.save
	sys.save = function()
		return false
	end
	next_response_body = values_body({ v = 2 }, 2)
	next_response_headers = { etag = '"v2"' }
	local fresh = fetch(client)
	assert_true(fresh.ok, fresh.error)
	assert_equal(fresh.from_cache, false)

	-- Offline now: the fallback must be the FRESHEST served configuration —
	-- the in-process record — not the older record still on disk.
	next_status = 0
	next_response_body = nil
	next_response_headers = nil
	local offline = fetch(client)
	sys.save = saved_save
	restore()

	assert_true(offline.ok)
	assert_equal(offline.from_cache, true)
	assert_equal(offline.values.v, 2,
		"a failed cache write must not revive the older on-disk configuration")
	assert_equal(offline.version, 2)
end

local function test_unpersistable_fresh_config_clears_stale_durable_record()
	reset()
	local restore = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ v = 1 }, 1)
	fetch(client)

	-- A fresh configuration too large for the save-file budget is served but
	-- cannot persist; the OLDER durable record must not survive it, or a
	-- restart would revive rolled-back values.
	next_response_body = values_body({ v = 2, blob = string.rep("x", 400000) }, 2)
	local fresh = fetch(client)
	assert_true(fresh.ok, fresh.error)
	assert_equal(fresh.from_cache, false)
	assert_equal(client:remote_config_number("v", 0), 2)
	assert_nil(storage.load_remote_config(client.config),
		"the stale durable record must be cleared when the overwrite cannot land")

	-- Same process: the freshest configuration is still the offline fallback.
	next_status = 0
	next_response_body = nil
	local offline = fetch(client)
	assert_true(offline.ok)
	assert_equal(offline.values.v, 2)

	-- After a restart there is nothing to revive: getters serve defaults (an
	-- honest miss) rather than the rolled-back configuration.
	local relaunched = assert(sdk.new(config()))
	assert_nil(relaunched:remote_config_values())

	restore()
end

local function test_anonymous_id_rotation_moves_the_scope()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	next_response_headers = { etag = '"anon-1"' }
	fetch(client)

	-- Rotating the identity re-scopes the NEXT fetch: new client id in the
	-- URL, and the old identity's cache is a scope miss (no revalidation).
	assert_true(client:set_anonymous_id("anon-other"))
	next_response_headers = nil
	fetch(client)
	local request = last_request()
	assert_equal(request.url, "http://localhost:18081/config/v1/workspace-test/develop/anon-other")
	assert_nil(request.headers["If-None-Match"],
		"the previous identity's ETag must not ride a rotated fetch")
end

-- ── typed getters ─────────────────────────────────────────────────────────────

local function test_typed_getters_serve_defaults_on_miss_and_type_mismatch()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({
		title = "hello",
		limit = 5,
		enabled = true,
		disabled = false,
		tuning = { depth = 2 },
	})
	fetch(client)

	assert_equal(client:remote_config_string("title", "fallback"), "hello")
	assert_equal(client:remote_config_number("limit", 0), 5)
	assert_equal(client:remote_config_boolean("enabled", false), true)
	assert_equal(client:remote_config_boolean("disabled", true), false,
		"a stored false must be served, not collapsed into the default")

	-- Missing keys and type mismatches both serve the default.
	assert_equal(client:remote_config_string("absent", "fallback"), "fallback")
	assert_equal(client:remote_config_string("limit", "fallback"), "fallback")
	assert_equal(client:remote_config_number("title", 7), 7)
	assert_equal(client:remote_config_boolean("title", true), true)
	assert_nil(client:remote_config_value("absent"))

	-- Table values come out as copies: mutating one must not corrupt what a
	-- later getter serves.
	local tuning = client:remote_config_value("tuning")
	assert_equal(tuning.depth, 2)
	tuning.depth = 99
	assert_equal(client:remote_config_value("tuning").depth, 2)

	local all = client:remote_config_values()
	assert_equal(all.limit, 5)
	all.limit = 99
	assert_equal(client:remote_config_values().limit, 5)
end

local function test_getters_without_remote_config_serve_defaults()
	reset()
	local no_remote_config = config()
	no_remote_config.remote_config_url = nil
	local client = assert(sdk.new(no_remote_config))
	assert_equal(client:remote_config_string("title", "fallback"), "fallback")
	assert_equal(client:remote_config_number("limit", 7), 7)
	assert_equal(client:remote_config_boolean("enabled", true), true)
	assert_nil(client:remote_config_value("anything"))
	assert_nil(client:remote_config_values())
	assert_nil(client:remote_config_version())

	local result = nil
	local ok, err = client:fetch_remote_config(function(value)
		result = value
	end)
	assert_equal(ok, false)
	assert_equal(err, "remote_config_not_configured")
	assert_equal(result.error, "remote_config_not_configured")
end

-- ── consent posture ───────────────────────────────────────────────────────────

local function test_denied_consent_does_not_gate_the_fetch()
	reset()
	next_status = 202
	next_response_body = '{"accepted":1}'
	local client = assert(sdk.new(config()))
	client:set_consent(false)

	-- Configuration delivery carries no analytics payload, so a denied
	-- analytics consent does not block it (consistent across our SDKs).
	next_status = 200
	next_response_body = values_body({ a = 1 })
	local result = fetch(client)
	assert_true(result.ok, result.error)
	assert_equal(result.values.a, 1)
end

-- ── degraded runtimes ─────────────────────────────────────────────────────────

local function test_missing_transport_serves_cache_and_reports()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	fetch(client)

	local saved_http = http
	http = nil
	local result = nil
	local dispatched, dispatch_err = client:fetch_remote_config(function(value)
		result = value
	end)
	http = saved_http

	assert_equal(dispatched, false)
	assert_equal(dispatch_err, "http_unavailable",
		"the non-dispatch reason must also come back to the caller")
	assert_true(result.ok, "no transport degrades to the cached snapshot")
	assert_equal(result.from_cache, true)
	assert_equal(result.error, "http_unavailable")
	assert_equal(result.values.a, 1)
end

local function test_missing_json_decoder_fails_the_fetch()
	reset()
	local client = assert(sdk.new(config()))
	local saved_json = json
	json = nil
	local result = nil
	local dispatched, dispatch_err = client:fetch_remote_config(function(value)
		result = value
	end)
	json = saved_json

	assert_equal(dispatched, false)
	assert_equal(dispatch_err, "json_unavailable")
	assert_equal(result.ok, false)
	assert_equal(result.error, "json_unavailable")
end

local function test_cache_persist_failure_is_best_effort_and_diagnosed()
	reset()
	local restore = install_fake_sys_storage()
	local saved_save = sys.save
	sys.save = function()
		return false
	end

	local issues = {}
	local client = assert(sdk.new(config({
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	local result = fetch(client)

	sys.save = saved_save
	restore()

	assert_true(result.ok, "a failed cache write must not fail the fetch")
	assert_equal(result.values.a, 1)
	local diagnosed = false
	for _, issue in ipairs(issues) do
		if issue.scope == "remote_config" and issue.status == "cache_persist_failed" then
			diagnosed = true
		end
	end
	assert_true(diagnosed, "the lost offline copy must be surfaced through diagnostics")
end

-- ── opt-in periodic revalidation (GAP-017 wave; default OFF) ──────────────────

local function count_requests()
	return #requests
end

local function test_cache_control_max_age_directive_boundary()
	reset()
	local function max_age(header)
		return remote_config.cache_max_age_seconds({ headers = { ["cache-control"] = header } })
	end
	assert_equal(max_age("max-age=120"), 120)
	assert_equal(max_age("private, max-age=300"), 300)
	assert_equal(max_age("Private, MAX-AGE=90"), 90, "directive names are case-insensitive")
	assert_equal(max_age(" max-age = 45 "), 45)
	assert_equal(max_age("s-maxage=3600, max-age=60"), 60,
		"the shared-cache directive must never win over the client max-age")
	assert_equal(max_age("max-age=60, s-maxage=3600"), 60)
	assert_nil(max_age("s-maxage=3600"), "a shared-cache directive alone anchors nothing")
	assert_nil(max_age("smax-age=3600"), "a lookalike directive name must not match")
	assert_nil(max_age("x-max-age=3600"))
	assert_nil(max_age("private"))
	assert_nil(remote_config.cache_max_age_seconds({ headers = {} }))
	assert_nil(remote_config.cache_max_age_seconds({}))

	-- Timer integration for the exact shared-cache header: the interval
	-- anchors on the client max-age (60), never on s-maxage (3600).
	local client = assert(sdk.new(config({ remote_config_revalidate = true })))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	next_response_headers = { etag = 'W/"v1"', ["cache-control"] = "s-maxage=3600, max-age=60" }
	assert_true(fetch(client).ok)
	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	client:update(59)
	assert_equal(count_requests(), 1)
	client:update(2)
	assert_equal(count_requests(), 2,
		"the client max-age (60), not s-maxage (3600), anchors the revalidation interval")
end

local function test_revalidation_config_validation()
	reset()
	local client, err = sdk.new(config({ remote_config_revalidate = "yes" }))
	assert_nil(client)
	assert_equal(err, "invalid_remote_config_revalidate")

	local plain = config()
	plain.remote_config_url = nil
	plain.remote_config_revalidate = true
	client, err = sdk.new(plain)
	assert_nil(client)
	assert_equal(err, "remote_config_revalidate_requires_url")

	-- An explicit false is the default spelled out: valid without a URL.
	plain.remote_config_revalidate = false
	assert_true(sdk.new(plain) ~= nil)
end

local function test_revalidation_defaults_off()
	reset()
	-- The knob unset pins today's stance: the SDK never fetches on its own,
	-- however stale the cache and however small the server's max-age.
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	next_response_headers = { etag = 'W/"v1"', ["cache-control"] = "private, max-age=5" }
	assert_true(fetch(client).ok)
	assert_equal(count_requests(), 1)
	client:update(9999)
	client:update(9999)
	client:update(9999)
	assert_equal(count_requests(), 1, "without the opt-in, update() must never fetch configuration")
end

local function test_revalidation_fires_conditional_get_on_the_max_age_interval()
	reset()
	local client = assert(sdk.new(config({ remote_config_revalidate = true })))
	next_status = 200
	next_response_body = values_body({ a = 1 }, 1)
	next_response_headers = { etag = 'W/"v1"', ["cache-control"] = "private, max-age=120" }
	assert_true(fetch(client).ok)
	assert_equal(count_requests(), 1)

	-- Below the interval (the server's max-age) the timer stays quiet.
	client:update(119)
	assert_equal(count_requests(), 1)

	-- Crossing it issues exactly ONE conditional GET: the cached ETag rides
	-- as If-None-Match, and a 304 keeps serving the cached snapshot. The
	-- 304 keeps advertising the same window (a usable outcome WITHOUT one
	-- would restore the default interval — tested separately).
	next_status = 304
	next_response_body = nil
	next_response_headers = { ["cache-control"] = "private, max-age=120" }
	client:update(1.5)
	assert_equal(count_requests(), 2)
	local request = last_request()
	assert_equal(request.method, "GET")
	assert_equal(request.headers["If-None-Match"], 'W/"v1"')
	assert_equal(client:remote_config_number("a", 0), 1)

	-- The accumulator reset on fire: the next tick needs a full interval
	-- again (no burst, no extra retry inside an interval).
	client:update(60)
	assert_equal(count_requests(), 2)
	client:update(61)
	assert_equal(count_requests(), 3)
end

local function test_revalidation_interval_floor_and_default()
	reset()
	-- A max-age below the floor is raised to 60s (the per-scope server rate
	-- limiter must not be revalidated into).
	local client = assert(sdk.new(config({ remote_config_revalidate = true })))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	next_response_headers = { etag = 'W/"v1"', ["cache-control"] = "private, max-age=30" }
	assert_true(fetch(client).ok)
	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	client:update(59)
	assert_equal(count_requests(), 1, "a 30s max-age must be floored to 60s")
	client:update(2)
	assert_equal(count_requests(), 2)

	-- With no max-age observed the interval defaults to 300s.
	reset()
	client = assert(sdk.new(config({ remote_config_revalidate = true })))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	next_response_headers = { etag = 'W/"v1"' }
	assert_true(fetch(client).ok)
	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	client:update(299)
	assert_equal(count_requests(), 1, "without a max-age the interval defaults to 300s")
	client:update(2)
	assert_equal(count_requests(), 2)
end

local function test_revalidation_rearms_on_shorter_max_age()
	reset()
	local client = assert(sdk.new(config({ remote_config_revalidate = true })))
	-- Armed long: no max-age observed yet, so the 300s default governs and
	-- most of it has already accumulated.
	next_status = 200
	next_response_body = values_body({ a = 1 })
	next_response_headers = { etag = 'W/"v1"' }
	assert_true(fetch(client).ok)
	client:update(250)
	assert_equal(count_requests(), 1, "the default interval has not elapsed yet")

	-- A host fetch observes a SHORTER max-age. The stale long deadline must
	-- not fire first: the timer re-arms from the observing fetch, so the
	-- next revalidation lands about one NEW interval (60s) after it.
	next_response_headers = { etag = 'W/"v1"', ["cache-control"] = "max-age=60" }
	assert_true(fetch(client).ok)
	assert_equal(count_requests(), 2)
	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	client:update(59)
	assert_equal(count_requests(), 2, "the shortened window re-arms from the observing fetch")
	client:update(2)
	assert_equal(count_requests(), 3, "the next revalidation lands about one new interval later")
end

local function test_revalidation_ignores_error_response_cadence()
	reset()
	local client = assert(sdk.new(config({ remote_config_revalidate = true })))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	next_response_headers = { etag = 'W/"v1"', ["cache-control"] = "max-age=60" }
	assert_true(fetch(client).ok)
	client:update(30)
	assert_equal(count_requests(), 1)

	-- A FAILED host fetch mid-window — even one whose error response
	-- carries a Cache-Control — must neither re-arm the timer nor stretch
	-- the interval: only a usable outcome (fresh 200 / 304) moves the
	-- cadence.
	next_status = 500
	next_response_body = nil
	next_response_headers = { ["cache-control"] = "max-age=3600" }
	local failed = fetch(client)
	assert_true(failed.from_cache, "the 500 serves the cache, as ever")
	assert_equal(count_requests(), 2)

	next_status = 304
	next_response_body = nil
	next_response_headers = { ["cache-control"] = "max-age=60" }
	client:update(31)
	assert_equal(count_requests(), 3,
		"the timer fires on the original anchor: the failed fetch moved nothing")

	-- And the interval is still the last USABLE max-age (60), not the
	-- error response's 3600.
	client:update(59)
	assert_equal(count_requests(), 3)
	client:update(2)
	assert_equal(count_requests(), 4,
		"an error response's Cache-Control must never stretch the interval")
end

local function test_stale_auth_refusal_does_not_halt_the_timer()
	reset()
	local client = assert(sdk.new(config({ remote_config_revalidate = true })))

	-- Two host fetches in flight; the NEWER settles first with a usable
	-- 200, then the DELAYED 401 from the older fetch arrives.
	local saved_request = http.request
	local pending = {}
	http.request = function(url, method, callback, headers, body, options)
		pending[#pending + 1] = callback
	end
	client:fetch_remote_config(function() end)
	client:fetch_remote_config(function() end)
	pending[2](nil, nil, { status = 200, response = values_body({ a = 1 }),
		headers = { etag = 'W/"v1"', ["cache-control"] = "max-age=60" } })
	pending[1](nil, nil, { status = 401 })
	http.request = saved_request

	assert_equal(client.remote_config.auth_refused, false,
		"a stale refusal outranked by a newer settled outcome must not halt the timer")
	assert_equal(client:remote_config_number("a", 0), 1)

	-- The timer keeps running on the settled outcome's cadence.
	next_status = 304
	next_response_body = nil
	next_response_headers = { ["cache-control"] = "max-age=60" }
	client:update(61)
	assert_equal(count_requests(), 1, "the timer must still fire after the stale refusal")

	-- A refusal that SETTLES the fence still halts.
	next_status = 401
	next_response_body = nil
	client:update(61)
	assert_equal(count_requests(), 2)
	assert_equal(client.remote_config.auth_refused, true)
	client:update(200)
	assert_equal(count_requests(), 2)
end

local function test_revalidation_restores_default_when_max_age_disappears()
	reset()
	local client = assert(sdk.new(config({ remote_config_revalidate = true })))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	next_response_headers = { etag = 'W/"v1"', ["cache-control"] = "max-age=60" }
	assert_true(fetch(client).ok)

	-- The anchored 60s window governs the first tick...
	next_status = 304
	next_response_body = nil
	next_response_headers = nil
	client:update(61)
	assert_equal(count_requests(), 2)

	-- ...but that usable 304 carried NO Cache-Control: the server stopped
	-- advertising a freshness window, so the anchor restores the 300s
	-- default instead of keeping the stale prior value.
	client:update(61)
	assert_equal(count_requests(), 2, "the stale 60s anchor must not survive a headerless success")
	client:update(239)
	assert_equal(count_requests(), 3, "the default interval governs once the header disappears")
end

local function test_revalidation_transient_failure_keeps_the_schedule()
	reset()
	local client = assert(sdk.new(config({ remote_config_revalidate = true })))
	next_status = 200
	next_response_body = values_body({ a = 1 })
	next_response_headers = { etag = 'W/"v1"', ["cache-control"] = "max-age=60" }
	assert_true(fetch(client).ok)

	-- A transient failure on a tick serves the cache internally and keeps
	-- the schedule: the next interval revalidates again, no tighter.
	next_status = 500
	next_response_body = nil
	next_response_headers = nil
	client:update(61)
	assert_equal(count_requests(), 2)
	client:update(30)
	assert_equal(count_requests(), 2, "no extra retry inside an interval")
	client:update(31)
	assert_equal(count_requests(), 3)
	assert_equal(client:remote_config_number("a", 0), 1, "the snapshot keeps serving through transients")
end

local function test_revalidation_halts_after_auth_refusal_manual_fetch_unaffected()
	reset()
	local client = assert(sdk.new(config({ remote_config_revalidate = true })))
	next_status = 200
	next_response_body = values_body({ a = 1 }, 1)
	next_response_headers = { etag = 'W/"v1"', ["cache-control"] = "max-age=60" }
	assert_true(fetch(client).ok)

	-- An authoritative 401 on a tick halts the TIMER (an unattended loop
	-- must not keep re-asking an endpoint that authoritatively refused it) —
	-- while classification stays per fetch: no latch, getters keep serving.
	next_status = 401
	next_response_body = nil
	next_response_headers = nil
	client:update(61)
	assert_equal(count_requests(), 2)
	assert_equal(client.remote_config.auth_refused, true)
	assert_equal(client:remote_config_number("a", 0), 1, "a 401 must not clear the getter snapshot")
	client:update(200)
	client:update(200)
	assert_equal(count_requests(), 2, "the halted timer must stop scheduling fetches")

	-- Manual fetches stay available and classify per fetch...
	next_status = 200
	next_response_body = values_body({ a = 2 }, 2)
	next_response_headers = { etag = 'W/"v2"' }
	local result = fetch(client)
	assert_true(result.ok, "a manual fetch must still dispatch after the halt")
	assert_equal(result.from_cache, false)
	assert_equal(client:remote_config_number("a", 0), 2)
	assert_equal(count_requests(), 3)

	-- ...and a manual success does NOT auto-resume the timer: only re-init
	-- (a new client) does.
	client:update(200)
	assert_equal(count_requests(), 3, "a manual success must not reopen the halted timer")
	local second = assert(sdk.new(config({ remote_config_revalidate = true })))
	assert_equal(second.remote_config.auth_refused, false, "re-init reopens the timer")
end

-- ── singleton facade ──────────────────────────────────────────────────────────

local function test_facade_serves_defaults_when_not_initialized()
	reset()
	assert_equal(sdk.remote_config_string("title", "fallback"), "fallback")
	assert_equal(sdk.remote_config_number("limit", 7), 7)
	assert_equal(sdk.remote_config_boolean("enabled", true), true)
	assert_nil(sdk.remote_config_value("anything"))
	assert_nil(sdk.remote_config_values())
	assert_nil(sdk.remote_config_version())

	local result = nil
	local ok, err = sdk.fetch_remote_config(function(value)
		result = value
	end)
	assert_equal(ok, false)
	assert_equal(err, "not_initialized")
	assert_equal(result.error, "not_initialized")
end

local function test_facade_delegates_to_the_default_client()
	reset()
	assert_true(sdk.init(config()))
	next_status = 200
	next_response_body = values_body({ flag_x = true }, 2)

	local result = nil
	sdk.fetch_remote_config(function(value)
		result = value
	end)
	assert_true(result.ok, result.error)
	assert_equal(sdk.remote_config_boolean("flag_x", false), true)
	assert_equal(sdk.remote_config_version(), 2)

	next_status = 202
	next_response_body = '{"accepted":1}'
	sdk.shutdown("test_teardown")
end

local tests = {
	test_build_url_joins_and_escapes_segments,
	test_build_scope_keeps_distinct_tuples_distinct,
	test_config_validation,
	test_mode_b_with_remote_config_splits_credentials,
	test_fresh_fetch_serves_values_and_writes_cache,
	test_revalidation_304_serves_cached_snapshot,
	test_transient_failure_serves_cache_with_error,
	test_transient_failure_without_cache_fails,
	test_timeout_408_is_transient,
	test_unauthorized_fails_closed_and_never_serves_cache,
	test_malformed_response_serves_cache_or_fails,
	test_permanent_http_error_fails_without_serving_cache,
	test_out_of_order_responses_do_not_install_stale_config,
	test_fail_closed_fences_older_inflight_success,
	test_identity_rotation_drops_inflight_response,
	test_transient_cache_hit_does_not_fence_inflight_fresh,
	test_malformed_wrapped_values_member_is_rejected,
	test_null_values_member_is_malformed,
	test_stale_scope_response_does_not_fence_current_scope,
	test_304_revalidation_fences_older_inflight_response,
	test_scope_fence_survives_rotation_cycle,
	test_newer_durable_record_from_sibling_client_is_preferred,
	test_intermediate_scope_outcome_does_not_fence_original_scope,
	test_cache_discovered_at_fetch_time_is_adopted,
	test_304_revalidation_renews_the_records_freshness,
	test_delayed_304_does_not_restamp_over_a_newer_body,
	test_failed_304_restamp_keeps_the_same_body_durable,
	test_failed_304_restamp_clears_a_lingering_stale_body,
	test_backward_clock_jump_cannot_rank_fresh_config_below_stale,
	test_failed_write_tombstone_spares_a_fresher_sibling_record,
	test_empty_array_values_member_is_malformed,
	test_fetch_after_shutdown_is_rejected,
	test_callback_mutation_cannot_corrupt_the_snapshot,
	test_unwrapped_payload_is_served_as_the_map,
	test_unwrapped_version_key_is_configuration_not_metadata,
	test_cache_from_another_scope_is_a_miss_and_gets_overwritten,
	test_transient_failure_never_serves_another_scopes_cache,
	test_restart_serves_last_known_good_and_offline_fetch_uses_it,
	test_corrupt_cache_record_reads_as_a_miss,
	test_failed_cache_write_keeps_the_freshest_fallback,
	test_unpersistable_fresh_config_clears_stale_durable_record,
	test_anonymous_id_rotation_moves_the_scope,
	test_typed_getters_serve_defaults_on_miss_and_type_mismatch,
	test_getters_without_remote_config_serve_defaults,
	test_denied_consent_does_not_gate_the_fetch,
	test_missing_transport_serves_cache_and_reports,
	test_missing_json_decoder_fails_the_fetch,
	test_cache_persist_failure_is_best_effort_and_diagnosed,
	test_cache_control_max_age_directive_boundary,
	test_revalidation_config_validation,
	test_revalidation_defaults_off,
	test_revalidation_fires_conditional_get_on_the_max_age_interval,
	test_revalidation_interval_floor_and_default,
	test_revalidation_rearms_on_shorter_max_age,
	test_revalidation_ignores_error_response_cadence,
	test_stale_auth_refusal_does_not_halt_the_timer,
	test_revalidation_restores_default_when_max_age_disappears,
	test_revalidation_transient_failure_keeps_the_schedule,
	test_revalidation_halts_after_auth_refusal_manual_fetch_unaffected,
	test_facade_serves_defaults_when_not_initialized,
	test_facade_delegates_to_the_default_client,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold remote-config tests passed")
