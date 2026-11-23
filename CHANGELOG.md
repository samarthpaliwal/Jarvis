# Changelog

### 0.15.0 — A second brain, and Siri (2026-11-23)
- **gpt-oss:120b, hosted by Ollama**, next to Claude: it steps in by itself when Claude cannot answer, or can
  be put first (menu → Brain). Nothing is installed or run on the Mac. Needs an Ollama API key.
- **"Hey Siri, Ask Jarvis"** shortcut (`scripts/make-siri-shortcut.sh`).
- README rewritten as a front page with an architecture diagram; documentation moved to `docs/`;
  `scripts/test.sh` reports tests per pipeline stage.

### 0.14.1 — Call mode (2026-11-23)
- **Phone app:** *Call* opens a hands-free, turn-after-turn conversation over the tailnet. Ends on Hang up,
  "bye", leaving the app, or 90 seconds of silence.

### 0.14.0 — Upgrade phase 6: privacy and retention (2026-11-23)
- **Local-first, visible:** a *Privacy* menu and a startup log line say what leaves this Mac. No audio does;
  the one recognizer that could use Apple's servers is refused unless `cloudSpeechRecognition` is `allow`.
- **Retention:** conversations and timings 30 days, diagnostics 14, the tool log 90, recordings kept (or
  moved to the Trash after a limit you set). Swept at start and daily.
- **Fix:** the pairing-code dialog froze the main queue and the hang watchdog restarted Jarvis after 30 s.

### 0.13.0 — Upgrade phase 5: remote access (2026-11-23)
- **Tailscale:** setup walkthrough and `scripts/tailscale-check.sh`.
- **Remote API:** `/v1/status`, `/v1/ask`, `/v1/approve`, inside the app, bound to the Tailscale address
  only, with a per-device token on every request. Off by default. A remote request runs the same stages as
  a spoken one and returns text and audio; nothing is shown or said on the Mac.
- **Remote approvals need a verified voice.** No Voice ID, a typed request, or someone else's voice: refused.
- **Phone app:** one mic button, served by Jarvis, installable from the browser. Pairs with a six-digit code
  shown on the Mac. The microphone needs HTTPS, which `tailscale serve` provides (see the README step).
- A copy of Jarvis opened by hand now hands over to the launchd supervisor.

### 0.12.1 — Touch ID for the saved keys (2026-11-23)
- **No more keychain password prompts.** A small, never-rebuilt helper (`jarvis-keyhelper`) holds the saved
  keys and releases them to Jarvis after Touch ID, once per launch. Before, every rebuild made macOS ask for
  the keychain password again, per key, sometimes mid-conversation under the HUD where it could not be typed.
- The helper refuses any caller that is not Jarvis. Existing keys move over on the first run.
- New *Keys* menu; a locked vault is spoken as such instead of "no API key".
- Unit tests no longer read the real Keychain.

### 0.12.0 — Camera, and upgrade phase 4: Voice ID (2026-11-23)
- **Camera:** live feed window, video and photo capture to `~/Movies/Jarvis` and `~/Pictures/Jarvis`. A
  recording is only possible while the feed is visible.
- **Voice ID:** ECAPA-TDNN speaker verification on-device; guided five-sentence enrollment; approvals are
  gated on the request being in your voice, with the Approve button as the fallback.
- **Stability:** fixed a deadlock when the camera closed; a watchdog now restarts Jarvis if its main thread
  freezes for 30 seconds.
- 285 tests.

### 0.11.0 — Upgrade phase 3: features (2026-11-22)
- **Calendar:** `calendar_move` (undoable) and `calendar_cancel` (always approved). Events are found by
  title and day; changes that would notify invitees ask first.
- **Chains:** multi-step requests with a spoken yes before anything irreversible. `email_send` sends a
  draft Jarvis created, after an approval that reads back the real recipient and subject. Approvals say
  when outside content was read first.
- **Memory:** a short RAM-only recap across chats, and a contact book with a macOS Contacts fallback.
- **Vision:** `look` takes one camera frame on request; a `glasses` frame source is ready for a bridge.
- 238 tests.

### 0.10.0 — Upgrade phases 1 and 2: architecture and reliability (2026-11-22)
- **Architecture:** five stages behind interfaces (wake, speech-to-text, intent, actions, speech-out), one
  state-transition table, a request ID traced through every stage, all thresholds in `tuning` with
  `JARVIS_*` overrides, and a spoken message for every failure.
- **Echo:** Jarvis no longer answers its own voice (19 of 89 logged exchanges were echoes).
- **Reliability:** audio-device crash fixed; launchd supervisor restarts after a crash; retries with backoff
  on every network call; tool and request deadlines; daily cost cap with a spoken warning.
- **Latency:** opening clause spoken first, prompt cache warmed while you speak, shorter silence wait after
  a complete sentence. First-chunk synthesis p90 3.65 s → 1.61 s.
- **Bugs found by the new tracing and tests:** overlapping Kokoro sentences, replies stalled by a sentence
  ending in a two-letter word, error messages spoken twice, token usage counted twice. 198 tests.

### 0.9.3 — Web search, stable signing (2026-11-07)
- Jarvis can search the web and read pages freely, using Anthropic's server-side `web_search` and `web_fetch`. Server blocks are kept verbatim in the history, `pause_turn` resumes automatically, an interrupted search is repaired out of the history, and every search is logged. A web answer takes about 3 s.
- Fixed a crash when listening started while Jarvis was speaking: audio that arrived before Apple's SpeechAnalyzer reported its format went in unconverted.
- Text dialogs (API key, Spotify, and Google client) now take keyboard focus. Recent macOS ignored the old activation call for menu-bar apps.
- `scripts/make-dev-cert.sh` works with OpenSSL 3, and `build-app.sh` signs with "Jarvis Dev" automatically, so the Keychain stops asking after every rebuild.
- The chat log records typed questions correctly. 111 tests.

### 0.9.2 — Email fixes, one chat at a time (2026-11-06)
- Fixed "API error 400" after interrupting Jarvis mid-request: each turn now commits its history atomically, any malformed history is repaired before sending (every tool_use gets a tool_result, same-role messages merged), and a 400 retries once with a clean history.
- Gmail search fetches messages in parallel: 9.4 s → 0.5 s for an inbox search.
- One chat at a time: when the card disappears, the conversation ends and the next one starts fresh. The HUD no longer lists earlier exchanges. Every exchange is kept in `~/Library/Logs/Jarvis/conversations.log` (menu → Memory → Open Chat Log) and stays searchable through memory.
- Fixed Gmail sign-in: the OAuth redirect used port 0. 103 tests.

### 0.9.1 — Free neural voice (2026-11-06)
- Kokoro-82M on-device voice (free, offline, no key): `scripts/setup-kokoro.sh`, `voice/kokoro_server.py`, app-managed server with auto-restart. Auto engine order: ElevenLabs key → OpenAI key → Kokoro → Apple. British voices in the menu. 98 tests.

### 0.9.0 — Card, music, voice (2026-11-06)
- Floating card on the active screen replaces the menu-bar notch overlay; halo off; HUD no longer on every turn.
- `music` tool: Spotify / Apple Music via AppleScript, play by name via Spotify search (client credentials). Replaces media keys, which macOS ignored.
- Neural voices: ElevenLabs and OpenAI TTS with per-sentence streaming and Apple fallback; voice picker ranks Siri neural / Premium voices first when visible.
- Verified live: "What's Spotify playing?" and "Play the music" worked; card shown on the screen under the mouse. 95 tests.

### 0.8.1 — Mic fix (2026-11-06)
- Fixed: after the input switched between AirPods and the built-in mic, the audio tap could go silent, so "Hey Jarvis" was never heard while typed commands still worked. Capture now builds a fresh `AVAudioEngine` on every restart, and a watchdog rebuilds it if no audio arrives for 6 seconds.
- Fixed: the hidden HUD kept animating at 30 fps (~13 % CPU). Its view tree is now torn down when dismissed.

### 0.8.0 — OpenJarvis port (2026-11-06)
- Persistent memory (MEMORY.md, USER.md, FTS5 conversation index) with `memory` and `memory_search` tools; injected into every turn.
- LoopGuard, secret redaction of all tool output, prompt-injection labelling of untrusted content.
- Claude-narrated briefings in JARVIS's voice with weather and headlines; `weather`, `news_headlines` tools.
- Ollama local engine for offline use and Private Mode.
- SKILL.md skills with `use_skill`; ships `exam-prep`.
- Fix: typed or menu questions were ignored while Jarvis was listening for a follow-up.
- Verified live: narrated briefing, "remember my lab partner is Maya" → USER.md → recalled next turn. 89 tests.

### 0.7.1 — Conversation flow + G5 (2026-11-05)
- HUD on a preferred display (`hud.preferredDisplay`, default "Odyssey G5"), fallback to the notch screen.
- Conversation mode: follow-up listening after every reply (no wake word), end words, quiet timeout.
- Interrupt by talking over Jarvis, with an echo filter against its own speech; "stop" unchanged.
- HUD exchange log; menu toggles for Conversation Mode and the HUD display line. 76 tests.

### 0.7.0 — Iron Man mode (2026-11-05)
- JARVIS persona in the system prompt, British voice preference.
- `PhraseSpotter`: extra wake phrases via on-device speech recognition, active only during an arrival window (home Wi-Fi after being away, or wake from sleep at home). "Hey Jarvis" during the window also triggers the homecoming.
- `SceneDirector` with the homecoming scene; `welcome_home` and `set_display_mode` tools.
- Full-screen HUD (`HUDView`, `HUDWindowController`): arc reactor, readouts, transcript/reply, Esc/click to dismiss, optional always-on.
- Fixes: launching at home no longer counts as an arrival; a debounced homecoming lets "Hey Jarvis" fall through to a normal turn.
- 72 tests.

### 0.6.0 — Milestone 6 (2026-11-05)
- Context detection (Core Location, CoreWLAN SSID, power, displays, current calendar event) + pure `ModeScorer`; automatic mode switching with a manual-override window; `remember_place` writes `modes.json`.
- Mode setup applied through the dispatcher as source `mode` (volume, brightness, quit/hide/open apps, Focus via Shortcuts) with snapshot + restore / undo. New tools: `set_brightness`, `set_focus`.
- Proactive scheduler: morning briefing (time or first unlock), exam/deadline nudges at 7/3/1/0 days, Road low-battery warning, optional break reminders; gated by DND, quiet hours, call/screen-share detection, Class mode.
- Maintenance: `organize_folder` (undoable, moves.json), `app_health`, `restart_app` (Tier 2), `performance_report`, `clear_caches` (Tier 2, to Trash).
- Menu: Automatic mode toggle with the last auto reason, Break Reminders, quiet-hours status, Ask by Text…, pastable key dialogs (Edit menu, Paste button), `scripts/set-api-key.sh`, `scripts/make-dev-cert.sh`.
- Fixed: SSE parsing dropped every event (the byte-line iterator swallows blank separators), so Claude replies were empty; empty assistant content could then poison the history with a 400. Both fixed, with a parser test.
- Prompt caching (stable tools + personality prefix, volatile mode/clock block). Measured on Sonnet 5.5: 9,938 cached tokens read per turn, ~700 fresh; first token 1.0 s on a cached turn.
- Verified live end to end with the real API key: "What's my battery at?" → `system_status` → spoken answer.
- 68 tests. Measured: idle CPU 2.1 % with everything running (wake word, context polling, scheduler), 41 MB.

### 0.5.0 — Milestone 5 (2026-11-05)
- EventKit `CalendarService`: events, incomplete reminders, create event / reminder (undoable), natural date parsing.
- Google OAuth (PKCE + loopback) with Keychain-stored client and refresh token; `GmailClient` search / read / draft (no send). HTML-to-text for bodies.
- `NotionClient` (API 2025-09-03): data-source queries with filters/sorts, search, create page, relation title cache. `profile.json` pre-wired to the Student OS Homework / Exams / Classes data sources.
- `BriefingService` + `get_briefing`: merges calendar, reminders, Notion, email; cleans and dedupes titles; spoken one-liner; next-class line in Class mode. Verified live against the real calendar.
- Menu: Integrations submenu (Google client, Connect Gmail, Connect Notion), Briefing Now. `kill -USR2` runs the real briefing.
- Config merging: new default keys are added to the user's profile.json copy on launch.
- 55 tests (Notion/Gmail parsing, date parsing, briefing logic, title cleaning).

### 0.4.0 — Milestone 4 (2026-11-05)
- Claude brain: streaming `/v1/messages` client, agent loop with parallel tool results, 10-minute conversation memory, refusal handling, friendly API/network errors, offline fallback matcher.
- Permission system enforced in code: tiers, `JarvisTool` protocol, denylist guard (paths, patterns, apps, shell), dispatcher with approval gate (user-sourced only), JSONL action log, undo stack.
- Approval card in the notch with Approve/Deny buttons and voice yes/no; sentence-by-sentence streaming TTS.
- 12 tools: system_status, open_app, set_volume, media_control, set_timer, file_search, file_read, run_shell, get_location_context, set_mode, undo_last_action, actions_today.
- Menu: Set API Key… (Keychain), Clear Conversation, What Did You Do Today?, per-turn tool/token stats.
- `kill -INFO $(pgrep -x Jarvis)` pushes a demo `run_shell` request through the real approval path.
- 46 tests, including 17 for the dispatcher/denylist and live checks of the read-only tools and the sandboxed shell.

### 0.3.0 — Milestone 3 (2026-11-05)
- `Transcriber` protocol with two implementations: SpeechAnalyzer (macOS 26, on-device, no Dictation dependency) and SFSpeechRecognizer (macOS 14–15 fallback). Live transcript shown in the notch.
- `Endpointer` (silence / no-speech / max-duration / final-result) with unit tests.
- `SpeechOutput` protocol + `AppleSpeechOutput`: best-quality voice selection (skips novelty voices), per-mode volume, profile speech rate. Voice submenu to pick and test voices.
- `ConversationController`: wake → listen → think → speak state machine, barge-in by "Hey Jarvis" or "stop", text-only replies when the mode disables voice, latency logging. `kill -USR1` now runs the real flow.
- Config: optional `profile.json → speech` section (older config copies still parse).
- Measured live (built-in mic, SpeechAnalyzer): wake score 0.99 → first word 1299 ms; end of speech → reply 346 ms. 23 tests pass.

### 0.2.0 — Milestone 2 (2026-11-05)
- On-device wake word: openWakeWord "hey jarvis" on ONNX Runtime, batched inference, 2 s cooldown.
- `AudioCapture`: AVAudioEngine tap → 16 kHz mono, restarts on device change and wake from sleep.
- Siri-style iridescent glow around the notch and the screen edge while listening; dimmer while thinking. Respects Reduce Motion.
- Menu: wake word status/stats, pause, test trigger, Microphone privacy shortcut when denied.
- Tests: silence never triggers; synthesized "hey jarvis" (macOS `say`) scores ≥ 0.5; unrelated phrase stays < 0.5; checks at batch sizes 1/2/4. A benchmark test prints per-model timings.
- Measured on M4 Pro (built-in mic): idle CPU 3.1–4.4% in `top` with the wake word running (0.2–0.4% with the mic open but inference paused; the embedding model is the floor at ~1 ms of P-core time per 80 ms chunk, which shows as ~3% because it runs on efficiency cores at low clock). Memory ~40 MB. Synthesized "hey jarvis" through the speakers at 13% volume scored 0.73 and 0.99; unrelated speech < 0.01. Wake → notch visible in under 1 ms after detection.

### 0.1.0 — Milestone 1 (2026-11-05)
- Swift Package with `JarvisCore` library + thin `Jarvis` executable; `scripts/build-app.sh` produces a signed `Jarvis.app`.
- Menu bar app with no Dock icon (`LSUIElement`), status, mode switcher, Do Not Disturb, demos, config and log shortcuts, Launch at Login.
- Notch overlay: non-activating panel above the menu bar on all Spaces and over full-screen apps; notch geometry from `NSScreen` safe areas with floating-pill fallback; spring expand/collapse; listening glow + waveform; thinking dots; response text; briefing card; Reduce Motion support; re-measure on display change and wake.
- Config: `profile.json`, `allowed-folders.json`, `denylist.json`, `modes.json` with seeding to Application Support, strict parsing with visible errors and safe fallbacks, denylist floor always merged.
- Logging to `~/Library/Logs/Jarvis/jarvis.log` and Console.
- Tests: config parsing, denylist floor, fallback behaviour, notch geometry/shape, view-model phase flow (9 tests).
- Measured: idle CPU 0.0%, resident memory ~70 MB, notch detected 185×32 pt on this MacBook Pro.
