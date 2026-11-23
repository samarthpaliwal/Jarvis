// Jarvis remote: one mic button. Records a request, sends it to the Mac over the tailnet, shows and plays the reply.
// No frameworks, no third-party requests. Everything goes to the origin this page was loaded from.
"use strict";

// ---- Audio helpers (pure; also loaded by the tests under Node) ------------------------------------------------

const JarvisAudio = {
  TARGET_RATE: 16000,

  /** Joins recorded chunks into one Float32Array. */
  merge(chunks) {
    const out = new Float32Array(chunks.reduce((n, c) => n + c.length, 0));
    let at = 0;
    for (const c of chunks) { out.set(c, at); at += c.length; }
    return out;
  },

  /** Resamples to 16 kHz by averaging each output sample's span of input (a box filter: fine for speech). */
  downsample(samples, fromRate, toRate = JarvisAudio.TARGET_RATE) {
    if (fromRate === toRate) return samples;
    if (fromRate < toRate) throw new Error("cannot upsample " + fromRate + " Hz audio");
    const ratio = fromRate / toRate;
    const out = new Float32Array(Math.floor(samples.length / ratio));
    for (let i = 0; i < out.length; i++) {
      const start = Math.floor(i * ratio), end = Math.min(samples.length, Math.floor((i + 1) * ratio));
      let sum = 0;
      for (let j = start; j < end; j++) sum += samples[j];
      out[i] = end > start ? sum / (end - start) : 0;
    }
    return out;
  },

  /** 16-bit mono WAV. */
  wav(samples, rate = JarvisAudio.TARGET_RATE) {
    const buffer = new ArrayBuffer(44 + samples.length * 2);
    const v = new DataView(buffer);
    const text = (at, s) => { for (let i = 0; i < s.length; i++) v.setUint8(at + i, s.charCodeAt(i)); };
    text(0, "RIFF"); v.setUint32(4, 36 + samples.length * 2, true); text(8, "WAVE");
    text(12, "fmt "); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
    text(36, "data"); v.setUint32(40, samples.length * 2, true);
    for (let i = 0; i < samples.length; i++) {
      const s = Math.max(-1, Math.min(1, samples[i]));
      v.setInt16(44 + i * 2, Math.round(s * 32767), true);
    }
    return buffer;
  },

  rms(samples) {
    let sum = 0;
    for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
    return samples.length ? Math.sqrt(sum / samples.length) : 0;
  },

  /**
   * Decides when a recording is over. Feed it the loudness of each chunk and how long the chunk was.
   * Returns "continue", "done" (speech, then a pause), "nothing" (nobody spoke), or "limit".
   */
  endpointer({ speechLevel = 0.02, quietLevel = 0.012, pauseSeconds = 1.4, noSpeechSeconds = 7, maxSeconds = 30 } = {}) {
    let total = 0, quiet = 0, spoke = false;
    return (level, seconds) => {
      total += seconds;
      if (level >= speechLevel) { spoke = true; quiet = 0; }
      else if (level < quietLevel) quiet += seconds;
      if (total >= maxSeconds) return "limit";
      if (spoke && quiet >= pauseSeconds) return "done";
      if (!spoke && total >= noSpeechSeconds) return "nothing";
      return "continue";
    };
  },

  /** A short "that's it" that ends a call: "bye", "goodbye Jarvis", "hang up", "that's all". */
  isGoodbye(text) {
    const words = String(text || "").toLowerCase().replace(/[^a-z' ]/g, " ").split(/\s+/).filter(Boolean);
    if (!words.length || words.length > 4) return false;
    const said = words.join(" ").replace(/'/g, "");
    return ["bye", "goodbye", "hang up", "thats all", "end call", "end the call"].some((p) => said === p || said.startsWith(p + " ") || said.endsWith(" " + p));
  },

  base64ToBytes(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  },
};

if (typeof module !== "undefined" && module.exports) module.exports = JarvisAudio;

// ---- The app (browser only) ------------------------------------------------------------------------------------

if (typeof document !== "undefined") (() => {
  const $ = (id) => document.getElementById(id);
  const app = $("app");
  const TOKEN_KEY = "jarvis.token", SPEAK_KEY = "jarvis.speak", SERVER_KEY = "jarvis.server";

  const store = {
    get(key) { try { return localStorage.getItem(key); } catch { return null; } },
    set(key, value) { try { value === null ? localStorage.removeItem(key) : localStorage.setItem(key, value); } catch { /* private mode */ } },
  };
  let token = store.get(TOKEN_KEY);
  // Hook for a native wrapper (Capacitor): there these files load from inside the app, not from the Mac, so the
  // app has to be told where the Mac is. Served by Jarvis itself, `server` stays empty and everything is same-origin.
  const wrapped = location.protocol === "capacitor:" || location.protocol === "file:" || typeof window.Capacitor !== "undefined";
  let server = wrapped ? (store.get(SERVER_KEY) || "") : "";
  const normalizeServer = (raw) => {
    let s = raw.trim();
    if (!s) return "";
    if (!/^https?:\/\//i.test(s)) s = "https://" + s;
    return s.endsWith("/") ? s : s + "/";
  };
  let device = "";
  let pendingApproval = null;
  let audioContext = null, playing = null, recorder = null;
  // A call: the microphone stays open and Jarvis listens again after every reply, until you hang up.
  let call = null;
  let hungUpWhileThinking = false;
  const CALL_QUIET_LIMIT = 90;             // seconds of nobody speaking before the call ends by itself
  const canRecord = !!(window.isSecureContext && navigator.mediaDevices && navigator.mediaDevices.getUserMedia);

  // ---- Talking to the Mac ----

  class ApiError extends Error {
    constructor(status, code, message) { super(message); this.status = status; this.code = code; }
  }

  async function api(path, { method = "GET", body, type, auth = true } = {}) {
    const headers = {};
    if (auth) headers.Authorization = "Bearer " + token;
    if (type) headers["Content-Type"] = type;
    let response;
    try { response = await fetch(server + path, { method, headers, body, cache: "no-store", credentials: "omit" }); }
    catch { throw new ApiError(0, "unreachable", "Can't reach your Mac. Is Tailscale on, and is the Mac awake?"); }
    let data = {};
    try { data = await response.json(); } catch { /* not JSON */ }
    if (!response.ok) throw new ApiError(response.status, data.error || "error", data.message || ("The Mac answered " + response.status + "."));
    return data;
  }

  // ---- Screens ----

  function show(screen) {
    $("pair").hidden = screen !== "pair";
    $("talk").hidden = screen !== "talk";
  }
  function setState(state, hint) {
    app.dataset.state = state;
    if (hint !== undefined) $("hint").textContent = hint;
  }
  function setLink(kind, text) { app.dataset.link = kind; $("status").textContent = text; }
  const idleHint = () => (call ? "On a call" : canRecord ? "Tap to talk" : "The microphone needs HTTPS here. Type instead.");

  function unpair(message) {
    token = null; store.set(TOKEN_KEY, null);
    pendingApproval = null;
    if (call) endCall();
    setLink("down", "Not paired");
    $("pair-error").textContent = message || "";
    $("pair-server").hidden = !wrapped;
    if (wrapped && server) $("pair-server").value = server;
    show("pair");
    $("pair-code").focus();
  }

  async function refreshStatus() {
    if (!token) return unpair();
    try {
      const s = await api("v1/status");
      device = s.device || "";
      if (!s.keys_unlocked) setLink("locked", "Jarvis is locked: unlock it with Touch ID at the Mac");
      else if (s.busy) setLink("busy", "Jarvis is busy");
      else setLink("ok", "Connected" + (s.voice_id ? "" : " · Voice ID is not set up"));
      show("talk");
      if (app.dataset.state === "loading") setState("idle", idleHint());
    } catch (e) {
      if (e.status === 401) return unpair("This device is no longer paired.");
      setLink("down", e.status === 429 ? "Too many attempts. Wait a few minutes." : e.message);
      show("talk");
      if (app.dataset.state === "loading") setState("idle", idleHint());
    }
  }

  // ---- Pairing ----

  let pairingNow = false;
  $("pair-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (pairingNow) return;                    // one attempt at a time: a second tap must not undo the first
    const entered = $("pair-code").value.trim();
    $("pair-error").textContent = "";
    if (!entered) return;
    let target = server;
    if (wrapped) {
      target = normalizeServer($("pair-server").value);
      if (!target) { $("pair-error").textContent = "Enter your Mac's Tailscale address first."; return; }
    }
    const button = $("pair-form").querySelector("button");
    const previous = { token, server };
    pairingNow = true; button.disabled = true; button.textContent = "Pairing…";
    try {
      server = target;
      let candidate;
      if (/^jrv_[A-Za-z0-9_-]{20,}$/.test(entered)) {
        candidate = entered;                   // a token made with "Create Access Token…"
        token = candidate;
        await api("v1/status");
      } else {
        const code = entered.replace(/\D/g, "");
        if (code.length !== 6) { $("pair-error").textContent = "The code has six digits."; return; }
        candidate = (await api("v1/pair", { method: "POST", body: JSON.stringify({ code }), type: "application/json", auth: false })).token;
        if (!candidate) throw new ApiError(0, "pairing_failed", "Pairing failed. Try again from the Mac.");
        token = candidate;
      }
      // Saved before anything else can fail, and never taken back by a later failed attempt.
      store.set(TOKEN_KEY, token);
      if (wrapped) store.set(SERVER_KEY, server);
      $("pair-code").value = "";
      setLink("ok", "Paired");
      show("talk");
      setState("idle", idleHint());
      refreshStatus();
    } catch (e) {
      token = previous.token; server = previous.server;
      $("pair-error").textContent = e.status === 401 ? "That code isn't right, or it has expired. Get a new one on the Mac." : e.message;
    } finally {
      pairingNow = false; button.disabled = false; button.textContent = "Pair";
    }
  });

  // ---- Showing a reply ----

  async function showResult(result) {
    if (result.transcript) $("heard").textContent = result.transcript;
    $("reply").textContent = result.text || "";
    $("reply").classList.toggle("failed", !!result.failed);
    if (result.status === "needs_approval" && result.approval) {
      pendingApproval = result.approval;
      $("approval-text").textContent = result.approval.prompt;
      $("approval").hidden = false;
    } else {
      pendingApproval = null;
      $("approval").hidden = true;
    }
    if (call && !pendingApproval && JarvisAudio.isGoodbye(result.transcript)) call.ending = true;
    // Hung up while Jarvis was still thinking: show the answer, but do not start talking after the call is over.
    const silenced = hungUpWhileThinking;
    hungUpWhileThinking = false;
    if (!silenced && result.audio && result.audio.base64) await play(result.audio.base64);
    setState("idle", pendingApproval ? "Yes or no?" : idleHint());
  }

  function showError(e) {
    if (e.status === 401) return unpair("This device is no longer paired.");
    $("reply").textContent = e.code === "no_speech" ? "I didn't catch anything." : e.message;
    $("reply").classList.add("failed");
    setState("idle", idleHint());
  }

  const wantsSpeech = () => store.get(SPEAK_KEY) !== "0";
  const askPath = () => "v1/ask" + (wantsSpeech() ? "" : "?audio=0");

  async function sendRecording(wav) {
    setState("thinking", "Thinking…");
    try {
      if (pendingApproval) {
        const id = pendingApproval.id;
        await showResult(await api("v1/approve?id=" + encodeURIComponent(id) + (wantsSpeech() ? "" : "&audio=0"), { method: "POST", body: wav, type: "audio/wav" }));
      } else {
        await showResult(await api(askPath(), { method: "POST", body: wav, type: "audio/wav" }));
      }
    } catch (e) {
      if (pendingApproval && e.status === 410) { pendingApproval = null; $("approval").hidden = true; }
      if (pendingApproval && e.status === 422) { $("reply").textContent = e.message; return setState("idle", "Yes or no?"); }
      showError(e);
    }
  }

  async function sendText(text) {
    stopPlaying();
    $("heard").textContent = text; $("reply").textContent = ""; $("reply").classList.remove("failed");
    setState("thinking", "Thinking…");
    try { await showResult(await api("v1/ask", { method: "POST", body: JSON.stringify({ text, audio: wantsSpeech() }), type: "application/json" })); }
    catch (e) { showError(e); }
  }

  async function decide(decision) {
    if (!pendingApproval) return;
    const id = pendingApproval.id;
    stopPlaying();
    setState("thinking", decision === "yes" ? "Doing it…" : "Cancelling…");
    try { await showResult(await api("v1/approve", { method: "POST", body: JSON.stringify({ id, decision, audio: wantsSpeech() }), type: "application/json" })); }
    catch (e) { pendingApproval = null; $("approval").hidden = true; showError(e); }
  }

  // ---- Audio: one context for recording and for playing, started by the tap ----

  function context() {
    if (!audioContext) audioContext = new (window.AudioContext || window.webkitAudioContext)();
    return audioContext;
  }

  function stopPlaying() {
    if (playing) { try { playing.stop(); } catch { /* already stopped */ } playing = null; }
  }

  async function play(base64) {
    try {
      const ctx = context();
      await ctx.resume();
      const bytes = JarvisAudio.base64ToBytes(base64);
      const buffer = await new Promise((resolve, reject) => ctx.decodeAudioData(bytes.buffer, resolve, reject));
      stopPlaying();
      const source = ctx.createBufferSource();
      source.buffer = buffer;
      source.connect(ctx.destination);
      playing = source;
      setState("speaking", "Tap to stop");
      await new Promise((resolve) => { source.onended = resolve; source.start(); });
      if (playing === source) playing = null;
    } catch { /* the words are on screen either way */ }
  }

  async function startRecording() {
    const ctx = context();
    await ctx.resume();
    const inCall = call;
    const stream = inCall ? inCall.stream : await openMicrophone();
    const source = ctx.createMediaStreamSource(stream);
    const node = ctx.createScriptProcessor(4096, 1, 1);
    const mute = ctx.createGain();
    mute.gain.value = 0;                      // the graph must reach the output to run; this keeps it silent
    const chunks = [];
    const verdict = JarvisAudio.endpointer(pendingApproval ? { pauseSeconds: 0.9, noSpeechSeconds: 6, maxSeconds: 8 }
      : inCall ? { pauseSeconds: 1.1, noSpeechSeconds: 10, maxSeconds: 30 } : {});
    let seconds = 0;
    recorder = {
      stop(send) {
        if (recorder !== this) return;
        recorder = null;
        node.onaudioprocess = null;
        try { source.disconnect(); node.disconnect(); mute.disconnect(); } catch { /* fine */ }
        if (!inCall) stream.getTracks().forEach((t) => t.stop());      // a call keeps its microphone
        $("ring").style.removeProperty("--level");
        if (!send) {
          if (inCall && call === inCall) inCall.quiet += seconds;
          setState("idle", pendingApproval ? "Yes or no?" : idleHint());
          return callNext(inCall);
        }
        const samples = JarvisAudio.downsample(JarvisAudio.merge(chunks), ctx.sampleRate);
        if (samples.length < JarvisAudio.TARGET_RATE * 0.3) { setState("idle", idleHint()); return callNext(inCall); }
        if (inCall) inCall.quiet = 0;
        sendRecording(JarvisAudio.wav(samples)).then(() => callNext(inCall));
      },
    };
    const mine = recorder;
    node.onaudioprocess = (event) => {
      const data = new Float32Array(event.inputBuffer.getChannelData(0));
      chunks.push(data);
      const level = JarvisAudio.rms(data);
      $("ring").style.setProperty("--level", String(1 + Math.min(0.35, level * 4)));
      seconds += data.length / ctx.sampleRate;
      const v = verdict(level, data.length / ctx.sampleRate);
      if (v === "done" || v === "limit") mine.stop(true);
      else if (v === "nothing") { if (!inCall) $("reply").textContent = "I didn't catch anything."; mine.stop(false); }
    };
    source.connect(node); node.connect(mute); mute.connect(ctx.destination);
    $("reply").classList.remove("failed");
    if (!pendingApproval && !inCall) { $("heard").textContent = ""; $("reply").textContent = ""; }
    setState("listening", inCall ? "On a call · listening" : "Listening… tap when you're done");
  }

  function openMicrophone() {
    return navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
  }

  // ---- Call mode: hands-free, turn after turn ----

  /** After a reply (or a silence) on a call: listen again, or end the call if it is over. */
  function callNext(inCall) {
    if (!inCall || call !== inCall) return;
    if (inCall.ending) return endCall("Call ended.");
    if (inCall.quiet >= CALL_QUIET_LIMIT) return endCall("Call ended: nobody spoke for a while.");
    if (!token) return endCall();
    // A beat of silence first, so the tail of Jarvis's own voice is not taken for yours.
    setTimeout(() => {
      if (call !== inCall || recorder || app.dataset.state !== "idle") return;
      startRecording().catch(() => endCall("The microphone stopped. Call ended."));
    }, 350);
  }

  async function startCall() {
    if (call || !canRecord || app.dataset.state === "thinking") return;
    stopPlaying();
    if (recorder) recorder.stop(false);
    try {
      const ctx = context();
      await ctx.resume();
      const stream = await openMicrophone();
      call = { stream, quiet: 0, ending: false, wakeLock: null };
      // Keep the screen on for the length of the call, where the browser can.
      try { if (navigator.wakeLock) call.wakeLock = await navigator.wakeLock.request("screen"); } catch { /* not allowed: fine */ }
      app.dataset.call = "on";
      $("call").textContent = "Hang up";
      $("heard").textContent = ""; $("reply").textContent = "";
      await startRecording();
    } catch (e) {
      const denied = e && (e.name === "NotAllowedError" || e.name === "SecurityError");
      endCall(denied ? "Allow the microphone for this site, then call again." : "The microphone isn't available.");
    }
  }

  function endCall(message) {
    const ended = call;
    call = null;
    delete app.dataset.call;
    $("call").textContent = "Call";
    if (recorder) recorder.stop(false);
    stopPlaying();
    if (ended) {
      ended.stream.getTracks().forEach((t) => t.stop());
      try { if (ended.wakeLock) ended.wakeLock.release(); } catch { /* already released */ }
    }
    if (app.dataset.state !== "thinking") setState("idle", message || idleHint());
    else { hungUpWhileThinking = !!ended; if (message) $("hint").textContent = message; }
  }

  $("call").addEventListener("click", () => (call ? endCall("Call ended.") : startCall()));
  $("call").hidden = !canRecord;

  $("mic").addEventListener("click", async () => {
    const state = app.dataset.state;
    if (state === "listening") return recorder && recorder.stop(true);
    if (state === "speaking") { stopPlaying(); return; }
    if (state === "thinking") return;
    if (!canRecord) { $("type-text").focus(); return setState("idle", idleHint()); }
    try { await startRecording(); }
    catch (e) {
      const denied = e && (e.name === "NotAllowedError" || e.name === "SecurityError");
      setState("idle", denied ? "Allow the microphone for this site, then tap again." : "The microphone isn't available.");
    }
  });

  $("type-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const text = $("type-text").value.trim();
    if (!text || app.dataset.state === "thinking" || app.dataset.state === "listening") return;
    $("type-text").value = ""; $("type-text").blur();
    pendingApproval = null; $("approval").hidden = true;
    sendText(text);
  });
  $("approve").addEventListener("click", () => decide("yes"));
  $("deny").addEventListener("click", () => decide("no"));

  // ---- Check-in: Jarvis asks which mode, and whether anyone is there ----

  let checkin = null, pickedMode = null, pickedPeople = null;

  function renderCheckin() {
    $("checkin").hidden = !checkin;
    if (!checkin) return;
    $("checkin-text").textContent = checkin.text;
    const box = $("checkin-modes");
    box.textContent = "";
    for (const m of checkin.modes) {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = m.name;
      b.className = "secondary" + ((pickedMode || checkin.current) === m.id ? " chosen" : "");
      b.addEventListener("click", () => { pickedMode = m.id; renderCheckin(); });
      box.appendChild(b);
    }
    $("people-no").classList.toggle("chosen", pickedPeople === false);
    $("people-yes").classList.toggle("chosen", pickedPeople === true);
  }

  async function loadCheckin() {
    if (!token) return;
    try {
      const r = await api("v1/checkin");
      const q = r.question || null;
      if ((q && q.id) !== (checkin && checkin.id)) { pickedMode = null; pickedPeople = null; }
      checkin = q;
    } catch { /* an older Jarvis, or unreachable: no question to show */ }
    renderCheckin();
  }

  $("people-no").addEventListener("click", () => { pickedPeople = false; renderCheckin(); });
  $("people-yes").addEventListener("click", () => { pickedPeople = true; renderCheckin(); });
  $("checkin-skip").addEventListener("click", () => { checkin = null; renderCheckin(); });
  $("checkin-send").addEventListener("click", async () => {
    if (!checkin) return;
    const body = { id: checkin.id };
    if (pickedMode) body.mode = pickedMode;
    if (pickedPeople !== null) body.people = pickedPeople;
    try {
      const r = await api("v1/checkin", { method: "POST", body: JSON.stringify(body), type: "application/json" });
      $("reply").textContent = r.reply || "Got it.";
    } catch (e) { $("reply").textContent = e.status === 409 ? "That question has expired." : e.message; }
    checkin = null;
    renderCheckin();
  });

  // ---- Notifications ----

  const canNotify = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window && window.isSecureContext;
  const keyBytes = (b64) => {
    const s = atob(b64.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((b64.length + 3) % 4));
    return Uint8Array.from(s, (c) => c.charCodeAt(0));
  };

  async function notifyState() {
    if (!canNotify) return "unsupported";
    if (Notification.permission === "denied") return "denied";
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = reg && (await reg.pushManager.getSubscription());
    return sub && Notification.permission === "granted" ? "on" : "off";
  }

  async function showNotifyState() {
    const state = await notifyState().catch(() => "unsupported");
    $("notify").hidden = state !== "off" || !token;
    $("notify-line").textContent =
      state === "on" ? "Notifications are on for this device." :
      state === "denied" ? "Notifications are blocked for Jarvis in this phone's Settings." :
      state === "unsupported" ? "For notifications, add Jarvis to the Home Screen and open it from there." : "";
  }

  // Must run from a tap: phones only show the permission question in answer to one.
  $("notify").addEventListener("click", async () => {
    try {
      if ((await Notification.requestPermission()) !== "granted") return showNotifyState();
      const { key } = await api("v1/push/key");
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(key) });
      await api("v1/push/subscribe", { method: "POST", body: JSON.stringify(sub.toJSON()), type: "application/json" });
      $("notify-line").textContent = "Notifications are on for this device.";
      $("notify").hidden = true;
    } catch (e) { $("notify-line").textContent = "Couldn't turn notifications on: " + (e.message || e); }
  });

  // ---- Settings sheet ----

  $("menu").addEventListener("click", () => {
    $("device-line").textContent = token ? "Paired as “" + (device || "this device") + "”." : "Not paired.";
    const standalone = window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
    $("install-line").textContent = standalone ? "" : "Tip: use Share → Add to Home Screen to keep Jarvis as an app. You will pair once more there.";
    $("speak-toggle").checked = wantsSpeech();
    showNotifyState();
    $("sheet").showModal();
  });
  $("speak-toggle").addEventListener("change", (e) => store.set(SPEAK_KEY, e.target.checked ? "1" : "0"));
  $("close-sheet").addEventListener("click", () => $("sheet").close());
  $("forget").addEventListener("click", () => { $("sheet").close(); unpair("Forgotten on this device. To block it for good, revoke it in the Jarvis menu on the Mac."); });

  // ---- Start ----

  document.addEventListener("visibilitychange", () => { if (document.hidden && call) endCall("Call ended: the app went to the background."); });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && token && app.dataset.state !== "thinking" && app.dataset.state !== "listening") { refreshStatus(); loadCheckin(); } });
  if ("serviceWorker" in navigator && window.isSecureContext) navigator.serviceWorker.register("sw.js").catch(() => {});
  refreshStatus();
  loadCheckin();
})();
