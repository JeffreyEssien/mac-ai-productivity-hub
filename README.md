# Mac AI Productivity Hub — v0.3 AppKit edition

A native macOS task and storage dashboard for Apple Silicon Macs. AppKit replaces the prior SwiftUI interface to avoid `SwiftUIMacros` compilation failure on Command Line Tools-only installations.

**Start here:** [NATIVE_APP_SETUP.md](NATIVE_APP_SETUP.md).

This project bundles the existing Python storage manager, productivity tooling, and test suite without modifying your previously scheduled `launchd` jobs. The task dashboard uses EventKit to manage your real Apple Reminders lists with a graphical date/time picker, editing, completion, search and sorting. iPhone reminders synchronize via iCloud; iPhone Shortcuts run independently of the Mac.

The on-device/macOS build is not verified until you run `./native/install_mac_app.sh` on your Mac. This version does not embed an Apple Intelligence model; any previously configured Mac AI Shortcuts remain separate.

## v0.3.1 compiler compatibility fix

Updated AppKit entry point for Swift 6 actor isolation, explicitly unwrapped
initialized views, and handled optional reminder titles. No existing
Apple Reminders lists or scheduled Python jobs are modified by installation.

## Command reference

All Python tools are stdlib-only and macOS-only for their Apple integrations.
Scheduled/headless runs stay read-only; anything that writes is interactive or
requires an explicit `--apply`/`--execute` flag.

### `ai_hub.py` — text-first Apple Reminders assistant

| Command | What it does |
|---------|--------------|
| `list` | Print a prioritized brief of open reminders (overdue / today / upcoming / no due date). |
| `add` | Interactively add a reminder via native dialogs. |
| `add-nl "<phrase>"` | Create a reminder from natural language (e.g. `"call the dentist next tuesday at 3pm"`). Routes the phrase to an on-device Apple Intelligence Shortcut (`--shortcut`, default `Mac AI Task Parser`) and falls back to a built-in local parser. Use `--local` to force local parsing with no Shortcut. |
| `ai-brief` | Run an Apple Intelligence Shortcut (`--shortcut`, default `Mac AI Task Briefing`) over your tasks on-device. |
| `checkin <morning\|midday\|evening>` | Print a read-only check-in; `--notify` also posts a macOS notification. |
| `diagnose` | Read-only disk/swap/memory snapshot. |
| `doctor` | Health check: config validity, Reminders access, which scheduled agents are installed/loaded, and recent errors. |
| `install` / `uninstall` | Add or remove the read-only scheduled check-in `launchd` agents. |

Natural-language entry and briefings use on-device Apple Intelligence Shortcuts
only — there are no network AI calls.

### `productivity_manager.py` — iCloud Notes → Apple Reminders planner

| Command | What it does |
|---------|--------------|
| `scan` | Preview tasks parsed from the planning note (read-only). |
| `sync` | Create/update reminders from the note. Preview by default; add `--apply` to write. |
| `reflect` | Reverse sync: mark a note task `DONE` when the matching reminder has been completed (e.g. on iPhone). Only ever flips `OPEN → DONE`; preview by default, `--apply` to write. |
| `prompt <morning\|evening>` | Show the daily planning dialog (open the note / sync now). |
| `install` / `uninstall` | Add or remove the planner `launchd` agents and the double-clickable sync launcher app. |

Task lines use the format `TASK-xxxx | Title | YYYY-MM-DD HH:MM | OPEN|DONE`
(the `TASK-` prefix is case-insensitive). A persistently failing headless sync
posts a macOS notification instead of failing silently.

### `storage_manager.py` — conservative storage report/cleanup

| Command | What it does |
|---------|--------------|
| `scan` | Read-only report of cleanup candidates and report-only storage. |
| `execute` | Interactive, per-item approved cleanup (TTY required); `--approve-native` also offers `pip`/Homebrew cleanup. |
| `trend` | Show recorded free-space history over time and the net change across the window. |
| `install` / `uninstall` | Add or remove the daily read-only scan `launchd` agent (`--hour`). |

Each `scan`/`execute` appends a row to `~/.mac-storage-manager/history.jsonl`
(capped at 500 rows) that `trend` reads.

### Native AppKit app

Beyond add/edit/complete/search/sort with a graphical date picker, the app adds
**Snooze +1 day / +1 week** on the selected reminder, **live open/overdue counts**
in the menu-bar icon, and a `macaihub://` URL scheme that opens the app to a
specific tab — `macaihub://overdue` (also `today`, `upcoming`, `nodue`,
`completed`, `all`), e.g. `open macaihub://overdue`.
