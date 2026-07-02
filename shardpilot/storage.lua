-- Durable persistence for the identity record (anonymous ID + consent state),
-- the pending-crash sidecar, and the offline event spool.
-- This is the only SDK module allowed to call Defold sys persistence. Every
-- call is pcall-guarded so plain Lua hosts without the Defold `sys` API
-- degrade gracefully to in-memory state for the process lifetime.
--
-- Records are namespaced per configured app identity
-- (`shardpilot.<workspace_id>.<app_id>`, segments sanitized) so two games on
-- the same device never share an anonymous ID or consent decision. The bare
-- `shardpilot` namespace is only used when no scope is configured.

local clock = require "shardpilot.clock"

local M = {}

local memory_records = {}

local function clone(record)
	if type(record) ~= "table" then
		return nil
	end
	local out = {}
	for key, value in pairs(record) do
		out[key] = value
	end
	return out
end

local function sanitize(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return (value:gsub("[^%w%-_]", "_"))
end

local function namespace(scope)
	local workspace = sanitize(type(scope) == "table" and scope.workspace_id or nil)
	local app = sanitize(type(scope) == "table" and scope.app_id or nil)
	if workspace and app then
		return "shardpilot." .. workspace .. "." .. app
	end
	return "shardpilot"
end

-- A short, stable 32-bit hash of a string, returned as lowercase hex. Used to
-- disambiguate storage namespaces whose slugs would otherwise collide after the
-- sanitizer collapses disallowed characters to "_": two raw app ids like "com.game"
-- and "com_game" sanitize to the same slug but hash differently, so appending this
-- suffix keeps their per-app sidecars distinct.
--
-- This is a pure-arithmetic polynomial rolling hash (hash = hash * 131 + byte,
-- folded to 32 bits with a modulo) so it uses only features available on the
-- in-game Lua runtime — no bitwise operators. Every intermediate value stays well
-- within double-precision integer range: 2^32 * 131 + 255 < 2^53, so the
-- multiply-add never loses precision before the modulo folds it back to 32 bits.
local function short_hash(value)
	local hash = 2166136261
	for i = 1, #value do
		hash = (hash * 131 + value:byte(i)) % 4294967296
	end
	return string.format("%08x", hash)
end

local function save_path(ns, file_name)
	if type(sys) ~= "table" then
		return nil
	end
	if type(sys.get_save_file) ~= "function" or type(sys.save) ~= "function" or type(sys.load) ~= "function" then
		return nil
	end
	local ok, path = pcall(sys.get_save_file, ns, file_name or "identity")
	if not ok or type(path) ~= "string" or path == "" then
		return nil
	end
	return path
end

function M.load(scope)
	local ns = namespace(scope)
	local path = save_path(ns)
	if not path then
		return clone(memory_records[ns])
	end
	local ok, record = pcall(sys.load, path)
	if not ok or type(record) ~= "table" then
		return clone(memory_records[ns])
	end
	return record
end

function M.save(scope, record)
	if type(record) ~= "table" then
		return false
	end
	local ns = namespace(scope)
	memory_records[ns] = clone(record)
	local path = save_path(ns)
	if not path then
		return true
	end
	local ok, saved = pcall(sys.save, path, record)
	return ok and saved == true
end

-- ── pending crash reports ────────────────────────────────────────────────────
--
-- A previous-session native crash dump is one-shot: reading it consumes it from
-- disk. If the network send of the prepared report fails for a temporary reason
-- (offline / rate-limited / server error), the report would otherwise be lost
-- forever. These helpers persist such a report to a per-app sidecar so the next
-- launch can resend it. The list is bounded (count + per-record size) so a
-- persistently failing send can never grow the file without limit.

local pending_memory = {}

local max_pending_records = 8
local max_pending_record_bytes = 64 * 1024

-- A pending crash report older than this is a stale retry that is discarded on
-- read rather than resent: a report that has failed to send for a week is not
-- worth the bandwidth and bounds how long a sanitized report lingers on the
-- device (a local retention limit). The created-at stamp is taken from the SDK
-- clock when the report is first persisted.
local pending_ttl_ms = 7 * 24 * 60 * 60 * 1000

local function now_ms()
	local ok, ms = pcall(clock.unix_ms)
	if ok and type(ms) == "number" then
		return ms
	end
	return 0
end

-- A monotonically increasing per-process counter that makes each persisted entry
-- individually addressable, so a report persisted BEFORE its send can be removed
-- on acceptance/terminal rejection without disturbing other entries.
local pending_token_counter = 0

-- Seed the RNG once for this module so token suffixes do not repeat across
-- restarts. The counter and os.time() both reset/repeat when the app relaunches
-- within the same second, so a random suffix is what actually keeps a freshly
-- minted token from colliding with an entry persisted by a previous launch (a
-- collision would let remove_pending_crash delete the wrong, still-pending report).
local token_seeded = false

local function seed_token_rng()
	if token_seeded then
		return
	end
	local seed = (os.time and os.time() or 0)
	if socket and socket.gettime then
		seed = seed + math.floor(socket.gettime() * 1000000)
	end
	local address = tostring({}):match("0x(%x+)")
	if address then
		seed = seed + (tonumber(address:sub(-7), 16) or 0)
	end
	math.randomseed(seed)
	math.random()
	math.random()
	token_seeded = true
end

local function next_pending_token()
	seed_token_rng()
	pending_token_counter = pending_token_counter + 1
	-- counter + launch time keeps tokens human-readable and roughly ordered; the
	-- random suffix makes them robustly unique even across a same-second restart.
	local suffix = string.format("%x%x", math.random(0, 0xffffff), math.random(0, 0xffffff))
	return "p" .. tostring(pending_token_counter)
		.. "-" .. tostring(os.time and os.time() or 0)
		.. "-" .. suffix
end

local function pending_namespace(scope)
	-- The pending-crash sidecar is keyed per app so two games on the same device
	-- never share a queue, even when no workspace scope is configured (the crash
	-- client carries only an app id). Fall back to the shared namespace only when
	-- no app id is available at all.
	local app = sanitize(type(scope) == "table" and scope.app_id or nil)
	local base = namespace(scope)
	if app and base == "shardpilot" then
		base = "shardpilot." .. app
	end
	-- The sanitized slug above collapses any disallowed character to "_", so two raw
	-- app ids that differ only in such characters ("com.game" vs "com_game") would map
	-- to the SAME pending-crash namespace and let one app resend/remove another app's
	-- report. Append a short hash of the RAW (un-sanitized) scope so those two ids get
	-- distinct namespaces and per-app isolation holds. The hash is omitted only when no
	-- app id is available at all (the shared fallback has nothing to disambiguate).
	local raw_app = type(scope) == "table" and scope.app_id or nil
	if type(raw_app) == "string" and raw_app ~= "" then
		local raw_workspace = type(scope) == "table" and scope.workspace_id or nil
		local fingerprint = raw_app
		if type(raw_workspace) == "string" and raw_workspace ~= "" then
			fingerprint = raw_workspace .. "\0" .. raw_app
		end
		base = base .. "." .. short_hash(fingerprint)
	end
	return base .. ".pending-crashes"
end

local function approx_record_bytes(record)
	-- A cheap upper-bound size estimate without pulling in a JSON encoder:
	-- count the bytes of every string scalar in the record tree.
	local total = 0
	local function walk(value, depth)
		if depth > 32 then
			return
		end
		local value_type = type(value)
		if value_type == "string" then
			total = total + #value
		elseif value_type == "table" then
			for key, child in pairs(value) do
				if type(key) == "string" then
					total = total + #key
				end
				walk(child, depth + 1)
			end
		end
	end
	walk(record, 0)
	return total
end

-- Normalize a stored items list to the wrapped { token, report, created_at }
-- shape and apply the retention TTL. Returns (out, changed):
--   * An entry written by an older build (a bare prepared report with no
--     wrapper, or a wrapper missing created_at) is adopted with a freshly minted
--     token (when absent) and the current created-at stamp so it is individually
--     addressable and TTL-bounded. `changed` is set so the caller writes the
--     adopted entry back — otherwise a later read would mint a DIFFERENT token and
--     remove_pending_crash could never match it (an endless resend).
--   * An entry whose created_at is older than the TTL is discarded (a stale
--     retry); `changed` is set so the pruned list is written back.
local function normalize_items(items, current_ms)
	if type(items) ~= "table" then
		return {}, false
	end
	local out = {}
	local changed = false
	for i = 1, #items do
		local entry = items[i]
		if type(entry) == "table" then
			local report, token, created_at
			if type(entry.report) == "table" then
				report = entry.report
				token = entry.token
				created_at = entry.created_at
			else
				-- A bare (legacy) prepared report: wrap it.
				report = entry
			end
			if type(report) == "table" then
				if type(token) ~= "string" then
					token = next_pending_token()
					changed = true
				end
				if type(created_at) ~= "number" then
					created_at = current_ms
					changed = true
				end
				-- Discard a report older than the retention TTL.
				if (current_ms - created_at) > pending_ttl_ms then
					changed = true
				else
					out[#out + 1] = { token = token, report = report, created_at = created_at }
				end
			end
		end
	end
	return out, changed
end

local function load_raw_items(ns)
	local path = save_path(ns)
	if not path then
		return pending_memory[ns]
	end
	local ok, record = pcall(sys.load, path)
	if not ok or type(record) ~= "table" or type(record.items) ~= "table" then
		return pending_memory[ns]
	end
	return record.items
end

-- forward declaration: read_pending_list writes back an adopted/pruned list.
local write_pending_list

local function read_pending_list(ns)
	local current_ms = now_ms()
	local items, changed = normalize_items(load_raw_items(ns), current_ms)
	if changed then
		-- Persist the adopted tokens / pruned TTL so a later read sees stable tokens
		-- (a freshly minted token on every read would defeat remove_pending_crash and
		-- cause an endless resend) and so the stale entries stay gone. A write failure
		-- here is non-fatal: the in-memory normalized view is still returned.
		write_pending_list(ns, items)
	end
	return items
end

function write_pending_list(ns, items)
	local path = save_path(ns)
	if not path then
		-- No durable backend: the in-memory list IS the store. Update it and report
		-- success.
		pending_memory[ns] = items
		return true
	end
	local ok, saved = pcall(sys.save, path, { items = items })
	if not (ok and saved == true) then
		-- The durable write failed (e.g. disk quota). Do NOT update the in-memory
		-- shadow: leaving it unchanged keeps the persisted and in-memory views in
		-- agreement, so a later capture_previous() memory-fallback cannot resurface
		-- a crash this write would have settled, and the caller correctly sees a
		-- failed persist (no removable token).
		return false
	end
	pending_memory[ns] = items
	return true
end

-- Persist one prepared crash report for retry on a later launch. Returns a stable
-- token addressing the stored entry on success (so the caller can remove exactly
-- this entry once its send is accepted or terminally rejected), or nil when the
-- record is unusable or oversized. If `token` is supplied and an entry with that
-- token already exists, the stored report is refreshed in place (idempotent
-- re-persist) rather than appended a second time. The oldest entry is evicted once
-- the bound is reached so the list never grows past max_pending_records. Each entry
-- is stamped with a created-at time (from the SDK clock by default; `created_at_ms`
-- overrides it for tests) so the retention TTL can discard a stale report on read.
function M.save_pending_crash(scope, record, token, created_at_ms)
	if type(record) ~= "table" then
		return nil
	end
	local stamp = type(created_at_ms) == "number" and created_at_ms or now_ms()
	if approx_record_bytes(record) > max_pending_record_bytes then
		return nil
	end
	local ns = pending_namespace(scope)
	local items = read_pending_list(ns)
	-- Defensive copy so a later caller mutation cannot reach the stored snapshot.
	local stored = {}
	for i = 1, #items do
		stored[i] = items[i]
	end
	if token then
		-- Idempotent re-persist: replace an existing entry with this token in place.
		for i = 1, #stored do
			if stored[i].token == token then
				-- Refresh the report in place but PRESERVE the original created-at so a
				-- re-persist cannot reset the retention TTL and keep a report alive
				-- indefinitely.
				local created_at = type(stored[i].created_at) == "number" and stored[i].created_at or stamp
				stored[i] = { token = token, report = record, created_at = created_at }
				if write_pending_list(ns, stored) then
					return token
				end
				return nil
			end
		end
	else
		-- Mint a token that is not already present in the stored list, so a new
		-- entry can never reuse a still-pending entry's token (which would let a
		-- later remove delete the wrong report). The random suffix makes a collision
		-- almost impossible; this loop closes the gap entirely.
		repeat
			token = next_pending_token()
			local clash = false
			for i = 1, #stored do
				if stored[i].token == token then
					clash = true
					break
				end
			end
		until not clash
	end
	stored[#stored + 1] = { token = token, report = record, created_at = stamp }
	while #stored > max_pending_records do
		table.remove(stored, 1)
	end
	-- The count bound alone does not guarantee the SERIALIZED list fits the durable
	-- store's per-file limit (Defold's sys.save caps a saved table at 512 KB):
	-- approx_record_bytes counts only string scalars and ignores table/wrapper
	-- overhead, so a list of near-budget records can still overflow and fail the
	-- write. A failed write would lose THIS report (no removable token). So evict
	-- the OLDEST entries one at a time and retry the write until it succeeds or only
	-- the just-added report remains — the new report is the one we must not lose, so
	-- it is evicted last. This keeps a pending crash report always persistable and
	-- therefore removable.
	while true do
		if write_pending_list(ns, stored) then
			return token
		end
		if #stored <= 1 then
			-- Even the single new report could not be written: the backend is
			-- unavailable. Report a failed persist (no removable token).
			return nil
		end
		table.remove(stored, 1)
	end
end

-- Remove a single persisted entry by its token (called once its send is accepted
-- or terminally rejected). A no-op when no entry carries that token.
function M.remove_pending_crash(scope, token)
	if type(token) ~= "string" then
		return false
	end
	local ns = pending_namespace(scope)
	local items = read_pending_list(ns)
	local kept = {}
	for i = 1, #items do
		if items[i].token ~= token then
			kept[#kept + 1] = items[i]
		end
	end
	return write_pending_list(ns, kept)
end

-- Return the list of pending prepared crash reports for this app (possibly
-- empty), each the raw report ready for re-dispatch.
function M.load_pending_crashes(scope)
	local ns = pending_namespace(scope)
	local items = read_pending_list(ns)
	local out = {}
	for i = 1, #items do
		out[i] = items[i].report
	end
	return out
end

-- Return the pending entries as { token, report } pairs so a resend can address
-- (remove / re-persist) each entry individually.
function M.load_pending_entries(scope)
	local ns = pending_namespace(scope)
	local items = read_pending_list(ns)
	local out = {}
	for i = 1, #items do
		out[i] = { token = items[i].token, report = items[i].report }
	end
	return out
end

-- ── offline event spool ──────────────────────────────────────────────────────
--
-- Durable storage for analytics event envelopes the client could not deliver
-- (offline play, an app kill with a batch still in flight, a transient server
-- failure at shutdown). The client re-sends the spooled envelopes verbatim on a
-- later launch; each envelope carries the stable event_id stamped when the
-- event was tracked, so the ingest service de-duplicates a re-send that raced
-- an original delivery. The record is a flat FIFO list of envelope tables —
-- oldest first — bounded by both a count and an approximate serialized-bytes
-- budget supplied by the caller.

local spool_memory = {}

-- Defold documents that sys.save caps a saved table at 512 KB. The byte budget
-- passed by the caller is clamped to 384 KB so the approximate size estimate
-- plus table/serialization overhead always stays clear of that hard limit.
local max_spool_file_bytes = 393216

-- Approximate the serialized size of one envelope. When the runtime provides a
-- JSON encoder (real Defold does), the encoded length is used. Otherwise a
-- conservative fallback sums the bytes of every string key/value and charges a
-- fixed allowance per non-string scalar and per table for punctuation. The
-- estimate only steers FIFO eviction against the byte budget; it does not need
-- to be exact, which is why the budget is clamped well under the save-file cap.
local function approx_envelope_bytes(envelope)
	if json and type(json.encode) == "function" then
		local ok, encoded = pcall(json.encode, envelope)
		if ok and type(encoded) == "string" then
			return #encoded + 1
		end
	end
	local total = 2
	local function walk(value, depth)
		if depth > 16 then
			return
		end
		local value_type = type(value)
		if value_type == "string" then
			total = total + #value + 3
		elseif value_type == "number" or value_type == "boolean" then
			total = total + 12
		elseif value_type == "table" then
			total = total + 2
			for key, child in pairs(value) do
				if type(key) == "string" then
					total = total + #key + 3
				else
					total = total + 12
				end
				walk(child, depth + 1)
			end
		end
	end
	walk(envelope, 0)
	return total
end

-- The spool is keyed by the same per-app namespace scheme as the identity
-- record, plus the short raw-scope hash (as the pending-crash sidecar does) so
-- two raw app ids that sanitize to the same slug still get distinct spools.
local function spool_namespace(scope)
	local base = namespace(scope)
	local raw_workspace = type(scope) == "table" and scope.workspace_id or nil
	local raw_app = type(scope) == "table" and scope.app_id or nil
	if type(raw_app) == "string" and raw_app ~= "" then
		local fingerprint = raw_app
		if type(raw_workspace) == "string" and raw_workspace ~= "" then
			fingerprint = raw_workspace .. "\0" .. raw_app
		end
		base = base .. "." .. short_hash(fingerprint)
	end
	return base
end

-- Keep only entries that look like event envelopes (a table carrying a
-- non-empty string event_id). A corrupted or partially garbled record thus
-- degrades to the salvageable subset — or a clean empty spool — instead of
-- erroring into game code.
local function sanitize_spool_events(events)
	local out = {}
	if type(events) ~= "table" then
		return out
	end
	for i = 1, #events do
		local entry = events[i]
		if type(entry) == "table" and type(entry.event_id) == "string" and entry.event_id ~= "" then
			out[#out + 1] = entry
		end
	end
	return out
end

local function write_spool(ns, events)
	local path = save_path(ns, "spool")
	if not path then
		-- No durable backend (plain Lua host): the in-memory list is the store.
		spool_memory[ns] = events
		return true
	end
	local ok, saved = pcall(sys.save, path, { events = events })
	if not (ok and saved == true) then
		return false
	end
	spool_memory[ns] = events
	return true
end

-- Load the spooled envelopes for this app (possibly empty). A failed or
-- garbled sys.load discards the record and starts clean; this never throws.
function M.load_spool(scope)
	local ns = spool_namespace(scope)
	local path = save_path(ns, "spool")
	if not path then
		return sanitize_spool_events(spool_memory[ns])
	end
	local ok, record = pcall(sys.load, path)
	if not ok or type(record) ~= "table" then
		return sanitize_spool_events(spool_memory[ns])
	end
	return sanitize_spool_events(record.events)
end

-- Replace the persisted spool with `events` (oldest first), enforcing the
-- count and approximate-bytes caps by evicting the OLDEST entries first.
-- Returns the list that was actually persisted (possibly shorter than the
-- input after eviction), or nil when the durable write failed outright.
function M.save_spool(scope, events, max_events, max_bytes)
	local ns = spool_namespace(scope)
	local kept = sanitize_spool_events(events)
	local limit_events = (type(max_events) == "number" and max_events > 0) and max_events or 500
	local limit_bytes = (type(max_bytes) == "number" and max_bytes > 0) and max_bytes or 262144
	if limit_bytes > max_spool_file_bytes then
		limit_bytes = max_spool_file_bytes
	end
	while #kept > limit_events do
		table.remove(kept, 1)
	end
	-- Estimate each entry once, then evict from the front (oldest) until the
	-- summed estimate fits the byte budget.
	local total = 2
	local sizes = {}
	for i = 1, #kept do
		sizes[i] = approx_envelope_bytes(kept[i])
		total = total + sizes[i]
	end
	local drop = 0
	while drop < #kept and total > limit_bytes do
		drop = drop + 1
		total = total - sizes[drop]
	end
	if drop > 0 then
		local trimmed = {}
		for i = drop + 1, #kept do
			trimmed[#trimmed + 1] = kept[i]
		end
		kept = trimmed
	end
	-- The estimate ignores serialization overhead, so a near-budget list can
	-- still overflow the save-file cap and fail the write. Evict the oldest
	-- entries one at a time and retry until the write succeeds or nothing is
	-- left to save (then the backend itself is unavailable).
	while true do
		if write_spool(ns, kept) then
			return kept
		end
		if #kept == 0 then
			return nil
		end
		table.remove(kept, 1)
	end
end

-- Drop the whole spool (consent revoked, or a persisted denial found at load).
function M.clear_spool(scope)
	return write_spool(spool_namespace(scope), {})
end

-- Clears the in-memory fallback records only; intended for tests.
function M.reset()
	memory_records = {}
	pending_memory = {}
	spool_memory = {}
end

return M
