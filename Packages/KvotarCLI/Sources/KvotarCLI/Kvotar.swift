import ArgumentParser

/// Root of the `kvotar` CLI. STEP_54 shipped the foundation (argument routing, read-only store
/// access, the `--json` output seam, `doctor`); STEP_17 adds the operator commands `logs` and
/// `debug`. Product commands (`status`, `forecast`, …) arrive in later steps and register
/// themselves in `subcommands`.
@main
struct Kvotar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kvotar",
        abstract: "Monitor Claude and Codex quota from the command line.",
        version: KvotarVersion.full,
        subcommands: [Doctor.self, Logs.self, Debug.self, Capture.self, Status.self,
                      Import.self])
}
