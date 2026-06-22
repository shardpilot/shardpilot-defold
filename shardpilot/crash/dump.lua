-- Best-effort auto-capture of a PREVIOUS-SESSION native crash.
--
-- A native engine crash (SIGSEGV/SIGABRT) in Defold is NOT recoverable in Lua:
-- the process is already dead, so there is no in-process hook to run. Defold
-- instead writes a
-- native crash dump to disk via its built-in `crash` module, which the NEXT
-- launch reads with crash.load_previous(). So the Defold auto-capture model is
-- LOAD-ON-NEXT-LAUNCH, documented in docs/crash.md.
--
-- This module reads that one-shot dump (load_previous removes it from disk on a
-- successful load) and converts it into a NATIVE crash event: address-only
-- frames (instruction_addr) resolved against the loaded module map, plus os /
-- exception metadata. There is no source-side symbolication; the server
-- resolves addresses against the module map. LIMITS (see docs/crash.md): no
-- per-frame module attribution from
-- the engine (the dump exposes a flat backtrace + a module list), no
-- breadcrumbs from the dead session, and capture depends on the platform's
-- native dump writer being available.
local M = {}

-- Map a POSIX-ish signal number to a stable, human-readable exception type. An
-- unknown signal falls back to "signal_<n>". These are not PII.
local signal_names = {
	[4] = "SIGILL",
	[6] = "SIGABRT",
	[7] = "SIGBUS",
	[8] = "SIGFPE",
	[11] = "SIGSEGV",
}

local function signal_to_type(signum)
	if type(signum) ~= "number" then
		return "native_crash"
	end
	return signal_names[signum] or ("signal_" .. tostring(math.floor(signum)))
end

-- Normalize an address to the 0x-prefixed lowercase hex the wire schema requires
-- (^0x[0-9a-fA-F]+$). Accepts a number or an already-formatted string; returns
-- nil for anything unusable.
local function to_hex_address(value)
	if type(value) == "number" then
		if value < 0 then
			return nil
		end
		return string.format("0x%x", math.floor(value))
	end
	if type(value) ~= "string" then
		return nil
	end
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	if value == "" then
		return nil
	end
	if value:match("^0[xX]%x+$") then
		return "0x" .. value:sub(3):lower()
	end
	if value:match("^%x+$") then
		return "0x" .. value:lower()
	end
	return nil
end

-- Read a sys-field from the dump without ever raising (the crash module field
-- may be absent on a given platform).
local function read_sys_field(crash_module, handle, field)
	if field == nil then
		return nil
	end
	local ok, value = pcall(crash_module.get_sys_field, handle, field)
	if ok and type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

-- Build the modules[] from the dump's module list. Each module carries a name +
-- a base load address; the engine does not expose debug ids, so debug_id is set
-- to the module name as a stable reference (the server requires debug_id OR
-- build_id and a load/base address). Modules without a usable address are
-- dropped.
local function build_modules(crash_module, handle)
	local ok, raw = pcall(crash_module.get_modules, handle)
	if not ok or type(raw) ~= "table" then
		return {}
	end
	local modules = {}
	for _, entry in ipairs(raw) do
		if type(entry) == "table" then
			local address = to_hex_address(entry.address)
			local name = entry.name
			if type(name) == "string" and name ~= "" and address then
				modules[#modules + 1] = {
					name = name,
					-- No debug id from the engine: use the module name as a stable
					-- reference so the server's debug_id-or-build_id rule is met.
					debug_id = name,
					load_address = address,
				}
			end
		end
	end
	return modules
end

-- Build the crashed thread's frames from the flat backtrace (a list of
-- instruction addresses). The engine does not attribute a frame to a specific
-- module, so frames carry no module_id; the server resolves the address
-- against the module map and records module_missing when ambiguous.
local function build_frames(crash_module, handle)
	local ok, raw = pcall(crash_module.get_backtrace, handle)
	if not ok or type(raw) ~= "table" then
		return {}
	end
	local frames = {}
	for _, entry in ipairs(raw) do
		local address
		if type(entry) == "table" then
			address = to_hex_address(entry.address or entry.pc or entry[1])
		else
			address = to_hex_address(entry)
		end
		if address then
			frames[#frames + 1] = {
				index = #frames,
				instruction_addr = address,
			}
		end
	end
	return frames
end

-- Convert a loaded dump handle into a crash event table (the same shape
-- crash/event.lua prepares). Returns nil when the dump has no usable backtrace
-- (an event with zero frames and no raw_text would fail validation, so there is
-- nothing to forward).
function M.event_from_handle(crash_module, handle)
	local modules = build_modules(crash_module, handle)
	local frames = build_frames(crash_module, handle)
	-- A native address frame requires at least one module to resolve against; if
	-- the dump carried a backtrace but no modules, there is nothing the server
	-- can symbolicate, so drop it rather than ship an unresolvable crash.
	if #frames == 0 or #modules == 0 then
		return nil
	end

	local signum
	local ok_sig, sig = pcall(crash_module.get_signum, handle)
	if ok_sig then
		signum = sig
	end

	local os_name = read_sys_field(crash_module, handle, crash_module.SYSFIELD_SYSTEM_NAME)
	local os_version = read_sys_field(crash_module, handle, crash_module.SYSFIELD_SYSTEM_VERSION)

	return {
		exception = {
			type = signal_to_type(signum),
			crashed_thread_id = "main",
		},
		os = {
			name = os_name,
			version = os_version,
		},
		modules = modules,
		threads = {
			{
				id = "main",
				crashed = true,
				frames = frames,
			},
		},
	}
end

-- Load a previous-session dump (if any) and convert it to a crash event,
-- releasing the handle afterward. Returns the event table, or nil when there is
-- no dump (or the runtime has no `crash` module / no usable dump). Never raises.
-- `crash_module` is injectable for testing; defaults to the global `crash`.
function M.load_previous_event(crash_module)
	crash_module = crash_module or _G.crash
	if type(crash_module) ~= "table" or type(crash_module.load_previous) ~= "function" then
		return nil
	end
	local ok, handle = pcall(crash_module.load_previous)
	if not ok or handle == nil then
		return nil
	end
	local built_ok, event = pcall(M.event_from_handle, crash_module, handle)
	if type(crash_module.release) == "function" then
		pcall(crash_module.release, handle)
	end
	if not built_ok then
		return nil
	end
	return event
end

return M
