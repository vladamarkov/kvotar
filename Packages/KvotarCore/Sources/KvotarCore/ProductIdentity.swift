import Foundation

/// Canonical runtime identity for the shipped Kvotar application.
///
/// The Swift package module names remain internal implementation details. All user-visible names,
/// bundle-derived identifiers, and Kvotar-owned filesystem locations come from this type so a
/// future update cannot accidentally fall back to the legacy AgentPilot namespace.
public enum ProductIdentity {
    public static let productName = "Kvotar"

    /// One-line descriptor shown wherever the product introduces itself — the right-click menu's
    /// caption row and the About panel (UI Spec Part 3 §1a, D-86). Sentence case on purpose: every
    /// other row of that menu is a title-cased *command*, and a caption must not read like one.
    public static let tagline = "Claude Code and Codex capacity intelligence"

    /// The sentence that cashes `tagline`'s claim out in concrete verbs. About panel only — the
    /// menu caption has no room for it (D-86).
    public static let descriptionSentence =
        "Tracks how much you have left, how fast you're using it, and when it resets."

    /// Where a report goes. One constant, two surfaces — the About panel and every diagnostics
    /// bundle's `WHAT_LOOKED_WRONG.txt` — so a tester who no longer has the guide still has the
    /// address in front of them, and the two can never drift apart.
    public static let supportEmail = "hello@kvotar.com"

    public static let bundleIdentifier = "com.vladimirmarkovic.kvotar"
    public static let applicationSupportDirectoryName = "Kvotar"
    public static let databaseFilename = "kvotar.db"
    public static let pidFilename = "kvotar.pid"
    public static let logDirectoryName = "Kvotar"
    public static let logBasename = "kvotar"
    public static let diagnosticsPrefix = "Kvotar-diagnostics"
    public static let migrationReceiptFilename = "agentpilot-migration.json"
    public static let buildChannelInfoKey = "KvotarChannel"
    public static let buildChannelSetting = "KVOTAR_CHANNEL"

    /// Frozen legacy identity. These values are read only by the copy-only migration and the
    /// compatibility launch guard. They must not be used for new Kvotar writes.
    public enum Legacy {
        public static let productName = "AgentPilot"
        public static let bundleIdentifier = "com.agentpilot.app"
        public static let applicationSupportDirectoryName = "AgentPilot"
        public static let databaseFilename = "agentpilot.db"
        public static let pidFilename = "agentpilot.pid"
        public static let logDirectoryName = "AgentPilot"
    }

    public static func applicationSupportDirectory(
        fileManager: FileManager = .default,
        create: Bool
    ) throws -> URL {
        let directory = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    public static func legacyApplicationSupportDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Legacy.applicationSupportDirectoryName, isDirectory: true)
    }

    public static func legacyDatabaseURL(fileManager: FileManager = .default) -> URL {
        legacyApplicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent(Legacy.databaseFilename)
    }

    public static func logDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(logDirectoryName, isDirectory: true)
    }
}
