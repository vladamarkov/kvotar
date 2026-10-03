import ArgumentParser
import KvotarCore

/// Flags shared across every `kvotar` subcommand. Included via `@OptionGroup` so each command
/// accepts them without redeclaring — the ArgumentParser idiom for cross-command flags.
struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human-readable text.")
    var json = false

    @Option(name: .long, help: "Path to Kvotar's database (defaults to the app's location).")
    var database: String?

    /// Resolved read-only database path — the override when given, else the app's §5.3 location.
    var databasePath: String { database ?? SQLiteStore.expectedDatabasePath() }
}
