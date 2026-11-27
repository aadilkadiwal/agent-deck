import AgentDeckCore
import SwiftUI

struct ApprovalCard: View {
    let model: AppModel
    let request: ApprovalRequest
    var roomy = false
    var selected = false
    @State private var expanded = false
    @State private var denying = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let previewLines = 8

    private var outcome: ApprovalAnswer? { model.outcomes[request.id] }
    private var risk: String? { request.risk }
    private var tint: Color {
        switch outcome {
        case .deny, .denyWith: .red
        case .allow, .acceptEdits, .answers: .green
        case .terminal: .secondary
        case nil: risk == nil ? .orange : .red
        }
    }

    private var word: String {
        if let risk { return "Risky · \(risk)" }
        switch request.kind {
        case .permission: return "Waiting on you"
        case .plan: return "Plan to review"
        case .question: return request.questions.count == 1 ? "Question" : "\(request.questions.count) questions"
        }
    }

    private var name: String { model.sessionName(request.sessionId, cwd: request.cwd) }

    private var sentence: String {
        switch request.kind {
        case .permission: return "\(name) wants to \(request.toolName == "Bash" ? "run" : "use") \(request.toolName)"
        case .plan: return "\(name) has a plan for you"
        case .question: return "\(name) asks"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(word.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(tint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = max(0, Int(ctx.date.timeIntervalSince(request.receivedAt)))
                    Text(String(format: "%d:%02d", s / 60, s % 60)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
                .frame(minWidth: 34, alignment: .trailing)
                IconButton(symbol: "terminal", help: "Answer in the terminal") { model.openSession(id: request.sessionId) }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(sentence).font(.body.weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let place = Fmt.place(request.cwd, branch: model.branches[request.cwd], name: name) {
                    Text(place).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            .help(risk.map { "This one \($0), so shortcuts won't allow it. Click Allow once if you're sure." } ?? request.cwd)
            if let did = model.away[request.sessionId]?.line {
                Text(did).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let d = request.description, request.kind == .permission {
                Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                .overlay { if risk != nil { RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Color.red.opacity(0.6)) } }
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
        .padding(10)
        .padding(.leading, 3)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color.primary.opacity(0.05)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Radius.row, bottomLeadingRadius: Radius.row).fill(tint).frame(width: 3)
        }
        .overlay { if selected { RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Color.accentColor, lineWidth: 2) } }
        .overlay { if let o = outcome { outcomeView(o) } }
        .animation(Motion.snappy(reduceMotion), value: outcome)
    }

    static func transition(_ outcome: ApprovalAnswer?, reduced: Bool) -> AnyTransition {
        if reduced { return .opacity }
        let denied: Bool = switch outcome { case .deny, .denyWith: true; default: false }
        return .asymmetric(insertion: .push(from: .top),
                           removal: denied ? .move(edge: .leading).combined(with: .opacity)
                                           : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    private func outcomeView(_ o: ApprovalAnswer) -> some View {
        let (text, symbol, color): (String, String, Color) = switch o {
        case .deny: ("Denied", "xmark.circle.fill", .red)
        case .denyWith: ("Denied, with your reason", "xmark.circle.fill", .red)
        case .answers: ("Answer sent", "checkmark.circle.fill", .green)
        case .allow(let always, let scope):
            (request.kind == .plan ? "Plan approved" : !always ? "Allowed"
             : scope == .session ? "Allowed for this session" : scope == .project ? "Always allowed here" : "Always allowed everywhere",
             "checkmark.circle.fill", .green)
        case .acceptEdits: ("Allowed", "checkmark.circle.fill", .green)
        case .terminal: ("Answered in the terminal", "terminal.fill", .secondary)
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

    @ViewBuilder private var permissionButtons: some View {
        if denying { denyForm } else { decideButtons }
    }

    private var denyForm: some View {
        HStack(spacing: 8) {
            TextField("Tell Claude why (optional)", text: $reason)
                .textFieldStyle(.roundedBorder)
                .focused($reasonFocused)
                .onSubmit(deny)
                // A pass later: set while the field is still being inserted, the focus doesn't take.
                .task { reasonFocused = true }
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

    // Risky: Deny is the primary button and sits where Allow usually is, so a habit click is the safe one.
    private var riskyButtons: some View {
        HStack {
            Button("Allow once") { model.answer(request.id, .allow(always: false)) }
                .help("Allows just this run. Risky commands can't be always allowed.")
            Spacer()
            Button("Deny…") { withAnimation(Motion.snappy(reduceMotion)) { denying = true } }
                .buttonStyle(.borderedProminent).tint(.red)
                .help("Deny it, and tell Claude why if you like")
        }
    }

    private var normalButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Deny…") { withAnimation(Motion.snappy(reduceMotion)) { denying = true } }
                    .help("Deny it, and tell Claude why if you like")
                Spacer()
                if let rule = request.alwaysLabel {
                    Menu("Always allow") {
                        ForEach(RuleScope.allCases, id: \.self) { scope in
                            Button(Self.scopeTitle(scope, cwd: request.cwd)) { model.answer(request.id, .allow(always: true, scope: scope)) }
                        }
                    } primaryAction: { model.answer(request.id, .allow(always: true, scope: .session)) }
                    .menuStyle(.borderedButton).fixedSize()
                    .help("Click: allow \(rule) until this session ends. Arrow: keep it for this project or everywhere.")
                }
                Button("Allow") { model.answer(request.id, .allow(always: false)) }.buttonStyle(.borderedProminent)
            }
            if let rule = request.alwaysLabel {
                Text("Always allow covers \(rule) for this session. The arrow keeps it longer.").font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true).help(rule)
            }
        }
    }

    private var planButtons: some View {
        HStack {
            Spacer()
            Button("Approve, auto-accept edits") { model.approvePlan(request, acceptEdits: true) }
                .help("Approves the plan and lets Claude edit files in this session without asking")
            Button("Approve plan") { model.approvePlan(request, acceptEdits: false) }.buttonStyle(.borderedProminent)
        }
    }
}

struct HotkeyHint: View {
    let model: AppModel

    var body: some View {
        Group {
            if let r = model.pendingApprovals.first(where: { $0.kind == .permission }) {
                Text(r.risk == nil ? "From any app, ⌃⌥A allows the oldest prompt, ⌃⌥D denies it and ⌃⌥J shows it in its terminal"
                                   : "From any app, ⌃⌥D denies the oldest prompt and ⌃⌥J shows it in its terminal. It's risky, so allowing it takes a click.")
            } else if !model.pendingApprovals.isEmpty || model.needsYou {
                Text("From any app, ⌃⌥J shows the oldest waiting session in its terminal")
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension ApprovalCard {
    static func scopeTitle(_ scope: RuleScope, cwd: String) -> String {
        switch scope {
        case .session: "For this session"
        case .project: "Always in \(Fmt.folderTitle(cwd))"
        case .everywhere: "Always, in every project"
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
            // Indexed: two questions (or options) can share the same text.
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(q.question).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(q.options.enumerated()), id: \.offset) { _, o in option(q, o) }
                    TextField("Other…", text: Binding(get: { other[q.question] ?? "" }, set: { other[q.question] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if instant, !answer(q).isEmpty { send([q.question: answer(q)]) } }
                }
            }
            if !instant {
                HStack {
                    Spacer()
                    Button("Send") { send(Dictionary(questions.map { ($0.question, answer($0)) }, uniquingKeysWith: { a, _ in a })) }
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
