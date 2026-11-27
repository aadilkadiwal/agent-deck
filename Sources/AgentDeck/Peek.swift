import AgentDeckCore
import AppKit
import SwiftUI

struct PeekAlert {
    enum Kind {
        case needs, risky, done, warn, runsOut, reached, back

        var mood: DotMood {
            switch self {
            case .needs: .needs
            case .risky: .risky
            case .done: .done
            case .warn: .warn
            case .runsOut: .runsOut
            case .reached: .reached
            case .back: .back
            }
        }
        var word: String {
            switch self {
            case .needs: "Waiting for you"
            case .risky: "Careful"
            case .done: "Done"
            case .warn: "Close to the limit"
            case .runsOut: "Running out"
            case .reached: "Limit reached"
            case .back: "You're back"
            }
        }
        var sound: String {
            switch self {
            case .needs, .risky: "DotNeeds"
            case .warn, .runsOut, .reached: "DotLimit"
            case .done, .back: "DotDone"
            }
        }
        /// Seconds on screen; questions stay until answered or clicked away.
        var seconds: Double? {
            switch self {
            case .needs, .risky: nil
            case .warn, .runsOut, .reached: 6
            case .done, .back: 4
            }
        }
        var isLimit: Bool { self == .warn || self == .runsOut || self == .reached }
    }

    struct Action {
        enum Style { case plain, primary, danger }
        let title: String
        var style = Style.plain
        var done: String?
        let run: () -> Void
    }

    let id: String
    let kind: Kind
    let title: String
    var meta: String?
    var code: String?
    var lines: [String] = []
    var percent: Double?
    var actions: [Action] = []
    var celebrate = true
    var seconds: Double?
    var quiet = false
    var tag: String?
    var soft = false
    var lifetime: Double? { seconds ?? kind.seconds }
}

enum PeekPlacement: String, CaseIterable {
    case automatic, menuBar, banners
    static let key = "peekPlacement"
    static var current: PeekPlacement { PeekPlacement(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic }
    var label: String {
        switch self {
        case .automatic: "At the notch"
        case .menuBar: "Under the menu bar icon"
        case .banners: "As macOS notifications"
        }
    }
}

@MainActor @Observable
final class PeekState {
    enum Shape: Equatable { case notch(width: CGFloat, height: CGFloat), icon, top }
    var alert: PeekAlert?
    var shape = Shape.icon
    var wide = false
    var open = false
    var progress = 1.0
    var doneText: String?
    var percent: Double?
}

@MainActor
enum Peek {
    static let width: CGFloat = 400
    private static let margin: CGFloat = 24   // room for the shadow
    private static let state = PeekState()
    private static var panel: PeekPanel?
    private static var queue: [PeekAlert] = []
    private static var countdown: Task<Void, Never>?
    private static var monitors: [Any] = []
    private static var closing = false

    /// Shows the alert and returns true, or returns false when it should go out as a macOS notification instead.
    static func show(_ alert: PeekAlert, percent: Double?) -> Bool {
        guard PeekPlacement.current != .banners, !userAway else { return false }
        var alert = alert
        alert.percent = alert.percent ?? percent
        if state.alert != nil {
            queue.removeAll { $0.id == alert.id }
            queue.append(alert)
        } else {
            present(alert)
        }
        return true
    }

    static func dismiss(id: String) {
        queue.removeAll { $0.id == id }
        // After a click in the peek it closes itself, once its "Allowed" has shown.
        if state.alert?.id == id, state.doneText == nil { close() }
    }

    static func close() {
        // Once: a second close mid-animation would also hide the alert queued behind this one.
        guard state.alert != nil, !closing else { return }
        closing = true
        countdown?.cancel()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        withAnimation(.easeIn(duration: 0.16)) { state.open = false }
        Task {
            try? await Task.sleep(nanoseconds: 140_000_000)
            withAnimation(.easeIn(duration: 0.12)) { state.wide = false }
            try? await Task.sleep(nanoseconds: 160_000_000)
            panel?.orderOut(nil)
            state.alert = nil
            state.doneText = nil
            closing = false
            if !queue.isEmpty { present(queue.removeFirst()) }
        }
    }

    static func finish(_ text: String?) {
        countdown?.cancel()
        guard let text else { close(); return }
        withAnimation(.easeOut(duration: 0.15)) { state.doneText = text }
        resize()
        countdown = Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled { close() }
        }
    }

    private static func present(_ alert: PeekAlert) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let place = placement() else { return }
        state.alert = alert
        state.percent = alert.percent
        state.shape = place.0
        state.open = false
        state.wide = false
        state.progress = 1
        state.doneText = nil
        resize(anchor: place)
        panel.orderFrontRegardless()
        if !alert.quiet, let sound = NSSound(named: alert.kind.sound) {
            if alert.soft { sound.volume = 0.4 }
            sound.play()
        }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "\(alert.kind.word). \(alert.title)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        Task {
            withAnimation(.easeOut(duration: 0.14)) { state.wide = true }
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { state.open = true }
        }
        // Any click elsewhere closes it, like a menu. Questions stay in the dropdown.
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in close() },
                    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
                        if e.window !== panel { close() }
                        return e
                    }].compactMap { $0 }
        countdown?.cancel()
        if let seconds = alert.lifetime { countdown = Task { await run(seconds) } }
    }

    // Hovering holds the timer, so an alert being read doesn't vanish.
    private static func run(_ seconds: Double) async {
        var left = seconds
        while left > 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            if let p = panel, p.frame.contains(NSEvent.mouseLocation) { continue }
            left -= 0.1
            state.progress = max(left / seconds, 0)
        }
        close()
    }

    private static var anchor: (shape: PeekState.Shape, x: CGFloat, top: CGFloat, alignRight: Bool)?

    private static func resize(anchor new: (PeekState.Shape, CGFloat, CGFloat, Bool)? = nil) {
        if let new { anchor = (new.0, new.1, new.2, new.3) }
        guard let panel, let anchor, let host = panel.contentView else { return }
        let height = host.fittingSize.height
        let x = anchor.alignRight ? anchor.x - width - margin : anchor.x - width / 2 - margin
        panel.setFrame(NSRect(x: x, y: anchor.top - height, width: width + 2 * margin, height: height), display: true)
    }

    /// Notch when the screen you're on has one, else under Dot's menu bar icon, else (menu bar hidden) the top edge.
    private static func placement() -> (PeekState.Shape, CGFloat, CGFloat, Bool)? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return nil }
        let frame = screen.frame
        if PeekPlacement.current == .automatic, screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = frame.width - left.width - right.width
            return (.notch(width: notch, height: screen.safeAreaInsets.top), frame.midX, frame.maxY, false)
        }
        if let icon = StatusMenu.buttonFrame, NSMouseInRect(NSPoint(x: icon.midX, y: icon.midY), frame, false),
           frame.maxY - screen.visibleFrame.maxY > 0 {
            return (.icon, min(icon.maxX, frame.maxX - 8), icon.minY - 6, true)
        }
        return (.top, frame.midX, frame.maxY, false)
    }

    private static func makePanel() -> PeekPanel {
        let p = PeekPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // It can show commands and project names: keep it out of screen sharing and recordings.
        p.sharingType = .none
        let host = ClickHost(rootView: PeekView(state: state).padding(.horizontal, margin).padding(.bottom, margin))
        host.onResize = { resize() }
        p.contentView = host
        return p
    }

    /// Nobody would see it: the screen is locked or asleep, or there's been no input for two minutes.
    private static var userAway: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return idle > 120
    }
}

private final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons work on the first click without making Agent Deck active, so typing stays in your app.
private final class ClickHost<Content: View>: NSHostingView<Content> {
    var onResize: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
}

private struct PeekView: View {
    let state: PeekState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let ink = Color(red: 0.043, green: 0.047, blue: 0.059)

    var body: some View {
        if let alert = state.alert {
            content(alert)
                .frame(width: Peek.width, alignment: .leading)
                .opacity(state.open ? 1 : 0)
                .background(shape.fill(Self.ink).shadow(color: .black.opacity(state.open ? 0.45 : 0), radius: 18, y: 10))
                .clipShape(shape)
                .mask(alignment: .top) { reveal }
                .offset(y: offset)
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var shape: UnevenRoundedRectangle {
        switch state.shape {
        case .icon: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 18, bottomLeading: 18, bottomTrailing: 18, topTrailing: 18), style: .continuous)
        case .notch, .top: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 26, bottomTrailing: 26, topTrailing: 0), style: .continuous)
        }
    }

    /// The notch version grows out of the notch: the visible part starts at the notch's size.
    @ViewBuilder private var reveal: some View {
        if case .notch(let w, let h) = state.shape, !reduceMotion {
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: state.open ? 26 : 12, bottomTrailing: state.open ? 26 : 12, topTrailing: 0))
                .frame(width: state.wide ? Peek.width : w, height: state.open ? 2000 : h)
        } else {
            Rectangle()
        }
    }

    private var offset: CGFloat {
        guard !reduceMotion, !state.open else { return 0 }
        switch state.shape {
        case .notch: return 0
        case .icon: return -18
        case .top: return -200
        }
    }

    @ViewBuilder private func content(_ a: PeekAlert) -> some View {
        let color = Dot.moodColor(a.kind.mood)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Dot(mood: a.kind.mood, percent: state.percent, size: 56, celebrate: a.celebrate)
                VStack(alignment: .leading, spacing: 2) {
                    Text((a.tag ?? a.kind.word).uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(color)
                    Text(a.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let meta = a.meta {
                        Text(meta).font(.system(size: 11)).foregroundStyle(Color(white: 0.62)).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            if let code = a.code, !code.isEmpty {
                Text(code).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.88)).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(Color(red: 0.086, green: 0.094, blue: 0.114), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(a.kind == .risky ? Color.red.opacity(0.55) : Color(white: 0.16)))
            }
            if !a.lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(a.lines, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Color(white: 0.78)) }
                }
            }
            if let done = state.doneText {
                Label(done, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color(white: 0.7))
                    .symbolRenderingMode(.multicolor)
            } else if !a.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(a.actions.enumerated()), id: \.offset) { _, action in
                        Button(action.title) {
                            // The confirmation shows first: answering dismisses this alert, unless it's confirming.
                            Peek.finish(action.done)
                            action.run()
                        }
                        .buttonStyle(PeekButton(style: action.style))
                    }
                }
            }
            if a.lifetime != nil, state.doneText == nil {
                GeometryReader { g in
                    Capsule().fill(Color(white: 0.35)).frame(width: g.size.width * state.progress)
                }
                .frame(height: 2)
                .background(Capsule().fill(Color(white: 0.13)))
            }
        }
        .padding(16)
        .padding(.top, topInset)
    }

    private var topInset: CGFloat {
        if case .notch(_, let h) = state.shape { return h - 6 }
        return 0
    }
}

private struct PeekButton: ButtonStyle {
    let style: PeekAlert.Action.Style
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(style == .primary ? Color.black : style == .danger ? Color(red: 1, green: 0.54, blue: 0.5) : .white)
            .background(Capsule().fill(style == .primary ? Color(white: 0.95) : style == .danger ? Color(red: 0.23, green: 0.08, blue: 0.07) : Color(white: 0.14)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}
