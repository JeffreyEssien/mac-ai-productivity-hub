import AppKit
import EventKit
import Foundation

// A native AppKit front end, intentionally free of SwiftUI and compiler macros.
// EventKit is the task database. The bundled Python scripts remain read-only
// for their scheduled diagnostics unless manually approved in Terminal.

private func reminderDate(_ item: EKReminder) -> Date? {
    guard let parts = item.dueDateComponents else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = parts.timeZone ?? .current
    return calendar.date(from: parts)
}

private func reminderHasTime(_ item: EKReminder) -> Bool {
    item.dueDateComponents?.hour != nil && item.dueDateComponents?.minute != nil
}

private func reminderIsOverdue(_ item: EKReminder, now: Date = Date()) -> Bool {
    guard !item.isCompleted, let due = reminderDate(item) else { return false }
    let cal = Calendar.current
    if reminderHasTime(item) { return due < now }
    return cal.startOfDay(for: due) < cal.startOfDay(for: now)
}

private func reminderDueLabel(_ item: EKReminder) -> String {
    guard let due = reminderDate(item) else { return "No due date" }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = reminderHasTime(item) ? .short : .none
    return formatter.string(from: due)
}

private func normalizedTitle(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
}

// Carbon four-char codes for the Get-URL Apple Event, so we avoid `import Carbon`.
// 'GURL' is both the event class and id; keyDirectObject is '----'.
private let kGURLFourCC: UInt32 = 0x4755524C          // 'GURL'
private let kDirectObjectFourCC: AEKeyword = 0x2D2D2D2D // '----'

// macaihub://<host> opens the app to a tab. Host names map to the tab order.
private let tabHostIndex: [String: Int] = [
    "all": 0, "today": 1, "overdue": 2, "upcoming": 3, "nodue": 4, "completed": 5
]

// EKReminder.title is an implicitly-unwrapped String!; a reminder synced or
// created by another app can have a nil title. Always read it through here so
// search, sort, and dedupe never force-unwrap a nil.
private func reminderTitle(_ item: EKReminder) -> String {
    item.title ?? ""
}

@MainActor
final class MacHub: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store = EKEventStore()
    private var calendars: [EKCalendar] = []
    private var reminders: [EKReminder] = []
    private var visible: [EKReminder] = []
    private var generation = 0
    private var granted = false
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var table: NSTableView!
    private var tabs: NSPopUpButton!
    private var search: NSSearchField!
    private var stats: NSTextField!
    private var detail: NSTextField!
    private var quickDatePicker: NSDatePicker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        createWindow()
        createMenuBar()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
            name: .EKEventStoreChanged, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        NSAppleEventManager.shared().setEventHandler(self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kGURLFourCC), andEventID: AEEventID(kGURLFourCC))
        requestRemindersAccess()
        showDashboard(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func makeLabel(_ value: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 630),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Mac AI Productivity Hub"
        window.minSize = NSSize(width: 710, height: 480)
        window.center()
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = makeLabel("Your tasks", size: 25, bold: true)
        title.translatesAutoresizingMaskIntoConstraints = false
        stats = makeLabel("Connecting to Apple Reminders…", size: 13)
        stats.textColor = .secondaryLabelColor
        stats.translatesAutoresizingMaskIntoConstraints = false

        let newButton = NSButton(title: "New Task", target: self, action: #selector(newTask))
        newButton.bezelStyle = .rounded
        newButton.keyEquivalent = "n"
        newButton.keyEquivalentModifierMask = [.command]
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        let reminderButton = NSButton(title: "Open Reminders", target: self, action: #selector(openReminders))
        let diagButton = NSButton(title: "Mac Health", target: self, action: #selector(showDiagnostics))
        let actions = NSStackView(views: [newButton, refreshButton, reminderButton, diagButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        tabs = NSPopUpButton()
        tabs.addItems(withTitles: ["All Open", "Today", "Overdue", "Upcoming", "No Due Date", "Completed"])
        tabs.target = self
        tabs.action = #selector(updateVisible)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        search = NSSearchField()
        search.placeholderString = "Search existing reminders"
        search.target = self
        search.action = #selector(updateVisible)
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false
        let toolbar = NSStackView(views: [tabs, search])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        toolbar.distribution = .fill
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        tabs.widthAnchor.constraint(equalToConstant: 160).isActive = true

        table = NSTableView()
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(editTask)
        for (id, label, width) in [("title", "Task", 390.0), ("due", "Due", 190.0), ("list", "List", 160.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = label
            column.width = width
            column.minWidth = 110
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        let scroller = NSScrollView()
        scroller.documentView = table
        scroller.hasVerticalScroller = true
        scroller.borderType = .bezelBorder
        scroller.translatesAutoresizingMaskIntoConstraints = false

        let editButton = NSButton(title: "Edit Selected", target: self, action: #selector(editTask))
        let completeButton = NSButton(title: "Toggle Complete", target: self, action: #selector(toggleComplete))
        let snoozeDayButton = NSButton(title: "Snooze +1 day", target: self, action: #selector(snoozeOneDay))
        let snoozeWeekButton = NSButton(title: "Snooze +1 week", target: self, action: #selector(snoozeOneWeek))
        let bottomButtons = NSStackView(views: [editButton, completeButton, snoozeDayButton, snoozeWeekButton])
        bottomButtons.orientation = .horizontal
        bottomButtons.spacing = 8
        bottomButtons.translatesAutoresizingMaskIntoConstraints = false
        detail = makeLabel("Select a task to edit or mark complete. Your iPhone syncs through iCloud.")
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false

        // Both implicitly unwrapped outlets have been initialized above.
        // Explicitly use NSView so Swift does not infer an [NSView?] array.
        let contentViews: [NSView] = [title, stats!, actions, toolbar, scroller, bottomButtons, detail!]
        for view in contentViews {
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            actions.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 20),
            stats.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            stats.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stats.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            toolbar.topAnchor.constraint(equalTo: stats.bottomAnchor, constant: 20),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroller.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            scroller.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroller.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroller.bottomAnchor.constraint(equalTo: bottomButtons.topAnchor, constant: -12),
            bottomButtons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            bottomButtons.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
    }

    private func createMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Productivity Hub")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        for (title, selector) in [
            ("Open Dashboard", #selector(showDashboard(_:))),
            ("New Task", #selector(newTask(_:))),
            ("Refresh Reminders", #selector(refresh(_:))),
            ("Mac Health", #selector(showDiagnostics(_:))),
            ("Open Apple Reminders", #selector(openReminders(_:)))
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func quitApp(_ sender: Any?) { NSApp.terminate(nil) }
    @objc private func showDashboard(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openReminders(_ sender: Any?) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: kDirectObjectFourCC)?.stringValue,
              let url = URL(string: raw) else { return }
        selectTab(host: url.host ?? "")
        showDashboard(nil)
    }

    private func selectTab(host: String) {
        let index = tabHostIndex[host.lowercased()] ?? 0
        guard index < tabs.numberOfItems else { return }
        tabs.selectItem(at: index)
        updateVisible(nil)
    }

    private func requestRemindersAccess() {
        store.requestFullAccessToReminders { [weak self] allowed, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.granted = allowed
                if allowed { self.refresh(nil) }
                else {
                    self.stats.stringValue = "Reminders permission needed. System Settings → Privacy & Security → Reminders."
                    self.alert("Reminders access required", error?.localizedDescription ?? "Allow access in System Settings → Privacy & Security → Reminders, then restart this app.")
                }
            }
        }
    }

    @objc private func refresh(_ sender: Any? = nil) {
        guard granted else { return }
        generation += 1
        let token = generation
        calendars = store.calendars(for: .reminder).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        guard !calendars.isEmpty else {
            reminders = []
            updateVisible(nil)
            stats.stringValue = "No Reminders lists found. Make sure iCloud Reminders is enabled."
            return
        }
        stats.stringValue = "Loading your reminders…"
        store.fetchReminders(matching: store.predicateForReminders(in: calendars)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.reminders = result ?? []
                self.updateVisible(nil)
            }
        }
    }

    @objc private func updateVisible(_ sender: Any? = nil) {
        let now = Date()
        let category = tabs.indexOfSelectedItem
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = reminders.filter { item in
            if !query.isEmpty && !reminderTitle(item).localizedCaseInsensitiveContains(query) { return false }
            let due = reminderDate(item)
            switch category {
            case 1: return !item.isCompleted && due.map { Calendar.current.isDateInToday($0) } == true
            case 2: return reminderIsOverdue(item)
            case 3: return !item.isCompleted && due.map { $0 > now && !Calendar.current.isDateInToday($0) } == true
            case 4: return !item.isCompleted && due == nil
            case 5: return item.isCompleted
            default: return !item.isCompleted
            }
        }.sorted { a, b in
            let da = reminderDate(a) ?? Date.distantFuture
            let db = reminderDate(b) ?? Date.distantFuture
            if da != db { return da < db }
            return reminderTitle(a).localizedCaseInsensitiveCompare(reminderTitle(b)) == .orderedAscending
        }
        table.reloadData()
        let openCount = reminders.filter { !$0.isCompleted }.count
        let overdueCount = reminders.filter { reminderIsOverdue($0) }.count
        let todayCount = reminders.filter { !$0.isCompleted && reminderDate($0).map { Calendar.current.isDateInToday($0) } == true }.count
        stats.stringValue = "\(openCount) open   ·   \(overdueCount) overdue   ·   \(todayCount) due today   ·   \(visible.count) shown"
        updateStatusBarTitle(open: openCount, overdue: overdueCount)
    }

    private func updateStatusBarTitle(open: Int, overdue: Int) {
        // Live glanceable counts next to the menu-bar icon; "!" flags overdue work.
        statusItem?.button?.title = overdue > 0 ? " \(open) · \(overdue)!" : " \(open)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visible.count, let tableColumn else { return nil }
        let item = visible[row]
        let text: String
        switch tableColumn.identifier.rawValue {
        case "due": text = reminderDueLabel(item)
        case "list": text = item.calendar.title
        default:
            let raw = reminderTitle(item)
            let taskTitle = raw.isEmpty ? "(Untitled reminder)" : raw
            text = item.isCompleted ? "✓  \(taskTitle)" : taskTitle
        }
        let view = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        if reminderIsOverdue(item) && tableColumn.identifier.rawValue == "due" { field.textColor = .systemRed }
        view.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        return view
    }

    private func selectedReminder() -> EKReminder? {
        guard table.selectedRow >= 0, table.selectedRow < visible.count else { return nil }
        return visible[table.selectedRow]
    }

    private func alert(_ title: String, _ description: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = description
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func newTask(_ sender: Any?) { editReminder(nil) }
    @objc private func editTask(_ sender: Any?) {
        guard let item = selectedReminder() else { alert("Select a reminder", "Choose a row to edit."); return }
        editReminder(item)
    }

    @objc private func toggleComplete(_ sender: Any?) {
        guard let item = selectedReminder() else { alert("Select a reminder", "Choose a row to mark complete."); return }
        let current = (store.calendarItem(withIdentifier: item.calendarItemIdentifier) as? EKReminder) ?? item
        current.isCompleted = !current.isCompleted
        do { try store.save(current, commit: true); refresh(nil) }
        catch { alert("Couldn't save", error.localizedDescription) }
    }

    @objc private func snoozeOneDay(_ sender: Any?) { snooze(byDays: 1) }
    @objc private func snoozeOneWeek(_ sender: Any?) { snooze(byDays: 7) }

    private func snooze(byDays days: Int) {
        guard let item = selectedReminder() else { alert("Select a reminder", "Choose a row to snooze."); return }
        let live = (store.calendarItem(withIdentifier: item.calendarItemIdentifier) as? EKReminder) ?? item
        let cal = Calendar.current
        let hadTime = reminderHasTime(live)
        let oldDate = reminderDate(live)
        // No due date yet? Anchor to 9am today so +1 day / +1 week still make sense.
        let base = oldDate ?? cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        guard let shifted = cal.date(byAdding: .day, value: days, to: base) else { return }
        var comps = cal.dateComponents([.year, .month, .day], from: shifted)
        if hadTime {
            let clock = cal.dateComponents([.hour, .minute], from: shifted)
            comps.hour = clock.hour
            comps.minute = clock.minute
        }
        comps.timeZone = TimeZone.current
        live.dueDateComponents = comps
        if hadTime {
            if let old = oldDate {
                for alarm in live.alarms ?? [] where alarm.absoluteDate.map({ abs($0.timeIntervalSince(old)) < 60 }) == true {
                    live.removeAlarm(alarm)
                }
            }
            if let newDate = cal.date(from: comps) { live.addAlarm(EKAlarm(absoluteDate: newDate)) }
        }
        do { try store.save(live, commit: true); refresh(nil) }
        catch { alert("Couldn't snooze", error.localizedDescription) }
    }

    @objc private func quickSelectDate(_ sender: NSSegmentedControl) {
        guard let picker = quickDatePicker else { return }
        let addition: Int
        switch sender.selectedSegment { case 1: addition = 1; case 2: addition = 7; default: addition = 0 }
        let currentTime = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        let start = Calendar.current.startOfDay(for: Date())
        if let day = Calendar.current.date(byAdding: .day, value: addition, to: start),
           let updated = Calendar.current.date(bySettingHour: currentTime.hour ?? 9,
                minute: currentTime.minute ?? 0, second: 0, of: day) {
            picker.dateValue = updated
        }
    }

    private func editReminder(_ original: EKReminder?) {
        guard granted else { alert("Permission required", "Enable Reminders access first."); return }
        let writable = calendars.filter { $0.allowsContentModifications }
        guard !writable.isEmpty else { alert("No writable list", "Create an iCloud Reminders list, then refresh."); return }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 380))
        let name = NSTextField(frame: NSRect(x: 135, y: 344, width: 370, height: 25))
        name.placeholderString = "What do you need to do?"
        name.stringValue = original?.title ?? ""
        let listMenu = NSPopUpButton(frame: NSRect(x: 135, y: 306, width: 370, height: 26))
        for list in writable { listMenu.addItem(withTitle: "\(list.title) (\(list.source.title))") }
        let initialListID = original?.calendar.calendarIdentifier ?? store.defaultCalendarForNewReminders()?.calendarIdentifier
        if let idx = writable.firstIndex(where: { $0.calendarIdentifier == initialListID }) { listMenu.selectItem(at: idx) }
        let hasDue = NSButton(checkboxWithTitle: "Set due date", target: nil, action: nil)
        hasDue.frame = NSRect(x: 135, y: 269, width: 180, height: 24)
        hasDue.state = original?.dueDateComponents == nil ? .off : .on
        let hasTime = NSButton(checkboxWithTitle: "Remind at a specific time", target: nil, action: nil)
        hasTime.frame = NSRect(x: 135, y: 243, width: 265, height: 24)
        hasTime.state = original.map { reminderHasTime($0) } == true ? .on : .off
        let quick = NSSegmentedControl(labels: ["Today", "Tomorrow", "Next Week"], trackingMode: .selectOne, target: self, action: #selector(quickSelectDate))
        quick.frame = NSRect(x: 135, y: 209, width: 370, height: 27)
        let picker = NSDatePicker(frame: NSRect(x: 135, y: 4, width: 360, height: 196))
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = original.flatMap { reminderDate($0) } ?? Date()
        quickDatePicker = picker
        for (label, y) in [("Task", 345.0), ("Reminders List", 309.0), ("Deadline", 271.0)] {
            let text = makeLabel(label)
            text.frame = NSRect(x: 0, y: y, width: 126, height: 21)
            box.addSubview(text)
        }
        for view in [name, listMenu, hasDue, hasTime, quick, picker] { box.addSubview(view) }
        let dialog = NSAlert()
        dialog.messageText = original == nil ? "Add Reminder" : "Edit Reminder"
        dialog.informativeText = "Tasks use your existing Apple Reminders lists and synchronize through iCloud."
        dialog.accessoryView = box
        dialog.addButton(withTitle: original == nil ? "Add Task" : "Save Changes")
        dialog.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let chosen = dialog.runModal()
        quickDatePicker = nil
        guard chosen == .alertFirstButtonReturn else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty && title.count <= 250 else {
            alert("Invalid task name", "Enter a task between 1 and 250 characters.")
            return
        }
        let idx = listMenu.indexOfSelectedItem
        guard idx >= 0 && idx < writable.count else { alert("Choose a list", "Select a writable Reminders list."); return }
        let selectedList = writable[idx]
        if original == nil && reminders.contains(where: {
            !$0.isCompleted && $0.calendar.calendarIdentifier == selectedList.calendarIdentifier &&
            normalizedTitle(reminderTitle($0)) == normalizedTitle(title)
        }) {
            alert("Possible duplicate", "This list already contains an incomplete reminder with the same title. No new reminder was created.")
            return
        }
        guard let item = original.flatMap({ store.calendarItem(withIdentifier: $0.calendarItemIdentifier) as? EKReminder })
            ?? (original == nil ? EKReminder(eventStore: store) : nil) else {
            alert("Reminder changed", "The reminder is no longer available. Refresh and try again.")
            return
        }
        let oldDate = reminderDate(item)
        let oldHadTime = reminderHasTime(item)
        let previousDue = item.dueDateComponents
        item.title = title
        item.calendar = selectedList
        if hasDue.state == .on {
            var due = Calendar.current.dateComponents([.year, .month, .day], from: picker.dateValue)
            if hasTime.state == .on {
                let clock = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
                due.hour = clock.hour
                due.minute = clock.minute
            }
            due.timeZone = TimeZone.current
            item.dueDateComponents = due
        } else { item.dueDateComponents = nil }
        if previousDue != item.dueDateComponents {
            if oldHadTime, let oldDate {
                for alarm in item.alarms ?? [] {
                    if let exact = alarm.absoluteDate, abs(exact.timeIntervalSince(oldDate)) < 60 { item.removeAlarm(alarm) }
                }
            }
            if hasDue.state == .on && hasTime.state == .on {
                let newDue = picker.dateValue
                if !(item.alarms ?? []).contains(where: { $0.absoluteDate.map { abs($0.timeIntervalSince(newDue)) < 60 } == true }) {
                    item.addAlarm(EKAlarm(absoluteDate: newDue))
                }
            }
        }
        do { try store.save(item, commit: true); refresh(nil) }
        catch { alert("Couldn't save reminder", error.localizedDescription) }
    }

    @objc private func showDiagnostics(_ sender: Any?) {
        guard let backend = Bundle.main.resourceURL?.appendingPathComponent("Backend") else {
            alert("Unavailable", "The Python backend was not bundled.")
            return
        }
        let commands: [(String, [String])] = [
            ("RAM and CPU", ["performance_monitor.py"]),
            ("Storage scan", ["storage_manager.py", "scan"])
        ]
        var output = ""
        for (title, args) in commands {
            let source = backend.appendingPathComponent(args[0])
            guard FileManager.default.fileExists(atPath: source.path) else {
                output += "\n\(title): Optional diagnostic unavailable.\n"
                continue
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["python3", source.path] + Array(args.dropFirst())
            task.currentDirectoryURL = backend
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            task.environment = env
            let combined = Pipe()
            task.standardOutput = combined
            task.standardError = combined
            do {
                try task.run()
                let data = combined.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                output += "\n=== \(title) ===\n" + String(String(decoding: data, as: UTF8.self).prefix(12000)) + "\n"
            } catch {
                output += "\n\(title): \(error.localizedDescription)\n"
            }
        }
        let dialog = NSAlert()
        dialog.messageText = "Mac Health & Storage"
        dialog.informativeText = "Read-only diagnostics. No files or processes were deleted."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 340))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = output.isEmpty ? "No diagnostic output available." : output
        scroll.documentView = text
        dialog.accessoryView = scroll
        dialog.addButton(withTitle: "Close")
        dialog.runModal()
    }
}

// Swift 6 enforces main-actor isolation for AppKit application delegates.
// An explicit entry point keeps initialization and the event loop on MainActor.
@main
struct MacAIHubEntryPoint {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = MacHub()
        app.delegate = delegate
        app.run()
    }
}
