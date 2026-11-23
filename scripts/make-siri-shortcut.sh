#!/bin/bash
# Builds "Ask Jarvis", a Siri shortcut: "Hey Siri, Ask Jarvis" → say your request → Siri speaks the answer.
#
#   scripts/make-siri-shortcut.sh            writes build/Ask Jarvis.shortcut
#
# The shortcut dictates what you say, sends the words to Jarvis on your Mac over your tailnet, and speaks
# the reply. It contains this Mac's tailnet address but no token: Shortcuts asks you to paste one when you
# add it. Add it on the Mac and iCloud puts it on your iPhone, Watch and CarPlay.
# Signing is done by Apple's `shortcuts sign`, which needs you to be signed in to iCloud.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/build"; mkdir -p "$OUT_DIR"
TS=""
for c in "$(command -v tailscale || true)" /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do [ -n "$c" ] && [ -x "$c" ] && { TS="$c"; break; }; done
NAME="${JARVIS_TAILNET_NAME:-}"
if [ -z "$NAME" ] && [ -n "$TS" ]; then
  NAME="$(TAILSCALE_BE_CLI=1 "$TS" status --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
fi
[ -n "$NAME" ] || { echo "✗ Could not find this Mac's Tailscale name. Is Tailscale on? (Or set JARVIS_TAILNET_NAME=your-mac.your-tailnet.ts.net)"; exit 1; }
URL="https://$NAME/v1/ask?format=text"
UNSIGNED="$OUT_DIR/ask-jarvis-unsigned.shortcut"
SIGNED="$OUT_DIR/Ask Jarvis.shortcut"

/usr/bin/python3 - "$URL" "$UNSIGNED" <<'PY'
import plistlib, sys, uuid
url, out = sys.argv[1], sys.argv[2]
token_id, heard_id, reply_id = (str(uuid.uuid4()).upper() for _ in range(3))
def text(s): return {"Value": {"string": s}, "WFSerializationType": "WFTextTokenString"}
def output(name, ident): return {"OutputName": name, "OutputUUID": ident, "Type": "ActionOutput"}
actions = [
    # 0: the access token. Filled in by the question Shortcuts asks when the shortcut is added.
    {"WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
     "WFWorkflowActionParameters": {"UUID": token_id, "CustomOutputName": "Token", "WFTextActionText": ""}},
    # 1: listen.
    {"WFWorkflowActionIdentifier": "is.workflow.actions.dictatetext",
     "WFWorkflowActionParameters": {"UUID": heard_id, "CustomOutputName": "Request"}},
    # 2: send the words to Jarvis.
    {"WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
     "WFWorkflowActionParameters": {
         "UUID": reply_id, "CustomOutputName": "Reply", "WFURL": url, "WFHTTPMethod": "POST", "ShowHeaders": True,
         "WFHTTPHeaders": {"WFSerializationType": "WFDictionaryFieldValue", "Value": {"WFDictionaryFieldValueItems": [
             {"WFItemType": 0, "WFKey": text("Authorization"),
              "WFValue": {"WFSerializationType": "WFTextTokenString",
                          "Value": {"string": "Bearer ￼", "attachmentsByRange": {"{7, 1}": output("Token", token_id)}}}},
             {"WFItemType": 0, "WFKey": text("Content-Type"), "WFValue": text("text/plain; charset=utf-8")},
         ]}},
         "WFHTTPBodyType": "File",
         "WFRequestVariable": {"WFSerializationType": "WFTextTokenAttachment", "Value": output("Request", heard_id)},
     }},
    # 3: say the answer.
    {"WFWorkflowActionIdentifier": "is.workflow.actions.speaktext",
     "WFWorkflowActionParameters": {"WFText": {"WFSerializationType": "WFTextTokenString",
                                               "Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": output("Reply", reply_id)}}}}},
]
workflow = {
    "WFWorkflowName": "Ask Jarvis",
    "WFWorkflowActions": actions,
    "WFWorkflowClientVersion": "2607.0.2", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59771},
    "WFWorkflowTypes": [], "WFWorkflowInputContentItemClasses": [], "WFWorkflowHasShortcutInputVariables": False,
    "WFWorkflowImportQuestions": [{"ActionIndex": 0, "Category": "Parameter", "ParameterKey": "WFTextActionText", "DefaultValue": "",
                                   "Text": "Paste the access token for Siri (Jarvis menu → Remote Access → Create Access Token…)."}],
}
with open(out, "wb") as f: plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)
PY

if shortcuts sign --mode people-who-know-me --input "$UNSIGNED" --output "$SIGNED" 2>"$OUT_DIR/shortcut-sign.log"; then
  echo "✓ $SIGNED"
  echo "  Sends to: $URL"
  echo "  Next: 1) Jarvis menu → Remote Access → Create Access Token…, name it Siri, Copy and Close."
  echo "        2) Double-click the file above, Add Shortcut, paste the token when asked."
  echo "        3) Say “Hey Siri, Ask Jarvis”. iCloud brings the shortcut to your iPhone by itself."
else
  echo "✗ Apple's signing step failed:"; sed 's/^/    /' "$OUT_DIR/shortcut-sign.log" | head -8
  echo "  (It needs iCloud to be signed in on this Mac, and a network connection.)"
  exit 1
fi
