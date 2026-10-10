package.path = "./?.lua;" .. package.path

local group = arg and arg[1]
assert(not group or group=="reference" or group=="seeds" or group=="browser" or group=="global", "unknown test group")

local records = {}
sys = {
	get_save_file = function(ns, name) return ns .. "/" .. name end,
	load = function(name) return records[name] or {} end,
	save = function(name, record) records[name] = record; return true end,
}
socket = { gettime = function() return 1700000000.125 end }

local id = require "shardpilot.id"
local storage = require "shardpilot.storage"
local Client = require("shardpilot.client").Client
local Experiments = require("shardpilot.experiments").Experiments
local client = setmetatable({publish_backoff_attempt=2, consent_backoff_attempt=2}, {__index=Client})
local experiments = setmetatable({backoff_attempt=2}, {__index=Experiments})
local scope = { app_id="random-tests" }
local seen = {}
local function unique(value)
	assert(type(value)=="string" and #value>0, "mint must be reached")
	assert(not seen[value], "identifiers must differ in this sample")
	seen[value] = true
end

-- Isolated Lua environments model separate launches with the same wall time.
-- No production seeding/reset API is exposed to obtain these deterministic inputs.
local function load_in(file, env)
	local chunk
	if setfenv then
		chunk = assert(loadfile(file))
		setfenv(chunk, env)
	else
		chunk = assert(loadfile(file, "t", env))
	end
	return chunk()
end
local function launch(address, cpu, browser, force_plain)
	local reads = {wall=0, cpu=0, seconds=0, address=0, browser=0}
	local env = setmetatable({
		socket = {gettime=function() reads.wall=reads.wall+1; return 1700000000.125 end},
		os = {
			clock=function() reads.cpu=reads.cpu+1; return cpu or 0.03125 end,
			time=function() reads.seconds=reads.seconds+1; return 1700000000 end,
		},
		tostring = function(value)
			if type(value)=="table" then reads.address=reads.address+1; return address or "table: 0x1000" end
			return tostring(value)
		end,
		bit = not force_plain and bit or false,
		html5 = browser and {run=function(code)
			reads.browser=reads.browser+1
			return browser(code)
		end} or false,
		require = function(name)
			if force_plain then error("plain interpreter") end
			return require(name)
		end,
	}, {__index=_G})
	local rng = load_in("shardpilot/random.lua", env)
	env.require = function(name)
		if name=="shardpilot.random" then return rng end
		if name=="shardpilot.clock" then return {unix_ms=function() return 1700000000125 end} end
		error("unexpected dependency " .. name)
	end
	return rng, load_in("shardpilot/id.lua", env), reads
end

if not group or group=="reference" then
	-- Reference words from the published C xoshiro128** 1.1 transition with
	-- seed material "1700000000.125|0.03125|1700000000|table: 0x1000" and 32 warmups.
	local reference = {1216842336,242178701,3849093193,1787715055,2318200157,436571773,722376422,1121825881}
	for _, plain in ipairs({false,true}) do
		local rng = launch(nil,nil,nil,plain)
		for i, word in ipairs(reference) do
			assert(rng.unit()*4294967296==word, "reference word " .. i .. " differs")
		end
	end
	print("PASS xoshiro reference words with available BitOp and plain arithmetic")
end

if not group or group=="seeds" then
	local _, first, reads = launch()
	local _, changed_address = launch("table: 0x2000")
	local _, changed_cpu = launch(nil, 0.0625)
	local _, repeated = launch()
	local seen_launches = {}
	for i=1,128 do
		local original = first.uuid_v7()
		assert(original==repeated.uuid_v7(), "controlled identical sources must reproduce the reference stream")
		for _, value in ipairs({original,changed_address.uuid_v7(),changed_cpu.uuid_v7()}) do
			assert(value:sub(1,13)==original:sub(1,13), "simulated launches must share the same millisecond")
			assert(value:sub(15,15)=="7" and value:sub(20,20):match("[89ab]"), "UUID version/variant")
			assert(not seen_launches[value], "same-time launch sources failed to separate IDs")
			seen_launches[value]=true
		end
	end
	assert(reads.wall==1 and reads.cpu==1 and reads.seconds==1 and reads.address==1, "seed sources must be read once")
	print("PASS 384 distinct IDs across same-millisecond launches; address and CPU sources each discriminate")
end

local function first_hex(browser)
	local rng, _, counts = launch(nil,nil,browser)
	local value = rng.hex(32)
	rng.hex(32)
	assert(counts.browser==(browser and 1 or 0), "browser seed must be read once")
	return value
end
if not group or group=="browser" then
	local ordinary = first_hex()
	assert(first_hex(function() return "" end)==ordinary, "unavailable Web Crypto uses process sources")
	assert(first_hex(function() error("unavailable") end)==ordinary, "HTML5 errors use process sources")
	assert(first_hex(function() return string.rep("z",64) end)==ordinary, "malformed browser seed must be ignored")
	local web_a = first_hex(function() return string.rep("a",64) end)
	local web_b = first_hex(function() return string.rep("b",64) end)
	assert(web_a~=ordinary and web_a~=web_b and web_b~=ordinary, "browser entropy must influence the stream")
	print("PASS optional browser entropy, refusal fallback and seed-once behavior")
end
local cases = {
	{"uuid", function() unique(id.uuid()) end},
	{"uuid_v7", function() unique(id.uuid_v7()) end},
	{"pending_crash", function()
		local token = storage.save_pending_crash(scope, {body="{}",fatal=true})
		unique(token)
		storage.remove_pending_crash(scope, token)
	end},
	{"publish_jitter", function()
		client:defer_backoff()
		assert(client.publish_retry_after_ms > 1700000000125, "publish jitter reached")
	end},
	{"consent_jitter", function()
		client:defer_consent_backoff()
		assert(client.consent_retry_after_ms > 1700000000125, "consent jitter reached")
	end},
	{"revalidation_jitter", function()
		experiments:arm_revalidation(1700000000125)
		assert(experiments.revalidate_at_ms > 1700000000125, "revalidation jitter reached")
	end},
	{"retry_jitter", function()
		experiments:pace_transient()
		assert(experiments.retry_after_ms > 1700000000125, "retry jitter reached")
	end},
}
local function game_sequence()
	local values = {}
	for i=1,32 do values[i] = string.format("%.17g", math.random()) end
	return table.concat(values, ",")
end
if not group or group=="global" then
	for _, case in ipairs(cases) do
		math.randomseed(412032)
		local expected = game_sequence()
		math.randomseed(412032)
		for i=1,128 do case[2]() end
		assert(game_sequence()==expected, case[1] .. " changed the game's RNG sequence")
		print("PASS " .. case[1] .. ": 128 operations preserve 32 game draws")
	end
end
