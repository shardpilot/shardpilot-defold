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
	-- must fail rather than serve the wrapper itself as configuration...
	for _, body in ipairs({
		'{"version":3,"values":"oops"}',
		'{"version":3,"values":42}',
		'{"version":3,"values":[1,2]}',
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
	local dispatched = client:fetch_remote_config(function(value)
		result = value
	end)
	http = saved_http

	assert_equal(dispatched, false)
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
	local dispatched = client:fetch_remote_config(function(value)
		result = value
	end)
	json = saved_json

	assert_equal(dispatched, false)
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
	test_unauthorized_fails_closed_and_never_serves_cache,
	test_malformed_response_serves_cache_or_fails,
	test_permanent_http_error_fails_without_serving_cache,
	test_out_of_order_responses_do_not_install_stale_config,
	test_fail_closed_fences_older_inflight_success,
	test_identity_rotation_drops_inflight_response,
	test_transient_cache_hit_does_not_fence_inflight_fresh,
	test_malformed_wrapped_values_member_is_rejected,
	test_cache_discovered_at_fetch_time_is_adopted,
	test_empty_array_values_member_is_malformed,
	test_fetch_after_shutdown_is_rejected,
	test_callback_mutation_cannot_corrupt_the_snapshot,
	test_unwrapped_payload_is_served_as_the_map,
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
	test_facade_serves_defaults_when_not_initialized,
	test_facade_delegates_to_the_default_client,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold remote-config tests passed")
