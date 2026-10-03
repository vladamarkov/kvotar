import XCTest
@testable import KvotarCore

/// Exercises the retrospective whole-window recompute (REV-53 — STEP_76, supersedes the REV-27
/// accumulator suite). Each `record`/`current` re-walks the window's persisted `quota_series`
/// against landed token events: a settled zero-token interval is exact off-machine; token-bearing
/// or still-pending intervals are Local; the unattributed share is the pre-observation residue.
/// Tests seed a real temp-file store through the production `writePoll(now:)` path and drive the
/// walk with explicit clocks (mirroring `ForecastEngineTests`' injectable-clock style).
final class OffMachineEstimatorTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let window = Date(timeIntervalSince1970: 1_700_000_000)   // window start anchor
    private var resetsAt: Date { window.addingTimeInterval(18_000) }
    private let guardGap = OffMachineEstimator.inFlightGuard          // 180s

    private var dbPath: String!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory().appending("kvotar-offmachine-\(UUID().uuidString).db")
        store = try SQLiteStore(path: dbPath)
    }

    override func tearDown() {
        store = nil
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    /// Seeds one window poll through the production write path (`writePoll` also writes the
    /// `quota_series` row the recompute walks).
    private func poll(tool: Tool = .claude, pct: Double, resetsAt: Date? = nil,
                      at now: Date) async throws {
        let snapshot = QuotaSnapshot(tool: tool, primaryUsedPct: pct,
                                     primaryResetsAt: resetsAt ?? self.resetsAt,
                                     secondaryUsedPct: nil, secondaryResetsAt: nil,
                                     rateLimitReached: nil)
        try await store.writePoll(snapshot: snapshot, now: now)
    }

    /// Seeds one local token event at `at` (the recompute classifies by presence only).
    private func token(tool: Tool = .claude, at: Date) async throws {
        try await store.writeTokenEvents([TokenEvent(
            tool: tool, sessionId: "s-\(UUID().uuidString)", surfaceBucket: "cli",
            inputTokens: 10, outputTokens: 10, cacheCreationTokens: 0, cacheReadTokens: 0,
            recordedAt: at, dedupKey: UUID().uuidString)])
    }

    // MARK: Idle path — exact off-machine, settlement staged by the guard

    func testIdleIntervalsAccumulateOffMachine() async throws {
        try await poll(pct: 10, at: base)                                   // pre-observation residue
        try await poll(pct: 15, at: base.addingTimeInterval(240))
        try await poll(pct: 18, at: base.addingTimeInterval(480))
        let e = OffMachineEstimator(store: store)

        // At the third poll the first interval (+5) is settled idle; the second (+3) is still
        // inside the guard → pending Local.
        let r = await e.record(tool: .claude, resetsAt: resetsAt, windowSeconds: 18_000, currentUsedPct: 18,
                               now: base.addingTimeInterval(480))
        XCTAssertEqual(r?.offMachinePct ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(r?.localPct ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedPct ?? -1, 10, accuracy: 1e-9,
                       "the pre-observation 10% stays unattributed")

        // Guard time passes with no tokens → the pending interval settles to off-machine.
        let settled = await e.current(for: .claude, now: base.addingTimeInterval(720))
        XCTAssertEqual(settled?.offMachinePct ?? -1, 8, accuracy: 1e-9)
        XCTAssertEqual(settled?.localPct ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(settled?.totalUsedPct ?? -1, 18, accuracy: 1e-9)
    }

    // MARK: Active path — token-bearing intervals stay Local, even settled

    func testActiveIntervalsAccumulateLocal() async throws {
        try await poll(pct: 0, at: base)
        try await poll(pct: 6, at: base.addingTimeInterval(240))
        try await token(at: base.addingTimeInterval(120))
        let e = OffMachineEstimator(store: store)
        let r = await e.current(for: .claude, now: base.addingTimeInterval(900))
        XCTAssertEqual(r?.localPct ?? -1, 6, accuracy: 1e-9)
        XCTAssertEqual(r?.offMachinePct ?? -1, 0, accuracy: 1e-9,
                       "a token-bearing interval never settles to off-machine")
    }

    // MARK: The core regression — off-machine survives local going active

    func testOffMachineStaysVisibleAfterLocalGoesActive() async throws {
        try await poll(pct: 0, at: base)
        try await poll(pct: 10, at: base.addingTimeInterval(240))           // browser-only: idle
        try await poll(pct: 14, at: base.addingTimeInterval(480))           // local session: token below
        // +460: inside the second interval, and past the first interval's guard span (+420) —
        // a token inside a settled interval's guard span legitimately poisons it (in-flight call).
        try await token(at: base.addingTimeInterval(460))
        let e = OffMachineEstimator(store: store)
        let r = await e.current(for: .claude, now: base.addingTimeInterval(1_200))
        XCTAssertEqual(r?.offMachinePct ?? -1, 10, accuracy: 1e-9,
                       "the earlier off-machine burn must NOT vanish when local goes active")
        XCTAssertEqual(r?.localPct ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(r?.totalUsedPct ?? -1, 14, accuracy: 1e-9)
    }

    // MARK: Window rollover — the resets_at-proximity row selection

    func testWindowRolloverResets() async throws {
        try await poll(pct: 0, at: base)
        try await poll(pct: 30, at: base.addingTimeInterval(240))
        // New window: resets_at advanced a full 5h; fresh usage near 0.
        let newWindow = window.addingTimeInterval(18_000)
        try await poll(pct: 2, resetsAt: newWindow.addingTimeInterval(18_000),
                 at: base.addingTimeInterval(480))
        let e = OffMachineEstimator(store: store)
        let r = await e.record(tool: .claude, resetsAt: newWindow.addingTimeInterval(18_000), windowSeconds: 18_000, currentUsedPct: 2,
                               now: base.addingTimeInterval(480))
        XCTAssertEqual(r?.offMachinePct ?? -1, 0, accuracy: 1e-9,
                       "the old window's rows must not leak into the new window's walk")
        XCTAssertEqual(r?.totalUsedPct ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedPct ?? -1, 2, accuracy: 1e-9,
                       "fresh window's initial usage is unattributed")
    }

    // MARK: Running high-water — downward endpoint wobble never double-counts

    func testDownwardWobbleDoesNotDoubleCount() async throws {
        for (i, pct) in [0.0, 10, 9, 10].enumerated() {
            try await poll(pct: pct, at: base.addingTimeInterval(Double(i) * 240))
        }
        let e = OffMachineEstimator(store: store)
        let r = await e.current(for: .claude, now: base.addingTimeInterval(2_000))
        XCTAssertEqual(r?.offMachinePct ?? -1, 10, accuracy: 1e-9,
                       "the 1% re-rise must not be counted twice (running high-water, not pairwise)")
    }

    // MARK: Null window / read-only path

    func testNilWindowReturnsLastKnown() async throws {
        try await poll(pct: 5, at: base)
        try await poll(pct: 12, at: base.addingTimeInterval(240))
        let e = OffMachineEstimator(store: store)
        _ = await e.record(tool: .claude, resetsAt: resetsAt, windowSeconds: 18_000, currentUsedPct: 12,
                           now: base.addingTimeInterval(240))
        // A null-window poll (no usedPct / no windowStart) must not invent or lose usage.
        let r = await e.record(tool: .claude, resetsAt: nil, windowSeconds: 18_000, currentUsedPct: nil,
                               now: base.addingTimeInterval(480))
        XCTAssertEqual(r?.totalUsedPct ?? -1, 12, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedPct ?? -1, 5, accuracy: 1e-9)
    }

    func testNilWindowAfterRestartLazilyRecomputes() async throws {
        try await poll(pct: 5, at: base)
        try await poll(pct: 12, at: base.addingTimeInterval(240))
        // Fresh instance, empty cache (an app restart), first poll is null-window — the REV-46
        // idle retrospective depends on this returning the last window's share, not nil.
        let e = OffMachineEstimator(store: store)
        let r = await e.record(tool: .claude, resetsAt: nil, windowSeconds: 18_000, currentUsedPct: nil,
                               now: base.addingTimeInterval(600))
        XCTAssertEqual(r?.offMachinePct ?? -1, 7, accuracy: 1e-9,
                       "post-restart null poll recomputes the newest persisted window")
        XCTAssertEqual(r?.unattributedPct ?? -1, 5, accuracy: 1e-9)
    }

    func testCurrentMaySettleButNeverInvents() async throws {
        try await poll(pct: 0, at: base)
        try await poll(pct: 8, at: base.addingTimeInterval(240))
        let e = OffMachineEstimator(store: store)
        // Same instant → identical result (idempotent read).
        let a = await e.current(for: .claude, now: base.addingTimeInterval(300))
        let b = await e.current(for: .claude, now: base.addingTimeInterval(300))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a?.localPct ?? -1, 8, accuracy: 1e-9, "inside the guard: pending → Local")
        // Later `now` may settle Local → off, but the total never rises without a poll.
        let c = await e.current(for: .claude, now: base.addingTimeInterval(600))
        XCTAssertEqual(c?.offMachinePct ?? -1, 8, accuracy: 1e-9)
        XCTAssertEqual(c?.totalUsedPct ?? -1, a?.totalUsedPct ?? -2, accuracy: 1e-9,
                       "current never invents usage")
    }

    func testNoStateReturnsNil() async {
        let e = OffMachineEstimator(store: store)
        let r = await e.current(for: .codex)
        XCTAssertNil(r, "no observation yet → nothing to render")
        let storeless = OffMachineEstimator()
        let r2 = await storeless.current(for: .codex)
        XCTAssertNil(r2)
    }

    // MARK: Series round-trip across a fresh actor instance (restart parity)

    func testSeriesRoundTripAcrossRestart() async throws {
        try await poll(pct: 0, at: base)
        try await poll(pct: 20, at: base.addingTimeInterval(240))
        let e1 = OffMachineEstimator(store: store)
        let before = await e1.current(for: .claude, now: base.addingTimeInterval(600))
        XCTAssertEqual(before?.offMachinePct ?? -1, 20, accuracy: 1e-9)

        // A brand-new instance (an app restart) recomputes the same answer from the series.
        let e2 = OffMachineEstimator(store: store)
        let resumed = await e2.current(for: .claude, now: base.addingTimeInterval(600))
        XCTAssertEqual(resumed, before, "restart loses nothing — the DB is the state")

        // A rollover poll on the fresh instance walks only the new window.
        let newWindow = window.addingTimeInterval(18_000)
        try await poll(pct: 3, resetsAt: newWindow.addingTimeInterval(18_000),
                 at: base.addingTimeInterval(900))
        let r = await e2.record(tool: .claude, resetsAt: newWindow.addingTimeInterval(18_000), windowSeconds: 18_000, currentUsedPct: 3,
                                now: base.addingTimeInterval(900))
        XCTAssertEqual(r?.offMachinePct ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: New pins (REV-53 semantics)

    func testZeroTokenIntervalBanksExactly() async throws {
        // The 18:41–18:45 incident pin: a JSONL write landing exactly at the interval's start
        // belongs to the previous interval — open lower bound on the token bucket.
        try await poll(pct: 10, at: base)
        try await poll(pct: 11, at: base.addingTimeInterval(240))
        try await token(at: base)
        let e = OffMachineEstimator(store: store)
        let r = await e.current(for: .claude, now: base.addingTimeInterval(600))
        XCTAssertEqual(r?.offMachinePct ?? -1, 1, accuracy: 1e-9,
                       "a token at exactly t₀ must not poison the interval")
    }

    func testGuardDefersSettlement() async throws {
        try await poll(pct: 0, at: base)
        try await poll(pct: 5, at: base.addingTimeInterval(240))
        let e = OffMachineEstimator(store: store)
        let pending = await e.record(tool: .claude, resetsAt: resetsAt, windowSeconds: 18_000, currentUsedPct: 5,
                                     now: base.addingTimeInterval(240))
        XCTAssertEqual(pending?.localPct ?? -1, 5, accuracy: 1e-9, "inside the guard: Local")
        XCTAssertEqual(pending?.offMachinePct ?? -1, 0, accuracy: 1e-9)
        // Settlement at exactly t₁ + G (the `>=` boundary).
        let settled = await e.current(for: .claude,
                                      now: base.addingTimeInterval(240 + guardGap))
        XCTAssertEqual(settled?.offMachinePct ?? -1, 5, accuracy: 1e-9)
    }

    func testLateJSONLFlipsProvisionalIdleToLocal() async throws {
        try await poll(pct: 0, at: base)
        try await poll(pct: 5, at: base.addingTimeInterval(240))
        let e = OffMachineEstimator(store: store)
        let pending = await e.current(for: .claude, now: base.addingTimeInterval(300))
        XCTAssertEqual(pending?.localPct ?? -1, 5, accuracy: 1e-9)
        // A turn's usage lands late but inside the guard span (t₁+60) → the interval is Local
        // and stays Local after the guard passes — self-healing in the confirming direction.
        try await token(at: base.addingTimeInterval(300))
        let r = await e.current(for: .claude, now: base.addingTimeInterval(900))
        XCTAssertEqual(r?.localPct ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(r?.offMachinePct ?? -1, 0, accuracy: 1e-9)
    }

    func testMonotoneFloorWithinWindow() async throws {
        // Mixed idle/active sequence; with writes landing within the guard, the off-machine
        // figure only ever ratchets up across successive reads.
        try await poll(pct: 0, at: base)
        try await poll(pct: 5, at: base.addingTimeInterval(240))            // idle interval
        try await poll(pct: 8, at: base.addingTimeInterval(480))            // token below → Local
        try await token(at: base.addingTimeInterval(470))                   // past interval 1's guard span
        try await poll(pct: 12, at: base.addingTimeInterval(720))           // idle interval
        let e = OffMachineEstimator(store: store)
        var previousOff = -1.0
        for offset in [720.0, 900, 1_200, 2_000] {
            let r = await e.current(for: .claude, now: base.addingTimeInterval(offset))
            XCTAssertGreaterThanOrEqual(r?.offMachinePct ?? -1, previousOff,
                                        "off-machine must not decrease at now=+\(offset)")
            previousOff = r?.offMachinePct ?? -1
        }
        XCTAssertEqual(previousOff, 9, accuracy: 1e-9, "5 (first idle) + 4 (last idle)")
    }

    func testPreObservationResidueUnattributed() async throws {
        try await poll(pct: 40, at: base)
        try await poll(pct: 45, at: base.addingTimeInterval(240))
        let e = OffMachineEstimator(store: store)
        let r = await e.current(for: .claude, now: base.addingTimeInterval(600))
        XCTAssertEqual(r?.unattributedPct ?? -1, 40, accuracy: 1e-9)
        XCTAssertEqual(r?.offMachinePct ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(r?.totalUsedPct ?? -1, 45, accuracy: 1e-9)
    }

    func testCodexSeriesCoexists() async throws {
        let codexResets = base.addingTimeInterval(7_200)              // unrelated codex window
        try await poll(pct: 0, at: base)
        try await poll(tool: .codex, pct: 50, resetsAt: codexResets, at: base.addingTimeInterval(60))
        try await poll(pct: 10, at: base.addingTimeInterval(240))
        try await poll(tool: .codex, pct: 60, resetsAt: codexResets, at: base.addingTimeInterval(300))
        let e = OffMachineEstimator(store: store)
        let claude = await e.current(for: .claude, now: base.addingTimeInterval(900))
        XCTAssertEqual(claude?.offMachinePct ?? -1, 10, accuracy: 1e-9,
                       "codex rows must not leak into the claude walk")
        let codex = await e.record(tool: .codex, resetsAt: codexResets, windowSeconds: 18_000,
                                   currentUsedPct: 60, now: base.addingTimeInterval(900))
        XCTAssertEqual(codex?.offMachinePct ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(codex?.unattributedPct ?? -1, 50, accuracy: 1e-9)
    }

    // MARK: The leading slice (REV-56 §5 — STEP_84)

    /// The 2026-07-29 11:00–16:00 window off the dogfood machine, replayed sample for sample
    /// (REV-56 §1.1). 30 readings, the first already at 3.0, two `+1.0` rises, and one
    /// `5.0 → 4.0 → 5.0` quantization wobble. `local_usage_events` held **nothing** for Claude
    /// that whole day, and `app_lifecycle_events` puts the app launched 07-28 00:10:28 and awake
    /// across the leading span (`wake 10:42:00`, `sleep 11:26:32`) — so every point of the window
    /// is provably off-machine, the leading 3.0 included.
    private static let july29Window: [(offset: TimeInterval, pct: Double)] = [
        (412, 3.0), (667, 3.0), (908, 4.0), (1158, 4.0), (1402, 4.0), (3511, 4.0),
        (8399, 4.0), (13468, 4.0), (14644, 4.0), (14898, 4.0), (15150, 4.0), (15405, 4.0),
        (15662, 4.0), (15791, 5.0), (15922, 4.0), (16056, 4.0), (16185, 4.0), (16306, 4.0),
        (16437, 4.0), (16558, 4.0), (16680, 4.0), (16801, 4.0), (16923, 4.0), (17065, 4.0),
        (17198, 4.0), (17318, 4.0), (17439, 4.0), (17570, 4.0), (17701, 5.0), (17834, 5.0),
    ]

    private var july29Samples: [OffMachineEstimator.SeriesSample] {
        Self.july29Window.map {
            .init(polledAt: window.addingTimeInterval($0.offset), usedPct: $0.pct)
        }
    }

    // MARK: The Elsewhere split learns about file growth (STEP_173)

    /// The alpha tester's Codex window of 2026-09-03, 05:20:24 → 10:20:24 UTC, lifted row for row
    /// from their 09-07 diagnostics bundle. `(offset, pct, activityMarkOffset)` — the third value
    /// is the §12 liveness timestamp the app held at that poll, reconstructed from the bundle's own
    /// `JSONL flush` log lines and its nine token rows, which is what `writePoll` now stamps onto
    /// the series row.
    ///
    /// It is the episode STEP_170 was written for. Their editor extension appended to disk every
    /// 10–30 seconds all morning while the account climbed 3 % → 95 %, and Codex wrote the turns'
    /// `token_count` twenty to thirty minutes late — nine rows, the first at offset 8964. So the
    /// long rises at 7212–7776 (5 → 32) and 9357–10197 (64 → 95) hold no token evidence at all,
    /// and the tokens that eventually landed belong to *later* intervals, which is why the REV-53
    /// self-heal never reached back.
    ///
    /// Trimmed after offset 10263: the meter is pinned at 95 for the rest of the window, so those
    /// rows carry no delta. The last point is kept so `closeObserved` still reads the real close.
    /// `app_lifecycle_events` puts the app launched 2026-09-02 09:33:23, well before the window, so
    /// the leading slice is covered; the 1361 → 6307 gap is the Mac asleep (`wake` at 6317), which
    /// §12.2 counts as covered.
    private static let sept3CodexWindow: [(offset: TimeInterval, pct: Double, mark: TimeInterval?)] = [
        (1361, 2, nil), (6307, 3, nil), (6369, 3, nil), (6429, 3, nil), (6489, 3, nil),
        (6546, 3, nil), (6604, 3, nil), (6672, 3, nil), (6735, 3, nil), (6795, 3, nil),
        (6861, 3, nil), (6919, 3, nil), (6975, 3, nil), (7033, 3, nil), (7089, 3, nil),
        (7152, 3, 7122), (7212, 5, 7188), (7278, 8, 7277), (7337, 9, 7323), (7401, 11, 7389),
        (7458, 13, 7458), (7524, 17, 7524), (7588, 23, 7560), (7652, 26, 7652), (7715, 29, 7704),
        (7776, 32, 7770), (7840, 32, 7770), (7905, 32, 7770), (7971, 32, 7770), (8034, 32, 7770),
        (8092, 32, 7770), (8153, 32, 7770), (8212, 32, 7770), (8277, 32, 7770), (8337, 32, 7770),
        (8396, 32, 8383), (8463, 33, 8418), (8523, 33, 8418), (8583, 33, 8418), (8646, 35, 8640),
        (8706, 37, 8669), (8770, 38, 8669), (8828, 40, 8827), (8885, 40, 8880), (8951, 41, 8880),
        (9010, 45, 9006), (9069, 48, 9056), (9124, 50, 9123), (9183, 54, 9178), (9241, 57, 9226),
        (9292, 60, 9285), (9357, 64, 9340), (9420, 64, 9340), (9474, 67, 9473), (9537, 69, 9528),
        (9603, 72, 9591), (9661, 74, 9643), (9717, 75, 9715), (9780, 78, 9777), (9843, 78, 9829),
        (9900, 80, 9888), (9963, 82, 9949), (10022, 86, 10018), (10070, 89, 10068),
        (10134, 93, 10121), (10197, 95, 10178), (10263, 95, 10178), (18009, 95, 16408),
    ]

    /// The nine `local_usage_events` rows Codex actually wrote that morning, as window offsets —
    /// 07:49:48 … 08:07:22 UTC. Every one of them is an `IDE extension` row.
    private static let sept3TokenOffsets: [TimeInterval] = [
        8964, 9006, 9027, 9056, 9142, 9195, 9226, 9308, 10018,
    ]

    /// The window replayed with the liveness marks the series now carries.
    private var sept3Samples: [OffMachineEstimator.SeriesSample] {
        Self.sept3CodexWindow.map {
            .init(polledAt: window.addingTimeInterval($0.offset), usedPct: $0.pct,
                  lastLocalActivityAt: $0.mark.map(window.addingTimeInterval))
        }
    }

    /// The same window as every build before STEP_173 saw it — series rows with no mark, which is
    /// also how a pre-`v22` row reads back today.
    private var sept3SamplesWithoutMarks: [OffMachineEstimator.SeriesSample] {
        Self.sept3CodexWindow.map {
            .init(polledAt: window.addingTimeInterval($0.offset), usedPct: $0.pct)
        }
    }

    private var sept3Tokens: [Date] {
        Self.sept3TokenOffsets.map(window.addingTimeInterval)
    }

    /// The defect, pinned. Codex's write lag leaves the intervals the user actually worked through
    /// token-free, so token evidence alone books 61 of 95 points as Elsewhere — under a burn card
    /// whose `Local source` row was, correctly, naming their editor extension as active.
    ///
    /// This is not a regression guard, it is the *before* half of the pair: it must keep passing,
    /// because a pre-`v22` row carries no mark and has to classify exactly as it always did.
    func testSept3WindowWithoutMarksStillBooksTheWorkedStretchElsewhere() {
        let r = OffMachineEstimator.recompute(
            points: sept3SamplesWithoutMarks, tokenTimestamps: sept3Tokens, liveUsedPct: nil,
            now: window.addingTimeInterval(18_609), resetsAt: resetsAt,
            leadingSliceCovered: true)
        XCTAssertEqual(r?.offMachinePct ?? -1, 61, accuracy: 1e-9,
                       "token rows alone cannot see a stretch whose tokens land 20 minutes later")
        XCTAssertEqual(r?.localPct ?? -1, 34, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedPct ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.totalUsedPct ?? -1, 95, accuracy: 1e-9)
    }

    /// The fix. With the liveness marks the series now carries, the window reads the way the tester
    /// lived it: 92 of 95 points on their own machine. The 3 that stay Elsewhere are the leading
    /// 2.0 and the 1.0 the account gained while the Mac was asleep — both genuinely not theirs.
    func testSept3WindowWithMarksResolvesToThisMachine() {
        let r = OffMachineEstimator.recompute(
            points: sept3Samples, tokenTimestamps: sept3Tokens, liveUsedPct: nil,
            now: window.addingTimeInterval(18_609), resetsAt: resetsAt,
            leadingSliceCovered: true)
        XCTAssertEqual(r?.offMachinePct ?? -1, 3, accuracy: 1e-9,
                       "only the sleeping span and the leading slice survive elimination")
        XCTAssertEqual(r?.localPct ?? -1, 92, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedPct ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.totalUsedPct ?? -1, 95, accuracy: 1e-9)
        XCTAssertTrue(r?.closeObserved ?? false)
    }

    /// A mark is evidence a surface was alive, never of an amount: it can move a delta between
    /// buckets and must never change the total or invent one.
    func testActivityMarksNeverMoveTheTotal() {
        let withMarks = OffMachineEstimator.recompute(
            points: sept3Samples, tokenTimestamps: sept3Tokens, liveUsedPct: nil,
            now: window.addingTimeInterval(18_609), resetsAt: resetsAt, leadingSliceCovered: true)
        let without = OffMachineEstimator.recompute(
            points: sept3SamplesWithoutMarks, tokenTimestamps: sept3Tokens, liveUsedPct: nil,
            now: window.addingTimeInterval(18_609), resetsAt: resetsAt, leadingSliceCovered: true)
        XCTAssertEqual(withMarks?.totalUsedPct ?? -1, without?.totalUsedPct ?? -2, accuracy: 1e-9)
        XCTAssertEqual((withMarks?.offMachinePct ?? 0) + (withMarks?.localPct ?? 0)
                       + (withMarks?.unattributedPct ?? 0),
                       withMarks?.totalUsedPct ?? -1, accuracy: 1e-9,
                       "the three buckets still close on the total")
    }

    /// The lower bound stays open, as it is for tokens: a mark landing exactly at `t₀` belongs to
    /// the interval that ended there and must not stop the next one settling.
    func testActivityMarkAtIntervalStartDoesNotBlockSettlement() {
        let points: [OffMachineEstimator.SeriesSample] = [
            .init(polledAt: base, usedPct: 0, lastLocalActivityAt: base),
            .init(polledAt: base.addingTimeInterval(300), usedPct: 4),
        ]
        let r = OffMachineEstimator.recompute(
            points: points, tokenTimestamps: [], liveUsedPct: nil,
            now: base.addingTimeInterval(900), resetsAt: resetsAt)
        XCTAssertEqual(r?.offMachinePct ?? -1, 4, accuracy: 1e-9,
                       "a mark at exactly t₀ belongs to the previous interval")
    }

    /// The whole seam through the store: `writePoll` stamps the mark, `quotaSeries` reads it back,
    /// and the walk acts on it — the path `PollCoordinator` actually takes. Without this the two
    /// pure tests above would pass over a column nothing populates.
    func testLivenessMarkSurvivesTheStoreRoundTrip() async throws {
        try await poll(pct: 0, at: base)
        // A local file write at 120s — no token row anywhere, which is the Codex write-lag shape.
        try await store.writePoll(
            snapshot: QuotaSnapshot(tool: .claude, primaryUsedPct: 7, primaryResetsAt: resetsAt,
                                    secondaryUsedPct: nil, secondaryResetsAt: nil,
                                    rateLimitReached: nil),
            lastLocalActivityAt: base.addingTimeInterval(120),
            now: base.addingTimeInterval(240))

        let rows = try await store.quotaSeries(tool: .claude, resetsAtNear: resetsAt)
        XCTAssertNil(rows.first?.lastLocalActivityAt, "the first poll had seen no local activity")
        XCTAssertEqual(rows.last?.lastLocalActivityAt, base.addingTimeInterval(120))

        let r = await OffMachineEstimator(store: store)
            .current(for: .claude, now: base.addingTimeInterval(900))
        XCTAssertEqual(r?.localPct ?? -1, 7, accuracy: 1e-9,
                       "a settled, token-free interval the machine was alive through is This machine")
        XCTAssertEqual(r?.offMachinePct ?? -1, 0, accuracy: 1e-9)
    }

    /// …and the upper bound stays guard-extended: a mark landing inside `G` past an interval's end
    /// is the write-lag case the guard exists for, and blocks that interval.
    func testActivityMarkInsideTheGuardBlocksSettlement() {
        let points: [OffMachineEstimator.SeriesSample] = [
            .init(polledAt: base, usedPct: 0),
            .init(polledAt: base.addingTimeInterval(300), usedPct: 4,
                  lastLocalActivityAt: base.addingTimeInterval(400)),
        ]
        let r = OffMachineEstimator.recompute(
            points: points, tokenTimestamps: [], liveUsedPct: nil,
            now: base.addingTimeInterval(900), resetsAt: resetsAt)
        XCTAssertEqual(r?.localPct ?? -1, 4, accuracy: 1e-9,
                       "a mark within G of the interval's end counts it Local")
        XCTAssertEqual(r?.offMachinePct ?? -1, 0, accuracy: 1e-9)
    }

    /// The window as it should have read: the leading 3.0 resolves by elimination, the block
    /// closes exactly, and `Not observed` is absent. Pre-fix this returned `off 2.0 /
    /// unattributed 3.0` — verified failing before the walk changed (STEP_81 discipline).
    func testLiveJuly29WindowResolvesEntirelyOffMachine() {
        let r = OffMachineEstimator.recompute(
            points: july29Samples, tokenTimestamps: [], liveUsedPct: nil,
            now: window.addingTimeInterval(30_000), resetsAt: resetsAt,
            leadingSliceCovered: true)
        XCTAssertEqual(r?.offMachinePct ?? -1, 5, accuracy: 1e-9,
                       "the leading 3.0 resolves by elimination under app coverage")
        XCTAssertEqual(r?.localPct ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedPct ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.totalUsedPct ?? -1, 5, accuracy: 1e-9)
        XCTAssertTrue(r?.closeObserved ?? false,
                      "polls ran to 166s before the close — as good as the cadence allows")
    }

    /// The same series with the app **quit** across part of `11:00–11:06:52`: today's answer,
    /// now for a stated reason. Zero backfill (§7.2) means the local corpus provably cannot
    /// speak for that span, so `Not observed` is the honest verdict rather than the default one.
    func testLiveJuly29WindowStaysUnattributedWhenAppWasQuit() {
        let r = OffMachineEstimator.recompute(
            points: july29Samples, tokenTimestamps: [], liveUsedPct: nil,
            now: window.addingTimeInterval(30_000), resetsAt: resetsAt,
            leadingSliceCovered: false)
        XCTAssertEqual(r?.offMachinePct ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedPct ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(r?.totalUsedPct ?? -1, 5, accuracy: 1e-9)
    }

    /// Tokens in the leading span ⇒ Local, matching the walk's "tokens present ⇒ Local". Positive
    /// evidence needs no guard wait, so this holds at any `now`.
    func testLeadingSliceWithLocalTokensIsLocal() {
        let r = OffMachineEstimator.recompute(
            points: july29Samples,
            tokenTimestamps: [window.addingTimeInterval(200)], liveUsedPct: nil,
            now: window.addingTimeInterval(30_000), resetsAt: resetsAt,
            leadingSliceCovered: true)
        XCTAssertEqual(r?.localPct ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(r?.offMachinePct ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedPct ?? -1, 0, accuracy: 1e-9)
    }

    /// A write landing exactly at the window start belongs to *this* window — the interval that
    /// would otherwise own it is in the previous window, a different denominator. Closed lower
    /// bound, deliberately unlike the interior intervals' open one.
    func testLeadingSliceLowerBoundIsClosed() {
        let r = OffMachineEstimator.recompute(
            points: july29Samples, tokenTimestamps: [window], liveUsedPct: nil,
            now: window.addingTimeInterval(30_000), resetsAt: resetsAt,
            leadingSliceCovered: true)
        XCTAssertEqual(r?.localPct ?? -1, 3, accuracy: 1e-9,
                       "a token at exactly windowStart claims the leading slice")
    }

    /// Inside the in-flight guard the slice stays unattributed rather than defaulting to Local:
    /// the app was never watching this span, so there is nothing to support a "This machine"
    /// claim. It settles to off-machine once the guard passes.
    func testLeadingSliceStaysUnattributedInsideTheGuard() {
        // A flat two-point series, so nothing the *interior* walk does can be mistaken for the
        // leading slice's verdict (interior intervals default to Local while pending — this
        // slice must not).
        let firstPoll = window.addingTimeInterval(412)
        let points: [OffMachineEstimator.SeriesSample] = [
            .init(polledAt: firstPoll, usedPct: 3),
            .init(polledAt: firstPoll.addingTimeInterval(240), usedPct: 3),
        ]
        let pending = OffMachineEstimator.recompute(
            points: points, tokenTimestamps: [], liveUsedPct: nil,
            now: firstPoll.addingTimeInterval(guardGap - 1), resetsAt: resetsAt,
            leadingSliceCovered: true)
        XCTAssertEqual(pending?.unattributedPct ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(pending?.localPct ?? -1, 0, accuracy: 1e-9,
                       "never a transient This-machine claim about an unwatched span")

        let settled = OffMachineEstimator.recompute(
            points: points, tokenTimestamps: [], liveUsedPct: nil,
            now: firstPoll.addingTimeInterval(guardGap), resetsAt: resetsAt,
            leadingSliceCovered: true)
        XCTAssertEqual(settled?.offMachinePct ?? -1, 3, accuracy: 1e-9,
                       "settles at exactly t_first + G (the `>=` boundary)")
        XCTAssertEqual(settled?.unattributedPct ?? -1, 0, accuracy: 1e-9)
    }

    /// Unknown token data (a failed read) can never produce an off-machine claim, covered or not.
    func testLeadingSliceNeedsTokenEvidence() {
        let r = OffMachineEstimator.recompute(
            points: july29Samples, tokenTimestamps: nil, liveUsedPct: nil,
            now: window.addingTimeInterval(30_000), resetsAt: resetsAt,
            leadingSliceCovered: true)
        XCTAssertEqual(r?.offMachinePct ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedPct ?? -1, 3, accuracy: 1e-9)
    }

    /// The `5.0 → 4.0 → 5.0` wobble in the real series is one true value drifting around 4.5,
    /// not two 1% bursts — the §11.2a high-water discipline, re-pinned now that the leading
    /// slice feeds the same accumulator.
    func testLiveJuly29QuantizationWobbleCountsOnce() {
        let r = OffMachineEstimator.recompute(
            points: july29Samples, tokenTimestamps: [], liveUsedPct: nil,
            now: window.addingTimeInterval(30_000), resetsAt: resetsAt,
            leadingSliceCovered: false)
        XCTAssertEqual(r?.offMachinePct ?? -1, 2, accuracy: 1e-9,
                       "two +1.0 rises, not three: the 4.0 dip must not re-bank the 5.0")
    }

    // MARK: The unobserved close (REV-56 §4.1 — STEP_84)

    /// Live 2026-07-29: the 05:00 window's last reading landed 03:43:59, an hour and a quarter
    /// before its close, with the Mac asleep. The total is a floor and says so.
    func testUnobservedCloseMarksTheTotalAsAFloor() {
        let close = window.addingTimeInterval(18_000)
        let points: [OffMachineEstimator.SeriesSample] = [
            .init(polledAt: window.addingTimeInterval(60), usedPct: 2),
            .init(polledAt: close.addingTimeInterval(-4_561), usedPct: 2),
        ]
        let r = OffMachineEstimator.recompute(
            points: points, tokenTimestamps: [], liveUsedPct: nil,
            now: close.addingTimeInterval(3_600), resetsAt: close, leadingSliceCovered: true)
        XCTAssertFalse(r?.closeObserved ?? true)
    }

    /// Boundary: a last reading exactly `closeObservationTolerance` before the close counts as
    /// observed; one second earlier does not.
    func testCloseObservationToleranceBoundary() {
        let close = window.addingTimeInterval(18_000)
        let tolerance = OffMachineEstimator.closeObservationTolerance
        func attribution(lastPollBeforeClose gap: TimeInterval) -> WindowAttribution? {
            OffMachineEstimator.recompute(
                points: [.init(polledAt: close.addingTimeInterval(-gap), usedPct: 2)],
                tokenTimestamps: [], liveUsedPct: nil,
                now: close.addingTimeInterval(3_600), resetsAt: close,
                leadingSliceCovered: false)
        }
        XCTAssertTrue(attribution(lastPollBeforeClose: tolerance)?.closeObserved ?? false)
        XCTAssertFalse(attribution(lastPollBeforeClose: tolerance + 1)?.closeObserved ?? true)
    }

    /// A window still running has no close to have missed — the marker is for a *recapped*
    /// window whose end the app slept through, not for the ordinary gap between polls.
    func testOpenWindowNeverCarriesTheFloorMarker() {
        let r = OffMachineEstimator.recompute(
            points: [.init(polledAt: window.addingTimeInterval(60), usedPct: 2)],
            tokenTimestamps: [], liveUsedPct: 2, now: window.addingTimeInterval(600),
            resetsAt: resetsAt, leadingSliceCovered: false)
        XCTAssertTrue(r?.closeObserved ?? false)
    }

    // MARK: Coverage through the store (the real read)

    /// End to end through `record`: lifecycle rows put the app launched before the window and
    /// asleep across the leading span, so the residue resolves off-machine. Sleep is covered —
    /// the process survives it with its file offsets, and a sleeping Mac cannot spend.
    func testSleepInsideLeadingSliceStillCounsAsCovered() async throws {
        try await store.writeLifecycleEvent(.launch, appVersion: "test",
                                            occurredAt: window.addingTimeInterval(-3_600))
        try await store.writeLifecycleEvent(.sleep, appVersion: "test",
                                            occurredAt: window.addingTimeInterval(60))
        try await store.writeLifecycleEvent(.wake, appVersion: "test",
                                            occurredAt: window.addingTimeInterval(180))
        try await poll(pct: 40, at: base.addingTimeInterval(240))
        try await poll(pct: 45, at: base.addingTimeInterval(480))
        let e = OffMachineEstimator(store: store)
        let r = await e.record(tool: .claude, resetsAt: resetsAt, windowSeconds: 18_000, currentUsedPct: 45,
                               now: base.addingTimeInterval(1_200))
        XCTAssertEqual(r?.offMachinePct ?? -1, 45, accuracy: 1e-9,
                       "sleep never breaks coverage")
        XCTAssertEqual(r?.unattributedPct ?? -1, 0, accuracy: 1e-9)
    }

    /// A relaunch inside the leading span is exactly the blind spot `Not observed` names: the
    /// fresh process seeded its file offsets to EOF, so anything written before it is lost.
    func testRelaunchInsideLeadingSliceBreaksCoverage() async throws {
        try await store.writeLifecycleEvent(.launch, appVersion: "test",
                                            occurredAt: window.addingTimeInterval(-3_600))
        try await store.writeLifecycleEvent(.launch, appVersion: "test",
                                            occurredAt: window.addingTimeInterval(120))
        try await poll(pct: 40, at: base.addingTimeInterval(240))
        try await poll(pct: 45, at: base.addingTimeInterval(480))
        let e = OffMachineEstimator(store: store)
        let r = await e.record(tool: .claude, resetsAt: resetsAt, windowSeconds: 18_000, currentUsedPct: 45,
                               now: base.addingTimeInterval(1_200))
        XCTAssertEqual(r?.unattributedPct ?? -1, 40, accuracy: 1e-9)
        XCTAssertEqual(r?.offMachinePct ?? -1, 5, accuracy: 1e-9)
    }

    // MARK: A window is as wide as the provider says (REV-60 — STEP_90)

    /// The live `go` account, 2026-08-11: a **43,200-minute** window that anchored at 18:47:40 and
    /// was consumed 19% → 97% by twelve turns run on this machine, in this project, over six
    /// minutes. The card said `Off-machine ≈97% of quota this window`.
    ///
    /// Every one of those turns is in `local_usage_events` and all 151 readings are in
    /// `quota_series`. The walk never saw the turns because the window's start was derived by
    /// subtracting a hardcoded five hours from a reset a month away — 2026-09-10 — which became
    /// the lower bound of the token query, so it returned nothing and every interval read as idle.
    /// **Verified failing before the fix: `off=97.0 local=0.0`.**
    func testMonthWideWindowAttributesLocalTurnsToThisMachine() async throws {
        let width: TimeInterval = 43_200 * 60
        let resetsAt = base.addingTimeInterval(width)
        try await store.writeLifecycleEvent(.launch, appVersion: "test",
                                            occurredAt: base.addingTimeInterval(-3_600))
        // The 151-row series, compressed to its shape: first reading 55s in at 19%, 97% by +380s,
        // a local turn just before each reading.
        for (offset, pct) in [(55.0, 19.0), (120.0, 35.0), (200.0, 60.0), (300.0, 84.0), (380.0, 97.0)] {
            try await token(tool: .codex, at: base.addingTimeInterval(offset - 10))
            try await poll(tool: .codex, pct: pct, resetsAt: resetsAt,
                           at: base.addingTimeInterval(offset))
        }
        let e = OffMachineEstimator(store: store)
        let r = await e.record(tool: .codex, resetsAt: resetsAt, windowSeconds: width,
                               currentUsedPct: 97, now: base.addingTimeInterval(1_200))
        XCTAssertEqual(r?.localPct ?? -1, 97, accuracy: 1e-9,
                       "every turn was on this machine — the whole window is local")
        XCTAssertEqual(r?.offMachinePct ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(r?.unattributedPct ?? -1, 0, accuracy: 1e-9)
    }

    /// The regression bar: five hours is Claude's real width and the width of every 300-minute
    /// Codex window, so an identical series must attribute identically on both sides of the
    /// change. This one passed **before** the fix too — that is the point of it.
    func testFiveHourWindowAttributesIdenticallyToBeforeTheChange() async throws {
        try await store.writeLifecycleEvent(.launch, appVersion: "test",
                                            occurredAt: base.addingTimeInterval(-3_600))
        for (offset, pct) in [(55.0, 19.0), (380.0, 97.0)] {
            try await token(at: base.addingTimeInterval(offset - 10))
            try await poll(pct: pct, at: base.addingTimeInterval(offset))
        }
        let e = OffMachineEstimator(store: store)
        let r = await e.record(tool: .claude, resetsAt: resetsAt, windowSeconds: 18_000,
                               currentUsedPct: 97, now: base.addingTimeInterval(1_200))
        XCTAssertEqual(r?.localPct ?? -1, 97, accuracy: 1e-9)
        XCTAssertEqual(r?.offMachinePct ?? -1, 0, accuracy: 1e-9)
    }

    /// The STEP_84 leading-slice rule is **unchanged** at month scale (REV-60 §5.1): a relaunch
    /// inside the leading span means zero backfill (§7.2) and the local corpus provably cannot
    /// speak for it, so the honest answer is `Not observed` — never an off-machine claim
    /// manufactured out of absent evidence.
    ///
    /// Pre-fix this was the opposite: the September window start made *any* launch look like it
    /// preceded the window, so coverage read true and the slice was claimed off-machine.
    /// **Verified failing before the fix: `off=30.0 unattributed=0.0`.**
    func testMonthWideWindowWithALifecycleGapStaysNotObserved() async throws {
        let width: TimeInterval = 43_200 * 60
        let resetsAt = base.addingTimeInterval(width)
        try await store.writeLifecycleEvent(.launch, appVersion: "test",
                                            occurredAt: base.addingTimeInterval(-3_600))
        try await store.writeLifecycleEvent(.launch, appVersion: "test",
                                            occurredAt: base.addingTimeInterval(20))
        for (offset, pct) in [(55.0, 19.0), (300.0, 30.0)] {
            try await poll(tool: .codex, pct: pct, resetsAt: resetsAt,
                           at: base.addingTimeInterval(offset))
        }
        let e = OffMachineEstimator(store: store)
        let r = await e.record(tool: .codex, resetsAt: resetsAt, windowSeconds: width,
                               currentUsedPct: 30, now: base.addingTimeInterval(1_200))
        XCTAssertEqual(r?.unattributedPct ?? -1, 19, accuracy: 1e-9,
                       "an unwatched leading slice is Not observed, never an off-machine claim")
        XCTAssertEqual(r?.offMachinePct ?? -1, 11, accuracy: 1e-9,
                       "the watched remainder still resolves by elimination")
    }

    /// The width reaches the pure walk, so the leading slice's bound moves with it: the same
    /// series and the same token, read as a five-hour window and as a month-wide one.
    func testPureWalkTakesTheReportedWidth() {
        let width: TimeInterval = 43_200 * 60
        let resetsAt = base.addingTimeInterval(width)
        let points: [OffMachineEstimator.SeriesSample] = [
            .init(polledAt: base.addingTimeInterval(55), usedPct: 19),
            .init(polledAt: base.addingTimeInterval(380), usedPct: 97),
        ]
        // A token inside the real window start → the leading slice is this machine's.
        let wide = OffMachineEstimator.recompute(
            points: points, tokenTimestamps: [base.addingTimeInterval(10)], liveUsedPct: nil,
            now: base.addingTimeInterval(1_200), resetsAt: resetsAt, windowSeconds: width,
            leadingSliceCovered: true)
        XCTAssertEqual(wide?.localPct ?? -1, 19, accuracy: 1e-9)

        // The same call defaulting to five hours puts the window start a month in the future,
        // so the token falls outside it and the slice is claimed off-machine — the exact defect.
        let narrow = OffMachineEstimator.recompute(
            points: points, tokenTimestamps: [base.addingTimeInterval(10)], liveUsedPct: nil,
            now: base.addingTimeInterval(1_200), resetsAt: resetsAt,
            leadingSliceCovered: true)
        XCTAssertEqual(narrow?.offMachinePct ?? -1, 97, accuracy: 1e-9,
                       "pinning what the wrong width does, so the fix cannot silently regress")
    }
}
