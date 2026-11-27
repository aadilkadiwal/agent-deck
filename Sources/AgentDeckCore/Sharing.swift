import Foundation

public struct RecentUse: Equatable, Sendable {
    public var tokens: [String: Int] = [:]
    public var activeMinutes = Set<Int>()
    public var stoppedAtLimit = Set<String>()

    public init() {}

    // ponytail: reads the last 4 MB of each transcript; a session writing more than that in an hour is undercounted.
    public static func load(_ files: [String: URL], since: Date) -> RecentUse {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var r = RecentUse()
        for (id, url) in files {
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 4_000_000 ? size - 4_000_000 : 0)
            guard let data = try? h.readToEnd() else { continue }
            var seen = Set<String>(), stopped = false
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let msg = o["message"] as? [String: Any]
                switch o["type"] as? String {
                case "assistant": stopped = o["error"] as? String == "rate_limit"
                case "user" where o["isMeta"] as? Bool != true && !isToolResult(msg): stopped = false
                default: continue
                }
                guard let ts = (o["timestamp"] as? String).flatMap(iso.date(from:)), ts >= since,
                      let u = msg?["usage"] as? [String: Any] else { continue }
                if let mid = msg?["id"] as? String, !seen.insert(mid).inserted { continue }
                let n = ["input_tokens", "output_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
                guard n > 0 else { continue }
                r.tokens[id, default: 0] += n
                r.activeMinutes.insert(Int(ts.timeIntervalSince1970 / 60))
            }
            if stopped { r.stoppedAtLimit.insert(id) }
        }
        return r
    }

    static func isToolResult(_ msg: [String: Any]?) -> Bool {
        (msg?["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "tool_result" } ?? false
    }
}

// The account's numbers cover every Mac on the login, this Mac's transcripts only this Mac,
// so a rise with no reply written here came from somewhere else.
public enum SharedUse {
    public struct Split: Equatable, Sendable {
        public var mine = 0.0, others = 0.0
        public var total: Double { mine + others }
    }

    // ponytail: a rise while both Macs were busy counts as this Mac's, so other Macs are undercounted then.
    public static func split(_ samples: [UsageSample], key: String, since: Date, activeMinutes: Set<Int>) -> Split {
        let s = samples.filter { $0.key == key }.sorted { $0.at < $1.at }
        var out = Split()
        for (a, b) in zip(s, s.dropFirst()) where b.at > since && b.percent > a.percent && Forecast.sameWindow(a.resetsAt, b.resetsAt) {
            // A reply counts a minute early: the reading can land just before the transcript line.
            let from = Int(max(a.at, since).timeIntervalSince1970 / 60) - 1, to = Int(b.at.timeIntervalSince1970 / 60)
            if (from...max(from, to)).contains(where: activeMinutes.contains) { out.mine += b.percent - a.percent }
            else { out.others += b.percent - a.percent }
        }
        return out
    }
}
