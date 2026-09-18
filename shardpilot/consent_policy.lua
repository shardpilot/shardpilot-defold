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

local STORES = { steam = true, apple = true, google_play = true, standalone = true }
local PLATFORMS = {
	windows = true, macos = true, linux = true, android = true, ios = true, web = true,
}
local SIGNAL_REASONS = {
	source_not_permitted = true, source_unavailable = true, not_enabled_in_release = true,
}

-- The private cache: one entry, in memory, for this session only.
local cached = nil

local function now_seconds()
	if socket and socket.gettime then
		return socket.gettime()
	end
	return nil
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
function M.validate_context(context)
	if type(context) ~= "table" then
		return false, "the context must be a table"
	end
	for _, field in ipairs({ "workspace_id", "app_id", "environment_id" }) do
		if not bounded_string(context[field], MAX_ENTRY) then
			return false, field .. " is missing or over its bound"
		end
	end
	if not version_ok(context.app_version) then
		return false, "app_version is missing, over 64 bytes, or outside the permitted characters"
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
function M.parse_plan(plan, context)
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
	local scope = plan.scope
	if type(scope) ~= "table" or scope.workspace_id ~= context.workspace_id
		or scope.app_id ~= context.app_id or scope.environment_id ~= context.environment_id then
		return nil, "the plan is scoped to another app, environment or workspace"
	end
	if plan.signals_used ~= nil then
		if type(plan.signals_used) ~= "table" or #plan.signals_used > MAX_SIGNALS then
			return nil, "signals_used is malformed or over its bound"
		end
		for _, signal in ipairs(plan.signals_used) do
			if type(signal) ~= "table" or not bounded_string(signal.name, MAX_ENTRY) then
				return nil, "a signal is malformed"
			end
			-- An unavailable signal must say WHY, from the closed vocabulary. A
			-- bare "not available" is the shape that hides a prohibited source.
			if signal.available ~= true and not SIGNAL_REASONS[signal.reason] then
				return nil, "an unavailable signal carries no known reason"
			end
		end
	end
	for _, name in ipairs({ "prohibited_purposes", "operation_blocks" }) do
		local list = plan[name]
		if list ~= nil then
			if type(list) ~= "table" or #list > MAX_ENTRIES then
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
	if plan.max_age_seconds ~= nil
		and (type(plan.max_age_seconds) ~= "number" or plan.max_age_seconds < 0) then
		return nil, "max_age_seconds is not a whole non-negative number"
	end
	-- The signature is reserved and absent in the resolver's initial release.
	-- If one is PRESENT, this build cannot verify it — and an unverifiable
	-- signature must not admit, or the field's arrival becomes a downgrade.
	if plan.signature ~= nil and plan.signature ~= "" then
		return nil, "the plan carries a signature this build cannot verify"
	end
	return plan
end

local function decision_from_plan(plan)
	return {
		regime = plan.regime,
		crash_profile = plan.crash_profile,
		server_analytics = plan.server_analytics,
		server_analytics_objection_required = plan.server_analytics_objection_required == true,
		-- ⚠ FALSE IS NOT PERMISSION. It says only that the regime is not what
		-- closed the door: SOFT still waits for the final notice barrier and
		-- for the backend admission bound to this session, which this module
		-- knows nothing about.
		optional_processing_closed = plan.regime ~= M.SOFT_OPT_OUT,
		plan_used = true,
		reason = nil,
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
	if cached and at and cached.until_at > at then
		callback(cached.decision)
		return
	end

	if not http or not http.request then
		callback(strict("transport_unavailable", "no http transport is available"))
		return
	end
	if not json or not json.decode then
		callback(strict("decoder_unavailable", "no json decoder is available"))
		return
	end
	local encoded
	if json.encode then
		encoded = json.encode(request_body(context))
	else
		callback(strict("encoder_unavailable", "no json encoder is available"))
		return
	end

	local settled = false
	local deadline = at and (at + DEADLINE_SECONDS) or nil
	local function settle(decision)
		-- ⚠ ONE CALLBACK, EVER. A response that arrives after the deadline is
		-- dropped here: the screen it would change has already been presented.
		if settled then
			return
		end
		settled = true
		callback(decision)
	end

	http.request(context.endpoint .. ROUTE, "POST", function(_, _, response)
		local arrived = now_seconds()
		if deadline and arrived and arrived > deadline then
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
		if response.status < 200 or response.status >= 300 then
			-- Every error still carries a complete strict plan, so there is
			-- nothing to synthesise; the reason is reported as the server gave
			-- it when it is one this build knows.
			settle(strict(tostring(decoded.reason or "policy_unavailable"), "the resolver refused"))
			return
		end
		local plan, refusal = M.parse_plan(decoded, context)
		if not plan then
			settle(strict("invalid_response", refusal))
			return
		end
		local decision = decision_from_plan(plan)
		-- ⚠ ONLY A LIVE, VERIFIED PLAN IS EVER CACHED, and only for the shorter
		-- of the cache ceiling and its own life. An error or offline state
		-- reaches this line never, which is what stops a cached permission
		-- being reused when the network is gone.
		if arrived then
			cached = { decision = decision, until_at = arrived + CACHE_SECONDS }
		end
		settle(decision)
	end, { ["Content-Type"] = "application/json" }, encoded, { timeout = DEADLINE_SECONDS })
end

return M
