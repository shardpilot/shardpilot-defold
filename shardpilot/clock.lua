local M = {}

function M.unix_ms()
	if socket and socket.gettime then
		return math.floor(socket.gettime() * 1000)
	end
	return os.time() * 1000
end

function M.iso_utc(ms)
	local seconds = math.floor((ms or M.unix_ms()) / 1000)
	return os.date("!%Y-%m-%dT%H:%M:%SZ", seconds)
end

return M
