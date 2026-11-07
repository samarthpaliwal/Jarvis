#!/bin/bash
# Builds Jarvis.app into ./build. Usage: scripts/build-app.sh [debug|release]
#
# Signing: ad-hoc by default. macOS ties Microphone/Calendar/etc. permissions to the code
# signature, and an ad-hoc signature changes on every build, so you will be re-prompted.
# To keep permissions across builds, create a self-signed "Code Signing" certificate in
# Keychain Access (e.g. "Jarvis Dev") and run:  JARVIS_SIGN_IDENTITY="Jarvis Dev" scripts/build-app.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
# Prefer the stable "Jarvis Dev" identity (scripts/make-dev-cert.sh) so Keychain/TCC grants survive rebuilds.
if [ -z "${JARVIS_SIGN_IDENTITY:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "\"Jarvis Dev\""; then
  JARVIS_SIGN_IDENTITY="Jarvis Dev"
fi
IDENTITY="${JARVIS_SIGN_IDENTITY:--}"
cd "$ROOT"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" --product Jarvis
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Jarvis.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Jarvis" "$APP/Contents/MacOS/Jarvis"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/config" "$APP/Contents/Resources/config"
# SwiftPM resource bundles (added in later milestones) ride along if present.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi
echo "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ codesign (identity: $IDENTITY)"
codesign --force --deep --sign "$IDENTITY" --entitlements "$ROOT/Resources/Jarvis.entitlements" "$APP"
codesign --verify --verbose=1 "$APP"
echo "✓ Built $APP"
