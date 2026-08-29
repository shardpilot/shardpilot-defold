-- Durable persistence for the identity record (anonymous ID + consent state),
-- the consent denial marker (the write-ahead witness for a denial whose
-- identity write failed), the pending-crash sidecar, the crash-reporting
-- settings record (the persisted opt-out), the offline event spool, and the
-- consent-receipt outbox.
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

-- Load the identity record, or nil when absent/unreadable (the in-process
-- shadow answers when the durable read fails). An identity record that cannot
-- be read resolves to a consent-first "unknown" in the client, which
-- transmits nothing and purges the offline spool — so a swallowed read
-- failure here still fails closed end to end.
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

-- ── consent denial marker ────────────────────────────────────────────────────
--
-- A small write-ahead record for DENIED consent decisions, paired 1:1 with
-- the identity record's scope. set_consent writes it BEFORE the identity
-- write for every denied-state decision and retires it only once the identity
-- record durably holds the denial (or a later successfully persisted decision
-- supersedes it): should the identity write fail and the process exit, the
-- marker is the durable witness that stops the next launch from restoring the
-- stale pre-denial record — a grant re-opened against an explicit revocation.
-- Like the crash-settings record, the load DISTINGUISHES an absent marker
-- from a failed read: an unreadable marker may witness a denial, so the
-- client fails closed over a granted restore instead of ignoring it.

local consent_denial_memory = {}

-- Load the consent denial marker. Returns (record, err):
--   * a table when a marker is stored (an empty table — Defold's sys.load
--     result for a file that does not exist, and the retired form written by
--     clear_consent_denial_marker — reads as "no marker");
--   * nil, nil when no marker exists at all (fresh install, or a plain-Lua
--     host whose in-memory fallback holds nothing);
--   * nil, "consent_marker_read_failed" when the durable read itself failed
--     (sys.load threw, or produced a non-table) and no in-process shadow —
--     written by a successful save this session — can answer instead.
function M.load_consent_denial_marker(scope)
	local ns = namespace(scope)
	local path = save_path(ns, "consent-denial")
	if not path then
		return clone(consent_denial_memory[ns]), nil
	end
	local ok, record = pcall(sys.load, path)
	if ok and type(record) == "table" then
		return record, nil
	end
	local fallback = clone(consent_denial_memory[ns])
	if fallback ~= nil then
		return fallback, nil
	end
	if ok and record == nil then
		-- The backend answered cleanly with nothing: no marker exists.
		return nil, nil
	end
	return nil, "consent_marker_read_failed"
end

-- Replace the consent denial marker. Returns true when the record was durably
-- stored (or stored in the in-memory fallback on hosts without the save-file
-- API, which then lasts only for the process lifetime).
function M.save_consent_denial_marker(scope, record)
	if type(record) ~= "table" then
		return false
	end
	local ns = namespace(scope)
	local path = save_path(ns, "consent-denial")
	if not path then
		-- No durable backend: the in-memory record IS the store.
		consent_denial_memory[ns] = clone(record)
		return true
	end
	local ok, saved = pcall(sys.save, path, record)
	if not (ok and saved == true) then
		-- Mirror the crash-settings rule: never seed the in-process shadow
		-- from a failed durable write — the shadow answers a failed READ, so
		-- it must only ever reflect a marker that actually persisted.
		return false
	end
	consent_denial_memory[ns] = clone(record)
	return true
end

-- Retire the marker (the identity record durably holds the denial, or a later
-- successfully persisted decision superseded it). An empty record reads as
-- "no marker".
function M.clear_consent_denial_marker(scope)
	return M.save_consent_denial_marker(scope, {})
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

-- The per-app base namespace for the crash-plane records (the pending-crash
-- sidecar and the crash-reporting settings), keyed per app so two games on the
-- same device never share a queue or an opt-out decision, even when no
-- workspace scope is configured (the crash client carries only an app id).
-- Fall back to the shared namespace only when no app id is available at all.
local function crash_scope_base(scope)
	local app = sanitize(type(scope) == "table" and scope.app_id or nil)
	local base = namespace(scope)
	if app and base == "shardpilot" then
		base = "shardpilot." .. app
	end
	-- The sanitized slug above collapses any disallowed character to "_", so two raw
	-- app ids that differ only in such characters ("com.game" vs "com_game") would map
	-- to the SAME crash namespace and let one app resend/remove another app's
	-- report (or flip its opt-out). Append a short hash of the RAW (un-sanitized)
	-- scope so those two ids get
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
	return base
end

local function pending_namespace(scope)
	return crash_scope_base(scope) .. ".pending-crashes"
end

-- The fixed byte charge for a non-string scalar (number, boolean) and for a
-- non-string table key: sys.save serializes them as tagged binary values
-- (numbers as doubles plus framing), so charging a conservative fixed
-- estimate keeps the check honest for numeric/boolean-heavy payloads — an
-- estimator that counted only strings would declare such a record fit,
-- and the sys-layer write would then fail on every retry with nothing to
-- evict. Overshoot is the safe direction: evicting early costs a refetch,
-- undershooting wedges the durable sync permanently.
local non_string_scalar_bytes = 16

local function approx_record_bytes(record)
	-- A cheap upper-bound size estimate without pulling in a JSON encoder:
	-- count the bytes of every string scalar plus a fixed conservative
	-- charge per non-string scalar and non-string key in the record tree.
	local total = 0
	local function walk(value, depth)
		if depth > 32 then
			return
		end
		local value_type = type(value)
		if value_type == "string" then
			total = total + #value
		elseif value_type == "number" or value_type == "boolean" then
			total = total + non_string_scalar_bytes
		elseif value_type == "table" then
			for key, child in pairs(value) do
				if type(key) == "string" then
					total = total + #key
				else
					total = total + non_string_scalar_bytes
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
	-- Read (and thereby ADOPT any legacy, un-stamped entries) BEFORE taking
	-- the new report's timestamp: adoption stamps legacy entries with the
	-- read-time clock, and the resend pass orders by created_at — a new
	-- report stamped earlier than the older backlog it queues behind would
	-- jump the line (and a 429 on it would strand the true oldest).
	local items, deadline = read_pending_record(ns)
	local stamp = type(created_at_ms) == "number" and created_at_ms or now_ms()
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
	local replaced = false
	if token then
		-- Idempotent re-persist: replace an existing entry with this token in
		-- place. The refresh then runs through the SAME caps enforcement and
		-- evict-and-retry write as an append — a legacy sidecar written
		-- before the total-byte budget existed can already sit above it, and
		-- adopting an entry must shrink toward the bound, not skip it.
		for i = 1, #stored do
			if stored[i].token == token then
				-- Refresh the body in place but PRESERVE the original created-at so a
				-- re-persist cannot reset the retention TTL and keep a report alive
				-- indefinitely.
				new_entry.token = token
				new_entry.created_at = type(stored[i].created_at) == "number" and stored[i].created_at or stamp
				stored[i] = new_entry
				replaced = true
				break
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
	if not replaced then
		new_entry.token = token
		new_entry.created_at = stamp
		stored[#stored + 1] = new_entry
	end
	-- Enforce the count AND total-bytes caps, never evicting the just-added
	-- (or just-refreshed) report — its durability is the whole point of the
	-- write-ahead persist — and never a FATAL entry to admit a non-fatal one.
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

-- Return the pending entries as
-- { token, body|report, crash_id?, fatal, created_at } records — oldest
-- first — so a resend can address (remove / re-persist) each entry
-- individually and merge them by age with any session-only retained
-- reports, plus the stored resend-backpressure deadline (ms epoch, or nil).
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
			created_at = items[i].created_at,
		}
	end
	return out, deadline
end

-- ── crash-reporting settings ─────────────────────────────────────────────────
--
-- One small per-app record holding the crash-reporting opt-out decision
-- (`crash_enabled`). Crash reporting is ON by default (no record needed); an
-- explicit `set_enabled(false)` persists `crash_enabled = false` here so the
-- opt-out is honored on every later launch. The load DISTINGUISHES an absent
-- record from a failed read: absent (a fresh install) means the default
-- applies, while a read failure means the player may have opted out and the
-- crash client must fail CLOSED — so unlike the other loaders, this one
-- reports the failure instead of swallowing it into "absent".

local crash_settings_memory = {}

local function crash_settings_namespace(scope)
	return crash_scope_base(scope) .. ".crash-settings"
end

-- Load the crash-reporting settings record. Returns (record, err):
--   * a table when a record is stored (an empty table — Defold's sys.load
--     result for a file that does not exist — reads as "no decision", so the
--     caller's default applies);
--   * nil, nil when no record exists at all (fresh install, or a plain-Lua
--     host whose in-memory fallback holds nothing);
--   * nil, "crash_settings_read_failed" when the durable read itself failed
--     (sys.load threw, or produced a non-table) and no in-process shadow —
--     written by a successful save this session — can answer instead.
function M.load_crash_settings(scope)
	local ns = crash_settings_namespace(scope)
	local path = save_path(ns)
	if not path then
		return clone(crash_settings_memory[ns]), nil
	end
	local ok, record = pcall(sys.load, path)
	if ok and type(record) == "table" then
		return record, nil
	end
	local fallback = clone(crash_settings_memory[ns])
	if fallback ~= nil then
		return fallback, nil
	end
	if ok and record == nil then
		-- The backend answered cleanly with nothing: no record exists.
		return nil, nil
	end
	return nil, "crash_settings_read_failed"
end

-- Replace the crash-reporting settings record. Returns true when the record
-- was durably stored (or stored in the in-memory fallback on hosts without
-- the save-file API, which then lasts only for the process lifetime).
function M.save_crash_settings(scope, record)
	if type(record) ~= "table" then
		return false
	end
	local ns = crash_settings_namespace(scope)
	local path = save_path(ns)
	if not path then
		-- No durable backend: the in-memory record IS the store.
		crash_settings_memory[ns] = clone(record)
		return true
	end
	local ok, saved = pcall(sys.save, path, record)
	if not (ok and saved == true) then
		-- The durable write failed. Do NOT seed the in-process shadow: the
		-- shadow answers load_crash_settings when the durable READ fails, so
		-- it must only ever reflect a decision that actually persisted —
		-- otherwise a failed set_enabled(true) could reopen a fail-closed
		-- client at the next same-process init without any readable decision
		-- on disk.
		return false
	end
	crash_settings_memory[ns] = clone(record)
	return true
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
-- Wire names an older release of this SDK persisted, and what a load must do
-- with them. The spool re-sends stored envelopes VERBATIM, so an upgrade that
-- only fixes the enqueue path leaves the old backlog on the wire under names
-- ingest no longer accepts -- and an unregistered name is refused for the WHOLE
-- BATCH, which takes the valid events stored beside it down too. The load is
-- the one place every persisted envelope passes through, so it is where the
-- backlog is made sendable.
--
-- RENAMED: the event still exists under a registered name, so the envelope is
-- rewritten and kept.
local spool_renamed_events = {
	["session_end"] = "app.session_ended",
}
-- REMOVED: the helper is gone and no registered name accepts these, so the
-- entry is DROPPED. Keeping it would poison every batch it lands in for as
-- long as the backlog survives, and there is nothing to rewrite it to.
local spool_removed_events = {
	["tutorial_start"] = true,
	["tutorial_step_complete"] = true,
	["tutorial_complete"] = true,
}

local function sanitize_spool_events(events)
	local out = {}
	if type(events) ~= "table" then
		return out
	end
	for i = 1, #events do
		local entry = events[i]
		if type(entry) == "table" and type(entry.event_id) == "string" and entry.event_id ~= "" then
			local name = entry.event_name
			if type(name) == "string" and spool_removed_events[name] then
				-- dropped: no registered name to carry it
			else
				if type(name) == "string" and spool_renamed_events[name] then
					entry.event_name = spool_renamed_events[name]
				end
				out[#out + 1] = entry
			end
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
		elseif not ok then
			-- The STORE errored on the read: the spool's DURABLE content is
			-- UNKNOWN, not proven empty — and the in-process shadow must
			-- NOT stand in for it (the same rule as the experiments
			-- record): the shadow is this runtime's last successful write,
			-- while the file may hold facts it never saw, so a
			-- shadow-backed answer would let an armed condemnation marker
			-- retire off a process-local snapshot. The collapse to an
			-- empty list stands for flow (nothing can be re-sent from an
			-- unreadable file); callers that must prove spool CLEANLINESS
			-- — the condemnation-marker retire rule — read the third value
			-- and treat the launch as unproven instead of clean.
			return {}, nil, "unreadable"
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

-- The base of the byte estimate: what an empty record costs before any
-- envelope is counted. Named because the running total in a spool state must
-- start from exactly the same place the one-shot estimate did, or the two
-- paths would disagree about when the budget is reached.
local spool_estimate_base = 2

-- A spool STATE is the persisted list plus what an append needs to know about
-- it without re-reading it: the per-entry size estimates and their running
-- total.
--
-- ⚠ THIS APPLIES NO CAPS, deliberately. The caps belong to admission, which
-- knows the caller's configured limits; a state is just "what is here". An
-- earlier version of this idea in the Godot SDK defaulted the cap here
-- instead, and a backlog larger than the default was silently trimmed on
-- load with no eviction recorded -- the state disagreed with the disk about
-- what existed.
function M.spool_state_for(events)
	local state = { events = {}, sizes = {}, total = spool_estimate_base, ids = {} }
	M.spool_admit_all(state, events)
	return state
end

-- Add entries to a state with NO cap applied, refusing an id it already
-- holds.
--
-- ⚠ ONE ENTRY PER ID IS AN INVARIANT NOW, not an accident. The loader
-- deliberately salvages every table-shaped entry carrying a valid event_id
-- rather than deduplicating, so a garbled record can hold the same id twice
-- -- and a caller keeping a boolean id index cannot then evict one copy
-- without wrongly declaring the id gone while another survives. The record
-- is normalised here instead, which is the same repair the loader already
-- performs on shape.
function M.spool_admit_all(state, events)
	local kept = sanitize_spool_events(events)
	for i = 1, #kept do
		local entry = kept[i]
		if not state.ids[entry.event_id] then
			local size = approx_envelope_bytes(entry)
			state.events[#state.events + 1] = entry
			state.sizes[#state.sizes + 1] = size
			state.ids[entry.event_id] = true
			state.total = state.total + size
		end
	end
end

-- Admit `fresh` into `state`, evicting the OLDEST entries until both caps
-- hold. Mutates `state` and returns the evicted entries, oldest first.
--
-- The entries rather than a count, because the caller keeps an id index over
-- the record: given only a number it would have to rebuild that index over
-- the whole record to find out which ids left -- and at a full spool every
-- append evicts, so the O(#record) pass this removes would come straight
-- back in the caller.
--
-- ⚠ THE MEASURING is O(#fresh): appending one envelope used to re-estimate
-- every envelope already spooled -- 437.6 of them per append at the default
-- caps, measured in docs/SPOOL_OVERFLOW_LATENCY_BOUND.md -- and entries now
-- carry their estimate from the moment they are admitted, so nothing is
-- measured twice. That is the cost this exists to remove.
--
-- ⚠ IT IS NOT O(1) OVERALL, AND SAYING SO WOULD BE FALSE. table.remove(t, 1)
-- shifts every surviving element, so an eviction costs O(#state) pointer
-- moves in two arrays. That term stays, deliberately: the write it
-- accompanies hands the WHOLE table to sys.save, which serialises every
-- surviving envelope on the same call -- the platform has no append (see
-- docs/SPOOL_OVERFLOW_LATENCY_BOUND.md). Replacing the shift with a head
-- offset would still have to materialise a contiguous array for that write,
-- trading two pointer shifts for one copy while the serialisation it sits
-- inside is untouched.
--
-- There is ONE implementation of the caps and both paths use it. A second
-- copy for the append path would be a second place for the two to drift, and
-- the eviction rule is exactly what a reader and a writer must agree on.
function M.spool_admit(state, fresh, max_events, max_bytes)
	local limit_events = (type(max_events) == "number" and max_events > 0) and max_events or 500
	local limit_bytes = (type(max_bytes) == "number" and max_bytes > 0) and max_bytes or 262144
	if limit_bytes > max_spool_file_bytes then
		limit_bytes = max_spool_file_bytes
	end
	local admitted = sanitize_spool_events(fresh)
	-- An entry the count cap will certainly evict is never estimated. Only
	-- the leading (#admitted - limit_events) of THIS batch qualify: anything
	-- after that may survive, depending on how much of `state` the cap
	-- displaces. The one-shot path applied its count cap before estimating
	-- and this keeps that property -- without it, saving a 10k-entry list
	-- would estimate 10k envelopes to persist 500.
	--
	-- ⚠ AND THEY ARE STILL EVICTIONS. Skipping the estimate must not skip
	-- the accounting: the first version of this dropped them silently, and
	-- the existing FIFO fixture caught it as spool_evicted 0 where 1 was
	-- owed. Not estimating an entry is a cost decision; not reporting it is
	-- a lie about what was persisted.
	local skipped = {}
	local skip = #admitted - limit_events
	if skip > 0 then
		local trimmed = {}
		for i = 1, skip do
			skipped[#skipped + 1] = admitted[i]
		end
		for i = skip + 1, #admitted do
			trimmed[#trimmed + 1] = admitted[i]
		end
		admitted = trimmed
	end
	M.spool_admit_all(state, admitted)
	-- Evict oldest-first until both caps hold. table.remove(t, 1) is O(#t),
	-- so the shift is proportional to what SURVIVES rather than to what is
	-- evicted -- fine for the one-or-two evictions a steady-state append
	-- causes, and the whole-record case only arises on the first admission
	-- after a load, which pays it once.
	local evicted = {}
	while #state.events > 0
		and (#state.events > limit_events or state.total > limit_bytes) do
		state.total = state.total - state.sizes[1]
		local gone = table.remove(state.events, 1)
		table.remove(state.sizes, 1)
		state.ids[gone.event_id] = nil
		evicted[#evicted + 1] = gone
	end
	-- Appended rather than interleaved. A batch big enough to be skipped is
	-- one that fills the count cap by itself, so every prior entry is
	-- evicted too and this IS the FIFO order; only a byte cap biting into
	-- the same batch could reorder the tail, and nothing consumes the order
	-- -- the caller uses the set (which ids left) and the count.
	for i = 1, #skipped do
		evicted[#evicted + 1] = skipped[i]
	end
	return evicted
end

-- Persist `state` (already admitted) plus the deadline. Returns the list that
-- was actually persisted, or nil when the durable write failed outright.
--
-- The estimate ignores serialization overhead, so a near-budget list can still
-- overflow the save-file cap and fail the write. Evict the oldest entries one
-- at a time and retry until the write succeeds or nothing is left to save
-- (then the backend itself is unavailable). ⚠ THE STATE IS SHRUNK WITH THE
-- LIST: a state describing entries the store rejected would send the next
-- append's admission decision off a record that does not exist.
-- Returns the persisted list plus the entries the retry loop shed (usually
-- none), or nil plus what it shed. The shed entries are returned for the same
-- reason admission returns its evictions: a caller indexing the record has to
-- know which ids stopped existing.
function M.write_spool_state(scope, state, retry_after_until_ms)
	local ns = spool_namespace(scope)
	if write_spool(ns, state.events, retry_after_until_ms) then
		return state.events, {}
	end
	-- ⚠ THE RETRIES SHRINK A COPY, NOT THE CALLER'S STATE. A FAILED WRITE
	-- LEAVES THE FILE AT ITS PREVIOUS CONTENTS -- so if nothing lands at
	-- all, the state must still describe what is on disk. Shrinking it in
	-- place emptied it while the file still held the backlog, and the next
	-- append that succeeded then wrote mirror-plus-new over the top,
	-- silently discarding everything previously persisted.
	local events, sizes = {}, {}
	local total = state.total
	for i = 1, #state.events do
		events[i] = state.events[i]
		sizes[i] = state.sizes[i]
	end
	local shed = {}
	while #events > 0 do
		total = total - sizes[1]
		shed[#shed + 1] = table.remove(events, 1)
		table.remove(sizes, 1)
		if write_spool(ns, events, retry_after_until_ms) then
			state.events, state.sizes, state.total = events, sizes, total
			for i = 1, #shed do
				state.ids[shed[i].event_id] = nil
			end
			return events, shed
		end
	end
	return nil, shed
end

-- Undo an admission that no write survived. Cheap by construction: the batch
-- went in at the TAIL and the caps evicted from the FRONT, so both ends are
-- known without touching the middle.
--
-- Entries that arrived with THIS batch are not restored -- they were never on
-- disk, and the caller reports them as uncaptured.
function M.spool_restore(state, fresh, evicted)
	local from_batch = {}
	for i = 1, #fresh do
		local entry = fresh[i]
		if type(entry) == "table" and type(entry.event_id) == "string" then
			from_batch[entry.event_id] = true
		end
	end
	while #state.events > 0 do
		local last = state.events[#state.events]
		if not (type(last) == "table" and from_batch[last.event_id]) then
			break
		end
		state.total = state.total - state.sizes[#state.sizes]
		state.ids[last.event_id] = nil
		table.remove(state.events)
		table.remove(state.sizes)
	end
	for i = #evicted, 1, -1 do
		local entry = evicted[i]
		if not from_batch[entry.event_id] then
			local size = approx_envelope_bytes(entry)
			table.insert(state.events, 1, entry)
			table.insert(state.sizes, 1, size)
			state.ids[entry.event_id] = true
			state.total = state.total + size
		end
	end
end

-- Replace the persisted spool with `events` (oldest first), enforcing the
-- count and approximate-bytes caps by evicting the OLDEST entries first.
-- `retry_after_until_ms` (optional) is stored with the record. Returns the
-- list that was actually persisted (possibly shorter than the input after
-- eviction), or nil when the durable write failed outright.
--
-- This is the whole-record path, expressed through the same admission the
-- append path uses: an empty state, everything admitted at once.
function M.save_spool(scope, events, max_events, max_bytes, retry_after_until_ms)
	local state = { events = {}, sizes = {}, total = spool_estimate_base, ids = {} }
	M.spool_admit(state, events, max_events, max_bytes)
	return M.write_spool_state(scope, state, retry_after_until_ms)
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

-- ── consent-receipt outbox ───────────────────────────────────────────────────
--
-- Durable retention for consent receipts — the exact `POST /v1/consent`
-- payload built for every explicit set_consent decision — until the server
-- acknowledges them, so a receipt survives process death and offline play.
-- CONSENT-PLANE ONLY: the record never carries event envelopes or any other
-- analytics payload, and — unlike the offline event spool — it is never
-- consent-purged: a receipt documents the decision itself, so it is retained
-- and delivered under denied/unknown states alike. The list is bounded by a
-- fixed entry count (receipts are small, fixed-shape, and rare — one per
-- explicit player decision); overflow eviction is DENIAL-PREFERRING: the
-- oldest PURE-GRANT receipt is evicted first, and a denial-carrying receipt
-- is evicted (oldest first) only when everything over the cap carries
-- denials. A recorded denial is the compliance-critical write — the server
-- honors a stored denial unconditionally, while a LOST denial fail-opens
-- the actor under its fail-open-on-missing rule — whereas a lost grant only
-- delays pipeline opening and is re-writable. There is deliberately NO TTL:
-- an undelivered receipt is retried until acknowledged.

local consent_outbox_memory = {}

local max_consent_outbox_entries = 32
-- Exported so the client's grant-append fail-closed gate (set_consent
-- refusing `consent_outbox_full` on a denial-full outbox) reasons about
-- the SAME cap this store enforces, from one definition.
M.max_consent_outbox_entries = max_consent_outbox_entries

-- Shared byte budget for host-supplied identifiers, exported so the client's
-- acceptance gate (valid_identity in client.lua) and this sanitizer enforce
-- the SAME bound from one definition. Receipts persist identifiers verbatim
-- and this record has no other byte budget, so the clamp is what keeps the
-- 32-entry worst case far under the engine's save-record cap. Enforcing it
-- here as well covers records written BEFORE the clamp existed: a legacy
-- receipt carrying a near-cap identifier reloads verbatim, and the next
-- decision's rewrite (old entries + new receipt) could exceed the save cap
-- again — a write this store deliberately never resolves by eviction — and
-- re-wedge shutdown() in consent_pending. Such an entry is dropped at
-- sanitize like any other malformed one: it can never be durably rewritten
-- alongside new decisions, and one bad record on disk must never block the
-- deliverable rest.
M.max_identifier_bytes = 512

local function valid_receipt_field(value)
	return type(value) == "string" and value ~= ""
end

-- Identifier fields (actor_identifier, anonymous_id) additionally honor the
-- shared byte budget; the other receipt fields are SDK-generated or config
-- constants and keep the plain non-empty-string rule.
local function valid_receipt_identifier(value)
	return valid_receipt_field(value) and #value <= M.max_identifier_bytes
end

-- The ADR-0222 actor-identity classes a receipt may carry. The SDK itself
-- produces only these two — never "user_unverified" (a self-asserted Mode A
-- user id is a class any caller could spoof, and the ingest service rejects
-- SDK writes carrying it) — and the sanitizer holds loaded records to the
-- same closed set: an entry with any other kind is dropped fail-safe like
-- any malformed field, while a LEGACY entry with no kind at all (written
-- before kind existed) is kept and backfilled "anon" — the pre-kind ingress
-- bound every client write to the caller's anon scope, so anon is the class
-- those receipts were recorded under.
local valid_receipt_kinds = { anon = true, user_verified = true }

-- Keep only entries that are complete, well-formed receipts, copied down to
-- the known fields — the wire fields plus one piece of retention metadata,
-- `anonymous_id` (the decision-time anon snapshot the client's Mode B
-- identity check reads at load; the client strips it from the wire payload).
-- Anything else — a corrupt file, a truncated entry, a garbled field — is
-- dropped rather than sent or crashed on: one bad record on disk must never
-- block (or ride along with) the deliverable rest.
-- Returns the salvageable entries AND how many were refused. The count is
-- the caller's only way to tell a trail that was fully understood from one
-- that lost something: every rejection here is a SHAPE failure, so a nonzero
-- count means the file held a receipt this build cannot read -- and a receipt
-- it cannot read may be a denial. The could-never-send drop is deliberately
-- NOT here (it lives in the client, on a receipt this store understood
-- perfectly), so the count never conflates policy with corruption.
local function sanitize_outbox_entries(entries)
	local out = {}
	if entries == nil then
		-- No receipts key at all: what an absent file loads as. Honestly
		-- empty, nothing lost.
		return out, 0
	end
	if type(entries) ~= "table" then
		-- Present and not a list: at least one receipt is unaccounted for.
		return out, 1
	end
	local dropped = 0
	-- `#entries` is the ARRAY PREFIX ONLY, and the loop below never leaves it.
	-- A table with a HOLE ({[1]=a, [3]=b}) or with non-array keys hides
	-- receipts behind that prefix: they would never be visited, never counted,
	-- and the loader would report a fully understood trail while a denial sat
	-- unread. Walk every key first and charge anything outside the prefix.
	local prefix = #entries
	for key in pairs(entries) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > prefix then
			dropped = dropped + 1
		end
	end
	for i = 1, prefix do
		local entry = entries[i]
		if type(entry) == "table"
			and valid_receipt_field(entry.idempotency_key)
			and valid_receipt_field(entry.workspace_id)
			and valid_receipt_field(entry.app_id)
			and valid_receipt_field(entry.environment_id)
			and valid_receipt_identifier(entry.actor_identifier)
			and (entry.kind == nil or valid_receipt_kinds[entry.kind] == true)
			and valid_receipt_field(entry.decided_at)
			and type(entry.categories) == "table"
			and type(entry.categories.analytics) == "boolean"
			and (entry.reason == nil or valid_receipt_field(entry.reason))
			and (entry.anonymous_id == nil or valid_receipt_identifier(entry.anonymous_id)) then
			out[#out + 1] = {
				idempotency_key = entry.idempotency_key,
				workspace_id = entry.workspace_id,
				app_id = entry.app_id,
				environment_id = entry.environment_id,
				actor_identifier = entry.actor_identifier,
				kind = entry.kind or "anon",
				decided_at = entry.decided_at,
				-- Retention-only tie-break metadata (never on the wire):
				-- legacy or malformed values backfill 0, preserving the
				-- pre-seq strict-stamp ordering for legacy entries rather
				-- than dropping a receipt over metadata.
				decision_seq = (type(entry.decision_seq) == "number"
					and entry.decision_seq >= 0)
					and math.floor(entry.decision_seq) or 0,
				categories = { analytics = entry.categories.analytics },
				reason = entry.reason,
				anonymous_id = entry.anonymous_id,
			}
		else
			dropped = dropped + 1
		end
	end
	return out, dropped
end

-- A receipt counts as a pure grant for eviction purposes when its category
-- map carries NO false value — any false makes it denial-carrying and
-- eviction-protected (under the default legitimate-interest posture the map
-- is exactly `analytics: true/false`; the loop keeps the rule correct
-- should the snapshot ever grow more categories).
local function receipt_is_pure_grant(receipt)
	for _, value in pairs(receipt.categories) do
		if value ~= true then
			return false
		end
	end
	return true
end
-- Exported alongside the cap above: the client's grant-append gate must
-- predict this store's eviction choices with the SAME predicate the
-- eviction loop applies.
M.receipt_is_pure_grant = receipt_is_pure_grant

local function write_consent_outbox(ns, receipts)
	local record = { receipts = receipts }
	local path = save_path(ns, "consent-outbox")
	if not path then
		-- No durable backend (plain Lua host): the in-memory record is the store.
		consent_outbox_memory[ns] = record
		return true
	end
	local ok, saved = pcall(sys.save, path, record)
	if not (ok and saved == true) then
		return false
	end
	consent_outbox_memory[ns] = record
	return true
end

-- Load the retained consent receipts for this app (oldest first, possibly
-- empty). The outbox shares the identity record's per-app namespace scheme
-- (plus the raw-scope hash, like the spool and the pending-crash sidecar).
-- Never throws into game code.
--
-- THREE-VALUED, like load_consent_denial_marker and for the same reason.
-- This outbox is an accepted DENIAL WITNESS -- a retained receipt is proof
-- of a refusal, and shutdown() will finalize on it alone when the record and
-- the marker both failed to write. For a witness, "empty" is not the absence
-- of an answer, it is the CLAIM that nothing was ever refused, and a read
-- that failed cannot support that claim. Returns:
--   * entries, nil -- understood. An empty list here is honestly empty.
--   * entries, "consent_outbox_read_failed" -- the trail exists and could
--     not be fully understood: the durable read threw or produced a
--     non-table with no in-process shadow to answer instead, OR the file
--     parsed but held a receipt this build refused. The entries returned are
--     the salvageable subset and are still usable; what the caller must not
--     do is read the list as complete.
--
-- The old contract collapsed both into a bare empty list, so a first launch
-- and a destroyed denial trail were the same value. The cache/spool loaders
-- deliberately KEEP that degrade-to-empty behaviour: losing a cached event
-- costs an event, while losing a denial costs a refusal the user made.
-- ── the outbox's state is RESOLVED ONCE, at load ────────────────────────────
--
-- The loader used to re-derive "can this trail be trusted" on every question,
-- from a fresh read each time. A transient failure could therefore flip the
-- answer mid-session: the same file read twice gave two verdicts, and every
-- rule built on the second one silently disagreed with the first.
--
-- So the state is established ONCE per client session and everything else is a
-- thin read of it. `begin_consent_outbox_session` is what starts a session;
-- resolving once is scoped to a CLIENT, not to a process, because a module
-- cache outlives the client and a second `sdk.new()` in one process would
-- otherwise inherit the first one's verdict until the engine restarts.

local CONSENT_OUTBOX_KEY = "consent-outbox"
local outbox_resolution = {}

-- FOUR STATES, because a store can fail in two ways that mean different things
-- and one value cannot carry both:
--
--   "absent"   -- the store replied, and there is nothing here.
--   "readable" -- the store replied with a record this build understands.
--   "unusable" -- the store REPLIED, and what came back is not a record.
--   "silent"   -- the store did not reply at all: the read threw.
--
-- The last two used to share one value with the discriminator returned
-- alongside, for every caller to remember to read. They do not mean the same
-- thing to an operator -- one says look at the file, the other says look at the
-- device -- so they are not one value.
--
-- Having no durable backend at all is NOT a fifth state: that is a different
-- question and `consent_outbox_is_durable` already answers it.
local function read_outbox_key(ns, key)
	local path = save_path(ns, key)
	if not path then
		return "absent", nil
	end
	local ok, record = pcall(sys.load, path)
	if not ok then
		return "silent", nil
	end
	if record == nil then
		return "absent", nil
	end
	if type(record) ~= "table" then
		return "unusable", nil
	end
	if next(record) == nil then
		-- An absent file loads as an empty table on this backend.
		return "absent", nil
	end
	return "readable", record
end

-- Copies, never the list itself. Handing out `r.receipts` made the caller's
-- mirror and the resolution the SAME table, so every mirror mutation silently
-- edited the resolution and the two could not disagree even where they should.
-- Entries are shared deliberately: `sanitize_outbox_entries` builds a fresh
-- table per receipt and nothing mutates one in place.
local function copy_outbox_entries(entries)
	local out = {}
	for i = 1, #entries do
		out[i] = entries[i]
	end
	return out
end

-- Everything below is DERIVED from the observations the resolution stores,
-- computed on demand rather than stamped at resolve time. A stamped conclusion
-- goes stale at every later site that changes one of its inputs, and the sites
-- that change an input are exactly the sites that perform a READ.
local function outbox_unaccounted(r)
	if r.shadow_answered then
		-- This process wrote this trail itself, so nothing about it is
		-- unaccounted however badly the read path is behaving.
		return false
	end
	return r.state == "unusable" or r.state == "silent" or r.record_damaged
end

-- What an operator should go and look at: the FILE, or the DEVICE. "store" only
-- when the store never replied; "record" whenever it DID reply and the reply
-- cannot be used. nil when nothing is unaccounted.
local function outbox_cause(r)
	if not outbox_unaccounted(r) then
		return nil
	end
	if r.state == "silent" then
		return "store"
	end
	return "record"
end

function M.resolve_consent_outbox(scope)
	local ns = spool_namespace(scope)
	local state, record = read_outbox_key(ns, CONSENT_OUTBOX_KEY)

	local shadow_answered = false
	if record == nil and type(consent_outbox_memory[ns]) == "table" then
		-- A shadow written by a successful save THIS session answers for a read
		-- that failed: the process knows what it wrote.
		shadow_answered = true
		record = consent_outbox_memory[ns]
	end

	local receipts, dropped = sanitize_outbox_entries(
		type(record) == "table" and record.receipts or nil
	)
	-- A NONEMPTY RECORD WITH NO receipts KEY IS NOT AN EMPTY TRAIL. An absent
	-- file is what loads as empty, which is why a missing key normally means
	-- honestly empty; a record carrying something else is one this build cannot
	-- make sense of, and what it held may have been a denial.
	local shape_foreign = type(record) == "table"
		and record.receipts == nil
		and next(record) ~= nil

	local resolution = {
		-- OBSERVATIONS. Each changes only where a read happens.
		state = state,
		record_damaged = dropped > 0 or shape_foreign,
		shadow_answered = shadow_answered,
		receipts = receipts,
	}
	outbox_resolution[ns] = resolution
	return resolution
end

local function resolution_for(ns, scope)
	return outbox_resolution[ns] or M.resolve_consent_outbox(scope)
end

-- A SESSION, NOT A PROCESS. Called by the client at init, before the load.
function M.begin_consent_outbox_session(scope)
	local ns = spool_namespace(scope)
	local r = outbox_resolution[ns]
	if r ~= nil and r.owed_reason == "write_failed" then
		-- A RESOLUTION HOLDING UN-PERSISTED WORK IS NOT A CACHE, so a new
		-- session may not replace it with whatever disk happens to say. Two
		-- clients for one app scope share this resolution: discarding it here
		-- re-read the STALE durable record, and the first client's retry then
		-- flushed that replacement and cleared its debt -- dropping a consent
		-- receipt accepted in memory that never reached disk.
		--
		-- Re-resolving is what a fresh session is FOR: a transient READ failure
		-- must not fail closed until the engine restarts. That reason is about
		-- a resolution disk could answer better than, and says nothing about
		-- one disk is behind.
		return
	end
	outbox_resolution[ns] = nil
end

-- A THIN READ OF THE RESOLUTION, not a second reader. The three-valued contract
-- is unchanged -- entries plus `consent_outbox_read_failed` -- but the judgement
-- behind it is made once, where the read happened.
function M.load_consent_outbox(scope)
	local r = resolution_for(spool_namespace(scope), scope)
	if outbox_unaccounted(r) then
		return copy_outbox_entries(r.receipts), "consent_outbox_read_failed"
	end
	return copy_outbox_entries(r.receipts), nil
end

-- Diagnostic only, and deliberately NOT a fourth value of the loader's error:
-- nothing behavioural distinguishes these, and what they DO distinguish is what
-- an operator should go and look at, which belongs in the alarm's text.
function M.consent_outbox_unaccounted_cause(scope)
	return outbox_cause(resolution_for(spool_namespace(scope), scope))
end

-- Replace the persisted outbox with `receipts` (oldest first), enforcing the
-- fixed entry cap with DENIAL-PREFERRING eviction: while over the cap, the
-- oldest PURE-GRANT receipt is evicted; only when every retained receipt
-- carries a denial does the oldest denial go (see the section header for
-- why a recorded denial outranks a grant). Returns the list that
-- was actually persisted — possibly shorter than the input after the cap
-- eviction — or nil when the durable write failed. Unlike the event spool,
-- a FAILED WRITE never evicts: receipts are consent records whose retention
-- the caller must be able to trust, and at 32 small fixed-shape entries the
-- record sits far under the save-file size limit — so a failing write means
-- the backend is (transiently) unavailable, not that the record is too big.
-- Evict-and-retry here could turn a transient fail-then-succeed into a
-- successfully written EMPTY record, silently dropping a receipt while
-- reporting success; failing the save keeps the receipt in the caller's
-- mirror, marked owed and retried at every dispatch point.
-- ── the caller names an OPERATION, never hands over a list ──────────────────
--
-- A whole-list write cannot say WHY a receipt is missing from what it was
-- handed. Three different facts share that one representation:
--
--   * acknowledged and pruned      -- it must NOT come back
--   * never seen by this caller    -- it MUST come back
--   * removed on purpose, because no credential this session holds can ever
--     send it                      -- it must NOT come back
--
-- The storage layer had to guess between them, and guessing wrong in the third
-- case resurrects a receipt the client deliberately filtered: a revived anon
-- grant then holds the event grant gate open for the session and blocks
-- anonymous-id rotation. So the caller says APPEND THIS or DROP THESE, the
-- resolution owns the list, and there is nothing left to guess.
--
-- Both operations refuse while the trail is unaccounted, and they refuse HERE
-- rather than at the call site. The damaged file is the evidence a session's
-- refusal rests on, and the mirror is only its salvageable subset -- writing
-- the subset over it destroys the evidence with an ordinary acknowledgment
-- instead of a decision. A rule the caller has to remember is a rule one caller
-- forgets.

-- WHAT THIS PROCESS HOLDS AND WHETHER DISK AGREES ARE TWO FACTS. The
-- resolution takes the new list either way; only the return says whether it
-- reached the store. Folding them would mean a failed write also un-does the
-- operation in memory -- so a denial the player just made would not dispatch,
-- and an acknowledged receipt would come back and re-send, both because the
-- disk was briefly unavailable. The decision applies in memory and the trail is
-- marked dirty; that is what the caller's retry is for.
-- THE HOLD IS ABOUT DISK, NOT ABOUT WHAT THE PROCESS KNOWS. While the trail is
-- unaccounted the damaged file is the evidence this session's refusal rests on,
-- and the in-memory list is only its salvageable subset -- writing the subset
-- over it destroys the evidence with an ordinary acknowledgment. So the durable
-- write is withheld. The OPERATION still happens in memory: an acknowledged
-- receipt cannot be re-sent by this process, and a fresh decision applies now.
-- Refusing both would leave the caller re-sending a receipt the server already
-- accepted, forever, because its mirror can never lose it.
-- THE BOUND APPLIED TO A LIST NOBODY APPENDED TO. The loader keeps an over-cap
-- durable record on purpose so identity filtering runs over the whole of it, and
-- the whole-list write used to enforce the bound on the way out. A drop or a
-- flush writing its list straight through means a legacy or externally produced
-- oversized record never converges -- acknowledging some entries leaves it over
-- the bound forever, and the documented fixed cap becomes a number nothing
-- enforces. Denial-preferring, like every other eviction here: pure grants go
-- first, and only an all-denials overflow costs a denial.
--
-- Returns the list AND what it cost, because those are two answers and a caller
-- that surfaces evictions needs both.
local function cap_existing(kept)
	local removed = 0
	while #kept > max_consent_outbox_entries do
		local evict_index = 1
		for i = 1, #kept do
			if receipt_is_pure_grant(kept[i]) then
				evict_index = i
				break
			end
		end
		table.remove(kept, evict_index)
		removed = removed + 1
	end
	return kept, removed
end

local function outbox_write(ns, scope, receipts, withhold)
	local durable = not withhold and write_consent_outbox(ns, receipts)
	local r = outbox_resolution[ns]
	if r ~= nil then
		r.receipts = receipts
		-- WHY DISK DOES NOT HOLD WHAT THIS RESOLUTION HOLDS -- not merely THAT
		-- it does not. One boolean answered two questions that come apart in
		-- exactly the case that matters:
		--
		--   "write_failed" -- the write was attempted and the store refused it.
		--       Disk is BEHIND. Re-reading it loses work already accepted, and
		--       nothing else can recover that work, so a session preserves this.
		--   "held"         -- no write was attempted, because the trail is
		--       unaccounted and the in-memory list is only its salvageable
		--       subset. Disk is not behind, it is DELIBERATELY untouched. A new
		--       session must re-read it: that recovery is the entire reason the
		--       session boundary exists, and preserving this state instead made
		--       every later client inherit the old unaccounted verdict until the
		--       engine restarted.
		r.owed_reason = durable and nil or (withhold and "held" or "write_failed")
		if durable then
			-- On disk, so the resolution describes disk -- the payload AND the
			-- derived facts, or it keeps asserting something about a trail this
			-- process just wrote.
			r.state = "readable"
			r.record_damaged = false
			r.shadow_answered = true
		end
	end
	return durable
end

-- Append ONE receipt. Returns `true, nil, evicted` on success, or
-- `false, reason` -- `consent_outbox_unaccounted` while the trail cannot be
-- read, `consent_outbox_invalid` for a receipt this build would not keep, and
-- `consent_outbox_full` when the cap could only be honoured by evicting a
-- receipt that carries a DENIAL. That last refusal is the point of the cap
-- policy rather than an edge of it: a recorded denial outranks a grant, so a
-- grant that cannot fit is refused rather than admitted at a denial's expense.
-- THE HOLD IS A FACT ABOUT THE TRAIL, and the trail is what storage owns -- so
-- it is DERIVED here rather than passed in. Passing it was wrong for a reason
-- worth stating, because "policy belongs to the caller" is otherwise right: the
-- hold is not a policy about the CALLER's view, it is the state of a shared
-- object. Two clients for one scope share this resolution, so a `withhold` taken
-- from one client's stale flag let it write over a trail the other was
-- protecting -- client A dispatching a full trail, client B replacing the shared
-- resolution with an empty unaccounted one after a transient read failure, and
-- A's acknowledgment then saving that empty list over every undelivered receipt.
--
-- What the caller does own is the DECISION that ends a hold, and that is
-- `supersede_consent_outbox_hold` below.
function M.append_consent_receipt(scope, receipt)
	local ns = spool_namespace(scope)
	local r = resolution_for(ns, scope)
	local withhold = outbox_unaccounted(r)
	local one = sanitize_outbox_entries({ receipt })
	if #one ~= 1 then
		return false, "consent_outbox_invalid"
	end
	local kept = copy_outbox_entries(r.receipts)
	kept[#kept + 1] = one[1]
	local evicted = 0
	while #kept > max_consent_outbox_entries do
		-- THE INCOMING RECEIPT IS NOT A CANDIDATE FOR ITS OWN EVICTION. It sits
		-- last, and searching the whole list found it first when everything
		-- ahead of it was a denial -- so a grant appended to a denial-full
		-- outbox evicted ITSELF and the append reported success. The caller
		-- then flips its state on a receipt that is not there.
		local evict_index = nil
		for i = 1, #kept - 1 do
			if receipt_is_pure_grant(kept[i]) then
				evict_index = i
				break
			end
		end
		if evict_index == nil then
			-- Nothing over the cap is a pure grant, so honouring it costs a
			-- DENIAL -- and what that means depends on what is being appended.
			-- A fresh denial outranks a stale one, so it evicts the oldest and
			-- the trail keeps its most recent refusals. A GRANT does not
			-- outrank any denial, so it is REFUSED and nothing is written: the
			-- caller's state must not flip on a receipt that did not land.
			if receipt_is_pure_grant(one[1]) then
				return false, "consent_outbox_full"
			end
			evict_index = 1
		end
		table.remove(kept, evict_index)
		evicted = evicted + 1
	end
	if not outbox_write(ns, scope, kept, withhold) then
		-- THE EVICTION COUNT RIDES OUT ON BOTH PATHS. The cap has already
		-- removed the entry from the in-memory list -- `outbox_write` applies
		-- the operation whether or not disk takes it -- and a later flush
		-- commits that permanently. Dropping the count here made capacity loss
		-- silent for exactly the runs where a write was failing.
		return false, withhold and "consent_outbox_held" or "consent_outbox_write_failed", evicted
	end
	return true, nil, evicted
end

-- Drop receipts BY KEY, which is the operation a whole-list write could not
-- express. Dropping is explicit, so nothing downstream can restore them:
-- storage is told, rather than inferring from a list it was handed.
-- Keys that are not present are not an error -- the caller asking twice, or
-- asking about a receipt another path already removed, is not a failure.
function M.drop_consent_receipts(scope, keys)
	local ns = spool_namespace(scope)
	local r = resolution_for(ns, scope)
	local withhold = outbox_unaccounted(r)
	local drop = {}
	for i = 1, #keys do
		drop[keys[i]] = true
	end
	local kept, removed = {}, 0
	for i = 1, #r.receipts do
		if drop[r.receipts[i].idempotency_key] then
			removed = removed + 1
		else
			kept[#kept + 1] = r.receipts[i]
		end
	end
	-- NO EARLY RETURN FOR A NO-OP. "Nothing to remove" and "disk already agrees"
	-- are two facts, and returning success for the first cleared the caller's
	-- debt for the second. Reachable: an over-capacity append whose write failed
	-- evicts in memory and leaves the write owed; the acknowledged receipt's
	-- callback then drops a key that is already gone, takes this path, and the
	-- debt disappears -- so a process exit resurrects the old receipt from stale
	-- disk and loses the new decision. The write costs one save and is the only
	-- thing that makes the success it reports true.
	local capped, over = cap_existing(kept)
	if not outbox_write(ns, scope, capped, withhold) then
		return false, withhold and "consent_outbox_held" or "consent_outbox_write_failed", over
	end
	return true, nil, over
end

-- Write what the resolution ALREADY HOLDS to disk. No list crosses the
-- boundary, so none of the three facts a handed-over list confuses can arise --
-- this is the owed-write retry, and the only question it answers is whether
-- disk has caught up with what this process already decided.
function M.flush_consent_outbox(scope)
	local ns = spool_namespace(scope)
	local r = resolution_for(ns, scope)
	local withhold = outbox_unaccounted(r)
	-- THE COUNT RIDES OUT HERE TOO. Both paths that cap a list they did not
	-- build must say what it cost: a client whose only pending action is an owed
	-- write never calls drop, so evictions on this path are the only ones it
	-- would ever see -- and returning nothing made them the ones it never does.
	local capped, over = cap_existing(copy_outbox_entries(r.receipts))
	if not outbox_write(ns, scope, capped, withhold) then
		return false, withhold and "consent_outbox_held" or "consent_outbox_write_failed", over
	end
	return true, nil, over
end

-- AN EXPLICIT DECISION ENDS THE HOLD. The client already does this to its own
-- view; the fact lives here now, so the clear has to land here too. It clears
-- the OBSERVATIONS the hold rested on, not just a flag: leaving `silent` or
-- `unusable` in place meant a resolution preserved for its write debt still
-- reported a read error, so the next client marked the outbox unreadable and
-- withheld every retry even after the store recovered -- and an offline grant
-- receipt stayed memory-only while the persisted identity already said granted.
--
-- This is the IN-SESSION clear that exists on the client today, moved to where
-- the fact now lives. Whether a fresh decision supersedes an unreadable trail
-- ACROSS RESTARTS is a different question and is not answered here.
function M.supersede_consent_outbox_hold(scope)
	local r = resolution_for(spool_namespace(scope), scope)
	r.state = "readable"
	r.record_damaged = false
	r.shadow_answered = true
end

-- IS A DURABLE WRITE OUTSTANDING, and is it outstanding because the store
-- refused one. A client constructed after another has already accepted work
-- into this resolution has to adopt the debt with it: without that, its
-- shutdown treats a memory-only receipt as durably retained and a process exit
-- loses the decision.
function M.consent_outbox_owed(scope)
	return resolution_for(spool_namespace(scope), scope).owed_reason == "write_failed"
end

-- The retained receipts, as a COPY. The caller's mirror and the resolution are
-- never the same table: an in-place append at a call site would otherwise
-- mutate the resolution ahead of -- and regardless of -- the durable write.
function M.consent_outbox_receipts(scope)
	return copy_outbox_entries(resolution_for(spool_namespace(scope), scope).receipts)
end

function M.save_consent_outbox(scope, receipts)
	local ns = spool_namespace(scope)
	local kept = sanitize_outbox_entries(receipts)
	while #kept > max_consent_outbox_entries do
		local evict_index = 1
		for i = 1, #kept do
			if receipt_is_pure_grant(kept[i]) then
				evict_index = i
				break
			end
		end
		table.remove(kept, evict_index)
	end
	if not write_consent_outbox(ns, kept) then
		return nil
	end
	-- THE RESOLUTION NOW DESCRIBES WHAT IS ON DISK, BECAUSE THIS CALL PUT IT
	-- THERE. Leaving it stale would trade "re-derivation flips a fact" for "the
	-- resolution drifted from the disk it describes", which is the same class
	-- facing the other way.
	local r = outbox_resolution[ns]
	if r ~= nil then
		r.state = "readable"
		r.record_damaged = false
		r.shadow_answered = true
		r.receipts = kept
	end
	return copy_outbox_entries(kept)
end

-- True when the outbox has a durable backend on this runtime (the save-file
-- API is available). The in-memory fallback keeps in-process retries working
-- on plain Lua hosts, but it does not survive the process — so shutdown()
-- must not count a fallback write as delivery-safe retention.
function M.consent_outbox_is_durable(scope)
	return save_path(spool_namespace(scope), "consent-outbox") ~= nil
end

-- ── remote-config cache ──────────────────────────────────────────────────────
--
-- One durable last-known-good record per app for the remote-config client:
-- the raw response body plus the ETag it was served with, stamped with the
-- (workspace, environment, client, url) scope string the fetch was made for.
-- The scope check itself lives in the remote-config client; this store only
-- persists and validates the record shape. The cache is best-effort — a
-- failed write costs only offline serving, never the fetched values.

local remote_config_memory = {}

-- Defold documents that sys.save caps a saved table at 512 KB. A body that
-- alone approaches the cap is refused up front (matching the spool's byte
-- clamp) so the write cannot fail at the sys layer with the record half
-- formed; the previously cached record stays untouched.
local max_remote_config_body_bytes = 393216

local function remote_config_record(record)
	return {
		scope = record.scope,
		etag = type(record.etag) == "string" and record.etag or "",
		body = record.body,
		fetched_at_ms = type(record.fetched_at_ms) == "number" and record.fetched_at_ms or 0,
	}
end

-- Load the cached remote-config record for this app (the same per-app
-- namespace scheme as the spool), or nil when absent or unusable. A record
-- without a scope stamp cannot be attributed to any (workspace, environment,
-- client, url) tuple, and one without a body has nothing to serve — both
-- read as no cache. Never throws.
function M.load_remote_config(scope)
	local ns = spool_namespace(scope)
	local record = nil
	local path = save_path(ns, "remote-config")
	if path then
		local ok, loaded = pcall(sys.load, path)
		if ok and type(loaded) == "table" then
			record = loaded
		end
	end
	if record == nil then
		record = remote_config_memory[ns]
	end
	if type(record) ~= "table"
		or type(record.scope) ~= "string" or record.scope == ""
		or type(record.body) ~= "string" or record.body == "" then
		return nil
	end
	return remote_config_record(record)
end

-- Drop the cached remote-config record: an empty record is written in its
-- place (which loads as "no cache") and the in-memory fallback is cleared.
-- Used when a newer configuration was served but could not overwrite the
-- record — the stale copy must not be revived by a later launch. Returns
-- true when the clear landed.
function M.clear_remote_config(scope)
	local ns = spool_namespace(scope)
	local path = save_path(ns, "remote-config")
	if not path then
		remote_config_memory[ns] = nil
		return true
	end
	local ok, saved = pcall(sys.save, path, {})
	if not (ok and saved == true) then
		return false
	end
	remote_config_memory[ns] = nil
	return true
end

-- Replace the cached remote-config record (`{ scope, etag, body,
-- fetched_at_ms }`). Returns true when stored — in the durable save file, or
-- in the in-memory fallback on hosts without the save-file API (which then
-- lasts only for the process lifetime, like the identity record).
function M.save_remote_config(scope, record)
	if type(record) ~= "table"
		or type(record.scope) ~= "string" or record.scope == ""
		or type(record.body) ~= "string" or record.body == "" then
		return false
	end
	if #record.body > max_remote_config_body_bytes then
		return false
	end
	local ns = spool_namespace(scope)
	local stored = remote_config_record(record)
	local path = save_path(ns, "remote-config")
	if not path then
		remote_config_memory[ns] = stored
		return true
	end
	local ok, saved = pcall(sys.save, path, stored)
	if not (ok and saved == true) then
		return false
	end
	remote_config_memory[ns] = stored
	return true
end

-- ── experiment-assignment cache ──────────────────────────────────────────────
--
-- One durable last-known-good record per app for the experiments client: a map
-- of experiment_key → the assignment entry served for it, stamped with the
-- (workspace, environment, subject, url) scope string the fetches were made
-- for. The scope check itself lives in the experiments client; this store only
-- persists and validates the record shape. Like the remote-config cache, the
-- record is best-effort — a failed write costs only offline serving, never the
-- fetched assignment — and a corrupt or partially garbled record degrades to
-- the salvageable subset (corrupt = miss, clean start).

local experiments_memory = {}

-- Defold documents that sys.save caps a saved table at 512 KB; refuse a record
-- whose string-scalar estimate approaches it (parity with the remote-config
-- body clamp) so the write cannot fail at the sys layer with the record half
-- formed. The previously cached record stays untouched.
local max_experiments_record_bytes = 393216

-- Keep only attribute pairs that are usable for a revalidation fetch: a
-- { name, value } table of non-empty strings.
local function sanitize_experiment_attributes(attributes)
	if type(attributes) ~= "table" then
		return nil
	end
	local out = nil
	for i = 1, #attributes do
		local pair = attributes[i]
		if type(pair) == "table"
			and type(pair.name) == "string" and pair.name ~= ""
			and type(pair.value) == "string" then
			out = out or {}
			out[#out + 1] = { name = pair.name, value = pair.value }
		end
	end
	return out
end

-- Deep copy for a cached variant payload (decoded JSON: acyclic; the depth
-- cap only bounds the walk). Non-table scalars are stored as-is.
local function copy_experiment_payload(value, depth)
	if type(value) ~= "table" then
		return value
	end
	if depth >= 16 then
		return nil
	end
	local out = {}
	for key, child in pairs(value) do
		if type(key) == "string" or type(key) == "number" then
			out[key] = copy_experiment_payload(child, depth + 1)
		end
	end
	return out
end

-- The positive wire grammar for a server-minted subject-fact key (kept in
-- sync with shardpilot/experiments.lua's valid_subject_fact_key — storage
-- cannot require experiments without a cycle): sfk1_ + exactly 64 lowercase
-- hex. A restored client_id entry whose key fails it would serve a variant
-- with every fact terminally skipped — the zero-reporting bias the live
-- install path rejects — so it reads as a safe scope-miss instead. Every
-- OTHER unit restores the entry but has the failing FIELD cleared (live
-- install parity: the install path stores the key on no unit unless it
-- passes this grammar): a corrupted or pre-grammar-build value — an
-- SDK-subject-shaped `spcid_...` included — must not ride
-- `props.assignment_key` onto the analytics plane at the next emit, and a
-- key-less synthetic entry keeps the documented fact-less serving posture.
local function valid_subject_fact_key(value)
	if type(value) ~= "string" or #value ~= 69 then
		return false
	end
	return value:match("^sfk1_[0-9a-f]+$") ~= nil
end

-- The positive wire grammar for an experiment version (kept in sync with
-- shardpilot/experiments.lua's valid_wire_version — same no-cycle rule as
-- the fact-key grammar above): a positive, finite integer. A cached entry
-- restored with a garbled version would go LIVE and stamp every emitted
-- fact with an invalid experiment_version, so non-conforming entries drop
-- at load (greenfield store: no legacy tolerance needed).
local function valid_wire_version(value)
	return type(value) == "number" and value > 0 and value < math.huge
		and value % 1 == 0
end

-- Keep only entries that are complete, well-formed assignment records, copied
-- down to the known fields. Anything else — a corrupt file, a truncated entry,
-- a garbled field — is dropped rather than served or crashed on.
local function sanitize_experiment_entries(entries)
	local out = {}
	if type(entries) ~= "table" then
		return out
	end
	for key, entry in pairs(entries) do
		if type(key) == "string" and key ~= ""
			and type(entry) == "table"
			and type(entry.assignment_key) == "string" and entry.assignment_key ~= ""
			and type(entry.variant_key) == "string" and entry.variant_key ~= ""
			and valid_wire_version(entry.version)
			and type(entry.assignment_unit) == "string" and entry.assignment_unit ~= ""
			and (entry.assignment_unit ~= "client_id"
				or valid_subject_fact_key(entry.subject_fact_key))
			and (entry.subject_key == nil or type(entry.subject_key) == "string")
			and type(entry.fetched_at_ms) == "number" then
			out[key] = {
				assignment_key = entry.assignment_key,
				variant_key = entry.variant_key,
				variant_payload = copy_experiment_payload(entry.variant_payload, 0),
				version = entry.version,
				assignment_unit = entry.assignment_unit,
				subject_fact_key = valid_subject_fact_key(entry.subject_fact_key)
					and entry.subject_fact_key or nil,
				subject_key = entry.subject_key,
				attributes = sanitize_experiment_attributes(entry.attributes),
				fetched_at_ms = entry.fetched_at_ms,
			}
		end
	end
	return out
end

-- Load the cached experiment-assignment record for this app (the same per-app
-- namespace scheme as the spool), or nil when absent or unusable. A record
-- without a scope stamp cannot be attributed to any (workspace, environment,
-- subject, url) tuple — it reads as no cache. Never throws.
function M.load_experiments(scope)
	local ns = spool_namespace(scope)
	local record = nil
	local path = save_path(ns, "experiments")
	if path then
		local ok, loaded = pcall(sys.load, path)
		if ok and type(loaded) == "table" then
			record = loaded
		elseif not ok then
			-- The STORE errored on the read — distinct from a readable
			-- miss (no file, or a record another scope replaced) and from
			-- a parsed-but-corrupt record (which stays a plain miss, the
			-- corrupt-is-a-miss canon: same bytes parse the same way
			-- forever). The in-process memory shadow must NOT stand in for
			-- the failed read: the file's current content is unknown — a
			-- sibling client may have persisted entries after this
			-- process's last successful save — and a shadow-backed answer
			-- would let settle/save paths decide off a process-local
			-- snapshot (wiping durable entries absent from the shadow, or
			-- vacuously retiring a drop the file still holds). Callers
			-- that must fail closed on ambiguity — the sync/settle/retire
			-- paths — read the second value; everyone else keeps the
			-- nil-is-a-miss contract unchanged.
			return nil, "unreadable"
		end
	end
	if record == nil then
		record = experiments_memory[ns]
	end
	if type(record) ~= "table"
		or type(record.scope) ~= "string" or record.scope == "" then
		return nil
	end
	return {
		scope = record.scope,
		entries = sanitize_experiment_entries(record.entries),
	}
end

-- Replace the cached experiment-assignment record
-- (`{ scope, entries = { [experiment_key] = entry } }`). Returns true when
-- stored — in the durable save file, or in the in-memory fallback on hosts
-- without the save-file API (which then lasts only for the process lifetime).
function M.save_experiments(scope, record)
	if type(record) ~= "table"
		or type(record.scope) ~= "string" or record.scope == "" then
		return false
	end
	local stored = {
		scope = record.scope,
		entries = sanitize_experiment_entries(record.entries),
	}
	-- The size cap is a DETERMINISTIC bound, so an oversized record must
	-- never surface as a retryable failure: the caller would record an owed
	-- durable sync that can never land and persist()/shutdown() would wedge
	-- on experiments_pending forever. Spool parity instead — evict entries
	-- oldest-fetched-first until the record fits (including the offender
	-- itself when a single entry alone exceeds the cap). Evicted entries
	-- simply stop being durable: memory keeps serving them for this
	-- process, the next launch refetches (absence is a refetch, never
	-- wrong serving), and drops always land because removal only shrinks
	-- the record. The evicted count returns as a second value so callers
	-- can surface a diagnostic.
	local evicted = 0
	while approx_record_bytes(stored) > max_experiments_record_bytes do
		local oldest_key = nil
		local oldest_at = nil
		for key, entry in pairs(stored.entries) do
			local at = type(entry) == "table"
				and type(entry.fetched_at_ms) == "number"
				and entry.fetched_at_ms or 0
			if oldest_at == nil or at < oldest_at then
				oldest_at = at
				oldest_key = key
			end
		end
		if oldest_key == nil then
			-- Nothing left to evict and the record still exceeds the cap:
			-- deterministic and terminal for this input, surfaced as a
			-- plain failure (callers treat it like any failed save; no
			-- retry can change it, but no entry data exists to wedge on).
			return false, evicted
		end
		stored.entries[oldest_key] = nil
		evicted = evicted + 1
	end
	local ns = spool_namespace(scope)
	local path = save_path(ns, "experiments")
	if not path then
		experiments_memory[ns] = stored
		return true, evicted
	end
	local ok, saved = pcall(sys.save, path, stored)
	if not (ok and saved == true) then
		return false, evicted
	end
	experiments_memory[ns] = stored
	return true, evicted
end

-- Durable condemnation marker for the experiment cache: when the
-- real-subjects sentinel's whole-record clear cannot land, the CLEAR ITSELF
-- is persisted — its stamp — in a sidecar file, so the intent survives the
-- process and the next launch refuses the withdrawn record instead of
-- serving it until the first probe. Deliberately a SEPARATE file: the
-- record file's write is what is failing, and this marker is the cheapest
-- possible durable mark (a per-file failure of the record must not take the
-- condemnation down with it; if the whole store is down, both writes fail
-- and the documented storage-down-through-exit residual applies).
local experiments_clear_memory = {}

-- The marker carries BOTH the clear's stamp and the assignment SCOPE it was
-- decided for: the record file is shared across every assignment scope in
-- this per-app namespace, and a sentinel for one environment/credential
-- must never condemn another scope's entries just because their stamps are
-- older. Returns (stamp, clear_scope); clear_scope may be nil only for a
-- legacy/degenerate record, which consumers treat conservatively.
function M.load_experiments_clear(scope)
	local ns = spool_namespace(scope)
	local record = nil
	local read_failed = false
	local path = save_path(ns, "experiments-clear")
	if path then
		local ok, loaded = pcall(sys.load, path)
		if ok and type(loaded) == "table" then
			record = loaded
		elseif not ok then
			read_failed = true
		end
	end
	if record == nil then
		record = experiments_clear_memory[ns]
	end
	if type(record) ~= "table" or type(record.stamp) ~= "number" then
		if read_failed and record == nil then
			-- The sidecar READ errored and no in-process shadow backs it:
			-- an armed condemnation may be sitting in the unreadable file,
			-- and reading that as "no marker" would let a perfectly
			-- readable spool replay condemned facts after a restart (the
			-- shadow is empty then by construction). The third return
			-- lets consumers fail CLOSED — treat the marker as armed with
			-- unknown stamp/scope — until a readable pass decides it. A
			-- readable-but-garbled record still reads as absent (the
			-- corrupt-is-a-miss canon), and a present shadow (a marker
			-- this process saved) is served as armed like always.
			return nil, nil, "unreadable"
		end
		return nil
	end
	local clear_scope = type(record.scope) == "string" and record.scope ~= ""
		and record.scope or nil
	return record.stamp, clear_scope
end

function M.save_experiments_clear(scope, stamp, clear_scope)
	if type(stamp) ~= "number" or type(clear_scope) ~= "string"
		or clear_scope == "" then
		return false
	end
	local ns = spool_namespace(scope)
	local stored = { stamp = stamp, scope = clear_scope }
	local path = save_path(ns, "experiments-clear")
	if not path then
		experiments_clear_memory[ns] = stored
		return true
	end
	local ok, saved = pcall(sys.save, path, stored)
	if not (ok and saved == true) then
		return false
	end
	experiments_clear_memory[ns] = stored
	return true
end

function M.clear_experiments_clear(scope)
	local ns = spool_namespace(scope)
	local path = save_path(ns, "experiments-clear")
	if not path then
		experiments_clear_memory[ns] = nil
		return true
	end
	local ok, saved = pcall(sys.save, path, {})
	if not (ok and saved == true) then
		return false
	end
	experiments_clear_memory[ns] = nil
	return true
end

-- Drop the cached experiment-assignment record: an empty record is written in
-- its place (which loads as "no cache") and the in-memory fallback is cleared.
-- Returns true when the clear landed.
function M.clear_experiments(scope)
	local ns = spool_namespace(scope)
	local path = save_path(ns, "experiments")
	if not path then
		experiments_memory[ns] = nil
		return true
	end
	local ok, saved = pcall(sys.save, path, {})
	if not (ok and saved == true) then
		return false
	end
	experiments_memory[ns] = nil
	return true
end

-- Clears the in-memory fallback records only; intended for tests.
function M.reset()
	memory_records = {}
	consent_denial_memory = {}
	pending_memory = {}
	crash_settings_memory = {}
	spool_memory = {}
	consent_outbox_memory = {}
	outbox_resolution = {}
	remote_config_memory = {}
	experiments_memory = {}
	experiments_clear_memory = {}
end

return M
