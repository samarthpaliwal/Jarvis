#!/bin/bash
# Removes the launchd supervisor and stops the supervised copy of Jarvis.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/Jarvis.app/Contents/MacOS/Jarvis"
if [ -x "$BIN" ]; then "$BIN" --uninstall-agent
else launchctl bootout "gui/$(id -u)/com.samarth.jarvis" 2>/dev/null || true; rm -f "$HOME/Library/LaunchAgents/com.samarth.jarvis.plist"; fi
echo "✓ Supervisor removed. Start Jarvis by hand with: open $ROOT/build/Jarvis.app"
