-- Every request to a ShardPilot service names this SDK and its release in one
-- header: `X-ShardPilot-SDK: defold/<version>`. The version is the constant the
-- release tag is cut from (shardpilot/version.lua), without build metadata.
local version = require "shardpilot.version"

local M = {}

M.NAME = "X-ShardPilot-SDK"

-- The header value for a release version. A constant outside the grammar
-- (MAJOR.MINOR.PATCH with an optional pre-release, at most 64 bytes of
-- visible ASCII in all) fails at load, never on the wire.
function M.value_for(release)
	local core = type(release) == "string" and release:gsub("%+.*$", "") or ""
	local pre_release = core:match("^%d+%.%d+%.%d+%-([%w%-%.]+)$")
	assert(core:match("^%d+%.%d+%.%d+$") or pre_release, "invalid SDK release version: " .. tostring(release))
	local value = "defold/" .. core
	assert(#value <= 64, "SDK header value longer than 64 bytes")
	return value
end

M.VALUE = M.value_for(version.VERSION)

return M
