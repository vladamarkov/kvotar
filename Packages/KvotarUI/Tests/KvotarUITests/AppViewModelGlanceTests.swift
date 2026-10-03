import XCTest
import KvotarCore
@testable import KvotarUI

/// §17.1 `popover_opens` glance fidelity (STEP_52): `glance()` must report exactly what the
/// render shows — the state as classified for it and the utilization through the same shared
/// degradation — including unknown/loading NULLs. What-was-shown facts, never recomputed.
@MainActor
final class AppViewModelGlanceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(tool: Tool, used: Double?,
                          resetsIn: TimeInterval = 2 * 3600) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: used,
                      primaryResetsAt: used == nil ? nil : now.addingTimeInterval(resetsIn),
                      secondaryUsedPct: used == nil ? nil : 14, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: .disabled, planType: "Pro")
    }

    private func forecast(_ tool: Tool) -> Forecast {
        Forecast(tool: tool, tier: .fullRunway, runwayMinutes: nil,
                 burnRatePerMin: 0.4, isEstimate: false, pollCount: 5)
    }

    func testGlanceBeforeAnyDataIsAllNull() {
        let vm = AppViewModel()
        let glance = vm.glance(now: now)
        XCTAssertEqual(glance.tab, vm.activeTab)
        XCTAssertNil(glance.claudeState, "loading is unknown — never an invented state string")
        XCTAssertNil(glance.claudeUsedPct)
        XCTAssertNil(glance.codexState)
        XCTAssertNil(glance.codexUsedPct)
    }

    func testGlanceMatchesLiveRender() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        let glance = vm.glance(now: now)
        XCTAssertEqual(glance.claudeState, "healthy")
        XCTAssertEqual(glance.claudeUsedPct, 38,
                       "must equal the rendered hero (\(vm.claudeState.header?.heroText ?? "—"))")
        XCTAssertNil(glance.codexState, "the untouched tool stays null")
        XCTAssertNil(glance.codexUsedPct)
    }

    func testGlanceMatchesCachedRender() {
        let vm = AppViewModel()
        vm.applyCached(tool: .claude, state: .overQuota,
                       snapshot: snapshot(tool: .claude, used: 104),
                       asOf: now.addingTimeInterval(-20 * 60), now: now)
        let glance = vm.glance(now: now)
        XCTAssertEqual(glance.claudeState, "over_quota",
                       "the stale-kept classification is what is shown (R33-1)")
        XCTAssertEqual(glance.claudeUsedPct, 104)
    }

    func testGlanceDegradesExpiredWindowLikeTheDisplay() {
        // The popover shows `—` for an expired window (R33-7 shared degradation) — the glance
        // must report the same null, not resurrect the pre-expiry number.
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 62, resetsIn: 600),
                 forecast: forecast(.claude), state: .healthy, now: now)
        let glance = vm.glance(now: now.addingTimeInterval(3600))
        XCTAssertEqual(glance.claudeState, "healthy")
        XCTAssertNil(glance.claudeUsedPct,
                     "an expired primary window is a null window, in the glance row too")
    }

    func testGlanceReportsPresentedTab() {
        let vm = AppViewModel()
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 91),
                 forecast: forecast(.codex), state: .atRisk, now: now)
        vm.selectDefaultTab(now: now)
        let glance = vm.glance(now: now)
        XCTAssertEqual(glance.tab, .codex, "§15.1 urgency default — the tab actually presented")
        XCTAssertEqual(glance.codexState, "at_risk")
        XCTAssertEqual(glance.codexUsedPct, 91)
    }
}
