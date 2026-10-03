import ArgumentParser
import Foundation
import KvotarCore

/// `kvotar import` — N diagnostics bundles into one queryable corpus (STEP_74, REV-52 §7).
///
/// **Operator tooling, not a product surface.** Testers never run this; it is the receiving end of
/// the support channel **Save Diagnostics…** opened in STEP_73. The findings it exists for are the
/// ones no single bundle contains — *"Codex Plus accounts show utilization stuck at 0% for the first
/// 40 minutes on all three testers"* — so every row keeps the tester it came from.
///
/// It reads bundle copies and writes a **separate** analysis database. The app's own database is
/// never opened, and writing to it is refused outright.
struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Ingest diagnostics bundles into one analysis database.",
        discussion: """
            Bundles are the .zip archives produced by Kvotar's "Save Diagnostics…" menu item \
            (an already-expanded directory works too). Re-importing a bundle, or importing a later \
            bundle that overlaps an earlier one from the same machine, adds only genuinely new \
            rows — a row is identified by its contents, not by its position in a database.

            --tester is required: a bundle records app version, channel, timezone and generation \
            time, but nothing that identifies the machine or the person. Use the same label every \
            time for the same tester, or their history arrives split in two.
            """)

    @OptionGroup var global: GlobalOptions

    @Option(name: .long, help: ArgumentHelp(
        "Label for the machine these bundles came from.", valueName: "id"))
    var tester: String?

    @Option(name: .long, help: ArgumentHelp(
        "Analysis database to write (default: ~/Library/Application Support/Kvotar/analysis/analysis.db).",
        valueName: "path"))
    var analysisDb: String?

    @Flag(name: .long, help: "Print the starter queries and exit.")
    var printQueries = false

    @Argument(help: ArgumentHelp("Bundle .zip archives or expanded bundle directories.",
                                 valueName: "bundle"))
    var bundles: [String] = []

    /// Where this invocation will write the corpus.
    var resolvedAnalysisPath: String {
        let path = analysisDb.map { ($0 as NSString).expandingTildeInPath }
            ?? Self.defaultAnalysisPath()
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The corpus lives beside the app's database but is emphatically not it — its own directory,
    /// so nothing in `Application Support/Kvotar` is ambiguous about what owns which file.
    static func defaultAnalysisPath(fileManager: FileManager = .default) -> String {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kvotar", isDirectory: true)
            .appendingPathComponent("analysis", isDirectory: true)
            .appendingPathComponent("analysis.db").path
    }

    func validate() throws {
        if printQueries { return }
        // `--database` means "the app's database" in every other command and means nothing here;
        // silently ignoring it would be the kind of surprise that costs an afternoon.
        guard global.database == nil else {
            throw ValidationError("`import` never touches the app's database. "
                                  + "Use --analysis-db to choose where the corpus is written.")
        }
        guard let tester, !tester.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("Specify --tester <id> — bundles carry no machine identity, so "
                                  + "the corpus cannot work out whose rows these are.")
        }
        guard !bundles.isEmpty else {
            throw ValidationError("Specify at least one bundle (.zip or expanded directory).")
        }
        guard resolvedAnalysisPath != URL(fileURLWithPath: SQLiteStore.expectedDatabasePath())
            .standardizedFileURL.path else {
            throw ValidationError("That is Kvotar's own database. The corpus must be a "
                                  + "separate file — this command never writes the app's.")
        }
    }

    func run() async throws {
        CLIRuntime.bootstrap()

        if printQueries {
            print(StarterQueries.text)
            return
        }

        let testerID = (tester ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let resolved = resolvedAnalysisPath

        var reader = BundleReader()
        defer { reader.cleanUp() }

        let store = try AnalysisStore(path: resolved)
        var results: [ImportReport.BundleResult] = []
        var failures: [ImportReport.Failure] = []

        for path in bundles {
            do {
                let bundle = try reader.read(path: path)
                if let databasePath = bundle.databasePath,
                   URL(fileURLWithPath: databasePath).standardizedFileURL.path == resolved {
                    throw ValidationError("A bundle's own database cannot be the corpus.")
                }
                let outcome = try store.importBundle(bundle, tester: testerID)
                Logger.info("import: bundle ingested", component: .cli,
                            metadata: ["tester": testerID, "bundle": bundle.bundleID,
                                       "rows": "\(outcome.sourceRows)",
                                       "inserted": "\(outcome.inserted)"])
                results.append(ImportReport.BundleResult(bundle: bundle, outcome: outcome))
            } catch {
                Logger.warning("import: bundle failed", component: .cli,
                               metadata: ["path": path, "error": "\(error)"])
                failures.append(ImportReport.Failure(
                    source: path,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }

        let testers = (try? store.testerSummary()) ?? []
        let corpusRows = ((try? store.tableCounts()) ?? [])
            .filter { $0.table != "bundles" && $0.table != "bundle_tables" }
            .reduce(0) { $0 + $1.rows }

        CLIOutput.print(
            ImportReport(analysisDatabase: resolved, imported: results, failures: failures,
                         corpusTesters: testers.count, corpusBundles: testers.reduce(0) { $0 + $1.bundles },
                         corpusRows: corpusRows),
            json: global.json)

        if !failures.isEmpty { throw ExitCode.failure }
    }
}

/// `import`'s output payload. Field names follow the CLI's snake_case contract.
struct ImportReport: CLIOutputPayload {

    struct TableResult: Encodable {
        let table: String
        let sourceRows: Int
        let insertedRows: Int
        let duplicateRows: Int

        enum CodingKeys: String, CodingKey {
            case table
            case sourceRows = "source_rows"
            case insertedRows = "inserted_rows"
            case duplicateRows = "duplicate_rows"
        }
    }

    struct BundleResult: Encodable {
        let bundleID: String
        let testerID: String
        let archiveName: String
        let appVersion: String?
        let channel: String?
        let captureEnabled: Bool?
        let generatedAt: String?
        let schemaMigration: String?
        let importCount: Int
        let sourceRows: Int
        let insertedRows: Int
        let duplicateRows: Int
        let tables: [TableResult]
        let notes: [String]
        let whatLookedWrong: String?

        enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id"
            case testerID = "tester_id"
            case archiveName = "archive_name"
            case appVersion = "app_version"
            case channel
            case captureEnabled = "capture_enabled"
            case generatedAt = "generated_at"
            case schemaMigration = "schema_migration"
            case importCount = "import_count"
            case sourceRows = "source_rows"
            case insertedRows = "inserted_rows"
            case duplicateRows = "duplicate_rows"
            case tables
            case notes
            case whatLookedWrong = "what_looked_wrong"
        }

        init(bundle: BundleReader.Bundle, outcome: AnalysisStore.BundleOutcome) {
            bundleID = outcome.bundleID
            testerID = outcome.tester
            archiveName = bundle.archiveName
            appVersion = bundle.manifest?.appVersion
            channel = bundle.manifest?.channel
            captureEnabled = bundle.captureEnabled
            generatedAt = bundle.manifest?.generatedAtLocal
            schemaMigration = outcome.schemaMigration
            importCount = outcome.importCount
            sourceRows = outcome.sourceRows
            insertedRows = outcome.inserted
            duplicateRows = outcome.duplicates
            tables = outcome.tables.map {
                TableResult(table: $0.table, sourceRows: $0.sourceRows,
                            insertedRows: $0.inserted, duplicateRows: $0.duplicates)
            }
            notes = bundle.notes
            whatLookedWrong = bundle.whatLookedWrong
        }
    }

    struct Failure: Encodable {
        let source: String
        let reason: String
    }

    let analysisDatabase: String
    let imported: [BundleResult]
    let failures: [Failure]
    let corpusTesters: Int
    let corpusBundles: Int
    let corpusRows: Int

    enum CodingKeys: String, CodingKey {
        case analysisDatabase = "analysis_database"
        case imported
        case failures
        case corpusTesters = "corpus_testers"
        case corpusBundles = "corpus_bundles"
        case corpusRows = "corpus_rows"
    }

    var humanText: String {
        var lines = ["Corpus: \(analysisDatabase)", ""]
        for result in imported {
            lines.append("\(result.testerID) · \(result.archiveName)")
            var facts = [result.appVersion ?? "version unknown"]
            if let channel = result.channel { facts.append(channel) }
            switch result.captureEnabled {
            case true: facts.append("capture on")
            case false: facts.append("capture off")
            case nil: facts.append("capture unknown")
            }
            if let generated = result.generatedAt { facts.append("saved \(generated)") }
            if let schema = result.schemaMigration { facts.append("schema \(schema)") }
            lines.append("  " + facts.joined(separator: " · "))
            lines.append("  \(count(result.sourceRows)) rows across "
                         + "\(result.tables.count) tables — \(count(result.insertedRows)) new, "
                         + "\(count(result.duplicateRows)) already in the corpus")
            if result.importCount > 1 {
                lines.append("  (import #\(result.importCount) of this bundle)")
            }
            for note in result.notes { lines.append("  ⚠ \(note)") }
            if result.whatLookedWrong != nil {
                lines.append("  ✎ carries a WHAT_LOOKED_WRONG note — "
                             + "SELECT what_looked_wrong FROM bundles WHERE bundle_id = "
                             + "'\(result.bundleID)';")
            }
            lines.append("")
        }
        for failure in failures {
            lines.append("✗ \(failure.source)")
            lines.append("  \(failure.reason)")
            lines.append("")
        }
        lines.append("Corpus now holds \(count(corpusRows)) rows from \(corpusBundles) "
                     + "\(corpusBundles == 1 ? "bundle" : "bundles") across \(corpusTesters) "
                     + "\(corpusTesters == 1 ? "tester" : "testers").")
        lines.append("Starter queries: kvotar import --print-queries")
        return lines.joined(separator: "\n")
    }

    /// Row counts run to five and six figures; unseparated they are unreadable at a glance.
    private func count(_ value: Int) -> String {
        ImportReport.grouping.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.groupingSeparator = ","
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
