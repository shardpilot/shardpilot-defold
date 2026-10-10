local clock = require "shardpilot.clock"
local random = require "shardpilot.random"

local M = {}

local random_hex = random.hex

function M.uuid()
	return table.concat({
		random_hex(8),
		random_hex(4),
		"4" .. random_hex(3),
		string.format("%x", 8 + math.floor(random.unit() * 4)) .. random_hex(3),
		random_hex(12),
	}, "-")
end

function M.uuid_v7()
	local unix_ms = clock.unix_ms() % 0x1000000000000
	local time_hex = string.format("%012x", unix_ms)
	return table.concat({
		time_hex:sub(1, 8),
		time_hex:sub(9, 12),
		"7" .. random_hex(3),
		string.format("%x", 8 + math.floor(random.unit() * 4)) .. random_hex(3),
		random_hex(12),
	}, "-")
end

return M
