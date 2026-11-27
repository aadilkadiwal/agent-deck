import Foundation

public struct LimitWindow: Equatable, Sendable, Identifiable {
    public var id: String { key }
    // Readings like 99.7 show as 100%, and Claude Code stops there too.
    public static let full = 99.5
    public let key: String          // five_hour, seven_day, seven_day_opus, ...
    public let usedPercent: Double  // 0...100
    public let resetsAt: Date?

    public var label: String {
        switch key {
        case "five_hour": return "5-hour"
        case "seven_day": return "Weekly"
        case "seven_day_opus": return "Weekly · Opus"
        case "seven_day_sonnet": return "Weekly · Sonnet"
        case "spend_limit": return "Spend limit"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Once the reset time has passed the window is empty again, even before Claude Code reports it.
    public func percent(at now: Date = Date()) -> Double {
        if let r = resetsAt, r <= now { return 0 }
        return usedPercent
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let windows: [LimitWindow]
    public let model: String?
    public let updatedAt: Date

    public func window(_ key: String) -> LimitWindow? { windows.first { $0.key == key } }
    public var fiveHour: LimitWindow? { window("five_hour") }
    public var weekly: LimitWindow? { window("seven_day") }

    static let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "spend_limit"]

    public static func parse(_ data: Data, updatedAt: Date) -> UsageSnapshot? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = o["rate_limits"] as? [String: Any] else { return nil }
        var windows: [LimitWindow] = rl.compactMap { key, value in
            guard let w = value as? [String: Any], let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return LimitWindow(key: key, usedPercent: min(max(pct, 0), 100), resetsAt: reset)
        }
        guard !windows.isEmpty else { return nil }
        // Claude Code omits a window that isn't running (e.g. 5-hour after a reset): show it at 0%.
        for key in ["five_hour", "seven_day"] where !windows.contains(where: { $0.key == key }) {
            windows.append(LimitWindow(key: key, usedPercent: 0, resetsAt: nil))
        }
        windows.sort { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }
        let model = (o["model"] as? [String: Any])?["display_name"] as? String
        return UsageSnapshot(windows: windows, model: model, updatedAt: updatedAt)
    }

    public static func load(_ paths: ClaudePaths) -> UsageSnapshot? {
        let url = paths.statusFile
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return parse(data, updatedAt: mtime)
    }

    // Usage only goes up within a period, but an idle session's status line repeats the numbers from
    // its last reply. So a lower reading for the same period, or one for an earlier period, is old.
    public func keepingNewest(_ old: UsageSnapshot?) -> UsageSnapshot {
        guard let old else { return self }
        let now = Date()
        let ws = windows.map { w -> LimitWindow in
            guard let o = old.window(w.key), let oReset = o.resetsAt, oReset > now else { return w }
            guard let reset = w.resetsAt, reset > oReset.addingTimeInterval(-60) else { return o }
            return Forecast.sameWindow(reset, oReset) && w.usedPercent < o.usedPercent ? o : w
        }
        return UsageSnapshot(windows: ws, model: model, updatedAt: updatedAt)
    }
}

public enum ClaudeAccount {
    public static func current() -> String? {
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        let o = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (o?["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
    }
}

public struct ContextReading: Equatable, Sendable {
    public let percent: Int
    public let updatedAt: Date
}

public enum ContextUsage {
    static func parse(_ data: Data) -> Int? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pct = ((o["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
        return Int(min(max(pct, 0), 100).rounded())
    }

    public static func load(_ paths: ClaudePaths, sessionId: String) -> ContextReading? {
        let url = paths.contextDir.appendingPathComponent("\(sessionId).json")
        guard let pct = (try? Data(contentsOf: url)).flatMap(parse) else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return ContextReading(percent: pct, updatedAt: mtime)
    }
}

public enum AccountUsage {
    public enum Result: Equatable, Sendable { case ok(UsageSnapshot), signedOut, expired, rateLimited, failed }

    public static func fetch() async -> Result {
        guard let auth = token() else { return .signedOut }
        guard auth.expires > Date() else { return .expired }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return .failed }
        switch (resp as? HTTPURLResponse)?.statusCode {
        case 401: return .expired
        case 429: return .rateLimited
        default: break
        }
        return parse(data).map(Result.ok) ?? .failed
    }

    static func parse(_ data: Data) -> UsageSnapshot? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var windows: [LimitWindow] = UsageSnapshot.order.compactMap { key in
            guard let w = o[key] as? [String: Any], let pct = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (w["resets_at"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            return LimitWindow(key: key, usedPercent: min(max(pct, 0), 100), resetsAt: reset)
        }
        guard !windows.isEmpty else { return nil }
        for key in ["five_hour", "seven_day"] where !windows.contains(where: { $0.key == key }) {
            windows.append(LimitWindow(key: key, usedPercent: 0, resetsAt: nil))
        }
        windows.sort { (UsageSnapshot.order.firstIndex(of: $0.key) ?? 99) < (UsageSnapshot.order.firstIndex(of: $1.key) ?? 99) }
        return UsageSnapshot(windows: windows, model: nil, updatedAt: Date())
    }

    static func token() -> (token: String, expires: Date)? {
        let keychain = try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/security"),
                                           ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 10)
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        let data = keychain.flatMap { $0.status == 0 ? $0.output : nil } ?? (try? Data(contentsOf: file))
        guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = o["claudeAiOauth"] as? [String: Any], let t = a["accessToken"] as? String,
              let ms = (a["expiresAt"] as? NSNumber)?.doubleValue else { return nil }
        return (t, Date(timeIntervalSince1970: ms / 1000))
    }
}
