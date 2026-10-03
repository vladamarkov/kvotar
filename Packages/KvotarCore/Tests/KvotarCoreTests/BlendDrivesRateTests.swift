import XCTest
@testable import KvotarCore

/// REV-105 / STEP_230: on Claude's five-hour window the §11.5 blend is the rate the runway divides
/// by, the faster of the blend and the 18-minute rate takes over at ≥ 75 % used, and every case
/// the blend refuses falls back to the 18-minute rate unchanged. Codex and long windows keep the
/// 18-minute rate.
final class BlendDrivesRateTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(tool: Tool = .claude, used: Double?, reset: Date? = nil,
                          windowSeconds: Int? = nil) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: used, primaryResetsAt: reset,
                      primaryWindowSeconds: windowSeconds, secondaryUsedPct: 10,
                      secondaryResetsAt: nil, rateLimitReached: false, extraUsage: .disabled)
    }

    /// Feeds 30 polls at 120 s ending at `base` (58 minutes) and returns the last poll's forecast.
    private func run(tool: Tool = .claude, windowSeconds: Int? = nil,
                     used: (Int) -> Double) async -> (engine: ForecastEngine, forecast: Forecast) {
        let engine = ForecastEngine()
        var last: Forecast!
        for index in 0..<30 {
            let at = base.addingTimeInterval(-Double(29 - index) * 120)
            last = await engine.record(
                snapshot: snapshot(tool: tool, used: used(index),
                                   reset: base.addingTimeInterval(3600),
                                   windowSeconds: windowSeconds),
                at: at)
        }
        return (engine, last)
    }

    /// Flat for forty minutes, then +1 point per poll: the 18-minute rate is 0.5 %/min, the
    /// trailing hour's 10 / 58, and the account is burning — the prior's alpha is 0.
    private func lateRise(from start: Double) -> (Int) -> Double {
        { index in index < 20 ? start : start + Double(index - 19) }
    }

    // MARK: Which rate

    func testBelowTheFloorTheBlendIsChosen() async {
        let (engine, forecast) = await run(used: lateRise(from: 20))
        XCTAssertEqual(forecast.burnRatePerMin ?? 0, 10.0 / 58, accuracy: 0.0001)
        XCTAssertEqual(forecast.shortBurnRatePerMin ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(forecast.runwayMinutes ?? 0, 70 / (10.0 / 58), accuracy: 0.01)
        // One derivation: the rate the verdict used is the blend the log records.
        let shadow = await engine.shadow(
            for: snapshot(used: 30, reset: base.addingTimeInterval(3600)), tables: .empty, now: base)
        XCTAssertEqual(shadow?.blendRate, forecast.burnRatePerMin)
    }

    func testAtTheFloorTheShortRateWinsWhenItIsFaster() async {
        let (_, forecast) = await run(used: lateRise(from: 65))     // ends at 75
        XCTAssertEqual(forecast.burnRatePerMin ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(forecast.shortBurnRatePerMin, forecast.burnRatePerMin)
        XCTAssertEqual(forecast.runwayMinutes ?? 0, 50, accuracy: 0.01)
    }

    func testAtTheFloorTheBlendWinsWhenItIsFaster() async {
        // +1 per poll for forty minutes, then flat but for one last tick: the hour remembers the
        // spurt (20 / 58), the eighteen minutes barely see it (1 / 18).
        let (_, forecast) = await run { index in
            index < 20 ? 60 + Double(index) : (index < 29 ? 79 : 80)
        }
        XCTAssertEqual(forecast.burnRatePerMin ?? 0, 20.0 / 58, accuracy: 0.0001)
        XCTAssertEqual(forecast.shortBurnRatePerMin ?? 0, 1.0 / 18, accuracy: 0.0001)
    }

    // MARK: The span follows the chosen rate (D-130)

    func testSpanIsTheHourRingsWhenBlended() async {
        let (_, forecast) = await run(used: lateRise(from: 20))
        XCTAssertEqual(forecast.burnSpanMinutes ?? 0, 58, accuracy: 0.01)
    }

    func testSpanIsTheBuffersWhenTheShortRateWasTaken() async {
        let (_, nearLimit) = await run(used: lateRise(from: 65))
        XCTAssertEqual(nearLimit.burnSpanMinutes ?? 0, 18, accuracy: 0.01)
        // Quiet: the prior's alpha is 1, so the blend *is* the 18-minute rate.
        let (_, quiet) = await run { _ in 20 }
        XCTAssertEqual(quiet.burnRatePerMin, 0)
        XCTAssertEqual(quiet.burnSpanMinutes ?? 0, 18, accuracy: 0.01)
    }

    // MARK: Fallbacks — the 18-minute rate, unchanged

    func testUnderThirtyMinutesOfRingTheShortRateIsUsed() async {
        // Ten polls reach back 18 minutes: no neighbour near −30 min, the account state is unknown.
        let engine = ForecastEngine()
        var forecast: Forecast!
        for index in 0..<10 {
            forecast = await engine.record(
                snapshot: snapshot(used: 20 + Double(index), reset: base.addingTimeInterval(3600)),
                at: base.addingTimeInterval(-Double(9 - index) * 120))
        }
        XCTAssertEqual(forecast.burnRatePerMin, 9.0 / 18)
        XCTAssertEqual(forecast.shortBurnRatePerMin, 9.0 / 18)
        XCTAssertEqual(forecast.burnSpanMinutes, 18)
        XCTAssertEqual(forecast.runwayMinutes, 71 / (9.0 / 18))
    }

    func testAStaleNewestReadingUsesTheShortRate() async {
        // Five minutes after the last poll the blend describes nothing (§11.5's recency bound).
        let (engine, _) = await run(used: lateRise(from: 20))
        let forecast = await engine.forecast(
            for: snapshot(used: 30, reset: base.addingTimeInterval(3600)),
            tables: .empty, now: base.addingTimeInterval(300))
        XCTAssertEqual(forecast.burnRatePerMin, 0.5)
        XCTAssertEqual(forecast.burnSpanMinutes, 18)
    }

    func testBothRatesUnresolvedStaysUnmeasured() async {
        // Three flat polls: under the zero-proof on either ring, so there is no rate to choose.
        let engine = ForecastEngine()
        var forecast: Forecast!
        for index in 0..<3 {
            forecast = await engine.record(
                snapshot: snapshot(used: 20, reset: base.addingTimeInterval(3600)),
                at: base.addingTimeInterval(-Double(2 - index) * 120))
        }
        XCTAssertNil(forecast.burnRatePerMin)
        XCTAssertNil(forecast.shortBurnRatePerMin)
        XCTAssertNil(forecast.burnSpanMinutes)
        XCTAssertNil(forecast.runwayMinutes)
    }

    // MARK: Codex and long windows are unchanged

    func testCodexFiveHourKeepsTheShortRate() async {
        let (_, forecast) = await run(tool: .codex, windowSeconds: 18_000,
                                      used: lateRise(from: 20))
        XCTAssertEqual(forecast.burnRatePerMin ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(forecast.shortBurnRatePerMin, forecast.burnRatePerMin)
        XCTAssertEqual(forecast.burnSpanMinutes ?? 0, 18, accuracy: 0.01)
    }

    func testCodexSevenDayKeepsItsOwnRate() async {
        // The long policy already measures over the hour; nothing about it moves.
        let (_, forecast) = await run(tool: .codex, windowSeconds: 604_800,
                                      used: lateRise(from: 20))
        XCTAssertEqual(forecast.burnRatePerMin ?? 0, 10.0 / 58, accuracy: 0.0001)
        XCTAssertEqual(forecast.shortBurnRatePerMin, forecast.burnRatePerMin)
        XCTAssertEqual(forecast.burnSpanMinutes ?? 0, 58, accuracy: 0.01)
    }

    // MARK: The 2026-09-16 window (REV-105 §3.2)

    /// The owner's Claude polls from 15:55 to 17:34 local on 2026-09-16, as `quota_series`
    /// recorded them: `(polled_at, primary_used_pct)`. The only window of the graded fortnight
    /// that drew a warning.
    private static let sep16: [(at: TimeInterval, used: Double)] = [
        (1789566909, 46), (1789567033, 46), (1789567153, 46), (1789567282, 46), (1789567401, 46),
        (1789567531, 46), (1789567654, 46), (1789567783, 46), (1789567909, 46), (1789568034, 46),
        (1789568160, 46), (1789568293, 46), (1789568425, 46), (1789568548, 46), (1789568681, 46),
        (1789568814, 46), (1789568947, 46), (1789569081, 46), (1789569203, 46), (1789569326, 46),
        (1789569446, 46), (1789569566, 46), (1789569685, 46), (1789569808, 46), (1789569939, 46),
        (1789570069, 46), (1789570194, 58), (1789570319, 59), (1789570450, 74), (1789570583, 74),
        (1789570713, 75), (1789570845, 79), (1789570972, 80), (1789571104, 80), (1789571230, 82),
        (1789571355, 82), (1789571485, 82), (1789571608, 82), (1789571739, 82), (1789571856, 82),
        (1789571903, 83), (1789572023, 83), (1789572087, 84), (1789572218, 84), (1789572338, 84),
        (1789572466, 84), (1789572591, 84), (1789572715, 84), (1789572838, 84),
    ]

    /// §13 rank 4's own test, on a forecast's numbers.
    private func isAtRisk(used: Double, rate: Double?) -> Bool {
        guard used >= StateEngine.atRiskUtilFloor, let rate,
              rate > ForecastEngine.nearZeroBurnPerMin else { return false }
        return (100 - used) / rate < StateEngine.atRiskRunwayGateMin
    }

    func testSep16WarnsAtTheSameMinuteAndNeverLaterThanTheShortRate() async {
        let engine = ForecastEngine()
        let reset = Date(timeIntervalSince1970: 1789579199)
        var forecasts: [TimeInterval: (used: Double, forecast: Forecast)] = [:]
        for poll in Self.sep16 {
            let forecast = await engine.record(
                snapshot: snapshot(used: poll.used, reset: reset, windowSeconds: 18_000),
                at: Date(timeIntervalSince1970: poll.at))
            forecasts[poll.at] = (poll.used, forecast)
            // Never later than the 18-minute rate alone: wherever it warns, so does the choice.
            if isAtRisk(used: poll.used, rate: forecast.shortBurnRatePerMin) {
                XCTAssertTrue(isAtRisk(used: poll.used, rate: forecast.burnRatePerMin),
                              "short rate warned at \(poll.at) and the chosen rate did not")
            }
        }

        // The fixture reproduces what the app logged at 16:58:33 — burn 1.5173, blend 0.4887.
        let first = forecasts[1789570713]!.forecast
        XCTAssertEqual(first.shortBurnRatePerMin ?? 0, 1.5173, accuracy: 0.001)
        XCTAssertEqual(first.burnRatePerMin ?? 0, 1.5173, accuracy: 0.001)

        // The `forecast_log` rows of 16:56–17:33, by local time.
        let rows: [(at: TimeInterval, atRisk: Bool)] = [
            (1789570583, false),    // 16:56 — 74 % used, under the floor
            (1789570713, true),     // 16:58
            (1789571104, true),     // 17:05
            (1789571485, true),     // 17:11
            (1789571856, false),    // 17:17
            (1789572087, true),     // 17:21 — the hour still remembers the spurt
            (1789572466, true),     // 17:27
            (1789572838, false),    // 17:33
        ]
        for row in rows {
            let (used, forecast) = forecasts[row.at]!
            XCTAssertEqual(isAtRisk(used: used, rate: forecast.burnRatePerMin), row.atRisk,
                           "row at \(row.at)")
            XCTAssertEqual(forecast.runwayMinutes != nil && forecast.runwayMinutes! < 30
                           && used >= 75, row.atRisk, "runway at \(row.at)")
        }
    }
}
