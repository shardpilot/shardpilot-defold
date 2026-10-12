-- Supported instance operations bound to private implementation state.
local M = {}
local unpack_args = table.unpack or unpack
local function bind(client, method, argument_count)
	return function(_, ...)
		return method(client, unpack_args({ ... }, 1, argument_count))
	end
end
-- A method entry is its argument count, or { argument_count, implementation }
-- when the public name is served by a differently named client method.
function M.new(client, methods)
	local public = {}
	for name, spec in pairs(methods) do
		local argument_count, target = spec, name
		if type(spec) == "table" then
			argument_count, target = spec[1], spec[2]
		end
		public[name] = bind(client, assert(client[target]), argument_count)
	end
	return public
end
return M
