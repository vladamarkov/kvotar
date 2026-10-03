import XCTest
@testable import KvotarCLI

/// The reading half of `kvotar import` (STEP_74): what a bundle is, and the facts an operator
/// must be told at import time rather than discover later in a query.
final class BundleReaderTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        work = try BundleFixture.makeWorkingDirectory()
    }

    override func tearDownWithError() throws {
        BundleFixture.cleanUp(work)
    }

    private func read(_ path: String) throws -> BundleReader.Bundle {
        var reader = BundleReader()
        return try reader.read(path: path)
    }

    private static let minimalSQL = [
        "CREATE TABLE poll_snapshots (id INTEGER, tool TEXT)",
        "INSERT INTO poll_snapshots VALUES (1, 'claude')"
    ]

    // MARK: - Honest gaps

    /// DoD: a capture-off bundle must say so, or its empty payload table reads as "nothing
    /// happened" when it means "never recorded".
    func testCaptureOffBundleIsFlaggedAtImportTime() throws {
        let source = try BundleFixture.make(
            in: work, named: "dave-bundle",
            manifestJSON: BundleFixture.manifest(captureEnabled: false),
            sql: Self.minimalSQL)

        let bundle = try read(source.path)

        XCTAssertEqual(bundle.captureEnabled, false)
        XCTAssertTrue(bundle.notes.contains { $0.contains("capture was OFF") },
                      "expected a capture-off note, got \(bundle.notes)")
    }

    /// The builder writes its own version of that sentence into the manifest; printing both would
    /// say it twice.
    func testCaptureOffNoteIsNotPrintedTwice() throws {
        let source = try BundleFixture.make(
            in: work, named: "dave-bundle",
            manifestJSON: BundleFixture.manifest(
                captureEnabled: false,
                notes: ["Diagnostics capture was off for part of this period."]),
            sql: Self.minimalSQL)

        let bundle = try read(source.path)

        let captureNotes = bundle.notes.filter { $0.lowercased().contains("capture was off")
            || $0.contains("capture was OFF") }
        XCTAssertEqual(captureNotes.count, 1, "got \(bundle.notes)")
    }

    /// `DiagnosticsBundle.build` writes the manifest with `try?`, so a real bundle can arrive
    /// without one. That is a note on the import, not a rejection.
    func testBundleWithoutManifestImportsWithAProvenanceNote() throws {
        let source = try BundleFixture.make(
            in: work, named: "nameless-bundle", manifestJSON: nil, sql: Self.minimalSQL)

        let bundle = try read(source.path)

        XCTAssertNil(bundle.manifest)
        XCTAssertNil(bundle.captureEnabled)
        XCTAssertTrue(bundle.notes.contains { $0.contains("No manifest.json") },
                      "expected a missing-manifest note, got \(bundle.notes)")
    }

    func testUndecodableManifestIsStoredVerbatimWithANote() throws {
        let source = try BundleFixture.make(
            in: work, named: "broken-bundle",
            manifestJSON: "{ this is not json",
            sql: Self.minimalSQL)

        let bundle = try read(source.path)

        XCTAssertNil(bundle.manifest)
        XCTAssertEqual(bundle.manifestJSON, "{ this is not json")
        XCTAssertTrue(bundle.notes.contains { $0.contains("could not be decoded") },
                      "expected a decode note, got \(bundle.notes)")
    }

    // MARK: - What a bundle is

    /// A tester sends a `.zip`; an operator who unzipped it to look inside should not have to
    /// re-zip it. Both must read the same.
    func testZipAndExpandedDirectoryReadIdentically() throws {
        let directory = try BundleFixture.make(
            in: work, named: "alice-bundle", sql: Self.minimalSQL)
        let zip = try BundleFixture.archive(directory)

        let fromDirectory = try read(directory.path)
        var reader = BundleReader()
        let fromZip = try reader.read(path: zip.path)
        defer { reader.cleanUp() }

        XCTAssertEqual(fromDirectory.bundleID, fromZip.bundleID)
        XCTAssertEqual(fromZip.archiveName, "alice-bundle.zip")
    }

    /// Identity is the manifest, so renaming the archive does not make it a second bundle — the
    /// idempotency guarantee would be worthless if it depended on a filename.
    func testRenamingTheArchiveDoesNotChangeIdentity() throws {
        let source = try BundleFixture.make(
            in: work, named: "alice-bundle", sql: Self.minimalSQL)
        let original = try read(source.path)

        let renamed = work.appendingPathComponent("alice-bundle-COPY", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: renamed)

        XCTAssertEqual(try read(renamed.path).bundleID, original.bundleID)
    }

    /// Without a manifest there is nothing to hash but the database itself.
    func testBundlesWithoutManifestsAreIdentifiedByTheirDatabase() throws {
        let first = try BundleFixture.make(
            in: work, named: "one", manifestJSON: nil, sql: Self.minimalSQL)
        let second = try BundleFixture.make(
            in: work, named: "two", manifestJSON: nil,
            sql: ["CREATE TABLE poll_snapshots (id INTEGER, tool TEXT)",
                  "INSERT INTO poll_snapshots VALUES (2, 'codex')"])

        XCTAssertNotEqual(try read(first.path).bundleID, try read(second.path).bundleID)
    }

    /// A directory carrying none of the artifacts is not a bundle. Absence of the *database*
    /// specifically is no longer a rejection — that is the ordinary shape.
    func testDirectoryWithNoArtifactsAtAllIsRejected() throws {
        let empty = work.appendingPathComponent("not-a-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        XCTAssertThrowsError(try read(empty.path)) { error in
            guard case BundleReader.ReaderError.notABundle = error else {
                return XCTFail("expected notABundle, got \(error)")
            }
        }
    }

    // MARK: - The sanitized shape

    /// STEP_124: a bundle written before the rename carries `agentpilot.db`. It used to import
    /// zero rows silently, with a note blaming consent its own manifest contradicted.
    func testLegacyAgentPilotBundleReadsItsDatabase() throws {
        let source = try BundleFixture.make(
            in: work, named: "AgentPilot-diagnostics-20260722-1712-0.1.3-4-beta",
            databaseName: "agentpilot.db",
            sql: Self.minimalSQL)

        let bundle = try read(source.path)

        XCTAssertEqual(bundle.databasePath, source.appendingPathComponent("agentpilot.db").path)
        XCTAssertFalse(bundle.notes.contains { $0.contains("No database") },
                       "a legacy bundle has a database; got \(bundle.notes)")
    }

    /// A bundle that arrives with no database at all (the builder's copy is non-fatal) still
    /// imports its provenance — and the note blames the copy, not the tester's consent.
    func testSanitizedBundleWithoutADatabaseImports() throws {
        let source = try BundleFixture.make(
            in: work, named: "erin-bundle",
            whatLookedWrong: "Menu bar froze at 4%.",
            summary: #"{"pollSnapshots":128}"#,
            sql: nil)

        let bundle = try read(source.path)

        XCTAssertNil(bundle.databasePath)
        XCTAssertEqual(bundle.whatLookedWrong, "Menu bar froze at 4%.")
        XCTAssertTrue(bundle.notes.contains { $0.contains("No database in this bundle") },
                      "expected the no-database note, got \(bundle.notes)")
        XCTAssertFalse(bundle.notes.contains { $0.contains("not authorized") },
                       "a missing database is a failed copy, not withheld consent")
    }

    /// Without a manifest *or* a database the sanitized artifacts have to carry identity, or every
    /// re-import would look like a new bundle and duplicate its provenance row.
    func testSanitizedBundleIdentityIsStableAndDistinct() throws {
        let first = try BundleFixture.make(
            in: work, named: "one", manifestJSON: nil,
            summary: #"{"pollSnapshots":1}"#, sql: nil)
        let second = try BundleFixture.make(
            in: work, named: "two", manifestJSON: nil,
            summary: #"{"pollSnapshots":2}"#, sql: nil)

        XCTAssertEqual(try read(first.path).bundleID, try read(first.path).bundleID)
        XCTAssertNotEqual(try read(first.path).bundleID, try read(second.path).bundleID)
    }

    func testMissingPathIsRejected() {
        XCTAssertThrowsError(try read("/nonexistent/nope.zip")) { error in
            guard case BundleReader.ReaderError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    /// The tester's own words travel with their rows — the note is the only part of a bundle a
    /// human wrote.
    func testTesterNotesAndEnvironmentAreCarried() throws {
        let source = try BundleFixture.make(
            in: work, named: "alice-bundle",
            whatLookedWrong: "Claude tab said 97% off-machine while I was on a plane.",
            environment: "macOS 15.2 · Apple M2",
            sql: Self.minimalSQL)

        let bundle = try read(source.path)

        XCTAssertEqual(bundle.whatLookedWrong,
                       "Claude tab said 97% off-machine while I was on a plane.")
        XCTAssertEqual(bundle.environment, "macOS 15.2 · Apple M2")
    }

    /// `ditto --keepParent` means an expanded archive holds one folder holding the artifacts, so
    /// pointing at either level must work.
    func testPointingAtTheParentOfABundleDirectoryWorks() throws {
        let nested = work.appendingPathComponent("outer", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try BundleFixture.make(in: nested, named: "alice-bundle", sql: Self.minimalSQL)

        XCTAssertNoThrow(try read(nested.path))
    }
}
