local M = {}

local replacement = string.char(239, 191, 189)

local function continuation(byte)
	return byte ~= nil and byte >= 128 and byte <= 191
end

-- Match the ingest decoder: consume one byte on an invalid encoding and
-- emit U+FFFD. Valid scalar encodings are preserved, with no normalization.
-- Return the repaired string and its code-point count from the same scan.
function M.repair(value)
	if type(value) ~= "string" then
		return value
	end
	if not value:find("[\128-\255]") then
		return value, #value
	end
	local pieces, start, index, count = nil, 1, 1, 0
	while index <= #value do
		local first, second, third, fourth = value:byte(index, index + 3)
		local width = 0
		if first < 128 then
			width = 1
		elseif first >= 194 and first <= 223 and continuation(second) then
			width = 2
		elseif first >= 224 and first <= 239 and continuation(second) and continuation(third)
			and (first ~= 224 or second >= 160) and (first ~= 237 or second <= 159) then
			width = 3
		elseif first >= 240 and first <= 244 and continuation(second)
			and continuation(third) and continuation(fourth)
			and (first ~= 240 or second >= 144) and (first ~= 244 or second <= 143) then
			width = 4
		end
		if width == 0 then
			pieces = pieces or {}
			pieces[#pieces + 1] = value:sub(start, index - 1)
			pieces[#pieces + 1] = replacement
			index = index + 1
			start = index
		else
			index = index + width
		end
		count = count + 1
	end
	if not pieces then
		return value, count
	end
	pieces[#pieces + 1] = value:sub(start)
	return table.concat(pieces), count
end

return M
