#!/usr/bin/env bash
# Builds WiFiPilot.app from the SwiftPM target.
#
#   ./Scripts/build-app.sh             # release build, ad-hoc signed
#   ./Scripts/build-app.sh debug       # debug build
#   CODESIGN_IDENTITY="Developer ID Application: …" ./Scripts/build-app.sh
#
# Requires macOS 14+ with Xcode or the Swift 6 toolchain installed.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: WiFiPilot.app requires macOS (SwiftUI, CoreWLAN, CoreLocation, ServiceManagement)." >&2
    echo "       On this platform only the shared core can be built: " >&2
    echo "         swift build" >&2
    echo "         swift test" >&2
    exit 1
fi

CONFIGURATION="${1:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP_DIR="build/WiFiPilot.app"

echo "==> Building WiFiPilot ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product WiFiPilot

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH/WiFiPilot" "$APP_DIR/Contents/MacOS/WiFiPilot"
cp Sources/WiFiPilot/Info.plist "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/WiFiPilot"

echo "==> Signing (identity: $IDENTITY)"
if ! codesign --force --deep --options runtime --sign "$IDENTITY" "$APP_DIR"; then
    echo "warning: code signing failed. macOS may refuse Location Services or Launch at Login." >&2
    echo "         Set CODESIGN_IDENTITY to a valid signing identity for full functionality." >&2
fi

echo
echo "Built $APP_DIR"
echo "Run it with:  open \"$APP_DIR\""
echo
echo "First launch: approve the Location Services prompt (required for SSIDs and scans),"
echo "then enable it in System Settings → Privacy & Security → Location Services."
