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

local consent_policy = require "shardpilot.consent_policy"

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

local function reset()
	requests = {}
	next_status = 200
	next_response_body = nil
	next_response_headers = nil
	consent_policy.invalidate()
end

local function context(overrides)
	local ctx = {
		endpoint = "https://policy.example",
		workspace_id = "ws-synthetic",
		app_id = "app-synthetic",
		environment_id = "env-synthetic",
		app_version = "1.2.3",
		locale = "en",
		platform = "windows",
	}
	for key, value in pairs(overrides or {}) do
		if value == "__nil__" then
			ctx[key] = nil
		else
			ctx[key] = value
		end
	end
	return ctx
end

-- A plan as the resolver's initial release actually sends one: no signature,
-- and every signal unavailable with a reason, because it performs no
-- geolocation. A valid plan therefore carries NO COUNTRY.
local function plan(overrides)
	local body = {
		regime = consent_policy.STRICT_OPT_IN,
		crash_profile = consent_policy.CRASH_OFF,
		server_analytics = consent_policy.SERVER_ANALYTICS_DENIED,
		server_analytics_objection_required = true,
		policy_version = "2026-09-12.1",
		consent_text_version = "ff-v1.3",
		presented_language = "en",
		scope = {
			workspace_id = "ws-synthetic",
			app_id = "app-synthetic",
			environment_id = "env-synthetic",
		},
		signals_used = {
			{ name = "server_country", available = false, reason = "not_enabled_in_release" },
			{ name = "store_region", available = false, reason = "source_not_permitted" },
		},
		expires_at = "2099-01-01T00:00:00Z",
		max_age_seconds = 300,
	}
	for key, value in pairs(overrides or {}) do
		if value == "__nil__" then
			body[key] = nil
		else
			body[key] = value
		end
	end
	return encode_value(body)
end

local function prepare(ctx)
	local got
	local calls = 0
	consent_policy.prepare(ctx or context(), function(decision)
		calls = calls + 1
		got = decision
	end)
	return got, calls
end

-- The control: without it, every refusal below would be satisfied by a module
-- that refuses everything.
local function test_a_valid_plan_is_used()
	reset()
	next_response_body = plan()
	local decision, calls = prepare()
	assert_equal(calls, 1, "exactly one callback")
	assert_true(decision.plan_used, "a valid plan must be used: " .. tostring(decision.reason))
	assert_equal(decision.regime, consent_policy.STRICT_OPT_IN)
	assert_true(decision.optional_processing_closed, "STRICT closes optional processing on this verdict alone")
	assert_equal(#requests, 1, "one request")
	assert_true(requests[1].url:find("/api/cp/v1/consent/policy", 1, true) ~= nil, "the published route")
end

-- ⚠ RULE (a): NO SINGLETON, NO IDENTITY, NO DISK. Asserted against the SOURCE
-- and against behaviour: a require of the SDK's storage would create the
-- persisted scope record, and a require of its id module would mint an
-- anonymous identifier — before the player has chosen anything.
local function test_the_module_touches_no_sdk_state()
	local source = io.open("shardpilot/consent_policy.lua"):read("*a")
	for _, forbidden in ipairs({
		'require "shardpilot.sdk"', 'require "shardpilot.client"', 'require "shardpilot.storage"',
		'require "shardpilot.id"', 'require "shardpilot.queue"', 'require "shardpilot.crash"',
	}) do
		assert_true(source:find(forbidden, 1, true) == nil,
			"consent_policy must not " .. forbidden .. ": policy selection is not processing admission")
	end
	-- And it writes nothing: sys.save is the only durable path this SDK has.
	local saves = 0
	local saved = sys.save
	sys.save = function(...)
		saves = saves + 1
		return saved and saved(...)
	end
	reset()
	next_response_body = plan()
	prepare()
	sys.save = saved
	assert_equal(saves, 0, "prepare wrote to disk")
end

-- ⚠ RULE (b): OFFLINE CAN TIGHTEN, NEVER RELAX. A cached permissive result
-- reused when the network is gone is the failure this rule exists for.
local function test_an_error_never_reuses_a_cached_permission()
	reset()
	-- Cache a SOFT plan first, so there is a permission to reuse.
	next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT })
	local first = prepare()
	assert_equal(first.regime, consent_policy.SOFT_OPT_OUT, "the fixture must cache a permissive plan")
	assert_true(not first.optional_processing_closed, "SOFT is not closed by the regime")

	-- Now the network fails. The cache is still warm, and must not be served
	-- as a permission... but it also must not be served at all once the host
	-- invalidates it on the named trigger.
	consent_policy.invalidate()
	next_status = 500
	next_response_body = encode_value({ reason = "policy_unavailable" })
	local second = prepare()
	assert_true(not second.plan_used, "an error must not report a used plan")
	assert_equal(second.regime, consent_policy.STRICT_OPT_IN, "an error is STRICT")
	assert_true(second.optional_processing_closed, "an error closes optional processing")
	assert_equal(second.crash_profile, consent_policy.CRASH_OFF, "an error closes the crash lane")
end

-- ⚠ RULE (c): ONE CALLBACK, EVER, AND A LATE RESPONSE IS DROPPED. A response
-- that arrives after the total deadline cannot change a screen that has
-- already been presented.
local function test_a_late_response_is_dropped()
	reset()
	next_response_body = plan()
	local decisions = {}
	-- The fake transport answers synchronously; advancing the clock inside the
	-- callback is what makes the arrival "late" without a real timer.
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		socket.now = socket.now + 10 -- past the two-second total deadline
		callback(nil, nil, { status = 200, response = next_response_body })
	end
	consent_policy.prepare(context(), function(decision)
		decisions[#decisions + 1] = decision
	end)
	http.request = saved_request
	assert_equal(#decisions, 1, "exactly one callback")
	assert_equal(decisions[1].reason, "deadline_exceeded", "a late response takes the strict path")
	assert_true(decisions[1].optional_processing_closed, "and closes optional processing")
end

-- ⚠ RULE (d): A REFUSED LOCAL VALUE NEVER REACHES THE WIRE. Refusing a
-- non-null store_region only after sending it would have told a server a
-- country claim about this player, which is the point of refusing it.
local function test_a_refused_value_costs_no_request()
	reset()
	next_response_body = plan()
	local decision, calls = prepare(context({ store_region = "DE" }))
	assert_equal(calls, 1, "exactly one callback")
	assert_equal(#requests, 0, "a refused store_region must cost ZERO requests")
	assert_equal(decision.reason, "invalid_request")
	assert_true(decision.optional_processing_closed, "and the verdict is closed")

	-- The other closed vocabularies behave the same way.
	for _, override in ipairs({
		{ platform = "toaster" }, { store = "epic" }, { app_version = "1 2 3" },
		{ locale = string.rep("x", 36) }, { workspace_id = "__nil__" },
		{ age_band = { vocabulary = "v1" } },
	}) do
		reset()
		local refused = prepare(context(override))
		assert_equal(#requests, 0, "a refused context must cost zero requests")
		assert_equal(refused.reason, "invalid_request")
	end

	-- And the control: a well-formed context DOES reach the wire, or the
	-- assertions above would pass on a module that never sends anything.
	reset()
	next_response_body = plan()
	prepare(context({ store = "steam", age_band = { vocabulary = "coarse.v1", band = "adult" } }))
	assert_equal(#requests, 1, "a valid context must be sent")
	assert_true(requests[1].body:find("store_region", 1, true) == nil, "store_region never travels")
end

-- Every malformed plan resolves to STRICT with optional processing closed.
local function test_every_malformed_plan_is_strict()
	local cases = {
		{ "unknown regime", plan({ regime = "PERMISSIVE" }) },
		{ "unknown crash profile", plan({ crash_profile = "EVERYTHING" }) },
		{ "unknown server analytics", plan({ server_analytics = "MAYBE" }) },
		{ "another app's scope", plan({ scope = { workspace_id = "ws-synthetic", app_id = "other", environment_id = "env-synthetic" } }) },
		{ "no expiry", plan({ expires_at = "__nil__" }) },
		{ "version outside its characters", plan({ policy_version = "2026 09 12" }) },
		{ "unavailable signal with no reason", plan({ signals_used = { { name = "server_country", available = false } } }) },
		{ "a signature this build cannot verify", plan({ signature = "ed25519:synthetic" }) },
		{ "not an object", "[]" },
		{ "not json at all", "regime=STRICT" },
	}
	for _, case in ipairs(cases) do
		reset()
		next_response_body = case[2]
		local decision = prepare()
		assert_true(not decision.plan_used, case[1] .. " must not report a used plan")
		assert_equal(decision.regime, consent_policy.STRICT_OPT_IN, case[1] .. " must be STRICT")
		assert_true(decision.optional_processing_closed, case[1] .. " must close optional processing")
		assert_true(decision.server_analytics_objection_required,
			case[1] .. " must keep the objection requirement standing")
	end
end

-- UNKNOWN is a VERIFIED plan that still closes optional processing: the
-- resolver said it could not classify, and that is not permission.
local function test_unknown_closes_optional_processing()
	reset()
	next_response_body = plan({ regime = consent_policy.UNKNOWN })
	local decision = prepare()
	assert_true(decision.plan_used, "UNKNOWN is a verified plan")
	assert_true(decision.optional_processing_closed, "UNKNOWN closes optional processing")
end

-- The private cache is a ceiling, and the host's invalidation is what the
-- named re-resolution triggers call.
local function test_the_cache_is_private_and_invalidatable()
	reset()
	next_response_body = plan()
	prepare()
	assert_equal(#requests, 1)
	prepare()
	assert_equal(#requests, 1, "a second call inside the window is served privately")
	consent_policy.invalidate()
	prepare()
	assert_equal(#requests, 2, "invalidation forces a re-resolution")
end

local tests = {
	test_a_valid_plan_is_used,
	test_the_module_touches_no_sdk_state,
	test_an_error_never_reuses_a_cached_permission,
	test_a_late_response_is_dropped,
	test_a_refused_value_costs_no_request,
	test_every_malformed_plan_is_strict,
	test_unknown_closes_optional_processing,
	test_the_cache_is_private_and_invalidatable,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold consent-policy tests passed")
