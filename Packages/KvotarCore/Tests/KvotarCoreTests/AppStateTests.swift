import XCTest
@testable import KvotarCore

final class AppStateTests: XCTestCase {

    /// Severity order used by §15.1 default-tab selection: lower rank = more urgent, and
    /// Idle/fallback is least urgent (the §13 list's leading idle entry is a no-data guard).
    func testPriorityRankSeverityOrder() {
        XCTAssertLessThan(AppState.spendControl.priorityRank, AppState.overQuota.priorityRank)
        XCTAssertLessThan(AppState.overQuota.priorityRank, AppState.atRisk.priorityRank)
        XCTAssertLessThan(AppState.atRisk.priorityRank, AppState.badTiming.priorityRank)
        // Rank 5b sits between Bad timing and Fast burn (REV-96 §2.3 — STEP_194).
        XCTAssertLessThan(AppState.badTiming.priorityRank, AppState.limitNearlySpent.priorityRank)
        XCTAssertLessThan(AppState.limitNearlySpent.priorityRank, AppState.fastBurnSpike.priorityRank)
        XCTAssertLessThan(AppState.badTiming.priorityRank, AppState.elevated.priorityRank)
        XCTAssertLessThan(AppState.elevated.priorityRank, AppState.limitAheadOfPace.priorityRank)
        XCTAssertLessThan(AppState.limitAheadOfPace.priorityRank, AppState.healthy.priorityRank)
        XCTAssertLessThan(AppState.healthy.priorityRank, AppState.nullWindow.priorityRank)
        XCTAssertLessThan(AppState.nullWindow.priorityRank, AppState.idleFallback.priorityRank)
    }

    func testPriorityRankIsUnique() {
        let ranks = AppState.allCases.map(\.priorityRank)
        XCTAssertEqual(Set(ranks).count, AppState.allCases.count, "priorityRank must be a total order")
    }

    func testIdleFallbackIsLeastUrgent() {
        let maxRank = AppState.allCases.map(\.priorityRank).max()
        XCTAssertEqual(AppState.idleFallback.priorityRank, maxRank)
    }

    /// `state_transitions.to_state` strings for the two long-limit ranks — documented in §17.1.
    func testLongLimitRawValues() {
        XCTAssertEqual(AppState.limitAheadOfPace.rawValue, "limit_ahead_of_pace")
        XCTAssertEqual(AppState.limitNearlySpent.rawValue, "limit_nearly_spent")
    }

    /// REV-96 §5.4 (STEP_194): `weekly_elevated` is retired, nothing rewrites the rows that
    /// carry it, and a reader decoding a stored state still understands them.
    func testRetiredWeeklyElevatedStillDecodes() {
        XCTAssertNil(AppState(rawValue: "weekly_elevated"))
        XCTAssertEqual(AppState(storedRawValue: "weekly_elevated"), .limitAheadOfPace)
        // The strict path is unchanged for everything this build writes.
        for state in AppState.allCases {
            XCTAssertEqual(AppState(storedRawValue: state.rawValue), state)
        }
        XCTAssertNil(AppState(storedRawValue: "not_a_state"))
    }

    /// Owner ruling 2026-09-14: rank 5b is red but is **not** warning-tier — both readers of that
    /// set are about the primary window, and STEP_191 is grading off one of them.
    func testNearlySpentIsNotWarningTier() {
        XCTAssertFalse(AppState.limitNearlySpent.isWarningTier)
        XCTAssertFalse(AppState.limitAheadOfPace.isWarningTier)
        XCTAssertEqual(AppState.warningStates,
                       [.atRisk, .badTiming, .overQuota, .spendControl])
    }

    // Severity tiers were deleted by D-98 (REV-78): the type existed for the menu-bar gauge
    // glyph and the Adaptive text slot, both retired, and the stacked dot was always painted
    // from `StatusDot`. The table-driven `testSeverityTierMapping` went with them.
}
