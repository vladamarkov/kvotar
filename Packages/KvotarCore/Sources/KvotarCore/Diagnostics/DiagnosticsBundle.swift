import Foundation

/// Builds the "Save Diagnostics…" archive (REV-52 §6, D-47, STEP_73).
///
/// Export is always a human act; the app never transmits it. The ordinary bundle is deliberately
/// aggregate-only. An authorized extended bundle — one written inside an explicit, visibly active
/// capture window of at most 24 hours — additionally carries safety-filtered payloads and a
/// checkpointed copy of the database, which is the artifact a real investigation needs.
/// (STEP_136 briefly shipped the database in every bundle for the pre-alpha tester group; P1-31
/// restored the consent gate on 2026-09-07 for the first public build.)
///
/// Lives in Core, not the App target, so the CLI importer (STEP_74) and any future command reuse it
/// rather than reimplementing it. AppKit-free — revealing the file in Finder is the caller's job.
public enum DiagnosticsBundle {

    /// Facts Core cannot observe for itself; supplied by the composition root.
    public struct HostFacts: Sendable {
        /// `ForecastLogRecorder.currentAppVersion()` — e.g. `0.1.2 (3) beta`.
        public let appVersion: String
        public let channel: BuildChannel
        /// `UNAuthorizationStatus` rendered as a word, or `"unknown"`.
        public let notificationAuthorization: String
        public let openAtLogin: Bool
        /// `pricing.json`'s own `version` / `updated` (STEP_91). Every est. token value in the
        /// bundled database was produced by *some* rate table, and until now the bundle carried no
        /// way to tell which — a stale rate and a parsing bug look identical in the numbers. `nil`
        /// when the table failed to load; the report then says so rather than inventing a version.
        public let pricingVersion: String?
        public let pricingUpdated: String?

        public init(appVersion: String, channel: BuildChannel,
                    notificationAuthorization: String, openAtLogin: Bool,
                    pricingVersion: String? = nil, pricingUpdated: String? = nil) {
            self.appVersion = appVersion
            self.channel = channel
            self.notificationAuthorization = notificationAuthorization
            self.openAtLogin = openAtLogin
            self.pricingVersion = pricingVersion
            self.pricingUpdated = pricingUpdated
        }
    }

    public enum BundleError: Error, LocalizedError {
        case zipFailed(status: Int32)

        public var errorDescription: String? {
            switch self {
            case .zipFailed(let status): return "Archiving failed (ditto exit \(status))."
            }
        }
    }

    /// Assembles the archive and returns its URL.
    ///
    /// **Default (no capture window): sanitized.** Aggregate counts, environment facts, the manifest
    /// and the tester's own sentence. No database, no account rows, no project paths, no logs.
    ///
    /// **Inside an authorized capture window:** adds the safety-filtered extended payloads and a
    /// checkpointed copy of the database. That copy carries account emails, project paths and months
    /// of usage history, which is exactly why it is gated on consent that expires — never on the
    /// default path. It still contains no prompts, code or transcripts; those are never stored.
    ///
    /// **Log files ride in both cases (STEP_135).** REV-52 §1.2 excluded them on the reading that a
    /// ring rotating on every launch has usually discarded the incident by collection time. That was
    /// true of the writer as it stood, and STEP_135 changed the writer: rotation is on size only, the
    /// ring is ten deep, and the test suite no longer writes into it — so the log now holds weeks,
    /// and it is the only artifact that carries the *sequence* of what the app did. It carries no
    /// prompts, code, transcripts or response bodies (Baseline §10.6 keeps them out by construction)
    /// and no email (`email=<redacted>`); it does carry the user's home path inside the two watcher
    /// roots, which is why it sits at the same tier as the rest of an unredacted bundle.
    ///
    /// **`explanation` is what the popover was showing (STEP_133).** Supplied by the composition
    /// root, which reads it off the view model on the main actor before this call; `nil` when no
    /// tab had a render, which the manifest then says in a note rather than shipping an empty
    /// file. `HostFacts` stays host facts — this is a render, not a fact about the machine.
    public static func build(
        store: SQLiteStore,
        facts: HostFacts,
        explanation: ExplanationSnapshot? = nil,
        logDirectory: URL = Logger.logDirectoryURL,
        destinationDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true),
        now: Date = Date()
    ) async throws -> URL {
        let fm = FileManager.default
        let name = bundleName(version: facts.appVersion, channel: facts.channel, now: now)
        let staging = fm.temporaryDirectory
            .appendingPathComponent("KvotarDiagnostics-\(UUID().uuidString)", isDirectory: true)
        let root = staging.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 1. Aggregate facts only — no account rows, projects, local events, preferences, or logs.
        let summary = (try? await store.diagnosticsSummary())
        if let summary, let encoded = try? manifestEncoder.encode(summary) {
            try? encoded.write(to: root.appendingPathComponent("diagnostics-summary.json"))
        }
        var extendedIncluded = false
        var databaseIncluded = false
        if DiagnosticsCapture.isEnabled {
            if let extended = try? await store.extendedDiagnosticsJSON() {
                try? extended.write(to: root.appendingPathComponent("extended-payloads.json"))
                extendedIncluded = true
            }
            // Checkpointed via VACUUM INTO — a consistent copy, never the live file. Non-fatal: a
            // bundle carrying only its summary still beats no bundle at all, and the manifest and
            // notes both say the copy is missing rather than letting an empty corpus imply calm.
            do {
                try await store.backup(
                    to: root.appendingPathComponent(ProductIdentity.databaseFilename).path)
                databaseIncluded = true
            } catch {
                Logger.warning("Diagnostics database copy failed", component: .appLifecycle,
                               metadata: ["error": "\(error)"])
            }
        }

        // The explanation layer as the tester saw it (STEP_133). Only *tagged* elements are in
        // here, which is what keeps the project name, the per-model rows, the session counts, the
        // email and the plan badge out — see `ExplanationSnapshot`. It carries the app's own copy
        // and the tester's own numbers, and nothing a provider returned, so it rides at the
        // default tier beside the database rather than behind the payload gate.
        var explanationIncluded = false
        if let explanation, let encoded = try? manifestEncoder.encode(explanation) {
            try? encoded.write(to: root.appendingPathComponent(ExplanationSnapshot.filename))
            explanationIncluded = true
        }

        // 2. Log generations — the sequence of what the app did, which no table records.
        let logsCollected = collectLogs(from: logDirectory, into: root)

        // 3. Environment + manifest.
        let environment = environmentReport(facts: facts, now: now, logsCollected: logsCollected)
        try? Data(environment.utf8)
            .write(to: root.appendingPathComponent("environment.txt"))

        let manifest = Manifest(
            generatedAt: Int(now.timeIntervalSince1970),
            generatedAtLocal: BundleTime.iso(now),
            appVersion: facts.appVersion,
            channel: facts.channel.rawValue,
            captureEnabled: DiagnosticsCapture.isEnabled,
            timeZone: TimeZone.current.identifier,
            contents: ["diagnostics-summary.json", "environment.txt", "manifest.json",
                       whatLookedWrongName]
                + logsCollected.map { "\(logsDirectoryName)/\($0)" }
                + (extendedIncluded ? ["extended-payloads.json"] : [])
                + (databaseIncluded ? [ProductIdentity.databaseFilename] : [])
                + (explanationIncluded ? [ExplanationSnapshot.filename] : []),
            database: summary,
            notes: notes(summary: summary, logsCollected: logsCollected,
                         databaseIncluded: databaseIncluded,
                         explanationIncluded: explanationIncluded))
        if let encoded = try? manifestEncoder.encode(manifest) {
            try? encoded.write(to: root.appendingPathComponent("manifest.json"))
        }

        // 4. The human sentence — the single most valuable artifact, and the one most likely to be
        //    orphaned in a chat thread within a day. Inside the archive it stays attached.
        try? Data(whatLookedWrongTemplate.utf8)
            .write(to: root.appendingPathComponent(whatLookedWrongName))

        // 5. Zip. `--keepParent` so the archive expands into one folder, not loose files.
        let archive = destinationDirectory.appendingPathComponent("\(name).zip")
        try? fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(at: archive)
        let status = await ProcessRun.run(
            "/usr/bin/ditto",
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, archive.path],
            timeout: 30)
        guard status == 0 else { throw BundleError.zipFailed(status: status ?? -1) }

        let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? nil
        Logger.info("Diagnostics bundle written", component: .appLifecycle,
                    metadata: ["name": "\(name).zip", "bytes": "\(size ?? 0)",
                               "capture": "\(DiagnosticsCapture.isEnabled)",
                               "channel": facts.channel.rawValue])
        return archive
    }

    // MARK: - Pieces

    static let whatLookedWrongName = "WHAT_LOOKED_WRONG.txt"

    static let logsDirectoryName = "logs"

    /// Copies every log generation into `<root>/logs/` and returns the names copied, newest first.
    ///
    /// The directory is **enumerated, not enumerated-by-formula**: the ring's depth is the writer's
    /// business, the CLI keeps a separate `kvotar-cli.log` beside it, and a bundle that silently
    /// stopped at generation five because a constant moved would be the P1-24 failure re-enacted
    /// inside the fix for it. Anything not `*.log` is skipped — nothing else belongs in this
    /// directory, and a stray file must not become a transport channel.
    static func collectLogs(from logDirectory: URL, into root: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }

        let logs = entries.filter { $0.pathExtension == "log" }
            .sorted { left, right in
                let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l > r
            }
        guard !logs.isEmpty else { return [] }

        let destination = root.appendingPathComponent(logsDirectoryName, isDirectory: true)
        guard (try? fm.createDirectory(at: destination, withIntermediateDirectories: true)) != nil
        else { return [] }

        // Best effort per file: one unreadable generation must not cost the bundle the others.
        return logs.compactMap { source in
            let name = source.lastPathComponent
            do {
                try fm.copyItem(at: source, to: destination.appendingPathComponent(name))
                return name
            } catch {
                return nil
            }
        }
    }

    /// `Kvotar-diagnostics-20260820-1435-0.2.0-5-release.zip` — date, version and channel, so
    /// bundles from two testers (or two days) never collide in a Downloads folder.
    static func bundleName(version: String, channel: BuildChannel, now: Date) -> String {
        let stamp = DateFormatter.bundleStamp.string(from: now)
        let slug = version
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "-")
        return "Kvotar-diagnostics-\(stamp)-\(slug)"
            + (slug.hasSuffix(channel.rawValue) ? "" : "-\(channel.rawValue)")
    }

    /// Plain text, not JSON — a human opens this one first.
    ///
    /// The timezone block is load-bearing: every number in this app is timestamp arithmetic against
    /// UTC hour buckets and reset deadlines, so a tester in another timezone produces burn rates and
    /// rollup buckets that look exactly like engine bugs. A genuinely skewed clock stays readable by
    /// comparing `Generated` below against the newest database row and log line, both in the bundle.
    static func environmentReport(facts: HostFacts, now: Date, logsCollected: [String]) -> String {
        let tz = TimeZone.current
        let home = FileManager.default.homeDirectoryForCurrentUser
        func exists(_ relative: String) -> String {
            FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path)
                ? "present" : "absent"
        }
        var lines: [String] = [
            "Kvotar diagnostics — environment",
            "",
            "App version:            \(facts.appVersion)",
            "Build channel:          \(facts.channel.rawValue)",
            "Extended Diagnostics:   \(DiagnosticsCapture.isEnabled ? "on" : "off")",
            "Debug logging:          \(Logger.isDebugModeEnabled ? "on" : "off")",
            "macOS:                  \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture:           \(machineArchitecture())",
            "Pricing table:          \(facts.pricingVersion ?? "unavailable")"
                + " (updated \(facts.pricingUpdated ?? "unknown"))",
            "",
            "Generated (local):      \(BundleTime.iso(now))",
            "Generated (UTC):        \(BundleTime.isoUTC(now))",
            "Time zone:              \(tz.identifier)",
            "UTC offset:             \(tz.secondsFromGMT(for: now)) s",
            "DST in effect:          \(tz.isDaylightSavingTime(for: now))",
            "System uptime:          \(Int(ProcessInfo.processInfo.systemUptime)) s",
            "",
            "Notifications:          \(facts.notificationAuthorization)",
            "Open at Login:          \(facts.openAtLogin)",
            "",
            "Credential sources (existence only — contents never read here):",
            "  ~/.codex/auth.json    \(exists(".codex/auth.json"))",
            "  ~/.claude.json        \(exists(".claude.json"))",
            "  ~/.claude/projects    \(exists(".claude/projects"))",
            "",
            "Logs collected:         \(logsCollected.isEmpty ? "none" : logsCollected.joined(separator: ", "))",
        ]
        lines.append("")
        lines.append("Local tool versions (best effort):")
        lines.append("  claude:               \(toolVersion("claude"))")
        // Codex Desktop ships its binary inside the app bundle and often puts nothing a GUI app can
        // reach on PATH (true on the dogfood machine), so the §8.6 discovery order is mirrored here
        // — otherwise the line reads `unknown` on a perfectly normal install.
        lines.append("  codex:                \(toolVersion("codex", preferring: codexBinaryCandidates))")
        return lines.joined(separator: "\n") + "\n"
    }

    static func notes(summary: DiagnosticsSummary?, logsCollected: [String],
                      databaseIncluded: Bool = false,
                      explanationIncluded: Bool = false) -> [String] {
        var notes: [String] = []
        if summary == nil { notes.append("Database summary unavailable — counts omitted.") }
        if logsCollected.isEmpty {
            notes.append("No log files were found — an absent log means 'nothing on disk', not "
                         + "'nothing happened'.")
        }
        if DiagnosticsCapture.isEnabled && !databaseIncluded {
            notes.append("Extended Diagnostics was on but the database copy failed — this bundle carries "
                         + "its summary only, so an absent row means 'not exported', not 'absent'.")
        }
        if !explanationIncluded {
            notes.append("Explanation snapshot absent — the popover had no rendered tab.")
        }
        if let unpriced = summary?.unpricedModels, !unpriced.isEmpty {
            let names = unpriced.map { "\($0.provider)/\($0.model)" }.joined(separator: ", ")
            notes.append("Models priced at the provider fallback (no pricing.json row): \(names). "
                         + "Their est. token value figures used the fallback rate.")
        }
        if !DiagnosticsCapture.isEnabled {
            notes.append("Extended Diagnostics was OFF when this bundle was written — an empty "
                         + "payload set means 'not captured', not 'nothing happened'.")
        }
        return notes
    }

    static let whatLookedWrongTemplate = """
        What looked wrong?

        One or two sentences is plenty. The most useful things to say:

          • What you saw          (e.g. "it said 'No active session' but I was mid-session")
          • What you expected
          • Roughly when          (date and time, so it can be found in the logs)
          • Anything you did just before it

        Write below this line, then send this whole .zip file to
        \(ProductIdentity.supportEmail) — and thank you.
        ------------------------------------------------------------------------

        """

    // MARK: - Probes

    /// `<tool> --version` through a login shell so the user's PATH (Homebrew, custom installs) is in
    /// scope (`/bin/zsh -lc`, the shape a `command -v` lookup needs). Best effort: an
    /// absent or hung tool records as `unknown`, it never fails the bundle.
    ///
    /// Only a line that looks like a version string is kept. A login shell runs the user's
    /// profile, and one tester's profile echoed an API key on startup — it landed in the bundle
    /// they sent us (2026-08-27). Anything that is not a version is dropped, never quoted.
    /// Only the **first** executable candidate is run. Trying each in turn would cost a 3-second
    /// timeout per miss, and a bundle that takes half a minute to save is a bundle nobody sends.
    static func toolVersion(_ tool: String, preferring paths: [String] = []) -> String {
        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
           let direct = versionLine(ProcessRun.output(path, arguments: ["--version"], timeout: 3)) {
            return direct
        }
        return versionLine(
            ProcessRun.output("/bin/zsh", arguments: ["-lc", "\(tool) --version"], timeout: 3))
            ?? "unknown"
    }

    /// The §8.6 search list. `appBundle: nil` because resolving the bundle identifier needs
    /// LaunchServices and KvotarCore stays free of it — this is a best-effort version line, and the
    /// literal candidates cover every install seen so far.
    static var codexBinaryCandidates: [String] {
        CodexBinaryCandidates.candidates(
            appBundle: nil, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The first output line that reads as a version report: short, and containing `N.N` where
    /// the digits are not part of a longer token. Profile noise (`export`, `KEY=value`, banners)
    /// fails the shape and is discarded.
    static func versionLine(_ output: String?) -> String? {
        guard let output else { return nil }
        let pattern = #"(^|[^A-Za-z0-9_])\d{1,4}\.\d{1,4}(\.\d{1,4})?([^A-Za-z0-9_]|$)"#
        return output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                line.count <= 80
                    && !line.contains("=")
                    && line.range(of: pattern, options: .regularExpression) != nil
            }
    }

    static func machineArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    // MARK: - Manifest

    /// Contents, channel, whether capture was on, and the period covered. Without the capture flag
    /// an empty payload set is ambiguous between "capture was off" and "nothing happened".
    struct Manifest: Codable {
        let generatedAt: Int
        let generatedAtLocal: String
        let appVersion: String
        let channel: String
        let captureEnabled: Bool
        let timeZone: String
        let contents: [String]
        let database: DiagnosticsSummary?
        let notes: [String]
    }

    private static var manifestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Slashes unescaped: the manifest is read by a human first, and `logs\/kvotar.3.log` is
        // noise in a file whose whole job is to say plainly what the archive contains.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - Helpers

/// The timestamp grammar every artifact in a bundle shares — `2026-08-22 20:41:07 +02:00`.
/// Public because `ExplanationSnapshot` is built in the UI package and must stamp itself the
/// same way the manifest does; two formatters would let two files in one zip disagree.
public enum BundleTime {
    public static func iso(_ date: Date) -> String {
        DateFormatter.bundleTimestamp.string(from: date)
    }

    static func isoUTC(_ date: Date) -> String {
        DateFormatter.bundleTimestampUTC.string(from: date)
    }
}

private extension DateFormatter {
    static let bundleStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f
    }()

    static let bundleTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f
    }()

    static let bundleTimestampUTC: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return f
    }()
}

/// Shell-out with a watchdog, so the bundle never hangs a click on a wedged subprocess.
enum ProcessRun {
    /// Runs off the calling thread and returns the exit status, or nil if the process never started.
    /// A watchdog terminates it after `timeout`.
    static func run(_ path: String, arguments: [String], timeout: TimeInterval) async -> Int32? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runSync(path, arguments: arguments,
                                                       timeout: timeout).status)
            }
        }
    }

    /// stdout of a short-lived probe, or nil on any failure. Synchronous by design — callers are
    /// off the main path already (bundle assembly runs in a `Task`).
    static func output(_ path: String, arguments: [String], timeout: TimeInterval) -> String? {
        let result = runSync(path, arguments: arguments, timeout: timeout, captureOutput: true)
        guard result.status == 0, let data = result.output, !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func runSync(_ path: String, arguments: [String], timeout: TimeInterval,
                                captureOutput: Bool = false) -> (status: Int32?, output: Data?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()   // discard
        do {
            try process.run()
        } catch {
            return (nil, nil)
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting: a full pipe buffer would otherwise deadlock the child.
        let data = captureOutput ? stdout.fileHandleForReading.readDataToEndOfFile() : nil
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, data)
    }
}
