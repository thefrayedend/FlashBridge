#!/usr/bin/env bash
# Builds and publishes the Flash Bridge Android app. Run by .github/workflows/build-app.yml from the
# repo root, after Java 17 and Flutter are set up. Kept here (not in the workflow) so changes to the
# build travel with the normal pi-bridge upload.
#   env: GH_TOKEN, GITHUB_REPOSITORY, RUN_NUMBER; optional ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="0.1.${RUN_NUMBER:-0}"
OUT="${OUT:-$PWD/../../app-out}"

echo "== complete the Android project (our own files are kept)"
flutter --version
flutter create --platforms=android --org io.github.thefrayedend --project-name flash_bridge .
rm -rf test   # the template's sample test belongs to the template's app

echo "== sign with the app's fixed key, so each build installs over the last"
if [ -n "${ANDROID_KEYSTORE_BASE64:-}" ]; then
  echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > android/app/release.jks
  STORE=release.jks; PASS="${ANDROID_KEYSTORE_PASSWORD:-}"
else
  STORE=flashbridge-sideload.jks; PASS=flashbridge-sideload
fi
if [ -f android/app/build.gradle.kts ]; then
  cat >> android/app/build.gradle.kts <<EOF

android {
    signingConfigs {
        create("flashbridge") {
            storeFile = file("$STORE")
            storePassword = "$PASS"
            keyAlias = "flashbridge"
            keyPassword = "$PASS"
        }
    }
    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("flashbridge")
        }
    }
}
EOF
else
  cat >> android/app/build.gradle <<EOF

android {
    signingConfigs {
        flashbridge {
            storeFile file("$STORE")
            storePassword "$PASS"
            keyAlias "flashbridge"
            keyPassword "$PASS"
        }
    }
    buildTypes {
        release {
            signingConfig signingConfigs.flashbridge
        }
    }
}
EOF
fi

echo "== check the code"
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings

echo "== build"
flutter build apk --release --build-name "$VERSION" --build-number "${RUN_NUMBER:-1}"
mkdir -p "$OUT"
cp build/app/outputs/flutter-apk/app-release.apk "$OUT/flash-bridge.apk"
echo "{\"version\": \"$VERSION\", \"apk\": \"flash-bridge.apk\"}" > "$OUT/flash-bridge-app.json"
ls -lh "$OUT"

if [ -n "${GH_TOKEN:-}" ]; then
  echo "== publish as the release latest-app"
  gh release delete latest-app --yes --cleanup-tag --repo "$GITHUB_REPOSITORY" || true
  gh release create latest-app "$OUT"/* --repo "$GITHUB_REPOSITORY" \
    --title "Flash Bridge Android app $VERSION" \
    --notes "Open this page on your phone, tap flash-bridge.apk and install it. Updating: install the new one over the old (Settings → Check for updates in the app does this)."
fi
