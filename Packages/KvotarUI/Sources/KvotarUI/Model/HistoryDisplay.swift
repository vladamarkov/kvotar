import Foundation
import KvotarCore

/// The History window's chart and row primitives (STEP_109/115/116/120/121, kept through the
/// REV-84/D-108 cutover): the shapes `HistoryExperience` renders — `Header`, the day strip, the
/// hour chart, `RankedRow` — with their geometry and hover grammar. Everything the window draws
/// is strings and clamped fractions; nothing is computed in SwiftUI (the same split
/// `PopoverDisplay` has over the popover).
///
/// The pre-REV-84 one-page pipeline (`Tab`, `Block`, `RowGroup`, `Fact`, `WeeklyChart` and
/// `screen(_:now:)` with its tab builders) was deleted by STEP_160 after the three-view cutover;
/// `HistoryDisplay.experience` in `HistoryDisplay+Experience.swift` is the sole builder. The
/// helpers below it in this file (row grammar, hour captions, change folding, REV-72 window
/// summaries) are shared with that pipeline and stay.
public struct HistoryScreen: Sendable {

    /// The stable window title and the fixed evidence span. Variant A keeps the title stable
    /// while evidence pages name the 30-day horizon locally.
    public struct Header: Sendable {
        public let title: String        // "History"
        public let subtitle: String     // "Jul 18 – Aug 17"

        public var evidenceEyebrow: String {
            "Last \(HistoryReport.periodDays) days · \(subtitle)"
        }

        public init(title: String, subtitle: String) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    /// One tool's share of one day column (STEP_116). `fraction` is **geometry** — a clamped 0…1
    /// the view multiplies by a height — never a judgement about the day.
    public struct DayBar: Sendable, Equatable {
        public let tool: Tool
        public let fraction: Double

        public init(tool: Tool, fraction: Double) {
            self.tool = tool
            self.fraction = min(max(fraction, 0), 1)
        }
    }

    /// One local calendar day of the strip. Every day of the period has one, including empty days
    /// — the axis is the calendar, not the data.
    public struct DayPoint: Sendable, Equatable {
        /// Stacked bottom-up in this order; a tool with nothing that day contributes no bar.
        public let bars: [DayBar]
        /// Tools that hit a limit on this day — a dot under the axis, in the tool's accent.
        public let hitLimitTools: [Tool]
        /// Tools whose account or windows changed on this day (STEP_121) — a **diamond** beside the
        /// dots, same accent. An addition, not a replacement: the strip reaches 31 days and cannot
        /// express `weekly window now 5 days`, so the hover names the change and the row keeps it.
        public let changeTools: [Tool]
        /// Set on the days a week bucket begins, so the strip and the weekly rows cannot disagree.
        public let tickLabel: String?
        /// The hover card's markdown. Pre-formatted here; the view renders it and parses nothing.
        public let hoverBody: String
        /// The column's spoken value (STEP_160 — REV-84 §8): date, per-provider activity,
        /// block/change facts and partial/no-activity state as plain text — no markdown, so
        /// VoiceOver never reads asterisks. Built beside `hoverBody` from the same parts;
        /// defaulted empty for the legacy builder and the hour chart, which keep hover only.
        public let accessibilityValue: String

        public init(bars: [DayBar], hitLimitTools: [Tool] = [], changeTools: [Tool] = [],
                    tickLabel: String? = nil, hoverBody: String, accessibilityValue: String = "") {
            self.bars = bars
            self.hitLimitTools = hitLimitTools
            self.changeTools = changeTools
            self.tickLabel = tickLabel
            self.hoverBody = hoverBody
            self.accessibilityValue = accessibilityValue
        }
    }

    /// A legend swatch: a provider, or one of the two marker shapes drawn under the axis.
    /// **One field, not two booleans** (STEP_121): a swatch is a provider colour, a limit-hit dot
    /// or a change diamond, and never two of those at once.
    public struct DayLegendEntry: Sendable, Equatable {
        public enum Marker: Sendable, Equatable {
            /// The dot under the axis on a day a quota window was blocked (STEP_116).
            case limitHit
            /// The diamond beside it on a day the account or its windows changed (STEP_121).
            case accountChange
        }

        public let label: String
        public let tool: Tool?
        public let marker: Marker?

        public init(label: String, tool: Tool?, marker: Marker? = nil) {
            self.label = label
            self.tool = tool
            self.marker = marker
        }
    }

    /// Tokens per day (STEP_116 — REV-70 §4.1 item 2): the one element that answers *what was I
    /// doing on the day I was cut off*. Oldest day first.
    public struct DayStrip: Sendable, Equatable {
        public let points: [DayPoint]
        public let legend: [DayLegendEntry]
        public let footer: String

        public init(points: [DayPoint], legend: [DayLegendEntry], footer: String) {
            self.points = points
            self.legend = legend
            self.footer = footer
        }
    }

    /// One local clock hour of the hour-of-day chart (STEP_120 — REV-73/D-80). Twenty-four of
    /// these, hour 0 first, whatever the corpus holds: the axis is the clock, not the data.
    public struct HourPoint: Sendable, Equatable {
        /// Stacked bottom-up in this order; a tool with nothing in this hour contributes no bar.
        public let bars: [DayBar]
        /// **One entry per block**, not per tool that has one — three blocks are three marks. This
        /// is what makes a rhythm honest at n = 3, where an averaged distribution would not be.
        public let blockTools: [Tool]
        /// Set on the quarter hours (12a / 6a / 12p / 6p) so the axis can be read without counting.
        public let tickLabel: String?
        /// The hover card's markdown. Pre-formatted here; the view renders it and parses nothing.
        public let hoverBody: String

        public init(bars: [DayBar], blockTools: [Tool] = [], tickLabel: String? = nil,
                    hoverBody: String) {
            self.bars = bars
            self.blockTools = blockTools
            self.tickLabel = tickLabel
            self.hoverBody = hoverBody
        }
    }

    /// Work by hour of day with every block plotted on it (STEP_120). The caption describes what is
    /// **drawn** — never a claimed distribution, which needs the floor the aggregate row applies.
    public struct HourChart: Sendable, Equatable {
        public let points: [HourPoint]          // exactly 24, hour 0 first
        public let legend: [DayLegendEntry]
        public let caption: String

        public init(points: [HourPoint], legend: [DayLegendEntry], caption: String) {
            self.points = points
            self.legend = legend
            self.caption = caption
        }
    }

    /// A row in a ranked list, optionally carrying the provider it belongs to. The tag is set on
    /// the All tab **only when both tools have activity** — on a one-tool machine every row would
    /// carry the same word, which is decoration, not information.
    public struct RankedRow: Sendable {
        public let row: LabeledRow
        public let tag: String?
        /// Bar-track geometry (STEP_162 — the prototype's ranked-list track): this row's
        /// share of the **same provider's** top row in its list, clamped 0…1 (REV-70 §4.6 —
        /// fractions are geometry, never a cross-provider token comparison). Nil draws no
        /// track (event, observation and change rows stay text-only).
        public let fraction: Double?
        /// The accent that fills the track — the row's own provider.
        public let accent: Tool?
        /// Renders the value in the warn hue (`Reset unknown` block rows).
        public let warn: Bool
        /// The instant an event row records, where it has one — a block firing, an observation,
        /// an account change. `nil` on every ranked row that is a ranking rather than an event
        /// (projects, models, sessions), which is why it defaults. Present so a week-scoped
        /// arrival can find its rows without re-reading the label (STEP_183). Never displayed:
        /// the row's own label already carries the date in the D-80/D-81 grammar.
        public let at: Date?

        public init(row: LabeledRow, tag: String? = nil, fraction: Double? = nil,
                    accent: Tool? = nil, warn: Bool = false, at: Date? = nil) {
            self.row = row
            self.tag = tag
            self.fraction = fraction.map { min(max($0, 0), 1) }
            self.accent = accent
            self.warn = warn
            self.at = at
        }
    }

}

/// Pure static mapping `HistoryReport → HistoryScreen`. No I/O, no state, no `Date()` — `now` is
/// passed in so tests are deterministic and the window cannot format a figure differently from
/// the popover: every number goes through the same `Fmt` helpers and the same shared Core rules
/// (`DisplayedTokens`, `CacheHit`) the §2.5a/§2.5b cards use.
public enum HistoryDisplay {

    /// The counterfactual line under every Est.-token-value figure (REV-62/D-62). It used to live
    /// on the retired `LocalSessionSplit`; the History window is its remaining consumer, and the
    /// popover's own value section carries its own §REV92 wording.
    public static let pricingNote = "Priced at published API rates for each model. Not a bill."

    // MARK: - Vocabulary

    /// Sub-heading inside `Where did it go?` — was `Biggest sessions` in STEP_109. It holds both
    /// Claude sessions and Codex threads and the reader does not care which, so it is named for
    /// the work, not the container.
    public static let largestWorkTitle = "Largest work"

    public static let estValueLabel = "Est. token value"
    public static let sessionsLabel = "Sessions"
    public static let threadsLabel = "Threads"
    /// The strip's footer lead-in.
    public static let busiestDayLabel = "Busiest day"
    /// A day with nothing in it, in the hover card. **Not `—`**, for `noActivityValue`'s reason:
    /// the day is *known* to be empty, not unknown.
    public static let noActivityDayValue = "no activity"
    /// The clipped oldest day — the period starts mid-day, so its first slot is a sliver.
    public static let partialDayNote = "partial day"
    /// The legend swatch for the markers under the axis.
    public static let limitHitLegendLabel = "Hit the limit"
    /// …and for the second marker shape beside it (STEP_121).
    public static let accountChangeLegendLabel = "Account change"

    /// A week with no work. **Not `—`**: that is the *unknown* placeholder (STEP_107), and a week
    /// with nothing in it is known, not unknown.
    public static let noActivityValue = "No activity"

    /// The row for tokens whose working directory was not a project — never recorded, or a temp /
    /// home directory (`ProjectGrouping.isNonProject`). Their tokens are real; the label just
    /// declines to call `/private/tmp` a project.
    public static let noProjectLabel = "(no project)"
    /// Account-change rows shown before the overflow row (STEP_121 — was the plan-change cap).
    public static let accountChangeRowLimit = 5
    /// The lead-in on a plan-change row, and on its hover line.
    public static let planChangedLabel = "Plan changed"
    /// The lead-ins on the window rows (STEP_141). Every row in the list now opens with what kind
    /// of thing changed, so the eye reads one column of leads and one of dates — a bare date
    /// beside `Plan changed · Aug 12` looked like a different list.
    public static let windowsChangedLabel = "Windows changed"
    public static let windowChangedLabel = "Window changed"
    public static let windowAddedLabel = "Window added"
    public static let windowRemovedLabel = "Window removed"
    public static let resetEarlyLabel = "Reset early"
    /// The overflow row's label, when more changes landed than the cap draws.
    public static let earlierChangesLabel = "Earlier changes"

    // When did I hit limits? — copy and thresholds (REV-73 §4.1 / D-80).

    static let mostOftenLabel = "Most often"
    /// Blocks needed before the app may claim *when* limits tend to land. Below it the chart plots
    /// each block and the copy describes the drawing; a tendency drawn from three points is the
    /// error REV-72 removed next door.
    static let claimedRhythmFloor = 12
    /// …and the claimed band must hold more than this share of them, or it is not a tendency.
    static let claimedRhythmShare = 0.5
    /// The width of the band the `Most often` line names, in hours.
    static let rhythmBandHours = 4
    /// A window this wide or narrower earns the hour-of-day chart. **Width, never the tool name**
    /// (D-80): a five-hour block gets the chart whoever reported it, and a seven- or thirty-day
    /// block gets the lockout row alone, because the hour you were cut off hardly matters when the
    /// consequence runs to next Tuesday.
    static let shortWindowSeconds = 6 * 3600

    // Is the window changing? — copy and thresholds (REV-72 §4.1 / D-79).

    /// The only verdict the app may state, and only at `minimumQualifyingCycles`. **Never
    /// `steady`, and never `no sign of change`:** both read as a guarantee, and with a 35–40 %
    /// detection floor neither is one (REV-72 §5).
    public static let nothingConclusiveVerdict = "Nothing conclusive yet."
    static let notEnoughLead = "Not enough history yet"
    /// A tool the app has never watched through a window — distinct from one watched and found
    /// wanting, which is what the counted forms say.
    static let neverWatchedVerdict =
        "Not enough history yet — Kvotar has not watched a full window."
    static let providerCutSentence =
        "A provider-side cut would show every model's rate falling together and staying down."
    /// A cycle whose span does not match a window width the app can name (D-58 vocabulary).
    static let unknownGrain = "Window"
    /// Cycles needed before a verdict may be stated. Three is a baseline; REV-72 §4.3's notice
    /// would want two more on top of it to confirm.
    static let minimumQualifyingCycles = 3
    /// Percentage points a window must have moved for its rate to mean anything. Both providers
    /// report whole integers, so a two-point cycle is one or two quantisation steps (REV-72 §3.1).
    static let minimumCycleDelta = 10.0
    /// The most of a cycle's rise that may have no local work behind it — the web app, another
    /// machine. Above this the cycle is not evidence about this Mac's work.
    static let maximumUnseenShare = 0.20
    /// Ranked rows kept on the All tab, where two tools share the list.
    public static let allRankedRowLimit = 3

    public static var emptyReportMessage: String {
        "No local Claude Code or Codex activity in the last \(HistoryReport.periodDays) days yet."
    }

    // MARK: - Screen

    // MARK: - All

    // MARK: - One tool

    // MARK: - Facts

    // MARK: - Model split

    // MARK: - Week by week

    // MARK: - Tokens per day (STEP_116)

    private static func tokens(_ t: HistoryReport.ToolReport, _ column: Int) -> Int {
        t.days.indices.contains(column) ? t.days[column].tokens : 0
    }

    /// `88.8M · 5 sessions`, prefixed with the provider when two tools share the strip. Codex
    /// counts threads (PATTERNS.md naming table), and one of anything is singular — a per-day
    /// figure shows a `1` far more often than a 30-day total does.
    static func dayFigure(_ d: HistoryReport.Day, tool: Tool, named: Bool) -> String {
        let noun = tool == .codex ? "thread" : "session"
        let unit = d.sessions == 1 ? noun : noun + "s"
        let figure = "\(Fmt.tokens(d.tokens)) · \(d.sessions) \(unit)"
        return named ? "\(tool.tabLabel) \(figure)" : figure
    }

    /// The columns a week bucket begins on — the report's *own* week boundaries, so the strip's
    /// ticks and the weekly bar rows cannot disagree about where a week starts. The clipped oldest
    /// bucket is skipped: its start is the period's, not a week's, and it sits two days from the
    /// next tick.
    static func tickColumns(days: [HistoryReport.Day],
                            weeks: [HistoryReport.Week]) -> Set<Int> {
        var result: Set<Int> = []
        for week in weeks where !week.isPartial {
            guard let index = days.lastIndex(where: { $0.start <= week.start }) else { continue }
            result.insert(index)
        }
        return result
    }

    /// `Busiest day Aug 12 · 88.8M`, or one clause per tool when two share the strip — **never** a
    /// combined figure, which is why this is per tool rather than per column.
    static func busiestDayFooter(_ active: [HistoryReport.ToolReport], named: Bool) -> String {
        let clauses = active.compactMap { t -> String? in
            guard let day = busiestDay(t) else { return nil }
            let figure = "\(Fmt.monthDay(day.start)) · \(Fmt.tokens(day.tokens))"
            return named ? "\(t.tool.tabLabel) \(figure)" : figure
        }
        guard !clauses.isEmpty else { return "" }
        return "\(busiestDayLabel) \(clauses.joined(separator: " · "))"
    }

    /// The first day holding the tool's maximum — first, not last, so a tie is resolved the way a
    /// reader scanning left to right would resolve it.
    static func busiestDay(_ t: HistoryReport.ToolReport) -> HistoryReport.Day? {
        var best: HistoryReport.Day?
        for day in t.days where day.tokens > (best?.tokens ?? 0) { best = day }
        return best
    }

    // MARK: - Rows

    /// Top projects by tokens: `kvotar` / `18.2M · 41 sessions` — the trailing folder, the
    /// same `projectName` rule the popover's project row uses (a full path wraps to three lines
    /// on the dogfood machine). Rows arrive already grouped by `ProjectGrouping` (sub-folders
    /// rolled up, temp/home folded to nil); a nil project reads as `noProjectLabel` — never
    /// dropped, since its tokens are real.
    static func projectRow(_ p: HistoryReport.Project, tool: Tool) -> LabeledRow {
        let unit = tool == .codex ? "threads" : "sessions"
        return LabeledRow(label: p.name.map(DisplayFormatter.projectName) ?? noProjectLabel,
                          value: "\(Fmt.tokens(p.tokens)) · \(p.sessions) \(unit)")
    }

    static func projectRows(_ t: HistoryReport.ToolReport) -> [LabeledRow] {
        t.projects.map { projectRow($0, tool: t.tool) }
    }

    /// One piece of work: `Aug 14 · kvotar` / `4.1M · $6.20`. The session id itself is never
    /// shown — it means nothing to a reader and would only invite copy-paste into a support ticket.
    static func sessionRow(_ s: HistoryReport.Session) -> LabeledRow {
        var label = Fmt.monthDay(s.lastSeenAt)
        if let project = s.project, !project.isEmpty {
            label += " · \(DisplayFormatter.projectName(project))"
        }
        return LabeledRow(label: label,
                          value: "\(Fmt.tokens(s.tokens)) · \(Fmt.dollarValue(s.value))")
    }

    // MARK: - Limit blocks (REV-73 / D-80 — STEP_120)

    /// The band the blocks tend to land in, or `nil`. Two gates, and the line is withheld unless
    /// both pass: at least `claimedRhythmFloor` blocks, and more than `claimedRhythmShare` of them
    /// inside one `rhythmBandHours` band. **Hours only, never a weekday** — nothing on this page
    /// plots weekdays, and a claim must describe an axis the reader can check (REV-73 §6).
    static func claimedRhythm(_ blocks: [HistoryReport.LimitBlock]) -> String? {
        guard blocks.count >= claimedRhythmFloor else { return nil }
        let hours = blocks.map { Calendar.current.component(.hour, from: $0.firedAt) }
        var best = (start: 0, count: 0)
        // Only bands that *begin* on an hour a block landed in. Otherwise a run at 2–4 pm names
        // itself `1–5 pm`, because an empty leading hour scores exactly the same and sorts first.
        for start in 0..<24 where hours.contains(start) {
            let count = hours.filter { hour in
                (0..<rhythmBandHours).contains { (start + $0) % 24 == hour }
            }.count
            if count > best.count { best = (start, count) }
        }
        guard Double(best.count) > Double(blocks.count) * claimedRhythmShare else { return nil }
        return hourBand(from: best.start, hours: rhythmBandHours)
    }

    // MARK: - Hour of day (REV-73 §4.1 / D-80)

    private static func work(_ t: HistoryReport.ToolReport, _ hour: Int) -> Int {
        t.workByHour.indices.contains(hour) ? t.workByHour[hour] : 0
    }

    /// The sentence under the chart. It says what is **drawn** and stops there: which part of the
    /// day the marks are in, and which part the bars are tallest in. It never claims a tendency —
    /// that is `claimedRhythm`'s job and it has a floor this does not.
    static func hourCaption(marks: [Int: [Tool]], work: [Int]) -> String {
        let count = marks.values.reduce(0) { $0 + $1.count }
        let bands = Set(marks.keys.map { dayBand($0) })
        let lead: String
        if let band = bands.count == 1 ? bands.first : nil {
            lead = count == 1
                ? "The one block landed \(bandPhrase(band))"
                : "Every block landed \(bandPhrase(band))"
        } else {
            lead = "Blocks landed across the day"
        }
        guard let busiest = busiestBand(work) else { return "\(lead)." }
        if bands.count == 1, bands.first == busiest {
            return "\(lead), when you work hardest."
        }
        return bands.count == 1
            ? "\(lead), though you work hardest \(bandPhrase(busiest))."
            : "\(lead); you work hardest \(bandPhrase(busiest))."
    }

    /// Six-hour quarters of the day. Coarse on purpose: the caption is a direction to look in, not
    /// a measurement, and a narrower band would imply a precision three marks cannot carry.
    enum DayBand: Sendable, Hashable { case night, morning, afternoon, evening }

    static func dayBand(_ hour: Int) -> DayBand {
        switch hour {
        case 6..<12:  return .morning
        case 12..<18: return .afternoon
        case 18..<24: return .evening
        default:      return .night
        }
    }

    static func bandPhrase(_ band: DayBand) -> String {
        switch band {
        case .night:     return "overnight"
        case .morning:   return "in the morning"
        case .afternoon: return "in the afternoon"
        case .evening:   return "in the evening"
        }
    }

    /// The quarter of the day holding the most drawn work, or `nil` when there is none to name.
    static func busiestBand(_ work: [Int]) -> DayBand? {
        var totals: [DayBand: Int] = [:]
        for (hour, tokens) in work.enumerated() { totals[dayBand(hour), default: 0] += tokens }
        guard let best = totals.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return best.key
    }

    /// `12 am` / `2 pm` — the clock vocabulary `Fmt.clock` uses, for an hour with no date attached.
    static func hourLabel(_ hour: Int) -> String {
        let suffix = hour < 12 ? "am" : "pm"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve) \(suffix)"
    }

    /// The axis tick: `12a` / `6p`. Full labels would collide at 24 columns.
    static func shortHourLabel(_ hour: Int) -> String {
        let suffix = hour < 12 ? "a" : "p"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve)\(suffix)"
    }

    /// `2–6 pm`, or `10 am–2 pm` when the band crosses noon or midnight.
    static func hourBand(from start: Int, hours: Int) -> String {
        let end = (start + hours) % 24
        let startSuffix = start < 12 ? "am" : "pm"
        let endSuffix = end < 12 ? "am" : "pm"
        let startHour = start % 12 == 0 ? 12 : start % 12
        let endHour = end % 12 == 0 ? 12 : end % 12
        return startSuffix == endSuffix
            ? "\(startHour)–\(endHour) \(endSuffix)"
            : "\(startHour) \(startSuffix)–\(endHour) \(endSuffix)"
    }

    /// A tab has nothing to show only when there is neither work nor watching history. A tool with
    /// recorded events but no tokens still renders — its evidence blocks are the content.
    static func isBlank(_ t: HistoryReport.ToolReport) -> Bool {
        t.isEmpty && t.watchingSince == nil && t.accountChanges.isEmpty && t.limitHitCount == 0
            && t.workPerPercent.isEmpty
    }

    // MARK: - Is the window changing? (REV-69 / STEP_114, cut to a summary by REV-72 / STEP_119)

    // MARK: - What changed (REV-73 / D-81 — STEP_121; folded rows STEP_141)

    /// One row of *What changed*: a stored change as it is, or the one shape this surface builds
    /// out of two — a provider restructuring its windows in a single poll. The detector records
    /// that as a `window_width_changed` on the primary slot **and** a `window_added` on the
    /// secondary, at the same instant; read one at a time they contradict each other (*weekly
    /// window now 5 hours* beside *weekly window added*, the 2026-08-25 Codex change). The fold is
    /// display-only: nothing is stored differently and the day strip counts the folded entry.
    enum ChangeEntry: Equatable {
        case single(HistoryReport.AccountChange)
        /// `before` / `after` are the widths in seconds of every window the provider carried, in
        /// slot order, as far as the two rows say — `nil` where a row carried no usable width.
        case restructured(at: Date, before: [Int?], after: [Int?])

        var at: Date {
            switch self {
            case .single(let c): return c.at
            case .restructured(let at, _, _): return at
            }
        }
    }

    /// The stored changes, with each same-instant width-change + window-added pair folded into
    /// one `.restructured` entry. Order is whatever the input's is.
    static func changeEntries(_ changes: [HistoryReport.AccountChange]) -> [ChangeEntry] {
        // Pair first, emit second: the store returns the two rows in id order, and the detector
        // appends the secondary's `window_added` before the primary's `window_width_changed`, so
        // whichever comes first has to be able to find the other.
        var partner: [Int: Int] = [:]   // width-change index → window-added index
        var taken = Set<Int>()
        for (i, change) in changes.enumerated() where change.kind == .windowWidthChanged {
            if let j = changes.indices.first(where: { j in
                !taken.contains(j) && changes[j].kind == .windowAdded && changes[j].at == change.at
            }) {
                partner[i] = j
                taken.insert(j)
            }
        }
        var folded: [ChangeEntry] = []
        for (i, change) in changes.enumerated() where !taken.contains(i) {
            if let j = partner[i] {
                folded.append(.restructured(
                    at: change.at,
                    before: [change.oldValue.flatMap(Int.init)],
                    after: [change.newValue.flatMap(Int.init),
                            changes[j].newValue.flatMap(Int.init)]))
            } else {
                folded.append(.single(change))
            }
        }
        return folded
    }

    /// `Plan changed · Aug 12` → `go → plus`; `Windows changed · Aug 25` → `weekly → 5-hour +
    /// weekly`; `Window added · Aug 25` → `weekly window`. One grammar: the lead says what kind of
    /// thing changed, the date sits beside it, and the value is the before-and-after where there
    /// is one and the window's name where there is not.
    static func accountChangeRow(_ entry: ChangeEntry) -> LabeledRow {
        let (lead, value) = changeParts(entry)
        return LabeledRow(label: "\(lead) · \(Fmt.monthDay(entry.at))", value: value)
    }

    /// The lead and the value of a row, shared with the hover line. The §2.8 fact grammar holds,
    /// unchanged from the receipt STEP_119 removed: **never a size, never an accusation** — the
    /// wire does not carry how big an allowance is, so no copy here states one. Widths only.
    static func changeParts(_ entry: ChangeEntry) -> (lead: String, value: String) {
        switch entry {
        case .restructured(_, let before, let after):
            return (windowsChangedLabel, "\(widthList(before)) → \(widthList(after))")
        case .single(let change):
            let grain = grainName(change.windowType)
            switch change.kind {
            case .planChanged:
                return (planChangedLabel, "\(change.oldValue ?? "—") → \(change.newValue ?? "—")")
            case .windowWidthChanged:
                let old = widthName(change.oldValue) ?? "—"
                let new = widthName(change.newValue) ?? grain ?? "a new length"
                return (windowChangedLabel, "\(old) → \(new)")
            case .windowAdded:
                return (windowAddedLabel, windowNoun(widthName(change.newValue) ?? grain))
            case .windowRemoved:
                return (windowRemovedLabel, windowNoun(widthName(change.oldValue) ?? grain))
            case .earlyReset:
                return (resetEarlyLabel, windowNoun(grain))
            }
        }
    }

    /// `weekly window`, or just `window` when the row could not name a width (D-58's load-bearing
    /// "say nothing" — a guessed grain would be a claim).
    static func windowNoun(_ grain: String?) -> String {
        grain.map { "\($0) window" } ?? "window"
    }

    /// A stored width (`"604800"`) as the grain the app already calls it — `weekly`, `5-hour`,
    /// `5-day`. Lower case: these sit mid-sentence.
    static func widthName(_ seconds: String?) -> String? {
        DisplayFormatter.windowGrain(seconds: seconds.flatMap(Int.init)).map { $0.lowercased() }
    }

    /// `5-hour + weekly` — the windows a provider carries, in slot order. An unnamed one reads as
    /// `window`, so the count of windows is never lost even where a width is.
    static func widthList(_ widths: [Int?]) -> String {
        widths.map { DisplayFormatter.windowGrain(seconds: $0)?.lowercased() ?? "window" }
            .joined(separator: " + ")
    }

    /// The stored `window_type` in the reader's vocabulary. `DisplayFormatter.windowGrain` is the
    /// width-based one; this is the fallback for a row that carries a name and no usable width.
    static func grainName(_ windowType: String?) -> String? {
        guard let windowType else { return nil }
        switch windowType {
        case "five_hour": return "5-hour"
        case "weekly": return "weekly"
        case "monthly": return "monthly"
        default: return windowType.replacingOccurrences(of: "_", with: "-")
        }
    }

    /// Which day column each change belongs to, by the columns' own spans — a column runs from its
    /// own `start` to the next one's, so this needs no calendar and cannot drift from the reader's.
    /// Folded entries, so a restructuring is one mark and one hover line, not two.
    static func changeColumns(_ t: HistoryReport.ToolReport) -> [Int: [ChangeEntry]] {
        guard !t.days.isEmpty else { return [:] }
        var result: [Int: [ChangeEntry]] = [:]
        for entry in changeEntries(t.accountChanges) {
            guard let index = t.days.lastIndex(where: { $0.start <= entry.at }) else { continue }
            result[index, default: []].append(entry)
        }
        return result
    }

    /// The hover line for a marked day: `Plan changed go → plus`, `Windows changed weekly → 5-hour
    /// + weekly`, `Weekly window added`. The before-and-after rows keep their lead; the named-window
    /// rows read as a sentence, because `Window added weekly window` is not one.
    static func changeHoverLine(_ entry: ChangeEntry, tool: Tool, named: Bool) -> String {
        let (lead, value) = changeParts(entry)
        var text: String
        switch entry {
        case .restructured:
            text = "\(lead) \(value)"
        case .single(let change):
            switch change.kind {
            case .planChanged, .windowWidthChanged:
                text = "\(lead) \(value)"
            case .windowAdded:
                text = "\(value) added"
            case .windowRemoved:
                text = "\(value) removed"
            case .earlyReset:
                text = "\(value) reset early"
            }
            text = text.prefix(1).uppercased() + text.dropFirst()
        }
        if named { text = "\(tool.tabLabel) · \(text)" }
        return text
    }

    /// The verdict, and the figure row when there is enough history to earn one.
    ///
    /// `Nothing conclusive yet.` is the **only** verdict the app may state, and only at
    /// `minimumQualifyingCycles`. Below that it says how little it has, which is a fact about the
    /// watching rather than a claim about the window.
    static func windowChangeSummary(_ t: HistoryReport.ToolReport)
        -> (verdict: String, row: LabeledRow?) {
        let cycles = qualifyingCycles(t)
        let count = cycles.points.count
        let since = t.watchingSince
        let sinceClause = since.map { " since \(Fmt.monthDay($0))" } ?? ""

        guard count >= minimumQualifyingCycles else {
            if count == 0, since == nil { return (neverWatchedVerdict, nil) }
            let usable = count == 0
                ? "no usable cycle"
                : "\(count) usable cycle\(count == 1 ? "" : "s")"
            return ("\(notEnoughLead) — \(usable)\(sinceClause).", nil)
        }

        let rates = cycles.points.compactMap(correctedRate).sorted()
        let low = Int((rates.first ?? 0).rounded()), high = Int((rates.last ?? 0).rounded())
        // Whole dollars: the precision the measurement has, not the precision it could print.
        let value = low == high
            ? "about $\(low) of work per 1%"
            : "$\(low) – $\(high) of work per 1%"
        return (nothingConclusiveVerdict,
                LabeledRow(label: "\(cycles.grain) · \(count) cycles\(sinceClause)", value: value))
    }

    /// The cycles the summary may speak for, and the name of the window they belong to.
    ///
    /// **One slot only** — the widest whole-cycle slot, ties broken toward the secondary window,
    /// which is the weekly one by construction (`DiscontinuityDetector.secondaryWindowSeconds`).
    /// On Claude that is the weekly slot; on Codex its single seven-day one. Claude's five-hour
    /// slot arrives re-aggregated per day (`byDay`) and is excluded outright: REV-72 §3.5 measured
    /// it at a 2.5× spread on its *cleanest* days, which is noise, not a series.
    ///
    /// A cycle qualifies (complete or still running) when the window moved at least
    /// `minimumCycleDelta` points — below that the rate is computed from one or two whole-percent
    /// quantisation steps and cannot mean anything — and at most `maximumUnseenShare` of that rise
    /// had no local work behind it, since a cycle half of whose movement came from the web app or
    /// another machine is not evidence about this one.
    static func qualifyingCycles(_ t: HistoryReport.ToolReport)
        -> (grain: String, points: [WorkPerPercentSeries.Point]) {
        let cycleSlots = t.workPerPercent.slots.filter { !$0.byDay }
        let slot = cycleSlots.max { a, b in
            (a.windowSeconds ?? 0, a.isPrimary ? 0 : 1) < (b.windowSeconds ?? 0, b.isPrimary ? 0 : 1)
        }
        guard let slot else { return (unknownGrain, []) }
        let points = slot.points.filter {
            $0.deltaPct >= minimumCycleDelta
                && ($0.unexplainedShare ?? 0) <= maximumUnseenShare
                && correctedRate($0) != nil
        }
        return (DisplayFormatter.windowGrain(seconds: slot.windowSeconds) ?? unknownGrain, points)
    }

    /// `$ per 1 % ÷ (1 − unseen share)` — the rate over the part of the rise this Mac can account
    /// for. The raw rate is never displayed, and not merely because it is noisy: it **misorders
    /// the weeks** (REV-72 §3.2 — Jul 24–31 reads cheapest of the period raw at $8.01 and mid-pack
    /// corrected at $10.40).
    static func correctedRate(_ point: WorkPerPercentSeries.Point) -> Double? {
        guard let raw = point.dollarsPerPct else { return nil }
        let seen = 1 - (point.unexplainedShare ?? 0)
        guard seen > 0 else { return nil }
        return raw / seen
    }

    /// What a real cut would look like, then where the numbers come from. One paragraph, as
    /// REV-72 §4.1 renders it. **Direction matters and is the reason this sentence exists:** a
    /// higher rate means the window is *harder* to move, which is good news, and a sustained drop
    /// across every model is the alarm — the opposite of how "cost per 1 %" reads at a glance.
    static func changeFootnote(since: Date?) -> String {
        let prices = since.map { "Recorded since \(Fmt.monthDay($0)) · list prices, not a bill." }
            ?? "List prices, not a bill."
        return "\(providerCutSentence) \(prices)"
    }

    // MARK: - Footer

    /// "Local Claude Code and Codex records on this Mac · evidence from Jun 30 · prices v1.4
    /// (2026-08-11)". Says what the numbers are made of; the earliest evidence date is the older
    /// of the two tools' oldest events, and is omitted when there is none.
    static func footer(_ report: HistoryReport) -> String {
        var parts = ["Local Claude Code and Codex records on this Mac"]
        if let oldest = report.tools.compactMap(\.evidenceFrom).min() {
            parts.append("evidence from \(Fmt.monthDay(oldest))")
        }
        if let version = report.pricingVersion {
            if let updated = report.pricingUpdated {
                parts.append("prices v\(version) (\(updated))")
            } else {
                parts.append("prices v\(version)")
            }
        }
        return parts.joined(separator: " · ")
    }
}
