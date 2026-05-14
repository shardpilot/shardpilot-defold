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
local next_status = 202

http = {
	request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = {
			url = url,
			method = method,
			headers = headers,
			body = body,
			options = options,
		}
		callback(nil, nil, { status = next_status, response = '{"accepted":1}' })
	end,
}

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

json = {
	encode = encode_value,
}

local sdk = require "shardpilot.sdk"

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

local function assert_not_equal(actual, expected, message)
	if actual == expected then
		error((message or "values unexpectedly match") .. ": " .. tostring(actual), 2)
	end
end

local function assert_contains(haystack, needle)
	if not string.find(haystack, needle, 1, true) then
		error("expected to find " .. needle .. " in " .. haystack, 2)
	end
end

local function assert_not_contains(haystack, needle)
	if string.find(haystack, needle, 1, true) then
		error("did not expect to find " .. needle .. " in " .. haystack, 2)
	end
end

local function assert_ordered_contains(haystack, first, second)
	local first_index = string.find(haystack, first, 1, true)
	local second_index = string.find(haystack, second, 1, true)
	if not first_index or not second_index or second_index < first_index then
		error("expected to find " .. first .. " before " .. second .. " in " .. haystack, 2)
	end
end

local function assert_not_initialized(label, fn)
	local ok, err = fn()
	assert_equal(ok, false, label)
	assert_equal(err, "not_initialized", label)
end

local function config(overrides)
	local out = {
		ingest_url = "http://localhost:8080",
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		app_version = "0.1.0",
		app_build = "100",
		token_provider = function(callback)
			callback("client-token-placeholder", nil, nil)
		end,
		flush_interval_seconds = 1,
		publish_timeout_seconds = 2,
	}
	for key, value in pairs(overrides or {}) do
		out[key] = value
	end
	return out
end

local function reset()
	requests = {}
	next_status = 202
end

local function test_config_validation()
	local client, err = sdk.new({})
	assert_equal(client, nil)
	assert_equal(err, "ingest_url_required")

	local invalid_cases = {
		{ { ingest_url = 42 }, "invalid_ingest_url" },
		{ { workspace_id = 42 }, "invalid_workspace_id" },
		{ { app_id = false }, "invalid_app_id" },
		{ { environment_id = {} }, "invalid_environment_id" },
		{ { batch_size = 0 }, "invalid_batch_size" },
		{ { batch_size = -1 }, "invalid_batch_size" },
		{ { batch_size = 101 }, "invalid_batch_size" },
		{ { batch_size = 1.5 }, "invalid_batch_size" },
		{ { buffer_size = 0 }, "invalid_buffer_size" },
		{ { flush_interval_seconds = 0 }, "invalid_flush_interval_seconds" },
		{ { publish_timeout_seconds = -1 }, "invalid_publish_timeout_seconds" },
		{ { token_refresh_lead_ms = -1 }, "invalid_token_refresh_lead_ms" },
	}
	for _, entry in ipairs(invalid_cases) do
		client, err = sdk.new(config(entry[1]))
		assert_equal(client, nil, entry[2])
		assert_equal(err, entry[2])
	end

	client, err = sdk.new(config())
	assert_true(client, err)
	assert_equal(client.config.batch_size, 25)
	assert_equal(client.config.buffer_size, 200)
	assert_equal(client.config.platform, "linux")
	assert_equal(client.config.token_refresh_lead_ms, 60000)
end

local function test_app_first_payload()
	reset()
	local client = assert(sdk.new(config()))
	client:identify("user-example")
	client:session_start()
	client:screen_view("menu")
	client:track("play_cta_click", { cta_source = "main_menu" })
	assert_true(client:flush())

	assert_equal(#requests, 1)
	local request = requests[1]
	assert_equal(request.url, "http://localhost:8080/v1/events:batch")
	assert_equal(request.method, "POST")
	assert_equal(request.headers["Authorization"], "Bearer client-token-placeholder")
	assert_equal(request.options.timeout, 2)
	assert_contains(request.body, '"workspace_id":"workspace-example"')
	assert_contains(request.body, '"app_id":"app-example"')
	assert_contains(request.body, '"environment_id":"develop"')
	assert_contains(request.body, '"event_ts":')
	assert_contains(request.body, '"session_sequence":')
	assert_contains(request.body, '"app_version":"0.1.0"')
	assert_contains(request.body, '"app_build":"100"')
	assert_not_contains(request.body, '"project_id"')
	assert_not_contains(request.body, '"game_id"')
	assert_not_contains(request.body, '"env":')
	assert_not_contains(request.body, '"event_ts_server"')
	assert_not_contains(request.body, '"event_seq_session"')
	assert_not_contains(request.body, '"build_version"')
end

local function test_id_generator_seeds_without_caller()
	local id_mod = require "shardpilot.id"
	local first = id_mod.uuid()
	local second = id_mod.uuid()
	assert_equal(#first, 36)
	assert_equal(#second, 36)
	assert_not_equal(first, second)
end

local function test_session_start_renews_session_and_resets_sequence()
	reset()
	local client = assert(sdk.new(config()))
	client:identify("user-example")

	assert_true(client:session_start())
	local first_session_id = client.session_id
	assert_equal(client.session_sequence, 1)
	assert_true(client:flush())
	assert_contains(requests[1].body, '"event_name":"session_start"')
	assert_contains(requests[1].body, '"session_id":"' .. first_session_id .. '"')
	assert_contains(requests[1].body, '"session_sequence":1')

	assert_true(client:session_end("complete"))
	assert_true(client:flush())
	assert_contains(requests[2].body, '"event_name":"session_end"')
	assert_contains(requests[2].body, '"session_id":"' .. first_session_id .. '"')
	assert_contains(requests[2].body, '"session_sequence":2')

	assert_true(client:session_start())
	local second_session_id = client.session_id
	assert_not_equal(second_session_id, first_session_id)
	assert_equal(client.session_sequence, 1)
	assert_true(client:flush())
	assert_contains(requests[3].body, '"event_name":"session_start"')
	assert_contains(requests[3].body, '"session_id":"' .. second_session_id .. '"')
	assert_contains(requests[3].body, '"session_sequence":1')
end

local function test_track_snapshots_identity_session_and_time()
	reset()
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-a"))
	assert_true(client:session_start())
	local session_a = client.session_id
	assert_true(client:flush())
	reset()

	assert_true(client:track("snapshot_event"))
	local snapshot_sequence = client.session_sequence
	assert_true(client:identify("user-b"))
	assert_true(client:session_start())
	local session_b = client.session_id
	assert_not_equal(session_b, session_a)
	assert_true(client:flush())

	local body = requests[1].body
	assert_ordered_contains(body, '"event_name":"snapshot_event"', '"user_id":"user-a"')
	assert_ordered_contains(body, '"event_name":"snapshot_event"', '"session_id":"' .. session_a .. '"')
	assert_ordered_contains(body, '"event_name":"snapshot_event"', '"session_sequence":' .. tostring(snapshot_sequence))
	assert_contains(body, '"event_name":"session_start"')
	assert_contains(body, '"user_id":"user-b"')
	assert_contains(body, '"session_id":"' .. session_b .. '"')
end

local function test_track_snapshots_timestamp_props_context_and_sequence_order()
	reset()
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	local props = { surface = "before" }
	local context = { screen = "menu" }
	assert_true(client:track("first_event", props, context))
	local event_ts = client.queue.items[1].event_ts
	props.surface = "after"
	context.screen = "gameplay"
	socket.now = socket.now + 1000
	assert_true(client:track("second_event"))
	assert_true(client:track("third_event"))

	assert_equal(client.queue.items[1].session_sequence, 1)
	assert_equal(client.queue.items[2].session_sequence, 2)
	assert_equal(client.queue.items[3].session_sequence, 3)
	assert_true(client:flush())

	local body = requests[1].body
	assert_contains(body, '"event_ts":"' .. event_ts .. '"')
	assert_contains(body, '"surface":"before"')
	assert_contains(body, '"screen":"menu"')
	assert_not_contains(body, '"surface":"after"')
	assert_not_contains(body, '"screen":"gameplay"')
	assert_ordered_contains(body, '"event_name":"first_event"', '"session_sequence":1')
	assert_ordered_contains(body, '"event_name":"second_event"', '"session_sequence":2')
	assert_ordered_contains(body, '"event_name":"third_event"', '"session_sequence":3')
end

local function test_bounded_queue_drop()
	reset()
	local client = assert(sdk.new(config({ buffer_size = 1 })))
	local ok, err = client:track("one")
	assert_true(ok, err)
	ok, err = client:track("two")
	assert_equal(ok, false)
	assert_equal(err, "queue_full")
	assert_equal(client:snapshot().dropped, 1)
end

local function test_token_provider_failure()
	reset()
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			callback(nil, nil, "no token")
		end,
	})))
	client:identify("user-example")
	client:track("screen_view", { screen_name = "menu" })
	assert_equal(client:flush(), false)
	assert_equal(#requests, 0)
	assert_equal(client:snapshot().last_error, "token_unavailable")
end

local function test_identity_validation()
	reset()
	local client = assert(sdk.new(config()))
	local ok, err = client:identify("")
	assert_equal(ok, false)
	assert_equal(err, "invalid_user_id")
	ok, err = client:identify(42)
	assert_equal(ok, false)
	assert_equal(err, "invalid_user_id")
	ok, err = client:set_anonymous_id("")
	assert_equal(ok, false)
	assert_equal(err, "invalid_anonymous_id")
	ok, err = client:set_anonymous_id({})
	assert_equal(ok, false)
	assert_equal(err, "invalid_anonymous_id")

	assert_true(client:track("needs_identity"))
	assert_equal(client:flush(), false)
	assert_equal(#requests, 0)
	assert_equal(client:snapshot().last_error, "identity_required")

	assert_true(client:identify("user-example"))
	assert_true(client:flush())
	assert_equal(#requests, 1)
end

local function test_async_token_provider_retains_queued_events()
	reset()
	local token_callback = nil
	local token_requests = 0
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			token_requests = token_requests + 1
			token_callback = callback
		end,
	})))
	client:identify("user-example")
	assert_true(client:track("async_token_event"))

	assert_equal(client:flush(), false)
	assert_equal(token_requests, 1)
	assert_equal(client.token_request_in_flight, true)
	assert_equal(#client.queue.items, 1)
	assert_equal(#requests, 0)

	token_callback("async-token", nil, nil)
	assert_equal(client.token_request_in_flight, false)
	assert_equal(client.token, "async-token")

	assert_true(client:flush())
	assert_equal(#client.queue.items, 0)
	assert_equal(#requests, 1)
	assert_equal(requests[1].headers["Authorization"], "Bearer async-token")
	assert_contains(requests[1].body, '"event_name":"async_token_event"')
end

local function test_unauthorized_invalidates_token_and_retains_batch()
	reset()
	next_status = 401
	local client = assert(sdk.new(config()))
	client:identify("user-example")
	client:track("screen_view", { screen_name = "menu" })
	assert_equal(client:flush(), false)
	assert_equal(client.token, nil)
	assert_equal(client:snapshot().failed_batches, 1)
	assert_equal(#client.in_flight_batch, 1)
	local failed_body = requests[1].body

	next_status = 202
	assert_true(client:flush())
	assert_equal(client.in_flight_batch, nil)
	assert_equal(#requests, 2)
	assert_equal(requests[2].body, failed_body)
	assert_contains(requests[2].body, '"event_name":"screen_view"')
end

local function assert_retryable_status_retains_batch(status)
	reset()
	next_status = status
	local client = assert(sdk.new(config()))
	client:identify("user-example")
	assert_true(client:track("retryable_event"))

	assert_equal(client:flush(), false)
	assert_equal(#requests, 1)
	assert_equal(#client.queue.items, 0)
	assert_equal(#client.in_flight_batch, 1)
	assert_equal(client:snapshot().failed_batches, 1)
	local failed_body = requests[1].body

	next_status = 202
	assert_true(client:flush())
	assert_equal(client.in_flight_batch, nil)
	assert_equal(#requests, 2)
	assert_equal(requests[2].body, failed_body)
	assert_contains(requests[2].body, '"event_name":"retryable_event"')
end

local function test_retryable_failures_retain_batch()
	assert_retryable_status_retains_batch(500)
	assert_retryable_status_retains_batch(429)
	assert_retryable_status_retains_batch(0)
end

local function test_non_retryable_failure_drops_batch()
	reset()
	next_status = 400
	local client = assert(sdk.new(config()))
	client:identify("user-example")
	assert_true(client:track("validation_error_event"))

	assert_equal(client:flush(), false)
	assert_equal(client.in_flight_batch, nil)
	assert_equal(#client.queue.items, 0)
	assert_equal(client:snapshot().failed_batches, 1)
	assert_equal(client:snapshot().dropped, 1)

	next_status = 202
	assert_true(client:flush())
	assert_equal(#requests, 1)
end

local function test_token_expiry_refresh()
	reset()
	local token_calls = 0
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			token_calls = token_calls + 1
			callback("client-token-" .. tostring(token_calls), math.floor(socket.now * 1000) + 1000, nil)
		end,
	})))
	client:identify("user-example")
	client:track("first_event")
	assert_true(client:flush())
	client:track("second_event")
	assert_true(client:flush())
	assert_equal(token_calls, 2)
	assert_equal(requests[1].headers["Authorization"], "Bearer client-token-1")
	assert_equal(requests[2].headers["Authorization"], "Bearer client-token-2")
end

local function test_update_honors_flush_interval()
	reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 0.5 })))
	client:identify("user-example")
	assert_true(client:session_start())
	client:update(0.25)
	assert_equal(#requests, 0)
	client:update(0.25)
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"event_name":"session_start"')
	assert_not_contains(requests[1].body, '"event_name":"perf_summary"')
end

local function test_perf_and_network_summaries()
	reset()
	local client = assert(sdk.new(config({ transport = "websocket" })))
	client:identify("user-example")
	client:session_start()
	client:update(0.016)
	client:update(0.020)
	client:observe_ping_ms(42)
	client:observe_ping_ms(80)
	client:observe_disconnect("websocket_disconnected_with_extra_details")
	assert_true(client:flush())
	local body = requests[1].body
	assert_contains(body, '"event_name":"perf_summary"')
	assert_contains(body, '"avg_fps":')
	assert_contains(body, '"frames_sampled":2')
	assert_contains(body, '"event_name":"network_summary"')
	assert_contains(body, '"avg_ping_ms":61')
	assert_contains(body, '"disconnect_count":1')
	assert_contains(body, '"transport":"websocket"')
end

local function test_shutdown_emits_session_end()
	reset()
	local client = assert(sdk.new(config()))
	client:identify("user-example")
	client:session_start()
	assert_true(client:shutdown("app_final"))
	assert_contains(requests[1].body, '"event_name":"session_end"')
	assert_equal(client.initialized, false)
end

local function test_singleton_guard()
	reset()
	local calls = {
		{ "identify", function()
			return sdk.identify("user-example")
		end },
		{ "set_anonymous_id", function()
			return sdk.set_anonymous_id("anonymous-example")
		end },
		{ "session_start", function()
			return sdk.session_start()
		end },
		{ "screen_view", function()
			return sdk.screen_view("menu")
		end },
		{ "track", function()
			return sdk.track("event")
		end },
		{ "update", function()
			return sdk.update(0.016)
		end },
		{ "observe_ping_ms", function()
			return sdk.observe_ping_ms(42)
		end },
		{ "observe_disconnect", function()
			return sdk.observe_disconnect("offline")
		end },
		{ "flush", function()
			return sdk.flush()
		end },
		{ "shutdown", function()
			return sdk.shutdown("app_final")
		end },
		{ "snapshot", function()
			return sdk.snapshot()
		end },
	}
	for _, entry in ipairs(calls) do
		assert_not_initialized("pre-init " .. entry[1], entry[2])
	end

	local ok, err = sdk.init(config())
	assert_true(ok, err)
	assert_true(sdk.identify("user-example"))
	assert_true(sdk.track("singleton_event"))
	assert_true(sdk.shutdown("app_final"))

	for _, entry in ipairs(calls) do
		assert_not_initialized("post-shutdown " .. entry[1], entry[2])
	end
end

local tests = {
	test_config_validation,
	test_singleton_guard,
	test_id_generator_seeds_without_caller,
	test_app_first_payload,
	test_session_start_renews_session_and_resets_sequence,
	test_track_snapshots_identity_session_and_time,
	test_track_snapshots_timestamp_props_context_and_sequence_order,
	test_bounded_queue_drop,
	test_token_provider_failure,
	test_identity_validation,
	test_async_token_provider_retains_queued_events,
	test_unauthorized_invalidates_token_and_retains_batch,
	test_retryable_failures_retain_batch,
	test_non_retryable_failure_drops_batch,
	test_token_expiry_refresh,
	test_update_honors_flush_interval,
	test_perf_and_network_summaries,
	test_shutdown_emits_session_end,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold lua tests passed")
