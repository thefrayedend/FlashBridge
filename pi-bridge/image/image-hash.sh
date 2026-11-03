#!/bin/bash
# Prints a short fingerprint of everything that only a new SD card image can change
# (system packages, Python packages, AI model, Mainsail, the image layout).
# The board stores it at build time; an update with a different fingerprint asks for a reflash.
#
#   image-hash.sh [--board orangepi-zero4 | raspberrypi-4]     (default: orangepi-zero4)
#
# Lines in customize.sh / build-image.sh between "# >>> pi4-image" and "# <<< pi4-image" only
# matter for the Raspberry Pi image, so for every other board they are left out of the
# fingerprint: adding Pi-only steps must not make the proven Orange Pi boards ask for a reflash.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BOARD="orangepi-zero4"
while [ $# -gt 0 ]; do
  case "$1" in
    --board) BOARD="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
strip_other_boards() {
  if [ "$BOARD" = raspberrypi-4 ]; then cat "$1"; else sed '/^# >>> pi4-image$/,/^# <<< pi4-image$/d' "$1"; fi
}
{ strip_other_boards "$REPO/pi-bridge/image/customize.sh"; strip_other_boards "$REPO/pi-bridge/image/build-image.sh"
  cat "$REPO/pi-bridge/ai/requirements.txt" "$REPO/pi-bridge/ai/fetch-model.sh" \
      "$REPO/android-tv-app/source/assets/mainsail.zip"; } | sha256sum | cut -c1-16
