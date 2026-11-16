-- Usage: lua LearnedImporter.lua <base data file> [SavedVariables/DBM-FlightTimers.lua ...] > <output data file>
-- See import-learned.sh for re-generating Forever.lua.

-- Merges flight times the AddOn learned in game (DBMFlightTimers_Learned) on top of an existing data file.
-- Learned times win over the base data, later SavedVariables files win over earlier ones.
-- Changes are reported on stderr.

local filenameBase = ...
local filenamesLearned = {select(2, ...)}

local function abort(err)
	io.stderr:write(err)
	io.stderr:write("\n")
	os.exit(1)
end

if not filenameBase then
	return abort("Usage: lua LearnedImporter.lua <base data file> [SavedVariables/DBM-FlightTimers.lua ...]")
end

local factions = {"Horde", "Alliance"}

local function runFile(filename, ...)
	local chunk, err = loadfile(filename)
	if not chunk then
		abort("could not load " .. filename .. "\n" .. tostring(err))
		return -- unreachable but makes LuaLS happy
	end
	local ok, res = pcall(chunk, ...)
	if not ok then
		abort("error while loading " .. filename .. "\n" .. tostring(res))
	end
end

-- Base data: times per faction, names from the comments
local function loadBase(faction)
	local ns = {}
	rawset(_G, "UnitFactionGroup", function() return faction end)
	runFile(filenameBase, nil, ns)
	return ns.FlightTimes or {}
end
local times, baseTimes, names = {}, {}, {}
for _, faction in ipairs(factions) do
	times[faction] = loadBase(faction)
	baseTimes[faction] = loadBase(faction)
end
for line in io.lines(filenameBase) do
	local id, name = line:match("^%s*%[(%d+)%].-%-%- (.-)%s*$")
	if id then
		names[tonumber(id)] = name
	end
end

for _, filename in ipairs(filenamesLearned) do
	rawset(_G, "DBMFlightTimers_Learned", nil)
	runFile(filename)
	local learned = rawget(_G, "DBMFlightTimers_Learned")
	if type(learned) ~= "table" or type(learned.times) ~= "table" then
		io.stderr:write("no learned flight times in " .. filename .. "\n")
	else
		for id, name in pairs(learned.names or {}) do
			-- Names are only comments; keep the existing (English) ones, learned names may be in any locale.
			names[id] = names[id] or name
		end
		for faction, learnedTimes in pairs(learned.times) do
			if not times[faction] then
				io.stderr:write("ignoring flight times for faction " .. tostring(faction) .. " in " .. filename .. "\n")
			else
				for from, destinations in pairs(learnedTimes) do
					times[faction][from] = times[faction][from] or {}
					for to, time in pairs(destinations) do
						times[faction][from][to] = time
					end
				end
			end
		end
	end
end

local function nodeName(id)
	return names[id] or "unknown"
end

local function sortedKeys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	return keys
end

local numChanges = 0
for _, faction in ipairs(factions) do
	for _, from in ipairs(sortedKeys(times[faction])) do
		local old = baseTimes[faction][from] or {}
		for _, to in ipairs(sortedKeys(times[faction][from])) do
			local time = times[faction][from][to]
			if old[to] ~= time then
				numChanges = numChanges + 1
				io.stderr:write(("%s: %s (%d) -> %s (%d): %s -> %d\n"):format(
					faction, nodeName(from), from, nodeName(to), to, old[to] and tostring(old[to]) or "new", time
				))
			end
		end
	end
end
io.stderr:write(("%d flight times added or changed\n"):format(numChanges))

local function numLength(x)
	return #tostring(x)
end

local function printFaction(factionTimes)
	print("\tns.FlightTimes = {")
	for _, from in ipairs(sortedKeys(factionTimes)) do
		local destinations = factionTimes[from]
		local keys = sortedKeys(destinations)
		local longestId, longestTime = 0, 0
		for _, to in ipairs(keys) do
			longestId = math.max(longestId, numLength(to))
			longestTime = math.max(longestTime, numLength(destinations[to]))
		end
		print(("\t\t[%d] = { -- %s"):format(from, nodeName(from)))
		for _, to in ipairs(keys) do
			print(("\t\t\t[%d]%s = %d,%s -- %s"):format(
				to,
				(" "):rep(longestId - numLength(to)),
				destinations[to],
				(" "):rep(longestTime - numLength(destinations[to])),
				nodeName(to)
			))
		end
		print("\t\t},")
	end
	print("\t}")
end

print[[-- This file is auto-generated, DO NOT EDIT BY HAND.
-- See import-learned.sh for details on re-generation.

local _, ns = ...
]]
for i, faction in ipairs(factions) do
	print(('%s UnitFactionGroup("player") == "%s" then'):format(i == 1 and "if" or "elseif", faction))
	printFaction(times[faction])
end
print[[else
	ns.FlightTimes = {}
end]]
