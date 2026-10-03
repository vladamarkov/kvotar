import XCTest
@testable import KvotarCore

/// Exercises the cumulative per-cycle accumulator (REV-47/D-42 — the `OffMachineEstimator`
/// interval rule transplanted to the monthly meter). Each `record` folds one poll's exact meter
/// delta (raw units, meter-native scale) into the cycle's local / off-machine split; the
/// unattributed share is the derived residual. Tests drive sequences with explicit `now` /
/// `cycleReset` / `usedAmount` (mirroring `OffMachineEstimatorTests`).
final class MonthlyAttributionEstimatorTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let cycleReset = Date(timeIntervalSince1970: 1_702_000_000)   // monthly anchor

    // MARK: Idle path — off-machine

    func testIdleIntervalsAccumulateOffMachine() async {
        let e = MonthlyAttributionEstimator()
        // First poll seeds the cycle (no delta attributed): 1000 already used → unattributed.
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 1000,
                           localValueLast8Min: 0, now: base)
        // Two idle intervals: +500 then +300, all off-machine (local value 0 the whole time).
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 1500,
                           localValueLast8Min: 0, now: base.addingTimeInterval(60))
        let r = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 1800,
                               localValueLast8Min: nil, now: base.addingTimeInterval(120))
        XCTAssertEqual(r?.offMachineAmount ?? -1, 800, accuracy: 1e-9)
        XCTAssertEqual(r?.localAmount ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedAmount ?? -1, 1000, accuracy: 1e-9,
                       "the pre-observation 1000 stays unattributed")
        XCTAssertEqual(r?.usedAmount ?? -1, 1800, accuracy: 1e-9)
    }

    // MARK: Active path — attributed to local

    func testActiveIntervalsAccumulateLocal() async {
        let e = MonthlyAttributionEstimator()
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 0,
                           localValueLast8Min: 0, now: base)
        let r = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 600,
                               localValueLast8Min: 1.5, now: base.addingTimeInterval(60))
        XCTAssertEqual(r?.localAmount ?? -1, 600, accuracy: 1e-9)
        XCTAssertEqual(r?.offMachineAmount ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: High-water mark — the SPIKE's eventual-consistency dips never double-count

    func testDownwardWobbleDoesNotDoubleCount() async {
        let e = MonthlyAttributionEstimator()
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 0,
                           localValueLast8Min: 0, now: base)
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 1000,
                           localValueLast8Min: 0, now: base.addingTimeInterval(60))
        // Meter dips to 990 (P2-15's ±10 at-rest regression), then recovers to 1000.
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 990,
                           localValueLast8Min: 0, now: base.addingTimeInterval(120))
        let r = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 1000,
                               localValueLast8Min: 0, now: base.addingTimeInterval(180))
        XCTAssertEqual(r?.offMachineAmount ?? -1, 1000, accuracy: 1e-9,
                       "the 10-unit re-rise must not be counted twice")
    }

    // MARK: Mid-cycle first observation — residual is honest

    func testMidCycleFirstObservationIsUnattributed() async {
        let e = MonthlyAttributionEstimator()
        let r = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 6_916,
                               localValueLast8Min: 2.0, now: base)
        XCTAssertEqual(r?.unattributedAmount ?? -1, 6_916, accuracy: 1e-9,
                       "spend observed before watching began is never guessed into a bucket")
        XCTAssertEqual(r?.localAmount ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.offMachineAmount ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: Cycle anchor

    func testAnchorAdvanceStartsFresh() async {
        let e = MonthlyAttributionEstimator()
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 0,
                           localValueLast8Min: 0, now: base)
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 3000,
                           localValueLast8Min: 0, now: base.addingTimeInterval(60))
        // Next calendar month: anchor advances ~30 days, meter restarted near 0.
        let nextCycle = cycleReset.addingTimeInterval(30 * 86_400)
        let r = await e.record(tool: .claude, cycleReset: nextCycle, usedAmount: 200,
                               localValueLast8Min: 0, now: base.addingTimeInterval(120))
        XCTAssertEqual(r?.offMachineAmount ?? -1, 0, accuracy: 1e-9, "rollover clears the accumulator")
        XCTAssertEqual(r?.usedAmount ?? -1, 200, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedAmount ?? -1, 200, accuracy: 1e-9,
                       "post-rollover pre-observation spend is unattributed")
    }

    func testAnchorJitterWithinToleranceIsSameCycle() async {
        let e = MonthlyAttributionEstimator()
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 0,
                           localValueLast8Min: 0, now: base)
        // The derived reset wobbles by 30s between polls — still the same cycle.
        let r = await e.record(tool: .claude, cycleReset: cycleReset.addingTimeInterval(30),
                               usedAmount: 500, localValueLast8Min: 0,
                               now: base.addingTimeInterval(60))
        XCTAssertEqual(r?.offMachineAmount ?? -1, 500, accuracy: 1e-9,
                       "a jittered anchor must not reset the accumulator")
    }

    // MARK: Nil-meter poll / read-only path

    func testNilMeterReturnsLastKnown() async {
        let e = MonthlyAttributionEstimator()
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 500,
                           localValueLast8Min: 0, now: base)
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 1200,
                           localValueLast8Min: 0, now: base.addingTimeInterval(60))
        // A poll without a monthly meter must not disturb the accumulator.
        let r = await e.record(tool: .claude, cycleReset: nil, usedAmount: nil,
                               localValueLast8Min: nil, now: base.addingTimeInterval(120))
        XCTAssertEqual(r?.offMachineAmount ?? -1, 700, accuracy: 1e-9)
        XCTAssertEqual(r?.usedAmount ?? -1, 1200, accuracy: 1e-9)
    }

    func testCurrentDoesNotAdvance() async {
        let e = MonthlyAttributionEstimator()
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 0,
                           localValueLast8Min: 0, now: base)
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 800,
                           localValueLast8Min: 0, now: base.addingTimeInterval(60))
        let a = await e.current(for: .claude)
        let b = await e.current(for: .claude)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a?.offMachineAmount ?? -1, 800, accuracy: 1e-9)
    }

    func testNoStateReturnsNil() async {
        let e = MonthlyAttributionEstimator()
        let r = await e.current(for: .codex)
        XCTAssertNil(r, "no observation yet → nothing to render")
    }

    // MARK: Sum invariant — local + off + unattributed == used, mixed sequence

    func testSumInvariantAcrossMixedSequence() async {
        let e = MonthlyAttributionEstimator()
        // Mid-cycle start (residual), then idle, active, wobble, idle intervals.
        let sequence: [(used: Double, localValue: Double?)] = [
            (1000, nil), (1400, 0), (1900, 3.2), (1850, 0), (2600, 0.1), (2600, nil), (3100, 0),
        ]
        var last: MonthlyAttribution?
        for (i, step) in sequence.enumerated() {
            last = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: step.used,
                                  localValueLast8Min: step.localValue,
                                  now: base.addingTimeInterval(Double(i) * 60))
            if let r = last {
                XCTAssertEqual(r.localAmount + r.offMachineAmount + r.unattributedAmount,
                               r.usedAmount, accuracy: 1e-9,
                               "sum invariant violated at step \(i)")
            }
        }
        XCTAssertEqual(last?.usedAmount ?? -1, 3100, accuracy: 1e-9)
        XCTAssertEqual(last?.localAmount ?? -1, 1200, accuracy: 1e-9,
                       "active intervals: +500 (step 2) + 700 (step 4, from high-water 1900)")
        XCTAssertEqual(last?.offMachineAmount ?? -1, 900, accuracy: 1e-9,
                       "idle intervals: +400 (step 1) + 500 (step 6); the step-3 dip adds nothing")
        XCTAssertEqual(last?.unattributedAmount ?? -1, 1000, accuracy: 1e-9,
                       "the mid-cycle seed stays the residual")
    }

    // MARK: Persistence round-trip across a fresh actor instance (KV JSON, no migration)

    func testPersistenceResumesMidCycle() async throws {
        let dbPath = NSTemporaryDirectory().appending("kvotar-monthlyattrib-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) } }
        let store = try SQLiteStore(path: dbPath)

        let e1 = MonthlyAttributionEstimator(store: store)
        _ = await e1.record(tool: .claude, cycleReset: cycleReset, usedAmount: 0,
                            localValueLast8Min: 0, now: base)
        _ = await e1.record(tool: .claude, cycleReset: cycleReset, usedAmount: 2000,
                            localValueLast8Min: 0, now: base.addingTimeInterval(60))

        // A brand-new instance (simulating an app restart) resumes from the persisted state.
        let e2 = MonthlyAttributionEstimator(store: store)
        let resumed = await e2.current(for: .claude)
        XCTAssertEqual(resumed?.offMachineAmount ?? -1, 2000, accuracy: 1e-9,
                       "off-machine accumulated before restart is restored")

        // A mismatched anchor (rollover while off) discards the stale state.
        let r = await e2.record(tool: .claude, cycleReset: cycleReset.addingTimeInterval(30 * 86_400),
                                usedAmount: 300, localValueLast8Min: 0,
                                now: base.addingTimeInterval(120))
        XCTAssertEqual(r?.offMachineAmount ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedAmount ?? -1, 300, accuracy: 1e-9)
    }

    // MARK: Codex instantiation (REV-48 — STEP_67)
    //
    // Same component, second tool: the meter is *credits*, not money-minor-units, and nothing in
    // the estimator may notice the difference (E4 discipline — no credits↔tokens conversion, no
    // `QuotaUnit` inspection). These drive the two regimes the P2-15 SPIKE actually observed on
    // the dogfood account: fractional token-priced deltas while local Codex runs, frozen-mantissa
    // 10-credit lumps while it doesn't.

    func testCodexCreditsAreAttributedRawInBothRegimes() async {
        let e = MonthlyAttributionEstimator()
        // Mid-cycle seed: 2876.213 credits already spent this cycle (synthetic; the SPIKE's shape).
        _ = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: 2876.213,
                           localValueLast8Min: nil, now: base)
        // Elsewhere regime: ChatGPT web, three +10 lumps, mantissa frozen, local Codex idle.
        for (i, used) in [2886.213, 2896.213, 2906.213].enumerated() {
            _ = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: used,
                               localValueLast8Min: 0,
                               now: base.addingTimeInterval(Double(i + 1) * 60))
        }
        // At-rest correction: the server rounds the aggregate back down by 10, then re-reports.
        _ = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: 2896.213,
                           localValueLast8Min: 0, now: base.addingTimeInterval(240))
        _ = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: 2906.213,
                           localValueLast8Min: 0, now: base.addingTimeInterval(300))
        // Local CLI regime: fractional, token-priced, local Codex live.
        let r = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: 2921.555,
                               localValueLast8Min: 0.8, now: base.addingTimeInterval(360))

        XCTAssertEqual(r?.offMachineAmount ?? -1, 30, accuracy: 1e-9,
                       "three +10 web lumps; the −10 at-rest dip and its re-rise net to zero")
        XCTAssertEqual(r?.localAmount ?? -1, 15.342, accuracy: 1e-9,
                       "the fractional CLI delta is filed raw — no rounding, no unit conversion")
        XCTAssertEqual(r?.unattributedAmount ?? -1, 2876.213, accuracy: 1e-9)
        XCTAssertEqual(r?.usedAmount ?? -1, 2921.555, accuracy: 1e-9)
        XCTAssertEqual((r?.localAmount ?? 0) + (r?.offMachineAmount ?? 0)
                       + (r?.unattributedAmount ?? 0), r?.usedAmount ?? -1, accuracy: 1e-9,
                       "This machine + Elsewhere + Unattributed = Used")
    }

    func testCodexServerAnchorAdvanceStartsFresh() async {
        let e = MonthlyAttributionEstimator()
        _ = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: 3400,
                           localValueLast8Min: 0, now: base)
        _ = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: 3500,
                           localValueLast8Min: 0, now: base.addingTimeInterval(60))
        // Codex's anchor is the *server's* `individual_limit.reset_at`, so an advance is a real
        // rollover rather than derivation wobble — the residual is honestly unattributed.
        let nextCycle = cycleReset.addingTimeInterval(31 * 86_400)
        let r = await e.record(tool: .codex, cycleReset: nextCycle, usedAmount: 40,
                               localValueLast8Min: 0, now: base.addingTimeInterval(120))
        XCTAssertEqual(r?.localAmount ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.offMachineAmount ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedAmount ?? -1, 40, accuracy: 1e-9)
    }

    func testCodexNilMeterReturnsLastKnown() async {
        let e = MonthlyAttributionEstimator()
        _ = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: 100,
                           localValueLast8Min: 0, now: base)
        _ = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: 340,
                           localValueLast8Min: 0, now: base.addingTimeInterval(60))
        // A windowed (consumer) Codex poll carries no monthly meter — it must not disturb state.
        let r = await e.record(tool: .codex, cycleReset: nil, usedAmount: nil,
                               localValueLast8Min: nil, now: base.addingTimeInterval(120))
        XCTAssertEqual(r?.offMachineAmount ?? -1, 240, accuracy: 1e-9)
        XCTAssertEqual(r?.usedAmount ?? -1, 340, accuracy: 1e-9)
    }

    /// Both tools now record on every poll, so the per-tool keying is load-bearing rather than
    /// theoretical: one account's meter must never leak into the other's buckets.
    func testPerToolAccumulatorsAreIndependent() async {
        let e = MonthlyAttributionEstimator()
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 0,
                           localValueLast8Min: 0, now: base)
        _ = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: 0,
                           localValueLast8Min: 0, now: base)
        // Claude spends while idle, Codex while active, over the same interval.
        _ = await e.record(tool: .claude, cycleReset: cycleReset, usedAmount: 900,
                           localValueLast8Min: 0, now: base.addingTimeInterval(60))
        _ = await e.record(tool: .codex, cycleReset: cycleReset, usedAmount: 70,
                           localValueLast8Min: 2.0, now: base.addingTimeInterval(60))

        let claude = await e.current(for: .claude)
        let codex = await e.current(for: .codex)
        XCTAssertEqual(claude?.offMachineAmount ?? -1, 900, accuracy: 1e-9)
        XCTAssertEqual(claude?.localAmount ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(codex?.localAmount ?? -1, 70, accuracy: 1e-9)
        XCTAssertEqual(codex?.offMachineAmount ?? -1, 0, accuracy: 1e-9)
    }

    /// The Codex state persists under its own KV key — asserted by name, because the live
    /// verification for STEP_67 reads exactly this row off the real database.
    func testCodexPersistsUnderCodexKey() async throws {
        let dbPath = NSTemporaryDirectory().appending("kvotar-monthlyattrib-codex-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) } }
        let store = try SQLiteStore(path: dbPath)

        let e1 = MonthlyAttributionEstimator(store: store)
        _ = await e1.record(tool: .codex, cycleReset: cycleReset, usedAmount: 3400,
                            localValueLast8Min: 0, now: base)
        _ = await e1.record(tool: .codex, cycleReset: cycleReset, usedAmount: 3460,
                            localValueLast8Min: 0, now: base.addingTimeInterval(60))

        let raw = try await store.readSetting(key: "monthly_attrib_accum_codex")
        XCTAssertNotNil(raw, "the Codex accumulator must land under monthly_attrib_accum_codex")
        let claudeRow = try await store.readSetting(key: "monthly_attrib_accum_claude")
        XCTAssertNil(claudeRow, "a Codex-only session must not write the Claude key")

        // A fresh instance (app restart) resumes mid-cycle from that row.
        let e2 = MonthlyAttributionEstimator(store: store)
        let resumed = await e2.current(for: .codex)
        XCTAssertEqual(resumed?.offMachineAmount ?? -1, 60, accuracy: 1e-9)
        XCTAssertEqual(resumed?.usedAmount ?? -1, 3460, accuracy: 1e-9)
    }
}
