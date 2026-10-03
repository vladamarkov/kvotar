import XCTest
@testable import KvotarCore

/// R33-7 Part B (STEP_39): the one Core expiry rule — an expired window is a null window —
/// shared by `StateEngine.classify` and `DisplayFormatter.degradeExpiredWindows`, keyed off the
/// single `QuotaSnapshot.resetJitterTolerance` (no second 60s literal anywhere).
final class QuotaSnapshotDegradationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(primaryReset: Date?, secondaryReset: Date? = nil) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: .claude,
            primaryUsedPct: 100,
            primaryResetsAt: primaryReset,
            secondaryUsedPct: 18,
            secondaryResetsAt: secondaryReset,
            rateLimitReached: true,
            extraUsage: .disabled,
            spendControlReached: true,
            email: "user@example.com",
            planType: "max")
    }

    func testExpiredPrimaryDegradesToNullIncludingHardBlockFlags() {
        let s = snapshot(primaryReset: now.addingTimeInterval(-120),
                         secondaryReset: now.addingTimeInterval(86_400))
        let d = s.degradingExpiredWindows(now: now)
        XCTAssertNil(d.primaryUsedPct)
        XCTAssertNil(d.primaryResetsAt)
        XCTAssertNil(d.rateLimitReached, "a block flag is a measurement about the spent window")
        XCTAssertNil(d.spendControlReached, "no hard block can be classified from a dead window")
        // The live weekly keeps its real values; identity fields survive.
        XCTAssertEqual(d.secondaryUsedPct, 18)
        XCTAssertEqual(d.planType, "max")
        XCTAssertEqual(d.email, "user@example.com")
    }

    func testExpiredSecondaryDegradesIndependently() {
        let s = snapshot(primaryReset: now.addingTimeInterval(3600),
                         secondaryReset: now.addingTimeInterval(-120))
        let d = s.degradingExpiredWindows(now: now)
        XCTAssertEqual(d.primaryUsedPct, 100)
        XCTAssertEqual(d.rateLimitReached, true)
        XCTAssertNil(d.secondaryUsedPct)
        XCTAssertNil(d.secondaryResetsAt)
    }

    func testWithinJitterToleranceIsNotExpired() {
        // 59s past the boundary is wobble, not a rollover (§9.2 jitter tolerance).
        let s = snapshot(primaryReset: now.addingTimeInterval(-59))
        XCTAssertEqual(s.degradingExpiredWindows(now: now), s)
    }

    func testNilResetsAtNeverDegrades() {
        // A window with no reset stamp cannot expire — null-window shapes pass through.
        let s = snapshot(primaryReset: nil)
        XCTAssertEqual(s.degradingExpiredWindows(now: now), s)
    }

    // MARK: REV-38 (STEP_43) — the monthly analogue (D-35: R33-7 at month scale)

    private func monthlySnapshot(
        monthlyReset: Date,
        primaryReset: Date? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: .codex,
            primaryUsedPct: primaryReset == nil ? nil : 100,
            primaryResetsAt: primaryReset,
            secondaryUsedPct: nil,
            secondaryResetsAt: nil,
            rateLimitReached: primaryReset == nil ? nil : true,
            spendControlReached: true,
            monthlyLimit: MonthlyLimit(
                limitAmount: 4000, usedAmount: 4000, remainingPercent: 0,
                resetsAt: monthlyReset, source: "group_based_spend_controls"),
            planType: "enterprise")
    }

    // MARK: - Model allowances expire per window (STEP_176 — REV-92 / Baseline §15.2)

    private func spark(primaryReset: Date?, secondaryReset: Date?) -> AdditionalRateLimit {
        AdditionalRateLimit(id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark",
                            usedPercent: 40, resetsAt: primaryReset, primaryWindowSeconds: 18_000,
                            secondary: .init(usedPercent: 12, resetsAt: secondaryReset,
                                             windowSeconds: 604_800))
    }

    private func withScoped(_ limits: [AdditionalRateLimit]) -> QuotaSnapshot {
        QuotaSnapshot(tool: .codex, primaryUsedPct: 4,
                      primaryResetsAt: now.addingTimeInterval(500_000),
                      primaryWindowSeconds: 604_800, secondaryUsedPct: nil,
                      secondaryResetsAt: nil, rateLimitReached: false, extraUsage: .disabled,
                      additionalRateLimits: limits)
    }

    /// An expired Spark five-hour window is cleared on its own; Spark's live weekly stays, and
    /// so does the width (a property of the plan, as for the main window).
    func testExpiredModelPrimaryWindowClearsOnlyThatWindow() {
        let s = withScoped([spark(primaryReset: now.addingTimeInterval(-120),
                                  secondaryReset: now.addingTimeInterval(500_000))])
        let d = s.degradingExpiredWindows(now: now)
        let limit = d.additionalRateLimits[0]
        XCTAssertNil(limit.usedPercent)
        XCTAssertNil(limit.resetsAt)
        XCTAssertEqual(limit.primaryWindowSeconds, 18_000, "the width survives expiry")
        XCTAssertEqual(limit.secondary?.usedPercent, 12)
        XCTAssertEqual(limit.secondary?.windowSeconds, 604_800)
        XCTAssertEqual(limit.id, "codex_bengalfox")
    }

    /// The reverse: an expired weekly leaves the five-hour window untouched.
    func testExpiredModelSecondaryWindowClearsOnlyThatWindow() {
        let s = withScoped([spark(primaryReset: now.addingTimeInterval(3600),
                                  secondaryReset: now.addingTimeInterval(-120))])
        let limit = s.degradingExpiredWindows(now: now).additionalRateLimits[0]
        XCTAssertEqual(limit.usedPercent, 40)
        XCTAssertEqual(limit.resetsAt, now.addingTimeInterval(3600))
        XCTAssertNil(limit.secondary)
    }

    /// Both windows gone ⇒ the allowance is gone — the single-reset behaviour STEP_134 pinned.
    func testModelAllowanceWithNoLiveWindowIsDropped() {
        let s = withScoped([spark(primaryReset: now.addingTimeInterval(-120),
                                  secondaryReset: now.addingTimeInterval(-120)),
                            spark(primaryReset: now.addingTimeInterval(3600),
                                  secondaryReset: now.addingTimeInterval(500_000))])
        let d = s.degradingExpiredWindows(now: now)
        XCTAssertEqual(d.additionalRateLimits.count, 1, "one allowance expiring must not take its sibling")
        XCTAssertEqual(d.additionalRateLimits[0].usedPercent, 40)
    }

    /// A single-window Claude scoped limit (no width, no secondary) expires exactly as before.
    func testSingleWindowScopedLimitStillExpiresWhole() {
        let fable = AdditionalRateLimit(id: nil, name: "Fable", usedPercent: 10,
                                        resetsAt: now.addingTimeInterval(-120))
        let s = withScoped([fable])
        XCTAssertTrue(s.degradingExpiredWindows(now: now).additionalRateLimits.isEmpty)
        let live = withScoped([AdditionalRateLimit(id: nil, name: "Fable", usedPercent: 10,
                                                   resetsAt: now.addingTimeInterval(120))])
        XCTAssertEqual(live.degradingExpiredWindows(now: now), live)
    }

    func testExpiredMonthlyDegradesLimitAndSpendControlFlag() {
        // Month rolled over: the monthly reading describes credits already forgiven, and the
        // spend-control block's recovery anchor (`individual_limit.reset_at`) has passed.
        let s = monthlySnapshot(monthlyReset: now.addingTimeInterval(-120))
        let d = s.degradingExpiredWindows(now: now)
        XCTAssertNil(d.monthlyLimit)
        XCTAssertNil(d.spendControlReached, "the block dies with its month")
        XCTAssertEqual(d.planType, "enterprise")
    }

    func testLiveMonthlyReanchorsSpendControlPastPrimaryExpiry() {
        // With a monthly limit present, `spend_control.reached` recovers at the *monthly* reset
        // (§8.3 REV-38): an expired 5-hour window degrades itself — and its own block flags —
        // but no longer clears the spend-control flag.
        let s = monthlySnapshot(monthlyReset: now.addingTimeInterval(86_400),
                                primaryReset: now.addingTimeInterval(-120))
        let d = s.degradingExpiredWindows(now: now)
        XCTAssertNil(d.primaryUsedPct)
        XCTAssertNil(d.rateLimitReached, "the windowed flag still dies with its window")
        XCTAssertEqual(d.spendControlReached, true, "monthly anchor keeps the spend-control block")
        XCTAssertNotNil(d.monthlyLimit)
    }

    func testMonthlyWithinJitterToleranceIsNotExpired() {
        let s = monthlySnapshot(monthlyReset: now.addingTimeInterval(-59))
        XCTAssertEqual(s.degradingExpiredWindows(now: now), s)
    }

    // MARK: The weekly width outlives its readings (STEP_188)

    /// A width belongs to the plan, not to the window that just ended — the rule
    /// `primaryWindowSeconds` has always followed, applied to its weekly twin.
    func testExpiredSecondaryKeepsItsWidth() {
        let s = QuotaSnapshot(
            tool: .codex,
            primaryUsedPct: 40,
            primaryResetsAt: now.addingTimeInterval(3600),
            primaryWindowSeconds: 18_000,
            secondaryUsedPct: 18,
            secondaryResetsAt: now.addingTimeInterval(-120),
            secondaryWindowSeconds: 604_800,
            rateLimitReached: false)
        let d = s.degradingExpiredWindows(now: now)
        XCTAssertNil(d.secondaryUsedPct)
        XCTAssertNil(d.secondaryResetsAt)
        XCTAssertEqual(d.secondaryWindowSeconds, 604_800)
    }

    func testWithdrawingThePrimaryWindowKeepsTheWeeklyWidth() {
        let s = QuotaSnapshot(
            tool: .codex,
            primaryUsedPct: 0,
            primaryResetsAt: now.addingTimeInterval(3600),
            primaryWindowSeconds: 18_000,
            secondaryUsedPct: 18,
            secondaryResetsAt: now.addingTimeInterval(86_400),
            secondaryWindowSeconds: 604_800,
            rateLimitReached: false)
        let w = s.withdrawingPrimaryWindow()
        XCTAssertNil(w.primaryUsedPct)
        XCTAssertEqual(w.secondaryUsedPct, 18)
        XCTAssertEqual(w.secondaryWindowSeconds, 604_800)
    }
}
