import Foundation
import AgentDeckCore
import UserNotifications

/// macOS notifications: a session needs you, a long task finished, a usage limit is getting close.
/// Each kind can be switched off in Settings.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Key {
        static let waiting = "notifyWaiting", finished = "notifyFinished", limits = "notifyLimits"
        static let fired = "firedLimitWarnings"
    }
    static let thresholds: [Double] = [80, 95]
    /// A reply shorter than this isn't worth a "finished" notification.
    static let longTask: TimeInterval = 60

    var onOpen: ((String) -> Void)?
    var onAnswer: ((Int, ApprovalAnswer) -> Void)?
    var hasApproval: ((String) -> Bool)?
    private var busySince: [String: Date] = [:]
    private var asked = false

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
        ])
        UNUserNotificationCenter.current().delegate = self
    }

    private func enabled(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    func sessionsChanged(from old: [LiveSession], to new: [LiveSession], name: (LiveSession) -> String) {
        let before = Dictionary(old.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        for s in new where !s.isLeftover {
            let prev = before[s.sessionId]
            if s.state == .busy, prev?.state != .busy { busySince[s.sessionId] = now }
            if s.state == .blocked, prev != nil, prev?.state != .blocked, enabled(Key.waiting), hasApproval?(s.sessionId) != true {
                post(id: "wait-\(s.sessionId)", title: name(s), body: Self.waitingText(s.waitingFor), sessionId: s.sessionId)
            }
            if s.state == .idle, prev?.state == .busy, let start = busySince[s.sessionId],
               now.timeIntervalSince(start) >= Self.longTask, enabled(Key.finished) {
                post(id: "done-\(s.sessionId)", title: name(s), body: "Finished · took \(Fmt.duration(now.timeIntervalSince(start)))", sessionId: s.sessionId)
            }
            if s.state != .busy { busySince[s.sessionId] = nil }
        }
    }

    static func waitingText(_ waitingFor: String?) -> String {
        guard let w = waitingFor, !w.isEmpty, w != "input needed" else { return "is waiting for your answer" }
        return "is waiting: \(w)"
    }

    /// One warning per threshold per window period (the reset time identifies the period).
    func usageChanged(_ u: UsageSnapshot, forecast: (LimitWindow) -> Forecast) {
        guard enabled(Key.limits) else { return }
        var fired = Set(UserDefaults.standard.stringArray(forKey: Key.fired) ?? [])
        for w in [u.fiveHour, u.weekly].compactMap({ $0 }) {
            let pct = w.percent()
            guard let t = Self.thresholds.last(where: { pct >= $0 }) else { continue }
            let key = "\(w.key)-\(Int(t))-\(Int(w.resetsAt?.timeIntervalSince1970 ?? 0))"
            guard fired.insert(key).inserted else { continue }
            var body = Fmt.resets(w.resetsAt).capitalized
            if case .reachesLimit(let at) = forecast(w) { body += " · at this pace you'll reach 100% at \(Fmt.clock(at))" }
            post(id: key, title: "\(w.label) limit at \(Int(pct.rounded()))%", body: body, sessionId: nil)
        }
        UserDefaults.standard.set(Array(fired.suffix(40)), forKey: Key.fired)
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
        if !asked {
            asked = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
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
            if let approval, let answer = answers[action] {
                self.onAnswer?(approval, answer)
            } else if action == UNNotificationDefaultActionIdentifier, let id {
                self.onOpen?(id)
            }
            completionHandler()
        }
    }
}
