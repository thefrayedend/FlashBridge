#!/usr/bin/env bash
# Puts current OrcaSlicer's Flashforge printer profiles (and Orca's filament library they build on)
# into an unpacked slicer engine, in place of the older ones the engine was released with.
#
#   bash pi-bridge/slicer/update-profiles.sh ENGINE-DIR
#
# Why: the engine is OrcaSlicer 2.4.2; its Flashforge profiles are older than the OrcaSlicer people
# run on their PC (2.5): no tool-change ramming on the Creator 5, old filament names ("Flashforge
# Generic PLA" instead of "Generic PLA @Flashforge"), no 0.25 mm nozzle for the Creator 5, no
# Adventurer A5. Same profiles = same print settings as the desktop with the same choices.
#
# One edit: the 2.5 profiles start the G-code with "file_start_gcode" ("; estimated printing time
# ... {print_time_day}d ..."), placeholders the 2.4.2 engine does not have (it stops with "Not a
# variable name"). The board writes that line itself (slicer.dart addThumbnail), so the key is
# removed here. Used by make-slicer-pack.sh; runs on any Linux with git and python3.
set -euo pipefail

# OrcaSlicer v2.5.0-beta (the version on Jon's PC that made the reference file).
ORCA_REPO="https://github.com/SoftFever/OrcaSlicer.git"
ORCA_TAG="v2.5.0-beta"
ORCA_COMMIT="345efec64c7b95a05ce5cf96df0dde66a158835c"

E="$(cd "${1:?usage: $0 ENGINE-DIR}" && pwd)"
P="$E/resources/profiles-orca"
[ -d "$P/Flashforge" ] || { echo "no Flashforge profiles in $P" >&2; exit 1; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
echo "== OrcaSlicer $ORCA_TAG profiles ($ORCA_COMMIT)"
git -C "$W" init -q orca
git -C "$W/orca" remote add origin "$ORCA_REPO"
git -C "$W/orca" sparse-checkout set --no-cone /resources/profiles/Flashforge/ /resources/profiles/Flashforge.json \
  /resources/profiles/OrcaFilamentLibrary/ /resources/profiles/OrcaFilamentLibrary.json
git -C "$W/orca" fetch -q --depth 1 --filter=blob:none origin "$ORCA_COMMIT"
git -C "$W/orca" -c advice.detachedHead=false checkout -q FETCH_HEAD
[ "$(git -C "$W/orca" rev-parse HEAD)" = "$ORCA_COMMIT" ] || { echo "got the wrong OrcaSlicer commit" >&2; exit 1; }
S="$W/orca/resources/profiles"
for f in Flashforge Flashforge.json OrcaFilamentLibrary OrcaFilamentLibrary.json; do
  [ -e "$S/$f" ] || { echo "OrcaSlicer $ORCA_TAG has no resources/profiles/$f" >&2; exit 1; }
done

echo "== replace (engine had Flashforge $(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$P/Flashforge.json"))"
rm -rf "$P/Flashforge" "$P/Flashforge.json" "$P/OrcaFilamentLibrary" "$P/OrcaFilamentLibrary.json"
cp -r "$S/Flashforge" "$S/Flashforge.json" "$S/OrcaFilamentLibrary" "$S/OrcaFilamentLibrary.json" "$P/"

python3 - "$P" <<'PY'
import json, os, sys
p = sys.argv[1]
n = 0
for root, _, files in os.walk(os.path.join(p, 'Flashforge')):
    for name in files:
        if not name.endswith('.json'):
            continue
        f = os.path.join(root, name)
        with open(f, encoding='utf-8') as fh:
            j = json.load(fh)
        if 'file_start_gcode' in j:
            del j['file_start_gcode']
            with open(f, 'w', encoding='utf-8') as fh:
                json.dump(j, fh, indent=4, ensure_ascii=False)
                fh.write('\n')
            n += 1
print(f'file_start_gcode removed from {n} profile(s)')
for v in ('Flashforge', 'OrcaFilamentLibrary'):
    print(v, json.load(open(os.path.join(p, v + '.json')))['version'])
PY
