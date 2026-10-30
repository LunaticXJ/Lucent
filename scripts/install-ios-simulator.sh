#!/usr/bin/env bash
set -euo pipefail

device_id="${1:-736120C9-6141-45FF-B977-C55346D9355A}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${LUCENT_DERIVED_DATA:-/tmp/lucent-derived}"
app="$derived_data/Build/Products/Debug-iphonesimulator/Lucent-iOS.app"
xcodebuild -project "$project_root/Lucent.xcodeproj" -scheme Lucent-iOS \
  -configuration Debug -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath "$derived_data" build CODE_SIGNING_ALLOWED=NO

xcrun simctl install "$device_id" "$app"
echo "Installed Lucent on $device_id"
