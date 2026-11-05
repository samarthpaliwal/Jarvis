#!/bin/bash
# Creates a self-signed "Jarvis Dev" code-signing identity in your login Keychain so every build
# has the SAME signature: macOS then remembers Microphone/Calendar/Keychain grants across rebuilds.
# You will be asked for your login password by Keychain once or twice. Run once, then build with:
#   JARVIS_SIGN_IDENTITY="Jarvis Dev" scripts/run.sh
set -euo pipefail
NAME="Jarvis Dev"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✓ '$NAME' already exists."; exit 0
fi
TMP="$(mktemp -d)"
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/jarvis.p12" -passout pass:jarvis -name "$NAME"
LOGIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/jarvis.p12" -k "$LOGIN" -P jarvis -T /usr/bin/codesign -T /usr/bin/security
# Trust it for code signing (user scope). Expect a password prompt here.
security add-trusted-cert -p codeSign -k "$LOGIN" "$TMP/cert.pem"
rm -rf "$TMP"
echo "✓ Created '$NAME'. Now build with: JARVIS_SIGN_IDENTITY=\"$NAME\" scripts/run.sh"
echo "  (macOS will ask for permissions one more time with the new identity, then remember them.)"
