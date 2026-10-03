import Foundation

/// One tool's observed local work on this Mac for the current local calendar day, midnight to the
/// read instant (STEP_177 — REV-92 / Baseline §15.2 "Daily local report"). Every figure comes
/// from **one** bounded read of `local_usage_events ⋈ local_sessions`, so the totals reconcile
/// by construction: `totalTokens` is the sum of every project row (hidden and `(no project)`
/// included), each project's tokens are the sum of its model rows (`Unknown model` included),
/// and `value` is the sum of the model rows' values priced through the one `EstimatedValueEngine`.
///
/// The report describes *selected-tool activity on this Mac*, never "the current email's usage":
/// stored local events carry a tool identity, not an account identity (REV-92 §3).
public struct DailyLocalReport: Sendable, Equatable {
    public let tool: Tool
    /// Local midnight — the population's lower bound.
    public let dayStart: Date
    /// The read instant — the population's upper bound (half-open), and the collection stamp
    /// the display ages against. A future-dated event never lands inside it.
    public let readUntil: Date
    /// Displayed tokens (`DisplayedTokens`, per-tool rule) over the whole population.
    public let totalTokens: Int
    /// Distinct sessions (Claude) / threads (Codex) with a token-bearing event inside the day.
    /// Not "sessions last seen today", and not a count of open windows.
    public let sessionCount: Int
    /// `CacheHit.ratio` over the summed components; `nil` on a zero denominator, never 0.
    public let cacheHitRatio: Double?
    /// Every grouped project row, tokens descending then stable canonical identity (nil last).
    public let projects: [Project]
    /// The newest event inside the population — evidence recency, **not** collector health.
    public let lastEventAt: Date?
    /// Today's est. token value in USD over the same population.
    public let value: Double
    /// The day's work split by the local app that did it (STEP_197), tokens descending. Sums to
    /// `totalTokens` like `projects` does — the same events, cut a second way. Helper threads are
    /// **inside** their app's figure, never a row of their own: a `Subagent · …` thread runs in
    /// the surface that spawned it (D-96), and its session records that surface's originator.
    /// Empty for a tool whose collector observes one surface by construction (Claude, REV-81)
    /// only in the sense that the list then holds a single entry — the display, not this model,
    /// decides that one entry is not worth a row.
    public let surfaces: [Surface]

    public init(tool: Tool, dayStart: Date, readUntil: Date, totalTokens: Int, sessionCount: Int,
                cacheHitRatio: Double?, projects: [Project], lastEventAt: Date?, value: Double,
                surfaces: [Surface] = []) {
        self.tool = tool
        self.dayStart = dayStart
        self.readUntil = readUntil
        self.totalTokens = totalTokens
        self.sessionCount = sessionCount
        self.cacheHitRatio = cacheHitRatio
        self.projects = projects
        self.lastEventAt = lastEventAt
        self.value = value
        self.surfaces = surfaces
    }

    /// One local app's share of the day (STEP_197). `bucket` is a real surface name — never a
    /// `Subagent · …` label, which the fold has already resolved into its parent app.
    public struct Surface: Sendable, Equatable {
        public let bucket: String
        public let tokens: Int
        /// The newest event attributed to this app today, helpers included — the recency marker's
        /// evidence. *Most recently observed*, never "running now" (that is the Multi-surface
        /// card's 8-minute rule, STEP_192).
        public let latestEventAt: Date

        public init(bucket: String, tokens: Int, latestEventAt: Date) {
            self.bucket = bucket
            self.tokens = tokens
            self.latestEventAt = latestEventAt
        }
    }

    /// A successful read that found nothing — distinct from an unavailable read, which is a
    /// different `DailyLocalReportState` case and never an empty report.
    public var isEmpty: Bool { totalTokens == 0 && sessionCount == 0 && projects.isEmpty }

    /// One grouped project (`ProjectGrouping.canonical` over the provider's stored paths).
    public struct Project: Sendable, Equatable {
        /// The canonical stored path; `nil` is the one explicit `(no project)` group.
        public let name: String?
        public let tokens: Int
        /// Per-event model rows, tokens descending then model name; sums to `tokens`.
        public let models: [ModelTotal]
        /// The newest event of this project inside the day — the recency marker's evidence.
        public let latestEventAt: Date
        public let value: Double

        public init(name: String?, tokens: Int, models: [ModelTotal], latestEventAt: Date,
                    value: Double) {
            self.name = name
            self.tokens = tokens
            self.models = models
            self.latestEventAt = latestEventAt
            self.value = value
        }
    }

    /// One model's share of a project's day. `model == nil` is `Unknown model`; its tokens are
    /// kept, never dropped, so the project still sums.
    public struct ModelTotal: Sendable, Equatable {
        public let model: String?
        public let tokens: Int
        public let value: Double

        public init(model: String?, tokens: Int, value: Double) {
            self.model = model
            self.tokens = tokens
            self.value = value
        }
    }

    /// The rows the popover shows (UI Spec §REV92 "Local activity"): the top `limit` projects by
    /// tokens, plus the most recently observed project when it is not already among them.
    public struct Selection: Sendable, Equatable {
        public let rows: [Project]
        /// Index into `rows` of the project with the newest observed event; `nil` when empty.
        public let mostRecentIndex: Int?
        /// Grouped rows excluded by the selection — the `N more projects ›` count.
        public let moreCount: Int

        public init(rows: [Project], mostRecentIndex: Int?, moreCount: Int) {
            self.rows = rows
            self.mostRecentIndex = mostRecentIndex
            self.moreCount = moreCount
        }
    }

    /// Selects at most `limit + 1` rows: the first `limit` of `projects` (already ranked), then
    /// the project with the newest event if distinct. Equal recency is broken by rank order, so
    /// two projects sharing a last event pick deterministically. `moreCount` counts every grouped
    /// row left out — `(no project)` included, since it is a row like any other.
    public func selection(limit: Int = 2) -> Selection {
        var rows = Array(projects.prefix(max(0, limit)))
        var mostRecentIndex: Int?
        if let newest = projects.indices.max(by: { a, b in
            let (pa, pb) = (projects[a], projects[b])
            if pa.latestEventAt != pb.latestEventAt { return pa.latestEventAt < pb.latestEventAt }
            return a > b   // earlier rank wins a tie, so the max is the lower index
        }) {
            let project = projects[newest]
            if let index = rows.firstIndex(of: project) {
                mostRecentIndex = index
            } else {
                rows.append(project)
                mostRecentIndex = rows.count - 1
            }
        }
        return Selection(rows: rows, mostRecentIndex: mostRecentIndex,
                         moreCount: projects.count - rows.count)
    }
}

/// Availability of the daily report on a render path (Baseline §15.2 "Availability and
/// updates"). A failed read is never an empty report: `.unavailable` keeps the last successful
/// report so the display can show it with an honest stale qualifier instead of a fabricated zero.
public enum DailyLocalReportState: Sendable, Equatable {
    /// No read has completed yet this launch.
    case loading
    case available(DailyLocalReport)
    /// The latest read failed. `retained` is the last successful report, if any.
    case unavailable(retained: DailyLocalReport?, failedAt: Date)

    /// The report a display may draw numbers from — current or retained.
    public var report: DailyLocalReport? {
        switch self {
        case .loading: return nil
        case .available(let report): return report
        case .unavailable(let retained, _): return retained
        }
    }
}
