# Privacy and security

## Privacy: what leaves this Mac, and what is kept

**Local-first.** Menu → *Privacy* lists, for the settings in use right now, what stays on this Mac and what
leaves it. The same summary is written to `jarvis.log` at every start (`Privacy: No audio leaves this Mac. …`).

| Stage | Data | Where it is processed |
|---|---|---|
| Wake word | microphone audio | this Mac (openWakeWord) |
| Speech recognition | the audio of each request | this Mac (Apple SpeechAnalyzer, on-device) |
| Voice ID | your voiceprint, each request's audio | this Mac |
| Remote access | recordings from your phone | this Mac, over your tailnet |
| Thinking | the request as text, the conversation, tool results | Anthropic (Claude) |
| Looking | one camera frame or screenshot, only when you ask | Anthropic |
| Web search | queries and page addresses, only when needed | Anthropic |
| Speaking | the text of the reply | this Mac (Kokoro, Apple); ElevenLabs or OpenAI only if you choose those voices |
| Gmail, Notion, Spotify, weather | what you ask about | that service, only when you ask |

**No stage sends audio to the cloud.** The one that could is the fallback recognizer on older macOS for a
language Apple cannot recognize on-device; there Jarvis refuses and says so rather than send your voice to
Apple. That is your decision to change: `cloudSpeechRecognition` = `never` (default) or `allow`. If it is
ever in effect, the Privacy menu's first line and the startup log say that audio leaves this Mac.
Text does leave: Claude needs the words to answer. Nothing is sent anywhere until the wake word fires.

**Retention.** Applied when Jarvis starts and once a day. `0` means keep forever.

| What | Where | Kept | Setting |
|---|---|---|---|
| What was said, by you and by Jarvis | `~/Library/Logs/Jarvis/conversations.log` | 30 days | `retainConversationsDays` |
| Per-request timings (no words) | `trace.jsonl` | 30 days | `retainTraceDays` |
| Diagnostics | `jarvis.log` | 14 days | `retainLogDays` |
| Every tool call: the audit trail | `actions.log` | 90 days | `retainActionsDays` |
| Photos and videos you asked for | `~/Pictures/Jarvis`, `~/Movies/Jarvis` | forever; with a limit, older ones go to the Trash | `retainMediaDays` |
| Recent chats for context | memory only | 30 minutes, gone on quit | `sessionMemoryMinutes` |
| Long-term memory (facts you told it) | `memory.db` | until you remove them | |
| Your voiceprint | `voiceprint/` | until *Voice ID → Forget* | |
| Audio of requests, camera frames for "look" | not stored | | |
| Remote access tokens (hashes) | `remote/tokens.json` | until revoked | |
| Spending totals | `spend.json` | amounts only | |

Logs also rotate by size (5 MB, three old files). Jarvis only ever prunes its own four log files and, if
you set a limit, files it named itself in its own two media folders, and those go to the Trash, not away.
API keys are in the Keychain behind Touch ID and are redacted from tool output and logs.

## Safety model (enforced in code, Milestone 4)

Every tool call goes through `ToolDispatcher` ([Actions/ToolDispatcher.swift](../Sources/JarvisCore/Actions/ToolDispatcher.swift)), in this order:

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
| 1 free (calendar) | undoable; asks first if other people are invited | `calendar_move` |
| 1 free (people) | undoable | `contacts` (find, save, remove, list) |
| 1 free (camera) | user requests only; asks first after outside content | `look`, `camera` (live feed, photo, video) |
| 2 approve | preview + explicit yes | `run_shell` (zsh, 30 s timeout, minimal env, never sudo), `restart_app`, `clear_caches`, `calendar_cancel`, `email_send` |
| 3 never | denylist.json + hard-coded floor | — |

Prompt-injection defence: `file_read` (and the email / web / calendar tools in Milestone 5) wrap
their output in `<untrusted_content source=…>` tags; the system prompt tells Claude such content is
data, never instructions, and to tell you if it tried to be. Closing tags inside the content are neutralised.
Approvals asked after such content was read say so (see the confirmation gate above).

**Adding a tool** is one file in `Actions/Tools/`: conform to `JarvisTool` (name, description, tier, JSON
schema, `targets(for:)`, `run`), then add it to the `register([...])` list in `AppDelegate`.
The dispatcher handles denylist, approval, logging, and the undo stack.

The dispatcher and denylist are covered by `Tests/JarvisCoreTests/PermissionTests.swift`.

## Keys: Touch ID instead of the keychain password

Jarvis keeps its API keys and tokens (Claude, Google, Notion, Spotify, ElevenLabs, OpenAI) in the macOS
Keychain. On their own, Keychain items are approved per program, and for an app without an Apple
Developer signature "the program" means the exact binary. Every rebuild made a new binary, so macOS asked
for the keychain password again, sometimes in the middle of a conversation, underneath the HUD.

So the keys now sit behind a small separate program, `jarvis-keyhelper`:

```bash
scripts/install-keyhelper.sh     # once. It is deliberately NOT rebuilt when Jarvis is.
```

- **It never changes, so its approval sticks.** It is installed to
  `~/Library/Application Support/Jarvis/bin/` and left alone. Rebuilding Jarvis does not touch it.
- **Touch ID unlocks it.** When Jarvis starts, the helper asks for Touch ID (or the Mac's password, which
  is macOS's own fallback) and then hands all the keys over in one go. Jarvis holds them in memory until
  it quits. Nothing is asked again while it runs, and never during a conversation.
- **Only Jarvis can ask.** The helper checks that the program calling it is a validly signed
  `com.samarth.jarvis` carrying the same certificate as itself, and refuses anything else:

  ```bash
  echo '{}' | ~/Library/Application\ Support/Jarvis/bin/jarvis-keyhelper get
  # {"error":"refused: caller is com.apple.zsh, not Jarvis","ok":false}
  ```

- **The first run moves the old keys in.** macOS asks for the keychain password one last time per saved
  key ("jarvis-keyhelper wants to use…"). Choose *Always Allow*. A key you decline stays where it was and
  keeps working the old way; *Keys → Import … Keys from the Old Keychain* tries again.

| Menu → Keys | |
|---|---|
| Status line | How many keys are unlocked, or "Locked". |
| Unlock with Touch ID… | Ask again, for example after cancelling the prompt at startup. |
| Require Touch ID to Unlock | On by default. Turning it off itself needs Touch ID. |

If Jarvis is asked something while the keys are locked it says so ("My keys are locked. Unlock me with
Touch ID, then ask again.") and brings the Touch ID prompt up.

What this does and does not protect: the keys are released only to Jarvis, only after Touch ID, and are
never written to disk outside the Keychain. They are in Jarvis's memory while it runs, as before. The
helper's own Keychain approval is tied to its exact binary, so `install-keyhelper.sh --force` (a new
helper build) brings the password prompts back once. Without the helper installed, Jarvis reads the
Keychain directly as it used to, once per key per launch. Unit tests never touch the real Keychain.

Why not the Keychain's built-in Touch ID protection? That needs an entitlement only an Apple Developer
team signature can carry; with a self-signed certificate macOS answers `-34018`.

## Voice ID: checking it is you

With Voice ID set up, Jarvis checks whose voice made each spoken request, and anything that needs approval
is gated on the result.

**Setup** (about a minute). Install the model once, then enroll:

```bash
scripts/setup-voiceid.sh        # 24.9 MB model, verified by checksum
```

Then choose *Voice ID → Set Up Voice ID…* in the menu, or say "set up Voice ID". Jarvis shows five sentences;
after each tone you read the one on screen. If a sentence is missed it asks again, and if the recordings do
not sound like one voice nothing is saved.

**Which model, and why.** Three were considered:

| Option | For | Against |
|--------|-----|---------|
| **ECAPA-TDNN** (chosen) | The most accurate of the three (0.88% error on VoxCeleb1), free, and it runs in the ONNX Runtime Jarvis already ships for the wake word, so nothing new runs in the background | A 25 MB model file to download |
| Picovoice Eagle | Easiest to integrate, small | Needs a Picovoice account and access key, and the free tier is metered |
| Resemblyzer | Simple | Older and less accurate, and needs a Python process running next to Jarvis |

The model is the WeSpeaker project's ECAPA-TDNN trained on VoxCeleb (CC-BY-4.0), published as ONNX. Features
are computed in Swift ([VoiceID/Fbank.swift](../Sources/JarvisCore/VoiceID/Fbank.swift)) and match a Python
reference above 0.999. One check takes about 90 ms.

**At run time.** The audio of each spoken request, "Hey Jarvis" included, is compared with your voiceprint.
The result is a score from 0 to 1; `tuning.speakerThreshold` (0.5) or more counts as you.

| The request was… | A spoken "yes" | The Approve button | A spoken "no" |
|---|---|---|---|
| Spoken, and verified as you | Counts | Counts | Counts |
| Spoken, not verified (another voice, or too little speech) | Ignored | Counts | Counts |
| Typed | Ignored | Counts | Counts |
| Anything, with `tuning.unverifiedVoiceApproval` set to `never` | Refused outright | Refused | n/a |

When the voice is not verified, Jarvis says so: "I couldn't verify your voice, so approve it on screen: …".
This applies to everything that needs approval: sending email, cancelling events, shell commands, moving an
event other people are invited to, and the camera after outside content. Replacing or deleting the voiceprint
by voice needs an approval too, so someone else cannot take the gate over.

**Local only.**
- The voiceprint is 192 numbers in `~/Library/Application Support/Jarvis/voiceprint/voiceprint.json`,
  readable only by your user (folder 0700, file 0600).
- No audio is stored. Enrollment recordings and each request's audio are held in RAM and dropped after use.
- Nothing is sent anywhere: the model runs on this Mac and the voiceprint is never in a request or a log.
  Logs carry only the score.
- The folder is on the hard-coded denylist, so no tool can read it, and it is in `.gitignore`.
- *Voice ID → Forget My Voice* deletes it.

**What it is not.** Voice ID tells voices apart; it does not prove a voice is live. A good recording or a
clone of your voice could pass. Treat it as a second check on top of the approval, not as a lock. The scores
from the synthetic test voices (same voice 0.68 to 0.92, another voice at most 0.39) are cleaner than a real
room will be; after enrolling, watch *Voice ID → Last request* for a few days and adjust the threshold if
you are being rejected or the margin looks thin.
