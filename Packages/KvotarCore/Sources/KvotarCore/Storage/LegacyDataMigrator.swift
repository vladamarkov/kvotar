import Foundation
import GRDB

/// Copy-only first-launch migration from AgentPilot storage into Kvotar-owned storage.
///
/// The legacy process guard is acquired before this runs, so its database and WAL are stable. Those
/// files are byte-copied without opening the source, then SQLite recovery, checkpointing, and
/// validation happen only inside the Kvotar temporary copy. An atomic same-directory move publishes
/// the validated result as `kvotar.db`.
///
/// The import happens once. The receipt written beside the database records that it did, so a later
/// launch whose database has gone missing starts clean rather than re-importing a snapshot that is
/// by then months stale.
public struct LegacyDataMigrator {
    public enum Outcome: String, Codable, Sendable {
        case cleanInstall
        case migrated
        case preservedExistingKvotarStore
        /// Kvotar storage is absent, but an earlier run already established it. The legacy store is
        /// deliberately not re-imported — see `migrateIfNeeded()`.
        case cleanStartAfterPriorRun
    }

    public struct Receipt: Codable, Equatable, Sendable {
        public let outcome: Outcome
        public let completedAt: Date
        public let legacyDatabasePath: String
        public let kvotarDatabasePath: String
        public let legacyDatabaseBytes: UInt64?
        public let legacyWALBytes: UInt64?
        public let schemaMigration: String?
    }

    public enum MigrationError: Error, LocalizedError {
        case invalidLegacyDatabase
        case invalidExistingKvotarDatabase
        case invalidCopiedDatabase

        public var errorDescription: String? {
            switch self {
            case .invalidLegacyDatabase:
                return "The AgentPilot database is not a valid migratable SQLite store."
            case .invalidExistingKvotarDatabase:
                return "Kvotar storage already exists but is not a valid database; it was left unchanged."
            case .invalidCopiedDatabase:
                return "The copied database failed validation and was not installed."
            }
        }
    }

    private let legacyDatabaseURL: URL
    private let kvotarDatabaseURL: URL
    private let receiptURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let afterValidatedCopy: (@Sendable () throws -> Void)?

    public init(
        legacyDatabaseURL: URL = ProductIdentity.legacyDatabaseURL(),
        kvotarDatabaseURL: URL = URL(fileURLWithPath: SQLiteStore.expectedDatabasePath()),
        receiptURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        afterValidatedCopy: (@Sendable () throws -> Void)? = nil
    ) {
        self.legacyDatabaseURL = legacyDatabaseURL
        self.kvotarDatabaseURL = kvotarDatabaseURL
        self.receiptURL = receiptURL
            ?? kvotarDatabaseURL.deletingLastPathComponent()
                .appendingPathComponent(ProductIdentity.migrationReceiptFilename)
        self.fileManager = fileManager
        self.now = now
        self.afterValidatedCopy = afterValidatedCopy
    }

    @discardableResult
    public func migrateIfNeeded() throws -> Receipt {
        let destinationDirectory = kvotarDatabaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try cleanupStaleTemporaryCopies(in: destinationDirectory)

        if fileManager.fileExists(atPath: kvotarDatabaseURL.path) {
            let size = fileSize(at: kvotarDatabaseURL) ?? 0
            if size == 0 {
                try fileManager.removeItem(at: kvotarDatabaseURL)
            } else {
                guard Self.databaseIsValid(at: kvotarDatabaseURL, readOnly: false) else {
                    throw MigrationError.invalidExistingKvotarDatabase
                }
                let receipt = makeReceipt(
                    outcome: .preservedExistingKvotarStore,
                    schemaMigration: try Self.schemaMigration(at: kvotarDatabaseURL))
                try writeReceipt(receipt)
                return receipt
            }
        }

        // Kvotar storage is absent. If an earlier run already established it, the database was
        // deleted, moved, or restored from a backup older than itself — and re-copying AgentPilot
        // would silently reinstate a stale snapshot over that removal. Start clean instead and leave
        // the legacy store untouched. A receipt that will not decode is treated the same way:
        // unreadable is not evidence that importing is safe. An earlier *clean install* does not
        // block, so someone who launches Kvotar before copying their AgentPilot data still gets
        // migrated on the next launch; deleting the receipt forces a deliberate re-import.
        if fileManager.fileExists(atPath: receiptURL.path), readReceipt()?.outcome != .cleanInstall {
            let receipt = makeReceipt(outcome: .cleanStartAfterPriorRun, schemaMigration: nil)
            try writeReceipt(receipt)
            return receipt
        }

        guard fileManager.fileExists(atPath: legacyDatabaseURL.path) else {
            let receipt = makeReceipt(outcome: .cleanInstall, schemaMigration: nil)
            try writeReceipt(receipt)
            return receipt
        }
        let temporaryURL = destinationDirectory
            .appendingPathComponent(".kvotar-migration-\(UUID().uuidString).db")
        do {
            try Self.copyDatabaseWithoutOpeningSource(
                from: legacyDatabaseURL, to: temporaryURL, fileManager: fileManager)
        } catch {
            throw MigrationError.invalidLegacyDatabase
        }
        guard Self.databaseIsValid(at: temporaryURL, readOnly: false) else {
            throw MigrationError.invalidCopiedDatabase
        }

        // Test seam for a process interruption after a complete, valid copy but before publication.
        // The unique temp file is intentionally left behind; the next run removes it before retrying.
        try afterValidatedCopy?()
        try fileManager.moveItem(at: temporaryURL, to: kvotarDatabaseURL)
        try cleanupStaleTemporaryCopies(in: destinationDirectory)

        let receipt = makeReceipt(
            outcome: .migrated,
            schemaMigration: try Self.schemaMigration(at: kvotarDatabaseURL))
        try writeReceipt(receipt)
        return receipt
    }

    private func cleanupStaleTemporaryCopies(in directory: URL) throws {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for child in children where child.lastPathComponent.hasPrefix(".kvotar-migration-") {
            try fileManager.removeItem(at: child)
        }
    }

    private func makeReceipt(outcome: Outcome, schemaMigration: String?) -> Receipt {
        Receipt(
            outcome: outcome,
            completedAt: now(),
            legacyDatabasePath: legacyDatabaseURL.path,
            kvotarDatabasePath: kvotarDatabaseURL.path,
            legacyDatabaseBytes: fileSize(at: legacyDatabaseURL),
            legacyWALBytes: fileSize(at: URL(fileURLWithPath: legacyDatabaseURL.path + "-wal")),
            schemaMigration: schemaMigration)
    }

    private func fileSize(at url: URL) -> UInt64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    private func readReceipt() -> Receipt? {
        guard let data = fileManager.contents(atPath: receiptURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Receipt.self, from: data)
    }

    private func writeReceipt(_ receipt: Receipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: receiptURL, options: [.atomic])
    }

    private static func copyDatabaseWithoutOpeningSource(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        // A stopped WAL-mode database may have committed rows only in the WAL. Copy it under the
        // already-held compatibility process lock; SQLite rebuilds shared memory on the copy.
        for suffix in ["-wal", "-journal"] {
            let sourceSidecar = URL(fileURLWithPath: sourceURL.path + suffix)
            guard fileManager.fileExists(atPath: sourceSidecar.path) else { continue }
            let destinationSidecar = URL(fileURLWithPath: destinationURL.path + suffix)
            try fileManager.copyItem(at: sourceSidecar, to: destinationSidecar)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destinationSidecar.path)
        }

        let destination = try DatabaseQueue(path: destinationURL.path)
        // Fold recovered sidecars into the single temp file before its basename changes.
        try destination.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
        }
        try destination.close()
    }

    private static func databaseIsValid(at url: URL, readOnly: Bool) -> Bool {
        do {
            var configuration = Configuration()
            configuration.readonly = readOnly
            configuration.busyMode = .timeout(5)
            let database = try DatabaseQueue(path: url.path, configuration: configuration)
            let valid = try database.read { db in
                let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check")
                let hasMigrations = try db.tableExists("grdb_migrations")
                let hasSettings = try db.tableExists("settings")
                return quickCheck == "ok" && hasMigrations && hasSettings
            }
            try database.close()
            return valid
        } catch {
            return false
        }
    }

    private static func schemaMigration(at url: URL) throws -> String? {
        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        return try database.read { db in
            try String.fetchOne(
                db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1")
        }
    }
}
