local _, ns = ...

---@class FlightCalc
local FlightCalc = {}
ns.FlightCalc = FlightCalc

---@return FlightCalc
function FlightCalc:New(flightTimes)
	return setmetatable({flightTimes = flightTimes}, {__index = FlightCalc})
end

-- Strip suffixes so it fits neatly into the timer
function FlightCalc:shortName(name)
	if GetLocale() == "koKR" then
		-- Korean names are like "foo (bar)"
		return name:gsub(" %([^)]*%)$", "")
	else
		-- All other locales are like "foo, bar"
		return name:gsub(", [^,]+$", "")
	end
end

local function positionId(x, y)
	return ("%d,%d"):format(x * 1000, y * 1000)
end

function FlightCalc:getFlightMap()
	local map, mapByPos = {}, {}
	local mapId = GetTaxiMapID()
	if not mapId then
		return nil
	end
	local nodes = C_TaxiMap.GetAllTaxiNodes(mapId)
	for _, node in ipairs(nodes) do
		local posId = positionId(node.position.x, node.position.y)
		local entry = {
			name = self:shortName(node.name),
			id = node.nodeID,
			slot = node.slotIndex,
			hops = {},
			pos = posId,
			isCurrent = node.state == Enum.FlightPathState.Current,
		}
		map[node.slotIndex] = entry
		mapByPos[posId] = entry
	end
	for _, node in ipairs(nodes) do
		local hops = GetNumRoutes(node.slotIndex)
		local entry = map[node.slotIndex]
		for hop = 1, hops do
			local posId = positionId(TaxiGetDestX(node.slotIndex, hop), TaxiGetDestY(node.slotIndex, hop))
			local hopEntry = mapByPos[posId]
			if not hopEntry then
				DBM:Debug("Route goes via unknown hop with position " .. posId)
				-- Just ignore hops completely if we can't figure them out
				-- Only the overall path in this case
				entry.hops = {entry}
				break
			end
			entry.hops[#entry.hops + 1] = hopEntry
		end
	end
	return map
end

function FlightCalc:flightTimeSingleHop(fromEntry, toEntry)
	if self.flightTimes[fromEntry.id] and self.flightTimes[fromEntry.id][toEntry.id] then
		return self.flightTimes[fromEntry.id][toEntry.id]
	else -- Flight paths are not symmetric, do not try to add a reverse lookup here
		return nil
	end
end

function FlightCalc:longestKnownPath(fromEntry, toEntry)
	for i = #toEntry.hops, 1, -1 do
		local hop = toEntry.hops[i]
		if self:flightTimeSingleHop(fromEntry, hop) then
			return hop
		end
	end
end

function FlightCalc:flightTime(fromEntry, toEntry)
	if self:flightTimeSingleHop(fromEntry, toEntry) then
		return self:flightTimeSingleHop(fromEntry, toEntry)
	else
		-- Piece together from hops if possible
		local time = 0
		local lastHop = fromEntry
		while true do
			local nextHop = self:longestKnownPath(lastHop, toEntry)
			if not nextHop then
				return nil
			end
			time = time + self:flightTimeSingleHop(lastHop, nextHop)
			if nextHop == toEntry then
				return time
			else
				time = time - 1 -- Not landing is slightly faster
			end
			lastHop = nextHop
		end
	end
end


function FlightCalc:PathToSlot(toSlot)
	local map = self:getFlightMap()
	if not map then
		return nil
	end
	local fromEntry, toEntry
	for _, entry in ipairs(map) do
		if entry.isCurrent then
			fromEntry = entry
		end
	end
	local toEntry = map[toSlot]
	if not toEntry or not fromEntry then
		return nil
	end
	DBM:Debug(("Getting flight times from %s (id %s, slot %d) to %s (id %s, slot %d)"):format(
		fromEntry.name, fromEntry.id, fromEntry.slot,
		toEntry.name, toEntry.id, toEntry.slot
	))
	local result = {}
	for i, hop in ipairs(toEntry.hops) do
		local time = self:flightTime(fromEntry, hop)
		if time then
			result[#result + 1] = {time = time, name = hop.name}
		elseif i == #toEntry.hops then
			DBM:Debug(("Timing to final destination %s (id %s, slot %d) is unknown"):format(
				toEntry.name, toEntry.id, toEntry.slot
			))
			return {} -- Don't show partial flight path even if available, that's just confusing
		end
	end
	return result
end

return ns
