#!/bin/bash
# Build and (re)launch Jarvis.app. Usage: scripts/run.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh" "${1:-release}"
pkill -x Jarvis 2>/dev/null || true
sleep 0.3
open "$ROOT/build/Jarvis.app"
echo "✓ Jarvis launched. Logs: ~/Library/Logs/Jarvis/jarvis.log"
