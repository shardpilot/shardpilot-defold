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
		local response = { status = next_status, response = next_response_body or '{"crash_id":"x"}' }
		if next_response_headers then
			response.headers = next_response_headers
		end
		callback(nil, nil, response)
	end,
}

-- Reuse the same minimal JSON encoder the analytics harness uses so wire-shape
-- assertions can grep the encoded body.
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

-- A minimal recursive-descent JSON decoder (verbatim from the analytics test
-- harness): the real Defold runtime ships json.decode, the crash client uses it
-- only when present, so the test stub must provide it to exercise response parsing.
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

local crash = require "shardpilot.crash"
local crash_client = require "shardpilot.crash.client"
local sanitize = require "shardpilot.crash.sanitize"
local event_mod = require "shardpilot.crash.event"
local dump = require "shardpilot.crash.dump"
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

local function config(overrides)
	local out = {
		crash_ingest_url = "http://localhost:8080",
		crash_api_key = "sp_crash_write_key",
		app_id = "app-example",
		app_version = "0.1.0",
		app_build = "100",
		publish_timeout_seconds = 5,
	}
	for key, value in pairs(overrides or {}) do
		out[key] = value
	end
	return out
end

-- A minimal pre-symbolicated crash event: a function-only frame, no modules.
local function presymbolicated_event(overrides)
	local out = {
		exception = { type = "lua_error", reason = "something went wrong" },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					{ ["function"] = "game.update", file = "game/update.lua", line = 42 },
				},
			},
		},
	}
	for key, value in pairs(overrides or {}) do
		out[key] = value
	end
	return out
end

local function reset()
	requests = {}
	next_status = 202
	next_response_body = nil
	next_response_headers = nil
	-- Every emit persists write-ahead to the pending sidecar, so a test that
	-- leaves entries behind would leak resends into the next test's
	-- capture_previous. Start every test from a clean store.
	storage.reset()
end

-- ── config validation ────────────────────────────────────────────────────────

local function test_config_validation()
	local client, err = crash.new({})
	assert_equal(client, nil)
	assert_equal(err, "crash_ingest_url_required")

	local cases = {
		{ { crash_ingest_url = 42 }, "invalid_crash_ingest_url" },
		{ { crash_ingest_url = "ftp://x" }, "invalid_crash_ingest_url" },
		{ { crash_ingest_url = "http://example.com" }, "invalid_crash_ingest_url" },
		{ { crash_ingest_url = "https://ingest.example.com/path" }, "invalid_crash_ingest_url" },
		{ { crash_ingest_url = "https://ingest.example.com?x=1" }, "invalid_crash_ingest_url" },
		{ { app_id = false }, "invalid_app_id" },
		{ { sample_every = 0 }, "invalid_sample_every" },
		{ { sample_every = 1.5 }, "invalid_sample_every" },
		{ { publish_timeout_seconds = -1 }, "invalid_publish_timeout_seconds" },
		{ { crash_source = "Bad_Slug" }, "invalid_crash_source" },
		{ { crash_source = "-leadinghyphen" }, "invalid_crash_source" },
		{ { crash_source = string.rep("a", 64) }, "invalid_crash_source" },
		{ { diagnostics = 42 }, "invalid_diagnostics" },
		{ { sampler = 42 }, "invalid_sampler" },
	}
	for _, entry in ipairs(cases) do
		client, err = crash.new(config(entry[1]))
		assert_equal(client, nil, entry[2])
		assert_equal(err, entry[2], entry[2])
	end

	-- Missing the crash:write API key.
	local no_key = config()
	no_key.crash_api_key = nil
	client, err = crash.new(no_key)
	assert_equal(client, nil)
	assert_equal(err, "crash_api_key_required")

	-- Valid configs: https remote, loopback variants, and a valid slug.
	assert_true(crash.new(config({ crash_ingest_url = "https://crashes.example.com" })))
	assert_true(crash.new(config({ crash_ingest_url = "http://127.0.0.1:8080" })))
	assert_true(crash.new(config({ crash_ingest_url = "http://[::1]:8080" })))
	local valid = assert(crash.new(config({ crash_source = "game-client" })))
	assert_equal(valid.config.crash_source, "game-client")

	-- A bare-app (no source) config defaults crash_source to nil.
	local bare = assert(crash.new(config()))
	assert_equal(bare.config.crash_source, nil)
	assert_equal(bare.config.sample_every, 10)
end

-- ── source slug stamping ─────────────────────────────────────────────────────

local function test_source_stamped_on_every_report()
	reset()
	local client = assert(crash.new(config({ crash_source = "main-server", sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event()))
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"source":"main-server"')

	-- A per-event source overrides the configured default.
	reset()
	assert_true(client:emit(presymbolicated_event({ source = "per-event-slug" })))
	assert_contains(requests[1].body, '"source":"per-event-slug"')
	assert_not_contains(requests[1].body, '"source":"main-server"')
end

local function test_bare_app_omits_source()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event()))
	assert_equal(#requests, 1)
	assert_not_contains(requests[1].body, '"source"')
end

local function test_per_event_invalid_source_rejected()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A per-event source carrying an uppercase/invalid slug must be rejected by
	-- validation BEFORE it reaches the wire.
	local ok, err = client:emit(presymbolicated_event({ source = "Invalid Slug" }))
	assert_equal(ok, false)
	assert_equal(err, "invalid_source")
	assert_equal(#requests, 0)
	assert_equal(client:snapshot().dropped, 1)
end

-- A per-report source is an operator-set slug and must be a string. A non-string,
-- non-nil value (e.g. a number) is invalid input, NOT an absent source: it must not
-- silently inherit the configured default and misattribute the crash. A non-fatal
-- report is rejected; a FATAL report omits the bad source and is STILL SENT, bare.
local function test_non_string_source_rejected_nonfatal_omitted_fatal()
	reset()
	-- Configure a default source so we can prove a non-string per-report value does
	-- NOT silently fall back to it.
	local client = assert(crash.new(config({ crash_source = "main-server", sample_every = 1 })))

	-- Non-fatal: a non-string source is rejected, not defaulted.
	local ok, err = client:emit(presymbolicated_event({ source = 123 }))
	assert_equal(ok, false)
	assert_equal(err, "invalid_source")
	assert_equal(#requests, 0, "a non-fatal report with a non-string source must not reach the wire")
	assert_equal(client:snapshot().dropped, 1)

	-- Fatal: a non-string source is omitted, the crash is still sent, and it must NOT
	-- inherit the configured default (it sends bare).
	reset()
	local sent = client:emit_fatal({
		exception = { type = "SIGSEGV", reason = "boom" },
		source = 123,
		threads = {
			{ id = "main", crashed = true, frames = { { ["function"] = "game.update" } } },
		},
	})
	assert_equal(sent, true, "a fatal crash must never be dropped over a non-string source")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_not_contains(requests[1].body, '"source":"main-server"',
		"a fatal must not silently inherit the configured default over a bad source")
	assert_not_contains(requests[1].body, '"source":123')
end

-- ── wire route + shape ───────────────────────────────────────────────────────

local function test_routes_to_dedicated_crash_endpoint()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event()))
	assert_equal(#requests, 1)
	local request = requests[1]
	assert_equal(request.url, "http://localhost:8080/api/v1/crashes/ingest")
	assert_equal(request.method, "POST")
	assert_equal(request.headers["Authorization"], "Bearer sp_crash_write_key")
	assert_equal(request.headers["Content-Type"], "application/json")
	assert_equal(request.options.timeout, 5)
	-- Crash report JSON body, NOT a mobile_crash analytics event.
	assert_contains(request.body, '"crash_id":')
	assert_contains(request.body, '"occurred_at":')
	assert_contains(request.body, '"app":{')
	assert_contains(request.body, '"id":"app-example"')
	assert_contains(request.body, '"version":"0.1.0"')
	assert_contains(request.body, '"build_id":"100"')
	assert_contains(request.body, '"platform":"linux"')
	assert_contains(request.body, '"exception":{')
	assert_contains(request.body, '"type":"lua_error"')
	assert_contains(request.body, '"threads":[')
	assert_contains(request.body, '"function":"game.update"')
	-- It must NOT look like an analytics batch.
	assert_not_contains(request.body, "events:batch")
	assert_not_contains(request.body, '"event_name"')
	assert_not_contains(request.body, "mobile_crash")
end

local function test_crash_id_defaults_to_uuid_v7()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event()))
	local crash_id = requests[1].body:match('"crash_id":"([^"]+)"')
	assert_true(crash_id ~= nil, "crash_id must be present")
	assert_true(event_mod.looks_like_uuid_v7(crash_id), "default crash_id must be a UUIDv7: " .. tostring(crash_id))
end

local function test_native_frames_require_modules()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A native (address-only) frame with no module map cannot be resolved: its
	-- unresolvable address is dropped, leaving the frame with no identity, so it is
	-- dropped too. With no frame and no raw text left, there is no crash content to
	-- send and the report is honestly rejected as frames_or_raw_text_required.
	local ok, err = client:emit({
		exception = { type = "SIGSEGV" },
		threads = {
			{ id = "main", crashed = true, frames = { { instruction_addr = "0xdeadbeef" } } },
		},
	})
	assert_equal(ok, false)
	assert_equal(err, "frames_or_raw_text_required")

	-- With a module map, the same native frame is accepted.
	reset()
	assert_true(client:emit({
		exception = { type = "SIGSEGV" },
		modules = {
			{ name = "libgame.so", debug_id = "ABC123", load_address = "0x1000" },
		},
		threads = {
			{ id = "main", crashed = true, frames = { { instruction_addr = "0xdeadbeef" } } },
		},
	}))
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"instruction_addr":"0xdeadbeef"')
	assert_contains(requests[1].body, '"load_address":"0x1000"')
end

local function test_presymbolicated_modules_omitted()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event()))
	-- A pre-symbolicated crash carries no modules; the field must be absent (the
	-- encoder drops nil), never an unresolvable empty native frame.
	assert_not_contains(requests[1].body, '"modules"')
	assert_not_contains(requests[1].body, '"instruction_addr"')
end

-- ── fatal-not-sampled (the headline requirement) ─────────────────────────────

local function test_fatal_bypasses_sampler()
	reset()
	-- A 1-in-1000 sampler would almost never let a non-fatal report through, but
	-- a fatal crash must be sent EVERY time.
	local client = assert(crash.new(config({ sample_every = 1000 })))
	for _ = 1, 20 do
		assert_true(client:emit_fatal(presymbolicated_event()))
	end
	assert_equal(#requests, 20, "every fatal report must be sent regardless of sampling")
	assert_equal(client:snapshot().sampled_out, 0)
	assert_equal(client:snapshot().emitted, 20)
end

local function test_non_fatal_is_sampled()
	reset()
	-- sample_every = 5 => the deterministic default sampler keeps 1 in 5.
	local client = assert(crash.new(config({ sample_every = 5 })))
	for _ = 1, 10 do
		assert_true(client:emit(presymbolicated_event()))
	end
	assert_equal(#requests, 2, "1-in-5 sampling keeps 2 of 10 non-fatal reports")
	assert_equal(client:snapshot().sampled_out, 8)
end

local function test_custom_sampler_does_not_affect_fatal()
	reset()
	-- A sampler that drops everything must STILL never drop a fatal report.
	local client = assert(crash.new(config({
		sampler = function()
			return false
		end,
	})))
	assert_true(client:emit(presymbolicated_event()))
	assert_equal(#requests, 0, "the custom sampler dropped the non-fatal report")
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(#requests, 1, "fatal bypasses even a drop-everything sampler")
end

-- A custom sampler receives the report AFTER it is sanitized and validated. If it
-- mutates the table it is handed (e.g. attaching its own unsanitized metadata),
-- that mutation must NOT reach the wire — the sampler is given a throwaway copy,
-- so the privacy boundary holds regardless of what the sampler does.
local function test_sampler_mutation_does_not_reach_wire()
	reset()
	local client = assert(crash.new(config({
		sampler = function(report)
			-- A malicious / buggy sampler tries to smuggle raw PII onto the report.
			report.metadata = report.metadata or {}
			report.metadata.leaked_user = "player@example.com"
			report.exception = report.exception or {}
			report.exception.reason = "user_4242 secret"
			return true
		end,
	})))
	assert_true(client:emit(presymbolicated_event()))
	assert_equal(#requests, 1, "the sampler kept the report")
	local body = requests[1].body
	assert_not_contains(body, "player@example.com")
	assert_not_contains(body, "leaked_user")
	assert_not_contains(body, "user_4242")
	-- the original, sanitized reason is what shipped
	assert_contains(body, '"reason":"something went wrong"')
end

-- A fatal crash whose exception type is a package-qualified class name (dotted,
-- like "java.lang.RuntimeException") must reach the wire. The type is a structured
-- code identifier, not a secret: if the full content scrub blanks it as a
-- dotted-token credential, validation fails with exception_type_required and the
-- fatal crash is DROPPED. This guards that regression.
local function test_fatal_dotted_exception_type_reaches_wire()
	-- Dotted class names AND plain error types that happen to be shaped like a bare
	-- raw-id prefix ("user_error", "player_died", "device_lost") must all survive:
	-- exception.type is a required field with no fallback, so blanking it would drop
	-- the whole fatal crash. The bare-id rule is only for optional code-symbol fields.
	for _, exc_type in ipairs({ "java.lang.RuntimeException", "com.company.game.Crash",
		"user_error", "player_died", "device_lost" }) do
		reset()
		local client = assert(crash.new(config({ sample_every = 1 })))
		local ok = client:emit_fatal(presymbolicated_event({
			exception = { type = exc_type, reason = "boom" },
		}))
		assert_true(ok, "fatal with type " .. exc_type .. " must dispatch")
		assert_equal(#requests, 1, "the fatal crash must reach the wire, not be dropped")
		assert_equal(client:snapshot().dropped, 0,
			"a dotted exception type must NEVER drop a fatal crash")
		assert_contains(requests[1].body, '"type":"' .. exc_type .. '"')
	end

	-- But an email / raw actor id in the exception type is still removed; the type
	-- then becomes empty and the fatal report is honestly rejected at validation
	-- (the PII never reaches the wire). This is the safety counterpart.
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok, err = client:emit_fatal(presymbolicated_event({
		exception = { type = "leaked_player@example.com", reason = "boom" },
	}))
	assert_equal(ok, false, "a PII exception type with no other type must not ship the PII")
	assert_equal(err, "exception_type_required")
	assert_equal(#requests, 0)
	assert_not_contains(tostring(err), "@")
end

-- A fatal crash whose module name is a reverse-DNS / dotted package name
-- ("com.company.game") must reach the wire. The module name is a structured
-- identifier, not a secret: if the full content scrub blanks it as a dotted-token
-- credential, the module loses its required name, validation fails with
-- module_name_required, and the one-shot fatal dump is consumed WITHOUT ever being
-- sent — the native crash is lost. This load-bearing test guards that a fatal
-- with a dotted module name is NOT dropped, while a real token / digit-bearing raw
-- id / email in the same field is still removed.
local function test_fatal_dotted_module_name_reaches_wire()
	for _, module_name in ipairs({ "com.company.game", "java.lang.RuntimeException", "libgame.so" }) do
		reset()
		local client = assert(crash.new(config({ sample_every = 1 })))
		local ok = client:emit_fatal(presymbolicated_event({
			modules = {
				{ name = module_name, debug_id = "ABC123", load_address = "0x1000" },
			},
		}))
		assert_true(ok, "fatal with dotted module name " .. module_name .. " must dispatch")
		assert_equal(#requests, 1, "the fatal crash must reach the wire, not be dropped")
		assert_equal(client:snapshot().dropped, 0,
			"a dotted module name must NEVER drop a fatal crash")
		assert_contains(requests[1].body, '"name":"' .. module_name .. '"')
	end

	-- Safety counterpart: a digit-bearing raw actor id smuggled into the module name
	-- is still blanked, so the module loses its required name and becomes unusable.
	-- The stack here is pre-symbolicated (a function frame, no address), so it needs
	-- no module map: the unusable module entry is DROPPED and the fatal STILL SHIPS
	-- without it — the PII never reaches the wire, and a fatal is not lost over an
	-- optional module entry.
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal(presymbolicated_event({
		modules = {
			{ name = "handler_user_4242", debug_id = "ABC123", load_address = "0x1000" },
		},
	}))
	assert_true(ok, "a pre-symbolicated fatal must still ship after the bad module is dropped")
	assert_equal(#requests, 1, "the fatal must reach the wire with the bad module dropped")
	assert_equal(client:snapshot().dropped, 0, "a bad module entry must not drop a pre-symbolicated fatal")
	assert_not_contains(requests[1].body, "4242")
	-- the dropped module's blanked name must not ship, and the clean function frame survives
	assert_not_contains(requests[1].body, "handler_user")
	assert_contains(requests[1].body, '"function":"game.update"')
end

-- A long dotless build identifier (e.g. a 40-char SHA-1 build-id) is a STRUCTURED
-- identifier, not a free-text secret: it must survive the scrub and reach the wire.
-- The free-text long-opaque-run rule must NOT blank it (which would fail
-- module_debug_id_required and drop the fatal native crash).
local function test_fatal_long_build_id_reaches_wire()
	reset()
	local build_id = "a1b2c3d4e5f6071829304152637485960a1b2c3d" -- 40 hex chars, no dots
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal(presymbolicated_event({
		modules = {
			{ name = "libgame.so", debug_id = build_id, load_address = "0x1000" },
		},
	}))
	assert_true(ok, "fatal with a 40-char dotless build id must dispatch")
	assert_equal(#requests, 1, "the fatal crash must reach the wire, not be dropped")
	assert_equal(client:snapshot().dropped, 0,
		"a long dotless build id must NEVER drop a fatal crash")
	assert_contains(requests[1].body, build_id)
end

-- ── PII scrubbing ────────────────────────────────────────────────────────────

local function test_pii_scrubbed_from_wire()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit({
		exception = { type = "lua_error", reason = "boom" },
		context = { build_channel = "beta" },
		metadata = {
			-- a raw-identifier-prefixed key + an email value must both be dropped
			user_email = "player@example.com",
			-- a clean key/value survives
			level_name = "arena",
		},
		modules = {
			{ name = "libgame.so", debug_id = "ABC", load_address = "0x1000" },
		},
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					-- a manual frame function carrying an email is fully scrubbed;
					-- the frame stays identifiable by its native address.
					{ ["function"] = "callback for player@example.com", instruction_addr = "0xaa11" },
					{ ["function"] = "game.tick", instruction_addr = "0xbb22" },
				},
			},
		},
	}))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "player@example.com")
	assert_not_contains(body, "user_email")
	assert_contains(body, '"level_name":"arena"')
	assert_contains(body, '"build_channel":"beta"')
	-- the clean frame function survives
	assert_contains(body, '"function":"game.tick"')
end

local function test_context_session_id_pii_rejects_event()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok, err = client:emit(presymbolicated_event({
		context = { session_id = "user_12345" },
	}))
	assert_equal(ok, false)
	assert_equal(err, "context_session_id_disallowed")
	assert_equal(#requests, 0)
end

local function test_sanitizer_unit_rules()
	-- email
	assert_equal(sanitize.sanitize_string("a@b.com"), "")
	-- raw-id prefix
	assert_equal(sanitize.sanitize_string("player_42"), "")
	assert_equal(sanitize.sanitize_string("user_abc"), "")
	-- ipv4
	assert_equal(sanitize.sanitize_string("connect 10.0.0.1 failed"), "")
	-- ipv6
	assert_equal(sanitize.sanitize_string("addr fe80::1 down"), "")
	-- jwt / dotted token
	assert_equal(sanitize.sanitize_string("aaaa.bbbb.cccc"), "")
	-- a clean value survives
	assert_equal(sanitize.sanitize_string("  arena  "), "arena")
	-- a package-qualified SYMBOL survives the symbol scrub (dotted, not an email/IP)
	assert_equal(sanitize.sanitize_symbol("pkg.Type.method"), "pkg.Type.method")
	-- but the SAME dotted value under the full scrub is treated as a token and blanked
	assert_equal(sanitize.sanitize_string("pkga.bbbb.cccc"), "")
	-- a symbol with an embedded email IS blanked even by the symbol scrub
	assert_equal(sanitize.sanitize_symbol("handler_for_a@b.com"), "")
	-- a 0x instruction address must NEVER be misread as IPv6 (no colons)
	assert_equal(sanitize.sanitize_string("0xdeadbeef"), "0xdeadbeef")
	-- A frame function is a code symbol in BOTH the trusted (auto-capture) and the
	-- untrusted (manual emit) path, so a dotted/qualified symbol survives in both:
	-- the full free-text scrub would blank it as a dotted token, leaving the frame
	-- unidentified and dropping the whole crash.
	assert_equal(sanitize.sanitize_function_name("pkg.A.b", true), "pkg.A.b")
	assert_equal(sanitize.sanitize_function_name("pkga.bbbb.cccc", false), "pkga.bbbb.cccc")
	-- a manual three-segment symbol like "game.player.update" survives (the bug:
	-- it used to be blanked by the full scrub's dotted-token heuristic)
	assert_equal(sanitize.sanitize_function_name("game.player.update", false), "game.player.update")
	-- a "::"-qualified code symbol survives both tiers and is NOT misread as an
	-- IPv6 literal (the "::" is scope resolution, not address compression)
	assert_equal(sanitize.sanitize_symbol("Auth::user_id_from_token"), "Auth::user_id_from_token")
	assert_equal(sanitize.sanitize_symbol("pkg::Type::method"), "pkg::Type::method")
	assert_equal(sanitize.sanitize_function_name("Auth::user_id_from_token", false),
		"Auth::user_id_from_token")
	-- but an embedded email / IPv4 in a frame function is still blanked in BOTH
	-- paths (only the "::" scope-resolution false positive was fixed)
	assert_equal(sanitize.sanitize_function_name("handler_a@b.com", false), "")
	assert_equal(sanitize.sanitize_function_name("handler_a@b.com", true), "")
	assert_equal(sanitize.sanitize_symbol("connect_10.0.0.1"), "")
	-- a genuine IPv6 literal standing as its own token IS still blanked by the
	-- symbol tier (its "::" is bounded by non-identifier chars)
	assert_equal(sanitize.sanitize_symbol("fe80::1"), "")
	assert_equal(sanitize.sanitize_symbol("addr fe80::1 down"), "")

	-- AGGRESSIVE embedded-id scrub: a disallowed prefix at a TOKEN BOUNDARY
	-- (start-of-string or right after a non-identifier char) followed by at least
	-- one identifier char is treated as a raw identifier ANYWHERE in the value and
	-- the whole value is blanked.
	assert_equal(sanitize.sanitize_string("failed for user_4242"), "")
	assert_equal(sanitize.sanitize_string("player_42 disconnected"), "")
	assert_equal(sanitize.sanitize_string("save failed for user_ab12"), "")
	assert_equal(sanitize.sanitize_string("dropped player_xyz9 from lobby"), "")
	assert_equal(sanitize.sanitize_string("player_abc123"), "")
	assert_equal(sanitize.sanitize_string("login failed for user_alice"), "")
	-- a digit-free identifier token after a token-boundary prefix is now ALSO a raw
	-- identifier under the aggressive rule (no longer treated as prose)
	assert_equal(sanitize.sanitize_string("user_id is null"), "")
	assert_equal(sanitize.sanitize_string("the device_token expired"), "")
	assert_equal(sanitize.sanitize_string("user_name was empty"), "")
	-- hyphen / dot / colon-separated suffixes are caught too
	assert_equal(sanitize.sanitize_string("customer_acme-42"), "")
	assert_equal(sanitize.sanitize_string("user_ab.12"), "")
	assert_equal(sanitize.sanitize_string("device_id:99"), "")
	-- but a prefix that is NOT at a token boundary is part of a larger word and
	-- survives (e.g. "multiuser_mode" — the "user_" is mid-word)
	assert_equal(sanitize.sanitize_string("multiuser_mode"), "multiuser_mode")
	assert_equal(sanitize.sanitize_string("superuser_panel opened"), "superuser_panel opened")
	-- a value with no disallowed-prefix token survives
	assert_equal(sanitize.sanitize_string("the player joined the lobby"), "the player joined the lobby")
	-- a dangling prefix with NO identifier continuation is harmless prose
	assert_equal(sanitize.sanitize_string("the user_ was here"), "the user_ was here")
	-- the AGGRESSIVE embedded-id rule must NOT touch the SYMBOL scrub: a
	-- package-qualified code symbol (a trusted frame function) must survive
	assert_equal(sanitize.sanitize_symbol("pkg.User_Service.update"), "pkg.User_Service.update")
	assert_equal(sanitize.sanitize_function_name("pkg.User_Service.update", true), "pkg.User_Service.update")
	-- a code symbol whose qualified name literally contains a disallowed prefix at a
	-- boundary still survives the symbol tier (only embedded email/IP blanks it)
	assert_equal(sanitize.sanitize_symbol("game.user_session.tick"), "game.user_session.tick")
	assert_equal(sanitize.sanitize_function_name("game.user_session.tick", true), "game.user_session.tick")

	-- STRUCTURED-FIELD tier (frame function / module name / exception type /
	-- breadcrumb name). It preserves legitimate structured values while still
	-- blanking a digit-bearing raw id and a high-confidence token.
	local long_jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
		.. "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ."
		.. "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
	local long_secret = "AKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLEXX"
	-- (a) a DIGIT-BEARING raw id at a sub-token boundary is blanked, even when glued
	-- by an underscore inside a compound name
	assert_equal(sanitize.sanitize_symbol("handler_user_4242"), "")
	assert_equal(sanitize.sanitize_symbol("user_42"), "")
	assert_equal(sanitize.sanitize_symbol("customer_acme-99"), "")
	assert_equal(sanitize.sanitize_symbol("auth.user_99"), "")
	-- A WHOLE-VALUE bare raw id — the ENTIRE value is a disallowed prefix followed
	-- solely by identifier chars — is blanked by the structured tier even with no
	-- digit (it is almost always a raw actor id, not code-symbol text). A rare lone
	-- bare symbol like "user_id_from_token" used as a whole function name therefore
	-- blanks; this only drops THAT frame (sibling frames / raw_text keep the crash
	-- alive and the server re-scrubs), never the whole report.
	assert_equal(sanitize.sanitize_symbol("user_alice"), "")
	assert_equal(sanitize.sanitize_symbol("customer_acme"), "")
	assert_equal(sanitize.sanitize_symbol("user_id_from_token"), "")
	assert_equal(sanitize.sanitize_symbol("user_session"), "")
	assert_equal(sanitize.sanitize_symbol("player_state"), "")
	-- A QUALIFIED code symbol that merely embeds a disallowed prefix mid-token does
	-- NOT start with the prefix, so it is NOT a bare raw id and is PRESERVED.
	assert_equal(sanitize.sanitize_symbol("Auth::user_id_from_token"), "Auth::user_id_from_token")
	assert_equal(sanitize.sanitize_symbol("game.user_session.tick"), "game.user_session.tick")
	assert_equal(sanitize.sanitize_symbol("pkg::user_handler"), "pkg::user_handler")
	-- a prefix glued to the middle of an alphanumeric word is NOT a sub-token start
	assert_equal(sanitize.sanitize_symbol("multiuser_4242"), "multiuser_4242")
	-- (b) a HIGH-CONFIDENCE JWT (dotted) is blanked in the structured tier too
	assert_equal(sanitize.sanitize_symbol(long_jwt), "")
	assert_equal(sanitize.sanitize_exception_type(long_jwt), "")
	-- A single long DOTLESS opaque run is PRESERVED by the structured/symbol tier:
	-- it is indistinguishable from a legitimate 40-char build id / mangled code
	-- symbol, so blanking it here would fail a required field and drop a native
	-- crash. The long-opaque-run rule is FREE-TEXT only, so the same value in a
	-- free-text field is still blanked (and the server re-scrubs structured fields).
	assert_equal(sanitize.sanitize_symbol(long_secret), long_secret)
	assert_equal(sanitize.sanitize_string("api key " .. long_secret), "")
	-- but a readable dotted class name is NOT a token and survives
	assert_equal(sanitize.sanitize_exception_type("java.lang.RuntimeException"),
		"java.lang.RuntimeException")
	assert_equal(sanitize.sanitize_exception_type("com.company.game.Crash"),
		"com.company.game.Crash")
	-- a structured module name (reverse-DNS package) survives the structured tier;
	-- the loose dotted-token rule would have blanked it and dropped the crash
	assert_equal(sanitize.sanitize_structured("com.company.game"), "com.company.game")
	-- a structured breadcrumb name with dotted segments survives, but a real token
	-- in the same field is still rejected
	do
		local name, ok = sanitize.sanitize_breadcrumb_name("level.load.done")
		assert_equal(ok, true)
		assert_equal(name, "level.load.done")
		local _, ok2 = sanitize.sanitize_breadcrumb_name("aaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbb.cccccccccccccccccc")
		assert_equal(ok2, false, "a high-confidence token breadcrumb name is rejected")
		local _, ok3 = sanitize.sanitize_breadcrumb_name("user_alice")
		assert_equal(ok3, false, "a digit-free raw-actor-id breadcrumb label is rejected")
		local _, ok4 = sanitize.sanitize_breadcrumb_name("customer_acme")
		assert_equal(ok4, false, "a digit-free raw-actor-id breadcrumb label is rejected")
	end
	-- a frame FILE path keeps normal source paths and redacts a user-home username,
	-- but does NOT apply the digit-bearing raw-id rule to path segments (a directory
	-- named like an identifier is not a raw actor id)
	assert_equal(sanitize.sanitize_file("Source/UI/user_interface.cpp"),
		"Source/UI/user_interface.cpp")
	assert_equal(sanitize.sanitize_file("Source/user_42/menu.cpp"),
		"Source/user_42/menu.cpp")
	-- but an embedded email / IP / real (dotted) token in a file path is still removed
	assert_equal(sanitize.sanitize_file("/logs/build@example.com/x.cpp"), "")
	-- a long dotless run in a file path is a hash-named build artifact, not a
	-- distinguishable secret, so it is preserved (the structured/file tier omits the
	-- free-text long-opaque-run rule — blanking it would lose file/line context);
	-- the same value in a genuine free-text field is still blanked.
	assert_equal(sanitize.sanitize_file(long_secret .. ".cpp"), long_secret .. ".cpp")

	-- a dotted version string is preserved (NOT misread as an IPv4 literal)
	assert_equal(sanitize.sanitize_version("1.2.3.4"), "1.2.3.4")
	assert_equal(sanitize.sanitize_version("2.0.0-rc.1+build.7"), "2.0.0-rc.1+build.7")
	-- but an email / raw-id / token in the version field is still rejected
	assert_equal(sanitize.sanitize_version("build@example.com"), "")
	assert_equal(sanitize.sanitize_version("user_123"), "")
	assert_equal(sanitize.sanitize_version("aaaa.bbbb.cccc"), "")
	-- a version-shaped value that is actually a bare raw id is rejected too
	assert_equal(sanitize.sanitize_version("user_abc"), "")
	assert_equal(sanitize.sanitize_version("device_token"), "")
	assert_equal(sanitize.sanitize_version("player_one"), "")
	-- a normal dotted version with no raw-id prefix still survives
	assert_equal(sanitize.sanitize_version("10.20.30"), "10.20.30")

	-- a Lua error / traceback line ("file:42:") must NOT be misread as an IPv6
	-- literal and blanked — that would drop a raw-text fatal crash. The text is
	-- preserved verbatim.
	assert_equal(sanitize.sanitize_string("main.script:42: attempt to index nil"),
		"main.script:42: attempt to index nil")
	assert_equal(sanitize.sanitize_string("game/update.lua:123: bad argument"),
		"game/update.lua:123: bad argument")
	-- a plain numeric log time ("12:34:56") is hextet-shaped but is NOT an IPv6
	-- literal: blanking it would drop a raw-text-only fatal crash carrying a
	-- timestamp. It must survive verbatim. A genuine IPv6 signal requires a hex
	-- LETTER, a "::" compression, or the full 8-group form.
	assert_equal(sanitize.sanitize_string("12:34:56"), "12:34:56")
	assert_equal(sanitize.sanitize_string("01:02:03"), "01:02:03")
	assert_equal(sanitize.sanitize_string("crashed at 12:34:56 in update"),
		"crashed at 12:34:56 in update")
	-- but a genuine IPv6 literal is still blanked
	assert_equal(sanitize.sanitize_string("fe80::1"), "")
	assert_equal(sanitize.sanitize_string("2001:db8::1"), "")
	assert_equal(sanitize.sanitize_string("listen on 2001:db8:0:0:0:0:0:1 failed"), "")
	-- a 3-group run with a hex LETTER is a genuine (partial) IPv6 signal and blanks
	assert_equal(sanitize.sanitize_string("addr ab:cd:ef down"), "")
	-- the full 8-group numeric form is IPv6 even with no hex letter
	assert_equal(sanitize.sanitize_string("0:0:0:0:0:0:0:1"), "")

	-- a user-home path has only its username segment redacted; the rest of the
	-- path survives so the file location is still useful
	assert_equal(sanitize.sanitize_string("crash at /Users/alice/game/main.lua"),
		"crash at /Users/<redacted>/game/main.lua")
	assert_equal(sanitize.sanitize_string("/home/bob/projects/app/x.lua failed"),
		"/home/<redacted>/projects/app/x.lua failed")
	assert_equal(sanitize.sanitize_string([[loaded C:\Users\Charlie\game\f.dat]]),
		[[loaded C:\Users\<redacted>\game\f.dat]])
	-- the redaction is case-insensitive on the home prefix
	assert_equal(sanitize.sanitize_string("/users/dave/x.lua"), "/users/<redacted>/x.lua")
	-- a path with no user-home prefix is untouched
	assert_equal(sanitize.sanitize_string("/opt/game/main.lua:42"), "/opt/game/main.lua:42")
	-- the username segment is redacted even when it ENDS the value (no trailing
	-- slash) — otherwise the OS account name leaks on the wire
	assert_equal(sanitize.sanitize_string("/home/alice"), "/home/<redacted>")
	assert_equal(sanitize.sanitize_string("permission denied: /Users/alice"),
		"permission denied: /Users/<redacted>")
	-- a username ending at a non-path boundary (whitespace / quote / paren) is
	-- redacted and the boundary preserved
	assert_equal(sanitize.sanitize_string("opening /Users/bob failed"),
		"opening /Users/<redacted> failed")
	assert_equal(sanitize.sanitize_string("path (/home/carol) missing"),
		"path (/home/<redacted>) missing")
	-- Windows: the account name ending the value is redacted too
	assert_equal(sanitize.sanitize_string([[C:\Users\Dave]]), [[C:\Users\<redacted>]])
	-- the placeholder itself is not re-matched / double-redacted
	assert_equal(sanitize.sanitize_string("/home/eve/x and /Users/frank"),
		"/home/<redacted>/x and /Users/<redacted>")
	-- the symbol/frame-function tier ALSO redacts a user-home username segment: a
	-- frame function can describe a closure by its source path ("callback in
	-- /Users/<name>/x.lua"), and the OS account name must not reach the wire even
	-- though the rest of the symbol survives
	assert_equal(sanitize.sanitize_symbol("/Users/eve/x"), "/Users/<redacted>/x")
	assert_equal(sanitize.sanitize_symbol("callback in /Users/eve/x.lua"),
		"callback in /Users/<redacted>/x.lua")

	-- a package-qualified exception type is a structured code identifier and must
	-- survive the exception-type scrub even though it is dotted (the full scrub
	-- would blank it as a dotted-token credential and drop the crash)
	assert_equal(sanitize.sanitize_exception_type("java.lang.RuntimeException"),
		"java.lang.RuntimeException")
	assert_equal(sanitize.sanitize_exception_type("com.company.game.Crash"),
		"com.company.game.Crash")
	assert_equal(sanitize.sanitize_exception_type("lua_error"), "lua_error")
	-- but an email / raw id / IP smuggled into the type is still removed
	assert_equal(sanitize.sanitize_exception_type("crash_from_a@b.com"), "")
	assert_equal(sanitize.sanitize_exception_type("user_4242"), "")
	assert_equal(sanitize.sanitize_exception_type("10.0.0.1"), "")

	-- an email FOLLOWED BY SENTENCE PUNCTUATION is still detected and blanked: the
	-- trailing dot / comma / paren must not let a real address slip past the
	-- scrubber (the domain capture used to swallow a trailing dot and fail the TLD
	-- check)
	assert_equal(sanitize.sanitize_string("alice@example.com."), "")
	assert_equal(sanitize.sanitize_string("contact alice@example.com, please"), "")
	assert_equal(sanitize.sanitize_string("see (alice@example.com)"), "")
	assert_equal(sanitize.sanitize_string("ping alice@example.com..."), "")
	-- a bare address with no trailing punctuation is still blanked
	assert_equal(sanitize.sanitize_string("alice@example.com"), "")
	-- and the embedded form inside a longer reason string is blanked
	assert_equal(sanitize.sanitize_string("login failed for alice@example.com."), "")
	-- but a NON-email "@" token still survives (it would otherwise blank a value,
	-- fail the frames-or-text requirement, and DROP a fatal crash): an HTML5/file
	-- URL after "@", or an offset like "module@0x1234", is not an address
	assert_equal(sanitize.sanitize_string("load @file:///game/x failed"),
		"load @file:///game/x failed")
	assert_equal(sanitize.sanitize_string("at module@0x1234"), "at module@0x1234")

	-- a SINGLE LONG OPAQUE SECRET (40+ char base64url run, NO dots) in a free-text
	-- field must be blanked by the FULL scrub: the loose dotted-token heuristic only
	-- catches a DOTTED secret, so a dotless API key would otherwise leak.
	local long_opaque = "AKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLEXX"
	assert(#long_opaque >= 40)
	assert_equal(sanitize.sanitize_string(long_opaque), "")
	-- it is blanked even embedded in a sentence (an exception reason / breadcrumb
	-- message / metadata value)
	assert_equal(sanitize.sanitize_string("auth failed with key " .. long_opaque), "")
	-- a normal sentence (no 40+ char unbroken run) is PRESERVED — the rule must not
	-- over-blank readable prose and drop a fatal crash carrying its reason
	assert_equal(sanitize.sanitize_string("the player could not connect to the lobby server"),
		"the player could not connect to the lobby server")
	-- a short token survives
	assert_equal(sanitize.sanitize_string("abc123def456"), "abc123def456")
	-- the STRUCTURED tier stays symbol-preserving: it does NOT gain the dotted-token
	-- heuristic, so a long READABLE dotted symbol still survives (only a real
	-- high-confidence token blanks it, which it already handled)
	assert_equal(sanitize.sanitize_structured("com.company.game.subsystem.module"),
		"com.company.game.subsystem.module")

	-- RAW-TEXT tier: the native trace is scrubbed by REDACTING PII SUBSTRINGS IN
	-- PLACE and is NEVER blanked-whole (so a frame-less fatal that relies entirely on
	-- raw_text is never dropped). PII is removed; code symbols and surrounding prose
	-- survive.
	-- pure code symbols are unchanged (nothing to redact)
	assert_equal(
		sanitize.sanitize_raw_text("java.lang.RuntimeException at Player::Update via game.player.update"),
		"java.lang.RuntimeException at Player::Update via game.player.update")
	-- mixed PII + symbol: the PII is replaced in place, the symbol + prose survive
	do
		local out = sanitize.sanitize_raw_text(
			"login failed for user_alice at Player::Update (a@b.com 10.0.0.5)")
		assert_not_contains(out, "user_alice")
		assert_not_contains(out, "a@b.com")
		assert_not_contains(out, "10.0.0.5")
		assert_contains(out, "Player::Update")
		assert_contains(out, "login failed for")
		assert_not_equal(out, "", "raw_text must never be blanked whole")
	end
	-- a genuine IPv6 literal is redacted, a "::"-qualified symbol is NOT
	do
		local out = sanitize.sanitize_raw_text("connect fe80::1 from pkg::Type::method")
		assert_not_contains(out, "fe80::1")
		assert_contains(out, "pkg::Type::method")
	end
	-- a log timestamp is left intact (not an IPv6 literal)
	assert_equal(
		sanitize.sanitize_raw_text("12:34:56 main.script:42: attempt to index nil"),
		"12:34:56 main.script:42: attempt to index nil")
	-- a real JWT embedded in the trace is redacted in place; the trailing symbol stays
	do
		local jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
			.. "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ."
			.. "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
		local out = sanitize.sanitize_raw_text("token=" .. jwt .. " at game.tick")
		assert_not_contains(out, jwt)
		assert_not_contains(out, "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ")
		assert_contains(out, "game.tick")
	end
	-- a long opaque dotless secret run is redacted in place
	do
		local out = sanitize.sanitize_raw_text(
			"auth failed key=AKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLEXX at game.tick")
		assert_not_contains(out, "AKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLEXX")
		assert_contains(out, "game.tick")
	end
	-- a user-home username segment is redacted, the rest of the path survives
	do
		local out = sanitize.sanitize_raw_text("crash at /Users/alice/game/main.lua")
		assert_not_contains(out, "alice")
		assert_contains(out, "/game/main.lua")
	end
	-- a non-email "@" (an offset) is NOT redacted
	assert_equal(sanitize.sanitize_raw_text("at module@0x1234 fault"),
		"at module@0x1234 fault")
	-- a DIGIT-BEARING raw id glued after a dot is redacted; a digit-FREE qualified
	-- code path (game.user_session.tick) survives intact
	do
		local out = sanitize.sanitize_raw_text("crash in handler.user_4242.update")
		assert_not_contains(out, "user_4242")
		assert_contains(out, "handler.")
	end
	assert_equal(sanitize.sanitize_raw_text("game.user_session.tick failed"),
		"game.user_session.tick failed")
	-- a prefix glued mid-alphanumeric is not a fresh sub-token and survives
	assert_equal(sanitize.sanitize_raw_text("multiuser_4242 active"),
		"multiuser_4242 active")
end

-- ── breadcrumbs ──────────────────────────────────────────────────────────────

local function test_breadcrumbs_attached_and_bounded()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	for i = 1, event_mod.max_breadcrumbs + 10 do
		client:record_breadcrumb("step." .. tostring(i))
	end
	assert_true(client:emit(presymbolicated_event()))
	local body = requests[1].body
	assert_contains(body, '"breadcrumbs":[')
	-- the oldest were dropped (ring of max_breadcrumbs); the newest is kept
	assert_contains(body, '"name":"step.' .. tostring(event_mod.max_breadcrumbs + 10) .. '"')
	assert_not_contains(body, '"name":"step.1"')
	-- breadcrumb count never exceeds the cap
	local count = 0
	for _ in body:gmatch('"timestamp"') do
		count = count + 1
	end
	assert_true(count <= event_mod.max_breadcrumbs, "breadcrumbs must not exceed the cap")
end

local function test_breadcrumb_pii_name_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A breadcrumb name is a user-provided label: a raw actor id is rejected as PII
	-- whether or not it has a digit ("user_4242", "user_alice", "customer_acme"),
	-- while a legitimate dotted name ("level.load.done") and a plain word
	-- ("menu.open") survive.
	assert_equal(client:record_breadcrumb("user_4242"), false, "a digit-bearing raw-id breadcrumb name is rejected")
	assert_equal(client:record_breadcrumb("user_alice"), false, "a digit-free raw-actor-id breadcrumb label is rejected")
	assert_equal(client:record_breadcrumb("customer_acme"), false, "a digit-free raw-actor-id breadcrumb label is rejected")
	assert_true(client:record_breadcrumb("level.load.done"))
	assert_true(client:record_breadcrumb("menu.open"))
	assert_true(client:emit(presymbolicated_event()))
	assert_not_contains(requests[1].body, "user_4242")
	assert_not_contains(requests[1].body, "user_alice")
	assert_contains(requests[1].body, '"name":"level.load.done"')
	assert_contains(requests[1].body, '"name":"menu.open"')
end

-- A breadcrumb name is OPTIONAL caller input, not a required native code symbol, so
-- a single long opaque token (a 40+ char dotless base64url run, API-key-shaped) is
-- never a legitimate readable label and must be dropped — dropping the breadcrumb
-- does not affect the crash. A normal dotted label ("level.load.done") still ships.
local function test_breadcrumb_long_opaque_name_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- a 44-char dotless base64url token (no separators a readable label would have)
	local opaque = "AbCdEf0123456789AbCdEf0123456789AbCdEf012345"
	assert_equal(#opaque >= 40, true, "the fixture is a long opaque run")
	assert_equal(client:record_breadcrumb(opaque), false,
		"a long dotless opaque breadcrumb name must be dropped")
	-- MUTATION GUARD: a normal short dotted label still survives
	assert_true(client:record_breadcrumb("level.load.done"))
	assert_true(client:emit(presymbolicated_event()))
	assert_not_contains(requests[1].body, opaque)
	assert_contains(requests[1].body, '"name":"level.load.done"')
end

-- ── transport outcomes ───────────────────────────────────────────────────────

local function test_accepted_increments_snapshot()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(client:snapshot().accepted, 1)
	assert_equal(client:snapshot().failed, 0)
end

local function test_rejected_surfaced_via_diagnostics()
	reset()
	next_status = 400
	local issues = {}
	local client = assert(crash.new(config({
		sample_every = 1,
		diagnostics = function(issue)
			issues[#issues + 1] = issue
		end,
	})))
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(client:snapshot().failed, 1)
	assert_equal(client:snapshot().rejected, 1)
	assert_equal(#issues, 1)
	assert_equal(issues[1].scope, "crash")
	assert_equal(issues[1].status, "rejected")
	assert_equal(issues[1].code, "http_400")
end

local function test_unauthorized_surfaced()
	reset()
	next_status = 401
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(client:snapshot().failed, 1)
	assert_equal(client:snapshot().last_error, "unauthorized")
	-- a 401 is an auth problem, not a content rejection
	assert_equal(client:snapshot().rejected, 0)
end

local function test_suppressed_response_surfaced()
	reset()
	next_status = 202
	next_response_body = '{"suppressed":true}'
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(client:snapshot().suppressed, 1,
		"a consent-suppressed 2xx must be surfaced as suppressed")
	assert_equal(client:snapshot().accepted, 0,
		"a suppressed crash was not stored, so it must NOT count as accepted")
end

local function test_warning_surfaced()
	reset()
	next_status = 202
	next_response_body = '{"crash_id":"x","warnings":["truncated breadcrumbs"]}'
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(client:snapshot().accepted, 1)
	assert_equal(client:snapshot().suppressed, 0)
	assert_equal(client:snapshot().last_warning, "truncated breadcrumbs")
end

local function test_garbage_2xx_body_still_accepted()
	reset()
	next_status = 202
	next_response_body = "<<not json>>"
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(client:snapshot().accepted, 1,
		"a 2xx with an unparseable body is still an accepted crash")
	assert_equal(client:snapshot().suppressed, 0)
end

local function test_retry_after_recorded_on_429()
	reset()
	next_status = 429
	next_response_headers = { ["retry-after"] = "7" }
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(client:snapshot().failed, 1)
	assert_equal(client:snapshot().last_retry_after, 7,
		"the 429 Retry-After must be recorded")
end

local function test_retry_after_recorded_on_503()
	reset()
	next_status = 503
	next_response_headers = { ["retry-after"] = "3" }
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(client:snapshot().failed, 1)
	assert_equal(client:snapshot().last_retry_after, 3,
		"the 503 Retry-After must be recorded (previously dropped on the 5xx path)")
end

-- ── auto-capture (previous-session dump forward) ─────────────────────────────

local function fake_crash_module(opts)
	opts = opts or {}
	local released = { value = false }
	local module = {
		SYSFIELD_SYSTEM_NAME = 1,
		SYSFIELD_SYSTEM_VERSION = 2,
		load_previous = function()
			return opts.handle
		end,
		release = function()
			released.value = true
		end,
		get_signum = function()
			return opts.signum
		end,
		get_modules = function()
			return opts.modules or {}
		end,
		get_backtrace = function()
			return opts.backtrace or {}
		end,
		get_sys_field = function(_, field)
			if field == 1 then
				return opts.os_name
			elseif field == 2 then
				return opts.os_version
			end
			return nil
		end,
	}
	return module, released
end

local function test_capture_previous_no_dump()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local module = fake_crash_module({ handle = nil })
	local ok, sent = client:capture_previous(module)
	assert_equal(ok, true)
	assert_equal(sent, false, "no dump means nothing is sent")
	assert_equal(#requests, 0)
end

local function test_capture_previous_forwards_native_dump()
	reset()
	local module, released = fake_crash_module({
		handle = 7,
		signum = 11,
		os_name = "Android",
		os_version = "14",
		modules = {
			{ name = "libgame.so", address = 0x1000 },
			{ name = "libc.so", address = 0x8000 },
		},
		backtrace = {
			{ address = 0x1abc },
			{ address = 0x1def },
		},
	})
	-- A 1-in-1000 sampler must NOT suppress the dump forward (it is fatal).
	local client = assert(crash.new(config({ sample_every = 1000, crash_source = "game-client" })))
	local ok, sent = client:capture_previous(module)
	assert_equal(ok, true)
	assert_equal(sent, true)
	assert_equal(released.value, true, "the dump handle must be released")
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_equal(requests[1].url, "http://localhost:8080/api/v1/crashes/ingest")
	assert_contains(body, '"type":"SIGSEGV"')
	assert_contains(body, '"source":"game-client"')
	assert_contains(body, '"os":{')
	assert_contains(body, '"name":"Android"')
	-- native modules + address frames
	assert_contains(body, '"name":"libgame.so"')
	assert_contains(body, '"load_address":"0x1000"')
	assert_contains(body, '"instruction_addr":"0x1abc"')
	assert_contains(body, '"instruction_addr":"0x1def"')
end

local function test_capture_previous_drops_dump_without_modules()
	reset()
	-- A backtrace with no resolvable module map is unsymbolicatable: it must be
	-- dropped, not shipped as an invalid event.
	local module = fake_crash_module({
		handle = 1,
		signum = 6,
		backtrace = { { address = 0x1abc } },
		modules = {},
	})
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok, sent = client:capture_previous(module)
	assert_equal(ok, true)
	assert_equal(sent, false, "a dump with no module map is dropped")
	assert_equal(#requests, 0)
end

local function test_dump_event_builder_unit()
	-- The dump builder must produce a valid native event that survives prepare().
	local module = fake_crash_module({
		handle = 3,
		signum = 11,
		modules = { { name = "libgame.so", address = 0x2000 } },
		backtrace = { { address = 0x2abc } },
	})
	local event = dump.load_previous_event(module)
	assert_true(event ~= nil, "a usable dump yields an event")
	assert_equal(event.exception.type, "SIGSEGV")
	assert_equal(#event.modules, 1)
	assert_equal(event.modules[1].load_address, "0x2000")
	assert_equal(#event.threads[1].frames, 1)
	assert_equal(event.threads[1].frames[1].instruction_addr, "0x2abc")
end

-- ── singleton API ────────────────────────────────────────────────────────────

local function test_singleton_guard_and_flow()
	reset()
	-- before init the singleton calls report not_initialized
	local ok, err = crash.emit(presymbolicated_event())
	assert_equal(ok, false)
	assert_equal(err, "not_initialized")

	assert_true(crash.init(config({ sample_every = 1, crash_source = "game-client" })))
	assert_true(crash.record_breadcrumb("menu.open"))
	assert_true(crash.emit_fatal(presymbolicated_event()))
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"source":"game-client"')

	assert_true(crash.shutdown())
	ok, err = crash.emit(presymbolicated_event())
	assert_equal(ok, false)
	assert_equal(err, "not_initialized")
end

local function test_caller_event_not_mutated()
	reset()
	local client = assert(crash.new(config({ sample_every = 1, crash_source = "main-server" })))
	local event = presymbolicated_event()
	assert_true(client:emit(event))
	-- prepare() clones; the caller's table must be untouched (no defaulted source
	-- or crash_id leaked back).
	assert_equal(event.source, nil)
	assert_equal(event.crash_id, nil)
	assert_equal(event.app, nil)
	assert_equal(event.platform, nil)
end

-- ── crash_id normalization ──────────────────────────────────────────

local function test_crash_id_pii_replaced_with_uuid()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A caller crash_id carrying a raw-identifier prefix must NOT reach the wire;
	-- it is replaced with a generated UUIDv7, never dropped.
	assert_true(client:emit(presymbolicated_event({ crash_id = "player_123" })))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "player_123")
	local crash_id = body:match('"crash_id":"([^"]+)"')
	assert_true(event_mod.looks_like_uuid_v7(crash_id),
		"a PII crash_id must be replaced by a UUIDv7: " .. tostring(crash_id))

	-- An email-shaped crash_id is likewise replaced.
	reset()
	assert_true(client:emit(presymbolicated_event({ crash_id = "a@b.com" })))
	assert_not_contains(requests[1].body, "a@b.com")

	-- A free-form value (spaces/punctuation) is not a stable id shape -> replaced.
	reset()
	assert_true(client:emit(presymbolicated_event({ crash_id = "oops it broke!" })))
	assert_not_contains(requests[1].body, "oops it broke")

	-- A clean caller-supplied id-shaped value is preserved verbatim.
	reset()
	assert_true(client:emit(presymbolicated_event({ crash_id = "crash-abc.123" })))
	assert_contains(requests[1].body, '"crash_id":"crash-abc.123"')

	-- A caller-supplied UUID is preserved.
	reset()
	local uuid = "0190b3c4-1234-7abc-89ab-0123456789ab"
	assert_true(client:emit(presymbolicated_event({ crash_id = uuid })))
	assert_contains(requests[1].body, '"crash_id":"' .. uuid .. '"')
end

-- ── identity keys stripped from caller context ──────────────────────

local function test_context_identity_keys_stripped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- Clean (non-PII-prefixed) identity values would pass the value scrub; the KEY
	-- itself must be stripped so a raw actor identifier never reaches the wire.
	assert_true(client:emit(presymbolicated_event({
		context = {
			session_id = "0190b3c4-1234-7abc-89ab-0123456789ab",
			anonymous_id = "anon-cleanvalue",
			user_id = "alice",
			device_id = "dev-1",
			-- a non-identity context value survives
			build_channel = "beta",
		},
	})))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "session_id")
	assert_not_contains(body, "anonymous_id")
	assert_not_contains(body, '"user_id"')
	assert_not_contains(body, "0190b3c4-1234-7abc-89ab-0123456789ab")
	assert_not_contains(body, "anon-cleanvalue")
	assert_contains(body, '"build_channel":"beta"')
end

-- ── occurred_at validation ──────────────────────────────────────────

local function test_occurred_at_malformed_defaults_to_now()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A malformed occurred_at must NOT be shipped verbatim; default to now.
	assert_true(client:emit(presymbolicated_event({ occurred_at = "not a date" })))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "not a date")
	local occurred_at = body:match('"occurred_at":"([^"]+)"')
	assert_true(event_mod.valid_iso_instant(occurred_at),
		"occurred_at must be a valid ISO instant: " .. tostring(occurred_at))

	-- A PII-bearing occurred_at is replaced too (never dropped).
	reset()
	assert_true(client:emit(presymbolicated_event({ occurred_at = "player_99" })))
	assert_not_contains(requests[1].body, "player_99")

	-- A clean ISO instant is preserved verbatim.
	reset()
	assert_true(client:emit(presymbolicated_event({ occurred_at = "2026-06-21T10:11:12Z" })))
	assert_contains(requests[1].body, '"occurred_at":"2026-06-21T10:11:12Z"')
end

-- ── breadcrumb timestamp validation ─────────────────────────────────

local function test_breadcrumb_timestamp_scrubbed()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A caller breadcrumb with a malformed/PII timestamp must not ship it verbatim;
	-- it falls back to the event time. A clean ISO timestamp is preserved.
	assert_true(client:emit(presymbolicated_event({
		occurred_at = "2026-06-21T10:11:12Z",
		breadcrumbs = {
			{ name = "menu.open", timestamp = "user_4242" },
			{ name = "level.load", timestamp = "2026-06-21T09:00:00Z" },
		},
	})))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "user_4242")
	-- the clean caller timestamp survives
	assert_contains(body, '"timestamp":"2026-06-21T09:00:00Z"')
	-- the bad one fell back to the event time
	assert_contains(body, '"timestamp":"2026-06-21T10:11:12Z"')
end

-- ── first_non_empty nil-tolerant fallback ────────────────────────────────

local function test_base_address_without_load_address_accepted()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A module with base_address but NO load_address must satisfy the
	-- load/base-address requirement (the nil first arg must not stop the fallback).
	assert_true(client:emit({
		exception = { type = "SIGSEGV" },
		modules = {
			{ name = "libgame.so", debug_id = "ABC123", base_address = "0x2000" },
		},
		threads = {
			{ id = "main", crashed = true, frames = { { address = "0xdeadbeef" } } },
		},
	}))
	assert_equal(#requests, 1, "a frame .address (instruction_addr nil) must be accepted")
	assert_contains(requests[1].body, '"base_address":"0x2000"')
	-- The accepted `address` alias is normalized into `instruction_addr` before the
	-- wire so the server can resolve it; the bare `address` alias is dropped.
	assert_contains(requests[1].body, '"instruction_addr":"0xdeadbeef"')
	assert_not_contains(requests[1].body, '"address":"0xdeadbeef"')
end

-- ── malformed nested entry rejected cleanly (no Lua error) ────────────────

local function test_malformed_nested_entry_rejected()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A non-table module entry must be rejected via the normal error path, never
	-- raise a Lua error.
	local ok, err = client:emit(presymbolicated_event({ modules = { 42 } }))
	assert_equal(ok, false)
	assert_equal(err, "malformed_event")
	assert_equal(#requests, 0)

	-- A non-table thread entry is likewise rejected.
	reset()
	ok, err = client:emit({ exception = { type = "x" }, threads = { 7 } })
	assert_equal(ok, false)
	assert_equal(err, "malformed_event")

	-- A non-table frame entry is likewise rejected.
	reset()
	ok, err = client:emit({
		exception = { type = "x" },
		threads = { { id = "main", crashed = true, frames = { "nope" } } },
	})
	assert_equal(ok, false)
	assert_equal(err, "malformed_event")
end

-- ── non-hex frame address rejected ───────────────────────────────────────

local function test_non_hex_frame_address_rejected()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A non-empty but non-hex address is cleared, never dispatched as a resolvable
	-- address. Here it is the frame's only identity, so the frame is dropped and the
	-- report falls back to the frame-less rule — still rejected, nothing non-hex sent.
	local ok, err = client:emit({
		exception = { type = "SIGSEGV" },
		modules = { { name = "libgame.so", debug_id = "ABC", load_address = "0x1000" } },
		threads = {
			{ id = "main", crashed = true, frames = { { instruction_addr = "nothex" } } },
		},
	})
	assert_equal(ok, false)
	assert_equal(err, "frames_or_raw_text_required")
	assert_equal(#requests, 0)

	-- Fatal-safety: a non-hex address on ONE frame must not drop a fatal whose other
	-- frames are clean. The bad address is cleared (that frame dropped), and the clean
	-- symbolic frame still ships — the non-hex value never reaches the wire.
	reset()
	assert_true(client:emit_fatal({
		exception = { type = "SIGSEGV" },
		modules = { { name = "libgame.so", debug_id = "ABC", load_address = "0x1000" } },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					{ instruction_addr = "nothex" },
					{ ["function"] = "game.update" },
				},
			},
		},
	}))
	assert_equal(#requests, 1)
	assert_not_contains(requests[1].body, "nothex")
	assert_contains(requests[1].body, '"function":"game.update"')

	-- A bare-hex (no 0x) address is a valid address shape and is accepted.
	reset()
	assert_true(client:emit({
		exception = { type = "SIGSEGV" },
		modules = { { name = "libgame.so", debug_id = "ABC", load_address = "0x1000" } },
		threads = {
			{ id = "main", crashed = true, frames = { { instruction_addr = "deadbeef" } } },
		},
	}))
	assert_equal(#requests, 1)
end

-- ── shutdown awaits in-flight crash sends ───────────────────────────

local function test_shutdown_waits_for_in_flight_send()
	reset()
	-- A transport that holds its callback simulates the real async http path: the
	-- POST has not completed, so shutdown must report pending, not success.
	local held_callback = nil
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		held_callback = function()
			callback(nil, nil, { status = 202, response = '{"crash_id":"x"}' })
		end
	end

	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(#requests, 1)

	-- The send is in flight: shutdown must NOT finalize.
	local ok, err = client:shutdown()
	assert_equal(ok, false)
	assert_equal(err, "pending")

	-- The runtime delivers the http callback (host pumped http.update); now the
	-- in-flight send has settled and a retried shutdown finalizes.
	held_callback()
	assert_equal(client:snapshot().accepted, 1)
	assert_true(client:shutdown())

	http.request = saved_request
end

-- ── dump forward does not attach the current breadcrumb ring ─────────────

local function test_capture_previous_does_not_attach_current_breadcrumbs()
	reset()
	local module = fake_crash_module({
		handle = 9,
		signum = 11,
		os_name = "Android",
		modules = { { name = "libgame.so", address = 0x1000 } },
		backtrace = { { address = 0x1abc } },
	})
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- The current (live) session recorded a breadcrumb; it must NOT be attached to
	-- the previous-session dump, whose own breadcrumbs are unavailable.
	assert_true(client:record_breadcrumb("live-session-breadcrumb"))
	local ok, sent = client:capture_previous(module)
	assert_equal(ok, true)
	assert_equal(sent, true)
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "live-session-breadcrumb")
	assert_not_contains(body, '"breadcrumbs"')
end

-- ── identity keys stripped from metadata too ────────────────────────────

local function test_metadata_identity_keys_stripped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- Clean (non-PII-prefixed) identity VALUES pass the value scrub; the KEY itself
	-- must be stripped from metadata exactly as it is from context, so a raw actor
	-- identifier never reaches the wire.
	assert_true(client:emit(presymbolicated_event({
		metadata = {
			session_id = "0190b3c4-5678-7abc-89ab-0123456789ab",
			anonymous_id = "anon-cleanvalue",
			user_id = "alice",
			device_id = "dev-1",
			-- a non-identity metadata value survives
			level_name = "forest",
		},
	})))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "session_id")
	assert_not_contains(body, "anonymous_id")
	assert_not_contains(body, '"user_id"')
	assert_not_contains(body, "0190b3c4-5678-7abc-89ab-0123456789ab")
	assert_not_contains(body, "anon-cleanvalue")
	assert_contains(body, '"level_name":"forest"')
end

-- ── absent optional module fields are omitted, not blank ────────────────

local function test_absent_module_fields_omitted()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A module with only the required fields (name + debug_id + load_address) must
	-- not encode present-but-empty optional fields.
	assert_true(client:emit({
		exception = { type = "SIGSEGV" },
		modules = {
			{ name = "libgame.so", debug_id = "ABC123", load_address = "0x1000" },
		},
		threads = {
			{ id = "main", crashed = true, frames = { { address = "0xdeadbeef" } } },
		},
	}))
	assert_equal(#requests, 1)
	local body = requests[1].body
	-- the required module fields are present
	assert_contains(body, '"name":"libgame.so"')
	assert_contains(body, '"debug_id":"ABC123"')
	assert_contains(body, '"load_address":"0x1000"')
	-- the absent optional fields are omitted entirely (no empty strings on the wire)
	assert_not_contains(body, '"platform":""')
	assert_not_contains(body, '"base_address":""')
	assert_not_contains(body, '"end_address":""')
	assert_not_contains(body, '"size":""')
	assert_not_contains(body, '"build_id":""')
end

-- ── absent optional breadcrumb fields are omitted, not blank ────────────

local function test_absent_breadcrumb_fields_omitted()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A breadcrumb supplied with only a name must not encode present-but-empty
	-- type/category/level/message.
	assert_true(client:emit(presymbolicated_event({
		breadcrumbs = {
			{ name = "menu.open" },
		},
	})))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_contains(body, '"name":"menu.open"')
	assert_not_contains(body, '"type":""')
	assert_not_contains(body, '"category":""')
	assert_not_contains(body, '"level":""')
	assert_not_contains(body, '"message":""')
	-- a present breadcrumb field still survives
	reset()
	assert_true(client:emit(presymbolicated_event({
		breadcrumbs = {
			{ name = "level.load", category = "navigation", message = "entered forest" },
		},
	})))
	body = requests[1].body
	assert_contains(body, '"category":"navigation"')
	assert_contains(body, '"message":"entered forest"')
	assert_not_contains(body, '"type":""')
	assert_not_contains(body, '"level":""')
end

-- ── fractional-seconds grammar is strict ────────────────────────────────

local function test_iso_instant_fraction_strict()
	-- A single dot + digits fractional part is valid.
	assert_true(event_mod.valid_iso_instant("2026-06-21T10:11:12.5Z"))
	assert_true(event_mod.valid_iso_instant("2026-06-21T10:11:12.123456Z"))
	assert_true(event_mod.valid_iso_instant("2026-06-21T10:11:12Z"))
	assert_true(event_mod.valid_iso_instant("2026-06-21T10:11:12.5+05:30"))
	assert_true(event_mod.valid_iso_instant("2026-06-21T10:11:12-08:00"))
	-- Malformed fractional runs must NOT pass.
	assert_true(not event_mod.valid_iso_instant("2026-06-21T10:11:12..Z"))
	assert_true(not event_mod.valid_iso_instant("2026-06-21T10:11:12.5.6Z"))
	assert_true(not event_mod.valid_iso_instant("2026-06-21T10:11:12.Z"))
	assert_true(not event_mod.valid_iso_instant("2026-06-21T10:11:12.5.6+01:00"))

	-- End-to-end: a malformed-fraction occurred_at is defaulted, never shipped.
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event({ occurred_at = "2026-06-21T10:11:12..Z" })))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "2026-06-21T10:11:12..Z")
	local occurred_at = body:match('"occurred_at":"([^"]+)"')
	assert_true(event_mod.valid_iso_instant(occurred_at),
		"defaulted occurred_at must be a valid ISO instant: " .. tostring(occurred_at))
end

-- ── non-hex module load/base address rejected ───────────────────────────

local function test_non_hex_module_address_rejected()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A module whose load_address is non-hex is an unusable entry: it is dropped
	-- rather than rejecting the whole report. Here the lone address frame
	-- (0xdeadbeef) has no module map left to resolve against and no function symbol,
	-- so its unresolvable address is cleared and the now-identity-less frame is
	-- dropped; with nothing left the report is honestly rejected as having no crash
	-- content. Either way nothing non-hex is dispatched.
	local ok, err = client:emit({
		exception = { type = "SIGSEGV" },
		modules = { { name = "libgame.so", debug_id = "ABC", load_address = "nothex" } },
		threads = {
			{ id = "main", crashed = true, frames = { { address = "0xdeadbeef" } } },
		},
	})
	assert_equal(ok, false)
	assert_equal(err, "frames_or_raw_text_required")
	assert_equal(#requests, 0)

	-- A non-hex base_address (used as the fallback) likewise makes the module unusable.
	reset()
	ok, err = client:emit({
		exception = { type = "SIGSEGV" },
		modules = { { name = "libgame.so", debug_id = "ABC", base_address = "deadzone" } },
		threads = {
			{ id = "main", crashed = true, frames = { { address = "0xdeadbeef" } } },
		},
	})
	assert_equal(ok, false)
	assert_equal(err, "frames_or_raw_text_required")

	-- A valid hex (0x-prefixed or bare) module address is accepted.
	reset()
	assert_true(client:emit({
		exception = { type = "SIGSEGV" },
		modules = { { name = "libgame.so", debug_id = "ABC", load_address = "0x1000" } },
		threads = {
			{ id = "main", crashed = true, frames = { { address = "0xdeadbeef" } } },
		},
	}))
	assert_equal(#requests, 1)
	reset()
	assert_true(client:emit({
		exception = { type = "SIGSEGV" },
		modules = { { name = "libgame.so", debug_id = "ABC", base_address = "2000" } },
		threads = {
			{ id = "main", crashed = true, frames = { { address = "0xdeadbeef" } } },
		},
	}))
	assert_equal(#requests, 1)
end

-- ── embedded raw identifier scrubbed from free-form fields ───────────────────

local function test_embedded_raw_id_scrubbed_from_wire()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit({
		-- an embedded raw id inside an exception reason must be blanked
		exception = { type = "lua_error", reason = "save failed for user_4242" },
		-- under the AGGRESSIVE scrub a value that mentions a token-boundary prefix
		-- ("user_id ...") is now ALSO blanked and dropped from the map; a value with
		-- no disallowed-prefix token survives
		metadata = { note = "user_id was unset", clean = "level load failed" },
		modules = {
			{ name = "libgame.so", debug_id = "ABC", load_address = "0x1000" },
		},
		threads = {
			{
				id = "main",
				crashed = true,
				frames = { { ["function"] = "game.tick", instruction_addr = "0xbb22" } },
			},
		},
	}))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "user_4242")
	-- the prefix-bearing prose value is now blanked (aggressive) and dropped
	assert_not_contains(body, '"note"')
	assert_not_contains(body, "user_id was unset")
	-- a value with no disallowed-prefix token still reaches the wire
	assert_contains(body, '"clean":"level load failed"')
end

-- ── dotted app version preserved (not blanked as IPv4) ───────────────────────

local function test_dotted_app_version_preserved_on_wire()
	reset()
	-- a 4-part version comes from the trusted config and must survive to the wire
	local client = assert(crash.new(config({ app_version = "1.2.3.4", app_build = "2024.6", sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event()))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_contains(body, '"version":"1.2.3.4"')
	assert_contains(body, '"build_id":"2024.6"')

	-- but an email/raw-id in the version field is still rejected (blanked + omitted)
	reset()
	local poisoned = assert(crash.new(config({ app_version = "build@example.com", sample_every = 1 })))
	assert_true(poisoned:emit(presymbolicated_event()))
	assert_equal(#requests, 1)
	assert_not_contains(requests[1].body, "build@example.com")
end

-- ── a raw-text-only fatal crash with a traceback is never dropped ────────────

local function test_raw_text_only_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A fatal crash reported as raw traceback text (no structured frames). The
	-- traceback line "main.script:42:" must NOT be mistaken for an IPv6 literal and
	-- blanked, which would otherwise leave the report with no frames AND no
	-- raw_text and get the FATAL crash rejected before the wire.
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "main.script:42: attempt to index nil" },
		raw_text = "main.script:42: attempt to index nil\n\tin function 'update'",
	})
	assert_equal(ok, true, "a raw-text-only fatal crash must not be dropped")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the traceback text survives verbatim (it carries no PII)
	assert_contains(body, "main.script:42: attempt to index nil")
	assert_equal(client:snapshot().dropped, 0, "the fatal crash must not be counted as dropped")

	-- LOAD-BEARING: a raw-text-only fatal whose trace is full of CODE SYMBOLS must
	-- survive. The native trace carries "::"-scoped symbols (Player::Update — a
	-- "::" that the loose IPv6 heuristic would misread as a literal), dotted class
	-- names (java.lang.RuntimeException), and dotted call paths (game.player.update
	-- — three dotted segments the loose dotted-token heuristic would blank). Under
	-- the full free-text scrub raw_text would be BLANKED, leaving the report with no
	-- frames AND no raw_text, dropping the FATAL crash. raw_text must use the
	-- STRUCTURED tier so these symbols survive.
	reset()
	local symbol_trace = "java.lang.RuntimeException: boom\n"
		.. "\tat Player::Update(player.cpp:42)\n"
		.. "\tat game.player.update(player.lua:7)"
	ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		raw_text = symbol_trace,
	})
	assert_equal(ok, true, "a raw-text-only fatal whose trace is code symbols must not be dropped")
	assert_equal(#requests, 1, "the symbol-bearing fatal crash must reach the wire")
	body = requests[1].body
	-- every code symbol survives verbatim (none is PII)
	assert_contains(body, "java.lang.RuntimeException")
	assert_contains(body, "Player::Update")
	assert_contains(body, "game.player.update")
	assert_equal(client:snapshot().dropped, 0, "the symbol-bearing fatal crash must not be dropped")

	-- LOAD-BEARING (redact-in-place): a raw-text-ONLY fatal whose trace MIXES PII with
	-- a code symbol must SEND with the PII redacted and the symbol preserved — it must
	-- NEVER be blanked-whole (which would fail frames_or_raw_text_required and DROP the
	-- fatal). The trace carries a raw actor id, an email, and an IPv4 alongside the
	-- "Player::Update" code symbol.
	reset()
	ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		raw_text = "login failed for user_alice at Player::Update (a@b.com 10.0.0.5)",
	})
	assert_equal(ok, true, "a raw-text-only fatal mixing PII with a code symbol must send")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	body = requests[1].body
	-- the PII substrings are gone
	assert_not_contains(body, "user_alice")
	assert_not_contains(body, "a@b.com")
	assert_not_contains(body, "10.0.0.5")
	-- the code symbol survives verbatim (the field was redacted in place, not blanked)
	assert_contains(body, "Player::Update")
	-- the surrounding prose survives too, proving an in-place redaction not a blank
	assert_contains(body, "login failed for")
	assert_equal(client:snapshot().dropped, 0, "a redacted raw-text-only fatal must not be dropped")

	-- MUTATION GUARD: a real email / IP / digit-bearing raw id / JWT / long opaque
	-- secret embedded in raw_text is STILL removed, even on a raw-text-ONLY fatal (no
	-- structured frame to fall back on). Each PII form is redacted in place while the
	-- crash still reaches the wire.
	reset()
	ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		raw_text = "owner alice@example.com from 10.0.0.5 user_4242\n"
			.. "token aaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbb.cccccccccccccccc\n"
			.. "key AKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLEXX",
	})
	assert_equal(ok, true, "a raw-text-only fatal carrying PII must still send (redacted)")
	assert_equal(#requests, 1)
	body = requests[1].body
	assert_not_contains(body, "alice@example.com")
	assert_not_contains(body, "10.0.0.5")
	assert_not_contains(body, "user_4242")
	assert_not_contains(body, "aaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbb.cccccccccccccccc")
	assert_not_contains(body, "AKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLEXX")
	assert_equal(client:snapshot().dropped, 0)

	-- a real JWT embedded in raw_text is redacted, the crash still sends
	reset()
	local jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
		.. "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ."
		.. "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
	ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		raw_text = "auth rejected token=" .. jwt .. " at game.player.update",
	})
	assert_equal(ok, true, "a raw-text-only fatal carrying a JWT must still send (redacted)")
	assert_equal(#requests, 1)
	body = requests[1].body
	assert_not_contains(body, jwt)
	assert_not_contains(body, "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ")
	-- the code symbol after it survives
	assert_contains(body, "game.player.update")
	assert_equal(client:snapshot().dropped, 0)

	-- PURE-SYMBOL raw_text is unchanged and sends (no PII, nothing to redact)
	reset()
	local pure_symbols = "java.lang.RuntimeException: boom\n"
		.. "\tat Player::Update(player.cpp:42)\n"
		.. "\tat game.player.update(player.lua:7)"
	ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		raw_text = pure_symbols,
	})
	assert_equal(ok, true, "a pure-symbol raw-text-only fatal must send unchanged")
	assert_equal(#requests, 1)
	body = requests[1].body
	assert_contains(body, "java.lang.RuntimeException")
	assert_contains(body, "Player::Update")
	assert_contains(body, "game.player.update")
	assert_equal(client:snapshot().dropped, 0)
end

-- ── a raw-text-only fatal carrying a log timestamp is NOT dropped ────────────

-- A fatal crash reported as raw traceback text whose only "colon run" is a plain
-- numeric log time ("12:34:56") must not have that time mistaken for an IPv6
-- literal and blanked — which would leave the report with no frames AND no
-- raw_text and drop the FATAL crash before the wire. A genuine IPv6 literal in
-- the same text IS still blanked.
local function test_timestamp_raw_text_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "crash at 12:34:56" },
		raw_text = "12:34:56 main.script:42: attempt to index nil\n\tin function 'update'",
	})
	assert_equal(ok, true, "a raw-text-only fatal carrying a log timestamp must not be dropped")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the timestamp + traceback survive verbatim (they carry no PII)
	assert_contains(body, "12:34:56")
	assert_contains(body, "main.script:42: attempt to index nil")
	assert_equal(client:snapshot().dropped, 0, "the fatal crash must not be counted as dropped")

	-- a GENUINE IPv6 literal in the raw text is still blanked; here the report keeps
	-- its structured frame so it is not dropped, and the IPv6 literal is gone.
	reset()
	assert_true(client:emit({
		exception = { type = "lua_error", reason = "boom" },
		raw_text = "connect fe80::1 failed",
		threads = {
			{ id = "main", crashed = true, frames = { { ["function"] = "game.tick" } } },
		},
	}))
	assert_equal(#requests, 1)
	assert_not_contains(requests[1].body, "fe80::1")
end

-- ── a manual frame function that is a normal code symbol is NOT dropped ──────

-- LOAD-BEARING fatal-safety test. A manually emitted FATAL crash whose only
-- frame identity is a normal dotted code symbol ("game.player.update") must reach
-- the wire. The bug: a manual frame function used to go through the full
-- free-text scrub, whose dotted-token heuristic blanked a three-segment symbol,
-- leaving the frame unidentified and dropping the whole FATAL crash. A frame
-- function is a CODE SYMBOL and must get the symbol-aware scrub, which preserves
-- the symbol while still stripping an embedded email/IP.
local function test_manual_frame_symbol_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A function-only frame (no address), so the frame's ONLY identity is the
	-- symbol: if it is blanked the frame is unidentified and the fatal is dropped.
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = { { ["function"] = "game.player.update", file = "game/player.lua", line = 7 } },
			},
		},
	})
	assert_equal(ok, true, "a manual fatal crash with a normal symbol frame must not be dropped")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the symbol survives verbatim on the wire (it is a code symbol, not free text)
	assert_contains(body, '"function":"game.player.update"')
	assert_equal(client:snapshot().dropped, 0, "the fatal crash must not be counted as dropped")

	-- A "::"-qualified symbol survives too (the "::" is scope resolution, NOT an
	-- IPv6 literal, so it must not be blanked).
	reset()
	ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = { { ["function"] = "Auth::user_id_from_token" } },
			},
		},
	})
	assert_equal(ok, true, "a fatal crash with a ::-qualified symbol frame must not be dropped")
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"function":"Auth::user_id_from_token"')
	assert_equal(client:snapshot().dropped, 0)

	-- MUTATION GUARD: a frame function carrying a genuine embedded email or IP is
	-- STILL blanked even though it is on the symbol tier. Here the frame also has a
	-- resolvable address + module map, so the report is NOT dropped — but the PII
	-- must be gone from the wire.
	reset()
	ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		modules = { { name = "libgame.so", debug_id = "ABC", load_address = "0x1000" } },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					{ ["function"] = "handler_for_alice@example.com", instruction_addr = "0xbb22" },
				},
			},
		},
	})
	assert_equal(ok, true)
	assert_equal(#requests, 1)
	local pii_body = requests[1].body
	assert_not_contains(pii_body, "alice@example.com")
	-- the blanked symbol is omitted (an empty function is dropped to nil)
	assert_not_contains(pii_body, '"function":"handler_for_alice')
end

-- ── a PII-only frame is dropped, the report is not, the clean frame ships ────

-- LOAD-BEARING fatal-safety. A FATAL crash whose stack mixes a frame whose ONLY
-- identity is a PII-bearing function (it scrubs to empty) with a later CLEAN frame
-- must NOT be rejected as frame_unidentified: the PII frame is dropped, the clean
-- frame ships, the crash reaches the wire, and the PII is absent.
local function test_pii_only_frame_dropped_clean_frame_ships()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					-- the only identity here is a function carrying an embedded email; it
					-- scrubs empty, so this frame is unidentified and must be DROPPED
					{ ["function"] = "handler_for_alice@example.com" },
					-- a later clean frame the report must still ship
					{ ["function"] = "game.player.update" },
				},
			},
		},
	})
	assert_equal(ok, true, "a fatal with one clean frame must ship when an earlier frame scrubs to PII")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the clean frame ships
	assert_contains(body, '"function":"game.player.update"')
	-- the PII is absent (the unidentified frame was dropped, not shipped blank)
	assert_not_contains(body, "alice@example.com")
	assert_not_contains(body, '"function":"handler_for_alice')
	assert_equal(client:snapshot().dropped, 0, "the fatal crash must not be counted as dropped")

	-- a PII-only frame paired with raw_text (no other frame) also ships: the frame is
	-- dropped, raw_text satisfies frames_or_raw_text_required.
	reset()
	ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		raw_text = "fatal in game.tick",
		threads = {
			{
				id = "main",
				crashed = true,
				frames = { { ["function"] = "handler_for_alice@example.com" } },
			},
		},
	})
	assert_equal(ok, true, "a fatal with raw_text must ship when its only frame scrubs to PII")
	assert_equal(#requests, 1)
	body = requests[1].body
	assert_contains(body, "fatal in game.tick")
	assert_not_contains(body, "alice@example.com")
	assert_equal(client:snapshot().dropped, 0)
end

-- ── a fatal with a bad per-event platform falls back to the configured one ───

-- LOAD-BEARING fatal-safety. A manual report whose per-event platform carries
-- disallowed content (a raw id, an email) scrubs to empty. Without a fallback the
-- report would fail platform_required and DROP even a fatal. The trusted,
-- init-validated config platform must be reapplied so the fatal reaches the wire.
local function test_bad_per_event_platform_falls_back_to_config()
	reset()
	local client = assert(crash.new(config({ sample_every = 1, platform = "html5" })))
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		platform = "user_4242",
		raw_text = "fatal in game.tick",
	})
	assert_equal(ok, true, "a fatal must not be dropped over a bad per-event platform")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the bad per-event platform is gone, the configured platform is on the wire
	assert_not_contains(body, "user_4242")
	assert_contains(body, '"platform":"html5"')
	assert_equal(client:snapshot().dropped, 0, "the fatal crash must not be counted as dropped")

	-- an email-bearing per-event platform falls back identically
	reset()
	ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		platform = "a@b.com",
		raw_text = "fatal in game.tick",
	})
	assert_equal(ok, true)
	assert_equal(#requests, 1)
	body = requests[1].body
	assert_not_contains(body, "a@b.com")
	assert_contains(body, '"platform":"html5"')
	assert_equal(client:snapshot().dropped, 0)
end

-- ── camelCase / kebab-case identity-key aliases are stripped from the wire ───

-- A clean (non-PII-prefixed) identity VALUE passes the value scrub, so the KEY
-- itself must be stripped. The strip must match case + separator aliases
-- (userId / user-id / USER_ID), not only snake_case, or a raw actor identifier
-- reaches the wire under an aliased key.
local function test_identity_key_aliases_stripped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event({
		context = {
			userId = "alice",
			sessionId = "0190b3c4-1234-7abc-89ab-0123456789ab",
			["anonymous-id"] = "anon-cleanvalue",
			DeviceId = "dev-1",
			-- a non-identity key with a clean value survives
			build_channel = "beta",
		},
	})))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "userId")
	assert_not_contains(body, "sessionId")
	assert_not_contains(body, "anonymous-id")
	assert_not_contains(body, "DeviceId")
	assert_not_contains(body, '"alice"')
	assert_not_contains(body, "0190b3c4-1234-7abc-89ab-0123456789ab")
	assert_not_contains(body, "anon-cleanvalue")
	assert_contains(body, '"build_channel":"beta"')
end

-- ── identity keys are stripped from the caller device map too ────────────────

-- The caller-populated device map must pass through the same identity-key strip
-- as context/metadata, or a raw actor identifier (device_id / user_id) reaches
-- the wire under device. A legitimate device.class is NOT an identity key and
-- survives.
local function test_device_identity_keys_stripped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event({
		device = {
			device_id = "dev-clean-123",
			user_id = "alice",
			userId = "bob",
			model = "Pixel 7",
			class = "phone",
		},
	})))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "device_id")
	assert_not_contains(body, '"user_id"')
	assert_not_contains(body, "userId")
	assert_not_contains(body, "dev-clean-123")
	assert_not_contains(body, '"alice"')
	assert_not_contains(body, '"bob"')
	-- non-identity device fields survive
	assert_contains(body, '"model":"Pixel 7"')
	assert_contains(body, '"class":"phone"')
end

-- ── a whitespace-padded identity key is still stripped from the wire ─────────

-- The identity-key strip normalizes a key (trim + lowercase + drop separators)
-- before matching. A whitespace-padded key like " user_id " (or " userId ") must
-- still be recognized as an identity key and stripped — otherwise the value scrub
-- never inspects the key, the map emits it as a trimmed "user_id", and a raw actor
-- identifier reaches the wire. A non-identity key with surrounding space survives
-- (trimmed) with its value.
local function test_padded_identity_key_stripped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event({
		context = {
			[" user_id "] = "alice",
			[" userId "] = "bob",
			-- a non-identity key with padding survives (its value is clean)
			[" build_channel "] = "beta",
		},
	})))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "user_id")
	assert_not_contains(body, "userId")
	assert_not_contains(body, '"alice"')
	assert_not_contains(body, '"bob"')
	assert_contains(body, '"build_channel":"beta"')
end

-- ── a code-symbol fingerprint component survives on the wire ─────────────────

-- A caller's fingerprint component is the grouping key and is typically a code
-- symbol (a package/class name like "java.lang.RuntimeException"). It must be
-- scrubbed with the structured tier so the dotted symbol survives — the full
-- free-text scrub would read it as a dotted token and blank it, silently dropping
-- the caller's grouping key. A real token / digit-bearing raw id / email in a
-- component is still removed.
local function test_symbol_fingerprint_component_survives_on_wire()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event({
		fingerprint_components = {
			"java.lang.RuntimeException",
			"com.company.game.Boss",
			-- a digit-bearing raw actor id is still blanked (dropped from the array)
			"user_4242",
		},
	})))
	assert_equal(#requests, 1)
	local body = requests[1].body
	-- the dotted code symbols survive as grouping keys
	assert_contains(body, "java.lang.RuntimeException")
	assert_contains(body, "com.company.game.Boss")
	-- the digit-bearing raw id is removed
	assert_not_contains(body, "user_4242")
end

-- ── a user-home path username leak is redacted on the wire ───────────────────

local function test_home_path_username_redacted_on_wire()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit({
		exception = { type = "lua_error", reason = "asset load failed: /Users/alice/game/level.lua" },
		raw_text = "stack:\n\t/home/bob/projects/app/src/main.lua:10",
		modules = { { name = "libgame.so", debug_id = "ABC", load_address = "0x1000" } },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = { { ["function"] = "callback in /Users/alice/x.lua", instruction_addr = "0xbb22" } },
			},
		},
	}))
	assert_equal(#requests, 1)
	local body = requests[1].body
	-- the OS account names must not reach the wire
	assert_not_contains(body, "alice")
	assert_not_contains(body, "bob")
	-- the rest of each path survives so the file location is still useful
	assert_contains(body, "/Users/<redacted>/game/level.lua")
	assert_contains(body, "/home/<redacted>/projects/app/src/main.lua")
end

-- ── a frame `file` path username is redacted on the wire ─────────────────────

-- A stack frame's `file` path leaks the OS account name the same way a free-text
-- field does. Its username segment must be redacted before the wire, keeping the
-- rest of the file location useful.
local function test_frame_file_path_username_redacted_on_wire()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit({
		exception = { type = "lua_error", reason = "boom" },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					{ ["function"] = "game.update", file = "/Users/alice/game/src/update.lua", line = 7 },
					{ ["function"] = "game.tick", file = [[C:\Users\Dave\game\tick.lua]], line = 3 },
				},
			},
		},
	}))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "alice")
	assert_not_contains(body, "Dave")
	assert_contains(body, "/Users/<redacted>/game/src/update.lua")
	assert_contains(body, [[C:\\Users\\<redacted>\\game\\tick.lua]])
end

-- ── a raw-text-only fatal carrying a non-email "@" is NOT dropped ────────────

-- LOAD-BEARING fatal-safety test. A fatal crash reported as raw traceback text
-- whose only "@" is a non-email token ("@file:///path", "module@0x1234") must NOT
-- have that text mistaken for an email and blanked — which would leave the report
-- with no frames AND no raw_text and DROP the FATAL crash before the wire. A
-- genuine email address in free text IS still blanked.
local function test_at_sign_raw_text_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- The traceback carries two non-email "@" tokens: an HTML5/file URL and an
	-- offset-into-module address. Neither is an email address shape (no dotted
	-- letters-only TLD after the "@"), so the raw text must survive verbatim.
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		raw_text = "trace:\n\t@file:///game/main.lua:10\n\tat module@0x1234",
	})
	assert_equal(ok, true, "a raw-text-only fatal with a non-email @ must not be dropped")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the non-email "@" tokens survive (they carry no PII)
	assert_contains(body, "@file:///game/main.lua:10")
	assert_contains(body, "module@0x1234")
	assert_equal(client:snapshot().dropped, 0, "the fatal crash must not be counted as dropped")

	-- MUTATION GUARD: a GENUINE email address in free text IS still blanked. Here
	-- the report keeps a structured frame so it is not dropped, and the email is
	-- gone from the wire.
	reset()
	assert_true(client:emit({
		exception = { type = "lua_error", reason = "login failed for alice@example.com" },
		threads = {
			{ id = "main", crashed = true, frames = { { ["function"] = "game.tick" } } },
		},
	}))
	assert_equal(#requests, 1)
	assert_not_contains(requests[1].body, "alice@example.com")
end

-- ── a native backtrace over the frame budget is TRUNCATED, not dropped ───────

-- LOAD-BEARING fatal-safety test. A stack-overflow / deep-recursion native crash
-- can carry far more frames than the per-report budget. Rejecting it would lose
-- the FATAL crash entirely (the one-shot native dump has already been consumed by
-- the time the report is assembled), so the frames must be TRUNCATED to the budget
-- — keeping the TOP frames, closest to the fault — and the fatal must still reach
-- the wire.
local function test_overlong_backtrace_truncated_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- Build a single thread with far more than the 256-frame budget. Each frame is a
	-- distinct, recognizable symbol so we can assert which end survived.
	local frames = {}
	for i = 1, 400 do
		frames[i] = { ["function"] = "frame_" .. i }
	end
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "stack overflow" },
		threads = { { id = "main", crashed = true, frames = frames } },
	})
	assert_equal(ok, true, "an over-budget native backtrace must be truncated, not dropped")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_equal(client:snapshot().dropped, 0, "the fatal crash must not be counted as dropped")
	local body = requests[1].body
	-- the TOP frames (nearest the fault) are kept...
	assert_contains(body, '"function":"frame_1"')
	assert_contains(body, '"function":"frame_256"')
	-- ...and the deep tail beyond the budget is dropped.
	assert_not_contains(body, '"function":"frame_257"')
	assert_not_contains(body, '"function":"frame_400"')
end

-- ── the accepted `address` frame alias is normalized to instruction_addr ──────

-- A native frame that supplies only the accepted `address` alias (no
-- instruction_addr) validates, but the server resolves instruction_addr. The
-- alias must be copied into instruction_addr before the wire so the frame is
-- resolvable; the bare alias key is dropped.
local function test_frame_address_alias_normalized()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit({
		exception = { type = "SIGSEGV" },
		modules = { { name = "libgame.so", debug_id = "ABC", load_address = "0x1000" } },
		threads = {
			{ id = "main", crashed = true, frames = { { address = "0xdeadbeef" } } },
		},
	}))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_contains(body, '"instruction_addr":"0xdeadbeef"')
	assert_not_contains(body, '"address":"0xdeadbeef"')

	-- when instruction_addr is already present, the alias does not overwrite it AND
	-- the stale alias is dropped from the wire — instruction_addr is canonical, so a
	-- second divergent (or even non-hex) address must never be left on the frame.
	reset()
	assert_true(client:emit({
		exception = { type = "SIGSEGV" },
		modules = { { name = "libgame.so", debug_id = "ABC", load_address = "0x1000" } },
		threads = {
			{ id = "main", crashed = true, frames = { { instruction_addr = "0x1111", address = "0x2222" } } },
		},
	}))
	assert_contains(requests[1].body, '"instruction_addr":"0x1111"')
	assert_not_contains(requests[1].body, '"address":"0x2222"')
	assert_not_contains(requests[1].body, "0x2222")
end

-- ── the crashed thread keeps its frames even when an earlier thread overruns ──

-- LOAD-BEARING. The per-report frame budget is shared across threads, but the
-- CRASHED thread carries the actionable stack and must be served FIRST. When an
-- earlier NON-crashed thread carries more than the whole budget, it must not
-- consume all of it and truncate the crashed thread to zero frames — that would
-- leave the report with no actionable stack.
local function test_crashed_thread_frames_prioritized()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- Thread order puts a huge NON-crashed thread first, the crashed thread second.
	local bg_frames = {}
	for i = 1, 400 do
		bg_frames[i] = { ["function"] = "bg_" .. i }
	end
	local crash_frames = {}
	for i = 1, 12 do
		crash_frames[i] = { ["function"] = "crash_" .. i }
	end
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		threads = {
			{ id = "0", crashed = false, frames = bg_frames },
			{ id = "1", crashed = true, frames = crash_frames },
		},
	})
	assert_equal(ok, true, "the fatal crash must not be dropped")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the crashed thread's actionable frames are all preserved...
	assert_contains(body, '"function":"crash_1"')
	assert_contains(body, '"function":"crash_12"')
	-- ...and the background thread is the one truncated (its top frames stay, its
	-- deep tail is dropped to make room).
	assert_contains(body, '"function":"bg_1"')
	assert_not_contains(body, '"function":"bg_400"')
	assert_equal(client:snapshot().dropped, 0)
end

-- ── app_id is operator scope: an actor-prefixed slug survives, real PII rejected ─

-- LOAD-BEARING. app_id is operator-set product scope, NOT a raw actor id. A
-- legitimate scope whose slug begins with an actor-style prefix ("user_app",
-- "customer_portal") must NOT be blanked at emit — blanking it fails
-- app_id_required and DROPS every report, including a FATAL. It is scrubbed with
-- the structured tier (so the scope survives) and validated at init time (so a
-- value that carries real PII is rejected up front, never reaching emit).
local function test_app_id_actor_prefix_scope_survives()
	reset()
	local client = assert(crash.new(config({ sample_every = 1, app_id = "user_app" })))
	-- a FATAL crash must reach the wire with the scope intact, not be dropped over it
	local ok = client:emit_fatal(presymbolicated_event())
	assert_equal(ok, true, "a fatal crash must not be dropped over an actor-prefixed app_id scope")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_contains(requests[1].body, '"id":"user_app"')
	assert_equal(client:snapshot().dropped, 0)

	-- a second actor-style scope (customer_portal) survives identically
	reset()
	local client2 = assert(crash.new(config({ sample_every = 1, app_id = "customer_portal" })))
	assert_true(client2:emit_fatal(presymbolicated_event()))
	assert_contains(requests[1].body, '"id":"customer_portal"')
end

-- App identity comes ONLY from the trusted client config. A caller-provided
-- event.app.id must be IGNORED and overridden with the configured app_id: the
-- crash key is scoped to the configured app, so a stale/mismatched per-report app
-- id would send under the wrong scope or be rejected.
local function test_caller_app_id_overridden_by_config()
	reset()
	local client = assert(crash.new(config({ sample_every = 1, app_id = "app-example" })))
	-- the caller tries to set a DIFFERENT app id on the event
	local ok = client:emit_fatal(presymbolicated_event({ app = { id = "some-other-app" } }))
	assert_equal(ok, true)
	assert_equal(#requests, 1)
	-- the configured scope wins; the caller value never reaches the wire
	assert_contains(requests[1].body, '"id":"app-example"')
	assert_not_contains(requests[1].body, "some-other-app")

	-- a caller app id carrying PII is likewise overridden (never sent, never used
	-- to drop the crash): the trusted config app_id is stamped instead
	reset()
	local ok2 = client:emit_fatal(presymbolicated_event({ app = { id = "user_4242" } }))
	assert_equal(ok2, true, "a fatal crash must not be dropped over a caller-provided app id")
	assert_contains(requests[1].body, '"id":"app-example"')
	assert_not_contains(requests[1].body, "user_4242")
end

-- A frame.index is a numeric position. A NON-NUMBER index (a string, possibly
-- PII) is schema-invalid and must never be JSON-encoded onto the wire: it is
-- treated as missing and replaced with the positional index.
local function test_non_number_frame_index_normalized()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal(presymbolicated_event({
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					{ ["function"] = "game.update", file = "game/update.lua", line = 42,
						index = "user_secret_index" },
				},
			},
		},
	}))
	assert_equal(ok, true, "a fatal crash must not be dropped over a bad frame index")
	assert_equal(#requests, 1)
	-- the PII string index never reaches the wire; the positional index is used
	assert_not_contains(requests[1].body, "user_secret_index")
	assert_contains(requests[1].body, '"index":0')
end

-- A numeric-but-invalid frame index (negative or fractional) is just as
-- schema-invalid as a non-number: it must be restamped to the positional index, not
-- shipped verbatim and not allowed to drop the fatal.
local function test_invalid_numeric_frame_index_normalized()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal(presymbolicated_event({
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					{ ["function"] = "game.boot", index = -1 },
					{ ["function"] = "game.update", index = 1.5 },
				},
			},
		},
	}))
	assert_equal(ok, true, "a fatal must not be dropped over a bad numeric frame index")
	assert_equal(#requests, 1)
	local body = requests[1].body
	-- positional indices were restamped; the invalid values never reach the wire
	assert_not_contains(body, '"index":-1')
	assert_not_contains(body, '"index":1.5')
	assert_contains(body, '"index":0')
	assert_contains(body, '"index":1')
end

-- A frame line number is meaningful only as a non-negative INTEGER. A fractional
-- value (42.5) is not a real line, so the optional field is dropped before encoding
-- (the same normalization frame.index gets), while a clean integer line survives.
-- A fatal is never dropped over a bad line.
local function test_fractional_frame_line_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal(presymbolicated_event({
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					-- fractional line: dropped from the wire
					{ ["function"] = "game.boot", line = 42.5 },
					-- clean integer line: kept
					{ ["function"] = "game.update", line = 17 },
				},
			},
		},
	}))
	assert_equal(ok, true, "a fatal must not be dropped over a fractional frame line")
	assert_equal(#requests, 1)
	local body = requests[1].body
	-- the fractional line is omitted; the clean integer line ships
	assert_not_contains(body, '"line":42.5')
	assert_not_contains(body, '"line":42')
	assert_contains(body, '"line":17')
end

-- More than the budget of fingerprint_components must be CAPPED to the limit, never
-- reject the whole fatal — it is only an optional grouping hint.
local function test_oversized_fingerprint_components_capped_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local components = {}
	for i = 1, 40 do
		components[i] = "group.part" .. i
	end
	local ok = client:emit_fatal(presymbolicated_event({
		fingerprint_components = components,
	}))
	assert_equal(ok, true, "an over-budget fingerprint hint must be capped, not drop the fatal")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_equal(client:snapshot().dropped, 0)
	local body = requests[1].body
	-- the leading components are kept; the tail beyond the budget (32) is dropped
	assert_contains(body, "group.part1")
	assert_contains(body, "group.part32")
	assert_not_contains(body, "group.part33")
	assert_not_contains(body, "group.part40")
end

-- A non-enum device.class is OPTIONAL metadata: the bad value must be dropped, never
-- reject the whole crash.
local function test_invalid_device_class_dropped_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal(presymbolicated_event({
		device = { class = "handheld", model = "pixel" },
	}))
	assert_equal(ok, true, "a fatal must not be dropped over a bad device.class")
	assert_equal(#requests, 1)
	local body = requests[1].body
	-- the bad class is dropped; other clean device metadata still ships
	assert_not_contains(body, "handheld")
	assert_contains(body, '"model":"pixel"')

	-- a valid class is preserved
	reset()
	assert_true(client:emit_fatal(presymbolicated_event({ device = { class = "phone" } })))
	assert_contains(requests[1].body, '"class":"phone"')
end

-- More than the budget of threads must be CAPPED to the limit, always KEEPING the
-- crashed thread, never reject the fatal with a thread overflow.
local function test_oversized_thread_list_capped_keeps_crashed_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local threads = {}
	-- 80 non-crashed background threads first (past the 64 budget), then the crashed
	-- thread last so a naive head-truncation would drop it.
	for i = 1, 80 do
		threads[i] = {
			id = "bg" .. i,
			frames = { { ["function"] = "bg.loop" } },
		}
	end
	threads[#threads + 1] = {
		id = "crasher",
		crashed = true,
		frames = { { ["function"] = "game.fault" } },
	}
	local ok = client:emit_fatal({
		exception = { type = "SIGSEGV", reason = "boom" },
		threads = threads,
	})
	assert_equal(ok, true, "an over-budget thread list must be capped, not drop the fatal")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_equal(client:snapshot().dropped, 0)
	local body = requests[1].body
	-- the crashed thread survived the cap and its actionable frame is present
	assert_contains(body, '"id":"crasher"')
	assert_contains(body, '"function":"game.fault"')
end

-- An unreferenced module whose required fields scrub empty must be DROPPED, not
-- reject the whole crash, when a clean module already covers the stack (or, as here,
-- the stack is pre-symbolicated and needs no module map).
local function test_invalid_module_entry_dropped_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal(presymbolicated_event({
		modules = {
			-- a clean module the stack does not need
			{ name = "libgame.so", debug_id = "GOODDBG", load_address = "0x1000" },
			-- a module whose debug_id and build_id are both absent: unusable, dropped
			{ name = "libbroken.so", load_address = "0x2000" },
		},
	}))
	assert_equal(ok, true, "an unusable module entry must not drop a pre-symbolicated fatal")
	assert_equal(#requests, 1)
	local body = requests[1].body
	-- the clean module survives; the broken one is dropped
	assert_contains(body, '"name":"libgame.so"')
	assert_not_contains(body, "libbroken.so")
end

-- When the ONLY module a native address frame references is dropped as invalid, that
-- frame's address path is dropped (the established missing-module outcome) but a
-- clean symbolic frame in the same stack still ships — the fatal is not lost.
local function test_dropped_referenced_module_drops_frame_address_keeps_clean_frame()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal({
		exception = { type = "SIGSEGV", reason = "boom" },
		modules = {
			-- invalid: missing both debug_id and build_id -> dropped
			{ name = "libnative.so", load_address = "0x4000" },
		},
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					-- references the dropped module by name: its address path is dropped,
					-- and with no function symbol the frame itself is dropped
					{ instruction_addr = "0x4abc", module_name = "libnative.so" },
					-- a clean symbolic frame survives so the fatal still ships
					{ ["function"] = "game.update" },
				},
			},
		},
	})
	assert_equal(ok, true, "a clean symbolic frame must keep the fatal alive")
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_contains(body, '"function":"game.update"')
	-- the unresolvable address whose module was dropped is not shipped
	assert_not_contains(body, "0x4abc")
end

-- A native address frame with NO module map at all (none supplied) cannot be
-- resolved: its address is dropped and, with no function symbol, the frame is
-- dropped too — but a clean symbolic sibling frame in the same stack still ships,
-- so the fatal is NOT lost over the unresolvable optional address.
local function test_unresolvable_address_frame_dropped_clean_sibling_keeps_fatal()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal({
		exception = { type = "SIGSEGV", reason = "boom" },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					-- a clean symbolic frame
					{ ["function"] = "game.update" },
					-- a bare native address with no module map to resolve against
					{ instruction_addr = "0xdeadbeef" },
				},
			},
		},
	})
	assert_equal(ok, true, "a clean symbolic frame must keep the fatal alive")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_equal(client:snapshot().dropped, 0)
	local body = requests[1].body
	assert_contains(body, '"function":"game.update"')
	-- the unresolvable address is not shipped
	assert_not_contains(body, "0xdeadbeef")
end

-- FATAL-SAFETY: the frame budget is enforced AFTER the address-only frames that
-- will not ship are dropped. A fatal whose crashed thread leads with more than the
-- frame budget of address-only frames that reference a module which gets filtered
-- out — followed by clean symbolic frames PAST the budget — must not spend the
-- budget on the doomed address frames (truncating the clean tail) and then drop
-- those addresses, leaving zero usable frames and dropping the fatal. The clean
-- symbolic tail frames must survive.
local function test_address_frames_for_filtered_module_dropped_before_budget()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local frames = {}
	-- 256 (== the frame budget) address-only frames into a module that is dropped as
	-- invalid (no debug_id/build_id), so each frame's address path is cleared and the
	-- frame itself is dropped.
	for i = 1, 256 do
		frames[i] = { instruction_addr = "0x4abc", module_name = "libbroken.so" }
	end
	-- clean symbolic frames PAST the budget that must survive
	frames[#frames + 1] = { ["function"] = "game.clean_a" }
	frames[#frames + 1] = { ["function"] = "game.clean_b" }
	local ok = client:emit_fatal({
		exception = { type = "SIGSEGV", reason = "boom" },
		modules = {
			-- referenced-but-invalid: both ids absent -> dropped, taking the address
			-- path of every frame that references it
			{ name = "libbroken.so", load_address = "0x4000" },
		},
		threads = { { id = "main", crashed = true, frames = frames } },
	})
	assert_equal(ok, true,
		"a fatal with clean symbolic frames past the budget must not be dropped")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_equal(client:snapshot().dropped, 0)
	local body = requests[1].body
	-- the clean tail frames (which sat past the budget behind the doomed address
	-- frames) survive
	assert_contains(body, '"function":"game.clean_a"')
	assert_contains(body, '"function":"game.clean_b"')
	-- the doomed address frames did not ship
	assert_not_contains(body, "0x4abc")
end

-- An app_id that carries REAL PII (an email, an IP, a digit-bearing raw actor id,
-- a token) is rejected at crash.new() with a clear config error — surfaced at init
-- time, never silently dropping reports later.
local function test_config_app_id_rejects_pii()
	local cases = {
		"ops@example.com",
		"10.0.0.5",
		"user_4242",
		"aaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbb.cccccccccccccccc",
	}
	for _, bad in ipairs(cases) do
		local client, err = crash.new(config({ app_id = bad }))
		assert_equal(client, nil, "a PII-bearing app_id must be rejected at init: " .. bad)
		assert_equal(err, "invalid_app_id", "the reject reason is a clear config error: " .. bad)
	end
	-- a digit-free actor-prefixed scope is NOT PII and is accepted
	assert_true(crash.new(config({ app_id = "user_app" })), "an actor-prefixed scope must be accepted")
end

-- ── platform must be resolvable at init, not deferred to a failing emit ──────

-- When config.platform is omitted AND auto-detection cannot identify the runtime
-- (platform.detect() returns nil), crash.new() must fail with a clear config error
-- instead of returning a client whose every emit fails platform_required.
local function test_platform_required_at_init()
	-- Force detection to fail: an unmapped system_name yields nil from detect().
	local saved = sys.get_sys_info
	sys.get_sys_info = function()
		return { system_name = "PlanScape" }
	end
	local client, err = crash.new(config({ platform = nil }))
	sys.get_sys_info = saved
	assert_equal(client, nil, "crash.new must fail when no platform can be resolved")
	assert_equal(err, "platform_required", "the failure is a clear config error")

	-- an explicit config.platform is honored even when detection would fail
	sys.get_sys_info = function()
		return { system_name = "PlanScape" }
	end
	local ok_client = crash.new(config({ platform = "ios" }))
	sys.get_sys_info = saved
	assert_true(ok_client, "an explicit platform must be accepted regardless of detection")

	-- an explicitly-set platform that carries PII/invalid content is non-empty (so
	-- it passes the bare non-empty check) but scrubs to EMPTY on every emit — which
	-- would make every report, including a fatal, fail platform_required. crash.new()
	-- must reject the SANITIZED platform at init rather than hand back a client that
	-- can never send.
	for _, bad in ipairs({ "user_123", "ops@example.com", "10.0.0.5" }) do
		local client_bad, err_bad = crash.new(config({ platform = bad }))
		assert_equal(client_bad, nil, "a PII/invalid platform must be rejected at init: " .. bad)
		assert_equal(err_bad, "platform_required",
			"the reject reason is a clear config error: " .. bad)
	end
end

-- ── a per-report source that scrubs invalid: rejected (non-fatal) / omitted (fatal)

-- A per-report `source` that is non-empty but carries disallowed content scrubs to
-- empty. It must NOT silently become a bare-app report: a non-fatal emit() is
-- REJECTED with invalid_source, while emit_fatal() OMITS the source and STILL
-- SENDS (a fatal crash is never dropped over a bad source).
local function test_per_report_invalid_scrubbed_source()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))

	-- non-fatal: a source carrying a raw identifier is rejected
	local ok, err = client:emit(presymbolicated_event({ source = "user_123" }))
	assert_equal(ok, false)
	assert_equal(err, "invalid_source")
	assert_equal(#requests, 0)
	assert_equal(client:snapshot().dropped, 1)

	-- non-fatal: a source carrying an email is likewise rejected
	reset()
	local ok2, err2 = client:emit(presymbolicated_event({ source = "ops@example.com" }))
	assert_equal(ok2, false)
	assert_equal(err2, "invalid_source")
	assert_equal(#requests, 0)

	-- FATAL: the same bad source is OMITTED and the crash still reaches the wire
	reset()
	assert_true(client:emit_fatal(presymbolicated_event({ source = "user_123" })),
		"a fatal crash must never be dropped over a bad source")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the bad source is omitted entirely (no PII, no bogus slug on the wire)
	assert_not_contains(body, "user_123")
	assert_not_contains(body, '"source"')
	assert_not_contains(body, "ops@example.com")
end

-- A VALID component slug that is long (up to the 63-char limit) is made only of
-- lowercase letters, digits, and hyphens — no "@"/dot/underscore — so it is SAFE
-- BY CONSTRUCTION and must survive verbatim. The free-text scrub's long-opaque-run
-- rule (40+ char dotless run) would otherwise blank it, wrongly rejecting a
-- non-fatal report and silently dropping the source dimension from a fatal. This
-- must hold for BOTH a per-report source and the configured default.
local function test_long_valid_slug_source_preserved()
	-- a 50-char valid slug: leading alnum then hyphen/alnum, all lowercase
	local long_slug = "a" .. string.rep("b", 24) .. "-" .. string.rep("c", 24)
	assert_equal(#long_slug, 50)
	assert_equal(event_mod.valid_source(long_slug), true, "the fixture is a valid slug")

	-- per-report, non-fatal: the long valid slug is NOT rejected and reaches the wire
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok, err = client:emit(presymbolicated_event({ source = long_slug }))
	assert_equal(ok, true, "a valid long slug source must not be rejected: " .. tostring(err))
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"source":"' .. long_slug .. '"')

	-- per-report, FATAL: the long valid slug survives (the source dimension is NOT
	-- silently lost from a fatal)
	reset()
	assert_true(client:emit_fatal(presymbolicated_event({ source = long_slug })),
		"a fatal must keep a valid long slug source")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_contains(requests[1].body, '"source":"' .. long_slug .. '"')

	-- config-default: the same long slug stamped from config survives on every report
	reset()
	local client2 = assert(crash.new(config({ crash_source = long_slug, sample_every = 1 })))
	assert_true(client2:emit(presymbolicated_event()))
	assert_equal(#requests, 1)
	assert_contains(requests[1].body, '"source":"' .. long_slug .. '"')

	-- MUTATION GUARD: a same-length value that is NOT a valid slug (it carries an
	-- email) must still be rejected for a non-fatal report — the keep-valid path must
	-- not become a blanket keep-everything path.
	reset()
	local bad = "ops@" .. string.rep("c", 42) .. ".com"
	assert_equal(event_mod.valid_source(bad), false, "the negative fixture is not a valid slug")
	local ok3, err3 = client:emit(presymbolicated_event({ source = bad }))
	assert_equal(ok3, false, "a non-slug PII-bearing source must still be rejected")
	assert_equal(err3, "invalid_source")
	assert_equal(#requests, 0)
end

-- ── one-shot dump persists on a retryable failure and resends next launch ─────

-- A fake sys persistence layer (mirrors shardpilot/storage.lua's contract) so the
-- pending-crash sidecar exercises the real on-disk path, not just the memory
-- fallback.
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

-- The dump-sourced report is persisted BEFORE dispatch, so it survives even an
-- app kill during the in-flight window (before the send callback fires). It is
-- cleared only once the send is accepted (or terminally rejected).
local function test_dump_persisted_before_dispatch()
	reset()
	storage.reset()
	local restore = install_fake_sys_storage()

	-- A transport that holds its callback simulates the real async http path: the
	-- POST is dispatched but has not completed yet.
	local held_callback = nil
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		held_callback = function()
			callback(nil, nil, { status = 202, response = '{"crash_id":"x"}' })
		end
	end

	local client = assert(crash.new(config({ app_id = "inflight-app", sample_every = 1 })))
	local ok, sent = client:capture_previous(fake_crash_module({
		handle = 9,
		signum = 11,
		os_name = "Android",
		modules = { { name = "libgame.so", address = 0x1000 } },
		backtrace = { { address = 0x1abc } },
	}))
	assert_equal(ok, true)
	assert_equal(sent, true)
	assert_equal(#requests, 1, "the dump was dispatched")

	-- BEFORE the callback fires (the in-flight window): the report is already
	-- persisted, so an app kill here would not lose it. The persisted payload
	-- is the exact ENCODED wire body — the same bytes that were dispatched.
	local in_flight = storage.load_pending_crashes({ app_id = "inflight-app" })
	assert_equal(#in_flight, 1, "the dump report must be persisted before its send completes")
	assert_contains(in_flight[1], '"instruction_addr":"0x1abc"')
	assert_equal(in_flight[1], requests[1].body, "the persisted body is byte-identical to the dispatched one")

	-- The runtime delivers the accept callback; the persisted copy is now cleared.
	held_callback()
	assert_equal(client:snapshot().accepted, 1)
	local after_accept = storage.load_pending_crashes({ app_id = "inflight-app" })
	assert_equal(#after_accept, 0, "an accepted send clears the pre-dispatch persisted copy")

	http.request = saved_request
	restore()
	storage.reset()
end

local function test_dump_retryable_failure_persists_and_resends()
	reset()
	storage.reset()
	local restore = install_fake_sys_storage()

	local function fresh_dump_module()
		return fake_crash_module({
			handle = 9,
			signum = 11,
			os_name = "Android",
			os_version = "14",
			modules = { { name = "libgame.so", address = 0x1000 } },
			backtrace = { { address = 0x1abc } },
		})
	end

	-- LAUNCH 1: the server is unreachable (status 0 == retryable). The dump is
	-- consumed on read, so the prepared report MUST be persisted, not dropped.
	next_status = 0
	local client = assert(crash.new(config({ app_id = "persist-app", sample_every = 1 })))
	local ok, sent = client:capture_previous(fresh_dump_module())
	assert_equal(ok, true)
	assert_equal(sent, true, "the dump was dispatched")
	assert_equal(#requests, 1, "one POST attempted on launch 1")
	assert_equal(client:snapshot().accepted or 0, 0, "the retryable send was not accepted")
	local pending = storage.load_pending_crashes({ app_id = "persist-app" })
	assert_equal(#pending, 1, "a retryable failure of a dump report must persist it")

	-- LAUNCH 2: now the server accepts (202). capture_previous resends the
	-- persisted report (even though there is no NEW dump), it is accepted, and the
	-- pending list is cleared.
	reset()
	next_status = 202
	local client2 = assert(crash.new(config({ app_id = "persist-app", sample_every = 1 })))
	-- no new native dump this launch
	local ok2, sent2 = client2:capture_previous(fake_crash_module({ handle = nil }))
	assert_equal(ok2, true)
	assert_equal(sent2, false, "no NEW dump on launch 2")
	assert_equal(#requests, 1, "the persisted report is resent on launch 2")
	-- the resent body carries the real native crash (the persisted prepared report),
	-- not an empty placeholder
	assert_contains(requests[1].body, '"type":"SIGSEGV"')
	assert_contains(requests[1].body, '"instruction_addr":"0x1abc"')
	assert_equal(client2:snapshot().accepted, 1, "the resend was accepted")
	local cleared = storage.load_pending_crashes({ app_id = "persist-app" })
	assert_equal(#cleared, 0, "an accepted resend clears the persisted report")

	-- a DIFFERENT app on the same device must NOT see persist-app's pending queue
	assert_equal(#storage.load_pending_crashes({ app_id = "other-app" }), 0,
		"pending crashes must be isolated per app")

	restore()
	storage.reset()
end

-- A non-retryable reject (a 4xx other than rate-limit) of a dump report is
-- terminal: it is NOT persisted for retry.
local function test_dump_non_retryable_reject_not_persisted()
	reset()
	storage.reset()
	local restore = install_fake_sys_storage()

	next_status = 400
	local client = assert(crash.new(config({ app_id = "terminal-app", sample_every = 1 })))
	local ok, sent = client:capture_previous(fake_crash_module({
		handle = 5,
		signum = 6,
		modules = { { name = "libgame.so", address = 0x2000 } },
		backtrace = { { address = 0x2abc } },
	}))
	assert_equal(ok, true)
	assert_equal(sent, true)
	assert_equal(#requests, 1)
	local pending = storage.load_pending_crashes({ app_id = "terminal-app" })
	assert_equal(#pending, 0, "a terminal 4xx reject must NOT persist the report")

	restore()
	storage.reset()
end

-- A pending-store entry in the current shape: an encoded wire body carrying a
-- recognizable tag, plus its crash_id and fatal flag (storage-unit tests build
-- these directly; the client builds them from a prepared report).
local function pending_body_entry(tag, options)
	options = options or {}
	local body = options.body or ('{"crash_id":"' .. tag .. '","exception":{"type":"' .. tag .. '"}}')
	return { body = body, crash_id = tag, fatal = options.fatal ~= false }
end

-- Two pending entries persisted in the same process must carry DISTINCT tokens,
-- so removing one never deletes the other. The token includes a random suffix and
-- save_pending_crash re-mints on any clash, so even a forced same-time /
-- same-random collision (which a same-second app restart can otherwise produce,
-- resetting the counter and repeating os.time()) cannot make two live entries
-- share a token.
local function test_pending_tokens_unique_under_forced_collision()
	reset()
	storage.reset()
	local restore = install_fake_sys_storage()

	-- Force the volatile token inputs to constants: os.time() pinned and
	-- math.random() always returning the same value. The only thing left varying is
	-- the existence-check re-mint loop and the per-process counter — which is
	-- exactly what must keep the tokens apart.
	local saved_time = os.time
	local saved_random = math.random
	os.time = function()
		return 1700000000
	end
	math.random = function()
		return 7
	end

	local scope = { app_id = "collide-app" }
	local token1 = storage.save_pending_crash(scope, pending_body_entry("A"))
	local token2 = storage.save_pending_crash(scope, pending_body_entry("B"))

	os.time = saved_time
	math.random = saved_random

	assert_true(type(token1) == "string", "first persist returns a token")
	assert_true(type(token2) == "string", "second persist returns a token")
	assert_not_equal(token1, token2,
		"two live pending entries must never share a token even under forced collision")

	-- Removing the FIRST token must leave the SECOND entry intact (proving the
	-- collision could not delete the wrong report).
	storage.remove_pending_crash(scope, token1)
	local entries = storage.load_pending_entries(scope)
	assert_equal(#entries, 1, "removing one token must leave the other entry")
	assert_equal(entries[1].token, token2, "the surviving entry is the one NOT removed")
	assert_contains(entries[1].body, '"B"')

	restore()
	storage.reset()
end

-- When durable persistence exists but the write FAILS (e.g. disk quota), the
-- in-memory pending list must NOT be updated and no removable token returned. A
-- later capture_previous() memory-fallback must not then resurface a crash that
-- the failed write would have settled.
local function test_failed_durable_write_does_not_update_memory()
	reset()
	storage.reset()
	local saved_get = sys.get_save_file
	local saved_save = sys.save
	local saved_load = sys.load
	local stores = {}
	sys.get_save_file = function(application_id, file_name)
		return application_id .. "/" .. file_name
	end
	-- Durable backend present, but every write fails (quota / read-only disk).
	sys.save = function()
		return false
	end
	sys.load = function(path)
		return stores[path]
	end

	local scope = { app_id = "quota-app" }
	local token = storage.save_pending_crash(scope, pending_body_entry("X"))
	assert_equal(token, nil, "a failed durable write must not return a removable token")
	-- The in-memory list must remain empty so a later memory-fallback cannot resend.
	assert_equal(#storage.load_pending_crashes(scope), 0,
		"a failed durable write must NOT leave the report in the in-memory list")

	sys.get_save_file = saved_get
	sys.save = saved_save
	sys.load = saved_load
	storage.reset()
end

-- The count bound alone does not guarantee the serialized pending list fits the
-- durable store's per-file limit. When a write fails because the list is too large
-- to serialize, the oldest entries must be evicted one at a time and the write
-- retried until it succeeds — so the NEWEST report (the one being saved) is always
-- persistable and therefore returns a removable token, instead of being lost.
local function test_oversized_pending_list_evicts_until_write_succeeds()
	reset()
	storage.reset()
	local saved_get = sys.get_save_file
	local saved_save = sys.save
	local saved_load = sys.load
	local stores = {}
	sys.get_save_file = function(application_id, file_name)
		return application_id .. "/" .. file_name
	end
	-- Model a backend with a small per-file serialized-size limit: count the string
	-- bytes of the record tree and reject a write above the cap, exactly as the real
	-- durable store would reject an oversized table.
	local max_serialized_bytes = 20000
	local function record_bytes(value, depth)
		if depth > 32 then
			return 0
		end
		local total = 0
		if type(value) == "string" then
			total = #value
		elseif type(value) == "table" then
			for key, child in pairs(value) do
				if type(key) == "string" then
					total = total + #key
				end
				total = total + record_bytes(child, depth + 1)
			end
		end
		return total
	end
	sys.save = function(path, record)
		if record_bytes(record, 0) > max_serialized_bytes then
			return false
		end
		stores[path] = record
		return true
	end
	sys.load = function(path)
		return stores[path]
	end

	local scope = { app_id = "bigsidecar-app" }
	-- A large-but-individually-allowed body (under the per-record byte cap, so it
	-- is accepted by save_pending_crash, but several together overflow the list).
	local function big_entry(tag)
		return pending_body_entry(tag,
			{ body = '{"crash_id":"' .. tag .. '","blob":"' .. string.rep("x", 8000) .. '"}' })
	end

	-- Persist several reports. Each new save must succeed (return a token) by
	-- evicting older entries so the serialized list fits, never losing the newest.
	local last_token
	for i = 1, 5 do
		last_token = storage.save_pending_crash(scope, big_entry("R" .. i))
		assert_true(last_token ~= nil,
			"each pending save must persist the newest report by evicting older entries")
	end

	-- The newest report is present and removable by its token.
	local entries = storage.load_pending_entries(scope)
	assert_true(#entries >= 1, "at least the newest report must be persisted")
	local removed = storage.remove_pending_crash(scope, last_token)
	assert_equal(removed, true, "the newest persisted report must be removable by its token")

	sys.get_save_file = saved_get
	sys.save = saved_save
	sys.load = saved_load
	storage.reset()
end

-- Persistence degrades safely to a no-op when the host has no sys persistence
-- API (a plain Lua host / test harness without sys.save): the report is held in
-- memory for the process and the resend path still works without raising.
local function test_pending_persistence_safe_without_sys_api()
	reset()
	storage.reset()
	-- no fake sys storage installed: sys.save/load/get_save_file are absent here
	next_status = 0
	local client = assert(crash.new(config({ app_id = "no-disk-app", sample_every = 1 })))
	local ok = client:capture_previous(fake_crash_module({
		handle = 3,
		signum = 11,
		modules = { { name = "libgame.so", address = 0x3000 } },
		backtrace = { { address = 0x3abc } },
	}))
	assert_equal(ok, true, "capture_previous must not raise without sys persistence")
	-- Without a durable backend the save must NOT claim durability: no
	-- storage-side pending entry, an honest persist_failed count, and the
	-- report retained in the CLIENT's session-only memory fallback (so an
	-- in-session resend can still retry it).
	assert_equal(#storage.load_pending_crashes({ app_id = "no-disk-app" }), 0,
		"a process-local table is never counted as write-ahead durability")
	local snap = client:snapshot()
	assert_equal(snap.persisted, 0, "nothing was durably persisted")
	assert_equal(snap.persist_failed, 1, "the failed persist is surfaced honestly")
	local mem_count = 0
	for _ in pairs(client.in_memory_pending) do
		mem_count = mem_count + 1
	end
	assert_equal(mem_count, 1, "the report is retained in the session-only fallback")
	storage.reset()
end

-- A pending crash report older than the retention TTL (~7 days) is discarded on
-- read rather than resent. The created-at stamp is overridable for the test.
local function test_pending_ttl_discards_stale_report()
	reset()
	storage.reset()
	local restore = install_fake_sys_storage()

	local scope = { app_id = "ttl-app" }
	local seven_days_ms = 7 * 24 * 60 * 60 * 1000
	local clock = require "shardpilot.clock"

	-- A report stamped well over the TTL ago (relative to the SDK clock's "now").
	local stale_token = storage.save_pending_crash(scope, pending_body_entry("STALE"),
		nil, clock.unix_ms() - (seven_days_ms + 60000))
	assert_true(type(stale_token) == "string", "the stale report was persisted")
	-- On read it is discarded as a stale retry.
	assert_equal(#storage.load_pending_crashes(scope), 0,
		"a pending report older than the TTL must be discarded on read")

	-- A freshly stamped report (created just now) is NOT discarded.
	local fresh_token = storage.save_pending_crash(scope, pending_body_entry("FRESH"))
	assert_true(type(fresh_token) == "string", "the fresh report was persisted")
	local pending = storage.load_pending_crashes(scope)
	assert_equal(#pending, 1, "a fresh pending report must survive the TTL check")
	assert_contains(pending[1], '"FRESH"')

	-- A report stamped just inside the TTL window survives; just past it does not.
	-- Distinct app scopes so neither sub-case sees the earlier reports on disk.
	local now = clock.unix_ms()
	local within_scope = { app_id = "ttl-within-app" }
	-- a 10-minute margin inside the window absorbs the test clock's per-call drift
	local within = storage.save_pending_crash(within_scope, pending_body_entry("WITHIN"),
		nil, now - (seven_days_ms - 600000))
	assert_true(type(within) == "string")
	assert_equal(#storage.load_pending_crashes(within_scope), 1, "a report within the TTL window survives")
	local past_scope = { app_id = "ttl-past-app" }
	local just_past = storage.save_pending_crash(past_scope, pending_body_entry("PAST"),
		nil, now - (seven_days_ms + 60000))
	assert_true(type(just_past) == "string")
	assert_equal(#storage.load_pending_crashes(past_scope), 0, "a report just past the TTL window is discarded")

	restore()
	storage.reset()
end

-- A legacy bare-record entry (a prepared report written with no { token } wrapper
-- by an older build) is adopted with a freshly minted token that is WRITTEN BACK,
-- so a later read returns the SAME token and remove_pending_crash can settle it. A
-- read that minted a different token each time would never match and resend forever.
local function test_legacy_bare_record_token_persisted()
	reset()
	storage.reset()
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

	local scope = { app_id = "legacy-app" }
	-- Seed the on-disk store with a BARE legacy entry: items[1] is the prepared
	-- report itself, with no { token, report } wrapper. The pending namespace carries
	-- a short hash of the raw app id so two app ids that sanitize to the same slug
	-- still get distinct sidecars; "631b4e26" is that hash for "legacy-app".
	local ns = "shardpilot.legacy-app.631b4e26.pending-crashes"
	stores[ns .. "/identity"] = { items = { { exception = { type = "LEGACY" } } } }

	-- First read adopts a token and writes it back.
	local entries1 = storage.load_pending_entries(scope)
	assert_equal(#entries1, 1, "the legacy bare report is adopted")
	local token1 = entries1[1].token
	assert_true(type(token1) == "string", "the adopted entry has a token")
	assert_equal(entries1[1].report.exception.type, "LEGACY")

	-- A SECOND read must return the SAME token (it was persisted, not re-minted).
	local entries2 = storage.load_pending_entries(scope)
	assert_equal(#entries2, 1)
	assert_equal(entries2[1].token, token1,
		"a re-read must return the persisted token, not a freshly minted one")

	-- Removing by that token actually settles the entry (no endless resend).
	assert_true(storage.remove_pending_crash(scope, token1))
	assert_equal(#storage.load_pending_entries(scope), 0,
		"removing by the adopted token must settle the legacy entry")

	sys.get_save_file = saved_get
	sys.save = saved_save
	sys.load = saved_load
	storage.reset()
end

-- ── dotted identity-key aliases are stripped from the wire ───────────────────

-- A dotted identity-key alias ("user.id", "session.id") names the same raw actor
-- correlation key as user_id / session_id under a different separator. The key
-- normalizer must collapse the dot too, or a clean (scrub-passing) value reaches the
-- wire under a dotted key the value scrub never inspects. A non-identity dotted key
-- like "build.channel" is NOT an identity name after collapsing and must survive.
local function test_dotted_identity_key_aliases_stripped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event({
		context = {
			["user.id"] = "alice",
			["session.id"] = "0190b3c4-1234-7abc-89ab-0123456789ab",
			["device.id"] = "dev-clean-1",
			-- a non-identity dotted key with a clean value survives
			["build.channel"] = "beta",
		},
		metadata = {
			["player.id"] = "p-77",
		},
	})))
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, "user.id")
	assert_not_contains(body, "session.id")
	assert_not_contains(body, "device.id")
	assert_not_contains(body, "player.id")
	assert_not_contains(body, '"alice"')
	assert_not_contains(body, "0190b3c4-1234-7abc-89ab-0123456789ab")
	assert_not_contains(body, "dev-clean-1")
	assert_not_contains(body, "p-77")
	-- the non-identity dotted key survives
	assert_contains(body, '"build.channel":"beta"')
end

-- ── a non-boolean thread.crashed never reaches the wire as truthy ────────────

-- A caller-supplied thread.crashed that is not a boolean (a string "false", or an
-- accidental raw id) must be coerced to a strict boolean before encoding: a truthy
-- string would otherwise mark the wrong thread as crashed AND ship the raw value in
-- the crashed field.
local function test_non_boolean_thread_crashed_normalized()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- Thread 0 carries crashed="false" (a truthy string); thread 1 is the real
	-- boolean-crashed thread. The string must not win the crashed selection and must
	-- not reach the wire.
	assert_true(client:emit({
		exception = { type = "lua_error", reason = "boom" },
		threads = {
			{ id = "bg", crashed = "false", frames = { { ["function"] = "bg.tick" } } },
			{ id = "main", crashed = true, frames = { { ["function"] = "game.update" } } },
		},
	}))
	assert_equal(#requests, 1)
	local body = requests[1].body
	-- the raw string is never on the wire
	assert_not_contains(body, '"crashed":"false"')
	assert_not_contains(body, '"false"')
	-- the boolean-crashed thread is the one identified
	assert_contains(body, '"crashed_thread_id":"main"')

	-- an accidental raw id in crashed is likewise coerced away (never shipped verbatim)
	reset()
	assert_true(client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		threads = {
			{ id = "main", crashed = "user_4242", frames = { { ["function"] = "game.update" } } },
		},
	}))
	assert_equal(#requests, 1)
	body = requests[1].body
	assert_not_contains(body, "user_4242")
	-- a single-thread fatal still gets a crashed thread defaulted (boolean true)
	assert_contains(body, '"crashed":true')
end

-- ── a thread id that scrubs to PII is re-defaulted, never dropping a fatal ────

-- LOAD-BEARING fatal-safety. A thread id carrying disallowed content ("user_123")
-- scrubs to empty. Without a re-defaulted positional id the otherwise-clean fatal
-- would fail thread_id_required and be DROPPED. The positional default must be
-- reassigned AND the crashed-thread pointer repointed to it.
local function test_thread_id_pii_redefaulted_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom", crashed_thread_id = "user_123" },
		threads = {
			{ id = "user_123", crashed = true, frames = { { ["function"] = "game.update" } } },
		},
	})
	assert_equal(ok, true, "a fatal must not be dropped over a thread id that scrubs to PII")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_equal(client:snapshot().dropped, 0, "the fatal crash must not be counted as dropped")
	local body = requests[1].body
	-- the raw id is gone from both the thread id and the crashed-thread pointer
	assert_not_contains(body, "user_123")
	-- the positional default id is on the wire and the crashed pointer references it
	assert_contains(body, '"id":"0"')
	assert_contains(body, '"crashed_thread_id":"0"')
	-- the clean frame still ships
	assert_contains(body, '"function":"game.update"')
end

-- ── PII frames are dropped BEFORE the frame budget is enforced ───────────────

-- LOAD-BEARING fatal-safety. For an over-budget stack whose TOP frames scrub away
-- (PII-only) while later frames are clean, enforcing the budget BEFORE the scrub
-- would truncate the clean tail off and could leave the report with no usable stack
-- (dropping the fatal). The scrub must drop the PII frames first so the budget is
-- spent on the frames that actually ship.
local function test_pii_frames_dropped_before_frame_budget()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- Build a stack that exceeds the 256-frame budget: the first 256 frames are
	-- PII-only (an embedded email, so they scrub empty and are dropped), followed by
	-- clean frames that must survive.
	local frames = {}
	for i = 1, 256 do
		frames[i] = { ["function"] = "leak_for_alice@example.com" }
	end
	frames[#frames + 1] = { ["function"] = "game.clean_frame_a" }
	frames[#frames + 1] = { ["function"] = "game.clean_frame_b" }
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "stack overflow" },
		threads = { { id = "main", crashed = true, frames = frames } },
	})
	assert_equal(ok, true, "the fatal must not be dropped: clean tail frames exist past the pre-scrub cap")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_equal(client:snapshot().dropped, 0)
	local body = requests[1].body
	-- the PII never reaches the wire
	assert_not_contains(body, "alice@example.com")
	-- the clean tail frames (which sat PAST the pre-scrub budget) survive
	assert_contains(body, '"function":"game.clean_frame_a"')
	assert_contains(body, '"function":"game.clean_frame_b"')
end

-- ── an over-budget module map is truncated, not rejected wholesale ───────────

-- LOAD-BEARING fatal-safety. A native dump on a large process can load more modules
-- than the per-report budget. Rejecting the whole report (modules_exceeded) would
-- lose a valid previous-session fatal. The module list must be truncated to the cap
-- instead, keeping modules the surviving frames reference.
local function test_oversized_module_map_truncated_fatal_not_dropped()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- The crashed frame references a module deep in the list (past the budget); the
	-- referenced module must be kept so the frame still resolves.
	local referenced_name = "lib_referenced.so"
	local modules = {}
	for i = 1, 300 do
		modules[i] = {
			name = "lib_" .. i .. ".so",
			debug_id = "DBG" .. i,
			load_address = "0x" .. string.format("%x", 0x1000 + i),
		}
	end
	-- put the referenced module at position 290 (well past the 256 budget)
	modules[290] = {
		name = referenced_name,
		debug_id = "DBGREF",
		load_address = "0x9000",
	}
	local ok = client:emit_fatal({
		exception = { type = "SIGSEGV", reason = "boom" },
		modules = modules,
		threads = {
			{
				id = "main",
				crashed = true,
				frames = { { instruction_addr = "0x1abc", module_name = referenced_name } },
			},
		},
	})
	assert_equal(ok, true, "an over-budget module map must be truncated, not reject the fatal")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	assert_equal(client:snapshot().dropped, 0)
	local body = requests[1].body
	-- the module the surviving frame references is kept despite sitting past the budget
	assert_contains(body, '"name":"' .. referenced_name .. '"')
end

-- A previous-session native dump's frames often carry only an instruction address,
-- with no module name. When the module map exceeds the budget, name-based references
-- alone leave the crashing module unprotected, so the truncation could drop the very
-- module the crashing PC falls in (keeping the first N by position) and the crash
-- becomes unsymbolicatable. The module whose ADDRESS RANGE contains a surviving
-- frame's PC must be kept even when no frame names it.
local function test_oversized_module_map_keeps_address_covering_module()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A wide map of early modules at low addresses, plus a late-loaded module whose
	-- address range contains the crashing PC. No frame names any module.
	local modules = {}
	for i = 1, 300 do
		local base = 0x1000 + (i * 0x100)
		modules[i] = {
			name = "lib_" .. i .. ".so",
			debug_id = "DBG" .. i,
			load_address = string.format("0x%x", base),
			end_address = string.format("0x%x", base + 0x80),
		}
	end
	-- The crashing module sits at position 290 (well past the 256 budget) and its
	-- range [0xabc000, 0xabd000) covers the crashing PC 0xabc500.
	local covering_name = "lib_crashing.so"
	modules[290] = {
		name = covering_name,
		debug_id = "DBGCOVER",
		load_address = "0xabc000",
		end_address = "0xabd000",
	}
	local ok = client:emit_fatal({
		exception = { type = "SIGSEGV", reason = "boom" },
		modules = modules,
		threads = {
			{
				id = "main",
				crashed = true,
				-- Only an instruction address; deliberately NO module_name.
				frames = { { instruction_addr = "0xabc500" } },
			},
		},
	})
	assert_equal(ok, true, "an over-budget module map must be truncated, not reject the fatal")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the address-covering module is kept despite sitting past the budget and not
	-- being named by any frame
	assert_contains(body, '"name":"' .. covering_name .. '"')
end

-- ── two app ids that sanitize to the same slug get distinct pending namespaces ─

-- The storage slug collapses any disallowed character to "_", so "com.game" and
-- "com_game" sanitize to the SAME slug. Without a collision-free namespace, one app
-- could resend/remove another app's pending report. A short hash of the RAW app id
-- must keep their per-app sidecars distinct.
local function test_pending_namespace_collision_free()
	reset()
	storage.reset()
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

	local scope_a = { app_id = "com.game" }
	local scope_b = { app_id = "com_game" }
	-- Persist a report under each app; they must NOT land in the same sidecar.
	local token_a = storage.save_pending_crash(scope_a, pending_body_entry("A"))
	local token_b = storage.save_pending_crash(scope_b, pending_body_entry("B"))
	assert_true(type(token_a) == "string")
	assert_true(type(token_b) == "string")

	local entries_a = storage.load_pending_entries(scope_a)
	local entries_b = storage.load_pending_entries(scope_b)
	assert_equal(#entries_a, 1, "app A sees only its own pending report")
	assert_equal(#entries_b, 1, "app B sees only its own pending report")
	assert_contains(entries_a[1].body, '"A"')
	assert_contains(entries_b[1].body, '"B"')

	-- Distinct on-disk namespaces: exactly one identity file per app, two total.
	local paths = {}
	for path in pairs(stores) do
		paths[#paths + 1] = path
	end
	assert_equal(#paths, 2, "the two colliding app ids must write to two distinct namespaces")

	-- The two raw app ids sanitize to the SAME slug ("com_game"), so the only thing
	-- keeping their sidecars apart is the appended hash suffix. Assert each path
	-- carries an 8-hex suffix and that the two suffixes DIFFER — a hash that collapsed
	-- "." and "_" to the same value (or any non-disambiguating hash) would fail here.
	local suffixes = {}
	for _, path in ipairs(paths) do
		local suffix = path:match("%.com_game%.(%x%x%x%x%x%x%x%x)%.pending%-crashes/")
		assert_true(type(suffix) == "string", "each pending namespace carries an 8-hex hash suffix")
		suffixes[#suffixes + 1] = suffix
	end
	assert_not_equal(suffixes[1], suffixes[2],
		"the two colliding app ids must hash to different namespace suffixes")

	-- Removing app A's report must NOT touch app B's.
	assert_true(storage.remove_pending_crash(scope_a, token_a))
	assert_equal(#storage.load_pending_entries(scope_a), 0, "app A's report is settled")
	assert_equal(#storage.load_pending_entries(scope_b), 1, "app B's report is untouched")

	sys.get_save_file = saved_get
	sys.save = saved_save
	sys.load = saved_load
	storage.reset()
end

-- When durable on-disk persistence fails (storage quota / write failure /
-- oversized prepared report) for a one-shot dump-sourced report, the report must
-- NOT be dropped: it falls back to an in-session in-memory pending entry so an
-- in-session retryable failure can still resend it. The send still dispatches, and
-- once the resend is accepted the in-memory entry is cleared (it does not survive a
-- process restart — that is the best-effort contract).
local function test_dump_persist_failure_falls_back_to_in_memory_pending()
	reset()
	storage.reset()
	-- Durable backend PRESENT but every write fails: save_pending_crash returns nil,
	-- so the on-disk path cannot retain the report.
	local saved_get = sys.get_save_file
	local saved_save = sys.save
	local saved_load = sys.load
	sys.get_save_file = function(application_id, file_name)
		return application_id .. "/" .. file_name
	end
	sys.save = function()
		return false
	end
	sys.load = function()
		return nil
	end

	-- LAUNCH: the server is unreachable (status 0 == retryable). The dump is consumed
	-- on read, so the prepared report MUST survive the failed persist via the
	-- in-memory fallback, not be dropped.
	next_status = 0
	local client = assert(crash.new(config({ app_id = "mem-fallback-app", sample_every = 1 })))
	local ok, sent = client:capture_previous(fake_crash_module({
		handle = 9,
		signum = 11,
		os_name = "Android",
		modules = { { name = "libgame.so", address = 0x1000 } },
		backtrace = { { address = 0x1abc } },
	}))
	assert_equal(ok, true)
	assert_equal(sent, true, "the dump must still be dispatched despite the failed persist")
	assert_equal(#requests, 1, "one POST attempted")
	assert_equal(client:snapshot().accepted or 0, 0, "the retryable send was not accepted")
	-- The on-disk store holds nothing (the write failed), but the in-memory fallback
	-- retains exactly one entry so an in-session resend can still recover it.
	assert_equal(#storage.load_pending_crashes({ app_id = "mem-fallback-app" }), 0,
		"the failed durable write leaves nothing on disk")
	local mem_count = 0
	for _ in pairs(client.in_memory_pending) do
		mem_count = mem_count + 1
	end
	assert_equal(mem_count, 1, "a failed persist of a dump report must keep an in-memory pending entry")

	-- IN-SESSION RESEND: the server now accepts (202). The in-memory entry resends,
	-- is accepted, and is cleared (it is not resent again).
	reset()
	next_status = 202
	client:resend_pending()
	assert_equal(#requests, 1, "the in-memory pending report is resent in-session")
	assert_contains(requests[1].body, '"type":"SIGSEGV"')
	assert_contains(requests[1].body, '"instruction_addr":"0x1abc"')
	assert_equal(client:snapshot().accepted, 1, "the in-session resend was accepted")
	local remaining = 0
	for _ in pairs(client.in_memory_pending) do
		remaining = remaining + 1
	end
	assert_equal(remaining, 0, "an accepted in-memory resend clears the entry")

	-- A SECOND resend must not re-dispatch the settled report.
	reset()
	client:resend_pending()
	assert_equal(#requests, 0, "a settled in-memory report is not resent again")

	sys.get_save_file = saved_get
	sys.save = saved_save
	sys.load = saved_load
	storage.reset()
end

-- A terminal (non-retryable 4xx) reject of an in-memory fallback report clears the
-- entry so it is never resent — the SETTLED-removal guarantee holds for the
-- in-memory store too, not just the on-disk one.
local function test_in_memory_pending_terminal_reject_cleared()
	reset()
	storage.reset()
	local saved_get = sys.get_save_file
	local saved_save = sys.save
	local saved_load = sys.load
	sys.get_save_file = function(application_id, file_name)
		return application_id .. "/" .. file_name
	end
	sys.save = function()
		return false
	end
	sys.load = function()
		return nil
	end

	next_status = 400
	local client = assert(crash.new(config({ app_id = "mem-terminal-app", sample_every = 1 })))
	local ok = client:capture_previous(fake_crash_module({
		handle = 5,
		signum = 6,
		modules = { { name = "libgame.so", address = 0x2000 } },
		backtrace = { { address = 0x2abc } },
	}))
	assert_equal(ok, true)
	assert_equal(#requests, 1)
	-- A terminal reject removes the in-memory fallback entry just like a disk entry.
	local remaining = 0
	for _ in pairs(client.in_memory_pending) do
		remaining = remaining + 1
	end
	assert_equal(remaining, 0, "a terminal reject must clear the in-memory pending entry")

	sys.get_save_file = saved_get
	sys.save = saved_save
	sys.load = saved_load
	storage.reset()
end

-- A WHOLE-VALUE bare raw id in a structured code-symbol field (a frame function /
-- fingerprint component) is blanked even with no digit, while a qualified symbol
-- that merely embeds the prefix mid-token is preserved. A FATAL whose ONLY frame
-- function is a bare raw id must still ship — via a clean sibling frame — rather
-- than be dropped as a whole.
local function test_bare_raw_id_frame_blanked_fatal_ships_via_sibling()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- Two frames: the crashing frame's only identity is a bare raw id ("user_alice"),
	-- which blanks to empty and is dropped; the sibling frame carries a clean
	-- qualified symbol and keeps the fatal alive.
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = {
					{ ["function"] = "user_alice" },
					{ ["function"] = "game.update", file = "game/update.lua", line = 42 },
				},
			},
		},
	})
	assert_equal(ok, true, "a fatal must not be dropped because one frame was a bare raw id")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the bare raw id is gone, the clean sibling survives
	assert_not_contains(body, "user_alice")
	assert_contains(body, '"function":"game.update"')

	-- A qualified symbol that embeds the prefix mid-token is PRESERVED as a frame
	-- function (it does not START with the prefix, so it is not a bare raw id).
	reset()
	assert_true(client:emit_fatal({
		exception = { type = "lua_error", reason = "boom" },
		threads = {
			{
				id = "main",
				crashed = true,
				frames = { { ["function"] = "Auth::user_id_from_token" } },
			},
		},
	}))
	assert_contains(requests[1].body, '"function":"Auth::user_id_from_token"')
end

-- A previous-session dump module carries ONLY a load_address (no end_address /
-- size). A crashing frame PC that falls STRICTLY INSIDE a late module (PC greater
-- than that module's base, with no upper bound declared) must still keep that
-- module — resolved by nearest-preceding base — even when it sits past the module
-- budget and no frame names it.
local function test_oversized_address_only_module_map_keeps_nearest_preceding()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	-- A wide map of early ADDRESS-ONLY modules (load_address only, no end_address).
	local modules = {}
	for i = 1, 300 do
		local base = 0x1000 + (i * 0x1000)
		modules[i] = {
			name = "lib_" .. i .. ".so",
			debug_id = "DBG" .. i,
			load_address = string.format("0x%x", base),
		}
	end
	-- The crashing module sits at position 290 (well past the 256 budget) with the
	-- GREATEST base below the crashing PC and NO end_address. The PC is strictly
	-- greater than its base, so a base-only "covers" rule would miss it — the
	-- nearest-preceding rule must promote it.
	local covering_name = "lib_crashing.so"
	modules[290] = {
		name = covering_name,
		debug_id = "DBGCOVER",
		load_address = "0xabc000",
	}
	-- A still-later module loads ABOVE the crashing PC, so it must NOT be chosen
	-- (its base exceeds the PC).
	modules[291] = {
		name = "lib_above.so",
		debug_id = "DBGABOVE",
		load_address = "0xfff000",
	}
	local ok = client:emit_fatal({
		exception = { type = "SIGSEGV", reason = "boom" },
		modules = modules,
		threads = {
			{
				id = "main",
				crashed = true,
				-- PC 0xabc500 is strictly inside lib_crashing.so (base 0xabc000); NO
				-- module_name on the frame.
				frames = { { instruction_addr = "0xabc500" } },
			},
		},
	})
	assert_equal(ok, true, "an over-budget address-only module map must be truncated, not reject the fatal")
	assert_equal(#requests, 1, "the fatal crash must reach the wire")
	local body = requests[1].body
	-- the nearest-preceding module is kept despite sitting past the budget and not
	-- being named by any frame
	assert_contains(body, '"name":"' .. covering_name .. '"')
end

-- A caller-supplied crashed_thread_id that matches NO thread (it was truncated away,
-- or never matched any thread) must not leave a dangling crashed-thread pointer: the
-- pointer falls back to the thread whose `crashed` flag is set (else the first
-- thread), so the crashed stack is always addressable.
local function test_stale_crashed_thread_id_repointed_to_crashed_thread()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom", crashed_thread_id = "no-such-thread" },
		threads = {
			{ id = "bg", crashed = false, frames = { { ["function"] = "bg.tick" } } },
			{ id = "main", crashed = true, frames = { { ["function"] = "game.update" } } },
		},
	})
	assert_equal(ok, true, "a fatal must ship even with a stale crashed_thread_id")
	assert_equal(#requests, 1)
	local body = requests[1].body
	-- the dangling id is repointed to the thread that is actually crashed
	assert_not_contains(body, '"crashed_thread_id":"no-such-thread"')
	assert_contains(body, '"crashed_thread_id":"main"')
end

-- A stale crashed_thread_id with NO thread flagged crashed falls back to the FIRST
-- thread (which is also marked crashed), so the report still has an addressable
-- crashed stack rather than a dangling pointer to a non-existent thread.
local function test_stale_crashed_thread_id_no_flag_falls_back_to_first()
	reset()
	local client = assert(crash.new(config({ sample_every = 1 })))
	local ok = client:emit_fatal({
		exception = { type = "lua_error", reason = "boom", crashed_thread_id = "ghost" },
		threads = {
			{ id = "first", crashed = false, frames = { { ["function"] = "a.tick" } } },
			{ id = "second", crashed = false, frames = { { ["function"] = "b.tick" } } },
		},
	})
	assert_equal(ok, true)
	assert_equal(#requests, 1)
	local body = requests[1].body
	assert_not_contains(body, '"crashed_thread_id":"ghost"')
	assert_contains(body, '"crashed_thread_id":"first"')
end

-- Replaces the stub http.request with one that answers each successive
-- request from `responses` (an array of { status, headers?, body? }; the
-- last one repeats). Returns a restore function.
local function install_scripted_http(responses)
	local saved_request = http.request
	local sent = 0
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		sent = sent + 1
		local script = responses[math.min(sent, #responses)]
		local response = { status = script.status, response = script.body or '{"crash_id":"x"}' }
		if script.headers then
			response.headers = script.headers
		end
		callback(nil, nil, response)
	end
	return function()
		http.request = saved_request
	end
end

-- ── write-ahead durability for live emits ────────────────────────────────────

-- Every emitted report — a live fatal, not just a dump forward — is persisted
-- BEFORE its send attempt, holding the exact encoded wire body.
local function test_live_fatal_emit_persisted_before_dispatch()
	reset()
	local restore = install_fake_sys_storage()

	local held_callback = nil
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		held_callback = function()
			callback(nil, nil, { status = 202, response = '{"crash_id":"x"}' })
		end
	end

	local client = assert(crash.new(config({ app_id = "live-writeahead-app", sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event()))
	assert_equal(#requests, 1, "the live send was dispatched")

	-- The in-flight window: the process may die HERE. The report is already
	-- durable, byte-identical to what was dispatched.
	local in_flight = storage.load_pending_crashes({ app_id = "live-writeahead-app" })
	assert_equal(#in_flight, 1, "a live fatal emit must be persisted before its send completes")
	assert_equal(in_flight[1], requests[1].body, "the persisted body is the exact dispatched wire body")
	assert_equal(client:snapshot().persisted, 1)
	-- Anchor the sidecar cap sizing: a real encoded report is a few hundred
	-- bytes to low kilobytes — far under the 64 KB per-record cap, so the
	-- 8-record / 384 KB bounds hold many launches' worth of reports.
	assert_true(#in_flight[1] > 100 and #in_flight[1] < 16 * 1024,
		"a real encoded report measures well under the per-record cap")

	held_callback()
	assert_equal(client:snapshot().accepted, 1)
	assert_equal(#storage.load_pending_crashes({ app_id = "live-writeahead-app" }), 0,
		"an accepted send clears the write-ahead copy")

	http.request = saved_request
	restore()
	storage.reset()
end

-- Sampling still gates PERSISTENCE, not just dispatch: a sampled-out
-- non-fatal report never touches the sidecar; a sampled-in one is persisted
-- like any other.
local function test_sampling_gates_write_ahead_persist()
	reset()
	local restore = install_fake_sys_storage()
	next_status = 500

	local client = assert(crash.new(config({ app_id = "sampling-app", sample_every = 2 })))
	assert_true(client:emit(presymbolicated_event()))
	assert_equal(client:snapshot().sampled_out, 1, "the first non-fatal is sampled out (1-in-2)")
	assert_equal(#storage.load_pending_crashes({ app_id = "sampling-app" }), 0,
		"a sampled-out report is never persisted")

	assert_true(client:emit(presymbolicated_event()))
	assert_equal(#requests, 1, "the second non-fatal is sampled in and dispatched")
	assert_equal(#storage.load_pending_crashes({ app_id = "sampling-app" }), 1,
		"a sampled-in non-fatal persists write-ahead like any report")

	restore()
	storage.reset()
end

-- The resend pass is STRICTLY SEQUENTIAL and a 429 stops it: remaining
-- reports stay durable, the Retry-After deadline persists with the record,
-- and the pass resumes where it left off once the window is over.
local function test_resend_sequential_429_stops_pass_and_defers()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "seq-app" }

	-- Seed three pending fatals (oldest first: S1, S2, S3), all failing 500.
	next_status = 500
	local seeder = assert(crash.new(config({ app_id = "seq-app", sample_every = 1 })))
	assert_true(seeder:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "S1" } })))
	assert_true(seeder:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "S2" } })))
	assert_true(seeder:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "S3" } })))
	assert_equal(#storage.load_pending_crashes(scope), 3, "three reports are pending")

	-- Relaunch: S1 delivers (202), S2 hits a 429 with Retry-After — the pass
	-- STOPS: S3 is never attempted this pass.
	reset()
	local restore_http = install_scripted_http({
		{ status = 202 },
		{ status = 429, headers = { ["retry-after"] = "7200" } },
	})
	local client = assert(crash.new(config({ app_id = "seq-app", sample_every = 1 })))
	client:resend_pending()
	assert_equal(#requests, 2, "the 429 stops the pass: strictly one request at a time, S3 never raced out")
	assert_contains(requests[1].body, '"S1"')
	assert_contains(requests[2].body, '"S2"')
	local entries, deadline = storage.load_pending_entries(scope)
	assert_equal(#entries, 2, "the delivered report left; the throttled one and its successor stay durable")
	assert_contains(entries[1].body, '"S2"')
	assert_contains(entries[2].body, '"S3"')
	assert_true(type(deadline) == "number" and deadline > 0,
		"the server Retry-After window persists with the pending record")
	restore_http()

	-- While the stored window holds, another pass DEFERS (nothing is sent).
	reset()
	next_status = 202
	local deferred = assert(crash.new(config({ app_id = "seq-app", sample_every = 1 })))
	deferred:resend_pending()
	assert_equal(#requests, 0, "the persisted backpressure window defers the whole pass")
	assert_true(type(deferred:snapshot().resend_deferred_until_ms) == "number",
		"the deferral is surfaced via snapshot")

	-- Once the window is over (cleared here as the elapsed case), the pass
	-- resumes exactly where it left off — S2 first, then S3.
	assert_true(storage.set_pending_crash_retry_after(scope, nil))
	reset()
	next_status = 202
	local resumed = assert(crash.new(config({ app_id = "seq-app", sample_every = 1 })))
	resumed:resend_pending()
	assert_equal(#requests, 2, "the resumed pass delivers the remainder")
	assert_contains(requests[1].body, '"S2"')
	assert_contains(requests[2].body, '"S3"')
	assert_equal(#storage.load_pending_crashes(scope), 0, "everything settled")
	assert_equal(resumed:snapshot().resend_deferred_until_ms, nil, "no deferral is surfaced once the pass ran")

	restore()
	storage.reset()
end

-- An ACCEPTED live send clears the stored backpressure window (the endpoint
-- is taking traffic again); an absurd stored deadline self-cleans on read.
local function test_retry_after_window_cleared_on_accept_and_absurd_dropped()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "window-app" }

	-- Arm a stored window, then deliver a live crash successfully.
	assert_true(storage.set_pending_crash_retry_after(scope, 3600))
	local _, armed = storage.load_pending_entries(scope)
	assert_true(type(armed) == "number", "the window is stored")
	next_status = 202
	local client = assert(crash.new(config({ app_id = "window-app", sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event()))
	local _, after_accept = storage.load_pending_entries(scope)
	assert_equal(after_accept, nil, "an accepted send clears the stored backpressure window")

	-- An absurd stored deadline (far beyond the one-day clamp — wall-clock
	-- skew or a corrupt value) reads as none and self-cleans.
	local clock = require "shardpilot.clock"
	local ns_items = storage.load_pending_entries(scope)
	assert_equal(#ns_items, 0)
	-- write an absurd raw deadline through the public setter's clamp bypass:
	-- the setter clamps, so plant the raw value via a save + manual read
	-- check instead — the setter path itself proves the clamp.
	assert_true(storage.set_pending_crash_retry_after(scope, 10 * 24 * 60 * 60))
	local _, clamped = storage.load_pending_entries(scope)
	assert_true(clamped ~= nil and clamped <= clock.unix_ms() + 24 * 60 * 60 * 1000 + 5000,
		"a stored window is clamped to at most one day ahead")

	restore()
	storage.reset()
end

-- Non-fatal reports are evicted BEFORE any fatal one when the sidecar hits
-- its caps: a burst of handled errors can never displace a pending fatal
-- crash.
local function test_pending_eviction_prefers_non_fatal()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "evict-app" }

	-- Fill to the 8-record count cap: one OLD fatal, then seven non-fatal.
	assert_true(type(storage.save_pending_crash(scope, pending_body_entry("FATAL-OLD"))) == "string")
	for i = 1, 7 do
		assert_true(type(storage.save_pending_crash(scope,
			pending_body_entry("NF" .. i, { fatal = false }))) == "string")
	end
	assert_equal(#storage.load_pending_crashes(scope), 8, "the sidecar is at the count cap")

	-- The ninth report (fatal) must evict the OLDEST NON-FATAL (NF1) — never
	-- the older fatal.
	assert_true(type(storage.save_pending_crash(scope, pending_body_entry("FATAL-NEW"))) == "string")
	local pending = storage.load_pending_crashes(scope)
	assert_equal(#pending, 8)
	local joined = table.concat(pending, "\n")
	assert_contains(joined, '"FATAL-OLD"')
	assert_contains(joined, '"FATAL-NEW"')
	assert_not_contains(joined, '"NF1"')

	restore()
	storage.reset()
end

-- The total-bytes budget bounds the sidecar as a whole: near-cap bodies
-- evict oldest-first (within the non-fatal-first rule) until the list fits.
local function test_pending_total_bytes_budget_evicts()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "budget-app" }

	-- Each body ~60 KB (under the 64 KB per-record cap); seven of them
	-- overflow the 384 KB total budget, so the oldest must leave.
	local function fat_entry(tag)
		return pending_body_entry(tag,
			{ body = '{"crash_id":"' .. tag .. '","blob":"' .. string.rep("y", 60 * 1024) .. '"}' })
	end
	for i = 1, 7 do
		assert_true(type(storage.save_pending_crash(scope, fat_entry("B" .. i))) == "string",
			"each save succeeds by evicting older entries into the byte budget")
	end
	local pending = storage.load_pending_crashes(scope)
	local total = 0
	for i = 1, #pending do
		total = total + #pending[i]
	end
	assert_true(total <= 384 * 1024, "the stored bodies fit the total byte budget")
	assert_true(#pending < 7, "older entries were evicted to fit")
	assert_contains(table.concat(pending, "\n"), '"B7"', "the newest report always survives")

	restore()
	storage.reset()
end

-- A legacy pending entry that stored a prepared-report TABLE (written by an
-- older build) is still resent — encoded once at dispatch — and settles.
local function test_legacy_report_table_entry_resent_and_settled()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "legacy-entry-app" }

	-- Plant a legacy-shaped record (a bare prepared report, no body) at the
	-- exact namespace path the store resolves — probed through
	-- sys.get_save_file so the test never guesses the hashing scheme.
	local ns_probe = nil
	local saved_get = sys.get_save_file
	sys.get_save_file = function(application_id, file_name)
		if application_id:find("pending%-crashes") then
			ns_probe = application_id .. "/" .. (file_name or "identity")
		end
		return saved_get(application_id, file_name)
	end
	storage.load_pending_entries(scope) -- resolves + records the namespace path
	sys.get_save_file = saved_get
	assert_true(ns_probe ~= nil, "the pending namespace path was resolved")
	assert_true(sys.save(ns_probe, { items = {
		{ exception = { type = "lua_error", reason = "LEGACY" }, platform = "linux",
		  app = { id = "legacy-entry-app" }, crash_id = "legacy-1",
		  threads = { { id = "main", crashed = true,
			frames = { { index = 0, ["function"] = "game.update" } } } },
		  occurred_at = "2026-01-01T00:00:00Z" },
	} }), "the legacy record is planted")

	-- The FIRST resend adopts the legacy entry into the byte-identical
	-- contract: it fails retryably here, and the stored entry must now
	-- carry the encoded body under the same token.
	reset()
	next_status = 500
	local client = assert(crash.new(config({ app_id = "legacy-entry-app", sample_every = 1 })))
	client:resend_pending()
	assert_equal(#requests, 1, "the legacy entry was attempted")
	local first_body = requests[1].body
	assert_contains(first_body, '"LEGACY"')
	local adopted = storage.load_pending_entries(scope)
	assert_equal(#adopted, 1, "the retryable failure kept the entry")
	assert_equal(adopted[1].body, first_body,
		"the adoption persisted the exact first-attempt bytes under the same token")

	-- The next pass re-sends those SAME bytes and settles.
	reset()
	next_status = 202
	local client2 = assert(crash.new(config({ app_id = "legacy-entry-app", sample_every = 1 })))
	client2:resend_pending()
	assert_equal(#requests, 1, "the adopted entry is resent")
	assert_equal(requests[1].body, first_body, "byte-identical to the first attempt")
	assert_equal(#storage.load_pending_crashes(scope), 0, "the accepted entry settled")

	restore()
	storage.reset()
end

-- With Defold's ASYNC http callbacks, a fresh dump must never race the
-- resend pass: it is queued (write-ahead) behind the older backlog and the
-- single serial pass sends everything one at a time — a 429 on the older
-- report stops the pass BEFORE the dump goes out, keeping it durable.
local function test_dump_forward_queues_behind_pending_pass()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "order-app" }

	-- Seed one older pending report (S1).
	next_status = 500
	local seeder = assert(crash.new(config({ app_id = "order-app", sample_every = 1 })))
	assert_true(seeder:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "S1" } })))
	assert_equal(#storage.load_pending_crashes(scope), 1)

	-- An ASYNC transport: callbacks are held and released by the test.
	reset()
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		held[#held + 1] = callback
	end

	local client = assert(crash.new(config({ app_id = "order-app", sample_every = 1 })))
	local ok, sent = client:capture_previous(fake_crash_module({
		handle = 9,
		signum = 11,
		os_name = "Android",
		modules = { { name = "libgame.so", address = 0x1000 } },
		backtrace = { { address = 0x1abc } },
	}))
	assert_equal(ok, true)
	assert_equal(sent, true, "the dump was accepted (durably queued + pass started)")

	-- Strictly ONE request in flight: the older S1. The dump must NOT have
	-- been dispatched concurrently with the pass.
	assert_equal(#requests, 1, "one report at a time — the dump never races the pass")
	assert_contains(requests[1].body, '"S1"')
	assert_equal(#storage.load_pending_crashes(scope), 2, "the dump is durably queued behind S1")

	-- The older report hits a 429: the pass STOPS — the dump stays durable
	-- and is never sent into the backpressure window.
	held[1](nil, nil, { status = 429, headers = { ["retry-after"] = "3600" }, response = "" })
	assert_equal(#requests, 1, "the 429 stopped the pass before the dump went out")
	local entries, deadline = storage.load_pending_entries(scope)
	assert_equal(#entries, 2, "both reports remain durable")
	assert_true(type(deadline) == "number", "the backpressure window persisted")

	http.request = saved_request
	restore()
	storage.reset()
end

-- A sidecar full of FATAL reports never gives one up for a sampled-in
-- NON-fatal newcomer: the newcomer is dropped instead (falling back to the
-- session-only memory retention).
local function test_non_fatal_save_never_displaces_fatal_backlog()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "fatal-shield-app" }

	for i = 1, 8 do
		assert_true(type(storage.save_pending_crash(scope, pending_body_entry("F" .. i))) == "string")
	end
	assert_equal(storage.save_pending_crash(scope, pending_body_entry("NF", { fatal = false })), nil,
		"a non-fatal newcomer is dropped rather than displacing a fatal report")
	local pending = storage.load_pending_crashes(scope)
	assert_equal(#pending, 8, "every fatal report survived")
	assert_not_contains(table.concat(pending, "\n"), '"NF"')

	restore()
	storage.reset()
end

-- The in-session memory fallback is BOUNDED with the same retention policy
-- as the sidecar: a persist-failure loop with chatty handled errors cannot
-- accumulate unbounded encoded bodies, and fatal entries are shielded.
local function test_memory_fallback_bounded_and_fatal_shielded()
	reset()
	storage.reset()
	-- No sys storage: every persist fails over to the memory fallback.
	next_status = 500
	local client = assert(crash.new(config({ app_id = "mem-bound-app", sample_every = 1 })))
	for i = 1, 12 do
		assert_true(client:emit(presymbolicated_event({ exception = { type = "lua_error", reason = "NF" .. i } })))
	end
	local count = 0
	for _ in pairs(client.in_memory_pending) do
		count = count + 1
	end
	assert_true(count <= 8, "the memory fallback stays within the sidecar bound")

	-- Fill with fatal entries; a later non-fatal is refused rather than
	-- displacing one.
	for i = 1, 8 do
		assert_true(client:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "F" .. i } })))
	end
	assert_true(client:emit(presymbolicated_event({ exception = { type = "lua_error", reason = "NF-LATE" } })))
	local fatal_only = true
	for _, held in pairs(client.in_memory_pending) do
		if held.fatal ~= true then
			fatal_only = false
		end
	end
	assert_true(fatal_only, "a non-fatal newcomer never displaces a retained fatal report")

	storage.reset()
end

-- The memory fallback honors the sidecar's BYTE caps too: an oversized body
-- is refused outright and the total stays within the budget.
local function test_memory_fallback_honors_byte_caps()
	reset()
	storage.reset()
	next_status = 500
	local client = assert(crash.new(config({ app_id = "mem-bytes-app", sample_every = 1 })))

	local oversized = { body = string.rep("x", 65 * 1024), crash_id = "big", fatal = true }
	assert_equal(client:retain_in_memory_pending(oversized), nil,
		"a body over the per-record cap is refused by the fallback too")

	for i = 1, 7 do
		assert_true(client:retain_in_memory_pending(
			{ body = string.rep("y", 60 * 1024), crash_id = "b" .. i, fatal = true }) ~= nil)
	end
	local total = 0
	for _, held in pairs(client.in_memory_pending) do
		total = total + #held.body
	end
	assert_true(total <= 384 * 1024, "the fallback total stays within the byte budget")

	storage.reset()
end

-- Memory-fallback resend order is by minted sequence, not lexicographic: a
-- pass must send the OLDEST retained report first even once token numbers
-- pass one digit.
local function test_memory_fallback_resends_oldest_first()
	reset()
	storage.reset()
	-- No sys storage: every persist fails over to the memory fallback.
	next_status = 500
	local client = assert(crash.new(config({ app_id = "mem-order-app", sample_every = 1 })))
	for i = 1, 12 do
		assert_true(client:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "NF" .. i .. "x" } })))
	end
	-- Twelve mints, eight retained: the oldest survivor is NF5.
	reset()
	next_status = 202
	client:resend_pending()
	assert_true(#requests >= 1, "the pass ran over the fallback")
	assert_contains(requests[1].body, '"NF5x"')

	storage.reset()
end

-- An accepted send clears the stored backpressure window even when the
-- send was TOKENLESS (its write-ahead persist was rejected outright): the
-- endpoint just took traffic, so later passes must not keep deferring.
local function test_tokenless_accept_clears_retry_after_window()
	reset()
	storage.reset()
	-- No sys storage: the durable save is refused; fill the memory fallback
	-- with fatal entries so a non-fatal emit retains NOTHING (token nil).
	local scope = { app_id = "tokenless-app" }
	next_status = 202
	local client = assert(crash.new(config({ app_id = "tokenless-app", sample_every = 1 })))
	for i = 1, 8 do
		assert_true(client:retain_in_memory_pending(
			{ body = '{"crash_id":"f' .. i .. '"}', crash_id = "f" .. i, fatal = true }) ~= nil)
	end
	assert_true(storage.set_pending_crash_retry_after(scope, 3600))
	local _, armed = storage.load_pending_entries(scope)
	assert_true(type(armed) == "number", "the window is armed")

	assert_true(client:emit(presymbolicated_event()), "the tokenless non-fatal emit is accepted")
	local _, after_accept = storage.load_pending_entries(scope)
	assert_equal(after_accept, nil, "the accepted tokenless send cleared the stale window")

	storage.reset()
end

-- A token REFRESH (the legacy-entry adoption path) runs through the same
-- total-byte budget as an append: a pre-budget sidecar shrinks toward the
-- bound instead of skipping enforcement.
local function test_token_refresh_enforces_byte_budget()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "refresh-budget-app" }

	-- Plant SEVEN wrapped legacy TABLE entries (~60 KB of string scalars
	-- each — over the 384 KB budget in aggregate, which predates it).
	local ns_probe = nil
	local saved_get = sys.get_save_file
	sys.get_save_file = function(application_id, file_name)
		if application_id:find("pending%-crashes") then
			ns_probe = application_id .. "/" .. (file_name or "identity")
		end
		return saved_get(application_id, file_name)
	end
	storage.load_pending_entries(scope)
	sys.get_save_file = saved_get
	assert_true(ns_probe ~= nil, "the pending namespace path was resolved")
	local items = {}
	for i = 1, 7 do
		items[i] = {
			token = "legacy-" .. i,
			report = { crash_id = "L" .. i, blob = string.rep("z", 60 * 1024) },
			created_at = require("shardpilot.clock").unix_ms(),
		}
	end
	assert_true(sys.save(ns_probe, { items = items }), "the legacy over-budget sidecar is planted")

	-- Refresh the OLDEST entry with an encoded body under its own token: the
	-- shared enforcement must evict toward the budget rather than write the
	-- still-over list back untouched.
	local refreshed = storage.save_pending_crash(scope,
		{ body = '{"crash_id":"L1","blob":"' .. string.rep("z", 60 * 1024) .. '"}', crash_id = "L1", fatal = true },
		"legacy-1")
	assert_equal(refreshed, "legacy-1", "the refresh persisted under the same token")
	local entries = storage.load_pending_entries(scope)
	local total = 0
	local has_refreshed = false
	for i = 1, #entries do
		if entries[i].token == "legacy-1" then
			has_refreshed = true
		end
		if type(entries[i].body) == "string" then
			total = total + #entries[i].body
		elseif type(entries[i].report) == "table" then
			total = total + 60 * 1024 -- the planted blob dominates
		end
	end
	assert_true(has_refreshed, "the refreshed entry survived enforcement")
	assert_true(total <= 384 * 1024, "the refresh shrank the sidecar toward the byte budget")
	assert_true(#entries < 7, "older entries were evicted to fit")

	restore()
	storage.reset()
end

-- The resend pass merges memory-retained and on-disk reports by ACTUAL age:
-- an older report whose durable save failed must go out before a newer one
-- that persisted, so a mid-pass 429 never strands the oldest.
local function test_resend_merges_memory_and_disk_by_age()
	reset()
	local restore = install_fake_sys_storage()

	next_status = 500
	local client = assert(crash.new(config({ app_id = "age-merge-app", sample_every = 1 })))
	-- OLDER report: force its durable save to fail (memory retention).
	local saved_save = sys.save
	sys.save = function()
		return false
	end
	assert_true(client:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "OLDERx" } })))
	sys.save = saved_save
	-- NEWER report: persists durably.
	assert_true(client:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "NEWERx" } })))
	assert_equal(client:snapshot().persist_failed, 1, "the older report fell to memory retention")
	assert_equal(client:snapshot().persisted, 1, "the newer report persisted durably")

	reset()
	next_status = 202
	client:resend_pending()
	assert_true(#requests >= 2, "both reports resent")
	assert_contains(requests[1].body, '"OLDERx"')
	assert_contains(requests[2].body, '"NEWERx"')

	restore()
	storage.reset()
end

-- A stored server backpressure window defers NON-fatal live dispatches (the
-- report stays queued for the pass); a FATAL live report still fires — the
-- process may be dying and this is its only chance at the network.
local function test_live_non_fatal_defers_into_stored_window()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "window-defer-app" }

	assert_true(storage.set_pending_crash_retry_after(scope, 3600))
	next_status = 202
	local client = assert(crash.new(config({ app_id = "window-defer-app", sample_every = 1 })))

	assert_true(client:emit(presymbolicated_event({ exception = { type = "lua_error", reason = "HELDx" } })))
	assert_equal(#requests, 0, "a non-fatal live report defers into the stored window")
	assert_equal(#storage.load_pending_crashes(scope), 1, "the deferred report stays durably queued")
	assert_true(type(client:snapshot().resend_deferred_until_ms) == "number", "the deferral is surfaced")

	assert_true(client:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "URGENTx" } })))
	assert_equal(#requests, 1, "a fatal live report fires regardless of the window")
	assert_contains(requests[1].body, '"URGENTx"')

	restore()
	storage.reset()
end

-- A sampled-in NON-fatal live emit during an ACTIVE resend pass queues
-- (never racing the in-flight report into potential backpressure); a clean
-- pass completion runs one follow-up pass that delivers it.
local function test_live_non_fatal_queues_behind_active_pass()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "pass-queue-app" }

	-- Seed one older pending report.
	next_status = 500
	local seeder = assert(crash.new(config({ app_id = "pass-queue-app", sample_every = 1 })))
	assert_true(seeder:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "OLDpass" } })))
	assert_equal(#storage.load_pending_crashes(scope), 1)

	-- Async transport: hold each callback and release manually.
	reset()
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		held[#held + 1] = callback
	end

	local client = assert(crash.new(config({ app_id = "pass-queue-app", sample_every = 1 })))
	client:resend_pending()
	assert_equal(#requests, 1, "the pass has the older report in flight")

	assert_true(client:emit(presymbolicated_event({ exception = { type = "lua_error", reason = "LIVEpass" } })),
		"the sampled-in non-fatal is accepted")
	assert_equal(#requests, 1, "the live non-fatal queued instead of racing the in-flight resend")
	assert_equal(#storage.load_pending_crashes(scope), 2, "it is durably queued")

	-- The in-flight report settles cleanly: the follow-up pass delivers the
	-- queued live report next.
	held[1](nil, nil, { status = 202, response = '{"crash_id":"x"}' })
	assert_equal(#requests, 2, "the follow-up pass dispatched the queued report")
	assert_contains(requests[2].body, '"LIVEpass"')
	held[2](nil, nil, { status = 202, response = '{"crash_id":"x"}' })
	assert_equal(#storage.load_pending_crashes(scope), 0, "everything settled")

	http.request = saved_request
	restore()
	storage.reset()
end

-- The surfaced deferral clears once the window is over (an accepted send
-- clears the stored window and the stat with it).
local function test_deferral_stat_clears_with_window()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "stat-clear-app" }

	assert_true(storage.set_pending_crash_retry_after(scope, 3600))
	next_status = 202
	local client = assert(crash.new(config({ app_id = "stat-clear-app", sample_every = 1 })))
	assert_true(client:emit(presymbolicated_event()), "the non-fatal defers into the window")
	assert_true(type(client:snapshot().resend_deferred_until_ms) == "number", "the deferral is surfaced")

	assert_true(client:emit_fatal(presymbolicated_event()), "the fatal fires and is accepted")
	assert_equal(client:snapshot().resend_deferred_until_ms, nil,
		"the accepted send cleared the window and the surfaced deferral with it")

	restore()
	storage.reset()
end

-- A manual resend_pending() during a live in-flight send must not dispatch
-- the same pending body a second time.
local function test_resend_skips_tokens_in_flight()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "inflight-skip-app" }

	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		held[#held + 1] = callback
	end

	local client = assert(crash.new(config({ app_id = "inflight-skip-app", sample_every = 1 })))
	assert_true(client:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "INFLIGHTx" } })))
	assert_equal(#requests, 1, "the live send is on the wire")
	assert_equal(#storage.load_pending_crashes(scope), 1, "its write-ahead copy is pending")

	client:resend_pending()
	assert_equal(#requests, 1, "the pass skipped the in-flight token — no duplicate concurrent POST")

	held[1](nil, nil, { status = 202, response = '{"crash_id":"x"}' })
	assert_equal(client:snapshot().accepted, 1, "settled exactly once")
	assert_equal(#storage.load_pending_crashes(scope), 0, "the copy settled")

	http.request = saved_request
	restore()
	storage.reset()
end

-- A fatal live emit throttled DURING an active pass raises backpressure the
-- pass honors before its next dispatch: remaining reports stay durable.
local function test_pass_stops_on_concurrent_fatal_throttle()
	reset()
	local restore = install_fake_sys_storage()
	local scope = { app_id = "concurrent-throttle-app" }

	-- Seed two pending reports.
	next_status = 500
	local seeder = assert(crash.new(config({ app_id = "concurrent-throttle-app", sample_every = 1 })))
	assert_true(seeder:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "R1x" } })))
	assert_true(seeder:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "R2x" } })))
	assert_equal(#storage.load_pending_crashes(scope), 2)

	reset()
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		held[#held + 1] = callback
	end

	local client = assert(crash.new(config({ app_id = "concurrent-throttle-app", sample_every = 1 })))
	client:resend_pending()
	assert_equal(#requests, 1, "the pass has R1 in flight")

	-- A fatal live emit bypasses the queue (dying-process posture) and gets
	-- throttled while R1 is still on the wire.
	assert_true(client:emit_fatal(presymbolicated_event({ exception = { type = "lua_error", reason = "LIVEHOTx" } })))
	assert_equal(#requests, 2, "the fatal fired immediately")
	held[2](nil, nil, { status = 429, headers = { ["retry-after"] = "3600" }, response = "" })

	-- R1 settles cleanly, but the pass must NOT advance to R2: the server
	-- just requested a window.
	held[1](nil, nil, { status = 202, response = '{"crash_id":"x"}' })
	assert_equal(#requests, 2, "the pass stopped before R2 — no send into the fresh window")
	local pending = storage.load_pending_crashes(scope)
	assert_true(#pending >= 2, "R2 and the throttled fatal stay durable")

	http.request = saved_request
	restore()
	storage.reset()
end

local tests = {
	test_config_validation,
	test_source_stamped_on_every_report,
	test_bare_app_omits_source,
	test_per_event_invalid_source_rejected,
	test_routes_to_dedicated_crash_endpoint,
	test_crash_id_defaults_to_uuid_v7,
	test_native_frames_require_modules,
	test_presymbolicated_modules_omitted,
	test_fatal_bypasses_sampler,
	test_fatal_dotted_exception_type_reaches_wire,
	test_fatal_dotted_module_name_reaches_wire,
	test_fatal_long_build_id_reaches_wire,
	test_non_fatal_is_sampled,
	test_custom_sampler_does_not_affect_fatal,
	test_sampler_mutation_does_not_reach_wire,
	test_pii_scrubbed_from_wire,
	test_context_session_id_pii_rejects_event,
	test_sanitizer_unit_rules,
	test_breadcrumbs_attached_and_bounded,
	test_breadcrumb_pii_name_dropped,
	test_accepted_increments_snapshot,
	test_suppressed_response_surfaced,
	test_warning_surfaced,
	test_garbage_2xx_body_still_accepted,
	test_retry_after_recorded_on_429,
	test_retry_after_recorded_on_503,
	test_rejected_surfaced_via_diagnostics,
	test_unauthorized_surfaced,
	test_capture_previous_no_dump,
	test_capture_previous_forwards_native_dump,
	test_capture_previous_drops_dump_without_modules,
	test_dump_event_builder_unit,
	test_singleton_guard_and_flow,
	test_caller_event_not_mutated,
	test_crash_id_pii_replaced_with_uuid,
	test_context_identity_keys_stripped,
	test_occurred_at_malformed_defaults_to_now,
	test_breadcrumb_timestamp_scrubbed,
	test_base_address_without_load_address_accepted,
	test_malformed_nested_entry_rejected,
	test_non_hex_frame_address_rejected,
	test_shutdown_waits_for_in_flight_send,
	test_capture_previous_does_not_attach_current_breadcrumbs,
	test_metadata_identity_keys_stripped,
	test_absent_module_fields_omitted,
	test_absent_breadcrumb_fields_omitted,
	test_iso_instant_fraction_strict,
	test_non_hex_module_address_rejected,
	test_embedded_raw_id_scrubbed_from_wire,
	test_dotted_app_version_preserved_on_wire,
	test_raw_text_only_fatal_not_dropped,
	test_timestamp_raw_text_fatal_not_dropped,
	test_manual_frame_symbol_fatal_not_dropped,
	test_pii_only_frame_dropped_clean_frame_ships,
	test_bad_per_event_platform_falls_back_to_config,
	test_at_sign_raw_text_fatal_not_dropped,
	test_overlong_backtrace_truncated_fatal_not_dropped,
	test_identity_key_aliases_stripped,
	test_device_identity_keys_stripped,
	test_padded_identity_key_stripped,
	test_symbol_fingerprint_component_survives_on_wire,
	test_home_path_username_redacted_on_wire,
	test_frame_file_path_username_redacted_on_wire,
	test_frame_address_alias_normalized,
	test_crashed_thread_frames_prioritized,
	test_app_id_actor_prefix_scope_survives,
	test_caller_app_id_overridden_by_config,
	test_non_number_frame_index_normalized,
	test_invalid_numeric_frame_index_normalized,
	test_oversized_fingerprint_components_capped_fatal_not_dropped,
	test_invalid_device_class_dropped_fatal_not_dropped,
	test_oversized_thread_list_capped_keeps_crashed_fatal_not_dropped,
	test_invalid_module_entry_dropped_fatal_not_dropped,
	test_dropped_referenced_module_drops_frame_address_keeps_clean_frame,
	test_unresolvable_address_frame_dropped_clean_sibling_keeps_fatal,
	test_config_app_id_rejects_pii,
	test_platform_required_at_init,
	test_per_report_invalid_scrubbed_source,
	test_dump_persisted_before_dispatch,
	test_dump_retryable_failure_persists_and_resends,
	test_dump_non_retryable_reject_not_persisted,
	test_pending_tokens_unique_under_forced_collision,
	test_failed_durable_write_does_not_update_memory,
	test_oversized_pending_list_evicts_until_write_succeeds,
	test_pending_persistence_safe_without_sys_api,
	test_pending_ttl_discards_stale_report,
	test_legacy_bare_record_token_persisted,
	test_dotted_identity_key_aliases_stripped,
	test_non_boolean_thread_crashed_normalized,
	test_thread_id_pii_redefaulted_fatal_not_dropped,
	test_pii_frames_dropped_before_frame_budget,
	test_oversized_module_map_truncated_fatal_not_dropped,
	test_oversized_module_map_keeps_address_covering_module,
	test_oversized_address_only_module_map_keeps_nearest_preceding,
	test_dump_persist_failure_falls_back_to_in_memory_pending,
	test_in_memory_pending_terminal_reject_cleared,
	test_bare_raw_id_frame_blanked_fatal_ships_via_sibling,
	test_stale_crashed_thread_id_repointed_to_crashed_thread,
	test_stale_crashed_thread_id_no_flag_falls_back_to_first,
	test_non_string_source_rejected_nonfatal_omitted_fatal,
	test_long_valid_slug_source_preserved,
	test_breadcrumb_long_opaque_name_dropped,
	test_address_frames_for_filtered_module_dropped_before_budget,
	test_fractional_frame_line_dropped,
	test_pending_namespace_collision_free,
	test_live_fatal_emit_persisted_before_dispatch,
	test_sampling_gates_write_ahead_persist,
	test_resend_sequential_429_stops_pass_and_defers,
	test_retry_after_window_cleared_on_accept_and_absurd_dropped,
	test_pending_eviction_prefers_non_fatal,
	test_pending_total_bytes_budget_evicts,
	test_legacy_report_table_entry_resent_and_settled,
	test_dump_forward_queues_behind_pending_pass,
	test_non_fatal_save_never_displaces_fatal_backlog,
	test_memory_fallback_bounded_and_fatal_shielded,
	test_memory_fallback_honors_byte_caps,
	test_memory_fallback_resends_oldest_first,
	test_tokenless_accept_clears_retry_after_window,
	test_token_refresh_enforces_byte_budget,
	test_resend_merges_memory_and_disk_by_age,
	test_live_non_fatal_defers_into_stored_window,
	test_live_non_fatal_queues_behind_active_pass,
	test_deferral_stat_clears_with_window,
	test_resend_skips_tokens_in_flight,
	test_pass_stops_on_concurrent_fatal_throttle,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold crash tests passed")
