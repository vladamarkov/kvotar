import Foundation
import KvotarCore

/// Diagnostics only (STEP_233): `KVOTAR_NOTIFICATION_FIXTURE=<name>` plays one scripted weekly
/// through the notification path of a Debug build, so the ladder's notices can be seen as real
/// banners. A real step needs a real week — the owner's account stands on one rung at a time,
/// and has never reached the red line — so without this the delivered copy could only ever be
/// read in a test.
///
/// **Nothing here touches the real account or the database.** The frames run through a
/// throwaway `NotificationEngine` with **no store**: its keys live in memory for the length of
/// the script, no `notification_events` row and no `ladder.*` / `nearly_spent.*` key is
/// written, and the engine the poll loop drives never sees a frame. Only the presenter is the
/// real one, which is the point. Read once at launch, never persisted, never surfaced — the
/// `KVOTAR_MENU_BAR_FIXTURE` precedent, which does the same for the status item.
enum NotificationFixture: String, CaseIterable {
    /// A weekly behind a five-hour window, off pace: `half`, then `quarter` on the same
    /// instance, then the same reading again, which sends nothing.
    case ladderSteps = "ladder-steps"
    /// A weekly-only account whose first reading is 92 % used: nearly spent alone, once, with
    /// no early step before or after it.
    case weeklyOnlyNearlySpent = "weekly-only-nearly-spent"
    /// A weekly-only account crossing 85 % used on pace: the state turns to Bad timing and
    /// nearly spent is sent with it, in place of event 2 (STEP_238 — it used to send nothing
    /// until 90 %).
    case weeklyOnlyBadTiming = "weekly-only-bad-timing"

    static let environmentKey = "KVOTAR_NOTIFICATION_FIXTURE"

    static var fromEnvironment: NotificationFixture? {
        ProcessInfo.processInfo.environment[environmentKey].flatMap(NotificationFixture.init)
    }

    /// One poll's worth of input: the reading, the state it classifies as, and the state before
    /// it where the frame is a transition (`nil` ⇒ no state change, as on a first evaluation).
    struct Frame {
        let snapshot: QuotaSnapshot
        let state: AppState
        let previous: AppState?
    }

    func frames(now: Date) -> [Frame] {
        let week = TimeInterval(QuotaSnapshot.weeklyPrimarySeconds)
        switch self {
        case .ladderSteps:
            let reset = now.addingTimeInterval(week * 0.6)
            let reading = { (used: Double) in
                Frame(snapshot: QuotaSnapshot(
                          tool: .claude, primaryUsedPct: 20,
                          primaryResetsAt: now.addingTimeInterval(3600),
                          primaryWindowSeconds: 18_000,
                          secondaryUsedPct: used, secondaryResetsAt: reset,
                          rateLimitReached: false, extraUsage: .disabled),
                      state: .healthy, previous: nil)
            }
            return [reading(55), reading(78), reading(78)]
        case .weeklyOnlyNearlySpent:
            let first = Frame(snapshot: Self.weeklyOnly(used: 92, elapsed: 0.6, now: now),
                              state: .badTiming, previous: nil)
            return [first, first]
        case .weeklyOnlyBadTiming:
            return [
                Frame(snapshot: Self.weeklyOnly(used: 70, elapsed: 0.8, now: now),
                      state: .healthy, previous: nil),
                Frame(snapshot: Self.weeklyOnly(used: 85, elapsed: 0.8, now: now),
                      state: .badTiming, previous: .healthy),
            ]
        }
    }

    /// The owner's shape: Codex Pro, one seven-day window and nothing else.
    private static func weeklyOnly(used: Double, elapsed: Double, now: Date) -> QuotaSnapshot {
        let week = TimeInterval(QuotaSnapshot.weeklyPrimarySeconds)
        return QuotaSnapshot(
            tool: .codex, primaryUsedPct: used,
            primaryResetsAt: now.addingTimeInterval(week * (1 - elapsed)),
            primaryWindowSeconds: QuotaSnapshot.weeklyPrimarySeconds,
            secondaryUsedPct: nil, secondaryResetsAt: nil,
            rateLimitReached: false, extraUsage: .disabled, planType: "pro")
    }

    /// Plays the frames `spacing` seconds apart, each as the cycle `PollCoordinator` runs after
    /// a fresh poll: the state change, where the frame is one, and the poll signal together.
    func play(presenter: NotificationPresenter, startDelay: TimeInterval = 10,
              spacing: TimeInterval = 20, now: Date = Date()) async {
        let engine = NotificationEngine(store: nil, presenter: presenter)
        let frames = frames(now: now)
        try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
        for (index, frame) in frames.enumerated() {
            if index > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
            let s = frame.snapshot
            Logger.info("Notification fixture", component: .notificationEngine,
                        metadata: ["name": rawValue, "frame": "\(index + 1)/\(frames.count)",
                                   "tool": s.tool.rawValue, "state": frame.state.rawValue])
            let change = frame.previous.map {
                StateChange(tool: s.tool, previous: $0, new: frame.state,
                            utilizationPct: s.primaryUsedPct, resetsAt: s.primaryResetsAt,
                            primaryWindowSeconds: s.primaryWindowSeconds,
                            isLowAllowanceShape: s.isLowAllowanceShape,
                            blockEpisode: s.blockEpisode, longLimit: s.longLimit(now: now))
            }
            let signal = NotificationSignal(
                tool: s.tool, state: frame.state, utilizationPct: s.primaryUsedPct,
                runwayMinutes: nil, resetsAt: s.primaryResetsAt,
                primaryWindowSeconds: s.primaryWindowSeconds,
                isLowAllowanceShape: s.isLowAllowanceShape,
                blockEpisode: s.blockEpisode, longLimit: s.longLimit(now: now),
                weekly: s.weeklyForNotifications(now: now), now: now)
            await engine.evaluateCycle(change: change, signal: signal, now: now)
        }
    }
}
