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
try:
    with open(settings) as f:
        data = json.load(f)
except Exception as e:
    print(f"! ~/.claude/settings.json isn't valid JSON ({e}); status line left as it is")
    sys.exit(0)
line = data.get("statusLine") if isinstance(data, dict) else None
if isinstance(line, dict) and line.get("command") == tap:
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

# The hooks call $DATA_DIR/hook.py, so keep that folder unless they're really gone.
if [ -f "$DATA_DIR/hook.py" ]; then
  if ! python3 "$DATA_DIR/hook.py" uninstall; then
    echo "✗ Couldn't remove the hooks (see above). Kept $DATA_DIR; fix the file and run this again." >&2
    exit 1
  fi
  echo "✓ Hooks removed from Claude Code"
elif grep -qs 'agent-deck/hook.py' "$SETTINGS"; then
  echo "✗ Agent Deck hooks are still in your settings, but $DATA_DIR/hook.py is missing. Run install.sh, then this again." >&2
  exit 1
fi
rm -rf "$DATA_DIR"
echo "✓ Agent Deck data removed (your Claude Code sessions are untouched)"
