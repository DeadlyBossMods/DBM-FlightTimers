#!/bin/bash
# Usage: ./import-learned.sh <path to WoW installation (base path)> [client folder, default _forever_]
# Merges the flight times DBM-FlightTimers learned in game (from every account's SavedVariables) into Forever.lua.
# Starts from Classic.lua if Forever.lua doesn't exist yet.
function error() {
	echo "$*"
	exit 1
}

test -e "$1" || error "$0 <WoW base dir> [client folder, default _forever_]"
cd "$(dirname "$0")" || exit 1

shopt -s nullglob
SAVED=("$1/${2:-_forever_}"/WTF/Account/*/SavedVariables/DBM-FlightTimers.lua)
test ${#SAVED[@]} -gt 0 || error "No SavedVariables/DBM-FlightTimers.lua found under $1/${2:-_forever_}/WTF/Account"

BASE=Forever.lua
test -e "$BASE" || BASE=Classic.lua

lua LearnedImporter.lua "$BASE" "${SAVED[@]}" > Forever.lua.new || { rm -f Forever.lua.new; exit 1; }
mv Forever.lua.new Forever.lua
