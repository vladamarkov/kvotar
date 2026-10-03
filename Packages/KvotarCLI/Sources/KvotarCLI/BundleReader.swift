import Foundation
import CryptoKit
import KvotarCore

/// Opens one diagnostics bundle produced by **Save Diagnostics…** (`DiagnosticsBundle`, STEP_73) and
/// hands back its database path plus the provenance a corpus row needs (STEP_74).
///
/// Accepts either the `.zip` a tester sends or an already-expanded directory — an operator who has
/// unzipped a bundle to look inside it should not have to re-zip it to import it.
///
/// **Tolerates what the builder can produce.** Since STEP_136 every bundle carries a checkpointed
/// database copy, but the copy is non-fatal on the builder's side, so a bundle can still arrive
/// without one — it then contributes its provenance and notes but no rows. A missing manifest is
/// likewise a note rather than a rejection, because the builder writes it with `try?`. What makes a
/// directory *not* a bundle is carrying none of the artifacts at all.
///
/// **Reads both database names** (STEP_124): bundles written before the rename carry `agentpilot.db`,
/// and the only Enterprise evidence on hand is one of those. A bundle never carries both.
struct BundleReader {

    /// What one bundle contributes to the `bundles` table, plus where its database sits.
    struct Bundle {
        let bundleID: String
        let archiveName: String
        let sourcePath: String
        /// `nil` when the builder's database copy failed on the tester's machine.
        let databasePath: String?
        let manifest: Manifest?
        /// Verbatim `manifest.json`, stored whole so a field this importer never decodes is still
        /// in the corpus when someone asks for it later.
        let manifestJSON: String?
        let environment: String?
        let whatLookedWrong: String?
        /// Facts the operator must be told at import time rather than discover in a query.
        let notes: [String]

        var captureEnabled: Bool? { manifest?.captureEnabled }
    }

    /// The subset of `DiagnosticsBundle.Manifest` the corpus indexes. Field names match that type's
    /// `Codable` synthesis exactly — the manifest is written with default (camelCase) keys.
    struct Manifest: Decodable {
        struct Database: Decodable {
            let schemaMigration: String?
        }
        let generatedAt: Int?
        let generatedAtLocal: String?
        let appVersion: String?
        let channel: String?
        let captureEnabled: Bool?
        let timeZone: String?
        let notes: [String]?
        let database: Database?
    }

    enum ReaderError: Error, LocalizedError {
        case notFound(String)
        case expandFailed(String, status: Int32)
        case notABundle(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let path):
                return "No such bundle: \(path)"
            case .expandFailed(let path, let status):
                return "Could not expand \(path) (ditto exit \(status))."
            case .notABundle(let path):
                return "\(path) carries no diagnostics artifacts — not a diagnostics bundle."
            }
        }
    }

    /// Directories created while expanding zips; the caller removes them when the import is done.
    private(set) var temporaryDirectories: [URL] = []

    mutating func read(path: String) throws -> Bundle {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ReaderError.notFound(source.path)
        }

        let root: URL
        if isDirectory.boolValue {
            root = try bundleRoot(in: source, original: source)
        } else {
            let staging = fm.temporaryDirectory
                .appendingPathComponent("KvotarImport-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            temporaryDirectories.append(staging)
            // `DiagnosticsBundle` archives with `ditto -c -k --keepParent`; unarchive with its twin.
            let status = CLIProcess.run("/usr/bin/ditto",
                                        arguments: ["-x", "-k", source.path, staging.path],
                                        timeout: 120)
            guard status == 0 else {
                throw ReaderError.expandFailed(source.path, status: status ?? -1)
            }
            root = try bundleRoot(in: staging, original: source)
        }

        let databasePath = Self.databaseNames
            .map { root.appendingPathComponent($0).path }
            .first { fm.fileExists(atPath: $0) }
        let manifestData = fm.contents(atPath: root.appendingPathComponent("manifest.json").path)
        let manifest = manifestData.flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }

        var notes: [String] = []
        if manifestData == nil {
            notes.append("No manifest.json in this bundle — app version, channel and the capture "
                         + "flag are unknown for every row it contributed.")
        } else if manifest == nil {
            notes.append("manifest.json could not be decoded — stored verbatim, provenance unknown.")
        }
        if databasePath == nil {
            notes.append("No database in this bundle — the copy failed on the tester's machine "
                         + "when it was written, so it contributes provenance but no rows.")
        }
        let captureOff = manifest?.captureEnabled == false
        if captureOff {
            notes.append("Diagnostics capture was OFF on this machine — an empty payload set means "
                         + "'not captured', not 'nothing happened'.")
        }
        // The builder writes its own version of that sentence into the manifest, so carrying the
        // manifest's notes through verbatim prints the same warning twice. Ours is kept because it
        // is also produced for a bundle whose manifest carries no notes at all.
        notes.append(contentsOf: (manifest?.notes ?? []).filter { note in
            !(captureOff && note.lowercased().contains("capture was off"))
        })

        return Bundle(
            bundleID: try identity(manifestData: manifestData, databasePath: databasePath,
                                   root: root),
            archiveName: source.lastPathComponent,
            sourcePath: source.path,
            databasePath: databasePath,
            manifest: manifest,
            manifestJSON: manifestData.map { String(decoding: $0, as: UTF8.self) },
            environment: text(at: root.appendingPathComponent("environment.txt")),
            whatLookedWrong: text(at: root.appendingPathComponent(
                DiagnosticsBundleFileNames.whatLookedWrong)),
            notes: notes)
    }

    /// Cleans up anything expanded for this import.
    func cleanUp() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Pieces

    /// Current name first, then the pre-rename one. Order only matters if both were ever present,
    /// which no builder has done.
    static let databaseNames = [ProductIdentity.databaseFilename,
                                ProductIdentity.Legacy.databaseFilename]

    /// Any one of these marks a directory as a bundle root. The database is not a guaranteed
    /// artifact, so identification cannot hang on it.
    private static let markers = databaseNames
        + ["manifest.json", "diagnostics-summary.json",
           "environment.txt", DiagnosticsBundleFileNames.whatLookedWrong]

    private static func looksLikeBundle(_ directory: URL, _ fm: FileManager) -> Bool {
        markers.contains { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// `--keepParent` means an expanded archive holds one folder which holds the artifacts; a
    /// directory the operator points at may be either that folder or its parent.
    private func bundleRoot(in directory: URL, original: URL) throws -> URL {
        let fm = FileManager.default
        if Self.looksLikeBundle(directory, fm) { return directory }
        let children = (try? fm.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        for child in children where Self.looksLikeBundle(child, fm) {
            return child
        }
        throw ReaderError.notABundle(original.path)
    }

    /// A bundle's identity is its manifest — same manifest, same bundle, whatever the operator
    /// renamed the zip to. Without one, the database's own bytes stand in (streamed, because a
    /// bundle database is tens of megabytes and there is no reason to hold it in memory), and
    /// without a database either, the sanitized artifacts do. The fallbacks only have to be stable
    /// and distinct — two different bundles must not collide, and re-importing one must not
    /// duplicate it.
    private func identity(manifestData: Data?, databasePath: String?, root: URL) throws -> String {
        var hasher = SHA256()
        if let manifestData {
            hasher.update(data: manifestData)
        } else if let databasePath, let handle = FileHandle(forReadingAtPath: databasePath) {
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } else {
            let fm = FileManager.default
            var found = false
            for name in ["diagnostics-summary.json", "environment.txt",
                         DiagnosticsBundleFileNames.whatLookedWrong] {
                guard let data = fm.contents(atPath: root.appendingPathComponent(name).path)
                else { continue }
                hasher.update(data: Data(name.utf8))
                hasher.update(data: data)
                found = true
            }
            guard found else { throw ReaderError.notABundle(root.path) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func text(at url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let string = String(decoding: data, as: UTF8.self)
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
    }
}

/// Names `DiagnosticsBundle` writes that this side has to know about. The builder keeps its own
/// copies internal to Core; duplicating the one filename is cheaper than widening Core's surface.
enum DiagnosticsBundleFileNames {
    static let whatLookedWrong = "WHAT_LOOKED_WRONG.txt"
}

/// Shell-out with a watchdog, for the one subprocess the CLI runs. Core has the same shape
/// (`ProcessRun`, beside `DiagnosticsBundle`) but keeps it internal to that module.
enum CLIProcess {
    static func run(_ path: String, arguments: [String], timeout: TimeInterval) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()   // discard
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        return process.terminationStatus
    }
}
