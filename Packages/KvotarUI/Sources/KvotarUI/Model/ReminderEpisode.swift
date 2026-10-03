import Foundation
import KvotarCore

/// One continuing long-limit warning, and the two clocks the menu-bar reminder is scheduled
/// against (UI Spec §1.3 / §5, REV-98 §2.3 — STEP_202).
///
/// Until this step the anchor was a single in-memory `Date` per tool, cleared the moment the
/// formatter stopped emitting reminders. That made three different things look identical: a
/// relaunch, a poll that came back stale, and a genuine recovery followed by a re-entry. All
/// three replayed the reminder from the top, which on a warning that is true for four days is
/// the loudest possible reading of the quietest possible fact.
///
/// **Two clocks, deliberately separate.** `enteredAt` is when this limit first entered *any*
/// warning tier and never moves inside an episode. `tierAt` is when the current tier began and
/// moves on escalation — which is what lets red's first hour restart without the episode
/// restarting. The cadence is measured from `tierAt`; `enteredAt` is what tells a relaunch from
/// a re-entry.
///
/// **It lives beside `MenuBarReminder` rather than in Core** — the schedule is a menu-bar
/// concern and this is its state, the way `MenuBarDisplayMode` owns its own §17.1 settings key
/// in this same package. The *vocabulary* is Core's: the limit is `BlockEpisode.Limit` and the
/// reset is compared through `QuotaSnapshot.isSameResetInstant`, so a stored key can never name
/// a limit the assessment cannot, and a one-second endpoint wobble is never a new episode.
public struct ReminderEpisode: Sendable, Equatable {

    public let tool: Tool
    /// Which long limit this episode is about. Never `.primary` — the five-hour window speaks
    /// through the ordinary string and outranks every long-limit rank (§2.4).
    public let limit: BlockEpisode.Limit
    /// The tier as of the last live reading. Drives which cadence column applies.
    public var tier: LongLimitAssessment.Tier
    /// When this limit first entered any warning tier. Never moves inside an episode.
    public let enteredAt: Date
    /// When the current tier began. Moves on escalation, and only on escalation.
    public var tierAt: Date
    /// The limit instance — a different reset is a different week, and a different episode.
    public let resetsAt: Date

    /// When a restored episode was confirmed live again after a relaunch. **Transient**: never
    /// stored, and cleared by a recovery like everything else. It buys the one off-grid reminder
    /// §2.3 asks for — the reader has been away, not newly warned, so they get the situation once
    /// and then the decayed cadence at the episode's true age.
    public var resumedAt: Date?
    /// Set on a restore, cleared the first time the episode is seen live. Between the two the
    /// episode is held: at launch there is no reading yet, and reminding about a tier the app has
    /// not re-confirmed would be asserting a stale claim (D-35).
    public var awaitingResume: Bool
    /// When the reader opened the popover during this amber episode (REV-100 §2.2 — STEP_211).
    /// **Stored**, unlike the two fields above: a look is a fact about the episode, not about
    /// this run of the app, so a relaunch after it owes no resume reminder. Kept on escalation
    /// and ignored there — `MenuBarReminder` honours it in amber only.
    public var acknowledgedAt: Date?

    public init(tool: Tool, limit: BlockEpisode.Limit, tier: LongLimitAssessment.Tier,
                enteredAt: Date, tierAt: Date, resetsAt: Date,
                resumedAt: Date? = nil, awaitingResume: Bool = false,
                acknowledgedAt: Date? = nil) {
        self.tool = tool
        self.limit = limit
        self.tier = tier
        self.enteredAt = enteredAt
        self.tierAt = tierAt
        self.resetsAt = resetsAt
        self.resumedAt = resumedAt
        self.awaitingResume = awaitingResume
        self.acknowledgedAt = acknowledgedAt
    }

    // MARK: Storage (§17.1)

    /// The `settings` row this episode is stored under — one per tool per limit, keyed the way
    /// event 9's `nearly_spent.<tool>.<limit>` already is.
    public static func settingsKey(tool: Tool, limit: BlockEpisode.Limit) -> String {
        "reminder_episode.\(tool.rawValue).\(limit.rawValue)"
    }

    /// `<enteredAt>|<tierAt>|<tier>|<resetsAt>|<acknowledgedAt>`, all unix seconds but the tier;
    /// the fifth field is empty while the episode is unacknowledged (STEP_211). The two transient
    /// fields are absent by construction: a resume belongs to this run of the app.
    public var storedValue: String {
        [String(Int(enteredAt.timeIntervalSince1970)),
         String(Int(tierAt.timeIntervalSince1970)),
         String(tier.rawValue),
         String(Int(resetsAt.timeIntervalSince1970)),
         acknowledgedAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""].joined(separator: "|")
    }

    /// Rebuilds an episode from its stored row, or `nil` if the row is malformed — a settings
    /// value written by a future build must not crash a menu bar. A restored episode is
    /// `awaitingResume`: it reminds once when a live reading confirms it, not before — unless it
    /// was acknowledged.
    ///
    /// A four-field row, written before STEP_211, restores as unacknowledged. The split keeps
    /// empty fields: the default drops a trailing empty one, which would make every
    /// unacknowledged five-field row look like a four-field one by accident rather than by rule.
    public static func restored(tool: Tool, limit: BlockEpisode.Limit,
                                storedValue: String) -> ReminderEpisode? {
        let parts = storedValue.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4 || parts.count == 5,
              let entered = TimeInterval(parts[0]), let tierAt = TimeInterval(parts[1]),
              let tierRaw = Int(parts[2]), let tier = LongLimitAssessment.Tier(rawValue: tierRaw),
              let resets = TimeInterval(parts[3]) else { return nil }
        var acknowledged: Date?
        if parts.count == 5, !parts[4].isEmpty {
            guard let at = TimeInterval(parts[4]) else { return nil }
            acknowledged = Date(timeIntervalSince1970: at)
        }
        return ReminderEpisode(tool: tool, limit: limit, tier: tier,
                               enteredAt: Date(timeIntervalSince1970: entered),
                               tierAt: Date(timeIntervalSince1970: tierAt),
                               resetsAt: Date(timeIntervalSince1970: resets),
                               awaitingResume: true, acknowledgedAt: acknowledged)
    }

    /// Whether a live reading describes **this** instance. Not a string comparison, for the
    /// reason `BlockEpisode.matches` is not one: the provider wobbles `resets_at` by a second
    /// between polls, and on a string match that wobble reads as a new week.
    public func matches(resetsAt instant: Date) -> Bool {
        QuotaSnapshot.isSameResetInstant(instant.timeIntervalSince1970, resetsAt)
    }
}
