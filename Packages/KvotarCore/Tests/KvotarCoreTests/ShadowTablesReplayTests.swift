import XCTest
import GRDB
@testable import KvotarCore

/// Reconciles `ShadowTablesReader` against an independently written implementation of the same
/// §11.5 rules, over the same real corpus (STEP_190).
///
/// The reconciliation the step contract asks for cannot be run through the shipped eligibility
/// path: STEP_190 ruling 1 admits only windows a `v24`-era build recorded exposure for, and on
/// 2026-09-14 — the day after `v24` landed — that is almost none. So the **fold** is what is
/// checked here, with every window supplied as recorded and unwarned, against the Python
/// derivation the shipped prior was computed with (`scripts/shadow_prior.py`). Two implementations
/// written from the same §11.5 text, over 29,785 real polls, agreeing on origin counts, hit counts
/// and the chosen alpha is the evidence that the rule in Swift is the rule that was measured.
///
/// Read-only, and against a **copy** — the live database is never opened in place. Run with:
///
///     KVOTAR_LIVE=1 swift test --filter ShadowTablesReplayTests
///
/// Override the path with `KVOTAR_REPLAY_DB`. Skipped when neither is set, so CI stays hermetic.
final class ShadowTablesReplayTests: XCTestCase {

    private func replayDatabase() throws -> String? {
        guard ProcessInfo.processInfo.environment["KVOTAR_LIVE"] == "1",
              let path = ProcessInfo.processInfo.environment["KVOTAR_REPLAY_DB"],
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private func points(from path: String, tool: Tool) throws -> [QuotaSeriesPoint] {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT polled_at, primary_used_pct, primary_resets_at, primary_window_seconds
                  FROM quota_series WHERE tool = ? ORDER BY polled_at ASC
                """, arguments: [tool.rawValue])
            .map { row in
                QuotaSeriesPoint(
                    polledAt: Date(timeIntervalSince1970: TimeInterval(row["polled_at"] as Int)),
                    usedPct: row["primary_used_pct"] as Double,
                    resetsAt: Date(timeIntervalSince1970:
                                    TimeInterval(row["primary_resets_at"] as Int)),
                    windowSeconds: row["primary_window_seconds"] as Int?)
            }
        }
    }

    /// Every window admitted, unwarned — the fold under test, not the eligibility gate.
    private func openExposures(_ points: [QuotaSeriesPoint]) -> [WindowExposure] {
        Set(points.map(\.resetsAt)).map {
            WindowExposure(anchor: $0, recorded: true, warningFirstShownAt: nil)
        }
    }

    func testTheSwiftFoldMatchesThePythonDerivation() throws {
        guard let path = try replayDatabase() else {
            throw XCTSkip("set KVOTAR_LIVE=1 and KVOTAR_REPLAY_DB to a database copy")
        }
        let points = try points(from: path, tool: .claude)
        XCTAssertFalse(points.isEmpty, "the copy carries a Claude series")

        // `now` past every reset in the corpus, so nothing is excluded merely for being current.
        let now = (points.map(\.resetsAt).max() ?? Date()).addingTimeInterval(86_400)
        let tables = ShadowTablesReader.build(tool: .claude, points: points,
                                              exposures: openExposures(points), now: now)

        // `scripts/shadow_prior.py` on the same copy, 2026-09-14:
        //   77 completed short windows, 1,862 origins
        //   burning 811 / 711 hits / alpha 0.0
        //   paused  384 / 238 hits / alpha 0.75
        //   quiet   667 / 188 hits / alpha 1.0
        //   all-state alpha 0.5
        XCTAssertEqual(tables.completedWindows, 77)
        XCTAssertEqual(tables.originCount, 1862)
        XCTAssertEqual(tables.cells[.burning]?.n, 811)
        XCTAssertEqual(tables.cells[.burning]?.hits, 711)
        XCTAssertEqual(tables.cells[.paused]?.n, 384)
        XCTAssertEqual(tables.cells[.paused]?.hits, 238)
        XCTAssertEqual(tables.cells[.quiet]?.n, 667)
        XCTAssertEqual(tables.cells[.quiet]?.hits, 188)
        XCTAssertEqual(tables.cells[.burning]?.alpha, 0.0)
        XCTAssertEqual(tables.cells[.paused]?.alpha, 0.75)
        XCTAssertEqual(tables.cells[.quiet]?.alpha, 1.0)
        XCTAssertEqual(tables.allStateAlpha, 0.5)
    }

    /// The shipped prior's probabilities are these counts, so the two must agree. Any future drift
    /// in the fold shows up here as a prior that no longer describes the corpus it came from.
    func testThePriorDescribesTheCorpusItWasDerivedFrom() throws {
        guard let path = try replayDatabase() else {
            throw XCTSkip("set KVOTAR_LIVE=1 and KVOTAR_REPLAY_DB to a database copy")
        }
        let points = try points(from: path, tool: .claude)
        let now = (points.map(\.resetsAt).max() ?? Date()).addingTimeInterval(86_400)
        let tables = ShadowTablesReader.build(tool: .claude, points: points,
                                              exposures: openExposures(points), now: now)
        for state in ShadowAccountState.allCases {
            guard let cell = tables.cells[state], cell.n > 0 else { continue }
            XCTAssertEqual(Double(cell.hits) / Double(cell.n),
                           ShadowTables.prior.probability[state]!, accuracy: 0.001,
                           "\(state) — the prior is this corpus's own rate")
        }
    }

    /// Codex contributes nothing on this machine, and the reason is a property of the data rather
    /// than a defect: the current plan reports a seven-day primary (long, out of §11.5's scope) and
    /// every older five-hour row predates `v23` and so states no width at all.
    func testCodexContributesNoEligibleWindowsOnThisCorpus() throws {
        guard let path = try replayDatabase() else {
            throw XCTSkip("set KVOTAR_LIVE=1 and KVOTAR_REPLAY_DB to a database copy")
        }
        let points = try points(from: path, tool: .codex)
        let now = (points.map(\.resetsAt).max() ?? Date()).addingTimeInterval(86_400)
        let tables = ShadowTablesReader.build(tool: .codex, points: points,
                                              exposures: openExposures(points), now: now)
        XCTAssertEqual(tables.completedWindows, 0)
    }
}
