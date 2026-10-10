-- Private, non-cryptographic randomness for identifiers and retry timing.
-- xoshiro128** 1.1 by David Blackman and Sebastiano Vigna (public domain):
-- Reference: <https://prng.di.unimi.it/xoshiro128starstar.c>
-- State never enters the game's random-number generator.
local M = {}
local modulus = 4294967296
local bitops = bit
if not bitops then
	local ok, value = pcall(require, "bit")
	if ok then bitops = value end
end

local function xor(a, b)
	if bitops then return bitops.bxor(a, b) % modulus end
	-- Plain Lua hosts use the same unsigned operation without BitOp.
	local value, place = 0, 1
	for _ = 1, 32 do
		if a % 2 ~= b % 2 then value = value + place end
		a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
	end
	return value
end

local function rotate(value, count)
	return (value * 2 ^ count) % modulus + math.floor(value / 2 ^ (32 - count))
end

local a, b, c, d
local function next_word()
	local result = (rotate((b * 5) % modulus, 7) * 9) % modulus
	local shifted = (b * 512) % modulus
	c = xor(c, a)
	d = xor(d, b)
	b = xor(b, c)
	a = xor(a, d)
	c = xor(c, shifted)
	d = rotate(d, 11)
	return result
end

local function clock_value(fn)
	if type(fn) ~= "function" then return "" end
	local ok, value = pcall(fn)
	if not ok or type(value) ~= "number" then return "" end
	return string.format("%.17g", value)
end

local function seed_once()
	if a then return end
	local sources = {
		clock_value(socket and socket.gettime),
		clock_value(os.clock),
		clock_value(os.time),
		tostring({}),
	}
	if html5 and type(html5.run) == "function" then
		local ok, value = pcall(html5.run, [[(function() {
			try {
				if (typeof crypto === "undefined" || !crypto.getRandomValues) return "";
				var bytes = new Uint8Array(32);
				crypto.getRandomValues(bytes);
				return Array.prototype.map.call(bytes, function(b) {
					return ("0" + b.toString(16)).slice(-2);
				}).join("");
			} catch (e) { return ""; }
		})()]])
		if ok and type(value) == "string" and #value == 64 and not value:find("[^%x]") then
			sources[#sources + 1] = value
		end
	end
	-- Clock/address diversity reduces same-time launch collisions, but is not
	-- a guaranteed entropy budget. Even with browser entropy these are not secrets.
	a, b, c, d = 0x243f6a88, 0x85a308d3, 0x13198a2e, 0x03707344
	local material = table.concat(sources, "|")
	for i = 1, #material do
		local byte = material:byte(i)
		a = (a * 33 + byte) % modulus
		b = (b * 65599 + byte) % modulus
		c = (c * 131 + byte) % modulus
		d = (d * 8191 + byte) % modulus
	end
	if a == 0 and b == 0 and c == 0 and d == 0 then a = 1 end
	for _ = 1, 32 do next_word() end
end

function M.unit()
	seed_once()
	return next_word() / modulus
end

function M.hex(count)
	seed_once()
	local words = {}
	for i = 1, math.ceil(count / 8) do
		words[i] = string.format("%08x", next_word())
	end
	return table.concat(words):sub(1, count)
end

return M
