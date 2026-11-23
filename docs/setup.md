# Setup

## Requirements

- macOS 14 or newer (built and tested on macOS 26 / Xcode 27.2, Apple Silicon)
- Xcode command line tools (`xcode-select --install`) or full Xcode

## Build, run, test

```bash
# Build Jarvis.app into ./build and launch it
scripts/run.sh

# Just build the .app (release by default; pass "debug" for a debug build)
scripts/build-app.sh

# Tests, reported per pipeline stage (or plain `swift test`)
scripts/test.sh

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
will be re-prompted after each rebuild. Fix it once with a stable self-signed identity (this keeps the
permission grants; the saved keys are a separate matter, see *Keys: Touch ID instead of the keychain
password*):

```bash
scripts/make-dev-cert.sh
```

```bash
JARVIS_SIGN_IDENTITY="Jarvis Dev" scripts/run.sh
```

(Or make it in Keychain Access → Certificate Assistant → Create a Certificate → name `Jarvis Dev`,
type Code Signing.)

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
It is stored in the Keychain and released to Jarvis after Touch ID (see *Keys: Touch ID instead of the
keychain password*). Jarvis's own saved keys are the only Keychain items it ever reads; tools cannot reach
them. From a terminal, copy the key first, then:

```bash
scripts/set-api-key.sh
```

`ANTHROPIC_API_KEY` in the environment overrides the Keychain (handy for `swift run`).

**Model.** `profile.json → claude.model` (default `claude-sonnet-5-5`), overridable with `CLAUDE_MODEL`.
Requests stream over raw HTTPS (there is no official Swift SDK): `anthropic-version: 2026-10-21`,
`output_config.effort: low` for snappy voice replies, and `thinking: between_tools` on Sonnet 5.5 so the
model skips reasoning between tool calls. **Prompt caching**: the 43 tool schemas and the personality
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

### Tuning and environment overrides

Every threshold, limit, and timeout lives in `profile.json → tuning` (wake threshold, mic recovery
timings, Claude effort and timeouts, tool budgets, approval timeout, speech ports). Nothing is a literal
in the code; the definitions and defaults are in [Config/Settings.swift](../Sources/JarvisCore/Config/Settings.swift).

Any tuning field can be overridden by an environment variable named `JARVIS_` plus the field in upper
snake case, for example `wakeThreshold` → `JARVIS_WAKE_THRESHOLD`. A menu-bar app has no shell
environment, so Jarvis also reads an env file:

```bash
cp .env.example ~/Library/Application\ Support/Jarvis/jarvis.env
```

Uncomment what you want, then restart Jarvis. The real process environment wins over the file, and the
file wins over `profile.json`. Overrides that took effect are logged at startup, and a value that is not a
valid number is reported in the menu bar and ignored.

**Secrets never go in the env file.** API keys stay in the macOS Keychain. Jarvis ignores any variable
in `jarvis.env` whose name contains KEY, TOKEN, SECRET, PASSWORD, or CREDENTIAL, and says so in the log.
`.gitignore` excludes env files, logs, databases, and voice enrollment data.
