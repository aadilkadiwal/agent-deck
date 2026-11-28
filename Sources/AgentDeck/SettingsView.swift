import AgentDeckCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", notifications = "Alerts", shortcuts = "Shortcuts", storage = "Storage", health = "Health"
    var id: String { rawValue }
    static let key = "settingsPage"

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell"
        case .shortcuts: "keyboard"
        case .storage: "internaldrive"
        case .health: "stethoscope"
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    @AppStorage("barStyle") private var barStyle = BarStyle.closest.rawValue
    @AppStorage(TerminalApp.key) private var terminalApp = TerminalApp.iterm.rawValue
    @AppStorage(AppModel.keepAwakeKey) private var keepAwake = false
    @AppStorage(AppModel.statusKey) private var checkStatus = true
    @AppStorage(Notifier.Key.waiting) private var notifyWaiting = true
    @AppStorage(Notifier.Key.finished) private var notifyFinished = true
    @AppStorage(Notifier.Key.limits) private var notifyLimits = true
    @AppStorage(PeekPlacement.key) private var peekPlacement = PeekPlacement.automatic.rawValue
    @AppStorage(SettingsPage.key) private var page = SettingsPage.general.rawValue
    @AppStorage(Notifier.Key.warnAt) private var warnLevel = 80.0
    @AppStorage(MenuHotkey.key) private var menuHotkey = MenuHotkey.off.rawValue
    @StateObject private var updater = Updater()
    @State private var cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var confirmCleanup = false
    @AppStorage("autoCleanLeftovers") private var autoCleanLeftovers = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var old: [HistorySession] { model.closed.filter { $0.lastActive < cutoff } }
    private var hooksBroken: Bool {
        model.health?["error"] != nil || Self.hookKeys.contains { model.health?[$0.0] as? String == "missing" }
    }
    static let hookKeys = [("claude", "Claude Code hooks"), ("statusLine", "Status line (usage numbers)")]

    private func healthRow(_ title: String, _ state: String?) -> some View {
        LabeledContent(title) {
            Group {
                switch state {
                case "ok": Label("Working", systemImage: "checkmark.circle.fill").foregroundStyle(Tone.okText)
                case "missing": Label("Not set up", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.warnText)
                case "absent": Text("Not installed").foregroundStyle(.secondary)
                default: ProgressView().controlSize(.small)
                }
            }
            .transition(.opacity)
            .animation(Motion.fast(reduceMotion), value: state)
        }
    }

    var body: some View {
        TabView(selection: Binding(get: { SettingsPage(rawValue: page) ?? .general }, set: { page = $0.rawValue })) {
            ForEach(SettingsPage.allCases) { p in
                VStack(spacing: 0) {
                    if hooksBroken && (p == .health || p == .general) { healthSummary.padding([.horizontal, .top], 20) }
                    Form {
                        switch p {
                        case .general: general
                        case .notifications: notifications
                        case .shortcuts: shortcuts
                        case .storage: storage
                        case .health: health
                        }
                    }
                    .formStyle(.grouped)
                }
                .tabItem { Label(p.rawValue, systemImage: p.symbol) }
                .tag(p)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .onAppear { updater.check() }
        .task { await model.checkHealth() }
        .task { await model.refreshStorage() }
    }

    @ViewBuilder private var shortcuts: some View {
        Section {
            Picker("Open the menu from any app", selection: Binding(get: { MenuHotkey(rawValue: menuHotkey) ?? .off },
                                                                     set: { menuHotkey = $0.rawValue; model.setMenuHotkey($0) })) {
                ForEach(MenuHotkey.allCases) { Text($0.title).tag($0) }
            }
            if model.menuHotkeyFailed {
                Label("Another app already uses \((MenuHotkey(rawValue: menuHotkey) ?? .off).title), so it does nothing here. Pick a different one.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Tone.warnText)
            }
        } header: { Text("Menu") } footer: {
            Note("Opens the menu with the newest prompt selected, so ⌘⏎ answers it and Esc closes it. Heads up: ⌃⌥Space also switches keyboard languages if you use more than one.")
        }
        Section {
            LabeledContent("Allow the oldest permission prompt") { Keys("⌃⌥A") }
            LabeledContent("Deny the oldest permission prompt") { Keys("⌃⌥D") }
            LabeledContent("Show the session that has waited longest") { Keys("⌃⌥J") }
        } header: { Text("Prompts") } footer: {
            Note("They work only while something is waiting, so other apps keep these keys the rest of the time. Risky commands always need a click.")
        }
        Section {
            LabeledContent("Move, then open") { Keys("↑ ↓", "⏎") }
            LabeledContent("Everything you can do with the selected row") { Keys("⌘K") }
            LabeledContent("Allow or deny the selected prompt") { Keys("⌘⏎", "⌘⌫") }
            LabeledContent("Reply to the selected session") { Keys("M") }
            LabeledContent("Stop the selected session") { Keys("⌘.") }
            LabeledContent("Running or Recent") { Keys("⌘1", "⌘2") }
            LabeledContent("Search, refresh, new session") { Keys("⌘F", "⌘R", "⌘N") }
        } header: { Text("In the dropdown") }
        Section {
            LabeledContent("Search sessions") { Keys("⌘F") }
            LabeledContent("Open or resume the selected session") { Keys("⏎") }
            LabeledContent("Show or hide the side panel") { Keys("Space") }
            LabeledContent("Delete the selected closed sessions") { Keys("⌫") }
        } header: { Text("In the Details window") }
    }

    @ViewBuilder private var healthSummary: some View {
        let missing = Self.hookKeys.filter { model.health?[$0.0] as? String == "missing" }
        Callout(tint: model.health == nil ? .clear : missing.isEmpty && model.health?["error"] == nil ? .green : .orange) {
            if model.health == nil {
                ProgressView().controlSize(.small)
                Text("Checking hooks…").foregroundStyle(.secondary)
            } else if model.health?["error"] != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't check the hooks. Is python3 installed?")
            } else if missing.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("All hooks working")
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Needs a repair: \(missing.map(\.1).joined(separator: ", "))").lineLimit(1)
                Spacer()
                Button("Repair setup") { Task { await model.repairHooks() } }.controlSize(.small)
            }
            if missing.isEmpty || model.health?["error"] != nil { Spacer(minLength: 0) }
        }
        .font(.callout)
        .animation(Motion.fast(reduceMotion), value: missing.count)
    }

    @ViewBuilder private var general: some View {
        Section {
            Toggle("Answer Claude's prompts from Agent Deck", isOn: Binding(get: { model.approvalsOn }, set: { model.setApprovals($0) }))
        } header: { Text("Prompts") } footer: {
            Note("Prompts, questions and plans show up in the menu and as alerts. The terminal still asks too, and whichever you answer first counts. Risky commands always need a click.")
        }

        if !model.allowedRules.isEmpty {
            Section {
                ForEach(model.allowedRules) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.rule).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).help(r.rule)
                            Text("\(r.everywhere ? "Every project" : Fmt.folderTitle(r.cwd)) · \(Fmt.ago(r.at))").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { model.removeRule(r) }
                    }
                }
            } header: { Text("Rules you allowed from Agent Deck") } footer: {
                Note("Remove takes a rule out of Claude Code's settings, so it asks again. Session-only rules end with their session.")
            }
        }

        Section {
            Picker("Open sessions in", selection: $terminalApp) {
                ForEach(TerminalApp.allCases.filter { $0.isInstalled || $0.rawValue == terminalApp }) { Text($0.title).tag($0.rawValue) }
            }
            if terminalApp != TerminalApp.iterm.rawValue {
                Note("Reply, rename, compact, clear and phone type into a session, so they work only for sessions in iTerm.")
            }
            Toggle(AppModel.keepAwakeTitle, isOn: Binding(get: { keepAwake }, set: { keepAwake = $0; model.setKeepAwake($0) }))
            Toggle("Show when Claude is having problems", isOn: Binding(get: { checkStatus }, set: { checkStatus = $0; model.checkServiceStatus(every: 0) }))
        } header: { Text("Sessions") } footer: {
            Note("Keeping awake holds off idle sleep only while a session works; the display can still sleep. Claude's status comes from status.claude.com.")
        }

        Section {
            Picker("Menu bar shows", selection: $barStyle) {
                ForEach(BarStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
        } header: { Text("App") }

        Section {
            Picker("Keep session history for", selection: Binding(get: { model.retentionDays }, set: { model.setRetention($0) })) {
                ForEach(Retention.choices(current: model.retentionDays), id: \.self) { d in
                    Text(Retention.label(d)).tag(d)
                }
            }
            .pickerStyle(.segmented)
        } header: { Text("History") } footer: {
            Note("Claude Code deletes older sessions by itself. Up to 30 days.")
        }

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
            if !updater.incoming.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(updater.incoming.prefix(8).enumerated()), id: \.offset) { Text("• \($0.element)").lineLimit(1) }
                    if updater.incoming.count > 8 { Text("and \(updater.incoming.count - 8) more") }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
        } header: { Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")") }
    }

    @ViewBuilder private var notifications: some View {
        Section {
            Picker("Show alerts", selection: $peekPlacement) {
                ForEach(PeekPlacement.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            LabeledContent("Preview") {
                HStack(spacing: 8) {
                    ForEach(Preview.allCases, id: \.self) { p in
                        Button { p.show() } label: { Label(p.title, systemImage: "play.fill") }
                            .help("Shows a sample \(p.title.lowercased()) alert with its sound")
                    }
                }
                .controlSize(.small)
                .disabled(peekPlacement == PeekPlacement.banners.rawValue)
            }
            .help(peekPlacement == PeekPlacement.banners.rawValue ? "Previews show Agent Deck's own alerts. macOS notifications look like any other app's." : "")
        } header: { Text("Alerts") } footer: {
            Note(peekPlacement == PeekPlacement.banners.rawValue
                 ? "macOS shows them like any other app's notifications, so Focus and Notification settings apply. Preview needs Agent Deck's own alerts."
                 : "Without a notch they drop from Dot in the menu bar. They never show in screen sharing. In a Focus only prompts get through, quietly. When you're away, they arrive as macOS notifications.")
        }
        Section {
            Toggle("A session needs your answer", isOn: $notifyWaiting)
            Toggle("A task that took over a minute finishes", isOn: $notifyFinished)
            Toggle("A limit gets close or looks set to run out", isOn: $notifyLimits)
            if notifyLimits {
                LabeledContent("Warn at") {
                    HStack(spacing: 4) {
                        Text("\(Int(warnLevel))%").monospacedDigit()
                        Stepper("Warn at", value: $warnLevel, in: 50...95, step: 5).labelsHidden()
                    }
                }
                .onChange(of: warnLevel) { model.recheckLimits() }
            }
        } header: { Text("Alert me when") } footer: {
            Note("Limits are shared by everyone on your Claude account, so a warning can come while this Mac is quiet.")
        }
    }

    @ViewBuilder private var storage: some View {
        Section {
            if let st = model.storage {
                StorageBar(parts: [("Conversations", st.conversations, Color.primary.opacity(0.7)), ("Scratchpads", st.scratchpads, Color.primary.opacity(0.42)), ("Undo backups", st.undoBackups, Color.primary.opacity(0.22))])
                HStack {
                    Text(st.orphans.isEmpty ? "No leftovers. Nice and tidy."
                         : "\(Fmt.count(st.orphans.count, "leftover")) from deleted sessions · \(Fmt.bytes(st.orphanBytes))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clean up leftovers") { Task { await model.cleanLeftovers() } }.disabled(st.orphans.isEmpty)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
            }
            Toggle("Clean up leftovers automatically once a day", isOn: $autoCleanLeftovers)
        } header: { Text("Claude storage") } footer: {
            Note("Leftovers are files Claude Code kept for sessions that are gone, like scratchpads and undo backups. Anything touched in the last day stays. Cleaned files go to the Trash.")
        }

        Section {
            DatePicker("Delete closed sessions last used before", selection: $cutoff, displayedComponents: .date)
            HStack {
                Text(old.isEmpty ? "Nothing that old" : "\(Fmt.count(old.count, "session")) · \(Fmt.bytes(old.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(old.count)))
                    .animation(Motion.fast(reduceMotion), value: old.count)
                Spacer()
                if confirmCleanup {
                    ConfirmRow(message: old.count == 1 ? "Move it to the Trash?" : "Move them to the Trash?", confirmTitle: "Clean up", destructive: true,
                               cancel: { confirmCleanup = false }) { model.delete(old); confirmCleanup = false }
                } else {
                    Button("Clean up…", role: .destructive) { confirmCleanup = true }.disabled(old.isEmpty)
                }
            }
        } header: { Text("Clean up now") } footer: {
            Note("This frees space on your Mac. Sessions on claude.ai and in the phone app live on Anthropic's servers and stay as they are.")
        }
    }

    @ViewBuilder private var health: some View {
        Section {
            ForEach(Self.hookKeys, id: \.0) { key, title in healthRow(title, model.health?[key] as? String) }
            if !hooksBroken || model.health?["error"] != nil {
                HStack {
                    if model.health?["error"] != nil { Text("Couldn't run the check. Is python3 installed?").foregroundStyle(Tone.warnText) }
                    Spacer()
                    Button("Repair setup") { Task { await model.repairHooks() } }
                }
            }
        } header: { Text("Health") } footer: {
            Note("Repair puts Agent Deck's hooks back and leaves yours alone. If the status line is missing, run install.sh again.")
        }

        Section {
            LabeledContent("Usage numbers", value: model.usageSourceText)
            LabeledContent("Claude Code", value: model.cli.map { Fmt.shortPath($0.executable.path) } ?? "not found")
        } header: { Text("Status") }
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
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
                .clipShape(RoundedRectangle(cornerRadius: Radius.inner))
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
            .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }
}

enum Preview: CaseIterable {
    case needs, limit, done

    var title: String {
        switch self {
        case .needs: "Needs you"
        case .limit: "Limit"
        case .done: "Done"
        }
    }

    @MainActor func show() {
        let alert: PeekAlert = switch self {
        case .needs:
            PeekAlert(id: "preview", kind: .needs, title: "my-app wants to run Bash", code: "npm run test",
                      actions: [.init(title: "Deny", done: "Denied") {}, .init(title: "Allow", style: .primary, done: "Allowed") {}], seconds: 6)
        case .limit:
            PeekAlert(id: "preview", kind: .warn, title: "5-hour limit at \(Int(Notifier.warnAt))%",
                      meta: Fmt.resetsTitle(Date().addingTimeInterval(95 * 60)), percent: Notifier.warnAt)
        case .done:
            PeekAlert(id: "preview", kind: .done, title: "my-app", meta: "Done after 12 min")
        }
        Peek.close()
        _ = Peek.show(alert, percent: nil)
    }
}

enum Retention {
    static let presets = [7, 14, 30]
    static func choices(current: Int) -> [Int] { presets.contains(current) ? presets : (presets + [current]).sorted() }
    static func label(_ d: Int) -> String { d == 7 ? "1 week" : d == 14 ? "2 weeks" : "\(d) days" }
}

enum BarStyle: String, CaseIterable, Identifiable {
    case closest, withSessions, ringOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .closest: return "Closest limit"
        case .withSessions: return "Closest limit · running sessions"
        case .ringOnly: return "Ring only"
        }
    }
}

private struct Keys: View {
    let keys: [String]
    init(_ keys: String...) { self.keys = keys }
    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { Keycap($0) }
        }
    }
}
