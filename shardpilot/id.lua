local M = {}

local hex = "0123456789abcdef"
local seeded = false

local function seed_once()
	if seeded then
		return
	end
	local seed = os.time()
	if socket and socket.gettime then
		seed = seed + math.floor(socket.gettime() * 1000000)
	end
	local address = tostring({}):match("0x(%x+)")
	if address then
		seed = seed + (tonumber(address:sub(-7), 16) or 0)
	end
	math.randomseed(seed)
	math.random()
	math.random()
	seeded = true
end

local function random_hex(count)
	local out = {}
	for i = 1, count do
		local n = math.random(1, 16)
		out[i] = hex:sub(n, n)
	end
	return table.concat(out)
end

function M.uuid()
	seed_once()
	return table.concat({
		random_hex(8),
		random_hex(4),
		"4" .. random_hex(3),
		string.format("%x", math.random(8, 11)) .. random_hex(3),
		random_hex(12),
	}, "-")
end

return M
