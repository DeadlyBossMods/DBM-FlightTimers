-- Usage: lua Importer.lua <defaults.lua file from InFlight> <FlightPoints-Classic|Classic-WotLK|Retail>.lua <Base Data> > <Classic/Retail/...>.lua
-- See import.sh for re-generating all flight timnings.

-- The inflight data is in turn based on crowdsourced contributions here:
-- https://www.wowinterface.com/forums/showthread.php?t=18997&page=27
-- If this mod ever receives traction we could setup something a bit more sophisticated.

local filenameInflight, filenameFlightpoints, filenameBase = ...

local function abort(err)
	io.stderr:write(err)
	io.stderr:write("\n")
	os.exit(1)
end

if not filenameInflight or not filenameFlightpoints then
	return abort("Usage: lua Importer.lua <defaults.lua file from InFlight> <FlightPoints-Classic|Classic-WotLK|Retail>.lua <Base Data>\n"
		.. "Optional <Base Data>.lua allows loading a previously loaded file and only adding timers not already present there. "
		.. "This is used to load Classic timers for WotLK and then layer Retail data on top without messing up old routes changed later.")
end

---@return table
local function loadOrError(filename, ...)
	local chunk = loadfile(filename)
	if not chunk then
		abort("could not load " .. filename)
		return {} -- unreachable but makes LuaLS happy
	end
	local ok, res = pcall(chunk, ...)
	if not ok then
		abort("error while loading " .. filename .. "\n" .. tostring(res))
	end
	return res
end

InFlight = {}
loadOrError(filenameInflight)
if not InFlight.defaults
or not InFlight.defaults.global
or not InFlight.defaults.global.Horde
or not InFlight.defaults.global.Alliance then
	abort("could not find data after loading InFlight file")
end

local flightPoints = loadOrError(filenameFlightpoints)

local baseFlightData = {}
if filenameBase then
	local faction = "Horde"
	_G.UnitFactionGroup = function() return faction end
	local ns = {}
	loadOrError(filenameBase, nil, ns)
	baseFlightData.Horde = ns.FlightTimes
	faction = "Alliance"
	loadOrError(filenameBase, nil, ns)
	baseFlightData.Alliance = ns.FlightTimes
end

local function numLength(x)
	return math.floor(math.log10(x)) + 1
end

local function shortenName(name)
	return name:gsub(", [^,]+$", "")
end

-- Override everything in input with data from base (adding if non-existant)
local function applyBaseLayer(input, base, flightPointsById)
	if not base then return end
	for baseFrom, baseDestinations in pairs(base) do
		local fromPoint = flightPointsById[baseFrom]
		if not fromPoint then
			error("unknown src flight point in base " .. baseFrom)
		end
		if not input[fromPoint.name] and not input[baseFrom] then
			input[baseFrom] = baseDestinations
		else
			local inputDestinations = input[baseFrom] or input[fromPoint.name]
			for baseDest, time in pairs(baseDestinations) do
				local baseDestPoint = flightPointsById[baseDest]
				if not baseDestPoint then
					error("unknown dst flight point in base " .. baseFrom)
				end
				local key = inputDestinations[baseDest] and baseDest or inputDestinations[baseDestPoint.name] and baseDestPoint.name or baseDest
				inputDestinations[key] = time
			end
		end
	end
end

local function buildFor(faction)
	local flightPointsByShortName, flightPointsById = {}, {}
	for _, point in ipairs(flightPoints) do
		-- have to filter by faction because, e.g., Booty Bay has horde and alliance paths with same name but different id
		if point.faction == "Neutral" or point.faction == faction then
			local shortName = shortenName(point.name)
			if flightPointsByShortName[shortName] then
				io.stderr:write(("name collision for short name %s: %s (%d) and %s (%d)\n"):format(
					shortName,
					flightPointsByShortName[shortName].name, flightPointsByShortName[shortName].id,
					point.name, point.id
				))
			end
			flightPointsByShortName[shortName] = point
			flightPointsByShortName[point.id] = point
			flightPointsById[point.id] = point
		end
	end
	local output = {}
	local input = InFlight.defaults.global[faction]
	applyBaseLayer(input, baseFlightData[faction], flightPointsById)
	for from, inDestinations in pairs(input) do
		local fromPoint = flightPointsByShortName[from]
		if not fromPoint then
			io.stderr:write("unknown source flight point: " .. from .. "\n")
		else
			local outDestinations = {}
			for dest, time in pairs(inDestinations) do
				if dest ~= "name" then
					local toPoint = flightPointsByShortName[dest]
					if not toPoint then
						io.stderr:write("unknown destination flight point: " .. from .. "\n")
					else
						outDestinations[#outDestinations + 1] = {time = time, name = toPoint.name, id = toPoint.id}
					end
				end
			end
			table.sort(outDestinations, function(a, b)
				return a.id < b.id
			end)
			output[#output + 1] = {name = fromPoint.name, id = fromPoint.id, destinations = outDestinations}
		end
	end
	table.sort(output, function(a, b)
		return a.id < b.id
	end)
	local result = {}
	result[#result + 1] = "ns.FlightTimes = {"
	for _, from in ipairs(output) do
		local longestId, longestTime = 0, 0
		for _, to in ipairs(from.destinations) do
			longestId = math.max(longestId, numLength(to.id))
			longestTime = math.max(longestTime, numLength(to.time))
		end
		result[#result + 1] = ("\t[%d] = { -- %s"):format(from.id, from.name)
		for _, to in ipairs(from.destinations) do
			result[#result + 1] = ("\t\t[%d]%s = %d,%s -- %s"):format(
				to.id,
				(" "):rep(longestId - numLength(to.id)),
				to.time,
				(" "):rep(longestTime - numLength(to.time)),
				to.name
			)
		end
		result[#result + 1] = ("\t},"):format(from.id, from.name)
	end
	result[#result + 1] = "}"
	return result
end


print[[-- This file is auto-generated, DO NOT EDIT BY HAND.
-- See import.sh for details on re-generation.

local _, ns = ...

if UnitFactionGroup("player") == "Horde" then]]
for _, line in ipairs(buildFor("Horde")) do
	print("\t" .. line)
end
print[[elseif UnitFactionGroup("player") == "Alliance" then]]
for _, line in ipairs(buildFor("Alliance")) do
	print("\t" .. line)
end
print[[else
	error("could not find faction")
end]]