-- Normalize configured analytics platform values. Canonical values are checked
-- against the publisher capture; existing aliases remain compatibility inputs.
-- Human-supplied build suffixes are deliberately not inferred here.
-- Crash configuration uses its own platform path.
local M = {}

M.VOCABULARY_REVISION = "cf85d6f986723ff1"

M.VOCABULARY = {
	["tvos"]      = "tvos",
	["ps4"]       = "ps4",
	["ps5"]       = "ps5",
	["xbox"]      = "xbox",
	["switch"]    = "switch",
	["other"]     = "other",
	["android"]   = "android",
	["browser"]   = "web",
	["darwin"]    = "macos",
	["html5"]     = "web",
	["ios"]       = "ios",
	["ipad"]      = "ios",
	["ipados"]    = "ios",
	["iphone"]    = "ios",
	["linux"]     = "linux",
	["mac"]       = "macos",
	["macos"]     = "macos",
	["macosx"]    = "macos",
	["osx"]       = "macos",
	["steamdeck"] = "linux",
	["web"]       = "web",
	["win"]       = "windows",
	["win32"]     = "windows",
	["win64"]     = "windows",
	["windows"]   = "windows",
}

-- Return nil for unrecognized input so callers retain diagnostic information.
-- Analytics emission chooses the explicit fallback at the client boundary.
function M.normalize(value)
	if type(value) ~= "string" then
		return nil
	end
	local folded = value:lower():match("^%s*(.-)%s*$")
	return M.VOCABULARY[folded]
end

return M
