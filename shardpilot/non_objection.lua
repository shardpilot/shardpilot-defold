-- Closed snapshots for an analytics non-objection, separate from consent.
-- This is the SDK's structural subset: locale registry membership belongs to
-- the server. A valid snapshot is host data, never policy authority or a grant.
local notice = require "shardpilot.consent_notice"
local utf8 = require "shardpilot.utf8"
local M = {}

local function literal(expected)
	return function(value) if value == expected then return value end end
end

local function text(minimum, maximum)
	return function(value)
		if type(value) ~= "string" then return nil end
		local repaired, count = utf8.repair(value)
		if repaired == value and count >= minimum and count <= maximum then return value end
	end
end

local function hex(length)
	return function(value)
		if type(value) == "string" and #value == length and value:match("^[a-f0-9]+$") then return value end
	end
end

local function date(value)
	if type(value) ~= "string" then return nil end
	local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not year then return nil end
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
	local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if days[month] and day >= 1 and day <= days[month] then return value end
end

local function object(shape)
	return function(value)
		if type(value) ~= "table" then return nil end
		for key in next, value do if not shape[key] then return nil end end
		local copy = {}
		for key, capture in pairs(shape) do
			local item = capture(rawget(value, key))
			if item == nil then return nil end
			copy[key] = item
		end
		return copy
	end
end

local capture = object({
	advisory = object({
		matrix = object({ docs_commit = hex(40), file_sha256 = hex(64), date = date }),
		row_id = text(1, 64),
		jurisdiction = function(value)
			if type(value) == "string" and value:match("^[A-Z][A-Z]$") then return value end
		end,
	}),
	age_evidence_class = literal("eligible_adult"),
	attestation = object({ notice_provided = literal(true), free_simple_objection_provided = literal(true),
		did_not_object = literal(true), eligible = literal(true) }),
	notice_version = text(1, 64), notice_locale = text(2, 35), policy_version = text(1, 64),
})

function M.snapshot(value)
	local copy = capture(value)
	if not copy or not notice.snapshot({ notice_version = copy.notice_version,
		notice_locale = copy.notice_locale, policy_version = copy.policy_version }) then
		return nil, "non_objection_invalid"
	end
	return copy
end

function M.from_receipt(value)
	if type(value) ~= "table" or value.admission_basis ~= "advisory_non_objection"
		or value.purpose ~= "analytics" or value.categories ~= nil or value.reason ~= nil then return nil end
	return M.snapshot({ advisory = value.advisory, age_evidence_class = value.age_evidence_class,
		attestation = value.attestation, notice_version = value.notice_version,
		notice_locale = value.notice_locale, policy_version = value.policy_version })
end

-- Both inputs are closed snapshots, so recursive equality is bounded.
function M.equal(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then return left == right end
	for key, value in pairs(left) do if not M.equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

local response = object({ recorded = literal(true), admission_basis = literal("advisory_non_objection"),
	replayed = function(value) if type(value) == "boolean" then return value end end })

-- Decoded acknowledgement shape only; no transport, consent or admission effect.
function M.response(value)
	local copy = response(value)
	if not copy then return nil, "non_objection_response_invalid" end
	return copy
end

return M
