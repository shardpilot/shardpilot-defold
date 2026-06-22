-- A bounded breadcrumb ring (consistent across our SDKs).
-- Holds at most `max_breadcrumbs` most-recent entries; on overflow the oldest is
-- dropped. Names are scrubbed at record time and rejected if they do not match
-- the breadcrumb-name shape or carry disallowed content, so nothing unsafe is
-- ever retained.
local clock = require "shardpilot.clock"
local sanitize = require "shardpilot.crash.sanitize"

local M = {}

local max_breadcrumbs = 50

M.max_breadcrumbs = max_breadcrumbs

local Ring = {}
Ring.__index = Ring

function M.new()
	return setmetatable({
		entries = {},
		next = 1,
		count = 0,
	}, Ring)
end

-- Record a breadcrumb by name (timestamped now, UTC). A name that fails the
-- scrub is silently dropped — recording must never raise.
function Ring:record(name)
	local clean, ok = sanitize.sanitize_breadcrumb_name(name)
	if not ok then
		return false
	end
	self.entries[self.next] = { name = clean, timestamp = clock.iso_utc() }
	self.next = (self.next % max_breadcrumbs) + 1
	if self.count < max_breadcrumbs then
		self.count = self.count + 1
	end
	return true
end

-- Return the retained breadcrumbs oldest-first as a fresh array, or nil when
-- empty.
function Ring:snapshot()
	if self.count == 0 then
		return nil
	end
	local out = {}
	local start
	if self.count == max_breadcrumbs then
		start = self.next
	else
		start = 1
	end
	for i = 0, self.count - 1 do
		local idx = ((start - 1 + i) % max_breadcrumbs) + 1
		local entry = self.entries[idx]
		out[#out + 1] = { name = entry.name, timestamp = entry.timestamp }
	end
	return out
end

return M
