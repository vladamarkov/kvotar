import Foundation

/// The one place that knows what a `Subagent · …` bucket is (D-96; moved into Core by D-99).
///
/// `AttributionEngine.surfaceShares` mixes two different things in one list: real surfaces
/// (`Desktop` / `CLI` / `IDE extension` / `Unknown`) and helper threads, which are not surfaces at
/// all — a helper *runs inside* one. Splitting the list once, behind a name, keeps that distinction
/// from turning into scattered `hasPrefix` checks.
///
/// **Why it lives here and not in `DisplayFormatter` (D-99).** D-96 put the split in the UI, so
/// only the *naming* layer applied it: `PollCoordinator` still counted every bucket into
/// `StateInputs.activeSurfaceBucketCount` / `NotificationSignal`, and §13 rule 8's `>= 2` read one
/// desktop app plus its own helper threads as two concurrent surfaces. On a machine that uses
/// subagents that is the ordinary shape, not an edge — the dogfood machine entered `multi_surface`
/// at 2026-08-24 14:57 CEST on `Desktop` + `Subagent · Bacon` + `Subagent · McClintock`, all three
/// written by one `originator: Codex Desktop`. The state engine, the notification engine and the
/// popover copy now read one definition, so they cannot disagree about what a surface is.
///
/// Order is preserved on both sides: `AttributionEngine.surfaceShares` already sorts
/// tokens-descending, so `surfaces` and `helpers` each stay in share order without re-sorting.
public struct SurfaceWorkSplit: Sendable, Equatable {
    /// The prefix both parsers write in front of a helper thread's name
    /// (`ClaudeJSONLParser.surfaceBucket` / `CodexJSONLParser.surfaceBucket`). Declared here
    /// because `KvotarCore` depends on neither adapter package.
    public static let subagentPrefix = "Subagent · "

    /// The bucket an unmapped originator lands in (`CodexJSONLParser.surfaceUnknown`). It stays
    /// in `surfaces` (it burns quota like any other and the whole-window split must sum), but it is
    /// **not an active surface** (STEP_192, owner ruling 2026-09-13): it cannot be named, so a
    /// multi-surface state it helped trigger could only ever print the unnamed fallback — and an
    /// unmapped originator is far more often a *renamed* known surface (`codex-tui`, the CLI) than
    /// a genuinely new one. The cost — a real new surface goes unwarned until §8.4 maps its name —
    /// is the right trade for the one-account user.
    public static let unknownLabel = "Unknown"

    /// Claude's one and only surface (`ClaudeJSONLParser.surfaceMainAgent`, REV-81: Desktop chat
    /// writes no JSONL). Named here since STEP_197 because Core resolves a Claude helper thread
    /// back to it in the daily fold, and a second copy of the string is a second thing to drift.
    public static let claudeMainAgent = "Claude Code"

    /// Non-helper buckets — the only labels the UI may ever *name*, and the only ones §13 rule 8
    /// counts as concurrently-active surfaces.
    public let surfaces: [SurfaceShare]

    /// `Subagent · …` buckets. Counted and summed; their nicknames never reach the UI (D-96).
    public let helpers: [SurfaceShare]

    public init(_ shares: [SurfaceShare]) {
        surfaces = shares.filter { !$0.label.hasPrefix(Self.subagentPrefix) }
        helpers = shares.filter { $0.label.hasPrefix(Self.subagentPrefix) }
    }

    /// The helper share of the window total.
    public var helperFraction: Double { helpers.reduce(0) { $0 + $1.fraction } }

    /// Everything that is not a helper — the `Main thread` share. Taken as the remainder rather
    /// than summed separately so the two rows always describe one denominator, which is the whole
    /// of D-96's argument. Zero Codex event rows carry a NULL `surface_bucket` (REV-76 §2.4), so
    /// the two genuinely account for the total.
    public var mainFraction: Double { max(0, 1 - helperFraction) }

    /// The surfaces *burning now* — §13 rule 8's count and the only list the multi-surface card
    /// and the event 6 notification may name (STEP_192, closing A28). `surfaces` is the whole
    /// window's split, so on a weekly hero a surface used once on Monday stayed "active" — and,
    /// holding the larger window share, was named the primary driver — all week. A surface is
    /// active when its newest token event is within `gap` of `now`: the same 8-minute idle gap
    /// (`LocalAttribution.idleGap`, REV-23) that decides `All local surfaces idle`, so the card
    /// and the Local source row cannot disagree. Share order is preserved, so `[0]` is still the
    /// larger *window* share of the active pair. Accepted lag: `recorded_at` is the token line,
    /// which Codex writes 20–30 min into a turn (STEP_170), so a surface can read idle while it
    /// works — it can never read active while it does not. `Unknown` is never active (see
    /// `unknownLabel`), so every label in this list is one the UI may print.
    public func activeSurfaces(now: Date, gap: TimeInterval = LocalAttribution.idleGap) -> [SurfaceShare] {
        surfaces.filter { share in
            guard share.label != Self.unknownLabel, let at = share.lastEventAt else { return false }
            return now.timeIntervalSince(at) < gap
        }
    }
}
