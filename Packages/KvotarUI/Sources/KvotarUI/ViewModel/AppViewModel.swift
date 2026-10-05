import SwiftUI
import KvotarCore

/// The single `@MainActor` model bridging the actor world to SwiftUI (PATTERNS.md §SwiftUI state
/// management). Instantiated once at app startup and injected via `.environmentObject`; views hold
/// no business logic and read from this model only.
///
/// The `PollCoordinator` (App target) drives each poll on its own actors, then hops to the main
/// actor and calls `apply` / `applyUnavailable` / `applyUndetected` — the only mutation entry
/// points. Everything the menu bar and popover render (`menuBarRender`, the two
/// display states) is derived here via `DisplayFormatter`, so the coordinator never touches
/// presentation shapes.
@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var claudeState: ClaudeDisplayState {
        didSet { releaseAnatomyOnFamilyChange(.claude, claudeState.header?.verdict?.family) }
    }
    @Published public var codexState: CodexDisplayState {
        didSet { releaseAnatomyOnFamilyChange(.codex, codexState.header?.verdict?.family) }
    }
    /// A tab switch is a new look: it releases a pinned anatomy (UI Spec Part 3 §5.3) and any
    /// hover card, peeked or pinned (§5.1 — STEP_111), and re-arms the settle guard.
    @Published public var activeTab: Tool {
        didSet { if oldValue != activeTab { pinnedAnatomy = nil; resetExplanationCards() } }
    }
    /// The tool the §15.1 priority rule would auto-open. Recomputed with `activeTab` on each
    /// popover open via `selectDefaultTab`. Never labeled in the UI (D-49) — the user sees its
    /// outcome, which is the tab that opened.
    @Published public private(set) var defaultTab: Tool

    /// Everything the status item renders (Baseline §14.1 v5.4). Rebuilt on every `apply` and
    /// on a display-mode change.
    @Published public private(set) var menuBarRender: MenuBarRender
    /// The user-selected §1.0 display mode. Read from `settings` at startup; written by the
    /// interim context-menu picker (Step 30's settings window replaces it).
    @Published public private(set) var menuBarDisplayMode: MenuBarDisplayMode = .bothStacked

    /// True when *both* tools are undetected (no credentials AND no JSONL) — the popover opens to
    /// the combined welcome instead of an empty tabbed view (UI Spec Part 3 §3). Flipped false as
    /// soon as either tool is detected (any `apply` / `applyUnavailable` / `applyCached`).
    @Published public private(set) var bothUndetected: Bool = false

    /// The tools the popover renders tabs for (D-68 — STEP_105): two → today's tabbed layout,
    /// one → tabless single-tool popover, none → the combined welcome (`bothUndetected`). Same
    /// §1.0/D-32 predicate as the menu bar (undetected = no credentials AND no JSONL, as the
    /// coordinator classified it). A tool not yet classified counts as detected, so a two-tool
    /// machine keeps its two "Connecting…" tabs through startup. Stable `Tool.allCases` order.
    @Published public private(set) var detectedTools: [Tool] = Tool.allCases

    /// The tool whose setup card the popover is transiently showing — set by the right-click
    /// `Set up <tool>…` item (D-68, UI Spec Part 3 §1a), cleared by the next ordinary open
    /// (`selectDefaultTab`). Never persisted.
    @Published public private(set) var transientSetupTool: Tool?

    /// How tall the popover may grow on the screen presenting it (Baseline §15.2 — STEP_179).
    /// `MenuBarController` measures it from that screen's visible frame and the status button
    /// before every open, and again if the display configuration changes while the popover is up.
    /// **`nil` means unbounded** — the natural-height path every preview, snapshot and test that
    /// never opened a real popover keeps taking. Transient: never persisted.
    @Published public var popoverMaxHeight: CGFloat?

    /// The tab whose verdict anatomy is **pinned** (UI Spec Part 3 §5.3, D-73 — STEP_110), or nil.
    /// The hover *peek* is view-local state; the pin is owned here because AppKit must be able to
    /// release it (the hosting controller outlives a popover close, so view state would survive
    /// one) and because STEP_111/113's exclusivity rules — one pinned thing at a time, no coach
    /// mark while something is pinned — need one owner. Transient: never persisted, every
    /// popover open starts nil.
    @Published public private(set) var pinnedAnatomy: Tool?
    /// The verdict family last rendered per tool — a pinned anatomy is released when it changes
    /// (a new family is a different anatomy), and only then: the 30 s freshness re-render and
    /// every ordinary poll keep the family and so keep the card up with live values.
    private var lastVerdictFamily: [Tool: VerdictFamily] = [:]

    // MARK: Explanation layer — hover cards (UI Spec Part 3 §5.1/§5.2, D-72 — STEP_111)
    // Methods live in `AppViewModel+ExplanationLayer.swift`; the stored state is here because a
    // Swift extension cannot add it. Everything below is transient — never persisted, every
    // popover open starts clean.

    /// The element the pointer is resting on — drives the label's hover tell (brighter + dotted
    /// underline). Set on enter, cleared on leave; independent of whether a card is showing yet.
    @Published public internal(set) var hoveredExplanation: ExplanationTarget?
    /// The card showing as a *peek* (pointer rested ≥ `hoverPeekDelay`; every element re-arms the
    /// full delay — there is no instant swap between adjacent ones, D-91), dropped `hoverGraceLeave`
    /// after the pointer leaves both the element and the card.
    @Published public internal(set) var peekedCard: ExplanationTarget?
    /// The card **pinned** by a click. Owned here for the same reason as `pinnedAnatomy`: AppKit
    /// releases it on close, and the exclusivity rules need one owner — pinning a card releases a
    /// pinned anatomy and vice versa; one card at a time.
    @Published public internal(set) var pinnedCard: ExplanationTarget?
    /// The pending peek-**in** timer — one element waiting out `hoverPeekDelay`.
    var explanationTimer: Task<Void, Never>?
    /// The pending peek-**out** timer — the showing card waiting out `hoverGraceLeave`. Separate
    /// from the peek-in one since STEP_132: with the instant swap gone, entering B while A is
    /// showing must let A's grace run *and* start B's delay, and one shared task cancelled
    /// whichever arrived second.
    var explanationEndTimer: Task<Void, Never>?
    /// Pointer is over the card body itself — keeps a peek alive while the user reads it.
    var explanationCardHovered = false
    /// When the layer last (re)started — popover open, tab switch. Hover-enters inside
    /// `hoverSettle` of it are the phantom AppKit delivers while the window re-frames
    /// (STEP_110, log-verified) and are ignored.
    var explanationSettledAt = Date.distantPast
    /// UI Spec Part 1 §5 tuning — the shared `ExplanationTiming` (STEP_132), so the cards, the
    /// anatomy and History cannot drift apart. Instance values so tests can shrink them.
    public var hoverPeekDelay: Duration = ExplanationTiming.peekDelay
    public var hoverGraceLeave: Duration = ExplanationTiming.graceLeave
    /// The clock the peek and grace timers sleep on. The app keeps the default (what
    /// `Task.sleep` uses); tests drive a manual one instead of sleeping on the wall clock (STEP_277).
    public var hoverClock: any Clock<Duration> = ContinuousClock()
    public var hoverSettle: TimeInterval = ExplanationTiming.settle

    // MARK: "Since you last looked" (UI Spec Part 1 §2.8 / Part 2 §2.10, D-75 — STEP_112)
    // Methods live in `AppViewModel+DeltaLine.swift`; stored state here for the same reason.

    /// The line to render as row 0 of each tab, if any — set when the tab is displayed, cleared
    /// by `✕`, a re-display, or popover close. Never re-computed while the popover is open.
    @Published public internal(set) var deltaLines: [Tool: String] = [:]
    /// What each tab showed the last time it was displayed — the in-memory truth; the `settings`
    /// row is only how it survives a relaunch (seeded once by the composition root).
    var lastOpenSnapshot: [Tool: LastOpenSnapshot] = [:]
    /// Bumped on every display and on close, so a window-boundary read that completes after the
    /// popover moved on cannot publish onto the wrong open.
    var deltaLineGeneration: [Tool: Int] = [:]
    /// Persists a freshly taken snapshot (`LastOpenSnapshot.encoded()`) under
    /// `LastOpenSnapshot.settingsKey(tool)`. Injected by the composition root; nil in tests.
    public var onPersistLastOpenSnapshot: ((Tool, String) -> Void)?
    /// The previous window's outcome for the window-boundary form (`SQLiteStore
    /// .previousWindowOutcome`); `before` is the current window's reset, nil on a fresh null.
    /// Injected by the composition root; nil ⇒ the boundary line falls back to its plain form.
    public var loadWindowOutcome: ((Tool, Date?) async -> WindowOutcome?)?
    /// §2.8 trigger 6 (STEP_146): the window facts recorded for `tool` since the given instant —
    /// `discontinuity_events` window rows, not plan changes. Composition-root wired; `nil` (tests,
    /// no store) means the line is evaluated without facts, synchronously.
    public var loadWindowFacts: ((Tool, Date) async -> [HistoryReport.AccountChange])?
    /// Persists one long-limit warning episode under `ReminderEpisode.settingsKey(tool:limit:)`,
    /// or clears the row when the value is nil (REV-98 §2.3 — STEP_202). Injected by the
    /// composition root; nil in tests and previews, where the schedule runs entirely in memory.
    /// Fire-and-forget, the same shape as `onPersistLastOpenSnapshot` — a settings write that
    /// loses a race costs one relaunch its resume reminder, not its correctness.
    public var onPersistReminderEpisode: ((Tool, BlockEpisode.Limit, String?) -> Void)?

    /// Per-tool undetected flag — set by `applyUndetected`, cleared by any detected-state entry
    /// point. Drives `bothUndetected`, `detectedTools`, and the first-run card.
    private var undetected: [Tool: Bool] = [:]

    /// Forces an immediate re-poll of `tool` (first-run "Re-check" button). Injected by the
    /// composition root so the view layer stays coordinator-free (mirrors `onSelectMode`).
    public var onRecheck: ((Tool) -> Void)?

    /// Opens the History window (STEP_109). Injected by the composition root, which also closes
    /// the popover — the view layer stays window-free. A `nil` destination is the ordinary
    /// opening (Summary · All); a destination sends the reader to one provider's own local day
    /// (STEP_178).
    public var onOpenHistory: ((HistoryDestination?) -> Void)?

    /// Per-tool menu-bar slots; `nil` = undetected (no credentials AND no JSONL) — the tool
    /// renders nothing in any mode (§1.0).
    private var claudeMenu: ToolMenuBarDisplay?
    private var codexMenu: ToolMenuBarDisplay?
    /// The live long-limit warning episodes, one per tool per limit (REV-98 §2.3 — STEP_202).
    /// Absent = that limit is not in a warning tier, as far as the last **live** reading knows;
    /// a reading the app could not take holds whatever is here rather than clearing it.
    ///
    /// This replaces STEP_199's `reminderEnteredAt: [Tool: Date]`, which was cleared the moment
    /// the formatter stopped emitting reminders — so a relaunch, a stale poll and a genuine
    /// recovery-then-re-entry were the same event, and all three replayed the reminder from the
    /// top.
    private var reminderEpisodes: [Tool: [BlockEpisode.Limit: ReminderEpisode]] = [:]
    /// The one clock for both tools: sleeps to the next phase edge, republishes, repeats. Present
    /// only while something is reminding, so an ordinary green bar has no timer at all.
    private var reminderTask: Task<Void, Never>?
    /// Whether the reminder clock holds a task — the test seam for STEP_211's stop-on-its-own path.
    var isReminderClockRunning: Bool { reminderTask != nil }
    /// Injected so tests can drive the phase without sleeping through a real minute. The schedule
    /// itself is `MenuBarReminder`'s pure arithmetic; this is only *when* it is asked.
    var clock: () -> Date = Date.init
    /// Last classified state per tool — drives the §15.1 default-tab choice.
    private var lastState: [Tool: AppState] = [:]
    /// Most recent local JSONL activity per tool (from `LocalAttribution.lastActivityAt`) —
    /// the §15.1 default-tab middle tie-break input.
    private var lastLocalActivity: [Tool: Date] = [:]
    /// The tab the user last tapped this session — wins over the §15.1 urgency default on
    /// subsequent popover opens (A1). Nil until the first manual tap; cleared on a display-mode
    /// change. Session-scoped only (C1): not persisted, so it resets to the urgency default on
    /// relaunch.
    private var manualPick: Tool?
    /// Timestamp of the last *successful* poll per tool — the account-quota freshness `asOf`
    /// (UI Spec v4.7 §2.2a) and the `hasSucceeded` gate. Held through a `recordsPoll: false`
    /// re-apply so the quota stamp keeps aging while a JSONL delta refreshes the burn/local stamps.
    private var lastSuccessfulPollAt: [Tool: Date] = [:]
    /// The last inputs applied per tool, retained so the per-source freshness stamps can be
    /// re-rendered with a current `now` while the popover stays open (the age ticks muted → amber
    /// → stale-keep). Cleared when a tool drops to idle/undetected.
    private var lastRender: [Tool: LastRender] = [:]
    /// The monthly-layout payloads from the last *live* render, kept so the stale path can hold
    /// them (REV-47/D-42): the attribution split is a set of cumulative facts (monotone — the
    /// D-35 lower-bound logic), and the day grain is JSONL-anchored and unaffected by a stale
    /// account reading. Without this the cached render would drop the split rows and revert the
    /// local card to the 5-hour grain, both of which the layout has no window for. The trailing
    /// spend rate is deliberately *not* held — it answers "now", and stale means we do not know.
    private var lastMonthlyAttribution: [Tool: MonthlyAttribution] = [:]
    private var lastLocalDay: [Tool: LocalDayGrain] = [:]
    /// The daily local report per tool (STEP_177 — REV-92 / Baseline §15.2), held out of band
    /// like the two above: it is JSONL-derived and independent of any account reading, so a
    /// stale or failed poll must keep rendering it, and a refresh of it must not need a poll.
    /// Never cleared — local evidence outlives an idle or undetected account state.
    private var lastDailyReport: [Tool: DailyLocalReportState] = [:]

    public init(claudeState: ClaudeDisplayState, codexState: CodexDisplayState, activeTab: Tool = .claude) {
        self.claudeState = claudeState
        self.codexState = codexState
        self.activeTab = activeTab
        self.defaultTab = activeTab
        self.claudeMenu = DisplayFormatter.loadingMenuBar(.claude)
        self.codexMenu = DisplayFormatter.loadingMenuBar(.codex)
        self.menuBarRender = DisplayFormatter.menuBarRender(
            mode: .bothStacked,
            claude: DisplayFormatter.loadingMenuBar(.claude),
            codex: DisplayFormatter.loadingMenuBar(.codex))
    }

    /// Live app entry point — both tools start in the pre-first-poll loading state (Baseline §13.3):
    /// grey dot, `● CL … · CX …`, "Connecting…" cards.
    public convenience init() {
        self.init(claudeState: ClaudeDisplayState(dot: .grey, phase: .loading),
                  codexState: CodexDisplayState(dot: .grey, phase: .loading))
    }

    // MARK: Coordinator entry points

    /// Applies one successful poll for `tool`: maps engine output to the display state + menu-bar
    /// slot and records the poll time (which the footer measures staleness against).
    /// `recordsPoll: false` re-applies *cached* poll data after a JSONL-delta evaluation
    /// (STEP_26) — the display refreshes but the footer's poll-staleness clock must not.
    public func apply(tool: Tool, snapshot: QuotaSnapshot, forecast: Forecast,
                      state: AppState, localAttribution: LocalAttribution? = nil,
                      offMachine: WindowAttribution? = nil,
                      fastBurnDelta: Double? = nil,
                      moneyGlyph: MoneyGlyph = .none,
                      lastActiveWindow: DateInterval? = nil,
                      monthlyAttribution: MonthlyAttribution? = nil,
                      monthlyRatePerHour: Double? = nil,
                      localDay: LocalDayGrain? = nil,
                      now: Date = Date(), recordsPoll: Bool = true) {
        lastState[tool] = state
        setUndetected(tool, false)
        if recordsPoll { lastSuccessfulPollAt[tool] = now }
        if let activity = localAttribution?.lastActivityAt { lastLocalActivity[tool] = activity }
        // D-26 withdrawal on the bar (REV-80 / D-101): the same predicate `DisplayFormatter.claude`
        // applies to the popover, so a falsified not-started claim reads `——` on both surfaces.
        // The poll time is this apply's own stamp on a recording poll, else the last one's.
        let polledAt = recordsPoll ? now : lastSuccessfulPollAt[tool]
        let menuSnapshot = tool == .claude && DisplayFormatter.notStartedWithdrawn(
            snapshot: snapshot, polledAt: polledAt,
            lastActivityAt: localAttribution?.lastActivityAt)
            ? snapshot.withdrawingPrimaryWindow() : snapshot
        // §1.6 money glyph — the hysteresis-settled value from StateEngine (display-only, REV-29).
        // D-113 (STEP_172): no local-activity argument — the bar's runway slot reads the same
        // exhaustion decision the popover verdict does, so a quiet JSONL cannot hide it.
        let menu = DisplayFormatter.toolMenuBar(tool: tool, state: state, snapshot: menuSnapshot,
                                                forecast: forecast,
                                                glyph: moneyGlyph, now: now)
        if let monthlyAttribution { lastMonthlyAttribution[tool] = monthlyAttribution }
        // Assigned unconditionally, nil included (STEP_69): the grain now also expresses windowed
        // Codex's window-confidence fork, so a confirmed-window render must *clear* the hold —
        // otherwise a later stale card keeps a "today" title over rows anchored to the 5-hour
        // window. The monthly layout is unaffected: it always supplies a grain.
        lastLocalDay[tool] = localDay
        lastRender[tool] = .live(snapshot: snapshot, forecast: forecast, state: state,
                                 attribution: localAttribution, offMachine: offMachine,
                                 fastBurnDelta: fastBurnDelta, lastActiveWindow: lastActiveWindow,
                                 monthlyAttribution: monthlyAttribution,
                                 monthlyRatePerHour: monthlyRatePerHour, localDay: localDay)
        renderDisplay(tool: tool, now: now)
        switch tool {
        case .claude: claudeMenu = menu
        case .codex:  codexMenu = menu
        }
        rebuildMenuBar()
    }

    /// Applies one tool's daily local report (STEP_177) and re-renders whatever that tool is
    /// showing. Independent of the poll paths: the coordinator calls this after local ingestion,
    /// backfill, open, wake and the midnight boundary, and never through `apply`. A tool with no
    /// retained render keeps the report for the render that comes.
    public func applyDailyReport(tool: Tool, _ report: DailyLocalReportState, now: Date = Date()) {
        lastDailyReport[tool] = report
        renderDisplay(tool: tool, now: now)
    }

    /// The retained daily report for `tool`, for the coordinator's retain-on-failure rule.
    public func dailyReport(for tool: Tool) -> DailyLocalReportState? {
        lastDailyReport[tool]
    }

    /// Applies a *cached* snapshot with a stale marker (STEP_32, §9.3): once poll data ages past
    /// the TTL — or was restored from `poll_snapshots` at launch — the popover keeps showing the
    /// last-known account values with an "as of h:mm" source tag instead of wiping to the idle
    /// card. `state` is the StateEngine's classification of that cached snapshot (REV-33): a
    /// still-true hard block keeps its verdict, block banner, and red dot; every other stale
    /// state renders grey exactly as before. Classification is never invented here — the view
    /// model applies what the engine decided. Windows whose reset has passed degrade to the
    /// null-window presentation inside the formatter (REV-16/R33-7). Never records a successful
    /// poll; `asOf` is when the snapshot was actually polled (launch restore passes the
    /// persisted poll time). `freezeReason` (REV-37 — STEP_41) is the adapter's `AdapterHealth`
    /// when the stale render was applied — a `.rateLimited` freeze forks the null verdict to
    /// "Reconnecting…" rather than the idle "No active session"; nil on a launch restore.
    public func applyCached(tool: Tool, state: AppState, snapshot: QuotaSnapshot, asOf: Date,
                            localAttribution: LocalAttribution? = nil,
                            freezeReason: AdapterHealth? = nil, now: Date = Date()) {
        lastState[tool] = state
        setUndetected(tool, false)   // restored/cached data means the tool was detected
        if let activity = localAttribution?.lastActivityAt { lastLocalActivity[tool] = activity }
        // Same D-26 withdrawal as `apply` (REV-80 / D-101), keyed on the cached poll time.
        let menuSnapshot = tool == .claude && DisplayFormatter.notStartedWithdrawn(
            snapshot: snapshot, polledAt: asOf,
            lastActivityAt: localAttribution?.lastActivityAt, freezeReason: freezeReason)
            ? snapshot.withdrawingPrimaryWindow() : snapshot
        let menu = DisplayFormatter.staleMenuBar(tool: tool, state: state, snapshot: menuSnapshot,
                                                 now: now)
        lastRender[tool] = .cached(snapshot: snapshot, state: state,
                                   attribution: localAttribution, asOf: asOf,
                                   freezeReason: freezeReason)
        renderDisplay(tool: tool, now: now)
        switch tool {
        case .claude: claudeMenu = menu
        case .codex:  codexMenu = menu
        }
        rebuildMenuBar()
    }

    /// Applies the Idle/fallback state for `tool` — used on a first-poll timeout/failure with no
    /// prior success (Baseline §13.3), and by the §9.3 staleness path once cached state ages past
    /// the 10-min TTL (or its window reset behind our back) and is deliberately invalidated.
    /// Does *not* record a successful poll. A freshly-failed but still-fresh tool must freeze at
    /// its last-known state instead of calling this.
    public func applyUnavailable(tool: Tool, now: Date = Date()) {
        lastState[tool] = .idleFallback
        setUndetected(tool, false)   // "detected but idle" — not first-run
        lastRender[tool] = nil   // idle has no data to keep aging
        let menu = DisplayFormatter.toolMenuBar(tool: tool, state: .idleFallback,
                                                snapshot: nil, forecast: nil, now: now)
        switch tool {
        case .claude:
            claudeState = DisplayFormatter.claude(state: .idleFallback, snapshot: nil, forecast: nil, now: now)
            claudeMenu = menu
        case .codex:
            codexState = DisplayFormatter.codex(state: .idleFallback, snapshot: nil, forecast: nil, now: now)
            codexMenu = menu
        }
        rebuildMenuBar()
    }

    /// Marks `tool` undetected — no credentials AND no local JSONL activity observed (§1.0
    /// v4.6): the tool renders nothing in the menu bar (no bar, no dot, no text) and gets no
    /// popover tab (D-68); its first-run onboarding card (STEP_30) renders in the combined
    /// welcome or via the `Set up <tool>…` item — distinct from Idle/fallback (§13.3).
    /// Reversed automatically by the next successful `apply` (or `applyUnavailable`, which means
    /// "detected but idle").
    public func applyUndetected(tool: Tool, now: Date = Date()) {
        lastState[tool] = .idleFallback
        setUndetected(tool, true)
        lastRender[tool] = nil   // first-run has no data to age
        switch tool {
        case .claude:
            claudeState = ClaudeDisplayState(dot: .grey, phase: .firstRun)
            claudeMenu = nil
        case .codex:
            codexState = CodexDisplayState(dot: .grey, phase: .firstRun)
            codexMenu = nil
        }
        rebuildMenuBar()
    }

    /// Updates the per-tool undetected flag and recomputes `bothUndetected` / `detectedTools`.
    private func setUndetected(_ tool: Tool, _ value: Bool) {
        undetected[tool] = value
        bothUndetected = Tool.allCases.allSatisfy { undetected[$0] == true }
        detectedTools = Tool.allCases.filter { undetected[$0] != true }
        // D-68: the active tab must always be a rendered tab. When the detected set shrinks
        // away from under it, move to a surviving tool and drop a manual pick pointing at the
        // ghost — otherwise the remembered pick would resurrect a tab that no longer exists.
        if let pick = manualPick, undetected[pick] == true { manualPick = nil }
        if undetected[activeTab] == true, let fallback = detectedTools.first {
            activeTab = fallback
        }
    }

    /// First-run "Re-check" action — forces an immediate re-poll of `tool` via the injected
    /// coordinator seam. A no-op until the composition root wires `onRecheck`.
    public func recheck(_ tool: Tool) { onRecheck?(tool) }

    /// Popover footer `History…` action. A no-op until the composition root wires `onOpenHistory`.
    public func openHistory() { onOpenHistory?(nil) }

    /// `N more projects ›` — opens History on this tool's own local day, at the project
    /// breakdown. The day is the one the section is describing, taken from the report itself so
    /// the click and the numbers above it can never name different days; with no report yet it
    /// falls back to the current local day. Same rule as the report's own boundary arithmetic:
    /// calendar days, never `+ 86 400 s` (`LocalDayPolicy`).
    public func openProjectHistory(_ tool: Tool) {
        let day = lastDailyReport[tool]?.report?.dayStart
            ?? LocalDayPolicy.dayStart(now: Date(), calendar: .current)
        onOpenHistory?(.projects(provider: tool, day: day))
    }

    /// Right-click `Set up <tool>…` entry (D-68): the popover's next show renders `tool`'s setup
    /// card instead of the tabbed content. The caller shows the popover *without* running
    /// `selectDefaultTab` — that call is what ends the transient view on the next ordinary open.
    public func openSetup(_ tool: Tool) { transientSetupTool = tool }

    /// Applies the persisted / user-picked §1.0 display mode and re-renders the status item.
    public func setMenuBarDisplayMode(_ mode: MenuBarDisplayMode) {
        menuBarDisplayMode = mode
        // Switching to/from a single-tool mode (B1) invalidates the remembered tab pick (A1) so
        // the next open starts from a clean slate rather than stranding a stale selection.
        manualPick = nil
        rebuildMenuBar()
    }

    /// Whether `tool` has ever produced a successful poll — the coordinator uses this to decide
    /// between "drop to idle" (never succeeded) and "freeze last-known state" (§9.3) on a failure.
    public func hasSucceeded(_ tool: Tool) -> Bool { lastSuccessfulPollAt[tool] != nil }

    /// The per-tool menu-bar slot as the status item would render it — nil when the tool is
    /// undetected. Read by the first-run window (UI Spec Part 3 §3a, STEP_143) so screens 2 and 3
    /// show the *same* string as the live item, never a re-derivation.
    public func toolMenuBar(_ tool: Tool) -> ToolMenuBarDisplay? {
        switch tool {
        case .claude: return claudeMenu
        case .codex:  return codexMenu
        }
    }

    // MARK: Popover selection / footer

    /// Default-tab selection, re-evaluated on every popover open. Resolution order:
    /// - B1: a single-tool display mode (Claude-only / Codex-only) pins that tab, overriding both
    ///   the remembered pick and the urgency rule (the tab stays switchable within the session).
    /// - The §15.1 urgency rule computes the winner (`defaultTab`):
    ///   1. the more-urgent tool (lower `priorityRank`); 2. on a rank tie, the tool with the most
    ///   recent local JSONL activity (STEP_26); 3. both idle / unclassified → Claude.
    /// - A1: the user's remembered manual pick (`manualPick`) wins for the actually-shown tab when
    ///   present; otherwise the shown tab is the urgency winner.
    public func selectDefaultTab(now: Date = Date()) {
        chooseDefaultTab()
        // The chosen tab is being displayed — take its "since you last looked" snapshot
        // (STEP_112). One call site for every open, the notification-open included.
        noteTabDisplayed(activeTab, now: now)
    }

    private func chooseDefaultTab() {
        transientSetupTool = nil   // an ordinary open leaves the D-68 setup view
        // D-68 / Baseline §15.1: an undetected tool is never a candidate; with one candidate it
        // wins immediately — before the display-mode branch, so a pinned single-tool mode can
        // never select a tab that does not exist.
        if detectedTools.count == 1, let only = detectedTools.first {
            defaultTab = only
            activeTab = only
            return
        }
        switch menuBarDisplayMode {
        case .claudeOnly:
            activeTab = .claude
            defaultTab = .claude
            return
        case .codexOnly:
            activeTab = .codex
            defaultTab = .codex
            return
        default:
            break
        }
        let claudeRank = lastState[.claude]?.priorityRank ?? Int.max
        let codexRank = lastState[.codex]?.priorityRank ?? Int.max
        let urgencyDefault: Tool
        if codexRank == claudeRank {
            let claudeActivity = lastLocalActivity[.claude] ?? .distantPast
            let codexActivity = lastLocalActivity[.codex] ?? .distantPast
            urgencyDefault = codexActivity > claudeActivity ? .codex : .claude
        } else {
            urgencyDefault = codexRank < claudeRank ? .codex : .claude
        }
        defaultTab = urgencyDefault
        activeTab = manualPick ?? urgencyDefault
    }

    /// Records a user tab tap (A1) and switches to it. The remembered pick is honored by
    /// `selectDefaultTab` on the next open unless a single-tool display mode overrides it (B1).
    public func selectTab(_ tool: Tool, now: Date = Date()) {
        // A tap on the already-active tab is not a new look (STEP_112) — re-snapshotting would
        // swallow a line that just rendered. The pick still records.
        let switched = tool != activeTab
        activeTab = tool
        manualPick = tool
        if switched { noteTabDisplayed(tool, now: now) }
    }

    /// Re-renders both tools' display states against `now` so the per-source freshness stamps
    /// (UI Spec v4.7 §2.2a, D-21) keep aging while the popover stays open — muted → amber (≥ 2m) →
    /// stale-keep. Called on each open and by the menu-bar controller's tick timer; a no-op for
    /// tools with no retained render (idle/undetected/loading). The menu bar carries no freshness
    /// stamp, so it is not rebuilt here.
    public func refreshFreshness(now: Date = Date()) {
        for tool in Tool.allCases where lastRender[tool] != nil {
            renderDisplay(tool: tool, now: now)
        }
    }

    // MARK: Verdict anatomy (STEP_110)

    /// Click on line 1: pin `tool`'s anatomy, or release it if it is the one already pinned.
    /// A tool whose current verdict carries no anatomy is inert — the call is a no-op.
    public func togglePinnedAnatomy(_ tool: Tool) {
        if pinnedAnatomy == tool { pinnedAnatomy = nil; return }
        guard verdictFamilyHasAnatomy(tool) else { return }
        // One pinned thing at a time (§5.1): pinning the anatomy releases a pinned card.
        resetExplanationCards(stampSettle: false)
        pinnedAnatomy = tool
    }

    /// Release whatever is pinned — click-away, popover close, popover open (belt and braces).
    public func releasePinnedAnatomy() {
        if pinnedAnatomy != nil { pinnedAnatomy = nil }
    }

    /// Esc while the popover is key: returns `true` when it consumed the key by releasing a
    /// pinned card (STEP_111) or the pinned anatomy, `false` when nothing was pinned — the caller
    /// then lets the event through so a transient popover's own Esc-to-close keeps working.
    /// STEP_113 (coach mark) chains onto this.
    public func handleEscape() -> Bool {
        if pinnedCard != nil { releasePinnedCard(); return true }
        guard pinnedAnatomy != nil else { return false }
        pinnedAnatomy = nil
        return true
    }

    /// Release everything the explanation layer may have open — hover card (peek or pin) and the
    /// pinned anatomy — and re-arm the settle guard. Called by `MenuBarController` on popover
    /// show (every open starts clean) and close (nothing survives a close).
    public func releaseExplanationLayer() {
        releasePinnedAnatomy()
        resetExplanationCards()
    }

    private func verdictFamilyHasAnatomy(_ tool: Tool) -> Bool {
        switch tool {
        case .claude: return claudeState.header?.verdict?.anatomy != nil
        case .codex: return codexState.header?.verdict?.anatomy != nil
        }
    }

    private func releaseAnatomyOnFamilyChange(_ tool: Tool, _ family: VerdictFamily?) {
        let previous = lastVerdictFamily[tool]
        lastVerdictFamily[tool] = family
        guard previous != family, pinnedAnatomy == tool else { return }
        pinnedAnatomy = nil
    }

    // MARK: Accessors

    /// The display state for a given tab.
    public func state(for tool: Tool) -> AnyPopoverState {
        switch tool {
        case .claude: return .claude(claudeState)
        case .codex: return .codex(codexState)
        }
    }

    /// The status dot for a tab indicator (§15.1) without switching to it.
    public func dot(for tool: Tool) -> StatusDot {
        switch tool {
        case .claude: return claudeState.dot
        case .codex: return codexState.dot
        }
    }

    /// What the popover is presenting at this instant — the §17.1 `popover_opens` glance row's
    /// content (STEP_52). What-was-shown facts (§17 exception), read from the same inputs the
    /// render used — the state as classified for it, the snapshot through the shared
    /// `degradingExpiredWindows` exactly as `DisplayFormatter` applies it — never recomputed
    /// from fresh engine state. Nil fields = the tool was showing an unknown/loading
    /// presentation. Call after `selectDefaultTab()` so `tab` is the §15.1 outcome.
    public func glance(now: Date = Date()) -> PopoverGlance {
        PopoverGlance(tab: activeTab,
                      claudeState: lastState[.claude]?.rawValue,
                      claudeUsedPct: shownUtilization(for: .claude, now: now),
                      codexState: lastState[.codex]?.rawValue,
                      codexUsedPct: shownUtilization(for: .codex, now: now))
    }

    /// The primary utilization as the current render shows it — nil once a tool dropped to
    /// idle/undetected (`lastRender` cleared) or when the (degraded) window is null.
    func shownUtilization(for tool: Tool, now: Date) -> Double? {
        switch lastRender[tool] {
        case .live(let snapshot, _, _, _, _, _, _, _, _, _), .cached(let snapshot, _, _, _, _):
            return snapshot.degradingExpiredWindows(now: now).primaryUsedPct
        case nil:
            return nil
        }
    }

    /// The retained render inputs the "since you last looked" snapshot reads (STEP_112): the
    /// degraded snapshot, the local attribution, and whether the render is stale-kept. nil when
    /// the tool has no render (loading / idle / undetected) — nothing to snapshot then.
    func snapshotInputs(for tool: Tool, now: Date)
        -> (snapshot: QuotaSnapshot, attribution: LocalAttribution?, offMachinePct: Double?,
            stale: Bool)? {
        switch lastRender[tool] {
        case .live(let snapshot, _, _, let attribution, let offMachine, _, _, _, _, _):
            // The §2.4 row's number, on the same gate the row uses (`hasUsage`); nil otherwise.
            let off = offMachine.flatMap { $0.hasUsage ? $0.offMachinePct : nil }
            return (snapshot.degradingExpiredWindows(now: now), attribution, off, false)
        case .cached(let snapshot, _, let attribution, _, _):
            return (snapshot.degradingExpiredWindows(now: now), attribution, nil, true)
        case nil:
            return nil
        }
    }

    /// The rest of the retained render, for `explanation-snapshot.json`'s `inputs` block
    /// (STEP_133): the forecast and the monthly split, which `snapshotInputs` has no use for.
    /// Two accessors rather than one wider tuple — STEP_112 is `snapshotInputs`'s only caller and
    /// has no business growing fields it does not read. `lastRender` is file-scoped, so this must
    /// live here beside its sibling rather than in the snapshot extension.
    func explanationInputs(for tool: Tool)
        -> (forecast: Forecast?, attribution: LocalAttribution?, monthly: MonthlyAttribution?,
            monthlyRatePerHour: Double?)? {
        switch lastRender[tool] {
        case .live(_, let forecast, _, let attribution, _, _, _, let monthly, let rate, _):
            return (forecast, attribution, monthly, rate)
        case .cached(_, _, let attribution, _, _):
            // A stale render holds no forecast (it answers "now") and no fresh monthly rate; the
            // split it does hold is re-supplied by `lastMonthlyAttribution` at render time.
            return (nil, attribution, lastMonthlyAttribution[tool], nil)
        case nil:
            return nil
        }
    }

    // MARK: Private

    /// Rebuilds one tool's display state from its retained inputs against `now`, mapping the live /
    /// cached distinction onto the formatter's `pollAsOf` (quota freshness `asOf`) and `staleAsOf`.
    func renderDisplay(tool: Tool, now: Date) {
        guard let render = lastRender[tool] else { return }
        switch render {
        case let .live(snapshot, forecast, state, attribution, offMachine, fastBurnDelta,
                       lastActiveWindow, monthlyAttribution, monthlyRatePerHour, localDay):
            let pollAsOf = lastSuccessfulPollAt[tool]
            switch tool {
            case .claude:
                claudeState = DisplayFormatter.claude(
                    state: state, snapshot: snapshot, forecast: forecast,
                    localAttribution: attribution, offMachine: offMachine,
                    fastBurnDelta: fastBurnDelta, pollAsOf: pollAsOf,
                    lastActiveWindow: lastActiveWindow,
                    monthlyAttribution: monthlyAttribution,
                    monthlyRatePerHour: monthlyRatePerHour, localDay: localDay,
                    dailyReport: lastDailyReport[.claude], now: now)
            case .codex:
                codexState = DisplayFormatter.codex(
                    state: state, snapshot: snapshot, forecast: forecast,
                    localAttribution: attribution, offMachine: offMachine,
                    fastBurnDelta: fastBurnDelta, pollAsOf: pollAsOf,
                    lastActiveWindow: lastActiveWindow,
                    monthlyAttribution: monthlyAttribution,
                    monthlyRatePerHour: monthlyRatePerHour, localDay: localDay,
                    dailyReport: lastDailyReport[.codex], now: now)
            }
        case let .cached(snapshot, state, attribution, asOf, freezeReason):
            switch tool {
            case .claude:
                claudeState = DisplayFormatter.claude(
                    state: state, snapshot: snapshot, forecast: nil,
                    localAttribution: attribution, staleAsOf: asOf,
                    freezeReason: freezeReason,
                    monthlyAttribution: lastMonthlyAttribution[.claude],
                    monthlyRatePerHour: nil,
                    localDay: lastLocalDay[.claude],
                    dailyReport: lastDailyReport[.claude], now: now)
            case .codex:
                codexState = DisplayFormatter.codex(
                    state: state, snapshot: snapshot, forecast: nil,
                    localAttribution: attribution, staleAsOf: asOf,
                    freezeReason: freezeReason,
                    monthlyAttribution: lastMonthlyAttribution[.codex],
                    monthlyRatePerHour: nil,
                    localDay: lastLocalDay[.codex],
                    dailyReport: lastDailyReport[.codex], now: now)
            }
        }
    }

    // MARK: The reminder schedule (REV-97 §2.1 — STEP_199; the episode, REV-98 §2.3 — STEP_202)

    private func rebuildMenuBar() {
        syncReminderEpisodes()
        publishMenuBar(phasedRender(now: clock()))
        syncReminderClock()
    }

    /// Recomputes which phase each reminding row is in and republishes only if something moved.
    /// The one entry point the clock calls, and the seam the schedule tests drive directly — two
    /// publishes per reminder per reminding tool, none at all otherwise.
    func advanceReminderPhase(now: Date? = nil) {
        publishMenuBar(phasedRender(now: now ?? clock()))
    }

    /// The one write to `menuBarRender`, so a phase edge and a poll cannot publish by different
    /// rules.
    ///
    /// The DEBUG line fires only while some row can remind — twice per reminder then, none on an
    /// ordinary calm bar. It is how the dogfood week judges the REV-98 §2.2 cadence, which is a
    /// set of proposals rather than replayed numbers, and it is what caught the timer leeway that
    /// clipped every reminder after the first (STEP_199). At the decayed cadence it is also the
    /// only way to tell a quiet bar from a dead clock across an hour-long gap. Strings only, no
    /// account data: every one of them is already on the menu bar.
    private func publishMenuBar(_ render: MenuBarRender) {
        guard render != menuBarRender else { return }
        let cycles = render.lines.contains { !$0.reminders.isEmpty }
        menuBarRender = render
        guard cycles else { return }
        Logger.debug("Menu-bar phase · " + render.lines.map {
            "\($0.reminderIndex.map { i in "reminder\(i)" } ?? "steady")=\($0.text)"
        }.joined(separator: " "), component: .appLifecycle)
    }

    /// The §1.0 matrix with each reminding row's phase turned on. The formatter says what the bar
    /// *can* show and never picks a phase (STEP_198); this is the other half.
    private func phasedRender(now: Date) -> MenuBarRender {
        var render = DisplayFormatter.menuBarRender(mode: menuBarDisplayMode,
                                                    claude: menuDisplay(.claude),
                                                    codex: menuDisplay(.codex))
        for (index, tool) in renderedTools.enumerated() {
            guard let episode = schedulingEpisode(tool),
                  let count = menuDisplay(tool)?.reminders.count,
                  let phase = MenuBarReminder.phase(episode: episode, now: now,
                                                    reminderCount: count) else { continue }
            render = render.showingReminder(phase, on: index)
        }
        return render
    }

    /// The episode the tool's cycle runs on: the **worst limit the bar actually reminds about**.
    ///
    /// The formatter has already ranked the statuses worst-first and already decided every §2.1
    /// and §2.4 gate, so nothing here re-tests a rank — the lead reminder's limit supplies the
    /// tier the cadence table reads and the `tierAt` it is measured from. A second elevated limit
    /// still alternates into the cycle; at the decayed cadence its turn may be an hour or two
    /// away, which REV-98 §5 item 8 records and accepts because both dots are visible throughout.
    private func schedulingEpisode(_ tool: Tool) -> ReminderEpisode? {
        guard let lead = menuDisplay(tool)?.longLimits.statuses
            .first(where: { $0.reminderText != nil }) else { return nil }
        return reminderEpisodes[tool]?[lead.limit]
    }

    /// The §2.3 lifecycle, applied to whatever the last render knows.
    ///
    /// **A reading the app could not take changes nothing.** `.unknown` — loading, idle, a null
    /// window, a monthly-hero layout, every stale render — holds both clocks, the tier and the
    /// episode itself. Motion stops because there is no reminder to show, and the dot keeps its
    /// colour; on return the same episode resumes on the same schedule, with no replay and no
    /// catch-up.
    private func syncReminderEpisodes() {
        for tool in Tool.allCases {
            guard case let .live(statuses) = menuDisplay(tool)?.longLimits ?? .unknown else {
                continue
            }
            let now = clock()
            var live = reminderEpisodes[tool] ?? [:]

            // Confirmed recovery: a limit the live reading no longer calls elevated. Recovery is
            // the **tier** clearing, not the percentage falling — a week catching up with its own
            // usage clears at unchanged utilization.
            for limit in Array(live.keys) where !statuses.contains(where: { $0.limit == limit }) {
                live[limit] = nil
                persistEpisode(tool: tool, limit: limit, value: nil)
            }

            for status in statuses {
                guard var episode = live[status.limit],
                      episode.matches(resetsAt: status.resetsAt) else {
                    // A new instance, or the first time this limit has warned. Both clocks at
                    // zero and the full first-hour cadence.
                    let fresh = ReminderEpisode(tool: tool, limit: status.limit, tier: status.tier,
                                                enteredAt: now, tierAt: now,
                                                resetsAt: status.resetsAt)
                    live[status.limit] = fresh
                    persistEpisode(tool: tool, limit: status.limit, value: fresh.storedValue)
                    continue
                }
                var changed = false
                if episode.awaitingResume {
                    // The relaunch reminder (§2.3): one immediately, now that a live reading has
                    // confirmed the tier, then the decayed cadence at the episode's true age.
                    // Not the first-hour burst — the reader has been away, not newly warned.
                    episode.awaitingResume = false
                    episode.resumedAt = now
                    changed = true
                }
                if episode.tier != status.tier {
                    // `enteredAt` is kept and `tierAt` moves **only on escalation**, which starts
                    // the new tier's first hour with an immediate reminder. A de-escalation
                    // inside the warning band takes the quieter cadence on the same clock: a
                    // limit that gets less serious must not get louder.
                    if status.tier > episode.tier { episode.tierAt = now }
                    episode.tier = status.tier
                    changed = true
                }
                if changed {
                    live[status.limit] = episode
                    persistEpisode(tool: tool, limit: status.limit, value: episode.storedValue)
                }
            }
            reminderEpisodes[tool] = live
        }
    }

    /// Restores one episode from `settings` at launch (REV-98 §2.3 — STEP_202). Mirrors
    /// `seedLastOpenSnapshot`: the composition root reads the row, this decides what it means.
    ///
    /// Three cases, and the middle one is why the seed can arrive late without harm. **Nothing
    /// tracked and no live reading yet** — the ordinary launch — installs the episode awaiting
    /// resume, so it reminds once when the first poll confirms the tier. **Something tracked for
    /// the same instance** means a poll beat the read and opened a fresh episode; the stored
    /// clocks are older and truer, so they win, and the resume is stamped at once because the
    /// tier is already confirmed. **A live reading that does not name this limit** means it
    /// recovered while the app was closed: drop the row.
    public func seedReminderEpisode(tool: Tool, limit: BlockEpisode.Limit, storedValue: String) {
        guard var restored = ReminderEpisode.restored(tool: tool, limit: limit,
                                                      storedValue: storedValue) else {
            persistEpisode(tool: tool, limit: limit, value: nil)
            return
        }
        let reading = menuDisplay(tool)?.longLimits ?? .unknown
        if case let .live(statuses) = reading {
            guard let status = statuses.first(where: { $0.limit == limit }),
                  restored.matches(resetsAt: status.resetsAt) else {
                persistEpisode(tool: tool, limit: limit, value: nil)
                return
            }
            restored.tier = status.tier
            restored.awaitingResume = false
            restored.resumedAt = clock()
            // A poll that beat the read has already written this run's younger clocks over the
            // stored ones; put the true ones back, or the *next* relaunch inherits launch time.
            persistEpisode(tool: tool, limit: limit, value: restored.storedValue)
        } else if reminderEpisodes[tool]?[limit] != nil {
            // Held reading with something already tracked: the tracked one was created by this
            // run and is younger. Nothing to reconcile against, so the stored clocks stand.
            restored.awaitingResume = true
        }
        reminderEpisodes[tool, default: [:]][limit] = restored
        rebuildMenuBar()
    }

    /// The reader opened the popover or the quota window: every live **amber** episode on both
    /// tools is acknowledged, and reminds no more (REV-100 §2.2 — STEP_211).
    ///
    /// Both tools from one look, because the normal user has one account and opens one popover.
    /// Nothing is republished: a reminder on screen at this instant ends at its own edge through
    /// the ordinary crossfade, and the dot keeps its colour. An episode still awaiting its resume
    /// is acknowledged too — the reader looked before the first poll confirmed it, and owes no
    /// reminder when it does. Red episodes are left alone; red does not remind.
    public func acknowledgeReminders(now: Date? = nil) {
        let now = now ?? clock()
        var acknowledged: [String] = []
        for tool in Tool.allCases {
            guard var live = reminderEpisodes[tool] else { continue }
            for (limit, episode) in live
            where episode.tier <= .aheadOfPace && episode.acknowledgedAt == nil {
                var stamped = episode
                stamped.acknowledgedAt = now
                live[limit] = stamped
                persistEpisode(tool: tool, limit: limit, value: stamped.storedValue)
                acknowledged.append("\(tool.rawValue).\(limit.rawValue)")
            }
            reminderEpisodes[tool] = live
        }
        guard !acknowledged.isEmpty else { return }
        Logger.debug("Menu-bar reminders acknowledged · " + acknowledged.sorted().joined(separator: " "),
                     component: .appLifecycle)
        syncReminderClock()
    }

    /// The one write to a `reminder_episode` row — and the one place the debug fixture override
    /// is kept out of the real database.
    ///
    /// `KVOTAR_MENU_BAR_FIXTURE` is read once, never persisted and never surfaced (STEP_199), and
    /// a forced frame driving an episode row into `settings` would break all three at once: the
    /// owner's account has never reached the red tier, so watching red on the live bar would
    /// leave a fabricated red episode behind for the next launch to restore. The other tool's
    /// rows are untouched — only the forced one is silent.
    private func persistEpisode(tool: Tool, limit: BlockEpisode.Limit, value: String?) {
        guard Self.menuBarFixture?.tool != tool else { return }
        onPersistReminderEpisode?(tool, limit, value)
    }

    /// One task for both tools, started on the first entry and cancelled when nothing has an edge
    /// left — the last tool left its tier, or every remaining episode is acknowledged.
    private func syncReminderClock() {
        let now = clock()
        if renderedTools.contains(where: {
            schedulingEpisode($0).flatMap { MenuBarReminder.nextEdge(episode: $0, now: now) } != nil
        }) {
            guard reminderTask == nil else { return }
            reminderTask = Task { [weak self] in await self?.runReminderClock() }
        } else {
            reminderTask?.cancel()
            reminderTask = nil
        }
    }

    /// Sleep to the nearest phase edge across the reminding tools, republish, repeat.
    ///
    /// Every iteration recomputes the edge from the wall clock rather than counting ticks, so a
    /// machine that slept through a boundary is one late tick behind, not permanently out of
    /// phase.
    ///
    /// **The tolerance is the whole trick.** `Task.sleep(nanoseconds:)` lets the system coalesce a
    /// long wait with whatever else it is waking for, and the leeway scales with the wait: on the
    /// live bar a 55-second sleep landed about three seconds late while the five-second one that
    /// ended the reminder landed on time, so every reminder after the first was clipped to under
    /// two seconds (measured 2026-09-14, `docs/evidence/STEP_199`). A 50 ms tolerance costs one
    /// accurate wake-up a minute, and only while something is reminding.
    private func runReminderClock() async {
        while !Task.isCancelled {
            let now = clock()
            let edges = renderedTools.compactMap { schedulingEpisode($0) }
                .compactMap { MenuBarReminder.nextEdge(episode: $0, now: now) }
            guard let next = edges.min() else {
                // Reachable since STEP_211: an acknowledged reminder ends and nothing follows it.
                // Uncancelled, so the task is still this one — clear it, or the next episode
                // finds a finished task in the slot and never gets a clock.
                reminderTask = nil
                return stopped("nothing to tick")
            }
            let delay = max(next.timeIntervalSince(now), 0.05)
            do {
                try await Task.sleep(until: .now.advanced(by: .milliseconds(Int(delay * 1_000))),
                                     tolerance: .milliseconds(50), clock: .continuous)
            } catch {
                return stopped("sleep interrupted")
            }
            guard !Task.isCancelled else { return stopped("cancelled") }
            advanceReminderPhase()
        }
        stopped("cancelled")
    }

    /// Why the cycle ended. One DEBUG line, and worth its keep: a clock that dies quietly looks
    /// exactly like a bar that has nothing to remind about, which is how STEP_199 spent an hour
    /// reading screenshots before it read a log.
    private func stopped(_ reason: String) {
        Logger.debug("Menu-bar reminder clock stopped · \(reason)", component: .appLifecycle)
    }

    /// The tools the current mode draws, in the order their rows appear — the same rule
    /// `DisplayFormatter.menuBarRender` uses, so a phase index can never land on the wrong row.
    private var renderedTools: [Tool] {
        switch menuBarDisplayMode {
        case .bothStacked: return Tool.allCases.filter { menuDisplay($0) != nil }
        case .claudeOnly:  return menuDisplay(.claude) == nil ? [] : [.claude]
        case .codexOnly:   return menuDisplay(.codex) == nil ? [] : [.codex]
        }
    }

    /// The slot the status item renders for `tool` — the live one, or the forced fixture.
    private func menuDisplay(_ tool: Tool) -> ToolMenuBarDisplay? {
        if let fixture = Self.menuBarFixture, fixture.tool == tool { return fixture.menuBar }
        return tool == .claude ? claudeMenu : codexMenu
    }

    /// Diagnostics only: forces one `LongLimitFixture` onto the live status item so the amber and
    /// red phases can be watched on a real menu bar. Read once, never persisted, never surfaced —
    /// there is no fixture setting (the `KVOTAR_MAX_POPOVER_HEIGHT` precedent). The owner's own
    /// account has never reached the nearly-spent line, so without this the shipped colour and
    /// pulse could only ever be looked at in a PNG.
    static let menuBarFixture: LongLimitFixture? = {
        guard let name = ProcessInfo.processInfo.environment["KVOTAR_MENU_BAR_FIXTURE"],
              !name.isEmpty else { return nil }
        return LongLimitFixture.named(name)
    }()
}

/// The last inputs applied for a tool, retained so the per-source freshness stamps can be
/// re-rendered with a current `now` while the popover stays open (§2.2a age ticking).
private enum LastRender {
    case live(snapshot: QuotaSnapshot, forecast: Forecast, state: AppState,
              attribution: LocalAttribution?, offMachine: WindowAttribution?, fastBurnDelta: Double?,
              // Idle "last window" retrospective span (REV-46 — STEP_64); nil except on a fresh
              // null 5-hour window with a prior window on record. Retained so a freshness-tick
              // re-render keeps the retrospective anchor.
              lastActiveWindow: DateInterval?,
              // Monthly attribution split + trailing rate + local-day grain (REV-47 — STEP_65;
              // REV-48 — STEP_67); nil except on a monthly layout, either tool. The Claude
              // formatter consumes them (STEP_66); the Codex one accepts and ignores until STEP_68.
              monthlyAttribution: MonthlyAttribution?, monthlyRatePerHour: Double?,
              localDay: LocalDayGrain?)
    // `freezeReason` (REV-37 — STEP_41) is the adapter's `AdapterHealth` at the moment the stale
    // render was applied; the formatter forks the null-window verdict on it (a `.rateLimited`
    // freeze reads "Reconnecting…", not the idle "No active session"). nil on a launch restore.
    case cached(snapshot: QuotaSnapshot, state: AppState, attribution: LocalAttribution?,
                asOf: Date, freezeReason: AdapterHealth?)
}

/// One popover open's what-was-shown facts (§17.1 `popover_opens`, STEP_52) — the presented
/// tab plus both tools' state string and primary utilization exactly as rendered.
public struct PopoverGlance: Sendable, Equatable {
    public let tab: Tool
    public let claudeState: String?
    public let claudeUsedPct: Double?
    public let codexState: String?
    public let codexUsedPct: Double?
}

/// Type-erased per-tool state so the tab container can render either tool uniformly.
public enum AnyPopoverState {
    case claude(ClaudeDisplayState)
    case codex(CodexDisplayState)
}
