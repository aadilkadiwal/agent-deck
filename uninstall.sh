#!/bin/bash
# Removes Agent Deck, puts your original status line back and removes its prompt hooks.
set -euo pipefail

DATA_DIR="$HOME/.claude/agent-deck"
SETTINGS="$HOME/.claude/settings.json"

pkill -x AgentDeck 2>/dev/null || true
rm -rf "/Applications/Agent Deck.app" "$HOME/Applications/Agent Deck.app"
echo "✓ App removed"

if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" "$DATA_DIR/statusline-tap.sh" "$DATA_DIR/original-statusline" <<'PY'
import json, os, sys
settings, tap, orig_file = sys.argv[1:4]
with open(settings) as f:
    data = json.load(f)
line = data.get("statusLine") or {}
if line.get("command") == tap:
    orig = open(orig_file).read().strip() if os.path.exists(orig_file) else ""
    if orig:
        data["statusLine"] = {**line, "command": orig}
    else:
        data.pop("statusLine", None)
    with open(settings + ".tmp", "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(settings + ".tmp", settings)
    print("✓ Status line restored")
PY
fi

[ -f "$DATA_DIR/hook.py" ] && python3 "$DATA_DIR/hook.py" uninstall && echo "✓ Hooks removed from Claude Code, Codex and Gemini CLI"
rm -rf "$DATA_DIR"
echo "✓ Agent Deck data removed (your Claude Code sessions are untouched)"
