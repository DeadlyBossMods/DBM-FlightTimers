#!/bin/bash

function error() {
	echo $*
	exit 1
}

test -e "$1" || error "Usage: $0 <WoW base dir>"

CLASSIC="$1/_classic_era_/Interface/AddOns/DBM-FlightTimers"
WOTLK="$1/_classic_/Interface/AddOns/DBM-FlightTimers"
RETAIL="$1/_retail_/Interface/AddOns/DBM-FlightTimers"

rsync --delete -r --exclude=.\* . "$CLASSIC"
rsync --delete -r --exclude=.\* . "$WOTLK"
rsync --delete -r --exclude=.\* . "$RETAIL"

mv "$CLASSIC/DBM-FlightTimers-Classic.toc" "$CLASSIC/DBM-FlightTimers.toc"
mv "$WOTLK/DBM-FlightTimers-Classic-WotLK.toc" "$WOTLK/DBM-FlightTimers.toc"
mv "$RETAIL/DBM-FlightTimers-Retail.toc" "$RETAIL/DBM-FlightTimers.toc"

