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
local experiments = require "shardpilot.experiments"
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

-- A Mode A (publishable-key) config with the experiment-assignment surface
-- enabled — the default shape for these tests.
local function config(overrides)
	local out = {
		ingest_url = "http://localhost:8080",
		experiments_url = "http://localhost:28090",
		experiments_app_key = "app-test",
		experiments_environment_key = "develop",
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

-- The same config with the experiments surface absent (the overrides merge
-- cannot express nil).
local function unopted_config()
	local out = config()
	out.experiments_url = nil
	out.experiments_app_key = nil
	out.experiments_environment_key = nil
	return out
end

local test_sfk = "sfk1_" .. string.rep("0123456789abcdef", 4)
local test_assignment_key = "asgn_" .. string.rep("ab", 16)
local sentinel_text = "experiment real-subject assignment is disabled"

-- An assigned client_id-unit 200 body; `overrides` merge over the defaults.
local function assigned_body(overrides)
	local body = {
		app_key = "app-test",
		environment_key = "develop",
		experiment_key = "exp-armor",
		version = 3,
		assigned = true,
		assignment_key = test_assignment_key,
		variant_key = "variant-b",
		variant_payload = { armor = 2 },
		subject_fact_key = test_sfk,
		boundary = { assignment_unit = "client_id", subject_key_kind = "client_id_pseudonymous" },
	}
	for key, value in pairs(overrides or {}) do
		body[key] = value
	end
	return json.encode(body)
end

-- A not-assigned client_id-unit 200 body; `reason` nil models the
-- deterministic traffic gate (the member is omitted entirely).
local function unassigned_body(reason)
	local body = {
		experiment_key = "exp-armor",
		version = 3,
		assigned = false,
		assignment_key = test_assignment_key,
		subject_fact_key = test_sfk,
		boundary = { assignment_unit = "client_id" },
	}
	body.reason = reason
	return json.encode(body)
end

-- Drive one fetch to completion (the http stub answers synchronously) and
-- return the result the callback received.
local function fetch(client, experiment_key)
	local result = nil
	client:fetch_experiment_assignment(experiment_key or "exp-armor", function(value)
		result = value
	end)
	assert_true(result ~= nil, "the fetch callback must have been invoked")
	return result
end

local function last_request()
	return requests[#requests]
end

local function requests_to(url_part)
	local count = 0
	for i = 1, #requests do
		if requests[i].url:find(url_part, 1, true) then
			count = count + 1
		end
	end
	return count
end

-- ── grammar validators ────────────────────────────────────────────────────────

local function test_spcid_grammar()
	assert_true(experiments.valid_spcid("spcid_" .. string.rep("a", 20)), "20-char suffix is valid")
	assert_true(experiments.valid_spcid("spcid_" .. string.rep("a", 64)), "64-char suffix is valid")
	assert_true(experiments.valid_spcid("spcid_AZaz09_-AZaz09_-AZaz"), "the full character set is valid")
	assert_true(experiments.valid_spcid("spcid_0198c600-0000-7abc-9def-0123456789ab"),
		"an spcid_ + uuid_v7 spelling is valid")
	assert_equal(experiments.valid_spcid("spcid_" .. string.rep("a", 19)), false, "19-char suffix is too short")
	assert_equal(experiments.valid_spcid("spcid_" .. string.rep("a", 65)), false, "65-char suffix is too long")
	assert_equal(experiments.valid_spcid("spcid_" .. string.rep("a", 19) .. "."), false, "a dot is outside the set")
	assert_equal(experiments.valid_spcid("spcid " .. string.rep("a", 20)), false, "the prefix must be exact")
	assert_equal(experiments.valid_spcid("SPCID_" .. string.rep("a", 20)), false, "the prefix is case-sensitive")
	assert_equal(experiments.valid_spcid(string.rep("a", 26)), false, "the prefix is required")
	assert_equal(experiments.valid_spcid(""), false)
	assert_equal(experiments.valid_spcid(nil), false)
	assert_equal(experiments.valid_spcid(42), false)
end

local function test_subject_fact_key_grammar()
	assert_true(experiments.valid_subject_fact_key(test_sfk), "64 lowercase hex chars are valid")
	assert_equal(experiments.valid_subject_fact_key("sfk1_" .. string.rep("0", 63)), false, "63 chars is short")
	assert_equal(experiments.valid_subject_fact_key("sfk1_" .. string.rep("0", 65)), false, "65 chars is long")
	assert_equal(experiments.valid_subject_fact_key("sfk1_" .. string.rep("A", 64)), false, "uppercase hex is invalid")
	assert_equal(experiments.valid_subject_fact_key("sfk2_" .. string.rep("0", 64)), false, "the prefix is pinned")
	assert_equal(experiments.valid_subject_fact_key(nil), false)
end

-- ── URL and scope building ────────────────────────────────────────────────────

local function test_build_url_escapes_query_values()
	assert_equal(
		experiments.build_url("http://localhost:28090/", "app 1", "env&dev", "exp=a", "spcid_" .. string.rep("a", 20)),
		"http://localhost:28090/api/cp/v1/runtime/experiments/assignment"
			.. "?app_key=app%201&environment_key=env%26dev&experiment_key=exp%3Da"
			.. "&subject_key=spcid_" .. string.rep("a", 20))
end

local function test_build_scope_keeps_distinct_tuples_distinct()
	local subject = "spcid_" .. string.rep("a", 20)
	assert_true(
		experiments.build_scope("app", "env-a", "exp", subject, "http://localhost:28090")
			~= experiments.build_scope("app", "env", "a-exp", subject, "http://localhost:28090"),
		"shifting one identifier boundary must not collide two scopes")
	assert_true(
		experiments.build_scope("app", "env", "exp-a", subject, "http://localhost:28090")
			~= experiments.build_scope("app", "env", "exp-b", subject, "http://localhost:28090"),
		"two experiments must never share one scope")
	assert_true(
		experiments.build_scope("app", "env", "exp", "spcid_" .. string.rep("a", 20), "http://localhost:28090")
			~= experiments.build_scope("app", "env", "exp", "spcid_" .. string.rep("b", 20), "http://localhost:28090"),
		"two subjects must never share one scope")
	assert_equal(
		experiments.build_scope("app", "env", "exp", subject, "http://localhost:28090"),
		experiments.build_scope("app", "env", "exp", subject, "http://localhost:28090/"),
		"a trailing slash must not split one endpoint into two scopes")
end

-- ── configuration validation ──────────────────────────────────────────────────

local function test_config_validation()
	reset()
	local invalid_cases = {
		{ { experiments_url = 42 }, "invalid_experiments_url" },
		{ { experiments_url = "" }, "invalid_experiments_url" },
		{ { experiments_url = "https://cp.example.com/api/cp/v1" }, "invalid_experiments_url" },
		{ { experiments_url = "http://example.com" }, "invalid_experiments_url" },
		{ { experiments_app_key = "" }, "experiments_app_key_required" },
		{ { experiments_environment_key = 7 }, "experiments_environment_key_required" },
	}
	for _, case in ipairs(invalid_cases) do
		local client, err = sdk.new(config(case[1]))
		assert_nil(client, "config must be rejected")
		assert_equal(err, case[2])
	end
	-- An absent key (not just an empty one) is rejected too — the overrides
	-- merge cannot express nil, so these two build the config directly.
	local missing_app = config()
	missing_app.experiments_app_key = nil
	local client, err = sdk.new(missing_app)
	assert_nil(client)
	assert_equal(err, "experiments_app_key_required")
	local missing_env = config()
	missing_env.experiments_environment_key = nil
	client, err = sdk.new(missing_env)
	assert_nil(client)
	assert_equal(err, "experiments_environment_key_required")

	-- The assignment endpoint authenticates with the publishable api_key
	-- only: Mode B alone cannot carry the surface...
	local mode_b_only = config({
		token_provider = function(callback)
			callback("token-b", nil, nil)
		end,
	})
	mode_b_only.api_key = nil
	local mode_b_client, mode_b_err = sdk.new(mode_b_only)
	assert_nil(mode_b_client)
	assert_equal(mode_b_err, "experiments_api_key_required")

	-- ...while Mode B WITH an api_key becomes a valid split exactly like the
	-- remote-config exception: the minted token keeps the ingest Bearer, the
	-- api_key authenticates the assignment fetch.
	local split_client = assert(sdk.new(config({
		token_provider = function(callback)
			callback("token-b", nil, nil)
		end,
	})))
	assert_true(split_client.experiments ~= nil, "the split-credential config must construct")
end

-- ── pure classification (M.apply) ─────────────────────────────────────────────

local function test_apply_transients_serve_cache_and_permanents_fail()
	reset()
	local cache = { body = assigned_body(), fetched_at_ms = 1000 }
	local transient_cases = {
		{ { status = 0 }, "http_0" },
		{ nil, "http_0" },
		{ { status = 408 }, "transient_408" },
		{ { status = 429 }, "transient_429" },
		{ { status = 500 }, "transient_500" },
		{ { status = 503, response = '{"error":"kill switch state unavailable"}' }, "transient_503" },
	}
	for _, case in ipairs(transient_cases) do
		local result, new_cache, authoritative, drop, refused = experiments.apply(cache, case[1], 2000, "exp-armor")
		assert_true(result.ok, case[2] .. " must serve the cache")
		assert_equal(result.from_cache, true)
		assert_equal(result.error, case[2])
		assert_equal(result.variant_key, "variant-b")
		assert_nil(new_cache)
		assert_equal(authoritative, false, case[2] .. " must not settle the fence")
		assert_equal(drop, false)
		assert_equal(refused, false)

		local missing = experiments.apply(nil, case[1], 2000, "exp-armor")
		assert_equal(missing.ok, false, case[2] .. " without cache must fail")
		assert_equal(missing.error, case[2])
	end

	local permanent_cases = {
		{ { status = 404, response = '{"error":"published experiment not found"}' }, "http_404" },
		{ { status = 302 }, "http_302" },
		{ { status = 413 }, "http_413" },
	}
	for _, case in ipairs(permanent_cases) do
		local result, new_cache, authoritative, drop, refused = experiments.apply(cache, case[1], 2000, "exp-armor")
		assert_equal(result.ok, false, case[2] .. " must fail without serving the cache")
		assert_equal(result.error, case[2])
		assert_nil(new_cache)
		assert_equal(authoritative, true, case[2] .. " settles the fence")
		assert_equal(drop, false)
		assert_equal(refused, false)
	end
end

local function test_apply_malformed_bodies_are_transient()
	reset()
	-- Raw assigned bodies with a literal variant_payload value: the mock
	-- json.encode cannot express null or an empty ARRAY distinctly, and
	-- these cases are decided on the body TEXT.
	local function assigned_raw_payload(payload_json)
		return '{"assigned":true,"version":3,"assignment_key":"' .. test_assignment_key
			.. '","variant_key":"v","experiment_key":"exp-armor"'
			.. ',"boundary":{"assignment_unit":"client_id"},"subject_fact_key":"' .. test_sfk
			.. '","variant_payload":' .. payload_json .. "}"
	end
	local malformed = {
		"not json",
		"[]",
		'{"assigned":"yes"}',
		-- No version member.
		'{"assigned":true,"assignment_key":"a","variant_key":"v","experiment_key":"e","boundary":{"assignment_unit":"client_id"},"subject_fact_key":"' .. test_sfk .. '"}',
		-- Unknown assignment unit.
		assigned_body({ boundary = { assignment_unit = "household" } }),
		-- Assigned without a variant key.
		'{"assigned":true,"version":3,"assignment_key":"a","experiment_key":"e","boundary":{"assignment_unit":"synthetic_subject_key"}}',
		-- client_id unit without a grammar-valid subject_fact_key.
		assigned_body({ subject_fact_key = "sfk1_short" }),
		'{"assigned":false,"version":3,"assignment_key":"a","experiment_key":"e","boundary":{"assignment_unit":"client_id"}}',
		-- A body naming a DIFFERENT experiment than the one fetched.
		assigned_body({ experiment_key = "exp-other" }),
		-- An unknown not-assigned reason (only kill_switch /
		-- targeting_unmatched / absence are published shapes).
		unassigned_body("kil_switch"),
		unassigned_body("paused"),
		-- An assigned verdict missing its assignment_key entirely.
		'{"assigned":true,"version":3,"variant_key":"v","experiment_key":"exp-armor","boundary":{"assignment_unit":"synthetic_subject_key"}}',
		-- variant_payload present but not a JSON object: scalar, array
		-- (empty or not — an empty array decodes to the same Lua table as an
		-- empty object, so the check reads the body text), or null.
		assigned_raw_payload('"str"'),
		assigned_raw_payload("7"),
		assigned_raw_payload("[1,2]"),
		assigned_raw_payload("[]"),
		assigned_raw_payload("null"),
	}
	local cache = { body = assigned_body(), fetched_at_ms = 1000 }
	for index, body in ipairs(malformed) do
		local result, new_cache, authoritative = experiments.apply(cache, { status = 200, response = body }, 2000, "exp-armor")
		assert_true(result.ok, "malformed case " .. index .. " must serve the cache")
		assert_equal(result.error, "malformed_response", "malformed case " .. index)
		assert_nil(new_cache, "malformed case " .. index .. " must not overwrite the cache")
		assert_equal(authoritative, false)
	end
end

local function test_apply_auth_refusals_and_sentinel()
	reset()
	local cache = { body = assigned_body(), fetched_at_ms = 1000 }
	local generic_cases = {
		{ status = 401, response = '{"error":"invalid runtime token"}' },
		{ status = 403, response = '{"error":"experimentation runtime is disabled"}' },
		{ status = 403, response = '{"error":"experiment assignment fetch is disabled"}' },
		{ status = 403, response = '{"error":"workspace suspended"}' },
		-- Near-sentinel bodies must stay generic: equality, not substring.
		{ status = 403, response = '{"error":"' .. sentinel_text .. ' today"}' },
		{ status = 403, response = '{"error":"Experiment real-subject assignment is disabled"}' },
		-- An unparseable body is a generic 403.
		{ status = 403, response = "experiment real-subject assignment is disabled" },
		{ status = 403 },
	}
	for index, response in ipairs(generic_cases) do
		local result, new_cache, authoritative, drop, refused = experiments.apply(cache, response, 2000, "exp-armor")
		assert_equal(result.ok, false, "auth case " .. index .. " must fail closed")
		assert_equal(result.error, "unauthorized", "auth case " .. index)
		assert_nil(new_cache)
		assert_equal(authoritative, true)
		assert_equal(drop, false, "auth case " .. index .. " must not drop the cache")
		assert_equal(refused, true, "auth case " .. index .. " must flag the automatic-lane halt")
	end

	-- The exact sentinel body — and only it — additionally drops the cache.
	local result, new_cache, authoritative, drop, refused =
		experiments.apply(cache, { status = 403, response = '{"error":"' .. sentinel_text .. '"}' }, 2000, "exp-armor")
	assert_equal(result.ok, false)
	assert_equal(result.error, "unauthorized")
	assert_nil(new_cache)
	assert_equal(authoritative, true)
	assert_equal(drop, true, "the exact sentinel must drop the cache")
	assert_equal(refused, true)

	-- A 401 carrying the sentinel text never drops: the drop is 403-only.
	local _, _, _, drop_401 =
		experiments.apply(cache, { status = 401, response = '{"error":"' .. sentinel_text .. '"}' }, 2000, "exp-armor")
	assert_equal(drop_401, false, "a 401 never drops the cache")
end

-- ── fetch wiring ──────────────────────────────────────────────────────────────

local function test_fetch_sends_bearer_get_without_conditional_headers()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	local result = fetch(client)
	assert_true(result.ok, result.error)

	local request = last_request()
	assert_equal(request.method, "GET")
	assert_equal(request.url,
		"http://localhost:28090/api/cp/v1/runtime/experiments/assignment"
			.. "?app_key=app-test&environment_key=develop&experiment_key=exp-armor"
			.. "&subject_key=" .. client:get_spcid())
	assert_equal(request.headers["Authorization"], "Bearer sp_ingest_publishable_key")
	assert_equal(request.options.timeout, 2)
	assert_nil(request.body)

	-- The endpoint has no ETag/304 lane: even with a cached record, a
	-- re-fetch carries no If-None-Match.
	fetch(client)
	assert_nil(last_request().headers["If-None-Match"])

	local ok, err = client:fetch_experiment_assignment("", function() end)
	assert_equal(ok, false)
	assert_equal(err, "experiment_key_required")
end

local function test_assigned_200_serves_and_caches()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	local result = fetch(client)
	assert_true(result.ok, result.error)
	assert_equal(result.from_cache, false)
	assert_equal(result.assigned, true)
	assert_nil(result.reason)
	assert_equal(result.experiment_key, "exp-armor")
	assert_equal(result.version, 3)
	assert_equal(result.assignment_key, test_assignment_key)
	assert_equal(result.variant_key, "variant-b")
	assert_equal(result.variant_payload.armor, 2)
	assert_equal(result.assignment_unit, "client_id")
	assert_equal(result.subject_fact_key, test_sfk, "the sfk must be retained with the assignment")

	local snapshot = client:experiment_assignment("exp-armor")
	assert_true(snapshot ~= nil, "the getter must serve the installed snapshot")
	assert_equal(snapshot.variant_key, "variant-b")
	assert_equal(snapshot.subject_fact_key, test_sfk)

	-- The snapshot is a defensive copy: mutating what the getter handed out
	-- must not corrupt what the next read serves.
	snapshot.variant_payload.armor = 99
	snapshot.variant_key = "mutated"
	local re_read = client:experiment_assignment("exp-armor")
	assert_equal(re_read.variant_payload.armor, 2)
	assert_equal(re_read.variant_key, "variant-b")
end

local function test_not_assigned_shapes_are_valid_and_distinguished()
	reset()
	local client = assert(sdk.new(config()))
	local shapes = {
		{ nil, "the deterministic traffic gate carries no reason" },
		{ "kill_switch" },
		{ "targeting_unmatched" },
	}
	for _, shape in ipairs(shapes) do
		next_status = 200
		next_response_body = unassigned_body(shape[1])
		local result = fetch(client)
		assert_true(result.ok, result.error)
		assert_equal(result.assigned, false)
		assert_equal(result.reason, shape[1], shape[2])
		assert_nil(result.variant_key)
	end
	-- A not-assigned decision is still cached and served — facts are simply
	-- never produced from it (see the producer tests).
	local snapshot = client:experiment_assignment("exp-armor")
	assert_equal(snapshot.assigned, false)
end

local function test_restart_serves_cache_and_offline_fetch_uses_it()
	reset()
	local restore = install_fake_sys_storage()
	local first = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(first).ok)

	-- A second client (a restart) serves the durable record without any
	-- fetch — same config, same persisted spcid, same scope.
	local second = assert(sdk.new(config()))
	assert_equal(second:get_spcid(), first:get_spcid(), "the restart must adopt the persisted spcid")
	local snapshot = second:experiment_assignment("exp-armor")
	assert_true(snapshot ~= nil, "the restart must serve the durable assignment record")
	assert_equal(snapshot.variant_key, "variant-b")

	-- An offline fetch serves the cached record, marked from-cache.
	next_status = 0
	next_response_body = nil
	local result = fetch(second)
	assert_true(result.ok, "the offline fetch must serve the cache")
	assert_equal(result.from_cache, true)
	assert_equal(result.error, "http_0")
	assert_equal(result.variant_key, "variant-b")
	restore()
end

local function test_scope_isolation_between_experiments_and_subjects()
	reset()
	local restore = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(client, "exp-armor").ok)

	-- Another experiment is another scope: its transient fetch must not be
	-- served exp-armor's cache.
	next_status = 500
	next_response_body = nil
	local other = fetch(client, "exp-shield")
	assert_equal(other.ok, false, "another experiment must never serve this experiment's cache")
	assert_equal(other.error, "transient_500")
	assert_nil(client:experiment_assignment("exp-shield"))

	-- Fetching another experiment must never displace this one either: the
	-- cache is keyed per scope (one record per experiment), not one shared
	-- record.
	next_status = 200
	next_response_body = assigned_body({ experiment_key = "exp-shield", variant_key = "variant-s" })
	assert_true(fetch(client, "exp-shield").ok)
	assert_equal(client:experiment_assignment("exp-armor").variant_key, "variant-b",
		"fetching experiment B must not evict experiment A's cached decision")
	assert_equal(client:experiment_assignment("exp-shield").variant_key, "variant-s")
	local reloaded = assert(sdk.new(config()))
	assert_equal(reloaded:experiment_assignment("exp-armor").variant_key, "variant-b",
		"both experiments' records survive a restart side by side")
	assert_equal(reloaded:experiment_assignment("exp-shield").variant_key, "variant-s")

	-- Another subject is another scope: a client whose spcid differs must
	-- not adopt the persisted record at construction.
	local foreign = assert(sdk.new(config({ spcid = "spcid_" .. string.rep("z", 24) })))
	assert_nil(foreign:experiment_assignment("exp-armor"),
		"another subject must not serve this subject's cached assignment")
	restore()
end

local function test_mismatched_experiment_key_200_is_malformed()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(client).ok)

	-- A 200 naming ANOTHER experiment must not install under this scope —
	-- it would misattribute that experiment's decision (and its exposures)
	-- until restart. Malformed: the last-known-good decision serves.
	next_response_body = assigned_body({ experiment_key = "exp-other", variant_key = "variant-x" })
	local result = fetch(client)
	assert_true(result.ok, "the cache serves through the malformed body")
	assert_equal(result.from_cache, true)
	assert_equal(result.error, "malformed_response")
	assert_equal(result.variant_key, "variant-b", "the served decision is the last-known-good one")
	assert_equal(client:experiment_assignment("exp-armor").variant_key, "variant-b",
		"a mismatched-key body must not overwrite the snapshot")
	assert_nil(client:experiment_assignment("exp-other"),
		"nothing may be installed for the foreign key either")

	-- Without a cache the mismatch fails outright (still transient-shaped).
	next_response_body = assigned_body()
	local miss = fetch(client, "exp-shield")
	assert_equal(miss.ok, false)
	assert_equal(miss.error, "malformed_response")
	assert_nil(client:experiment_assignment("exp-shield"))
end

local function test_unknown_not_assigned_reason_is_malformed()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(client).ok)

	-- Only three not-assigned shapes exist (reason absent / kill_switch /
	-- targeting_unmatched): any other reason is a body this build cannot
	-- interpret, and it must not overwrite the last-known-good decision.
	next_response_body = unassigned_body("kil_switch")
	local result = fetch(client)
	assert_true(result.ok, "the cache serves through the malformed body")
	assert_equal(result.from_cache, true)
	assert_equal(result.error, "malformed_response")
	assert_equal(result.assigned, true, "the served decision is the cached assigned one")
	assert_equal(client:experiment_assignment("exp-armor").variant_key, "variant-b",
		"an unknown refusal reason must not displace the cached decision")

	-- The intact decision keeps feeding the producers.
	next_status = 200
	next_response_body = nil
	assert_true(client:set_consent(true))
	assert_true(client:track_experiment_exposure("exp-armor"))
end

local function test_sentinel_drop_failed_durable_clear_blocks_resurrection()
	reset()
	local restore, stores = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(client).ok)

	local function stored_assignment_records()
		for path, record in pairs(stores) do
			if path:find("experiment-assignments", 1, true) then
				return record.records
			end
		end
		return nil
	end

	-- Storage WRITES start failing while reads keep working: the sentinel's
	-- durable clear cannot land, so the disk record survives the drop.
	local saved_save = sys.save
	sys.save = function()
		return false
	end
	next_status = 403
	next_response_body = '{"error":"' .. sentinel_text .. '"}'
	fetch(client)
	assert_nil(client:experiment_assignment("exp-armor"))
	local kept = stored_assignment_records()
	assert_true(kept ~= nil and #kept == 1, "the failed clear leaves the record on disk")

	-- The surviving disk record must NOT resurrect through a later
	-- transient fetch: the in-memory tombstone refuses it.
	next_status = 500
	next_response_body = nil
	local result = fetch(client)
	assert_equal(result.ok, false, "the sentinel-disabled record must never be re-served")
	assert_equal(result.error, "transient_500")
	assert_nil(client:experiment_assignment("exp-armor"))

	-- Storage recovers: the next fetch retries the owed durable clear and
	-- the poisoned record leaves the disk.
	sys.save = saved_save
	next_status = 500
	local after = fetch(client)
	assert_equal(after.ok, false, "still nothing to serve once the clear lands")
	kept = stored_assignment_records()
	assert_true(kept ~= nil and #kept == 0, "the retried durable clear must land once storage recovers")

	-- A newer fresh decision lifts the drop entirely: it serves, re-caches,
	-- and backs later transients again.
	next_status = 200
	next_response_body = assigned_body({ variant_key = "variant-after" })
	assert_true(fetch(client).ok)
	assert_equal(client:experiment_assignment("exp-armor").variant_key, "variant-after")
	next_status = 500
	next_response_body = nil
	local served = fetch(client)
	assert_true(served.ok, "the newer decision serves from cache on transients")
	assert_equal(served.variant_key, "variant-after")
	restore()
end

local function test_auth_refusal_fails_closed_without_latch_or_drop()
	reset()
	local restore, stores = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(client).ok)

	local auth_cases = {
		{ 401, '{"error":"invalid runtime token"}' },
		{ 403, '{"error":"experimentation runtime is disabled"}' },
		{ 403, '{"error":"experiment assignment fetch is disabled"}' },
		{ 403, "not json at all" },
	}
	for _, case in ipairs(auth_cases) do
		next_status = case[1]
		next_response_body = case[2]
		local result = fetch(client)
		assert_equal(result.ok, false, "an auth refusal must fail closed")
		assert_equal(result.from_cache, false, "the cache is never served for an auth refusal")
		assert_equal(result.error, "unauthorized")
		-- ...but there is NO latch and NO drop: the getter keeps serving
		-- last-known-good and the durable record survives.
		assert_equal(client:experiment_assignment("exp-armor").variant_key, "variant-b")
	end
	local durable = false
	for path, record in pairs(stores) do
		if path:find("experiment-assignments", 1, true) and record.records and #record.records > 0 then
			durable = true
		end
	end
	assert_true(durable, "generic auth refusals must leave the durable record untouched")

	-- A later fetch classifies independently: a 200 under a fixed credential
	-- resumes serving fresh decisions (per-fetch, no cross-fetch state).
	next_status = 200
	next_response_body = assigned_body({ variant_key = "variant-c" })
	local recovered = fetch(client)
	assert_true(recovered.ok, "a later fetch must classify independently")
	assert_equal(recovered.variant_key, "variant-c")
	restore()
end

local function test_sentinel_403_drops_cache_and_sfk_for_its_scope_only()
	reset()
	local restore, stores = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(client, "exp-armor").ok)
	next_response_body = assigned_body({ experiment_key = "exp-shield", variant_key = "variant-s" })
	assert_true(fetch(client, "exp-shield").ok)

	next_status = 403
	next_response_body = '{"error":"' .. sentinel_text .. '"}'
	local result = fetch(client, "exp-armor")
	assert_equal(result.ok, false)
	assert_equal(result.error, "unauthorized")

	-- The sentinel dropped exp-armor's snapshot (and with it the sfk)...
	assert_nil(client:experiment_assignment("exp-armor"), "the sentinel must drop the cached assignment")
	-- ...and its durable record, while exp-shield's record survives.
	local kept = nil
	for path, record in pairs(stores) do
		if path:find("experiment-assignments", 1, true) then
			kept = record.records
		end
	end
	assert_true(kept ~= nil and #kept == 1, "exactly one durable record must survive the sentinel drop")
	assert_equal(kept[1].experiment_key, "exp-shield")

	-- With the record gone, a transient failure has nothing to serve.
	next_status = 500
	next_response_body = nil
	local after = fetch(client, "exp-armor")
	assert_equal(after.ok, false, "after the sentinel drop there is no cache to serve")
	assert_equal(after.error, "transient_500")

	-- A restart must not resurrect the dropped record either.
	local second = assert(sdk.new(config()))
	assert_nil(second:experiment_assignment("exp-armor"))
	assert_equal(second:experiment_assignment("exp-shield").variant_key, "variant-s")
	restore()
end

local function test_automatic_lane_halts_after_auth_refusal_until_reinit()
	reset()
	local restore = install_fake_sys_storage()
	local client = assert(sdk.new(config()))
	assert_true(client.experiments:automatic_fetch_allowed(), "the lane starts open")

	next_status = 401
	next_response_body = '{"error":"invalid runtime token"}'
	fetch(client)
	assert_equal(client.experiments:automatic_fetch_allowed(), false,
		"an authoritative 401 must halt the automatic lane")

	-- Host-triggered fetches are never blocked and classify per fetch...
	local before = #requests
	next_status = 200
	next_response_body = assigned_body()
	local result = fetch(client)
	assert_true(result.ok, "a host fetch must still dispatch and classify per fetch")
	assert_equal(#requests, before + 1)
	-- ...and a per-fetch success does NOT reopen the lane: only re-init
	-- (a new client) or a config change does.
	assert_equal(client.experiments:automatic_fetch_allowed(), false,
		"a host-fetch success must not auto-resume the automatic lane")

	local second = assert(sdk.new(config()))
	assert_true(second.experiments:automatic_fetch_allowed(), "re-init reopens the lane")

	-- The sentinel flavor halts too (any authoritative 403).
	next_status = 403
	next_response_body = '{"error":"' .. sentinel_text .. '"}'
	fetch(second)
	assert_equal(second.experiments:automatic_fetch_allowed(), false)
	restore()
end

local function test_out_of_order_responses_cannot_install_or_erase_fresh_state()
	reset()
	local client = assert(sdk.new(config()))

	-- A queueing transport: callbacks are held and answered manually, so an
	-- older response can arrive after a newer one.
	local saved_request = http.request
	local pending = {}
	http.request = function(url, method, callback, headers, body, options)
		pending[#pending + 1] = callback
	end

	local results = {}
	client:fetch_experiment_assignment("exp-armor", function(result)
		results[1] = result
	end)
	client:fetch_experiment_assignment("exp-armor", function(result)
		results[2] = result
	end)
	assert_equal(#pending, 2)

	-- The NEWER fetch settles first with a fresh decision...
	pending[2](nil, nil, { status = 200, response = assigned_body({ variant_key = "variant-new" }) })
	assert_equal(results[2].variant_key, "variant-new")
	-- ...and the older in-flight success must not roll it back.
	pending[1](nil, nil, { status = 200, response = assigned_body({ variant_key = "variant-old" }) })
	assert_equal(client:experiment_assignment("exp-armor").variant_key, "variant-new",
		"an older in-flight response must not roll back a newer decision")

	-- A newer fail-closed refusal fences an older in-flight success the same
	-- way: nothing may sneak in after it.
	pending = {}
	client:fetch_experiment_assignment("exp-shield", function() end)
	client:fetch_experiment_assignment("exp-shield", function() end)
	pending[2](nil, nil, { status = 401, response = '{"error":"invalid runtime token"}' })
	pending[1](nil, nil, { status = 200,
		response = assigned_body({ experiment_key = "exp-shield", variant_key = "variant-s" }) })
	assert_nil(client:experiment_assignment("exp-shield"),
		"an older success must not install after a newer fail-closed outcome")

	-- A stale sentinel must not erase a decision installed after it either:
	-- the drop is fence-guarded like any install.
	pending = {}
	client:fetch_experiment_assignment("exp-armor", function() end)
	client:fetch_experiment_assignment("exp-armor", function() end)
	pending[2](nil, nil, { status = 200, response = assigned_body({ variant_key = "variant-kept" }) })
	pending[1](nil, nil, { status = 403, response = '{"error":"' .. sentinel_text .. '"}' })
	assert_equal(client:experiment_assignment("exp-armor").variant_key, "variant-kept",
		"a stale sentinel must not erase the fresher decision installed after it")

	http.request = saved_request
end

local function test_missing_transport_and_decoder_degrade_cleanly()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(client).ok)

	local saved_http = http
	http = nil
	local result = fetch(client)
	assert_true(result.ok, "a missing transport must serve the cache like any transient")
	assert_equal(result.from_cache, true)
	assert_equal(result.error, "http_unavailable")
	http = saved_http

	local saved_json = json
	json = nil
	local ok, err = client:fetch_experiment_assignment("exp-armor", function(value)
		result = value
	end)
	json = saved_json
	assert_equal(ok, false)
	assert_equal(err, "json_unavailable")
	assert_equal(result.error, "json_unavailable")
end

-- ── spcid provisioning ────────────────────────────────────────────────────────

local function test_spcid_minted_persisted_and_distinct_from_anonymous_id()
	reset()
	local restore, stores = install_fake_sys_storage()
	local client = assert(sdk.new(config({ anonymous_id = nil })))
	local spcid = client:get_spcid()
	assert_true(experiments.valid_spcid(spcid), "the minted spcid must be grammar-valid")
	assert_true(spcid ~= client:get_anonymous_id(), "the spcid is a dedicated id, never the anonymous id")
	assert_true(spcid ~= "spcid_" .. client:get_anonymous_id(),
		"the spcid must not be derived from the anonymous id")

	local identity = stores["shardpilot.workspace-test.app-test/identity"]
	assert_true(identity ~= nil, "the identity record must exist")
	assert_equal(identity.spcid, spcid, "the spcid must be persisted in the identity record")
	assert_true(identity.anonymous_id ~= nil and identity.anonymous_id ~= identity.spcid)

	-- A restart adopts the persisted value instead of minting a new one.
	local second = assert(sdk.new(config({ anonymous_id = nil })))
	assert_equal(second:get_spcid(), spcid)
	restore()
end

local function test_spcid_survives_unopted_relaunch_rewrites()
	reset()
	local restore, stores = install_fake_sys_storage()
	local first = assert(sdk.new(config()))
	local spcid = first:get_spcid()

	-- A later launch WITHOUT the experiments opt-in rewrites the identity
	-- record (a consent decision does) — the provisioned spcid must survive.
	local unopted = assert(sdk.new(unopted_config()))
	next_status = 200
	next_response_body = nil
	assert_true(unopted:set_consent(true))
	assert_equal(stores["shardpilot.workspace-test.app-test/identity"].spcid, spcid,
		"an un-opted relaunch must never drop the persisted spcid")

	local third = assert(sdk.new(config()))
	assert_equal(third:get_spcid(), spcid, "the re-opted launch must still see the original spcid")
	restore()
end

local function test_spcid_config_override_and_invalid_fallthrough()
	reset()
	local restore, stores = install_fake_sys_storage()
	local supplied = "spcid_host_supplied_0123456789"
	local client = assert(sdk.new(config({ spcid = supplied })))
	assert_equal(client:get_spcid(), supplied, "a grammar-valid config spcid is adopted")
	assert_equal(stores["shardpilot.workspace-test.app-test/identity"].spcid, supplied)

	-- A grammar-invalid config value falls through to the stored id, exactly
	-- like an invalid config anonymous_id.
	local second = assert(sdk.new(config({ spcid = "not-an-spcid" })))
	assert_equal(second:get_spcid(), supplied)
	restore()
end

local function test_no_optin_means_no_spcid_and_no_wire()
	reset()
	local client = assert(sdk.new(unopted_config()))
	assert_nil(client:get_spcid(), "no opt-in, no spcid")
	assert_nil(client:experiment_assignment("exp-armor"))
	local record = storage.load(client.config)
	assert_nil(record.spcid, "the identity record must stay byte-identical without the opt-in")

	local result = nil
	local ok, err = client:fetch_experiment_assignment("exp-armor", function(value)
		result = value
	end)
	assert_equal(ok, false)
	assert_equal(err, "experiments_not_configured")
	assert_equal(result.error, "experiments_not_configured")

	local produced, produce_err = client:track_experiment_exposure("exp-armor")
	assert_equal(produced, false)
	assert_equal(produce_err, "experiments_not_configured")

	-- The dark posture: nothing was fetched, nothing was sent.
	assert_equal(#requests, 0, "no opt-in must mean zero experiment wire traffic")
	client:update(9999)
	assert_equal(requests_to("/runtime/experiments/"), 0)
end

-- ── exposure/outcome producers ────────────────────────────────────────────────

-- Build a granted client with a served assigned decision, ready to produce.
local function granted_client_with_assignment(overrides)
	local client = assert(sdk.new(config(overrides)))
	next_status = 200
	next_response_body = nil
	assert_true(client:set_consent(true))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(client).ok)
	return client
end

local function published_events(client)
	next_status = 202
	next_response_body = '{"accepted":1}'
	assert_true(client:flush())
	local request = last_request()
	assert_true(request.url:find("/v1/events:batch", 1, true) ~= nil, "the batch pipe must carry the facts")
	return json.decode(request.body).events, request
end

local function test_exposure_rides_consent_gated_queue_with_strict_props()
	reset()
	local client = granted_client_with_assignment()
	assert_true(client:identify("user-known"))

	local ok, err = client:track_experiment_exposure("exp-armor")
	assert_true(ok, err)
	assert_equal(client.stats.enqueued, 1)

	local events = published_events(client)
	assert_equal(#events, 1)
	local event = events[1]
	assert_equal(event.event_name, "experiment_exposure")
	assert_equal(event.source, "client")
	assert_nil(event.user_id, "experiment facts must never carry user_id, even for an identified user")
	assert_equal(event.anonymous_id, "anon-client", "anonymous_id is required (erasure reachability)")
	assert_true(type(event.session_id) == "string" and event.session_id ~= "")

	-- The props are the strict allowlist and NOTHING else.
	local props = event.props
	assert_equal(props.experiment_key, "exp-armor")
	assert_equal(props.experiment_version, 3)
	assert_equal(props.assignment_key, test_sfk,
		"a client_id-unit fact's subject must be the subject_fact_key")
	assert_equal(props.variant_key, "variant-b")
	assert_equal(props.assignment_unit, "client_id")
	local prop_count = 0
	for _ in pairs(props) do
		prop_count = prop_count + 1
	end
	assert_equal(prop_count, 5, "an exposure carries exactly the five allowlisted props")

	-- The raw spcid must never ride the wire payload.
	local request = last_request()
	assert_nil(request.body:find(client:get_spcid(), 1, true),
		"the raw spcid must never appear in an events:batch payload")
end

local function test_outcome_props_validation_and_no_dedupe()
	reset()
	local client = granted_client_with_assignment()

	local ok, err = client:track_experiment_outcome("exp-armor", "level_finished", 12)
	assert_true(ok, err)
	assert_true(client:track_experiment_outcome("exp-armor", "hard_mode_used", true))
	assert_true(client:track_experiment_outcome("exp-armor", "level_finished", 13),
		"outcomes are deliberately not de-duplicated")

	for index, value in ipairs({ "twelve", {} }) do
		local bad, bad_err = client:track_experiment_outcome("exp-armor", "k", value)
		assert_equal(bad, false, "invalid outcome value case " .. index)
		assert_equal(bad_err, "invalid_outcome_value")
	end
	local nan_ok, nan_err = client:track_experiment_outcome("exp-armor", "k", 0 / 0)
	assert_equal(nan_ok, false)
	assert_equal(nan_err, "invalid_outcome_value", "NaN is not a finite number")
	local inf_ok = client:track_experiment_outcome("exp-armor", "k", math.huge)
	assert_equal(inf_ok, false, "infinity is not a finite number")
	local neg_inf_ok = client:track_experiment_outcome("exp-armor", "k", -math.huge)
	assert_equal(neg_inf_ok, false, "negative infinity is not a finite number")
	local nil_ok, nil_err = client:track_experiment_outcome("exp-armor", "k", nil)
	assert_equal(nil_ok, false)
	assert_equal(nil_err, "invalid_outcome_value")
	local no_key, no_key_err = client:track_experiment_outcome("exp-armor", "", 1)
	assert_equal(no_key, false)
	assert_equal(no_key_err, "outcome_key_required")

	local events = published_events(client)
	assert_equal(#events, 3)
	local outcome = events[1]
	assert_equal(outcome.event_name, "experiment_outcome")
	assert_equal(outcome.props.outcome_key, "level_finished")
	assert_equal(outcome.props.outcome_value, 12)
	assert_equal(outcome.props.assignment_key, test_sfk)
	local prop_count = 0
	for _ in pairs(outcome.props) do
		prop_count = prop_count + 1
	end
	assert_equal(prop_count, 7, "an outcome carries exactly the seven allowlisted props")
	assert_equal(events[2].props.outcome_value, true, "a boolean outcome value is admitted")
end

local function test_producers_consent_gating_unknown_and_denied_drop()
	reset()
	-- Consent still unknown: the assignment FETCH works (config-plane), the
	-- FACT is dropped at the gate — nothing queued, nothing on the wire.
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(client).ok, "the assignment fetch is not consent-gated")

	local ok, err = client:track_experiment_exposure("exp-armor")
	assert_equal(ok, false)
	assert_equal(err, "consent_unknown")
	assert_equal(client.stats.enqueued, 0)
	assert_equal(client.stats.dropped, 1)
	assert_equal(requests_to("/v1/events:batch"), 0, "an unconsented fact must never reach the wire")

	local outcome_ok, outcome_err = client:track_experiment_outcome("exp-armor", "k", 1)
	assert_equal(outcome_ok, false)
	assert_equal(outcome_err, "consent_unknown")

	-- A consent-dropped exposure is not burned by the dedupe: after the
	-- grant, the same exposure emits normally...
	next_status = 200
	next_response_body = nil
	assert_true(client:set_consent(true))
	assert_true(client:track_experiment_exposure("exp-armor"))
	-- ...and only the repeat is de-duplicated.
	local repeat_ok, repeat_err = client:track_experiment_exposure("exp-armor")
	assert_equal(repeat_ok, false)
	assert_equal(repeat_err, "duplicate_exposure")
	assert_equal(client.stats.enqueued, 1)

	-- Denied drops at the gate too (and clears the queued fact).
	assert_true(client:set_consent(false))
	local denied_ok, denied_err = client:track_experiment_outcome("exp-armor", "k", 1)
	assert_equal(denied_ok, false)
	assert_equal(denied_err, "consent_denied")
	assert_equal(requests_to("/v1/events:batch"), 0)
end

local function test_producers_refuse_without_assigned_decision()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = nil
	assert_true(client:set_consent(true))

	local ok, err = client:track_experiment_exposure("exp-armor")
	assert_equal(ok, false)
	assert_equal(err, "assignment_unavailable", "no served assignment, no fact")

	-- A not-assigned decision NEVER produces facts.
	next_status = 200
	next_response_body = unassigned_body("kill_switch")
	assert_true(fetch(client).ok)
	local killed_ok, killed_err = client:track_experiment_exposure("exp-armor")
	assert_equal(killed_ok, false)
	assert_equal(killed_err, "not_assigned")
	local outcome_ok, outcome_err = client:track_experiment_outcome("exp-armor", "k", 1)
	assert_equal(outcome_ok, false)
	assert_equal(outcome_err, "not_assigned")
	assert_equal(client.stats.enqueued, 0)
end

local function test_synthetic_unit_fact_uses_response_assignment_key()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = nil
	assert_true(client:set_consent(true))
	next_status = 200
	next_response_body = json.encode({
		experiment_key = "exp-armor",
		version = 2,
		assigned = true,
		assignment_key = test_assignment_key,
		variant_key = "variant-a",
		boundary = { assignment_unit = "synthetic_subject_key" },
	})
	assert_true(fetch(client).ok)
	assert_true(client:track_experiment_exposure("exp-armor"))
	local events = published_events(client)
	assert_equal(events[1].props.assignment_key, test_assignment_key,
		"a synthetic-unit fact's subject is the response assignment_key")
	assert_equal(events[1].props.assignment_unit, "synthetic_subject_key")
end

local function test_exposure_dedupe_is_per_launch()
	reset()
	local restore = install_fake_sys_storage()
	local client = granted_client_with_assignment()
	assert_true(client:track_experiment_exposure("exp-armor"))
	assert_equal(client:track_experiment_exposure("exp-armor"), false)

	-- A new launch (new client) may act on the assignment again: the dedupe
	-- is per launch, not durable.
	local second = assert(sdk.new(config()))
	assert_true(second:track_experiment_exposure("exp-armor"),
		"a new launch emits its own first-act exposure")
	restore()
end

local function test_consent_purge_rearms_undelivered_exposure_dedupe()
	reset()
	local client = granted_client_with_assignment()

	-- Queued but NOT yet delivered: a revocation purges the event, so the
	-- dedupe key must re-arm — the fact never left the device, and leaving
	-- it burned would make this assignment's exposure unreportable for the
	-- rest of the launch.
	assert_true(client:track_experiment_exposure("exp-armor"))
	next_status = 200
	next_response_body = nil
	assert_true(client:set_consent(false))
	assert_true(client:set_consent(true))
	assert_true(client:track_experiment_exposure("exp-armor"),
		"a consent purge must re-arm the undelivered exposure")
	local events = published_events(client)
	assert_equal(#events, 1, "the re-armed exposure is delivered exactly once")
	assert_equal(events[1].event_name, "experiment_exposure")

	-- A DELIVERED exposure stays deduped across a revoke/re-grant cycle:
	-- re-arming it would double-count the fact.
	next_status = 200
	next_response_body = nil
	assert_true(client:set_consent(false))
	assert_true(client:set_consent(true))
	local repeat_ok, repeat_err = client:track_experiment_exposure("exp-armor")
	assert_equal(repeat_ok, false)
	assert_equal(repeat_err, "duplicate_exposure",
		"a delivered exposure must stay deduped through a consent cycle")
	assert_equal(requests_to("/v1/events:batch"), 1)
end

-- ── singleton facade ──────────────────────────────────────────────────────────

local function test_facade_reports_not_initialized()
	reset()
	assert_nil(sdk.experiment_assignment("exp-armor"))
	assert_nil(sdk.get_spcid())

	local result = nil
	local ok, err = sdk.fetch_experiment_assignment("exp-armor", function(value)
		result = value
	end)
	assert_equal(ok, false)
	assert_equal(err, "not_initialized")
	assert_equal(result.error, "not_initialized")

	local produced, produce_err = sdk.track_experiment_exposure("exp-armor")
	assert_equal(produced, false)
	assert_equal(produce_err, "not_initialized")
end

local function test_facade_delegates_to_the_default_client()
	reset()
	assert_true(sdk.init(config()))
	next_status = 200
	next_response_body = nil
	assert_true(sdk.set_consent(true))
	next_status = 200
	next_response_body = assigned_body()

	local result = nil
	sdk.fetch_experiment_assignment("exp-armor", function(value)
		result = value
	end)
	assert_true(result.ok, result.error)
	assert_true(experiments.valid_spcid(sdk.get_spcid()))
	assert_equal(sdk.experiment_assignment("exp-armor").variant_key, "variant-b")
	assert_true(sdk.track_experiment_exposure("exp-armor"))
	assert_true(sdk.track_experiment_outcome("exp-armor", "level_finished", 1))

	next_status = 202
	next_response_body = '{"accepted":2}'
	sdk.shutdown("test_teardown")
end

local function test_fetch_after_shutdown_is_rejected()
	reset()
	local client = assert(sdk.new(config()))
	next_status = 200
	next_response_body = nil
	assert_true(client:set_consent(true))
	next_status = 200
	next_response_body = assigned_body()
	assert_true(fetch(client).ok)
	next_status = 202
	next_response_body = '{"accepted":0}'
	assert_true(client:shutdown("test_teardown"))

	local before = #requests
	local result = nil
	local ok, err = client:fetch_experiment_assignment("exp-armor", function(value)
		result = value
	end)
	assert_equal(ok, false)
	assert_equal(err, "shutdown")
	assert_equal(result.error, "shutdown")
	assert_equal(#requests, before, "a torn-down client must not dispatch")

	local produced, produce_err = client:track_experiment_exposure("exp-armor")
	assert_equal(produced, false)
	assert_equal(produce_err, "shutdown")
end

local tests = {
	test_spcid_grammar,
	test_subject_fact_key_grammar,
	test_build_url_escapes_query_values,
	test_build_scope_keeps_distinct_tuples_distinct,
	test_config_validation,
	test_apply_transients_serve_cache_and_permanents_fail,
	test_apply_malformed_bodies_are_transient,
	test_apply_auth_refusals_and_sentinel,
	test_fetch_sends_bearer_get_without_conditional_headers,
	test_assigned_200_serves_and_caches,
	test_not_assigned_shapes_are_valid_and_distinguished,
	test_restart_serves_cache_and_offline_fetch_uses_it,
	test_scope_isolation_between_experiments_and_subjects,
	test_auth_refusal_fails_closed_without_latch_or_drop,
	test_sentinel_403_drops_cache_and_sfk_for_its_scope_only,
	test_mismatched_experiment_key_200_is_malformed,
	test_unknown_not_assigned_reason_is_malformed,
	test_sentinel_drop_failed_durable_clear_blocks_resurrection,
	test_automatic_lane_halts_after_auth_refusal_until_reinit,
	test_out_of_order_responses_cannot_install_or_erase_fresh_state,
	test_missing_transport_and_decoder_degrade_cleanly,
	test_spcid_minted_persisted_and_distinct_from_anonymous_id,
	test_spcid_survives_unopted_relaunch_rewrites,
	test_spcid_config_override_and_invalid_fallthrough,
	test_no_optin_means_no_spcid_and_no_wire,
	test_exposure_rides_consent_gated_queue_with_strict_props,
	test_outcome_props_validation_and_no_dedupe,
	test_producers_consent_gating_unknown_and_denied_drop,
	test_producers_refuse_without_assigned_decision,
	test_synthetic_unit_fact_uses_response_assignment_key,
	test_exposure_dedupe_is_per_launch,
	test_consent_purge_rearms_undelivered_exposure_dedupe,
	test_facade_reports_not_initialized,
	test_facade_delegates_to_the_default_client,
	test_fetch_after_shutdown_is_rejected,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold experiments tests passed")
