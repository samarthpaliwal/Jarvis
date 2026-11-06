#!/bin/bash
# Installs the free, on-device Kokoro voice for Jarvis (~250 MB, one time).
#   Python 3.12 venv (via uv) + kokoro-onnx + Kokoro-82M fp16 model + voices
# into ~/Library/Application Support/Jarvis/kokoro. Jarvis.app starts the voice server itself.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/Application Support/Jarvis/kokoro"
BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"
mkdir -p "$DEST"
cd "$DEST"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required (https://docs.astral.sh/uv/). brew install uv" >&2; exit 1
fi

echo "▸ Python 3.12 virtualenv"
[ -x .venv/bin/python ] || uv venv --python 3.12 .venv
echo "▸ kokoro-onnx"
uv pip install --python .venv/bin/python "kokoro-onnx==0.6.1"

echo "▸ model files"
[ -s kokoro-v1.0.fp16.onnx ] || curl -fL --progress-bar -o kokoro-v1.0.fp16.onnx "$BASE/kokoro-v1.0.fp16.onnx"
[ -s voices-v1.0.bin ]       || curl -fL --progress-bar -o voices-v1.0.bin "$BASE/voices-v1.0.bin"

cp "$ROOT/voice/kokoro_server.py" "$DEST/kokoro_server.py"
echo "▸ smoke test"
.venv/bin/python - <<'PY'
from kokoro_onnx import Kokoro
k = Kokoro("kokoro-v1.0.fp16.onnx", "voices-v1.0.bin")
s, sr = k.create("Good evening, Sam.", voice="bm_george", speed=1.0, lang="en-gb")
print(f"ok: {len(s)/sr:.1f}s of audio at {sr} Hz")
PY
echo "✓ Kokoro installed in $DEST. Restart Jarvis to use it."
