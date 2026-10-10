-- Consent-regime policy preparation, and the ONE thing to understand about it:
-- it runs BEFORE the telemetry SDK exists.
--
-- ⚠ IT IMPORTS NO SDK RUNTIME. Not sdk.lua, not client.lua, not
-- queue.lua, not storage.lua, not id.lua. That is a design rule rather than a
-- preference: requiring storage would create the persisted scope record and
-- requiring id would mint an anonymous identifier, and the first-run contract
-- forbids any SDK init, identity generation, spool load, capture hook or
-- buffered event before the player's final choice. A module that quietly
-- created one of those would break the rule it exists to serve.
-- Its shared consent-version predicate is pure and touches no runtime state.
--
-- WHAT IT IS NOT:
--   * not a consent grant — a plan says which regime applies, never that a
--     player agreed to anything;
--   * not permission to send anything — a valid plan is still not admission;
--   * not a geolocator — no address is read here, and a plan carrying no
--     country is normal rather than an error. The optional ADVISORY part, when
--     the host asks for it, carries the resolver's own reading of the
--     connection's jurisdiction; that reading is validated, never made here;
--   * not persistent — nothing is written to disk. A cached plan on disk would
--     outlive the session this contract scopes it to.
--
-- No authenticated plan means no plan authority. This build has no verifier
-- or trusted signing key, so every response is unused, including a well-formed
-- plan with signature: null. Shape, scope and time validation still distinguish
-- malformed responses from well-formed unsigned ones.
--
-- The local fallback is STRICT, default OFF, explicit grant required, crash
-- OFF, server analytics denied and child handling minimised. Its operation
-- block set is UNKNOWN (nil), never an empty authorized set. A host must keep
-- plan-dependent operations closed while that set is unknown; an explicit
-- consent grant alone cannot supply the missing policy authority.
-- Nothing from an unauthenticated response is cached or retained as a policy.

local M = {}
local version_ok = require "shardpilot.consent_version"

M.STRICT_OPT_IN = "STRICT_OPT_IN"
M.SOFT_OPT_OUT = "SOFT_OPT_OUT"
M.UNKNOWN = "UNKNOWN"

-- The resolver returns a nested plan with case-sensitive values such as
-- "off", "minimal_diagnostics_for_minors" and "denied". A flat plan or
-- uppercase variants do not satisfy that contract. These constants follow
-- the resolver's published OpenAPI schema (ConsentPolicyPlan).
M.CRASH_OFF = "off"
M.CRASH_MINIMAL = "minimal_diagnostics_for_minors"

M.SERVER_ANALYTICS_DENIED = "denied"

M.CHILD_RULES_MINIMISED = "minimised"

-- These constants also describe the wire vocabulary. Only OFF is returned by
-- this build; a parsed SOFT value has no authority without authentication.
M.CHOICE_DEFAULT_OFF = "off"
M.CHOICE_DEFAULT_ON = "on"

-- The route is public API surface; the schema it speaks has exactly one
-- published copy, beside the resolver's own contract.
local ROUTE = "/api/cp/v1/consent/policy"

-- The total deadline for the whole preparation, in seconds. A late response
-- cannot change a screen that has already been presented, so one that arrives
-- after this is DROPPED rather than delivered: two callbacks would be worse
-- than a slow one.
local DEADLINE_SECONDS = 2

-- Bounds, mirrored from the published schema so a value outside them is
-- refused HERE rather than sent and refused there. A refusal that costs a
-- request is a refusal that told a server something about this player.
local MAX_LANGUAGE = 35
local MAX_BAND = 32
local MAX_ENTRY = 64
local MAX_ENTRIES = 64
local MAX_SIGNALS = 16
local MAX_BODY = 16 * 1024
local MAX_ENDPOINT = 256
-- Bound the wire notice without interpreting or forwarding unauthenticated text.
local MAX_NOTICE = 2048
-- advisory.advisory_basis is the matrix row's basis in its own words, with the
-- same published bound.
local MAX_ADVISORY_BASIS = 2048

local STORES = { steam = true, apple = true, google_play = true, standalone = true }
local PLATFORMS = {
	windows = true, macos = true, linux = true, android = true, ios = true, web = true,
}
local SIGNAL_REASONS = {
	source_not_permitted = true, source_unavailable = true, not_enabled_in_release = true,
}

-- ⚠ EACH ENUM HOLDS THE VALUES THE CONTRACT NAMES TODAY, AND AN UNKNOWN VALUE
-- IS A REFUSAL — never a permissive plan. Where the contract names one value,
-- one value is what is here: a second one arrives in the release that adds it,
-- in both repositories at once, with the golden body that proves it.
local CRASH_PROFILES = { off = true, minimal_diagnostics_for_minors = true }
local SERVER_ANALYTICS = { denied = true }
local CHILD_RULES = { minimised = true }
local BASIS_CHARACTERS = { informational_reference = true }
local TABLE_PROVENANCES = { ai_draft = true, owner_accepted = true }
-- The advisory part's own vocabularies. ITS ESTIMATE IS NOT A REGIME: the two
-- spellings coincide, and nothing in this module ever reads one as the other.
local ADVISORY_ESTIMATES = { SOFT_OPT_OUT = true, STRICT_OPT_IN = true }
local ADVISORY_ROW_STATUSES = { COUNSEL_PENDING = true }
local ADVISORY_ROW_BASES = { ai_draft = true }
local ADVISORY_RESOLVED_BY = { server_country = true, unknown = true }
local ADVISORY_OTHER = "OTHER"

-- The resolver's closed refusal vocabulary. A reason outside it is reported as
-- the generic one rather than echoed into a caller's control flow.
local REFUSAL_REASONS = {
	invalid_request = true, invalid_scope = true, store_region_not_accepted = true,
	unsupported_app_version = true, policy_unavailable = true,
}

-- Context epochs fence in-flight callbacks; no unauthenticated plan is cached.
local active_context = nil

-- A response must belong to the current context epoch.
local generation = 0

-- Same-context requests share an epoch. Only the latest dispatch may finish
-- parsing; an older one gets a distinct superseded fallback.
local dispatch_counter = 0
local latest_dispatch = {}

-- ⚠ THE EMPTY OBJECT IS CAUGHT BEFORE THE DECODE, BECAUSE AFTER IT THERE IS
-- NOTHING LEFT TO CATCH IT WITH. Defold's json.decode returns a plain Lua
-- table for both `{}` and `[]` and marks neither, so by the time the plan is a
-- table the container type has been ERASED — the previous note here said that
-- and stopped, which left `"operation_blocks": {}` reading as "no operation
-- blocks" and being used.
--
-- The raw response text is the only place the distinction still exists, so it
-- is read there: a schema list key followed by `{` is malformed. That is the
-- ONLY container-type signal available in this SDK, which is why this looks
-- like string matching in a parser rather than a type check.
-- Top-level arrays. operation_blocks moved INSIDE flags with the contract, so
-- it is checked in the flags branch of the scan rather than here.
local LIST_KEYS = { signals_used = true }

-- ⚠ THE COMPLETE TOP-LEVEL VOCABULARY, and it is CLOSED. Every other bounded
-- value in this module is checked against a closed set; the set of FIELD NAMES
-- was the one that was not, so a plan could carry anything at all beside the
-- ones we read and still be used. A key we do not understand is a plan we
-- cannot say we fully read, and "use the parts I understood" is how a
-- permissive default gets in.
-- Every object in this schema has an exact key set. Keep the nested sets
-- together so that each added object has an explicit allowed vocabulary.
--
-- They are checked on the RAW TEXT, not on the decoded tables, because a
-- present-and-null member decodes to the same nil an absent one does: an
-- unknown key spelled `"tenant": null` would vanish before any decoded-side
-- check could see it.
local NESTED_OBJECT_KEYS = {
	flags = { crash_profile = true, server_analytics = true, child_rules = true, operation_blocks = true },
	scope = { workspace_key = true, app_key = true, environment_key = true },
	basis = { character = true, table_provenance = true, notice = true },
}

local SIGNAL_KEYS = { name = true, available = true, reason = true }

-- ⚠ THE TOP-LEVEL SET IS THE CONTRACT'S, INCLUDING THE FIELDS THAT LEFT.
-- server_analytics_objection_required, prohibited_purposes and the echoed
-- age_band are NOT in the resolver's schema and were read here because this
-- module was written from prose rather than from the published bytes. They
-- return when the server's contract carries them, in both repositories at once
-- — a field this module reads and the server never sends is a promise to the
-- host that nothing can keep.
local SCHEMA_KEYS = {
	regime = true,
	flags = true,
	policy_version = true,
	consent_text_version = true,
	presented_language = true,
	scope = true,
	signals_used = true,
	band_vocabulary = true,
	band_vocabulary_version = true,
	expires_at = true,
	max_age_seconds = true,
	signature = true,
	basis = true,
	reason = true,
	advisory = true,
}

-- ⚠ THE ADVISORY PART HAS ITS OWN EXACT KEY SETS, and it is NOT in
-- NESTED_OBJECT_KEYS because that roster's members are REQUIRED: the advisory
-- is present only when the host asked for it and the resolver admitted the
-- request. When it IS present, every member below is required, and only the
-- estimate may be null (where its row carries none, and always for OTHER).
local ADVISORY_KEYS = {
	jurisdiction = true, estimate = true, row_id = true, row_status = true,
	row_basis = true, advisory_basis = true, matrix = true, resolved_by = true,
}
local ADVISORY_MATRIX_KEYS = { docs_commit = true, file_sha256 = true, date = true }
local ADVISORY_NULLABLE_KEYS = { estimate = true }

-- Signature is the one nullable top-level wire member. Null is a valid
-- unsigned shape, not authentication. Non-null signatures remain unverifiable;
-- the final unsigned gate also refuses the present-null shape.
-- The advisory estimate is nullable inside its part (ADVISORY_NULLABLE_KEYS).
local NULLABLE_KEYS = { signature = true }

-- ⚠ REQUIRED IS THE DEFAULT, AND THAT DIRECTION IS THE WHOLE POINT. The
-- contract of record sends every name in SCHEMA_KEYS on every plan; only
-- `reason` and `advisory` are conditional: one marks a refusal rather than a
-- plan, and the other is present only when the request asked for it. So the
-- required roster is DERIVED from the schema roster minus those explicit
-- exceptions, which means a key added to SCHEMA_KEYS becomes required without
-- anyone remembering to require it. The other direction — a roster of
-- required names kept beside the schema — is how flags.operation_blocks came
-- to be optional here: absent was read as "no restrictions", so a malformed
-- plan could drop every restriction it carried by leaving the key out and
-- still be USED. That was one key; the shape of the mistake was the roster.
local OPTIONAL_KEYS = { reason = true, advisory = true }

-- Sorted, so a plan missing several keys names the same one every run. A
-- refusal reason that varies between runs is a refusal nobody can test.
local REQUIRED_KEYS = {}
for key in pairs(SCHEMA_KEYS) do
	if not OPTIONAL_KEYS[key] then
		REQUIRED_KEYS[#REQUIRED_KEYS + 1] = key
	end
end
table.sort(REQUIRED_KEYS)

-- The same rule one level down: every member NESTED_OBJECT_KEYS names is
-- required, with no exception to carry. Sorted by object, then by member.
local REQUIRED_MEMBERS = {}
for object, members in pairs(NESTED_OBJECT_KEYS) do
	local names = {}
	for member in pairs(members) do
		names[#names + 1] = member
	end
	table.sort(names)
	REQUIRED_MEMBERS[#REQUIRED_MEMBERS + 1] = { object = object, names = names }
end
table.sort(REQUIRED_MEMBERS, function(left, right) return left.object < right.object end)

-- ⚠ AND THE SCAN HAS TO BE JSON-AWARE, NOT A SEARCH FOR THE LITERAL NAME. The
-- first cut looked for `"operation_blocks"%s*:%s*{` in the raw text, which a
-- valid response spells past in one character: "operation\u005fblocks" decodes
-- to the same key, json.decode restores it, and the literal search never saw
-- it. So this walks the document's TOP LEVEL with a tokenizer — unescaping
-- each key before comparing it, and skipping every value whole, so a key of
-- the same name nested inside another object is not mistaken for this one.
local MAX_SCAN_DEPTH = 32

local function skip_space(text, pos)
	local _, stop = text:find("^[ \t\r\n]*", pos)
	return stop + 1
end

-- Reads one JSON string starting at `pos` (which must be the opening quote)
-- and returns its DECODED value and the index after the closing quote, or nil.
-- A \u escape outside ASCII is folded to a byte that cannot appear in a schema
-- name: the point here is to compare key names, not to decode text.
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
				parts[#parts + 1] = code < 128 and string.char(code) or "\1"
				pos = pos + 6
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
		-- ⚠ DUPLICATE KEYS ARE AMBIGUOUS AT EVERY DEPTH, NOT ONLY AT THE ROOT.
		-- The root walk refused them and this one skipped nested values whole,
		-- so a scope carrying workspace_key twice — once the caller's, once
		-- another tenant's — was decided silently by the decoder, last one
		-- wins, and then compared against the caller's own scope.
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
	return stop + 1
end

-- Walks the plan's top level once and answers two questions the decoded table
-- can no longer answer: whether a list key was given an object, and WHICH KEYS
-- WERE PRESENT AT ALL.
--
-- ⚠ THE SECOND ONE MATTERS BECAUSE LUA HAS NO NULL: a present-but-null key
-- decodes to exactly the same nil as an absent one. For every key but
-- `signature` that is a refusal; `signature` is null on every response in this
-- release by contract, so for that one — and only that one — present-and-null
-- is the unsigned state and is admissible.
-- ⚠ flags CARRIES THE ONLY NESTED ARRAY IN THE SCHEMA, so it gets its own
-- walk rather than the generic object one: operation_blocks must be an ARRAY
-- (an object supplied there reads as no blocks at all) with no null entry (Lua
-- drops one, so a roster of three comes back as two with nothing saying so).
-- Those two facts live in the raw text and nowhere else.
local function scan_flags(body, pos)
	local seen = {}
	pos = skip_space(body, pos + 1)
	if body:sub(pos, pos) == "}" then
		return true, nil, pos + 1
	end
	while true do
		if body:sub(pos, pos) ~= '"' then
			return false, "a flags key is not a string"
		end
		local key, after = read_string(body, pos)
		if not key then
			return false, "a flags key is not readable"
		end
		if seen[key] then
			return false, "flags carries the key " .. key .. " twice"
		end
		if not NESTED_OBJECT_KEYS.flags[key] then
			return false, "flags carries an unknown key"
		end
		seen[key] = true
		pos = skip_space(body, after)
		if body:sub(pos, pos) ~= ":" then
			return false, "a flags key carries no value"
		end
		pos = skip_space(body, pos + 1)
		if key == "operation_blocks" then
			if body:sub(pos, pos) ~= "[" then
				return false, "operation_blocks is not a list"
			end
			local scan = skip_space(body, pos + 1)
			while body:sub(scan, scan) ~= "]" do
				if body:sub(scan, scan + 3) == "null" then
					return false, "operation_blocks carries a null entry"
				end
				local entry_end = skip_value(body, scan, 1)
				if not entry_end then
					return false, "the plan is not readable"
				end
				scan = skip_space(body, entry_end)
				if body:sub(scan, scan) == "," then
					scan = skip_space(body, scan + 1)
				elseif body:sub(scan, scan) ~= "]" then
					return false, "the plan is not readable"
				end
			end
		end
		local next_pos = skip_value(body, pos, 1)
		if not next_pos then
			return false, "the plan is not readable"
		end
		pos = skip_space(body, next_pos)
		local delimiter = body:sub(pos, pos)
		if delimiter == "}" then
			return true, nil, pos + 1
		end
		if delimiter ~= "," then
			return false, "the plan is not readable"
		end
		pos = skip_space(body, pos + 1)
	end
end

-- ⚠ THE ADVISORY PART, WALKED WHERE THE RAW TEXT STILL KNOWS IT. Lua has no
-- null, so a member sent as null decodes to the same nil an absent one does,
-- and only the estimate may be null; an unknown or repeated member is a part
-- this module did not fully read; and `matrix` must be an object, which the
-- decoded table can no longer say. Every member is required once the part is
-- present. The same walk serves the matrix, one level down.
local scan_advisory_object
scan_advisory_object = function(body, pos, keys, nullable, where)
	local seen = {}
	pos = skip_space(body, pos + 1)
	if body:sub(pos, pos) ~= "}" then
		while true do
			if body:sub(pos, pos) ~= '"' then
				return false, "a key of " .. where .. " is not a string"
			end
			local key, after = read_string(body, pos)
			if not key then
				return false, "a key of " .. where .. " is not readable"
			end
			if seen[key] then
				return false, where .. " carries the key " .. key .. " twice"
			end
			if not keys[key] then
				return false, where .. " carries an unknown key"
			end
			seen[key] = true
			pos = skip_space(body, after)
			if body:sub(pos, pos) ~= ":" then
				return false, "a key of " .. where .. " carries no value"
			end
			pos = skip_space(body, pos + 1)
			local next_pos
			if body:sub(pos, pos + 3) == "null" then
				if not nullable[key] then
					return false, where .. "." .. key .. " is present and null"
				end
				next_pos = skip_value(body, pos, 1)
			elseif key == "matrix" and keys == ADVISORY_KEYS then
				if body:sub(pos, pos) ~= "{" then
					return false, "advisory.matrix is not an object"
				end
				local matrix_ok, matrix_refusal, matrix_end =
					scan_advisory_object(body, pos, ADVISORY_MATRIX_KEYS, {}, "advisory.matrix")
				if not matrix_ok then
					return false, matrix_refusal
				end
				next_pos = matrix_end
			else
				next_pos = skip_value(body, pos, 1)
			end
			if not next_pos then
				return false, "the plan is not readable"
			end
			pos = skip_space(body, next_pos)
			local delimiter = body:sub(pos, pos)
			if delimiter == "}" then
				break
			end
			if delimiter ~= "," then
				return false, "the plan is not readable"
			end
			pos = skip_space(body, pos + 1)
		end
	end
	-- Sorted, so a part missing several members names the same one every run.
	local missing = {}
	for key in pairs(keys) do
		if not seen[key] then
			missing[#missing + 1] = key
		end
	end
	if #missing > 0 then
		table.sort(missing)
		return false, "the plan is missing the required key " .. where .. "." .. missing[1]
	end
	return true, nil, pos + 1
end

local function scan_plan_text(body)
	local present = {}
	local present_signals = {}
	local pos = skip_space(body, 1)
	if body:sub(pos, pos) ~= "{" then
		-- Not an object at all; the decode refuses it on its own terms.
		return true, nil, present, present_signals
	end
	pos = skip_space(body, pos + 1)
	if body:sub(pos, pos) == "}" then
		return true, nil, present, present_signals
	end
	while true do
		if body:sub(pos, pos) ~= '"' then
			return false, "a plan key is not a string", present, present_signals
		end
		local key, after = read_string(body, pos)
		if not key then
			return false, "a plan key is not readable", present, present_signals
		end
		-- ⚠ A DUPLICATE TOP-LEVEL KEY IS AMBIGUOUS, AND THE DECODER RESOLVES
		-- IT SILENTLY — last one wins. The plan carrying both a strict and a
		-- permissive spelling of the same field is not a plan with a value, it
		-- is two plans, and this build does not get to pick.
		if present[key] then
			return false, "the plan carries the key " .. key .. " twice", present, present_signals
		end
		-- ⚠ AND A KEY THAT IS NOT IN THE SCHEMA MEANS WE DID NOT FULLY READ IT.
		if not SCHEMA_KEYS[key] then
			return false, "the plan carries an unknown key", present, present_signals
		end
		present[key] = true
		pos = skip_space(body, after)
		if body:sub(pos, pos) ~= ":" then
			return false, "a plan key carries no value", present, present_signals
		end
		pos = skip_space(body, pos + 1)
		if LIST_KEYS[key] and body:sub(pos, pos) == "{" then
			return false, key .. " is a JSON object where the schema says a list", present, present_signals
		end
		-- ⚠ THE ELEMENTS OF signals_used, WALKED WHERE THE RAW TEXT STILL
		-- KNOWS THEM. Lua DROPS a null element, so a roster of three comes back
		-- as two with nothing saying so; and a member spelled `null` inside an
		-- entry decodes to the same nil an absent one does, so the entry's own
		-- key set has to be recorded here too.
		if LIST_KEYS[key] and body:sub(pos, pos) == "[" then
			local scan = skip_space(body, pos + 1)
			local index = 0
			while body:sub(scan, scan) ~= "]" do
				if body:sub(scan, scan + 3) == "null" then
					return false, key .. " carries a null entry", present, present_signals
				end
				index = index + 1
				local collect = nil
				if key == "signals_used" and body:sub(scan, scan) == "{" then
					collect = {}
					present_signals[index] = collect
				end
				local element_end = skip_value(body, scan, 1, collect)
				if not element_end then
					return false, "the plan is not readable", present, present_signals
				end
				if collect then
					for member in pairs(collect) do
						if not SIGNAL_KEYS[member] then
							return false, "a signal carries an unknown key", present, present_signals
						end
					end
				end
				scan = skip_space(body, element_end)
				if body:sub(scan, scan) == "," then
					scan = skip_space(body, scan + 1)
				elseif body:sub(scan, scan) ~= "]" then
					return false, "the plan is not readable", present, present_signals
				end
			end
		end
		-- The nested objects the schema names, checked where the raw text still
		-- knows what was written. `members` is collected by the same walk that
		-- skips the value, so this costs no second pass.
		local handled = false
		if key == "flags" and body:sub(pos, pos) == "{" then
			local flags_ok, flags_refusal, flags_end = scan_flags(body, pos)
			if not flags_ok then
				return false, flags_refusal, present, present_signals
			end
			pos = flags_end
			handled = true
		end
		-- `"advisory": null` is left to the present-and-null rule below, which
		-- refuses it: the resolver omits an advisory it does not serve.
		if key == "advisory" and body:sub(pos, pos + 3) ~= "null" then
			if body:sub(pos, pos) ~= "{" then
				return false, "advisory is not an object", present, present_signals
			end
			local advisory_ok, advisory_refusal, advisory_end =
				scan_advisory_object(body, pos, ADVISORY_KEYS, ADVISORY_NULLABLE_KEYS, "advisory")
			if not advisory_ok then
				return false, advisory_refusal, present, present_signals
			end
			pos = advisory_end
			handled = true
		end

		if not handled then
			local members = nil
			if NESTED_OBJECT_KEYS[key] and body:sub(pos, pos) == "{" then
				members = {}
			end
			local next_pos = skip_value(body, pos, 1, members)
			if not next_pos then
				return false, "the plan is not readable", present, present_signals
			end
			if members then
				for member in pairs(members) do
					if not NESTED_OBJECT_KEYS[key][member] then
						return false, key .. " carries an unknown key", present, present_signals
					end
				end
			end
			pos = next_pos
		end

		pos = skip_space(body, pos)
		local delimiter = body:sub(pos, pos)
		if delimiter == "}" then
			return true, nil, present, present_signals
		end
		if delimiter ~= "," then
			return false, "the plan is not readable", present, present_signals
		end
		pos = skip_space(body, pos + 1)
	end
end

-- ⚠ AN OBJECT IS NOT AN EMPTY LIST. A JSON object decodes to a Lua table
-- whose length is zero and over which ipairs yields nothing, so a roster
-- supplied as {"a": 1} read as "no operation blocks" — a malformed plan
-- presenting as a permissive one. This check stays for the NON-empty case and
-- for a caller that hands parse_plan a table directly; the raw check above is
-- what covers the empty one.
local function is_sequence(list)
	local length = #list
	local count = 0
	for key in pairs(list) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
			return false
		end
		count = count + 1
	end
	return count == length
end

-- Days since 1970-01-01 from a civil date, so expiry is evaluated by
-- arithmetic rather than by os.time — which reads its table as LOCAL time and
-- would have the same plan expire at different instants on two machines.
local function days_from_civil(y, m, d)
	if m <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function days_in_month(y, m)
	if m == 2 and y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then
		return 29
	end
	return DAYS_IN_MONTH[m]
end

-- RFC 3339 to seconds since the epoch, or nil. Unreadable is refused, not
-- treated as "no expiry": a timestamp this build cannot compare is a plan
-- whose life it cannot confirm.
local function parse_timestamp(value)
	if type(value) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, sec, rest =
		value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)(.*)$")
	if not y then
		return nil
	end
	y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
	h, mi, sec = tonumber(h), tonumber(mi), tonumber(sec)
	if mo < 1 or mo > 12 or d < 1 or d > days_in_month(y, mo) then
		return nil
	end
	-- ⚠ SECOND 60 IS REFUSED. The grammar allows it, but a UTC leap second can
	-- only ever be inserted at 23:59:60 on a date the IERS announced — so an
	-- arbitrary ":00:60" is not a leap second, it is a malformed timestamp, and
	-- normalising it arithmetically to the next minute quietly moved a plan's
	-- expiry. Validating it against the real insertion dates would mean
	-- shipping and maintaining that table in an SDK; refusing is the honest
	-- answer this module can actually keep.
	if h > 23 or mi > 59 or sec > 59 then
		return nil
	end
	rest = rest:gsub("^%.%d+", "")
	local offset = 0
	if rest ~= "Z" and rest ~= "z" then
		-- RFC 3339 spells an offset with the colon. Accepting "+0200" as well
		-- was me being generous with someone else's grammar, and a parser that
		-- accepts more than the spec is a parser that disagrees with every
		-- other reader of the same field.
		local sign, oh, om = rest:match("^([%+%-])(%d%d):(%d%d)$")
		if not sign then
			return nil
		end
		oh, om = tonumber(oh), tonumber(om)
		if oh > 23 or om > 59 then
			return nil
		end
		-- ⚠ "-00:00" IS NOT ZERO, IT IS "OFFSET UNKNOWN" (RFC 3339). An
		-- expiry whose offset the sender declined to state is an instant this
		-- build cannot place on a timeline, and treating it as UTC is picking
		-- one of the twenty-seven it could have meant.
		if sign == "-" and oh == 0 and om == 0 then
			return nil
		end
		offset = (oh * 3600 + om * 60) * (sign == "-" and -1 or 1)
	end
	return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - offset
end

-- ⚠ COPIED VERBATIM FROM client.lua, NOT REQUIRED FROM IT. The endpoint obeys
-- the SAME rule as ingest_url and crash_ingest_url — https anywhere, http only
-- for a loopback host, no userinfo, no query, no fragment, no path beyond a
-- single trailing slash — and there is exactly one way for this module to obey
-- it: copy the predicate. Requiring shardpilot.client would pull in storage and
-- id, creating the persisted scope record and minting an anonymous identifier,
-- which is the one thing this module exists not to do.
--
-- The function keeps the original's NAME so the copy is byte-for-byte and a
-- test can compare the two texts. A duplicated rule that drifts is worse than
-- one that was never shared, so the drift is what the test watches.
-- BEGIN COPY FROM client.lua
local function local_http_host(host)
	return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function parse_authority(authority)
	if authority == "" or authority:find("@", 1, true) then
		return nil
	end
	local host = nil
	if authority:sub(1, 1) == "[" then
		local rest = nil
		host, rest = authority:match("^%[([^%]]+)%](.*)$")
		if not host then
			return nil
		end
		if rest ~= "" and not rest:match("^:%d+$") then
			return nil
		end
	else
		local colon = authority:find(":", 1, true)
		if colon then
			host = authority:sub(1, colon - 1)
			local port = authority:sub(colon + 1)
			if port == "" or not port:match("^%d+$") then
				return nil
			end
		else
			host = authority
		end
		if host:find(":", 1, true) then
			return nil
		end
	end
	if not host or host == "" or host:match("%s") then
		return nil
	end
	return host
end

local function valid_ingest_url(value)
	if type(value) ~= "string" or value == "" then
		return false
	end
	if value:find("?", 1, true) or value:find("#", 1, true) then
		return false
	end
	local scheme, rest = value:match("^(https?)://(.+)$")
	if not scheme then
		return false
	end
	local authority = rest
	local path = nil
	local slash = rest:find("/", 1, true)
	if slash then
		authority = rest:sub(1, slash - 1)
		path = rest:sub(slash)
	end
	if path and path ~= "/" then
		return false
	end
	local host = parse_authority(authority or "")
	if not host then
		return false
	end
	if scheme == "https" then
		return true
	end
	return local_http_host(host)
end
-- END COPY FROM client.lua

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

-- Freeze the validated request so caller mutation cannot change its scope.
local function copy_value(value, depth)
	if type(value) ~= "table" then
		return value
	end
	if depth >= 16 then
		return nil
	end
	local out = {}
	for key, child in pairs(value) do
		out[key] = copy_value(child, depth + 1)
	end
	return out
end

-- Length-prefixed, so no two different values can spell the same key.
local function key_field(value)
	value = value or ""
	return string.format("%d:%s", #value, value)
end

-- The policy context defines an epoch for in-flight responses. Advisory is
-- an optional extra part, so changing that opt-in shares the dispatch order.
local function context_key(context)
	local parts = {}
	local function field(value)
		parts[#parts + 1] = key_field(value)
	end
	field(context.workspace_key)
	field(context.app_key)
	field(context.environment_key)
	field(context.app_version)
	field(context.locale)
	field(context.platform)
	field(context.store)
	field(context.endpoint)
	field(context.age_band and context.age_band.vocabulary)
	field(context.age_band and context.age_band.band)
	return table.concat(parts, "|")
end

-- ⚠ THE SAME FALLBACK clock.lua ALREADY USES (clock.lua:4-9), and for the same
-- reason. Returning nil when socket is absent looked conservative and was not:
-- prepare refuses outright with no clock, so every target without the socket
-- module was PERMANENTLY strict — not failing closed on a doubt, but never
-- asking the question at all. os.time() is second-resolution, which is ample
-- for an expiry measured in minutes.
local function now_seconds()
	if socket and socket.gettime then
		return socket.gettime()
	end
	if os and os.time then
		return os.time()
	end
	return nil
end

-- The reason an error envelope carries, or the generic one.
--
-- ⚠ IT IS BOUNDED AND PATTERN-CHECKED BECAUSE IT TRAVELS INTO decision.reason,
-- which hosts branch on and log. Echoing whatever arrived would let a body put
-- arbitrary text — or a great deal of it — into a caller's control flow and log
-- lines; a reason this build cannot recognise is reported as the generic one
-- rather than repeated.
local function error_envelope_reason(decoded)
	-- ⚠ CHECKED AGAINST THE RESOLVER'S CLOSED LIST, not a character class. The
	-- reason travels into decision.reason, which hosts branch on and log; a
	-- name this build does not know is reported as the generic one rather than
	-- repeated, because a caller cannot map a reason it has never heard of.
	if REFUSAL_REASONS[decoded.reason] then
		return decoded.reason
	end
	return "policy_unavailable"
end

-- ⚠ STRICT IS BUILT IN ONE PLACE, so no path can invent a partial permissive
-- result. Every failure comes through here.
local function strict(reason, detail)
	return {
		regime = M.STRICT_OPT_IN,
		crash_profile = M.CRASH_OFF,
		server_analytics = M.SERVER_ANALYTICS_DENIED,
		child_rules = M.CHILD_RULES_MINIMISED,
		-- This default describes a strict choice, not permission to process.
		-- Unknown operation restrictions remain a separate admission barrier.
		analytics_choice_default = M.CHOICE_DEFAULT_OFF,
		explicit_grant_required = true,
		plan_used = false,
		-- No authenticated restriction set is known. Nil must not mean no blocks.
		operation_blocks = nil,
		operation_blocks_source = "none",
		reason = reason,
		detail = detail,
	}
end

local function bounded_string(value, limit)
	return type(value) == "string" and #value > 0 and #value <= limit
end

-- Validates the CALLER's context before anything is sent. A value outside the
-- closed vocabulary never reaches the wire.
-- ⚠ THE CALLER'S FIELD NAMES ARE A CLOSED SET FOR THE SAME REASON THE PLAN'S
-- ARE. A key we do not read is a context we cannot say we understood, and the
-- shape it actually takes in practice is a typo: `age_bnad` is silently no age
-- band at all, so the request goes out claiming this player has none.
local CONTEXT_KEYS = {
	endpoint = true,
	workspace_key = true,
	app_key = true,
	environment_key = true,
	app_version = true,
	store = true,
	store_region = true,
	locale = true,
	platform = true,
	age_band = true,
	advisory = true,
}

function M.validate_context(context)
	if type(context) ~= "table" then
		return false, "the context must be a table"
	end
	for key in pairs(context) do
		if not CONTEXT_KEYS[key] then
			return false, "the context carries an unknown field"
		end
	end
	for _, field in ipairs({ "workspace_key", "app_key", "environment_key" }) do
		if not bounded_string(context[field], MAX_ENTRY) then
			return false, field .. " is missing or over its bound"
		end
	end
	if not version_ok(context.app_version) then
		return false, "app_version is missing, over 64 bytes, or outside the permitted characters"
	end
	-- ⚠ THE ENDPOINT IS VALIDATED, NOT ASSUMED. It is concatenated with the
	-- route in prepare, so an absent or non-string one raised a Lua error out
	-- of prepare rather than taking the strict path: the single callback this
	-- module promises was never invoked at all, leaving the caller with no
	-- decision to fail closed on.
	if not bounded_string(context.endpoint, MAX_ENDPOINT) then
		return false, "endpoint is missing or over its bound"
	end
	-- ⚠ AND PLAIN http OFF LOOPBACK IS REFUSED, by the SDK's own predicate
	-- rather than by a second opinion. A consent-regime request carries this
	-- app's scope and this player's locale and age band; sending that in the
	-- clear to a remote host is the kind of exception nobody revisits. An
	-- earlier cut here accepted any `^https?://`, which is exactly that hole.
	if not valid_ingest_url(context.endpoint) then
		return false, "endpoint must be https, or http only for a loopback host"
	end
	if context.store ~= nil and not STORES[context.store] then
		return false, "store is not one of the permitted kinds"
	end
	-- ⚠ store_region IS NULL-ONLY IN THIS RELEASE, and it is refused locally
	-- rather than sent to be refused: a non-null value carries a country claim,
	-- and the point of refusing it is that it does not travel.
	if context.store_region ~= nil then
		return false, "store_region is not accepted in this release; a region adapter is a reviewed change"
	end
	if not bounded_string(context.locale, MAX_LANGUAGE) then
		return false, "locale is missing or over its bound"
	end
	if not PLATFORMS[context.platform] then
		return false, "platform is not one of the permitted values"
	end
	-- ⚠ THE ADVISORY PART IS ASKED FOR, NEVER ASSUMED. true asks the resolver
	-- for it; absent or false sends the request without the member, which the
	-- resolver answers with the plan alone. Anything else is refused here,
	-- including the string "true": the wire takes a boolean and nothing else.
	if context.advisory ~= nil and type(context.advisory) ~= "boolean" then
		return false, "advisory must be true or false"
	end
	if context.age_band ~= nil then
		local band = context.age_band
		if type(band) ~= "table" or not bounded_string(band.vocabulary, MAX_BAND)
			or not bounded_string(band.band, MAX_BAND) then
			return false, "age_band is malformed or over its bound"
		end
		-- ⚠ THE SAME CLOSED KEY SET THE RESPONSE'S age_band GETS. It was closed
		-- on the band the resolver sends back and left open on the one the
		-- caller sends — and this is the side that TRAVELS: an unread member
		-- here is an age claim about this player that nothing looked at and
		-- request_body would have carried anyway had it been copied wholesale.
		for key in pairs(band) do
			if key ~= "vocabulary" and key ~= "band" then
				return false, "age_band carries an unknown field"
			end
		end
	end
	return true
end

local function request_body(context)
	local body = {
		workspace_key = context.workspace_key,
		app_key = context.app_key,
		environment_key = context.environment_key,
		app_version = context.app_version,
		locale = context.locale,
		platform = context.platform,
	}
	if context.store ~= nil then
		body.store = context.store
	end
	-- store_region is never set: null-only, and validate_context already
	-- refused a non-null one.
	if context.age_band ~= nil then
		body.age_band = { vocabulary = context.age_band.vocabulary, band = context.age_band.band }
	end
	-- Sent only when asked: otherwise the version 3 request asks for the
	-- plan alone, without an advisory member.
	if context.advisory == true then
		body.advisory = true
	end
	return body
end

-- ⚠ THE ADVISORY PART IS VALIDATED LIKE EVERY OTHER MEMBER, and a malformed
-- one makes the WHOLE plan unreadable: a plan this module cannot fully read is
-- a plan it cannot act on. The raw scan has already settled its key set, its
-- nulls and that matrix is an object; what is left is each value.
local function advisory_code(value)
	return type(value) == "string" and (value == ADVISORY_OTHER or value:match("^[A-Z][A-Z]$") ~= nil)
end

local function lower_hex(value, length)
	return type(value) == "string" and #value == length and value:match("^[0-9a-f]+$") ~= nil
end

local function calendar_date(value)
	if type(value) ~= "string" then
		return false
	end
	local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not y then
		return false
	end
	y, m, d = tonumber(y), tonumber(m), tonumber(d)
	return m >= 1 and m <= 12 and d >= 1 and d <= days_in_month(y, m)
end

local function advisory_refusal(advisory)
	if type(advisory) ~= "table" then
		return "advisory is not an object"
	end
	if not advisory_code(advisory.jurisdiction) then
		return "advisory.jurisdiction is neither a two-letter code nor OTHER"
	end
	if not advisory_code(advisory.row_id) then
		return "advisory.row_id is neither a two-letter code nor OTHER"
	end
	if advisory.estimate ~= nil and not ADVISORY_ESTIMATES[advisory.estimate] then
		return "advisory.estimate is outside the closed vocabulary"
	end
	-- The row is the jurisdiction's own, or OTHER for both: the contract makes
	-- the jurisdiction OTHER for a connection with no row of its own, and the
	-- resolver sets both members from one row. Checked first, so the OTHER rule
	-- below holds for the row as well as the jurisdiction.
	if advisory.row_id ~= advisory.jurisdiction then
		return "advisory.row_id is not the jurisdiction's row"
	end
	-- The contract states both of these in its own words: OTHER never carries
	-- an estimate, and an unresolved connection is OTHER.
	if advisory.jurisdiction == ADVISORY_OTHER and advisory.estimate ~= nil then
		return "advisory names OTHER and still carries an estimate"
	end
	if not ADVISORY_RESOLVED_BY[advisory.resolved_by] then
		return "advisory.resolved_by is outside the closed vocabulary"
	end
	if advisory.resolved_by == "unknown" and advisory.jurisdiction ~= ADVISORY_OTHER then
		return "advisory resolved nothing and still names a jurisdiction"
	end
	if not ADVISORY_ROW_STATUSES[advisory.row_status] then
		return "advisory.row_status is outside the closed vocabulary"
	end
	if not ADVISORY_ROW_BASES[advisory.row_basis] then
		return "advisory.row_basis is outside the closed vocabulary"
	end
	if not bounded_string(advisory.advisory_basis, MAX_ADVISORY_BASIS) then
		return "advisory.advisory_basis is empty or over its bound"
	end
	-- ⚠ NO CONTROL CHARACTERS. The text is a table cell, which holds none, and
	-- it is the free text a host is most likely to log or show: a newline here
	-- could write a second line into a log that nothing authorised. %c sees
	-- only C0 and DEL, so C1 (U+0080-U+009F, "\194\128"-"\194\159" in UTF-8)
	-- is matched on its encoding: some log sinks read U+0085 NEXT LINE as a
	-- line break.
	if advisory.advisory_basis:find("%c") or advisory.advisory_basis:find("\194[\128-\159]") then
		return "advisory.advisory_basis carries a control character"
	end
	local matrix = advisory.matrix
	if type(matrix) ~= "table" then
		return "advisory.matrix is not an object"
	end
	if not lower_hex(matrix.docs_commit, 40) then
		return "advisory.matrix.docs_commit is not a 40-character hex commit"
	end
	if not lower_hex(matrix.file_sha256, 64) then
		return "advisory.matrix.file_sha256 is not a 64-character hex digest"
	end
	if not calendar_date(matrix.date) then
		return "advisory.matrix.date is not a calendar date"
	end
	return nil
end

-- ⚠ PRIVATE. The public surface is prepare() and invalidate(), and this is
-- why: parse_plan takes a DECODED TABLE, and half of what this module checks —
-- container types, duplicate keys, present-and-null members, unknown key names
-- — lives in the raw text and is gone by the time a table exists. An exported
-- parse_plan would hand a caller a "validator" that silently cannot perform
-- most of its own validation.
--
-- Reads a plan. It REFUSES rather than repairs: a plan the SDK cannot fully
-- read is a plan it cannot act on, and "use the parts I understood" is how a
-- permissive default gets in.
-- `now` is seconds since the epoch. It is what makes expiry enforceable here
-- rather than merely described; a caller with no clock passes nothing and
-- prepare refuses before it ever reaches this point.
local function parse_plan(plan, context, now)
	if type(plan) ~= "table" then
		return nil, "the plan is not an object"
	end
	-- ⚠ PRESENCE BEFORE MEANING, FOR EVERY REQUIRED NAME AT ONCE. Each check
	-- below reads a value; a missing one reads as nil, and nil used to mean
	-- whatever that particular check made of it — an absent list meant "no
	-- restrictions", an absent max_age meant "no ceiling". So this runs first
	-- and names the key it did not find, and every check after it is about a
	-- value that arrived.
	if plan.regime == nil then
		return nil, "the plan is missing the required key regime"
	end
	for _, object in ipairs(REQUIRED_MEMBERS) do
		local nested = plan[object.object]
		if type(nested) ~= "table" then
			return nil, "the plan carries no " .. object.object .. " object"
		end
		for _, member in ipairs(object.names) do
			if nested[member] == nil then
				return nil, "the plan is missing the required key "
					.. object.object .. "." .. member
			end
		end
	end
	if plan.regime ~= M.STRICT_OPT_IN and plan.regime ~= M.SOFT_OPT_OUT and plan.regime ~= M.UNKNOWN then
		return nil, "unknown regime"
	end
	-- ⚠ THE RESTRICTIONS ARE NESTED UNDER flags, AND EACH IS DECIDED
	-- SEPARATELY. None of them inherits an analytics permission, which is why
	-- the contract groups them rather than folding them into the regime.
	local flags = plan.flags
	if not CRASH_PROFILES[flags.crash_profile] then
		return nil, "unknown crash_profile"
	end
	if not SERVER_ANALYTICS[flags.server_analytics] then
		return nil, "unknown server_analytics"
	end
	if not CHILD_RULES[flags.child_rules] then
		return nil, "unknown child_rules"
	end
	-- ⚠ AN ABSENT operation_blocks IS NOT AN EMPTY ONE. The contract sends []
	-- when there is nothing to block, so absence is a plan that lost its
	-- restrictions in transit — and reading it as "none" let a malformed plan
	-- drop every restriction it carried and still be USED. The roster above
	-- has already refused an absent key by name; what is left here is shape.
	if type(flags.operation_blocks) ~= "table" or #flags.operation_blocks > MAX_ENTRIES
		or not is_sequence(flags.operation_blocks) then
		return nil, "operation_blocks is malformed or over its bound"
	end
	for _, entry in ipairs(flags.operation_blocks) do
		if not bounded_string(entry, MAX_ENTRY) then
			return nil, "an entry of operation_blocks is malformed"
		end
	end
	if not version_ok(plan.policy_version) or not version_ok(plan.consent_text_version) then
		return nil, "a version field is missing or outside its bound"
	end
	-- presented_language names the ACTUAL supported text; it is bounded but not
	-- required to echo the requested locale.
	if not bounded_string(plan.presented_language, MAX_LANGUAGE) then
		return nil, "presented_language is missing or over its bound"
	end
	-- ⚠ THE BAND VOCABULARY IS A DECLARATION, NOT AN ECHO, so it is checked for
	-- SHAPE and compared with nothing. The resolver states which age scale it
	-- speaks as a constant; in this release it does not read the caller's band
	-- at all, and says so by naming age_band among the UNAVAILABLE signals.
	-- Comparing the caller's vocabulary against it would compare against a
	-- value that ignored the request — refusing every plan for any host whose
	-- age vocabulary happens to be spelled differently. An earlier cut of this
	-- module did exactly that.
	if not bounded_string(plan.band_vocabulary, MAX_BAND)
		or not bounded_string(plan.band_vocabulary_version, MAX_BAND) then
		return nil, "the band vocabulary is missing or over its bound"
	end
	local basis = plan.basis
	if not BASIS_CHARACTERS[basis.character] then
		return nil, "unknown basis character"
	end
	if not TABLE_PROVENANCES[basis.table_provenance] then
		return nil, "unknown table provenance"
	end
	-- Validate the notice shape without making its unauthenticated text authoritative.
	if not bounded_string(basis.notice, MAX_NOTICE) then
		return nil, "the basis carries no notice"
	end
	local scope = plan.scope
	if scope.workspace_key ~= context.workspace_key
		or scope.app_key ~= context.app_key or scope.environment_key ~= context.environment_key then
		return nil, "the plan is scoped to another app, environment or workspace"
	end
	do
		if type(plan.signals_used) ~= "table" or #plan.signals_used > MAX_SIGNALS
			or not is_sequence(plan.signals_used) then
			return nil, "signals_used is malformed or over its bound"
		end
		for _, signal in ipairs(plan.signals_used) do
			if type(signal) ~= "table" or not bounded_string(signal.name, MAX_ENTRY) then
				return nil, "a signal is malformed"
			end
			if type(signal.available) ~= "boolean" then
				return nil, "a signal does not state whether it was available"
			end
			if signal.reason ~= nil and not SIGNAL_REASONS[signal.reason] then
				return nil, "a signal carries a reason outside the closed vocabulary"
			end
			-- An unavailable signal must say WHY, from the closed vocabulary. A
			-- bare "not available" is the shape that hides a prohibited source.
			if not signal.available and not SIGNAL_REASONS[signal.reason] then
				return nil, "an unavailable signal carries no known reason"
			end
		end
	end
	if not bounded_string(plan.expires_at, MAX_ENTRY) then
		return nil, "the plan carries no expires_at"
	end
	local expires_at = parse_timestamp(plan.expires_at)
	if not expires_at then
		return nil, "expires_at is not a readable timestamp"
	end
	-- ⚠ EXPIRED IS MALFORMED. The conservative rule names expiry beside
	-- missing and unreadable for a reason: a plan whose life has run out is
	-- not a weaker plan, it is no plan.
	if type(now) == "number" and expires_at <= now then
		return nil, "the plan has already expired"
	end
	if type(plan.max_age_seconds) ~= "number" or plan.max_age_seconds < 0
		or plan.max_age_seconds % 1 ~= 0 then
		return nil, "max_age_seconds is not a whole non-negative number"
	end
	-- This build cannot verify a non-null signature. A present-null signature
	-- passes this shape check only, then reaches the final unsigned refusal.
	if plan.signature ~= nil then
		return nil, "the plan carries a signature this build cannot verify"
	end
	if plan.advisory ~= nil then
		-- ⚠ AN ANSWER TO A QUESTION THIS REQUEST DID NOT ASK. The resolver
		-- serves the advisory part only to a request that asked for it, so one
		-- arriving unasked is a response to a different request.
		if context.advisory ~= true then
			return nil, "the plan carries an advisory part this request did not ask for"
		end
		local refusal = advisory_refusal(plan.advisory)
		if refusal then
			return nil, refusal
		end
	end
	return plan
end

-- Invalidate every response dispatched under the previous context epoch.
function M.invalidate()
	generation = generation + 1
	-- Nothing in flight may answer after this, so the per-key records go too;
	-- they are the only thing that grows, and this is what bounds them.
	latest_dispatch = {}
end

-- prepare(context, callback) — the first integration call, before the
-- telemetry SDK is created.
--
-- The callback receives exactly ONE decision, exactly ONCE.
function M.prepare(context, callback)
	assert(type(callback) == "function", "prepare requires a callback")

	local function fallback(reason, detail)
		return strict(reason, detail)
	end

	local ok, why = M.validate_context(context)
	if not ok then
		callback(fallback("invalid_request", why))
		return
	end

	-- Freeze the validated request: caller mutation cannot relabel an in-flight
	-- response. A context change also fences
	-- callbacks dispatched before the change, even if that context returns later.
	context = copy_value(context, 0)
	local key = context_key(context)
	if active_context ~= key then
		M.invalidate()
		active_context = key
	end

	local at = now_seconds()
	-- ⚠ NO CLOCK, NO PLAN. Expiry is enforced by comparing the plan's
	-- expires_at against this reading, so without it an expired plan could not
	-- be recognised as expired — and "used because we could not check" is the
	-- permissive default the conservative rule exists to forbid.
	if not at then
		callback(fallback("clock_unavailable", "no clock is available to evaluate the plan's expiry"))
		return
	end

	-- Missing dependencies return a local fallback before any request.
	if not http or not http.request then
		callback(fallback("transport_unavailable", "no http transport is available"))
		return
	end
	if not json or not json.decode then
		callback(fallback("decoder_unavailable", "no json decoder is available"))
		return
	end
	if not json.encode then
		callback(fallback("encoder_unavailable", "no json encoder is available"))
		return
	end

	-- ⚠ AND THE ENCODER IS CALLED THROUGH pcall. json.encode raises on a value
	-- it cannot represent, and an error thrown out of prepare is not a strict
	-- decision — it is NO decision, so the one callback this module promises
	-- never arrives and the caller has nothing to fail closed on.
	local encoded_ok, encoded = pcall(json.encode, request_body(context))
	if not encoded_ok or type(encoded) ~= "string" then
		callback(fallback("encoder_failed", "the request body could not be encoded"))
		return
	end

	local settled = false
	local deadline = at + DEADLINE_SECONDS
	-- The invalidation this request is dispatched under; see `generation`.
	local dispatched_under = generation
	-- ...and its place in the order of dispatches for THIS context key.
	dispatch_counter = dispatch_counter + 1
	local dispatch = dispatch_counter
	latest_dispatch[key] = dispatch
	local function settle(decision)
		-- ⚠ ONE CALLBACK, EVER. A response that arrives after the deadline is
		-- dropped here: the screen it would change has already been presented.
		if settled then
			return
		end
		settled = true
		callback(decision)
	end

	http.request(trim_slash(context.endpoint) .. ROUTE, "POST", function(_, _, response)
		local arrived = now_seconds()
		if not arrived then
			settle(fallback("clock_unavailable", "no clock is available to evaluate the plan's expiry"))
			return
		end
		-- A clock rollback makes the deadline and expiry comparisons unreliable.
		if arrived < at then
			settle(fallback("clock_regressed", "the clock moved backwards while the request was in flight"))
			return
		end
		-- Invalidation fences every response from the previous epoch.
		if dispatched_under ~= generation then
			settle(fallback("invalidated", "the policy was invalidated while this request was in flight"))
			return
		end
		-- Preserve request ordering even when both answers would be strict.
		if latest_dispatch[key] ~= dispatch then
			settle(fallback("superseded", "a later request for this context was dispatched first"))
			return
		end
		latest_dispatch[key] = nil
		if arrived > deadline then
			settle(fallback("deadline_exceeded", "the response arrived after the total deadline"))
			return
		end
		if type(response) ~= "table" or response.status == nil then
			settle(fallback("transport_error", "no response"))
			return
		end
		local body = response.response
		if type(body) ~= "string" or #body == 0 or #body > MAX_BODY then
			settle(fallback("invalid_response", "the response body is empty or over its bound"))
			return
		end
		local decoded_ok, decoded = pcall(json.decode, body)
		if not decoded_ok or type(decoded) ~= "table" then
			settle(fallback("invalid_response", "the response body is not readable"))
			return
		end
		-- ⚠ THE STATUS DECIDES WHICH DOCUMENT THIS IS, AND IT HAS TO BE ASKED
		-- FIRST. An error body is an ERROR ENVELOPE, not a plan, so running the
		-- plan-key allowlist over it refused a perfectly well-formed
		-- {"reason": ...} for carrying a key that is not a plan field — a
		-- regression I introduced with the allowlist, which turned every
		-- resolver refusal into "unreadable" and lost the reason it gave.
		-- ⚠ A REFUSAL IS NOT ALWAYS A NON-2xx. The resolver answers a COMPLETE
		-- strict plan on every path — that is its contract, so a caller never
		-- receives a bare error and never has to invent a fallback — and it
		-- returns 200 for at least one refusal. So the REASON FIELD is what
		-- says "this is a refusal", not the status: a plan carrying one is
		-- settled as the strict fallback it already is, with its reason
		-- surfaced, and its scope is not compared — a refusal carries none, so
		-- that the response cannot be used to learn which tuples exist.
		if response.status < 200 or response.status >= 300 or decoded.reason ~= nil then
			settle(fallback(error_envelope_reason(decoded), "the resolver refused"))
			return
		end
		local shapes_ok, shape_refusal, present, present_signals = scan_plan_text(body)
		if not shapes_ok then
			settle(fallback("invalid_response", shape_refusal))
			return
		end
		-- The raw scan distinguishes absent fields from present-null values.
		-- Only the schema's nullable members may lose their value during decode.
		for key in pairs(present) do
			if decoded[key] == nil and not NULLABLE_KEYS[key] then
				settle(fallback("invalid_response", key .. " is present and null"))
				return
			end
		end
		-- ⚠ AND THE OTHER HALF OF THE SAME RULE: WHICH KEYS ARRIVED AT ALL.
		-- This is the only place that can ask it. Lua has no null, so by the
		-- time the plan is a table an absent `signature` and a `"signature":
		-- null` are the same nil — and one of those is the unsigned state the
		-- contract sends on every response while the other is a plan that lost
		-- a field in transit. The raw scan is what separates them, so the
		-- required-key roster is checked HERE, against the bytes, and
		-- parse_plan is left to judge the values it is handed.
		for _, key in ipairs(REQUIRED_KEYS) do
			if not present[key] then
				settle(fallback("invalid_response", "the plan is missing the required key " .. key))
				return
			end
		end
		-- The same rule inside each signal entry.
		for index, keys in pairs(present_signals) do
			local entry = type(decoded.signals_used) == "table" and decoded.signals_used[index] or nil
			if type(entry) ~= "table" then
				settle(fallback("invalid_response", "a signal entry is not an object"))
				return
			end
			for key in pairs(keys) do
				if entry[key] == nil then
					settle(fallback("invalid_response", "a signal entry carries " .. key .. " present and null"))
					return
				end
			end
		end
		local plan, refusal = parse_plan(decoded, context, arrived)
		if not plan then
			settle(fallback("invalid_response", refusal))
			return
		end
		-- Shape, scope and time checks do not authenticate a plan. No verifier
		-- or trusted key exists in this build, so even an unsigned strict plan
		-- must not supply restrictions or remove ones a host already enforces.
		settle(fallback("plan_unsigned", "this build cannot authenticate a consent plan"))
	end, { ["Content-Type"] = "application/json" }, encoded, { timeout = DEADLINE_SECONDS })
end

return M
