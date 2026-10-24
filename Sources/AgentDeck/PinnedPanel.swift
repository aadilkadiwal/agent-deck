import AppKit
import AgentDeckCore
import SwiftUI

@MainActor
final class PinnedPanel: NSObject, NSWindowDelegate {
    static let shared = PinnedPanel()
    static let key = "pinned"
    private var panel: NSPanel?
    private weak var model: AppModel?

    func toggle(_ model: AppModel) {
        if panel == nil { show(model) } else { panel?.close() }
    }

    func show(_ model: AppModel) {
        if let panel { panel.orderFrontRegardless(); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Agent Deck"
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentMinSize = NSSize(width: 300, height: 160)
        p.contentView = NSHostingView(rootView: PinnedView(model: model))
        p.delegate = self
        if !p.setFrameUsingName("AgentDeckPinned"), let screen = NSScreen.main?.visibleFrame {
            p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - p.frame.width - 16, y: screen.maxY - 16))
        }
        p.setFrameAutosaveName("AgentDeckPinned")
        p.orderFrontRegardless()
        panel = p
        self.model = model
        model.pinnedOpen = true
        UserDefaults.standard.set(true, forKey: Self.key)
    }

    func windowWillClose(_ notification: Notification) {
        panel?.delegate = nil
        panel = nil
        model?.pinnedOpen = false
        UserDefaults.standard.set(false, forKey: Self.key)
    }
}

struct PinnedView: View {
    let model: AppModel

    private var rows: [LiveSession] {
        let carded = Set(model.approvals.map(\.sessionId))
        return model.live.filter { !carded.contains($0.sessionId) }
    }

    var body: some View {
        let hotkeyTarget = model.pendingApprovals.first { $0.kind == .permission }?.id
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                CompactUsage(model: model) { model.showDetails?(.usage) }
                ForEach(model.approvals) {
                    ApprovalCard(model: model, request: $0, hotkeyTarget: $0.id == hotkeyTarget)
                        .transition(.opacity)
                }
                if !model.approvals.isEmpty && !rows.isEmpty { Divider().padding(.vertical, 2) }
                ForEach(rows) { PinnedRow(model: model, session: $0) }
                if model.live.isEmpty {
                    Text("No sessions running.").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                }
            }
            .padding(10)
            .animation(.easeOut(duration: 0.2), value: model.approvals.map(\.id))
        }
        .frame(minWidth: 300, minHeight: 160)
    }
}

private struct PinnedRow: View {
    let model: AppModel
    let session: LiveSession

    var body: some View {
        let s = session
        let waiting = s.state == .blocked && !s.isLeftover
        HoverRow {
            Capsule().fill(waiting ? Color.orange : SessionColor.of(s.sessionId)).frame(width: 3, height: 18)
            StateDot(state: s.isLeftover ? nil : s.state, animated: true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(model.displayName(s)).font(.system(size: 12, weight: waiting ? .semibold : .medium)).lineLimit(1)
                    if s.isOnPhone { Image(systemName: "iphone").font(.system(size: 10)).foregroundStyle(Color.accentColor) }
                }
                if ActivityLine.isShown(s, model) { ActivityLine(model: model, session: s) }
            }
            Spacer(minLength: 4)
            if let c = model.context[s.sessionId] { ContextBar(reading: c) }
        } action: { model.open(s) }
        .background { if waiting { RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.08)) } }
        .help(s.kind == .interactive ? "Show its window" : "Open in iTerm")
    }
}
