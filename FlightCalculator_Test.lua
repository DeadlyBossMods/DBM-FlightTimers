local lu = require "luaunit"

local function makeEnv(env, base)
	return setmetatable(env, { __index = base or _G })
end

DBM = {
	Debug = function(self, msg)
		print(msg)
	end
}

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

function TestShortNameRegex()
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

Enum = {FlightPathState = {Current = 0, Reachable = 1}}

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

function TestGetFlightTimes()
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

TestSuite = {}

os.exit(lu.LuaUnit.run())
