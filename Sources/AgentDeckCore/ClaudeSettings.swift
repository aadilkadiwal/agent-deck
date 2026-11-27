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
