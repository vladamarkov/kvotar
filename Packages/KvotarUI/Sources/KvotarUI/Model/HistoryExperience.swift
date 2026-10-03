import Foundation
import KvotarCore

/// The History window's typed render contract (STEP_159 — REV-84 / D-108; four modes since
/// STEP_182 — REV-93 / D-115): one window, a mode control (`Weekly recap | Explore quota |
/// Explore usage | Hard blocks`) and a provider filter (`All | Claude | Codex`) that is
/// **mode-local on the three evidence modes and absent from Weekly recap**, precomputed from one
/// `HistoryReport` load. SwiftUI renders this and computes nothing: every string, grouping,
/// total, conclusion, empty state, selected-day detail, chart fraction and scoped destination is
/// produced by `HistoryDisplay.experience`.
///
/// `HistoryScreen` next door carries the chart and row primitives (`DayStrip`, `HourChart`,
/// `RankedRow`, `Header`, `DayLegendEntry`): geometry and hover grammar shared by every mode.
///
/// **Provider safety (REV-84 §3.1, unchanged by REV-93).** `All` is not a synthetic third
/// provider. There is no combined token total *field* anywhere in this type — the absence is
/// structural, so a future caller cannot render one by mistake. Dollars may combine (once,
/// subordinate, always under `pricingNote`); tokens, sessions/threads and model rows never do.
/// On `All`, every local-activity chart fraction is normalised against **that provider's own**
/// busiest bucket, and Explore quota stacks one 0–100 % section per provider rather than sharing
/// an axis — two allowances are never drawn as comparable magnitudes.
public struct HistoryExperience: Sendable {

    /// The primary mode control, in display order (UI Spec §6.0). `Weekly recap` is the
    /// ordinary-open default — position 0 here, and the view model may rely on that.
    public enum Mode: Sendable, Hashable, CaseIterable {
        case weeklyRecap
        case exploreQuota
        case exploreUsage
        case hardBlocks

        /// Control label. The exact decided names: `Weekly recap` replaces `Summary` outright
        /// (there is no legacy Summary mode), `Explore usage` is never `Explore days`, and
        /// `Explore quota` is a top-level mode rather than a grain inside usage.
        public var label: String {
            switch self {
            case .weeklyRecap: return "Weekly recap"
            case .exploreQuota: return "Explore quota"
            case .exploreUsage: return "Explore usage"
            case .hardBlocks: return "Hard blocks"
            }
        }

        /// The stable titlebar's second line in the approved Variant A hierarchy. Copy lives
        /// on the typed presentation model, not in SwiftUI.
        public var windowSubtitle: String {
            switch self {
            case .weeklyRecap: return "Weekly recaps and the evidence behind them"
            case .exploreQuota: return "Explore provider-reported quota history"
            case .exploreUsage: return "Explore recorded local activity"
            case .hardBlocks: return "Investigate recorded interruptions"
            }
        }

        /// The evidence-page grounding sentence below the mode name. Weekly recap has its own
        /// editorial lead and therefore never renders this value.
        public var evidenceSubtitle: String? {
            switch self {
            case .weeklyRecap:
                return nil
            case .exploreQuota:
                return "How each provider-reported quota window ended. Current windows are shown separately as “So far.”"
            case .exploreUsage:
                return "Recorded local activity by day, week, project and model."
            case .hardBlocks:
                return "Recorded interruptions and the evidence around them."
            }
        }
    }

    /// One provider-filter position. Same identity space as `HistoryScreen.Tab.Kind`, kept as
    /// its own type so the legacy model can be deleted without touching this one.
    public enum Provider: Sendable, Hashable {
        case all
        case tool(Tool)

        public var label: String {
            switch self {
            case .all: return "All"
            case .tool(let tool): return tool.tabLabel
            }
        }
    }

    // MARK: - Shared panel shapes

    /// One evidence-backed line inside a panel: a wrapping sentence, plus a figure row where the
    /// evidence has one (the REV-72 quota-change figure). Carries facts the surrounding
    /// conclusion did not use — never a duplicate of it.
    public struct Highlight: Sendable {
        public let lede: String
        public let row: LabeledRow?

        public init(lede: String, row: LabeledRow? = nil) {
            self.lede = lede
            self.row = row
        }
    }

    /// One compact measure (STEP_160 — Hard blocks' known consequence): a label, the figure,
    /// and a muted caption saying what the figure is made of. Variant A draws it inline.
    public struct Stat: Sendable, Equatable {
        public let label: String
        public let figure: String
        public let caption: String?

        public init(label: String, figure: String, caption: String? = nil) {
            self.label = label
            self.figure = figure
            self.caption = caption
        }
    }

    /// The allowance panel (REV-84 §4.1 item 2 and §6 item 6): recorded plan/window changes and
    /// the provider-scoped REV-72 quota-change evidence, under one title — `Has your allowance
    /// changed?` on Summary, `Allowance history` on Hard blocks. Context, never causation: the
    /// evidence keeps REV-72's guards and no entry ever claims a change caused a block.
    public struct AllowancePanel: Sendable {
        public let title: String
        /// One verdict per watched provider (named on `All`), with the corrected-rate figure
        /// row only where REV-72's qualifying-cycle floor earned one.
        public let evidence: [Highlight]
        /// Recorded changes, newest first, D-81 row grammar, provider-tagged on `All`; capped
        /// with an honest overflow row rather than silent truncation.
        public let changes: [HistoryScreen.RankedRow]

        public init(title: String, evidence: [Highlight] = [],
                    changes: [HistoryScreen.RankedRow] = []) {
            self.title = title
            self.evidence = evidence
            self.changes = changes
        }
    }

    // MARK: - Weekly recap (REV-93 §2.2 / UI Spec §6.2)

    /// A typed link from a recap insight to the evidence that supports it. The label is the copy
    /// the reader clicks; the destination names the exact mode, provider and week (UI Spec
    /// §6.2 *Evidence links*). Nothing here is a URL and nothing is parsed on the other side.
    public struct RecapLink: Sendable, Equatable {
        public let label: String
        public let destination: HistoryDestination

        public init(label: String, destination: HistoryDestination) {
            self.label = label
            self.destination = destination
        }
    }

    /// The recap's one lead: an eyebrow, the conclusion sentence, and the sentence that grounds
    /// it in what was recorded. `kind` exists so a test can pin the §6.2 priority ladder without
    /// matching prose, and so the view can tint the lead — it is never rendered as a word.
    public struct RecapLead: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            /// Rung 1 — the week recorded a hard block.
            case blockConsequence
            /// Rung 2 — a plan change or a window added/removed/re-widened. A recurring early
            /// reset is deliberately **not** here (it would lead every recap on an account whose
            /// weekly window resets early every other day); it supports a recap as an insight.
            case allowanceChange
            /// Rung 3 — the week moved outside the ±5 % band against the preceding complete week.
            case usagePattern
            /// Rung 4 — the calm factual summary.
            case calm
        }

        public let eyebrow: String
        public let sentence: String
        public let grounding: String?
        public let kind: Kind

        public init(eyebrow: String, sentence: String, grounding: String? = nil, kind: Kind) {
            self.eyebrow = eyebrow
            self.sentence = sentence
            self.grounding = grounding
            self.kind = kind
        }
    }

    /// One cell of the `This week` table: the figure, and the comparison against the provider's
    /// own previous complete week where one is allowed (`↓86% vs 917.0M`).
    public struct RecapTableCell: Sendable, Equatable {
        public let text: String
        public let comparison: String?

        public init(text: String, comparison: String? = nil) {
            self.text = text
            self.comparison = comparison
        }
    }

    /// One row of the `This week` table — a label and one cell per column, index-aligned with
    /// `RecapTable.columns`.
    public struct RecapTableRow: Sendable, Equatable {
        public let label: String
        public let cells: [RecapTableCell]

        public init(label: String, cells: [RecapTableCell]) {
            self.label = label
            self.cells = cells
        }
    }

    /// The `This week` block (REV-104 §2.3): one column per provider with activity, three rows,
    /// never a token total across providers. The combined Est. token value is a line under it,
    /// subordinate and beside the not-a-bill note (UI Spec §6.1).
    public struct RecapTable: Sendable, Equatable {
        public let title: String
        public let columns: [Tool]
        public let rows: [RecapTableRow]
        /// `Together about $303 · Priced at published API rates for each model. Not a bill.` —
        /// the note alone with one column.
        public let valueNote: String
        /// `Claude includes models priced at a fallback rate.` where a value cell carries `≈`.
        public let fallbackNote: String?
        public let link: RecapLink

        public init(title: String, columns: [Tool], rows: [RecapTableRow], valueNote: String,
                    fallbackNote: String? = nil, link: RecapLink) {
            self.title = title
            self.columns = columns
            self.rows = rows
            self.valueNote = valueNote
            self.fallbackNote = fallbackNote
            self.link = link
        }
    }

    /// One weekly limit that reset inside the week: `Claude overall · Sep 25` and `43% used`.
    public struct RecapLimitLine: Sendable, Equatable {
        public let provider: Tool
        /// `Claude overall · Sep 25`, `Codex · Sep 12 (reset early)`.
        public let label: String
        /// `43% used`, `58% used*`, `reached the limit`.
        public let value: String

        public init(provider: Tool, label: String, value: String) {
            self.provider = provider
            self.label = label
            self.value = value
        }
    }

    /// The `Weekly limits that reset <span>` block (REV-104 §2.4). Absent — no empty heading —
    /// when no weekly limit ended inside the week.
    public struct RecapWeeklyLimits: Sendable, Equatable {
        public let title: String
        public let lines: [RecapLimitLine]
        /// One per asterisked line; empty when every reading was taken close to its reset.
        public let footnotes: [String]
        public let link: RecapLink

        public init(title: String, lines: [RecapLimitLine], footnotes: [String] = [],
                    link: RecapLink) {
            self.title = title
            self.lines = lines
            self.footnotes = footnotes
            self.link = link
        }
    }

    /// One observation: consequence first, evidence link last (UI Spec §6.2). `provider`
    /// names the account only where the fact belongs to one — the recap is cross-provider and
    /// does not tag what does not need tagging.
    public struct RecapInsight: Sendable, Equatable {
        public let provider: Tool?
        public let sentence: String
        /// States the coverage limit **next to the conclusion it bounds** (§6.2 *Evidence
        /// quality*). Present only where the week's evidence is genuinely clipped.
        public let coverageNote: String?
        public let link: RecapLink?

        public init(provider: Tool? = nil, sentence: String, coverageNote: String? = nil,
                    link: RecapLink? = nil) {
            self.provider = provider
            self.sentence = sentence
            self.coverageNote = coverageNote
            self.link = link
        }
    }

    /// The at-most-one `Next week` action. Present **only when the week recorded a hard block**
    /// (owner ruling 2026-09-10): a block is the one outcome that names a change worth making,
    /// and every softer trigger would be advice the evidence does not carry. Omitted entirely
    /// otherwise — a calm week ends without one.
    public struct RecapAction: Sendable, Equatable {
        public let title: String
        public let sentence: String
        /// What the sentence is drawn from, so the reader can check it.
        public let evidence: String?

        public init(title: String, sentence: String, evidence: String? = nil) {
            self.title = title
            self.sentence = sentence
            self.evidence = evidence
        }
    }

    /// One completed local **Monday–Sunday** week (UI Spec §6.2). The current partial week never
    /// produces one of these — that exclusion is structural, not a display filter.
    public struct RecapWeek: Sendable, Equatable, Identifiable {
        /// Local Monday 00:00 — the week's own start, and its stable identity.
        public let id: Date
        public let end: Date
        /// `Last completed week` on the newest, `Week of Sep 1` on an older one.
        public let title: String
        /// `Sep 1 – Sep 7`.
        public let span: String
        public let isLatest: Bool
        /// Names the horizon limit when the week is only partly inside the fixed 30 days, or
        /// when Kvotar was not watching for all of it. Every conclusion that needs whole-week
        /// totals is suppressed while this is set.
        public let coverageNote: String?
        public let lead: RecapLead
        /// `This week` — nil on a clipped week and on a week with no local activity.
        public let table: RecapTable?
        /// `Weekly limits that reset …` — nil when none ended inside the week.
        public let weeklyLimits: RecapWeeklyLimits?
        /// At most two (REV-104 §2.5); empty slots are omitted, never padded.
        public let observations: [RecapInsight]
        public let action: RecapAction?

        public init(id: Date, end: Date, title: String, span: String, isLatest: Bool,
                    coverageNote: String? = nil, lead: RecapLead,
                    table: RecapTable? = nil, weeklyLimits: RecapWeeklyLimits? = nil,
                    observations: [RecapInsight] = [], action: RecapAction? = nil) {
            self.id = id
            self.end = end
            self.title = title
            self.span = span
            self.isLatest = isLatest
            self.coverageNote = coverageNote
            self.lead = lead
            self.table = table
            self.weeklyLimits = weeklyLimits
            self.observations = Array(observations.prefix(RecapWeek.maxObservations))
            self.action = action
        }

        /// The REV-104 §2.5 budget, enforced by the type rather than by the builder alone.
        public static let maxObservations = 2

        /// Every evidence link on the page, top to bottom — one per block (§6.2).
        public var links: [RecapLink] {
            [table?.link, weeklyLimits?.link].compactMap { $0 } + observations.compactMap(\.link)
        }
    }

    /// Weekly recap answers: **what mattered in the last completed week, and is there one useful
    /// change to make next week?** Always cross-provider — there is no provider-filtered recap
    /// payload, and the absence is what stops a provider control appearing on this mode.
    public struct RecapSection: Sendable, Equatable {
        /// Completed weeks intersecting the fixed 30-day horizon, **newest first**. The first
        /// entry is the one an ordinary open lands on.
        public let weeks: [RecapWeek]
        /// Replaces the page when the horizon holds no completed week at all.
        public let emptyMessage: String?

        public init(weeks: [RecapWeek] = [], emptyMessage: String? = nil) {
            self.weeks = weeks
            self.emptyMessage = emptyMessage
        }
    }

    // MARK: - Explore quota (REV-93 §2.3 / UI Spec §6.3)

    /// One provider-observed quota window, drawn as one point. Everything here is already
    /// decided: the shape to draw, the copy to print, the spoken value, and the detail pinned
    /// when the reader selects it.
    ///
    /// **`fraction` is `% used`** — the narrow REV-77/D-97 retrospective exception (§6.1). Every
    /// live surface in the app stays `% left`, and no chart mixes the two.
    public struct QuotaPoint: Sendable, Equatable, Identifiable {
        /// How much of the window Kvotar watched — the shape's meaning, not a quality score.
        public enum Kind: String, Sendable, Equatable {
            /// Seen to its end: `Ended at N% used` is an outcome.
            case completedFull
            /// Abandoned before its reset: `N%` is a **lower bound**, drawn hollow.
            case completedPartial
            /// The window still open, drawn dashed as `So far`. Excluded from every completed
            /// count, median, comparison and conclusion (§6.3).
            case current
        }

        /// `QuotaWindowOutcome.id` — stable across reloads, so a pinned selection survives one.
        public let id: String
        public let provider: Tool
        /// The window's own reset instant — the same date `x` is derived from. Present so a
        /// scoped arrival can tell which points belong to the week a recap link named
        /// (STEP_183); the alternative was parsing `detail.title`, which is the string parsing
        /// this contract exists to prevent. Nothing displays it.
        public let at: Date
        public let kind: Kind
        /// The window was observed at or above 100 %. Drawn as its own mark, never colour alone.
        public let hitLimit: Bool
        /// Geometry: utilization ÷ 100, clamped 0…1. The view multiplies it by a height.
        public let fraction: Double
        /// Geometry: where the window's reset sits across the report period, clamped 0…1.
        public let x: Double
        /// `Ended at 87% used` / `Reached at least 62% used · Partial` / `So far 41% used`.
        public let label: String
        /// Provider, span, width, ending/lower-bound utilization, completion and block state as
        /// plain text (§6.0 accessibility) — no markdown, so VoiceOver never reads punctuation.
        public let accessibilityValue: String
        public let detail: QuotaDetail

        public init(id: String, provider: Tool, at: Date, kind: Kind, hitLimit: Bool,
                    fraction: Double, x: Double, label: String, accessibilityValue: String,
                    detail: QuotaDetail) {
            self.id = id
            self.provider = provider
            self.at = at
            self.kind = kind
            self.hitLimit = hitLimit
            self.fraction = min(max(fraction, 0), 1)
            self.x = min(max(x, 0), 1)
            self.label = label
            self.accessibilityValue = accessibilityValue
            self.detail = detail
        }
    }

    /// What is pinned below the charts when a point is selected (§6.3): the window's own facts,
    /// then the local work that happened alongside it — labelled context, never cause.
    public struct QuotaDetail: Sendable, Equatable {
        /// `Claude · Sep 3, 2 pm – 7 pm`, or the reset alone where the width was never recorded.
        public let title: String
        /// Width, used percentage or lower bound, coverage, reset behaviour, nearby local work.
        /// A fact with no defensible value is **omitted**, never printed as a dash.
        public let rows: [LabeledRow]
        /// The context disclaimer, present whenever a local-activity row is.
        public let note: String?
        /// The hard block recorded inside this window, where one was.
        public let blockLink: RecapLink?

        public init(title: String, rows: [LabeledRow] = [], note: String? = nil,
                    blockLink: RecapLink? = nil) {
            self.title = title
            self.rows = rows
            self.note = note
            self.blockLink = blockLink
        }
    }

    /// A run of points the chart may draw as one connected series. A gap in observation, a change
    /// of reported width, and any ending other than the window's own reset all **break** the
    /// segment — an unlike window is not the continuation of the one before it (§6.3, REV-64).
    public struct QuotaSegment: Sendable, Equatable, Identifiable {
        public let id: String
        /// `5-hour windows` / `Weekly windows`, or nil where no row in the run recorded a width.
        /// Named with the app's own grain vocabulary, so this chart, the popover and the block
        /// rows cannot call one width by two names.
        public let widthLabel: String?
        /// **Whether a line may be drawn through these points at all.** A window whose width was
        /// never recorded has no defensible start (STEP_181: a legacy row never borrows a
        /// neighbour's width), so nothing can establish that it abuts the window before it — and
        /// a line asserting exactly that is the interpolation §6.3 forbids. Such a run stays one
        /// labelled group of separate points, which is what the evidence supports.
        public let connects: Bool
        /// Why this run starts where it does — `Gap in observation`, `Window width changed`,
        /// `Reset early`, `Withdrawn by the provider`. Nil on the first run of a section.
        public let boundaryNote: String?
        /// One section-level evidence note, attached to its first segment: either why unresolved
        /// points are not joined or how legacy widths were recovered.
        public let widthNote: String?
        /// Point ids in time order. The points themselves live once, on the section.
        public let pointIDs: [String]

        public init(id: String, widthLabel: String?, connects: Bool, boundaryNote: String?,
                    widthNote: String? = nil, pointIDs: [String]) {
            self.id = id
            self.widthLabel = widthLabel
            self.connects = connects
            self.boundaryNote = boundaryNote
            self.widthNote = widthNote
            self.pointIDs = pointIDs
        }
    }

    /// One provider's full-width quota chart. On `All` these stack, Claude then Codex; they
    /// never sit side by side and never share an axis or a summary (§6.3).
    public struct QuotaSection: Sendable, Equatable, Identifiable {
        public let provider: Tool
        /// `Claude · 5-hour windows`, or `Claude · main account window` where widths vary or
        /// were never recorded.
        public let title: String
        /// The one factual sentence above the chart — counts only, no advice and no pattern
        /// language. Weekly recap owns interpretation.
        public let summary: String
        /// `Not enough completed windows to show a pattern yet.` below the sparse floor. The
        /// points are still drawn.
        public let sparseNote: String?
        public let segments: [QuotaSegment]
        /// Every point of this section in time order, oldest first.
        public let points: [QuotaPoint]

        public var id: Tool { provider }

        public init(provider: Tool, title: String, summary: String, sparseNote: String? = nil,
                    segments: [QuotaSegment] = [], points: [QuotaPoint] = []) {
            self.provider = provider
            self.title = title
            self.summary = summary
            self.sparseNote = sparseNote
            self.segments = segments
            self.points = points
        }
    }

    /// Explore quota answers: **how did the provider-reported quota windows end?** Provider
    /// truth over the fixed 30 days — not a grain of local token activity (§6.3).
    public struct QuotaPage: Sendable, Equatable {
        /// `All providers · quota windows` / `Claude · quota windows`.
        public let eyebrow: String
        /// Names the coverage in plain language: the main account window only, and why the
        /// history starts when it does. Never implies secondary or model limits have the same
        /// history.
        public let scopeNote: String
        public let sections: [QuotaSection]
        /// The fresh-install sentence, or the scoped no-evidence one. Replaces the body.
        public let emptyMessage: String?

        public init(eyebrow: String, scopeNote: String, sections: [QuotaSection] = [],
                    emptyMessage: String? = nil) {
            self.eyebrow = eyebrow
            self.scopeNote = scopeNote
            self.sections = sections
            self.emptyMessage = emptyMessage
        }
    }

    // MARK: - Explore usage (REV-84 §5)

    /// One provider's share of a selected day: tokens, value, activity and models, all
    /// provider-native. On `All` there is one of these per provider with work that day —
    /// **never** a combined tokens or sessions figure across them.
    public struct DaySection: Sendable {
        public let provider: Tool
        /// Displayed tokens under this provider's own rule, e.g. `88.8M`.
        public let tokens: String
        /// Est. token value for this provider's day, e.g. `$12.40`.
        public let value: String
        /// `5 sessions` / `3 threads` — provider-native noun, singular at one.
        public let activity: String
        /// Per-model rows for exactly this day: `Opus 4.8` / `1.2M` — displayed tokens only
        /// (REV-84 §5.1 as amended 2026-09-01; the day's value is the section's own `value`).
        /// Day grain only — the 30-day model rows live in `Breakdown` and the two never mix.
        public let models: [LabeledRow]
        /// Per-project rows for exactly this day: `kvotar` / `1.0M` — displayed tokens only
        /// (STEP_178 — REV-92 §2 decision 6). This is where the popover's `N more projects ›`
        /// lands, and it is grouped on the same provider-wide path set the popover uses, so the
        /// overflow count and this list agree. Day grain only, like `models`.
        public let projects: [LabeledRow]

        public init(provider: Tool, tokens: String, value: String, activity: String,
                    models: [LabeledRow] = [], projects: [LabeledRow] = []) {
            self.provider = provider
            self.tokens = tokens
            self.value = value
            self.activity = activity
            self.models = models
            self.projects = projects
        }
    }

    /// Everything the corpus can honestly say about one selected day (REV-84 §5.1), fully
    /// formatted. An absent optional group is an **empty array or nil — the view omits it**;
    /// the detail never becomes a grid of `—`.
    public struct DayDetail: Sendable {
        /// `Aug 12`.
        public let title: String
        /// `Partial day` on the clipped oldest sliver, `No activity` on a known-empty day,
        /// nil on an ordinary day with work.
        public let status: String?
        /// One per provider with work that day, report order.
        public let sections: [DaySection]
        /// The day's combined Est. token value — `All` only, only when both providers worked,
        /// rendered once and subordinate, under the experience's `pricingNote`.
        public let combinedValue: String?
        /// Recorded hard blocks on this day, REV-73 row grammar, provider-tagged on `All`.
        public let blocks: [HistoryScreen.RankedRow]
        /// Recorded critical-state observations — `At risk · 3:34 pm` with the stored
        /// utilization rendered as `% left` where kept (`—` where not). Instants, never
        /// intervals.
        public let observations: [HistoryScreen.RankedRow]
        /// Recorded plan/window changes on this day, the existing D-81 row grammar.
        public let changes: [HistoryScreen.RankedRow]
        /// The once-per-detail honesty sentence (REV-84 §5.1) — always present.
        public let evidenceNote: String

        public init(title: String, status: String? = nil, sections: [DaySection] = [],
                    combinedValue: String? = nil, blocks: [HistoryScreen.RankedRow] = [],
                    observations: [HistoryScreen.RankedRow] = [],
                    changes: [HistoryScreen.RankedRow] = [], evidenceNote: String) {
            self.title = title
            self.status = status
            self.sections = sections
            self.combinedValue = combinedValue
            self.blocks = blocks
            self.observations = observations
            self.changes = changes
            self.evidenceNote = evidenceNote
        }
    }

    /// One selectable column of the 31-day strip: the drawn point and the **already-typed**
    /// detail revealed on selection. The view indexes by `id` and calculates nothing — a day
    /// selection is transient presentation state over precomputed content.
    public struct DayEntry: Sendable, Identifiable {
        /// Stable day identity: the day's `start` (local midnight; the clipped oldest day's
        /// slot starts at `periodStart`).
        public let id: Date
        public let point: HistoryScreen.DayPoint
        public let detail: DayDetail

        public init(id: Date, point: HistoryScreen.DayPoint, detail: DayDetail) {
            self.id = id
            self.point = point
            self.detail = detail
        }
    }

    /// One week of one provider's *Week by week*: span, tokens **and** Est. token value
    /// (REV-84 §5.2), with the bar measured against the same provider's busiest week.
    public struct WeekRow: Sendable {
        /// `Aug 9 – Aug 16`.
        public let label: String
        /// `12.4M`, or `No activity` when the zero is known.
        public let tokens: String
        /// `$18.20` — `$0.00` only on a known-zero week.
        public let value: String
        /// Geometry: this week's share of the same provider's busiest week, clamped 0…1.
        public let fraction: Double
        /// `Partial week` on the clipped oldest bucket; nil otherwise.
        public let note: String?

        public init(label: String, tokens: String, value: String, fraction: Double,
                    note: String? = nil) {
            self.label = label
            self.tokens = tokens
            self.value = value
            self.fraction = min(max(fraction, 0), 1)
            self.note = note
        }
    }

    /// One provider's weekly rows. On `All` there is one of these per active provider —
    /// charts stay separate, scales stay the provider's own.
    public struct ProviderWeekly: Sendable {
        public let provider: Tool
        public let rows: [WeekRow]

        public init(provider: Tool, rows: [WeekRow]) {
            self.provider = provider
            self.rows = rows
        }
    }

    /// One provider's visible 30-day total (REV-84 §5.2): tokens, activity and value. Cache
    /// hit moved to the provider Summary's Local-tokens caption (§7 as amended 2026-09-01).
    /// `All` shows one per provider — there is no combined-token variant.
    public struct ProviderTotal: Sendable {
        public let provider: Tool
        /// `Claude total`.
        public let title: String
        public let tokens: String
        /// `133 sessions` / `16 threads`.
        public let activity: String
        public let value: String

        public init(provider: Tool, title: String, tokens: String, activity: String,
                    value: String) {
            self.provider = provider
            self.title = title
            self.tokens = tokens
            self.activity = activity
            self.value = value
        }
    }

    /// One provider's 30-day model rows — kept per provider on `All` (REV-84 §5.1's grouping
    /// rule): model token conventions differ, so the lists are never merged into one ranking.
    public struct ModelGroup: Sendable {
        public let provider: Tool
        /// `Opus 4.8` / `1.2B · $840.12`, each with its track fraction against the same
        /// provider's largest model (STEP_162 — the prototype's ranked-list bars).
        public let rows: [HistoryScreen.RankedRow]

        public init(provider: Tool, rows: [HistoryScreen.RankedRow]) {
            self.provider = provider
            self.rows = rows
        }
    }

    /// The lower explorer, explicitly headed `30-day breakdown` (REV-84 §5.3) so day selection
    /// cannot silently change what its rows mean — structurally: nothing here takes a day.
    public struct Breakdown: Sendable {
        public let title: String
        /// `ProjectGrouping` ranking, provider-tagged only when both providers contribute.
        public let projects: [HistoryScreen.RankedRow]
        public let models: [ModelGroup]
        /// The merged session/thread ranking, provider tags only when needed.
        public let largestWork: [HistoryScreen.RankedRow]

        public init(title: String, projects: [HistoryScreen.RankedRow] = [],
                    models: [ModelGroup] = [], largestWork: [HistoryScreen.RankedRow] = []) {
            self.title = title
            self.projects = projects
            self.models = models
            self.largestWork = largestWork
        }
    }

    /// Explore usage answers: **how did local usage break down?** Three grains inside one mode
    /// — selected day, week by week, 30-day breakdown (REV-84 §5).
    public struct ExplorePage: Sendable {
        /// 31 selectable columns, oldest first, aligned with the drawn strip.
        public let days: [DayEntry]
        /// The initially selected day: newest day with activity, else today (the last column).
        /// Nil only when there are no columns at all.
        public let initialSelection: Date?
        public let legend: [HistoryScreen.DayLegendEntry]
        /// The strip's footer (busiest-day line), same grammar as Summary's strip.
        public let stripFooter: String
        /// Visible 30-day totals, one per active provider.
        public let totals: [ProviderTotal]
        /// Combined 30-day Est. token value — `All` only, both providers active, once,
        /// subordinate, under `pricingNote`. There is no combined-token counterpart.
        public let combinedValue: String?
        public let weekly: [ProviderWeekly]
        public let breakdown: Breakdown
        public let emptyMessage: String?

        public init(days: [DayEntry] = [], initialSelection: Date? = nil,
                    legend: [HistoryScreen.DayLegendEntry] = [], stripFooter: String = "",
                    totals: [ProviderTotal] = [], combinedValue: String? = nil,
                    weekly: [ProviderWeekly] = [],
                    breakdown: Breakdown, emptyMessage: String? = nil) {
            self.days = days
            self.initialSelection = initialSelection
            self.legend = legend
            self.stripFooter = stripFooter
            self.totals = totals
            self.combinedValue = combinedValue
            self.weekly = weekly
            self.breakdown = breakdown
            self.emptyMessage = emptyMessage
        }
    }

    // MARK: - Hard blocks (REV-84 §6)

    /// Hard blocks answers: **what happened when access stopped, and how does it relate to my
    /// activity?** Investigative and provider-honest: unknown durations stay excluded with the
    /// denominator named, and the pattern claim stays behind the REV-73 floor.
    public struct HardBlocksPage: Sendable {
        /// `All providers · hard blocks` / `Claude · hard blocks`.
        public let eyebrow: String
        /// The conclusion lead: recorded count per provider and the last block. The lockout
        /// aggregate moved into `consequence` (STEP_160 — the companion's card), so the two
        /// never repeat each other.
        public let conclusion: String
        /// The known-consequence card: total known lockout as the figure, the recovery
        /// denominator and longest lockout as the caption — `Unknown` when blocks exist but
        /// no reset was recovered; nil with no blocks at all.
        public let consequence: Stat?
        /// Block history, **newest first** — REV-73 row grammar; `All` merges chronologically
        /// with provider tags. This view always lists rows; the conclusion is the aggregate.
        public let rows: [HistoryScreen.RankedRow]
        /// Activity by hour with every block drawn as its own mark. On `All`, each bar's
        /// fraction is against its own provider's busiest hour. The caption describes local
        /// token activity — never effort or productivity.
        public let chart: HistoryScreen.HourChart?
        /// `Most often 2–6 pm` above `claimedRhythmFloor`; below it, the investigative
        /// sample note — which Summary must never borrow as a conclusion.
        public let patternNote: String?
        /// Watching-since plus the honest gaps: weekly-only exhaustion may be absent, and an
        /// unknown reset means an unknown lockout, not zero.
        public let coverageNote: String
        /// `Allowance history` (REV-84 §6 item 6): the same provider-filtered recorded
        /// allowance/window context Summary carries, after the investigation — structural
        /// context near an event, never a claimed cause.
        public let allowance: AllowancePanel?
        /// Replaces the page body when this provider has neither work nor watching history.
        public let emptyMessage: String?

        public init(eyebrow: String = "", conclusion: String, consequence: Stat? = nil,
                    rows: [HistoryScreen.RankedRow] = [],
                    chart: HistoryScreen.HourChart? = nil, patternNote: String? = nil,
                    coverageNote: String, allowance: AllowancePanel? = nil,
                    emptyMessage: String? = nil) {
            self.eyebrow = eyebrow
            self.conclusion = conclusion
            self.consequence = consequence
            self.rows = rows
            self.chart = chart
            self.patternNote = patternNote
            self.coverageNote = coverageNote
            self.allowance = allowance
            self.emptyMessage = emptyMessage
        }
    }

    // MARK: - Root

    /// One provider filter position with its three **evidence** mode payloads. Weekly recap is
    /// not among them: it is cross-provider by contract (§6.2), so it lives once at the root and
    /// a provider filter has nothing to select on it. Every combination exists up front —
    /// switching either control is instant and reads precomputed content.
    public struct ProviderPages: Sendable, Identifiable {
        public let provider: Provider
        public let quota: QuotaPage
        public let explore: ExplorePage
        public let hardBlocks: HardBlocksPage

        public var id: Provider { provider }

        public init(provider: Provider, quota: QuotaPage, explore: ExplorePage,
                    hardBlocks: HardBlocksPage) {
            self.provider = provider
            self.quota = quota
            self.explore = explore
            self.hardBlocks = hardBlocks
        }
    }

    public let header: HistoryScreen.Header
    /// The cross-provider Weekly recap — the ordinary-open mode, held once rather than per
    /// provider (§6.2).
    public let recap: RecapSection
    /// `[.all]` then one per tool, report order — the provider control's data source.
    public let pages: [ProviderPages]
    /// `Local Claude Code and Codex records on this Mac · evidence horizons vary · prices …`.
    public let footer: String
    /// `Priced at published API rates for each model. Not a bill.` — rendered wherever an
    /// Est. token value is visible.
    public let pricingNote: String
    /// The whole-report empty state (controls stay visible above it); nil when any provider
    /// has content.
    public let emptyMessage: String?

    public init(header: HistoryScreen.Header, recap: RecapSection, pages: [ProviderPages],
                footer: String, pricingNote: String, emptyMessage: String? = nil) {
        self.header = header
        self.recap = recap
        self.pages = pages
        self.footer = footer
        self.pricingNote = pricingNote
        self.emptyMessage = emptyMessage
    }

    public var providers: [Provider] { pages.map(\.provider) }

    /// The pages for a filter position, or the first (`.all`) when the kind is not present —
    /// the same fallback rule `HistoryScreen.tab(_:)` has.
    public func pages(_ provider: Provider) -> ProviderPages {
        pages.first { $0.provider == provider } ?? pages[0]
    }
}
