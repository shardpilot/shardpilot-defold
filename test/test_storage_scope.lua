package.path = "./?.lua;./?/init.lua;" .. package.path
local sdk = require "shardpilot.sdk"
local passed, failed = 0, 0
local io_calls, records, now = 0, {}, 1000
local function equal(a, b, why) assert(a == b, why .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end
local function config(app, workspace)
	return { ingest_url = "https://events.example.com", workspace_key = workspace or "scope-workspace",
		app_key = app or "scope-app", environment_key = "develop", publishable_key = "sp_ingest_public_example" }
end
local function close(client)
	local answer
	assert(client:shutdown(1, function(ok) answer = ok end))
	equal(answer, true, "empty close completes")
end
local function scene(name, run)
	collectgarbage("collect"); collectgarbage("collect")
	collectgarbage("stop") -- explicit release must not rely on a lucky collection
	io_calls, records = 0, {}
	socket = { gettime = function() return now end }
	sys = { get_sys_info = function() return { system_name = "Linux" } end,
		get_save_file = function(app, file) io_calls = io_calls + 1; return app .. "/" .. file end,
		save = function(path, record) io_calls = io_calls + 1; records[path] = record; return true end,
		load = function(path) io_calls = io_calls + 1; return records[path] end }
	json = { encode = function() return "{}" end, decode = function() return { accepted = 1 } end }
	http = nil
	local ok, err = pcall(run)
	collectgarbage("restart")
	sdk.shutdown(1)
	if ok then passed = passed + 1 else failed = failed + 1 end
	print("storage scope " .. name .. ": " .. (ok and "PASS" or "FAIL " .. tostring(err)))
end

scene("new and init refuse duplicate owners before storage", function()
	local first = assert(sdk.new(config()))
	assert(io_calls > 0, "the first constructor exercises the storage counter")
	local before = io_calls
	local second, err = sdk.new(config())
	equal(second, nil, "duplicate new refused"); equal(err, "storage_scope_in_use", "new error")
	equal(io_calls, before, "refused new performs no persistence calls")
	require("shardpilot.storage").reset()
	local ok; ok, err = sdk.init(config())
	equal(ok, false, "duplicate init refused"); equal(err, "storage_scope_in_use", "init error")
	equal(io_calls, before, "refused init performs no persistence calls")
	close(first)
	assert(sdk.init(config()), "init succeeds after the instance closes")
	second, err = sdk.new(config())
	equal(second, nil, "new also respects the singleton's ownership")
	equal(err, "storage_scope_in_use", "singleton conflict error")
	assert(sdk.shutdown(1))
	close(assert(sdk.new(config())))
end)

scene("app scope ignores environment but keeps raw keys distinct", function()
	local first = assert(sdk.new(config("com.game")))
	local other_environment = config("com.game"); other_environment.environment_key = "production"
	local second, err = sdk.new(other_environment)
	equal(second, nil, "same app's other environment shares storage")
	equal(err, "storage_scope_in_use", "environment conflict error")
	for _, keys in ipairs({ { "com_game" }, { "Com.game" }, { "com.game", "another-workspace" } }) do
		close(assert(sdk.new(config(keys[1], keys[2]))))
	end
	assert(sdk.init(config("singleton-app"))); assert(sdk.shutdown(1))
	close(first)
end)

scene("analytics and crash clients coexist", function()
	local analytics = assert(sdk.new(config()))
	local crash = assert(require("shardpilot.crash").new({ crash_url = "https://crash.example.com",
		crash_key = "sp_crash_public_example", app_key = "scope-app", previous_crash_capture_enabled = false }))
	assert(crash:shutdown())
	local second, err = sdk.new(config())
	equal(second, nil, "crash close cannot release analytics ownership")
	equal(err, "storage_scope_in_use", "analytics still owns its scope")
	close(analytics)
end)

scene("failed construction releases its reservation", function()
	local load = sys.load
	sys.load = function(...)
		socket.gettime = function() error("synthetic construction failure") end
		return load(...)
	end
	local ok = pcall(sdk.new, config())
	equal(ok, false, "failure occurs after storage was entered")
	assert(io_calls > 0)
	sys.load = load; socket.gettime = function() return now end
	close(assert(sdk.new(config()), "failed construction must not retain ownership"))
end)

scene("construction reserves before reentrant storage hooks", function()
	local load, entered = sys.load, false
	local nested, nested_err, before, after
	sys.load = function(...)
		if not entered then
			entered = true; before = io_calls
			nested, nested_err = sdk.new(config()); after = io_calls
		end
		return load(...)
	end
	local first = assert(sdk.new(config()))
	equal(nested, nil, "reentrant duplicate refused")
	equal(nested_err, "storage_scope_in_use", "reentrant error")
	equal(after, before, "reentrant duplicate never enters storage")
	close(first)
end)

scene("garbage collection releases an unreachable client", function()
	collectgarbage("restart")
	do local client = assert(sdk.new(config())); assert(client) end
	collectgarbage("collect"); collectgarbage("collect")
	close(assert(sdk.new(config()), "unreachable owner must not reserve the scope"))
end)

scene("closing retains ownership until its callback", function()
	local held
	http = { request = function(url, _, callback)
		if url:find("/v1/consent", 1, true) then callback(nil, nil, { status = 202, response = "{}" })
		else held = callback end
	end }
	local first = assert(sdk.new(config()))
	assert(first:set_consent(true)); assert(first:track("scope_close"))
	local answer
	assert(first:shutdown(1, function(ok) answer = ok end))
	equal(answer, nil, "the close is still draining")
	local second, err = sdk.new(config())
	equal(second, nil, "closing owner still holds the scope")
	equal(err, "storage_scope_in_use", "closing conflict error")
	assert(held); held(nil, nil, { status = 202, response = "{}" }); first:update(0)
	equal(answer, true, "close finishes after delivery")
	close(assert(sdk.new(config())))
end)

local function android_paths()
	local storage, names = require("shardpilot.storage"), {}
	storage.reset()
	-- Android selects the app sandbox independently of application_id.
	sys.get_save_file = function(_, file)
		names[#names + 1] = file
		return "android/" .. file
	end
	return storage, names
end

scene("Android identity survives crash settings and relaunch", function()
	local storage = android_paths()
	local scope = { workspace_id = "workspace-a", app_id = "app-a" }
	assert(storage.save(scope, { anonymous_id = "install-a" }))
	assert(storage.save_crash_settings({ app_id = scope.app_id }, { crash_enabled = false }))
	equal(storage.load(scope).anonymous_id, "install-a", "crash settings preserve identity")
	storage.reset()
	equal(storage.load(scope).anonymous_id, "install-a", "relaunch retains identity")
	equal(storage.load_crash_settings({ app_id = scope.app_id }).crash_enabled, false, "crash decision retained")
end)

scene("Android identity survives pending crash writes", function()
	local storage = android_paths()
	local scope = { workspace_id = "workspace-a", app_id = "app-a" }
	assert(storage.save(scope, { anonymous_id = "install-a" }))
	assert(storage.save_pending_crash({ app_id = scope.app_id },
		{ body = "{}", crash_id = "crash-a", fatal = true }, now * 1000))
	equal(storage.load(scope).anonymous_id, "install-a", "pending crash preserves identity")
	storage.reset()
	equal(storage.load(scope).anonymous_id, "install-a", "relaunch retains identity")
	equal(#storage.load_pending_crashes({ app_id = scope.app_id }), 1, "pending report retained")
end)

scene("Android separates raw scopes with bounded filenames", function()
	local storage, names = android_paths()
	local first = { workspace_id = string.rep("workspace", 100), app_id = "app.a" }
	local second = { workspace_id = first.workspace_id, app_id = "app_a" }
	assert(storage.save(first, { anonymous_id = "install-a" }))
	assert(storage.save(second, { anonymous_id = "install-b" }))
	storage.reset()
	equal(storage.load(first).anonymous_id, "install-a", "first scope retains its identity")
	equal(storage.load(second).anonymous_id, "install-b", "second scope retains its identity")
	assert(#names > 0, "the filename probe must run")
	for _, name in ipairs(names) do
		assert(#name <= 255 and not name:find("/", 1, true) and not name:find("\\", 1, true),
			"each filename must fit one filesystem component")
	end
end)

print(string.format("storage scope: %d pass, %d fail", passed, failed))
equal(failed, 0, "storage ownership scenes")
