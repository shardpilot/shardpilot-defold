-- Runs the checked-in SDK; the Python host supplies only JSON, HTTP and time.
local sdk = require "shardpilot.sdk"
local crash = require "shardpilot.crash"

return function(c)
	local client = assert(sdk.new({
		ingest_url = c.ingest_url, api_key = c.ingest_key,
		workspace_id = c.workspace_id, app_id = c.app_id,
		environment_id = c.environment_id, platform = "linux",
		batch_size = 100, spool_enabled = false,
		request_compression_enabled = false, publish_timeout_seconds = 15,
	}))
	local crashes = assert(crash.new({
		crash_ingest_url = c.crash_url, crash_api_key = c.crash_key,
		app_id = c.crash_app_id, platform = "linux",
		app_version = "synthetic-sender", app_build = "synthetic-build",
		crash_source = "sdk-evidence-sender", sample_every = 1,
		capture_previous_on_boot = false, publish_timeout_seconds = 15,
	}))
	stage("consent")
	assert(client:set_consent(true))
	stage("minimal")
	assert(client:screen_view("sender_minimal"))
	assert(client:flush({ include_summaries = false }))
	stage("batch")
	assert(client:session_start())
	assert(client:screen_view("sender_menu"))
	assert(client:track_level_start("sender_level", 1))
	assert(client:track_level_complete("sender_level", 1, 12000, 100))
	assert(client:flush({ include_summaries = false }))
	stage("mixed_size")
	assert(client:screen_view("sender_small"))
	assert(client:screen_view("sender_large", { sample_padding = string.rep("x", 2500) }))
	assert(client:flush({ include_summaries = false }))
	local function lua_error()
		return { exception = { type = "lua_error", reason = "Synthetic sender failure" },
			threads = {{ id = "main", crashed = true,
				frames = {{ ["function"] = "sender.update", file = "sender.lua", line = 1 }} }} }
	end
	stage("lua_nonfatal")
	assert(crashes:emit(lua_error()))
	stage("lua_fatal")
	assert(crashes:emit_fatal(lua_error()))
	stage("native_frame")
	assert(crashes:emit_fatal({
		exception = { type = "SIGSEGV", reason = "Synthetic native frame; no process crash" },
		modules = {{ name = "sender.so", debug_id = "ABC123", load_address = "0x1000" }},
		threads = {{ id = "main", crashed = true, frames = {{ instruction_addr = "0x1010" }} }},
	}))
end
