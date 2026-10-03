import Foundation
import KvotarCore

/// The `LOCAL ACTIVITY · TODAY` section and its `ESTIMATED VALUE` companion as typed render
/// data (STEP_177 — REV-92 / D-114, UI Spec §REV92 "Local activity" + "Estimated value").
/// Built once per render by `DisplayFormatter.localActivitySection` from the `DailyLocalReport`
/// the view model retains; views draw it verbatim and aggregate nothing. Additive beside the
/// legacy `LocalSessionSplit` until STEP_178 switches the visible composition.
public struct LocalActivitySection: Sendable, Equatable {
    public static let title = "LOCAL ACTIVITY · TODAY"
    public static let projectsHeading = "TOP PROJECTS · BY OBSERVED TOKENS"
    public static let valueTitle = "LOCAL ACTIVITY · ESTIMATED VALUE"
    public static let recentRateLabel = "Recent local rate"
    public static let cacheHitLabel = "Cache hit"
    public static let loadingCopy = "Loading local activity…"
    public static let emptyCopy = "No local activity observed today"
    public static let unavailableCopy = "Local activity unavailable"
    public static let valueNote = "Based on published API rates in USD. Not your spend or bill."
    public static let organizationValueNote =
        "Based on published API rates in USD. Not your organization’s spend or bill."
    public static let noProjectName = "(no project)"
    public static let unknownModelName = "Unknown model"
    /// An unmapped Codex originator's row (STEP_197) — the `Unknown model` convention: the
    /// tokens are real and stay visible under an honest name, never dropped to make the rows
    /// look tidy, which would leave them summing to less than the line above.
    public static let unknownSurfaceName = "Unknown app"
    /// The constant `site` the surface rows report to the diagnostics walk — a fixed string for
    /// the same reason `recencySite` is one.
    public static let surfacesSite = "local surfaces"
    /// The constant `site` the recency marker reports to the diagnostics walk. It must never be
    /// the project's name: a tagged element records its site and label into the bundle, and
    /// project paths are on the §17 never-store list (STEP_178).
    public static let recencySite = "project recency"
    /// The marker glyph itself — a neutral clock, never a status colour (REV-92 §2 decision 6).
    public static let recencyMarker = "◷"
    public static let recencyAccessibilityLabel = "Most recently observed activity"

    /// What the section can honestly show. Fresh-empty, loading and unavailable are three
    /// different states (REV-92 §3), and a failed refresh over known data keeps the numbers
    /// with a dated qualifier rather than replacing them with a zero or yesterday.
    public enum Availability: Sendable, Equatable {
        case loading
        /// A successful read that observed nothing today.
        case empty
        case available
        /// The read failed and nothing earlier is retained.
        case unavailable
        /// The read failed; the numbers shown are the last successful read's, dated `asOf`.
        case staleRetained(asOf: Date)
    }

    public struct ModelRow: Sendable, Equatable {
        public let name: String
        public let tokens: String
        public init(name: String, tokens: String) {
            self.name = name
            self.tokens = tokens
        }
    }

    /// One local app's row under the summary (STEP_197). Helper-thread tokens are already inside
    /// the app's figure; there is no subagent row.
    public struct SurfaceRow: Sendable, Equatable {
        /// `Desktop` / `CLI` / `IDE extension`, or `Unknown app`.
        public let name: String
        public let tokens: String
        /// The neutral clock marker: this app has the newest observed event today. *Most recently
        /// observed*, never "running now" — the Multi-surface card owns that (STEP_192).
        public let isMostRecent: Bool

        public init(name: String, tokens: String, isMostRecent: Bool) {
            self.name = name
            self.tokens = tokens
            self.isMostRecent = isMostRecent
        }
    }

    public struct ProjectRow: Sendable, Equatable {
        /// The trailing folder, or `(no project)`.
        public let name: String
        /// The canonical stored path for accessibility / explanation text; `nil` for `(no project)`.
        public let fullName: String?
        public let tokens: String
        /// The neutral clock marker: this project has the newest observed event today. Means
        /// *most recently observed usage*, never foreground focus or a running process.
        public let isMostRecent: Bool
        public let models: [ModelRow]

        public init(name: String, fullName: String?, tokens: String, isMostRecent: Bool,
                    models: [ModelRow]) {
            self.name = name
            self.fullName = fullName
            self.tokens = tokens
            self.isMostRecent = isMostRecent
            self.models = models
        }
    }

    public let availability: Availability
    /// The line shown in place of the summary when there is nothing to summarise (loading /
    /// empty / unavailable copy), or the dated qualifier above retained numbers; `nil` when live.
    public let statusCopy: String?
    /// One aligned collector/population row: `Claude Code` → `1.2M tokens · 3 sessions`.
    public let summary: LabeledRow?
    /// `~2.3k tokens/min`, or `—` when no rate is current (older than the 2-minute horizon).
    public let recentRate: String
    /// `71%`, or `—` on a zero denominator.
    public let cacheHit: String
    /// The day's local apps, tokens descending (STEP_197). **Empty unless there are two or more**
    /// and the tool is Codex: a lone `Desktop 14.4M` under `Codex 14.4M` repeats the line above,
    /// and Claude observes one surface by construction (REV-81). The formatter decides; the view
    /// renders whatever arrives.
    public let surfaces: [SurfaceRow]
    public let projects: [ProjectRow]
    /// Grouped rows not shown — `N more projects ›` renders only when this is positive.
    public let moreCount: Int
    /// `Today` / `7-day` / `30-day` in USD; `—` where unknown.
    public let valueRows: [LabeledRow]
    public let valueNote: String
    /// `2 more projects ›` — nil when nothing is hidden. Composed by the formatter so the view
    /// never pluralises.
    public let overflowLabel: String?
    /// The local collector's freshness tag (`Claude Code JSONL · 35s ago`). Carried here since
    /// STEP_178 — the two-part local card that used to own it is gone.
    public let sourceTag: SourceTag?
    /// The newest observed event today — evidence recency, not collector health.
    public let lastEventAt: Date?
    /// When the shown report was read.
    public let readAt: Date?

    public init(availability: Availability, statusCopy: String?, summary: LabeledRow?,
                recentRate: String, cacheHit: String, surfaces: [SurfaceRow] = [],
                projects: [ProjectRow], moreCount: Int, valueRows: [LabeledRow],
                valueNote: String, overflowLabel: String? = nil, sourceTag: SourceTag? = nil,
                lastEventAt: Date?, readAt: Date?) {
        self.availability = availability
        self.statusCopy = statusCopy
        self.summary = summary
        self.recentRate = recentRate
        self.cacheHit = cacheHit
        self.surfaces = surfaces
        self.projects = projects
        self.moreCount = moreCount
        self.valueRows = valueRows
        self.valueNote = valueNote
        self.overflowLabel = overflowLabel
        self.sourceTag = sourceTag
        self.lastEventAt = lastEventAt
        self.readAt = readAt
    }
}
