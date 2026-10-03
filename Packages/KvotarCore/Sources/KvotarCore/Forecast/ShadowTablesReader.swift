import Foundation

/// One window's warning exposure, folded from `forecast_log` (REV-95 §3.2 — STEP_190).
///
/// Two facts, and the first is load-bearing. `recorded` says the window was observed by a build
/// that *had* the exposure column: before migration `v24` (2026-09-13) `warning_first_shown_at` is
/// NULL on every row because the column did not exist, not because no warning was shown, and
/// training on those rows would feed the probability exactly the post-warning behaviour §3.2 exists
/// to exclude. `displayed_state` landed in the same migration and is never null afterwards, so it is
/// the durable marker that exposure was being recorded at all (STEP_190 ruling 1).
public struct WindowExposure: Sendable, Equatable {
    /// The window's `primary_resets_at`, as `forecast_log` recorded it.
    public let anchor: Date
    /// Any row for this window carries a `displayed_state` — i.e. a v24-era build wrote it.
    public let recorded: Bool
    /// The earliest non-null `warning_first_shown_at` across the window's rows; nil if none warned.
    public let warningFirstShownAt: Date?

    public init(anchor: Date, recorded: Bool, warningFirstShownAt: Date?) {
        self.anchor = anchor
        self.recorded = recorded
        self.warningFirstShownAt = warningFirstShownAt
    }
}

/// Builds the §11.5 learned tables from persisted polls — pure over its rows, so the whole rule is
/// unit-testable without a database and `ForecastEngine` keeps its promise never to read one.
///
/// The population is §3.3's, in full: **completed** windows with an **observed** ending, **short**
/// windows only, **pre-warning** origins only, spaced at least `originSpacing` apart, and — per
/// ruling 1 — only windows a v24-era build recorded exposure for.
public enum ShadowTablesReader {

    /// One training origin: what the account was doing, what the two rate estimators said at that
    /// moment, and what actually happened over the next half hour.
    struct Origin {
        let state: ShadowAccountState
        /// The shipped §11.2/§11.3 burn at this origin, %/min, or nil where it did not resolve.
        let shortRate: Double?
        /// The §11.5 long rate at this origin, %/min, or nil where it did not resolve.
        let longRate: Double?
        /// Points the primary window actually rose over `riseHorizon`.
        let actualRise: Double
    }

    /// - Parameters:
    ///   - tool: the tool these rows belong to.
    ///   - points: `quota_series` rows over the training lookback, any order.
    ///   - exposures: `forecast_log` exposure rows over the same span.
    ///   - now: the clock separating a completed window from the current one.
    public static func build(tool: Tool, points: [QuotaSeriesPoint],
                             exposures: [WindowExposure], now: Date) -> ShadowTables {
        // Eligibility, width resolution and the ±60 s anchor fold are `QuotaWindowOutcomes`' job
        // already (STEP_181/STEP_186) — reusing it is what keeps the shadow's idea of a finished
        // window and the History window's identical. Only the close tolerance differs, and it is a
        // parameter: the chart asks "did we watch it close", this asks "is the ending trustworthy
        // enough to learn from" (§3.3's 15 minutes).
        let outcomes = QuotaWindowOutcomes.compute(
            tool: tool, points: points, now: now, tolerance: ShadowPolicy.windowCloseTolerance)

        var origins: [Origin] = []
        var eligibleWindows = 0
        for outcome in outcomes where isEligible(outcome, exposures: exposures) {
            let group = points
                .filter { abs($0.resetsAt.timeIntervalSince(outcome.resetsAt))
                            <= QuotaWindowOutcomes.anchorJitterTolerance }
                .sorted { $0.polledAt < $1.polledAt }
            guard group.count >= 3 else { continue }
            eligibleWindows += 1
            origins.append(contentsOf: windowOrigins(
                group, warnedAt: exposure(outcome, in: exposures)?.warningFirstShownAt,
                windowSeconds: outcome.windowSeconds))
        }
        return tables(from: origins, completedWindows: eligibleWindows)
    }

    // MARK: - Eligibility

    private static func exposure(_ outcome: QuotaWindowOutcome,
                                 in exposures: [WindowExposure]) -> WindowExposure? {
        exposures.first {
            abs($0.anchor.timeIntervalSince(outcome.resetsAt))
                <= QuotaWindowOutcomes.anchorJitterTolerance
        }
    }

    private static func isEligible(_ outcome: QuotaWindowOutcome,
                                   exposures: [WindowExposure]) -> Bool {
        // Observed ending. A window whose close nobody watched has a floor, not an outcome, and a
        // floor cannot say whether usage rose in its last half hour.
        guard outcome.completion == .completedFull else { return false }
        // Short windows only in this revision (§3.3). An unresolved width is excluded rather than
        // guessed — REV-93 §4's rule, reused: a plan name and a neighbour row are not evidence.
        guard let width = outcome.windowSeconds,
              TimeInterval(width) < ForecastEngine.longWindowFrom else { return false }
        // Ruling 1: exposure has to have been recordable.
        return exposure(outcome, in: exposures)?.recorded == true
    }

    // MARK: - Origins

    private static func windowOrigins(_ group: [QuotaSeriesPoint], warnedAt: Date?,
                                      windowSeconds: Int?) -> [Origin] {
        let times = group.map(\.polledAt)
        let used = group.map(\.usedPct)
        let policy = ForecastEngine.bufferPolicy(
            windowLength: TimeInterval(windowSeconds ?? 18_000))
        // Both rates for every sample in one forward pass — the buffers evolve exactly as the live
        // engine's do, so replaying them per origin would redo the same work quadratically.
        let shortRates = rates(times: times, used: used, trimmedTo: policy)
        let longRates = rates(times: times, used: used, trimmedTo: nil)

        var result: [Origin] = []
        var lastOriginAt: Date?
        for (index, at) in times.enumerated() {
            if let last = lastOriginAt,
               at.timeIntervalSince(last) < ShadowPolicy.originSpacing { continue }
            // Pre-warning origins only (§3.2): once a warning had been displayed in this window,
            // what follows is partly the user's response to the app, not their demand (Spike D F13).
            if let warnedAt, at >= warnedAt { continue }

            guard let future = nearest(times, to: at + ShadowPolicy.riseHorizon, from: index + 1),
                  let past10 = nearest(times, to: at - 600), times[past10] <= at,
                  let past30 = nearest(times, to: at - 1800), times[past30] <= at
            else { continue }

            let moved10 = max(0, used[index] - used[past10])
            let moved30 = max(0, used[index] - used[past30])
            let state: ShadowAccountState = moved10 >= ShadowPolicy.riseThreshold
                ? .burning
                : (moved30 >= ShadowPolicy.riseThreshold ? .paused : .quiet)

            result.append(Origin(
                state: state,
                shortRate: shortRates[index],
                longRate: longRates[index],
                actualRise: max(0, used[future] - used[index])))
            lastOriginAt = at
        }
        return result
    }

    /// The nearest sample to `target` within `originMatchTolerance`, or nil. A missing neighbour is
    /// why an origin is skipped rather than classified `quiet`: "we did not look" is not "nothing
    /// happened" (§3.3 — unknown ⇒ no shadow row, never quiet).
    private static func nearest(_ times: [Date], to target: Date, from low: Int = 0) -> Int? {
        var best: Int?
        for index in low..<times.count {
            let distance = abs(times[index].timeIntervalSince(target))
            guard distance <= ShadowPolicy.originMatchTolerance else { continue }
            if best == nil || distance < abs(times[best!].timeIntervalSince(target)) {
                best = index
            }
        }
        return best
    }

    /// Replays the burn rate as it stood at every sample, in one forward pass.
    ///
    /// `trimmedTo` non-nil replays the **shipped** buffer — the `sampleMaxAge` sweep plus the
    /// span-aware count trim (§11.2a, REV-65/REV-74) — so the training short rate is the same
    /// quantity the live path feeds into `blend_rate`. `nil` replays the **untrimmed ≤ 1 h** ring,
    /// which is the §11.5 long rate. Both end in the same two-point rule and the same zero-proof:
    /// a flat span shorter than the proof claims nothing (§11.2a Rule 1).
    ///
    /// The window-rollover clears the live engine applies are deliberately absent: every sample
    /// here already belongs to **one** window by construction (the group is one anchor's rows), so
    /// there is no rollover inside the replay to clear on.
    private static func rates(times: [Date], used: [Double],
                              trimmedTo policy: ForecastEngine.BufferPolicy?) -> [Double?] {
        let zeroProof = (policy ?? ForecastEngine.shortWindowBuffer).zeroProofSpan
        var result: [Double?] = []
        var buffer: [Int] = []
        for step in times.indices {
            buffer.removeAll {
                times[step].timeIntervalSince(times[$0]) > ForecastEngine.sampleMaxAge
            }
            buffer.append(step)
            if let policy {
                while buffer.count > policy.countCap,
                      times[buffer[buffer.count - 1]].timeIntervalSince(times[buffer[1]])
                        >= policy.retentionSpan {
                    buffer.removeFirst()
                }
            }
            result.append(twoPointRate(times: times, used: used, buffer: buffer,
                                       zeroProof: zeroProof))
        }
        return result
    }

    /// §11.2's two-point rule over a buffer of indices, with §11.2a Rule 1's zero-proof.
    private static func twoPointRate(times: [Date], used: [Double], buffer: [Int],
                                     zeroProof: TimeInterval) -> Double? {
        guard buffer.count >= 2, let first = buffer.first, let last = buffer.last else { return nil }
        let span = times[last].timeIntervalSince(times[first])
        guard span > 0 else { return nil }
        let delta = max(0, used[last] - used[first])
        guard delta > 0 || span >= zeroProof else { return nil }
        return delta / (span / 60)
    }

    // MARK: - Fold

    private static func tables(from origins: [Origin], completedWindows: Int) -> ShadowTables {
        var cells: [ShadowAccountState: ShadowTables.Cell] = [:]
        for state in ShadowAccountState.allCases {
            let cell = origins.filter { $0.state == state }
            guard !cell.isEmpty else { continue }
            cells[state] = ShadowTables.Cell(
                hits: cell.filter { $0.actualRise >= ShadowPolicy.riseThreshold }.count,
                n: cell.count,
                alpha: bestAlpha(cell),
                rises: cell.map(\.actualRise))
        }
        return ShadowTables(cells: cells, allStateAlpha: bestAlpha(origins),
                            completedWindows: completedWindows)
    }

    /// The grid weight minimising mean absolute error of the predicted 30-minute rise against the
    /// observed one, over origins where **both** rates resolved — the reference implementation's
    /// `AdaptiveBlend._best_alpha`. nil below `alphaMinCell`, so a small cell borrows rather than
    /// overfits.
    static func bestAlpha(_ origins: [Origin]) -> Double? {
        let fittable = origins.compactMap { origin -> (Double, Double, Double)? in
            guard let short = origin.shortRate, let long = origin.longRate else { return nil }
            return (short, long, origin.actualRise)
        }
        guard fittable.count >= ShadowPolicy.alphaMinCell else { return nil }
        let horizonMinutes = ShadowPolicy.riseHorizon / 60
        return ShadowPolicy.alphaGrid.min { lhs, rhs in
            error(fittable, lhs, horizonMinutes) < error(fittable, rhs, horizonMinutes)
        }
    }

    private static func error(_ rows: [(Double, Double, Double)], _ alpha: Double,
                              _ horizonMinutes: Double) -> Double {
        rows.reduce(0) { total, row in
            total + abs((alpha * row.0 + (1 - alpha) * row.1) * horizonMinutes - row.2)
        } / Double(rows.count)
    }
}
