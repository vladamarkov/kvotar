import XCTest
import SwiftUI
import AppKit
import KvotarCore
@testable import KvotarUI

/// Visual evidence: every §3.8 fixture, in **both phases**, both display modes, light and dark
/// (STEP_199), now drawing **variant D** in the reminder phase and one crossfade midpoint per
/// reminding fixture (STEP_203). Modelled on `PopoverCompositionSnapshots` — an offscreen
/// `NSHostingView` renders the same `MenuBarItemView` the live `NSStatusItem` hosts.
///
/// Gated: set `KVOTAR_SNAPSHOT_DIR` to write PNGs there.
///
/// **Amber and red are still unreachable on the owner's account**, so these frames plus the
/// `KVOTAR_MENU_BAR_FIXTURE` override are the only two ways to look at the reminder at all. What
/// a still cannot show is *timing* — the pulse, and how 350 ms feels; the colour, the strings, the
/// fitted headline, the hidden peer row and the reserved width it can.
@MainActor
final class MenuBarSnapshots: XCTestCase {

    private var outDir: String? { ProcessInfo.processInfo.environment["KVOTAR_SNAPSHOT_DIR"] }

    private var calmCodex: ToolMenuBarDisplay {
        ToolMenuBarDisplay(prefix: "CX", dot: .green, percentText: "58%", timeSlot: "↻2h04m")
    }

    private var calmClaude: ToolMenuBarDisplay {
        ToolMenuBarDisplay(prefix: "CL", dot: .green, percentText: "62%", timeSlot: "↻1h52m")
    }

    /// One fixture's two modes. The other tool is calm on purpose: a reminder must leave it alone,
    /// and a frame where both rows move would not show that.
    private func modes(_ fixture: LongLimitFixture) -> [(String, MenuBarRender)] {
        let menu = fixture.menuBar
        let stacked = DisplayFormatter.menuBarRender(
            mode: .bothStacked,
            claude: fixture.tool == .claude ? menu : calmClaude,
            codex: fixture.tool == .codex ? menu : calmCodex)
        let single = DisplayFormatter.menuBarRender(
            mode: fixture.tool == .claude ? .claudeOnly : .codexOnly,
            claude: fixture.tool == .claude ? menu : nil,
            codex: fixture.tool == .codex ? menu : nil)
        return [("stacked", stacked), ("single", single)]
    }

    /// The row index the fixture's tool occupies, so a phase lands where it belongs.
    private func lineIndex(_ fixture: LongLimitFixture, mode: String) -> Int {
        mode == "single" ? 0 : (fixture.tool == .claude ? 0 : 1)
    }

    /// The status item on a menu-bar-coloured strip, at the reserved width, with a neighbour to
    /// its right — so a frame that moved between phases would be visible as the gap changing.
    private func snap<Item: View>(_ item: Item, reservedWidth: CGFloat, name: String, dir: String,
                                  dark: Bool) {
        let strip = HStack(spacing: 0) {
            item
                .frame(width: reservedWidth, alignment: .leading)
            // A stand-in for the system clock: the item to the right of ours is what a reader
            // would see shift if the width were re-measured at a phase edge.
            Text("18:42")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 8)
        }
        .frame(height: 24)
        .padding(.horizontal, 6)
        .background(.bar)

        let hosting = NSHostingView(rootView: strip)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
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

    func testWriteMenuBarPhaseSnapshots() async throws {
        guard let dir = outDir else {
            throw XCTSkip("set KVOTAR_SNAPSHOT_DIR to write menu-bar phase evidence")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        for fixture in LongLimitFixture.all + [.claudeFiveHourOutranksTheWeekly] {
            for (mode, render) in modes(fixture) {
                // One reservation per render, computed exactly as the controller computes it —
                // through the `.measuring` layout, which is the rule variant D's fitted headline
                // depends on: a thing fitted to a measurement is not one of the things measured.
                let reserved = MenuBarWidth.phaseRenders(render)
                    .map { ceil(NSHostingView(rootView: MenuBarItemView(render: $0)).fittingSize.width) }
                    .max() ?? 0
                let row = lineIndex(fixture, mode: mode)
                var phases: [(String, MenuBarRender)] = [("steady", render)]
                for j in render.lines[row].reminders.indices {
                    phases.append(("reminder\(j + 1)", render.showingReminder(j, on: row)))
                }
                for (phase, framed) in phases {
                    for dark in [false, true] {
                        snap(MenuBarItemView(render: framed, layout: .drawing(width: reserved)),
                             reservedWidth: reserved,
                             name: "\(fixture.name)-\(mode)-\(phase)\(dark ? "-dark" : "-light")",
                             dir: dir, dark: dark)
                    }
                }
                // The §2.4a crossfade, stopped halfway. Composed from the two layers the shipped
                // view composes, at the opacities the 350 ms animation passes through — the only
                // thing a still can say about a transition, and the one that matters: **both**
                // layers live inside the width reserved before the fade started, so nothing moves
                // and nothing resizes while the item is showing two things at once.
                guard phases.count > 1 else { continue }
                for dark in [false, true] {
                    let midpoint = ZStack(alignment: .leading) {
                        MenuBarLayers(render: phases[0].1, headlineWidth: reserved,
                                      motion: .frozen).opacity(0.5)
                        MenuBarLayers(render: phases[1].1, headlineWidth: reserved,
                                      motion: .frozen).opacity(0.5)
                    }
                    snap(midpoint, reservedWidth: reserved,
                         name: "\(fixture.name)-\(mode)-crossfade-mid\(dark ? "-dark" : "-light")",
                         dir: dir, dark: dark)
                }
            }
        }
    }
}
