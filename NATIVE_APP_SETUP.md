# Mac AI Productivity Hub v0.3 — AppKit edition

This is a **native Mac desktop and menu-bar app** that reads/writes your existing Apple Reminders through EventKit. It uses **AppKit, not SwiftUI** so it does not require the missing `SwiftUIMacros.StateMacro` plugin. It is distributed as source; it has **not** been compiled or permission-tested on your Mac, and your Apple Command Line Tools installation must support AppKit compilation.

## Installation on your Mac (Apple Silicon, macOS 14+)

1. Download and extract the ZIP to Desktop. The extracted project directory is `mac_ai_productivity_hub_appkit_v3`.
2. Open Terminal **once** and run:

   ```bash
   cd "$HOME/Desktop/mac_ai_productivity_hub_appkit_v3"
   chmod +x native/install_mac_app.sh
   ./native/install_mac_app.sh
   ```

   If the extracted name differs, drag the folder from Finder into Terminal after typing `cd `.
3. Open the installed app:

   ```bash
   open "$HOME/Applications/Mac AI Productivity Hub.app"
   ```

4. Grant macOS **Reminders** permission. Your existing iCloud lists, including `REMINDER`, will appear when adding a task. The app does not require or create `Mac Planner`.
5. Optionally pin the app to the Dock. Its checklist icon should also appear in the Mac menu bar. To launch at login, add the `.app` via **System Settings → General → Login Items & Extensions**.

> The AppKit source passes syntax parsing in the build environment, but it cannot be fully compiled against Apple's macOS SDK there. If your Mac reports a compiler error, send the **first error and 15 lines around it** so it can be corrected precisely. Please do not install full Xcode solely to fix the SwiftUI macro error until we test this replacement.

## Everyday use

- **New Task:** Click **New Task** (or use the menu-bar icon), type a title, select one of your real Apple Reminders lists, check **Set due date** and optionally **Remind at a specific time**. Use **Today / Tomorrow / Next Week** buttons or choose a day and time from Apple's native picker.
- **See tasks:** The dashboard shows **All Open, Today, Overdue, Upcoming, No Due Date, Completed**. It sorts by due date and time, and shows untimed tasks as dates rather than midnight.
- **Edit task:** Select a row and click **Edit Selected**, or double-click it. This updates the original reminder using its native EventKit identifier.
- **Complete task:** Select a row and click **Toggle Complete**. Changes appear on your iPhone after iCloud sync.
- **Diagnostics:** Click **Mac Health** to run read-only RAM/CPU/swap and storage inspections. Any cleanup still requires manual approval through the original Python tool.
- **Open Apple's Reminders:** Use the dedicated button when you want its own full editing experience.

The app does **not** provide Apple Intelligence analysis directly; Mac AI Shortcuts from the prior package remain separate. Existing iPhone Quick Add Task and Daily Task Review Shortcuts continue independently while the Mac is off.

## Duplicate protection and synchronization

The same iCloud Reminders records are shared between Mac and iPhone, not copied into a second database. The app prevents creating an **incomplete reminder with the same normalized title in the same list** when already fetched. Edits and completion use EventKit identifiers. This avoids ordinary duplication, **but is not an atomic cross-device guarantee**: pending iCloud writes, differently worded tasks, and simultaneous offline creation can still produce duplicates. Check iCloud Reminders on the Mac before creating a reminder you have just entered on an offline iPhone.

Do **not** re-enable an older *Notes-to-Reminders automatic creation* schedule at the same time. If your previous `productivity_manager.py` is scheduled to create reminders, disable that particular schedule with its own `uninstall` command from the **original** project folder; this will not delete your reminders. The Mac and iPhone read-only daily briefing schedules can remain running.

## What installation changes

- It compiles and installs only `~/Applications/Mac AI Productivity Hub.app`.
- If an older version of the `.app` exists, it is renamed to a timestamped backup under `~/Applications`.
- It does **not** change your active launchd jobs, Apple Reminders, iCloud settings, Notes, or iPhone Shortcuts.
- It does not clear memory, delete project files, or delete caches in the background.
- The app is signed locally *ad hoc*. Depending on your macOS privacy settings, a rebuilt binary may require allowing Reminders access again.

## Troubleshooting

- **Compiler failure:** Run `xcode-select -p`, `xcrun swiftc --version`, `xcrun --sdk macosx --show-sdk-path`; share the **first new error**. This build intentionally does **not** import SwiftUI.
- **Permissions:** System Settings → Privacy & Security → Reminders → enable **Mac AI Productivity Hub**.
- **Missing new iPhone tasks:** Open the actual Reminders app on Mac, wait for iCloud changes to appear, then click **Refresh** in the Hub.
- **Duplicate or overdue issues in older Python CLI:** The old CLI is a separate code path; use the new dashboard, which reads EventKit date components and handles date-only tasks correctly.
- **No diagnostic output:** Confirm `python3 --version`; task management works without Python being in the application PATH.

## Uninstall

Quit the app and move `~/Applications/Mac AI Productivity Hub.app` to Trash. Remove it from Login Items if added. This does not delete tasks or disable separate Python schedules.

## Swift 6 / AppKit build update (v0.3.1)

This revision fixes Swift 6 errors for the `@MainActor` delegate initializer,
optional `NSView` values in the view array, and optional reminder titles. The
installer compiles with `-parse-as-library` for the explicit `@main` entry point.
The app still requires a local Mac build with Apple's Command Line Tools;
this package was not compiled against a macOS SDK in the packaging environment.

If you want to fix an already extracted v0.3 copy, overwrite the two files
`native/AppKit/MacAIHub.swift` and `native/install_mac_app.sh` with their v0.3.1
versions, then rerun `./native/install_mac_app.sh`.
