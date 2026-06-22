-- Public crash-reporting facade for the ShardPilot Defold SDK. Like
-- shardpilot/sdk.lua, it offers a singleton API plus an instance (`crash.new`)
-- for hosts that want to hold the client themselves.
--
-- Crash reports go to a DEDICATED crash ingest endpoint
-- (POST {crash_ingest_url}/api/v1/crashes/ingest) with a `crash:write` API key
-- and the crash report JSON body — they are NEVER wrapped as a `mobile_crash`
-- analytics event. A fatal report is ALWAYS sent (never sampled).
local client_mod = require "shardpilot.crash.client"

local M = {}
local default_client = nil

function M.new(config)
	return client_mod.new(config)
end

function M.init(config)
	local client, err = client_mod.new(config)
	if not client then
		return false, err
	end
	default_client = client
	return true
end

local function default()
	return default_client
end

local function with_default(method, ...)
	local client = default()
	if not client then
		return false, "not_initialized"
	end
	return client[method](client, ...)
end

-- Record a breadcrumb on the singleton client (attached to the next report).
function M.record_breadcrumb(name)
	return with_default("record_breadcrumb", name)
end

-- Emit a non-fatal crash report (subject to sampling).
function M.emit(event)
	return with_default("emit", event)
end

-- Emit a FATAL crash report (never sampled away).
function M.emit_fatal(event)
	return with_default("emit_fatal", event)
end

-- Forward a previous-session native crash dump, if any, as a fatal report.
-- Call this ONCE early in init() so a crash from the prior session is reported
-- on next launch (the Defold auto-capture model — see docs/crash.md).
function M.capture_previous(crash_module)
	return with_default("capture_previous", crash_module)
end

function M.snapshot()
	return with_default("snapshot")
end

function M.shutdown()
	local client = default()
	if not client then
		return false, "not_initialized"
	end
	local ok, err = client:shutdown()
	if ok then
		default_client = nil
	end
	return ok, err
end

return M
