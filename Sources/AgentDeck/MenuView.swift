import AppKit
import AgentDeckCore
import SwiftUI

struct MenuView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirm: Confirm?
    @State private var showingNew = false
    @State private var search = ""
    @State private var searchAsked = false
    @State private var collapsed = Set<String>()
    @State private var only: LiveSession.State?
    @State private var previewing: String?
    @State private var cursor: Item?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var usageHover = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    enum Confirm: Equatable {
        case stop(LiveSession), openWithPhone(LiveSession), delete(HistorySession)
        case renameLive(LiveSession), renameClosed(HistorySession)
        var sessionId: String {
            switch self {
            case .stop(let s), .openWithPhone(let s), .renameLive(let s): return s.sessionId
            case .delete(let h), .renameClosed(let h): return h.sessionId
            }
        }
    }

    enum Item: Hashable { case card(Int), live(String), closed(String) }

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    private var showSearch: Bool { model.live.count > 5 || searchAsked || searching }

    private var cards: [ApprovalRequest] { only == nil || only == .blocked ? model.approvals : [] }
    /// Waiting sessions with no card (Gemini, approvals off, a prompt Agent Deck can't answer).
    private var waitingRows: [LiveSession] {
        guard only == nil || only == .blocked else { return [] }
        let carded = Set(model.approvals.map(\.sessionId))
        return model.live.filter { $0.state == .blocked && !$0.isLeftover && !carded.contains($0.sessionId) && matches(model.displayName($0), $0.cwd, $0.sessionId) }
    }
    private var running: [LiveSession] {
        model.live.filter { s in
            let waiting = s.state == .blocked && !s.isLeftover
            guard !waiting else { return false }
            if let only { return s.state == only && !s.isLeftover }
            return matches(model.displayName(s), s.cwd, s.sessionId)
        }
    }
    private var closed: [HistorySession] {
        guard only == nil else { return [] }
        // Searching looks through all saved sessions; otherwise show the last five.
        return searching ? Array(model.closed.filter { matches($0.name, $0.cwd, $0.sessionId, $0.lastPrompt ?? "") }.prefix(15))
                         : Array(model.closed.prefix(5))
    }
    private var grouped: Bool { running.count > 5 && !searching && only == nil }

    /// Everything ↑/↓ can reach, top to bottom, as it's drawn.
    private var items: [Item] {
        let live: [LiveSession] = grouped
            ? ProjectGroups.group(running).filter { !collapsed.contains($0.name) }.flatMap(\.sessions)
            : running
        return cards.filter { model.outcomes[$0.id] == nil }.map { .card($0.id) }
            + waitingRows.map { .live($0.sessionId) }
            + live.map { .live($0.sessionId) }
            + closed.map { .closed($0.sessionId) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                healthBanner
                if !model.live.isEmpty { statusStrip }
                usage
                Divider().padding(.vertical, 6)
                ZStack(alignment: .top) {
                    if showingNew {
                        NewSessionPanel(model: model, isShown: $showingNew).transition(slide(from: .trailing))
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            if !cards.isEmpty || !waitingRows.isEmpty { needsYou.transition(.opacity.combined(with: .move(edge: .top))) }
                            sessions
                        }
                        .transition(slide(from: .leading))
                    }
                }
                .clipped()
                BannerView(model: model).padding(.top, 6).animation(Motion.spring(reduced: reduceMotion), value: model.banner?.id)
                Divider().padding(.vertical, 6)
                footer
            }
            .animation(Motion.spring(reduced: reduceMotion), value: model.approvals.isEmpty)
            .animation(Motion.spring(reduced: reduceMotion), value: showingNew)
            .animation(Motion.spring(reduced: reduceMotion), value: only)
            .padding(8)
            .frame(width: 370)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in move(press.key == .downArrow ? 1 : -1, proxy); return .handled }
            .onKeyPress(.return, phases: .down) { press in activate(command: press.modifiers.contains(.command)) }
            .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in answerOption(press.characters) }
            .onKeyPress(.escape) {
                if previewing != nil { withAnimation(Motion.snappy(reduceMotion)) { previewing = nil }; return .handled }
                if only != nil { only = nil; return .handled }
                if cursor != nil { cursor = nil; return .handled }
                return .ignored
            }
            .scaleEffect(appeared || reduceMotion ? 1 : 0.98, anchor: .top)
            .offset(y: appeared || reduceMotion ? 0 : -4)
            .opacity(appeared ? 1 : 0)
            .background {
                // ⌘F: jump to search.
                Button("") { showingNew = false; searchAsked = true; searchFocused = true }
                    .keyboardShortcut("f").opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            .onAppear {
                model.menuOpen = true
                listFocused = true
                withAnimation(Motion.spring(reduced: reduceMotion)) { appeared = true }
            }
            .onDisappear {
                model.menuOpen = false; search = ""; searchAsked = false; appeared = false
                only = nil; previewing = nil; cursor = nil
            }
        }
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) {
        let list = items
        guard !list.isEmpty else { return }
        let at = cursor.flatMap(list.firstIndex(of:)).map { $0 + step } ?? (step > 0 ? 0 : list.count - 1)
        let next = list[min(max(at, 0), list.count - 1)]
        cursor = next
        listFocused = true
        withAnimation(Motion.fast(reduceMotion)) { proxy.scrollTo(next) }
    }

    private func activate(command: Bool) -> KeyPress.Result {
        guard let cursor else { return .ignored }
        switch cursor {
        case .card(let id):
            guard let r = model.approvals.first(where: { $0.id == id }) else { return .ignored }
            if !command { model.openSession(id: r.sessionId) }
            else if r.kind == .permission { model.answer(id, .allow(always: false)) }
            else if r.kind == .plan { model.approvePlan(r, acceptEdits: false) }
            else { return .ignored }
        case .live(let sid):
            guard let s = model.live.first(where: { $0.sessionId == sid }) else { return .ignored }
            model.open(s)
        case .closed(let sid):
            guard let h = model.closed.first(where: { $0.sessionId == sid }) else { return .ignored }
            model.resumeInTerminal(h)
        }
        return .handled
    }

    /// 1–4 picks an option of the picked card's question (one single-choice question only).
    private func answerOption(_ key: String) -> KeyPress.Result {
        guard case .card(let id) = cursor, let r = model.approvals.first(where: { $0.id == id }),
              r.kind == .question, r.questions.count == 1, let q = r.questions.first, !q.multiSelect,
              let n = Int(key), n <= q.options.count else { return .ignored }
        model.answer(id, .answers([q.question: q.options[n - 1].label]))
        return .handled
    }

    private func slide(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .push(from: .top),
                                               removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    @ViewBuilder private var healthBanner: some View {
        let missing = model.missingHooks
        if !missing.isEmpty {
            let text = !missing.isDisjoint(with: ["claude", "codex"]) ? "Approvals off: a hook is missing"
                : missing.contains("statusLine") ? "Usage off: the status line isn't set up"
                : "Gemini CLI sessions won't show: a hook is missing"
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Repair") { Task { await model.repairHooks() } }.controlSize(.small).buttonStyle(.borderedProminent)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.5)))
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            chip(.blocked, "waiting", .orange)
            chip(.busy, "working", .green)
            chip(.idle, "idle", .secondary)
            Spacer()
        }
        .padding(.horizontal, 4).padding(.bottom, 8)
    }

    private func chip(_ state: LiveSession.State, _ word: String, _ color: Color) -> some View {
        let n = model.count(state), on = only == state
        return Button {
            withAnimation(Motion.snappy(reduceMotion)) { only = on ? nil : state; cursor = nil }
        } label: {
            Text("\(n) \(word)")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .contentTransition(.numericText(value: Double(n)))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(on ? 0.3 : color == .secondary ? 0 : 0.14)))
                .overlay(Capsule().strokeBorder(color.opacity(on ? 1 : 0.6), lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(PressableStyle())
        .disabled(n == 0 && !on)
        .opacity(n == 0 && !on ? 0.45 : 1)
        .help(on ? "Show all sessions" : "Show only sessions that are \(word == "waiting" ? "waiting for you" : word)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var needsYou: some View {
        let hotkeyTarget = model.pendingApprovals.first { $0.kind == .permission }?.id
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "NEEDS YOU · \(cards.count + waitingRows.count)", trailing: "or answer in the terminal")
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(cards) {
                        ApprovalCard(model: model, request: $0, hotkeyTarget: $0.id == hotkeyTarget, selected: cursor == .card($0.id))
                            .id(Item.card($0.id))
                            .transition(cardTransition)
                    }
                    ForEach(waitingRows) { s in liveRow(s) }
                }
                .animation(Motion.spring(reduced: reduceMotion), value: model.approvals.map(\.id))
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private var usage: some View {
        if let u = model.usage {
            let stale = Date().timeIntervalSince(u.updatedAt) > 600
            Button { showDetails(tab: .usage) } label: {
                HStack(spacing: 12) {
                    if let w = u.fiveHour { UsageTile(window: w, forecast: model.forecast(w)).frame(maxWidth: .infinity, alignment: .leading) }
                    if let w = u.weekly { UsageTile(window: w, forecast: model.forecast(w), delay: 0.08).frame(maxWidth: .infinity, alignment: .leading) }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(usageHover ? .secondary : .tertiary)
                }
                .opacity(stale ? 0.6 : 1)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(usageHover ? Color.primary.opacity(0.05) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .onHover { usageHover = $0 }
            .animation(Motion.fast(reduceMotion), value: usageHover)
            .help(stale ? "These numbers are over 10 minutes old. They update with your next Claude Code message." : "Open usage details")
            HStack {
                Text(u.model ?? "")
                Spacer()
                Text("updated \(Fmt.ago(u.updatedAt))")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage limits").font(.system(size: 13, weight: .semibold))
                Text("They appear after your next Claude Code message. Claude Code sends them to the status line, and Agent Deck reads them from there.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(8)
        }
        if !model.codexUsage.isEmpty {
            HStack(spacing: 10) {
                Text("Codex").fontWeight(.semibold)
                ForEach(model.codexUsage) { l in
                    Text("\(l.label) \(Int(l.percent.rounded()))%").monospacedDigit()
                        .foregroundStyle(l.percent >= 75 ? Level.color(l.percent) : .secondary)
                        .contentTransition(.numericText(value: l.percent))
                        .animation(Motion.spring(reduced: reduceMotion), value: l.percent)
                        .help(Fmt.resets(l.resetsAt).capitalized)
                }
                Spacer()
            }
            .font(.system(size: 11)).padding(.horizontal, 8).padding(.top, 4)
        }
    }

    private func matches(_ text: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || text.contains { $0.lowercased().contains(q) }
    }

    private var sessions: some View {
        let running = self.running, closed = self.closed
        return VStack(alignment: .leading, spacing: 4) {
            if showSearch {
                TextField("Search name, folder or session ID", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .controlSize(.regular)
                    .padding(.horizontal, 6)
                    .onKeyPress(.downArrow) { cursor = nil; listFocused = true; return .ignored }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(title: "\(only.map(stateTitle) ?? "RUNNING") · \(running.count)", trailing: only == nil ? "newest first" : "esc shows all")
                    if running.isEmpty {
                        HStack {
                            Text(searching ? "No running session matches." : only != nil ? "None right now." : "No Claude Code sessions running.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            if !searching && only == nil && model.live.isEmpty { Button("New session…") { showingNew = true }.controlSize(.small) }
                        }
                        .padding(8)
                    }
                    if grouped {
                        ForEach(ProjectGroups.group(running), id: \.name) { g in groupView(g) }
                    } else {
                        ForEach(running) { s in liveRow(s).transition(.opacity.combined(with: .move(edge: .top))) }
                    }

                    if !closed.isEmpty {
                        SectionHeader(title: searching ? "CLOSED · MATCHES" : "RECENT · CLOSED").padding(.top, 6)
                        ForEach(closed) { h in closedRowWithConfirm(h).transition(.opacity) }
                    } else if searching {
                        Text("No closed session matches.").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                    }
                }
                .animation(Motion.spring(reduced: reduceMotion), value: running.map(\.id))
                .animation(Motion.spring(reduced: reduceMotion), value: closed.map(\.id))
                .animation(Motion.spring(reduced: reduceMotion), value: confirm)
                .animation(Motion.spring(reduced: reduceMotion), value: previewing)
            }
            .frame(maxHeight: model.approvals.isEmpty ? 380 : 240)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(Motion.spring(reduced: reduceMotion), value: showSearch)
    }

    private func stateTitle(_ s: LiveSession.State) -> String {
        switch s { case .blocked: "WAITING"; case .busy: "WORKING"; case .idle: "IDLE" }
    }

    @ViewBuilder private func groupView(_ g: ProjectGroups.Group) -> some View {
        let open = !collapsed.contains(g.name)
        Button {
            withAnimation(Motion.snappy(reduceMotion)) {
                if open { collapsed.insert(g.name) } else { collapsed.remove(g.name) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(g.name).font(.system(size: 12, weight: .semibold))
                if g.sessions.contains(where: { $0.state == .blocked }) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                        .help("A session here is waiting for you")
                }
                Spacer()
                Text("\(g.sessions.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open {
            ForEach(Array(g.sessions.enumerated()), id: \.element.id) { i, s in
                liveRow(s).padding(.leading, 12).transition(stagger(i))
            }
        }
    }

    private func stagger(_ i: Int) -> AnyTransition {
        reduceMotion ? .opacity
            : AnyTransition.opacity.combined(with: .move(edge: .top)).animation(Motion.spring(reduced: false).delay(Double(min(i, 5)) * 0.02))
    }

    @ViewBuilder private func liveRow(_ s: LiveSession) -> some View {
        let busy = model.working.contains(s.sessionId)
        let waiting = s.state == .blocked && !s.isLeftover
        VStack(spacing: 4) {
            HoverRow(selected: cursor == .live(s.sessionId)) {
                Capsule().fill(waiting ? Color.orange : SessionColor.of(s.sessionId)).frame(width: waiting ? 4 : 3, height: 22)
                StateDot(state: s.isLeftover ? nil : s.state, animated: model.menuOpen)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(highlighted(model.displayName(s), search)).font(.system(size: 13, weight: waiting ? .semibold : .medium)).lineLimit(1)
                        if s.kind == .background { Pill(text: "BG") }
                        if s.agent != .claude { Pill(text: s.agent.label.uppercased(), color: s.agent == .codex ? .teal : .blue) }
                    }
                    Text(highlighted([Fmt.shortPath(s.cwd), model.branches[s.cwd].map { "⎇ \($0)" }].compactMap { $0 }.joined(separator: " "), search))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    activityLine(s)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                if s.agent == .claude {
                    HStack(spacing: 8) { rowButtons(s) }
                        .opacity(busy ? 0.3 : 1)
                        .disabled(busy)
                        .overlay { if busy { ProgressView().controlSize(.small).transition(.opacity) } }
                        .animation(Motion.fast(reduceMotion), value: busy)
                } else if busy {
                    ProgressView().controlSize(.small)
                }
            } action: { model.open(s) }
            .background { if waiting { RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.08)) } }
            .animation(Motion.snappy(reduceMotion), value: s.state)
            .contextMenu {
                Button("Rename…") { confirm = .renameLive(s) }
                    .disabled(s.agent != .claude || s.kind == .background || model.typingBlockers[s.sessionId] != nil)
                Button(s.kind == .interactive ? "Show its window" : "Open in iTerm") { model.open(s) }
                if let url = s.phoneURL { Button("Copy phone link") { copy(url.absoluteString) } }
                Button("Copy session ID") { copy(s.sessionId) }
            }

            if let c = confirm, c.sessionId == s.sessionId { confirmBar(c).transition(slide(from: .top)) }
        }
        .id(Item.live(s.sessionId))
    }

    @ViewBuilder private func rowButtons(_ s: LiveSession) -> some View {
        IconButton(symbol: "iphone", on: s.isOnPhone, help: model.typingBlockers[s.sessionId] ?? phoneHelp(s),
                   dimmed: model.typingBlockers[s.sessionId] != nil) {
            switch (s.isOnPhone, s.kind) {
            case (false, .interactive): model.phoneOn(s)    // keeps running here too
            case (true, .interactive): model.phoneOff(s)    // keeps running here
            case (false, .background): confirm = .openWithPhone(s)
            case (true, .background): confirm = .stop(s)    // phone is its only window
            }
        }
        IconButton(symbol: s.isLeftover ? "xmark" : "stop.fill",
                   help: s.isLeftover ? "Clear this leftover entry (history is kept)" : "Stop session") {
            if s.state == .idle && !s.isLeftover { model.stop(s) } else { confirm = .stop(s) }
        }
    }

    private func closedRow(_ h: HistorySession) -> some View {
        let open = previewing == h.sessionId
        return HoverRow(selected: cursor == .closed(h.sessionId), open: { model.resumeInTerminal(h) }) {
            Color.clear.frame(width: 3, height: 22)
            StateDot(state: nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(h.name, search)).font(.system(size: 13, weight: open ? .semibold : .medium)).lineLimit(1)
                if !open {
                    Text(model.duplicateNames.contains(h.name) && h.lastPrompt?.isEmpty == false
                         ? "“\(h.lastPrompt ?? "")” · \(Fmt.folderName(h.cwd))" : Fmt.shortPath(h.cwd))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(Fmt.ago(h.lastActive)).font(.system(size: 11)).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
        } action: {
            withAnimation(Motion.snappy(reduceMotion)) { previewing = open ? nil : h.sessionId }
            cursor = .closed(h.sessionId)
        }
        .contextMenu {
            Button("Rename…") { confirm = .renameClosed(h) }
            Button("Resume in iTerm") { model.resumeInTerminal(h) }
            Button("Copy session ID") { copy(h.sessionId) }
        }
    }

    @ViewBuilder private func closedRowWithConfirm(_ h: HistorySession) -> some View {
        let open = previewing == h.sessionId
        VStack(alignment: .leading, spacing: 4) {
            closedRow(h)
            if open {
                ClosedPreview(model: model, session: h,
                              rename: { confirm = .renameClosed(h) },
                              delete: { confirm = .delete(h) })
                    .padding(.horizontal, 8).padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let c = confirm, c.sessionId == h.sessionId { confirmBar(c).transition(slide(from: .top)) }
        }
        .background { if open { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)) } }
        .overlay { if open { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.25) } }
        .id(Item.closed(h.sessionId))
    }

    private func phoneHelp(_ s: LiveSession) -> String {
        switch (s.isOnPhone, s.kind) {
        case (false, .interactive): return "Also open on your phone (keeps running here)"
        case (true, .interactive): return "On your phone. Click to disconnect the phone; it keeps running here."
        case (false, .background): return s.isLeftover ? "Reopen it in iTerm and on your phone"
                                                       : "Open in iTerm and on your phone"
        case (true, .background): return "On your phone only. Click to stop it."
        }
    }

    private func confirmBar(_ c: Confirm) -> some View {
        HStack(spacing: 8) {
            switch c {
            case .stop(let s):
                Text(s.isLeftover ? "It isn't running, it's a leftover entry. Clear it? Its history stays."
                     : s.state == .blocked ? "It's waiting for an answer. Stop it?"
                     : s.kind == .background && s.isOnPhone ? "It runs only on your phone. Stop it?"
                     : s.isOnPhone ? "Stop it? It also leaves your phone." : "Stop this session?")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { confirm = nil }
                Button(s.isLeftover ? "Clear" : "Stop") { confirm = nil; model.stop(s) }.keyboardShortcut(.defaultAction)
            case .openWithPhone(let s):
                Text("It has no window. Open it in iTerm with phone access on?").fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { confirm = nil }
                Button("Open") { confirm = nil; model.phoneOn(s) }.keyboardShortcut(.defaultAction)
            case .renameLive(let s):
                RenameField(initial: model.displayName(s)) { name in confirm = nil; if let name { model.rename(s, to: name) } }
            case .renameClosed(let h):
                RenameField(initial: h.name) { name in confirm = nil; if let name { model.rename(h, to: name) } }
            case .delete(let h):
                DeleteConfirm(model: model, sessions: [h], compact: true) { confirm = nil }
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.1)))
    }

    @ViewBuilder private func activityLine(_ s: LiveSession) -> some View {
        let a = model.activity[s.sessionId]
        let agents = a.map(\.subagents.count).flatMap { $0 > 0 ? "\($0) agent\($0 == 1 ? "" : "s")" : nil }
        let doing = s.state == .busy ? a?.tool.map { t in a?.detail.map { "\(t): \($0)" } ?? t } : nil
        let text = [doing ?? stateText(s), agents].compactMap { $0 }.joined(separator: " · ")
        Group {
            if let since = model.busySince[s.sessionId], s.state == .busy {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let t = max(0, Int(ctx.date.timeIntervalSince(since)))
                    Text("\(text) · \(t / 60):\(String(format: "%02d", t % 60))")
                        .contentTransition(.numericText(countsDown: false))
                        .animation(Motion.fast(reduceMotion), value: t)
                }
            } else {
                Text(text)
            }
        }
        .font(.system(size: 11)).foregroundStyle(s.state == .blocked ? Color.orange : .secondary).lineLimit(1).truncationMode(.tail)
    }

    private func stateText(_ s: LiveSession) -> String {
        if s.isLeftover { return "not running · leftover" }
        switch s.state {
        case .busy: return "working"
        case .idle: return "idle"
        case .blocked: return "waiting for you"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("↑↓ move · ⏎ open · ⌘⏎ approve · 1–4 answer")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .accessibilityLabel("Keyboard: arrows move, Return opens, Command Return approves, 1 to 4 answers")
            HStack {
                Button { showingNew.toggle() } label: { Label(showingNew ? "Back" : "New session…", systemImage: showingNew ? "chevron.left" : "plus") }
                    .keyboardShortcut("n")
                Spacer()
                Button("View details…") { showDetails(tab: .sessions) }
                IconButton(symbol: "arrow.clockwise", help: "Refresh now", dimmed: model.refreshing) { Task { await model.refreshNow() } }
                IconButton(symbol: "power", help: "Quit Agent Deck") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
        }
    }

    private func showDetails(tab: DetailsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: "detailsTab")
        openWindow(id: "details")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ClosedPreview: View {
    let model: AppModel
    let session: HistorySession
    let rename: () -> Void
    let delete: () -> Void
    @State private var detail: SessionDetail?

    private var stats: String {
        guard let d = detail else { return "Reading…" }
        return [d.duration.map(Fmt.duration), d.tokens > 0 ? "\(Fmt.tokens(d.tokens)) tokens" : nil,
                d.prompts > 0 ? "\(d.prompts) prompt\(d.prompts == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = session.lastPrompt, !p.isEmpty { line("Last prompt", p) }
            if let r = detail?.lastReply { line("Last reply", r) }
            Text(stats).foregroundStyle(.secondary)
            Text(Fmt.shortPath(session.cwd)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Button { model.resumeInTerminal(session) } label: { Label("Resume in iTerm", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent)
                Button("Rename…", action: rename)
                Button("Delete…", role: .destructive, action: delete)
                Spacer()
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .font(.system(size: 11))
        .padding(.leading, 23)
        .task(id: session.sessionId) {
            let url = session.fileURL
            detail = await Task.detached { SessionDetail.load(url) }.value
        }
    }

    private func line(_ label: String, _ text: String) -> some View {
        (Text("\(label): ").foregroundStyle(.secondary) + Text(text))
            .lineLimit(2).textSelection(.enabled)
    }
}

struct NewSessionPanel: View {
    let model: AppModel
    @Binding var isShown: Bool
    @State private var folder: String?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New session").font(.system(size: 13, weight: .semibold))
            Text("FOLDER").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            FlowChips(items: model.recentFolders, selected: $folder)
            Button("Browse…") { browse() }.controlSize(.small)
            if let folder { Text(Fmt.shortPath(folder)).font(.system(size: 11)).foregroundStyle(.secondary) }
            Text("NAME (optional)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            TextField("e.g. fix-login", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button { start(phone: false) } label: { Label("Open in iTerm", systemImage: "terminal") }
                Button { start(phone: true) } label: { Label("Start for phone", systemImage: "iphone") }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(folder == nil || model.working.contains("new"))
            Text("Start for phone opens no window. The session shows up in the Claude app within a few seconds.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .onAppear { folder = folder ?? model.recentFolders.first }
    }

    private func start(phone: Bool) {
        guard let folder else { return }
        if phone { model.newOnPhone(folder: folder, name: name) } else { model.newInTerminal(folder: folder, name: name) }
        isShown = false
        name = ""
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

struct FlowChips: View {
    let items: [String]
    @Binding var selected: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { f in
                Button { selected = f } label: {
                    Text(Fmt.folderName(f)).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Capsule().fill(selected == f ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1)))
                        .overlay(Capsule().stroke(selected == f ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain)
                .help(f)
            }
        }
    }
}

struct BannerView: View {
    let model: AppModel

    var body: some View {
        if let b = model.banner {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: b.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(b.isError ? .orange : .green)
                Text(b.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let title = b.actionTitle, let action = b.action {
                    Button(title) { model.banner = nil; action() }.controlSize(.small)
                }
                Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill((b.isError ? Color.orange : Color.green).opacity(0.12)))
            .overlay(alignment: .bottom) {
                if !b.isError {
                    ProgressView(timerInterval: b.shownAt...b.shownAt.addingTimeInterval(b.lifetime), countsDown: true) {
                        EmptyView()
                    } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .scaleEffect(x: 1, y: 0.5, anchor: .bottom)
                    .padding(.horizontal, 8)
                    .accessibilityHidden(true)
                }
            }
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: b.id) {
                guard !b.isError else { return }
                try? await Task.sleep(nanoseconds: UInt64(b.lifetime * 1e9))
                if model.banner?.id == b.id { model.banner = nil }
            }
        }
    }
}

struct DeleteConfirm: View {
    let model: AppModel
    let sessions: [HistorySession]
    var compact = false
    let onDone: () -> Void
    @State private var bytes: Int64?
    @State private var files: [CreatedFile] = []
    @State private var picked = Set<URL>()
    @State private var showFiles = false

    private var title: String {
        let what = sessions.count == 1 ? "this session" : "\(sessions.count) sessions"
        return "Move \(what) and Claude's data for \(sessions.count == 1 ? "it" : "them") (\(bytes.map(Fmt.bytes) ?? "counting…")) to the Trash?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                    .help("Conversation, scratchpad, undo backups and other files Claude Code keeps for this session")
                Spacer()
                Button("Cancel", action: onDone)
                Button(picked.isEmpty ? "Delete" : "Delete + \(picked.count) file\(picked.count == 1 ? "" : "s")", role: .destructive) {
                    model.delete(sessions, files: Array(picked))
                    onDone()
                }.keyboardShortcut(.defaultAction)
            }
            if !files.isEmpty {
                DisclosureGroup(isExpanded: $showFiles) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(files) { fileRow($0) }
                        Text("Only files Claude made with its Write tool are listed. Nothing here is deleted unless you tick it.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                } label: {
                    Text("Files this session created in \(Fmt.folderName(sessions[0].cwd)) (\(files.count))")
                }
            }
        }
        .task(id: sessions.map(\.sessionId)) {
            let r = await model.deletePreview(sessions)
            (bytes, files, picked) = (r.bytes, r.files, [])
        }
    }

    private func fileRow(_ f: CreatedFile) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { picked.contains(f.url) },
                                     set: { if $0 { picked.insert(f.url) } else { picked.remove(f.url) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!f.canDelete)
            Text(relative(f.url)).lineLimit(1).truncationMode(.middle).help(f.url.path)
            Spacer(minLength: 4)
            switch f.state {
            case .inGit: Label("in git, kept", systemImage: "lock.fill").foregroundStyle(.secondary)
            case .changedSince: Label("changed since", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .untracked: Text("untracked").foregroundStyle(.secondary)
            }
            if !compact { Text(Fmt.bytes(f.bytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing) }
        }
        .font(.system(size: 11))
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } }
    }

    private func relative(_ url: URL) -> String {
        let root = sessions[0].cwd + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : Fmt.shortPath(url.path)
    }
}
