import AppKit
import UserNotifications
import KvotarCore
import KvotarUI

/// Delivers `NotificationEngine` decisions as real macOS notifications (Baseline §16). Owns copy
/// (UI Spec §4 wins on copy — Core stays copy-free) and the `UNUserNotificationCenter` plumbing.
///
/// Standard delivery only — never `.critical`/`.timeSensitive`, so macOS Focus/Do-Not-Disturb
/// suppresses these automatically (UI Spec §4.2). No snooze; the single action is "Open Kvotar".
/// Acts as the center's delegate so a dismissal/open reports back to arm the at-risk re-arm path.
final class UserNotificationPresenter: NSObject, NotificationPresenter, UNUserNotificationCenterDelegate, @unchecked Sendable {

    private static let categoryID = "com.vladimirmarkovic.kvotar.alert"
    private static let openActionID = "com.vladimirmarkovic.kvotar.open"
    /// The hidden-item notice (REV-99 §2.7 — STEP_206): its own identifier, so it never replaces a
    /// quota banner in place, and its own `userInfo` marker, so the delegate can tell it apart
    /// from the nine engine events.
    static let hiddenItemNoticeID = "com.vladimirmarkovic.kvotar.hidden-item"
    static let noticeKey = "notice"
    static let hiddenItemNoticeValue = "hidden_item"
    /// Copy fixture, verbatim from REV-99 §2.7.
    static let hiddenItemNoticeTitle = "Kvotar is running"
    static let hiddenItemNoticeBody = "Its menu bar item may be hidden. Open Kvotar to see your quota."

    private let center = UNUserNotificationCenter.current()

    /// Opens the popover — wired by `AppDelegate`. Invoked on the main actor.
    var onOpen: (@Sendable @MainActor () -> Void)?
    /// Opens the quota **window** — the hidden-item notice's action, and deliberately not `onOpen`
    /// (REV-99 §2.7 — STEP_206). That user is being told their icon may be gone; the response must
    /// not depend on a second reading of the same signal.
    var onOpenWindow: (@Sendable @MainActor () -> Void)?
    /// User saw the notification (opened or dismissed) — arms at-risk re-arm via the engine.
    var onAcknowledge: (@Sendable (Tool, NotificationEventType) -> Void)?
    /// §4.2: project name in the body by default; the opt-out is the settings key
    /// `notification_project_name_enabled` read by `AppDelegate` at startup (toggle UI is
    /// Step 30). STEP_27.
    var includeProjectName = true

    override init() {
        super.init()
        let open = UNNotificationAction(identifier: Self.openActionID, title: "Open Kvotar",
                                        options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [open],
                                              intentIdentifiers: [],
                                              options: [.customDismissAction])
        center.setNotificationCategories([category])
        center.delegate = self
    }

    /// Fires once the OS has answered the authorization request (STEP_150) — the AppDelegate
    /// re-reads the permission for the **Notify me ▸** hint. Called off the main thread.
    var onAuthorizationResolved: (() -> Void)?

    /// One-time authorization request — from the first-run window's screen 4, or on the first
    /// detected tool of an already-onboarded install (D-100). Read-only outcome: a denial means
    /// no banners, and the context menu says so (D-103); the app never re-prompts.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Logger.error("Notification authorization failed", component: .notificationEngine,
                             metadata: ["error": "\(error)"])
            } else {
                Logger.info("Notification authorization", component: .notificationEngine,
                            metadata: ["granted": "\(granted)"])
            }
            self?.onAuthorizationResolved?()
        }
    }

    // MARK: NotificationPresenter

    func present(_ decision: NotificationDecision) async {
        let content = UNMutableNotificationContent()
        content.title = Self.title(for: decision)
        content.body = Self.body(for: decision, includeProject: includeProjectName)
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["tool": decision.tool.rawValue, "event": decision.eventType.rawValue,
                            Self.withdrawKey: Self.withdrawsAtReset(decision)]
        // D-126 (STEP_224): until this line no notification carried a sound, so macOS had nothing
        // to play (`hasSound: false`) and every warning was a silent banner.
        if Self.isAudible(decision.eventType) { content.sound = .default }

        // Stable per-(tool, event, window) identifier: a re-fire replaces the delivered banner
        // in place instead of stacking (STEP_28; UI Spec §4.2 "no stacking").
        let request = UNNotificationRequest(identifier: decision.stableRequestID,
                                            content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Logger.error("Notification delivery failed", component: .notificationEngine,
                             metadata: ["event": decision.eventType.rawValue, "error": "\(error)"])
            }
        }
    }

    /// UI Spec §4.2 Sound row (D-126 — STEP_224): the events that say *you are about to be
    /// stopped, or you just were*. Everything else — fast burn, off-machine, multi-surface, both
    /// window resets, window changed — is news, not an emergency, and arrives silently. The
    /// hidden-item notice never reads this list and stays silent too.
    static let audibleEvents: Set<NotificationEventType> =
        [.atRisk, .badTiming, .overQuota, .spendControl, .limitNearlySpent]

    static func isAudible(_ event: NotificationEventType) -> Bool {
        audibleEvents.contains(event)
    }

    // MARK: Withdrawal at window reset (D-128 — STEP_226)

    static let withdrawKey = "withdraw_at_reset"

    /// Whether this notice is about the tool's primary window, so its reset makes it untrue.
    /// Kept: a weekly or monthly block (still true after a five-hour rollover), nearly spent,
    /// spend control, "has reset" and window changed.
    static func withdrawsAtReset(_ d: NotificationDecision) -> Bool {
        switch d.eventType {
        case .atRisk, .badTiming, .fastBurnSpike, .offMachineBurn, .multiSurface, .windowResetPre:
            return true
        case .overQuota:
            return d.blockEpisode.map { $0.limit == .primary } ?? true
        case .spendControl, .limitNearlySpent, .limitAheadOfPace, .windowResetPost,
             .windowChanged:
            return false
        }
    }

    /// Only notices delivered **before** the reset go: one fired in the new window is current.
    func windowDidReset(_ tool: Tool) async {
        let now = Date()
        let delivered = await center.deliveredNotifications()
        let ids = delivered.filter { n in
            let info = n.request.content.userInfo
            return info["tool"] as? String == tool.rawValue
                && info[Self.withdrawKey] as? Bool == true
                && n.date < now
        }.map(\.request.identifier)
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        Logger.info("Withdrew notices at window reset", component: .notificationEngine,
                    metadata: ["tool": tool.rawValue, "count": "\(ids.count)"])
    }

    // MARK: The hidden-item notice (REV-99 §2.7 — STEP_206)

    /// **Not an engine event.** It never passes through `NotificationEngine`: no §16 arbitration,
    /// no priority, no cap, no cooldown, no `notification_events` row, and it can neither displace
    /// nor be displaced by a quota warning. The nine events are claims about *quota*; this one is
    /// a claim about *the app*. It is outside the four D-100 groups for the same reason — a user
    /// cannot opt out of being told where their app went.
    ///
    /// **"May be hidden", not "is hidden"** — the hedge is load-bearing. Spike E ran on one notched
    /// Mac with one built-in display; external displays and notch-less bars are untested. The copy
    /// describes a symptom the reader can check in one glance and names no macOS mechanism, no API
    /// and no polling internal.
    ///
    /// The once-per-launch cap lives with the `AppDelegate`, which knows what a launch is.
    func presentHiddenItemNotice() {
        let content = UNMutableNotificationContent()
        content.title = Self.hiddenItemNoticeTitle
        content.body = Self.hiddenItemNoticeBody
        content.categoryIdentifier = Self.categoryID
        // No `(tool, event)` pair: this is not one of the nine, and `onAcknowledge` — which arms
        // the at-risk re-arm path off that pair — must never fire for it.
        content.userInfo = [Self.noticeKey: Self.hiddenItemNoticeValue]

        let request = UNNotificationRequest(identifier: Self.hiddenItemNoticeID,
                                            content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Logger.error("Hidden-item notice delivery failed", component: .notificationEngine,
                             metadata: ["error": "\(error)"])
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound]   // show even when Kvotar is frontmost
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // The hidden-item notice, answered before anything reads a `(tool, event)` pair it does
        // not carry: its action opens the window, not whichever surface the routing prefers.
        if info[Self.noticeKey] as? String == Self.hiddenItemNoticeValue {
            let openWindow = onOpenWindow
            await MainActor.run { openWindow?() }
            return
        }
        if let t = info["tool"] as? String, let tool = Tool(rawValue: t),
           let e = info["event"] as? String, let event = NotificationEventType(rawValue: e) {
            onAcknowledge?(tool, event)
        }
        if response.actionIdentifier == Self.openActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let open = onOpen
            await MainActor.run { open?() }
        }
    }

    // MARK: Copy (UI Spec §4)

    /// Internal rather than private since STEP_194: the title now branches on which limit
    /// blocked you, so it is copy worth pinning beside the body it goes with.
    static func title(for d: NotificationDecision) -> String {
        let name = d.tool.tabLabel
        switch d.eventType {
        case .atRisk:          return "\(name) quota at risk"
        case .badTiming:       return "\(name) may block before reset"
        // REV-96 §3.8 (STEP_194): the title names the limit that stopped you where one is
        // identified. "Claude quota exceeded" was true of a five-hour block and useless on a
        // weekly one — the tester read it eleven times in three days about a week-long block.
        case .overQuota:
            // REV-102 §2.6 (STEP_221): with credits paying, nothing stopped.
            if isCharging(d) { return "\(name) \(chargingLimit(d).lowercased()) spent" }
            switch blockShape(d) {
            case .weekly:    return "\(name) stopped — weekly spent"
            case .bothWindows: return "\(name) stopped"
            case .plain:     return "\(name) quota exceeded"
            }
        case .fastBurnSpike:   return "\(name) usage spike detected"
        case .offMachineBurn:  return d.tool == .codex ? "Codex usage on another machine"
                                                       : "Claude usage rising"
        case .multiSurface:    return "Codex usage spike detected"
        case .windowResetPre:  return "\(name) quota resets soon"
        case .windowResetPost: return "\(name) quota reset"
        // Both tools since STEP_193 gave the Claude monthly a state (REV-96 §3.8). Claude's own
        // wording is "spend limit" (claude.ai's), Codex's is "monthly limit"; the Claude title
        // deliberately stops short of "stopped" until P1-16b captures what reaching it does.
        case .spendControl:
            return d.tool == .claude ? "Claude spend limit reached"
                                     : "Codex monthly limit reached"
        case .windowChanged:   return "\(name) quota window changed"
        // REV-96 §3.8 (STEP_193). Defined, fired by nothing until STEP_194 adds rank 5b; the
        // limit's own name ("weekly" / "monthly spend") arrives with the assessment that step
        // computes, so the title stays limit-agnostic for now.
        case .limitNearlySpent:
            switch d.longLimit?.limit {
            // A seven-day primary is the account's weekly too (REV-106 §2.4 — STEP_233).
            case .secondary?, .primary?: return "\(name) weekly nearly spent"
            case .monthly?:
                return d.tool == .claude ? "Claude monthly spend nearly reached"
                                         : "Codex monthly limit nearly reached"
            default: return "\(name) limit nearly spent"
            }
        // REV-106 §2.5 (STEP_233): the ladder's two early steps, carried as the copy variant.
        case .limitAheadOfPace:
            return d.copyVariant == WeeklyLadder.Step.quarter.rawValue
                ? "\(name) weekly: a quarter left"
                : "\(name) weekly won't last at this pace"
        }
    }

    static func body(for d: NotificationDecision, includeProject: Bool) -> String {
        let text = coreBody(for: d)
        // §4.2 (STEP_27): project name in the body by default. Session-scoped events only —
        // window-reset and workspace spend-control are account-level.
        let projectScoped: Set<NotificationEventType> =
            [.atRisk, .badTiming, .overQuota, .fastBurnSpike, .offMachineBurn, .multiSurface]
        guard includeProject, projectScoped.contains(d.eventType),
              let project = d.project.map(projectName), !project.isEmpty else { return text }
        return "\(text) Project: \(project)."
    }

    private static func coreBody(for d: NotificationDecision) -> String {
        let pct = d.utilizationPct.map { "\(max(0, 100 - Int($0)))% left" }
        switch d.eventType {
        case .atRisk:
            let left = d.runwayMinutes.map { "runs out in ~\(runwayIn($0)) at this pace" } ?? "at risk"
            return "\(pct ?? "Quota at risk") · \(left). Resets at \(resetTime(d.resetsAt))."
        case .badTiming:
            return "\(pct ?? "High usage") with \(resetIn(d.resetsAt)) until reset. "
                + "You could hit the limit before your quota refreshes."
        case .overQuota:
            // §4.1 event 3 (STEP_27): the three Claude cases carry dollar amounts; Codex is a
            // hard block with distinct copy (D-11 Codex — never reuse Claude credit copy).
            // REV-96 §3.8: a block keyed to the weekly names the weekly's reset, not the
            // five-hour one. On the tester's block the old body pointed at a clock three days
            // early, every few hours, for three days.
            // REV-102 §2.6 (STEP_221): credits paying is decided first — "used up" and "hard
            // block" are both untrue while work continues on credits, on either plan family.
            if isCharging(d) {
                let cap = d.extraUsageMonthlyLimit.map {
                    " (\(Fmt.money(minor: Double($0), exponent: d.extraUsageCurrencyExponent ?? 2, currency: d.extraUsageCurrency)) cap)"
                } ?? ""
                let reset = d.blockEpisode?.limitResetsAt != nil
                    ? blockReset(d) : "in \(resetIn(d.resetsAt))"
                return "Now running on usage credits\(cap). \(chargingLimit(d)) resets \(reset)."
            }
            switch blockShape(d) {
            case .weekly:
                return "The weekly quota is used up. Resets \(blockReset(d))."
            case .bothWindows:
                return "Both windows are spent. Resets \(blockReset(d)), when the weekly resets."
            case .plain:
                break
            }
            if d.tool == .codex {
                return "\(pct ?? "Over quota") · Codex CLI will block new requests. "
                    + "Resets in \(resetIn(d.resetsAt))."
            }
            switch d.copyVariant {
            case "case_2":
                let used = d.extraUsageUsedCredits.map {
                    Fmt.money(major: $0, exponent: d.extraUsageCurrencyExponent ?? 2,
                              currency: d.extraUsageCurrency)
                } ?? "credits"
                return "\(pct ?? "Over quota") · credits no longer accruing "
                    + "(\(used) used earlier · last observed). Hard block. "
                    + "Resets in \(resetIn(d.resetsAt))."
            default:
                return "\(pct ?? "Over quota") · hard block. Resets in \(resetIn(d.resetsAt))."
            }
        case .fastBurnSpike:
            let onModel = d.model.map { " on \($0)" } ?? ""
            // D-119 (STEP_189): the rise is measured between two consecutive polls, so the body
            // names that, not a two-minute clock the 120s cadence does not keep. Multi-surface
            // below still measures a real 2-minute window and keeps its own wording.
            let head = d.deltaPct.map { "+\(Int($0))% since the last check" } ?? "Usage spike"
            return d.tool == .codex
                ? "\(head)\(onModel). If unexpected, check Codex for a runaway loop."
                : "\(head)\(onModel)."
        case .offMachineBurn:
            return d.tool == .codex
                ? "Codex is idle here. Usage likely from another machine or Codex Web. "
                    + "\(pct ?? "Usage rising") · resets at \(resetTime(d.resetsAt))."
                : "Likely Claude Desktop here, claude.ai, or another computer. "
                    + "\(pct ?? "Usage rising") · resets at \(resetTime(d.resetsAt))."
        case .multiSurface:
            // §4.1 Codex event 6 (STEP_27): "[A] + [B] both active on [model]".
            let onModel = d.model.map { " on \($0)" } ?? ""
            let head = d.deltaPct.map { "+\(Int($0))% in ~2 min" } ?? "Usage spike"
            // STEP_192: the list arrives filtered to surfaces burning now (`Unknown` never among
            // them), and every one is named — two "both active", three-plus "all active".
            if d.surfaces.count == 2 {
                return "\(head) · \(d.surfaces[0]) + \(d.surfaces[1]) both active\(onModel)."
            }
            if d.surfaces.count > 2 {
                return "\(head) · \(d.surfaces.joined(separator: " + ")) all active\(onModel)."
            }
            return "\(head) · multiple surfaces active\(onModel)."
        case .windowResetPre:
            return "Your \(windowName(d)) window resets in \(resetIn(d.resetsAt))."
                + " Full quota available shortly."
        case .windowResetPost:
            return "Your \(windowName(d)) window has reset. Full quota available."
        case .spendControl:
            // Claude names the amount, because the meter is money and the reader set (or was
            // given) that number; Codex keeps its verified REV-38 wording about the workspace
            // pool. Neither claims more than the account has been observed to do.
            if d.tool == .claude {
                let limit = d.longLimit.flatMap { a in
                    a.limitAmount.flatMap { total in
                        a.unit.map { DisplayFormatter.monthlyAmount(total, unit: $0) }
                    }
                }
                let amount = limit.map { "The \($0) monthly limit" } ?? "Your monthly spend limit"
                return "\(amount) is used up. Resets \(blockReset(d))."
            }
            return "Monthly workspace limit reached. New requests are blocked until the limit "
                + "resets \(blockReset(d))."
        case .windowChanged:
            return windowChangedBody(d.windowFact)
        case .limitNearlySpent:
            return nearlySpentBody(d)
        case .limitAheadOfPace:
            return aheadOfPaceBody(d, now: Date())
        }
    }

    /// §4.1a copy — the reported width names (D-58), never a size. A restructuring (STEP_146) is
    /// told as what you have now against what you had: `You now have a 5-hour window and a weekly
    /// window — before, weekly only.`
    static func windowChangedBody(_ fact: WindowFact?) -> String {
        guard let fact else { return "Your quota windows changed. See the History window." }
        let name = { (w: Int?) in
            (DisplayFormatter.windowGrain(seconds: w) ?? "quota").lowercased() + " window"
        }
        let list = { (ws: [Int?]) in
            ws.map { "a \(name($0))" }.joined(separator: " and ")
        }
        switch fact.kind {
        case .added:
            return "A \(name(fact.after.first ?? nil)) was added."
        case .removed:
            return "Your \(name(fact.before.first ?? nil)) was removed."
        case .widthChanged:
            let old = DisplayFormatter.windowGrain(seconds: fact.before.first ?? nil)?.lowercased()
            let new = DisplayFormatter.windowGrain(seconds: fact.after.first ?? nil)?.lowercased()
            return "Your \(old ?? "quota") window is now \(new ?? "a different length")."
        case .restructured:
            let before = fact.before.compactMap { DisplayFormatter.windowGrain(seconds: $0)?.lowercased() }
            let was = before.isEmpty ? "" : " — before, \(before.joined(separator: " + ")) only"
            return "You now have \(list(fact.after))\(was)."
        }
    }

    /// Which §3.8 block row this decision is (STEP_194). `plain` is every block the five-hour
    /// window owns — Claude's three credit cases included — and keeps the copy it has always had.
    private enum BlockShape { case plain, weekly, bothWindows }

    private static func blockShape(_ d: NotificationDecision) -> BlockShape {
        guard d.blockEpisode?.limit == .secondary else { return .plain }
        // The primary is spent too when its own utilization reached the ceiling; the episode
        // named the weekly because its reset is the later one, which is what makes it the
        // sentence's subject either way.
        return (d.utilizationPct ?? 0) >= 100 ? .bothWindows : .weekly
    }

    /// The reset that actually ends the block — the blocking limit's, not the primary window's.
    /// Named in the same grammar the popover uses for the same instant: a date at or beyond the
    /// D-59 day band, a clock time below it.
    private static func blockReset(_ d: NotificationDecision) -> String {
        guard let at = d.blockEpisode?.limitResetsAt else { return "when the window resets" }
        if let days = Fmt.daysLong(at, from: Date()) { return "\(Fmt.monthDay(at)), in \(days)" }
        return "at \(resetTime(at)), in \(resetIn(at))"
    }

    /// Event 9's body (UI Spec §4.1 event 9 / REV-96 §3.8): what is left of the limit, how long
    /// its period still has to run, and one sentence of context — for the weekly, whether the
    /// five-hour window is the reader's problem too; for a monthly, who can raise it.
    private static func nearlySpentBody(_ d: NotificationDecision) -> String {
        guard let a = d.longLimit else { return "A limit is nearly spent." }
        let span = Fmt.daysLong(a.resetsAt, from: Date())
        let resetsWord = span.map { "with \($0) until it resets \(Fmt.monthDay(a.resetsAt))" }
            ?? "and it resets \(Fmt.monthDay(a.resetsAt))"
        switch a.limit {
        case .secondary, .primary:
            // The last clause only where the five-hour window really is fine — saying it while
            // the reader is also at risk on the short window would be the opposite of useful —
            // and never on a weekly-only account, which has no five-hour window to be fine
            // (REV-106 §2.4 — STEP_233).
            let primaryCalm = a.limit == .secondary
                && (d.utilizationPct ?? 100) < StateEngine.longLimitNearlySpentPct
            let tail = primaryCalm ? " Your 5-hour window is fine." : ""
            return "\(Fmt.percent(a.remainingPct)) of the weekly left, \(resetsWord).\(tail)"
        case .monthly:
            let left = a.limitAmount.flatMap { total in
                a.usedAmount.flatMap { used in
                    a.unit.map { DisplayFormatter.monthlyAmount(max(0, total - used), unit: $0) }
                }
            }
            let total = a.limitAmount.flatMap { t in
                a.unit.map { DisplayFormatter.monthlyAmount(t, unit: $0) }
            }
            let head: String
            if let left, let total {
                // Credits are a count and carry their own noun; money already reads as money and
                // needs the word "limit" to say what the second figure is (UI Spec §4.1 event 9).
                if case .credits? = a.unit {
                    head = "\(left) of \(total) credits left"
                } else {
                    head = "\(left) of the \(total) limit left"
                }
            } else {
                head = "\(Fmt.percent(a.remainingPct)) of the monthly limit left"
            }
            let tail = d.tool == .claude
                ? " Ask your workspace admin if you need more."
                : " You can request a limit increase from ChatGPT settings → Usage."
            return "\(head), \(resetsWord).\(tail)"
        }
    }

    /// Event 10's body (UI Spec §4.1 event 10 / REV-106 §2.5 — STEP_233): position and a
    /// per-day budget, never a run-out date — the weekly's date has not passed grading. The
    /// budget is what is left over the days to the reset; the average is what is used over the
    /// days elapsed, **dropped while less than one day has elapsed** (4 → 77 % in a week's first
    /// four hours is not "averaged over 500 % a day"). No five-hour tail: a planning notice says
    /// one thing.
    static func aheadOfPaceBody(_ d: NotificationDecision, now: Date) -> String {
        guard let a = d.longLimit else { return "The weekly is running ahead of pace." }
        let head = "\(Fmt.percent(a.remainingPct)) left with \(resetIn(a.resetsAt, from: now)) "
            + "until it resets \(weekdayClock(a.resetsAt))."
        let daysLeft = a.resetsAt.timeIntervalSince(now) / 86_400
        guard daysLeft > 0 else { return head }
        let budget = "That is about \(Fmt.percent(a.remainingPct / daysLeft)) a day"
        let daysElapsed = a.elapsedPct / 100 * Double(a.periodSeconds) / 86_400
        guard daysElapsed >= 1 else { return "\(head) \(budget)." }
        return "\(head) \(budget); this week has averaged "
            + "\(Fmt.percent(a.usedPct / daysElapsed)) a day."
    }

    /// "Sun 8:45 pm" — the weekly's reset as a day and a clock, the grain a week is planned in.
    private static func weekdayClock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE h:mm a"
        let text = f.string(from: date)
        return String(text.prefix(3)) + text.dropFirst(3).lowercased()
    }

    /// Credits are paying for this block (`case_1` — `NotificationEngine.overQuotaVariant`,
    /// which sends a spent cap to `case_3`). Claude only; Codex carries no variant.
    private static func isCharging(_ d: NotificationDecision) -> Bool {
        d.eventType == .overQuota && d.copyVariant == "case_1"
    }

    /// The spent limit a charging banner names — the one whose reset ends the charge.
    private static func chargingLimit(_ d: NotificationDecision) -> String {
        blockShape(d) == .plain ? "5-hour" : "Weekly"
    }

    /// Trailing folder of the project path, matching the popover's Project row.
    private static func projectName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The window's name, from the width the provider reported (D-58 — REV-59), shared with the
    /// popover so the two surfaces can never disagree about what reset. `Your 5-hour window has
    /// reset.` is simply false on a 30-day window, and this copy had been asserting it for every
    /// width since the string was written.
    ///
    /// Falls back to `5-hour` when no width was reported — which is every Claude notification, so
    /// Claude's copy is byte-identical — and on Codex only where the provider omitted the duration,
    /// where the old literal is no worse than the silence that would replace it.
    private static func windowName(_ d: NotificationDecision) -> String {
        (DisplayFormatter.windowGrain(seconds: d.primaryWindowSeconds) ?? "5-hour").lowercased()
    }

    private static func resetTime(_ date: Date?) -> String {
        guard let date else { return "reset time" }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// D-63 / D-59 (STEP_99): the unit follows the distance here too. Before this, a 30-day Codex
    /// window rendered **"692h 59m"** in the alert while the popover beside it said "29 days" —
    /// STEP_97 taught `DisplayFormatter` the day band but this file does its own arithmetic and was
    /// missed. `Fmt.daysLong` owns everything at ≥ 48h so the two surfaces cannot disagree; the
    /// hour/minute form below the band is untouched.
    private static func resetIn(_ date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "a few min" }
        if let days = Fmt.daysLong(date, from: now) { return days }
        let mins = max(0, Int(date.timeIntervalSince(now) / 60))
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins) min"
    }

    /// Runway ("~N left at this pace") in the same band. Deliberately **not** `Fmt.runwayLong`:
    /// that rounds where this file has always truncated, and reusing it would move sub-day alert
    /// text by up to a minute. The day band is shared; the sub-day arithmetic is not.
    private static func runwayIn(_ minutes: Double) -> String {
        if let days = Fmt.daysLong(Date().addingTimeInterval(minutes * 60), from: Date()) {
            return days
        }
        return "\(Int(minutes)) min"
    }
}
