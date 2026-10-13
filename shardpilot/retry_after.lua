-- Retry-After, as every plane reads it: delta-seconds or an HTTP date (all
-- three spellings), a floor for the next attempt, capped at 24 hours.
local clock = require "shardpilot.clock"

local M = {}

M.MAX_SECONDS = 86400

local months = { Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6, Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12 }
local weekdays = { Sun=true, Mon=true, Tue=true, Wed=true, Thu=true, Fri=true, Sat=true,
	Sunday=true, Monday=true, Tuesday=true, Wednesday=true, Thursday=true, Friday=true, Saturday=true }

-- Seconds since the epoch for an IMF-fixdate, RFC 850 or asctime date, or nil.
local function http_date(value)
	if not weekdays[value:match("^(%a+)")] then return nil end
	local day, mon, year, hour, minute, second = value:match("^%a+, (%d%d) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d) GMT$")
	if not day then
		day, mon, year, hour, minute, second = value:match("^%a+, (%d%d)%-(%a%a%a)%-(%d%d) (%d%d):(%d%d):(%d%d) GMT$")
		if year then
			-- A two-digit year more than 50 years ahead is in the past century.
			local current = tonumber(os.date("!%Y", math.floor(clock.unix_ms() / 1000)))
			year = math.floor(current / 100) * 100 + tonumber(year)
			if year > current + 50 then year = year - 100 end
		end
	end
	if not day then
		mon, day, hour, minute, second, year = value:match("^%a%a%a (%a%a%a) +(%d%d?) (%d%d):(%d%d):(%d%d) (%d%d%d%d)$")
	end
	day, year, hour, minute, second = tonumber(day), tonumber(year), tonumber(hour), tonumber(minute), tonumber(second)
	local month = months[mon]
	if not day or not month or year < 1 or hour > 23 or minute > 59 or second > 59 then return nil end
	local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
	local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if day < 1 or day > days[month] then return nil end
	local y = year - 1
	local total = 365 * y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) - 719162 + day - 1
	for m = 1, month - 1 do total = total + days[m] end
	return total * 86400 + hour * 3600 + minute * 60 + second
end

-- The Retry-After of a response as whole seconds to wait, or nil when it is
-- absent or unreadable. A past date asks for no wait. The real Defold http API
-- lowercases response header names; other hosts may not.
function M.seconds(response)
	if type(response) ~= "table" or type(response.headers) ~= "table" then return nil end
	local value = response.headers["retry-after"] or response.headers["Retry-After"]
	local seconds
	if type(value) == "number" then
		seconds = value
	elseif type(value) == "string" and #value <= 128 then
		value = value:match("^%s*(.-)%s*$")
		seconds = tonumber(value:match("^%d+$"))
		if not seconds then
			local at = http_date(value)
			if at then seconds = math.max(0, math.ceil(at - clock.unix_ms() / 1000)) end
		end
	end
	if not seconds or seconds ~= seconds or seconds < 0 then return nil end
	return math.min(M.MAX_SECONDS, math.floor(seconds))
end

return M
