local _, ns = ...

---@class FlightCalc
---@field flightTimes table<number, table<number, number>>
---@field getLearnedTimes (fun(): table<number, table<number, number>>?)?
local FlightCalc = {}
ns.FlightCalc = FlightCalc

---@param flightTimes table<number, table<number, number>> Shipped times: [fromNodeId][toNodeId] = seconds
---@param getLearnedTimes (fun(): table<number, table<number, number>>?)? Times measured in game, preferred over shipped ones
---@return FlightCalc
function FlightCalc:New(flightTimes, getLearnedTimes)
	return setmetatable({flightTimes = flightTimes, getLearnedTimes = getLearnedTimes}, {__index = FlightCalc})
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

-- Retired nodes the client still returns ("zzOLD..." Riverglades nodes on Forever), some on top of real ones
local ignoredNodes = {
	[3206] = true, -- zzOLDBolder'ok, Riverglades
	[3207] = true, -- zzOLDRiverglades, Farholde Keep (at Southshore)
	[3208] = true, -- zzOLDPowderfuse Port, Riverglades (at Ratchet)
}

local function positionId(x, y)
	return ("%d,%d"):format(x * 1000, y * 1000)
end

function FlightCalc:getFlightMap()
	local map, mapByPos = {}, {}
	local mapId = GetTaxiMapID()
	if not mapId then
		return nil
	end
	local nodes = {}
	for _, node in ipairs(C_TaxiMap.GetAllTaxiNodes(mapId)) do
		if not ignoredNodes[node.nodeID] then
			nodes[#nodes + 1] = node
		end
	end
	for _, node in ipairs(nodes) do
		local posId = positionId(node.position.x, node.position.y)
		local entry = {
			name = self:shortName(node.name),
			fullName = node.name,
			id = node.nodeID,
			slot = node.slotIndex,
			hops = {},
			pos = posId,
			isCurrent = node.state == Enum.FlightPathState.Current,
			isUnreachable = node.state == Enum.FlightPathState.Unreachable,
		}
		map[node.slotIndex] = entry
		-- Nodes can share a position, prefer one we can fly to
		local other = mapByPos[posId]
		if other then
			DBM:Debug(("Taxi nodes %s (id %s) and %s (id %s) share position %s"):format(other.name, other.id, entry.name, entry.id, posId))
		end
		if not other or other.isUnreachable and not entry.isUnreachable then
			mapByPos[posId] = entry
		end
	end
	for _, node in ipairs(nodes) do
		local hops = GetNumRoutes(node.slotIndex)
		local entry = map[node.slotIndex]
		for hop = 1, hops do
			local posId = positionId(TaxiGetDestX(node.slotIndex, hop), TaxiGetDestY(node.slotIndex, hop))
			-- The last hop is the destination itself
			local hopEntry = hop == hops and entry or mapByPos[posId]
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

function FlightCalc:knownFlightTime(fromId, toId)
	local learned = self.getLearnedTimes and self.getLearnedTimes()
	local time = learned and learned[fromId] and learned[fromId][toId]
	if time then
		return time
	end
	return self.flightTimes[fromId] and self.flightTimes[fromId][toId]
end

function FlightCalc:flightTimeSingleHop(fromEntry, toEntry, allowReverse)
	return self:knownFlightTime(fromEntry.id, toEntry.id) or allowReverse and self:knownFlightTime(toEntry.id, fromEntry.id) or nil
end

-- Furthest hop on the route to toEntry, after hop number afterIndex, with a known time from fromEntry
function FlightCalc:longestKnownPath(fromEntry, toEntry, afterIndex, allowReverse)
	for i = #toEntry.hops, afterIndex + 1, -1 do
		local hop = toEntry.hops[i]
		if self:flightTimeSingleHop(fromEntry, hop, allowReverse) then
			return hop, i
		end
	end
end

function FlightCalc:flightTimeFromKnownTimes(fromEntry, toEntry, allowReverse)
	local direct = self:flightTimeSingleHop(fromEntry, toEntry, allowReverse)
	if direct then
		return direct
	end
	-- Piece together from hops if possible
	local time = 0
	local lastHop, lastIndex = fromEntry, 0
	while true do
		-- Only ever move forward along the route, reverse times could otherwise lead back to an earlier hop
		local nextHop, nextIndex = self:longestKnownPath(lastHop, toEntry, lastIndex, allowReverse)
		if not nextHop then
			return nil
		end
		time = time + self:flightTimeSingleHop(lastHop, nextHop, allowReverse)
		if nextHop == toEntry then
			return time
		else
			time = time - 1 -- Not landing is slightly faster
		end
		lastHop, lastIndex = nextHop, nextIndex
	end
end

function FlightCalc:flightTime(fromEntry, toEntry)
	-- Flight paths are not symmetric (routes can differ by direction), so reverse times are only a fallback
	return self:flightTimeFromKnownTimes(fromEntry, toEntry, false) or self:flightTimeFromKnownTimes(fromEntry, toEntry, true)
end


---Timers for each hop of the flight to toSlot, plus the start and destination nodes so the flight time can be learned.
---The hop list is empty if the time to the destination is unknown.
---@return {time: number, name: string}[]? hops
---@return table? fromEntry
---@return table? toEntry
function FlightCalc:PathToSlot(toSlot)
	local map = self:getFlightMap()
	if not map then
		return nil
	end
	local fromEntry
	-- Slots can have gaps (ignored nodes), so no ipairs
	for _, entry in pairs(map) do
		if entry.isCurrent then
			fromEntry = entry
		end
	end
	local toEntry = map[toSlot]
	if not toEntry or not fromEntry then
		return nil
	end
	-- Stops before the destination, which is always the last hop
	local stops = {}
	for i = 1, #toEntry.hops - 1 do
		stops[i] = ("%s (id %s)"):format(toEntry.hops[i].name, toEntry.hops[i].id)
	end
	DBM:Debug(("Getting flight times from %s (id %s, slot %d) to %s (id %s, slot %d), %s, shipped data %s"):format(
		fromEntry.name, fromEntry.id, fromEntry.slot,
		toEntry.name, toEntry.id, toEntry.slot,
		#stops > 0 and "via " .. table.concat(stops, ", ") or "direct", next(self.flightTimes) and "loaded" or "empty"
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
			return {}, fromEntry, toEntry -- Don't show partial flight path even if available, that's just confusing
		end
	end
	return result, fromEntry, toEntry
end

return ns
