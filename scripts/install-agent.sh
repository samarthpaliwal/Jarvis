#!/bin/bash
# Installs the launchd supervisor: Jarvis starts at login and restarts after a crash.
#   scripts/install-agent.sh            install and start under launchd now
#   scripts/install-agent.sh --status   show whether it is installed and loaded
# Remove with scripts/uninstall-agent.sh. The agent file is ~/Library/LaunchAgents/com.samarth.jarvis.plist
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/Jarvis.app/Contents/MacOS/Jarvis"
[ -x "$BIN" ] || { echo "Build first: scripts/build-app.sh"; exit 1; }
if [ "${1:-}" = "--status" ]; then "$BIN" --agent-status; exit 0; fi
# Stop the copy that was started by hand, so launchd owns the only one.
pkill -x Jarvis 2>/dev/null || true
sleep 1
"$BIN" --install-agent
echo "✓ Jarvis is now supervised by launchd. Check: launchctl print gui/$(id -u)/com.samarth.jarvis | head"
