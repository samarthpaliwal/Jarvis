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
  const TOKEN_KEY = "jarvis.token", SPEAK_KEY = "jarvis.speak";

  const store = {
    get(key) { try { return localStorage.getItem(key); } catch { return null; } },
    set(key, value) { try { value === null ? localStorage.removeItem(key) : localStorage.setItem(key, value); } catch { /* private mode */ } },
  };
  let token = store.get(TOKEN_KEY);
  let device = "";
  let pendingApproval = null;
  let audioContext = null, playing = null, recorder = null;
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
    try { response = await fetch(path, { method, headers, body, cache: "no-store", credentials: "omit" }); }
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
  const idleHint = () => (canRecord ? "Tap to talk" : "The microphone needs HTTPS here. Type instead.");

  function unpair(message) {
    token = null; store.set(TOKEN_KEY, null);
    pendingApproval = null;
    setLink("down", "Not paired");
    $("pair-error").textContent = message || "";
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

  $("pair-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const entered = $("pair-code").value.trim();
    $("pair-error").textContent = "";
    if (!entered) return;
    try {
      if (/^jrv_[A-Za-z0-9_-]{20,}$/.test(entered)) {
        token = entered;                       // a token made with "Create Access Token…"
        await api("v1/status");
      } else {
        const code = entered.replace(/\D/g, "");
        if (code.length !== 6) { $("pair-error").textContent = "The code has six digits."; return; }
        const paired = await api("v1/pair", { method: "POST", body: JSON.stringify({ code }), type: "application/json", auth: false });
        token = paired.token;
      }
      store.set(TOKEN_KEY, token);
      $("pair-code").value = "";
      setState("loading");
      await refreshStatus();
    } catch (e) {
      token = null;
      $("pair-error").textContent = e.status === 401 ? "That code isn't right, or it has expired." : e.message;
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
    if (result.audio && result.audio.base64) await play(result.audio.base64);
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
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
    const source = ctx.createMediaStreamSource(stream);
    const node = ctx.createScriptProcessor(4096, 1, 1);
    const mute = ctx.createGain();
    mute.gain.value = 0;                      // the graph must reach the output to run; this keeps it silent
    const chunks = [];
    const verdict = JarvisAudio.endpointer(pendingApproval ? { pauseSeconds: 0.9, noSpeechSeconds: 6, maxSeconds: 8 } : {});
    recorder = {
      stop(send) {
        if (recorder !== this) return;
        recorder = null;
        node.onaudioprocess = null;
        try { source.disconnect(); node.disconnect(); mute.disconnect(); } catch { /* fine */ }
        stream.getTracks().forEach((t) => t.stop());
        $("ring").style.removeProperty("--level");
        if (!send) return setState("idle", pendingApproval ? "Yes or no?" : idleHint());
        const samples = JarvisAudio.downsample(JarvisAudio.merge(chunks), ctx.sampleRate);
        if (samples.length < JarvisAudio.TARGET_RATE * 0.3) return setState("idle", idleHint());
        sendRecording(JarvisAudio.wav(samples));
      },
    };
    const mine = recorder;
    node.onaudioprocess = (event) => {
      const data = new Float32Array(event.inputBuffer.getChannelData(0));
      chunks.push(data);
      const level = JarvisAudio.rms(data);
      $("ring").style.setProperty("--level", String(1 + Math.min(0.35, level * 4)));
      const v = verdict(level, data.length / ctx.sampleRate);
      if (v === "done" || v === "limit") mine.stop(true);
      else if (v === "nothing") { mine.stop(false); $("reply").textContent = "I didn't catch anything."; }
    };
    source.connect(node); node.connect(mute); mute.connect(ctx.destination);
    $("reply").classList.remove("failed");
    if (!pendingApproval) { $("heard").textContent = ""; $("reply").textContent = ""; }
    setState("listening", "Listening… tap when you're done");
  }

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

  // ---- Settings sheet ----

  $("menu").addEventListener("click", () => {
    $("device-line").textContent = token ? "Paired as “" + (device || "this device") + "”." : "Not paired.";
    const standalone = window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
    $("install-line").textContent = standalone ? "" : "Tip: use Share → Add to Home Screen to keep Jarvis as an app. You will pair once more there.";
    $("speak-toggle").checked = wantsSpeech();
    $("sheet").showModal();
  });
  $("speak-toggle").addEventListener("change", (e) => store.set(SPEAK_KEY, e.target.checked ? "1" : "0"));
  $("close-sheet").addEventListener("click", () => $("sheet").close());
  $("forget").addEventListener("click", () => { $("sheet").close(); unpair("Forgotten on this device. To block it for good, revoke it in the Jarvis menu on the Mac."); });

  // ---- Start ----

  document.addEventListener("visibilitychange", () => { if (!document.hidden && token && app.dataset.state !== "thinking" && app.dataset.state !== "listening") refreshStatus(); });
  if ("serviceWorker" in navigator && window.isSecureContext) navigator.serviceWorker.register("sw.js").catch(() => {});
  refreshStatus();
})();
