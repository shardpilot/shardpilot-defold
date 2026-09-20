package.path = "./?.lua;./?/init.lua;" .. package.path

-- ONE SOURCE FOR THE INTEGRATION FLOW, CHECKED BYTE FOR BYTE.
--
-- The flow was written three times: examples/minimal/main.script, which is
-- executable and has a test suite behind it; the README's quick start; and the
-- packaged skill's Init section. One review round found five findings that
-- were the same flow drifting — an ordering fixed in the skill and not the
-- README, retry state removed from the example and not the README, a fallback
-- rejected in the skill that the example accepts, a crash flag set in the
-- README without reading the result the example reads.
--
-- Reviewing three hand-kept copies will never converge, so there is one copy.
-- The example carries `-- doc-region: <name>` markers; the documents carry the
-- SAME BYTES inside a fenced block introduced by `<!-- doc-region: <name> -->`.
-- Prose around the blocks is free. Code is not.
--
-- TO RE-EXTRACT after changing the example, from the repository root (this is
-- deliberately not a script under scripts/: a file there is part of the judge
-- population check_gate_integrity.py guards, and adding one would make every
-- change that touches it refuse):
--
--   python3 -c "$(sed -n '/^--   BEGIN RECIPE/,/^--   END RECIPE/p' \
--       test/test_documented_regions.lua | sed 's/^--   //;1d;$d')"
--
--   BEGIN RECIPE
--   import pathlib, re
--   ex = pathlib.Path('examples/minimal/main.script').read_text().split('\n')
--   regions, name, buf = {}, None, None
--   for line in ex:
--       m = re.match(r'^-- doc-region: ([\w-]+)$', line)
--       e = re.match(r'^-- doc-region-end: ([\w-]+)$', line)
--       if m: name, buf = m.group(1), []
--       elif e: regions[e.group(1)] = buf; name, buf = None, None
--       elif name is not None: buf.append(line)
--   for path in ['README.md', '.claude/skills/shardpilot-defold-integration/SKILL.md']:
--       lines = pathlib.Path(path).read_text().split('\n')
--       out, i = [], 0
--       while i < len(lines):
--           m = re.match(r'^<!-- doc-region: ([\w-]+) -->$', lines[i])
--           if m and i + 1 < len(lines) and lines[i + 1] == '```lua':
--               j = i + 2
--               while lines[j] != '```': j += 1
--               out += [lines[i], '```lua'] + regions[m.group(1)] + ['```']
--               i = j + 1
--               continue
--           out.append(lines[i]); i += 1
--       pathlib.Path(path).write_text('\n'.join(out))
--   END RECIPE
--
-- ⚠ AND AN UNMARKED BLOCK FAILS, which is the part that keeps this from
-- rotting. Checking only the blocks that opt in leaves the door the defect
-- came through wide open: the next hand-written snippet is a fourth copy and
-- nothing notices. A Lua block in these documents is either an extracted
-- region or it is explicitly declared not to be one, with a reason.

local EXAMPLE = "examples/minimal/main.script"
local DOCUMENTS = {
	"README.md",
	".claude/skills/shardpilot-defold-integration/SKILL.md",
}

local failures = 0
local function check(condition, message)
	if not condition then
		failures = failures + 1
		print("FAIL: " .. message)
	end
end

local function read(path)
	local file = assert(io.open(path, "r"), "cannot read " .. path)
	local text = file:read("*a")
	file:close()
	return text
end

local function lines_of(text)
	local out = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		out[#out + 1] = line
	end
	-- gmatch above yields one trailing empty line for a file ending in \n.
	if out[#out] == "" then
		out[#out] = nil
	end
	return out
end

-- The regions the example publishes: name -> exact text, markers excluded.
local function regions_of(path)
	local found, order = {}, {}
	local open_name, collected = nil, nil
	local number = 0
	for _, line in ipairs(lines_of(read(path))) do
		number = number + 1
		local starts = line:match("^%-%- doc%-region: ([%w%-]+)$")
		local ends = line:match("^%-%- doc%-region%-end: ([%w%-]+)$")
		if starts then
			check(not open_name, path .. ":" .. number .. " opens region '" .. starts
				.. "' inside '" .. tostring(open_name) .. "'; regions do not nest")
			check(not found[starts], path .. ":" .. number .. " defines region '"
				.. starts .. "' twice")
			open_name, collected = starts, {}
		elseif ends then
			check(open_name == ends, path .. ":" .. number .. " closes region '" .. ends
				.. "' but '" .. tostring(open_name) .. "' is open")
			if open_name == ends then
				found[ends] = table.concat(collected, "\n")
				order[#order + 1] = ends
				open_name, collected = nil, nil
			end
		elseif open_name then
			collected[#collected + 1] = line
		end
	end
	check(not open_name, path .. " leaves region '" .. tostring(open_name) .. "' unterminated")
	return found, order
end

-- Every fenced lua block in a document, with the marker line above it.
local function blocks_of(path)
	local blocks = {}
	local all = lines_of(read(path))
	local index = 1
	while index <= #all do
		if all[index] == "```lua" then
			local marker = index > 1 and all[index - 1] or ""
			local body, cursor = {}, index + 1
			while cursor <= #all and all[cursor] ~= "```" do
				body[#body + 1] = all[cursor]
				cursor = cursor + 1
			end
			check(cursor <= #all, path .. ":" .. index .. " opens a lua block that never closes")
			blocks[#blocks + 1] = {
				line = index,
				marker = marker,
				text = table.concat(body, "\n"),
			}
			index = cursor
		end
		index = index + 1
	end
	return blocks
end

local regions, order = regions_of(EXAMPLE)
check(#order > 0, EXAMPLE .. " publishes no doc regions at all; a run that "
	.. "matched nothing is not a pass")

local checked, declared = 0, 0
local used = {}
for _, path in ipairs(DOCUMENTS) do
	local blocks = blocks_of(path)
	check(#blocks > 0, path .. " carries no lua blocks; the roster in this "
		.. "suite is stale or the path moved")
	for _, block in ipairs(blocks) do
		local name = block.marker:match("^<!%-%- doc%-region: ([%w%-]+) %-%->$")
		local reason = block.marker:match("^<!%-%- doc%-region: none %-%- (.+) %-%->$")
		if name then
			local region = regions[name]
			check(region ~= nil, path .. ":" .. block.line .. " names region '" .. name
				.. "', which " .. EXAMPLE .. " does not publish")
			if region then
				used[name] = true
				checked = checked + 1
				check(block.text == region, path .. ":" .. block.line
					.. " has drifted from region '" .. name .. "' in " .. EXAMPLE
					.. ". The example is the one copy: re-extract this block from it "
					.. "rather than editing the document.")
			end
		elseif reason then
			declared = declared + 1
			check(#reason >= 8, path .. ":" .. block.line
				.. " declares itself outside the flow with no usable reason")
		else
			failures = failures + 1
			print("FAIL: " .. path .. ":" .. block.line .. " is a lua block with no "
				.. "doc-region marker above it. Every lua block in these documents is "
				.. "either an extracted region -- `<!-- doc-region: <name> -->` -- or is "
				.. "declared not to be one -- `<!-- doc-region: none -- <reason> -->`. An "
				.. "unmarked block is how the fourth hand-kept copy of the flow starts.")
		end
	end
end

check(checked > 0, "no document quoted a single region; the markers are present "
	.. "but nothing is held to them")

-- An unused region is dead weight that still reads as checked.
for _, name in ipairs(order) do
	check(used[name], EXAMPLE .. " publishes region '" .. name
		.. "' that no document quotes; remove the markers or quote it")
end

if failures > 0 then
	print(string.format("shardpilot defold documented-region tests: %d failure(s)", failures))
	os.exit(1)
end
print(string.format(
	"shardpilot defold documented-region tests passed (%d region(s) published, "
	.. "%d quotation(s) compared, %d block(s) declared outside the flow)",
	#order, checked, declared))
