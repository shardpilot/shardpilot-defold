--- Request-body compression for the analytics batch route.
--
-- The engine's `zlib` module produces RFC 1950 zlib framing — a 2-byte header,
-- the deflate stream, an Adler-32 trailer — which is exactly the
-- `Content-Encoding: deflate` content coding. It cannot produce gzip.
--
-- We send deflate rather than framing gzip by hand, and that is a deliberate
-- divergence from the other SDKs. gzip framing needs a CRC32 over the WHOLE
-- uncompressed batch, and there is no engine CRC32 to borrow — zlib's own
-- trailer is Adler-32, a different checksum. A pure-Lua CRC32 over tens of
-- kilobytes runs on the flush path and costs milliseconds, which is a frame
-- hitch traded for the bytes this lane exists to save. The ingest server reads
-- RFC 1950 on the `deflate` coding for exactly this reason, and both ends of
-- the pairing are ours, so the usual "deflate is ambiguous in the wild"
-- objection does not apply here.
--
-- Everything is feature-detected. The module is absent on some engine
-- versions and host tooling, so its absence must be an ordinary uncompressed
-- publish rather than an error: a missing compressor is a missed optimisation,
-- never a dropped batch.
local M = {}

--- Body size below which a publish is sent uncompressed.
--
-- zlib framing costs 6 bytes before the deflate stream's own block overhead,
-- so a small body can come out LARGER compressed — and the CPU is spent either
-- way. A single-event batch is a few hundred bytes; a full batch is tens of
-- kilobytes and is the same envelope keys repeated per event, close to the
-- best case deflate has. The threshold sits between them.
M.MINIMUM_BYTES = 1024

--- The content coding this SDK sends. See the module note for why not gzip.
M.CODING = "deflate"

M.HEADER = "Content-Encoding"

--- Ingest detail codes meaning "this server cannot read the coding you sent".
--
-- Matched instead of the bare 400: a status-only match would let an ordinary
-- validation failure — a bad event name, a scope mismatch — silently switch
-- compression off for the rest of the session, a transport change nobody asked
-- for made in response to an unrelated defect, hiding the real one behind it.
M.UNSUPPORTED_CODING_DETAIL = "unsupported_content_encoding"
M.INVALID_CODING_DETAIL = "invalid_content_encoding"

--- Reports whether the engine can compress at all.
function M.available()
	return type(zlib) == "table" and type(zlib.deflate) == "function"
end

--- Compresses `body` and returns the compressed string, or nil when the caller
-- should send the body as-is.
--
-- nil is returned when the engine has no compressor, when the body is under
-- the threshold, when compression raises, or when the result is not actually
-- smaller. The last case is not theoretical: a high-entropy body comes back
-- larger, and sending it would spend CPU to make the request worse.
function M.compress(body)
	if type(body) ~= "string" or #body < M.MINIMUM_BYTES then
		return nil
	end
	if not M.available() then
		return nil
	end
	local ok, compressed = pcall(zlib.deflate, body)
	if not ok or type(compressed) ~= "string" or #compressed == 0 then
		return nil
	end
	if #compressed >= #body then
		return nil
	end
	return compressed
end

--- Reports whether a failed publish carried the server saying it could not
-- read the request's content coding.
--
-- `detail_codes` is the comma-joined detail-code list the transport lifts out
-- of the ingest error envelope; nil or empty means the body carried no
-- envelope and the answer is no.
--
-- WHOLE TOKENS, not substrings. A plain find() over the joined list matches
-- any code that merely CONTAINS one of these — `not_invalid_content_encoding`,
-- `unsupported_content_encoding_policy` — and the consequences run both ways:
-- a terminally rejected batch is retained and retried, and compression is
-- latched off for the session. The whole point of discriminating on codes
-- rather than the bare 400 is exactness, so the match has to be exact
-- (Codex on #46).
function M.is_encoding_refusal(detail_codes)
	if type(detail_codes) ~= "string" or detail_codes == "" then
		return false
	end
	for code in detail_codes:gmatch("[^,]+") do
		if code == M.UNSUPPORTED_CODING_DETAIL or code == M.INVALID_CODING_DETAIL then
			return true
		end
	end
	return false
end

return M
