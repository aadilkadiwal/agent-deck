import Foundation
import AgentDeckCore
import Intents
import UserNotifications

/// macOS notifications: a session needs you, a long task finished, a usage limit is getting close.
/// Each kind can be switched off in Settings.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Key {
        static let waiting = "notifyWaiting", finished = "notifyFinished", limits = "notifyLimits"
        static let fired = "firedLimitWarnings", warnAt = "limitWarnAt"
    }
    nonisolated static var warnAt: Double {
        let v = UserDefaults.standard.double(forKey: Key.warnAt)
        return (1...99).contains(v) ? v : 80
    }
    /// A reply shorter than this isn't worth a "finished" notification.
    static let longTask: TimeInterval = 60

    var onOpen: ((String) -> Void)?
    var onAnswer: ((Int, ApprovalAnswer) -> Void)?
    var onSwitch: (() -> Void)?
    var onDecide: ((Int, ApprovalAnswer) -> Void)?
    var onReview: (() -> Void)?
    var peek: ((PeekAlert) -> Bool)?
    var hasApproval: ((String) -> Bool)?
    var lastReply: ((String) async -> String?)?
    var awayLine: ((String) -> String?)?
    var canReply: ((String) -> Bool)?
    var onReply: ((String) -> Void)?
    private var busySince: [String: Date] = [:]
    private var lastCelebrated: Date?
    private var held: [Held] = []

    private struct Held {
        let alert: PeekAlert, title: String?, body: String, sessionId: String?, category: String?, info: [String: Any], at: Date
    }

    /// Seconds since 1970, so views can watch it with @AppStorage.
    nonisolated static let snoozeKey = "alertsSnoozedUntilTime"
    nonisolated static func snoozedUntil(_ t: Double = UserDefaults.standard.double(forKey: snoozeKey)) -> Date? {
        t > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: t) : nil
    }
    static var snoozedUntil: Date? { snoozedUntil() }
    static func snooze(for seconds: TimeInterval?) {
        UserDefaults.standard.set(seconds.map { Date().timeIntervalSince1970 + $0 } ?? 0, forKey: snoozeKey)
    }

    private var focused: Bool { INFocusStatusCenter.default.focusStatus.isFocused == true }

    // macOS kills the app if it asks without the usage text in Info.plist (as when the binary runs outside its bundle).
    func askForFocusStatus() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSFocusStatusUsageDescription") != nil,
              INFocusStatusCenter.default.authorizationStatus == .notDetermined else { return }
        INFocusStatusCenter.default.requestAuthorization { _ in }
    }

    func flushHeld() {
        guard !held.isEmpty, !focused, Self.snoozedUntil == nil else { return }
        let due = held.filter { Date().timeIntervalSince($0.at) < 7200 }
        held = []
        for h in due { post(h.alert, title: h.title, body: h.body, sessionId: h.sessionId, category: h.category, info: h.info) }
    }

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Key.waiting: true, Key.finished: true, Key.limits: true])
        let allow = UNNotificationAction(identifier: "allow", title: "Allow")
        let always = UNNotificationAction(identifier: "always", title: "Allow for this session")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: .destructive)
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "permission", actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission-always", actions: [allow, always, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission-risky", actions: [deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plan", actions: [UNNotificationAction(identifier: "allow", title: "Approve plan")], intentIdentifiers: []),
            UNNotificationCategory(identifier: "limit-switch", actions: [UNNotificationAction(identifier: "switch", title: "Switch to Sonnet")], intentIdentifiers: []),
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
                post(PeekAlert(id: "wait-\(s.sessionId)", kind: .needs, title: name(s), meta: s.waitingFor.flatMap { $0.isEmpty || $0 == "input needed" ? nil : "Needs you: \($0)" },
                               actions: [show(s.sessionId)]),
                     body: Self.waitingReason(s.waitingFor) ?? "Waiting for you", sessionId: s.sessionId)
            }
            // Answered in the terminal: nothing left to wait for.
            if s.state != .blocked, prev?.state == .blocked { Peek.dismiss(id: "wait-\(s.sessionId)") }
            if s.state == .idle, prev?.state == .busy, let start = busySince[s.sessionId],
               now.timeIntervalSince(start) >= Self.longTask, enabled(Key.finished) {
                let took = "Done after \(Fmt.duration(now.timeIntervalSince(start)))"
                let big = now.timeIntervalSince(start) >= 600 || !(lastCelebrated.map(Calendar.current.isDateInToday) ?? false)
                if big { lastCelebrated = now }
                let sid = s.sessionId, title = name(s)
                let actions = (canReply?(sid) == true ? [PeekAlert.Action(title: "Reply…") { [weak self] in self?.onReply?(sid) }] : []) + [show(sid)]
                let did = awayLine?(sid)
                Task { [weak self] in
                    let line = await self?.lastReply?(sid)
                    let lines = [line, did].compactMap { $0 }
                    self?.post(PeekAlert(id: "done-\(sid)", kind: .done, title: title, meta: took, lines: lines, actions: actions, celebrate: big),
                               title: "\(title) is done",
                               body: ([took.replacingOccurrences(of: "Done after", with: "Took")] + lines).joined(separator: " · "), sessionId: sid)
                }
            }
            if s.state == .idle { busySince[s.sessionId] = nil }
        }
        let ids = Set(new.map(\.sessionId))
        busySince = busySince.filter { ids.contains($0.key) }
    }

    /// "Needs you: <reason>" when Claude gave one; nil otherwise, since the eyebrow already says it's waiting.
    static func waitingReason(_ waitingFor: String?) -> String? {
        guard let w = waitingFor, !w.isEmpty, w != "input needed" else { return nil }
        return "Needs you: \(w)"
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
            if pct < LimitWindow.full, case .reachesLimit(let at) = forecast(w) { body += ". At this pace you'll hit it around \(Fmt.clock(at))." }
            let switches = pct < LimitWindow.full ? canSwitch : 0
            post(PeekAlert(id: key, kind: pct >= LimitWindow.full ? .reached : .warn, title: "\(w.label) limit at \(Int(pct.rounded()))%",
                           meta: body, lines: limitLines(note, switches), percent: pct, actions: switchActions(switches)),
                 body: limitBody(body, note, switches), sessionId: nil, category: switches > 0 ? "limit-switch" : nil)
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
            let body = "You're at \(Int(w.percent().rounded()))%. It \(Fmt.resets(w.resetsAt))."
            post(PeekAlert(id: key, kind: .runsOut, title: "You'll hit the \(w.label.lowercased()) limit around \(Fmt.clock(at))", meta: body,
                           lines: limitLines(note, canSwitch), percent: w.percent(), actions: switchActions(canSwitch)),
                 body: limitBody(body, note, canSwitch), sessionId: nil, category: canSwitch > 0 ? "limit-switch" : nil)
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
        ([body] + limitLines(note, canSwitch)).joined(separator: "\n")
    }

    private func limitLines(_ note: String?, _ canSwitch: Int) -> [String] {
        [note, canSwitch > 0 ? "\(Fmt.count(canSwitch, "idle session")) on Opus could switch to Sonnet and use less" : nil].compactMap { $0 }
    }

    private func switchActions(_ canSwitch: Int) -> [PeekAlert.Action] {
        guard canSwitch > 0 else { return [] }
        return [PeekAlert.Action(title: "Not now") {},
                PeekAlert.Action(title: "Switch to Sonnet", style: .primary, done: "Switching to Sonnet…") { [weak self] in self?.onSwitch?() }]
    }

    private func show(_ sessionId: String) -> PeekAlert.Action {
        PeekAlert.Action(title: "Show", style: .primary) { [weak self] in self?.onOpen?(sessionId) }
    }

    func continued(done: [String], failed: [String]) {
        guard !done.isEmpty || !failed.isEmpty else { return }
        let body = [done.isEmpty ? nil : "Continued \(done.joined(separator: ", "))",
                    failed.isEmpty ? nil : "Couldn't type into \(failed.joined(separator: ", ")), so continue it yourself"]
        let lines = body.compactMap { $0 }
        post(PeekAlert(id: "continued-\(Date().timeIntervalSince1970)", kind: .back, title: "Your limit reset. You're good to go.", lines: lines),
             body: lines.joined(separator: "\n"), sessionId: nil)
    }

    /// The reminder for a prompt nobody answered reuses its alert id, so answering clears either one.
    func stillWaiting(_ s: LiveSession, name: String, waited: TimeInterval) {
        guard enabled(Key.waiting) else { return }
        let tag = "Still waiting · \(Fmt.span(waited))"
        var alert = PeekAlert(id: "wait-\(s.sessionId)", kind: .needs, title: name, lines: Self.waitingReason(s.waitingFor).map { [$0] } ?? [], actions: [show(s.sessionId)])
        alert.tag = tag
        alert.soft = true
        post(alert, body: [tag, Self.waitingReason(s.waitingFor)].compactMap { $0 }.joined(separator: ". "), sessionId: s.sessionId)
    }

    func approvalArrived(_ r: ApprovalRequest, name: String, waited: TimeInterval? = nil) {
        // The session can read as waiting a moment before its card arrives; the card replaces that alert.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["wait-\(r.sessionId)"])
        Peek.dismiss(id: "wait-\(r.sessionId)")
        guard enabled(Key.waiting) else { return }
        let title: String, body: String, category: String?
        var bannerTitle: String?, bannerBody: String?
        switch r.kind {
        case .permission:
            title = "\(name) wants to \(r.toolName == "Bash" ? "run" : "use") \(r.toolName)"
            body = r.detail.isEmpty ? (r.description ?? "") : r.detail
            if let risk = r.risk { (bannerTitle, bannerBody) = ("Risky: \(title)", "\(body.prefix(240)) · \(risk)") }
            category = r.risk != nil ? "permission-risky" : r.alwaysLabel == nil ? "permission" : "permission-always"
        case .plan:
            (title, body, category) = ("\(name) has a plan for you", r.detail, "plan")
        case .question:
            (title, body, category) = ("\(name) asks", r.questions.map(\.question).joined(separator: "\n"), nil)
        }
        let decide = { [weak self] (a: ApprovalAnswer) -> Void in self?.onDecide?(r.id, a) }
        let review = { [weak self] () -> Void in self?.onReview?() }
        var alert = PeekAlert(id: "approval-\(r.id)", kind: r.risk != nil ? .risky : .needs, title: title)
        alert.tag = waited.map { "Still waiting · \(Fmt.span($0))" } ?? r.risk.map { "Risky · \($0)" }
            ?? (r.kind == .question ? (r.questions.count == 1 ? "Question" : "\(r.questions.count) questions") : r.kind == .plan ? "Plan to review" : nil)
        alert.soft = waited != nil
        switch r.kind {
        case .permission:
            alert.code = body
            alert.actions = r.risk != nil
                ? [.init(title: "Allow once", style: .danger, done: "Allowed once") { decide(.allow(always: false)) },
                   .init(title: "Deny", style: .primary, done: "Denied") { decide(.deny) }]
                : [.init(title: "Deny", done: "Denied") { decide(.deny) }]
                    + (r.alwaysLabel == nil ? [] : [.init(title: "For this session", done: "Allowed for this session") { decide(.allow(always: true)) }])
                    + [.init(title: "Allow", style: .primary, done: "Allowed") { decide(.allow(always: false)) }]
        case .plan:
            alert.lines = Array(body.split(separator: "\n").map {
                $0.replacingOccurrences(of: #"^\s*#+\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "• ", options: .regularExpression)
            }.filter { !$0.isEmpty }.prefix(3))
            alert.actions = [.init(title: "Review the plan…", style: .primary, run: review)]
        case .question:
            alert.lines = Array(body.split(separator: "\n").prefix(3).map(String.init))
            if r.questions.count == 1, let q = r.questions.first, !q.multiSelect, (2...3).contains(q.options.count),
               q.options.allSatisfy({ $0.label.count <= 20 }) {
                alert.actions = q.options.map { o in .init(title: o.label, done: "Answered") { decide(.answers([q.question: o.label])) } }
                    + [.init(title: "Answer…", style: .primary, run: review)]
            } else {
                alert.actions = [.init(title: "Answer", style: .primary, run: review)]
            }
        }
        post(alert, title: bannerTitle, body: bannerBody ?? String(body.prefix(300)), sessionId: r.sessionId, category: category, info: ["approvalId": r.id])
    }

    func approvalDone(_ id: Int) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["approval-\(id)"])
        Peek.dismiss(id: "approval-\(id)")
    }

    /// `title` overrides the alert's title in the macOS banner, which has to make sense later in Notification Center.
    private func post(_ alert: PeekAlert, title: String? = nil, body: String, sessionId: String?, category: String? = nil, info: [String: Any] = [:]) {
        if Self.snoozedUntil != nil { return }
        var alert = alert
        // In a Focus a stuck session still gets through, without a sound; the rest waits for the Focus to end.
        if focused {
            guard alert.kind == .needs || alert.kind == .risky else {
                held.removeAll { $0.alert.id == alert.id }
                held.append(Held(alert: alert, title: title, body: body, sessionId: sessionId, category: category, info: info, at: Date()))
                return
            }
            alert.quiet = true
        }
        if peek?(alert) == true { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title ?? alert.title
        content.body = body
        content.sound = alert.quiet ? nil : UNNotificationSound(named: UNNotificationSoundName("\(alert.kind.sound).wav"))
        if alert.kind.isLimit, let png = Dot.png(mood: alert.kind.mood, percent: alert.percent) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-\(UUID().uuidString).png")
            if (try? png.write(to: url)) != nil, let a = try? UNNotificationAttachment(identifier: "dot", url: url) { content.attachments = [a] }
        }
        var userInfo = info
        if let sessionId { userInfo["sessionId"] = sessionId }
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
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
