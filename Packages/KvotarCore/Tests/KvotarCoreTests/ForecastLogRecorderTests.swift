import XCTest
@testable import KvotarCore

final class ForecastLogRecorderTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Builders

    private func forecast(
        tool: Tool = .claude,
        tier: ForecastTier = .fullRunway,
        runway: Double? = nil,
        burn: Double? = nil,
        pollCount: Int = 10
    ) -> Forecast {
        Forecast(tool: tool, tier: tier, runwayMinutes: runway,
                 burnRatePerMin: burn, isEstimate: pollCount >= 2 && pollCount < 10,
                 pollCount: pollCount)
    }

    private func snapshot(
        tool: Tool = .claude,
        used: Double? = 44,
        secondary: Double? = 10,
        resetMinutes: Double? = 90
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: tool,
            primaryUsedPct: used,
            primaryResetsAt: resetMinutes.map { t0.addingTimeInterval($0 * 60) },
            secondaryUsedPct: secondary,
            secondaryResetsAt: nil,
            rateLimitReached: false,
            extraUsage: .disabled,
            spendControlReached: nil,
            monthlyLimit: nil)
    }

    private func makeRecorder() -> ForecastLogRecorder {
        ForecastLogRecorder(appVersion: "0.9.3 (142)")
    }

    /// The evaluation the coordinator hands the recorder: the displayed (post-hysteresis) state
    /// and whether this cycle produced a transition.
    private func evaluation(_ state: AppState = .healthy,
                            changed: Bool = false) -> StateEvaluation {
        StateEvaluation(
            state: state,
            change: changed ? StateChange(tool: .claude, previous: .healthy, new: state,
                                          utilizationPct: nil) : nil)
    }

    // MARK: Sampling clock

    func testSamplingClockOneRowPer300sWindow() {
        var recorder = makeRecorder()
        var written: [TimeInterval] = []
        for offset in stride(from: 0.0, through: 660, by: 60) {
            let entry = recorder.entry(
                tool: .claude, snapshot: snapshot(), forecast: forecast(),
                evaluation: evaluation(), now: t0.addingTimeInterval(offset))
            if let entry {
                written.append(offset)
                XCTAssertEqual(entry.trigger, .sample)
            }
        }
        XCTAssertEqual(written, [0, 300, 600])
    }

    func testToolsSampleIndependently() {
        var recorder = makeRecorder()
        XCTAssertNotNil(recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(), now: t0))
        // Codex's first evaluation lands 30s later — its own clock, writes regardless.
        XCTAssertNotNil(recorder.entry(
            tool: .codex, snapshot: snapshot(tool: .codex), forecast: forecast(tool: .codex),
            evaluation: evaluation(), now: t0.addingTimeInterval(30)))
        // Claude at +60s is inside claude's window; codex at +330s is past codex's own 300s.
        XCTAssertNil(recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(), now: t0.addingTimeInterval(60)))
        XCTAssertNotNil(recorder.entry(
            tool: .codex, snapshot: snapshot(tool: .codex), forecast: forecast(tool: .codex),
            evaluation: evaluation(), now: t0.addingTimeInterval(330)))
    }

    // MARK: State-change bypass

    func testStateChangeBypassesClock() {
        var recorder = makeRecorder()
        XCTAssertNotNil(recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(), now: t0))
        let change = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(.atRisk, changed: true), now: t0.addingTimeInterval(60))
        XCTAssertEqual(change?.trigger, .stateChange)
        // A second transition moments later also writes — the bypass is unconditional.
        let second = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(.atRisk, changed: true), now: t0.addingTimeInterval(90))
        XCTAssertEqual(second?.trigger, .stateChange)
    }

    func testStateChangeAdvancesSampleClock() {
        var recorder = makeRecorder()
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(), now: t0)
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.atRisk, changed: true), now: t0.addingTimeInterval(60))
        // 300s after the *first* row but only 240s after the transition row — not due yet.
        XCTAssertNil(recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(), now: t0.addingTimeInterval(300)))
        let due = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(), now: t0.addingTimeInterval(360))
        XCTAssertEqual(due?.trigger, .sample)
    }

    // MARK: Null-eta rows and tier derivation

    func testColdStartRowHasNullEtaAndColdStartTier() {
        var recorder = makeRecorder()
        let entry = recorder.entry(
            tool: .claude, snapshot: snapshot(),
            forecast: forecast(tier: .unknown, runway: nil, burn: nil, pollCount: 0),
            evaluation: evaluation(), now: t0)
        XCTAssertNil(entry?.etaTo100)
        XCTAssertNil(entry?.burnRatePctPerMin)
        XCTAssertEqual(entry?.forecastTier, .coldStart)
    }

    func testNearZeroBurnRowHasNullEtaPartialTier() {
        var recorder = makeRecorder()
        let entry = recorder.entry(
            tool: .claude, snapshot: snapshot(),
            forecast: forecast(runway: nil, burn: 0.0, pollCount: 5),
            evaluation: evaluation(), now: t0)
        XCTAssertNil(entry?.etaTo100)
        // Measured zero is not unmeasured — 0.0 must persist, distinct from nil.
        XCTAssertEqual(entry?.burnRatePctPerMin, 0.0)
        XCTAssertEqual(entry?.forecastTier, .partial)
    }

    func testFullTierEtaDerivation() {
        var recorder = makeRecorder()
        let entry = recorder.entry(
            tool: .claude, snapshot: snapshot(used: 78),
            forecast: forecast(runway: 44.0, burn: 0.5, pollCount: 10),
            evaluation: evaluation(), now: t0)
        XCTAssertEqual(entry?.etaTo100, t0.addingTimeInterval(44 * 60))
        XCTAssertEqual(entry?.forecastTier, .full)
        XCTAssertEqual(entry?.primaryUsedPct, 78)
    }

    func testNilSnapshotWritesNullUtilizations() {
        var recorder = makeRecorder()
        let entry = recorder.entry(
            tool: .claude, snapshot: nil,
            forecast: forecast(tier: .unknown, runway: nil, burn: nil, pollCount: 0),
            evaluation: evaluation(), now: t0)
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.primaryUsedPct)
        XCTAssertNil(entry?.secondaryUsedPct)
        XCTAssertNil(entry?.primaryResetsAt)
    }

    // MARK: Both rates on every row (REV-105 §2.4 — STEP_230)

    func testBurnColumnKeepsTheShortRateWhenTheBlendWasChosen() {
        var recorder = makeRecorder()
        // The runway was divided by the blend (0.2); the 18-minute rate (0.5) still lands in its
        // own column, and the eta is the one the app displayed.
        let blended = Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 280,
                               burnRatePerMin: 0.2, isEstimate: false, pollCount: 10,
                               burnSpanMinutes: 58, shortBurnRatePerMin: 0.5)
        let entry = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: blended,
                                   evaluation: evaluation(), now: t0)
        XCTAssertEqual(entry?.burnRatePctPerMin, 0.5)
        XCTAssertEqual(entry?.etaTo100, t0.addingTimeInterval(280 * 60))
    }

    // MARK: Displayed state and warning exposure (STEP_188 — REV-95 §3.2)

    func testDisplayedStateIsTheEvaluationState() {
        var recorder = makeRecorder()
        let entry = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(.elevated), now: t0)
        XCTAssertEqual(entry?.displayedState, .elevated)
        // The raw value is the `state_transitions.to_state` vocabulary a grader already reads.
        XCTAssertEqual(entry?.displayedState.rawValue, "elevated")
    }

    func testNoWarningYetLeavesTheStampNil() {
        var recorder = makeRecorder()
        let entry = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(.healthy), now: t0)
        XCTAssertNil(entry?.warningFirstShownAt)
    }

    func testFirstWarningDisplayStampsThatInstant() {
        var recorder = makeRecorder()
        let at = t0.addingTimeInterval(120)
        let entry = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(.atRisk, changed: true), now: at)
        XCTAssertEqual(entry?.warningFirstShownAt, at)
    }

    func testStampSurvivesTheStateCalmingDown() {
        var recorder = makeRecorder()
        let warned = t0.addingTimeInterval(60)
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.atRisk, changed: true), now: warned)
        // Back to healthy 10 minutes later: the user was still warned in this window.
        let later = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(.healthy), now: t0.addingTimeInterval(660))
        XCTAssertEqual(later?.warningFirstShownAt, warned)
    }

    func testAWorseWarningKeepsTheFirstInstant() {
        var recorder = makeRecorder()
        let first = t0.addingTimeInterval(60)
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.atRisk, changed: true), now: first)
        let worse = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(.overQuota, changed: true), now: t0.addingTimeInterval(400))
        XCTAssertEqual(worse?.warningFirstShownAt, first, "first, not latest")
    }

    func testStampClearsWhenTheAnchorAdvances() {
        var recorder = makeRecorder()
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.atRisk, changed: true),
                           now: t0.addingTimeInterval(60))
        // The next window: same shape, an anchor five hours further out.
        let next = recorder.entry(
            tool: .claude, snapshot: snapshot(resetMinutes: 90 + 300), forecast: forecast(),
            evaluation: evaluation(.healthy, changed: true), now: t0.addingTimeInterval(400))
        XCTAssertNil(next?.warningFirstShownAt, "a stamp is never inherited by the next window")
    }

    func testAnchorJitterInsideToleranceKeepsTheStamp() {
        var recorder = makeRecorder()
        let warned = t0.addingTimeInterval(60)
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.atRisk, changed: true), now: warned)
        // The endpoint wobbles its own reset by a couple of seconds — the same window.
        let wobbled = recorder.entry(
            tool: .claude, snapshot: snapshot(resetMinutes: 90 + 2.0 / 60), forecast: forecast(),
            evaluation: evaluation(.healthy, changed: true), now: t0.addingTimeInterval(400))
        XCTAssertEqual(wobbled?.warningFirstShownAt, warned)
    }

    func testStampClearsWhenTheRememberedAnchorHasPassed() {
        var recorder = makeRecorder()
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.atRisk, changed: true), now: t0)
        // Claude's post-reset payload carries no `resets_at` to advance, so the clause that has
        // to fire here is the remembered anchor having passed (90 min + tolerance).
        let after = recorder.entry(
            tool: .claude, snapshot: snapshot(used: nil, resetMinutes: nil), forecast: forecast(),
            evaluation: evaluation(.nullWindow, changed: true),
            now: t0.addingTimeInterval(90 * 60 + 120))
        XCTAssertNil(after?.warningFirstShownAt)
    }

    func testAWarningWithNoKnownWindowStampsNothing() {
        var recorder = makeRecorder()
        let entry = recorder.entry(
            tool: .claude, snapshot: snapshot(used: nil, resetMinutes: nil), forecast: forecast(),
            evaluation: evaluation(.overQuota, changed: true), now: t0)
        XCTAssertNil(entry?.warningFirstShownAt,
                     "no window instance to scope the stamp to, and none to clear it later")
    }

    func testACachedEvaluationStillStampsAKnownWindow() {
        var recorder = makeRecorder()
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.healthy), now: t0)
        // A failed poll re-classifies the cached snapshot — the window has not ended.
        let stamped = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(.atRisk, changed: true), now: t0.addingTimeInterval(120))
        XCTAssertEqual(stamped?.warningFirstShownAt, t0.addingTimeInterval(120))
    }

    func testTheLatchAdvancesOnEvaluationsThatWriteNoRow() {
        var recorder = makeRecorder()
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.healthy), now: t0)
        // Warning at +10s: inside the 300s clock and not a transition, so no row is written.
        let silent = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(.atRisk), now: t0.addingTimeInterval(10))
        XCTAssertNil(silent)
        let sample = recorder.entry(
            tool: .claude, snapshot: snapshot(), forecast: forecast(),
            evaluation: evaluation(.atRisk), now: t0.addingTimeInterval(300))
        XCTAssertEqual(sample?.warningFirstShownAt, t0.addingTimeInterval(10),
                       "the stamp is when the warning was shown, not when a row was next due")
    }

    func testARolloverInsideASilentGapIsNotInherited() {
        var recorder = makeRecorder()
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.atRisk, changed: true), now: t0)
        // The window rolls over at +60s and writes no row (no transition, clock not due). The
        // latch still has to see it, or the next row carries the previous window's stamp.
        XCTAssertNil(recorder.entry(
            tool: .claude, snapshot: snapshot(resetMinutes: 90 + 300), forecast: forecast(),
            evaluation: evaluation(.healthy), now: t0.addingTimeInterval(60)))
        let sample = recorder.entry(
            tool: .claude, snapshot: snapshot(resetMinutes: 90 + 300), forecast: forecast(),
            evaluation: evaluation(.healthy), now: t0.addingTimeInterval(300))
        XCTAssertNil(sample?.warningFirstShownAt)
    }

    /// The other half of the rule: a warning **still on screen** after the rollover is exposure
    /// in the new window, so it stamps again — at its own instant, not the old one.
    func testAWarningStillShowingAfterRolloverStampsTheNewWindow() {
        var recorder = makeRecorder()
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.atRisk, changed: true), now: t0)
        let after = recorder.entry(
            tool: .claude, snapshot: snapshot(resetMinutes: 90 + 300), forecast: forecast(),
            evaluation: evaluation(.atRisk), now: t0.addingTimeInterval(300))
        XCTAssertEqual(after?.warningFirstShownAt, t0.addingTimeInterval(300))
    }

    func testExposureIsPerTool() {
        var recorder = makeRecorder()
        _ = recorder.entry(tool: .claude, snapshot: snapshot(), forecast: forecast(),
                           evaluation: evaluation(.atRisk, changed: true), now: t0)
        let codex = recorder.entry(
            tool: .codex, snapshot: snapshot(tool: .codex), forecast: forecast(tool: .codex),
            evaluation: evaluation(.healthy), now: t0)
        XCTAssertNil(codex?.warningFirstShownAt)
    }

    // MARK: app_version

    func testAppVersionFormatting() {
        XCTAssertEqual(
            ForecastLogRecorder.appVersionString(shortVersion: "0.9.3", build: "142"),
            "0.9.3 (142)")
        XCTAssertEqual(
            ForecastLogRecorder.appVersionString(shortVersion: nil, build: nil),
            "0.0.0 (0)")
    }
}
