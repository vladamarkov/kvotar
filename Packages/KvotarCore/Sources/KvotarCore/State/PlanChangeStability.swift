import Foundation

/// One plan-name transition, as the detector is about to write it or as the corpus stored it
/// (REV-73 §4.2 / D-81 — STEP_121). Values are the provider's own strings; `nil` is a plan the
/// payload did not carry.
public struct PlanTransition: Sendable, Equatable {
    public let at: Date
    public let from: String?
    public let to: String?

    public init(at: Date, from: String?, to: String?) {
        self.at = at
        self.from = from
        self.to = to
    }
}

/// **Two plan names that trade places are two sources disagreeing, not an account changing.**
///
/// The dogfood corpus holds 248 Codex `plan_changed` rows, of which **245** are `enterprise ↔
/// business` round-trips — Codex reports the plan name from two payloads that disagree
/// (`account/read.planType ?? rateLimits.planType`), and every disagreement was faithfully written
/// down as history. Exactly three rows are real: `business → free`, `free → go`, `go → plus`.
///
/// One idea, applied in two places, so the write side and the read side cannot drift apart:
///
/// - **`isDamped` — the write gate** (`DiscontinuityDetector`). A transition is not recorded when
///   the same unordered name pair already produced one inside `dampingWindow`. The **first** flip
///   of an episode is still recorded: one disagreement is a real observation, and recording it is
///   §17's substrate principle rather than an exception to it — the raw fact is *the sources
///   disagreed*. What the gate refuses is the 20-a-day repetition of that same fact. A genuine plan
///   change is recorded immediately, because its pair has no recent history.
/// - **`settled` — the read collapse** (`HistoryReportReader`). Inside the report's period, a pair
///   accounting for `unstablePairTransitions` or more transitions is unstable and **none** of its
///   rows are drawn. The stored rows are permanent and are never deleted (REV-73 §6) — the display
///   simply declines to call them changes. A genuine up-then-down inside one month is two
///   transitions and survives.
///
/// **Accepted corner:** a brand-new install on a flapping account can draw one such row in its
/// first week and two in its second, before enough rows exist for the collapse to recognise the
/// pair. From the third on, the block is clean and stays clean.
///
/// Pure — no I/O, no clock of its own; every instant is passed in.
public enum PlanChangeStability {

    /// How far back the write gate looks for the same pair. Long enough to cover a flapping
    /// episode (the corpus flipped ~2×/day for 13 days), short enough that a pair which genuinely
    /// settles re-arms on its own.
    public static let dampingWindow: TimeInterval = 7 * 86_400

    /// Transitions of one pair, inside the read period, at which the display stops believing the
    /// pair. Three, not two: a user who upgrades and comes back down inside a month produces
    /// exactly two, and that is a real story about their account.
    public static let unstablePairTransitions = 3

    /// The unordered pair, as a comparable key. `nil` when either side is missing — a transition
    /// with an unknown half never pairs with anything, so it is neither damped nor collapsed.
    static func pairKey(_ from: String?, _ to: String?) -> String? {
        guard let from, let to, from != to else { return nil }
        return from < to ? "\(from)\u{0}\(to)" : "\(to)\u{0}\(from)"
    }

    /// Has this pair already traded places inside `dampingWindow` before `at`?
    ///
    /// `history` is what was **stored**, not what was observed — the gate suppresses writes, so a
    /// damped episode leaves one row and the window empties from that row, which is what bounds the
    /// corpus at roughly one row per pair per week instead of ~600 a month.
    public static func isDamped(from: String?, to: String?, at: Date,
                                history: [PlanTransition]) -> Bool {
        guard let key = pairKey(from, to) else { return false }
        let earliest = at.addingTimeInterval(-dampingWindow)
        return history.contains {
            $0.at >= earliest && $0.at <= at && pairKey($0.from, $0.to) == key
        }
    }

    /// The transitions worth drawing, in the order given. Every row of an unstable pair drops —
    /// including the first and the last, because "the account was one of these two names for a
    /// while" is one indistinct state, not a sequence of changes.
    public static func settled(_ transitions: [PlanTransition]) -> [PlanTransition] {
        var counts: [String: Int] = [:]
        for transition in transitions {
            guard let key = pairKey(transition.from, transition.to) else { continue }
            counts[key, default: 0] += 1
        }
        return transitions.filter { transition in
            guard let key = pairKey(transition.from, transition.to) else { return true }
            return (counts[key] ?? 0) < unstablePairTransitions
        }
    }
}
