import Foundation

/// The weekly notification ladder — **50 → 25 → 10 → 0 % left** (Baseline §16, REV-106 —
/// STEP_232; the third mark is 15 on a seven-day primary, where that tab turns red —
/// STEP_238). The two lower rungs are shipped events (9 `limit_nearly_spent`, 3 `over_quota`);
/// this type is the two upper ones, event 10 `limit_ahead_of_pace`, and the key that remembers
/// how far down a weekly instance has already been announced.
///
/// Pure: `NotificationEngine` owns the reads, the writes and the decision.
public enum WeeklyLadder {

    /// **The switch.** On since STEP_233, which shipped the copy; STEP_232 decided every step
    /// behind it and logged `Ladder would send`. Off, the engine writes no key, delivers
    /// nothing, and leaves events 2 and 9 as they were before REV-106 — the revert target.
    public static let isEnabled = true

    /// Event 10's two steps, carried as the decision's copy variant and as the stored half of
    /// the key. *Ahead of pace* is the amber tier; which step it is depends only on position.
    public enum Step: String, Sendable, Equatable {
        /// Half gone and off pace — below `weeklySecondNoticePct`.
        case half
        /// A quarter left and off pace — at or past it.
        case quarter

        /// How far down the ladder this step is. A step is sent only when it is deeper than
        /// everything already announced for the instance, which is the whole no-catch-up rule.
        var depth: Int {
            switch self {
            case .half: return 1
            case .quarter: return 2
            }
        }
    }

    /// The depth of *nearly spent* and *spent*: below both early steps, so once either has been
    /// announced for an instance neither early step can follow.
    static let depthBelowEarlySteps = 3

    /// The step this weekly is standing on, or `nil` when it is not on an early one — on pace,
    /// or already at the red line, where events 9 and 3 speak instead.
    public static func step(for weekly: LongLimitAssessment) -> Step? {
        guard weekly.tier == .aheadOfPace else { return nil }
        return weekly.usedPct >= StateEngine.weeklySecondNoticePct ? .quarter : .half
    }

    // MARK: The key (§17.1)

    /// `settings["ladder.<tool>.<limit>"]` — one row per weekly, the `nearly_spent.*` shape.
    public static func settingsKey(tool: Tool, limit: BlockEpisode.Limit) -> String {
        "ladder.\(tool.rawValue).\(limit.rawValue)"
    }

    /// `resetsAt|lowestStep`: the instance, and the deepest early step sent for it.
    public static func storedValue(for weekly: LongLimitAssessment, step: Step) -> String {
        "\(Int(weekly.resetsAt.timeIntervalSince1970))|\(step.rawValue)"
    }

    static func parse(_ raw: String?) -> (epoch: TimeInterval, step: Step)? {
        guard let parts = raw?.split(separator: "|"), parts.count == 2,
              let epoch = TimeInterval(parts[0]),
              let step = Step(rawValue: String(parts[1])) else { return nil }
        return (epoch, step)
    }

    /// The deepest early step a stored value records **for this instance** — compared through
    /// the one Core reset tolerance, never by string, for the reason `matchesNearlySpent` gives.
    /// A value about another week, or an unreadable one, records nothing.
    static func announcedStep(storedValue: String?, for weekly: LongLimitAssessment) -> Step? {
        guard let stored = parse(storedValue),
              QuotaSnapshot.isSameResetInstant(stored.epoch, weekly.resetsAt) else { return nil }
        return stored.step
    }
}
