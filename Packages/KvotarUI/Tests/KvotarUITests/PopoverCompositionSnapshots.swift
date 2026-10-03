import XCTest
import SwiftUI
import AppKit
import KvotarCore
@testable import KvotarUI

/// STEP_178 visual evidence harness, extended through STEP_184's readability matrix. Modelled on `HistoryExperienceSnapshots`. Renders
/// `PopoverView` at its native 340 pt through an offscreen `NSHostingView` so the REV-94
/// state matrix can be looked at without driving the real popover — which cannot be opened by
/// script (no window until the user clicks the status item, and UI scripting is blocked by
/// accessibility).
///
/// Gated: set `KVOTAR_SNAPSHOT_DIR` to write PNGs there. These are **fixtures**, not live
/// evidence: an offscreen `NSHostingView` is not the shipped popover. Most legacy states remain
/// static stubs; the REV-94 precision/warning cases above run through the real formatter. The
/// live look on a real account remains a separate pass.
final class PopoverCompositionSnapshots: XCTestCase {

    private var outDir: String? { ProcessInfo.processInfo.environment["KVOTAR_SNAPSHOT_DIR"] }
    private let fixtureNow = Date(timeIntervalSince1970: 1_789_000_000)

    private func rev94FableState() -> ClaudeDisplayState {
        let fable = AdditionalRateLimit(
            id: "fable", name: "Fable", usedPercent: 97,
            resetsAt: fixtureNow.addingTimeInterval(5 * 86_400),
            primaryWindowSeconds: 604_800)
        let snapshot = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 45,
            primaryResetsAt: fixtureNow.addingTimeInterval(2 * 3600),
            primaryWindowSeconds: 18_000, secondaryUsedPct: 20,
            secondaryResetsAt: fixtureNow.addingTimeInterval(5 * 86_400),
            rateLimitReached: false, extraUsage: .disabled,
            additionalRateLimits: [fable], source: .oauth, planType: "pro")
        let forecast = Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 400,
                                burnRatePerMin: 0.04, isEstimate: false, pollCount: 10)
        return DisplayFormatter.claude(
            state: .healthy, snapshot: snapshot, forecast: forecast,
            offMachine: WindowAttribution(offMachinePct: 0.4, localPct: 44.6,
                                          unattributedPct: 0, totalUsedPct: 45),
            pollAsOf: fixtureNow.addingTimeInterval(-35), now: fixtureNow)
    }

    private func rev94VeryLowBurnState() -> CodexDisplayState {
        let snapshot = QuotaSnapshot(
            tool: .codex, primaryUsedPct: 25,
            primaryResetsAt: fixtureNow.addingTimeInterval(2 * 3600),
            primaryWindowSeconds: 18_000, secondaryUsedPct: 15,
            secondaryResetsAt: fixtureNow.addingTimeInterval(5 * 86_400),
            rateLimitReached: false, source: .appServerRPC, planType: "plus")
        let forecast = Forecast(tool: .codex, tier: .fullRunway, runwayMinutes: 7_500,
                                burnRatePerMin: 0.01, isEstimate: false, pollCount: 10)
        return DisplayFormatter.codex(state: .healthy, snapshot: snapshot, forecast: forecast,
                                      pollAsOf: fixtureNow.addingTimeInterval(-35), now: fixtureNow)
    }

    private func rev94SparkState() -> CodexDisplayState {
        let spark = AdditionalRateLimit(
            id: "spark", name: "GPT-5.3-Codex-Spark", usedPercent: 0,
            resetsAt: fixtureNow.addingTimeInterval(2 * 3600),
            primaryWindowSeconds: 18_000,
            secondary: .init(usedPercent: 97,
                             resetsAt: fixtureNow.addingTimeInterval(5 * 86_400),
                             windowSeconds: 604_800))
        let snapshot = QuotaSnapshot(
            tool: .codex, primaryUsedPct: 2,
            primaryResetsAt: fixtureNow.addingTimeInterval(5 * 86_400),
            primaryWindowSeconds: 604_800, secondaryUsedPct: nil,
            secondaryResetsAt: nil, rateLimitReached: false,
            additionalRateLimits: [spark], source: .appServerRPC, planType: "pro")
        let forecast = Forecast(tool: .codex, tier: .fullRunway, runwayMinutes: 1_000,
                                burnRatePerMin: 0.005, isEstimate: false, pollCount: 10)
        return DisplayFormatter.codex(state: .healthy, snapshot: snapshot, forecast: forecast,
                                      pollAsOf: fixtureNow.addingTimeInterval(-35), now: fixtureNow)
    }

    /// STEP_197 — a two-app Codex day: the rows under the summary they belong to.
    private func step197SurfacesState() -> CodexDisplayState {
        let base = rev94SparkState()
        return CodexDisplayState(
            dot: base.dot, phase: .content, header: base.header,
            windowGrain: base.windowGrain, otherLimits: base.otherLimits,
            localActivity: Stub.local(tool: .codex, tokens: "14.4M", sessions: "4 threads",
                                      surfaces: [
                                          .init(name: "Desktop", tokens: "9.9M",
                                                isMostRecent: false),
                                          .init(name: "CLI", tokens: "4.5M", isMostRecent: true),
                                      ],
                                      moreCount: 0))
    }

    /// STEP_197 — the same day carrying an unmapped originator: `Unknown app` stays visible, so
    /// the rows still account for the summary above them.
    private func step197UnknownSurfaceState() -> CodexDisplayState {
        let base = rev94SparkState()
        return CodexDisplayState(
            dot: base.dot, phase: .content, header: base.header,
            windowGrain: base.windowGrain, otherLimits: base.otherLimits,
            localActivity: Stub.local(tool: .codex, tokens: "14.4M", sessions: "4 threads",
                                      surfaces: [
                                          .init(name: "Desktop", tokens: "9.9M",
                                                isMostRecent: false),
                                          .init(name: "Unknown app", tokens: "4.3M",
                                                isMostRecent: false),
                                          .init(name: "CLI", tokens: "210k",
                                                isMostRecent: true),
                                      ],
                                      moreCount: 0))
    }

    private func rev94LongContentState() -> CodexDisplayState {
        let base = rev94SparkState()
        let project = LocalActivitySection.ProjectRow(
            name: "a-very-long-project-name-that-must-wrap-without-overlap",
            fullName: "/Users/example/a-very-long-project-name-that-must-wrap-without-overlap",
            tokens: "1.2M", isMostRecent: true,
            models: [
                .init(name: "gpt-5.5-with-a-long-provider-suffix", tokens: "900k"),
                .init(name: "gpt-5.3-codex-spark", tokens: "300k"),
            ])
        return CodexDisplayState(
            dot: base.dot, phase: .content, header: base.header,
            windowGrain: base.windowGrain, otherLimits: base.otherLimits,
            localActivity: Stub.local(tool: .codex, tokens: "1.2M", sessions: "12 threads",
                                      projects: [project], moreCount: 0))
    }

    @MainActor
    private func snap(_ model: AppViewModel, name: String, dir: String, dark: Bool = false,
                      maxHeight: CGFloat? = nil) {
        // STEP_179: `nil` is the unbounded path this harness has always rendered — the popover
        // hugs its content. A value stands in for a screen too short to show it all, so the
        // constrained viewport can be looked at without a second display.
        model.popoverMaxHeight = maxHeight
        let hosting = NSHostingView(rootView: PopoverView().environmentObject(model))
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 900)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        // Let SwiftUI complete its async layout passes before caching the bitmap.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        let size = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: max(size.height, 200))
        window.setContentSize(hosting.frame.size)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("no bitmap rep for \(name)")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("render failed for \(name)")
            return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? png.write(to: url)
        window.contentView = nil
        print("[snapshot] \(url.path) (\(png.count) bytes)")
    }

    @MainActor
    func testWriteCompositionSnapshots() async throws {
        guard let dir = outDir else {
            throw XCTSkip("set KVOTAR_SNAPSHOT_DIR to write popover composition evidence")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // The REV-92 §7 matrix, in the shapes the stubs cover.
        let claude: [(String, ClaudeDisplayState)] = [
            ("claude-healthy", .healthy),
            ("claude-elevated", .elevated),
            // The rank-10 frame moved to `testWriteLongLimitSnapshots`, where it is built from a
            // real snapshot through the real formatter. Left here it wrote the same two filenames
            // from a stub and whichever test ran last silently won.
            ("claude-over-quota-credits", .overQuotaCreditsActive),
            ("claude-null-window", .nullWindow),
            ("claude-stale", .stale),
            ("claude-ent-monthly", .entMonthly),
            ("claude-ent-monthly-reached", .entMonthlyReached),
            // The STEP_180 acceptance shapes (REV-92 §7): a Team seat under pressure, the
            // no-five-hour weekly+monthly account, a critical weekly over a healthy primary, and
            // local activity in each of its three non-populated forms.
            ("claude-team-urgent", .teamUrgent),
            ("claude-weekly-hero-monthly", .weeklyHeroWithMonthly),
            ("claude-critical-weekly-healthy-primary", .criticalWeeklyHealthyPrimary),
            ("claude-local-loading", .localLoading),
            ("claude-local-unavailable", .localUnavailable),
            ("claude-local-retained", .localRetained),
            ("rev94-claude-fable-warning", rev94FableState()),
        ]
        for (name, state) in claude {
            for dark in [false, true] {
                snap(AppViewModel.previewModel(claude: state, activeTab: .claude),
                     name: name + (dark ? "-dark" : "-light"), dir: dir, dark: dark)
            }
        }

        let codex: [(String, CodexDisplayState)] = [
            ("codex-healthy-spark", .healthy),
            ("codex-spark-scoped-warning", .scopedModelWarning),
            ("codex-monthly-credits", .cxMonthly),
            ("codex-low-allowance", .cxLowAllowance),
            ("codex-null-window", .nullWindow),
            ("rev94-codex-very-low-burn", rev94VeryLowBurnState()),
            ("rev94-codex-main-weekly-spark", rev94SparkState()),
            ("rev94-codex-long-content", rev94LongContentState()),
            ("step197-codex-surfaces", step197SurfacesState()),
            ("step197-codex-surfaces-unknown", step197UnknownSurfaceState()),
        ]
        for (name, state) in codex {
            for dark in [false, true] {
                snap(AppViewModel.previewModel(codex: state, activeTab: .codex),
                     name: name + (dark ? "-dark" : "-light"), dir: dir, dark: dark)
            }
        }
    }

    /// The REV-96 §3.11 frames (STEP_195), each rendered through the **real formatter** from
    /// `LongLimitFixtures` rather than from a stub — the strip, the tier suffixes, the lifted row
    /// and the greyed blocked rows are what the shipped code produces for those snapshots.
    /// Amber and red cannot be reached on the owner's own account, so these frames are the only
    /// way to look at them until a tester bundle carries one.
    @MainActor
    func testWriteLongLimitSnapshots() async throws {
        guard let dir = outDir else {
            throw XCTSkip("set KVOTAR_SNAPSHOT_DIR to write long-limit evidence")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for fixture in LongLimitFixture.all + LongLimitFixture.teamCredits {
            for dark in [false, true] {
                let model = fixture.tool == .claude
                    ? AppViewModel.previewModel(claude: fixture.claude, activeTab: .claude)
                    : AppViewModel.previewModel(codex: fixture.codex, activeTab: .codex)
                snap(model, name: fixture.name + (dark ? "-dark" : "-light"), dir: dir, dark: dark)
            }
        }
    }

    /// **The not-started header (STEP_207 — D-123).** The one frame the live app cannot be made
    /// to show: the shape lasts a poll or two at a five-hour rollover and cannot be summoned. It
    /// is built here from the owner's own 2026-09-15 13:30 polls — `utilization: 0`,
    /// `resets_at: null`, width 18 000 s, the weekly at 60 % — through the real formatter, so the
    /// removed verdict row and the `not started` line under the hero are what the shipped code
    /// produces. Both tools, because D-101 makes it one shape.
    @MainActor
    func testWriteNotStartedSnapshots() async throws {
        guard let dir = outDir else {
            throw XCTSkip("set KVOTAR_SNAPSHOT_DIR to write the not-started evidence")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func rolled(_ tool: Tool) -> QuotaSnapshot {
            QuotaSnapshot(tool: tool, primaryUsedPct: 0, primaryResetsAt: nil,
                          primaryWindowSeconds: 18_000, secondaryUsedPct: 60,
                          secondaryResetsAt: fixtureNow.addingTimeInterval(3 * 86_400),
                          rateLimitReached: false,
                          extraUsage: tool == .claude ? .disabled : nil,
                          source: tool == .claude ? .oauth : .appServerRPC,
                          email: "user@example.com",
                          planType: tool == .claude ? "max" : "plus")
        }
        func unresolved(_ tool: Tool) -> Forecast {
            // The rollover cleared the buffer — the state in which the header used to say
            // `Measuring…`.
            Forecast(tool: tool, tier: .fullRunway, runwayMinutes: nil, burnRatePerMin: nil,
                     isEstimate: false, pollCount: 1)
        }
        let claude = DisplayFormatter.claude(state: .healthy, snapshot: rolled(.claude),
                                             forecast: unresolved(.claude),
                                             pollAsOf: fixtureNow.addingTimeInterval(-44),
                                             now: fixtureNow)
        let codex = DisplayFormatter.codex(state: .healthy, snapshot: rolled(.codex),
                                           forecast: unresolved(.codex),
                                           pollAsOf: fixtureNow.addingTimeInterval(-44),
                                           now: fixtureNow)
        XCTAssertNil(claude.header?.verdict, "the frame being photographed is the removed row")
        XCTAssertNil(codex.header?.verdict)
        for dark in [false, true] {
            let suffix = dark ? "-dark" : "-light"
            snap(AppViewModel.previewModel(claude: claude, activeTab: .claude),
                 name: "step207-claude-not-started\(suffix)", dir: dir, dark: dark)
            snap(AppViewModel.previewModel(codex: codex, activeTab: .codex),
                 name: "step207-codex-not-started\(suffix)", dir: dir, dark: dark)
        }
    }

    /// The constrained viewport (STEP_179): the same states under a height budget a short screen
    /// would give them. The long one is capped and scrolls, the short one still hugs — the
    /// difference between the two files is the whole rule.
    @MainActor
    func testWriteConstrainedViewportSnapshots() async throws {
        guard let dir = outDir else {
            throw XCTSkip("set KVOTAR_SNAPSHOT_DIR to write popover viewport evidence")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        for dark in [false, true] {
            let suffix = dark ? "-dark" : "-light"
            // A long state on a screen too short for it: capped, and the body scrolls.
            snap(AppViewModel.previewModel(claude: .healthy, activeTab: .claude),
                 name: "viewport-claude-capped\(suffix)", dir: dir, dark: dark, maxHeight: 420)
            // A short state with room to spare: it hugs, and the budget is not spent.
            snap(AppViewModel.previewModel(claude: .nullWindow, activeTab: .claude),
                 name: "viewport-claude-hugs\(suffix)", dir: dir, dark: dark, maxHeight: 700)
        }
    }
}
