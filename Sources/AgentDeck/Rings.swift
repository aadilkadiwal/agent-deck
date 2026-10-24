import AppKit
import AgentDeckCore
import SwiftUI

enum Level {
    static func color(_ pct: Double) -> Color { pct >= 90 ? .red : pct >= 75 ? .orange : .accentColor }
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
                                           Color(red: 0.39, green: 0.45, blue: 0.55), Color(red: 0.61, green: 0.31, blue: 0.59)]

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
            if showsLabel {
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
    var size: CGFloat = 44
    var forecast: Forecast = .unknown
    var delay: Double = 0

    var body: some View {
        let pct = window.percent()
        HStack(spacing: 10) {
            Ring(percent: pct, size: size, line: size / 8.5, delay: delay)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.label).font(.system(size: 13, weight: .semibold))
                Text(Fmt.resets(window.resetsAt)).font(.system(size: 11)).foregroundStyle(.secondary)
                if let f = Fmt.forecast(forecast) {
                    Text(f).font(.system(size: 11, weight: .medium)).lineLimit(2)
                        .foregroundStyle(forecast == .safeUntilReset ? Color.secondary : Color.orange)
                }
            }
        }
    }
}

/// The menu bar picture: a small ring drawn into an image (menu bar labels only take Image + Text).
enum MenuBarRing {
    static func image(percent: Double?, weekly: Bool = false, alert: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { full in
            let rect = NSRect(x: 0, y: 0, width: 16, height: 16)
            if alert {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: full.maxX - 6, y: full.maxY - 6, width: 6, height: 6)).fill()
            }
            let r = rect.insetBy(dx: 2, dy: 2)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = 2.5
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
            track.stroke()
            guard let percent, percent > 0 else { return true }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: r.width / 2, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(percent, 100) / 100), clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            (percent >= 75 || !weekly ? NSColor(Level.color(percent)) : NSColor.systemTeal).setStroke()
            arc.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }
}
