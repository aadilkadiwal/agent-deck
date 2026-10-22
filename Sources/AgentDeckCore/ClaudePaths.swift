import Foundation

public struct ClaudePaths: Sendable {
    public let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    public let tmpDir = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())")

    public init() {}

    public var sessionsDir: URL { claudeDir.appendingPathComponent("sessions") }
    public var projectsDir: URL { claudeDir.appendingPathComponent("projects") }
    public var fileHistoryDir: URL { claudeDir.appendingPathComponent("file-history") }
    public var sessionEnvDir: URL { claudeDir.appendingPathComponent("session-env") }
    public var debugDir: URL { claudeDir.appendingPathComponent("debug") }
    public var todosDir: URL { claudeDir.appendingPathComponent("todos") }
    public var tasksDir: URL { claudeDir.appendingPathComponent("tasks") }
    public var settingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    public var appDir: URL { claudeDir.appendingPathComponent("agent-deck") }
    public var statusFile: URL { appDir.appendingPathComponent("status.json") }
    public var contextDir: URL { appDir.appendingPathComponent("context") }
    public var approvalSocket: URL { appDir.appendingPathComponent("approvals.sock") }
}
