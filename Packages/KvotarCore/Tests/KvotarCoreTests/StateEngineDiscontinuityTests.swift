import XCTest
import GRDB
@testable import KvotarCore

/// §17.1 `window_reset` discontinuity rows ride the §13.2 `windowReset(tool)` emission
/// (STEP_52): one row per anchor (R33-7 dedup inherited), old/new = old/new `resets_at`,
/// `utilization_pct` = the last reading before the crossing — never the new window's.
final class StateEngineDiscontinuityTests: XCTestCase {

    private var dbPath: String!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-discontinuity-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    private func snapshot(used: Double?, resetMinutes: Double?) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: used,
                      primaryResetsAt: resetMinutes.map { now.addingTimeInterval($0 * 60) },
                      secondaryUsedPct: 18, secondaryResetsAt: nil, rateLimitReached: false)
    }

    private func inputs(_ snapshot: QuotaSnapshot?, at offset: TimeInterval = 0,
                        trigger: StateTrigger = .poll) -> StateInputs {
        StateInputs(tool: .claude, snapshot: snapshot, health: .healthy,
                    forecast: Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: nil,
                                       burnRatePerMin: nil, isEstimate: false, pollCount: 10),
                    trigger: trigger, now: now.addingTimeInterval(offset))
    }

    /// One `window_reset` row, flattened to Sendable values (GRDB `Row` cannot leave the actor).
    private struct ResetRow: Equatable {
        let tool: String
        let windowType: String?
        let observedAt: Int
        let oldValue: String?
        let newValue: String?
        let utilizationPct: Double?
    }

    private func resetRows(_ store: SQLiteStore) async throws -> [ResetRow] {
        try await store.withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT * FROM discontinuity_events
                    WHERE event_type = 'window_reset' ORDER BY id
                    """).map {
                        ResetRow(tool: $0["tool"], windowType: $0["window_type"],
                                 observedAt: $0["observed_at"], oldValue: $0["old_value"],
                                 newValue: $0["new_value"], utilizationPct: $0["utilization_pct"])
                    }
            }
        }
    }

    /// Advance clause: the reset-revealing poll carries the NEW window's numbers, so the row
    /// must hold the previous poll's utilization, and old/new anchors as unix seconds.
    func testAdvanceClauseWritesRowWithPreCrossingUtilization() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        _ = await engine.evaluate(inputs(snapshot(used: 90, resetMinutes: 30)))
        _ = await engine.evaluate(inputs(snapshot(used: 5, resetMinutes: 330), at: 60))

        let rows = try await resetRows(store)
        XCTAssertEqual(rows, [ResetRow(
            tool: "claude", windowType: "five_hour",
            observedAt: Int(now.timeIntervalSince1970) + 60,
            oldValue: String(Int(now.timeIntervalSince1970) + 30 * 60),
            newValue: String(Int(now.timeIntervalSince1970) + 330 * 60),
            utilizationPct: 90.0)],
            "utilization-at-crossing is the pre-reset reading, not the new window's 5%")
    }

    /// Expiry clause (R33-7): Claude's post-reset null payload carries no `resets_at` — the row
    /// records what is known: old anchor, NULL new, last pre-crossing utilization.
    func testExpiryClauseWritesRowWithNullNewValue() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        _ = await engine.evaluate(inputs(snapshot(used: 100, resetMinutes: 5)))
        _ = await engine.evaluate(inputs(snapshot(used: nil, resetMinutes: nil), at: 390))

        let rows = try await resetRows(store)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.oldValue, String(Int(now.timeIntervalSince1970) + 5 * 60))
        XCTAssertNil(rows.first?.newValue, "a pure expiry fire has no new anchor to record")
        XCTAssertEqual(rows.first?.utilizationPct, 100.0)
    }

    /// Once per anchor: a run of post-reset null polls must not append a row per cycle — the
    /// R33-7 anchor clearing is the dedup, same as for the notification-state event.
    func testNullPollRunWritesExactlyOneRow() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        _ = await engine.evaluate(inputs(snapshot(used: 100, resetMinutes: 5)))
        for offset in [390.0, 630.0, 870.0] {
            _ = await engine.evaluate(inputs(snapshot(used: nil, resetMinutes: nil), at: offset))
        }
        let rows = try await resetRows(store)
        XCTAssertEqual(rows.count, 1, "one anchor, one row — regardless of how many null polls follow")
    }

    /// Steady polls with an unchanged anchor write nothing.
    func testUnchangedAnchorWritesNothing() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        for offset in [0.0, 60.0, 120.0] {
            _ = await engine.evaluate(inputs(snapshot(used: 40 + offset / 60, resetMinutes: 30),
                                             at: offset))
        }
        let rows = try await resetRows(store)
        XCTAssertTrue(rows.isEmpty)
    }

    /// A relaunch across a rollover: the `.restore` evaluation seeds the anchor and the
    /// pre-crossing utilization from the restored snapshot, so the first live poll writes one
    /// row with a plausible utilization-at-crossing — not a duplicate, not a null.
    func testRestoreThenPollAcrossRolloverWritesOneRow() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        _ = await engine.evaluate(inputs(snapshot(used: 87, resetMinutes: 5), trigger: .restore))
        _ = await engine.evaluate(inputs(snapshot(used: nil, resetMinutes: nil), at: 390))

        let rows = try await resetRows(store)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.utilizationPct, 87.0,
                       "the restored snapshot's reading is the last known before the crossing")
    }

    // MARK: - REV-64 / STEP_102 — derived `window_type`, and the withdrawn window

    /// All rows of any type, in write order — the tests below assert on `event_type` itself.
    private func allRows(_ store: SQLiteStore) async throws -> [(type: String, row: ResetRow)] {
        try await store.withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM discontinuity_events ORDER BY id").map {
                    (type: $0["event_type"],
                     row: ResetRow(tool: $0["tool"], windowType: $0["window_type"],
                                   observedAt: $0["observed_at"], oldValue: $0["old_value"],
                                   newValue: $0["new_value"], utilizationPct: $0["utilization_pct"]))
                }
            }
        }
    }

    private func codexSnapshot(used: Double?, resetMinutes: Double?,
                               windowSeconds: Int) -> QuotaSnapshot {
        QuotaSnapshot(tool: .codex, primaryUsedPct: used,
                      primaryResetsAt: resetMinutes.map { now.addingTimeInterval($0 * 60) },
                      primaryWindowSeconds: windowSeconds,
                      secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false)
    }

    private func codexInputs(_ snapshot: QuotaSnapshot?, at offset: TimeInterval = 0,
                             trigger: StateTrigger = .poll,
                             runway: Double? = nil) -> StateInputs {
        StateInputs(tool: .codex, snapshot: snapshot, health: .healthy,
                    forecast: Forecast(tool: .codex, tier: .fullRunway, runwayMinutes: runway,
                                       burnRatePerMin: nil, isEstimate: false, pollCount: 10),
                    trigger: trigger, now: now.addingTimeInterval(offset))
    }

    /// **The regression the `primaryWindowLength` choice exists to prevent, and the one that would
    /// otherwise ship silently.** Claude reports no window width, so the width read falls back to
    /// REV-60's five hours — which is Claude's *true* width. Deriving the label must therefore
    /// leave Claude exactly where the deleted literal had it.
    func testClaudeStillWritesFiveHour() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        _ = await engine.evaluate(inputs(snapshot(used: 90, resetMinutes: 30)))
        _ = await engine.evaluate(inputs(snapshot(used: 5, resetMinutes: 330), at: 60))

        let rows = try await resetRows(store)
        XCTAssertEqual(rows.first?.windowType, "five_hour",
                       "Claude keeps its correct label through the fallback, not through a literal")
    }

    /// Codex stops borrowing Claude's label: a 7-day window says so.
    func testCodexWeeklyResetWritesWeekly() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        let week = 7 * 86_400
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 96, resetMinutes: 30, windowSeconds: week)))
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 2, resetMinutes: 10_110, windowSeconds: week), at: 60))

        let rows = try await resetRows(store)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.tool, "codex")
        XCTAssertEqual(rows.first?.windowType, "weekly",
                       "every such row was stamped five_hour before STEP_102")
    }

    /// And a 30-day one — the Free/Go grain, which produced the mislabelled rows §17.1 already
    /// noticed and left alone.
    func testCodexThirtyDayResetWritesMonthly() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        let month = 30 * 86_400
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 99, resetMinutes: 30, windowSeconds: month)))
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 1, resetMinutes: 43_230, windowSeconds: month), at: 60))

        let rows = try await resetRows(store)
        XCTAssertEqual(rows.first?.windowType, "monthly")
    }

    /// **The withdrawal, replayed** (REV-64 §5). A live 3% weekly window, then a poll in which the
    /// adapter reports the window unanchored while the remembered anchor is still six days out.
    /// Pre-STEP_102 neither clause fired: no row, and — worse — the anchor was never cleared.
    func testWithdrawnWindowWritesOneDemolitionRowAndClearsTheAnchor() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        let week = 7 * 86_400
        // 01:48 — a real, fixed anchor six days out at 3% used.
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 3, resetMinutes: 6 * 24 * 60, windowSeconds: week)))
        // 03:42 — the window is gone: no anchor, 0% used, width still reported ⇒ unanchored.
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 0, resetMinutes: nil, windowSeconds: week), at: 6_800))

        let rows = try await allRows(store)
        XCTAssertEqual(rows.count, 1, "one withdrawal, one row")
        XCTAssertEqual(rows.first?.type, "window_demolished",
                       "not a reset — the table's job is to tell those apart")
        XCTAssertEqual(rows.first?.row.windowType, "weekly")
        XCTAssertEqual(rows.first?.row.oldValue,
                       String(Int(now.timeIntervalSince1970) + 6 * 24 * 3_600),
                       "the anchor that was withdrawn")
        XCTAssertNil(rows.first?.row.newValue, "nothing replaced it")
        XCTAssertEqual(rows.first?.row.utilizationPct, 3.0, "what the provider forgave")
    }

    /// A run of unanchored polls after the withdrawal must not append a row per cycle — the anchor
    /// clearing is the dedup, exactly as it is for the two older clauses.
    func testWithdrawalRunWritesExactlyOneRow() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        let week = 7 * 86_400
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 3, resetMinutes: 6 * 24 * 60, windowSeconds: week)))
        for offset in [6_800.0, 12_100.0, 19_400.0] {
            _ = await engine.evaluate(codexInputs(
                codexSnapshot(used: 0, resetMinutes: nil, windowSeconds: week), at: offset))
        }
        let rows = try await allRows(store)
        XCTAssertEqual(rows.count, 1)
    }

    /// **The 2026-09-01 dogfood replay** (REV-85/D-109). At-risk at 99% used, then the provider
    /// withdraws the window: the calm candidate adopts on the demolition evaluation itself, not
    /// after 3 calm polls — the popover was painting a fresh 100%-left window with the dead
    /// window's At-risk card ("Finish your current task and pause new prompts") for ~2 minutes.
    func testWithdrawalBypassesTheDeEscalationHold() async throws {
        let engine = StateEngine()
        let week = 7 * 86_400
        let before = await engine.evaluate(codexInputs(
            codexSnapshot(used: 99, resetMinutes: 25, windowSeconds: week), runway: 5))
        XCTAssertEqual(before.state, .atRisk, "precondition: the old window's verdict")
        let after = await engine.evaluate(codexInputs(
            codexSnapshot(used: 0, resetMinutes: nil, windowSeconds: week), at: 60))
        XCTAssertEqual(after.state, .healthy,
                       "a verdict measured against a withdrawn window must not outlive it")
    }

    /// **The fiction the dead anchor produced.** Six hours after the withdrawal a genuine window
    /// opened, and the advance clause compared it against the corpse — writing a `window_reset`
    /// claiming a crossing of a deadline that never arrived, at a utilization from a window
    /// destroyed that morning. With the anchor cleared, the new window simply seeds a fresh one.
    func testGenuineStartAfterWithdrawalDoesNotReachBackForTheCorpse() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = StateEngine(store: store)
        let week = 7 * 86_400
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 3, resetMinutes: 6 * 24 * 60, windowSeconds: week)))
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 0, resetMinutes: nil, windowSeconds: week), at: 6_800))
        // ~6h later a real window opens and anchors a full week out.
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 1, resetMinutes: 24_460, windowSeconds: week), at: 24_400))

        let rows = try await allRows(store)
        XCTAssertEqual(rows.map(\.type), ["window_demolished"],
                       "no window_reset: there was no anchor left to fabricate a crossing from")
    }

    /// **No notification, no bus event.** The user's quota improved; there is nothing to act on,
    /// which is what keeps this outside STEP_101's notification scope. Asserted by discrimination:
    /// a withdrawal on Codex followed by a genuine Claude reset must leave Claude first in the
    /// stream — the stream preserves order, so a Codex yield would arrive ahead of it.
    func testWithdrawalEmitsNoWindowResetEvent() async throws {
        let engine = StateEngine()
        let week = 7 * 86_400
        // `snapshot(resetMinutes:)` is relative to the fixed base, `inputs(at:)` shifts the clock —
        // so a Claude window evaluated at +6800s needs its reset expressed from that offset too,
        // or it is already expired and fires nothing (and `iterator.next()` waits forever).
        let offsetMinutes = 6_800.0 / 60
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 3, resetMinutes: 6 * 24 * 60, windowSeconds: week)))
        _ = await engine.evaluate(codexInputs(
            codexSnapshot(used: 0, resetMinutes: nil, windowSeconds: week), at: 6_800))
        _ = await engine.evaluate(inputs(snapshot(used: 90, resetMinutes: offsetMinutes + 30),
                                         at: 6_800))
        _ = await engine.evaluate(inputs(snapshot(used: 5, resetMinutes: offsetMinutes + 330),
                                         at: 6_860))

        var iterator = engine.windowResets.makeAsyncIterator()
        let tool = await iterator.next()
        XCTAssertEqual(tool, .claude,
                       "a withdrawn window must not announce a reset — nothing rolled over")
    }
}
