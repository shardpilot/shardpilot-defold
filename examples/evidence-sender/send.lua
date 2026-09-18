-- Runs the checked-in SDK; the Python host supplies only JSON, HTTP and time.
local sdk = require "shardpilot.sdk"
local crash = require "shardpilot.crash"

-- One synthetic Lua report, reused by the nonfatal and fatal forms.
local function lua_error()
	return { exception = { type = "lua_error", reason = "Synthetic sender failure" },
		threads = {{ id = "main", crashed = true,
			frames = {{ ["function"] = "sender.update", file = "sender.lua", line = 1 }} }} }
end

return function(c)
	local client = assert(sdk.new({
		ingest_url = c.ingest_url, anonymous_id = c.anonymous_id,
		-- The owner supplies this credential; the example never mints or refreshes it.
		token_provider = function(callback) callback(c.ingest_token, nil, nil) end,
		workspace_id = c.workspace_id, app_id = c.app_id,
		environment_id = c.environment_id, platform = "linux", source = "client",
		batch_size = 100, spool_enabled = false,
		request_compression_enabled = false, publish_timeout_seconds = 15,
		-- The caller's documented view of a per-event rejection: the
		-- diagnostics hook receives every non-accepted row and
		-- get_rejections() keeps the same rows retrievable (docs/configuration.md).
		-- Installing the hook also silences the SDK's default print warnings,
		-- so the hook records are the evidence that the caller was told.
		rejection_capacity = 8,
		diagnostics = function(issue) report_issue(issue) end,
	}))
	assert(client:identify(c.user_id))
	local crashes = assert(crash.new({
		crash_ingest_url = c.crash_url, crash_api_key = c.crash_key,
		app_id = c.crash_app_id, platform = "linux",
		app_version = "synthetic-sender", app_build = "synthetic-build",
		crash_source = "sdk-evidence-sender", sample_every = 1,
		capture_previous_on_boot = false, publish_timeout_seconds = 15,
	}))
	stage("consent")
	assert(client:set_consent(true))
	stage("single")
	assert(client:track(c.event_name, {}))
	assert(client:flush({ include_summaries = false }))
	-- Two synthetic sessions, each with a start and an end, in ONE batch:
	-- session_start resets the per-session sequence, so each session carries
	-- sequence 1 for its start and 2 for its end.
	stage("realistic-batch")
	assert(client:session_start({ entry_point = "synthetic_sender_first" }))
	assert(client:session_end("completed"))
	assert(client:session_start({ entry_point = "synthetic_sender_second" }))
	assert(client:session_end("backgrounded"))
	assert(client:flush({ include_summaries = false }))
	stage("mixed-size")
	assert(client:track(c.event_name, {}))
	assert(client:track(c.event_name, { sample_padding = string.rep("x", 2500) }))
	assert(client:flush({ include_summaries = false }))
	-- What the caller can see, read through the public API rather than
	-- inferred from the response the host already has.
	report_rejections(client:get_rejections())
	-- And what the caller must NOT do: a rejected event is not re-queued, so
	-- this flush publishes nothing and the case keeps its single attempt. A
	-- re-queued event would appear here as a second exchange for the case.
	assert(client:flush({ include_summaries = false }))
	stage("lua-nonfatal")
	assert(crashes:emit(lua_error()))
	stage("lua-fatal")
	assert(crashes:emit_fatal(lua_error()))
	stage("native-json")
	assert(crashes:emit_fatal({
		exception = { type = "SIGSEGV", reason = "Synthetic native frame; no process crash" },
		modules = {{ name = "sender.so", debug_id = "ABC123", load_address = "0x1000", size = "0x2000" }},
		threads = {{ id = "main", crashed = true, frames = {{ instruction_addr = "0x1010" }} }},
	}))
	-- The frameless form: raw_text alone satisfies the SDK's
	-- frames-or-raw_text contract, which is the wire shape a script-error
	-- traceback ships in.
	stage("raw-text")
	assert(crashes:emit_fatal({
		exception = { type = "lua_error", reason = "Synthetic frameless report" },
		raw_text = "stack traceback:\n\tsender.lua:1: in function 'update'",
	}))
	-- A FRESH event whose credential the host removes at the transport seam.
	-- Reusing an accepted event's id would make the run plan's "no facts from
	-- the unauthenticated ID" readback unjudgeable. The SDK's own publish
	-- fails by design here, so the refusal is measured in the exchange
	-- record rather than in flush's return value.
	stage("unauthenticated")
	assert(client:track(c.event_name, { synthetic_admission_probe = true }))
	client:flush({ include_summaries = false })
end
