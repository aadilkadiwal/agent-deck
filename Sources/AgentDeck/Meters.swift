import AppKit
import AgentDeckCore
import SwiftUI

enum Level {
    static func color(_ pct: Double) -> Color { pct >= LimitWindow.full ? Tone.risky : pct >= Notifier.warnAt ? Tone.waiting : .gray }
}

enum Motion {
    static let pulse = 1.6
    static func beat(_ d: Date) -> Double { (d.timeIntervalSinceReferenceDate / pulse).truncatingRemainder(dividingBy: 1) }
    static func fast(_ reduced: Bool) -> Animation { .easeOut(duration: reduced ? 0.15 : 0.12) }
    static func snappy(_ reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 0.85) }
    static func spring(reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.78) }
}

enum SessionColor {
    // No purples, so a session is never mistaken for the brand violet.
    private static let palette: [Color] = [.teal, .pink, .indigo, .cyan, adaptive(light: (0.39, 0.45, 0.55), dark: (0.58, 0.64, 0.74))]

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
        let elapsed = full ? nil : window.elapsed()
        HStack(spacing: 8) {
            Text(window.key == "five_hour" ? "5-hour" : window.label).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            MeterBar(percent: pct, elapsed: elapsed)
            Text("\(Int(pct.rounded()))%").fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(Tone.text(pct))
                .frame(width: 38, alignment: .trailing)
            Group {
                if full, let r = window.resetsAt { Text("back \(Fmt.clock(r))").foregroundStyle(Tone.riskText) }
                else if let out { Text("full ~\(Fmt.clock(out))").foregroundStyle(Tone.warnText) }
                else { Text(window.resetsAt.map { Calendar.current.isDateInToday($0) ? "resets \(Fmt.clock($0))" : "resets \($0.formatted(.dateTime.weekday(.abbreviated)))" } ?? "").foregroundStyle(.secondary) }
            }
            .lineLimit(1).frame(width: 92, alignment: .leading)
        }
        .font(.subheadline)
        .animation(Motion.spring(reduced: reduceMotion), value: pct)
        .help(tooltip(pct, full: full, elapsed: elapsed, out: out))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(pct, full: full, elapsed: elapsed))
    }

    private func tooltip(_ pct: Double, full: Bool, elapsed: Double?, out: Date?) -> String {
        if full { return "\(window.label) limit reached. \(Fmt.resetsTitle(window.resetsAt))." }
        var parts = ["\(window.label) limit: \(Int(pct.rounded()))% used"]
        if let elapsed { parts.append(Self.pace(pct, elapsed)) }
        parts.append(Fmt.resets(window.resetsAt))
        if let out { parts.append("at this pace it runs out at \(Fmt.clock(out))") }
        return parts.joined(separator: " · ")
    }

    private func spoken(_ pct: Double, full: Bool, elapsed: Double?) -> String {
        var s = "\(window.label) limit \(Int(pct.rounded())) percent"
        if full { s += ", reached, back at \(window.resetsAt.map(Fmt.clock) ?? "reset")" }
        if let elapsed { s += ", " + Self.pace(pct, elapsed) }
        return s
    }

    /// Used against time gone. Using less than the clock is headroom, not "behind".
    static func pace(_ pct: Double, _ elapsed: Double) -> String {
        let gone = Int((elapsed * 100).rounded()), diff = Int((pct - elapsed * 100).rounded())
        let pace = abs(diff) < 3 ? "on pace" : diff > 0 ? "using it faster than the clock" : "\(-diff) points of headroom"
        return "\(gone)% of the time gone, \(pace)"
    }
}

/// The tick marks how much of the window's time has passed: fill past it means you're using it faster.
struct MeterBar: View {
    let percent: Double
    var elapsed: Double?
    private let height: CGFloat = 6

    var body: some View {
        Capsule().fill(Color.primary.opacity(0.12))
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(Level.color(percent)).frame(width: max(height, g.size.width * min(percent, 100) / 100))
                    if let elapsed {
                        RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.55))
                            .frame(width: 2, height: height + 4)
                            .offset(x: min(g.size.width - 2, max(0, g.size.width * elapsed - 1)), y: -2)
                    }
                }
            }
            .frame(height: height)
    }
}

/// Status colours. Light mode gets darker fills so dots and bars keep 3:1 on the light menu, and done is a
/// bluish green that stays apart from risky and waiting with red–green colour blindness. Brand violet means no status.
enum Tone {
    static let waiting = adaptive(light: (0.80, 0.384, 0.0), dark: (1.0, 0.624, 0.039))       // #CC6200 / #FF9F0A
    static let working = adaptive(light: (0.0, 0.478, 1.0), dark: (0.039, 0.518, 1.0))        // #007AFF / #0A84FF
    static let done = adaptive(light: (0.043, 0.49, 0.365), dark: (0.184, 0.839, 0.663))      // #0B7D5D / #2FD6A9
    static let risky = adaptive(light: (0.878, 0.161, 0.122), dark: (1.0, 0.271, 0.227))      // #E0291F / #FF453A
    static let brand = adaptive(light: (0.431, 0.337, 0.812), dark: (0.639, 0.58, 1.0))       // #6E56CF / #A394FF
    static let warnText = adaptive(light: (0.66, 0.33, 0.0), dark: (1.0, 0.62, 0.04))
    static let riskText = adaptive(light: (0.79, 0.11, 0.08), dark: (1.0, 0.41, 0.38))
    static let okText = done

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    static func text(_ pct: Double) -> Color { pct >= LimitWindow.full ? riskText : pct >= Notifier.warnAt ? warnText : .primary }
}
