import Foundation

/// The §11.5 learned tables for one tool: how often usage rose from each account state, how large
/// those rises were, and which short/long weight predicted them best (REV-95 §3.3 — STEP_190).
///
/// **Derived data, never a stored conclusion.** Nothing here is written to any table: the counts are
/// recomputed from `quota_series` at launch and on window close and held in memory, which is §17's
/// substrate principle applied rather than excepted — a stored `p = 0.88` would go stale the day the
/// rule changed, the raw series never does.
///
/// A fresh install carries empty cells and reads exactly `ShadowTables.prior`; the user's own
/// origins accumulate on top of it from day one (Spike D §5.1).
public struct ShadowTables: Sendable, Equatable {

    /// One account state's history: how many origins, how many of them rose, how much they rose by,
    /// and the blend weight that fit them.
    public struct Cell: Sendable, Equatable {
        /// Origins whose 30-minute rise reached `ShadowPolicy.riseThreshold`.
        public let hits: Int
        /// Origins in this cell.
        public let n: Int
        /// The grid weight minimising absolute error on this cell, or nil below
        /// `ShadowPolicy.alphaMinCell` fittable origins.
        public let alpha: Double?
        /// Each origin's observed 30-minute rise, in points.
        public let rises: [Double]

        public init(hits: Int, n: Int, alpha: Double?, rises: [Double]) {
            self.hits = hits
            self.n = n
            self.alpha = alpha
            self.rises = rises
        }

        static let empty = Cell(hits: 0, n: 0, alpha: nil, rises: [])
    }

    public let cells: [ShadowAccountState: Cell]
    /// The all-state blend weight, used by a cell too small for its own (§3.3).
    public let allStateAlpha: Double?
    /// How many completed, eligible windows the tables were built from — logged, not a gate.
    public let completedWindows: Int
    /// Total origins across every cell.
    public var originCount: Int { cells.values.reduce(0) { $0 + $1.n } }

    public init(cells: [ShadowAccountState: Cell], allStateAlpha: Double?, completedWindows: Int) {
        self.cells = cells
        self.allStateAlpha = allStateAlpha
        self.completedWindows = completedWindows
    }

    /// No history at all — what every tool starts the process with, and what a machine with no
    /// eligible windows keeps. Every lookup below then returns the prior unchanged.
    public static let empty = ShadowTables(cells: [:], allStateAlpha: nil, completedWindows: 0)

    // MARK: - Lookups (the §11.5 formulas)

    /// `alpha[state]` — the user's own fit where the cell is big enough, else their all-state fit,
    /// else the prior's (§3.3).
    public func alpha(for state: ShadowAccountState) -> Double {
        cells[state]?.alpha ?? allStateAlpha ?? Self.prior.alpha[state] ?? Self.prior.allStateAlpha
    }

    /// `p = (k·p₀[state] + hits[state]) / (k + n[state])` — Spike D §5.1's formula, with the
    /// shipped prior as `p₀`. At `n = 0` this is exactly the prior; a cell with a few hundred of
    /// the user's own origins is essentially their own rate.
    ///
    /// **This reads §3.3's `p_global` as the prior for that state, not one pooled number**, and
    /// drops the "< 10 completed windows" switch with it (STEP_190 ruling, recorded in §11.5): a
    /// single smooth formula has no cliff at the tenth window, and Spike D §5.1 — the source §3.3
    /// compresses — states it in exactly this shape.
    public func probability(for state: ShadowAccountState) -> Double {
        let k = ShadowPolicy.shrinkageK
        let p0 = Self.prior.probability[state] ?? 0.5
        let cell = cells[state] ?? .empty
        return (k * p0 + Double(cell.hits)) / (k + Double(cell.n))
    }

    /// The 10th and 90th percentile of the 30-minute rise: the user's own origins for this state at
    /// weight 1 each, with the prior's twenty representative points mixed in at weight `k / 20 = 1`
    /// — total prior weight `k`, which is §3.3's "the global set mixed in at weight k / n_global".
    public func riseRange(for state: ShadowAccountState) -> (p10: Double, p90: Double) {
        let priorWeight = ShadowPolicy.shrinkageK / Double(Self.prior.rises.count)
        var items = Self.prior.rises.map { (value: $0, weight: priorWeight) }
        items.append(contentsOf: (cells[state]?.rises ?? []).map { (value: $0, weight: 1.0) })
        return (ShadowQuantile.weighted(items, 0.10), ShadowQuantile.weighted(items, 0.90))
    }
}

// MARK: - The shipped prior

extension ShadowTables {

    /// The default every install starts from, and — because STEP_190 ruling 1 makes only v24-era
    /// windows eligible — what actually runs for the first fortnight after this ships.
    ///
    /// **Derived once, offline, from the owner's own corpus** (2026-09-14: 77 completed five-hour
    /// windows, 1,862 origins) through the same origin rules the live path uses, and pinned by
    /// `ShadowTablesTests` so it cannot drift silently. Three things about it are stated rather
    /// than hidden:
    ///
    /// 1. **It is one user's, and it is a placeholder** (REV-95 §6 trade 2). Mechanisms are expected
    ///    to generalise — recent movement persists — percentages are not. Alpha diagnostics bundles
    ///    are the experiment that would widen it.
    /// 2. **It is Claude-only.** Codex contributed **zero** eligible windows: this account's Codex
    ///    plan reports a seven-day primary (long, excluded by §11.5's short-window scope) and every
    ///    older five-hour Enterprise row predates `v23`, so it states no width and STEP_186's rule
    ///    refuses to guess one. Both tools use it until each has its own history.
    /// 3. **It mixes pre- and post-warning behaviour**, because the exposure column did not exist
    ///    before 2026-09-13. That is precisely what Spike D §4.1 flags about its own table, and why
    ///    the *learned* tables apply the pre-warning filter that this prior cannot.
    ///
    /// The probabilities corroborate Spike D F9/§4.1's independent account-only reading
    /// (burning ~0.80–0.88, paused ~0.50, quiet ~0.30) closely enough to be the same finding.
    public static let prior = Prior(
        probability: [.burning: 0.877, .paused: 0.620, .quiet: 0.282],
        // Read plainly: while the account is **burning**, the trailing hour predicts the next half
        // hour better than the last eighteen minutes do (MAE 6.01 vs 6.85 points); while it is
        // **quiet**, the short buffer does (2.03 vs 2.49); **paused** sits between at 0.75. Each
        // minimum is the bottom of a smooth five-point curve, not an edge artefact.
        alpha: [.burning: 0.0, .paused: 0.75, .quiet: 1.0],
        allStateAlpha: 0.5,
        // Twenty equally-weighted representative points — the 2.5th, 7.5th … 97.5th percentiles of
        // the 1,862 observed 30-minute rises. Over these twenty the range reads 0.0 / 11.4 against
        // the full distribution's 0.0 / 12.0; carrying the tail exactly would mean shipping 1,862
        // doubles to move the 90th percentile by half a point.
        rises: [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 2, 3, 4, 5, 6, 7, 8, 11, 15, 24.475])

    /// The shipped prior's shape. A value rather than loose statics so a test can assert the whole
    /// table at once and so nothing can read half of one generation and half of another.
    public struct Prior: Sendable, Equatable {
        public let probability: [ShadowAccountState: Double]
        public let alpha: [ShadowAccountState: Double]
        public let allStateAlpha: Double
        public let rises: [Double]

        public init(probability: [ShadowAccountState: Double], alpha: [ShadowAccountState: Double],
                    allStateAlpha: Double, rises: [Double]) {
            self.probability = probability
            self.alpha = alpha
            self.allStateAlpha = allStateAlpha
            self.rises = rises
        }
    }
}
