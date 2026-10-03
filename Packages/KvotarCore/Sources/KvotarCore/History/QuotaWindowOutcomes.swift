import Foundation

// The provider-observed quota-window history behind Explore quota (REV-93 §4 / D-115, STEP_181).
//
// `quota_series` records one row per poll that carried a live window: a utilization, the reset the
// provider attributed it to, and — since `v23` — that window's width. Thirty days of those rows is
// several thousand readings of a few dozen windows. This file is the pure fold from the readings
// to the windows, and every rule in it exists to stop the fold from claiming more than the rows
// support.
//
// Pure by construction, like `WorkPerPercentSeries` and `PlanChangeStability`: no store, no clock
// of its own, no copy. `HistoryDisplay` owns the strings; this owns the facts.

/// One provider-observed quota window, folded from every poll that named it.
///
/// The identity is the window's reset anchor, not a time range: that is the key the provider
/// itself attributes each reading to, and it stays correct across a rollover edge where a
/// `polled_at` range does not (REV-53/STEP_76).
public struct QuotaWindowOutcome: Sendable, Equatable, Identifiable {

    /// Why `windowSeconds` is safe to use. Legacy reconstruction is explicit so downstream copy
    /// can distinguish a value stored on the poll from one recovered from durable provider facts.
    public enum WidthEvidence: String, Sendable, Equatable {
        /// This window's own `quota_series` row carried the provider-reported width.
        case recorded
        /// Claude's primary quota field is always the provider's five-hour window.
        case providerContract
        /// A recorded Codex `window_width_changed` boundary identifies this width era.
        case recordedChange
        /// No surviving fact identifies the width. The start and chart continuity stay unknown.
        case unknown
    }

    /// How much of the window Kvotar actually watched. The distinction is the whole point of the
    /// type: a window seen to its end has an *outcome*, one abandoned halfway has only a *floor*.
    public enum Completion: String, Sendable, Equatable {
        /// The reset has not passed. Excluded from every completed-window count, median and
        /// comparison — REV-93 §2.3's dashed `So far` point.
        case current
        /// The reset has passed and the ending is known: either the last observation lands inside
        /// `fullObservationTolerance` of it, or the window was seen at 100% (see below).
        case completedFull
        /// The reset has passed and the last observation predates it by more than the tolerance.
        /// `highWaterPct` is a **lower bound**, never an ending value.
        case completedPartial
    }

    /// What ended the window, where the app recorded it. Anything other than `reachedReset` breaks
    /// a chart segment: a replaced window is not the continuation of the one it replaced
    /// (REV-64 — a live Codex anchor can be *withdrawn*, not only advanced or expired).
    public enum Ending: String, Sendable, Equatable {
        case reachedReset
        case earlyReset
        case withdrawn
    }

    public let id: String
    public let tool: Tool
    /// The provider's own reset time for this window — the canonical anchor of its jitter group.
    public let resetsAt: Date
    /// The provider-reported width in seconds, or nil where no surviving evidence identifies it.
    /// New rows carry it directly. Legacy Claude rows use the provider's fixed primary-field
    /// contract; legacy Codex rows can use a recorded width-change boundary. Never inferred from
    /// a plan name, neighbouring window or the current snapshot.
    public let windowSeconds: Int?
    public let widthEvidence: WidthEvidence
    /// `resetsAt − windowSeconds`, and nil when the width is unknown.
    public let start: Date?
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let observationCount: Int
    /// The highest utilization observed. An ending value when `completion == .completedFull`,
    /// a lower bound when `.completedPartial`, and the current reading when `.current`.
    public let highWaterPct: Double
    /// The first poll that saw this window at or above 100%, where one did.
    public let hitLimitAt: Date?
    public let completion: Completion
    public let ending: Ending
    /// When the window actually ended: the recorded break for an early or withdrawn ending, the
    /// scheduled `resetsAt` otherwise (STEP_228). Completion and the last-reading gap are measured
    /// against it — a weekly the provider took back on Sep 12 ended on Sep 12, not on the Sep 17
    /// it was scheduled for.
    public let endedAt: Date

    public init(id: String, tool: Tool, resetsAt: Date, windowSeconds: Int?,
                widthEvidence: WidthEvidence, start: Date?,
                firstObservedAt: Date, lastObservedAt: Date, observationCount: Int,
                highWaterPct: Double, hitLimitAt: Date?, completion: Completion, ending: Ending,
                endedAt: Date? = nil) {
        self.id = id
        self.tool = tool
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
        self.widthEvidence = widthEvidence
        self.start = start
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.observationCount = observationCount
        self.highWaterPct = highWaterPct
        self.hitLimitAt = hitLimitAt
        self.completion = completion
        self.ending = ending
        self.endedAt = endedAt ?? resetsAt
    }

    /// How long before the window ended the last reading was taken (STEP_227; measured to
    /// `endedAt` since STEP_228). The recap marks a weekly line whose gap is large, because the
    /// final use may be higher than what was seen.
    public var lastReadingGap: TimeInterval { endedAt.timeIntervalSince(lastObservedAt) }
}

public enum QuotaWindowOutcomes {

    /// How close the last observation must sit to the reset before the window's ending is
    /// considered seen. **Two base poll ticks**, and deliberately the same constant the freshness
    /// stamp turns amber on (D-112): one number for "we should have heard by now", so the chart's
    /// idea of a watched window and the popover's idea of stale data cannot drift apart.
    ///
    /// Chosen from cadence plus the live corpus rather than picked (STEP_181): on thirty days of
    /// the dogfood database this splits 88 Claude windows into roughly 48 seen-to-the-end and 40
    /// partial, and 32 Codex windows into roughly 13 and 19. About half of all windows are
    /// genuinely unwatched at their close, and saying so is the point.
    public static let fullObservationTolerance: TimeInterval = PollBackoffPolicy.freshnessAmberAge

    /// Two reset anchors this close together are the same window. The endpoint wobbles its
    /// `resets_at` by a second or so — on the dogfood corpus 64 of 144 Claude anchors and 155 of
    /// 210 Codex anchors have a neighbour inside two minutes, and the twins *interleave* in time
    /// (one 48% window arrived under both `21:59:59` and `22:00:00`). Grouping is therefore by
    /// anchor value, never by runs of consecutive polls. Mirrors
    /// `OffMachineEstimator.resetJitterToleranceUnix` and `quotaSeries(resetsAtNear:)`.
    public static let anchorJitterTolerance: TimeInterval = 60

    /// Claude's fixed field widths — the `.providerContract` evidence for a row that stored none.
    /// The primary is `five_hour`; the secondary is `seven_day` (STEP_227).
    public static let primaryContractSeconds = 18_000
    public static let weeklyContractSeconds = 604_800

    /// The discontinuity types that end a window as something other than its own reset. Each one
    /// breaks a chart segment: the replacement window is a new series, not a continuation.
    public static let segmentBreakingEventTypes: [String] = [
        DiscontinuityObservation.EventType.earlyReset.rawValue,
        DiscontinuityObservation.EventType.windowDemolished.rawValue,
        DiscontinuityObservation.EventType.windowRemoved.rawValue,
    ]

    /// Durable facts used by the outcome fold. A width change is evidence for reconstruction but
    /// does not end a window by itself; the display model breaks a line when resolved widths differ.
    public static let evidenceEventTypes: [String] = segmentBreakingEventTypes + [
        DiscontinuityObservation.EventType.windowWidthChanged.rawValue,
    ]

    /// Folds one tool's series rows into the windows they describe, oldest first.
    ///
    /// - Parameters:
    ///   - points: `quota_series` rows for one tool over the period, any order.
    ///   - discontinuities: rows of `segmentBreakingEventTypes` over the same period.
    ///   - now: the report clock — what separates a current window from a completed one.
    ///
    /// **A window exists only where the provider reported one.** A quiet stretch produces no
    /// outcome at all, and the absence *is* the gap. Nothing here manufactures a 0% window for a
    /// period nobody polled, and nothing interpolates across one (REV-93 §2.3, §7).
    public static func compute(
        tool: Tool,
        points: [QuotaSeriesPoint],
        discontinuities: [SQLiteStore.DiscontinuityRow] = [],
        now: Date,
        tolerance: TimeInterval = fullObservationTolerance,
        providerContractSeconds: Int = primaryContractSeconds
    ) -> [QuotaWindowOutcome] {
        guard !points.isEmpty else { return [] }

        let facts = discontinuities.sorted { $0.at < $1.at }
        let breaks = facts
            .filter { segmentBreakingEventTypes.contains($0.eventType) }

        let groups = groupedByAnchor(points)
        let owned = breaksByGroup(groups, breaks: breaks)
        return groups.indices.compactMap { index in
            outcome(tool: tool, group: groups[index], facts: facts, ownBreaks: owned[index],
                    now: now, tolerance: tolerance,
                    providerContractSeconds: providerContractSeconds)
        }
        .sorted { $0.resetsAt < $1.resetsAt }
    }

    // MARK: - Grouping

    /// Distinct anchors ascending, folded into windows. An anchor joins the open group when it is
    /// within `anchorJitterTolerance` of that group's newest member **and** within twice the
    /// tolerance of its opener — which is exactly the ±60 s span one `quotaSeries(resetsAtNear:)`
    /// call selects, so a window folded here and a window read there are the same window.
    ///
    /// The second clause is the guard: chaining on neighbours alone would let a long drift of
    /// one-second steps accumulate into a group of unbounded width, and eventually swallow the
    /// next real window. Observed jitter is a second or two, so the cap never fires in practice —
    /// it is there so it cannot.
    private static func groupedByAnchor(_ points: [QuotaSeriesPoint]) -> [[QuotaSeriesPoint]] {
        var byAnchor: [Date: [QuotaSeriesPoint]] = [:]
        for point in points { byAnchor[point.resetsAt, default: []].append(point) }

        var groups: [[QuotaSeriesPoint]] = []
        var opener: Date?
        var newest: Date?
        for anchor in byAnchor.keys.sorted() {
            if let open = opener, let last = newest,
               anchor.timeIntervalSince(last) <= anchorJitterTolerance,
               anchor.timeIntervalSince(open) <= anchorJitterTolerance * 2 {
                groups[groups.count - 1].append(contentsOf: byAnchor[anchor] ?? [])
            } else {
                opener = anchor
                groups.append(byAnchor[anchor] ?? [])
            }
            newest = anchor
        }
        return groups.map { $0.sorted { $0.polledAt < $1.polledAt } }
    }

    // MARK: - Classification

    private static func outcome(
        tool: Tool,
        group: [QuotaSeriesPoint],
        facts: [SQLiteStore.DiscontinuityRow],
        ownBreaks: [SQLiteStore.DiscontinuityRow],
        now: Date,
        tolerance: TimeInterval,
        providerContractSeconds: Int
    ) -> QuotaWindowOutcome? {
        guard let first = group.first, let last = group.last,
              let highWater = group.map(\.usedPct).max() else { return nil }

        // The latest reset the provider named for this window — its own last word on when the
        // window ends, which is what a completed/current test has to be made against.
        let resetsAt = group.map(\.resetsAt).max() ?? last.resetsAt

        let width = resolvedWidth(tool: tool, group: group, facts: facts,
                                  providerContractSeconds: providerContractSeconds)
        let windowSeconds = width.seconds

        // An early ending counts only strictly before the scheduled reset: the detector logs a
        // natural reset as a withdrawal when its poll lands inside the jitter allowance after
        // the anchor (Codex, Sep 19 15:26 — 35 s past a reset it had simply reached). And only
        // after the window's last reading: a window the provider dropped and then restored
        // under the same anchor was not ended by the drop (Codex, Sep 9 18:57 — back two
        // minutes later, and read for two more hours).
        let early = ownBreaks.last {
            $0.at < resetsAt.addingTimeInterval(-anchorJitterTolerance)
                && $0.at >= last.polledAt
        }
        let endedAt = early?.at ?? resetsAt

        let completion: QuotaWindowOutcome.Completion
        if now < endedAt {
            completion = .current
        } else if highWater >= 100 {
            // Utilization is monotone inside a window (§9.3), so a reading at the ceiling cannot
            // be a floor under something higher — the ending is known however early we stopped
            // watching. This is the one case where a sparse window still has an outcome.
            completion = .completedFull
        } else if endedAt.timeIntervalSince(last.polledAt) <= tolerance {
            completion = .completedFull
        } else {
            completion = .completedPartial
        }

        return QuotaWindowOutcome(
            id: "\(tool.rawValue)-\(Int(resetsAt.timeIntervalSince1970))",
            tool: tool,
            resetsAt: resetsAt,
            windowSeconds: windowSeconds,
            widthEvidence: width.evidence,
            start: windowSeconds.map { resetsAt.addingTimeInterval(-TimeInterval($0)) },
            firstObservedAt: first.polledAt,
            lastObservedAt: last.polledAt,
            observationCount: group.count,
            highWaterPct: highWater,
            hitLimitAt: group.first { $0.usedPct >= 100 }?.polledAt,
            completion: completion,
            ending: ending(early),
            endedAt: endedAt)
    }

    // MARK: - Legacy width evidence

    /// Recovers only what the surviving provider facts prove. It never uses plan names: one Codex
    /// plan can expose different primary widths over time, as the dogfood corpus demonstrates.
    private static func resolvedWidth(
        tool: Tool,
        group: [QuotaSeriesPoint],
        facts: [SQLiteStore.DiscontinuityRow],
        providerContractSeconds: Int
    ) -> (seconds: Int?, evidence: QuotaWindowOutcome.WidthEvidence) {
        if let recorded = group.reversed().compactMap(\.windowSeconds).first {
            return (recorded, .recorded)
        }
        guard tool == .codex else {
            // Claude's adapter normalizes the primary `five_hour` field to 18 000 seconds on
            // every snapshot, and its `seven_day` field is seven days by name while stating no
            // width (STEP_227 passes 604 800 for it). Provider structure, not a plan or
            // neighbour guess.
            return (providerContractSeconds, .providerContract)
        }
        guard let first = group.first?.polledAt, let last = group.last?.polledAt else {
            return (nil, .unknown)
        }

        let changes = facts.filter {
            $0.eventType == DiscontinuityObservation.EventType.windowWidthChanged.rawValue
        }
        // A group observed across the switch cannot safely take either side. In normal data the
        // provider also changes the reset anchor, producing two groups; this guard handles a
        // malformed or unusually ordered corpus without inventing a start.
        guard !changes.contains(where: { $0.at > first && $0.at < last }) else {
            return (nil, .unknown)
        }

        let left = changes.last(where: { $0.at <= first }).flatMap { positiveInt($0.newValue) }
        let right = changes.first(where: { $0.at >= last }).flatMap { positiveInt($0.oldValue) }
        switch (left, right) {
        case let (lhs?, rhs?) where lhs == rhs:
            return (lhs, .recordedChange)
        case (_?, _?):
            return (nil, .unknown)
        case let (value?, nil), let (nil, value?):
            return (value, .recordedChange)
        case (nil, nil):
            return (nil, .unknown)
        }
    }

    private static func positiveInt(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// Which window each break ended (STEP_228). A break is recorded on the poll **after** the
    /// window's last reading — a withdrawal writes no series row at all, and an early reset's row
    /// already carries the replacement's anchor — so a time-span test can never find it inside
    /// the window it ended, and used to hand an early reset to its replacement instead.
    ///
    /// `early_reset` and `window_demolished` name the ended window's scheduled reset in
    /// `old_value`, so they are matched by anchor. `window_removed` stores a width there; it goes
    /// to the window whose last reading is the newest one strictly before the break.
    private static func breaksByGroup(
        _ groups: [[QuotaSeriesPoint]], breaks: [SQLiteStore.DiscontinuityRow]
    ) -> [[SQLiteStore.DiscontinuityRow]] {
        var owned = Array(repeating: [SQLiteStore.DiscontinuityRow](), count: groups.count)
        let anchors = groups.map { $0.map(\.resetsAt).max() }
        for row in breaks {
            let owner: Int?
            if row.eventType == DiscontinuityObservation.EventType.windowRemoved.rawValue {
                owner = groups.indices
                    .compactMap { index in lastReading(groups[index], before: row.at).map { (index, $0) } }
                    .max { $0.1 < $1.1 }?.0
            } else if let raw = row.oldValue, let unix = Double(raw) {
                let anchor = Date(timeIntervalSince1970: unix)
                owner = groups.indices.first { index in
                    anchors[index].map { abs($0.timeIntervalSince(anchor)) <= anchorJitterTolerance } ?? false
                }
            } else {
                owner = nil
            }
            if let owner { owned[owner].append(row) }
        }
        return owned
    }

    private static func lastReading(_ group: [QuotaSeriesPoint], before instant: Date) -> Date? {
        group.last { $0.polledAt < instant }?.polledAt
    }

    /// What finished the window: the newest of its own early breaks — a window demolished after an
    /// early reset is described by what actually finished it — or its own reset.
    private static func ending(_ early: SQLiteStore.DiscontinuityRow?) -> QuotaWindowOutcome.Ending {
        switch early?.eventType {
        case DiscontinuityObservation.EventType.earlyReset.rawValue:
            return .earlyReset
        case DiscontinuityObservation.EventType.windowDemolished.rawValue,
             DiscontinuityObservation.EventType.windowRemoved.rawValue:
            return .withdrawn
        default:
            return .reachedReset
        }
    }
}
