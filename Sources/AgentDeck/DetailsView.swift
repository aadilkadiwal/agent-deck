import AppKit
import Charts
import CoreImage
import AgentDeckCore
import SwiftUI

enum DetailsTab: String, CaseIterable, Identifiable {
    case sessions, waiting, usage, settings
    var id: String { rawValue }
}

struct DetailsView: View {
    let model: AppModel
    @AppStorage("detailsTab") private var tab = DetailsTab.sessions.rawValue
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: DetailsTab { DetailsTab(rawValue: tab) ?? .sessions }
    private var waitingCount: Int { model.live.filter { $0.state == .blocked && !$0.isLeftover }.count }
    private var hooksNeedRepair: Bool {
        SettingsTab.hookKeys.contains { model.health?[$0.0] as? String == "missing" }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { current }, set: { if let t = $0 { tab = t.rawValue } })) {
                sidebarRow(.sessions, "Sessions", "list.bullet", trailing: "\(model.live.count + model.closed.count)")
                sidebarRow(.waiting, "Waiting", "hourglass", trailing: waitingCount > 0 ? "\(waitingCount)" : nil, dot: waitingCount > 0)
                sidebarRow(.usage, "Usage", "chart.xyaxis.line")
                sidebarRow(.settings, "Settings", "gearshape", warn: hooksNeedRepair)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            VStack(spacing: 0) {
                BannerView(model: model).padding([.horizontal, .top], 12)
                    .animation(Motion.spring(reduced: reduceMotion), value: model.banner?.id)
                Group {
                    switch current {
                    case .sessions: SessionsTab(model: model, search: $search, waitingOnly: false)
                    case .waiting: SessionsTab(model: model, search: $search, waitingOnly: true)
                    case .usage: UsageTab(model: model)
                    case .settings: SettingsTab(model: model)
                    }
                }
                .id(current)
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
                Button("") { tab = DetailsTab.settings.rawValue }.keyboardShortcut(",")
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
    }

    private var title: String {
        switch current {
        case .sessions: "Sessions"
        case .waiting: "Waiting for you"
        case .usage: "Usage"
        case .settings: "Settings"
        }
    }

    private func sidebarRow(_ t: DetailsTab, _ name: String, _ symbol: String,
                            trailing: String? = nil, dot: Bool = false, warn: Bool = false) -> some View {
        HStack {
            Label(name, systemImage: symbol)
            Spacer()
            if dot { Circle().fill(Color.orange).frame(width: 7, height: 7) }
            if let trailing { Text(trailing).monospacedDigit().foregroundStyle(.secondary) }
            if warn {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .help("A hook needs repair")
                    .accessibilityLabel("A hook needs repair")
            }
        }
        .tag(t)
    }
}

/// One line in the table: a running session, a saved one, or both (running sessions are saved too).
struct SessionRow: Identifiable {
    let id: String
    let live: LiveSession?
    let saved: HistorySession?
    var liveName: String?

    var name: String { liveName ?? saved?.name ?? id }
    var folder: String { live?.cwd ?? saved?.cwd ?? "" }
    var shortId: String { String(id.prefix(8)) }
    var lastActive: Date { saved?.lastActive ?? live?.startedAt ?? .distantPast }
    var bytes: Int64 { saved?.bytes ?? 0 }
    var model: String { Fmt.model(saved?.model) }
    var isClosed: Bool { live == nil }
    var status: String {
        guard let s = live else { return "Closed" }
        if s.isLeftover { return "Leftover" }
        switch s.state { case .busy: return "Working"; case .idle: return "Idle"; case .blocked: return "Waiting" }
    }
    var statusColor: Color {
        guard let s = live, !s.isLeftover else { return .secondary }
        switch s.state { case .busy: return .green; case .idle: return .accentColor; case .blocked: return .orange }
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
    @State private var filter = SessionFilter.all
    @State private var range = ActiveRange.any
    @State private var selection = Set<String>()
    @State private var checked = Set<String>()
    @State private var pendingDelete: [HistorySession]?
    @State private var renaming: SessionRow?
    @State private var sortOrder = [KeyPathComparator(\SessionRow.lastActive, order: .reverse)]
    @State private var sparkle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allRows: [SessionRow] {
        let saved = Dictionary(model.history.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let live = model.live.map { SessionRow(id: $0.sessionId, live: $0, saved: saved[$0.sessionId], liveName: model.displayName($0)) }
        let closed = model.closed.map { SessionRow(id: $0.sessionId, live: nil, saved: $0) }
        return live + closed
    }

    private var rows: [SessionRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return allRows
            .filter { waitingOnly ? $0.live?.state == .blocked && $0.live?.isLeftover == false : filter.matches($0) && range.matches($0.lastActive) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.folder.lowercased().contains(q) || $0.id.hasPrefix(q) }
            .sorted(using: sortOrder)
    }

    private var visibleClosed: [HistorySession] { rows.filter(\.isClosed).compactMap(\.saved) }
    private var checkedSessions: [HistorySession] { model.closed.filter { checked.contains($0.sessionId) } }
    private var selectedRow: SessionRow? { selection.count == 1 ? allRows.first { selection.contains($0.id) } : nil }

    private var allVisibleChecked: Binding<Bool> {
        Binding(
            get: { !visibleClosed.isEmpty && visibleClosed.allSatisfy { checked.contains($0.sessionId) } },
            set: { on in
                let ids = Set(visibleClosed.map(\.sessionId))
                if on { checked.formUnion(ids) } else { checked.subtract(ids) }
            })
    }

    private func isChecked(_ id: String) -> Binding<Bool> {
        Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } })
    }

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: 10) {
            if !waitingOnly { controls }
            table(rows)
                .overlay { if rows.isEmpty { emptyState } }
        }
        .padding(12)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pendingDelete != nil || renaming != nil || !checkedSessions.isEmpty {
                bottomBar
                    .font(.system(size: 12))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
                    .padding([.horizontal, .bottom], 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.spring(reduced: reduceMotion), value: checked)
        .animation(Motion.spring(reduced: reduceMotion), value: pendingDelete?.map(\.sessionId))
        .animation(Motion.spring(reduced: reduceMotion), value: renaming?.id)
        .inspector(isPresented: Binding(get: { selectedRow != nil }, set: { if !$0 { selection = [] } })) {
            if let r = selectedRow {
                Inspector(row: r) { actions(for: r) }
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
            }
        }
        .animation(Motion.spring(reduced: reduceMotion), value: selectedRow?.id)
        // Forget ticks for sessions that no longer exist (deleted here or by Claude Code's cleanup).
        .onChange(of: model.history.count) { checked.formIntersection(Set(model.closed.map(\.sessionId))) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(SessionFilter.allCases) { f in Text("\(f.rawValue) \(allRows.filter(f.matches).count)").tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            HStack(spacing: 14) {
                Toggle("Select all closed (\(visibleClosed.count))", isOn: allVisibleChecked)
                    .toggleStyle(.checkbox)
                    .disabled(visibleClosed.isEmpty)
                let empty = model.emptySessions
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
        return Table(of: SessionRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { r in
                if r.isClosed {
                    Toggle("", isOn: isChecked(r.id)).toggleStyle(.checkbox).labelsHidden()
                }
            }.width(22)
            TableColumn("Status") { r in StatusPill(row: r) }.width(min: 76, ideal: 84)
            TableColumn("Name", value: \.name) { r in
                HStack(spacing: 4) {
                    Text(highlighted(r.name, search)).lineLimit(1).help(r.saved?.lastPrompt.map { "Last prompt: \($0)" } ?? r.name)
                    if r.live?.isOnPhone == true { Image(systemName: "iphone").foregroundStyle(Color.accentColor).help("On your phone") }
                    if r.live?.kind == .background { Pill(text: "BG") }
                    if let a = r.live?.agent, a != .claude { Pill(text: a.label.uppercased(), color: a == .codex ? .teal : .blue) }
                }
            }.width(min: 150, ideal: 200)
            TableColumn("Folder", value: \.folder) { r in Text(highlighted(Fmt.shortPath(r.folder), search)).lineLimit(1).help(r.folder) }
                .width(min: 110, ideal: 160)
            TableColumn("Session ID") { r in Text(r.shortId).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                .width(80)
            TableColumn("Model") { r in Text(r.model) }.width(min: 70, ideal: 80)
            TableColumn("Last active", value: \.lastActive) { r in Text(Fmt.ago(r.lastActive)) }.width(min: 80, ideal: 90)
            TableColumn("Size", value: \.bytes) { r in Text(Fmt.bytes(r.bytes)).monospacedDigit() }.width(64)
            TableColumn("") { r in
                if r.isClosed, let h = r.saved {
                    Button { pendingDelete = [h] } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Delete this session")
                }
            }.width(28)
        } rows: {
            if !running.isEmpty {
                Section("Running · \(running.count)") { ForEach(running) { TableRow($0) } }
            }
            if !closed.isEmpty {
                Section("Closed · \(closed.count)") { ForEach(closed) { TableRow($0) } }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let r = allRows.first(where: { ids.first == $0.id }) { actions(for: r) }
        } primaryAction: { ids in
            if let r = allRows.first(where: { ids.first == $0.id }) { open(r) }
        }
        .onDeleteCommand {
            let picked = checkedSessions.isEmpty ? model.closed.filter { selection.contains($0.sessionId) } : checkedSessions
            if !picked.isEmpty { pendingDelete = picked }
        }
        .onKeyPress(.space) {
            let ids = selection.filter { id in model.closed.contains { $0.sessionId == id } }
            guard !ids.isEmpty else { return .ignored }
            if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
            return .handled
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
                let picked = checkedSessions
                Text("\(picked.count) checked · \(Fmt.bytes(picked.reduce(0) { $0 + $1.bytes }))")
                    .contentTransition(.numericText(value: Double(picked.count)))
                Spacer()
                Button("Clear") { checked.removeAll() }
                Button("Delete…", role: .destructive) { pendingDelete = picked }
                    .help("Moves the files to the Trash. Running sessions can't be ticked.")
            }
        }
    }

    @ViewBuilder private func actions(for r: SessionRow) -> some View {
        Button("Rename…") { renaming = r }
            .disabled(r.live.map { $0.agent != .claude || $0.kind == .background || model.typingBlockers[$0.sessionId] != nil } ?? false)
        if let s = r.live, s.agent != .claude {
            Button("Show its window") { model.open(s) }
        } else if let s = r.live {
            Button(s.kind == .interactive ? "Show its window" : "Open in iTerm") { model.open(s) }
            if s.isOnPhone, s.kind == .interactive { Button("Disconnect phone (keep running)") { model.phoneOff(s) } }
            if !s.isOnPhone { Button(s.kind == .interactive ? "Also open on phone" : "Open in iTerm + phone") { model.phoneOn(s) } }
            if let url = s.phoneURL {
                Button("Copy phone link") { copy(url.absoluteString) }
                Button("Open on claude.ai") { NSWorkspace.shared.open(url) }
            }
            Button(s.isLeftover ? "Clear leftover entry" : "Stop") { model.stop(s) }
        } else if let h = r.saved {
            Button("Resume in iTerm") { model.resumeInTerminal(h) }
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
    let row: SessionRow
    @ViewBuilder let actions: Actions
    @State private var detail: SessionDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.system(size: 15, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 6) {
                        StatusPill(row: row)
                        if let s = row.live {
                            Text("\(s.kind == .background ? "Background" : "Terminal") · since \(Fmt.ago(s.startedAt))\(s.isOnPhone ? " · on your phone" : "")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let d = detail {
                    field("Activity", [d.prompts > 0 ? "\(d.prompts) prompt\(d.prompts == 1 ? "" : "s")" : "no prompts",
                                       d.duration.map { "ran \(Fmt.duration($0))" },
                                       d.tokens > 0 ? "\(Fmt.tokens(d.tokens)) tokens" : nil].compactMap { $0 }.joined(separator: " · "))
                }
                if let p = row.saved?.lastPrompt { field("Last prompt", p, lines: 3) }
                if let reply = detail?.lastReply { field("Last reply", reply, lines: 4) }
                field("Folder", row.folder)
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
                VStack(alignment: .leading, spacing: 6) { actions }
                    .buttonStyle(.bordered).controlSize(.small)
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
    }

    private func field(_ label: String, _ value: String, lines: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(lines).textSelection(.enabled)
        }
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

                    Text("Updated \(Fmt.ago(u.updatedAt))\(u.model.map { " · \($0)" } ?? ""). These are the same numbers /usage shows. They refresh whenever any Claude Code session is active.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("The pace line compares your usage over the last hour (5-hour limit) or day (weekly) and appears once there are 10 minutes of readings.")
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

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", notifications = "Notifications", storage = "Storage", health = "Health"
    var id: String { rawValue }
}

struct SettingsTab: View {
    let model: AppModel
    @AppStorage("barStyle") private var barStyle = BarStyle.closest.rawValue
    @AppStorage(Notifier.Key.waiting) private var notifyWaiting = true
    @AppStorage(Notifier.Key.finished) private var notifyFinished = true
    @AppStorage(Notifier.Key.limits) private var notifyLimits = true
    @AppStorage("settingsPage") private var page = SettingsPage.general.rawValue
    @StateObject private var updater = Updater()
    @State private var cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var confirmCleanup = false
    @AppStorage("autoCleanLeftovers") private var autoCleanLeftovers = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var old: [HistorySession] { model.closed.filter { $0.lastActive < cutoff } }
    static let hookKeys = [("claude", "Claude Code hooks"), ("codex", "Codex hooks"), ("gemini", "Gemini CLI hooks"), ("statusLine", "Status line (usage numbers)")]

    private func healthRow(_ title: String, _ state: String?) -> some View {
        LabeledContent(title) {
            Group {
                switch state {
                case "ok": Label("Working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case "missing": Label("Not set up", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case "absent": Text("Not installed").foregroundStyle(.secondary)
                default: ProgressView().controlSize(.small)
                }
            }
            .transition(.opacity)
            .animation(Motion.fast(reduceMotion), value: state)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            healthSummary.padding([.horizontal, .top], 20)
            Picker("", selection: $page) {
                ForEach(SettingsPage.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.top, 12)
            Form {
                switch SettingsPage(rawValue: page) ?? .general {
                case .general: general
                case .notifications: notifications
                case .storage: storage
                case .health: health
                }
            }
            .formStyle(.grouped)
            .id(page)
            .transition(.opacity)
        }
        .animation(Motion.fast(reduceMotion), value: page)
        .onAppear { updater.check() }
        .task { await model.checkHealth() }
        .task { await model.refreshStorage() }
    }

    @ViewBuilder private var healthSummary: some View {
        let missing = Self.hookKeys.filter { model.health?[$0.0] as? String == "missing" }
        HStack(spacing: 8) {
            if model.health == nil {
                ProgressView().controlSize(.small)
                Text("Checking hooks…").foregroundStyle(.secondary)
            } else if model.health?["error"] != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't run the hook check (python3 missing?)")
            } else if missing.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("All hooks working")
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(missing.count) need\(missing.count == 1 ? "s" : "") repair: \(missing.map(\.1).joined(separator: ", "))").lineLimit(1)
                Spacer()
                Button("Repair hooks") { Task { await model.repairHooks() } }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill((missing.isEmpty ? Color.green : Color.orange).opacity(model.health == nil ? 0 : 0.1)))
        .animation(Motion.fast(reduceMotion), value: missing.count)
    }

    @ViewBuilder private var general: some View {
        Section {
            Picker("Keep session history for", selection: Binding(get: { model.retentionDays }, set: { model.setRetention($0) })) {
                ForEach(Retention.choices(current: model.retentionDays), id: \.self) { d in
                    Text(Retention.label(d)).tag(d)
                }
            }
            .pickerStyle(.segmented)
            Text("Claude Code deletes saved sessions older than this on its own (setting: cleanupPeriodDays). 30 days is the most Agent Deck offers.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } header: { Text("History") }

        Section {
            Toggle("Answer Claude's prompts from Agent Deck", isOn: Binding(get: { model.approvalsOn }, set: { model.setApprovals($0) }))
        } header: { Text("Prompts") } footer: {
            Text("Permission prompts, questions and plans show up in the menu and as notifications with Allow / Deny buttons. ⌃⌥A allows and ⌃⌥D denies the oldest permission prompt from any app, only while one is waiting. The prompt stays in the terminal too: whichever you answer first wins. \"Always allow\" saves the rule Claude Code itself suggests. Off: Claude Code asks only in the terminal.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        Section {
            Picker("Menu bar shows", selection: $barStyle) {
                ForEach(BarStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
        } header: { Text("App") }

        Section {
            HStack {
                Text(updater.status)
                Spacer()
                if updater.updatesAvailable > 0 {
                    Button("Update now") { updater.update() }.buttonStyle(.borderedProminent).disabled(updater.busy)
                } else {
                    Button("Check for updates") { updater.check() }.disabled(updater.busy)
                }
            }
        } header: { Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")") }
    }

    @ViewBuilder private var notifications: some View {
        Section {
            Toggle("A session is waiting for your answer", isOn: $notifyWaiting)
            Toggle("A session finishes a task that took over a minute", isOn: $notifyFinished)
            Toggle("A usage limit passes 80% and 95%", isOn: $notifyLimits)
        } header: { Text("Notify me when") } footer: {
            Text("If your notch app already announces sessions, switch the first two off here to avoid double alerts.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var storage: some View {
        Section {
            if let st = model.storage {
                StorageBar(parts: [("Conversations", st.conversations, .blue), ("Scratchpads", st.scratchpads, .purple), ("Undo backups", st.undoBackups, .teal)])
                HStack {
                    Text(st.orphans.isEmpty ? "No leftovers from deleted sessions"
                         : "\(st.orphans.count) leftover\(st.orphans.count == 1 ? "" : "s") from deleted sessions · \(Fmt.bytes(st.orphanBytes))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clean up leftovers") { Task { await model.cleanLeftovers() } }.disabled(st.orphans.isEmpty)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
            }
            Toggle("Clean up leftovers automatically once a day", isOn: $autoCleanLeftovers)
        } header: { Text("Claude storage") } footer: {
            Text("Leftovers are scratchpads, undo backups and other files Claude Code keeps per session, whose session was deleted or expired. Anything used in the last day is kept. They go to the Trash.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        Section {
            DatePicker("Delete closed sessions last used before", selection: $cutoff, displayedComponents: .date)
            HStack {
                Text("\(old.count) session\(old.count == 1 ? "" : "s") · \(Fmt.bytes(old.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(old.count)))
                    .animation(Motion.fast(reduceMotion), value: old.count)
                Spacer()
                if confirmCleanup {
                    Text("Move them to the Trash?")
                    Button("Cancel") { confirmCleanup = false }
                    Button("Delete", role: .destructive) { model.delete(old); confirmCleanup = false }
                } else {
                    Button("Clean up…", role: .destructive) { confirmCleanup = true }.disabled(old.isEmpty)
                }
            }
        } header: { Text("Clean up now") } footer: {
            Text("This frees space on your Mac. Sessions listed on claude.ai or in the phone app are kept on Anthropic's servers and aren't affected.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var health: some View {
        Section {
            ForEach(Self.hookKeys, id: \.0) { key, title in healthRow(title, model.health?[key] as? String) }
            HStack {
                if model.health?["error"] != nil { Text("Couldn't run the check (python3 missing?)").foregroundStyle(.orange) }
                Spacer()
                Button("Repair hooks") { Task { await model.repairHooks() } }
            }
        } header: { Text("Health") } footer: {
            Text("Repair puts Agent Deck's hooks back without touching your own. Codex runs a new hook only after you approve it once: open Codex and type /hooks. A missing status line comes back by running install.sh again.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        Section {
            LabeledContent("Usage snapshot", value: FileManager.default.fileExists(atPath: model.paths.statusFile.path)
                           ? "received \(model.usage.map { Fmt.ago($0.updatedAt) } ?? "—")" : "not received yet")
            LabeledContent("claude command", value: model.cli?.executable.path ?? "not found")
        } header: { Text("Status") }
    }
}

struct StorageBar: View {
    let parts: [(name: String, bytes: Int64, color: Color)]

    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.bytes }, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.name) { p in
                        Rectangle().fill(p.color.gradient)
                            .frame(width: max(p.bytes > 0 ? 3 : 0, (g.size.width - 4) * CGFloat(p.bytes) / CGFloat(total)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 12)
            HStack(spacing: 16) {
                ForEach(parts, id: \.name) { p in
                    HStack(spacing: 5) {
                        Circle().fill(p.color).frame(width: 8, height: 8)
                        Text(p.name)
                        Text(Fmt.bytes(p.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 11))
        }
        .accessibilityElement(children: .combine)
    }
}

enum Retention {
    static let presets = [7, 14, 30]
    static func choices(current: Int) -> [Int] { presets.contains(current) || current > 30 ? presets : (presets + [current]).sorted() }
    static func label(_ d: Int) -> String { d == 7 ? "1 week" : d == 14 ? "2 weeks" : "\(d) days" }
}

enum BarStyle: String, CaseIterable, Identifiable {
    case closest, ringOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .closest: return "Closest limit · running sessions"
        case .ringOnly: return "Ring only"
        }
    }
}
