import AppKit
import AgentDeckCore
import SwiftUI

enum Level {
    static func color(_ pct: Double) -> Color { pct >= LimitWindow.full ? .red : pct >= Notifier.warnAt ? .orange : .accentColor }
}

enum Motion {
    static let pulse = 1.6
    static func fast(_ reduced: Bool) -> Animation { .easeOut(duration: reduced ? 0.15 : 0.12) }
    static func snappy(_ reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 0.85) }
    static func spring(reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.78) }
}

/// A steady color per session, so a prompt card matches its row. No green or orange: they mean working / needs you.
enum SessionColor {
    private static let palette: [Color] = [.blue, .teal, .purple, .pink, .indigo, .cyan,
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

struct Ring: View {
    let percent: Double
    var size: CGFloat = 44
    var line: CGFloat = 5
    var delay: Double = 0
    var showsLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    private var level: Int { percent >= 90 ? 2 : percent >= 75 ? 1 : 0 }

    var body: some View {
        let still = reduceMotion
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: line)
            Circle()
                .trim(from: 0, to: shown / 100)
                .stroke(Level.color(shown), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsLabel && size * 0.24 >= 11 {
                Text("\(Int(shown.rounded()))%")
                    .font(.system(size: size * 0.24, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: shown))
            }
        }
        .keyframeAnimator(initialValue: 1.0, trigger: level) { v, scale in
            v.scaleEffect(still ? 1 : scale)
        } keyframes: { _ in
            SpringKeyframe(1.06, duration: 0.15)
            SpringKeyframe(1.0, duration: 0.25)
        }
        .frame(width: size, height: size)
        .onAppear {
            if reduceMotion { shown = percent; return }
            withAnimation(Motion.spring(reduced: false).delay(delay)) { shown = percent }
        }
        .onChange(of: percent) { withAnimation(Motion.spring(reduced: reduceMotion)) { shown = percent } }
        .accessibilityLabel("\(Int(percent.rounded())) percent used")
    }
}

struct UsageTile: View {
    let window: LimitWindow
    var size: CGFloat = 48
    var forecast: Forecast = .unknown
    var delay: Double = 0

    var body: some View {
        let pct = window.percent()
        HStack(spacing: 10) {
            Ring(percent: pct, size: size, line: size / 8.5, delay: delay)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.label).font(.body.weight(.semibold))
                Text(Fmt.resets(window.resetsAt)).font(.subheadline).foregroundStyle(.secondary)
                if let f = Fmt.forecast(forecast) {
                    Text(f).font(.subheadline.weight(.medium)).lineLimit(2)
                        .foregroundStyle(forecast == .safeUntilReset ? Color.secondary : Color.orange)
                }
            }
        }
    }
}
