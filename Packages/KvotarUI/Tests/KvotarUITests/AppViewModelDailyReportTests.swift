import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_177 — the daily report is retained per tool out of band from the poll paths: it survives
/// a cached render, an unavailable state and a freshness tick, and never needs a poll to land.
@MainActor
final class AppViewModelDailyReportTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_789_048_800)

    private func snapshot(_ tool: Tool = .claude) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: 38,
                      primaryResetsAt: now.addingTimeInterval(2 * 3600),
                      secondaryUsedPct: 14, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: .disabled, planType: "pro")
    }

    private func forecast(_ tool: Tool = .claude) -> Forecast {
        Forecast(tool: tool, tier: .fullRunway, runwayMinutes: nil,
                 burnRatePerMin: 0.4, isEstimate: false, pollCount: 5)
    }

    private func report(tool: Tool = .claude) -> DailyLocalReport {
        let p = DailyLocalReport.Project(
            name: "/u/kvotar", tokens: 500,
            models: [.init(model: "claude-fable-5-1", tokens: 500, value: 0.01)],
            latestEventAt: now, value: 0.01)
        return DailyLocalReport(tool: tool, dayStart: now.addingTimeInterval(-14 * 3600),
                                readUntil: now, totalTokens: 500, sessionCount: 1,
                                cacheHitRatio: nil, projects: [p], lastEventAt: now, value: 0.01)
    }

    func testReportAppliedBeforeAnyPollWaitsForTheRender() {
        let vm = AppViewModel()
        vm.applyDailyReport(tool: .claude, .available(report()), now: now)
        XCTAssertEqual(vm.claudeState.phase, .loading, "no poll yet — nothing to render into")
        XCTAssertEqual(vm.dailyReport(for: .claude), .available(report()))
        vm.apply(tool: .claude, snapshot: snapshot(), forecast: forecast(), state: .healthy, now: now)
        XCTAssertEqual(vm.claudeState.localActivity?.availability, .available)
        XCTAssertEqual(vm.claudeState.localActivity?.summary?.value, "500 tokens · 1 session")
    }

    func testReportAppliedAfterAPollReRendersAtOnce() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(), forecast: forecast(), state: .healthy, now: now)
        XCTAssertEqual(vm.claudeState.localActivity?.availability, .loading)
        vm.applyDailyReport(tool: .claude, .available(report()), now: now)
        XCTAssertEqual(vm.claudeState.localActivity?.availability, .available)
        XCTAssertEqual(vm.codexState.localActivity, nil, "the other tool is untouched")
    }

    func testCachedRenderKeepsTheReport() {
        let vm = AppViewModel()
        vm.apply(tool: .codex, snapshot: snapshot(.codex), forecast: forecast(.codex), state: .healthy, now: now)
        vm.applyDailyReport(tool: .codex, .available(report(tool: .codex)), now: now)
        vm.applyCached(tool: .codex, state: .idleFallback, snapshot: snapshot(.codex),
                       asOf: now.addingTimeInterval(-20 * 60), now: now)
        XCTAssertEqual(vm.codexState.dot, .grey)
        XCTAssertEqual(vm.codexState.localActivity?.availability, .available,
                       "a stale account reading does not stale local evidence")
    }

    func testUnavailableAccountDoesNotDiscardTheReport() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(), forecast: forecast(), state: .healthy, now: now)
        vm.applyDailyReport(tool: .claude, .available(report()), now: now)
        vm.applyUnavailable(tool: .claude, now: now)
        XCTAssertEqual(vm.dailyReport(for: .claude), .available(report()))
        vm.apply(tool: .claude, snapshot: snapshot(), forecast: forecast(), state: .healthy, now: now)
        XCTAssertEqual(vm.claudeState.localActivity?.availability, .available)
    }

    func testFreshnessTickReRendersWithTheReport() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(), forecast: forecast(), state: .healthy, now: now)
        vm.applyDailyReport(tool: .claude, .unavailable(retained: report(), failedAt: now), now: now)
        vm.refreshFreshness(now: now.addingTimeInterval(600))
        XCTAssertEqual(vm.claudeState.localActivity?.availability, .staleRetained(asOf: now))
        XCTAssertEqual(vm.claudeState.localActivity?.statusCopy?.hasPrefix("As of "), true)
    }
}
