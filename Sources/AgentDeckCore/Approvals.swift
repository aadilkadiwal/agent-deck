import Foundation

/// Sent by `scripts/hook.py` as `{"kind": ..., "payload": <the hook's stdin JSON>}`.
public struct ApprovalRequest: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case permission, question, plan }
    public struct Option: Equatable, Sendable { public let label: String; public let description: String }
    public struct Question: Equatable, Sendable {
        public let question: String
        public let multiSelect: Bool
        public let options: [Option]
    }

    public let id: Int
    public let kind: Kind
    public let agent: Agent
    public let pid: Int32?
    public let sessionId: String
    public let cwd: String
    public let toolName: String
    public let detail: String
    public let description: String?
    public let alwaysLabel: String?
    public let questions: [Question]
    /// From the whole command: `detail` is cut to 4000 characters.
    public let risk: String?
    public let receivedAt = Date()

    private static let maxDetail = 4000

    public static let shellTools: Set<String> = ["Bash", "shell", "exec_command", "local_shell"]

    public static func parse(_ data: Data, id: Int) -> ApprovalRequest? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = (o["kind"] as? String).flatMap(Kind.init),
              let p = o["payload"] as? [String: Any],
              let sid = p["session_id"] as? String, !sid.isEmpty else { return nil }
        let tool = p["tool_name"] as? String ?? ""
        let input = p["tool_input"] as? [String: Any] ?? [:]
        let questions = kind == .question ? parseQuestions(input["questions"]) : []
        if kind == .question && questions.isEmpty { return nil }
        let detail: String
        var risk: String?
        switch kind {
        case .permission:
            detail = summary(tool: tool, input: input)
            if shellTools.contains(tool) { risk = Risk.of(command: detail) }
        case .plan: detail = input["plan"] as? String ?? ""
        case .question: detail = ""
        }
        return ApprovalRequest(
            id: id, kind: kind, agent: (o["agent"] as? String).flatMap(Agent.init) ?? .claude,
            pid: (o["pid"] as? NSNumber)?.int32Value, sessionId: sid, cwd: p["cwd"] as? String ?? "", toolName: tool,
            detail: String(detail.prefix(maxDetail)),
            description: (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            alwaysLabel: kind == .permission ? alwaysLabel(p["permission_suggestions"]) : nil,
            questions: questions,
            risk: risk
        )
    }

    static func summary(tool: String, input: [String: Any]) -> String {
        func lines(_ prefix: String, _ text: Any?) -> [String] {
            ((text as? String) ?? "").split(separator: "\n", omittingEmptySubsequences: false).prefix(60).map { prefix + $0 }
        }
        if let cmd = input["command"] as? String { return cmd }
        // Codex sends its command as an argument list.
        if let args = input["command"] as? [String] { return args.joined(separator: " ") }
        if let path = (input["file_path"] ?? input["notebook_path"]) as? String {
            var out: [String] = []
            switch tool {
            case "Edit": out = lines("- ", input["old_string"]) + lines("+ ", input["new_string"])
            case "MultiEdit":
                for e in input["edits"] as? [[String: Any]] ?? [] { out += lines("- ", e["old_string"]) + lines("+ ", e["new_string"]) }
            case "Write": out = lines("+ ", input["content"])
            case "NotebookEdit": out = lines("+ ", input["new_source"])
            default: break
            }
            return ([path] + out).joined(separator: "\n")
        }
        if let url = input["url"] as? String { return url }
        guard !input.isEmpty, let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    private static func alwaysLabel(_ suggestions: Any?) -> String? {
        let rules = (suggestions as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "addRules" && $0["behavior"] as? String == "allow" }
            .flatMap { $0["rules"] as? [[String: Any]] ?? [] }
            .compactMap { r -> String? in
                guard let name = r["toolName"] as? String else { return nil }
                let content = r["ruleContent"] as? String ?? ""
                return content.isEmpty ? name : "\(name)(\(content))"
            }
        return rules.isEmpty ? nil : rules.joined(separator: ", ")
    }

    private static func parseQuestions(_ raw: Any?) -> [Question] {
        var out: [Question] = []
        for q in raw as? [[String: Any]] ?? [] {
            guard let text = q["question"] as? String else { return [] }
            let options = (q["options"] as? [Any] ?? []).compactMap { o -> Option? in
                if let s = o as? String { return Option(label: s, description: "") }
                guard let d = o as? [String: Any], let l = d["label"] as? String else { return nil }
                return Option(label: l, description: d["description"] as? String ?? "")
            }
            guard !options.isEmpty else { return [] }
            out.append(Question(question: text, multiSelect: q["multiSelect"] as? Bool ?? false, options: options))
        }
        return out
    }
}

/// A heuristic: a command it doesn't flag isn't proven safe.
public enum Risk {
    // Matches only where a command starts, so `git rm -r` or "sudo" in a commit message don't count.
    private static let start = #"(^|[;&|(\n]\s*|\b(sudo|xargs|then|do|exec)\s+)"#
    private static let rmRecursive = start + #"(\S*/)?rm\s+(-{1,2}[a-zA-Z-]+\s+)*(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)\b"#

    private static let rules: [(pattern: String, reason: String)] = [
        (rmRecursive + #"[^;&|]*\s(\.\.|/|~)"#, "deletes files outside the folder"),
        (rmRecursive, "deletes folders"),
        (#"\bgit\s+push\b[^;&|]*(\s--force\b|\s-f\b|\s--force-with-lease\b|\s\+\S)"#, "force-pushes"),
        (#"\bgit\s+reset\s+[^;&|]*--hard\b"#, "throws away local changes"),
        (#"\bgit\s+clean\s+[^;&|]*-[a-zA-Z]*f"#, "deletes untracked files"),
        (#"\bgit\s+(checkout|restore)\s+(--\s+)?\.(\s|$)"#, "throws away local changes"),
        (#"\bgit\s+branch\s+[^;&|]*-D\b"#, "deletes a branch"),
        (#"(^|[;&|(\n]\s*)sudo\s"#, "runs as administrator"),
        (#"\b(curl|wget)\b[^;&]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#, "runs a downloaded script"),
        (#"\b(mkfs|diskutil\s+(erase|partition)|dd\s+[^;&|]*of=/dev/)"#, "writes to a disk"),
        (#"\bchmod\s+(-R\s+)?[0-7]*777\b"#, "makes files writable by everyone"),
        (#"(?i)\b(drop\s+(table|database|schema)|truncate\s+table)\s+[\w"`\[]"#, "deletes database data"),
        (#"\bfind\b[^;&|]*\s-delete\b"#, "deletes files"),
    ]

    public static func of(command: String) -> String? {
        rules.first { command.range(of: $0.pattern, options: .regularExpression) != nil }?.reason
    }
}

/// `.terminal` makes the hook print nothing, so Claude Code's own prompt decides.
public enum ApprovalAnswer: Equatable, Sendable {
    case allow(always: Bool)
    case deny
    case denyWith(reason: String)
    /// Question text → label; multi-select labels joined with ", ", as the terminal does.
    case answers([String: String])
    case acceptEdits
    case terminal

    public var json: Data {
        let o: [String: Any]
        switch self {
        case .allow(let always): o = ["decision": "allow", "always": always]
        case .deny: o = ["decision": "deny"]
        case .denyWith(let reason): o = ["decision": "deny", "message": reason]
        case .acceptEdits: o = ["decision": "allow", "mode": "acceptEdits"]
        case .answers(let a): o = ["answers": a]
        case .terminal: o = [:]
        }
        return (try? JSONSerialization.data(withJSONObject: o, options: .sortedKeys)) ?? Data("{}".utf8)
    }
}

/// One connection per request: the hook sends one line and keeps the connection open until the app
/// answers. End-of-file before that means the hook went away, which `onGone` reports.
/// Only same-user peers are served (getpeereid), and the socket is 0600.
public final class ApprovalServer: @unchecked Sendable {
    public let path: String
    private let onRequest: @Sendable (ApprovalRequest) -> Void
    private let onGone: @Sendable (Int) -> Void
    private let onEvent: @Sendable (AgentEvent) -> Void
    private let queue = DispatchQueue(label: "agent-deck.approvals")
    private var listener: DispatchSourceRead?
    private var open: [Int: (fd: Int32, source: DispatchSourceRead)] = [:]
    /// Unique across launches, so a notification left from an earlier run can't answer a new prompt.
    private var nextId = Int(Date().timeIntervalSince1970 * 1000)

    private static let maxRequest = 1 << 20

    public init(path: String, onRequest: @escaping @Sendable (ApprovalRequest) -> Void, onGone: @escaping @Sendable (Int) -> Void,
                onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.path = path
        self.onRequest = onRequest
        self.onGone = onGone
        self.onEvent = onEvent
    }

    public enum Failure: LocalizedError {
        case socket(String)
        public var errorDescription: String? {
            switch self { case .socket(let why): return "Couldn't listen for approvals: \(why)" }
        }
    }

    public func start() throws {
        try queue.sync {
            guard listener == nil else { return }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.socket("path too long") }
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                buf.copyBytes(from: bytes)
                buf[bytes.count] = 0
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }
            unlink(path)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard ok == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
                let why = String(cString: strerror(errno))
                close(fd)
                unlink(path)
                throw Failure.socket(why)
            }
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.accept(fd) }
            src.setCancelHandler { close(fd) }
            src.resume()
            listener = src
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            unlink(path)
            for id in Array(open.keys) { reply(id, .terminal) }
        }
    }

    public func answer(_ id: Int, _ a: ApprovalAnswer) {
        queue.async { self.reply(id, a) }
    }

    private func reply(_ id: Int, _ a: ApprovalAnswer) {
        guard let c = open.removeValue(forKey: id) else { return }
        let data = a.json
        _ = data.withUnsafeBytes { write(c.fd, $0.baseAddress, $0.count) }
        c.source.cancel()   // closes fd
    }

    private func accept(_ listenFd: Int32) {
        let fd = Darwin.accept(listenFd, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        var on: Int32 = 1
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
        else { close(fd); return }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while data.count < Self.maxRequest, data.last != UInt8(ascii: "\n") {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], o["kind"] as? String == "event" {
            close(fd)
            if let e = AgentEvent.parse(o) { onEvent(e) }
            return
        }
        let id = nextId
        nextId += 1
        guard let req = ApprovalRequest.parse(data, id: id) else {
            _ = ApprovalAnswer.terminal.json.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            return
        }
        // The hook sends nothing more, so anything readable from here on is EOF: it's gone.
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, self.open.removeValue(forKey: id) != nil else { return }
            src.cancel()
            self.onGone(id)
        }
        src.setCancelHandler { close(fd) }
        open[id] = (fd, src)
        src.resume()
        onRequest(req)
    }
}
