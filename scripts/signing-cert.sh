#!/bin/bash
# Makes "Agent Deck Local", a self-signed code-signing certificate, once. build-app.sh signs with it,
# so every update keeps the same identity and macOS remembers the folder, notification and
# automation permissions you gave instead of asking again.
# It lives in its own keychain, which the build unlocks itself: codesign then never needs a prompt.
set -euo pipefail
NAME="Agent Deck Local"
KC="$HOME/Library/Keychains/agent-deck-signing.keychain-db"
PW="agent-deck-local"   # guards a key that only signs your own local builds
if [ -f "$KC" ]; then echo "$NAME is already set up."; exit 0; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
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
# macOS's own LibreSSL: the keychain can't import the .p12 format newer OpenSSL writes by default.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -passout pass:agent-deck -out "$TMP/id.p12"

security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P agent-deck -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
echo "Set up $NAME."
