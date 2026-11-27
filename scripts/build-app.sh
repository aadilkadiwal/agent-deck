#!/bin/bash
# Builds "Agent Deck.app" into ./build from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AgentDeck
BIN="$(swift build -c release --show-bin-path)/AgentDeck"

APP="build/Agent Deck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp scripts/hook.py "$APP/Contents/Resources/hook.py"   # Settings → Health repairs hooks with it
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # Dot; notifications carry it too
# macOS plays custom notification sounds only from the app bundle
cp Resources/Sounds/*.wav "$APP/Contents/Resources/"

# Signed with "Agent Deck Local" when scripts/signing-cert.sh has made it, so macOS keeps its permissions
# across updates; otherwise ad hoc, which runs fine but makes macOS ask again after each build.
KC="$HOME/Library/Keychains/agent-deck-signing.keychain-db"
if [ -f "$KC" ] && security unlock-keychain -p agent-deck-local "$KC" 2>/dev/null; then
  codesign --force --keychain "$KC" --sign "Agent Deck Local" "$APP" >/dev/null
else
  codesign --force --sign - "$APP" >/dev/null
fi
echo "$APP"
