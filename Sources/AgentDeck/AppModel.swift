import AppKit
import ServiceManagement
import AgentDeckCore
import SwiftUI

struct Activity: Equatable {
    var tool: String?
    var detail: String?
    var subagents = Set<String>()
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var isError = false
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    let shownAt = Date()
    var lifetime: Double { action == nil ? 4 : 8 }
    static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
}

@MainActor @Observable
final class AppModel {
    private(set) var live: [LiveSession] = []
    private(set) var history: [HistorySession] = []
    private(set) var usage: UsageSnapshot?
    private(set) var samples: [UsageSample] = []
    private(set) var working: Set<String> = []
    private(set) var typingBlockers: [String: String] = [:]
    var banner: Banner?
    private(set) var retentionDays: Int
    private(set) var refreshing = false
    private(set) var storage: StorageSummary?
    private(set) var approvals: [ApprovalRequest] = []
    /// Answered cards stay a moment to show what was sent, then leave.
    private(set) var outcomes: [Int: ApprovalAnswer] = [:]
    private(set) var activity: [String: Activity] = [:]
    private(set) var busySince: [String: Date] = [:]
    private(set) var branches: [String: String] = [:]
    private(set) var context: [String: ContextReading] = [:]
    private(set) var codexUsage: [CodexUsage.Limit] = []
    /// `hook.py check`: "ok" / "missing" / "absent" per agent, plus hookScript and statusLine.
    private(set) var health: [String: Any]?
    var menuOpen = false {
        didSet {
            guard menuOpen else { return }
            Task { await refresh(history: true, agents: true) }
            // A broken hook silently turns approvals off, so the dropdown checks too (not on every open).
            if Date().timeIntervalSince(lastHealthCheck) > 600 { Task { await checkHealth() } }
        }
    }
    var detailsOpen = false
    var pinnedOpen = false
    @ObservationIgnored var showDetails: ((DetailsTab) -> Void)?
    private(set) var menuHotkeyFailed = false

    let paths = ClaudePaths()
    let cli: ClaudeCLI?
    let notifier = Notifier()
    private let scanner: HistoryScanner
    private let usageLog: UsageLog
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    private var lastHistoryScan = Date.distantPast
    private var lastAgents: Data?
    private var lastAgentsFetch = Date.distantPast
    private var lastAutoClean = Date.distantPast
    private var approvalServer: ApprovalServer?
    /// Codex and Gemini sessions, known only from their hooks.
    private var others: [String: LiveSession] = [:]
    /// Sessions whose plan was approved with "auto-accept edits": applied at their next edit prompt.
    private var autoAcceptEdits = Set<String>()
    private var lastCodexUsage = Date.distantPast
    private var lastHealthCheck = Date.distantPast
    private let hotkeys = Hotkeys()

    init() {
        let paths = self.paths
        scanner = HistoryScanner(paths: paths)
        usageLog = UsageLog(paths: paths)
        cli = ClaudeCLI.locate().map { ClaudeCLI(executable: $0, paths: paths) }
        retentionDays = ClaudeSettings.retentionDays(paths)
        samples = usageLog.load()
        if cli == nil {
            banner = Banner(text: "Couldn't find the claude command. Install Claude Code, then reopen Agent Deck.", isError: true)
        }
        // Open at login is on by default; after the first launch it's the user's choice in Settings.
        if !UserDefaults.standard.bool(forKey: "didSetLoginDefault") {
            UserDefaults.standard.set(true, forKey: "didSetLoginDefault")
            try? SMAppService.mainApp.register()
        }
        notifier.onOpen = { [weak self] id in self?.openSession(id: id) }
        notifier.onAnswer = { [weak self] id, answer in self?.answerFromNotification(id, answer) }
        notifier.hasApproval = { [weak self] sid in self?.approvals.contains { $0.sessionId == sid } ?? false }
        hotkeys.onKey = { [weak self] allow in self?.answerWithHotkey(allow: allow) }
        hotkeys.onMenu = { StatusMenu.toggle() }
        menuHotkeyFailed = !hotkeys.setMenuKey(MenuHotkey.current)
        UserDefaults.standard.register(defaults: [Self.approvalsKey: true])
        setApprovals(UserDefaults.standard.bool(forKey: Self.approvalsKey))
        watch(paths.sessionsDir)
        watch(paths.appDir)
        // Cheap tick: re-reads the small session files and the usage snapshot (no processes started),
        // so "waiting for you" shows within seconds. `claude agents` runs only when due, see refresh().
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh(history: true, agents: true) }
    }

    var liveIds: Set<String> { Set(live.map(\.sessionId)) }
    var closed: [HistorySession] { history.filter { !liveIds.contains($0.sessionId) } }
    var needsYou: Bool { live.contains { $0.state == .blocked && !$0.isLeftover } }
    func count(_ state: LiveSession.State) -> Int { live.filter { $0.state == state && !$0.isLeftover }.count }

    var barSummary: String {
        var parts: [String] = []
        if let w = usage?.fiveHour { parts.append("5-hour limit \(Int(w.percent().rounded()))%") }
        if let w = usage?.weekly { parts.append("weekly \(Int(w.percent().rounded()))%") }
        parts.append("\(live.count) session\(live.count == 1 ? "" : "s") running")
        let waiting = count(.blocked)
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        return parts.joined(separator: " · ")
    }
    var emptySessions: [HistorySession] { closed.filter(\.isEmpty) }
    var duplicateNames: Set<String> {
        var seen = Set<String>(), dupes = Set<String>()
        for h in history where !seen.insert(h.name).inserted { dupes.insert(h.name) }
        return dupes
    }

    func forecast(_ w: LimitWindow) -> Forecast { Forecast.compute(w, samples: samples) }

    func lastPrompt(_ sessionId: String) -> String {
        history.first { $0.sessionId == sessionId }?.lastPrompt ?? ""
    }

    var recentFolders: [String] {
        var seen = Set<String>()
        return (live.map(\.cwd) + history.map(\.cwd))
            .filter { FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
            .prefix(8).map { $0 }
    }

    /// Session files and usage every call. `claude agents` (which starts a process) every 5 s while
    /// a window is open, otherwise once a minute or when a session starts/stops. History once a minute.
    func refresh(history forceHistory: Bool = false, agents forceAgents: Bool = false) async {
        let agentsEvery: TimeInterval = (menuOpen || detailsOpen || pinnedOpen) ? 5 : 60
        if let cli, forceAgents || Date().timeIntervalSince(lastAgentsFetch) >= agentsEvery {
            lastAgentsFetch = Date()
            lastAgents = await cli.listAgentsJSON()
        }
        others = others.filter { $0.value.pid.map { kill($0, 0) == 0 } ?? true }
        let waiting = Set(approvals.map(\.sessionId))
        let next = (LiveSessions.load(paths, agentsJSON: lastAgents) + others.values.map { s in
            var s = s
            if waiting.contains(s.sessionId) { s.state = .blocked }
            return s
        }).sorted { $0.startedAt > $1.startedAt }
        if next != live {
            notifier.sessionsChanged(from: live, to: next, name: displayName)
            let now = Date()
            busySince = Dictionary(uniqueKeysWithValues: next.filter { $0.state == .busy }.map { ($0.sessionId, busySince[$0.sessionId] ?? now) })
            live = next
            typingBlockers = Dictionary(uniqueKeysWithValues: next.filter { $0.agent == .claude }.compactMap { s in ClaudeCLI.typingBlocker(s).map { (s.sessionId, $0) } })
            branches = Dictionary(next.compactMap { s in Git.branch(s.cwd).map { (s.cwd, $0) } }, uniquingKeysWith: { a, _ in a })
            activity = activity.filter { id, _ in next.contains { $0.sessionId == id } }
        }
        let ctx = Dictionary(uniqueKeysWithValues: live.filter { $0.agent == .claude }.compactMap { s in
            ContextUsage.load(paths, sessionId: s.sessionId).map { (s.sessionId, $0) } })
        if ctx != context { context = ctx }
        if Date().timeIntervalSince(lastCodexUsage) > 30 {
            lastCodexUsage = Date()
            let u = await Task.detached { CodexUsage.load() }.value
            if u != codexUsage { codexUsage = u }
        }
        dropAnsweredElsewhere()
        let u = UsageSnapshot.load(paths)
        if u != usage {
            usage = u
            if let u {
                samples = usageLog.record(u, existing: samples)
                notifier.usageChanged(u, forecast: forecast)
            }
        }
        if forceHistory || Date().timeIntervalSince(lastHistoryScan) > 60 { await refreshHistory() }
    }

    func refreshNow() async {
        refreshing = true
        defer { refreshing = false }
        await refresh(history: true, agents: true)
    }

    func refreshHistory() async {
        lastHistoryScan = Date()
        let scanner = self.scanner
        let h = await Task.detached { scanner.scan() }.value
        if h != history { history = h }
        if UserDefaults.standard.bool(forKey: "autoCleanLeftovers"), Date().timeIntervalSince(lastAutoClean) > 86400 {
            lastAutoClean = Date()
            await cleanLeftovers(quiet: true)
        }
    }

    private func watch(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            let sessions = dir == self?.paths.sessionsDir
            Task { @MainActor in await self?.refresh(history: sessions, agents: sessions) }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watchers.append(src)
    }

    func openSession(id: String) {
        if let s = live.first(where: { $0.sessionId == id }) { open(s) }
        else if let h = history.first(where: { $0.sessionId == id }) { resumeInTerminal(h) }
    }

    private func perform(_ id: String, success: String? = nil, undo: (@MainActor () -> Void)? = nil,
                         _ body: @escaping (ClaudeCLI) async throws -> Void) {
        guard let cli else { return }
        working.insert(id)
        Task {
            defer { working.remove(id) }
            do {
                try await body(cli)
                if let success { banner = Banner(text: success, actionTitle: undo == nil ? nil : "Undo", action: undo) }
            } catch let ClaudeCLI.Failure.untrusted(folder) {
                banner = Banner(text: ClaudeCLI.Failure.untrusted(folder: folder).errorDescription ?? "", isError: true,
                                actionTitle: "Open in iTerm") { [weak self] in
                    self?.openTerminal(ClaudeCLI.ShellLine.new(cwd: folder, name: ""))
                }
            } catch {
                banner = Banner(text: error.localizedDescription, isError: true)
            }
            await refresh(history: true)
        }
    }

    func stop(_ s: LiveSession) {
        if s.isLeftover {
            perform(s.sessionId, success: "Cleared \(displayName(s)). Its history is still in Recent.") { try await $0.stop(s) }
            return
        }
        perform(s.sessionId, success: "Stopped \(displayName(s)).", undo: { [weak self] in
            self?.openTerminal(ClaudeCLI.ShellLine.resume(s.sessionId, cwd: s.cwd))
        }) { try await $0.stop(s) }
    }

    /// Phone on: a terminal session gets /remote-control typed into it and keeps running on the Mac.
    /// A background session has no window, so it reopens in iTerm/Terminal with remote control on.
    func phoneOn(_ s: LiveSession) {
        let name = displayName(s)
        if s.kind == .interactive {
            perform(s.sessionId, success: "\(name) is on your phone and still open on your Mac.") { try await $0.setPhone(s, on: true) }
        } else {
            perform(s.sessionId, success: "\(name) is open in iTerm and on your phone.") { try await $0.openWithPhone(s) }
        }
    }

    func phoneOff(_ s: LiveSession) {
        perform(s.sessionId, success: "\(displayName(s)) is off your phone. It's still running on your Mac.") { try await $0.setPhone(s, on: false) }
    }

    func clearContext(_ s: LiveSession) {
        let name = displayName(s)
        perform(s.sessionId, success: "Cleared \(name)'s context.", undo: { [weak self] in
            guard let self, let now = self.live.first(where: { $0.pid == s.pid && $0.pid != nil }) else { return }
            self.perform(now.sessionId, success: "Brought back \(name)'s conversation.") { try await $0.resumeHere(now, id: s.sessionId) }
        }) { try await $0.clear(s) }
    }

    func compact(_ s: LiveSession) {
        perform(s.sessionId, success: "Compacting \(displayName(s)). Its context bar updates when it's done.") { try await $0.compact(s) }
    }

    func setMenuHotkey(_ key: MenuHotkey) {
        UserDefaults.standard.set(key.rawValue, forKey: MenuHotkey.key)
        menuHotkeyFailed = !hotkeys.setMenuKey(key)
    }

    func rename(_ s: LiveSession, to name: String) {
        perform(s.sessionId, success: "Renamed to \(name).") { try await $0.rename(s, to: name) }
    }

    func rename(_ h: HistorySession, to name: String) {
        do {
            try HistoryScanner.rename(h, to: name)
            banner = Banner(text: "Renamed to \(name).")
        } catch { banner = Banner(text: "Couldn't rename: \(error.localizedDescription)", isError: true) }
        Task { await refreshHistory() }
    }

    /// Running sessions named by Claude Code ("personal-a8") show the session's title instead,
    /// the same one the closed list uses. Names you set yourself are kept.
    func displayName(_ s: LiveSession) -> String {
        guard s.nameIsDerived, let h = history.first(where: { $0.sessionId == s.sessionId }), h.name != h.shortId else { return s.name }
        return h.name
    }

    func newOnPhone(folder: String, name: String) {
        perform("new", success: "Started a session in \(Fmt.folderName(folder)). It's on your phone now.") {
            try await $0.newOnPhone(cwd: folder, name: name)
        }
    }

    func newInTerminal(folder: String, name: String) { openTerminal(ClaudeCLI.ShellLine.new(cwd: folder, name: name)) }
    func resumeInTerminal(_ h: HistorySession) { openTerminal(ClaudeCLI.ShellLine.resume(h.sessionId, cwd: h.cwd)) }

    func open(_ s: LiveSession) {
        if s.kind == .interactive, let pid = s.pid, ClaudeCLI.focusTerminal(pid: pid, cwd: s.cwd) { return }
        guard s.agent == .claude else { return }
        openTerminal(ClaudeCLI.ShellLine.attach(s.shortId))
    }

    func openTerminal(_ line: String) {
        do { try cli?.openInITerm(line) } catch { banner = Banner(text: error.localizedDescription, isError: true) }
    }

    /// Only closed sessions; running ones are skipped so a live transcript is never pulled away.
    func delete(_ sessions: [HistorySession], files: [URL] = []) {
        let ids = liveIds
        var failed = 0, done = 0, moved: [Leftovers.Moved] = []
        for s in sessions where !ids.contains(s.sessionId) {
            do { moved += try HistoryScanner.trash(s, paths: paths); done += 1 } catch { failed += 1 }
        }
        let (fileFailed, filesMoved) = Leftovers.moveToTrash(files)
        moved += filesMoved
        let filesNote = files.isEmpty ? "" : " and \(files.count - fileFailed) file\(files.count - fileFailed == 1 ? "" : "s")"
        banner = failed + fileFailed == 0
            ? Banner(text: "Moved \(done) session\(done == 1 ? "" : "s")\(filesNote) to the Trash.", actionTitle: moved.isEmpty ? nil : "Undo") { [weak self] in
                self?.undoDelete(moved)
            }
            : Banner(text: "Moved \(done) session\(done == 1 ? "" : "s")\(filesNote) to the Trash; \(failed + fileFailed) couldn't be moved.", isError: true)
        Task { await refreshHistory(); if storage != nil { await refreshStorage() } }
    }

    private func undoDelete(_ moved: [Leftovers.Moved]) {
        let failed = Leftovers.restore(moved)
        banner = failed == 0 ? Banner(text: "Restored from the Trash.")
                             : Banner(text: "\(failed) item\(failed == 1 ? "" : "s") couldn't be restored. They're still in the Trash.", isError: true)
        Task { await refreshHistory(); if storage != nil { await refreshStorage() } }
    }

    func deletePreview(_ sessions: [HistorySession]) async -> (bytes: Int64, files: [CreatedFile]) {
        let paths = self.paths
        return await Task.detached {
            let bytes = sessions.reduce(0) { $0 + Leftovers.size(Leftovers.allPaths($1, paths)) }
            let files = sessions.count == 1 ? Leftovers.createdFiles(sessions[0], paths) : []
            return (bytes, files)
        }.value
    }

    func refreshStorage() async {
        let paths = self.paths, keep = liveIds
        storage = await Task.detached { Leftovers.summary(paths, keep: keep) }.value
    }

    func cleanLeftovers(quiet: Bool = false) async {
        let paths = self.paths, keep = liveIds
        let (orphans, bytes) = await Task.detached {
            let o = Leftovers.orphans(paths, keep: keep)
            return (o, Leftovers.size(o))
        }.value
        let failed = Leftovers.moveToTrash(orphans).failed
        if !quiet || failed > 0 {
            banner = failed == 0 ? Banner(text: "Moved \(orphans.count) leftover\(orphans.count == 1 ? "" : "s") (\(Fmt.bytes(bytes))) to the Trash.")
                : Banner(text: "\(failed) leftover\(failed == 1 ? "" : "s") couldn't be moved to the Trash.", isError: true)
        }
        if storage != nil { await refreshStorage() }
    }

    func setRetention(_ days: Int) {
        do {
            try ClaudeSettings.setRetentionDays(days, paths)
            retentionDays = days
            banner = Banner(text: "Claude Code will now keep sessions for \(days) days.")
        } catch {
            banner = Banner(text: error.localizedDescription, isError: true)
        }
    }

    // MARK: Approvals

    static let approvalsKey = "answerPrompts"
    var approvalsOn: Bool { approvalServer != nil }

    /// Off removes the socket, so the installed hooks find nothing and print nothing.
    func setApprovals(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.approvalsKey)
        approvalServer?.stop()
        approvalServer = nil
        approvals = []
        updateApprovalUI()
        guard on else { return }
        let server = ApprovalServer(
            path: paths.approvalSocket.path,
            onRequest: { req in Task { @MainActor [weak self] in self?.received(req) } },
            onGone: { id in Task { @MainActor [weak self] in self?.removeApproval(id) } },
            onEvent: { e in Task { @MainActor [weak self] in self?.handle(e) } })
        do {
            try server.start()
            approvalServer = server
        } catch {
            banner = Banner(text: error.localizedDescription, isError: true)
        }
    }

    private func received(_ r: ApprovalRequest) {
        if r.agent != .claude { track(r.agent, r.sessionId, cwd: r.cwd, pid: r.pid, state: .blocked) }
        if r.kind == .permission, Self.editTools.contains(r.toolName), autoAcceptEdits.remove(r.sessionId) != nil {
            approvalServer?.answer(r.id, .acceptEdits)
            return
        }
        approvals.append(r)
        let name = sessionName(r.sessionId, cwd: r.cwd)
        notifier.approvalArrived(r, name: name)
        AccessibilityNotification.Announcement(r.kind == .permission ? "\(name) wants to use \(r.toolName)"
                                               : r.kind == .plan ? "\(name) has a plan for you" : "\(name) has a question").post()
        updateApprovalUI()
    }

    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    func approvePlan(_ r: ApprovalRequest, acceptEdits: Bool) {
        if acceptEdits { autoAcceptEdits.insert(r.sessionId) }
        answer(r.id, .allow(always: false))
    }

    private func handle(_ e: AgentEvent) {
        let sid = e.sessionId
        var a = activity[sid] ?? Activity()
        switch e.name {
        case "PreToolUse": (a.tool, a.detail) = (e.toolName, e.toolSummary)
        case "PostToolUse":
            a.tool = nil
            // That tool ran, so a card still asking about it was answered in the terminal.
            for r in approvals where r.sessionId == sid && r.toolName == e.toolName && r.detail == e.toolSummary.map({ String($0.prefix(4000)) }) {
                answer(r.id, .terminal)
            }
        case "SubagentStart": if let id = e.subagentId { a.subagents.insert(id) }
        case "SubagentStop": if let id = e.subagentId { a.subagents.remove(id) }
        case "Stop":
            a = Activity()
            autoAcceptEdits.remove(sid)
            for r in approvals where r.sessionId == sid { answer(r.id, .terminal) }
        default: break
        }
        activity[sid] = a
        guard e.agent != .claude else { return }
        switch e.name {
        case "SessionEnd": others[sid] = nil; activity[sid] = nil
        case "SessionStart", "Stop": track(e.agent, sid, cwd: e.cwd, pid: e.pid, state: .idle)
        case "Notification": track(e.agent, sid, cwd: e.cwd, pid: e.pid, state: .blocked)
        default: track(e.agent, sid, cwd: e.cwd, pid: e.pid, state: .busy)
        }
        Task { await refresh() }
    }

    private func track(_ agent: Agent, _ sid: String, cwd: String, pid: Int32?, state: LiveSession.State) {
        var s = others[sid] ?? LiveSession(agent: agent, sessionId: sid, pid: pid, cwd: cwd, state: state)
        s.state = state
        s.pid = s.pid ?? pid
        others[sid] = s
    }

    func answer(_ id: Int, _ a: ApprovalAnswer) {
        guard outcomes[id] == nil else { return }
        approvalServer?.answer(id, a)
        guard a != .terminal, approvals.contains(where: { $0.id == id }) else { removeApproval(id); return }
        outcomes[id] = a
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        notifier.approvalDone(id)
        updateApprovalUI()
        Task { try? await Task.sleep(nanoseconds: 700_000_000); removeApproval(id) }
    }

    var pendingApprovals: [ApprovalRequest] { approvals.filter { outcomes[$0.id] == nil } }

    private func removeApproval(_ id: Int) {
        outcomes[id] = nil
        guard approvals.contains(where: { $0.id == id }) else { return }
        approvals.removeAll { $0.id == id }
        notifier.approvalDone(id)
        updateApprovalUI()
    }

    // A notification posted before its category changed can still carry an Allow button.
    private func answerFromNotification(_ id: Int, _ a: ApprovalAnswer) {
        if case .allow = a, approvals.first(where: { $0.id == id })?.risk != nil { openPrompt(id); return }
        answer(id, a)
    }

    private func openPrompt(_ id: Int) {
        if let r = approvals.first(where: { $0.id == id }) { openSession(id: r.sessionId) }
    }

    private func answerWithHotkey(allow: Bool) {
        guard let r = pendingApprovals.first(where: { $0.kind == .permission }) else { return }
        if allow, let risk = r.risk {
            banner = Banner(text: "Not allowed by shortcut: this command \(risk). Click Allow once in the menu if you mean it.", isError: true)
            NSSound.beep()
            return
        }
        answer(r.id, allow ? .allow(always: false) : .deny)
    }

    private func updateApprovalUI() {
        hotkeys.setEnabled(pendingApprovals.contains { $0.kind == .permission })
    }

    /// Claude Code doesn't stop the hook when you answer in the terminal. Once the session's pid file
    /// no longer says it's waiting, the prompt is gone. The 3 s grace covers a pid file that hasn't
    /// caught up with a brand-new prompt yet.
    private func dropAnsweredElsewhere() {
        let waiting = Dictionary(live.map { ($0.sessionId, $0.state == .blocked) }, uniquingKeysWith: { a, _ in a })
        for r in approvals where waiting[r.sessionId] == false && Date().timeIntervalSince(r.receivedAt) > 3 {
            answer(r.id, .terminal)
        }
    }

    func sessionName(_ sessionId: String, cwd: String) -> String {
        live.first { $0.sessionId == sessionId }.map(displayName) ?? Fmt.folderName(cwd)
    }

    // MARK: Health

    /// The copy inside the app, so hooks can be repaired even if ~/.claude/agent-deck is gone.
    private var hookScript: String {
        Bundle.main.path(forResource: "hook", ofType: "py") ?? paths.appDir.appendingPathComponent("hook.py").path
    }

    func checkHealth() async {
        lastHealthCheck = Date()
        let out = await Self.python(hookScript, "check")
        health = out.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? ["error": true]
    }

    var missingHooks: Set<String> {
        Set(["claude", "codex", "gemini", "statusLine"].filter { health?[$0] as? String == "missing" })
    }

    func projectUsage(since: Date) async -> [ProjectUsage.Entry] {
        let sessions = history
        return await Task.detached { ProjectUsage.load(sessions, since: since) }.value
    }

    func repairHooks() async {
        let out = await Self.python(hookScript, "install")
        banner = out == nil ? Banner(text: "Couldn't repair the hooks. Run install.sh again.", isError: true)
                            : Banner(text: "Hooks repaired. In Codex, approve them once in /hooks.")
        await checkHealth()
    }

    private static func python(_ args: String...) async -> String? {
        await Task.detached {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = args
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }.value
    }

    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            banner = Banner(text: "Couldn't change Open at login: \(error.localizedDescription)", isError: true)
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

enum Fmt {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func folderName(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func shortPath(_ path: String) -> String {
        var p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 4 { p = "\(parts[0])/…/\(parts[parts.count - 2])/\(parts[parts.count - 1])" }
        return p
    }

    static func ago(_ d: Date) -> String {
        let now = Date()
        if now.timeIntervalSince(d) < 60 { return "now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: now)
    }

    static func resets(_ d: Date?) -> String {
        let now = Date()
        guard let d else { return "" }
        if d <= now { return "reset" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return "resets " + f.string(from: d)
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: d)
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m < 60 ? "\(max(m, 1)) min" : "\(m / 60) h \(m % 60) min"
    }

    static func forecast(_ f: Forecast) -> String? {
        switch f {
        case .reachesLimit(let at): return at <= Date() ? "Limit reached" : "At this pace: 100% at \(clock(at))"
        case .safeUntilReset: return "Safe until reset at this pace"
        case .unknown: return nil
        }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0fk", Double(n) / 1e3) : "\(n)"
    }

    static func model(_ id: String?) -> String {
        guard let id else { return "—" }
        // claude-opus-5-5 → Opus 5.5
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix(2).filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " \(version)")
    }
}
