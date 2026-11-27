import Foundation

public enum ClaudeSettings {
    public static let defaultRetentionDays = 30

    public static func retentionDays(_ paths: ClaudePaths) -> Int {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = o["cleanupPeriodDays"] as? NSNumber else { return defaultRetentionDays }
        return n.intValue
    }

    public enum Failure: LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Couldn't update ~/.claude/settings.json: \(why). Nothing was changed."
            }
        }
    }

    public static func setRetentionDays(_ days: Int, _ paths: ClaudePaths) throws {
        precondition(days > 0)
        try set("cleanupPeriodDays", days, paths)
    }

    static func model(_ paths: ClaudePaths) -> String? {
        (try? Data(contentsOf: paths.settingsFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["model"] as? String
    }

    static func setModel(_ model: String?, _ paths: ClaudePaths) throws { try set("model", model, paths) }

    static func set(_ key: String, _ value: Any?, _ paths: ClaudePaths) throws {
        let fm = FileManager.default
        let backup = paths.settingsFile.appendingPathExtension("agent-deck-backup")
        if !fm.fileExists(atPath: backup.path), let data = try? Data(contentsOf: paths.settingsFile) { try data.write(to: backup) }
        // Read as late as possible: Claude Code and other tools write this file too.
        var obj: [String: Any] = [:]
        if fm.fileExists(atPath: paths.settingsFile.path) {
            guard let o = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.settingsFile)) as? [String: Any] else {
                throw Failure.unreadable("it isn't a JSON object")
            }
            obj = o
        }
        obj[key] = value
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: paths.settingsFile, options: .atomic)
    }
}

/// Lasting "Always allow" rules added from Agent Deck, so Settings can list them and take them back.
/// Session rules aren't kept: they end with their session.
public struct AllowedRule: Codable, Equatable, Identifiable, Sendable {
    public let rule: String
    public let everywhere: Bool
    public let cwd: String
    public let at: Date
    public var id: String { "\(everywhere ? "" : cwd)|\(rule)" }

    public init(rule: String, everywhere: Bool, cwd: String, at: Date = Date()) {
        self.rule = rule; self.everywhere = everywhere; self.cwd = cwd; self.at = at
    }

    public func settingsFile(_ paths: ClaudePaths) -> URL {
        everywhere ? paths.settingsFile : URL(fileURLWithPath: cwd).appendingPathComponent(".claude/settings.local.json")
    }

    static func logFile(_ paths: ClaudePaths) -> URL { paths.appDir.appendingPathComponent("allowed-rules.json") }

    public static func load(_ paths: ClaudePaths) -> [AllowedRule] {
        (try? Data(contentsOf: logFile(paths))).flatMap { try? JSONDecoder().decode([AllowedRule].self, from: $0) } ?? []
    }

    public static func save(_ rules: [AllowedRule], _ paths: ClaudePaths) {
        try? FileManager.default.createDirectory(at: paths.appDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(rules).write(to: logFile(paths), options: .atomic)
    }

    /// Takes the rule out of `permissions.allow` in the file Claude Code wrote it to. A rule that's
    /// already gone (removed by hand) counts as removed.
    public func remove(_ paths: ClaudePaths) throws {
        let file = settingsFile(paths)
        guard let data = try? Data(contentsOf: file) else { return }
        guard var o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeSettings.Failure.unreadable("it isn't a JSON object")
        }
        var perms = o["permissions"] as? [String: Any] ?? [:]
        // Claude Code stores brackets inside a rule escaped (`print\(2\)`), so compare without them.
        let plain = { (r: String) in r.replacingOccurrences(of: "\\", with: "") }
        guard let allow = perms["allow"] as? [String], allow.contains(where: { plain($0) == plain(rule) }) else { return }
        perms["allow"] = allow.filter { plain($0) != plain(rule) }
        o["permissions"] = perms
        try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: file, options: .atomic)
    }
}
