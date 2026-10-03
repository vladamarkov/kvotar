import XCTest
@testable import KvotarCore

/// §11.5's live half (REV-95 §3.3 — STEP_190): the untrimmed ring, the five guards, the account
/// state and the blend. Since REV-105 (STEP_230) the blend is Claude's five-hour rate —
/// `BlendDrivesRateTests` holds that half; the probability and the range stay rendered nowhere.
final class ShadowForecastTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(tool: Tool = .claude, used: Double?, reset: Date? = nil,
                          windowSeconds: Int? = nil, planType: String? = nil) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: used, primaryResetsAt: reset,
                      primaryWindowSeconds: windowSeconds, secondaryUsedPct: 10,
                      secondaryResetsAt: nil, rateLimitReached: false, extraUsage: .disabled,
                      planType: planType)
    }

    /// Feeds `count` polls at `every` seconds, rising by `step` points each, ending at `base`.
    /// Returns the engine primed exactly as a live run would have left it.
    private func primed(count: Int, every: TimeInterval = 120, step: Double = 0,
                        from startUsed: Double = 20, tool: Tool = .claude,
                        windowSeconds: Int? = nil) async -> ForecastEngine {
        let engine = ForecastEngine()
        for index in 0..<count {
            let at = base.addingTimeInterval(-Double(count - 1 - index) * every)
            let used = startUsed + step * Double(index)
            await engine.record(snapshot: snapshot(tool: tool, used: used,
                                                   reset: base.addingTimeInterval(3600),
                                                   windowSeconds: windowSeconds), at: at)
        }
        return engine
    }

    // MARK: The untrimmed ring

    func testRawRingKeepsWhatTheCountTrimDiscards() async {
        // 30 polls at 120 s = 58 minutes: the shipped buffer caps at 10, the ring keeps them all.
        let engine = await primed(count: 30, step: 1)
        let raw = await engine.rawSampleCount(for: .claude)
        XCTAssertEqual(raw, 30)
        // And the shipped burn is unchanged by the ring existing — still the trimmed buffer's.
        let forecast = await engine.forecast(for: snapshot(used: 49, reset: base))
        XCTAssertEqual(forecast.burnSpanMinutes ?? 0, 18, accuracy: 0.5)
    }

    func testRawRingAgesOutPastSampleMaxAge() async {
        // Two polls an hour and a half apart: the older is past `sampleMaxAge` when the newer lands.
        let engine = ForecastEngine()
        await engine.record(snapshot: snapshot(used: 20), at: base.addingTimeInterval(-5400))
        await engine.record(snapshot: snapshot(used: 30), at: base)
        let raw = await engine.rawSampleCount(for: .claude)
        XCTAssertEqual(raw, 1)
    }

    func testRawRingAgesOnANullWindowPollToo() async {
        // §11.2a Rule 2 / REV-54 §7: the sweep is outside the window guard, for both rings.
        let engine = ForecastEngine()
        await engine.record(snapshot: snapshot(used: 20), at: base.addingTimeInterval(-5400))
        await engine.record(snapshot: snapshot(used: nil), at: base)
        let raw = await engine.rawSampleCount(for: .claude)
        XCTAssertEqual(raw, 0)
    }

    func testRawRingClearsOnRolloverWithTheBuffer() async {
        let engine = ForecastEngine()
        await engine.record(snapshot: snapshot(used: 80, reset: base.addingTimeInterval(600)),
                            at: base.addingTimeInterval(-240))
        await engine.record(snapshot: snapshot(used: 90, reset: base.addingTimeInterval(600)),
                            at: base.addingTimeInterval(-120))
        let before = await engine.rawSampleCount(for: .claude)
        XCTAssertEqual(before, 2)
        // Utilization dropped — a new window's first reading.
        await engine.record(snapshot: snapshot(used: 2, reset: base.addingTimeInterval(18_600)),
                            at: base)
        let after = await engine.rawSampleCount(for: .claude)
        XCTAssertEqual(after, 1)
    }

    func testResetClearsBothRings() async {
        let engine = await primed(count: 5, step: 1)
        await engine.reset(tool: .claude)
        let raw = await engine.rawSampleCount(for: .claude)
        XCTAssertEqual(raw, 0)
    }

    func testSeedFillsBothRings() async {
        let seeds = (0..<20).map { index in
            ForecastEngine.SeedSample(usedPct: 20 + Double(index),
                                      polledAt: base.addingTimeInterval(-Double(19 - index) * 120),
                                      resetsAt: base.addingTimeInterval(3600), windowSeconds: 18_000)
        }
        let engine = ForecastEngine()
        await engine.seed(tool: .claude, samples: seeds, now: base)
        let raw = await engine.rawSampleCount(for: .claude)
        XCTAssertEqual(raw, 20)
    }

    // MARK: The five guards

    func testNilOnColdStart() async {
        let engine = await primed(count: 1)
        let shadow = await engine.shadow(for: snapshot(used: 20, reset: base.addingTimeInterval(3600)),
                                         tables: .empty, now: base)
        XCTAssertNil(shadow)
    }

    func testNilOnNullWindow() async {
        let engine = await primed(count: 20, step: 1)
        let shadow = await engine.shadow(for: snapshot(used: nil), tables: .empty, now: base)
        XCTAssertNil(shadow)
    }

    func testNilOnLowAllowanceShape() async {
        let engine = await primed(count: 20, step: 1, tool: .codex)
        // `free` is the §11.3 low-allowance plan name (REV-63 / D-64).
        let shape = snapshot(tool: .codex, used: 40, reset: base.addingTimeInterval(3600),
                             windowSeconds: 2_592_000, planType: "free")
        XCTAssertTrue(shape.isLowAllowanceShape)
        let shadow = await engine.shadow(for: shape, tables: .empty, now: base)
        XCTAssertNil(shadow)
    }

    func testNilOnLongWindow() async {
        // §3.3 scopes this revision to short windows; the weekly shadow waits on REV-95 §3.5.
        let weekly = 604_800
        let engine = await primed(count: 40, step: 0.5, tool: .codex, windowSeconds: weekly)
        let shadow = await engine.shadow(
            for: snapshot(tool: .codex, used: 40, reset: base.addingTimeInterval(3600),
                          windowSeconds: weekly),
            tables: .empty, now: base)
        XCTAssertNil(shadow)
    }

    func testNilWhenAccountStateIsUnknown() async {
        // Three polls two minutes apart reach back only six minutes — no neighbour near −30 min,
        // so the state is unknown and the row is missing rather than reported `quiet`.
        let engine = await primed(count: 3, step: 1)
        let shadow = await engine.shadow(for: snapshot(used: 22, reset: base.addingTimeInterval(3600)),
                                         tables: .empty, now: base)
        XCTAssertNil(shadow)
    }

    func testNilWhenTheNewestReadingIsStale() async {
        // A shadow describes *now*. Five minutes after the last poll it describes nothing —
        // the same recency discipline STEP_189 gave rank 6.
        let engine = await primed(count: 20, step: 1)
        let shadow = await engine.shadow(for: snapshot(used: 39, reset: base.addingTimeInterval(3600)),
                                         tables: .empty, now: base.addingTimeInterval(300))
        XCTAssertNil(shadow)
    }

    // MARK: Account state and the blend

    func testBurningWhenTheAccountMovedInTheLastTenMinutes() async {
        let engine = await primed(count: 20, step: 1)      // +1 point every 2 min
        let shadow = await engine.shadow(for: snapshot(used: 39, reset: base.addingTimeInterval(3600)),
                                         tables: .empty, now: base)
        // Burning reads the shipped prior's burning cell.
        XCTAssertEqual(shadow?.riseProbability ?? 0,
                       ShadowTables.prior.probability[.burning]!, accuracy: 0.0001)
    }

    func testQuietWhenNothingMovedInThirtyMinutes() async {
        let engine = await primed(count: 20, step: 0)
        let shadow = await engine.shadow(for: snapshot(used: 20, reset: base.addingTimeInterval(3600)),
                                         tables: .empty, now: base)
        XCTAssertEqual(shadow?.riseProbability ?? 0,
                       ShadowTables.prior.probability[.quiet]!, accuracy: 0.0001)
        // A flat 38 minutes is past the 600 s zero-proof, so both rates resolve to a measured zero.
        XCTAssertEqual(shadow?.blendRate ?? -1, 0, accuracy: 0.0001)
    }

    func testPausedWhenItMovedInThirtyMinutesButNotTen() async {
        // Rises early, then flat for the last twelve minutes.
        let engine = ForecastEngine()
        for index in 0..<20 {
            let at = base.addingTimeInterval(-Double(19 - index) * 120)
            let used = index < 14 ? 20 + Double(index) : 33.0
            await engine.record(snapshot: snapshot(used: used,
                                                   reset: base.addingTimeInterval(3600)), at: at)
        }
        let shadow = await engine.shadow(for: snapshot(used: 33, reset: base.addingTimeInterval(3600)),
                                         tables: .empty, now: base)
        XCTAssertEqual(shadow?.riseProbability ?? 0,
                       ShadowTables.prior.probability[.paused]!, accuracy: 0.0001)
    }

    func testBlendUsesTheStatesAlphaOverTheTwoRates() async {
        // Rising fast in the last stretch only: the trimmed buffer (18 min) sees a steeper rate
        // than the untrimmed hour does, so alpha actually chooses between two different numbers.
        let engine = ForecastEngine()
        for index in 0..<30 {
            let at = base.addingTimeInterval(-Double(29 - index) * 120)
            let used = index < 20 ? 20.0 : 20 + Double(index - 19) * 3
            await engine.record(snapshot: snapshot(used: used,
                                                   reset: base.addingTimeInterval(3600)), at: at)
        }
        let current = snapshot(used: 50, reset: base.addingTimeInterval(3600))

        // alpha = 1 → the short rate alone; alpha = 0 → the long rate alone.
        let allShort = ShadowTables(cells: [.burning: .init(hits: 90, n: 100, alpha: 1, rises: [])],
                                    allStateAlpha: 1, completedWindows: 20)
        let allLong = ShadowTables(cells: [.burning: .init(hits: 90, n: 100, alpha: 0, rises: [])],
                                   allStateAlpha: 0, completedWindows: 20)
        let short = await engine.shadow(for: current, tables: allShort, now: base)?.blendRate
        let long = await engine.shadow(for: current, tables: allLong, now: base)?.blendRate
        XCTAssertNotNil(short)
        XCTAssertNotNil(long)
        XCTAssertGreaterThan(short!, long!,
                             "the last eighteen minutes are steeper than the trailing hour")

        let half = ShadowTables(cells: [.burning: .init(hits: 90, n: 100, alpha: 0.5, rises: [])],
                                allStateAlpha: 0.5, completedWindows: 20)
        let blended = await engine.shadow(for: current, tables: half, now: base)?.blendRate
        XCTAssertEqual(blended ?? 0, (short! + long!) / 2, accuracy: 0.0001)
    }

    func testVersionStampIsWritten() async {
        let engine = await primed(count: 20, step: 1)
        let shadow = await engine.shadow(for: snapshot(used: 39, reset: base.addingTimeInterval(3600)),
                                         tables: .empty, now: base)
        XCTAssertEqual(shadow?.version, "s1")
    }

    /// Contract item 4: the shipped forecast the display and the engines read carries no shadow.
    /// Asserted on the type rather than a value, because that is where the guarantee lives.
    /// Since REV-105 (STEP_230) the blend reaches Claude's five-hour rate *through*
    /// `burnRatePerMin`, and `shortBurnRatePerMin` keeps the 18-minute rate for the log; the
    /// probability and the range still have no member here.
    func testShippedForecastHasNoShadowMember() async {
        let engine = await primed(count: 20, step: 1)
        let forecast = await engine.forecast(for: snapshot(used: 39, reset: base))
        let mirrored = Mirror(reflecting: forecast).children.compactMap(\.label)
        XCTAssertEqual(mirrored, ["tool", "tier", "runwayMinutes", "burnRatePerMin",
                                  "isEstimate", "pollCount", "burnSpanMinutes",
                                  "shortBurnRatePerMin"])
    }
}
