package.path = "./?.lua;./?/init.lua;" .. package.path

socket = {
	now = 1000,
	gettime = function()
		socket.now = socket.now + 0.1
		return socket.now
	end,
}

sys = {
	get_sys_info = function()
		return { system_name = "Linux" }
	end,
}

local requests = {}
local next_status = 200
local next_response_body = nil
local next_response_headers = nil

http = {
	request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = {
			url = url,
			method = method,
			headers = headers,
			body = body,
			options = options,
		}
		local response = { status = next_status, response = next_response_body }
		if next_response_headers then
			response.headers = next_response_headers
		end
		callback(nil, nil, response)
	end,
}

-- The same minimal JSON encoder/decoder the analytics harness uses. Real
-- Defold ships json.encode/json.decode; the SDK uses them only when present.
local function encode_string(value)
	return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- ⚠ A FIXTURE THAT CANNOT SAY "null" CANNOT BUILD THE CONTRACT'S OWN BODY.
-- Lua has no null and this encoder dropped nil keys, so `signature = nil`
-- produced a body with no signature at all — which is now a refusal, and was
-- the shape that let the suite pass while the fixture and the resolver
-- disagreed about what a plan looks like. NULL is a distinct value the encoder
-- writes as `null` and the key survives.
local NULL = setmetatable({}, { __tostring = function() return "null" end })

local function encode_value(value)
	if value == NULL then
		return "null"
	end
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
				if esc == "u" then
					-- Real Defold json.decode resolves \uXXXX; the harness has
					-- to as well, or a scene about escaped key names would be
					-- testing the harness rather than the module.
					local code = tonumber(string.sub(text, pos + 2, pos + 5), 16)
					parts[#parts + 1] = code and code < 128 and string.char(code) or "?"
					pos = pos + 6
				else
					local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
					parts[#parts + 1] = map[esc] or esc
					pos = pos + 2
				end
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

	local parsed = parse_value()
	skip_ws()
	if pos <= #text then
		error("trailing content")
	end
	return parsed
end

json = {
	encode = encode_value,
	decode = json_decode,
}

local consent_policy = require "shardpilot.consent_policy"

local function assert_true(value, message)
	if not value then
		error(message or "expected true", 2)
	end
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local function reset()
	crash_shutdown_pending = 0
	sdk_init_failures = 0
	sdk_consent_refusals = 0
	sdk_identify_refusals = 0
	requests = {}
	next_status = 200
	next_response_body = nil
	next_response_headers = nil
	-- A test starts a new module session. Ordinary invalidation is a refresh,
	-- and must retain restrictions learned during the existing session.
	package.loaded["shardpilot.consent_policy"] = nil
	consent_policy = require "shardpilot.consent_policy"
end

local function context(overrides)
	local ctx = {
		endpoint = "https://policy.example",
		workspace_key = "ws-synthetic",
		app_key = "app-synthetic",
		environment_key = "env-synthetic",
		app_version = "1.2.3",
		locale = "en",
		platform = "windows",
	}
	for key, value in pairs(overrides or {}) do
		if value == "__nil__" then
			ctx[key] = nil
		else
			ctx[key] = value
		end
	end
	return ctx
end

-- ⚠ THE FIXTURE IS THE RESOLVER'S ACTUAL SHAPE, not this module's idea of it.
-- It was a FLAT plan until a later fix, which is exactly the defect it fixed:
-- the module and the server were written from the same prose and neither ever
-- parsed the other's bytes. Every field, nesting and value here is copied from
-- the golden bodies in test/golden/, which are the handler's own output.
--
-- `flags` MERGES rather than replaces, so a scene can change one restriction
-- without restating the other three.
local NOTICE = "AI draft — owner-confirmed; counsel confirmation pending (Stage B): " ..
	"The consent-policy resolver provides informational reference output based on " ..
	"AI-collected jurisdiction data, not legal advice."

local function plan(overrides)
	local body = {
		regime = consent_policy.STRICT_OPT_IN,
		flags = {
			crash_profile = consent_policy.CRASH_OFF,
			server_analytics = consent_policy.SERVER_ANALYTICS_DENIED,
			child_rules = consent_policy.CHILD_RULES_MINIMISED,
			operation_blocks = {},
		},
		policy_version = "strict-fallback/1",
		consent_text_version = "ff-v1.3",
		presented_language = "en",
		scope = {
			workspace_key = "ws-synthetic",
			app_key = "app-synthetic",
			environment_key = "env-synthetic",
		},
		signals_used = {
			{ name = "server_country", available = false, reason = "not_enabled_in_release" },
			{ name = "store_region", available = false, reason = "source_not_permitted" },
		},
		band_vocabulary = "coarse",
		band_vocabulary_version = "1",
		expires_at = "2099-01-01T00:00:00Z",
		max_age_seconds = 300,
		basis = {
			character = "informational_reference",
			table_provenance = "ai_draft",
			notice = NOTICE,
		},
		-- Present and null, which is what the resolver sends on every response
		-- in this release and the valid unsigned wire shape, still refused for authority.
		signature = NULL,
	}
	for key, value in pairs(overrides or {}) do
		if value == "__nil__" then
			body[key] = nil
		elseif key == "flags" then
			for flag, setting in pairs(value) do
				if setting == "__nil__" then
					body.flags[flag] = nil
				else
					body.flags[flag] = setting
				end
			end
		else
			body[key] = value
		end
	end
	return encode_value(body)
end

-- ⚠ THIS COMMENT USED TO DESCRIBE A DROP THE CODE DID NOT PERFORM. It said
-- the field was removed from the fixture first; the body below only prepended,
-- so every raw_field on a key the fixture already carried built a DUPLICATE
-- and the scene passed on the duplicate rule rather than on the value it meant
-- to test. Both intents are wanted, so both are now named.

-- Splices a field into the fixture as RAW TEXT — the encoder cannot produce an
-- empty object, an escaped key name, or (before the NULL sentinel) a null.
-- REPLACES the fixture's own copy, so the scene is about the value.
local function raw_field(name, raw_value, overrides)
	local merged = {}
	for key, value in pairs(overrides or {}) do
		merged[key] = value
	end
	-- Unescaped names only; an escaped spelling matches no fixture key, drops
	-- nothing, and is therefore a duplicate — which is what those scenes want.
	local plain = name:match('^"([%a_][%w_]*)"$')
	if plain and merged[plain] == nil then
		merged[plain] = "__nil__"
	end
	local body = plan(merged)
	return body:sub(1, 1) .. name .. ":" .. raw_value .. "," .. body:sub(2)
end

-- ⚠ REMOVES ONE TOP-LEVEL KEY FROM RAW JSON TEXT, so the omission scenes can
-- work on the RESOLVER'S OWN BYTES rather than on a fixture that agrees with
-- the module by construction. It walks the document tracking string state and
-- container depth, because a key name also occurs inside the notice text and
-- inside nested objects, and a plain gsub would cut one of those instead.
--
-- If this ever produced malformed text the scenes below would fail rather than
-- pass: they assert the refusal NAMES the omitted key, and unreadable text
-- refuses with a different reason.
-- Locates one member of a JSON object's raw text: the byte the `"key":` pair
-- starts at, and the byte its value ends at. Walks the document tracking
-- string state and container depth, because a name also occurs inside the
-- notice text and inside nested objects, and a plain find would hit one of
-- those instead.
local function member_span(body, name, from, to)
	local needle = '"' .. name .. '":'
	local depth, in_string, escaped = 0, false, false
	local pair_from, value_from
	local index = from
	while index <= to do
		local char = body:sub(index, index)
		if in_string then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				in_string = false
			end
		elseif char == '"' then
			if depth == 1 and not pair_from and body:sub(index, index + #needle - 1) == needle then
				pair_from = index
				value_from = index + #needle
			end
			in_string = true
		elseif char == "{" or char == "[" then
			depth = depth + 1
		elseif char == "}" or char == "]" then
			-- ⚠ TESTED BEFORE THE DECREMENT. The closing brace of the object
			-- being scanned is the end of its LAST member's value, and it is
			-- reached while the walk is still inside — decrementing first made
			-- the last member's span stop one brace short and left a stray
			-- `}` in the text.
			if pair_from and index > value_from and depth == 1 then
				return pair_from, value_from, index - 1, "}"
			end
			depth = depth - 1
		end
		if pair_from and index > value_from and not in_string and depth == 1 and char == "," then
			return pair_from, value_from, index - 1, ","
		end
		index = index + 1
	end
	return nil
end

-- ⚠ REMOVES ONE KEY FROM RAW JSON TEXT, so the omission scenes can work on the
-- RESOLVER'S OWN BYTES rather than on a fixture that agrees with the module by
-- construction. With `parent`, removes a member of that nested object instead.
--
-- If this ever produced malformed text the scenes below would FAIL rather than
-- pass: they assert the refusal NAMES the omitted key, and unreadable text
-- refuses with a different reason.
local function without_key(body, name, parent)
	local from, to = 1, #body
	if parent then
		local _, value_from, value_to = member_span(body, parent, 1, #body)
		assert(value_from, "without_key found no top-level key named " .. parent)
		from, to = value_from, value_to
	end
	local pair_from, _, value_to, closer = member_span(body, name, from, to)
	assert(pair_from, "without_key found no key named " .. name)
	local cut_to = value_to
	if closer == "," then
		cut_to = value_to + 1
	else
		-- ⚠ THE OBJECT'S LAST MEMBER TAKES THE LEADING COMMA WITH IT, AND THE
		-- COMMA NEED NOT BE THE BYTE BEFORE THE KEY. The resolver's wire bytes
		-- are INDENTED, so what precedes a key is a newline and two spaces;
		-- looking only at the previous byte left the comma behind and produced
		-- `…, }`, which is not JSON. The scenes caught it by refusing with
		-- "not readable" instead of naming the key, which is the failure
		-- direction this helper is built for.
		local back = pair_from - 1
		while back > 1 and body:sub(back, back):match("[ \t\r\n]") do
			back = back - 1
		end
		if body:sub(back, back) == "," then
			pair_from = back
		end
	end
	return body:sub(1, pair_from - 1) .. body:sub(cut_to + 1)
end

-- Every member name of a JSON object's raw text, in the order it was sent.
-- The omission scenes are driven from THIS rather than from a roster typed
-- into the suite: a roster here is a second copy of the contract, and the
-- whole defect being repaired is a second copy of the contract drifting from
-- the first. A key the resolver starts sending is covered the day its golden
-- body is refreshed.
local function member_names(body, parent)
	local from, to = 1, #body
	if parent then
		local _, value_from, value_to = member_span(body, parent, 1, #body)
		assert(value_from, "member_names found no top-level key named " .. parent)
		from, to = value_from, value_to
	end
	local names = {}
	local depth, in_string, escaped, key_from = 0, false, false, nil
	local index = from
	while index <= to do
		local char = body:sub(index, index)
		if in_string then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				in_string = false
				-- A NAME is a depth-1 string followed by a colon; a depth-1
				-- string followed by anything else is a value.
				if depth == 1 and key_from and body:sub(index + 1, index + 1) == ":" then
					names[#names + 1] = body:sub(key_from, index - 1)
				end
				key_from = nil
			end
		elseif char == '"' then
			in_string = true
			if depth == 1 then
				key_from = index + 1
			end
		elseif char == "{" or char == "[" then
			depth = depth + 1
		elseif char == "}" or char == "]" then
			depth = depth - 1
		end
		index = index + 1
	end
	return names
end

-- Splices a SECOND copy of a field in, leaving the fixture's own. For the
-- scenes whose subject IS the duplicate.
local function duplicate_field(name, raw_value, overrides)
	local body = plan(overrides)
	return body:sub(1, 1) .. name .. ":" .. raw_value .. "," .. body:sub(2)
end

-- ⚠ THE RESOLVER'S ACTUAL BYTES. Not a fixture of this repository's making:
-- test/golden/ holds the handler's output, produced by running the server's
-- own constructors at a pinned commit (see test/golden/README.md). The fixture
-- above is written to match them; these are what says whether it still does.
-- ⚠ COMPACTION WITHOUT A JSON LIBRARY, ON PURPOSE. This removes insignificant
-- whitespace and NOTHING ELSE: bytes inside strings are copied through, so key
-- ORDER, number spelling, escape spelling and the notice's own characters
-- cannot move. A round trip through a decoder and an encoder would prove only
-- that the two documents mean the same thing, which is the weaker claim and
-- the one that let this SDK and the resolver disagree in the first place.
local function compact_json(text)
	local out, in_string, escaped = {}, false, false
	for index = 1, #text do
		local char = text:sub(index, index)
		if in_string then
			out[#out + 1] = char
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				in_string = false
			end
		elseif char == '"' then
			in_string = true
			out[#out + 1] = char
		elseif not char:match("[ \t\r\n]") then
			out[#out + 1] = char
		end
	end
	return table.concat(out)
end

-- The resolver repository stores each response RE-INDENTED so a human notices
-- a diff; indentation is the only transformation it applies, and it applies it
-- to both sides of its own comparison. Both forms are vendored here so the
-- relation between them is PROVED by a scene rather than asserted in prose.
local function golden_indented(name)
	local file = assert(io.open("test/golden/consent-policy-" .. name .. ".indented.json"),
		"the indented review forms must be present")
	local body = file:read("*a")
	file:close()
	return body
end

local function golden(name)
	local file = assert(io.open("test/golden/consent-policy-" .. name .. ".json"),
		"the golden bodies must be present")
	local body = file:read("*a")
	file:close()
	return body
end

-- The request the golden RESOLVED body answers, field for field, so a scene is
-- genuinely in scope for it rather than approximately.
local function golden_context()
	return context({
		workspace_key = "ws_1",
		app_key = "app_1",
		environment_key = "env_1",
		app_version = "1.2.3",
		store = "steam",
		locale = "en-GB",
		platform = "windows",
	})
end

local function prepare(ctx)
	local got
	local calls = 0
	consent_policy.prepare(ctx or context(), function(decision)
		calls = calls + 1
		got = decision
	end)
	return got, calls
end

-- The control: without it, every refusal below would be satisfied by a module
-- that refuses everything.
-- A positive shape control must reach the authentication boundary, not merely fall back.
local function assert_unsigned(decision, label)
	assert_true(not decision.plan_used, label)
	assert_equal(decision.reason, "plan_unsigned", label)
	assert_true(decision.operation_blocks == nil, "an unsigned plan supplies no block authority")
end

local function test_no_unauthenticated_plan_has_authority()
	local cases = {
		{ "unsigned strict", {} },
		{ "unsigned soft", { regime = consent_policy.SOFT_OPT_OUT } },
		{ "unsigned unknown", { regime = consent_policy.UNKNOWN } },
		{ "unsigned empty blocks", { flags = { operation_blocks = {} } } },
		{ "unsigned blocks", { flags = { operation_blocks = { "transfer_review" } } } },
		{ "missing signature", { signature = "__nil__" } },
		{ "empty signature", { signature = "" } },
		{ "unverifiable signature", { signature = "ed25519:synthetic" } },
		{ "unknown signing key", { signature = "unknown-key:synthetic" } },
	}
	for _, case in ipairs(cases) do
		reset()
		next_response_body = plan(case[2])
		local decision, calls = prepare()
		assert_equal(calls, 1, case[1] .. " settles once")
		assert_equal(#requests, 1, case[1] .. " reaches the response gate")
		assert_true(not decision.plan_used, case[1] .. " must not be used")
		assert_equal(decision.regime, consent_policy.STRICT_OPT_IN, case[1])
		assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF, case[1])
		assert_true(decision.explicit_grant_required, case[1])
		assert_equal(decision.crash_profile, consent_policy.CRASH_OFF, case[1])
		assert_equal(decision.server_analytics, consent_policy.SERVER_ANALYTICS_DENIED, case[1])
		assert_equal(decision.child_rules, consent_policy.CHILD_RULES_MINIMISED, case[1])
		assert_true(decision.operation_blocks == nil, case[1] .. " cannot authenticate an empty block set")
		assert_equal(decision.operation_blocks_source, "none", case[1])
		assert_true(decision.advisory == nil and decision.valid_for_seconds == nil, case[1])
		if case[2].signature == nil then
			assert_equal(decision.reason, "plan_unsigned", case[1] .. " reaches the authentication refusal")
		end
	end
end

local function test_a_well_formed_unsigned_plan_is_unused()
	reset()
	next_response_body = plan()
	local decision, calls = prepare()
	assert_equal(calls, 1, "exactly one callback")
	assert_unsigned(decision, "a valid shape must reach the unsigned refusal: " .. tostring(decision.reason))
	assert_equal(decision.regime, consent_policy.STRICT_OPT_IN)
	assert_true(decision.analytics_choice_default == consent_policy.CHOICE_DEFAULT_OFF, "STRICT closes optional processing on this verdict alone")
	assert_equal(#requests, 1, "one request")
	assert_true(requests[1].url:find("/api/cp/v1/consent/policy", 1, true) ~= nil, "the published route")
end

-- ⚠ RULE (a): NO SINGLETON, NO IDENTITY, NO DISK. Asserted against the SOURCE
-- and against behaviour: a require of the SDK's storage would create the
-- persisted scope record, and a require of its id module would mint an
-- anonymous identifier — before the player has chosen anything.
local function test_the_module_touches_no_sdk_state()
	local source = io.open("shardpilot/consent_policy.lua"):read("*a")
	for _, forbidden in ipairs({
		'require "shardpilot.sdk"', 'require "shardpilot.client"', 'require "shardpilot.storage"',
		'require "shardpilot.id"', 'require "shardpilot.queue"', 'require "shardpilot.crash"',
	}) do
		assert_true(source:find(forbidden, 1, true) == nil,
			"consent_policy must not " .. forbidden .. ": policy selection is not processing admission")
	end
	-- And it writes nothing: sys.save is the only durable path this SDK has.
	local saves = 0
	local saved = sys.save
	sys.save = function(...)
		saves = saves + 1
		return saved and saved(...)
	end
	reset()
	next_response_body = plan()
	prepare()
	sys.save = saved
	assert_equal(saves, 0, "prepare wrote to disk")
end


local function test_an_outage_after_an_unsigned_plan_stays_closed()
	reset()
	next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT })
	assert_unsigned(prepare(), "unsigned SOFT is unused before the outage")
	consent_policy.invalidate()
	next_status = 500
	next_response_body = encode_value({ reason = "policy_unavailable" })
	local second = prepare()
	assert_equal(second.reason, "policy_unavailable")
	assert_equal(second.regime, consent_policy.STRICT_OPT_IN)
	assert_equal(second.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF)
	assert_equal(second.crash_profile, consent_policy.CRASH_OFF)
	assert_true(second.operation_blocks == nil, "an outage cannot establish restrictions")
end

-- ⚠ RULE (c): ONE CALLBACK, EVER, AND A LATE RESPONSE IS DROPPED. A response
-- that arrives after the total deadline cannot change a screen that has
-- already been presented.
local function test_a_late_response_is_dropped()
	reset()
	next_response_body = plan()
	local decisions = {}
	-- The fake transport answers synchronously; advancing the clock inside the
	-- callback is what makes the arrival "late" without a real timer.
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		socket.now = socket.now + 10 -- past the two-second total deadline
		callback(nil, nil, { status = 200, response = next_response_body })
	end
	consent_policy.prepare(context(), function(decision)
		decisions[#decisions + 1] = decision
	end)
	http.request = saved_request
	assert_equal(#decisions, 1, "exactly one callback")
	assert_equal(decisions[1].reason, "deadline_exceeded", "a late response takes the strict path")
	assert_equal(decisions[1].analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
		"and the choice defaults off")
end

-- ⚠ RULE (d): A REFUSED LOCAL VALUE NEVER REACHES THE WIRE. Refusing a
-- non-null store_region only after sending it would have told a server a
-- country claim about this player, which is the point of refusing it.
local function test_a_refused_value_costs_no_request()
	reset()
	next_response_body = plan()
	local decision, calls = prepare(context({ store_region = "DE" }))
	assert_equal(calls, 1, "exactly one callback")
	assert_equal(#requests, 0, "a refused store_region must cost ZERO requests")
	assert_equal(decision.reason, "invalid_request")
	assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")

	-- The other closed vocabularies behave the same way.
	for _, override in ipairs({
		{ platform = "toaster" }, { store = "epic" }, { app_version = "1 2 3" },
		{ locale = string.rep("x", 36) }, { workspace_key = "__nil__" },
		{ age_band = { vocabulary = "v1" } },
	}) do
		reset()
		local refused = prepare(context(override))
		assert_equal(#requests, 0, "a refused context must cost zero requests")
		assert_equal(refused.reason, "invalid_request")
	end

	-- And the control: a well-formed context DOES reach the wire, or the
	-- assertions above would pass on a module that never sends anything.
	reset()
	next_response_body = plan()
	prepare(context({ store = "steam", age_band = { vocabulary = "coarse.v1", band = "adult" } }))
	assert_equal(#requests, 1, "a valid context must be sent")
	assert_true(requests[1].body:find("store_region", 1, true) == nil, "store_region never travels")
end

-- Every malformed plan resolves to STRICT with optional processing closed.
local function test_every_malformed_plan_is_strict()
	local cases = {
		{ "unknown regime", plan({ regime = "PERMISSIVE" }) },
		{ "unknown crash profile", plan({ flags = { crash_profile = "EVERYTHING" } }) },
		{ "unknown server analytics", plan({ flags = { server_analytics = "MAYBE" } }) },
		{ "another app's scope", plan({ scope = { workspace_key = "ws-synthetic", app_key = "other", environment_key = "env-synthetic" } }) },
		{ "no expiry", plan({ expires_at = "__nil__" }) },
		{ "version outside its characters", plan({ policy_version = "2026 09 12" }) },
		{ "unavailable signal with no reason", plan({ signals_used = { { name = "server_country", available = false } } }) },
		{ "a signature this build cannot verify", plan({ signature = "ed25519:synthetic" }) },
		{ "not an object", "[]" },
		{ "not json at all", "regime=STRICT" },
	}
	for _, case in ipairs(cases) do
		reset()
		next_response_body = case[2]
		local decision = prepare()
		assert_equal(decision.reason, "invalid_response", case[1] .. " must not report a used plan")
		assert_equal(decision.regime, consent_policy.STRICT_OPT_IN, case[1] .. " must be STRICT")
		assert_true(decision.analytics_choice_default == consent_policy.CHOICE_DEFAULT_OFF, case[1] .. " must close optional processing")
		assert_equal(decision.child_rules, consent_policy.CHILD_RULES_MINIMISED,
			case[1] .. " must keep the child rules minimised")
	end
end

-- UNKNOWN is a valid wire regime and is still unauthenticated.
local function test_unknown_closes_optional_processing()
	reset()
	next_response_body = plan({ regime = consent_policy.UNKNOWN })
	local decision = prepare()
	assert_unsigned(decision, "unsigned UNKNOWN reaches the authentication boundary")
	assert_true(decision.analytics_choice_default == consent_policy.CHOICE_DEFAULT_OFF, "UNKNOWN closes optional processing")
end


local function test_unsigned_responses_are_never_cached()
	for _, regime in ipairs({ consent_policy.STRICT_OPT_IN, consent_policy.SOFT_OPT_OUT, consent_policy.UNKNOWN }) do
		reset()
		next_response_body = plan({ regime = regime })
		assert_unsigned(prepare(), regime)
		assert_unsigned(prepare(), regime)
		assert_equal(#requests, 2, "an unsigned response is never cached")
		consent_policy.invalidate()
		assert_unsigned(prepare(), regime)
		assert_equal(#requests, 3)
	end
end


local function test_expiry_is_validated_before_authentication()
	for _, stamp in ipairs({ "1970-01-01T00:00:00Z", "2099-13-01T00:00:00Z" }) do
		reset()
		next_response_body = plan({ expires_at = stamp })
		assert_equal(prepare().reason, "invalid_response", "invalid expiry fails before authentication")
	end
	for _, lifetime in ipairs({ 0, 1, 300 }) do
		reset()
		next_response_body = plan({ max_age_seconds = lifetime, expires_at = "2099-01-01T00:00:00+02:00" })
		assert_unsigned(prepare(), "a fresh timestamp parses but supplies no authority")
		assert_unsigned(prepare(), "a lifetime does not authenticate the response")
		assert_equal(#requests, 2)
	end
end


-- ⚠ AN INVALIDATED REQUEST CANNOT ANSWER. Clearing the cache alone left the
-- in-flight request free to complete inside its deadline, deliver the stale
-- decision and write it back — the named trigger undone by the very request
-- it fired against.
local function test_an_invalidated_request_cannot_answer()
	reset()
	next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT })
	local decisions = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url, method = method, headers = headers, body = body, options = options }
		consent_policy.invalidate() -- a policy revocation, mid-flight
		callback(nil, nil, { status = 200, response = next_response_body })
	end
	consent_policy.prepare(context(), function(decision)
		decisions[#decisions + 1] = decision
	end)
	http.request = saved_request
	assert_equal(#decisions, 1, "exactly one callback")
	assert_equal(decisions[1].reason, "invalidated", "an invalidated request takes the strict path")
	assert_true(not decisions[1].plan_used, "it must not deliver the plan it was carrying")
	assert_equal(decisions[1].analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
		"and the choice defaults off")

	-- And the cache must still be empty: repopulating it was the defect.
	next_response_body = plan()
	local after = prepare()
	assert_equal(#requests, 2, "the invalidated response must not have repopulated the cache")
	assert_equal(after.regime, consent_policy.STRICT_OPT_IN, "and the fresh resolution stands")
end

-- ⚠ A JSON OBJECT IS NOT AN EMPTY LIST. It decodes to a Lua table of length
-- zero over which ipairs yields nothing, so a roster of operation blocks
-- supplied as an object read as "no blocks" — a malformed plan wearing a
-- permissive one's clothes.
local function test_a_json_object_is_not_an_empty_list()
	for _, case in ipairs({
		{ "operation_blocks", plan({ flags = { operation_blocks = { policy_selection = "blocked" } } }) },

		{ "signals_used", plan({ signals_used = { server_country = "absent" } }) },
	}) do
		reset()
		next_response_body = case[2]
		local decision = prepare()
		assert_equal(decision.reason, "invalid_response",
			case[1] .. " supplied as an object must not read as an empty list")
		assert_true(decision.analytics_choice_default == consent_policy.CHOICE_DEFAULT_OFF, case[1] .. " must close optional processing")
	end

	-- The control: a genuine array of the same fields is still accepted, or
	-- the refusals above would pass on a module that refuses both shapes.
	reset()
	next_response_body = plan({ flags = { operation_blocks = { "profiling" } } })
	local accepted = prepare()
	assert_unsigned(accepted, "a genuine array must still be accepted: " .. tostring(accepted.reason))
	assert_true(accepted.operation_blocks == nil, "unverified restrictions are not carried through")
end


-- ⚠ THE ENDPOINT IS PART OF THE CONTEXT CONTRACT. An absent one was
-- concatenated with the route and raised a Lua error out of prepare, so the
-- single callback this module promises never arrived and the caller had
-- nothing to fail closed on.
local function test_an_invalid_endpoint_is_an_invalid_request()
	for _, override in ipairs({
		{ endpoint = "__nil__" }, { endpoint = 8080 }, { endpoint = "policy.example" },
		{ endpoint = "https://" .. string.rep("h", 300) },
		-- ⚠ PLAIN http OFF LOOPBACK. The request carries this app's scope and
		-- this player's locale and age band; in the clear to a remote host is
		-- not a development convenience.
		{ endpoint = "http://policy.example" },
		{ endpoint = "http://198.51.100.7:8082" },
		-- The rest of the SDK's URL rule, which the copied predicate brings
		-- with it: no userinfo, no query, no fragment, no path.
		{ endpoint = "https://user@policy.example" },
		{ endpoint = "https://policy.example?a=1" },
		{ endpoint = "https://policy.example#f" },
		{ endpoint = "https://policy.example/v2" },
	}) do
		reset()
		next_response_body = plan()
		local decision, calls = prepare(context(override))
		assert_equal(calls, 1, "exactly one callback, even for a malformed endpoint")
		assert_equal(#requests, 0, "a refused endpoint must cost zero requests")
		assert_equal(decision.reason, "invalid_request")
		assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")
	end

	-- The controls: https anywhere, http on loopback, and a single trailing
	-- slash accepted and trimmed rather than refused — the SAME verdicts the
	-- SDK gives ingest_url and crash_ingest_url, which is the point of copying
	-- its predicate instead of writing a second opinion.
	for _, endpoint in ipairs({
		"https://policy.example", "https://policy.example/", "https://policy.example:8443",
		"http://localhost:8082", "http://127.0.0.1:8082", "http://[::1]:8082",
	}) do
		reset()
		next_response_body = plan()
		local decision = prepare(context({ endpoint = endpoint }))
		assert_unsigned(decision, endpoint .. " must be accepted: " .. tostring(decision.reason))
		assert_equal(#requests, 1, endpoint .. " must reach the wire")
		assert_true(requests[1].url:find("//api/cp", 1, true) == nil,
			"a trailing slash must be trimmed, not doubled: " .. requests[1].url)
	end
end

-- ⚠ THE URL PREDICATE IS A COPY, AND A COPY THAT DRIFTS IS WORSE THAN NO
-- SHARING AT ALL. consent_policy cannot require shardpilot.client — that would
-- pull in storage and id, creating the persisted scope record and minting an
-- anonymous identifier before the player has chosen anything — so the rule is
-- duplicated on purpose. This asserts the duplicate is still byte-for-byte the
-- original.
--
-- HONEST LIMIT: it compares TEXT. It catches the copy falling behind an edit to
-- client.lua; it cannot catch a divergence introduced somewhere else in either
-- module.
local function test_the_url_predicate_is_a_verbatim_copy()
	local client = io.open("shardpilot/client.lua"):read("*a")
	local policy = io.open("shardpilot/consent_policy.lua"):read("*a")
	local first = client:find("local function local_http_host(host)", 1, true)
	local last = client:find("local max_snapshot_depth = 4", 1, true)
	assert_true(first ~= nil and last ~= nil and last > first,
		"client.lua no longer has the predicate this copy was taken from")
	local original = client:sub(first, last - 1):gsub("%s+$", "")
	assert_true(policy:find(original, 1, true) ~= nil,
		"consent_policy.lua no longer carries client.lua's URL predicate verbatim; " ..
		"re-copy it rather than letting the two rules drift")
end

-- ⚠ available IS A BOOLEAN OR THE PLAN IS MALFORMED. `available ~= true`
-- folded a string, a number and an absent key into "unavailable" — an answer
-- the resolver never gave, written into the provenance record as though it had.
local function test_a_signal_must_state_its_availability_as_a_boolean()
	for _, signal in ipairs({
		{ name = "server_country", reason = "not_enabled_in_release" },
		{ name = "server_country", available = "false", reason = "not_enabled_in_release" },
		{ name = "server_country", available = 0, reason = "not_enabled_in_release" },
		{ name = "server_country", available = "true" },
	}) do
		reset()
		next_response_body = plan({ signals_used = { signal } })
		local decision = prepare()
		assert_equal(decision.reason, "invalid_response", "a signal that does not state a boolean must not be used")
		assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")
	end

	-- The controls: a stated false WITH a reason and a stated true WITHOUT one
	-- both parse, or the rule would be satisfied by a parser that refuses every
	-- signal.
	reset()
	next_response_body = plan({ signals_used = { { name = "server_country", available = false, reason = "source_unavailable" } } })
	assert_unsigned(prepare(), "a stated false with a reason must parse")
	reset()
	next_response_body = plan({ signals_used = { { name = "server_country", available = true } } })
	assert_unsigned(prepare(), "a stated true must parse")
end


local function test_fallback_decisions_are_independent()
	reset()
	next_response_body = plan()
	local first = prepare()
	first.regime = "PERMISSIVE"
	first.analytics_choice_default = consent_policy.CHOICE_DEFAULT_ON
	first.child_rules = "unrestricted"
	first.operation_blocks = {}
	first.plan_used = true
	local second = prepare()
	assert_unsigned(second, "a caller cannot rewrite the next fallback")
	assert_equal(second.regime, consent_policy.STRICT_OPT_IN)
	assert_equal(second.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF)
	assert_equal(second.child_rules, consent_policy.CHILD_RULES_MINIMISED)
end

-- ⚠ AN EMPTY SIGNATURE IS STILL A SIGNATURE. Treating "" as absence is a
-- downgrade path: a signed response whose signature failed to serialise would
-- have been admitted by a build that cannot verify signatures at all.
local function test_an_empty_signature_is_still_a_signature()
	reset()
	next_response_body = plan({ signature = "" })
	local decision = prepare()
	assert_equal(decision.reason, "invalid_response", "an empty signature is not an absent one")
	assert_equal(decision.regime, consent_policy.STRICT_OPT_IN, "it takes the strict path")
	assert_true(decision.analytics_choice_default == consent_policy.CHOICE_DEFAULT_OFF, "and closes optional processing")
end

-- ⚠ THE PUBLISHED EXAMPLE IS PART OF THE CONTRACT, AND IT IS RUN HERE RATHER
-- THAN READ. An earlier cut logged the regime and then called set_consent(true),
-- started a session and initialised default-on crash reporting regardless —
-- "we asked, and then ignored the answer". The example is the integration path
-- users copy, so the branches are exercised headlessly: the SDK modules are
-- replaced in package.loaded and the chunk is loaded, which defines init().
-- `between` runs after init() and before update(), i.e. while the notice is
-- still on screen. `window_events` are fired after update().
-- When set, the fake crash client reports shutdown as still pending this many
-- times before succeeding — the real one does exactly that while a POST is in
-- flight (crash/client.lua:1175-1188).
local crash_shutdown_pending = 0
-- The real SDK returns false, err from init (a bad config) and from
-- set_consent (a full or unwritable consent outbox); the fakes do too, on
-- demand, because the example is supposed to notice.
local sdk_init_failures = 0
local sdk_consent_refusals = 0
local sdk_identify_refusals = 0

-- `opts.age_band` and `opts.answer` replace the example's two GLOBAL
-- placeholders after the chunk loads. They are globals in the example for
-- exactly this reason: a host replaces them with its own age step and its own
-- screen, and without replacing them here the granted path is unreachable and
-- the age rule untestable.
local function run_example(between, window_events, dts, finalize, opts)
	local seen = {}
	local function record(name)
		return function(...)
			seen[#seen + 1] = name
			return ...
		end
	end
	local saved = {}
	for _, name in ipairs({ "shardpilot.sdk", "shardpilot.crash", "shardpilot.platform" }) do
		saved[name] = package.loaded[name]
	end
	package.loaded["shardpilot.sdk"] = {
		init = function()
			seen[#seen + 1] = "sdk.init"
			if sdk_init_failures > 0 then
				sdk_init_failures = sdk_init_failures - 1
				return false, "ingest_url_required"
			end
			return true
		end,
		identify = function()
			seen[#seen + 1] = "sdk.identify"
			if sdk_identify_refusals > 0 then
				sdk_identify_refusals = sdk_identify_refusals - 1
				return false, "events_pending"
			end
			return true
		end,
		set_consent = function(value, notice)
			if opts and opts.on_consent then opts.on_consent(value, notice) end
			seen[#seen + 1] = "sdk.set_consent:" .. tostring(value)
			if sdk_consent_refusals > 0 then
				sdk_consent_refusals = sdk_consent_refusals - 1
				return false, "consent_outbox_full"
			end
			return true
		end,
		session_start = record("sdk.session_start"),
		fetch_remote_config = function(callback)
			seen[#seen + 1] = "sdk.fetch_remote_config"
			callback({ ok = true })
		end,
		remote_config_number = function(_, default)
			return default
		end,
		update = function() end,
		persist = function() end,
		on_window_event = function(event)
			seen[#seen + 1] = "sdk.on_window_event:" .. tostring(event)
			return true
		end,
		shutdown = function(reason)
			seen[#seen + 1] = "sdk.shutdown:" .. tostring(reason)
			return true
		end,
	}
	package.loaded["shardpilot.crash"] = {
		init = function()
			seen[#seen + 1] = "crash.init"
			return true
		end,
		set_enabled = function(enabled)
			seen[#seen + 1] = "crash.set_enabled:" .. tostring(enabled)
		end,
		shutdown = function()
			if crash_shutdown_pending > 0 then
				crash_shutdown_pending = crash_shutdown_pending - 1
				seen[#seen + 1] = "crash.shutdown:pending"
				return false, "pending"
			end
			seen[#seen + 1] = "crash.shutdown"
			return true
		end,
	}
	local saved_window = window
	window = {
		WINDOW_EVENT_ICONFIED = "iconified",
		WINDOW_EVENT_FOCUS_LOST = "focus_lost",
		WINDOW_EVENT_FOCUS_GAINED = "focus_gained",
		set_listener = function(listener)
			window.listener = listener
		end,
	}
	package.loaded["shardpilot.platform"] = { detect = function() return "windows" end }

	-- The example's own print() is the only place it reports the decision, so
	-- it is captured rather than left on stdout: it is what tells this scene
	-- the refusal reason, not merely that the branches were taken.
	local saved_print = print
	print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(i, ...)))
		end
		seen[#seen + 1] = "print:" .. table.concat(parts, " ")
	end

	-- ⚠ TWO SNAPSHOTS, BECAUSE THE ORDERING IS THE PROPERTY. The example's
	-- placeholder notice answers from update(), so what happened by the end of
	-- init() is exactly "everything that ran BEFORE the player's final choice".
	local after_init, after_update
	local ok, err = pcall(function()
		local chunk = assert(loadfile("examples/minimal/main.script"))
		chunk()
		opts = opts or {}
		if opts.age_bands then
			-- ⚠ A BAND THAT CHANGES BETWEEN READS, which a constant cannot
			-- express: the property under test is that the example asks the
			-- HOST again after the notice closes rather than reusing the
			-- reading it took before the screen opened. Entries are consumed
			-- one per call; the last one holds. "__nil__" is an unknown band,
			-- because a nil in a Lua list is a hole and not a value.
			local bands = opts.age_bands
			local reads = 0
			host_age_band = function()
				reads = reads + 1
				local band = bands[reads] or bands[#bands]
				if band == "__nil__" then
					return nil
				end
				return band
			end
		elseif opts.age_band ~= nil then
			local band = opts.age_band
			host_age_band = function()
				return band
			end
		end
		-- The notice is ALWAYS wrapped, so a scene can see the default the
		-- screen would open with; only the ANSWER is overridden, and only when
		-- a scene supplies one — otherwise the example's own placeholder
		-- answers with the regime default, which is what an untouched screen
		-- does.
		local deliver = present_consent_notice
		local answer = opts.answer
		-- ⚠ A DIFFERENT ANSWER PER SCREEN, which a single value cannot express.
		-- Proving that a SECOND notice's answer is the one recorded needs the
		-- two answers to differ: with both set to true, a scene cannot tell the
		-- new answer from the stale one being reused.
		local answers, presented = opts.answers, 0
		present_consent_notice = function(decision, callback)
			presented = presented + 1
			local this_answer = answer
			if answers then
				this_answer = answers[presented]
				if this_answer == "__untouched__" then
					this_answer = nil
				end
			end
			seen[#seen + 1] = "notice:default=" .. tostring(decision.analytics_choice_default)
			if opts.before_notice_answer then opts.before_notice_answer() end
			deliver(decision, function(default_answer)
				if this_answer == nil then
					callback(default_answer)
				else
					callback(this_answer)
				end
			end)
		end
		init(nil)
		after_init = table.concat(seen, " | ")
		if between then
			between()
		end
		update(nil, 0)
		after_update = table.concat(seen, " | ")
		for _, event in ipairs(window_events or {}) do
			window.listener(nil, event, nil)
			update(nil, 0)
		end
		for _, dt in ipairs(dts or {}) do
			update(nil, dt)
		end
		if finalize then
			final(nil)
		end
		after_update = table.concat(seen, " | ")
	end)
	window = saved_window

	print = saved_print
	for _, name in ipairs({ "shardpilot.sdk", "shardpilot.crash", "shardpilot.platform" }) do
		package.loaded[name] = saved[name]
	end
	assert_true(ok, "the example must run: " .. tostring(err))
	return after_update, after_init
end

-- The example's own context, so the fixture's plan is IN SCOPE for it. Without
-- this every scene below would be reading a scope-mismatch fallback and would
-- pass for the wrong reason — which is what the first draft did.
local function example_plan(overrides)
	local body = overrides or {}
	body.scope = {
		workspace_key = "workspace-example",
		app_key = "app-example",
		environment_key = "develop",
	}
	return plan(body)
end


-- Unknown operation restrictions close the quick start, even for an adult willing to grant.
local function test_example_stays_closed_without_authenticated_restrictions()
	for _, overrides in ipairs({ {}, { regime = consent_policy.SOFT_OPT_OUT },
		{ flags = { operation_blocks = {} } },
		{ flags = { operation_blocks = { "restricted" }, crash_profile = consent_policy.CRASH_MINIMAL } },
		{ signature = "synthetic-unverifiable" } }) do
		reset()
		next_response_body = example_plan(overrides)
		local calls, initial = run_example(function() next_response_body = "not JSON" end,
			{ "focus_lost", "focus_gained" }, { 1, 1, 1 }, true,
			{ age_band = "adult", answer = true })
		for _, forbidden in ipairs({ "sdk.init", "notice:default=", "crash.init", "sdk.set_consent",
			"sdk.identify", "sdk.session_start", "sdk.fetch_remote_config" }) do
			assert_true(calls:find(forbidden, 1, true) == nil, "unknown blocks prevent " .. forbidden)
		end
		assert_true(initial:find("operation restrictions are unknown; no lane opened", 1, true) ~= nil,
			"the real resolver must reach the unknown-block guard: " .. initial)
		assert_equal(select(2, calls:gsub("operation restrictions are unknown; no lane opened", "")), 2,
			"launch and resume outage must both close the lanes")
		assert_equal(#requests, 2, "launch and resume re-resolve; frames do not spin")

	end
end

-- Both responses are unused, but an older dispatch must retain its superseded
-- reason instead of being treated as the current response.
local function test_an_older_response_cannot_overwrite_a_newer_one()
	reset()
	-- A transport that holds every request until this scene releases it.
	local held = {}
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url }
		held[#held + 1] = { callback = callback, body = next_response_body }
	end

	local first, second = {}, {}
	next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT })
	consent_policy.prepare(context(), function(d) first[#first + 1] = d end)
	next_response_body = plan({ regime = consent_policy.STRICT_OPT_IN })
	consent_policy.prepare(context(), function(d) second[#second + 1] = d end)
	assert_equal(#held, 2, "both requests must be in flight")

	-- The NEWER one answers first; then the older, permissive one arrives.
	held[2].callback(nil, nil, { status = 200, response = held[2].body })
	held[1].callback(nil, nil, { status = 200, response = held[1].body })
	http.request = saved_request

	assert_equal(#second, 1, "the newer caller is answered exactly once")
	assert_equal(second[1].regime, consent_policy.STRICT_OPT_IN, "with the local fallback")
	assert_equal(#first, 1, "the older caller is answered exactly once, not dropped")
	assert_equal(first[1].reason, "superseded", "and told why")
	assert_equal(first[1].analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
		"a superseded answer defaults off")

	-- A later prepare always makes a new request.
	local served = prepare()
	assert_equal(#requests, 3, "an unsigned response cannot populate a cache")
	assert_equal(served.regime, consent_policy.STRICT_OPT_IN,
		"the next response stays strict")
end

-- ⚠ AN ENCODER THAT RAISES IS NOT A STRICT DECISION, IT IS NO DECISION. The
-- error left prepare without ever invoking the one callback it promises, so
-- the caller had nothing to fail closed on — the same shape as the endpoint
-- concatenation defect.
local function test_an_encoder_failure_still_answers()
	reset()
	next_response_body = plan()
	local saved_encode = json.encode
	json.encode = function()
		error("synthetic encoder failure")
	end
	local decision, calls = prepare()
	json.encode = saved_encode
	assert_equal(calls, 1, "exactly one callback when the encoder raises")
	assert_equal(decision.reason, "encoder_failed")
	assert_equal(#requests, 0, "a body that could not be encoded must cost zero requests")
	assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")
end


local function test_unsigned_soft_cannot_authorize_an_offline_call()
	reset()
	next_response_body = plan({ regime = consent_policy.SOFT_OPT_OUT })
	assert_unsigned(prepare(), "SOFT/null is unused")
	local saved_http = http
	http = nil
	local offline, calls = prepare()
	http = saved_http
	assert_equal(calls, 1)
	assert_equal(offline.reason, "transport_unavailable")
	assert_true(not offline.plan_used)
	assert_true(offline.operation_blocks == nil)
	assert_equal(offline.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF)
end

-- ⚠ NO socket IS NOT A REASON TO BE PERMANENTLY STRICT. Returning nil made
-- prepare refuse outright on every target without the socket module — not
-- failing closed on a doubt, but never asking the question. clock.lua already
-- falls back to os.time(); second resolution is ample for an expiry measured
-- in minutes.
local function test_the_clock_falls_back_to_os_time()
	reset()
	next_response_body = plan()
	local saved_socket = socket
	socket = nil
	local decision, calls = prepare()
	socket = saved_socket
	assert_equal(calls, 1, "exactly one callback")
	assert_equal(#requests, 1, "a target without socket must still reach the wire")
	assert_unsigned(decision, "and use the plan: " .. tostring(decision.reason))

	-- The control: with NEITHER clock the refusal stands, so the fallback did
	-- not simply delete the rule.
	reset()
	next_response_body = plan()
	socket = nil
	local saved_time = os.time
	os.time = nil
	local blind = prepare()
	os.time = saved_time
	socket = saved_socket
	assert_equal(blind.reason, "clock_unavailable", "with no clock at all the refusal stands")
	assert_equal(#requests, 0, "and it costs no request")
end

-- ⚠ AN EMPTY JSON OBJECT AND AN EMPTY ARRAY DECODE TO THE SAME LUA TABLE, so
-- after the decode the container type is gone. `"operation_blocks": {}` read
-- as "no operation blocks" and the plan was USED. The raw response text is the
-- only place the distinction survives.
local function test_an_empty_object_is_not_an_empty_list()
	for _, name in ipairs({ "signals_used" }) do
		for _, spacing in ipairs({ "{}", " { }", "\t{\"a\":1}" }) do
			reset()
			next_response_body = raw_field('"' .. name .. '"', spacing, { [name] = "__nil__" })
			local decision = prepare()
			assert_equal(decision.reason, "invalid_response",
				name .. " as a JSON object must not be used (" .. spacing .. ")")
			assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")
		end
	end

	-- The controls: an empty ARRAY still parses for all three, or this rule
	-- would be refusing the resolver's own output.
	reset()
	next_response_body = plan({ flags = { operation_blocks = {} }, signals_used = {} })
	assert_unsigned(prepare(), "empty arrays must still parse")

	-- ⚠ AND THE ONE INSIDE flags, which the top-level scan never sees. The
	-- contract moved operation_blocks in there, so it is checked by the flags
	-- walk instead.
	reset()
	local body = plan()
	next_response_body = body:gsub('"operation_blocks":%[%]', '"operation_blocks":{}', 1)
	local blocks = prepare()
	assert_equal(blocks.reason, "invalid_response", "operation_blocks as an object must not read as no blocks")
	-- ⚠ THE REASON IS THE ASSERTION. The walk refuses a malformed object one
	-- way or another; what the explicit check adds is SAYING WHICH FIELD, and
	-- a refusal that cannot name the field is the one an integrator cannot act
	-- on.
	assert_true(blocks.detail == "operation_blocks is not a list",
		"and must name the field: " .. tostring(blocks.detail))
end

-- ⚠ AN OFFSET IS SPELLED WITH THE COLON. Accepting "+0200" as well was being
-- generous with someone else's grammar, and a parser that accepts more than
-- the spec disagrees with every other reader of the same field.
local function test_an_offset_needs_its_colon()
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:00+0200" })
	assert_equal(prepare().reason, "invalid_response", '"+0200" is not an RFC 3339 offset')
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:00+02:00" })
	assert_unsigned(prepare(), '"+02:00" is')
end


-- ⚠ A LITERAL SEARCH FOR THE KEY NAME IS BYPASSED BY ONE ESCAPE.
-- "operation_blocks" decodes to the same key, json.decode restores it,
-- and the raw-text search never saw it — so the scan has to unescape the key
-- before comparing, and skip every value whole so a nested key of the same
-- name is not mistaken for the top-level one.
local function test_an_escaped_key_cannot_hide_an_object()
	-- signals_used is the only TOP-LEVEL list the contract has;
	-- operation_blocks moved inside flags in the contract migration and prohibited_purposes left
	-- the schema, so this is now the one key the top-level scan can be asked
	-- about. The flags walk covers its own array separately.
	local escaped = {
		signals_used = '"signals\\u005fused"',
	}
	for name, spelling in pairs(escaped) do
		reset()
		next_response_body = raw_field(spelling, "{}", { [name] = "__nil__" })
		local decision = prepare()
		assert_equal(decision.reason, "invalid_response",
			name .. " spelled with an escape must not hide an object: " .. tostring(decision.reason))

		-- The control: the SAME escaped spelling with an ARRAY still parses,
		-- so the rule is about the container and not about the escape.
		reset()
		next_response_body = raw_field(spelling, "[]", { [name] = "__nil__" })
		assert_unsigned(prepare(), name .. " spelled with an escape must still parse as a list")
	end

	-- ⚠ AND A NESTED KEY OF THE SAME NAME IS NOT THE TOP-LEVEL ONE. The scan
	-- skips each value whole; a scope object carrying its own "operation_blocks"
	-- would otherwise refuse a perfectly good plan.
	reset()
	local body = plan()
	next_response_body = body:gsub('"scope":{', '"scope":{"operation_blocks":{},', 1)
	local nested = prepare()
	-- ⚠ THE REASON IS THE CONTROL, NOT THE VERDICT. Every schema
	-- object now has a closed key set, so this IS refused — but it must be refused
	-- as "scope carries an unknown key", never as "operation_blocks is a JSON
	-- object where the schema says a list". A scan that matched the name
	-- anywhere in the document would give the second answer.
	assert_equal(nested.reason, "invalid_response", "an unknown key inside scope is refused")
	assert_true(nested.detail ~= nil and nested.detail:find("scope carries an unknown key", 1, true) ~= nil,
		"it must be refused as a scope member, not as a top-level list shape: "
			.. tostring(nested.detail))
end

-- ⚠ SECOND 60 IS NOT A LEAP SECOND UNLESS IT IS 23:59:60 ON AN ANNOUNCED DATE.
-- Accepting it anywhere normalised the timestamp arithmetically to the next
-- minute, quietly moving a plan's expiry.
local function test_second_sixty_is_refused()
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:60Z" })
	assert_equal(prepare().reason, "invalid_response", "second 60 must not be normalised into the next minute")
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:59Z" })
	assert_unsigned(prepare(), "second 59 is still a second")
end



-- Present-null has valid unsigned syntax. Neither it nor an absent or
-- non-null signature supplies authentication or plan authority.
local function test_the_signature_is_present_and_null_or_refused()
	reset()
	next_response_body = raw_field('"signature"', "null")
	assert_unsigned(prepare(), "a null signature is the unsigned state")

	-- ⚠ AND ABSENT IS NOT THE SAME STATE. This scene asserted that it was,
	-- until the required-key roster: the contract sends `"signature": null` on
	-- every response, so a plan without the key lost it on the way rather than
	-- arriving unsigned — and "absent means unsigned" is the reading that lets
	-- a stripped field pass as a deliberate one. It is the one key whose
	-- absence only the RAW SCAN can see, because null and absent decode alike.
	reset()
	next_response_body = plan({ signature = "__nil__" })
	local absent = prepare()
	assert_equal(absent.reason, "invalid_response", "an absent signature must not be used")
	assert_true(absent.detail:find("missing the required key signature", 1, true) ~= nil,
		"and the reason must name the key: " .. tostring(absent.detail))

	for _, forged in ipairs({ '"ed25519:synthetic"', '""', "42" }) do
		reset()
		next_response_body = raw_field('"signature"', forged)
		local decision = prepare()
		assert_equal(decision.reason, "invalid_response",
			"a present signature must not be used: " .. forged)
		assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")
	end
end

-- ⚠ A CLOCK THAT MOVED BACKWARDS WHILE THE REQUEST WAS IN FLIGHT makes every
-- judgement below it meaningless in the permissive direction: the deadline,
-- the expiry and the cache lifetime are all comparisons against the arrival
-- reading, and an earlier one makes a plan look fresher and an entry live
-- longer.
local function test_a_clock_rollback_during_the_request_is_refused()
	reset()
	next_response_body = plan()
	local saved_request = http.request
	http.request = function(url, method, callback, headers, body, options)
		requests[#requests + 1] = { url = url }
		socket.now = socket.now - 30
		callback(nil, nil, { status = 200, response = next_response_body })
	end
	local decision, calls = prepare()
	http.request = saved_request
	socket.now = 1000
	assert_equal(calls, 1, "exactly one callback")
	assert_equal(decision.reason, "clock_regressed", "a rollback in flight is refused by name")
	assert_true(not decision.plan_used, "and no plan is used")
	assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")

	-- And it is refused BEFORE anything is cached: the next call goes to the
	-- wire rather than being served a plan that was never accepted.
	next_response_body = plan()
	prepare()
	assert_equal(#requests, 2, "a refused response must not have been cached")
end


-- ⚠ NO FIELD IN THIS SCHEMA IS NULLABLE, AND THAT IS ONE RULE. Lua has no
-- null, so every present-and-null key decodes to exactly the nil an absent key
-- decodes to — and this module reads absence as a MEANING everywhere: absent
-- signature is unsigned, absent objection requirement stands, absent list is
-- no restrictions. Asked over the whole schema rather than field by field,
-- because patching them one at a time is how the next added field arrives with
-- the same hole.
local function test_no_schema_field_is_nullable()
	-- Every top-level key the contract has, EXCEPT `signature`: that one is
	-- null on every response by contract, so present-and-null is its unsigned
	-- state and the one admissible exception to the rule.
	local nullable = {
		"regime", "flags", "policy_version", "consent_text_version",
		"presented_language", "scope", "signals_used", "band_vocabulary",
		"band_vocabulary_version", "expires_at", "max_age_seconds", "basis",
	}
	for _, name in ipairs(nullable) do
		reset()
		next_response_body = raw_field('"' .. name .. '"', "null", { [name] = "__nil__" })
		local decision = prepare()
		assert_equal(decision.reason, "invalid_response", name .. " present and null must not be used")
		assert_true(decision.analytics_choice_default == consent_policy.CHOICE_DEFAULT_OFF, name .. " must close optional processing")
	end

	-- ⚠ AND THE EXCEPTION, asserted so it cannot quietly become a hole: a null
	-- signature is the UNSIGNED state and must parse.
	reset()
	next_response_body = raw_field('"signature"', "null")
	assert_unsigned(prepare(), "a null signature is unsigned and must reach the authentication refusal")

	-- The control: the same plan with every key carrying a real value parses,
	-- so the rule is about null rather than about the roster.
	reset()
	next_response_body = plan({ flags = { operation_blocks = { "transfer_review" } } })
	assert_unsigned(prepare(), "a plan with every schema field populated must parse")
end

-- ⚠ AND A null ELEMENT INSIDE A LIST. Lua drops it: the decoded array comes
-- back one entry SHORTER, so a roster of three operation blocks with the
-- middle one nulled reads as a roster of two, with nothing anywhere saying a
-- third was sent.
local function test_a_null_list_entry_is_refused()
	reset()
	next_response_body = raw_field('"signals_used"', '["a",null,"b"]', { signals_used = "__nil__" })
	assert_equal(prepare().reason, "invalid_response", "signals_used with a null entry must not be used")

	-- ⚠ AND THE ONE INSIDE flags, which the top-level walk never reaches.
	reset()
	local body = plan({ flags = { operation_blocks = { "transfer_review" } } })
	next_response_body = body:gsub('"transfer_review"', '"transfer_review",null', 1)
	assert_equal(prepare().reason, "invalid_response", "operation_blocks with a null entry must not be used")

	-- The control: the same lists without the null still parse.
	reset()
	next_response_body = plan({ flags = { operation_blocks = { "transfer_review", "age_capacity" } } })
	assert_unsigned(prepare(), "a dense list must still parse")
end


-- ⚠ AN ERROR BODY IS AN ERROR ENVELOPE, NOT A PLAN. Running the plan-key
-- allowlist over it refused a perfectly well-formed {"reason": ...} for
-- carrying a key that is not a plan field — a regression the allowlist
-- introduced, which turned every resolver refusal into "unreadable" and lost
-- the reason the resolver gave.
local function test_an_error_envelope_keeps_its_reason()
	reset()
	next_status = 503
	next_response_body = encode_value({ reason = "policy_unavailable" })
	local decision = prepare()
	assert_equal(decision.reason, "policy_unavailable", "the resolver's reason must survive")
	assert_true(not decision.plan_used, "and no plan is used")
	assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")

	-- ⚠ BUT NOT WHATEVER ARRIVES. decision.reason travels into a caller's
	-- control flow and its log lines, so an unrecognisable one is reported as
	-- the generic reason rather than echoed.
	for _, hostile in ipairs({ "Policy Unavailable", string.rep("x", 65), "reason\ninjected", 42 }) do
		reset()
		next_status = 500
		next_response_body = encode_value({ reason = hostile })
		assert_equal(prepare().reason, "policy_unavailable",
			"an unrecognisable reason must not be echoed: " .. tostring(hostile))
	end
end


-- ⚠ A DUPLICATE KEY IS AMBIGUOUS AT EVERY DEPTH. The root walk refused them
-- and the nested walk skipped values whole, so a scope carrying workspace_key
-- twice — once the caller's, once another tenant's — was decided silently by
-- the decoder, last one wins, and then compared against the caller's own scope
-- and passed.
local function test_nested_duplicate_keys_are_refused()
	local cases = {
		{ "scope", '"workspace_key":"ws-other",', '"scope":{' },
		{ "flags", '"child_rules":"unrestricted",', '"flags":{' },
		{ "basis", '"notice":"other",', '"basis":{' },
		{ "a signal", '"name":"other",', '"signals_used":[{' },
	}
	for _, case in ipairs(cases) do
		reset()
		local body = plan()
		-- The duplicate is spliced INSIDE the nested object, so the root walk
		-- sees one occurrence of the outer key and this is genuinely nested.
		next_response_body = body:gsub(case[3]:gsub("%p", "%%%0"), case[3] .. case[2], 1)
		assert_true(next_response_body ~= body, "the fixture must carry " .. case[1])
		local decision = prepare()
		assert_equal(decision.reason, "invalid_response",
			"a duplicate key inside " .. case[1] .. " must not be used: " .. tostring(decision.reason))
	end

	-- The control is the resolver's own bytes, which carry all four objects
	-- spelled once each.
	reset()
	next_response_body = golden("resolved")
	assert_unsigned(prepare(golden_context()), "well-formed nested objects must parse")
end

-- ⚠ THE CALLER'S FIELD NAMES ARE A CLOSED SET TOO, and the shape this takes in
-- practice is a typo: `age_bnad` is silently no age band at all, so the request
-- goes out claiming this player has none.
local function test_an_unknown_context_field_is_refused()
	for _, override in ipairs({
		{ age_bnad = { vocabulary = "coarse.v1", band = "adult" } },
		{ workspace = "ws-synthetic" },
		{ user_id = "player-1" },
	}) do
		reset()
		next_response_body = plan()
		local decision, calls = prepare(context(override))
		assert_equal(calls, 1, "exactly one callback")
		assert_equal(#requests, 0, "an unknown context field must cost zero requests")
		assert_equal(decision.reason, "invalid_request")
		assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")
	end

	-- The control: every field the context DOES have must still be accepted,
	-- including the optional ones, or this rule would refuse valid callers.
	reset()
	next_response_body = plan()
	-- ⚠ THE VOCABULARY MUST BE THE ONE THE RESOLVER NAMES. The contract has no
	-- echo of the band, so a caller's vocabulary is checked against
	-- band_vocabulary instead — "coarse" here, as the resolver sends.
	assert_unsigned(prepare(context({
		store = "steam",
		age_band = { vocabulary = "coarse", band = "adult" },
	})), "a context using every optional field must parse")
end

-- ⚠ THE NULLABILITY RULE HAS TO REACH INSIDE THE LIST, NOT STOP AT ITS NAME.
--
-- Being honest about what this adds: a null `name`, a null `available`, or a
-- null `reason` on an UNAVAILABLE signal were already refused — by the name
-- bound, the boolean check and the needs-a-reason rule. They were refused BY
-- LUCK, in the sense that nothing was checking the thing that was actually
-- wrong. The cases below are the ones nothing reached at all: a field the
-- entry does not need, nulled.
local function test_a_null_field_inside_a_signal_is_refused()
	local cases = {
		-- An AVAILABLE signal needs no reason, so a null one was simply
		-- ignored: the plan said "reason: null" and was used as though it had
		-- not mentioned it.
		{ "a null reason on an available signal",
			'[{"name":"server_country","available":true,"reason":null}]' },
		-- And any other field the entry carries. Nothing validates names
		-- inside a signal entry, so this was accepted outright.
		{ "a null field the entry does not need",
			'[{"name":"server_country","available":false,"reason":"source_unavailable","source":null}]' },
		-- ⚠ THE SECOND ENTRY IS CHECKED TOO, or the rule would only ever see
		-- the first signal a plan happens to list.
		{ "a null in the SECOND entry",
			'[{"name":"server_country","available":false,"reason":"source_unavailable"},' ..
			'{"name":"store_region","available":true,"reason":null}]' },
	}
	for _, case in ipairs(cases) do
		reset()
		next_response_body = raw_field('"signals_used"', case[2], { signals_used = "__nil__" })
		local decision = prepare()
		assert_equal(decision.reason, "invalid_response",
			case[1] .. " must not be used: " .. tostring(decision.reason))
		assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")
	end

	-- The controls: the same entries without the nulls still parse — an
	-- available signal with no reason mentioned at all, and two unavailable
	-- ones with reasons.
	reset()
	next_response_body = plan({ signals_used = { { name = "server_country", available = true } } })
	assert_unsigned(prepare(), "an available signal that mentions no reason must parse")
	reset()
	next_response_body = plan({ signals_used = {
		{ name = "server_country", available = false, reason = "source_unavailable" },
		{ name = "store_region", available = false, reason = "source_not_permitted" },
	} })
	assert_unsigned(prepare(), "well-formed signal entries must parse")
end

-- ⚠ A reason IS CHECKED WHEREVER IT APPEARS. The closed vocabulary was
-- enforced on the branch that REQUIRES a reason and nowhere else, so an
-- AVAILABLE signal could carry any string at all — and signals_used is a
-- provenance record, so an unreadable reason on it is a claim about how the
-- resolver reached its answer that nothing checked.
local function test_a_signal_reason_is_always_from_the_vocabulary()
	for _, signal in ipairs({
		{ name = "server_country", available = true, reason = "because" },
		{ name = "server_country", available = true, reason = "SOURCE_UNAVAILABLE" },
		{ name = "server_country", available = false, reason = "because" },
	}) do
		reset()
		next_response_body = plan({ signals_used = { signal } })
		assert_equal(prepare().reason, "invalid_response", "a reason outside the vocabulary must not be used")
	end

	-- The controls: every member of the vocabulary parses on an available
	-- signal and on an unavailable one, and an available signal may still
	-- mention no reason at all.
	for _, reason in ipairs({ "source_not_permitted", "source_unavailable", "not_enabled_in_release" }) do
		for _, available in ipairs({ true, false }) do
			reset()
			next_response_body = plan({
				signals_used = { { name = "server_country", available = available, reason = reason } },
			})
			assert_unsigned(prepare(), reason .. " must parse (available=" .. tostring(available) .. ")")
		end
	end
	reset()
	next_response_body = plan({ signals_used = { { name = "server_country", available = true } } })
	assert_unsigned(prepare(), "an available signal may mention no reason")
end


-- ⚠ THE PACKAGED SKILL'S SNIPPETS ARE CODE A CUSTOMER RUNS. The skill is what
-- an integrator's assistant reads, so a snippet that does not even parse is a
-- broken integration shipped with confidence. Every ```lua block in it is
-- compiled here.
--
-- HONEST LIMIT: this compiles them. It cannot run the policy snippet — that
-- one is deliberately a fragment, with `<YOUR-...>` placeholders and a
-- `present_your_consent_notice` the integrator supplies — so its SEMANTICS
-- were checked by reading it against examples/minimal/main.script line by
-- line, not by execution. The executable statement of the contract remains the
-- example, which this suite does run.
local function test_the_packaged_skill_snippets_compile()
	local source = io.open(".claude/skills/shardpilot-defold-integration/SKILL.md")
	assert_true(source ~= nil, "the packaged skill must exist")
	local text = source:read("*a")
	source:close()
	local compile = loadstring or load
	local blocks = 0
	for block in text:gmatch("```lua\n(.-)```") do
		blocks = blocks + 1
		local chunk, err = compile(block)
		assert_true(chunk ~= nil,
			"a lua block in the packaged skill does not compile: " .. tostring(err))
	end
	assert_true(blocks >= 5, "the skill must still carry its snippets, found " .. blocks)
end

-- ⚠ THE CONTEXT'S age_band GETS THE SAME CLOSED KEY SET THE RESPONSE'S DOES.
-- It was closed on the band the resolver sends back and left open on the one
-- the caller sends — and this is the side that TRAVELS: an unread member here
-- is an age claim about this player that nothing looked at.
local function test_the_context_age_bands_keys_are_closed()
	reset()
	next_response_body = plan()
	local decision, calls = prepare(context({
		age_band = { vocabulary = "coarse", band = "adult", date_of_birth = "1989-04-02" },
	}))
	assert_equal(calls, 1, "exactly one callback")
	assert_equal(#requests, 0, "an unknown age_band field must cost zero requests")
	assert_equal(decision.reason, "invalid_request")
	assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")

	-- The control: the two schema fields alone are still accepted and reach
	-- the wire.
	reset()
	next_response_body = plan()
	assert_unsigned(prepare(context({ age_band = { vocabulary = "coarse", band = "adult" } })),
		"a well-formed context age_band must be accepted")
	assert_equal(#requests, 1, "and must reach the wire")
end


-- ⚠ EVERY OBJECT IN THE SCHEMA HAS AN EXACT KEY SET. The root was closed
-- first, then age_band, then the context's age_band — the same finding
-- arriving at one door after another, which is what a roster is for. This
-- asks it of all four at once, and of the shape that would otherwise slip
-- past: an unknown member spelled `null`, which decodes to the same nil an
-- absent one does and would vanish before any decoded-side check could see it.
local function test_every_schema_object_has_a_closed_key_set()
	local objects = {
		{
			what = "the plan root",
			build = function(raw)
				return raw_field('"tenant_override"', raw)
			end,
		},
		{
			what = "flags",
			build = function(raw)
				local body = plan()
				return (body:gsub('"flags":{', '"flags":{"tenant_override":' .. raw .. ",", 1))
			end,
		},
		{
			what = "scope",
			build = function(raw)
				local body = plan()
				return (body:gsub('"scope":{', '"scope":{"tenant_override":' .. raw .. ",", 1))
			end,
		},
		{
			what = "basis",
			build = function(raw)
				local body = plan()
				return (body:gsub('"basis":{', '"basis":{"tenant_override":' .. raw .. ",", 1))
			end,
		},
		{
			what = "a signal entry",
			build = function(raw)
				return raw_field('"signals_used"',
					'[{"name":"server_country","available":false,"reason":"source_unavailable",' ..
					'"tenant_override":' .. raw .. "}]", { signals_used = "__nil__" })
			end,
		},
	}
	-- A real value, and the null that would otherwise disappear in decoding.
	for _, raw in ipairs({ '"other"', "null" }) do
		for _, object in ipairs(objects) do
			reset()
			next_response_body = object.build(raw)
			local decision = prepare()
			assert_equal(decision.reason, "invalid_response",
				"an unknown key in " .. object.what .. " (" .. raw .. ") must not be used: "
					.. tostring(decision.reason))
			assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")
		end
	end

	-- The control is the resolver's own bytes: every object spelled with
	-- exactly its own members, which must parse.
	reset()
	next_response_body = golden("resolved")
	assert_unsigned(prepare(golden_context()), "the resolver's own response must parse")
end

-- ⚠ "-00:00" IS NOT ZERO, IT IS "OFFSET UNKNOWN" (RFC 3339). An expiry
-- whose offset the sender declined to state is an instant this build cannot
-- place on a timeline, and reading it as UTC is picking one of the
-- twenty-seven it could have meant.
local function test_an_unknown_offset_is_refused()
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:00-00:00" })
	assert_equal(prepare().reason, "invalid_response", '"-00:00" is not an offset this build can place')
	-- The controls: "+00:00" IS zero, and "Z" is the usual spelling of it.
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:00+00:00" })
	assert_unsigned(prepare(), '"+00:00" is a stated offset of zero')
	reset()
	next_response_body = plan({ expires_at = "2099-01-01T00:00:00Z" })
	assert_unsigned(prepare(), '"Z" is still UTC')
end

-- ⚠ parse_plan IS PRIVATE. The public surface is prepare() and invalidate().
-- It takes a DECODED TABLE, and half of what this module checks — container
-- types, duplicate keys, present-and-null members, unknown key names — lives
-- in the raw text and is gone by the time a table exists, so an exported
-- parse_plan would hand a caller a validator that silently cannot perform most
-- of its own validation.
local function test_the_public_surface_is_prepare_and_invalidate()
	local exported = {}
	for name, value in pairs(consent_policy) do
		if type(value) == "function" then
			exported[#exported + 1] = name
		end
	end
	table.sort(exported)
	assert_equal(table.concat(exported, ","), "invalidate,prepare,validate_context",
		"the exported functions are the contract; parse_plan is not one of them")
end


-- ⚠ THE RESOLVER'S OWN BYTES, AND THE REASON THIS SCENE EXISTS AT ALL.
--
-- This module and the resolver were written from the same prose and neither
-- ever parsed the other's output: the module validated a FLAT plan while the
-- server answers a NESTED one, so every real response was refused as
-- unreadable. It was invisible because the answer is STRICT either way — the
-- fallback and the plan agree today — and it would have become visible on the
-- first release where they did not.
--
-- A schema written down in two places is a schema in neither. These are the
-- handler's actual bytes (test/golden/, with the commit they came from), and
-- they are the one artefact both sides can be wrong against.
local function test_the_resolvers_own_bytes_are_understood()
	-- (i) A RESOLVED plan: used, strict, fully closed, and the versions the
	-- host needs actually delivered — those were the fields silently lost
	-- while every response was being refused.
	reset()
	next_response_body = golden("resolved")
	local decision = prepare(golden_context())
	assert_unsigned(decision,
		"the resolver's resolved plan must reach the unsigned refusal: " .. tostring(decision.reason)
			.. " / " .. tostring(decision.detail))
	assert_equal(decision.regime, consent_policy.STRICT_OPT_IN)
	assert_true(decision.analytics_choice_default == consent_policy.CHOICE_DEFAULT_OFF, "STRICT closes optional processing")
	assert_equal(decision.crash_profile, consent_policy.CRASH_OFF)
	assert_equal(decision.server_analytics, consent_policy.SERVER_ANALYTICS_DENIED)
	assert_equal(decision.child_rules, consent_policy.CHILD_RULES_MINIMISED)
	assert_true(decision.policy_version == nil, "unauthenticated policy_version is not carried")
	assert_true(decision.consent_text_version == nil, "unauthenticated consent_text_version is not carried")
	assert_true(decision.presented_language == nil, "unauthenticated presented_language is not carried")
	assert_true(decision.band_vocabulary == nil, "unauthenticated band_vocabulary is not carried")
	assert_true(decision.band_vocabulary_version == nil, "unauthenticated band_vocabulary_version is not carried")
	assert_true(decision.notice == nil, "unauthenticated notice text is not presented")

	-- (ii) A REFUSAL: the resolver answers a COMPLETE strict plan with a reason
	-- — every key present, scope as three empty strings — so what tells a
	-- refusal from a plan is the REASON, not the status and not a missing
	-- field. The reason must be surfaced, and that empty scope must not be read
	-- as a mismatch.
	reset()
	next_response_body = golden("refusal")
	local refused = prepare(golden_context())
	assert_true(not refused.plan_used, "a refusal reports no used plan")
	assert_equal(refused.reason, "invalid_scope", "and surfaces the resolver's reason")
	assert_equal(refused.regime, consent_policy.STRICT_OPT_IN, "and is STRICT")
	assert_true(refused.analytics_choice_default == consent_policy.CHOICE_DEFAULT_OFF, "and closes optional processing")

	-- ⚠ AND THE SCENE MUST BREAK WHEN THE CONTRACT MOVES. One renamed key in
	-- the resolver's body must make this red — otherwise the golden is
	-- decoration.
	for _, renamed in ipairs({
		{ '"flags"', '"restrictions"' },
		{ '"band_vocabulary"', '"band_vocab"' },
		{ '"basis"', '"provenance"' },
		{ '"crash_profile"', '"crash"' },
	}) do
		reset()
		next_response_body = golden("resolved"):gsub(renamed[1], renamed[2], 1)
		local moved = prepare(golden_context())
		assert_equal(moved.reason, "invalid_response",
			"a renamed " .. renamed[1] .. " must not be quietly accepted")
	end
end

-- A wall-clock change between calls cannot make an unsigned plan authoritative.
local function test_clock_change_cannot_authorize_an_unsigned_plan()
	reset()
	next_response_body = plan()
	assert_unsigned(prepare(), "the fixture must reach the unsigned refusal")
	assert_equal(#requests, 1)

	-- The clock goes backwards by a minute before the next dispatch.
	socket.now = socket.now - 60
	local served = prepare()
	socket.now = 1000
	-- Both requests remain unauthenticated and closed.
	assert_true(served.analytics_choice_default == consent_policy.CHOICE_DEFAULT_OFF, "the response after a clock change must stay closed")
	assert_equal(served.crash_profile, consent_policy.CRASH_OFF, "with the crash lane shut")
	assert_equal(served.server_analytics, consent_policy.SERVER_ANALYTICS_DENIED, "and no server lane")
	assert_equal(served.child_rules, consent_policy.CHILD_RULES_MINIMISED, "and the child rules minimised")
end


-- ⚠ A PRESENT-AND-NULL LIST IS NOT AN ABSENT ONE, and for these three fields
-- it is worse than for the signature: a null roster of operation blocks
-- decodes to the same nil as no roster at all, and those blocks govern
-- transfer, age/capacity, localisation and safety — restrictions no consent
-- choice lifts.
local function test_a_null_list_is_not_an_absent_one()
	reset()
	next_response_body = raw_field('"signals_used"', "null")
	local decision = prepare()
	assert_equal(decision.reason, "invalid_response", "signals_used present and null must not be used")
	assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")

	-- ⚠ AND ABSENT IS NOW REFUSED TOO, BY A DIFFERENT RULE WITH A DIFFERENT
	-- REASON. This scene used to assert the opposite — that a genuinely absent
	-- signals_used still parsed — because the module treated the key as
	-- optional. The contract of record sends it on every plan, so the two
	-- states are both malformed and the reasons say which is which: one is
	-- present and null, the other is missing.
	reset()
	next_response_body = plan({ signals_used = "__nil__" })
	decision = prepare()
	assert_equal(decision.reason, "invalid_response", "signals_used absent must not be used either")
	assert_true(decision.detail:find("missing the required key signals_used", 1, true) ~= nil,
		"and the reason must name the key: " .. tostring(decision.detail))
end

-- ⚠ THE FIELD NAMES ARE A CLOSED VOCABULARY TOO. Every other bounded value in
-- this module is checked against a closed set; the set of names was the one
-- that was not, so a plan could carry anything beside the fields we read and
-- still be used. A key we do not understand is a plan we cannot say we fully
-- read.
local function test_an_unknown_top_level_key_is_refused()
	reset()
	next_response_body = raw_field('"tenant_override"', '"other"')
	local decision = prepare()
	assert_equal(decision.reason, "invalid_response", "an unknown top-level key must not be used")
	assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")

	-- The controls: every key the schema DOES have must still parse, or this
	-- rule would refuse the resolver's own output. Asked with the optional
	-- ones present, which are the easiest to forget in a roster.
	reset()
	next_response_body = golden("resolved")
	assert_unsigned(prepare(golden_context()), "the resolver's own response must parse")
end

-- ⚠ A DUPLICATE TOP-LEVEL KEY IS AMBIGUOUS AND THE DECODER RESOLVES IT
-- SILENTLY — last one wins. A body carrying both a strict and a permissive
-- spelling of the same field is not a plan with a value, it is two plans, and
-- this build does not get to pick.
local function test_a_duplicate_top_level_key_is_refused()
	reset()
	-- The fixture keeps its own "regime"; this adds a second, permissive one.
	next_response_body = duplicate_field('"regime"', '"' .. consent_policy.SOFT_OPT_OUT .. '"')
	local decision = prepare()
	assert_equal(decision.reason, "invalid_response", "a duplicated key must not be used")
	assert_true(decision.regime == consent_policy.STRICT_OPT_IN,
		"and certainly not with the permissive spelling: " .. tostring(decision.regime))

	-- The same key spelled with an escape is the same key.
	reset()
	next_response_body = raw_field('"regi\\u006de"', '"' .. consent_policy.SOFT_OPT_OUT .. '"')
	assert_equal(prepare().reason, "invalid_response", "an escaped duplicate is still a duplicate")
end

-- ⚠ EVERY ENUM IN THE PLAN IS CLOSED, AND AN UNKNOWN VALUE IS A REFUSAL — not
-- a permissive plan, and not a value to pass through. Where the contract names
-- one value, one value is what parses: a second one arrives in the release
-- that adds it, in both repositories at once.
local function test_every_plan_enum_is_closed()
	local cases = {
		{ "regime", plan({ regime = "PERMISSIVE" }) },
		{ "crash_profile", plan({ flags = { crash_profile = "everything" } }) },
		{ "crash_profile (wrong case)", plan({ flags = { crash_profile = "OFF" } }) },
		{ "server_analytics", plan({ flags = { server_analytics = "eligible" } }) },
		{ "child_rules", plan({ flags = { child_rules = "unrestricted" } }) },
		{ "basis.character", plan({ basis = {
			character = "legal_advice", table_provenance = "ai_draft", notice = NOTICE } }) },
		{ "basis.table_provenance", plan({ basis = {
			character = "informational_reference", table_provenance = "guessed", notice = NOTICE } }) },
		{ "a signal reason", plan({ signals_used = {
			{ name = "server_country", available = false, reason = "because" } } }) },
	}
	for _, case in ipairs(cases) do
		reset()
		next_response_body = case[2]
		local decision = prepare()
		assert_equal(decision.reason, "invalid_response",
			"an unknown " .. case[1] .. " must not be used: " .. tostring(decision.detail))
		assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")
	end

	-- The controls: every value the contract DOES name parses.
	for _, profile in ipairs({ consent_policy.CRASH_OFF, consent_policy.CRASH_MINIMAL }) do
		reset()
		next_response_body = plan({ flags = { crash_profile = profile } })
		assert_unsigned(prepare(), profile .. " must parse")
	end
	for _, provenance in ipairs({ "ai_draft", "owner_accepted" }) do
		reset()
		next_response_body = plan({ basis = {
			character = "informational_reference", table_provenance = provenance, notice = NOTICE } })
		assert_unsigned(prepare(), provenance .. " must parse")
	end
end


-- ⚠ THE PROVENANCE, AS A SCENE RATHER THAN A SENTENCE. The README used to
-- claim these files are the handler's own bytes and point at a commit. A
-- reader had no way to check it, and a claim nobody can check is the shape
-- every other defect in this module took.
--
-- Both forms are vendored: the COMPACT file, which is what the handler writes
-- on the wire, and the INDENTED file, which is what the resolver repository
-- stores so a human notices a diff. Its own golden test re-indents the raw
-- response and compares that, applying indentation to both sides, so
-- indentation is the only transformation between them. This asserts exactly
-- that — and asserts it by COMPACTION rather than by decoding, so a key
-- reordered, a number respelled or an escape rewritten in either file would
-- fail here instead of passing as "the same document".
local function test_the_review_forms_compact_to_the_wire_bytes()
	for _, name in ipairs({ "resolved", "refusal", "resolved-advisory" }) do
		local wire, review = golden(name), golden_indented(name)

		-- ⚠ THE CONTROL COMES FIRST. Without it, a review form accidentally
		-- vendored in its compact spelling would satisfy every line below
		-- while proving nothing at all.
		assert_true(#review > #wire,
			"the " .. name .. " review form carries no indentation, so this scene "
				.. "would hold whatever the files contained")
		assert_true(review:find("\n", 1, true) ~= nil,
			"the " .. name .. " review form has no newlines: " .. review:sub(1, 60))

		assert_equal(compact_json(review), wire,
			"compacting the " .. name .. " review form must reproduce the wire bytes "
				.. "EXACTLY; if it does not, the two files are not the same response")

		-- And compaction is idempotent on the wire form, which is what says
		-- the wire file carries no insignificant whitespace of its own.
		assert_equal(compact_json(wire), wire,
			"the " .. name .. " wire form must already be compact")
	end
end

-- ⚠ AND THE MODULE MUST READ BOTH THE SAME WAY. JSON permits insignificant
-- whitespace anywhere between tokens, and this module does a RAW-TEXT SCAN —
-- duplicate keys, unknown keys, container types, present-and-null — before it
-- ever decodes. Every golden scene in this file ran on the compact form only,
-- so that scanner had never met a newline or an indent. A proxy that
-- re-serialises, a future encoder, or a server that starts pretty-printing
-- would all arrive as whitespace, and a closed validator that has only seen
-- one spelling is one layer of exactly the gap these files exist for.
local function test_whitespace_does_not_change_the_answer()
	reset()
	next_response_body = golden_indented("resolved")
	local indented = prepare(golden_context())
	assert_unsigned(indented,
		"the indented resolved plan must reach the unsigned refusal: " .. tostring(indented.reason)
			.. " / " .. tostring(indented.detail))

	reset()
	next_response_body = golden("resolved")
	local compact = prepare(golden_context())
	assert_unsigned(compact, "the control: the wire form is used")

	-- Field by field, because "both were used" would hold even if the scanner
	-- had quietly taken a different path through one of them.
	for _, field in ipairs({ "regime", "crash_profile", "server_analytics", "child_rules",
		"analytics_choice_default", "explicit_grant_required", "notice",
		"consent_text_version", "presented_language", "policy_version",
		"band_vocabulary", "band_vocabulary_version", "plan_used", "reason" }) do
		assert_equal(tostring(indented[field]), tostring(compact[field]),
			"whitespace changed the answer for " .. field)
	end

	-- The refusal too: the reason is what identifies one, and it must survive
	-- the same way.
	reset()
	next_response_body = golden_indented("refusal")
	local refusal = prepare(golden_context())
	assert_true(not refusal.plan_used, "the indented refusal must not be used")
	assert_equal(refusal.reason, "invalid_scope",
		"and must still be identified by its reason: " .. tostring(refusal.reason))
	assert_equal(refusal.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
		"with the choice defaulting off")
end

local function test_every_key_the_contract_sends_is_required()
	-- ⚠ OVER BOTH FORMS. The omission rule is about which keys ARRIVED, and
	-- arrival is read off the raw text — so running it only on the compact
	-- spelling left the whole rule untested against the whitespace JSON
	-- permits between every pair of tokens.
	for _, form in ipairs({ "wire", "review" }) do
	local body = form == "wire" and golden("resolved") or golden_indented("resolved")

	-- The control first: unmodified, these bytes reach the unsigned refusal. Without it every
	-- assertion below would also pass against a plan refused for some other
	-- reason entirely.
	reset()
	next_response_body = body
	assert_unsigned(prepare(golden_context()),
		"the control: the resolver's own plan must parse unmodified (" .. form .. ")")

	local checked = 0
	local function omission_is_refused(removed, named)
		reset()
		next_response_body = removed
		local decision = prepare(golden_context())
		assert_true(not decision.plan_used,
			"a plan missing " .. named .. " must not be used")
		assert_true(decision.detail:find("missing the required key " .. named, 1, true) ~= nil,
			"and the reason must NAME " .. named .. ", not describe the damage: "
				.. tostring(decision.detail))
		assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
			"and the choice defaults off")
		checked = checked + 1
	end

	for _, key in ipairs(member_names(body)) do
		omission_is_refused(without_key(body, key), key)
	end
	for _, parent in ipairs({ "flags", "scope", "basis" }) do
		for _, member in ipairs(member_names(body, parent)) do
			omission_is_refused(without_key(body, member, parent), parent .. "." .. member)
		end
	end

	-- ⚠ AND THE COUNT IS ASSERTED, because the loops above are driven by a
	-- text walk: an enumerator that quietly returned nothing would leave this
	-- scene green having tested no key at all — the same silence the nil-hole
	-- sentinel at the bottom of this file exists for.
	assert_equal(checked, 23,
		"the golden plan carries 13 top-level names and 3 + 3 + 4 nested ones; "
			.. "if the contract grew, refresh the golden body and this number "
			.. "(" .. form .. ")")

	-- `reason` is the one name that is NOT required: it marks a refusal rather
	-- than a plan, and the golden resolved body does not carry it at all.
	reset()
	next_response_body = body
	assert_unsigned(prepare(golden_context()),
		"a plan without `reason` is a plan, not a refusal (" .. form .. ")")
	end
end

local function test_the_band_vocabulary_is_shape_checked_only()
	-- ⚠ THE CASE THE COMPARISON BROKE: a caller on its own vocabulary, a
	-- resolver declaring another. The shape parses; the plan is still unsigned.
	reset()
	next_response_body = plan({ band_vocabulary = "coarse" })
	local decision = prepare(context({ age_band = { vocabulary = "acme.bands.v3", band = "adult" } }))
	assert_unsigned(decision,
		"a caller's own vocabulary must not refuse the resolver's declaration: "
			.. tostring(decision.detail))
	assert_true(decision.band_vocabulary == nil, "unauthenticated band_vocabulary is not carried")
	assert_true(decision.band_vocabulary_version == nil, "unauthenticated band_vocabulary_version is not carried")

	-- The shape is still checked: missing, empty or over its bound is malformed.
	for _, override in ipairs({
		{ band_vocabulary = "__nil__" },
		{ band_vocabulary_version = "__nil__" },
		{ band_vocabulary = "" },
		{ band_vocabulary = string.rep("x", 33) },
	}) do
		reset()
		next_response_body = plan(override)
		assert_equal(prepare().reason, "invalid_response", "a malformed band vocabulary must not be used")
	end
end


local function test_unsigned_notice_text_is_not_authority()
	reset()
	next_response_body = golden("resolved")
	local decision = prepare(golden_context())
	assert_unsigned(decision, "the complete notice parses")
	assert_true(decision.notice == nil, "unsigned notice text cannot replace the host notice")
end


local function test_unsigned_regimes_cannot_change_the_local_default()
	for _, regime in ipairs({ consent_policy.STRICT_OPT_IN, consent_policy.UNKNOWN, consent_policy.SOFT_OPT_OUT }) do
		reset()
		next_response_body = plan({ regime = regime })
		local decision = prepare()
		assert_unsigned(decision, regime)
		assert_equal(decision.regime, consent_policy.STRICT_OPT_IN)
		assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF)
		assert_equal(decision.explicit_grant_required, true)
	end
end

-- ⚠ THE HAZARD THE SENTINEL AT THE BOTTOM OF THIS FILE EXISTS FOR, kept as a
-- test rather than as a one-off check: ipairs STOPS at a nil hole. A scene
-- renamed or deleted but left in the `tests` list is exactly that, and every
-- scene after it silently never runs. It happened here during the contract
-- migration and the suite stayed green.
--
-- HONEST LIMIT: this proves the LANGUAGE behaves that way. The sentinel proves
-- the suite noticed, and it was checked by hand with a fake name.
local function test_ipairs_stops_at_a_nil_hole()
	local holed = { function() end }
	holed[3] = function() end
	local ran = 0
	for _ in ipairs(holed) do
		ran = ran + 1
	end
	assert_equal(ran, 1, "ipairs walks to the first hole and stops — silently")
	local total = 0
	for _ in pairs(holed) do
		total = total + 1
	end
	assert_equal(total, 2, "while the entries after it are still there, unrun")
end

-- Derive the fixture from the vendored wire body; only the scene's blocks,
-- scope, expiry and zero cache lifetime differ. The decoder erases JSON null,
-- so restore its sentinel before encoding. The golden files are never edited.
local function golden_block_plan(blocks, ctx, overrides)
	local body = json_decode(golden("resolved"))
	body.signature = NULL
	body.flags.operation_blocks = blocks
	body.scope = { workspace_key = ctx.workspace_key, app_key = ctx.app_key,
		environment_key = ctx.environment_key }
	body.expires_at = "2099-01-01T00:00:00Z"
	body.max_age_seconds = 0
	for key, value in pairs(overrides or {}) do
		body[key] = value
	end
	return encode_value(body)
end


local function test_operation_blocks_remain_unknown_across_fallbacks()
	local cases = { "refusal", "malformed", "timeout", "signature", "out_of_scope",
		"expired", "transport", "decoder", "encoder", "encode_error", "clock" }
	local reasons = { refusal = "invalid_scope", malformed = "invalid_response",
		timeout = "deadline_exceeded", signature = "invalid_response",
		out_of_scope = "invalid_response", expired = "invalid_response",
		transport = "transport_unavailable", decoder = "decoder_unavailable",
		encoder = "encoder_unavailable", encode_error = "encoder_failed",
		clock = "clock_unavailable" }
	for _, mode in ipairs(cases) do
		reset()
		local ctx = golden_context()
		next_response_body = golden_block_plan({ "cross_border_transfer", "profiling_under_16" }, ctx)
		assert_unsigned(prepare(ctx), "unverified blocks are not learned")
		local saved_http, saved_json, saved_socket, saved_os = http, json, socket, os
		next_response_body = "not JSON"
		if mode == "refusal" then
			next_status, next_response_body = 400, golden("refusal")
		elseif mode == "timeout" then
			http = { request = function(...)
				socket.now = socket.now + 3
				saved_http.request(...)
			end }
		elseif mode == "signature" then
			next_response_body = golden_block_plan({}, ctx, { signature = "unverified-fixture" })
		elseif mode == "out_of_scope" then
			next_response_body = golden_block_plan({}, context({ app_key = "another-app" }))
		elseif mode == "expired" then
			next_response_body = golden_block_plan({}, ctx, { expires_at = "1970-01-01T00:00:00Z" })
		elseif mode == "transport" then
			http = nil
		elseif mode == "decoder" then
			json = { encode = saved_json.encode }
		elseif mode == "encoder" then
			json = { decode = saved_json.decode }
		elseif mode == "encode_error" then
			json = { decode = saved_json.decode, encode = function() error("fixture encoder failure") end }
		elseif mode == "clock" then
			socket, os = nil, {}
		end
		local ok, decision = pcall(prepare, ctx)
		http, json, socket, os = saved_http, saved_json, saved_socket, saved_os
		assert_true(ok, mode .. " must return a decision")
		assert_true(not decision.plan_used, mode .. " must reach a fallback")
		assert_equal(decision.reason, reasons[mode], mode .. " reaches the intended refusal")
		assert_true(decision.operation_blocks == nil, mode .. " leaves the block set unknown")
		assert_equal(decision.operation_blocks_source, "none")
		assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF)
		assert_equal(decision.crash_profile, consent_policy.CRASH_OFF)
	end
	print("operation-block fallback cases passed: " .. #cases)
end


local function test_context_change_fences_pending_responses()
	reset()
	local first, second = golden_context(), golden_context()
	second.app_key = "second-app"
	local saved_request, pending, stale = http.request
	http.request = function(_, _, callback) pending = callback end
	consent_policy.prepare(first, function(decision) stale = decision end)
	http.request = saved_request
	next_response_body = golden_block_plan({}, second)
	assert_unsigned(prepare(second), "the new context is also unsigned")
	pending(nil, nil, { status = 200, response = golden_block_plan({}, first) })
	assert_equal(stale.reason, "invalidated", "changing context fences the in-flight response")
	assert_true(stale.operation_blocks == nil)
end


local function test_caller_mutation_cannot_relabel_request_scope()
	reset()
	local ctx = golden_context()
	local saved_request, pending, decision = http.request
	http.request = function(_, _, callback) pending = callback end
	consent_policy.prepare(ctx, function(value) decision = value end)
	http.request = saved_request
	ctx.app_key = "mutated-after-dispatch"
	pending(nil, nil, { status = 200, response = golden_block_plan({}, ctx) })
	assert_equal(decision.reason, "invalid_response")
	assert_equal(decision.detail, "the plan is scoped to another app, environment or workspace")
	assert_true(decision.operation_blocks == nil)
end



-- ===== THE ADVISORY PART =====
--
-- The resolver can serve, beside a plan, a non-binding estimate for the
-- connection's jurisdiction: only to a request that asked for it, only for a
-- workspace admitted to it, and never in place of the plan. These scenes run
-- on the resolver's own advisory bytes.

-- The request the golden ADVISORY body answers: the resolved request, plus
-- the opt-in.
local function golden_advisory_context()
	local ctx = golden_context()
	ctx.advisory = true
	return ctx
end

-- The resolver's advisory bytes with one edit, and the edit is ASSERTED to
-- have applied: a replacement that matched nothing would leave the scene
-- testing the unmodified body, which is used.
local function advisory_body(from, to, form)
	local body = form == "review" and golden_indented("resolved-advisory") or golden("resolved-advisory")
	if not from then
		return body
	end
	local start = body:find(from, 1, true)
	assert(start, "the advisory golden does not contain " .. from)
	return body:sub(1, start - 1) .. to .. body:sub(start + #from)
end

-- The value span of one advisory member (or, with `matrix`, of one matrix
-- member), located by the same depth-aware walk the omission scenes use.
local function advisory_member_span(body, name, in_matrix)
	local _, from, to = member_span(body, "advisory", 1, #body)
	assert(from, "the body carries no advisory")
	if in_matrix then
		_, from, to = member_span(body, "matrix", from, to)
		assert(from, "the advisory carries no matrix")
	end
	return member_span(body, name, from, to)
end

local function with_advisory_value(body, name, raw_value, in_matrix)
	local _, value_from, value_to = advisory_member_span(body, name, in_matrix)
	assert(value_from, "no advisory member named " .. name)
	return body:sub(1, value_from - 1) .. raw_value .. body:sub(value_to + 1)
end

local function without_advisory_member(body, name, in_matrix)
	local pair_from, _, value_to, closer = advisory_member_span(body, name, in_matrix)
	assert(pair_from, "no advisory member named " .. name)
	local cut_to = value_to
	if closer == "," then
		cut_to = value_to + 1
	else
		local back = pair_from - 1
		while back > 1 and body:sub(back, back):match("[ \t\r\n]") do
			back = back - 1
		end
		if body:sub(back, back) == "," then
			pair_from = back
		end
	end
	return body:sub(1, pair_from - 1) .. body:sub(cut_to + 1)
end

local ADVISORY_MEMBERS = {
	"jurisdiction", "estimate", "row_id", "row_status", "row_basis", "advisory_basis", "matrix", "resolved_by",
}
local MATRIX_MEMBERS = { "docs_commit", "file_sha256", "date" }

local function assert_refused(decision, label)
	assert_true(not decision.plan_used, label .. " must not be used")
	assert_equal(decision.reason, "invalid_response", label)
	assert_true(decision.advisory == nil, label .. " must not reach the host")
	assert_equal(decision.analytics_choice_default, consent_policy.CHOICE_DEFAULT_OFF,
		label .. ": the choice defaults off")
end

-- ASKED FOR, NEVER ASSUMED. The version 3 request omits the advisory member
-- without the opt-in; with it, the member travels as a boolean. Other values
-- are refused before a byte leaves.
local function test_the_advisory_is_asked_for_only_when_requested()
	for _, override in ipairs({ {}, { advisory = false } }) do
		reset()
		next_response_body = plan()
		local decision = prepare(context(override))
		assert_unsigned(decision, "the control: " .. tostring(decision.detail))
		assert_true(requests[1].body:find('"advisory"', 1, true) == nil,
			"a request that did not ask must not carry the member: " .. requests[1].body)
		assert_true(decision.advisory == nil, "and the decision carries no advisory")
	end

	reset()
	next_response_body = golden("resolved-advisory")
	prepare(golden_advisory_context())
	assert_true(requests[1].body:find('"advisory":true', 1, true) ~= nil,
		"the opt-in travels as the boolean true: " .. requests[1].body)

	for _, value in ipairs({ "true", 1, {}, "yes" }) do
		reset()
		next_response_body = golden("resolved-advisory")
		local decision, calls = prepare(context({ advisory = value }))
		assert_equal(calls, 1, "exactly one callback")
		assert_equal(#requests, 0, "a malformed opt-in must cost zero requests")
		assert_equal(decision.reason, "invalid_request")
	end
end


local function test_the_resolvers_advisory_bytes_are_understood()
	for _, form in ipairs({ "wire", "review" }) do
		reset()
		next_response_body = advisory_body(nil, nil, form)
		local decision = prepare(golden_advisory_context())
		assert_unsigned(decision, "the advisory shape parses (" .. form .. ")")
		assert_true(decision.advisory == nil, "unauthenticated advisory data is not forwarded")
	end
	reset()
	next_response_body = golden("resolved")
	assert_unsigned(prepare(golden_advisory_context()), "an absent optional advisory also parses")
end

-- ⚠ IT NEVER CHANGES THE DECISION. The same plan with and without its advisory
-- part — whatever the estimate — gives the same answer to every question a
-- host branches on.
local function test_the_advisory_never_changes_the_decision()
	reset()
	next_response_body = golden("resolved")
	local without = prepare(golden_context())
	assert_unsigned(without, "the control: " .. tostring(without.detail))

	for _, variant in ipairs({
		{ "SOFT_OPT_OUT", nil },
		{ "STRICT_OPT_IN", '"STRICT_OPT_IN"' },
		{ "no estimate", "null" },
	}) do
		reset()
		local body = golden("resolved-advisory")
		if variant[2] then
			body = with_advisory_value(body, "estimate", variant[2])
		end
		next_response_body = body
		local with = prepare(golden_advisory_context())
		assert_unsigned(with, variant[1] .. ": " .. tostring(with.detail))
		assert_true(with.advisory == nil, variant[1] .. ": the advisory remains unauthenticated")
		for _, field in ipairs({ "regime", "crash_profile", "server_analytics", "child_rules",
			"analytics_choice_default", "explicit_grant_required", "plan_used", "reason",
			"policy_version", "consent_text_version", "presented_language", "notice",
			"band_vocabulary", "band_vocabulary_version", "operation_blocks_source" }) do
			assert_equal(tostring(with[field]), tostring(without[field]),
				variant[1] .. ": the advisory changed " .. field)
		end
		assert_equal(with.operation_blocks, without.operation_blocks,
			variant[1] .. ": the advisory changed the operation blocks")
	end
end


-- Every advisory member the resolver sends is required once the part is
-- present, and the refusal NAMES it. Driven from the recorded bytes.
local function test_every_advisory_member_is_required()
	for _, form in ipairs({ "wire", "review" }) do
		local body = advisory_body(nil, nil, form)
		local checked = 0
		local function omission_is_refused(removed, named)
			reset()
			next_response_body = removed
			local decision = prepare(golden_advisory_context())
			assert_refused(decision, "a plan missing " .. named .. " (" .. form .. ")")
			assert_true(decision.detail:find("missing the required key " .. named, 1, true) ~= nil,
				"and the reason must NAME " .. named .. ": " .. tostring(decision.detail))
			checked = checked + 1
		end
		for _, member in ipairs(member_names(body, "advisory")) do
			omission_is_refused(without_advisory_member(body, member), "advisory." .. member)
		end
		for _, member in ipairs(MATRIX_MEMBERS) do
			omission_is_refused(without_advisory_member(body, member, true), "advisory.matrix." .. member)
		end
		assert_equal(checked, 11, "the advisory carries 8 members and its matrix 3 (" .. form .. ")")
	end
end

-- ⚠ ONE ADVISORY MEMBER MAY BE NULL, AND THE ADVISORY ITSELF IS NOT IT.
local function test_only_the_estimate_may_be_null()
	local body = golden("resolved-advisory")
	for _, member in ipairs(ADVISORY_MEMBERS) do
		reset()
		next_response_body = with_advisory_value(body, member, "null")
		local decision = prepare(golden_advisory_context())
		if member == "estimate" then
			assert_unsigned(decision, "a null estimate is the contract's own spelling: " .. tostring(decision.detail))
			assert_true(decision.advisory == nil, "no unauthenticated advisory reaches the host")
		else
			assert_refused(decision, "a null advisory." .. member)
			assert_true(decision.detail:find("advisory." .. member .. " is present and null", 1, true) ~= nil,
				"named: " .. tostring(decision.detail))
		end
	end
	for _, member in ipairs(MATRIX_MEMBERS) do
		reset()
		next_response_body = with_advisory_value(body, member, "null", true)
		assert_refused(prepare(golden_advisory_context()), "a null advisory.matrix." .. member)
	end
	reset()
	local _, from, to = member_span(body, "advisory", 1, #body)
	next_response_body = body:sub(1, from - 1) .. "null" .. body:sub(to + 1)
	local decision = prepare(golden_advisory_context())
	assert_refused(decision, "a null advisory")
end

-- The shapes the contract permits beyond the recorded one are all used.
local function test_the_advisory_shapes_the_contract_permits()
	local body = golden("resolved-advisory")
	local function set(b, member, raw) return with_advisory_value(b, member, raw) end
	for _, case in ipairs({
		{ "an unresolved connection", set(set(set(set(body, "jurisdiction", '"OTHER"'), "row_id", '"OTHER"'),
			"estimate", "null"), "resolved_by", '"unknown"'), "OTHER", nil },
		{ "a located country without its own row", set(set(set(body, "jurisdiction", '"OTHER"'), "row_id", '"OTHER"'),
			"estimate", "null"), "OTHER", nil },
		{ "a row without an estimate", set(set(set(body, "jurisdiction", '"TD"'), "row_id", '"TD"'),
			"estimate", "null"), "TD", nil },
		{ "a STRICT_OPT_IN estimate", set(body, "estimate", '"STRICT_OPT_IN"'), "GB", "STRICT_OPT_IN" },
		{ "a basis at exactly the bound", set(body, "advisory_basis", '"' .. string.rep("a", 2048) .. '"'),
			"GB", "SOFT_OPT_OUT" },
	}) do
		reset()
		next_response_body = case[2]
		local decision = prepare(golden_advisory_context())
		assert_unsigned(decision, case[1] .. ": " .. tostring(decision.detail))
		assert_true(decision.advisory == nil, case[1] .. ": unauthenticated data stays unused")
	end
end

-- ⚠ AND EVERY SHAPE OUTSIDE IT MAKES THE PLAN UNREADABLE.
local function test_the_advisory_vocabulary_is_closed()
	local body = golden("resolved-advisory")
	local function set(member, raw, in_matrix)
		return with_advisory_value(body, member, raw, in_matrix)
	end
	local cases = {
		{ "jurisdiction in lower case", set("jurisdiction", '"gb"') },
		{ "jurisdiction of three letters", set("jurisdiction", '"GBR"') },
		{ "jurisdiction empty", set("jurisdiction", '""') },
		{ "jurisdiction OTHERS", set("jurisdiction", '"OTHERS"') },
		{ "jurisdiction as a number", set("jurisdiction", "1") },
		{ "row_id with a digit", set("row_id", '"G1"') },
		{ "estimate outside the vocabulary", set("estimate", '"UNKNOWN"') },
		{ "estimate in lower case", set("estimate", '"soft_opt_out"') },
		{ "estimate as an object", set("estimate", "{}") },
		{ "row_status claims review", set("row_status", '"REVIEWED"') },
		{ "row_basis claims acceptance", set("row_basis", '"owner_accepted"') },
		{ "resolved_by outside the vocabulary", set("resolved_by", '"geoip"') },
		{ "an unresolved connection that names a country", set("resolved_by", '"unknown"') },
		{ "OTHER with an estimate", with_advisory_value(with_advisory_value(body, "jurisdiction", '"OTHER"'),
			"row_id", '"OTHER"') },
		-- The row is the jurisdiction's own, or OTHER for both.
		{ "an OTHER row with an estimate under a country", set("row_id", '"OTHER"') },
		{ "an OTHER row without an estimate under a country",
			with_advisory_value(set("row_id", '"OTHER"'), "estimate", "null") },
		{ "another country's row", set("row_id", '"FR"') },
		{ "a country's row under OTHER",
			with_advisory_value(set("jurisdiction", '"OTHER"'), "estimate", "null") },
		{ "basis empty", set("advisory_basis", '""') },
		{ "basis one byte over the bound", set("advisory_basis", '"' .. string.rep("a", 2049) .. '"') },
		{ "basis with a newline", set("advisory_basis", '"estimate\\nforged: everything is fine"') },
		{ "basis with a tab", set("advisory_basis", '"a\\tb"') },
		{ "basis with DEL", set("advisory_basis", '"a\127b"') },
		-- C1 controls, as the UTF-8 a JSON decoder yields for them: %c, an
		-- ASCII class, does not see them.
		{ "basis with U+0085 NEXT LINE", set("advisory_basis", '"estimate\194\133forged: everything is fine"') },
		{ "basis with U+0080", set("advisory_basis", '"a\194\128b"') },
		{ "basis with U+009F", set("advisory_basis", '"a\194\159b"') },
		{ "docs_commit in upper case", set("docs_commit", '"F6B6F0F617D4E15442608FC77BE8A5BB40F40E26"', true) },
		{ "docs_commit one character short", set("docs_commit", '"f6b6f0f617d4e15442608fc77be8a5bb40f40e2"', true) },
		{ "file_sha256 one character short",
			set("file_sha256", '"370b04f374d0c506b92a003d4c801f450d5e5c45aed369f14a1c9382e3d592c"', true) },
		{ "date without leading zeros", set("date", '"2026-10-7"', true) },
		{ "date that does not exist", set("date", '"2026-02-30"', true) },
		{ "date as a timestamp", set("date", '"2026-10-07T00:00:00Z"', true) },
		{ "matrix as a string", set("matrix", '"f6b6f0f6"') },
		{ "matrix as a list", set("matrix", "[]") },
		{ "an unknown advisory member", advisory_body('"advisory":{', '"advisory":{"note":"x",') },
		{ "an unknown matrix member", advisory_body('"matrix":{', '"matrix":{"branch":"main",') },
		{ "estimate twice", advisory_body('"estimate":"SOFT_OPT_OUT"',
			'"estimate":"STRICT_OPT_IN","estimate":"SOFT_OPT_OUT"') },
		{ "estimate twice, once escaped", advisory_body('"estimate":"SOFT_OPT_OUT"',
			'"\\u0065stimate":"STRICT_OPT_IN","estimate":"SOFT_OPT_OUT"') },
	}
	local _, from, to = member_span(body, "advisory", 1, #body)
	cases[#cases + 1] = { "the advisory as a string", body:sub(1, from - 1) .. '"SOFT_OPT_OUT"' .. body:sub(to + 1) }
	cases[#cases + 1] = { "the advisory as a list", body:sub(1, from - 1) .. "[]" .. body:sub(to + 1) }
	-- Where the raw text is the only witness, the refusal must NAME it: a list
	-- decodes to a table, so only the scan can say it was not an object.
	local named = {
		["matrix as a list"] = "advisory.matrix is not an object",
		["the advisory as a list"] = "advisory is not an object",
		["an unknown advisory member"] = "advisory carries an unknown key",
		["an unknown matrix member"] = "advisory.matrix carries an unknown key",
		["estimate twice"] = "advisory carries the key estimate twice",
		["estimate twice, once escaped"] = "advisory carries the key estimate twice",
	}
	for _, case in ipairs(cases) do
		assert_true(case[2] ~= body, case[1] .. ": the mutation did not apply")
		reset()
		next_response_body = case[2]
		local decision = prepare(golden_advisory_context())
		assert_refused(decision, case[1])
		if named[case[1]] then
			assert_true(decision.detail:find(named[case[1]], 1, true) ~= nil,
				case[1] .. " must be named: " .. tostring(decision.detail))
		end
	end

	-- An advisory this request did not ask for is an answer to another question.
	reset()
	next_response_body = body
	assert_refused(prepare(golden_context()), "an advisory nobody asked for")
end

-- A refusal is settled by its reason, and whatever else it carries never
-- reaches the host.
local function test_a_refusal_never_carries_an_advisory()
	local body = golden("resolved-advisory")
	local _, from, to = member_span(body, "advisory", 1, #body)
	local advisory = body:sub(from, to)
	reset()
	next_response_body = golden("refusal"):sub(1, -2) .. ',"advisory":' .. advisory .. "}"
	local decision = prepare(golden_advisory_context())
	assert_true(not decision.plan_used, "a refusal is not a plan")
	assert_equal(decision.reason, "invalid_scope", "and keeps its own reason")
	assert_true(decision.advisory == nil, "and no advisory reaches the host from it")
end


local function test_scope_key_wire_contract()
	local passed, failed = 0, 0
	local function scene(name, run)
		local ok, err = pcall(run)
		if ok then passed = passed + 1 else failed = failed + 1; print("FAIL scope wire: " .. name .. ": " .. tostring(err)) end
	end
	local axes = { "workspace", "app", "environment" }
	for _, advisory in ipairs({ false, true }) do
		scene("request advisory=" .. tostring(advisory), function()
			reset()
			local ctx = golden_context(); ctx.advisory = advisory
			next_response_body = golden(advisory and "resolved-advisory" or "resolved")
			local decision, calls = prepare(ctx)
			assert_equal(calls, 1); assert_equal(#requests, 1)
			local sent = json.decode(requests[1].body)
			local expected = { workspace_key = ctx.workspace_key, app_key = ctx.app_key,
				environment_key = ctx.environment_key, app_version = ctx.app_version,
				locale = ctx.locale, platform = ctx.platform, store = ctx.store }
			if advisory then expected.advisory = true end
			for key, value in pairs(expected) do assert_equal(sent[key], value, key) end
			for key in pairs(sent) do assert_true(expected[key] ~= nil, "unexpected request field " .. key) end
			assert_unsigned(decision, tostring(decision.reason))
		end)
	end
	for _, axis in ipairs({ "workspace", "app", "environment", "all" }) do
		for _, mixed in ipairs({ false, true }) do
			scene("context " .. axis .. " mixed=" .. tostring(mixed), function()
				reset()
				local ctx = golden_context()
				for _, field in ipairs(axis == "all" and axes or { axis }) do
					ctx[field .. "_id"] = ctx[field .. "_key"]
					if not mixed then ctx[field .. "_key"] = nil end
				end
				local decision, calls = prepare(ctx)
				assert_equal(calls, 1); assert_equal(#requests, 0)
				assert_equal(decision.reason, "invalid_request")
			end)
		end
	end
	for _, read in ipairs({ golden, golden_indented }) do
		for _, name in ipairs({ "resolved", "refusal", "resolved-advisory" }) do
			local function response(body, malformed)
				reset()
				next_response_body = body
				if name == "refusal" then next_status = 400 end
				local ctx = golden_context(); ctx.advisory = name == "resolved-advisory"
				local decision, calls = prepare(ctx)
				assert_equal(calls, 1); assert_equal(#requests, 1)
				if name == "refusal" then
					-- Refusals never become plans; their scope is not consumed.
					assert_equal(decision.reason, "invalid_scope")
					assert_true(not decision.plan_used)
				elseif malformed then
					assert_equal(decision.reason, "invalid_response")
					assert_true(not decision.plan_used)
				else assert_unsigned(decision, tostring(decision.reason)) end
			end
			scene(name .. " canonical", function() response(read(name), false) end)
			if name ~= "refusal" then
				for _, axis in ipairs(axes) do
					scene(name .. " foreign " .. axis, function()
						reset(); next_response_body = read(name)
						local ctx = golden_context(); ctx[axis .. "_key"] = "other-scope"
						ctx.advisory = name == "resolved-advisory"
						local decision, calls = prepare(ctx)
						assert_equal(calls, 1); assert_equal(#requests, 1)
						assert_true(not decision.plan_used)
						assert_equal(decision.reason, "invalid_response")
						assert_equal(decision.detail, "the plan is scoped to another app, environment or workspace")
					end)
				end
			end
			for _, axis in ipairs({ "workspace", "app", "environment", "all" }) do
				for _, mixed in ipairs({ false, true }) do
					scene(name .. " " .. axis .. " mixed=" .. tostring(mixed), function()
						local body = read(name)
						for _, field in ipairs(axis == "all" and axes or { axis }) do
							local key = '"' .. field .. '_key"'
							local replacement = '"' .. field .. '_id"'
							if mixed then replacement = replacement .. ':null,' .. key end
							local count; body, count = body:gsub(key, replacement, 1)
							assert_equal(count, 1, "golden must carry " .. key)
						end
						response(body, true)
					end)
				end
			end
		end
	end
	print("scope wire scenes: " .. passed .. " passed, " .. failed .. " failed")
	assert_equal(failed, 0, "scope wire contract")
end

local tests = {
	test_no_unauthenticated_plan_has_authority,
	test_scope_key_wire_contract,
	test_operation_blocks_remain_unknown_across_fallbacks,
	test_context_change_fences_pending_responses,
	test_caller_mutation_cannot_relabel_request_scope,
	test_a_well_formed_unsigned_plan_is_unused,
	test_the_module_touches_no_sdk_state,
	test_an_outage_after_an_unsigned_plan_stays_closed,
	test_a_late_response_is_dropped,
	test_a_refused_value_costs_no_request,
	test_every_malformed_plan_is_strict,
	test_unknown_closes_optional_processing,
	test_unsigned_responses_are_never_cached,
	test_expiry_is_validated_before_authentication,
	test_an_invalidated_request_cannot_answer,
	test_a_json_object_is_not_an_empty_list,
	test_an_invalid_endpoint_is_an_invalid_request,
	test_an_empty_signature_is_still_a_signature,
	test_the_url_predicate_is_a_verbatim_copy,
	test_a_signal_must_state_its_availability_as_a_boolean,
	test_fallback_decisions_are_independent,
	test_example_stays_closed_without_authenticated_restrictions,
	test_an_older_response_cannot_overwrite_a_newer_one,
	test_an_encoder_failure_still_answers,
	test_unsigned_soft_cannot_authorize_an_offline_call,
	test_the_clock_falls_back_to_os_time,
	test_an_empty_object_is_not_an_empty_list,
	test_an_offset_needs_its_colon,
	test_an_escaped_key_cannot_hide_an_object,
	test_second_sixty_is_refused,
	test_the_signature_is_present_and_null_or_refused,
	test_clock_change_cannot_authorize_an_unsigned_plan,
	test_a_null_list_is_not_an_absent_one,
	test_an_unknown_top_level_key_is_refused,
	test_a_duplicate_top_level_key_is_refused,
	test_a_clock_rollback_during_the_request_is_refused,
	test_no_schema_field_is_nullable,
	test_a_null_list_entry_is_refused,
	test_an_error_envelope_keeps_its_reason,
	test_nested_duplicate_keys_are_refused,
	test_an_unknown_context_field_is_refused,
	test_a_null_field_inside_a_signal_is_refused,
	test_a_signal_reason_is_always_from_the_vocabulary,
	test_the_packaged_skill_snippets_compile,
	test_the_context_age_bands_keys_are_closed,
	test_every_schema_object_has_a_closed_key_set,
	test_an_unknown_offset_is_refused,
	test_the_public_surface_is_prepare_and_invalidate,
	test_the_resolvers_own_bytes_are_understood,
	test_every_plan_enum_is_closed,
	test_the_review_forms_compact_to_the_wire_bytes,
	test_whitespace_does_not_change_the_answer,
	test_every_key_the_contract_sends_is_required,
	test_the_band_vocabulary_is_shape_checked_only,
	test_unsigned_notice_text_is_not_authority,
	test_unsigned_regimes_cannot_change_the_local_default,
	test_ipairs_stops_at_a_nil_hole,
	test_the_advisory_is_asked_for_only_when_requested,
	test_the_resolvers_advisory_bytes_are_understood,
	test_the_advisory_never_changes_the_decision,
	test_every_advisory_member_is_required,
	test_only_the_estimate_may_be_null,
	test_the_advisory_shapes_the_contract_permits,
	test_the_advisory_vocabulary_is_closed,
	test_a_refusal_never_carries_an_advisory,
}

-- ⚠ ipairs STOPS AT A NIL HOLE, SILENTLY. A scene renamed or deleted but left
-- in the list above is a nil entry, and every scene AFTER it simply never runs
-- — the suite goes green having skipped half of itself. That happened during
-- the contract migration: five scenes were lost in an edit and four
-- mutants "survived" that were in fact never tested. This sentinel is the
-- cheapest thing that makes it impossible to miss again.
local reached_the_end = false
tests[#tests + 1] = function()
	reached_the_end = true
end

for _, test in ipairs(tests) do
	test()
end

assert_true(reached_the_end,
	"the suite stopped early: `tests` has a nil entry — a scene named in the list " ..
	"that no longer exists — and every scene after it was skipped")

print("shardpilot defold consent-policy tests passed")
