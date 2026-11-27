import Foundation

public struct AgentEvent: Sendable {
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
            name: name, sessionId: sid,
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
