# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

The design language is Apple's (Impeccable has no separate macOS value). The app itself is native macOS (SwiftUI + AppKit), macOS 14+: a menu bar item with a dropdown, a details window, a floating pinned panel and a Settings window. Pointer and keyboard, not touch.

## Users

Developers who run several coding-agent sessions at once (mainly Claude Code, also Codex and Gemini CLI) in iTerm on a Mac. They work in the terminal and glance at Agent Deck between tasks: to answer a prompt, see which session is working or waiting, check how close they are to a usage limit, or find and resume an old session.

## Product Purpose

One place on the Mac for every running agent session: answer permission prompts, questions and plans without switching windows; see usage limits with a pace forecast; control sessions (phone, compact, clear, rename, stop); browse, resume and clean up history. Success: a prompt is answered within seconds of appearing, and nobody runs out of a limit by surprise.

## Positioning

Agent Deck controls sessions instead of only showing numbers. It answers Claude Code's prompts through Claude Code's own hooks, and types slash commands (`/remote-control`, `/compact`, `/clear`, `/rename`) into the exact iTerm tab of a session. It has no server and no login: it reads what Claude Code already writes.

## Operating Context

- Lives in the menu bar; the dropdown is opened dozens of times a day, usually for a few seconds.
- The terminal (iTerm) is the main workspace; the pinned panel floats above it.
- Prompts also stay in the terminal: whichever is answered first wins.
- Keyboard first: ⌘K, ↑↓, ⏎, ⌘⏎, letter keys, global ⌃⌥A / ⌃⌥D and an optional global shortcut to open the menu.

## Capabilities and Constraints

- Data sources: `~/.claude/sessions/*.json`, `claude agents --json`, transcripts under `~/.claude/projects`, the status line JSON (via a tap script), Codex and Gemini hook events.
- Typing into a session only happens when it's idle (or for immediate commands), never into a draft or a pending question.
- Deletes go to the Trash with Undo.
- Risky shell commands (pattern heuristic) can't be allowed with a shortcut or a notification button.
- Terminology: "session", "prompt", "waiting / working / idle", "compact", "clear", "background session", "old entry".

## Evidence on Hand

- `README.md`: feature list and "How it works" table.
- `docs/design.html`, `docs/review.html`: earlier design walkthrough and product review.
- No screenshots or recordings of the current build exist in the repo.

## Product Principles

1. What needs you comes first; everything else waits its turn.
2. Never act on a session behind the user's back: no typing into drafts, no one-key approval of risky commands.
3. Every action can be undone or is confirmed first.
4. Calm at rest: details appear when pointed at, selected or asked for (⌘K).
5. Native over custom: standard Mac windows, tables, shortcuts and SF Symbols.

## Accessibility & Inclusion

- VoiceOver: every control is labeled; row buttons are always shown when VoiceOver is on.
- Text uses macOS text styles with an 11 pt minimum.
- Reduce Motion is honored everywhere.

## Open decisions

These were inferred from the code and README, not confirmed in an interview. Run `/impeccable init` to confirm or correct them:

- Audience beyond Claude Code power users (teams? newcomers?).
- Whether Codex and Gemini support should get equal design weight.
- Brand voice: currently plain and direct; no visual brand beyond the system look.
