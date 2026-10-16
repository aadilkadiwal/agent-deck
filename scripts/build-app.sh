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

# Ad-hoc signature: enough for a locally built app to run and to register "Open at login".
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
