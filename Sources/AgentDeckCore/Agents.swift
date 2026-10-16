import Foundation

public enum Agent: String, Sendable {
    case claude, codex, gemini
    public var label: String { rawValue.capitalized }
}

public struct AgentEvent: Sendable {
    public let agent: Agent
    public let name: String
    public let sessionId: String
    public let cwd: String
    public let pid: Int32?
    public let toolName: String?
    public let toolSummary: String?
    public let subagentId: String?

    static func parse(_ o: [String: Any]) -> AgentEvent? {
        guard let name = o["event"] as? String, let p = o["payload"] as? [String: Any],
              let sid = p["session_id"] as? String, !sid.isEmpty else { return nil }
        let tool = p["tool_name"] as? String
        return AgentEvent(
            agent: (o["agent"] as? String).flatMap(Agent.init) ?? .claude, name: name, sessionId: sid,
            cwd: p["cwd"] as? String ?? "", pid: (o["pid"] as? NSNumber)?.int32Value,
            toolName: tool, toolSummary: tool.map { ApprovalRequest.summary(tool: $0, input: p["tool_input"] as? [String: Any] ?? [:]) },
            subagentId: p["agent_id"] as? String)
    }
}

public enum Git {
    public static func branch(_ cwd: String) -> String? {
        var dir = URL(fileURLWithPath: cwd)
        while dir.path != "/" {
            let git = dir.appendingPathComponent(".git")
            var gitDir = git
            // A worktree or submodule has a .git file pointing at the real folder.
            if let link = try? String(contentsOf: git, encoding: .utf8), link.hasPrefix("gitdir:") {
                let path = link.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                gitDir = URL(fileURLWithPath: path, relativeTo: dir)
            }
            if let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) {
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                return h.hasPrefix("ref: refs/heads/") ? String(h.dropFirst(16)) : String(h.prefix(7))
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

/// Codex's own usage limits, from the `token_count` events it writes to its session files
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`). No login or network needed.
public enum CodexUsage {
    public struct Limit: Equatable, Sendable, Identifiable {
        public var id: String { label }
        public let label: String
        public let percent: Double
        public let resetsAt: Date?
    }

    public static func load() -> [Limit] {
        for file in newestSessionFiles(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")).prefix(5) {
            if let limits = lastLimits(in: file) { return limits }
        }
        return []
    }

    static func newestSessionFiles(_ root: URL) -> [URL] {
        let fm = FileManager.default
        func children(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        for year in children(root) { for month in children(year) { for day in children(month) {
            let files = children(day).filter { $0.pathExtension == "jsonl" }
            let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            if !files.isEmpty { return dated.sorted { $0.1 > $1.1 }.map(\.0) }
        } } }
        return []
    }

    static func lastLimits(in file: URL) -> [Limit]? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let limits = parse(Data(line.utf8)) { return limits }
        }
        return nil
    }

    static func parse(_ line: Data) -> [Limit]? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let p = o["payload"] as? [String: Any], let r = p["rate_limits"] as? [String: Any],
              (r["limit_id"] as? String ?? "codex") == "codex" else { return nil }
        // primary/secondary aren't fixed to 5-hour/weekly (a free plan has one 30-day window), so label by length.
        let limits = ["primary", "secondary"].compactMap { key -> Limit? in
            guard let w = r[key] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
            let label = minutes == 300 ? "5-hour" : minutes == 10080 ? "Weekly" : minutes >= 40000 ? "Monthly" : "\(max(minutes / 60, 1))-hour"
            return Limit(label: label, percent: pct, resetsAt: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        return limits.isEmpty ? nil : limits
    }
}
