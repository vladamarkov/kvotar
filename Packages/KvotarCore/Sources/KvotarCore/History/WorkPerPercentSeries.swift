import Foundation

/// The "Work per 1 % of window" series — REV-69 §4 M3 (+ M2, M3ʹ) as **evidence**, not a verdict
/// (D-76 — STEP_114). For each quota window (slot) and each cycle of it: how many list-price
/// dollars of *local* work it took to move the window by one percent, the same per model, the raw
/// token equivalent, the share of the rise nothing local can explain, and the cross-window ratio.
/// A silent bucket shrink would show up here as a step down in dollars-per-1 % that moves every
/// model together; the notice that reads it is a later, gated step. **No threshold, no verdict.**
///
/// **Inputs are read-only history**: `history_rollups` (poll side, permanent hourly aggregate) and
/// the priced hourly `local_usage_events` (local side, permanent corpus), joined by UTC hour — both
/// floor to the hour by the same integer arithmetic. Neither is modified.
///
/// **Samples are intervals between consecutive rollup rows of one cycle**, not hours: the rollups
/// have gaps (the app was not running; the newest ≤ 2 h still sit in `poll_snapshots`) while the
/// local corpus is complete, so a per-hour join would drop the rise across a gap onto one hour's
/// dollars. An interval `(a, b]` carries the rise `max(0, b.max − highWater)` (the §12.2 running
/// high-water rule) and the dollars of every hour bucket in `(a.hour, b.hour]`.
///
/// **A cycle's first observed row seeds the high-water and produces no interval.** That drops the
/// leading slice of the first cycle (the §12.2 leading-slice reasoning at hour grain) and the
/// boundary hour of every later cycle — a rollup hour containing a reset mixes two cycles in one
/// `max`/`last` pair and cannot be split at this grain, so its rise and dollars are excluded from
/// the rate rather than assigned to either side. Documented coarseness (task file); it removes one
/// interval per cycle and biases nothing.
///
/// **Per model** the dominant-interval rule (user decision 2026-08-17): an interval whose priced
/// work is ≥ `dominantShare` one model attributes its whole rise to that model. Mixed intervals
/// feed only the all-models rate; `coverage` says how much of the cycle's rise the per-model rates
/// stand on. Chosen over a least-squares fit because STEP_78 found passive-data weight fits
/// unstable on exactly this substrate (holdout R² −0.21).
///
/// **Unexplained share** is elimination at hour grain, mirroring §12.2: an interval with no local
/// dollars in `(a, b]` **and** none in the hour before it (JSONL lands after the API call) whose
/// window still rose is usage this machine cannot see — the web app, another machine.
public struct WorkPerPercentSeries: Sendable, Equatable {

    /// One model's rate inside a point — only models with rise attributed under the dominant rule.
    public struct ModelRate: Sendable, Equatable {
        public let model: String?
        public let deltaPct: Double
        public let dollars: Double
        public var dollarsPerPct: Double { dollars / deltaPct }

        public init(model: String?, deltaPct: Double, dollars: Double) {
            self.model = model
            self.deltaPct = deltaPct
            self.dollars = dollars
        }
    }

    /// One point of the series — a cycle, or a local calendar day of short (5-hour) cycles.
    public struct Point: Sendable, Equatable {
        public let start: Date
        public let end: Date
        /// False for the cycle still running (or the day still in progress) — rendered "so far".
        public let isComplete: Bool
        public let deltaPct: Double
        public let dollars: Double
        public let tokens: Int
        public let perModel: [ModelRate]
        /// ΣΔ% of dominant-model intervals ÷ ΣΔ%; nil when Δ% is 0.
        public let coverage: Double?
        /// ΣΔ% of intervals with no local work ÷ ΣΔ%; nil when Δ% is 0.
        public let unexplainedShare: Double?
        /// Δweekly% ÷ Δ5-hour% over the point's span (M2), when both windows moved.
        public let crossWindowRatio: Double?

        public var dollarsPerPct: Double? { deltaPct > 0 ? dollars / deltaPct : nil }
        public var tokensPerPct: Double? { deltaPct > 0 ? Double(tokens) / deltaPct : nil }

        public init(start: Date, end: Date, isComplete: Bool, deltaPct: Double, dollars: Double,
                    tokens: Int, perModel: [ModelRate], coverage: Double?,
                    unexplainedShare: Double?, crossWindowRatio: Double?) {
            self.start = start
            self.end = end
            self.isComplete = isComplete
            self.deltaPct = deltaPct
            self.dollars = dollars
            self.tokens = tokens
            self.perModel = perModel
            self.coverage = coverage
            self.unexplainedShare = unexplainedShare
            self.crossWindowRatio = crossWindowRatio
        }
    }

    /// One window slot's series. `windowSeconds` is what the History window names the slot by
    /// (`DisplayFormatter.windowGrain`); nil when it could not be derived (one Codex cycle).
    public struct Slot: Sendable, Equatable {
        public let isPrimary: Bool
        public let windowSeconds: Int?
        /// True when short cycles were re-aggregated per local calendar day.
        public let byDay: Bool
        public let points: [Point]

        public init(isPrimary: Bool, windowSeconds: Int?, byDay: Bool, points: [Point]) {
            self.isPrimary = isPrimary
            self.windowSeconds = windowSeconds
            self.byDay = byDay
            self.points = points
        }
    }

    /// A `discontinuity_events` row placed on the timeline (raw strings, §17.1).
    public struct Marker: Sendable, Equatable {
        public let at: Date
        public let eventType: String
        public let windowType: String?
        public let oldValue: String?
        public let newValue: String?

        public init(at: Date, eventType: String, windowType: String?, oldValue: String?,
                    newValue: String?) {
            self.at = at
            self.eventType = eventType
            self.windowType = windowType
            self.oldValue = oldValue
            self.newValue = newValue
        }
    }

    public let slots: [Slot]
    public let markers: [Marker]

    public init(slots: [Slot], markers: [Marker]) {
        self.slots = slots
        self.markers = markers
    }

    public static let empty = WorkPerPercentSeries(slots: [], markers: [])
    public var isEmpty: Bool { slots.allSatisfy { $0.points.isEmpty } && markers.isEmpty }

    /// Share of an interval's dollars one model must hold for the interval to count as its own.
    static let dominantShare = 0.9
    /// Cycles narrower than this are re-aggregated per local calendar day (Claude's 5-hour).
    static let dayRollupBelowSeconds = 86_400
    /// Two anchors closer than this are the same cycle (Claude's `:59:59` / `:00:00` jitter).
    static let anchorTolerance = 60
    static let claudePrimaryWindowSeconds = 18_000
    static let hour = 3600

    /// One priced hour bucket for one model — the reader's join of `hourlyTokenTotalsByModel`
    /// with the pricing engine (`tokens` is the §4 displayed count via `DisplayedTokens.sum`).
    public struct HourlyWork: Sendable, Equatable {
        public let hourStart: Date
        public let model: String?
        public let dollars: Double
        public let tokens: Int

        public init(hourStart: Date, model: String?, dollars: Double, tokens: Int) {
            self.hourStart = hourStart
            self.model = model
            self.dollars = dollars
            self.tokens = tokens
        }
    }

    // MARK: - Computation

    /// Pure. `rollups` oldest first (as `historyRollups` returns them); `until` is the reader's
    /// clock (a cycle whose anchor is past it, or that a later cycle replaced, is complete);
    /// `primaryWindowSeconds` is the width the provider currently reports for the primary window
    /// (Codex; the rollups do not keep it — the reader passes the latest snapshot's, the same
    /// D-58 read every other surface names the window by; Claude's is the five-hour fallback);
    /// `calendar` decides the local day for the short-cycle rollup (`.current` in the app, UTC in
    /// tests).
    static func compute(tool: Tool, rollups: [HistoryRollup], hourly: [HourlyWork],
                        markers: [Marker], until: Date, primaryWindowSeconds: Int? = nil,
                        calendar: Calendar = .current) -> WorkPerPercentSeries {
        // Hour bucket → per-model dollars/tokens.
        var buckets: [Int: [(model: String?, dollars: Double, tokens: Int)]] = [:]
        for h in hourly {
            buckets[Int(h.hourStart.timeIntervalSince1970), default: []]
                .append((h.model, h.dollars, h.tokens))
        }
        let primaryIntervals = intervals(rollups: rollups, primary: true, buckets: buckets)
        let secondaryIntervals = intervals(rollups: rollups, primary: false, buckets: buckets)

        var slots: [Slot] = []
        for (isPrimary, own, other) in [(true, primaryIntervals, secondaryIntervals),
                                        (false, secondaryIntervals, primaryIntervals)] {
            guard !own.isEmpty else { continue }
            let width = isPrimary
                ? (tool == .claude ? claudePrimaryWindowSeconds : primaryWindowSeconds)
                : DiscontinuityDetector.secondaryWindowSeconds
            let byDay = width.map { $0 < dayRollupBelowSeconds } ?? false
            let groups: [[Interval]] = byDay
                ? Dictionary(grouping: own) {
                    calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.end)))
                  }.sorted { $0.key < $1.key }.map(\.value)
                : Dictionary(grouping: own, by: \.cycleAnchor)
                    .sorted { $0.value[0].start < $1.value[0].start }.map(\.value)
            let points = groups.enumerated().map { index, group -> Point in
                let start: Date, end: Date, complete: Bool
                if byDay {
                    start = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(group[0].end)))
                    end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                    complete = end <= until
                } else {
                    start = Date(timeIntervalSince1970: TimeInterval(group[0].start))
                    let anchor = Date(timeIntervalSince1970: TimeInterval(group[0].cycleAnchor))
                    let lastEnd = Date(timeIntervalSince1970: TimeInterval(group.last!.end + hour))
                    // Complete when its anchor has passed — or when a later cycle replaced it (a
                    // withdrawn or plan-changed window never reaches its anchor).
                    let ranThrough = anchor.addingTimeInterval(TimeInterval(anchorTolerance)) < until
                    complete = ranThrough || index < groups.count - 1
                    // A cycle that ran to its anchor ends there; one cut short (withdrawn,
                    // plan-changed, or still running) ends where observation did.
                    end = ranThrough ? anchor : lastEnd
                }
                return point(start: start, end: end, complete: complete, intervals: group,
                             other: other, isPrimary: isPrimary, buckets: buckets)
            }
            slots.append(Slot(isPrimary: isPrimary, windowSeconds: width, byDay: byDay,
                              points: points))
        }
        return WorkPerPercentSeries(slots: slots, markers: markers.sorted { $0.at < $1.at })
    }

    // MARK: - Internals

    /// One sample: the rise between two consecutive rollup rows of one cycle and the local work
    /// in `(start, end]` (hour starts). `dollars` is per model.
    struct Interval: Equatable {
        let cycleAnchor: Int
        let start: Int
        let end: Int
        let rise: Double
        let dollars: [String?: Double]
        let tokens: Int
        /// Local dollars in the hour bucket at `start` — the "hour before" of the unexplained rule.
        let dollarsBefore: Double
        var totalDollars: Double { dollars.values.reduce(0, +) }
    }

    private static func intervals(rollups: [HistoryRollup], primary: Bool,
                                  buckets: [Int: [(model: String?, dollars: Double, tokens: Int)]])
        -> [Interval] {
        var out: [Interval] = []
        var cycleAnchor: Int?
        var highWater = 0.0
        var previousHour: Int?
        for r in rollups {
            let (maxP, lastP, anchor) = primary
                ? (r.primaryUsedPctMax, r.primaryUsedPctLast, r.primaryResetsAtLast)
                : (r.secondaryUsedPctMax, r.secondaryUsedPctLast, r.secondaryResetsAtLast)
            // A row where the slot is null is not an observation of it (idle / no window).
            guard let maxP, let lastP, let anchor else { continue }
            let sameCycle = cycleAnchor.map { abs($0 - anchor) <= anchorTolerance } ?? false
            if !sameCycle {
                // First row of a cycle: seed, no interval. `last` (not `max`) — a reset inside
                // this hour leaves `max` on the old cycle and `last` on the new one. The anchor
                // key stays the first one seen so a jittering `:59:59`/`:00:00` pair is one cycle.
                cycleAnchor = anchor
                highWater = lastP
                previousHour = r.hourStart
                continue
            }
            let rise = max(0, maxP - highWater)
            highWater = max(highWater, maxP)
            var dollars: [String?: Double] = [:]
            var tokens = 0
            var h = previousHour! + hour
            while h <= r.hourStart {
                for b in buckets[h] ?? [] {
                    dollars[b.model, default: 0] += b.dollars
                    tokens += b.tokens
                }
                h += hour
            }
            let before = (buckets[previousHour!] ?? []).reduce(0) { $0 + $1.dollars }
            out.append(Interval(cycleAnchor: cycleAnchor!, start: previousHour!, end: r.hourStart,
                                rise: rise, dollars: dollars, tokens: tokens, dollarsBefore: before))
            previousHour = r.hourStart
        }
        return out
    }

    private static func point(start: Date, end: Date, complete: Bool, intervals: [Interval],
                              other: [Interval], isPrimary: Bool,
                              buckets: [Int: [(model: String?, dollars: Double, tokens: Int)]])
        -> Point {
        let delta = intervals.reduce(0) { $0 + $1.rise }
        let dollars = intervals.reduce(0) { $0 + $1.totalDollars }
        let tokens = intervals.reduce(0) { $0 + $1.tokens }

        // Dominant-interval per-model attribution.
        var perModel: [String?: (delta: Double, dollars: Double)] = [:]
        var covered = 0.0
        var unexplained = 0.0
        for i in intervals {
            let total = i.totalDollars
            if total == 0, i.dollarsBefore == 0 { unexplained += i.rise }
            guard total > 0, i.rise > 0,
                  let top = i.dollars.max(by: { $0.value < $1.value }),
                  top.value / total >= dominantShare else { continue }
            perModel[top.key, default: (0, 0)].delta += i.rise
            perModel[top.key, default: (0, 0)].dollars += top.value
            covered += i.rise
        }
        let rates = perModel.filter { $0.value.delta > 0 }
            .map { ModelRate(model: $0.key, deltaPct: $0.value.delta, dollars: $0.value.dollars) }
            .sorted { ($0.model ?? "") < ($1.model ?? "") }

        // Cross-window ratio over the same span: Δsecondary ÷ Δprimary.
        let lo = intervals.map(\.start).min() ?? 0
        let hi = intervals.map(\.end).max() ?? 0
        let otherDelta = other.filter { $0.start >= lo && $0.end <= hi }.reduce(0) { $0 + $1.rise }
        let ratio: Double?
        if isPrimary {
            ratio = delta > 0 && otherDelta > 0 ? otherDelta / delta : nil
        } else {
            ratio = delta > 0 && otherDelta > 0 ? delta / otherDelta : nil
        }

        return Point(start: start, end: end, isComplete: complete,
                     deltaPct: delta, dollars: dollars, tokens: tokens, perModel: rates,
                     coverage: delta > 0 ? covered / delta : nil,
                     unexplainedShare: delta > 0 ? unexplained / delta : nil,
                     crossWindowRatio: ratio)
    }
}
