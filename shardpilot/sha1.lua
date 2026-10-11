-- SHA-1 for RFC 9562 name-based UUIDs. Pure Lua on every supported runtime;
-- this is not an authentication or password-hashing API.
-- Algorithm: https://www.rfc-editor.org/rfc/rfc3174.html#section-6.1
local M = {}
local floor = math.floor
local modulus = 4294967296

-- Four-bit lookup keeps the same arithmetic path on Lua 5.1, LuaJIT and 5.4.
local xor_nibbles = {}
for a = 0, 15 do
	for b = 0, 15 do
		local left, right, value, place = a, b, 0, 1
		for _ = 1, 4 do
			if left % 2 ~= right % 2 then value = value + place end
			left, right, place = floor(left / 2), floor(right / 2), place * 2
		end
		xor_nibbles[a * 16 + b] = value
	end
end

local function xor(a, b)
	local value, place = 0, 1
	for _ = 1, 8 do
		value = value + xor_nibbles[(a % 16) * 16 + b % 16] * place
		a, b, place = floor(a / 16), floor(b / 16), place * 16
	end
	return value
end

local function band(a, b)
	return (a + b - xor(a, b)) / 2
end

local function rotate(value, count)
	local cut = 2 ^ (32 - count)
	return (value % cut) * 2 ^ count + floor(value / cut)
end

local function word_bytes(value)
	return string.char(floor(value / 16777216) % 256,
		floor(value / 65536) % 256, floor(value / 256) % 256, value % 256)
end

function M.hex(text)
	local length = #text
	text = text .. "\128" .. string.rep("\0", (55 - length) % 64)
		.. word_bytes(floor(length / 536870912)) .. word_bytes((length * 8) % modulus)
	local h0, h1, h2, h3, h4 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
	local words = {}
	for offset = 1, #text, 64 do
		for i = 0, 15 do
			local a, b, c, d = text:byte(offset + i * 4, offset + i * 4 + 3)
			words[i] = a * 16777216 + b * 65536 + c * 256 + d
		end
		for i = 16, 79 do
			words[i] = rotate(xor(xor(words[i - 3], words[i - 8]),
				xor(words[i - 14], words[i - 16])), 1)
		end
		local a, b, c, d, e = h0, h1, h2, h3, h4
		for i = 0, 79 do
			local f, k
			if i < 20 then
				f, k = band(b, c) + band(modulus - 1 - b, d), 0x5a827999
			elseif i < 40 then
				f, k = xor(xor(b, c), d), 0x6ed9eba1
			elseif i < 60 then
				f, k = band(b, c) + band(xor(b, c), d), 0x8f1bbcdc
			else
				f, k = xor(xor(b, c), d), 0xca62c1d6
			end
			local next_a = (rotate(a, 5) + f + e + words[i] + k) % modulus
			e, d, c, b, a = d, c, rotate(b, 30), a, next_a
		end
		h0, h1, h2, h3, h4 = (h0 + a) % modulus, (h1 + b) % modulus,
			(h2 + c) % modulus, (h3 + d) % modulus, (h4 + e) % modulus
	end
	return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

return M
