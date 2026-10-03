import ArgumentParser
import Foundation
import KvotarCore

/// `kvotar doctor` — proves the CLI can find and read the app's database read-only, and
/// degrades cleanly when it can't. It is the STEP_54 output-seam guinea pig (exercises human +
/// `--json`) and the manual-verification handle every later CLI step reuses.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that the CLI can read Kvotar's database.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        CLIRuntime.bootstrap()
        let path = global.databasePath

        // The DB is absent until the app has run at least once. Don't create it — the CLI is
        // read-only; report and exit non-zero.
        guard FileManager.default.fileExists(atPath: path) else {
            Logger.info("doctor: database absent", component: .cli, metadata: ["path": path])
            CLIOutput.print(DoctorReport.notRunYet(path: path), json: global.json)
            throw ExitCode.failure
        }

        do {
            let store = try SQLiteStore.openReadOnly(path: path)
            // Best-effort: a successful open already proves read access; the migration id is detail.
            let migration: String? = (try? await store.latestSchemaMigration()) ?? nil
            Logger.info("doctor: database readable", component: .cli,
                        metadata: ["path": path, "schema": migration ?? "unknown"])
            CLIOutput.print(DoctorReport.readable(path: path, migration: migration), json: global.json)
        } catch {
            // File exists but a read-only WAL open failed — e.g. the app has never opened it this
            // boot, so the -wal/-shm sidecars a read-only connection needs aren't present.
            Logger.warning("doctor: database open failed", component: .cli,
                           metadata: ["path": path, "error": "\(error)"])
            CLIOutput.print(DoctorReport.unreadable(path: path), json: global.json)
            throw ExitCode.failure
        }
    }
}

/// `doctor`'s output payload. `reason` / `schema_migration` are `encodeIfPresent` — they appear
/// only when meaningful; consumers key on `database_readable`.
struct DoctorReport: CLIOutputPayload {
    let databaseReadable: Bool
    let databasePath: String
    let schemaMigration: String?
    let reason: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case databaseReadable = "database_readable"
        case databasePath = "database_path"
        case schemaMigration = "schema_migration"
        case reason
        case message
    }

    var humanText: String { message }

    static func readable(path: String, migration: String?) -> DoctorReport {
        let schema = migration.map { " (schema: \($0))" } ?? ""
        return DoctorReport(
            databaseReadable: true, databasePath: path, schemaMigration: migration,
            reason: nil, message: "Kvotar database readable at \(path)\(schema)")
    }

    static func notRunYet(path: String) -> DoctorReport {
        DoctorReport(
            databaseReadable: false, databasePath: path, schemaMigration: nil,
            reason: "not_run_yet",
            message: "Kvotar hasn't run yet — no database at \(path)")
    }

    static func unreadable(path: String) -> DoctorReport {
        DoctorReport(
            databaseReadable: false, databasePath: path, schemaMigration: nil,
            reason: "open_failed",
            message: "Can't read Kvotar's database — is Kvotar running? (\(path))")
    }
}
