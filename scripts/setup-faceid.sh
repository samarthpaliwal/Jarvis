#!/bin/bash
# Installs the face-recognition model for the owner lock.
#   face_recognition_sface_2021dec.onnx, 38.7 MB, Apache 2.0
#   SFace from the OpenCV model zoo: https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface
# It goes to ~/Library/Application Support/Jarvis/models/ (not into the repository) and is verified by checksum.
# Everything face recognition does afterwards is on this Mac: no picture and no face data ever leaves it.
set -euo pipefail
DEST="$HOME/Library/Application Support/Jarvis/models"
FILE="face_recognition_sface_2021dec.onnx"
SHA="0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
URL="https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/$FILE"
mkdir -p "$DEST"
if [ -f "$DEST/$FILE" ] && echo "$SHA  $DEST/$FILE" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "✓ $FILE is already installed and verified."; exit 0
fi
echo "▸ Downloading $FILE (38.7 MB)…"
curl -fL --progress-bar -o "$DEST/$FILE.part" "$URL"
if ! echo "$SHA  $DEST/$FILE.part" | shasum -a 256 -c - >/dev/null; then
  echo "✗ Checksum mismatch. The file was not installed. The partial download is at: $DEST/$FILE.part"
  exit 1
fi
mv "$DEST/$FILE.part" "$DEST/$FILE"
echo "✓ Installed. Restart Jarvis, then choose Owner Lock → Set Up Face Recognition… from the menu, or say \"set up face recognition\"."
