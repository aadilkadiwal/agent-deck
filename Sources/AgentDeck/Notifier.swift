import Foundation
import AgentDeckCore
import UserNotifications

/// macOS notifications: a session needs you, a long task finished, a usage limit is getting close.
/// Each kind can be switched off in Settings.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Key {
        static let waiting = "notifyWaiting", finished = "notifyFinished", limits = "notifyLimits"
        static let fired = "firedLimitWarnings", warnAt = "limitWarnAt"
    }
    static var warnAt: Double {
        let v = UserDefaults.standard.double(forKey: Key.warnAt)
        return (1...99).contains(v) ? v : 80
    }
    /// A reply shorter than this isn't worth a "finished" notification.
    static let longTask: TimeInterval = 60

    var onOpen: ((String) -> Void)?
    var onAnswer: ((Int, ApprovalAnswer) -> Void)?
    var onSwitch: (() -> Void)?
    var hasApproval: ((String) -> Bool)?
    private var busySince: [String: Date] = [:]

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Key.waiting: true, Key.finished: true, Key.limits: true])
        let allow = UNNotificationAction(identifier: "allow", title: "Allow")
        let always = UNNotificationAction(identifier: "always", title: "Always allow")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: .destructive)
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "permission", actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission-always", actions: [allow, always, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission-risky", actions: [deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plan", actions: [UNNotificationAction(identifier: "allow", title: "Approve plan")], intentIdentifiers: []),
            UNNotificationCategory(identifier: "limit-switch", actions: [UNNotificationAction(identifier: "switch", title: "Switch idle sessions to Sonnet")], intentIdentifiers: []),
        ])
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func enabled(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    func sessionsChanged(from old: [LiveSession], to new: [LiveSession], name: (LiveSession) -> String) {
        let before = Dictionary(old.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        for s in new where !s.isLeftover {
            let prev = before[s.sessionId]
            // A permission prompt mid-task is still the same task, so the start time survives until idle.
            if s.state == .busy, busySince[s.sessionId] == nil { busySince[s.sessionId] = now }
            if s.state == .blocked, prev != nil, prev?.state != .blocked, enabled(Key.waiting), hasApproval?(s.sessionId) != true {
                post(id: "wait-\(s.sessionId)", title: name(s), body: Self.waitingText(s.waitingFor), sessionId: s.sessionId)
            }
            if s.state == .idle, prev?.state == .busy, let start = busySince[s.sessionId],
               now.timeIntervalSince(start) >= Self.longTask, enabled(Key.finished) {
                post(id: "done-\(s.sessionId)", title: name(s), body: "Finished · took \(Fmt.duration(now.timeIntervalSince(start)))", sessionId: s.sessionId)
            }
            if s.state == .idle { busySince[s.sessionId] = nil }
        }
        let ids = Set(new.map(\.sessionId))
        busySince = busySince.filter { ids.contains($0.key) }
    }

    static func waitingText(_ waitingFor: String?) -> String {
        guard let w = waitingFor, !w.isEmpty, w != "input needed" else { return "is waiting for your answer" }
        return "is waiting: \(w)"
    }

    func usageChanged(_ u: UsageSnapshot, forecast: (LimitWindow) -> Forecast, note: String? = nil, canSwitch: Int = 0) {
        guard enabled(Key.limits) else { return }
        var fired = Set(UserDefaults.standard.stringArray(forKey: Key.fired) ?? [])
        var warned = Set<String>()
        for w in [u.fiveHour, u.weekly].compactMap({ $0 }) {
            let pct = w.percent()
            let t = Self.warnAt
            guard pct >= t else { continue }
            let key = "\(w.key)-\(Int(t))-\(Self.period(w))"
            guard fired.insert(key).inserted else { continue }
            warned.insert(w.key)
            var body = Fmt.resetsTitle(w.resetsAt)
            if pct < LimitWindow.full, case .reachesLimit(let at) = forecast(w) { body += " · at this pace you'll reach 100% at \(Fmt.clock(at))" }
            post(id: key, title: "\(w.label) limit at \(Int(pct.rounded()))%", body: limitBody(body, note, canSwitch), sessionId: nil,
                 category: canSwitch > 0 && pct < LimitWindow.full ? "limit-switch" : nil)
        }
        // Accounts are often shared, so the pace can jump from someone else's use: warn once per period
        // as soon as the limit is on track to run out before it resets.
        // ponytail: a 50% floor (or your warning level, if lower) keeps an early burst from alerting.
        let floor = min(50, Self.warnAt)
        for w in [u.fiveHour, u.weekly].compactMap({ $0 }) where w.percent() >= floor && w.percent() < LimitWindow.full {
            guard case .reachesLimit(let at) = forecast(w), at > Date() else { continue }
            let key = "\(w.key)-pace-\(Self.period(w))"
            // The threshold alert just posted already carries this ETA.
            guard fired.insert(key).inserted, !warned.contains(w.key) else { continue }
            post(id: key, title: "\(w.label) limit runs out at \(Fmt.clock(at))",
                 body: limitBody("At this pace, before it \(Fmt.resets(w.resetsAt)) · now \(Int(w.percent().rounded()))%", note, canSwitch),
                 sessionId: nil, category: canSwitch > 0 ? "limit-switch" : nil)
        }
        // Keys end with the period's reset minute; once that has passed the key can't match again.
        let now = Date().timeIntervalSince1970 / 60
        // (Keys saved before this used seconds.)
        fired = fired.filter { k in k.split(separator: "-").last.flatMap { Double($0) }.map { $0 == 0 || ($0 > 1e9 ? $0 / 60 : $0) > now } ?? false }
        UserDefaults.standard.set(Array(fired), forKey: Key.fired)
    }

    // The reset minute: Anthropic and the status line give the same reset a second or so apart.
    static func period(_ w: LimitWindow) -> Int { Int(((w.resetsAt?.timeIntervalSince1970 ?? 0) / 60).rounded()) }

    private func limitBody(_ body: String, _ note: String?, _ canSwitch: Int) -> String {
        [body, note, canSwitch > 0 ? "\(Fmt.count(canSwitch, "idle session")) on Opus here could switch to Sonnet" : nil]
            .compactMap { $0 }.joined(separator: "\n")
    }

    func continued(done: [String], failed: [String]) {
        guard !done.isEmpty || !failed.isEmpty else { return }
        let body = [done.isEmpty ? nil : "Continued \(done.joined(separator: ", "))",
                    failed.isEmpty ? nil : "Couldn't type into \(failed.joined(separator: ", ")); continue it yourself"]
        post(id: "continued-\(Date().timeIntervalSince1970)", title: "Your limit has reset",
             body: body.compactMap { $0 }.joined(separator: "\n"), sessionId: nil)
    }

    func approvalArrived(_ r: ApprovalRequest, name: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["wait-\(r.sessionId)"])
        guard enabled(Key.waiting) else { return }
        let title: String, body: String, category: String?
        switch r.kind {
        case .permission:
            title = r.risk.map { "\(name) wants to run a risky command: it \($0)" } ?? "\(name) wants to use \(r.toolName)"
            body = r.detail.isEmpty ? (r.description ?? "") : r.detail
            category = r.risk != nil ? "permission-risky" : r.alwaysLabel == nil ? "permission" : "permission-always"
        case .plan:
            (title, body, category) = ("\(name) has a plan for you", r.detail, "plan")
        case .question:
            (title, body, category) = ("\(name) asks", r.questions.map(\.question).joined(separator: "\n"), nil)
        }
        post(id: "approval-\(r.id)", title: title, body: String(body.prefix(300)), sessionId: r.sessionId,
             category: category, info: ["approvalId": r.id], sound: UNNotificationSound(named: UNNotificationSoundName("Glass.aiff")))
    }

    func approvalDone(_ id: Int) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["approval-\(id)"])
    }

    private func post(id: String, title: String, body: String, sessionId: String?, category: String? = nil, info: [String: Any] = [:],
                      sound: UNNotificationSound = .default) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        var userInfo = info
        if let sessionId { userInfo["sessionId"] = sessionId }
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = info["sessionId"] as? String
        let approval = info["approvalId"] as? Int
        let action = response.actionIdentifier
        let answers: [String: ApprovalAnswer] = ["allow": .allow(always: false), "always": .allow(always: true), "deny": .deny]
        Task { @MainActor in
            if action == "switch" {
                self.onSwitch?()
            } else if let approval, let answer = answers[action] {
                self.onAnswer?(approval, answer)
            } else if action == UNNotificationDefaultActionIdentifier, let id {
                self.onOpen?(id)
            }
            completionHandler()
        }
    }
}
