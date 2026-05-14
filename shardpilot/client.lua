local envelope = require "shardpilot.envelope"
local platform = require "shardpilot.platform"
local queue = require "shardpilot.queue"
local sampling = require "shardpilot.sampling"
local transport = require "shardpilot.transport"

local M = {}

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

local function validate_config(config)
	if type(config) ~= "table" then
		return nil, "config_required"
	end
	local required = { "ingest_url", "workspace_id", "app_id", "environment_id", "token_provider" }
	for _, key in ipairs(required) do
		if not config[key] or config[key] == "" then
			return nil, key .. "_required"
		end
	end
	if type(config.token_provider) ~= "function" then
		return nil, "token_provider_required"
	end
	local source = config.source or "client"
	if source ~= "client" and source ~= "server" and source ~= "backend" then
		return nil, "invalid_source"
	end
	local out = {
		ingest_url = trim_slash(config.ingest_url),
		workspace_id = config.workspace_id,
		app_id = config.app_id,
		environment_id = config.environment_id,
		app_version = config.app_version,
		app_build = config.app_build,
		source = source,
		platform = config.platform or platform.detect(),
		transport = config.transport,
		token_provider = config.token_provider,
		batch_size = math.min(config.batch_size or 25, 100),
		buffer_size = config.buffer_size or 200,
		flush_interval_seconds = config.flush_interval_seconds or 1,
		publish_timeout_seconds = config.publish_timeout_seconds or 2,
	}
	return out
end

local Client = {}
Client.__index = Client

function M.new(config)
	local normalized, err = validate_config(config)
	if not normalized then
		return nil, err
	end
	return setmetatable({
		config = normalized,
		queue = queue.new(normalized.buffer_size),
		stats = {
			enqueued = 0,
			dropped = 0,
			published = 0,
			failed_batches = 0,
			accepted = 0,
			rejected = 0,
			duplicates = 0,
			last_error = nil,
		},
		token = nil,
		token_expires_at_ms = nil,
		user_id = config.user_id,
		anonymous_id = config.anonymous_id,
		session_id = nil,
		session_sequence = 0,
		session_active = false,
		perf = sampling.new_perf(),
		network = sampling.new_network(),
		initialized = true,
	}, Client)
end

function Client:identify(user_id)
	self.user_id = user_id
	return true
end

function Client:set_anonymous_id(anonymous_id)
	self.anonymous_id = anonymous_id
	return true
end

function Client:session_start(props)
	self.session_id = self.session_id or ("session-" .. tostring(math.random(100000, 999999)))
	self.session_active = true
	return self:track("session_start", props)
end

function Client:session_end(reason)
	local ok = self:track("session_end", { reason = reason or "session_end" })
	self.session_active = false
	return ok
end

function Client:screen_view(screen_name, props)
	props = props or {}
	props.screen_name = screen_name
	return self:track("screen_view", props)
end

function Client:tutorial_start(tutorial_id)
	return self:track("tutorial_start", { tutorial_id = tutorial_id })
end

function Client:tutorial_step_complete(tutorial_id, step_id)
	return self:track("tutorial_step_complete", { tutorial_id = tutorial_id, step_id = step_id })
end

function Client:tutorial_complete(tutorial_id)
	return self:track("tutorial_complete", { tutorial_id = tutorial_id })
end

function Client:track(event_name, props, context)
	if not self.initialized then
		self.stats.dropped = self.stats.dropped + 1
		return false, "shutdown"
	end
	if type(event_name) ~= "string" or event_name == "" then
		self.stats.dropped = self.stats.dropped + 1
		return false, "event_name_required"
	end
	local ok = queue.push(self.queue, {
		event_name = event_name,
		props = props,
		context = context,
	})
	if not ok then
		self.stats.dropped = self.stats.dropped + 1
		return false, "queue_full"
	end
	self.stats.enqueued = self.stats.enqueued + 1
	return true
end

function Client:update(dt)
	if self.initialized and self.session_active then
		sampling.sample_frame(self.perf, dt)
	end
end

function Client:observe_ping_ms(ms)
	sampling.sample_ping(self.network, ms)
end

function Client:observe_disconnect(reason)
	sampling.disconnect(self.network, reason)
end

function Client:enqueue_summaries()
	local perf = sampling.perf_summary(self.perf)
	if perf then
		self:track("perf_summary", perf)
	end
	local network = sampling.network_summary(self.network, self.config.transport)
	if network then
		self:track("network_summary", network)
	end
end

function Client:refresh_token()
	local token, expires_at, provider_error = nil, nil, nil
	local ok, err = pcall(self.config.token_provider, function(new_token, new_expires_at, callback_error)
		token = new_token
		expires_at = new_expires_at
		provider_error = callback_error
	end)
	if not ok then
		provider_error = err
	end
	if provider_error or not token or token == "" then
		self.stats.last_error = "token_unavailable"
		return false
	end
	self.token = token
	self.token_expires_at_ms = expires_at
	return true
end

function Client:can_publish()
	if not self.user_id and not self.anonymous_id then
		self.stats.last_error = "identity_required"
		return false
	end
	if not self.token and not self:refresh_token() then
		return false
	end
	return true
end

function Client:flush()
	self:enqueue_summaries()
	if queue.size(self.queue) == 0 then
		return true
	end
	if not self:can_publish() then
		return false
	end

	local all_dispatched = true
	while queue.size(self.queue) > 0 do
		local events = queue.drain(self.queue, self.config.batch_size)
		local envelopes = {}
		for i, event in ipairs(events) do
			envelopes[i] = envelope.build(self.config, self, event)
		end
		local payload = { events = envelopes }
		local dispatched = transport.publish(self.config, self.token, payload, function(ok, err, unauthorized)
			if ok then
				self.stats.published = self.stats.published + #events
				self.stats.accepted = self.stats.accepted + #events
			else
				self.stats.failed_batches = self.stats.failed_batches + 1
				self.stats.last_error = err
				if unauthorized then
					self.token = nil
					self.token_expires_at_ms = nil
				end
			end
		end)
		all_dispatched = all_dispatched and dispatched
	end
	return all_dispatched
end

function Client:shutdown(reason)
	if self.session_active then
		self:session_end(reason or "app_final")
	end
	self:enqueue_summaries()
	local ok = self:flush()
	self.initialized = false
	return ok
end

function Client:snapshot()
	local out = {}
	for key, value in pairs(self.stats) do
		out[key] = value
	end
	return out
end

M.Client = Client

return M
