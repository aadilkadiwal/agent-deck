import AppKit
import Charts
import CoreImage
import AgentDeckCore
import SwiftUI

enum DetailsTab: String, CaseIterable, Identifiable {
    case sessions, waiting, usage
    var id: String { rawValue }
}

enum SidebarItem: Hashable {
    case tab(DetailsTab)
    case project(String)
}

struct DetailsView: View {
    let model: AppModel
    @AppStorage("detailsTab") private var tab = DetailsTab.sessions.rawValue
    @State private var project: String?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    private var current: DetailsTab { DetailsTab(rawValue: tab) ?? .sessions }
    private var waitingCount: Int { model.live.filter { $0.state == .blocked && !$0.isLeftover }.count }
    private var hooksNeedRepair: Bool {
        SettingsView.hookKeys.contains { model.health?[$0.0] as? String == "missing" }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(get: { project.map(SidebarItem.project) ?? .tab(current) },
                set: { item in
                    switch item {
                    case .tab(let t): tab = t.rawValue; project = nil
                    case .project(let p): tab = DetailsTab.sessions.rawValue; project = p
                    case nil: break
                    }
                })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                sidebarRow(.tab(.sessions), "All sessions", "list.bullet", trailing: "\(model.live.count + model.closed.count)")
                sidebarRow(.tab(.waiting), "Waiting", "hourglass", trailing: waitingCount > 0 ? "\(waitingCount)" : nil, dot: waitingCount > 0)
                sidebarRow(.tab(.usage), "Usage", "chart.xyaxis.line")
                let projects = Projects.list(model)
                if !projects.isEmpty {
                    Section("Projects") {
                        ForEach(projects) { p in
                            sidebarRow(.project(p.folder), Fmt.folderName(p.folder), "folder",
                                       trailing: "\(p.count)", dot: p.waiting)
                                .help(Fmt.shortPath(p.folder))
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                BannerView(model: model).padding([.horizontal, .top], 12)
                    .animation(Motion.spring(reduced: reduceMotion), value: model.banner?.id)
                Group {
                    switch current {
                    case .sessions: SessionsTab(model: model, search: $search, waitingOnly: false, project: project)
                    case .waiting: SessionsTab(model: model, search: $search, waitingOnly: true, project: nil)
                    case .usage: UsageTab(model: model) { folder in selection.wrappedValue = .project(folder) }
                    }
                }
                .id(project.map { "project:\($0)" } ?? current.rawValue)
                .transition(.opacity)
            }
            .animation(Motion.fast(reduceMotion), value: current)
            .navigationTitle(title)
            .toolbar {
                if current == .sessions || current == .waiting {
                    ToolbarItem(placement: .primaryAction) {
                        TextField("Search  ⌘F", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .focused($searchFocused)
                    }
                }
            }
        }
        .background {
            // No menu bar in a menu bar app, so the usual shortcuts live here.
            Group {
                Button("") { if current != .waiting { tab = DetailsTab.sessions.rawValue }; searchFocused = true }.keyboardShortcut("f")
                Button("") { openSettings(); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut(",")
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            model.detailsOpen = true
            Task { await model.refresh(history: true, agents: true) }
            Task { await model.checkHealth() }
        }
        .onDisappear { model.detailsOpen = false }
        .onChange(of: Projects.list(model).map(\.folder)) { _, folders in
            if let p = project, !folders.contains(p) { project = nil }
        }
    }

    private var title: String {
        if let project { return Fmt.folderName(project) }
        switch current {
        case .sessions: return "Sessions"
        case .waiting: return "Waiting for you"
        case .usage: return "Usage"
        }
    }

    @ViewBuilder private var sidebarFooter: some View {
        if hooksNeedRepair {
            Button {
                UserDefaults.standard.set(SettingsPage.health.rawValue, forKey: SettingsPage.key)
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Hooks need repair", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .help("Open Settings → Health")
        }
    }

    private func sidebarRow(_ item: SidebarItem, _ name: String, _ symbol: String,
                            trailing: String? = nil, dot: Bool = false) -> some View {
        HStack {
            Label(name, systemImage: symbol).lineLimit(1)
            Spacer()
            if dot { Circle().fill(Color.orange).frame(width: 7, height: 7).accessibilityLabel("Waiting for you") }
            if let trailing { Text(trailing).monospacedDigit().foregroundStyle(.secondary) }
        }
        .tag(item)
    }
}

enum Projects {
    struct Entry: Identifiable, Equatable {
        let folder: String
        var count = 0
        var running = false
        var waiting = false
        var lastActive = Date.distantPast
        var id: String { folder }
    }

    @MainActor
    static func list(_ model: AppModel) -> [Entry] {
        var by: [String: Entry] = [:]
        for s in model.live where !s.cwd.isEmpty {
            var e = by[s.cwd] ?? Entry(folder: s.cwd)
            e.count += 1
            e.running = true
            e.waiting = e.waiting || (s.state == .blocked && !s.isLeftover)
            e.lastActive = max(e.lastActive, s.startedAt)
            by[s.cwd] = e
        }
        for h in model.closed where !h.cwd.isEmpty {
            var e = by[h.cwd] ?? Entry(folder: h.cwd)
            e.count += 1
            e.lastActive = max(e.lastActive, h.lastActive)
            by[h.cwd] = e
        }
        return by.values.sorted { ($0.running ? 1 : 0, $0.lastActive, $0.folder) > ($1.running ? 1 : 0, $1.lastActive, $1.folder) }
    }
}

/// One line in the table: a running session, a saved one, or both (running sessions are saved too).
struct SessionRow: Identifiable {
    let id: String
    let live: LiveSession?
    let saved: HistorySession?
    var liveName: String?
    var liveBranch: String?

    var name: String { liveName ?? saved?.name ?? id }
    var folder: String { live?.cwd ?? saved?.cwd ?? "" }
    var shortId: String { String(id.prefix(8)) }
    var lastActive: Date { saved?.lastActive ?? live?.startedAt ?? .distantPast }
    var bytes: Int64 { saved?.bytes ?? 0 }
    var model: String { Fmt.model(saved?.model) }
    var branch: String { liveBranch ?? saved?.branch ?? "" }
    var duration: TimeInterval? { saved?.duration }
    var durationSort: Double { duration ?? -1 }
    var lastPrompt: String? { saved?.lastPrompt.flatMap { $0.isEmpty ? nil : $0 } }
    var promptLine: String? { lastPrompt.flatMap { $0.hasPrefix(name) ? nil : $0 } }
    var isClosed: Bool { live == nil }
    var status: String {
        guard let s = live else { return "Closed" }
        if s.isLeftover { return "Leftover" }
        switch s.state { case .busy: return "Working"; case .idle: return "Idle"; case .blocked: return "Waiting" }
    }
    var statusColor: Color {
        guard let s = live, !s.isLeftover else { return .secondary }
        switch s.state { case .busy: return .green; case .idle: return .secondary; case .blocked: return .orange }
    }
}

enum SessionFilter: String, CaseIterable, Identifiable {
    case all = "All", running = "Running", phone = "On phone", background = "Background", closed = "Closed"
    var id: String { rawValue }
    func matches(_ r: SessionRow) -> Bool {
        switch self {
        case .all: return true
        case .running: return r.live != nil
        case .phone: return r.live?.isOnPhone == true
        case .background: return r.live?.kind == .background
        case .closed: return r.isClosed
        }
    }
}

struct StatusPill: View {
    let row: SessionRow
    var body: some View {
        Text(row.status)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(row.statusColor.opacity(0.18)))
            .foregroundStyle(row.isClosed ? Color.secondary : Color.primary)
            .accessibilityLabel("Status: \(row.status)")
    }
}

struct SessionsTab: View {
    let model: AppModel
    @Binding var search: String
    let waitingOnly: Bool
    let project: String?
    @State private var filter = SessionFilter.all
    @State private var range = ActiveRange.any
    @State private var selection = Set<String>()
    @State private var pendingDelete: [HistorySession]?
    @State private var renaming: SessionRow?
    @State private var sortOrder = [KeyPathComparator(\SessionRow.lastActive, order: .reverse)]
    @State private var sparkle = false
    @SceneStorage("sessionColumns") private var columns = TableColumnCustomization<SessionRow>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allRows: [SessionRow] {
        let saved = Dictionary(model.history.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let live = model.live.map { SessionRow(id: $0.sessionId, live: $0, saved: saved[$0.sessionId], liveName: model.displayName($0),
                                               liveBranch: model.branches[$0.cwd]) }
        let closed = model.closed.map { SessionRow(id: $0.sessionId, live: nil, saved: $0) }
        return live + closed
    }

    private var rows: [SessionRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return allRows
            .filter { project == nil || $0.folder == project }
            .filter { waitingOnly ? $0.live?.state == .blocked && $0.live?.isLeftover == false : filter.matches($0) && range.matches($0.lastActive) }
            .filter { q.isEmpty || [$0.name, $0.folder, $0.id, $0.lastPrompt ?? ""].contains { $0.lowercased().contains(q) } }
            .sorted(using: sortOrder)
    }

    private var visibleClosed: [HistorySession] { rows.filter(\.isClosed).compactMap(\.saved) }
    private var selectedClosed: [HistorySession] { model.closed.filter { selection.contains($0.sessionId) } }
    private var selectedRow: SessionRow? { selection.count == 1 ? allRows.first { selection.contains($0.id) } : nil }

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: 10) {
            if !waitingOnly { controls }
            if waitingOnly && !model.approvals.isEmpty { cards }
            table(rows)
                .frame(minHeight: waitingOnly && !model.approvals.isEmpty ? 120 : nil)
                .overlay { if rows.isEmpty { emptyState } }
        }
        .padding(12)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pendingDelete != nil || renaming != nil || selection.count > 1 {
                bottomBar
                    .font(.system(size: 12))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
                    .padding([.horizontal, .bottom], 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.spring(reduced: reduceMotion), value: selection.count > 1)
        .animation(Motion.spring(reduced: reduceMotion), value: pendingDelete?.map(\.sessionId))
        .animation(Motion.spring(reduced: reduceMotion), value: renaming?.id)
        .inspector(isPresented: Binding(get: { selectedRow != nil }, set: { if !$0 { selection = [] } })) {
            if let r = selectedRow {
                Inspector(row: r, primary: primary(for: r)) { actions(for: r, includeOpen: false) }
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
            }
        }
        .animation(Motion.spring(reduced: reduceMotion), value: selectedRow?.id)
        .onChange(of: model.history.count) { selection.formIntersection(Set(allRows.map(\.id))) }
    }

    private var cards: some View {
        let hotkeyTarget = model.pendingApprovals.first { $0.kind == .permission }?.id
        return ScrollView {
            VStack(spacing: 10) {
                ForEach(model.approvals) {
                    ApprovalCard(model: model, request: $0, hotkeyTarget: $0.id == hotkeyTarget, roomy: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Motion.spring(reduced: reduceMotion), value: model.approvals.map(\.id))
        }
        .layoutPriority(1)
    }

    private var controls: some View {
        let scoped = allRows.filter { project == nil || $0.folder == project }
        return VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(SessionFilter.allCases) { f in Text("\(f.rawValue) \(scoped.filter(f.matches).count)").tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            HStack(spacing: 14) {
                Button("Select all closed (\(visibleClosed.count))") { selection = Set(visibleClosed.map(\.sessionId)) }
                    .controlSize(.small)
                    .disabled(visibleClosed.isEmpty)
                    .help("Selects every closed session in the list. ⌘-click or ⇧-click to adjust, ⌫ to delete.")
                let empty = model.emptySessions.filter { project == nil || $0.cwd == project }
                if !empty.isEmpty {
                    Button { pendingDelete = empty } label: {
                        Label {
                            Text("\(empty.count) empty session\(empty.count == 1 ? "" : "s") · \(Fmt.bytes(empty.reduce(0) { $0 + $1.bytes })) · Clean up")
                        } icon: {
                            Image(systemName: "sparkles").symbolEffect(.bounce, value: sparkle)
                        }
                    }
                    .onAppear { if !reduceMotion { sparkle.toggle() } }
                    .buttonStyle(.bordered).controlSize(.small).tint(.orange)
                    .help("Sessions you opened and closed without a reply from Claude")
                }
                Spacer()
                Picker("Last active", selection: $range) {
                    ForEach(ActiveRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }
            .font(.system(size: 12))
        }
    }

    private func table(_ rows: [SessionRow]) -> some View {
        // Running sessions stay on top whatever the column sort.
        let running = rows.filter { $0.live != nil }, closed = rows.filter(\.isClosed)
        return Table(of: SessionRow.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Status") { r in StatusPill(row: r) }.width(min: 76, ideal: 84)
                .customizationID("status")
            TableColumn("Name", value: \.name) { r in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(highlighted(r.name, search)).lineLimit(1)
                        if r.live?.isOnPhone == true { Image(systemName: "iphone").foregroundStyle(Color.accentColor).help("On your phone") }
                        if r.live?.kind == .background { Pill(text: "BG").help("Background session: it runs without a terminal window") }
                        if let a = r.live?.agent, a != .claude { Pill(text: a.label.uppercased(), color: a == .codex ? .teal : .blue) }
                    }
                    if let p = r.promptLine {
                        Text(highlighted("“\(p)”", search)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help(r.lastPrompt.map { "Last prompt: \($0)" } ?? r.name)
            }
            .width(min: 180, ideal: 280)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Folder", value: \.folder) { r in Text(highlighted(Fmt.shortPath(r.folder), search)).lineLimit(1).help(r.folder) }
                .width(min: 110, ideal: 150)
                .customizationID("folder")
            TableColumn("Branch", value: \.branch) { r in
                Text(r.branch.isEmpty ? "—" : r.branch).lineLimit(1).truncationMode(.middle).foregroundStyle(r.branch.isEmpty ? .tertiary : .primary)
            }
            .width(min: 70, ideal: 110)
            .customizationID("branch")
            TableColumn("Duration", value: \.durationSort) { r in
                Text(r.duration.map(Fmt.duration) ?? "—").monospacedDigit().foregroundStyle(r.duration == nil ? .tertiary : .primary)
                    .help("From the first message to the last")
            }
            .width(min: 60, ideal: 76)
            .customizationID("duration")
            TableColumn("Session ID") { r in Text(r.shortId).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                .width(80)
                .customizationID("sessionId")
                .defaultVisibility(.hidden)
            TableColumn("Model") { r in Text(r.model) }.width(min: 70, ideal: 80)
                .customizationID("model")
                .defaultVisibility(.hidden)
            TableColumn("Last active", value: \.lastActive) { r in Text(Fmt.ago(r.lastActive)) }.width(min: 80, ideal: 90)
                .customizationID("lastActive")
            TableColumn("Size", value: \.bytes) { r in Text(Fmt.bytes(r.bytes)).monospacedDigit() }.width(64)
                .customizationID("size")
            TableColumn("") { r in
                if r.isClosed, let h = r.saved {
                    Button { pendingDelete = [h] } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Delete this session")
                }
            }
            .width(28)
            .customizationID("delete")
            .disabledCustomizationBehavior(.all)
        } rows: {
            if !running.isEmpty {
                Section("Running · \(running.count)") { ForEach(running) { TableRow($0) } }
            }
            if !closed.isEmpty {
                Section("Closed · \(closed.count)") { ForEach(closed) { TableRow($0) } }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count > 1 {
                let picked = model.closed.filter { ids.contains($0.sessionId) }
                Button("Delete \(picked.count) closed session\(picked.count == 1 ? "" : "s")…", role: .destructive) { pendingDelete = picked }
                    .disabled(picked.isEmpty)
            } else if let r = allRows.first(where: { ids.first == $0.id }) {
                actions(for: r, includeOpen: true)
            }
        } primaryAction: { ids in
            if ids.count == 1, let r = allRows.first(where: { ids.first == $0.id }) { open(r) }
        }
        .onDeleteCommand {
            if !selectedClosed.isEmpty { pendingDelete = selectedClosed }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: search)
        } else if waitingOnly {
            ContentUnavailableView("Nothing is waiting for you", systemImage: "checkmark.circle",
                                   description: Text("Sessions that ask for permission, a plan or an answer show up here."))
        } else {
            ContentUnavailableView {
                Label("No sessions", systemImage: "tray")
            } description: {
                Text(filter == .all && range == .any ? "Start one from the menu bar with New session." : "Nothing matches these filters.")
            } actions: {
                if filter != .all || range != .any { Button("Show all") { filter = .all; range = .any } }
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        HStack {
            if let pending = pendingDelete {
                DeleteConfirm(model: model, sessions: pending) { pendingDelete = nil }
            } else if let r = renaming {
                Text("Rename \(r.name):").lineLimit(1)
                RenameField(initial: r.name) { name in
                    renaming = nil
                    guard let name else { return }
                    if let s = r.live { model.rename(s, to: name) } else if let h = r.saved { model.rename(h, to: name) }
                }
                .controlSize(.small)
            } else {
                let picked = selectedClosed
                let runningCount = selection.count - picked.count
                Text("\(selection.count) selected · \(Fmt.bytes(picked.reduce(0) { $0 + $1.bytes }))")
                    .contentTransition(.numericText(value: Double(selection.count)))
                if runningCount > 0 {
                    Text("· \(runningCount) running, kept").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear selection") { selection.removeAll() }
                Button(runningCount > 0 ? "Delete \(picked.count) closed…" : "Delete…", role: .destructive) { pendingDelete = picked }
                    .disabled(picked.isEmpty)
                    .help("Moves the files to the Trash. Running sessions are never deleted. ⌫ in the table does the same.")
            }
        }
    }

    private func primary(for r: SessionRow) -> Inspector<EmptyView>.Primary {
        if let s = r.live {
            return .init(title: s.kind == .interactive || s.agent != .claude ? "Show its window" : "Open in iTerm", symbol: "macwindow") { model.open(s) }
        }
        return .init(title: "Resume in iTerm", symbol: "terminal") { open(r) }
    }

    @ViewBuilder private func actions(for r: SessionRow, includeOpen: Bool) -> some View {
        Button("Rename…") { renaming = r }
            .disabled(r.live.map { $0.agent != .claude || $0.kind == .background || model.typingBlockers[$0.sessionId] != nil } ?? false)
        if let s = r.live, s.agent != .claude {
            if includeOpen { Button("Show its window") { model.open(s) } }
        } else if let s = r.live {
            if includeOpen { Button(s.kind == .interactive ? "Show its window" : "Open in iTerm") { model.open(s) } }
            if s.kind == .interactive {
                Button("Compact context") { model.compact(s) }
                    .disabled(s.state != .idle || model.typingBlockers[s.sessionId] != nil)
            }
            if s.isOnPhone, s.kind == .interactive { Button("Disconnect phone (keep running)") { model.phoneOff(s) } }
            if !s.isOnPhone { Button(s.kind == .interactive ? "Also open on phone" : "Open in iTerm + phone") { model.phoneOn(s) } }
            if let url = s.phoneURL {
                Button("Copy phone link") { copy(url.absoluteString) }
                Button("Open on claude.ai") { NSWorkspace.shared.open(url) }
            }
            Button(s.isLeftover ? "Clear leftover entry" : "Stop") { model.stop(s) }
        } else if let h = r.saved {
            if includeOpen { Button("Resume in iTerm") { model.resumeInTerminal(h) } }
            Button("Delete…", role: .destructive) { pendingDelete = [h] }
            Button("Show file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([h.fileURL]) }
        }
        Button("Copy session ID") { copy(r.id) }
    }

    private func open(_ r: SessionRow) {
        if let s = r.live { model.open(s) } else if let h = r.saved { model.resumeInTerminal(h) }
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct Inspector<Actions: View>: View {
    struct Primary {
        let title: String
        let symbol: String
        let run: () -> Void
    }

    let row: SessionRow
    let primary: Inspector<EmptyView>.Primary
    @ViewBuilder let actions: Actions
    @AppStorage("inspectorPage") private var page = "info"
    @State private var detail: SessionDetail?
    @State private var conversation: Conversation?
    @State private var conversationFor: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    Picker("", selection: $page) {
                        Text("Info").tag("info")
                        Text("Conversation").tag("conversation")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(row.saved == nil)
                    if page == "conversation", row.saved != nil {
                        ConversationView(conversation: conversation, folder: row.folder)
                    } else {
                        info
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: 12))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: row.id) {
                detail = nil
                guard let url = row.saved?.fileURL else { return }
                detail = await Task.detached { SessionDetail.load(url) }.value
            }
            // Keyed on size too, so a running session's conversation reloads as its transcript grows.
            .task(id: "\(row.id)-\(row.bytes)-\(page)") {
                guard page == "conversation", let url = row.saved?.fileURL else { return }
                let id = row.id
                if conversationFor != id { conversation = nil }
                let c = await Task.detached { Conversation.load(url) }.value
                guard !Task.isCancelled else { return }
                let first = conversationFor != id
                conversation = c
                conversationFor = id
                if first { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.name).font(.system(size: 15, weight: .semibold)).lineLimit(2).textSelection(.enabled)
            HStack(spacing: 6) {
                StatusPill(row: row)
                if let s = row.live {
                    Text("\(s.kind == .background ? "Background" : "Terminal") · since \(Fmt.ago(s.startedAt))\(s.isOnPhone ? " · on your phone" : "")")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Button(action: primary.run) { Label(primary.title, systemImage: primary.symbol) }
                    .buttonStyle(.borderedProminent)
                Menu { actions } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderedButton).menuIndicator(.hidden).fixedSize()
                    .help("More actions")
                    .accessibilityLabel("More actions")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var info: some View {
        if let d = detail {
            field("Activity", [d.prompts > 0 ? "\(d.prompts) prompt\(d.prompts == 1 ? "" : "s")" : "no prompts",
                               d.duration.map { "ran \(Fmt.duration($0))" },
                               d.tokens > 0 ? "\(Fmt.tokens(d.tokens)) tokens" : nil].compactMap { $0 }.joined(separator: " · "))
        }
        if let p = row.lastPrompt { field("Last prompt", p, lines: 3) }
        if let reply = detail?.lastReply { field("Last reply", reply, lines: 4) }
        field("Folder", row.folder)
        if !row.branch.isEmpty { field("Branch", row.branch) }
        VStack(alignment: .leading, spacing: 2) {
            Text("Session ID").foregroundStyle(.secondary)
            HStack {
                Text(row.id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button { copy(row.id) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
            }
        }
        if let url = row.live?.phoneURL, let qr = QRCode.image(url.absoluteString) {
            HStack(spacing: 10) {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 84, height: 84)
                Text("Scan to open on your phone").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ label: String, _ value: String, lines: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(lines).textSelection(.enabled)
        }
    }
}

struct ConversationView: View {
    let conversation: Conversation?
    let folder: String

    var body: some View {
        if let c = conversation {
            if c.entries.isEmpty {
                Text("No messages in this session yet.").foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if c.dropped > 0 {
                        Text("\(c.dropped) earlier entr\(c.dropped == 1 ? "y" : "ies") not shown").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    ForEach(c.entries) { entry($0) }
                }
                if !c.files.isEmpty { files(c.files) }
            }
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading the transcript…").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func entry(_ e: Conversation.Entry) -> some View {
        switch e.kind {
        case .prompt, .reply:
            Text(e.text)
                .lineLimit(14)
                .textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(e.kind == .prompt ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
                .help(e.at.map { Fmt.clock($0) } ?? "")
                .accessibilityLabel("\(e.kind == .prompt ? "You" : "Claude"): \(e.text)")
        case .tool:
            Label { Text(e.text).lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: "chevron.right") }
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .labelStyle(TightLabel())
                .padding(.leading, 4)
                .help(e.text)
        case .command:
            Label { Text(e.text).lineLimit(1) } icon: { Image(systemName: "terminal") }
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .labelStyle(TightLabel())
                .padding(.leading, 4)
        }
    }

    private func files(_ files: [Conversation.File]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("FILES CHANGED · \(files.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(files) { f in
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)])
                } label: {
                    HStack(spacing: 6) {
                        Text(f.created ? "A" : "M").foregroundStyle(f.created ? .green : .orange).frame(width: 10)
                        Text(relative(f.path)).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(f.created ? "Created" : "Edited") · \(f.path) · click to show in Finder")
            }
        }
        .padding(.top, 8)
    }

    private func relative(_ path: String) -> String {
        path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : Fmt.shortPath(path)
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 8, weight: .semibold)); configuration.title }
    }
}

enum QRCode {
    static func image(_ text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = f.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

struct UsageTab: View {
    let model: AppModel
    var pick: (String) -> Void = { _ in }
    @AppStorage("usageChartKey") private var chartKey = "five_hour"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let u = model.usage {
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(Array(u.windows.enumerated()), id: \.element.id) { i, w in
                            VStack(spacing: 6) {
                                Ring(percent: w.percent(), size: 84, line: 9, delay: Double(i) * 0.08)
                                Text(w.label).font(.system(size: 13, weight: .semibold))
                                Text(Fmt.resets(w.resetsAt)).font(.system(size: 11)).foregroundStyle(.secondary)
                                if let f = Fmt.forecast(model.forecast(w)) {
                                    Text(f).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center)
                                        .foregroundStyle(model.forecast(w) == .safeUntilReset ? Color.secondary : Color.orange)
                                }
                            }
                            .frame(width: 140)
                        }
                        Spacer(minLength: 0)
                        if !model.codexUsage.isEmpty { codex }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(chartKey == "five_hour" ? "5-hour limit, last 24 hours" : "Weekly limit, last 7 days")
                                .font(.system(size: 13, weight: .semibold))
                            InfoButton(text: "The same numbers /usage shows. They refresh whenever any Claude Code session is active. The dashed orange line is the pace forecast: it compares your usage over the last hour (5-hour limit) or day (weekly) and appears once there are 10 minutes of readings.")
                            Spacer()
                            Picker("", selection: $chartKey) {
                                Text("5-hour").tag("five_hour")
                                Text("Weekly").tag("seven_day")
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        UsageChart(window: u.window(chartKey), samples: model.samples, key: chartKey,
                                   span: chartKey == "five_hour" ? 24 * 3600 : 7 * 24 * 3600,
                                   forecast: u.window(chartKey).map(model.forecast) ?? .unknown)
                            .id(chartKey)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))

                    UsageHeatmapView(samples: model.samples)

                    ProjectUsageView(model: model, pick: pick)

                    Text("Updated \(Fmt.ago(u.updatedAt))\(u.model.map { " · \($0)" } ?? "")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("No usage numbers yet", systemImage: "chart.xyaxis.line",
                                           description: Text("Send a message in any Claude Code session and they'll appear here. If they still don't, re-run the installer so the status line hook is set up."))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var codex: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex").font(.system(size: 13, weight: .semibold))
            ForEach(model.codexUsage) { l in
                HStack(spacing: 8) {
                    Ring(percent: l.percent, size: 28, line: 4)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(l.label).font(.system(size: 12, weight: .medium))
                        Text(Fmt.resets(l.resetsAt)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }
}

struct ProjectUsageView: View {
    let model: AppModel
    let pick: (String) -> Void
    @AppStorage("projectUsageSpan") private var span = "five_hour"
    @State private var entries: [ProjectUsage.Entry]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let shown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(span == "five_hour" ? "Tokens by project, last 5 hours" : "Tokens by project, last 7 days")
                    .font(.system(size: 13, weight: .semibold))
                InfoButton(text: "Input, output and cache-write tokens read from transcripts. Click a project to see its sessions.")
                Spacer()
                Picker("", selection: $span) {
                    Text("5 hours").tag("five_hour")
                    Text("7 days").tag("seven_day")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if let entries {
                if entries.isEmpty {
                    Text("No Claude Code replies in this period.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    let most = Double(entries[0].tokens)
                    ForEach(entries.prefix(Self.shown)) { e in bar(e, share: Double(e.tokens) / most) }
                    if entries.count > Self.shown {
                        Text("and \(entries.count - Self.shown) more").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .task(id: span) {
            entries = nil
            let since = Date().addingTimeInterval(span == "five_hour" ? -5 * 3600 : -7 * 86400)
            let e = await model.projectUsage(since: since)
            withAnimation(Motion.spring(reduced: reduceMotion)) { entries = e }
        }
    }

    private func bar(_ e: ProjectUsage.Entry, share: Double) -> some View {
        Button { pick(e.folder) } label: {
            HStack(spacing: 10) {
                Text(Fmt.folderName(e.folder)).lineLimit(1).truncationMode(.middle)
                    .frame(width: 150, alignment: .leading)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(3, g.size.width * share))
                        .frame(maxHeight: .infinity)
                }
                .frame(height: 14)
                Text(Fmt.tokens(e.tokens)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("Show sessions in \(Fmt.shortPath(e.folder))")
        .accessibilityLabel("\(Fmt.folderName(e.folder)), \(Fmt.tokens(e.tokens)) tokens")
    }
}

struct UsageChart: View {
    let window: LimitWindow?
    let samples: [UsageSample]
    let key: String
    let span: TimeInterval
    let forecast: Forecast
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Point: Identifiable {
        let at: Date
        let percent: Double
        var id: Date { at }
    }

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-span)
        var points = samples.filter { $0.key == key && $0.at >= start }.sorted { $0.at < $1.at }.map { Point(at: $0.at, percent: $0.percent) }
        // Carry the latest value up to now (readings are only logged when they change).
        if let w = window, !points.isEmpty { points.append(Point(at: now, percent: w.percent(at: now))) }
        let resets = Set(samples.filter { $0.key == key }.compactMap(\.resetsAt)).filter { $0 > start && $0 <= now }.sorted()
        let eta: Date? = if case .reachesLimit(let at) = forecast, at > now { at } else { nil }

        return Group {
            if points.count < 2 {
                ContentUnavailableView("Not enough readings yet", systemImage: "chart.xyaxis.line",
                                       description: Text("The chart fills in as Claude Code sends usage numbers."))
                    .frame(height: 220)
            } else {
                Chart {
                    RuleMark(y: .value("Alert", 95)).foregroundStyle(.red.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("95%").font(.system(size: 10)).foregroundStyle(.secondary) }
                    RuleMark(y: .value("Alert", 80)).foregroundStyle(.orange.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("80%").font(.system(size: 10)).foregroundStyle(.secondary) }
                    ForEach(resets, id: \.self) { r in
                        RuleMark(x: .value("Reset", r)).foregroundStyle(.secondary.opacity(0.3))
                            .annotation(position: .top) { Text("reset").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    ForEach(points) { p in
                        AreaMark(x: .value("Time", p.at), y: .value("Used", p.percent))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(Color.accentColor.opacity(0.12))
                        LineMark(x: .value("Time", p.at), y: .value("Used", p.percent), series: .value("Series", "Used"))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(Color.accentColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let eta, let last = points.last {
                        ForEach([(last.at, last.percent), (eta, 100.0)], id: \.0) { at, pct in
                            LineMark(x: .value("Time", at), y: .value("Used", pct), series: .value("Series", "Pace"))
                                .foregroundStyle(Color.orange)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                        PointMark(x: .value("Time", eta), y: .value("Used", 100))
                            .foregroundStyle(Color.orange)
                            .annotation(position: .leading) {
                                Text("100% at \(Fmt.clock(eta))").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                            }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: start...max(now, eta ?? now))
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine()
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%") } }
                } }
                .frame(height: 220)
                .mask {
                    GeometryReader { g in
                        Rectangle().frame(width: revealed ? g.size.width : 0).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onAppear {
                    if reduceMotion { revealed = true } else { withAnimation(.easeOut(duration: 0.6)) { revealed = true } }
                }
                .accessibilityLabel("\(key == "five_hour" ? "5-hour" : "Weekly") usage over time, now \(Int(points.last?.percent ?? 0)) percent")
            }
        }
    }
}


struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(text)
            .accessibilityLabel("About this")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading).padding(12)
            }
    }
}

struct UsageHeatmapView: View {
    let samples: [UsageSample]

    var body: some View {
        let m = UsageHeatmap.compute(samples)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("When you use the most, last 7 days").font(.system(size: 13, weight: .semibold))
                InfoButton(text: "Each square is one hour. The darker it is, the more your 5-hour limit went up in that hour. It fills in from the usage readings Agent Deck saves while Claude Code runs. A rise between readings more than two hours apart is left out, since it can't be placed in one hour.")
                Spacer()
            }
            if m.peak <= 0 {
                Text("Not enough readings yet. This fills in as you use Claude Code.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow {
                        Text("")
                        ForEach(0..<24, id: \.self) { h in
                            Text(h % 6 == 0 ? "\(h)" : "").font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(0..<7, id: \.self) { d in
                        GridRow {
                            Text(m.weekdaySymbols[d]).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                            ForEach(0..<24, id: \.self) { h in
                                let v = m.cells[d][h]
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(v > 0 ? Color.accentColor.opacity(0.15 + 0.85 * v / m.peak) : Color.secondary.opacity(0.08))
                                    .frame(height: 14)
                                    .help(v > 0 ? "\(m.weekdaySymbols[d]) \(h):00 · +\(Int(v.rounded())) points" : "")
                            }
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary(m))
                Text(summary(m)).font(.system(size: 12)).foregroundStyle(m.limitHits > 0 ? Color.orange : .secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func summary(_ m: UsageHeatmap) -> String {
        let busiest = m.busiest.map { "Busiest: \($0.day) \(hour($0.from))–\(hour($0.to))." } ?? ""
        let hits = m.limitHits > 0 ? " You reached the 5-hour limit \(m.limitHits) time\(m.limitHits == 1 ? "" : "s")." : ""
        return busiest + hits
    }

    private func hour(_ h: Int) -> String {
        var c = DateComponents()
        c.hour = h % 24
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return Calendar.current.date(from: c).map(f.string(from:)) ?? "\(h)"
    }
}
