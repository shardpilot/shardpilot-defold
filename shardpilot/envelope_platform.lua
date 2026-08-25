-- Fold a HOST-SUPPLIED platform onto the analytics envelope's closed vocabulary.
--
-- The ingest door accepts six values and one out-of-vocabulary value fails the
-- WHOLE batch, every event in it. `config.platform` is typed by a human, so
-- `Windows 11`, `win-x64` and `PC` all reach that door as written unless they
-- are folded first.
--
-- THIS TABLE IS NOT THIS SDK'S OPINION. It is one shared vocabulary, measured
-- from the ShardPilot SDKs that already fold (the Unreal and Godot ones) so
-- that every SDK answers a given spelling identically; `VOCABULARY_REVISION`
-- identifies the revision it was taken from, and
-- `test/test_platform_fold.lua` holds this table to a copy of it, so an entry
-- edited here and nowhere else fails rather than diverging quietly.
--
-- SUFFIXED SPELLINGS ARE DELIBERATELY NOT FOLDED. The Unreal SDK also strips
-- build suffixes (`noeditor`, `x64`, `arm64`, ...); it can, because the engine
-- PRODUCES those names from a closed set. Here a human types the value, so the
-- input is open and a handful of suffixes does not approach completeness
-- against it -- it manufactures the APPEARANCE of completeness, after which the
-- next uncovered spelling reads as a gap in the rule rather than as a property
-- of an open input. This is a decision, not an omission.
--
-- THE CRASH PLATFORM IS A DIFFERENT FIELD AND IS NOT TOUCHED. `crash/client.lua`
-- resolves its own; a crash platform may be any lowercase token and takes part
-- in crash-group fingerprinting, so folding it would refingerprint existing
-- groups.
local M = {}

M.VOCABULARY_REVISION = "1bd5acee111988d8"

M.VOCABULARY = {
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

-- Returns the canonical value, or nil when the input is not one this vocabulary
-- knows. nil means the key is OMITTED from the envelope -- `platform` is
-- optional at the door, so an omitted key is accepted while a wrong one is not.
function M.normalize(value)
	if type(value) ~= "string" then
		return nil
	end
	local folded = value:lower():match("^%s*(.-)%s*$")
	return M.VOCABULARY[folded]
end

return M
