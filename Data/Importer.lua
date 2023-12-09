-- Usage: lua Importer.lua <defaults.lua file from InFlight> > Classic.lua

-- The inflight data is in turn based on crowdsourced contributions here:
-- https://www.wowinterface.com/forums/showthread.php?t=18997&page=27
-- If this mod ever receives traction we could setup something a bit more sophisticated.

local filename = ...

local function abort(err)
	io.stderr:write(err)
	io.stderr:write("\n")
	os.exit(1)
end

if not filename then
	return abort("Usage: lua Importer.lua <defaults.lua file from InFlight>")
end

local header =
[[-- This file is auto-generated, DO NOT EDIT BY HAND.
-- See Importer.lua for details on re-generation.

local _, ns = ...

if UnitFactionGroup("player") == "Horde" then]]
local mid = [[elseif UnitFactionGroup("player") == "Alliance" then]]
local footer =
[[else
	error("could not find faction")
end]]

InFlight = {}
local inflightChunk = loadfile(filename)
if not inflightChunk then
	return abort("could not load " .. filename)
end
inflightChunk()

if not InFlight.defaults
or not InFlight.defaults.global
or not InFlight.defaults.global.Horde
or not InFlight.defaults.global.Alliance then
	abort("could not find data after loading InFlight file")
end

local flightPoints = loadfile("FlightPoints-Classic.lua")()

local function numLength(x)
	return math.floor(math.log10(x)) + 1
end

local function buildFor(faction)
	local flightPointsByShortName = {}
	for _, point in ipairs(flightPoints) do
		-- have to filter by faction because, e.g., Booty Bay has horde and alliance paths with same name but different id
		if point.faction == "Neutral" or point.faction == faction then
			local shortName = point.name:gsub(", [^,]+$", "")
			if flightPointsByShortName[shortName] then
				error("name collision for short name " .. shortName)
			end
			flightPointsByShortName[shortName] = point
		end
	end
	local output = {}
	local input = InFlight.defaults.global[faction]
	for from, inDestinations in pairs(input) do
		local fromPoint = flightPointsByShortName[from]
		if not fromPoint then
			error("unknown flight point: " .. from)
		end
		local outDestinations = {}
		for dest, time in pairs(inDestinations) do
			local toPoint = flightPointsByShortName[dest]
			if not toPoint then
				error("unknown flight point: " .. dest)
			end
			outDestinations[#outDestinations + 1] = {time = time, name = toPoint.name, id = toPoint.id}
		end
		table.sort(outDestinations, function(a, b)
			return a.id < b.id
		end)
		output[#output + 1] = {name = fromPoint.name, id = fromPoint.id, destinations = outDestinations}
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

print(header)
for _, line in ipairs(buildFor("Horde")) do
	print("\t" .. line)
end
print(mid)
for _, line in ipairs(buildFor("Alliance")) do
	print("\t" .. line)
end
print(footer)