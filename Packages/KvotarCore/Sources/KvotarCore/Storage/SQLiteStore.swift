import Foundation
import GRDB

/// Owns the single GRDB `DatabasePool` for Kvotar. All reads and writes go through
/// this actor — no other component imports GRDB (ARCHITECTURE.md §SQLite access).
///
/// `DatabasePool` (not `DatabaseQueue`) is required because the CLI binary shares the
/// same database file as the app; WAL mode allows concurrent multi-process access.
public actor SQLiteStore {
    private let pool: DatabasePool

    /// Opens the database at `path`, enabling WAL + foreign-key enforcement per connection.
    /// When `runMigrations` is true (the app's path) all registered migrations are applied before
    /// any read or write occurs. A read-only connection (`readOnly == true`) never migrates
    /// regardless — the app owns the schema, and a CLI-triggered migrate would race the running
    /// app. The CLI passes `runMigrations: false` even for its one read-write path (`debug`),
    /// which only mutates an already-migrated `settings` row. Prefer the `openReadOnly(path:)` /
    /// `openReadWrite(path:)` factories over passing the flags directly.
    public init(path: String, readOnly: Bool = false, runMigrations: Bool = true) throws {
        var config = Configuration()
        config.readonly = readOnly
        // The CLI binary shares this DB file. GRDB's default `busyMode` is `.immediateError`, so a
        // `SQLITE_BUSY` from the concurrently-writing CLI would surface at once — and every write
        // caller uses `try?`, so contention silently drops poll snapshots / notification rows /
        // token events. `.timeout(5)` waits out a CLI write burst instead (ARCHITECTURE.md §SQLite).
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            // `DatabasePool` already opens the database in WAL mode itself; re-running the pragma on
            // every pooled connection (including readers) is redundant. Only FK enforcement, which
            // is per-connection, needs setting here.
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        do {
            pool = try DatabasePool(path: path, configuration: config)
        } catch {
            Logger.error("Failed to open database pool", component: .sqliteStore,
                         metadata: ["error": "\(error)", "readOnly": "\(readOnly)"])
            throw error
        }

        guard !readOnly else {
            Logger.info("Opened database read-only (migrations skipped)", component: .sqliteStore)
            return
        }

        guard runMigrations else {
            Logger.info("Opened database read-write (migrations skipped)", component: .sqliteStore)
            return
        }

        do {
            var migrator = DatabaseMigrator()
            SQLiteStore.registerMigrations(&migrator)
            try migrator.migrate(pool)
            Logger.info("Migrations applied", component: .sqliteStore)
        } catch {
            Logger.error("Migration failed", component: .sqliteStore,
                         metadata: ["error": "\(error)"])
            throw error
        }
    }

    /// Opens the app's database read-only, without running migrations — the entry point for the
    /// `kvotar` CLI, which must never mutate the schema the running app owns. Throws if the
    /// file is absent or a read-only WAL open fails (Baseline §5.3; STEP_54).
    public static func openReadOnly(path: String) throws -> SQLiteStore {
        try SQLiteStore(path: path, readOnly: true)
    }

    /// Opens the app's database read-**write** without running migrations — the entry point for the
    /// one CLI command that mutates state (`debug`, which flips a `settings` row). The CLI never
    /// migrates: the running app owns the schema, and a CLI-triggered migrate would race it. Callers
    /// must check the file exists first and degrade (the CLI must not create the DB). Throws if the
    /// file is absent or the WAL open fails (STEP_17).
    public static func openReadWrite(path: String) throws -> SQLiteStore {
        try SQLiteStore(path: path, readOnly: false, runMigrations: false)
    }

    /// Default Kvotar-owned location. Creates the containing directory if needed.
    public static func defaultPath(fileManager: FileManager = .default) throws -> String {
        try ProductIdentity.applicationSupportDirectory(fileManager: fileManager, create: true)
            .appendingPathComponent(ProductIdentity.databaseFilename).path
    }

    /// The §5.3 database path **without** creating the containing directory — the read-only CLI
    /// must not leave an empty Application Support directory behind just to discover the DB is
    /// absent. Callers check existence and degrade; only the app (via `defaultPath()`) creates.
    public static func expectedDatabasePath() -> String {
        (try? ProductIdentity.applicationSupportDirectory(create: false)
            .appendingPathComponent(ProductIdentity.databaseFilename).path)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(ProductIdentity.applicationSupportDirectoryName,
                                        isDirectory: true)
                .appendingPathComponent(ProductIdentity.databaseFilename).path
    }

    /// Internal accessor for the pool, used by same-module extensions and tests.
    /// Not part of the public surface — external components call typed methods only.
    func withPool<T>(_ body: (DatabasePool) throws -> T) rethrows -> T {
        try body(pool)
    }
}
