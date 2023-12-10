#!/bin/bash
# Usage: ./import.sh <path to WoW installation (base path)>
function error() {
	echo $*
	exit 1
}

test -e "$1" || error "$0 <WoW base dir>"

CLASSIC_IF="$1/_classic_era_/Interface/AddOns/InFlight/Defaults.lua"
RETAIL_IF="$1/_retail_/Interface/AddOns/InFlight/Defaults.lua"

test -e "$CLASSIC_IF" || error "InFlight data for classic not found at $CLASSIC_IF"
test -e "$RETAIL_IF" || error "InFlight data for retail not found at $RETAIL_IF"

lua Importer.lua "$CLASSIC_IF" FlightPoints-Classic.lua > Classic.lua
lua Importer.lua "$RETAIL_IF" FlightPoints-Classic-WotLK.lua Classic.lua > Classic-WotLK.lua
lua Importer.lua "$RETAIL_IF" FlightPoints-Retail.lua > Retail.lua
