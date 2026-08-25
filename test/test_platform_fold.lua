package.path = "./?.lua;./?/init.lua;" .. package.path

-- CONFORMANCE AGAINST THE SHARED PLATFORM VOCABULARY.
--
-- One vocabulary is shared across the ShardPilot SDKs so that a given spelling
-- folds the same way everywhere. The expectations below are therefore NOT this
-- repository's opinion about the fold -- they are a generated copy of that
-- shared set, and the point of holding a copy is that it can disagree with
-- `shardpilot/envelope_platform.lua` and fail.
--
-- The copy is pinned by EXACT COMPARISON, in both directions and including the
-- entry count: an association changed in the module and nowhere else fails
-- here, which is the case this file exists for.

local VOCABULARY_REVISION = "1bd5acee111988d8"

-- Required: every SDK must produce these exactly.
local CORE = {
	{ "android", "android" },
	{ "browser", "web" },
	{ "darwin", "macos" },
	{ "html5", "web" },
	{ "ios", "ios" },
	{ "ipad", "ios" },
	{ "ipados", "ios" },
	{ "iphone", "ios" },
	{ "linux", "linux" },
	{ "mac", "macos" },
	{ "macos", "macos" },
	{ "macosx", "macos" },
	{ "osx", "macos" },
	{ "steamdeck", "linux" },
	{ "web", "web" },
	{ "win", "windows" },
	{ "win32", "windows" },
	{ "win64", "windows" },
	{ "windows", "windows" },
}

-- Required: the empty answer. An unmapped value is OMITTED from the
-- envelope, which the door accepts; sending it fails the whole batch.
local REJECTIONS = {
	"tvos",
	"steam",
	"other",
	"unknown",
	"ps5",
	"ps4",
	"xbox",
	"xsx",
	"switch",
	"nintendo",
	"freebsd",
	"openbsd",
	"netbsd",
	"solaris",
	"illumos",
	"js",
	"",
	"   ",
	"machine-42",
	"studios-pc",
	"Windows 11",
	"win-x64",
	"PC",
	"Win64_Shipping",
	"notaplatformx64",
	"editor",
	"client",
	"x64",
}

-- Deliberately not folded here -- see the header of
-- `shardpilot/envelope_platform.lua`. Asserted absent rather than left
-- untested, so "we chose not to" cannot decay into "it quietly started working"
-- without a test saying so.
local BUILD_SUFFIXES = {
	"noeditor",
	"client",
	"server",
	"editor",
	"aarch64",
	"arm64",
	"x64",
	"x86_64",
}

sys = {
	get_sys_info = function()
		return { system_name = "Linux" }
	end,
}

local envelope_platform = require "shardpilot.envelope_platform"
local client_mod = require "shardpilot.client"
local crash_client = require "shardpilot.crash.client"

local failures = 0
local function check(ok, message)
	if not ok then
		failures = failures + 1
		print("FAIL " .. message)
	end
end

-- 1. The module's table IS the shared set, in both directions -- and says which
-- revision of it, so a regenerated table cannot keep the old label.
do
	check(envelope_platform.VOCABULARY_REVISION == VOCABULARY_REVISION,
		string.format("the module declares revision %s and this copy is %s",
			tostring(envelope_platform.VOCABULARY_REVISION), VOCABULARY_REVISION))
	local n = 0
	for _, row in ipairs(CORE) do
		check(envelope_platform.VOCABULARY[row[1]] == row[2],
			string.format("vocabulary[%q] is %s, shared set says %q",
				row[1], tostring(envelope_platform.VOCABULARY[row[1]]), row[2]))
	end
	for key in pairs(envelope_platform.VOCABULARY) do
		n = n + 1
	end
	check(n == #CORE, string.format(
		"the module carries %d entries and the shared set %d -- an entry added here "
		.. "and nowhere else makes the SDKs disagree", n, #CORE))
end

-- 2. Every core vector folds to its shared answer.
for _, row in ipairs(CORE) do
	check(envelope_platform.normalize(row[1]) == row[2],
		string.format("normalize(%q) = %s, want %q", row[1],
			tostring(envelope_platform.normalize(row[1])), row[2]))
end

-- 3. Every rejection folds to nothing.
for _, value in ipairs(REJECTIONS) do
	check(envelope_platform.normalize(value) == nil,
		string.format("normalize(%q) = %s, want nil", value,
			tostring(envelope_platform.normalize(value))))
end

-- 4. Case and padding fold; the value is the host's typing, not a token.
for _, row in ipairs({ { "WINDOWS", "windows" }, { "  OSX  ", "macos" },
	{ "Html5", "web" }, { "\tweb\n", "web" } }) do
	check(envelope_platform.normalize(row[1]) == row[2],
		string.format("normalize(%q) = %s, want %q", row[1],
			tostring(envelope_platform.normalize(row[1])), row[2]))
end

-- 5. Suffixed spellings are absent, deliberately.
for _, suffix in ipairs(BUILD_SUFFIXES) do
	check(envelope_platform.normalize("windows" .. suffix) == nil,
		string.format("windows%s folded -- suffix stripping is not implemented here", suffix))
end

-- 6. A non-string is not a platform.
for _, value in ipairs({ 42, true, {} }) do
	check(envelope_platform.normalize(value) == nil, "a non-string folded")
end

local function base_config(overrides)
	local config = {
		ingest_url = "https://ingest.example.com",
		workspace_id = "ws_1",
		app_id = "app_1",
		environment_id = "develop",
		source = "client",
		app_version = "1.0.0",
		api_key = "sp_ingest_publishable_key",
	}
	for key, value in pairs(overrides or {}) do
		config[key] = value
	end
	return config
end

-- 7. THE DIAGNOSTIC, THROUGH THE REAL CONSTRUCTOR.
--
-- Not a restatement of the rule: the client is actually built and its resolved
-- config read. A fixture that re-implements the condition it is checking passes
-- whatever its subject does, and certifies only itself.
for _, case in ipairs({
	{ name = "set and unmapped is reported and omitted",
	  platform = "Win64_Shipping", want_platform = nil, want_report = true },
	{ name = "unset is detected and silent",
	  platform = nil, want_platform = "linux", want_report = false },
	{ name = "blank is unset, not a value",
	  platform = "", want_platform = "linux", want_report = false },
	{ name = "whitespace was typed, so it is reported",
	  platform = "   ", want_platform = nil, want_report = true },
	{ name = "set and mapped is folded and silent",
	  platform = "Windows", want_platform = "windows", want_report = false },
}) do
	local reports = {}
	local client = assert(client_mod.new(base_config({
		platform = case.platform,
		diagnostics = function(issue) reports[#reports + 1] = issue end,
	})))
	check(client.config.platform == case.want_platform, string.format(
		"%s: envelope platform is %s, want %s", case.name,
		tostring(client.config.platform), tostring(case.want_platform)))
	check((#reports > 0) == case.want_report, string.format(
		"%s: %d report(s), want_report=%s", case.name, #reports,
		tostring(case.want_report)))
	if case.want_report and #reports == 1 then
		check(reports[1].code == "platform_unmapped",
			case.name .. ": report code is " .. tostring(reports[1].code))
		check(reports[1].scope == "config",
			case.name .. ": report scope is " .. tostring(reports[1].scope))
	end
end

-- 8. THE CRASH PLATFORM IS NOT THIS FIELD.
--
-- The worst case for the exception: the host hands ONE table to both
-- constructors. A crash platform may be any lowercase token and rides the group
-- fingerprint, so a fold reaching it would refingerprint existing crash groups.
do
	local shared = base_config({
		platform = "Win64_Shipping",
		crash_ingest_url = "https://crash.example.com",
		crash_api_key = "sp_crash_write_key",
	})
	local analytics = assert(client_mod.new(shared))
	local crash = assert(crash_client.new(shared))
	check(shared.platform == "Win64_Shipping", "the fold mutated the caller's own table")
	check(crash.config.platform == "Win64_Shipping",
		"the fold reached the CRASH wire: crash platform is "
		.. tostring(crash.config.platform))
	check(analytics.config.platform == nil,
		"an unmapped value survived onto the envelope")
end

-- 9. THE OFFLINE BACKLOG IS FOLDED AT LOAD.
--
-- Envelopes spooled by an EARLIER launch carry that launch's platform and the
-- resend path sends them verbatim. Folding only the live config would leave the
-- very events that motivated the upgrade still failing -- and a batch is
-- rejected whole, so each stale envelope takes the fresh events batched beside
-- it down too.
do
	local stores = {}
	sys.get_save_file = function(application_id, file_name)
		return application_id .. "/" .. file_name
	end
	sys.save = function(path, record) stores[path] = record return true end
	sys.load = function(path) return stores[path] end

	local reports = {}
	local config = base_config({
		diagnostics = function(issue) reports[#reports + 1] = issue end,
	})
	-- The spool is only LOADED under a granted consent; without one it is
	-- purged, and a test that skipped this would prove nothing while passing.
	local storage = require "shardpilot.storage"
	local probe = assert(client_mod.new(config))
	local scope = probe.config
	local record = storage.load(scope) or {}
	record.consent_analytics = "granted"
	assert(storage.save(scope, record))

	-- Seed a spool the way an older launch would have left it: envelopes whose
	-- platform never went through a fold.
	local spool_path
	for path in pairs(stores) do
		if path:sub(-6) == "/spool" then spool_path = path end
	end
	check(spool_path ~= nil, "no spool path was created, so this case is inert")
	stores[spool_path] = {
		events = {
			{ event_id = "e1", event_ts = "2026-01-01T00:00:00Z", platform = "Windows" },
			{ event_id = "e2", event_ts = "2026-01-01T00:00:01Z", platform = "Win64_Shipping" },
			{ event_id = "e3", event_ts = "2026-01-01T00:00:02Z" },
			-- The shapes an UNVALIDATED `config.platform` could have left on an
			-- envelope before this version. The blank is not hypothetical: it is
			-- what `config.platform or ...` produced for `platform = ""`.
			{ event_id = "e4", event_ts = "2026-01-01T00:00:03Z", platform = "" },
			{ event_id = "e5", event_ts = "2026-01-01T00:00:04Z", platform = 42 },
			{ event_id = "e6", event_ts = "2026-01-01T00:00:05Z", platform = {} },
		},
	}

	reports = {}
	local client = assert(client_mod.new(config))
	local loaded = client.spool_record or {}
	local by_id = {}
	for i = 1, #loaded do by_id[loaded[i].event_id] = loaded[i] end

	if by_id.e1 then
		check(by_id.e1.platform == "windows", string.format(
			"a spooled `Windows` stayed %s -- the backlog was not folded",
			tostring(by_id.e1.platform)))
		check(by_id.e1.event_id == "e1" and by_id.e1.event_ts == "2026-01-01T00:00:00Z",
			"the fold disturbed the event identity the resend path depends on")
	else
		check(false, "the seeded spool was not loaded, so this case proved nothing")
	end
	if by_id.e2 then
		check(by_id.e2.platform == nil, string.format(
			"a spooled `Win64_Shipping` stayed %s -- it would fail the whole batch",
			tostring(by_id.e2.platform)))
	end
	for _, id in ipairs({ "e4", "e5", "e6" }) do
		if by_id[id] then
			check(by_id[id].platform == nil, string.format(
				"restored envelope %s kept platform %s (%s) -- it would fail the "
				.. "whole batch", id, tostring(by_id[id].platform),
				type(by_id[id].platform)))
		end
	end
	if by_id.e3 then
		check(by_id.e3.platform == nil,
			"an ABSENT platform key must stay absent, not gain a value")
	end

	local reported = 0
	for i = 1, #reports do
		if reports[i].scope == "spool" and reports[i].code == "platform_unmapped" then
			reported = reported + 1
			check(reports[i].count == 4, "the spool report carried count "
				.. tostring(reports[i].count) .. ", want 4")
		end
	end
	check(reported == 1, string.format(
		"the unfoldable spooled platform was reported %d time(s), want 1", reported))

	sys.get_save_file, sys.save, sys.load = nil, nil, nil
end

-- 10. A HOSTILE `__tostring` DOES NOT ESCAPE CONSTRUCTION.
--
-- The diagnostics field coercion takes scalars only, so a table platform never
-- reaches `tostring` and its metamethod never runs.
do
	local hostile = setmetatable({}, { __tostring = function()
		error("a platform value must never be able to break new()")
	end })
	local reports = {}
	local ok, client = pcall(client_mod.new, base_config({
		platform = hostile,
		diagnostics = function(issue) reports[#reports + 1] = issue end,
	}))
	check(ok, "new() threw on a platform whose __tostring raises: " .. tostring(client))
	if ok and client then
		check(client.config.platform == nil, "a table survived onto the envelope")
	end
end

if failures > 0 then
	print(string.format("shardpilot defold platform-fold tests: %d failure(s)", failures))
	os.exit(1)
end
print(string.format(
	"shardpilot defold platform-fold tests passed (%d core, %d rejections, "
	.. "vocabulary %s)", #CORE, #REJECTIONS, VOCABULARY_REVISION))
