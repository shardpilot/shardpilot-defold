local compression = require "shardpilot.compression"
local experiment_facts = require "shardpilot.experiment_facts"

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

local function dispatch(config, token, route, payload, callback, compress, before_send)
	if not http or not http.request then
		callback(false, "http_unavailable", false, true, nil, nil, false, "unsent")
		return false
	end
	if not json or not json.encode then
		callback(false, "json_unavailable", false, false, nil, nil, false, "unsent")
		return false
	end

	while true do
		local encoder = route == "/v1/events:batch" and experiment_facts.encode_batch or json.encode
		local ok, encoded = pcall(encoder, payload)
		if not ok then
			callback(false, "json_encode_failed", false, false, nil, nil, false, "unsent")
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
		-- Request-body compression. The body is replaced with the compressed bytes
		-- and the coding declared; `compressed` is reported back on EVERY callback
		-- arm so the client knows whether an encoding refusal it is looking at
		-- could even have been caused by this request. A compression module that
		-- declines — no engine compressor, a sub-threshold body, a body that did
		-- not shrink — leaves this an ordinary uncompressed publish.
		local compressed = false
		if compress then
			local compressed_body = compression.compress(encoded)
			if compressed_body then
				encoded = compressed_body
				compressed = true
				headers[compression.HEADER] = compression.CODING
			end
		end
		local options = {
			timeout = config.publish_timeout_seconds,
		}

		local prepared = payload
		if before_send then prepared = before_send() end
		if before_send and not prepared then
			callback(false, "analytics_delivery_deferred", false, true, nil, nil, false, "unsent")
			return false
		end
		if prepared == payload then
			http.request(trim_slash(config.ingest_url) .. route, "POST", function(_, _, response)
				local status = response and response.status or 0
				if status == 401 then
					callback(false, "unauthorized", true, true, response, nil, compressed, "rejected")
					return
				end
				if status >= 200 and status < 300 then
					callback(true, nil, false, false, response, nil, compressed)
					return
				end
				if status == 0 then
					callback(false, "http_0", false, true, response, nil, compressed)
					return
				end
				if status == 429 then
					callback(false, "transient_429", false, true, response, retry_after_seconds(response), compressed, "rejected")
					return
				end
				if status >= 500 then
					-- Pass the parsed Retry-After through exactly like the 429 branch:
					-- the strict-consent mode-unknown lane answers a whole-batch 503
					-- with `Retry-After: 5`, and the client's deferral must pace
					-- recovery on the server's hint instead of its own jittered
					-- backoff.
					callback(false, "transient_" .. tostring(status), false, true, response, retry_after_seconds(response), compressed)
					return
				end
				callback(false, "http_" .. tostring(status), false, false, response, nil, compressed, status >= 400 and status < 500 and "rejected" or nil)
			end, headers, encoded, options)
			return true
		end
		payload = prepared
	end
end

function M.publish(config, token, payload, callback, compress, before_send)
	return dispatch(config, token, "/v1/events:batch", payload, callback, compress, before_send)
end

function M.send_consent(config, token, payload, callback)
	return dispatch(config, token, "/v1/consent", payload, callback)
end

return M
