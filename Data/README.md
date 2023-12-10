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