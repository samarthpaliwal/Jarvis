# Features

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

**Speech-to-text** sits behind the `Transcriber` protocol in `STT/`:

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

Tools: `email_search` (Gmail query syntax), `email_read`, `email_draft` (creates a **draft**, never sends),
and `email_send`, which sends a draft Jarvis created, only after your explicit yes (see *Multi-step requests
and the confirmation gate*). Email bodies reach Claude wrapped as untrusted content.

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

## Calendar: list, create, move, cancel

Jarvis works on every account in macOS Calendar (iCloud, Google, Exchange) through EventKit.

| Say | Tool | Safety |
|-----|------|--------|
| "What's on tomorrow?" | `calendar_read` | Read-only. Marks events that repeat, have other people invited, or are read-only. |
| "Add office hours Friday at 2." | `calendar_create` | Undoable ("undo that" deletes it). |
| "Move calculus tomorrow to 3." | `calendar_move` | Undoable (moves it back). Keeps the event's length. |
| "Cancel my dentist appointment." | `calendar_cancel` | Always asks first. Undo puts back a copy. |

- **Finding the event.** You name it by a few words and the day. If nothing matches, or two events do, Jarvis
  asks which one instead of guessing.
- **Other people.** Moving or cancelling an event with invitees can notify them, which is a message sent on
  your behalf. Jarvis asks first, and a proactive feature can never do it.
- **Cancelling.** The approval names the event that will really be deleted, with its date and time, not just
  the words you used.
- **Repeating events.** Only the occurrence you named changes. The rest of the series is untouched.
- **Read-only calendars** (holidays, a subscribed class schedule) are never changed.

## Multi-step requests and the confirmation gate

"Check Friday, draft a note to Maya about it, and send it" is one request with three steps. Jarvis says
the plan in a sentence, runs the steps in order, and stops for your yes before the one that cannot be undone.

- **What needs a yes** (Tier 2): sending an email, cancelling an event, running a shell command, restarting
  an app, clearing caches. Jarvis says exactly what it is about to do and listens for "yes" or "no" after it
  has finished speaking; the card also has Approve and Deny. No answer in 12 seconds means no.
- **The approval reads back the real thing.** For an email that is the recipient, subject, and opening line
  as Gmail holds them. For an event it is the title, date, and time of the event that will be deleted.
- **Outside content is called out.** If the request read an email, a web page, a file, or the calendar
  before asking, the approval ends with "Note: I read an email before asking this". That is where a
  prompt injection would have to get through, so that is where you are told.
- **Sending is narrow.** `email_send` only sends a draft that `email_draft` created since Jarvis started.
  A draft that was already in Gmail, or an ID that turned up inside an email, is refused before you are
  even asked. To turn sending off, remove `email_send` from the mode's `allowedTools` in `modes.json`.
- **If you say no, or a step fails,** the chain stops there and Jarvis says what was done and what was not.
  A refused email stays in Drafts.
- **Limits:** ten model rounds and sixteen tool calls per request (`tuning.llmMaxToolRounds`,
  `tuning.toolCallBudgetPerTurn`), and the 120-second request deadline.
- **Nothing irreversible is ever started by a briefing, a timer, or a mode change.** Only a live request from
  you can reach an approval.

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

## Google in the browser

"Hey Jarvis, google cheap flights to Seattle" opens your default browser on the Google results page, with
the search already typed in. "Google images of red pandas", "google news about…", "find ramen on Google
Maps" work the same way (`google_search`, kinds `web`, `images`, `news`, `videos`, `maps`).

- **It opens one page and stops.** It does not click results, fill in forms, or sign in to anything.
- **Asking a question is different.** "What's the cheapest flight to Seattle?" still gets a spoken answer
  from Claude's own web search, with no browser.
- **Only when you ask.** A briefing, a timer, or a mode change can never open a search.
- **Outside content.** If the request read an email, a web page, or a file first, Jarvis reads the exact
  search back and waits for your yes, because a search is a way to send words to Google.
- **Never a key or a password.** A search that looks like one is refused.
- The address is always `https://www.google.com/…`; the words you said can only ever be the search.

## Any website

"Hey Jarvis, open YouTube", "go to github.com/samarthpaliwal" opens that page in your default browser
(`open_website`). Like the Google search it opens one page and stops.

- **https, public sites only.** Addresses on this Mac or your network, IP addresses, other ports, and
  anything that is not a web page (`file:`, app links) are refused.
- **No banking, payment, or password sites.** Every app name in `denylist.json` also blocks its site
  (Chase blocks chase.com), plus a built-in list. Refused even if you ask.
- **Only when you ask**, and with a yes first, showing the whole address, if the request read outside content.

## Lights (Govee)

"Turn the lights off", "make the desk light blue", "lights to 40 percent", "warm white" (`lights`).

Set up once: in the Govee Home app go to Profile → Settings (the gear) → **Apply for API Key**. Govee emails
the key. Then Jarvis menu → Integrations → **Connect Govee Lights…** and paste it. It is kept in the Keychain
behind Touch ID.

- Names match loosely: "desk" finds "Desk Strip". No name means every light. An unknown name gets the list back.
- Only lights are touched. Other Govee devices on the account (a heater, a humidifier) are ignored.
- A light that cannot do what was asked (colour on a white-only lamp) is reported, not skipped silently.
- Commands go through Govee's servers, so they need the internet and show under *Privacy* once connected.
- Govee's API does not cover every model; a light missing from "list the lights" is one Govee does not expose.

## Staying awake while plugged in

Menu → **Stay Awake While Plugged In**. While it is on and the charger is connected, the Mac does not go to
sleep on its own, so the phone app can still reach Jarvis when you are out. The display still sleeps. It is a
request Jarvis holds (like `caffeinate`), not a system setting: it ends when the charger is unplugged or
Jarvis quits. **Closing the lid still puts the Mac to sleep**; leave it open, or use an external display.

## Mouse and keyboard control

Off by default. It turns on only when you say so ("Hey Jarvis, enable computer control"), for ten minutes
(up to thirty if you ask), and is off again after every restart. While it is on, Jarvis can look at the screen,
click, type a line, press keys, and scroll (`computer`). The menu shows the state and turns it off with a click.

One-time setup, which only you can do: System Settings → Privacy & Security → **Accessibility** → switch Jarvis
on (macOS opens the right page the first time), and **Screen & System Audio Recording** → Jarvis.

What the code enforces, not just what the model is told:

- **Esc turns it off at once.** So does clicking or typing yourself right after Jarvis acted.
- **One yes per app** each time it is switched on ("Use the mouse and keyboard in Safari").
- **Never in:** terminals, Mail, Messages and other chat apps, System Settings, the App Store, code editors,
  password managers, anything in `denylist.json`, or a window whose title mentions a bank, a payment, a
  checkout, billing, or passwords. Those apps are also cut out of the picture Jarvis sees.
- **Never:** typing into a password field, typing anything that looks like a key, pasting, locking, logging out.
- **A yes first** for a click on anything labelled send, post, buy, pay, order, delete, submit, sign in,
  install, download, accept and the like, and for Return anywhere except a search box or the address bar.
- **Only at the Mac.** Not from the phone, not from a briefing, timer, or mode change.
- **The screen is outside content.** After a look, the request is treated like one that read a web page.
- Each look sends one picture of the screen to Claude (shown under *Privacy* while control is on). It is not
  saved. Private Mode and gpt-oss cannot see, so it only works with Claude.

**What it cannot promise.** The labels come from what each app tells macOS. A web page with an unlabelled
or oddly named button can be clicked without a question. Jarvis is told to stop and ask before anything that
sends, buys, or deletes, and the gates above catch the usual cases, but watch it while it works.
A request gets at most sixteen steps, so long tasks need to be asked for in parts.

## Vision: looking on demand

"Hey Jarvis, what am I holding?" takes one picture with the Mac's camera and shows it to Claude.

- **On demand only.** The `look` tool runs only inside a live request from you. A briefing, a timer, or a
  mode change can never trigger it; the dispatcher refuses.
- **One frame.** The camera opens, exposure settles for about half a second, one frame is taken, and the
  camera closes. macOS shows its green indicator while it is on.
- **Where the picture goes.** It is scaled to 1280 pixels, sent to Claude with your question, and kept in
  RAM for the rest of that chat so you can ask a follow-up. It is never written to disk or to any log, and
  only the newest picture stays in the conversation.
- **Outside content.** If the request read an email or a web page before reaching for the camera, Jarvis
  asks first and says why.
- **Permission.** macOS asks for camera access the first time. Deny it and everything else keeps working.
- **People.** Jarvis describes what it sees and does not identify real people from their faces.
- **Private Mode** has no vision: the local model cannot see.

### Live feed, photos, and video

"Show me the camera" opens a small floating window with the live picture. "Record a video" and "take a
photo" save to folders Jarvis creates: `~/Movies/Jarvis` and `~/Pictures/Jarvis`. The same things are in the
menu under *Camera*.

| Say | What happens |
|-----|--------------|
| "Show me the camera." / "Close the camera." | Opens or closes the live feed. The camera is on while the window is open. |
| "Record a video." / "Record 20 seconds." | Starts recording, with sound. Opens the feed if it is closed. |
| "Stop recording." | Saves the video and says where. |
| "Take a photo." | Saves one still. |

- **A recording is always visible.** It only runs while the feed window is open, and the window shows a red
  `● REC` badge with a running clock. Closing the window stops the recording and turns the camera off.
- **Every recording ends.** With no length given it stops at five minutes (`tuning.videoMaxSeconds`), and
  Jarvis says so.
- **Nothing is uploaded.** The feed and the files never leave the Mac. Only `look` sends anything, and that
  is one frame.
- **Same rules as `look`:** user requests only, and a yes is needed first if the request read outside content.
- The feed is mirrored, like a mirror. Photos and videos are not.

One camera session is shared by the feed, `look`, photos, and video
([Vision/CameraSession.swift](../Sources/JarvisCore/Vision/CameraSession.swift)). It turns off when the last of
them is done.

Frames come from a `FrameSource` ([Vision/FrameSource.swift](../Sources/JarvisCore/Vision/FrameSource.swift)).
`camera` is the Mac's camera. `glasses` is a `PushedFrameSource`: a bridge pushes its newest frame and
`look` with `source: "glasses"` reads it, refusing anything older than ten seconds. Nothing feeds it yet;
that is the hook for the remote-access phase.

## Memory: what Jarvis remembers, and for how long

| Layer | Holds | Lives in | Lasts |
|-------|-------|----------|-------|
| This chat | Everything said since the card appeared | RAM | Until the card closes, or 10 idle minutes |
| This sitting | A short recap of the last 6 exchanges from chats that already closed | RAM | 30 minutes, gone when Jarvis quits |
| Preferences and facts | "prefers Celsius", "CSC 210 lab is in Gould-Simpson 701" | `USER.md`, `MEMORY.md` | Until you change them |
| Contacts | Name, email, phone, how you refer to them | `contacts.json` | Until you remove them |
| Archive | Every past exchange, searchable | `memory.db`, `conversations.log` | See the retention policy |

Everything is in `~/Library/Application Support/Jarvis/` and `~/Library/Logs/Jarvis/` on this Mac. Nothing is synced.

- **Session recap.** The card shows one chat at a time and each chat starts clean. So that "move it to four
  instead" still works a minute later, the next chat is given a few lines about the previous ones. The recap
  is clipped, has secrets redacted, is marked as context and not instructions, and is never written to disk
  (`tuning.sessionMemoryMinutes`, 0 turns it off).
- **Contacts.** "Maya is my lab partner, her email is maya@example.com" saves her. "Email my lab partner"
  then finds her. If nobody is saved under a name, Jarvis looks in macOS Contacts, which asks for your
  permission the first time; only the matching name, email, and phone are read. If nobody is found,
  Jarvis asks you. It never invents an address.
- **Nothing that looks like a credential** is stored in any layer.

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

## A second brain: gpt-oss 120B, hosted

Jarvis can use a second model next to Claude: OpenAI's open-weight **gpt-oss:120b**, run on Ollama's
servers. Nothing is installed or started on the Mac for it, and there is no command to run: Jarvis calls
it over HTTPS when needed.

**Set up (once).** Make an account at ollama.com, create an API key there (Settings → Keys), then Jarvis
menu → *Brain* → *Set Ollama API Key…*. The key goes in the Keychain behind Touch ID like the others.
The hosted model is billed by Ollama per use (about $0.15 per million input tokens and $0.60 per million
output at the time of writing), so the account needs credit.

**How the two work together** (menu → *Brain*, whose first line says who is answering right now):

- *Claude first* (default): Claude answers. If Claude cannot (no key, the daily budget is used up, the
  service is down or rate-limited), gpt-oss answers that request instead, by itself.
- *gpt-oss first*: the other way round.
- Without an Ollama key nothing changes: Jarvis behaves exactly as before.

**What is the same:** the tools, the permission tiers, approvals, Voice ID, logging.
**What gpt-oss does not have:** web search (that runs on Anthropic's side) and sight (no `look`).
**Private Mode and offline** never use it: a hosted model is still someone else's computer. Its requests
go to Ollama, which the *Privacy* menu shows once a key is set. Its cost is not counted by Jarvis's daily
budget; Ollama's own dashboard shows it.

Settings: `hostedModel` (`gpt-oss:120b`), `hostedBaseURL` (`https://ollama.com`).

