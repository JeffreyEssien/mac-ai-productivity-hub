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
    private var overviewValues: [NSTextField] = []
    private var focusHeadline: NSTextField?
    private var focusDetail: NSTextField?
    private var compactStorage: NSTextField?
    private var compactPanel: NSPanel?
    private var compactSummary: NSTextField?
    private var compactNext: NSTextField?

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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Mac AI Productivity Hub"
        window.minSize = NSSize(width: 850, height: 650)
        window.center()
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = makeLabel("Your day, clearly organized", size: 26, bold: true)
        title.translatesAutoresizingMaskIntoConstraints = false
        stats = makeLabel("Connecting to Apple Reminders…", size: 13)
        stats.textColor = .secondaryLabelColor
        stats.translatesAutoresizingMaskIntoConstraints = false

        let newButton = NSButton(title: "New Task", target: self, action: #selector(newTask))
        newButton.bezelStyle = .rounded
        newButton.keyEquivalent = "n"
        newButton.keyEquivalentModifierMask = [.command]
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        let compactButton = NSButton(title: "Desktop Companion", target: self, action: #selector(showCompactPanel))
        let actions = NSStackView(views: [newButton, refreshButton, compactButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        // Overview cards: readable facts before the detailed task table.
        let overview = NSStackView()
        overview.orientation = .horizontal
        overview.distribution = .fillEqually
        overview.spacing = 12
        overview.translatesAutoresizingMaskIntoConstraints = false
        for heading in ["Open tasks", "Overdue", "Due today", "Free storage"] {
            let card = NSView()
            card.wantsLayer = true
            card.layer?.cornerRadius = 12
            card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            card.translatesAutoresizingMaskIntoConstraints = false
            let large = makeLabel("—", size: 21, bold: true)
            let small = makeLabel(heading, size: 11)
            small.textColor = .secondaryLabelColor
            large.translatesAutoresizingMaskIntoConstraints = false
            small.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(large)
            card.addSubview(small)
            overviewValues.append(large)
            NSLayoutConstraint.activate([
                card.heightAnchor.constraint(equalToConstant: 70),
                large.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
                large.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 13),
                small.topAnchor.constraint(equalTo: large.bottomAnchor, constant: 2),
                small.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 13)
            ])
            overview.addArrangedSubview(card)
        }

        // A primary focus card gives the dashboard a useful purpose beyond
        // duplicating the Apple Reminders list.
        let focusCard = NSView()
        focusCard.translatesAutoresizingMaskIntoConstraints = false
        focusCard.wantsLayer = true
        focusCard.layer?.cornerRadius = 14
        focusCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let focusKicker = makeLabel("YOUR NEXT STEP", size: 10, bold: true)
        focusKicker.textColor = .secondaryLabelColor
        focusKicker.translatesAutoresizingMaskIntoConstraints = false
        let focusHeadline = makeLabel("Loading your priorities…", size: 17, bold: true)
        focusHeadline.translatesAutoresizingMaskIntoConstraints = false
        let focusDetail = makeLabel("Your reminders stay in iCloud. Suggestions never change them.", size: 12)
        focusDetail.textColor = .secondaryLabelColor
        focusDetail.translatesAutoresizingMaskIntoConstraints = false
        let focusPlanButton = NSButton(title: "View Today’s Plan", target: self, action: #selector(showAIPlan))
        focusPlanButton.translatesAutoresizingMaskIntoConstraints = false
        for v in [focusKicker, focusHeadline, focusDetail, focusPlanButton] { focusCard.addSubview(v) }
        self.focusHeadline = focusHeadline
        self.focusDetail = focusDetail
        NSLayoutConstraint.activate([
            focusCard.heightAnchor.constraint(equalToConstant: 97),
            focusKicker.leadingAnchor.constraint(equalTo: focusCard.leadingAnchor, constant: 18),
            focusKicker.topAnchor.constraint(equalTo: focusCard.topAnchor, constant: 14),
            focusHeadline.leadingAnchor.constraint(equalTo: focusKicker.leadingAnchor),
            focusHeadline.topAnchor.constraint(equalTo: focusKicker.bottomAnchor, constant: 6),
            focusHeadline.trailingAnchor.constraint(lessThanOrEqualTo: focusPlanButton.leadingAnchor, constant: -14),
            focusDetail.leadingAnchor.constraint(equalTo: focusKicker.leadingAnchor),
            focusDetail.topAnchor.constraint(equalTo: focusHeadline.bottomAnchor, constant: 5),
            focusDetail.trailingAnchor.constraint(lessThanOrEqualTo: focusPlanButton.leadingAnchor, constant: -14),
            focusPlanButton.trailingAnchor.constraint(equalTo: focusCard.trailingAnchor, constant: -18),
            focusPlanButton.centerYAnchor.constraint(equalTo: focusCard.centerYAnchor)
        ])

        let healthButton = NSButton(title: "Mac Health", target: self, action: #selector(showDiagnostics))
        let cleanupButton = NSButton(title: "Review Cleanup", target: self, action: #selector(showCleanup))
        let aiButton = NSButton(title: "AI Setup", target: self, action: #selector(showAISetup))
        let reminderButton = NSButton(title: "Open Reminders", target: self, action: #selector(openReminders))
        let utilities = NSStackView(views: [healthButton, cleanupButton, aiButton, reminderButton])
        utilities.orientation = .horizontal
        utilities.spacing = 10
        utilities.translatesAutoresizingMaskIntoConstraints = false

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
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 32
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
        let contentViews: [NSView] = [title, stats!, actions, overview, focusCard, utilities, toolbar, scroller, bottomButtons, detail!]
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
            overview.topAnchor.constraint(equalTo: stats.bottomAnchor, constant: 12),
            overview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            overview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            focusCard.topAnchor.constraint(equalTo: overview.bottomAnchor, constant: 12),
            focusCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            focusCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            utilities.topAnchor.constraint(equalTo: focusCard.bottomAnchor, constant: 12),
            utilities.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            toolbar.topAnchor.constraint(equalTo: utilities.bottomAnchor, constant: 14),
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
            ("Review Cleanup", #selector(showCleanup(_:))),
            ("Today's Plan", #selector(showAIPlan(_:))),
            ("Set Up Apple Intelligence", #selector(showAISetup(_:))),
            ("Desktop Companion", #selector(showCompactPanel(_:))),
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
        stats.stringValue = "Changes synchronize through iCloud Reminders. Cleanup always asks for permission."
        if overviewValues.count == 4 {
            overviewValues[0].stringValue = String(openCount)
            overviewValues[1].stringValue = String(overdueCount)
            overviewValues[2].stringValue = String(todayCount)
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
               let free = attrs[.systemFreeSize] as? NSNumber {
                overviewValues[3].stringValue = String(format: "%.1f GB", free.doubleValue / 1e9)
            } else { overviewValues[3].stringValue = "—" }
        }
        updateFocusCard()
        updateCompactPanel()
        updateStatusBarTitle(open: openCount, overdue: overdueCount)
    }

    private func updateStatusBarTitle(open: Int, overdue: Int) {
        // Live glanceable counts next to the menu-bar icon; "!" flags overdue work.
        statusItem?.button?.title = overdue > 0 ? " \(open) · \(overdue)!" : " \(open)"
    }

    private func updateFocusCard() {
        let open = reminders.filter { !$0.isCompleted }
        let overdue = open.filter { reminderIsOverdue($0) }
        if let first = overdue.sorted(by: { (reminderDate($0) ?? .distantFuture) < (reminderDate($1) ?? .distantFuture) }).first {
            focusHeadline?.stringValue = first.title ?? "Review an overdue reminder"
            focusDetail?.stringValue = "Overdue · \(reminderDueLabel(first)). Your first priority is to review this task."
        } else if let next = open.filter({ reminderDate($0) != nil }).sorted(by: {
            (reminderDate($0) ?? .distantFuture) < (reminderDate($1) ?? .distantFuture)
        }).first {
            focusHeadline?.stringValue = next.title ?? "Upcoming reminder"
            focusDetail?.stringValue = "Next scheduled: \(reminderDueLabel(next)). Tap View Today’s Plan for a grouped review."
        } else if !open.isEmpty {
            focusHeadline?.stringValue = "Give your open tasks a clear deadline"
            focusDetail?.stringValue = "You have \(open.count) tasks without an upcoming scheduled deadline."
        } else {
            focusHeadline?.stringValue = "You're all caught up"
            focusDetail?.stringValue = "No outstanding reminders. Add something when you're ready."
        }
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

    // MARK: - JSON-backed, read-only system diagnostics and safe cleanup

    private func service(_ parameters: [String]) -> [String: Any]? {
        guard let backend = Bundle.main.resourceURL?.appendingPathComponent("Backend") else { return nil }
        let source = backend.appendingPathComponent("hub_services.py")
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", source.path] + parameters
        process.currentDirectoryURL = backend
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let raw = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
            return json
        } catch { return nil }
    }

    private func serviceData(_ parameters: [String]) -> [String: Any]? {
        guard let response = service(parameters) else {
            alert("Feature unavailable", "The Python helper couldn't run. Confirm Python 3 is installed and reinstall the latest Hub version.")
            return nil
        }
        guard response["ok"] as? Bool == true else {
            alert("Couldn't finish", response["error"] as? String ?? "Please try again.")
            return nil
        }
        return response["data"] as? [String: Any]
    }

    private func presentReadableReport(_ title: String, _ content: String) {
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = "A plain-English report. Nothing is deleted automatically."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 610, height: 340))
        scroll.hasVerticalScroller = true
        let field = NSTextView(frame: scroll.bounds)
        field.isEditable = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 14)
        field.textContainerInset = NSSize(width: 12, height: 12)
        field.string = content
        scroll.documentView = field
        dialog.accessoryView = scroll
        dialog.addButton(withTitle: "Close")
        dialog.runModal()
    }

    @objc private func showDiagnostics(_ sender: Any?) {
        guard let data = serviceData(["health"]) else { return }
        let disk = data["disk"] as? [String: Any] ?? [:]
        let free = disk["free_gb"] as? Double ?? 0
        let total = disk["total_gb"] as? Double ?? 0
        let swap = data["swap_gb"] as? Double
        let ram = data["total_ram_gb"] as? Double
        let apps = (data["top_apps"] as? [[String: Any]] ?? []).prefix(5)
            .map { "• \($0["name"] as? String ?? "App"): \($0["memory_mb"] as? Int ?? 0) MB of memory" }
            .joined(separator: "\n")
        let report = """
        STORAGE
        \(data["storage_status"] as? String ?? "Unknown storage status")
        \(String(format: "%.1f", free)) GB free out of \(String(format: "%.0f", total)) GB.

        MEMORY
        Installed RAM: \(ram.map { String(format: "%.1f GB", $0) } ?? "Unavailable")
        Swap currently used: \(swap.map { String(format: "%.1f GB", $0) } ?? "Unavailable")
        \(data["memory_status"] as? String ?? "Not assessed")

        APPS USING THE MOST MEMORY
        \(apps.isEmpty ? "No process information available." : apps)

        WHAT TO DO
        • Quit apps you aren't using if your Mac feels sluggish.
        • Open Review Cleanup to inspect old screenshots and installers.
        • Use Activity Monitor’s Memory Pressure graph to confirm RAM pressure.
        • Do not delete system data, application databases, or swap files.

        Nothing was deleted, closed, or modified.
        """
        presentReadableReport("Mac Health, explained", report)
    }

    @objc private func showCleanup(_ sender: Any?) {
        guard let scan = serviceData(["scan"]) else { return }
        let candidates = scan["candidates"] as? [[String: Any]] ?? []
        let reports = scan["report_only"] as? [[String: Any]] ?? []
        guard !candidates.isEmpty else {
            let biggest = reports.prefix(4).map { "• \($0["name"] as? String ?? "App"): \($0["size"] as? String ?? "")" }.joined(separator: "\n")
            alert("Nothing safe to remove right now", "No screenshots or installer files meet the configured age limits.\n\nOther large folders are report-only:\n" + biggest)
            return
        }
        // All checkboxes start unchecked. Nothing moves until the user selects
        // files AND confirms the final batch. This path is never run by launchd.
        let shown = Array(candidates.prefix(120))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        var selections: [(NSButton, [String: Any])] = []
        for candidate in shown {
            let label = candidate["label"] as? String ?? "File"
            let name = candidate["name"] as? String ?? "Unknown file"
            let size = candidate["size"] as? String ?? ""
            let check = NSButton(checkboxWithTitle: "\(label) · \(name) (\(size))", target: nil, action: nil)
            check.state = .off
            check.toolTip = candidate["path"] as? String
            check.font = NSFont.systemFont(ofSize: 12)
            check.cell?.lineBreakMode = .byTruncatingMiddle
            check.widthAnchor.constraint(equalToConstant: 555).isActive = true
            stack.addArrangedSubview(check)
            selections.append((check, candidate))
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 575, height: 330))
        scroll.hasVerticalScroller = true
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 570, height: CGFloat(max(330, 34 * shown.count))))
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -8)
        ])
        scroll.documentView = box
        let review = NSAlert()
        review.messageText = "Review old files — nothing selected"
        review.informativeText = "Select only files you want to move to Trash. Browser profiles, projects, Application Support and Docker volumes are excluded."
        review.accessoryView = scroll
        review.addButton(withTitle: "Review Selected")
        review.addButton(withTitle: "Cancel")
        guard review.runModal() == .alertFirstButtonReturn else { return }
        let selected = selections.filter { $0.0.state == .on }.map { $0.1 }
        guard !selected.isEmpty else { alert("No changes made", "You didn't select any files."); return }
        let bytes = selected.reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) }
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Move \(selected.count) selected files to Trash?"
        confirm.informativeText = "Approximately \(String(format: "%.1f MB", Double(bytes) / 1048576)) in selected files. You can restore files from Trash. Storage isn't freed until Trash is emptied."
        confirm.addButton(withTitle: "Move to Trash")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        var moved = 0
        var failed = 0
        for item in selected {
            guard let token = item["fingerprint"] as? String else { failed += 1; continue }
            let result = service(["trash", token])
            if result?["ok"] as? Bool == true { moved += 1 } else { failed += 1 }
        }
        alert("Cleanup complete", "\(moved) items moved to Trash. \(failed) could not be moved or changed before cleanup. Nothing was permanently deleted.\n\nBrowser and Spotify caches remain review-only. pip and Homebrew require their own separate native cleanup commands.")
        refresh(nil)
    }

    // MARK: - Typed Apple Intelligence handoff (plus reliable offline fallback)

    private func basicPlan() -> String {
        let open = reminders.filter { !$0.isCompleted }
        let overdue = open.filter { reminderIsOverdue($0) }
        let today = open.filter { item in
            guard let due = reminderDate(item) else { return false }
            return !reminderIsOverdue(item) && Calendar.current.isDateInToday(due)
        }
        let later = open.filter { item in
            guard let due = reminderDate(item) else { return false }
            return !reminderIsOverdue(item) && !Calendar.current.isDateInToday(due)
        }
        let unscheduled = open.filter { reminderDate($0) == nil }

        func lines(_ items: [EKReminder]) -> String {
            if items.isEmpty { return "Nothing in this group." }
            let sorted = items.sorted {
                (reminderDate($0) ?? .distantFuture) < (reminderDate($1) ?? .distantFuture)
            }
            let preview = sorted.prefix(8).map {
                "• \($0.title ?? "Untitled") — \(reminderDueLabel($0))"
            }.joined(separator: "\n")
            let remaining = sorted.count - min(sorted.count, 8)
            return preview + (remaining > 0 ? "\n…and \(remaining) more in Apple Reminders." : "")
        }
        return """
        This is a RULES-BASED REVIEW (no AI model was used).
        It organizes real reminders by their stored due dates. It does not change anything.

        OVERDUE — REVIEW FIRST (\(overdue.count))
        \(lines(overdue))

        DUE TODAY (\(today.count))
        \(lines(today))

        COMING UP (\(later.count))
        \(lines(later))

        NO DEADLINE (\(unscheduled.count))
        \(lines(unscheduled))

        TIP
        Start with an urgent task you can realistically finish. Use Apple Reminders to edit or complete tasks.
        """
    }

    private func showBasicPlan() {
        presentReadableReport("Your plan — no AI required", basicPlan())
    }

    @objc private func showAISetup(_ sender: Any?) {
        let guide = """
        CONNECT APPLE INTELLIGENCE TO THIS MAC

        1. Open the Shortcuts app on your Mac.
        2. Create a NEW shortcut named exactly:
           Mac Hub AI Plan
        3. Add an action that reads the Shortcut Input as text (or Get Text from Input).
        4. Add Use Model. Choose On-Device Apple Intelligence if supported and enabled.
        5. In the model prompt, insert Shortcut Input and instruct it to:
           Group tasks into Do first / Today / Later / No deadline.
           Never invent due dates or change reminders. Return plain text.
        6. Turn OFF Follow Up, and connect Response to Stop and Output.
        7. Test it inside Shortcuts with a small example task list.
        8. Return to the Hub and select View Today’s Plan.

        IMPORTANT
        The Shortcut must receive input and RETURN text. An action that only displays text won't supply a response to this app.
        The Hub asks before passing reminder titles to the Shortcut. Your selected model determines whether any data is processed in the cloud.

        You can use the no-AI plan before this is configured.
        """
        presentReadableReport("One-time AI setup", guide)
        let action = NSAlert()
        action.messageText = "Open Shortcuts now?"
        action.informativeText = "Create and test Mac Hub AI Plan. Return here when it works."
        action.addButton(withTitle: "Open Shortcuts")
        action.addButton(withTitle: "Not Now")
        if action.runModal() == .alertFirstButtonReturn {
            let url = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAIPlan(_ sender: Any?) {
        guard granted else {
            alert("Reminders access needed", "Allow Reminders access in System Settings first.")
            return
        }
        let tasks = reminders.filter { !$0.isCompleted }.sorted {
            (reminderDate($0) ?? .distantFuture) < (reminderDate($1) ?? .distantFuture)
        }
        guard !tasks.isEmpty else {
            alert("You're up to date", "You have no outstanding reminders to plan around.")
            return
        }
        // Check the Shortcuts app BEFORE requesting personal task data.
        // If it is not configured, offer a useful deterministic fallback.
        let status = service(["ai_status"])
        let found = (status?["data"] as? [String: Any])?["installed"] as? Bool ?? false
        if !found {
            let dialog = NSAlert()
            dialog.messageText = "Apple Intelligence isn't connected yet"
            dialog.informativeText = "Your task list is already available. Set up the Mac Hub AI Plan Shortcut for AI suggestions, or view your deadlines now without AI."
            dialog.addButton(withTitle: "View Basic Plan")
            dialog.addButton(withTitle: "Set Up AI")
            dialog.addButton(withTitle: "Cancel")
            let answer = dialog.runModal()
            if answer == .alertFirstButtonReturn { showBasicPlan() }
            else if answer == .alertSecondButtonReturn { showAISetup(nil) }
            return
        }
        let consent = NSAlert()
        consent.messageText = "Create a plan with Apple Intelligence?"
        consent.informativeText = "The Hub will send your open reminder titles, due dates and list names to your Mac Hub AI Plan Shortcut. Choose the On-Device model there to keep processing local. No reminders will be edited."
        consent.addButton(withTitle: "Generate AI Plan")
        consent.addButton(withTitle: "View Basic Plan")
        consent.addButton(withTitle: "Cancel")
        let approval = consent.runModal()
        if approval == .alertSecondButtonReturn { showBasicPlan(); return }
        guard approval == .alertFirstButtonReturn else { return }
        let lines = tasks.prefix(50).map { item in
            let status = reminderIsOverdue(item) ? "Overdue" : "Open"
            return "• [\(status)] \(item.title ?? "Untitled") | \(reminderDueLabel(item)) | \(item.calendar.title)"
        }.joined(separator: "\n")
        let text = """
        You are a productivity planning assistant. Provide brief, practical plain-English advice.
        Group tasks into: Do first, Do later today, Schedule later, and Missing due dates.
        Respect listed due dates. Do not fabricate times, calendar availability, or completions.
        Never edit reminders or delete files. Your output is suggestions only.
        Current date and time: \(Date().formatted())
        Open reminders:
        \(lines)
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hub-ai-" + UUID().uuidString + ".txt")
        do {
            try text.write(to: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        } catch {
            alert("Couldn't prepare your plan", error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = service(["ai", tmp.path])
        if result?["ok"] as? Bool == true,
           let data = result?["data"] as? [String: Any],
           let summary = data["summary"] as? String, !summary.isEmpty {
            presentReadableReport("Your AI suggested plan", summary)
            return
        }
        let failure = NSAlert()
        failure.messageText = "Your AI Shortcut needs attention"
        failure.informativeText = "It exists but did not return a usable text response. Check that Use Model is connected to Stop and Output, and turn Follow Up off."
        failure.addButton(withTitle: "View Basic Plan")
        failure.addButton(withTitle: "See Setup Steps")
        failure.addButton(withTitle: "Cancel")
        let answer = failure.runModal()
        if answer == .alertFirstButtonReturn { showBasicPlan() }
        else if answer == .alertSecondButtonReturn { showAISetup(nil) }
    }

    private func updateCompactPanel() {
        guard let summary = compactSummary, let next = compactNext else { return }
        let open = reminders.filter { !$0.isCompleted }
        let overdue = open.filter { reminderIsOverdue($0) }.count
        summary.stringValue = "\(open.count) open  ·  \(overdue) overdue"
        let upcoming = open.filter { reminderDate($0) != nil }.sorted {
            (reminderDate($0) ?? .distantFuture) < (reminderDate($1) ?? .distantFuture)
        }
        if let first = upcoming.first {
            next.stringValue = "NEXT TASK\n\(first.title ?? "Untitled")\n\(reminderDueLabel(first))"
        } else {
            next.stringValue = open.isEmpty ? "You're all caught up." : "No upcoming timed deadlines."
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            compactStorage?.stringValue = String(format: "Free disk space: %.1f GB", free.doubleValue / 1e9)
        } else { compactStorage?.stringValue = "Storage information unavailable" }
    }

    @objc private func showCompactPanel(_ sender: Any?) {
        if compactPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 290),
                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Mac Hub · Desktop Companion"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            let surface = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: 290))
            surface.material = .sidebar
            surface.blendingMode = .behindWindow
            surface.state = .active
            let heading = makeLabel("Your Day", size: 21, bold: true)
            heading.frame = NSRect(x: 20, y: 237, width: 330, height: 30)
            let totals = makeLabel("Loading…", size: 13, bold: true)
            totals.frame = NSRect(x: 20, y: 210, width: 330, height: 24)
            let next = NSTextField(wrappingLabelWithString: "")
            next.font = NSFont.systemFont(ofSize: 13)
            next.maximumNumberOfLines = 3
            next.frame = NSRect(x: 20, y: 112, width: 335, height: 86)
            let storage = makeLabel("Checking storage…", size: 12)
            storage.textColor = .secondaryLabelColor
            storage.frame = NSRect(x: 20, y: 91, width: 335, height: 21)
            let add = NSButton(title: "Add Task", target: self, action: #selector(newTask))
            add.frame = NSRect(x: 20, y: 48, width: 102, height: 29)
            let plan = NSButton(title: "Today's Plan", target: self, action: #selector(showAIPlan))
            plan.frame = NSRect(x: 131, y: 48, width: 112, height: 29)
            let dashboard = NSButton(title: "Dashboard", target: self, action: #selector(showDashboard))
            dashboard.frame = NSRect(x: 252, y: 48, width: 108, height: 29)
            let cleanup = NSButton(title: "Review Cleanup", target: self, action: #selector(showCleanup))
            cleanup.frame = NSRect(x: 20, y: 12, width: 132, height: 26)
            let health = NSButton(title: "Mac Health", target: self, action: #selector(showDiagnostics))
            health.frame = NSRect(x: 161, y: 12, width: 118, height: 26)
            for view in [heading, totals, next, storage, add, plan, dashboard, cleanup, health] {
                surface.addSubview(view)
            }
            panel.contentView = surface
            panel.setFrameAutosaveName("MacAIHubCompanionPanel")
            panel.center()
            compactSummary = totals
            compactNext = next
            compactStorage = storage
            compactPanel = panel
        }
        updateCompactPanel()
        compactPanel?.makeKeyAndOrderFront(nil)
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
