import XCTest
import SwiftUI
import AppKit
import KvotarCore
@testable import KvotarUI

/// STEP_160 visual evidence harness (extended STEP_163 with the Explore/Hard-blocks parity
/// states). Renders `HistoryView` states to PNG via `ImageRenderer` —
/// the History window cannot be opened by script (no window until the user clicks the menu
/// item, and UI scripting is blocked by accessibility), so this is the deterministic,
/// repeatable substitute for a `screencapture` of the real window. Layout, copy and theme are
/// exercised; hover, focus and the window lifecycle are validated by hand in the running app.
///
/// Gated: set `KVOTAR_SNAPSHOT_DIR` to write PNGs there. With `KVOTAR_LIVE_DB` also set (a
/// **copy** of the dogfood DB — never the live file), the dense states render from the real
/// corpus; fixture states render either way.
final class HistoryExperienceSnapshots: XCTestCase {

    private var outDir: String? { ProcessInfo.processInfo.environment["KVOTAR_SNAPSHOT_DIR"] }

    /// Renders through a real (offscreen) `NSHostingView` — `ImageRenderer` cannot draw the
    /// AppKit-backed segmented controls or the scroll content, and this window is mostly both.
    @MainActor
    private func snap(_ experience: HistoryExperience, mode: HistoryExperience.Mode,
                      provider: HistoryExperience.Provider = .all,
                      width: CGFloat = 860, height: CGFloat = 640,
                      dark: Bool = false, name: String, dir: String,
                      exploreGrain: ExploreModeView.Grain? = nil,
                      configure: ((HistoryViewModel) -> Void)? = nil) {
        let vm = HistoryViewModel(experience: experience)
        vm.mode = mode
        vm.provider = provider
        // The STEP_183 states that are a *control* rather than a payload: an older recap week,
        // a pinned quota window, an arrival from a recap link.
        configure?(vm)
        let root = HistoryView(viewModel: vm, initialExploreGrain: exploreGrain)
            .frame(width: width, height: height, alignment: .topLeading)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        // Let SwiftUI complete its async layout passes before caching the bitmap.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
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
    func testWriteSnapshots() async throws {
        guard let dir = outDir else {
            throw XCTSkip("set KVOTAR_SNAPSHOT_DIR to write History visual evidence")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Live (dense) states, from the pinned DB copy when supplied.
        if let dbPath = ProcessInfo.processInfo.environment["KVOTAR_LIVE_DB"] {
            let store = try SQLiteStore(path: dbPath)
            var url = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { url.deleteLastPathComponent() }
            let bundle = try XCTUnwrap(Bundle(url: url.appendingPathComponent(
                "Resources", isDirectory: true)))
            let engine = EstimatedValueEngine(store: store, bundle: bundle)
            await engine.loadPricingTable()
            let now = Date()
            let report = await HistoryReportReader(store: store, valueEngine: engine)
                .report(now: now)
            let experience = HistoryDisplay.experience(report, now: now)
            snap(experience, mode: .weeklyRecap, name: "live-recap-860-light", dir: dir)
            snap(experience, mode: .exploreQuota, name: "live-quota-all-860-light", dir: dir)
            snap(experience, mode: .exploreUsage, name: "live-explore-all-860-light", dir: dir)
            snap(experience, mode: .hardBlocks, name: "live-hardblocks-all-860-light", dir: dir)
            // STEP_185: the approved HTML companion is a 1080 × 720 composition. These frames
            // make the direct visual comparison possible without treating its fixture values as
            // production data.
            snap(experience, mode: .weeklyRecap, width: 1080, height: 720,
                 name: "live-recap-1080-light", dir: dir)
            snap(experience, mode: .exploreQuota, width: 1080, height: 720,
                 name: "live-quota-all-1080-light", dir: dir)
            snap(experience, mode: .exploreUsage, width: 1080, height: 720,
                 name: "live-explore-all-1080-light", dir: dir)
            snap(experience, mode: .exploreUsage, width: 1080, height: 720,
                 name: "live-explore-week-1080-light", dir: dir, exploreGrain: .week)
            snap(experience, mode: .exploreUsage, width: 1080, height: 720,
                 name: "live-explore-breakdown-1080-light", dir: dir,
                 exploreGrain: .breakdown)
            snap(experience, mode: .hardBlocks, width: 1080, height: 720,
                 name: "live-hardblocks-all-1080-light", dir: dir)
            snap(experience, mode: .weeklyRecap, dark: true,
                 name: "live-recap-860-dark", dir: dir)
            snap(experience, mode: .exploreQuota, dark: true,
                 name: "live-quota-all-860-dark", dir: dir)
            snap(experience, mode: .exploreUsage, dark: true,
                 name: "live-explore-all-860-dark", dir: dir)
            snap(experience, mode: .weeklyRecap, width: 560, height: 420,
                 name: "live-recap-560-light", dir: dir)
            snap(experience, mode: .exploreQuota, width: 560, height: 420,
                 name: "live-quota-all-560-light", dir: dir)
            snap(experience, mode: .exploreUsage, width: 560, height: 420,
                 name: "live-explore-all-560-light", dir: dir)
            snap(experience, mode: .hardBlocks, dark: true,
                 name: "live-hardblocks-all-860-dark", dir: dir)
            snap(experience, mode: .hardBlocks, width: 560, height: 420,
                 name: "live-hardblocks-all-560-light", dir: dir)
            snap(experience, mode: .exploreQuota, width: 560, height: 420, dark: true,
                 name: "live-quota-all-560-dark", dir: dir)
            snap(experience, mode: .exploreUsage, width: 560, height: 420, dark: true,
                 name: "live-explore-all-560-dark", dir: dir)
            snap(experience, mode: .hardBlocks, width: 560, height: 420, dark: true,
                 name: "live-hardblocks-all-560-dark", dir: dir)
            snap(experience, mode: .exploreUsage, provider: .tool(.claude),
                 name: "live-explore-claude-860-light", dir: dir)
            snap(experience, mode: .exploreUsage, provider: .tool(.codex),
                 name: "live-explore-codex-860-light", dir: dir)
            // Tall renders: the 640-pt window clips the day card's tinted event box and the
            // breakdown tabs, which are exactly what STEP_163 restyled.
            snap(experience, mode: .exploreUsage, provider: .tool(.claude), height: 1400,
                 name: "live-explore-claude-860-tall-light", dir: dir)
            snap(experience, mode: .hardBlocks, provider: .tool(.claude), height: 1000,
                 name: "live-hardblocks-claude-860-tall-light", dir: dir)
            snap(experience, mode: .exploreQuota, provider: .tool(.claude), height: 1400,
                 name: "live-quota-claude-860-tall-light", dir: dir)
            snap(experience, mode: .exploreQuota, provider: .tool(.codex), height: 1400,
                 name: "live-quota-codex-860-tall-light", dir: dir)

            // STEP_228: the whole recap page — headline, table, weekly limits, observations — at
            // the reading width and at the 560-pt minimum, both appearances.
            snap(experience, mode: .weeklyRecap, height: 1700,
                 name: "live-recap-860-tall-light", dir: dir)
            snap(experience, mode: .weeklyRecap, height: 1700, dark: true,
                 name: "live-recap-860-tall-dark", dir: dir)
            snap(experience, mode: .weeklyRecap, width: 560, height: 2000,
                 name: "live-recap-560-tall-light", dir: dir)
            snap(experience, mode: .weeklyRecap, width: 560, height: 2000, dark: true,
                 name: "live-recap-560-tall-dark", dir: dir)
            snap(experience, mode: .weeklyRecap, height: 1800,
                 name: "live-recap-sep7-860-tall-light", dir: dir) { vm in
                vm.showOlderRecapWeek()
                vm.showOlderRecapWeek()
            }

            // STEP_183 control states.
            snap(experience, mode: .weeklyRecap, name: "live-recap-older-week-860-light",
                 dir: dir) { $0.showOlderRecapWeek() }
            snap(experience, mode: .weeklyRecap, width: 560, height: 420,
                 dark: true, name: "live-recap-560-dark", dir: dir)
            snap(experience, mode: .exploreQuota, provider: .tool(.claude), height: 1000,
                 name: "live-quota-claude-pinned-860-light", dir: dir) { vm in
                if let id = vm.experience?.pages(.tool(.claude)).quota
                    .sections.first?.points.last?.id {
                    vm.selectQuotaPoint(id)
                }
            }
            snap(experience, mode: .weeklyRecap, height: 1000,
                 name: "live-quota-scoped-from-recap-860-light", dir: dir) { vm in
                if let link = vm.experience?.recap.weeks.first?.links
                    .first(where: { $0.destination.mode == .exploreQuota }) {
                    vm.navigate(to: link.destination)
                }
            }
            snap(experience, mode: .weeklyRecap, height: 1000,
                 name: "live-blocks-scoped-from-recap-860-light", dir: dir) { vm in
                if let link = vm.experience?.recap.weeks.compactMap({ week in
                    week.links
                        .first { $0.destination.mode == .hardBlocks }
                }).first {
                    vm.navigate(to: link.destination)
                }
            }
        }

        // Fixture edge states (deterministic without any DB).
        let empty = HXFix.experience([HXFix.blank(.claude), HXFix.blank(.codex)])
        snap(empty, mode: .weeklyRecap, name: "fixture-empty-report-860-light", dir: dir)

        let watchedIdle = HXFix.experience([
            HXFix.tool(.claude, weeks: [HXFix.week(daysBack: 0, tokens: 2_200_000),
                                        HXFix.week(daysBack: 7, tokens: 2_000_000)],
                       days: HXFix.days([0, 500_000, 1_000_000])),
            HXFix.blank(.codex, watchingSince: HXFix.now.addingTimeInterval(-12 * 86_400)),
        ])
        snap(watchedIdle, mode: .exploreQuota, provider: .tool(.codex),
             name: "fixture-events-only-quota-860-light", dir: dir)

        let belowFloor = HXFix.experience([
            HXFix.tool(.claude,
                       limitBlocks: [HXFix.localBlock(daysBack: 1, hour: 14),
                                     HXFix.localBlock(daysBack: 3, hour: 15),
                                     HXFix.block(at: HXFix.now.addingTimeInterval(-5 * 86_400),
                                                 lockout: nil)],
                       watchingSince: HXFix.now.addingTimeInterval(-20 * 86_400),
                       days: HXFix.days([0, 500_000, 1_000_000, 200_000]),
                       workByHour: (0..<24).map { $0 >= 12 ? ($0 - 10) * 1_000 : 100 }),
        ])
        snap(belowFloor, mode: .hardBlocks, provider: .tool(.claude),
             name: "fixture-hardblocks-belowfloor-860-light", dir: dir)
        snap(belowFloor, mode: .hardBlocks, provider: .tool(.claude), width: 560, height: 420,
             name: "fixture-hardblocks-belowfloor-560-light", dir: dir)

        // A fresh install has no poll evidence and cannot get any back — the quota mode says so
        // rather than drawing an empty axis.
        snap(empty, mode: .exploreQuota, name: "fixture-quota-fresh-install-860-light", dir: dir)

        // One completed window: the point is still drawn, and the sparse note stands under the
        // factual sentence rather than replacing it.
        let sparse = HXFix.experience([
            HXFix.tool(.claude, days: HXFix.days([0, 400_000, 900_000]),
                       quotaWindows: [HXFix.quotaWindow(.claude, daysBack: 1, used: 74)]),
        ])
        snap(sparse, mode: .exploreQuota, provider: .tool(.claude),
             name: "fixture-quota-sparse-860-light", dir: dir)

        // Every shape at once: ended, partial, open now and hit the limit, across a width change.
        let shapes = HXFix.experience([
            HXFix.tool(.claude, days: HXFix.days([0, 400_000, 900_000, 1_200_000]),
                       quotaWindows: [
                        HXFix.quotaWindow(.claude, daysBack: 6, used: 51),
                        HXFix.quotaWindow(.claude, daysBack: 5, used: 88,
                                          lastSeenBefore: 4_000,
                                          completion: .completedPartial),
                        HXFix.quotaWindow(.claude, daysBack: 4, used: 100, hitLimit: true),
                        HXFix.quotaWindow(.claude, daysBack: 2, width: 604_800, used: 39),
                        HXFix.quotaWindow(.claude, daysBack: 0, hour: 20, width: 604_800,
                                          used: 12, completion: .current),
                       ]),
        ])
        snap(shapes, mode: .exploreQuota, provider: .tool(.claude), height: 900,
             name: "fixture-quota-every-shape-860-light", dir: dir)
        snap(shapes, mode: .exploreQuota, provider: .tool(.claude), height: 900, dark: true,
             name: "fixture-quota-every-shape-860-dark", dir: dir)
    }
}
