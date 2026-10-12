-- One plausibility rule for in-memory and persisted crash retry deadlines.
-- Wall-clock rollback must not strand a report beyond its source's bound.
local M = { local_limit_ms = 60 * 1000, server_limit_ms = 24 * 60 * 60 * 1000 }

function M.normalize(value, now, limit_ms)
	if type(value) == "number" and value > now and value <= now + limit_ms then
		return value
	end
	return nil
end

return M
