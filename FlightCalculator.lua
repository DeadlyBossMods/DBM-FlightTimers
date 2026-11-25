local _, ns = ...

-- Flight times come in two shapes:
-- * routes: [routeKey] = seconds for one exact route, routeKey is the node IDs of start, stops and destination ("26-28-64")
-- * times: [fromNodeId][toNodeId] = seconds without the route (the shipped InFlight data, and times learned before
--   routes were saved). They are for whatever route the game picked when they were measured, which depends on the
--   flight points that player knew, so even a time between two neighbouring stops may be for a route with more stops.

---@class FlightCalc
---@field flightTimes table<number, table<number, number>>
---@field flightRoutes table<string, number>
---@field getLearned (fun(kind: "times"|"routes"): table?)?
local FlightCalc = {}
ns.FlightCalc = FlightCalc

---@param flightTimes table<number, table<number, number>> Shipped times without routes
---@param getLearned (fun(kind: "times"|"routes"): table?)? Data measured in game, preferred over shipped data
---@param flightRoutes table<string, number>? Shipped times of exact routes
---@return FlightCalc
function FlightCalc:New(flightTimes, getLearned, flightRoutes)
	return setmetatable({flightTimes = flightTimes, getLearned = getLearned, flightRoutes = flightRoutes or {}}, {__index = FlightCalc})
end

---@param ids number[]
function FlightCalc.RouteKey(ids, first, last)
	return table.concat(ids, "-", first or 1, last or #ids)
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
				entry.routeUnknown = true
				break
			end
			entry.hops[#entry.hops + 1] = hopEntry
		end
	end
	return map
end

local function lookupTime(times, fromId, toId)
	return times and times[fromId] and times[fromId][toId]
end

-- Time between two nodes without route information (learned, then shipped)
function FlightCalc:fromToTime(fromId, toId)
	return lookupTime(self.getLearned and self.getLearned("times"), fromId, toId) or lookupTime(self.flightTimes, fromId, toId)
end

-- Time of exactly the route ids[first..last] (learned, then shipped)
function FlightCalc:exactRouteTime(ids, first, last)
	local key = self.RouteKey(ids, first, last)
	local learned = self.getLearned and self.getLearned("routes")
	return learned and learned[key] or self.flightRoutes[key]
end

-- Time of ids[first..last], and whether it is known for exactly that route.
-- A single leg can also come from times without a route, which are usually (but not always) for the direct flight.
---@return number? time
---@return boolean? exact
function FlightCalc:segmentTime(ids, first, last, allowReverse)
	local exact = self:exactRouteTime(ids, first, last)
	if exact then
		return exact, true
	end
	local leg = last == first + 1 and self:fromToTime(ids[first], ids[last])
	if leg or not allowReverse then
		return leg or nil, false
	end
	local reversed = {}
	for i = last, first, -1 do
		reversed[#reversed + 1] = ids[i]
	end
	exact = self:exactRouteTime(reversed)
	if exact then
		return exact, true
	end
	return last == first + 1 and self:fromToTime(ids[last], ids[first]) or nil, false
end

-- Piece the route ids[1..last] together from known segments: fewest segments without a known route, then fewest segments
---@return number? time
---@return boolean? exact All segments are known for exactly this route
function FlightCalc:piecedTime(ids, last, allowReverse)
	-- best[pos] = {inexact segments, segments, time} for the route ids[1..pos]
	local best = {[1] = {0, 0, 0}}
	for pos = 2, last do
		for from = 1, pos - 1 do
			local segment, exact
			if best[from] then
				segment, exact = self:segmentTime(ids, from, pos, allowReverse)
			end
			if segment then
				local inexact, segments = best[from][1] + (exact and 0 or 1), best[from][2] + 1
				local current = best[pos]
				if not current or inexact < current[1] or inexact == current[1] and segments < current[2] then
					-- Flying past a stop instead of landing there is slightly faster
					best[pos] = {inexact, segments, best[from][3] + segment - (from > 1 and 1 or 0)}
				end
			end
		end
	end
	if best[last] then
		return best[last][3], best[last][1] == 0
	end
end

---Time from ids[1] to ids[last] along exactly this route.
---@param ids number[] Node IDs of start, stops and destination
---@param routeUnknown boolean? The stops couldn't be resolved, only start and destination are known
---@return number? time
---@return string? source
function FlightCalc:routeTime(ids, last, routeUnknown, allowReverse)
	local fromId, toId = ids[1], ids[last]
	local fromTo = self:fromToTime(fromId, toId) or allowReverse and self:fromToTime(toId, fromId) or nil
	if routeUnknown then
		return fromTo, fromTo and "start to destination, route unknown"
	end
	if last == 2 then
		local time, exact = self:segmentTime(ids, 1, 2, allowReverse)
		return time, time and (exact and "direct" or "direct, from data without route")
	end
	local exactTime = self:exactRouteTime(ids, 1, last)
	if exactTime then
		return exactTime, "exact route"
	end
	-- A start to destination time may be for another route, but pieced times are worse: flying past a stop instead of
	-- landing saves anywhere from 0 to 49 s (Ironforge) on Forever, so they can't even tell whether the route differs.
	-- An unexpected route is wrong once, after that flight its exact time is known.
	if fromTo then
		return fromTo, "start to destination"
	end
	local pieced, piecedExact = self:piecedTime(ids, last, allowReverse)
	return pieced, pieced and (piecedExact and "pieced from exact routes" or "pieced")
end

function FlightCalc:flightTime(ids, last, routeUnknown)
	-- Flight paths are not symmetric (routes can differ by direction), so reverse times are only a fallback
	local time, source = self:routeTime(ids, last, routeUnknown, false)
	if time then
		return time, source
	end
	time, source = self:routeTime(ids, last, routeUnknown, true)
	return time, source and source .. ", reverse"
end


---Timers for each hop of the flight to toSlot, plus the start and destination nodes so the flight time can be learned.
---The hop list is empty if the time to the destination is unknown.
---@return {time: number, name: string}[]? hops
---@return table? fromEntry
---@return table? toEntry
---@return number[]? routeIds Node IDs of start, stops and destination, nil if the stops couldn't be resolved
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
		toEntry.routeUnknown and "route unknown" or #stops > 0 and "via " .. table.concat(stops, ", ") or "direct",
		next(self.flightTimes) and "loaded" or "empty"
	))
	local ids = {fromEntry.id}
	for i, hop in ipairs(toEntry.hops) do
		ids[i + 1] = hop.id
	end
	local routeIds = not toEntry.routeUnknown and ids or nil
	local result, sources = {}, {}
	for i, hop in ipairs(toEntry.hops) do
		local time, source = self:flightTime(ids, i + 1, toEntry.routeUnknown)
		if time then
			result[#result + 1] = {time = time, name = hop.name}
			sources[#sources + 1] = ("%s %d s (%s)"):format(hop.name, time, source)
		elseif i == #toEntry.hops then
			DBM:Debug(("Timing to final destination %s (id %s, slot %d) is unknown"):format(
				toEntry.name, toEntry.id, toEntry.slot
			))
			return {}, fromEntry, toEntry, routeIds -- Don't show partial flight path even if available, that's just confusing
		end
	end
	DBM:Debug("Flight time sources: " .. table.concat(sources, ", "))
	return result, fromEntry, toEntry, routeIds
end

return ns
