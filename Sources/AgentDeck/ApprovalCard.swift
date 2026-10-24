import AgentDeckCore
import SwiftUI

struct ApprovalCard: View {
    let model: AppModel
    let request: ApprovalRequest
    var hotkeyTarget = false
    var roomy = false
    var selected = false
    @State private var expanded = false
    @State private var denying = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let previewLines = 8

    private var outcome: ApprovalAnswer? { model.outcomes[request.id] }
    private var risk: String? { request.risk }
    private var tint: Color {
        switch outcome {
        case .deny, .denyWith: .red
        case .allow, .acceptEdits, .answers: .green
        case .terminal: .orange
        case nil: risk == nil ? .orange : .red
        }
    }

    private var place: String? {
        let name = model.sessionName(request.sessionId, cwd: request.cwd)
        let folder = Fmt.folderName(request.cwd)
        let branch = model.branches[request.cwd].map { "⎇ \($0)" }
        let parts = [folder == name || folder.isEmpty ? nil : folder, branch].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(SessionColor.of(request.sessionId)).frame(width: 7, height: 7)
                Text(model.sessionName(request.sessionId, cwd: request.cwd)).font(.body.weight(.semibold)).lineLimit(1)
                    .layoutPriority(1)
                if let place {
                    Text("· \(place)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = max(0, Int(ctx.date.timeIntervalSince(request.receivedAt)))
                    Text(String(format: "%d:%02d", s / 60, s % 60)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText(countsDown: false))
                        .animation(Motion.fast(reduceMotion), value: s)
                }
                IconButton(symbol: "terminal", help: "Show it in the terminal instead") { model.openSession(id: request.sessionId) }
            }
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(risk == nil ? Color.orange : Color.red)
                    .symbolEffect(.bounce, value: arrived)
                Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if let risk {
                    Text("RISKY · \(risk)")
                        .font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                        .help("This command \(risk). It can't be allowed with ⌃⌥A or ⌘⏎; click Allow once if you mean it.")
                }
            }
            .accessibilityElement(children: .combine)
            if let d = request.description, request.kind == .permission {
                Text(d).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !request.detail.isEmpty {
                let lines = request.detail.split(separator: "\n", omittingEmptySubsequences: false)
                let long = !roomy && lines.count > Self.previewLines
                ScrollView {
                    Text(styled(long && !expanded ? lines.prefix(Self.previewLines).joined(separator: "\n") : request.detail))
                        .font(request.kind == .plan ? .callout : .subheadline.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: roomy ? 520 : expanded ? 260 : 150)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Color.primary.opacity(0.06)))
                if long {
                    Button(expanded ? "Show less" : "Show all \(lines.count) lines") { withAnimation(Motion.spring(reduced: reduceMotion)) { expanded.toggle() } }
                        .buttonStyle(.link).font(.subheadline)
                }
            }
            switch request.kind {
            case .permission: permissionButtons
            case .plan: planButtons
            case .question: QuestionForm(questions: request.questions) { model.answer(request.id, .answers($0)) }
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(8)
        .padding(.leading, 4)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(tint.opacity(0.1)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Radius.row, bottomLeadingRadius: Radius.row).fill(tint).frame(width: 4)
        }
        .overlay { if selected { RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Color.accentColor, lineWidth: 2) } }
        .overlay { if let o = outcome { outcomeView(o) } }
        .animation(Motion.snappy(reduceMotion), value: outcome)
        .keyframeAnimator(initialValue: 0.0, trigger: isDenied) { v, x in
            v.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(3, duration: 0.05)
                LinearKeyframe(-3, duration: 0.07)
                LinearKeyframe(3, duration: 0.07)
                LinearKeyframe(-3, duration: 0.07)
                LinearKeyframe(0, duration: 0.05)
            }
        }
        .onAppear { if !reduceMotion { arrived = true } }
    }

    private var isDenied: Bool {
        switch outcome { case .deny, .denyWith: true; default: false }
    }

    private func outcomeView(_ o: ApprovalAnswer) -> some View {
        let (text, symbol, color): (String, String, Color) = switch o {
        case .deny: ("Denied", "xmark.circle.fill", .red)
        case .denyWith: ("Denied, reason sent", "xmark.circle.fill", .red)
        case .answers: ("Answer sent", "checkmark.circle.fill", .green)
        case .allow(let always): (request.kind == .plan ? "Plan approved" : always ? "Always allowed" : "Allowed", "checkmark.circle.fill", .green)
        case .acceptEdits: ("Allowed", "checkmark.circle.fill", .green)
        case .terminal: ("", "", .clear)
        }
        return ZStack {
            RoundedRectangle(cornerRadius: Radius.row).fill(.background.opacity(0.88))
            RoundedRectangle(cornerRadius: Radius.row).fill(color.opacity(0.1))
            OutcomeBadge(text: text, symbol: symbol, color: color)
        }
        .transition(.opacity)
    }

    private func styled(_ detail: String) -> AttributedString {
        if request.kind == .plan { return Self.plan(detail) }
        guard request.kind == .permission, ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(request.toolName) else {
            return AttributedString(detail)
        }
        var out = AttributedString()
        for (i, line) in detail.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var a = AttributedString((i == 0 ? "" : "\n") + line)
            a.foregroundColor = i == 0 ? .secondary : line.hasPrefix("- ") ? .red : line.hasPrefix("+ ") ? .green : .primary
            out += a
        }
        return out
    }

    // Text renders only inline Markdown, so headings and list markers are converted by hand.
    static func plan(_ markdown: String) -> AttributedString {
        var out = AttributedString()
        for (i, raw) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(raw), heading = false
            if let r = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(r)
                heading = true
            } else if let r = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                let indent = String(line[r].prefix { $0 == " " })
                line.replaceSubrange(r, with: indent + "• ")
            }
            var a = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
            if heading { a.font = .callout.weight(.semibold) }
            if i > 0 { out += AttributedString("\n") }
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
        case .permission:
            let what = ApprovalRequest.shellTools.contains(request.toolName) ? "wants to run a command" : "wants to use \(request.toolName)"
            return "\(request.agent == .claude ? "" : "(\(request.agent.label)) ")\(what)"
        case .plan: return "has a plan for you"
        case .question: return request.questions.count == 1 ? "asks" : "asks \(request.questions.count) questions"
        }
    }

    @ViewBuilder private var permissionButtons: some View {
        if denying { denyForm } else { decideButtons }
    }

    private var denyForm: some View {
        HStack(spacing: 8) {
            TextField("Tell Claude why (optional)", text: $reason)
                .textFieldStyle(.roundedBorder)
                .focused($reasonFocused)
                .onSubmit(deny)
                .onAppear { reasonFocused = true }
                .onExitCommand { denying = false }
            Button("Cancel") { denying = false }
            Button("Deny", role: .destructive, action: deny).keyboardShortcut(.defaultAction)
        }
    }

    private func deny() {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        model.answer(request.id, why.isEmpty ? .deny : .denyWith(reason: why))
    }

    @ViewBuilder private var decideButtons: some View {
        if risk != nil { riskyButtons } else { normalButtons }
    }

    private var riskyButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Deny…") { withAnimation(Motion.snappy(reduceMotion)) { denying = true } }
                    .buttonStyle(.borderedProminent).tint(.gray)
                    .help("Deny, and optionally tell Claude why")
                Spacer()
                Button("Allow once") { model.answer(request.id, .allow(always: false)) }
                    .help("Allow this one command. Always allow isn't offered for risky commands.")
            }
            if hotkeyTarget {
                Text("⌃⌥D deny from any app · Allow needs a click").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var normalButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Deny…") { withAnimation(Motion.snappy(reduceMotion)) { denying = true } }
                    .help("Deny, and optionally tell Claude why")
                Spacer()
                if request.alwaysLabel != nil {
                    Button("Always allow") { model.answer(request.id, .allow(always: true)) }
                }
                Button("Allow") { model.answer(request.id, .allow(always: false)) }.buttonStyle(.borderedProminent)
            }
            if let rule = request.alwaysLabel {
                Text("Always allow saves \(rule)").font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(rule)
            }
            if hotkeyTarget {
                Text("⌃⌥A allow · ⌃⌥D deny, from any app").font(.subheadline).foregroundStyle(.secondary)
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
                    Text(q.question).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
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
            HStack(alignment: .top, spacing: 8) {
                if !instant { Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.label).font(.callout.weight(.medium))
                    if !o.description.isEmpty { Text(o.description).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.inner).fill(on ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct OutcomeBadge: View {
    let text: String
    let symbol: String
    let color: Color
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).symbolEffect(.bounce, value: shown)
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(color)
        .onAppear { shown = !reduceMotion }
        .accessibilityElement(children: .combine)
    }
}
