local M = {}

local hex = "0123456789abcdef"

local function random_hex(count)
	local out = {}
	for i = 1, count do
		local n = math.random(1, 16)
		out[i] = hex:sub(n, n)
	end
	return table.concat(out)
end

function M.uuid()
	return table.concat({
		random_hex(8),
		random_hex(4),
		"4" .. random_hex(3),
		string.format("%x", math.random(8, 11)) .. random_hex(3),
		random_hex(12),
	}, "-")
end

return M
