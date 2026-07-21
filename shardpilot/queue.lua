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

-- Remove every queued item the predicate matches, preserving the order of
-- the rest. Returns the number removed.
function M.remove_matching(queue, predicate)
	local kept = {}
	local removed = 0
	for i = 1, #queue.items do
		local item = queue.items[i]
		if predicate(item) then
			removed = removed + 1
		else
			kept[#kept + 1] = item
		end
	end
	if removed > 0 then
		queue.items = kept
	end
	return removed
end

return M
