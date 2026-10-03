import ArgumentParser
import Foundation
import KvotarCore

/// `kvotar debug` — toggle diagnostic (§10.7) mode or report its state. `--enable`/`--disable`
/// persist `debug_mode_enabled` in the `settings` table (the CLI's one read-write path) and post a
/// payload-less Darwin notification so a running app flips live; `--status` reads it read-only.
///
/// SQLite is the source of truth: the app restores the flag at launch and re-reads the row on every
/// notification, so a dropped/coalesced notification only delays the flip to the next relaunch — it
/// never diverges. The write goes through `SQLiteStore.writeSetting`, which appends the
/// `settings_changes` audit row in the same transaction and skips a no-op re-write.
struct Debug: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Turn diagnostic mode on or off, or show its state.")

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "Turn diagnostic mode on.")
    var enable = false

    @Flag(name: .long, help: "Turn diagnostic mode off.")
    var disable = false

    @Flag(name: .long, help: "Show whether diagnostic mode is on.")
    var status = false

    func validate() throws {
        guard [enable, disable, status].filter({ $0 }).count == 1 else {
            throw ValidationError("Specify exactly one of --enable, --disable, or --status.")
        }
    }

    func run() async throws {
        CLIRuntime.bootstrap()
        let path = global.databasePath
        let action: DebugReport.Action = status ? .status : (enable ? .enabled : .disabled)

        // The DB is absent until the app has run once. Don't create it (matches `doctor`).
        guard FileManager.default.fileExists(atPath: path) else {
            CLIOutput.print(DebugReport.notRunYet(path: path, action: action), json: global.json)
            throw ExitCode.failure
        }

        if status {
            try await runStatus(path: path)
        } else {
            try await runToggle(on: enable, path: path)
        }
    }

    private func runStatus(path: String) async throws {
        do {
            let store = try SQLiteStore.openReadOnly(path: path)
            let value = (try? await store.readSetting(key: DebugMode.settingsKey)) ?? nil
            CLIOutput.print(DebugReport.status(enabled: DebugMode.isEnabled(value), path: path),
                            json: global.json)
        } catch {
            Logger.warning("debug: database open failed", component: .cli,
                           metadata: ["path": path, "error": "\(error)"])
            CLIOutput.print(DebugReport.unreadable(path: path, action: .status), json: global.json)
            throw ExitCode.failure
        }
    }

    private func runToggle(on: Bool, path: String) async throws {
        do {
            // Read-write, non-migrating: the app owns the schema; we only flip one already-migrated
            // settings row. WAL + busy-timeout make the write safe while the app holds the file.
            let store = try SQLiteStore.openReadWrite(path: path)
            try await store.writeSetting(key: DebugMode.settingsKey, value: on ? "1" : "0")
            Self.postDarwinNotification()
            Logger.info("debug mode \(on ? "enabled" : "disabled") via CLI", component: .cli,
                        metadata: ["path": path])
            CLIOutput.print(DebugReport.toggled(enabled: on, path: path), json: global.json)
        } catch {
            Logger.warning("debug: settings write failed", component: .cli,
                           metadata: ["path": path, "error": "\(error)"])
            CLIOutput.print(DebugReport.unreadable(path: path, action: on ? .enabled : .disabled),
                            json: global.json)
            throw ExitCode.failure
        }
    }

    /// Wake a running app to re-read the setting. Payload-less/level-triggered — see the type doc.
    private static func postDarwinNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(DebugMode.darwinNotificationName as CFString),
            nil, nil, true)
    }
}

/// `debug`'s output payload. `reason` is `nil` on success and carries `not_run_yet` / `open_failed`
/// on the degrade paths (mirrors `DoctorReport`); consumers key on `debug_mode_enabled` + `reason`.
struct DebugReport: CLIOutputPayload {
    enum Action: String { case enabled, disabled, status }

    let debugModeEnabled: Bool
    let action: String
    let databasePath: String
    let reason: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case debugModeEnabled = "debug_mode_enabled"
        case action
        case databasePath = "database_path"
        case reason
        case message
    }

    var humanText: String { message }

    static func toggled(enabled: Bool, path: String) -> DebugReport {
        DebugReport(debugModeEnabled: enabled, action: enabled ? Action.enabled.rawValue : Action.disabled.rawValue,
                    databasePath: path, reason: nil,
                    message: "Debug mode \(enabled ? "enabled" : "disabled").")
    }

    static func status(enabled: Bool, path: String) -> DebugReport {
        DebugReport(debugModeEnabled: enabled, action: Action.status.rawValue, databasePath: path,
                    reason: nil, message: "Debug mode is \(enabled ? "on" : "off").")
    }

    static func notRunYet(path: String, action: Action) -> DebugReport {
        DebugReport(debugModeEnabled: false, action: action.rawValue, databasePath: path,
                    reason: "not_run_yet",
                    message: "Kvotar hasn't run yet — no database at \(path)")
    }

    static func unreadable(path: String, action: Action) -> DebugReport {
        DebugReport(debugModeEnabled: false, action: action.rawValue, databasePath: path,
                    reason: "open_failed",
                    message: "Can't open Kvotar's database — is Kvotar running? (\(path))")
    }
}
