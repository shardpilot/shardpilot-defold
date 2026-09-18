-- Consent-regime policy preparation, and the ONE thing to understand about it:
-- it runs BEFORE the telemetry SDK exists.
--
-- ⚠ IT IMPORTS NOTHING FROM THIS SDK. Not sdk.lua, not client.lua, not
-- queue.lua, not storage.lua, not id.lua. That is a design rule rather than a
-- preference: requiring storage would create the persisted scope record and
-- requiring id would mint an anonymous identifier, and the first-run contract
-- forbids any SDK init, identity generation, spool load, capture hook or
-- buffered event before the player's final choice. A module that quietly
-- created one of those would break the rule it exists to serve.
--
-- WHAT IT IS NOT:
--   * not a consent grant — a plan says which regime applies, never that a
--     player agreed to anything;
--   * not permission to send anything — a valid plan is still not admission;
--   * not a geolocator — no address is read here, and a plan carrying no
--     country is normal rather than an error;
--   * not persistent — nothing is written to disk. A cached plan on disk would
--     outlive the session this contract scopes it to.
--
-- The conservative rule, which is the whole point: a plan that is missing,
-- unreadable, out of scope, expired or carrying anything outside its bounded
-- vocabulary resolves to STRICT with optional processing closed. An error or
-- an offline state can PRESERVE or ADD restrictions; it can never relax one,
-- and it can never reuse a cached permissive result.
--
-- SOFT_OPT_OUT is implemented so a future plan parses. It is NOT reachable
-- today: every row of the jurisdiction matrix is marked pending counsel
-- confirmation, so the resolver's initial release has no path that emits it.
-- Owner statement of 2026-09-18 (rendering): that matrix has no counsel
-- confirmation outside the platform's own records and was prepared as an AI
-- draft. So STRICT is not a temporary default waiting for the table to be
-- filled in; it is what an unconfirmed table can support.

local M = {}

M.STRICT_OPT_IN = "STRICT_OPT_IN"
M.SOFT_OPT_OUT = "SOFT_OPT_OUT"
M.UNKNOWN = "UNKNOWN"

M.CRASH_OFF = "OFF"
M.CRASH_MINIMAL = "MINIMAL"

M.SERVER_ANALYTICS_DENIED = "DENIED"
M.SERVER_ANALYTICS_ELIGIBLE = "ELIGIBLE"

-- The route is public API surface; the schema it speaks has exactly one
-- published copy, beside the resolver's own contract.
local ROUTE = "/api/cp/v1/consent/policy"

-- The total deadline for the whole preparation, in seconds. A late response
-- cannot change a screen that has already been presented, so one that arrives
-- after this is DROPPED rather than delivered: two callbacks would be worse
-- than a slow one.
local DEADLINE_SECONDS = 2

-- Private cache lifetime. It is a ceiling, not a target, and it never outlives
-- the plan's own expiry.
local CACHE_SECONDS = 300

-- Bounds, mirrored from the published schema so a value outside them is
-- refused HERE rather than sent and refused there. A refusal that costs a
-- request is a refusal that told a server something about this player.
local MAX_VERSION = 64
local MAX_LANGUAGE = 35
local MAX_BAND = 32
local MAX_ENTRY = 64
local MAX_ENTRIES = 64
local MAX_SIGNALS = 16
local MAX_BODY = 16 * 1024
local MAX_ENDPOINT = 256

local STORES = { steam = true, apple = true, google_play = true, standalone = true }
local PLATFORMS = {
	windows = true, macos = true, linux = true, android = true, ios = true, web = true,
}
local SIGNAL_REASONS = {
	source_not_permitted = true, source_unavailable = true, not_enabled_in_release = true,
}

-- The private cache: one entry, in memory, for this session only.
local cached = nil

-- ⚠ THE INVALIDATION COUNTER. invalidate() clearing the cache was not enough
-- on its own: a request already in flight could still complete inside its
-- deadline, deliver the decision the invalidation was meant to discard, and
-- write it back into the cache. The trigger would be undone by the very
-- request it fired against. A response is now refused unless the generation
-- it was dispatched under is still current.
local generation = 0

-- ⚠ THE GENERATION IS NOT ENOUGH ON ITS OWN. Two prepare calls for the SAME
-- context can be in flight together — they share a generation, so neither
-- supersedes the other, and whichever answers LAST writes the cache. An older
-- permissive response landing after a newer restrictive one therefore reopened
-- what the newer one had just closed. Each dispatch takes a number, the newest
-- number for a context key is remembered, and a response from an older
-- dispatch is refused rather than delivered or cached.
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
local LIST_KEYS = { operation_blocks = true, prohibited_purposes = true, signals_used = true }

-- ⚠ THE COMPLETE TOP-LEVEL VOCABULARY, and it is CLOSED. Every other bounded
-- value in this module is checked against a closed set; the set of FIELD NAMES
-- was the one that was not, so a plan could carry anything at all beside the
-- ones we read and still be used. A key we do not understand is a plan we
-- cannot say we fully read, and "use the parts I understood" is how a
-- permissive default gets in.
local SCHEMA_KEYS = {
	regime = true,
	crash_profile = true,
	server_analytics = true,
	server_analytics_objection_required = true,
	prohibited_purposes = true,
	operation_blocks = true,
	policy_version = true,
	consent_text_version = true,
	presented_language = true,
	scope = true,
	signals_used = true,
	age_band = true,
	expires_at = true,
	max_age_seconds = true,
	signature = true,
}

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
		-- so a scope carrying workspace_id twice — once the caller's, once
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
-- ⚠ THE SECOND ONE MATTERS FOR `"signature": null`. Lua has no null, so a
-- present-but-null key decodes to exactly the same nil as an absent one — and
-- this build refuses every present signature precisely because it cannot check
-- one. A response that spells the field as null would otherwise be read as
-- "no signature at all" and admitted.
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
		-- ⚠ AND A null ELEMENT INSIDE ONE OF THOSE LISTS. Lua drops it: the
		-- decoded array simply comes back one entry shorter, so a roster of
		-- three operation blocks with the middle one nulled reads as a roster
		-- of two, with nothing anywhere saying a third was sent. The raw text
		-- is again the only place that still knows.
		if LIST_KEYS[key] and body:sub(pos, pos) == "[" then
			local scan = skip_space(body, pos + 1)
			local index = 0
			while body:sub(scan, scan) ~= "]" do
				if body:sub(scan, scan + 3) == "null" then
					return false, key .. " carries a null entry", present, present_signals
				end
				index = index + 1
				-- ⚠ AND THE SIGNAL ENTRIES NEED THEIR OWN PRESENCE MAP. A
				-- signal's `reason` present-and-null decodes to the same nil as
				-- an absent one, and an unavailable signal with no reason is
				-- the shape that hides a prohibited source — so the entry would
				-- be refused for the right reason by luck, or accepted if the
				-- nulled field were one the entry did not need. The nullability
				-- rule has to reach inside the list, not stop at its name.
				local collect = nil
				if key == "signals_used" and body:sub(scan, scan) == "{" then
					collect = {}
					present_signals[index] = collect
				end
				local element_end = skip_value(body, scan, 1, collect)
				if not element_end then
					return false, "the plan is not readable", present, present_signals
				end
				scan = skip_space(body, element_end)
				if body:sub(scan, scan) == "," then
					scan = skip_space(body, scan + 1)
				elseif body:sub(scan, scan) ~= "]" then
					return false, "the plan is not readable", present, present_signals
				end
			end
		end
		local next_pos = skip_value(body, pos, 1)
		if not next_pos then
			return false, "the plan is not readable", present, present_signals
		end
		pos = skip_space(body, next_pos)
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

-- Depth-bounded copy, the same shape the remote-config and experiments caches
-- use, so a decision handed to game code can be mutated freely without
-- corrupting the entry the next prepare serves. Decisions are acyclic; the cap
-- only bounds the walk.
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

-- ⚠ THE CACHE KEY IS THE WHOLE CONTEXT. One in-memory entry is shared by
-- every caller in the process, and serving it on liveness alone applied one
-- app's, environment's or endpoint's plan to another — past the scope check
-- in parse_plan, which only ever saw the context that produced the entry.
-- Length-prefixed, so no two different contexts can spell the same key.
local function context_key(context)
	local parts = {}
	local function field(value)
		value = value or ""
		parts[#parts + 1] = string.format("%d:%s", #value, value)
	end
	field(context.workspace_id)
	field(context.app_id)
	field(context.environment_id)
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
	local reason = decoded.reason
	if type(reason) == "string" and #reason > 0 and #reason <= MAX_ENTRY
		and reason:match("^[a-z0-9_]+$") then
		return reason
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
		server_analytics_objection_required = true,
		optional_processing_closed = true,
		plan_used = false,
		reason = reason,
		detail = detail,
	}
end

local function bounded_string(value, limit)
	return type(value) == "string" and #value > 0 and #value <= limit
end

local function version_ok(value)
	return bounded_string(value, MAX_VERSION) and value:match("^[A-Za-z0-9._+-]+$") ~= nil
end

-- Validates the CALLER's context before anything is sent. A value outside the
-- closed vocabulary never reaches the wire.
-- ⚠ THE CALLER'S FIELD NAMES ARE A CLOSED SET FOR THE SAME REASON THE PLAN'S
-- ARE. A key we do not read is a context we cannot say we understood, and the
-- shape it actually takes in practice is a typo: `age_bnad` is silently no age
-- band at all, so the request goes out claiming this player has none.
local CONTEXT_KEYS = {
	endpoint = true,
	workspace_id = true,
	app_id = true,
	environment_id = true,
	app_version = true,
	store = true,
	store_region = true,
	locale = true,
	platform = true,
	age_band = true,
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
	for _, field in ipairs({ "workspace_id", "app_id", "environment_id" }) do
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
	if context.age_band ~= nil then
		local band = context.age_band
		if type(band) ~= "table" or not bounded_string(band.vocabulary, MAX_BAND)
			or not bounded_string(band.band, MAX_BAND) then
			return false, "age_band is malformed or over its bound"
		end
	end
	return true
end

local function request_body(context)
	local body = {
		workspace_id = context.workspace_id,
		app_id = context.app_id,
		environment_id = context.environment_id,
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
	return body
end

-- Reads a plan. It REFUSES rather than repairs: a plan the SDK cannot fully
-- read is a plan it cannot act on, and "use the parts I understood" is how a
-- permissive default gets in.
-- `now` is seconds since the epoch. It is what makes expiry enforceable here
-- rather than merely described; a caller with no clock passes nothing and
-- prepare refuses before it ever reaches this point.
function M.parse_plan(plan, context, now)
	if type(plan) ~= "table" then
		return nil, "the plan is not an object"
	end
	if plan.regime ~= M.STRICT_OPT_IN and plan.regime ~= M.SOFT_OPT_OUT and plan.regime ~= M.UNKNOWN then
		return nil, "unknown regime"
	end
	if plan.crash_profile ~= M.CRASH_OFF and plan.crash_profile ~= M.CRASH_MINIMAL then
		return nil, "unknown crash_profile"
	end
	if plan.server_analytics ~= M.SERVER_ANALYTICS_DENIED
		and plan.server_analytics ~= M.SERVER_ANALYTICS_ELIGIBLE then
		return nil, "unknown server_analytics"
	end
	if not version_ok(plan.policy_version) or not version_ok(plan.consent_text_version) then
		return nil, "a version field is missing or outside its bound"
	end
	-- presented_language names the ACTUAL supported text; it is bounded but not
	-- required to echo the requested locale.
	if not bounded_string(plan.presented_language, MAX_LANGUAGE) then
		return nil, "presented_language is missing or over its bound"
	end
	-- ⚠ THE BAND IS THE ONLY AGE SHAPE THAT TRAVELS, so its shape is checked
	-- rather than assumed. validate_context checks the band the CALLER sends;
	-- nothing checked the one the resolver sends back, so a plan could echo an
	-- age_band of any shape at all and be used.
	if plan.age_band ~= nil then
		local band = plan.age_band
		if type(band) ~= "table" or not bounded_string(band.vocabulary, MAX_BAND)
			or not bounded_string(band.band, MAX_BAND) then
			return nil, "age_band is malformed or over its bound"
		end
		-- ⚠ AND ITS KEY SET IS CLOSED, like the top level's. A nested object
		-- whose names are unchecked is the top-level hole one level down: an
		-- age_band could carry anything beside the two fields we read and still
		-- be used, and a band is the only age shape that travels.
		for key in pairs(band) do
			if key ~= "vocabulary" and key ~= "band" then
				return nil, "age_band carries an unknown key"
			end
		end
	end
	local scope = plan.scope
	if type(scope) ~= "table" or scope.workspace_id ~= context.workspace_id
		or scope.app_id ~= context.app_id or scope.environment_id ~= context.environment_id then
		return nil, "the plan is scoped to another app, environment or workspace"
	end
	-- ⚠ A STRING IS NOT A BOOLEAN. "true" was coerced to false below, and the
	-- objection requirement it carried vanished into a plan marked USED. An
	-- ABSENT field is not false either: the requirement stands unless the plan
	-- says, as a boolean, that it does not.
	if plan.server_analytics_objection_required ~= nil
		and type(plan.server_analytics_objection_required) ~= "boolean" then
		return nil, "server_analytics_objection_required is not a boolean"
	end
	if plan.signals_used ~= nil then
		if type(plan.signals_used) ~= "table" or #plan.signals_used > MAX_SIGNALS
			or not is_sequence(plan.signals_used) then
			return nil, "signals_used is malformed or over its bound"
		end
		for _, signal in ipairs(plan.signals_used) do
			if type(signal) ~= "table" or not bounded_string(signal.name, MAX_ENTRY) then
				return nil, "a signal is malformed"
			end
			-- ⚠ available IS A BOOLEAN OR THE PLAN IS MALFORMED, the same rule
			-- the objection field gets. `available ~= true` quietly folded the
			-- string "yes", the number 0 and an absent key into "unavailable" —
			-- an answer the resolver never gave, written into the provenance
			-- record as though it had. Unreadable and unavailable are different
			-- facts and this record exists to keep them apart.
			if type(signal.available) ~= "boolean" then
				return nil, "a signal does not state whether it was available"
			end
			-- ⚠ A reason IS CHECKED WHEREVER IT APPEARS, not only where it is
			-- required. The vocabulary was enforced on the branch that needs a
			-- reason and nowhere else, so an AVAILABLE signal could carry any
			-- string at all — and this list is a provenance record, so an
			-- unreadable reason on it is a claim about how the resolver reached
			-- its answer that nothing checked.
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
	for _, name in ipairs({ "prohibited_purposes", "operation_blocks" }) do
		local list = plan[name]
		if list ~= nil then
			if type(list) ~= "table" or #list > MAX_ENTRIES or not is_sequence(list) then
				return nil, name .. " is malformed or over its bound"
			end
			for _, entry in ipairs(list) do
				if not bounded_string(entry, MAX_ENTRY) then
					return nil, "an entry of " .. name .. " is malformed"
				end
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
	-- not a weaker plan, it is no plan. It used to be READ for its shape and
	-- then used, so an expired SOFT_OPT_OUT went on reporting optional
	-- processing open.
	if type(now) == "number" and expires_at <= now then
		return nil, "the plan has already expired"
	end
	if plan.max_age_seconds ~= nil
		and (type(plan.max_age_seconds) ~= "number" or plan.max_age_seconds < 0
			or plan.max_age_seconds % 1 ~= 0) then
		return nil, "max_age_seconds is not a whole non-negative number"
	end
	-- The signature is reserved and absent in the resolver's initial release.
	-- If one is PRESENT, this build cannot verify it — and an unverifiable
	-- signature must not admit, or the field's arrival becomes a downgrade.
	-- ⚠ AN EMPTY SIGNATURE IS STILL A SIGNATURE. `""` was waved through as
	-- though the field were absent, which is the downgrade path itself: a
	-- signed response whose signature failed to serialise would admit.
	if plan.signature ~= nil then
		return nil, "the plan carries a signature this build cannot verify"
	end
	return plan, nil, expires_at
end

local function decision_from_plan(plan)
	return {
		regime = plan.regime,
		crash_profile = plan.crash_profile,
		server_analytics = plan.server_analytics,
		-- Absence is not false. Only an explicit boolean false lifts it, and
		-- parse_plan has already refused anything that is not a boolean.
		server_analytics_objection_required = plan.server_analytics_objection_required ~= false,
		-- ⚠ FALSE IS NOT PERMISSION. It says only that the regime is not what
		-- closed the door: SOFT still waits for the final notice barrier and
		-- for the backend admission bound to this session, which this module
		-- knows nothing about.
		optional_processing_closed = plan.regime ~= M.SOFT_OPT_OUT,
		plan_used = true,
		reason = nil,
		-- ⚠ HOW LONG THIS VERDICT IS GOOD FOR, in seconds, set by prepare
		-- rather than here because it depends on when the answer ARRIVED. The
		-- host needs it: cache expiry protects the next lookup and stops
		-- nothing that is already running, so a lane opened on a permissive
		-- plan would otherwise stay open long past the plan's life. A fallback
		-- carries no validity at all — it established nothing to be valid.
		valid_for_seconds = nil,
		policy_version = plan.policy_version,
		consent_text_version = plan.consent_text_version,
		presented_language = plan.presented_language,
		prohibited_purposes = plan.prohibited_purposes,
		operation_blocks = plan.operation_blocks,
	}
end

-- Clears the private cache. The host calls it on the named re-resolution
-- triggers: launch and resume, a network or permitted storefront change, an
-- age correction, a language or text change, a workspace or app change, a
-- policy revocation, and before the first optional admission.
function M.invalidate()
	cached = nil
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

	local ok, why = M.validate_context(context)
	if not ok then
		callback(strict("invalid_request", why))
		return
	end

	local at = now_seconds()
	-- ⚠ NO CLOCK, NO PLAN. Expiry is enforced by comparing the plan's
	-- expires_at against this reading, so without it an expired plan could not
	-- be recognised as expired — and "used because we could not check" is the
	-- permissive default the conservative rule exists to forbid.
	if not at then
		callback(strict("clock_unavailable", "no clock is available to evaluate the plan's expiry"))
		return
	end

	-- ⚠ THE TRANSPORT IS CHECKED BEFORE THE CACHE IS READ, AND THE ORDER IS THE
	-- RULE. With the cache first, losing the network served the last permissive
	-- answer for the rest of the window — the one thing "an offline state can
	-- tighten but never relax" forbids, and it read as a cache hit rather than
	-- as an outage. A missing transport is a fallback, and a fallback wins.
	if not http or not http.request then
		callback(strict("transport_unavailable", "no http transport is available"))
		return
	end
	if not json or not json.decode then
		callback(strict("decoder_unavailable", "no json decoder is available"))
		return
	end
	if not json.encode then
		callback(strict("encoder_unavailable", "no json encoder is available"))
		return
	end

	local key = context_key(context)
	-- ⚠ A CLOCK THAT WENT BACKWARDS INVALIDATES THE ENTRY. socket.gettime is
	-- wall-clock: an NTP step, a manual change or a device waking with a bad
	-- RTC can put `at` BEFORE the moment this entry was written, and then
	-- `until_at > at` is true for as long as the clock is wrong — an entry that
	-- outlives its plan by however far the clock slipped. It cannot be aged, so
	-- it is discarded.
	if cached and at < cached.inserted_at then
		cached = nil
	end
	if cached and cached.key == key and cached.until_at > at then
		-- ⚠ A COPY, NOT THE ENTRY. The cache used to hand out the very table it
		-- kept, so a caller that wrote a field on the decision it was given —
		-- or that read prohibited_purposes and sorted it in place — edited what
		-- every later prepare would serve for the next five minutes.
		local served = copy_value(cached.decision, 0)
		-- Counts DOWN, and never above the window the plan originally had:
		-- a forward clock step must not hand the host a longer life than the
		-- resolver granted.
		local remaining = cached.until_at - at
		served.valid_for_seconds = remaining < cached.lifetime and remaining or cached.lifetime
		callback(served)
		return
	end

	-- ⚠ AND THE ENCODER IS CALLED THROUGH pcall. json.encode raises on a value
	-- it cannot represent, and an error thrown out of prepare is not a strict
	-- decision — it is NO decision, so the one callback this module promises
	-- never arrives and the caller has nothing to fail closed on.
	local encoded_ok, encoded = pcall(json.encode, request_body(context))
	if not encoded_ok or type(encoded) ~= "string" then
		callback(strict("encoder_failed", "the request body could not be encoded"))
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
			settle(strict("clock_unavailable", "no clock is available to evaluate the plan's expiry"))
			return
		end
		-- ⚠ THE CLOCK MOVED BACKWARDS WHILE THIS REQUEST WAS IN FLIGHT. Every
		-- judgement below is a comparison against `arrived` — the deadline, the
		-- expiry, the cache lifetime — and a reading earlier than the one this
		-- request was dispatched with makes all of them meaningless in the
		-- permissive direction: a plan looks fresher and an entry lives longer.
		-- It is refused before anything is parsed or cached.
		if arrived < at then
			settle(strict("clock_regressed", "the clock moved backwards while the request was in flight"))
			return
		end
		-- ⚠ AN INVALIDATED REQUEST CANNOT ANSWER. A policy revocation or a
		-- workspace change fired while this was in flight; its answer describes
		-- the world the host has just declared gone, so it is refused here
		-- rather than delivered — and, crucially, never written to the cache.
		if dispatched_under ~= generation then
			settle(strict("invalidated", "the policy was invalidated while this request was in flight"))
			return
		end
		-- ⚠ A LATER DISPATCH FOR THIS CONTEXT HAS ALREADY BEEN MADE, so this
		-- answer describes an older question. It is still ANSWERED — exactly
		-- one callback, strict — but it does not reach the cache, which is
		-- where an older permissive plan used to overwrite a newer restrictive
		-- one purely by arriving second.
		if latest_dispatch[key] ~= dispatch then
			settle(strict("superseded", "a later request for this context was dispatched first"))
			return
		end
		latest_dispatch[key] = nil
		if arrived > deadline then
			settle(strict("deadline_exceeded", "the response arrived after the total deadline"))
			return
		end
		if type(response) ~= "table" or response.status == nil then
			settle(strict("transport_error", "no response"))
			return
		end
		local body = response.response
		if type(body) ~= "string" or #body == 0 or #body > MAX_BODY then
			settle(strict("invalid_response", "the response body is empty or over its bound"))
			return
		end
		local decoded_ok, decoded = pcall(json.decode, body)
		if not decoded_ok or type(decoded) ~= "table" then
			settle(strict("invalid_response", "the response body is not readable"))
			return
		end
		-- ⚠ THE STATUS DECIDES WHICH DOCUMENT THIS IS, AND IT HAS TO BE ASKED
		-- FIRST. An error body is an ERROR ENVELOPE, not a plan, so running the
		-- plan-key allowlist over it refused a perfectly well-formed
		-- {"reason": ...} for carrying a key that is not a plan field — a
		-- regression I introduced with the allowlist, which turned every
		-- resolver refusal into "unreadable" and lost the reason it gave.
		if response.status < 200 or response.status >= 300 then
			settle(strict(error_envelope_reason(decoded), "the resolver refused"))
			return
		end
		local shapes_ok, shape_refusal, present, present_signals = scan_plan_text(body)
		if not shapes_ok then
			settle(strict("invalid_response", shape_refusal))
			return
		end
		-- ⚠ NO FIELD IN THIS SCHEMA IS NULLABLE, AND THAT IS ONE RULE RATHER
		-- THAN A LIST OF FIELDS. Lua has no null, so every present-and-null key
		-- decodes to exactly the nil an absent key decodes to — and this module
		-- reads absence as a meaning everywhere: an absent signature is
		-- unsigned, an absent objection requirement stands, an absent list is
		-- no restrictions. Each of those was a separate hole, and patching them
		-- one at a time is how the next added field arrives with the same one.
		-- The raw scan knows which keys were present; anything present whose
		-- decoded value is nil is malformed, whatever it is.
		for key in pairs(present) do
			if decoded[key] == nil then
				settle(strict("invalid_response", key .. " is present and null"))
				return
			end
		end
		-- The same rule inside each signal entry.
		for index, keys in pairs(present_signals) do
			local entry = type(decoded.signals_used) == "table" and decoded.signals_used[index] or nil
			if type(entry) ~= "table" then
				settle(strict("invalid_response", "a signal entry is not an object"))
				return
			end
			for key in pairs(keys) do
				if entry[key] == nil then
					settle(strict("invalid_response", "a signal entry carries " .. key .. " present and null"))
					return
				end
			end
		end
		local plan, refusal, expires_at = M.parse_plan(decoded, context, arrived)
		if not plan then
			settle(strict("invalid_response", refusal))
			return
		end
		local decision = decision_from_plan(plan)
		-- ⚠ ONLY A LIVE, VERIFIED PLAN IS EVER CACHED, and never past the
		-- SHORTEST of the cache ceiling, the plan's own expiry and its
		-- max_age_seconds. The ceiling used to win outright, so a plan with ten
		-- seconds of life left was served from memory for five minutes. An
		-- error or offline state reaches this line never, which is what stops a
		-- cached permission being reused when the network is gone.
		local lifetime = CACHE_SECONDS
		if expires_at - arrived < lifetime then
			lifetime = expires_at - arrived
		end
		if plan.max_age_seconds ~= nil and plan.max_age_seconds < lifetime then
			lifetime = plan.max_age_seconds
		end
		decision.valid_for_seconds = lifetime
		if lifetime > 0 then
			-- The entry gets its OWN copy too, so the table delivered below and
			-- the table kept here are never the same object.
			cached = {
				key = key,
				decision = copy_value(decision, 0),
				inserted_at = arrived,
				lifetime = lifetime,
				until_at = arrived + lifetime,
			}
		else
			-- max_age_seconds = 0 says "do not reuse this". The plan is still
			-- live for this one answer; it is simply not cacheable.
			cached = nil
		end
		settle(decision)
	end, { ["Content-Type"] = "application/json" }, encoded, { timeout = DEADLINE_SECONDS })
end

return M
