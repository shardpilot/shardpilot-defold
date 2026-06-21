-- Crash event shape, normalization, sanitization, and validation for the crash
-- report JSON body sent to the crash ingest endpoint. Behavior is consistent
-- across our SDKs.
--
-- An event table carries (snake_case wire keys throughout):
--   crash_id, occurred_at, app{id,version,build_id}, source, platform,
--   os{name,version}, device{}, context{}, exception{type,reason,
--   crashed_thread_id}, modules[], threads[]{id,name,crashed,frames[]},
--   raw_text, breadcrumbs[], fingerprint_components[], metadata{}.
local clock = require "shardpilot.clock"
local id = require "shardpilot.id"
local sanitize = require "shardpilot.crash.sanitize"

local M = {}

local max_stack_frames = 256
local max_threads = 64
local max_modules = 256
local max_breadcrumbs = 50
local max_fingerprint_components = 32

M.max_breadcrumbs = max_breadcrumbs

local device_classes = {
	phone = true,
	tablet = true,
	desktop = true,
	console = true,
	tv = true,
}

local function trim(value)
	if type(value) ~= "string" then
		return ""
	end
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function non_empty(value)
	return type(value) == "string" and trim(value) ~= ""
end

-- Return the first non-empty argument, trimmed. Uses select() so a nil argument
-- is tolerated: an ipairs over {...} would stop at the first nil, so a fallback
-- like (instruction_addr, address) would never reach `address` when
-- `instruction_addr` is nil — silently rejecting a valid native frame.
local function first_non_empty(...)
	local n = select("#", ...)
	for i = 1, n do
		local value = select(i, ...)
		if non_empty(value) then
			return trim(value)
		end
	end
	return ""
end

-- Component slug: ^[a-z0-9][a-z0-9-]{0,62}$, max 63 chars. Empty is a
-- valid "bare app" (the field is omitted from the wire). Validates the same
-- shape the server enforces, BEFORE the value reaches the wire.
function M.valid_source(value)
	if value == nil or value == "" then
		return true
	end
	if type(value) ~= "string" then
		return false
	end
	if #value > 63 then
		return false
	end
	return value:match("^[a-z0-9][a-z0-9-]*$") ~= nil
end

-- UUIDv7 shape check (version nibble 7). Mirrors the analytics id generator's
-- v7 layout. crash_id is preferably a UUIDv7 but the server only requires a
-- stable string, so a non-v7 value is accepted (validation only rejects empty).
local function looks_like_uuid_v7(value)
	return type(value) == "string"
		and value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-7%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

M.looks_like_uuid_v7 = looks_like_uuid_v7

-- A safe crash_id shape: a UUID (any version) or a plain token of id-safe
-- characters, max 128 chars. Anything else (whitespace, punctuation, an email,
-- a free-form sentence) is not a stable correlation key the server expects.
local function looks_like_safe_crash_id(value)
	if type(value) ~= "string" then
		return false
	end
	if #value == 0 or #value > 128 then
		return false
	end
	if value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
		return true
	end
	return value:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$") ~= nil
end

-- Normalize a caller-supplied crash_id: trim it, and if it is not a safe
-- id shape OR carries disallowed identifier material (player_/user_ prefixes,
-- email, IP, dotted token), substitute a freshly generated UUIDv7. A fatal crash
-- is never dropped over a malformed crash_id — it is replaced, never rejected.
function M.normalize_crash_id(value)
	if type(value) ~= "string" then
		return id.uuid_v7()
	end
	local trimmed = trim(value)
	if not looks_like_safe_crash_id(trimmed) or sanitize.contains_disallowed_content(trimmed) then
		return id.uuid_v7()
	end
	return trimmed
end

-- Identity keys that must never be carried in the free-form caller context map:
-- they are raw actor correlation keys, not crash diagnostics. Listed in the
-- canonical snake_case form; matching is done after normalizing each candidate
-- key (lowercase + strip the '_' and '-' separators) so case and separator
-- aliases all collapse to the same form — userId / user-id / USER_ID / userid
-- all match user_id.
local identity_context_keys = {
	session_id = true,
	anonymous_id = true,
	user_id = true,
	device_id = true,
	player_id = true,
	customer_id = true,
	actor_id = true,
}

-- Normalize an identity key for comparison: trim surrounding whitespace, lowercase,
-- then drop the separators ('_', '-', and '.') so snake_case, camelCase, kebab-case,
-- dotted, and SCREAMING_CASE aliases of the same key all collapse to one form
-- (user_id / userId / user-id / user.id -> userid). Dropping the dot is load-bearing:
-- a dotted alias like "user.id" or "session.id" is an identity key under a different
-- separator and must collapse too, or a raw actor id reaches the wire under a key the
-- value scrub never inspects. Only the known identity names match after collapsing, so
-- a non-identity dotted key like "build.channel" (-> "buildchannel") still survives.
-- Trimming first is load-bearing: a whitespace-padded key like " user_id " must still
-- be recognized as an identity key and stripped.
local function normalize_identity_key(key)
	return (key:gsub("^%s+", ""):gsub("%s+$", ""):lower():gsub("[_%-%.]", ""))
end

-- The identity set keyed by its normalized form, built once from the canonical
-- snake_case set above.
local normalized_identity_keys = {}
for canonical in pairs(identity_context_keys) do
	normalized_identity_keys[normalize_identity_key(canonical)] = true
end

-- Drop any known identity key from a caller context map so a raw identifier
-- never reaches the wire even when its value scrubs clean. Each key is normalized
-- (lowercase + separators stripped) before the lookup so camelCase / kebab-case /
-- SCREAMING_CASE aliases (userId, user-id, USER_ID) are stripped too.
local function strip_identity_keys(context)
	if type(context) ~= "table" then
		return context
	end
	for key in pairs(context) do
		if type(key) == "string" and normalized_identity_keys[normalize_identity_key(key)] then
			context[key] = nil
		end
	end
	return context
end

local function copy_string_map(value)
	if type(value) ~= "table" then
		return nil
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = v
	end
	return out
end

-- Deep-ish clone of a crash event so the caller's table is never mutated by
-- normalization/sanitization. A nested list entry (module/thread/frame/
-- breadcrumb) that is not a table is malformed input: returning (nil,
-- "malformed_event") routes it through the normal reject path instead of letting
-- a later index raise a Lua error.
local function clone_event(event)
	local out = {
		crash_id = event.crash_id,
		occurred_at = event.occurred_at,
		platform = event.platform,
		source = event.source,
		raw_text = event.raw_text,
	}
	out.app = {}
	if type(event.app) == "table" then
		out.app.id = event.app.id
		out.app.version = event.app.version
		out.app.build_id = event.app.build_id
	end
	out.os = {}
	if type(event.os) == "table" then
		out.os.name = event.os.name
		out.os.version = event.os.version
	end
	out.exception = {}
	if type(event.exception) == "table" then
		out.exception.type = event.exception.type
		out.exception.reason = event.exception.reason
		out.exception.crashed_thread_id = event.exception.crashed_thread_id
	end
	out.device = copy_string_map(event.device)
	out.context = copy_string_map(event.context)
	out.metadata = copy_string_map(event.metadata)
	out.fingerprint_components = nil
	if type(event.fingerprint_components) == "table" then
		out.fingerprint_components = {}
		for i = 1, #event.fingerprint_components do
			out.fingerprint_components[i] = event.fingerprint_components[i]
		end
	end
	out.modules = nil
	if type(event.modules) == "table" then
		out.modules = {}
		for i, module in ipairs(event.modules) do
			if type(module) ~= "table" then
				return nil, "malformed_event"
			end
			out.modules[i] = {
				id = module.id,
				name = module.name,
				platform = module.platform,
				debug_id = module.debug_id,
				build_id = module.build_id,
				load_address = module.load_address,
				base_address = module.base_address,
				end_address = module.end_address,
				size = module.size,
			}
		end
	end
	out.threads = nil
	if type(event.threads) == "table" then
		out.threads = {}
		for i, thread in ipairs(event.threads) do
			if type(thread) ~= "table" then
				return nil, "malformed_event"
			end
			local frames = {}
			if type(thread.frames) == "table" then
				for j, frame in ipairs(thread.frames) do
					if type(frame) ~= "table" then
						return nil, "malformed_event"
					end
					frames[j] = {
						index = frame.index,
						module_id = frame.module_id,
						module = frame.module,
						module_name = frame.module_name,
						instruction_addr = frame.instruction_addr,
						address = frame.address,
						relative_addr = frame.relative_addr,
						["function"] = frame["function"],
						file = frame.file,
						line = frame.line,
					}
				end
			end
			out.threads[i] = {
				id = thread.id,
				name = thread.name,
				-- crashed is a strict boolean wire field. Coerce it here so a non-boolean
				-- caller value (a string like "false", or an accidental raw id) is never
				-- treated as a truthy crashed flag and never reaches the wire verbatim:
				-- only an exact boolean true marks the crashed thread.
				crashed = thread.crashed == true,
				frames = frames,
			}
		end
	end
	out.breadcrumbs = nil
	if type(event.breadcrumbs) == "table" then
		out.breadcrumbs = {}
		for i, breadcrumb in ipairs(event.breadcrumbs) do
			if type(breadcrumb) ~= "table" then
				return nil, "malformed_event"
			end
			out.breadcrumbs[i] = {
				name = breadcrumb.name,
				timestamp = breadcrumb.timestamp,
				type = breadcrumb.type,
				category = breadcrumb.category,
				level = breadcrumb.level,
				message = breadcrumb.message,
			}
		end
	end
	return out
end

M.clone_event = clone_event

-- An ISO-8601 UTC-ish instant shape: YYYY-MM-DDTHH:MM:SS with an optional
-- fractional part and a Z / +HH:MM / -HH:MM offset. This is the shape clock.iso_utc()
-- emits and the shape the server expects; a free-form or PII-bearing string fails
-- it. Lua patterns have no alternation, so the offset suffix is checked separately.
local function valid_iso_instant(value)
	if type(value) ~= "string" then
		return false
	end
	-- Match the fixed date-time head, then take the remainder. The fractional part
	-- (when present) must be exactly one "." followed by one-or-more digits — a run
	-- like "..Z" or ".5.6Z" is malformed and must not pass.
	local rest = value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d(.*)$")
	if not rest then
		return false
	end
	local fraction = rest:match("^(%.%d+)")
	if fraction then
		rest = rest:sub(#fraction + 1)
	end
	if rest == "" or rest == "Z" then
		return true
	end
	return rest:match("^[%+%-]%d%d:%d%d$") ~= nil
end

M.valid_iso_instant = valid_iso_instant

-- A hex instruction/load address: an optional 0x prefix followed by hex digits.
-- Mirrors the address normalization the native-dump path emits and the shape the
-- server resolves against the module map.
local function looks_like_hex_address(value)
	if type(value) ~= "string" then
		return false
	end
	if value:match("^0[xX]%x+$") then
		return true
	end
	return value:match("^%x+$") ~= nil
end

M.looks_like_hex_address = looks_like_hex_address

-- Scrub a caller-supplied breadcrumb timestamp. Keep it only when it is a
-- clean ISO-8601 instant; otherwise fall back to the event time so a malformed or
-- PII-bearing value never reaches the wire. The ISO instant grammar is a closed
-- shape that cannot carry PII (and whose colons would otherwise trip the IPv6
-- heuristic), so matching it is sufficient — no further content scrub is applied.
local function sanitize_breadcrumb_timestamp(value, fallback)
	if non_empty(value) and valid_iso_instant(trim(value)) then
		return trim(value)
	end
	return fallback
end

-- Keep only the most-recent max_breadcrumbs entries.
local function cap_breadcrumbs(breadcrumbs)
	if type(breadcrumbs) ~= "table" or #breadcrumbs <= max_breadcrumbs then
		return breadcrumbs
	end
	local out = {}
	local start = #breadcrumbs - max_breadcrumbs + 1
	for i = start, #breadcrumbs do
		out[#out + 1] = breadcrumbs[i]
	end
	return out
end

-- Default the occurred_at + breadcrumb timestamps to now (UTC, ISO-8601 string).
local function normalize_event_times(event)
	-- occurred_at is best-effort caller input. Default it to now when it is
	-- absent or not a clean ISO-8601 instant. The ISO instant grammar is a closed
	-- shape (digits / dashes / colons / T / Z / numeric offset) that cannot carry
	-- PII, so matching it is sufficient — no content scrub is applied (its colons
	-- would otherwise be misread by the IPv6 heuristic). A fatal crash is never
	-- dropped over a bad timestamp; it is replaced.
	if not non_empty(event.occurred_at) or not valid_iso_instant(trim(event.occurred_at)) then
		event.occurred_at = clock.iso_utc()
	else
		event.occurred_at = trim(event.occurred_at)
	end
	if type(event.breadcrumbs) == "table" then
		for _, breadcrumb in ipairs(event.breadcrumbs) do
			if not non_empty(breadcrumb.timestamp) then
				breadcrumb.timestamp = event.occurred_at
			end
		end
	end
	return event
end

-- A native backtrace from a stack overflow / deep recursion can carry far more
-- than the per-report frame budget. Rejecting it would lose the crash entirely
-- (the one-shot native dump has already been consumed by the time the report is
-- assembled), so instead TRUNCATE the frames to the budget, keeping the TOP frames
-- (closest to the fault — the most relevant for diagnosis) and dropping the
-- deepest tail. The budget is shared across all threads, but the CRASHED thread is
-- served FIRST: it carries the actionable stack, so it must keep its top frames
-- before any other thread spends the shared budget. Without this, an earlier
-- non-crashed thread with more than the whole budget could consume all of it and
-- truncate the crashed thread to zero frames, leaving the report with no
-- actionable stack. After the crashed thread is served, the remaining threads keep
-- as many of their top frames as the remaining budget allows, in thread order.
local function truncate_thread_frames(thread, remaining)
	if type(thread.frames) ~= "table" then
		return remaining
	end
	if #thread.frames > remaining then
		-- Keep the top `remaining` frames; drop the deeper tail.
		for j = #thread.frames, remaining + 1, -1 do
			thread.frames[j] = nil
		end
	end
	remaining = remaining - #thread.frames
	if remaining < 0 then
		remaining = 0
	end
	return remaining
end

local function truncate_frames(event)
	if type(event.threads) ~= "table" then
		return event
	end
	local remaining = max_stack_frames
	-- Serve the crashed thread first so its actionable stack is never starved by an
	-- earlier non-crashed thread that overruns the shared budget. The crashed thread
	-- is identified either by its own `crashed` flag or by the event's
	-- crashed_thread_id (some callers set only the latter). This runs AFTER the scrub
	-- pass has dropped PII-only frames, so the budget is spent on the frames that
	-- actually ship — a stack whose top frames scrubbed away still keeps its clean
	-- tail frames up to the budget instead of being truncated before the scrub.
	local crashed_thread_id = non_empty(event.exception and event.exception.crashed_thread_id)
		and trim(event.exception.crashed_thread_id) or nil
	local crashed_thread = nil
	for _, thread in ipairs(event.threads) do
		if type(thread.frames) == "table"
			and (thread.crashed
				or (crashed_thread_id ~= nil and non_empty(thread.id)
					and trim(thread.id) == crashed_thread_id)) then
			crashed_thread = thread
			break
		end
	end
	if crashed_thread then
		remaining = truncate_thread_frames(crashed_thread, remaining)
	end
	-- Then the remaining threads in order, skipping the already-served crashed one.
	for _, thread in ipairs(event.threads) do
		if thread ~= crashed_thread then
			remaining = truncate_thread_frames(thread, remaining)
		end
	end
	return event
end

-- Parse a hex address (with or without a leading 0x) to a number, or nil when the
-- value is not a clean hex address. tonumber handles the 0x form directly; a bare
-- hex run is parsed in base 16.
local function parse_hex_address(value)
	if not looks_like_hex_address(value) then
		return nil
	end
	local trimmed = trim(value)
	if trimmed:match("^0[xX]") then
		return tonumber(trimmed)
	end
	return tonumber(trimmed, 16)
end

-- A native dump on a large process can load far more modules than the per-report
-- module budget. Rejecting the whole report would lose a previous-session fatal whose
-- frames are valid, so instead SELECT a subset within the budget rather than rejecting.
-- The modules a frame actually references are the ones the server needs to resolve the
-- kept stack, so those are kept FIRST; the remaining budget is filled with the earliest
-- other modules. A previous-session dump's frames often carry only an instruction
-- address (no module name), so a frame is also treated as referencing the module whose
-- loaded address range CONTAINS that address — otherwise a crash in a later-loaded
-- module on a process with more than the budget of modules would lose its module entry
-- and become unsymbolicatable. This keeps the report under the budget while preserving
-- the modules the surviving frames resolve against.
-- A module entry whose required fields scrubbed away (its name blanked as PII, or
-- both its debug_id and build_id removed) or whose load/base address is missing or
-- not a hex address is unusable. Such an entry must not reject the WHOLE report:
-- the other clean modules may already cover every address frame, or the stack may
-- be pre-symbolicated (function frames, no addresses) and need no module map at
-- all. So DROP the invalid module entries here instead of failing the report. A
-- dropped module that a frame referenced simply loses that frame's address
-- resolution path — the same established outcome as an unattributed address — but
-- the frame itself (and its function symbol, if any) still ships.
local function module_is_usable(module)
	if not non_empty(module.name) then
		return false
	end
	if not non_empty(module.debug_id) and not non_empty(module.build_id) then
		return false
	end
	local module_address = first_non_empty(module.load_address, module.base_address)
	if module_address == "" or not looks_like_hex_address(module_address) then
		return false
	end
	return true
end

local function filter_invalid_modules(event)
	if type(event.modules) ~= "table" then
		return event
	end
	local kept = {}
	-- Names/ids of dropped modules: a frame that referenced one of these by id/name
	-- can no longer resolve its address against it, so that frame's address path is
	-- dropped (the established outcome for a missing referenced module). The frame
	-- itself still ships with whatever identity it retains (its function symbol).
	local dropped_refs = {}
	for _, module in ipairs(event.modules) do
		if module_is_usable(module) then
			kept[#kept + 1] = module
		else
			if non_empty(module.id) then
				dropped_refs[trim(module.id)] = true
			end
			if non_empty(module.name) then
				dropped_refs[trim(module.name)] = true
			end
		end
	end
	event.modules = kept
	if next(dropped_refs) ~= nil and type(event.threads) == "table" then
		for _, thread in ipairs(event.threads) do
			if type(thread.frames) == "table" then
				local kept_frames = {}
				for _, frame in ipairs(thread.frames) do
					local ref = first_non_empty(frame.module_id, frame.module, frame.module_name)
					if ref ~= "" and dropped_refs[trim(ref)] then
						frame.instruction_addr = ""
						frame.address = ""
					end
					-- Keep the frame only if it still has a usable identity. A frame whose
					-- address path was just dropped and that carries no function symbol is
					-- no longer identifiable, so it is dropped rather than failing the
					-- whole report — mirroring the scrub-pass frame filter.
					if non_empty(frame["function"]) or non_empty(frame.instruction_addr)
						or non_empty(frame.address) then
						kept_frames[#kept_frames + 1] = frame
					end
				end
				thread.frames = kept_frames
			end
		end
	end
	return event
end

local function truncate_modules(event)
	if type(event.modules) ~= "table" or #event.modules <= max_modules then
		return event
	end
	-- Collect the module references (by name) and the instruction addresses that
	-- surviving frames point at.
	local referenced = {}
	local frame_addresses = {}
	if type(event.threads) == "table" then
		for _, thread in ipairs(event.threads) do
			if type(thread.frames) == "table" then
				for _, frame in ipairs(thread.frames) do
					for _, ref in ipairs({ frame.module_id, frame.module, frame.module_name }) do
						if non_empty(ref) then
							referenced[trim(ref)] = true
						end
					end
					local addr = parse_hex_address(frame.instruction_addr) or parse_hex_address(frame.address)
					if addr then
						frame_addresses[#frame_addresses + 1] = addr
					end
				end
			end
		end
	end
	-- Resolve which modules cover a crashing frame PC, using the standard
	-- symbolication model:
	--   * A module that declares an explicit upper bound — end_address, or
	--     load_address + size — covers a PC in the half-open range
	--     [load_address, end_address). This is exact and takes precedence.
	--   * A previous-session dump module typically carries ONLY a load_address (no
	--     end_address/size). For an address-only module set, a PC is covered by the
	--     module with the GREATEST load_address that is <= PC (nearest-preceding
	--     base) — the module the address actually falls inside. A PC already claimed
	--     by an explicit-range module is not reassigned.
	-- The result is a set (keyed by module table) of modules that cover at least one
	-- frame PC, so a name-less native frame still pins the module it crashed in.
	local module_bounds = {}
	for _, module in ipairs(event.modules) do
		local load_addr = parse_hex_address(module.load_address)
			or parse_hex_address(module.base_address)
		if load_addr then
			local end_addr = parse_hex_address(module.end_address)
			if not end_addr then
				local size = parse_hex_address(module.size)
				if size then
					end_addr = load_addr + size
				end
			end
			module_bounds[#module_bounds + 1] =
				{ module = module, load_addr = load_addr, end_addr = end_addr }
		end
	end
	local covering_modules = {}
	for _, addr in ipairs(frame_addresses) do
		local claimed_by_range = false
		-- First, an explicit [load, end) range claims the PC exactly.
		for _, b in ipairs(module_bounds) do
			if b.end_addr and addr >= b.load_addr and addr < b.end_addr then
				covering_modules[b.module] = true
				claimed_by_range = true
			end
		end
		-- Otherwise fall back to the nearest-preceding address-only module: the
		-- greatest load_address <= PC among modules with no explicit upper bound.
		if not claimed_by_range then
			local best = nil
			for _, b in ipairs(module_bounds) do
				if not b.end_addr and b.load_addr <= addr then
					if best == nil or b.load_addr > best.load_addr then
						best = b
					end
				end
			end
			if best ~= nil then
				covering_modules[best.module] = true
			end
		end
	end
	local function is_referenced(module)
		return (non_empty(module.id) and referenced[trim(module.id)])
			or (non_empty(module.name) and referenced[trim(module.name)])
			or covering_modules[module]
			or false
	end
	-- Two passes, both in original order: referenced modules first, then the rest,
	-- stopping at the budget.
	local kept = {}
	for _, module in ipairs(event.modules) do
		if #kept >= max_modules then
			break
		end
		if is_referenced(module) then
			kept[#kept + 1] = module
		end
	end
	for _, module in ipairs(event.modules) do
		if #kept >= max_modules then
			break
		end
		if not is_referenced(module) then
			kept[#kept + 1] = module
		end
	end
	event.modules = kept
	return event
end

-- A native instruction address can only be resolved against a loaded module map.
-- When no modules remain (none were supplied, or every entry was dropped as
-- unusable), a bare address has nothing to resolve against — the same
-- unattributed-address situation as a dropped referenced module. Clearing the
-- address here lets a frame that still carries a function symbol ship as a
-- symbolic frame, and drops a frame whose only identity was that now-unresolvable
-- address, rather than rejecting the WHOLE report. This keeps a fatal whose stack
-- still has at least one clean (symbolic or raw_text) entry from being dropped
-- over an optional native locator that cannot be resolved.
local function drop_unresolvable_addresses(event)
	if type(event.modules) == "table" and #event.modules > 0 then
		return event
	end
	if type(event.threads) ~= "table" then
		return event
	end
	for _, thread in ipairs(event.threads) do
		if type(thread.frames) == "table" then
			local kept_frames = {}
			for _, frame in ipairs(thread.frames) do
				frame.instruction_addr = ""
				frame.address = ""
				-- Keep the frame only if it still has a usable identity (a function
				-- symbol). A frame whose only identity was the unresolvable address is
				-- dropped rather than failing the whole report.
				if non_empty(frame["function"]) then
					kept_frames[#kept_frames + 1] = frame
				end
			end
			thread.frames = kept_frames
		end
	end
	return event
end

-- A process with many threads can exceed the per-report thread budget. Rejecting
-- the whole report would lose a fatal whose crashed thread is perfectly valid, so
-- instead SELECT a within-budget subset, always KEEPING the crashed thread (it
-- carries the actionable stack) and filling the remaining slots with the earliest
-- other threads in their original order. The crashed thread is identified by its
-- own `crashed` flag or by the event's crashed_thread_id. This runs BEFORE the
-- frame-budget pass so that pass sees only the threads that actually ship.
local function truncate_threads(event)
	if type(event.threads) ~= "table" or #event.threads <= max_threads then
		return event
	end
	local crashed_thread_id = non_empty(event.exception and event.exception.crashed_thread_id)
		and trim(event.exception.crashed_thread_id) or nil
	local crashed_thread = nil
	for _, thread in ipairs(event.threads) do
		if thread.crashed
			or (crashed_thread_id ~= nil and non_empty(thread.id)
				and trim(thread.id) == crashed_thread_id) then
			crashed_thread = thread
			break
		end
	end
	local kept = {}
	if crashed_thread then
		kept[#kept + 1] = crashed_thread
	end
	for _, thread in ipairs(event.threads) do
		if #kept >= max_threads then
			break
		end
		if thread ~= crashed_thread then
			kept[#kept + 1] = thread
		end
	end
	event.threads = kept
	return event
end

-- Fill in thread ids / frame indices and pick the crashed thread (mirrors
-- normalizeEventShape). The shared frame budget is NOT enforced here: it is enforced
-- AFTER the sanitize pass drops PII-only frames, so an over-budget stack whose top
-- frames scrub away does not have its clean tail frames truncated off before the
-- scrubber runs (which could leave the report with no usable stack and drop a fatal).
local function normalize_event_shape(event)
	if type(event.threads) == "table" then
		for i, thread in ipairs(event.threads) do
			if not non_empty(thread.id) then
				thread.id = tostring(i - 1)
			end
			if type(thread.frames) == "table" then
				for j, frame in ipairs(thread.frames) do
					-- frame.index is a non-negative integer position. A non-number value
					-- (a string, including PII), a fractional value (1.5), or a negative
					-- value (-1) is schema-invalid and must never reach the wire: treat
					-- any such value as missing and stamp the positional index instead.
					-- This is an optional positional hint, so a bad value is normalized
					-- rather than allowed to reach the wire as-is.
					local index = frame.index
					if type(index) ~= "number" or index < 0 or index ~= math.floor(index) then
						frame.index = j - 1
					end
				end
			end
		end
	end
	-- Pick (or repoint) the crashed-thread pointer. The fallback applies both when
	-- no id is supplied AND when a supplied id is stale — it points at no thread in
	-- this report (the caller passed a thread id that was truncated away, or a value
	-- that never matched any thread). A dangling pointer would leave the crashed
	-- stack unaddressable, so in either case fall back to the thread whose `crashed`
	-- flag is set, else the first thread, so the crashed stack is always addressable.
	if type(event.threads) == "table" then
		local supplied = non_empty(event.exception.crashed_thread_id)
			and trim(event.exception.crashed_thread_id) or nil
		local matches_thread = false
		if supplied ~= nil then
			for _, thread in ipairs(event.threads) do
				if non_empty(thread.id) and trim(thread.id) == supplied then
					matches_thread = true
					break
				end
			end
		end
		if supplied == nil or not matches_thread then
			for _, thread in ipairs(event.threads) do
				if thread.crashed then
					event.exception.crashed_thread_id = thread.id
					return event
				end
			end
			if #event.threads > 0 then
				event.threads[1].crashed = true
				event.exception.crashed_thread_id = event.threads[1].id
			end
		end
	end
	return event
end

-- Scrub every caller-populated string under the appropriate tier. A frame
-- `function` is a CODE SYMBOL (from auto-capture OR a manual emit) and gets the
-- symbol-aware scrub so a normal symbol like "game.player.update" survives;
-- genuine free-text fields (exception reason, breadcrumb message, raw text) are
-- full-scrubbed.
function M.sanitize_event(event, trusted_frame_functions, fatal)
	local cloned, clone_err = clone_event(event)
	if not cloned then
		return nil, clone_err
	end
	event = cloned
	-- A crash_id is best-effort caller input. Trim it; if it neither looks like a
	-- UUID nor is a plain safe token (or it carries disallowed identifier
	-- material), replace it with a generated UUIDv7. A fatal crash is NEVER
	-- dropped over a bad crash_id.
	event.crash_id = M.normalize_crash_id(event.crash_id)
	-- app.id is operator-set product scope from the trusted config, NOT a raw
	-- actor id. The full free-text scrub would blank a legitimate product scope
	-- whose slug happens to begin with an actor-style prefix ("user_app",
	-- "customer_portal") — which fails app_id_required and DROPS every report,
	-- including a fatal. Scrub it with the structured tier so such a scope
	-- survives, while an embedded email / IP / token / digit-bearing raw id is
	-- still removed. An app_id that would still scrub empty is rejected up front at
	-- config time (crash.new), so a fatal is never dropped over it here.
	event.app.id = sanitize.sanitize_structured(event.app.id)
	-- app.version / app.build come from the trusted config, not caller free-text:
	-- scrub them with the version-aware rule so a common 4-part version like
	-- "1.2.3.4" survives instead of being blanked as an IP literal, while an
	-- email / raw identifier / token in this field is still rejected.
	event.app.version = sanitize.sanitize_version(event.app.version)
	event.app.build_id = sanitize.sanitize_version(event.app.build_id)
	-- source is an operator-set component slug; scrub it like the other
	-- identifiers so a misconfigured value carrying PII never leaves the process.
	-- A per-report source that is non-empty but scrubs to empty (it carried
	-- disallowed content such as a raw identifier or an email) is INVALID input,
	-- not a bare-app report: it must not silently become a bare app. For a
	-- non-fatal report this is rejected (invalid_source) below; for a FATAL report
	-- the source is OMITTED and the crash is STILL SENT (a fatal crash is never
	-- dropped over a bad source).
	local source_before_scrub = trim(event.source)
	-- A source that already matches the component-slug shape
	-- (^[a-z0-9][a-z0-9-]{0,62}$) is SAFE BY CONSTRUCTION: it contains only lowercase
	-- letters, digits, and hyphens — no "@"/dot/underscore/whitespace — so it cannot
	-- carry an email, an IP, a raw-id prefix, or a dotted token. Such a slug is kept
	-- verbatim, including a long (up to 63-char) one, which the free-text scrub's
	-- long-opaque-run rule would otherwise blank — wrongly rejecting a non-fatal
	-- report and silently dropping the source dimension from a fatal. Anything that is
	-- NOT already a valid slug still goes through the full PII scrub below.
	if M.valid_source(source_before_scrub) then
		event.source = source_before_scrub
	else
		event.source = sanitize.sanitize_string(event.source)
	end
	-- A per-report source is INVALID when it was non-empty but either scrubbed to
	-- empty (it carried disallowed content) or does not match the component-slug
	-- shape. Such input must not silently become a bare-app report.
	if source_before_scrub ~= ""
		and (event.source == "" or not M.valid_source(event.source)) then
		if fatal then
			-- Omit the bad source and keep going: the fatal crash must reach the wire.
			event.source = ""
		else
			return nil, "invalid_source"
		end
	end
	event.platform = sanitize.sanitize_string(event.platform)
	event.os.name = sanitize.sanitize_string(event.os.name)
	event.os.version = sanitize.sanitize_string(event.os.version)
	-- exception.type is a package-qualified class name (a structured code
	-- identifier), not free text: scrub it with the exception-type rule so a
	-- dotted name like "java.lang.RuntimeException" survives instead of being
	-- blanked as a dotted-token credential — which would fail validation and drop
	-- the crash — while an email / raw identifier / IP in this field is still removed.
	event.exception.type = sanitize.sanitize_exception_type(event.exception.type)
	event.exception.reason = sanitize.sanitize_string(event.exception.reason)
	-- Capture the crashed-thread id BEFORE scrubbing it: a thread id that scrubs to
	-- empty (it carried disallowed content) gets a positional default reassigned in
	-- the thread loop below, and the crashed-thread pointer must be repointed to that
	-- default so the crashed thread stays identified instead of dropping the fatal.
	local crashed_thread_id_before = trim(event.exception.crashed_thread_id)
	event.exception.crashed_thread_id = sanitize.sanitize_string(event.exception.crashed_thread_id)
	-- raw_text is the native crash trace / traceback — full of code symbols
	-- ("::"-qualified scopes, dotted class names, dotted call paths), not prose.
	-- Scrub it with the structured tier: the full free-text scrub would read a
	-- symbol like Player::Update (a "::" misread as an IPv6 literal) or
	-- java.lang.RuntimeException (a dotted name misread as a token) and blank the
	-- whole field. A frame-less fatal crash relies entirely on raw_text, so
	-- blanking it would fail frames_or_raw_text_required and DROP the crash. The
	-- structured tier still removes a real email / IP / token / digit-bearing raw
	-- id embedded in the trace.
	event.raw_text = sanitize.sanitize_raw_text(event.raw_text)

	-- A context.session_id carrying disallowed identifier material poisons the
	-- whole event: reject rather than ship.
	if type(event.context) == "table" then
		local session_id = event.context.session_id
		if type(session_id) == "string" and sanitize.contains_disallowed_content(session_id) then
			return nil, "context_session_id_disallowed"
		end
	end

	-- Known identity keys never belong in the free-form caller device, context, or
	-- metadata maps. A clean (UUID-shaped) session_id/anonymous_id/user_id/device_id
	-- would otherwise pass the value scrub and reach the wire as a raw actor
	-- identifier. Strip the identity keys from all three caller maps before they are
	-- scrubbed/assigned. (device.class is not an identity key and survives.)
	event.device = strip_identity_keys(event.device)
	event.context = strip_identity_keys(event.context)
	event.metadata = strip_identity_keys(event.metadata)

	event.device = sanitize.sanitize_string_map(event.device)
	-- device.class is OPTIONAL metadata constrained to a known set. A value outside
	-- that set ("mobile", "handheld") is not the crash and must not reject the whole
	-- report: drop the field so the device block ships without it rather than failing
	-- validation. An empty/missing class is already omitted downstream.
	if type(event.device) == "table" then
		local class = event.device.class
		if non_empty(class) and not device_classes[trim(class)] then
			event.device.class = nil
		end
	end
	event.context = sanitize.sanitize_string_map(event.context)
	event.metadata = sanitize.sanitize_string_map(event.metadata)

	if type(event.modules) == "table" then
		for _, module in ipairs(event.modules) do
			-- Module ids, build/debug ids, and load/base/end addresses are structured
			-- identifiers (hex or base64 build hashes / addresses), not free text. Scrub
			-- them with the structured tier so the free-text long-opaque-run rule never
			-- blanks a legitimate 40-char build id (which would fail
			-- module_debug_id_required and drop the whole native crash).
			module.id = sanitize.sanitize_structured(module.id)
			-- A module name is a structured identifier — a reverse-DNS package name
			-- ("com.company.game") or a library/binary name — not free text. Scrub it
			-- with the structured tier so a dotted package name survives (the full
			-- free-text scrub would read it as a dotted-token credential and blank it,
			-- failing module_name_required and dropping the whole crash) while an
			-- embedded email / raw id / IP / real token is still removed.
			module.name = sanitize.sanitize_structured(module.name)
			module.platform = sanitize.sanitize_string(module.platform)
			module.debug_id = sanitize.sanitize_structured(module.debug_id)
			module.build_id = sanitize.sanitize_structured(module.build_id)
			module.load_address = sanitize.sanitize_structured(module.load_address)
			module.base_address = sanitize.sanitize_structured(module.base_address)
			module.end_address = sanitize.sanitize_structured(module.end_address)
			module.size = sanitize.sanitize_string(module.size)
		end
	end

	if type(event.threads) == "table" then
		for i, thread in ipairs(event.threads) do
			local thread_id_before = trim(thread.id)
			thread.id = sanitize.sanitize_string(thread.id)
			-- A thread id carrying disallowed content (e.g. "user_123") scrubs to empty.
			-- An empty thread id would fail thread_id_required and DROP an otherwise-clean
			-- fatal, so reassign the positional default (the same id normalize_event_shape
			-- would have stamped) instead of dropping the report. If the crashed-thread
			-- pointer referenced this thread's pre-scrub id (or was itself blanked), repoint
			-- it to the new positional id so the crashed thread stays identified.
			if not non_empty(thread.id) then
				thread.id = tostring(i - 1)
				if not non_empty(event.exception.crashed_thread_id)
					or (thread_id_before ~= "" and crashed_thread_id_before == thread_id_before) then
					event.exception.crashed_thread_id = thread.id
				end
			end
			thread.name = sanitize.sanitize_string(thread.name)
			if type(thread.frames) == "table" then
				-- A frame whose only identity (its function symbol) scrubbed away to PII
				-- must not reject the WHOLE report as frame_unidentified and drop even a
				-- fatal: such a frame is DROPPED here, keeping the report's other clean
				-- frames (and raw_text) so the crash still ships. Build a filtered list as
				-- we scrub; only a frame with a usable identity (a non-empty function or a
				-- non-empty address) is retained.
				local kept_frames = {}
				for _, frame in ipairs(thread.frames) do
					frame.module_id = sanitize.sanitize_structured(frame.module_id)
					-- A per-frame module / module_name is the same structured identifier
					-- class as a top-level module name (a reverse-DNS package or binary
					-- name), so route both through the structured tier rather than the
					-- full free-text scrub, which would blank a legitimate dotted name.
					frame.module = sanitize.sanitize_structured(frame.module)
					frame.module_name = sanitize.sanitize_structured(frame.module_name)
					frame.instruction_addr = sanitize.sanitize_structured(frame.instruction_addr)
					frame.address = sanitize.sanitize_structured(frame.address)
					-- `address` is an accepted alias for `instruction_addr`. The wire body
					-- carries instruction_addr only, so the alias is always normalized away:
					--   * alias-only frame: promote address into instruction_addr so the
					--     server gets a resolvable address;
					--   * both present: instruction_addr is canonical, so drop the alias —
					--     leaving a stale/divergent address on the wire would otherwise ship
					--     a second, possibly non-hex, address the server should never see.
					-- Either way frame.address is cleared once instruction_addr is set.
					if non_empty(frame.instruction_addr) then
						frame.address = ""
					elseif non_empty(frame.address) then
						frame.instruction_addr = frame.address
						frame.address = ""
					end
					-- The wire address must be a hex address (^0x?[0-9a-fA-F]+$), the shape
					-- the server resolves against the module map. A non-empty but non-hex
					-- value would otherwise fail validation and reject the WHOLE report,
					-- dropping even a fatal whose other frames are clean. The address is an
					-- OPTIONAL native locator, not the crash itself, so clear a non-hex value
					-- here instead: a frame that still has a function symbol ships as a
					-- symbolic frame, and a frame whose only identity was the bad address is
					-- dropped by the identity check below.
					if non_empty(frame.instruction_addr)
						and not looks_like_hex_address(frame.instruction_addr) then
						frame.instruction_addr = ""
					end
					frame.relative_addr = sanitize.sanitize_string(frame.relative_addr)
					-- A frame function is a code symbol, not free text, whether the frame
					-- came from auto-capture or a manual emit. Scrub it with the
					-- symbol-aware tier so a normal symbol like "game.player.update" or a
					-- "::"-qualified name survives (the full free-text scrub would read it
					-- as a dotted token and blank it, leaving the frame unidentified and
					-- dropping the whole crash), while an embedded email/IP is still removed.
					frame["function"] = sanitize.sanitize_function_name(frame["function"], trusted_frame_functions)
					-- A frame file is a structured source path
					-- ("Source/UI/user_interface.cpp"). Scrub it with the path-aware tier:
					-- it redacts a user-home username segment and rejects an embedded
					-- email / IP / real token, but does NOT apply the raw-id rule to path
					-- segments (a "user_interface" directory is not a raw actor id), so a
					-- normal source path survives.
					frame.file = sanitize.sanitize_file(frame.file)
					-- A line number is meaningful only as a non-negative INTEGER. A
					-- non-number, a negative, or a fractional value (42.5) is not a real
					-- line, so drop the optional field rather than serialize it — the same
					-- normalization frame.index already gets.
					if type(frame.line) ~= "number" or frame.line < 0
						or frame.line ~= math.floor(frame.line) then
						frame.line = nil
					end
					-- Retain the frame only when it still has a usable identity: a
					-- non-empty function symbol OR a non-empty address (instruction_addr
					-- was promoted from the alias above). A frame whose only identity
					-- scrubbed to empty is dropped rather than failing the whole report.
					if non_empty(frame["function"]) or non_empty(frame.instruction_addr) then
						kept_frames[#kept_frames + 1] = frame
					end
				end
				thread.frames = kept_frames
			end
		end
	end

	-- Breadcrumbs: cap, then keep only those whose name survives the scrub.
	local kept = {}
	local source_breadcrumbs = cap_breadcrumbs(event.breadcrumbs)
	if type(source_breadcrumbs) == "table" then
		for _, breadcrumb in ipairs(source_breadcrumbs) do
			local name, ok = sanitize.sanitize_breadcrumb_name(breadcrumb.name)
			if ok then
				kept[#kept + 1] = {
					name = name,
					-- A caller-supplied breadcrumb timestamp is untrusted
					-- string input like the neighbor strings. Keep it only when it is
					-- a clean ISO-8601 instant; otherwise fall back to the event time
					-- so a malformed/PII-bearing value never reaches the wire.
					timestamp = sanitize_breadcrumb_timestamp(breadcrumb.timestamp, event.occurred_at),
					type = sanitize.sanitize_string(breadcrumb.type),
					category = sanitize.sanitize_string(breadcrumb.category),
					level = sanitize.sanitize_string(breadcrumb.level),
					message = sanitize.sanitize_string(breadcrumb.message),
				}
			end
		end
	end
	event.breadcrumbs = (#kept > 0) and kept or nil

	-- Fingerprint components are the caller's grouping key — typically code symbols
	-- (a package/class name like "java.lang.RuntimeException"). Scrub them with the
	-- structured tier so a dotted/qualified symbol survives as the grouping key
	-- rather than being blanked as a dotted token, while a real token / digit-bearing
	-- raw id / email / IP smuggled in is still removed.
	event.fingerprint_components = sanitize.sanitize_structured_array(event.fingerprint_components)
	-- Cap the grouping components to the budget rather than rejecting the whole
	-- report when a caller supplies too many. fingerprint_components is an OPTIONAL
	-- grouping hint, never the crash itself, so an over-long list must not drop a
	-- fatal — keep the leading components (the most significant for grouping) and
	-- drop the tail, mirroring the breadcrumb cap.
	if type(event.fingerprint_components) == "table"
		and #event.fingerprint_components > max_fingerprint_components then
		for i = #event.fingerprint_components, max_fingerprint_components + 1, -1 do
			event.fingerprint_components[i] = nil
		end
	end

	-- Select a within-budget thread subset (always keeping the crashed thread) rather
	-- than rejecting a report that carries more threads than the budget — a busy
	-- process can exceed it, and dropping the report would lose a valid fatal.
	truncate_threads(event)
	-- Drop module entries whose required fields scrubbed away or whose address is not
	-- a usable hex address, rather than rejecting the whole report over one bad entry.
	-- This also clears the address path of frames that referenced a dropped module.
	filter_invalid_modules(event)
	-- Select a within-budget module subset (referenced modules first) rather than
	-- rejecting a report that loaded more modules than the budget — a large native
	-- process can exceed it, and dropping the report would lose a valid fatal.
	truncate_modules(event)
	-- With no module map left to resolve against, a bare native address cannot be
	-- symbolicated: clear it (and drop a frame whose only identity it was) rather
	-- than rejecting a report whose remaining frames are clean.
	drop_unresolvable_addresses(event)
	-- Enforce the shared frame budget LAST — after the scrub dropped PII-only frames
	-- AND after the unresolvable address-only frames were dropped (a frame whose only
	-- identity was an address into a filtered-out module, or any address once no module
	-- map remains, does not ship). Capping last spends the budget on frames that
	-- actually reach the wire, so clean symbolic frames past the cap are not truncated
	-- ahead of address-only frames that were about to be discarded — which could
	-- otherwise leave a fatal with zero usable frames and drop it.
	truncate_frames(event)

	return event, nil
end

-- Strip empty strings to nil so optional fields are omitted from the wire (the
-- test JSON encoder, like Defold's json.encode, drops nil keys). Required-but-
-- absent fields are caught by validate, not here.
local function blank_to_nil(value)
	if value == "" then
		return nil
	end
	return value
end

local function compact_event(event)
	event.crash_id = blank_to_nil(event.crash_id)
	event.source = blank_to_nil(event.source)
	event.platform = blank_to_nil(event.platform)
	event.raw_text = blank_to_nil(event.raw_text)
	if type(event.app) == "table" then
		event.app.id = blank_to_nil(event.app.id)
		event.app.version = blank_to_nil(event.app.version)
		event.app.build_id = blank_to_nil(event.app.build_id)
	end
	if type(event.os) == "table" then
		event.os.name = blank_to_nil(event.os.name)
		event.os.version = blank_to_nil(event.os.version)
		if event.os.name == nil and event.os.version == nil then
			event.os = nil
		end
	end
	if type(event.modules) == "table" then
		for _, module in ipairs(event.modules) do
			module.id = blank_to_nil(module.id)
			module.platform = blank_to_nil(module.platform)
			module.debug_id = blank_to_nil(module.debug_id)
			module.build_id = blank_to_nil(module.build_id)
			module.load_address = blank_to_nil(module.load_address)
			module.base_address = blank_to_nil(module.base_address)
			module.end_address = blank_to_nil(module.end_address)
			module.size = blank_to_nil(module.size)
		end
	end
	if type(event.exception) == "table" then
		event.exception.type = blank_to_nil(event.exception.type)
		event.exception.reason = blank_to_nil(event.exception.reason)
		event.exception.crashed_thread_id = blank_to_nil(event.exception.crashed_thread_id)
	end
	if type(event.threads) == "table" then
		for _, thread in ipairs(event.threads) do
			thread.id = blank_to_nil(thread.id)
			thread.name = blank_to_nil(thread.name)
			if type(thread.frames) == "table" then
				for _, frame in ipairs(thread.frames) do
					frame.module_id = blank_to_nil(frame.module_id)
					frame.module = blank_to_nil(frame.module)
					frame.module_name = blank_to_nil(frame.module_name)
					frame.instruction_addr = blank_to_nil(frame.instruction_addr)
					frame.address = blank_to_nil(frame.address)
					frame.relative_addr = blank_to_nil(frame.relative_addr)
					frame["function"] = blank_to_nil(frame["function"])
					frame.file = blank_to_nil(frame.file)
				end
			end
		end
	end
	if type(event.breadcrumbs) == "table" then
		for _, breadcrumb in ipairs(event.breadcrumbs) do
			breadcrumb.type = blank_to_nil(breadcrumb.type)
			breadcrumb.category = blank_to_nil(breadcrumb.category)
			breadcrumb.level = blank_to_nil(breadcrumb.level)
			breadcrumb.message = blank_to_nil(breadcrumb.message)
		end
	end
	return event
end

-- Validate a sanitized event against the server's required-field rules.
-- Returns (true) or (false, error_code).
function M.validate_event(event)
	if not non_empty(event.crash_id) then
		return false, "crash_id_required"
	end
	if not non_empty(event.occurred_at) then
		return false, "occurred_at_required"
	end
	if type(event.app) ~= "table" or not non_empty(event.app.id) then
		return false, "app_id_required"
	end
	if not non_empty(event.platform) then
		return false, "platform_required"
	end
	if type(event.exception) ~= "table" or not non_empty(event.exception.type) then
		return false, "exception_type_required"
	end
	if not M.valid_source(event.source) then
		return false, "invalid_source"
	end

	local modules = event.modules or {}
	if #modules > max_modules then
		return false, "modules_exceeded"
	end
	for i, module in ipairs(modules) do
		if not non_empty(module.name) then
			return false, "module_name_required"
		end
		if not non_empty(module.debug_id) and not non_empty(module.build_id) then
			return false, "module_debug_id_required"
		end
		local module_address = first_non_empty(module.load_address, module.base_address)
		if module_address == "" then
			return false, "module_load_address_required"
		end
		-- The module's load/base address must be a hex address (^0x?[0-9a-fA-F]+$),
		-- the same shape the server resolves frame addresses against. A non-empty but
		-- non-hex value would otherwise be treated as a resolvable base; reject it
		-- locally with a clear error instead of dispatching it.
		if not looks_like_hex_address(module_address) then
			return false, "module_load_address_invalid"
		end
	end

	local threads = event.threads or {}
	if #threads > max_threads then
		return false, "threads_exceeded"
	end
	local frame_count = 0
	for _, thread in ipairs(threads) do
		if not non_empty(thread.id) then
			return false, "thread_id_required"
		end
		for _, frame in ipairs(thread.frames or {}) do
			frame_count = frame_count + 1
			if type(frame.line) == "number" and frame.line < 0 then
				return false, "frame_line_negative"
			end
			local has_function = non_empty(frame["function"])
			-- a frame address must be a hex address (^0x?[0-9a-fA-F]+$), the shape
			-- the server resolves against the module map. A non-empty but non-hex
			-- value ("nothex") would otherwise be treated as a resolvable address and
			-- dispatched; reject it locally with a clear error instead.
			local addr_value = first_non_empty(frame.instruction_addr, frame.address)
			local has_address = false
			if addr_value ~= "" then
				if not looks_like_hex_address(addr_value) then
					return false, "frame_address_invalid"
				end
				has_address = true
			end
			if not has_function and not has_address then
				return false, "frame_unidentified"
			end
			-- A native (address) frame requires a module map to resolve against.
			-- A module REFERENCE (module_id/module/module_name) is OPTIONAL per the
			-- wire contract for a stack frame: the server resolves an unattributed
			-- address against the loaded module map and records module_missing when
			-- it cannot disambiguate. This matters for
			-- the Defold native-dump path, where the engine exposes a flat backtrace
			-- with no per-frame module attribution.
			if has_address and #modules == 0 then
				return false, "frame_address_without_module"
			end
		end
	end
	if frame_count > max_stack_frames then
		return false, "stack_frames_exceeded"
	end
	if frame_count == 0 and not non_empty(event.raw_text) then
		return false, "frames_or_raw_text_required"
	end

	if type(event.breadcrumbs) == "table" and #event.breadcrumbs > max_breadcrumbs then
		return false, "breadcrumbs_exceeded"
	end
	if type(event.fingerprint_components) == "table"
		and #event.fingerprint_components > max_fingerprint_components then
		return false, "fingerprint_components_exceeded"
	end

	if type(event.device) == "table" then
		local class = event.device.class
		if non_empty(class) and not device_classes[class] then
			return false, "invalid_device_class"
		end
	end
	return true
end

-- Prepare a caller-supplied event for the wire: default app identity + source +
-- crash_id from client config (a per-event value always wins), normalize times
-- and shape, attach breadcrumbs, sanitize, and validate. Returns (event) or
-- (nil, error_code). `options.skip_breadcrumb_ring` suppresses attaching the
-- current breadcrumb ring: a previous-session dump carries no breadcrumbs of
-- its own, and the current ring belongs to THIS session — attaching it would
-- misattribute live breadcrumbs to the dead session's crash.
function M.prepare(client, event, trusted_frame_functions, options)
	local cloned, clone_err = clone_event(event)
	if not cloned then
		return nil, clone_err
	end
	event = cloned
	options = options or {}
	-- A FATAL crash must never be dropped over a bad per-report source: when fatal,
	-- an invalid source is omitted rather than rejected. A non-fatal report with an
	-- invalid source is rejected with invalid_source.
	local fatal = options.fatal == true
	event.exception = event.exception or {}
	event.app = event.app or {}
	event.os = event.os or {}
	event.crash_id = trim(event.crash_id)

	-- App identity is product scope from the TRUSTED client config, never caller
	-- free-text. Always stamp the configured app_id, overriding any caller-provided
	-- event.app.id: the crash key is scoped to the configured app, so a stale or
	-- mismatched per-report app id would send under the wrong scope or be rejected.
	event.app.id = client.config.app_id
	if not non_empty(event.app.version) then
		event.app.version = client.config.app_version
	end
	if not non_empty(event.app.build_id) then
		event.app.build_id = client.config.app_build
	end
	-- A per-report source is an operator-set component slug, so it must be a string.
	-- A non-string, non-nil value (e.g. a number) is invalid caller input, NOT an
	-- absent source: it must not silently inherit the configured default and
	-- misattribute the crash. A non-fatal report with such a value is rejected with
	-- invalid_source; a fatal report omits the bad source and is STILL SENT, bare,
	-- without inheriting the configured default (a fatal crash is never dropped over a
	-- bad source). A genuinely absent (nil/empty) source falls back to the configured
	-- default below.
	local source_omitted_for_fatal = false
	if event.source ~= nil and type(event.source) ~= "string" then
		if fatal then
			event.source = nil
			source_omitted_for_fatal = true
		else
			return nil, "invalid_source"
		end
	end
	if not source_omitted_for_fatal and not non_empty(event.source) then
		event.source = client.config.crash_source
	end
	if not non_empty(event.platform) then
		event.platform = client.config.platform
	end
	if event.crash_id == "" then
		event.crash_id = id.uuid_v7()
	end

	-- Attach the breadcrumb ring snapshot when the caller supplied none — unless
	-- this is the previous-session dump-forward path, whose breadcrumbs are
	-- unavailable: the current ring belongs to a different (live) session.
	if (type(event.breadcrumbs) ~= "table" or #event.breadcrumbs == 0)
		and client.breadcrumbs and not options.skip_breadcrumb_ring then
		event.breadcrumbs = client.breadcrumbs:snapshot()
	else
		event.breadcrumbs = cap_breadcrumbs(event.breadcrumbs)
	end

	event = normalize_event_times(event)
	event = normalize_event_shape(event)

	local sanitized, sanitize_err = M.sanitize_event(event, trusted_frame_functions, fatal)
	if not sanitized then
		return nil, sanitize_err
	end
	-- A per-event platform that scrubbed to empty (it carried disallowed content) must
	-- not drop the report over platform_required: fall back to the configured platform,
	-- which is validated to scrub non-empty at crash.new(). Re-scrub it so only a clean
	-- value reaches the wire. This keeps a fatal from being dropped over a bad per-event
	-- platform while still removing the disallowed per-event value.
	if not non_empty(sanitized.platform) then
		sanitized.platform = sanitize.sanitize_string(client.config.platform)
	end
	local ok, validate_err = M.validate_event(sanitized)
	if not ok then
		return nil, validate_err
	end
	return compact_event(sanitized)
end

return M
