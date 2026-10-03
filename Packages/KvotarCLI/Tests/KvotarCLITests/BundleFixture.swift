import Foundation
import GRDB

/// Builds diagnostics bundles on disk for the importer tests (STEP_74).
///
/// A bundle is a directory of small text artifacts, plus `kvotar.db` when — and only when — it was
/// written inside an authorized capture window. Both shapes are fixtures here: `sql:` produces the
/// extended shape, `sql: nil` the ordinary sanitized one. Hand-writing is the point: these tests
/// need bundles that no machine here can produce (capture off, a missing manifest, a table named
/// like the corpus's own bookkeeping).
enum BundleFixture {

    /// A temporary directory removed by `cleanUp()`. Tests keep one for the whole case.
    static func makeWorkingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KvotarImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes one bundle directory and returns its path.
    ///
    /// - Parameters:
    ///   - sql: statements run against the bundle's fresh database, in order — the tables and rows
    ///     this bundle is supposed to contain. `nil` writes **no database**, which is the ordinary
    ///     sanitized shape the app produces without an authorized capture window.
    ///   - summary: written as `diagnostics-summary.json`. A sanitized bundle needs at least one
    ///     artifact to be recognisable, and this is the one every real bundle carries.
    ///   - manifestJSON: `nil` writes no `manifest.json` at all, which a real bundle can genuinely
    ///     arrive without (the builder writes it with `try?`).
    @discardableResult
    static func make(in parent: URL,
                     named name: String,
                     manifestJSON: String? = manifest(),
                     whatLookedWrong: String? = nil,
                     environment: String? = nil,
                     summary: String? = nil,
                     databaseName: String = "kvotar.db",
                     sql: [String]?) throws -> URL {
        let root = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        if let sql {
            let queue = try DatabaseQueue(path: root.appendingPathComponent(databaseName).path)
            try queue.write { db in
                for statement in sql { try db.execute(sql: statement) }
            }
            // The importer opens the database read-only, which fails against a WAL sidecar the copy
            // does not have — real bundles are written with `VACUUM INTO`, so close this one fully.
            try queue.close()
        }
        if let summary {
            try Data(summary.utf8)
                .write(to: root.appendingPathComponent("diagnostics-summary.json"))
        }

        if let manifestJSON {
            try Data(manifestJSON.utf8)
                .write(to: root.appendingPathComponent("manifest.json"))
        }
        if let whatLookedWrong {
            try Data(whatLookedWrong.utf8)
                .write(to: root.appendingPathComponent("WHAT_LOOKED_WRONG.txt"))
        }
        if let environment {
            try Data(environment.utf8)
                .write(to: root.appendingPathComponent("environment.txt"))
        }
        return root
    }

    /// A manifest in the shape `DiagnosticsBundle` writes (default camelCase `Codable` keys).
    static func manifest(appVersion: String = "0.1.9 (12)",
                         channel: String = "beta",
                         captureEnabled: Bool = true,
                         schemaMigration: String? = "v17_cache_write_tiers",
                         generatedAt: Int = 1786568900,
                         notes: [String] = []) -> String {
        let schema = schemaMigration.map { "\"schemaMigration\" : \"\($0)\"" } ?? ""
        let noteList = notes.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
            {
              "appVersion" : "\(appVersion)",
              "captureEnabled" : \(captureEnabled),
              "channel" : "\(channel)",
              "database" : { \(schema) },
              "generatedAt" : \(generatedAt),
              "generatedAtLocal" : "2026-08-12 22:28:20 +02:00",
              "notes" : [\(noteList)],
              "timeZone" : "Europe/Belgrade"
            }
            """
    }

    /// Archives a bundle directory the way `DiagnosticsBundle` does, so the zip path is exercised
    /// against a real `ditto` archive rather than a hand-rolled one.
    static func archive(_ directory: URL) throws -> URL {
        let zip = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + ".zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", directory.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return zip
    }

    // MARK: - Reading a corpus back

    static func rows(_ path: String, sql: String) throws -> [Row] {
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: path, configuration: config).read { db in
            try Row.fetchAll(db, sql: sql)
        }
    }

    static func count(_ path: String, table: String) throws -> Int {
        try rows(path, sql: "SELECT COUNT(*) AS n FROM \"\(table)\"").first?["n"] ?? 0
    }

    static func columns(_ path: String, table: String) throws -> Set<String> {
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: path, configuration: config).read { db in
            Set(try db.columns(in: table).map(\.name))
        }
    }
}
