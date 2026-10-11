-- Supported instance operations bound to private implementation state.
local M = {}
local unpack_args = table.unpack or unpack
local function bind(client, method, argument_count)
	return function(_, ...)
		return method(client, unpack_args({ ... }, 1, argument_count))
	end
end
function M.new(client, methods)
	local public = {}
	for name, argument_count in pairs(methods) do
		public[name] = bind(client, assert(client[name]), argument_count)
	end
	return public
end
return M
