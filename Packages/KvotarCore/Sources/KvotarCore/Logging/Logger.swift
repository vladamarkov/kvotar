import Foundation
import os

public enum LogLevel: Int, Comparable {
    case debug
    case info
    case warning
    case error
    case critical

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .critical: return "CRITICAL"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .error
        case .error: return .fault
        case .critical: return .fault
        }
    }
}

public enum LogComponent: String {
    case appLifecycle = "AppLifecycle"
    case claudeAccountAdapter = "ClaudeAccountAdapter"
    case claudeLocalAdapter = "ClaudeLocalAdapter"
    case codexAccountAdapter = "CodexAccountAdapter"
    case codexLocalAdapter = "CodexLocalAdapter"
    case pollEngine = "PollEngine"
    case forecastEngine = "ForecastEngine"
    case attributionEngine = "AttributionEngine"
    case stateEngine = "StateEngine"
    case notificationEngine = "NotificationEngine"
    case sqliteStore = "SQLiteStore"
    case limitsDatabaseAdapter = "LimitsDatabaseAdapter"
    case estimatedValueEngine = "EstimatedValueEngine"
    case cli = "CLI"
}

/// Dual-output logging wrapper (os_log + rotating file). Static-only — never instantiated.
/// See Baseline §10.1: one call site, two outputs, owned entirely by this wrapper.
public struct Logger {
    private static let subsystem = ProductIdentity.bundleIdentifier

    /// File destination for `Logger`. Defaults to the app's shared `kvotar.log`. The dormant CLI
    /// redirects this to its own file at startup (see `useLogFile`) so that `kvotar`
    /// invocations never rotate or interleave the running app's forensic log (STEP_54).
    private nonisolated(unsafe) static var fileWriter: LogFileWriter = .shared

    /// Point the file destination at a separate log file. Call once at process startup, before
    /// any logging. Used by the CLI to write `kvotar-cli.log`.
    public static func useLogFile(basename: String) {
        fileWriter = LogFileWriter(basename: basename)
    }

    /// Test seam: the writer `Logger` is currently pointed at, so a test can wait for its
    /// fire-and-forget write to land.
    static var currentFileWriterForTesting: LogFileWriter { fileWriter }

    /// Directory holding Kvotar's log files.
    ///
    /// **Under XCTest this is a per-process temp directory (STEP_135).** `fileWriter` is a
    /// process-wide static, so every SPM test target used to write fixture polls into the user's
    /// real `kvotar.log` and burn a ring generation per run — on the dogfood machine `kvotar.1.log`
    /// was a two-second file of `plan=enterprise primary=100%` test output. That destroyed history
    /// in exactly the sessions where someone was trying to read it (Baseline §20 P1-24). This is the
    /// only environment sniff in the logging path, and it lives here rather than in each suite so
    /// that a future suite cannot forget it.
    public static var logDirectoryURL: URL {
        isRunningUnderTests ? testLogDirectoryURL : ProductIdentity.logDirectory()
    }

    /// Three probes, because no one of them covers both runners: the environment variable is set by
    /// Xcode and **not** by `swift test`, and the bundle suffix is absent when the test binary runs
    /// directly. `XCTestCase` is loaded only in a test process, which is the reliable one.
    private static let isRunningUnderTests: Bool = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }()

    private static let testLogDirectoryURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("KvotarTestLogs-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)

    /// The log file for `basename` (`<basename>.log`) in `logDirectoryURL`. Single source of truth
    /// for the path — `LogFileWriter` derives its destination from here. The app writes `kvotar`
    /// (default); the CLI writes `kvotar-cli`; the `logs` command reads the app's file (STEP_17).
    public static func logFileURL(basename: String = ProductIdentity.logBasename) -> URL {
        logDirectoryURL.appendingPathComponent("\(basename).log")
    }

    private static let debugModeLock = NSLock()
    private nonisolated(unsafe) static var _debugModeEnabled = false

    public static var isDebugModeEnabled: Bool {
        debugModeLock.lock()
        defer { debugModeLock.unlock() }
        return _debugModeEnabled
    }

    public static func setDebugModeEnabled(_ enabled: Bool) {
        debugModeLock.lock()
        _debugModeEnabled = enabled
        debugModeLock.unlock()
        if enabled {
            fileWriter.writeRaw("[DEBUG MODE]")
        }
    }

    public static func debug(_ message: String, component: LogComponent, metadata: [String: String] = [:]) {
        log(.debug, message, component: component, metadata: metadata)
    }

    public static func info(_ message: String, component: LogComponent, metadata: [String: String] = [:]) {
        log(.info, message, component: component, metadata: metadata)
    }

    public static func warning(_ message: String, component: LogComponent, metadata: [String: String] = [:]) {
        log(.warning, message, component: component, metadata: metadata)
    }

    public static func error(_ message: String, component: LogComponent, metadata: [String: String] = [:]) {
        log(.error, message, component: component, metadata: metadata)
    }

    public static func critical(_ message: String, component: LogComponent, metadata: [String: String] = [:]) {
        log(.critical, message, component: component, metadata: metadata)
    }

    /// One line per run naming what wrote the file (STEP_135). Rotation used to mark a launch; the
    /// ring paid for that in generations (Baseline §20 P1-24), and a marker that also carries the
    /// build, the host and the clock is worth more than the boundary ever was. A log that leaves the
    /// machine is otherwise unattributable — no version, channel, OS or timezone appears anywhere
    /// else in the file, and timezone is load-bearing because every figure in this app is timestamp
    /// arithmetic against UTC buckets.
    ///
    /// Deliberately **one structured line**, not a block: `kvotar logs` filters per line, so a
    /// ten-line banner would be ten records that a `--component` filter splits apart.
    public static func launchBanner(appVersion: String, channel: String,
                                    databasePath: String?, schemaMigration: String?) {
        let tz = TimeZone.current
        info("Kvotar started", component: .appLifecycle, metadata: [
            "version": appVersion,
            "channel": channel,
            "pid": "\(processID)",
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "arch": DiagnosticsBundle.machineArchitecture(),
            "tz": tz.identifier,
            "utc_offset_s": "\(tz.secondsFromGMT())",
            "debug": isDebugModeEnabled ? "on" : "off",
            "capture": DiagnosticsCapture.isEnabled ? "on" : "off",
            "schema": schemaMigration ?? "unknown",
            "db": databasePath ?? "unavailable",
            "log": logFileURL().path,
        ])
    }

    private static func log(_ level: LogLevel, _ message: String, component: LogComponent, metadata: [String: String]) {
        guard level != .debug || isDebugModeEnabled else { return }

        let metadataBlob = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.metadataValue($0.value))" }
            .joined(separator: " ")

        emitOSLog(level, message, component: component, metadataBlob: metadataBlob)

        let paddedLevel = "[\(level.label)]".padding(toLength: 11, withPad: " ", startingAt: 0)
        var line = "\(Self.timestamp()) \(paddedLevel)[\(processID)][\(component.rawValue)] \(message)"
        if !metadataBlob.isEmpty {
            line += " · \(metadataBlob)"
        }
        fileWriter.writeLine(line)
    }

    /// This process's PID, carried in every line's prefix (STEP_135). Two instances writing one
    /// file, or several generations read back concatenated, are otherwise indistinguishable — half
    /// of the REV-13 rotation confusion was exactly that.
    public static let processID = ProcessInfo.processInfo.processIdentifier

    /// Collapses newlines and whitespace runs so one logged record is always one file line.
    ///
    /// `NSError`'s description spans lines, so a single `Poll failed` used to become several file
    /// lines of which only the first parsed — and `LogFilter.matches` opens with
    /// `guard line.isStructured`, so `kvotar logs --level warning` then *discarded* the rest of the
    /// error. The damage was visible in the live log's metadata key set, which had grown the
    /// fragments `omain=`, `ode=` and `escription=`. Enforcing the invariant here covers every call
    /// site that interpolates an error, without touching any of them.
    /// Space runs are left alone — the level field is deliberately padded, and collapsing that
    /// would break the `LogLine` grammar this invariant exists to protect.
    static func singleLine(_ text: String) -> String {
        guard text.contains(where: { $0.isNewline || $0 == "\t" }) else { return text }
        return text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
    }

    /// Quotes a metadata value that contains a space, so the space-separated `k=v` blob stays
    /// parseable (STEP_135).
    ///
    /// The blob is split on spaces, and a token with no `=` is discarded — so an unquoted spaced
    /// value did not merely truncate, it **read as something else**: the live log's
    /// `error=unable to open database file table=thread_goals` parsed as `error=unable`, silently,
    /// with four words dropped on the floor. Values are quoted rather than escaped because a
    /// filesystem path (`…/Application Support/…`) and an OS string (`Version 15.6 (Build 24G84)`)
    /// both have to survive a round trip and stay readable to a human eye.
    static func metadataValue(_ value: String) -> String {
        guard value.contains(" ") || value.contains("\"") else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Renders an `Error` as greppable, one-line metadata. `NSError`'s `domain`/`code` are the two
    /// fields worth filtering on (`NSURLErrorDomain` / `-1009` for offline), and they are buried in
    /// the middle of its description otherwise.
    public static func metadata(for error: Error) -> [String: String] {
        let ns = error as NSError
        return ["error_domain": ns.domain,
                "error_code": "\(ns.code)",
                "error": singleLine(ns.localizedDescription)]
    }

    private static func emitOSLog(_ level: LogLevel, _ message: String, component: LogComponent, metadataBlob: String) {
        let osLogger = os.Logger(subsystem: subsystem, category: component.rawValue)
        #if DEBUG
        osLogger.log(level: level.osLogType, "\(message, privacy: .public) · \(metadataBlob, privacy: .public)")
        #else
        osLogger.log(level: level.osLogType, "\(message, privacy: .public) · \(metadataBlob, privacy: .private)")
        #endif
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
