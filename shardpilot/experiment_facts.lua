-- Signed fact fields must survive Lua's numeric decoder unchanged. The engine
-- validates JSON; this bounded walk records value spans and rejects duplicate
-- object members before any decoded value is used for routing or admission.
local M = {}

function M.object(body)
	if type(body) ~= "string" or #body > 65536 or not json or not json.decode then
		return nil
	end
	local ok, decoded = pcall(json.decode, body)
	if not ok or type(decoded) ~= "table" then return nil end
	local pos = 1
	local function whitespace()
		local _, last = body:find("^[ \t\r\n]*", pos)
		pos = last + 1
	end
	local function quoted()
		local first = pos
		assert(body:sub(pos, pos) == '"')
		pos = pos + 1
		while pos <= #body do
			local char = body:sub(pos, pos)
			pos = pos + 1
			if char == '"' then return body:sub(first, pos - 1) end
			if char == "\\" then pos = pos + 1 end
		end
		error("unterminated string")
	end
	local value
	value = function(depth)
		assert(depth <= 16)
		whitespace()
		local first = pos
		local char = body:sub(pos, pos)
		local node = {}
		if char == "{" or char == "[" then
			local object = char == "{"
			local closing = object and "}" or "]"
			node.fields = object and {} or nil
			pos = pos + 1
			whitespace()
			if body:sub(pos, pos) ~= closing then
				while true do
					local key
					if object then
						key = json.decode(quoted())
						assert(type(key) == "string" and node.fields[key] == nil)
						whitespace()
						assert(body:sub(pos, pos) == ":")
						pos = pos + 1
					end
					local child = value(depth + 1)
					if object then node.fields[key] = child end
					whitespace()
					char = body:sub(pos, pos)
					if char == closing then break end
					assert(char == ",")
					pos = pos + 1
					whitespace()
				end
			end
			pos = pos + 1
		elseif char == '"' then
			quoted()
		else
			local token = body:match("^[^,%]} \t\r\n]+", pos)
			assert(token and token ~= "")
			pos = pos + #token
		end
		node.raw = body:sub(first, pos - 1)
		return node
	end
	local parsed, root = pcall(value, 0)
	if not parsed or not root.fields then return nil end
	whitespace()
	if pos <= #body then return nil end
	return decoded, root.fields
end

function M.integer(node, minimum)
	local raw = type(node) == "table" and node.raw or node
	if type(raw) ~= "string" or not raw:match("^%d+$")
		or (#raw > 1 and raw:sub(1, 1) == "0")
		or #raw > 19 or (#raw == 19 and raw > "9223372036854775807")
		or (minimum == 1 and raw == "0") then return nil end
	return raw
end

local fact_fields = {
	workspace_key = true, app_key = true, environment_key = true,
	event_id = true, event_name = true, event_ts = true, props = true,
}
local prop_fields = {
	assignment_key = true, assignment_unit = true, attestation = true,
	experiment_key = true, experiment_version = true, variant_key = true,
	outcome_key = true, outcome_value = true,
}
local function closed(fields, allowed)
	for key in pairs(fields) do if not allowed[key] then return false end end
	return true
end

function M.decode(body, expected)
	local decoded, fields = M.object(body)
	local raw = fields and fields.fact
	local fact = decoded and decoded.fact
	local props = type(fact) == "table" and fact.props or nil
	if not raw or not raw.fields or not closed(raw.fields, fact_fields)
		or not raw.fields.props or not raw.fields.props.fields
		or not closed(raw.fields.props.fields, prop_fields)
		or type(props) ~= "table" or type(decoded.seal) ~= "string"
		or not decoded.seal:match("^sps1%.[%w_%-]+%.[%w_%-]+$")
		or type(fact.event_id) ~= "string" or #fact.event_id ~= 69
		or not fact.event_id:match("^cpx1_[0-9a-f]+$")
		or type(fact.event_ts) ~= "string" or fact.event_ts == ""
		or type(props.assignment_key) ~= "string" or #props.assignment_key ~= 69
		or not props.assignment_key:match("^sfk1_[0-9a-f]+$")
		or props.assignment_unit ~= "client_id"
		or (props.attestation ~= "client_attested" and props.attestation ~= "backend_attested") then
		return nil, "malformed_sealed_fact"
	end
	for _, key in ipairs({ "workspace_key", "app_key", "environment_key", "event_name" }) do
		if type(fact[key]) ~= "string" or fact[key] ~= expected[key] then
			return nil, "sealed_fact_mismatch"
		end
	end
	if props.experiment_key ~= expected.experiment_key or props.variant_key ~= expected.variant_key
		or M.integer(raw.fields.props.fields.experiment_version, 1) ~= expected.version_wire then
		return nil, "sealed_fact_mismatch"
	end
	if fact.event_name == "experiment_outcome" then
		if props.outcome_key ~= expected.outcome_key
			or not raw.fields.props.fields.outcome_value
			or raw.fields.props.fields.outcome_value.raw ~= expected.outcome_value_wire then
			return nil, "sealed_fact_mismatch"
		end
	elseif fact.event_name ~= "experiment_exposure"
		or raw.fields.props.fields.outcome_key or raw.fields.props.fields.outcome_value then
		return nil, "sealed_fact_mismatch"
	end
	return {
		raw = raw.raw, seal = decoded.seal, event_id = fact.event_id,
		event_name = fact.event_name, event_ts = fact.event_ts,
		workspace_key = fact.workspace_key, app_key = fact.app_key,
		environment_key = fact.environment_key, props = props,
	}
end

-- Only unsigned envelope metadata is encoded again. Even the numeric spelling
-- inside props remains the exact one the apply endpoint signed.
function M.encode_event(event)
	if not event.sealed_fact then return json.encode(event) end
	local sealed = event.sealed_fact
	local metadata = { schema_version = 2, source = "client", attestation_seal = sealed.seal }
	for _, key in ipairs({ "anonymous_id", "session_id", "session_sequence", "platform", "app_version", "app_build" }) do
		metadata[key] = event[key]
	end
	return sealed.raw:sub(1, -2) .. "," .. json.encode(metadata):sub(2)
end

function M.encode_batch(payload)
	local events = {}
	for i, event in ipairs(payload.events) do events[i] = M.encode_event(event) end
	return '{"events":[' .. table.concat(events, ",") .. "]}"
end

return M
