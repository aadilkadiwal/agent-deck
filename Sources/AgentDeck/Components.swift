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
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
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
        let loops = animated && !reduceMotion, still = reduceMotion
        Group {
            switch state {
            case .busy:
                Circle().fill(Color.green)
                    .phaseAnimator(loops ? [1.0, 0.55] : [1.0]) { c, o in c.opacity(o) } animation: { _ in .easeInOut(duration: 0.6) }
            case .idle: Circle().strokeBorder(Color.green, lineWidth: 1.5)
            case .blocked: Circle().fill(Color.orange)
            case nil: Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            }
        }
        .background {
            if loops && state == .blocked {
                Circle().fill(Color.orange)
                    .phaseAnimator([false, true]) { c, on in
                        c.scaleEffect(on ? 1.9 : 1).opacity(on ? 0 : 0.5)
                    } animation: { on in on ? .easeOut(duration: Motion.pulse) : nil }
            }
        }
        .keyframeAnimator(initialValue: 1.0, trigger: state) { v, scale in
            v.scaleEffect(still ? 1 : scale)
        } keyframes: { _ in
            SpringKeyframe(1.25, duration: 0.12)
            SpringKeyframe(1.0, duration: 0.2)
        }
        .animation(Motion.snappy(reduceMotion), value: state)
        .frame(width: 9, height: 9)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .orange
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}

struct ContextBar: View {
    let reading: ContextReading
    var body: some View {
        let percent = reading.percent
        let tint: Color = percent >= 90 ? .red : .secondary
        HStack(spacing: 4) {
            Capsule().fill(Color.primary.opacity(0.12)).frame(width: 36, height: 4)
                .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: 36 * CGFloat(percent) / 100, height: 4) }
            Text("\(percent)%").monospacedDigit().foregroundStyle(tint)
        }
        .help("Context: \(percent)% used · updated \(Fmt.ago(reading.updatedAt))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(percent) percent used")
    }
}

struct IconButton: View {
    let symbol: String
    var on = false
    let help: String
    var dimmed = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 26, height: 22)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.15) : .clear))
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
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover || focused || selected ? Color.primary.opacity(0.07) : .clear))
            .overlay {
                if focused || selected { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5) }
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
