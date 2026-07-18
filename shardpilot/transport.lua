local M = {}

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

-- The real Defold http API lowercases response header keys; the test mock
-- omits headers entirely. Read the Retry-After header (whole seconds) when
-- present and return it as a non-negative number, otherwise nil.
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

local function dispatch(config, token, route, payload, callback)
	if not http or not http.request then
		callback(false, "http_unavailable", false, true)
		return false
	end
	if not json or not json.encode then
		callback(false, "json_unavailable", false, false)
		return false
	end

	local ok, encoded = pcall(json.encode, payload)
	if not ok then
		callback(false, "json_encode_failed", false, false)
		return false
	end

	-- Dual-mode Bearer: `token` is the resolved Authorization
	-- credential the client already selected — a per-tenant ingest JWT in
	-- Mode B (yielded by token_provider) or the non-secret publishable
	-- `sp_ingest_...` api_key in Mode A. The ingest endpoint accepts both, so
	-- the transport stays mode-agnostic and always sends `Bearer <token>`.
	local headers = {
		["Content-Type"] = "application/json",
		["Authorization"] = "Bearer " .. token,
	}
	local options = {
		timeout = config.publish_timeout_seconds,
	}

	http.request(trim_slash(config.ingest_url) .. route, "POST", function(_, _, response)
		local status = response and response.status or 0
		if status == 401 then
			callback(false, "unauthorized", true, true, response)
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
			-- Pass the parsed Retry-After through exactly like the 429 branch:
			-- the strict-consent mode-unknown lane answers a whole-batch 503
			-- with `Retry-After: 5`, and the client's deferral must pace
			-- recovery on the server's hint instead of its own jittered
			-- backoff.
			callback(false, "transient_" .. tostring(status), false, true, response, retry_after_seconds(response))
			return
		end
		callback(false, "http_" .. tostring(status), false, false, response)
	end, headers, encoded, options)
	return true
end

function M.publish(config, token, payload, callback)
	return dispatch(config, token, "/v1/events:batch", payload, callback)
end

function M.send_consent(config, token, payload, callback)
	return dispatch(config, token, "/v1/consent", payload, callback)
end

return M
