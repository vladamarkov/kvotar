import XCTest
import GRDB
@testable import KvotarCore

final class LegacyDataMigratorTests: XCTestCase {
    private var root: URL!
    private var legacy: URL!
    private var kvotar: URL!
    private var receipt: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvotar-migration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        legacy = root.appendingPathComponent("AgentPilot/agentpilot.db")
        kvotar = root.appendingPathComponent("Kvotar/kvotar.db")
        receipt = root.appendingPathComponent("Kvotar/kvotar-migration.json")
    }

    override func tearDownWithError() throws {
        if root != nil { try? FileManager.default.removeItem(at: root) }
    }

    func testCleanInstallCreatesNoLegacyData() throws {
        let result = try migrator().migrateIfNeeded()
        XCTAssertEqual(result.outcome, .cleanInstall)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kvotar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))
    }

    func testMigratesBackupAndNeverChangesLegacyFiles() async throws {
        let source = try await makeLegacyStore()
        try await source.writeSetting(key: "migration_probe", value: "preserved")
        let sourceFilesBefore = try databaseFileSnapshot(at: legacy)

        let result = try migrator().migrateIfNeeded()

        XCTAssertEqual(result.outcome, .migrated)
        XCTAssertEqual(try databaseFileSnapshot(at: legacy), sourceFilesBefore)
        let migrated = try SQLiteStore.openReadOnly(path: kvotar.path)
        let value = try await migrated.readSetting(key: "migration_probe")
        XCTAssertEqual(value, "preserved")
        XCTAssertNotNil(result.schemaMigration)
    }

    func testValidNonEmptyKvotarStoreIsNeverOverwritten() async throws {
        _ = try await makeLegacyStore()
        let existing = try await makeStore(at: kvotar, setting: "kvotar_wins")
        let before = try Data(contentsOf: kvotar)

        let result = try migrator().migrateIfNeeded()

        XCTAssertEqual(result.outcome, .preservedExistingKvotarStore)
        XCTAssertEqual(try Data(contentsOf: kvotar), before)
        let value = try await existing.readSetting(key: "probe")
        XCTAssertEqual(value, "kvotar_wins")
    }

    func testInterruptedCopyIsCleanedAndRerunSucceeds() async throws {
        _ = try await makeLegacyStore()
        enum Stop: Error { case simulated }
        XCTAssertThrowsError(try migrator(afterValidatedCopy: { throw Stop.simulated }).migrateIfNeeded())
        XCTAssertFalse(FileManager.default.fileExists(atPath: kvotar.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: kvotar.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix(".kvotar-migration-") })

        XCTAssertEqual(try migrator().migrateIfNeeded().outcome, .migrated)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            at: kvotar.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix(".kvotar-migration-") })
    }

    func testFutureKvotarUpdateIsIdempotentWithoutLegacyStore() async throws {
        _ = try await makeStore(at: kvotar, setting: "future")
        let before = try Data(contentsOf: kvotar)

        let first = try migrator().migrateIfNeeded()
        let second = try migrator().migrateIfNeeded()

        XCTAssertEqual(first.outcome, .preservedExistingKvotarStore)
        XCTAssertEqual(second.outcome, .preservedExistingKvotarStore)
        XCTAssertEqual(try Data(contentsOf: kvotar), before)
    }

    func testInvalidNonEmptyDestinationFailsClosedWithoutOverwrite() async throws {
        _ = try await makeLegacyStore()
        try FileManager.default.createDirectory(
            at: kvotar.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("not a database".utf8)
        try invalid.write(to: kvotar)

        XCTAssertThrowsError(try migrator().migrateIfNeeded()) { error in
            guard case LegacyDataMigrator.MigrationError.invalidExistingKvotarDatabase = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: kvotar), invalid)
    }

    func testOpeningMigratedV19CopyPurgesLegacyDiagnosticBodiesOnlyInKvotar() async throws {
        let source = try await makeLegacyStore()
        try await source.withPool { pool in
            try pool.write { db in
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                               arguments: ["v20_time_limited_diagnostics"])
                try db.execute(sql: "UPDATE settings SET value = '19' WHERE key = 'schema_version'")
                try db.execute(sql: """
                    INSERT INTO raw_payloads
                        (tool, endpoint, captured_at, http_status, body, shape_hash, keep_reason)
                    VALUES ('claude', 'claude_usage', 1, 200, '{"prompt":"legacy"}', 'x', 'window')
                    """)
                try db.execute(sql: """
                    INSERT INTO poll_health_events
                        (tool, endpoint, timestamp, retry_after_seconds, consecutive_count,
                         base_interval_at_time, response_headers_json, response_body, category)
                    VALUES ('claude', 'oauth_usage', 1, 30, 1, 60,
                            '{"Set-Cookie":"legacy"}', '{"prompt":"legacy"}', 'transient')
                    """)
            }
        }

        XCTAssertEqual(try migrator().migrateIfNeeded().outcome, .migrated)
        let migrated = try SQLiteStore(path: kvotar.path)

        try await migrated.withPool { pool in
            try pool.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM raw_payloads"), 0)
                let row = try Row.fetchOne(db, sql: "SELECT * FROM poll_health_events")
                XCTAssertNil(row?["response_headers_json"] as String?)
                XCTAssertNil(row?["response_body"] as String?)
            }
        }
        try await source.withPool { pool in
            try pool.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM raw_payloads"), 1)
                let body = try String.fetchOne(
                    db, sql: "SELECT response_body FROM poll_health_events LIMIT 1")
                XCTAssertEqual(body, "{\"prompt\":\"legacy\"}")
            }
        }
    }

    func testDeletedKvotarStoreStartsCleanInsteadOfReimportingStaleLegacyData() async throws {
        let source = try await makeLegacyStore()
        XCTAssertEqual(try migrator().migrateIfNeeded().outcome, .migrated)
        try FileManager.default.removeItem(at: kvotar)

        let result = try migrator().migrateIfNeeded()

        XCTAssertEqual(result.outcome, .cleanStartAfterPriorRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: kvotar.path))
        let legacyIntact = try await source.readSetting(key: "probe")
        XCTAssertEqual(legacyIntact, "legacy")
    }

    func testUndecodableReceiptAlsoBlocksReimport() async throws {
        let source = try await makeLegacyStore()
        XCTAssertEqual(try migrator().migrateIfNeeded().outcome, .migrated)
        try FileManager.default.removeItem(at: kvotar)
        try Data("not json".utf8).write(to: receipt)

        XCTAssertEqual(try migrator().migrateIfNeeded().outcome, .cleanStartAfterPriorRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: kvotar.path))
        let legacyIntact = try await source.readSetting(key: "probe")
        XCTAssertEqual(legacyIntact, "legacy")
    }

    func testCleanInstallReceiptStillAllowsALaterMigration() async throws {
        XCTAssertEqual(try migrator().migrateIfNeeded().outcome, .cleanInstall)
        let source = try await makeLegacyStore()

        XCTAssertEqual(try migrator().migrateIfNeeded().outcome, .migrated)

        let migrated = try SQLiteStore.openReadOnly(path: kvotar.path)
        let imported = try await migrated.readSetting(key: "probe")
        XCTAssertEqual(imported, "legacy")
        let legacyIntact = try await source.readSetting(key: "probe")
        XCTAssertEqual(legacyIntact, "legacy")
    }

    private func migrator(
        afterValidatedCopy: (@Sendable () throws -> Void)? = nil
    ) -> LegacyDataMigrator {
        LegacyDataMigrator(
            legacyDatabaseURL: legacy,
            kvotarDatabaseURL: kvotar,
            receiptURL: receipt,
            now: { Date(timeIntervalSince1970: 1_777_777_777) },
            afterValidatedCopy: afterValidatedCopy)
    }

    private func makeLegacyStore() async throws -> SQLiteStore {
        try await makeStore(at: legacy, setting: "legacy")
    }

    private func makeStore(at url: URL, setting: String) async throws -> SQLiteStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try SQLiteStore(path: url.path)
        try await store.writeSetting(key: "probe", value: setting)
        return store
    }

    private func databaseFileSnapshot(at url: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                snapshot[suffix.isEmpty ? "database" : suffix] = try Data(contentsOf: file)
            }
        }
        return snapshot
    }
}
