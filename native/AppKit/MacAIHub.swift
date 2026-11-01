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

// SF Symbol drawn in a fixed colour (hierarchical rendering, so layered symbols
// keep their depth), which keeps its tint inside buttons and image views.
private func symbolImage(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

// A Reminders-style smart-list tile: coloured badge, live count and name.
@MainActor
final class SmartListTile: NSView {
    var onClick: (() -> Void)?
    var count = 0 { didSet { countLabel.stringValue = "\(count)" } }
    var isSelected = false { didSet { applyStyle() } }
    private let color: NSColor
    private let symbol: String
    private let badge = NSView()
    private let icon = NSImageView()
    private let countLabel = NSTextField(labelWithString: "0")
    private let nameLabel: NSTextField

    init(title: String, symbol: String, color: NSColor) {
        self.color = color
        self.symbol = symbol
        nameLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 13
        countLabel.font = .systemFont(ofSize: 22, weight: .bold)
        countLabel.alignment = .right
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        for view in [badge, icon, countLabel, nameLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            countLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        // Layer colours are CGColors, so resolve the dynamic NSColors for light/dark first.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected ? color : NSColor.controlBackgroundColor).cgColor
            badge.layer?.backgroundColor = (isSelected ? NSColor.white : color).cgColor
        }
        icon.image = symbolImage(symbol, size: 12, color: isSelected ? color : .white, weight: .bold)
        countLabel.textColor = isSelected ? .white : .labelColor
        nameLabel.textColor = isSelected ? .white : .secondaryLabelColor
    }
}

// Rounded card filled with a fixed diagonal gradient (the same in light and dark mode).
@MainActor
final class GradientView: NSView {
    private let colors: [CGColor]

    init(colors: [NSColor]) {
        self.colors = colors.map(\.cgColor)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        let gradient = CAGradientLayer()
        gradient.colors = colors
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        return gradient
    }
}

// One task row: a list-coloured completion circle, the title, and a due/list subtitle.
@MainActor
final class TaskCell: NSTableCellView {
    let check = NSButton()
    let titleField = NSTextField(labelWithString: "")
    let subtitleField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        check.isBordered = false
        check.imagePosition = .imageOnly
        check.setButtonType(.momentaryChange)
        check.setAccessibilityLabel("Toggle complete")
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.lineBreakMode = .byTruncatingTail
        for view in [check, titleField, subtitleField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 24),
            titleField.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleField.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            subtitleField.topAnchor.constraint(equalTo: centerYAnchor, constant: 3)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
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
    private var selectedTab = 0
    private var tiles: [SmartListTile] = []
    private var header: NSTextField!
    private var search: NSSearchField!
    private var stats: NSTextField!
    private var detail: NSTextField!
    private var emptyState: NSTextField!
    private var storageLabel: NSTextField?
    private var quickDatePicker: NSDatePicker?
    private var focusHeadline: NSTextField?
    private var focusDetail: NSTextField?
    private var compactStorage: NSTextField?
    private var compactPanel: NSPanel?
    private var compactSummary: NSTextField?
    private var compactNext: NSTextField?

    // Smart lists, in the same order as tabHostIndex (macaihub:// links).
    private struct TabStyle { let title: String; let symbol: String; let color: NSColor; let empty: String }
    private static let tabStyles: [TabStyle] = [
        TabStyle(title: "All Open", symbol: "tray.full.fill", color: .systemIndigo, empty: "No open tasks. Enjoy the free time."),
        TabStyle(title: "Today", symbol: "sun.max.fill", color: .systemBlue, empty: "Nothing due today."),
        TabStyle(title: "Overdue", symbol: "exclamationmark", color: .systemRed, empty: "You're all caught up."),
        TabStyle(title: "Upcoming", symbol: "calendar", color: .systemOrange, empty: "Nothing scheduled ahead."),
        TabStyle(title: "No Due Date", symbol: "infinity", color: .systemTeal, empty: "Every open task has a date."),
        TabStyle(title: "Completed", symbol: "checkmark", color: .systemGreen, empty: "No completed tasks yet.")
    ]

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

    private func sidebarButton(_ title: String, _ symbol: String, _ color: NSColor, _ action: Selector) -> NSButton {
        let button = NSButton(title: "  " + title, image: symbolImage(symbol, size: 14, color: color, weight: .semibold) ?? NSImage(),
            target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func actionButton(_ title: String, _ symbol: String, _ color: NSColor, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, image: symbolImage(symbol, size: 12, color: color, weight: .semibold) ?? NSImage(),
            target: self, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        return button
    }

    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Mac AI Productivity Hub"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 880, height: 640)
        window.center()
        let root = NSView()
        window.contentView = root

        // Sidebar: translucent like Apple's own apps, with colourful smart lists and tools.
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let brand = makeLabel("PRODUCTIVITY HUB", size: 11, bold: true)
        brand.textColor = .tertiaryLabelColor
        tiles = Self.tabStyles.enumerated().map { index, style in
            let tile = SmartListTile(title: style.title, symbol: style.symbol, color: style.color)
            tile.onClick = { [weak self] in self?.selectTab(index) }
            tile.widthAnchor.constraint(equalToConstant: 108).isActive = true
            tile.heightAnchor.constraint(equalToConstant: 72).isActive = true
            return tile
        }
        let grid = NSGridView(views: [[tiles[0], tiles[1]], [tiles[2], tiles[3]], [tiles[4], tiles[5]]])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        let toolsHeading = makeLabel("TOOLS", size: 11, bold: true)
        toolsHeading.textColor = .tertiaryLabelColor
        let tools = NSStackView(views: [
            sidebarButton("Today’s Plan", "sparkles", .systemPurple, #selector(showAIPlan)),
            sidebarButton("Mac Health", "heart.text.square.fill", .systemPink, #selector(showDiagnostics)),
            sidebarButton("Review Cleanup", "trash.fill", .systemOrange, #selector(showCleanup)),
            sidebarButton("Desktop Companion", "macwindow.on.rectangle", .systemTeal, #selector(showCompactPanel)),
            sidebarButton("AI Setup", "wand.and.stars", .systemIndigo, #selector(showAISetup)),
            sidebarButton("Open Reminders", "list.bullet.rectangle.fill", .systemBlue, #selector(openReminders))
        ])
        tools.orientation = .vertical
        tools.alignment = .leading
        tools.spacing = 4
        let storage = makeLabel("Checking storage…", size: 12)
        storage.textColor = .secondaryLabelColor
        storageLabel = storage
        let storageIcon = NSImageView(image: symbolImage("internaldrive.fill", size: 12, color: .systemGray) ?? NSImage())
        let storageRow = NSStackView(views: [storageIcon, storage])
        storageRow.spacing = 6
        for view in [brand, grid, toolsHeading, tools, storageRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }

        header = makeLabel(Self.tabStyles[0].title, size: 28, bold: true)
        header.textColor = Self.tabStyles[0].color
        header.translatesAutoresizingMaskIntoConstraints = false
        stats = makeLabel("Connecting to Apple Reminders…", size: 13)
        stats.textColor = .secondaryLabelColor
        stats.translatesAutoresizingMaskIntoConstraints = false

        search = NSSearchField()
        search.placeholderString = "Search reminders"
        search.target = self
        search.action = #selector(updateVisible)
        search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let refreshButton = NSButton(image: symbolImage("arrow.clockwise", size: 12, color: .secondaryLabelColor, weight: .semibold) ?? NSImage(),
            target: self, action: #selector(refresh))
        refreshButton.bezelStyle = .rounded
        refreshButton.toolTip = "Refresh reminders"
        let newButton = NSButton(title: "New Task", image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage(),
            target: self, action: #selector(newTask))
        newButton.bezelStyle = .rounded
        newButton.bezelColor = .systemIndigo
        newButton.imagePosition = .imageLeading
        newButton.keyEquivalent = "n"
        newButton.keyEquivalentModifierMask = [.command]
        let topActions = NSStackView(views: [search, refreshButton, newButton])
        topActions.spacing = 8
        topActions.translatesAutoresizingMaskIntoConstraints = false

        // A primary focus card gives the dashboard a useful purpose beyond
        // duplicating the Apple Reminders list.
        let focusCard = GradientView(colors: [
            NSColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1),
            NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)
        ])
        focusCard.translatesAutoresizingMaskIntoConstraints = false
        let focusKicker = makeLabel("YOUR NEXT STEP", size: 10, bold: true)
        focusKicker.textColor = NSColor.white.withAlphaComponent(0.75)
        let focusHeadline = makeLabel("Loading your priorities…", size: 19, bold: true)
        focusHeadline.textColor = .white
        let focusDetail = makeLabel("Your reminders stay in iCloud. Suggestions never change them.", size: 12)
        focusDetail.textColor = NSColor.white.withAlphaComponent(0.85)
        let focusPlanButton = NSButton(title: "", target: self, action: #selector(showAIPlan))
        focusPlanButton.isBordered = false
        focusPlanButton.attributedTitle = NSAttributedString(string: "View Today’s Plan  ", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        focusPlanButton.image = symbolImage("arrow.right.circle.fill", size: 15, color: .white)
        focusPlanButton.imagePosition = .imageTrailing
        focusPlanButton.wantsLayer = true
        focusPlanButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        focusPlanButton.layer?.cornerRadius = 16
        for v in [focusKicker, focusHeadline, focusDetail, focusPlanButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            focusCard.addSubview(v)
        }
        self.focusHeadline = focusHeadline
        self.focusDetail = focusDetail

        table = NSTableView()
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 52
        table.backgroundColor = .clear
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(editTask)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        let scroller = NSScrollView()
        scroller.documentView = table
        scroller.hasVerticalScroller = true
        scroller.drawsBackground = false
        scroller.borderType = .noBorder
        scroller.translatesAutoresizingMaskIntoConstraints = false
        emptyState = makeLabel("", size: 15)
        emptyState.font = .systemFont(ofSize: 15, weight: .medium)
        emptyState.textColor = .tertiaryLabelColor
        emptyState.isHidden = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        let bottomButtons = NSStackView(views: [
            actionButton("Edit Selected", "pencil", .systemBlue, #selector(editTask)),
            actionButton("Toggle Complete", "checkmark.circle.fill", .systemGreen, #selector(toggleComplete)),
            actionButton("Snooze +1 day", "moon.zzz.fill", .systemOrange, #selector(snoozeOneDay)),
            actionButton("Snooze +1 week", "calendar.badge.clock", .systemOrange, #selector(snoozeOneWeek))
        ])
        bottomButtons.orientation = .horizontal
        bottomButtons.spacing = 8
        bottomButtons.translatesAutoresizingMaskIntoConstraints = false
        detail = makeLabel("Click a circle to complete a task, or double-click a row to edit. Your iPhone syncs through iCloud.", size: 12)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false

        // All implicitly unwrapped outlets have been initialized above.
        // Explicitly use NSView so Swift does not infer an [NSView?] array.
        let contentViews: [NSView] = [sidebar, header!, stats!, topActions, focusCard, scroller, emptyState!, bottomButtons, detail!]
        for view in contentViews {
            root.addSubview(view)
        }
        let content = sidebar.trailingAnchor
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 254),
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 52),
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            grid.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 10),
            grid.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            toolsHeading.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 26),
            toolsHeading.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            tools.topAnchor.constraint(equalTo: toolsHeading.bottomAnchor, constant: 6),
            tools.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            tools.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -14),
            storageRow.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            storageRow.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -14),
            storageRow.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),

            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            header.leadingAnchor.constraint(equalTo: content, constant: 28),
            topActions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            topActions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            topActions.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 16),
            stats.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 3),
            stats.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            stats.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            focusCard.topAnchor.constraint(equalTo: stats.bottomAnchor, constant: 18),
            focusCard.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            focusCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            focusCard.heightAnchor.constraint(equalToConstant: 104),
            focusKicker.leadingAnchor.constraint(equalTo: focusCard.leadingAnchor, constant: 22),
            focusKicker.topAnchor.constraint(equalTo: focusCard.topAnchor, constant: 18),
            focusHeadline.leadingAnchor.constraint(equalTo: focusKicker.leadingAnchor),
            focusHeadline.topAnchor.constraint(equalTo: focusKicker.bottomAnchor, constant: 6),
            focusHeadline.trailingAnchor.constraint(lessThanOrEqualTo: focusPlanButton.leadingAnchor, constant: -16),
            focusDetail.leadingAnchor.constraint(equalTo: focusKicker.leadingAnchor),
            focusDetail.topAnchor.constraint(equalTo: focusHeadline.bottomAnchor, constant: 4),
            focusDetail.trailingAnchor.constraint(lessThanOrEqualTo: focusPlanButton.leadingAnchor, constant: -16),
            focusPlanButton.trailingAnchor.constraint(equalTo: focusCard.trailingAnchor, constant: -22),
            focusPlanButton.centerYAnchor.constraint(equalTo: focusCard.centerYAnchor),
            focusPlanButton.widthAnchor.constraint(equalToConstant: 180),
            focusPlanButton.heightAnchor.constraint(equalToConstant: 32),
            scroller.topAnchor.constraint(equalTo: focusCard.bottomAnchor, constant: 12),
            scroller.leadingAnchor.constraint(equalTo: content, constant: 16),
            scroller.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroller.bottomAnchor.constraint(equalTo: bottomButtons.topAnchor, constant: -12),
            emptyState.centerXAnchor.constraint(equalTo: scroller.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroller.centerYAnchor),
            bottomButtons.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            bottomButtons.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
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
        selectTab(tabHostIndex[host.lowercased()] ?? 0)
    }

    private func selectTab(_ index: Int) {
        guard index < Self.tabStyles.count else { return }
        selectedTab = index
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

    private func matches(_ item: EKReminder, tab: Int, now: Date) -> Bool {
        let due = reminderDate(item)
        switch tab {
        case 1: return !item.isCompleted && due.map { Calendar.current.isDateInToday($0) } == true
        case 2: return reminderIsOverdue(item, now: now)
        case 3: return !item.isCompleted && due.map { $0 > now && !Calendar.current.isDateInToday($0) } == true
        case 4: return !item.isCompleted && due == nil
        case 5: return item.isCompleted
        default: return !item.isCompleted
        }
    }

    @objc private func updateVisible(_ sender: Any? = nil) {
        let now = Date()
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = reminders.filter { item in
            if !query.isEmpty && !reminderTitle(item).localizedCaseInsensitiveContains(query) { return false }
            return matches(item, tab: selectedTab, now: now)
        }.sorted { a, b in
            let da = reminderDate(a) ?? Date.distantFuture
            let db = reminderDate(b) ?? Date.distantFuture
            if da != db { return da < db }
            return reminderTitle(a).localizedCaseInsensitiveCompare(reminderTitle(b)) == .orderedAscending
        }
        table.reloadData()
        for (index, tile) in tiles.enumerated() {
            tile.count = reminders.filter { matches($0, tab: index, now: now) }.count
            tile.isSelected = index == selectedTab
        }
        let style = Self.tabStyles[selectedTab]
        header.stringValue = style.title
        header.textColor = style.color
        stats.stringValue = "\(visible.count) \(visible.count == 1 ? "task" : "tasks")  ·  Changes sync through iCloud Reminders. Cleanup always asks first."
        emptyState.stringValue = query.isEmpty ? style.empty : "No tasks match “\(query)”."
        emptyState.isHidden = !visible.isEmpty || !granted
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            storageLabel?.stringValue = String(format: "%.1f GB free on this Mac", free.doubleValue / 1e9)
        } else { storageLabel?.stringValue = "Storage information unavailable" }
        updateFocusCard()
        updateCompactPanel()
        updateStatusBarTitle(open: tiles[0].count, overdue: tiles[2].count)
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
        guard row < visible.count else { return nil }
        let item = visible[row]
        let id = NSUserInterfaceItemIdentifier("taskCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? TaskCell) ?? TaskCell(identifier: id)
        let listColor = NSColor(cgColor: item.calendar.cgColor) ?? .systemBlue
        cell.check.image = symbolImage(item.isCompleted ? "checkmark.circle.fill" : "circle", size: 19, color: listColor)
        cell.check.target = self
        cell.check.action = #selector(toggleRow(_:))

        let raw = reminderTitle(item)
        var titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: item.isCompleted ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        if item.isCompleted { titleAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let taskTitle = raw.isEmpty ? "(Untitled reminder)" : raw
        cell.titleField.attributedStringValue = NSAttributedString(string: taskTitle, attributes: titleAttrs)

        // Due date coloured by urgency, then a dot and the list name in the list's own colour.
        let small = NSFont.systemFont(ofSize: 12)
        let due = reminderDate(item)
        let overdue = reminderIsOverdue(item)
        let dueColor: NSColor
        if item.isCompleted || due == nil { dueColor = .tertiaryLabelColor }
        else if overdue { dueColor = .systemRed }
        else if due.map({ Calendar.current.isDateInToday($0) }) == true { dueColor = .systemBlue }
        else { dueColor = .secondaryLabelColor }
        let subtitle = NSMutableAttributedString(string: overdue ? "Overdue · \(reminderDueLabel(item))" : reminderDueLabel(item),
            attributes: [.font: small, .foregroundColor: dueColor])
        subtitle.append(NSAttributedString(string: "   ●  ", attributes: [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: listColor, .baselineOffset: 1.5
        ]))
        subtitle.append(NSAttributedString(string: item.calendar.title, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        cell.subtitleField.attributedStringValue = subtitle
        return cell
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
        toggle(item)
    }

    @objc private func toggleRow(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < visible.count else { return }
        toggle(visible[row])
    }

    private func toggle(_ item: EKReminder) {
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
        dialog.icon = symbolImage(original == nil ? "plus.circle.fill" : "pencil.circle.fill", size: 44, color: .systemIndigo)
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
