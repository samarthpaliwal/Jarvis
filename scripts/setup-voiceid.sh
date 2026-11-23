#!/bin/bash
# Installs the speaker-verification model for Voice ID.
#   voxceleb_ECAPA512_LM.onnx, 24.9 MB, CC-BY-4.0
#   ECAPA-TDNN trained on VoxCeleb by the WeSpeaker project: https://github.com/wenet-e2e/wespeaker
# It goes to ~/Library/Application Support/Jarvis/models/ (not into the repository) and is verified by checksum.
# Everything Voice ID does afterwards is on this Mac: no audio and no voiceprint ever leaves it.
set -euo pipefail
DEST="$HOME/Library/Application Support/Jarvis/models"
FILE="voxceleb_ECAPA512_LM.onnx"
SHA="d71b85d9b48058ef68004f04f1b78acebefb9dfcf542e19b976a12a5ad1f10b0"
URL="https://huggingface.co/Wespeaker/wespeaker-ecapa-tdnn512-LM/resolve/main/$FILE"
mkdir -p "$DEST"
if [ -f "$DEST/$FILE" ] && echo "$SHA  $DEST/$FILE" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "✓ $FILE is already installed and verified."; exit 0
fi
echo "▸ Downloading $FILE (24.9 MB)…"
curl -fL --progress-bar -o "$DEST/$FILE.part" "$URL"
if ! echo "$SHA  $DEST/$FILE.part" | shasum -a 256 -c - >/dev/null; then
  echo "✗ Checksum mismatch. The file was not installed. The partial download is at: $DEST/$FILE.part"
  exit 1
fi
mv "$DEST/$FILE.part" "$DEST/$FILE"
echo "✓ Installed. Restart Jarvis, then choose Voice ID → Set Up Voice ID… from the menu, or say \"set up Voice ID\"."
