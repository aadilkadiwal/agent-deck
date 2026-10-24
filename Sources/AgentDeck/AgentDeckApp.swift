import AppKit
import AgentDeckCore
import SwiftUI

@main
struct AgentDeckApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            BarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Agent Deck", id: "details") {
            DetailsView(model: model)
        }
        .defaultSize(width: 1180, height: 700)

        Settings {
            SettingsView(model: model)
        }
    }
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
        let limit = weeklyCloser ? "W \(pct(week))" : pct(five)
        let waiting = model.count(.blocked)
        HStack(spacing: 4) {
            Image(nsImage: MenuBarRing.image(percent: weeklyCloser ? week : five, weekly: weeklyCloser, alert: model.needsYou && !blinkOff))
            switch style {
            case .closest: Text(waiting > 0 ? "\(limit) · \(waiting) waiting" : limit)
            case .withSessions: Text("\(limit) · \(model.live.count)")
            case .ringOnly: EmptyView()
            }
        }
        .help(model.barSummary)
        .accessibilityLabel(model.barSummary)
        // Menu bar labels take only images, so the dot blinks by swapping them.
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
                UserDefaults.standard.set(tab.rawValue, forKey: "detailsTab")
                openWindow(id: "details")
                NSApp.activate(ignoringOtherApps: true)
            }
            if UserDefaults.standard.bool(forKey: PinnedPanel.key) { PinnedPanel.shared.show(model) }
        }
    }
}

/// MenuBarExtra has no API to open its window, so the global shortcut clicks our status item.
@MainActor
enum StatusMenu {
    static func toggle() {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBarWindow") {
            if let button = statusButton(in: w.contentView) {
                NSApp.activate(ignoringOtherApps: true)
                button.performClick(nil)
                return
            }
        }
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        return view.subviews.lazy.compactMap { statusButton(in: $0) }.first
    }
}
