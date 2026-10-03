import XCTest
@testable import KvotarCore

final class ForecastEngineTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// A week, in seconds — the width the dogfood Codex Plus account reports (REV-74 §2).
    private let weekly = 604_800

    /// `windowSeconds` defaults to nil, so every pre-REV-74 case keeps the five-hour fallback
    /// (`primaryWindowLength == 18_000`) and therefore the short buffer policy. That default is
    /// what guarantees no five-hour behaviour moved: a long-window case has to opt in.
    private func snapshot(
        tool: Tool = .claude,
        used: Double?,
        secondary: Double? = 10,
        reset: Date? = nil,
        planType: String? = nil,
        windowSeconds: Int? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: tool,
            primaryUsedPct: used,
            primaryResetsAt: reset,
            primaryWindowSeconds: windowSeconds,
            secondaryUsedPct: secondary,
            secondaryResetsAt: nil,
            rateLimitReached: false,
            extraUsage: .disabled,
            planType: planType
        )
    }

    // MARK: Cold start (§11.4)

    func testColdStartZeroToOnePollShowsNoRunway() async {
        let engine = ForecastEngine()
        let f = await engine.record(snapshot: snapshot(used: 40), at: base)
        XCTAssertEqual(f.pollCount, 1)
        XCTAssertNil(f.runwayMinutes, "0–1 polls: reset countdown only, never runway")
        XCTAssertNil(f.burnRatePerMin)
        XCTAssertFalse(f.isEstimate)
        XCTAssertEqual(f.tier, .fullRunway)
    }

    func testTwoToNinePollsMarkedEstimate() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        let f = await engine.record(snapshot: snapshot(used: 50), at: base.addingTimeInterval(60))
        XCTAssertEqual(f.pollCount, 2)
        XCTAssertTrue(f.isEstimate, "2–9 polls carry the ~est. label")
        // 10%/min burn, 50% remaining → 5 minutes runway.
        XCTAssertEqual(f.runwayMinutes ?? 0, 5, accuracy: 0.01)
        XCTAssertEqual(f.burnRatePerMin ?? 0, 10, accuracy: 0.01)
    }

    func testTenPollsRemovesEstimateLabel() async {
        let engine = ForecastEngine()
        for i in 0..<10 {
            _ = await engine.record(
                snapshot: snapshot(used: Double(i)),
                at: base.addingTimeInterval(Double(i) * 60))
        }
        let f = await engine.forecast(for: snapshot(used: 9))
        XCTAssertEqual(f.pollCount, 10)
        XCTAssertFalse(f.isEstimate, "10+ polls: estimate label removed")
    }

    func testBufferTrimIsSpanAware() async {
        // REV-65/STEP_106: the trim may not shrink the span below `zeroBurnRetentionSpan` (660s),
        // or the §11.2a zero-proof (600s) is unfinishable at the 60s base cadence — 10 samples
        // span 540s, one minute short forever, and idle Codex sat on "Measuring…" for 80% of an
        // evening. At 60s the buffer settles at 12 samples (span 660s); the count cap alone would
        // leave 10.
        let engine = ForecastEngine()
        for i in 0..<20 {
            _ = await engine.record(
                snapshot: snapshot(used: Double(i)),
                at: base.addingTimeInterval(Double(i) * 60))
        }
        let f = await engine.forecast(for: snapshot(used: 19))
        XCTAssertEqual(f.pollCount, 12, "60s cadence: retention holds 12 samples to span 660s")
    }

    func testBufferCapsAtTenSamplesAtTwoMinuteCadence() async {
        // At every cadence ≥ 120s ten samples already span the zero-proof, so the count cap
        // governs exactly as before REV-65.
        let engine = ForecastEngine()
        for i in 0..<15 {
            _ = await engine.record(
                snapshot: snapshot(used: Double(i)),
                at: base.addingTimeInterval(Double(i) * 120))
        }
        let f = await engine.forecast(for: snapshot(used: 14))
        XCTAssertEqual(f.pollCount, 10, "≥120s cadence: buffer never exceeds 10 samples")
    }

    func testFlatMeterProvesZeroBurnAtBaseCadence() async {
        // The defect itself, pinned end to end: a meter flat at 60s polling must eventually earn
        // "Nothing burning" (burn = 0), not sit on `Measuring…` (burn = nil) forever.
        let engine = ForecastEngine()
        var f: Forecast?
        for i in 0..<12 {
            f = await engine.record(
                snapshot: snapshot(used: 7),
                at: base.addingTimeInterval(Double(i) * 60))
        }
        XCTAssertEqual(f?.burnRatePerMin ?? -1, 0, accuracy: 0.0001,
                       "11 minutes of flat 60s polls span the zero-proof and earn a measured zero")
    }

    // MARK: Burn window (REV-18 — off-machine span alignment)

    func testBurnWindowExposesBufferSpanAndDelta() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 32), at: base)
        _ = await engine.record(snapshot: snapshot(used: 35), at: base.addingTimeInterval(120))
        _ = await engine.record(snapshot: snapshot(used: 39), at: base.addingTimeInterval(240))

        let w = await engine.burnWindow(for: .claude)

        XCTAssertEqual(w?.start, base)
        XCTAssertEqual(w?.end, base.addingTimeInterval(240))
        XCTAssertEqual(w?.usedPctDelta ?? 0, 7, accuracy: 0.0001)
    }

    func testBurnWindowNilUnderTwoSamples() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 32), at: base)
        let w = await engine.burnWindow(for: .claude)
        XCTAssertNil(w, "no burn rate exists under two samples — no window either")
    }

    // MARK: Burn span on the Forecast (STEP_110 — the anatomy's "Burn (last 9m)" label)

    func testForecastCarriesTheBurnSpanItWasMeasuredOver() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 32), at: base)
        _ = await engine.record(snapshot: snapshot(used: 35), at: base.addingTimeInterval(120))
        let f = await engine.record(snapshot: snapshot(used: 39), at: base.addingTimeInterval(540))
        XCTAssertNotNil(f.burnRatePerMin)
        XCTAssertEqual(f.burnSpanMinutes ?? -1, 9, accuracy: 0.0001,
                       "first→last sample span, the same denominator the rate used")
    }

    func testForecastBurnSpanIsNilWhereverBurnIs() async {
        let engine = ForecastEngine()
        // Cold start: one sample, no rate, no span.
        let cold = await engine.record(snapshot: snapshot(used: 32), at: base)
        XCTAssertNil(cold.burnRatePerMin)
        XCTAssertNil(cold.burnSpanMinutes)
        // Flat reading inside the §11.2a resolvable span: rate unresolved → span withheld too.
        let flat = await engine.record(snapshot: snapshot(used: 32), at: base.addingTimeInterval(120))
        XCTAssertNil(flat.burnRatePerMin)
        XCTAssertNil(flat.burnSpanMinutes, "a span without a rate is a claim about a measurement that did not resolve")
    }

    func testBurnWindowDeltaClampsAcrossReset() async {
        let engine = ForecastEngine()
        // A utilization drop clears the buffer in `record` (window rollover), so the surviving
        // window never spans the reset — the delta can only be the post-reset rise.
        _ = await engine.record(snapshot: snapshot(used: 90), at: base)
        _ = await engine.record(snapshot: snapshot(used: 2), at: base.addingTimeInterval(120))
        _ = await engine.record(snapshot: snapshot(used: 5), at: base.addingTimeInterval(240))

        let w = await engine.burnWindow(for: .claude)

        XCTAssertEqual(w?.start, base.addingTimeInterval(120))
        XCTAssertEqual(w?.usedPctDelta ?? -1, 3, accuracy: 0.0001)
    }

    // MARK: Runway formula (§11.2/§11.3)

    func testNearZeroBurnSuppressesRunway() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        // Flat across a span long enough for one 1% quantum to have landed (§11.2a): now zero
        // burn is earned, and the runway is suppressed in favour of the reset countdown.
        let f = await engine.record(snapshot: snapshot(used: 40), at: base.addingTimeInterval(600))
        XCTAssertNil(f.runwayMinutes, "flat utilization → show reset countdown, not runway")
        XCTAssertEqual(f.burnRatePerMin ?? -1, 0, accuracy: 0.0001)
    }

    // MARK: Quantization guard (§11.2a, REV-35)

    func testFlatShortSpanReportsUnknownBurnNotZero() async {
        // The 2026-07-14 incident: two polls four minutes apart, both reading 44%. Utilization is
        // quantized to whole percent, so this bounds burn below 0.25 %/min — it does not establish
        // zero. The account was in fact burning ~0.5 %/min, and the app rendered "No active burn".
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 44), at: base)
        let f = await engine.record(snapshot: snapshot(used: 44), at: base.addingTimeInterval(243))
        XCTAssertEqual(f.pollCount, 2)
        XCTAssertNil(f.burnRatePerMin, "a flat reading this short cannot resolve zero burn")
        XCTAssertNil(f.runwayMinutes)
    }

    func testFlatLongSpanEarnsZeroBurn() async {
        // 1% over 10 min is 0.1 %/min — the "none" tier boundary. Once a flat reading spans that,
        // it is real evidence of no burn, and the burn≈0 verdict is honest.
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 44), at: base)
        let f = await engine.record(snapshot: snapshot(used: 44), at: base.addingTimeInterval(600))
        XCTAssertEqual(f.burnRatePerMin ?? -1, 0, accuracy: 0.0001,
                       "a flat reading over the resolvable span is genuine zero burn")
    }

    func testAnyRiseIsReportedRegardlessOfSpan() async {
        // The guard is on *zero* deltas only — a 1% rise over one minute still reports 1 %/min.
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 44), at: base)
        let f = await engine.record(snapshot: snapshot(used: 45), at: base.addingTimeInterval(60))
        XCTAssertEqual(f.burnRatePerMin ?? 0, 1, accuracy: 0.0001)
    }

    func testWindowResetClearsBufferAndRestartsCleanly() async {
        // A utilization drop is a window rollover: the pre-reset samples are cleared so the
        // burn average never straddles the boundary (it used to read ~0 for up to 10 polls).
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 80), at: base)
        let f = await engine.record(snapshot: snapshot(used: 5), at: base.addingTimeInterval(60))
        XCTAssertEqual(f.pollCount, 1, "buffer restarts with only the post-reset sample")
        XCTAssertNil(f.burnRatePerMin)
        XCTAssertNil(f.runwayMinutes)
    }

    func testBurnAfterResetComputedFromPostResetSamplesOnly() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 70), at: base)
        _ = await engine.record(snapshot: snapshot(used: 80), at: base.addingTimeInterval(60))
        // Rollover, then two fresh samples: 5 → 15 over 1 min = 10%/min. With the old straddling
        // buffer this read (15 − 70) → clamp 0 and suppressed the runway.
        _ = await engine.record(snapshot: snapshot(used: 5), at: base.addingTimeInterval(120))
        let f = await engine.record(snapshot: snapshot(used: 15), at: base.addingTimeInterval(180))
        XCTAssertEqual(f.burnRatePerMin ?? 0, 10, accuracy: 0.01,
                       "post-reset burn must not be diluted by pre-reset samples")
        XCTAssertEqual(f.pollCount, 2)
    }

    func testResetsAtAdvanceClearsBuffer() async {
        // Same utilization before/after (no drop) — the resets_at advance alone must clear.
        let engine = ForecastEngine()
        let reset1 = base.addingTimeInterval(3600)
        let reset2 = base.addingTimeInterval(3600 + 18000)
        _ = await engine.record(snapshot: snapshot(used: 40, reset: reset1), at: base)
        _ = await engine.record(snapshot: snapshot(used: 42, reset: reset1), at: base.addingTimeInterval(60))
        let f = await engine.record(
            snapshot: snapshot(used: 42, reset: reset2), at: base.addingTimeInterval(120))
        XCTAssertEqual(f.pollCount, 1, "a resets_at advance is a rollover even without a util drop")
    }

    func testResetsAtJitterDoesNotClearBuffer() async {
        let engine = ForecastEngine()
        let reset1 = base.addingTimeInterval(3600)
        _ = await engine.record(snapshot: snapshot(used: 40, reset: reset1), at: base)
        let f = await engine.record(
            snapshot: snapshot(used: 50, reset: reset1.addingTimeInterval(1)),
            at: base.addingTimeInterval(60))
        XCTAssertEqual(f.pollCount, 2, "±1s server wobble is not a rollover")
        XCTAssertEqual(f.burnRatePerMin ?? 0, 10, accuracy: 0.01)
    }

    // MARK: Buffer ageing across gaps (§11.2a, REV-35)

    func testShortSleepGapKeepsAnchor() async {
        // The 2026-07-14 incident's gap: the Mac idle-slept ~10 min, which used to wipe the buffer
        // and leave burn reading 0 for up to 10 polls. The samples either side of a gap this short
        // are still in the same window, and the account delta across it is exact — keep the anchor.
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 31), at: base)
        _ = await engine.record(snapshot: snapshot(used: 39), at: base.addingTimeInterval(260))
        let f = await engine.record(snapshot: snapshot(used: 44), at: base.addingTimeInterval(874))
        XCTAssertEqual(f.pollCount, 3, "a 10-minute gap does not wipe the buffer")
        // 13% over 14.57 min ≈ 0.89 %/min — the real rate, not the 0.0 the old wipe produced.
        XCTAssertEqual(f.burnRatePerMin ?? 0, 13 / (874 / 60), accuracy: 0.01)
    }

    func testSamplesOlderThanMaxAgeAreDropped() async {
        // An overnight sleep: every buffered sample ages out, leaving a clean cold start rather
        // than an average smeared across eight idle hours.
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        _ = await engine.record(snapshot: snapshot(used: 45), at: base.addingTimeInterval(60))
        let f = await engine.record(snapshot: snapshot(used: 46),
                                    at: base.addingTimeInterval(8 * 3600))
        XCTAssertEqual(f.pollCount, 1, "samples past sampleMaxAge are dropped")
        XCTAssertNil(f.burnRatePerMin)
    }

    func testFullBufferSurvivesSlowestLegalCadence() async {
        // 10 polls at the 300s ceiling span 45 min — under sampleMaxAge, so the `~est.` label
        // still clears at poll 10. An age bound below that would strand the app in estimate mode.
        let engine = ForecastEngine()
        for i in 0..<10 {
            _ = await engine.record(snapshot: snapshot(used: Double(i)),
                                    at: base.addingTimeInterval(Double(i) * 300))
        }
        let f = await engine.forecast(for: snapshot(used: 9))
        XCTAssertEqual(f.pollCount, 10, "a full buffer at the slowest legal cadence is not aged out")
        XCTAssertFalse(f.isEstimate)
    }

    func testResetClearsBufferForTool() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        _ = await engine.record(snapshot: snapshot(used: 50), at: base.addingTimeInterval(60))
        await engine.reset(tool: .claude)
        let f = await engine.forecast(for: snapshot(used: 50))
        XCTAssertEqual(f.pollCount, 0, "cache invalidation empties the rolling buffer")
    }

    // MARK: Buffer ageing across *null-window* runs (REV-54 §7 — STEP_81)

    /// **The regression pin.** The sweep used to sit inside `record`'s `usedPct` guard, so a poll
    /// carrying no window neither appended nor decayed and the buffer froze on the moment before
    /// the window closed. Live 2026-07-23: 65 minutes of a re-served `0.032 %/min` feeding a grey
    /// "none" pill and nine `forecast_log` rows stamping a measurement the app never made.
    ///
    /// Shape matters here. This is the *Claude Enterprise* idle case — 5-hour window null,
    /// **weekly still live** — so `isNullWindow` (which needs both nil) is false and the tier
    /// lands on `.unknown` rather than `.creditBased`. (The §11.1 tier this test used to watch
    /// stop firing is gone — REV-80 / D-101; what remains pinned is the ageing itself. Consumer
    /// Claude's overnight shape now carries `0%` and appends a sample instead — see
    /// `testNotStartedPollAppendsAZeroSampleAndClearsOnDrop`.)
    func testNullWindowRunAgesTheBufferOut() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40, planType: "max"), at: base)
        _ = await engine.record(snapshot: snapshot(used: 50, planType: "max"),
                                at: base.addingTimeInterval(60))
        // Pre-fix this buffer would still read 10 %/min an hour later.
        var f = await engine.record(snapshot: snapshot(used: nil, planType: "max"),
                                    at: base.addingTimeInterval(1800))
        XCTAssertEqual(f.pollCount, 2, "half an hour in, the samples are still fresh")

        f = await engine.record(snapshot: snapshot(used: nil, planType: "max"),
                                at: base.addingTimeInterval(3600 + 120))
        XCTAssertEqual(f.pollCount, 0, "every sample is past sampleMaxAge — time passed for them")
        XCTAssertNil(f.burnRatePerMin, "no samples ⇒ no burn rate ⇒ REV-35 'Measuring…', not 'none'")
        XCTAssertEqual(f.tier, .unknown, "5-hour null with a live weekly is not the Codex null case")
    }

    /// The fix must not blind the engine across an ordinary one- or two-poll null gap — that is
    /// the REV-35 property the whole design rests on (`staleSampleGap` was retired for exactly
    /// this). Under `sampleMaxAge` the anchor survives. The null poll itself reports no burn —
    /// a nil percent has no denominator, and the §11.1 tier that once estimated one is retired
    /// (REV-80 §3.3) — the proof is the *next* live poll, measured across the gap.
    func testShortNullRunKeepsTheBuffer() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40, planType: "max"), at: base)
        _ = await engine.record(snapshot: snapshot(used: 50, planType: "max"),
                                at: base.addingTimeInterval(60))
        let f = await engine.record(snapshot: snapshot(used: nil, planType: "max"),
                                    at: base.addingTimeInterval(300))
        XCTAssertEqual(f.pollCount, 2, "a 4-minute null gap is not a reason to discard history")
        XCTAssertEqual(f.tier, .unknown)
        XCTAssertNil(f.burnRatePerMin, "no percent this poll, no burn this poll")

        let next = await engine.record(snapshot: snapshot(used: 60, planType: "max"),
                                       at: base.addingTimeInterval(360))
        XCTAssertEqual(next.pollCount, 3, "the anchor survived the gap")
        // (60 − 40) % over 6 min, first sample to last — the gap is inside the measurement.
        XCTAssertEqual(next.burnRatePerMin ?? 0, 20.0 / 6.0, accuracy: 0.01)
    }

    /// REV-80 / D-101 side effect, accepted and stated (REV-80 §3.4): a not-started poll carries
    /// `0%`, so it appends a sample and the drop-on-decrease clear wipes the buffer on the first
    /// such poll after a live window — the window ended. Codex has done this since REV-57.
    /// One sample after the clear is a §11.4 cold start: reset countdown only, never a runway —
    /// the `.fullRunway` / nil-runway shape `testColdStartZeroToOnePollShowsNoRunway` pins.
    func testNotStartedPollAppendsAZeroSampleAndClearsOnDrop() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40, planType: "max"), at: base)
        _ = await engine.record(snapshot: snapshot(used: 50, planType: "max"),
                                at: base.addingTimeInterval(60))
        let notStarted = QuotaSnapshot(tool: .claude, primaryUsedPct: 0, primaryResetsAt: nil,
                                       primaryWindowSeconds: 18_000,
                                       secondaryUsedPct: 30, secondaryResetsAt: nil,
                                       rateLimitReached: false, planType: "max")
        let f = await engine.record(snapshot: notStarted, at: base.addingTimeInterval(120))
        XCTAssertEqual(f.pollCount, 1, "the drop clears the old window; the 0% sample seeds the next")
        XCTAssertEqual(f.tier, .fullRunway, "one sample is a cold start, not an unknown window")
        XCTAssertNil(f.runwayMinutes)
        XCTAssertNil(f.burnRatePerMin)
    }

    /// Regression pin on what deliberately stayed *inside* the guard: both clears need a `usedPct`
    /// to compare against, so they still fire on the first non-null poll of a new window.
    func testRolloverAndDropClearsStillFireAfterANullRun() async {
        // Rollover: `resets_at` advances past resetJitterTolerance.
        let engine = ForecastEngine()
        let firstReset = base.addingTimeInterval(1800)
        _ = await engine.record(snapshot: snapshot(used: 40, reset: firstReset), at: base)
        _ = await engine.record(snapshot: snapshot(used: 50, reset: firstReset),
                                at: base.addingTimeInterval(60))
        _ = await engine.record(snapshot: snapshot(used: nil), at: base.addingTimeInterval(120))
        let rolled = await engine.record(
            snapshot: snapshot(used: 2, reset: firstReset.addingTimeInterval(18_000)),
            at: base.addingTimeInterval(180))
        XCTAssertEqual(rolled.pollCount, 1, "a new window starts a new average, not a continuation")

        // Drop: utilization goes backwards without a reset advance.
        let other = ForecastEngine()
        _ = await other.record(snapshot: snapshot(used: 40), at: base)
        _ = await other.record(snapshot: snapshot(used: 50), at: base.addingTimeInterval(60))
        _ = await other.record(snapshot: snapshot(used: nil), at: base.addingTimeInterval(120))
        let dropped = await other.record(snapshot: snapshot(used: 3),
                                         at: base.addingTimeInterval(180))
        XCTAssertEqual(dropped.pollCount, 1, "a utilization drop still clears the buffer")
    }

    /// Codex is unchanged (§11.3): a null-window run still suspends runway rather than inferring,
    /// whatever the buffer holds. The sweep is tool-agnostic; the *tier* rule is not.
    func testCodexNullRunStillSuspendsRunway() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(tool: .codex, used: 40), at: base)
        _ = await engine.record(snapshot: snapshot(tool: .codex, used: 50),
                                at: base.addingTimeInterval(60))
        let f = await engine.record(snapshot: snapshot(tool: .codex, used: nil, secondary: nil),
                                    at: base.addingTimeInterval(3600 + 120))
        XCTAssertEqual(f.tier, .creditBased, "Codex never infers — a null window displays `—`")
        XCTAssertNil(f.runwayMinutes)
        XCTAssertEqual(f.pollCount, 0, "the sweep is tool-agnostic")
    }

    // MARK: Null window (§11.3)

    func testNullWindowSuspendsRunway() async {
        let engine = ForecastEngine()
        let f = await engine.record(
            snapshot: snapshot(tool: .codex, used: nil, secondary: nil), at: base)
        XCTAssertNil(f.runwayMinutes)
        XCTAssertNil(f.burnRatePerMin)
        XCTAssertEqual(f.tier, .creditBased)
        XCTAssertEqual(f.pollCount, 0, "null-window poll contributes no sample")
    }

    func testNullWindowPollDoesNotPolluteBuffer() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(tool: .codex, used: 40), at: base)
        _ = await engine.record(
            snapshot: snapshot(tool: .codex, used: nil, secondary: nil),
            at: base.addingTimeInterval(60))
        let f = await engine.record(
            snapshot: snapshot(tool: .codex, used: 60), at: base.addingTimeInterval(120))
        // Only two real samples (40 → 60 over 2 min) contribute: 10%/min.
        XCTAssertEqual(f.burnRatePerMin ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(f.pollCount, 2)
    }

    // MARK: Fast-burn delta helper

    func testUtilDeltaOverWindow() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        _ = await engine.record(snapshot: snapshot(used: 65), at: base.addingTimeInterval(90))
        let delta = await engine.utilDelta(
            for: .claude, overSeconds: 120, now: base.addingTimeInterval(90))
        XCTAssertEqual(delta ?? 0, 25, accuracy: 0.01)
    }

    func testUtilDeltaNilWithSingleSample() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        let delta = await engine.utilDelta(for: .claude, overSeconds: 120, now: base)
        XCTAssertNil(delta)
    }

    func testBuffersAreIndependentPerTool() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(tool: .claude, used: 40), at: base)
        let codex = await engine.record(snapshot: snapshot(tool: .codex, used: 10), at: base)
        XCTAssertEqual(codex.pollCount, 1, "codex buffer unaffected by claude samples")
    }

    // MARK: Two-poll delta (Off-machine rise signal, §13 rule 7)

    func testUtilDeltaLast2PollsUsesMostRecentPair() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        _ = await engine.record(snapshot: snapshot(used: 45), at: base.addingTimeInterval(60))
        _ = await engine.record(snapshot: snapshot(used: 52), at: base.addingTimeInterval(120))
        let delta = await engine.utilDeltaLast2Polls(for: .claude)
        XCTAssertEqual(delta ?? 0, 7, accuracy: 0.01, "delta is over the last two polls only")
    }

    func testUtilDeltaLast2PollsNilWithSingleSample() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        let delta = await engine.utilDeltaLast2Polls(for: .claude)
        XCTAssertNil(delta)
    }

    func testUtilDeltaLast2PollsNilAfterReset() async {
        // A utilization drop clears the buffer, so the post-reset sample stands alone — the
        // delta is nil (not a negative rise) until a second post-reset poll lands.
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 80), at: base)
        _ = await engine.record(snapshot: snapshot(used: 3), at: base.addingTimeInterval(60))
        let delta = await engine.utilDeltaLast2Polls(for: .claude)
        XCTAssertNil(delta, "a window reset must not read as a rise")
    }

    // MARK: Bounded two-poll delta (Fast-burn spike, §13 rank 6 — STEP_189)

    private func fastBurnDelta(_ engine: ForecastEngine, at now: Date) async -> Double? {
        await engine.utilDeltaLast2Polls(
            for: .claude, withinSeconds: ForecastEngine.fastBurnMaxPollGap, now: now)
    }

    func testFastBurnDeltaAtTheBaseCadence() async {
        // The case the old rule could not see: two polls exactly one base tick apart (REV-89),
        // which never both fit inside a 120s wall-clock window.
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        let at = base.addingTimeInterval(120)
        _ = await engine.record(snapshot: snapshot(used: 62), at: at)
        let delta = await fastBurnDelta(engine, at: at)
        XCTAssertEqual(delta ?? 0, 22, accuracy: 0.01)
    }

    func testFastBurnDeltaAtTheOldCadence() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        let at = base.addingTimeInterval(60)
        _ = await engine.record(snapshot: snapshot(used: 62), at: at)
        let delta = await fastBurnDelta(engine, at: at)
        XCTAssertEqual(delta ?? 0, 22, accuracy: 0.01, "a 60s gap still measures")
    }

    func testFastBurnDeltaNilBeyondTheGap() async {
        // 310s apart: the two polls no longer describe one burst, so the pair makes no claim.
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        let at = base.addingTimeInterval(310)
        _ = await engine.record(snapshot: snapshot(used: 62), at: at)
        let delta = await fastBurnDelta(engine, at: at)
        XCTAssertNil(delta, "a pair spanning more than the gap bound claims nothing")
    }

    func testFastBurnDeltaNilOnAStalePair() async {
        // The pair is close together but the newer poll is 40 minutes old — a JSONL-triggered
        // evaluation must not re-assert a spike that ended (the clock-relative rule this
        // replaced expired on its own; this bound is what restores that).
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        _ = await engine.record(snapshot: snapshot(used: 62), at: base.addingTimeInterval(120))
        let delta = await fastBurnDelta(engine, at: base.addingTimeInterval(2_520))
        XCTAssertNil(delta, "a spike that ended is not a spike now")
    }

    func testFastBurnDeltaReportsBelowThresholdRisesFaithfully() async {
        // The engine measures; the 20-point threshold is StateEngine's. A 19-point rise is a
        // real measurement that simply does not clear the gate.
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 40), at: base)
        let at = base.addingTimeInterval(120)
        _ = await engine.record(snapshot: snapshot(used: 59), at: at)
        let delta = await fastBurnDelta(engine, at: at)
        XCTAssertEqual(delta ?? 0, 19, accuracy: 0.01)
        XCTAssertLessThan(delta ?? 0, StateEngine.fastBurnDeltaPct)
    }

    func testFastBurnDeltaNilAcrossAReset() async {
        // A utilization drop clears the buffer, so the post-reset sample stands alone.
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(used: 80), at: base)
        let at = base.addingTimeInterval(120)
        _ = await engine.record(snapshot: snapshot(used: 3), at: at)
        let delta = await fastBurnDelta(engine, at: at)
        XCTAssertNil(delta, "a window rollover must not read as a spike")
    }

    // (The §11.1 Inferred-runway block that stood here — `unloadedLimits`, the "lost window"
    // trio and the personal-ceiling case — was deleted with the tier: REV-80 / D-101, STEP_147.)

    // MARK: Long-window buffer — an hour of evidence (§11.2a, REV-74/D-84)

    /// The 2026-08-19 dogfood evening, replayed as the weekly window it actually was
    /// (`quota_series`, Codex Plus — REV-74 §2). Polls every 60s holding the last reading between
    /// ticks; the eleven observed transitions are the data. At 22:19 the window had moved 21 → 25
    /// across the preceding hour, which is the rate a person would recognise as "a working
    /// evening". The eleven-minute buffer saw one tick and called it something else.
    private func replayEvening(policyWindowSeconds: Int?) async -> Forecast {
        // minutes after 20:55 → used %, from the observed series.
        let ticks: [(Int, Double)] = [(0, 17), (3, 18), (5, 19), (12, 20), (19, 21),
                                      (32, 22), (42, 23), (71, 24), (84, 25)]
        let engine = ForecastEngine()
        var used: Double = 16
        var last = Forecast(tool: .codex, tier: .unknown, runwayMinutes: nil,
                            burnRatePerMin: nil, isEstimate: false, pollCount: 0)
        for minute in 0...84 {
            if let tick = ticks.first(where: { $0.0 == minute }) { used = tick.1 }
            last = await engine.record(
                snapshot: snapshot(tool: .codex, used: used, secondary: nil,
                                   windowSeconds: policyWindowSeconds),
                at: base.addingTimeInterval(Double(minute) * 60))
        }
        return last
    }

    func testWeeklyWindowMeasuresTheEveningOverAnHour() async {
        let f = await replayEvening(policyWindowSeconds: weekly)
        // 21 % at 21:20 → 25 % at 22:19: 4 points over the 59-minute span.
        XCTAssertEqual(f.pollCount, 60, "a weekly window keeps an hour of samples")
        XCTAssertEqual(f.burnRatePerMin ?? -1, 0.0678, accuracy: 0.002,
                       "4 points over 59 min — what the evening actually did")
    }

    func testTheSameEveningOnAFiveHourBufferSeesOneTick() async {
        // The defect, pinned: the identical series through the eleven-minute buffer. One tick
        // (24 → 25) over 660s reads 0.091 %/min, and a minute later reads zero — the flapping
        // the "Since you last looked" banner reported as `burn low → none`.
        let f = await replayEvening(policyWindowSeconds: nil)
        XCTAssertEqual(f.pollCount, 12, "the five-hour buffer is unchanged: 12 samples at 60s")
        XCTAssertEqual(f.burnRatePerMin ?? -1, 0.0909, accuracy: 0.002,
                       "one tick over eleven minutes — the reading this step replaces")
    }

    func testWeeklyFlatSpanUnderTheProofIsUnknownNotZero() async {
        // 49 minutes flat on a weekly window bounds burn below 0.02 %/min — still twice that
        // window's even pace, so it cannot support a calm claim (§11.2a Rule 1).
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(tool: .codex, used: 25, secondary: nil,
                                                   windowSeconds: weekly), at: base)
        let f = await engine.record(
            snapshot: snapshot(tool: .codex, used: 25, secondary: nil, windowSeconds: weekly),
            at: base.addingTimeInterval(2940))
        XCTAssertNil(f.burnRatePerMin, "under the long zero-proof a flat reading claims nothing")
    }

    func testWeeklyFlatSpanOverTheProofEarnsZeroBurn() async {
        let engine = ForecastEngine()
        _ = await engine.record(snapshot: snapshot(tool: .codex, used: 25, secondary: nil,
                                                   windowSeconds: weekly), at: base)
        let f = await engine.record(
            snapshot: snapshot(tool: .codex, used: 25, secondary: nil, windowSeconds: weekly),
            at: base.addingTimeInterval(3060))
        XCTAssertEqual(f.burnRatePerMin ?? -1, 0, accuracy: 0.0001,
                       "51 flat minutes is the long window's earned zero")
    }

    /// The proof must be *finishable* at every legal cadence — REV-65's rule, which is why the
    /// long zero-proof is 3000s and not the 3600s D-84 first specified: `sampleMaxAge` drops
    /// samples past 3600s, so the span can never reach 3600 and the pill would never leave
    /// `Measuring…`. At the fast end the retention floor stops the trim before the cap does.
    func testWeeklyBufferSpansTheProofAtEveryLegalCadence() async {
        for cadence in [45.0, 60.0, 120.0, 300.0] {
            let engine = ForecastEngine()
            var f: Forecast?
            for i in 0..<120 {
                f = await engine.record(
                    snapshot: snapshot(tool: .codex, used: 25, secondary: nil, windowSeconds: weekly),
                    at: base.addingTimeInterval(Double(i) * cadence))
            }
            let span = Double(f!.pollCount - 1) * cadence
            XCTAssertGreaterThanOrEqual(span, 3000, "cadence \(cadence): the zero-proof is reachable")
            XCTAssertLessThanOrEqual(span, 3600, "cadence \(cadence): never older than sampleMaxAge")
            XCTAssertNotNil(f?.burnRatePerMin, "cadence \(cadence): a flat hour resolves to zero")
        }
    }

    func testWeeklyBufferSettlesAtSixtySamplesAtBaseCadence() async {
        let engine = ForecastEngine()
        var f: Forecast?
        for i in 0..<90 {
            f = await engine.record(
                snapshot: snapshot(tool: .codex, used: Double(i) / 10, secondary: nil,
                                   windowSeconds: weekly),
                at: base.addingTimeInterval(Double(i) * 60))
        }
        XCTAssertEqual(f?.pollCount, 60, "60s cadence: the count cap governs, one hour of samples")
    }

    /// §11.4 is untouched by the cap — the `~est.` label clears at ten polls on every width.
    /// Tying it to the long cap would leave a weekly account in estimate mode for an hour.
    func testEstimateLabelStillClearsAtTenPollsOnAWeeklyWindow() async {
        let engine = ForecastEngine()
        var f: Forecast?
        for i in 0..<10 {
            f = await engine.record(
                snapshot: snapshot(tool: .codex, used: Double(i), secondary: nil,
                                   windowSeconds: weekly),
                at: base.addingTimeInterval(Double(i) * 60))
        }
        XCTAssertEqual(f?.pollCount, 10)
        XCTAssertFalse(f?.isEstimate ?? true, "ten polls is a full average on any window width")
    }

    /// A width that changes across a poll (the REV-69 `window_width_changed` fact) needs no
    /// special path: the next trim uses the new policy.
    func testWidthChangeRecapsTheBufferOnTheNextPoll() async {
        let engine = ForecastEngine()
        for i in 0..<40 {
            _ = await engine.record(
                snapshot: snapshot(tool: .codex, used: Double(i) / 10, secondary: nil,
                                   windowSeconds: weekly),
                at: base.addingTimeInterval(Double(i) * 60))
        }
        let wide = await engine.forecast(for: snapshot(tool: .codex, used: 3.9, secondary: nil,
                                                      windowSeconds: weekly))
        XCTAssertEqual(wide.pollCount, 40, "40 samples is under the long cap — nothing evicted")

        let narrowed = await engine.record(
            snapshot: snapshot(tool: .codex, used: 4, secondary: nil, windowSeconds: 18_000),
            at: base.addingTimeInterval(40 * 60))
        XCTAssertEqual(narrowed.pollCount, 12,
                       "back on a five-hour window the short cap and floor apply immediately")
    }

    // MARK: Launch rehydration

    func testSeedRestoresRecentSameWindowEvidence() async {
        let engine = ForecastEngine()
        let reset = base.addingTimeInterval(TimeInterval(weekly))
        let samples = (0..<10).map { index in
            ForecastEngine.SeedSample(
                usedPct: 12 + Double(index / 3),
                polledAt: base.addingTimeInterval(Double(index) * 360),
                resetsAt: reset,
                windowSeconds: weekly)
        }
        await engine.seed(tool: .codex, samples: samples,
                          now: base.addingTimeInterval(9 * 360 + 30))

        let forecast = await engine.forecast(for: snapshot(
            tool: .codex, used: 15, secondary: nil, reset: reset, windowSeconds: weekly))
        XCTAssertEqual(forecast.pollCount, 10)
        XCTAssertFalse(forecast.isEstimate)
        XCTAssertEqual(forecast.burnRatePerMin ?? -1, 3 / 54, accuracy: 0.0001)
        XCTAssertEqual(forecast.burnSpanMinutes, 54)
    }

    func testSeedKeepsOnlyThePostResetSegment() async {
        let engine = ForecastEngine()
        let firstReset = base.addingTimeInterval(18_000)
        let nextReset = firstReset.addingTimeInterval(18_000)
        let samples = [
            ForecastEngine.SeedSample(usedPct: 80, polledAt: base,
                                      resetsAt: firstReset, windowSeconds: nil),
            ForecastEngine.SeedSample(usedPct: 90, polledAt: base.addingTimeInterval(120),
                                      resetsAt: firstReset, windowSeconds: nil),
            ForecastEngine.SeedSample(usedPct: 1, polledAt: base.addingTimeInterval(240),
                                      resetsAt: nextReset, windowSeconds: nil),
            ForecastEngine.SeedSample(usedPct: 3, polledAt: base.addingTimeInterval(360),
                                      resetsAt: nextReset, windowSeconds: nil),
        ]
        await engine.seed(tool: .claude, samples: samples,
                          now: base.addingTimeInterval(400))

        let forecast = await engine.forecast(for: snapshot(used: 3, reset: nextReset))
        XCTAssertEqual(forecast.pollCount, 2)
        XCTAssertEqual(forecast.burnRatePerMin ?? -1, 1, accuracy: 0.0001)
    }

    func testSeedRejectsExpiredAndFutureRows() async {
        let engine = ForecastEngine()
        let samples = [
            ForecastEngine.SeedSample(usedPct: 10, polledAt: base,
                                      resetsAt: nil, windowSeconds: nil),
            ForecastEngine.SeedSample(usedPct: 20, polledAt: base.addingTimeInterval(7201),
                                      resetsAt: nil, windowSeconds: nil),
        ]
        await engine.seed(tool: .claude, samples: samples,
                          now: base.addingTimeInterval(7200))

        let forecast = await engine.forecast(for: snapshot(used: 20))
        XCTAssertEqual(forecast.pollCount, 0)
        XCTAssertNil(forecast.burnRatePerMin)
    }
}
