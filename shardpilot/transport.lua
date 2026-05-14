local M = {}

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

function M.publish(config, token, payload, callback)
	if not http or not http.request then
		callback(false, "http_unavailable")
		return false
	end
	if not json or not json.encode then
		callback(false, "json_unavailable")
		return false
	end

	local ok, encoded = pcall(json.encode, payload)
	if not ok then
		callback(false, "json_encode_failed")
		return false
	end

	local headers = {
		["Content-Type"] = "application/json",
		["Authorization"] = "Bearer " .. token,
	}
	local options = {
		timeout = config.publish_timeout_seconds,
	}

	http.request(trim_slash(config.ingest_url) .. "/v1/events:batch", "POST", function(_, _, response)
		local status = response and response.status or 0
		if status == 401 then
			callback(false, "unauthorized", true)
			return
		end
		if status >= 200 and status < 300 then
			callback(true, nil, false, response)
			return
		end
		if status == 429 or status >= 500 then
			callback(false, "transient_" .. tostring(status), false)
			return
		end
		callback(false, "http_" .. tostring(status), false)
	end, headers, encoded, options)
	return true
end

return M
