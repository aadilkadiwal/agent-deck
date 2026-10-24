import AgentDeckCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", notifications = "Notifications", shortcuts = "Shortcuts", storage = "Storage", health = "Health"
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
    @AppStorage(Notifier.Key.waiting) private var notifyWaiting = true
    @AppStorage(Notifier.Key.finished) private var notifyFinished = true
    @AppStorage(Notifier.Key.limits) private var notifyLimits = true
    @AppStorage(SettingsPage.key) private var page = SettingsPage.general.rawValue
    @AppStorage(MenuHotkey.key) private var menuHotkey = MenuHotkey.off.rawValue
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
        TabView(selection: Binding(get: { SettingsPage(rawValue: page) ?? .general }, set: { page = $0.rawValue })) {
            ForEach(SettingsPage.allCases) { p in
                VStack(spacing: 0) {
                    if p == .general || p == .health { healthSummary.padding([.horizontal, .top], 20) }
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
                Label("\((MenuHotkey(rawValue: menuHotkey) ?? .off).title) is already used by another app, so it does nothing here. Pick a different one.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
        } header: { Text("Menu") } footer: {
            Text("Opens the dropdown with the newest question selected, so ⌘⏎ answers it and esc takes you back. ⌃⌥Space also switches input sources in macOS when you have more than one keyboard language.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Allow the oldest permission prompt", value: "⌃⌥A")
            LabeledContent("Deny the oldest permission prompt", value: "⌃⌥D")
        } header: { Text("Prompts") } footer: {
            Text("Active only while a permission prompt is waiting. Risky commands, like deleting folders or force-pushing, can't be allowed with a shortcut: click Allow once in the menu.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Move · open", value: "↑ ↓ · ⏎")
            LabeledContent("All actions for the selected row", value: "⌘K")
            LabeledContent("Approve the selected card", value: "⌘⏎")
            LabeledContent("Phone · compact · clear · rename", value: "P · C · K · R")
            LabeledContent("Stop the selected session", value: "⌘⌫")
            LabeledContent("Search · refresh · new session", value: "⌘F · ⌘R · ⌘N")
        } header: { Text("In the dropdown") }
    }

    @ViewBuilder private var healthSummary: some View {
        let missing = Self.hookKeys.filter { model.health?[$0.0] as? String == "missing" }
        Callout(tint: model.health == nil ? .clear : missing.isEmpty && model.health?["error"] == nil ? .green : .orange) {
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
                Text("Needs repair: \(missing.map(\.1).joined(separator: ", "))").lineLimit(1)
                Spacer()
                Button("Repair hooks") { Task { await model.repairHooks() } }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
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
                .font(.subheadline).foregroundStyle(.secondary)
        } header: { Text("History") }

        Section {
            Toggle("Answer Claude's prompts from Agent Deck", isOn: Binding(get: { model.approvalsOn }, set: { model.setApprovals($0) }))
        } header: { Text("Prompts") } footer: {
            Text("Permission prompts, questions and plans show up in the menu and as notifications with Allow / Deny buttons. ⌃⌥A allows and ⌃⌥D denies the oldest permission prompt from any app, only while one is waiting; risky commands need a click. The prompt stays in the terminal too: whichever you answer first wins. \"Always allow\" saves the rule Claude Code itself suggests. Off: Claude Code asks only in the terminal.")
                .font(.subheadline).foregroundStyle(.secondary)
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
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var storage: some View {
        Section {
            if let st = model.storage {
                StorageBar(parts: [("Conversations", st.conversations, .blue), ("Scratchpads", st.scratchpads, .purple), ("Undo backups", st.undoBackups, .teal)])
                HStack {
                    Text(st.orphans.isEmpty ? "No leftovers from deleted sessions"
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
            Text("Leftovers are scratchpads, undo backups and other files Claude Code keeps per session, whose session was deleted or expired. Anything used in the last day is kept. They go to the Trash.")
                .font(.subheadline).foregroundStyle(.secondary)
        }

        Section {
            DatePicker("Delete closed sessions last used before", selection: $cutoff, displayedComponents: .date)
            HStack {
                Text("\(Fmt.count(old.count, "session")) · \(Fmt.bytes(old.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(old.count)))
                    .animation(Motion.fast(reduceMotion), value: old.count)
                Spacer()
                if confirmCleanup {
                    ConfirmRow(message: "Move them to the Trash?", confirmTitle: "Delete", destructive: true,
                               cancel: { confirmCleanup = false }) { model.delete(old); confirmCleanup = false }
                } else {
                    Button("Clean up…", role: .destructive) { confirmCleanup = true }.disabled(old.isEmpty)
                }
            }
        } header: { Text("Clean up now") } footer: {
            Text("This frees space on your Mac. Sessions listed on claude.ai or in the phone app are kept on Anthropic's servers and aren't affected.")
                .font(.subheadline).foregroundStyle(.secondary)
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
                .font(.subheadline).foregroundStyle(.secondary)
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
            .font(.subheadline)
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
    case closest, withSessions, ringOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .closest: return "Closest limit · waiting count"
        case .withSessions: return "Closest limit · running sessions"
        case .ringOnly: return "Ring only"
        }
    }
}
