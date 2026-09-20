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
				if esc == "u" then
					-- Real Defold json.decode resolves \uXXXX; the harness has
					-- to as well, or a scene about escaped key names would be
					-- testing the harness rather than the module.
					local code = tonumber(string.sub(text, pos + 2, pos + 5), 16)
					parts[#parts + 1] = code and code < 128 and string.char(code) or "?"
					pos = pos + 6
				else
					local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
					parts[#parts + 1] = map[esc] or esc
					pos = pos + 2
				end
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
	crash_shutdown_pending = 0
	sdk_init_failures = 0
	sdk_consent_refusals = 0
	sdk_identify_refusals = 0
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

-- Splices a field into the fixture as RAW TEXT — the encoder cannot produce
-- an empty object, a null, or an escaped key name. The field is dropped from
-- the fixture first, because a duplicate top-level key is now malformed in its
-- own right and the scene would pass for that reason instead.
local function raw_field(name, raw_value, overrides)
	local body = plan(overrides)
	return body:sub(1, 1) .. name .. ":" .. raw_value .. "," .. body:sub(2)
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

-- ⚠ EXPIRY IS ENFORCED, NOT MERELY DESCRIBED. The shape of expires_at was
-- checked and then the plan was used and cached for the full five minutes
-- regardless — so an expired SOFT_OPT_OUT went on reporting optional
-- processing open, and a plan with seconds of life left was served for
-- minutes.
local function test_expiry_is_enforced_before_use_and_before_caching()
	-- (a) An already-expired permissive plan is not used AT ALL.
	reset()
	next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT, expires_at = "1970-01-01T00:00:00Z" })
	local expired = prepare()
	assert_true(not expired.plan_used, "an expired plan must not be used")
	assert_equal(expired.regime, consent_policy.STRICT_OPT_IN, "an expired plan is STRICT")
	assert_true(expired.optional_processing_closed, "an expired plan closes optional processing")

	-- (b) max_age_seconds = 0 says DO NOT REUSE. The answer stands; the cache
	-- entry does not exist.
	reset()
	next_response_body = plan({ max_age_seconds = 0 })
	local once = prepare()
	assert_true(once.plan_used, "max_age_seconds = 0 is still a live plan for this one answer")
	prepare()
	assert_equal(#requests, 2, "max_age_seconds = 0 must not be cached")

	-- (c) The cache never outlives max_age_seconds.
	reset()
	next_response_body = plan({ max_age_seconds = 1 })
	prepare()
	assert_equal(#requests, 1)
	for _ = 1, 20 do
		socket.gettime() -- 0.1 per reading: past a one-second life
	end
	prepare()
	assert_equal(#requests, 2, "the cache must not outlive max_age_seconds")

	-- (d) ...and never outlives expires_at either, whatever max_age says.
	reset()
	socket.now = 0
	next_response_body = plan({ expires_at = "1970-01-01T00:00:03Z", max_age_seconds = 300 })
	local live = prepare()
	assert_true(live.plan_used, "three seconds of life is still life: " .. tostring(live.reason))
	prepare()
	assert_equal(#requests, 1, "inside its life it is served privately")
	socket.now = socket.now + 5
	local stale = prepare()
	assert_equal(#requests, 2, "the cache must not outlive expires_at")
	assert_true(not stale.plan_used, "and the re-resolved plan is now expired")
	socket.now = 1000

	-- The control: an unreadable timestamp is refused rather than treated as
	-- "no expiry", and a valid one is still accepted.
	reset()
	next_response_body = plan({ expires_at = "2099-13-01T00:00:00Z" })
	assert_true(not prepare().plan_used, "an impossible month is not a timestamp")
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:00+02:00" })
	assert_true(prepare().plan_used, "a valid offset timestamp is still a timestamp")
end

-- ⚠ A STRING IS NOT A BOOLEAN, AND ABSENCE IS NOT FALSE. `"true"` was coerced
-- to false, silently lifting an objection requirement inside a plan marked
-- used.
local function test_objection_required_must_be_a_json_boolean()
	reset()
	next_response_body = plan({ server_analytics_objection_required = "true" })
	local coerced = prepare()
	assert_true(not coerced.plan_used, 'the string "true" must not be accepted')
	assert_true(coerced.server_analytics_objection_required, "and the requirement stands")

	reset()
	next_response_body = plan({ server_analytics_objection_required = "__nil__" })
	local absent = prepare()
	assert_true(absent.plan_used, "an omitted optional field is still a readable plan")
	assert_true(absent.server_analytics_objection_required,
		"an omitted objection requirement stands rather than lifting")

	-- The control: an explicit boolean false is the ONLY thing that lifts it,
	-- or the two assertions above would pass on a module that never lifts it.
	reset()
	next_response_body = plan({ server_analytics_objection_required = false })
	local lifted = prepare()
	assert_true(lifted.plan_used, "an explicit false is a readable plan")
	assert_true(not lifted.server_analytics_objection_required, "and it lifts the requirement")
end

-- ⚠ AN INVALIDATED REQUEST CANNOT ANSWER. Clearing the cache alone left the
-- in-flight request free to complete inside its deadline, deliver the stale
-- decision and write it back — the named trigger undone by the very request
-- it fired against.
local function test_an_invalidated_request_cannot_answer()
	reset()
	next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT })
	local decisions = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		consent_policy.invalidate() -- a policy revocation, mid-flight
		callback(nil, nil, { status = 200, response = next_response_body })
	end
	consent_policy.prepare(context(), function(decision)
		decisions[#decisions + 1] = decision
	end)
	http.request = saved_request
	assert_equal(#decisions, 1, "exactly one callback")
	assert_equal(decisions[1].reason, "invalidated", "an invalidated request takes the strict path")
	assert_true(not decisions[1].plan_used, "it must not deliver the plan it was carrying")
	assert_true(decisions[1].optional_processing_closed, "and closes optional processing")

	-- And the cache must still be empty: repopulating it was the defect.
	next_response_body = plan()
	local after = prepare()
	assert_equal(#requests, 2, "the invalidated response must not have repopulated the cache")
	assert_equal(after.regime, consent_policy.STRICT_OPT_IN, "and the fresh resolution stands")
end

-- ⚠ A JSON OBJECT IS NOT AN EMPTY LIST. It decodes to a Lua table of length
-- zero over which ipairs yields nothing, so a roster of operation blocks
-- supplied as an object read as "no blocks" — a malformed plan wearing a
-- permissive one's clothes.
local function test_a_json_object_is_not_an_empty_list()
	for _, case in ipairs({
		{ "operation_blocks", plan({ operation_blocks = { policy_selection = "blocked" } }) },
		{ "prohibited_purposes", plan({ prohibited_purposes = { advertising = true } }) },
		{ "signals_used", plan({ signals_used = { server_country = "absent" } }) },
	}) do
		reset()
		next_response_body = case[2]
		local decision = prepare()
		assert_true(not decision.plan_used,
			case[1] .. " supplied as an object must not read as an empty list")
		assert_true(decision.optional_processing_closed, case[1] .. " must close optional processing")
	end

	-- The control: a genuine array of the same fields is still accepted, or
	-- the refusals above would pass on a module that refuses both shapes.
	reset()
	next_response_body = plan({ operation_blocks = { "profiling" }, prohibited_purposes = { "advertising" } })
	local accepted = prepare()
	assert_true(accepted.plan_used, "a genuine array must still be accepted: " .. tostring(accepted.reason))
	assert_equal(accepted.operation_blocks[1], "profiling", "and it is carried through")
end

-- ⚠ THE CACHE IS SCOPED TO THE WHOLE CONTEXT. One process-wide entry served
-- on liveness alone handed one app's, environment's or endpoint's permission
-- to another, past the scope check that only ever saw the first context.
local function test_the_cache_is_scoped_to_the_whole_context()
	-- The control first: the SAME context is still served privately.
	reset()
	next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT })
	local first = prepare()
	assert_equal(first.regime, consent_policy.SOFT_OPT_OUT, "the fixture must cache a permissive plan")
	local again = prepare()
	assert_equal(#requests, 1, "the same context is served from the cache")
	assert_equal(again.regime, consent_policy.SOFT_OPT_OUT, "with the decision that was cached")

	for _, override in ipairs({
		{ app_id = "app-other" }, { workspace_id = "ws-other" }, { environment_id = "env-other" },
		{ endpoint = "https://policy.other.example" }, { locale = "de" },
		{ platform = "macos" }, { app_version = "9.9.9" },
		{ age_band = { vocabulary = "coarse.v1", band = "adult" } },
	}) do
		reset()
		next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT })
		prepare()
		assert_equal(#requests, 1, "the cache is primed")
		prepare(context(override))
		assert_equal(#requests, 2, "a changed context field must re-resolve, not reuse the permission")
	end
end

-- ⚠ THE ENDPOINT IS PART OF THE CONTEXT CONTRACT. An absent one was
-- concatenated with the route and raised a Lua error out of prepare, so the
-- single callback this module promises never arrived and the caller had
-- nothing to fail closed on.
local function test_an_invalid_endpoint_is_an_invalid_request()
	for _, override in ipairs({
		{ endpoint = "__nil__" }, { endpoint = 8080 }, { endpoint = "policy.example" },
		{ endpoint = "https://" .. string.rep("h", 300) },
		-- ⚠ PLAIN http OFF LOOPBACK. The request carries this app's scope and
		-- this player's locale and age band; in the clear to a remote host is
		-- not a development convenience.
		{ endpoint = "http://policy.example" },
		{ endpoint = "http://198.51.100.7:8082" },
		-- The rest of the SDK's URL rule, which the copied predicate brings
		-- with it: no userinfo, no query, no fragment, no path.
		{ endpoint = "https://user@policy.example" },
		{ endpoint = "https://policy.example?a=1" },
		{ endpoint = "https://policy.example#f" },
		{ endpoint = "https://policy.example/v2" },
	}) do
		reset()
		next_response_body = plan()
		local decision, calls = prepare(context(override))
		assert_equal(calls, 1, "exactly one callback, even for a malformed endpoint")
		assert_equal(#requests, 0, "a refused endpoint must cost zero requests")
		assert_equal(decision.reason, "invalid_request")
		assert_true(decision.optional_processing_closed, "and the verdict is closed")
	end

	-- The controls: https anywhere, http on loopback, and a single trailing
	-- slash accepted and trimmed rather than refused — the SAME verdicts the
	-- SDK gives ingest_url and crash_ingest_url, which is the point of copying
	-- its predicate instead of writing a second opinion.
	for _, endpoint in ipairs({
		"https://policy.example", "https://policy.example/", "https://policy.example:8443",
		"http://localhost:8082", "http://127.0.0.1:8082", "http://[::1]:8082",
	}) do
		reset()
		next_response_body = plan()
		local decision = prepare(context({ endpoint = endpoint }))
		assert_true(decision.plan_used, endpoint .. " must be accepted: " .. tostring(decision.reason))
		assert_equal(#requests, 1, endpoint .. " must reach the wire")
		assert_true(requests[1].url:find("//api/cp", 1, true) == nil,
			"a trailing slash must be trimmed, not doubled: " .. requests[1].url)
	end
end

-- ⚠ THE URL PREDICATE IS A COPY, AND A COPY THAT DRIFTS IS WORSE THAN NO
-- SHARING AT ALL. consent_policy cannot require shardpilot.client — that would
-- pull in storage and id, creating the persisted scope record and minting an
-- anonymous identifier before the player has chosen anything — so the rule is
-- duplicated on purpose. This asserts the duplicate is still byte-for-byte the
-- original.
--
-- HONEST LIMIT: it compares TEXT. It catches the copy falling behind an edit to
-- client.lua; it cannot catch a divergence introduced somewhere else in either
-- module.
local function test_the_url_predicate_is_a_verbatim_copy()
	local client = io.open("shardpilot/client.lua"):read("*a")
	local policy = io.open("shardpilot/consent_policy.lua"):read("*a")
	local first = client:find("local function local_http_host(host)", 1, true)
	local last = client:find("local max_snapshot_depth = 4", 1, true)
	assert_true(first ~= nil and last ~= nil and last > first,
		"client.lua no longer has the predicate this copy was taken from")
	local original = client:sub(first, last - 1):gsub("%s+$", "")
	assert_true(policy:find(original, 1, true) ~= nil,
		"consent_policy.lua no longer carries client.lua's URL predicate verbatim; " ..
		"re-copy it rather than letting the two rules drift")
end

-- ⚠ available IS A BOOLEAN OR THE PLAN IS MALFORMED. `available ~= true`
-- folded a string, a number and an absent key into "unavailable" — an answer
-- the resolver never gave, written into the provenance record as though it had.
local function test_a_signal_must_state_its_availability_as_a_boolean()
	for _, signal in ipairs({
		{ name = "server_country", reason = "not_enabled_in_release" },
		{ name = "server_country", available = "false", reason = "not_enabled_in_release" },
		{ name = "server_country", available = 0, reason = "not_enabled_in_release" },
		{ name = "server_country", available = "true" },
	}) do
		reset()
		next_response_body = plan({ signals_used = { signal } })
		local decision = prepare()
		assert_true(not decision.plan_used, "a signal that does not state a boolean must not be used")
		assert_true(decision.optional_processing_closed, "and the verdict is closed")
	end

	-- The controls: a stated false WITH a reason and a stated true WITHOUT one
	-- both parse, or the rule would be satisfied by a parser that refuses every
	-- signal.
	reset()
	next_response_body = plan({ signals_used = { { name = "server_country", available = false, reason = "source_unavailable" } } })
	assert_true(prepare().plan_used, "a stated false with a reason must parse")
	reset()
	next_response_body = plan({ signals_used = { { name = "server_country", available = true } } })
	assert_true(prepare().plan_used, "a stated true must parse")
end

-- ⚠ THE CALLER GETS A COPY, NOT THE CACHE ENTRY. The same table was handed to
-- every caller and kept as the entry, so a caller that wrote a field on its
-- decision — or sorted prohibited_purposes in place — edited what the next five
-- minutes of prepare calls would serve.
local function test_a_returned_decision_is_a_copy()
	reset()
	next_response_body = plan({ operation_blocks = { "transfer_review" }, prohibited_purposes = { "advertising" } })
	local first = prepare()
	assert_equal(first.operation_blocks[1], "transfer_review", "the fixture must carry a block")

	-- Mutate everything a caller could reach.
	first.regime = "PERMISSIVE"
	first.optional_processing_closed = false
	first.server_analytics_objection_required = false
	first.operation_blocks[1] = "removed"
	first.prohibited_purposes[1] = "removed"

	local second = prepare()
	assert_equal(#requests, 1, "the second call must be served from the cache, or this proves nothing")
	assert_equal(second.regime, consent_policy.STRICT_OPT_IN, "a caller mutated the cached regime")
	assert_true(second.optional_processing_closed, "a caller reopened optional processing in the cache")
	assert_true(second.server_analytics_objection_required, "a caller lifted the cached objection requirement")
	assert_equal(second.operation_blocks[1], "transfer_review", "a caller mutated the cached block list")
	assert_equal(second.prohibited_purposes[1], "advertising", "a caller mutated the cached purpose list")

	-- And two cache hits do not share an array with each other either.
	second.operation_blocks[1] = "removed"
	local third = prepare()
	assert_equal(third.operation_blocks[1], "transfer_review", "two cache hits shared one array")
end

-- ⚠ AN EMPTY SIGNATURE IS STILL A SIGNATURE. Treating "" as absence is a
-- downgrade path: a signed response whose signature failed to serialise would
-- have been admitted by a build that cannot verify signatures at all.
local function test_an_empty_signature_is_still_a_signature()
	reset()
	next_response_body = plan({ signature = "" })
	local decision = prepare()
	assert_true(not decision.plan_used, "an empty signature is not an absent one")
	assert_equal(decision.regime, consent_policy.STRICT_OPT_IN, "it takes the strict path")
	assert_true(decision.optional_processing_closed, "and closes optional processing")
end

-- ⚠ THE PUBLISHED EXAMPLE IS PART OF THE CONTRACT, AND IT IS RUN HERE RATHER
-- THAN READ. An earlier cut logged the regime and then called set_consent(true),
-- started a session and initialised default-on crash reporting regardless —
-- "we asked, and then ignored the answer". The example is the integration path
-- users copy, so the branches are exercised headlessly: the SDK modules are
-- replaced in package.loaded and the chunk is loaded, which defines init().
-- `between` runs after init() and before update(), i.e. while the notice is
-- still on screen. `window_events` are fired after update().
-- When set, the fake crash client reports shutdown as still pending this many
-- times before succeeding — the real one does exactly that while a POST is in
-- flight (crash/client.lua:1175-1188).
local crash_shutdown_pending = 0
-- The real SDK returns false, err from init (a bad config) and from
-- set_consent (a full or unwritable consent outbox); the fakes do too, on
-- demand, because the example is supposed to notice.
local sdk_init_failures = 0
local sdk_consent_refusals = 0
local sdk_identify_refusals = 0

local function run_example(between, window_events, dts, finalize)
	local seen = {}
	local function record(name)
		return function(...)
			seen[#seen + 1] = name
			return ...
		end
	end
	local saved = {}
	for _, name in ipairs({ "shardpilot.sdk", "shardpilot.crash", "shardpilot.platform" }) do
		saved[name] = package.loaded[name]
	end
	package.loaded["shardpilot.sdk"] = {
		init = function()
			seen[#seen + 1] = "sdk.init"
			if sdk_init_failures > 0 then
				sdk_init_failures = sdk_init_failures - 1
				return false, "ingest_url_required"
			end
			return true
		end,
		identify = function()
			seen[#seen + 1] = "sdk.identify"
			if sdk_identify_refusals > 0 then
				sdk_identify_refusals = sdk_identify_refusals - 1
				return false, "events_pending"
			end
			return true
		end,
		set_consent = function(value)
			seen[#seen + 1] = "sdk.set_consent:" .. tostring(value)
			if sdk_consent_refusals > 0 then
				sdk_consent_refusals = sdk_consent_refusals - 1
				return false, "consent_outbox_full"
			end
			return true
		end,
		session_start = record("sdk.session_start"),
		fetch_remote_config = function(callback)
			seen[#seen + 1] = "sdk.fetch_remote_config"
			callback({ ok = true })
		end,
		remote_config_number = function(_, default)
			return default
		end,
		update = function() end,
		persist = function() end,
		shutdown = function(reason)
			seen[#seen + 1] = "sdk.shutdown:" .. tostring(reason)
			return true
		end,
	}
	package.loaded["shardpilot.crash"] = {
		init = function()
			seen[#seen + 1] = "crash.init"
			return true
		end,
		set_enabled = function(enabled)
			seen[#seen + 1] = "crash.set_enabled:" .. tostring(enabled)
		end,
		shutdown = function()
			if crash_shutdown_pending > 0 then
				crash_shutdown_pending = crash_shutdown_pending - 1
				seen[#seen + 1] = "crash.shutdown:pending"
				return false, "pending"
			end
			seen[#seen + 1] = "crash.shutdown"
			return true
		end,
	}
	local saved_window = window
	window = {
		WINDOW_EVENT_ICONFIED = "iconified",
		WINDOW_EVENT_FOCUS_LOST = "focus_lost",
		WINDOW_EVENT_FOCUS_GAINED = "focus_gained",
		set_listener = function(listener)
			window.listener = listener
		end,
	}
	package.loaded["shardpilot.platform"] = { detect = function() return "windows" end }

	-- The example's own print() is the only place it reports the decision, so
	-- it is captured rather than left on stdout: it is what tells this scene
	-- the plan was USED, not merely that the branches were taken.
	local saved_print = print
	print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(i, ...)))
		end
		seen[#seen + 1] = "print:" .. table.concat(parts, " ")
	end

	-- ⚠ TWO SNAPSHOTS, BECAUSE THE ORDERING IS THE PROPERTY. The example's
	-- placeholder notice answers from update(), so what happened by the end of
	-- init() is exactly "everything that ran BEFORE the player's final choice".
	local after_init, after_update
	local ok, err = pcall(function()
		local chunk = assert(loadfile("examples/minimal/main.script"))
		chunk()
		init(nil)
		after_init = table.concat(seen, " | ")
		if between then
			between()
		end
		update(nil, 0)
		after_update = table.concat(seen, " | ")
		for _, event in ipairs(window_events or {}) do
			window.listener(nil, event, nil)
			update(nil, 0)
		end
		for _, dt in ipairs(dts or {}) do
			update(nil, dt)
		end
		if finalize then
			final(nil)
		end
		after_update = table.concat(seen, " | ")
	end)
	window = saved_window

	print = saved_print
	for _, name in ipairs({ "shardpilot.sdk", "shardpilot.crash", "shardpilot.platform" }) do
		package.loaded[name] = saved[name]
	end
	assert_true(ok, "the example must run: " .. tostring(err))
	return after_update, after_init
end

-- The example's own context, so the fixture's plan is IN SCOPE for it. Without
-- this every scene below would be reading a scope-mismatch fallback and would
-- pass for the wrong reason — which is what the first draft did.
local function example_plan(overrides)
	local body = overrides or {}
	body.scope = {
		workspace_id = "workspace-example",
		app_id = "app-example",
		environment_id = "develop",
	}
	return plan(body)
end

local function test_the_published_example_branches_on_the_decision()
	-- (a) The regime this release actually emits: STRICT, crash OFF, server
	-- analytics DENIED. Nothing may be granted, so nothing is asked and
	-- nothing is initialised.
	reset()
	next_response_body = example_plan()
	local calls, before_choice = run_example()
	-- ⚠ THE CONTROL FIRST: the example must have USED the plan. Otherwise it is
	-- reading a strict fallback and every assertion below is satisfied by a
	-- refusal rather than by a branch.
	assert_true(calls:find("consent regime: STRICT_OPT_IN", 1, true) ~= nil,
		"the example must report the plan's regime: " .. calls)
	assert_true(calls:find("strict fallback", 1, true) == nil,
		"the example read a fallback, not the fixture's plan: " .. calls)
	assert_true(calls:find("sdk.init", 1, true) == nil,
		"a closed lane must not initialise the SDK (identity + spool): " .. calls)
	assert_true(calls:find("set_consent", 1, true) == nil,
		"a closed lane leaves nothing to grant, so no consent decision is written: " .. calls)
	assert_true(calls:find("crash.init", 1, true) == nil,
		"the example enabled default-on crash reporting under crash_profile OFF: " .. calls)

	-- (b) The CRASH lane is decided separately, so a permitted crash profile
	-- opens it even though analytics stays closed. Without this the assertions
	-- above would be satisfied by an example that does nothing at all.
	--
	-- ⚠ AND IT OPENS AT ONCE HERE, WHICH IS A CHANGE FROM THE PREVIOUS ROUND.
	-- The rule is "no capture hook before the player's FINAL CHOICE"; with the
	-- optional lane closed there is nothing to grant, no notice is presented
	-- (a question whose answer is discarded is worse than not asking), and so no
	-- choice is pending — the decision itself is final. The waiting property
	-- is asked in (c), where a choice really is pending.
	reset()
	next_response_body = example_plan({ crash_profile = consent_policy.CRASH_MINIMAL })
	calls, before_choice = run_example()
	assert_true(calls:find("crash.init", 1, true) ~= nil,
		"a permitted crash profile must open the crash lane: " .. calls)
	assert_true(calls:find("sdk.init", 1, true) == nil,
		"and it must not open analytics: " .. calls)
	assert_true(calls:find("present", 1, true) == nil and calls:find("set_consent", 1, true) == nil,
		"a closed optional lane must not be asked about: " .. calls)

	-- (c) An OPEN optional lane. A choice IS pending, so NEITHER lane may have
	-- started by the end of init() — the crash reporter is a capture hook and
	-- this is where that rule bites. After the answer both lanes act, and the
	-- placeholder's DECLINE is recorded, which is the documented path.
	reset()
	next_response_body = example_plan({
		regime = consent_policy.SOFT_OPT_OUT, crash_profile = consent_policy.CRASH_MINIMAL,
	})
	calls, before_choice = run_example()
	assert_true(before_choice:find("sdk.", 1, true) == nil and before_choice:find("crash.", 1, true) == nil,
		"nothing may exist while the notice is still on screen: " .. before_choice)
	assert_true(calls:find("sdk.init", 1, true) ~= nil,
		"an open lane must reach the SDK once the player has answered: " .. calls)
	assert_true(calls:find("set_consent:false", 1, true) ~= nil,
		"a declined answer must be recorded, not dropped: " .. calls)
	assert_true(calls:find("sdk.session_start", 1, true) == nil,
		"a decline must not start a session: " .. calls)
	assert_true(calls:find("crash.init", 1, true) ~= nil,
		"and the crash lane opens once the choice is no longer pending: " .. calls)
end

-- ⚠ TWO REQUESTS FOR THE SAME CONTEXT SHARE A GENERATION, so neither
-- supersedes the other and whichever answers LAST writes the cache. An older
-- permissive response landing after a newer restrictive one therefore reopened
-- what the newer one had just closed — purely by arriving second.
local function test_an_older_response_cannot_overwrite_a_newer_one()
	reset()
	-- A transport that holds every request until this scene releases it.
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url }
		held[#held + 1] = { callback = callback, body = next_response_body }
	end

	local first, second = {}, {}
	next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT })
	consent_policy.prepare(context(), function(d) first[#first + 1] = d end)
	next_response_body = plan({ regime = consent_policy.STRICT_OPT_IN })
	consent_policy.prepare(context(), function(d) second[#second + 1] = d end)
	assert_equal(#held, 2, "both requests must be in flight")

	-- The NEWER one answers first; then the older, permissive one arrives.
	held[2].callback(nil, nil, { status = 200, response = held[2].body })
	held[1].callback(nil, nil, { status = 200, response = held[1].body })
	http.request = saved_request

	assert_equal(#second, 1, "the newer caller is answered exactly once")
	assert_equal(second[1].regime, consent_policy.STRICT_OPT_IN, "and with its own plan")
	assert_equal(#first, 1, "the older caller is answered exactly once, not dropped")
	assert_equal(first[1].reason, "superseded", "and told why")
	assert_true(first[1].optional_processing_closed, "a superseded answer is closed")

	-- ⚠ AND THE CACHE KEEPS THE NEWER ANSWER. This is the whole point: the
	-- older response must not reopen what the newer one closed.
	local served = prepare()
	assert_equal(#requests, 2, "the third call must be served from the cache")
	assert_equal(served.regime, consent_policy.STRICT_OPT_IN,
		"an older permissive response overwrote the cache")
end

-- ⚠ AN ENCODER THAT RAISES IS NOT A STRICT DECISION, IT IS NO DECISION. The
-- error left prepare without ever invoking the one callback it promises, so
-- the caller had nothing to fail closed on — the same shape as the endpoint
-- concatenation defect.
local function test_an_encoder_failure_still_answers()
	reset()
	next_response_body = plan()
	local saved_encode = json.encode
	json.encode = function()
		error("synthetic encoder failure")
	end
	local decision, calls = prepare()
	json.encode = saved_encode
	assert_equal(calls, 1, "exactly one callback when the encoder raises")
	assert_equal(decision.reason, "encoder_failed")
	assert_equal(#requests, 0, "a body that could not be encoded must cost zero requests")
	assert_true(decision.optional_processing_closed, "and the verdict is closed")
end

-- ⚠ AN OUTAGE CAN TIGHTEN, NEVER RELAX — INCLUDING OVER A WARM CACHE. The
-- cache was read before the transport was checked, so losing the network
-- served the last permissive answer for the rest of the window, and it read as
-- a cache hit rather than as an outage.
local function test_a_lost_transport_beats_a_cached_permission()
	reset()
	next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT })
	local first = prepare()
	assert_equal(first.regime, consent_policy.SOFT_OPT_OUT, "the fixture must cache a permissive plan")

	local saved_http = http
	http = nil
	local decision, calls = prepare()
	http = saved_http
	assert_equal(calls, 1, "exactly one callback")
	assert_equal(decision.reason, "transport_unavailable", "the outage wins over the cache")
	assert_true(not decision.plan_used, "and no plan is reported as used")
	assert_true(decision.optional_processing_closed, "and optional processing is closed")

	-- The control: with the transport back, the cache is still there — so the
	-- assertion above is about the outage, not about the entry having expired.
	local restored = prepare()
	assert_equal(restored.regime, consent_policy.SOFT_OPT_OUT, "the entry survived the outage")
	assert_equal(#requests, 1, "and was served without a new request")
end

-- ⚠ NO socket IS NOT A REASON TO BE PERMANENTLY STRICT. Returning nil made
-- prepare refuse outright on every target without the socket module — not
-- failing closed on a doubt, but never asking the question. clock.lua already
-- falls back to os.time(); second resolution is ample for an expiry measured
-- in minutes.
local function test_the_clock_falls_back_to_os_time()
	reset()
	next_response_body = plan()
	local saved_socket = socket
	socket = nil
	local decision, calls = prepare()
	socket = saved_socket
	assert_equal(calls, 1, "exactly one callback")
	assert_equal(#requests, 1, "a target without socket must still reach the wire")
	assert_true(decision.plan_used, "and use the plan: " .. tostring(decision.reason))

	-- The control: with NEITHER clock the refusal stands, so the fallback did
	-- not simply delete the rule.
	reset()
	next_response_body = plan()
	socket = nil
	local saved_time = os.time
	os.time = nil
	local blind = prepare()
	os.time = saved_time
	socket = saved_socket
	assert_equal(blind.reason, "clock_unavailable", "with no clock at all the refusal stands")
	assert_equal(#requests, 0, "and it costs no request")
end

-- ⚠ AN EMPTY JSON OBJECT AND AN EMPTY ARRAY DECODE TO THE SAME LUA TABLE, so
-- after the decode the container type is gone. `"operation_blocks": {}` read
-- as "no operation blocks" and the plan was USED. The raw response text is the
-- only place the distinction survives.
local function test_an_empty_object_is_not_an_empty_list()
	for _, name in ipairs({ "operation_blocks", "prohibited_purposes", "signals_used" }) do
		for _, spacing in ipairs({ "{}", " { }", "\t{\"a\":1}" }) do
			reset()
			next_response_body = raw_field('"' .. name .. '"', spacing, { [name] = "__nil__" })
			local decision = prepare()
			assert_true(not decision.plan_used,
				name .. " as a JSON object must not be used (" .. spacing .. ")")
			assert_true(decision.optional_processing_closed, "and the verdict is closed")
		end
	end

	-- The controls: an empty ARRAY still parses for all three, or this rule
	-- would be refusing the resolver's own output.
	reset()
	next_response_body = plan({ operation_blocks = {}, prohibited_purposes = {}, signals_used = {} })
	assert_true(prepare().plan_used, "empty arrays must still parse")
end

-- ⚠ AN OFFSET IS SPELLED WITH THE COLON. Accepting "+0200" as well was being
-- generous with someone else's grammar, and a parser that accepts more than
-- the spec disagrees with every other reader of the same field.
local function test_an_offset_needs_its_colon()
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:00+0200" })
	assert_true(not prepare().plan_used, '"+0200" is not an RFC 3339 offset')
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:00+02:00" })
	assert_true(prepare().plan_used, '"+02:00" is')
end

-- ⚠ THE DECISION THAT OPENED THE NOTICE IS NOT THE ONE TO ACT ON. The player
-- was reading the screen; the plan may have expired or the policy may have
-- been revoked meanwhile, and acting on the captured decision starts a lane on
-- a verdict that is no longer true.
local function test_the_example_re_resolves_after_the_answer()
	reset()
	-- The optional lane must be OPEN, or no notice is presented and there is
	-- no answer to be stale about. The plan carries the NORMAL cache lifetime:
	-- the re-resolution has to reach the resolver on its own merits, which it
	-- only does because the example invalidates first. An earlier version of
	-- this scene used max_age_seconds = 0 and so could not tell a real
	-- re-resolution from a cache entry that had simply never been written.
	next_response_body = example_plan({
		regime = consent_policy.SOFT_OPT_OUT,
		crash_profile = consent_policy.CRASH_MINIMAL,
	})
	local calls = run_example(function()
		-- While the notice is on screen the policy changes: the crash lane closes.
		next_response_body = example_plan({
			regime = consent_policy.SOFT_OPT_OUT,
			crash_profile = consent_policy.CRASH_OFF,
		})
	end)
	assert_equal(#requests, 2, "the answer must be followed by a real request, not a cache hit")
	assert_true(calls:find("crash.init", 1, true) == nil,
		"the example acted on the stale decision and opened a lane the fresh one closes: " .. calls)
end

-- ⚠ RESUME IS A NAMED RE-RESOLUTION TRIGGER, and one that cannot CLOSE
-- anything is not one. An app can sit in the background for days.
local function test_the_example_closes_lanes_on_resume()
	local function open_plan()
		return example_plan({
			regime = consent_policy.SOFT_OPT_OUT, crash_profile = consent_policy.CRASH_MINIMAL,
		})
	end

	-- The control: with the policy unchanged, a resume closes nothing.
	reset()
	next_response_body = open_plan()
	local calls = run_example(nil, { "focus_gained" })
	assert_true(calls:find("sdk.init", 1, true) ~= nil and calls:find("crash.init", 1, true) ~= nil,
		"both lanes must be open, or this scene proves nothing: " .. calls)
	-- The placeholder notice declines, so set_consent:false appears either way;
	-- what only a CLOSURE produces is the suspension lines.
	assert_true(calls:find("suspended", 1, true) == nil,
		"an unchanged policy must not close anything on resume: " .. calls)

	-- Now the policy closes both lanes while the app is backgrounded. The
	-- resume resolution is the SECOND request: launch is the first, and the
	-- one after the player's answer is a private cache hit.
	reset()
	next_response_body = open_plan()
	local resumed = false
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url }
		-- Launch is 1, the post-notice re-resolution is 2, the resume is 3.
		if #requests >= 3 then
			next_response_body = example_plan({
				regime = consent_policy.STRICT_OPT_IN, crash_profile = consent_policy.CRASH_OFF,
			})
			resumed = true
		end
		callback(nil, nil, { status = 200, response = next_response_body })
	end
	calls = run_example(nil, { "focus_gained" })
	http.request = saved_request
	assert_true(resumed, "resume must re-resolve rather than answer from the cache")
	assert_true(calls:find("analytics suspended (optional_processing_closed)", 1, true) ~= nil,
		"resume must close the analytics lane the new decision closes: " .. calls)
	assert_true(calls:find("crash reporting suspended (crash_profile_off)", 1, true) ~= nil,
		"resume must stop the crash lane the new decision closes: " .. calls)
	-- ⚠ AND IT MUST NOT WRITE A PLAYER DECISION. set_consent(false) records and
	-- persists an explicit denial and queues its receipt; crash.set_enabled
	-- persists an opt_out that outlives the launch. Nobody chose anything here
	-- — the policy changed. The only set_consent in this run is the one the
	-- placeholder notice produced, before the resume.
	assert_true(calls:find("crash.set_enabled", 1, true) == nil,
		"a policy closure must not persist a crash opt-out: " .. calls)
	assert_true(calls:find("sdk.shutdown", 1, true) ~= nil and calls:find("crash.shutdown", 1, true) ~= nil,
		"suspension is a shutdown, which writes no choice: " .. calls)
end

-- ⚠ A LITERAL SEARCH FOR THE KEY NAME IS BYPASSED BY ONE ESCAPE.
-- "operation_blocks" decodes to the same key, json.decode restores it,
-- and the raw-text search never saw it — so the scan has to unescape the key
-- before comparing, and skip every value whole so a nested key of the same
-- name is not mistaken for the top-level one.
local function test_an_escaped_key_cannot_hide_an_object()
	local escaped = {
		operation_blocks = '"operation\\u005fblocks"',
		prohibited_purposes = '"prohibited\\u005fpurposes"',
		signals_used = '"signals\\u005fused"',
	}
	for name, spelling in pairs(escaped) do
		reset()
		next_response_body = raw_field(spelling, "{}", { [name] = "__nil__" })
		local decision = prepare()
		assert_true(not decision.plan_used,
			name .. " spelled with an escape must not hide an object: " .. tostring(decision.reason))

		-- The control: the SAME escaped spelling with an ARRAY still parses,
		-- so the rule is about the container and not about the escape.
		reset()
		next_response_body = raw_field(spelling, "[]", { [name] = "__nil__" })
		assert_true(prepare().plan_used, name .. " spelled with an escape must still parse as a list")
	end

	-- ⚠ AND A NESTED KEY OF THE SAME NAME IS NOT THE TOP-LEVEL ONE. The scan
	-- skips each value whole; a scope object carrying its own "operation_blocks"
	-- would otherwise refuse a perfectly good plan.
	reset()
	local body = plan()
	next_response_body = body:gsub('"scope":{', '"scope":{"operation_blocks":{},', 1)
	local nested = prepare()
	-- ⚠ THE REASON IS THE CONTROL, NOT THE VERDICT. Since R14 every schema
	-- object has a closed key set, so this IS refused — but it must be refused
	-- as "scope carries an unknown key", never as "operation_blocks is a JSON
	-- object where the schema says a list". A scan that matched the name
	-- anywhere in the document would give the second answer.
	assert_true(not nested.plan_used, "an unknown key inside scope is refused")
	assert_true(nested.detail ~= nil and nested.detail:find("scope carries an unknown key", 1, true) ~= nil,
		"it must be refused as a scope member, not as a top-level list shape: "
			.. tostring(nested.detail))
end

-- ⚠ SECOND 60 IS NOT A LEAP SECOND UNLESS IT IS 23:59:60 ON AN ANNOUNCED DATE.
-- Accepting it anywhere normalised the timestamp arithmetically to the next
-- minute, quietly moving a plan's expiry.
local function test_second_sixty_is_refused()
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:60Z" })
	assert_true(not prepare().plan_used, "second 60 must not be normalised into the next minute")
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:59Z" })
	assert_true(prepare().plan_used, "second 59 is still a second")
end

-- ⚠ CACHE EXPIRY PROTECTS THE NEXT LOOKUP AND STOPS NOTHING THAT IS RUNNING.
-- A lane opened on a permissive plan would otherwise stay open indefinitely
-- while the app is foregrounded, until an unrelated trigger happened to fire.
local function test_the_example_revalidates_at_the_plans_deadline()
	reset()
	next_response_body = example_plan({
		regime = consent_policy.SOFT_OPT_OUT, crash_profile = consent_policy.CRASH_MINIMAL,
		max_age_seconds = 2,
	})
	local swapped = false
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url }
		-- Launch is 1, the post-notice re-resolution is 2, the deadline is 3.
		if #requests >= 3 then
			next_response_body = example_plan({
				regime = consent_policy.STRICT_OPT_IN, crash_profile = consent_policy.CRASH_OFF,
			})
			swapped = true
		end
		callback(nil, nil, { status = 200, response = next_response_body })
	end
	-- Three seconds of frames, past the two-second plan.
	local calls = run_example(nil, nil, { 1, 1, 1 })
	http.request = saved_request
	assert_true(swapped, "the deadline must re-resolve rather than answer from the cache")
	-- ⚠ SUSPENDED FIRST, then replaced. A lane whose plan has run out does not
	-- keep running while the replacement is fetched.
	assert_true(calls:find("analytics suspended (plan_expired)", 1, true) ~= nil,
		"the analytics lane must stop when its plan expires: " .. calls)
	assert_true(calls:find("crash reporting suspended (plan_expired)", 1, true) ~= nil,
		"the crash lane must stop when its plan expires: " .. calls)

	-- The control: inside the plan's life, nothing is suspended.
	reset()
	next_response_body = example_plan({
		regime = consent_policy.SOFT_OPT_OUT, crash_profile = consent_policy.CRASH_MINIMAL,
		max_age_seconds = 300,
	})
	calls = run_example(nil, nil, { 1, 1, 1 })
	assert_true(calls:find("suspended", 1, true) == nil,
		"a live plan must not be revalidated out from under its lanes: " .. calls)
end

-- ⚠ A GRANT BELONGS TO THE NOTICE THE PLAYER SAW. A new plan with a different
-- consent_text_version or presented_language means the running grant was given
-- against text nobody read, so processing stops and the notice is presented
-- again — closing on the policy's authority, reopening on the player's.
local function test_the_example_re_presents_when_the_notice_text_changes()
	for _, changed in ipairs({
		{ consent_text_version = "ff-v2.0" },
		{ presented_language = "de" },
	}) do
		reset()
		next_response_body = example_plan({
			regime = consent_policy.SOFT_OPT_OUT, crash_profile = consent_policy.CRASH_MINIMAL,
		})
		local saved_request = http.request
		http.request = function(url, method, callback, headers, body, options)
			requests[#requests + 1] = { url = url }
			if #requests >= 3 then
				local overrides = {
					regime = consent_policy.SOFT_OPT_OUT,
					crash_profile = consent_policy.CRASH_MINIMAL,
				}
				for key, value in pairs(changed) do
					overrides[key] = value
				end
				next_response_body = example_plan(overrides)
			end
			callback(nil, nil, { status = 200, response = next_response_body })
		end
		local calls = run_example(nil, { "focus_gained" }, { 0, 0 })
		http.request = saved_request
		assert_true(calls:find("analytics suspended (consent_text_changed)", 1, true) ~= nil,
			"a changed notice text must suspend the running grant: " .. calls)
		-- ⚠ AND THE CRASH LANE GOES WITH IT. A reporter left running under text
		-- nobody saw is the same defect as an analytics client left running
		-- under it.
		assert_true(calls:find("crash reporting suspended (consent_text_changed)", 1, true) ~= nil,
			"a changed notice text must suspend the crash lane too: " .. calls)
		-- And it comes back only through a NEW answer: two init calls, because
		-- the notice was presented a second time.
		local inits = 0
		for _ in calls:gmatch("sdk%.init") do
			inits = inits + 1
		end
		assert_equal(inits, 2, "the notice must be presented again and the lane restarted: " .. calls)
	end
end

-- ⚠ A VERDICT SAYS HOW LONG IT IS GOOD FOR, because cache expiry protects the
-- next lookup and stops nothing that is already running. Without this the host
-- cannot schedule the revalidation that closes a lane whose plan has run out.
local function test_a_verdict_carries_its_validity_window()
	reset()
	next_response_body = plan({ max_age_seconds = 7 })
	local fresh = prepare()
	assert_equal(fresh.valid_for_seconds, 7, "a fresh verdict must carry the shortest of its bounds")

	local served = prepare()
	assert_equal(#requests, 1, "the second call is a cache hit")
	assert_true(served.valid_for_seconds ~= nil and served.valid_for_seconds < 7,
		"a cache hit must count DOWN rather than restate the original window: "
			.. tostring(served.valid_for_seconds))

	-- A fallback established nothing that could expire, so it schedules nothing.
	reset()
	next_status = 500
	next_response_body = encode_value({ reason = "policy_unavailable" })
	assert_true(prepare().valid_for_seconds == nil, "a fallback carries no validity window")
end

-- ⚠ shutdown() CAN SAY "NOT YET", AND THE STATE HAS TO SURVIVE THAT. A crash
-- POST in flight makes shutdown return false, "pending"; clearing the flag
-- anyway loses the retry — final() skips it, and a later start would
-- initialise over a client that never finished.
local function test_a_pending_crash_shutdown_keeps_its_state()
	reset()
	crash_shutdown_pending = 1
	next_response_body = example_plan({
		regime = consent_policy.SOFT_OPT_OUT, crash_profile = consent_policy.CRASH_MINIMAL,
	})
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url }
		if #requests >= 3 then
			next_response_body = example_plan({
				regime = consent_policy.SOFT_OPT_OUT, crash_profile = consent_policy.CRASH_OFF,
			})
		end
		callback(nil, nil, { status = 200, response = next_response_body })
	end
	-- Resume closes the crash lane; its shutdown comes back pending once, and
	-- final() is what retries it.
	local calls = run_example(nil, { "focus_gained" }, nil, true)
	http.request = saved_request
	assert_true(calls:find("crash.shutdown:pending", 1, true) ~= nil,
		"the fixture must exercise a pending shutdown: " .. calls)
	assert_true(calls:find("crash reporting suspended", 1, true) == nil,
		"a pending shutdown is not a completed one: " .. calls)
	-- final() retried it, and this time it completed. Counted over the exact
	-- tokens, so "crash.shutdown:pending" is not mistaken for a completion.
	local pending, completed = 0, 0
	for token in (calls .. " | "):gmatch("(.-) | ") do
		if token == "crash.shutdown:pending" then
			pending = pending + 1
		elseif token == "crash.shutdown" then
			completed = completed + 1
		end
	end
	assert_equal(pending, 1, "one pending attempt: " .. calls)
	assert_equal(completed, 1, "final() must retry the pending shutdown until it completes: " .. calls)
end

-- ⚠ PRESENT-AND-NULL IS PRESENT. Lua has no null, so `"signature": null`
-- decodes to the same nil as an absent key — and this build refuses every
-- present signature precisely because it cannot check one.
local function test_a_null_signature_is_still_a_signature()
	reset()
	next_response_body = raw_field('"signature"', "null")
	local decision = prepare()
	assert_true(not decision.plan_used, "a null signature is not an absent one")
	assert_true(decision.optional_processing_closed, "and the verdict is closed")

	-- The control: with the key genuinely absent the same plan parses, so the
	-- rule is about presence rather than about the fixture.
	reset()
	next_response_body = plan()
	assert_true(prepare().plan_used, "an absent signature must still parse")
end

-- ⚠ A CLOCK THAT WENT BACKWARDS CANNOT AGE AN ENTRY. socket.gettime is
-- wall-clock: an NTP step or a bad RTC can put "now" before the moment the
-- entry was written, and then `until_at > at` stays true for as long as the
-- clock is wrong — an entry outliving its plan by however far the clock
-- slipped.
local function test_a_backwards_clock_invalidates_the_cache()
	reset()
	next_response_body = plan({ max_age_seconds = 300 })
	local first = prepare()
	assert_equal(#requests, 1)
	prepare()
	assert_equal(#requests, 1, "the control: a cache hit while the clock behaves")

	socket.now = socket.now - 60
	next_response_body = plan({ max_age_seconds = 300 })
	local after = prepare()
	assert_equal(#requests, 2, "a backwards clock must discard the entry, not serve it")
	assert_true(after.plan_used, "and the replacement is used: " .. tostring(after.reason))
	socket.now = 1000

	-- ⚠ AND NO SERVED WINDOW EVER EXCEEDS THE ONE THE RESOLVER GRANTED. The
	-- cap is defence in depth: while the regression check above stands, the
	-- only way remaining could exceed the ceiling is a clock earlier than the
	-- insertion, which is already discarded — so there is no mutant that kills
	-- the cap alone, and saying so is better than implying one.
	reset()
	next_response_body = plan({ max_age_seconds = 5 })
	assert_equal(prepare().valid_for_seconds, 5, "the fresh window is the plan's own")
	local served = prepare()
	assert_true(served.valid_for_seconds <= 5,
		"a served window must never exceed the ceiling: " .. tostring(served.valid_for_seconds))
end

-- ⚠ A RESTORED ANSWER IS NOT A NEW ONE. A policy suspension followed by a
-- revalidation restarts the client, and client.new reads the persisted consent
-- decision back — so calling set_consent again would re-persist a decision
-- nobody made twice and enqueue a second receipt, putting a policy change into
-- the consent trail as a player changing their mind.
local function test_a_restored_answer_writes_no_consent()
	reset()
	next_response_body = example_plan({ regime = consent_policy.SOFT_OPT_OUT, max_age_seconds = 2 })
	-- The plan does not change; only its life runs out, which suspends the
	-- lane and then restarts it from the standing answer.
	local calls = run_example(nil, nil, { 1, 1, 1 })
	assert_true(calls:find("analytics suspended (plan_expired)", 1, true) ~= nil,
		"the fixture must exercise a suspension: " .. calls)
	local restarts = 0
	for _ in calls:gmatch("sdk%.init") do
		restarts = restarts + 1
	end
	assert_true(restarts >= 2, "the lane must come back after the suspension: " .. calls)
	local writes = 0
	for _ in calls:gmatch("sdk%.set_consent") do
		writes = writes + 1
	end
	assert_equal(writes, 1, "only the newly completed notice may write consent: " .. calls)
end

-- ⚠ A PRESENT-AND-NULL LIST IS NOT AN ABSENT ONE, and for these three fields
-- it is worse than for the signature: a null roster of operation blocks
-- decodes to the same nil as no roster at all, and those blocks govern
-- transfer, age/capacity, localisation and safety — restrictions no consent
-- choice lifts.
local function test_a_null_list_is_not_an_absent_one()
	for _, name in ipairs({ "operation_blocks", "prohibited_purposes", "signals_used" }) do
		reset()
		next_response_body = raw_field('"' .. name .. '"', "null", { [name] = "__nil__" })
		local decision = prepare()
		assert_true(not decision.plan_used, name .. " present and null must not be used")
		assert_true(decision.optional_processing_closed, "and the verdict is closed")

		-- The control: genuinely absent still parses, so the rule is about
		-- presence rather than about the field being optional.
		reset()
		next_response_body = plan({ [name] = "__nil__" })
		assert_true(prepare().plan_used, name .. " genuinely absent must still parse")
	end
end

-- ⚠ THE FIELD NAMES ARE A CLOSED VOCABULARY TOO. Every other bounded value in
-- this module is checked against a closed set; the set of names was the one
-- that was not, so a plan could carry anything beside the fields we read and
-- still be used. A key we do not understand is a plan we cannot say we fully
-- read.
local function test_an_unknown_top_level_key_is_refused()
	reset()
	next_response_body = raw_field('"tenant_override"', '"other"')
	local decision = prepare()
	assert_true(not decision.plan_used, "an unknown top-level key must not be used")
	assert_true(decision.optional_processing_closed, "and the verdict is closed")

	-- The controls: every key the schema DOES have must still parse, or this
	-- rule would refuse the resolver's own output. Asked with the optional
	-- ones present, which are the easiest to forget in a roster.
	reset()
	next_response_body = plan({
		operation_blocks = { "transfer_review" },
		prohibited_purposes = { "advertising" },
		age_band = { vocabulary = "coarse.v1", band = "adult" },
	})
	assert_true(prepare().plan_used, "a plan using every optional schema field must parse")
end

-- ⚠ A DUPLICATE TOP-LEVEL KEY IS AMBIGUOUS AND THE DECODER RESOLVES IT
-- SILENTLY — last one wins. A body carrying both a strict and a permissive
-- spelling of the same field is not a plan with a value, it is two plans, and
-- this build does not get to pick.
local function test_a_duplicate_top_level_key_is_refused()
	reset()
	-- The fixture keeps its own "regime"; this adds a second, permissive one.
	next_response_body = raw_field('"regime"', '"' .. consent_policy.SOFT_OPT_OUT .. '"')
	local decision = prepare()
	assert_true(not decision.plan_used, "a duplicated key must not be used")
	assert_true(decision.regime == consent_policy.STRICT_OPT_IN,
		"and certainly not with the permissive spelling: " .. tostring(decision.regime))

	-- The same key spelled with an escape is the same key.
	reset()
	next_response_body = raw_field('"regi\\u006de"', '"' .. consent_policy.SOFT_OPT_OUT .. '"')
	assert_true(not prepare().plan_used, "an escaped duplicate is still a duplicate")
end

-- ⚠ A CLOCK THAT MOVED BACKWARDS WHILE THE REQUEST WAS IN FLIGHT makes every
-- judgement below it meaningless in the permissive direction: the deadline,
-- the expiry and the cache lifetime are all comparisons against the arrival
-- reading, and an earlier one makes a plan look fresher and an entry live
-- longer.
local function test_a_clock_rollback_during_the_request_is_refused()
	reset()
	next_response_body = plan()
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url }
		socket.now = socket.now - 30
		callback(nil, nil, { status = 200, response = next_response_body })
	end
	local decision, calls = prepare()
	http.request = saved_request
	socket.now = 1000
	assert_equal(calls, 1, "exactly one callback")
	assert_equal(decision.reason, "clock_regressed", "a rollback in flight is refused by name")
	assert_true(not decision.plan_used, "and no plan is used")
	assert_true(decision.optional_processing_closed, "and the verdict is closed")

	-- And it is refused BEFORE anything is cached: the next call goes to the
	-- wire rather than being served a plan that was never accepted.
	next_response_body = plan()
	prepare()
	assert_equal(#requests, 2, "a refused response must not have been cached")
end

-- ⚠ A STRICT FALLBACK IS NOT A NOTICE CHANGE. A fallback carries no
-- consent_text_version at all, so comparing the standing answer against one
-- read every outage as "the text changed" and threw away an answer the player
-- really did give — meaning the next good plan asked them again for no reason.
-- A fallback CLOSES; it does not erase.
local function test_a_fallback_does_not_erase_the_standing_answer()
	reset()
	next_response_body = example_plan({ regime = consent_policy.SOFT_OPT_OUT })
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url }
		if #requests == 3 then
			-- The resume resolution fails: a fallback, carrying no plan.
			callback(nil, nil, { status = 500, response = encode_value({ reason = "policy_unavailable" }) })
			return
		end
		callback(nil, nil, { status = 200, response = next_response_body })
	end
	-- Resume once into the outage, then again into a good plan.
	local calls = run_example(nil, { "focus_gained", "focus_gained" })
	http.request = saved_request

	assert_true(calls:find("strict fallback", 1, true) ~= nil,
		"the fixture must produce a fallback: " .. calls)
	assert_true(calls:find("consent_text_changed", 1, true) == nil,
		"an outage is not a notice change: " .. calls)
	assert_true(calls:find("analytics suspended (optional_processing_closed)", 1, true) ~= nil,
		"a fallback still closes the lane: " .. calls)

	-- The answer survived: the lane comes back WITHOUT a second notice, so
	-- exactly one consent write across the whole run.
	local writes = 0
	for _ in calls:gmatch("sdk%.set_consent") do
		writes = writes + 1
	end
	assert_equal(writes, 1, "the standing answer must survive an outage: " .. calls)
	local inits = 0
	for _ in calls:gmatch("sdk%.init") do
		inits = inits + 1
	end
	assert_true(inits >= 2, "and the lane must come back after the outage: " .. calls)
end

-- ⚠ NO FIELD IN THIS SCHEMA IS NULLABLE, AND THAT IS ONE RULE. Lua has no
-- null, so every present-and-null key decodes to exactly the nil an absent key
-- decodes to — and this module reads absence as a MEANING everywhere: absent
-- signature is unsigned, absent objection requirement stands, absent list is
-- no restrictions. Asked over the whole schema rather than field by field,
-- because patching them one at a time is how the next added field arrives with
-- the same hole.
local function test_no_schema_field_is_nullable()
	local nullable = {
		"regime", "crash_profile", "server_analytics",
		"server_analytics_objection_required", "prohibited_purposes",
		"operation_blocks", "policy_version", "consent_text_version",
		"presented_language", "scope", "signals_used", "age_band",
		"expires_at", "max_age_seconds", "signature",
	}
	for _, name in ipairs(nullable) do
		reset()
		next_response_body = raw_field('"' .. name .. '"', "null", { [name] = "__nil__" })
		local decision = prepare()
		assert_true(not decision.plan_used, name .. " present and null must not be used")
		assert_true(decision.optional_processing_closed, name .. " must close optional processing")
	end

	-- The control: the same plan with every one of those keys carrying a real
	-- value parses, so the rule is about null rather than about the roster.
	reset()
	next_response_body = plan({
		operation_blocks = { "transfer_review" },
		prohibited_purposes = { "advertising" },
		age_band = { vocabulary = "coarse.v1", band = "adult" },
	})
	assert_true(prepare().plan_used, "a plan with every schema field populated must parse")
end

-- ⚠ AND A null ELEMENT INSIDE A LIST. Lua drops it: the decoded array comes
-- back one entry SHORTER, so a roster of three operation blocks with the
-- middle one nulled reads as a roster of two, with nothing anywhere saying a
-- third was sent.
local function test_a_null_list_entry_is_refused()
	for _, name in ipairs({ "operation_blocks", "prohibited_purposes", "signals_used" }) do
		reset()
		next_response_body = raw_field('"' .. name .. '"', '["a",null,"b"]', { [name] = "__nil__" })
		assert_true(not prepare().plan_used, name .. " with a null entry must not be used")
	end
	-- The control: the same lists without the null still parse.
	reset()
	next_response_body = plan({
		operation_blocks = { "transfer_review", "age_capacity" },
		prohibited_purposes = { "advertising" },
	})
	assert_true(prepare().plan_used, "a dense list must still parse")
end

-- ⚠ THE PLAN'S age_band WAS NEVER CHECKED. validate_context checks the band
-- the CALLER sends; nothing checked the one the resolver sends back, so a plan
-- could echo an age_band of any shape at all and be used.
local function test_the_plans_age_band_is_shape_checked()
	for _, band in ipairs({
		{ vocabulary = "coarse.v1" },
		{ band = "adult" },
		{ vocabulary = "coarse.v1", band = string.rep("x", 33) },
		{ vocabulary = "", band = "adult" },
	}) do
		reset()
		next_response_body = plan({ age_band = band })
		assert_true(not prepare().plan_used, "a malformed age_band must not be used")
	end
	reset()
	next_response_body = plan({ age_band = { vocabulary = "coarse.v1", band = "adult" } })
	assert_true(prepare().plan_used, "a well-formed age_band must parse")
end

-- ⚠ AN ERROR BODY IS AN ERROR ENVELOPE, NOT A PLAN. Running the plan-key
-- allowlist over it refused a perfectly well-formed {"reason": ...} for
-- carrying a key that is not a plan field — a regression the allowlist
-- introduced, which turned every resolver refusal into "unreadable" and lost
-- the reason the resolver gave.
local function test_an_error_envelope_keeps_its_reason()
	reset()
	next_status = 503
	next_response_body = encode_value({ reason = "policy_unavailable" })
	local decision = prepare()
	assert_equal(decision.reason, "policy_unavailable", "the resolver's reason must survive")
	assert_true(not decision.plan_used, "and no plan is used")
	assert_true(decision.optional_processing_closed, "and the verdict is closed")

	-- ⚠ BUT NOT WHATEVER ARRIVES. decision.reason travels into a caller's
	-- control flow and its log lines, so an unrecognisable one is reported as
	-- the generic reason rather than echoed.
	for _, hostile in ipairs({ "Policy Unavailable", string.rep("x", 65), "reason\ninjected", 42 }) do
		reset()
		next_status = 500
		next_response_body = encode_value({ reason = hostile })
		assert_equal(prepare().reason, "policy_unavailable",
			"an unrecognisable reason must not be echoed: " .. tostring(hostile))
	end
end

-- ⚠ init AND set_consent BOTH RETURN false, err, AND THE EXAMPLE IGNORED BOTH.
-- A lane marked running on a client that was never built is one final() will
-- try to shut down; a session started on a grant that was never recorded is
-- the exact ordering the consent outbox exists to prevent.
local function test_the_example_notices_a_failed_write()
	-- (a) A failed init must not mark the lane running.
	reset()
	sdk_init_failures = 1
	next_response_body = example_plan({ regime = consent_policy.SOFT_OPT_OUT })
	local calls = run_example(nil, nil, nil, true)
	assert_true(calls:find("init failed", 1, true) ~= nil, "the fixture must fail init: " .. calls)
	assert_true(calls:find("sdk.set_consent", 1, true) == nil,
		"a failed init must not be followed by a consent write: " .. calls)
	assert_true(calls:find("sdk.shutdown", 1, true) == nil,
		"and final() must not shut down a client that was never built: " .. calls)

	-- (b) A refused consent write is OWED: the answer stays pending and the
	-- next trigger retries it.
	reset()
	sdk_consent_refusals = 1
	next_response_body = example_plan({ regime = consent_policy.SOFT_OPT_OUT })
	calls = run_example(nil, { "focus_gained" })
	assert_true(calls:find("consent not recorded", 1, true) ~= nil,
		"the fixture must refuse the first write: " .. calls)
	local writes = 0
	for _ in calls:gmatch("sdk%.set_consent") do
		writes = writes + 1
	end
	assert_equal(writes, 2, "an owed consent write must be retried on the next trigger: " .. calls)
end

-- ⚠ A VERDICT WITH NO LIFE IS NOT RUNNABLE, and scheduling by it directly is a
-- spin: max_age_seconds = 0 makes valid_for_seconds 0, so the example
-- re-resolved every single frame — a flood against the resolver dressed up as
-- diligence.
local function test_a_zero_window_does_not_spin()
	reset()
	next_response_body = example_plan({ regime = consent_policy.SOFT_OPT_OUT, max_age_seconds = 0 })
	-- Ten seconds of frames. The floor is thirty, so nothing may re-resolve.
	local calls = run_example(nil, nil, { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 })
	assert_true(#requests <= 2, "a zero window must not re-resolve per frame: " .. #requests .. " requests")
	assert_true(calls:find("no validity window; no lane started", 1, true) ~= nil,
		"a verdict with no life must say so: " .. calls)
	assert_true(calls:find("sdk.init", 1, true) == nil and calls:find("crash.init", 1, true) == nil,
		"and must run no lane at all: " .. calls)

	-- The control: the same plan with a real window DOES run, so the rule is
	-- about the zero and not about the example refusing everything.
	reset()
	next_response_body = example_plan({ regime = consent_policy.SOFT_OPT_OUT, max_age_seconds = 300 })
	calls = run_example(nil, nil, { 1, 1, 1 })
	assert_true(calls:find("sdk.init", 1, true) ~= nil, "a live window must run the lane: " .. calls)
end

-- ⚠ A DUPLICATE KEY IS AMBIGUOUS AT EVERY DEPTH. The root walk refused them
-- and the nested walk skipped values whole, so a scope carrying workspace_id
-- twice — once the caller's, once another tenant's — was decided silently by
-- the decoder, last one wins, and then compared against the caller's own scope
-- and passed.
local function test_nested_duplicate_keys_are_refused()
	local cases = {
		{ "scope", '"workspace_id":"ws-other",', '"scope":{' },
		{ "age_band", '"band":"minor",', '"age_band":{' },
		{ "a signal", '"name":"other",', '"signals_used":[{' },
	}
	for _, case in ipairs(cases) do
		reset()
		local body = plan({ age_band = { vocabulary = "coarse.v1", band = "adult" } })
		-- The duplicate is spliced INSIDE the nested object, so the root walk
		-- sees one occurrence of the outer key and this is genuinely nested.
		next_response_body = body:gsub(case[3]:gsub("%p", "%%%0"), case[3] .. case[2], 1)
		assert_true(next_response_body ~= body, "the fixture must carry " .. case[1])
		local decision = prepare()
		assert_true(not decision.plan_used,
			"a duplicate key inside " .. case[1] .. " must not be used: " .. tostring(decision.reason))
	end

	-- The control: the same nested objects spelled once each still parse.
	reset()
	next_response_body = plan({ age_band = { vocabulary = "coarse.v1", band = "adult" } })
	assert_true(prepare().plan_used, "well-formed nested objects must parse")
end

-- ⚠ THE CALLER'S FIELD NAMES ARE A CLOSED SET TOO, and the shape this takes in
-- practice is a typo: `age_bnad` is silently no age band at all, so the request
-- goes out claiming this player has none.
local function test_an_unknown_context_field_is_refused()
	for _, override in ipairs({
		{ age_bnad = { vocabulary = "coarse.v1", band = "adult" } },
		{ workspace = "ws-synthetic" },
		{ user_id = "player-1" },
	}) do
		reset()
		next_response_body = plan()
		local decision, calls = prepare(context(override))
		assert_equal(calls, 1, "exactly one callback")
		assert_equal(#requests, 0, "an unknown context field must cost zero requests")
		assert_equal(decision.reason, "invalid_request")
		assert_true(decision.optional_processing_closed, "and the verdict is closed")
	end

	-- The control: every field the context DOES have must still be accepted,
	-- including the optional ones, or this rule would refuse valid callers.
	reset()
	next_response_body = plan()
	assert_true(prepare(context({
		store = "steam",
		age_band = { vocabulary = "coarse.v1", band = "adult" },
	})).plan_used, "a context using every optional field must be accepted")
end

-- ⚠ THE NULLABILITY RULE HAS TO REACH INSIDE THE LIST, NOT STOP AT ITS NAME.
--
-- Being honest about what this adds: a null `name`, a null `available`, or a
-- null `reason` on an UNAVAILABLE signal were already refused — by the name
-- bound, the boolean check and the needs-a-reason rule. They were refused BY
-- LUCK, in the sense that nothing was checking the thing that was actually
-- wrong. The cases below are the ones nothing reached at all: a field the
-- entry does not need, nulled.
local function test_a_null_field_inside_a_signal_is_refused()
	local cases = {
		-- An AVAILABLE signal needs no reason, so a null one was simply
		-- ignored: the plan said "reason: null" and was used as though it had
		-- not mentioned it.
		{ "a null reason on an available signal",
			'[{"name":"server_country","available":true,"reason":null}]' },
		-- And any other field the entry carries. Nothing validates names
		-- inside a signal entry, so this was accepted outright.
		{ "a null field the entry does not need",
			'[{"name":"server_country","available":false,"reason":"source_unavailable","source":null}]' },
		-- ⚠ THE SECOND ENTRY IS CHECKED TOO, or the rule would only ever see
		-- the first signal a plan happens to list.
		{ "a null in the SECOND entry",
			'[{"name":"server_country","available":false,"reason":"source_unavailable"},' ..
			'{"name":"store_region","available":true,"reason":null}]' },
	}
	for _, case in ipairs(cases) do
		reset()
		next_response_body = raw_field('"signals_used"', case[2], { signals_used = "__nil__" })
		local decision = prepare()
		assert_true(not decision.plan_used,
			case[1] .. " must not be used: " .. tostring(decision.reason))
		assert_true(decision.optional_processing_closed, "and the verdict is closed")
	end

	-- The controls: the same entries without the nulls still parse — an
	-- available signal with no reason mentioned at all, and two unavailable
	-- ones with reasons.
	reset()
	next_response_body = plan({ signals_used = { { name = "server_country", available = true } } })
	assert_true(prepare().plan_used, "an available signal that mentions no reason must parse")
	reset()
	next_response_body = plan({ signals_used = {
		{ name = "server_country", available = false, reason = "source_unavailable" },
		{ name = "store_region", available = false, reason = "source_not_permitted" },
	} })
	assert_true(prepare().plan_used, "well-formed signal entries must parse")
end

-- ⚠ A reason IS CHECKED WHEREVER IT APPEARS. The closed vocabulary was
-- enforced on the branch that REQUIRES a reason and nowhere else, so an
-- AVAILABLE signal could carry any string at all — and signals_used is a
-- provenance record, so an unreadable reason on it is a claim about how the
-- resolver reached its answer that nothing checked.
local function test_a_signal_reason_is_always_from_the_vocabulary()
	for _, signal in ipairs({
		{ name = "server_country", available = true, reason = "because" },
		{ name = "server_country", available = true, reason = "SOURCE_UNAVAILABLE" },
		{ name = "server_country", available = false, reason = "because" },
	}) do
		reset()
		next_response_body = plan({ signals_used = { signal } })
		assert_true(not prepare().plan_used, "a reason outside the vocabulary must not be used")
	end

	-- The controls: every member of the vocabulary parses on an available
	-- signal and on an unavailable one, and an available signal may still
	-- mention no reason at all.
	for _, reason in ipairs({ "source_not_permitted", "source_unavailable", "not_enabled_in_release" }) do
		for _, available in ipairs({ true, false }) do
			reset()
			next_response_body = plan({
				signals_used = { { name = "server_country", available = available, reason = reason } },
			})
			assert_true(prepare().plan_used, reason .. " must parse (available=" .. tostring(available) .. ")")
		end
	end
	reset()
	next_response_body = plan({ signals_used = { { name = "server_country", available = true } } })
	assert_true(prepare().plan_used, "an available signal may mention no reason")
end

-- ⚠ THE NESTED age_band KEY SET IS CLOSED TOO. An object whose names are
-- unchecked is the top-level hole one level down: a band could carry anything
-- beside the two fields we read and still be used, and a band is the only age
-- shape that travels.
local function test_the_age_bands_keys_are_closed()
	reset()
	next_response_body = plan({
		age_band = { vocabulary = "coarse.v1", band = "adult", precise_age = "37" },
	})
	assert_true(not prepare().plan_used, "an unknown key inside age_band must not be used")

	reset()
	next_response_body = plan({ age_band = { vocabulary = "coarse.v1", band = "adult" } })
	assert_true(prepare().plan_used, "the two schema fields alone must parse")
end

-- ⚠ THE PACKAGED SKILL'S SNIPPETS ARE CODE A CUSTOMER RUNS. The skill is what
-- an integrator's assistant reads, so a snippet that does not even parse is a
-- broken integration shipped with confidence. Every ```lua block in it is
-- compiled here.
--
-- HONEST LIMIT: this compiles them. It cannot run the policy snippet — that
-- one is deliberately a fragment, with `<YOUR-...>` placeholders and a
-- `present_your_consent_notice` the integrator supplies — so its SEMANTICS
-- were checked by reading it against examples/minimal/main.script line by
-- line, not by execution. The executable statement of the contract remains the
-- example, which this suite does run.
local function test_the_packaged_skill_snippets_compile()
	local source = io.open(".claude/skills/shardpilot-defold-integration/SKILL.md")
	assert_true(source ~= nil, "the packaged skill must exist")
	local text = source:read("*a")
	source:close()
	local compile = loadstring or load
	local blocks = 0
	for block in text:gmatch("```lua\n(.-)```") do
		blocks = blocks + 1
		local chunk, err = compile(block)
		assert_true(chunk ~= nil,
			"a lua block in the packaged skill does not compile: " .. tostring(err))
	end
	assert_true(blocks >= 5, "the skill must still carry its snippets, found " .. blocks)
end

-- ⚠ THE CONTEXT'S age_band GETS THE SAME CLOSED KEY SET THE RESPONSE'S DOES.
-- It was closed on the band the resolver sends back and left open on the one
-- the caller sends — and this is the side that TRAVELS: an unread member here
-- is an age claim about this player that nothing looked at.
local function test_the_context_age_bands_keys_are_closed()
	reset()
	next_response_body = plan()
	local decision, calls = prepare(context({
		age_band = { vocabulary = "coarse.v1", band = "adult", date_of_birth = "1989-04-02" },
	}))
	assert_equal(calls, 1, "exactly one callback")
	assert_equal(#requests, 0, "an unknown age_band field must cost zero requests")
	assert_equal(decision.reason, "invalid_request")
	assert_true(decision.optional_processing_closed, "and the verdict is closed")

	-- The control: the two schema fields alone are still accepted and reach
	-- the wire.
	reset()
	next_response_body = plan()
	assert_true(prepare(context({ age_band = { vocabulary = "coarse.v1", band = "adult" } })).plan_used,
		"a well-formed context age_band must be accepted")
	assert_equal(#requests, 1, "and must reach the wire")
end

-- ⚠ identify CAN REFUSE, and the example ignored it. Under Mode B a switch
-- while the previous identity still has undelivered events returns
-- false, "events_pending" — recording a consent decision after that would
-- attach it to an identity the client did not accept.
local function test_the_example_stops_when_identify_refuses()
	reset()
	sdk_identify_refusals = 1
	next_response_body = example_plan({ regime = consent_policy.SOFT_OPT_OUT })
	local calls = run_example(nil, nil, nil, true)
	assert_true(calls:find("identify refused", 1, true) ~= nil,
		"the fixture must refuse identify: " .. calls)
	assert_true(calls:find("sdk.set_consent", 1, true) == nil,
		"no consent may be recorded for an identity the client refused: " .. calls)
	assert_true(calls:find("sdk.session_start", 1, true) == nil,
		"and no session may start: " .. calls)
	-- The client WAS built, so teardown still owes it a shutdown.
	assert_true(calls:find("sdk.shutdown", 1, true) ~= nil,
		"an initialised client must still be shut down: " .. calls)

	-- The control: with identify accepted, the same run records consent.
	reset()
	next_response_body = example_plan({ regime = consent_policy.SOFT_OPT_OUT })
	calls = run_example(nil, nil, nil, true)
	assert_true(calls:find("sdk.set_consent", 1, true) ~= nil,
		"an accepted identify must reach the consent write: " .. calls)
end

-- ⚠ EVERY OBJECT IN THE SCHEMA HAS AN EXACT KEY SET. The root was closed in
-- R8, age_band in R12, the context's age_band in R13 — the same finding
-- arriving at one door after another, which is what a roster is for. This
-- asks it of all four at once, and of the shape that would otherwise slip
-- past: an unknown member spelled `null`, which decodes to the same nil an
-- absent one does and would vanish before any decoded-side check could see it.
local function test_every_schema_object_has_a_closed_key_set()
	local objects = {
		{
			what = "the plan root",
			build = function(raw)
				return raw_field('"tenant_override"', raw)
			end,
		},
		{
			what = "scope",
			build = function(raw)
				local body = plan()
				return (body:gsub('"scope":{', '"scope":{"tenant_override":' .. raw .. ",", 1))
			end,
		},
		{
			what = "age_band",
			build = function(raw)
				local body = plan({ age_band = { vocabulary = "coarse.v1", band = "adult" } })
				return (body:gsub('"age_band":{', '"age_band":{"tenant_override":' .. raw .. ",", 1))
			end,
		},
		{
			what = "a signal entry",
			build = function(raw)
				return raw_field('"signals_used"',
					'[{"name":"server_country","available":false,"reason":"source_unavailable",' ..
					'"tenant_override":' .. raw .. "}]", { signals_used = "__nil__" })
			end,
		},
	}
	-- A real value, and the null that would otherwise disappear in decoding.
	for _, raw in ipairs({ '"other"', "null" }) do
		for _, object in ipairs(objects) do
			reset()
			next_response_body = object.build(raw)
			local decision = prepare()
			assert_true(not decision.plan_used,
				"an unknown key in " .. object.what .. " (" .. raw .. ") must not be used: "
					.. tostring(decision.reason))
			assert_true(decision.optional_processing_closed, "and the verdict is closed")
		end
	end

	-- The control: every object spelled with exactly its own members parses,
	-- so the roster refuses the unknown rather than refusing nesting.
	reset()
	next_response_body = plan({
		age_band = { vocabulary = "coarse.v1", band = "adult" },
		signals_used = { { name = "server_country", available = false, reason = "source_unavailable" } },
		operation_blocks = { "transfer_review" },
		prohibited_purposes = { "advertising" },
	})
	assert_true(prepare().plan_used, "every schema object spelled correctly must parse")
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
	test_expiry_is_enforced_before_use_and_before_caching,
	test_objection_required_must_be_a_json_boolean,
	test_an_invalidated_request_cannot_answer,
	test_a_json_object_is_not_an_empty_list,
	test_the_cache_is_scoped_to_the_whole_context,
	test_an_invalid_endpoint_is_an_invalid_request,
	test_an_empty_signature_is_still_a_signature,
	test_the_url_predicate_is_a_verbatim_copy,
	test_a_signal_must_state_its_availability_as_a_boolean,
	test_a_returned_decision_is_a_copy,
	test_the_published_example_branches_on_the_decision,
	test_an_older_response_cannot_overwrite_a_newer_one,
	test_an_encoder_failure_still_answers,
	test_a_lost_transport_beats_a_cached_permission,
	test_the_clock_falls_back_to_os_time,
	test_an_empty_object_is_not_an_empty_list,
	test_an_offset_needs_its_colon,
	test_the_example_re_resolves_after_the_answer,
	test_the_example_closes_lanes_on_resume,
	test_an_escaped_key_cannot_hide_an_object,
	test_second_sixty_is_refused,
	test_the_example_revalidates_at_the_plans_deadline,
	test_the_example_re_presents_when_the_notice_text_changes,
	test_a_verdict_carries_its_validity_window,
	test_a_pending_crash_shutdown_keeps_its_state,
	test_a_null_signature_is_still_a_signature,
	test_a_backwards_clock_invalidates_the_cache,
	test_a_restored_answer_writes_no_consent,
	test_a_null_list_is_not_an_absent_one,
	test_an_unknown_top_level_key_is_refused,
	test_a_duplicate_top_level_key_is_refused,
	test_a_clock_rollback_during_the_request_is_refused,
	test_a_fallback_does_not_erase_the_standing_answer,
	test_no_schema_field_is_nullable,
	test_a_null_list_entry_is_refused,
	test_the_plans_age_band_is_shape_checked,
	test_an_error_envelope_keeps_its_reason,
	test_the_example_notices_a_failed_write,
	test_a_zero_window_does_not_spin,
	test_nested_duplicate_keys_are_refused,
	test_an_unknown_context_field_is_refused,
	test_a_null_field_inside_a_signal_is_refused,
	test_a_signal_reason_is_always_from_the_vocabulary,
	test_the_age_bands_keys_are_closed,
	test_the_packaged_skill_snippets_compile,
	test_the_context_age_bands_keys_are_closed,
	test_the_example_stops_when_identify_refuses,
	test_every_schema_object_has_a_closed_key_set,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold consent-policy tests passed")
