#!/bin/bash
# Runs the tests and reports them by pipeline stage.
#
#   scripts/test.sh              everything, with a line per stage
#   scripts/test.sh wake         one stage: wake | stt | intent | actions | tts | pipeline | voiceid | remote | privacy | app
#   scripts/test.sh --list       which test classes belong to which stage
#
# No microphone, network, Keychain or real calendar is used: every stage runs against fakes.
set -uo pipefail
cd "$(dirname "$0")/.."
exec /usr/bin/python3 - "$@" <<'PY'
import re, subprocess, sys

STAGES = [
    ("wake",     "1 Wake word",          "WakeWordTests WakeConfigTests PhraseSpotterTests AudioRecoveryTests"),
    ("stt",      "2 Speech to text",     "EndpointerTests EchoGuardTests AudioCodecTests"),
    ("intent",   "3 Intent (Claude)",    "IntentStageTests ClaudeClientTests SSEParsingTests HistoryRepairTests AgenticChainTests OllamaShapeTests WebSearchTests SessionMemoryTests MemoryStoreTests LoopGuardTests BudgetTests RetryTests SkillLibraryTests HostedBrainTests"),
    ("actions",  "4 Actions (tools)",    "DispatcherTests DenylistGuardTests SecretRedactorTests InjectionScannerTests ToolTimeoutTests DeadlineTests CalendarToolsTests CalendarMatcherTests CameraToolTests GoogleSearchToolTests OpenWebsiteRulesTests OpenWebsiteToolTests LightsToolTests LightColorTests CameraFilesTests VisionTests LiveToolTests MusicTests ScreenTests ContactBookTests OrganizePlannerTests NotionParsingTests GmailParsingTests DateParsingTests BriefingLogicTests LoopbackListenerTests"),
    ("tts",      "5 Text to speech",     "SentenceChunkerTests SpeechQueueTests SpeechOutputTests VoicePickerTests KokoroTests VoiceTests"),
    ("pipeline", "Pipeline end to end",  "PipelineMachineTests PipelineStagesTests PipelineFailureTests SpokenFailureTests ConversationFlowTests LatencyTests TraceTests BudgetPipelineTests"),
    ("voiceid",  "Voice ID",             "VoiceCaptureTests VoiceGateRuleTests SentenceRecorderTests VoiceEnrollmentTests VoiceGatedApprovalTests VoiceMathTests SpeakerVerifierTests ECAPAModelTests"),
    ("remote",   "Remote access",        "TailnetTests HTTPParserTests HTTPServerTests RemoteTokenTests RemoteAPITests RemoteAccessServiceTests RemoteTurnTests WebAppTests PairingTests"),
    ("privacy",  "Privacy and keys",     "PrivacyTests RetentionTests SecretVaultTests"),
    ("app",      "App and settings",     "ConfigTests SettingsTests LenientConfigTests ModeScorerTests QuietHoursTests NotchGeometryTests SupervisorTests HangWatchdogTests StayAwakeTests"),
]
args = sys.argv[1:]
if args and args[0] == "--list":
    for key, title, classes in STAGES: print(f"{key:9} {title}\n          " + classes.replace(" ", ", "))
    sys.exit(0)
chosen = [s for s in STAGES if not args or s[0] in args]
if not chosen:
    sys.exit("Unknown stage. Use one of: " + " ".join(s[0] for s in STAGES))
cmd = ["swift", "test"]
if args: cmd += ["--filter", "|".join(c for s in chosen for c in s[2].split())]
print("▸ " + " ".join(cmd[:2]) + (" (" + ", ".join(s[0] for s in chosen) + ")" if args else ""), flush=True)
run = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
out = run.stdout
# "Test Suite 'X' passed at …" is followed by "Executed N tests, with F failures (… ) in S (…) seconds".
results = {}
for m in re.finditer(r"Test Suite '(\w+)' (passed|failed) at [^\n]*\n\s*Executed (\d+) tests?, with (\d+) failures?[^\n]*? in ([\d.]+)", out):
    results[m.group(1)] = (int(m.group(3)), int(m.group(4)), float(m.group(5)))
known = {c for s in STAGES for c in s[2].split()}
total = failed = 0
print()
for key, title, classes in chosen:
    n = f = 0; t = 0.0; missing = []
    for c in classes.split():
        if c in results: n += results[c][0]; f += results[c][1]; t += results[c][2]
        else: missing.append(c)
    total += n; failed += f
    mark = "✗" if f or (missing and run.returncode == 0 and not n) else "✓"
    print(f"  {mark} {title:22} {n:4} tests  {f} failed  {t:5.1f}s" + (f"   (not run: {', '.join(missing)})" if missing else ""))
other = sorted(c for c in results if c not in known and c not in ("JarvisCoreTests", "All", "Selected") and not c.endswith("xctest") and results[c][0])
if other and not args:
    n = sum(results[c][0] for c in other); f = sum(results[c][1] for c in other); total += n; failed += f
    print(f"  {'✗' if f else '✓'} {'Other':22} {n:4} tests  {f} failed          ({', '.join(other)})")
print(f"\n  {total} tests, {failed} failed")
if failed or run.returncode != 0:
    print()
    for line in out.splitlines():
        if re.search(r"error: -\[|: error: |Test Case .* failed|fatal error", line): print("  " + line[:300])
    if not failed: print("  swift test exited with", run.returncode, "— last lines:\n  " + "\n  ".join(out.splitlines()[-8:]))
    sys.exit(1)
PY
