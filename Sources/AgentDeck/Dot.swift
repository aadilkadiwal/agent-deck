import AgentDeckCore
import SwiftUI

enum DotMood: Equatable {
    case idle, working, needs, risky, done, warn, runsOut, reached, back
}

struct Dot: View {
    let mood: DotMood
    let percent: Double?
    var size: CGFloat = 56
    var extras = true
    var fps: Double = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var since = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps, paused: reduceMotion)) { tl in
            Canvas { ctx, sz in
                let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
                let sinceChange = reduceMotion ? 60 : tl.date.timeIntervalSince(since)
                DotFace(mood: mood, percent: percent, extras: extras).draw(&ctx, sz, t: t, sinceChange: sinceChange)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: mood) { since = Date() }
        .accessibilityHidden(true)
    }

    @MainActor static func png(mood: DotMood, percent: Double?, size: CGFloat = 120) -> Data? {
        let view = Canvas { ctx, sz in DotFace(mood: mood, percent: percent, extras: true).draw(&ctx, sz, t: 0, sinceChange: 60) }
            .frame(width: size, height: size)
            .padding(size * 0.12)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    static func color(_ mood: DotMood, percent: Double?) -> Color {
        switch mood {
        case .needs, .warn, .runsOut: .orange
        case .risky, .reached: .red
        case .done: .green
        case .idle, .working, .back: Level.color(percent ?? 0)
        }
    }
}

/// Drawn on a 120-point grid. Animations are functions of time, so a frame can be drawn at any moment.
private struct DotFace {
    let mood: DotMood
    let percent: Double?
    let extras: Bool

    private let eye = Color(red: 0.95, green: 0.96, blue: 0.98)
    private let ink = Color(red: 0.05, green: 0.06, blue: 0.08)

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize, t: Double, sinceChange sc: Double) {
        let k = min(size.width, size.height) / 120
        ctx.scaleBy(x: k, y: k)
        let rim = Dot.color(mood, percent: percent)

        var body = ctx
        let (dx, dy, rot, sx, sy) = bodyMove(sc)
        body.translateBy(x: 60 + dx, y: 104 + dy)
        body.rotate(by: .degrees(rot))
        body.scaleBy(x: sx, y: sy)
        body.translateBy(x: -60, y: -104)

        body.fill(Path(ellipseIn: CGRect(x: 2, y: 2, width: 116, height: 116)), with: .color(rim.opacity(0.16)))
        let ring = Path(ellipseIn: CGRect(x: 8, y: 8, width: 104, height: 104))
        body.stroke(ring, with: .color(Color.gray.opacity(0.28)), lineWidth: 8)
        let fraction = min(max((percent ?? 0) / 100, 0), 1)
        if fraction > 0 {
            body.stroke(arc(from: 0, to: fraction), with: .color(rim.opacity(mood == .working ? 0.35 : 1)),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
        }
        if mood == .working {
            let start = (t / 1.1).truncatingRemainder(dividingBy: 1)
            body.stroke(arc(from: start, to: start + 0.22), with: .color(rim), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        }
        body.fill(Path(ellipseIn: CGRect(x: 16, y: 16, width: 88, height: 88)),
                  with: .radialGradient(Gradient(colors: [Color(red: 0.23, green: 0.25, blue: 0.29), Color(red: 0.11, green: 0.12, blue: 0.15),
                                                          Color(red: 0.05, green: 0.06, blue: 0.08)]),
                                        center: CGPoint(x: 51, y: 44), startRadius: 0, endRadius: 70))
        drawEyes(&body, t: t)
        drawMouth(&body)
        if extras { drawExtras(&body, t: t, rim: rim) }
    }

    private func drawEyes(_ ctx: inout GraphicsContext, t: Double) {
        switch mood {
        case .idle, .back:
            pills(&ctx, y: 47, h: 20, blink: kf(t, 4.2, [(0, 1), (0.92, 1), (0.95, 0.1), (1, 1)]), pivot: 58)
        case .working:
            let x = kf(t, 2.6, [(0, 0), (0.3, -4), (0.65, 4), (1, 0)])
            pills(&ctx, y: 47, h: 20, blink: kf(t, 4.2, [(0, 1), (0.92, 1), (0.95, 0.1), (1, 1)]), pivot: 58, dx: x)
        case .needs:
            let blink = kf(t, 3.4, [(0, 1), (0.8, 1), (0.83, 0.08), (0.86, 1), (0.89, 0.08), (0.92, 1), (1, 1)])
            let px = kf(t, 2.9, [(0, 0), (0.2, -2.5), (0.45, 2.5), (0.7, 0), (1, 0)])
            let py = kf(t, 2.9, [(0, 0), (0.2, -1), (0.45, 0), (0.7, 1.5), (1, 0)])
            for cx in [46.5, 73.5] {
                ctx.fill(Path(ellipseIn: squash(CGRect(x: cx - 9, y: 47, width: 18, height: 18), blink, pivot: 56)), with: .color(eye))
                if blink > 0.4 {
                    ctx.fill(Path(ellipseIn: squash(CGRect(x: cx + 1.5 - 3.6 + px, y: 57 - 3.6 + py, width: 7.2, height: 7.2), blink, pivot: 56)),
                             with: .color(ink))
                }
            }
        case .risky:
            let twitch = kf(t, 1.7, [(0, 0), (0.44, -2), (0.5, 1), (1, 0)])
            line(&ctx, [(38, 50 + twitch), (53, 57 + twitch)], 5)
            line(&ctx, [(82, 50 + twitch), (67, 57 + twitch)], 5)
            let blink = kf(t, 1.7, [(0, 1), (0.4, 1), (0.44, 0.1), (0.48, 1), (0.5, 0.1), (0.52, 1), (1, 1)])
            pills(&ctx, y: 58, h: 9, blink: blink, pivot: 62)
        case .done:
            let sq = kf(t, 2.6, [(0, 1), (0.78, 1), (0.84, 0.55), (0.9, 1), (1, 1)])
            for x in [39.0, 66.0] {
                var p = Path()
                p.move(to: CGPoint(x: x, y: 60))
                p.addQuadCurve(to: CGPoint(x: x + 15, y: 60), control: CGPoint(x: x + 7.5, y: 60 - 12 * sq))
                ctx.stroke(p, with: .color(eye), style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
            }
        case .warn:
            let lift = kf(t, 4.6, [(0, 0), (0.5, -2), (1, 0)])
            line(&ctx, [(38, 44 + lift), (52, 40 + lift)], 4)
            line(&ctx, [(82, 44 + lift), (68, 40 + lift)], 4)
            pills(&ctx, y: 50, h: 17, blink: kf(t, 4.6, [(0, 1), (0.84, 1), (0.9, 0.08), (0.95, 0.5), (1, 1)]), pivot: 58)
        case .runsOut:
            let look = kf(t, 3.8, [(0, 0), (0.35, 1), (0.7, 1), (1, 0)])
            pills(&ctx, y: 44 - 3 * look, h: 17, blink: kf(t, 3.8, [(0, 1), (0.92, 1), (0.95, 0.1), (1, 1)]), pivot: 52, dx: 1 + 3 * look)
        case .reached:
            let breath = kf(t, 3.2, [(0, 0), (0.5, 1), (1, 0)])
            let peek = kf(t, 7, [(0, 0), (0.6, 0), (0.64, 0.55), (0.72, 0.55), (0.78, 0), (1, 0)])
            for x in [39.0, 66.0] where !(x == 66 && peek > 0.05) {
                var p = Path()
                p.move(to: CGPoint(x: x, y: 60 + 1.5 * breath))
                p.addQuadCurve(to: CGPoint(x: x + 15, y: 60 + 1.5 * breath), control: CGPoint(x: x + 7.5, y: 66 - 0.9 * breath))
                ctx.stroke(p, with: .color(eye), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            if peek > 0.05 {
                ctx.fill(Path(roundedRect: squash(CGRect(x: 68, y: 54, width: 11, height: 12), peek, pivot: 60), cornerRadius: 5.5), with: .color(eye))
            }
        }
    }

    private func drawMouth(_ ctx: inout GraphicsContext) {
        switch mood {
        case .done, .back:
            var p = Path()
            p.move(to: CGPoint(x: 52, y: 76))
            p.addQuadCurve(to: CGPoint(x: 68, y: 76), control: CGPoint(x: 60, y: 83))
            ctx.stroke(p, with: .color(eye), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        case .needs:
            ctx.fill(Path(ellipseIn: CGRect(x: 55.5, y: 74, width: 9, height: 10)), with: .color(eye))
        case .risky, .warn, .runsOut:
            line(&ctx, [(53, 79), (67, 79)], 4)
        case .idle, .working, .reached:
            break
        }
    }

    private func drawExtras(_ ctx: inout GraphicsContext, t: Double, rim: Color) {
        switch mood {
        case .needs:
            let y = 20 + kf(t, 1.4, [(0, 0), (0.5, -3), (1, 0)])
            ctx.fill(Path(ellipseIn: CGRect(x: 85, y: y - 13, width: 26, height: 26)), with: .color(.orange))
            ctx.draw(Text("!").font(.system(size: 17, weight: .heavy)).foregroundColor(Color(red: 0.1, green: 0.07, blue: 0.02)),
                     at: CGPoint(x: 98, y: y))
        case .done, .back:
            for (i, (cx, cy, r)) in [(98.0, 24.0, 10.0), (18.0, 29.0, 7.0), (106.0, 70.0, 6.0)].enumerated() {
                let phase = t + Double(i) * 0.3
                let a = kf(phase, 1.2, [(0, 0), (0.4, 1), (1, 0)])
                let s = kf(phase, 1.2, [(0, 0.4), (0.4, 1), (1, 0.6)])
                ctx.fill(star(cx, cy, r * s), with: .color((mood == .done ? Color.green : rim).opacity(a)))
            }
        case .warn:
            let a = kf(t, 1.6, [(0, 0), (0.3, 1), (1, 0)])
            let y = kf(t, 1.6, [(0, -2), (1, 9)])
            var drop = Path()
            drop.move(to: CGPoint(x: 88, y: 30 + y))
            drop.addQuadCurve(to: CGPoint(x: 88, y: 43 + y), control: CGPoint(x: 96, y: 40 + y))
            drop.addQuadCurve(to: CGPoint(x: 88, y: 30 + y), control: CGPoint(x: 80, y: 40 + y))
            ctx.fill(drop, with: .color(Color(red: 0.49, green: 0.77, blue: 1).opacity(a)))
        case .runsOut:
            let face = Path(ellipseIn: CGRect(x: 85, y: 7, width: 26, height: 26))
            ctx.fill(face, with: .color(Color(red: 0.11, green: 0.13, blue: 0.15)))
            ctx.stroke(face, with: .color(.orange), lineWidth: 3)
            line(&ctx, [(98, 13), (98, 20), (103, 23)], 3, color: .orange)
        case .reached:
            for (i, (x, y, s)) in [(88.0, 30.0, 16.0), (100.0, 18.0, 12.0)].enumerated() {
                let phase = t + Double(i) * 0.8
                let a = kf(phase, 2.4, [(0, 0), (0.3, 1), (1, 0)])
                let m = kf(phase, 2.4, [(0, 0), (1, 1)])
                ctx.draw(Text("z").font(.system(size: s, weight: .heavy)).foregroundColor(Color(red: 0.62, green: 0.69, blue: 0.78).opacity(a)),
                         at: CGPoint(x: x + 6 * m, y: y - 6 + 6 - 16 * m))
            }
        case .idle, .working, .risky:
            break
        }
    }

    private func bodyMove(_ sc: Double) -> (Double, Double, Double, Double, Double) {
        switch mood {
        case .needs where sc < 1.8:
            return (0, kf(sc, 0.9, [(0, 0), (0.35, -9), (0.6, 0), (1, 0)]), 0, 1, 1)
        case .risky where sc < 1.5:
            return (kf(sc, 0.5, [(0, 0), (0.2, -5), (0.4, 5), (0.6, -4), (0.8, 3), (1, 0)]), 0,
                    kf(sc, 0.5, [(0, 0), (0.2, -4), (0.4, 4), (0.6, -3), (0.8, 2), (1, 0)]), 1, 1)
        case .done where sc < 1.4:
            return (0, kf(sc, 0.7, [(0, 0), (0.4, -10), (1, 0)]), kf(sc, 0.7, [(0, 0), (0.4, -5), (1, 0)]), 1, 1)
        case .warn where sc < 2.6, .runsOut where sc < 2.6:
            return (0, 0, kf(sc, 1.3, [(0, 0), (0.25, -6), (0.75, 6), (1, 0)]), 1, 1)
        case .reached:
            let p = ease(min(sc / 1.2, 1))
            return (0, 5 * p, -8 * p, 1, 1)
        case .back where sc < 0.9:
            return (0, kf(sc, 0.9, [(0, 0), (0.4, -4), (1, 0)]), 0,
                    kf(sc, 0.9, [(0, 1), (0.4, 0.92), (1, 1)]), kf(sc, 0.9, [(0, 1), (0.4, 1.12), (1, 1)]))
        default:
            return (0, 0, 0, 1, 1)
        }
    }

    private func pills(_ ctx: inout GraphicsContext, y: Double, h: Double, blink: Double, pivot: Double, dx: Double = 0) {
        for x in [41.0, 68.0] {
            let r = squash(CGRect(x: x + dx, y: y, width: 11, height: h), blink, pivot: pivot)
            ctx.fill(Path(roundedRect: r, cornerRadius: min(5.5, r.height / 2)), with: .color(eye))
        }
    }

    private func squash(_ r: CGRect, _ s: Double, pivot: Double) -> CGRect {
        CGRect(x: r.minX, y: pivot + (r.minY - pivot) * s, width: r.width, height: max(r.height * s, 1))
    }

    private func line(_ ctx: inout GraphicsContext, _ pts: [(Double, Double)], _ w: Double, color: Color? = nil) {
        var p = Path()
        p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) })
        ctx.stroke(p, with: .color(color ?? eye), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }

    private func arc(from a: Double, to b: Double) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: 60, y: 60), radius: 52, startAngle: .degrees(-90 + 360 * a), endAngle: .degrees(-90 + 360 * b), clockwise: false)
        return p
    }

    private func star(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
        var p = Path()
        let pts = (0..<8).map { i -> CGPoint in
            let a = Double(i) * .pi / 4 - .pi / 2
            let d = i.isMultiple(of: 2) ? r : r * 0.3
            return CGPoint(x: cx + cos(a) * d, y: cy + sin(a) * d)
        }
        p.addLines(pts)
        p.closeSubpath()
        return p
    }
}

/// Keyframes over a repeating period: `stops` are (fraction of the period, value), eased between.
private func kf(_ t: Double, _ period: Double, _ stops: [(Double, Double)]) -> Double {
    let f = (t / period).truncatingRemainder(dividingBy: 1)
    guard let next = stops.firstIndex(where: { $0.0 >= f }), next > 0 else { return stops.first?.1 ?? 0 }
    let (f0, v0) = stops[next - 1], (f1, v1) = stops[next]
    return v0 + (v1 - v0) * ease((f - f0) / max(f1 - f0, 0.0001))
}

private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
