-- A5's Defold leg: allocation bytes per `track()` and per-call cost.
--
-- WHAT THIS MEASURES, AND WHY IT IS THE METRIC A5 ASKS FOR
-- -------------------------------------------------------
-- A5 wants "allocation bytes per Track()" for the client SDKs, because on a
-- game client the number that hurts is not throughput — it is garbage. A
-- per-frame allocation that survives to the next collection is a GC pause in
-- somebody's frame budget, and it is the one cost an engine integration cannot
-- hide behind a background thread.
--
-- Lua makes that directly observable: `collectgarbage("count")` reports the
-- live heap in kilobytes, so a full collection either side of a measured run
-- gives the bytes that run allocated. That is a REAL measurement of this
-- source, not a model of one.
--
-- WHAT IT DOES NOT MEASURE, stated so the number is not over-read
-- --------------------------------------------------------------
--  * **Not a device measurement.** It runs on a build machine. CI runs it on
--    the whole interpreter matrix — lua5.1, lua5.4 and **luajit**, which is what
--    Defold actually ships — so the LuaJIT column is the one a studio would
--    feel and the reference-interpreter columns are the comparison. Neither is
--    a phone: allocator behaviour under memory pressure is not reproduced here,
--    and the ALLOCATION SHAPE (how many tables one `track()` builds) is what
--    transfers, not the exact byte count.
--  * **Not build-size delta.** A5 asks for that too, and it needs `bob`
--    building the bundle twice; that belongs with `scripts/ci_bob_build.sh`,
--    not here.
--  * **Not per-frame cost in an engine.** Per-call wall time is reported as an
--    indicative figure; a real frame budget needs the engine.
--
-- WHY THERE IS A FLOOR ASSERTION AND NOT A CEILING
-- -----------------------------------------------
-- A ceiling is a regression gate, and it needs a baseline measured on
-- comparable hardware — this runs anywhere. What it asserts instead is that the
-- measurement HAPPENED: a nonzero allocation and a nonzero call count. The
-- failure this guards is the one that keeps recurring in this plan — a harness
-- that measures nothing and reports a clean zero, which reads like the best
-- possible result.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- The Defold engine globals the SDK reaches for, in their smallest honest
-- form. Same shims the test suite installs; kept minimal here because a
-- benchmark that accidentally measures a shim is measuring the wrong thing.
socket = {
	now = 1000,
	gettime = function()
		socket.now = socket.now + 0.001
		return socket.now
	end,
}

sys = {
	get_sys_info = function()
		return { system_name = "Linux" }
	end,
}

-- The transport is a black hole ON PURPOSE. `track()` enqueues; publishing is
-- a separate, asynchronous concern with its own costs, and letting a real
-- serialize-and-send run inside the measured loop would attribute the
-- transport's allocations to `track()`.
http = {
	request = function(_url, _method, callback, _headers, _body, _options)
		callback(nil, nil, { status = 202, response = '{"accepted":1}' })
	end,
}

-- The `json` global, from the SAME encoder the test suite installs.
--
-- ⚠ AND IT IS NOT WHAT FIXED THIS FILE'S NUMBERS — I claimed it was, and
-- measuring it said otherwise. Removing the shim and re-running changes the
-- result by less than a byte per call (916 → 916, 928 → 928, 1290 → 1290),
-- because `track()` ENQUEUES and serialization happens later, at publish, which
-- is outside the measured window by design.
--
-- It stays because the SDK should be in a realistic state while being measured
-- and the publish path errors without it — but as scaffolding, honestly
-- labelled, not as the measurement. The actual defect is recorded at
-- `buffer_size` below, and the reason this comment says all of it is that the
-- first version of this file carried a confident, wrong explanation of its own
-- numbers, which is worse than carrying none.
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

local function config()
	return {
		ingest_url = "http://localhost:8080",
		workspace_id = "workspace-bench",
		app_id = "app-bench",
		environment_id = "develop",
		app_version = "0.1.0",
		app_build = "100",
		token_provider = function(callback)
			callback("client-token-placeholder", nil, nil)
		end,
		flush_interval_seconds = 3600, -- never inside the measured window
		publish_timeout_seconds = 2,
		spool_enabled = false, -- disk I/O is A6's measurement, not this one
		-- A queue big enough that nothing DROPS. THIS is the defect that
		-- produced this file's first, nonsensical table — confirmed by
		-- measurement, after a first diagnosis blamed the json shim and was
		-- wrong.
		--
		-- The default buffer is 1000 and nothing flushes inside the measured
		-- window by design — so at 2000 iterations per case the queue filled
		-- partway through case one and every later call took the drop path.
		-- Allocation then went DOWN as the props got richer (338 → 73 → 26
		-- B/call), which is exactly backwards and exactly what the numbers said.
		-- A refusal is cheaper than the work; a benchmark that silently starts
		-- measuring refusals reports the SDK getting faster the more you ask of
		-- it. Sized above every case plus warm-up, and the per-case gate below
		-- fails if a single event is dropped anyway.
		buffer_size = 50000
	}
end

local ITERATIONS = tonumber(os.getenv("SHARDPILOT_BENCH_ITERATIONS") or "") or 2000

local function fail(message)
	io.stderr:write("FAIL: " .. message .. "\n")
	os.exit(1)
end

--- Bytes allocated by running `body` once per iteration, and seconds per call.
---
--- Two full collections before the baseline, because one leaves finalizable
--- objects behind and the resulting "before" reading is too high — which makes
--- the measured delta too LOW, i.e. flattering.
local function measure(body, iterations)
	collectgarbage("collect")
	collectgarbage("collect")

	local before_kb = collectgarbage("count")
	local started = os.clock()

	for i = 1, iterations do
		body(i)
	end

	local elapsed = os.clock() - started
	local after_kb = collectgarbage("count")

	return (after_kb - before_kb) * 1024, elapsed
end

local ok, err = sdk.init(config())
if not ok then
	fail("sdk.init: " .. tostring(err))
end
-- Consent FIRST. The client SDKs refuse events at enqueue while the decision is
-- undecided or denied — that is the documented consent-first rule, not a
-- configuration detail — so a benchmark that skips it measures the refusal
-- path and reports a very fast, very small `track()`.
if not sdk.set_consent(true) then
	fail("sdk.set_consent(true) returned false")
end
if not sdk.session_start() then
	fail("sdk.session_start returned false")
end

-- Warm the path once: the first call through any Lua module resolves upvalues
-- and grows tables that no later call pays for, and charging that to the
-- per-call average is a lie in the direction of "slower than it is".
for i = 1, 50 do
	sdk.track("bench_warmup", { index = i })
end

local cases = {
	{
		name = "track, no props",
		body = function()
			sdk.track("bench_bare")
		end,
	},
	{
		name = "track, 3 scalar props",
		body = function(i)
			sdk.track("bench_props", { level = i, score = i * 10, mode = "arcade" })
		end,
	},
	{
		name = "track, nested props",
		body = function(i)
			sdk.track("bench_nested", { level = i, loadout = { weapon = "bow", tier = 3 } })
		end,
	},
}

io.write(string.format("shardpilot-defold track() benchmark — %s, %d iterations/case\n",
	_VERSION, ITERATIONS))
io.write(string.rep("-", 72) .. "\n")

--- One counter, read as a NUMBER.
---
--- Two traps, both hit while writing this. The counters are TOP-LEVEL on the
--- snapshot, not under `.stats` — reading `snapshot.stats.enqueued` yields nil,
--- which arithmetic turns into a silent 0 and a permanently failing gate. And
--- `snapshot()` hands back a live reference, so holding the table across the
--- measured loop and diffing it against itself reports 0 for everything, which
--- would have made the gate fail on a correct run and "pass" on nothing.
--- Both are the same mistake in different clothes: the check has to capture a
--- value, not a view.
local function counter(name)
	local snapshot, snapshot_err = sdk.snapshot()
	if type(snapshot) ~= "table" then
		fail("sdk.snapshot: " .. tostring(snapshot_err))
	end
	local value = snapshot[name]
	if type(value) ~= "number" then
		fail(string.format("snapshot has no numeric %q counter — the harness cannot verify that "
			.. "track() did anything, so its numbers mean nothing.", name))
	end

	return value
end

for _, case in ipairs(cases) do
	-- `enqueued`, not `accepted`. `accepted` counts what the SERVER took, and
	-- nothing publishes inside the measured window by design (flush interval
	-- 3600) — so gating on it fails a correct run. `track()`'s own success is
	-- that the event reached the queue.
	local enqueued_before, dropped_before = counter("enqueued"), counter("dropped")
	local bytes, seconds = measure(case.body, ITERATIONS)
	local enqueued = counter("enqueued") - enqueued_before
	local dropped = counter("dropped") - dropped_before
	local bytes_per_call = bytes / ITERATIONS
	local us_per_call = (seconds / ITERATIONS) * 1e6

	io.write(string.format("%-26s %10.1f B/call  %8.2f us/call  enqueued %d/%d\n",
		case.name, bytes_per_call, us_per_call, enqueued, ITERATIONS))

	-- THE ASSERTION, and it checks the SDK's OWN counter rather than the byte
	-- total. "Allocated more than zero" is not evidence: the refusal path
	-- allocates too, which is how the first version of this harness produced a
	-- full table of confident numbers while every event was being dropped. What
	-- proves the loop measured `track()` is that `track()` ACCEPTED the events.
	if enqueued ~= ITERATIONS or dropped ~= 0 then
		fail(string.format(
			"case %q: %d of %d events enqueued, %d dropped (last issue: %s). The measured loop was "
				.. "not doing the work this benchmark claims to measure.",
			case.name, enqueued, ITERATIONS, dropped, "see sdk.snapshot()"))
	end
end

io.write(string.rep("-", 72) .. "\n")
io.write("OK: every case accepted every event — the allocations above are track()'s.\n")
