import Foundation

public struct UsageSample: Codable, Equatable, Sendable {
    public let at: Date
    public let key: String        // five_hour, seven_day, ...
    public let percent: Double
    public let resetsAt: Date?
}

/// "At this pace you'll reach 100% at 3:40 PM" — worked out from recent readings in the same window.
public enum Forecast: Equatable, Sendable {
    case reachesLimit(at: Date)   // before the window resets
    case safeUntilReset           // won't reach 100% before the reset at this pace
    case unknown                  // not enough readings yet, or usage isn't rising

    static func lookback(for key: String) -> TimeInterval { key == "five_hour" ? 3600 : 24 * 3600 }

    public static func compute(_ window: LimitWindow, samples: [UsageSample]) -> Forecast {
        let now = Date()
        let pct = window.percent(at: now)
        if pct >= 100 { return .reachesLimit(at: now) }
        // Same window only: readings from before the last reset describe a different period.
        let recent = samples
            .filter { $0.key == window.key && $0.resetsAt == window.resetsAt && $0.at >= now.addingTimeInterval(-lookback(for: window.key)) }
            .sorted { $0.at < $1.at }
        guard let first = recent.first, let last = recent.last,
              last.at.timeIntervalSince(first.at) >= 10 * 60,     // at least 10 minutes of data
              last.percent > first.percent else { return .unknown }
        let perSecond = (last.percent - first.percent) / last.at.timeIntervalSince(first.at)
        let eta = now.addingTimeInterval((100 - pct) / perSecond)
        if let reset = window.resetsAt, eta >= reset { return .safeUntilReset }
        return .reachesLimit(at: eta)
    }
}

/// Small append-only log of readings (`~/.claude/agent-deck/usage-log.jsonl`), trimmed to 8 days:
/// one weekly window plus a day. Nothing older is kept.
public struct UsageLog: Sendable {
    public let url: URL
    public static let keep: TimeInterval = 8 * 24 * 3600

    public init(paths: ClaudePaths) { url = paths.appDir.appendingPathComponent("usage-log.jsonl") }

    public func load() -> [UsageSample] {
        let now = Date()
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? dec.decode(UsageSample.self, from: Data($0)) }
            .filter { $0.at >= now.addingTimeInterval(-Self.keep) }
    }

    @discardableResult
    public func record(_ snapshot: UsageSnapshot, existing: [UsageSample]) -> [UsageSample] {
        let now = Date()
        let added = snapshot.windows
            .map { UsageSample(at: snapshot.updatedAt, key: $0.key, percent: $0.usedPercent, resetsAt: $0.resetsAt) }
            .filter { s in existing.last(where: { $0.key == s.key }).map { $0.percent != s.percent || $0.resetsAt != s.resetsAt } ?? true }
        guard !added.isEmpty else { return existing }
        let fresh = (existing + added).filter { $0.at >= now.addingTimeInterval(-Self.keep) }
        let enc = JSONEncoder()
        let text = fresh.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
        return fresh
    }
}

public struct UsageHeatmap: Equatable, Sendable {
    /// [weekday][hour], weekday 0 = the calendar's first weekday.
    public var cells: [[Double]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    public var limitHits = 0
    public var weekdaySymbols: [String] = []
    public var peak: Double { cells.flatMap { $0 }.max() ?? 0 }

    /// A rise between readings further apart than this can't be placed in one hour.
    static let maxGap: TimeInterval = 2 * 3600

    public static func compute(_ samples: [UsageSample]) -> UsageHeatmap {
        let now = Date(), calendar = Calendar.current
        var m = UsageHeatmap()
        let symbols = calendar.shortWeekdaySymbols
        m.weekdaySymbols = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        let since = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(-6 * 86400)
        let five = samples.filter { $0.key == "five_hour" && $0.at >= since }.sorted { $0.at < $1.at }
        var hitWindows = Set<Date?>()
        for (prev, s) in zip(five, five.dropFirst()) where s.at.timeIntervalSince(prev.at) <= maxGap {
            // A rise inside the same window is usage; a drop or a new reset time is the window starting over.
            let rise = prev.resetsAt == s.resetsAt ? s.percent - prev.percent : s.percent
            guard rise > 0 else { continue }
            let day = (calendar.component(.weekday, from: s.at) - calendar.firstWeekday + 7) % 7
            m.cells[day][calendar.component(.hour, from: s.at)] += rise
        }
        for s in five where s.percent >= 100 { hitWindows.insert(s.resetsAt) }
        m.limitHits = hitWindows.count
        return m
    }

    public var busiest: (day: String, from: Int, to: Int)? {
        guard peak > 0, let d = cells.indices.max(by: { cells[$0].reduce(0, +) < cells[$1].reduce(0, +) }) else { return nil }
        let row = cells[d]
        guard let h = row.indices.max(by: { row[$0] < row[$1] }) else { return nil }
        var from = h, to = h
        while from > 0, row[from - 1] >= row[h] * 0.4 { from -= 1 }
        while to < 23, row[to + 1] >= row[h] * 0.4 { to += 1 }
        return (weekdaySymbols[d], from, to + 1)
    }
}
