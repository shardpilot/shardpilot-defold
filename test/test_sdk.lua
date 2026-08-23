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
local schema_revision = require "shardpilot.schema_revision"
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

-- Swap the synchronous http fake for one that HOLDS every callback (real
-- Defold http.request is asynchronous): requests are still recorded, but the
-- response callback is captured for the test to fire manually. Returns the
-- held-callback list and a restore function. Firing a callback with a 202
-- settles the in-flight batch without re-entering the flush loop — exactly
-- the production window in which owed summaries linger between flushes.
local function hold_http_requests()
	local held = {}
	local real_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = {
			url = url,
			method = method,
			headers = headers,
			body = body,
			options = options,
		}
		held[#held + 1] = callback
	end
	return held, function()
		http.request = real_request
	end
end

local function release_held_request(held)
	local callback = table.remove(held, 1)
	assert_true(callback ~= nil, "expected a held http request to release")
	callback(nil, nil, { status = 202, response = '{"accepted":1}' })
end

local identity_scope = { workspace_id = "workspace-example", app_id = "app-example" }

-- Consent-first: a client whose consent is still "unknown" transmits nothing,
-- so tests that exercise the event pipeline persist a grant BEFORE building
-- their client. Seeding the record directly (instead of calling set_consent)
-- keeps request-order assertions stable — no /v1/consent receipt is sent for
-- a pre-seeded decision. The read-modify-write preserves any anonymous_id a
-- previous client persisted.
local function seed_granted_consent(scope)
	scope = scope or identity_scope
	local record = storage.load(scope) or {}
	record.consent_analytics = "granted"
	assert_true(storage.save(scope, record), "seeding the consent grant must succeed")
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
		{ { spool_enabled = "yes" }, "invalid_spool_enabled" },
		{ { spool_max_events = 0 }, "invalid_spool_max_events" },
		{ { spool_max_events = 1.5 }, "invalid_spool_max_events" },
		{ { spool_max_bytes = 512 }, "invalid_spool_max_bytes" },
		{ { spool_max_bytes = 1000000 }, "invalid_spool_max_bytes" },
		{ { schema_revision = 42 }, "invalid_schema_revision" },
		{ { schema_revision = true }, "invalid_schema_revision" },
		{ { schema_revision = {} }, "invalid_schema_revision" },
		{ { consent_kind_emission_enabled = "yes" }, "invalid_consent_kind_emission_enabled" },
		{ { consent_kind_emission_enabled = 1 }, "invalid_consent_kind_emission_enabled" },
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
	-- 1000 is the cross-SDK canonical buffer default (SP-059).
	assert_equal(client.config.buffer_size, 1000)
	assert_equal(client.config.platform, "linux")
	assert_equal(client.config.token_refresh_lead_ms, 60000)
	assert_equal(client.config.spool_enabled, true)
	assert_equal(client.config.spool_max_events, 500)
	assert_equal(client.config.spool_max_bytes, 262144)
	-- Default: declare the SDK's built-in schema-set revision on batch ingest.
	assert_equal(client.config.schema_revision, schema_revision.REVISION)
	-- Default: consent receipts carry their actor kind on the wire.
	assert_equal(client.config.consent_kind_emission_enabled, true)

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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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

-- Mode A deliberately: the pin is that identity/session/time are
-- SNAPSHOTTED at enqueue — an event tracked under user-a ships user-a even
-- after the host re-identifies — and Mode A is where that mixed-user batch
-- remains lawful (a static publishable key vouches for no particular
-- user). Mode B now REFUSES the un-flushed switch outright, exactly so a
-- mixed batch can never ride one minted Bearer: pinned by
-- test_identify_refused_while_other_user_events_pending.
local function test_track_snapshots_identity_session_and_time()
	reset()
	seed_granted_consent()
	local client = assert(sdk.new(config_mode_a()))
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	-- Consent-first: "unknown" transmits nothing — the event is dropped at
	-- enqueue with its own distinct error, so the caller can tell the
	-- undecided state from an explicit denial.
	local ok, err = client:track("blocked_while_unknown")
	assert_equal(ok, false)
	assert_equal(err, "consent_unknown")
	assert_equal(#client.queue.items, 0, "nothing may be queued while consent is unknown")
	assert_equal(client:snapshot().dropped, 1)

	ok, err = client:set_consent("yes")
	assert_equal(ok, false)
	assert_equal(err, "invalid_consent")
	assert_equal(client.consent_state, "unknown")

	assert_true(client:set_consent(false))
	assert_equal(client.consent_state, "denied")
	assert_equal(#client.queue.items, 0)
	assert_equal(client:snapshot().dropped, 1, "the empty queue leaves nothing more to drop")
	assert_equal(#requests, 1)
	local consent_request = requests[1]
	assert_equal(consent_request.url, "http://localhost:8080/v1/consent")
	assert_equal(consent_request.method, "POST")
	assert_equal(consent_request.headers["Authorization"], "Bearer client-token-placeholder")
	assert_contains(consent_request.body, '"workspace_id":"workspace-example"')
	assert_contains(consent_request.body, '"app_id":"app-example"')
	assert_contains(consent_request.body, '"environment_id":"develop"')
	assert_contains(consent_request.body, '"actor_identifier":"user-example"')
	-- Mode B + identify(): the canonical actor is the verified user id, and
	-- its kind rides the wire by default.
	assert_contains(consent_request.body, '"kind":"user_verified"')
	assert_contains(consent_request.body, '"categories":{"analytics":false}')
	assert_contains(consent_request.body, '"decided_at":"')
	assert_contains(consent_request.body, '"idempotency_key":"')
	assert_not_contains(consent_request.body, '"event_name"')

	local denied_ok, denied_err = client:track("denied_event")
	assert_equal(denied_ok, false)
	assert_equal(denied_err, "consent_denied")
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
	seed_granted_consent()
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
	-- The transiently failed receipt is RETAINED in the outbox (previously it
	-- was dropped): the next dispatch point retries it until acknowledged.
	assert_equal(#client.consent_outbox, 1, "a transient receipt failure must retain the receipt")
	next_status = 202
	-- The failure armed the receipt's own backoff deadline (A6: the first
	-- hint-less failure paces on the retry clock now, where it used to arm
	-- nothing and let the next flush tick decide). Advance the harness clock
	-- past that window, then tick: the receipt must go out on the RETRY wake,
	-- which is a different code path from the flush-cadence one — this tick
	-- deliberately passes a dt of ZERO so the flush-interval branch cannot
	-- fire and take the credit.
	socket.now = socket.now + 2
	client:update(0)
	assert_equal(#requests, 2)
	assert_equal(requests[2].url, "http://localhost:8080/v1/consent")
	assert_equal(#client.consent_outbox, 0, "the acknowledged receipt must leave the outbox")
	assert_equal(client:snapshot().consent_recorded, 1)
	storage.reset()
end

local function test_consent_denied_drops_in_flight_batch_on_retryable_failure()
	reset()
	storage.reset()
	seed_granted_consent()
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
	assert_equal(#client.consent_outbox, 1, "the receipt must be retained in the outbox")
	assert_equal(client:snapshot().consent_failed, 1)
	assert_equal(client:snapshot().consent_recorded, 0)

	token_callback("deferred-token", nil, nil)
	assert_equal(client.token, "deferred-token")
	assert_equal(#client.consent_outbox, 1, "still pending until the next dispatch point")

	-- the next dispatch point (the update-driven flush) transmits it
	-- without a second set_consent call
	client:update(client.config.flush_interval_seconds)
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_equal(requests[1].headers["Authorization"], "Bearer deferred-token")
	assert_contains(requests[1].body, '"categories":{"analytics":true}')
	assert_equal(#client.consent_outbox, 0)
	assert_equal(client:snapshot().consent_recorded, 1)
	storage.reset()
end

local function test_session_end_while_denied_completes_locally()
	reset()
	storage.reset()
	seed_granted_consent()
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
	assert_equal(#client.consent_outbox, 1, "an auth failure must not lose the decision")
	assert_equal(client:snapshot().consent_failed, 1)
	assert_equal(client:snapshot().last_consent_error, "unauthorized")

	-- the next dispatch point refreshes the token and retries the decision
	next_status = 202
	client:update(client.config.flush_interval_seconds)
	assert_equal(#requests, 2)
	assert_equal(requests[2].url, "http://localhost:8080/v1/consent")
	assert_equal(requests[2].headers["Authorization"], "Bearer token-2")
	assert_contains(requests[2].body, '"categories":{"analytics":true}')
	assert_equal(#client.consent_outbox, 0)
	assert_equal(client:snapshot().consent_recorded, 1)
	storage.reset()
end

local function test_lazy_session_rolls_back_on_enqueue_failure()
	reset()
	storage.reset()
	seed_granted_consent()
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
	seed_granted_consent()
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
	-- 401 is terminal: the receipt is dropped from the outbox rather than
	-- replayed forever against the same static key.
	assert_equal(#client.consent_outbox, 0, "Mode A 401 must drop the receipt")
	assert_equal(client:snapshot().consent_failed, 1)
	next_status = 202
	client:update(client.config.flush_interval_seconds)
	assert_equal(#requests, 1, "Mode A 401 consent must not be retried against the same key")
	storage.reset()
end

local function test_set_anonymous_id_rejected_while_events_pending_mode_b()
	reset()
	storage.reset()
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
			-- Settle the request with an error: the receipt stays retained in
			-- the outbox but token_request_in_flight returns to false.
			callback(nil, nil, "no token")
		end,
	})))
	assert_true(client:set_consent(true))
	assert_equal(#client.consent_outbox, 1, "consent stays pending after a token error")
	assert_equal(client.consent_outbox[1].kind, "anon",
		"a pre-identify Mode B decision keys to the anon actor")
	assert_equal(client.token_request_in_flight, false)
	-- An ANON-KEYED consent receipt carries the OLD anon as its actor, so
	-- rotation must be blocked even though no token request is in flight —
	-- a post-rotation retry would mint for the new anon but send the old
	-- actor. (A user_verified-keyed receipt does not block: see
	-- test_rotation_allowed_with_only_parked_verified_receipts.)
	local ok, err = client:set_anonymous_id("anon-new")
	assert_equal(ok, false)
	assert_equal(err, "events_pending")
	storage.reset()
end

-- Receipts are an audit trail: EVERY explicit decision delivers exactly one
-- receipt, serially and strictly in decision order — one receipt in flight at
-- a time, so a grant made right after a denial can never settle on the server
-- as deny-after-grant, and a Mode B 401 on the older receipt retries IT first
-- (with a fresh token) before the newer decision goes out.
local function test_consent_receipts_deliver_serially_in_decision_order()
	reset()
	storage.reset()
	local original_request = http.request
	local callbacks = {}
	local token_calls = 0
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

	local client = assert(sdk.new(config({
		token_provider = function(callback)
			token_calls = token_calls + 1
			callback("token-" .. tostring(token_calls), nil, nil)
		end,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:set_consent(false))
	assert_true(client:set_consent(true))
	-- Serial delivery: the denied receipt is in flight, the granted receipt
	-- queues behind it instead of dispatching concurrently.
	assert_equal(#requests, 1, "one receipt in flight at a time")
	assert_contains(requests[1].body, '"categories":{"analytics":false}')
	assert_equal(#client.consent_outbox, 2)

	-- the in-flight (older, denied) receipt comes back unauthorized: the
	-- token is invalidated, the receipt stays at the HEAD of the outbox
	callbacks[1](nil, nil, { status = 401, response = "" })
	assert_equal(client.token, nil)
	assert_equal(#client.consent_outbox, 2, "a Mode B 401 must not lose the receipt")

	-- the next dispatch point re-mints and retries the denied receipt FIRST;
	-- its ack then chains the granted receipt in the same dispatch pass
	client:update(client.config.flush_interval_seconds)
	assert_equal(#requests, 2)
	assert_equal(requests[2].headers["Authorization"], "Bearer token-2")
	assert_contains(requests[2].body, '"categories":{"analytics":false}')
	callbacks[2](nil, nil, { status = 202, response = "" })
	assert_equal(#requests, 3, "the ack must chain the next retained receipt")
	assert_contains(requests[3].body, '"categories":{"analytics":true}')
	callbacks[3](nil, nil, { status = 202, response = "" })
	assert_equal(#client.consent_outbox, 0)
	assert_equal(client:snapshot().consent_recorded, 2)

	client:update(client.config.flush_interval_seconds)
	assert_equal(#requests, 3, "an empty outbox must not replay anything")
	http.request = original_request
	storage.reset()
end

-- On a host WITHOUT a durable save-file backend the outbox cannot outlive the
-- process, so the old contract holds: shutdown() refuses to tear down while a
-- receipt is still awaiting a token, and the host retries once it lands.
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
	assert_equal(#client.consent_outbox, 1)
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
	assert_equal(#client.consent_outbox, 0)
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
	local client = assert(sdk.new(config()))
	client:identify("user-example")
	client:session_start()
	assert_true(client:shutdown("app_final"))
	assert_contains(requests[1].body, '"event_name":"session_end"')
	assert_equal(client.initialized, false)
end

local function test_session_end_queue_full_keeps_session_active()
	reset()
	seed_granted_consent()
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

local function test_shutdown_queue_full_completes_after_final_flush()
	reset()
	seed_granted_consent()
	local client = assert(sdk.new(config({ buffer_size = 1 })))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())

	-- The full queue rejects session_end's event first, but shutdown's own
	-- final flush is exactly what frees the room: the session end is
	-- retried and delivered, and teardown completes in ONE call — a full
	-- queue must not wedge the exit path behind a manual flush.
	assert_true(client:shutdown("app_final"))
	assert_equal(client.initialized, false)
	assert_equal(client.session_active, false)
	local seen_session_end = false
	for i = 1, #requests do
		if requests[i].body
			and requests[i].body:find('"event_name":"session_end"', 1, true) then
			seen_session_end = true
		end
	end
	assert_true(seen_session_end,
		"the deferred session end must ride a shutdown batch")
end

local function test_flush_and_shutdown_wait_for_async_publish()
	reset()
	seed_granted_consent()
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

	-- spool_enabled=false: this test exercises the in-process wait contract
	-- (shutdown must not finalize while a publish is still in flight).
	local client = assert(sdk.new(config({ spool_enabled = false })))
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
	seed_granted_consent()
	next_status = 500
	-- spool_enabled=false: without the durable spool, a retryable final-flush
	-- failure must keep the singleton alive for a host retry loop.
	local ok, err = sdk.init(config({ spool_enabled = false }))
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
	seed_granted_consent()
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
		{ "persist", function()
			return sdk.persist()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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

-- L1 §6: a 5xx Retry-After is honored exactly like the 429 one. The server's
-- strict-consent mode-unknown lane answers a whole-batch 503 with
-- `Retry-After: 5`; the transport must pass the parsed header through so the
-- deferral paces recovery on the server's hint instead of falling back to the
-- client's own jittered backoff.
local function test_503_retry_after_defers_next_publish()
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 503
	next_response_headers = { ["retry-after"] = "5" }
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("consent_outage_event"))

	assert_equal(client:flush(), false)
	assert_equal(#requests, 1)
	assert_equal(#client.in_flight_batch, 1, "the 503 batch is retained")
	assert_true(client.publish_retry_after_ms ~= nil, "a 503 Retry-After sets a deferral")
	assert_true(client:publish_deferred(), "publishing is deferred until the deadline")
	assert_equal(client.publish_backoff_attempt, 0, "the server hint is used instead of jittered backoff")
	assert_true(client.spool_retry_after_ms ~= nil, "the server-requested deadline reaches the spool record")

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

-- Strict-consent receipt-lag hardening (audit 2026-07-18, item 3a): within one
-- flush cycle the consent-receipt outbox is handed to the transport BEFORE the
-- event batch, so a retained grant receipt is on the wire ahead of the first
-- post-grant events. Sequencing only — the batch must not wait on the
-- receipt's acknowledgment.
local function test_flush_sends_consent_receipt_before_event_batch()
	reset()
	storage.reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	-- The initial receipt dispatch fails retryably, so the receipt stays
	-- retained at the outbox head while the local grant opens the pipeline.
	next_status = 500
	client:set_consent(true)
	assert_equal(#requests, 1)
	assert_true(requests[1].url:find("/v1/consent", 1, true) ~= nil, "the grant posts a receipt")
	assert_true(client:track("post_grant_event"))

	-- One flush drives both planes: the retained receipt re-sends first, the
	-- event batch second — and the batch is dispatched in the SAME cycle (no
	-- ack-gating deferral to a later flush).
	--
	-- The clock advance is A6's, and it is a real behaviour change rather
	-- than test scaffolding. The receipt's FIRST failure now arms its own
	-- retry window where it armed none, and an undispatched grant holds the
	-- event legs by design (ordering, not pacing — see
	-- try_send_consent_outbox). So a post-grant event is held for that
	-- window. That is the trade this makes deliberately: one second, against
	-- the fifteen it would be if the receipt's retry still rode the flush
	-- tick.
	next_status = 202
	socket.now = socket.now + 2
	assert_true(client:flush())
	assert_equal(#requests, 3)
	assert_true(requests[2].url:find("/v1/consent", 1, true) ~= nil, "the retained receipt is dispatched first")
	assert_true(requests[3].url:find("/v1/events:batch", 1, true) ~= nil, "the event batch follows in the same cycle")
	storage.reset()
end

-- Audit 3a follow-up: an undispatched GRANT receipt holds the event-batch leg
-- of flush — a grant parked in a server Retry-After window (or the client's
-- own jittered backoff) has not been handed to the transport, so a batch
-- published meanwhile would overtake it and reach a strict-enforce workspace
-- with no consent row to admit it.
local function test_grant_receipt_retry_after_defers_event_publish()
	reset()
	storage.reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	next_status = 503
	next_response_headers = { ["retry-after"] = "30" }
	client:set_consent(true)
	assert_equal(#requests, 1)
	assert_true(client:consent_send_deferred(), "the consent plane honors the 5xx Retry-After")
	assert_true(client:track("post_grant_event"))

	-- The batch leg is held while the grant receipt sits in the window.
	next_status = 202
	next_response_headers = nil
	local flushed, reason = client:flush()
	assert_equal(flushed, false)
	assert_equal(reason, "consent_receipt_pending")
	assert_equal(#requests, 1, "no event publish while the grant awaits dispatch")

	-- Once the window passes, ONE flush cycle sends receipt then batch.
	client.consent_retry_after_ms = nil
	assert_true(client:flush())
	assert_equal(#requests, 3)
	assert_true(requests[2].url:find("/v1/consent", 1, true) ~= nil, "the retained receipt goes first")
	assert_true(requests[3].url:find("/v1/events:batch", 1, true) ~= nil, "the batch follows in the same cycle")

	-- The rule is dispatch-based, not window-based: a grant parked by the
	-- client's own jittered backoff is equally undispatched, so it holds
	-- events just the same.
	reset()
	storage.reset()
	local scoped = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(scoped:identify("user-example"))
	next_status = 500
	scoped:set_consent(true) -- first failure: receipt retained
	assert_equal(#requests, 1)
	assert_true(scoped:track("backoff_scoped_event"))
	scoped:defer_consent_backoff()
	scoped:defer_consent_backoff()
	assert_true(scoped:consent_send_deferred(), "a jittered receipt window is open")
	next_status = 202
	local scoped_flushed, scoped_reason = scoped:flush()
	assert_equal(scoped_flushed, false)
	assert_equal(scoped_reason, "consent_receipt_pending")
	assert_equal(#requests, 1, "events must not overtake a backoff-parked grant either")
	storage.reset()
end

-- Gate scoping: a grant queued BEHIND a server-deferred head receipt still
-- holds events — the serial outbox cannot deliver the grant until the head's
-- window elapses, so post-grant events would overtake it on a strict-enforce
-- workspace.
local function test_grant_behind_deferred_head_receipt_holds_events()
	reset()
	storage.reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	-- The deny receipt fails retryably with a server hint: head deferred.
	next_status = 503
	next_response_headers = { ["retry-after"] = "30" }
	client:set_consent(false)
	assert_equal(#requests, 1)
	assert_true(client:consent_send_deferred(), "the head receipt is parked in the server window")
	-- The user grants during the window: the grant queues behind the head.
	client:set_consent(true)
	assert_equal(#requests, 1, "the serial outbox cannot deliver the grant yet")
	assert_true(client:track("post_grant_event"))

	next_status = 202
	next_response_headers = nil
	local flushed, reason = client:flush()
	assert_equal(flushed, false)
	assert_equal(reason, "consent_receipt_pending")
	assert_equal(#requests, 1, "no event publish while the grant waits behind the deferred head")

	-- After the window: deny, then grant, then the batch — in order.
	client.consent_retry_after_ms = nil
	assert_true(client:flush())
	assert_equal(#requests, 4)
	assert_true(requests[2].url:find("/v1/consent", 1, true) ~= nil, "the deny receipt goes first")
	assert_true(requests[3].url:find("/v1/consent", 1, true) ~= nil, "the grant receipt follows")
	assert_true(requests[4].url:find("/v1/events:batch", 1, true) ~= nil, "the batch goes last")
	storage.reset()
end

-- Audit 3a follow-up (async transport): the real Defold http.request is
-- asynchronous, so a flush after the head's window elapses only STARTS the
-- head receipt — a grant queued behind it is still undispatched, and the
-- batch must stay held until the chained drain hands the grant itself to the
-- transport. Release is on DISPATCH, not acknowledgment: once the grant is
-- in flight the batch follows with the grant's response still pending.
local function test_grant_behind_head_holds_events_until_dispatched()
	reset()
	storage.reset()
	local original_request = http.request
	local callbacks = {}
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		callbacks[#callbacks + 1] = callback
	end
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	-- The deny receipt dispatches, then fails with a Retry-After: head parked.
	client:set_consent(false)
	assert_equal(#requests, 1)
	callbacks[1](nil, nil, { status = 503, headers = { ["retry-after"] = "30" } })
	-- The user grants during the window; the grant queues behind the head.
	client:set_consent(true)
	assert_equal(#requests, 1)
	assert_true(client:track("post_grant_event"))

	-- The window elapses. This flush only STARTS the head receipt (async);
	-- the grant behind it is still undispatched, so the batch stays held
	-- even though the deferral window is over.
	client.consent_retry_after_ms = nil
	local flushed, reason = client:flush()
	assert_equal(flushed, false)
	assert_equal(reason, "consent_receipt_pending")
	assert_equal(#requests, 2, "only the head receipt was dispatched")
	assert_true(requests[2].url:find("/v1/consent", 1, true) ~= nil)

	-- The head succeeds; the chained drain hands the GRANT to the transport.
	callbacks[2](nil, nil, { status = 202, response = "{}" })
	assert_equal(#requests, 3, "the chained drain dispatches the grant")
	assert_true(requests[3].url:find("/v1/consent", 1, true) ~= nil)
	assert_contains(requests[3].body, '"analytics":true')

	-- The grant is in flight (unacknowledged): the batch may follow it now —
	-- sequencing, not ack-gating.
	local publish_flushed, publish_reason = client:flush()
	assert_equal(publish_flushed, false)
	assert_equal(publish_reason, "pending")
	assert_equal(#requests, 4)
	assert_true(requests[4].url:find("/v1/events:batch", 1, true) ~= nil, "the batch follows the dispatched grant")
	callbacks[3](nil, nil, { status = 202, response = "{}" })
	callbacks[4](nil, nil, { status = 202, response = '{"accepted":1}' })
	http.request = original_request
	storage.reset()
end


-- L1 §6: a successful publish clears any active backpressure deferral. A
-- deferral whose deadline has already elapsed does not block the publish.
local function test_successful_publish_clears_deferral()
	reset()
	storage.reset()
	seed_granted_consent()
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

-- L1 §6: transient failures with no Retry-After header back off on the
-- CLIENT'S OWN clock, first failure included.
local function test_backoff_on_sustained_transient_failures()
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("transient_event"))

	-- First transient failure: defers on the retry clock. It used to defer
	-- NOTHING and retry "on the next flush", which sounded immediate only
	-- because the flush interval was one second — at fifteen the same code
	-- path is a fifteen-second stall, and this test would still have passed.
	-- The deadline is asserted here so the schedule is what decides.
	assert_equal(client:flush(), false)
	assert_equal(client.publish_backoff_attempt, 1)
	assert_true(client:publish_deferred(), "the first failure defers on the retry clock")

	-- An EXPLICIT flush is not bound by the client's own backoff (only by a
	-- server-sent Retry-After), so the caller's retry goes out and advances
	-- the streak.
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

-- A6: the retained batch's retry is driven by the RETRY clock, through a wake
-- in update(), not by the flush cadence.
--
-- This client has no timer of its own — update(dt) is the only thing that
-- publishes — so before this an armed deadline never actually decided when a
-- retry happened; the next flush tick did, and the deadline merely had to be
-- earlier than it. The flush interval here is 9999s and the tick is driven
-- with dt = 0, so the cadence branch CANNOT fire: anything that goes out is
-- the wake's doing.
local function test_retry_wake_republishes_without_a_flush_tick()
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("woken_event"))

	assert_equal(client:flush(), false)
	assert_equal(#requests, 1)
	assert_equal(#client.in_flight_batch, 1, "the batch is retained")
	assert_true(client:publish_deferred(), "the first failure arms the retry clock")

	-- Inside the window: the wake must NOT fire.
	next_status = 202
	client:update(0)
	assert_equal(#requests, 1, "an open window holds the retry")

	-- Past it: the wake republishes, with no flush tick anywhere in sight.
	socket.now = socket.now + 2
	client:update(0)
	assert_equal(#requests, 2, "the elapsed deadline is picked up by the retry wake")
	assert_equal(client.in_flight_batch, nil)

	-- SAME test function, second subject: WHOSE deadline it is decides
	-- whether an explicit flush honours it. Folded in here rather than split
	-- out because this file is at Lua's 200-local ceiling for the main chunk.
	reset()
	storage.reset()
	seed_granted_consent()

	-- Client-side backoff: an explicit flush goes out.
	next_status = 500
	local mine = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(mine:identify("user-example"))
	assert_true(mine:track("client_backoff_event"))
	assert_equal(mine:flush(), false)
	assert_true(mine:publish_deferred(), "the client armed its own window")
	assert_equal(mine:publish_server_deferred(), false, "nobody but us asked for this wait")
	next_status = 202
	assert_true(mine:flush(), "an explicit flush is not bound by our own backoff")
	assert_equal(#requests, 2)

	-- Server-sent Retry-After: an explicit flush waits.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 429
	next_response_headers = { ["retry-after"] = "120" }
	local theirs = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(theirs:identify("user-example"))
	assert_true(theirs:track("server_hinted_event"))
	assert_equal(theirs:flush(), false)
	assert_true(theirs:publish_deferred(), "the server armed the window")
	assert_true(theirs:publish_server_deferred(), "the server asked for this wait")
	next_status = 202
	next_response_headers = nil
	assert_equal(theirs:flush(), false, "the server's instruction binds an explicit flush too")
	assert_equal(#requests, 1, "no publish inside a server-sent window")

	-- THIRD subject, same function and the same ceiling reason: a mint that
	-- settles BADLY must re-arm the retained work, paced.
	--
	-- The update() that starts the mint spends the retained 401 batch's
	-- one-shot nudge, and that batch has no deadline and has left the queue.
	-- So a provider that errors leaves it with no wake at all until the flush
	-- interval — fifteen seconds, on a credential failure. And the arm has to
	-- be the BACKOFF, not another nudge: a failing provider fails repeatedly,
	-- and a bare nudge mints again every frame.
	reset()
	storage.reset()
	seed_granted_consent()
	local mint_calls = 0
	local settle = nil
	local minted = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		token_provider = function(callback)
			mint_calls = mint_calls + 1
			if mint_calls == 1 then
				-- The first mint succeeds SYNCHRONOUSLY so a batch can be
				-- published and 401'd, which is what retains it.
				callback("token-1", nil, nil)
			else
				-- The RE-mint is asynchronous and will fail. Asynchronous is
				-- the only shape that shows the defect: a synchronous callback
				-- runs while its caller is on its way to publish anyway.
				settle = callback
			end
		end,
	})))
	assert_true(minted:identify("user-example"))
	assert_true(minted:track("mint_failure_event"))

	next_status = 401
	assert_equal(minted:flush(), false)
	assert_true(minted.in_flight_batch ~= nil and #minted.in_flight_batch > 0,
		"a Mode B 401 retains the batch for a fresh token")
	assert_equal(minted:publish_deferred(), false,
		"the 401 deliberately arms nothing so a fresh token can be tried at once")

	-- The tick that starts the re-mint spends the batch's one-shot nudge.
	minted:update(0)
	assert_true(settle ~= nil, "the retry asked the provider for a fresh token")
	local deliver = settle
	settle = nil
	local mints_at_settle = mint_calls
	deliver(nil, nil, "provider unavailable")

	assert_equal(minted:snapshot().last_error, "token_unavailable")
	assert_true(minted:publish_deferred(),
		"a failed settlement must arm the retained batch rather than leave it wakeless")

	-- Paced, not per-frame: inside the window nothing mints again.
	minted:update(0)
	minted:update(0)
	assert_equal(mint_calls, mints_at_settle,
		"a failing provider must not be re-minted on every frame")

	-- FOURTH subject: the plane the third one could not see.
	--
	-- A mint is started for EITHER plane, and a user_verified receipt's
	-- dispatch is one of the callers — it needs the token to vouch for the
	-- actor. But the failed settlement armed the backoff only behind
	-- has_retained_publish_work(), which counts event batches and spool
	-- chunks. With no event work in flight the mint was the receipt's alone,
	-- so a failing provider armed NOTHING: consent_retry_after_ms stayed nil,
	-- consent_retry_due() cannot fire without it, and the receipt waited out
	-- the whole flush interval — fifteen seconds under the new default, on
	-- the one plane whose timing must never inherit the batching cadence.
	reset()
	storage.reset()
	local consent_mints = 0
	local consent_settle = nil
	local receipt_only = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		token_provider = function(callback)
			consent_mints = consent_mints + 1
			consent_settle = callback
		end,
	})))
	-- identify() + a token_provider is what makes the receipt user_verified,
	-- and that kind is carried by the minted token alone.
	assert_true(receipt_only:identify("user-example"))
	assert_true(receipt_only:set_consent(true))
	receipt_only:flush()

	assert_true(consent_settle ~= nil, "the receipt's dispatch asked the provider for a token")
	assert_equal(receipt_only:has_retained_publish_work(), false,
		"the premise: no event batch and no spool chunk, so this mint is the receipt's alone")
	assert_true(receipt_only.consent_outbox ~= nil and #receipt_only.consent_outbox > 0,
		"the premise: the receipt is still undelivered")

	local deliver_consent = consent_settle
	consent_settle = nil
	local consent_mints_at_settle = consent_mints
	deliver_consent(nil, nil, "provider unavailable")

	assert_true(receipt_only:consent_send_deferred(),
		"a failed mint must arm the CONSENT clock too, or the receipt has no wake at all "
			.. "and waits out the flush interval")

	-- Paced on this plane as well: the consent clock is what stops the
	-- failing provider being asked again every frame.
	receipt_only:update(0)
	receipt_only:update(0)
	assert_equal(consent_mints, consent_mints_at_settle,
		"a failing provider must not be re-minted on every frame for a receipt either")

	-- FIFTH subject, and it is the fourth one's own regression: arming the
	-- consent clock for a NONEMPTY outbox rather than for work that was
	-- waiting on this mint.
	--
	-- A mint started for EVENT work, over an outbox holding only a PARKED
	-- receipt, armed a consent deadline nothing was blocked on. Nothing clears
	-- it when it expires with nothing dispatchable, so the wake fires forever
	-- and update() calls flush() every frame — permanently, which is worse
	-- than the fifteen-second stall the arm was added to remove.
	reset()
	storage.reset()
	local parked_mints = 0
	local parked_settle = nil
	local parked = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		token_provider = function(callback)
			parked_mints = parked_mints + 1
			if parked_mints == 1 then
				-- The receipt's own mint fails, so it stays undispatched.
				callback(nil, nil, "provider unavailable")
			elseif parked_mints == 2 then
				-- The event publish gets a token, so it can reach its 401.
				callback("token-parked", nil, nil)
			else
				parked_settle = callback
			end
		end,
	})))
	-- The receipt is keyed to user-a; signing in as user-b PARKS it, because
	-- the minted token vouches for the current user and no other. A parked
	-- grant does not hold the event legs (grant_receipt_pending_dispatch
	-- skips parked receipts), so the events plane below runs normally.
	assert_true(parked:identify("user-a"))
	assert_true(parked:set_consent(true))
	assert_true(parked:identify("user-b"))
	assert_true(parked.consent_outbox ~= nil and #parked.consent_outbox > 0,
		"the premise: the outbox still holds the undispatched receipt")
	assert_equal(parked:next_dispatchable_receipt(), nil,
		"the premise: and nothing in it is dispatchable for this session")

	-- Wait out the windows the receipt's own failed mint armed: what is under
	-- test is what the NEXT failure arms.
	parked.consent_retry_after_ms = nil
	parked.publish_retry_after_ms = nil

	next_status = 401
	assert_true(parked:track("parked_outbox_event"))
	assert_equal(parked:flush(), false)
	assert_true(parked.in_flight_batch ~= nil and #parked.in_flight_batch > 0,
		"the premise: the 401 retains an EVENT batch, so the re-mint is the events plane's")
	parked:update(0)
	assert_true(parked_settle ~= nil, "the retry asked the provider for a fresh token")
	local deliver_parked = parked_settle
	parked_settle = nil
	deliver_parked(nil, nil, "provider unavailable")

	assert_true(parked:publish_deferred(),
		"the events plane armed, which is the half that WAS waiting on this mint")
	assert_equal(parked:consent_send_deferred(), false,
		"no receipt was waiting on this mint, so the consent clock must not be armed")
	assert_equal(parked:consent_retry_due(), false,
		"and an expired deadline over an undispatchable outbox must never come due, "
			.. "or the wake fires on every frame for the life of the process")

	-- The second half of the fix, pinned on its own rather than through the
	-- first: whatever armed the deadline, an expired window over an outbox
	-- with nothing dispatchable must not come due. Nothing clears such a
	-- deadline — try_send_consent_outbox finds nothing to send — so a wake
	-- keyed on "the outbox is nonempty" calls flush() every frame for the
	-- life of the process.
	parked.consent_retry_after_ms = (require "shardpilot.clock").unix_ms() - 1
	assert_equal(parked:consent_send_deferred(), false, "the premise: the window has expired")
	assert_equal(parked:consent_retry_due(), false,
		"an expired window with nothing dispatchable behind it is a wake with no work")

	-- And the window the failed mint armed BELONGS to the receipt that was
	-- waiting on it. Without the key recorded, the actor-change cleanup
	-- cannot tell that this window's owner parked, and a receipt queued for
	-- the new actor inherits a backoff it never earned.
	reset()
	storage.reset()
	parked_mints = 0
	parked = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		token_provider = function(callback)
			parked_mints = parked_mints + 1
			callback(nil, nil, "provider unavailable")
		end,
	})))
	assert_true(parked:identify("user-owner"))
	assert_true(parked:set_consent(true))
	assert_true(parked:consent_send_deferred(), "the failed mint armed the receipt's window")
	assert_equal(parked.consent_deferral_armed_key,
		parked.consent_outbox[1].idempotency_key,
		"the armed window must name the receipt that is waiting on the mint")

	-- A mint DISCARDED for a stale identity epoch still owes the work it left
	-- behind a wake. identify() moved the actor while the mint was in flight,
	-- so the token must not be installed — but the dispatch point that
	-- started it already spent the one-shot nudge, and returning at the guard
	-- left the retained batch with no token, no deadline and no wake.
	reset()
	storage.reset()
	seed_granted_consent()
	parked_settle = nil
	parked_mints = 0
	parked = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		token_provider = function(callback)
			parked_mints = parked_mints + 1
			if parked_mints == 1 then
				callback("token-stale-1", nil, nil)
			else
				parked_settle = callback
			end
		end,
	})))
	-- ANONYMOUS work, deliberately: identify() refuses a switch that would
	-- strand a USER-keyed batch ("events_pending"), so anon-snapshotted work
	-- is the shape that can actually reach the stale-epoch guard.
	next_status = 401
	assert_true(parked:track("stale_epoch_event"))
	assert_equal(parked:flush(), false)
	assert_true(parked.in_flight_batch ~= nil and #parked.in_flight_batch > 0,
		"the premise: the 401 retains the anon batch")
	parked:update(0)
	assert_true(parked_settle ~= nil, "the premise: the re-mint is in flight")
	parked.flush_elapsed_seconds = 0
	assert_true(parked:identify("user-after"), "identity moves while the mint is in flight")
	parked_settle("token-for-the-previous-actor", nil, nil)
	assert_equal(parked.flush_elapsed_seconds, parked.config.flush_interval_seconds,
		"a discarded stale settlement must re-arm the work it left behind, "
			.. "or it waits out the whole flush interval with no token and no deadline")

	-- A malformed error envelope must not THROW inside the HTTP callback. A
	-- truthy non-string detail code reached table.concat, which raises and
	-- aborts flush() before the failure can be classified, retained or
	-- dropped — on a body the caller does not control.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 400
	next_response_body = '{"error":{"code":"validation_error","message":"bad",'
		.. '"details":[{"code":true},{"code":"unknown_event"}]}}'
	parked = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(parked:identify("user-example"))
	assert_true(parked:track("malformed_envelope_event"))
	assert_equal(parked:flush(), false,
		"a malformed detail code must classify as an ordinary failure, never throw")
	next_response_body = nil

	-- A minted-token consent 401 gets the wake the dispatch comment already
	-- promised. It retained the receipt and cleared the token but armed
	-- nothing, so the "immediate re-mint" waited out the batching cadence —
	-- fifteen seconds under the new default. Bounded like the event plane's:
	-- the SECOND 401 for the same receipt paces on the backoff, or an
	-- endpoint answering 401 forever mints a token every frame.
	reset()
	storage.reset()
	next_status = 401
	parked = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(parked:identify("user-401"))
	assert_true(parked:set_consent(true))
	assert_true(parked.consent_outbox ~= nil and #parked.consent_outbox > 0,
		"the premise: the 401 retains the receipt")
	assert_equal(parked:consent_send_deferred(), false,
		"the first 401 is a stale-token race: it re-mints at once rather than backing off")
	assert_equal(parked.flush_elapsed_seconds, parked.config.flush_interval_seconds,
		"and it must be WOKEN to do so, not left to the flush cadence")
	parked:update(0)
	assert_true(parked:consent_send_deferred(),
		"a second 401 for the same receipt means the fresh token did not help: pace it")

	-- Retry-After: 0 is an explicit "retry now". The transport accepts it as
	-- a valid non-negative delay, and both planes used to fall through to the
	-- one-second first-failure backoff this PR introduced.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 429
	next_response_headers = { ["retry-after"] = "0" }
	parked = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(parked:identify("user-zero"))
	assert_true(parked:track("retry_after_zero_event"))
	assert_equal(parked:flush(), false)
	next_response_headers = nil
	assert_equal(parked:publish_deferred(), false,
		"a server saying 'retry now' must not be answered with our own backoff")
	assert_equal(parked.flush_elapsed_seconds, parked.config.flush_interval_seconds,
		"and the retry must be woken for the next tick")

	-- The same zero on the CONSENT plane, which is its own branch.
	reset()
	storage.reset()
	next_status = 429
	next_response_headers = { ["retry-after"] = "0" }
	parked = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(parked:identify("user-zero-consent"))
	assert_true(parked:set_consent(true))
	next_response_headers = nil
	assert_true(parked.consent_outbox ~= nil and #parked.consent_outbox > 0,
		"the premise: the 429 retains the receipt")
	assert_equal(parked:consent_send_deferred(), false,
		"a server saying 'retry now' must not be answered with the receipt's own backoff")
	assert_equal(parked.flush_elapsed_seconds, parked.config.flush_interval_seconds,
		"and the receipt's retry must be woken for the next tick")

	-- A retained batch inside its own backoff must not re-trigger the
	-- full-queue flush every frame. The retained batch is dispatched first so
	-- the queue cannot drain, and the automatic flush is refused inside the
	-- window: neither side changes, and flush() ran on every tick for a
	-- window approaching 60 seconds. flush() zeroes the elapsed clock, so the
	-- clock itself is the witness — under the defect it never accumulates.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 503
	parked = assert(sdk.new(config({ flush_interval_seconds = 9999, batch_size = 2 })))
	assert_true(parked:identify("user-spin"))
	assert_true(parked:track("spin_first_event"))
	assert_equal(parked:flush(), false)
	assert_true(parked.in_flight_batch ~= nil, "the premise: the 503 retains the batch")
	assert_true(parked:publish_deferred(), "the premise: and arms its own window")
	assert_true(parked:track("spin_queued_1"))
	assert_true(parked:track("spin_queued_2"))
	parked.flush_elapsed_seconds = 0
	parked:update(0.1)
	parked:update(0.1)
	parked:update(0.1)
	assert_true(parked.flush_elapsed_seconds > 0.25,
		"the full queue behind a deferred retained batch must not flush every frame: "
			.. "elapsed = " .. tostring(parked.flush_elapsed_seconds))

	-- The CONSENT plane holds the queue the same way: an undispatched grant
	-- blocks every event leg by design, so while that receipt sits inside its
	-- own window the queue cannot drain either — and a server Retry-After
	-- there runs to 24 hours, not 60 seconds.
	reset()
	storage.reset()
	next_status = 503
	parked = assert(sdk.new(config({ flush_interval_seconds = 9999, batch_size = 2 })))
	assert_true(parked:identify("user-grant-spin"))
	assert_true(parked:set_consent(true))
	assert_true(parked:consent_send_deferred(), "the premise: the grant receipt is inside its window")
	assert_true(parked:grant_receipt_pending_dispatch(),
		"the premise: and an undispatched grant holds the event legs")
	assert_true(parked:track("grant_spin_queued_1"))
	assert_true(parked:track("grant_spin_queued_2"))
	parked.flush_elapsed_seconds = 0
	parked:update(0.1)
	parked:update(0.1)
	parked:update(0.1)
	assert_true(parked.flush_elapsed_seconds > 0.25,
		"the full queue behind a deferred GRANT must not flush every frame either: "
			.. "elapsed = " .. tostring(parked.flush_elapsed_seconds))

	-- A first 401 taken on an explicit flush that BYPASSED a live client
	-- backoff must not have its wake blocked by that superseded deadline.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 503
	parked = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(parked:identify("user-bypass"))
	assert_true(parked:track("bypass_401_event"))
	assert_equal(parked:flush(), false, "a transient failure arms OUR backoff")
	assert_true(parked:publish_deferred(), "the premise: a client-owned window is live")
	assert_equal(parked:publish_server_deferred(), false, "the premise: and it is ours, not the server's")
	next_status = 401
	assert_equal(parked:flush(), false, "an explicit flush bypasses our own backoff and takes the 401")
	assert_equal(parked:publish_deferred(), false,
		"the superseded client deadline must be cleared, or the promised immediate "
			.. "authenticated retry waits out a window approaching 60 seconds")
	assert_equal(parked.flush_elapsed_seconds, parked.config.flush_interval_seconds,
		"and the retry is woken for the next tick")
	storage.reset()
end

-- L1 §6: the { error: { code, message, details } } envelope on a non-2xx is
-- parsed and surfaced (error.code + detail codes), not just the bare status.
local function test_error_envelope_is_surfaced()
	reset()
	storage.reset()
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
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
	seed_granted_consent()
	local backend = assert(sdk.new(config({ source = "backend" })))
	assert_true(backend:identify("user-example"))
	assert_true(backend:track("backend_event"))
	assert_equal(backend.session_id, nil)
	assert_true(backend:flush())
	assert_equal(#requests, 1)
	assert_not_contains(requests[1].body, '"session_id"')
	storage.reset()
end

-- ── offline event spool ──────────────────────────────────────────────────────

-- Install an in-test durable sys persistence layer (the same technique as the
-- identity persistence tests) backed by a `stores` table. Returns the table
-- and a restore function.
local function install_stub_sys_storage()
	local stores = {}
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
	return stores, function()
		sys.get_save_file = nil
		sys.save = nil
		sys.load = nil
	end
end

local function stored_spool_record(stores)
	for path, record in pairs(stores) do
		if path:sub(-6) == "/spool" then
			return record, path
		end
	end
	return nil
end

local spool_scope = { workspace_id = "workspace-example", app_id = "app-example" }

-- A transiently failed batch is spooled durably with its envelopes verbatim; a
-- later launch re-sends it byte-for-byte (same event_id / event_ts) through the
-- normal publish machinery and clears the record only after the 2xx ack.
local function test_spool_persists_transient_failure_and_resends_next_launch()
	reset()
	storage.reset()
	seed_granted_consent()
	local stores, restore = install_stub_sys_storage()

	next_status = 500
	local first = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(first:identify("user-example"))
	assert_true(first:track("offline_event", { level = 3 }))
	assert_equal(first:flush(), false)
	assert_equal(#requests, 1)
	local failed_body = requests[1].body
	local sent = first.in_flight_batch.payload.events
	assert_equal(#sent, 1)
	local original_id = sent[1].event_id
	local original_ts = sent[1].event_ts

	local record = stored_spool_record(stores)
	assert_true(record ~= nil, "a transiently failed batch must be spooled durably")
	assert_equal(#record.events, 1)
	assert_equal(record.events[1].event_id, original_id, "the spool must keep the event_id verbatim")
	assert_equal(record.events[1].event_ts, original_ts, "the spool must keep the event_ts verbatim")
	assert_equal(first:snapshot().spooled, 1)

	-- "next launch": a fresh client re-sends the spooled envelope and clears
	-- the record after the server acknowledged it
	reset()
	local second = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(#second.spool_batches, 1)
	assert_true(second:flush())
	assert_equal(#requests, 1)
	assert_equal(requests[1].body, failed_body, "the re-sent payload must be the original envelopes verbatim")
	assert_contains(requests[1].body, '"event_id":"' .. original_id .. '"')
	assert_contains(requests[1].body, '"event_ts":"' .. original_ts .. '"')
	assert_contains(requests[1].body, '"event_name":"offline_event"')
	assert_equal(second:snapshot().spool_resent, 1)
	record = stored_spool_record(stores)
	assert_equal(#record.events, 0, "an acknowledged re-send must clear the spool record")

	assert_true(second:flush())
	assert_equal(#requests, 1, "a cleared spool must not re-send anything")
	restore()
	storage.reset()
end

-- Over the caps the OLDEST entries are evicted first (FIFO), for both the
-- entry-count cap and the approximate serialized-bytes cap.
local function test_spool_overflow_evicts_oldest_first()
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999, spool_max_events = 2 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("evict_one"))
	assert_true(client:track("evict_two"))
	assert_true(client:track("evict_three"))
	assert_equal(client:flush(), false)
	assert_equal(#client.spool_record, 2, "the count cap must hold")
	assert_equal(client.spool_record[1].event_name, "evict_two", "the oldest entry is evicted first")
	assert_equal(client.spool_record[2].event_name, "evict_three")
	assert_equal(client:snapshot().spool_evicted, 1)

	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local padded = string.rep("x", 1200)
	local bytes_client = assert(sdk.new(config({ flush_interval_seconds = 9999, spool_max_bytes = 2048 })))
	assert_true(bytes_client:identify("user-example"))
	assert_true(bytes_client:track("bytes_one", { pad = padded }))
	assert_true(bytes_client:track("bytes_two", { pad = padded }))
	assert_equal(bytes_client:flush(), false)
	assert_equal(#bytes_client.spool_record, 1, "the byte budget must evict the oldest entry")
	assert_equal(bytes_client.spool_record[1].event_name, "bytes_two")
	storage.reset()
end

-- A failed or garbled durable read discards the record and starts clean; the
-- spool never errors into game code.
local function test_spool_corrupted_record_starts_clean()
	reset()
	storage.reset()
	sys.get_save_file = function(application_id, file_name)
		return application_id .. "/" .. file_name
	end
	sys.save = function()
		return true
	end
	sys.load = function()
		error("corrupt save file")
	end
	-- Seeded through the in-memory shadow: the throwing sys.load falls back to
	-- it, so the client still starts granted and the spool path is exercised.
	-- The denial marker's shadow is seeded as affirmatively ABSENT the same
	-- way (a successful clear this session): an UNREADABLE marker with no
	-- shadow fails closed over a granted restore by design, which is not
	-- what this spool-corruption test is about. The consent OUTBOX gets the
	-- identical treatment for the identical reason -- it is the third denial
	-- witness and fails closed on an unreadable read the same way, so it is
	-- seeded as affirmatively EMPTY rather than left unreadable. Neither line
	-- weakens those guards; both keep this test about the spool. The guards
	-- themselves are asserted directly by the unreadable-consent-outbox test
	-- (declared inline in the registry at the foot of this file).
	seed_granted_consent()
	assert_true(storage.clear_consent_denial_marker(identity_scope))
	assert_true(storage.save_consent_outbox(identity_scope, {}))
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(#client.spool_batches, 0, "a throwing sys.load must start a clean spool")
	assert_true(client:identify("user-example"))
	assert_true(client:track("after_corruption"))
	assert_true(client:flush())

	-- The table-shaped garbage doubles as the identity record read (the same
	-- sys.load answers both paths), so it carries a granted consent — the
	-- spool payload itself stays garbled.
	local garbage = {
		"not-a-record",
		{ events = "not-a-list", consent_analytics = "granted" },
		{ events = { "junk", { event_id = 42 }, { no_event_id = true } }, consent_analytics = "granted" },
	}
	for _, record in ipairs(garbage) do
		storage.reset()
		seed_granted_consent()
		sys.load = function()
			return record
		end
		local survivor = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
		assert_equal(#survivor.spool_batches, 0, "a garbled spool record must start clean")
	end
	sys.get_save_file = nil
	sys.save = nil
	sys.load = nil
	storage.reset()
end

-- Consent recheck: a persisted denial clears the spool at load without
-- sending; a runtime set_consent(false) purges a live spool the same way.
local function test_spool_cleared_by_denied_consent()
	reset()
	storage.reset()
	assert_true(storage.save_spool(spool_scope, {
		{ event_id = "denied-e1", event_name = "stale_event", event_ts = "2026-01-01T00:00:00.000Z" },
	}, 500, 262144) ~= nil)
	assert_true(storage.save(spool_scope, { anonymous_id = "anon-denied", consent_analytics = "denied" }))

	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "denied")
	assert_equal(#client.spool_batches, 0, "a persisted denial must not load the spool")
	assert_equal(#storage.load_spool(spool_scope), 0, "a persisted denial must clear the spool at load")
	client:flush()
	assert_equal(#requests, 0, "nothing may be sent for a denied actor")

	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local live = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(live:identify("user-example"))
	assert_true(live:track("spooled_then_denied"))
	assert_equal(live:flush(), false)
	assert_equal(#live.spool_record, 1)
	next_status = 202
	assert_true(live:set_consent(false))
	assert_equal(#live.spool_record, 0)
	assert_equal(#storage.load_spool(spool_scope), 0, "set_consent(false) must purge the durable spool")
	storage.reset()
end

-- Consent-first: a fresh client (consent "unknown") transmits NOTHING — no
-- event enqueue, no publish, no spool write, no consent receipt — until an
-- explicit grant. Pre-consent events are dropped with a distinct error, not
-- held: no pre-consent data exists at rest.
local function test_consent_unknown_blocks_all_analytics_egress()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "unknown")
	assert_true(client:identify("user-example"))

	local ok, err = client:track("pre_consent_event")
	assert_equal(ok, false)
	assert_equal(err, "consent_unknown")
	ok, err = client:screen_view("menu")
	assert_equal(ok, false)
	assert_equal(err, "consent_unknown")
	ok, err = client:session_start()
	assert_equal(ok, false)
	assert_equal(err, "consent_unknown")
	assert_equal(#client.queue.items, 0, "nothing may be queued while consent is unknown")
	assert_equal(client.session_active, false, "the blocked session_start must roll back")
	assert_equal(client:snapshot().dropped, 3)

	-- flush / the update cadence / persist are clean no-ops: no publish, no
	-- consent receipt, no summary enqueue, no spool write.
	assert_true(client:flush())
	client:update(9999)
	assert_true(client:persist())
	assert_equal(#requests, 0, "zero analytics wire traffic while consent is unknown")
	-- The init-time purge writes an empty clear record; no EVENT may ever
	-- reach the offline spool while consent is unknown.
	local spool_record = stored_spool_record(stores)
	assert_true(spool_record == nil or #spool_record.events == 0,
		"nothing may be written to the offline spool")
	assert_equal(client:snapshot().dropped, 3, "the blocked cadence must not keep dropping summaries")

	-- an explicit grant opens the pipeline for FUTURE events only
	assert_true(client:set_consent(true))
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_contains(requests[1].body, '"categories":{"analytics":true}')
	assert_true(client:track("post_grant_event"))
	assert_true(client:flush())
	assert_equal(#requests, 2)
	assert_equal(requests[2].url, "http://localhost:8080/v1/events:batch")
	assert_contains(requests[2].body, '"event_name":"post_grant_event"')
	assert_not_contains(requests[2].body, "pre_consent_event")
	restore()

	-- an unknown-state client also tears down cleanly, with zero traffic
	reset()
	storage.reset()
	local silent = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(silent:identify("user-example"))
	silent:track("dropped_at_teardown")
	assert_true(silent:shutdown("app_final"), "an unknown-state shutdown completes with nothing to deliver")
	assert_equal(#requests, 0, "shutdown while unknown must not transmit")
	storage.reset()
end

-- Runtime samples are analytics data: signals observed while the pipeline is
-- closed (unknown or denied) are dropped, not held — the first summary after
-- a later grant must not carry pre-consent or denied-period activity.
local function test_blocked_period_samples_never_summarized()
	reset()
	storage.reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_equal(client.consent_state, "unknown")

	-- observed before any grant: dropped at the source
	client:observe_ping_ms(50)
	client:observe_ping_ms(70)
	client:observe_disconnect("pre_consent_drop")
	assert_true(client:set_consent(true))
	assert_true(client:flush())
	for _, request in ipairs(requests) do
		assert_not_contains(request.body, '"event_name":"network_summary"')
	end

	-- observed under the grant: summarized normally
	client:observe_ping_ms(60)
	assert_true(client:flush())
	local summarized = false
	for _, request in ipairs(requests) do
		if request.body:find('"event_name":"network_summary"', 1, true) then
			summarized = true
			assert_contains(request.body, '"ping_sample_count":1')
		end
	end
	assert_true(summarized, "post-grant samples must still summarize")

	-- samples gathered under a grant are dropped by a denial: a re-grant must
	-- not summarize pre-denial activity
	client:observe_ping_ms(80)
	assert_true(client:set_consent(false))
	assert_true(client:set_consent(true))
	reset()
	assert_true(client:flush())
	assert_equal(#requests, 0, "no summary may survive the denial")
	storage.reset()
end

-- Only a launch that starts with a persisted GRANT loads the spool. A spool
-- record found while consent reads "unknown" (no identity record — no
-- decision was ever persisted) cannot be proven to have been written under a
-- grant (a v0.5 install spooled while "unknown" was still open), so it is
-- purged at init instead of being held for a later grant: the grant opens
-- the pipeline for FUTURE events only.
local function test_consent_unknown_purges_unproven_spool_at_init()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	assert_true(storage.save_spool(spool_scope, {
		{
			event_id = "unknown-e1",
			event_name = "unproven_era_event",
			event_ts = "2026-01-01T00:00:00.000Z",
			anonymous_id = "anon-spool",
		},
	}, 500, 262144) ~= nil)

	local unknown_client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(unknown_client.consent_state, "unknown")
	assert_equal(#unknown_client.spool_batches, 0, "an unknown consent must not load the spool")
	assert_equal(unknown_client.spool_purge_pending, false)
	assert_equal(#stored_spool_record(stores).events, 0,
		"a spool with no provable grant behind it must be purged at init")
	assert_true(unknown_client:flush())
	assert_equal(#requests, 0, "nothing may re-send while consent is unknown")

	-- even after an explicit grant and a relaunch, the unproven envelopes are
	-- gone: the grant opened the pipeline for future events only
	assert_true(unknown_client:set_consent(true))
	reset()
	local granted_client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(granted_client.consent_state, "granted")
	assert_equal(#granted_client.spool_batches, 0, "nothing unproven survives to re-send under the grant")
	assert_true(granted_client:flush())
	assert_equal(#requests, 0)

	-- a spool written UNDER the grant still round-trips as before
	next_status = 500
	assert_true(granted_client:identify("user-example"))
	assert_true(granted_client:track("granted_era_event"))
	assert_equal(granted_client:flush(), false)
	next_status = 202
	reset()
	local relaunch = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(relaunch.consent_state, "granted")
	assert_equal(#relaunch.spool_batches, 1, "a granted launch loads the granted-era spool for re-send")
	assert_true(relaunch:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"event_name":"granted_era_event"')
	assert_equal(#stored_spool_record(stores).events, 0, "the acknowledged re-send clears the record")
	restore()
	storage.reset()
end

-- An identity record that FAILS to read resolves to "unknown", and unknown
-- purges at init like every non-granted state: the unreadable record may
-- have carried a denial whose spool purge is still owed, and init re-writes
-- the identity record without it — possibly pre-revocation envelopes must
-- not outlive the lost decision and re-send under a later grant.
local function test_identity_read_failure_purges_spool()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	assert_true(storage.save_spool(spool_scope, {
		{
			event_id = "lost-denial-e1",
			event_name = "pre_revocation_event",
			event_ts = "2026-01-01T00:00:00.000Z",
			anonymous_id = "anon-lost",
		},
	}, 500, 262144) ~= nil)
	assert_equal(#stored_spool_record(stores).events, 1)

	-- The identity record throws on read (the spool file reads fine); no
	-- in-process shadow exists to answer for it.
	local real_load = sys.load
	sys.load = function(path)
		if path:sub(-9) == "/identity" then
			error("unreadable identity record")
		end
		return real_load(path)
	end
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "unknown", "an unreadable identity record reads as unknown")
	assert_equal(#client.spool_batches, 0, "nothing may load for re-send")
	assert_equal(client.spool_purge_pending, false)
	assert_equal(#stored_spool_record(stores).events, 0,
		"an unreadable consent decision must not leave event data at rest")
	assert_true(client:flush())
	assert_equal(#requests, 0)

	-- Even after a later grant, the pre-revocation envelopes are gone.
	sys.load = real_load
	assert_true(client:set_consent(true))
	local relaunch = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(#relaunch.spool_batches, 0, "nothing survives to re-send under the new grant")
	restore()
	storage.reset()
end

-- A permanent reject on a spooled batch removes the entries (they would fail
-- forever), surfaces the durable drop via diagnostics, and never retries.
local function test_spool_permanent_reject_removes_entry_and_diagnoses()
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local first = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(first:identify("user-example"))
	assert_true(first:track("later_rejected"))
	assert_equal(first:flush(), false)
	assert_equal(#first.spool_record, 1)

	reset()
	next_status = 400
	local issues = {}
	local second = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	assert_equal(#second.spool_batches, 1)
	assert_equal(second:flush(), false)
	assert_equal(#requests, 1)
	assert_equal(second.in_flight_batch, nil, "a permanent reject must drop the batch")
	assert_equal(#second.spool_record, 0, "a permanent reject must remove the spooled entry")
	assert_equal(second:snapshot().dropped, 1)
	local spool_issue = nil
	for _, issue in ipairs(issues) do
		if issue.scope == "spool" then
			spool_issue = issue
		end
	end
	assert_true(spool_issue ~= nil, "the durable drop must surface via diagnostics")
	assert_equal(spool_issue.status, "dropped")
	assert_equal(spool_issue.code, "http_400")
	assert_equal(spool_issue.count, 1)

	next_status = 202
	assert_true(second:flush())
	assert_equal(#requests, 1, "a permanently rejected spool entry must not be retried")
	storage.reset()
end

-- shutdown() spools the undelivered remnant and completes the teardown (the
-- data is safe on disk); with the spool disabled the old wait contract holds.
local function test_shutdown_spools_undelivered_and_finalizes()
	reset()
	storage.reset()
	seed_granted_consent()
	local _, restore = install_stub_sys_storage()
	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())
	assert_true(client:track("undelivered_at_exit"))

	assert_true(client:shutdown("app_final"), "a durably spooled remnant must complete the teardown")
	assert_equal(client.initialized, false)
	local spooled = storage.load_spool(spool_scope)
	assert_equal(#spooled, 3, "session events and the tracked event must be spooled")
	local names = {}
	for _, env in ipairs(spooled) do
		names[env.event_name] = true
	end
	assert_true(names["undelivered_at_exit"] ~= nil)
	assert_true(names["session_end"] ~= nil)
	restore()

	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local manual = assert(sdk.new(config({ flush_interval_seconds = 9999, spool_enabled = false })))
	assert_true(manual:identify("user-example"))
	assert_true(manual:track("kept_in_memory"))
	local ok = manual:shutdown("app_final")
	assert_equal(ok, false, "spool_enabled=false keeps the old failed-shutdown contract")
	assert_equal(manual.initialized, true)
	assert_equal(#storage.load_spool(spool_scope), 0)
	next_status = 202
	assert_true(manual:shutdown("app_final"))
	storage.reset()
end

-- Full-queue shutdown, end to end: shutdown work must ride the durable spool
-- rather than drop. The summary events built by the final flush's
-- enqueue_summaries CONSUME the sampler state — when the still-full queue
-- refuses them, the built snapshots become OWED and the housekeeping passes
-- re-enqueue them (after the deferred session end) once the flush/spool
-- eviction frees room. Offline throughout (every publish 500s), everything —
-- queued event, session end, perf and network summaries — must land durably
-- on the spool, teardown must complete, and the next launch re-sends it all.
local function test_shutdown_full_queue_spools_session_end_and_summaries()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local client = assert(sdk.new(config({
		buffer_size = 1,
		flush_interval_seconds = 9999,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())
	-- The queue is now FULL (buffer_size = 1 holds app.session_started).
	-- Sample runtime signals so both summaries have data to summarize.
	client:update(0.016)
	client:update(0.020)
	client:observe_ping_ms(42)
	client:observe_disconnect("net_down")
	assert_equal(#client.queue.items, 1)

	assert_true(client:shutdown("app_final"),
		"a full queue with a durable spool must not wedge or fail teardown")
	assert_equal(client.initialized, false)
	assert_equal(client.session_active, false)
	assert_equal(#client.owed_summaries, 0, "no summary may stay owed past teardown")
	local record = stored_spool_record(stores)
	assert_true(record ~= nil)
	local spooled_names = {}
	for i = 1, #record.events do
		spooled_names[record.events[i].event_name] = true
	end
	assert_true(spooled_names["app.session_started"] ~= nil)
	assert_true(spooled_names["session_end"] ~= nil,
		"the deferred session end must ride the durable spool")
	assert_true(spooled_names["perf_summary"] ~= nil,
		"a full queue must not drop the exit perf summary — it rides the spool")
	assert_true(spooled_names["network_summary"] ~= nil,
		"a full queue must not drop the exit network summary — it rides the spool")

	-- Next launch, back online: the spooled remnant re-sends verbatim.
	reset()
	next_status = 202
	local relaunch = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(#relaunch.spool_batches > 0)
	assert_true(relaunch:flush())
	local resent = {}
	for i = 1, #requests do
		for name in string.gmatch(requests[i].body or "", '"event_name":"([^"]+)"') do
			resent[name] = true
		end
	end
	assert_true(resent["app.session_started"] ~= nil)
	assert_true(resent["session_end"] ~= nil)
	assert_true(resent["perf_summary"] ~= nil)
	assert_true(resent["network_summary"] ~= nil)
	assert_equal(#storage.load_spool(spool_scope), 0,
		"the acknowledged re-send clears the record")
	restore()
	storage.reset()
end

-- persist() snapshots queued events into the durable spool while the client
-- keeps running; a later acknowledged publish removes them (ack-based).
local function test_persist_snapshots_queue_while_running()
	reset()
	storage.reset()
	seed_granted_consent()
	local _, restore = install_stub_sys_storage()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("persisted_one"))
	assert_true(client:track("persisted_two"))
	local queued_ids = {}
	for i, event in ipairs(client.queue.items) do
		queued_ids[i] = event.event_id
	end

	assert_true(client:persist())
	assert_equal(#requests, 0, "persist must not publish")
	assert_equal(#client.queue.items, 2, "persist must keep the events queued")
	assert_equal(#client.spool_record, 2)
	assert_equal(client.spool_record[1].event_id, queued_ids[1])
	assert_equal(client.spool_record[2].event_id, queued_ids[2])
	assert_equal(client:snapshot().spooled, 2)

	-- a second persist appends nothing new (de-duplicated by event_id)
	assert_true(client:persist())
	assert_equal(#client.spool_record, 2)
	assert_equal(client:snapshot().spooled, 2)

	-- later successful delivery removes the entries (ack-based)
	assert_true(client:flush())
	assert_equal(#requests, 1)
	assert_equal(#client.spool_record, 0, "an acknowledged publish must remove persisted entries")
	assert_equal(#storage.load_spool(spool_scope), 0)

	local disabled = assert(sdk.new(config({ spool_enabled = false })))
	local ok, err = disabled:persist()
	assert_equal(ok, false)
	assert_equal(err, "spool_disabled")
	restore()
	storage.reset()
end

-- P2 review fix (round 1): persist() must make owed summaries durable. A
-- full-queue refusal turns a built perf/network summary into an owed entry
-- whose sampler window is already consumed; a focus-loss persist() that
-- snapshots only the queue/in-flight tail would report the tail durable
-- while a process death still loses both summaries. persist() now enqueues
-- owed entries when the queue has room and appends the still-refused ones
-- to the durable spool directly — a relaunch re-sends them verbatim
-- (original event_id / identity / session).
local function test_persist_captures_owed_summaries_across_relaunch()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local client = assert(sdk.new(config({
		buffer_size = 1,
		flush_interval_seconds = 9999,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:session_start())
	local original_session = client.session_id
	client:update(0.016)
	client:update(0.020)
	client:observe_ping_ms(42)
	assert_equal(#client.queue.items, 1)

	-- The flush builds both summaries against the FULL queue (they become
	-- owed) and fails the publish transiently (offline).
	assert_equal(client:flush(), false)
	assert_equal(#client.owed_summaries, 2, "both built summaries are owed")
	-- Refill the single-slot queue so the persist below cannot enqueue the
	-- owed entries — forcing the direct-spool arm.
	assert_true(client:track("filler_event"))
	local owed_ids = {}
	for i = 1, #client.owed_summaries do
		local event = client.owed_summaries[i].event
		owed_ids[event.event_name] = event.event_id
	end

	assert_true(client:persist(),
		"persist must succeed once the owed summaries are durably captured")
	assert_equal(#client.owed_summaries, 2,
		"direct-spooled entries stay owed in memory for live delivery")
	local record = stored_spool_record(stores)
	assert_true(record ~= nil)
	local spooled = {}
	for i = 1, #record.events do
		spooled[record.events[i].event_name] = record.events[i]
	end
	assert_true(spooled["perf_summary"] ~= nil,
		"persist must capture the owed perf summary durably")
	assert_true(spooled["network_summary"] ~= nil,
		"persist must capture the owed network summary durably")
	assert_equal(spooled["perf_summary"].event_id, owed_ids["perf_summary"],
		"the spooled copy is the owed envelope verbatim")
	assert_equal(spooled["network_summary"].event_id, owed_ids["network_summary"])
	assert_equal(spooled["perf_summary"].user_id, "user-example",
		"the spooled copy preserves the build-time actor")
	assert_equal(spooled["perf_summary"].session_id, original_session,
		"the spooled copy preserves the build-time session")

	-- A second persist appends nothing new (event_id-idempotent).
	local events_before = #record.events
	assert_true(client:persist())
	record = stored_spool_record(stores)
	assert_equal(#record.events, events_before,
		"repeated persists must not duplicate owed entries")

	-- Simulated process death + relaunch, back online: the spooled remnant
	-- re-sends and both summaries land on the wire.
	reset()
	local relaunch = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(#relaunch.spool_batches > 0)
	assert_true(relaunch:flush())
	local resent = {}
	for i = 1, #requests do
		for name in string.gmatch(requests[i].body or "", '"event_name":"([^"]+)"') do
			resent[name] = true
		end
	end
	assert_true(resent["perf_summary"] ~= nil,
		"the owed perf summary must land on the wire after the relaunch")
	assert_true(resent["network_summary"] ~= nil,
		"the owed network summary must land on the wire after the relaunch")
	restore()
	storage.reset()
end

-- P2 review fix (round 1): an owed summary replays under the identity it
-- was BUILT with. Mode A (no per-session credential): identify() after the
-- refusal proceeds, and the drained summary lands attributed to the
-- original user and session while post-switch events carry the new user.
-- (Round 2 re-choreography: flush() now drains owed summaries within the
-- same call, so the lingering owed state is produced the way production
-- produces it — an ASYNC publish settling between flushes.)
local function test_owed_summary_preserves_actor_across_identify_mode_a()
	reset()
	storage.reset()
	seed_granted_consent()
	local client = assert(sdk.new(config_mode_a({
		buffer_size = 1,
		flush_interval_seconds = 9999,
	})))
	assert_true(client:identify("user-alpha"))
	assert_true(client:session_start())
	local original_session = client.session_id
	client:update(0.016)
	client:update(0.020)

	-- The flush builds the perf summary against the FULL queue: it becomes
	-- owed, snapshotted under user-alpha; the queued session start goes on
	-- the wire and is HELD (async transport), so the flush truthfully
	-- reports pending work instead of success over the owed entry.
	local held, restore_http = hold_http_requests()
	local flush_ok, flush_err = client:flush()
	assert_equal(flush_ok, false,
		"flush must not report success while a summary stays owed")
	assert_equal(flush_err, "pending")
	assert_equal(#client.owed_summaries, 1, "the perf summary is owed")
	assert_equal(client.owed_summaries[1].event.user_id, "user-alpha",
		"the owed snapshot preserves the build-time actor")
	release_held_request(held)
	restore_http()
	assert_equal(client.in_flight_batch, nil)
	assert_equal(#client.owed_summaries, 1,
		"the async settle leaves the owed summary for the next flush")

	assert_true(client:identify("user-beta"),
		"Mode A has no per-session credential — the switch proceeds")
	assert_true(client:flush(), "the owed drain delivers under the old actor")
	assert_equal(#client.owed_summaries, 0,
		"the flush drains the owed summary in the same call")
	assert_true(client:track("post_switch_event"))
	assert_true(client:flush())

	local summary_user = nil
	local summary_session = nil
	local post_switch_user = nil
	for i = 1, #requests do
		local body = requests[i].body or ""
		if string.find(body, '"event_name":"perf_summary"', 1, true) then
			summary_user = string.match(body, '"user_id":"([^"]+)"')
			summary_session = string.match(body, '"session_id":"([^"]+)"')
		end
		if string.find(body, '"event_name":"post_switch_event"', 1, true) then
			post_switch_user = string.match(body, '"user_id":"([^"]+)"')
		end
	end
	assert_equal(summary_user, "user-alpha",
		"the owed summary must land attributed to the actor it was built under")
	assert_equal(summary_session, original_session,
		"the owed summary must keep its build-time session")
	assert_equal(post_switch_user, "user-beta",
		"post-switch events carry the new actor")
	storage.reset()
end

-- P2 review fix (round 1), Mode B arm: an owed summary snapshotted to
-- another verified user is undrained event work a credential minted for
-- the incoming user cannot vouch for — identify() refuses (events_pending,
-- the same pending-work family as queued/in-flight/spooled events) until
-- the owed entry drains; the drained summary lands under the original
-- actor and the switch then proceeds.
local function test_identify_refused_while_owed_summary_pending_mode_b()
	reset()
	storage.reset()
	seed_granted_consent()
	local client = assert(sdk.new(config({
		buffer_size = 1,
		flush_interval_seconds = 9999,
	})))
	assert_true(client:identify("user-alpha"))
	assert_true(client:session_start())
	client:update(0.016)
	client:update(0.020)

	-- Async transport: the flush parks the summary owed (full queue at build
	-- time), reports pending, and the held batch settles WITHOUT draining
	-- it — the production window between flushes.
	local held, restore_http = hold_http_requests()
	assert_equal(client:flush(), false)
	assert_equal(#client.owed_summaries, 1)
	release_held_request(held)
	restore_http()
	assert_equal(#client.queue.items, 0,
		"only the owed snapshot remains undrained")
	assert_equal(client.in_flight_batch, nil)

	local ok, err = client:identify("user-beta")
	assert_equal(ok, false,
		"Mode B must refuse the switch while an owed summary is snapshotted to another user")
	assert_equal(err, "events_pending")
	assert_equal(client.user_id, "user-alpha", "the refused switch must not apply")

	-- The host recourse: flush first (drains the owed summary under the
	-- original actor), then re-identify.
	assert_true(client:flush())
	assert_equal(#client.owed_summaries, 0)
	local summary_user = nil
	for i = 1, #requests do
		local body = requests[i].body or ""
		if string.find(body, '"event_name":"perf_summary"', 1, true) then
			summary_user = string.match(body, '"user_id":"([^"]+)"')
		end
	end
	assert_equal(summary_user, "user-alpha")
	assert_true(client:identify("user-beta"), "the drained pipeline admits the switch")
	storage.reset()
end

-- P2 review fix (round 1), Mode B rotation arm: owed summaries are pending
-- old-anon work that sits outside the queue (their built envelopes carry
-- the old anon verbatim), so set_anonymous_id refuses like it does for
-- queued/in-flight/spooled work until they drain.
local function test_set_anonymous_id_rejected_while_owed_summary_pending_mode_b()
	reset()
	storage.reset()
	seed_granted_consent()
	local client = assert(sdk.new(config({
		buffer_size = 1,
		flush_interval_seconds = 9999,
	})))
	assert_true(client:session_start())
	client:update(0.016)
	client:update(0.020)
	local original_anon = client.anonymous_id

	-- Async transport: the owed summary outlives the flush (held batch
	-- settles without draining it) — the state the rotation guard must see.
	local held, restore_http = hold_http_requests()
	assert_equal(client:flush(), false)
	assert_equal(#client.owed_summaries, 1)
	release_held_request(held)
	restore_http()
	assert_equal(#client.queue.items, 0)
	assert_equal(client.in_flight_batch, nil)

	local ok, err = client:set_anonymous_id("anon-rotated-example")
	assert_equal(ok, false,
		"Mode B must refuse rotation while an owed summary carries the old anon")
	assert_equal(err, "events_pending")
	assert_equal(client.anonymous_id, original_anon, "the refused rotation must not apply")

	assert_true(client:flush())
	assert_equal(#client.owed_summaries, 0)
	local summary_anon = nil
	for i = 1, #requests do
		local body = requests[i].body or ""
		if string.find(body, '"event_name":"perf_summary"', 1, true) then
			summary_anon = string.match(body, '"anonymous_id":"([^"]+)"')
		end
	end
	assert_equal(summary_anon, original_anon,
		"the drained summary carries the anon it was built under")
	assert_true(client:set_anonymous_id("anon-rotated-example"),
		"the drained pipeline admits the rotation")
	storage.reset()
end

-- P2 review fix (round 2): flush() treats newly owed summaries as ITS OWN
-- pending work. Building summaries against a full queue used to park them
-- owed while the same flush drained the queue and returned true — a Mode B
-- caller following the documented flush-then-re-identify recourse hit
-- events_pending right after a "successful" flush, and outside
-- shutdown/persist the built summary sat memory-only until another explicit
-- flush. The loop now re-drains owed entries into the room it frees and only
-- reports success once nothing stays owed. P3 fix pinned alongside: the
-- refuse→owe→deliver cycle counts the summary once as published, never as
-- dropped — the denial wipe is the one point where an owed summary counts
-- as a real loss.
local function test_flush_drains_owed_summaries_within_same_call()
	reset()
	storage.reset()
	seed_granted_consent()
	local client = assert(sdk.new(config({
		buffer_size = 1,
		flush_interval_seconds = 9999,
	})))
	assert_true(client:session_start())
	client:update(0.016)
	client:update(0.020)
	client:observe_ping_ms(42)
	assert_equal(#client.queue.items, 1, "the single-slot queue is full at build time")

	assert_true(client:flush(),
		"the flush is only successful once it drained what it built")
	assert_equal(#client.owed_summaries, 0,
		"no summary may stay owed past a successful flush")
	assert_equal(#client.queue.items, 0)
	local sent = {}
	for i = 1, #requests do
		for name in string.gmatch(requests[i].body or "", '"event_name":"([^"]+)"') do
			sent[name] = true
		end
	end
	assert_true(sent["app.session_started"] ~= nil)
	assert_true(sent["perf_summary"] ~= nil,
		"the refused perf summary must deliver within the same flush call")
	assert_true(sent["network_summary"] ~= nil,
		"the refused network summary must deliver within the same flush call")
	assert_equal(client:snapshot().dropped, 0,
		"owed retention must never leave the queue_full refusal counted dropped")
	assert_equal(client:snapshot().published, 3,
		"each summary counts exactly once, as published")
	-- The Mode B recourse, end to end: a successful flush leaves no owed
	-- work, so identify-after-flush proceeds immediately.
	assert_true(client:identify("user-after-flush"),
		"the documented flush-then-re-identify flow must succeed")

	-- The one terminal loss point still counts: a denial wipes an owed
	-- summary as a real drop. Park one owed via the async window, then deny.
	client:update(0.016)
	client:update(0.020)
	assert_true(client:track("refill_slot"))
	local held, restore_http = hold_http_requests()
	assert_equal(client:flush(), false)
	assert_equal(#client.owed_summaries, 1)
	assert_equal(client:snapshot().dropped, 0,
		"the owed snapshot is retention, not loss")
	release_held_request(held)
	restore_http()
	assert_true(client:set_consent(false))
	assert_equal(#client.owed_summaries, 0)
	assert_equal(client:snapshot().dropped, 1,
		"the denial wipe is where an owed summary becomes a counted drop")
	storage.reset()
end

-- P2 review fix (round 2): persist() captures the WHOLE remnant in one
-- durable write. Direct-spooling still-owed summaries in a second append
-- used to evict just-captured queue/in-flight envelopes on a near-full
-- spool (oldest first) while only the second write's own batch was
-- survivor-checked — a focus-loss persist reported durability over an
-- evicted remnant. One write sized against the caps as a whole either
-- captures everything or reports spool_persist_failed truthfully.
local function test_persist_single_write_keeps_whole_remnant_under_caps()
	-- Direction 1 — the remnant fits the caps: persist() claims durability
	-- and a relaunch re-sends every envelope it claimed.
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local client = assert(sdk.new(config({
		buffer_size = 1,
		flush_interval_seconds = 9999,
	})))
	assert_true(client:session_start())
	client:update(0.016)
	client:update(0.020)
	client:observe_ping_ms(42)
	assert_equal(client:flush(), false, "offline: the batch is retained")
	assert_equal(#client.owed_summaries, 2, "both built summaries are owed")
	assert_true(client:track("filler_event"))

	assert_true(client:persist(),
		"a remnant within the caps may be claimed durable")
	local record = stored_spool_record(stores)
	assert_true(record ~= nil)
	assert_equal(#record.events, 4,
		"one write captured in-flight + queue + both owed summaries")
	reset()
	local relaunch = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(relaunch:flush())
	local resent = {}
	for i = 1, #requests do
		for name in string.gmatch(requests[i].body or "", '"event_name":"([^"]+)"') do
			resent[name] = true
		end
	end
	assert_true(resent["app.session_started"] ~= nil,
		"nothing persist() claimed durable may be lost across the relaunch")
	assert_true(resent["filler_event"] ~= nil)
	assert_true(resent["perf_summary"] ~= nil)
	assert_true(resent["network_summary"] ~= nil)
	restore()
	storage.reset()

	-- Direction 2 — spool_max_events = 2 cannot hold the four-envelope
	-- remnant: appending the owed summaries evicts the just-captured
	-- queue/in-flight envelopes, so persist() must refuse to claim
	-- durability (pre-fix, the second append's own survivor check passed
	-- and the call returned success over the evicted remnant).
	reset()
	storage.reset()
	stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local capped = assert(sdk.new(config({
		buffer_size = 1,
		flush_interval_seconds = 9999,
		spool_max_events = 2,
	})))
	assert_true(capped:session_start())
	capped:update(0.016)
	capped:update(0.020)
	capped:observe_ping_ms(42)
	assert_equal(capped:flush(), false)
	assert_equal(#capped.owed_summaries, 2)
	assert_true(capped:track("filler_event"))

	local ok, err = capped:persist()
	assert_equal(ok, false,
		"a capped-out remnant must not be claimed durable")
	assert_equal(err, "spool_persist_failed")
	restore()
	storage.reset()
end

-- P1 (denial-marker gap, folded from the godot#1 round-10 fleet finding):
-- with a persisted grant on disk, a denial whose identity persist FAILED
-- only surfaced consent_persist_failed — an app exit before a successful
-- retry made the next init() restore GRANTED and events flowed against an
-- explicit revocation. set_consent now writes a write-ahead denial marker
-- BEFORE the identity write; init imposes a present marker over any
-- restored record for its actor, consolidates the record, and retires the
-- marker only once the record durably holds the denial.
local function test_denial_marker_imposes_over_stale_granted_record()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "granted")
	local actor = client.anonymous_id
	-- The identity write starts failing; the marker file still works.
	local real_save = sys.save
	sys.save = function(path, record)
		if path:sub(-9) == "/identity" then
			return false
		end
		return real_save(path, record)
	end
	local ok, err = client:set_consent(false)
	assert_equal(ok, false)
	assert_equal(err, "consent_persist_failed")
	local identity_path = nil
	local marker_record = nil
	for path, record in pairs(stores) do
		if path:sub(-9) == "/identity" then
			identity_path = path
		elseif path:sub(-15) == "/consent-denial" then
			marker_record = record
		end
	end
	assert_equal(stores[identity_path].consent_analytics, "granted",
		"the stale record still carries the pre-denial grant — the exact gap")
	assert_true(marker_record ~= nil and marker_record.consent_analytics == "denied",
		"the write-ahead marker durably witnesses the denial")
	assert_equal(marker_record.anonymous_id, actor,
		"the marker is scoped to the denying actor")

	-- Simulated app exit; storage heals for the next launch. The relaunch
	-- must impose the marker over the restored granted record.
	sys.save = real_save
	reset()
	local relaunch = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(relaunch.consent_state, "denied",
		"the marker must impose the denial over the stale granted record")
	local tok, terr = relaunch:track("post_denial_event")
	assert_equal(tok, false)
	assert_equal(terr, "consent_denied")
	-- Consolidation on that same boot: the record converged and the marker
	-- retired.
	assert_equal(stores[identity_path].consent_analytics, "denied",
		"consolidation must converge the identity record")
	local retired = nil
	for path, record in pairs(stores) do
		if path:sub(-15) == "/consent-denial" then
			retired = record
		end
	end
	assert_true(retired ~= nil and next(retired) == nil,
		"the healed record retires the marker")
	-- Relaunch after the heal: denied purely from the record, no marker.
	local third = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(third.consent_state, "denied",
		"after the heal the record alone carries the denial")
	restore()
	storage.reset()
end

-- P1 denial marker: the denied_forced_minor flavor survives the marker path
-- — the imposed boot state is the band-forced denial, not a generic one.
local function test_denial_marker_preserves_forced_minor_flavor()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	local real_save = sys.save
	sys.save = function(path, record)
		if path:sub(-9) == "/identity" then
			return false
		end
		return real_save(path, record)
	end
	local ok, err = client:set_consent("denied_forced_minor")
	assert_equal(ok, false)
	assert_equal(err, "consent_persist_failed")
	sys.save = real_save
	reset()
	local relaunch = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(relaunch.consent_state, "denied_forced_minor",
		"the marker must carry the denial flavor through the relaunch")
	restore()
	storage.reset()
end

-- P1 denial marker, actor scope: a marker witnesses ITS OWN actor's denial.
-- A fresh identity (configured override replacing a different persisted
-- actor) never inherits it — no manufactured decision — and the foreign
-- marker is NOT silently deleted while its own actor's record is
-- unresolved.
local function test_foreign_actor_denial_marker_stays_inert_and_undeleted()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	local old_anon = client.anonymous_id
	local real_save = sys.save
	sys.save = function(path, record)
		if path:sub(-9) == "/identity" then
			return false
		end
		return real_save(path, record)
	end
	local ok = client:set_consent(false)
	assert_equal(ok, false, "the denial persist fails, arming the marker")
	sys.save = real_save

	reset()
	local fresh = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		anonymous_id = "anon-override-fresh",
	})))
	assert_equal(fresh.consent_state, "unknown",
		"a foreign-actor marker must never manufacture a decision")
	local marker_record = nil
	for path, record in pairs(stores) do
		if path:sub(-15) == "/consent-denial" then
			marker_record = record
		end
	end
	assert_true(marker_record ~= nil and marker_record.consent_analytics == "denied",
		"the foreign marker must stay on disk for its own actor")
	assert_equal(marker_record.anonymous_id, old_anon)
	restore()
	storage.reset()
end

-- P1 denial marker, belt leg: a RETAINED (undelivered) denial receipt for
-- this actor stamped strictly newer than the restored record's decision
-- blocks a granted restore — the cheap cross-check for trails where the
-- marker is gone. Strictness pinned both ways: an older receipt (a
-- deny-then-grant whose denial receipt is still undelivered) never flips a
-- genuinely newer grant.
local function test_newer_denial_receipt_blocks_granted_restore()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-belt-example",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-01T00:00:00.000Z",
	}))
	assert_true(storage.save_consent_outbox(identity_scope, { {
		idempotency_key = "belt-denial-key",
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "anon-belt-example",
		kind = "anon",
		decided_at = "2026-07-02T00:00:00.000Z",
		categories = { analytics = false },
		reason = "denied_forced_minor",
		anonymous_id = "anon-belt-example",
	} }) ~= false)
	local client = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "denied_forced_minor",
		"a strictly newer retained denial receipt must block the granted restore")
	local tok, terr = client:track("post_belt_event")
	assert_equal(tok, false)
	assert_equal(terr, "consent_denied")
	local identity_record = nil
	for path, record in pairs(stores) do
		if path:sub(-9) == "/identity" then
			identity_record = record
		end
	end
	assert_true(identity_record ~= nil
			and identity_record.consent_analytics == "denied_forced_minor",
		"the belt converges the record for the next boot")
	restore()
	storage.reset()

	-- Counter-direction: the same receipt against a NEWER grant stamp.
	reset()
	storage.reset()
	stores, restore = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-belt-example",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-03T00:00:00.000Z",
	}))
	assert_true(storage.save_consent_outbox(identity_scope, { {
		idempotency_key = "belt-denial-key",
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "anon-belt-example",
		kind = "anon",
		decided_at = "2026-07-02T00:00:00.000Z",
		categories = { analytics = false },
		anonymous_id = "anon-belt-example",
	} }) ~= false)
	local granted_client = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(granted_client.consent_state, "granted",
		"an older denial receipt must not flip a genuinely newer grant")
	restore()
	storage.reset()
end

-- Godot round-11 parity (P1 tie-break): clock.iso_utc is SECOND-precision,
-- so a grant→denial inside one second used to leave the belt's
-- strictly-newer stamp comparison unable to break the tie when the denial's
-- marker AND record writes both failed — relaunch restored the stale grant
-- over the denial's only durable evidence, its retained receipt. The
-- monotonic decision seq breaks the tie fail-closed, and the mint floor
-- restored from retained receipts keeps a subsequent same-second re-grant
-- strictly above the denial, so the newest decision stays in charge
-- through the whole tie chain.
local function test_same_second_denial_tie_imposes_fail_closed()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	local clock = require "shardpilot.clock"
	local real_iso = clock.iso_utc
	local frozen = real_iso()
	clock.iso_utc = function() return frozen end
	-- Receipts must stay RETAINED (undelivered) — they are the denial's only
	-- durable witness in this scenario.
	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:set_consent(true), "the grant records and persists")
	-- Same second: the denial's marker AND record writes both fail; only the
	-- receipt append lands.
	local real_save = sys.save
	sys.save = function(path, record)
		if path:sub(-9) == "/identity" or path:sub(-15) == "/consent-denial" then
			return false
		end
		return real_save(path, record)
	end
	local ok, err = client:set_consent(false)
	assert_equal(ok, false)
	assert_equal(err, "consent_persist_failed")
	sys.save = real_save
	local identity_path = nil
	for path in pairs(stores) do
		if path:sub(-9) == "/identity" then
			identity_path = path
		end
	end
	assert_equal(stores[identity_path].consent_analytics, "granted",
		"the stale record still carries the same-second pre-denial grant — the exact tie")
	assert_equal(stores[identity_path].consent_decided_at, frozen,
		"the tie is real: both decisions share the second-precision stamp")
	-- Simulated exit + relaunch over healed storage: the retained receipt's
	-- higher decision seq must impose the denial over the same-stamp grant.
	reset()
	next_status = 500
	local relaunch = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(relaunch.consent_state, "denied",
		"the same-second denial must impose fail-closed via its higher seq")
	local tok, terr = relaunch:track("post_tie_event")
	assert_equal(tok, false)
	assert_equal(terr, "consent_denied")
	assert_equal(stores[identity_path].consent_analytics, "denied",
		"the belt converges the record with the denial's pair")
	-- The mint floor restored from the retained receipts: a STILL
	-- same-second re-grant mints strictly above the denial's seq and
	-- outranks it at the next boot.
	assert_true(relaunch:set_consent(true), "the same-second re-grant records")
	reset()
	next_status = 500
	local third = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(third.consent_state, "granted",
		"the re-grant's higher seq keeps the newest decision in charge")
	clock.iso_utc = real_iso
	restore()
	storage.reset()
end

-- The counter-directions of the tie-break: a same-stamp denial receipt with
-- a LOWER seq (an undelivered deny superseded by a same-second re-grant
-- whose record landed) must NOT flip the grant, and legacy same-stamp data
-- (no seq anywhere — both sides backfill 0) keeps the pre-seq strict-stamp
-- no-impose outcome.
local function test_same_second_regrant_outranks_undelivered_denial()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-tie-example",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-04T00:00:00Z",
		consent_decision_seq = 2,
	}))
	assert_true(storage.save_consent_outbox(identity_scope, { {
		idempotency_key = "tie-denial-key",
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "anon-tie-example",
		kind = "anon",
		decided_at = "2026-07-04T00:00:00Z",
		decision_seq = 1,
		categories = { analytics = false },
		anonymous_id = "anon-tie-example",
	} }) ~= false)
	local client = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "granted",
		"a same-stamp denial with a LOWER seq must not flip the re-granted record")
	restore()
	storage.reset()

	reset()
	storage.reset()
	stores, restore = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-tie-example",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-04T00:00:00Z",
	}))
	assert_true(storage.save_consent_outbox(identity_scope, { {
		idempotency_key = "tie-legacy-key",
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "anon-tie-example",
		kind = "anon",
		decided_at = "2026-07-04T00:00:00Z",
		categories = { analytics = false },
		anonymous_id = "anon-tie-example",
	} }) ~= false)
	local legacy = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(legacy.consent_state, "granted",
		"legacy same-stamp data keeps the pre-seq strict-stamp outcome")
	restore()
	storage.reset()
end

-- Codex #40 round 3: a marker from an earlier denial whose grant-side
-- retirement failed used to be imposed UNCONDITIONALLY at the next boot,
-- overriding the newer successfully-persisted grant. The imposition now
-- compares decision pairs: a marker the record strictly supersedes is
-- retired, never imposed; the genuine direction (marker pair newer) still
-- imposes.
local function test_stale_denial_marker_never_beats_newer_grant()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-stale-marker",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-05T00:00:00Z",
		consent_decision_seq = 2,
	}))
	assert_true(storage.save_consent_denial_marker(identity_scope, {
		consent_analytics = "denied",
		anonymous_id = "anon-stale-marker",
		decided_at = "2026-07-05T00:00:00Z",
		decision_seq = 1,
	}))
	local client = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "granted",
		"a stale denial marker must never override a newer durable grant")
	local marker = storage.load_consent_denial_marker(identity_scope)
	assert_true(type(marker) ~= "table" or next(marker) == nil,
		"the superseded marker is retired at boot")
	restore()
	storage.reset()

	-- The genuine direction stays imposed: the marker pair strictly newer
	-- than the record's (same second, higher seq).
	reset()
	storage.reset()
	stores, restore = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-stale-marker",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-05T00:00:00Z",
		consent_decision_seq = 1,
	}))
	assert_true(storage.save_consent_denial_marker(identity_scope, {
		consent_analytics = "denied",
		anonymous_id = "anon-stale-marker",
		decided_at = "2026-07-05T00:00:00Z",
		decision_seq = 2,
	}))
	local imposed = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(imposed.consent_state, "denied",
		"a genuinely newer same-second marker still imposes")
	restore()
	storage.reset()
end

-- Codex #40 round 3: the unreadable-marker fail-closed state is memory-only
-- by design — but the anonymous-id self-heal rewrite used to persist it,
-- durably overwriting a real granted record off an unreadable file. The
-- rewrite is now skipped while the unreadable imposition is in effect; the
-- heal re-runs once the marker is readable again.
local function test_unreadable_marker_fail_closed_stays_transient()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = string.rep("x", 600),
		consent_analytics = "granted",
	}))
	assert_true(storage.save_consent_denial_marker(identity_scope, {
		consent_analytics = "granted",
		anonymous_id = "anon-not-a-denial",
	}))
	local client = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "denied",
		"an unreadable/malformed marker fails closed over the granted restore")
	local tok, terr = client:track("gated_event")
	assert_equal(tok, false)
	assert_equal(terr, "consent_denied")
	local identity_record = nil
	for path, record in pairs(stores) do
		if path:sub(-9) == "/identity" then
			identity_record = record
		end
	end
	assert_true(identity_record ~= nil
			and identity_record.consent_analytics == "granted",
		"the transient fail-closed state never rewrites the granted record — not even through the anon self-heal")
	-- The marker heals: the next launch restores the real grant and
	-- completes the deferred self-heal.
	assert_true(storage.clear_consent_denial_marker(identity_scope))
	reset()
	local healed = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(healed.consent_state, "granted",
		"the healed launch restores the real decision — the imposition was transient")
	restore()
	storage.reset()
end


-- Codex #40 round 4 (P1): a denial receipt whose POST is IN FLIGHT used to
-- satisfy the shutdown witness check — but its own acknowledgment prunes it
-- from the durable outbox, possibly after teardown already finalized on its
-- evidence, leaving the stale granted record alone for the next launch. An
-- in-flight receipt no longer witnesses; the shutdown refusal holds until a
-- settled witness (record, marker, or a retained NON-in-flight receipt)
-- exists.
local function test_shutdown_refuses_while_witness_receipt_in_flight()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-inflight-witness",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-07T00:00:00Z",
		consent_decision_seq = 1,
	}))
	local client = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "granted")
	-- Break BOTH denial writes, hold the wire: the receipt appends durably
	-- and goes IN FLIGHT with no other witness anywhere.
	local real_save = sys.save
	sys.save = function(path, record)
		if path:sub(-9) == "/identity" or path:sub(-15) == "/consent-denial" then
			return false
		end
		return real_save(path, record)
	end
	local held, restore_http = hold_http_requests()
	local ok, err = client:set_consent(false)
	assert_equal(ok, false)
	assert_equal(err, "consent_persist_failed")
	assert_equal(#held, 1, "the denial receipt is on the wire")
	-- The in-flight receipt must NOT count as the denial's durable witness:
	-- shutdown stays refusable until a settled witness exists.
	local sok, serr = client:shutdown()
	assert_equal(sok, false,
		"shutdown must refuse while the only witness is in flight")
	assert_equal(serr, "consent_pending")
	-- The ack lands with storage still broken: the receipt leaves the
	-- outbox, the handoff marker attempt fails, the pendings stay armed —
	-- shutdown keeps refusing over the witness gap.
	release_held_request(held)
	restore_http()
	local sok2, serr2 = client:shutdown()
	assert_equal(sok2, false, "no witness landed anywhere — still refused")
	assert_equal(serr2, "consent_pending")
	-- Storage heals: the shutdown retry persists the record and finalizes.
	sys.save = real_save
	assert_true(client:shutdown(), "the healed retry persists the denial and finalizes")
	local identity_record = nil
	for path, record in pairs(stores) do
		if path:sub(-9) == "/identity" then
			identity_record = record
		end
	end
	assert_true(identity_record ~= nil and identity_record.consent_analytics == "denied",
		"the denial is durable at teardown")
	restore()
	storage.reset()
end

-- Codex #40 round 4 (P1, the handoff half): when the ack prunes a denial
-- receipt while the record AND marker writes are still owed, the prune
-- consumes the only durable evidence — so the ack path now retries the
-- marker write (the CURRENT decision's pair) before removing the receipt.
local function test_ack_prune_hands_witness_to_marker()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- NB the harness clock starts near the epoch, so the live-minted
	-- denial's stamp must be able to EXCEED the seeded record stamp — a
	-- 2026 seed here would make the round-3 stale-marker guard (correctly)
	-- retire the handed-off marker as record-superseded.
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-handoff-witness",
		consent_analytics = "granted",
		consent_decided_at = "1970-01-01T00:00:01Z",
		consent_decision_seq = 1,
	}))
	local client = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	local real_save = sys.save
	sys.save = function(path, record)
		if path:sub(-9) == "/identity" or path:sub(-15) == "/consent-denial" then
			return false
		end
		return real_save(path, record)
	end
	local held, restore_http = hold_http_requests()
	local ok, err = client:set_consent(false)
	assert_equal(ok, false)
	assert_equal(err, "consent_persist_failed")
	-- The marker path heals while the POST is on the wire (the identity
	-- store stays broken): the ack's handoff must land the marker before
	-- consuming the receipt.
	sys.save = function(path, record)
		if path:sub(-9) == "/identity" then
			return false
		end
		return real_save(path, record)
	end
	release_held_request(held)
	restore_http()
	local marker = storage.load_consent_denial_marker(identity_scope)
	assert_true(type(marker) == "table" and marker.consent_analytics == "denied",
		"the ack handoff writes the marker before pruning the receipt")
	assert_equal(#storage.load_consent_outbox(identity_scope), 0,
		"the acknowledged receipt left the durable outbox")
	-- Simulated process death (no shutdown); full heal; relaunch: the
	-- marker — the handed-off witness — imposes the denial over the stale
	-- granted record.
	sys.save = real_save
	reset()
	local relaunch = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(relaunch.consent_state, "denied",
		"the handed-off marker imposes the denial after the receipt is gone")
	restore()
	storage.reset()
end

-- Codex #40 round 3: when the belt's convergence write fails, the retained
-- denial receipt — the decision's only durable proof — still dispatches and
-- leaves the outbox, so the next launch would restore the stale grant with
-- no witness anywhere. The failed convergence now writes the write-ahead
-- marker (with the receipt's decision pair) as the receipt-independent
-- witness and arms the shutdown pending flags.
local function test_belt_convergence_failure_writes_marker_witness()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-belt-witness",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-06T00:00:00Z",
		consent_decision_seq = 1,
	}))
	assert_true(storage.save_consent_outbox(identity_scope, { {
		idempotency_key = "belt-witness-denial",
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "anon-belt-witness",
		kind = "anon",
		decided_at = "2026-07-06T00:00:01Z",
		decision_seq = 2,
		categories = { analytics = false },
		anonymous_id = "anon-belt-witness",
	} }) ~= false)
	-- The identity store is broken at boot: the belt imposes the denial,
	-- its convergence write fails, and the receipt delivers (202) and
	-- leaves the outbox.
	local real_save = sys.save
	sys.save = function(path, record)
		if path:sub(-9) == "/identity" then
			return false
		end
		return real_save(path, record)
	end
	local client = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "denied",
		"the belt imposes the retained denial")
	local marker = storage.load_consent_denial_marker(identity_scope)
	assert_true(type(marker) == "table" and marker.consent_analytics == "denied"
			and marker.decision_seq == 2,
		"the failed convergence writes the marker witness carrying the receipt's pair")
	local outbox = storage.load_consent_outbox(identity_scope)
	assert_equal(#outbox, 0, "the delivered receipt left the durable outbox")
	local identity_record = nil
	for path, record in pairs(stores) do
		if path:sub(-9) == "/identity" then
			identity_record = record
		end
	end
	assert_true(identity_record ~= nil and identity_record.consent_analytics == "granted",
		"the stale granted record still sits on disk — the marker is the only witness left")
	-- Heal and relaunch: the marker imposes the denial and converges.
	sys.save = real_save
	reset()
	local relaunch = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(relaunch.consent_state, "denied",
		"the marker witness imposes the denial after the receipt is gone")
	restore()
	storage.reset()
end

-- P1 denial marker, teardown leg: shutdown() refuses (consent_pending
-- family) while the latest denial has NO durable witness anywhere — record
-- write failed, marker write failed, and the receipt already delivered and
-- left the outbox (a delivered receipt proves nothing to the next boot).
-- The refusal retries both writes first, so a recovered store converges and
-- finalizes. Residual, documented: a process KILL before any durable write
-- lands is data-free loss no client-side ordering can close.
local function test_shutdown_refuses_denial_with_no_durable_witness()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "granted")
	-- Identity AND marker writes fail; the outbox works, and the receipt
	-- DELIVERS (202) — so it leaves the outbox and nothing durable
	-- witnesses the denial.
	local real_save = sys.save
	sys.save = function(path, record)
		if path:sub(-9) == "/identity" or path:sub(-15) == "/consent-denial" then
			return false
		end
		return real_save(path, record)
	end
	local ok, err = client:set_consent(false)
	assert_equal(ok, false)
	assert_equal(err, "consent_persist_failed")
	assert_equal(#client.consent_outbox, 0,
		"the receipt delivered and left the outbox")

	local down, derr = client:shutdown("app_final")
	assert_equal(down, false,
		"shutdown must refuse a denial with no durable witness")
	assert_equal(derr, "consent_pending")

	-- Storage recovers: the shutdown retry converges the record, retires
	-- the marker debt, and finalizes.
	sys.save = real_save
	assert_true(client:shutdown("app_final"),
		"the retried teardown lands the record and completes")
	local identity_record = nil
	for path, record in pairs(stores) do
		if path:sub(-9) == "/identity" then
			identity_record = record
		end
	end
	assert_true(identity_record ~= nil
			and identity_record.consent_analytics == "denied",
		"the retried teardown must leave the denial durable")
	restore()
	storage.reset()
end

-- Mode B anon rotation waits for pending spooled work the same way it waits
-- for queued/in-flight events: the spooled envelopes carry the historic anon.
local function test_set_anonymous_id_rejected_while_spool_pending_mode_b()
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local first = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(first:identify("user-example"))
	assert_true(first:track("spooled_before_rotation"))
	assert_equal(first:flush(), false)

	reset()
	local second = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(#second.spool_batches, 1)
	local ok, err = second:set_anonymous_id("anon-rotated")
	assert_equal(ok, false)
	assert_equal(err, "events_pending")

	assert_true(second:flush())
	assert_equal(#second.spool_batches, 0)
	assert_true(second:set_anonymous_id("anon-rotated"), "rotation allowed once the spool drained")
	assert_equal(second:get_anonymous_id(), "anon-rotated")

	-- Mode A has no token binding, so rotation stays allowed while spooled
	-- work is pending (the guard must not over-restrict).
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local seeder = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_true(seeder:identify("user-example"))
	assert_true(seeder:track("spooled_mode_a"))
	assert_equal(seeder:flush(), false)
	reset()
	local mode_a = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(#mode_a.spool_batches, 1)
	assert_true(mode_a:set_anonymous_id("anon-a-rotated"), "Mode A allows rotation while the spool is pending")
	storage.reset()
end

-- When the caps evict part of the remnant being captured itself (not just
-- older entries), the capture is NOT complete — shutdown() must keep the old
-- failure contract instead of finalizing over silently lost events.
local function test_shutdown_fails_when_remnant_evicted_by_caps()
	reset()
	storage.reset()
	seed_granted_consent()
	local _, restore = install_stub_sys_storage()
	local client = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		spool_max_events = 1,
		token_provider = function(callback)
			-- no token: the final flush cannot deliver, forcing the spool path
			callback(nil, nil, "token unavailable")
		end,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:track("evicted_one"))
	assert_true(client:track("evicted_two"))

	-- the remnant is [evicted_one, evicted_two, session_end]; the 1-entry cap
	-- keeps only the newest (session_end), so the capture is incomplete
	local ok = client:shutdown("app_final")
	assert_equal(ok, false, "an evicted remnant must not report durable capture")
	assert_equal(client.initialized, true)
	assert_equal(client:snapshot().spooled, 1, "only the surviving envelope counts as spooled")
	assert_equal(client:snapshot().spool_evicted, 2)
	local leftover = storage.load_spool(spool_scope)
	assert_equal(#leftover, 1, "the cap holds; the newest envelope survived")
	assert_equal(leftover[1].event_name, "session_end")

	-- the in-memory copy is intact: recovery delivers everything and clears
	client.config.token_provider = function(callback)
		callback("late-token", nil, nil)
	end
	assert_true(client:shutdown("app_final"))
	assert_equal(#storage.load_spool(spool_scope), 0)
	restore()
	storage.reset()
end

-- Mode B tokens bind the CURRENT anonymous ID, so an init-time anonymous_id
-- override drops spooled envelopes carrying the previous identity (they would
-- be rejected on every re-send); Mode A keeps and re-sends them unchanged.
-- The in-spool identity drop applies to GRANTED launches whose anonymous id
-- changed without an override mismatch (a config override replacing a
-- different persisted actor boots a FRESH identity and purges the spool
-- outright — test_anonymous_override_mismatch_boots_fresh_identity). The
-- reachable trigger here is the identity self-heal: a stored anonymous id
-- that fails validation (corrupt/oversized) is replaced by a fresh mint
-- while this install's persisted grant restores — under Mode B the historic
-- envelopes could never send (the minted token binds the CURRENT anon) and
-- drop at load; Mode A has no token binding and re-sends them verbatim.
local function test_spool_identity_mismatch_dropped_mode_b_kept_mode_a()
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local first = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(first:track("historic_anon_event"))
	assert_equal(first:flush(), false)
	assert_equal(#first.spool_record, 1)
	-- Corrupt the persisted anonymous id (oversized fails validation); the
	-- persisted grant survives, so the healed launch is still granted.
	local corrupt = storage.load(identity_scope) or {}
	corrupt.anonymous_id = string.rep("x", 513)
	assert_true(storage.save(identity_scope, corrupt))

	reset()
	local issues = {}
	local second = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	assert_equal(second.consent_state, "granted",
		"the self-healed launch restores this install's decision")
	assert_not_equal(second.anonymous_id, first.anonymous_id)
	assert_equal(#second.spool_batches, 0, "mismatched envelopes must not load for re-send")
	assert_equal(#storage.load_spool(spool_scope), 0, "mismatched envelopes must leave the record")
	assert_equal(#issues, 1)
	assert_equal(issues[1].scope, "spool")
	assert_equal(issues[1].status, "dropped")
	assert_equal(issues[1].code, "identity_changed")
	assert_equal(issues[1].count, 1)
	assert_true(second:flush())
	assert_equal(#requests, 0, "nothing re-sends after the identity change")

	-- Mode A: no token binding — historic-identity envelopes re-send verbatim
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local seeder = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_true(seeder:track("historic_mode_a_event"))
	assert_equal(seeder:flush(), false)
	local historic_anon = seeder.anonymous_id
	local corrupt_a = storage.load(identity_scope) or {}
	corrupt_a.anonymous_id = string.rep("y", 513)
	assert_true(storage.save(identity_scope, corrupt_a))
	reset()
	local mode_a = assert(sdk.new(config_mode_a({
		flush_interval_seconds = 9999,
	})))
	assert_equal(mode_a.consent_state, "granted")
	assert_equal(#mode_a.spool_batches, 1, "Mode A keeps historic-identity envelopes")
	assert_true(mode_a:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"anonymous_id":"' .. historic_anon .. '"')
	assert_contains(requests[1].body, '"event_name":"historic_mode_a_event"')
	storage.reset()
end

-- Without the save-file API the spool falls back to process memory, which is
-- NOT durable: shutdown()/persist() must keep the old failure contract even
-- with the spool enabled.
local function test_shutdown_without_durable_backend_keeps_old_contract()
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("memory_only_event"))
	local ok = client:shutdown("app_final")
	assert_equal(ok, false, "a memory-only spool write is not durable capture")
	assert_equal(client.initialized, true)

	local persist_ok, persist_err = client:persist()
	assert_equal(persist_ok, false)
	assert_equal(persist_err, "spool_persist_failed")

	-- in-process recovery still works: the retained batch delivers and clears
	next_status = 202
	assert_true(client:shutdown("app_final"))
	assert_equal(client.initialized, false)
	storage.reset()
end

-- Disabling the spool clears a record persisted by an earlier configuration:
-- nothing lingers on disk, and a later re-enable starts clean.
local function test_disabled_spool_clears_persisted_record_at_init()
	reset()
	storage.reset()
	local _, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local seeder = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(seeder:track("left_on_disk"))
	assert_equal(seeder:flush(), false)
	assert_equal(#storage.load_spool(spool_scope), 1)

	reset()
	local disabled = assert(sdk.new(config({ flush_interval_seconds = 9999, spool_enabled = false })))
	assert_equal(#disabled.spool_batches, 0)
	assert_equal(#storage.load_spool(spool_scope), 0, "disabling the spool must clear the persisted record")

	reset()
	local reenabled = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(#reenabled.spool_batches, 0, "a re-enabled spool starts clean")
	assert_true(reenabled:flush())
	assert_equal(#requests, 0)
	restore()
	storage.reset()
end

-- Break sys.save for spool writes only (identity writes keep working) and
-- return a function that heals it.
local function break_spool_saves()
	local real_save = sys.save
	local broken = true
	sys.save = function(path, record)
		if broken and path:sub(-6) == "/spool" then
			return false
		end
		return real_save(path, record)
	end
	return function()
		broken = false
	end
end

-- A failed durable purge at set_consent(false) must be reported, leave the
-- spool fail-closed, and be retried at later dispatch points until it lands.
local function test_set_consent_denied_reports_failed_spool_purge_and_retries()
	reset()
	storage.reset()
	local _, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("purge_me"))
	assert_equal(client:flush(), false)
	assert_equal(#storage.load_spool(spool_scope), 1)

	local heal = break_spool_saves()
	next_status = 202
	local ok, err = client:set_consent(false)
	assert_equal(ok, false)
	assert_equal(err, "spool_purge_failed")
	assert_equal(client.spool_purge_pending, true)
	assert_equal(#storage.load_spool(spool_scope), 1, "the record is still on disk")
	assert_equal(#client.spool_record, 0, "the in-memory spool is already cleared")
	assert_equal(#client.spool_batches, 0, "nothing may be pending for re-send")

	-- fail-closed: persist() reports the owed purge instead of touching the spool
	local persist_ok, persist_err = client:persist()
	assert_equal(persist_ok, false)
	assert_equal(persist_err, "spool_purge_failed")

	-- storage recovers: the next dispatch point (update-driven flush) lands it
	heal()
	client:update(client.config.flush_interval_seconds)
	assert_equal(client.spool_purge_pending, false)
	assert_equal(#storage.load_spool(spool_scope), 0, "the retried purge cleared the record")
	restore()
	storage.reset()
end

-- A failed purge at init (persisted denial) must never load or re-send the
-- record, and must keep retrying the purge until storage recovers.
local function test_init_purge_failure_fails_closed_and_retries()
	reset()
	storage.reset()
	local _, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local seeder = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(seeder:track("stale_after_denial"))
	assert_equal(seeder:flush(), false)
	assert_true(storage.save(spool_scope, { anonymous_id = seeder.anonymous_id, consent_analytics = "denied" }))

	reset()
	local heal = break_spool_saves()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "denied")
	assert_equal(client.spool_purge_pending, true)
	assert_equal(#client.spool_batches, 0, "a pending purge must never load the record")
	assert_equal(#client.spool_record, 0)
	client:flush()
	assert_equal(#requests, 0, "nothing may re-send while a purge is owed")
	assert_equal(#storage.load_spool(spool_scope), 1, "the record survives until the purge lands")

	heal()
	client:update(client.config.flush_interval_seconds)
	assert_equal(client.spool_purge_pending, false)
	assert_equal(#storage.load_spool(spool_scope), 0, "the retried init purge cleared the record")
	restore()
	storage.reset()
end

-- A failed ack-removal rewrite keeps the settled entries pending (mirror and
-- disk) and retries the rewrite at the next dispatch point, so the record
-- converges as soon as storage recovers.
local function test_failed_ack_removal_keeps_entries_and_retries_rewrite()
	reset()
	storage.reset()
	local _, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("acked_later"))
	assert_equal(client:flush(), false)
	assert_equal(#client.spool_record, 1)

	-- the batch is acknowledged but the removal rewrite fails
	local heal = break_spool_saves()
	next_status = 202
	assert_true(client:flush(), "the publish itself succeeded")
	assert_equal(#requests, 2)
	assert_equal(client.spool_rewrite_pending, true)
	assert_equal(#client.spool_record, 1, "the mirror keeps the settled entry while removal is pending")
	assert_equal(#storage.load_spool(spool_scope), 1, "the entry is still on disk")

	-- storage recovers: the retried rewrite settles the entry without waiting
	-- for an unrelated write or the next launch
	heal()
	client:update(client.config.flush_interval_seconds)
	assert_equal(client.spool_rewrite_pending, false)
	assert_equal(#client.spool_record, 0)
	assert_equal(#storage.load_spool(spool_scope), 0, "the retried rewrite removed the settled entry")
	restore()
	storage.reset()
end

-- The CURRENT caps are reapplied to a previously persisted record at load: a
-- lowered budget trims the oldest entries, durably.
local function test_loaded_record_reapplies_current_caps()
	reset()
	storage.reset()
	local _, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local seeder = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(seeder:identify("user-example"))
	assert_true(seeder:track("cap_one"))
	assert_true(seeder:track("cap_two"))
	assert_true(seeder:track("cap_three"))
	assert_equal(seeder:flush(), false)
	assert_equal(#storage.load_spool(spool_scope), 3)

	reset()
	local lowered = assert(sdk.new(config({ flush_interval_seconds = 9999, spool_max_events = 1 })))
	assert_equal(#lowered.spool_record, 1, "the lowered cap trims the loaded record")
	assert_equal(lowered.spool_record[1].event_name, "cap_three", "the oldest entries are trimmed first")
	assert_equal(lowered:snapshot().spool_evicted, 2)
	assert_equal(#lowered.spool_batches, 1)
	assert_equal(#lowered.spool_batches[1], 1)
	local disk = storage.load_spool(spool_scope)
	assert_equal(#disk, 1, "the trim is durable")
	assert_equal(disk[1].event_name, "cap_three")
	restore()
	storage.reset()
end

-- A 429 Retry-After on a spooled batch stores the deadline with the record; a
-- relaunch inside the window defers the startup resend, an expired deadline
-- does not.
local function test_persisted_retry_after_defers_startup_resend()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 429
	next_response_headers = { ["retry-after"] = "600" }
	local first = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(first:identify("user-example"))
	assert_true(first:track("backpressured_event"))
	assert_equal(first:flush(), false)
	next_response_headers = nil
	local record = stored_spool_record(stores)
	assert_true(record ~= nil)
	assert_equal(#record.events, 1)
	assert_true(type(record.retry_after_until_ms) == "number", "the Retry-After deadline must be stored")
	assert_true(record.retry_after_until_ms > math.floor(socket.now * 1000), "the stored deadline lies in the future")

	-- relaunch inside the window: the startup resend waits it out
	reset()
	local second = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(#second.spool_batches, 1)
	assert_true(second:publish_deferred(), "a still-future stored deadline must defer the resend")
	assert_equal(second:flush(), false)
	assert_equal(#requests, 0, "no resend inside the server-requested window")

	-- once the window passes, the resend proceeds and the ack clears the record
	second.publish_retry_after_ms = nil
	assert_true(second:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"event_name":"backpressured_event"')
	assert_equal(#storage.load_spool(spool_scope), 0)

	-- an EXPIRED stored deadline does not delay the startup resend
	reset()
	storage.reset()
	assert_true(storage.save_spool(spool_scope, {
		{ event_id = "expired-e1", event_name = "expired_deadline_event", anonymous_id = "anon-x" },
	}, 500, 262144, 1000) ~= nil)
	local third = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(#third.spool_batches, 1)
	assert_true(not third:publish_deferred(), "an expired stored deadline must not defer")
	assert_true(third:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"event_name":"expired_deadline_event"')

	-- A shorter server Retry-After arriving while a LONGER client backoff is
	-- already armed must persist the SERVER's own deadline, not the effective
	-- wait. The two diverge exactly there: defer_publish keeps the later of
	-- the pair as the effective window, so persisting that stores a deadline
	-- the server never asked for — and the loader restores whatever it finds
	-- as SERVER-owned, which is the one kind an explicit flush may not
	-- bypass. A relaunch would then hold explicit flushes off for the
	-- remainder of OUR backoff, on the server's authority (Codex on #46).
	--
	-- Folded in here rather than given its own function because the file is
	-- at Lua's 200-local ceiling for a main chunk, and this is the same
	-- subject: what the spool record's deadline means.
	reset()
	storage.reset()
	next_status = 500
	local backed_off = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(backed_off:identify("user-example"))
	assert_true(backed_off:track("backoff_then_hint_event"))
	assert_equal(backed_off:flush(), false)
	assert_true(backed_off.publish_retry_after_ms ~= nil, "a hint-less failure arms a client backoff")

	-- Stretch OUR backoff well past anything the server is about to ask for.
	local client_deadline = math.floor(socket.now * 1000) + 60000
	backed_off.publish_retry_after_ms = client_deadline

	-- An explicit flush bypasses a client-owned window; this one comes back
	-- with a much shorter server instruction.
	next_status = 429
	next_response_headers = { ["retry-after"] = "2" }
	assert_equal(backed_off:flush(), false)
	next_response_headers = nil

	assert_true(backed_off.publish_server_retry_after_ms ~= nil, "the server hint is recorded")
	assert_true(backed_off.publish_retry_after_ms >= client_deadline,
		"the effective wait is still the longer client backoff")
	assert_equal(backed_off.spool_retry_after_ms, backed_off.publish_server_retry_after_ms,
		"the record must carry the SERVER deadline, not the effective one")
	local overlapped = stored_spool_record(stores)
	assert_true(overlapped ~= nil)
	assert_true(overlapped.retry_after_until_ms < client_deadline,
		"persisting the effective deadline relaunches a client backoff as a server instruction")

	-- The relaunch is where that costs something: the restored deadline is
	-- server-owned by construction, so it holds explicit flushes off for
	-- exactly as long as the SERVER asked, and no longer.
	reset()
	local relaunched = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(#relaunched.spool_batches, 1)
	assert_true(relaunched.publish_server_retry_after_ms ~= nil,
		"the stored deadline restores as server-owned")
	assert_true(relaunched.publish_server_retry_after_ms < client_deadline,
		"the relaunch inherited our own backoff window as a server instruction")
	restore()
	storage.reset()
end

-- The denied/disabled init purge must run even when the record cannot be
-- read: a failed/corrupt read is not "nothing to purge" — the stale file
-- would otherwise survive and replay after a later grant/re-enable.
local function test_init_purge_runs_even_when_record_unreadable()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local seeder = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(seeder:track("stale_unreadable"))
	assert_equal(seeder:flush(), false)
	assert_equal(#stored_spool_record(stores).events, 1)
	assert_true(storage.save(spool_scope, { anonymous_id = seeder.anonymous_id, consent_analytics = "denied" }))

	-- clear the in-memory shadow and make the spool file unreadable, so a
	-- read-gated purge would see "nothing" while the stale file persists
	storage.reset()
	local real_load = sys.load
	sys.load = function(path)
		if path:sub(-6) == "/spool" then
			error("unreadable spool file")
		end
		return real_load(path)
	end
	reset()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "denied")
	assert_equal(client.spool_purge_pending, false)
	assert_equal(#stored_spool_record(stores).events, 0,
		"the stale record must be purged even when it cannot be read")
	sys.load = real_load
	restore()
	storage.reset()
end

-- A grant while a purge from an earlier revocation is still owed must not be
-- applied: the pending flag is memory-only, and a persisted grant would let a
-- relaunch replay the pre-revocation record. Revocation cleanup completes
-- before a new grant takes effect.
local function test_grant_blocked_until_owed_purge_lands()
	reset()
	storage.reset()
	local _, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("pre_denial_event"))
	assert_equal(client:flush(), false)

	local heal = break_spool_saves()
	next_status = 202
	local ok, err = client:set_consent(false)
	assert_equal(ok, false)
	assert_equal(err, "spool_purge_failed")
	assert_equal(#requests, 2, "the denial receipt is still reported")

	-- the grant is refused while the purge is owed; the persisted decision
	-- stays denied and no grant receipt goes out
	ok, err = client:set_consent(true)
	assert_equal(ok, false)
	assert_equal(err, "spool_purge_failed")
	assert_equal(client.consent_state, "denied", "the grant must not be applied")
	assert_equal(storage.load(spool_scope).consent_analytics, "denied",
		"the persisted decision must stay denied")
	assert_equal(#requests, 2, "no grant receipt while the purge is owed")

	-- a relaunch before the purge lands stays fail-closed: the persisted
	-- denial re-runs the purge at init and never loads the record
	local relaunch = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(relaunch.consent_state, "denied")
	assert_equal(relaunch.spool_purge_pending, true)
	assert_equal(#relaunch.spool_batches, 0)

	-- storage recovers: the grant retries the purge, lands it, and applies
	heal()
	ok, err = client:set_consent(true)
	assert_true(ok, err)
	assert_equal(client.consent_state, "granted")
	assert_equal(client.spool_purge_pending, false)
	assert_equal(#storage.load_spool(spool_scope), 0)
	assert_equal(storage.load(spool_scope).consent_analytics, "granted")
	assert_equal(#requests, 3, "the applied grant is reported")
	restore()
	storage.reset()
end

-- A terminal rejection during the final flush drops the batch, so there is
-- nothing to spool: shutdown must surface the failure instead of finalizing
-- through a vacuously successful capture of nothing. A repeated shutdown()
-- call still completes teardown (the queue is already clean).
local function test_shutdown_surfaces_terminal_failure_not_vacuous_spool()
	reset()
	storage.reset()
	local _, restore = install_stub_sys_storage()
	seed_granted_consent()
	next_status = 400
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("terminally_rejected"))

	local ok = client:shutdown("app_final")
	assert_equal(ok, false, "a terminal final-flush failure must not report a clean teardown")
	assert_equal(client.initialized, true)
	assert_equal(#storage.load_spool(spool_scope), 0, "a permanent reject is never spooled")
	assert_equal(client:snapshot().dropped, 2, "the tracked event and session_end were dropped")
	assert_equal(#requests, 1)

	-- retrying shutdown completes normally, as before the spool existed
	next_status = 202
	assert_true(client:shutdown("app_final"))
	assert_equal(client.initialized, false)
	assert_equal(#requests, 1, "nothing is left to send on the retry")
	restore()
	storage.reset()
end

-- ── consent-receipt outbox + denied_forced_minor ─────────────────────────────

local function stored_consent_outbox_record(stores)
	for path, record in pairs(stores) do
		if path:sub(-15) == "/consent-outbox" then
			return record, path
		end
	end
	return nil
end

-- AC-8 (consent & age-gate UX spec §7/§10): in a forced-minor session the
-- ONLY analytics-plane request permitted on the wire is the
-- denied_forced_minor receipt POST to /v1/consent — asserted as EXACTLY one
-- captured request across init, the decision, gameplay-shaped SDK usage,
-- update ticks, flush, session teardown, and shutdown; zero batch requests.
local function test_ac8_forced_minor_sole_request_is_the_receipt()
	reset()
	storage.reset()
	-- init dark: no persisted decision — a consent-first client transmits
	-- nothing at construction
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-minor"))
	assert_equal(#requests, 0, "a dark init must produce zero requests")

	assert_true(client:set_consent("denied_forced_minor"))
	assert_equal(client.consent_state, "denied_forced_minor")

	-- the rest of the forced-minor session: everything analytics stays closed
	local ok, err = client:track("match_started")
	assert_equal(ok, false)
	assert_equal(err, "consent_denied", "forced minor gates exactly like denied")
	ok, err = client:session_start()
	assert_equal(ok, false)
	assert_equal(err, "consent_denied")
	client:observe_ping_ms(42)
	client:observe_disconnect("net_drop")
	client:update(client.config.flush_interval_seconds)
	client:update(client.config.flush_interval_seconds)
	assert_true(client:flush())
	assert_true(client:session_end("minor_session_end"))
	assert_true(client:shutdown("app_final"))

	-- exactly ONE request left the device: the consent receipt
	assert_equal(#requests, 1, "the sole permitted analytics-plane request is the receipt POST")
	local receipt = requests[1]
	assert_equal(receipt.url, "http://localhost:8080/v1/consent")
	assert_equal(receipt.method, "POST")
	assert_contains(receipt.body, '"categories":{"analytics":false}')
	assert_contains(receipt.body, '"reason":"denied_forced_minor"')
	assert_contains(receipt.body, '"actor_identifier":"user-minor"')
	assert_contains(receipt.body, '"kind":"user_verified"')
	assert_contains(receipt.body, '"idempotency_key":"')
	assert_contains(receipt.body, '"decided_at":"')
	-- the retention-metadata anon snapshot stored on the outbox entry never
	-- reaches the wire
	assert_not_contains(receipt.body, '"anonymous_id"')
	for _, request in ipairs(requests) do
		assert_not_contains(request.url, "/v1/events:batch")
	end
	assert_equal(client:snapshot().consent_recorded, 1)
	storage.reset()
end

-- denied_forced_minor is persisted, reloads as the same state, discards a
-- retained batch when it lands mid-flight, purges the durable spool exactly
-- like a denial, and a later explicit choice (the spec §6 band-correction
-- path) supersedes it with a fresh, reason-less receipt.
local function test_forced_minor_persists_and_gates_like_denied()
	reset()
	storage.reset()
	seed_granted_consent()
	local _, restore = install_stub_sys_storage()

	next_status = 500
	local first = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(first:identify("user-example"))
	assert_true(first:track("pre_minor_event"))
	assert_equal(first:flush(), false)
	assert_true(first.in_flight_batch ~= nil, "the transient failure retains the batch")
	assert_equal(#first.spool_record, 1, "the transient failure spools the batch")

	next_status = 202
	assert_true(first:set_consent("denied_forced_minor"))
	assert_equal(first.in_flight_batch, nil, "a forced-minor denial discards the retained batch")
	assert_equal(#storage.load_spool(spool_scope), 0, "a forced-minor denial purges the durable spool")
	assert_equal(requests[#requests].url, "http://localhost:8080/v1/consent")
	assert_contains(requests[#requests].body, '"reason":"denied_forced_minor"')

	-- "next launch": the persisted forced-minor state reloads and keeps gating
	reset()
	local second = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(second.consent_state, "denied_forced_minor")
	local ok, err = second:track("still_blocked")
	assert_equal(ok, false)
	assert_equal(err, "consent_denied")
	assert_equal(#second.spool_batches, 0, "no spool may load under a forced-minor init")
	assert_equal(#requests, 0, "a forced-minor launch with an empty outbox transmits nothing")

	-- only the exact forced-minor string is a valid decision
	ok, err = second:set_consent("denied")
	assert_equal(ok, false)
	assert_equal(err, "invalid_consent")

	-- the band-correction path: a later explicit grant supersedes the forced
	-- state; its receipt carries no reason
	assert_true(second:set_consent(true))
	assert_equal(second.consent_state, "granted")
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"categories":{"analytics":true}')
	assert_not_contains(requests[1].body, '"reason"')
	restore()
	storage.reset()
end

-- The outbox's core durability contract: a receipt that could not be
-- delivered (500s / network errors) survives process death, re-sends at the
-- next init VERBATIM (same idempotency_key), keeps retrying with backoff, is
-- delivered even while the persisted consent state is DENIED (a receipt
-- documents the decision itself — consent-plane egress, not analytics), and
-- leaves the durable record the moment the server acknowledges it.
local function test_consent_receipt_survives_restart_and_retries_until_acked()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()

	next_status = 500
	local first = assert(sdk.new(config()))
	-- Anon-keyed on purpose: a user_verified receipt would park on the
	-- pre-identify relaunches below; this test pins the restart/retry/ack
	-- mechanics themselves.
	assert_true(first:set_consent(false))
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	local record = stored_consent_outbox_record(stores)
	assert_true(record ~= nil, "an undelivered receipt must be durably retained")
	assert_equal(#record.receipts, 1)
	local original_key = record.receipts[1].idempotency_key
	assert_equal(record.receipts[1].categories.analytics, false)
	assert_equal(record.receipts[1].kind, "anon")

	-- "next launch": init re-attempts delivery immediately — while the
	-- persisted state is denied
	reset()
	next_status = 500
	local second = assert(sdk.new(config()))
	assert_equal(second.consent_state, "denied")
	assert_equal(#requests, 1, "init must re-attempt the retained receipt")
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_contains(requests[1].body, '"idempotency_key":"' .. original_key .. '"',
		"the receipt re-sends verbatim")
	assert_equal(#second.consent_outbox, 1, "a failed re-send stays retained")
	assert_equal(second.consent_backoff_attempt, 1)
	-- The first failure arms the receipt's own window now (A6). It armed
	-- nothing before, which meant the retry happened whenever the next
	-- dispatch point came round — the flush tick, in practice — so the
	-- receipt's schedule described nothing.
	assert_true(second:consent_send_deferred(), "the first failure defers on the receipt's own clock")

	-- a second consecutive failure (network error this time) backs off
	next_status = 0
	socket.now = socket.now + 2
	second:update(0)
	assert_equal(#requests, 2)
	assert_equal(second:snapshot().last_consent_error, "http_0")
	assert_equal(second.consent_backoff_attempt, 2)
	assert_true(second:consent_send_deferred(), "sustained receipt failures back off")
	second:update(second.config.flush_interval_seconds)
	assert_equal(#requests, 2, "an open backoff window must hold the retry")

	-- recovery: the acknowledged receipt is pruned from the durable record
	second.consent_retry_after_ms = nil
	next_status = 202
	second:update(second.config.flush_interval_seconds)
	assert_equal(#requests, 3)
	assert_equal(second:snapshot().consent_recorded, 1)
	assert_equal(second.consent_backoff_attempt, 0)
	assert_equal(#second.consent_outbox, 0)
	record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 0, "an acknowledged receipt must leave the durable record")

	second:update(second.config.flush_interval_seconds)
	assert_equal(#requests, 3, "nothing replays after the prune")
	restore()
	storage.reset()
end

-- With a durable backend, an undelivered receipt no longer blocks teardown:
-- it is safe on disk (that durability is the outbox's point), so shutdown()
-- completes and the next launch delivers it. Hosts without durable storage
-- keep the consent_pending contract (test_shutdown_waits_for_deferred_consent).
local function test_shutdown_completes_with_durable_outbox_and_next_launch_delivers()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			callback(nil, nil, "token backend down")
		end,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:set_consent(true))
	assert_equal(#requests, 0, "no token — nothing dispatched")
	assert_equal(#client.consent_outbox, 1)

	assert_true(client:shutdown("app_final"), "a durably retained receipt must not block teardown")
	assert_equal(client.initialized, false)
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1, "the receipt survives teardown on disk")

	-- next launch (working token backend): the verified-keyed receipt stays
	-- parked until the session vouches for its actor; identify() delivers it
	reset()
	local second = assert(sdk.new(config()))
	assert_equal(#requests, 0, "a verified receipt stays parked before identify")
	assert_true(second:identify("user-example"))
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_contains(requests[1].body, '"categories":{"analytics":true}')
	assert_equal(second:snapshot().consent_recorded, 1)
	record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 0)
	restore()
	storage.reset()
end

-- Gate scoping (audit 3a follow-up): a durably retained grant receipt parked
-- in a server-requested Retry-After window must NOT block teardown when there
-- is nothing to publish — the receipt is safe on disk and re-sends at the
-- next launch, exactly like any other durably retained receipt.
local function test_shutdown_completes_with_only_deferred_grant_receipt()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	next_status = 503
	next_response_headers = { ["retry-after"] = "30" }
	client:set_consent(true)
	assert_equal(#requests, 1)
	assert_true(client:consent_send_deferred(), "the receipt is parked in the server window")
	-- No events queued: the deferred durable receipt alone must not hold
	-- shutdown hostage for the window.
	next_status = 202
	next_response_headers = nil
	assert_true(client:shutdown(), "a durably retained deferred receipt must not block teardown")
	assert_equal(client.initialized, false)
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1, "the receipt survives teardown on disk")
	restore()
	storage.reset()
end

-- Audit 3a follow-up (toggling): an in-flight head grant releases the gate
-- only for itself. With grant→deny→grant queued before the first receipt
-- settles, the LATER grant is still undispatched — events tracked under the
-- second grant must wait until that receipt's own handoff, or they would
-- overtake the deny+grant pair on the wire.
local function test_toggled_grant_behind_in_flight_head_still_holds_events()
	reset()
	storage.reset()
	local original_request = http.request
	local callbacks = {}
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		callbacks[#callbacks + 1] = callback
	end
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	client:set_consent(true) -- dispatched, in flight
	assert_equal(#requests, 1)
	client:set_consent(false) -- queued behind the in-flight head
	client:set_consent(true) -- queued behind the deny
	assert_equal(#requests, 1)
	assert_true(client:track("post_toggle_event"))

	-- The head grant is in flight, but the SECOND grant is undispatched:
	-- the batch stays held.
	local flushed, reason = client:flush()
	assert_equal(flushed, false)
	assert_equal(reason, "consent_receipt_pending")
	assert_equal(#requests, 1, "no batch while the toggled grant awaits dispatch")

	-- Head settles; the chained drain hands over the deny, then the grant.
	callbacks[1](nil, nil, { status = 202, response = "{}" })
	assert_equal(#requests, 2)
	assert_contains(requests[2].body, '"analytics":false')
	local mid_flushed, mid_reason = client:flush()
	assert_equal(mid_flushed, false)
	assert_equal(mid_reason, "consent_receipt_pending")
	assert_equal(#requests, 2, "still held while the deny is in flight and the grant queued")
	callbacks[2](nil, nil, { status = 202, response = "{}" })
	assert_equal(#requests, 3)
	assert_contains(requests[3].body, '"analytics":true')

	-- The second grant is now in flight (unacknowledged): the batch follows.
	local publish_flushed, publish_reason = client:flush()
	assert_equal(publish_flushed, false)
	assert_equal(publish_reason, "pending")
	assert_equal(#requests, 4)
	assert_true(requests[4].url:find("/v1/events:batch", 1, true) ~= nil, "the batch follows the dispatched second grant")
	callbacks[3](nil, nil, { status = 202, response = "{}" })
	callbacks[4](nil, nil, { status = 202, response = '{"accepted":1}' })
	http.request = original_request
	storage.reset()
end

-- Audit 3a follow-up (restart): a relaunch mid-window reloads the durable
-- outbox but no deferral state — the gate needs none: the retained
-- verified-keyed grant is handed to the transport the moment the session
-- vouches for its actor again (identify() is that dispatch point; until
-- then it is parked), ahead of anything the fresh process can publish, so
-- the first post-restart batch always follows the receipt on the wire (and
-- is never ack-gated on it).
local function test_restart_dispatches_retained_grant_before_first_batch()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- First launch: the grant receipt is held by a server Retry-After and
	-- the app closes with the receipt durably retained.
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	next_status = 503
	next_response_headers = { ["retry-after"] = "3600" }
	client:set_consent(true)
	assert_equal(#requests, 1)
	next_status = 202
	next_response_headers = nil
	assert_true(client:shutdown())
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1, "the deferred grant survives on disk")

	-- Relaunch (async transport): the verified receipt stays parked until
	-- the session vouches for its actor; identify() hands it over first.
	reset()
	local original_request = http.request
	local callbacks = {}
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		callbacks[#callbacks + 1] = callback
	end
	local second = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_equal(#requests, 0, "a verified receipt stays parked until the session vouches for it")
	assert_true(second:identify("user-example"))
	assert_equal(#requests, 1, "identify hands the retained grant to the transport")
	assert_true(requests[1].url:find("/v1/consent", 1, true) ~= nil)
	assert_true(second:track("post_restart_event"), "the persisted grant reopens the pipeline")
	local flushed, reason = second:flush()
	assert_equal(flushed, false)
	assert_equal(reason, "pending")
	assert_equal(#requests, 2, "the first batch follows the already-dispatched receipt")
	assert_true(requests[2].url:find("/v1/events:batch", 1, true) ~= nil)
	callbacks[1](nil, nil, { status = 202, response = "{}" })
	callbacks[2](nil, nil, { status = 202, response = '{"accepted":1}' })
	http.request = original_request
	restore()
	storage.reset()
end

-- Builds a well-formed outbox entry for the cap/eviction tests. Odd indices
-- are denials (analytics=false, eviction-protected), even indices pure
-- grants (analytics=true, evictable).
local function cap_test_receipt(i)
	return {
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "user-example",
		kind = "anon",
		categories = { analytics = (i % 2) == 0 },
		decided_at = "2026-07-11T00:00:00Z",
		idempotency_key = "receipt-" .. tostring(i),
	}
end

-- The outbox is bounded (cap 32) with DENIAL-PREFERRING eviction: overflow
-- evicts the OLDEST PURE-GRANT receipts first — a recorded denial is the
-- compliance-critical write (a lost denial fail-opens the actor
-- server-side; a lost grant only delays pipeline opening and is
-- re-writable) — and the client surfaces the eviction of a
-- still-undelivered receipt via stats/diagnostics. Rewrites the retired
-- plain-FIFO cap pin.
local function test_consent_outbox_cap_evicts_oldest_pure_grants_first()
	reset()
	storage.reset()
	local entries = {}
	for i = 1, 40 do
		entries[i] = cap_test_receipt(i)
	end
	local saved = storage.save_consent_outbox(identity_scope, entries)
	assert_equal(#saved, 32, "the outbox must hold at most 32 receipts")
	-- 8 over cap: the 8 OLDEST GRANTS (even 2..16) go; every denial stays.
	assert_equal(saved[1].idempotency_key, "receipt-1", "the oldest DENIAL must survive the cap")
	assert_equal(saved[2].idempotency_key, "receipt-3", "grants older than it are evicted instead")
	assert_equal(saved[32].idempotency_key, "receipt-40")
	local denials = 0
	for i = 1, #saved do
		if saved[i].categories.analytics == false then
			denials = denials + 1
		end
	end
	assert_equal(denials, 20, "cap pressure must never evict a denial while grants remain")

	-- the client mirror adopts the trim and counts the eviction
	reset()
	storage.reset()
	local issues = {}
	local client = assert(sdk.new(config({
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	for i = 1, 33 do
		client.consent_outbox[i] = cap_test_receipt(100 + i)
	end
	assert_true(client:persist_consent_outbox())
	assert_equal(#client.consent_outbox, 32)
	assert_equal(client.consent_outbox[1].idempotency_key, "receipt-101",
		"the denial head survives; the oldest grant was evicted")
	assert_equal(client.consent_outbox[2].idempotency_key, "receipt-103")
	assert_equal(client:snapshot().consent_outbox_evicted, 1)
	assert_equal(issues[#issues].scope, "consent")
	assert_equal(issues[#issues].code, "outbox_overflow")
	storage.reset()
end

-- The denial-preferring fallback: a denial-carrying receipt is evicted —
-- oldest first — ONLY when everything over the cap carries denials. The
-- forced-minor reason-bearing denial is denial-carrying too (its category
-- map is analytics=false), so it enjoys the same protection.
local function test_consent_outbox_cap_denial_evicted_only_among_denials()
	reset()
	storage.reset()
	local entries = {}
	for i = 1, 33 do
		local entry = cap_test_receipt(i)
		entry.categories = { analytics = false }
		if i == 1 then
			entry.reason = "denied_forced_minor"
		end
		entries[i] = entry
	end
	local saved = storage.save_consent_outbox(identity_scope, entries)
	assert_equal(#saved, 32)
	assert_equal(saved[1].idempotency_key, "receipt-2",
		"with nothing but denials over cap, the oldest denial goes")
	assert_equal(saved[32].idempotency_key, "receipt-33")
	storage.reset()
end

-- GRANT-APPEND FAILS CLOSED ON A DENIAL-FULL OUTBOX: when appending a
-- grant's receipt would overflow the 32-entry cap with no pre-existing pure
-- grant for the denial-preferring loop to evict, the loop's only candidates
-- are denial-carrying receipts or the just-appended grant itself — so
-- set_consent(true) is REFUSED with the distinct consent_outbox_full:
-- the state does not flip, nothing is evicted, every denial stays, and no
-- wire traffic results. A DENIAL append at the same cap keeps the shipped
-- semantics (the all-denials overflow evicts the OLDEST denial — a fresh
-- denial outranks a stale one). Once the outbox drains below the cap, the
-- same grant succeeds and dispatches.
local function test_grant_refused_on_denial_full_outbox_fails_closed()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	next_status = 500
	local client = assert(sdk.new(config_mode_a()))
	for _ = 1, 32 do
		assert_true(client:set_consent(false))
	end
	assert_equal(#client.consent_outbox, 32, "32 undelivered denials retained")

	local wire_before = #requests
	local ok, err = client:set_consent(true)
	assert_equal(ok, false)
	assert_equal(err, "consent_outbox_full")
	assert_equal(client.consent_state, "denied", "a refused grant must not flip the state")
	assert_equal(#client.consent_outbox, 32, "a refused grant evicts nothing")
	for i = 1, #client.consent_outbox do
		assert_equal(client.consent_outbox[i].categories.analytics, false,
			"every retained denial survives the refused grant")
	end
	assert_equal(#requests, wire_before, "a refused grant produces no wire traffic")
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 32, "the durable record is untouched")

	-- a DENIAL append still applies at the same cap: the all-denials
	-- overflow evicts the OLDEST denial in favor of the fresh one
	local oldest_key = client.consent_outbox[1].idempotency_key
	assert_true(client:set_consent(false))
	assert_equal(#client.consent_outbox, 32)
	assert_not_equal(client.consent_outbox[1].idempotency_key, oldest_key,
		"a fresh denial evicts the oldest denial, never the reverse")

	-- drain below the cap: the same grant now succeeds and dispatches
	next_status = 202
	client.consent_retry_after_ms = nil
	client:update(client.config.flush_interval_seconds)
	assert_equal(#client.consent_outbox, 0, "the outbox drains once the transport recovers")
	assert_true(client:set_consent(true), "the grant succeeds once the outbox drained")
	assert_equal(client.consent_state, "granted")
	assert_contains(requests[#requests].body, '"categories":{"analytics":true}')
	assert_equal(#client.consent_outbox, 0, "the grant receipt delivered")
	restore()
	storage.reset()
end

-- The refusal is scoped exactly to the denial-full case: with a
-- pre-existing pure grant available to absorb the overflow, a new grant
-- append proceeds and the shipped denial-preferring loop evicts that
-- OLDEST grant — the fresh grant is retained and every denial survives.
local function test_grant_append_proceeds_when_old_grant_evictable()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	next_status = 500
	local client = assert(sdk.new(config_mode_a()))
	for _ = 1, 31 do
		assert_true(client:set_consent(false))
	end
	assert_true(client:set_consent(true), "under the cap the grant appends normally")
	assert_equal(#client.consent_outbox, 32)
	local old_grant_key = client.consent_outbox[32].idempotency_key
	assert_true(client:set_consent(true),
		"with an old pure grant evictable, a new grant is not refused")
	assert_equal(#client.consent_outbox, 32)
	local denials = 0
	for i = 1, #client.consent_outbox do
		if client.consent_outbox[i].categories.analytics == false then
			denials = denials + 1
		end
	end
	assert_equal(denials, 31, "every denial survives the grant-for-grant eviction")
	assert_equal(client.consent_outbox[32].categories.analytics, true,
		"the fresh grant is retained")
	assert_not_equal(client.consent_outbox[32].idempotency_key, old_grant_key,
		"the OLD grant is the one evicted")
	assert_equal(client:snapshot().consent_outbox_evicted, 1)
	restore()
	storage.reset()
end

-- A malformed outbox record on disk is fail-safe: garbled entries are dropped
-- at load — never sent, never a crash into game code — and they never block
-- the deliverable receipts stored around them.
-- Load-order pin (fleet audit, from unreal round 2): the outbox load-side
-- drops — the sanitizer inside load_consent_outbox and the M.new
-- identity/vouch drop — run BEFORE any cap enforcement, which lives only in
-- save_consent_outbox. Were the 32-cap applied to the loaded file first, the
-- stale to-be-dropped entries would count against it and the
-- denial-preferring eviction would take the ONE deliverable receipt (worst
-- case: the only current-anon pure grant among 39 stale denials — the first
-- pure grant the eviction loop scans). Pinned: zero cap evictions, the grant
-- survives the drops and delivers.
local function test_outbox_load_drops_run_before_cap_enforcement()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- Learn the outbox path (and pin the current anon) with a real receipt.
	next_status = 500
	local seeder = assert(sdk.new(config({ anonymous_id = "anon-current" })))
	assert_true(seeder:set_consent(false))
	local _, outbox_path = stored_consent_outbox_record(stores)
	assert_true(outbox_path ~= nil)
	-- Hand-write an OVER-CAP record: 39 stale old-anon denials (Mode-B-only
	-- identity_changed fodder) with the one deliverable current-anon pure
	-- GRANT newest, behind all of them.
	local receipts = {}
	for i = 1, 39 do
		receipts[i] = {
			workspace_id = "workspace-example",
			app_id = "app-example",
			environment_id = "develop",
			actor_identifier = "anon-old",
			kind = "anon",
			categories = { analytics = false },
			decided_at = "2026-07-01T00:00:00Z",
			idempotency_key = "receipt-stale-" .. i,
			anonymous_id = "anon-old",
		}
	end
	receipts[40] = {
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "anon-current",
		kind = "anon",
		categories = { analytics = true },
		decided_at = "2026-07-01T00:00:01Z",
		idempotency_key = "receipt-deliverable-grant",
		anonymous_id = "anon-current",
	}
	stores[outbox_path] = { receipts = receipts }
	storage.reset() -- the hand-written FILE is what loads

	reset()
	next_status = 500 -- keep the grant RETAINED so retention is observable
	local issues = {}
	local client = assert(sdk.new(config({
		anonymous_id = "anon-current",
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	assert_equal(#client.consent_outbox, 1,
		"the 39 stale entries drop; the deliverable grant survives")
	assert_equal(client.consent_outbox[1].idempotency_key,
		"receipt-deliverable-grant")
	assert_equal(client:snapshot().consent_outbox_evicted, 0,
		"zero cap evictions: the drops run before the cap can see an overflow")
	local saw_overflow = false
	local identity_drop = nil
	for i = 1, #issues do
		if issues[i].code == "outbox_overflow" then
			saw_overflow = true
		end
		if issues[i].code == "identity_changed" then
			identity_drop = issues[i]
		end
	end
	assert_equal(saw_overflow, false, "no outbox_overflow may fire at load")
	assert_true(identity_drop ~= nil and identity_drop.count == 39,
		"the stale entries leave as identity_changed drops")
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1, "the persisted record keeps only the grant")
	assert_equal(record.receipts[1].idempotency_key, "receipt-deliverable-grant")

	-- The surviving grant actually delivers once the endpoint recovers. The
	-- clock advance waits out the receipt's own retry window, which its first
	-- failure now arms (A6); the consent gate is ordering, not pacing, so an
	-- explicit flush honours it.
	reset()
	next_status = 202
	socket.now = socket.now + 2
	assert_true(client:flush())
	assert_equal(#requests, 1)
	assert_contains(requests[1].body,
		'"idempotency_key":"receipt-deliverable-grant"')
	restore()
	storage.reset()
end

local function test_malformed_consent_outbox_dropped_failsafe()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()

	-- persist one real receipt (a transient failure keeps it retained;
	-- anon-keyed so the pre-identify relaunch below can dispatch it)
	next_status = 500
	local first = assert(sdk.new(config()))
	assert_true(first:set_consent(false))
	local record, path = stored_consent_outbox_record(stores)
	assert_true(record ~= nil and path ~= nil)
	local valid = record.receipts[1]

	-- corrupt the record around the one valid entry
	stores[path] = { receipts = {
		"not-a-table",
		42,
		{ idempotency_key = "" },
		{ idempotency_key = "half-a-receipt" },
		{
			idempotency_key = "bad-categories",
			workspace_id = "w",
			app_id = "a",
			environment_id = "e",
			actor_identifier = "u",
			decided_at = "2026-07-11T00:00:00Z",
			categories = { analytics = "yes" },
		},
		valid,
	} }
	storage.reset() -- drop the in-memory shadow so the corrupt FILE is what loads

	reset()
	next_status = 202
	local second = assert(sdk.new(config()))
	assert_equal(#requests, 1, "only the well-formed receipt may send")
	assert_contains(requests[1].body, '"idempotency_key":"' .. valid.idempotency_key .. '"')
	assert_equal(second:snapshot().consent_recorded, 1)
	assert_equal(#second.consent_outbox, 0)

	-- a wholly garbled record (not even a table) starts clean, never throws
	stores[path] = "garbage"
	storage.reset()
	reset()
	local third = assert(sdk.new(config()))
	assert_equal(#requests, 0, "a garbled outbox record must load as empty")
	assert_equal(#third.consent_outbox, 0)
	restore()
	storage.reset()
end

-- A failed post-delivery prune keeps the acknowledged receipt on disk; until
-- the retried rewrite lands, a Mode B anon rotation stays refused — a later
-- launch would reload the stale receipt and replay the OLD actor under a
-- token minted for the new anon.
local function test_rotation_blocked_while_prune_rewrite_owed()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	local outbox_writes = 0
	local fail_from_second_write = true
	local plain_save = sys.save
	sys.save = function(path, record)
		if path:sub(-15) == "/consent-outbox" then
			outbox_writes = outbox_writes + 1
			if fail_from_second_write and outbox_writes >= 2 then
				return false
			end
		end
		return plain_save(path, record)
	end

	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	-- enqueue write (1) succeeds; the delivery acks; the prune rewrite (2) fails
	assert_true(client:set_consent(true), "a delivered receipt needs no durability error")
	assert_equal(#client.consent_outbox, 0, "the ack removed the receipt from the mirror")
	assert_equal(client.consent_outbox_dirty, true, "the failed prune stays owed")
	assert_true(client:consent_outbox_pending(), "an owed prune rewrite counts as pending")

	local ok, err = client:set_anonymous_id("anon-new")
	assert_equal(ok, false)
	assert_equal(err, "events_pending", "rotation must wait for the owed prune rewrite")

	-- storage recovers: the next dispatch point lands the rewrite and
	-- rotation proceeds
	fail_from_second_write = false
	client:update(client.config.flush_interval_seconds)
	assert_equal(client.consent_outbox_dirty, false)
	assert_true(client:set_anonymous_id("anon-new"))
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 0, "the prune rewrite must land once storage recovers")
	restore()
	storage.reset()
end

-- The identity-changed anti-wedge drop at load is scoped to receipts that
-- could NEVER send on any configured credential: ANON-keyed receipts with a
-- rotated anon snapshot, in a Mode-B-ONLY configuration (the minted token
-- binds the CURRENT anon, so replaying them would wedge the trail behind a
-- guaranteed rejection; diagnosed as identity_changed, like the event
-- spool). Everything else keeps delivering: Mode A re-sends the historic
-- actor unchanged, a Mode B + api_key configuration dispatches
-- HISTORIC-anon receipts under the publishable key (the historic actor is
-- the correct subject of those decisions, and the key is the one
-- credential that can still carry it — a current-anon receipt rides the
-- minted token instead, most-vouching), and a user_verified-keyed receipt
-- is never dropped for a merely-absent identity.
local function test_outbox_identity_drop_narrowed_to_unsendable_anon_receipts()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()

	-- Mode-B-only: retain an anon-keyed receipt under the original anon,
	-- then relaunch with an identity override
	next_status = 500
	local first = assert(sdk.new(config()))
	assert_true(first:set_consent(false))
	assert_equal(#first.consent_outbox, 1)
	local record = stored_consent_outbox_record(stores)
	assert_equal(record.receipts[1].anonymous_id, first.anonymous_id,
		"the entry must carry its decision-time anon snapshot")
	assert_equal(record.receipts[1].kind, "anon")

	reset()
	next_status = 202
	local issues = {}
	local second = assert(sdk.new(config({
		anonymous_id = "anon-override",
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	assert_equal(#second.consent_outbox, 0, "a mismatched anon receipt must be dropped at load")
	assert_equal(#requests, 0, "a dropped receipt must not be dispatched")
	assert_equal(issues[#issues].scope, "consent")
	assert_equal(issues[#issues].code, "identity_changed")
	record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 0, "the drop must be persisted")

	-- Mode-B-only, user_verified-keyed: the same anon rotation must NOT drop
	-- the receipt (it may be the only record of that actor's decision); it
	-- parks until the session vouches for its actor, then delivers under the
	-- minted token.
	reset()
	storage.reset()
	next_status = 500
	local verified_first = assert(sdk.new(config()))
	assert_true(verified_first:identify("user-verified-example"))
	assert_true(verified_first:set_consent(false))
	assert_equal(#verified_first.consent_outbox, 1)

	reset()
	next_status = 202
	local verified_issues = {}
	local verified_second = assert(sdk.new(config({
		anonymous_id = "anon-override",
		diagnostics = function(issue)
			verified_issues[#verified_issues + 1] = issue
		end,
	})))
	for i = 1, #verified_issues do
		-- The override boot may surface its own fresh-identity reset
		-- (identity_override_changed); what must NEVER appear is an
		-- identity_changed DROP of the verified-keyed receipt.
		assert_not_equal(verified_issues[i].code, "identity_changed",
			"a verified-keyed receipt must never drop as identity_changed")
	end
	assert_equal(#verified_second.consent_outbox, 1, "the verified receipt is retained")
	assert_equal(#requests, 0, "and parked until the session vouches for its actor")
	assert_true(verified_second:identify("user-verified-example"))
	assert_equal(#requests, 1, "identify delivers the retained verified receipt")
	assert_contains(requests[1].body, '"actor_identifier":"user-verified-example"')
	assert_contains(requests[1].body, '"kind":"user_verified"')
	assert_equal(verified_second:snapshot().consent_recorded, 1)

	-- Mode B + api_key (the remote-config dual-credential configuration): an
	-- anon-keyed receipt with a rotated anon KEEPS delivering — a HISTORIC
	-- anon actor is one the minted token cannot vouch for, so it goes under
	-- the publishable key, which has no token binding. (The explicit anon
	-- makes the first launch's actor genuinely historic on the relaunch:
	-- the stubbed sys stores survive storage.reset(), so a generated-or-
	-- inherited anon could collide with the relaunch override and read as
	-- CURRENT — which would ride the token instead.)
	reset()
	storage.reset()
	next_status = 500
	local dual_config = {
		remote_config_url = "http://localhost:9090",
		api_key = "sp_ingest_publishable_key",
		anonymous_id = "anon-dual-historic",
	}
	local dual_first = assert(sdk.new(config(dual_config)))
	local dual_historic_anon = dual_first.anonymous_id
	assert_true(dual_first:set_consent(false))
	assert_equal(#dual_first.consent_outbox, 1)

	reset()
	next_status = 202
	local dual_second = assert(sdk.new(config({
		remote_config_url = "http://localhost:9090",
		api_key = "sp_ingest_publishable_key",
		anonymous_id = "anon-override",
	})))
	assert_equal(#requests, 1, "Mode B + api_key must re-send the historic anon receipt")
	assert_equal(requests[1].headers["Authorization"], "Bearer sp_ingest_publishable_key")
	assert_contains(requests[1].body, '"actor_identifier":"' .. dual_historic_anon .. '"')
	assert_equal(dual_second:snapshot().consent_recorded, 1)

	-- Mode A: same retained-receipt situation re-sends the historic actor
	reset()
	storage.reset()
	next_status = 500
	local third = assert(sdk.new(config_mode_a()))
	local historic_anon = third.anonymous_id
	assert_true(third:set_consent(false))
	assert_equal(#third.consent_outbox, 1)

	reset()
	next_status = 202
	local fourth = assert(sdk.new(config_mode_a({ anonymous_id = "anon-override" })))
	assert_equal(#requests, 1, "Mode A must re-send the retained receipt")
	assert_contains(requests[1].body, '"actor_identifier":"' .. historic_anon .. '"')
	assert_not_contains(requests[1].body, '"anonymous_id"')
	assert_equal(fourth:snapshot().consent_recorded, 1)
	restore()
	storage.reset()
end

-- Canonical-actor keying (ADR-0222 §1 / the ADR-0202 2026-07-20 amendment):
-- a Mode A self-asserted user id is NEVER the receipt actor — the
-- publishable key cannot vouch for it, and the ingress binds the write to
-- the caller's own anon scope regardless — so the receipt keys to the
-- SDK-managed anonymous id with kind "anon". Replaces the retired v0.9.1
-- user-first snapshot rule (which took a set user_id even in Mode A).
local function test_receipt_actor_canonical_anon_under_publishable_key()
	reset()
	storage.reset()
	local client = assert(sdk.new(config_mode_a()))
	assert_true(client:identify("user-actor"))
	assert_true(client:set_consent(false))
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_equal(requests[1].headers["Authorization"], "Bearer sp_ingest_publishable_key")
	assert_contains(requests[1].body, '"actor_identifier":"' .. client.anonymous_id .. '"')
	assert_not_contains(requests[1].body, "user-actor")
	assert_contains(requests[1].body, '"kind":"anon"')
	storage.reset()
end

-- Mode B canonical keying + default kind emission: a decision made before
-- identify() keys to the anonymous id (kind "anon"); once a token_provider-
-- backed session has an identified user, the receipt keys to the verified
-- user id with kind "user_verified" — and the kind rides the wire body BY
-- DEFAULT in both cases.
local function test_receipt_kind_verified_in_mode_b_and_emitted_by_default()
	reset()
	storage.reset()
	local client = assert(sdk.new(config()))
	assert_true(client:set_consent(false))
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"actor_identifier":"' .. client.anonymous_id .. '"')
	assert_contains(requests[1].body, '"kind":"anon"')
	assert_true(client:identify("user-verified-example"))
	assert_true(client:set_consent(true))
	assert_equal(#requests, 2)
	assert_contains(requests[2].body, '"actor_identifier":"user-verified-example"')
	assert_contains(requests[2].body, '"kind":"user_verified"')
	storage.reset()
end

-- The kind-emission escape hatch for deployments whose ingest service still
-- runs the pre-amendment INGEST_CONSENT_KIND_MODE=off strict decoder (which
-- 400-rejects a kind-bearing body as an unknown field):
-- consent_kind_emission_enabled = false suppresses the WIRE field only —
-- the kind is still chosen, persisted with the receipt, and drives
-- dispatch-credential selection.
local function test_consent_kind_emission_escape_hatch_suppresses_wire_field()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	next_status = 500
	local client = assert(sdk.new(config({ consent_kind_emission_enabled = false })))
	assert_true(client:identify("user-verified-example"))
	assert_true(client:set_consent(false))
	assert_equal(#requests, 1)
	assert_not_contains(requests[1].body, '"kind"')
	assert_contains(requests[1].body, '"actor_identifier":"user-verified-example"')
	local record = stored_consent_outbox_record(stores)
	assert_equal(record.receipts[1].kind, "user_verified",
		"the suppressed kind must still be persisted with the receipt")
	restore()
	storage.reset()
end

-- Parking (the amended §12 path-5 narrowing): a user_verified-keyed receipt
-- parks while the current session cannot VOUCH FOR ITS ACTOR — no
-- token_provider (a signed-out relaunch under the publishable key), no
-- identify() yet, or a DIFFERENT user signed in. Parked = retained,
-- persisted, excluded from dispatch, and never dispatched under the
-- publishable key or another actor's token (either would lose or wedge an
-- undelivered denial). It delivers verbatim (same idempotency_key) the
-- moment a Mode B session identifies as its actor again.
local function test_verified_receipt_parks_signed_out_and_dispatches_when_token_returns()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- Launch 1 (Mode B, signed in): the denial's receipt cannot deliver (500)
	next_status = 500
	local first = assert(sdk.new(config()))
	assert_true(first:identify("user-verified-example"))
	assert_true(first:set_consent(false))
	assert_equal(#first.consent_outbox, 1)
	local record = stored_consent_outbox_record(stores)
	local original_key = record.receipts[1].idempotency_key
	assert_equal(record.receipts[1].kind, "user_verified")
	assert_true(first:shutdown("app_final"))

	-- Launch 2 (signed out: publishable key only): the receipt parks —
	-- loaded, retained, durably persisted, dispatched by NOTHING
	reset()
	next_status = 202
	local second = assert(sdk.new(config_mode_a()))
	assert_equal(#requests, 0, "a parked receipt must not dispatch under the publishable key")
	assert_equal(#second.consent_outbox, 1, "a parked receipt stays retained")
	second:update(second.config.flush_interval_seconds)
	assert_true(second:flush())
	assert_equal(#requests, 0, "no dispatch point may send a parked receipt")
	assert_true(second:shutdown("app_final"),
		"a durably retained parked receipt must not block teardown")
	record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1, "the parked receipt survives teardown on disk")
	assert_equal(record.receipts[1].idempotency_key, original_key)

	-- Launch 3 (token_provider back, but a DIFFERENT user signs in): the
	-- receipt must STAY parked — the minted token vouches for the current
	-- user, and dispatching another actor's receipt under it would retry
	-- forever on the auth mismatch or be terminally dropped.
	reset()
	local third = assert(sdk.new(config()))
	assert_equal(#requests, 0, "a verified receipt stays parked before identify")
	assert_true(third:identify("some-other-user"))
	third:update(third.config.flush_interval_seconds)
	assert_true(third:flush())
	assert_equal(#requests, 0,
		"another user's session must not dispatch the parked receipt")
	assert_equal(#third.consent_outbox, 1, "the parked receipt stays retained")

	-- The receipt's own actor signs in: the session now vouches for it —
	-- identify() dispatches it immediately, verbatim, under the minted token.
	assert_true(third:identify("user-verified-example"))
	assert_equal(#requests, 1, "a vouching Mode B session must dispatch the parked receipt")
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_contains(requests[1].body, '"idempotency_key":"' .. original_key .. '"')
	assert_contains(requests[1].body, '"actor_identifier":"user-verified-example"')
	assert_contains(requests[1].body, '"kind":"user_verified"')
	assert_equal(third:snapshot().consent_recorded, 1)
	record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 0, "the delivered receipt is pruned")
	restore()
	storage.reset()
end

-- Parked receipts are excluded from dispatch selection AND from the
-- grant-dispatch gate: a parked GRANT never holds the event-batch leg
-- hostage (flush would otherwise wedge in consent_receipt_pending for as
-- long as the credential stays absent), and deliverable receipts behind a
-- parked one still deliver, under their own per-receipt credential.
local function test_parked_receipt_never_blocks_dispatch_or_gates_events()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- Launch 1 (Mode B): an undeliverable GRANT receipt (verified-keyed)
	next_status = 500
	local first = assert(sdk.new(config()))
	assert_true(first:identify("user-verified-example"))
	assert_true(first:set_consent(true))
	assert_true(first:shutdown("app_final"))

	-- Launch 2 (signed out, publishable key): the verified grant parks; the
	-- persisted granted state reopens the local pipeline, and the parked
	-- grant must not gate the batch leg.
	reset()
	next_status = 202
	local second = assert(sdk.new(config_mode_a()))
	assert_equal(#second.consent_outbox, 1)
	assert_true(second:track("post_park_event"))
	assert_true(second:flush({ include_summaries = false }),
		"a parked grant must not gate the batch leg")
	assert_equal(#requests, 1)
	assert_true(requests[1].url:find("/v1/events:batch", 1, true) ~= nil)

	-- A new decision on this launch keys to the anon actor and delivers
	-- under the publishable key, past the parked verified receipt.
	assert_true(second:set_consent(false))
	assert_equal(#requests, 2)
	assert_equal(requests[2].url, "http://localhost:8080/v1/consent")
	assert_contains(requests[2].body, '"actor_identifier":"' .. second.anonymous_id .. '"')
	assert_contains(requests[2].body, '"kind":"anon"')
	assert_equal(#second.consent_outbox, 1,
		"the delivered anon receipt is pruned; the parked one stays")
	assert_equal(second.consent_outbox[1].kind, "user_verified")
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1)
	restore()
	storage.reset()
end

-- The anon-rotation guard is scoped to work bound to the OLD anon: a
-- user_verified receipt PARKED for a signed-out actor is anon-independent
-- (it keys to the verified user and dispatches only under that user's JWT),
-- so it must not hold set_anonymous_id in events_pending — its actor may
-- never sign in again, so blocking on it could wedge rotation forever.
-- Anon-keyed receipts still block, and an owed durable rewrite still blocks
-- (test_rotation_blocked_while_prune_rewrite_owed).
local function test_rotation_allowed_with_only_parked_verified_receipts()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- Launch 1 (Mode B, signed in): user A's denial cannot deliver (500) and
	-- is retained user_verified-keyed.
	next_status = 500
	local first = assert(sdk.new(config()))
	assert_true(first:identify("user-a"))
	assert_true(first:set_consent(false))
	assert_equal(#first.consent_outbox, 1)
	assert_true(first:shutdown("app_final"))

	-- Launch 2 (Mode B, signed out): the receipt parks; rotation proceeds.
	reset()
	next_status = 202
	local second = assert(sdk.new(config()))
	assert_equal(#second.consent_outbox, 1, "the verified receipt is parked, not dropped")
	assert_equal(second.consent_outbox[1].kind, "user_verified")
	assert_true(second:set_anonymous_id("anon-rotated"),
		"a parked verified receipt must not block anon rotation")
	assert_equal(second.anonymous_id, "anon-rotated")
	assert_equal(#second.consent_outbox, 1, "rotation leaves the parked receipt retained")
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1, "the parked receipt stays durably retained")

	-- Contrast pin: an ANON-keyed retained receipt still blocks the next
	-- rotation (its actor IS the old anon).
	next_status = 500
	assert_true(second:set_consent(true))
	assert_equal(#second.consent_outbox, 2)
	assert_equal(second.consent_outbox[2].kind, "anon")
	local ok, err = second:set_anonymous_id("anon-rotated-again")
	assert_equal(ok, false)
	assert_equal(err, "events_pending")
	restore()
	storage.reset()
end

-- identify() is a consent dispatch point, and the dispatch it unlocks must
-- never ride a credential minted for a DIFFERENT session: the consent route
-- binds the actor to the token subject, and an actor/subject mismatch is
-- rejected terminally — dropping the receipt, a retained withdrawal
-- included. An identity CHANGE therefore invalidates the cached Mode B
-- token before the unpark dispatch (the dispatch mints fresh for the
-- just-identified session), and a mint still in flight across the change
-- discards its stale result instead of installing it.
local function test_identify_invalidates_stale_token_before_unpark_dispatch()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	local token_calls = 0
	local counting_mode_b = function()
		return config({
			token_provider = function(callback)
				token_calls = token_calls + 1
				callback("token-" .. tostring(token_calls), nil, nil)
			end,
		})
	end
	-- Launch 1 (Mode B): user A's withdrawal cannot deliver (500) and is
	-- retained user_verified-keyed.
	next_status = 500
	local first = assert(sdk.new(counting_mode_b()))
	assert_true(first:identify("user-a"))
	assert_true(first:set_consent(false))
	assert_true(first:shutdown("app_final"))

	-- Launch 2 (Mode B): user B signs in and delivers a decision of their
	-- own, leaving a cached token that vouches for B's session only.
	reset()
	next_status = 202
	local second = assert(sdk.new(counting_mode_b()))
	assert_equal(#second.consent_outbox, 1, "A's receipt is parked, not dropped")
	assert_true(second:identify("user-b"))
	assert_true(second:set_consent(true))
	assert_equal(#requests, 1)
	local cached = second.token
	assert_true(cached ~= nil, "B's delivery leaves a cached token")

	-- The account switches to A in the same process: identify() must drop
	-- B's cached token so the unpark dispatch mints fresh — reusing it would
	-- send A's receipt under a credential that cannot vouch for A.
	assert_true(second:identify("user-a"))
	assert_equal(#requests, 2, "identify() dispatches A's parked receipt")
	assert_contains(requests[2].body, '"actor_identifier":"user-a"')
	assert_not_equal(requests[2].headers["Authorization"], "Bearer " .. cached,
		"the unpark dispatch must not ride the previous session's token")
	assert_equal(requests[2].headers["Authorization"],
		"Bearer token-" .. tostring(token_calls))
	assert_equal(#second.consent_outbox, 0, "A's receipt delivered under the fresh mint")

	-- A mint in flight ACROSS an identity change discards its stale result:
	-- the late callback settles the in-flight flag but installs nothing, and
	-- the next dispatch point mints for the current session.
	reset()
	next_status = 500
	local pending_mint = nil
	local third = assert(sdk.new(config({
		token_provider = function(callback)
			pending_mint = callback
		end,
	})))
	assert_true(third:set_consent(false)) -- anon receipt; the mint stays in flight
	assert_true(third.token_request_in_flight)
	assert_true(third:identify("user-c")) -- identity changes mid-mint
	pending_mint("stale-anon-token", nil, nil)
	assert_equal(third.token_request_in_flight, false,
		"a stale mint callback still settles the in-flight flag")
	assert_equal(third.token, nil,
		"a mint from before the identity change must not install its token")
	restore()
	storage.reset()
end

-- The consent deferral is plane-wide by design — but only for heads that can
-- still retry. When identify() switches the vouched actor and thereby PARKS
-- the receipt whose failure armed the window, the window would outlive its
-- owner and hold the NEW head (possibly a fresh denial) for up to the 24h
-- clamp while the arming receipt cannot retry at all. The actor change
-- resets the plane deferral (and its backoff attempt count); the parked
-- receipt itself stays retained.
local function test_actor_change_parking_armed_head_resets_consent_deferral()
	reset()
	storage.reset()
	-- Mode B: user-a's denial hits a long Retry-After — the plane defers.
	next_status = 429
	next_response_headers = { ["retry-after"] = "3600" }
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-window-a"))
	assert_true(client:set_consent(false))
	assert_equal(#requests, 1)
	assert_equal(#client.consent_outbox, 1, "the 429 retains the receipt")
	assert_true(client.consent_retry_after_ms ~= nil,
		"the 429 Retry-After must arm the consent deferral")

	-- A DIFFERENT user signs in: the arming receipt parks, and the window
	-- resets with it.
	reset()
	next_status = 202
	next_response_headers = nil
	assert_true(client:identify("user-window-b"))
	assert_equal(client.consent_retry_after_ms, nil,
		"parking the arming head must reset the plane deferral")
	assert_equal(client.consent_backoff_attempt, 0)
	assert_equal(#client.consent_outbox, 1, "the parked receipt stays retained")
	assert_equal(#requests, 0, "nothing dispatchable yet — the parked head is skipped")

	-- The new session's fresh denial dispatches immediately instead of
	-- waiting out the parked actor's window.
	assert_true(client:set_consent(false))
	assert_equal(#requests, 1, "the fresh head must dispatch immediately")
	assert_contains(requests[1].body, '"actor_identifier":"user-window-b"')
	assert_equal(#client.consent_outbox, 1,
		"the delivered fresh receipt is pruned; the parked one stays")
	assert_equal(client.consent_outbox[1].actor_identifier, "user-window-a")
	storage.reset()
end

-- The reset above is scoped to the ARMING HEAD PARKING — everything else
-- keeps honoring the plane-wide window: plain same-actor retries (no
-- identity change), and an identity change that does NOT park the arming
-- receipt (an anon-keyed head never parks).
local function test_consent_window_holds_for_same_actor_and_non_parking_changes()
	reset()
	storage.reset()
	-- An ANON-keyed denial arms the window.
	next_status = 429
	next_response_headers = { ["retry-after"] = "3600" }
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:set_consent(false))
	assert_equal(#requests, 1)
	assert_true(client.consent_retry_after_ms ~= nil)
	local armed_deadline = client.consent_retry_after_ms

	-- Same-actor retries keep honoring the window: no dispatch on any
	-- cadence while the deadline is open.
	reset()
	next_status = 202
	next_response_headers = nil
	client:update(client.config.flush_interval_seconds)
	assert_true(client:flush())
	assert_equal(#requests, 0, "the retained head must wait out its own window")
	assert_equal(client.consent_retry_after_ms, armed_deadline)

	-- identify() — an identity change that does NOT park the anon-keyed
	-- arming head — must leave the window in place.
	assert_true(client:identify("user-window-c"))
	assert_equal(client.consent_retry_after_ms, armed_deadline,
		"a non-parking identity change must not reset the plane deferral")
	assert_equal(#requests, 0, "the window still paces the anon head")

	-- identify() with the SAME user again: no identity change, no reset.
	assert_true(client:identify("user-window-c"))
	assert_equal(client.consent_retry_after_ms, armed_deadline)
	assert_equal(#requests, 0)
	storage.reset()
end

-- The in-flight sibling: a receipt that PARKS while its POST is on the wire
-- (identify() switches the actor before the response lands) settles retained
-- but must NOT arm the plane deferral — the wait would belong to a receipt
-- that cannot retry, and a fresh head behind it must not inherit it.
local function test_receipt_parking_in_flight_settles_without_arming_window()
	reset()
	storage.reset()
	local original_request = http.request
	local held = {}
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = {
			url = url,
			method = method,
			headers = headers,
			body = body,
			options = options,
		}
		held[#held + 1] = callback
	end

	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-flight-a"))
	assert_true(client:set_consent(false))
	assert_equal(#held, 1, "the receipt POST is in flight")
	assert_equal(client.consent_send_in_flight, true)

	-- The actor switches while the POST is on the wire; then the response
	-- lands as a retryable 429 WITH a Retry-After the settle must ignore.
	assert_true(client:identify("user-flight-b"))
	held[1](nil, nil, { status = 429, headers = { ["retry-after"] = "3600" } })
	assert_equal(client.consent_send_in_flight, false)
	assert_equal(client.consent_retry_after_ms, nil,
		"a receipt parking mid-flight must settle without arming the window")
	assert_equal(client.consent_backoff_attempt, 0)
	assert_equal(#client.consent_outbox, 1, "the parked receipt stays retained")

	-- A fresh decision for the new actor dispatches immediately.
	http.request = original_request
	reset()
	next_status = 202
	assert_true(client:set_consent(false))
	assert_equal(#requests, 1, "the fresh head dispatches with no inherited wait")
	assert_contains(requests[1].body, '"actor_identifier":"user-flight-b"')
	storage.reset()
end

-- P1 (round-2 review): identify() REFUSES a Mode B identity CHANGE while
-- event work snapshotted to another verified user is still undrained —
-- queued in this process, or reloaded on the durable spool. Events snapshot
-- their user at enqueue time, so accepting the switch would drop the token
-- that vouches for them and the next flush would mint for the NEW user and
-- ship the previous user's events under a credential that cannot vouch for
-- those envelopes (rejected, or worse misattributed). Same refusal family
-- as the anon-rotation guard: false, "events_pending" — the host flushes,
-- then re-identifies. Anon-snapshotted work never blocks (the mint's
-- bind_anon vouches for it regardless of the verified subject), and Mode A
-- is untouched (no per-session credential exists to mismatch).
local function test_identify_refused_while_other_user_events_pending()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	seed_granted_consent()
	local token_calls = 0
	local counting_mode_b = function(overrides)
		local out = config(overrides)
		out.token_provider = function(callback)
			token_calls = token_calls + 1
			callback("token-" .. tostring(token_calls), nil, nil)
		end
		return out
	end
	local client = assert(sdk.new(counting_mode_b()))
	assert_true(client:identify("user-a"))
	assert_true(client:track("bound_to_a"))
	next_status = 202
	assert_true(client:flush({ include_summaries = false }))
	assert_equal(token_calls, 1, "A's delivery minted A's session token")
	assert_true(client:track("second_bound_to_a"))

	-- A's event is queued: the switch to B is refused, nothing flips, and
	-- the cached token that vouches for A's work stays put.
	local ok, err = client:identify("user-b")
	assert_equal(ok, false)
	assert_equal(err, "events_pending")
	assert_equal(client.user_id, "user-a", "a refused identify must not flip the identity")
	assert_equal(client.token, "token-1", "a refused identify must not drop the vouching token")

	-- The queued event drains under A's own credential — no re-mint, the
	-- queue was left intact.
	local wire_before = #requests
	assert_true(client:flush({ include_summaries = false }))
	assert_equal(#requests, wire_before + 1, "the refused identify left the queued event in place")
	assert_contains(requests[#requests].body, '"second_bound_to_a"')
	assert_contains(requests[#requests].body, '"user_id":"user-a"')
	assert_equal(requests[#requests].headers["Authorization"], "Bearer token-1")
	assert_equal(token_calls, 1, "draining A's events must not mint a new credential")

	-- Drained: the switch succeeds, and the round-1 invalidation (now safe)
	-- still drops the cached token so B's next work mints fresh.
	assert_true(client:identify("user-b"), "identify allowed once A's events drained")
	assert_equal(client.token, nil, "an accepted identity change still drops the cached token")
	assert_true(client:track("bound_to_b"))
	assert_true(client:flush({ include_summaries = false }))
	assert_equal(requests[#requests].headers["Authorization"], "Bearer token-2")
	assert_equal(token_calls, 2, "B's work minted B's own credential")

	-- Spooled work blocks the same way ACROSS a relaunch: A's failed batch
	-- spools; the next launch starts anonymous, and identifying as B before
	-- the spool drains would re-send A's envelopes under B's mint.
	reset()
	next_status = 500
	local first = assert(sdk.new(counting_mode_b({ flush_interval_seconds = 9999 })))
	assert_true(first:identify("user-a"))
	assert_true(first:track("spooled_for_a"))
	assert_equal(first:flush({ include_summaries = false }), false)

	reset()
	next_status = 202
	local second = assert(sdk.new(counting_mode_b({ flush_interval_seconds = 9999 })))
	assert_equal(#second.spool_batches, 1, "A's envelope is on the spool")
	local ok2, err2 = second:identify("user-b")
	assert_equal(ok2, false, "identify must refuse while another user's spooled events pend")
	assert_equal(err2, "events_pending")
	assert_true(second:flush({ include_summaries = false }))
	assert_equal(#second.spool_batches, 0)
	assert_true(second:identify("user-b"), "identify allowed once the spool drained")

	-- Mode A: no per-session credential exists to mismatch — the switch
	-- stays allowed while A's event is queued (scoped like the rotation
	-- guard, which must not over-restrict Mode A either).
	reset()
	storage.reset()
	seed_granted_consent()
	local plain = assert(sdk.new(config_mode_a()))
	assert_true(plain:identify("user-a"))
	assert_true(plain:track("queued_mode_a"))
	assert_true(plain:identify("user-b"), "Mode A identify stays allowed while events pend")
	restore()
	storage.reset()
end

-- Head-of-queue audit: with parking, the dispatch head can sit BEHIND the
-- queue front, so every piece of dispatch bookkeeping must key to the
-- ACTUAL dispatch-head receipt, never to index 1 — the dispatch selection
-- skips the parked front, the grant-dispatch gate holds for an
-- undispatched grant while a DIFFERENT (non-front) receipt is in flight,
-- the in-flight exemption releases only the receipt whose idempotency_key
-- is in flight, and a settled non-front receipt chains the next
-- dispatchable one while the parked front stays untouched.
local function test_gate_and_in_flight_release_key_to_dispatch_head_not_front()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- Launch 1 (Mode B, signed in): an undeliverable verified GRANT that
	-- will sit parked at the FRONT of the next launch's outbox.
	next_status = 500
	local first = assert(sdk.new(config()))
	assert_true(first:identify("user-verified-example"))
	assert_true(first:set_consent(true))
	assert_true(first:shutdown("app_final"))

	-- Launch 2 (signed out, publishable key, async transport): the parked
	-- verified grant is the front; fresh anon decisions queue behind it.
	reset()
	local original_request = http.request
	local callbacks = {}
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		callbacks[#callbacks + 1] = callback
	end
	local second = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(#second.consent_outbox, 1)
	assert_true(second:set_consent(false)) -- anon denial: dispatch head, behind the parked front
	assert_equal(#requests, 1, "the dispatch head is the receipt BEHIND the parked front")
	assert_contains(requests[1].body, '"analytics":false')
	assert_true(second:set_consent(true)) -- anon grant: queued while the denial is in flight
	assert_equal(#requests, 1)
	assert_equal(#second.consent_outbox, 3)
	assert_true(second:track("post_toggle_event"))

	-- The parked front grant must not gate; the undispatched anon grant
	-- must — even though the in-flight receipt is not the front.
	local flushed, reason = second:flush({ include_summaries = false })
	assert_equal(flushed, false)
	assert_equal(reason, "consent_receipt_pending")
	assert_equal(#requests, 1, "no batch while the queued anon grant awaits dispatch")

	-- The non-front in-flight denial settles: the chain dispatches the anon
	-- grant (again skipping the parked front), whose own handoff releases
	-- the gate for itself only.
	callbacks[1](nil, nil, { status = 202, response = "{}" })
	assert_equal(#requests, 2)
	assert_contains(requests[2].body, '"analytics":true')
	local batch_flushed, batch_reason = second:flush({ include_summaries = false })
	assert_equal(batch_flushed, false)
	assert_equal(batch_reason, "pending")
	assert_equal(#requests, 3, "the batch follows the dispatched anon grant")
	assert_true(requests[3].url:find("/v1/events:batch", 1, true) ~= nil)
	callbacks[2](nil, nil, { status = 202, response = "{}" })
	callbacks[3](nil, nil, { status = 202, response = '{"accepted":1}' })

	-- The parked front was never dispatched, never released, never pruned;
	-- the settled non-front receipts reset the retry bookkeeping.
	assert_equal(#second.consent_outbox, 1, "only the parked front remains")
	assert_equal(second.consent_outbox[1].kind, "user_verified")
	assert_equal(second:snapshot().consent_recorded, 2)
	assert_equal(second.consent_backoff_attempt, 0)
	assert_true(not second:consent_send_deferred(),
		"settled non-front receipts must leave no stale deferral behind")
	http.request = original_request
	restore()
	storage.reset()
end

-- Most-vouching dispatch-credential selection in the dual-credential
-- configuration (token_provider + api_key via remote_config_url): a receipt
-- rides the minted Mode B token whenever it vouches for the receipt's
-- actor — the current verified user, or the CURRENT anon the mint binds as
-- its subject — so a current-anon GRANT stays deliverable (the publishable
-- key would take the terminal grant 403). Only a receipt the token cannot
-- vouch for (a HISTORIC-anon actor) falls back to the publishable key, the
-- one credential that can still carry it, with no mint. A 401 stays
-- classified by the credential the dispatch ACTUALLY USED: a minted-token
-- 401 re-mints and retries the same receipt; a publishable-key 401 is
-- terminal (the static key can never change) and must not invalidate the
-- cached Mode B token.
local function test_most_vouching_credential_and_401_follows_credential_used()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	local token_calls = 0
	local dual = function()
		return config({
			remote_config_url = "http://localhost:9090",
			api_key = "sp_ingest_publishable_key",
			token_provider = function(callback)
				token_calls = token_calls + 1
				callback("token-" .. tostring(token_calls), nil, nil)
			end,
		})
	end
	local client = assert(sdk.new(dual()))
	-- a current-anon receipt (pre-identify) rides the minted token — and its
	-- 401 re-mints and retries the SAME receipt
	next_status = 401
	assert_true(client:set_consent(false))
	assert_equal(#requests, 1)
	assert_equal(requests[1].headers["Authorization"], "Bearer token-1",
		"a current-anon receipt rides the minted token, not the key")
	assert_equal(#client.consent_outbox, 1, "a minted-token 401 must retain the receipt")
	next_status = 202
	client:update(client.config.flush_interval_seconds)
	assert_equal(#requests, 2)
	assert_equal(requests[2].headers["Authorization"], "Bearer token-2")
	assert_contains(requests[2].body, '"kind":"anon"')
	assert_equal(#client.consent_outbox, 0)

	-- a current-anon GRANT rides the token too and DELIVERS — under the
	-- publishable key it would be the terminal grant 403
	assert_true(client:set_consent(true))
	assert_equal(#requests, 3)
	assert_equal(requests[3].headers["Authorization"], "Bearer token-2",
		"a still-valid cached token is reused for a vouched receipt")
	assert_contains(requests[3].body, '"categories":{"analytics":true}')
	assert_equal(client:snapshot().consent_recorded, 2)

	-- a verified receipt rides the token by the vouching predicate (the
	-- identity change re-mints: identify() drops the cached token)
	assert_true(client:identify("user-verified-example"))
	assert_true(client:set_consent(true))
	assert_equal(#requests, 4)
	assert_equal(requests[4].headers["Authorization"], "Bearer token-3")
	assert_contains(requests[4].body, '"kind":"user_verified"')
	assert_equal(#client.consent_outbox, 0)

	-- relaunch with a HISTORIC-anon receipt on disk (the dual configuration
	-- keeps it at load): the token cannot vouch for that actor, so it
	-- dispatches under the publishable key, with no mint
	local _, outbox_path = stored_consent_outbox_record(stores)
	assert_true(outbox_path ~= nil)
	stores[outbox_path] = { receipts = { {
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "anon-historic",
		kind = "anon",
		categories = { analytics = false },
		decided_at = "2026-07-01T00:00:00Z",
		idempotency_key = "receipt-historic-anon",
		anonymous_id = "anon-historic",
	} } }
	storage.reset() -- drop the in-memory shadow so the seeded FILE is what loads
	reset()
	next_status = 202
	local minted_before = token_calls
	local second = assert(sdk.new(dual()))
	assert_equal(#requests, 1, "the historic-anon receipt dispatches at boot")
	assert_equal(requests[1].headers["Authorization"], "Bearer sp_ingest_publishable_key",
		"a historic-anon actor stays on the publishable key")
	assert_contains(requests[1].body, '"actor_identifier":"anon-historic"')
	assert_equal(token_calls, minted_before, "a historic-anon dispatch must not mint")
	assert_equal(#second.consent_outbox, 0)

	-- with a token cached for current-anon work, a publishable-key 401 on a
	-- historic receipt is terminal and must NOT invalidate that token
	assert_true(second:set_consent(false))
	assert_equal(requests[2].headers["Authorization"], "Bearer token-" .. tostring(token_calls))
	local cached = second.token
	assert_true(cached ~= nil)
	second.consent_outbox = { {
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "anon-historic-2",
		kind = "anon",
		categories = { analytics = false },
		decided_at = "2026-07-01T00:00:00Z",
		idempotency_key = "receipt-historic-anon-2",
		anonymous_id = "anon-historic-2",
	} }
	next_status = 401
	second:update(second.config.flush_interval_seconds)
	assert_equal(#requests, 3)
	assert_equal(requests[3].headers["Authorization"], "Bearer sp_ingest_publishable_key")
	assert_equal(#second.consent_outbox, 0, "a publishable-key 401 must drop the receipt")
	assert_equal(second.token, cached,
		"a publishable-key 401 must not invalidate the cached Mode B token")
	next_status = 202
	second:update(second.config.flush_interval_seconds)
	assert_equal(#requests, 3, "a publishable-key 401 must not be retried")
	restore()
	storage.reset()
end

-- Outbox upgrade path for kind: a LEGACY record written before kind existed
-- loads with kind backfilled to "anon" — the pre-kind ingress bound every
-- client write to the caller's anon scope, so anon is the class those
-- receipts were recorded under — while an entry carrying a non-allowlisted
-- kind ("user_unverified" included, which the SDK never produces) is
-- dropped fail-safe like any other malformed entry.
local function test_legacy_kindless_receipt_backfills_anon_and_invalid_kind_drops()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- seed a real record once to learn the outbox path, then replace it with
	-- a hand-written legacy file
	next_status = 500
	local seeder = assert(sdk.new(config_mode_a()))
	assert_true(seeder:set_consent(false))
	local _, outbox_path = stored_consent_outbox_record(stores)
	assert_true(outbox_path ~= nil)
	local function legacy_entry(key, kind)
		return {
			workspace_id = "workspace-example",
			app_id = "app-example",
			environment_id = "develop",
			actor_identifier = "anon-legacy",
			kind = kind,
			categories = { analytics = false },
			decided_at = "2026-07-01T00:00:00Z",
			idempotency_key = key,
			anonymous_id = "anon-legacy",
		}
	end
	stores[outbox_path] = { receipts = {
		legacy_entry("receipt-legacy", nil),
		legacy_entry("receipt-unverified", "user_unverified"),
		legacy_entry("receipt-garbled-kind", 42),
	} }
	storage.reset() -- drop the in-memory shadow so the legacy FILE is what loads

	local salvaged = storage.load_consent_outbox(identity_scope)
	assert_equal(#salvaged, 1, "non-allowlisted kinds must drop; the kindless legacy entry stays")
	assert_equal(salvaged[1].idempotency_key, "receipt-legacy")
	assert_equal(salvaged[1].kind, "anon", "a pre-kind receipt must backfill kind anon")

	-- and the backfilled receipt delivers with kind on the wire
	reset()
	next_status = 202
	local upgraded = assert(sdk.new(config_mode_a()))
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"idempotency_key":"receipt-legacy"')
	assert_contains(requests[1].body, '"kind":"anon"')
	assert_contains(requests[1].body, '"actor_identifier":"anon-legacy"')
	assert_equal(upgraded:snapshot().consent_recorded, 1)
	restore()
	storage.reset()
end

-- P1 (round-2 review): a receipt NO configured credential can vouch for
-- must never ride the minted token. The concrete case: a legacy kindless
-- receipt that stored v0.9.1's user-first ACTOR backfills to kind="anon"
-- at load with its retained anon snapshot still matching the current anon
-- — in a Mode-B-ONLY configuration the token vouches only for the current
-- anon (or a verified user), no publishable key exists, and the old
-- fall-through sent the user-shaped actor under the token anyway: a
-- terminal auth failure or a wrong-actor write, and, anon-keyed as it is,
-- a standing events_pending wedge of the rotation guard. Such a receipt
-- now drops at the load-time could-never-send gate exactly like the
-- narrow identity_changed rule (counted, diagnosed, persisted), dispatch
-- selection skips it as a belt (never falling through to a non-vouching
-- credential, never head-blocking the trail), and in the dual
-- token_provider + api_key configuration the SAME receipt is retained and
-- delivered under the publishable key as today.
local function test_unvouchable_legacy_receipt_dropped_mode_b_only_kept_dual()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- seed a real record once to learn the outbox path, then replace it
	-- with a hand-written legacy file
	next_status = 500
	local seeder = assert(sdk.new(config({ anonymous_id = "anon-current" })))
	assert_true(seeder:set_consent(false))
	local _, outbox_path = stored_consent_outbox_record(stores)
	assert_true(outbox_path ~= nil)
	local function legacy_user_entry(key)
		return {
			workspace_id = "workspace-example",
			app_id = "app-example",
			environment_id = "develop",
			actor_identifier = "user-legacy-example",
			categories = { analytics = false },
			decided_at = "2026-07-01T00:00:00Z",
			idempotency_key = key,
			anonymous_id = "anon-current",
		}
	end
	local function current_anon_entry(key)
		return {
			workspace_id = "workspace-example",
			app_id = "app-example",
			environment_id = "develop",
			actor_identifier = "anon-current",
			kind = "anon",
			categories = { analytics = false },
			decided_at = "2026-07-01T00:00:01Z",
			idempotency_key = key,
			anonymous_id = "anon-current",
		}
	end
	stores[outbox_path] = { receipts = {
		legacy_user_entry("receipt-legacy-user"),
		current_anon_entry("receipt-current-anon"),
	} }
	storage.reset() -- drop the in-memory shadow so the legacy FILE is what loads

	-- Mode-B-only: the user-actor entry drops at load; the current-anon
	-- entry behind it still delivers under the mint — no wedge, and the
	-- unvouchable actor never touches the wire.
	reset()
	next_status = 202
	local issues = {}
	local upgraded = assert(sdk.new(config({
		anonymous_id = "anon-current",
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	assert_equal(#requests, 1, "the deliverable current-anon receipt still dispatches")
	assert_contains(requests[1].body, '"idempotency_key":"receipt-current-anon"')
	assert_not_contains(requests[1].body, "user-legacy-example")
	assert_equal(issues[1].scope, "consent")
	assert_equal(issues[1].status, "dropped")
	assert_equal(issues[1].code, "identity_changed")
	assert_equal(issues[1].count, 1)
	assert_equal(#upgraded.consent_outbox, 0, "delivered plus dropped leaves nothing retained")
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 0, "the drop is persisted")

	-- Belt: an unvouchable anon receipt reaching the mirror mid-process is
	-- skipped by dispatch selection — never sent under the token — and the
	-- receipt appended behind it still delivers.
	upgraded.consent_outbox[#upgraded.consent_outbox + 1] =
		legacy_user_entry("receipt-injected")
	local wire_before = #requests
	assert_true(upgraded:set_consent(false))
	assert_equal(#requests, wire_before + 1, "the receipt behind the unvouchable one still delivers")
	assert_contains(requests[#requests].body, '"actor_identifier":"anon-current"')
	assert_not_contains(requests[#requests].body, "user-legacy-example")

	-- Dual (token_provider + api_key): the SAME legacy receipt is retained
	-- at load and delivers under the publishable key — the historic-actor
	-- path, unchanged.
	reset()
	storage.reset()
	stores[outbox_path] = { receipts = { legacy_user_entry("receipt-legacy-user-dual") } }
	storage.reset() -- the overwritten FILE is what the dual client loads
	next_status = 202
	local dual_issues = {}
	local dual = assert(sdk.new(config({
		anonymous_id = "anon-current",
		remote_config_url = "http://localhost:9090",
		api_key = "sp_ingest_publishable_key",
		diagnostics = function(issue)
			dual_issues[#dual_issues + 1] = issue
		end,
	})))
	assert_equal(#dual_issues, 0, "with a publishable key the legacy receipt is NOT dropped")
	assert_equal(#requests, 1, "the legacy receipt re-sends under the key")
	assert_equal(requests[1].headers["Authorization"], "Bearer sp_ingest_publishable_key")
	assert_contains(requests[1].body, '"actor_identifier":"user-legacy-example"')
	assert_contains(requests[1].body, '"kind":"anon"')
	assert_equal(dual:snapshot().consent_recorded, 1)
	restore()
	storage.reset()
end

-- Fleet rule (restore-across-override): a configured anonymous_id override
-- that REPLACES a different valid persisted actor boots a FRESH identity —
-- consent "unknown" (the old actor's persisted decision is ignored, never
-- applied to the new actor), the old actor's spool purged by the standard
-- non-granted init path, and the identity rewrite persists the override with
-- NO consent key carried over. Without this, the new actor would boot
-- "granted" without ever deciding, load the old actor's envelopes, and the
-- boot rewrite would durably re-record the old decision under the new id.
local function test_anonymous_override_mismatch_boots_fresh_identity()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- Launch 1: actor "anon-one" grants (receipt acked), then a transient
	-- publish failure leaves granted-era envelopes on the durable spool.
	local first = assert(sdk.new(config({
		anonymous_id = "anon-one",
		flush_interval_seconds = 9999,
	})))
	assert_true(first:set_consent(true))
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"actor_identifier":"anon-one"')
	local first_key = requests[1].body:match('"idempotency_key":"([^"]+)"')
	local first_decided = requests[1].body:match('"decided_at":"([^"]+)"')
	assert_true(first_key ~= nil and first_decided ~= nil)
	next_status = 500
	assert_true(first:track("granted_era_event"))
	assert_equal(first:flush(), false)
	assert_true(first:shutdown("app_final"))
	local spool_before = stored_spool_record(stores)
	assert_true(spool_before ~= nil and #spool_before.events > 0,
		"launch 1 must leave a granted-era spool behind")

	-- Launch 2: a DIFFERENT override. Fresh identity: consent unknown, the
	-- old actor's spool purged unloaded, nothing laundered into the record.
	reset()
	next_status = 202
	socket.now = socket.now + 5 -- a later wall clock for the fresh decision
	local issues = {}
	local second = assert(sdk.new(config({
		anonymous_id = "anon-two",
		flush_interval_seconds = 9999,
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	assert_equal(second.anonymous_id, "anon-two")
	assert_equal(second.consent_state, "unknown",
		"an overriding actor must not inherit the previous actor's decision")
	assert_equal(#second.spool_batches, 0, "the old actor's spool must not load")
	assert_equal(second.spool_purge_pending, false)
	assert_equal(#stored_spool_record(stores).events, 0,
		"the old actor's spool is purged by the non-granted init path")
	local blocked, blocked_err = second:track("blocked_after_override")
	assert_equal(blocked, false)
	assert_equal(blocked_err, "consent_unknown")
	assert_true(second:flush())
	assert_equal(#requests, 0, "a fresh identity boots dark")
	local identity_record = storage.load(identity_scope)
	assert_equal(identity_record.anonymous_id, "anon-two")
	assert_equal(identity_record.consent_analytics, nil,
		"the boot rewrite must not re-record the old decision under the new id")
	local saw_reset = false
	for i = 1, #issues do
		if issues[i].scope == "consent"
			and issues[i].code == "identity_override_changed" then
			saw_reset = true
		end
	end
	assert_true(saw_reset, "the fresh-identity reset must surface via diagnostics")

	-- A grant after the mismatch is the NEW actor's own decision: fresh
	-- receipt, fresh idempotency key, its own decided_at.
	assert_true(second:set_consent(true))
	assert_equal(#requests, 1)
	assert_equal(requests[1].url, "http://localhost:8080/v1/consent")
	assert_contains(requests[1].body, '"actor_identifier":"anon-two"')
	local fresh_key = requests[1].body:match('"idempotency_key":"([^"]+)"')
	local fresh_decided = requests[1].body:match('"decided_at":"([^"]+)"')
	assert_not_equal(fresh_key, first_key,
		"a fresh decision mints a fresh idempotency key")
	assert_not_equal(fresh_decided, first_decided,
		"a fresh decision stamps its own decided_at")
	restore()
	storage.reset()
end

-- The override rule is a MISMATCH rule: an override matching the persisted
-- actor restores the persisted decision (and the granted-era spool) exactly
-- like an override-less relaunch.
local function test_anonymous_override_match_restores_unchanged()
	reset()
	storage.reset()
	local _, restore = install_stub_sys_storage()
	local first = assert(sdk.new(config({
		anonymous_id = "anon-stable",
		flush_interval_seconds = 9999,
	})))
	assert_true(first:set_consent(true))
	next_status = 500
	assert_true(first:track("granted_era_event"))
	assert_equal(first:flush(), false)
	assert_true(first:shutdown("app_final"))

	reset()
	next_status = 202
	local second = assert(sdk.new(config({
		anonymous_id = "anon-stable",
		flush_interval_seconds = 9999,
	})))
	assert_equal(second.consent_state, "granted",
		"a matching override restores the persisted decision unchanged")
	assert_true(#second.spool_batches > 0,
		"the granted-era spool loads for re-send under the same actor")
	assert_true(second:flush())
	assert_true(#requests > 0)
	local resent = false
	for i = 1, #requests do
		if requests[i].body
			and requests[i].body:find('"event_name":"granted_era_event"', 1, true) then
			resent = true
		end
	end
	assert_true(resent, "the same actor's envelopes re-send unchanged")
	restore()
	storage.reset()
end

-- The owed-wipe rule applies to the override-mismatch purge like to every
-- other non-granted init purge: a failed wipe fails closed — the old actor's
-- record never loads, set_consent(true) is refused (spool_purge_failed) until
-- the retried wipe lands, and only then does the new actor's grant apply.
local function test_override_mismatch_purge_failure_fails_closed()
	reset()
	storage.reset()
	local _, restore = install_stub_sys_storage()
	local first = assert(sdk.new(config({
		anonymous_id = "anon-one",
		flush_interval_seconds = 9999,
	})))
	assert_true(first:set_consent(true))
	next_status = 500
	assert_true(first:track("granted_era_event"))
	assert_equal(first:flush(), false)
	assert_true(first:shutdown("app_final"))

	reset()
	next_status = 202
	local heal = break_spool_saves()
	local second = assert(sdk.new(config({
		anonymous_id = "anon-two",
		flush_interval_seconds = 9999,
	})))
	assert_equal(second.consent_state, "unknown")
	assert_equal(second.spool_purge_pending, true,
		"a failed override-mismatch purge fails closed")
	assert_equal(#second.spool_batches, 0)
	local ok, err = second:set_consent(true)
	assert_equal(ok, false)
	assert_equal(err, "spool_purge_failed",
		"the grant is refused while the wipe is owed")
	assert_equal(second.consent_state, "unknown")
	heal()
	assert_true(second:set_consent(true))
	assert_equal(second.consent_state, "granted")
	assert_equal(#second.spool_batches, 0,
		"nothing of the old actor's spool survives the retried purge")
	assert_equal(#storage.load_spool(spool_scope), 0,
		"the retried purge cleared the old actor's record")
	restore()
	storage.reset()
end

-- A failed durable append is SURFACED, not silent: set_consent returns
-- false, "consent_outbox_persist_failed" while the undelivered receipt exists
-- only in memory (delivery is still attempted — the server-side record is the
-- point; durability is the process-death backstop). persist() retries the
-- owed write even with the event spool disabled — the outbox is independent
-- of event spooling.
local function test_set_consent_surfaces_receipt_persist_failure()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	local outbox_writes_fail = true
	local plain_save = sys.save
	sys.save = function(path, record)
		if outbox_writes_fail and path:sub(-15) == "/consent-outbox" then
			return false
		end
		return plain_save(path, record)
	end

	next_status = 500
	local client = assert(sdk.new(config({ spool_enabled = false })))
	assert_true(client:identify("user-example"))
	local ok, err = client:set_consent(false)
	assert_equal(ok, false)
	assert_equal(err, "consent_outbox_persist_failed",
		"an undelivered receipt without a durable copy must be surfaced")
	assert_equal(client:snapshot().consent_outbox_persist_failed >= 1, true)
	assert_equal(#client.consent_outbox, 1, "the receipt still delivers from memory")
	assert_equal(client.consent_state, "denied", "the decision itself applied")

	-- storage recovers; the focus-loss persist() retries the owed write even
	-- though the event spool is disabled
	outbox_writes_fail = false
	local persist_ok, persist_err = client:persist()
	assert_equal(persist_ok, false)
	assert_equal(persist_err, "spool_disabled", "the persist result stays about the event snapshot")
	assert_equal(client.consent_outbox_dirty, false, "persist() must retry the owed outbox write")
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1, "the retained receipt is durable after the retry")

	-- and a delivery that acks synchronously needs no durability error even
	-- while outbox writes fail. The clock advance waits out the receipt
	-- window an earlier failure in this fixture armed (A6).
	reset()
	outbox_writes_fail = true
	next_status = 202
	socket.now = socket.now + 2
	assert_true(client:set_consent(true),
		"a synchronously acknowledged receipt has nothing left to lose")
	restore()
	storage.reset()
end

-- A transient storage failure must never evict a receipt: a failed write
-- FAILS the save (the caller keeps the receipt in its mirror, marked owed)
-- instead of evicting toward an empty record whose write then "succeeds" —
-- which would silently drop the receipt while reporting success. And when
-- the dispatch path's immediate retry lands the owed write, set_consent
-- reports success on the CURRENT durability state, not the first attempt.
local function test_transient_outbox_save_failure_never_evicts()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	local fail_next_outbox_write = true
	local plain_save = sys.save
	sys.save = function(path, record)
		if fail_next_outbox_write and path:sub(-15) == "/consent-outbox" then
			fail_next_outbox_write = false
			return false
		end
		return plain_save(path, record)
	end

	-- storage level: the fail-then-succeed sequence must fail the save and
	-- leave nothing evicted, not write an empty record and report the list
	local entry = {
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "user-example",
		categories = { analytics = false },
		decided_at = "2026-07-12T00:00:00Z",
		idempotency_key = "receipt-transient",
	}
	local saved = storage.save_consent_outbox(identity_scope, { entry })
	assert_equal(saved, nil, "a failed write must fail the save, never evict toward success")
	local record = stored_consent_outbox_record(stores)
	assert_true(record == nil, "the failed write must not have produced an emptied record")
	saved = storage.save_consent_outbox(identity_scope, { entry })
	assert_equal(#saved, 1, "the retried save keeps the receipt")
	assert_equal(saved[1].idempotency_key, "receipt-transient")

	-- client level: a first-write failure healed by the dispatch path's
	-- immediate retry is durable by the time set_consent returns — success,
	-- with the receipt retained on disk for the 500-failed delivery
	reset()
	storage.reset()
	fail_next_outbox_write = true
	next_status = 500
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	assert_true(client:set_consent(false),
		"an append made durable by the in-call retry must not be reported as a failure")
	assert_equal(client.consent_outbox_dirty, false)
	assert_equal(#client.consent_outbox, 1, "the transiently failed delivery stays retained")
	record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1, "the receipt is durable despite the first failed write")
	restore()
	storage.reset()
end

-- Host-supplied identifiers are clamped to 512 bytes at acceptance: the
-- identity record and every consent receipt persist them verbatim, so an
-- unbounded identifier could push those sys.save records past the engine's
-- save-file record cap (see max_identifier_bytes in client.lua). An
-- exactly-max identifier is accepted and round-trips through the identity
-- record and the receipt's actor_identifier/anonymous_id snapshot; max+1 is
-- rejected with the previous identity retained — never truncated, since
-- truncation could collide distinct identities. Out-of-bounds config
-- identities and a legacy oversized persisted anonymous ID fall back to the
-- stored/fresh identity the same way any other invalid value does.
local function test_identifier_byte_clamp_boundary()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	local max_user = "u" .. string.rep("x", 511)
	local over_user = "u" .. string.rep("x", 512)
	local max_anon = "a" .. string.rep("y", 511)
	local over_anon = "a" .. string.rep("y", 512)
	assert_equal(#max_user, 512)
	assert_equal(#over_user, 513)

	local client = assert(sdk.new(config()))
	-- exactly-max anonymous_id accepted; it persists to the identity record
	assert_true(client:set_anonymous_id(max_anon))
	assert_equal(client.anonymous_id, max_anon)
	assert_equal(storage.load(identity_scope).anonymous_id, max_anon)
	-- max+1 rejected; the previous identity is retained, not truncated
	local ok, err = client:set_anonymous_id(over_anon)
	assert_equal(ok, false)
	assert_equal(err, "invalid_anonymous_id")
	assert_equal(client.anonymous_id, max_anon, "the previous anonymous_id must be retained")
	assert_equal(storage.load(identity_scope).anonymous_id, max_anon)

	-- exactly-max user_id accepted; max+1 rejected with the previous retained
	assert_true(client:identify(max_user))
	assert_equal(client.user_id, max_user)
	ok, err = client:identify(over_user)
	assert_equal(ok, false)
	assert_equal(err, "invalid_user_id")
	assert_equal(client.user_id, max_user, "the previous user_id must be retained")

	-- the receipt snapshots the accepted max-length identifiers verbatim and
	-- they round-trip through the durable outbox (500 keeps it retained)
	next_status = 500
	assert_true(client:set_consent(true))
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1)
	assert_equal(record.receipts[1].actor_identifier, max_user)
	assert_equal(record.receipts[1].anonymous_id, max_anon)
	local loaded = storage.load_consent_outbox(identity_scope)
	assert_equal(loaded[1].actor_identifier, max_user, "a max-length actor must round-trip the outbox")

	-- config-supplied identities over the bound fall back like any other
	-- invalid config identity: user_id unset, anonymous_id from the store
	local follower = assert(sdk.new(config({ user_id = over_user, anonymous_id = over_anon })))
	assert_equal(follower.user_id, nil, "an out-of-bounds config user_id must be ignored")
	assert_equal(follower.anonymous_id, max_anon,
		"an out-of-bounds config anonymous_id must fall back to the stored identity")

	-- a legacy oversized persisted anonymous ID (written before the clamp)
	-- is replaced by a fresh identity and the record self-heals
	assert_true(storage.save(identity_scope, { anonymous_id = over_anon }))
	local healed = assert(sdk.new(config()))
	assert_not_equal(healed.anonymous_id, over_anon)
	assert_equal(#healed.anonymous_id, 36, "a fresh UUID must replace the oversized stored id")
	assert_equal(storage.load(identity_scope).anonymous_id, healed.anonymous_id)
	restore()
	storage.reset()
end

-- The wedge the identifier clamp exists to prevent (GAP-075 follow-up to
-- #30's SECURITY caveats): Defold's sys.save caps a record at ~512 KB and a
-- failed consent-outbox write deliberately never evicts, so ONE receipt
-- carrying an oversized host-supplied identifier used to fail the outbox
-- write on every retry — the record stayed owed (dirty) forever and
-- shutdown() wedged in consent_pending. Simulated with a size-capped
-- sys.save standing in for the engine's record cap: (a) at the storage
-- level an entry with an out-of-bounds actor still fails persistently (the
-- wedge vector the unclamped acceptance path used to feed); (b) at the
-- client level the clamp keeps such an identifier from ever entering, the
-- outbox record stays byte-sane and writable, and shutdown() completes over
-- the durably retained receipt.
local function test_oversized_identifier_cannot_wedge_consent_teardown()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	-- Scaled-down stand-in for the engine's fixed save-record cap: a record
	-- whose encoded size exceeds it fails to save, exactly like sys.save
	-- refusing a > 512 KB table.
	local record_cap = 4096
	local plain_save = sys.save
	sys.save = function(path, record)
		if #json.encode(record) > record_cap then
			return false
		end
		return plain_save(path, record)
	end

	-- (a) storage level: an entry with an oversized actor_identifier used to
	-- fail the outbox write on EVERY attempt (a failed write never evicts, so
	-- the record could never converge — the wedge). The sanitizer now drops
	-- it fail-safe, like any malformed entry, so the write SUCCEEDS without
	-- it and the persisted record stays byte-sane
	local oversized_entry = {
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = string.rep("x", record_cap),
		categories = { analytics = true },
		decided_at = "2026-07-19T00:00:00Z",
		idempotency_key = "receipt-oversized",
	}
	local saved = storage.save_consent_outbox(identity_scope, { oversized_entry })
	assert_true(saved ~= nil, "the write must succeed once the oversized entry is dropped")
	assert_equal(#saved, 0, "the oversized entry must be dropped at sanitize, never persisted")
	local seeded = stored_consent_outbox_record(stores)
	assert_true(seeded ~= nil and #seeded.receipts == 0,
		"the durable record persists without the oversized entry")

	-- (b) client level: the clamp rejects the oversized identifier at
	-- acceptance, so no receipt can ever carry it
	local oversized_user = string.rep("x", record_cap)
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			callback(nil, nil, "token backend down")
		end,
	})))
	local ok, err = client:identify(oversized_user)
	assert_equal(ok, false)
	assert_equal(err, "invalid_user_id")
	assert_equal(client.user_id, nil, "the oversized identifier must not enter")

	-- the decision's receipt snapshots the in-bounds anonymous_id instead
	-- and is durably retained (no token: delivery waits for the next launch)
	assert_true(client:set_consent(true), "the outbox write must succeed with clamped identifiers")
	assert_equal(client.consent_outbox_dirty, false)
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1)
	assert_equal(record.receipts[1].actor_identifier, client.anonymous_id)
	assert_true(#json.encode(record) <= record_cap, "the persisted outbox record stays byte-sane")

	-- and teardown COMPLETES over the durable receipt instead of wedging in
	-- consent_pending
	assert_true(client:shutdown("app_final"),
		"shutdown must not wedge in consent_pending when identifiers are clamped")
	assert_equal(client.initialized, false)

	-- (c) the upgrade path: a LEGACY record written before the clamp existed
	-- can already hold a near-cap receipt on disk (it fit alone when old code
	-- wrote it). The load-time sanitizer drops it like any other malformed
	-- entry, so the next decision's rewrite — which would exceed the save cap
	-- with the oversized entry still aboard — stays writable and teardown
	-- still completes: a previously wedged install self-heals on upgrade.
	storage.reset()
	local _, outbox_path = stored_consent_outbox_record(stores)
	local legacy_sane = {
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "user-legacy",
		categories = { analytics = false },
		decided_at = "2026-07-18T00:00:00Z",
		idempotency_key = "receipt-legacy-sane",
	}
	-- seed the poisoned pre-clamp file directly (old code could write it
	-- when the oversized receipt still fit the record on its own)
	stores[outbox_path] = { receipts = { oversized_entry, legacy_sane } }
	local salvaged = storage.load_consent_outbox(identity_scope)
	assert_equal(#salvaged, 1, "the oversized legacy receipt must be dropped at load")
	assert_equal(salvaged[1].idempotency_key, "receipt-legacy-sane")

	-- Mode A client over the legacy record with the consent endpoint offline:
	-- the sane receipt is retained, a NEW decision still persists durably,
	-- and shutdown() completes instead of staying consent_pending
	next_status = 0
	local upgraded = assert(sdk.new(config_mode_a()))
	assert_equal(#upgraded.consent_outbox, 1, "the sane legacy receipt is retained")
	assert_true(upgraded:set_consent(false), "a new decision must persist over the legacy record")
	assert_equal(upgraded.consent_outbox_dirty, false)
	local upgraded_record = stored_consent_outbox_record(stores)
	assert_equal(#upgraded_record.receipts, 2, "legacy sane + new receipt are durable")
	assert_true(#json.encode(upgraded_record) <= record_cap,
		"the rewritten record stays under the save cap")
	assert_true(upgraded:shutdown("app_final"),
		"an upgraded install must not stay wedged in consent_pending")
	restore()
	storage.reset()
end

-- A receipt in flight when shutdown() tears the client down settles its own
-- bookkeeping, but must NOT chain the next retained receipt onto the wire —
-- the SDK is torn down; the remaining durable receipts re-send next launch.
local function test_no_receipt_chaining_after_shutdown()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
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
	local ok = client:set_consent(true)
	assert_true(ok, "the queued second receipt is durably retained")
	assert_equal(#requests, 1, "the second receipt queues behind the in-flight first")
	assert_equal(#client.consent_outbox, 2)

	-- both receipts are safely on disk, so teardown completes over the
	-- in-flight send
	assert_true(client:shutdown("app_final"))
	assert_equal(client.initialized, false)

	-- the late ack settles the first receipt but must not dispatch the second
	callbacks[1](nil, nil, { status = 202, response = "" })
	assert_equal(#requests, 1, "no receipt may be dispatched after teardown")
	assert_equal(client:snapshot().consent_recorded, 1)
	local record = stored_consent_outbox_record(stores)
	assert_equal(#record.receipts, 1, "the remaining receipt stays durably retained")

	-- the next launch delivers it once the session vouches for its verified
	-- actor again (parked until then)
	reset()
	callbacks = {}
	http.request = original_request
	next_status = 202
	local second = assert(sdk.new(config()))
	assert_equal(#requests, 0, "the verified receipt stays parked before identify")
	assert_true(second:identify("user-example"))
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"categories":{"analytics":true}')
	assert_equal(second:snapshot().consent_recorded, 1)
	restore()
	storage.reset()
end

-- Capability discovery: a game feature-detects the new consent surface before
-- init() and without version parsing; unknown names are false everywhere.
-- GAP-036 schema-revision handshake, emission side: every events:batch
-- request declares the SDK's schema-set revision in the
-- X-ShardPilot-Schema-Revision request header — and ONLY the batch route.
-- The consent route shares the same transport dispatch and must stay
-- header-free (the crash and remote-config routes use their own transports,
-- pinned header-free in their own suites). The declaration is a header,
-- never a body field: the ingest body is strict-decoded server-side and an
-- unknown field would 400 the whole batch.
local function test_schema_revision_header_on_batch_only()
	reset()
	storage.reset()
	seed_granted_consent()
	local client = assert(sdk.new(config()))
	assert_true(client:identify("user-example"))
	assert_true(client:track("play_cta_click"))
	assert_true(client:flush({ include_summaries = false }))
	assert_equal(#requests, 1)
	local batch = requests[1]
	assert_equal(batch.url, "http://localhost:8080/v1/events:batch")
	-- The exact provisioned value: "sha256:" + the 64-hex digest of the
	-- analytics-service schema set this SDK build was provisioned against
	-- (a public content identity, re-synced when the schema set changes).
	assert_equal(batch.headers["X-ShardPilot-Schema-Revision"], schema_revision.REVISION)
	assert_equal(schema_revision.REVISION,
		"sha256:e1ba01d4b76b9e73444e2edd5639281929fd89496cadc1dcc79eb68208c6a0a0")
	assert_true(schema_revision.REVISION:match("^sha256:[0-9a-f]+$") ~= nil,
		"the built-in revision must be sha256: plus lowercase hex")
	assert_equal(#schema_revision.REVISION, 71)
	assert_not_contains(batch.body, "schema_revision")
	assert_not_contains(batch.body, "X-ShardPilot-Schema-Revision")

	-- The consent route rides the same dispatch and must NOT declare.
	assert_true(client:set_consent(true))
	assert_equal(#requests, 2)
	local consent = requests[2]
	assert_contains(consent.url, "/v1/consent")
	assert_equal(consent.headers["X-ShardPilot-Schema-Revision"], nil,
		"the consent route must not carry the schema-revision header")
	assert_equal(consent.headers["Authorization"], "Bearer client-token-placeholder")
	storage.reset()
end

-- Config knob: a non-empty string overrides the declared value; false or ""
-- stops declaring entirely (the server treats an undeclared batch as
-- always-passing, so disabling is the no-rebuild escape hatch).
local function test_schema_revision_override_and_disable()
	reset()
	storage.reset()
	seed_granted_consent()

	-- Override: a custom declared value (assembled, not a real digest).
	local override = "sha256:" .. string.rep("ab", 32)
	local client = assert(sdk.new(config({ schema_revision = override })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("boot"))
	assert_true(client:flush({ include_summaries = false }))
	assert_equal(#requests, 1)
	assert_equal(requests[1].headers["X-ShardPilot-Schema-Revision"], override)

	-- Disable via false: no header on the batch at all.
	reset()
	local silent = assert(sdk.new(config({ schema_revision = false })))
	assert_equal(silent.config.schema_revision, nil)
	assert_true(silent:identify("user-example"))
	assert_true(silent:track("boot"))
	assert_true(silent:flush({ include_summaries = false }))
	assert_equal(#requests, 1)
	assert_equal(requests[1].headers["X-ShardPilot-Schema-Revision"], nil,
		"schema_revision = false must stop declaring")

	-- Disable via empty string: the same escape hatch.
	reset()
	local empty = assert(sdk.new(config({ schema_revision = "" })))
	assert_equal(empty.config.schema_revision, nil)
	assert_true(empty:identify("user-example"))
	assert_true(empty:track("boot"))
	assert_true(empty:flush({ include_summaries = false }))
	assert_equal(#requests, 1)
	assert_equal(requests[1].headers["X-ShardPilot-Schema-Revision"], nil,
		'schema_revision = "" must stop declaring')
	storage.reset()
end

-- GAP-036, response side: a 409 whose error.code is
-- "schema_revision_mismatch" is TERMINAL for the batch — the server sends no
-- Retry-After and a retry from the same build can never succeed. The batch
-- must ride the existing terminal-failure path (dropped; never retained,
-- deferred, or spooled) with a clear log line naming the declared and served
-- revisions. Discrimination is by error.code, never the bare 409 status:
-- another 409 code takes the same terminal transport path without the
-- schema-revision log line.
local function test_schema_revision_mismatch_409_is_terminal()
	reset()
	storage.reset()
	seed_granted_consent()
	local served = "sha256:" .. string.rep("cd", 32)
	local issues = {}
	next_status = 409
	next_response_body = '{"error":{"code":"schema_revision_mismatch",'
		.. '"message":"the declared schema revision does not match the schema revision this ingest-api serves",'
		.. '"details":[{"field":"X-ShardPilot-Schema-Revision","code":"schema_revision_mismatch"}]}}'
	next_response_headers = { ["x-shardpilot-schema-revision"] = served }
	local client = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	assert_true(client:identify("user-example"))
	assert_true(client:track("boot"))
	local logged = {}
	local function capture_print(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(i, ...)))
		end
		logged[#logged + 1] = table.concat(parts, "\t")
	end
	local real_print = print
	print = capture_print
	local ok = client:flush({ include_summaries = false })
	print = real_print
	assert_equal(ok, false)
	assert_equal(#requests, 1, "a schema-revision 409 must never trigger an immediate retry")
	assert_equal(client:snapshot().last_error, "http_409:schema_revision_mismatch")
	-- Terminal: dropped, not retained for retry, no deferral or backoff.
	assert_equal(client.in_flight_batch, nil)
	assert_equal(client.publish_retry_after_ms, nil)
	assert_equal(client.publish_backoff_attempt, 0)
	assert_equal(client:snapshot().dropped, 1)
	-- Never spooled: a terminal reject must not re-send on a later launch.
	assert_equal(#client.spool_record, 0)
	-- Surfaced through diagnostics like every batch-level rejection.
	assert_equal(#issues, 1)
	assert_equal(issues[1].scope, "batch")
	assert_equal(issues[1].code, "schema_revision_mismatch")
	-- The log line names both revisions and the fix.
	assert_equal(#logged, 1)
	assert_contains(logged[1], "schema revision mismatch")
	assert_contains(logged[1], schema_revision.REVISION)
	assert_contains(logged[1], served)
	assert_contains(logged[1], "schema_revision = false")
	-- The pipeline is not wedged: a fresh batch publishes immediately.
	reset()
	assert_true(client:track("after"))
	assert_true(client:flush({ include_summaries = false }))
	assert_equal(#requests, 1)

	-- A DIFFERENT 409 code: same terminal transport handling, no
	-- schema-revision log line.
	reset()
	next_status = 409
	next_response_body = '{"error":{"code":"workspace_override_conflict","message":"conflict"}}'
	assert_true(client:track("other"))
	logged = {}
	print = capture_print
	local other_ok = client:flush({ include_summaries = false })
	print = real_print
	assert_equal(other_ok, false)
	assert_equal(client:snapshot().last_error, "http_409:workspace_override_conflict")
	assert_equal(client.in_flight_batch, nil)
	assert_equal(#logged, 0, "only schema_revision_mismatch produces the schema log line")
	storage.reset()
end

local function test_supports_capability_discovery()
	assert_equal(sdk.supports("consent_receipt_outbox"), true)
	assert_equal(sdk.supports("consent_state_denied_forced_minor"), true)
	assert_equal(sdk.supports("schema_revision_declaration"), true)
	assert_equal(sdk.supports("time_travel"), false)
	assert_equal(sdk.supports(nil), false)
	assert_equal(sdk.supports(42), false)
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
	test_consent_receipts_deliver_serially_in_decision_order,
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
	test_shutdown_queue_full_completes_after_final_flush,
	test_flush_and_shutdown_wait_for_async_publish,
	test_singleton_shutdown_keeps_client_after_retryable_failure,
	test_batch_response_surfaces_per_event_outcomes,
	test_batch_response_surfaces_suppressed_no_consent,
	test_batch_response_without_events_array_keeps_accepted,
	test_retry_after_defers_next_publish,
	test_503_retry_after_defers_next_publish,
	test_flush_sends_consent_receipt_before_event_batch,
	test_grant_receipt_retry_after_defers_event_publish,
	test_shutdown_completes_with_only_deferred_grant_receipt,
	test_grant_behind_deferred_head_receipt_holds_events,
	test_grant_behind_head_holds_events_until_dispatched,
	test_toggled_grant_behind_in_flight_head_still_holds_events,
	test_restart_dispatches_retained_grant_before_first_batch,
	test_successful_publish_clears_deferral,
	test_backoff_on_sustained_transient_failures,
	test_retry_wake_republishes_without_a_flush_tick,
	test_error_envelope_is_surfaced,
	test_diagnostics_hook_errors_are_swallowed,
	test_invalid_diagnostics_rejected,
	test_mode_a_api_key_is_bearer,
	test_mode_a_consent_uses_api_key_bearer,
	test_client_source_keeps_anonymous_id_both_modes,
	test_get_anonymous_id_matches_wire,
	test_track_before_session_start_lazily_opens_session,
	test_spool_persists_transient_failure_and_resends_next_launch,
	test_spool_overflow_evicts_oldest_first,
	test_spool_corrupted_record_starts_clean,
	test_spool_cleared_by_denied_consent,
	test_consent_unknown_blocks_all_analytics_egress,
	test_blocked_period_samples_never_summarized,
	test_consent_unknown_purges_unproven_spool_at_init,
	test_identity_read_failure_purges_spool,
	test_spool_permanent_reject_removes_entry_and_diagnoses,
	test_shutdown_spools_undelivered_and_finalizes,
	test_shutdown_full_queue_spools_session_end_and_summaries,
	test_persist_snapshots_queue_while_running,
	test_persist_captures_owed_summaries_across_relaunch,
	test_owed_summary_preserves_actor_across_identify_mode_a,
	test_identify_refused_while_owed_summary_pending_mode_b,
	test_set_anonymous_id_rejected_while_owed_summary_pending_mode_b,
	test_flush_drains_owed_summaries_within_same_call,
	test_persist_single_write_keeps_whole_remnant_under_caps,
	test_denial_marker_imposes_over_stale_granted_record,
	test_denial_marker_preserves_forced_minor_flavor,
	test_foreign_actor_denial_marker_stays_inert_and_undeleted,
	test_newer_denial_receipt_blocks_granted_restore,
	test_same_second_denial_tie_imposes_fail_closed,
	test_same_second_regrant_outranks_undelivered_denial,
	test_stale_denial_marker_never_beats_newer_grant,
	test_unreadable_marker_fail_closed_stays_transient,
	-- Declared inline rather than as `local function`: Lua caps a chunk at
	-- 200 locals and this file sits at the ceiling, so one more top-level
	-- local breaks the 5.4 job while 5.1/LuaJIT still pass. The limit is per
	-- FUNCTION, so this is a function and not a do-block.
	-- The consent receipt outbox is the THIRD accepted denial witness -- shutdown
	-- finalizes on a retained receipt alone when the record and the marker both
	-- failed to write -- but its loader collapsed every failure into a bare empty
	-- list. An unreadable trail therefore read as "nothing was ever refused" and a
	-- granted record restored unconditionally. It now fails closed like the marker
	-- arm, for the session only, on BOTH shapes: a read that throws, and a file
	-- that parses while holding a receipt this build cannot understand.
	function()
	reset()
	storage.reset()
	local stores, restore = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-outbox-unreadable",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-07T00:00:00Z",
		consent_decision_seq = 1,
	}))
	-- WHOLE-TRAIL: the outbox read throws while every other file reads fine.
	local real_load = sys.load
	sys.load = function(path)
		if path:sub(-15) == "/consent-outbox" then
			error("corrupt consent outbox")
		end
		return real_load(path)
	end
	local client = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(client.consent_state, "denied",
		"an unreadable receipt trail fails closed over the granted restore")
	local tok, terr = client:track("gated_event")
	assert_equal(tok, false)
	assert_equal(terr, "consent_denied")
	-- ROTATION IS REFUSED while the evidence is unreadable. The unread trail
	-- may hold a denial for the CURRENT anon; carrying the restored grant onto
	-- a new one would make that denial foreign when the file heals -- the
	-- marker reads as another actor's and the belt skips it on the anon
	-- mismatch -- so analytics would reopen under B despite A's refusal.
	local rok, rerr = client:set_anonymous_id("anon-rotated-while-imposed")
	assert_equal(rok, false)
	assert_equal(rerr, "consent_evidence_unreadable",
		"identity rotation cannot launder a denial the trail may still hold")
	-- MEMORY ONLY. persist_identity is the single place consent reaches disk,
	-- so the shadow is asserted at its own boundary: without it this call
	-- stamps the manufactured denial durably and the grant never returns.
	-- (That every write funnels through here is what makes one guard enough;
	-- the rotation refusal above is the belt on the one caller that could
	-- also carry the grant onto a different actor.)
	assert_true(client:persist_identity())
	local identity_record = nil
	for path, record in pairs(stores) do
		if path:sub(-9) == "/identity" then
			identity_record = record
		end
	end
	assert_true(identity_record ~= nil
			and identity_record.consent_analytics == "granted",
		"a maintenance identity write must not make the session refusal durable")
	-- A fresh decision ends the imposition and persists ITSELF, not the
	-- shadowed grant.
	assert_true(client:set_consent(false))
	for path, record in pairs(stores) do
		if path:sub(-9) == "/identity" then
			identity_record = record
		end
	end
	assert_true(identity_record ~= nil
			and identity_record.consent_analytics == "denied",
		"an explicit decision persists as itself once the imposition ends")
	sys.load = real_load
	restore()
	storage.reset()

	-- PARTIAL: the trail parses and holds one receipt this build refuses.
	-- The whole-record guard cannot see this, and the salvageable subset is
	-- not a complete trail.
	reset()
	storage.reset()
	local stores2, restore2 = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-outbox-partial",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-07T00:00:00Z",
		consent_decision_seq = 1,
	}))
	assert_true(storage.save_consent_outbox(identity_scope, {}))
	for path, record in pairs(stores2) do
		if path:sub(-15) == "/consent-outbox" then
			record.receipts = { "this-entry-is-not-a-table" }
		end
	end
	storage.reset()
	local partial = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(partial.consent_state, "denied",
		"a trail holding an unreadable ENTRY fails closed too")
	-- THE DAMAGED FILE IS NOT REPLACED BY ITS SALVAGEABLE SUBSET. The mirror
	-- holds what could be read; writing that over the trail would leave a
	-- CLEAN file and the next launch would restore the grant -- the evidence
	-- destroyed by an ordinary dispatch acknowledgment rather than by anything
	-- resembling a decision. The write is refused and marked owed.
	assert_equal(partial:persist_consent_outbox(), false,
		"the outbox rewrite is held while the trail is unreadable")
	assert_true(partial.consent_outbox_dirty, "and the held write is recorded as owed")
	local on_disk = nil
	for path, record in pairs(stores2) do
		if path:sub(-15) == "/consent-outbox" then
			on_disk = record
		end
	end
	assert_true(on_disk ~= nil and on_disk.receipts[1] == "this-entry-is-not-a-table",
		"the damaged entry is still on disk, unreplaced")
	restore2()
	storage.reset()

	-- A HOLE IS NOT THE END OF THE TABLE. `#entries` measures the array prefix
	-- only, so a receipt sitting past a hole (or under a non-array key) is
	-- never visited by the shape loop and would never be counted -- the loader
	-- would report a fully understood trail while a denial sat unread behind
	-- the gap.
	reset()
	storage.reset()
	local stores4, restore4 = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-outbox-hole",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-07T00:00:00Z",
		consent_decision_seq = 1,
	}))
	assert_true(storage.save_consent_outbox(identity_scope, {}))
	for path, record in pairs(stores4) do
		if path:sub(-15) == "/consent-outbox" then
			-- Index 2 is absent: #receipts is 1, and index 3 lives past it.
			record.receipts = {
				[1] = {
					idempotency_key = "key-visible",
					workspace_id = "ws",
					app_id = "app",
					environment_id = "env",
					actor_identifier = "anon-outbox-hole",
					decided_at = "2026-07-08T00:00:00Z",
					decision_seq = 2,
					categories = { analytics = true },
					anonymous_id = "anon-outbox-hole",
				},
				[3] = "a receipt the prefix loop never reaches",
			}
		end
	end
	storage.reset()
	local holed = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(holed.consent_state, "denied",
		"a receipt hidden past a hole still makes the trail unreadable")
	-- A no-op id assignment rotates nothing and can launder nothing: refusing
	-- it would make a safe re-sync read as a failure.
	assert_true(holed:set_anonymous_id(holed.anonymous_id),
		"re-asserting the CURRENT id is a no-op, not a rotation")
	restore4()
	storage.reset()

	-- A NONEMPTY RECORD WITH NO receipts KEY IS NOT AN ABSENT FILE. An absent
	-- file loads as an empty table here, which is why a missing key normally
	-- means honestly empty; a record carrying something else entirely is a
	-- record this build cannot make sense of.
	reset()
	storage.reset()
	local stores5, restore5 = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-outbox-nokey",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-07T00:00:00Z",
		consent_decision_seq = 1,
	}))
	assert_true(storage.save_consent_outbox(identity_scope, {}))
	for path, record in pairs(stores5) do
		if path:sub(-15) == "/consent-outbox" then
			record.receipts = nil
			record.something_else = "a record shape this build does not know"
		end
	end
	storage.reset()
	local nokey = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(nokey.consent_state, "denied",
		"a nonempty record without receipts is unreadable, not empty")
	restore5()
	storage.reset()

	-- THE WRITE HOLD IS THE OUTBOX'S OWN FACT, NOT THE SHARED IMPOSITION. An
	-- unreadable MARKER imposes the same session denial, but it says nothing
	-- about the outbox -- which here read perfectly. Holding the outbox write
	-- on the shared flag left an acknowledged receipt's rewrite owed forever
	-- and wedged shutdown() on consent_pending.
	reset()
	storage.reset()
	local stores6, restore6 = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-marker-only",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-07T00:00:00Z",
		consent_decision_seq = 1,
	}))
	-- Present but not a valid denial: the marker's own unreadable arm.
	assert_true(storage.save_consent_denial_marker(identity_scope, {
		consent_analytics = "granted",
		anonymous_id = "anon-not-a-denial",
	}))
	assert_true(storage.save_consent_outbox(identity_scope, {}))
	local marker_only = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(marker_only.consent_state, "denied",
		"the unreadable marker still imposes its session denial")
	assert_true(marker_only:persist_consent_outbox(),
		"but a READABLE outbox is not held hostage to it")
	assert_true(not marker_only.consent_outbox_dirty,
		"and its write is not left owed")
	restore6()
	storage.reset()

	-- PRESERVING THE EVIDENCE IS NOT CONDITIONAL ON HAVING A GRANT TO WITHHOLD.
	-- A denied restore imposes nothing -- there is no grant to hold back -- but
	-- it still dispatches the salvageable receipts, and their acknowledgment
	-- would rewrite the mirror over an entry that may be an undelivered denial.
	reset()
	storage.reset()
	local stores7, restore7 = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-denied-restore",
		consent_analytics = "denied",
		consent_decided_at = "2026-07-07T00:00:00Z",
		consent_decision_seq = 1,
	}))
	storage.save_consent_outbox(identity_scope, {})
	for path, record in pairs(stores7) do
		if path:sub(-15) == "/consent-outbox" then
			record.receipts = { "this-entry-is-not-a-table" }
		end
	end
	storage.reset()
	local denied_restore = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(denied_restore.consent_state, "denied",
		"the denied restore stands; nothing is imposed over it")
	assert_equal(denied_restore:persist_consent_outbox(), false,
		"but the damaged trail is still held -- evidence outlives the state that read it")
	restore7()
	storage.reset()

	-- A REGENERATED ACTOR MUST NOT INHERIT THE SHADOWED GRANT. When the stored
	-- anon is missing or corrupt this boot mints a new one, which ordinarily
	-- just inherits this install's record. Combined with an imposition it stops
	-- being harmless: shadowing only the consent fields would write (new actor,
	-- restored grant), and the healed evidence's denial -- which belongs to the
	-- OLD actor -- then reads as foreign and analytics reopen. The whole write
	-- is refused, not just its consent half.
	reset()
	storage.reset()
	local stores8, restore8 = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		-- Oversized: valid_identity caps the byte length, so this fails the
		-- check and the boot mints a fresh id.
		anonymous_id = string.rep("x", 600),
		consent_analytics = "granted",
		consent_decided_at = "2026-07-07T00:00:00Z",
		consent_decision_seq = 1,
	}))
	assert_true(storage.save_consent_outbox(identity_scope, {}))
	for path, record in pairs(stores8) do
		if path:sub(-15) == "/consent-outbox" then
			record.receipts = { "this-entry-is-not-a-table" }
		end
	end
	storage.reset()
	local regen = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_true(regen.anonymous_id_regenerated,
		"the corrupt stored anon really was replaced this boot")
	assert_equal(regen.consent_state, "denied",
		"and the unreadable trail withholds the inherited grant")
	assert_equal(regen:persist_identity(), false,
		"no identity write may bind the shadowed grant to an actor that never made it")
	-- AND THE BOOT'S OWN SELF-HEAL MUST NOT HAVE FIRED EITHER. That rewrite runs
	-- during construction, so it is not enough for an explicit call to be
	-- refused -- the guard has to EXIST by then, which is why the outbox is read
	-- before the identity consolidation rather than after it. If the ordering
	-- regresses, the record reaches disk as (generated id, restored grant) here,
	-- before anything can refuse it.
	local healed_record = nil
	for path, record in pairs(stores8) do
		if path:sub(-9) == "/identity" then
			healed_record = record
		end
	end
	assert_true(healed_record ~= nil and #tostring(healed_record.anonymous_id) == 600,
		"the boot self-heal did not rewrite the record under the generated id")
	restore8()
	storage.reset()

	-- SALVAGEABLE EVIDENCE STILL WINS. A damaged trail that ALSO holds a
	-- readable, strictly-newer denial receipt must not simply be refused for
	-- the session: that receipt is concrete, and concrete evidence outranks
	-- an unknown -- including by being written down, which the imposition
	-- alone must never be. If the belt compared against the IMPOSED state it
	-- would never run (that state is no longer "granted") and the stale grant
	-- would survive on disk for the next launch to restore.
	reset()
	storage.reset()
	local stores3, restore3 = install_stub_sys_storage()
	assert_true(storage.save(identity_scope, {
		anonymous_id = "anon-outbox-belt",
		consent_analytics = "granted",
		consent_decided_at = "2026-07-07T00:00:00Z",
		consent_decision_seq = 1,
	}))
	assert_true(storage.save_consent_outbox(identity_scope, {}))
	for path, record in pairs(stores3) do
		if path:sub(-15) == "/consent-outbox" then
			record.receipts = {
				"this-entry-is-not-a-table",
				{
					idempotency_key = "key-belt-denial",
					workspace_id = "ws",
					app_id = "app",
					environment_id = "env",
					actor_identifier = "anon-outbox-belt",
					decided_at = "2026-07-08T00:00:00Z",
					decision_seq = 2,
					categories = { analytics = false },
					anonymous_id = "anon-outbox-belt",
				},
			}
		end
	end
	storage.reset()
	local belt = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(belt.consent_state, "denied",
		"the damaged trail refuses either way -- this leg is about what gets WRITTEN")
	local belt_record = nil
	for path, record in pairs(stores3) do
		if path:sub(-9) == "/identity" then
			belt_record = record
		end
	end
	assert_true(belt_record ~= nil
			and belt_record.consent_analytics == "denied"
			and belt_record.consent_decided_at == "2026-07-08T00:00:00Z",
		"the readable newer denial supersedes the imposition and IS persisted")
	restore3()
	storage.reset()
	end,
	test_belt_convergence_failure_writes_marker_witness,
	test_shutdown_refuses_while_witness_receipt_in_flight,
	test_ack_prune_hands_witness_to_marker,
	test_shutdown_refuses_denial_with_no_durable_witness,
	test_set_anonymous_id_rejected_while_spool_pending_mode_b,
	test_shutdown_fails_when_remnant_evicted_by_caps,
	test_spool_identity_mismatch_dropped_mode_b_kept_mode_a,
	test_shutdown_without_durable_backend_keeps_old_contract,
	test_disabled_spool_clears_persisted_record_at_init,
	test_set_consent_denied_reports_failed_spool_purge_and_retries,
	test_init_purge_failure_fails_closed_and_retries,
	test_failed_ack_removal_keeps_entries_and_retries_rewrite,
	test_loaded_record_reapplies_current_caps,
	test_persisted_retry_after_defers_startup_resend,
	test_init_purge_runs_even_when_record_unreadable,
	test_grant_blocked_until_owed_purge_lands,
	test_shutdown_surfaces_terminal_failure_not_vacuous_spool,
	test_ac8_forced_minor_sole_request_is_the_receipt,
	test_forced_minor_persists_and_gates_like_denied,
	test_consent_receipt_survives_restart_and_retries_until_acked,
	test_shutdown_completes_with_durable_outbox_and_next_launch_delivers,
	test_consent_outbox_cap_evicts_oldest_pure_grants_first,
	test_consent_outbox_cap_denial_evicted_only_among_denials,
	test_grant_refused_on_denial_full_outbox_fails_closed,
	test_grant_append_proceeds_when_old_grant_evictable,
	test_outbox_load_drops_run_before_cap_enforcement,
	test_malformed_consent_outbox_dropped_failsafe,
	test_rotation_blocked_while_prune_rewrite_owed,
	test_outbox_identity_drop_narrowed_to_unsendable_anon_receipts,
	test_receipt_actor_canonical_anon_under_publishable_key,
	test_receipt_kind_verified_in_mode_b_and_emitted_by_default,
	test_consent_kind_emission_escape_hatch_suppresses_wire_field,
	test_verified_receipt_parks_signed_out_and_dispatches_when_token_returns,
	test_parked_receipt_never_blocks_dispatch_or_gates_events,
	test_rotation_allowed_with_only_parked_verified_receipts,
	test_identify_invalidates_stale_token_before_unpark_dispatch,
	test_actor_change_parking_armed_head_resets_consent_deferral,
	test_consent_window_holds_for_same_actor_and_non_parking_changes,
	test_receipt_parking_in_flight_settles_without_arming_window,
	test_identify_refused_while_other_user_events_pending,
	test_gate_and_in_flight_release_key_to_dispatch_head_not_front,
	test_most_vouching_credential_and_401_follows_credential_used,
	test_legacy_kindless_receipt_backfills_anon_and_invalid_kind_drops,
	test_unvouchable_legacy_receipt_dropped_mode_b_only_kept_dual,
	test_anonymous_override_mismatch_boots_fresh_identity,
	test_anonymous_override_match_restores_unchanged,
	test_override_mismatch_purge_failure_fails_closed,
	test_set_consent_surfaces_receipt_persist_failure,
	test_transient_outbox_save_failure_never_evicts,
	test_identifier_byte_clamp_boundary,
	test_oversized_identifier_cannot_wedge_consent_teardown,
	test_no_receipt_chaining_after_shutdown,
	test_schema_revision_header_on_batch_only,
	test_schema_revision_override_and_disable,
	test_schema_revision_mismatch_409_is_terminal,
	test_supports_capability_discovery,
	-- Declared inline rather than as `local function`: Lua 5.4 caps a chunk at
	-- 200 locals and this file is at the ceiling, so a new top-level local per
	-- test breaks the 5.4 job while 5.1/LuaJIT still pass.
	function()
	-- The getter is wired into crash config, so its contract matters: a crash
	-- emitted between session_end and the next session_start must not be
	-- attributed to the session that already closed. session_end clears
	-- session_active but deliberately RETAINS session_id, so the getter has to
	-- gate on the flag rather than return the raw field.
	reset()
	seed_granted_consent()
	local client = assert(sdk.new(config()))

	assert_equal(client:get_session_id(), nil, "no session has been opened yet")

	assert_true(client:session_start())
	local open_id = client:get_session_id()
	assert_true(type(open_id) == "string" and #open_id > 0, "an open session must expose its id")
	assert_equal(open_id, client.session_id)

	assert_true(client:session_end("complete"))
	assert_equal(client:get_session_id(), nil, "a CLOSED session must not be reported as current")

	assert_true(client:session_start())
	assert_true(type(client:get_session_id()) == "string", "a renewed session exposes its id again")
	end,
	function()
	-- The module-level getter is a VALUE read, so "no client" must read as nil,
	-- not as the false/"not_initialized" pair a command returns. A caller using
	-- the documented `if id ~= nil then ... end` would otherwise treat false as a
	-- present id and pass a boolean downstream.
	reset()
	sdk.shutdown()
	assert_equal(sdk.get_session_id(), nil, "no default client must read as nil")

	seed_granted_consent()
	assert_true(sdk.init(config()))
	assert_equal(sdk.get_session_id(), nil, "initialized but no session open is still nil")
	assert_true(sdk.session_start())
	assert_true(type(sdk.get_session_id()) == "string", "an open session exposes its id")
	sdk.shutdown()
	assert_equal(sdk.get_session_id(), nil, "after shutdown it is nil again")
	end,
	-- Declared inline: Lua caps a chunk at 200 locals and this file is at it.
	--
	-- THE OUTBOX'S STATE IS RESOLVED ONCE, AND THE READ BEHIND IT HAS FOUR
	-- ANSWERS. "The store did not reply" and "the store replied with something
	-- unusable" used to be one value; they send an operator to different places,
	-- so they are not one value.
	function()
	local function outbox_path(stores)
		for path in pairs(stores) do
			if path:sub(-15) == "/consent-outbox" then return path end
		end
	end
	local function denial(key)
		return {
			idempotency_key = key,
			workspace_id = "ws", app_id = "app", environment_id = "env",
			actor_identifier = "anon-fv",
			decided_at = "2026-07-09T00:00:00Z",
			categories = { analytics = false },
			anonymous_id = "anon-fv",
		}
	end

	-- A. THE FOUR STATES, one assertion per fact, and the two that used to share
	--    a value asserted against EACH OTHER rather than only against "clean".
	reset(); storage.reset()
	local stores, restore = install_stub_sys_storage()
	assert_true(storage.save_consent_outbox(identity_scope, { denial("held") }))
	local path = outbox_path(stores)
	storage.reset()

	-- readable
	assert_equal(select(2, storage.load_consent_outbox(identity_scope)), nil,
		"a record this build understands is not unaccounted")
	assert_equal(storage.consent_outbox_unaccounted_cause(identity_scope), nil,
		"and there is nothing to diagnose")

	-- absent
	stores[path] = nil; storage.reset()
	assert_equal(select(2, storage.load_consent_outbox(identity_scope)), nil,
		"an absent trail is honestly empty, not unaccounted")
	assert_equal(storage.consent_outbox_unaccounted_cause(identity_scope), nil)

	-- unusable: the store REPLIED, with something that is not a record
	stores[path] = "garbage"; storage.reset()
	assert_equal(select(2, storage.load_consent_outbox(identity_scope)),
		"consent_outbox_read_failed", "an unusable reply is unaccounted")
	assert_equal(storage.consent_outbox_unaccounted_cause(identity_scope), "record",
		"and it names the RECORD: the store answered, so the device is fine")

	-- silent: the store did not reply at all
	stores[path] = { receipts = { denial("held") } }
	storage.reset()
	local real_load = sys.load
	sys.load = function() error("the store does not reply") end
	assert_equal(select(2, storage.load_consent_outbox(identity_scope)),
		"consent_outbox_read_failed", "a silent store is unaccounted too")
	assert_equal(storage.consent_outbox_unaccounted_cause(identity_scope), "store",
		"but it names the STORE -- nothing was answered, so nothing accuses the file")
	sys.load = real_load
	restore(); storage.reset()

	-- B. A SESSION IS NOT A PROCESS. One transient failure must not fail closed
	--    for every later client until the ENGINE restarts -- which on a game
	--    engine means until the editor is relaunched.
	reset(); storage.reset()
	local stores2, restore2 = install_stub_sys_storage()
	assert_true(storage.save_consent_outbox(identity_scope, {}))
	storage.reset()
	local real_load2 = sys.load
	sys.load = function(p)
		if p:sub(-15) == "/consent-outbox" then error("this session cannot read it") end
		return real_load2(p)
	end
	local client_a = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(client_a.consent_outbox_unreadable, true,
		"the first session fails closed, correctly, while the read is failing")
	assert_equal(client_a:snapshot().consent_denial_possibly_undelivered, 1,
		"and the alarm fires: there may be undeleted data behind an unaccounted denial")
	sys.load = real_load2
	local client_b = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_equal(client_b.consent_outbox_unreadable, nil,
		"a NEW session re-reads: recovery must not require restarting the engine")
	assert_equal(client_b:snapshot().consent_denial_possibly_undelivered, 0,
		"and a healthy client reports ZERO, not nothing -- an alarm you cannot see is not one")
	restore2(); storage.reset()

	-- C. THE RESOLUTION HANDS OUT COPIES. Returning its own list made the
	--    caller's mirror and the resolution the same table, so the two could not
	--    disagree even where they should.
	reset(); storage.reset()
	local stores3, restore3 = install_stub_sys_storage()
	assert_true(storage.save_consent_outbox(identity_scope, { denial("a"), denial("b") }))
	storage.reset()
	local first = storage.load_consent_outbox(identity_scope)
	assert_equal(#first, 2)
	table.remove(first)
	assert_equal(#storage.load_consent_outbox(identity_scope), 2,
		"mutating what the loader handed back leaves the resolution whole")
	local returned = storage.save_consent_outbox(identity_scope, { denial("a"), denial("b"), denial("c") })
	assert_equal(#returned, 3)
	table.remove(returned)
	assert_equal(#storage.load_consent_outbox(identity_scope), 3,
		"and so does mutating what the write handed back")
	restore3(); storage.reset()
	end,
}

for _, test in ipairs(tests) do
	test()
end


-- === A6 request compression ===============================================
--
-- Wrapped in an immediately-invoked FUNCTION on purpose. Lua caps a chunk at
-- 200 locals, this file is close to it, and the limit is per FUNCTION — a
-- plain do-block does not open a new one, so it does not help. Both of those
-- were learned the compiler's way.
--
-- What these tests DO cover: the transport plumbing — when a body is
-- compressed, what header it carries, that the compressed bytes go out
-- verbatim, and what happens when the server refuses the coding.
--
-- What they CANNOT cover, stated plainly rather than implied away: whether the
-- ENGINE's zlib.deflate actually emits RFC 1950 framing. That is an engine
-- fact, this SDK only forwards the bytes, and no interpreter in CI has the
-- module. The SERVER end of the same contract IS verified — analytics-service
-- reads Go's zlib writer output and refuses a raw RFC 1951 body — so the
-- unproven link is exactly one: the engine's own framing. It needs an
-- on-device capture and is owed as an acceptance artifact.
--
-- The stub below therefore returns an OPAQUE shrunk string. Making it emit
-- real zlib would prove nothing extra: the production path does not do the
-- framing, it forwards it.
;(function()
	local function install_zlib_stub(behaviour)
		local saved = rawget(_G, "zlib")
		local calls = {}
		_G.zlib = {
			deflate = function(body)
				calls[#calls + 1] = body
				if behaviour == "raise" then
					error("zlib boom")
				elseif behaviour == "grow" then
					return body .. string.rep("x", 64)
				elseif behaviour == "empty" then
					return ""
				elseif behaviour == "wrong_type" then
					return 42
				end
				-- Default: a deterministic, opaque, SHRUNK stand-in.
				return "Z<" .. #body .. ">" .. body:sub(1, 8)
			end,
		}
		return calls, function()
			_G.zlib = saved
		end
	end

	-- Only the batch route matters here. A seeded consent grant dispatches a
	-- receipt to /v1/consent on init, so `requests` is not batches alone —
	-- indexing it directly made the first version of these assertions count
	-- the receipt as a publish.
	local function batch_requests()
		local out = {}
		for _, request in ipairs(requests) do
			if request.url:find("/v1/events:batch", 1, true) then
				out[#out + 1] = request
			end
		end
		return out
	end

	-- shutdown() publishes a final small batch of its own, so "how many
	-- publishes happened" is not the contract. The contract is: compress iff
	-- the body was worth compressing. assert_no_compression checks that no
	-- batch carried the coding at all.
	local function assert_no_compression(label)
		local batches = batch_requests()
		assert_true(#batches >= 1, label .. ": expected at least one publish")
		for i, request in ipairs(batches) do
			assert_equal(request.headers["Content-Encoding"], nil,
				label .. ": batch " .. tostring(i) .. " was compressed")
		end
		return batches
	end

	local function fill_batch(count)
		for i = 1, count do
			assert_true(sdk.track("level_complete", {
				level_id = "world-3-stage-" .. tostring(i % 12),
				duration_ms = 41200 + i,
				attempts = 1 + (i % 4),
				score = 18400 + i * 7,
				difficulty = "normal",
				input_device = "gamepad",
			}), "track " .. tostring(i))
		end
	end

	-- A full batch goes out compressed, and the wire body is EXACTLY what the
	-- compressor returned: the transport forwards, it does not re-frame.
	reset()
	local calls, restore = install_zlib_stub()
	seed_granted_consent()
	assert_true(sdk.init(config({ batch_size = 100 })))
	fill_batch(60)
	assert_true(sdk.flush())
	sdk.shutdown()
	restore()

	local batches = batch_requests()
	assert_true(#batches >= 1, "expected at least one publish")
	assert_equal(batches[1].headers["Content-Encoding"], "deflate",
		"a full batch must be sent compressed")
	assert_equal(#calls, 1, "the engine compressor must have been called for exactly the over-threshold batch")
	assert_true(#calls[1] >= 1024,
		"fixture must exceed the threshold for this test to mean anything")
	assert_true(#batches[1].body < #calls[1],
		"the compressed body must be smaller than the payload")
	assert_equal(batches[1].body, "Z<" .. #calls[1] .. ">" .. calls[1]:sub(1, 8),
		"the wire body must be the compressor's output verbatim")
	-- Every OTHER batch (shutdown's small final one) stayed uncompressed
	-- because it sat under the threshold — the rule is about the body, not
	-- about which publish it is.
	for i = 2, #batches do
		assert_equal(batches[i].headers["Content-Encoding"], nil,
			"batch " .. tostring(i) .. " was under the threshold and must not be compressed")
		assert_true(#batches[i].body < 1024, "batch " .. tostring(i) .. " must be sub-threshold")
	end

	-- Sub-threshold bodies: zlib framing costs 6 bytes before the deflate
	-- stream's own overhead, so a single-event batch comes out larger.
	reset()
	calls, restore = install_zlib_stub()
	seed_granted_consent()
	assert_true(sdk.init(config()))
	assert_true(sdk.track("session_start"))
	assert_true(sdk.flush())
	sdk.shutdown()
	restore()

	batches = assert_no_compression("sub-threshold")
	assert_equal(#calls, 0, "the compressor must not even be called under the threshold")
	assert_true(#batches[1].body < 1024,
		"fixture must sit under the threshold for this test to mean anything")

	-- The opt-out.
	reset()
	calls, restore = install_zlib_stub()
	seed_granted_consent()
	assert_true(sdk.init(config({ batch_size = 100, request_compression_enabled = false })))
	fill_batch(60)
	assert_true(sdk.flush())
	sdk.shutdown()
	restore()

	batches = assert_no_compression("opt-out")
	assert_equal(#calls, 0, "the opt-out must not call the compressor at all")
	assert_true(#batches[1].body >= 1024,
		"fixture must exceed the threshold or the opt-out is untested")

	-- No engine module: an ordinary uncompressed publish, never an error. A
	-- missing compressor is a missed optimisation, not a dropped batch. This
	-- is also the state every other test in this file runs in.
	reset()
	local saved_zlib = rawget(_G, "zlib")
	_G.zlib = nil
	seed_granted_consent()
	assert_true(sdk.init(config({ batch_size = 100 })))
	fill_batch(60)
	assert_true(sdk.flush())
	sdk.shutdown()
	_G.zlib = saved_zlib

	batches = assert_no_compression("no engine module")
	assert_true(#batches[1].body >= 1024)

	-- A compressor that raises, returns a non-string, returns nothing, or
	-- returns something no smaller than the input: all fall back to the plain
	-- body. The last is not theoretical — a high-entropy body comes back
	-- larger, and sending it would spend CPU to make the request worse.
	for _, behaviour in ipairs({ "raise", "grow", "empty", "wrong_type" }) do
		reset()
		local _, restore_stub = install_zlib_stub(behaviour)
		seed_granted_consent()
		assert_true(sdk.init(config({ batch_size = 100 })))
		fill_batch(60)
		assert_true(sdk.flush(), "flush must succeed with a " .. behaviour .. " compressor")
		sdk.shutdown()
		restore_stub()

		batches = assert_no_compression(behaviour)
		assert_true(#batches[1].body >= 1024, behaviour .. ": fixture must exceed the threshold")
	end

	-- The ordering safety net, and the reason compression can be on by
	-- default. A deployment predating the coding answers 400 with a distinct
	-- detail code. That arrives as an ORDINARY 400 — terminal by default,
	-- which would DROP the batch — so it must be kept and re-sent
	-- uncompressed, or a transport detail becomes total data loss.
	reset()
	local _, restore_refusal = install_zlib_stub()
	seed_granted_consent()
	assert_true(sdk.init(config({ batch_size = 100 })))
	fill_batch(60)

	next_status = 400
	next_response_body = '{"error":{"code":"validation_error","message":"request validation failed",'
		.. '"details":[{"field":"content-encoding","code":"unsupported_content_encoding",'
		.. '"message":"content encoding deflate is not supported"}]}}'
	-- flush() reports the publish outcome, and this one is a rejection; the
	-- assertion that matters is what happens to the BATCH, below.
	sdk.flush()
	batches = batch_requests()
	assert_equal(#batches, 1, "expected exactly the refused publish so far")
	assert_equal(batches[1].headers["Content-Encoding"], "deflate")

	next_status = 202
	next_response_body = nil
	sdk.update(0)
	batches = batch_requests()
	assert_true(#batches >= 2, "the refused batch must be retried, not dropped")
	assert_equal(batches[2].headers["Content-Encoding"], nil,
		"the retry must be uncompressed")

	-- And the same rescue must survive an EXPLICIT flush that bypassed a
	-- client-owned backoff to make the refused attempt.
	--
	-- The nudge alone does not deliver it: that backoff's deadline is still
	-- armed, so start_publish_batch refuses the automatic flush the nudge
	-- triggers, and the uncompressed retry waits out the remainder of a window
	-- approaching 60s — a transport detail becoming a minute of data loss on
	-- exactly the deployments the fallback exists to protect.
	reset()
	seed_granted_consent()
	assert_true(sdk.init(config({ batch_size = 100, flush_interval_seconds = 9999 })))
	fill_batch(60)

	next_status = 500
	next_response_body = nil
	sdk.flush()
	-- The hint-less 500 armed our own backoff. Not asserted through the
	-- client — the singleton does not expose it — but pinned by the next two
	-- steps: the explicit flush gets through it, and the tick after must too.
	next_status = 400
	next_response_body = '{"error":{"code":"validation_error","message":"request validation failed",'
		.. '"details":[{"field":"content-encoding","code":"unsupported_content_encoding",'
		.. '"message":"content encoding deflate is not supported"}]}}'
	local before_refusal = #batch_requests()
	sdk.flush()
	assert_true(#batch_requests() > before_refusal,
		"an explicit flush is not bound by our own backoff")

	next_status = 202
	next_response_body = nil
	local before_retry = #batch_requests()
	sdk.update(0)
	assert_true(#batch_requests() > before_retry,
		"the uncompressed retry must go out on the next tick, not wait out a superseded backoff")

	local before = #batches
	fill_batch(60)
	assert_true(sdk.flush())
	batches = batch_requests()
	assert_true(#batches > before, "the second batch must publish")
	for i = before + 1, #batches do
		assert_equal(batches[i].headers["Content-Encoding"], nil,
			"compression was not latched off: batch " .. tostring(i))
	end
	sdk.shutdown()
	restore_refusal()

	-- The CONTROL, and the reason the fallback matches DETAIL CODES rather
	-- than the bare 400. A status-only match would switch this client's
	-- transport off for the session in response to an unrelated defect — and
	-- would start RETAINING batches the server rejected permanently, which is
	-- its own bug: they would be re-sent and re-rejected on every later
	-- launch.
	reset()
	local _, restore_control = install_zlib_stub()
	seed_granted_consent()
	assert_true(sdk.init(config({ batch_size = 100 })))
	fill_batch(60)

	next_status = 400
	next_response_body = '{"error":{"code":"validation_error","message":"request validation failed",'
		.. '"details":[{"field":"events.0.event_name","code":"unknown_event",'
		.. '"message":"event name is not in the tracking plan"}]}}'
	sdk.flush()
	batches = batch_requests()
	assert_equal(#batches, 1, "expected exactly the rejected publish so far")

	next_status = 202
	next_response_body = nil
	fill_batch(60)
	assert_true(sdk.flush())
	batches = batch_requests()
	assert_true(#batches >= 2, "the next batch must publish")
	for i = 2, #batches do
		assert_equal(batches[i].headers["Content-Encoding"], "deflate",
			"an unrelated 400 disabled compression: batch " .. tostring(i))
	end
	sdk.shutdown()
	restore_control()

	-- The module's own predicates, including every shape that must NOT trip
	-- the refusal match.
	local compression = require "shardpilot.compression"
	assert_equal(compression.is_encoding_refusal("unsupported_content_encoding"), true)
	assert_equal(compression.is_encoding_refusal("invalid_content_encoding"), true)
	assert_equal(compression.is_encoding_refusal("unknown_field,unsupported_content_encoding"), true)
	-- WHOLE TOKENS. A substring match treats any code that merely CONTAINS a
	-- refusal code as the refusal itself, and the cost runs both ways: a
	-- terminally rejected batch is retained and retried, and compression
	-- latches off for the session. Exactness is the entire reason this
	-- discriminates on codes rather than on the bare 400.
	assert_equal(compression.is_encoding_refusal("not_invalid_content_encoding"), false)
	assert_equal(compression.is_encoding_refusal("unsupported_content_encoding_policy"), false)
	assert_equal(compression.is_encoding_refusal("a,unsupported_content_encoding,b"), true)
	assert_equal(compression.is_encoding_refusal("unknown_event"), false)
	assert_equal(compression.is_encoding_refusal("request_too_large"), false)
	assert_equal(compression.is_encoding_refusal(""), false)
	assert_equal(compression.is_encoding_refusal(nil), false)
	assert_equal(compression.is_encoding_refusal(42), false)

	saved_zlib = rawget(_G, "zlib")
	_G.zlib = nil
	assert_equal(compression.available(), false, "no module means no compressor")
	assert_equal(compression.compress(string.rep("a", 4096)), nil)
	_G.zlib = { deflate = "not a function" }
	assert_equal(compression.available(), false, "a non-callable deflate is not a compressor")
	_G.zlib = { deflate = function(body) return "z" .. body:sub(1, 4) end }
	assert_equal(compression.available(), true)
	assert_equal(compression.compress(string.rep("a", 1023)), nil, "under the threshold")
	assert_true(compression.compress(string.rep("a", 1024)) ~= nil, "at the threshold")
	assert_equal(compression.compress(nil), nil)
	assert_equal(compression.compress(42), nil)
	_G.zlib = saved_zlib

	-- A non-boolean flag fails config validation rather than being coerced.
	local bad_client, bad_err = sdk.new(config({ request_compression_enabled = "yes" }))
	assert_equal(bad_client, nil)
	assert_equal(bad_err, "invalid_request_compression_enabled")
end)()

-- === Codex round: retry ownership and wake sources ========================
--
-- Same immediately-invoked-function trick as the block above: the main chunk
-- is at Lua's 200-local ceiling, and the limit is per FUNCTION (a `do` block
-- does not open one).
;(function()
	-- A SHORT server hint arriving inside a LONGER client window.
	--
	-- Ownership used to be recorded only when the server's deadline was the
	-- one that won, so a Retry-After: 1 landing inside a 2s client backoff
	-- left the window marked client-owned — and the next explicit flush()
	-- bypassed a server instruction outright. The two deadlines are held
	-- apart now, so the shorter server hint keeps its own expiry.
	reset()
	storage.reset()
	seed_granted_consent()

	next_status = 500
	local client = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(client:identify("user-example"))
	assert_true(client:track("overlap_event"))
	assert_equal(client:flush(), false)
	assert_true(client:publish_deferred(), "our own backoff armed a window")
	assert_equal(client:publish_server_deferred(), false, "nothing server-owned yet")
	-- Pin the client window at a minute so the arithmetic below is about the
	-- two deadlines rather than about backoff jitter, which is uniform over
	-- the ceiling and could land either side of the server's second.
	client.publish_retry_after_ms = math.floor(socket.now * 1000) + 60000
	local client_deadline = client.publish_retry_after_ms

	-- Now an explicit flush inside that window (allowed: our own backoff does
	-- not bind a caller) comes back with a much SHORTER server hint.
	next_status = 429
	next_response_headers = { ["retry-after"] = "1" }
	assert_equal(client:flush(), false)
	next_response_headers = nil
	assert_true(client:publish_server_deferred(),
		"a server hint inside a client window is still the server asking")
	assert_equal(client.publish_retry_after_ms, client_deadline,
		"the longer window still paces the automatic retries")

	-- The instruction binds the caller for as long as the SERVER asked, and
	-- no longer: our own backoff outlives it and still does not bind. This is
	-- the pair of assertions a single deadline plus a flag cannot satisfy at
	-- once — marking the whole minute server-owned would fail the second.
	next_status = 202
	assert_equal(client:flush(), false, "an explicit flush waits out the server's second")
	socket.now = socket.now + 2
	assert_equal(client:publish_server_deferred(), false, "the server's second is up")
	assert_true(client:publish_deferred(), "our own window has not expired")
	assert_true(client:flush(), "past the server's hint, the caller is free again")

	-- A bypassed client window whose batch is then DROPPED must not keep
	-- blocking the automatic path. This became reachable only when an
	-- explicit flush gained the right to bypass our own backoff: that attempt
	-- can now run inside a live window and come back terminal.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local dropper = assert(sdk.new(config({ flush_interval_seconds = 9999 })))
	assert_true(dropper:identify("user-example"))
	assert_true(dropper:track("doomed_event"))
	assert_equal(dropper:flush(), false)
	assert_true(dropper:publish_deferred(), "the client armed its own window")

	next_status = 400
	assert_equal(dropper:flush(), false, "the bypassing flush gets a terminal answer")
	assert_equal(dropper.in_flight_batch, nil, "a terminal 400 drops the batch")
	assert_equal(dropper:publish_deferred(), false,
		"the deadline belonged to discarded work and must not block the next batch")

	next_status = 202
	assert_true(dropper:track("next_event"))
	assert_true(dropper:flush(), "the next batch publishes immediately")

	-- A retained Mode B 401 has NO wake source of its own: it arms no
	-- deadline (a freshly minted token is tried at once), and the batch has
	-- already left the queue so the batch-size trigger cannot fire for it.
	-- Under the 15s default that was a fifteen-second stall on a token
	-- refresh that completed immediately. flush_interval_seconds is 9999
	-- here, so ONLY the nudge can produce the second request.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 401
	local minted = 0
	local reauth = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		token_provider = function(callback)
			minted = minted + 1
			callback("token-" .. minted, nil, nil)
		end,
	})))
	assert_true(reauth:identify("user-example"))
	assert_true(reauth:track("stale_token_event"))
	assert_equal(reauth:flush(), false)
	assert_equal(#requests, 1)
	assert_true(reauth.in_flight_batch ~= nil, "a Mode B 401 retains the batch")
	assert_equal(reauth:publish_deferred(), false, "a 401 arms no window: the retry is immediate")

	next_status = 202
	reauth:update(0)
	assert_equal(#requests, 2, "the retained 401 batch goes out on the next tick, not the flush tick")
	assert_true(minted >= 2, "the retry mints a fresh token")

	-- ...and exactly ONE immediate retry per batch, not a standing due state:
	-- a server answering 401 forever must not mint a token every frame. The
	-- second 401 for the same batch means the fresh token did not help, so it
	-- paces like any other retryable failure.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 401
	local looping = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		token_provider = function(callback) callback("token-loop", nil, nil) end,
	})))
	assert_true(looping:identify("user-example"))
	assert_true(looping:track("always_401"))
	assert_equal(looping:flush(), false)
	local after_flush = #requests
	looping:update(0)
	local after_nudge = #requests
	assert_equal(after_nudge, after_flush + 1, "the nudge is worth one attempt")
	assert_true(looping:publish_deferred(), "the second 401 falls back to the backoff schedule")
	looping:update(0)
	looping:update(0)
	looping:update(0)
	assert_equal(#requests, after_nudge, "and only one: the armed window holds the rest")

	-- ...and the same batch under an ASYNCHRONOUS token_provider, which is the
	-- shape the synchronous test above cannot reach.
	--
	-- The nudge is consumed by the update() that STARTS the mint: that tick
	-- zeroes the elapsed counter, can_publish returns false while the mint is
	-- in flight, and nothing publishes. So the retry has to be re-armed when
	-- the mint settles, or the batch waits out the whole interval after the
	-- token finally arrives.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 401
	local deferred_callback = nil
	local async = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		token_provider = function(callback)
			deferred_callback = callback
		end,
	})))
	assert_true(async:identify("user-example"))
	assert_true(async:track("async_stale_token_event"))

	-- The mint runs at the DISPATCH point, so the first flush only starts it.
	assert_equal(async:flush(), false)
	assert_equal(#requests, 0, "nothing goes out until a token exists")
	assert_true(deferred_callback ~= nil, "the provider was asked for a token")
	deferred_callback("token-async-1", nil, nil)
	deferred_callback = nil

	-- Now the publish happens, and answers 401.
	assert_equal(async:flush(), false)
	assert_equal(#requests, 1)
	assert_true(async.in_flight_batch ~= nil, "a Mode B 401 retains the batch")

	-- The tick that starts the re-mint publishes nothing and spends the nudge.
	next_status = 202
	async:update(0)
	assert_equal(#requests, 1, "the mint is in flight: nothing published, and the nudge is spent")
	assert_true(deferred_callback ~= nil, "the retry asked for a fresh token")

	-- The token arrives out of band. THIS is what has to re-arm the wake.
	deferred_callback("token-async-2", nil, nil)
	async:update(0)
	assert_equal(#requests, 2,
		"the retained batch goes out on the tick after the async mint settled, not the flush tick")

	-- A spool restored at startup whose persisted SERVER deadline is still
	-- live, and then expires. Only a Retry-After is persisted, so this is the
	-- shape where the reload really does restore a deadline — and the wake
	-- still had nothing to notice it with, because in_flight_batch stays nil
	-- until a publish actually selects a chunk.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 429
	next_response_headers = { ["retry-after"] = "30" }
	local hinted = assert(sdk.new(config({ flush_interval_seconds = 9999, spool_enabled = true })))
	assert_true(hinted:identify("user-example"))
	assert_true(hinted:track("hinted_spool_event"))
	assert_equal(hinted:flush(), false, "the 429 spools the batch with its deadline")
	next_response_headers = nil
	hinted:shutdown()

	reset()
	next_status = 202
	local resumed = assert(sdk.new(config({ flush_interval_seconds = 9999, spool_enabled = true })))
	assert_true(resumed:spool_pending(), "the relaunch reloaded the spooled chunk")
	assert_true(resumed:publish_deferred(), "and the server's window with it")
	assert_equal(resumed.in_flight_batch, nil, "nothing is selected until a publish runs")
	resumed:update(0)
	assert_equal(#requests, 0, "the live server window holds the resend")
	socket.now = socket.now + 31
	assert_equal(resumed:publish_deferred(), false, "the persisted window is up")
	resumed:update(0)
	assert_true(#requests > 0,
		"the expired persisted deadline wakes the spool resend, with no chunk selected yet")
	resumed:shutdown()

	-- A spool restored at startup whose persisted deadline has expired: the
	-- chunk sits in spool_batches with in_flight_batch still nil, so keying
	-- the wake on in_flight_batch alone meant nothing noticed the expiry.
	reset()
	storage.reset()
	seed_granted_consent()
	next_status = 500
	local seeder = assert(sdk.new(config({ flush_interval_seconds = 9999, spool_enabled = true })))
	assert_true(seeder:identify("user-example"))
	assert_true(seeder:track("spooled_event"))
	assert_equal(seeder:flush(), false, "the failure spools the batch")
	seeder:shutdown()

	reset()
	next_status = 202
	local relaunched = assert(sdk.new(config({ flush_interval_seconds = 9999, spool_enabled = true })))
	assert_true(relaunched:spool_pending(), "the relaunch reloaded the spooled chunk")
	assert_equal(relaunched.in_flight_batch, nil, "nothing is selected until a publish runs")
	socket.now = socket.now + 3600
	relaunched:update(0)
	assert_true(#requests > 0,
		"an expired persisted deadline wakes the spool resend without a flush tick")
	relaunched:shutdown()
	storage.reset()
end)()

-- === Codex round: wakes that fire on work nothing can dispatch =============
--
-- Every case here is the same defect: a wake stays due while the thing it
-- would wake CANNOT go out, so update() calls flush() on every frame and each
-- one re-pumps the consent outbox and the deferred-storage work. Request count
-- is blind to all of it — flush() runs, the dispatch is refused, and no extra
-- request appears — so the witness throughout is flush_elapsed_seconds, which
-- flush() zeroes: three ticks of 0.1 leave it at 0.3 with the gate and at
-- exactly 0 without.
--
-- Same immediately-invoked-function trick as the blocks above: the main chunk
-- is at Lua's 200-local ceiling, and the limit is per FUNCTION.
;(function()
	-- ── A publish retry behind a DEFERRED GRANT ────────────────────────────
	--
	-- An undispatched grant receipt holds the event leg by design (ordering,
	-- not pacing), and flush() returns at that gate before it ever reaches the
	-- publish loop. So a retained batch whose own deadline has expired keeps
	-- the wake due with nothing able to answer it — for the length of a
	-- CONSENT window, where a server Retry-After runs to 24 hours.
	--
	-- Built through a relaunch because that is the shape that actually
	-- reaches it: the gate blocks publishing while a grant is undispatched, so
	-- within one launch a batch can never become retained BEHIND one. A spool
	-- restored from a previous launch is retained publish work that arrives
	-- already past the gate.
	reset()
	storage.reset()
	seed_granted_consent()

	next_status = 503
	next_response_headers = { ["retry-after"] = "3" }
	local seeder = assert(sdk.new(config_mode_a({
		flush_interval_seconds = 9999, spool_enabled = true,
	})))
	assert_true(seeder:track("gated_event"))
	assert_equal(seeder:flush(), false, "the failure spools the batch with the server's window")
	next_response_headers = nil
	seeder:shutdown()

	-- A grant receipt is durably retained from that same launch.
	assert_true(storage.save_consent_outbox(identity_scope, { {
		idempotency_key = "gate-grant-key",
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "anon-gate-example",
		kind = "anon",
		decided_at = "2026-07-02T00:00:00.000Z",
		categories = { analytics = true },
		anonymous_id = "anon-gate-example",
	} }) ~= false)

	-- The relaunch dispatches the retained grant during init, so the server
	-- has to be failing BEFORE the client is built or the receipt is
	-- acknowledged and pruned before the test starts.
	reset()
	next_status = 503
	local gated = assert(sdk.new(config_mode_a({
		flush_interval_seconds = 9999, spool_enabled = true,
	})))
	assert_equal(#requests, 1, "the retained grant dispatches at startup and fails")
	assert_true(gated:spool_pending(), "the relaunch reloaded the spooled chunk")
	assert_true(gated:publish_deferred(), "and the persisted server window with it")

	-- Past both the persisted publish window and the grant's first backoff.
	socket.now = socket.now + 10
	assert_equal(gated:publish_deferred(), false, "the publish deadline has expired")
	assert_equal(gated:consent_send_deferred(), false, "and so has the grant's first backoff")

	-- The grant's next attempt fails too, arming the window that now holds
	-- the event leg while the publish retry sits due behind it.
	local gated_flushed, gated_reason = gated:flush()
	assert_equal(gated_flushed, false)
	assert_equal(gated_reason, "consent_receipt_pending")
	assert_equal(#requests, 2, "the grant went out again; the batch is held behind it")
	assert_true(gated:consent_send_deferred(), "the failed grant armed the consent window")
	assert_true(gated:grant_receipt_pending_dispatch(), "and the receipt is still undispatched")

	-- Pin the consent window at a minute. The fake clock advances 0.1s on
	-- every read, so a jittered second-scale backoff can expire part-way
	-- through the ticks below and re-dispatch the grant — which would make
	-- this a test of the harness rather than of the gate.
	gated.consent_retry_after_ms = math.floor(socket.now * 1000) + 60000

	local gated_before = #requests
	gated:update(0.1)
	gated:update(0.1)
	gated:update(0.1)
	assert_equal(#requests, gated_before, "nothing can go out while the grant holds the leg")
	assert_true(gated.flush_elapsed_seconds > 0.29,
		"the publish wake must stay quiet behind a deferred grant, or flush() runs every frame for the length of a consent window")
	gated:shutdown()
	storage.reset()

	-- ── ...and behind an IN-FLIGHT consent head ────────────────────────────
	--
	-- The case above only covers a grant held by its own WINDOW. Delivery is
	-- serial, so an earlier receipt already on the wire holds the grant back
	-- just as firmly — and with it every event leg — for a whole request round
	-- trip, with no window armed anywhere. Both wakes have to test whether the
	-- outbox can dispatch AT ALL, which is the condition
	-- try_send_consent_outbox() itself refuses on.
	reset()
	storage.reset()
	seed_granted_consent()

	next_status = 503
	next_response_headers = { ["retry-after"] = "3" }
	local head_seeder = assert(sdk.new(config_mode_a({
		flush_interval_seconds = 9999, spool_enabled = true,
	})))
	assert_true(head_seeder:track("head_gated_event"))
	assert_equal(head_seeder:flush(), false, "the failure spools the batch with the server's window")
	next_response_headers = nil
	head_seeder:shutdown()

	-- Two receipts: the head dispatches and stays on the wire, the GRANT
	-- behind it cannot be handed over and goes on holding the event leg.
	-- Both keyed to historic anons, so the retained-denial convergence at load
	-- (which requires the receipt's anon to be the current one) stays out of
	-- this.
	assert_true(storage.save_consent_outbox(identity_scope, {
		{
			idempotency_key = "head-denial-key",
			workspace_id = "workspace-example",
			app_id = "app-example",
			environment_id = "develop",
			actor_identifier = "anon-head-denial",
			kind = "anon",
			decided_at = "2026-07-01T00:00:00.000Z",
			categories = { analytics = false },
			anonymous_id = "anon-head-denial",
		},
		{
			idempotency_key = "queued-grant-key",
			workspace_id = "workspace-example",
			app_id = "app-example",
			environment_id = "develop",
			actor_identifier = "anon-head-grant",
			kind = "anon",
			decided_at = "2026-07-02T00:00:00.000Z",
			categories = { analytics = true },
			anonymous_id = "anon-head-grant",
		},
	}) ~= false)

	reset()
	local head_held, head_restore = hold_http_requests()
	local headed = assert(sdk.new(config_mode_a({
		flush_interval_seconds = 9999, spool_enabled = true,
	})))
	assert_equal(#head_held, 1, "the head receipt is on the wire with its callback held")
	assert_true(headed.consent_send_in_flight, "so the outbox can hand nothing else over")
	assert_equal(headed:consent_send_deferred(), false, "and no window is armed anywhere")
	assert_true(headed:grant_receipt_pending_dispatch(),
		"while the grant queued behind it still holds the event leg")
	assert_true(headed:spool_pending(), "and the relaunch reloaded the spooled chunk")
	socket.now = socket.now + 10
	assert_equal(headed:publish_deferred(), false, "the persisted publish window has expired")

	local headed_before = #requests
	headed:update(0.1)
	headed:update(0.1)
	headed:update(0.1)
	assert_equal(#requests, headed_before, "nothing can go out behind the in-flight head")
	assert_true(headed.flush_elapsed_seconds > 0.29,
		"the publish wake must stay quiet while an IN-FLIGHT receipt holds the grant, not only while the grant is deferred")
	head_restore()
	storage.reset()

	-- The full-queue trigger has the identical hole — it is the trigger that
	-- was fixed for the DEFERRED grant one round earlier, tested separately
	-- here so a mutation of either clause has its own witness.
	reset()
	storage.reset()
	seed_granted_consent()
	assert_true(storage.save_consent_outbox(identity_scope, {
		{
			idempotency_key = "head-grant-key",
			workspace_id = "workspace-example",
			app_id = "app-example",
			environment_id = "develop",
			actor_identifier = "anon-first-grant",
			kind = "anon",
			decided_at = "2026-07-01T00:00:00.000Z",
			categories = { analytics = true },
			anonymous_id = "anon-first-grant",
		},
		{
			idempotency_key = "second-grant-key",
			workspace_id = "workspace-example",
			app_id = "app-example",
			environment_id = "develop",
			actor_identifier = "anon-second-grant",
			kind = "anon",
			decided_at = "2026-07-02T00:00:00.000Z",
			categories = { analytics = true },
			anonymous_id = "anon-second-grant",
		},
	}) ~= false)

	local queue_held, queue_restore = hold_http_requests()
	local queued = assert(sdk.new(config_mode_a({
		flush_interval_seconds = 9999, batch_size = 2,
	})))
	assert_equal(#queue_held, 1, "the head grant is on the wire with its callback held")
	assert_true(queued:grant_receipt_pending_dispatch(),
		"the second grant is released by key identity only for the one in flight")
	assert_true(queued:track("queued_one"))
	assert_true(queued:track("queued_two"))

	local queued_before = #requests
	queued:update(0.1)
	queued:update(0.1)
	queued:update(0.1)
	assert_equal(#requests, queued_before, "a full queue still cannot drain past the grant")
	assert_true(queued.flush_elapsed_seconds > 0.29,
		"the full-queue trigger must be suppressed behind an in-flight consent head too")
	queue_restore()
	storage.reset()

	-- ── A retry wake while the MINT it needs is in flight ──────────────────
	--
	-- An expired backoff that starts an asynchronous token_provider puts no
	-- HTTP request on the wire, so publish_in_flight cannot see it: the
	-- deadline stays expired and the wake stays due for the whole latency of
	-- the provider.
	reset()
	storage.reset()
	seed_granted_consent()
	local pending_mint = nil
	local minting = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		token_provider = function(callback) pending_mint = callback end,
	})))
	assert_true(minting:identify("user-example"))
	assert_true(minting:track("mint_spin_event"))
	assert_equal(minting:flush(), false, "the first flush only starts the mint")
	assert_true(pending_mint ~= nil, "the provider was asked for a token")
	pending_mint("token-spin-1", math.floor(socket.now * 1000) + 1000, nil)
	pending_mint = nil

	next_status = 500
	assert_equal(minting:flush(), false)
	assert_equal(#requests, 1, "the batch went out and failed")
	assert_true(minting.in_flight_batch ~= nil, "and is retained")

	-- Past both our own backoff and the token's expiry, so the retry that is
	-- now due has to mint before it can publish.
	socket.now = socket.now + 120
	assert_equal(minting:publish_deferred(), false, "the backoff window is up")

	next_status = 202
	minting:update(0)
	assert_equal(#requests, 1, "the mint is in flight, so nothing published")
	assert_true(minting.token_request_in_flight, "and it has not settled")
	minting:update(0.1)
	minting:update(0.1)
	minting:update(0.1)
	assert_equal(#requests, 1, "still nothing: there is no token to publish with")
	assert_true(minting.flush_elapsed_seconds > 0.29,
		"the retry wake must stay quiet while the mint it is waiting on is in flight")

	-- Nothing is stranded by that silence: the settlement is the wake.
	pending_mint("token-spin-2", nil, nil)
	minting:update(0)
	assert_equal(#requests, 2, "the settled mint wakes the retained batch")
	minting:shutdown()
	storage.reset()

	-- ── A mint started for an ordinary QUEUE, not for retained work ────────
	--
	-- Every mint case above starts from work that has already left the queue.
	-- The commonest shape has not: a cadence or explicit flush over a partial
	-- queue calls can_publish() BEFORE draining, so the mint settles with
	-- in_flight_batch nil and spool_batches empty. The retained predicate sees
	-- nothing to wake, the flush that started the mint already zeroed the
	-- cadence, and a below-batch_size queue cannot trigger another — so the
	-- event that caused the mint waits out the whole interval.
	reset()
	storage.reset()
	seed_granted_consent()
	local queue_mint = nil
	local queue_mint_calls = 0
	local queue_minting = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		batch_size = 20,
		token_provider = function(callback)
			queue_mint_calls = queue_mint_calls + 1
			queue_mint = callback
		end,
	})))
	assert_true(queue_minting:identify("user-example"))
	assert_true(queue_minting:track("partial_queue_event"))
	assert_equal(queue_minting:flush(), false, "the flush starts the mint and drains nothing")
	assert_equal(queue_mint_calls, 1, "the provider was asked for a token")
	assert_equal(queue_minting.in_flight_batch, nil, "the queue is not drained until a token exists")
	assert_equal(#queue_minting.spool_batches, 0, "and nothing is spooled")
	assert_equal(queue_minting.flush_elapsed_seconds, 0, "while that flush zeroed the cadence")

	next_status = 202
	queue_mint("token-queue-1", nil, nil)
	queue_minting:update(0)
	assert_equal(#requests, 1,
		"a settled mint must wake the QUEUED event that started it, not only retained work")
	queue_minting:shutdown()
	storage.reset()

	-- The failure half of the same blind spot: no deadline was armed either,
	-- so a provider that recovers a moment later is not asked again until the
	-- cadence comes round.
	reset()
	storage.reset()
	seed_granted_consent()
	local failed_mint = nil
	local failed_mint_calls = 0
	local failing = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		batch_size = 20,
		token_provider = function(callback)
			failed_mint_calls = failed_mint_calls + 1
			failed_mint = callback
		end,
	})))
	assert_true(failing:identify("user-example"))
	assert_true(failing:track("failed_mint_queue_event"))
	assert_equal(failing:flush(), false, "the flush starts the mint")
	assert_equal(failed_mint_calls, 1)
	assert_equal(failing:publish_deferred(), false, "no window yet")

	failed_mint(nil, nil, "provider exploded")
	assert_true(failing:publish_deferred(),
		"a failed mint over a queued event must arm the publish clock, or nothing paces the retry")

	-- And the armed window must be one something actually watches: a deadline
	-- no predicate reads is the same stall wearing a deadline.
	socket.now = socket.now + 5
	assert_equal(failing:publish_deferred(), false, "the window is up")
	failing:update(0)
	assert_equal(failed_mint_calls, 2,
		"the expired window must drive the retry, or the queued event waits out the interval anyway")
	failing:shutdown()
	storage.reset()

	-- The full-queue trigger is blind to a QUEUE-ONLY deadline unless it asks
	-- about pending work rather than a retained batch — and the queue-only
	-- deadline is exactly what the failed-mint arm above now creates. Worse
	-- than a spin: each flush calls the HOST's token_provider again before
	-- start_publish_batch can enforce the window, so the 1–60s pacing that
	-- exists to protect a failing provider is walked straight around.
	reset()
	storage.reset()
	seed_granted_consent()
	local hammer_mint = nil
	local hammer_calls = 0
	local hammering = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		batch_size = 2,
		token_provider = function(callback)
			hammer_calls = hammer_calls + 1
			hammer_mint = callback
		end,
	})))
	assert_true(hammering:identify("user-example"))
	assert_true(hammering:track("hammer_one"))
	assert_true(hammering:track("hammer_two"))
	assert_equal(hammering:flush(), false, "the flush starts the mint over a FULL queue")
	assert_equal(hammer_calls, 1)
	assert_equal(hammering.in_flight_batch, nil, "nothing retained: the drain never happened")

	hammer_mint(nil, nil, "provider exploded")
	assert_true(hammering:publish_deferred(), "the failed mint armed the queue-only window")
	assert_true(hammering:has_pending_publish_work(), "and the queue that armed it is still pending")

	hammering:update(0.1)
	hammering:update(0.1)
	hammering:update(0.1)
	assert_equal(hammer_calls, 1,
		"the full-queue trigger must respect a queue-only window, or a failing provider is called once per frame")
	assert_true(hammering.flush_elapsed_seconds > 0.29, "and flush() is not run every frame either")
	hammering:shutdown()
	storage.reset()

	-- ── The CADENCE arm mints inside a live window ─────────────────────────
	--
	-- The suppression above guards the full-queue arm only. A backoff longer
	-- than the flush interval — a 60s ladder, or a server Retry-After — is
	-- crossed by cadence ticks, and each one calls can_publish() before
	-- start_publish_batch can enforce the deadline. The dispatch is duly
	-- refused; the HOST's token_provider has already been called.
	reset()
	storage.reset()
	seed_granted_consent()
	local cadence_mint = nil
	local cadence_calls = 0
	local cadence = assert(sdk.new(config({
		flush_interval_seconds = 1,
		batch_size = 20,
		token_provider = function(callback)
			cadence_calls = cadence_calls + 1
			cadence_mint = callback
		end,
	})))
	assert_true(cadence:identify("user-example"))
	assert_true(cadence:track("cadence_event"))
	assert_equal(cadence:flush(), false, "the first flush starts the mint")
	cadence_mint("token-cadence", math.floor(socket.now * 1000) + 3600000, nil)
	cadence_mint = nil

	next_status = 500
	assert_equal(cadence:flush(), false)
	assert_equal(#requests, 1, "the batch went out and failed")
	assert_true(cadence.in_flight_batch ~= nil, "and is retained")

	-- Past the token's life, then pin OUR window well beyond the cadence.
	socket.now = socket.now + 7200
	cadence.publish_retry_after_ms = math.floor(socket.now * 1000) + 60000
	assert_true(cadence:publish_deferred(), "a window far longer than the interval")
	assert_equal(cadence:publish_server_deferred(), false, "and it is ours")

	local calls_before_cadence = cadence_calls
	for _ = 1, 3 do
		cadence:update(2)
		-- A real provider settles between ticks; without this the in-flight
		-- flag alone would hide the repetition.
		if cadence_mint ~= nil then
			cadence_mint("token-cadence-again", math.floor(socket.now * 1000) + 3600000, nil)
			cadence_mint = nil
		end
	end
	assert_equal(cadence_calls, calls_before_cadence,
		"cadence ticks inside a live publish window must not mint: the deadline has to be enforced before the token, not after")
	assert_true(cadence:publish_deferred(), "the window is still live throughout")
	cadence:shutdown()
	storage.reset()

	-- ── A token that is stale the moment it arrives ────────────────────────
	--
	-- A numerically valid expires_at already inside token_refresh_lead_ms
	-- passes the type check, installs, and is then declared stale by the very
	-- next can_publish(). Arming the settlement wake for it makes the next
	-- update() mint again, settle, wake, mint — the HOST's provider called
	-- once per frame for as long as pending work exists.
	--
	-- The token is still installed and still used: refresh_token() returns
	-- true whenever one is present, so the publish rides the old credential
	-- while the refresh runs. Only the wake is withheld.
	reset()
	storage.reset()
	seed_granted_consent()
	local stale_mint = nil
	local stale_calls = 0
	local stale = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		batch_size = 20,
		token_provider = function(callback)
			stale_calls = stale_calls + 1
			stale_mint = callback
		end,
	})))
	assert_true(stale:identify("user-example"))
	assert_true(stale:track("stale_token_event"))
	assert_equal(stale:flush(), false, "the flush starts the mint")
	assert_equal(stale_calls, 1)

	-- Inside the 60s default lead, so stale on arrival — and still valid
	-- enough that the type guard has nothing to say about it.
	local born_stale_expiry = math.floor(socket.now * 1000) + 1000
	assert_true(stale:expiry_already_stale(born_stale_expiry), "the premise: stale on arrival")
	stale_mint("token-born-stale", born_stale_expiry, nil)
	assert_equal(stale.token, "token-born-stale", "it is still installed and still usable")

	stale:update(0.1)
	stale:update(0.1)
	stale:update(0.1)
	assert_equal(stale_calls, 1,
		"a token that is stale on arrival must not arm the wake, or the host provider is minted once per frame")

	-- The contract that keeps this from being an over-fix: a token with a
	-- healthy expiry still arms the wake.
	reset()
	storage.reset()
	seed_granted_consent()
	local fresh_mint = nil
	local fresh = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		batch_size = 20,
		token_provider = function(callback) fresh_mint = callback end,
	})))
	assert_true(fresh:identify("user-example"))
	assert_true(fresh:track("fresh_token_event"))
	assert_equal(fresh:flush(), false)
	local healthy_expiry = math.floor(socket.now * 1000) + 3600000
	assert_equal(fresh:expiry_already_stale(healthy_expiry), false, "an hour is well outside the lead")
	next_status = 202
	fresh_mint("token-fresh", healthy_expiry, nil)
	fresh:update(0)
	assert_equal(#requests, 1, "a usable token still wakes the queued event that started the mint")
	fresh:shutdown()
	storage.reset()

	-- ── ...but only for the receipts that are actually waiting on it ───────
	--
	-- The consent plane needs the qualification the events plane does not: a
	-- mint in flight means there is no usable token AT ALL, and every publish
	-- needs one — but a historic-anon receipt rides the publishable key and
	-- is not waiting on any mint, so suppressing its wake would strand it for
	-- the flush cadence. Asserted at the predicate rather than driven end to
	-- end: this is a statement about WHICH receipt blocks, and the dual
	-- credential configuration is the only place the two answers differ.
	reset()
	storage.reset()
	local dual = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		remote_config_url = "http://localhost:9090",
		api_key = "sp_ingest_publishable_key",
		token_provider = function(callback) callback("token-dual", nil, nil) end,
	})))
	local function receipt(key, actor)
		return {
			idempotency_key = key,
			workspace_id = "workspace-example",
			app_id = "app-example",
			environment_id = "develop",
			actor_identifier = actor,
			kind = "anon",
			decided_at = "2026-07-02T00:00:00.000Z",
			categories = { analytics = true },
			anonymous_id = actor,
		}
	end
	local historic = receipt("historic-anon-key", "anon-from-a-previous-launch")
	local current = receipt("current-anon-key", dual.anonymous_id)
	assert_equal(dual:receipt_dispatch_needs_token(historic), false,
		"a historic-anon receipt rides the publishable key and waits on no mint")
	assert_true(dual:receipt_dispatch_needs_token(current),
		"a receipt keyed to THIS session's anon rides the minted token")

	dual.consent_retry_after_ms = math.floor(socket.now * 1000) - 1000
	dual.token_request_in_flight = true
	dual.consent_outbox = { historic }
	assert_true(dual:consent_retry_due(),
		"a mint in flight must not silence a receipt the publishable key can carry")
	dual.consent_outbox = { current }
	assert_equal(dual:consent_retry_due(), false,
		"but the receipt that IS waiting on that mint has nothing to wake for")
	dual.token_request_in_flight = false
	dual.consent_outbox = {}
	storage.reset()

	-- ── A failed mint must not pace a receipt that was not waiting on it ───
	--
	-- A receipt already ON THE WIRE got its credential before this mint was
	-- even started: its own outcome paces it. Arming a consent window in its
	-- name double-counts the ladder, and if that in-flight request comes back
	-- terminal its receipt is dropped without clearing the window — leaving
	-- the next receipt in the trail blocked by a backoff it never earned.
	reset()
	storage.reset()
	local vouch_mint = nil
	local vouch_calls = 0
	local vouch_held, vouch_restore = hold_http_requests()
	local vouching = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		batch_size = 20,
		token_provider = function(callback)
			vouch_calls = vouch_calls + 1
			vouch_mint = callback
		end,
	})))
	assert_true(vouching:identify("user-a"))
	assert_true(vouching:set_consent(true))
	assert_equal(vouch_calls, 1, "a user_verified receipt needs the minted token")
	vouch_mint("token-vouch", math.floor(socket.now * 1000) + 3600000, nil)
	vouch_mint = nil
	vouching:update(0)
	assert_equal(#vouch_held, 1, "the grant receipt is on the wire with its callback held")
	assert_true(vouching.consent_send_in_flight, "so the consent plane is blocked, not waiting")

	-- Event work now needs a fresh token, and that mint fails.
	assert_true(vouching:track("vouch_event"))
	socket.now = socket.now + 7200
	assert_equal(vouching:flush(), false)
	assert_equal(vouch_calls, 2, "the stale token triggered a re-mint")
	assert_true(vouch_mint ~= nil)
	vouch_mint(nil, nil, "provider exploded")

	assert_true(vouching:publish_deferred(),
		"the events plane WAS waiting on that mint, so it is paced")
	assert_equal(vouching:consent_send_deferred(), false,
		"the receipt already on the wire was not, so it must not inherit a window")
	vouch_restore()
	storage.reset()

	-- ── An explicit caller's bypass, carried across an asynchronous mint ───
	--
	-- flush() outranks our own backoff but cannot outrank a token it does not
	-- have yet: with an async provider the caller's attempt ends inside
	-- can_publish(), and what eventually publishes is the AUTOMATIC flush the
	-- settlement wake drives — refused by the very window the caller was
	-- entitled to bypass.
	reset()
	storage.reset()
	seed_granted_consent()
	local bypass_mint = nil
	local bypass = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		token_provider = function(callback) bypass_mint = callback end,
	})))
	assert_true(bypass:identify("user-example"))
	assert_true(bypass:track("bypass_event"))
	assert_equal(bypass:flush(), false, "the first flush only starts the mint")
	bypass_mint("token-bypass-1", math.floor(socket.now * 1000) + 1000, nil)
	bypass_mint = nil

	next_status = 500
	assert_equal(bypass:flush(), false)
	assert_equal(#requests, 1, "the batch went out and failed")
	assert_true(bypass.in_flight_batch ~= nil, "and is retained")

	-- Past the token's expiry, then pin OUR OWN window at a minute so the
	-- assertion below is about the bypass rather than about backoff jitter.
	socket.now = socket.now + 120
	bypass.publish_retry_after_ms = math.floor(socket.now * 1000) + 60000
	assert_true(bypass:publish_deferred(), "our own window is live")
	assert_equal(bypass:publish_server_deferred(), false, "and it is ours, not the server's")

	next_status = 202
	assert_equal(bypass:flush(), false, "the explicit attempt ends at the mint")
	assert_equal(#requests, 1, "nothing published yet")
	assert_true(bypass_mint ~= nil, "the explicit flush asked for a token")

	bypass_mint("token-bypass-2", nil, nil)
	assert_true(bypass:publish_deferred(), "the caller's window is still live when the token lands")
	bypass:update(0)
	assert_equal(#requests, 2,
		"the caller's bypass must survive the mint, or the retry they asked for waits out a 60s window")
	bypass:shutdown()
	storage.reset()

	-- ── ...and when the CONSENT preflight is what starts the mint ──────────
	--
	-- flush() dispatches the outbox before it publishes, so a token-vouched
	-- grant can start the mint and the ordering gate then returns — above and
	-- before either events-side bypass hook. The caller's explicit intent has
	-- to survive that return path too, or the continuation hands off the grant
	-- and then refuses the retained batch against the caller's own window.
	reset()
	storage.reset()
	seed_granted_consent()
	assert_true(storage.save_consent_outbox(identity_scope, { {
		idempotency_key = "preflight-grant-key",
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
		actor_identifier = "user-a",
		kind = "user_verified",
		decided_at = "2026-07-02T00:00:00.000Z",
		categories = { analytics = true },
		anonymous_id = "anon-preflight",
	} }) ~= false)

	local pre_mint = nil
	local preflight = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		batch_size = 20,
		token_provider = function(callback) pre_mint = callback end,
	})))
	assert_equal(#requests, 0, "the verified receipt is PARKED until its actor signs in")
	assert_true(preflight:track("preflight_event"))
	assert_equal(preflight:flush(), false, "the first flush starts the mint")
	pre_mint("token-preflight", math.floor(socket.now * 1000) + 3600000, nil)
	pre_mint = nil

	next_status = 500
	assert_equal(preflight:flush(), false)
	assert_equal(#requests, 1, "the batch went out and failed")
	assert_true(preflight.in_flight_batch ~= nil, "and is retained")

	-- Stale the token, then pin the caller-bypassable window at a minute.
	socket.now = socket.now + 7200
	preflight.publish_retry_after_ms = math.floor(socket.now * 1000) + 60000
	assert_equal(preflight:publish_server_deferred(), false, "the window is ours to bypass")

	-- Signing in unparks the grant and invalidates the stale token, so the
	-- receipt's own dispatch is what asks for the next one.
	assert_true(preflight:identify("user-a"))
	assert_true(preflight.token_request_in_flight, "the CONSENT dispatch started the mint")
	assert_equal(#preflight.consent_outbox, 1, "and the grant is still undispatched")

	next_status = 202
	local pre_flushed, pre_reason = preflight:flush()
	assert_equal(pre_flushed, false)
	assert_equal(pre_reason, "consent_receipt_pending",
		"the explicit attempt ends at the ordering gate, above the publish loop")
	assert_equal(#requests, 1, "nothing went out: the mint is still in flight")

	pre_mint("token-preflight-2", math.floor(socket.now * 1000) + 3600000, nil)
	assert_true(preflight:publish_deferred(), "the caller's window is still live")
	preflight:update(0)
	assert_equal(#requests, 3,
		"the grant AND the retained batch go out: an explicit bypass must survive a mint the consent preflight started")
	preflight:shutdown()
	storage.reset()

	-- ── ...and when a CHAINED handoff swallows the continuation ────────────
	--
	-- The settlement wake arms one flush. If a second dispatchable grant is
	-- still pending, that flush returns at the ordering gate, and the consent
	-- callbacks chain the remaining receipt without ever waking the events
	-- plane. The caller's window then silences the only predicates left —
	-- which is the bug: a deadline an owed bypass already overrides must not
	-- suppress the wake that would deliver it.
	reset()
	storage.reset()
	seed_granted_consent()
	local function verified_grant(key, stamp)
		return {
			idempotency_key = key,
			workspace_id = "workspace-example",
			app_id = "app-example",
			environment_id = "develop",
			actor_identifier = "user-a",
			kind = "user_verified",
			decided_at = stamp,
			categories = { analytics = true },
			anonymous_id = "anon-chained",
		}
	end
	assert_true(storage.save_consent_outbox(identity_scope, {
		verified_grant("chained-grant-one", "2026-07-02T00:00:00.000Z"),
		verified_grant("chained-grant-two", "2026-07-03T00:00:00.000Z"),
	}) ~= false)

	local chain_mint = nil
	local chained = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		batch_size = 20,
		token_provider = function(callback) chain_mint = callback end,
	})))
	assert_true(chained:track("chained_event"))
	assert_equal(chained:flush(), false, "the first flush starts the mint")
	chain_mint("token-chained", math.floor(socket.now * 1000) + 3600000, nil)
	chain_mint = nil

	next_status = 500
	assert_equal(chained:flush(), false)
	assert_true(chained.in_flight_batch ~= nil, "the batch is retained")
	socket.now = socket.now + 7200
	chained.publish_retry_after_ms = math.floor(socket.now * 1000) + 60000
	assert_equal(chained:publish_server_deferred(), false, "the window is ours to bypass")

	-- Hold every callback from here, so the first grant genuinely stays on the
	-- wire and the gate really does stop the continuation.
	local chain_held, chain_restore = hold_http_requests()
	assert_true(chained:identify("user-a"))
	assert_true(chained.token_request_in_flight, "the consent dispatch started the mint")

	local chain_flushed, chain_reason = chained:flush()
	assert_equal(chain_flushed, false)
	assert_equal(chain_reason, "consent_receipt_pending", "the explicit attempt ends at the gate")

	chain_mint("token-chained-2", math.floor(socket.now * 1000) + 3600000, nil)
	local before_chain = #requests
	chained:update(0)
	assert_equal(#requests, before_chain + 1, "the settlement flush hands off the FIRST grant only")
	assert_true(chained:grant_receipt_pending_dispatch(), "the second grant still holds the event leg")

	-- The chain delivers the rest with no help from update().
	chain_held[#chain_held](nil, nil, { status = 202, response = "{}" })
	assert_equal(#requests, before_chain + 2, "the callback chained the second grant")
	chain_held[#chain_held](nil, nil, { status = 202, response = "{}" })
	assert_equal(#chained.consent_outbox, 0, "the outbox is drained")
	assert_true(chained:publish_deferred(), "and the caller's window is still live")

	chained:update(0.1)
	assert_equal(#requests, before_chain + 3,
		"the retained batch must still go out: a window the owed bypass overrides cannot silence its own wake")
	chain_restore()
	storage.reset()

	-- ── An owed bypass dies with the mint it was owed through ──────────────
	--
	-- The bypass was recorded against the window live when the caller was
	-- turned away. A backoff armed by a FAILED mint is fresh pacing toward a
	-- provider that just broke, and the caller never overrode that — leaving
	-- the bypass set lets the next cadence flush call itself the continuation
	-- and hit the failing provider on the batching clock.
	reset()
	storage.reset()
	seed_granted_consent()
	local dead_mint = nil
	local dead_calls = 0
	local dead = assert(sdk.new(config({
		flush_interval_seconds = 1,
		batch_size = 20,
		token_provider = function(callback)
			dead_calls = dead_calls + 1
			dead_mint = callback
		end,
	})))
	-- Tracked BEFORE any identify, so the batch is anon-keyed and identify()
	-- below is not refused for stranding user-keyed work.
	assert_true(dead:track("dead_mint_event"))
	assert_equal(dead:flush(), false)
	dead_mint("token-dead", math.floor(socket.now * 1000) + 3600000, nil)
	dead_mint = nil

	next_status = 500
	assert_equal(dead:flush(), false)
	assert_true(dead.in_flight_batch ~= nil, "the batch is retained")
	socket.now = socket.now + 7200
	dead.publish_retry_after_ms = math.floor(socket.now * 1000) + 60000

	-- Signing in invalidates the stale token, so the next attempt has no
	-- credential at all and really is stopped by the mint. A token merely PAST
	-- its expiry does not stop it: refresh_token() returns true whenever one is
	-- installed, and the publish rides the old credential.
	assert_true(dead:identify("user-a"))
	assert_equal(dead.token, nil, "the stale token is gone")

	-- The caller's explicit attempt is stopped by a mint...
	assert_equal(dead:flush(), false)
	assert_true(dead.publish_bypass_owed, "the caller is owed a bypass")
	-- ...and that mint fails.
	dead_mint(nil, nil, "provider exploded")
	assert_equal(dead.publish_bypass_owed, false,
		"the bypass dies with the mint it was owed through")

	local dead_before = dead_calls
	for _ = 1, 3 do
		dead:update(2)
		if dead_mint ~= nil then
			dead_mint(nil, nil, "provider exploded again")
			dead_mint = nil
		end
	end
	assert_equal(dead_calls, dead_before,
		"a stale bypass must not let cadence ticks skip the backoff armed by the failed mint")
	dead:shutdown()
	storage.reset()

	-- ── The full-queue trigger must NOT learn about the owed bypass ────────
	--
	-- Pinning a deliberate asymmetry, because making these two symmetric is
	-- the obvious tidy-up and it is a regression. An owed bypass is set
	-- precisely WHILE a mint is in flight, so a full-queue trigger that
	-- honoured it would fire every frame until the mint settles — the spin
	-- the gate exists to stop. The retry clock can honour it safely only
	-- because it suppresses itself on token_request_in_flight.
	reset()
	storage.reset()
	seed_granted_consent()
	local asym_mint = nil
	local asym = assert(sdk.new(config({
		flush_interval_seconds = 9999,
		batch_size = 2,
		token_provider = function(callback) asym_mint = callback end,
	})))
	assert_true(asym:track("asym_first"))
	assert_equal(asym:flush(), false)
	asym_mint("token-asym", math.floor(socket.now * 1000) + 3600000, nil)
	asym_mint = nil

	next_status = 500
	assert_equal(asym:flush(), false)
	assert_true(asym.in_flight_batch ~= nil, "a retained batch holds the pipeline")
	socket.now = socket.now + 7200
	asym.publish_retry_after_ms = math.floor(socket.now * 1000) + 60000

	-- A full queue behind it, and a caller stopped by a mint.
	assert_true(asym:track("asym_queued_one"))
	assert_true(asym:track("asym_queued_two"))
	assert_true(asym:identify("user-a"))
	assert_equal(asym:flush(), false)
	assert_true(asym.publish_bypass_owed, "the caller is owed a bypass")
	assert_true(asym.token_request_in_flight, "and the mint that stopped them is still in flight")

	asym:update(0.1)
	asym:update(0.1)
	asym:update(0.1)
	assert_true(asym.flush_elapsed_seconds > 0.29,
		"the full-queue trigger must stay on the bare window: honouring the owed bypass here spins every frame until the mint settles")
	asym:shutdown()
	storage.reset()

	-- ── Retry-After: 0 through a bypassed window, and its bound ────────────
	reset()
	storage.reset()
	seed_granted_consent()
	local zero = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	assert_true(zero:track("zero_event"))
	next_status = 500
	assert_equal(zero:flush(), false)
	assert_true(zero.in_flight_batch ~= nil, "the batch is retained")
	zero.publish_retry_after_ms = math.floor(socket.now * 1000) + 60000
	assert_true(zero:publish_deferred(), "our own window is live")
	assert_equal(zero:publish_server_deferred(), false, "and it is ours")

	-- The explicit flush bypasses that window, and the server says "retry now".
	next_status = 503
	next_response_headers = { ["retry-after"] = "0" }
	assert_equal(zero:flush(), false)
	next_response_headers = nil
	assert_equal(#requests, 2, "the bypassing attempt went out")
	assert_equal(zero:publish_deferred(), false,
		"a superseded client window must not outlive the server's own 'retry now'")
	assert_equal(zero.flush_elapsed_seconds, zero.config.flush_interval_seconds,
		"and the next tick is armed to answer it")

	-- The second zero for the same batch is where "retry now" stops being
	-- free: honouring it again costs a request per frame.
	next_status = 503
	next_response_headers = { ["retry-after"] = "0" }
	zero:update(0)
	next_response_headers = nil
	assert_equal(#requests, 3, "the immediate retry really goes out")
	assert_true(zero:publish_deferred(),
		"a SECOND zero for the same batch paces on the backoff instead")
	zero:update(0.1)
	zero:update(0.1)
	assert_equal(#requests, 3, "and that window holds the rest")
	zero:shutdown()
	storage.reset()

	-- The same bound one plane over, on the consent outbox.
	reset()
	storage.reset()
	local czero = assert(sdk.new(config_mode_a({ flush_interval_seconds = 9999 })))
	next_status = 503
	next_response_headers = { ["retry-after"] = "0" }
	assert_true(czero:set_consent(true))
	assert_equal(#requests, 1, "the grant went out and was told to retry now")
	assert_equal(czero:consent_send_deferred(), false,
		"no window: the server asked for an immediate retry")
	czero:update(0)
	next_response_headers = nil
	assert_equal(#requests, 2, "and the next tick answers it")
	assert_true(czero:consent_send_deferred(),
		"a SECOND zero for the same receipt paces on the consent backoff")
	czero:shutdown()
	storage.reset()
end)()

print("shardpilot defold lua tests passed")
