import Foundation
import Combine
import KvotarCore

/// `@MainActor` bridge for the History window (STEP_109), the same shape `AppViewModel` is for the
/// popover: it owns the published render model and nothing else. The report is computed by an
/// injected async closure (the composition root points it at `AttributionEngine.historyReport`),
/// so the UI package stays store-free and previews can hand it a canned report.
///
/// `reload()` is what the window calls on open and on every focus. Nothing here waits for the
/// launch backfill sweep — the window shows whatever the corpus holds right now, and the next
/// reload picks up what the sweep has landed since.
@MainActor
public final class HistoryViewModel: ObservableObject {
    @Published public private(set) var experience: HistoryExperience?
    @Published public private(set) var isLoading = false

    // MARK: Mode / provider / day selection (STEP_160 — REV-84 §2)
    //
    // Transient presentation state over precomputed content: all nine payloads are already in
    // `experience`, so changing a control reads memory and never the database. Nothing here is
    // persisted (Pre-Alpha). Owned by the one view model — the task rules out per-mode models —
    // so `prepareForOpen()` can reset the window without the views knowing.

    /// The primary mode control. `Weekly recap` on every ordinary open (`prepareForOpen`).
    @Published public var mode: HistoryExperience.Mode = .weeklyRecap {
        didSet { if mode != oldValue { selectedQuotaPoint = nil } }
    }

    /// The provider filter, **one per evidence mode** (UI Spec §6.0): choosing Codex while
    /// investigating a block must not silently re-scope Explore usage when the reader goes back
    /// to it. Weekly recap keeps an entry too — it is never read, because the recap is
    /// cross-provider by contract and its payload hangs off the root.
    @Published private var providerByMode: [HistoryExperience.Mode: HistoryExperience.Provider] = [:]

    /// The current mode's provider. Switching it clears the day and point selections: identities
    /// are shared across pages, but the newly shown page's own default is the honest one — a day
    /// the old provider was busy on may be empty on the new one.
    public var provider: HistoryExperience.Provider {
        get { providerByMode[mode] ?? .all }
        set {
            guard newValue != provider else { return }
            providerByMode[mode] = newValue
            selectedDay = nil
            selectedQuotaPoint = nil
        }
    }
    /// Explore's selected day — `nil` means "the page's `initialSelection`". Kept as a raw
    /// `Date` id rather than a resolved entry so a reload with fresh content cannot strand a
    /// stale object; `selectedEntry(in:)` re-resolves against whatever page is current.
    @Published public private(set) var selectedDay: Date?

    /// A day column was clicked or reached by arrow key. Selection updates only the detail —
    /// deliberately no hover release and no scroll: the strip the pointer is on does not move.
    public func selectDay(_ id: Date) {
        selectedDay = id
    }

    /// A day the window was *sent* to and has not resolved yet (STEP_178). The experience loads
    /// asynchronously, so a destination cannot be turned into a selection at `show()` time; it is
    /// held here and matched on the first page that can answer it. Held as the concrete date the
    /// reader clicked, so a midnight rollover between the click and the load cannot move it.
    private var pendingDay: Date?
    /// The calendar the pending day is matched with — the same one the popover's day boundary
    /// used. Injected so a test can pin a zone.
    private var calendar: Calendar = .current

    /// Every ordinary open starts the same way (REV-93 §2.1): Weekly recap, All, the model's own
    /// day selection, no card. Called by the window controller's `show()` — and not by
    /// `windowDidBecomeKey`, so re-focusing an open window keeps the reader's place.
    ///
    /// With a `destination` the open is explicit instead: the mode the destination names, its
    /// provider, and — for the popover's projects hand-off — that local day. `provider` is set
    /// **before** the day because its `didSet` clears the selection, and the day is held pending
    /// until a page exists to resolve it against.
    public func prepareForOpen(destination: HistoryDestination? = nil,
                               calendar: Calendar = .current) {
        self.calendar = calendar
        providerByMode = [:]
        recapWeekIndex = 0
        scope = nil
        selectedQuotaPoint = nil
        mode = destination?.mode ?? .weeklyRecap
        provider = destination?.provider.map { .tool($0) } ?? .all
        selectedDay = nil
        pendingDay = destination?.day
        applyScope(of: destination, returningTo: nil)
        releaseDayPeek()
    }

    // MARK: Evidence links and the scope banner (STEP_183 — UI Spec §6.2 / §6.3)
    //
    // Until this step a destination's week, focus and banner were built by the display model and
    // consumed by nothing: `prepareForOpen` read the mode, the provider and the day, and a recap
    // link was inert text. `navigate(to:)` is the in-window counterpart — the same application of
    // a destination, plus the banner that says where the reader came from and the way back.

    /// A destination the reader followed from inside the window, and what it narrowed to.
    public struct Scope: Sendable, Equatable {
        /// `From weekly recap · Claude · Sep 1 – Sep 7` — built beside the destination it
        /// describes, never assembled here.
        public let banner: String
        /// The completed week, `[start, end)`, where the destination named one.
        public let weekStart: Date?
        public let weekEnd: Date?
        /// The recap week to return to, so `Back to weekly recap` lands where the reader left.
        public let returnToRecapWeek: Date?

        public init(banner: String, weekStart: Date? = nil, weekEnd: Date? = nil,
                    returnToRecapWeek: Date? = nil) {
            self.banner = banner
            self.weekStart = weekStart
            self.weekEnd = weekEnd
            self.returnToRecapWeek = returnToRecapWeek
        }

        /// Whether an instant belongs to the scoped week. False when the scope names no week —
        /// a quota block link carries a banner and no span.
        public func contains(_ date: Date?) -> Bool {
            guard let date, let weekStart, let weekEnd else { return false }
            return date >= weekStart && date < weekEnd
        }

        public var hasWeek: Bool { weekStart != nil && weekEnd != nil }
    }

    @Published public private(set) var scope: Scope?

    /// Follow an evidence link without reopening the window. The recap week the reader was on is
    /// remembered so `Back to weekly recap` returns to the same one.
    public func navigate(to destination: HistoryDestination) {
        let returnWeek = mode == .weeklyRecap
            ? currentRecapWeek?.id
            : scope?.returnToRecapWeek
        mode = destination.mode
        provider = destination.provider.map { .tool($0) } ?? .all
        selectedDay = nil
        selectedQuotaPoint = nil
        pendingDay = destination.day
        applyScope(of: destination, returningTo: returnWeek)
        releaseDayPeek()
    }

    private func applyScope(of destination: HistoryDestination?, returningTo week: Date?) {
        guard let destination, let banner = destination.banner else {
            scope = nil
            return
        }
        scope = Scope(banner: banner, weekStart: destination.week?.start,
                      weekEnd: destination.week?.end, returnToRecapWeek: week)
    }

    /// The banner's `Clear`: the mode returns to its full 30 days, keeping the provider the
    /// reader arrived under (§6.3).
    public func clearScope() {
        guard scope != nil else { return }
        scope = nil
        selectedQuotaPoint = nil
    }

    /// The banner's `Back to weekly recap`, positioned on the week the link came from.
    public func backToWeeklyRecap() {
        let target = scope?.returnToRecapWeek
        scope = nil
        selectedQuotaPoint = nil
        mode = .weeklyRecap
        if let target, let index = experience?.recap.weeks.firstIndex(where: { $0.id == target }) {
            recapWeekIndex = index
        }
        releaseDayPeek()
    }

    // MARK: Weekly recap navigation (UI Spec §6.2)
    //
    // One completed week at a time, newest first. The index is transient like every other control
    // on this window, and it is clamped at read time rather than trusted: a reload can return
    // fewer weeks than the reader had walked back to.

    @Published public private(set) var recapWeekIndex = 0

    /// The week currently shown, or nil when the horizon holds no completed week.
    public var currentRecapWeek: HistoryExperience.RecapWeek? {
        recapWeek(in: experience?.recap)
    }

    public func recapWeek(in section: HistoryExperience.RecapSection?)
        -> HistoryExperience.RecapWeek? {
        guard let weeks = section?.weeks, !weeks.isEmpty else { return nil }
        return weeks[min(max(recapWeekIndex, 0), weeks.count - 1)]
    }

    /// `weeks` is newest first, so older is a step **forward** through the array.
    public func canShowOlderRecapWeek(in section: HistoryExperience.RecapSection?) -> Bool {
        recapWeekIndex + 1 < (section?.weeks.count ?? 0)
    }

    public func canShowNewerRecapWeek(in section: HistoryExperience.RecapSection?) -> Bool {
        recapWeekIndex > 0 && !(section?.weeks.isEmpty ?? true)
    }

    public func showOlderRecapWeek() {
        guard canShowOlderRecapWeek(in: experience?.recap) else { return }
        recapWeekIndex += 1
    }

    public func showNewerRecapWeek() {
        guard canShowNewerRecapWeek(in: experience?.recap) else { return }
        recapWeekIndex -= 1
    }

    // MARK: Explore quota point selection (UI Spec §6.3)
    //
    // Click or keyboard, never hover alone. The id is `QuotaWindowOutcome.id`, stable across
    // reloads, so a pinned point survives one — and `resolvedQuotaPoint(in:)` drops it silently
    // when a reload no longer holds it.

    @Published public private(set) var selectedQuotaPoint: String?

    public func selectQuotaPoint(_ id: String) {
        selectedQuotaPoint = id
    }

    /// The pinned point for a page: the reader's own selection where the page still has it, else
    /// the first point of a scoped week, else nothing pinned.
    public func resolvedQuotaPoint(in page: HistoryExperience.QuotaPage)
        -> HistoryExperience.QuotaPoint? {
        let points = page.sections.flatMap(\.points)
        if let selectedQuotaPoint,
           let match = points.first(where: { $0.id == selectedQuotaPoint }) {
            return match
        }
        guard let scope, scope.hasWeek else { return nil }
        return points.first { scope.contains($0.at) }
    }

    /// The typed detail for the current selection on a page: the selected day if that page has
    /// it, else the page's initial selection. Pure lookup — the detail was precomputed.
    ///
    /// A pending destination is resolved here, by **local calendar day** rather than by instant:
    /// History's oldest column starts at the report's period start, not at midnight, so an
    /// equality test would silently fall back to the default selection. A day the page does not
    /// have falls back the same way it always did.
    public func selectedEntry(in page: HistoryExperience.ExplorePage)
        -> HistoryExperience.DayEntry? {
        if let pendingDay, selectedDay == nil,
           let match = page.days.first(where: { calendar.isDate($0.id, inSameDayAs: pendingDay) }) {
            return match
        }
        // A week-scoped arrival lands on the newest day of that week the provider worked on,
        // falling back to the newest day of the week at all (STEP_183). The page itself is still
        // the whole 30 days — the scope moves the reader's attention, not the population.
        if selectedDay == nil, let scope, scope.hasWeek {
            let inWeek = page.days.filter { scope.contains($0.id) }
            if let match = inWeek.last(where: { !$0.point.bars.isEmpty }) ?? inWeek.last {
                return match
            }
        }
        let target = selectedDay ?? page.initialSelection
        return page.days.first { $0.id == target }
            ?? page.days.first { $0.id == page.initialSelection }
    }

    /// Whether the window is still waiting to place an explicit destination. Read by the Explore
    /// view so it can commit the resolved day to `selectedDay` once, on first appearance.
    public var hasPendingDay: Bool { pendingDay != nil && selectedDay == nil }

    /// Commits a resolved pending destination, so later reloads behave like any hand selection.
    public func commitPendingDay(_ id: Date) {
        guard pendingDay != nil else { return }
        pendingDay = nil
        selectedDay = id
    }

    // MARK: Day-strip hover (STEP_116)
    //
    // The popover's explanation layer cannot be reused as-is: `.explainable` and
    // `ExplanationCardOverlay` both read an `AppViewModel` out of the environment, and this window
    // deliberately has none. So the *grammar* is reused — `ExplanationCardView` and
    // `hoverCardChrome()`, the same 350/120 ms timings, the same 6-pt-below-flipping-above
    // placement — and the state lives here. **Peek only, no pin**: a day is data, not a registry
    // element, so there is nothing to keep open and read.

    /// Which chart a column belongs to. Two charts on one page share this state machine and the
    /// single overlay it drives (STEP_120), so the identifier has to say which strip a column
    /// index counts across — bare integers would have day 14 and 2 pm addressing the same card.
    public enum HoverColumn: Sendable, Hashable {
        case day(Int)
        case hour(Int)
    }

    /// The column the pointer is resting on.
    @Published public private(set) var hoveredDay: HoverColumn?
    /// The column whose card is showing (pointer rested ≥ `hoverPeekDelay`).
    @Published public private(set) var peekedDay: HoverColumn?
    private var dayTimer: Task<Void, Never>?
    /// UI Spec Part 1 §5 tuning — the shared `ExplanationTiming` (STEP_132), so the day strip and
    /// the popover's cards cannot drift apart. Instance values so tests can shrink them.
    ///
    /// The **values** are shared; the popover's no-instant-swap rule (D-91) is not. A bar chart is
    /// a comparison surface — sliding along it is the gesture, and the swap below is what makes
    /// that read — where a list of rows is a reading surface and sliding is only travel.
    public var hoverPeekDelay: Duration = ExplanationTiming.peekDelay
    public var hoverGraceLeave: Duration = ExplanationTiming.graceLeave

    private let load: () async -> HistoryReport?
    private var inFlight: Task<Void, Never>?

    public init(load: @escaping () async -> HistoryReport?) {
        self.load = load
    }

    /// Preview / test seam: a fully-formed experience, no loader.
    public init(experience: HistoryExperience) {
        self.load = { nil }
        self.experience = experience
    }

    /// Recomputes the report and re-renders. Coalesces: a reload requested while one is running
    /// is dropped, since the running one will read the same rows.
    public func reload(now: Date = Date()) {
        guard inFlight == nil else { return }
        isLoading = true
        inFlight = Task { [weak self] in
            let report = await self?.load()
            guard let self else { return }
            // A nil report keeps the previous experience — loading never blanks the window.
            if let report {
                self.experience = HistoryDisplay.experience(report, now: now,
                                                            calendar: self.calendar)
                // A reload can return fewer completed weeks than the reader had walked back to.
                let weeks = self.experience?.recap.weeks.count ?? 0
                self.recapWeekIndex = min(self.recapWeekIndex, max(weeks - 1, 0))
            }
            self.isLoading = false
            self.inFlight = nil
        }
    }

    /// Pointer entered (`hovering == true`) or left a day column.
    public func dayHover(_ column: Int, hovering: Bool) {
        hover(.day(column), hovering: hovering)
    }

    /// The same, for an hour-of-day column. One timer and one card for both charts: a pointer
    /// moving from one to the other should not leave two cards up.
    public func hourHover(_ column: Int, hovering: Bool) {
        hover(.hour(column), hovering: hovering)
    }

    private func hover(_ column: HoverColumn, hovering: Bool) {
        if hovering {
            hoveredDay = column
            dayTimer?.cancel()
            if peekedDay != nil {
                // Sliding along the strip: swap without paying the delay again.
                peekedDay = column
                return
            }
            dayTimer = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.hoverPeekDelay)
                guard !Task.isCancelled, self.hoveredDay == column else { return }
                self.peekedDay = column
            }
        } else {
            if hoveredDay == column { hoveredDay = nil }
            dayTimer?.cancel()
            guard peekedDay != nil else { return }
            dayTimer = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.hoverGraceLeave)
                guard !Task.isCancelled, self.hoveredDay == nil else { return }
                self.peekedDay = nil
            }
        }
    }

    /// Drop the card at once — Esc, a tab switch, a reload.
    public func releaseDayPeek() {
        dayTimer?.cancel()
        dayTimer = nil
        if hoveredDay != nil { hoveredDay = nil }
        if peekedDay != nil { peekedDay = nil }
    }
}
