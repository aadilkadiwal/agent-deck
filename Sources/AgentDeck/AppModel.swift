import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import AgentDeckCore
import SwiftUI
import UserNotifications

struct Activity: Equatable {
    var tool: String?
    var detail: String?
    var subagents = Set<String>()
}

/// What a session did since you last looked, counted from hook events (no transcript reading).
struct Away: Equatable {
    var since = Date()
    var files = Set<String>()
    var commands = 0
    var agents = 0

    var line: String? {
        let parts = [files.isEmpty ? nil : "edited \(Fmt.count(files.count, "file"))",
                     commands == 0 ? nil : "ran \(Fmt.count(commands, "command"))",
                     agents == 0 ? nil : "\(Fmt.count(agents, "agent")) done"].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let mins = Int(Date().timeIntervalSince(since) / 60)
        return (mins >= 1 ? "Since you looked, \(Fmt.span(Double(mins) * 60)): " : "Since you looked: ") + parts.joined(separator: " · ")
    }
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
    private(set) var forecasts: [String: Forecast] = [:]
    private(set) var recentFolders: [String] = []
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
    private(set) var away: [String: Away] = [:]
    /// Replies typed while a session was working; each goes out when that session is idle again.
    private(set) var queuedReplies: [String: String] = [:]
    /// Set by Reply on a Done alert; the dropdown opens with the reply field on that row.
    @ObservationIgnored var replyTarget: String?
    private(set) var serviceStatus: ServiceStatus?
    private(set) var allowedRules: [AllowedRule] = []
    private(set) var busySince: [String: Date] = [:]
    private(set) var recentUse = RecentUse()
    private(set) var continueQueue = Set<String>()
    private(set) var branches: [String: String] = [:]
    private(set) var context: [String: ContextReading] = [:]
    private(set) var accountStatus: AccountUsage.Result?
    /// `hook.py check`: "ok" / "missing" / "absent" per agent, plus hookScript and statusLine.
    private(set) var health: [String: Any]?
    private(set) var notificationsOff = false
    var menuOpen = false {
        didSet {
            // Closing the menu is "having looked", so the counts start over.
            guard menuOpen else { if oldValue { away = [:] }; return }
            checkServiceStatus(every: 120)
            Task { await refresh(history: true, agents: true); await checkNotifications() }
            // A broken hook silently turns approvals off, so the dropdown checks too (not on every open).
            if Date().timeIntervalSince(lastHealthCheck) > 600 { Task { await checkHealth() } }
        }
    }
    var detailsOpen = false
    @ObservationIgnored var showDetails: ((DetailsTab) -> Void)?
    @ObservationIgnored var showSettings: (() -> Void)?
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
    /// Sessions whose plan was approved with "auto-accept edits": applied at their next edit prompt.
    private var autoAcceptEdits = Set<String>()
    private var lastAccountFetch = Date.distantPast
    private var accountBackoff: TimeInterval = 0
    private var lastAccount = ClaudeAccount.current()
    private var historyLoaded = false
    private var alertsChecked = false
    private let launched = Date()
    private var lastLoginCheck = Date.distantPast
    private var lastRecentUse = Date.distantPast
    private var lastHealthCheck = Date.distantPast
    private var lastForecast = Date.distantPast
    private var refreshRunning = false
    private var usageRunning = false
    private var rerun: (history: Bool, agents: Bool)?
    private var watchTask: Task<Void, Never>?
    private var watchSessions = false
    private let hotkeys = Hotkeys()
    private var awake: IOPMAssertionID?
    private var lastStatusCheck = Date.distantPast
    private var reminded = Set<String>()
    private var blockedSince: [String: Date] = [:]
    static let keepAwakeKey = "keepAwake", statusKey = "checkServiceStatus"
    static let remindAfter: TimeInterval = 300

    init() {
        let paths = self.paths
        scanner = HistoryScanner(paths: paths)
        usageLog = UsageLog(paths: paths)
        cli = ClaudeCLI.locate().map { ClaudeCLI(executable: $0, paths: paths) }
        retentionDays = ClaudeSettings.retentionDays(paths)
        samples = usageLog.load()
        Task { await checkNotifications() }
        if cli == nil {
            banner = Banner(text: "Can't find Claude Code. Install it, then open Agent Deck again.", isError: true)
        }
        // Open at login is on by default; after the first launch it's the user's choice in Settings.
        if !UserDefaults.standard.bool(forKey: "didSetLoginDefault") {
            UserDefaults.standard.set(true, forKey: "didSetLoginDefault")
            try? SMAppService.mainApp.register()
        }
        notifier.onOpen = { [weak self] id in self?.openSession(id: id) }
        notifier.onAnswer = { [weak self] id, answer in self?.answerFromNotification(id, answer) }
        notifier.onSwitch = { [weak self] in self?.switchToSonnet() }
        notifier.onDecide = { [weak self] id, answer in self?.answer(id, answer) }
        notifier.onReview = { StatusMenu.open() }
        notifier.peek = { [weak self] alert in
            // With the dropdown open the prompt is already there as a card: just the sound.
            if self?.menuOpen == true, alert.kind == .needs || alert.kind == .risky {
                if !alert.quiet { NSSound(named: alert.kind.sound)?.play() }
                return true
            }
            return Peek.show(alert, percent: self?.shownPercent)
        }
        notifier.lastReply = { [weak self] sid in
            guard let url = self?.history.first(where: { $0.sessionId == sid })?.fileURL else { return nil }
            return await Task.detached { SessionDetail.lastReplyLine(url) }.value
        }
        notifier.hasApproval = { [weak self] sid in self?.approvals.contains { $0.sessionId == sid } ?? false }
        notifier.awayLine = { [weak self] sid in
            defer { self?.away[sid] = nil }
            return self?.away[sid]?.line
        }
        notifier.canReply = { [weak self] sid in
            guard let s = self?.live.first(where: { $0.sessionId == sid }) else { return false }
            return s.kind == .interactive && self?.typingBlockers[sid] == nil
        }
        notifier.onReply = { [weak self] sid in
            self?.replyTarget = sid
            StatusMenu.open()
        }
        hotkeys.onKey = { [weak self] allow in self?.answerWithHotkey(allow: allow) }
        hotkeys.onJump = { [weak self] in self?.jumpToWaiting() }
        hotkeys.onMenu = { StatusMenu.toggle() }
        menuHotkeyFailed = !hotkeys.setMenuKey(MenuHotkey.current)
        UserDefaults.standard.register(defaults: [Self.approvalsKey: true, Self.statusKey: true])
        allowedRules = AllowedRule.load(paths)
        setApprovals(UserDefaults.standard.bool(forKey: Self.approvalsKey))
        watch(paths.sessionsDir)
        watch(paths.appDir)
        // Cheap tick: re-reads the small session files and the usage snapshot (no processes started),
        // so "waiting for you" shows within seconds. `claude agents` runs only when due, see refresh().
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
            Task { @MainActor in await self?.refreshUsage() }
            Task { @MainActor in self?.notifier.flushHeld(); self?.remindWaiting(); self?.checkServiceStatus(every: 300) }
        }
        notifier.askForFocusStatus()
        Task { await refresh(history: true, agents: true) }
    }

    var liveIds: Set<String> { Set(live.map(\.sessionId)) }
    var closed: [HistorySession] { history.filter { !liveIds.contains($0.sessionId) } }
    var shownPercent: Double? { [usage?.fiveHour?.percent(), usage?.weekly?.percent()].compactMap { $0 }.max() }

    var needsYou: Bool { live.contains { $0.state == .blocked && !$0.isLeftover } }

    var closestWindow: LimitWindow? { [usage?.fiveHour, usage?.weekly].compactMap { $0 }.max { $0.percent() < $1.percent() } }

    func mood(for shown: LimitWindow?) -> DotMood {
        let pct = shown?.percent() ?? 0
        let out = shown.map { if case .reachesLimit(let at) = forecast($0), at > Date() { true } else { false } } ?? false
        if pendingApprovals.contains(where: { $0.risk != nil }) { return .risky }
        if needsYou || !pendingApprovals.isEmpty { return .needs }
        if pct >= LimitWindow.full { return .reached }
        if pct >= Notifier.warnAt { return out ? .runsOut : .warn }
        return count(.busy) > 0 ? .working : .idle
    }
    func count(_ state: LiveSession.State) -> Int { live.filter { $0.state == state && !$0.isLeftover }.count }

    private(set) var usageIsAccount = false

    var usageSourceText: String {
        let when = usage.map { " · updated \(Fmt.ago($0.updatedAt))" } ?? ""
        switch accountStatus {
        case .signedOut?: return "Not signed in to Claude Code"
        case .expired?: return "Your login expired. Open Claude Code once to fix it."
        case .rateLimited?: return "Anthropic asked us to slow down. Trying again in \(Int(accountBackoff / 60)) min."
        case .failed?: return "Couldn't reach Anthropic, so these are this Mac's last numbers" + when
        case .ok?, nil:
            guard usage != nil else { return "None yet. They arrive with your next Claude Code message." }
            return (usageIsAccount ? "From Anthropic, for the whole account" : "From Claude Code on this Mac") + when
        }
    }

    var barSummary: String {
        var parts: [String] = []
        if let w = usage?.fiveHour { parts.append("5-hour limit \(Int(w.percent().rounded()))%") }
        if let w = usage?.weekly { parts.append("weekly \(Int(w.percent().rounded()))%") }
        if let at = runsOut { parts.append("runs out at \(Fmt.clock(at)) at this pace") }
        parts.append("\(Fmt.count(live.count, "session")) running")
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

    func forecast(_ w: LimitWindow) -> Forecast { forecasts[w.key] ?? .unknown }

    var lastHour: SharedUse.Split {
        SharedUse.split(samples, key: "five_hour", since: Date().addingTimeInterval(-3600), activeMinutes: recentUse.activeMinutes)
    }

    var usageNote: String? {
        let h = lastHour
        guard h.others >= 1 else { return nil }
        if h.mine == 0 { return "All of the last hour's use came from another Mac on your account" }
        return "\(h.others >= h.mine ? "Most" : "Some") of the last hour's use came from another Mac on your account"
    }

    // The one that resets last is when work can go on. It counts as used up for a minute past its
    // reset, so "continue" doesn't race the server's clock.
    var limitHit: LimitWindow? {
        usage?.windows.filter { $0.percent(at: Date().addingTimeInterval(-60)) >= LimitWindow.full }.max { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    }

    func isStoppedAtLimit(_ s: LiveSession) -> Bool {
        s.state == .idle && recentUse.stoppedAtLimit.contains(s.sessionId)
    }

    func toggleContinue(_ s: LiveSession) {
        if continueQueue.remove(s.sessionId) == nil {
            continueQueue.insert(s.sessionId)
            if limitHit == nil { Task { await continueQueued() } }
        }
    }

    func recheckLimits() {
        guard let u = usage else { return }
        notifier.usageChanged(u, forecast: forecast, note: usageNote, canSwitch: switchCandidates.count)
    }

    var switchCandidates: [LiveSession] {
        live.filter { s in
            s.state == .idle && typingBlockers[s.sessionId] == nil && s.kind == .interactive
                && (history.first { $0.sessionId == s.sessionId }?.model.map { $0.contains("opus") || $0.contains("fable") } ?? false)
        }
    }

    func switchToSonnet() {
        let targets = switchCandidates
        guard let cli, !targets.isEmpty else { return }
        Task {
            let withFiles = targets.compactMap { s in history.first { $0.sessionId == s.sessionId }.map { (s, transcript: $0.fileURL) } }
            let errors = await cli.switchModel(withFiles, to: "sonnet")
            await refreshHistory()   // so the switched sessions stop counting as Opus before their next reply
            let done = targets.count - errors.count
            if let (s, e) = errors.first {
                let why = e.localizedDescription.replacingOccurrences(of: s.name, with: displayName(s))
                let which = errors.count > 1 ? " Couldn't type into \(errors.map { displayName($0.0) }.joined(separator: ", "))." : ""
                banner = Banner(text: "Switched \(done) of \(targets.count).\(which) \(why)", isError: true)
            } else {
                banner = Banner(text: "Switched \(Fmt.count(done, "session")) to Sonnet.")
            }
        }
    }

    private func refreshRecentUse() async {
        lastRecentUse = Date()
        let files = Dictionary(live.compactMap { s in history.first { $0.sessionId == s.sessionId }.map { (s.sessionId, $0.fileURL) } },
                               uniquingKeysWith: { a, _ in a })
        let since = Date().addingTimeInterval(-3600)
        let r = await Task.detached { RecentUse.load(files, since: since) }.value
        if r != recentUse { recentUse = r }
        let queue = continueQueue.filter { id in live.contains { $0.sessionId == id } && r.stoppedAtLimit.contains(id) }
        if queue != continueQueue { continueQueue = queue }
    }

    private func continueQueued() async {
        guard let cli, limitHit == nil, !continueQueue.isEmpty else { return }
        let targets = live.filter { continueQueue.contains($0.sessionId) }
        continueQueue = []
        var done: [String] = [], failed: [String] = []
        for s in targets {
            do { try await cli.send("continue", to: s); done.append(displayName(s)) } catch { failed.append(displayName(s)) }
        }
        notifier.continued(done: done, failed: failed)
        lastRecentUse = .distantPast
    }

    var runsOut: Date? {
        ["five_hour", "seven_day"].compactMap { if case .reachesLimit(let at) = forecasts[$0], at > Date() { at } else { nil } }.min()
    }

    func lastPrompt(_ sessionId: String) -> String {
        history.first { $0.sessionId == sessionId }?.lastPrompt ?? ""
    }

    private func updateRecentFolders() {
        var seen = Set<String>(), folders: [String] = []
        for cwd in live.map(\.cwd) + history.map(\.cwd) where folders.count < 8 {
            if seen.insert(cwd).inserted && FileManager.default.fileExists(atPath: cwd) { folders.append(cwd) }
        }
        if folders != recentFolders { recentFolders = folders }
    }

    /// Session files and usage every call. `claude agents` (which starts a process) every 5 s while
    /// a window is open, otherwise once a minute or when a session starts/stops. History once a minute.
    /// Timer, watchers and hook events all call this; a call during a run folds into one rerun after it.
    func refresh(history forceHistory: Bool = false, agents forceAgents: Bool = false) async {
        if refreshRunning {
            rerun = ((rerun?.history ?? false) || forceHistory, (rerun?.agents ?? false) || forceAgents)
            return
        }
        refreshRunning = true
        defer { refreshRunning = false }
        var next: (history: Bool, agents: Bool)? = (forceHistory, forceAgents)
        while let (h, a) = next {
            await refreshOnce(history: h, agents: a)
            next = rerun
            rerun = nil
        }
    }

    private func refreshOnce(history forceHistory: Bool, agents forceAgents: Bool) async {
        let agentsEvery: TimeInterval = (menuOpen || detailsOpen) ? 5 : 60
        if let cli, forceAgents || Date().timeIntervalSince(lastAgentsFetch) >= agentsEvery {
            lastAgentsFetch = Date()
            lastAgents = await cli.listAgentsJSON()
        }
        let next = LiveSessions.load(paths, agentsJSON: lastAgents).sorted { $0.startedAt > $1.startedAt }
        if next != live {
            notifier.sessionsChanged(from: live, to: next, name: displayName)
            let now = Date()
            busySince = Dictionary(uniqueKeysWithValues: next.filter { $0.state == .busy }.map { ($0.sessionId, busySince[$0.sessionId] ?? now) })
            blockedSince = Dictionary(uniqueKeysWithValues: next.filter { $0.state == .blocked && !$0.isLeftover }
                .map { ($0.sessionId, blockedSince[$0.sessionId] ?? now) })
            live = next
            activity = activity.filter { id, _ in next.contains { $0.sessionId == id } }
            away = away.filter { id, _ in next.contains { $0.sessionId == id } }
            sendQueuedReplies()
            updateAwake()
            updateApprovalUI()
            updateRecentFolders()
            lookUp(next)
        }
        let ctx = Dictionary(uniqueKeysWithValues: live.compactMap { s in
            ContextUsage.load(paths, sessionId: s.sessionId).map { (s.sessionId, $0) } })
        if ctx != context { context = ctx }
        dropAnsweredElsewhere()
        await refreshUsage()
        if forceHistory || Date().timeIntervalSince(lastHistoryScan) > 60 { await refreshHistory() }
        if Date().timeIntervalSince(lastRecentUse) > (live.contains { $0.state == .busy } ? 20 : 60) { await refreshRecentUse() }
    }

    @ObservationIgnored private var lookupNext: [LiveSession]?
    @ObservationIgnored private var lookupRunning = false

    // Reading a folder under Desktop or Documents blocks until macOS's access prompt is answered, so branches and
    // window checks run beside the refresh instead of holding up sessions, usage and history. Only the newest list waits.
    private func lookUp(_ sessions: [LiveSession]) {
        lookupNext = sessions
        guard !lookupRunning else { return }
        lookupRunning = true
        Task {
            while let next = lookupNext {
                lookupNext = nil
                let (blockers, br) = await Task.detached {
                    (Dictionary(next.compactMap { s in ClaudeCLI.typingBlocker(s).map { (s.sessionId, $0) } },
                                uniquingKeysWith: { a, _ in a }),
                     Dictionary(next.compactMap { s in Git.branch(s.cwd).map { (s.cwd, $0) } }, uniquingKeysWith: { a, _ in a }))
                }.value
                if blockers != typingBlockers { typingBlockers = blockers }
                if br != branches { branches = br }
            }
            lookupRunning = false
        }
    }

    /// Limit warnings must not wait behind session work (a slow `claude agents`, a folder-access prompt),
    /// so the timer also runs this on its own.
    private func refreshUsage() async {
        guard !usageRunning else { return }
        usageRunning = true
        defer { usageRunning = false }
        // Someone else signed in here: their limits are new numbers, not stale ones.
        let account = ClaudeAccount.current()
        if account != lastAccount {
            lastAccount = account
            usage = nil
            accountStatus = nil
            lastAccountFetch = .distantPast
        }
        // The status line carries the whole account's numbers too, so only a Mac where it has gone quiet
        // (nobody using Claude here) asks Anthropic. Keeps a shared login well under the endpoint's rate limit.
        let local = UsageSnapshot.load(paths)
        let localFresh = local.map { Date().timeIntervalSince($0.updatedAt) < 300 } ?? false
        if !localFresh, Date().timeIntervalSince(lastAccountFetch) >= max(600, accountBackoff) {
            lastAccountFetch = Date()
            var r = await AccountUsage.fetch()
            // ponytail: the endpoint allows about one request per 10 minutes per login (measured); Claude Code's
            // own /usage shares it, so ask at most that often and back off further after a 429.
            accountBackoff = r == .rateLimited ? min(max(accountBackoff * 2, 1200), 1800) : 0
            // Claude Code renews its own login; asking it for the auth status lets it do that while nobody uses it here.
            if r == .expired, let cli, Date().timeIntervalSince(lastLoginCheck) > 600 {
                lastLoginCheck = Date()
                _ = try? await cli.run(["auth", "status"], timeout: 20)
                r = await AccountUsage.fetch()
            }
            if r != accountStatus { accountStatus = r }
        }
        // Both cover every Mac on the login; the newer reading wins.
        var u = local
        var fromAccount = false
        if case .ok(let a) = accountStatus, a.updatedAt > (local?.updatedAt ?? .distantPast) { u = a; fromAccount = true }
        if fromAccount != usageIsAccount { usageIsAccount = fromAccount }
        u = u?.keepingNewest(usage)
        let usageChanged = u != usage
        if usageChanged {
            usage = u
            if let u { samples = usageLog.record(u, existing: samples) }
        }
        if usageChanged || Date().timeIntervalSince(lastForecast) >= 60 {
            lastForecast = Date()
            let f = Dictionary(uniqueKeysWithValues: (u?.windows ?? []).map { ($0.key, Forecast.compute($0, samples: samples)) })
            if f != forecasts { forecasts = f }
        }
        // Alerts wait for the first history scan (offering the switch needs each session's model), but
        // never long: a folder-access prompt can hold the session scan up indefinitely.
        if let u, historyLoaded || Date().timeIntervalSince(launched) > 15, usageChanged || !alertsChecked {
            alertsChecked = true
            notifier.usageChanged(u, forecast: forecast, note: usageNote, canSwitch: switchCandidates.count)
        }
        if !continueQueue.isEmpty, limitHit == nil { await continueQueued() }
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
        if h != history {
            history = h
            updateRecentFolders()
        }
        if !historyLoaded {
            historyLoaded = true
            // Which sessions here were active decides whether alerts blame another Mac, so read that first.
            await refreshRecentUse()
            recheckLimits()
        }
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
            MainActor.assumeIsolated { self?.watchFired(sessions: dir == self?.paths.sessionsDir) }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watchers.append(src)
    }

    /// A burst of file events (one write per session file) becomes one refresh 0.5 s after the first.
    private func watchFired(sessions: Bool) {
        watchSessions = watchSessions || sessions
        guard watchTask == nil else { return }
        watchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let sessions = watchSessions
            (watchSessions, watchTask) = (false, nil)
            await refresh(history: sessions, agents: sessions)
        }
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
                                actionTitle: "Open in \(TerminalApp.current.title)") { [weak self] in
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
            perform(s.sessionId, success: "Removed \(displayName(s)). Its history is still in Recent.") { try await $0.stop(s) }
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
            perform(s.sessionId, success: "\(name) is open in \(TerminalApp.current.title) and on your phone.") { try await $0.openWithPhone(s) }
        }
    }

    func phoneOff(_ s: LiveSession) {
        perform(s.sessionId, success: "\(displayName(s)) is off your phone and still running on your Mac.") { try await $0.setPhone(s, on: false) }
    }

    func clearContext(_ s: LiveSession) {
        let name = displayName(s)
        perform(s.sessionId, success: "\(name) is starting fresh.", undo: { [weak self] in
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
        } catch { banner = Banner(text: "Couldn't rename it. \(error.localizedDescription)", isError: true) }
        Task { await refreshHistory() }
    }

    /// Running sessions named by Claude Code ("personal-a8") show the session's title instead,
    /// the same one the closed list uses. Names you set yourself are kept.
    func displayName(_ s: LiveSession) -> String {
        guard s.nameIsDerived, let h = history.first(where: { $0.sessionId == s.sessionId }), h.name != h.shortId else { return s.name }
        return h.name
    }

    func newOnPhone(folder: String, name: String, worktree: Bool = false) {
        perform("new", success: "Started a session in \(Fmt.folderTitle(folder))\(worktree ? ", in its own worktree" : ""). It's on your phone now.") {
            try await $0.newOnPhone(cwd: folder, name: name, worktree: worktree)
        }
    }

    func newInTerminal(folder: String, name: String, worktree: Bool = false) {
        openTerminal(ClaudeCLI.ShellLine.new(cwd: folder, name: name, worktree: worktree))
    }
    func resumeInTerminal(_ h: HistorySession) { openTerminal(ClaudeCLI.ShellLine.resume(h.sessionId, cwd: h.cwd)) }

    func open(_ s: LiveSession) {
        Task {
            if s.kind == .interactive, let pid = s.pid, await ClaudeCLI.focusTerminal(pid: pid, cwd: s.cwd) { return }
            openTerminal(ClaudeCLI.ShellLine.attach(s.shortId))
        }
    }

    func openTerminal(_ line: String) {
        do { try cli?.openInTerminal(line) } catch { banner = Banner(text: error.localizedDescription, isError: true) }
    }

    // MARK: Reply

    /// Typed into the session's iTerm tab like /rename, with the same checks: never mixed into a
    /// draft, never into a question. A working session gets it once it's idle again.
    func reply(_ s: LiveSession, _ text: String) {
        let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let name = displayName(s), sid = s.sessionId
        if s.state == .busy {
            queuedReplies[sid] = t
            banner = Banner(text: "Queued. It goes to \(name) when it finishes.", actionTitle: "Cancel") { [weak self] in
                self?.queuedReplies[sid] = nil
            }
            return
        }
        away[sid] = nil
        perform(sid, success: "Sent to \(name).") { try await $0.send(t, to: s) }
    }

    private func sendQueuedReplies() {
        for (sid, text) in queuedReplies {
            guard let s = live.first(where: { $0.sessionId == sid }) else {
                queuedReplies[sid] = nil
                banner = Banner(text: "That session ended before your reply went out.", isError: true)
                continue
            }
            guard s.state == .idle else { continue }
            queuedReplies[sid] = nil
            reply(s, text)
        }
    }

    // MARK: Keep awake

    /// Holds off idle sleep (the display may still sleep) while any session is working.
    func updateAwake() {
        let want = UserDefaults.standard.bool(forKey: Self.keepAwakeKey) && count(.busy) > 0
        if want, awake == nil {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Claude Code is working" as CFString, &id) == kIOReturnSuccess { awake = id }
        } else if !want, let id = awake {
            IOPMAssertionRelease(id)
            awake = nil
        }
    }

    func setKeepAwake(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.keepAwakeKey)
        updateAwake()
    }

    var keepsAwake: Bool { awake != nil }

    // MARK: Claude status

    func checkServiceStatus(every interval: TimeInterval) {
        guard UserDefaults.standard.bool(forKey: Self.statusKey) else { serviceStatus = nil; return }
        guard menuOpen || count(.busy) > 0, Date().timeIntervalSince(lastStatusCheck) >= interval else { return }
        lastStatusCheck = Date()
        Task {
            let s = await ServiceStatus.fetch()
            if s != serviceStatus { serviceStatus = s }
        }
    }

    // MARK: Waiting prompts

    private func remindWaiting() {
        let now = Date()
        for r in pendingApprovals where now.timeIntervalSince(r.receivedAt) >= Self.remindAfter && reminded.insert("a\(r.id)").inserted {
            notifier.approvalArrived(r, name: sessionName(r.sessionId, cwd: r.cwd), waited: now.timeIntervalSince(r.receivedAt))
        }
        let carded = Set(approvals.map(\.sessionId))
        for (sid, since) in blockedSince where !carded.contains(sid) && now.timeIntervalSince(since) >= Self.remindAfter
            && reminded.insert("w\(sid)-\(Int(since.timeIntervalSince1970))").inserted {
            if let s = live.first(where: { $0.sessionId == sid }) { notifier.stillWaiting(s, name: displayName(s), waited: now.timeIntervalSince(since)) }
        }
    }

    /// ⌃⌥J: the session that has waited longest, in its own terminal tab.
    private func jumpToWaiting() {
        let carded = pendingApprovals.map { ($0.sessionId, $0.receivedAt) }
        let other = blockedSince.filter { sid, _ in !carded.contains { $0.0 == sid } }.map { ($0.key, $0.value) }
        guard let sid = (carded + other).min(by: { $0.1 < $1.1 })?.0 else { NSSound.beep(); return }
        openSession(id: sid)
    }

    // MARK: Allowed rules

    private func logRules(_ r: ApprovalRequest, _ scope: RuleScope) {
        guard scope != .session, !r.alwaysRules.isEmpty else { return }
        let added = r.alwaysRules.map { AllowedRule(rule: $0, everywhere: scope == .everywhere, cwd: r.cwd) }
        allowedRules = added + allowedRules.filter { old in !added.contains { $0.id == old.id } }
        AllowedRule.save(allowedRules, paths)
    }

    func removeRule(_ rule: AllowedRule) {
        do {
            try rule.remove(paths)
            allowedRules.removeAll { $0.id == rule.id }
            AllowedRule.save(allowedRules, paths)
            banner = Banner(text: "Removed \(rule.rule). Claude Code asks again next time.")
        } catch { banner = Banner(text: "Couldn't remove it. \(error.localizedDescription)", isError: true) }
    }

    /// Only closed sessions; running ones are skipped so a live transcript is never pulled away.
    func delete(_ sessions: [HistorySession], files: [URL] = []) {
        let ids = liveIds, paths = self.paths
        Task {
            let (done, failed, fileFailed, moved) = await Task.detached {
                var failed = 0, done = 0, moved: [Leftovers.Moved] = []
                for s in sessions where !ids.contains(s.sessionId) {
                    do { moved += try HistoryScanner.trash(s, paths: paths); done += 1 } catch { failed += 1 }
                }
                let (fileFailed, filesMoved) = Leftovers.moveToTrash(files)
                return (done, failed, fileFailed, moved + filesMoved)
            }.value
            deleted(done: done, failed: failed, files: files, fileFailed: fileFailed, moved: moved)
        }
    }

    private func deleted(done: Int, failed: Int, files: [URL], fileFailed: Int, moved: [Leftovers.Moved]) {
        let filesNote = files.isEmpty ? "" : " and \(Fmt.count(files.count - fileFailed, "file"))"
        banner = failed + fileFailed == 0
            ? Banner(text: "Moved \(Fmt.count(done, "session"))\(filesNote) to the Trash.", actionTitle: moved.isEmpty ? nil : "Undo") { [weak self] in
                self?.undoDelete(moved)
            }
            : Banner(text: "Moved \(Fmt.count(done, "session"))\(filesNote) to the Trash; \(failed + fileFailed) couldn't be moved.", isError: true)
        Task { await refreshHistory(); if storage != nil { await refreshStorage() } }
    }

    private func undoDelete(_ moved: [Leftovers.Moved]) {
        Task {
            let failed = await Task.detached { Leftovers.restore(moved) }.value
            undone(failed)
        }
    }

    private func undone(_ failed: Int) {
        banner = failed == 0 ? Banner(text: "Restored from the Trash.")
                             : Banner(text: "\(Fmt.count(failed, "item")) couldn't be restored. They're still in the Trash.", isError: true)
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
        let (orphans, bytes, failed) = await Task.detached {
            let o = Leftovers.orphans(paths, keep: keep)
            let bytes = Leftovers.size(o)
            return (o, bytes, Leftovers.moveToTrash(o).failed)
        }.value
        if !quiet || failed > 0 {
            banner = failed == 0 ? Banner(text: "Moved \(Fmt.count(orphans.count, "leftover")) (\(Fmt.bytes(bytes))) to the Trash.")
                : Banner(text: "\(Fmt.count(failed, "leftover")) couldn't be moved to the Trash.", isError: true)
        }
        if storage != nil { await refreshStorage() }
    }

    func setRetention(_ days: Int) {
        do {
            try ClaudeSettings.setRetentionDays(days, paths)
            retentionDays = days
            banner = Banner(text: "Claude Code now keeps sessions for \(days) days.")
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
            var w = away[sid] ?? Away()
            if let tool = e.toolName, Self.editTools.contains(tool), let file = e.toolSummary?.split(separator: "\n").first { w.files.insert(String(file)) }
            if e.toolName == "Bash" { w.commands += 1 }
            away[sid] = w
            // That tool ran, so a card still asking about it was answered in the terminal.
            for r in approvals where r.sessionId == sid && r.toolName == e.toolName && r.detail == e.toolSummary.map({ String($0.prefix(4000)) }) {
                answer(r.id, .terminal)
            }
        case "SubagentStart": if let id = e.subagentId { a.subagents.insert(id) }
        case "SubagentStop":
            if let id = e.subagentId { a.subagents.remove(id) }
            away[sid, default: Away()].agents += 1
        case "Stop":
            a = Activity()
            autoAcceptEdits.remove(sid)
            for r in approvals where r.sessionId == sid { answer(r.id, .terminal) }
        default: break
        }
        activity[sid] = a
    }

    func answer(_ id: Int, _ a: ApprovalAnswer) {
        guard outcomes[id] == nil else { return }
        approvalServer?.answer(id, a)
        if let r = approvals.first(where: { $0.id == id }) {
            if a != .terminal { away[r.sessionId] = nil }
            if case .allow(true, let scope) = a { logRules(r, scope) }
        }
        guard a != .terminal, approvals.contains(where: { $0.id == id }) else { removeApproval(id); return }
        outcomes[id] = a
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        notifier.approvalDone(id)
        updateApprovalUI()
        Task { try? await Task.sleep(nanoseconds: 700_000_000); removeApproval(id) }
    }

    /// Set by "New session…" in Dot's right-click menu; the dropdown opens on the new-session form.
    @ObservationIgnored var startNewSession = false

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
            banner = Banner(text: "That command \(risk), so it needs a click. Open the menu and choose Allow once.", isError: true)
            NSSound.beep()
            return
        }
        answer(r.id, allow ? .allow(always: false) : .deny)
    }

    private func updateApprovalUI() {
        hotkeys.setEnabled(pendingApprovals.contains { $0.kind == .permission })
        hotkeys.setJump(!pendingApprovals.isEmpty || needsYou)
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
        live.first { $0.sessionId == sessionId }.map(displayName) ?? Fmt.folderTitle(cwd)
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
        await checkNotifications()
    }

    /// Unanswered counts as off too: until someone allows them, macOS drops every alert.
    func checkNotifications() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsOff = status == .denied || status == .notDetermined
    }

    var missingHooks: Set<String> {
        Set(["claude", "statusLine"].filter { health?[$0] as? String == "missing" })
    }

    func projectUsage(since: Date) async -> [ProjectUsage.Entry] {
        let sessions = history
        return await Task.detached { ProjectUsage.load(sessions, since: since) }.value
    }

    func repairHooks() async {
        let out = await Self.python(hookScript, "install")
        banner = out == nil ? Banner(text: "Couldn't repair the hooks. Running install.sh again fixes it.", isError: true)
                            : Banner(text: "Fixed. Prompts and usage work again.")
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
            banner = Banner(text: "Couldn't change Open at login. \(error.localizedDescription)", isError: true)
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

    static func folderTitle(_ path: String) -> String { path == home ? "Home" : folderName(path) }

    static func place(_ cwd: String, branch: String?, name: String, grouped: Bool = false) -> String? {
        let folder = folderTitle(cwd)
        let showFolder = !grouped && !folder.isEmpty && !name.localizedCaseInsensitiveContains(folder)
        let parts = [showFolder ? folder : nil, branch.flatMap { $0 == "main" || $0 == "master" ? nil : $0 }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func ago(_ d: Date) -> String {
        let now = Date()
        if now.timeIntervalSince(d) < 60 { return "now" }
        return relative.localizedString(for: d, relativeTo: now)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    // Templates, not fixed formats, so the 24-hour setting is followed.
    private static let time = formatter("jmm"), dayTime = formatter("EEEjmm")
    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static func resets(_ d: Date?) -> String {
        guard let d else { return "" }
        return d <= Date() ? "reset" : "resets " + clock(d)
    }

    /// `resets(_:)` for the start of a sentence. `.capitalized` would also turn "PM" into "Pm".
    static func resetsTitle(_ d: Date?) -> String {
        let s = resets(d)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func clock(_ d: Date) -> String {
        (Calendar.current.isDateInToday(d) ? time : dayTime).string(from: d)
    }

    static func hour(_ h: Int) -> String {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()).map(time.string) ?? "\(h):00"
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m < 60 ? "\(max(m, 1)) min" : "\(m / 60) h \(m % 60) min"
    }

    static func span(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m < 60 ? "\(max(m, 1)) min" : m < 48 * 60 ? "\(m / 60) h" : "\(m / 1440) d"
    }

    // Foundation's grammar agreement ("1 session", "3 sessions"), so plurals stay localizable.
    static func count(_ n: Int, _ noun: String) -> String {
        String(AttributedString(localized: "^[\(n) \(noun)](inflect: true)").characters)
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
