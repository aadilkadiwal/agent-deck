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
    @State private var blinkOff = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let five = model.usage?.fiveHour?.percent()
        let week = model.usage?.weekly?.percent()
        let pct = { (p: Double?) in p.map { "\(Int($0.rounded()))%" } ?? "–" }
        let style = BarStyle(rawValue: barStyle) ?? .closest
        let weeklyCloser = style != .ringOnly && (week ?? 0) > (five ?? 0)
        let shown = weeklyCloser ? model.usage?.weekly : model.usage?.fiveHour
        let out: Date? = if let shown, case .reachesLimit(let at) = model.forecast(shown), at > Date() { at } else { nil }
        let back = shown.flatMap { $0.percent() >= LimitWindow.full ? $0.resetsAt : nil }
        let limit = (weeklyCloser ? "Weekly \(pct(week))" : pct(five))
            + (back.map { " · resets \(Fmt.clock($0))" } ?? out.map { " · out \(Fmt.clock($0))" } ?? "")
        let waiting = model.count(.blocked)
        HStack(spacing: 4) {
            Image(nsImage: MenuBarRing.image(percent: weeklyCloser ? week : five, weekly: weeklyCloser, alert: model.needsYou && !blinkOff))
            switch style {
            case .closest: Text(waiting > 0 ? "\(limit) · \(waiting) waiting" : limit)
            case .withSessions: Text("\(limit) · \(model.live.count)")
            case .ringOnly: EmptyView()
            }
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0)))
        .accessibilityHidden(true)
        // Tooltip and VoiceOver label live on the status button, which takes the clicks.
        .onChange(of: model.barSummary, initial: true) { StatusMenu.describe(model.barSummary) }
        .task(id: model.needsYou) {
            guard model.needsYou, !reduceMotion else { blinkOff = false; return }
            for _ in 0..<4 {
                blinkOff.toggle()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            blinkOff = false
        }
        // The label is the only view alive from launch, so it hands the AppKit panel a window opener.
        .task {
            model.showDetails = { [openWindow] tab in
                StatusMenu.close()
                UserDefaults.standard.set(tab.rawValue, forKey: "detailsTab")
                openWindow(id: "details")
                NSApp.activate(ignoringOtherApps: true)
            }
            if UserDefaults.standard.bool(forKey: PinnedPanel.key) { PinnedPanel.shared.show(model) }
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
    static private(set) var available: CGFloat = 800

    static func install(_ model: AppModel) {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = StatusTarget.shared
        button.action = #selector(StatusTarget.click)
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

    static func describe(_ summary: String) {
        item?.button?.toolTip = summary
        item?.button?.setAccessibilityLabel(summary)
    }

    static func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    static func open() {
        guard let content, let button = item?.button, let screen = button.window?.screen ?? NSScreen.main,
              panel?.isVisible != true else { return }
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

private final class StatusTarget: NSObject {
    static let shared = StatusTarget()
    @MainActor @objc func click() { StatusMenu.toggle() }
}

/// Borderless panels can't become key by default; the dropdown needs keyboard focus.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { StatusMenu.close() }
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

