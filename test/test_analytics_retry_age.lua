package.path = "./?.lua;./?/init.lua;" .. package.path

local now, disk, requests, response_status = 1700000000000, {}, {}, 202
local save_hook, encode_hook, request_hook, pending_response, issues
local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in pairs(value) do out[k] = copy(v) end
	return out
end
local function encode(value)
	if encode_hook then local hook = encode_hook; encode_hook = nil; hook() end
	if type(value) == "string" then
		return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t") .. '"'
	end
	if type(value) ~= "table" then return tostring(value) end
	local keys, out = {}, {}
	for k in pairs(value) do keys[#keys + 1] = k end
	table.sort(keys)
	local array = type(keys[1]) == "number"
	for _, k in ipairs(keys) do out[#out + 1] = (array and "" or encode(k) .. ":") .. encode(value[k]) end
	return (array and "[" or "{") .. table.concat(out, ",") .. (array and "]" or "}")
end
socket = { gettime = function() return now / 1000 end }
sys = {
	get_sys_info = function() return { system_name = "Linux" } end,
	get_save_file = function(ns, name) return ns .. "/" .. name end,
	save = function(path, record)
		if save_hook and save_hook(path, record) == false then return false end
		disk[path] = copy(record); return true
	end,
	load = function(path) return copy(disk[path] or {}) end,
}
json = {
	encode = encode,
	decode = function(text)
		if text == '{"accepted":1}' then return { accepted = 1 } end
		return {}
	end,
}
http = { request = function(url, method, callback, headers, body)
	if url:find("/v1/events:batch", 1, true) then
		requests[#requests + 1] = body
		if request_hook then request_hook(body) end
		local complete = function() callback(nil, nil, { status = response_status, response = '{"accepted":1}' }) end
		if pending_response then pending_response = complete else complete() end
	else callback(nil, nil, { status = 202, response = "{}" }) end
end }
local clients = require "shardpilot.client"
local storage = require "shardpilot.storage"
local function eq(actual, expected, message)
	assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local config = {
	api_key = "sp_test_retry_age", ingest_url = "https://ingest.example.invalid",
	workspace_id = "workspace-test", app_id = "app-test", environment_id = "test",
	source = "backend", batch_size = 25, flush_interval_seconds = 3600,
	diagnostics = function(issue) issues[#issues + 1] = issue end,
}
local function fresh()
	now, disk, requests, response_status = 1700000000000, {}, {}, 202
	save_hook, encode_hook, request_hook, pending_response, issues = nil, nil, nil, nil, {}
	storage.reset()
	local client = assert(clients.new(config))
	assert(client:set_consent(true))
	return client
end
local function restart()
	storage.reset()
	return assert(clients.new(config))
end
local function restart_case(minutes, attempt, eligible)
	local client = fresh()
	assert(client:track("retry_subject", { nested = { text = "tab\tline\n" }, number = 9007199254740991 }))
	local event = client.queue.items[1]
	assert(event and event.event_id, "the accepted event has its original ID")
	local original_id = event.event_id
	-- A host timestamp is not the intake clock.
	event.event_ts = "2099-01-01T00:00:00Z"
	if attempt then
		response_status = 0
		client:flush()
		eq(#requests, 1, "the ambiguous attempt reached transport")
	end
	assert(client:persist())
	local saved = storage.load_spool(client.config)
	eq(#saved, 1, "the subject is durable before the simulated restart")
	local original = encode(saved[1])
	now = now + minutes * 60000
	requests, response_status = {}, 202
	local loaded = restart()
	assert(loaded:track("fresh_control"))
	loaded:flush()
	local wire = table.concat(requests, "\n")
	assert(wire:find("fresh_control", 1, true), "the fresh batchmate is delivered")
	eq(wire:find(original_id, 1, true) ~= nil, eligible, "replay follows local delivery age")
	if eligible then assert(wire:find(original, 1, true), "eligible replay keeps exact envelope bytes") end
	if not eligible then
		eq(loaded.stats.spool_expired, 1, "expiry counts the original member once")
		local found = 0
		for _, issue in ipairs(issues) do
			if issue.code == "spool_expired" and issue.event_id == original_id then found = found + 1 end
		end
		eq(found, 1, "expiry diagnostic retains the original event ID")
	end
end
local function spool_record()
	for name, record in pairs(disk) do if name:sub(-6) == "/spool" then return record end end
	error("missing spool record")
end
local function durable_subject()
	local client = fresh()
	assert(client:track("retry_subject")); assert(client:persist())
	return client, client.queue.items[1].event_id
end
local function survives_restart(id, minutes, expected)
	now = now + minutes * 60000
	requests, response_status = {}, 202
	local client = restart()
	assert(client:track("fresh_control")); client:flush()
	local wire = table.concat(requests, "\n")
	assert(wire:find("fresh_control", 1, true), "fresh control reached HTTP")
	eq(wire:find(id, 1, true) ~= nil, expected, "subject replay after restart")
	return client
end
local function known_refusal(earlier_attempt)
	local client, id = durable_subject()
	if earlier_attempt then response_status = 0; client:flush(); now = now + 60000 end
	response_status = 429; client:flush()
	assert(client:track("later_writer")); assert(client:persist())
	local age = spool_record().delivery_age[id]
	eq(age.ambiguous_ms == 0, not earlier_attempt, "4xx rolls back only the new clock")
	survives_restart(id, earlier_attempt and 16 or 120, not earlier_attempt)
end
local function delayed_write(minutes, expected)
	local client, id = durable_subject()
	local delayed = false
	save_hook = function(name, record)
		if name:sub(-6) == "/spool" and record.delivery_age[id]
			and record.delivery_age[id].ambiguous_ms > 0 and not delayed then
			delayed = true; now = now + minutes * 60000
		end
	end
	response_status = 0
	client:flush()
	eq(#requests > 0, expected, "post-write expiry controls actual HTTP")
	assert(delayed, "the clock write delay was reached")
	if expected then eq(spool_record().delivery_age[id].ambiguous_ms, now, "unsent provisional clock restamped") end
end
local function malformed_clock(field, value)
	local _, id = durable_subject()
	spool_record().delivery_age[id][field] = value
	survives_restart(id, 0, false)
end
local cases = {
	{ "ambiguous_sixteen_minutes", function() restart_case(16, true, false) end },
	{ "ambiguous_fourteen_minutes", function() restart_case(14, true, true) end },
	{ "offline_two_hours", function() restart_case(120, false, true) end },
	{ "intake_eight_days", function() restart_case(8 * 24 * 60, false, false) end },
	{ "intake_seven_days_boundary", function() restart_case(7 * 24 * 60, false, false) end },
	{ "ambiguous_fifteen_minutes_boundary", function() restart_case(15, true, false) end },
	{ "received_429_rolls_back_new_clock", function() known_refusal(false) end },
	{ "received_429_keeps_earlier_clock", function() known_refusal(true) end },
	{ "legacy_metadata_absent", function()
		local _, id = durable_subject(); spool_record().delivery_age = nil; survives_restart(id, 0, false)
	end },
	{ "future_intake", function() malformed_clock("intake_ms", 1800000000000) end },
	{ "future_ambiguity", function() malformed_clock("ambiguous_ms", 1800000000000) end },
	{ "malformed_intake", function() malformed_clock("intake_ms", "yesterday") end },
	{ "negative_ambiguity", function() malformed_clock("ambiguous_ms", -1) end },
	{ "live_queue_age_and_fresh_sibling", function()
		local client = fresh(); assert(client:track("old_member"))
		now = now + 8 * 86400000; assert(client:track("fresh_member")); client:flush()
		eq(#requests, 1, "one filtered batch sent")
		assert(not requests[1]:find("old_member", 1, true)); assert(requests[1]:find("fresh_member", 1, true))
		eq(client.stats.spool_expired, 1, "one expired member")
	end },
	{ "failed_fence_sends_nothing_and_evicts_nothing", function()
		local client, id = durable_subject()
		save_hook = function(name) if name:sub(-6) == "/spool" then return false end end
		client:flush(); eq(#requests, 0, "failed fence never reaches HTTP")
		eq(#spool_record().events, 1, "failure does not evict durable member")
		eq(spool_record().delivery_age[id].ambiguous_ms, 0, "old disk clock survives failed fence")
		save_hook = nil; assert(client:persist()); survives_restart(id, 120, true)
	end },
	{ "clock_durable_before_http_completion", function()
		local client, id = durable_subject(); pending_response = true
		request_hook = function()
			eq(spool_record().delivery_age[id].ambiguous_ms, now, "clock was saved before HTTP")
		end
		client:flush(); eq(type(pending_response), "function", "response remains outstanding")
		pending_response, request_hook = nil, nil
		survives_restart(id, 16, false)
	end },
	{ "slow_write_restamps_unsent_clock", function() delayed_write(16, true) end },
	{ "slow_write_expires_intake", function() delayed_write(8 * 24 * 60, false) end },
	{ "rollback_failure_repaired_by_persist", function()
		local client, id = durable_subject()
		local attempted = false
		request_hook = function() attempted = true end
		save_hook = function(name, record)
			if attempted and name:sub(-6) == "/spool" and record.delivery_age[id]
				and record.delivery_age[id].ambiguous_ms == 0 then return false end
		end
		response_status = 429; client:flush()
		assert(spool_record().delivery_age[id].ambiguous_ms > 0, "rollback failure leaves old disk evidence")
		save_hook, request_hook = nil, nil
		assert(client:track("later_member")); assert(client:persist())
		eq(spool_record().delivery_age[id].ambiguous_ms, 0, "later writer carries the rollback")
		survives_restart(id, 120, true)
	end },
	{ "serialization_consent_change_refuses_http", function()
		local client = fresh(); assert(client:track("revoked_member"))
		encode_hook = function() assert(client:set_consent(false)); assert(client:set_consent(true)) end
		client:flush(); eq(#requests, 0, "revoked batch never reaches HTTP")
		assert(client:track("fresh_member")); client:flush()
		eq(#requests, 1, "new consent epoch can send fresh work")
		assert(not requests[1]:find("revoked_member", 1, true))
	end },
	{ "write_consent_change_refuses_http", function()
		local client, id = durable_subject()
		local reentered = false
		save_hook = function(name, record)
			if name:sub(-6) == "/spool" and record.delivery_age[id]
				and record.delivery_age[id].ambiguous_ms > 0 and not reentered then
				reentered = true; assert(client:set_consent(false)); assert(client:set_consent(true))
			end
		end
		client:flush(); assert(reentered); eq(#requests, 0, "revoked prepared batch never reaches HTTP")
	end },

	{ "ambiguity_before_intake", function() malformed_clock("ambiguous_ms", 1699999999999) end },
	{ "missing_ambiguity", function() malformed_clock("ambiguous_ms", nil) end },
	{ "boolean_ambiguity", function() malformed_clock("ambiguous_ms", false) end },
	{ "fractional_intake", function() malformed_clock("intake_ms", 1700000000000.5) end },
	{ "serialization_expiry_reencodes_survivor", function()
		local client = fresh(); assert(client:track("expired_serialized_member"))
		now = now + 6 * 86400000 + 23 * 3600000
		assert(client:track("surviving_serialized_member", { text = "exact\tbytes" }))
		encode_hook = function() now = now + 2 * 3600000 end
		client:flush(); eq(#requests, 1, "one rebuilt request reaches HTTP")
		assert(not requests[1]:find("expired_serialized_member", 1, true), "old encoded body was replaced")
		assert(requests[1]:find("surviving_serialized_member", 1, true), "eligible member survives rebuild")
		eq(client.stats.spool_expired, 1, "filtered member counted once")
	end },
	{ "http_unavailable_keeps_offline_budget", function()
		local client, id = durable_subject(); local saved = http; http = nil
		client:flush(); http = saved
		eq(#requests, 0, "unavailable HTTP never hands off")
		survives_restart(id, 120, true)
	end },
	{ "server_failure_keeps_ambiguity", function()
		local client, id = durable_subject(); response_status = 503; client:flush()
		eq(#requests, 1, "503 came from actual HTTP"); survives_restart(id, 16, false)
	end },
	{ "later_ambiguous_retry_keeps_first_clock", function()
		local client, id = durable_subject(); response_status = 0; client:flush()
		local first = spool_record().delivery_age[id].ambiguous_ms
		now = now + 10 * 60000; client:flush(); eq(#requests, 2, "eligible retry reaches HTTP")
		eq(spool_record().delivery_age[id].ambiguous_ms, first, "retry preserves first ambiguity")
		survives_restart(id, 6, false)
	end },
	{ "durable_clock_needs_no_rewrite_for_retry", function()
		local client, id = durable_subject(); response_status = 0; client:flush()
		local first = spool_record().delivery_age[id].ambiguous_ms
		save_hook = function(name) if name:sub(-6) == "/spool" then return false end end
		now = now + 60000; client:flush(); eq(#requests, 2, "already durable clock permits retry")
		eq(spool_record().delivery_age[id].ambiguous_ms, first, "disk still holds first ambiguity")
	end },
	{ "owed_clock_correction_blocks_failed_next_fence", function()
		local client, id = durable_subject(); response_status = 429
		request_hook = function()
			save_hook = function(name) if name:sub(-6) == "/spool" then return false end end
		end
		client:flush(); eq(#requests, 1, "first request was rejected")
		assert(spool_record().delivery_age[id].ambiguous_ms > 0, "correction is still owed on disk")
		request_hook = nil; response_status = 0; now = now + 60000
		client:flush(); eq(#requests, 1, "failed clock fence blocks next handoff")
		save_hook = nil; assert(client:persist()); survives_restart(id, 120, true)
	end },

}
local ran = 0
for _, case in ipairs(cases) do
	if not arg[1] or arg[1] == case[1] then case[2](); ran = ran + 1; print("PASS " .. case[1]) end
end
assert(ran > 0, "no retry-age case selected")
print("PASS " .. ran .. " analytics retry-age cases")
