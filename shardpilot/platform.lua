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
}

function M.detect()
	if not sys or not sys.get_sys_info then
		return nil
	end
	local ok, info = pcall(sys.get_sys_info)
	if not ok or type(info) ~= "table" then
		return nil
	end
	local name = tostring(info.system_name or info.system or ""):lower()
	return map[name]
end

return M
