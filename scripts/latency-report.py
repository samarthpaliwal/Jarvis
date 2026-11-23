#!/usr/bin/env python3
"""Per-stage latency from ~/Library/Logs/Jarvis/trace.jsonl.

Usage: scripts/latency-report.py [--since YYYY-MM-DD] [--last N] [path/to/trace.jsonl]
Reads the rotated files too (trace.jsonl.1 …) when no path is given.
"""
import glob, json, os, sys
from collections import Counter, defaultdict

STAGES = [
    ("first_word", "wake -> first word heard"),
    ("listen", "wake -> end of speech (incl. silence wait)"),
    ("llm_first_token", "end of speech -> Claude's first token"),
    ("llm_total", "end of speech -> Claude finished"),
    ("tools", "tools (sum per request)"),
    ("first_audio", "end of speech -> first audio (time to voice)"),
    ("total", "whole request"),
]

def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p))]

def main():
    args = sys.argv[1:]
    since, last, paths = None, None, []
    while args:
        a = args.pop(0)
        if a == "--since": since = args.pop(0)
        elif a == "--last": last = int(args.pop(0))
        elif a in ("-h", "--help"): print(__doc__); return
        else: paths.append(a)
    if not paths:
        base = os.path.expanduser("~/Library/Logs/Jarvis/trace.jsonl")
        paths = sorted(glob.glob(base + ".*"), reverse=True) + [base]
    requests, tools = [], defaultdict(list)
    first_chunk, silence, prewarm, seen_chunk = [], [], [], set()
    for path in paths:
        if not os.path.exists(path): continue
        for line in open(path, errors="ignore"):
            try: o = json.loads(line)
            except ValueError: continue
            if since and o.get("ts", "") < since: continue
            if o.get("event") == "request": requests.append(o)
            elif o.get("event") == "tool" and "ms" in o: tools[o.get("tool", "?")].append(o["ms"])
            elif o.get("event") == "tts_chunk" and o.get("request") not in seen_chunk:
                seen_chunk.add(o.get("request")); first_chunk.append(o.get("synth_ms", 0))
            elif o.get("event") == "speech_end" and "silence_wait_ms" in o: silence.append(o["silence_wait_ms"])
            elif o.get("event") == "cache_prewarm": prewarm.append(o.get("ms", 0))
    if last: requests = requests[-last:]
    if not requests:
        print("No finished requests in the trace yet. Talk to Jarvis, then run this again."); return
    answered = [r for r in requests if r.get("outcome") in ("spoken", "shown")]
    print(f"{len(requests)} requests, {len(answered)} answered   outcomes: {dict(Counter(r.get('outcome') for r in requests))}")
    print(f"\n{'stage':46} {'n':>4} {'p50':>7} {'p90':>7} {'max':>7}   (ms, answered requests)")
    slowest = None
    for key, label in STAGES:
        v = [r["ms"][key] for r in answered if key in r.get("ms", {})]
        if not v: print(f"{label:46} {'-':>4}"); continue
        print(f"{label:46} {len(v):>4} {pct(v, .5):>7.0f} {pct(v, .9):>7.0f} {max(v):>7.0f}")
        if key in ("llm_first_token", "tools") and (slowest is None or pct(v, .5) > slowest[1]): slowest = (label, pct(v, .5))
    # Time-to-voice minus the model's first token is what speech synthesis adds.
    tts = [r["ms"]["first_audio"] - r["ms"]["llm_first_token"] for r in answered
           if "first_audio" in r.get("ms", {}) and "llm_first_token" in r.get("ms", {})]
    if tts:
        print(f"{'first token -> first audio (speech synthesis)':46} {len(tts):>4} {pct(tts, .5):>7.0f} {pct(tts, .9):>7.0f} {max(tts):>7.0f}")
        if slowest is None or pct(tts, .5) > slowest[1]: slowest = ("speech synthesis", pct(tts, .5))
    for label, v in (("silence wait that ended the turn", silence), ("first spoken chunk: synthesis only", first_chunk),
                     ("cache pre-warm request", prewarm)):
        if v: print(f"{label:46} {len(v):>4} {pct(v, .5):>7.0f} {pct(v, .9):>7.0f} {max(v):>7.0f}")
    cold = [r for r in answered if r.get("tokens", {}).get("cache_read", 0) == 0 and r.get("engine") == "claude"]
    if answered: print(f"answered with a cold prompt cache: {len(cold)} of {len(answered)}")
    if slowest: print(f"\nSlowest stage at the median: {slowest[0]} ({slowest[1]:.0f} ms)")
    if tools:
        print(f"\n{'tool':28} {'n':>4} {'p50':>7} {'p90':>7} {'max':>7}")
        for name, v in sorted(tools.items(), key=lambda kv: -pct(kv[1], .5)):
            print(f"{name:28} {len(v):>4} {pct(v, .5):>7.0f} {pct(v, .9):>7.0f} {max(v):>7.0f}")

if __name__ == "__main__":
    main()
