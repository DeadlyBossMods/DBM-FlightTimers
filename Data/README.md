# FlightPoint Data

FlightPoints-*.lua are extracted from the game, to generate them run this in game:

```
/run DBM:GetModByName("FlightTimers"):DumpFlightPoints()
```

This should only be necessary if flight points are added to the game.
These files are not used by the AddOn itself, so no translations etc. are necessary.

# Data for the AddOn

Classic.lua, Classic-WotLK.lua, and Retail.lua are the actual files loaded in the AddOn, they are based on the FlightPoint data and enriched with timing data extracted from InFlight.

Run import.sh with your WoW base directory, for example:

```
./import.sh '/mnt/c/Program Files (x86)/World of Warcraft/'
```

## Notes on Classic-WotLK

This file is created by first taking Classic timing data and then applying Retail data for all additional flight points that exist in WotLK.

## Forever and learned flight times

The AddOn measures every completed flight (no early landing, not interrupted by a summon or battleground) and saves the time in the SavedVariables (`DBMFlightTimers_Learned`, per faction).
Times are saved per exact route (start, stops and destination), because the game routes you differently depending on which flight points you know.
Learned times are used instead of the shipped ones from then on. A route without a known time uses the time between start and destination (which may be for another route), or is pieced together from known parts.
Opening a taxi map also saves the price of every destination it offers (`prices` in the same table), so prices can be collected without flying every route.

Forever.lua started as a copy of the Classic data (the node IDs are the same) and is updated from these learned times.
Run import-learned.sh with your WoW base directory to merge the learned times and prices from all accounts into Forever.lua (`ns.FlightRoutes` in seconds per exact route, `ns.FlightTimes` in seconds between two nodes on an unknown route, `ns.FlightPrices` in copper; the AddOn doesn't use prices yet), it prints every added or changed value:

```
./import-learned.sh '/Applications/World of Warcraft/'
```

The second argument selects another client folder (default `_forever_`); LearnedImporter.lua works for any data file.