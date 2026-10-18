-- Core regression fixtures inspect private state without exporting a test API.
local M = {}
local clients = setmetatable({}, { __mode = "k" })
function M.finish_all()
	for client in pairs(clients) do client:finish_teardown(); clients[client] = nil end
end
-- A fixture reset models process death, not two simultaneously live clients.
function M.storage()
	local storage = require "shardpilot.storage"
	return setmetatable({ reset = function()
		M.finish_all()
		storage.reset()
	end }, { __index = storage, __newindex = storage })
end
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
function M.class(constructor, name)
	local wanted = name or "Client"
	local ok, value = pcall(upvalue, constructor, wanted)
	if ok then return value end
	return upvalue(upvalue(constructor, "construct"), wanted)
end
function M.track(value, module)
	local client
	if type(value) == "table" then client = M.state(value)
	elseif value == true and module then
		local ok, current = pcall(upvalue, module.init, "default_client")
		if ok then client = current end
	end
	if client and type(client.finish_teardown) == "function" then clients[client] = true end
	return value
end
function M.wrap(module, keep_facade)
	keep_facade = keep_facade == true -- Lua 5.4 require also returns loader data.
	return setmetatable({
		-- End a simulated launch without publishing or clearing its persisted data.
		restart = function(previous, ...)
			M.state(previous):finish_teardown()
			return M.wrap(module, keep_facade).new(...)
		end, init = function(...)
		collectgarbage("collect"); collectgarbage("collect")
		local ok, err = module.init(...)
		M.track(ok, module)
		return ok, err
	end, new = function(...)
		collectgarbage("collect"); collectgarbage("collect")
		local public, err = module.new(...)
		if not public then return public, err end
		M.track(public)
		local client = M.state(public)
		return keep_facade and public or client, err
	end }, { __index = module })
end
return M
