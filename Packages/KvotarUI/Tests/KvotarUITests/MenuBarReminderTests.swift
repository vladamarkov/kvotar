import XCTest
import KvotarCore
@testable import KvotarUI

/// The reminder cycle, its boundaries, and what holds (UI Spec §1.3 / §5, REV-97 §2.1–§2.5,
/// REV-98 §2.2–§2.3, REV-100 §2.2, Baseline §19 — STEP_198, STEP_202, STEP_211).
///
/// The schedule is pure arithmetic on purpose: the alternative to this file is watching a real
/// menu bar for an hour and trusting your eyes about a 100-millisecond boundary — and since
/// REV-98 the cycle is four days long, so the alternative is not an alternative at all.
final class MenuBarReminderTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_789_000_000)

    private func episode(_ tier: LongLimitAssessment.Tier = .aheadOfPace,
                         tierAt: TimeInterval = 0,
                         resumedAt: TimeInterval? = nil,
                         awaitingResume: Bool = false,
                         acknowledgedAt: TimeInterval? = nil) -> ReminderEpisode {
        ReminderEpisode(tool: .claude, limit: .secondary, tier: tier,
                        enteredAt: start, tierAt: start.addingTimeInterval(tierAt),
                        resetsAt: start.addingTimeInterval(4 * 86_400),
                        resumedAt: resumedAt.map(start.addingTimeInterval),
                        awaitingResume: awaitingResume,
                        acknowledgedAt: acknowledgedAt.map(start.addingTimeInterval))
    }

    private func phase(_ offset: TimeInterval, count: Int = 1,
                       _ episode: ReminderEpisode? = nil) -> Int? {
        MenuBarReminder.phase(episode: episode ?? self.episode(),
                              now: start.addingTimeInterval(offset), reminderCount: count)
    }

    // MARK: The cycle (§2.1)

    /// Entry fires a reminder **immediately**, in both tiers. The reader who just crossed the
    /// line is the one who most needs telling; making them wait would be a strange kind of
    /// politeness — and it is the one thing neither REV-98's decay nor REV-100's phases touch.
    func testTheFirstReminderFiresOnEntry() {
        XCTAssertEqual(phase(0), 0)
        XCTAssertEqual(phase(0, count: 1, episode(.nearlySpent)), 0)
    }

    /// Seven seconds up (REV-100 §2.2), whatever the interval is. The boundaries are asserted on
    /// both sides, because an inclusive/exclusive slip here is a bar that flickers for one frame
    /// and nobody can say why.
    func testTheSevenSecondBoundary() {
        XCTAssertEqual(phase(6.9), 0)
        XCTAssertNil(phase(7))
        XCTAssertNil(phase(7.1))
    }

    // MARK: The cadence table (REV-100 §2.2)

    /// **Amber: every minute for an hour, every ten minutes the second hour, then hourly.**
    func testAmberMinutesThenTensThenHours() {
        XCTAssertNil(phase(59.9))
        XCTAssertEqual(phase(60), 0)           // second reminder, a minute in
        XCTAssertNil(phase(67))
        XCTAssertEqual(phase(3_540), 0)        // sixtieth and last of the first hour
        XCTAssertNil(phase(3_590))
        XCTAssertEqual(phase(3_600), 0)        // the first boundary is itself a reminder
        XCTAssertNil(phase(3_660), "a minute's spacing does not survive the first hour")
        XCTAssertEqual(phase(4_200), 0)
        XCTAssertEqual(phase(6_600), 0)        // last of the second hour
        XCTAssertNil(phase(6_900))
        XCTAssertEqual(phase(7_200), 0)        // the second boundary is a reminder too
        XCTAssertNil(phase(7_800), "…and after it, hourly")
        XCTAssertEqual(phase(10_800), 0)
    }

    /// The whole amber grid, walked edge to edge through the clock's own function: 0, 60 … 3 540,
    /// then 3 600, 4 200 … 6 600, then 7 200, 10 800, 14 400 — the fixture Baseline §19 names.
    func testTheAmberGridIsExactlyTheSpecs() {
        let expected = Array(stride(from: 0.0, to: 3_600, by: 60))
            + Array(stride(from: 3_600.0, to: 7_200, by: 600))
            + [7_200, 10_800, 14_400]
        var starts: [TimeInterval] = []
        var t = 0.0
        while starts.count < expected.count {
            XCTAssertNotNil(phase(t), "a start at +\(t)s")
            starts.append(t)
            guard let end = edge(t), let next = edge(end) else { return XCTFail("clock stopped") }
            XCTAssertEqual(end, t + MenuBarReminder.reminderSeconds)
            t = next
        }
        XCTAssertEqual(starts, expected)
    }

    /// The figure REV-100 §2.2 states, asserted rather than asserted about: **160 reminders over
    /// four days of unacknowledged amber** — sixty in the first hour, six in the second, then
    /// ninety-four hourly. REV-98 gave 101 and the flat interval before it 5 760.
    func testFourDaysOfAmberIsOneHundredAndSixtyReminders() {
        XCTAssertEqual(MenuBarReminder.reminderCount(tier: .aheadOfPace, over: 4 * 86_400), 160)
        XCTAssertEqual(MenuBarReminder.reminderCount(tier: .aheadOfPace, over: 3_599), 60)
        XCTAssertEqual(MenuBarReminder.reminderCount(tier: .aheadOfPace, over: 7_199), 66)
    }

    // MARK: Alternation (§2.3)

    /// Two warnings take successive reminders, most severe first — never two in a row, never a
    /// third phase. The alternation counts *reminders*, so it survives both boundaries where the
    /// spacing changes underneath it.
    func testTwoWarningsAlternate() {
        XCTAssertEqual(phase(0, count: 2), 0)
        XCTAssertEqual(phase(60, count: 2), 1)
        XCTAssertEqual(phase(120, count: 2), 0)
        XCTAssertEqual(phase(3_540, count: 2), 1)   // sixtieth reminder
        XCTAssertEqual(phase(3_600, count: 2), 0)   // sixty-first, the first ten-minute one
        XCTAssertEqual(phase(4_200, count: 2), 1)
        XCTAssertEqual(phase(7_200, count: 2), 0)   // sixty-seventh, the first hourly one
        XCTAssertEqual(phase(10_800, count: 2), 1)
    }

    // MARK: What never fires

    func testNothingToRemindAboutNeverReminds() {
        XCTAssertNil(phase(0, count: 0))
        XCTAssertNil(phase(60, count: 0))
    }

    /// A clock that went backwards is not a reason to flash the menu bar.
    func testATimeBeforeEntryIsSteady() {
        XCTAssertNil(phase(-1))
        XCTAssertNil(phase(-3_600))
    }

    /// A restored episode is silent until a live reading confirms the tier — reminding about a
    /// tier the app has not re-read would be the confident claim D-35 refuses.
    func testARestoredEpisodeIsSilentUntilItIsConfirmed() {
        let held = episode(awaitingResume: true)
        for offset in [0.0, 7, 60, 3_600, 7_200] {
            XCTAssertNil(phase(offset, count: 1, held), "at +\(offset)s")
        }
    }

    // MARK: The relaunch reminder (§2.3)

    /// **One reminder immediately, then the decayed cadence at the episode's true age.** An
    /// episode two hours and thirteen minutes old resumes at 8 000 s — nowhere near a grid
    /// instant — reminds there, and then waits for its own hourly grid rather than replaying
    /// either of the louder hours it has long since left behind.
    func testARelaunchRemindsOnceAndThenDecays() {
        let resumed = episode(resumedAt: 8_000)
        XCTAssertNil(phase(7_900, count: 1, resumed), "nothing before the resume")
        XCTAssertEqual(phase(8_000, count: 1, resumed), 0, "the one reminder a relaunch earns")
        XCTAssertEqual(phase(8_006.9, count: 1, resumed), 0)
        XCTAssertNil(phase(8_007, count: 1, resumed))
        XCTAssertNil(phase(8_060, count: 1, resumed), "not a minute later — the first hour is gone")
        XCTAssertNil(phase(8_600, count: 1, resumed), "nor ten — so is the second")
        XCTAssertEqual(phase(10_800, count: 1, resumed), 0, "the grid, unmoved by the resume")
    }

    /// The resume shows the **worst** limit: the reader has been away, and the first thing they
    /// get back is the top of the list rather than wherever the alternation happened to be —
    /// which at 10 800 s is the second one.
    func testTheRelaunchReminderShowsTheWorstLimit() {
        XCTAssertEqual(phase(8_000, count: 2, episode(resumedAt: 8_000)), 0)
        XCTAssertEqual(phase(10_800, count: 2, episode()), 1, "…where the grid's own turn is not")
    }

    /// A resume landing **on** a scheduled reminder does not hijack the alternation: the grid is
    /// checked first, so a relaunch cannot silently restart the cycle at the worst limit for the
    /// rest of the episode.
    func testAResumeOnAScheduledReminderKeepsTheAlternation() {
        XCTAssertEqual(phase(10_800, count: 2, episode(resumedAt: 10_800)), 1)
    }

    // MARK: Acknowledgement (REV-100 §2.2 — STEP_211)

    /// **A reminder on screen when the reader looks is not cut** — it ends at its own edge
    /// through the ordinary fade — and nothing follows it: no next start, no next edge, so the
    /// clock stops.
    func testAReminderOnScreenAtAcknowledgementEndsAtItsEdgeAndNothingFollows() {
        let looked = episode(acknowledgedAt: 62)
        XCTAssertEqual(phase(62, count: 1, looked), 0)
        XCTAssertEqual(phase(66.9, count: 1, looked), 0)
        XCTAssertNil(phase(67, count: 1, looked))
        for offset in [120.0, 3_540, 3_600, 7_200, 10_800] {
            XCTAssertNil(phase(offset, count: 1, looked), "at +\(offset)s")
        }
        XCTAssertEqual(edge(62, looked), 67, "the reminder's own end is still an edge")
        XCTAssertNil(edge(67, looked), "and then there is none")
    }

    /// Acknowledged in the steady phase: nothing more at all.
    func testAnAcknowledgementBetweenRemindersSilencesTheRest() {
        let looked = episode(acknowledgedAt: 30)
        XCTAssertNil(phase(60, count: 1, looked))
        XCTAssertNil(edge(30, looked))
    }

    /// A click on the very instant a reminder starts lets that reminder finish: it may already be
    /// drawn, and cutting it would be the §2.4a glitch in reverse.
    func testAnAcknowledgementOnAStartKeepsThatReminder() {
        XCTAssertEqual(phase(60, count: 1, episode(acknowledgedAt: 60)), 0)
    }

    /// **A relaunch after a look owes nothing** — the resume reminder is for a reader who has
    /// been away, and this one already looked.
    func testAnAcknowledgedRelaunchHasNoResumeReminder() {
        let looked = episode(resumedAt: 8_000, acknowledgedAt: 7_300)
        XCTAssertNil(phase(8_000, count: 1, looked))
        XCTAssertNil(edge(7_300, looked))
    }

    /// **Amber only.** The flag rides along on escalation and mutes nothing in red.
    func testAnAmberAcknowledgementDoesNotMuteRed() {
        let escalated = episode(.spent, acknowledgedAt: 30)
        XCTAssertEqual(phase(300, count: 1, escalated), 0)
        XCTAssertNotNil(edge(30, escalated))
    }

    // MARK: Storage (Baseline §17.1)

    /// Five fields, the fifth empty until a look; a four-field row written before STEP_211 still
    /// restores, unacknowledged; anything else is malformed.
    func testTheStoredValueCarriesTheAcknowledgement() throws {
        let plain = episode()
        XCTAssertTrue(plain.storedValue.hasSuffix("|"), plain.storedValue)
        XCTAssertEqual(plain.storedValue.split(separator: "|", omittingEmptySubsequences: false)
                        .count, 5)
        let back = try XCTUnwrap(ReminderEpisode.restored(tool: .claude, limit: .secondary,
                                                         storedValue: plain.storedValue))
        XCTAssertNil(back.acknowledgedAt)
        XCTAssertTrue(back.awaitingResume)

        let looked = episode(acknowledgedAt: 62)
        let restored = try XCTUnwrap(ReminderEpisode.restored(tool: .claude, limit: .secondary,
                                                             storedValue: looked.storedValue))
        XCTAssertEqual(restored.acknowledgedAt, start.addingTimeInterval(62))
        XCTAssertEqual(restored.storedValue, looked.storedValue)

        let legacy = String(plain.storedValue.dropLast())
        let old = try XCTUnwrap(ReminderEpisode.restored(tool: .claude, limit: .secondary,
                                                        storedValue: legacy))
        XCTAssertNil(old.acknowledgedAt)
        XCTAssertEqual(old.tierAt, plain.tierAt)

        XCTAssertNil(ReminderEpisode.restored(tool: .claude, limit: .secondary,
                                              storedValue: legacy + "|soon"))
        XCTAssertNil(ReminderEpisode.restored(tool: .claude, limit: .secondary,
                                              storedValue: plain.storedValue + "|"))
    }

    // MARK: The constants are the spec's (§3.3)

    func testTheCadenceConstantsAreTheSpecs() {
        XCTAssertEqual(MenuBarReminder.reminderSeconds, 7)
        XCTAssertEqual(MenuBarReminder.decayAfterSeconds, 3_600)
        XCTAssertEqual(MenuBarReminder.secondDecayAfterSeconds, 7_200)
        XCTAssertEqual(MenuBarReminder.amberCadence, .init(first: 60, second: 600, late: 3_600))
        // One cadence: red holds its shape and never reminds (REV-100 §2.1), and the unconfirmed
        // monthly that alone read the red column was retired with REV-102 (STEP_220).
        for tier in [LongLimitAssessment.Tier.onPace, .aheadOfPace, .nearlySpent, .spent] {
            XCTAssertEqual(MenuBarReminder.cadence(for: tier), MenuBarReminder.amberCadence)
        }
    }

    // MARK: The next edge — the sleeping clock's one rule (§2.1 — STEP_199)

    private func edge(_ offset: TimeInterval, _ episode: ReminderEpisode? = nil) -> TimeInterval? {
        MenuBarReminder.nextEdge(episode: episode ?? self.episode(),
                                 now: start.addingTimeInterval(offset))?
            .timeIntervalSince(start)
    }

    /// The schedule's clock and these assertions read the same function, so a sleeping task and a
    /// test cannot disagree about where a boundary is.
    func testTheNextEdgeIsTheEndOfAReminderOrTheStartOfTheNext() {
        XCTAssertEqual(edge(0), 7)          // inside the first reminder → its end
        XCTAssertEqual(edge(6.9), 7)
        XCTAssertEqual(edge(7), 60)         // steady → the next reminder's start
        XCTAssertEqual(edge(59.9), 60)
        XCTAssertEqual(edge(60), 67)
        XCTAssertEqual(edge(3_547), 3_600, "the last first-hour gap runs to the boundary")
        XCTAssertEqual(edge(3_607), 4_200, "then ten minutes")
        XCTAssertEqual(edge(6_607), 7_200, "the last of those runs to the second boundary")
        XCTAssertEqual(edge(7_207), 10_800, "and after it, an hour")
    }

    /// The resume adds an edge and removes none.
    func testTheNextEdgeAccountsForAPendingResume() {
        let resumed = episode(resumedAt: 8_000)
        XCTAssertEqual(edge(7_207, resumed), 8_000, "the resume comes before the hourly grid")
        XCTAssertEqual(edge(8_000, resumed), 8_007)
        XCTAssertEqual(edge(8_007, resumed), 10_800, "and then the grid again")
    }

    /// A clock that went backwards points at the tier's start — its first reminder — rather than
    /// at a negative sleep.
    func testTheNextEdgeBeforeEntryIsEntry() {
        XCTAssertEqual(edge(-30), 0)
    }

    /// Every edge is strictly ahead of the instant it was asked about, so the clock loop can
    /// never spin — swept across both tiers and across both boundaries.
    func testEveryEdgeIsInTheFuture() {
        for tier in [LongLimitAssessment.Tier.aheadOfPace, .nearlySpent] {
            let e = episode(tier)
            for step in 0...2_400 {
                let offset = Double(step) * 5
                let next = edge(offset, e)
                XCTAssertNotNil(next, "\(tier) at +\(offset)s")
                XCTAssertGreaterThan(next ?? -1, offset, "\(tier) at +\(offset)s")
            }
        }
    }

    // MARK: The motion constants are the spec's (§3.3 — STEP_199, STEP_211)

    func testTheMotionConstantsAreTheSpecs() {
        XCTAssertEqual(MenuBarReminder.pulseFloorOpacity, 0.55)
        XCTAssertEqual(MenuBarReminder.pulseCycleSeconds, 1.6)
        XCTAssertEqual(MenuBarReminder.pulseCycles, 4)
        // Four cycles fit inside the phase and leave the row still before it ends.
        XCTAssertLessThan(MenuBarReminder.pulseCycleSeconds * Double(MenuBarReminder.pulseCycles),
                          MenuBarReminder.reminderSeconds)
    }

    // MARK: The reading — held is not recovered (REV-98 §2.3 — STEP_202)

    /// A five-hour warning outranks both long-limit ranks, so the bar keeps its own urgent string
    /// and reminds about nothing — but the weekly is still **in the reading**, so the episode
    /// holds through it instead of restarting when the five-hour calms.
    func testAFiveHourWarningHoldsTheBarAndKeepsTheLimit() {
        let f = LongLimitFixture.claudeFiveHourOutranksTheWeekly
        XCTAssertTrue(f.menuBar.reminders.isEmpty)
        XCTAssertEqual(f.menuBar.timeSlot, "◔~11m")
        XCTAssertEqual(f.menuBar.longLimits.statuses.map(\.limit), [.secondary])
        XCTAssertEqual(f.menuBar.longLimits.statuses.first?.tier, .nearlySpent)
        // The popover still says the weekly is nearly spent — the bar is quiet about it, not the
        // app (the implication rule, PATTERNS: a reminder implies a strip, never the converse).
        XCTAssertEqual(f.header?.longLimitStrip?.cue, .red)
    }

    /// A confirmed block says its piece through the steady string and keeps the limit, so the
    /// episode survives the block rather than starting over when it lifts.
    func testABlockKeepsItsLimitInTheReading() {
        let f = LongLimitFixture.claudeWeeklySpent
        XCTAssertTrue(f.menuBar.reminders.isEmpty)
        XCTAssertEqual(f.menuBar.longLimits.statuses.map(\.limit), [.secondary])
        XCTAssertEqual(f.menuBar.longLimits.statuses.first?.tier, .spent)
    }

    /// Loading, idle and null-window have no assessment: the reading is **unknown**, not empty,
    /// so nothing they render ends an episode.
    func testTheStatesWithNoReadingHoldRatherThanRecover() {
        for state in [AppState.idleFallback, .nullWindow] {
            let menu = DisplayFormatter.toolMenuBar(tool: .claude, state: state, snapshot: nil,
                                                    forecast: nil, now: start)
            XCTAssertEqual(menu.longLimits, .unknown, "\(state)")
            XCTAssertTrue(menu.reminders.isEmpty, "\(state)")
        }
        XCTAssertEqual(DisplayFormatter.loadingMenuBar(.claude).longLimits, .unknown)
    }

    /// A stale render never reminds and never recovers: a tier read off a frozen snapshot would
    /// be the confident claim D-35 refuses, and treating that silence as recovery is what made a
    /// poll gap replay the reminder from the top. The block that survives staleness keeps its
    /// *name*, not its cycle.
    func testAStaleRenderHoldsTheEpisode() {
        let f = LongLimitFixture.claudeBlockStale
        XCTAssertEqual(f.menuBar.longLimits, .unknown)
        XCTAssertTrue(f.menuBar.reminders.isEmpty)
        XCTAssertEqual(f.menuBar.percentText, "⚠wk 0%")
        XCTAssertNil(f.menuBar.timeSlot, "a cached countdown would lie (§9.3)")
    }

    /// **Recovery is the tier clearing, not the percentage falling** (§2.3). The same 52 % used
    /// that is amber at 45.2 % of the week is on pace at 55 % — a live reading naming no elevated
    /// limit, which is what ends an episode.
    func testRecoveryAtUnchangedUtilization() {
        let warning = LongLimitFixture.claudeProjection115Amber
        let recovered = LongLimitFixture.claudeRecoveryOnPace
        XCTAssertEqual(warning.snapshot.secondaryUsedPct, recovered.snapshot.secondaryUsedPct)
        XCTAssertEqual(warning.menuBar.longLimits.statuses.map(\.limit), [.secondary])
        XCTAssertEqual(recovered.menuBar.longLimits, .live([]),
                       "a live reading with nothing elevated — not `unknown`")
    }

    // MARK: Two warnings, one account colour (§2.2)

    /// **A red monthly beside an amber weekly holds; nothing cycles** — the accepted consequence of
    /// REV-100 §2.1 (owner, 2026-09-17). Red owns the bar in its held shape, in the account's red;
    /// the amber weekly stays in the reading, worst first, so its episode is held rather than
    /// ended, but it has no line while the red limit owns the bar.
    func testARedMonthlyHoldsOverAnAmberWeeklyInTheAccountColour() {
        let f = LongLimitFixture.claudeBothLimitsWarning
        XCTAssertTrue(f.menuBar.percentText.hasPrefix("⚠mo "), f.menuBar.fullString)
        XCTAssertTrue(f.menuBar.reminders.isEmpty, f.menuBar.reminders.description)
        XCTAssertEqual(f.menuBar.longLimits.statuses.map(\.limit), [.monthly, .secondary])
        XCTAssertEqual(f.menuBar.dot, .red)
    }

    // MARK: The reminder cycle, end to end (§3.8)

    /// One fixture, five instants: reminder / reminder / steady / steady / reminder. This is the
    /// frame-by-frame version of what a reader would see in the first minute of an amber
    /// warning — seven seconds up, a minute apart (REV-100 §2.2 — STEP_211). Red no longer cycles
    /// (REV-100 §2.1 — STEP_210), so amber is the tier this frame is about.
    func testTheReminderCycleRendersFrameByFrame() {
        let f = LongLimitFixture.claudeAheadOfPace
        let render = DisplayFormatter.menuBarRender(mode: .claudeOnly, claude: f.menuBar,
                                                    codex: nil)
        let e = episode(.aheadOfPace)
        let expected: [(TimeInterval, String)] = [
            (0,    "CL ⚠wk 30%"),
            (6.9,  "CL ⚠wk 30%"),
            (7,    "CL 71% ↻3h46m"),
            (59.9, "CL 71% ↻3h46m"),
            (60,   "CL ⚠wk 30%"),
        ]
        for (offset, text) in expected {
            let index = MenuBarReminder.phase(episode: e, now: start.addingTimeInterval(offset),
                                              reminderCount: f.menuBar.reminders.count)
            XCTAssertEqual(render.showingReminder(index, on: 0).lines[0].text, text,
                           "at +\(offset)s")
        }
    }

    // MARK: The field episode this settles (REV-97 §1.3 / §2.5)

    /// Three hours from the tester's 4–7 Sep Codex block, as `history_rollups` recorded them
    /// (bundle `Kvotar-diagnostics-20260908-0941-0.3.0-11-release`; values pasted, never read
    /// from a database by a test — the `LiveLongLimitDiagnostics` convention).
    ///
    /// Build 11 showed this reader the **five-hour** number and the five-hour reset for three
    /// days, beside a red dot, while the weekly was what had stopped them. The last frame is the
    /// worst of it: with the primary window gone the bar read `CX 100%` — "all of it left" — in
    /// the middle of a block.
    func testTheTesterBlockNamesTheWeeklyOnEveryFrame() {
        func frame(hour: TimeInterval, primaryUsed: Double, primaryResets: TimeInterval?)
            -> ToolMenuBarDisplay {
            let snapshot = QuotaSnapshot(
                tool: .codex, primaryUsedPct: primaryUsed,
                primaryResetsAt: primaryResets.map { Date(timeIntervalSince1970: $0) },
                secondaryUsedPct: 100,
                secondaryResetsAt: Date(timeIntervalSince1970: 1_788_764_127),
                rateLimitReached: true)
            return DisplayFormatter.toolMenuBar(tool: .codex, state: .overQuota,
                                                snapshot: snapshot, forecast: nil,
                                                now: Date(timeIntervalSince1970: hour))
        }
        // 4 Sep, inside the block, with a live five-hour window underneath it.
        XCTAssertEqual(frame(hour: 1_788_534_000, primaryUsed: 8,
                             primaryResets: 1_788_554_350).fullString, "CX ⚠wk 0% ↻3d")
        // 5 Sep — a five-hour rollover later, the same episode, the same string.
        XCTAssertEqual(frame(hour: 1_788_548_400, primaryUsed: 8,
                             primaryResets: 1_788_554_350).fullString, "CX ⚠wk 0% ↻3d")
        // 7 Sep, two hours before the Monday reset, with no primary window at all. Build 11 read
        // `CX 100%` here.
        let last = frame(hour: 1_788_757_200, primaryUsed: 0, primaryResets: nil)
        XCTAssertEqual(last.fullString, "CX ⚠wk 0% ↻1h55m")
        XCTAssertEqual(last.dot, .red)
        // A block never cycles, on any frame — and never stops being one episode either.
        XCTAssertTrue(last.reminders.isEmpty)
        XCTAssertEqual(last.longLimits.statuses.map(\.limit), [.secondary])
    }

    /// **The other tool never moves** (§2.1). One tool reminding leaves the other's line exactly
    /// as it was — the phase is per line, not per render.
    func testTheOtherToolIsUntouchedByAReminder() {
        let claude = LongLimitFixture.claudeAheadOfPace.menuBar
        let codex = ToolMenuBarDisplay(prefix: "CX", dot: .green, percentText: "58%",
                                       timeSlot: "↻2h04m")
        let render = DisplayFormatter.menuBarRender(mode: .bothStacked, claude: claude,
                                                    codex: codex)
        let reminding = render.showingReminder(0, on: 0)
        XCTAssertEqual(reminding.lines[0].text, "CL ⚠wk 30%")
        XCTAssertEqual(reminding.lines[1], render.lines[1])
        XCTAssertEqual(reminding.lines[1].text, "CX 58% ↻2h04m")
    }
}
