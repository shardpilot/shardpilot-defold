-- Recording and process-local ordinary analytics admission, separate from consent.
local clock = require "shardpilot.clock"
local id = require "shardpilot.id"
local snapshot = require "shardpilot.non_objection"
local storage = require "shardpilot.storage"
local transport = require "shardpilot.transport"
local M = {}

local function actor(client)
	if client.config.token_provider and client.user_id then return client.user_id, "user_verified" end
	return client.anonymous_id, "anon"
end

local function eligible(client, operation, draining)
	local who, kind = actor(client)
	for _, receipt in ipairs(client.consent_outbox) do
		if receipt.actor_identifier == who and receipt.kind == kind
			and receipt.categories and receipt.categories.analytics == false then return false end
	end
	return client.initialized and (draining or (not client.closing and not client.non_objection_closing))
		and operation.generation == client.non_objection_generation
		and operation.user_id == client.user_id
		and client.consent_state == "unknown" and not client:outbox_write_held()
		and not client.consent_marker_unreadable
		and client.anonymous_id == operation.anonymous_id and who == operation.actor_identifier
		and kind == operation.kind and client.config.workspace_id == operation.workspace_id
		and client.config.app_id == operation.app_id and client.config.environment_id == operation.environment_id
end

local function finish(client, operation, ok, code, acknowledgement)
	if client.non_objection ~= operation then return end
	client.non_objection = nil
	operation.code = code
	local attempt = client.non_objection_attempt
	if attempt and attempt.operation == operation then
		client.non_objection_attempt = nil
		client.consent_send_in_flight, client.consent_in_flight_key = false, nil
	end
	if operation.idempotency_key and client.consent_deferral_armed_key == operation.idempotency_key then
		client.consent_retry_after_ms, client.consent_deferral_armed_key = nil, nil
		client.consent_backoff_attempt = 0
	end
	if operation.callback then pcall(operation.callback, ok, code, acknowledgement) end
end

function M.revoke(client)
	if not client.non_objection_admission then return end
	client.non_objection_admission = nil
	if client.consent_state ~= "granted" then client:discard_non_objection_events() end
end

function M.admitted(client)
	local admission = client.non_objection_admission
	return admission ~= nil and eligible(client, admission, true)
end

function M.poll(client, reason, teardown)
	if client.non_objection_admission and (teardown or not M.admitted(client)) then M.revoke(client) end
	local operation = client.non_objection
	if not operation then return end
	reason = reason or operation.cancel_reason
	if operation.preparing then
		operation.cancel_reason = reason
		return
	end
	if not reason and not eligible(client, operation) then reason = "non_objection_superseded" end
	if not reason and clock.unix_ms() >= operation.deadline_ms then reason = "non_objection_timeout" end
	local retained = false
	for _, receipt in ipairs(client.consent_outbox) do
		if receipt.idempotency_key == operation.idempotency_key then retained = true; break end
	end
	if not retained and not operation.preparing then reason = reason or "non_objection_superseded" end
	if reason then finish(client, operation, false, reason) end
end

function M.active(client, receipt)
	return client.non_objection ~= nil and eligible(client, client.non_objection)
		and not client.non_objection.preparing
		and client.non_objection.idempotency_key == receipt.idempotency_key
end

function M.discard_undurable(client)
	if storage.consent_outbox_is_durable(client.config) then return end
	local keys = {}
	for _, receipt in ipairs(client.consent_outbox) do
		if receipt.admission_basis == "advisory_non_objection" then keys[#keys + 1] = receipt.idempotency_key end
	end
	if #keys == 0 then return end
	local ok, reason = storage.drop_consent_receipts(client.config, keys)
	client:record_outbox_op(ok, reason)
	client:diagnose({ scope = "non_objection", status = "dropped", code = "shutdown_undurable", count = #keys })
end

function M.record(client, record, callback)
	local function refuse(code)
		if type(callback) == "function" then pcall(callback, false, code) end
		return false, code
	end
	if callback ~= nil and type(callback) ~= "function" then return false, "invalid_callback" end
	if not client.initialized or client.closing or client.non_objection_closing then return refuse("shutdown") end
	M.revoke(client) -- A fresh host eligibility decision owns a fresh ACK episode.
	client.non_objection_generation = (client.non_objection_generation or 0) + 1
	local generation = client.non_objection_generation
	if client.non_objection and client.non_objection.preparing then return refuse("non_objection_pending") end
	local captured, err = snapshot.snapshot(record)
	if not captured then
		if client.non_objection then finish(client, client.non_objection, false, "non_objection_superseded") end
		return refuse(err)
	end
	M.poll(client)
	if generation ~= client.non_objection_generation then return refuse("non_objection_superseded") end
	if client.non_objection then return refuse("non_objection_pending") end
	local who, kind = actor(client)
	local operation = { actor_identifier = who, kind = kind, anonymous_id = client.anonymous_id, user_id = client.user_id,
		workspace_id = client.config.workspace_id, app_id = client.config.app_id,
		environment_id = client.config.environment_id, callback = callback, snapshot = captured, preparing = true,
		generation = generation,
		deadline_ms = clock.unix_ms() + client.config.http_timeout_seconds * 1000 }
	if not eligible(client, operation) then return refuse("non_objection_ineligible") end
	client.non_objection = operation
	-- Recovery never reopens eligibility: only this fresh matching host call
	-- reattaches a retained record, preserving its decision time and retry key.
	client:retry_consent_outbox_persist()
	for _, receipt in ipairs(client.consent_outbox) do
		if receipt.actor_identifier == who and receipt.kind == kind
			and receipt.anonymous_id == client.anonymous_id
			and receipt.workspace_id == operation.workspace_id and receipt.app_id == operation.app_id
			and receipt.environment_id == operation.environment_id
			and snapshot.equal(snapshot.from_receipt(receipt), captured) then
			operation.idempotency_key = receipt.idempotency_key; break
		end
	end
	if not operation.idempotency_key then
		local receipt = assert(snapshot.snapshot(captured))
		for _, key in ipairs({ "actor_identifier", "kind", "anonymous_id", "workspace_id", "app_id", "environment_id" }) do
			receipt[key] = operation[key]
		end
		receipt.admission_basis, receipt.purpose = "advisory_non_objection", "analytics"
		receipt.decided_at, receipt.idempotency_key = clock.iso_utc(), id.uuid_v7()
		local ok, reason, evicted = storage.append_consent_receipt(client.config, receipt)
		if not client:record_outbox_op(ok, reason, evicted) then
			finish(client, operation, false, reason); return false, reason
		end
		operation.idempotency_key = receipt.idempotency_key
	end
	if client.consent_outbox_dirty then
		finish(client, operation, false, "consent_outbox_write_failed"); return false, "consent_outbox_write_failed"
	end
	operation.preparing = nil
	M.poll(client)
	if client.non_objection ~= operation then return false, operation.code or "non_objection_superseded" end
	client:try_send_consent_outbox()
	return true
end

function M.send(client, receipt)
	local operation = client.non_objection
	if not M.active(client, receipt) then return false end
	local credential_available = client:can_publish()
	M.poll(client) -- A synchronous mint can cross the deadline or change identity.
	if not credential_available or client.non_objection ~= operation or not M.active(client, receipt) then return false end
	local wire = assert(snapshot.from_receipt(receipt))
	for _, key in ipairs({ "actor_identifier", "kind", "decided_at", "idempotency_key", "admission_basis", "purpose" }) do
		wire[key] = receipt[key]
	end
	wire.workspace_key, wire.app_key, wire.environment_key = receipt.workspace_id, receipt.app_id, receipt.environment_id
	local attempt = { operation = operation }
	client.non_objection_attempt = attempt
	client.consent_send_in_flight, client.consent_in_flight_key = true, receipt.idempotency_key
	transport.send_consent(client.config, client.token, wire, function(ok, err, unauthorized, retryable, response, retry_after)
		if attempt.answered then return end
		attempt.answered = true
		M.poll(client)
		if client.non_objection_attempt ~= attempt then return end
		client.non_objection_attempt = nil
		client.consent_send_in_flight, client.consent_in_flight_key = false, nil
		local acknowledgement
		if ok then
			local decoded_ok, decoded = pcall(function() return json.decode(response.response) end)
			acknowledgement = decoded_ok and snapshot.response(decoded) or nil
			if not acknowledgement then ok, err, retryable = false, "non_objection_response_invalid", false end
		end
		M.poll(client)
		if client.non_objection ~= operation then return end
		if unauthorized and not client.config.token_provider then retryable = false end
		if ok or not retryable then
			if ok then
				local admission = {}
				for _, key in ipairs({ "actor_identifier", "kind", "anonymous_id", "user_id", "workspace_id", "app_id", "environment_id", "snapshot", "generation" }) do
					admission[key] = operation[key]
				end
				client.non_objection_admission = admission
			end
			client:remove_consent_receipt(receipt.idempotency_key)
			finish(client, operation, ok, err, acknowledgement)
			if not ok then client:diagnose({ scope = "non_objection", status = "dropped", code = err }) end
			client:try_send_consent_outbox()
			return
		end
		if unauthorized then client.token, client.token_expires_at_ms = nil, nil end
		if retry_after and retry_after > 0 then client:defer_consent(retry_after)
		else client:defer_consent_backoff() end
		client.consent_deferral_armed_key = receipt.idempotency_key
	end, function()
		M.poll(client) -- Encoding can call a synchronous host bridge too.
		if client.non_objection_attempt == attempt and M.active(client, receipt) then return wire end
	end)
	return true
end

return M
