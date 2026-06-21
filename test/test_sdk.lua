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
		local response = { status = next_status, response = next_response_body or '{"accepted":1}' }
		if next_response_headers then
			response.headers = next_response_headers
		end
		callback(nil, nil, response)
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

-- A minimal recursive-descent JSON decoder, sufficient for the server bodies
-- the SDK parses in tests (objects, arrays, strings, numbers, booleans, null).
-- Real Defold ships json.decode; the SDK uses it only when present.
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

	return parse_value()
end

json = {
	encode = encode_value,
	decode = json_decode,
}

local sdk = require "shardpilot.sdk"
local sampling = require "shardpilot.sampling"
local platform = require "shardpilot.platform"
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

-- A Mode A (publishable-key) config: no token_provider, an sp_ingest_ api_key
-- used directly as the Bearer. Starts from config() and strips token_provider.
local function config_mode_a(overrides)
	local out = config(overrides)
	out.token_provider = nil
	out.api_key = (overrides and overrides.api_key) or "sp_ingest_publishable_key"
	return out
end

local function reset()
	requests = {}
	next_status = 202
	next_response_body = nil
	next_response_headers = nil
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

	-- Dual-mode auth: exactly one of token_provider / api_key.
	-- Neither configured -> auth_required.
	local no_auth = config()
	no_auth.token_provider = nil
	client, err = sdk.new(no_auth)
	assert_equal(client, nil)
	assert_equal(err, "auth_required")

	-- Both configured -> auth_mode_conflict (the Bearer source is ambiguous).
	client, err = sdk.new(config({ api_key = "sp_ingest_publishable_key" }))
	assert_equal(client, nil)
	assert_equal(err, "auth_mode_conflict")

	-- An empty-string api_key with no token_provider is not a usable Bearer.
	local empty_key = config()
	empty_key.token_provider = nil
	empty_key.api_key = ""
	client, err = sdk.new(empty_key)
	assert_equal(client, nil)
	assert_equal(err, "auth_required")

	-- A non-string api_key is rejected before mode selection.
	local bad_key = config()
	bad_key.token_provider = nil
	bad_key.api_key = 42
	client, err = sdk.new(bad_key)
	assert_equal(client, nil)
	assert_equal(err, "invalid_api_key")

	-- A non-function token_provider is rejected.
	client, err = sdk.new(config({ token_provider = "not-a-function" }))
	assert_equal(client, nil)
	assert_equal(err, "invalid_token_provider")

	-- Mode A (api_key, no token_provider) is a VALID config.
	client, err = sdk.new(config_mode_a())
	assert_true(client, err)
	assert_equal(client.config.api_key, "sp_ingest_publishable_key")
	assert_equal(client.config.token_provider, nil)
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
	assert_contains(request.body, '"event_name":"app.session_started"')
	assert_contains(request.body, '"event_name":"app.screen_view"')
	assert_not_contains(request.body, '"event_name":"session_start"')
	assert_not_contains(request.body, '"event_name":"screen_view"')
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
	assert_contains(requests[1].body, '"event_name":"app.session_started"')
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
	assert_contains(requests[3].body, '"event_name":"app.session_started"')
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
	assert_contains(body, '"event_name":"app.session_started"')
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
	client:track("app.screen_view", { screen_name = "menu" })
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

	-- an anonymous ID is auto-provisioned, so events publish before identify
	assert_equal(type(client.anonymous_id), "string")
	assert_equal(#client.anonymous_id, 36)
	assert_true(client:track("before_identify"))
	assert_true(client:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"anonymous_id":"' .. client.anonymous_id .. '"')
	assert_not_contains(requests[1].body, '"user_id"')

	assert_true(client:identify("user-example"))
	assert_true(client:track("after_identity"))
	assert_true(client:flush())
	assert_equal(#requests, 2)
	assert_contains(requests[2].body, '"event_name":"after_identity"')
	assert_contains(requests[2].body, '"user_id":"user-example"')
end

local function test_anonymous_id_in_memory_round_trip()
	reset()
	storage.reset()
	local first = assert(sdk.new(config()))
	local anon = first.anonymous_id
	assert_equal(type(anon), "string")
	assert_equal(#anon, 36)
	assert_equal(anon:sub(15, 15), "7", "anonymous id must be a UUIDv7")

	-- sys storage is unavailable under plain lua, so the in-memory record
	-- must round-trip to the next client in the same process
	local second = assert(sdk.new(config()))
	assert_equal(second.anonymous_id, anon)

	storage.reset()
	local third = assert(sdk.new(config()))
	assert_not_equal(third.anonymous_id, anon)
	storage.reset()
end

local function test_configured_anonymous_id_overrides_and_persists()
	reset()
	storage.reset()
	local configured = assert(sdk.new(config({ anonymous_id = "anon-configured" })))
	assert_equal(configured.anonymous_id, "anon-configured")
	local follower = assert(sdk.new(config()))
	assert_equal(follower.anonymous_id, "anon-configured")
	storage.reset()
end

local function test_consent_tri_state_gating_and_queue_clear()
	reset()
	storage.reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_equal(client.consent_state, "unknown")
	assert_true(client:track("open_while_unknown"))
	assert_equal(#client.queue.items, 1)

	local ok, err = client:set_consent("yes")
	assert_equal(ok, false)
	assert_equal(err, "invalid_consent")
	assert_equal(client.consent_state, "unknown")

	assert_true(client:set_consent(false))
	assert_equal(client.consent_state, "denied")
	assert_equal(#client.queue.items, 0, "denied must clear the pending queue")
	assert_equal(client:snapshot().dropped, 1)
	assert_equal(#requests, 1)
	local consent_request = requests[1]
	assert_equal(consent_request.url, "http://localhost:8080/v1/consent")
	assert_equal(consent_request.method, "POST")
	assert_equal(consent_request.headers["Authorization"], "Bearer client-token-placeholder")
	assert_contains(consent_request.body, '"workspace_id":"workspace-example"')
	assert_contains(consent_request.body, '"app_id":"app-example"')
	assert_contains(consent_request.body, '"environment_id":"develop"')
	assert_contains(consent_request.body, '"actor_identifier":"user-example"')
	assert_contains(consent_request.body, '"categories":{"analytics":false}')
	assert_contains(consent_request.body, '"decided_at":"')
	assert_contains(consent_request.body, '"idempotency_key":"')
	assert_not_contains(consent_request.body, '"event_name"')

	ok, err = client:track("denied_event")
	assert_equal(ok, false)
	assert_equal(err, "consent_denied")
	assert_equal(client:snapshot().dropped, 2)
	assert_equal(#requests, 1)

	-- the denied decision persists for the next client
	local follower = assert(sdk.new(config()))
	assert_equal(follower.consent_state, "denied")
	ok, err = follower:track("denied_for_follower")
	assert_equal(ok, false)
	assert_equal(err, "consent_denied")

	assert_true(client:set_consent(true))
	assert_equal(client.consent_state, "granted")
	assert_equal(#requests, 2)
	assert_equal(requests[2].url, "http://localhost:8080/v1/consent")
	assert_contains(requests[2].body, '"categories":{"analytics":true}')
	assert_true(client:track("granted_event"))
	assert_true(client:flush())
	assert_equal(#requests, 3)
	assert_equal(requests[3].url, "http://localhost:8080/v1/events:batch")
	assert_contains(requests[3].body, '"event_name":"granted_event"')
	assert_equal(client:snapshot().consent_recorded, 2)

	-- the granted decision persists for the next client
	local granted_follower = assert(sdk.new(config()))
	assert_equal(granted_follower.consent_state, "granted")
	storage.reset()
end

local function test_consent_denied_clears_retained_batch()
	reset()
	storage.reset()
	next_status = 500
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	assert_true(client:track("retained_event"))
	assert_equal(client:flush(), false)
	assert_equal(#client.in_flight_batch, 1)

	next_status = 202
	assert_true(client:set_consent(false))
	assert_equal(client.in_flight_batch, nil)
	assert_equal(client:snapshot().dropped, 1)
	assert_true(client:flush())
	assert_equal(#requests, 2)
	assert_equal(requests[2].url, "http://localhost:8080/v1/consent")
	storage.reset()
end

local function test_consent_send_failure_is_quiet()
	reset()
	storage.reset()
	next_status = 500
	local client = assert(sdk.new(config()))
	assert_true(client:set_consent(true))
	assert_equal(client.consent_state, "granted")
	assert_equal(client:snapshot().consent_failed, 1)
	assert_equal(client:snapshot().last_consent_error, "transient_500")
	assert_contains(requests[1].body, '"actor_identifier":"' .. client.anonymous_id .. '"')
	next_status = 202
	storage.reset()
end

local function test_consent_denied_drops_in_flight_batch_on_retryable_failure()
	reset()
	storage.reset()
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
	assert_true(client:track("in_flight_event"))
	local ok, err = client:flush()
	assert_equal(ok, false)
	assert_equal(err, "pending")
	assert_equal(client.publish_in_flight, true)
	assert_equal(#callbacks, 1)

	-- consent is denied while the publish is still in flight; the batch
	-- cannot be aborted mid-flight, so it stays attached for now
	assert_true(client:set_consent(false))
	assert_true(client.in_flight_batch ~= nil)
	assert_equal(#callbacks, 2, "the consent decision dispatches immediately")
	assert_equal(requests[2].url, "http://localhost:8080/v1/consent")

	-- the in-flight publish completes with a retryable failure: the batch
	-- must be dropped at the completion callback, not retained for retry
	callbacks[1](nil, nil, { status = 500, response = "" })
	assert_equal(client.publish_in_flight, false)
	assert_equal(client.in_flight_batch, nil, "denied consent must drop the retryable batch")
	assert_equal(client:snapshot().dropped, 1)
	assert_equal(client:snapshot().failed_batches, 1)
	callbacks[2](nil, nil, { status = 202, response = "" })

	-- the next flush must not republish the dropped batch
	assert_true(client:flush())
	assert_equal(#requests, 2)
	http.request = original_request
	storage.reset()
end

local function test_consent_decision_defers_until_token_arrives()
	reset()
	storage.reset()
	local token_callback = nil
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			token_callback = callback
		end,
	})))
	assert_true(client:identify("user-example"))

	-- the decision is made before the async token provider has answered:
	-- it must be retained, not lost
	assert_true(client:set_consent(true))
	assert_equal(#requests, 0, "no consent request can go out before the token arrives")
	assert_true(client.pending_consent ~= nil, "the decision must be retained")
	assert_equal(client:snapshot().consent_failed, 1)
	assert_equal(client:snapshot().consent_recorded, 0)

	token_callback("deferred-token", nil, nil)
	assert_equal(client.token, "deferred-token")
	assert_true(client.pending_consent ~= nil, "still pending until the next dispatch point")

	-- the next dispatch point (the update-driven flush) transmits it
	-- without a second set_consent call
	client:update(client.config.flush_interval_seconds)
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_equal(requests[1].headers["Authorization"], "Bearer deferred-token")
	assert_contains(requests[1].body, '"categories":{"analytics":true}')
	assert_equal(client.pending_consent, nil)
	assert_equal(client:snapshot().consent_recorded, 1)
	storage.reset()
end

local function test_session_end_while_denied_completes_locally()
	reset()
	storage.reset()
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())
	assert_true(client:flush())
	assert_true(client:set_consent(false))
	assert_equal(client.session_active, true)

	-- the local session teardown must complete while denied; only the wire
	-- event is suppressed
	local ok, err = client:session_end("denied_end")
	assert_true(ok, err)
	assert_equal(client.session_active, false)
	for _, request in ipairs(requests) do
		assert_not_contains(request.body, '"event_name":"session_end"')
	end
	storage.reset()
end

local function test_consent_retained_after_unauthorized_and_resent_with_fresh_token()
	reset()
	storage.reset()
	local token_calls = 0
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			token_calls = token_calls + 1
			callback("token-" .. tostring(token_calls), nil, nil)
		end,
	})))
	assert_true(client:identify("user-example"))

	next_status = 401
	assert_true(client:set_consent(true))
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_equal(client.token, nil, "401 must clear the token")
	assert_true(client.pending_consent ~= nil, "an auth failure must not lose the decision")
	assert_equal(client:snapshot().consent_failed, 1)
	assert_equal(client:snapshot().last_consent_error, "unauthorized")

	-- the next dispatch point refreshes the token and retries the decision
	next_status = 202
	client:update(client.config.flush_interval_seconds)
	assert_equal(#requests, 2)
	assert_equal(requests[2].url, "http://localhost:8080/v1/consent")
	assert_equal(requests[2].headers["Authorization"], "Bearer token-2")
	assert_contains(requests[2].body, '"categories":{"analytics":true}')
	assert_equal(client.pending_consent, nil)
	assert_equal(client:snapshot().consent_recorded, 1)
	storage.reset()
end

local function test_lazy_session_rolls_back_on_enqueue_failure()
	reset()
	storage.reset()
	local client = assert(sdk.new(config_mode_a({ buffer_size = 1 })))
	assert_true(client:identify("user-example"))
	-- Saturate the single-slot queue directly so the FIRST real track() both
	-- lazily opens a session AND then fails to enqueue.
	client.queue.items[1] = { event_name = "filler" }
	assert_equal(client.session_id, nil)
	local ok, err = client:track("first")
	assert_equal(ok, false)
	assert_equal(err, "queue_full")
	-- The lazy session opened for this event must be rolled back; otherwise a
	-- later update()/session_end would reference a session that carries no
	-- enqueued event.
	assert_equal(client.session_id, nil, "lazy session must roll back on enqueue failure")
	assert_equal(client.session_active, false)
	assert_equal(client:snapshot().dropped, 1)
	storage.reset()
end

local function test_mode_a_401_drops_batch_without_retry()
	reset()
	storage.reset()
	local client = assert(sdk.new(config_mode_a()))
	assert_true(client:identify("user-example"))
	assert_true(client:track("e1"))
	next_status = 401
	client:flush()
	assert_equal(#requests, 1)
	-- A Mode A 401 means the static publishable key is revoked/misconfigured;
	-- replaying it would loop forever, so the batch is dropped, not retained.
	assert_equal(client.in_flight_batch, nil, "Mode A 401 must drop the batch")
	assert_equal(client:snapshot().dropped, 1)
	assert_equal(client:snapshot().failed_batches, 1)
	next_status = 202
	client:flush()
	assert_equal(#requests, 1, "Mode A 401 batch must not be retried against the same key")
	storage.reset()
end

local function test_mode_a_401_drops_pending_consent()
	reset()
	storage.reset()
	local client = assert(sdk.new(config_mode_a()))
	assert_true(client:identify("user-example"))
	next_status = 401
	assert_true(client:set_consent(true))
	assert_equal(#requests, 1)
	-- Unlike Mode B (which retains for a fresh-token retry), a Mode A consent
	-- 401 is terminal: the decision is dropped rather than replayed forever.
	assert_equal(client.pending_consent, nil, "Mode A 401 must drop the decision")
	assert_equal(client:snapshot().consent_failed, 1)
	next_status = 202
	client:update(client.config.flush_interval_seconds)
	assert_equal(#requests, 1, "Mode A 401 consent must not be retried against the same key")
	storage.reset()
end

local function test_set_anonymous_id_rejected_while_events_pending_mode_b()
	reset()
	storage.reset()
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	assert_true(client:track("queued"))
	-- With a Mode B token_provider, rotating the anon while an event is queued
	-- would bind the next minted token to the new anon while the queued payload
	-- still carries the old one — a guaranteed server-side batch rejection.
	local ok, err = client:set_anonymous_id("anon-new")
	assert_equal(ok, false)
	assert_equal(err, "events_pending")
	-- Once the queue is drained the rotation is allowed.
	next_status = 202
	assert_true(client:flush())
	assert_true(client:set_anonymous_id("anon-new"), "rotation allowed once drained")
	assert_equal(client:get_anonymous_id(), "anon-new")
	storage.reset()
end

local function test_set_anonymous_id_allowed_while_pending_mode_a()
	reset()
	storage.reset()
	-- Mode A has no bind_anon enforcement, so the guard must NOT over-restrict:
	-- rotating the anon while an event is queued stays allowed.
	local client = assert(sdk.new(config_mode_a()))
	assert_true(client:identify("user-example"))
	assert_true(client:track("queued"))
	assert_true(client:set_anonymous_id("anon-a"), "Mode A allows rotation while pending")
	assert_equal(client:get_anonymous_id(), "anon-a")
	storage.reset()
end

local function test_set_anonymous_id_remints_token_after_rotation_mode_b()
	reset()
	storage.reset()
	local token_calls = 0
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			token_calls = token_calls + 1
			callback("token-" .. tostring(token_calls), nil, nil)
		end,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:track("first"))
	next_status = 202
	assert_true(client:flush())
	assert_equal(token_calls, 1)
	assert_equal(requests[1].headers["Authorization"], "Bearer token-1")

	-- Queue drained: rotate the anon. The cached token-1 was minted with
	-- bind_anon = the old anon, so it must be dropped or the next publish would
	-- ship the new anon under a Bearer bound to the old one.
	assert_true(client:set_anonymous_id("anon-rotated"))
	assert_equal(client.token, nil, "rotating the anon must drop the cached Mode B token")

	assert_true(client:track("second"))
	assert_true(client:flush())
	assert_equal(token_calls, 2, "a rotated anon must force a fresh token mint")
	assert_equal(requests[2].headers["Authorization"], "Bearer token-2")
	storage.reset()
end

local function test_diagnose_tolerates_non_string_fields()
	reset()
	storage.reset()
	local client = assert(sdk.new(config_mode_a()))
	-- Server diagnostic fields come straight from the response; a malformed body
	-- with a non-string status/code must never crash the publish path.
	local ok = pcall(function()
		client:diagnose({ scope = "event", status = { weird = true }, code = false })
	end)
	assert_true(ok, "diagnose must not error on non-string status/code")
	-- Scalars are coerced; a numeric code is appended.
	client:diagnose({ scope = "event", status = "rejected", code = 422 })
	assert_equal(client:snapshot().last_event_issue, "rejected:422")
	-- A boolean status coerces to its string form.
	client:diagnose({ scope = "event", status = true })
	assert_equal(client:snapshot().last_event_issue, "true")
	storage.reset()
end

local function test_set_anonymous_id_rejected_while_token_request_in_flight()
	reset()
	storage.reset()
	local token_callback = nil
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			token_callback = callback -- capture, do NOT complete yet
		end,
	})))
	assert_true(client:identify("user-example"))
	-- A consent receipt triggers a Mode B token request that stays in flight
	-- (bound to the current anon).
	assert_true(client:set_consent(true))
	assert_equal(client.token_request_in_flight, true)
	-- Rotation must be rejected while that request is in flight, or its late
	-- callback would cache a JWT bound to the pre-rotation anon.
	local ok, err = client:set_anonymous_id("anon-new")
	assert_equal(ok, false)
	assert_equal(err, "events_pending")
	-- Once the token settles AND the deferred consent (old anon) is delivered,
	-- rotation is allowed. The token arriving doesn't auto-send the consent; the
	-- next dispatch does, clearing pending_consent.
	next_status = 202
	token_callback("token-1", nil, nil)
	assert_equal(client.token_request_in_flight, false)
	client:update(client.config.flush_interval_seconds)
	assert_equal(client.pending_consent, nil)
	assert_true(client:set_anonymous_id("anon-new"))
	assert_equal(client:get_anonymous_id(), "anon-new")
	storage.reset()
end

local function test_consent_denial_clears_stale_publish_deferral()
	reset()
	storage.reset()
	local client = assert(sdk.new(config_mode_a()))
	assert_true(client:identify("user-example"))
	assert_true(client:track("e1"))
	-- A 429 with a long Retry-After defers the next publish and retains the batch.
	next_status = 429
	next_response_headers = { ["retry-after"] = "3600" }
	client:flush()
	assert_true(client.publish_retry_after_ms ~= nil, "429 Retry-After must set a deferral")
	assert_true(client.in_flight_batch ~= nil, "a retryable 429 retains the batch")
	-- Denying consent discards the batch; the deferral set for it must not linger
	-- and block a later granted batch for up to the Retry-After window.
	next_response_headers = nil
	assert_true(client:set_consent(false))
	assert_equal(client.in_flight_batch, nil)
	assert_equal(client.publish_retry_after_ms, nil, "consent denial must clear the stale deferral")
	assert_equal(client.publish_backoff_attempt, 0)
	storage.reset()
end

local function test_denied_in_flight_429_sets_no_stale_deferral()
	reset()
	storage.reset()
	local original_request = http.request
	local callbacks = {}
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		callbacks[#callbacks + 1] = callback
	end

	local client = assert(sdk.new(config_mode_a()))
	assert_true(client:identify("user-example"))
	assert_true(client:track("in_flight_event"))
	client:flush()
	assert_equal(client.publish_in_flight, true)
	assert_equal(#callbacks, 1)

	-- Deny consent while the publish is in flight: the batch can't be aborted
	-- mid-flight, so it stays attached until the callback completes.
	assert_true(client:set_consent(false))
	assert_true(client.in_flight_batch ~= nil)

	-- The in-flight publish now completes with a 429 + Retry-After. Because
	-- consent was denied, the batch is dropped — so NO deferral must be recorded
	-- for it (it would otherwise block a later granted batch).
	callbacks[1](nil, nil, { status = 429, headers = { ["retry-after"] = "3600" } })
	assert_equal(client.in_flight_batch, nil, "denied batch must be dropped")
	assert_equal(client.publish_retry_after_ms, nil, "a dropped denied batch must not set a deferral")
	http.request = original_request
	storage.reset()
end

local function test_set_anonymous_id_rejected_while_consent_pending_mode_b()
	reset()
	storage.reset()
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			-- Settle the request with an error: pending_consent stays queued but
			-- token_request_in_flight returns to false.
			callback(nil, nil, "no token")
		end,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:set_consent(true))
	assert_true(client.pending_consent ~= nil, "consent stays pending after a token error")
	assert_equal(client.token_request_in_flight, false)
	-- A consent receipt bound to the OLD anon is still pending, so rotation must
	-- be blocked even though no token request is in flight.
	local ok, err = client:set_anonymous_id("anon-new")
	assert_equal(ok, false)
	assert_equal(err, "events_pending")
	storage.reset()
end

local function test_stale_unauthorized_consent_does_not_resurrect_old_decision()
	reset()
	storage.reset()
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
	assert_true(client:set_consent(false))
	assert_true(client:set_consent(true))
	assert_equal(#requests, 2)
	assert_equal(#callbacks, 2)

	-- the newer (granted) decision completes first
	callbacks[2](nil, nil, { status = 202, response = "" })
	assert_equal(client:snapshot().consent_recorded, 1)

	-- the stale (denied) dispatch comes back unauthorized: the token is
	-- invalidated but the stale decision must NOT be resurrected over the
	-- newer one
	callbacks[1](nil, nil, { status = 401, response = "" })
	assert_equal(client.token, nil)
	assert_equal(client.pending_consent, nil, "a stale decision must not be resurrected")

	client:update(client.config.flush_interval_seconds)
	assert_equal(#requests, 2, "the stale decision must not be replayed")
	http.request = original_request
	storage.reset()
end

local function test_shutdown_waits_for_deferred_consent()
	reset()
	storage.reset()
	local token_callback = nil
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			token_callback = callback
		end,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:set_consent(true))
	assert_true(client.pending_consent ~= nil)
	assert_equal(#requests, 0)

	-- no queued events, but the deferred decision must keep the client
	-- alive instead of being dropped at teardown
	local ok, err = client:shutdown("app_final")
	assert_equal(ok, false)
	assert_equal(err, "consent_pending")
	assert_equal(client.initialized, true)

	token_callback("late-token", nil, nil)
	assert_true(client:shutdown("app_final"))
	assert_equal(client.initialized, false)
	assert_equal(client.pending_consent, nil)
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_equal(requests[1].headers["Authorization"], "Bearer late-token")
	assert_contains(requests[1].body, '"categories":{"analytics":true}')
	assert_equal(client:snapshot().consent_recorded, 1)
	storage.reset()
end

local function test_set_consent_reports_persist_failure()
	reset()
	storage.reset()
	sys.get_save_file = function(application_id, file_name)
		return application_id .. "/" .. file_name
	end
	sys.save = function()
		return false
	end
	sys.load = function()
		return nil
	end

	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	local ok, err = client:set_consent(false)
	assert_equal(ok, false)
	assert_equal(err, "consent_persist_failed")
	assert_equal(client:snapshot().consent_persist_failed, 1)
	assert_equal(client:snapshot().last_consent_error, "consent_persist_failed")

	-- the decision still applies in memory and still reaches the wire
	assert_equal(client.consent_state, "denied")
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_contains(requests[1].body, '"categories":{"analytics":false}')
	local track_ok, track_err = client:track("denied_event")
	assert_equal(track_ok, false)
	assert_equal(track_err, "consent_denied")

	sys.get_save_file = nil
	sys.save = nil
	sys.load = nil
	storage.reset()
end

local function test_storage_namespace_varies_with_app_config()
	reset()
	storage.reset()
	local first = assert(sdk.new(config()))
	local other = assert(sdk.new(config({ app_id = "app-other" })))
	assert_not_equal(other.anonymous_id, first.anonymous_id, "different apps must not share an anonymous id")
	local sibling = assert(sdk.new(config()))
	assert_equal(sibling.anonymous_id, first.anonymous_id)

	-- consent must not bleed across apps either
	assert_true(first:set_consent(false))
	local denied_follower = assert(sdk.new(config()))
	assert_equal(denied_follower.consent_state, "denied")
	local other_follower = assert(sdk.new(config({ app_id = "app-other" })))
	assert_equal(other_follower.consent_state, "unknown", "another app must not inherit the denial")
	storage.reset()
end

local function test_storage_uses_app_scoped_save_file()
	reset()
	storage.reset()
	local namespaces = {}
	local stores = {}
	sys.get_save_file = function(application_id, file_name)
		namespaces[#namespaces + 1] = application_id
		return application_id .. "/" .. file_name
	end
	sys.save = function(path, record)
		stores[path] = record
		return true
	end
	sys.load = function(path)
		return stores[path]
	end

	local client = assert(sdk.new(config()))
	local record = stores["shardpilot.workspace-example.app-example/identity"]
	assert_equal(type(record), "table", "identity must persist under the app-scoped namespace")
	assert_equal(record.anonymous_id, client.anonymous_id)

	local other = assert(sdk.new(config({ app_id = "app-other" })))
	local other_record = stores["shardpilot.workspace-example.app-other/identity"]
	assert_equal(type(other_record), "table")
	assert_equal(other_record.anonymous_id, other.anonymous_id)
	assert_not_equal(other.anonymous_id, client.anonymous_id)

	-- a sibling with the same config reloads the persisted identity
	local sibling = assert(sdk.new(config()))
	assert_equal(sibling.anonymous_id, client.anonymous_id)

	-- scope segments are sanitized before reaching sys.get_save_file
	assert(sdk.new(config({ workspace_id = "ws/../evil", app_id = "app one" })))
	assert_equal(type(stores["shardpilot.ws____evil.app_one/identity"]), "table")
	for _, application_id in ipairs(namespaces) do
		assert_equal(application_id:find("/", 1, true), nil, "namespace must not contain path separators")
		assert_equal(application_id:find("..", 1, true), nil, "namespace must not contain dot-dot")
	end

	sys.get_save_file = nil
	sys.save = nil
	sys.load = nil
	storage.reset()
end

local function test_shutdown_completes_when_consent_denied()
	reset()
	storage.reset()
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())
	assert_true(client:flush())
	assert_true(client:set_consent(false))
	assert_equal(client.session_active, true)

	-- a denied user must still be able to tear the client down; the
	-- session_end event is suppressed, not transmitted
	assert_true(client:shutdown("app_final"))
	assert_equal(client.initialized, false)
	assert_equal(client.session_active, false)
	for _, request in ipairs(requests) do
		assert_not_contains(request.body, '"event_name":"session_end"')
	end

	local ok, err = client:track("after_shutdown")
	assert_equal(ok, false)
	assert_equal(err, "shutdown")
	storage.reset()
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
	client:track("app.screen_view", { screen_name = "menu" })
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
	assert_contains(requests[2].body, '"event_name":"app.screen_view"')
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
	assert_contains(requests[1].body, '"event_name":"app.session_started"')
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
		{ "set_consent", function()
			return sdk.set_consent(true)
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

-- L1 §5: a 202 body carries a per-event events[] array; non-accepted outcomes
-- (observed / rejected / duplicate / suppressed_no_consent) must be surfaced
-- through the diagnostics hook and the snapshot, not silently counted as
-- accepted.
local function test_batch_response_surfaces_per_event_outcomes()
	reset()
	storage.reset()
	local issues = {}
	local client = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	assert_true(client:identify("user-example"))
	for i = 1, 4 do
		assert_true(client:track("event_" .. tostring(i)))
	end

	next_response_body = '{"accepted":1,"rejected":1,"duplicates":1,"events":['
		.. '{"event_id":"e1","status":"accepted"},'
		.. '{"event_id":"e2","status":"observed","code":"event_not_registered"},'
		.. '{"event_id":"e3","status":"rejected","code":"blocked_event","message":"blocked"},'
		.. '{"event_id":"e4","status":"duplicate","code":"duplicate_event_id"}'
		.. ']}'
	assert_true(client:flush())

	local snapshot = client:snapshot()
	assert_equal(snapshot.accepted, 1, "aggregate accepted is kept from the body")
	assert_equal(snapshot.rejected, 1)
	assert_equal(snapshot.duplicates, 1)
	assert_equal(snapshot.observed, 1)

	-- three non-accepted per-event outcomes must reach the diagnostics hook
	assert_equal(#issues, 3)
	local by_status = {}
	for _, issue in ipairs(issues) do
		by_status[issue.status] = issue
	end
	assert_true(by_status.observed ~= nil)
	assert_equal(by_status.observed.event_id, "e2")
	assert_equal(by_status.observed.code, "event_not_registered")
	assert_true(by_status.rejected ~= nil)
	assert_equal(by_status.rejected.code, "blocked_event")
	assert_true(by_status.duplicate ~= nil)
	assert_equal(by_status.duplicate.code, "duplicate_event_id")
	storage.reset()
end

-- L1 §5: a suppressed_no_consent per-event status surfaces distinctly.
local function test_batch_response_surfaces_suppressed_no_consent()
	reset()
	storage.reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("suppressed_event"))

	next_response_body = '{"accepted":0,"rejected":1,"duplicates":0,"events":['
		.. '{"event_id":"e1","status":"suppressed_no_consent","code":"suppressed_no_consent"}'
		.. ']}'
	assert_true(client:flush())

	local snapshot = client:snapshot()
	assert_equal(snapshot.accepted, 0)
	assert_equal(snapshot.suppressed, 1)
	assert_equal(snapshot.last_event_issue, "suppressed_no_consent:suppressed_no_consent")
	storage.reset()
end

-- L1 §5: a 202 with no parseable events[] must not regress the accepted count.
local function test_batch_response_without_events_array_keeps_accepted()
	reset()
	storage.reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("only_aggregate"))

	next_response_body = '{"accepted":1,"rejected":0,"duplicates":0}'
	assert_true(client:flush())
	assert_equal(client:snapshot().accepted, 1)
	storage.reset()
end

-- L1 §6: a 429 Retry-After (whole seconds) defers the next publish attempt at
-- least that long; the batch is retained, not dropped or re-sent immediately.
local function test_retry_after_defers_next_publish()
	reset()
	storage.reset()
	next_status = 429
	next_response_headers = { ["retry-after"] = "120" }
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("rate_limited_event"))

	assert_equal(client:flush(), false)
	assert_equal(#requests, 1)
	assert_equal(#client.in_flight_batch, 1, "the rate-limited batch is retained")
	assert_true(client.publish_retry_after_ms ~= nil, "a retry-after deadline is set")
	assert_true(client:publish_deferred(), "publishing is deferred until the deadline")

	-- a flush during the deferral window must NOT re-send the batch
	next_status = 202
	next_response_headers = nil
	assert_equal(client:flush(), false)
	assert_equal(#requests, 1, "no publish during the retry-after window")

	-- once the deadline passes the batch is republished
	client.publish_retry_after_ms = nil
	assert_true(client:flush())
	assert_equal(#requests, 2)
	assert_equal(client.in_flight_batch, nil)
	storage.reset()
end

-- L1 §6: a successful publish clears any active backpressure deferral. A
-- deferral whose deadline has already elapsed does not block the publish.
local function test_successful_publish_clears_deferral()
	reset()
	storage.reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	client.publish_retry_after_ms = 1 -- a deadline in the distant past
	client.publish_backoff_attempt = 3
	assert_true(not client:publish_deferred(), "an elapsed deadline does not defer")
	assert_true(client:track("recovered_event"))
	assert_true(client:flush())
	assert_equal(#requests, 1)
	assert_equal(client.publish_retry_after_ms, nil)
	assert_equal(client.publish_backoff_attempt, 0)
	storage.reset()
end

-- L1 §6: sustained transient failures with no Retry-After header back off; the
-- first failure retries promptly, repeats wait.
local function test_backoff_on_sustained_transient_failures()
	reset()
	storage.reset()
	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("transient_event"))

	-- first transient failure: no deferral, retries on the next flush
	assert_equal(client:flush(), false)
	assert_equal(client.publish_backoff_attempt, 1)
	assert_true(not client:publish_deferred(), "first failure does not defer")

	-- second consecutive failure: backs off
	assert_equal(client:flush(), false)
	assert_equal(client.publish_backoff_attempt, 2)
	assert_true(client:publish_deferred(), "sustained failure backs off")

	-- recovery clears the backoff
	client.publish_retry_after_ms = nil
	next_status = 202
	assert_true(client:flush())
	assert_equal(client.publish_backoff_attempt, 0)
	storage.reset()
end

-- L1 §6: the { error: { code, message, details } } envelope on a non-2xx is
-- parsed and surfaced (error.code + detail codes), not just the bare status.
local function test_error_envelope_is_surfaced()
	reset()
	storage.reset()
	local issues = {}
	next_status = 400
	next_response_body = '{"error":{"code":"validation_failed","message":"bad batch","details":['
		.. '{"field":"props.level","code":"unknown_property","message":"not allowed"},'
		.. '{"field":"event_name","code":"blocked_event","message":"blocked"}'
		.. ']}}'
	local client = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:track("invalid_event"))

	assert_equal(client:flush(), false)
	assert_equal(client:snapshot().last_error, "http_400:validation_failed")
	assert_equal(#issues, 1)
	local issue = issues[1]
	assert_equal(issue.scope, "batch")
	assert_equal(issue.code, "validation_failed")
	assert_true(issue.detail_codes ~= nil)
	assert_equal(issue.detail_codes[1], "unknown_property")
	assert_equal(issue.detail_codes[2], "blocked_event")
	-- a 400 stays non-retryable: the batch is dropped, not retained
	assert_equal(client.in_flight_batch, nil)
	storage.reset()
end

-- A diagnostics hook that throws must never break the publish path.
local function test_diagnostics_hook_errors_are_swallowed()
	reset()
	storage.reset()
	local client = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		diagnostics = function()
			error("hook blew up")
		end,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:track("observed_event"))
	next_response_body = '{"accepted":0,"rejected":0,"duplicates":0,"events":['
		.. '{"event_id":"e1","status":"observed","code":"event_not_registered"}'
		.. ']}'
	assert_true(client:flush(), "a throwing hook must not break flush")
	assert_equal(client:snapshot().observed, 1)
	storage.reset()
end

local function test_invalid_diagnostics_rejected()
	local client, err = sdk.new(config({ diagnostics = 42 }))
	assert_equal(client, nil)
	assert_equal(err, "invalid_diagnostics")
end

-- Mode A: a publishable api_key (no token_provider) publishes events
-- with the api_key as the Bearer, with no token round-trip.
local function test_mode_a_api_key_is_bearer()
	reset()
	storage.reset()
	local client = assert(sdk.new(config_mode_a({ api_key = "sp_ingest_abc123" })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("mode_a_event"))
	assert_true(client:flush())
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/events:batch")
	assert_equal(requests[1].headers["Authorization"], "Bearer sp_ingest_abc123")
	assert_contains(requests[1].body, '"event_name":"mode_a_event"')
	storage.reset()
end

-- Mode A: the consent decision also rides the publishable api_key.
local function test_mode_a_consent_uses_api_key_bearer()
	reset()
	storage.reset()
	local client = assert(sdk.new(config_mode_a({ api_key = "sp_ingest_consent" })))
	assert_true(client:identify("user-example"))
	assert_true(client:set_consent(true))
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_equal(requests[1].headers["Authorization"], "Bearer sp_ingest_consent")
	assert_contains(requests[1].body, '"categories":{"analytics":true}')
	storage.reset()
end

-- anonymous_id is ALWAYS sent on the wire for source="client" in
-- BOTH auth modes: the server requires it, so the SDK must never strip
-- anonymous_id.
local function test_client_source_keeps_anonymous_id_both_modes()
	-- Mode B (token_provider).
	reset()
	storage.reset()
	local mode_b = assert(sdk.new(config()))
	assert_equal(mode_b.config.source, "client")
	assert_true(mode_b:set_anonymous_id("anon-mode-b"))
	assert_true(mode_b:track("client_event_b"))
	assert_true(mode_b:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"anonymous_id":"anon-mode-b"')
	assert_contains(requests[1].body, '"event_name":"client_event_b"')

	-- Mode A (publishable api_key).
	reset()
	storage.reset()
	local mode_a = assert(sdk.new(config_mode_a()))
	assert_equal(mode_a.config.source, "client")
	assert_true(mode_a:set_anonymous_id("anon-mode-a"))
	assert_true(mode_a:track("client_event_a"))
	assert_true(mode_a:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"anonymous_id":"anon-mode-a"')
	assert_contains(requests[1].body, '"event_name":"client_event_a"')

	-- Non-client (service) source also keeps anonymous_id on the wire.
	reset()
	storage.reset()
	local server_client = assert(sdk.new(config({ source = "server" })))
	assert_true(server_client:set_anonymous_id("anon-server"))
	assert_true(server_client:track("server_event"))
	assert_true(server_client:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"anonymous_id":"anon-server"')
	storage.reset()
end

-- get_anonymous_id exposes the same anonymous ID the SDK sends on the wire, so
-- the host can hand it to its backend at JWT-mint time (bind_anon consistency).
local function test_get_anonymous_id_matches_wire()
	reset()
	storage.reset()
	local client = assert(sdk.new(config()))
	assert_true(client:set_anonymous_id("anon-exposed"))
	assert_equal(client:get_anonymous_id(), "anon-exposed")
	assert_true(client:track("anon_exposed_event"))
	assert_true(client:flush())
	assert_contains(requests[1].body, '"anonymous_id":"anon-exposed"')
	storage.reset()
end

-- The server requires session_id for non-backend sources, so track()
-- before session_start() must still carry a synthesized session_id.
local function test_track_before_session_start_lazily_opens_session()
	reset()
	storage.reset()
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
	storage.reset()
	local backend = assert(sdk.new(config({ source = "backend" })))
	assert_true(backend:identify("user-example"))
	assert_true(backend:track("backend_event"))
	assert_equal(backend.session_id, nil)
	assert_true(backend:flush())
	assert_equal(#requests, 1)
	assert_not_contains(requests[1].body, '"session_id"')
	storage.reset()
end

local tests = {
	test_config_validation,
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
	test_anonymous_id_in_memory_round_trip,
	test_configured_anonymous_id_overrides_and_persists,
	test_consent_tri_state_gating_and_queue_clear,
	test_consent_denied_clears_retained_batch,
	test_consent_send_failure_is_quiet,
	test_consent_denied_drops_in_flight_batch_on_retryable_failure,
	test_consent_decision_defers_until_token_arrives,
	test_session_end_while_denied_completes_locally,
	test_consent_retained_after_unauthorized_and_resent_with_fresh_token,
	test_lazy_session_rolls_back_on_enqueue_failure,
	test_mode_a_401_drops_batch_without_retry,
	test_mode_a_401_drops_pending_consent,
	test_set_anonymous_id_rejected_while_events_pending_mode_b,
	test_set_anonymous_id_allowed_while_pending_mode_a,
	test_set_anonymous_id_remints_token_after_rotation_mode_b,
	test_diagnose_tolerates_non_string_fields,
	test_set_anonymous_id_rejected_while_token_request_in_flight,
	test_consent_denial_clears_stale_publish_deferral,
	test_denied_in_flight_429_sets_no_stale_deferral,
	test_set_anonymous_id_rejected_while_consent_pending_mode_b,
	test_stale_unauthorized_consent_does_not_resurrect_old_decision,
	test_shutdown_waits_for_deferred_consent,
	test_set_consent_reports_persist_failure,
	test_storage_namespace_varies_with_app_config,
	test_storage_uses_app_scoped_save_file,
	test_shutdown_completes_when_consent_denied,
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
	test_batch_response_surfaces_per_event_outcomes,
	test_batch_response_surfaces_suppressed_no_consent,
	test_batch_response_without_events_array_keeps_accepted,
	test_retry_after_defers_next_publish,
	test_successful_publish_clears_deferral,
	test_backoff_on_sustained_transient_failures,
	test_error_envelope_is_surfaced,
	test_diagnostics_hook_errors_are_swallowed,
	test_invalid_diagnostics_rejected,
	test_mode_a_api_key_is_bearer,
	test_mode_a_consent_uses_api_key_bearer,
	test_client_source_keeps_anonymous_id_both_modes,
	test_get_anonymous_id_matches_wire,
	test_track_before_session_start_lazily_opens_session,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold lua tests passed")
