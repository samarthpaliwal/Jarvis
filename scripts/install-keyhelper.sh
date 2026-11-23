#!/bin/bash
# Installs jarvis-keyhelper: the small program that keeps Jarvis's saved keys and releases them after Touch ID.
#
#   scripts/install-keyhelper.sh           install once (does nothing if it is already there)
#   scripts/install-keyhelper.sh --force   replace it. macOS then asks for the keychain password again for
#                                          every saved key, because approval is tied to the exact program.
#
# It lives at ~/Library/Application Support/Jarvis/bin/jarvis-keyhelper and is NOT rebuilt when Jarvis is,
# which is the whole point: its Keychain approval survives every Jarvis rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$HOME/Library/Application Support/Jarvis/bin"
DEST="$DEST_DIR/jarvis-keyhelper"
if [ -x "$DEST" ] && [ "${1:-}" != "--force" ]; then
  echo "✓ Already installed: $DEST ($("$DEST" version))"
  exit 0
fi
cd "$ROOT"
echo "▸ Building the key helper"
swift build -c release --product jarvis-keyhelper >/dev/null
BIN="$(swift build -c release --show-bin-path)/jarvis-keyhelper"
mkdir -p "$DEST_DIR"
cp "$BIN" "$DEST"
chmod 755 "$DEST"
# Same certificate as Jarvis.app, so the helper can check that its caller really is Jarvis.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"Jarvis Dev\""; then
  codesign --force --sign "Jarvis Dev" --identifier com.samarth.jarvis.keyhelper "$DEST"
else
  codesign --force --sign - --identifier com.samarth.jarvis.keyhelper "$DEST"
  echo "  (no Jarvis Dev certificate: signed ad hoc. Run scripts/make-dev-cert.sh for the stronger caller check.)"
fi
echo "✓ Installed $DEST ($("$DEST" version))"
echo "  Restart Jarvis. The first time, macOS asks for the keychain password once per saved key, to move"
echo "  them into the helper's vault. After that, unlocking is Touch ID."
