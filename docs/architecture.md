# Architecture

## Architecture

A request is five stages, each behind a small interface in
[Pipeline/Stages.swift](../Sources/JarvisCore/Pipeline/Stages.swift). Any stage can be replaced or tested alone.

```
 WakeSource ──▶ Transcriber ──▶ IntentEngine ──▶ ActionRunner ──▶ SpeechOutput
  (heard)       (transcribed)     (intent)         (action)        (spoken)
 openWakeWord   SpeechAnalyzer    Claude + tools   ToolDispatcher  Kokoro / Apple /
                                  (Ollama offline) (tiers, denylist) ElevenLabs / OpenAI
```

`ConversationController` wires the stages together. It changes state only through one transition table,
[Pipeline/PipelineMachine.swift](../Sources/JarvisCore/Pipeline/PipelineMachine.swift):

| State | Meaning | Leaves on |
|-------|---------|-----------|
| `idle` | waiting for the wake word | wake, typed text, an announcement |
| `listening` | microphone to text | transcript, no speech, "thanks", echo dropped, recognizer failure |
| `thinking` | Claude is deciding or tools are running | first sentence of the reply, an approval request |
| `awaitingApproval` | a Tier 2 action waits for yes or no | yes, no, or timeout |
| `speaking` | the reply is being spoken | reply finished, talking over it, the wake word |

"Stop", the close button, and the menu return to `idle` from any state. A transition the table does not
allow is logged as `Illegal transition` and counted. The tests run the whole pipeline on fakes in strict
mode, where such a transition fails the turn.

Each request carries one ID through all five stages; see [Logs and tracing](#logs-and-tracing).

## Project layout

```
Sources/Jarvis/            Entry point (NSApplication boot)
Sources/JarvisObjC/        Objective-C shim: NSException → Swift error
Sources/JarvisCore/
  Pipeline/                Stage interfaces, state machine, ConversationController (the orchestrator)
  Wake/                    Stage 1: mic capture (AVAudioEngine → 16 kHz) + openWakeWord on ONNX Runtime
  STT/                     Stage 2: Transcriber interface, SpeechAnalyzer + SFSpeechRecognizer, endpointer, echo guard
  Intent/                  Stage 3: agent loop (Brain), streaming Claude client, Ollama client, system prompt
  Actions/                 Stage 4: tiers, denylist guard, dispatcher, action log, undo stack
  Actions/Tools/           One small file per tool
  TTS/                     Stage 5: SpeechOutput interface, Apple / Kokoro / ElevenLabs / OpenAI engines, sentence chunker
  App/                     AppDelegate (wiring), menu bar, mode manager, debug hooks
  Config/                  JSON models, tuning and environment overrides, Keychain store
  Remote/                  Remote access: Tailscale address, HTTP server, tokens, the API, headless turns
  Privacy/                 What leaves the Mac (data flows) and the retention sweep
  Logging/                 jarvis.log, trace.jsonl, request tracing
  NotchUI/                 Panel, floating card, HUD, SwiftUI views, view model
  Integrations/            EventKit calendar/reminders, Google OAuth + Gmail, Notion API, briefing, weather
  Context/                 Signals (location, Wi-Fi, power, displays, calendar), mode scorer and setup
  Proactive/               Scheduler (morning briefing, nudges, breaks, battery), call detection
  Vision/                  Camera session, live feed, photo and video, frame sources (camera, glasses hook)
  VoiceID/                 Speaker verification: filterbank features, ECAPA-TDNN, voiceprint, enrollment, gate
  Net/                     HTTP retries and timeouts, spend guard
  Memory/  Skills/  Music/ Long-term memory, skills, Spotify and Music control
  Resources/Models/        melspectrogram / embedding / hey_jarvis ONNX models (Apache-2.0)
Tests/JarvisCoreTests/     Unit tests (`scripts/test.sh`, grouped by stage)
config/                    Default profile.json, allowed-folders.json, denylist.json, modes.json
voice/                     Kokoro speech server (Python)
scripts/                   build-app.sh, run.sh, test.sh, latency-report.py, setup and check scripts
docs/                      Documentation
.env.example               Every environment override, documented
```

## Logs and tracing

Everything lives in `~/Library/Logs/Jarvis/` (menu → *Open Logs*):

| File | What it holds |
|------|---------------|
| `jarvis.log` | Human-readable events. Lines that belong to a request carry its ID, like `[r-3fa9c1]`. |
| `trace.jsonl` | Structured. One JSON object per pipeline stage, and one summary per request with per-stage latency. Never contains what was said, only sizes and timings. |
| `actions.log` | Every tool call as a JSON line: time, tool, tier, source, input, outcome, duration. |
| `conversations.log` | What you said and what Jarvis answered, secrets redacted. |

Every request gets an ID and moves through five stages: **heard → transcribed → intent → action → spoken**.
To follow one request end to end:

```bash
grep r-3fa9c1 ~/Library/Logs/Jarvis/jarvis.log ~/Library/Logs/Jarvis/trace.jsonl
```

For latency per stage across recent requests (median, 90th percentile, worst), and the slowest tool:

```bash
scripts/latency-report.py --last 50
```

Log files rotate at 5 MB and keep three old copies (`tuning.logMaxMegabytes`, `tuning.logKeepFiles`).
Unit tests write to a temporary folder, never to these files.

## Latency

Time from the end of your sentence to Jarvis's voice has three parts. Each was measured, then fixed
(Phase 2, 2026-11-22). Settings are in `profile.json → tuning`.

| Part | Before | After | How |
|------|--------|-------|-----|
| Silence wait that ends your turn | 1.3 s, always | 0.9 s when what you said already ends in `.` `?` `!` (74% of 181 logged utterances), otherwise 1.3 s | `endpointFastSilenceSeconds` |
| Claude's first word | median 1.6 s with a warm prompt cache, 1.8 s cold; 90th percentile 2.3 s warm, 4.9 s cold. 29% of 150 turns were cold | The cache is warmed while you are still speaking, so the turn reads it instead of writing it. Two warm turns measured after the change: 0.76 s and 0.83 s | `cachePrewarmAfterSeconds` |
| Synthesis of the first spoken chunk (Kokoro, 89 logged replies) | median 1.34 s, 90th percentile 3.65 s, worst 23.6 s | median 1.07 s, 90th percentile 1.61 s, worst 4.66 s | `ttsFirstChunkMinWords`, and a fixed sentence splitter |

What changed:

- **Opening clause first.** Speech starts on "Good morning, Sam," instead of waiting for the whole first
  sentence. Synthesis time grows with the length of the chunk.
- **Sentence splitter bug.** A sentence ending in a two-letter word ("…act on.", "…want it.") was taken for
  an abbreviation, and nothing after it was split. Such a reply was spoken as one clip after the model
  finished; that is the 23.6 s case.
- **Cache pre-warm.** At the first transcribed word, if the last request was more than four minutes ago,
  Jarvis sends a `max_tokens: 0` request with the same tools and system prompt. It costs one cache read
  (about $0.001) when the cache was still warm, and nothing extra when it was cold, because the turn
  would have paid for that write anyway. False wakes never trigger it.
- **Token counts were doubled.** Usage is reported at the start and again at the end of a message; both
  were added. Fixed before the cost cap was built on top of it.

The slowest remaining part is Kokoro itself, at about three times real time on this Mac: roughly 1.1 to
2.6 s for the first chunk inside a live turn. Thread count makes no difference and the CoreML provider
crashes; a different model file is the next lever.

To re-measure:

```bash
scripts/latency-report.py --last 50          # per stage, from real requests
scripts/tts-bench.py chunks.json             # voice engine alone; see the script header
```

## When something fails

The rule: every failure produces one short spoken sentence (or an on-screen one when voice is off), and
the pipeline returns to `idle`. Nothing fails silently and nothing hangs.

| Failure | What happens |
|---------|--------------|
| Claude error, rate limit, bad key, no network | Spoken in plain words ("I'm offline right now."). No status codes. |
| The model or a tool never answers | The request stops at `tuning.turnTimeoutSeconds` (120 s): "That took too long, so I stopped. Try again." |
| One tool hangs | Stopped at `tuning.toolTimeoutSeconds` (45 s). Claude is told it timed out and says so. Logged as `timeout`. |
| Speech recognition fails or is not permitted | Spoken once, then shown only for `tuning.repeatErrorAfterSeconds`. |
| The microphone delivers no audio | After three silent rebuilds: "I'm not getting any sound from the microphone." Announced again when it returns. |
| The audio device changes or disappears | Restarts are coalesced and backed off; the audio framework's exceptions are caught instead of crashing. |
| A cloud or Kokoro voice fails | The sentence is spoken by the Apple voice instead. |
| A transition the state table does not allow | Logged and counted (`Illegal transition`). |

### Network: timeouts and retries

Every outgoing request goes through [Net/HTTP.swift](../Sources/JarvisCore/Net/HTTP.swift).

- **Timeout:** 15 s for Gmail, Notion, Spotify, and Google sign-in (`tuning.httpTimeoutSeconds`). Weather keeps
  its own 8 s. Claude has a 60 s idle timeout between stream packets.
- **Retries:** up to two more attempts (`tuning.httpMaxRetries`) on 408, 429, 5xx, 529, and dropped
  connections. Waits start at 0.5 s, double each time with 25% jitter, and never exceed 8 s. A `Retry-After`
  header from the server is obeyed up to that 8 s cap, and `x-should-retry: false` stops retrying.
- **Nothing is created twice.** A request that creates something (a Gmail draft, a Notion page) is retried only
  when it provably did not go through: 429, 503, 529, or a connection that never opened. A 500 or a timeout
  on such a request is reported, not repeated.
- **Claude** is retried only before the first byte of a reply. Once Jarvis has started speaking an answer,
  starting over would say it twice.
- **Offline** fails at once, so Jarvis says "I'm offline right now" instead of waiting.

Each retry is a `Retry N for …` line in `jarvis.log` and a `retry` event in the trace.

The messages live in [Pipeline/Failures.swift](../Sources/JarvisCore/Pipeline/Failures.swift). The tests force
each failure with fakes and check that Jarvis speaks and recovers.

## Staying up: the launchd supervisor

On 2026-11-22 a crash left Jarvis dead for four hours before anyone noticed. A launchd agent now starts
Jarvis at login and restarts it after a crash.

```bash
scripts/install-agent.sh            # install and start under launchd
scripts/install-agent.sh --status   # installed? loaded?
scripts/uninstall-agent.sh          # remove it
```

The agent is `~/Library/LaunchAgents/com.samarth.jarvis.plist`. The menu item *Keep Running* writes or
removes the same file.

- **A crash or `kill -9`** restarts Jarvis within a second or so (never more often than every 10 s). On the
  way back up it says "I had to restart a moment ago. I'm back."
- **Quit from the menu, or a plain `kill`,** is a clean exit and stays quit.
- **A crash loop** is stopped from inside: more than five starts in two minutes and Jarvis exits cleanly,
  so launchd leaves it alone. The reason is in `jarvis.log` and `launchd.err.log`.
- **A frozen app** is caught too. A crash is not the only way to die: a background timer pings the main
  thread, and if it has not answered for 30 seconds (`tuning.hangTimeoutSeconds`) Jarvis logs it and exits,
  so launchd starts a fresh copy. The clock it uses stands still while the Mac sleeps.
- **Only one copy runs.** A second copy (the login item and the agent both firing) exits at once.
- `scripts/run.sh` notices the agent and restarts through launchd instead of opening a second copy.

To verify: `kill -9 $(pgrep -x Jarvis)`, then `pgrep -x Jarvis` shows a new process ID.

## Echo: keeping Jarvis from hearing itself

On built-in speakers the microphone hears everything Jarvis says. Four things keep that from turning into
Jarvis answering its own voice:

1. **Speaking means speaking.** A sentence that is still being synthesized counts as speech, so the
   follow-up listen cannot start while audio is on its way.
2. **A quiet gap.** After the last word, Jarvis waits `tuning.followUpGuardMilliseconds` (350 ms) before
   it listens for a follow-up.
3. **Echo guard.** A follow-up that is a long, in-order copy of the reply Jarvis just gave is dropped and
   logged as `echo_discarded`. The match is fuzzy, because the recognizer garbles its own voice.
   Short answers that reuse Jarvis's words ("yes, start something on Spotify") are not affected.
4. **Talking over Jarvis only interrupts on headphones** (`tuning.speechBargeIn`: `headphones`, `always`,
   or `never`). On speakers, say "stop", say "Hey Jarvis", or click the card.

Approvals are stricter still: Jarvis starts listening for "yes" or "no" only after its own prompt has
finished playing, and ignores anything heard while it is speaking.

## Spending: daily cap and rate limits

Every paid call goes through one guard ([Net/Budget.swift](../Sources/JarvisCore/Net/Budget.swift)): Claude
replies, cache warm-ups, briefings, web searches, and the paid voices (ElevenLabs, OpenAI). The Kokoro and
Apple voices are free and are not counted.

| Setting (`profile.json → tuning`) | Default | Meaning |
|---|---|---|
| `dailyBudgetUSD` | 3 | Paid requests stop for the day at this amount. 0 = no cap. |
| `budgetWarnFraction` | 0.8 | Jarvis says "Heads up: I've used 80 percent of today's 3 dollar budget." once. |
| `modelRequestsPerMinute` | 30 | More than this in a minute is treated as a runaway loop and refused. |
| `speechRequestsPerMinute` | 90 | The same, for paid voices. |

- **Before** each call the guard checks the cap and the rate. Over the cap, the request never leaves the Mac.
- **After** each call it records the real cost from the API's own token counts, including cached tokens
  and web searches. A reply that is cut off is still recorded.
- **At the cap** Jarvis says so once, then answers from the local Ollama model if one is installed, and
  otherwise tells you the budget is used up. Paid voices fall back to the Apple voice.
- **The day** is your local calendar day. Spend is kept in
  `~/Library/Application Support/Jarvis/spend.json` and survives restarts. The menu shows
  `Spend: $0.42 of $3.00 today`.

Prices are in `profile.json → pricing` because they change: Anthropic list prices per million tokens as of
2026-11-03, one cent per web search, and estimates for the paid voices that you should replace with your
plan's rate. An unknown model is priced like the most expensive one, so the cap can only arrive early.
For scale: a typical warm Sonnet 5.5 turn costs about $0.002, and a cold one about $0.03.
