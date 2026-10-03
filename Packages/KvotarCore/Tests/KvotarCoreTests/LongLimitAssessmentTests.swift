import XCTest
@testable import KvotarCore

/// STEP_194 — REV-96 §2.2: the four tiers on every secondary window and monthly limit, and the
/// one rule that picks between them. The state engine, the popover and the notification engine
/// all read this, so the boundaries are pinned here once rather than three times downstream.
final class LongLimitAssessmentTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week = 7.0 * 86_400

    /// A Claude-shaped snapshot: a weekly with a reading and a reset, and **no reported width**,
    /// which is the whole of what the endpoint sends.
    private func claudeWeekly(used: Double, elapsedFraction: Double) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: 20,
                      primaryResetsAt: now.addingTimeInterval(3600),
                      primaryWindowSeconds: 18_000,
                      secondaryUsedPct: used,
                      secondaryResetsAt: now.addingTimeInterval(week * (1 - elapsedFraction)),
                      rateLimitReached: false, extraUsage: .disabled)
    }

    private func tier(used: Double, elapsedFraction: Double) -> LongLimitAssessment.Tier? {
        claudeWeekly(used: used, elapsedFraction: elapsedFraction).longLimit(now: now)?.tier
    }

    // MARK: The tier ladder (§2.2)

    func testOnPaceUnderTheCalendar() {
        XCTAssertEqual(tier(used: 60, elapsedFraction: 0.8), .onPace)
    }

    /// Level with the calendar projects to exactly 100 %, which is well under the line.
    func testLevelWithTheCalendarIsOnPace() {
        XCTAssertEqual(tier(used: 50, elapsedFraction: 0.5), .onPace)
    }

    func testAheadOfPaceNeedsAllThreeConditions() {
        // Projects to 175 %, past the floor, past the grace.
        XCTAssertEqual(tier(used: 70, elapsedFraction: 0.4), .aheadOfPace)
        // Projects far past the line and past the grace, but under the floor.
        XCTAssertEqual(tier(used: 49, elapsedFraction: 0.4), .onPace)
        // Past the floor, projecting enormously, but inside the grace — the first hours of a
        // week are always "ahead of schedule" and mean nothing.
        XCTAssertEqual(tier(used: 60, elapsedFraction: 0.01), .onPace)
        // Past the floor and the grace, but behind the calendar — projects to 86 %.
        XCTAssertEqual(tier(used: 60, elapsedFraction: 0.7), .onPace)
    }

    // MARK: Where the pace lands (REV-98 §2.1 — STEP_200)

    /// The trigger is the projection, not the bare comparison: `used / elapsed × 100` against
    /// `longLimitProjectionPct`. Driven through the pure ladder so the two clocks can be set
    /// exactly, and asserted **at** the line as well as either side of it — the line is
    /// exclusive, and the cross-multiplied form in `longLimitTier` is what keeps that true at
    /// the boundary (the quotient of 55 over 50 is 110.00000000000001 in IEEE 754).
    func testTheProjectionLineIsExclusiveAtItsEdge() {
        func tierAtProjection(used: Double) -> LongLimitAssessment.Tier {
            QuotaSnapshot.longLimitTier(usedPct: used, elapsedPct: 50, spentByFlag: false)
        }
        XCTAssertEqual(tierAtProjection(used: 54.95), .onPace, "109.9 % — under the line")
        XCTAssertEqual(tierAtProjection(used: 55), .onPace, "110.0 % — on the line, not past it")
        XCTAssertEqual(tierAtProjection(used: 55.05), .aheadOfPace, "110.1 % — past the line")
    }

    /// **The July reading, verbatim** (`docs/evidence/REV98_projection_replay/`): 62 % used at
    /// 61.3 % of the week, projecting to 101 %. One of five such hours on 21–22 July 2026, on a
    /// window that peaked at 72 % — every sub-1-point amber the 50-floor has ever produced, and
    /// the case REV-96's bare `used > elapsed` could not tell from a blowout. Amber then, calm
    /// now.
    func testASubPointMarginIsCalm() {
        XCTAssertEqual(tier(used: 62, elapsedFraction: 0.613), .onPace)
    }

    /// **The owner's live reading, verbatim** (2026-09-14): 52 % used at 45.2 % of the week,
    /// projecting to 115 % — the week ends about a day early. It is the episode that prompted
    /// the revision, and it is a **true** warning: the back-of-envelope figure that called it
    /// marginal was arithmetic on the rounded `day 4 of 7` label, which rounds up. Pinned here
    /// so the case can never be quietly tuned away.
    func testTheLiveWeeklyStaysAmber() {
        XCTAssertEqual(tier(used: 52, elapsedFraction: 0.452), .aheadOfPace)
    }

    func testTheAmberFloorIsInclusive() {
        XCTAssertEqual(tier(used: 50, elapsedFraction: 0.4), .aheadOfPace)
        XCTAssertEqual(tier(used: 49.9, elapsedFraction: 0.4), .onPace)
    }

    func testTheGraceIsInclusiveAtItsEdge() {
        // `paceGraceFraction` is 2 % of the period.
        XCTAssertEqual(tier(used: 60, elapsedFraction: 0.02), .aheadOfPace)
        XCTAssertEqual(tier(used: 60, elapsedFraction: 0.0199), .onPace)
    }

    /// The red line is a **position** test — it fires however early in the week it happens.
    func testNearlySpentIgnoresThePace() {
        XCTAssertEqual(tier(used: 90, elapsedFraction: 0.95), .nearlySpent,
                       "well under the calendar, and still nearly spent")
        XCTAssertEqual(tier(used: 89.9, elapsedFraction: 0.95), .onPace)
    }

    func testSpentAtTheCeiling() {
        XCTAssertEqual(tier(used: 100, elapsedFraction: 0.5), .spent)
        XCTAssertEqual(tier(used: 140, elapsedFraction: 0.5), .spent)
    }

    // MARK: The calendar each limit is measured against (§2.2)

    /// Claude's `seven_day` object states no width, so the weekly paces against seven days.
    func testClaudeWeeklyWithNoReportedWidthUsesSevenDays() {
        let a = try! XCTUnwrap(claudeWeekly(used: 60, elapsedFraction: 0.25).longLimit(now: now))
        XCTAssertEqual(a.periodSeconds, 7 * 86_400)
        XCTAssertEqual(a.elapsedPct, 25, accuracy: 0.01)
    }

    /// Codex states a width on both transports, and a re-sized weekly paces against its real one.
    func testCodexWeeklyPacesAgainstTheReportedWidth() {
        let fiveDays = 5 * 86_400
        let s = QuotaSnapshot(tool: .codex, primaryUsedPct: 20,
                              primaryResetsAt: now.addingTimeInterval(3600),
                              primaryWindowSeconds: 18_000,
                              secondaryUsedPct: 60,
                              secondaryResetsAt: now.addingTimeInterval(Double(fiveDays) * 0.5),
                              secondaryWindowSeconds: fiveDays,
                              rateLimitReached: false)
        let a = try! XCTUnwrap(s.longLimit(now: now))
        XCTAssertEqual(a.periodSeconds, fiveDays)
        XCTAssertEqual(a.elapsedPct, 50, accuracy: 0.01)
        XCTAssertEqual(a.tier, .aheadOfPace)
    }

    /// The monthly's calendar is the cycle the backend anchors to — a real month, 28 to 31 days,
    /// never a fixed 30. Measured across February, the shortest one there is.
    func testMonthlyElapsedComesFromTheCalendarCycle() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let marchFirst = cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let febFifteenth = cal.date(from: DateComponents(year: 2026, month: 2, day: 15))!
        let monthly = MonthlyLimit(limitAmount: 4000, usedAmount: 2000, remainingPercent: 50,
                                   resetsAt: marchFirst)
        // 14 of February's 28 days gone — exactly half, which a 30-day assumption would call 47 %.
        XCTAssertEqual(monthly.elapsedPctInCycle(now: febFifteenth)!, 50, accuracy: 0.01)
        XCTAssertEqual(monthly.cycleSeconds()!, 28 * 86_400, accuracy: 1)
    }

    /// A limit with no reset has no calendar and no deadline: no assessment, and therefore no
    /// tier, no rank and no notification (§11.3).
    func testUnanchoredLimitYieldsNoAssessment() {
        let s = QuotaSnapshot(tool: .claude, primaryUsedPct: 20,
                              primaryResetsAt: now.addingTimeInterval(3600),
                              primaryWindowSeconds: 18_000,
                              secondaryUsedPct: 95, secondaryResetsAt: nil,
                              rateLimitReached: false)
        XCTAssertTrue(s.longLimitAssessments(now: now).isEmpty)
        XCTAssertNil(s.longLimit(now: now))
    }

    /// The **primary** window is never tiered, however long it is — Codex Plus's seven-day
    /// primary keeps its REV-65 pace verdict and is out of scope for this revision (§3.3).
    func testTheLongPrimaryWindowIsNotTiered() {
        let s = QuotaSnapshot(tool: .codex, primaryUsedPct: 95,
                              primaryResetsAt: now.addingTimeInterval(week * 0.5),
                              primaryWindowSeconds: Int(week),
                              secondaryUsedPct: nil, secondaryResetsAt: nil,
                              rateLimitReached: false)
        XCTAssertNil(s.longLimit(now: now))
    }

    // MARK: Selection across limits (§2.3)

    private func bothLimits(weeklyUsed: Double, weeklyResetDays: Double,
                            monthlyUsed: Double, monthlyResetDays: Double) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: 20,
                      primaryResetsAt: now.addingTimeInterval(3600),
                      primaryWindowSeconds: 18_000,
                      secondaryUsedPct: weeklyUsed,
                      secondaryResetsAt: now.addingTimeInterval(weeklyResetDays * 86_400),
                      rateLimitReached: false,
                      monthlyLimit: MonthlyLimit(
                        limitAmount: 100, usedAmount: monthlyUsed,
                        remainingPercent: Int(100 - monthlyUsed),
                        resetsAt: now.addingTimeInterval(monthlyResetDays * 86_400)))
    }

    func testWorseTierWins() {
        let s = bothLimits(weeklyUsed: 70, weeklyResetDays: 4,
                           monthlyUsed: 95, monthlyResetDays: 10)
        let worst = try! XCTUnwrap(s.longLimit(now: now))
        XCTAssertEqual(worst.limit, .monthly)
        XCTAssertEqual(worst.tier, .nearlySpent)
        // Both are still individually readable — the strip picks one, the rows show each.
        XCTAssertEqual(s.longLimit(.secondary, now: now)?.tier, .aheadOfPace)
    }

    /// On a tie the **nearer reset** wins: it is the one that stops you first, which is the only
    /// thing that distinguishes two equally bad limits.
    func testTieGoesToTheNearerReset() {
        let s = bothLimits(weeklyUsed: 95, weeklyResetDays: 3,
                           monthlyUsed: 95, monthlyResetDays: 12)
        XCTAssertEqual(s.longLimit(now: now)?.limit, .secondary)
        let reversed = bothLimits(weeklyUsed: 95, weeklyResetDays: 20,
                                  monthlyUsed: 95, monthlyResetDays: 12)
        XCTAssertEqual(reversed.longLimit(now: now)?.limit, .monthly)
    }

    /// The monthly reaches `.spent` through the flag as well as the number — which is what gives
    /// the Claude spend meter a tier at all, since its adapter never sets `spendControlReached`.
    func testMonthlyReachedFoldsIntoSpent() {
        let byNumber = bothLimits(weeklyUsed: 10, weeklyResetDays: 4,
                                  monthlyUsed: 100, monthlyResetDays: 10)
        XCTAssertEqual(byNumber.longLimit(.monthly, now: now)?.tier, .spent)
    }

    // MARK: Event 9's instance key (§3.5)

    func testNearlySpentKeyIsPerLimitInstanceAndToleratesResetJitter() {
        let a = try! XCTUnwrap(claudeWeekly(used: 92, elapsedFraction: 0.5).longLimit(now: now))
        XCTAssertEqual(LongLimitAssessment.nearlySpentSettingsKey(tool: .claude, limit: .secondary),
                       "nearly_spent.claude.secondary")
        XCTAssertTrue(a.matchesNearlySpent(storedValue: a.nearlySpentStoredValue))
        // The provider wobbles `resets_at` by a second or two inside one period; a string match
        // would read that as a new week and fire a second banner.
        let wobbled = String(Int(a.resetsAt.timeIntervalSince1970) + 1)
        XCTAssertTrue(a.matchesNearlySpent(storedValue: wobbled))
        // A genuinely different instance does not match.
        let nextWeek = String(Int(a.resetsAt.timeIntervalSince1970) + Int(7 * 86_400))
        XCTAssertFalse(a.matchesNearlySpent(storedValue: nextWeek))
        XCTAssertFalse(a.matchesNearlySpent(storedValue: nil))
        XCTAssertFalse(a.matchesNearlySpent(storedValue: "not-a-number"))
    }
}
