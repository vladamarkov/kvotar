import ArgumentParser
import Foundation
import KvotarCore

/// `kvotar capture` — turn diagnostics capture (§10.7a) off, or report its state.
///
/// The twin of `debug` for the off switch: same settings-row source of truth, same read-write path
/// through `SQLiteStore.writeSetting` (which appends the `settings_changes` audit row in the same
/// transaction and skips no-op re-writes), same payload-less Darwin notification so a running app
/// flips live without a relaunch.
///
/// **There is no way on from here.** Consent needs a visible confirmation and an expiry, and only
/// the app's *Enable Extended Diagnostics for 24 Hours…* dialog asks for both. A CLI `--enable`
/// used to write the flag with no expiry, which the app read as off and wrote back, while the CLI
/// said it had worked. `--enable` is kept only as a hidden flag that refuses and points to the
/// menu item, so an old habit or script gets directions instead of "unknown option".
///
/// **`--disable` also deletes the captured payloads.** Off means gone, not "stop appending".
struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Turn diagnostics capture off, or show its state.")

    /// What `--enable` says instead of turning capture on.
    static let enableRefusal = "Diagnostics capture can only be turned on in the app: right-click "
        + "the Kvotar menu-bar item and choose Enable Extended Diagnostics for 24 Hours…"

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: .hidden)
    var enable = false

    @Flag(name: .long, help: "Turn diagnostics capture off and delete captured payloads.")
    var disable = false

    @Flag(name: .long, help: "Show whether diagnostics capture is on.")
    var status = false

    func validate() throws {
        if enable { throw ValidationError(Self.enableRefusal) }
        guard [disable, status].filter({ $0 }).count == 1 else {
            throw ValidationError("Specify exactly one of --disable or --status.")
        }
    }

    func run() async throws {
        CLIRuntime.bootstrap()
        let path = global.databasePath
        let action: CaptureReport.Action = status ? .status : .disabled

        // The DB is absent until the app has run once. Don't create it (matches `doctor`/`debug`).
        guard FileManager.default.fileExists(atPath: path) else {
            CLIOutput.print(CaptureReport.notRunYet(path: path, action: action), json: global.json)
            throw ExitCode.failure
        }

        if status {
            try await runStatus(path: path)
        } else {
            try await runDisable(path: path)
        }
    }

    private func runStatus(path: String) async throws {
        do {
            let store = try SQLiteStore.openReadOnly(path: path)
            let value = (try? await store.readSetting(key: DiagnosticsCapture.settingsKey)) ?? nil
            CLIOutput.print(
                CaptureReport.status(enabled: DiagnosticsCapture.isEnabled(value), path: path),
                json: global.json)
        } catch {
            Logger.warning("capture: database open failed", component: .cli,
                           metadata: ["path": path, "error": "\(error)"])
            CLIOutput.print(CaptureReport.unreadable(path: path, action: .status), json: global.json)
            throw ExitCode.failure
        }
    }

    private func runDisable(path: String) async throws {
        do {
            // Read-write, non-migrating: the app owns the schema; we only flip one already-migrated
            // settings row. WAL + busy-timeout make the write safe while the app holds the file.
            let store = try SQLiteStore.openReadWrite(path: path)
            try await store.writeSetting(key: DiagnosticsCapture.settingsKey, value: "0")
            // Delete here as well as in the app: the CLI must leave nothing behind even if no app
            // is running to receive the notification.
            try await store.deleteCapturedPayloads()
            Self.postDarwinNotification()
            Logger.info("diagnostics capture disabled via CLI",
                        component: .cli, metadata: ["path": path])
            CLIOutput.print(CaptureReport.disabled(path: path), json: global.json)
        } catch {
            Logger.warning("capture: settings write failed", component: .cli,
                           metadata: ["path": path, "error": "\(error)"])
            CLIOutput.print(CaptureReport.unreadable(path: path, action: .disabled), json: global.json)
            throw ExitCode.failure
        }
    }

    /// Wake a running app to re-read the setting. Payload-less/level-triggered — see the type doc.
    private static func postDarwinNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(DiagnosticsCapture.darwinNotificationName as CFString),
            nil, nil, true)
    }
}

/// `capture`'s output payload. Mirrors `DebugReport` field-for-field so a consumer parsing one can
/// parse the other; `reason` is `nil` on success and carries `not_run_yet` / `open_failed`.
struct CaptureReport: CLIOutputPayload {
    enum Action: String { case disabled, status }

    let captureEnabled: Bool
    let action: String
    let databasePath: String
    let reason: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case captureEnabled = "diagnostics_capture_enabled"
        case action
        case databasePath = "database_path"
        case reason
        case message
    }

    var humanText: String { message }

    static func disabled(path: String) -> CaptureReport {
        CaptureReport(captureEnabled: false, action: Action.disabled.rawValue, databasePath: path,
                      reason: nil,
                      message: "Diagnostics capture disabled — captured payloads deleted.")
    }

    static func status(enabled: Bool, path: String) -> CaptureReport {
        CaptureReport(captureEnabled: enabled, action: Action.status.rawValue, databasePath: path,
                      reason: nil,
                      message: "Diagnostics capture is \(enabled ? "on" : "off").")
    }

    static func notRunYet(path: String, action: Action) -> CaptureReport {
        CaptureReport(captureEnabled: false, action: action.rawValue, databasePath: path,
                      reason: "not_run_yet",
                      message: "Kvotar hasn't run yet — no database at \(path)")
    }

    static func unreadable(path: String, action: Action) -> CaptureReport {
        CaptureReport(captureEnabled: false, action: action.rawValue, databasePath: path,
                      reason: "open_failed",
                      message: "Can't open Kvotar's database — is Kvotar running? (\(path))")
    }
}
