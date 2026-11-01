# Native App Guide

Mac AI Productivity Hub is a native Mac desktop and menu-bar app. It reads and writes your existing Apple Reminders through Apple's EventKit framework.

It's built with **AppKit rather than SwiftUI**, so it compiles with just Apple's Command Line Tools. You don't need full Xcode.

For requirements and installation steps, see the [README](README.md#installation).

## Everyday use

- **New task:** click **New Task** (or use the menu-bar icon) and type a title. Then pick one of your Reminders lists. To set a due date, check **Set due date** and, if you want, **Remind at a specific time**. Use the **Today / Tomorrow / Next Week** buttons or choose a day and time from Apple's date picker.
- **Overview:** the cards at the top show open tasks, overdue tasks, tasks due today and free storage. The "Your next step" card shows the most urgent task.
- **View tasks:** switch between **All Open, Today, Overdue, Upcoming, No Due Date** and **Completed**. Tasks are sorted by due date and time. Tasks without a time show only their date.
- **Edit a task:** select a row and click **Edit Selected**, or double-click the row. This updates the original reminder.
- **Complete a task:** select a row and click **Toggle Complete**. The change reaches your iPhone through iCloud.
- **Snooze:** **Snooze +1 day** or **Snooze +1 week** moves the selected reminder's due date.
- **Today's Plan:** click **View Today's Plan** for an overview grouped by what to do first, what's due today, what's later and what has no deadline. Without AI, choose **View Basic Plan**.
- **Desktop Companion:** opens a small floating panel with your counts, your next task, free space and quick buttons. Drag it by its title bar, and close it any time.
- **Review Cleanup:** shows old screenshots (30+ days), old installers (60+ days) and VS Code caches, all **unchecked**. Tick what to remove and confirm a second time. The files go to the Trash, which the app never empties. If a file changed after the scan, the app won't move it. Browser data, app support folders, projects and system files are never offered.
- **Mac Health:** a plain-language report on free space, installed memory, swap use and the apps using the most memory. High swap use hints at memory pressure but doesn't prove it.
- **Open Reminders:** opens Apple's Reminders app when you want its full editor.
- **Deep links:** `open macaihub://today` opens the app on a specific tab. The other tabs are `overdue`, `upcoming`, `nodue`, `completed` and `all`.

## AI setup (optional)

The AI plan uses a Shortcut that you build once in the Shortcuts app. Your Mac needs Apple Intelligence turned on. The app's **AI Setup** button shows these same steps.

1. Open **Shortcuts** and create a new shortcut named exactly **Mac Hub AI Plan**.
2. Add **Get Text from Input**, with **Shortcut Input** as its source.
3. Add **Use Model** and choose **On-Device** if it's available. Use a prompt like this:
   ```text
   Analyze the task list provided in the input. Write a concise plan in plain English:
   1. Do first (overdue/time-sensitive)
   2. Due today
   3. Schedule later
   4. Tasks without deadlines

   Only use the dates, times and task titles in the input.
   Do not invent missing dates, mark anything completed, or change reminders.
   Return plain text.

   TASKS:
   [Get Text from Input variable]
   ```
4. Turn **Follow Up** off. Connect the model's **Response** to **Stop and Output**. Don't add Show Alert or Ask for Input.
5. Test it in Shortcuts with a few sample tasks.
6. In the Hub, open **View Today's Plan** → **Generate AI Plan**. The app asks before it shares your tasks.

To check that the Shortcut is saved, run `shortcuts list | grep -F "Mac Hub AI Plan"`. The AI only gives suggestions: it can't edit reminders or delete files. Generating a plan can make the window pause briefly while the model runs.

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
- **AI plan fails:** check the Shortcut is named exactly **Mac Hub AI Plan** and ends with **Stop and Output**. A Shortcut that only shows text doesn't return anything to the app.
- **Mac Health shows no output:** make sure `python3 --version` works. Task management doesn't need Python.

## Uninstall

Quit the app and move `~/Applications/Mac AI Productivity Hub.app` to the Trash. If you added it to Login Items, remove it there too. Uninstalling doesn't delete your reminders or turn off any Python schedules you installed separately.

## Changelog

- **0.5.0:** Combined the 0.4.1 dashboard (overview cards, Today's Plan with optional AI, Desktop Companion, Review Cleanup and a plain-language Mac Health report) with the 0.3.x features (snooze, menu-bar counts, `macaihub://` links, crash-safe reminder titles, and the `doctor`, `add-nl`, `reflect` and `trend` CLI commands).
- **0.3.1:** Fixed Swift 6 errors (main-actor isolation of the app delegate, optional views and optional reminder titles). The installer now compiles with `-parse-as-library` for the `@main` entry point.
- **0.3.0:** Rewrote the interface in AppKit instead of SwiftUI, so it builds on Command Line Tools without full Xcode.
