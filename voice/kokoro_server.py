"""Jarvis local voice server: Kokoro-82M neural TTS (Apache-2.0) via kokoro-onnx.

Listens on 127.0.0.1 only. POST /v1/audio/speech {"input": str, "voice": "bm_george", "speed": 1.0}
returns audio/wav. GET /health returns {"ok": true, "voices": [...]}. Started and stopped by Jarvis.app.
"""
import io
import json
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import onnxruntime as ort

ort.set_default_logger_severity(3)  # hide harmless constant-folding warnings
from kokoro_onnx import Kokoro  # noqa: E402

MODEL_DIR = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8880

kokoro = Kokoro(f"{MODEL_DIR}/kokoro-v1.0.fp16.onnx", f"{MODEL_DIR}/voices-v1.0.bin")
lock = threading.Lock()  # one synthesis at a time keeps latency predictable
try:
    VOICES = sorted(kokoro.get_voices())
except Exception:
    VOICES = []


def to_wav(samples: np.ndarray, rate: int) -> bytes:
    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


def synthesize(text: str, voice: str, speed: float) -> bytes:
    lang = "en-gb" if voice.startswith("b") else "en-us"
    with lock:
        samples, rate = kokoro.create(text, voice=voice, speed=speed, lang=lang)
    return to_wav(samples, rate)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/health"):
            self._send(200, json.dumps({"ok": True, "voices": VOICES}).encode(), "application/json")
        else:
            self._send(404, b"{}", "application/json")

    def do_POST(self):  # noqa: N802
        if not self.path.startswith("/v1/audio/speech"):
            self._send(404, b"{}", "application/json")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(length) or b"{}")
            text = str(req.get("input", "")).strip()[:2000]
            if not text:
                raise ValueError("empty input")
            voice = str(req.get("voice", "bm_george"))
            speed = float(req.get("speed", 1.0))
            self._send(200, synthesize(text, voice, max(0.5, min(2.0, speed))), "audio/wav")
        except Exception as exc:  # report, never crash the server
            self._send(400, json.dumps({"error": str(exc)}).encode(), "application/json")

    def log_message(self, *args):  # keep stdout quiet
        pass


if __name__ == "__main__":
    synthesize("Ready.", "bm_george", 1.0)  # warm up the model so the first reply is fast
    print(f"kokoro ready on 127.0.0.1:{PORT} with {len(VOICES)} voices", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
