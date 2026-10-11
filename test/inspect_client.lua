-- Core regression fixtures inspect private state without exporting a test API.
local M = {}
local function upvalue(fn, wanted)
	for index = 1, math.huge do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == wanted then return value end
	end
	error("missing test inspection upvalue: " .. wanted)
end
function M.state(public)
	if rawget(public, "config") then return public end
	return upvalue(public.snapshot, "client")
end
function M.class(constructor, name) return upvalue(constructor, name or "Client") end
function M.wrap(module)
	return setmetatable({ new = function(...)
		local public, err = module.new(...)
		if not public then return public, err end
		return M.state(public), err
	end }, { __index = module })
end
return M
