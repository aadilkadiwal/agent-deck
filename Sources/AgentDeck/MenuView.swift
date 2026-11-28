import AppKit
import AgentDeckCore
import SwiftUI

struct MenuView: View {
    let model: AppModel
    @State private var confirm: Confirm?
    @State private var showingNew = false
    @State private var tab = ListTab.running
    @State private var tabMinHeight: CGFloat = 0
    @State private var search = ""
    @State private var searchAsked = false
    @State private var collapsed = Set<String>()
    @State private var only: LiveSession.State?
    @State private var previewing: String?
    @State private var cursor: Item?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var usageHover = false
    @State private var hoveredRow: String?
    @State private var actionsOpen = false
    @State private var allClear = false
    @State private var totalHeight: CGFloat = 0
    @State private var needsYouHeight: CGFloat = 0
    @State private var sessionsHeight: CGFloat = 0
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage(Notifier.snoozeKey) private var snoozeTime = 0.0
    @State private var hoveredCount: LiveSession.State?
    @State private var replyContext: String?
    @AppStorage(Notifier.Key.limits) private var notifyLimits = true
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.openSettings) private var openSettings

    enum Confirm: Equatable {
        case stop(LiveSession), openWithPhone(LiveSession), clearContext(LiveSession), compact(LiveSession), delete(HistorySession)
        case renameLive(LiveSession), renameClosed(HistorySession), stopIdle, reply(LiveSession)
        var sessionId: String {
            switch self {
            case .stopIdle: return "idle-sessions"
            case .stop(let s), .openWithPhone(let s), .clearContext(let s), .compact(let s), .renameLive(let s), .reply(let s): return s.sessionId
            case .delete(let h), .renameClosed(let h): return h.sessionId
            }
        }
    }

    enum Item: Hashable { case card(Int), live(String), closed(String) }
    enum ListTab: Hashable { case running, recent }

    // Searching and filtering look across both lists, so the switch only shows when neither is on.
    private var tabsShown: Bool { !searching && only == nil }
    private var showsRunning: Bool { !tabsShown || tab == .running }
    private var showsRecent: Bool { searching || (tabsShown && tab == .recent) }

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    private var showSearch: Bool { model.live.count > 5 || searchAsked || searching }

    private var cards: [ApprovalRequest] { only == nil || only == .blocked ? model.approvals : [] }
    /// Waiting sessions with no card (approvals off, or a prompt Agent Deck can't answer).
    private var waitingRows: [LiveSession] {
        guard only == nil || only == .blocked else { return [] }
        let carded = Set(model.approvals.map(\.sessionId))
        return model.live.filter { $0.state == .blocked && !$0.isLeftover && !carded.contains($0.sessionId) && matches($0) }
    }
    private var running: [LiveSession] {
        model.live.filter { s in
            let waiting = s.state == .blocked && !s.isLeftover
            guard !waiting else { return false }
            if let only { return s.state == only && !s.isLeftover }
            return matches(s)
        }
    }
    private var closed: [HistorySession] {
        guard showsRecent else { return [] }
        return searching ? Array(model.closed.filter { matches($0.name, $0.cwd, $0.sessionId, $0.lastPrompt ?? "") }.prefix(15))
                         : Array(model.closed.prefix(15))
    }
    private func grouped(_ running: [LiveSession]) -> Bool { running.count > 5 && !searching && only == nil }
    // Not narrowed by search, so typing never makes waiting sessions look answered.
    private var urgent: Bool {
        guard only == nil || only == .blocked else { return false }
        return !model.approvals.isEmpty || model.live.contains { $0.state == .blocked && !$0.isLeftover }
    }
    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    // The two lists scroll; everything else (header, usage, banners, footer) doesn't. Its height is
    // measured, so the lists share what's left below the menu bar and the footer stays on screen.
    private var heights: (needsYou: CGFloat, sessions: CGFloat) {
        let fixed = totalHeight > 0 ? totalHeight - needsYouHeight - sessionsHeight : 340
        let budget = max(240, StatusMenu.available - fixed)
        guard urgent else { return (0, min(380, budget)) }
        let needsYou = min(420, budget * 0.6)
        return (needsYou, max(120, min(240, budget - needsYou)))
    }

    /// Everything ↑/↓ can reach, top to bottom, as it's drawn.
    private var items: [Item] {
        let running = self.running
        let live: [LiveSession] = grouped(running)
            ? ProjectGroups.group(running).filter { !collapsed.contains($0.name) }.flatMap(\.sessions)
            : running
        return cards.filter { model.outcomes[$0.id] == nil }.map { .card($0.id) }
            + waitingRows.map { .live($0.sessionId) }
            + (showsRunning ? live.map { .live($0.sessionId) } : [])
            + closed.map { .closed($0.sessionId) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                header
                healthBanner
                if let st = model.serviceStatus { statusBanner(st).padding(.bottom, 8).transition(slide(from: .top)) }
                if confirm == .stopIdle { confirmBar(.stopIdle).padding(.bottom, 8).transition(slide(from: .top)) }
                if urgent && !showingNew {
                    needsYou.transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    if !onboarded {
                        WelcomeCard(model: model) { withAnimation(Motion.spring(reduced: reduceMotion)) { onboarded = true } }.padding(.bottom, 8)
                    }
                    usage
                }
                Divider().padding(.vertical, 8)
                ZStack(alignment: .top) {
                    if showingNew {
                        NewSessionPanel(model: model, isShown: $showingNew).transition(slide(from: .trailing))
                    } else {
                        sessions.transition(slide(from: .leading))
                    }
                }
                .clipped()
                BannerView(model: model).padding(.top, 8).animation(Motion.spring(reduced: reduceMotion), value: model.banner?.id)
                Divider().padding(.vertical, 8)
                footer
            }
            .animation(Motion.spring(reduced: reduceMotion), value: urgent)
            .animation(Motion.spring(reduced: reduceMotion), value: allClear)
            .animation(Motion.spring(reduced: reduceMotion), value: showingNew)
            .animation(Motion.spring(reduced: reduceMotion), value: only)
            .padding(.horizontal, 8).padding(.bottom, 8).padding(.top, 4)
            .frame(width: 370)
            // Rows leaving with a transition still count when the size is first measured, so the panel
            // also re-fits once the content's height settles (a filter used to leave empty space below).
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { totalHeight = $0; StatusMenu.fit() }
            .overlay(alignment: .top) {
                if actionsOpen, let cursor {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.06).contentShape(Rectangle()).onTapGesture { closeActions() }
                        ActionPanel(title: actionsTitle(cursor), actions: actions(for: cursor), close: closeActions)
                            .padding(.horizontal, 24).padding(.top, 56)
                    }
                    .transition(.opacity)
                }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard !actionsOpen else { return .ignored }
                move(press.key == .downArrow ? 1 : -1, proxy); return .handled
            }
            // Return falls through to the window only when this ignores it, so an open confirm bar's default button gets it.
            .onKeyPress(.return, phases: .down) { press in actionsOpen || typing || confirm != nil ? .ignored : activate(command: press.modifiers.contains(.command)) }
            .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in actionsOpen || typing ? .ignored : answerOption(press.characters) }
            .onKeyPress(characters: CharacterSet(charactersIn: Self.rowKeys)) { press in
                press.modifiers.isEmpty && !actionsOpen && !typing ? rowKey(press.characters) : .ignored
            }
            .onKeyPress(.escape) { escape(); return .handled }
            .background {
                // ⌘F: jump to search.
                Button("") { showingNew = false; searchAsked = true; searchFocused = true }
                    .keyboardShortcut("f").opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                Button("") { Task { await model.refreshNow() } }
                    .keyboardShortcut("r").opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                Button("") { openActions() }
                    .keyboardShortcut("k").opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                Button("") { settings() }
                    .keyboardShortcut(",").opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                Button("") { tab = .running }
                    .keyboardShortcut("1").opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                Button("") { tab = .recent }
                    .keyboardShortcut("2").opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                // ⌘⌫ and ⌘. are key equivalents, so onKeyPress never sees them. ⌘⌫ only ever denies a prompt
                // (in a text field it keeps its usual job); stopping a session is ⌘., so one chord never means two things.
                Button("") {
                    if typing { NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil); return }
                    guard !actionsOpen, case .card(let id) = cursor else { return }
                    _ = denyCard(id)
                }
                .keyboardShortcut(.delete, modifiers: .command).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                Button("") { if !actionsOpen && !typing { _ = rowKey(".", command: true) } }
                    .keyboardShortcut(".", modifiers: .command).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            .onAppear {
                model.menuOpen = true
                tab = model.live.contains { !$0.isLeftover } ? .running : .recent
                if model.startNewSession { showingNew = true; model.startNewSession = false }
                if let sid = model.replyTarget, let s = model.live.first(where: { $0.sessionId == sid }) {
                    model.replyTarget = nil; tab = .running; confirm = .reply(s)
                }
                listFocused = true
                StatusMenu.escape = escape
                // Same card ⌃⌥A answers, so the outline and the hotkey hint agree.
                let hotkeyTarget = model.pendingApprovals.first { $0.kind == .permission }?.id
                if let id = hotkeyTarget ?? model.pendingApprovals.last?.id { cursor = .card(id) }
            }
            .onDisappear {
                StatusMenu.escape = nil
                model.menuOpen = false; search = ""; searchAsked = false; confirm = nil; showingNew = false; tabMinHeight = 0
                only = nil; previewing = nil; cursor = nil; actionsOpen = false; allClear = false; hoveredRow = nil
            }
            .onChange(of: urgent) { was, now in
                guard was, !now, model.menuOpen, only == nil, !showingNew, !searching else { return }
                allClear = true
            }
            .task(id: allClear) {
                guard allClear, (try? await Task.sleep(nanoseconds: 1_800_000_000)) != nil else { return }
                allClear = false
            }
        }
        // The panel follows a height change one pass later; until then the content stays under the menu bar
        // instead of being centred in the old frame.
        .frame(maxHeight: .infinity, alignment: .top)
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
            else if r.kind == .permission, let risk = r.risk {
                model.banner = Banner(text: "This one \(risk). Click Allow once if you're sure.", isError: true)
            }
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

    private func denyCard(_ id: Int) -> KeyPress.Result {
        guard let r = model.approvals.first(where: { $0.id == id }), r.kind == .permission, model.outcomes[id] == nil else { return .ignored }
        model.answer(id, .deny)
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

    @ViewBuilder private var healthBanner: some View {
        let missing = model.missingHooks
        if !missing.isEmpty {
            let text = missing.contains("claude") ? "Prompts won't show up here until you repair setup"
                : "Usage and context won't update until you repair setup"
            Callout(tint: .orange) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Repair setup") { Task { await model.repairHooks() } }.controlSize(.small)
            }
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var header: some View {
        let waiting = cards.count + waitingRows.count
        let hit = model.limitHit
        return HStack(spacing: 12) {
            Button { showDetails(tab: .usage) } label: {
                Dot(mood: allClear ? .done : model.mood(for: model.closestWindow), percent: model.shownPercent, size: 36, celebrate: false)
            }
            .buttonStyle(.plain)
            .help("Dot's rim is your closest limit. Click for usage details.")
            .accessibilityLabel("Usage details")
            VStack(alignment: .leading, spacing: 1) {
                if urgent {
                    Text("\(Fmt.count(waiting, waitingRows.isEmpty ? "prompt" : "session")) waiting").font(.body.weight(.semibold))
                    counts(otherwise: "Nothing else running")
                } else if let hit, only == nil {
                    Text("Limit reached").font(.body.weight(.semibold)).foregroundStyle(Tone.riskText)
                    HStack(spacing: 0) {
                        Text("Back at \(hit.resetsAt.map(Fmt.clock) ?? "reset")").foregroundStyle(.secondary)
                        if model.live.contains(where: { !$0.isLeftover }) { Text(" · ").foregroundStyle(.secondary); counts(otherwise: "") }
                    }
                    .font(.subheadline)
                } else {
                    counts(otherwise: "No sessions running").font(.body.weight(.semibold))
                    Group {
                        if let only { Text("Showing \(only == .busy ? "working" : only == .idle ? "idle" : "waiting") sessions · Esc for all") }
                        else if allClear { Text("All clear").foregroundStyle(Tone.okText) }
                        else if let until = Notifier.snoozedUntil(snoozeTime) {
                            Button { Notifier.snooze(for: nil) } label: {
                                Label("Alerts snoozed until \(Fmt.clock(until)) · Resume", systemImage: "bell.slash")
                            }
                            .buttonStyle(.plain).help("Turn alerts back on")
                        }
                        else { Text("Nothing needs you" + (model.keepsAwake ? " · keeping the Mac awake" : "")) }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            IconButton(symbol: "magnifyingglass", on: searchAsked || searching, help: "Search sessions (⌘F)") {
                showingNew = false
                if searchAsked || searching {
                    searchAsked = false; search = ""; listFocused = true
                } else {
                    searchAsked = true; searchFocused = true
                }
            }
        }
        .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 8)
    }

    @ViewBuilder private func counts(otherwise: String) -> some View {
        let states: [(LiveSession.State, String)] = [(.blocked, "waiting"), (.busy, "working"), (.idle, "idle")]
        let shown = states.filter { st, _ in (st != .blocked || only == .blocked) && (model.count(st) > 0 || only == st) }
        if shown.isEmpty {
            Text(otherwise).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, item in
                    if i > 0 { Text(" · ").foregroundStyle(.secondary) }
                    countButton(item.0, item.1)
                }
            }
        }
    }

    private func countButton(_ state: LiveSession.State, _ word: String) -> some View {
        let n = model.count(state), on = only == state
        return Button {
            withAnimation(Motion.snappy(reduceMotion)) { only = on ? nil : state; cursor = nil }
        } label: {
            HStack(spacing: 3) {
                Text("\(n) \(word)").monospacedDigit()
                    .contentTransition(.numericText(value: Double(n)))
                if on { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, on || hoveredCount == state ? 6 : 0)
            .background(Capsule().fill(Color.primary.opacity(on ? 0.12 : hoveredCount == state ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredCount = $0 ? state : (hoveredCount == state ? nil : hoveredCount) }
        .animation(Motion.fast(reduceMotion), value: hoveredCount)
        .contextMenu {
            if state == .idle {
                Button("Stop all idle…") { confirm = .stopIdle }
            }
        }
        .help(on ? "Show all sessions" : "Show only sessions that are \(word == "waiting" ? "waiting for you" : word)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var needsYou: some View {
        let cards = self.cards, waitingRows = self.waitingRows
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 8) {
                    let focus: Int? = { if case .card(let id) = cursor, cards.contains(where: { $0.id == id }) { return id }; return cards.first?.id }()
                    ForEach(cards) { r in
                        Group {
                            if r.id == focus || cards.count == 1 {
                                ApprovalCard(model: model, request: r, selected: cursor == .card(r.id))
                            } else {
                                QueuedCard(model: model, request: r) { withAnimation(Motion.snappy(reduceMotion)) { cursor = .card(r.id) } }
                            }
                        }
                        .id(Item.card(r.id))
                        .transition(ApprovalCard.transition(model.outcomes[r.id], reduced: reduceMotion))
                    }
                    ForEach(waitingRows) { s in liveRow(s) }
                    if cards.isEmpty && waitingRows.isEmpty {
                        Text("Nothing waiting matches.").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                .animation(Motion.spring(reduced: reduceMotion), value: model.approvals.map(\.id))
            }
            .frame(maxHeight: heights.needsYou)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { needsYouHeight = $0 }
            .onDisappear { needsYouHeight = 0 }
        }
    }

    @ViewBuilder private var usage: some View {
        if let u = model.usage {
            let stale = Date().timeIntervalSince(u.updatedAt) > 600
            Button { showDetails(tab: .usage) } label: {
                VStack(spacing: 8) {
                    if let w = u.fiveHour { Meter(window: w, forecast: model.forecast(w)) }
                    if let w = u.weekly { Meter(window: w, forecast: model.forecast(w)) }
                }
                .opacity(stale ? 0.6 : 1)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Radius.row).fill(usageHover ? Color.primary.opacity(0.05) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .onHover { usageHover = $0 }
            .animation(Motion.fast(reduceMotion), value: usageHover)
            .help(stale ? "Couldn't reach Anthropic. These update with your next Claude Code message."
                  : "\(model.usageIsAccount ? "Whole account, every Mac on this login" : u.model ?? "Usage") · updated \(Fmt.ago(u.updatedAt)). Click for details.")
            if stale {
                Text("Updated \(Fmt.ago(u.updatedAt)). It refreshes with your next message.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LastHourBar(model: model, collapsible: true).font(.subheadline).padding(.horizontal, 8).padding(.top, 4)
            // Sonnet shares the 5-hour limit, so switching helps only before it's reached.
            if model.limitHit == nil,
               let w = [u.fiveHour, u.weekly].compactMap({ $0 }).first(where: { if case .reachesLimit(let at) = model.forecast($0), at > Date() { true } else { false } }),
               case .reachesLimit(let at) = model.forecast(w), !model.switchCandidates.isEmpty {
                Callout(tint: .orange) {
                    Image(systemName: "clock").foregroundStyle(.orange)
                    Text("You'll hit the \(w.label.lowercased()) limit around \(Fmt.clock(at)). Sonnet uses less of it.").fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Switch \(model.switchCandidates.count) to Sonnet") { model.switchToSonnet() }
                        .controlSize(.small)
                        .help("Switches idle Opus sessions to Sonnet by typing /model sonnet")
                }
                .font(.subheadline).padding(.top, 6)
            }
            limitStops
            if model.notificationsOff && notifyLimits {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                } label: {
                    Label("Notifications are off, so you won't hear about limits. Turn them on", systemImage: "bell.slash")
                        .font(.subheadline).foregroundStyle(Tone.warnText).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).padding(.horizontal, 8).padding(.top, 6)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage limits").font(.body.weight(.semibold))
                Text("Your limits show up after your next Claude Code message.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(8)
        }
    }

    @ViewBuilder private var limitStops: some View {
        let stopped = model.live.filter { model.isStoppedAtLimit($0) && model.typingBlockers[$0.sessionId] == nil }
        if let hit = model.limitHit, !stopped.isEmpty {
            let at = hit.resetsAt.map(Fmt.clock) ?? "the reset"
            let queued = stopped.allSatisfy { model.continueQueue.contains($0.sessionId) }
            Callout(tint: .secondary) {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("\(Fmt.count(stopped.count, "session")) stopped at the limit. Pick \(stopped.count == 1 ? "it" : "them") up again when it resets?")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    for s in stopped where queued || !model.continueQueue.contains(s.sessionId) { model.toggleContinue(s) }
                } label: {
                    Label(queued ? "Continues at \(at)" : "Continue at \(at)", systemImage: queued ? "checkmark.circle.fill" : "play.circle")
                        .fixedSize()
                }
                .controlSize(.small)
                .help(queued ? "Click to cancel" : "Types \"continue\" into each of them the moment the limit resets")
            }
            .font(.subheadline).padding(.top, 6)
        }
    }

    private func matches(_ text: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || text.contains { $0.lowercased().contains(q) }
    }

    private func matches(_ s: LiveSession) -> Bool {
        !searching || matches(model.displayName(s), s.cwd, s.sessionId, model.lastPrompt(s.sessionId))
    }

    private var sessions: some View {
        let running = self.running, closed = self.closed, isGrouped = grouped(running)
        return VStack(alignment: .leading, spacing: 4) {
            if showSearch {
                TextField("Search name, folder, prompt or ID", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .controlSize(.regular)
                    .padding(.horizontal, 8)
                    .onKeyPress(.downArrow) { cursor = nil; listFocused = true; return .ignored }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if tabsShown {
                Picker("", selection: $tab) {
                    Text("Running").tag(ListTab.running)
                    Text("Recent").tag(ListTab.recent)
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 8).padding(.bottom, 4)
                .help("⌘1 Running · ⌘2 Recent")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if showsRunning { runningList(running, grouped: isGrouped) }
                    if showsRecent { recentList(closed) }
                }
                .animation(Motion.spring(reduced: reduceMotion), value: running.map(\.id))
                .animation(Motion.spring(reduced: reduceMotion), value: closed.map(\.id))
                .animation(Motion.spring(reduced: reduceMotion), value: confirm)
                .animation(Motion.spring(reduced: reduceMotion), value: previewing)
            }
            .frame(maxHeight: heights.sessions)
            .fixedSize(horizontal: false, vertical: true)
            // Switching tabs keeps the height the list had, so the panel doesn't jump; a taller tab still grows it.
            .frame(minHeight: tabMinHeight > 0 ? min(tabMinHeight, heights.sessions) : nil, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sessionsHeight = $0 }
            .onDisappear { sessionsHeight = 0 }
        }
        .animation(Motion.spring(reduced: reduceMotion), value: showSearch)
        .onChange(of: tab) { tabMinHeight = sessionsHeight; cursor = nil }
        .onChange(of: tabsShown) { tabMinHeight = 0 }
    }

    @ViewBuilder private func runningList(_ running: [LiveSession], grouped isGrouped: Bool) -> some View {
                    if !tabsShown {
                        SectionHeader(title: "\(only.map(stateTitle) ?? "Running") · \(running.count)")
                    }
                    if running.isEmpty {
                        HStack {
                            Text(searching ? "No running session matches." : only != nil ? "None right now." : "Nothing running right now.")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            if !searching && only == nil && model.live.isEmpty { Button("New session…") { showingNew = true }.controlSize(.small) }
                        }
                        .padding(8)
                    }
                    if isGrouped {
                        ForEach(ProjectGroups.group(running), id: \.name) { g in groupView(g) }
                    } else {
                        ForEach(running) { s in liveRow(s).transition(.opacity.combined(with: .move(edge: .top))) }
                    }
    }

    @ViewBuilder private func recentList(_ closed: [HistorySession]) -> some View {
        if searching { SectionHeader(title: "Closed · matches").padding(.top, 8) }
        if closed.isEmpty {
            Text(searching ? "No closed session matches." : "No closed sessions yet.").font(.callout).foregroundStyle(.secondary).padding(8)
        } else {
            ForEach(closed) { h in closedRowWithConfirm(h).transition(.opacity) }
            if !searching && model.closed.count > closed.count {
                Button { showDetails(tab: .sessions) } label: {
                    HStack(spacing: 4) {
                        Text("All \(model.closed.count) in Details")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stateTitle(_ s: LiveSession.State) -> String {
        switch s { case .blocked: "Waiting"; case .busy: "Working"; case .idle: "Idle" }
    }

    @ViewBuilder private func groupView(_ g: ProjectGroups.Group) -> some View {
        let open = !collapsed.contains(g.name)
        Button {
            withAnimation(Motion.snappy(reduceMotion)) {
                if open { collapsed.insert(g.name) } else { collapsed.remove(g.name) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(g.name).font(.callout.weight(.semibold))
                if g.sessions.contains(where: { $0.state == .blocked }) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        .help("Something here needs you")
                }
                Spacer()
                Text("\(g.sessions.count)").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open {
            ForEach(Array(g.sessions.enumerated()), id: \.element.id) { i, s in
                liveRow(s, grouped: true).padding(.leading, 12).transition(stagger(i))
            }
        }
    }

    private func stagger(_ i: Int) -> AnyTransition {
        reduceMotion ? .opacity
            : AnyTransition.opacity.combined(with: .move(edge: .top)).animation(Motion.spring(reduced: false).delay(Double(min(i, 5)) * 0.02))
    }

    @ViewBuilder private func liveRow(_ s: LiveSession, grouped: Bool = false) -> some View {
        let busy = model.working.contains(s.sessionId)
        let waiting = s.state == .blocked && !s.isLeftover
        let showButtons = voiceOver || busy || model.live.count == 1 || hoveredRow == s.sessionId || cursor == .live(s.sessionId)
            || confirm?.sessionId == s.sessionId
        VStack(spacing: 4) {
            let place = Fmt.place(s.cwd, branch: model.branches[s.cwd], name: model.displayName(s), grouped: grouped)
            let context = model.context[s.sessionId].flatMap { $0.percent >= ContextBar.warnAt ? $0 : nil }
            HoverRow(selected: cursor == .live(s.sessionId)) {
                StateDot(state: s.isLeftover ? nil : s.state, animated: model.menuOpen
                         && (s.state != .busy || model.count(.busy) <= 1 || cursor == .live(s.sessionId) || hoveredRow == s.sessionId))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(highlighted(model.displayName(s), search)).font(.body.weight(waiting ? .semibold : .medium)).lineLimit(1)
                        if s.isOnPhone { Image(systemName: "iphone").font(.system(size: 12)).foregroundStyle(.secondary).help("On your phone") }
                        if s.kind == .background { Pill(text: "Background").help("Background session: it runs without a terminal window") }
                    }
                    if model.isStoppedAtLimit(s) {
                        if let place { Text(place).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                        LimitStopLine(model: model, session: s)
                    } else if place != nil || ActivityLine.isShown(s, model) {
                        ActivityLine(model: model, session: s, prefix: place)
                    }
                }
                .help(s.cwd)
                .accessibilityElement(children: .contain)
                Spacer(minLength: 4)
                ZStack(alignment: .trailing) {
                    HStack(spacing: 4) {
                        if let context { ContextBar(reading: context) }
                        Image(systemName: "ellipsis").foregroundStyle(.tertiary).frame(width: 20, height: 24)
                    }
                    .opacity(showButtons ? 0 : 1)
                    .accessibilityHidden(showButtons)
                    HStack(spacing: 2) {
                        if model.live.count == 1, let context { ContextBar(reading: context).padding(.trailing, 4) }
                        rowButtons(s)
                    }
                        .opacity(busy ? 0.3 : showButtons ? 1 : 0)
                        .disabled(busy)
                        .allowsHitTesting(showButtons)
                        .accessibilityHidden(!showButtons)
                        .overlay { if busy { ProgressView().controlSize(.small).transition(.opacity) } }
                }
                .animation(Motion.fast(reduceMotion), value: showButtons)
                .animation(Motion.fast(reduceMotion), value: busy)
            } action: { model.open(s) }
            .onHover { inside in
                if inside { hoveredRow = s.sessionId } else if hoveredRow == s.sessionId { hoveredRow = nil }
            }
            .background { if waiting { RoundedRectangle(cornerRadius: Radius.row).fill(Color.orange.opacity(0.08)) } }
            .animation(Motion.snappy(reduceMotion), value: s.state)
            .contextMenu {
                Button("Reply…") { confirm = .reply(s) }.disabled(replyBlocker(s) != nil)
                Button("Rename…") { confirm = .renameLive(s) }
                    .disabled(s.kind == .background || model.typingBlockers[s.sessionId] != nil)
                Button("Compact context…") { askCompact(s) }
                    .disabled(blocker(s, "compact") != nil)
                Button("Clear context…") { askClear(s) }
                    .disabled(s.kind == .background || s.state == .busy || model.typingBlockers[s.sessionId] != nil)
                Button(s.kind == .interactive ? "Show its window" : "Open in \(TerminalApp.current.title)") { model.open(s) }
                if let url = s.phoneURL { Button("Copy phone link") { copy(url.absoluteString) } }
                Button("Copy session ID") { copy(s.sessionId) }
            }

            if let c = confirm, c.sessionId == s.sessionId { confirmBar(c).transition(slide(from: .top)) }
        }
        .id(Item.live(s.sessionId))
    }

    private func togglePhone(_ s: LiveSession) {
        switch (s.isOnPhone, s.kind) {
        case (false, .interactive): model.phoneOn(s)    // keeps running here too
        case (true, .interactive): model.phoneOff(s)    // keeps running here
        case (false, .background): confirm = .openWithPhone(s)
        case (true, .background): confirm = .stop(s)    // phone is its only window
        }
    }

    private func askCompact(_ s: LiveSession) {
        confirm = .compact(s)
    }

    private func askClear(_ s: LiveSession) {
        confirm = .clearContext(s)
    }

    private func replyBlocker(_ s: LiveSession) -> String? {
        if s.kind == .background { return "It runs without a window. Open it to reply." }
        return model.typingBlockers[s.sessionId]
    }

    private func statusBanner(_ st: ServiceStatus) -> some View {
        Callout(tint: .secondary) {
            Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
            Text(st.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Status page ↗") { NSWorkspace.shared.open(st.link) }.controlSize(.small)
        }
        .font(.subheadline)
        .help("Slow or failed replies are likely on Anthropic's side, not your session.")
    }

    private func blocker(_ s: LiveSession, _ verb: String) -> String? {
        if s.kind == .background { return "It runs without a window, so there's nothing to \(verb)." }
        return model.typingBlockers[s.sessionId] ?? (s.state == .busy ? "Wait until it finishes its reply." : nil)
    }

    /// Esc steps back one layer and only closes the dropdown when there's nothing left to back out of.
    /// The panel's cancelOperation calls this too, since a mouse click can leave no SwiftUI view focused.
    private func escape() {
        if actionsOpen { withAnimation(Motion.fast(reduceMotion)) { actionsOpen = false }; return }
        if confirm != nil { confirm = nil; listFocused = true; return }
        if searching { search = ""; return }
        if previewing != nil { withAnimation(Motion.snappy(reduceMotion)) { previewing = nil }; return }
        if only != nil { only = nil; return }
        if showingNew { withAnimation(Motion.spring(reduced: reduceMotion)) { showingNew = false }; listFocused = true; return }
        if cursor != nil { cursor = nil; return }
        StatusMenu.close()
    }

    /// The single-letter row keys ⌘K and Settings advertise. rowKey handles each one; keep the three in step.
    static let rowKeys = "mpckr"

    private func rowKey(_ key: String, command: Bool = false) -> KeyPress.Result {
        guard case .live(let sid) = cursor, let s = model.live.first(where: { $0.sessionId == sid }),
              !model.working.contains(sid) else { return .ignored }
        let unavailable = { (why: String) in model.banner = Banner(text: why, isError: true) }
        switch key {
        case "p": if let why = model.typingBlockers[sid] { unavailable(why) } else { togglePhone(s) }
        case "k": if let why = blocker(s, "clear") { unavailable(why) } else { askClear(s) }
        case "c": if let why = blocker(s, "compact") { unavailable(why) } else { askCompact(s) }
        case "r":
            if s.kind == .background { unavailable("It runs without a window, so it can't be renamed here.") }
            else if let why = model.typingBlockers[sid] { unavailable(why) } else { confirm = .renameLive(s) }
        case "m": if let why = replyBlocker(s) { unavailable(why) } else { confirm = .reply(s) }
        case "." where command: if s.stopAsksFirst { confirm = .stop(s) } else { model.stop(s) }
        default: return .ignored
        }
        return .handled
    }

    @ViewBuilder private func rowButtons(_ s: LiveSession) -> some View {
        IconButton(symbol: "iphone", on: s.isOnPhone, help: model.typingBlockers[s.sessionId] ?? phoneHelp(s),
                   dimmed: model.typingBlockers[s.sessionId] != nil) { togglePhone(s) }
        if s.kind == .interactive {
            let why = blocker(s, "compact")
            let percent = model.context[s.sessionId]?.percent ?? 0
            IconButton(symbol: "arrow.down.right.and.arrow.up.left",
                       tint: percent >= ContextBar.warnAt && why == nil ? ContextBar.tint(percent) : nil,
                       help: why ?? "Compact the conversation to free up context. Clear is in the right-click menu.",
                       dimmed: why != nil) { askCompact(s) }
        }
        Color.clear.frame(width: 8, height: 1)
        IconButton(symbol: s.isLeftover ? "xmark" : "stop.fill",
                   help: s.isLeftover ? "Remove this ended session (its history stays)" : "Stop session") {
            if s.stopAsksFirst { confirm = .stop(s) } else { model.stop(s) }
        }
    }

    private func closedRow(_ h: HistorySession) -> some View {
        let open = previewing == h.sessionId
        return HoverRow(selected: cursor == .closed(h.sessionId), open: { model.resumeInTerminal(h) }) {
            StateDot(state: nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(h.name, search)).font(.body.weight(open ? .semibold : .medium)).lineLimit(1)
                if !open {
                    Text(model.duplicateNames.contains(h.name) && h.lastPrompt?.isEmpty == false
                         ? "“\(h.lastPrompt ?? "")” · \(Fmt.folderTitle(h.cwd))" : Fmt.folderTitle(h.cwd))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        .help(h.cwd)
                }
            }
            Spacer(minLength: 4)
            Text(Fmt.ago(h.lastActive)).font(.subheadline).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
        } action: {
            withAnimation(Motion.snappy(reduceMotion)) { previewing = open ? nil : h.sessionId }
            cursor = .closed(h.sessionId)
        }
        .contextMenu {
            Button("Rename…") { confirm = .renameClosed(h) }
            Button("Resume in \(TerminalApp.current.title)") { model.resumeInTerminal(h) }
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
        .background { if open { RoundedRectangle(cornerRadius: Radius.row).fill(Color.primary.opacity(0.05)) } }
        .overlay { if open { RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Color.primary.opacity(0.3), lineWidth: 1) } }
        .id(Item.closed(h.sessionId))
    }

    private func phoneHelp(_ s: LiveSession) -> String {
        switch (s.isOnPhone, s.kind) {
        case (false, .interactive): return "Open it on your phone too. It keeps running here."
        case (true, .interactive): return "On your phone. Click to disconnect the phone. It keeps running here."
        case (false, .background): return s.isLeftover ? "Reopen it in \(TerminalApp.current.title) and on your phone"
                                                       : "Open in \(TerminalApp.current.title) and on your phone"
        case (true, .background): return "Only on your phone. Click to stop it."
        }
    }

    @ViewBuilder private func confirmBar(_ c: Confirm) -> some View {
        Group {
            switch c {
            case .stop(let s):
                ConfirmRow(message: s.state == .blocked ? "It's waiting for your answer. Stop it anyway?"
                                    : s.kind == .background && s.isOnPhone ? "It runs only on your phone. Stop it?"
                                    : s.isOnPhone ? "Stop it? It closes on your phone too." : "Stop this session?",
                           confirmTitle: "Stop", destructive: true, cancel: { confirm = nil }) { confirm = nil; model.stop(s) }
            case .stopIdle:
                let idle = model.live.filter { $0.state == .idle && !$0.isLeftover }
                ConfirmRow(message: "Stop \(Fmt.count(idle.count, "idle session"))? You can resume any of them from Recent.",
                           confirmTitle: "Stop all", destructive: true, cancel: { confirm = nil }) { confirm = nil; idle.forEach(model.stop) }
            case .compact(let s):
                ConfirmRow(message: "Compact this conversation? Claude keeps a summary and lets go of the details. Nothing is deleted.",
                           confirmTitle: "Compact", cancel: { confirm = nil }) { confirm = nil; model.compact(s) }
            case .clearContext(let s):
                ConfirmRow(message: "Start fresh in the same window? You can undo it.",
                           confirmTitle: "Clear", cancel: { confirm = nil }) { confirm = nil; model.clearContext(s) }
            case .openWithPhone(let s):
                ConfirmRow(message: "It runs without a window. Open it in \(TerminalApp.current.title) and on your phone?",
                           confirmTitle: "Open", cancel: { confirm = nil }) { confirm = nil; model.phoneOn(s) }
            case .renameLive(let s):
                HStack(spacing: 8) {
                    RenameField(initial: model.displayName(s)) { name in confirm = nil; if let name { model.rename(s, to: name) } }
                }
            case .reply(let s):
                VStack(alignment: .leading, spacing: 4) {
                    if let replyContext {
                        Text("Claude: \(replyContext)").font(.subheadline).foregroundStyle(.secondary).lineLimit(2).help(replyContext)
                    }
                    HStack(spacing: 8) {
                        ReplyField(queued: s.state == .busy) { text in confirm = nil; if let text { model.reply(s, text) } }
                    }
                    Text(s.state == .busy ? "It's working, so this goes out when it finishes · Esc cancels" : "Types it into its terminal tab and presses Return · Esc cancels")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .task(id: s.sessionId) { replyContext = await model.lastReplyLine(s.sessionId) }
            case .renameClosed(let h):
                HStack(spacing: 8) {
                    RenameField(initial: h.name) { name in confirm = nil; if let name { model.rename(h, to: name) } }
                }
            case .delete(let h):
                DeleteConfirm(model: model, sessions: [h], compact: true) { confirm = nil }
            }
        }
        .confirmBar()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cursor {
                let onCard: Bool = { if case .card = cursor { return true }; return false }()
                let hint = onCard ? cardHint : "↑↓ move · ⏎ open · ⌘K actions"
                Text(hint)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 8)
                    .transition(.opacity)
                    .accessibilityLabel("Keyboard: " + Self.spoken(hint))
            }
            HStack {
                Button { showingNew.toggle() } label: { Label(showingNew ? "Back" : "New session…", systemImage: showingNew ? "chevron.left" : "plus") }
                    .keyboardShortcut("n")
                Spacer()
                Button("View details…") { showDetails(tab: .sessions) }
                Menu {
                    if let until = Notifier.snoozedUntil(snoozeTime) {
                        Button("Alerts snoozed until \(Fmt.clock(until))") {}.disabled(true)
                        Button("Resume alerts") { Notifier.snooze(for: nil) }
                    } else {
                        Button("Snooze alerts for 1 hour") { Notifier.snooze(for: 3600) }
                    }
                    Toggle(AppModel.keepAwakeTitle, isOn: Binding(get: { UserDefaults.standard.bool(forKey: AppModel.keepAwakeKey) },
                                                                  set: { model.setKeepAwake($0) }))
                    Divider()
                    Button("Settings…") { settings() }
                    Divider()
                    Button("Quit Agent Deck") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Settings, snooze and quit")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
        }
    }

    private var cardHint: String {
        guard case .card(let id) = cursor, let r = model.approvals.first(where: { $0.id == id }) else { return "↑↓ move · ⌘K actions" }
        switch r.kind {
        case .question: return "↑↓ move · 1–\(min(4, r.questions.first?.options.count ?? 4)) pick an answer · ⌃⌥J show"
        case .plan: return "↑↓ move · ⌘⏎ approve plan · ⌘K more · ⌃⌥J show"
        case .permission:
            return r.risk == nil ? "⌘⏎ allow · ⌘⌫ deny · ⌘K more · ⌃⌥A ⌃⌥D ⌃⌥J anywhere" : "⌘⌫ deny · allowing it takes a click · ⌃⌥J show"
        }
    }

    static func spoken(_ hint: String) -> String {
        [("⌃⌥", "Control Option "), ("⌘⏎", "Command Return"), ("⌘⌫", "Command Delete"), ("⌘K", "Command K"),
         ("↑↓", "arrows"), ("⏎", "Return"), (" · ", ", ")]
            .reduce(hint) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private func openActions() {
        guard !showingNew else { return }
        let list = items
        if cursor.map({ !list.contains($0) }) ?? true { cursor = list.first }
        guard cursor != nil else { return }
        withAnimation(Motion.fast(reduceMotion)) { actionsOpen = true }
    }

    private func closeActions() {
        withAnimation(Motion.fast(reduceMotion)) { actionsOpen = false }
        listFocused = true
    }

    private func actionsTitle(_ item: Item) -> String {
        switch item {
        case .card(let id): return model.approvals.first { $0.id == id }.map { model.sessionName($0.sessionId, cwd: $0.cwd) } ?? "this prompt"
        case .live(let sid): return model.live.first { $0.sessionId == sid }.map(model.displayName) ?? "this session"
        case .closed(let sid): return model.closed.first { $0.sessionId == sid }?.name ?? "this session"
        }
    }

    private func actions(for item: Item) -> [DeckAction] {
        switch item {
        case .card(let id):
            guard let r = model.approvals.first(where: { $0.id == id }), model.outcomes[id] == nil else { return [] }
            var list: [DeckAction] = []
            switch r.kind {
            case .permission:
                if let risk = r.risk {
                    list.append(DeckAction(title: "Allow once", detail: "Risky: \(risk)") { model.answer(id, .allow(always: false)) })
                } else {
                    list.append(DeckAction(title: "Allow", key: "⌘⏎") { model.answer(id, .allow(always: false)) })
                    if let rule = r.alwaysLabel {
                        for scope in RuleScope.allCases {
                            let title = scope == .session ? "Allow for this session" : scope == .project ? "Always allow in \(Fmt.folderTitle(r.cwd))" : "Always allow in every project"
                            list.append(DeckAction(title: title, detail: rule) {
                                model.answer(id, .allow(always: true, scope: scope))
                            })
                        }
                    }
                }
            case .plan:
                list.append(DeckAction(title: "Approve plan", key: "⌘⏎") { model.approvePlan(r, acceptEdits: false) })
                list.append(DeckAction(title: "Approve, auto-accept edits") { model.approvePlan(r, acceptEdits: true) })
            case .question:
                break
            }
            list.append(DeckAction(title: "Answer in the terminal", key: "⏎") { model.openSession(id: r.sessionId) })
            if r.kind == .permission { list.append(DeckAction(title: "Deny", key: "⌘⌫", destructive: true) { model.answer(id, .deny) }) }
            return list
        case .live(let sid):
            guard let s = model.live.first(where: { $0.sessionId == sid }) else { return [] }
            let open = DeckAction(title: s.kind == .interactive ? "Show its window" : "Open in \(TerminalApp.current.title)", key: "⏎") { model.open(s) }
            let working = model.working.contains(sid) ? "Still doing the last thing. Try again in a moment." : nil
            let typing = model.typingBlockers[sid]
            var list = [open]
            if !s.isLeftover {
                list.append(DeckAction(title: model.queuedReplies[sid] == nil ? "Reply…" : "Replace queued reply…", key: "M",
                                       unavailable: working ?? replyBlocker(s)) { confirm = .reply(s) })
                list.append(DeckAction(title: "Compact context…", detail: "Frees up context. Claude keeps a summary.", key: "C",
                                       unavailable: working ?? blocker(s, "compact")) { askCompact(s) })
                list.append(DeckAction(title: phoneTitle(s), key: "P", unavailable: working ?? typing) { togglePhone(s) })
                list.append(DeckAction(title: "Rename…", key: "R",
                                       unavailable: working ?? (s.kind == .background ? "It runs without a window, so it can't be renamed here." : typing)) { confirm = .renameLive(s) })
                list.append(DeckAction(title: "Clear context…", key: "K", unavailable: working ?? blocker(s, "clear")) { askClear(s) })
            }
            if let url = s.phoneURL { list.append(DeckAction(title: "Copy phone link") { copy(url.absoluteString) }) }
            list.append(DeckAction(title: "Copy session ID") { copy(s.sessionId) })
            if s.state == .idle && !s.isLeftover && model.count(.idle) > 1 {
                list.append(DeckAction(title: "Stop all idle…", destructive: true) { confirm = .stopIdle })
            }
            list.append(DeckAction(title: s.isLeftover ? "Remove from list" : s.stopAsksFirst ? "Stop session…" : "Stop session", key: "⌘.", destructive: true,
                                   unavailable: working) { if s.stopAsksFirst { confirm = .stop(s) } else { model.stop(s) } })
            return list
        case .closed(let sid):
            guard let h = model.closed.first(where: { $0.sessionId == sid }) else { return [] }
            return [
                DeckAction(title: "Resume in \(TerminalApp.current.title)", key: "⏎") { model.resumeInTerminal(h) },
                DeckAction(title: previewing == sid ? "Hide preview" : "Preview") {
                    withAnimation(Motion.snappy(reduceMotion)) { previewing = previewing == sid ? nil : sid }
                },
                DeckAction(title: "Rename…") { confirm = .renameClosed(h) },
                DeckAction(title: "Copy session ID") { copy(h.sessionId) },
                DeckAction(title: "Delete…", destructive: true) { confirm = .delete(h) },
            ]
        }
    }

    private func phoneTitle(_ s: LiveSession) -> String {
        switch (s.isOnPhone, s.kind) {
        case (false, .interactive): return "Also open on phone"
        case (true, .interactive): return "Disconnect phone (keeps running)"
        case (false, .background): return "Open in \(TerminalApp.current.title) and on your phone"
        case (true, .background): return "Stop it (it's only on your phone)…"
        }
    }

    private func showDetails(tab: DetailsTab) {
        model.showDetails?(tab)
    }

    private func settings() {
        StatusMenu.close()
        openSettings()
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
                d.prompts > 0 ? "\(Fmt.count(d.prompts, "prompt"))" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = session.lastPrompt, !p.isEmpty { line("Last prompt", p) }
            if let r = detail?.lastReply { line("Last reply", r) }
            if !stats.isEmpty { Text(stats).foregroundStyle(.secondary) }
            Text(Fmt.shortPath(session.cwd)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Button { model.resumeInTerminal(session) } label: { Label("Resume in \(TerminalApp.current.title)", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent)
                Button("Rename…", action: rename)
                Spacer()
                Button("Delete…", role: .destructive, action: delete)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .font(.subheadline)
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
    @State private var isRepo = false
    @State private var worktree = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New session").font(.body.weight(.semibold))
            Text("Folder").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            FlowChips(items: model.recentFolders, selected: $folder)
            HStack(spacing: 8) {
                if let folder { Text(Fmt.shortPath(folder)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 4)
                Button("Other folder…") { browse() }.controlSize(.small)
            }
            if isRepo, let folder {
                Toggle(isOn: $worktree) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Work in a new worktree")
                        Text(worktree ? "New worktree: \(Fmt.folderTitle(folder))/\(name.isEmpty ? "named by Claude" : ClaudeCLI.ShellLine.slug(name))"
                                      : "Its own branch and folder, so it can't touch your checkout")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
            }
            Text("Name").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Optional, like fix-login", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button { start(phone: true) } label: { Label("Start on phone", systemImage: "iphone") }
                    .help("Opens no window here. It shows up in the Claude app a few seconds later.")
                Spacer()
                Button { start(phone: false) } label: { Label("Open in \(TerminalApp.current.title)", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .disabled(folder == nil || model.working.contains("new"))
        }
        .padding(8)
        .onAppear { folder = folder ?? model.recentFolders.first; worktree = false }
        .task(id: folder) {
            guard let f = folder else { isRepo = false; return }
            isRepo = await Task.detached { Git.branch(f) != nil }.value
        }
    }

    private func start(phone: Bool) {
        guard let folder else { return }
        let w = isRepo && worktree
        if phone { model.newOnPhone(folder: folder, name: name, worktree: w) } else { model.newInTerminal(folder: folder, name: name, worktree: w) }
        isShown = false
        name = ""
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.level = .popUpMenu   // the dropdown sits at this level; same level, ordered later, so it shows on top
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

struct FlowChips: View {
    let items: [String]
    @Binding var selected: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { f in
                Button { selected = f } label: {
                    Text(Fmt.folderTitle(f)).font(.subheadline).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Capsule().fill(Color.primary.opacity(selected == f ? 0.12 : 0.08)))
                        .overlay(Capsule().stroke(selected == f ? Color.primary.opacity(0.45) : .clear))
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
            Callout(tint: b.blocking ? .red : b.isError ? .orange : .green, alignment: .top) {
                Image(systemName: b.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(b.blocking ? .red : b.isError ? .orange : .green)
                Text(b.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let title = b.actionTitle, let action = b.action {
                    Button(title) { model.banner = nil; action() }.controlSize(.small)
                }
                Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
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
            .padding(.bottom, 8)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                    .help("The conversation, scratchpad, undo backups and anything else Claude Code keeps for this session")
                Spacer()
                Button("Cancel", action: onDone)
                Button(picked.isEmpty ? "Delete" : "Delete + \(Fmt.count(picked.count, "file"))", role: .destructive) {
                    model.delete(sessions, files: Array(picked))
                    onDone()
                }
            }
            if !files.isEmpty {
                DisclosureGroup(isExpanded: $showFiles) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(files) { fileRow($0) }
                        Text("These are files Claude created with its Write tool. Only the ones you tick are deleted.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                } label: {
                    Text("Files this session created in \(Fmt.folderTitle(sessions[0].cwd)) (\(files.count))")
                }
            }
        }
        .task(id: sessions.map(\.sessionId)) {
            let r = await model.deletePreview(sessions)
            (bytes, files, picked) = (r.bytes, r.files, [])
        }
    }

    private func fileRow(_ f: CreatedFile) -> some View {
        HStack(spacing: 4) {
            Toggle("", isOn: Binding(get: { picked.contains(f.url) },
                                     set: { if $0 { picked.insert(f.url) } else { picked.remove(f.url) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!f.canDelete)
            Text(relative(f.url)).lineLimit(1).truncationMode(.middle).help(f.url.path)
            Spacer(minLength: 4)
            switch f.state {
            case .inGit: Label("in git, kept", systemImage: "lock.fill").foregroundStyle(.secondary)
            case .changedSince: Label("changed since", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.warnText)
            case .untracked: Text("untracked").foregroundStyle(.secondary)
            }
            if !compact { Text(Fmt.bytes(f.bytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing) }
        }
        .font(.subheadline)
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } }
    }

    private func relative(_ url: URL) -> String {
        let root = sessions[0].cwd + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : Fmt.shortPath(url.path)
    }
}

struct DeckAction {
    let title: String
    var detail: String?
    var key = ""
    var destructive = false
    var unavailable: String?
    let run: () -> Void
}

struct ActionPanel: View {
    let title: String
    let actions: [DeckAction]
    let close: () -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var shown: [DeckAction] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? actions : actions.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        let list = shown
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 12).padding(.top, 8)
            TextField("Actions", text: $query)
                .textFieldStyle(.plain).font(.body)
                .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 8)
                .focused($focused)
                .onKeyPress(.downArrow) { index = min(index + 1, max(list.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onExitCommand(perform: close)
                .onSubmit { run(list) }
                .onChange(of: query) { index = 0 }
            Divider()
            if list.isEmpty {
                Text(actions.isEmpty ? "Nothing to do here right now." : "No matching action.")
                    .font(.callout).foregroundStyle(.secondary).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(list.enumerated()), id: \.offset) { i, a in
                            if a.destructive && i > 0 && !list[i - 1].destructive { Divider().padding(.vertical, 3).padding(.horizontal, 6) }
                            Button { index = i; run(list) } label: {
                                row(a, selected: i == index).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { index = i } }
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.panel).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Color.primary.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .onAppear { focused = true }
        .accessibilityAddTraits(.isModal)
    }

    private func run(_ list: [DeckAction]) {
        guard list.indices.contains(index) else { return }
        let a = list[index]
        guard a.unavailable == nil else { NSSound.beep(); return }
        close()
        a.run()
    }

    private func row(_ a: DeckAction, selected: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.callout)
                    .foregroundStyle(selected ? Color.white : a.destructive ? Tone.riskText : Color.primary)
                if let sub = a.unavailable ?? a.detail {
                    Text(sub).font(.subheadline).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if !a.key.isEmpty {
                Keycap(a.key, onHighlight: selected)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Radius.inner).fill(selected ? Color.accentColor : .clear))
        .opacity(a.unavailable == nil ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityHint(a.unavailable ?? "")
    }
}

struct WelcomeCard: View {
    let model: AppModel
    let done: () -> Void
    @AppStorage(MenuHotkey.key) private var menuHotkey = MenuHotkey.off.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Dot(mood: .back, percent: model.shownPercent, size: 48, extras: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hi, I'm Dot").font(.body.weight(.semibold))
                    Text("My rim is your usage limit, and my face shows what your sessions need. The tick on each bar below is how much of that window's time has passed.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                setup
                Label("Press ⌘K on any row to see everything you can do", systemImage: "keyboard")
                if menuHotkey != MenuHotkey.off.rawValue && model.menuHotkeyFailed {
                    Label("\(MenuHotkey(rawValue: menuHotkey)?.title ?? "The shortcut") is already used by another app. Pick another one in Settings → Shortcuts.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.warnText)
                }
            }
            HStack(spacing: 8) {
                if menuHotkey == MenuHotkey.off.rawValue {
                    Button("Open with ⌃⌥O") {
                        menuHotkey = MenuHotkey.ctrlOptO.rawValue
                        model.setMenuHotkey(.ctrlOptO)
                    }
                    .help("Opens this menu from any app. Change it or turn it off in Settings → Shortcuts.")
                }
                Spacer()
                Button("Got it", action: done).buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var setup: some View {
        if model.health == nil {
            Label("Checking setup…", systemImage: "hourglass").foregroundStyle(.secondary)
        } else if model.missingHooks.isEmpty && model.health?["error"] == nil && !model.approvalsOn {
            Label("Prompts stay in the terminal. Turn on answering them here in Settings.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        } else if model.missingHooks.isEmpty && model.health?["error"] == nil {
            Label("All set. You can answer prompts from here.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Tone.okText)
        } else {
            HStack(spacing: 8) {
                Label("Setup needs a repair before prompts can show up here.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.warnText)
                Button("Repair setup") { Task { await model.repairHooks() } }.controlSize(.small)
            }
        }
    }
}
