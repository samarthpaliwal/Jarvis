#!/bin/bash
# Build and (re)launch Jarvis.app. Usage: scripts/run.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh" "${1:-release}"
LABEL="gui/$(id -u)/com.samarth.jarvis"
if launchctl print "$LABEL" >/dev/null 2>&1; then
  # Supervised: let launchd restart it, so there is never a second copy.
  launchctl kickstart -k "$LABEL"
  echo "✓ Jarvis restarted under launchd. Logs: ~/Library/Logs/Jarvis/jarvis.log"
else
  pkill -x Jarvis 2>/dev/null || true
  # Wait for the old copy to quit: a new copy that finds one still running exits at once.
  for _ in $(seq 1 50); do pgrep -x Jarvis >/dev/null 2>&1 || break; sleep 0.1; done
  open "$ROOT/build/Jarvis.app"
  echo "✓ Jarvis launched. Logs: ~/Library/Logs/Jarvis/jarvis.log"
fi
