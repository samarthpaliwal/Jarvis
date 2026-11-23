#!/usr/bin/env python3
"""Time-to-first-audio benchmark for the Kokoro voice. Nothing is played.

Usage: scripts/tts-bench.py chunks.json
`chunks.json` is a list of {"old": ..., "new": ...}: the first spoken chunk of a reply under the
whole-sentence rule and under the opening-clause rule. Produce it from your own chat log with:
  JARVIS_DUMP_CHUNKS=/tmp/chunks.json swift test --filter LatencyTests/testDumpFirstChunksForBenchmark
"""
import json, sys, time, urllib.request

URL = "http://127.0.0.1:8880/v1/audio/speech"

def synth_ms(text, cache={}):
    if text not in cache:
        req = urllib.request.Request(URL, data=json.dumps({"input": text, "voice": "bm_george", "speed": 1.0}).encode(),
                                     headers={"Content-Type": "application/json"})
        t0 = time.time(); urllib.request.urlopen(req, timeout=120).read()
        cache[text] = (time.time() - t0) * 1000
    return cache[text]

def pct(v, p):
    v = sorted(v); return v[min(len(v) - 1, int(len(v) * p))]

rows = json.load(open(sys.argv[1]))
synth_ms("Ready.")  # warm
old = [synth_ms(r["old"]) for r in rows]
new = [synth_ms(r["new"]) for r in rows]
words = lambda k: sorted(len(r[k].split()) for r in rows)
changed = sum(1 for r in rows if r["old"] != r["new"])
print(f"{len(rows)} replies; first chunk changed in {changed}")
print(f"{'':28} {'p50':>7} {'p90':>7} {'max':>7}")
print(f"{'first chunk words, before':28} {pct(words('old'), .5):>7} {pct(words('old'), .9):>7} {words('old')[-1]:>7}")
print(f"{'first chunk words, after':28} {pct(words('new'), .5):>7} {pct(words('new'), .9):>7} {words('new')[-1]:>7}")
print(f"{'synthesis ms, before':28} {pct(old, .5):>7.0f} {pct(old, .9):>7.0f} {max(old):>7.0f}")
print(f"{'synthesis ms, after':28} {pct(new, .5):>7.0f} {pct(new, .9):>7.0f} {max(new):>7.0f}")
print(f"mean saved per reply: {sum(o - n for o, n in zip(old, new)) / len(rows):.0f} ms")
