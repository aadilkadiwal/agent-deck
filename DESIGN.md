---
name: Agent Deck
description: A calm macOS menu bar deck for answering and steering coding-agent sessions.
colors:
  accent: "#007AFF"
  waiting: "#CC6200"
  working: "#007AFF"
  done: "#0B7D5D"
  risky: "#E0291F"
  brand: "#6E56CF"
  session-teal: "#30B0C7"
  session-pink: "#FF2D55"
  session-indigo: "#5856D6"
  session-cyan: "#32ADE6"
  session-slate: "#63738C"
  surface-tint: "rgba(0, 0, 0, 0.06)"
typography:
  title:
    fontFamily: "SF Pro, system-ui"
    fontSize: "15px"
    fontWeight: 600
  name:
    fontFamily: "SF Pro, system-ui"
    fontSize: "13px"
    fontWeight: 500
  body:
    fontFamily: "SF Pro, system-ui"
    fontSize: "12px"
    fontWeight: 400
  detail:
    fontFamily: "SF Pro, system-ui"
    fontSize: "11px"
    fontWeight: 400
  mono:
    fontFamily: "SF Mono, ui-monospace"
    fontSize: "11px"
    fontWeight: 400
rounded:
  inner: "6px"
  row: "8px"
  panel: "10px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "20px"
components:
  row:
    rounded: "{rounded.row}"
    padding: "4px 8px"
  approval-card:
    backgroundColor: "{colors.waiting}"
    rounded: "{rounded.row}"
    padding: "8px"
  approval-card-risky:
    backgroundColor: "{colors.risky}"
    rounded: "{rounded.row}"
    padding: "8px"
  callout:
    rounded: "{rounded.row}"
    padding: "8px"
  confirm-bar:
    backgroundColor: "{colors.accent}"
    rounded: "{rounded.row}"
    padding: "8px"
  icon-button:
    rounded: "{rounded.inner}"
    width: "28px"
    height: "24px"
  dropdown:
    width: "370px"
    padding: "8px"
---

# Design System: Agent Deck

## Overview

A tool you glance at, not a place you stay. Agent Deck looks like macOS itself: system fonts, system colors, standard controls and SF Symbols. Its character comes from one strict color language (orange = needs you, blue = working, bluish green = done, red = risky) and from restraint: rows are quiet until you point at them, and the loudest thing on screen is always whatever is waiting for you.

Colors in the frontmatter are the light-mode values. Status and brand colors live in `Tone` (Meters.swift), each with a light and a dark value; the code is the source of truth.

## Colors

### Primary

- **Accent** (`Color.accentColor`): selection, focus rings, prompt bubbles. Follows the user's system accent.

### Status (reserved)

- **Waiting** (`Tone.waiting`, #CC6200 / #FF9F0A): a session needs you. Card icon, waiting row tint, ringed dot, menu bar dot, context bar from 70%.
- **Working** (`Tone.working`, #007AFF / #0A84FF): a session is busy. Filled pulsing dot; a hollow grey dot is idle.
- **Done** (`Tone.done`, #0B7D5D / #2FD6A9): finished, allowed, healthy. Bluish, so it stays apart from risky and waiting with red–green colour blindness.
- **Risky** (`Tone.risky`, #E0291F / #FF453A): a risky command, a denied answer, a full limit, context from 90%.

Light mode gets darker fills so dots and bars keep 3:1 against the menu. Dot's body is graphite in both appearances, so it always uses the dark values.

### Brand

- **Violet** (`Tone.brand`, #6E56CF / #A394FF): the ring around Dot on the app icon and the welcome card. It has no status meaning and appears nowhere else.

### Session palette

Five colors that mark a session: teal, pink, indigo, cyan, slate. Slate has its own dark-mode value. Green, orange, blue and red are never used, because they would read as a status, and neither is purple, because it would read as the brand.

### Named Rules

- **Status colors are reserved.** Orange, blue, bluish green and red only ever mean waiting, working, done and risky. Nothing decorative uses them.
- **Never color alone.** Every status also has a shape or a word: hollow, solid and ringed dots; an icon on each prompt; the RISKY tag.
- **One tint per surface.** A surface gets at most one tinted background; emphasis beyond that comes from weight, not more color.

## Typography

System font only (SF Pro, SF Mono), through macOS text styles so text follows the system's size settings.

### Hierarchy

| Role | Text style | Size | Used for |
|---|---|---|---|
| Title | `.title3` semibold | 15 pt | Side panel session name |
| Name | `.body` medium (semibold when waiting) | 13 pt | Row and card names, Welcome title |
| Body | `.callout` | 12 pt | Card text, banners, confirm bars, settings |
| Detail | `.subheadline` | 11 pt | Paths, activity lines, hints, section headers, pills |
| Mono | `.subheadline.monospaced()` | 11 pt | Commands, diffs, file paths, tool lines |

### Named Rules

- **11 pt is the floor.** No text smaller than `.subheadline`. Only symbols (chevrons, small icons) use fixed point sizes.
- **Digits that change are monospaced** (`.monospacedDigit()`): timers, percentages, counts, sizes.

## Layout

- Dropdown: a borderless panel flush under the menu bar, 370 pt wide, 8 pt side padding (4 pt at the top), usage rings 48 pt (their percentage label stays at 11 pt or more; smaller rings show the number beside them). Its two scrolling lists (Needs you, Sessions) share the height left on that screen after the measured fixed parts, so the footer always stays on screen.
- Spacing is on a 4 pt grid: 4 (icon and its label), 8 (between items and inside rows and cards), 12 (window content), 20 (page padding).
- Details window: sidebar (Sessions, Waiting, Usage, then Projects, 8 shown), table, optional side panel (260 to 460 pt).
- Settings: a standard Settings window with tabs, resizable from 520 × 420 pt.

## Elevation & Depth

Flat. Depth comes from the system: the menu bar window's material, the floating panel's window shadow, and one shadow on the ⌘K list, which sits above the dropdown. Cards and rows separate by tint, never by shadow.

## Shapes

Three radii by role: **inner 6 pt** (code boxes, chips, option buttons, icon button highlight), **row 8 pt** (rows, cards, callouts, confirm bars), **panel 10 pt** (grouped panels in the details window, the ⌘K list). Capsules for status chips, pills and bars.

## Components

### Session row (`HoverRow` + `liveRow`)

Session color bar (3 pt), state dot, name (+ phone icon, Background / agent pill), path and branch, activity line (only when it says something: working, waiting, agents, old entry). At rest the trailing side shows the context bar and a faint "…" hint that the row has actions. On hover, keyboard selection (⌘K lists them all) or VoiceOver it shows the buttons: phone, compact (amber or red when context is high), a gap, then stop. With only one session running, the buttons always show, next to its context bar.

### Approval card

No side stripe. The first line starts with an SF Symbol in the status color: a hand for a permission, a speech bubble for a question, a clipboard for a plan, a triangle for risky. Collapsed prompts show the same symbol in front of their name. Line 1: session color dot, name, folder and branch, timer, terminal button. Line 2: what it wants, plus a red RISKY tag with the reason when the command is risky. Then the command, diff or plan (plans as formatted text), then the answer buttons. A risky card turns red, Deny becomes the prominent button, Allow becomes "Allow once" and there is no Always allow.

### Callout

A tinted notice in one of the status colors (setup warning, result banner, All clear, health summary, welcome card). Optional outline for warnings that block a feature.

### Confirm bar

The neutral strip (primary at 5%) under a row that asks before something happens (stop, compact, clear, open with phone, delete, rename). `ConfirmRow` gives the message + Cancel + the action. Return confirms, except for destructive actions, which need a click.

### Buttons

System buttons: `.borderedProminent` for the one main action of a surface, `.bordered` / plain for the rest. Icon buttons are 28 × 24 pt with a 6 pt highlight when on. Destructive actions use `role: .destructive`.

### ⌘K action list

A floating list over the dropdown: search field, then every action for the selected row with its shortcut. Actions that can't run right now stay listed, dimmed, with the reason.

### Pinned panel

A floating window that stays above other apps. Full: usage line, prompt cards, one row per session. Small: usage line and one line per session; a waiting one opens the dropdown with its card selected.

### Welcome card

Shown once in the dropdown, on a violet tint (the only brand color inside the app): setup status (with Repair), ⌘K, and "Choose a shortcut…", which opens Settings → Shortcuts. Dismissed with "Got it".

## Do's and Don'ts

- **Do** put whatever needs the user at the top; shrink everything else.
- **Do** say why an action is unavailable (tooltip, dimmed ⌘K entry) instead of hiding it.
- **Do** use plain words: "Background", "Old entry", "Weekly 18%".
- **Don't** use orange, blue, green or red for decoration, or violet for anything but the brand.
- **Don't** add a key that works outside Agent Deck by default. The only global shortcut is the open-menu key the user records.
- **Don't** add text below 11 pt or fixed font sizes for text.
- **Don't** animate the same event in more than one place at once (a waiting prompt gets the card's arrival and the menu bar dot, nothing more).
- **Don't** let a key press from another app approve a risky command.
