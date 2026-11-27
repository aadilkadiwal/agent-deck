import AppKit
import Foundation

public struct ClaudeCLI: Sendable {
    public let executable: URL
    public let paths: ClaudePaths

    public init(executable: URL, paths: ClaudePaths) {
        self.executable = executable
        self.paths = paths
    }

    /// GUI apps start with a bare PATH, so check the usual install spots, then ask a login shell.
    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        // Interactive too (-i), so PATH set in .zshrc (nvm and the like) counts. Its startup can print
        // other lines, so take the last one that is a path.
        guard let r = try? Subprocess.run(URL(fileURLWithPath: "/bin/zsh"), ["-ilc", "command -v claude"], timeout: 5), !r.timedOut,
              let path = String(decoding: r.output, as: UTF8.self).split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { $0.hasPrefix("/") }),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    public enum Args {
        public static let listAgents = ["agents", "--json"]
        public static func stop(_ shortId: String) -> [String] { ["stop", shortId] }
        /// Removes a background entry, even one with no process. The conversation history is kept.
        public static func remove(_ shortId: String) -> [String] { ["rm", shortId] }
        public static func newOnPhone(name: String) -> [String] {
            let n = name.trimmingCharacters(in: .whitespaces)
            return ["--bg", "--remote-control"] + (n.isEmpty ? [] : ["-n", n])
        }
    }

    public enum ShellLine {
        public static func resume(_ sessionId: String, cwd: String, phone: Bool = false) -> String {
            "cd \(quote(cwd)) && claude --resume \(quote(sessionId))" + (phone ? " --remote-control" : "")
        }
        public static func attach(_ shortId: String) -> String { "claude attach \(quote(shortId))" }
        public static func new(cwd: String, name: String) -> String {
            let n = name.trimmingCharacters(in: .whitespaces)
            return "cd \(quote(cwd)) && claude" + (n.isEmpty ? "" : " -n \(quote(n))")
        }
    }

    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public enum Failure: LocalizedError, Equatable {
        case untrusted(folder: String)
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .untrusted(let f):
                return "\((f as NSString).lastPathComponent) isn't a trusted folder yet. Open it once in iTerm and accept the trust prompt, then try again."
            case .failed(let msg): return msg
            }
        }
    }

    /// Variables Claude Code sets inside its own sessions. Passing them on would make a new session
    /// think it is a child of another one (and skip saving its transcript).
    static func cleanEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { !$0.key.hasPrefix("CLAUDE") && $0.key != "CLAUDECODE" }
    }

    @discardableResult
    public func run(_ args: [String], cwd: String? = nil, timeout: TimeInterval = 60) async throws -> String {
        var env = Self.cleanEnvironment(ProcessInfo.processInfo.environment)
        env["PATH"] = "\(executable.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let r: Subprocess.Output
        do { r = try await Subprocess.run(executable, args, cwd: cwd, env: env, stderr: true, timeout: timeout) } catch {
            throw Failure.failed("Couldn't run claude: \(error.localizedDescription)")
        }
        if r.timedOut { throw Failure.failed("claude didn't finish within \(Int(timeout)) seconds.") }
        let output = String(decoding: r.output, as: UTF8.self)
        if output.contains("Workspace not trusted") { throw Failure.untrusted(folder: cwd ?? "") }
        if r.status != 0 {
            let msg = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(msg.isEmpty ? "claude exited with code \(r.status)" : msg)
        }
        return output
    }

    public func listAgentsJSON() async -> Data? {
        guard let out = try? await run(Args.listAgents) else { return nil }
        return Data(out.utf8)
    }

    /// Stops a session. Ending the process also disconnects remote control, so it leaves the phone list.
    public func stop(_ s: LiveSession) async throws {
        if s.isLeftover { try await run(Args.remove(s.shortId)); return }
        if s.kind == .background {
            do { try await run(Args.stop(s.shortId)) } catch Failure.failed(let msg) where msg.lowercased().contains("no job") {
                // Its process exited between our refresh and the click: clear the leftover entry instead.
                try await run(Args.remove(s.shortId))
            }
            return
        }
        try await signalInteractive(s)
        _ = await waitUntilGone(s)
    }

    /// Terminal sessions get SIGTERM, the same clean shutdown as closing the tab. Only sent when the
    /// pid file still names this exact session, so a recycled pid can never hit some other process.
    func signalInteractive(_ s: LiveSession) async throws {
        guard let pid = s.pid else { throw Failure.failed("No process id for this session.") }
        let file = paths.sessionsDir.appendingPathComponent("\(pid).json")
        var live = pidFile(pid)
        // Caught mid-write (exists but doesn't parse yet): read it once more before deciding.
        if live == nil, FileManager.default.fileExists(atPath: file.path) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            live = pidFile(pid)
            if live == nil, FileManager.default.fileExists(atPath: file.path) {
                throw Failure.failed("Couldn't read process \(pid)'s session file. Try again.")
            }
        }
        guard let live, live.sessionId == s.sessionId else { return } // already gone
        if kill(pid, SIGTERM) != 0 { throw Failure.failed("Couldn't stop process \(pid) (errno \(errno)).") }
    }

    /// True once the session's pid file is removed, which Claude Code does on clean exit.
    public func waitUntilGone(_ s: LiveSession, timeout: TimeInterval = 10) async -> Bool {
        guard let pid = s.pid else { return true }
        let file = paths.sessionsDir.appendingPathComponent("\(pid).json").path
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: file) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Turns phone access on or off for a session running in iTerm, by typing /remote-control into
    /// it, exactly as you would. The session keeps running on the Mac.
    @MainActor
    public func setPhone(_ s: LiveSession, on: Bool) async throws {
        let (pid, win) = try typingTarget(s, busyOK: true)
        try await typeCommand("/remote-control", into: win, session: s)
        if on {
            guard await waitForPhone(pid: pid, on: true, timeout: 15) else {
                throw Failure.failed("Remote control didn't start. Check the session's window.")
            }
        } else {
            // When it's already on, the command opens a menu: Disconnect sits two rows above the default.
            guard await waitFor(timeout: 5, { (try? win.screen())?.contains("Disconnect this session") == true }) else {
                throw Failure.failed("The remote control menu didn't open. Check the session's window.")
            }
            try win.chooseAbove(2)
            guard await waitForPhone(pid: pid, on: false, timeout: 8) else {
                throw Failure.failed("Couldn't confirm the disconnect. Check the session's window.")
            }
        }
    }

    @MainActor
    public func rename(_ s: LiveSession, to name: String) async throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !title.isEmpty else { return }
        let (_, win) = try typingTarget(s, busyOK: true)
        try await typeCommand("/rename \(title)", into: win, session: s)
    }

    /// /clear gives the session a new id, so a changed id in its pid file confirms it. Not while busy:
    /// /clear isn't an immediate command and would wait in its queue.
    @MainActor
    public func clear(_ s: LiveSession) async throws {
        let (pid, win) = try typingTarget(s, busyOK: false)
        try await typeCommand("/clear", into: win, session: s)
        // An unreadable file (mid-write) proves nothing either way, so it counts as "not yet".
        guard await waitFor(timeout: 8, { pidFile(pid).map { $0.sessionId != s.sessionId } ?? false }) else {
            throw Failure.failed("Couldn't confirm the clear. Check the session's window.")
        }
    }

    /// typeCommand already confirmed it was sent; the wait only keeps the spinner up while it starts.
    @MainActor
    public func compact(_ s: LiveSession) async throws {
        let (pid, win) = try typingTarget(s, busyOK: false)
        try await typeCommand("/compact", into: win, session: s)
        _ = await waitFor(timeout: 6) { pidFile(pid).map { $0.state != .idle } ?? false }
    }

    @MainActor
    public func send(_ line: String, to s: LiveSession) async throws {
        let (_, win) = try typingTarget(s, busyOK: false)
        try await typeCommand(line, into: win, session: s)
    }

    // `/model` in a conversation with replies first asks "Switch model?" with Yes picked, so Return
    // confirms it. Done only once the transcript says "Set model to". Claude Code also saves the model
    // as the default for new sessions; that is put back, so only these sessions switch.
    @MainActor
    public func switchModel(_ targets: [(LiveSession, transcript: URL)], to model: String) async -> [(LiveSession, Error)] {
        let before = ClaudeSettings.model(paths)
        var failed: [(LiveSession, Error)] = []
        for (s, url) in targets {
            do { try await switchModel(s, transcript: url, to: model) } catch { failed.append((s, error)) }
        }
        if ClaudeSettings.model(paths) != before { try? ClaudeSettings.setModel(before, paths) }
        return failed
    }

    @MainActor
    private func switchModel(_ s: LiveSession, transcript: URL, to model: String) async throws {
        let (_, win) = try typingTarget(s, busyOK: false)
        let start = (try? transcript.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try await typeCommand("/model \(model)", into: win, session: s)
        var confirmed = false
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let h = try? FileHandle(forReadingFrom: transcript) {
                defer { try? h.close() }
                try? h.seek(toOffset: UInt64(start))
                if let d = try? h.readToEnd(), d.range(of: Data("Set model to".utf8)) != nil { return }
            }
            if !confirmed, SessionWindow.draft(in: try win.screen())?.hasPrefix("1. Yes, switch") == true {
                try win.type("", enter: true)
                confirmed = true
            }
        }
        throw Failure.failed("\(s.name) didn't confirm the switch. Check its window.")
    }

    @MainActor
    public func resumeHere(_ s: LiveSession, id: String) async throws {
        let (pid, win) = try typingTarget(s, busyOK: false)
        try await typeCommand("/resume \(id)", into: win, session: s)
        guard await waitFor(timeout: 10, { pidFile(pid)?.sessionId == id }) else {
            throw Failure.failed("Couldn't confirm the conversation came back. Check the session's window.")
        }
    }

    /// iTerm sessions that aren't asking anything: typing into a pending question could answer it by accident.
    /// `busyOK`: /remote-control and /rename run at once even mid-reply (Claude Code's "immediate"
    /// commands), so they work while it's working or running agents. Other commands wait for idle.
    @MainActor
    func typingTarget(_ s: LiveSession, busyOK: Bool) throws -> (Int32, SessionWindow) {
        guard s.kind == .interactive, let pid = s.pid else { throw Failure.failed("\(s.name) has no window to type into.") }
        if let why = Self.typingBlocker(s, busyOK: busyOK) { throw Failure.failed(why) }
        return (pid, try SessionWindow.find(pid: pid))
    }

    /// Safe off the main thread: NSWorkspace's running-application list may be read from any thread.
    public static func typingBlocker(_ s: LiveSession, busyOK: Bool = true) -> String? {
        if s.kind == .background { return nil }   // handled by reopening in iTerm, not typing
        if s.state == .busy && !busyOK { return "Available when it's idle. It's working on a reply." }
        if s.state == .blocked { return "Available after you answer its question." }
        guard let pid = s.pid else { return "This session has no window." }
        switch owningApp(pid: pid)?.bundleIdentifier {
        case SessionWindow.itermBundleId: return nil
        case let other: return "Runs in \(other.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.deletingPathExtension().lastPathComponent } ?? "an app") that Agent Deck can't type into."
        }
    }

    /// Types a command and presses Return, without ever mixing it into text you were typing: type it,
    /// read the prompt line back; it must be exactly the command (typing replaces a grey suggestion).
    /// Anything else means there was a draft, so erase what was typed and stop. A busy session can
    /// start asking something meanwhile, so its pid file is checked again right before Return.
    @MainActor
    func typeCommand(_ command: String, into win: SessionWindow, session s: LiveSession) async throws {
        try win.type(command, enter: false)
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard SessionWindow.draft(in: try win.screen()) == command else {
            try win.erase(command.count)
            throw Failure.failed("\(s.name) has unsent text in its prompt. Send or clear it, then try again.")
        }
        let now = s.pid.flatMap(pidFile)
        if now?.state == .blocked {
            try win.erase(command.count)
            throw Failure.failed("\(s.name) just asked you something. Answer it, then try again.")
        }
        try win.type("", enter: true)
    }

    /// A background session has no window, so reopen it in iTerm with remote control on:
    /// you get it on the Mac and on your phone. Same session id, same history.
    @MainActor
    public func openWithPhone(_ s: LiveSession) async throws {
        try await stop(s)
        try openInITerm(ShellLine.resume(s.sessionId, cwd: s.cwd, phone: true))
    }

    @MainActor
    func waitForPhone(pid: Int32, on: Bool, timeout: TimeInterval) async -> Bool {
        await waitFor(timeout: timeout) { pidFile(pid)?.isOnPhone == on }
    }

    func pidFile(_ pid: Int32) -> LiveSession? {
        (try? Data(contentsOf: paths.sessionsDir.appendingPathComponent("\(pid).json"))).flatMap(LiveSessions.parsePidFile)
    }

    @MainActor
    func waitFor(timeout: TimeInterval, _ check: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return check()
    }

    public func newOnPhone(cwd: String, name: String) async throws {
        try await run(Args.newOnPhone(name: name), cwd: cwd)
    }

    /// iTerm doesn't reliably run `.command` files handed to it, so use its AppleScript API: a new
    /// tab in the front window (a new window only when none is open), then type the line into the
    /// user's normal shell. macOS asks once for permission to control iTerm.
    @MainActor
    public func openInITerm(_ line: String) throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: SessionWindow.itermBundleId) != nil else {
            throw Failure.failed("Agent Deck opens sessions in iTerm, which isn't installed. Get it from iterm2.com.")
        }
        let source = """
        tell application "iTerm"
            activate
            if current window is missing value then
                set w to (create window with default profile)
            else
                set w to current window
                tell w to create tab with default profile
            end if
            tell current session of w to write text "\(Self.appleScriptEscape(line))"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            let denied = (error[NSAppleScript.errorNumber] as? Int) == -1743
            throw Failure.failed(denied
                ? "Agent Deck isn't allowed to control iTerm. Turn it on in System Settings → Privacy & Security → Automation."
                : "Couldn't open iTerm: \(msg)")
        }
    }

    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @MainActor
    public static func focusTerminal(pid: Int32, cwd: String) -> Bool { Terminals.focus(pid: pid, cwd: cwd) }

    @MainActor
    public static func focusTerminal(pid: Int32, cwd: String) async -> Bool { await Terminals.focus(pid: pid, cwd: cwd) }

    public static func owningApp(pid: Int32) -> NSRunningApplication? {
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var current = pid
        var visited = Set<Int32>()
        while current > 1, visited.insert(current).inserted {
            if let app = apps[current], app.bundleIdentifier != Bundle.main.bundleIdentifier { return app }
            guard let parent = parentPid(of: current) else { break }
            current = parent
        }
        return nil
    }

    static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}

/// Runs a tool and kills it if it outlives `timeout`. The sync form blocks its thread, so keep it off the main one.
enum Subprocess {
    struct Output: Sendable { let status: Int32; let output: Data; let timedOut: Bool }

    static func run(_ exe: URL, _ args: [String], cwd: String? = nil, env: [String: String]? = nil,
                    stderr: Bool = false, timeout: TimeInterval) throws -> Output {
        let p = Process(), pipe = Pipe()
        p.executableURL = exe
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { p.environment = env }
        p.standardOutput = pipe
        p.standardError = stderr ? pipe : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        // Drain while it runs, so a large output can't fill the pipe and stall it.
        let buffer = Buffer()
        DispatchQueue.global().async { buffer.data = pipe.fileHandleForReading.readDataToEndOfFile(); drained.signal() }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); exited.wait() }
        }
        // A child it started can keep the pipe open after it exits; don't wait on that.
        let data = drained.wait(timeout: .now() + 1) == .success ? buffer.data : Data()
        return Output(status: p.terminationStatus, output: data, timedOut: timedOut)
    }

    static func run(_ exe: URL, _ args: [String], cwd: String? = nil, env: [String: String]? = nil,
                    stderr: Bool = false, timeout: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global().async {
                c.resume(with: Result { try run(exe, args, cwd: cwd, env: env, stderr: stderr, timeout: timeout) })
            }
        }
    }

    private final class Buffer: @unchecked Sendable { var data = Data() }
}
