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

-- The learned data kinds, how they are named in the data file, and their unit for the change report
local kinds = {
	{learned = "times", data = "FlightTimes", unit = "s"},
	{learned = "prices", data = "FlightPrices", unit = "copper"},
}

-- Base data per kind and faction, names from the comments
local function loadBase(faction)
	local ns = {}
	rawset(_G, "UnitFactionGroup", function() return faction end)
	runFile(filenameBase, nil, ns)
	return ns
end
local merged, base, names = {routes = {}}, {routes = {}}, {}
for _, kind in ipairs(kinds) do
	merged[kind.learned], base[kind.learned] = {}, {}
end
for _, faction in ipairs(factions) do
	local mergedNs, baseNs = loadBase(faction), loadBase(faction)
	for _, kind in ipairs(kinds) do
		merged[kind.learned][faction] = mergedNs[kind.data] or {}
		base[kind.learned][faction] = baseNs[kind.data] or {}
	end
	-- Times of exact routes, keyed by the node IDs of start, stops and destination ("26-28-64")
	merged.routes[faction] = mergedNs.FlightRoutes or {}
	base.routes[faction] = baseNs.FlightRoutes or {}
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
	if type(learned) ~= "table" then
		io.stderr:write("no learned flight data in " .. filename .. "\n")
	else
		for id, name in pairs(learned.names or {}) do
			-- Names are only comments; keep the existing (English) ones, learned names may be in any locale.
			names[id] = names[id] or name
		end
		for faction, learnedRoutes in pairs(learned.routes or {}) do
			if not merged.routes[faction] then
				io.stderr:write(("ignoring flight routes for faction %s in %s\n"):format(tostring(faction), filename))
			else
				for key, time in pairs(learnedRoutes) do
					-- Direct flights too: FlightTimes doesn't say which route a time is for, FlightRoutes is exact
					merged.routes[faction][key] = time
				end
			end
		end
		for _, kind in ipairs(kinds) do
			for faction, learnedValues in pairs(learned[kind.learned] or {}) do
				local target = merged[kind.learned][faction]
				if not target then
					io.stderr:write(("ignoring flight %s for faction %s in %s\n"):format(kind.learned, tostring(faction), filename))
				else
					for from, destinations in pairs(learnedValues) do
						target[from] = target[from] or {}
						for to, value in pairs(destinations) do
							target[from][to] = value
						end
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

for _, kind in ipairs(kinds) do
	local numChanges = 0
	for _, faction in ipairs(factions) do
		local values = merged[kind.learned][faction]
		for _, from in ipairs(sortedKeys(values)) do
			local old = base[kind.learned][faction][from] or {}
			for _, to in ipairs(sortedKeys(values[from])) do
				local value = values[from][to]
				if old[to] ~= value then
					numChanges = numChanges + 1
					io.stderr:write(("%s: %s (%d) -> %s (%d): %s -> %d %s\n"):format(
						faction, nodeName(from), from, nodeName(to), to, old[to] and tostring(old[to]) or "new", value, kind.unit
					))
				end
			end
		end
	end
	io.stderr:write(("%d flight %s added or changed\n"):format(numChanges, kind.learned))
end

local function routeName(key)
	local stops = {}
	for id in key:gmatch("%d+") do
		stops[#stops + 1] = nodeName(tonumber(id))
	end
	return table.concat(stops, " > ")
end

local numRouteChanges = 0
for _, faction in ipairs(factions) do
	for _, key in ipairs(sortedKeys(merged.routes[faction])) do
		local old, time = base.routes[faction][key], merged.routes[faction][key]
		if old ~= time then
			numRouteChanges = numRouteChanges + 1
			io.stderr:write(("%s: %s (%s): %s -> %d s\n"):format(faction, routeName(key), key, old and tostring(old) or "new", time))
		end
	end
end
io.stderr:write(("%d flight routes added or changed\n"):format(numRouteChanges))

local function numLength(x)
	return #tostring(x)
end

local function printRoutes(routes)
	print("\tns.FlightRoutes = {")
	local keys = sortedKeys(routes)
	local longestKey, longestTime = 0, 0
	for _, key in ipairs(keys) do
		longestKey = math.max(longestKey, #key)
		longestTime = math.max(longestTime, numLength(routes[key]))
	end
	for _, key in ipairs(keys) do
		print(("\t\t[%q]%s = %d,%s -- %s"):format(
			key,
			(" "):rep(longestKey - #key),
			routes[key],
			(" "):rep(longestTime - numLength(routes[key])),
			routeName(key)
		))
	end
	print("\t}")
end

local function printTable(name, values)
	print(("\tns.%s = {"):format(name))
	for _, from in ipairs(sortedKeys(values)) do
		local destinations = values[from]
		local keys = sortedKeys(destinations)
		local longestId, longestValue = 0, 0
		for _, to in ipairs(keys) do
			longestId = math.max(longestId, numLength(to))
			longestValue = math.max(longestValue, numLength(destinations[to]))
		end
		print(("\t\t[%d] = { -- %s"):format(from, nodeName(from)))
		for _, to in ipairs(keys) do
			print(("\t\t\t[%d]%s = %d,%s -- %s"):format(
				to,
				(" "):rep(longestId - numLength(to)),
				destinations[to],
				(" "):rep(longestValue - numLength(destinations[to])),
				nodeName(to)
			))
		end
		print("\t\t},")
	end
	print("\t}")
end

print[[-- This file is auto-generated, DO NOT EDIT BY HAND.
-- See import-learned.sh for details on re-generation.
-- FlightRoutes are seconds for exact routes (keyed by the node IDs of start, stops and destination), FlightTimes are
-- seconds between two nodes on an unknown route (InFlight data and older measurements), FlightPrices are in copper
-- (prices are not used by the AddOn yet).

local _, ns = ...
]]
for i, faction in ipairs(factions) do
	print(('%s UnitFactionGroup("player") == "%s" then'):format(i == 1 and "if" or "elseif", faction))
	for _, kind in ipairs(kinds) do
		-- Only write tables that have data, so a data file without prices stays unchanged
		if next(merged[kind.learned][faction]) or kind.learned == "times" then
			printTable(kind.data, merged[kind.learned][faction])
		end
		if kind.learned == "times" and next(merged.routes[faction]) then
			printRoutes(merged.routes[faction])
		end
	end
end
print[[else
	ns.FlightTimes = {}
end]]
