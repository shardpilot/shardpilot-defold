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
		"workspace-test", "develop", params.subject_key,
		"http://localhost:18081", "sp_ingest_publishable_key"))
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
	-- a distinct deterministic id — once that session EXISTS. The
	-- background tick must not lazily open a session to drain it (a
	-- phantom session would demote the host's first session_start to a
	-- renewal and double-arm); the snapshot waits for the first-session
	-- migration.
	second:update(0.016)
	second:update(0.016)
	assert_equal(#queued_events(second, "experiment_exposure"), 0,
		"the pre-session snapshot is unsweepable by the background tick")
	assert_nil(second.session_id,
		"and the tick opened no phantom analytics session")
	assert_true(second:session_start())
	second:update(0.016)
	local exposures = queued_events(second, "experiment_exposure")
	assert_equal(#exposures, 1, "a restored assignment exposes once per session")
	assert_equal(exposures[1].session_id, second.session_id,
		"attributed to the first real session by the migration")
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

	-- ...then the older one completes late with the older assignment:
	-- nothing installs over the newer one, and the fenced-out caller
	-- receives the SETTLED current assignment — what the getters serve —
	-- never its own superseded body.
	held[1](nil, nil, { status = 200, response = assignment_body() })
	assert_true(results.older.ok and results.older.from_cache)
	assert_equal(results.older.variant_key, "control",
		"the fenced-out fetch reports the settled assignment")
	assert_equal(results.older.error, "superseded")
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

-- ── round-5 regressions ───────────────────────────────────────────────────────

local function test_ordinary_auth_failure_keeps_durable_cache_despite_owed_write()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- A refresh write fails and stays OWED (the tombstone save fails too, so
	-- the ORIGINAL record remains the disk truth).
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	advance_seconds(2)
	next_response_body = assignment_body({ version = 4, variant_key = "control" })
	fetch(client, "exp-checkout")

	-- An ORDINARY 401 then latches fail-closed while that write is still
	-- owed. The documented behavior retains the durable record: the owed
	-- WRITE — its source entry now cleared from memory — must not decay
	-- into a delete at the next retry.
	state.fail_save = nil
	next_status = 401
	next_response_body = json.encode({ error = "invalid runtime token" })
	local latched = fetch(client, "exp-checkout")
	assert_equal(latched.error, "unauthorized")
	client:update(0.016)
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"an ordinary auth failure must retain the durable record")
	assert_equal(record.entries["exp-checkout"].variant_key, "treatment")

	next_status = 200
	next_response_body = nil
	local relaunch = assert(sdk.new(config()))
	assert_equal(relaunch:experiment_variant("exp-checkout"), "treatment",
		"a relaunch serves the retained last-known assignment")
	restore()
end

local function test_fenced_out_response_reports_settled_state()
	reset()
	local client = granted_client()
	local held = {}
	local hold_next = false
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		if hold_next then
			hold_next = false
			held[#held + 1] = callback
			return true
		end
		return false
	end

	-- Phase 1: the newer settled outcome is a MISS (kill). The fenced-out
	-- older 200 must report that miss — never its own discarded variant.
	hold_next = true
	local stale_a = nil
	client:fetch_experiment_assignment("exp-checkout", function(result)
		stale_a = result
	end)
	assert_equal(#held, 1)
	next_response_body = not_assigned_body("kill_switch")
	local newer = fetch(client, "exp-checkout")
	assert_true(newer.ok)
	held[1](nil, nil, { status = 200, response = assignment_body() })
	assert_equal(stale_a.ok, false,
		"a fenced-out response must not deliver its discarded variant")
	assert_equal(stale_a.error, "superseded")
	assert_nil(stale_a.variant_key)
	assert_nil(client:experiment_variant("exp-checkout"))

	-- Phase 2: the newer settled outcome ASSIGNS. The fenced-out response
	-- reports the settled current assignment — exactly what the getters
	-- serve, not the older body's variant.
	hold_next = true
	local stale_b = nil
	client:fetch_experiment_assignment("exp-checkout", function(result)
		stale_b = result
	end)
	assert_equal(#held, 2)
	next_response_body = assignment_body({ version = 5, variant_key = "control" })
	fetch(client, "exp-checkout")
	held[2](nil, nil, { status = 200, response = assignment_body() })
	responder = nil
	assert_true(stale_b.ok and stale_b.assigned and stale_b.from_cache,
		"a fenced-out response reports the settled current assignment")
	assert_equal(stale_b.variant_key, "control")
	assert_equal(stale_b.error, "superseded")
	assert_equal(client:experiment_variant("exp-checkout"), "control")
end

local function test_owed_drop_retry_yields_to_fresher_sibling_write()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local first = granted_client()
	next_response_body = assignment_body()
	fetch(first, "exp-checkout")

	-- The kill lands in memory but the durable drop write fails: OWED.
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	next_response_body = not_assigned_body("kill_switch")
	fetch(first, "exp-checkout")
	assert_nil(first:experiment_variant("exp-checkout"))
	state.fail_save = nil

	-- A sibling client then persists a genuinely NEWER assignment for the
	-- same subject and experiment.
	advance_seconds(30)
	local second = assert(sdk.new(config()))
	next_response_body = assignment_body({ version = 9, variant_key = "beta" })
	fetch(second, "exp-checkout")
	local record = storage.load_experiments(second.config)
	assert_equal(record.entries["exp-checkout"].variant_key, "beta")

	-- The first client's owed drop retries — and must YIELD to the fresher
	-- entry it never resolved instead of deleting it.
	first:update(0.016)
	record = storage.load_experiments(first.config)
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"an owed drop must not delete a fresher sibling assignment")
	assert_equal(record.entries["exp-checkout"].variant_key, "beta")

	-- Settled, not looping: further ticks leave the record alone.
	first:update(0.016)
	record = storage.load_experiments(first.config)
	assert_equal(record.entries["exp-checkout"].variant_key, "beta")
	restore()
end

local function test_rearm_while_auto_exposure_owed_emits_both()
	reset()
	local client = granted_client({ buffer_size = 2 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))

	-- The assignment applies while the queue is full: the automatic
	-- exposure stays OWED.
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- The queue drains and the host explicitly re-arms BEFORE the tick
	-- sweeps the owed automatic fact: the re-arm buys an EXTRA fact — it
	-- must not consume the owed automatic slot.
	assert_true(client:flush({ include_summaries = false }))
	assert_true(client:track_exposure("exp-checkout"))
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 2,
		"the explicit re-arm AND the owed automatic exposure both emit")
	assert_true(exposures[1].event_id ~= exposures[2].event_id,
		"distinct arms derive distinct deterministic ids")

	-- And exactly those two: the automatic slot emitted once.
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 2)
end

local function test_shutdown_sweeps_owed_exposure_after_flush()
	reset()
	local client = granted_client({ buffer_size = 2 })
	-- End the session first: session_end tracks its own event, which a
	-- deliberately FULL queue would reject, failing shutdown for reasons
	-- this test is not about.
	assert_true(client:session_end("pre-shutdown"))
	assert_true(client:track("filler"))

	-- The assignment applies under a FULL queue: the exposure is owed, and
	-- no update() runs again before exit.
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- Shutdown's final flush frees the room: the owed fact must be swept
	-- and delivered with the teardown, not lost with the process.
	next_status = 202
	next_response_body = nil
	assert_true(client:shutdown())
	local published = {}
	for i = 1, #requests do
		if requests[i].url:find("/v1/events:batch", 1, true) then
			local body = json.decode(requests[i].body)
			for j = 1, #(body.events or {}) do
				if body.events[j].event_name == "experiment_exposure" then
					published[#published + 1] = body.events[j]
				end
			end
		end
	end
	assert_equal(#published, 1,
		"the owed exposure must ride a shutdown batch once the flush frees room")
	assert_equal(published[1].props.experiment_key, "exp-checkout")
	assert_equal(published[1].props.variant_key, "treatment")
end

-- ── round-6 regressions ───────────────────────────────────────────────────────

local function test_shutdown_retries_owed_durable_drop()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- The kill's durable drop fails transiently, and the game shuts down
	-- before any further update() tick runs.
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	state.fail_save = nil
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"the failed drop is still reload truth before shutdown")

	-- Shutdown retries the owed durable sync before teardown: the revoked
	-- assignment must not survive as reload truth.
	next_status = 202
	next_response_body = nil
	assert_true(client:shutdown())
	record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"shutdown must land the owed durable drop")

	next_status = 200
	local relaunch = assert(sdk.new(config()))
	assert_nil(relaunch:experiment_variant("exp-checkout"),
		"a relaunch must not revive the killed assignment")
	restore()
end

local function test_owed_clear_demoted_before_ordinary_latch()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body({ experiment_key = "exp-a" })
	fetch(client, "exp-a")
	next_response_body = assignment_body({ experiment_key = "exp-b", variant_key = "beta" })
	fetch(client, "exp-b")

	-- The real-subjects sentinel lands while the durable clear fails: the
	-- whole-record clear is OWED.
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(client, "exp-a")
	state.fail_save = nil

	-- A fresh authorized assignment lands, then an ORDINARY 401 latches
	-- BEFORE any tick could run the owed-clear retry. The stale clear must
	-- not wipe the fresh assignment: the ordinary-latch canon retains the
	-- durable record, and the clear's reach is only what it still covers.
	next_status = 200
	next_response_body = assignment_body({ experiment_key = "exp-a", variant_key = "fresh" })
	fetch(client, "exp-a")
	next_status = 401
	next_response_body = json.encode({ error = "invalid runtime token" })
	fetch(client, "exp-b")
	client:update(0.016)
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil and record.entries["exp-a"] ~= nil,
		"a stale owed clear must not wipe state written after it")
	assert_equal(record.entries["exp-a"].variant_key, "fresh")
	assert_nil(record.entries["exp-b"],
		"the sibling the sentinel still covers is dropped")
	restore()
end

local function test_clock_rollback_does_not_fence_refresh_write()
	reset()
	local restore = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- The wall clock rolls BACK before a successful refresh: the write must
	-- supersede the stored record it replaces — a fenced write would leave
	-- the OLD variant as reload truth while memory serves the new one.
	socket.now = socket.now - 100
	next_response_body = assignment_body({ version = 4, variant_key = "control" })
	fetch(client, "exp-checkout")
	assert_equal(client:experiment_variant("exp-checkout"), "control")
	local record = storage.load_experiments(client.config)
	assert_equal(record.entries["exp-checkout"].variant_key, "control",
		"a clock rollback must not fence the refresh off the disk")
	local relaunch = assert(sdk.new(config()))
	assert_equal(relaunch:experiment_variant("exp-checkout"), "control",
		"a relaunch serves the refreshed variant")
	restore()
end

local function test_stale_grammar_reject_does_not_remint()
	reset()
	local client = granted_client()
	local held = {}
	local hold_next = false
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		if hold_next then
			hold_next = false
			held[#held + 1] = callback
			return true
		end
		return false
	end
	local grammar_reject = json.encode({
		error = "experiment metadata must use synthetic local-safe identifiers only",
	})

	-- An older request is in flight when a NEWER same-key response settles.
	hold_next = true
	local stale = nil
	client:fetch_experiment_assignment("exp-checkout", function(result)
		stale = result
	end)
	assert_equal(#held, 1)
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local subject_before = query_params(last_assignment_request().url).subject_key

	-- The stale grammar reject lands late: fenced out like any other stale
	-- outcome — no subject rotation, no entry wipe, no auto retry, and the
	-- one-shot re-mint budget survives.
	local requests_before = #assignment_requests()
	held[1](nil, nil, { status = 400, response = grammar_reject })
	assert_equal(#assignment_requests(), requests_before,
		"a fenced-out grammar reject must not auto-retry")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"the settled assignment keeps serving")
	assert_true(stale.ok and stale.from_cache,
		"the stale caller receives the settled state")
	assert_equal(stale.error, "superseded")

	-- The budget was not consumed: a GENUINE grammar reject still re-mints.
	local answers = 0
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		answers = answers + 1
		if answers == 1 then
			callback(nil, nil, { status = 400, response = grammar_reject })
		else
			callback(nil, nil, { status = 200, response = assignment_body({
				experiment_key = "exp-fresh", variant_key = "beta",
			}) })
		end
		return true
	end
	local result = fetch(client, "exp-fresh")
	responder = nil
	assert_true(result.ok and result.assigned,
		"a genuine grammar reject after the stale one still heals")
	local subject_after = query_params(last_assignment_request().url).subject_key
	assert_true(subject_after ~= subject_before,
		"the genuine reject re-mints the subject (budget was not consumed)")
end

-- ── round-7 regressions ───────────────────────────────────────────────────────

local function test_owed_exposures_stay_session_scoped()
	reset()
	local restore = install_fake_sys_storage()
	local seed = granted_client()
	next_response_body = assignment_body()
	fetch(seed, "exp-checkout")
	next_status = 202
	next_response_body = nil
	assert_true(seed:shutdown())

	-- A relaunch restores the assignment, and activity REALIZES the first
	-- session (lazily) with the exposure still owed. The host then rotates
	-- the session BEFORE the tick drains it: the genuine renewal must
	-- queue the second session's exposure BEHIND the first session's owed
	-- snapshot — each session's treatment gets its own fact and id, never
	-- an overwrite.
	next_status = 200
	local client = assert(sdk.new(config()))
	assert_true(client:track("warmup"))
	assert_true(client:session_start())
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 2,
		"both sessions' treatments get their own exposure fact")
	assert_true(exposures[1].event_id ~= exposures[2].event_id,
		"each session derives its own deterministic id")

	-- And exactly those two.
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 2)
	restore()
end

local function test_ordinary_latch_preserves_owed_exposure()
	reset()
	local client = granted_client({ buffer_size = 2 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- An ORDINARY 401 latches: serving stops, but the treatment already
	-- ran — its owed fact is about the past and must survive the latch,
	-- draining once the queue has room.
	next_status = 401
	next_response_body = json.encode({ error = "invalid runtime token" })
	fetch(client, "exp-checkout")
	assert_nil(client:experiment_variant("exp-checkout"))

	next_status = 200
	next_response_body = nil
	assert_true(client:flush({ include_summaries = false }))
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1,
		"the owed exposure for a treatment that ran must survive the latch")
	assert_equal(exposures[1].props.variant_key, "treatment")
	assert_nil(client:experiment_variant("exp-checkout"),
		"serving stays latched")
end

local function test_remint_preserves_owed_exposure_of_past_treatment()
	reset()
	local client = granted_client({ buffer_size = 2 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- A grammar re-mint rotates the subject: the OLD subject's applied
	-- treatment is a past fact — its owed exposure survives the rotation
	-- (each fact carries its own server-minted fact key, never the subject
	-- id).
	local other_fact_key = "sfk1_" .. string.rep("c", 64)
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
			callback(nil, nil, { status = 200, response = assignment_body({
				experiment_key = "exp-other",
				variant_key = "beta",
				subject_fact_key = other_fact_key,
			}) })
		end
		return true
	end
	fetch(client, "exp-other")
	responder = nil

	assert_true(client:flush({ include_summaries = false }))
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 2,
		"the old subject's owed exposure AND the new subject's both emit")
	local seen = {}
	seen[exposures[1].props.assignment_key] = true
	seen[exposures[2].props.assignment_key] = true
	assert_true(seen[fixture_subject_fact_key] and seen[other_fact_key],
		"each fact carries its own server-minted fact key")
end

local function test_sentinel_discards_owed_exposures()
	reset()
	local client = granted_client({ buffer_size = 2 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- The real-subjects sentinel withdraws the assignments AND their
	-- subject-fact keys: unlike an ordinary latch, it discards owed
	-- exposure snapshots too — a withdrawn fact key must not egress after
	-- the platform flipped real subjects off.
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(client, "exp-checkout")

	next_status = 200
	next_response_body = nil
	assert_true(client:flush({ include_summaries = false }))
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 0,
		"no exposure fact may egress a sentinel-withdrawn fact key")
end

local function test_cadence_remint_retry_carries_attributes()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout", { geo = "de" })
	local params = query_params(last_assignment_request().url)
	assert_equal(params.geo, "de")
	local subject_before = params.subject_key

	-- The cadence revalidation hits the grammar sentinel: the self-heal
	-- retry must carry the SAME attribute set with the new subject — the
	-- rotation cleared the cached entry the cadence read them from, and a
	-- targeted assignment retried un-targeted would drop as
	-- targeting_unmatched.
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
	assert_equal(answers, 2, "the cadence fetch reminted and retried")
	local retry = query_params(last_assignment_request().url)
	assert_equal(retry.geo, "de",
		"the remint retry re-sends the rejected request's attributes")
	assert_true(retry.subject_key ~= subject_before, "with the new subject")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"the self-heal reinstalls the assignment")
end

local function test_stale_scope_retry_after_does_not_park_revalidation()
	reset()
	local client = granted_client()
	local held = {}
	local hold_next = false
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		if hold_next then
			hold_next = false
			held[#held + 1] = callback
			return true
		end
		return false
	end

	-- An old-subject request is in flight when a grammar reject on another
	-- experiment re-mints the subject.
	hold_next = true
	client:fetch_experiment_assignment("exp-slow", function() end)
	assert_equal(#held, 1)
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
			callback(nil, nil, { status = 200, response = assignment_body({
				experiment_key = "exp-b",
			}) })
		end
		return true
	end
	local result = fetch(client, "exp-b")
	responder = nil
	assert_true(result.ok and result.assigned)

	-- The OLD subject's 429 lands late with a huge Retry-After: install
	-- discards it on the scope check, and the PACING must be discarded
	-- with it — not park the new subject's revalidation and kill checks.
	held[1](nil, nil, {
		status = 429,
		response = "",
		headers = { ["retry-after"] = "3600" },
	})
	local before = #assignment_requests()
	advance_seconds(400)
	client:update(0.016)
	assert_true(#assignment_requests() > before,
		"a stale-scope Retry-After must not park the current subject's revalidation")
end

-- ── round-8 regressions ───────────────────────────────────────────────────────

local function test_restored_exposure_migrates_to_first_session()
	reset()
	local restore = install_fake_sys_storage()
	local seed = granted_client()
	next_response_body = assignment_body()
	fetch(seed, "exp-checkout")
	next_status = 202
	next_response_body = nil
	assert_true(seed:shutdown())

	-- The common init-then-start-session launch flow: the restored
	-- assignment's owed exposure is armed under the PRE-session
	-- constructor marker, and the host explicitly starts the FIRST session
	-- before any update(). No session existed for the restoration to have
	-- run in — the owed snapshot must MIGRATE to the first real session,
	-- never duplicate into two facts.
	next_status = 200
	local client = assert(sdk.new(config()))
	assert_true(client:session_start())
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1,
		"the restored application emits exactly ONE fact into the first session")
	assert_equal(exposures[1].session_id, client.session_id,
		"attributed to the just-started session")

	-- And stays once-only.
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 1)
	restore()
end

local function test_permanent_400_drops_cached_assignment()
	reset()
	local restore = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout", { geo = "de" })
	assert_equal(client:experiment_variant("exp-checkout"), "treatment")

	-- The cadence revalidation answers a NON-grammar 400: permanent for
	-- this input set. The cached assignment fails closed — a durable drop
	-- — instead of serving stale forever while the cadence re-sends the
	-- same rejected input.
	next_status = 400
	next_response_body = json.encode({ error = "unsupported attribute value" })
	advance_seconds(400)
	client:update(0.016)
	assert_nil(client:experiment_variant("exp-checkout"),
		"a permanent 400 stops serving the cached assignment")
	local record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"the drop is durable")

	-- The cadence stops re-asking for the dropped experiment.
	local before = #assignment_requests()
	next_status = 200
	next_response_body = nil
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), before)
	restore()
end

local function test_shutdown_captures_deferred_session_end_when_flush_cannot_send()
	reset()
	local restore, stores = install_fake_sys_storage()
	-- Mode B ingest (token provider) alongside the Mode A control plane:
	-- the provider cannot supply a token, so the shutdown flush fails
	-- BEFORE moving anything out of the queue.
	local client = granted_client({
		buffer_size = 2,
		token_provider = function(callback)
			callback(nil, nil, "token_unavailable")
		end,
	})
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- The queue is FULL and undeliverable; the spool durably captures it.
	-- Shutdown must evict the captured remnant so the deferred session end
	-- and the owed exposure can still enqueue — and be spooled in turn —
	-- instead of silently finalizing with the session active and neither
	-- fact captured anywhere.
	next_response_body = nil
	assert_true(client:shutdown(),
		"a durably captured queue must not block teardown")
	assert_equal(client.session_active, false,
		"the deferred session end completed")
	local names = {}
	local function collect(value)
		if type(value) ~= "table" then
			return
		end
		if type(value.event_name) == "string" then
			names[value.event_name] = true
		end
		for _, child in pairs(value) do
			collect(child)
		end
	end
	for _, record in pairs(stores) do
		collect(record)
	end
	assert_true(names["session_end"],
		"the deferred session end is durably captured in the spool")
	assert_true(names["experiment_exposure"],
		"the owed exposure is durably captured in the spool")
	restore()
end

local function test_shutdown_completes_with_active_session_and_full_queue()
	reset()
	local client = granted_client({ buffer_size = 2 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- Active session + FULL queue — the exact scenario that owes an
	-- exposure. session_end()'s queue_full must not short-circuit the
	-- shutdown housekeeping: the flush frees the room, the session end
	-- retries, the owed exposure sweeps, and teardown completes.
	next_status = 202
	next_response_body = nil
	assert_true(client:shutdown(),
		"a full queue with an active session must not fail shutdown")
	local names = {}
	for i = 1, #requests do
		if requests[i].url:find("/v1/events:batch", 1, true) then
			local body = json.decode(requests[i].body)
			for j = 1, #(body.events or {}) do
				names[body.events[j].event_name] = true
			end
		end
	end
	assert_true(names["experiment_exposure"],
		"the owed exposure rides a shutdown batch")
	assert_true(names["session_end"],
		"the deferred session end rides a shutdown batch")
end

-- ── round-9 regressions (post-merge audit absorption) ─────────────────────────

local function test_stale_auth_refusal_does_not_latch()
	reset()
	local client = granted_client()
	local held = {}
	local hold_next = false
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		if hold_next then
			hold_next = false
			held[#held + 1] = callback
			return true
		end
		return false
	end

	-- An older request is in flight when a NEWER same-key success settles.
	hold_next = true
	local stale = nil
	client:fetch_experiment_assignment("exp-checkout", function(result)
		stale = result
	end)
	assert_equal(#held, 1)
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	responder = nil

	-- The DELAYED STALE 401 lands: the per-key fence discards it BEFORE the
	-- latch branch — a fence-losing refusal must not halt the lane. (A
	-- fence-WINNING refusal still latches: pinned by
	-- test_unauthorized_fails_closed_and_halts_revalidation.)
	held[1](nil, nil, {
		status = 401,
		response = json.encode({ error = "invalid runtime token" }),
	})
	assert_true(stale.ok and stale.from_cache,
		"the stale caller receives the settled state")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"a fence-losing 401 must not stop serving")

	-- And the revalidation cadence still runs.
	local before = #assignment_requests()
	next_response_body = assignment_body()
	advance_seconds(400)
	client:update(0.016)
	assert_true(#assignment_requests() > before,
		"a fence-losing 401 must not halt the revalidation cadence")
end

local function test_credential_swap_scopes_the_cache()
	reset()
	local restore = install_fake_sys_storage()
	local first = granted_client()
	next_response_body = assignment_body()
	fetch(first, "exp-checkout")
	assert_equal(first:experiment_variant("exp-checkout"), "treatment")

	-- The scope carries a credential FINGERPRINT — never the raw key.
	local record = storage.load_experiments(first.config)
	assert_nil(record.scope:find("sp_ingest_publishable_key", 1, true),
		"the raw key must never appear in the scope")
	assert_match(record.scope, "%x%x%x%x%x%x%x%x$")

	-- An IN-PLACE key swap (same workspace/app/environment) is another
	-- tenant's plane: the previous tenant's cached assignment and its
	-- subject-fact key must be a safe scope-miss, never served.
	local swapped = assert(sdk.new(config({ api_key = "sp_ingest_publishable_key_b" })))
	assert_nil(swapped:experiment_variant("exp-checkout"),
		"a swapped credential must not serve the previous tenant's cache")

	-- The ORIGINAL credential still restores its own record.
	local back = assert(sdk.new(config()))
	assert_equal(back:experiment_variant("exp-checkout"), "treatment")
	restore()
end

local function test_mismatched_experiment_key_is_malformed()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- A 200 whose body names ANOTHER experiment (routing/proxy confusion)
	-- is malformed — serve-stale transient — never installed under the
	-- requested key.
	next_response_body = assignment_body({
		experiment_key = "exp-other",
		variant_key = "beta",
		version = 9,
	})
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok and result.from_cache,
		"a mismatched body serves the cached entry as a transient")
	assert_equal(result.error, "malformed_response")
	assert_equal(result.variant_key, "treatment")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"nothing installs from another experiment's payload")
	assert_nil(client:experiment_variant("exp-other"))
end

local function test_unknown_not_assigned_reason_is_malformed()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- The not-assigned reason vocabulary is CLOSED. An unknown reason is
	-- semantics this client cannot honor: malformed serve-stale — never a
	-- drop directive executed blind.
	next_response_body = not_assigned_body("mystery_gate")
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok and result.from_cache)
	assert_equal(result.error, "malformed_response")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"an unknown reason must not drop the cached assignment")

	-- The known vocabulary still drops.
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	assert_nil(client:experiment_variant("exp-checkout"))
end

local function test_failed_sentinel_clear_never_resurrects_serving()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- The sentinel lands while the durable clear keeps failing: the
	-- withdrawn assignment stays on DISK for the moment, but serving must
	-- never resurrect from the stale disk record while the clear is owed.
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(client, "exp-checkout")
	assert_nil(client:experiment_variant("exp-checkout"))
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"the withdrawn record is still on disk while the clear is owed")

	-- Owed-clear retry ticks READ the disk: no resurrection.
	client:update(0.016)
	client:update(0.016)
	assert_nil(client:experiment_variant("exp-checkout"),
		"owed-clear retries must never resurrect serving from the stale record")

	-- Storage recovers: the clear lands and a relaunch serves nothing.
	state.fail_save = nil
	client:update(0.016)
	next_status = 200
	next_response_body = nil
	local relaunch = assert(sdk.new(config()))
	assert_nil(relaunch:experiment_variant("exp-checkout"),
		"the landed clear leaves nothing to restore")
	restore()
end

-- ── round-10 regressions ──────────────────────────────────────────────────────

local function test_non_string_reason_is_malformed()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- A PRESENT but non-string reason must not coerce into the "absent"
	-- vocabulary entry and execute a drop: malformed serve-stale.
	next_response_body = json.encode({
		version = 3,
		assigned = false,
		reason = 123,
		boundary = { assignment_unit = "client_id" },
	})
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok and result.from_cache)
	assert_equal(result.error, "malformed_response")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"a non-string reason must not drop the cached assignment")

	-- A genuinely ABSENT reason (the traffic-gate miss) still drops.
	next_response_body = not_assigned_body(nil)
	fetch(client, "exp-checkout")
	assert_nil(client:experiment_variant("exp-checkout"))
end

local function test_sibling_write_lands_owed_drops()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body({ experiment_key = "exp-a" })
	fetch(client, "exp-a")
	next_response_body = assignment_body({ experiment_key = "exp-b", variant_key = "beta" })
	fetch(client, "exp-b")

	-- exp-a's kill fails to persist: the drop is OWED and the disk record
	-- still carries the killed assignment.
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-a")
	state.fail_save = nil
	local record = storage.load_experiments(client.config)
	assert_true(record.entries["exp-a"] ~= nil,
		"the failed drop leaves the entry on disk for the moment")

	-- A later SUCCESSFUL write for the sibling carries the owed drop with
	-- it: the record is ONE file, and an exit before the next tick must
	-- not leave the killed sibling as reload truth.
	next_response_body = assignment_body({
		experiment_key = "exp-b",
		variant_key = "beta",
		version = 4,
	})
	fetch(client, "exp-b")
	record = storage.load_experiments(client.config)
	assert_nil(record.entries["exp-a"],
		"a successful sibling write must land the owed drop")
	assert_equal(record.entries["exp-b"].variant_key, "beta")

	-- The swept drop SETTLED: a relaunch serves only the sibling.
	local relaunch = assert(sdk.new(config()))
	assert_nil(relaunch:experiment_variant("exp-a"))
	assert_equal(relaunch:experiment_variant("exp-b"), "beta")
	restore()
end

local function test_grammar_400_after_spent_budget_drops_entry()
	reset()
	local restore = install_fake_sys_storage()
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
	-- The first grammar reject spends the one-shot budget; its retry
	-- installs the assignment for the fresh subject.
	local result = fetch(client, "exp-checkout")
	responder = nil
	assert_true(result.ok and result.assigned)
	assert_equal(client:experiment_variant("exp-checkout"), "treatment")

	-- A LATER grammar reject with the budget spent is a permanent 400 for
	-- this subject: the cached assignment fails closed — a durable drop —
	-- instead of serving indefinitely against it.
	next_status = 400
	next_response_body = grammar_reject
	local rejected = fetch(client, "exp-checkout")
	assert_equal(rejected.ok, false)
	assert_equal(rejected.error, "bad_request")
	assert_nil(client:experiment_variant("exp-checkout"),
		"a budget-exhausted grammar 400 must stop serving")
	local record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"the drop is durable")
	restore()
end

local function test_mismatched_app_or_environment_is_malformed()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- A 200 echoing ANOTHER app is another scope's payload: malformed
	-- serve-stale, never an install (or drop) under this cache scope.
	next_response_body = assignment_body({
		app_key = "app-other",
		variant_key = "beta",
		version = 9,
	})
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok and result.from_cache)
	assert_equal(result.error, "malformed_response")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment")

	-- Same for a mismatched environment.
	next_response_body = assignment_body({
		environment_key = "prod-other",
		variant_key = "beta",
		version = 9,
	})
	result = fetch(client, "exp-checkout")
	assert_true(result.ok and result.from_cache)
	assert_equal(result.error, "malformed_response")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"another environment's payload must never install")
end

-- ── round-11 regressions ──────────────────────────────────────────────────────

local function test_non_string_scope_echo_is_malformed()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- A PRESENT but non-string scope echo must never "agree with the
	-- request" by type accident: malformed serve-stale.
	next_response_body = json.encode({
		experiment_key = 123,
		version = 9,
		assigned = true,
		assignment_key = "asgn_" .. string.rep("d", 32),
		variant_key = "beta",
		boundary = { assignment_unit = "client_id" },
	})
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok and result.from_cache)
	assert_equal(result.error, "malformed_response")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"a wrong-typed echo must not install")
end

local function test_owed_drop_lands_against_retired_scope()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- The kill's durable drop fails: OWED, decided under the CURRENT scope.
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	state.fail_save = nil

	-- A grammar reject on ANOTHER experiment re-mints the subject (its
	-- retry answers 404 — nothing installs, no new-scope write happens).
	-- The owed drop's scope is now RETIRED, but the kill must still land
	-- against the retired record: a failed subject persist could put the
	-- old subject back at the next launch and resurrect it.
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
			callback(nil, nil, { status = 404, response = "" })
		end
		return true
	end
	fetch(client, "exp-other")
	responder = nil

	client:update(0.016)
	local record = storage.load_experiments(client.config)
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"the owed kill must land against the retired scope's record")
	restore()
end

local function test_rotation_cancels_owed_writes()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- A refresh write fails (owed), then the subject re-mints: the write's
	-- source data dies with the rotation — the retired record must keep
	-- its LAST durable state, never be reshaped from another subject's
	-- memory or deleted by a decayed intent.
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	advance_seconds(2)
	next_response_body = assignment_body({ version = 4, variant_key = "control" })
	fetch(client, "exp-checkout")
	state.fail_save = nil

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
			callback(nil, nil, { status = 404, response = "" })
		end
		return true
	end
	fetch(client, "exp-other")
	responder = nil

	client:update(0.016)
	client:update(0.016)
	local record = storage.load_experiments(client.config)
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"the retired record keeps its last durable state")
	assert_equal(record.entries["exp-checkout"].variant_key, "treatment")
	restore()
end

local function test_sibling_save_folds_owed_writes()
	reset()
	local restore, _, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body({ experiment_key = "exp-a" })
	fetch(client, "exp-a")
	next_response_body = assignment_body({ experiment_key = "exp-b", variant_key = "beta" })
	fetch(client, "exp-b")

	-- exp-a's refresh write fails (owed; the tombstone save fails too, so
	-- the SUPERSEDED variant stays reload truth for the moment).
	state.fail_save = function(path)
		return fail_experiment_saves(path)
	end
	advance_seconds(2)
	next_response_body = assignment_body({
		experiment_key = "exp-a",
		version = 4,
		variant_key = "fresh",
	})
	fetch(client, "exp-a")
	state.fail_save = nil
	local record = storage.load_experiments(client.config)
	assert_equal(record.entries["exp-a"].variant_key, "treatment",
		"the superseded variant is reload truth until something saves")

	-- A successful save for the SIBLING (exp-b's kill) folds exp-a's owed
	-- refreshed write with it: an exit before the retry tick must not
	-- reload the superseded variant.
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-b")
	record = storage.load_experiments(client.config)
	assert_equal(record.entries["exp-a"].variant_key, "fresh",
		"a successful sibling save must fold the owed refreshed write")
	assert_nil(record.entries["exp-b"])
	local relaunch = assert(sdk.new(config()))
	assert_equal(relaunch:experiment_variant("exp-a"), "fresh")
	restore()
end

local function test_shutdown_fails_when_housekeeping_events_cannot_persist()
	reset()
	local client = granted_client({ buffer_size = 2, spool_enabled = false })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- The FIRST shutdown flush drains fine; the HOUSEKEEPING flush (the
	-- deferred session end + owed exposure) hits a transient 500, and with
	-- the spool disabled nothing captures it durably: shutdown must stay
	-- retryable — never silently finalize over the just-queued facts.
	local fail_housekeeping = true
	responder = function(url, _, callback)
		if not url:find("/v1/events:batch", 1, true) then
			return false
		end
		local body = requests[#requests].body or ""
		if fail_housekeeping
			and (body:find("experiment_exposure", 1, true)
				or body:find('"event_name":"session_end"', 1, true)) then
			callback(nil, nil, { status = 500, response = "" })
			return true
		end
		return false
	end
	local ok = client:shutdown()
	assert_equal(ok, false,
		"neither sent nor spooled: shutdown must stay retryable")
	assert_equal(client.initialized, true,
		"the client stays alive for a host retry")

	-- The transient clears: the retried shutdown delivers and finalizes.
	fail_housekeeping = false
	assert_true(client:shutdown())
	responder = nil
	assert_equal(client.initialized, false)
end

local function test_restored_attributes_renormalize_before_revalidation()
	reset()
	local restore = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout", { geo = "de" })
	next_status = 202
	next_response_body = nil
	assert_true(client:shutdown())

	-- Poison the stored attributes the way a corrupt or older-build record
	-- could: a reserved name, an out-of-vocabulary name, and an overlong
	-- value. Only the vocabulary-valid pair may ride the revalidation.
	local record = storage.load_experiments(config())
	record.entries["exp-checkout"].attributes = {
		{ name = "experiment_key", value = "evil-key" },
		{ name = "not_in_vocabulary", value = "x" },
		{ name = "geo", value = "de" },
		{ name = "user_segment", value = string.rep("v", 600) },
	}
	assert_true(storage.save_experiments(config(), record))

	next_status = 200
	local relaunch = assert(sdk.new(config()))
	assert_equal(relaunch:experiment_variant("exp-checkout"), "treatment")
	next_response_body = assignment_body()
	relaunch:update(0.016)
	local before = #assignment_requests()
	advance_seconds(400)
	relaunch:update(0.016)
	assert_true(#assignment_requests() > before,
		"the revalidation must actually fire")
	local params, order = query_params(last_assignment_request().url)
	assert_equal(params.experiment_key, "exp-checkout",
		"a poisoned reserved name must not reshape the request")
	assert_equal(params.geo, "de", "the vocabulary-valid pair survives")
	assert_nil(params.not_in_vocabulary)
	assert_nil(params.user_segment, "overlong values degrade to absence")
	local occurrences = 0
	for i = 1, #order do
		if order[i] == "experiment_key" then
			occurrences = occurrences + 1
		end
	end
	assert_equal(occurrences, 1, "exactly one experiment_key parameter")
	restore()
end

local function test_consent_purge_discards_dead_owed_exposures()
	reset()
	local client = granted_client({ buffer_size = 2 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- The assignment is KILLED (its owed snapshot survives the drop — the
	-- facts-about-the-past retention), then consent is REVOKED: the purge
	-- discards the unpublished fact. A re-grant must never publish a
	-- treatment the server already killed.
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	assert_true(client:set_consent(false))
	assert_true(client:set_consent(true))
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 0,
		"a purged owed exposure for a dead assignment must never publish")
end

local function test_owed_exposure_keeps_original_session_identity()
	reset()
	local client = granted_client({ buffer_size = 4 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	assert_true(client:track("filler-c"))
	assert_true(client:track("filler-d"))
	local first_session = client.session_id
	assert_true(first_session ~= nil)
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- The queue drains and the host RENEWS the session before the owed
	-- fact does: the late drain rides the session the treatment APPLIED
	-- in; the renewal's own exposure rides the new session.
	assert_true(client:flush({ include_summaries = false }))
	assert_true(client:session_start())
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 2)
	assert_equal(exposures[1].session_id, first_session,
		"the owed exposure keeps the session it applied in")
	assert_equal(exposures[2].session_id, client.session_id,
		"the renewal's exposure rides the new session")
	assert_true(exposures[1].event_id ~= exposures[2].event_id)
end

local function test_shutdown_buffer_one_drains_owed_exposure_after_session_end()
	reset()
	-- buffer_size = 1 (a valid config): after the first flush, EVERY freed
	-- slot fits exactly one owed item — the deferred session end must not
	-- consume the only slot and cost the owed exposure its fact.
	local client = granted_client({ buffer_size = 1 })
	assert_true(client:session_start())
	assert_equal(#client.queue.items, 1, "session_started fills the whole queue")
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0,
		"the full queue leaves the exposure owed")
	-- The assignment is then DROPPED (404): the owed fact survives, but a
	-- relaunch would NOT re-arm it from the durable cache — shutdown is its
	-- only exit. Exactly the fatal flavor of the loop-less housekeeping.
	next_status = 404
	next_response_body = nil
	fetch(client, "exp-checkout")
	next_status = 200

	assert_true(client:shutdown(), "shutdown completes by looping the housekeeping")
	local exposure_sent = false
	for i = 1, #requests do
		if requests[i].url:find("/v1/events:batch", 1, true)
			and type(requests[i].body) == "string"
			and requests[i].body:find("experiment_exposure", 1, true) then
			exposure_sent = true
		end
	end
	assert_true(exposure_sent,
		"the owed exposure must be delivered before teardown, not dropped")
end

local function test_sibling_client_adopts_persisted_subject()
	reset()
	-- Two clients constructed BEFORE the first fetch both capture a nil
	-- subject id: after the first client mints and persists, the second
	-- must adopt the persisted subject instead of re-minting over it.
	seed_granted_consent()
	local a = assert(sdk.new(config()))
	local b = assert(sdk.new(config()))
	next_response_body = assignment_body()
	fetch(a, "exp-checkout")
	local minted = query_params(last_assignment_request().url).subject_key
	assert_match(minted, subject_grammar)
	next_response_body = assignment_body()
	fetch(b, "exp-checkout")
	local adopted = query_params(last_assignment_request().url).subject_key
	assert_equal(adopted, minted,
		"the sibling client must fetch under the already-persisted subject")
	assert_equal(storage.load(storage_scope).experiments_client_id, minted,
		"one install converges on one persisted subject id")
end

local function test_owed_exposure_keeps_original_anonymous_id_and_timestamp()
	reset()
	local clock_mod = require "shardpilot.clock"
	local client = granted_client({ buffer_size = 4 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	assert_true(client:track("filler-c"))
	assert_true(client:track("filler-d"))
	local ts_before_arm = clock_mod.iso_utc()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local ts_after_arm = clock_mod.iso_utc()
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- The queue drains, TIME PASSES, and the anonymous id ROTATES before
	-- the owed fact does: the late drain rides the identity of the moment
	-- the treatment applied — its own anonymous id and timestamp — while
	-- fresh events ride the rotated identity.
	assert_true(client:flush({ include_summaries = false }))
	advance_seconds(120)
	assert_true(client:set_anonymous_id("anon-rotated"))
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1)
	assert_equal(exposures[1].anonymous_id, "anon-client",
		"the owed exposure keeps the anonymous id it applied under")
	assert_true(ts_before_arm <= exposures[1].event_ts
		and exposures[1].event_ts <= ts_after_arm,
		"the owed exposure keeps the timestamp of the apply moment")
	assert_true(client:track("post-rotation"))
	assert_equal(queued_events(client, "post-rotation")[1].anonymous_id,
		"anon-rotated", "fresh events ride the rotated identity")
end

local function test_persist_spools_owed_exposure_fact()
	reset()
	local restore, stores = install_fake_sys_storage()
	local client = granted_client({ buffer_size = 4 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	assert_true(client:track("filler-c"))
	assert_true(client:track("filler-d"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	-- The queue drains; the host's focus-loss listener fires persist()
	-- BEFORE any tick sweeps the owed fact. The app-may-die snapshot must
	-- capture it: the sweep enqueues the fact and the spool write below
	-- carries it — an OS kill right after persist() loses nothing.
	assert_true(client:flush({ include_summaries = false }))
	assert_true(client:persist())
	assert_equal(#queued_events(client, "experiment_exposure"), 1,
		"persist sweeps the owed fact into the queue (its normal emission)")
	local spooled = false
	for path, record in pairs(stores) do
		if path:sub(-#"/spool") == "/spool"
			and json.encode(record):find("experiment_exposure", 1, true) then
			spooled = true
		end
	end
	assert_true(spooled, "the spool snapshot must capture the owed exposure")
	restore()
	storage.reset()
end

local function test_persist_reports_uncaptured_experiment_state()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	local client = granted_client({ buffer_size = 4 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	assert_true(client:track("filler-c"))
	assert_true(client:track("filler-d"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- The queue is STILL full: the sweep cannot capture the owed fact, so
	-- persist must not claim the app-may-die snapshot is safe.
	local ok, err = client:persist()
	assert_equal(ok, false)
	assert_equal(err, "experiments_pending")

	-- Drain and let the fact through; then an owed DURABLE sync (a kill
	-- drop whose cache write keeps failing) must equally fail the claim —
	-- an OS kill would leave the revoked assignment as reload truth.
	assert_true(client:flush({ include_summaries = false }))
	client:update(0.016)
	assert_true(client:persist(), "a captured snapshot reports success")
	state.fail_save = fail_experiment_saves
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	local drop_ok, drop_err = client:persist()
	assert_equal(drop_ok, false)
	assert_equal(drop_err, "experiments_pending")
	state.fail_save = nil
	assert_true(client:persist(),
		"the recovered store lands the drop and the snapshot is safe")
	local record = storage.load_experiments(config())
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"the kill drop reached the disk")
	restore()
	storage.reset()
end

local function test_owed_clear_retry_preserves_sibling_fresh_write()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	seed_granted_consent()
	local a = assert(sdk.new(config()))
	next_response_body = assignment_body()
	fetch(a, "exp-checkout")

	-- The real-subjects sentinel lands while the experiments store cannot
	-- write: the whole-record clear is OWED. A same-app sibling then
	-- persists FRESH authorized state. The retry must remove only what the
	-- sentinel covered — never the sibling's newer record.
	state.fail_save = fail_experiment_saves
	next_status = 403
	next_response_body = json.encode({
		error = "experiment real-subject assignment is disabled",
	})
	fetch(a, "exp-checkout")
	state.fail_save = nil
	next_status = 200
	advance_seconds(5)
	local b = assert(sdk.new(config()))
	next_response_body = assignment_body({ experiment_key = "exp-onboarding" })
	fetch(b, "exp-onboarding")

	a:update(0.016)
	local record = storage.load_experiments(config())
	assert_true(record ~= nil, "the sibling's record must survive the retry")
	assert_true(record.entries["exp-onboarding"] ~= nil,
		"the sibling's post-sentinel assignment survives the owed clear")
	assert_nil(record.entries["exp-checkout"],
		"the state the sentinel withdrew is gone")
	a:update(0.016)
	record = storage.load_experiments(config())
	assert_true(record ~= nil and record.entries["exp-onboarding"] ~= nil,
		"the settled clear must not re-run against the sibling's record")
	restore()
	storage.reset()
end

local function test_owed_clear_demotion_preserves_fresh_disk_entry()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	seed_granted_consent()
	local a = assert(sdk.new(config()))
	next_response_body = assignment_body()
	fetch(a, "exp-checkout")

	-- Owed sentinel clear (as above), then a sibling persists a fresh
	-- OTHER experiment, then THIS instance reinstalls its own key: the
	-- install-time demotion walks the disk record and must leave the
	-- sibling's post-sentinel entry alone — only covered state drops.
	state.fail_save = fail_experiment_saves
	next_status = 403
	next_response_body = json.encode({
		error = "experiment real-subject assignment is disabled",
	})
	fetch(a, "exp-checkout")
	state.fail_save = nil
	next_status = 200
	advance_seconds(5)
	local b = assert(sdk.new(config()))
	next_response_body = assignment_body({ experiment_key = "exp-onboarding" })
	fetch(b, "exp-onboarding")

	next_response_body = assignment_body()
	fetch(a, "exp-checkout")
	local record = storage.load_experiments(config())
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"the reinstalled assignment is on disk")
	assert_true(record.entries["exp-onboarding"] ~= nil,
		"the demotion must not drop the sibling's fresher entry")
	a:update(0.016)
	record = storage.load_experiments(config())
	assert_true(record.entries["exp-onboarding"] ~= nil,
		"no owed drop may linger against the sibling's fresher entry")
	restore()
	storage.reset()
end

local function test_transient_serve_requires_matching_attributes()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	local first = fetch(client, "exp-checkout", { geo = "US" })
	assert_true(first.ok and first.assigned)

	-- Targeting is server-evaluated and the cache stores the attribute set
	-- it was evaluated under: during an outage, a request carrying a
	-- DIFFERENT set gets the closed transient failure — never a variant
	-- whose targeting condition the new context may not match.
	next_status = 503
	next_response_body = nil
	local mismatched = fetch(client, "exp-checkout", { geo = "CA" })
	assert_equal(mismatched.ok, false,
		"a geo=CA request must not serve the geo=US-evaluated cache")
	assert_true(not mismatched.from_cache)
	assert_equal(mismatched.error, "transient_503")
	local empty = fetch(client, "exp-checkout")
	assert_equal(empty.ok, false,
		"an attribute-less request is a different targeting context")
	local matched = fetch(client, "exp-checkout", { geo = "US" })
	assert_equal(matched.ok, true, "the SAME context still serves stale")
	assert_equal(matched.from_cache, true)
	assert_equal(matched.variant_key, "treatment")
	next_status = 200
end

local function test_stale_inflight_sentinel_preserves_sibling_write()
	reset()
	seed_granted_consent()
	local a = assert(sdk.new(config()))
	next_response_body = assignment_body()
	fetch(a, "exp-checkout")

	-- The sentinel answer is held IN FLIGHT while a sibling client lands a
	-- fresh authorized assignment: the flag flipped back on after the
	-- sentinel was served, so the sibling's write is the newer server
	-- truth. The clear's SUCCESS path must partition by its dispatch-bound
	-- stamp — withdrawing only what predates the request — not wipe the
	-- whole record.
	local held = nil
	responder = function(url, method, callback)
		if held == nil
			and url:find("/experiments/assignment", 1, true)
			and url:find("experiment_key=exp-checkout", 1, true) then
			held = callback
			return true
		end
	end
	a:fetch_experiment_assignment("exp-checkout", nil, function() end)
	assert_true(held ~= nil, "the sentinel response must be held in flight")
	responder = nil
	advance_seconds(5)
	local b = assert(sdk.new(config()))
	next_response_body = assignment_body({ experiment_key = "exp-onboarding" })
	fetch(b, "exp-onboarding")

	held(nil, nil, { status = 403, response = json.encode({
		error = "experiment real-subject assignment is disabled",
	}) })
	local record = storage.load_experiments(config())
	assert_true(record ~= nil,
		"the successful clear must not wipe the whole shared record")
	assert_true(record.entries["exp-onboarding"] ~= nil,
		"the sibling's post-sentinel write survives the clear")
	assert_nil(record.entries["exp-checkout"],
		"the state the sentinel covered is withdrawn")
end

local function test_condemned_record_refused_after_restart()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	seed_granted_consent()
	local a = assert(sdk.new(config()))
	next_response_body = assignment_body()
	fetch(a, "exp-checkout")

	-- The sentinel clear cannot land (the record file's writes fail); the
	-- condemnation is persisted in the sidecar marker. A RESTART must
	-- refuse the withdrawn record — no serving, not even stale — instead
	-- of serving it until the first probe; the first tick after storage
	-- recovers lands the clear and retires the marker.
	state.fail_save = fail_experiment_saves
	next_status = 403
	next_response_body = json.encode({
		error = "experiment real-subject assignment is disabled",
	})
	fetch(a, "exp-checkout")
	next_status = 200
	local b = assert(sdk.new(config()))
	next_status = 503
	next_response_body = nil
	local stale = fetch(b, "exp-checkout")
	assert_equal(stale.ok, false,
		"a condemned record must not serve after a restart, even stale")
	assert_true(not stale.from_cache)
	next_status = 200
	state.fail_save = nil
	b:update(0.016)
	local record = storage.load_experiments(config())
	assert_true(record == nil or record.entries["exp-checkout"] == nil,
		"the recovered store lands the owed clear")
	assert_nil(storage.load_experiments_clear(config()),
		"the landed clear retires its condemnation marker")
	restore()
	storage.reset()
end

local function test_condemned_survivor_restores_and_converges()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	seed_granted_consent()
	local a = assert(sdk.new(config()))
	next_response_body = assignment_body()
	fetch(a, "exp-checkout")
	state.fail_save = fail_experiment_saves
	next_status = 403
	next_response_body = json.encode({
		error = "experiment real-subject assignment is disabled",
	})
	fetch(a, "exp-checkout")
	next_status = 200
	state.fail_save = nil
	advance_seconds(5)

	-- Restart under the condemnation: the covered entry must not restore,
	-- and a fresh authorized install then supersedes the whole-record form
	-- — the demotion retires the marker and the combined save converges
	-- the covered key out while the fresh entry stays.
	local b = assert(sdk.new(config()))
	next_status = 503
	next_response_body = nil
	local stale = fetch(b, "exp-checkout")
	assert_equal(stale.ok, false, "condemned entries must not restore")
	next_status = 200
	next_response_body = assignment_body({ experiment_key = "exp-onboarding" })
	fetch(b, "exp-onboarding")
	local record = storage.load_experiments(config())
	assert_true(record ~= nil and record.entries["exp-onboarding"] ~= nil,
		"the fresh authorized install persists")
	assert_nil(record.entries["exp-checkout"],
		"the covered key converges out with the demoted clear")
	assert_nil(storage.load_experiments_clear(config()),
		"the authorized install disproves the sentinel state and retires the marker")
	local c = assert(sdk.new(config()))
	next_status = 503
	next_response_body = nil
	local kept = fetch(c, "exp-onboarding")
	assert_equal(kept.ok, true, "the survivor serves normally after the next restart")
	assert_equal(kept.from_cache, true)
	next_status = 200
	restore()
	storage.reset()
end

local function test_sibling_adopts_after_corrupt_subject_heals()
	reset()
	-- BOTH clients are constructed from an identity record whose stored
	-- subject id fails the wire grammar. The first fetch heals it (re-mint
	-- + persist); the second client's captured value is non-nil but
	-- INVALID — the reload gate must fire on validity, not nilness, so it
	-- adopts the healed subject instead of minting again over it.
	storage.save(storage_scope, {
		consent_analytics = "granted",
		experiments_client_id = "not-wire-valid",
	})
	local a = assert(sdk.new(config()))
	local b = assert(sdk.new(config()))
	next_response_body = assignment_body()
	fetch(a, "exp-checkout")
	local healed = query_params(last_assignment_request().url).subject_key
	assert_match(healed, subject_grammar)
	next_response_body = assignment_body()
	fetch(b, "exp-checkout")
	local adopted = query_params(last_assignment_request().url).subject_key
	assert_equal(adopted, healed,
		"the sibling must adopt the healed subject, not re-mint over it")
	assert_equal(storage.load(storage_scope).experiments_client_id, healed)
end

local function test_migrated_snapshot_keeps_apply_identity_through_session_start()
	reset()
	local restore, stores = install_fake_sys_storage()
	local seed_client = granted_client()
	next_response_body = assignment_body()
	fetch(seed_client, "exp-checkout")

	-- Restart: the restored assignment arms its pre-session snapshot at
	-- construction. Time passes and the anonymous id rotates BEFORE the
	-- first session starts: the migration must carry the snapshot into
	-- the first real session with its RESTORE-moment identity — the
	-- unconditional re-arm must not replace it with a session-start-
	-- stamped one.
	local clock_mod = require "shardpilot.clock"
	local ts_low = clock_mod.iso_utc()
	local client = assert(sdk.new(config()))
	local ts_high = clock_mod.iso_utc()
	advance_seconds(120)
	assert_true(client:set_anonymous_id("anon-rotated"))
	assert_true(client:session_start())
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1)
	assert_equal(exposures[1].anonymous_id, "anon-client",
		"the migrated snapshot keeps the restore-moment anonymous id")
	assert_true(ts_low <= exposures[1].event_ts
		and exposures[1].event_ts <= ts_high,
		"the migrated snapshot keeps the restore-moment timestamp")
	assert_equal(exposures[1].session_id, client.session_id,
		"and belongs to the first real session")
	restore()
	storage.reset()
end

local function test_mode_b_rotation_blocked_while_exposure_owed()
	reset()
	seed_granted_consent()
	-- Mode B analytics (token_provider) + the publishable api_key for the
	-- control plane: a valid dual-credential configuration. Owed exposure
	-- snapshots hold the OLD anon identity outside the queue, so a flushed
	-- queue must not admit rotation while one is owed — the later sweep
	-- would send an old-anon fact under a token minted for the new anon.
	local client = assert(sdk.new(config({
		buffer_size = 4,
		token_provider = function(callback)
			callback("client-token-placeholder", nil, nil)
		end,
	})))
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	assert_true(client:track("filler-c"))
	assert_true(client:track("filler-d"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_true(client:flush({ include_summaries = false }))
	assert_equal(#client.queue.items, 0, "the queue itself is drained")
	local ok, err = client:set_anonymous_id("anon-rotated")
	assert_equal(ok, false,
		"owed old-anon exposures must block Mode B rotation like queued work")
	assert_equal(err, "events_pending")
	client:update(0.016)
	assert_true(client:flush({ include_summaries = false }))
	assert_true(client:set_anonymous_id("anon-rotated"),
		"rotation proceeds once the owed fact drained")
end

local function test_purge_rearm_materializes_at_grant_identity()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	client:update(0.016)
	assert_true(client:flush({ include_summaries = false }))

	-- Consent is revoked (the purge re-arms the retained assignment as
	-- INTENT), time passes and the anonymous id rotates during denial,
	-- then consent returns: the re-emitted exposure must carry the
	-- identity of the moment serving RESUMED — never a denied-period
	-- snapshot for a treatment that was not being served.
	local clock_mod = require "shardpilot.clock"
	assert_true(client:set_consent(false))
	advance_seconds(120)
	assert_true(client:set_anonymous_id("anon-rotated"))
	-- The re-arm intent materializes INSIDE the grant call — serving
	-- resumes at that exact moment, so the snapshot captures the grant
	-- moment's identity; the window brackets set_consent(true) itself.
	-- The clock then moves well past the window before the sweep runs, so
	-- a lazily-at-first-sweep materialization (the pre-fix posture) would
	-- stamp a visibly LATER timestamp and fail the bracket.
	local ts_low = clock_mod.iso_utc()
	assert_true(client:set_consent(true))
	local ts_high = clock_mod.iso_utc()
	advance_seconds(5)
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1)
	assert_equal(exposures[1].anonymous_id, "anon-rotated",
		"the re-emitted exposure carries the serving-resumed identity")
	assert_true(ts_low <= exposures[1].event_ts
		and exposures[1].event_ts <= ts_high,
		"and the grant-moment timestamp, never the denied period's")
end

local function test_transient_pacing_shortens_next_revalidation()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local base = #assignment_requests()

	-- The cadence fires and meets a 503 carrying a SHORT Retry-After: the
	-- window must shorten the next attempt — the cadence deadline was
	-- re-armed a full interval out at dispatch, and without the pull-down
	-- the 5 s window is dead code swallowed by the 300 s cadence.
	next_status = 503
	next_response_body = nil
	next_response_headers = { ["retry-after"] = "5" }
	advance_seconds(400)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 1, "the cadence fired once")
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 1,
		"inside the server window nothing fires")
	next_status = 200
	next_response_body = assignment_body()
	next_response_headers = nil
	advance_seconds(10)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 2,
		"past the SHORT window the retry fires — not after the full cadence")
end

local function test_denied_restore_arms_intent_and_exposes_at_grant_identity()
	reset()
	local restore, stores = install_fake_sys_storage()
	local seed_client = granted_client()
	next_response_body = assignment_body()
	fetch(seed_client, "exp-checkout")

	-- Restart with a persisted DENIED consent: the restored assignment is
	-- not being served (getters are consent-gated), so its exposure must
	-- arm as INTENT — a construction-time snapshot would stamp the future
	-- fact with the denied period's timestamp/identity. When consent is
	-- granted mid-session, the fact materializes with the grant moment's.
	local identity = storage.load(storage_scope)
	identity.consent_analytics = "denied"
	storage.save(storage_scope, identity)
	local clock_mod = require "shardpilot.clock"
	local client = assert(sdk.new(config()))
	advance_seconds(120)
	assert_true(client:set_anonymous_id("anon-rotated"))
	-- The intent materializes INSIDE the grant call (the moment serving
	-- resumes stamps the snapshot's identity), so the timestamp window
	-- brackets set_consent(true) itself; the fact then enqueues once a
	-- session exists to attribute it to — the first session_start migrates
	-- it, and the background tick opens no phantom session for it.
	local ts_low = clock_mod.iso_utc()
	assert_true(client:set_consent(true))
	local ts_high = clock_mod.iso_utc()
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 0,
		"the grant-moment snapshot waits for the first real session")
	assert_true(client:session_start())
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1)
	assert_equal(exposures[1].anonymous_id, "anon-rotated",
		"the restored exposure carries the grant-moment identity")
	assert_equal(exposures[1].session_id, client.session_id,
		"attributed to the first real session")
	assert_true(ts_low <= exposures[1].event_ts
		and exposures[1].event_ts <= ts_high,
		"and the grant-moment timestamp, never the denied launch's")
	restore()
	storage.reset()
end

local function test_retryable_sweep_attempts_do_not_count_as_drops()
	reset()
	local client = granted_client({ buffer_size = 4 })
	assert_true(client:track("filler-a"))
	assert_true(client:track("filler-b"))
	assert_true(client:track("filler-c"))
	assert_true(client:track("filler-d"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- The owed exposure meets the full queue at the install sweep and at
	-- every tick until room exists: each refusal is RETRYABLE (the
	-- snapshot stays armed), so none of the attempts may count as a
	-- dropped event — the fact eventually delivers.
	client:update(0.016)
	client:update(0.016)
	assert_equal(client:snapshot().dropped, 0,
		"retryable owed-exposure attempts are not drops")
	assert_true(client:flush({ include_summaries = false }))
	client:update(0.016)
	assert_equal(#queued_events(client, "experiment_exposure"), 1,
		"the owed fact delivers once room exists")
	assert_equal(client:snapshot().dropped, 0,
		"a delivered fact never counted as dropped")
end

local function test_sentinel_clear_never_condemns_foreign_scope()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	seed_granted_consent()
	-- A staging-scope client persists its assignment; a develop-scope
	-- client then meets the real-subjects sentinel. The record file is
	-- shared per app, but the sentinel condemns ONLY the scope it was
	-- decided for — the staging entries (older-stamped by definition)
	-- must survive both the immediate clear and any later condemnation.
	local b = assert(sdk.new(config({ environment_id = "staging" })))
	next_response_body = assignment_body({ environment_key = "staging" })
	fetch(b, "exp-checkout")
	local a = assert(sdk.new(config()))
	next_status = 403
	next_response_body = json.encode({
		error = "experiment real-subject assignment is disabled",
	})
	fetch(a, "exp-checkout")
	next_status = 200
	local record = storage.load_experiments(config({ environment_id = "staging" }))
	assert_true(record ~= nil and record.entries["exp-checkout"] ~= nil,
		"another scope's record must survive the sentinel's clear")
	assert_nil(storage.load_experiments_clear(config()),
		"the foreign-scope clear settles without leaving a marker")

	-- Same collision with the record store FAILING: the scope check must
	-- settle the clear before any stamp-only condemnation can be minted,
	-- so a staging restart still restores and serves its entries.
	state.fail_save = fail_experiment_saves
	next_status = 403
	next_response_body = json.encode({
		error = "experiment real-subject assignment is disabled",
	})
	fetch(a, "exp-checkout")
	next_status = 200
	state.fail_save = nil
	assert_nil(storage.load_experiments_clear(config()),
		"no marker may condemn a record the clear's scope does not own")
	local b2 = assert(sdk.new(config({ environment_id = "staging" })))
	next_status = 503
	next_response_body = nil
	local stale = fetch(b2, "exp-checkout")
	assert_equal(stale.ok, true)
	assert_equal(stale.from_cache, true,
		"the foreign scope's restart serves its own retained assignment")
	next_status = 200
	restore()
	storage.reset()
end

local function test_marker_survives_demotion_until_drops_durable()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	seed_granted_consent()
	local a = assert(sdk.new(config()))
	next_response_body = assignment_body()
	fetch(a, "exp-checkout")
	next_response_body = assignment_body({ experiment_key = "exp-onboarding" })
	fetch(a, "exp-onboarding")

	-- Sentinel with a failing record store: the clear is owed and the
	-- condemnation marker persists. A fresh authorized install then
	-- DEMOTES the clear while the store is STILL failing — the demoted
	-- per-key drops are memory-only, so the marker must survive the
	-- demotion: an exit in that window still refuses the covered state.
	state.fail_save = fail_experiment_saves
	next_status = 403
	next_response_body = json.encode({
		error = "experiment real-subject assignment is disabled",
	})
	fetch(a, "exp-checkout")
	next_status = 200
	next_response_body = assignment_body()
	fetch(a, "exp-checkout")
	assert_true(storage.load_experiments_clear(config()) ~= nil,
		"the marker must outlive the demotion while the drops are not durable")
	local b = assert(sdk.new(config()))
	next_status = 503
	next_response_body = nil
	local stale = fetch(b, "exp-onboarding")
	assert_equal(stale.ok, false,
		"a restart in the window must still refuse the withdrawn state")
	next_status = 200
	state.fail_save = nil
	b:update(0.016)
	local record = storage.load_experiments(config())
	assert_true(record == nil or record.entries["exp-onboarding"] == nil,
		"the recovered store lands the owed refusal")
	assert_nil(storage.load_experiments_clear(config()),
		"the marker retires once nothing it condemns remains durable")
	restore()
	storage.reset()
end

local function test_shutdown_stays_retryable_while_cache_sync_owed()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- A kill drop is owed with the record store failing THROUGH shutdown:
	-- tearing down would leave the revoked assignment as reload truth, so
	-- shutdown stays retryable (persist() parity) until the sync lands.
	state.fail_save = fail_experiment_saves
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")
	local ok, err = client:shutdown()
	assert_equal(ok, false,
		"shutdown must not finalize while the kill drop is memory-only")
	assert_equal(err, "experiments_pending")
	state.fail_save = nil
	assert_true(client:shutdown(),
		"the recovered store lands the drop and shutdown completes")
	local record = storage.load_experiments(config())
	assert_true(record == nil or record.entries["exp-checkout"] == nil)
	restore()
	storage.reset()
end

local function test_superseded_serve_requires_matching_attributes()
	reset()
	local client = granted_client()
	-- An older geo=CA request is held in flight while a newer
	-- attribute-less request wins the race and installs the settled
	-- entry. The race loser's callback must NOT receive that variant as
	-- a successful cache serve — its targeting context differs, and the
	-- superseded fallback honors the same attribute fence as the
	-- transient serves. (A caller whose context MATCHES the settled
	-- entry still gets the cache serve — the settled-state contract.)
	local held = nil
	responder = function(url, method, callback)
		if held == nil and url:find("geo=CA", 1, true) then
			held = callback
			return true
		end
	end
	local late_result = nil
	client:fetch_experiment_assignment("exp-checkout", { geo = "CA" },
		function(value)
			late_result = value
		end)
	assert_true(held ~= nil)
	responder = nil
	next_response_body = assignment_body()
	local fresh = fetch(client, "exp-checkout")
	assert_true(fresh.ok and fresh.assigned)
	held(nil, nil, { status = 200, response = assignment_body() })
	assert_true(late_result ~= nil)
	assert_equal(late_result.ok, false,
		"the fenced-out geo=CA caller must not receive the mismatched variant")
	assert_equal(late_result.error, "superseded")
	assert_nil(late_result.variant_key)

	-- The matching-context race loser still receives the settled serve.
	local held_match = nil
	responder = function(url, method, callback)
		if held_match == nil
			and url:find("/experiments/assignment", 1, true) then
			held_match = callback
			return true
		end
	end
	local match_result = nil
	client:fetch_experiment_assignment("exp-checkout", nil, function(value)
		match_result = value
	end)
	assert_true(held_match ~= nil)
	responder = nil
	next_response_body = assignment_body({ version = 4 })
	local newer = fetch(client, "exp-checkout")
	assert_true(newer.ok and newer.assigned)
	held_match(nil, nil, { status = 200, response = assignment_body() })
	assert_true(match_result ~= nil)
	assert_equal(match_result.ok, true)
	assert_equal(match_result.from_cache, true)
	assert_equal(match_result.error, "superseded")
end

local function test_rearm_during_regrant_window_keeps_auto_exposure()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	client:update(0.016)
	assert_true(client:flush({ include_summaries = false }))

	-- Consent cycles; in the window between the re-grant and the first
	-- sweep the automatic exposure exists only as a pending re-arm
	-- INTENT. An explicit track_exposure() there buys the EXTRA fact
	-- (arm 1) — it must not consume the automatic slot: the intent still
	-- materializes arm 0 and both facts emit with distinct ids.
	assert_true(client:set_consent(false))
	assert_true(client:set_consent(true))
	assert_true(client:track_exposure("exp-checkout"))
	client:update(0.016)
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 2,
		"the explicit re-arm and the automatic post-grant fact both emit")
	assert_true(exposures[1].event_id ~= exposures[2].event_id)
end

local function test_retry_after_arms_cadence_before_first_tick()
	reset()
	local restore, stores = install_fake_sys_storage()
	local seed_client = granted_client()
	next_response_body = assignment_body()
	fetch(seed_client, "exp-checkout")

	-- A restored assignment has no cadence armed before its first tick.
	-- A transient fetch with a SHORT Retry-After must arm the cadence
	-- from the pacing window (the min rule applies from birth) — not
	-- leave it nil for the first tick to arm a fresh full interval.
	local client = assert(sdk.new(config()))
	next_status = 503
	next_response_body = nil
	next_response_headers = { ["retry-after"] = "5" }
	local stale = fetch(client, "exp-checkout")
	assert_equal(stale.from_cache, true)
	local base = #assignment_requests()
	next_status = 200
	next_response_body = assignment_body()
	next_response_headers = nil
	advance_seconds(10)
	client:update(0.016)
	assert_equal(#assignment_requests(), base + 1,
		"the probe fires at the server window, not a fresh full cadence")
	restore()
	storage.reset()
end

local function test_fresh_install_outranks_pending_clear_marker()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- The sentinel lands while the record store is down: the clear cannot
	-- land, so the condemnation persists as the sidecar marker.
	state.fail_save = fail_experiment_saves
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(client, "exp-checkout")

	-- The clock rolls back below the marker's stamp, storage recovers, and
	-- a LATER authorized fetch reassigns: the install must raise the fresh
	-- entry's stamp decisively above the pending clear — the demotion
	-- protects it in memory, but the constructor's partition would refuse
	-- a restored entry stamped at/below the marker and clear the fresh
	-- assignment on the next launch.
	socket.now = socket.now - 600
	state.fail_save = nil
	next_status = 200
	next_response_body = assignment_body({ variant_key = "fresh" })
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok, "the post-sentinel authorized fetch installs")
	assert_equal(client:experiment_variant("exp-checkout"), "fresh")

	local relaunch = assert(sdk.new(config()))
	assert_equal(relaunch:experiment_variant("exp-checkout"), "fresh",
		"the fresh assignment restores — the rolled-back install outranks the retired clear")
	restore()
	storage.reset()
end

local function test_marker_survives_unreadable_record()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	-- Sentinel with the record store down: marker persisted, clear owed.
	state.fail_save = fail_experiment_saves
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(client, "exp-checkout")

	local marker_path = nil
	for key in pairs(stores) do
		if key:match("/experiments%-clear$") then
			marker_path = key
		end
	end
	assert_true(marker_path ~= nil and stores[marker_path] ~= nil,
		"the durable condemnation marker exists")

	-- PROCESS BOUNDARY: the in-process memory mirror dies with the exit
	-- (storage.reset), the fake disk survives. The relaunch re-arms the
	-- clear from the marker; a fresh authorized install for ANOTHER key
	-- then demotes it — with the record UNREADABLE (the store errors on
	-- read, distinct from a readable miss) and the demoted state still
	-- owed, the settle check must keep the marker: retiring on ambiguity
	-- would lose the only durable refusal, and an exit after that would
	-- let the next launch serve the withdrawn record until its first
	-- probe.
	-- The durable identity record (consent + subject id) survives the
	-- boundary in the fake store — re-seeding would REPLACE it and wipe
	-- the persisted subject, detaching the relaunch from the marker's
	-- scope entirely.
	storage.reset()
	local second = assert(sdk.new(config()))
	state.fail_save = fail_experiment_saves
	local saved_load = sys.load
	sys.load = function(path)
		if path:match("/experiments$") then
			error("io_error")
		end
		return saved_load(path)
	end
	next_status = 200
	next_response_body = assignment_body({ experiment_key = "exp-two" })
	fetch(second, "exp-two")
	second:update(0.016)
	assert_true(type(stores[marker_path]) == "table"
		and stores[marker_path].stamp ~= nil,
		"an unreadable record is NOT settled — the marker survives with its stamp")

	sys.load = saved_load
	storage.reset()
	local relaunch = assert(sdk.new(config()))
	assert_nil(relaunch:experiment_variant("exp-checkout"),
		"the surviving marker still refuses the withdrawn record after a restart")
	restore()
	storage.reset()
end

local function test_oversized_record_write_settles_terminally()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	local client = granted_client()
	assert_true(client:session_start())
	-- A variant payload large enough that the stored record exceeds the
	-- deterministic size cap: the write can never fit, so it must SETTLE —
	-- non-durable serving plus eviction from the record — never wedge
	-- persist()/shutdown() on an owed sync that cannot land.
	next_response_body = assignment_body({
		variant_payload = { blob = string.rep("x", 420000) },
	})
	local result = fetch(client, "exp-checkout")
	assert_true(result.ok)
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"memory serves the oversized assignment")
	local ok, err = client:persist()
	assert_true(ok,
		"persist() settles — a deterministic oversize is terminal, not an owed retry (got "
			.. tostring(err) .. ")")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"serving is non-durable but intact")
	local relaunch = assert(sdk.new(config()))
	assert_nil(relaunch:experiment_variant("exp-checkout"),
		"the evicted entry is absent durably — the next launch refetches")
	restore()
	storage.reset()
end

local function test_stale_sentinel_stamp_ignores_post_dispatch_install()
	reset()
	local restore, stores = install_fake_sys_storage()
	local client = granted_client()
	assert_true(client:session_start())
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	next_response_body = assignment_body({ experiment_key = "exp-two", variant_key = "beta" })
	fetch(client, "exp-two")

	-- One revalidation batch: exp-checkout's answer is HELD in flight while
	-- exp-two's fresh 200 lands first. The held answer then reports the
	-- real-subjects sentinel — its authority is bounded by its own
	-- DISPATCH, so the fresh post-dispatch install must not raise the
	-- clear's stamp above itself and be deleted as covered.
	local held = nil
	responder = function(url, _, callback)
		if not url:find("/runtime/experiments/assignment", 1, true) then
			return false
		end
		if url:find("experiment_key=exp-checkout", 1, true)
			or url:find("exp%-checkout") then
			held = callback
			return true
		end
		callback(nil, nil, { status = 200,
			response = assignment_body({ experiment_key = "exp-two", variant_key = "beta-2" }) })
		return true
	end
	advance_seconds(400)
	client:update(0.016)
	assert_true(held ~= nil, "the sentinel answer is held in flight")
	assert_equal(client:experiment_variant("exp-two"), "beta-2",
		"the sibling key's fresh 200 installed first")
	held(nil, nil, { status = 403,
		response = json.encode({ error = "experiment real-subject assignment is disabled" }) })
	responder = nil

	local record_path = nil
	for key in pairs(stores) do
		if key:match("/experiments$") then
			record_path = key
		end
	end
	assert_true(record_path ~= nil and type(stores[record_path]) == "table",
		"the durable record survives the sentinel")
	assert_true(stores[record_path].entries ~= nil
		and stores[record_path].entries["exp-two"] ~= nil,
		"the post-dispatch install survives the sentinel's stamped partition")
	assert_nil(stores[record_path].entries["exp-checkout"],
		"while the sentinel's own key is withdrawn")

	local relaunch = assert(sdk.new(config()))
	assert_equal(relaunch:experiment_variant("exp-two"), "beta-2",
		"and restores on the next launch")
	assert_nil(relaunch:experiment_variant("exp-checkout"))
	restore()
	storage.reset()
end

local function test_regrant_window_blocks_rotation_until_materialized()
	reset()
	seed_granted_consent()
	local client = assert(sdk.new(config({
		token_provider = function(callback)
			callback("client-token-placeholder", nil, nil)
		end,
	})))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_true(client:flush({ include_summaries = false }))

	-- Deny (the purge re-arms the retained assignment as INTENT), then
	-- re-grant: the intent must materialize AT THE GRANT — the treatment
	-- resumes serving that instant under the OLD anon — so the Mode B
	-- rotation gate sees the owed automatic fact immediately. The lazy
	-- first-sweep posture left a window in which has_owed_exposures()
	-- reported none and a rotation could slip through, stamping the fact
	-- with the NEW anon's identity.
	assert_true(client:set_consent(false))
	assert_true(client:set_consent(true))
	assert_true(client:flush({ include_summaries = false }),
		"the consent receipts drain")
	local ok, err = client:set_anonymous_id("anon-rotated")
	assert_equal(ok, false,
		"rotation is blocked while the grant-materialized exposure is owed")
	assert_equal(err, "events_pending")
	client:update(0.016)
	assert_true(client:flush({ include_summaries = false }))
	assert_true(client:set_anonymous_id("anon-rotated"),
		"rotation proceeds once the owed fact drained")
end

local function test_sentinel_purges_queue_resident_exposure_facts()
	reset()
	local client = granted_client()
	assert_true(client:session_start())
	assert_true(client:track("filler-host-event"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 1,
		"the accepted exposure fact sits in the queue below batch size")

	-- The sentinel withdraws the assignments AND their subject-fact keys:
	-- facts already ACCEPTED into the analytics queue carry those keys
	-- verbatim and must not ship on the next flush — the kill switch stops
	-- egress, not just future serving.
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0,
		"queue-resident exposure facts are purged with the sentinel")
	assert_equal(#queued_events(client, "filler-host-event"), 1,
		"host events are untouched — the purge is selective, not the consent nuke")

	next_status = 200
	next_response_body = nil
	assert_true(client:flush({ include_summaries = false }))
	for i = 1, #requests do
		if requests[i].url:find("/v1/events:batch", 1, true) then
			assert_true(not requests[i].body:find("experiment_exposure", 1, true),
				"no exposure fact egresses after the sentinel")
		end
	end
end

local function test_sentinel_purges_retained_backoff_batch()
	reset()
	local client = granted_client()
	assert_true(client:session_start())
	assert_true(client:track("filler-host-event"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 1)

	-- The batch (host event + exposure fact) fails transiently and is
	-- RETAINED behind the retry backoff.
	responder = function(url, _, callback)
		if url:find("/v1/events:batch", 1, true) then
			callback(nil, nil, { status = 503, response = "{}" })
			return true
		end
		return false
	end
	local flushed = client:flush({ include_summaries = false })
	assert_true(not flushed, "the 503 retains the batch for retry")
	assert_true(client.in_flight_batch ~= nil)

	-- The sentinel lands BETWEEN attempts: the retained batch must lose
	-- the withdrawn facts (and its cached wire payload must be rebuilt) or
	-- the next attempt re-sends them verbatim.
	responder = nil
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(client, "exp-checkout")

	responder = function(url, _, callback)
		if url:find("/v1/events:batch", 1, true) then
			callback(nil, nil, { status = 202, response = '{"accepted":1}' })
			return true
		end
		return false
	end
	advance_seconds(60)
	local requests_before = #requests
	assert_true(client:flush({ include_summaries = false }))
	responder = nil
	for i = requests_before + 1, #requests do
		if requests[i].url:find("/v1/events:batch", 1, true) then
			assert_true(not requests[i].body:find("experiment_exposure", 1, true),
				"the retained batch resends WITHOUT the withdrawn facts")
			assert_true(requests[i].body:find("filler%-host%-event") ~= nil,
				"and keeps the host's events")
		end
	end
end

local function test_sentinel_purges_spooled_facts_from_prior_launch()
	reset()
	local restore, stores = install_fake_sys_storage()
	local first = granted_client()
	assert_true(first:session_start())
	assert_true(first:track("filler-host-event"))
	next_response_body = assignment_body()
	fetch(first, "exp-checkout")
	assert_equal(#queued_events(first, "experiment_exposure"), 1)
	-- A transiently failing publish durably SPOOLS the batch (exposure
	-- fact included); the process then dies without a clean shutdown.
	responder = function(url, _, callback)
		if url:find("/v1/events:batch", 1, true) then
			callback(nil, nil, { status = 503, response = "{}" })
			return true
		end
		return false
	end
	assert_true(not first:flush({ include_summaries = false }))
	responder = nil

	-- The next launch loads the spool for re-send — and the sentinel lands
	-- BEFORE the re-send window. The spooled exposure fact carries the
	-- withdrawn subject-fact key: it must leave both the loaded chunks and
	-- the durable record, or the relaunch ships it.
	local second = assert(sdk.new(config()))
	assert_true(second:spool_pending(), "the spooled envelopes await re-send")
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(second, "exp-checkout")

	next_status = 200
	next_response_body = nil
	local requests_before = #requests
	assert_true(second:flush({ include_summaries = false }))
	local resent = 0
	for i = requests_before + 1, #requests do
		if requests[i].url:find("/v1/events:batch", 1, true) then
			resent = resent + 1
			assert_true(not requests[i].body:find("experiment_exposure", 1, true),
				"the spool re-send excludes the withdrawn facts")
			assert_true(requests[i].body:find("filler%-host%-event") ~= nil,
				"and still delivers the host's spooled events")
		end
	end
	assert_true(resent > 0, "the surviving spooled envelopes re-sent")
	restore()
	storage.reset()
end

local function test_presession_exposure_attributes_to_lazy_first_session()
	reset()
	local restore = install_fake_sys_storage()
	local seed_client = granted_client()
	next_response_body = assignment_body()
	fetch(seed_client, "exp-checkout")

	-- Relaunch: the restored snapshot is pre-session. Host activity lazily
	-- opens the first real session (a pre-start track), the snapshot stays
	-- held (no tick runs), and the explicit session_start is a RENEWAL of
	-- that lazy session: the still-unattributed snapshot takes the LAZY
	-- session's id — the session it lived through — while the renewal
	-- re-arms the entry for the new session. Each real session gets
	-- exactly one fact, correctly attributed.
	local second = assert(sdk.new(config()))
	assert_true(second:track("boot-event"))
	local lazy_session = second.session_id
	assert_true(lazy_session ~= nil, "host activity opened the lazy first session")
	assert_true(second:session_start())
	local started_session = second.session_id
	assert_true(started_session ~= lazy_session)
	second:update(0.016)
	local exposures = queued_events(second, "experiment_exposure")
	assert_equal(#exposures, 2,
		"one fact per real session: the lazy first session's and the renewal's")
	assert_equal(exposures[1].session_id, lazy_session,
		"the pre-session application is attributed to the lazy FIRST session")
	assert_equal(exposures[2].session_id, started_session,
		"the renewal re-arm rides the new session")
	restore()
	storage.reset()
end

local function test_sentinel_purged_tuple_reexposes_on_refetch()
	reset()
	local client = granted_client()
	assert_true(client:session_start())
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	local exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1)
	local original_id = exposures[1].event_id

	-- The sentinel purges the queued fact — it never egressed — and the
	-- platform then flips real subjects back ON in the same session: the
	-- refetched tuple must expose again (a retained dedupe mark would
	-- under-count the re-served treatment), and it derives the SAME
	-- deterministic id, so a fact that had somehow already published
	-- collapses server-side instead of double-counting.
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0)

	next_status = 200
	next_response_body = assignment_body()
	local refetched = fetch(client, "exp-checkout")
	assert_true(refetched.ok, "the flag flipped back on — the plane recovers")
	exposures = queued_events(client, "experiment_exposure")
	assert_equal(#exposures, 1,
		"the purged tuple re-exposes on the same-session refetch")
	assert_equal(exposures[1].event_id, original_id,
		"with the same deterministic id — server-side dedupe stays the guard")
end

local function test_condemned_relaunch_filters_spooled_facts()
	reset()
	local restore, stores, state = install_fake_sys_storage()
	local client = granted_client()
	assert_true(client:session_start())
	assert_true(client:track("filler-host-event"))
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 1)
	-- The batch (filler + fact) spools durably on a transient failure.
	responder = function(url, _, callback)
		if url:find("/v1/events:batch", 1, true) then
			callback(nil, nil, { status = 503, response = "{}" })
			return true
		end
		return false
	end
	assert_true(not client:flush({ include_summaries = false }))
	responder = nil

	-- The sentinel lands with the WHOLE store down: the record clear and
	-- the spool rewrite both fail — only the sidecar marker persists. The
	-- process then dies. The relaunch must not re-send the spooled facts:
	-- the armed condemnation is consulted at spool load and the withdrawn
	-- facts are dropped there, durably.
	state.fail_save = function(path)
		return path:match("/experiments$") ~= nil or path:match("/spool$") ~= nil
	end
	next_status = 403
	next_response_body = json.encode({ error = "experiment real-subject assignment is disabled" })
	fetch(client, "exp-checkout")
	state.fail_save = nil
	storage.reset()

	local relaunch = assert(sdk.new(config()))
	next_status = 200
	next_response_body = nil
	local requests_before = #requests
	assert_true(relaunch:flush({ include_summaries = false }))
	local resent = 0
	for i = requests_before + 1, #requests do
		if requests[i].url:find("/v1/events:batch", 1, true) then
			resent = resent + 1
			assert_true(not requests[i].body:find("experiment_exposure", 1, true),
				"the condemned relaunch never re-sends withdrawn facts")
			assert_true(requests[i].body:find("filler%-host%-event") ~= nil,
				"while the host's spooled events still deliver")
		end
	end
	assert_true(resent > 0, "the surviving spooled envelopes re-sent")
	restore()
	storage.reset()
end

local function test_dropped_entry_owed_exposure_replays_after_kill()
	reset()
	local restore = install_fake_sys_storage()
	local client = granted_client({ buffer_size = 1 })
	assert_true(client:session_start())
	-- The queue is FULL (buffer_size 1 holds the session start), so the
	-- applied assignment's exposure stays OWED in memory.
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	assert_equal(#queued_events(client, "experiment_exposure"), 0,
		"the exposure is owed, not queued")

	-- The kill switch drops the entry DURABLY while the exposure is still
	-- owed only in memory: the delete removes the only persisted source
	-- the fact could re-arm from, so the drop must durably capture it —
	-- a process kill before the next sweep would otherwise lose the
	-- treatment's record entirely.
	next_response_body = not_assigned_body("kill_switch")
	fetch(client, "exp-checkout")

	-- SIMULATED PROCESS DEATH: no shutdown, no persist — module memory
	-- dies, the fake disk survives.
	storage.reset()
	local relaunch = assert(sdk.new(config()))
	assert_nil(relaunch:experiment_variant("exp-checkout"),
		"the kill landed durably — nothing restores")
	assert_true(relaunch:spool_pending(),
		"the captured fact envelope survived the kill in the spool")
	local requests_before = #requests
	assert_true(relaunch:flush({ include_summaries = false }))
	local replayed = false
	for i = requests_before + 1, #requests do
		if requests[i].url:find("/v1/events:batch", 1, true)
			and requests[i].body:find("experiment_exposure", 1, true) then
			replayed = true
		end
	end
	assert_true(replayed,
		"the relaunch replays the dropped entry's owed exposure from the spool")
	restore()
	storage.reset()
end

local function test_unproven_status_keeps_auth_latch()
	reset()
	local client = granted_client()
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")
	next_status = 401
	next_response_body = nil
	fetch(client, "exp-checkout")
	assert_nil(client:experiment_variant("exp-checkout"),
		"the 401 latches fail-closed")

	-- A post-latch fetch answered by an unexpected status (a captive
	-- portal's redirect, a gateway conflict) is authoritative for the
	-- caller but carries NO authorization proof: it must not unlatch the
	-- fail-closed plane. The latch's memory wipe makes the getters nil
	-- either way today, so the LATCH FLAG itself is the pinned contract —
	-- it must not lie to any current or future serve path (the flag is
	-- the plane's fail-closed truth, the wipe merely its consequence).
	next_status = 302
	next_response_body = ""
	local result = fetch(client, "exp-checkout")
	assert_equal(result.ok, false)
	assert_equal(result.error, "http_302")
	assert_nil(client:experiment_variant("exp-checkout"),
		"an unproven status must not resume serving")
	assert_true(client.experiments.auth_blocked,
		"an unproven status must not unlatch the fail-closed plane")

	-- A genuine authorized outcome still recovers the plane.
	next_status = 200
	next_response_body = assignment_body()
	local recovered = fetch(client, "exp-checkout")
	assert_true(recovered.ok)
	assert_true(not client.experiments.auth_blocked,
		"a parsed authorized outcome still unlatches")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"a parsed authorized 200 unlatches and reinstalls")
end

local function test_unexpected_status_classification_pin()
	reset()
	-- PIN (passes before and after this round): the classification table
	-- for statuses outside the handled set — 302/409/422 and kin — on a
	-- cached assignment. Contract: authoritative-no-serve for THAT call
	-- (closed http_<status> error, no stale serve), the cached record
	-- RETAINED and STILL SERVED by the getters, and the revalidation
	-- cadence KEEPS PROBING — the kill-switch reach survives, so no
	-- unclassified status can freeze a stale assignment beyond the
	-- server's own answers. No status lands in an implicit bucket.
	local client = granted_client()
	assert_true(client:session_start())
	next_response_body = assignment_body()
	fetch(client, "exp-checkout")

	next_status = 409
	next_response_body = "{}"
	local result = fetch(client, "exp-checkout")
	assert_equal(result.ok, false)
	assert_equal(result.error, "http_409")
	assert_equal(result.from_cache, false, "no stale serve on the failing call")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"the cached record is retained and served")

	local probes_before = #assignment_requests()
	advance_seconds(400)
	client:update(0.016)
	assert_true(#assignment_requests() > probes_before,
		"the cadence keeps probing after the unexpected status")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment",
		"and the assignment keeps serving between probes")

	next_status = 422
	local unproc = fetch(client, "exp-checkout")
	assert_equal(unproc.ok, false)
	assert_equal(unproc.error, "http_422")
	assert_equal(client:experiment_variant("exp-checkout"), "treatment")
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
	test_ordinary_auth_failure_keeps_durable_cache_despite_owed_write,
	test_fenced_out_response_reports_settled_state,
	test_owed_drop_retry_yields_to_fresher_sibling_write,
	test_rearm_while_auto_exposure_owed_emits_both,
	test_shutdown_sweeps_owed_exposure_after_flush,
	test_shutdown_retries_owed_durable_drop,
	test_owed_clear_demoted_before_ordinary_latch,
	test_clock_rollback_does_not_fence_refresh_write,
	test_stale_grammar_reject_does_not_remint,
	test_owed_exposures_stay_session_scoped,
	test_ordinary_latch_preserves_owed_exposure,
	test_remint_preserves_owed_exposure_of_past_treatment,
	test_sentinel_discards_owed_exposures,
	test_cadence_remint_retry_carries_attributes,
	test_stale_scope_retry_after_does_not_park_revalidation,
	test_shutdown_completes_with_active_session_and_full_queue,
	test_restored_exposure_migrates_to_first_session,
	test_permanent_400_drops_cached_assignment,
	test_shutdown_captures_deferred_session_end_when_flush_cannot_send,
	test_stale_auth_refusal_does_not_latch,
	test_credential_swap_scopes_the_cache,
	test_mismatched_experiment_key_is_malformed,
	test_unknown_not_assigned_reason_is_malformed,
	test_failed_sentinel_clear_never_resurrects_serving,
	test_non_string_reason_is_malformed,
	test_sibling_write_lands_owed_drops,
	test_grammar_400_after_spent_budget_drops_entry,
	test_mismatched_app_or_environment_is_malformed,
	test_non_string_scope_echo_is_malformed,
	test_owed_drop_lands_against_retired_scope,
	test_rotation_cancels_owed_writes,
	test_sibling_save_folds_owed_writes,
	test_shutdown_fails_when_housekeeping_events_cannot_persist,
	test_restored_attributes_renormalize_before_revalidation,
	test_consent_purge_discards_dead_owed_exposures,
	test_owed_exposure_keeps_original_session_identity,
	test_shutdown_buffer_one_drains_owed_exposure_after_session_end,
	test_sibling_client_adopts_persisted_subject,
	test_owed_exposure_keeps_original_anonymous_id_and_timestamp,
	test_persist_spools_owed_exposure_fact,
	test_persist_reports_uncaptured_experiment_state,
	test_owed_clear_retry_preserves_sibling_fresh_write,
	test_owed_clear_demotion_preserves_fresh_disk_entry,
	test_transient_serve_requires_matching_attributes,
	test_stale_inflight_sentinel_preserves_sibling_write,
	test_condemned_record_refused_after_restart,
	test_condemned_survivor_restores_and_converges,
	test_sibling_adopts_after_corrupt_subject_heals,
	test_migrated_snapshot_keeps_apply_identity_through_session_start,
	test_mode_b_rotation_blocked_while_exposure_owed,
	test_purge_rearm_materializes_at_grant_identity,
	test_transient_pacing_shortens_next_revalidation,
	test_denied_restore_arms_intent_and_exposes_at_grant_identity,
	test_retryable_sweep_attempts_do_not_count_as_drops,
	test_sentinel_clear_never_condemns_foreign_scope,
	test_marker_survives_demotion_until_drops_durable,
	test_shutdown_stays_retryable_while_cache_sync_owed,
	test_superseded_serve_requires_matching_attributes,
	test_rearm_during_regrant_window_keeps_auto_exposure,
	test_retry_after_arms_cadence_before_first_tick,
	test_fresh_install_outranks_pending_clear_marker,
	test_marker_survives_unreadable_record,
	test_oversized_record_write_settles_terminally,
	test_stale_sentinel_stamp_ignores_post_dispatch_install,
	test_regrant_window_blocks_rotation_until_materialized,
	test_sentinel_purges_queue_resident_exposure_facts,
	test_sentinel_purges_retained_backoff_batch,
	test_sentinel_purges_spooled_facts_from_prior_launch,
	test_presession_exposure_attributes_to_lazy_first_session,
	test_sentinel_purged_tuple_reexposes_on_refetch,
	test_condemned_relaunch_filters_spooled_facts,
	test_dropped_entry_owed_exposure_replays_after_kill,
	test_unproven_status_keeps_auth_latch,
	test_unexpected_status_classification_pin,
}

for _, test in ipairs(tests) do
	test()
end

print("shardpilot defold experiments tests passed")
