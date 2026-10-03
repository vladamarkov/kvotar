import Foundation
import KvotarCore

/// The state the CLI reports for one tool, read from the app's last-persisted `poll_snapshots`
/// row. Phase A only — no polling, no live burn buffer (that is the running app's job; a second
/// poller is the §9 429/OAuth-contention landmine).
struct ToolStatus {
    let tool: Tool
    let snapshot: QuotaSnapshot?
    let polledAt: Date?
    let state: AppState
    let isStale: Bool
}

/// Shared persisted-state read the product commands (`status`, and later `forecast`/`session`/
/// `today`) reuse. It runs the app's own launch-restore recipe against the newest snapshot:
/// `trigger: .restore` with a cold `.unknown` forecast, so the state it returns is exactly the one
/// the app would classify on restore from the same row. Rate-derived warnings (At Risk / Elevated /
/// fast-burn) require the live in-memory burn buffer, which is deliberately not persisted — so they
/// naturally collapse to the calmer restore state here. A stale hard block still keeps its rank
/// (REV-33), because `classify` treats a monotone-safe block as a fact with an expiry.
enum StatusReader {
    static func read(tool: Tool, from store: SQLiteStore, now: Date = Date()) async throws -> ToolStatus {
        let latest = try await store.readLatestPollSnapshot(tool: tool)
        let snapshot = latest?.snapshot
        let polledAt = latest?.polledAt
        let stale = StateEngine.isStale(lastPollAt: polledAt, now: now)
        let inputs = StateInputs(
            tool: tool,
            snapshot: snapshot,
            health: .healthy,
            forecast: Forecast(tool: tool, tier: .unknown, runwayMinutes: nil,
                               burnRatePerMin: nil, isEstimate: false, pollCount: 0),
            trigger: .restore,
            now: now)
        let state = StateEngine.classify(inputs, isStale: stale)
        return ToolStatus(tool: tool, snapshot: snapshot, polledAt: polledAt, state: state, isStale: stale)
    }
}
