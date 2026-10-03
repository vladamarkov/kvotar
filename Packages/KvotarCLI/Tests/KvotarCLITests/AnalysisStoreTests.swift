import XCTest
import GRDB
@testable import KvotarCLI

/// The corpus half of `kvotar import` (STEP_74): provenance, row identity, and the two shapes
/// it refuses outright.
final class AnalysisStoreTests: XCTestCase {

    private var work: URL!
    private var corpusPath: String { work.appendingPathComponent("corpus.db").path }

    override func setUpWithError() throws {
        work = try BundleFixture.makeWorkingDirectory()
    }

    override func tearDownWithError() throws {
        BundleFixture.cleanUp(work)
    }

    /// Reads a bundle directory the way the command does.
    private func bundle(at url: URL) throws -> BundleReader.Bundle {
        var reader = BundleReader()
        return try reader.read(path: url.path)
    }

    private func pollSnapshots(_ rows: [(Int, String, Int)]) -> [String] {
        var sql = ["CREATE TABLE poll_snapshots (id INTEGER, tool TEXT, used_pct INTEGER)"]
        sql += rows.map { "INSERT INTO poll_snapshots VALUES (\($0.0), '\($0.1)', \($0.2))" }
        return sql
    }

    // MARK: - The sanitized shape

    /// A bundle written without an authorized capture window carries no database. It must still be
    /// recorded: an unrecorded bundle is offered as new at every import, and "Erin exported on the
    /// 20th with capture off" is itself a fact worth keeping.
    func testSanitizedBundleIsRecordedWithNoTables() throws {
        let source = try BundleFixture.make(
            in: work, named: "erin-bundle",
            whatLookedWrong: "Menu bar froze at 4%.",
            summary: #"{"pollSnapshots":128}"#, sql: nil)

        let store = try AnalysisStore(path: corpusPath)
        let outcome = try store.importBundle(try bundle(at: source), tester: "erin")

        XCTAssertTrue(outcome.tables.isEmpty)
        XCTAssertEqual(outcome.sourceRows, 0)
        XCTAssertEqual(outcome.importCount, 1)

        let recorded = try BundleFixture.rows(
            corpusPath, sql: "SELECT tester_id, bundle_id FROM bundles")
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?["tester_id"] as String?, "erin")
    }

    /// Re-importing it counts the import without duplicating the bundle — the same guarantee the
    /// database-carrying shape has always had.
    func testReimportingASanitizedBundleDoesNotDuplicateIt() throws {
        let source = try BundleFixture.make(
            in: work, named: "erin-bundle", summary: #"{"pollSnapshots":128}"#, sql: nil)

        let store = try AnalysisStore(path: corpusPath)
        _ = try store.importBundle(try bundle(at: source), tester: "erin")
        let second = try store.importBundle(try bundle(at: source), tester: "erin")

        XCTAssertEqual(second.importCount, 2)
        let recorded = try BundleFixture.rows(corpusPath, sql: "SELECT bundle_id FROM bundles")
        XCTAssertEqual(recorded.count, 1, "the same bundle must not be recorded twice")
    }

    // MARK: - Provenance

    /// Every copied row must be able to say which machine it came from — a corpus that cannot is
    /// useless for the cross-tester findings this command exists for.
    func testEveryCopiedRowCarriesItsTesterAndBundle() throws {
        let source = try BundleFixture.make(
            in: work, named: "alice-bundle",
            sql: pollSnapshots([(1, "claude", 40), (2, "claude", 55), (3, "codex", 12)]))

        let store = try AnalysisStore(path: corpusPath)
        let outcome = try store.importBundle(try bundle(at: source), tester: "alice")

        XCTAssertEqual(outcome.sourceRows, 3)
        XCTAssertEqual(outcome.inserted, 3)

        let columns = try BundleFixture.columns(corpusPath, table: "poll_snapshots")
        for column in AnalysisStore.provenanceColumns {
            XCTAssertTrue(columns.contains(column), "copied table is missing \(column)")
        }

        let rows = try BundleFixture.rows(
            corpusPath, sql: "SELECT tester_id, bundle_id, src_rowid FROM poll_snapshots ORDER BY src_rowid")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0["tester_id"] as String }, ["alice", "alice", "alice"])
        XCTAssertEqual(Set(rows.map { $0["bundle_id"] as String }), [outcome.bundleID])
        XCTAssertEqual(rows.map { $0["src_rowid"] as Int }, [1, 2, 3],
                       "src_rowid should point back at the row in the tester's own database")
    }

    /// `bundle_tables` is what makes an import auditable per table.
    func testBundleTablesRecordsWhatEachTableMoved() throws {
        let source = try BundleFixture.make(
            in: work, named: "alice-bundle",
            sql: pollSnapshots([(1, "claude", 40)])
                + ["CREATE TABLE popover_opens (opened_at INTEGER, tab TEXT)",
                   "INSERT INTO popover_opens VALUES (1786568900, 'claude')"])

        let store = try AnalysisStore(path: corpusPath)
        try store.importBundle(try bundle(at: source), tester: "alice")

        let rows = try BundleFixture.rows(
            corpusPath,
            sql: "SELECT table_name, source_rows, inserted_rows FROM bundle_tables ORDER BY table_name")
        XCTAssertEqual(rows.map { $0["table_name"] as String }, ["poll_snapshots", "popover_opens"])
        XCTAssertEqual(rows.map { $0["inserted_rows"] as Int }, [1, 1])
    }

    /// `grdb_migrations` travels as a `bundles` column instead of being copied as a table.
    func testMigrationTableIsNotCopiedButItsVersionIsRecorded() throws {
        let source = try BundleFixture.make(
            in: work, named: "alice-bundle",
            manifestJSON: BundleFixture.manifest(schemaMigration: nil),
            sql: pollSnapshots([(1, "claude", 40)])
                + ["CREATE TABLE grdb_migrations (identifier TEXT)",
                   "INSERT INTO grdb_migrations VALUES ('v16_duplicate_event_cleanup')",
                   "INSERT INTO grdb_migrations VALUES ('v17_cache_write_tiers')"])

        let store = try AnalysisStore(path: corpusPath)
        let outcome = try store.importBundle(try bundle(at: source), tester: "alice")

        XCTAssertEqual(outcome.schemaMigration, "v17_cache_write_tiers",
                       "with no manifest schema, the newest migration row should stand in")
        XCTAssertFalse(try BundleFixture.columns(corpusPath, table: "bundles").isEmpty)
        let tables = try BundleFixture.rows(
            corpusPath, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            .map { $0["name"] as String }
        XCTAssertFalse(tables.contains("grdb_migrations"))
    }

    // MARK: - Idempotency

    /// The property that matters most in the field: a tester sends an updated bundle, and the
    /// corpus must not silently double.
    func testReimportingTheSameBundleInsertsNothing() throws {
        let source = try BundleFixture.make(
            in: work, named: "alice-bundle",
            sql: pollSnapshots([(1, "claude", 40), (2, "claude", 55)]))

        let store = try AnalysisStore(path: corpusPath)
        let first = try store.importBundle(try bundle(at: source), tester: "alice")
        let second = try store.importBundle(try bundle(at: source), tester: "alice")

        XCTAssertEqual(first.inserted, 2)
        XCTAssertEqual(second.sourceRows, 2)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.duplicates, 2)
        XCTAssertEqual(second.importCount, 2, "the counter distinguishes 'nothing new' from 'never imported'")
        XCTAssertEqual(try BundleFixture.count(corpusPath, table: "poll_snapshots"), 2)
    }

    /// A later bundle from the same machine overlaps the earlier one; only genuinely new rows land.
    func testOverlappingLaterBundleInsertsOnlyWhatIsNew() throws {
        let earlier = try BundleFixture.make(
            in: work, named: "alice-monday",
            sql: pollSnapshots([(1, "claude", 40), (2, "claude", 55)]))
        let later = try BundleFixture.make(
            in: work, named: "alice-tuesday",
            manifestJSON: BundleFixture.manifest(generatedAt: 1786655300),
            sql: pollSnapshots([(1, "claude", 40), (2, "claude", 55), (3, "claude", 71)]))

        let store = try AnalysisStore(path: corpusPath)
        try store.importBundle(try bundle(at: earlier), tester: "alice")
        let second = try store.importBundle(try bundle(at: later), tester: "alice")

        XCTAssertEqual(second.sourceRows, 3)
        XCTAssertEqual(second.inserted, 1)
        XCTAssertEqual(try BundleFixture.count(corpusPath, table: "poll_snapshots"), 3)
    }

    /// Identity is `(tester, row contents)`, so the same archive under two labels stays two
    /// histories — the corpus must never merge two machines because their rows happen to match.
    func testTheSameBundleUnderTwoTestersKeepsBothHistories() throws {
        let source = try BundleFixture.make(
            in: work, named: "shared-bundle",
            sql: pollSnapshots([(1, "claude", 40), (2, "claude", 55)]))

        let store = try AnalysisStore(path: corpusPath)
        try store.importBundle(try bundle(at: source), tester: "alice")
        try store.importBundle(try bundle(at: source), tester: "bob")

        XCTAssertEqual(try BundleFixture.count(corpusPath, table: "poll_snapshots"), 4)
        XCTAssertEqual(try store.testerSummary().map(\.tester), ["alice", "bob"])
    }

    // MARK: - Schema drift

    /// Bundles from different app versions coexist: the corpus widens, and a row that merely gained
    /// a null-backfilled column stays one row rather than becoming two.
    func testNewerBundleWidensTheCorpusWithoutDuplicatingCarriedRows() throws {
        let old = try BundleFixture.make(
            in: work, named: "alice-old",
            manifestJSON: BundleFixture.manifest(appVersion: "0.1.2 (3)"),
            sql: ["CREATE TABLE poll_snapshots (id INTEGER, tool TEXT)",
                  "INSERT INTO poll_snapshots VALUES (1, 'claude')"])
        let new = try BundleFixture.make(
            in: work, named: "alice-new",
            manifestJSON: BundleFixture.manifest(appVersion: "0.1.9 (12)"),
            sql: ["CREATE TABLE poll_snapshots (id INTEGER, tool TEXT, window_width INTEGER)",
                  "INSERT INTO poll_snapshots VALUES (1, 'claude', NULL)",
                  "INSERT INTO poll_snapshots VALUES (2, 'codex', 300)"])

        let store = try AnalysisStore(path: corpusPath)
        try store.importBundle(try bundle(at: old), tester: "alice")
        let second = try store.importBundle(try bundle(at: new), tester: "alice")

        XCTAssertTrue(try BundleFixture.columns(corpusPath, table: "poll_snapshots")
            .contains("window_width"), "the corpus should widen for a newer schema")
        XCTAssertEqual(second.inserted, 1, "the carried row gained only a null column — still one row")
        XCTAssertEqual(try BundleFixture.count(corpusPath, table: "poll_snapshots"), 2)
    }

    // MARK: - Refusals

    /// A bundle table named like the corpus's own bookkeeping would collide with it.
    func testTableNamedLikeCorpusBookkeepingIsRefused() throws {
        let source = try BundleFixture.make(
            in: work, named: "odd-bundle",
            sql: ["CREATE TABLE bundles (id INTEGER)", "INSERT INTO bundles VALUES (1)"])

        let store = try AnalysisStore(path: corpusPath)
        XCTAssertThrowsError(try store.importBundle(try bundle(at: source), tester: "alice")) { error in
            guard case AnalysisStore.StoreError.reservedTableName(let name) = error else {
                return XCTFail("expected reservedTableName, got \(error)")
            }
            XCTAssertEqual(name, "bundles")
        }
    }

    /// Shadowing a source column with a provenance column would quietly lose the tester's data.
    func testSourceColumnClashingWithProvenanceIsRefused() throws {
        let source = try BundleFixture.make(
            in: work, named: "odd-bundle",
            sql: ["CREATE TABLE poll_snapshots (tester_id TEXT, used_pct INTEGER)",
                  "INSERT INTO poll_snapshots VALUES ('someone-else', 40)"])

        let store = try AnalysisStore(path: corpusPath)
        XCTAssertThrowsError(try store.importBundle(try bundle(at: source), tester: "alice")) { error in
            guard case AnalysisStore.StoreError.columnCollision(let table, let column) = error else {
                return XCTFail("expected columnCollision, got \(error)")
            }
            XCTAssertEqual(table, "poll_snapshots")
            XCTAssertEqual(column, "tester_id")
        }
    }

    /// The bundle's own database is opened read-only — an import must never write a tester's data.
    func testImportDoesNotModifyTheBundleDatabase() throws {
        let source = try BundleFixture.make(
            in: work, named: "alice-bundle",
            sql: pollSnapshots([(1, "claude", 40), (2, "claude", 55)]))
        let databasePath = source.appendingPathComponent("kvotar.db").path
        let before = try FileManager.default.attributesOfItem(atPath: databasePath)

        let store = try AnalysisStore(path: corpusPath)
        try store.importBundle(try bundle(at: source), tester: "alice")

        let after = try FileManager.default.attributesOfItem(atPath: databasePath)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(before[.size] as? Int, after[.size] as? Int)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath + "-wal"),
                       "a read-only open must not leave a write-ahead log behind")
    }
}
