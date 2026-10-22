#!/bin/bash
# Agent Deck status line tap.
#
# Claude Code pipes a JSON blob to the status line command on every refresh. It includes your
# usage limits (rate_limits.five_hour / seven_day). This script saves that blob for Agent Deck,
# then hands the same input to your original status line command, so your status line looks
# exactly as before.
#
# Installed to ~/.claude/agent-deck/statusline-tap.sh; your original command is kept in
# ~/.claude/agent-deck/original-statusline and put back by uninstall.sh.

dir="$HOME/.claude/agent-deck"
input=$(cat)

# Only keep snapshots that carry limits (API-key sessions have none), written atomically
# because several sessions can refresh at the same moment.
case "$input" in
  *'"five_hour"'*|*'"seven_day"'*)
    tmp="$dir/status.json.$$"
    printf '%s' "$input" > "$tmp" && mv -f "$tmp" "$dir/status.json"
    ;;
esac

if [[ $input =~ \"session_id\":\ *\"([A-Za-z0-9-]+)\" ]] && [[ $input == *'"context_window"'* ]]; then
  ctx="$dir/context"
  mkdir -p "$ctx"
  printf '%s' "$input" > "$ctx/${BASH_REMATCH[1]}.json.$$" && mv -f "$ctx/${BASH_REMATCH[1]}.json.$$" "$ctx/${BASH_REMATCH[1]}.json"
  find "$ctx" -name '*.json' -mtime +7 -delete 2>/dev/null
fi

orig="$dir/original-statusline"
if [ -s "$orig" ]; then
  printf '%s' "$input" | /bin/bash -c "$(cat "$orig")"
fi
