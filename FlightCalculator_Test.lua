local lu = require "luaunit"

local function makeEnv(env, base)
	return setmetatable(env, { __index = base or _G })
end

-- luaunit finds tests through globals and the loaded files expect DBM to be one; rawset keeps these deliberate
rawset(_G, "DBM", {
	Debug = function(self, msg)
		print(msg)
	end
})

local tests = {}

local function loadWoWModFile(name, env, modName)
	if not name:match("%.lua$") then
		name = name .. ".lua"
	end
	env = env or makeEnv(_G)
	modName = modName or name
	local chunk = loadfile(name)
	if not chunk then error("couldn't load " .. name) end
	setfenv(chunk, env)
	local ns = {}
	chunk(modName or name, ns)
	return ns
end

function tests.TestShortNameRegex()
	local locale = "enUS"
	local fc = loadWoWModFile("FlightCalculator", {
		GetLocale = function()
			return locale
		end
	})
	lu.assertEquals(fc.FlightCalc:shortName("foo"), "foo")
	lu.assertEquals(fc.FlightCalc:shortName("foo, bar"), "foo")
	lu.assertEquals(fc.FlightCalc:shortName("foo, bar, baz"), "foo, bar")
	lu.assertEquals(fc.FlightCalc:shortName("foo,bar"), "foo,bar")
	locale = "koKR"
	lu.assertEquals(fc.FlightCalc:shortName("foo"), "foo")
	lu.assertEquals(fc.FlightCalc:shortName("foo (bar)"), "foo")
	lu.assertEquals(fc.FlightCalc:shortName("foo (bar) (baz)"), "foo (bar)")
	lu.assertEquals(fc.FlightCalc:shortName("foo(bar)baz"), "foo(bar)baz")
end

Enum = {FlightPathState = {Current = 0, Reachable = 1, Unreachable = 2}}

local baseMock = makeEnv({
	GetLocale = function() return "enUS" end,
})

local numMockNodes = 5
local mockTaxiMap = makeEnv({
	C_TaxiMap = {
		GetAllTaxiNodes = function()
			local r = {}
			for i = 1, numMockNodes do
				r[#r + 1] = {
					name = "Node " .. i,
					slotIndex = i,
					nodeID = i * 10,
					position = {
						x = i / numMockNodes,
						y = i / numMockNodes,
					},
					state = i == 1 and Enum.FlightPathState.Current or Enum.FlightPathState.Reachable,
				}
			end
			return r
		end
	},
	GetTaxiMapID = function() return 0 end,
	GetNumRoutes = function(slot) return slot - 1 end,
	TaxiGetDestX = function(slot, hop) return (hop + 1) / numMockNodes end,
	TaxiGetDestY = function(slot, hop) return (hop + 1) / numMockNodes end,
}, baseMock)

local times = {
	-- 1 -> 2 -> 3 -> 4 with 11 second between each hop (10 if not landing)
	-- but 1->4 is missing data, needs to be pieced together from from 1->3 and 3->4
	-- 5 exists but is disconnected from the rest
	[10] = {
		[20] = 11,
		[30] = 21,
	},
	[20] = {
		[30] = 11,
		[40] = 22,
	},
	[30] = {
		[40] = 11,
	},
	[40] = {},
}

function tests.TestGetFlightTimes()
	local fc = loadWoWModFile("FlightCalculator", mockTaxiMap)
	local cal = fc.FlightCalc:New(times)
	lu.assertEquals(cal:PathToSlot(1), {})
	lu.assertEquals(cal:PathToSlot(2), {{name="Node 2", time=11}})
	lu.assertEquals(cal:PathToSlot(4), {
		{name="Node 2", time=11},
		{name="Node 3", time=21},
		{name="Node 4", time=31},
	})
	lu.assertEquals(cal:PathToSlot(5), {})
end

function tests.TestLearnedFlightTimes()
	local fc = loadWoWModFile("FlightCalculator", mockTaxiMap)
	local learned = nil
	local cal = fc.FlightCalc:New(times, function() return learned end)
	-- Nothing learned yet (SavedVariables not loaded): shipped data, start and destination for learning
	local path, from, to = cal:PathToSlot(5)
	assert(from and to)
	lu.assertEquals(path, {})
	lu.assertEquals({from.id, from.fullName, to.id, to.fullName}, {10, "Node 1", 50, "Node 5"})
	learned = {
		[10] = {
			[20] = 12, -- overrides shipped 11
			[50] = 60, -- unknown in shipped data
		},
	}
	lu.assertEquals(cal:PathToSlot(2), {{name="Node 2", time=12}})
	lu.assertEquals(cal:PathToSlot(5), {
		{name="Node 2", time=12},
		{name="Node 3", time=21},
		{name="Node 4", time=31},
		{name="Node 5", time=60},
	})
	-- Learned times combine with shipped ones when piecing together hops
	learned[10][50] = nil
	learned[40] = {[50] = 9}
	lu.assertEquals(cal:PathToSlot(5)[4], {name="Node 5", time=39})
end

function tests.TestReverseFlightTimeFallback()
	local fc = loadWoWModFile("FlightCalculator", mockTaxiMap)
	local learned = {[50] = {[10] = 70}}
	local cal = fc.FlightCalc:New(times, function() return learned end)
	-- 1 -> 5 is only known in reverse
	lu.assertEquals(cal:PathToSlot(5)[4], {name="Node 5", time=70})
	-- A known forward time wins over the reverse one
	learned[10] = {[50] = 65}
	lu.assertEquals(cal:PathToSlot(5)[4], {name="Node 5", time=65})
	-- Forward times pieced together from hops win over a reverse time for the whole flight
	learned = {[50] = {[10] = 70}, [40] = {[50] = 9}}
	lu.assertEquals(cal:PathToSlot(5)[4], {name="Node 5", time=39})
end

function tests.TestNodesSharingAPosition()
	-- Node 6 is unreachable and sits on top of node 3, node 7 on top of node 5
	local env = makeEnv({
		C_TaxiMap = {
			GetAllTaxiNodes = function()
				local r = mockTaxiMap.C_TaxiMap.GetAllTaxiNodes()
				r[#r + 1] = {name = "Node 6", slotIndex = 6, nodeID = 60, position = r[3].position, state = Enum.FlightPathState.Unreachable}
				r[#r + 1] = {name = "Node 7", slotIndex = 7, nodeID = 70, position = r[5].position, state = Enum.FlightPathState.Reachable}
				return r
			end
		},
	}, mockTaxiMap)
	local fc = loadWoWModFile("FlightCalculator", env)
	local cal = fc.FlightCalc:New(times)
	lu.assertEquals(cal:PathToSlot(4), {
		{name="Node 2", time=11},
		{name="Node 3", time=21},
		{name="Node 4", time=31},
	})
	local learned = {[10] = {[50] = 60}}
	cal = fc.FlightCalc:New(times, function() return learned end)
	lu.assertEquals(cal:PathToSlot(5)[4], {name="Node 5", time=60})
end

function tests.TestIgnoredNodes()
	-- Retired Forever node 3207 sits on top of node 5 and must not replace it
	local env = makeEnv({
		C_TaxiMap = {
			GetAllTaxiNodes = function()
				local r = mockTaxiMap.C_TaxiMap.GetAllTaxiNodes()
				r[#r + 1] = {name = "zzOLD", slotIndex = 6, nodeID = 3207, position = r[5].position, state = Enum.FlightPathState.Reachable}
				return r
			end
		},
	}, mockTaxiMap)
	local fc = loadWoWModFile("FlightCalculator", env)
	local cal = fc.FlightCalc:New(times)
	lu.assertEquals(cal:PathToSlot(4), {
		{name="Node 2", time=11},
		{name="Node 3", time=21},
		{name="Node 4", time=31},
	})
	lu.assertNil(cal:PathToSlot(6))
end

function tests.TestCurrentNodeAfterIgnoredSlot()
	-- An ignored node leaves a gap in the slots, the current node comes after it
	local env = makeEnv({
		C_TaxiMap = {
			GetAllTaxiNodes = function()
				local r = mockTaxiMap.C_TaxiMap.GetAllTaxiNodes()
				r[1].state = Enum.FlightPathState.Reachable
				r[4].state = Enum.FlightPathState.Current
				r[3].nodeID = 3207
				return r
			end
		},
	}, mockTaxiMap)
	local fc = loadWoWModFile("FlightCalculator", env)
	local cal = fc.FlightCalc:New({[40] = {[20] = 30}})
	local path, from, to = cal:PathToSlot(2)
	assert(from and to)
	lu.assertEquals({from.id, to.id}, {40, 20})
	lu.assertEquals(path, {{name="Node 2", time=30}})
end

for name, test in pairs(tests) do
	rawset(_G, name, test)
end

os.exit(lu.LuaUnit.run())
