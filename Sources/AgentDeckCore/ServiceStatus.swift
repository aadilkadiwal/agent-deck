import Foundation

/// Anthropic's public status page, read only for the parts a Claude Code session depends on.
public struct ServiceStatus: Equatable, Sendable {
    public let text: String
    public let link: URL

    static let feed = URL(string: "https://status.claude.com/api/v2/summary.json")!
    static func watched(_ name: String) -> Bool { name == "Claude Code" || name.hasPrefix("Claude API") }

    /// nil when Claude Code and the API are both operational, or when the page can't be read.
    public static func fetch() async -> ServiceStatus? {
        var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> ServiceStatus? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let components = o["components"] as? [[String: Any]] else { return nil }
        let down = components.filter { watched($0["name"] as? String ?? "") && ($0["status"] as? String ?? "operational") != "operational" }
        guard let worst = down.max(by: { rank($0["status"]) < rank($1["status"]) }), let name = worst["name"] as? String else { return nil }
        let page = (o["page"] as? [String: Any])?["url"] as? String ?? "https://status.claude.com"
        let incident = (o["incidents"] as? [[String: Any]] ?? []).first { i in
            (i["components"] as? [[String: Any]] ?? []).contains { watched($0["name"] as? String ?? "") }
        }
        let who = name.hasPrefix("Claude API") ? "the Claude API" : name
        let what = "Anthropic reports " + ((incident?["name"] as? String).map { $0.prefix(1).lowercased() + $0.dropFirst() } ?? "\(phrase(worst["status"])) \(who)") + "."
        let link = (incident?["shortlink"] as? String).flatMap(URL.init(string:)) ?? URL(string: page)!
        return ServiceStatus(text: what, link: link)
    }

    private static func rank(_ status: Any?) -> Int {
        ["under_maintenance": 1, "degraded_performance": 2, "partial_outage": 3, "major_outage": 4][status as? String ?? ""] ?? 0
    }

    private static func phrase(_ status: Any?) -> String {
        switch status as? String {
        case "degraded_performance": "slower replies from"
        case "partial_outage": "a partial outage of"
        case "major_outage": "a major outage of"
        case "under_maintenance": "maintenance on"
        default: "problems with"
        }
    }
}
