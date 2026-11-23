# Remote access: reaching Jarvis from your phone

Jarvis can be reached from anywhere over [Tailscale](https://tailscale.com), a private network between
your own devices. Nothing is opened to the public internet: no port forwarding, no public address, no
Tailscale Funnel. Free on Tailscale's Personal plan.

### Step 1: put the Mac and the phone on one tailnet (once, about five minutes)

**On the Mac**

1. Download the Standalone app, the variant Tailscale recommends:
   <https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg>. Open it and install.
2. Open Tailscale. Its onboarding asks to add a VPN configuration (and to allow its system extension);
   allow both. This is how the private network interface gets created.
3. Sign in (Google, Apple, GitHub, or Microsoft). That account is your tailnet.
4. Optional, for the checker below to show device names: Tailscale → Settings → *CLI integration* →
   *Show me how* → *Install Now*.

**On the phone**

1. Install Tailscale from the App Store or Play Store.
2. *Get Started*, allow the VPN configuration, and log in with the same account as the Mac.

**Check it**

```bash
scripts/tailscale-check.sh
```

It reports this Mac's private address (`100.x.y.z`), whether a phone is on the tailnet, and that Funnel
(the one Tailscale feature that publishes to the internet) is off. It changes nothing.

Things worth knowing:

- Tailscale must be on, on both devices, for the phone to reach the Mac. The Mac must be awake.
- Addresses in `100.64.0.0/10` are never routed on the public internet. Only devices signed in to your
  tailnet can reach them, over an encrypted WireGuard tunnel.
- Do not turn on Tailscale Funnel for anything Jarvis serves. Jarvis never does.

### Step 2: the remote API

A small HTTP API inside Jarvis that wraps the same pipeline as the microphone: it takes a recording (or
text), runs speech-to-text, Claude, the tools, and text-to-speech, and returns the reply as text and audio.
It is written in Swift and lives in the app (`Sources/JarvisCore/Remote/`), not in a separate Python
service, so it runs the real stages rather than a copy of them.

**Turning it on.** It is off until you switch it on, and even then it listens only when both of these are
true: at least one device has a token, and this Mac has a Tailscale address.

1. Jarvis menu → *Remote Access* → *Allow Remote Access over Tailscale*.
2. *Remote Access* → *Create Access Token…*, name the device ("Sam's iPhone"). The token is shown once.
   From a terminal: `build/Jarvis.app/Contents/MacOS/Jarvis --remote-token "Sam's iPhone"`
   (`--remote-tokens` lists them, `--remote-revoke <name>` removes one).

The menu's first line says where it is listening (`Listening on 100.x.y.z:8787`), or why it is not.

**Where it listens.** On this Mac's Tailscale address and nothing else: not `0.0.0.0`, not the Wi-Fi
address, not `localhost`. If Tailscale is off, it does not listen at all, and it follows Tailscale coming
and going. Connections from addresses outside the tailnet range are dropped before a byte is read. There
is no setting that makes it listen on every address (`remoteBind` accepts `tailscale` or `loopback`; anything
else means `tailscale`).

**The token.** Every request to the pipeline needs `Authorization: Bearer <token>`. Without a valid one the
answer is `401` for every path except the phone app's own static files, whether or not the path exists,
and the request body is not read. Five wrong tokens
in a minute from one device lock that device out for five minutes. Jarvis stores only a SHA-256 of each
token (`~/Library/Application Support/Jarvis/remote/tokens.json`, owner-only, on the tool denylist), so the
file does not let anyone in. Each device gets its own token; revoke one in the menu and it stops working
at once. Revoking the last one closes the port.

**Routes**

| | | |
|---|---|---|
| `GET /` | | The phone app (static files, no token). |
| `POST /v1/pair` | `{"code": "123456"}` | Trades the code on the Mac's screen for a token. Exists only while a code is showing. |
| `GET /v1/status` | | Is Jarvis there, is it busy, are the keys unlocked, is Voice ID set up. |
| `POST /v1/ask` | a recording (WAV or M4A, up to 60 s), or `{"text": "…"}` | Runs the request. |
| `POST /v1/approve?id=…` | a recording of "yes" or "no", or `{"id": "…", "decision": "yes"}` | Answers an approval. |

```bash
TOKEN=…   # from Create Access Token
MAC=100.x.y.z

curl -s -H "Authorization: Bearer $TOKEN" http://$MAC:8787/v1/status

curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"text": "what is left today?", "audio": false}' http://$MAC:8787/v1/ask

say -o ask.wav --data-format=LEI16@16000 "What is seven times eight?"
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: audio/wav' --data-binary @ask.wav http://$MAC:8787/v1/ask
```

A reply:

```json
{"status": "done", "request_id": "r-15778b", "transcript": "What is 7 times 8?",
 "text": "Seven times eight is fifty-six.", "tools": [],
 "audio": {"mime": "audio/wav", "base64": "UklGR…"}}
```

Add `?audio=0` (or `"audio": false`) to get text only. `409` means Jarvis is busy with another request;
`422` means nothing was heard.

**What a remote request can and cannot do**

- It is silent on the Mac: nothing is shown and nothing is spoken there. It is logged like any other
  request (`jarvis.log`, `trace.jsonl` with source `remote`, `actions.log`, `conversations.log`).
- One request at a time, shared with the Mac. If someone is talking to Jarvis at the Mac, a remote request
  gets `409`; while a remote request runs, the wake word waits.
- Everything that is free for a spoken request is free remotely. Everything on the Tier 3 list is refused,
  as always.
- **Anything that needs approval (email, messages, deleting, shell commands, money) needs your voice.**
  Nobody is at the Mac to press Approve, so the request must be a recording, Voice ID must be set up, and
  the voice must be yours. Then the reply is `"status": "needs_approval"` with the exact action, and the
  action waits (60 s) for `POST /v1/approve`. A typed request, an unrecognized voice, or a Mac without Voice
  ID gets a refusal instead, and the reply says why. There is no setting to relax this.
- After a restart the saved keys are locked until Touch ID (see *Keys*). A remote request then gets a
  reply saying so. If you want Jarvis to recover unattended, turn off *Keys → Require Touch ID to Unlock*.

### Step 3: the phone app

A web app with one big mic button, served by Jarvis itself: open the Mac's address in the phone's browser,
pair once, and optionally *Share → Add to Home Screen* to keep it as an app. No App Store, nothing hosted
anywhere else, no third-party scripts.

- **Tap** the mic, talk, and it stops by itself when you pause (or tap again). The reply is shown and spoken.
- **Type** in the field under the button instead, any time.
- **Approvals** appear as a card with the exact action and *Yes, do it* / *No*; you can also tap the mic
  and say yes or no. The rules above still apply: without a verified voice there is no card, only a refusal.
- **Call** (under the mic) starts a hands-free conversation: the microphone stays open, Jarvis listens
  again after every reply, and the screen stays on. It ends when you tap *Hang up*, say "bye" or "that's
  all", leave the app, or nobody speaks for 90 seconds. Jarvis does not listen while it is talking, so it
  cannot hear itself; tap the mic to cut a reply short. Approvals work the same way: it asks, you say yes
  or no.
- ••• opens settings: turn spoken replies off, or forget the pairing on this device.

**Pairing.** Jarvis menu → *Remote Access* → *Pair a Phone…*, name the phone. The Mac shows a six-digit
code for two minutes and the address to open. Type the code in the app; the phone gets its own token
(listed in the menu, revocable there) and the Mac flashes a notice, so a pairing never happens unnoticed.
A code works once; five wrong guesses cancel it. Outside those two minutes the pairing route does not
exist. The app's own files (a page, a script, a stylesheet, icons) are the only thing served without a
token; they are the same for everyone and hold no data.

**The microphone needs HTTPS.** Browsers only allow the microphone on `https://` pages. Over plain
`http://100.x.y.z:8787` the app works for typing, and says so. For the mic, let Tailscale put HTTPS in front:

1. In the [Tailscale admin console](https://console.tailscale.com/admin/dns) → DNS: enable *MagicDNS*, then
   under *HTTPS Certificates* choose *Enable HTTPS*.
   **Know before you click:** certificates are recorded in public transparency logs, so this Mac's name and
   your tailnet's name (`sams-macbook.tail1234.ts.net`) become publicly visible. Only the names: nothing
   becomes reachable from the internet. If the Mac's name says more than you like, rename it in the admin
   console first.
2. Tell Jarvis to listen on this Mac only, so that Tailscale is the one thing facing the tailnet. Add to
   `~/Library/Application Support/Jarvis/jarvis.env`, then restart Jarvis:

   ```
   JARVIS_REMOTE_BIND=loopback
   ```

3. Publish it to your tailnet (not the internet: that would be Funnel, which Jarvis never uses):

   ```bash
   tailscale serve --bg 8787
   ```

   It prints `Available within your tailnet: https://<mac>.<tailnet>.ts.net`. `tailscale serve status`
   shows it, `tailscale serve reset` turns it off. (If your version does not know `--bg`, see
   `tailscale serve --help`.)
4. On the phone, with Tailscale on, open that `https://` address and pair.

In this mode every request reaches Jarvis from `127.0.0.1`, so any program on the Mac can connect to the
port too (it still needs a token), and the wrong-token lockout is shared by all devices.

**What has and has not been tried.** In a desktop browser at phone size, against the running app:
pairing with a code, a typed request and its reply, decoding the spoken reply, and uploading audio made by
the page's recorder. The recorder's resampling and WAV encoding are tested under Node against the Mac's
decoder. Pairing was also run in an iPhone simulator over the real `https://` tailnet address, and call
mode was run for several turns against a simulated microphone. Not yet tried: a real phone's microphone,
Add to Home Screen, and the service worker (the test browser does not run service workers).

### "Hey Siri, Ask Jarvis"

A Siri shortcut for when opening the app is too much: lock screen, AirPods, CarPlay, Watch.

```bash
scripts/make-siri-shortcut.sh        # writes build/Ask Jarvis.shortcut
```

1. Jarvis menu → *Remote Access* → *Create Access Token…*, name it `Siri`, *Copy and Close*.
2. Double-click `build/Ask Jarvis.shortcut`, *Add Shortcut*, and paste the token when it asks.
3. Say "Hey Siri, Ask Jarvis", then your request. iCloud copies the shortcut to your iPhone by itself.

It dictates what you say (Apple's dictation, on the phone), sends the words to
`POST /v1/ask?format=text` on your Mac over the tailnet, and speaks the plain-text reply. The file holds
this Mac's tailnet address and no token. Because Siri sends words, not your voice, Jarvis cannot verify
who is speaking: anything that needs approval is refused through Siri, and says so. The phone must be on
Tailscale. Revoke the `Siri` token in the menu to switch it off.

### Later: a real app icon (Capacitor)

Not built. The pieces are in place so that wrapping the same web app in a native shell is packaging, not
a rewrite:

- **The web app is one self-contained folder**, `Sources/JarvisCore/Resources/WebApp/`: no build step, no
  dependencies. That folder is what Capacitor calls `webDir`.
- **It can be told where the Mac is.** Loaded from inside a native shell (`capacitor://localhost`) instead
  of from the Mac, the pairing screen shows one more field for the Mac's Tailscale address and every
  request goes there.
- **The API can admit that origin.** `remoteAllowedOrigins` (empty by default) lists exact extra web
  origins that may call the API from a browser, for example `capacitor://localhost,https://localhost`.
  A listed origin still needs a token for everything; `*` is never accepted.
- A native shell also removes the HTTPS requirement for the microphone, because the app's own pages are
  not `http://`.

When the time comes: `npm init @capacitor/app`, point `webDir` at that folder, add the iOS and Android
platforms, add the microphone usage string, and set `JARVIS_REMOTE_ALLOWED_ORIGINS`.

**Check it**

```bash
scripts/tailscale-check.sh      # “remote API is listening on 100.x.y.z:8787 and refuses requests without a token”
swift test --filter "Remote|HTTP|AudioCodec|Tailnet|WebApp|Pairing"   # API, tokens, server, audio, approvals, the phone app
```

Settings (`profile.json → tuning`, or `JARVIS_…` in `jarvis.env`): `remotePort` 8787, `remoteBind`
`tailscale`, `remoteMaxAudioSeconds` 60, `remoteApprovalTimeoutSeconds` 60, `remoteAllowedOrigins` empty.
