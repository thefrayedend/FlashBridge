#!/usr/bin/env bash
# Checks the notification's start stages (StartStage.kt) without Android or Flutter. Needs kotlinc on PATH
# (the Kotlin compiler zip from https://github.com/JetBrains/kotlin/releases).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
kotlinc android/app/src/main/kotlin/io/github/thefrayedend/flash_bridge/StartStage.kt ci/StartStageCheck.kt \
  -include-runtime -d "$OUT/check.jar" 2>&1 | grep -v '^warning:' || true
java -jar "$OUT/check.jar"
