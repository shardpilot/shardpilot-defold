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
-- Scripted answer for ASSIGNMENT requests; the consent and events:batch
-- routes answer their happy-path defaults so consent receipts and fact
-- batches never interfere with the assignment scripting. A test may install
-- a `responder` for per-request scripting (held callbacks, sequences).
local next_status = 200
local next_response_body = nil
local next_response_headers = nil
local responder = nil

http = {
	request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = {
			url = url,
			method = method,
			headers = headers,
			body = body,
			options = options,
		}
		if responder then
			local handled = responder(url, method, callback)
			if handled then
				return
			end
		end
		if url:find("/v1/consent", 1, true) then
			callback(nil, nil, { status = 200, response = "{}" })
			return
		end
		if url:find("/v1/events:batch", 1, true) then
			callback(nil, nil, { status = 202, response = '{"accepted":1}' })
			return
		end
		local response = { status = next_status, response = next_response_body }
		if next_response_headers then
			response.headers = next_response_headers
		end
		callback(nil, nil, response)
	end,
}

-- The same minimal JSON encoder/decoder the other harnesses use. Real Defold
-- ships json.encode/json.decode; the SDK uses them only when present.
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
		pos = pos + 1
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
		pos = pos + 1
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
			pos = pos + 1
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
		pos = pos + 1
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

local function assert_match(value, pattern, message)
	if type(value) ~= "string" or not value:match(pattern) then
		error((message or "pattern not matched") .. ": " .. tostring(pattern) .. " against " .. tostring(value), 2)
	end
end

local function reset()
	requests = {}
	next_status = 200
	next_response_body = nil
	next_response_headers = nil
	responder = nil
	storage.reset()
end

-- Advance the mock clock by whole seconds (each gettime() call additionally
-- self-advances 0.1 s; tests use generous margins around that drift).
local function advance_seconds(seconds)
	socket.now = socket.now + seconds
end

-- A fake sys persistence layer (mirrors shardpilot/storage.lua's contract) so
-- restart-shaped tests exercise the real durable path, not just the memory
-- fallback. Returns (restore, stores, state); `state.fail_save(path, record)`
-- may be set to make selected writes fail (durability-failure tests).
local function install_fake_sys_storage()
	local stores = {}
	local state = {}
	local saved_get = sys.get_save_file
	local saved_save = sys.save
	local saved_load = sys.load
	sys.get_save_file = function(application_id, file_name)
		return application_id .. "/" .. file_name
	end
	sys.save = function(path, record)
		if state.fail_save and state.fail_save(path, record) then
			return false
		end
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
	end, stores, state
end

-- A predicate for state.fail_save that fails only the experiments-cache
-- writes (the identity record keeps persisting, so sibling clients share
-- one subject id).
local function fail_experiment_saves(path)
	return path:sub(-#"/experiments") == "/experiments"
end

-- Token-shaped fixture values are built from obviously synthetic constant
-- repeats — never realistic identifier bodies.
local fixture_assignment_key = "asgn_" .. string.rep("a", 32)
local fixture_subject_fact_key = "sfk1_" .. string.rep("b", 64)

-- The default config: Mode A with remote config AND experiments enabled.
-- The flush cadence is parked far away so queued facts stay inspectable and
-- update()-driven ticks never flush mid-test.
local function config(overrides)
	local out = {
		ingest_url = "http://localhost:8080",
		remote_config_url = "http://localhost:18081",
		workspace_id = "workspace-test",
		app_id = "app-test",
		environment_id = "develop",
		anonymous_id = "anon-client",
		api_key = "sp_ingest_publishable_key",
		experiments_enabled = true,
		batch_size = 100,
		flush_interval_seconds = 3600,
		publish_timeout_seconds = 2,
	}
	for key, value in pairs(overrides or {}) do
		out[key] = value
	end
	return out
end

local storage_scope = { workspace_id = "workspace-test", app_id = "app-test" }

local function seed_granted_consent()
	storage.save(storage_scope, { consent_analytics = "granted" })
end

local function granted_client(overrides)
	seed_granted_consent()
	return assert(sdk.new(config(overrides)))
end

local function assignment_body(overrides)
	local out = {
		app_key = "app-test",
		environment_key = "develop",
		experiment_key = "exp-checkout",
		version = 3,
		assigned = true,
		assignment_key = fixture_assignment_key,
		variant_key = "treatment",
		variant_payload = { color = "blue", limit = 5 },
		subject_fact_key = fixture_subject_fact_key,
		boundary = {
			assignment_unit = "client_id",
			subject_key_kind = "client_id_pseudonymous",
			production_rollout = "flag_gated_dark",
		},
	}
	for key, value in pairs(overrides or {}) do
		out[key] = value
	end
	return json.encode(out)
end

local function not_assigned_body(reason)
	local out = {
		version = 3,
		assigned = false,
		boundary = { assignment_unit = "client_id" },
	}
	out.reason = reason
	return json.encode(out)
end

local function is_assignment_request(request)
	return request.url:find("/api/v1/runtime/experiments/assignment", 1, true) ~= nil
end

local function assignment_requests()
	local out = {}
	for i = 1, #requests do
		if is_assignment_request(requests[i]) then
			out[#out + 1] = requests[i]
		end
	end
	return out
end

local function last_assignment_request()
	local list = assignment_requests()
	return list[#list]
end

local function decode_component(value)
	return (value:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

-- The url's query as a name → value map plus the ordered name list.
local function query_params(url)
	local out = {}
	local order = {}
	local query = url:match("%?(.*)$") or ""
	for name, value in query:gmatch("([^=&]+)=([^&]*)") do
		local decoded = decode_component(name)
		out[decoded] = decode_component(value)
		order[#order + 1] = decoded
	end
	return out, order
end

-- Drive one fetch to completion (the http stub answers synchronously) and
-- return the result the callback received.
local function fetch(client, experiment_key, attributes)
	local result = nil
	client:fetch_experiment_assignment(experiment_key, attributes, function(value)
		result = value
	end)
	assert_true(result ~= nil, "the fetch callback must have been invoked")
	return result
end

local function queued_events(client, event_name)
	local out = {}
	for i = 1, #client.queue.items do
		local event = client.queue.items[i]
		if event_name == nil or event.event_name == event_name then
			out[#out + 1] = event
		end
	end
	return out
end

local subject_grammar = "^spcid_[%w_%-]+$"

-- ── configuration and the dark flag ───────────────────────────────────────────

local function test_config_validation()
	reset()
	local client, err = sdk.new(config({ experiments_enabled = 42 }))
	assert_equal(client, nil)
	assert_equal(err, "invalid_experiments_enabled")

	client, err = sdk.new(config({ experiments_enabled = "yes" }))
	assert_equal(client, nil)
	assert_equal(err, "invalid_experiments_enabled")

	-- The assignment endpoint lives on the control-plane host the
	-- remote-config base names, so the flag requires that base URL.
	local no_base = config()
	no_base.remote_config_url = nil
	client, err = sdk.new(no_base)
	assert_equal(client, nil)
	assert_equal(err, "experiments_requires_remote_config_url")

	-- Default off: the consumer is not constructed.
	local off = config()
	off.experiments_enabled = nil
	client = assert(sdk.new(off))
	assert_nil(client.experiments, "the consumer must not exist while the flag is off")

	client = assert(sdk.new(config()))
	assert_true(client.experiments ~= nil, "the consumer must exist when the flag is on")
end

local function test_flag_off_zero_paths()
	reset()
	local restore, stores = install_fake_sys_storage()
	seed_granted_consent()
	local off = config()
	off.experiments_enabled = nil
	local client = assert(sdk.new(off))

	local result = nil
	local ok, err = client:fetch_experiment_assignment("exp-checkout", nil, function(value)
		result = value
	end)
	assert_equal(ok, false)
	assert_equal(err, "experiments_not_configured")
	assert_equal(result.error, "experiments_not_configured")
	assert_nil(client:experiment_variant("exp-checkout"))
	assert_nil(client:experiment_payload("exp-checkout"))
	ok, err = client:track_exposure("exp-checkout")
	assert_equal(err, "experiments_not_configured")
	ok, err = client:track_outcome("exp-checkout", "score", 1)
	assert_equal(err, "experiments_not_configured")
	client:update(0.016)
	client:update(0.016)

	assert_equal(#assignment_requests(), 0, "the dark flag must produce zero assignment requests")
	for path in pairs(stores) do
		assert_nil(path:match("/experiments$"), "the dark flag must create no experiments persistence")
	end
	local identity = storage.load(storage_scope)
	assert_nil(identity.experiments_client_id, "the dark flag must not mint a subject id")
	restore()
end

-- ── fetch happy path ──────────────────────────────────────────────────────────

local function test_fetch_happy_path_and_boundary_passthrough()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()

	local result = fetch(client, "exp-checkout")

	assert_true(result.ok, result.error)
	assert_equal(result.assigned, true)
	assert_equal(result.from_cache, false)
	assert_equal(result.variant_key, "treatment")
	assert_equal(result.variant_payload.color, "blue")
	assert_equal(result.variant_payload.limit, 5)
	assert_equal(result.version, 3)
	-- Boundary passthrough: served for host introspection; only
	-- assignment_unit is contract-relevant to the SDK itself.
	assert_equal(result.boundary.assignment_unit, "client_id")
	assert_equal(result.boundary.production_rollout, "flag_gated_dark")

	local request = last_assignment_request()
	assert_equal(request.method, "GET")
	assert_match(request.url,
		"^http://localhost:18081/api/v1/runtime/experiments/assignment%?")
	assert_equal(request.headers["Authorization"], "Bearer sp_ingest_publishable_key",
		"the assignment fetch authenticates with the publishable key")
	assert_nil(request.headers["X-ShardPilot-Schema-Revision"],
		"the assignment fetch must not carry the schema-revision header")
	assert_nil(request.body, "an assignment fetch carries no request body")
	assert_equal(request.options.timeout, 2)

	local params = query_params(request.url)
	assert_equal(params.app_key, "app-test")
	assert_equal(params.environment_key, "develop")
	assert_equal(params.experiment_key, "exp-checkout")
	assert_match(params.subject_key, subject_grammar,
		"the subject key must be an SDK-minted spcid id")
	assert_equal(#params.subject_key, 38, "spcid_ + 32 hex body")

	-- Getters serve the cached assignment; payload copies are defensive.
	assert_equal(client:experiment_variant("exp-checkout"), "treatment")
	local payload = client:experiment_payload("exp-checkout")
	payload.color = "mutated"
	assert_equal(client:experiment_payload("exp-checkout").color, "blue",
		"a served payload copy must not corrupt the cached entry")

	-- The durable record was written for this exact scope.
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil, "the fetch must persist a cache record")
	assert_true(record.entries["exp-checkout"] ~= nil)
	assert_equal(record.entries["exp-checkout"].variant_key, "treatment")
	assert_equal(record.scope, experiments.build_scope(
		"workspace-test", "develop", params.subject_key, "http://localhost:18081"))
end

local function test_optional_attributes_argument_shift()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	local result = nil
	client:fetch_experiment_assignment("exp-checkout", function(value)
		result = value
	end)
	assert_true(result ~= nil and result.ok, "the (key, callback) shape must work")
end

-- ── the SDK-managed subject id ────────────────────────────────────────────────

local function test_no_host_override_path_for_subject_id()
	reset()
	seed_granted_consent()
	local injected = "spcid_" .. string.rep("c", 32)
	-- A config field carrying a subject id is not part of the configuration
	-- contract and must be ignored outright.
	local client = assert(sdk.new(config({ experiments_client_id = injected })))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local params = query_params(last_assignment_request().url)
	assert_true(params.subject_key ~= injected,
		"a host-supplied subject id must never reach the wire")
	assert_true(client.experiments_client_id ~= injected,
		"a host-supplied subject id must never be adopted")
end

local function test_subject_id_persists_and_reloads()
	reset()
	local restore = install_fake_sys_storage()
	local first = granted_client()
	next_response_body = assignment_body()
	fetch(first, "exp-checkout")
	local minted = query_params(last_assignment_request().url).subject_key
	assert_match(minted, subject_grammar)
	assert_equal(storage.load(storage_scope).experiments_client_id, minted,
		"the minted subject id must persist in the identity record")

	-- A later launch reuses the persisted id verbatim (stickiness).
	local second = assert(sdk.new(config()))
	fetch(second, "exp-checkout")
	assert_equal(query_params(last_assignment_request().url).subject_key, minted,
		"a relaunch must reuse the persisted subject id")
	restore()
end

local function test_no_mint_before_granted_consent()
	reset()
	local client = assert(sdk.new(config()))
	assert_equal(client.consent_state, "unknown")
	local before = #requests
	local ok, err = client:fetch_experiment_assignment("exp-checkout", function() end)
	assert_equal(ok, false)
	assert_equal(err, "consent_unknown")
	assert_equal(#requests, before, "an undecided session must produce no request")
	assert_nil(client.experiments_client_id,
		"no subject id is minted while consent is not granted")
end

local function test_corrupt_subject_id_reminted_on_load()
	reset()
	local restore = install_fake_sys_storage()
	storage.save(storage_scope, {
		consent_analytics = "granted",
		experiments_client_id = "not a subject id!",
	})
	local client = assert(sdk.new(config()))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local minted = query_params(last_assignment_request().url).subject_key
	assert_match(minted, subject_grammar)
	assert_true(minted ~= "not a subject id!",
		"a non-conforming stored id must be replaced, never sent")
	assert_equal(storage.load(storage_scope).experiments_client_id, minted)
	restore()
end

local function test_identity_rewrite_carries_subject_id_forward()
	reset()
	local restore = install_fake_sys_storage()
	local kept = "spcid_" .. string.rep("d", 32)
	storage.save(storage_scope, {
		consent_analytics = "granted",
		experiments_client_id = kept,
	})
	-- The flag is OFF here: the consumer never runs, but an identity-record
	-- rewrite (config anonymous_id differs from the stored record) must not
	-- drop the previously minted id — dropping would re-bucket the subject
	-- on a later re-enable.
	local off = config()
	off.experiments_enabled = nil
	assert(sdk.new(off))
	assert_equal(storage.load(storage_scope).experiments_client_id, kept,
		"an identity rewrite must carry the subject id forward")
	restore()
end

local function test_grammar_400_reminted_once()
	reset()
	local client = granted_client()
	local grammar_reject = json.encode({
		error = "experiment metadata must use synthetic local-safe identifiers only",
	})
	local answers = 0
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		answers = answers + 1
		if answers == 1 then
			callback(nil, nil, { status = 400, response = grammar_reject })
		else
			callback(nil, nil, { status = 200, response = assignment_body() })
		end
		return true
	end

	local result = fetch(client, "exp-checkout")
	assert_true(result.ok, result.error)
	assert_equal(result.assigned, true)
	local sent = assignment_requests()
	assert_equal(#sent, 2, "the grammar reject must re-mint once and retry")
	local first_subject = query_params(sent[1].url).subject_key
	local second_subject = query_params(sent[2].url).subject_key
	assert_match(second_subject, subject_grammar)
	assert_true(first_subject ~= second_subject,
		"the retry must carry a freshly minted subject id")

	-- A second grammar reject with a fresh mint is a bug, never a loop.
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		callback(nil, nil, { status = 400, response = grammar_reject })
		return true
	end
	local before = #assignment_requests()
	result = fetch(client, "exp-checkout")
	assert_equal(result.error, "bad_request")
	assert_equal(#assignment_requests(), before + 1,
		"a repeated grammar reject must not retry again")
end

-- ── not-assigned shapes ───────────────────────────────────────────────────────

local function test_three_not_assigned_shapes_drop_cache()
	reset()
	local shapes = {
		{ nil, "the legacy reason-absent traffic-gate miss" },
		{ "targeting_unmatched", "targeting_unmatched" },
		{ "kill_switch", "kill_switch" },
	}
	for _, shape in ipairs(shapes) do
		reset()
		local client = granted_client()
		next_response_body = assignment_body()
		fetch(client, "exp-checkout")
		assert_equal(client:experiment_variant("exp-checkout"), "treatment")

		next_response_body = not_assigned_body(shape[1])
		local result = fetch(client, "exp-checkout")
		assert_true(result.ok, result.error)
		assert_equal(result.assigned, false, shape[2])
		assert_equal(result.reason, shape[1], shape[2])
		assert_nil(result.variant_key)
		assert_nil(client:experiment_variant("exp-checkout"),
			"every not-assigned shape must stop serving the variant: " .. shape[2])
		local record = storage.load_experiments(client.config)
		assert_true(record == nil or record.entries["exp-checkout"] == nil,
			"every not-assigned shape must drop the durable entry: " .. shape[2])
	end
end

local function test_kill_switch_drops_durably_and_never_exposes()
	reset()
	local restore = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 1,
		"the applied assignment emits one exposure")

	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	assert_nil(client:experiment_variant("exp-checkout"))
	assert_equal(#queued_events(client, "experiment_exposure"), 1,
		"a kill must emit no further exposure")

	-- The kill survives the process: a relaunch restores nothing, serves
	-- nothing, exposes nothing.
	local relaunch = assert(sdk.new(config()))
	assert_nil(relaunch:experiment_variant("exp-checkout"),
		"a killed assignment must not be revived by a relaunch")
	relaunch:update(0.016)
	assert_equal(#queued_events(relaunch, "experiment_exposure"), 0,
		"a relaunch after a kill must emit no exposure")
	restore()
end

-- ── error contract ────────────────────────────────────────────────────────────

local function test_unauthorized_fails_closed_and_halts_revalidation()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	next_status = 401
	next_response_body = json.encode({ error = "invalid runtime token" })
	local result = fetch(client, "exp-checkout")
	assert_equal(result.ok, false)
	assert_equal(result.error, "unauthorized")
	assert_nil(result.variant_key, "an unauthorized answer must never serve the cache")
	assert_nil(client:experiment_variant("exp-checkout"),
		"fail closed: serving stops after 401")
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"the durable record itself is left untouched on a plain 401")

	-- Revalidation halts while latched: no request fires on the cadence.
	local before = #assignment_requests()
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), before,
		"revalidation must halt after an unauthorized answer")

	-- The user-triggered path stays open and a success unlatches.
	next_status = 200
	next_response_body = assignment_body()
	next_response_headers = nil
	result = fetch(client, "exp-checkout")
	assert_true(result.ok and result.assigned)
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"a later authorized fetch resumes serving")
end

local function test_dark_server_403_is_fail_closed()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	next_status = 403
	next_response_body = json.encode({ error = "experiment assignment fetch is disabled" })
	local result = fetch(client, "exp-checkout")
	assert_equal(result.error, "unauthorized")
	assert_nil(client:experiment_variant("exp-checkout"))
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"a dark-flag 403 keeps the durable record for a later re-init")
end

local function test_real_subjects_sentinel_drops_durable_cache()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	local result = fetch(client, "exp-checkout")
	assert_equal(result.error, "unauthorized")
	assert_nil(client:experiment_variant("exp-checkout"))
	local record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"the real-subjects sentinel must drop the cached assignment and its fact key")
end

local function test_404_is_permanent_and_stops_revalidating()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	next_status = 404
	next_response_body = json.encode({ error = "published experiment not found" })
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok, "a 404 answers as first-class not-assigned")
	assert_equal(result.assigned, false)
	assert_equal(result.error, "not_found")
	assert_nil(client:experiment_variant("exp-checkout"),
		"a 404 must never serve the stale assignment")

	local before = #assignment_requests()
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), before,
		"nothing is left cached, so revalidation must stop asking")
end

local function test_503_serves_stale_and_keeps_retrying()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	next_status = 503
	next_response_body = json.encode({ error = "kill switch state unavailable" })
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok, "the kill-state-unavailable answer serves last-known-good")
	assert_equal(result.from_cache, true)
	assert_equal(result.variant_key, "treatment")
	assert_equal(result.error, "transient_503")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"serving continues through a transient failure")

	-- The cadence keeps retrying (transient never latches).
	local before = #assignment_requests()
	advance_seconds(400)
	client:update(0.016)
	assert_true(#assignment_requests() > before,
		"revalidation must keep retrying through 503")
end

local function test_offline_and_timeout_serve_stale()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	for _, case in ipairs({ { 0, "http_0" }, { 408, "transient_408" } }) do
		next_status = case[1]
		next_response_body = nil
		local result = fetch(client, "exp-checkout")
		assert_true(result.ok, "a transient failure with a cache must serve the snapshot")
		assert_equal(result.from_cache, true)
		assert_equal(result.error, case[2])
		assert_equal(result.variant_key, "treatment")
	end
	-- Without a cache the same failures fail.
	next_status = 0
	local result = fetch(client, "exp-other")
	assert_equal(result.ok, false)
	assert_equal(result.error, "http_0")
end

local function test_retry_after_paces_revalidation()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local base = #assignment_requests()

	-- The cadence fires and meets a 429 carrying Retry-After: 600.
	next_status = 429
	next_response_body = nil
	next_response_headers = { ["retry-after"] = "600" }
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 1, "the cadence must have fired once")

	-- Inside the server-requested window nothing fires, even though the
	-- jittered cadence deadline has long passed.
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 1,
		"Retry-After must hold the cadence")

	-- Past the window the cadence resumes.
	next_status = 200
	next_response_body = assignment_body()
	next_response_headers = nil
	advance_seconds(300)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 2,
		"the cadence must resume after the Retry-After window")
end

local function test_retry_after_honored_on_5xx()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local base = #assignment_requests()

	next_status = 503
	next_response_body = nil
	next_response_headers = { ["Retry-After"] = "900" }
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 1)

	advance_seconds(600)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 1,
		"a 5xx Retry-After must hold the cadence exactly like a 429")

	advance_seconds(600)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 2)
end

-- ── attributes ────────────────────────────────────────────────────────────────

local function test_attribute_passthrough_trim_and_bounds()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout", {
		geo = " EU ",
		app_version = "1.2.3",
		device_type = true,
		install_date = 20260101,
		user_segment = string.rep("x", 600),
		custom_attribute_cohort = "beta",
		["custom_attribute_" .. string.rep("s", 65)] = "overlong-name",
		invented_name = "never-sent",
	})
	local params = query_params(last_assignment_request().url)
	assert_equal(params.geo, "EU", "values are trimmed")
	assert_equal(params.app_version, "1.2.3")
	assert_equal(params.device_type, "true", "booleans are stringified")
	assert_equal(params.install_date, "20260101", "numbers are stringified")
	assert_nil(params.user_segment, "an oversized value is dropped, never sent")
	assert_equal(params.custom_attribute_cohort, "beta")
	assert_nil(params["custom_attribute_" .. string.rep("s", 65)],
		"a custom name with an overlong suffix is dropped")
	assert_nil(params.invented_name, "names outside the vocabulary are never sent")
end

local function test_attribute_count_cap_in_sorted_order()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	local attributes = {}
	for i = 1, 70 do
		attributes[string.format("custom_attribute_c%03d", i)] = "v"
	end
	fetch(client, "exp-checkout", attributes)
	local params = query_params(last_assignment_request().url)
	local sent = 0
	for name in pairs(params) do
		if name:match("^custom_attribute_") then
			sent = sent + 1
		end
	end
	assert_equal(sent, 64, "at most 64 attributes ride one fetch")
	assert_equal(params.custom_attribute_c001, "v")
	assert_equal(params.custom_attribute_c064, "v")
	assert_nil(params.custom_attribute_c065,
		"the cap drops in sorted-key order, matching the server")
end

-- ── revalidation ──────────────────────────────────────────────────────────────

local function test_revalidation_cadence_jitter_and_attribute_resend()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout", { geo = "EU" })
	local base = #assignment_requests()

	-- Well before the window floor (270 s) nothing fires.
	advance_seconds(200)
	client:update(0.016)
	assert_equal(#assignment_requests(), base,
		"the cadence must not fire before the jittered interval")

	-- Past the window ceiling (330 s) it must have fired, re-sending the
	-- last host-supplied attributes for the entry.
	advance_seconds(200)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 1,
		"the cadence must fire past the interval")
	local params = query_params(last_assignment_request().url)
	assert_equal(params.geo, "EU",
		"revalidation re-sends the last host-supplied attributes")
	assert_equal(params.experiment_key, "exp-checkout")

	-- The jitter itself stays inside ±10%.
	local ex = client.experiments
	for _ = 1, 25 do
		ex:arm_revalidation(0)
		assert_true(ex.revalidate_at_ms >= 270000 and ex.revalidate_at_ms <= 330000,
			"the jittered interval must stay within 300s ±10%")
	end
end

local function test_revalidation_kill_drops_mid_session()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment")

	-- The operator kill reaches the client on the next cadence tick.
	next_response_body = not_assigned_body("kill_switch")
	advance_seconds(400)
	client:update(0.016)
	assert_nil(client:experiment_variant("exp-checkout"),
		"a kill delivered by revalidation stops serving at the next resolution")
	local record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil)
end

local function test_variant_change_applies_at_resolution()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment")

	-- A republish re-buckets: the next resolution applies the new variant
	-- (no mid-session guard beyond the fetch cadence).
	next_response_body = assignment_body({
		version = 4,
		variant_key = "control",
		assignment_key = "asgn_" .. string.rep("e", 32),
	})
	advance_seconds(400)
	client:update(0.016)
	assert_equal(client:experiment_variant("exp-checkout"), "control",
		"the revalidated variant applies at its resolution")
end

local function test_no_revalidation_without_consumer_state()
	reset()
	local client = granted_client()
	-- Nothing cached, nothing requested: ticks must not fetch.
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), 0)
end

-- ── exposure lane ─────────────────────────────────────────────────────────────

local function test_exposure_auto_emit_once_with_deterministic_id()
	reset()
	local client = granted_client()
	client:identify("user-with-account")
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1, "the first application emits exactly one exposure")
	local fact = exposures[1]
	assert_equal(fact.props.experiment_key, "exp-checkout")
	assert_equal(fact.props.experiment_version, 3)
	assert_equal(fact.props.assignment_key, fixture_subject_fact_key,
		"a client_id-unit fact carries the subject-fact key verbatim")
	assert_equal(fact.props.variant_key, "treatment")
	assert_equal(fact.props.assignment_unit, "client_id")
	assert_nil(fact.user_id, "experiment facts omit user_id even when identified")
	assert_equal(fact.anonymous_id, "anon-client",
		"the envelope identity stays the standard anonymous id")
	local subject = client.experiments_client_id
	assert_equal(fact.event_id, experiments.exposure_event_id(
		client.experiments.session_marker, subject, "exp-checkout", 3, 0),
		"the exposure event id is the deterministic derivation")

	-- Re-fetching the same assignment does not re-emit.
	fetch(client, "exp-checkout")
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 1,
		"one exposure per (experiment, version, subject) per session")

	-- The explicit re-arm emits again with a distinct deterministic id.
	assert_true(client:track_exposure("exp-checkout"))
	local rearmed = queued_events(client, "experiment_exposure")
	assert_equal(#rearmed, 2)
	assert_true(rearmed[2].event_id ~= rearmed[1].event_id,
		"a re-arm derives a distinct id")
	assert_equal(rearmed[2].event_id, experiments.exposure_event_id(
		client.experiments.session_marker, subject, "exp-checkout", 3, 1))
end

local function test_exposure_event_id_derivation_is_stable()
	local subject = "spcid_" .. string.rep("f", 32)
	local a = experiments.exposure_event_id("marker", subject, "exp", 3, 0)
	local b = experiments.exposure_event_id("marker", subject, "exp", 3, 0)
	assert_equal(a, b, "the same tuple derives the same id")
	assert_match(a, "^%x+%-%x+%-%x+%-%x+%-%x+$")
	assert_true(a ~= experiments.exposure_event_id("marker", subject, "exp", 3, 1),
		"the arm counter varies the id")
	assert_true(a ~= experiments.exposure_event_id("marker", subject, "exp", 4, 0),
		"the version varies the id")
	assert_true(a ~= experiments.exposure_event_id("other", subject, "exp", 3, 0),
		"the session marker varies the id")
	assert_true(a ~= experiments.exposure_event_id("marker", "spcid_" .. string.rep("0", 32),
		"exp", 3, 0),
		"the subject varies the id")
end

local function test_exposure_version_change_rearms()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 1)
	-- A republished version is a new tuple: one more exposure.
	next_response_body = assignment_body({ version = 4 })
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 2,
		"a version change re-arms the exposure")
end

local function test_restart_restores_cache_serves_offline_and_exposes_once()
	reset()
	local restore = install_fake_sys_storage()
	local first = granted_client()
	next_response_body = assignment_body()
	fetch(first, "exp-checkout")
	local first_exposure = queued_events(first, "experiment_exposure")[1]

	-- A relaunch serves the persisted assignment before (and without) any
	-- fetch, even offline.
	local second = assert(sdk.new(config()))
	assert_equal(second:experiment_variant("exp-checkout"), "treatment",
		"the restored cache serves before any fetch")
	next_status = 0
	next_response_body = nil
	local result = fetch(second, "exp-checkout")
	assert_true(result.ok, "an offline relaunch serves last-known-good")
	assert_equal(result.from_cache, true)
	assert_equal(result.variant_key, "treatment")

	-- The restored application emits one exposure for the NEW session, with
	-- a distinct deterministic id.
	second:update(0.016)
	second:update(0.016)
	local exposures = queued_events(second, "experiment_exposure")
	assert_equal(#exposures, 1, "a restored assignment exposes once per session")
	assert_true(exposures[1].event_id ~= first_exposure.event_id,
		"each session derives its own exposure id")
	restore()
end

local function test_corrupt_cache_record_is_a_miss()
	reset()
	local restore, stores = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local path = nil
	for key in pairs(stores) do
		if key:match("/experiments$") then
			path = key
		end
	end
	assert_true(path ~= nil, "the durable record must exist")
	stores[path] = { scope = 42, entries = "garbled" }
	local relaunch = assert(sdk.new(config()))
	assert_nil(relaunch:experiment_variant("exp-checkout"),
		"a corrupt cache record reads as a miss")
	restore()
end

-- ── consent integration ───────────────────────────────────────────────────────

local function test_fetch_requires_granted_consent()
	reset()
	local client = assert(sdk.new(config()))
	local before = #requests
	local result = nil
	local ok, err = client:fetch_experiment_assignment("exp-checkout", function(value)
		result = value
	end)
	assert_equal(ok, false)
	assert_equal(err, "consent_unknown")
	assert_equal(result.error, "consent_unknown")
	assert_equal(#requests, before)

	assert_true(client:set_consent(false))
	ok, err = client:fetch_experiment_assignment("exp-checkout", function() end)
	assert_equal(err, "consent_denied")
	local list = assignment_requests()
	assert_equal(#list, 0, "no assignment request under unknown or denied")
end

local function test_consent_downgrade_stops_serving_and_regrant_resumes()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment")

	assert_true(client:set_consent(false))
	assert_nil(client:experiment_variant("exp-checkout"),
		"a downgrade serves nothing")
	assert_nil(client:experiment_payload("exp-checkout"))
	local ok, err = client:track_exposure("exp-checkout")
	assert_equal(ok, false)
	assert_equal(err, "consent_denied", "the emit path refuses with the distinct code")
	assert_equal(#queued_events(client), 0, "nothing is queued while denied")
	local spooled = storage.load_spool(client.config)
	assert_equal(#spooled, 0, "nothing is spooled while denied")
	local before = #assignment_requests()
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), before,
		"the revalidation timer does not run while denied")
	-- The cache record is retained unserved (fail closed, not destroyed).
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"the durable record is retained through a downgrade")

	assert_true(client:set_consent(true))
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"a re-grant serves the retained assignment again")
end

local function test_forced_minor_zero_traffic_on_both_planes()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	assert_true(client:set_consent("denied_forced_minor"))
	local baseline = #requests

	-- Assignment plane: nothing fetches, nothing revalidates, nothing
	-- serves, nothing mints.
	local ok, err = client:fetch_experiment_assignment("exp-checkout", function() end)
	assert_equal(ok, false)
	assert_equal(err, "consent_denied")
	assert_nil(client:experiment_variant("exp-checkout"))
	advance_seconds(400)
	client:update(0.016)
	advance_seconds(400)
	client:update(0.016)

	-- Analytics plane: no exposure, no outcome, nothing queued or spooled.
	ok, err = client:track_exposure("exp-checkout")
	assert_equal(ok, false)
	assert_equal(err, "consent_denied")
	ok, err = client:track_outcome("exp-checkout", "score", 1)
	assert_equal(ok, false)
	assert_equal(err, "consent_denied")
	assert_equal(#queued_events(client), 0)
	assert_equal(#storage.load_spool(client.config), 0)
	assert_equal(#requests, baseline,
		"a forced-minor session produces zero experiment requests on both planes")
end

-- ── outcome facts ─────────────────────────────────────────────────────────────

local function test_track_outcome_stamps_cached_assignment()
	reset()
	local client = granted_client()
	client:identify("user-with-account")
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	assert_true(client:track_outcome("exp-checkout", "score", 12.5))
	local outcomes = queued_events(client, "experiment_outcome")
	assert_equal(#outcomes, 1)
	local fact = outcomes[1]
	assert_equal(fact.props.experiment_key, "exp-checkout")
	assert_equal(fact.props.experiment_version, 3)
	assert_equal(fact.props.assignment_key, fixture_subject_fact_key)
	assert_equal(fact.props.variant_key, "treatment")
	assert_equal(fact.props.assignment_unit, "client_id")
	assert_equal(fact.props.outcome_key, "score")
	assert_equal(fact.props.outcome_value, 12.5)
	assert_nil(fact.user_id, "outcome facts omit user_id")

	-- Each call is a distinct fact.
	assert_true(client:track_outcome("exp-checkout", "score", 13))
	local again = queued_events(client, "experiment_outcome")
	assert_equal(#again, 2)
	assert_true(again[2].event_id ~= again[1].event_id)

	local ok, err = client:track_outcome("exp-unknown", "score", 1)
	assert_equal(ok, false)
	assert_equal(err, "no_assignment")
	ok, err = client:track_outcome("exp-checkout", "", 1)
	assert_equal(err, "invalid_outcome_key")
	ok, err = client:track_outcome("exp-checkout", "score", "twelve")
	assert_equal(err, "invalid_outcome_value")
end

-- ── ordering, teardown, facade ────────────────────────────────────────────────

local function test_out_of_order_responses_do_not_roll_back()
	reset()
	local client = granted_client()

	local held = {}
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		held[#held + 1] = callback
		return true
	end
	local results = {}
	client:fetch_experiment_assignment("exp-checkout", function(result)
		results.older = result
	end)
	client:fetch_experiment_assignment("exp-checkout", function(result)
		results.newer = result
	end)
	responder = nil
	assert_equal(#held, 2)

	-- The NEWER request answers first with version 4...
	held[2](nil, nil, { status = 200, response = assignment_body({
		version = 4, variant_key = "control",
	}) })
	assert_equal(client:experiment_variant("exp-checkout"), "control")

	-- ...then the older one completes late with the older assignment: its
	-- caller still receives that response, but nothing installs over the
	-- newer one.
	held[1](nil, nil, { status = 200, response = assignment_body() })
	assert_true(results.older.ok)
	assert_equal(results.older.variant_key, "treatment",
		"the older fetch still reports its own response")
	assert_equal(client:experiment_variant("exp-checkout"), "control",
		"an out-of-order response must not roll the assignment back")
end

local function test_fail_closed_fences_older_inflight_success()
	reset()
	local client = granted_client()
	local held = {}
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		held[#held + 1] = callback
		return true
	end
	client:fetch_experiment_assignment("exp-checkout", function() end)
	client:fetch_experiment_assignment("exp-checkout", function() end)
	responder = nil

	-- The newer fetch fails closed first; the older success lands late and
	-- must not sneak a variant in behind it.
	held[2](nil, nil, { status = 401, response = json.encode({ error = "invalid runtime token" }) })
	held[1](nil, nil, { status = 200, response = assignment_body() })
	assert_nil(client:experiment_variant("exp-checkout"),
		"an older success must not undo a newer fail-closed outcome")
end

local function test_shutdown_never_blocked_by_parked_revalidation()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	-- Park the cadence behind a server-requested window, then tear down.
	next_status = 429
	next_response_body = nil
	next_response_headers = { ["retry-after"] = "600" }
	advance_seconds(400)
	client:update(0.016)
	next_status = 202
	next_response_headers = nil
	next_response_body = nil
	assert_true(client:shutdown(),
		"a parked revalidation must never block shutdown")
	local result = nil
	client:fetch_experiment_assignment("exp-checkout", function(value)
		result = value
	end)
	assert_equal(result.error, "shutdown",
		"a torn-down client dispatches no assignment fetch")
end

local function test_facade_and_capability()
	reset()
	assert_equal(sdk.supports("experiments_assignment"), true)
	assert_equal(sdk.supports("experiments_time_travel"), false)

	-- Before init the facade answers like the remote-config facade.
	local result = nil
	local ok, err = sdk.fetch_experiment_assignment("exp-checkout", function(value)
		result = value
	end)
	assert_equal(ok, false)
	assert_equal(err, "not_initialized")
	assert_equal(result.error, "not_initialized")
	assert_nil(sdk.experiment_variant("exp-checkout"))
	assert_nil(sdk.experiment_payload("exp-checkout"))
	ok, err = sdk.track_exposure("exp-checkout")
	assert_equal(err, "not_initialized")
	ok, err = sdk.track_outcome("exp-checkout", "score", 1)
	assert_equal(err, "not_initialized")

	-- After init the facade delegates.
	seed_granted_consent()
	assert_true(sdk.init(config()))
	next_response_body = assignment_body()
	local delegated = nil
	sdk.fetch_experiment_assignment("exp-checkout", { geo = "EU" }, function(value)
		delegated = value
	end)
	assert_true(delegated ~= nil and delegated.ok, "the facade delegates the fetch")
	assert_equal(sdk.experiment_variant("exp-checkout"), "treatment")
	assert_equal(sdk.experiment_payload("exp-checkout").color, "blue")
	assert_true(sdk.track_exposure("exp-checkout"))
	assert_true(sdk.track_outcome("exp-checkout", "score", 1))
	next_status = 202
	next_response_body = nil
	assert_true(sdk.shutdown())
end

-- ── round-1 regressions ───────────────────────────────────────────────────────

local function test_auth_latch_survives_prelatch_inflight_success()
	reset()
	local client = granted_client()
	next_response_body = assignment_body({ experiment_key = "exp-a" })
	fetch(client, "exp-a")
	next_response_body = assignment_body({ experiment_key = "exp-b", variant_key = "beta" })
	fetch(client, "exp-b")

	-- A batched revalidation puts both requests in flight at once.
	local held = {}
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		held[#held + 1] = { url = url, callback = callback }
		return true
	end
	advance_seconds(400)
	client:update(0.016)
	responder = nil
	assert_equal(#held, 2, "both cached entries revalidate in one batch")

	-- One sibling fails closed first...
	held[1].callback(nil, nil, {
		status = 401,
		response = json.encode({ error = "invalid runtime token" }),
	})
	assert_nil(client:experiment_variant("exp-a"))
	assert_nil(client:experiment_variant("exp-b"))

	-- ...and the other — already in flight when the latch landed — answers
	-- 200. It must neither unlatch nor reinstall the revoked assignment.
	held[2].callback(nil, nil, {
		status = 200,
		response = assignment_body({ experiment_key = "exp-b", variant_key = "beta" }),
	})
	assert_nil(client:experiment_variant("exp-b"),
		"a pre-latch in-flight success must not resume serving")
	local before = #assignment_requests()
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), before,
		"a pre-latch in-flight success must not unlatch revalidation")

	-- Only a fetch STARTED AFTER the latch clears it.
	next_status = 200
	next_response_body = assignment_body({ experiment_key = "exp-a" })
	local result = fetch(client, "exp-a")
	assert_true(result.ok and result.assigned)
	assert_equal(client:experiment_variant("exp-a"), "treatment",
		"a post-latch authorized fetch unlatches and serves")
end

local function test_permanent_drop_reaches_disk_after_latch_wipe()
	reset()
	local restore = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body({ experiment_key = "exp-a" })
	fetch(client, "exp-a")
	next_response_body = assignment_body({ experiment_key = "exp-b", variant_key = "beta" })
	fetch(client, "exp-b")

	-- The latch clears the in-memory serving set; the durable record is
	-- deliberately retained.
	next_status = 401
	next_response_body = json.encode({ error = "invalid runtime token" })
	fetch(client, "exp-a")
	local record = storage.load_experiments(client.config)
	assert_true(record.entries["exp-a"] ~= nil and record.entries["exp-b"] ~= nil,
		"the latch retains the durable record")

	-- A post-latch permanent drop must reach the disk even though nothing
	-- is served in memory for the key.
	next_status = 404
	next_response_body = json.encode({ error = "published experiment not found" })
	fetch(client, "exp-a")
	record = storage.load_experiments(client.config)
	assert_nil(record.entries["exp-a"],
		"a permanent drop must reach the durable record after a latch wipe")
	assert_true(record.entries["exp-b"] ~= nil,
		"dropping one experiment must not disturb the sibling's durable entry")

	-- A post-latch reinstall must not clobber retained siblings either.
	next_status = 200
	next_response_body = assignment_body({ experiment_key = "exp-a" })
	fetch(client, "exp-a")
	record = storage.load_experiments(client.config)
	assert_true(record.entries["exp-a"] ~= nil and record.entries["exp-b"] ~= nil,
		"installing one experiment must keep the sibling's durable entry")

	-- The disk state is what a relaunch serves.
	local relaunch = assert(sdk.new(config()))
	assert_equal(relaunch:experiment_variant("exp-a"), "treatment")
	assert_equal(relaunch:experiment_variant("exp-b"), "beta",
		"the retained sibling survives to the next launch")
	restore()
end

local function test_remint_rearms_exposure_for_new_subject()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 1)
	local first_subject = query_params(last_assignment_request().url).subject_key

	-- The stored subject goes bad server-side; the re-minted subject gets
	-- the IDENTICAL assignment answer (same assignment key, same version).
	-- The Q4 tuple is per subject, so the new subject's first application
	-- must emit its own exposure.
	local grammar_reject = json.encode({
		error = "experiment metadata must use synthetic local-safe identifiers only",
	})
	local answers = 0
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		answers = answers + 1
		if answers == 1 then
			callback(nil, nil, { status = 400, response = grammar_reject })
		else
			callback(nil, nil, { status = 200, response = assignment_body() })
		end
		return true
	end
	local result = fetch(client, "exp-checkout")
	responder = nil
	assert_true(result.ok and result.assigned)
	local second_subject = query_params(last_assignment_request().url).subject_key
	assert_true(second_subject ~= first_subject)

	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 2,
		"the re-minted subject's first application must expose again")
	assert_true(exposures[2].event_id ~= exposures[1].event_id,
		"the new subject derives a distinct exposure id")
end

local function test_explicit_fetch_without_attributes_sends_none()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout", { geo = "EU" })
	assert_equal(query_params(last_assignment_request().url).geo, "EU")

	-- A host-triggered fetch that omits attributes means what it says: no
	-- attributes ride, and none become the remembered set.
	fetch(client, "exp-checkout")
	assert_nil(query_params(last_assignment_request().url).geo,
		"an explicit no-attributes fetch must not reuse the saved set")

	advance_seconds(400)
	client:update(0.016)
	assert_nil(query_params(last_assignment_request().url).geo,
		"the cadence re-sends the LAST host-supplied set — now none")
	assert_equal(query_params(last_assignment_request().url).experiment_key, "exp-checkout")
end

local function test_revalidation_remints_rejected_subject()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local first_subject = query_params(last_assignment_request().url).subject_key
	local base = #assignment_requests()

	-- The server starts rejecting the stored subject's grammar; the CADENCE
	-- must heal it (re-mint once and retry) without waiting for an explicit
	-- host fetch.
	local grammar_reject = json.encode({
		error = "experiment metadata must use synthetic local-safe identifiers only",
	})
	local answers = 0
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		answers = answers + 1
		if answers == 1 then
			callback(nil, nil, { status = 400, response = grammar_reject })
		else
			callback(nil, nil, { status = 200, response = assignment_body() })
		end
		return true
	end
	advance_seconds(400)
	client:update(0.016)
	responder = nil

	assert_equal(#assignment_requests(), base + 2,
		"the revalidation grammar reject must re-mint and retry")
	local healed_subject = query_params(last_assignment_request().url).subject_key
	assert_match(healed_subject, subject_grammar)
	assert_true(healed_subject ~= first_subject,
		"the retry must carry the freshly minted subject")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"the healed subject's assignment installs")
end

local function test_queue_full_exposure_retried_by_tick()
	reset()
	local client = granted_client({ buffer_size = 1 })
	assert_true(client:track("filler"))

	-- The fresh assignment applies while the queue is full: the exposure
	-- emit fails locally and must stay armed instead of being lost.
	next_response_body = assignment_body()
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok and result.assigned)
	assert_equal(client:experiment_variant("exp-checkout"), "treatment")
	assert_equal(#queued_events(client, "experiment_exposure"), 0,
		"the full queue rejected the exposure emit")

	-- Draining the queue and ticking retries the armed exposure.
	assert_true(client:flush({ include_summaries = false }))
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1,
		"the armed exposure must emit once the queue drains")
	assert_equal(exposures[1].props.experiment_key, "exp-checkout")

	-- Still exactly once: the retry consumed the arm.
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 1)
end

local function test_session_renewal_rearms_exposure()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local first = queued_events(client, "experiment_exposure")
	assert_equal(#first, 1)
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 1,
		"one exposure per session while the session lasts")

	-- An explicit session renewal re-arms the once-per-SESSION contract.
	assert_true(client:session_start())
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 2,
		"a renewed session emits its own exposure for the applied assignment")
	assert_true(exposures[2].event_id ~= exposures[1].event_id,
		"each session derives its own deterministic id")
	assert_equal(exposures[2].session_id, client.session_id,
		"the renewed session's exposure rides the new session")

	-- And once only, again.
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 2)
end

-- ── round-2 regressions ───────────────────────────────────────────────────────

local function test_regenerated_assignment_key_does_not_reexpose()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 1)

	-- The same (experiment, version, subject) tuple answering with a
	-- REGENERATED assignment key is still the same exposure tuple: no
	-- over-counting.
	next_response_body = assignment_body({
		assignment_key = "asgn_" .. string.rep("f", 32),
	})
	fetch(client, "exp-checkout")
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 1,
		"a regenerated assignment key must not re-expose the same tuple")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"the refreshed assignment still serves")
end

local function test_missing_fact_key_skips_facts_and_subject_never_egresses()
	reset()
	local client = granted_client()
	-- A synthetic-unit answer (or any answer without the server-minted
	-- subject-fact key): the assignment applies locally, but NO fact may be
	-- emitted — the SDK-minted subject id never rides the analytics plane
	-- and there is no server-safe key to send instead.
	next_response_body = json.encode({
		version = 3,
		assigned = true,
		assignment_key = fixture_assignment_key,
		variant_key = "treatment",
		variant_payload = { color = "blue" },
		boundary = { assignment_unit = "synthetic_subject_key" },
	})
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok and result.assigned)
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"the assignment still applies locally")
	client:update(0.016)
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 0,
		"no subject-fact key means no exposure fact, ever")

	local ok, err = client:track_exposure("exp-checkout")
	assert_equal(ok, false)
	assert_equal(err, "exposure_no_subject_fact_key")
	ok, err = client:track_outcome("exp-checkout", "score", 1)
	assert_equal(ok, false)
	assert_equal(err, "exposure_no_subject_fact_key")

	-- The egress rule itself: the SDK-minted subject id appears in NO
	-- queued analytics event, in any field.
	local subject = client.experiments_client_id
	assert_true(type(subject) == "string" and subject ~= "")
	for i = 1, #client.queue.items do
		local serialized = json.encode(client.queue.items[i])
		assert_nil(serialized:find(subject, 1, true),
			"the SDK subject id must never appear in an analytics event")
	end
end

local function test_sibling_success_does_not_clear_retry_after()
	reset()
	local client = granted_client()
	next_response_body = assignment_body({ experiment_key = "exp-a" })
	fetch(client, "exp-a")

	-- The cadence meets a long server Retry-After for exp-a...
	next_status = 429
	next_response_body = nil
	next_response_headers = { ["retry-after"] = "900" }
	advance_seconds(400)
	client:update(0.016)
	local deferred_base = #assignment_requests()

	-- ...then an UNRELATED explicit fetch succeeds. The server's wait for
	-- the plane is not rescinded by one admitted request.
	next_status = 200
	next_response_headers = nil
	next_response_body = assignment_body({ experiment_key = "exp-b", variant_key = "beta" })
	fetch(client, "exp-b")
	local base = #assignment_requests()

	next_response_body = assignment_body()
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), base,
		"an unrelated success must not clear the server-set Retry-After")

	-- Past the deadline the cadence resumes for every cached entry.
	advance_seconds(700)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 2,
		"the cadence resumes after the deadline expires on its own")
	assert_true(deferred_base >= 1)
end

local function test_transient_serve_reflects_current_fenced_entry()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment")

	-- Hold one request in flight...
	local held = {}
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		held[#held + 1] = callback
		return true
	end
	local late = nil
	client:fetch_experiment_assignment("exp-checkout", function(result)
		late = result
	end)
	responder = nil
	assert_equal(#held, 1)

	-- ...while a kill resolves and drops the entry...
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	assert_nil(client:experiment_variant("exp-checkout"))

	-- ...then the held request fails transiently. The serve must reflect
	-- the CURRENT fenced state (nothing), never revive the killed variant.
	held[1](nil, nil, { status = 503 })
	assert_equal(late.ok, false,
		"a transient serve must not revive a killed assignment")
	assert_equal(late.error, "transient_503")
	assert_nil(late.variant_key)
end

local function test_midflight_consent_revocation_fails_closed()
	reset()
	local client = granted_client()
	local held = {}
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		held[#held + 1] = callback
		return true
	end
	local result = nil
	client:fetch_experiment_assignment("exp-checkout", function(value)
		result = value
	end)
	responder = nil
	assert_equal(#held, 1)
	local minted = client.experiments_client_id

	-- Consent is revoked while the response is in flight: the late 200
	-- must not install, expose, persist, or report a healthy assignment.
	assert_true(client:set_consent(false))
	held[1](nil, nil, { status = 200, response = assignment_body() })
	assert_equal(result.ok, false)
	assert_equal(result.error, "consent_denied")
	local record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"a revoked-mid-flight response must not persist an assignment")
	assert_true(client:set_consent(true))
	assert_nil(client:experiment_variant("exp-checkout"),
		"nothing was installed for the re-grant to serve")

	-- The remint branch is unreachable post-revocation too: a grammar 400
	-- landing after a revocation mints nothing.
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		held[#held + 1] = callback
		return true
	end
	client:fetch_experiment_assignment("exp-checkout", function() end)
	responder = nil
	assert_true(client:set_consent(false))
	held[2](nil, nil, { status = 400, response = json.encode({
		error = "experiment metadata must use synthetic local-safe identifiers only",
	}) })
	assert_equal(client.experiments_client_id, minted,
		"no subject id is minted after a revocation")
	assert_equal(client.experiments.reminted, false)
end

local function test_prelatch_response_fails_closed_to_caller()
	reset()
	local client = granted_client()
	local held = {}
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		held[#held + 1] = callback
		return true
	end
	local results = {}
	client:fetch_experiment_assignment("exp-a", function(result)
		results.stale = result
	end)
	client:fetch_experiment_assignment("exp-b", function(result)
		results.latch = result
	end)
	responder = nil
	assert_equal(#held, 2)

	-- The latch lands while the first request is still in flight...
	held[2](nil, nil, {
		status = 401,
		response = json.encode({ error = "invalid runtime token" }),
	})
	assert_equal(results.latch.error, "unauthorized")

	-- ...and the stale 200 is discarded from state AND from the caller:
	-- the callback receives the closed result, never a healthy assignment.
	held[1](nil, nil, { status = 200, response = assignment_body({ experiment_key = "exp-a" }) })
	assert_equal(results.stale.ok, false,
		"a pre-latch response must fail closed to its caller too")
	assert_equal(results.stale.error, "unauthorized")
	assert_nil(results.stale.variant_key)
	assert_nil(client:experiment_variant("exp-a"))
end

-- ── round-3 regressions ───────────────────────────────────────────────────────

local function test_failed_refresh_write_never_leaves_superseded_variant()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local record = storage.load_experiments(client.config)
	assert_equal(record.entries["exp-checkout"].variant_key, "treatment")

	-- The refresh write fails (only when the record carries the refreshed
	-- variant — the size-limited shape): the superseded stored entry must
	-- be tombstoned, never left as reload truth.
	state.fail_save = function(path, saved)
		if not fail_experiment_saves(path) then
			return false
		end
		local entry = saved.entries and saved.entries["exp-checkout"]
		return entry ~= nil and entry.variant_key == "control"
	end
	advance_seconds(2)
	next_response_body = assignment_body({ version = 4, variant_key = "control" })
	fetch(client, "exp-checkout")
	assert_equal(client:experiment_variant("exp-checkout"), "control",
		"memory serves the refreshed variant")
	record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"a failed refresh write must tombstone the superseded stored entry")

	-- The owed write converges once storage recovers.
	state.fail_save = nil
	client:update(0.016)
	record = storage.load_experiments(client.config)
	assert_equal(record.entries["exp-checkout"].variant_key, "control",
		"the owed refresh write must land at the next tick")
	local relaunch = assert(sdk.new(config()))
	assert_equal(relaunch:experiment_variant("exp-checkout"), "control")
	restore()
end

local function test_failed_kill_drop_retried_until_durable()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- The kill lands in memory but every durable write fails: the drop is
	-- OWED and retried, and once storage recovers the revoked assignment
	-- leaves the disk — a relaunch must not serve it.
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	assert_nil(client:experiment_variant("exp-checkout"))
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"the failed drop leaves the entry on disk for the moment")

	state.fail_save = nil
	client:update(0.016)
	record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"the owed kill drop must land at the next tick")
	local relaunch = assert(sdk.new(config()))
	assert_nil(relaunch:experiment_variant("exp-checkout"),
		"a relaunch must not revive the killed assignment")
	restore()
end

local function test_drop_preserves_owed_exposure()
	reset()
	local client = granted_client({ buffer_size = 1 })
	assert_true(client:track("filler"))

	-- The assignment applies while the queue is full: the exposure fact is
	-- OWED. A kill then stops serving — but the application already
	-- happened, and its fact must still be emitted.
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0,
		"the full queue kept the exposure owed")
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	assert_nil(client:experiment_variant("exp-checkout"),
		"the kill stops serving")

	assert_true(client:flush({ include_summaries = false }))
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1,
		"the owed exposure for the pre-kill application must still emit")
	assert_equal(exposures[1].props.variant_key, "treatment")
	assert_equal(exposures[1].props.experiment_version, 3)

	-- Once, and no revival of serving.
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 1)
	assert_nil(client:experiment_variant("exp-checkout"))
end

local function test_stale_sibling_write_does_not_clobber_fresher_record()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local first = granted_client()
	-- The first client's cache write fails (identity still persists, so a
	-- sibling shares the same subject id) and stays OWED with an old stamp.
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	next_response_body = assignment_body()
	fetch(first, "exp-checkout")
	state.fail_save = nil

	-- A sibling client fetches FRESHER state and persists it.
	advance_seconds(10)
	local second = assert(sdk.new(config()))
	next_response_body = assignment_body({ version = 4, variant_key = "beta" })
	fetch(second, "exp-checkout")
	local record = storage.load_experiments(second.config)
	assert_equal(record.entries["exp-checkout"].variant_key, "beta")

	-- The first client's owed retry fires — and must NOT roll the shared
	-- record back to its older state.
	first:update(0.016)
	record = storage.load_experiments(first.config)
	assert_equal(record.entries["exp-checkout"].variant_key, "beta",
		"an older owed write must never clobber a fresher sibling record")
	restore()
end

local function test_no_callback_install_or_persist_after_shutdown()
	reset()
	local restore = install_fake_sys_storage()
	local client = granted_client()
	local held = {}
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		held[#held + 1] = callback
		return true
	end
	local result = nil
	client:fetch_experiment_assignment("exp-checkout", function(value)
		result = value
	end)
	responder = nil
	assert_equal(#held, 1)

	next_status = 202
	next_response_body = nil
	assert_true(client:shutdown())

	-- The response lands after teardown: nothing installs, nothing
	-- persists, no exposure is queued, and game code is never called back.
	held[1](nil, nil, { status = 200, response = assignment_body() })
	assert_nil(result, "no callback may run after shutdown")
	assert_nil(client:experiment_variant("exp-checkout"),
		"nothing installs after shutdown")
	local record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"nothing persists after shutdown")
	assert_equal(#queued_events(client, "experiment_exposure"), 0,
		"no exposure is queued after shutdown")
	restore()
end

-- ── round-4 regressions ───────────────────────────────────────────────────────

local function test_clock_rollback_cannot_revive_killed_variant()
	reset()
	local restore = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local record = storage.load_experiments(client.config)
	assert_true(record.entries["exp-checkout"] ~= nil)

	-- The wall clock rolls BACK before the kill resolves: the drop's
	-- resolution stamp is older than the stored entry's, but a drop for the
	-- entry it resolves must always win — a fenced delete would revive the
	-- killed variant at the next launch.
	socket.now = socket.now - 100
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"a clock rollback must not fence the kill drop off the disk")
	local relaunch = assert(sdk.new(config()))
	assert_nil(relaunch:experiment_variant("exp-checkout"),
		"a relaunch must not revive the killed variant")
	restore()
end

local function test_owed_clear_never_wipes_newer_state()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body({ experiment_key = "exp-a" })
	fetch(client, "exp-a")
	next_response_body = assignment_body({ experiment_key = "exp-b", variant_key = "beta" })
	fetch(client, "exp-b")

	-- The real-subjects sentinel arrives while the durable clear fails:
	-- the clear is owed.
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(client, "exp-a")
	state.fail_save = nil

	-- A LATER authorized fetch installs fresh state before the owed clear
	-- lands. The epoch-scoped clear must drop only what it still covers —
	-- the withdrawn sibling — never the newer install.
	next_status = 200
	next_response_body = assignment_body({ experiment_key = "exp-a", variant_key = "fresh" })
	fetch(client, "exp-a")
	client:update(0.016)
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil and record.entries["exp-a"] ~= nil,
		"the owed clear must not wipe newer authorized state")
	assert_equal(record.entries["exp-a"].variant_key, "fresh")
	assert_nil(record.entries["exp-b"],
		"the withdrawn sibling the clear still covers must drop")
	restore()
end

local function test_consent_purge_rearms_unpublished_exposures()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1)
	local original_event_id = exposures[1].event_id

	-- The denial purges the queued-but-unpublished exposure fact; the
	-- session's emission must re-arm so the re-granted assignment counts.
	assert_true(client:set_consent(false))
	assert_equal(#queued_events(client), 0, "the purge cleared the queue")
	assert_true(client:set_consent(true))
	client:update(0.016)
	exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1,
		"the purged exposure must re-emit after a re-grant")
	assert_equal(exposures[1].event_id, original_event_id,
		"the re-emission derives the SAME deterministic id (published"
		.. " duplicates collapse server-side)")

	-- Still once per session: no growth on further ticks.
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 1)
end

local function test_pre_remint_response_reports_stale_subject()
	reset()
	local client = granted_client()
	local held = {}
	local grammar_reject = json.encode({
		error = "experiment metadata must use synthetic local-safe identifiers only",
	})
	local answers = 0
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		if url:find("experiment_key=exp%-a", 1) then
			held[#held + 1] = callback
			return true
		end
		answers = answers + 1
		if answers == 1 then
			callback(nil, nil, { status = 400, response = grammar_reject })
		else
			callback(nil, nil, {
				status = 200,
				response = assignment_body({ experiment_key = "exp-b", variant_key = "beta" }),
			})
		end
		return true
	end
	local stale = nil
	client:fetch_experiment_assignment("exp-a", function(result)
		stale = result
	end)
	assert_equal(#held, 1)

	-- A grammar reject on ANOTHER experiment re-mints the subject while the
	-- first request is still in flight.
	local result = fetch(client, "exp-b")
	responder = nil
	assert_true(result.ok and result.assigned)

	-- The pre-re-mint 200 lands late: the install discards it, and the
	-- caller must receive the miss, never the discarded variant.
	held[1](nil, nil, { status = 200, response = assignment_body({ experiment_key = "exp-a" }) })
	assert_equal(stale.ok, false,
		"a pre-re-mint response must not report a healthy assignment")
	assert_equal(stale.error, "stale_subject")
	assert_nil(stale.variant_key)
	assert_nil(client:experiment_variant("exp-a"))
end

local function test_owed_exposures_queue_across_replacements()
	reset()
	local client = granted_client({ buffer_size = 1 })
	assert_true(client:track("filler"))

	-- Two applications land while the analytics queue is full: BOTH facts
	-- are owed, in order — the second application must not cost the first
	-- its exposure.
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	next_response_body = assignment_body({ version = 4, variant_key = "control" })
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	assert_true(client:flush({ include_summaries = false }))
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1, "the OLDER owed exposure emits first")
	assert_equal(exposures[1].props.experiment_version, 3)
	assert_equal(exposures[1].props.variant_key, "treatment")

	-- Draining again releases the second owed fact, in order.
	assert_true(client:flush({ include_summaries = false }))
	local batch = nil
	for i = #requests, 1, -1 do
		if requests[i].url:find("/v1/events:batch", 1, true) then
			batch = requests[i]
			break
		end
	end
	assert_true(batch ~= nil)
	local published = json.decode(batch.body).events
	assert_equal(published[1].props.experiment_version, 3,
		"the published batch carries the version-3 exposure")
	client:update(0.016)
	exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1)
	assert_equal(exposures[1].props.experiment_version, 4,
		"the newer owed exposure follows once the queue drains")
	assert_equal(exposures[1].props.variant_key, "control")

	-- Nothing further is owed.
	assert_true(client:flush({ include_summaries = false }))
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 0)
end

local tests = {
	test_config_validation,
	test_flag_off_zero_paths,
	test_fetch_happy_path_and_boundary_passthrough,
	test_optional_attributes_argument_shift,
	test_no_host_override_path_for_subject_id,
	test_subject_id_persists_and_reloads,
	test_no_mint_before_granted_consent,
	test_corrupt_subject_id_reminted_on_load,
	test_identity_rewrite_carries_subject_id_forward,
	test_grammar_400_reminted_once,
	test_three_not_assigned_shapes_drop_cache,
	test_kill_switch_drops_durably_and_never_exposes,
	test_unauthorized_fails_closed_and_halts_revalidation,
	test_dark_server_403_is_fail_closed,
	test_real_subjects_sentinel_drops_durable_cache,
	test_404_is_permanent_and_stops_revalidating,
	test_503_serves_stale_and_keeps_retrying,
	test_offline_and_timeout_serve_stale,
	test_retry_after_paces_revalidation,
	test_retry_after_honored_on_5xx,
	test_attribute_passthrough_trim_and_bounds,
	test_attribute_count_cap_in_sorted_order,
	test_revalidation_cadence_jitter_and_attribute_resend,
	test_revalidation_kill_drops_mid_session,
	test_variant_change_applies_at_resolution,
	test_no_revalidation_without_consumer_state,
	test_exposure_auto_emit_once_with_deterministic_id,
	test_exposure_event_id_derivation_is_stable,
	test_exposure_version_change_rearms,
	test_restart_restores_cache_serves_offline_and_exposes_once,
	test_corrupt_cache_record_is_a_miss,
	test_fetch_requires_granted_consent,
	test_consent_downgrade_stops_serving_and_regrant_resumes,
	test_forced_minor_zero_traffic_on_both_planes,
	test_track_outcome_stamps_cached_assignment,
	test_out_of_order_responses_do_not_roll_back,
	test_fail_closed_fences_older_inflight_success,
	test_shutdown_never_blocked_by_parked_revalidation,
	test_facade_and_capability,
	test_auth_latch_survives_prelatch_inflight_success,
	test_permanent_drop_reaches_disk_after_latch_wipe,
	test_remint_rearms_exposure_for_new_subject,
	test_explicit_fetch_without_attributes_sends_none,
	test_revalidation_remints_rejected_subject,
	test_queue_full_exposure_retried_by_tick,
	test_session_renewal_rearms_exposure,
	test_regenerated_assignment_key_does_not_reexpose,
	test_missing_fact_key_skips_facts_and_subject_never_egresses,
	test_sibling_success_does_not_clear_retry_after,
	test_transient_serve_reflects_current_fenced_entry,
	test_midflight_consent_revocation_fails_closed,
	test_prelatch_response_fails_closed_to_caller,
	test_failed_refresh_write_never_leaves_superseded_variant,
	test_failed_kill_drop_retried_until_durable,
	test_drop_preserves_owed_exposure,
	test_stale_sibling_write_does_not_clobber_fresher_record,
	test_no_callback_install_or_persist_after_shutdown,
	test_clock_rollback_cannot_revive_killed_variant,
	test_owed_clear_never_wipes_newer_state,
	test_consent_purge_rearms_unpublished_exposures,
	test_pre_remint_response_reports_stale_subject,
	test_owed_exposures_queue_across_replacements,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold experiments tests passed")
