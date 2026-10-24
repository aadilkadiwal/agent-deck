# Agent Deck

A macOS menu bar app for your coding agents: [Claude Code](https://claude.com/claude-code), plus [Codex](https://github.com/openai/codex) and [Gemini CLI](https://github.com/google-gemini/gemini-cli) sessions:

- **Usage at a glance**: rings for your 5-hour and weekly limits with reset times (the same numbers `/usage` shows), plus a pace line: "At this pace: 100% at 3:40 PM". The menu bar shows whichever limit is closer to running out.
- **Live session list**: every running session, newest first, each with its own color (the same color marks its prompt cards), its git branch, and what it's doing right now ("Bash: npm test · 2 agents · 1:23") next to a bar showing how full its context is (amber from 70%, red from 90%), with quick search (name, folder, prompt or ID). A row's buttons show when you point at it or select it. One click compacts a session's context (`/compact`, keeps a summary); Clear is in the right-click menu. ⌘K lists every action for the selected row. Codex and Gemini CLI sessions are listed too. Grouped by project when more than five are running. An amber dot on the menu bar icon and "N waiting" next to it mean a session is waiting for you.
- **Answer Claude from the menu bar**: permission prompts (Allow / Always allow / Deny), questions and plans (*Approve*, or *Approve, auto-accept edits*) show up as cards at the top of the dropdown and as notifications with answer buttons. Codex permission prompts too (Allow / Deny). ⌃⌥A / ⌃⌥D allow or deny from any app. Risky shell commands (deleting folders, force-pushing, `sudo`, piping a download into a shell…) are marked **RISKY** and can only be allowed with a click. The prompt stays in the terminal too: whichever you answer first wins.
- **Pin and shortcut**: pin the dropdown as a panel that floats above your terminal (full, or small: one line per session), or turn on ⌃⌥O to open it from any app (Settings → Shortcuts, or the welcome card on first open).
- **Codex usage**: Codex's own limits (5-hour and weekly, or monthly on the free plan) under the Claude rings, read from Codex's session files.
- **Health**: Settings (⌘,) shows whether every hook is set up, and repairs them in one click.
- **Notifications**: a session needs your answer, a long task finished, a limit passed 80% / 95%. Each can be switched off.
- **Phone in one click**: make a running session reachable from the Claude phone app while it keeps running on your Mac, or disconnect the phone again. No restart.
- **Rename** running sessions (types `/rename`) and closed ones.
- **New session without a terminal**: pick a folder, then start it for your phone or open it in iTerm.
- **History**: projects in the sidebar, search, the last prompt under each name, branch and duration columns, the whole conversation (prompts, replies, tool calls, files changed) in the side panel, resume in an iTerm tab, delete one or many (⌘/⇧-click, ⌫), one-click cleanup of empty sessions, and keep history for 1 week, 2 weeks or 30 days.
- **Usage patterns**: a weekday × hour heatmap of when your 5-hour limit rises, and how often it was reached.
- **Full cleanup**: deleting a session also removes its scratchpad, undo backups and other data Claude Code keeps for it, and lets you pick files it created in your project. Settings shows Claude's storage and clears leftovers of sessions that are already gone.

Design walkthrough with clickable mockups and every flow: [`docs/design.html`](docs/design.html).

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
4. Runs `scripts/hook.py install`, which adds Agent Deck's hooks for each agent it finds: `~/.claude/settings.json` (prompts, plus background activity hooks that never slow a tool call), `~/.codex/hooks.json` and `~/.gemini/settings.json` (Gemini CLI 0.26+). Your own hooks are kept as they are. **Codex runs a new hook only after you approve it once**: open Codex and type `/hooks`.
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
| Usage rings | `rate_limits` from the status line JSON, saved by the tap to `~/.claude/agent-deck/status.json` |
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
| Answering prompts | Claude Code runs `hook.py` when it's about to ask (`PermissionRequest`) or about to show a question or plan (`PreToolUse`). The hook sends the request over a Unix socket (`~/.claude/agent-deck/approvals.sock`, owner-only, peer uid checked) and waits up to ~10 min. Your answer is printed in Claude Code's own hook format: allow / deny, the rule Claude Code suggested for *Always allow*, `updatedInput` with your answers for questions. If the app isn't running, approvals are off, or there's no answer, the hook prints nothing and Claude Code asks as usual. Claude Code keeps its prompt on screen meanwhile; when you answer there, the session's pid file stops saying it's waiting and the card goes away. |
| Auto-accept edits | Approving a plan this way switches that session to *accept edits* at its next file-edit prompt (a `setMode` permission update), the same as choosing it in the terminal. |
| Codex | `PermissionRequest` gets Allow / Deny (Codex takes no saved rules from hooks). Session start, prompt, tool and stop hooks fill the session list; a session disappears when its process exits. Usage limits come from the `token_count` events in `~/.codex/sessions/…/rollout-*.jsonl`. |
| Gemini CLI | Watch only: its hooks show sessions, working / idle and "needs your OK". Gemini can't take an answer from a hook, so you answer in its terminal. |
| Activity line | `PreToolUse` / `PostToolUse` / `SubagentStart` / `SubagentStop` / `Stop` hooks with `async: true`, so they run in the background. Git branch is read from the folder's `.git/HEAD`. |
| Show its window | iTerm and Terminal: the exact tab, by tty. tmux: the pane, then the terminal tab its client is in. kitty and WezTerm: the pane in that folder. Others: the app. |
| Health | `hook.py check` (bundled in the app); *Repair hooks* runs `hook.py install`. |
| ⌃⌥A / ⌃⌥D | Carbon hotkeys, registered only while a permission prompt is waiting, so they're free for other apps otherwise. No Accessibility permission needed. ⌃⌥A never allows a command marked risky. |
| Risky commands | Pattern checks on the shell command (`Risk` in `Approvals.swift`): recursive `rm`, force push, `git reset --hard` / `clean -f`, `sudo`, `curl … \| sh`, disk tools, `chmod 777`, `DROP TABLE`, `find -delete`. A heuristic: a command it doesn't flag isn't proven safe. |
| Open the menu shortcut | A Carbon hotkey, off until you turn it on (⌃⌥O, ⌃⌥Space or ⌃⌥⌘A in Settings → Shortcuts), that clicks Agent Deck's own menu bar item. If another app already owns the combination, Settings says so. |
| Pinned panel | A floating window (`NSPanel`) with the usage line, prompt cards and running sessions; its small mode shows one line per session, and a waiting one opens the dropdown with its card selected. It stays above other apps and on every Space until you unpin it, and comes back at launch if it was pinned. |
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
- `scripts/hook.py`: the hook for all three agents, and its install / uninstall / check (Python 3.9 standard library, what ships with macOS).

## License

MIT, see [LICENSE](LICENSE).
