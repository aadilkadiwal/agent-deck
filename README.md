# Agent Deck

A macOS menu bar app for your [Claude Code](https://claude.com/claude-code) sessions:

- **Usage at a glance**: Dot, the app's face, leads the dropdown with one line ("2 working · 1 idle / Nothing needs you") and slim bars for your 5-hour and weekly limits with reset times (the same numbers `/usage` shows). A bar is grey, orange from your warning level, red when full, and says when the limit runs out at this pace. The menu bar shows the closer limit as a number ("86% · out 14:48", "100% · back 15:45"); Dot's rim there is the same meter.
- **Live session list**: every running session, newest first: a blue dot while it works, orange when it waits for you. Under the name, its folder, its branch when that isn't main, and what it's doing right now ("Iias · Bash: npm test · 2 agents 1:23"); the full path is in the tooltip. Context shows once it reaches 70% (red from 90%). Quick search by name, folder, prompt or ID. A row's buttons show when you point at it or select it. One click compacts a session's context (`/compact`, keeps a summary); Clear is in the right-click menu. ⌘K lists every action for the selected row. Grouped by project when more than five are running. An orange "!" on Dot in the menu bar means a session is waiting for you; the tooltip says how many.
- **Answer Claude from the menu bar**: permission prompts (Allow / Always allow / Deny), questions and plans (*Approve*, or *Approve, auto-accept edits*) show up as cards at the top of the dropdown and in the Waiting tab, the same card in both, and as alerts with answer buttons. ⌃⌥A / ⌃⌥D allow or deny the oldest prompt from any app; in the dropdown, ⌘⏎ approves and ⌘⌫ denies the selected card. Risky shell commands (deleting folders, force-pushing, `sudo`, piping a download into a shell…) are marked **RISKY** in red, Deny is the main button, and they can only be allowed with a click. The prompt stays in the terminal too: whichever you answer first wins.
- **Shortcut**: turn on ⌃⌥O to open the dropdown from any app (Settings → Shortcuts, or the welcome card on first open).
- **Health**: Settings (⌘,) shows whether every hook is set up, and repairs them in one click.
- **Alerts**: a session needs your answer, a long task finished, a limit reached your warning level (80% unless you change it in Settings) or is on pace to run out before it resets. They drop from the notch (or from the menu bar icon on a screen without one) with Dot, whose face shows what happened and whose rim is your usage, and a sound for each kind: needs you, limit, or done. Settings → Notifications plays a sample of each. When you're away they go out as macOS notifications. Each can be switched off.
- **Phone in one click**: make a running session reachable from the Claude phone app while it keeps running on your Mac, or disconnect the phone again. No restart.
- **Rename** running sessions (types `/rename`) and closed ones.
- **New session without a terminal**: pick a folder, then start it for your phone or open it in iTerm.
- **History**: projects in the sidebar, search, the last prompt under each name, branch and duration columns, the whole conversation (prompts, replies, tool calls, files changed) in the side panel, resume in an iTerm tab, delete one or many (⌘/⇧-click, ⌫), one-click cleanup of empty sessions, and keep history for 1 week, 2 weeks or 30 days.
- **Usage patterns**: a weekday × hour heatmap of when your 5-hour limit rises, and how often it was reached.
- **Full cleanup**: deleting a session also removes its scratchpad, undo backups and other data Claude Code keeps for it, and lets you pick files it created in your project. Settings shows Claude's storage and clears leftovers of sessions that are already gone.

A short tour of the real screens: [`docs/design.html`](docs/design.html).

## Install

```bash
npx agent-deck
```

Or without Node: `curl -fsSL https://raw.githubusercontent.com/aadilkadiwal/agent-deck/main/install.sh | bash`, or `./install.sh` from a checkout. Run it again any time to update.

Requirements: macOS 14+, Xcode Command Line Tools (`xcode-select --install`), Claude Code, iTerm2.

The installer:
1. Builds the app from source. Because it's built locally, there's no unsigned download for Gatekeeper to block.
2. Copies **Agent Deck.app** to `/Applications`.
3. Points Claude Code's status line at a small tap script (`~/.claude/agent-deck/statusline-tap.sh`) that saves the usage numbers and then runs **your original status line unchanged**. Your `settings.json` is backed up first, to `settings.json.agent-deck-backup`.
4. Runs `scripts/hook.py install`, which adds Agent Deck's hooks to `~/.claude/settings.json` (prompts, plus background activity hooks that never slow a tool call). Your own hooks are kept as they are.
5. Opens the app. It turns on *Open at login*, which you can switch off in Settings.

## Remove

```bash
npx agent-deck uninstall    # or ./uninstall.sh from a checkout
```

Restores your original status line, removes the prompt hooks, and removes the app and its data. Your Claude Code sessions are not touched.

## How it works

Agent Deck has no server and no login. It reads what Claude Code already writes, and every action is a normal `claude` command.

| Shows / does | Source |
|---|---|
| Running sessions, busy/idle, phone on/off | `~/.claude/sessions/<pid>.json` (watched for changes) + `claude agents --json` |
| Usage bars | `rate_limits` from the status line JSON, saved by the tap to `~/.claude/agent-deck/status.json` |
| History, names, models, sizes | Head and tail of `~/.claude/projects/*/*.jsonl` (cached) |
| 📱 on a running session (iTerm) | Types `/remote-control` into that exact tab, found by its tty, the same as typing it yourself. It keeps running on the Mac **and** is on your phone. Clicking again chooses *Disconnect* from that menu, so it leaves the phone but keeps running. Works while it's working or running agents too (`/remote-control` runs at once, like in the terminal); not while it's asking you something. If you've typed something in its prompt, nothing is sent and your text is left as it was. |
| 📱 on a background session | It has no window, so it reopens in iTerm with `claude --resume <id> --remote-control`: on your Mac and your phone. |
| Stop | `claude stop <id>` (background) or SIGTERM (terminal). Also removes it from the phone. |
| New for phone | `claude --bg --remote-control -n <name>` in the chosen folder |
| Open / resume a session | A new tab in your current iTerm window (a new window if none is open), via iTerm's AppleScript API. macOS asks once to allow it. |
| Keep history for 7 / 14 / 30 days | `cleanupPeriodDays` in `~/.claude/settings.json` (Claude Code's own cleanup) |
| Pace forecast | Usage readings logged to `~/.claude/agent-deck/usage-log.jsonl` (8 days kept). Rate over the last hour (5-hour limit) or day (weekly). |
| Waiting / finished alerts | `waitingFor` and `status` in each session's pid file, read every 3 s (no process started) |
| Context bar | `context_window.used_percentage` from the status line JSON, saved per session by the tap to `~/.claude/agent-deck/context/<id>.json`. Updates when Claude Code refreshes the status line. |
| Compact context | Types `/compact` into the session (idle only; same safety rules as the phone button). The session keeps its id; its context bar updates when Claude Code finishes the summary. |
| Clear context | Types `/clear` into the session (idle only; same safety rules as the phone button). It starts fresh in the same window; the old conversation stays in Recent, and *Undo* types `/resume <old id>` to bring it back. |
| Rename | Running: types `/rename <name>` (same safety rules as the phone button). Closed: appends a `custom-title` line, as Claude Code does. |
| Answering prompts | Claude Code runs `hook.py` when it's about to ask (`PermissionRequest`) or about to show a question or plan (`PreToolUse`). The hook sends the request over a Unix socket (`~/.claude/agent-deck/approvals.sock`, owner-only, peer uid checked) and waits up to ~10 min for a permission prompt, ~1 min for a question or plan. Your answer is printed in Claude Code's own hook format: allow / deny, the rule Claude Code suggested for *Always allow*, `updatedInput` with your answers for questions. If the app isn't running, approvals are off, or there's no answer, the hook prints nothing and Claude Code asks as usual. Claude Code keeps its prompt on screen meanwhile; when you answer there, the session's pid file stops saying it's waiting and the card goes away. |
| Auto-accept edits | Approving a plan this way switches that session to *accept edits* at its next file-edit prompt (a `setMode` permission update), the same as choosing it in the terminal. |
| Activity line | `PreToolUse` / `PostToolUse` / `SubagentStart` / `SubagentStop` / `Stop` hooks with `async: true`, so they run in the background. Git branch is read from the folder's `.git/HEAD`. |
| Show its window | iTerm and Terminal: the exact tab, by tty. tmux: the pane, then the terminal tab its client is in. kitty and WezTerm: the pane in that folder. Others: the app. |
| Health | `hook.py check` (bundled in the app); *Repair hooks* runs `hook.py install`. |
| ⌃⌥A / ⌃⌥D | Carbon hotkeys, registered only while a permission prompt is waiting, so they're free for other apps otherwise. No Accessibility permission needed. ⌃⌥A never allows a command marked risky. |
| Risky commands | Pattern checks on the shell command (`Risk` in `Approvals.swift`): recursive `rm`, force push, `git reset --hard` / `clean -f`, `sudo`, `curl … \| sh`, disk tools, `chmod 777`, `DROP TABLE`, `find -delete`. A heuristic: a command it doesn't flag isn't proven safe. |
| Open the menu shortcut | A Carbon hotkey, off until you turn it on (⌃⌥O, ⌃⌥Space or ⌃⌥⌘A in Settings → Shortcuts), that clicks Agent Deck's own menu bar item. If another app already owns the combination, Settings says so. |
| Conversation, branch, duration | Read from the transcript: user and assistant lines (subagent lines left out), `gitBranch`, and the first and last message `timestamp`. |
| Usage heatmap | The usage log's 5-hour readings: each rise is added to its weekday and hour. |
| Check for updates | `git fetch` in the folder the installer built from; Update pulls and re-runs `install.sh` |
| Delete / Clean up | Moves the transcript and everything Claude Code keeps for that session to the Trash, so you can still restore them: side folder, scratchpad (`/private/tmp/claude-<uid>/<project>/<id>`), undo backups (`file-history`), `session-env`, debug log, todos, tasks |
| Files a session created | Read from the transcript's Write results (`"type":"create"`). Shown when you delete one session, none ticked. Files in git can't be ticked; files changed after the session are flagged. Files made by shell commands aren't listed. |
| Claude storage / leftovers | Settings shows sizes of conversations, scratchpads and undo backups, and finds per-session data whose transcript is gone (unused for over a day). Clean up by hand or once a day automatically. |

Notes:
- Usage only updates while a Claude Code session is active, because that's when Claude Code sends it. The dropdown shows how old the numbers are.
- Background sessions only start in folders you've trusted. If a folder isn't trusted yet, the app offers to open it in iTerm so you can accept the prompt.
- Prompts: switch *Answer Claude's prompts from Agent Deck* off in Settings and Claude Code asks only in the terminal (the hooks stay installed and do nothing). Questions are answered in the dropdown; their notification only shows the question.
- Deleting history frees space on your Mac. Sessions listed on claude.ai or in the phone app are kept on Anthropic's servers and aren't affected.

## Develop

```bash
swift build                      # debug build
scripts/build-app.sh             # -> build/Agent Deck.app
```

Layout:
- `Sources/AgentDeckCore`: file parsing, `claude` commands, settings. No UI.
- `Sources/AgentDeck`: SwiftUI menu bar app (`MenuView` dropdown, `DetailsView` window).
- `scripts/statusline-tap.sh`: the status line tap.
- `scripts/hook.py`: the Claude Code hook, and its install / uninstall / check (Python 3.9 standard library, what ships with macOS).

## License

MIT, see [LICENSE](LICENSE).
