import AgentDeckCore
import SwiftUI

struct SectionHeader: View {
    let title: String
    var trailing: String?
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}

struct StateDot: View {
    let state: LiveSession.State?
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: String {
        state.map { $0 == .busy ? "Working" : $0 == .idle ? "Idle" : "Waiting for you" } ?? "Closed"
    }

    var body: some View {
        let loops = animated && !reduceMotion && (state == .busy || state == .blocked)
        // Phase comes from the clock, not from when this dot appeared, so every working dot pulses together.
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !loops)) { tl in
            let phase = loops ? Motion.beat(tl.date) : 0
            ZStack {
                switch state {
                case .busy: Circle().fill(Color.blue).opacity(1 - 0.45 * (1 - cos(2 * .pi * phase)) / 2)
                case .idle: Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                case .blocked:
                    Circle().fill(Color.orange).scaleEffect(1 + 0.9 * phase).opacity(loops ? 0.5 * (1 - phase) : 0)
                    Circle().fill(Color.orange)
                case nil: Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                }
            }
        }
        .keyframeAnimator(initialValue: 1.0, trigger: state) { [still = reduceMotion] v, scale in
            v.scaleEffect(still ? 1 : scale)
        } keyframes: { _ in
            SpringKeyframe(1.25, duration: 0.12)
            SpringKeyframe(1.0, duration: 0.2)
        }
        .frame(width: 9, height: 9)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .orange
    var body: some View {
        Text(text).font(.subheadline.weight(.bold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}

struct ContextBar: View {
    let reading: ContextReading
    var body: some View {
        let percent = reading.percent
        let tint = Self.tint(percent)
        HStack(spacing: 4) {
            Capsule().fill(Color.primary.opacity(0.12)).frame(width: 36, height: 4)
                .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: 36 * CGFloat(percent) / 100, height: 4) }
            Text("\(percent)%").monospacedDigit().foregroundStyle(tint)
        }
        .help("Context: \(percent)% used · updated \(Fmt.ago(reading.updatedAt))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(percent) percent used")
    }

    static let warnAt = 70
    static func tint(_ percent: Int) -> Color { percent >= 90 ? .red : percent >= warnAt ? .orange : .secondary }
}

struct IconButton: View {
    let symbol: String
    var on = false
    var tint: Color?
    let help: String
    var dimmed = false
    let action: () -> Void
    var body: some View {
        let color = tint ?? (on ? Color.accentColor : nil)
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 28, height: 24)
                .foregroundStyle(color ?? .secondary)
                .background(RoundedRectangle(cornerRadius: Radius.inner).fill(color?.opacity(0.15) ?? .clear))
        }
        .buttonStyle(.borderless)
        .disabled(dimmed)
        .opacity(dimmed ? 0.35 : 1)
        .accessibilityLabel(help)
        // A disabled button shows no tooltip, so the reason it's unavailable hangs on the frame around it.
        .contentShape(Rectangle())
        .help(help)
    }
}

struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.8 : 1)
            .animation(Motion.fast(reduceMotion), value: configuration.isPressed)
    }
}

struct RenameField: View {
    let initial: String
    let done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { save() }
            .onAppear { text = initial; focused = true }
        Button("Cancel") { done(nil) }
        Button("Save") { save() }.keyboardShortcut(.defaultAction)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        done(t == initial ? nil : t)
    }
}

struct ReplyField: View {
    let queued: Bool
    let done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Reply to Claude", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { send() }
            .onAppear { focused = true }
        Button("Cancel") { done(nil) }
        Button(queued ? "Queue" : "Send") { send() }.keyboardShortcut(.defaultAction)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        done(t)
    }
}

// `.activate` focus only exists with Keyboard navigation on, so a click never leaves a focus ring.
struct HoverRow<Content: View>: View {
    var selected = false
    var open: (() -> Void)?
    @ViewBuilder let content: Content
    let action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let row = HStack(spacing: 8) { content }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(hover || focused || selected ? Color.primary.opacity(0.07) : .clear))
            .overlay {
                if focused || selected { RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5) }
            }
            .animation(Motion.fast(reduceMotion), value: hover)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
        Group {
            if let open { row.onTapGesture(count: 2, perform: open).onTapGesture(perform: action) }
            else { row.onTapGesture(perform: action) }
        }
        .focusable(interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return) { (open ?? action)(); return .handled }
        .onKeyPress(.space) { action(); return .handled }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityAction(named: "Open") { (open ?? action)() }
    }
}



func highlighted(_ text: String, _ query: String) -> AttributedString {
    var out = AttributedString(text)
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return out }
    var from = out.startIndex
    while let r = out[from...].range(of: q, options: .caseInsensitive) {
        out[r].backgroundColor = Color.accentColor.opacity(0.25)
        from = r.upperBound
    }
    return out
}

struct ActivityLine: View {
    let model: AppModel
    let session: LiveSession
    var prefix: String?

    static func isShown(_ s: LiveSession, _ model: AppModel) -> Bool {
        s.isLeftover || s.state != .idle || (model.activity[s.sessionId]?.subagents.isEmpty == false)
    }

    var body: some View {
        let s = session
        let a = model.activity[s.sessionId]
        let agents = a.map(\.subagents.count).flatMap { $0 > 0 ? "\(Fmt.count($0, "agent"))" : nil }
        let doing = s.state == .busy ? a?.tool.map { t in a?.detail.map { "\(t): \($0)" } ?? t } : nil
        let timed = s.state == .busy && model.busySince[s.sessionId] != nil
        let status = Self.isShown(s, model) ? [doing ?? (timed ? nil : Self.stateText(s)), agents].compactMap { $0 }.joined(separator: " · ") : ""
        let tint: Color = s.state == .blocked && !s.isLeftover ? .orange : .secondary
        // The folder gives way first, so the status and its timer stay readable.
        HStack(spacing: 0) {
            if let prefix {
                Text(prefix).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            if !status.isEmpty || timed {
                let lead = prefix == nil ? "" : " · "
                Group {
                    if let since = model.busySince[s.sessionId], s.state == .busy {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let t = max(0, Int(ctx.date.timeIntervalSince(since)))
                            Text("\(lead)\(status.isEmpty ? "" : status + " ")\(t / 60):\(String(format: "%02d", t % 60))")
                                .accessibilityLabel("working for \(t / 60) minutes \(t % 60) seconds")
                        }
                    } else {
                        Text(lead + status)
                    }
                }
                .foregroundStyle(tint).lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            }
        }
        .font(.subheadline)
    }

    static func stateText(_ s: LiveSession) -> String {
        if s.isLeftover { return "ended" }
        switch s.state {
        case .busy: return "working"
        case .idle: return "idle"
        case .blocked: return "waiting for you"
        }
    }
}

struct Callout<Content: View>: View {
    let tint: Color
    var outlined = false
    var alignment = VerticalAlignment.center
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: 8) { content }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(tint.opacity(0.12)))
            .overlay { if outlined { RoundedRectangle(cornerRadius: Radius.row).strokeBorder(tint.opacity(0.5)) } }
    }
}

struct ConfirmRow: View {
    let message: String
    let confirmTitle: String
    var destructive = false
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel", action: cancel)
            if destructive {
                Button(confirmTitle, role: .destructive, action: confirm)
            } else {
                Button(confirmTitle, action: confirm).keyboardShortcut(.defaultAction)
            }
        }
    }
}

extension View {
    func confirmBar() -> some View {
        font(.callout)
            .controlSize(.small)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color.accentColor.opacity(0.1)))
    }
}

enum Radius {
    static let inner: CGFloat = 6
    static let row: CGFloat = 8
    static let panel: CGFloat = 10
}

struct LastHourBar: View {
    let model: AppModel
    var collapsible = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Part: Identifiable { let id: String, name: String, points: Double, color: Color }

    private var parts: [Part] {
        let h = model.lastHour
        let tokens = model.recentUse.tokens.filter { t in model.live.contains { $0.sessionId == t.key } }
        let sum = Double(max(tokens.values.reduce(0, +), 1))
        var parts = tokens.sorted { $0.value > $1.value }.compactMap { id, n in
            model.live.first { $0.sessionId == id }.map { Part(id: id, name: model.displayName($0), points: h.mine * Double(n) / sum, color: SessionColor.of(id)) }
        }
        if parts.isEmpty && h.mine > 0 { parts = [Part(id: "mac", name: "This Mac", points: h.mine, color: .teal)] }
        if h.others > 0 { parts.append(Part(id: "others", name: "Other Macs on your account", points: h.others, color: Color.secondary.opacity(0.6))) }
        return parts.filter { $0.points > 0 }
    }

    var body: some View {
        let total = model.lastHour.total
        if total >= 1 {
            let parts = parts
            let sessions = parts.filter { $0.id != "others" && $0.id != "mac" }.count
            let others = parts.contains { $0.id == "others" }
            let open = expanded || !collapsible
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(Motion.snappy(reduceMotion)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Last hour").fontWeight(.semibold)
                        Text(open ? "+\(Int(total.rounded()))% of the 5-hour limit"
                             : "+\(Int(total.rounded()))% · \([sessions > 0 ? Fmt.count(sessions, "session") : nil, others ? "other Macs" : nil].compactMap { $0 }.joined(separator: " + "))")
                            .foregroundStyle(.secondary).lineLimit(1)
                        if collapsible {
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(open ? 90 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!collapsible)
                .help(collapsible ? (open ? "Hide the split by session" : "Show the split by session") : "")
                if open {
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(parts) { p in
                            RoundedRectangle(cornerRadius: 2).fill(p.color)
                                .frame(width: max(3, (g.size.width - CGFloat(parts.count - 1) * 2) * p.points / total))
                        }
                    }
                }
                .frame(height: 6)
                ForEach(parts.prefix(4)) { p in
                    HStack(spacing: 6) {
                        Circle().fill(p.color).frame(width: 6, height: 6)
                        Text(p.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(p.points < 1 ? "<1%" : "\(Int(p.points.rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                }
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
        }
    }
}

struct LimitStopLine: View {
    let model: AppModel
    let session: LiveSession

    var body: some View {
        let queued = model.continueQueue.contains(session.sessionId)
        let at = model.limitHit?.resetsAt.map(Fmt.clock)
        let blocker = model.typingBlockers[session.sessionId]
        VStack(alignment: .leading, spacing: 3) {
            Text("Stopped at the limit").foregroundStyle(.orange).lineLimit(1)
            Button {
                model.toggleContinue(session)
            } label: {
                Label(queued ? "Continues at \(at ?? "reset")" : at.map { "Continue at \($0)" } ?? "Continue now",
                      systemImage: queued ? "checkmark.circle.fill" : "play.circle")
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(queued ? 0.25 : 0.12)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(blocker != nil)
            .help(blocker ?? (queued ? "Click to cancel" : "Types \"continue\" into it the moment the limit resets"))
        }
        .font(.subheadline)
    }
}
