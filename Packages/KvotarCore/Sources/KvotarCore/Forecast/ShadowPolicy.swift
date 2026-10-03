import Foundation

/// Every constant the §11.5 shadow computation uses, in one place, because STEP_191 grades the
/// exact rule that ran and must be able to name it (REV-95 §3.3: *"Constants … are recorded here so
/// STEP_191 grades the exact rule that ran"*).
///
/// None of these is learned. REV-95 §5 is explicit: `k`, the alpha grid and the gates are constants
/// set by revision and never mutated at runtime — only the *counts* are recomputed on the Mac.
public enum ShadowPolicy {

    /// Generation stamp written to `forecast_log.shadow_version`.
    public static let version = "s1"

    /// The horizon the rise probability and the range describe: half an hour.
    public static let riseHorizon: TimeInterval = 1800

    /// Two origins closer together than this are the same working stretch seen twice. At a 120 s
    /// cadence a 30-minute stretch contributes ~15 correlated polls, which overstates independence
    /// by roughly 10× (Spike D F12) — this is the de-correlation lever §3.3 chose.
    public static let originSpacing: TimeInterval = 300

    /// How near a poll must sit to a wanted instant (`origin − 10 min`, `origin − 30 min`,
    /// `origin + 30 min`) to stand in for it. **Not stated by REV-95 §3.3** — added here because
    /// the rule cannot run without one and a grader cannot reproduce the run without knowing it.
    /// The value is the reference implementation's (`run_experiment.py` `TARGET_TOLERANCE`), so
    /// the shipped rule and the experiment that justified it match.
    public static let originMatchTolerance: TimeInterval = 180

    /// How close the last observation must sit to a window's reset before its ending counts as
    /// observed. **§3.3's own number**, and deliberately not `QuotaWindowOutcomes`'s 240 s default:
    /// the chart's question is "did we watch this window close", this one's is "is the outcome
    /// trustworthy enough to learn from". The reference implementation used 4 minutes; the
    /// contract says 15, and the contract wins (STEP_190 ruling 3).
    public static let windowCloseTolerance: TimeInterval = 900

    /// Pseudo-origins the shipped prior is worth. Spike D §5.1: each cell starts at the shipped
    /// default weighted as `k` observations and adds the user's own on top, so a fresh install
    /// reads the prior exactly and a heavy user's own history overtakes it inside a few days.
    public static let shrinkageK = 20.0

    /// The short-rate share is chosen from this grid, never fitted continuously — five values keep
    /// the choice legible and cannot overfit a small cell (reference `AdaptiveBlend.GRID`).
    public static let alphaGrid: [Double] = [0, 0.25, 0.5, 0.75, 1]

    /// Fittable origins a state needs before it gets its own alpha; below it the all-state weight
    /// is used, and below *that* the shipped prior's (§3.3: "≥ 30 origins, else the all-state
    /// weight").
    public static let alphaMinCell = 30

    /// How far back the training read reaches. **Not stated by §3.3** — a bounded read needs a
    /// bound, and thirty days is the period every other retrospective surface on this app already
    /// uses (`HistoryReportReader`), so the shadow's training set and the History window describe
    /// the same span.
    public static let trainingLookback: TimeInterval = 30 * 86_400

    /// A rise of at least this many points counts as "usage rose measurably" — the label the
    /// probability predicts. One point is the endpoints' own reporting quantum (§11.2a), so this
    /// is the smallest rise either provider can express.
    public static let riseThreshold = 1.0
}
