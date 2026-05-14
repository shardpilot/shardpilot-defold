local clock = require "shardpilot.clock"

local M = {}

local function percentile(sorted, p)
	if #sorted == 0 then
		return 0
	end
	local index = math.ceil(#sorted * p)
	if index < 1 then
		index = 1
	end
	if index > #sorted then
		index = #sorted
	end
	return sorted[index]
end

local function sorted_copy(values)
	local out = {}
	for i, value in ipairs(values) do
		out[i] = value
	end
	table.sort(out)
	return out
end

function M.new_perf()
	return {
		start_ms = clock.unix_ms(),
		frames = {},
	}
end

function M.sample_frame(state, dt)
	if not dt or dt <= 0 then
		return
	end
	state.frames[#state.frames + 1] = dt * 1000
end

function M.perf_summary(state)
	if #state.frames == 0 then
		return nil
	end
	local total_ms = 0
	local max_ms = 0
	for _, value in ipairs(state.frames) do
		total_ms = total_ms + value
		if value > max_ms then
			max_ms = value
		end
	end
	local sorted = sorted_copy(state.frames)
	local duration_ms = math.max(clock.unix_ms() - state.start_ms, math.floor(total_ms))
	local summary = {
		avg_fps = math.floor((#state.frames / math.max(total_ms / 1000, 0.001)) * 100 + 0.5) / 100,
		p50_frame_time_ms = percentile(sorted, 0.50),
		p95_frame_time_ms = percentile(sorted, 0.95),
		max_frame_time_ms = max_ms,
		frames_sampled = #state.frames,
		duration_ms = duration_ms,
	}
	state.start_ms = clock.unix_ms()
	state.frames = {}
	return summary
end

function M.new_network()
	return {
		pings = {},
		disconnect_count = 0,
		last_disconnect_reason = nil,
	}
end

function M.sample_ping(state, ms)
	if type(ms) == "number" and ms >= 0 then
		state.pings[#state.pings + 1] = ms
	end
end

function M.disconnect(state, reason)
	state.disconnect_count = state.disconnect_count + 1
	if type(reason) == "string" then
		state.last_disconnect_reason = reason:sub(1, 64)
	end
end

function M.network_summary(state, transport)
	if #state.pings == 0 and state.disconnect_count == 0 then
		return nil
	end
	local total = 0
	local max_ping = 0
	for _, value in ipairs(state.pings) do
		total = total + value
		if value > max_ping then
			max_ping = value
		end
	end
	local sorted = sorted_copy(state.pings)
	local summary = {
		avg_ping_ms = #state.pings > 0 and total / #state.pings or 0,
		p50_ping_ms = percentile(sorted, 0.50),
		p95_ping_ms = percentile(sorted, 0.95),
		max_ping_ms = max_ping,
		ping_sample_count = #state.pings,
		disconnect_count = state.disconnect_count,
		transport = transport,
	}
	state.pings = {}
	state.disconnect_count = 0
	state.last_disconnect_reason = nil
	return summary
end

return M
