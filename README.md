# Jarvis

A personal voice assistant that lives in the MacBook notch. Menu bar app, no Dock icon,
on-device wake word, on-device speech recognition, Claude for the brain, tiered permissions
enforced in code.

**Status: Milestone 6 of 6 — feature complete.** Menu bar app, notch UI, on-device wake word, speech in/out, Claude with 29 tools behind the permission dispatcher, calendar / email / Notion / briefing, automatic context modes, proactive nudges, Mac maintenance. See the changelog at the bottom.

## Requirements

- macOS 14 or newer (built and tested on macOS 26 / Xcode 27.2, Apple Silicon)
- Xcode command line tools (`xcode-select --install`) or full Xcode

## Build, run, test

```bash
# Build Jarvis.app into ./build and launch it
scripts/run.sh

# Just build the .app (release by default; pass "debug" for a debug build)
scripts/build-app.sh

# Unit tests
swift test

# Equivalent with xcodebuild (SwiftPM package, no .xcodeproj needed)
xcodebuild -scheme Jarvis -destination 'platform=macOS' build
xcodebuild -scheme JarvisCore -destination 'platform=macOS' test
```

`swift run Jarvis` also works for quick iteration, but without the `.app` bundle macOS will
not honour `LSUIElement`, permission prompts will be attributed to your terminal, and
Launch at Login is unavailable.

### Code signing

The build script signs ad-hoc by default. macOS ties Microphone, Speech, Calendar and
Automation grants to the code signature, and an ad-hoc signature changes every build, so you
will be re-prompted after each rebuild. **This also makes the Keychain
re-ask before handing over the API key after every rebuild** (the app sits at "Config loaded" in the
log until you click Allow). Fix it once with a stable self-signed identity:

```bash
scripts/make-dev-cert.sh
```

```bash
JARVIS_SIGN_IDENTITY="Jarvis Dev" scripts/run.sh
```

(Or make it in Keychain Access → Certificate Assistant → Create a Certificate → name `Jarvis Dev`,
type Code Signing.) Click "Always Allow" on the Keychain prompt the first time.

## Project layout

```
Sources/Jarvis/            Entry point (NSApplication boot)
Sources/JarvisCore/
  App/                     AppDelegate, menu bar, mode manager, demo driver, debug hooks
  Config/                  JSON models, locator, store
  NotchUI/                 Panel, geometry, shape, SwiftUI views, view model
  Logging/                 os_log + ~/Library/Logs/Jarvis/*.log
  Wake/                    Mic capture (AVAudioEngine → 16 kHz) + openWakeWord on ONNX Runtime
  Resources/Models/        melspectrogram / embedding / hey_jarvis ONNX models (Apache-2.0)
  Speech/                  Transcriber protocol, SpeechAnalyzer (macOS 26) + SFSpeechRecognizer, endpointer, TTS
  Brain/                   Keychain store, streaming Claude client, system prompt, agent loop, offline fallback
  Permissions/             Tiers, tool protocol, denylist guard, dispatcher, action log, undo stack
  Tools/                   One small file per tool (system, apps, volume, media, timers, files, shell, modes, undo, calendar, email, Notion, briefing)
  Integrations/            EventKit calendar/reminders, Google OAuth + Gmail, Notion API, BriefingService
  Context/                 Signals (location, Wi-Fi, power, displays, calendar), mode scorer, mode setup/restore, brightness
  Proactive/               Scheduler (morning briefing, nudges, breaks, battery), call / screen-share detection
Tests/JarvisCoreTests/     Unit tests
config/                    Default profile.json, allowed-folders.json, denylist.json, modes.json
Resources/                 Info.plist, entitlements
scripts/                   build-app.sh, run.sh
```

## Configuration

Four JSON files hold every personal fact and safety rule. The defaults live in `config/`
and are bundled into the app. On first launch they are copied to

```
~/Library/Application Support/Jarvis/config/
```

and **that copy is the live one**: edit it, then choose *Reload Config* from the menu bar.
Bundled defaults never overwrite your edits. Set `JARVIS_CONFIG_DIR` to point somewhere else.

| File | What it holds |
|------|---------------|
| `profile.json` | Name, school, time zones, routine, assistant tone, briefing time, Claude model, data sources |
| `allowed-folders.json` | Folders Jarvis may read and organize. Everything else is off limits. |
| `denylist.json` | Tier 3: paths, file patterns, apps and shell patterns Jarvis refuses to touch, even when asked. A hard-coded floor (`~/.ssh`, Keychains, `.env`, `sudo`, …) is always merged in. |
| `modes.json` | Home / Class / Study / Work / Road: triggers, voice, notch glow, briefing contents, and the setup each mode applies. Also the list of known places. |

If a file fails to parse, Jarvis still launches with built-in defaults and shows the exact
error in the menu bar.

## Using Milestone 1

Click the waveform icon in the menu bar:

- **Status line**: current phase and whether a notch was detected (`notch 185×32` on a
  14"/16" MacBook Pro, `no notch, floating pill` on external or older displays).
- **Mode**: switch manually between Home, Class, Study, Work, Road. The notch flashes a
  one-line confirmation, except for Class mode which is silent.
- **Do Not Disturb Jarvis**: toggle (persisted; it gates proactive features in Milestone 6).
- **Demo Notch**: drive the UI through listening, thinking, responding, and the briefing
  card without a microphone or an API key.
- **Open Config Folder / Open Logs Folder / Reload Config / Re-measure Notch**.
- **Launch at Login**: registers the built `.app` via `SMAppService`.

Hover the notch while idle to peek at the current mode and time.

### Test hooks (for scripts and screenshots)

```bash
kill -USR1 $(pgrep -x Jarvis)   # run the demo conversation
kill -USR2 $(pgrep -x Jarvis)   # show the morning briefing card
tail -f ~/Library/Logs/Jarvis/jarvis.log
```

## Wake word (Milestone 2)

**Engine: [openWakeWord](https://github.com/dscripka/openWakeWord) "hey jarvis" v0.1 on ONNX Runtime**,
via Microsoft's `onnxruntime-swift-package-manager` (macOS 14+). Chosen over Picovoice Porcupine
because it needs no account or access key, is Apache-2.0, ships a pretrained *"hey jarvis"*
(Porcupine's built-in is plain *"jarvis"*), and runs entirely on-device. Nothing leaves the
Mac until the wake phrase fires. The `WakeWordDetector` protocol in `Wake/` lets you swap in
Porcupine or a custom model later.

Pipeline (mirrors openWakeWord's streaming path): 80 ms chunks → mel spectrogram → 96-d speech
embedding over the last 76 frames → wake classifier over the last 16 embeddings → score 0…1.
Threshold 0.5, 2 s cooldown. Inference is batched 2 chunks at a time (one wakeup per 160 ms), which adds at
most 80 ms to detection latency.

What you'll see: the notch expands with an iridescent Siri-style glow, a matching glow runs
around the screen edge, and a live waveform shows mic level. In Milestone 2 Jarvis listens
for 4 s, "thinks", and replies with a placeholder line; real transcription is Milestone 3.

Things that are handled: AirPods or another input device connecting mid-session (capture
restarts on the new device), wake from sleep (capture restarts after 1.5 s), mic permission
denied (menu shows a shortcut to the Privacy pane; everything else keeps working).

Menu: *Wake Word Listening* pauses scoring without closing the mic; *Wake Jarvis Now (test)*
fires the same path as a real detection. The status line shows ms/chunk, peak score, and count.

Debugging:

```bash
JARVIS_WAKE_DEBUG=1 build/Jarvis.app/Contents/MacOS/Jarvis   # logs every score ≥ 0.1 and mic levels
say "hey jarvis"                                            # quick speaker-to-mic test
```

Models were downloaded from the openWakeWord v0.5.1 release and are checksummed by
`scripts/fetch-models.sh`.

## Speech in and out (Milestone 3)

**Speech-to-text** sits behind the `Transcriber` protocol in `Speech/`:

- `AnalyzerSpeechTranscriber` — Apple's **SpeechAnalyzer** (macOS 26+). Fully on-device, needs only the
  microphone permission, downloads the English model once (~a minute on first run, logged).
  This is what runs on your Mac.
- `AppleSpeechTranscriber` — `SFSpeechRecognizer` with on-device recognition, used on macOS 14–15.
  It needs the Speech Recognition permission **and** Dictation enabled in System Settings → Keyboard
  (otherwise macOS reports "Siri and Dictation are disabled"). `JARVIS_FORCE_SFSPEECH=1` forces it.

To swap in Deepgram or whisper.cpp, conform to `Transcriber` (five methods) and change one line in
`TranscriberFactory`.

**When you've finished talking** is decided by `Endpointer`: 1.3 s of unchanged transcript after some
speech, 6 s with no speech at all, or 20 s hard cap. Tune these in `profile.json → speech`.

**Text-to-speech** sits behind `SpeechOutput`. `AppleSpeechOutput` uses `AVSpeechSynthesizer` and picks
the best installed English voice: Premium > Enhanced > Default, skipping novelty voices. Your Mac
currently has only default-quality voices, so Jarvis uses Samantha. For a much better voice:
System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, download e.g.
**Ava (Premium)** or **Zoe (Premium)**, then pick it under *Voice* in the Jarvis menu. The choice is
saved; `profile.json → assistant.voiceIdentifier` is the config-file alternative.

**Barge-in**: while Jarvis is talking, the wake word keeps running ("Hey Jarvis" interrupts and
starts a new turn) and the transcriber listens only for "stop" (stops speaking).

**Mode awareness**: Class mode has `voice.enabled: false`, so replies are text-only in the notch.
*Speak Replies* in the Voice menu is a global mute on top of that.

Milestone 3 replies with an echo of what it heard; Claude takes over in Milestone 4.

## Notch behaviour

- Idle: the black island is exactly the size of the physical notch, so it is invisible.
- Listening: expands sideways with a rotating iridescent glow (Siri palette) and a live waveform;
  the same glow traces the screen edge in a click-through overlay.
- Thinking: dimmer, slower glow and pulsing dots.
- Responding: expands downward with the reply and any cards, then collapses after a few
  seconds. It stays open while the pointer is over it.
- Works on every Space and over full-screen apps (non-activating panel above the menu bar).
- Follows the display with a notch; falls back to a menu-bar-height pill at top center
  otherwise. Re-measures on display changes and on wake from sleep.
- Honours *Reduce Motion*: fades instead of springs, no pulsing.

## Permissions

Permissions are requested on first use only:

| Permission | Why | Milestone |
|-----------|-----|-----------|
| Microphone | Wake word and speech capture. Audio stays on-device until the wake word fires. | 2 ✔ |
| Speech Recognition | Only for the macOS 14–15 `SFSpeechRecognizer` fallback. SpeechAnalyzer on macOS 26 does not need it. | 3 ✔ |
| Calendars, Reminders | Briefing, `calendar_read`/`calendar_create`, `set_reminder`. | 5 ✔ |
| Automation (Apple Events) | Controlling Music, Finder, Notes, and app quit/hide for mode setup. | 5–6 |
| Location (While Using) | Home / Class / Work / Road detection and Wi-Fi name. Coordinates never leave the Mac. | 6 ✔ |

Accessibility and Full Disk Access are **not** requested. If a feature would need them, it
will be optional and documented here first.

## Claude (Milestone 4)

**API key.** Jarvis menu → *Set API Key…*: paste with ⌘V or click *Paste from Clipboard & Save*.
It is stored in your login Keychain as `com.samarth.jarvis / ANTHROPIC_API_KEY`, the only Keychain
item Jarvis ever reads; tools cannot reach it. From a terminal, copy the key first, then:

```bash
scripts/set-api-key.sh
```

`ANTHROPIC_API_KEY` in the environment overrides the Keychain (handy for `swift run`).

**Model.** `profile.json → claude.model` (default `claude-sonnet-5-5`), overridable with `CLAUDE_MODEL`.
Requests stream over raw HTTPS (there is no official Swift SDK): `anthropic-version: 2026-10-21`,
`output_config.effort: low` for snappy voice replies, and `thinking: between_tools` on Sonnet 5.5 so the
model skips reasoning between tool calls. **Prompt caching**: the 29 tool schemas and the personality
block are a byte-stable prefix with `cache_control` breakpoints; mode, clock, and undo state ride in a
separate uncached system block. Measured: first turn writes ~9.9k tokens to cache, every following turn
reads them and sends only ~700 fresh input tokens. The reply is spoken sentence by sentence as it streams, so
you hear the first sentence while the rest is still arriving. A `refusal` stop reason becomes
"I can't help with that one."

**Web search.** Jarvis can search the web and read pages on its own, with no approval needed, using
Anthropic's server-side `web_search` and `web_fetch` tools. Ask "who won the Wildcats game", "is the Rec
open tonight", or "find the link for that Tinder internship". Searches run on Anthropic's side, so there is
no extra key or service. Each search is billed by Anthropic per use on top of tokens. Settings live in
`profile.json → web`:

```json
"web": { "enabled": true, "maxSearchesPerTurn": 5, "maxFetchesPerTurn": 3, "deepResearch": false }
```

`deepResearch: true` switches to the dynamic-filtering versions (`_20260209`), which run code over the results.
They're better for long research but slower, and Claude tends to narrate the steps aloud, so voice keeps the
basic versions. Search location follows the Mac's time zone: Tucson at home, Singapore when you're there.
Every search is logged to `actions.log` with source `claude-server`. Results are treated as untrusted
content, like email, so they can never start an action, and Tier 2 still needs your approval.

**Conversation memory** lasts 10 minutes of inactivity or 24 messages; *Clear Conversation* resets it.
**Offline:** a small local matcher still handles modes, volume, timers, opening apps, undo, and status.

## Calendar, email, Notion, briefing (Milestone 5)

**Calendar + Reminders: EventKit.** Reads every account already in macOS Calendar (Google included, and
anything Notion Calendar syncs through it). First use prompts for Calendars and Reminders full access.
Tools: `calendar_read`, `calendar_create` (undoable), `set_reminder` (Apple Reminders, undoable).
Times accept ISO 8601, `YYYY-MM-DD HH:mm`, `tomorrow 3pm`, `friday 10am`, `in 20 minutes`.

**Gmail: Google API with OAuth (PKCE, loopback redirect), read + compose scopes only.** One-time setup:

1. console.cloud.google.com → create a project → *APIs & Services → Library* → enable **Gmail API**.
2. *OAuth consent screen* → External, add yourself as a test user.
3. *Credentials → Create OAuth client ID → Desktop app*. Copy the client ID and secret.
4. Jarvis menu → *Integrations → Set Google OAuth Client…*, paste both (Keychain).
5. *Integrations → Connect Gmail…* opens the browser; approve; the refresh token lands in the Keychain.

Tools: `email_search` (Gmail query syntax), `email_read`, `email_draft` (creates a **draft**, never sends;
there is no send tool at all in this build, by design). Email bodies reach Claude wrapped as untrusted content.

**Notion: internal integration token.** notion.so/profile/integrations → New integration → copy the
secret → share your *Student OS // M Edition* page with the integration → Jarvis menu → *Integrations →
Connect Notion…*. `profile.json → dataSources.notion` is pre-filled with your Student OS data sources
(Homework / Exams / Classes) and their property names (`Assignment`, `Due`, `Status` with
`Submitted`/`Graded` meaning done; `Exam`, `Date`). Tools: `notion_search`, `notion_create_note`
(notes page under Student OS, or a homework / exam row with a date).

**Briefing.** `get_briefing` (and *Briefing Now* in the menu, or `kill -USR2`) merges: today's remaining
calendar events and reminders, Notion homework not yet submitted, the next deadlines, exams in the next
14 days with days left (calendar titles matching exam/midterm/final/quiz plus the Notion Exams table),
and assignment/exam emails from the last week. Missing sources are reported, never fatal. Synced
calendar titles are cleaned ("[CSC120] Midterm 2 Today at 3:00pm" → "CSC120 Midterm 2") and deduped.
In Class mode the summary also names the next class. The automatic morning briefing is Milestone 6.

Config evolution: on launch Jarvis adds any new default keys to your `profile.json` copy without
touching values you changed (logged as "Config: added new default keys").

## Modes, proactive features, maintenance (Milestone 6)

**Automatic modes.** `ContextDetector` samples every `pollingMinutes` and on display / wake events:
location (Core Location, *When in Use*; a fix is read on-device and never leaves the Mac or reaches
Claude), Wi-Fi name (needs the same Location permission on macOS 14+), power state, external
displays, and the calendar event happening now. `ModeScorer` (pure, unit-tested) scores each mode's
`triggers` in `modes.json`: known place +3, calendar keyword +4, power +1, displays +1, "away from
every known place on battery/hotspot" +2 for Road. A mode you pick by hand (menu or voice) holds
for `profile.json → proactive.manualOverrideHours` (2 h); *Mode → Automatic* clears it. Set
`proactive.autoModes: false` to disable detection entirely.

**Places.** Edit `modes.json → places`, or say *"Jarvis, remember this place as the gym"*
(`remember_place`, uses the current fix + Wi-Fi). Your dorm sits inside the campus geofence, so the
`home` place lists the **5G Honors** Wi-Fi: a Wi-Fi match scores higher than coordinates, which keeps
Honors Village in Home mode. Ties keep the current mode, so modes don't flap.

**Mode setup (all Tier 1, auto-applied, restorable).** On entering a mode Jarvis runs its `setup`
block through the dispatcher with source `mode`, so Tier 2 is structurally impossible: volume,
brightness (built-in display), quit / hide / open apps, and Focus. The previous state is snapshotted;
leaving the mode or saying *"undo that"* restores it. Focus has no public API, so create Shortcuts
named **`Jarvis Focus: Do Not Disturb`**, **`Jarvis Focus: Work`** (each one action: *Set Focus*) and
**`Jarvis Focus Off`**; `set_focus` runs them.

**Proactive.** `ProactiveScheduler` ticks every minute and delivers only when *all* gates pass:
Do Not Disturb off, outside quiet hours (`proactive.quietHoursStart/End`), not in a call or sharing
(any camera in use, or Zoom / FaceTime / Teams / Webex running, Discord or Slack only when frontmost),
and not in Class mode.

- Morning briefing at `briefing.time`, or the first screen unlock after 5 am (`onFirstUnlock`), once a day.
- Exam / deadline nudges at `briefing.nudgeDaysBefore` (7, 3, 1, 0), each said once.
- Road mode: battery warning at `lowBatteryWarnPercent`, at most every 30 min.
- Break reminders (off by default; menu toggle): after `breakAfterMinutes` of continuous activity in a
  coding app (Xcode, VS Code, Cursor, Terminal…), idle time resets it.

**Maintenance.**

| Tool | Tier | What |
|------|------|------|
| `organize_folder` | 1 | Desktop / Downloads → `Sorted/<Category>/` (or by month). Move only, logged to `~/Library/Logs/Jarvis/moves.json`, one undo puts everything back. `dry_run` previews. Flags files over `largeFileMB` or older than `oldFileDays`. |
| `app_health` | 0 | Is it running, memory, last log lines (`~/Library/Logs/<name>/`). |
| `restart_app` | 2 | Quit + relaunch one named app, after approval. |
| `performance_report` | 0 | Memory pressure, top memory/CPU, free disk, biggest caches, LaunchAgents, suggested actions. |
| `clear_caches` | 2 | Moves named `~/Library/Caches/<x>` folders to the **Trash** (recoverable), after approval. |

Never, even with approval: emptying the Trash, deleting outside folders Jarvis created, system folders,
security settings, `sudo`.

**Typing instead of talking:** *Ask by Text…* in the menu runs the same pipeline without the mic.

## Iron Man mode: persona, "Wake up, Daddy's home", full-screen HUD

**Persona.** `profile.json → assistant.persona: "ironman"` adds JARVIS's manner to the system prompt:
composed, dry British understatement, "sir" now and then, flight-check status reports, no verbatim film
quotes. The voice picker now prefers British voices (Daniel, Oliver, Kate, Serena); download a Premium
one in System Settings → Accessibility → Spoken Content for the full effect.

**Coming home.** When Jarvis sees your home Wi-Fi after 20+ minutes away (or wakes from sleep at
home), an *arrival window* opens for `wake.arrivalWindowMinutes` (10). During it:

- saying **"Wake up, Daddy's home"** (or just "Daddy's home") runs the **homecoming scene**;
- saying **"Hey Jarvis"** also runs it (`wake.homecomingOnHeyJarvis`), once; the next "Hey Jarvis" is a normal turn.

Outside the window "Hey Jarvis" behaves as usual, and *"I'm home"* in any conversation runs the scene
through the `welcome_home` tool. The scene: full-screen HUD, a welcome line in character, Home mode,
then today's status.

How the second phrase works, honestly: openWakeWord only ships trained models for a few phrases, so
"Daddy's home" is spotted with on-device SpeechAnalyzer running on the mic stream. That costs about
**28 % CPU** while it runs, which is why it only runs inside the arrival window (`wake.alwaysSpotPhrases`
turns it on permanently if you accept the cost). Phrases and aliases live in `profile.json → wake.phrases`.

**Full-screen HUD.** An arc reactor that spins faster while thinking and pulses with your voice, grid
backdrop, flight-check readouts (time, power, memory, disk, mode) on the left, today's items on the
right, transcript and reply along the bottom. Click or press Esc to dismiss; it fades on its own
`hud.dismissAfterSeconds` after a turn. It appears for scenes by default; *Full-Screen HUD for Every
Conversation* in the menu (or "Jarvis, full screen" → `set_display_mode`) makes every turn take the
screen. Reduce Motion freezes the rings.

**Which display.** `profile.json → hud.preferredDisplay` ("Odyssey G5") puts the HUD on that monitor
whenever it is connected, and on the notch screen otherwise. The menu shows which display is in use.
The notch pill and edge glow always stay on the built-in display.

**A proper conversation.** After each reply Jarvis keeps listening for `speech.followUpSeconds` (7 s)
with a calmer glow and "Go on…" in the notch, so the next sentence needs no wake word. Say "thanks",
"that's all", or "bye" to end; silence ends it quietly. *Conversation Mode* in the menu turns this off.
**Cutting it off:** talk over Jarvis and it stops mid-sentence and takes what you said as the next turn
(`speech.interruptOnSpeech`). The mic also hears Jarvis itself through the speakers, so words that
mostly match what it is currently saying are ignored as echo; "stop" still works on its own. The HUD
shows the last three exchanges.

Test hooks: write `!homecoming`, `!arrive`, or `!hud` to `~/Library/Application Support/Jarvis/ask.txt` and
`kill -INFO $(pgrep -x Jarvis)`.

## Look, music, and voice (0.9)

**Floating card instead of the notch.** Jarvis now appears as a dark card at the bottom of whichever
screen your mouse is on, only while it is listening, thinking, or answering. Nothing sits near the menu
bar, and there is no glow or halo. Click × to dismiss and stop it talking. `profile.json → ui`:
`style` (`floating` or `notch`), `screen` (`active` or a display name like `"Odyssey G5"` to pin it),
`position` (`bottom`, `center`, `top`), `halo` (`false`). The full-screen HUD is off for normal
conversations (menu toggle) and still used for the homecoming scene.

**Music.** The `music` tool drives Spotify (or Apple Music) through AppleScript: play, pause, next,
previous, what's playing, volume, shuffle, and **play by name**. macOS asks once to let Jarvis control
Spotify. Playing a specific song needs a free Spotify developer app for search (no login): Jarvis menu →
Integrations → *Set Spotify Client…* (steps in the dialog). Without it, Jarvis opens Spotify's search
for the song so one click plays it.

**Voice.** macOS hides its smoother Siri and Premium voices from third-party apps, so Jarvis on its own
only gets the basic voices. The default fix is free:

**Kokoro (free, on-device, no key).** [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) is an
Apache-2.0 neural voice that runs locally through `kokoro-onnx`. Install once (~200 MB):

```bash
scripts/setup-kokoro.sh
```

Jarvis then starts the voice server itself (127.0.0.1:8880 only) and stops it on quit. It works offline,
nothing leaves the Mac, and there are no limits. Measured on the M4 Pro: about 0.6 s for a short sentence,
1.9 s for ten seconds of speech; the voice server uses about 840 MB of memory and no CPU while idle. Pick the voice under Jarvis menu →
Voice → Kokoro Voice: George (default), Lewis, Daniel, Fable (all British male), or American ones.

Paid alternatives, also in the menu → Voice:
- *Set ElevenLabs Key…* (most natural; default voice "Daniel", a deep British male; free tier available).
- *Set OpenAI Key…* (gpt-4o-mini-tts, voice "fable", steered to sound like a calm British butler).

Replies are spoken sentence by sentence while the rest streams; if the cloud voice fails or you're
offline, that reply finishes on the Apple voice. Cloud voices send the reply text to that provider.

## Ported from OpenJarvis

[OpenJarvis](https://github.com/open-jarvis/openjarvis) (Stanford, Apache-2.0) is a Python/Rust/Tauri
framework for local-first personal AI. Switching stacks would have dropped the native notch, wake word,
and permission dispatcher, so instead these ideas were re-implemented in Swift:

| From OpenJarvis | Here |
|---|---|
| `memory_manage` / `user_profile_manage` (MEMORY.md, USER.md) + SQLite FTS5 memory | `memory` tool (Tier 1, undoable) writes `MEMORY.md` / `USER.md` in `~/Library/Application Support/Jarvis`, injected into every turn. Every exchange is indexed in `memory.db` (FTS5, secrets redacted first); `memory_search` answers "what did I ask you about…". Menu → Memory to open or forget history. |
| `LoopGuard` | Blocks identical repeated tool calls, A↔B ping-pong, and more than 12 tool calls per turn. |
| `SecretScanner` / `credential_stripper` | Every tool result is scrubbed for API keys, tokens, private keys, passwords, DB URLs and card numbers before Claude sees it. Memory refuses secrets. |
| `InjectionScanner` | Untrusted content (email, web, files, calendar) matching injection patterns is labelled with a warning Claude must heed and report. |
| `jarvis.md` persona | Briefing rules: only facts from the data, skip missing sources silently, "sir" sparingly. |
| Morning digest (LLM-synthesised, world section) | Briefings are now written by Claude in JARVIS's voice, with weather (Open-Meteo, keyless, city name only) and top headlines (Hacker News). New `weather` and `news_headlines` tools. Falls back to the template if Claude is slow or unreachable. |
| Local-first engine (Ollama) | When offline, or always in **Private Mode** (menu), turns go to a local model through Ollama with a trimmed tool set. `profile.json → local.model` (default `qwen3.5:9b`). |
| Skills (agentskills.io `SKILL.md`) | Folders in `~/Library/Application Support/Jarvis/skills`; the catalog goes in the prompt and `use_skill` loads one. Ships with `exam-prep`. Skills are instructions only; permission tiers still apply. |

Not ported, on purpose: their Python agent zoo, the browser GUI, iMessage (needs Full Disk Access),
Oura/Strava connectors, training/learning loops, and crypto "Pearl mining".

**Local model setup** (one time, ~6 GB download):

```bash
ollama serve
```

```bash
ollama pull qwen3.5:9b
```

The menu shows "Local model: … ready" once it's available.

## Safety model (enforced in code, Milestone 4)

Every tool call goes through `ToolDispatcher` ([Permissions/ToolDispatcher.swift](Sources/JarvisCore/Permissions/ToolDispatcher.swift)), in this order:

1. The tool must exist and not be **Tier 3** (refused outright, never offered to Claude).
2. The tool declares what it will touch (paths, apps, shell text); the **denylist** checks all of it
   before anything else happens — denied paths and their children, file patterns anywhere in a path,
   app names, shell substrings, and any path mentioned inside a shell command.
3. The current mode's `allowedTools` list.
4. **Tier 2** needs approval: an approval card in the notch (Approve / Deny) plus "yes"/"no" by voice,
   12 s timeout = denied. Only calls that come from a live user turn may ask; proactive features and
   mode changes can never trigger Tier 2.
5. Run, log, and surface a one-line summary for Tier 1+ ("Volume 40%").

Every call is a JSON line in `~/Library/Logs/Jarvis/actions.log` (time, tool, tier, source, input,
outcome, duration). *What Did You Do Today?* in the menu and the `actions_today` tool read it back.

| Tier | Behaviour | Tools today |
|------|-----------|-------------|
| 0 automatic | read-only, runs on Anthropic's side | `web_search`, `web_fetch` |
| 0 automatic | read-only | `system_status`, `file_search`, `file_read`, `get_location_context`, `actions_today`, `get_briefing`, `calendar_read`, `email_search`, `email_read`, `notion_search` |
| 1 free | reversible, logged, undoable | `open_app`, `set_volume`, `media_control`, `set_timer`, `set_mode`, `undo_last_action`, `calendar_create`, `set_reminder`, `email_draft`, `notion_create_note` |
| 1 free (cont.) | | `set_brightness`, `set_focus`, `remember_place`, `organize_folder` |
| 0 automatic (cont.) | | `app_health`, `performance_report` |
| 2 approve | preview + explicit yes | `run_shell` (zsh, 30 s timeout, minimal env, never sudo), `restart_app`, `clear_caches` |
| 3 never | denylist.json + hard-coded floor | — |

Prompt-injection defence: `file_read` (and the email / web / calendar tools in Milestone 5) wrap
their output in `<untrusted_content source=…>` tags; the system prompt tells Claude such content is
data, never instructions, and to tell you if it tried to be. Closing tags inside the content are neutralised.

**Adding a tool** is one file in `Tools/`: conform to `JarvisTool` (name, description, tier, JSON
schema, `targets(for:)`, `run`), then add it to the `register([...])` list in `AppDelegate`.
The dispatcher handles denylist, approval, logging, and the undo stack.

The dispatcher and denylist are covered by `Tests/JarvisCoreTests/PermissionTests.swift`.

## Known limitations

- Gmail and Notion were built against the API docs but not exercised live (no tokens on this Mac during development). Parsers are unit-tested; errors are spoken and logged.
- Brightness uses a private framework and works on the built-in display only. Focus needs the Shortcuts above.
- Call detection is heuristic (camera in use or a call app running). A browser-only Meet call with the camera off is not detected.
- Idle CPU with the wake word is 3–4 % in `top`, just above the 3 % target; the embedding model is the floor.
- Ad-hoc signing re-prompts for permissions and Keychain access after every rebuild; `scripts/make-dev-cert.sh` fixes that.
- I could not make a live Claude call during development because no API key was on this machine. The request shape is unit-tested and follows the current API docs; the first real turn is yours. If something 400s, the error text is spoken and logged.
- `media_control` posts system media-key events; on some macOS versions this needs Accessibility. If play/pause does nothing, that's why.
- Wake → first transcribed word measured 1.3 s with SpeechAnalyzer (includes the natural pause after "Hey Jarvis"). Partial results arrive faster once you're mid-sentence.
- Launching the raw binary from a terminal makes macOS attribute permission requests to the terminal (it even crashes on the speech prompt). Always launch `Jarvis.app` via `open` / `scripts/run.sh`.
- The wake model is English-trained TTS/real-speech data; a quiet room and the built-in mic work best. Lower `threshold` in `WakeWordService` if it misses you, raise it if it false-triggers.
- Idle CPU lands at 3–4% in `top`, just above the 3% target. Every lever tested (batching, QoS, Core ML provider) measured the same, so the next step would be a smaller embedding model.
- Jarvis listens on whatever macOS picks as the default input. With AirPods on, that is the AirPods mic.
- Mode switching is manual; automatic detection and per-mode setup land in Milestone 6.
- Focus modes and display brightness have no public API. Focus will be toggled through a
  Shortcut you create once; brightness through a private display call with graceful fallback.
- Ad-hoc signing resets permission grants on each build (see *Code signing*).

## Changelog

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
