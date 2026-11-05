#!/bin/bash
# Re-downloads the openWakeWord models (Apache-2.0, https://github.com/dscripka/openWakeWord)
# and verifies their checksums. The models are committed, so this is only needed if they go missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/JarvisCore/Resources/Models"
BASE="https://github.com/dscripka/openWakeWord/releases/download/v0.5.1"
mkdir -p "$DEST"
check() { echo "$2  $DEST/$1" | shasum -a 256 -c - ; }
curl -sL -o "$DEST/melspectrogram.onnx"   "$BASE/melspectrogram.onnx"
curl -sL -o "$DEST/embedding_model.onnx"  "$BASE/embedding_model.onnx"
curl -sL -o "$DEST/hey_jarvis_v0.1.onnx"  "$BASE/hey_jarvis_v0.1.onnx"
check melspectrogram.onnx  ba2b0e0f8b7b875369a2c89cb13360ff53bac436f2895cced9f479fa65eb176f
check embedding_model.onnx 70d164290c1d095d1d4ee149bc5e00543250a7316b59f31d056cff7bd3075c1f
check hey_jarvis_v0.1.onnx 94a13cfe60075b132f6a472e7e462e8123ee70861bc3fb58434a73712ee0d2cb
