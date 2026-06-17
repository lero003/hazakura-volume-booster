#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_DIR/build}"
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/CoreAudioTapPoC.app"
ZIP_PATH="$DIST_DIR/CoreAudioTapPoC-developer-id.zip"
ENTITLEMENTS_PATH="$DIST_DIR/CoreAudioTapPoC-release.entitlements.plist"

cd "$PROJECT_DIR"

xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  clean build

codesign --verify --strict --deep --verbose=2 "$APP_PATH"

mkdir -p "$DIST_DIR"
codesign -d --entitlements "$ENTITLEMENTS_PATH" "$APP_PATH" 2>/dev/null || true
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$ENTITLEMENTS_PATH" >/dev/null 2>&1; then
  if [[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$ENTITLEMENTS_PATH")" == "true" ]]; then
    echo "Release candidate unexpectedly has get-task-allow=true." >&2
    exit 1
  fi
fi

codesign -dvvv --entitlements :- "$APP_PATH" 2>&1 | sed -n '1,140p'

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo
echo "Release candidate app: $APP_PATH"
echo "Developer ID zip: $ZIP_PATH"
echo "Notarization is intentionally not submitted by this script."
