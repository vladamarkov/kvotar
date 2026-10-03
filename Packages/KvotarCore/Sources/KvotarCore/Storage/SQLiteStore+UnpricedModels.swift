import Foundation
import GRDB

// MARK: - Unpriced-model observations (§17.1 `unpriced_models` — REV-62 §5.3, STEP_92)

/// One `(provider, model)` pair that `resolvePricing` had to price at the provider fallback,
/// with the span and count of its observations. The same shape serves both directions: the
/// in-memory collector drains batches of these into the store, and the diagnostics summary
/// reads the merged rows back out.
public struct UnpricedModelObservation: Codable, Sendable, Equatable {
    public let provider: String
    public let model: String
    /// Unix seconds.
    public let firstSeenAt: Int
    public let lastSeenAt: Int
    public let observationCount: Int

    public init(provider: String, model: String,
                firstSeenAt: Int, lastSeenAt: Int, observationCount: Int) {
        self.provider = provider
        self.model = model
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.observationCount = observationCount
    }
}

extension SQLiteStore {

    /// Merge-upserts a drained batch of fallback observations (the `payload_shapes` pattern):
    /// a new pair inserts; a seen pair widens its span and adds to its count. Permanent table,
    /// no cleanup pass — the row is the record.
    public func upsertUnpricedModels(_ observations: [UnpricedModelObservation]) throws {
        guard !observations.isEmpty else { return }
        do {
            try withPool { pool in
                try pool.write { db in
                    for obs in observations {
                        try db.execute(sql: """
                            INSERT INTO unpriced_models
                                (provider, model, first_seen_at, last_seen_at, observation_count)
                            VALUES (?, ?, ?, ?, ?)
                            ON CONFLICT (provider, model) DO UPDATE SET
                                first_seen_at = MIN(first_seen_at, excluded.first_seen_at),
                                last_seen_at = MAX(last_seen_at, excluded.last_seen_at),
                                observation_count = observation_count + excluded.observation_count
                            """, arguments: [
                                obs.provider, obs.model,
                                obs.firstSeenAt, obs.lastSeenAt, obs.observationCount,
                            ])
                    }
                }
            }
        } catch {
            Logger.error("unpriced_models upsert failed", component: .sqliteStore,
                         metadata: ["rows": "\(observations.count)", "error": "\(error)"])
            throw error
        }
    }

    /// All recorded pairs, oldest first. Read by the diagnostics summary and tests.
    public func unpricedModels() throws -> [UnpricedModelObservation] {
        try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT provider, model, first_seen_at, last_seen_at, observation_count
                    FROM unpriced_models ORDER BY first_seen_at, provider, model
                    """).map { row in
                        UnpricedModelObservation(
                            provider: row["provider"], model: row["model"],
                            firstSeenAt: row["first_seen_at"], lastSeenAt: row["last_seen_at"],
                            observationCount: row["observation_count"])
                    }
            }
        }
    }
}
