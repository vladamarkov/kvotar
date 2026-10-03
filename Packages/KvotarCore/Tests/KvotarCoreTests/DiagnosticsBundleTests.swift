import XCTest
@testable import KvotarCore

final class DiagnosticsBundleTests: XCTestCase {
    private var scratch: URL!
    private var logDirectory: URL!
    private var destination: URL!
    private var dbPath: String!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvotar-bundle-\(UUID().uuidString)", isDirectory: true)
        logDirectory = scratch.appendingPathComponent("logs", isDirectory: true)
        destination = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        dbPath = scratch.appendingPathComponent("kvotar.db").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        DiagnosticsCapture.setEnabled(false)
    }

    /// The default tier carries aggregate facts and the logs — and, still, no database and no
    /// session file. A `.jsonl` sitting in the log directory is the case that matters: it holds
    /// transcripts, and the never-store rule (REV-52 §4) admits no carve-out for it.
    func testOrdinaryArchiveCarriesLogsButNoDatabaseAndNoSessionFile() async throws {
        try Data("a log line".utf8)
            .write(to: logDirectory.appendingPathComponent("kvotar.log"))
        try Data("private transcript".utf8)
            .write(to: logDirectory.appendingPathComponent("session.jsonl"))

        let archive = try await buildBundle(capture: false)
        let root = try await unzip(archive)
        let files = relativePaths(under: root)

        XCTAssertEqual(files, [
            "diagnostics-summary.json",
            "environment.txt",
            "logs/kvotar.log",
            "manifest.json",
            "WHAT_LOOKED_WRONG.txt",
        ])
        XCTAssertFalse(files.contains { $0.hasSuffix(".db") || $0.hasSuffix(".jsonl") })
    }

    func testAuthorizedArchiveAddsOnlySafetyFilteredExtendedPayloads() async throws {
        DiagnosticsCapture.setEnabled(true)
        let archive = try await buildBundle(capture: true)
        let root = try await unzip(archive)
        let extended = try String(
            contentsOf: root.appendingPathComponent("extended-payloads.json"), encoding: .utf8)

        XCTAssertTrue(extended.contains("<redacted>"))
        XCTAssertFalse(extended.contains("private prompt"))
        XCTAssertFalse(extended.contains("secret-token"))
    }

    /// The point of the consent window: inside it, the bundle carries the database an investigation
    /// actually needs, and the manifest declares it so the artifact is never a surprise.
    func testAuthorizedArchiveCarriesTheDatabaseAndDeclaresIt() async throws {
        DiagnosticsCapture.setEnabled(true)
        let archive = try await buildBundle(capture: true)
        let root = try await unzip(archive)

        XCTAssertTrue(relativePaths(under: root).contains("kvotar.db"))
        let manifest = try String(
            contentsOf: root.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("kvotar.db"), "manifest must list what it shipped")
    }

    /// The other half of the same rule, and the one that protects a tester who never consented:
    /// no capture window, no database — whatever else changes.
    func testOrdinaryArchiveStillCarriesNoDatabase() async throws {
        let archive = try await buildBundle(capture: false)
        let root = try await unzip(archive)

        XCTAssertFalse(relativePaths(under: root).contains("kvotar.db"))
    }

    /// Raw logs stay out of both shapes: the log ring rotates on every launch, so what survives to
    /// export time is rarely the incident (REV-52 §1.2, P1-24).
    /// Inverted in STEP_135 from `testLogsAreExcludedEvenInsideTheConsentWindow`. REV-52 §1.2
    /// excluded logs because a ring rotating on every launch had usually discarded the incident by
    /// collection time; that reasoning was about the writer, and the writer changed. Every
    /// generation travels, plus the CLI's own file, and the manifest and `environment.txt` both
    /// name what was taken — an undeclared artifact in a bundle is how a reader stops trusting it.
    func testEveryLogGenerationTravelsAndIsDeclared() async throws {
        DiagnosticsCapture.setEnabled(true)
        try Data("current".utf8).write(to: logDirectory.appendingPathComponent("kvotar.log"))
        try Data("older".utf8).write(to: logDirectory.appendingPathComponent("kvotar.7.log"))
        try Data("cli".utf8).write(to: logDirectory.appendingPathComponent("kvotar-cli.log"))

        let archive = try await buildBundle(capture: true)
        let root = try await unzip(archive)
        let files = relativePaths(under: root)

        XCTAssertTrue(files.contains("logs/kvotar.log"))
        XCTAssertTrue(files.contains("logs/kvotar.7.log"), "rotated generations travel too")
        XCTAssertTrue(files.contains("logs/kvotar-cli.log"))

        let manifest = try String(
            contentsOf: root.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("logs/kvotar.7.log"))
        XCTAssertFalse(manifest.contains("intentionally excluded"))

        let environment = try String(
            contentsOf: root.appendingPathComponent("environment.txt"), encoding: .utf8)
        XCTAssertTrue(environment.contains("kvotar.7.log"))
        XCTAssertFalse(environment.contains("Logs collected:         none"))
    }

    /// An absent log directory must read as "nothing on disk", never as a silently empty bundle.
    func testAnEmptyLogDirectoryIsNamedInTheNotes() async throws {
        let archive = try await buildBundle(capture: false)
        let root = try await unzip(archive)
        let manifest = try String(
            contentsOf: root.appendingPathComponent("manifest.json"), encoding: .utf8)

        XCTAssertTrue(manifest.contains("No log files were found"))
    }

    func testManifestReportsIdentityCaptureAndSchema() async throws {
        DiagnosticsCapture.setEnabled(true)
        let archive = try await buildBundle(capture: true)
        let root = try await unzip(archive)
        let manifest = try JSONDecoder().decode(
            DiagnosticsBundle.Manifest.self,
            from: try Data(contentsOf: root.appendingPathComponent("manifest.json")))

        XCTAssertEqual(manifest.channel, "release")
        XCTAssertTrue(manifest.captureEnabled)
        XCTAssertEqual(manifest.appVersion, "0.2.0 (5)")
        XCTAssertEqual(manifest.database?.capturedPayloadsWindow, 1)
        XCTAssertEqual(manifest.database?.capturedPayloadsShapeKeeps, 0)
        XCTAssertEqual(manifest.database?.schemaMigration, "v25_model_limit_series")
        XCTAssertTrue(manifest.contents.contains("extended-payloads.json"))
    }

    func testCaptureOffIsExplicitInManifest() async throws {
        let root = try await unzip(try await buildBundle(capture: false))
        let manifest = try JSONDecoder().decode(
            DiagnosticsBundle.Manifest.self,
            from: try Data(contentsOf: root.appendingPathComponent("manifest.json")))
        XCTAssertFalse(manifest.captureEnabled)
        XCTAssertTrue(manifest.notes.contains { $0.contains("OFF") })
        XCTAssertFalse(manifest.contents.contains("extended-payloads.json"))
    }

    /// STEP_133. The snapshot rides at the default tier and the manifest declares it, so a reader
    /// never has to guess whether the popover's cards were captured or merely absent.
    func testExplanationSnapshotIsWrittenWhenProvided() async throws {
        let snapshot = ExplanationSnapshot(
            takenAt: now, activeTab: "claude", peekDelayMs: 600, graceLeaveMs: 120,
            tools: [ExplanationSnapshot.ToolSnapshot(
                tool: "claude", stale: false, inputs: ["usedPct": "27%"],
                entries: [ExplanationSnapshot.Entry(
                    element: "E-01", site: "Account quota", label: "5-hour used", value: "27%",
                    cardText: "**5-hour window.**", liveLine: nil, liveDropReason: "noWindow")],
                anatomy: ExplanationSnapshot.Anatomy(
                    family: "resetsFirst", rows: [["Burn", "0.4% / min"]],
                    comparison: "runway vs reset", flip: nil))])

        let root = try await unzip(try await buildBundle(capture: false, explanation: snapshot))

        XCTAssertTrue(relativePaths(under: root).contains(ExplanationSnapshot.filename))
        let manifest = try String(
            contentsOf: root.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(ExplanationSnapshot.filename),
                      "manifest must list what it shipped")

        let data = try Data(contentsOf: root.appendingPathComponent(ExplanationSnapshot.filename))
        let decoded = try JSONDecoder().decode(ExplanationSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.tools.first?.entries.first?.liveDropReason, "noWindow",
                       "the drop reason is the point — an on-screen silence with a written cause")
    }

    /// The absence is stated, not implied: a bundle with no snapshot must not read as a popover
    /// whose cards were all blank.
    func testAbsentExplanationSnapshotIsNamedInTheNotes() async throws {
        let root = try await unzip(try await buildBundle(capture: false))
        let manifest = try String(
            contentsOf: root.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertFalse(relativePaths(under: root).contains(ExplanationSnapshot.filename))
        XCTAssertTrue(manifest.contains("Explanation snapshot absent"))
    }

    func testHumanPlaceholderAndEnvironmentFacts() async throws {
        let root = try await unzip(try await buildBundle(capture: false))
        let prompt = try String(
            contentsOf: root.appendingPathComponent("WHAT_LOOKED_WRONG.txt"), encoding: .utf8)
        let environment = try String(
            contentsOf: root.appendingPathComponent("environment.txt"), encoding: .utf8)
        XCTAssertTrue(prompt.contains("What looked wrong?"))
        XCTAssertTrue(environment.contains("Kvotar diagnostics"))
        XCTAssertTrue(environment.contains("Open at Login:          true"))
    }

    /// The bundle tells the user where to send it, and that address is the one constant the
    /// About panel reads too — never a second literal (STEP_236).
    func testWhatLookedWrongNamesTheSupportAddress() async throws {
        let root = try await unzip(try await buildBundle(capture: false))
        let prompt = try String(
            contentsOf: root.appendingPathComponent("WHAT_LOOKED_WRONG.txt"), encoding: .utf8)
        XCTAssertTrue(prompt.contains(ProductIdentity.supportEmail))
    }

    func testFilenameCarriesDateVersionBuildAndReleaseLabel() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: now)
        XCTAssertEqual(
            DiagnosticsBundle.bundleName(version: "0.2.0 (5)", channel: .release, now: now),
            "Kvotar-diagnostics-\(stamp)-0.2.0-5-release")
    }

    private func buildBundle(capture: Bool,
                             explanation: ExplanationSnapshot? = nil) async throws -> URL {
        if !capture { DiagnosticsCapture.setEnabled(false) }
        let store = try SQLiteStore(path: dbPath)
        try await store.writeLifecycleEvent(.launch, appVersion: "0.2.0 (5)", occurredAt: now)
        try await store.writeRawPayload(
            tool: .claude, endpoint: DiagnosticsEndpoint.claudeUsage,
            body: Data(#"{"usage":42,"prompt":"private prompt","access_token":"secret-token"}"#.utf8),
            httpStatus: 200, capturedAt: now)
        let facts = DiagnosticsBundle.HostFacts(
            appVersion: "0.2.0 (5)", channel: .release,
            notificationAuthorization: "authorized", openAtLogin: true)
        return try await DiagnosticsBundle.build(
            store: store, facts: facts, explanation: explanation, logDirectory: logDirectory,
            destinationDirectory: destination, now: now)
    }

    private func unzip(_ archive: URL) async throws -> URL {
        let out = scratch.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        let status = await ProcessRun.run(
            "/usr/bin/ditto", arguments: ["-x", "-k", archive.path, out.path], timeout: 30)
        XCTAssertEqual(status, 0)
        let entries = try FileManager.default.contentsOfDirectory(
            at: out, includingPropertiesForKeys: [.isDirectoryKey])
        return try XCTUnwrap(entries.first { $0.hasDirectoryPath })
    }

    private func relativePaths(under root: URL) -> Set<String> {
        var result: Set<String> = []
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        while let path = enumerator?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory)
            if !isDirectory.boolValue { result.insert(path) }
        }
        return result
    }
}

final class DiagnosticsToolVersionProbeTests: XCTestCase {
    func testAVersionLineIsKept() {
        XCTAssertEqual(DiagnosticsBundle.versionLine("2.1.3 (Claude Code)\n"), "2.1.3 (Claude Code)")
        XCTAssertEqual(DiagnosticsBundle.versionLine("codex-cli 0.133.0"), "codex-cli 0.133.0")
    }

    func testProfileNoiseBeforeTheVersionIsSkipped() {
        let output = "Welcome back\nSOME_API_KEY=4nmttjOqSI6t0WcxH45kpIHDNXgKNlgBzgtZGQGL\n2.1.3 (Claude Code)\n"
        XCTAssertEqual(DiagnosticsBundle.versionLine(output), "2.1.3 (Claude Code)")
    }

    func testOutputWithNoVersionShapeIsDropped() {
        XCTAssertNil(DiagnosticsBundle.versionLine("SOME_API_KEY=4nmttjOqSI6t0WcxH45kpIHDNXgKNlgBzgtZGQGL"))
        XCTAssertNil(DiagnosticsBundle.versionLine("zsh: command not found: claude"))
        XCTAssertNil(DiagnosticsBundle.versionLine(nil))
        XCTAssertNil(DiagnosticsBundle.versionLine(""))
    }
}
