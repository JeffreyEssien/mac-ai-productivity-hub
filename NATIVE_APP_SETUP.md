# Native App Guide

Mac AI Productivity Hub is a native Mac desktop and menu-bar app. It reads and writes your existing Apple Reminders through Apple's EventKit framework.

It's built with **AppKit rather than SwiftUI**, so it compiles with just Apple's Command Line Tools. You don't need full Xcode.

For requirements and installation steps, see the [README](README.md#installation).

## Everyday use

- **New task:** click **New Task** (or use the menu-bar icon) and type a title. Then pick one of your Reminders lists. To set a due date, check **Set due date** and, if you want, **Remind at a specific time**. Use the **Today / Tomorrow / Next Week** buttons or choose a day and time from Apple's date picker.
- **View tasks:** switch between **All Open, Today, Overdue, Upcoming, No Due Date** and **Completed**. Tasks are sorted by due date and time. Tasks without a time show only their date.
- **Edit a task:** select a row and click **Edit Selected**, or double-click the row. This updates the original reminder.
- **Complete a task:** select a row and click **Toggle Complete**. The change reaches your iPhone through iCloud.
- **Snooze:** **Snooze +1 day** or **Snooze +1 week** moves the selected reminder's due date.
- **Mac Health:** shows a read-only snapshot of RAM, CPU, swap and storage. Any cleanup still goes through `storage_manager.py`, which asks before deleting anything.
- **Open Reminders:** opens Apple's Reminders app when you want its full editor.
- **Deep links:** `open macaihub://today` opens the app on a specific tab. The other tabs are `overdue`, `upcoming`, `nodue`, `completed` and `all`.

## Syncing and duplicates

The Hub works directly with your iCloud Reminders and doesn't keep a copy of its own. Edits and completions target each reminder by its EventKit ID.

To avoid duplicates, the app won't create an incomplete reminder whose title matches one already in the same list. This isn't a full guarantee across devices, though. Pending iCloud changes, slightly different wording, or tasks created on an offline iPhone at the same time can still produce duplicates.

If you also use `productivity_manager.py` to create reminders from an Apple Notes planning note on a schedule, keep in mind that both tools can create reminders. To turn off that schedule, run `python3 productivity_manager.py uninstall`. Your reminders won't be deleted.

## What the installer changes

- It builds and installs only `~/Applications/Mac AI Productivity Hub.app`.
- If an older copy is already there, it's renamed to a timestamped backup in `~/Applications`.
- It does **not** change `launchd` jobs, Apple Reminders, iCloud settings, Notes or Shortcuts.
- The app is signed ad hoc on your Mac. After you rebuild it, macOS may ask for Reminders access again.
- To sign with your own identity, set `MAC_HUB_SIGN_IDENTITY` before running the installer.

## Troubleshooting

- **Compiler errors:** check your toolchain with:
  ```bash
  xcode-select -p
  xcrun swiftc --version
  xcrun --sdk macosx --show-sdk-path
  ```
  If the SDK path is missing, reinstall the tools with `xcode-select --install`.
- **Reminders permission:** go to System Settings → Privacy & Security → Reminders and turn on **Mac AI Productivity Hub**.
- **New iPhone tasks not showing:** open Apple's Reminders app on the Mac and wait for iCloud to sync. Then click **Refresh** in the Hub.
- **Mac Health shows no output:** make sure `python3 --version` works. Task management doesn't need Python.

## Uninstall

Quit the app and move `~/Applications/Mac AI Productivity Hub.app` to the Trash. If you added it to Login Items, remove it there too. Uninstalling doesn't delete your reminders or turn off any Python schedules you installed separately.

## Changelog

- **0.3.1:** Fixed Swift 6 errors (main-actor isolation of the app delegate, optional views and optional reminder titles). The installer now compiles with `-parse-as-library` for the `@main` entry point.
- **0.3.0:** Rewrote the interface in AppKit instead of SwiftUI, so it builds on Command Line Tools without full Xcode.
