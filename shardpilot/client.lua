local envelope = require "shardpilot.envelope"
local clock = require "shardpilot.clock"
local id = require "shardpilot.id"
local platform = require "shardpilot.platform"
local queue = require "shardpilot.queue"
local sampling = require "shardpilot.sampling"
local transport = require "shardpilot.transport"

local M = {}

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

local function local_http_host(host)
	return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function parse_authority(authority)
	if authority == "" or authority:find("@", 1, true) then
		return nil
	end
	local host = nil
	if authority:sub(1, 1) == "[" then
		local rest = nil
		host, rest = authority:match("^%[([^%]]+)%](.*)$")
		if not host then
			return nil
		end
		if rest ~= "" and not rest:match("^:%d+$") then
			return nil
		end
	else
		local colon = authority:find(":", 1, true)
		if colon then
			host = authority:sub(1, colon - 1)
			local port = authority:sub(colon + 1)
			if port == "" or not port:match("^%d+$") then
				return nil
			end
		else
			host = authority
		end
		if host:find(":", 1, true) then
			return nil
		end
	end
	if not host or host == "" or host:match("%s") then
		return nil
	end
	return host
end

local function valid_ingest_url(value)
	if type(value) ~= "string" or value == "" then
		return false
	end
	if value:find("?", 1, true) or value:find("#", 1, true) then
		return false
	end
	local scheme, rest = value:match("^(https?)://(.+)$")
	if not scheme then
		return false
	end
	local authority = rest
	local path = nil
	local slash = rest:find("/", 1, true)
	if slash then
		authority = rest:sub(1, slash - 1)
		path = rest:sub(slash)
	end
	if path and path ~= "/" then
		return false
	end
	local host = parse_authority(authority or "")
	if not host then
		return false
	end
	if scheme == "https" then
		return true
	end
	return local_http_host(host)
end

local max_snapshot_depth = 4

local function copy_value(value, depth, seen)
	if type(value) ~= "table" then
		return value, nil
	end
	if depth >= max_snapshot_depth or seen[value] then
		return nil, "invalid_table"
	end
	seen[value] = true
	local out = {}
	for k, v in pairs(value) do
		if type(k) == "table" then
			seen[value] = nil
			return nil, "invalid_table"
		end
		local copied, err = copy_value(v, depth + 1, seen)
		if err then
			seen[value] = nil
			return nil, err
		end
		out[k] = copied
	end
	seen[value] = nil
	return out, nil
end

local function copy_table(value, error_code)
	if value == nil or type(value) ~= "table" then
		return nil, nil
	end
	local copied, err = copy_value(value, 0, {})
	if err then
		return nil, error_code
	end
	return copied, nil
end

local function valid_identity(value)
	return type(value) == "string" and value ~= ""
end

local function normalize_integer(value, default_value, min_value, max_value, error_code)
	if value == nil then
		return default_value
	end
	if type(value) ~= "number" or value ~= math.floor(value) or value < min_value then
		return nil, error_code
	end
	if max_value and value > max_value then
		return nil, error_code
	end
	return value
end

local function normalize_positive_number(value, default_value, error_code)
	if value == nil then
		return default_value
	end
	if type(value) ~= "number" or value <= 0 then
		return nil, error_code
	end
	return value
end

local function normalize_non_negative_number(value, default_value, error_code)
	if value == nil then
		return default_value
	end
	if type(value) ~= "number" or value < 0 then
		return nil, error_code
	end
	return value
end

local function validate_config(config)
	if type(config) ~= "table" then
		return nil, "config_required"
	end
	local required = { "ingest_url", "workspace_id", "app_id", "environment_id" }
	for _, key in ipairs(required) do
		if config[key] == nil or config[key] == "" then
			return nil, key .. "_required"
		end
		if type(config[key]) ~= "string" then
			return nil, "invalid_" .. key
		end
	end
	if not valid_ingest_url(config.ingest_url) then
		return nil, "invalid_ingest_url"
	end
	if type(config.token_provider) ~= "function" then
		return nil, "token_provider_required"
	end
	local source = config.source or "client"
	if source ~= "client" and source ~= "server" and source ~= "backend" then
		return nil, "invalid_source"
	end
	local batch_size, batch_size_err = normalize_integer(config.batch_size, 25, 1, 100, "invalid_batch_size")
	if not batch_size then
		return nil, batch_size_err
	end
	local buffer_size, buffer_size_err = normalize_integer(config.buffer_size, 200, 1, nil, "invalid_buffer_size")
	if not buffer_size then
		return nil, buffer_size_err
	end
	local flush_interval_seconds, flush_interval_err =
		normalize_positive_number(config.flush_interval_seconds, 1, "invalid_flush_interval_seconds")
	if not flush_interval_seconds then
		return nil, flush_interval_err
	end
	local publish_timeout_seconds, publish_timeout_err =
		normalize_positive_number(config.publish_timeout_seconds, 2, "invalid_publish_timeout_seconds")
	if not publish_timeout_seconds then
		return nil, publish_timeout_err
	end
	local token_refresh_lead_ms, token_refresh_lead_err =
		normalize_non_negative_number(config.token_refresh_lead_ms, 60000, "invalid_token_refresh_lead_ms")
	if token_refresh_lead_ms == nil then
		return nil, token_refresh_lead_err
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
		batch_size = batch_size,
		buffer_size = buffer_size,
		flush_interval_seconds = flush_interval_seconds,
		publish_timeout_seconds = publish_timeout_seconds,
		token_refresh_lead_ms = token_refresh_lead_ms,
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
		token_request_in_flight = false,
		in_flight_batch = nil,
		publish_in_flight = false,
		user_id = valid_identity(config.user_id) and config.user_id or nil,
		anonymous_id = valid_identity(config.anonymous_id) and config.anonymous_id or nil,
		session_id = nil,
		session_sequence = 0,
		session_active = false,
		perf = sampling.new_perf(),
		network = sampling.new_network(),
		flush_elapsed_seconds = 0,
		initialized = true,
	}, Client)
end

function Client:identify(user_id)
	if not valid_identity(user_id) then
		return false, "invalid_user_id"
	end
	self.user_id = user_id
	return true
end

function Client:set_anonymous_id(anonymous_id)
	if not valid_identity(anonymous_id) then
		return false, "invalid_anonymous_id"
	end
	self.anonymous_id = anonymous_id
	return true
end

function Client:session_start(props)
	local previous_session_id = self.session_id
	local previous_session_sequence = self.session_sequence
	local previous_session_active = self.session_active

	self.session_id = "session-" .. id.uuid()
	self.session_sequence = 0
	self.session_active = true
	local ok, err = self:track("session_start", props)
	if not ok then
		self.session_id = previous_session_id
		self.session_sequence = previous_session_sequence
		self.session_active = previous_session_active
		return false, err
	end
	return true
end

function Client:session_end(reason)
	local ok = self:track("session_end", { reason = reason or "session_end" })
	self.session_active = false
	return ok
end

function Client:screen_view(screen_name, props)
	local out = {}
	if type(props) == "table" then
		for key, value in pairs(props) do
			out[key] = value
		end
	end
	out.screen_name = screen_name
	return self:track("screen_view", out)
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
	local props_snapshot, props_err = copy_table(props, "invalid_props")
	if props_err then
		self.stats.dropped = self.stats.dropped + 1
		return false, props_err
	end
	local context_snapshot, context_err = copy_table(context, "invalid_context")
	if context_err then
		self.stats.dropped = self.stats.dropped + 1
		return false, context_err
	end
	local event = {
		event_id = id.uuid(),
		event_name = event_name,
		event_ts = clock.iso_utc(),
		user_id = self.user_id,
		anonymous_id = self.anonymous_id,
		session_id = self.session_id,
		session_sequence = self.session_sequence + 1,
		props = props_snapshot,
		context = context_snapshot,
	}
	local ok = queue.push(self.queue, event)
	if not ok then
		self.stats.dropped = self.stats.dropped + 1
		return false, "queue_full"
	end
	self.session_sequence = event.session_sequence
	self.stats.enqueued = self.stats.enqueued + 1
	return true
end

function Client:update(dt)
	if not self.initialized then
		return
	end
	if type(dt) == "number" and dt > 0 then
		self.flush_elapsed_seconds = self.flush_elapsed_seconds + dt
	end
	if self.session_active and type(dt) == "number" then
		sampling.sample_frame(self.perf, dt)
	end
	if queue.size(self.queue) >= self.config.batch_size or self.flush_elapsed_seconds >= self.config.flush_interval_seconds then
		self.flush_elapsed_seconds = 0
		self:flush({ include_summaries = false })
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
	if self.token_request_in_flight then
		return false
	end
	self.token_request_in_flight = true
	local ok, err = pcall(self.config.token_provider, function(new_token, new_expires_at, callback_error)
		self.token_request_in_flight = false
		if callback_error or type(new_token) ~= "string" or new_token == "" then
			self.token = nil
			self.token_expires_at_ms = nil
			self.stats.last_error = "token_unavailable"
			return
		end
		self.token = new_token
		self.token_expires_at_ms = new_expires_at
	end)
	if not ok then
		self.token_request_in_flight = false
		self.token = nil
		self.token_expires_at_ms = nil
		self.stats.last_error = "token_unavailable"
		return false
	end
	return self.token ~= nil
end

function Client:can_publish()
	if not valid_identity(self.user_id) and not valid_identity(self.anonymous_id) then
		self.stats.last_error = "identity_required"
		return false
	end
	local needs_token = not self.token
	if self.token and self.token_expires_at_ms then
		needs_token = clock.unix_ms() >= self.token_expires_at_ms - self.config.token_refresh_lead_ms
	end
	if needs_token and not self:refresh_token() then
		return false
	end
	return true
end

local function is_retryable_publish_failure(err, unauthorized, retryable)
	if retryable ~= nil then
		return retryable
	end
	if unauthorized then
		return true
	end
	return err == "http_0" or err == "http_unavailable" or err == "unauthorized" or err == "transient_429" or
		(type(err) == "string" and err:match("^transient_5%d%d$") ~= nil)
end

function Client:start_publish_batch()
	if self.publish_in_flight or not self.in_flight_batch or #self.in_flight_batch == 0 then
		return true, false, true
	end
	local events = self.in_flight_batch
	if not events.payload then
		local envelopes = {}
		for i, event in ipairs(events) do
			envelopes[i] = envelope.build(self.config, self, event)
		end
		events.payload = { events = envelopes }
	end
	self.publish_in_flight = true
	local completed = false
	local succeeded = false
	local dispatched = transport.publish(self.config, self.token, events.payload, function(ok, err, unauthorized, retryable)
		completed = true
		succeeded = ok == true
		self.publish_in_flight = false
		if ok then
			self.stats.published = self.stats.published + #events
			self.stats.accepted = self.stats.accepted + #events
			if self.in_flight_batch == events then
				self.in_flight_batch = nil
			end
			return
		end
		self.stats.failed_batches = self.stats.failed_batches + 1
		self.stats.last_error = err
		if unauthorized then
			self.token = nil
			self.token_expires_at_ms = nil
		end
		if not is_retryable_publish_failure(err, unauthorized, retryable) and self.in_flight_batch == events then
			self.stats.dropped = self.stats.dropped + #events
			self.in_flight_batch = nil
		end
	end)
	if not dispatched and self.publish_in_flight then
		self.publish_in_flight = false
	end
	return dispatched, completed, succeeded
end

function Client:flush(options)
	if type(options) ~= "table" then
		options = {}
	end
	if options.include_summaries ~= false then
		self:enqueue_summaries()
	end
	self.flush_elapsed_seconds = 0
	if self.publish_in_flight then
		if self.in_flight_batch or queue.size(self.queue) > 0 then
			return false, "pending"
		end
		return true
	end

	while true do
		local token_ready = false
		if not self.in_flight_batch then
			if queue.size(self.queue) == 0 then
				return true
			end
			if not self:can_publish() then
				return false
			end
			token_ready = true
			self.in_flight_batch = queue.drain(self.queue, self.config.batch_size)
		end
		if not token_ready and not self:can_publish() then
			return false
		end
		local dispatched, completed, succeeded = self:start_publish_batch()
		if not dispatched or (completed and not succeeded) then
			return false
		end
		if self.publish_in_flight then
			return false, "pending"
		end
	end
end

function Client:shutdown(reason)
	if self.session_active then
		self:session_end(reason or "app_final")
	end
	local ok, err = self:flush({ include_summaries = true })
	if ok then
		self.initialized = false
	end
	return ok, err
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
