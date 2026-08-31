-- A6 spool-overflow benchmark, Defold SDK.
--
-- Drives the REAL Client:spool_envelopes under sustained overflow -- one
-- envelope per append, the shape a full queue produces -- and reports the two
-- numbers docs/SPOOL_OVERFLOW_LATENCY_BOUND.md bounds.
--
-- ⚠ WHAT THIS HARNESS DOES AND DOES NOT MEASURE. sys.save here STORES A
-- REFERENCE and returns; it does not serialize. Every millisecond below is
-- therefore the SDK's OWN work in Lua, with the engine's durable write
-- excluded entirely. That is deliberate -- it is the half this SDK controls --
-- but it means the absolute figures are NOT an end-to-end frame cost, and the
-- bound document says so rather than implying otherwise.
--
--   lua5.1 test/bench_spool_append.lua [appends]
package.path = "./?.lua;./?/init.lua;" .. package.path

socket = { now = 1000, gettime = function() socket.now = socket.now + 0.1; return socket.now end }

local stores = {}
local save_calls, save_entries = 0, 0
sys = {
	get_sys_info = function() return { system_name = "Linux" } end,
	get_save_file = function(app, name) return app .. "/" .. name end,
	save = function(path, record)
		save_calls = save_calls + 1
		if type(record) == "table" and type(record.events) == "table" then
			save_entries = save_entries + #record.events
		end
		stores[path] = record
		return true
	end,
	load = function(path) return stores[path] end,
}
http = { request = function(url, method, cb) cb(nil, nil, { status = 202, response = '{"accepted":1}' }) end }

-- Real Defold provides `json`, and approx_envelope_bytes uses json.encode when
-- it is there. Without this global the benchmark measures the FALLBACK
-- estimator, which is not what ships. Counted, because "how many envelopes are
-- re-encoded per append" is the machine-independent statement of the defect.
local encode_calls = 0
local function enc(v)
	local t = type(v)
	if t == "string" then return '"' .. v:gsub('[\\"]', '\\%0') .. '"' end
	if t == "number" or t == "boolean" then return tostring(v) end
	if t ~= "table" then return "null" end
	local is_array, max = true, 0
	for k in pairs(v) do
		if type(k) ~= "number" then is_array = false break end
		if k > max then max = k end
	end
	local parts = {}
	if is_array then
		for i = 1, max do parts[#parts + 1] = enc(v[i]) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = tostring(k) end
	table.sort(keys)
	for i = 1, #keys do parts[#parts + 1] = enc(keys[i]) .. ":" .. enc(v[keys[i]]) end
	return "{" .. table.concat(parts, ",") .. "}"
end
json = { encode = function(v) encode_calls = encode_calls + 1; return enc(v) end }

local sdk = require("shardpilot.sdk")
local storage = require("shardpilot.storage")

-- Consent must be GRANTED on disk before the client will spool anything:
-- spool_envelopes is fail-closed on consent_state. Seeded the way the test
-- suite seeds it.
local identity_scope = { workspace_id = "workspace-example", app_id = "app-example",
                         environment_id = "develop" }
local seed = storage.load(identity_scope) or {}
seed.consent_analytics = "granted"
assert(storage.save(identity_scope, seed), "seeding the consent grant must succeed")

local client = assert(sdk.new({
	ingest_url = "http://localhost:8080",
	workspace_id = "workspace-example",
	app_id = "app-example",
	environment_id = "develop",
	app_version = "0.1.0",
	app_build = "100",
	token_provider = function(callback) callback("client-token-placeholder", nil, nil) end,
	flush_interval_seconds = 1,
	publish_timeout_seconds = 2,
}))

local function make_envelope(i)
	return {
		event_id = string.format("evt-%08d-aaaabbbbccccddddeeeeffff", i),
		event_name = "level_completed",
		event_ts = "2026-08-25T19:00:00.000Z",
		anonymous_id = "anon-0123456789abcdef0123456789abcdef",
		session_id = "sess-0123456789abcdef0123456789abcdef",
		session_sequence = i,
		props = { level = i, score = i * 7, mode = "campaign", duration_ms = i * 13,
		          device = "desktop", region = "eu-west-1" },
		context = { sdk = "shardpilot-defold", sdk_version = "0.1.0", platform = "linux" },
	}
end

local N = tonumber(arg and arg[1] or nil) or 2000
local samples = {}
local t_total = 0
for i = 1, N do
	local env = make_envelope(i)
	local t0 = os.clock()
	client:spool_envelopes({ env })
	local dt = (os.clock() - t0) * 1000
	samples[i] = dt
	t_total = t_total + dt
	if i == 1 or i == 100 or i == 250 or i == 500 or i == 1000 or i == 1500 or i == N then
		io.write(string.format("append #%5d: %8.3f ms   record %5d entries\n",
			i, dt, #client.spool_record))
	end
end

local function pct(list, p)
	local s = {}
	for i = 1, #list do s[i] = list[i] end
	table.sort(s)
	local idx = math.floor(#s * p + 0.5)
	if idx < 1 then idx = 1 end
	if idx > #s then idx = #s end
	return s[idx]
end
local function slice(from, to)
	local out = {}
	for i = from, to do out[#out + 1] = samples[i] end
	return out
end

local first, last = slice(1, 100), slice(N - 99, N)
local p95e, p95f = pct(first, 0.95), pct(last, 0.95)
io.write(string.format("\nn=%d  min %.3f  p50 %.3f  p95 %.3f  p99 %.3f  max %.3f ms\n",
	N, pct(samples, 0), pct(samples, 0.5), pct(samples, 0.95), pct(samples, 0.99), pct(samples, 1.0)))
io.write(string.format("mean %.3f ms   total %.1f ms across %d spooling appends\n", t_total / N, t_total, N))
io.write(string.format("p95 empty(first 100) %.3f ms   p95 full(last 100) %.3f ms   ratio %.1fx\n",
	p95e, p95f, p95f / p95e))
io.write(string.format("sys.save calls %d   entries handed to sys.save %d (%.1f per append)\n",
	save_calls, save_entries, save_entries / N))
-- The count, and NOT a claim about what it means. This line used to end
-- "every entry re-encoded, every time", which was true before the append
-- optimisation and false after: storage.lua encodes only each newly admitted
-- envelope, so the figure is ~1.0 per append while the record holds hundreds.
-- A caption contradicting the number directly above it is read as the finding,
-- because prose outranks a column in a reader's eye.
io.write(string.format("json.encode calls %d (%.1f per append)\n",
	encode_calls, encode_calls / N))
