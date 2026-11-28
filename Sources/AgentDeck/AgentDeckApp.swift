import AppKit
import AgentDeckCore
import SwiftUI

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        StatusMenu.install(model)
    }

    var body: some Scene {
        // Never inserted (StatusMenu owns the status item); as the first scene it keeps SwiftUI
        // from opening the details window at launch.
        MenuBarExtra("Agent Deck", isInserted: .constant(false)) { EmptyView() }

        Window("Agent Deck", id: "details") {
            DetailsView(model: model)
        }
        .defaultSize(width: 1180, height: 700)

        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct BarLabel: View {
    let model: AppModel
    @AppStorage("barStyle") private var barStyle = BarStyle.closest.rawValue
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let five = model.usage?.fiveHour?.percent()
        let week = model.usage?.weekly?.percent()
        let style = BarStyle(rawValue: barStyle) ?? .closest
        let weeklyCloser = style != .ringOnly && (week ?? 0) > (five ?? 0)
        let shown = weeklyCloser ? model.usage?.weekly : model.usage?.fiveHour
        let out: Date? = if let shown, case .reachesLimit(let at) = model.forecast(shown), at > Date() { at } else { nil }
        let back = shown.flatMap { $0.percent() >= LimitWindow.full ? $0.resetsAt : nil }
        let pct = shown.map { "\(Int($0.percent().rounded()))%" } ?? "–"
        let tail: String = if let back { " · back \(Fmt.clock(back))" } else if let out { " · full ~\(Fmt.clock(out))" } else { "" }
        let limit = pct + tail
        let mood = model.mood(for: shown)
        // Below 50% (or the warning level, if lower) the number says nothing Dot's rim doesn't.
        let low = (shown?.percent() ?? 0) < min(50, Notifier.warnAt) && out == nil && back == nil
        HStack(spacing: 4) {
            Dot(mood: mood, percent: shown?.percent(), size: 18, extras: mood == .needs || mood == .risky, fps: 15, still: true)
            switch style {
            case .closest: if !low { Text(limit) }
            case .withSessions: Text(low ? "\(model.live.count)" : "\(limit) · \(model.live.count)")
            case .ringOnly: EmptyView()
            }
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0)))
        .accessibilityHidden(true)
        // Tooltip and VoiceOver label live on the status button, which takes the clicks.
        .onChange(of: model.barSummary, initial: true) { StatusMenu.describe(model.barSummary) }
        // The label is the only view alive from launch, so it hands the AppKit panel a window opener.
        .task {
            model.showDetails = { [openWindow] tab in
                StatusMenu.close()
                UserDefaults.standard.set(tab.rawValue, forKey: "detailsTab")
                openWindow(id: "details")
                NSApp.activate(ignoringOtherApps: true)
            }
            model.showSettings = { [openSettings] in
                StatusMenu.close()
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

@MainActor
enum StatusMenu {
    private static var item: NSStatusItem?
    private static var label: Host<BarLabel>?
    private static var panel: MenuPanel?
    private static var content: Host<MenuView>?
    private static var monitors: [Any] = []
    private static var observers: [NSObjectProtocol] = []
    static var escape: (() -> Void)?
    static private(set) var available: CGFloat = 800

    static func install(_ model: AppModel) {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = StatusTarget.shared
        button.action = #selector(StatusTarget.click)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        StatusTarget.shared.model = model
        let label = Host(rootView: BarLabel(model: model))
        label.passesClicks = true
        label.onResize = { [weak label] in
            guard let label else { return }
            let w = label.fittingSize.width
            label.frame = NSRect(x: 6, y: 0, width: w, height: button.bounds.height)
            item.length = w + 12
        }
        label.autoresizingMask = [.height]
        button.addSubview(label)
        label.onResize?()
        let content = Host(rootView: MenuView(model: model))
        content.onResize = place
        self.item = item
        self.label = label
        self.content = content
    }

    static func popUp(_ menu: NSMenu) {
        guard let item, let button = item.button else { return }
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    static func describe(_ summary: String) {
        item?.button?.toolTip = summary
        item?.button?.setAccessibilityLabel(summary)
    }

    static var buttonFrame: NSRect? {
        guard let b = item?.button, let w = b.window else { return nil }
        return w.convertToScreen(b.convert(b.bounds, to: nil))
    }

    static func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    static func open() {
        guard let content, let button = item?.button, let screen = button.window?.screen ?? NSScreen.main,
              panel?.isVisible != true else { return }
        Peek.close()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        available = (button.window?.frame.minY ?? screen.visibleFrame.maxY) - screen.visibleFrame.minY
        panel.contentView?.addSubview(content)   // mounting fires MenuView's onAppear
        place()
        button.highlight(true)
        panel.alphaValue = 0
        // A non-activating panel takes the keyboard without making Agent Deck the active app, so the
        // terminal stays frontmost and gets its focus straight back when the dropdown closes, like a menu.
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        // Clicks in other apps, clicks in our other windows, and switching apps all close it, like a menu.
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in close() },
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
                // Context menus and the open panel are windows too; they mustn't close it.
                if let w = e.window, w !== panel, w !== button.window, w.level < .popUpMenu, NSApp.modalWindow == nil { close() }
                return e
            },
        ].compactMap { $0 }
        observers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { MainActor.assumeIsolated { close() } }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { close() }
            },
        ]
    }

    static func close() {
        guard let panel, panel.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        monitors = []
        observers = []
        panel.orderOut(nil)
        content?.removeFromSuperview()   // unmounting fires onDisappear; the view keeps its state
        item?.button?.highlight(false)
    }

    static func fit() { DispatchQueue.main.async { place() } }

    private static func place() {
        guard let panel, let content, content.superview != nil, let button = item?.button, let bar = button.window,
              let screen = bar.screen ?? NSScreen.main else { return }
        let size = content.fittingSize
        let frame = screen.visibleFrame
        let height = min(size.height, available)
        let x = min(max(bar.convertToScreen(button.convert(button.bounds, to: nil)).minX, frame.minX), frame.maxX - size.width)
        panel.setFrame(NSRect(x: x, y: bar.frame.minY - height, width: size.width, height: height), display: true)
        content.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: height))
        panel.invalidateShadow()
    }

    private static func makePanel() -> MenuPanel {
        let p = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Radius.panel
        background.layer?.masksToBounds = true
        p.contentView = background
        return p
    }
}

@MainActor
private final class StatusTarget: NSObject {
    static let shared = StatusTarget()
    weak var model: AppModel?
    /// Menu items only hold their targets weakly, so the open menu keeps them alive here.
    private var menu: NSMenu?

    @objc func click() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true { showMenu() } else { StatusMenu.toggle() }
    }

    private func showMenu() {
        StatusMenu.close()
        let menu = NSMenu()
        if let until = Notifier.snoozedUntil {
            let status = NSMenuItem(title: "Alerts snoozed until \(Fmt.clock(until))", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(item("Resume alerts") { Notifier.snooze(for: nil) })
        } else {
            menu.addItem(item("Snooze alerts for 1 hour") { Notifier.snooze(for: 3600) })
        }
        let on = UserDefaults.standard.bool(forKey: AppModel.keepAwakeKey)
        let awake = item(AppModel.keepAwakeTitle) { [weak self] in self?.model?.setKeepAwake(!on) }
        awake.state = on ? .on : .off
        menu.addItem(awake)
        menu.addItem(.separator())
        menu.addItem(item("New session…") { [weak self] in self?.model?.startNewSession = true; StatusMenu.open() })
        menu.addItem(item("View details…") { [weak self] in self?.model?.showDetails?(.sessions) })
        menu.addItem(item("Settings…") { [weak self] in self?.model?.showSettings?() })
        menu.addItem(.separator())
        menu.addItem(item("Quit Agent Deck") { NSApp.terminate(nil) })
        self.menu = menu
        StatusMenu.popUp(menu)
    }

    private func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        let action = MenuAction(run)
        i.target = action
        i.representedObject = action
        return i
    }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// Borderless panels can't become key by default; the dropdown needs keyboard focus.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { if let escape = StatusMenu.escape { escape() } else { StatusMenu.close() } }
}

final class Host<Content: View>: NSHostingView<Content> {
    var onResize: (() -> Void)?
    var passesClicks = false

    override func hitTest(_ point: NSPoint) -> NSView? { passesClicks ? nil : super.hitTest(point) }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
}

