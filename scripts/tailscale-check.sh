#!/bin/bash
# Checks the Tailscale side of Jarvis's remote access. Changes nothing.
#
#   scripts/tailscale-check.sh
#
# Tells you: is Tailscale installed, is it connected, what this Mac's private address and name are,
# whether your phone is on the same network, and that nothing is exposed to the public internet.
set -uo pipefail
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
note() { printf '    %s\n' "$1"; }
FAILED=0
APP="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

# The command-line tool: installed from the app's settings, or the one inside the app itself.
TS=()
if command -v tailscale >/dev/null 2>&1; then TS=(tailscale)
elif [ -x /usr/local/bin/tailscale ]; then TS=(/usr/local/bin/tailscale)
elif [ -x "$APP" ]; then TS=(env TAILSCALE_BE_CLI=1 "$APP")
fi

echo "Tailscale"
if [ -d /Applications/Tailscale.app ] || [ ${#TS[@]} -gt 0 ]; then ok "installed"
else
  bad "not installed"
  note "Download: https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg (see README → Remote access)"
  exit 1
fi

# The address on the tunnel interface. This is what Jarvis binds to; it needs no command-line tool.
IP="$(ifconfig 2>/dev/null | awk '/^utun[0-9]+:/{t=1;next} /^[a-z]/{t=0} t && $1=="inet" && $2 ~ /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./{print $2; exit}')"
if [ -n "$IP" ]; then ok "connected: this Mac is $IP on your tailnet"
else
  bad "not connected (no 100.x address on a tunnel interface)"
  note "Open Tailscale from the menu bar and turn it on, or sign in."
fi

if [ ${#TS[@]} -gt 0 ]; then
  JSON="$("${TS[@]}" status --json 2>/dev/null || true)"
  if [ -n "$JSON" ]; then
    printf '%s' "$JSON" | /usr/bin/python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
me = d.get("Self") or {}
name = (me.get("DNSName") or "").rstrip(".")
if name: print("    name: " + name)
peers = list((d.get("Peer") or {}).values())
phones = [p for p in peers if (p.get("OS") or "").lower() in ("ios", "android")]
print("    other devices on your tailnet: %d" % len(peers))
for p in peers[:12]:
    print("      - %s (%s)%s" % ((p.get("HostName") or "?"), (p.get("OS") or "?"), "" if p.get("Online") else " offline"))
print("  \033[32m✓\033[0m a phone is on the tailnet" if phones else "  \033[33m!\033[0m no phone on the tailnet yet: install Tailscale on it and sign in with the same account")
' || true
  else
    note "(could not read status from the tailscale command; the address check above is what matters)"
  fi
  # Funnel is the one Tailscale feature that publishes to the public internet. Jarvis never uses it.
  FUNNEL="$("${TS[@]}" funnel status 2>/dev/null || true)"
  if printf '%s' "$FUNNEL" | grep -qi "funnel on"; then
    bad "Tailscale Funnel is ON: something on this Mac is published to the public internet"
    printf '%s\n' "$FUNNEL" | sed 's/^/      /'
    note "Turn it off with: tailscale funnel reset"
  else
    ok "Funnel is off: nothing is published to the public internet"
  fi
else
  note "(the tailscale command is not installed; that is fine. Tailscale → Settings → CLI integration adds it.)"
fi

echo "Jarvis"
if [ -n "$IP" ]; then
  PORT="${JARVIS_REMOTE_PORT:-8787}"
  CODE="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://$IP:$PORT/v1/status" 2>/dev/null || true)"
  case "$CODE" in
    401) ok "remote API is listening on $IP:$PORT and refuses requests without a token" ;;
    000|"") note "remote API is not listening on $IP:$PORT (it is off until you turn it on: Jarvis menu → Remote Access)" ;;
    *) bad "remote API answered $CODE to a request without a token; it should answer 401" ;;
  esac
  # It must not answer on the ordinary network address.
  LAN="$(ipconfig getifaddr en0 2>/dev/null || true)"
  if [ -n "$LAN" ]; then
    CODE="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://$LAN:$PORT/v1/status" 2>/dev/null || true)"
    if [ "$CODE" = "000" ] || [ -z "$CODE" ]; then ok "nothing answers on the Wi-Fi address ($LAN:$PORT)"
    else bad "something answers on the Wi-Fi address $LAN:$PORT (HTTP $CODE). Jarvis only binds to the tailnet address; check what that is."; fi
  fi
fi
exit $FAILED
