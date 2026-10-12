local M = {}

local map = {
	android = "android",
	ios = "ios",
	iphone = "ios",
	ipad = "ios",
	["iphone os"] = "ios",
	windows = "windows",
	win32 = "windows",
	macos = "macos",
	mac = "macos",
	darwin = "macos",
	osx = "macos",
	linux = "linux",
	html5 = "web",
}

-- The runtime's platform, one of the twelve the services accept. The table maps
-- the engine's documented system names; a runtime it does not know, or no sys
-- info at all, is "other", never nil or empty.
function M.detect()
	if not sys or not sys.get_sys_info then
		return "other"
	end
	local ok, info = pcall(sys.get_sys_info)
	if not ok or type(info) ~= "table" then
		return "other"
	end
	local name = tostring(info.system_name or info.system or ""):lower()
	return map[name] or "other"
end

return M
