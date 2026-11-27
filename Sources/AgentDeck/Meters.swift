import AppKit
import AgentDeckCore
import SwiftUI

enum Level {
    static func color(_ pct: Double) -> Color { pct >= LimitWindow.full ? .red : pct >= Notifier.warnAt ? .orange : .gray }
}

enum Motion {
    static let pulse = 1.6
    static func beat(_ d: Date) -> Double { (d.timeIntervalSinceReferenceDate / pulse).truncatingRemainder(dividingBy: 1) }
    static func fast(_ reduced: Bool) -> Animation { .easeOut(duration: reduced ? 0.15 : 0.12) }
    static func snappy(_ reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 0.85) }
    static func spring(reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.78) }
}

enum SessionColor {
    private static let palette: [Color] = [.teal, .purple, .pink, .indigo, .cyan,
                                           adaptive(light: (0.39, 0.45, 0.55), dark: (0.58, 0.64, 0.74)),
                                           adaptive(light: (0.61, 0.31, 0.59), dark: (0.80, 0.52, 0.78))]

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static func of(_ sessionId: String) -> Color {
        // String.hashValue changes every launch; this doesn't.
        palette[sessionId.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } % palette.count]
    }
}

struct Meter: View {
    let window: LimitWindow
    var forecast: Forecast = .unknown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pct = window.percent(), full = pct >= LimitWindow.full
        let out: Date? = if !full, case .reachesLimit(let at) = forecast, at > Date() { at } else { nil }
        HStack(spacing: 8) {
            Text(window.key == "five_hour" ? "5-hour" : window.label).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            MeterBar(percent: pct)
            Text("\(Int(pct.rounded()))%").fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(pct >= Notifier.warnAt ? Level.color(pct) : .primary)
                .frame(width: 38, alignment: .trailing)
            Group {
                if full, let r = window.resetsAt { Text("back \(Fmt.clock(r))").foregroundStyle(.red) }
                else if let out { Text("out \(Fmt.clock(out))").foregroundStyle(.orange) }
                else { Text(window.resetsAt.map { Fmt.clock($0).replacingOccurrences(of: ", ", with: " ") } ?? "").foregroundStyle(.secondary) }
            }
            .lineLimit(1).frame(width: 92, alignment: .leading)
        }
        .font(.subheadline)
        .animation(Motion.spring(reduced: reduceMotion), value: pct)
        .help(full ? "\(window.label) limit reached. \(Fmt.resetsTitle(window.resetsAt))."
              : "\(window.label) limit: \(Int(pct.rounded()))% used · \(Fmt.resets(window.resetsAt))" + (out.map { " · at this pace it runs out at \(Fmt.clock($0))" } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) limit \(Int(pct.rounded())) percent" + (full ? ", reached, back at \(window.resetsAt.map(Fmt.clock) ?? "reset")" : ""))
    }
}

struct MeterBar: View {
    let percent: Double
    private let height: CGFloat = 6

    var body: some View {
        Capsule().fill(Color.primary.opacity(0.12))
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(Level.color(percent)).frame(width: max(height, g.size.width * min(percent, 100) / 100))
                }
            }
            .frame(height: height)
    }
}
