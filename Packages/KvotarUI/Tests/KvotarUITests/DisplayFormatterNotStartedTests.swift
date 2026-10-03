import XCTest
import KvotarCore
@testable import KvotarUI

/// **A window that has not started has no verdict** (D-123, amending REV-80 / D-101 — STEP_207).
/// The §2.2a row is *removed* on this shape, exactly as D-60 removes it on the low-allowance one,
/// because every branch below the null-window fork answers with a claim about burn and there is
/// nothing to burn yet. What this file pins is the rule and — more important — its **edges**: the
/// three withdrawn forks that look like this shape and are not it, the hero gate, the stale path,
/// and the delta line's boundary form, which must survive the removal.
final class DisplayFormatterNotStartedTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The shape the account actually sends between two five-hour windows: a present window
    /// object, `utilization: 0`, `resets_at: null`, width known.
    private func notStarted(_ tool: Tool = .claude, secondary: Double? = 60) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: 0, primaryResetsAt: nil,
                      primaryWindowSeconds: 18_000,
                      secondaryUsedPct: secondary,
                      secondaryResetsAt: secondary == nil ? nil : now.addingTimeInterval(3 * 86_400),
                      rateLimitReached: false,
                      extraUsage: tool == .claude ? .disabled : nil,
                      source: tool == .claude ? .oauth : .appServerRPC,
                      email: "user@example.com", planType: tool == .claude ? "max" : "plus")
    }

    /// Burn is unresolved on every frame here — the rollover clears the buffer, which is exactly
    /// why the header used to read `Measuring…`.
    private func unresolved(_ tool: Tool = .claude) -> Forecast {
        Forecast(tool: tool, tier: .fullRunway, runwayMinutes: nil, burnRatePerMin: nil,
                 isEstimate: false, pollCount: 1)
    }

    // MARK: The rule

    /// **The live frame this step was written from**, replayed rather than invented: the owner's
    /// Claude tab at 2026-09-15 13:33 local. The five-hour window had rolled over at 13:30 and
    /// `poll_snapshots` holds two polls at `primary_used_pct = 0` with a null `primary_resets_at`
    /// (13:30:33 and 13:32:41) before the new window anchored at 13:34:23. The header read
    /// `100%` / `5-hour quota left` / **`Measuring…`** / `—` / `not started`; it now states the
    /// fact and stops.
    func testTheRolloverFrameStatesTheFactAndStops() {
        let c = DisplayFormatter.claude(state: .healthy, snapshot: notStarted(),
                                        forecast: unresolved(), now: now)
        XCTAssertNil(c.header?.verdict, "no answer about burn on a window that has not begun")
        // Everything the frame legitimately said is still said.
        XCTAssertEqual(c.header?.heroText, "100%")
        XCTAssertEqual(c.header?.limitCaption, "5-hour quota left")
        XCTAssertEqual(c.header?.heroDetails.map(\.text), ["not started"])
        XCTAssertEqual(c.header?.windowScopeLive?.text,
                       "*Not started yet — your first turn starts the clock.*")
        XCTAssertNotNil(c.header?.sourceTag)
        // And the weekly still has its row, so nothing about the account went quiet.
        XCTAssertNotNil(c.otherLimits?.rows.first { $0.id == .secondaryWindow })
    }

    /// The removed row keeps an identity (`verdictFamily`) even though it draws nothing — the
    /// §2.8 delta line reads it, and `unknown` there would silence a render that is not silent.
    func testTheRemovedRowStillNamesItself() {
        let c = DisplayFormatter.claude(state: .healthy, snapshot: notStarted(),
                                        forecast: unresolved(), now: now)
        XCTAssertNil(c.header?.verdict)
        XCTAssertEqual(c.header?.verdictFamily, .notStarted)
        // A drawn row is still its own family — the field defaults to the verdict's.
        let anchored = QuotaSnapshot(tool: .claude, primaryUsedPct: 44,
                                     primaryResetsAt: now.addingTimeInterval(2 * 3600),
                                     primaryWindowSeconds: 18_000,
                                     secondaryUsedPct: nil, secondaryResetsAt: nil,
                                     rateLimitReached: false, extraUsage: .disabled,
                                     source: .oauth, planType: "max")
        let live = DisplayFormatter.claude(state: .healthy, snapshot: anchored,
                                           forecast: unresolved(), now: now)
        XCTAssertEqual(live.header?.verdict?.line1, "Measuring…", "an anchored window still speaks")
        XCTAssertEqual(live.header?.verdictFamily, live.header?.verdict?.family)
    }

    // MARK: The edges — three shapes that look like this one and are not

    /// D-26 (§9.3): local JSONL activity postdating the poll falsifies the not-started claim, so
    /// the window is **withdrawn** and the render is the unknown form. That is a different state
    /// with a different verdict, and it is decided above this rule.
    func testWithdrawnByLocalActivityKeepsTheUnknownRow() {
        let polledAt = now.addingTimeInterval(-120)
        let attribution = LocalAttribution(
            project: "/p", model: nil, surfaceBucket: nil, subagentCount: 0, cacheHitRatio: nil,
            estValue: EstimatedValueEngine.WindowValue(weekly: 0, thirtyDay: 0),
            surfaceShares: [], tokensPerMinute: nil, lastActivityAt: now.addingTimeInterval(-30))
        let c = DisplayFormatter.claude(state: .healthy, snapshot: notStarted(),
                                        forecast: unresolved(), localAttribution: attribution,
                                        pollAsOf: polledAt, now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "—")
        XCTAssertEqual(c.header?.verdict?.family, .unknown)
    }

    /// D-33 (REV-37): a rate-limited freeze over this shape is *reconnecting*, never a removed row.
    func testRateLimitedFreezeKeepsReconnecting() {
        let c = DisplayFormatter.claude(state: .healthy, snapshot: notStarted(),
                                        forecast: unresolved(),
                                        freezeReason: .rateLimited(retryAfter: 120), now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "Reconnecting…")
        XCTAssertEqual(c.header?.verdict?.family, .reconnecting)
    }

    /// D-38 (REV-41): an expired sign-in over this shape names the one action that fixes it.
    func testCredentialExpiredKeepsItsOwnLine() {
        let c = DisplayFormatter.claude(state: .healthy, snapshot: notStarted(),
                                        forecast: unresolved(),
                                        freezeReason: .credentialExpired, now: now)
        XCTAssertEqual(c.header?.verdict?.family, .signInExpired)
    }

    /// **The hero gate.** A weekly that has stopped you owns the header while the five-hour window
    /// sits unanchored underneath — the verdict is about the weekly, and a rule about the
    /// five-hour must not remove it. (The over-quota branch decides this above the rule; the gate
    /// is what keeps that true if the branch order ever moves.)
    func testABlockingWeeklyOverAnUnanchoredPrimaryKeepsItsVerdict() {
        let s = QuotaSnapshot(tool: .claude, primaryUsedPct: 0, primaryResetsAt: nil,
                              primaryWindowSeconds: 18_000,
                              secondaryUsedPct: 100,
                              secondaryResetsAt: now.addingTimeInterval(2 * 86_400),
                              rateLimitReached: true, extraUsage: .disabled, source: .oauth,
                              planType: "max")
        let c = DisplayFormatter.claude(state: .overQuota, snapshot: s,
                                        forecast: unresolved(), now: now)
        XCTAssertNotNil(c.header?.verdict, "the limit that stopped you still speaks")
        XCTAssertTrue(c.header?.verdict?.line1.hasPrefix("Stopped") == true,
                      "got: \(c.header?.verdict?.line1 ?? "nil")")
    }

    /// **The stale path is unchanged.** A restored not-started snapshot arrives as
    /// `idleFallback`, which is decided above this rule and keeps the grey `—`: a stale render
    /// makes no claims, and that includes the claim that a window is waiting for you.
    func testStaleRestoredNotStartedKeepsTheGreyDash() {
        let c = DisplayFormatter.claude(state: .idleFallback, snapshot: notStarted(),
                                        forecast: nil,
                                        staleAsOf: now.addingTimeInterval(-900), now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "—")
        XCTAssertEqual(c.header?.verdict?.family, .idle)
        XCTAssertEqual(c.header?.heroDetails.map(\.text), ["not started"])
    }
}
