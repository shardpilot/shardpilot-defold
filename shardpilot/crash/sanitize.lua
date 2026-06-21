-- PII scrubbing for crash reports, consistent across our SDKs: no raw actor
-- identifiers, IPs, emails, or JWT-shaped tokens ever leave the process on the
-- wire.
--
-- Two scrub tiers:
--   * FULL content scrub (sanitize_string) for genuine free-text fields (an
--     exception reason, a breadcrumb message, raw text). Blanks emails, the
--     player_/user_/customer_/device_ raw-identifier prefixes, IPv4/IPv6
--     literals, and JWT-shaped dotted tokens.
--   * SYMBOL scrub (sanitize_symbol) for a frame `function` — whether it comes
--     from the auto-capture symbol table OR a manual caller-supplied frame. A
--     frame function is a CODE SYMBOL (package-qualified / "::"-qualified /
--     dotted), not free text, so it gets the symbol tier in both cases. The
--     symbol tier applies ONLY the email/IP signals that never legitimately
--     appear in a code symbol, so a normal symbol like "game.player.update" or
--     "Auth::user_id_from_token" survives — running it through the full scrub
--     would blank it as a dotted token and drop the whole crash — while an
--     embedded email/IP smuggled into the field is still removed.
local M = {}

local disallowed_prefixes = { "player_", "user_", "customer_", "device_" }

-- ^[A-Za-z][A-Za-z0-9_.:-]{0,127}$ — breadcrumb name shape (Lua patterns have no
-- bounded repetition, so the length is checked separately).
local function valid_breadcrumb_name(value)
	if not value:match("^[A-Za-z][A-Za-z0-9_.:-]*$") then
		return false
	end
	return #value <= 128
end

-- ^[A-Za-z][A-Za-z0-9_.:-]{0,63}$ — map key shape.
local function valid_map_key(value)
	if not value:match("^[A-Za-z][A-Za-z0-9_.:-]*$") then
		return false
	end
	return #value <= 64
end

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- An email ADDRESS shape: a local part, an "@", then a domain that has at least
-- one dot and a letter-only top-level label (alice@example.com,
-- player.one@example.co.uk). Matching the address SHAPE — not a bare "@" — keeps a
-- non-email "@" token from blanking the value: a raw-text-only fatal crash whose
-- traceback carries an HTML5/file URL after an "@" or an offset like "module@0x1234"
-- would otherwise be blanked, fail the frames-or-text requirement, and be DROPPED.
-- A genuine address like "alice@example.com" is still detected and removed.
local function contains_email(value)
	-- Scan each "@" and check the surrounding bytes form an address: at least one
	-- local-part char immediately before, and a dotted domain ending in a
	-- letters-only TLD of 2+ chars immediately after.
	for local_part, domain in value:gmatch("([%w%.%_%%%+%-]+)@([%w%.%-]+)") do
		-- The domain must contain a dot and end in a letter-only TLD (2+ letters),
		-- which a file path ("file:///...", a bare "0x1234" address) never does.
		-- Strip a trailing run of domain punctuation first so an address followed by
		-- sentence punctuation — "alice@example.com.", "...com,", "...com)" — still
		-- ends in a letter-only TLD. The "@" candidate domain only contains word
		-- chars, dots, and dashes, so the run to strip is dots and dashes.
		local trimmed_domain = domain:gsub("[%.%-]+$", "")
		local tld = trimmed_domain:match("%.([%a]+)$")
		if #local_part >= 1 and tld ~= nil and #tld >= 2 then
			return true
		end
	end
	return false
end

-- A user-home path leaks the OS account name in its second segment
-- ("/Users/alice/...", "/home/alice/...", "C:\Users\alice\..."). Replace just
-- that one username segment with a placeholder, preserving the rest of the path so
-- the file location stays useful. This redacts (never blanks) and is applied to
-- free-text fields only, not to a trusted code symbol / frame function. The match
-- is case-insensitive on the home-directory prefix.
local home_path_redaction = "<redacted>"

local function redact_home_paths(value)
	-- Build a case-insensitive char class for a literal ASCII word.
	local function ci(word)
		return (word:gsub("%a", function(ch)
			return "[" .. ch:upper() .. ch:lower() .. "]"
		end))
	end
	-- POSIX: "/Users/<name>/" and "/home/<name>/". Capture the home prefix (kept
	-- verbatim so its casing survives) and replace only the username segment, which
	-- runs up to the next slash. The trailing slash is preserved so the rest of the
	-- path stays. The username segment is also redacted when it ends at the end of
	-- the value (no trailing slash) so a path that stops at the account name —
	-- "/home/alice" or "permission denied: /Users/alice" — does not leak the name.
	local function redact_posix(text, root)
		-- Username followed by another path component: keep the trailing slash.
		text = text:gsub("(/" .. root .. "/)[^/]+/", "%1" .. home_path_redaction .. "/")
		-- Username ending at a non-path boundary (end of value or a non-name char
		-- such as whitespace, a colon, a quote): redact and preserve that boundary.
		-- "<" and ">" are excluded from the segment so the just-inserted placeholder
		-- is never re-matched and re-redacted.
		text = text:gsub("(/" .. root .. "/)[^/%s:;,'\"%)%]<>]+", "%1" .. home_path_redaction)
		return text
	end
	value = redact_posix(value, ci("Users"))
	value = redact_posix(value, ci("home"))
	-- Windows: "<drive>:\Users\<name>\" — backslash separators, case-insensitive.
	local function redact_windows(text)
		text = text:gsub("(%a:\\" .. ci("Users") .. "\\)[^\\]+\\", "%1" .. home_path_redaction .. "\\")
		text = text:gsub("(%a:\\" .. ci("Users") .. "\\)[^\\%s:;,'\"%)%]<>]+", "%1" .. home_path_redaction)
		return text
	end
	value = redact_windows(value)
	return value
end

-- The whole value is a bare raw-identifier token: a disallowed prefix followed
-- only by identifier characters and nothing else (e.g. "user_abc", "player_42",
-- "device_42af"). This is a raw actor id, not prose — a value with whitespace or
-- other words ("user_id is null", "device_token expired") is NOT matched here and
-- is left to the embedded-id rule below.
local function is_bare_disallowed_id(value)
	local lowered = value:lower():gsub("^%s+", ""):gsub("%s+$", "")
	for _, prefix in ipairs(disallowed_prefixes) do
		if lowered:sub(1, #prefix) == prefix then
			local rest = lowered:sub(#prefix + 1)
			-- A bare identifier: the remainder is identifier-shaped (alphanumerics,
			-- underscores, dots, dashes, colons) with no whitespace or other words.
			if rest:match("^[%w_%.:%-]*$") then
				return true
			end
		end
	end
	return false
end

-- A disallowed prefix appearing at a TOKEN BOUNDARY (start-of-string or right
-- after a non-identifier character) and followed by AT LEAST ONE identifier
-- character, matched ANYWHERE in the value, is a raw identifier embedded in
-- free-form text (e.g. "failed for user_123", "player_abc123", "login failed for
-- user_alice", "the device_token expired", "customer_acme-42"). The aggressive
-- rule treats any such token-boundary prefix+continuation as a raw actor id and
-- blanks the value. A prefix that is NOT at a token boundary ("multiuser_mode")
-- is part of a larger word and survives. The identifier continuation includes the
-- hyphen / dot / colon separators that appear in real identifier suffixes
-- (player_ab-12, user_ab.12) so a separated suffix is still caught.
local function is_identifier_char(ch)
	return ch ~= "" and ch:match("[%w_%.:%-]") ~= nil
end

local function embeds_disallowed_id(value)
	local lowered = value:lower()
	for _, prefix in ipairs(disallowed_prefixes) do
		-- Plain (non-pattern) search for the literal prefix, then check that it sits
		-- at a token boundary (nothing identifier-shaped immediately before it) and is
		-- followed by at least one identifier-continuation char. Repeat from just past
		-- the match so a later occurrence is still found.
		local from = 1
		while true do
			local start_pos, end_pos = lowered:find(prefix, from, true)
			if not start_pos then
				break
			end
			local before = start_pos > 1 and lowered:sub(start_pos - 1, start_pos - 1) or ""
			local after = lowered:sub(end_pos + 1, end_pos + 1)
			-- Token boundary: the char before the prefix is not an identifier char (so
			-- the prefix begins a fresh token, not the tail of a longer word like
			-- "multiuser_"). The char after the prefix must be an identifier char (so a
			-- raw id actually follows the prefix).
			if not is_identifier_char(before) and is_identifier_char(after) then
				return true
			end
			from = start_pos + 1
		end
	end
	return false
end

-- An IPv4 dotted quad anywhere in the value, each octet 0-255, not part of a
-- longer number run on either side.
local function contains_ipv4(value)
	local function octet_ok(o)
		local n = tonumber(o)
		return n ~= nil and n >= 0 and n <= 255
	end
	-- Scan every dotted-quad candidate; verify boundaries and octet ranges.
	for prefix, a, b, c, d, suffix in
		value:gmatch("()(%d+)%.(%d+)%.(%d+)%.(%d+)()") do
		local before = prefix > 1 and value:sub(prefix - 1, prefix - 1) or ""
		local after = value:sub(suffix, suffix)
		if not before:match("%d") and not after:match("%d") then
			if octet_ok(a) and octet_ok(b) and octet_ok(c) and octet_ok(d) then
				return true
			end
		end
	end
	return false
end

-- A conservative IPv6 detector: a run of hex/colon that is either "::"-compressed
-- or carries at least three NON-EMPTY hextet groups, every group a valid hextet.
-- Crash addresses are written as 0x-prefixed hex (no colons), so this never trips
-- on a legitimate instruction address. Counting only NON-EMPTY groups is
-- deliberate: an ordinary error/traceback fragment like "main.script:42:" has
-- empty colon-separated groups (":42:" -> "", "42", "") and must NOT be read as
-- an IPv6 literal, or a fatal crash reported as raw traceback text would have its
-- text blanked and be dropped.
-- `require_literal_boundary`, set ONLY by the symbol tier, additionally requires
-- a "::"-compressed candidate to sit at a token boundary (no identifier char
-- immediately before or after the run of hex/colon) to count as an IPv6 literal.
-- A genuine literal like "fe80::1" always stands as its own token, whereas the
-- "::" in a C++/Defold scope-qualified code symbol ("Auth::user_id_from_token",
-- "pkg::Type::method") is wedged between identifier letters. The full free-text
-- scrub never sets this, so its IPv6 detection is unchanged — this only stops a
-- legitimate "::"-qualified frame function from being blanked (which would drop
-- the whole crash).
local function contains_ipv6(value, require_literal_boundary)
	for prefix, raw_candidate, suffix in value:gmatch("()([0-9A-Fa-f:%.]+)()") do
		local candidate = raw_candidate:gsub("^[%[%(]+", ""):gsub("[%]%),;]+$", "")
		if candidate:find(":", 1, true) then
			-- "::" compression is the unambiguous IPv6 signal.
			if candidate:find("::", 1, true) then
				if not require_literal_boundary then
					return true
				end
				-- Symbol tier: only a "::" run that stands as its own token (bounded by
				-- non-identifier characters) is a real IPv6 literal. A "::" wedged
				-- between identifier letters is scope-resolution in a code symbol.
				local before = prefix > 1 and value:sub(prefix - 1, prefix - 1) or ""
				local after = value:sub(suffix, suffix)
				local id_before = before ~= "" and before:match("[%w_]") ~= nil
				local id_after = after ~= "" and after:match("[%w_]") ~= nil
				if not id_before and not id_after then
					return true
				end
			else
				-- Otherwise require >=3 NON-EMPTY groups, each a valid hextet (or a
				-- trailing IPv4 tail), AND a genuine IPv6 signal. A purely-numeric colon
				-- run like a log time "12:34:56" is hextet-shaped but is NOT an IPv6
				-- literal, so blanking it would drop a raw-text-only fatal crash whose
				-- traceback carries a timestamp. The genuine signal is one of: a group
				-- containing a hex LETTER (a-f), or the full 8-group address form ("::"
				-- compression was already handled above). Any non-empty group that is not
				-- a hextet disqualifies the whole candidate.
				local hextet_groups = 0
				local all_hex = true
				local has_hex_letter = false
				for group in (candidate .. ":"):gmatch("([^:]*):") do
					if group ~= "" then
						if group:match("^[0-9A-Fa-f]+$") or group:match("^%d+%.%d+%.%d+%.%d+$") then
							hextet_groups = hextet_groups + 1
							if group:match("[A-Fa-f]") then
								has_hex_letter = true
							end
						else
							all_hex = false
						end
					end
				end
				if all_hex and hextet_groups >= 3 and (has_hex_letter or hextet_groups >= 8) then
					return true
				end
			end
		end
	end
	return false
end

-- A JWT-shaped (or generic dotted-secret) token: three base64url segments of >=4
-- chars each. A package-qualified symbol like
-- pkg.Type.method is also three dotted segments, so this signal is applied ONLY
-- by the FULL scrub, never the symbol/structured scrub.
local function contains_jwt(value)
	-- Find a.b.c where each part is [A-Za-z0-9_-]{4,} and not bordered by another
	-- token char (so an embedded credential is caught, a sentence is not).
	for prefix, token, suffix in
		value:gmatch("()([%w_%-]+%.[%w_%-]+%.[%w_%-]+)()") do
		local a, b, c = token:match("^([%w_%-]+)%.([%w_%-]+)%.([%w_%-]+)$")
		if a and #a >= 4 and #b >= 4 and #c >= 4 then
			local before = prefix > 1 and value:sub(prefix - 1, prefix - 1) or ""
			local after = value:sub(suffix, suffix)
			if not before:match("[%w_%-]") and not after:match("[%w_%-]") then
				return true
			end
		end
	end
	return false
end

-- A HIGH-CONFIDENCE secret/token, safe to run over a STRUCTURED diagnostic field
-- (a class name, a package/module name, a dotted breadcrumb name) without
-- blanking the legitimate dotted values those fields carry. Unlike the loose
-- contains_jwt above (>=4 chars per segment, which a normal dotted symbol trips),
-- this fires ONLY on:
--   * three-or-more dot-separated base64url segments where EACH segment is >= 16
--     chars (a real JWT header.payload.signature, never a readable class name like
--     java.lang.RuntimeException whose segments are short words), OR
--   * a single contiguous base64url run of >= 40 chars (a long opaque secret /
--     API key with no readable structure).
-- A readable qualified name (com.company.game, java.lang.RuntimeException,
-- level.load.done, a::b::c) has short, word-shaped segments and so is preserved.
local min_token_segment_len = 16
local min_long_secret_len = 40

-- A high-confidence JWT-shaped token: >=3 dot-separated base64url segments, each
-- long. Used by BOTH the full and structured tiers — a real JWT always carries the
-- two dots, while a readable qualified name (com.company.game, level.load.done) has
-- short word-shaped segments and is preserved.
local function contains_high_confidence_token(value)
	for prefix, run, suffix in value:gmatch("()([%w_%-]+%.[%w_%-][%w_%-%.]*)()") do
		local before = prefix > 1 and value:sub(prefix - 1, prefix - 1) or ""
		local after = value:sub(suffix, suffix)
		-- The run must be a whole token (not bordered by another base64url char),
		-- so an embedded credential is caught and a sentence fragment is not.
		if not before:match("[%w_%-%.]") and not after:match("[%w_%-%.]") then
			local segments = {}
			local all_long = true
			for seg in (run .. "."):gmatch("([^%.]*)%.") do
				segments[#segments + 1] = seg
				if #seg < min_token_segment_len then
					all_long = false
				end
			end
			if #segments >= 3 and all_long then
				return true
			end
		end
	end
	return false
end

-- A single long opaque secret: a contiguous base64url run of >= min_long_secret_len
-- chars with no dot separators (e.g. a raw API key). This is a FREE-TEXT-ONLY
-- signal: a legitimate STRUCTURED identifier — a 40-char SHA-1 build id, a long
-- mangled code symbol, a hex address — is also a single long dotless run, so
-- applying this to the structured tier would blank a real build id and DROP the
-- native crash. The structured tier therefore does NOT use it.
local function contains_long_opaque_run(value)
	for run in value:gmatch("[%w_%-]+") do
		if #run >= min_long_secret_len then
			return true
		end
	end
	return false
end

-- A DIGIT-BEARING raw identifier embedded at a SUB-TOKEN boundary: a disallowed
-- prefix (player_/user_/customer_/device_) that begins a fresh sub-token (it sits
-- at the start of the value or right after a separator — "_", ".", ":", "-", or
-- any non-alphanumeric) and is followed by a continuation that CONTAINS at least
-- one digit (handler_user_4242, user_42, customer_acme-99, auth.user_99). A
-- digit-free qualified word (user_id_from_token, user_session, player_state,
-- device_token) is NOT matched and is preserved, and a prefix glued to the middle
-- of a longer alphanumeric word ("multiuser_4242") is NOT a sub-token start and
-- is preserved too. This is the raw-id signal applied to STRUCTURED fields, where
-- a digit-free "user_"/"player_" word is legitimate code-symbol text but a
-- digit-bearing one is almost always a raw actor id.
local function embeds_digit_bearing_disallowed_id(value)
	local lowered = value:lower()
	for _, prefix in ipairs(disallowed_prefixes) do
		local from = 1
		while true do
			local start_pos, end_pos = lowered:find(prefix, from, true)
			if not start_pos then
				break
			end
			local before = start_pos > 1 and lowered:sub(start_pos - 1, start_pos - 1) or ""
			-- Sub-token boundary: the char before the prefix is start-of-string or a
			-- SEPARATOR (anything that is not a letter or digit). An underscore/dot/
			-- colon/dash before the prefix still starts a fresh sub-token, so
			-- "handler_user_4242" and "auth.user_99" are caught, while "multiuser_4242"
			-- (the prefix glued to the middle of an alphanumeric word) is not.
			if before == "" or before:match("[^%w]") then
				-- Walk the identifier continuation after the prefix; if any of its
				-- characters is a digit, this is a digit-bearing raw id.
				local i = end_pos + 1
				local saw_digit = false
				while i <= #lowered do
					local ch = lowered:sub(i, i)
					if not is_identifier_char(ch) then
						break
					end
					if ch:match("%d") then
						saw_digit = true
						break
					end
					i = i + 1
				end
				if saw_digit then
					return true
				end
			end
			from = start_pos + 1
		end
	end
	return false
end

-- STRUCTURED-FIELD check: the single scrub tier for structured diagnostic fields
-- (a frame function, a module / module.name, an exception type, a breadcrumb
-- name). It PRESERVES legitimate structured values — package-qualified /
-- "::"-qualified code symbols, reverse-DNS package names (com.company.game),
-- dotted class names (java.lang.RuntimeException), dotted breadcrumb names
-- (level.load.done) — while still blanking true PII/secrets. The signals are:
--   (a) embedded email / IPv4 / IPv6 literal (a "::"-qualified symbol is NOT an
--       IPv6 literal — the token-boundary form of contains_ipv6 handles that);
--   (b) a DIGIT-BEARING raw identifier at a token boundary;
--   (c) a HIGH-CONFIDENCE token (a real JWT / long opaque secret).
-- When `apply_bare_id` is set (the CODE-SYMBOL tier — a frame function, a module
-- name, an exception type, a fingerprint component), it ALSO blanks:
--   (d) a WHOLE-VALUE bare raw id — the ENTIRE value is a disallowed prefix
--       followed solely by identifier chars (user_alice, customer_acme). A
--       qualified code symbol that does NOT start with the prefix
--       (Auth::user_id_from_token, game.user_session.tick, pkg::user_handler) is
--       PRESERVED. The aggressive embeds-anywhere rule is deliberately NOT applied
--       — it would blank an embedded prefix inside a qualified symbol. A rare lone
--       bare symbol ("user_id_from_token" as a whole function name) may blank,
--       which only drops THAT frame (sibling frames / raw_text keep the crash
--       alive and the server re-scrubs), never the whole report.
-- `apply_bare_id` is deliberately OFF for the operator-scope app.id field, where a
-- legitimate product scope ("user_app", "customer_portal") must survive.
-- It deliberately does NOT apply the aggressive digit-free embeds-anywhere raw-id
-- rule or the loose dotted-token rule, both of which blank legitimate symbols.
local function structure_has_disallowed_content(value, apply_bare_id)
	if contains_email(value) then
		return true
	end
	if contains_ipv4(value) then
		return true
	end
	-- Require a genuine IPv6-literal token boundary so a "::"-qualified code symbol
	-- ("Auth::user_id_from_token", "pkg::Type::method") is not misread as an IPv6
	-- literal and blanked.
	if contains_ipv6(value, true) then
		return true
	end
	-- CODE-SYMBOL tier only: the ENTIRE value is a bare raw id (starts with the
	-- prefix). A qualified symbol that merely embeds the prefix mid-token does not
	-- start with it and is kept.
	if apply_bare_id and is_bare_disallowed_id(value) then
		return true
	end
	if embeds_digit_bearing_disallowed_id(value) then
		return true
	end
	return contains_high_confidence_token(value)
end

-- A breadcrumb name is a USER-PROVIDED label (a dotted-identifier grammar). A raw
-- actor-id label like "user_alice" or "customer_acme" must be dropped even when it
-- has no digit, while a legitimate dotted name like "level.load.done" survives.
-- So: email/IP + the aggressive raw-id identity rule (any disallowed prefix at a
-- token boundary followed by identifier text) + the high-confidence token check
-- (a real token is still dropped, but a short dotted name is kept) + the
-- single-long-opaque-run rule. Unlike a native code symbol (a long mangled name /
-- build id that the structured tier must preserve), a breadcrumb name is OPTIONAL
-- caller input — a 40+ char dotless base64url token (API-key-shaped) is never a
-- legitimate readable label, and dropping the breadcrumb does not affect the crash —
-- so the long-opaque-run rule the free-text scrub uses applies here too.
local function breadcrumb_has_disallowed_content(value)
	if contains_email(value) then
		return true
	end
	if contains_ipv4(value) then
		return true
	end
	if contains_ipv6(value, true) then
		return true
	end
	if is_bare_disallowed_id(value) then
		return true
	end
	if embeds_disallowed_id(value) then
		return true
	end
	if contains_high_confidence_token(value) then
		return true
	end
	return contains_long_opaque_run(value)
end

-- The non-token PII signals (email, raw-id prefix, IP) — applied even to code
-- symbols.
local function contains_disallowed_identity(value)
	value = trim(value)
	if value == "" then
		return false
	end
	if contains_email(value) then
		return true
	end
	if is_bare_disallowed_id(value) then
		return true
	end
	if embeds_disallowed_id(value) then
		return true
	end
	if contains_ipv4(value) then
		return true
	end
	return contains_ipv6(value)
end

-- FULL content check for a genuine FREE-TEXT field (an exception reason, a
-- breadcrumb message, a metadata/context value): identity signals PLUS the
-- loose dotted-token heuristic PLUS the high-confidence JWT detector PLUS the
-- single-long-opaque-run rule. The loose heuristic only catches a DOTTED secret;
-- a single long opaque secret (a 40+ char base64url API key with no dots) has no
-- dots and is caught only by contains_long_opaque_run. That run rule is free-text
-- ONLY — the structured tier omits it so a legitimate long build id / mangled
-- symbol / hex address is never blanked (which would drop the native crash).
local function contains_disallowed_content(value)
	value = trim(value)
	if value == "" then
		return false
	end
	if contains_disallowed_identity(value) then
		return true
	end
	if contains_jwt(value) then
		return true
	end
	if contains_high_confidence_token(value) then
		return true
	end
	return contains_long_opaque_run(value)
end

function M.contains_disallowed_content(value)
	if type(value) ~= "string" then
		return false
	end
	return contains_disallowed_content(value)
end

-- Scrub a caller-populated string under the FULL rules. Returns "" when the
-- value is empty or carries disallowed content (the caller drops empties). A
-- user-home path has its username segment redacted in place first, so a useful
-- file location survives without leaking the OS account name.
function M.sanitize_string(value)
	if type(value) ~= "string" then
		return ""
	end
	value = trim(value)
	value = redact_home_paths(value)
	if value == "" or contains_disallowed_content(value) then
		return ""
	end
	return value
end

-- Scrub a STRUCTURED diagnostic field — a frame function, a module / module.name,
-- an exception type, a breadcrumb name. Keeps a package-qualified /
-- "::"-qualified / dotted code symbol or reverse-DNS / dotted class name; blanks
-- only on an embedded email/IP, a digit-bearing raw actor id, or a
-- high-confidence token (real JWT / long secret). A structured value can still
-- carry a user-home path (e.g. a closure described as "callback in
-- /Users/<name>/x.lua"), so the username segment is redacted in place first — the
-- OS account name must never reach the wire, but the rest of the value survives.
-- The OPERATOR-SCOPE structured tier (app.id). It does NOT apply the whole-value
-- bare-raw-id rule: a legitimate product scope whose slug begins with an
-- actor-style prefix ("user_app", "customer_portal") must survive, or blanking it
-- would fail app_id_required and DROP every report (including a fatal).
function M.sanitize_structured(value)
	if type(value) ~= "string" then
		return ""
	end
	value = trim(value)
	value = redact_home_paths(value)
	if value == "" or structure_has_disallowed_content(value, false) then
		return ""
	end
	return value
end

-- The CODE-SYMBOL structured tier (a frame function, a module name, an exception
-- type, a fingerprint component). Same as sanitize_structured PLUS the whole-value
-- bare-raw-id rule: a value that is ENTIRELY a disallowed prefix + identifier
-- chars (user_alice, customer_acme) is a raw actor id and is blanked, while a
-- qualified symbol that does not start with the prefix is preserved.
function M.sanitize_symbol(value)
	if type(value) ~= "string" then
		return ""
	end
	value = trim(value)
	value = redact_home_paths(value)
	if value == "" or structure_has_disallowed_content(value, true) then
		return ""
	end
	return value
end

-- The placeholder a redacted PII substring is replaced with inside the raw crash
-- trace. It carries no identifier/base64url/colon/at characters, so a redactor
-- never re-matches its own output.
local raw_text_redaction = "<redacted>"

-- Redact every email ADDRESS occurrence in place (local-part@dotted-domain with a
-- letter-only TLD), leaving the surrounding trace text intact. Mirrors
-- contains_email's address SHAPE so a non-email "@" (an offset like "module@0x1234",
-- a file URL) is left alone.
local function redact_emails(value)
	return (value:gsub("([%w%.%_%%%+%-]+)@([%w%.%-]+)", function(local_part, domain)
		local trimmed_domain = domain:gsub("[%.%-]+$", "")
		local tld = trimmed_domain:match("%.([%a]+)$")
		if #local_part >= 1 and tld ~= nil and #tld >= 2 then
			-- Preserve any trailing domain punctuation that was NOT part of the address
			-- (sentence punctuation after the TLD) so the trace reads naturally.
			local trailing = domain:sub(#trimmed_domain + 1)
			return raw_text_redaction .. trailing
		end
		return local_part .. "@" .. domain
	end))
end

-- Redact every IPv4 dotted-quad literal in place (each octet 0-255, not glued to a
-- longer digit run on either side). Mirrors contains_ipv4's boundary/range checks.
local function redact_ipv4(value)
	local function octet_ok(o)
		local n = tonumber(o)
		return n ~= nil and n >= 0 and n <= 255
	end
	local out = {}
	local pos = 1
	while pos <= #value do
		local s, e, a, b, c, d = value:find("(%d+)%.(%d+)%.(%d+)%.(%d+)", pos)
		if not s then
			out[#out + 1] = value:sub(pos)
			break
		end
		local before = s > 1 and value:sub(s - 1, s - 1) or ""
		local after = value:sub(e + 1, e + 1)
		out[#out + 1] = value:sub(pos, s - 1)
		if not before:match("%d") and not after:match("%d")
			and octet_ok(a) and octet_ok(b) and octet_ok(c) and octet_ok(d) then
			out[#out + 1] = raw_text_redaction
			pos = e + 1
		else
			-- Not a real dotted quad: keep the first char and re-scan from the next so a
			-- shifted candidate is still found.
			out[#out + 1] = value:sub(s, s)
			pos = s + 1
		end
	end
	return table.concat(out)
end

-- Redact every genuine IPv6 literal in place while leaving a "::"-qualified code
-- symbol (Player::Update, pkg::Type::method) intact. Mirrors contains_ipv6's
-- token-boundary form: a "::"-compressed run counts only when it stands as its own
-- token (no identifier char immediately around it), and a non-compressed run needs
-- >=3 non-empty hextet groups with a genuine hex-letter / full-address signal (so a
-- log time "12:34:56" is left alone).
local function ipv6_run_is_literal(candidate, has_token_boundary)
	if not candidate:find(":", 1, true) then
		return false
	end
	if candidate:find("::", 1, true) then
		return has_token_boundary
	end
	local hextet_groups = 0
	local all_hex = true
	local has_hex_letter = false
	for group in (candidate .. ":"):gmatch("([^:]*):") do
		if group ~= "" then
			if group:match("^[0-9A-Fa-f]+$") or group:match("^%d+%.%d+%.%d+%.%d+$") then
				hextet_groups = hextet_groups + 1
				if group:match("[A-Fa-f]") then
					has_hex_letter = true
				end
			else
				all_hex = false
			end
		end
	end
	return all_hex and hextet_groups >= 3 and (has_hex_letter or hextet_groups >= 8)
end

local function redact_ipv6(value)
	local out = {}
	local pos = 1
	while pos <= #value do
		local s, e, raw_candidate = value:find("([0-9A-Fa-f:%.]+)", pos)
		if not s then
			out[#out + 1] = value:sub(pos)
			break
		end
		out[#out + 1] = value:sub(pos, s - 1)
		-- Strip surrounding brackets/punctuation the way contains_ipv6 does, then
		-- locate the trimmed core inside the raw run so only the literal is replaced
		-- (any stripped prefix/suffix punctuation is preserved verbatim).
		local lead = raw_candidate:match("^([%[%(]*)")
		local trail = raw_candidate:match("([%]%),;]*)$")
		local core = raw_candidate:sub(#lead + 1, #raw_candidate - #trail)
		local before = s > 1 and value:sub(s - 1, s - 1) or ""
		local after = value:sub(e + 1, e + 1)
		local id_before = before ~= "" and before:match("[%w_]") ~= nil
		local id_after = after ~= "" and after:match("[%w_]") ~= nil
		local has_token_boundary = not id_before and not id_after
		if core ~= "" and ipv6_run_is_literal(core, has_token_boundary) then
			out[#out + 1] = lead .. raw_text_redaction .. trail
		else
			out[#out + 1] = raw_candidate
		end
		pos = e + 1
	end
	return table.concat(out)
end

-- Redact an aggressive raw-identifier token in place: a disallowed prefix
-- (player_/user_/customer_/device_) at a TOKEN BOUNDARY followed by at least one
-- identifier-continuation char (user_alice, user_4242, customer_acme-42). Only the
-- offending token is replaced; the rest of the trace — including code symbols that
-- merely contain such a word inside a longer qualified name — is left intact. The
-- token boundary is enforced exactly like embeds_disallowed_id: the prefix must not
-- be preceded by an identifier char (so "multiuser_" is not a fresh token).
local function redact_aggressive_raw_ids(value)
	for _, prefix in ipairs(disallowed_prefixes) do
		local out = {}
		local lowered = value:lower()
		local pos = 1
		while pos <= #value do
			local start_pos, end_pos = lowered:find(prefix, pos, true)
			if not start_pos then
				out[#out + 1] = value:sub(pos)
				break
			end
			local before = start_pos > 1 and lowered:sub(start_pos - 1, start_pos - 1) or ""
			local after = lowered:sub(end_pos + 1, end_pos + 1)
			if not is_identifier_char(before) and is_identifier_char(after) then
				-- Token boundary + a continuation: consume the prefix and the entire
				-- identifier continuation that follows it, replacing the whole raw id.
				out[#out + 1] = value:sub(pos, start_pos - 1)
				local i = end_pos + 1
				while i <= #value and is_identifier_char(value:sub(i, i)) do
					i = i + 1
				end
				out[#out + 1] = raw_text_redaction
				pos = i
			else
				-- Not a fresh token: keep through the matched prefix and re-scan past it.
				out[#out + 1] = value:sub(pos, end_pos)
				pos = end_pos + 1
			end
		end
		value = table.concat(out)
	end
	return value
end

-- Redact a DIGIT-BEARING raw identifier at a SUB-TOKEN boundary in place: a
-- disallowed prefix that begins a fresh sub-token (start-of-value or right after a
-- separator — "_", ".", ":", "-", or any non-alphanumeric) followed by a
-- continuation that CONTAINS a digit (handler.user_4242.update, auth.user_99).
-- Mirrors embeds_digit_bearing_disallowed_id so the same digit-bearing raw id the
-- structured tier blanks is removed from the trace, while a digit-FREE qualified
-- word (game.user_session.tick) is left intact. This complements
-- redact_aggressive_raw_ids, which handles the whitespace/standalone token form;
-- here the prefix may be glued after a "." inside a longer dotted symbol.
local function redact_digit_bearing_raw_ids(value)
	for _, prefix in ipairs(disallowed_prefixes) do
		local out = {}
		local lowered = value:lower()
		local pos = 1
		while pos <= #value do
			local start_pos, end_pos = lowered:find(prefix, pos, true)
			if not start_pos then
				out[#out + 1] = value:sub(pos)
				break
			end
			local before = start_pos > 1 and lowered:sub(start_pos - 1, start_pos - 1) or ""
			-- Sub-token boundary: start-of-value or a separator (anything not a letter
			-- or digit), so the prefix glued mid-alphanumeric ("multiuser_4242") is not a
			-- fresh sub-token.
			if before == "" or before:match("[^%w]") then
				-- Walk the identifier continuation; if any char is a digit, this is a
				-- digit-bearing raw id — redact the prefix plus the whole continuation.
				local i = end_pos + 1
				local saw_digit = false
				while i <= #value and is_identifier_char(value:sub(i, i)) do
					if value:sub(i, i):match("%d") then
						saw_digit = true
					end
					i = i + 1
				end
				if saw_digit then
					out[#out + 1] = value:sub(pos, start_pos - 1)
					out[#out + 1] = raw_text_redaction
					pos = i
				else
					out[#out + 1] = value:sub(pos, end_pos)
					pos = end_pos + 1
				end
			else
				out[#out + 1] = value:sub(pos, end_pos)
				pos = end_pos + 1
			end
		end
		value = table.concat(out)
	end
	return value
end

-- Redact a high-confidence JWT in place: >=3 dot-separated base64url segments each
-- >= min_token_segment_len chars, standing as a whole token. Mirrors
-- contains_high_confidence_token so a readable qualified name (com.company.game,
-- java.lang.RuntimeException) — short word segments — is left intact.
local function redact_high_confidence_tokens(value)
	return (value:gsub("([%w_%-]+%.[%w_%-][%w_%-%.]*)", function(run)
		local segments = {}
		local all_long = true
		for seg in (run .. "."):gmatch("([^%.]*)%.") do
			segments[#segments + 1] = seg
			if #seg < min_token_segment_len then
				all_long = false
			end
		end
		if #segments >= 3 and all_long then
			return raw_text_redaction
		end
		return run
	end))
end

-- Redact a long opaque base64url run in place: a contiguous dotless run of
-- [%w_-] of >= min_long_secret_len chars (a raw API key / opaque secret). A run
-- this long with no readable separators is treated as a secret. Code symbols are
-- short or dot/colon-separated, so they are not single runs of this length. (A
-- "::"-qualified symbol's individual segments are short and survive.)
local function redact_long_opaque_runs(value)
	return (value:gsub("[%w_%-]+", function(run)
		if #run >= min_long_secret_len then
			return raw_text_redaction
		end
		return run
	end))
end

-- Scrub the native crash trace / traceback (raw_text) by REDACTING PII SUBSTRINGS
-- IN PLACE — never blanking the whole field. raw_text is the full text of a native
-- backtrace: it is simultaneously dense with code symbols ("::"-qualified scopes
-- like Player::Update, dotted class names like java.lang.RuntimeException, dotted
-- call paths like game.player.update) AND able to carry arbitrary caller free-text
-- (an error message with an email, an IP, a raw actor id, a leaked token). Routing
-- it through the structured tier would leak aggressive raw ids / loose tokens;
-- routing it through the full free-text scrub would BLANK the whole field over a
-- single code symbol — and a frame-less fatal crash relies entirely on raw_text, so
-- blanking it would fail the frames-or-raw-text requirement and DROP the crash.
-- Instead, each PII occurrence (a user-home username segment, an email, an IPv4/IPv6
-- literal, an aggressive raw-id token, a high-confidence JWT, a long opaque secret
-- run) is replaced with a placeholder while the code symbols and the rest of the
-- trace survive verbatim. The result is never blanked-whole, so a fatal is never
-- dropped, and the listed PII is removed.
function M.sanitize_raw_text(value)
	if type(value) ~= "string" then
		return ""
	end
	value = trim(value)
	if value == "" then
		return ""
	end
	-- Order matters: redact the home-path username and the email first (the email's
	-- domain dots/letters could otherwise be partially consumed by the token/IPv6
	-- passes), then the structured-secret runs, then IP literals, then the raw-id
	-- tokens last (their continuation walk must see original separators).
	value = redact_home_paths(value)
	value = redact_emails(value)
	value = redact_high_confidence_tokens(value)
	value = redact_long_opaque_runs(value)
	value = redact_ipv6(value)
	value = redact_ipv4(value)
	value = redact_aggressive_raw_ids(value)
	value = redact_digit_bearing_raw_ids(value)
	return value
end

-- An exception type is a structured code identifier (a package-qualified class
-- name like "java.lang.RuntimeException" or "com.company.game.Crash"). It is a
-- REQUIRED wire field with no fallback, so it uses the structured tier WITHOUT the
-- whole-value bare-id rule: a dotted class name survives, an embedded email /
-- digit-bearing raw id / IP / real token is still removed, but a plain error type
-- that happens to be shaped like a bare prefix ("user_error", "player_died") is
-- NOT blanked — blanking it would fail the required-type check and DROP the whole
-- fatal crash. (The bare-id rule is only applied to optional/sibling-recoverable
-- code-symbol fields like a frame function or a fingerprint component.)
function M.sanitize_exception_type(value)
	return M.sanitize_structured(value)
end

-- Scrub a frame FILE path. A source path ("Source/UI/user_interface.cpp") is
-- structured, but the aggressive/digit-bearing raw-id rule must NOT fire on its
-- path segments (a directory called "user_interface" is not a raw actor id) — a
-- path's only PII risk is a user-home directory leaking the OS account name, so
-- apply ONLY the home-directory username redaction plus the email/IP and
-- high-confidence-token signals. The structured raw-id rule is intentionally
-- skipped here.
function M.sanitize_file(value)
	if type(value) ~= "string" then
		return ""
	end
	value = trim(value)
	value = redact_home_paths(value)
	if value == "" then
		return ""
	end
	if contains_email(value)
		or contains_ipv4(value)
		or contains_ipv6(value, true)
		or contains_high_confidence_token(value) then
		return ""
	end
	return value
end

-- Scrub an app version / build string. These come from the trusted config, not
-- caller free-text, and a common 4-part version like "1.2.3.4" would otherwise be
-- read as an IPv4 literal by the full scrub and blanked, dropping the version. A
-- value made only of version characters (digits, dots, dashes, plus, and ASCII
-- letters — e.g. "1.2.3.4", "2.0.0-rc.1+build.7") is kept rather than blanked as
-- an IP, while emails, raw identifiers, and dotted-token (credential) content are
-- still rejected. Anything outside the version shape (an "@", whitespace, or any
-- other character) falls through to the full content scrub.
function M.sanitize_version(value)
	if type(value) ~= "string" then
		return ""
	end
	value = trim(value)
	if value == "" then
		return ""
	end
	if value:match("^[%w%.%-%+]+$") then
		-- A version-shaped value: keep dotted numerics (do NOT treat them as an
		-- IPv4 literal), but still reject anything that is itself a bare raw
		-- identifier, carries an embedded raw identifier, or is a dotted-token
		-- credential shape.
		if is_bare_disallowed_id(value) or embeds_disallowed_id(value) or contains_jwt(value) then
			return ""
		end
		return value
	end
	return M.sanitize_string(value)
end

-- Scrub a frame function. A frame function is a CODE SYMBOL in BOTH the
-- auto-capture path and a manual caller-supplied frame, so it always gets the
-- symbol scrub (which preserves a package-qualified / "::"-qualified / dotted
-- name and strips only an embedded email/IP). The full free-text scrub would
-- read a normal symbol like "game.player.update" as a dotted token and blank it,
-- which would make the frame unidentified and drop the whole crash. The
-- `trusted` argument is retained for call-site clarity but no longer changes the
-- tier — neither tier may blank a legitimate symbol.
function M.sanitize_function_name(value, trusted)
	return M.sanitize_symbol(value)
end

-- Scrub a {string=string} map: drop keys that are not a valid map key (or carry
-- disallowed content) and any value that scrubs empty. Returns nil when empty.
function M.sanitize_string_map(value)
	if type(value) ~= "table" then
		return nil
	end
	local out = {}
	local any = false
	for key, raw in pairs(value) do
		if type(key) == "string" then
			local trimmed_key = trim(key)
			if valid_map_key(trimmed_key) and not contains_disallowed_content(trimmed_key) then
				local clean = M.sanitize_string(raw)
				if clean ~= "" then
					out[trimmed_key] = clean
					any = true
				end
			end
		end
	end
	if not any then
		return nil
	end
	return out
end

-- Scrub an array of strings, dropping any that scrub empty.
function M.sanitize_string_array(value)
	if type(value) ~= "table" then
		return nil
	end
	local out = {}
	for i = 1, #value do
		local clean = M.sanitize_string(value[i])
		if clean ~= "" then
			out[#out + 1] = clean
		end
	end
	if #out == 0 then
		return nil
	end
	return out
end

-- Scrub an array of STRUCTURED diagnostic strings (each a code-symbol-class value
-- such as a package/class name used as a grouping key), dropping any that scrub
-- empty. Uses the structured tier so a dotted/qualified symbol like
-- "java.lang.RuntimeException" or "com.company.game" survives as a grouping key —
-- the full free-text scrub would read it as a dotted token and blank it, silently
-- discarding the caller's chosen grouping — while an embedded email / IP /
-- digit-bearing raw id / real token is still removed.
function M.sanitize_structured_array(value)
	if type(value) ~= "table" then
		return nil
	end
	local out = {}
	for i = 1, #value do
		local clean = M.sanitize_symbol(value[i])
		if clean ~= "" then
			out[#out + 1] = clean
		end
	end
	if #out == 0 then
		return nil
	end
	return out
end

-- Scrub a breadcrumb name: must match the breadcrumb-name shape AND carry no
-- disallowed content. A breadcrumb name is a user-provided dotted-identifier
-- label: a legitimate name like "level.load.done" is kept, but a raw actor-id
-- label like "user_alice" is dropped (see breadcrumb_has_disallowed_content).
-- Returns (name, true) on success, (nil, false) on reject.
function M.sanitize_breadcrumb_name(name)
	if type(name) ~= "string" then
		return nil, false
	end
	name = trim(name)
	if name == "" or not valid_breadcrumb_name(name) then
		return nil, false
	end
	if breadcrumb_has_disallowed_content(name) then
		return nil, false
	end
	return name, true
end

return M
