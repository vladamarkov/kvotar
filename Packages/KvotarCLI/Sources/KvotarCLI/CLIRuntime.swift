import KvotarCore

/// One-time process setup shared by every subcommand. Called at the top of each command's `run()`
/// (root `run()` does not execute when a subcommand is matched, so setup lives per-command).
enum CLIRuntime {
    static func bootstrap() {
        // Isolate CLI diagnostics into their own append-only log so `kvotar` invocations never
        // rotate or interleave the running app's shared `kvotar.log` (STEP_54). One subcommand
        // runs per process, so no idempotence guard is needed.
        Logger.useLogFile(basename: "kvotar-cli")
    }
}
