local _, ns = ...
local mod = DBM:NewMod("FlightTimers", "DBM-FlightTimers")
local L   = mod:GetLocalizedStrings()

mod:SetRevision("20231208180000")
mod:SetZone(DBM_DISABLE_ZONE_DETECTION)
mod:RegisterEvents(
	"PLAYER_CONTROL_LOST",
	"PLAYER_CONTROL_GAINED"
)

mod.state = "IDLE" -- IDLE | WAIT_FOR_START | IN_FLIGHT | LEARNING
mod.flightPath = {}
mod.flightRequestTime = 0
mod.controlLostTime = 0

local timer = mod:NewIntermissionTimer(0, nil, "%s", true, "TimerOption", nil, "136106")
local timerVia = mod:NewIntermissionTimer(0, nil, "Via %s", true, "TimerViaOption", nil, "136106")
timer.startLarge = true
timerVia.startLarge = true

local flightCalc = ns.FlightCalc:New(ns.FlightTimes)

function mod:PLAYER_CONTROL_LOST()
	if self.state ~= "WAIT_FOR_START" then return end
	local delay = GetTime() - self.flightRequestTime
	if delay > 5 then
		DBM:Debug("PLAYER_CONTROL_LOST " .. delay .. " seconds after TakeTaxiNodes, ignoring")
		self.state = "IDLE"
		return
	end
	self.state = "IN_FLIGHT"
	self.controlLostTime = GetTime()
	self.earlyLandingRequested = nil
	for i, hop in ipairs(self.flightPath) do
		if i == #self.flightPath then
			hop.timer = timer:Start(hop.time, hop.name)
		else
			hop.timer = timerVia:Start(hop.time, hop.name)
		end
	end
end

function mod:CancelFlight()
	timer:Stop()
	timerVia:Stop()
	self.state = "IDLE"
end

function mod:OnEarlyLandingRequest()
	if self.earlyLandingRequested then return end
	self.earlyLandingRequested = true
	if self.state ~= "IN_FLIGHT" then return end
	local elapsed = GetTime() - self.controlLostTime
	local newLastHopIndex = #self.flightPath
	local newLastHop
	for i, hop in ipairs(self.flightPath) do
		if elapsed < hop.time then
			newLastHopIndex = i
			newLastHop = hop
			break
		end
	end
	DBM:Debug(("Early landing requested after %d seconds, new final destination is %s, new total flight time %d"):format(
		elapsed,
		newLastHop and newLastHop.name or "nil",
		newLastHop and newLastHop.time or 0
	))
	if newLastHopIndex == #self.flightPath then
		 -- Cancel before final destination doesn't do anything
		 -- But we still want to set the earlyLanding flag above in case we messed up timers
		return
	end
	local lastHopTimer = self.flightPath[#self.flightPath].timer
	if lastHopTimer then
		-- We have to update the actual final destination timer because the viaTimers may be disabled
		lastHopTimer:SetText(newLastHop.name)
		-- Raw DBT objects are a bit weird, SetTimer preserves remaining time
		-- We need to call both to make bar fill state and remaining time correct
		lastHopTimer:SetTimer(newLastHop.time)
		lastHopTimer:SetElapsed(elapsed)
	end
	-- Cancel via timer for the new final destination but not the final stop
	for i = newLastHopIndex, #self.flightPath - 1 do
		if self.flightPath[i].timer then
			self.flightPath[i].timer:Cancel()
		end
	end
end

function mod:PLAYER_CONTROL_GAINED()
	if self.state ~= "IN_FLIGHT" then return end
	-- TODO: learn timing here if it's off or if we didn't know at all before
	-- note: don't do this if earlyLandingRequested is set because we could mess this up
	local actualTime = GetTime() - self.controlLostTime
	local lastHop = self.flightPath[#self.flightPath]
	if lastHop then
		DBM:Debug(("Flight took %d seconds (%d predicted)"):format(actualTime, lastHop.time))
	end
	self:CancelFlight()
end

local function TakeTaxiNodeHook(slot)
	local flightPath = flightCalc:PathToSlot(slot)
	if flightPath then
		mod.flightRequestTime = GetTime()
		mod.flightPath = flightPath
		mod.state = "WAIT_FOR_START"
	else
		DBM:Debug("Failed to calculate flight path to slot " .. tostring(slot))
	end
end
hooksecurefunc("TakeTaxiNode", TakeTaxiNodeHook)


local function TaxiRequestEarlyLandingHook()
	mod:OnEarlyLandingRequest()
end
hooksecurefunc("TaxiRequestEarlyLanding", TaxiRequestEarlyLandingHook)

local function AcceptBattlefieldPortHook(index, acceptFlag)
	if acceptFlag then
		mod:CancelFlight()
	end
end
hooksecurefunc("AcceptBattlefieldPort", AcceptBattlefieldPortHook)

local function ConfirmSummonHook()
	mod:CancelFlight()
end
hooksecurefunc(C_SummonInfo, "ConfirmSummon", ConfirmSummonHook)

local function getAllContinents()
	local r = {}
	for i = 1, 5000 do -- highest number currently: 2225
		local mapInfo = C_Map.GetMapInfo(i)
		if mapInfo and mapInfo.mapType == Enum.UIMapType.Continent then
			r[#r + 1] = i
			DBM:Debug(("Found continent %d: %s"):format(i, mapInfo.name))
		end
	end
	return r
end

local function dumpTaxiNodes()
	local ids = {}
	local nodes = {}
	for _, mapId in ipairs(getAllContinents()) do
		for _, node in ipairs(C_TaxiMap.GetTaxiNodesForMap(mapId)) do
			local entry = {
				id = node.nodeID,
				name = node.name,
				continent = mapId,
				faction = node.faction == Enum.FlightPathFaction.Neutral and "Neutral"
					or node.faction == Enum.FlightPathFaction.Horde and "Horde"
					or node.faction == Enum.FlightPathFaction.Alliance and "Alliance"
			}
			if ids[node.nodeID] and ids[node.nodeID].name ~= entry.name then
				-- All continents are duplicated in Classic for some reason, so only trigger on name conflict
				DBM:Debug(("Duplicate nodeID: %d, used by %s and %s"):format(
					node.nodeID, entry.name, ids[node.nodeID].name
				))
			elseif not ids[node.nodeID] then
				ids[node.nodeID] = entry
				nodes[#nodes + 1] = entry
			end
		end
	end
	table.sort(nodes, function (a, b)
		return a.id < b.id
	end)
	return nodes
end

local function getMetadata()
	return ("-- Release: %s (Season: %d)"):format(
		WOW_PROJECT_ID == WOW_PROJECT_MAINLINE and "Retail"
		or WOW_PROJECT_ID == WOW_PROJECT_CLASSIC and "Classic"
		or "Unknown",
		(C_Seasons and C_Seasons.GetActiveSeason() or -1)
	)
end

local function numLength(x)
	return math.floor(math.log10(x)) + 1
end

function mod:DumpFlightPoints()
	local metadata = getMetadata()
	local file =
[[-- This file is auto-generated, DO NOT EDIT BY HAND.
-- Run this in game to re-generate: /run DBM:GetModByName("FlightTimers"):DumpFlightPoints()
-- Do not translate this file, these strings are only used to generate the data files for the AddOn.
-- The AddOn itself gets the localized name from the client.

%s
return {
%s
}
]]
	local lines = {}
	local nodes = dumpTaxiNodes()
	local longestId = numLength(nodes[#nodes].id)
	for _, node in ipairs(nodes) do
		local idLen = numLength(node.id)
		local idPad = (" "):rep(longestId - idLen)
		local factionPad = (" "):rep(#"Alliance" - #node.faction)
		local line = ("\t{id = %d,%s faction = %q,%s name = %q},"):format(
			node.id,
			idPad,
			node.faction,
			factionPad,
			node.name
		)
		lines[#lines + 1] = line
	end
	file = file:format(metadata, table.concat(lines, "\n"))
	DBM:ShowUpdateReminder(nil, nil, "Copy and paste this into the appropriate file\n" .. metadata, file)
end