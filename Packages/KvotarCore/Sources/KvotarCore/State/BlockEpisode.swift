import Foundation

/// One continuing block, keyed to the limit that caused it (Baseline §13 / §16, REV-96 §2.1 —
/// STEP_193).
///
/// A block used to be keyed to the five-hour window instance, which is not what a block is: the
/// tester's Codex weekly was spent from 4 Sep to the Monday reset and the app sent **eleven**
/// "Over quota" banners, one per five-hour rollover underneath it. An episode is the limit plus
/// the moment it lets go — it survives a rollover, a stale gap and a relaunch, and ends when a
/// fresh poll shows that limit below the ceiling.
public struct BlockEpisode: Sendable, Equatable {

    /// Which limit is doing the blocking. Raw values are part of the persisted `settings` key, so
    /// they are the storage contract as much as the vocabulary (§17.1).
    public enum Limit: String, Sendable, Equatable, CaseIterable {
        case primary
        case secondary
        case monthly
    }

    public let tool: Tool
    public let limit: Limit
    /// When the blocking limit resets — the instant the episode ends, and the reset the
    /// notification body names.
    public let limitResetsAt: Date

    public init(tool: Tool, limit: Limit, limitResetsAt: Date) {
        self.tool = tool
        self.limit = limit
        self.limitResetsAt = limitResetsAt
    }

    /// The dedup key, persisted as `settings["block_episode.<tool>"]` (§17.1).
    public var key: String { "\(limit.rawValue)|\(Int(limitResetsAt.timeIntervalSince1970))" }

    /// Whether a stored key describes **this** episode.
    ///
    /// Not a string comparison, deliberately. The provider wobbles `resets_at` by a second or two
    /// between polls — the tester's weekly reported `06:55:26` and `06:55:27` inside the same
    /// block — and on a string match that reads as a new episode and fires a second banner, which
    /// is the exact failure this key exists to prevent. Same limit, and a reset inside the one
    /// Core tolerance every other reading of this boundary uses
    /// (`QuotaSnapshot.resetJitterTolerance`), is the same episode.
    public func matches(storedKey: String?) -> Bool {
        guard let storedKey else { return false }
        let parts = storedKey.split(separator: "|")
        guard parts.count == 2, parts[0] == limit.rawValue,
              let epoch = TimeInterval(parts[1]) else { return false }
        return QuotaSnapshot.isSameResetInstant(epoch, limitResetsAt)
    }

    /// The `settings` key this tool's current episode is stored under.
    public static func settingsKey(for tool: Tool) -> String { "block_episode.\(tool.rawValue)" }
}
