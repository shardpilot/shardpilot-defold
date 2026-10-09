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

local MAX_SCAN_DEPTH = 32

local function skip_space(text, pos)
	local _, stop = text:find("^[ \t\r\n]*", pos)
	return stop + 1
end

local function utf8_codepoint(code)
	if code < 128 then return string.char(code) end
	if code < 2048 then return string.char(192 + math.floor(code / 64), 128 + code % 64) end
	if code < 65536 then return string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64) end
	return string.char(240 + math.floor(code / 262144), 128 + math.floor(code / 4096) % 64, 128 + math.floor(code / 64) % 64, 128 + code % 64)
end

-- Decode keys for comparison while keeping the original JSON spans intact.
local function read_string(text, pos)
	local parts = {}
	pos = pos + 1
	while pos <= #text do
		local c = text:sub(pos, pos)
		if c == '"' then
			return table.concat(parts), pos + 1
		elseif c == "\\" then
			local escape = text:sub(pos + 1, pos + 1)
			if escape == "u" then
				local hex = text:sub(pos + 2, pos + 5)
				if not hex:match("^%x%x%x%x$") then
					return nil
				end
				local code = tonumber(hex, 16)
				pos = pos + 6
				if code >= 0xd800 and code <= 0xdbff then
					if text:sub(pos, pos + 1) ~= "\\u" then return nil end
					local low_hex = text:sub(pos + 2, pos + 5)
					if not low_hex:match("^%x%x%x%x$") then return nil end
					local low = tonumber(low_hex, 16)
					if low < 0xdc00 or low > 0xdfff then return nil end
					code = 0x10000 + (code - 0xd800) * 1024 + low - 0xdc00
					pos = pos + 6
				elseif code >= 0xdc00 and code <= 0xdfff then return nil end
				parts[#parts + 1] = utf8_codepoint(code)
			else
				local simple = {
					n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
					['"'] = '"', ["\\"] = "\\", ["/"] = "/",
				}
				if not simple[escape] then
					return nil
				end
				parts[#parts + 1] = simple[escape]
				pos = pos + 2
			end
		else
			if c:byte() < 32 then return nil end
			parts[#parts + 1] = c
			pos = pos + 1
		end
	end
	return nil
end

local skip_value

-- Skips one complete JSON value and returns the index after it, or nil.
-- `collect`, when given, receives the keys of THIS object (only this one; the
-- recursion below passes nil, so a nested object's names are not folded into
-- its parent's set).
skip_value = function(text, pos, depth, collect)
	if depth > MAX_SCAN_DEPTH then
		return nil
	end
	local c = text:sub(pos, pos)
	if c == '"' then
		local _, after = read_string(text, pos)
		return after
	elseif c == "{" or c == "[" then
		local close = c == "{" and "}" or "]"
		-- Duplicate object keys are ambiguous.
		local seen = c == "{" and {} or nil
		pos = skip_space(text, pos + 1)
		if text:sub(pos, pos) == close then
			return pos + 1
		end
		while true do
			if c == "{" then
				if text:sub(pos, pos) ~= '"' then
					return nil
				end
				local nested_key, after = read_string(text, pos)
				if not after then
					return nil
				end
				if seen[nested_key] then
					return nil
				end
				seen[nested_key] = true
				if collect then
					collect[nested_key] = true
				end
				pos = skip_space(text, after)
				if text:sub(pos, pos) ~= ":" then
					return nil
				end
				pos = skip_space(text, pos + 1)
			end
			local next_pos = skip_value(text, pos, depth + 1)
			if not next_pos then
				return nil
			end
			pos = skip_space(text, next_pos)
			local delimiter = text:sub(pos, pos)
			if delimiter == close then
				return pos + 1
			end
			if delimiter ~= "," then
				return nil
			end
			pos = skip_space(text, pos + 1)
		end
	end
	local _, stop = text:find("^[^,%]}%s]+", pos)
	if not stop then
		return nil
	end
	local token = text:sub(pos, stop)
	if token ~= "true" and token ~= "false" and token ~= "null" then
		local integer = token:match("^%-?(%d+)")
		if not integer or (#integer > 1 and integer:sub(1, 1) == "0") then return nil end
		local rest = token:sub(#integer + (token:sub(1, 1) == "-" and 2 or 1))
		if rest:sub(1, 1) == "." then
			local fraction = rest:match("^%.%d+")
			if not fraction then return nil end
			rest = rest:sub(#fraction + 1)
		end
		if rest ~= "" and not rest:match("^[eE][%+%-]?%d+$") then return nil end
	end
	return stop + 1
end

-- Rename only an unambiguous root key in a durable JSON body.
function M.migrate_component(body)
	if type(body) ~= "string" then return nil end
	local after = skip_value(body, skip_space(body, 1), 0)
	if not after or skip_space(body, after) <= #body then return nil end
	if json and json.decode then
		local ok, value = pcall(json.decode, body)
		if not ok or type(value) ~= "table" then return nil end
	end
	local pos = skip_space(body, 1)
	if body:sub(pos, pos) ~= "{" then return nil end
	pos = skip_space(body, pos + 1)
	local source_start, source_end, component_present
	while body:sub(pos, pos) ~= "}" do
		local start = pos
		local key, key_end = read_string(body, pos)
		if not key_end then return nil end
		pos = skip_space(body, key_end)
		if body:sub(pos, pos) ~= ":" then return nil end
		pos = skip_space(body, pos + 1)
		if key == "source" then
			if body:sub(pos, pos) ~= '"' then return nil end
			local value = read_string(body, pos)
			if not value or not value:match("^[a-z0-9][a-z0-9%-]*$") or #value > 63 then return nil end
			source_start, source_end = start, key_end
		elseif key == "component" then component_present = true end
		pos = skip_value(body, pos, 1)
		if not pos then return nil end
		pos = skip_space(body, pos)
		if body:sub(pos, pos) == "}" then break end
		pos = skip_space(body, pos + 1)
	end
	if not source_start then return body end
	if component_present then return nil end
	return body:sub(1, source_start - 1) .. '"component"' .. body:sub(source_end)
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
