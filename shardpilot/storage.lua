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
-- Every crash report the client dispatches is persisted to this per-app
-- sidecar BEFORE its send attempt (write-ahead): a previous-session native
-- crash dump is one-shot (reading it consumes it from disk), and a live
-- report whose send fails for a temporary reason (offline / rate-limited /
-- server error) — or whose process dies mid-send — would otherwise be lost
-- forever. The next launch resends whatever is still pending. An entry
-- stores the exact ENCODED wire body, so a resend is byte-identical to the
-- original attempt and the crash ingest service de-duplicates it by the
-- stable crash_id embedded in the body. The list is bounded (count,
-- per-record size, and total serialized bytes) so a persistently failing
-- send can never grow the file without limit.

local pending_memory = {}

local max_pending_records = 8
local max_pending_record_bytes = 64 * 1024
-- Total budget across all pending bodies. Defold documents that sys.save
-- caps a saved table at 512 KB; like the event spool's clamp, this stays
-- well under that hard limit so wrapper/serialization overhead can never
-- push a full list over the cap.
local max_pending_total_bytes = 384 * 1024
-- The clamp for a server-requested resend-backpressure deadline persisted
-- with the record (one day, matching the analytics publish deferral): a
-- corrupt or absurd stored deadline must never park crash resend
-- effectively forever.
local max_pending_retry_after_ms = 24 * 60 * 60 * 1000

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

-- The byte cost one pending entry charges against the caps: the exact
-- encoded-body length for a body entry, the string-scalar estimate for a
-- legacy prepared-report entry.
local function pending_entry_bytes(entry)
	if type(entry.body) == "string" then
		return #entry.body
	end
	return approx_record_bytes(entry.report)
end

-- Normalize a stored items list to the wrapped
-- { token, body|report, crash_id?, fatal, created_at } shape and apply the
-- retention TTL. Returns (out, changed):
--   * The CURRENT shape stores the exact encoded wire body (`body`, a JSON
--     string) plus its `crash_id` and a `fatal` flag. An entry written by an
--     older build — a bare prepared report with no wrapper, or a wrapper
--     carrying a prepared `report` table — is adopted as-is (the resend path
--     encodes a legacy report once at dispatch) with a freshly minted token
--     (when absent), the current created-at stamp, and fatal=true (legacy
--     entries were dump-sourced fatal crashes), so it stays individually
--     addressable and TTL-bounded. `changed` is set so the caller writes the
--     adopted entry back — otherwise a later read would mint a DIFFERENT
--     token and remove_pending_crash could never match it (an endless
--     resend).
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
			local body, crash_id, report, token, created_at, fatal
			if type(entry.body) == "string" and entry.body ~= "" then
				body = entry.body
				crash_id = type(entry.crash_id) == "string" and entry.crash_id or nil
				token = entry.token
				created_at = entry.created_at
				fatal = entry.fatal
			elseif type(entry.report) == "table" then
				report = entry.report
				token = entry.token
				created_at = entry.created_at
				fatal = entry.fatal
			else
				-- A bare (legacy) prepared report: wrap it.
				report = entry
			end
			if body or type(report) == "table" then
				if type(token) ~= "string" then
					token = next_pending_token()
					changed = true
				end
				if type(created_at) ~= "number" then
					created_at = current_ms
					changed = true
				end
				if type(fatal) ~= "boolean" then
					-- Legacy entries predate the flag and were dump-sourced
					-- fatal crashes; keeping them in the fatal tier means the
					-- adoption can never demote their eviction priority.
					fatal = true
					changed = true
				end
				-- Discard a report older than the retention TTL.
				if (current_ms - created_at) > pending_ttl_ms then
					changed = true
				else
					out[#out + 1] = {
						token = token,
						body = body,
						crash_id = crash_id,
						report = report,
						fatal = fatal,
						created_at = created_at,
					}
				end
			end
		end
	end
	return out, changed
end

local function load_raw_record(ns)
	local path = save_path(ns)
	if not path then
		return pending_memory[ns]
	end
	local ok, record = pcall(sys.load, path)
	if not ok or type(record) ~= "table" or type(record.items) ~= "table" then
		return pending_memory[ns]
	end
	return record
end

-- Normalize the stored resend-backpressure deadline: a number strictly in the
-- future and no further out than the one-day clamp survives; anything else —
-- expired, absurdly far ahead (wall-clock skew or a corrupt value), or not a
-- number — reads as none, so a bad stored deadline can never park crash
-- resend effectively forever.
local function normalize_pending_deadline(value, current_ms)
	if type(value) ~= "number" then
		return nil
	end
	if value <= current_ms or value > current_ms + max_pending_retry_after_ms then
		return nil
	end
	return value
end

-- forward declaration: read_pending_record writes back an adopted/pruned list.
local write_pending_list

local function read_pending_record(ns)
	local current_ms = now_ms()
	local raw = load_raw_record(ns)
	local raw_items = type(raw) == "table" and raw.items or nil
	local raw_deadline = type(raw) == "table" and raw.retry_after_until_ms or nil
	local items, changed = normalize_items(raw_items, current_ms)
	local deadline = normalize_pending_deadline(raw_deadline, current_ms)
	if deadline ~= raw_deadline and raw_deadline ~= nil then
		-- A spent or absurd stored deadline self-cleans with the rewrite.
		changed = true
	end
	if changed then
		-- Persist the adopted tokens / pruned TTL / cleaned deadline so a later
		-- read sees stable tokens (a freshly minted token on every read would
		-- defeat remove_pending_crash and cause an endless resend) and so the
		-- stale entries stay gone. A write failure here is non-fatal: the
		-- in-memory normalized view is still returned.
		write_pending_list(ns, items, deadline)
	end
	return items, deadline
end

function write_pending_list(ns, items, retry_after_until_ms)
	local record = { items = items, retry_after_until_ms = retry_after_until_ms }
	local path = save_path(ns)
	if not path then
		-- No durable backend: the in-memory record IS the store. Update it and
		-- report success.
		pending_memory[ns] = record
		return true
	end
	local ok, saved = pcall(sys.save, path, record)
	if not (ok and saved == true) then
		-- The durable write failed (e.g. disk quota). Do NOT update the in-memory
		-- shadow: leaving it unchanged keeps the persisted and in-memory views in
		-- agreement, so a later capture_previous() memory-fallback cannot resurface
		-- a crash this write would have settled, and the caller correctly sees a
		-- failed persist (no removable token).
		return false
	end
	pending_memory[ns] = record
	return true
end

-- Evict ONE entry from `stored` toward the caps, never touching the entry
-- carrying `protected_token` (the report being saved right now — the one the
-- write-ahead contract must not lose). Non-fatal reports go first, oldest
-- first. A FATAL report is evicted only to admit another FATAL one
-- (`protected_is_fatal`): a fatal crash is the most valuable diagnostics
-- signal, so a burst of handled (non-fatal) reports can never displace a
-- pending fatal — when only fatal entries remain and the newcomer is
-- non-fatal, this returns false and the CALLER drops the newcomer instead.
local function evict_one_pending(stored, protected_token, protected_is_fatal)
	for i = 1, #stored do
		if stored[i].token ~= protected_token and stored[i].fatal ~= true then
			table.remove(stored, i)
			return true
		end
	end
	if not protected_is_fatal then
		return false
	end
	for i = 1, #stored do
		if stored[i].token ~= protected_token then
			table.remove(stored, i)
			return true
		end
	end
	return false
end

local function pending_total_bytes(stored)
	local total = 0
	for i = 1, #stored do
		total = total + pending_entry_bytes(stored[i])
	end
	return total
end

-- Persist one crash report for retry on a later launch — write-ahead, BEFORE
-- its first send attempt. `entry` carries the exact encoded wire body
-- (`entry.body`, a JSON string), its `entry.crash_id`, and `entry.fatal`.
-- Returns a stable token addressing the stored entry on success (so the
-- caller can remove exactly this entry once its send is accepted or
-- terminally rejected), or nil when the entry is unusable or its body alone
-- exceeds the per-record byte cap (an oversized report is rejected up front,
-- without evicting anything). If `token` is supplied and an entry with that
-- token already exists, the stored body is refreshed in place (idempotent
-- re-persist) rather than appended a second time. Once the count or
-- total-bytes bound is exceeded, entries are evicted via evict_one_pending —
-- oldest NON-fatal first, the just-added report never — so the list stays
-- within max_pending_records / max_pending_total_bytes. Each entry is
-- stamped with a created-at time (from the SDK clock by default;
-- `created_at_ms` overrides it for tests) so the retention TTL can discard a
-- stale report on read.
function M.save_pending_crash(scope, entry, token, created_at_ms)
	if type(entry) ~= "table" or type(entry.body) ~= "string" or entry.body == "" then
		return nil
	end
	local stamp = type(created_at_ms) == "number" and created_at_ms or now_ms()
	if #entry.body > max_pending_record_bytes then
		return nil
	end
	local ns = pending_namespace(scope)
	-- Durability is this store's whole contract: without the Defold
	-- save-file API there is nothing durable to write to, so the save FAILS
	-- (no token) and the caller degrades to its explicitly non-durable
	-- in-memory retention — a process-local table must never be counted as
	-- write-ahead durability.
	if not save_path(ns) then
		return nil
	end
	local items, deadline = read_pending_record(ns)
	-- Defensive copy so a later caller mutation cannot reach the stored snapshot.
	local stored = {}
	for i = 1, #items do
		stored[i] = items[i]
	end
	local new_entry = {
		body = entry.body,
		crash_id = type(entry.crash_id) == "string" and entry.crash_id or nil,
		fatal = entry.fatal == true,
	}
	if token then
		-- Idempotent re-persist: replace an existing entry with this token in place.
		for i = 1, #stored do
			if stored[i].token == token then
				-- Refresh the body in place but PRESERVE the original created-at so a
				-- re-persist cannot reset the retention TTL and keep a report alive
				-- indefinitely.
				new_entry.token = token
				new_entry.created_at = type(stored[i].created_at) == "number" and stored[i].created_at or stamp
				stored[i] = new_entry
				if write_pending_list(ns, stored, deadline) then
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
	new_entry.token = token
	new_entry.created_at = stamp
	stored[#stored + 1] = new_entry
	-- Enforce the count AND total-bytes caps, never evicting the just-added
	-- report (its durability is the whole point of the write-ahead persist)
	-- and never a FATAL entry to admit a non-fatal one.
	while (#stored > max_pending_records or pending_total_bytes(stored) > max_pending_total_bytes) and
		evict_one_pending(stored, token, new_entry.fatal) do
	end
	if #stored > max_pending_records or pending_total_bytes(stored) > max_pending_total_bytes then
		-- Still over the caps with nothing evictable: the sidecar is full of
		-- FATAL reports and the newcomer is non-fatal. The newcomer — the
		-- lowest-value report present — is the one dropped; the durable file
		-- is left untouched.
		return nil
	end
	-- The byte budget above steers eviction but does not GUARANTEE the
	-- serialized list fits the durable store's per-file limit (Defold's
	-- sys.save caps a saved table at 512 KB): wrapper/serialization overhead
	-- is not counted. A failed write would lose THIS report (no removable
	-- token). So keep evicting — under the same policy — and retry the write
	-- until it succeeds or nothing evictable remains. This keeps a pending
	-- FATAL report always persistable and therefore removable, while a
	-- non-fatal newcomer never costs a fatal report its slot.
	while true do
		if write_pending_list(ns, stored, deadline) then
			return token
		end
		if not evict_one_pending(stored, token, new_entry.fatal) then
			-- Nothing more may be evicted (the backend is unavailable, or
			-- only fatal entries shield a non-fatal newcomer). Report a
			-- failed persist (no removable token).
			return nil
		end
	end
end

-- Remove a single persisted entry by its token (called once its send is
-- accepted or terminally rejected). A no-op when no entry carries that
-- token. `clear_retry_after` drops the stored backpressure deadline in the
-- same write — an ACCEPTED send proves the endpoint is taking traffic again,
-- so the window is over (a terminal reject preserves it: one rejected report
-- says nothing about rate limiting).
function M.remove_pending_crash(scope, token, clear_retry_after)
	if type(token) ~= "string" then
		return false
	end
	local ns = pending_namespace(scope)
	local items, deadline = read_pending_record(ns)
	local kept = {}
	for i = 1, #items do
		if items[i].token ~= token then
			kept[#kept + 1] = items[i]
		end
	end
	if clear_retry_after == true then
		deadline = nil
	end
	return write_pending_list(ns, kept, deadline)
end

-- Persist (or clear, with nil/non-positive seconds) the resend-backpressure
-- deadline stored with the pending record, recorded when the crash ingest
-- service answered a send with 429/Retry-After: a relaunch inside the window
-- keeps waiting it out instead of hammering a rate-limited endpoint. The
-- deadline is clamped to at most one day ahead. Best-effort: a failed write
-- only costs one early retry the server can re-throttle.
function M.set_pending_crash_retry_after(scope, seconds)
	local ns = pending_namespace(scope)
	local items, _ = read_pending_record(ns)
	local deadline = nil
	if type(seconds) == "number" and seconds > 0 then
		local clamped_ms = math.floor(seconds * 1000)
		if clamped_ms > max_pending_retry_after_ms then
			clamped_ms = max_pending_retry_after_ms
		end
		deadline = now_ms() + clamped_ms
	end
	return write_pending_list(ns, items, deadline)
end

-- Return the list of pending crash report payloads for this app (possibly
-- empty): the encoded body string for current entries, the prepared report
-- table for legacy ones.
function M.load_pending_crashes(scope)
	local ns = pending_namespace(scope)
	local items = read_pending_record(ns)
	local out = {}
	for i = 1, #items do
		out[i] = items[i].body or items[i].report
	end
	return out
end

-- Return the pending entries as { token, body|report, crash_id?, fatal }
-- records — oldest first — so a resend can address (remove / re-persist)
-- each entry individually, plus the stored resend-backpressure deadline (ms
-- epoch, or nil).
function M.load_pending_entries(scope)
	local ns = pending_namespace(scope)
	local items, deadline = read_pending_record(ns)
	local out = {}
	for i = 1, #items do
		out[i] = {
			token = items[i].token,
			body = items[i].body,
			report = items[i].report,
			crash_id = items[i].crash_id,
			fatal = items[i].fatal,
		}
	end
	return out, deadline
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

-- The record optionally carries a server-requested backpressure deadline
-- (`retry_after_until_ms`, wall-clock epoch ms recorded from a 429
-- Retry-After) so a relaunch inside the window can keep waiting it out.
local function sanitize_deadline(value)
	if type(value) == "number" and value > 0 then
		return value
	end
	return nil
end

local function write_spool(ns, events, retry_after_until_ms)
	local record = { events = events, retry_after_until_ms = sanitize_deadline(retry_after_until_ms) }
	local path = save_path(ns, "spool")
	if not path then
		-- No durable backend (plain Lua host): the in-memory record is the store.
		spool_memory[ns] = record
		return true
	end
	local ok, saved = pcall(sys.save, path, record)
	if not (ok and saved == true) then
		return false
	end
	spool_memory[ns] = record
	return true
end

-- Load the spooled envelopes for this app (possibly empty) plus the stored
-- backpressure deadline, if any. A failed or garbled sys.load discards the
-- record and starts clean; this never throws.
function M.load_spool(scope)
	local ns = spool_namespace(scope)
	local record = nil
	local path = save_path(ns, "spool")
	if path then
		local ok, loaded = pcall(sys.load, path)
		if ok and type(loaded) == "table" then
			record = loaded
		end
	end
	if record == nil then
		record = spool_memory[ns]
	end
	if type(record) ~= "table" then
		return {}, nil
	end
	return sanitize_spool_events(record.events), sanitize_deadline(record.retry_after_until_ms)
end

-- Replace the persisted spool with `events` (oldest first), enforcing the
-- count and approximate-bytes caps by evicting the OLDEST entries first.
-- `retry_after_until_ms` (optional) is stored with the record. Returns the
-- list that was actually persisted (possibly shorter than the input after
-- eviction), or nil when the durable write failed outright.
function M.save_spool(scope, events, max_events, max_bytes, retry_after_until_ms)
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
		if write_spool(ns, kept, retry_after_until_ms) then
			return kept
		end
		if #kept == 0 then
			return nil
		end
		table.remove(kept, 1)
	end
end

-- Drop the whole spool — envelopes and any stored deadline (consent revoked,
-- a persisted denial found at load, or the spool disabled by configuration).
function M.clear_spool(scope)
	return write_spool(spool_namespace(scope), {}, nil)
end

-- True when the spool has a durable backend on this runtime (the save-file
-- API is available). The in-memory fallback keeps in-process behavior working
-- on plain Lua hosts, but it does not survive the process — so callers that
-- promise durability (the shutdown/persist capture) must check this instead
-- of treating a fallback write as data safe on disk.
function M.spool_is_durable(scope)
	return save_path(spool_namespace(scope), "spool") ~= nil
end

-- Clears the in-memory fallback records only; intended for tests.
function M.reset()
	memory_records = {}
	pending_memory = {}
	spool_memory = {}
end

return M
