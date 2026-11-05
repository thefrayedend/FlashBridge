#!/bin/bash
# Starts the FlashBridge test stack: Creator 5 Pro simulator (API :8898, camera :8080), fake AI
# service (:3333), and the real bridge from your clone (web page + API on :8088).
#   usage: up.sh <repo-clone> [engine-dir] [work-dir]
#   engine-dir: unpacked x86_64 slicer-cli (needed only for slicing tests)
set -u
REPO="$(cd "${1:?usage: up.sh <repo-clone> [engine-dir] [work-dir]}" && pwd)"
ENGINE="${2:-}"
W="${3:-/tmp/fbtest}"
H="$(cd "$(dirname "$0")" && pwd)"
export PATH="$PATH:/opt/dart-sdk/bin"
if curl -s -o /dev/null localhost:8088/; then echo "already running (stop it with down.sh)"; exit 0; fi
mkdir -p "$W/data" "$W/boot"
# the slicer page's 3D libraries are fetched at build time, not stored in the repo
[ -f "$REPO/pi-bridge/bridge/web/slicer/vendor/three.module.js" ] || bash "$REPO/pi-bridge/slicer/fetch-web-vendor.sh"
[ -f "$W/data/ffbridge.json" ] || { cp "$H/seed/ffbridge.json" "$H/seed/pi.json" "$W/data/"; mkdir -p "$W/data/slicer"; cp "$H/seed/slicer/printers.json" "$W/data/slicer/"; }
cd "$H/sim" && (setsid nohup dart c5sim.dart > "$W/sim.log" 2>&1 < /dev/null &)
cd "$REPO/pi-bridge/ai" && (FAKE_GOOD=1 setsid nohup python3 test/fake_ai.py > "$W/ai.log" 2>&1 < /dev/null &)
cd "$REPO/pi-bridge/bridge" && dart pub get > "$W/pub.log" 2>&1
sleep 5
(setsid nohup dart run -DFFB_VERSION=1.0.5 bin/pibridge.dart --data "$W/data" \
  --mainsail-zip ../../android-tv-app/source/assets/mainsail.zip --setup-web web --setup-port 8088 \
  --boot-partition "$W/boot" ${ENGINE:+--slicer-engine "$ENGINE"} > "$W/bridge.log" 2>&1 < /dev/null &)
for i in $(seq 1 40); do sleep 3; curl -s -o /dev/null localhost:8088/ && break; done
sleep 10
curl -s localhost:8088/api/status | python3 -c "import json,sys;j=json.load(sys.stdin);print('bridge', j.get('version'), '| printers:', [(p['name'], p['online']) for p in j['printers']])"
echo "logs in $W (sim.log, ai.log, bridge.log)"
