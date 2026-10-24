import Foundation

public struct HistorySession: Identifiable, Equatable, Sendable {
    public var id: String { sessionId }
    public let sessionId: String
    public let fileURL: URL
    public var cwd: String
    public var name: String
    public var lastPrompt: String?
    public var model: String?
    public var lastActive: Date
    public var bytes: Int64
    public var branch: String? = nil
    public var firstAt: Date? = nil
    public var lastAt: Date? = nil
    public var shortId: String { String(sessionId.prefix(8)) }
    public var duration: TimeInterval? { firstAt.flatMap { f in lastAt.map { $0.timeIntervalSince(f) } } }
    /// Opened and closed without a reply from Claude. Small files are read whole, so "no model
    /// seen" is reliable for them.
    public var isEmpty: Bool { model == nil && bytes < Int64(HistoryScanner.chunk) }
}

/// Reads only the head and tail of each transcript (they can be tens of MB) and caches by
/// mtime+size, so rescanning a few hundred sessions every minute costs almost nothing.
public final class HistoryScanner: @unchecked Sendable {
    private let paths: ClaudePaths
    private var cache: [URL: (stamp: String, session: HistorySession)] = [:]
    private let lock = NSLock()
    static let chunk = 128 * 1024

    public init(paths: ClaudePaths) { self.paths = paths }

    public func scan() -> [HistorySession] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let projects = (try? fm.contentsOfDirectory(at: paths.projectsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [HistorySession] = []
        lock.lock(); defer { lock.unlock() }
        var fresh: [URL: (String, HistorySession)] = [:]
        for dir in projects {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            for url in files where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      let mtime = v.contentModificationDate else { continue }
                let size = Int64(v.fileSize ?? 0)
                let stamp = "\(mtime.timeIntervalSince1970)-\(size)"
                let s: HistorySession
                if let c = cache[url], c.stamp == stamp { s = c.session }
                else if let parsed = Self.parse(url: url, mtime: mtime, size: size, folderSlug: dir.lastPathComponent) { s = parsed }
                else { continue }
                fresh[url] = (stamp, s)
                out.append(s)
            }
        }
        cache = fresh
        return out.sorted { $0.lastActive > $1.lastActive }
    }

    static func parse(url: URL, mtime: Date, size: Int64, folderSlug: String) -> HistorySession? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: chunk)) ?? Data()
        var tail = Data()
        if size > Int64(chunk) {
            try? fh.seek(toOffset: UInt64(max(Int64(chunk), size - Int64(chunk))))
            tail = (try? fh.readToEnd()) ?? Data()
        }
        return parse(chunks: [head, tail], sessionId: url.deletingPathExtension().lastPathComponent,
                     url: url, mtime: mtime, size: size, folderSlug: folderSlug)
    }

    /// Later lines win, so pass chunks in file order.
    static func parse(chunks: [Data], sessionId: String, url: URL, mtime: Date, size: Int64, folderSlug: String) -> HistorySession? {
        var cwd: String?, custom: String?, agent: String?, ai: String?, prompt: String?, model: String?, branch: String?
        var firstAt: Date?, lastAt: Date?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for chunk in chunks {
            for line in chunk.split(separator: UInt8(ascii: "\n")) {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if cwd == nil, let c = o["cwd"] as? String { cwd = c }
                if let b = o["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { branch = b }
                if let t = o["type"] as? String, t == "user" || t == "assistant",
                   let ts = (o["timestamp"] as? String).flatMap(iso.date(from:)) {
                    firstAt = firstAt ?? ts
                    lastAt = ts
                }
                switch o["type"] as? String {
                case "custom-title": custom = (o["customTitle"] as? String) ?? custom
                case "agent-name": agent = (o["agentName"] as? String) ?? agent
                case "ai-title": ai = (o["aiTitle"] as? String) ?? ai
                case "last-prompt": prompt = (o["lastPrompt"] as? String) ?? prompt
                case "assistant":
                    if let m = (o["message"] as? [String: Any])?["model"] as? String, m != "<synthetic>" { model = m }
                default: break
                }
            }
        }
        let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = [custom, agent, ai, p.map { String($0.prefix(60)) }]
            .compactMap { $0 }.first { !$0.isEmpty } ?? String(sessionId.prefix(8))
        return HistorySession(sessionId: sessionId, fileURL: url, cwd: cwd ?? folderSlug, name: name,
                              lastPrompt: p, model: model, lastActive: mtime, bytes: size,
                              branch: branch, firstAt: firstAt, lastAt: lastAt)
    }

    /// Renames a closed session the way Claude Code's /rename does: a `custom-title` line at the end.
    public static func rename(_ s: HistorySession, to name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let line = try JSONSerialization.data(withJSONObject: ["type": "custom-title", "customTitle": title, "sessionId": s.sessionId],
                                              options: [.withoutEscapingSlashes])
        let fh = try FileHandle(forUpdating: s.fileURL)
        defer { try? fh.close() }
        let end = try fh.seekToEnd()
        var prefix = Data()
        if end > 0 {
            try fh.seek(toOffset: end - 1)
            if try fh.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) { prefix = Data([UInt8(ascii: "\n")]) }
        }
        try fh.seekToEnd()
        try fh.write(contentsOf: prefix + line + Data([UInt8(ascii: "\n")]))
    }

    /// Transcript first: if that fails nothing else is touched.
    public static func trash(_ s: HistorySession, paths: ClaudePaths) throws -> [Leftovers.Moved] {
        let all = Leftovers.allPaths(s, paths)
        var landed: NSURL?
        try FileManager.default.trashItem(at: s.fileURL, resultingItemURL: &landed)
        let rest = Leftovers.moveToTrash(all.filter { $0 != s.fileURL }).moved
        return (landed.map { [(s.fileURL, $0 as URL)] } ?? []) + rest
    }
}

public enum ActiveRange: String, CaseIterable, Identifiable, Sendable {
    case any = "Any time", today = "Today", week = "Last 7 days", olderThanWeek = "Older than 7 days", olderThanMonth = "Older than 30 days"
    public var id: String { rawValue }

    public func matches(_ d: Date) -> Bool {
        let now = Date(), calendar = Calendar.current
        let age = now.timeIntervalSince(d)
        switch self {
        case .any: return true
        case .today: return calendar.isDate(d, inSameDayAs: now)
        case .week: return age <= 7 * 86400
        case .olderThanWeek: return age > 7 * 86400
        case .olderThanMonth: return age > 30 * 86400
        }
    }
}

public struct SessionDetail: Equatable, Sendable {
    public var prompts = 0
    public var lastReply: String?
    public var firstAt: Date?
    public var lastAt: Date?
    public var tokens = 0
    public var duration: TimeInterval? { firstAt.flatMap { f in lastAt.map { $0.timeIntervalSince(f) } } }

    public static func load(_ url: URL) -> SessionDetail {
        guard let data = try? Data(contentsOf: url) else { return SessionDetail() }
        return parse(data)
    }

    static func parse(_ data: Data, since: Date? = nil) -> SessionDetail {
        var d = SessionDetail()
        var seen = Set<String>()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let type = o["type"] as? String
            guard type == "user" || type == "assistant" else { continue }
            let ts = (o["timestamp"] as? String).flatMap(iso.date(from:))
            if let ts {
                d.firstAt = d.firstAt ?? ts
                d.lastAt = ts
            }
            let msg = o["message"] as? [String: Any]
            if type == "user" {
                // Real prompts only: tool results also arrive as "user" lines, as content arrays.
                if msg?["content"] is String, o["isMeta"] as? Bool != true { d.prompts += 1 }
                continue
            }
            let inWindow = since.map { s in ts.map { $0 >= s } ?? false } ?? true
            if inWindow, let id = msg?["id"] as? String, seen.insert(id).inserted, let u = msg?["usage"] as? [String: Any] {
                d.tokens += ["input_tokens", "output_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
            }
            if let parts = msg?["content"] as? [[String: Any]],
               let text = parts.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                d.lastReply = text
            }
        }
        return d
    }
}

/// Tokens per project folder since a date. Reads whole transcripts, but only those touched since then.
public enum ProjectUsage {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let folder: String
        public let tokens: Int
        public var id: String { folder }
    }

    public static func load(_ sessions: [HistorySession], since: Date) -> [Entry] {
        var by: [String: Int] = [:]
        for s in sessions where s.lastActive >= since {
            guard let data = try? Data(contentsOf: s.fileURL) else { continue }
            let n = SessionDetail.parse(data, since: since).tokens
            if n > 0 { by[s.cwd, default: 0] += n }
        }
        return by.map { Entry(folder: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
    }
}

public struct Conversation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case prompt, reply, tool, command }
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: Int
        public let kind: Kind
        public let text: String
        public let at: Date?
    }
    public struct File: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public let path: String
        public let created: Bool
    }

    public var entries: [Entry] = []
    public var files: [File] = []
    public var dropped = 0

    static let maxText = 1500
    static let notPrompt = ["<local-command-", "<command-", "<system-reminder>", "<bash-", "<user-memory-input>", "<task-notification>"]
    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// Reads a transcript as it grows: each `read()` parses only the lines added since the last one.
    public struct Reader: Sendable {
        public let url: URL
        private var offset: UInt64 = 0
        private var entries: [Entry] = []
        private var order: [String] = []
        private var created = Set<String>()

        public init(url: URL) { self.url = url }

        public var conversation: Conversation {
            var c = Conversation()
            c.dropped = max(0, entries.count - limit)
            c.entries = Array(entries.suffix(limit))
            c.files = order.map { File(path: $0, created: created.contains($0)) }
            return c
        }

        private let limit = 300

        public mutating func read() {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? fh.close() }
            // A file shorter than what was read was rewritten, not appended to: start over.
            if let end = try? fh.seekToEnd(), end < offset { self = Reader(url: url) }
            guard (try? fh.seek(toOffset: offset)) != nil, let data = try? fh.readToEnd(), !data.isEmpty,
                  let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
            // A line still being written has no newline yet; it's read next time.
            let complete = data[data.startIndex...lastNewline]
            offset += UInt64(complete.count)
            parse(complete)
        }

        private mutating func add(_ kind: Kind, _ text: String, _ at: Date?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            entries.append(Entry(id: entries.count, kind: kind, text: t.count > maxText ? String(t.prefix(maxText)) + "…" : t, at: at))
        }

        private mutating func parse(_ data: Data) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      o["isSidechain"] as? Bool != true else { continue }
                let type = o["type"] as? String
                guard type == "user" || type == "assistant" else { continue }
                let at = (o["timestamp"] as? String).flatMap(iso.date(from:))
                let content = (o["message"] as? [String: Any])?["content"]
                if type == "user" {
                    if let r = o["toolUseResult"] as? [String: Any], r["type"] as? String == "create", let p = r["filePath"] as? String { created.insert(p) }
                    guard o["isMeta"] as? Bool != true, o["isCompactSummary"] as? Bool != true else { continue }
                    let text: String
                    if let s = content as? String { text = s }
                    else if let parts = content as? [[String: Any]], !parts.contains(where: { $0["type"] as? String == "tool_result" }) {
                        text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                    } else { continue }
                    if let cmd = command(text) { add(.command, cmd, at) }
                    else if text.hasPrefix("[Request interrupted") { add(.command, "Interrupted", at) }
                    else if !notPrompt.contains(where: text.hasPrefix) { add(.prompt, text, at) }
                    continue
                }
                for part in content as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "text": add(.reply, part["text"] as? String ?? "", at)
                    case "tool_use":
                        let name = part["name"] as? String ?? "Tool"
                        let input = part["input"] as? [String: Any] ?? [:]
                        if editTools.contains(name), let p = (input["file_path"] ?? input["notebook_path"]) as? String, !order.contains(p) { order.append(p) }
                        add(.tool, toolLine(name, input), at)
                    default: break
                    }
                }
            }
        }
    }

    /// "<command-name>/clear</command-name>…" → "/clear"; other tags are output, not prompts.
    static func command(_ text: String) -> String? {
        guard let r = text.range(of: "<command-name>"), let e = text.range(of: "</command-name>", range: r.upperBound..<text.endIndex) else { return nil }
        let name = String(text[r.upperBound..<e.lowerBound])
        let args = text.range(of: "<command-args>").flatMap { a in
            text.range(of: "</command-args>", range: a.upperBound..<text.endIndex).map { String(text[a.upperBound..<$0.lowerBound]) }
        } ?? ""
        return args.isEmpty ? name : "\(name) \(args)"
    }

    static func toolLine(_ name: String, _ input: [String: Any]) -> String {
        let firstLine = { (s: String) in s.split(separator: "\n").first.map(String.init) ?? s }
        let detail: String?
        if let p = (input["file_path"] ?? input["notebook_path"]) as? String { detail = (p as NSString).lastPathComponent }
        else if let c = input["command"] as? String { detail = firstLine(c) }
        else if let d = input["description"] as? String { detail = d }
        else if let q = (input["pattern"] ?? input["query"] ?? input["url"] ?? input["prompt"]) as? String { detail = firstLine(q) }
        else { detail = nil }
        guard let detail, !detail.isEmpty else { return name }
        return "\(name) · \(detail.count > 120 ? String(detail.prefix(120)) + "…" : detail)"
    }
}
