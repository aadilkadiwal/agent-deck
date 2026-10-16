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
    }
}

struct BarLabel: View {
    let model: AppModel
    @AppStorage("barStyle") private var barStyle = BarStyle.closest.rawValue
    @State private var blinkOff = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let five = model.usage?.fiveHour?.percent()
        let week = model.usage?.weekly?.percent()
        let pct = { (p: Double?) in p.map { "\(Int($0.rounded()))%" } ?? "–" }
        let style = BarStyle(rawValue: barStyle) ?? .closest
        let weeklyCloser = style == .closest && (week ?? 0) > (five ?? 0)
        HStack(spacing: 4) {
            Image(nsImage: MenuBarRing.image(percent: weeklyCloser ? week : five, weekly: weeklyCloser, alert: model.needsYou && !blinkOff))
            switch style {
            case .closest: Text(weeklyCloser ? "W \(pct(week)) · \(model.live.count)" : "\(pct(five)) · \(model.live.count)")
            case .ringOnly: EmptyView()
            }
        }
        // Menu bar labels take only images, so the dot blinks by swapping them.
        .task(id: model.needsYou) {
            guard model.needsYou, !reduceMotion else { blinkOff = false; return }
            for _ in 0..<4 {
                blinkOff.toggle()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            blinkOff = false
        }
    }
}
