import AgentDeckCore
import SwiftUI

struct ApprovalCard: View {
    @ObservedObject var model: AppModel
    let request: ApprovalRequest
    var hotkeyTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.orange)
                Circle().fill(SessionColor.of(request.sessionId)).frame(width: 7, height: 7)
                Text(model.sessionName(request.sessionId, cwd: request.cwd)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = max(0, Int(ctx.date.timeIntervalSince(request.receivedAt)))
                    Text(String(format: "%d:%02d", s / 60, s % 60)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                IconButton(symbol: "terminal", help: "Show it in the terminal instead") { model.openSession(id: request.sessionId) }
            }
            if let d = request.description, request.kind == .permission {
                Text(d).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if !request.detail.isEmpty {
                ScrollView {
                    Text(styledDetail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: request.kind == .plan ? 180 : 120)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
            switch request.kind {
            case .permission: permissionButtons
            case .plan: planButtons
            case .question: QuestionForm(questions: request.questions) { model.answer(request.id, .answers($0)) }
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    private var styledDetail: AttributedString {
        guard request.kind == .permission, ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(request.toolName) else {
            return AttributedString(request.detail)
        }
        var out = AttributedString()
        for (i, line) in request.detail.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var a = AttributedString((i == 0 ? "" : "\n") + line)
            a.foregroundColor = i == 0 ? .secondary : line.hasPrefix("- ") ? .red : line.hasPrefix("+ ") ? .green : .primary
            out += a
        }
        return out
    }

    private var icon: String {
        switch request.kind {
        case .permission: return "hand.raised.fill"
        case .plan: return "list.bullet.clipboard"
        case .question: return "questionmark.bubble.fill"
        }
    }

    private var title: String {
        switch request.kind {
        case .permission: return "\(request.agent == .claude ? "" : "(\(request.agent.label)) ")wants to use \(request.toolName)"
        case .plan: return "has a plan for you"
        case .question: return request.questions.count == 1 ? "asks" : "asks \(request.questions.count) questions"
        }
    }

    private var permissionButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Deny", role: .destructive) { model.answer(request.id, .deny) }
                Spacer()
                if request.alwaysLabel != nil {
                    Button("Always allow") { model.answer(request.id, .allow(always: true)) }
                }
                Button("Allow") { model.answer(request.id, .allow(always: false)) }.buttonStyle(.borderedProminent)
            }
            if let rule = request.alwaysLabel {
                Text("Always allow saves \(rule)").font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(rule)
            }
            if hotkeyTarget {
                Text("⌃⌥A allow · ⌃⌥D deny, from any app").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var planButtons: some View {
        HStack {
            Spacer()
            Button("Approve, auto-accept edits") { model.approvePlan(request, acceptEdits: true) }
                .help("Approve, and let Claude make file edits in this session without asking")
            Button("Approve plan") { model.approvePlan(request, acceptEdits: false) }.buttonStyle(.borderedProminent)
        }
    }
}

struct QuestionForm: View {
    let questions: [ApprovalRequest.Question]
    let send: ([String: String]) -> Void
    @State private var picked: [String: [String]] = [:]
    @State private var other: [String: String] = [:]

    private var instant: Bool { questions.count == 1 && !questions[0].multiSelect }

    private func answer(_ q: ApprovalRequest.Question) -> String {
        let typed = (other[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ((picked[q.question] ?? []) + (typed.isEmpty ? [] : [typed])).joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(questions, id: \.question) { q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(q.question).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    ForEach(q.options, id: \.label) { o in option(q, o) }
                    TextField("Other…", text: Binding(get: { other[q.question] ?? "" }, set: { other[q.question] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if instant, !answer(q).isEmpty { send([q.question: answer(q)]) } }
                }
            }
            if !instant {
                HStack {
                    Spacer()
                    Button("Send") { send(Dictionary(uniqueKeysWithValues: questions.map { ($0.question, answer($0)) })) }
                        .buttonStyle(.borderedProminent)
                        .disabled(questions.contains { answer($0).isEmpty })
                }
            }
        }
    }

    @ViewBuilder private func option(_ q: ApprovalRequest.Question, _ o: ApprovalRequest.Option) -> some View {
        let on = picked[q.question]?.contains(o.label) ?? false
        Button {
            if instant { send([q.question: o.label]); return }
            var list = picked[q.question] ?? []
            if q.multiSelect { if on { list.removeAll { $0 == o.label } } else { list.append(o.label) } } else { list = [o.label] }
            picked[q.question] = list
        } label: {
            HStack(alignment: .top, spacing: 6) {
                if !instant { Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.label).font(.system(size: 12, weight: .medium))
                    if !o.description.isEmpty { Text(o.description).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
