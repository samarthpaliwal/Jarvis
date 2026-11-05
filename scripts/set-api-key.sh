#!/bin/bash
# Stores the Anthropic API key from your clipboard into the Keychain item Jarvis reads.
# Copy the key first, then run this. Nothing is echoed or saved to shell history.
set -euo pipefail
KEY="$(pbpaste | tr -d '[:space:]')"
if [[ "$KEY" != sk-ant-* ]]; then
  echo "Clipboard doesn't look like an Anthropic key (expected sk-ant-…). Copy the key and try again." >&2
  exit 1
fi
security add-generic-password -U -s com.samarth.jarvis -a ANTHROPIC_API_KEY -w "$KEY"
echo "✓ API key saved to Keychain (com.samarth.jarvis / ANTHROPIC_API_KEY). Jarvis picks it up on the next request."
