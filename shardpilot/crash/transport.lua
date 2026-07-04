-- Crash ingest transport: POSTs a single crash report JSON body to
-- {crash_ingest_url}/api/v1/crashes/ingest with a `crash:write` API key as the
-- Bearer. Distinct from the analytics transport (shardpilot/transport.lua),
-- which batches analytics events to /v1/events:batch — a crash is NEVER wrapped
-- as a `mobile_crash` analytics event.
local M = {}

local crash_ingest_route = "/api/v1/crashes/ingest"

M.route = crash_ingest_route

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

-- Read the Retry-After header (whole seconds) when present; returns a
-- non-negative number or nil. The real Defold http API lowercases header keys.
local function retry_after_seconds(response)
	if type(response) ~= "table" or type(response.headers) ~= "table" then
		return nil
	end
	local value = response.headers["retry-after"] or response.headers["Retry-After"]
	if type(value) == "number" then
		if value < 0 then
			return nil
		end
		return math.floor(value)
	end
	if type(value) ~= "string" then
		return nil
	end
	local seconds = tonumber(value:match("^%s*(%d+)%s*$"))
	if not seconds or seconds < 0 then
		return nil
	end
	return math.floor(seconds)
end

-- Encode one crash report to its wire body. Returns the JSON string, or
-- (nil, error_code) when no encoder is available or encoding fails. Exposed
-- so the client can encode ONCE at capture — the same bytes are then
-- persisted write-ahead and dispatched, and a later resend of the persisted
-- body is byte-identical to the original attempt.
function M.encode(event)
	if not json or not json.encode then
		return nil, "json_unavailable"
	end
	local ok, encoded = pcall(json.encode, event)
	if not ok or type(encoded) ~= "string" then
		return nil, "json_encode_failed"
	end
	return encoded
end

-- Send one crash report (a prepared table; encoded here). The callback
-- signature mirrors the analytics transport:
-- (ok, err, unauthorized, retryable, response, retry_after).
function M.ingest(config, api_key, event, callback)
	local encoded, encode_err = M.encode(event)
	if not encoded then
		callback(false, encode_err, false, false)
		return false
	end
	return M.ingest_body(config, api_key, encoded, callback)
end

-- Send one ALREADY-ENCODED crash report body VERBATIM. The resend path uses
-- this so a persisted report goes out byte-identical to its original
-- attempt; the crash ingest service de-duplicates by the stable crash_id
-- embedded in the body.
function M.ingest_body(config, api_key, encoded, callback)
	if not http or not http.request then
		callback(false, "http_unavailable", false, true)
		return false
	end
	if type(encoded) ~= "string" or encoded == "" then
		callback(false, "json_encode_failed", false, false)
		return false
	end

	local headers = {
		["Content-Type"] = "application/json",
		["Authorization"] = "Bearer " .. api_key,
	}
	local options = {
		timeout = config.publish_timeout_seconds,
	}

	http.request(trim_slash(config.crash_ingest_url) .. crash_ingest_route, "POST", function(_, _, response)
		local status = response and response.status or 0
		if status == 401 or status == 403 then
			callback(false, "unauthorized", true, false, response)
			return
		end
		if status >= 200 and status < 300 then
			callback(true, nil, false, false, response)
			return
		end
		if status == 0 then
			callback(false, "http_0", false, true, response)
			return
		end
		if status == 429 then
			callback(false, "transient_429", false, true, response, retry_after_seconds(response))
			return
		end
		if status >= 500 then
			callback(false, "transient_" .. tostring(status), false, true, response, retry_after_seconds(response))
			return
		end
		callback(false, "http_" .. tostring(status), false, false, response)
	end, headers, encoded, options)
	return true
end

return M
