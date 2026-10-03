import ArgumentParser
import Foundation
import KvotarCore

/// `kvotar status` — the flagship product command. Prints the per-tool headline the menu bar
/// shows (state, utilization %, reset countdown) from the app's last-persisted state, read-only.
/// It never polls a quota endpoint (that is the running app's job) and labels stale/absent data
/// honestly (`· as of [t]`), never as live. Live/IPC freshness is Phase B (STEP_61).
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show Claude and Codex quota state, utilization, and reset.")

    @OptionGroup var global: GlobalOptions

    @Option(name: .long, help: "Scope to one tool: claude or codex.")
    var tool: String?

    func validate() throws {
        if let tool, Tool(rawValue: tool) == nil {
            throw ValidationError("Unknown tool '\(tool)'. Use claude or codex.")
        }
    }

    func run() async throws {
        CLIRuntime.bootstrap()
        let path = global.databasePath

        // The DB is absent until the app has run once. Don't create it — the CLI is read-only.
        guard FileManager.default.fileExists(atPath: path) else {
            CLIOutput.print(StatusReport.notRunYet(path: path), json: global.json)
            throw ExitCode.failure
        }

        let tools: [Tool] = tool.flatMap(Tool.init(rawValue:)).map { [$0] } ?? Tool.allCases
        do {
            let store = try SQLiteStore.openReadOnly(path: path)
            let now = Date()
            var rows: [StatusReport.Row] = []
            for tool in tools {
                rows.append(StatusReport.Row(from: try await StatusReader.read(tool: tool, from: store, now: now),
                                             now: now))
            }
            CLIOutput.print(StatusReport.ok(rows: rows), json: global.json)
        } catch {
            Logger.warning("status: database read failed", component: .cli,
                           metadata: ["path": path, "error": "\(error)"])
            CLIOutput.print(StatusReport.unreadable(path: path), json: global.json)
            throw ExitCode.failure
        }
    }
}

/// `status`'s output payload. On success `tools` carries one row per reported tool and `reason` is
/// nil; on a degrade path `tools` is empty and `reason`/`message` mirror `DoctorReport`
/// (`not_run_yet` / `open_failed`). Human-only display fields (prefix, label, detail, freshness) are
/// stored for rendering but omitted from `CodingKeys`, so JSON stays the stable machine contract.
struct StatusReport: CLIOutputPayload {
    let tools: [Row]
    let reason: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case tools
        case reason
        case message
    }

    /// One tool's line. The encoded fields are the machine contract; the trailing `let`s (not in
    /// `CodingKeys`) carry the pre-rendered human cells so `humanText` needs no Core types.
    struct Row: Encodable {
        let toolRaw: String
        let state: String
        let stateRaw: String
        let window: String?
        let utilizationPct: Double?
        let resetsAt: Int?
        let runwayDays: Double?
        let polledAt: Int?
        let stale: Bool
        let asOf: String?

        // Human-render only — deliberately excluded from CodingKeys.
        let prefix: String
        let utilText: String
        let detailText: String
        let freshnessText: String

        enum CodingKeys: String, CodingKey {
            case toolRaw = "tool"
            case state
            case stateRaw = "state_raw"
            case window
            case utilizationPct = "utilization_pct"
            case resetsAt = "resets_at"
            case runwayDays = "runway_days"
            case polledAt = "polled_at"
            case stale
            case asOf = "as_of"
        }

        init(from status: ToolStatus, now: Date) {
            // The reported window is the live 5-hour one, else the monthly fallback (Codex business /
            // Claude Enterprise) — mirroring the app's §13 item-12 monthly layout.
            let win = CLIFormat.displayWindow(status.snapshot, now: now)

            toolRaw = status.tool.rawValue
            state = CLIFormat.stateLabel(status.state)
            stateRaw = status.state.rawValue
            window = win.kind?.rawValue
            utilizationPct = win.usedPct
            resetsAt = win.resetsAt.map { Int($0.timeIntervalSince1970) }
            runwayDays = win.runwayDays
            polledAt = status.polledAt.map { Int($0.timeIntervalSince1970) }
            stale = status.isStale
            asOf = (status.isStale ? status.polledAt : nil).map { CLIFormat.clock($0, now: now) }

            prefix = status.tool.menuBarPrefix
            // REV-77 / D-97 (STEP_140): the human column prints remaining, like every app
            // surface. JSON `utilization_pct` above keeps its name and meaning — machine contract.
            utilText = CLIFormat.percent(win.usedPct.map { max(0, 100 - $0) })
            detailText = CLIFormat.detail(window: win, hasSnapshot: status.snapshot != nil, now: now)
            freshnessText = CLIFormat.freshnessSuffix(polledAt: status.polledAt, isStale: status.isStale, now: now)
        }
    }

    var humanText: String {
        if let message { return message }
        // Fixed-width columns: prefix (2) · state (widest label "Pacing Only" = 11) · util (4, right).
        return tools.map { r in
            let label = r.state.padding(toLength: 11, withPad: " ", startingAt: 0)
            let util = String(repeating: " ", count: max(0, 4 - r.utilText.count)) + r.utilText
            return "\(r.prefix)  \(label)  \(util)  \(r.detailText) \(r.freshnessText)"
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    static func ok(rows: [Row]) -> StatusReport {
        StatusReport(tools: rows, reason: nil, message: nil)
    }

    static func notRunYet(path: String) -> StatusReport {
        StatusReport(tools: [], reason: "not_run_yet",
                     message: "Kvotar hasn't run yet — no database at \(path)")
    }

    static func unreadable(path: String) -> StatusReport {
        StatusReport(tools: [], reason: "open_failed",
                     message: "Can't read Kvotar's database — is Kvotar running? (\(path))")
    }
}
