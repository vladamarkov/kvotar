import Foundation
import CryptoKit
import GRDB
import KvotarCore

/// The multi-tester analysis corpus: N diagnostics bundles ingested into one database that keeps
/// every row's provenance (STEP_74, REV-52 §7).
///
/// **This is the one place in the project outside `SQLiteStore` that talks to GRDB directly** (see
/// the carve-out in `PATTERNS.md`). It owns a database the app never opens: a different file, a
/// different schema, no migrator, and nothing in it is ever read back by the running app. Routing it
/// through `SQLiteStore` would mean teaching the app's storage actor a schema that mirrors whatever
/// tables a stranger's bundle happens to contain.
///
/// ## What the corpus looks like
///
/// - `bundles` — one row per imported bundle **per tester**, with the manifest's facts and the
///   tester's own `WHAT_LOOKED_WRONG.txt` alongside them. Keyed on both because the same archive
///   can legitimately be imported under two labels (and was, during this step's verification);
///   keyed on the bundle alone, the second import silently re-labelled the first one's rows.
/// - `bundle_tables` — what the most recent import of each bundle moved, per table. This is what
///   makes idempotency *visible*: a second import of the same bundle reports zero inserted.
/// - one table per table found in a bundle's database, carrying four extra columns:
///   `tester_id`, `bundle_id`, `src_rowid`, `row_hash`.
///
/// ## Identity is contents, not position
///
/// A row's identity is `(tester_id, row_hash)`, where the hash covers the row's **non-null columns
/// in name order**. Re-importing the same bundle inserts nothing, and a later overlapping bundle
/// from the same machine inserts only what is new — neither depends on import order. Nulls are
/// skipped so that a row which merely *gained* a column in a newer schema (added null-backfilled,
/// which is how every column this project has added behaves) stays one row rather than two.
///
/// Source primary keys and constraints are deliberately **not** copied: several are unique per
/// machine (`accounts` is keyed on `tool` alone) and would collide the moment a second tester
/// arrived.
final class AnalysisStore {

    /// Columns this importer adds to every copied table. A source column of the same name would be
    /// silently shadowed, so it is an error instead.
    static let provenanceColumns = ["tester_id", "bundle_id", "src_rowid", "row_hash"]

    /// Corpus bookkeeping — a source table of either name would collide with it.
    static let reservedTables = ["bundles", "bundle_tables"]

    /// Schema bookkeeping travels as a `bundles` column instead of a copied table.
    static let skippedTables = ["grdb_migrations"]

    struct TableOutcome {
        let table: String
        let sourceRows: Int
        let inserted: Int
        var duplicates: Int { sourceRows - inserted }
    }

    struct BundleOutcome {
        let bundleID: String
        let tester: String
        let tables: [TableOutcome]
        let schemaMigration: String?
        let importCount: Int
        var sourceRows: Int { tables.reduce(0) { $0 + $1.sourceRows } }
        var inserted: Int { tables.reduce(0) { $0 + $1.inserted } }
        var duplicates: Int { sourceRows - inserted }
    }

    enum StoreError: Error, LocalizedError {
        case reservedTableName(String)
        case columnCollision(table: String, column: String)

        var errorDescription: String? {
            switch self {
            case .reservedTableName(let table):
                return "The bundle contains a table named '\(table)', which the corpus uses for its "
                     + "own bookkeeping. Import it by hand or rename the corpus table."
            case .columnCollision(let table, let column):
                return "Table '\(table)' already has a column named '\(column)', which the corpus "
                     + "adds as provenance. Refusing to import it rather than shadow the original."
            }
        }
    }

    let path: String
    private let pool: DatabasePool

    /// Opens (creating if needed) the analysis database. Unlike every other CLI command, `import`
    /// legitimately creates a file — but never the app's, which `Import` guards before calling this.
    init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(5)
        pool = try DatabasePool(path: path, configuration: config)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bundles (
                    bundle_id TEXT NOT NULL,
                    tester_id TEXT NOT NULL,
                    archive_name TEXT NOT NULL,
                    source_path TEXT NOT NULL,
                    first_imported_at INTEGER NOT NULL,
                    imported_at INTEGER NOT NULL,
                    import_count INTEGER NOT NULL,
                    generated_at INTEGER,
                    generated_at_local TEXT,
                    app_version TEXT,
                    channel TEXT,
                    capture_enabled INTEGER,
                    time_zone TEXT,
                    schema_migration TEXT,
                    notes TEXT,
                    manifest_json TEXT,
                    environment TEXT,
                    what_looked_wrong TEXT,
                    PRIMARY KEY (bundle_id, tester_id)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bundle_tables (
                    bundle_id TEXT NOT NULL,
                    tester_id TEXT NOT NULL,
                    table_name TEXT NOT NULL,
                    source_rows INTEGER NOT NULL,
                    inserted_rows INTEGER NOT NULL,
                    duplicate_rows INTEGER NOT NULL,
                    PRIMARY KEY (bundle_id, tester_id, table_name)
                )
                """)
        }
    }

    // MARK: - Import

    /// A sanitized bundle carries no database, so it contributes a `bundles` row and nothing else.
    /// It is still recorded: knowing a tester exported on a given day, with capture off, is itself
    /// evidence — and an unrecorded bundle would be re-offered as new at every import.
    func importBundle(_ bundle: BundleReader.Bundle, tester: String,
                      now: Date = Date()) throws -> BundleOutcome {
        guard let databasePath = bundle.databasePath else {
            let schemaMigration = bundle.manifest?.database?.schemaMigration
            let importCount = try recordBundle(bundle, tester: tester,
                                               schemaMigration: schemaMigration, now: now)
            try pool.write { db in
                try db.execute(
                    sql: "DELETE FROM bundle_tables WHERE bundle_id = ? AND tester_id = ?",
                    arguments: [bundle.bundleID, tester])
            }
            return BundleOutcome(bundleID: bundle.bundleID, tester: tester, tables: [],
                                 schemaMigration: schemaMigration, importCount: importCount)
        }

        var config = Configuration()
        config.readonly = true
        // A `DatabaseQueue`, not a pool: the bundle's copy was written with `VACUUM INTO`, so it has
        // no WAL sidecar and a read-only pool open would fail on a database GRDB expects to be WAL.
        let source = try DatabaseQueue(path: databasePath, configuration: config)

        let tableNames = try source.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
        }
        let schemaMigration = bundle.manifest?.database?.schemaMigration
            ?? (try? source.read { db in
                try String.fetchOne(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1")
            }) ?? nil

        for name in tableNames where Self.reservedTables.contains(name) {
            throw StoreError.reservedTableName(name)
        }

        let importCount = try recordBundle(bundle, tester: tester, schemaMigration: schemaMigration,
                                           now: now)

        var outcomes: [TableOutcome] = []
        for table in tableNames where !Self.skippedTables.contains(table) {
            outcomes.append(try copy(table: table, from: source,
                                     bundleID: bundle.bundleID, tester: tester))
        }

        try pool.write { db in
            try db.execute(sql: "DELETE FROM bundle_tables WHERE bundle_id = ? AND tester_id = ?",
                           arguments: [bundle.bundleID, tester])
            for outcome in outcomes {
                try db.execute(sql: """
                    INSERT INTO bundle_tables
                        (bundle_id, tester_id, table_name, source_rows, inserted_rows,
                         duplicate_rows)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [bundle.bundleID, tester, outcome.table, outcome.sourceRows,
                                outcome.inserted, outcome.duplicates])
            }
        }

        return BundleOutcome(bundleID: bundle.bundleID, tester: tester, tables: outcomes,
                             schemaMigration: schemaMigration, importCount: importCount)
    }

    /// Upserts the `bundles` row and returns how many times this bundle has now been imported —
    /// the counter is what distinguishes "nothing new arrived" from "nobody ever imported this".
    private func recordBundle(_ bundle: BundleReader.Bundle, tester: String,
                              schemaMigration: String?, now: Date) throws -> Int {
        let timestamp = Int(now.timeIntervalSince1970)
        return try pool.write { db in
            let previous = try Row.fetchOne(
                db, sql: """
                    SELECT first_imported_at, import_count FROM bundles
                    WHERE bundle_id = ? AND tester_id = ?
                    """,
                arguments: [bundle.bundleID, tester])
            let firstImportedAt: Int = previous?["first_imported_at"] ?? timestamp
            let importCount: Int = (previous?["import_count"] ?? 0) + 1
            try db.execute(sql: """
                INSERT OR REPLACE INTO bundles
                    (bundle_id, tester_id, archive_name, source_path, first_imported_at,
                     imported_at, import_count, generated_at, generated_at_local, app_version,
                     channel, capture_enabled, time_zone, schema_migration, notes, manifest_json,
                     environment, what_looked_wrong)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    bundle.bundleID, tester, bundle.archiveName, bundle.sourcePath,
                    firstImportedAt, timestamp, importCount,
                    bundle.manifest?.generatedAt, bundle.manifest?.generatedAtLocal,
                    bundle.manifest?.appVersion, bundle.manifest?.channel,
                    bundle.manifest?.captureEnabled, bundle.manifest?.timeZone, schemaMigration,
                    bundle.notes.isEmpty ? nil : bundle.notes.joined(separator: "\n"),
                    bundle.manifestJSON, bundle.environment, bundle.whatLookedWrong])
            return importCount
        }
    }

    // MARK: - Copying one table

    private func copy(table: String, from source: DatabaseQueue,
                      bundleID: String, tester: String) throws -> TableOutcome {
        let columns = try source.read { db in try db.columns(in: table) }
        for column in columns where Self.provenanceColumns.contains(column.name) {
            throw StoreError.columnCollision(table: table, column: column.name)
        }
        try ensureTable(table, columns: columns)

        let names = columns.map(\.name)
        // Hash over columns in *name* order, so two bundles whose tables list columns differently
        // (a later schema appends) still agree on what a row is.
        let hashOrder = names.enumerated().sorted { $0.element < $1.element }

        let quotedTable = Self.quote(table)
        let insertSQL = """
            INSERT OR IGNORE INTO \(quotedTable) \
            (\(Self.provenanceColumns.map(Self.quote).joined(separator: ", ")), \
            \(names.map(Self.quote).joined(separator: ", "))) \
            VALUES (\(Array(repeating: "?", count: names.count + 4).joined(separator: ", ")))
            """

        var sourceRows = 0
        var inserted = 0
        try source.read { sourceDB in
            // `rowid` is a reference, not the identity — but it is the cheapest way to point back at
            // the original row in a tester's database when a query turns up something odd.
            var selectSQL = "SELECT rowid AS __src_rowid, * FROM \(quotedTable)"
            var hasRowID = true
            do {
                _ = try sourceDB.makeStatement(sql: selectSQL)
            } catch {
                selectSQL = "SELECT * FROM \(quotedTable)"   // WITHOUT ROWID table
                hasRowID = false
            }
            let offset = hasRowID ? 1 : 0
            let cursor = try Row.fetchCursor(sourceDB, sql: selectSQL)

            try pool.write { db in
                let statement = try db.makeStatement(sql: insertSQL)
                while let row = try cursor.next() {
                    sourceRows += 1
                    let values: [DatabaseValue] = (0..<names.count).map { row[$0 + offset] }
                    let srcRowID: Int64? = hasRowID ? row[0] : nil
                    var arguments: [DatabaseValueConvertible?] = [
                        tester, bundleID, srcRowID,
                        Self.rowHash(names: names, values: values, order: hashOrder)]
                    arguments.append(contentsOf: values.map { $0 as DatabaseValueConvertible? })
                    try statement.execute(arguments: StatementArguments(arguments))
                    inserted += db.changesCount
                }
            }
        }
        return TableOutcome(table: table, sourceRows: sourceRows, inserted: inserted)
    }

    /// Creates the corpus table on first sight, and widens it when a newer bundle brings columns the
    /// corpus has not seen. Bundles from different app versions therefore coexist: an older one
    /// simply leaves the newer columns null.
    private func ensureTable(_ table: String, columns: [ColumnInfo]) throws {
        try pool.write { db in
            guard try db.tableExists(table) else {
                let definitions = columns.map { column in
                    "    \(Self.quote(column.name))"
                        + (column.type.isEmpty ? "" : " \(column.type)")
                }
                try db.execute(sql: """
                    CREATE TABLE \(Self.quote(table)) (
                        "tester_id" TEXT NOT NULL,
                        "bundle_id" TEXT NOT NULL,
                        "src_rowid" INTEGER,
                        "row_hash" TEXT NOT NULL,
                    \(definitions.joined(separator: ",\n")),
                        PRIMARY KEY ("tester_id", "row_hash")
                    )
                    """)
                return
            }
            let existing = Set(try db.columns(in: table).map(\.name))
            for column in columns where !existing.contains(column.name) {
                try db.execute(sql: "ALTER TABLE \(Self.quote(table)) "
                               + "ADD COLUMN \(Self.quote(column.name)) \(column.type)")
                Logger.info("import: corpus table widened", component: .cli,
                            metadata: ["table": table, "column": column.name])
            }
        }
    }

    // MARK: - Row identity

    /// SHA-256 over `name␟<type><value>␞` for every **non-null** column, in column-name order.
    /// Blobs are hashed as bytes rather than stringified — a captured payload body is measured in
    /// megabytes and there is no reason to build a hex copy of it.
    static func rowHash(names: [String], values: [DatabaseValue],
                        order: [(offset: Int, element: String)]) -> String {
        var hasher = SHA256()
        for (index, name) in order {
            let value = values[index]
            let tagged: (tag: String, bytes: Data)
            switch value.storage {
            case .null:
                continue
            case .int64(let int):
                tagged = ("i", Data(String(int).utf8))
            case .double(let double):
                tagged = ("d", Data(String(double).utf8))
            case .string(let string):
                tagged = ("s", Data(string.utf8))
            case .blob(let data):
                tagged = ("b", data)
            }
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data([0x1F]))
            hasher.update(data: Data(tagged.tag.utf8))
            hasher.update(data: tagged.bytes)
            hasher.update(data: Data([0x1E]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reading the corpus back

    /// Row counts per table, for the operator's own before/after comparison.
    func tableCounts() throws -> [(table: String, rows: Int)] {
        try pool.read { db in
            let names = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
            return try names.map { name in
                (name, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(Self.quote(name))") ?? 0)
            }
        }
    }

    /// Every tester currently in the corpus, with how many bundles each has contributed.
    func testerSummary() throws -> [(tester: String, bundles: Int)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT tester_id, COUNT(*) AS n FROM bundles GROUP BY tester_id ORDER BY tester_id
                """).map { ($0["tester_id"], $0["n"]) }
        }
    }

    private static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
