local M = { NAME = "X-ShardPilot-Anonymous-Id" }

-- Identity bytes must survive HTTP field parsing without splitting or trimming.
function M.valid(value)
	if type(value) ~= "string" or value == "" then return false end
	if value:byte(1) == 32 or value:byte(-1) == 32 then return false end
	for index = 1, #value do
		local byte = value:byte(index)
		if byte < 32 or byte == 127 then return false end
	end
	return true
end

return M
