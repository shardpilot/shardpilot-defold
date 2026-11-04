-- Every case of the vendored wire-conformance corpus, driven through this SDK's
-- own handlers (scripts/check_conformance_pack.py proves the bytes). The request
-- line is PASS only where this SDK builds the request from the case's own inputs
-- and it matches byte for byte; otherwise UNSUPPORTED with a named reason. The
-- response line asserts the real handler's outcome class: admitted, refused or retry.
package.path = "./?.lua;./?/init.lua;" .. package.path

local NOW = 1789905630 -- 2026-09-20T12:00:30Z, inside the captured plans' expiry window
local BASE = "https://conformance.test"
local KEY = "sp_ingest_publishable_key"
socket = { gettime = function() return NOW end }
sys = { get_sys_info = function() return { system_name = "Linux" } end }
local exchange, sent
http = { request = function(url, method, callback, headers, body)
	sent = { url = url, method = method, headers = headers or {}, body = body }
	callback(nil, nil, exchange)
end }

local function decode(text)
	local pos, value = 1, nil
	local function skip() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end
	local function char() return text:sub(pos, pos) end
	local escapes = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
	local function str()
		local out, i = {}, pos + 1
		while true do
			local stop = assert(text:find('["\\]', i), "unterminated string")
			out[#out + 1] = text:sub(i, stop - 1)
			if text:sub(stop, stop) == '"' then pos = stop + 1; return table.concat(out) end
			local e = text:sub(stop + 1, stop + 1)
			if e == "u" then -- a BMP code point, as UTF-8
				local c = assert(tonumber(text:sub(stop + 2, stop + 5), 16))
				out[#out + 1] = c < 128 and string.char(c) or c < 2048 and string.char(192 + math.floor(c / 64), 128 + c % 64)
					or string.char(224 + math.floor(c / 4096), 128 + math.floor(c / 64) % 64, 128 + c % 64)
				i = stop + 6
			else out[#out + 1] = escapes[e] or e; i = stop + 2 end
		end
	end
	local function members(close, read)
		pos = pos + 1; skip()
		if char() == close then pos = pos + 1; return end
		repeat read(); skip(); local c = char(); pos = pos + 1
			if c == close then return end
			assert(c == ",", "expected , or " .. close .. " at " .. pos)
		until false
	end
	function value()
		skip()
		local c = char()
		if c == "{" then
			local t = {}
			members("}", function() skip(); local k = str(); skip(); assert(char() == ":"); pos = pos + 1; t[k] = value() end)
			return t
		elseif c == "[" then
			local t, n = {}, 0
			members("]", function() n = n + 1; t[n] = value() end)
			return t
		elseif c == '"' then return str() end
		if text:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
		local word = text:match("^true", pos) or text:match("^false", pos)
		if word then pos = pos + #word; return word == "true" end
		local number = assert(text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos), "bad value at " .. pos)
		pos = pos + #number
		return tonumber(number)
	end
	local result = value(); skip()
	assert(pos > #text, "trailing data")
	return result
end

-- Request bodies are never compared here (the engine's encoder is not in this
-- runtime), so encode only has to hand the transport some bytes.
json = { decode = decode, encode = function() return "{}" end }
local remote_config = require "shardpilot.remote_config"
local transport = require "shardpilot.transport"
local crash_transport = require "shardpilot.crash.transport"
local consent_policy = require "shardpilot.consent_policy"
local non_objection = require "shardpilot.non_objection"
local Client = require("test.inspect_client").class(require("shardpilot.client").new)
local storage = require("test.inspect_client").storage()
local DIR = "test/conformance/v1/"
local function read(path)
	local file = assert(io.open(DIR .. path, "rb"))
	local data = file:read("*a"); file:close()
	return data
end
local manifest, roster = decode(read("manifest.json")), decode(read("roster.json"))
assert(manifest.schema_version == 1 and manifest.byte_exact == true, "unknown corpus schema")
-- Every request but the remote config GET has a JSON body encoded by the
-- engine's json.encode, so none of them can be compared byte for byte here.
local UNSUPPORTED = {
	batchIngestEvents = "event bodies are encoded by the engine's json.encode, absent from the Lua runtime; the captured bodies carry receiver-authored member order and source=backend",
	recordConsent = "receipt bodies are encoded by the engine's json.encode, absent from the Lua runtime; the captured member order is receiver-authored",
	resolveConsentPolicy = "the request body is encoded by the engine's json.encode, absent from the Lua runtime; the captured bodies also carry store_region:null, which this SDK omits",
	ingestCrash = "native-shaped crash bodies are encoded by the engine's json.encode, absent from the Lua runtime",
}
-- Expected classes follow evidence and status, with one reviewed exception.
local EXPECT = {
	["nonobjection-flag-off"] = "refused", -- recorded without the advisory basis: no ACK, analytics stay closed
}
local function expected(case)
	if EXPECT[case.id] then return EXPECT[case.id] end
	if case.evidence == "receiver_admitted" then return "admitted" end
	return (case.response.status == 429 or case.response.status >= 500) and "retry" or "refused"
end
local function class(ok, retryable) return ok and "admitted" or retryable and "retry" or "refused" end
local function transport_class(ok, err, retryable, case)
	assert(ok or err == "http_" .. case.response.status or err:match("^transient_"), "error " .. tostring(err))
	return class(ok, retryable)
end
local function body_of(case) return decode(read(case.response.file)) end
local drive = {}
function drive.batchIngestEvents(case, request)
	local decoded, payload = pcall(decode, request)
	payload = decoded and payload or { events = {} } -- this SDK cannot emit the malformed case
	local outcome
	transport.publish({ ingest_url = BASE }, KEY, payload, function(ok, err, _, retryable)
		outcome = transport_class(ok, err, retryable, case)
	end)
	local fake = setmetatable({ stats = { accepted = 0, rejected = 0, duplicates = 0, observed = 0, suppressed = 0 },
		config = { rejection_capacity = 64, diagnostics = function() end }, rejection_records = {} }, { __index = Client })
	local body = body_of(case)
	if outcome == "admitted" then
		fake:apply_batch_response(exchange.response, #payload.events)
		for _, field in ipairs({ "accepted", "rejected", "duplicates", "suppressed" }) do
			assert(fake.stats[field] == body[field], field .. " counted " .. fake.stats[field] .. ", receiver said " .. body[field])
		end
	else
		fake:apply_error_envelope("http_" .. case.response.status, exchange)
		assert(fake.stats.last_error == "http_" .. case.response.status .. ":" .. body.error.code, "envelope code not surfaced")
	end
	return outcome
end
function drive.recordConsent(case, request)
	local outcome
	transport.send_consent({ ingest_url = BASE }, KEY, decode(request), function(ok, err, _, retryable)
		outcome = transport_class(ok, err, retryable, case)
		-- A non-objection receipt is only acknowledged by a valid ACK body.
		if ok and case.surface == "non_objection" and not non_objection.response(body_of(case)) then outcome = "refused" end
	end)
	return outcome
end
function drive.resolveConsentPolicy(case, request)
	local q, decision = decode(request), nil
	consent_policy.prepare({ workspace_key = q.workspace_key or q.workspace_id, app_key = q.app_key,
		environment_key = q.environment_key, app_version = q.app_version, store = q.store, locale = q.locale,
		platform = q.platform, advisory = q.advisory, app_url = BASE }, function(d) decision = d end)
	assert(decision, "no decision")
	local body = body_of(case)
	assert(not decision.plan_used, "a plan was used, but this build has no plan verifier")
	if body.reason then
		assert(decision.reason == body.reason, "refusal reason " .. tostring(decision.reason))
		return "refused"
	end
	-- A plan read in full settles as plan_unsigned; any other reason refused a field.
	assert(decision.reason == "plan_unsigned", "plan refused: " .. tostring(decision.detail))
	assert((q.advisory == true) == (decision.advisory ~= nil), "advisory part not carried to the host")
	return "admitted"
end
local SEED = read("bodies/rc.two-key-200.response")
function drive.fetchRemoteConfigSDKConfigByKeys(case)
	local q = case.request
	local workspace, environment = q.path:match("^/config/v1/([^/]+)/([^/]+)$")
	local anonymous, etag = q.headers["X-ShardPilot-Anonymous-Id"], q.headers["If-None-Match"]
	local rc = remote_config.new({ app_url = BASE, workspace_id = workspace, environment_id = environment,
		publishable_key = KEY, http_timeout_seconds = 2, remote_config_enabled = true },
		function() return anonymous or "" end, function() return anonymous and "granted" or "unknown" end)
	local scope = rc:scope_for(anonymous or "")
	if etag then rc.cache = { scope = scope, etag = etag, body = SEED, fetched_at_ms = NOW * 1000 - 1000 } end
	local result
	rc:fetch(function(r) result = r end)
	assert(result, "no fetch result")
	local status = case.response.status
	if status == 304 then assert(result.from_cache and result.values, "304 did not serve the revalidated cache") end
	local retry_after = case.response.headers["Retry-After"]
	if retry_after then
		local paced = assert(rc.paced[scope], "Retry-After not honoured")
		assert(paced.until_ms == (NOW + tonumber(retry_after)) * 1000, "Retry-After window " .. paced.until_ms)
	end
	local want = status == 401 and "unauthorized" or (status == 429 or status >= 500) and "transient_" .. status or "http_" .. status
	assert(result.ok or result.error == want, "error " .. tostring(result.error) .. ", want " .. want)
	return class(result.ok, result.error and result.error:match("^transient_"))
end
function drive.ingestCrash(case, request)
	local outcome
	crash_transport.ingest_body({ crash_url = BASE }, KEY, request, function(ok, err, _, retryable)
		outcome = transport_class(ok, err, retryable, case)
	end)
	return outcome
end
-- The credential kinds this SDK sends per operation (crash: its crash:write API key).
local CREDENTIALS = {
	batchIngestEvents = { publishable_key = true, client_jwt = true }, recordConsent = { publishable_key = true, client_jwt = true },
	resolveConsentPolicy = { none = true }, fetchRemoteConfigSDKConfigByKeys = { publishable_key = true }, ingestCrash = { api_key = true },
}
-- Byte-exact needs every part: request line, approved headers, credential kind and body. The
-- remote config GET is built from the case's own inputs: path, identity header and cached ETag.
local function compare_request(case)
	local q, reasons = case.request, {}
	for _, name in ipairs(roster.approved_headers) do
		assert(sent.headers[name] == q.headers[name], "header " .. name .. " sent " .. tostring(sent.headers[name]))
	end
	if case.byte_exact ~= true then reasons[#reasons + 1] = "the corpus does not mark this case byte-exact" end
	if CREDENTIALS[case.operation][q.credential] then
		local auth = sent.headers.Authorization
		assert(q.credential == "none" and auth == nil or q.credential ~= "none" and tostring(auth):match("^Bearer %S+$"),
			"credential " .. q.credential .. " not sent as declared: " .. tostring(auth))
	else
		reasons[#reasons + 1] = "credential " .. q.credential .. " is not how this SDK sends this request"
	end
	if case.id == "batch-malformed-json" then reasons[#reasons + 1] = "the captured body is not JSON, which this SDK never emits"
	elseif q.file then reasons[#reasons + 1] = UNSUPPORTED[case.operation]
	else assert(q.bytes == 0 and (sent.body == nil or sent.body == ""), "a body was sent where the case has none") end
	return #reasons == 0, table.concat(reasons, "; ")
end
local failures, counts = 0, { PASS = 0, UNSUPPORTED = 0 }
for _, case in ipairs(manifest.cases) do
	local ok, err = pcall(function()
		assert(manifest.applicability[case.surface].defold.value == "required", "no driver for a case that is not required")
		local headers = {}
		for name, value in pairs(case.response.headers or {}) do headers[name:lower()] = value end
		exchange = { status = case.response.status, headers = headers, response = case.response.file and read(case.response.file) or "" }
		sent = nil
		storage.reset() -- each case starts from a fresh install: no cache, no ETag
		local request = case.request.file and read(case.request.file)
		local outcome = drive[case.operation](case, request)
		assert(sent and sent.method == case.request.method and sent.url == BASE .. case.request.path, "dispatched to the wrong route")
		assert(outcome == expected(case), "outcome " .. tostring(outcome) .. ", want " .. expected(case))
		local exact, reason = compare_request(case)
		local verdict = exact and "PASS" or "UNSUPPORTED"; counts[verdict] = counts[verdict] + 1
		print(string.format("%s %s request%s", verdict, case.id, exact and " byte-exact" or ": " .. reason))
		print(string.format("PASS %s response %d -> %s", case.id, case.response.status, outcome))
	end)
	if not ok then
		failures = failures + 1
		print(string.format("FAIL %s %s", case.id, tostring(err)))
	end
end
-- Reviewed: the 11 remote config GETs sent with a publishable key are the byte-exact requests.
if counts.PASS ~= 11 then failures = failures + 1; print("FAIL expected 11 byte-exact requests, got " .. counts.PASS) end
print(string.format("%d cases: %d request PASS, %d request UNSUPPORTED, %d FAIL", #manifest.cases, counts.PASS, counts.UNSUPPORTED, failures))
if failures > 0 or #manifest.cases == 0 then os.exit(1) end
