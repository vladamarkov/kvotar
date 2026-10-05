import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_87 (REV-59 / UI Spec D-58 + D-59) — **a window is named by the width the provider
/// reported**, never by its position in the payload and never by `plan_type`.
///
/// The defect these pin: on the live `go` account the card read `5-hour used ● 0%` for a window
/// the provider reported as 43,200 minutes — wrong by a factor of 144 — over `Weekly used —` and
/// `Weekly resets —` rows for a secondary window that does not exist on the tier, where the dash
/// reads as *we failed to fetch this* rather than *this does not apply*.
///
/// **Evidence posture: measured, not synthetic.** Every width, utilization and reset instant below
/// is copied from a real `rate_limits` block in this machine's `~/.codex/sessions` corpus (121
/// files, 4,798 blocks; 384 at `window_minutes: 300`, 384 at `10080`, 54 at `43200`). That matters
/// more than usual here, because the whole defect is that each payload looks individually
/// reasonable — an invented fixture would have looked reasonable too.
final class DisplayFormatterWindowGrainTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FixtureTimeZone.pin(self)
    }

    // MARK: Fixtures — real corpus values

    /// `go` account, 2026-08-11. Anchored at first use 18:47:32 CEST; the reset lands
    /// 2026-09-10 18:47:32 CEST, exactly 2,592,000 s later.
    private static let goResetsAt = Date(timeIntervalSince1970: 1_789_058_852)
    private static let thirtyDayWidth = 43_200 * 60

    /// Enterprise, the 5-hour + weekly pairing. Every 300 + 10,080 block in the corpus belongs to
    /// an Enterprise/Business account — no consumer account this project has observed has it.
    private static let entPrimaryResetsAt = Date(timeIntervalSince1970: 1_772_425_633)
    private static let entSecondaryResetsAt = Date(timeIntervalSince1970: 1_773_012_433)

    /// Poll instant for the 30-day fixtures: the window's first request, so the reset is a full
    /// 30 days out and the row must read `30 days · Sep 10`.
    private var goNow: Date { Self.goResetsAt.addingTimeInterval(-30 * 86_400) }
    private var entNow: Date { Self.entPrimaryResetsAt.addingTimeInterval(-90 * 60) }

    /// The `go`/`free` shape: one 30-day primary, **no** secondary, no monthly limit, no credits.
    private func goSnapshot(used: Double? = 89, resetsAt: Date? = goResetsAt) -> QuotaSnapshot {
        QuotaSnapshot(tool: .codex, primaryUsedPct: used, primaryResetsAt: resetsAt,
                      primaryWindowSeconds: Self.thirtyDayWidth,
                      secondaryUsedPct: nil, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: nil,
                      source: .appServerRPC, planType: "go")
    }

    /// The Enterprise shape this step must leave exactly as it is.
    private func enterpriseSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(tool: .codex, primaryUsedPct: 1, primaryResetsAt: Self.entPrimaryResetsAt,
                      primaryWindowSeconds: 300 * 60,
                      secondaryUsedPct: 0, secondaryResetsAt: Self.entSecondaryResetsAt,
                      rateLimitReached: false, extraUsage: nil,
                      source: .appServerRPC, planType: "enterprise")
    }

    /// Claude never populates `primaryWindowSeconds` — the property that makes it structurally
    /// immune to every rule in this file.
    private func claudeSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: 38,
                      primaryResetsAt: Self.entPrimaryResetsAt,
                      secondaryUsedPct: 14, secondaryResetsAt: Self.entSecondaryResetsAt,
                      rateLimitReached: false, extraUsage: .disabled,
                      email: "user@example.com", planType: "max")
    }

    private func labels(_ rows: [LabeledRow]) -> [String] { rows.map(\.label) }

    private func value(_ rows: [LabeledRow], _ label: String) -> String? {
        rows.first { $0.label == label }?.value
    }

    // MARK: D-58 — the row labels

    /// The headline defect. 43,200 minutes is `Monthly`, and this assertion fails before the fix
    /// with `5-hour used` — the row the live account actually rendered.
    func testThirtyDayWindowIsNamedMonthly() {
        let rows = DisplayFormatter.quotaRows(state: .elevated, snapshot: goSnapshot(), now: goNow)
        XCTAssertEqual(value(rows, "Monthly left"), "11%",
                       "43,200 minutes is a monthly window — the name comes from the width")
        XCTAssertNil(value(rows, "5-hour left"),
                     "the 5-hour label on a 30-day window is wrong by a factor of 144")
    }

    /// Clause 3 of D-58 — *render the windows you were sent*. An absent window produces no rows;
    /// a dash would claim a fetch failure where the truth is that the tier has no such window.
    func testAbsentSecondaryWindowOmitsItsRows() {
        let rows = DisplayFormatter.quotaRows(state: .healthy, snapshot: goSnapshot(), now: goNow)
        XCTAssertFalse(labels(rows).contains("Weekly left"))
        XCTAssertFalse(labels(rows).contains("Weekly resets"))
        XCTAssertEqual(labels(rows), ["Monthly left", "Resets in"],
                       "the go card is two rows, not four with two dashes")
    }

    /// The reset row switches form with the *distance*, not the width: a wall-clock time is
    /// meaningless a month out, so the day band takes `Resets in  30 days · Sep 10`. The absolute
    /// date is what the user cross-checks against OpenAI's own menu, and what keeps "Monthly"
    /// honest for a window that is rolling rather than calendar-aligned.
    func testMonthlyResetRowPairsCountdownWithDate() {
        let rows = DisplayFormatter.quotaRows(state: .healthy, snapshot: goSnapshot(), now: goNow)
        XCTAssertEqual(value(rows, "Resets in"), "30 days · Sep 10")
    }

    /// A 300-minute window is `5-hour` on both sides of this change, and its four rows stay.
    /// Codex Enterprise is unaffected by construction — it reports the shape the labels assumed.
    func testFiveHourWindowKeepsItsNameAndItsRows() {
        let rows = DisplayFormatter.quotaRows(state: .healthy, snapshot: enterpriseSnapshot(),
                                              now: entNow)
        XCTAssertEqual(labels(rows), ["5-hour left", "Resets at", "Weekly left", "Weekly resets"])
        XCTAssertEqual(value(rows, "5-hour left"), "99%")
        XCTAssertEqual(value(rows, "Weekly left"), "100%")
    }

    /// **The regression that matters most.** `quotaRows` is shared with Claude (the STEP_85
    /// lesson), so a Claude snapshot — which never carries a width — must render byte-identically
    /// to pre-change, labels and values alike (values remaining since REV-77 / D-97).
    func testClaudeRowsAreUnchanged() {
        let rows = DisplayFormatter.quotaRows(state: .healthy, snapshot: claudeSnapshot(),
                                              now: entNow)
        XCTAssertEqual(labels(rows), ["5-hour left", "Resets at", "Weekly left", "Weekly resets"])
        XCTAssertEqual(value(rows, "5-hour left"), "62%")
        XCTAssertEqual(value(rows, "Resets at"), DisplayFormatter.resetShort(
            Self.entPrimaryResetsAt, now: entNow))
        XCTAssertEqual(value(rows, "Weekly left"), "86%")
        XCTAssertEqual(value(rows, "Weekly resets"), Fmt.monthDay(Self.entSecondaryResetsAt))
    }

    /// Same nil grain, two meanings. On Claude it means *this rule does not apply*; on Codex it
    /// means the provider genuinely did not say how wide the window is — and D-58 is explicit that
    /// we then make no grain claim at all rather than guessing one.
    func testCodexWithNoReportedWidthMakesNoGrainClaim() {
        let snap = QuotaSnapshot(tool: .codex, primaryUsedPct: 42,
                                 primaryResetsAt: Self.entPrimaryResetsAt,
                                 secondaryUsedPct: nil, secondaryResetsAt: nil,
                                 rateLimitReached: false, extraUsage: nil,
                                 source: .wham, planType: "plus")
        let rows = DisplayFormatter.quotaRows(state: .healthy, snapshot: snap, now: entNow)
        XCTAssertEqual(value(rows, "Left"), "58%")
        XCTAssertFalse(labels(rows).contains("5-hour left"),
                       "an unnamed width must not borrow the five-hour name")
    }

    /// STEP_85's `— (no window open)` copy is not disturbed: an unanchored window still has a
    /// grain (the width is known) but no reset, and the row says why rather than dashing.
    func testUnanchoredWindowKeepsItsNoWindowCopy() {
        let rows = DisplayFormatter.quotaRows(state: .healthy,
                                              snapshot: goSnapshot(used: 0, resetsAt: nil),
                                              now: goNow)
        XCTAssertEqual(value(rows, "Monthly left"), "100%")
        XCTAssertEqual(value(rows, "Resets at"), "— (no window open)")
    }

    // MARK: D-59 — the countdown unit follows the distance, not the tool

    /// 30 days renders `719h59m` before this change, which is how the 2026-07-31 spike first
    /// noticed the window was not five hours.
    func testCountdownGainsADayUnit() {
        let now = Date(timeIntervalSince1970: 1_786_466_852)
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(30 * 86_400), from: now), "30d")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(9 * 86_400), from: now), "9d")
    }

    /// Rounding is **up**: a countdown must never promise relief sooner than it arrives, whether
    /// the user is rationing or already blocked.
    func testDayCountdownRoundsUp() {
        let now = Date(timeIntervalSince1970: 1_786_466_852)
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(29.5 * 86_400), from: now), "30d")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(2.1 * 86_400), from: now), "3d")
    }

    // MARK: §2.7 — the reminder's compact reset (REV-97, STEP_198)

    /// Above 48 hours the reminder and the countdown are the **same function**, so a reminder and
    /// a reset can never disagree about a span of two days or more. That reuse is the whole
    /// argument for allowing a second duration form at all (REV-96 §5 item 6 refused one that
    /// could contradict D-59; this one cannot).
    func testTheCompactResetIsTheDayBandAboveFortyEightHours() {
        let now = Date(timeIntervalSince1970: 1_786_466_852)
        for span in [2.0, 4.2, 9.0, 30.0] {
            let at = now.addingTimeInterval(span * 86_400)
            XCTAssertEqual(Fmt.compactReset(to: at, from: now), Fmt.countdown(to: at, from: now),
                           "\(span) days")
        }
    }

    /// Below it the hours are whole and **rounded up** — the same never-promise-relief-early rule
    /// the day band follows. This is where the width comes from: `47h59m` becomes `48h`.
    func testTheCompactResetRoundsHoursUpBelowTheDayBand() {
        let now = Date(timeIntervalSince1970: 1_786_466_852)
        XCTAssertEqual(Fmt.compactReset(to: now.addingTimeInterval(47 * 3600 + 59 * 60), from: now),
                       "48h")
        XCTAssertEqual(Fmt.compactReset(to: now.addingTimeInterval(3 * 3600 + 1), from: now), "4h")
        XCTAssertEqual(Fmt.compactReset(to: now.addingTimeInterval(3 * 3600), from: now), "3h")
        // The one place the two forms genuinely diverge, and the reason the compact one exists:
        // just under the day band, `47h54m` is five characters of precision nobody reads in a
        // five-second glance.
        let almost = now.addingTimeInterval(47.9 * 3600)
        XCTAssertEqual(Fmt.compactReset(to: almost, from: now), "48h")
        XCTAssertEqual(Fmt.countdown(to: almost, from: now), "47h54m")
    }

    /// Minutes only under an hour, and nothing at all for a reset that has passed — a reminder
    /// about a limit that already let go is not a reminder.
    func testTheCompactResetKeepsMinutesUnderAnHourAndNothingAfterIt() {
        let now = Date(timeIntervalSince1970: 1_786_466_852)
        XCTAssertEqual(Fmt.compactReset(to: now.addingTimeInterval(59 * 60), from: now), "59m")
        XCTAssertEqual(Fmt.compactReset(to: now.addingTimeInterval(61), from: now), "2m")
        XCTAssertNil(Fmt.compactReset(to: now, from: now))
        XCTAssertNil(Fmt.compactReset(to: now.addingTimeInterval(-60), from: now))
    }

    /// The boundary is 48 hours, not 24: `1d` is ambiguous between 24 and 47 hours, while `31h`
    /// is unambiguous and no wider. Below it the existing hour and minute forms are untouched —
    /// which is what keeps every Claude string identical.
    func testBelowFortyEightHoursTheHourFormIsUnchanged() {
        let now = Date(timeIntervalSince1970: 1_786_466_852)
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(47 * 3600), from: now), "47h00m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(3 * 3600 + 20 * 60), from: now),
                       "3h20m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(45 * 60), from: now), "45m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(48 * 3600), from: now), "2d",
                       "48 hours is the first value in the day band")
    }

    /// Caught by rendering the live `go` card end-to-end: the verdict read
    /// `resets 6:47 pm tomorrow` for a reset **30 days** away, because every future date that was
    /// not today earned the word. Naming the window's true span is what made the lie visible.
    func testClockDayNamesTheDateInsideTheDayBand() {
        let now = Date(timeIntervalSince1970: 1_786_552_368)   // 2026-08-11 20:32:48 CEST
        XCTAssertEqual(Fmt.clockDay(Self.goResetsAt, from: now), "Sep 10")
        // Below the band "tomorrow" still means tomorrow — where every Claude reset lives.
        XCTAssertEqual(Fmt.clockDay(now.addingTimeInterval(20 * 3600), from: now),
                       "\(Fmt.clock(now.addingTimeInterval(20 * 3600))) tomorrow")
        XCTAssertEqual(Fmt.clockDay(now.addingTimeInterval(90 * 60), from: now),
                       Fmt.clock(now.addingTimeInterval(90 * 60)))
    }

    // MARK: The hero's reset line (the D-58 caption's fact, relocated by STEP_178)
    //
    // The caption now names the limit (`Monthly quota left`) and the reset moved to its own
    // muted line under the verdict. The **band rule is unchanged**: a window whose reset the
    // verdict already carries gets no line, so the reset is still stated exactly once
    // (REV-66 / D-70).

    /// A rolling 30-day window's reset is days out, so the header states it.
    func testHeroResetLineOnALongWindow() {
        let header = DisplayFormatter.header(tool: .codex, state: .elevated,
                                             snapshot: goSnapshot(), forecast: nil, now: goNow)
        XCTAssertEqual(header.limitCaption, "Monthly quota left")
        XCTAssertEqual(header.heroDetails.map(\.text), ["resets in 30 days"])
    }

    /// On the REV-57 unanchored shape the line turns an apparent fault into information.
    func testHeroResetLineOnUnanchoredWindow() {
        let header = DisplayFormatter.header(tool: .codex, state: .healthy,
                                             snapshot: goSnapshot(used: 0, resetsAt: nil),
                                             forecast: nil, now: goNow)
        XCTAssertEqual(header.heroDetails.map(\.text), ["not started"])
    }

    /// REV-66/D-70 inside the D-59 sub-48h band: `daysLong` is nil there, and a day-or-wider
    /// window falls back to the spaced hour-band countdown rather than losing the reset.
    func testHeroResetLineSub48hFallsBackToCountdown() {
        let now = Date(timeIntervalSince1970: 1_789_058_852)
        let weekly = QuotaSnapshot(tool: .codex, primaryUsedPct: 61,
                                   primaryResetsAt: now.addingTimeInterval(14 * 3600 + 5 * 60),
                                   primaryWindowSeconds: 10_080 * 60,
                                   secondaryUsedPct: nil, secondaryResetsAt: nil,
                                   rateLimitReached: false, extraUsage: nil,
                                   source: .appServerRPC, planType: "plus")
        let header = DisplayFormatter.header(tool: .codex, state: .healthy,
                                             snapshot: weekly, forecast: nil, now: now)
        // "14h 5m", not "14h05m" — the spaced form is the §2.3 register.
        XCTAssertEqual(header.heroDetails.map(\.text), ["resets in 14h 5m"])
    }

    /// A five-hour window carries no reset line: its verdict already states the reset.
    func testHeroResetLineAbsentOnFiveHourWindow() {
        let header = DisplayFormatter.header(tool: .codex, state: .healthy,
                                             snapshot: enterpriseSnapshot(), forecast: nil,
                                             now: entNow)
        XCTAssertTrue(header.heroDetails.isEmpty)
    }

    /// Claude reports no width, so the band rule cannot fire and the verdict keeps the reset.
    func testHeroResetLineAbsentWithoutAWidth() {
        let header = DisplayFormatter.header(tool: .claude, state: .healthy,
                                             snapshot: claudeSnapshot(), forecast: nil, now: entNow)
        XCTAssertTrue(header.heroDetails.isEmpty)
    }

    // MARK: §0.4 — the plan-label table

    /// `go` was absent from the table and would have fallen through to the raw-value row.
    func testGoPlanLabel() {
        XCTAssertEqual(DisplayFormatter.planDisplayName("go"), "Go")
        XCTAssertEqual(DisplayFormatter.planDisplayName("free"), "Free")
    }

    // MARK: The lookup itself

    func testWindowGrainLookup() {
        XCTAssertEqual(DisplayFormatter.windowGrain(seconds: 300 * 60), "5-hour")
        XCTAssertEqual(DisplayFormatter.windowGrain(seconds: 10_080 * 60), "Weekly")
        XCTAssertEqual(DisplayFormatter.windowGrain(seconds: 43_200 * 60), "Monthly")
        XCTAssertEqual(DisplayFormatter.windowGrain(seconds: 72 * 3600), "72-hour")
        XCTAssertEqual(DisplayFormatter.windowGrain(seconds: 14 * 86_400), "14-day")
        XCTAssertNil(DisplayFormatter.windowGrain(seconds: nil))
        XCTAssertNil(DisplayFormatter.windowGrain(seconds: 4_271),
                     "a width we cannot name exactly yields no claim, never a guessed one")
    }
}
