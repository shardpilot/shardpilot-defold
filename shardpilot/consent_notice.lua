-- Per-decision provenance. Locale validation is structural, not registry lookup.
local M = {}
local version_ok = require "shardpilot.consent_version"
local fields = { notice_version = true, notice_locale = true, policy_version = true }
-- RFC 5646 section 2.1's fixed irregular productions; regular grandfathered
-- tags already match the grammar below. This is not a locale registry.
local irregular = {}
for tag in ("en-gb-oed i-ami i-bnn i-default i-enochian i-hak i-klingon i-lux " ..
	"i-mingo i-navajo i-pwn i-tao i-tay i-tsu sgn-be-fr sgn-be-nl sgn-ch-de"):gmatch("%S+") do
	irregular[tag] = true
end

local function locale(value)
	if type(value) ~= "string" or #value < 2 or #value > 35
		or not value:match("^[A-Za-z0-9-]+$")
		or value:sub(1, 1) == "-" or value:sub(-1) == "-" or value:find("--", 1, true) then
		return false
	end
	local lower, parts = value:lower(), {}
	if irregular[lower] then return true end
	for part in lower:gmatch("[^-]+") do
		if #part > 8 then return false end
		parts[#parts + 1] = part
	end
	if parts[1] == "x" then return #parts > 1 end
	local function alpha(part, minimum, maximum)
		return part and #part >= minimum and #part <= maximum and part:match("^[a-z]+$")
	end
	if not alpha(parts[1], 2, 8) then return false end
	local i = 2
	if #parts[1] <= 3 then
		for _ = 1, 3 do
			if alpha(parts[i], 3, 3) then i = i + 1 else break end
		end
	end
	if alpha(parts[i], 4, 4) then i = i + 1 end
	if alpha(parts[i], 2, 2) or (parts[i] and parts[i]:match("^%d%d%d$")) then i = i + 1 end
	local variants = {}
	while parts[i] and (#parts[i] >= 5 or (#parts[i] == 4 and parts[i]:match("^%d"))) do
		if variants[parts[i]] then return false end
		variants[parts[i]] = true; i = i + 1
	end
	local singletons = {}
	while parts[i] and #parts[i] == 1 and parts[i] ~= "x" do
		if singletons[parts[i]] then return false end
		singletons[parts[i]] = true; i = i + 1
		local first = i
		while parts[i] and #parts[i] >= 2 do i = i + 1 end
		if i == first then return false end
	end
	if parts[i] == "x" then return i < #parts end
	return i > #parts
end

function M.snapshot(value)
	if value == nil then return nil end
	if type(value) ~= "table" then return nil, "consent_notice_invalid" end
	local captured = {}
	for key, item in next, value do
		if not fields[key] then return nil, "consent_notice_invalid" end
		captured[key] = item
	end
	if not version_ok(captured.notice_version) or not version_ok(captured.policy_version)
		or not locale(captured.notice_locale) then return nil, "consent_notice_invalid" end
	return captured
end

-- Legacy receipts have no tuple. A present malformed tuple is not rewritten
-- under its old idempotency key; the outbox's existing corruption rule applies.
function M.from_receipt(entry)
	if type(entry) ~= "table" then return nil, "consent_notice_invalid" end
	local notice_version = rawget(entry, "notice_version")
	local notice_locale = rawget(entry, "notice_locale")
	local policy_version = rawget(entry, "policy_version")
	if notice_version == nil and notice_locale == nil and policy_version == nil then return nil end
	return M.snapshot({ notice_version = notice_version, notice_locale = notice_locale, policy_version = policy_version })
end

return M
