#!/bin/sh
# Build, check, upload to Hostinger, then confirm the live site serves the new version.
set -e
cd "$(dirname "$0")"
node build.js mainnet
node check.js
V=$(sed 's/.*"v":"\([^"]*\)".*/\1/' dist/version.json)
# version.json goes last: open tabs only pick up a new version once every other file is in place.
(cd dist && tar cf - --exclude=_redirects --exclude=_headers --exclude=version.json .) | ssh -i ~/.ssh/gtstar_hostinger -p 65002 u855846839@147.93.73.195 "cd ~/domains/minegts.fun/public_html && tar xf -"
(cd dist && tar cf - version.json) | ssh -i ~/.ssh/gtstar_hostinger -p 65002 u855846839@147.93.73.195 "cd ~/domains/minegts.fun/public_html && tar xf -"
LIVE=$(curl -s "https://minegts.fun/version.json?x=$(date +%s)")
case "$LIVE" in *"$V"*) echo "live: $V";; *) echo "LIVE VERSION MISMATCH: $LIVE (expected $V)"; exit 1;; esac
