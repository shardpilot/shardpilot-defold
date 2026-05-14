local M = {}

function M.new(limit)
	return {
		limit = limit or 200,
		items = {},
	}
end

function M.push(queue, item)
	if #queue.items >= queue.limit then
		return false
	end
	queue.items[#queue.items + 1] = item
	return true
end

function M.drain(queue, max_count)
	local count = math.min(max_count or #queue.items, #queue.items)
	local out = {}
	for i = 1, count do
		out[i] = queue.items[i]
	end
	for i = count + 1, #queue.items do
		queue.items[i - count] = queue.items[i]
	end
	for i = #queue.items, #queue.items - count + 1, -1 do
		queue.items[i] = nil
	end
	return out
end

function M.size(queue)
	return #queue.items
end

return M
