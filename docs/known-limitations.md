# Known limitations

- Gmail and Notion were built against the API docs but not exercised live (no tokens on this Mac during development). Parsers are unit-tested; errors are spoken and logged.
- Brightness uses a private framework and works on the built-in display only. Focus needs the Shortcuts above.
- Call detection is heuristic (camera in use or a call app running). A browser-only Meet call with the camera off is not detected.
- Idle CPU with the wake word is 3–4 % in `top`, just above the 3 % target; the embedding model is the floor.
- Ad-hoc signing re-prompts for permissions after every rebuild; `scripts/make-dev-cert.sh` fixes that. Saved keys are unlocked with Touch ID through `jarvis-keyhelper` and no longer depend on the signature.
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
