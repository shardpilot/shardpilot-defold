-- Local delivery clocks never enter an event envelope. Event snapshots and
-- their wire envelopes share one object, so a rollback reaches every writer.
local clock = require "shardpilot.clock"
local M = {}
local clocks = setmetatable({}, { __mode = "k" })
local function valid(value)
	return type(value) == "number" and value >= 0 and value < 9007199254740992
		and value == math.floor(value)
end
function M.start(event, prior)
	clocks[event] = prior or clocks[event] or { intake_ms = clock.unix_ms(), ambiguous_ms = 0 }
end
function M.bind(envelope, event)
	clocks[envelope] = clocks[event]
end
function M.get(event)
	return clocks[event]
end
function M.restore(events, saved)
	for _, event in ipairs(events) do
		local old = saved[event.event_id]
		clocks[event] = {
			intake_ms = type(old) == "table" and old.intake_ms or 0,
			ambiguous_ms = type(old) == "table" and old.ambiguous_ms,
		}
	end
end
function M.snapshot(events)
	local saved = {}
	for _, event in ipairs(events) do
		local age = clocks[event]
		if age then saved[event.event_id] = { intake_ms = age.intake_ms, ambiguous_ms = age.ambiguous_ms } end
	end
	return saved
end
function M.expired(event, now)
	local age = clocks[event]
	return not age or age.expired or not valid(now) or not valid(age.intake_ms)
		or age.intake_ms == 0 or age.intake_ms > now or now - age.intake_ms >= 7 * 86400000
		or not valid(age.ambiguous_ms) or age.ambiguous_ms > now
		or (age.ambiguous_ms > 0 and (age.ambiguous_ms < age.intake_ms
			or now - age.ambiguous_ms >= 15 * 60000))
end
function M.reset()
	clocks = setmetatable({}, { __mode = "k" })
end
return M
