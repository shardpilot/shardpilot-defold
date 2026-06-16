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
local sampling = require "shardpilot.sampling"
local platform = require "shardpilot.platform"

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
		{ { ingest_url = "https:///" }, "invalid_ingest_url" },
		{ { ingest_url = "https://?x" }, "invalid_ingest_url" },
		{ { ingest_url = "https://#fragment" }, "invalid_ingest_url" },
		{ { ingest_url = "https://ingest.example.com/path" }, "invalid_ingest_url" },
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
	client, err = sdk.new(config({ ingest_url = "http://example.com" }))
	assert_equal(client, nil)
	assert_equal(err, "invalid_ingest_url")

	client, err = sdk.new(config({ ingest_url = "https://ingest.example.com" }))
	assert_true(client, err)
	client, err = sdk.new(config({ ingest_url = "http://localhost:8080" }))
	assert_true(client, err)
	client, err = sdk.new(config({ ingest_url = "http://127.0.0.1:8080" }))
	assert_true(client, err)
	client, err = sdk.new(config({ ingest_url = "http://[::1]:8080" }))
	assert_true(client, err)

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

local function test_screen_view_does_not_mutate_caller_props()
	reset()
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	local props = { origin = "menu" }
	assert_true(client:screen_view("settings", props))
	assert_equal(props.screen_name, nil)
	assert_equal(props.origin, "menu")
end

local function test_platform_maps_html5_to_web()
	local original_get_sys_info = sys.get_sys_info
	sys.get_sys_info = function()
		return { system_name = "html5" }
	end
	assert_equal(platform.detect(), "web")
	sys.get_sys_info = original_get_sys_info
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

local function test_session_start_rolls_back_on_enqueue_failure()
	reset()
	local client = assert(sdk.new(config({ buffer_size = 1 })))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())
	local previous_session_id = client.session_id
	local previous_sequence = client.session_sequence
	local previous_active = client.session_active

	local ok, err = client:session_start()
	assert_equal(ok, false)
	assert_equal(err, "queue_full")
	assert_equal(client.session_id, previous_session_id)
	assert_equal(client.session_sequence, previous_sequence)
	assert_equal(client.session_active, previous_active)
end

local function test_session_start_rolls_back_on_invalid_props()
	reset()
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())
	assert_true(client:flush())
	local previous_session_id = client.session_id
	local previous_sequence = client.session_sequence
	local previous_active = client.session_active
	local cyclic = {}
	cyclic.self = cyclic

	local ok, err = client:session_start(cyclic)
	assert_equal(ok, false)
	assert_equal(err, "invalid_props")
	assert_equal(client.session_id, previous_session_id)
	assert_equal(client.session_sequence, previous_sequence)
	assert_equal(client.session_active, previous_active)
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
	local props = { surface = "before", loadout = { weapon = "sword" } }
	local context = { screen = "menu", nested = { zone = "lobby" } }
	assert_true(client:track("first_event", props, context))
	local event_ts = client.queue.items[1].event_ts
	props.surface = "after"
	props.loadout.weapon = "axe"
	context.screen = "gameplay"
	context.nested.zone = "arena"
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
	assert_contains(body, '"weapon":"sword"')
	assert_contains(body, '"screen":"menu"')
	assert_contains(body, '"zone":"lobby"')
	assert_not_contains(body, '"surface":"after"')
	assert_not_contains(body, '"weapon":"axe"')
	assert_not_contains(body, '"screen":"gameplay"')
	assert_not_contains(body, '"zone":"arena"')
	assert_ordered_contains(body, '"event_name":"first_event"', '"session_sequence":1')
	assert_ordered_contains(body, '"event_name":"second_event"', '"session_sequence":2')
	assert_ordered_contains(body, '"event_name":"third_event"', '"session_sequence":3')
end

local function test_track_rejects_cyclic_or_too_deep_snapshots()
	reset()
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	local cyclic = {}
	cyclic.self = cyclic
	local ok, err = client:track("cyclic_props", cyclic)
	assert_equal(ok, false)
	assert_equal(err, "invalid_props")

	local deep = { a = { b = { c = { d = { e = "too-deep" } } } } }
	ok, err = client:track("deep_props", deep)
	assert_equal(ok, false)
	assert_equal(err, "invalid_props")

	local context_cycle = {}
	context_cycle.self = context_cycle
	ok, err = client:track("cyclic_context", nil, context_cycle)
	assert_equal(ok, false)
	assert_equal(err, "invalid_context")
end

local function test_bounded_queue_drop()
	reset()
	local client = assert(sdk.new(config({ buffer_size = 1 })))
	assert_true(client:identify("user-example"))
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

	ok, err = client:track("needs_identity")
	assert_equal(ok, false)
	assert_equal(err, "identity_required")
	assert_equal(#client.queue.items, 0)
	assert_equal(#requests, 0)
	assert_equal(client:snapshot().last_error, "identity_required")

	assert_true(client:identify("user-example"))
	assert_true(client:flush())
	assert_equal(#requests, 0)

	assert_true(client:track("after_identity"))
	assert_true(client:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"event_name":"after_identity"')
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

local function test_token_provider_rejects_non_numeric_expiry()
	reset()
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			callback("client-token-placeholder", "not-a-number", nil)
		end,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:track("invalid_expiry_token_event"))

	assert_equal(client:flush(), false)
	assert_equal(client.token, nil)
	assert_equal(client.token_expires_at_ms, nil)
	assert_equal(client.token_request_in_flight, false)
	assert_equal(client:snapshot().last_error, "token_unavailable")
	assert_equal(#requests, 0)
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

local function test_perf_and_ping_samples_are_bounded()
	reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())
	for _ = 1, sampling.max_perf_samples + 50 do
		client:update(0.016)
		client:observe_ping_ms(42)
	end
	if #client.perf.frames > sampling.max_perf_samples then
		error("perf samples exceeded cap", 2)
	end
	if #client.network.pings > sampling.max_ping_samples then
		error("ping samples exceeded cap", 2)
	end
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

local function test_session_end_queue_full_keeps_session_active()
	reset()
	local client = assert(sdk.new(config({ buffer_size = 1 })))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())
	local session_id = client.session_id

	local ok, err = client:session_end("queue_full")
	assert_equal(ok, false)
	assert_equal(err, "queue_full")
	assert_equal(client.session_active, true)
	assert_equal(client.session_id, session_id)
end

local function test_shutdown_queue_full_does_not_finalize_and_can_retry()
	reset()
	local client = assert(sdk.new(config({ buffer_size = 1 })))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())

	local ok, err = client:shutdown("app_final")
	assert_equal(ok, false)
	assert_equal(err, "queue_full")
	assert_equal(client.initialized, true)
	assert_equal(client.session_active, true)

	assert_true(client:flush())
	assert_true(client:shutdown("app_final"))
	assert_equal(client.initialized, false)
end

local function test_flush_and_shutdown_wait_for_async_publish()
	reset()
	local original_request = http.request
	local callbacks = {}
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = {
			url = url,
			method = method,
			headers = headers,
			body = body,
			options = options,
		}
		callbacks[#callbacks + 1] = callback
	end

	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())
	local ok, err = client:flush()
	assert_equal(ok, false)
	assert_equal(err, "pending")
	assert_equal(client.publish_in_flight, true)
	assert_equal(#callbacks, 1)

	assert_true(client:track("queued_while_publish_pending"))
	ok, err = client:shutdown("app_final")
	assert_equal(ok, false)
	assert_equal(err, "pending")
	assert_equal(client.initialized, true)
	assert_equal(#client.queue.items, 2)
	assert_contains(client.queue.items[2].event_name, "session_end")

	callbacks[1](nil, nil, { status = 202, response = '{"accepted":1}' })
	assert_equal(client.publish_in_flight, false)

	ok, err = client:flush()
	assert_equal(ok, false)
	assert_equal(err, "pending")
	assert_equal(#callbacks, 2)
	callbacks[2](nil, nil, { status = 202, response = '{"accepted":2}' })

	assert_true(client:shutdown("app_final"))
	assert_equal(client.initialized, false)
	http.request = original_request
end

local function test_singleton_shutdown_keeps_client_after_retryable_failure()
	reset()
	next_status = 500
	local ok, err = sdk.init(config())
	assert_true(ok, err)
	assert_true(sdk.identify("user-example"))
	assert_true(sdk.session_start())
	ok, err = sdk.shutdown("app_final")
	assert_equal(ok, false)
	local snapshot, snapshot_err = sdk.snapshot()
	assert_true(type(snapshot) == "table", snapshot_err)

	next_status = 202
	assert_true(sdk.shutdown("app_final"))
	local missing, missing_err = sdk.snapshot()
	assert_equal(missing, false)
	assert_equal(missing_err, "not_initialized")
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

local function test_client_source_omits_anonymous_id()
	reset()
	-- config() defaults source="client": the client-JWT trust tier rejects a
	-- non-empty anonymous_id (400 anonymous_id_not_allowed), so it must never
	-- reach the wire even when the host sets it.
	local client = assert(sdk.new(config()))
	assert_true(client:set_anonymous_id("anon-123"))
	assert_true(client:track("client_event"))
	assert_true(client:flush())
	assert_equal(#requests, 1)
	assert_not_contains(requests[1].body, '"anonymous_id"')
	assert_contains(requests[1].body, '"event_name":"client_event"')

	-- Non-client (service trust tier) sources keep anonymous_id on the wire.
	reset()
	local server_client = assert(sdk.new(config({ source = "server" })))
	assert_true(server_client:set_anonymous_id("anon-456"))
	assert_true(server_client:track("server_event"))
	assert_true(server_client:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"anonymous_id":"anon-456"')
end

local function test_track_before_session_start_lazily_opens_session()
	reset()
	-- The server requires session_id for non-backend sources. A track() before
	-- session_start() must still carry a synthesized session_id.
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	assert_true(client:track("early_event"))
	assert_not_equal(client.session_id, nil)
	assert_true(client:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"session_id":"session-')
	assert_contains(requests[1].body, '"session_sequence":1')

	-- Backend sources do not require a session and must not synthesize one.
	reset()
	local backend = assert(sdk.new(config({ source = "backend" })))
	assert_true(backend:identify("user-example"))
	assert_true(backend:track("backend_event"))
	assert_equal(backend.session_id, nil)
	assert_true(backend:flush())
	assert_equal(#requests, 1)
	assert_not_contains(requests[1].body, '"session_id"')
end

local tests = {
	test_config_validation,
	test_client_source_omits_anonymous_id,
	test_track_before_session_start_lazily_opens_session,
	test_singleton_guard,
	test_id_generator_seeds_without_caller,
	test_platform_maps_html5_to_web,
	test_app_first_payload,
	test_screen_view_does_not_mutate_caller_props,
	test_session_start_renews_session_and_resets_sequence,
	test_session_start_rolls_back_on_enqueue_failure,
	test_session_start_rolls_back_on_invalid_props,
	test_track_snapshots_identity_session_and_time,
	test_track_snapshots_timestamp_props_context_and_sequence_order,
	test_track_rejects_cyclic_or_too_deep_snapshots,
	test_bounded_queue_drop,
	test_token_provider_failure,
	test_identity_validation,
	test_async_token_provider_retains_queued_events,
	test_unauthorized_invalidates_token_and_retains_batch,
	test_retryable_failures_retain_batch,
	test_non_retryable_failure_drops_batch,
	test_token_expiry_refresh,
	test_token_provider_rejects_non_numeric_expiry,
	test_update_honors_flush_interval,
	test_perf_and_ping_samples_are_bounded,
	test_perf_and_network_summaries,
	test_shutdown_emits_session_end,
	test_session_end_queue_full_keeps_session_active,
	test_shutdown_queue_full_does_not_finalize_and_can_retry,
	test_flush_and_shutdown_wait_for_async_publish,
	test_singleton_shutdown_keeps_client_after_retryable_failure,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold lua tests passed")
