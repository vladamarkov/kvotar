import XCTest
@testable import KvotarCore

/// §17.1 `discontinuity_events` detection over the consecutive-poll comparison (STEP_52) —
/// per-type semantics and, above all, the both-non-null gating: a null↔value transition is
/// payload shape (overnight null, failed identity fetch, Codex healthy idle), never a moment.
final class DiscontinuityDetectorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        tool: Tool = .claude,
        plan: String? = nil,
        creditsEnabled: Bool? = nil,
        monthlyLimit: Double? = nil,
        monthlyUsed: Double = 100,
        monthlyResetDays: Double = 12,
        primaryUsedPct: Double? = 40,
        primaryResetsIn: TimeInterval? = 3600,
        primaryWindowSeconds: Int? = nil,
        secondaryUsedPct: Double? = 10,
        secondaryResetsIn: TimeInterval? = nil,
        bankedResets: Int? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: tool, primaryUsedPct: primaryUsedPct,
            primaryResetsAt: primaryResetsIn.map { now.addingTimeInterval($0) },
            primaryWindowSeconds: primaryWindowSeconds,
            secondaryUsedPct: secondaryUsedPct,
            secondaryResetsAt: secondaryResetsIn.map { now.addingTimeInterval($0) },
            rateLimitReached: false,
            extraUsage: creditsEnabled.map { ExtraUsage(isEnabled: $0, monthlyLimit: 2000) },
            rateLimitResetCreditsCount: bankedResets,
            monthlyLimit: monthlyLimit.map {
                MonthlyLimit(limitAmount: $0, usedAmount: monthlyUsed, remainingPercent: 50,
                             resetsAt: now.addingTimeInterval(monthlyResetDays * 86_400))
            },
            planType: plan)
    }

    private func detect(_ previous: QuotaSnapshot?, _ current: QuotaSnapshot,
                        at: Date? = nil) -> [DiscontinuityObservation] {
        DiscontinuityDetector.detect(previous: previous, current: current, now: at ?? now)
    }

    // MARK: limit_changed — monthly limit only (user decision 2026-07-19)

    func testLimitChangeBothNonNullWrites() {
        let events = DiscontinuityDetector.detect(
            previous: snapshot(monthlyLimit: 4000), current: snapshot(monthlyLimit: 6000), now: now)
        XCTAssertEqual(events, [DiscontinuityObservation(
            eventType: .limitChanged, windowType: "monthly",
            oldValue: "4000", newValue: "6000")])
    }

    func testLimitNullToValueWritesNothing() {
        XCTAssertEqual(DiscontinuityDetector.detect(
            previous: snapshot(monthlyLimit: nil), current: snapshot(monthlyLimit: 4000), now: now), [])
    }

    func testLimitValueToNullWritesNothing() {
        XCTAssertEqual(DiscontinuityDetector.detect(
            previous: snapshot(monthlyLimit: 4000), current: snapshot(monthlyLimit: nil), now: now), [])
    }

    func testNonIntegralLimitKeepsFraction() {
        let events = DiscontinuityDetector.detect(
            previous: snapshot(monthlyLimit: 4000), current: snapshot(monthlyLimit: 4000.5), now: now)
        XCTAssertEqual(events.first?.newValue, "4000.5")
    }

    // MARK: plan_changed

    func testPlanChangeWrites() {
        let events = DiscontinuityDetector.detect(
            previous: snapshot(plan: "pro"), current: snapshot(plan: "max"), now: now)
        XCTAssertEqual(events, [DiscontinuityObservation(
            eventType: .planChanged, oldValue: "pro", newValue: "max")])
        XCTAssertNil(events.first?.windowType, "account-scoped type carries no window_type")
    }

    /// The corpus shape (REV-73 §4.2): two Codex sources arguing about a name. The first flip is
    /// still written — one disagreement is an observation — and everything inside the damping
    /// window after it is withheld.
    func testPlanChangeIsDampedOnceTheNamesHaveTradedPlaces() {
        let history = [PlanTransition(at: now.addingTimeInterval(-90),
                                      from: "enterprise", to: "business")]
        XCTAssertEqual(DiscontinuityDetector.detect(
            previous: snapshot(plan: "business"), current: snapshot(plan: "enterprise"),
            now: now, recentPlanChanges: history), [])
        // …and the other direction is the same pair, so it is damped too.
        XCTAssertEqual(DiscontinuityDetector.detect(
            previous: snapshot(plan: "enterprise"), current: snapshot(plan: "business"),
            now: now, recentPlanChanges: history), [])
    }

    func testADifferentPairIsNeverDampedByAnUnrelatedArgument() {
        let history = [PlanTransition(at: now.addingTimeInterval(-90),
                                      from: "enterprise", to: "business")]
        let events = DiscontinuityDetector.detect(
            previous: snapshot(plan: "business"), current: snapshot(plan: "free"),
            now: now, recentPlanChanges: history)
        XCTAssertEqual(events.map(\.eventType), [.planChanged],
                       "a genuine change is recorded the moment it is seen")
    }

    func testAPairQuietForLongerThanTheWindowReArms() {
        let stale = [PlanTransition(at: now.addingTimeInterval(-PlanChangeStability.dampingWindow - 60),
                                    from: "enterprise", to: "business")]
        XCTAssertEqual(DiscontinuityDetector.detect(
            previous: snapshot(plan: "business"), current: snapshot(plan: "enterprise"),
            now: now, recentPlanChanges: stale).map(\.eventType), [.planChanged])
    }

    /// Damping withholds the **row**, not the reading: the plan still moved, so the window Codex
    /// replaced with it is still not an early reset.
    func testADampedPlanChangeStillSuppressesEarlyReset() {
        let history = [PlanTransition(at: now.addingTimeInterval(-90), from: "go", to: "plus")]
        let previous = snapshot(tool: .codex, plan: "plus", primaryUsedPct: 100,
                                primaryResetsIn: 20 * 86_400, primaryWindowSeconds: 2_592_000,
                                secondaryUsedPct: nil)
        let current = snapshot(tool: .codex, plan: "go", primaryUsedPct: 0,
                               primaryResetsIn: 30 * 86_400, primaryWindowSeconds: 2_592_000,
                               secondaryUsedPct: nil)
        XCTAssertEqual(DiscontinuityDetector.detect(previous: previous, current: current, now: now,
                                                    recentPlanChanges: history), [])
    }

    func testPlanNullTransitionsWriteNothing() {
        XCTAssertEqual(DiscontinuityDetector.detect(
            previous: snapshot(plan: nil), current: snapshot(plan: "pro"), now: now), [])
        XCTAssertEqual(DiscontinuityDetector.detect(
            previous: snapshot(plan: "pro"), current: snapshot(plan: nil), now: now), [])
    }

    // MARK: credits_toggled

    func testCreditsToggleWrites() {
        let events = DiscontinuityDetector.detect(
            previous: snapshot(creditsEnabled: true), current: snapshot(creditsEnabled: false), now: now)
        XCTAssertEqual(events, [DiscontinuityObservation(
            eventType: .creditsToggled, oldValue: "1", newValue: "0")])
    }

    func testMissingExtraUsageObjectWritesNothing() {
        // nil object = no pay-as-you-go exposed (Enterprise) — payload shape, not a toggle.
        XCTAssertEqual(DiscontinuityDetector.detect(
            previous: snapshot(creditsEnabled: nil), current: snapshot(creditsEnabled: true), now: now), [])
        XCTAssertEqual(DiscontinuityDetector.detect(
            previous: snapshot(creditsEnabled: false), current: snapshot(creditsEnabled: nil), now: now), [])
    }

    // MARK: monthly_rollover

    func testMonthlyRolloverWritesSpendAndNewReset() {
        let previous = snapshot(monthlyLimit: 4000, monthlyUsed: 3999.5, monthlyResetDays: 0.5)
        let current = snapshot(monthlyLimit: 4000, monthlyUsed: 2, monthlyResetDays: 30.5)
        let events = DiscontinuityDetector.detect(previous: previous, current: current, now: now)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventType, .monthlyRollover)
        XCTAssertEqual(events.first?.oldValue, "3999.5", "old = spend-at-rollover")
        XCTAssertEqual(events.first?.newValue,
                       String(Int(now.timeIntervalSince1970) + Int(30.5 * 86_400)),
                       "new = the new cycle end")
        XCTAssertNil(events.first?.utilizationPct)
    }

    func testMonthlyResetJitterWritesNothing() {
        let previous = snapshot(monthlyLimit: 4000, monthlyResetDays: 10)
        let current = snapshot(monthlyLimit: 4000, monthlyUsed: 100,
                               monthlyResetDays: 10 + 30.0 / 86_400)   // +30s wobble
        XCTAssertEqual(DiscontinuityDetector.detect(previous: previous, current: current, now: now), [])
    }

    // MARK: general gating

    func testIdenticalSnapshotsWriteNothing() {
        let s = snapshot(plan: "pro", creditsEnabled: true, monthlyLimit: 4000)
        XCTAssertEqual(DiscontinuityDetector.detect(previous: s, current: s, now: now), [])
    }

    func testNoPreviousWritesNothing() {
        XCTAssertEqual(DiscontinuityDetector.detect(
            previous: nil, current: snapshot(plan: "pro", monthlyLimit: 4000), now: now), [])
    }

    func testSimultaneousMomentsAllLand() {
        // One poll can reveal several moments — e.g. a limit change landing with the rollover.
        let previous = snapshot(plan: "pro", monthlyLimit: 4000, monthlyUsed: 3000,
                                monthlyResetDays: 0.5)
        let current = snapshot(plan: "max", monthlyLimit: 6000, monthlyUsed: 0,
                               monthlyResetDays: 30.5)
        let types = DiscontinuityDetector.detect(previous: previous, current: current, now: now)
            .map(\.eventType)
        XCTAssertEqual(Set(types), [.limitChanged, .planChanged, .monthlyRollover])
    }

    // MARK: REV-69 window facts (D-76 — STEP_114); Baseline §19 fixture names in comments

    private let day: TimeInterval = 86_400

    /// §19 `disc-window-removed`: 5-hour live at 40 % → absent next poll, weekly still moving.
    func testWindowRemovedWhenSlotVanishesWithAnchorAheadAndOtherWindowLive() {
        let previous = snapshot(primaryUsedPct: 40, primaryResetsIn: 3600, secondaryUsedPct: 30,
                                secondaryResetsIn: 3 * day)
        let current = snapshot(primaryUsedPct: nil, primaryResetsIn: nil, secondaryUsedPct: 31,
                               secondaryResetsIn: 3 * day)
        XCTAssertEqual(detect(previous, current), [DiscontinuityObservation(
            eventType: .windowRemoved, windowType: "five_hour",
            oldValue: "18000", newValue: nil, utilizationPct: 40)])
    }

    func testWeeklyRemovedBesideLivePrimaryRecordsWeeklyWidth() {
        let previous = snapshot(secondaryUsedPct: 61, secondaryResetsIn: 3 * day)
        let current = snapshot(secondaryUsedPct: nil, secondaryResetsIn: nil)
        XCTAssertEqual(detect(previous, current), [DiscontinuityObservation(
            eventType: .windowRemoved, windowType: "weekly",
            oldValue: "604800", newValue: nil, utilizationPct: 61)])
    }

    /// §19 `disc-idle-null`: every window null → payload shape, nothing written.
    func testAllNullCurrentWritesNothing() {
        let previous = snapshot(primaryUsedPct: 40, primaryResetsIn: 3600, secondaryUsedPct: 30,
                                secondaryResetsIn: 3 * day)
        let current = snapshot(primaryUsedPct: nil, primaryResetsIn: nil,
                               secondaryUsedPct: nil, secondaryResetsIn: nil)
        XCTAssertEqual(detect(previous, current), [])
    }

    func testClaudeOvernightNullAfterExpiryIsNotARemoval() {
        // The 5-hour anchor has passed (−120s) — the normal post-expiry null (§8.0.2), even
        // though the weekly is still live.
        let previous = snapshot(primaryUsedPct: 40, primaryResetsIn: -120, secondaryUsedPct: 30,
                                secondaryResetsIn: 3 * day)
        let current = snapshot(primaryUsedPct: nil, primaryResetsIn: nil, secondaryUsedPct: 30,
                               secondaryResetsIn: 3 * day)
        XCTAssertEqual(detect(previous, current), [])
    }

    func testMorningStartIsNotAnAddition() {
        // Primary nil → live beside a live weekly is a window starting after idle, never
        // `window_added` (documented limitation — indistinguishable from two snapshots).
        let previous = snapshot(primaryUsedPct: nil, primaryResetsIn: nil, secondaryUsedPct: 30,
                                secondaryResetsIn: 3 * day)
        let current = snapshot(primaryUsedPct: 1, primaryResetsIn: 5 * 3600, secondaryUsedPct: 30,
                               secondaryResetsIn: 3 * day)
        XCTAssertEqual(detect(previous, current), [])
    }

    func testSecondaryAppearingBesideLivePrimaryIsWindowAdded() {
        let previous = snapshot(tool: .codex, primaryUsedPct: 12, primaryResetsIn: 3 * day,
                                primaryWindowSeconds: 604_800,
                                secondaryUsedPct: nil, secondaryResetsIn: nil)
        let current = snapshot(tool: .codex, primaryUsedPct: 12, primaryResetsIn: 3 * day,
                               primaryWindowSeconds: 604_800,
                               secondaryUsedPct: 0, secondaryResetsIn: 30 * day)
        XCTAssertEqual(detect(previous, current), [DiscontinuityObservation(
            eventType: .windowAdded, windowType: "weekly", oldValue: nil, newValue: "604800")])
    }

    func testCodexIdleToActiveWritesNothing() {
        let previous = snapshot(tool: .codex, primaryUsedPct: nil, primaryResetsIn: nil,
                                secondaryUsedPct: nil, secondaryResetsIn: nil)
        let current = snapshot(tool: .codex, primaryUsedPct: 2, primaryResetsIn: 7 * day,
                               primaryWindowSeconds: 604_800,
                               secondaryUsedPct: nil, secondaryResetsIn: nil)
        XCTAssertEqual(detect(previous, current), [])
    }

    func testUnanchoredCurrentIsNotARemoval() {
        // Codex "not started": usedPct 0 with a width and no anchor — StateEngine's
        // `window_demolished` territory, never `window_removed`.
        let previous = snapshot(tool: .codex, primaryUsedPct: 3, primaryResetsIn: 6 * day,
                                primaryWindowSeconds: 604_800,
                                secondaryUsedPct: 5, secondaryResetsIn: 20 * day)
        let current = snapshot(tool: .codex, primaryUsedPct: 0, primaryResetsIn: nil,
                               primaryWindowSeconds: 604_800,
                               secondaryUsedPct: 5, secondaryResetsIn: 20 * day)
        XCTAssertEqual(detect(previous, current), [])
    }

    func testStaleRestoredPreviousFiresNothing() {
        // Restart after a long sleep: the restored anchor is in the past, the weekly moved on.
        let previous = snapshot(primaryUsedPct: 40, primaryResetsIn: -6 * 3600,
                                secondaryUsedPct: 30, secondaryResetsIn: -1 * day)
        let current = snapshot(primaryUsedPct: nil, primaryResetsIn: nil, secondaryUsedPct: 2,
                               secondaryResetsIn: 6 * day)
        XCTAssertEqual(detect(previous, current), [])
    }

    /// §19 `disc-width-changed`: `limit_window_seconds` 604 800 → 432 000.
    func testWidthChangeWritesOldAndNewSeconds() {
        let previous = snapshot(tool: .codex, primaryUsedPct: 12, primaryResetsIn: 3 * day,
                                primaryWindowSeconds: 604_800, secondaryUsedPct: nil)
        let current = snapshot(tool: .codex, primaryUsedPct: 12, primaryResetsIn: 3 * day,
                               primaryWindowSeconds: 432_000, secondaryUsedPct: nil)
        XCTAssertEqual(detect(previous, current), [DiscontinuityObservation(
            eventType: .windowWidthChanged, windowType: "120_hour",   // windowTypeName: `_day` only from 7 days
            oldValue: "604800", newValue: "432000")])
    }

    func testWidthChangeOnNullWindowWritesNothing() {
        let previous = snapshot(tool: .codex, primaryUsedPct: 12, primaryResetsIn: 3 * day,
                                primaryWindowSeconds: 604_800, secondaryUsedPct: nil)
        let current = snapshot(tool: .codex, primaryUsedPct: nil, primaryResetsIn: nil,
                               primaryWindowSeconds: 432_000, secondaryUsedPct: nil)
        XCTAssertEqual(detect(previous, current), [])
    }

    /// §19 `disc-early-reset`: weekly at 61 % resets 3 days before its anchor.
    func testEarlyResetRecordsScheduledAnchorObservedInstantAndForgivenUtilization() {
        let previous = snapshot(secondaryUsedPct: 61, secondaryResetsIn: 3 * day)
        let current = snapshot(secondaryUsedPct: 0, secondaryResetsIn: 10 * day)
        XCTAssertEqual(detect(previous, current), [DiscontinuityObservation(
            eventType: .earlyReset, windowType: "weekly",
            oldValue: String(Int(now.timeIntervalSince1970) + Int(3 * day)),
            newValue: String(Int(now.timeIntervalSince1970)),
            utilizationPct: 61)])
    }

    func testAnchorAdvanceAfterScheduledResetIsNotEarly() {
        // Observed 90 s after the old anchor: an ordinary rollover (StateEngine's window_reset).
        let previous = snapshot(secondaryUsedPct: 61, secondaryResetsIn: -90)
        let current = snapshot(secondaryUsedPct: 0, secondaryResetsIn: 7 * day)
        XCTAssertEqual(detect(previous, current), [])
    }

    func testAnchorJitterWithinToleranceIsNotAnEarlyReset() {
        let previous = snapshot(secondaryUsedPct: 61, secondaryResetsIn: 3 * day)
        let current = snapshot(secondaryUsedPct: 61, secondaryResetsIn: 3 * day + 30)
        XCTAssertEqual(detect(previous, current), [])
    }

    func testEarlyResetAtZeroPercentWritesNothing() {
        let previous = snapshot(secondaryUsedPct: 0, secondaryResetsIn: 3 * day)
        let current = snapshot(secondaryUsedPct: 0, secondaryResetsIn: 10 * day)
        XCTAssertEqual(detect(previous, current), [])
    }

    func testEarlyResetSuppressedOnPlanChange() {
        // Codex replaces the window on a plan change (dogfood 2026-08-01 / 08-08): the plan
        // change is the fact; the new anchor is its consequence, not a handed-out reset.
        let previous = snapshot(tool: .codex, plan: "go", primaryUsedPct: 100,
                                primaryResetsIn: 20 * day, primaryWindowSeconds: 2_592_000,
                                secondaryUsedPct: nil)
        let current = snapshot(tool: .codex, plan: "plus", primaryUsedPct: 0,
                               primaryResetsIn: 30 * day, primaryWindowSeconds: 2_592_000,
                               secondaryUsedPct: nil)
        XCTAssertEqual(detect(previous, current).map(\.eventType), [.planChanged])
    }

    func testPrimaryEarlyResetOnClaudeIsWrittenAsFiveHour() {
        let previous = snapshot(primaryUsedPct: 40, primaryResetsIn: 3600)
        let current = snapshot(primaryUsedPct: 0, primaryResetsIn: 5 * 3600)
        let events = detect(previous, current)
        XCTAssertEqual(events.map(\.eventType), [.earlyReset])
        XCTAssertEqual(events.first?.windowType, "five_hour")
    }
}
