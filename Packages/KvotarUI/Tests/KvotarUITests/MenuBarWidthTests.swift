import XCTest
import SwiftUI
import AppKit
import KvotarCore
@testable import KvotarUI

/// **The item does not move at a phase edge** (UI Spec §1.0 / REV-97 §2.6 — STEP_199).
///
/// Measured, not argued: every render goes through a real `NSHostingView` at the shipped metrics,
/// the same way `MenuBarController` measures the live status item. A rule asserted only on strings
/// would miss the thing that actually moves a menu bar — the laid-out row.
@MainActor
final class MenuBarWidthTests: XCTestCase {

    private func width(_ render: MenuBarRender) -> CGFloat {
        let hosting = NSHostingView(rootView: MenuBarItemView(render: render))
        return ceil(hosting.fittingSize.width)
    }

    /// What `MenuBarController.reservedWidth` computes, through the same two rules.
    private func reserved(_ render: MenuBarRender) -> CGFloat {
        MenuBarWidth.phaseRenders(render).map(width).max() ?? 0
    }

    private var calmCodex: ToolMenuBarDisplay {
        ToolMenuBarDisplay(prefix: "CX", dot: .green, percentText: "58%", timeSlot: "↻2h04m")
    }

    /// Every fixture, in both the stacked and the single-tool shape, with every phase it can show.
    private func renders(_ fixture: LongLimitFixture) -> [(String, MenuBarRender)] {
        let menu = fixture.menuBar
        let stacked = fixture.tool == .claude
            ? DisplayFormatter.menuBarRender(mode: .bothStacked, claude: menu, codex: calmCodex)
            : DisplayFormatter.menuBarRender(mode: .bothStacked,
                                             claude: ToolMenuBarDisplay(prefix: "CL", dot: .green,
                                                                        percentText: "62%",
                                                                        timeSlot: "↻1h52m"),
                                             codex: menu)
        let single = DisplayFormatter.menuBarRender(
            mode: fixture.tool == .claude ? .claudeOnly : .codexOnly,
            claude: fixture.tool == .claude ? menu : nil,
            codex: fixture.tool == .codex ? menu : nil)
        return [("\(fixture.name)/stacked", stacked), ("\(fixture.name)/single", single)]
    }

    // MARK: The reservation does not move

    /// The contract's own assertion: the length the controller would set is **identical** at every
    /// phase of a render, because it is computed from the steady form and the steady form is what
    /// a phase edge leaves alone.
    func testTheReservedWidthIsIdenticalAcrossAPhaseEdge() {
        for fixture in LongLimitFixture.all + [.claudeFiveHourOutranksTheWeekly] {
            for (name, render) in renders(fixture) {
                let atEntry = reserved(render)
                for candidate in MenuBarWidth.phaseRenders(render) {
                    XCTAssertEqual(reserved(candidate), atEntry, "\(name)")
                    XCTAssertEqual(MenuBarWidth.steadyForm(candidate),
                                   MenuBarWidth.steadyForm(render), "\(name)")
                }
            }
        }
    }

    /// And the reservation is big enough: no phase the row can reach draws wider than the width
    /// reserved for it. A reservation that were merely stable but too small would clip.
    func testEveryPhaseFitsInsideTheReservedWidth() {
        for fixture in LongLimitFixture.all + [.claudeFiveHourOutranksTheWeekly] {
            for (name, render) in renders(fixture) {
                let reservation = reserved(render)
                for candidate in MenuBarWidth.phaseRenders(render) {
                    XCTAssertLessThanOrEqual(width(candidate), reservation, "\(name)")
                }
            }
        }
    }

    /// **The reminder costs the bar nothing at all any more** (REV-98 §2.4 — STEP_203).
    ///
    /// It used to cost a few points and the §2.7 compact reset was what kept it there. Variant D
    /// dropped the reset from the reminder entirely — the headline is provider, limit and
    /// remaining percent, and the reset moved to the popover — so every reminder is now *narrower*
    /// than the steady string it replaces and the reservation is exactly the steady width. That is
    /// the strongest form this rule can take: entering a warning tier does not move the item by a
    /// point, in either direction.
    ///
    /// The slack it leaves is not waste: it is what the headline grows into (§2.4), which the fit
    /// test below measures.
    func testTheReminderIsNarrowerThanTheStringItReplacesAndReservesNothingExtra() {
        var checked = 0
        for fixture in LongLimitFixture.all where !fixture.menuBar.reminders.isEmpty {
            for (name, render) in renders(fixture) {
                let steady = width(MenuBarWidth.steadyForm(render))
                XCTAssertEqual(reserved(render), steady, "\(name): the reminder reserved extra")
                for candidate in MenuBarWidth.phaseRenders(render) {
                    XCTAssertLessThanOrEqual(width(candidate), steady, "\(name)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    // MARK: Variant D's headline fits inside it

    /// **The headline never widens the item** (§2.4), measured rather than argued.
    ///
    /// It is laid out at `headlineMaxSize` and allowed to scale down to its display mode's own
    /// row size and no further. The assertion is on the scale the reserved width actually forces:
    /// it must stay at or above that floor, because below it the string would be *truncated* —
    /// a reminder that cannot be read is worse than no reminder — and it must not exceed 13 pt,
    /// which is what stops a short reminder on a wide bar rendering at poster scale.
    func testTheHeadlineFitsInsideTheReservedWidthAtNoSmallerThanTheRowItReplaces() {
        for fixture in LongLimitFixture.all where !fixture.menuBar.reminders.isEmpty {
            for (name, render) in renders(fixture) {
                let available = reserved(render) - itemHorizontalPadding
                let base: CGFloat = render.lines.count == 1 ? 11 : 9
                for candidate in MenuBarWidth.phaseRenders(render) {
                    guard let i = candidate.lines.firstIndex(where: { $0.reminderIndex != nil })
                    else { continue }
                    let intrinsic = headlineWidth(candidate.lines[i])
                    let size = min(MenuBarReminder.headlineMaxSize,
                                   MenuBarReminder.headlineMaxSize * available / intrinsic)
                    XCTAssertGreaterThanOrEqual(size, base,
                        "\(name): the headline would scale to \(size)pt, under the \(base)pt row")
                    XCTAssertLessThanOrEqual(size, MenuBarReminder.headlineMaxSize, "\(name)")
                }
            }
        }
    }

    /// The item's own horizontal padding, which the headline's box does not get.
    private let itemHorizontalPadding: CGFloat = 8

    /// Variant D's headline laid out on its own at full size — how wide it *wants* to be, which
    /// is what the reserved width then scales.
    private func headlineWidth(_ line: MenuBarRender.TextLine) -> CGFloat {
        let view = MenuBarLineView(line: line, size: MenuBarReminder.headlineMaxSize,
                                   dotDiameter: 6)
        return ceil(NSHostingView(rootView: view).fittingSize.width)
    }

    // MARK: The candidate list

    /// One candidate per phase the render can show, steady included — and a render with nothing to
    /// remind about has exactly one, which is the proof that an ordinary menu bar measures exactly
    /// as it always did.
    func testTheCandidateListIsEveryPhaseAndNothingMore() {
        let calm = DisplayFormatter.menuBarRender(mode: .bothStacked,
                                                  claude: ToolMenuBarDisplay(prefix: "CL",
                                                                             dot: .green,
                                                                             percentText: "62%",
                                                                             timeSlot: "↻1h52m"),
                                                  codex: calmCodex)
        XCTAssertEqual(MenuBarWidth.phaseRenders(calm), [calm])

        // Built by hand: since REV-100 §2.1 (STEP_210) the only fixture with two warnings holds a
        // red monthly and reminds about nothing, and it gets its own assertion below.
        let calmLine = DisplayFormatter.menuBarRender(mode: .codexOnly, claude: nil,
                                                      codex: calmCodex).lines[0]
        let two = MenuBarRender(lines: [
            MenuBarRender.TextLine(steady: "CL 71% ↻3h46m",
                                   reminders: ["CL ⚠mo 38%", "CL ⚠wk 30%"], dot: .amber),
            calmLine,
        ])
        let candidates = MenuBarWidth.phaseRenders(two)
        XCTAssertEqual(candidates.count, 3)   // steady + two reminders on one row
        XCTAssertEqual(candidates.map { $0.lines[0].text },
                       [two.lines[0].steady] + two.lines[0].reminders)
        // The other row is the same in all three.
        XCTAssertTrue(candidates.allSatisfy { $0.lines[1] == two.lines[1] })

        // Red holds: its held string is the steady form and there is nothing else to reserve.
        let red = DisplayFormatter.menuBarRender(
            mode: .bothStacked, claude: LongLimitFixture.claudeBothLimitsWarning.menuBar,
            codex: calmCodex)
        XCTAssertEqual(MenuBarWidth.phaseRenders(red), [red])
    }

    /// `steadyForm` returns the render untouched when nothing is showing a reminder — the
    /// controller compares it on every render, so it must not allocate a new value per poll.
    func testSteadyFormIsIdentityOnASteadyRender() {
        let calm = DisplayFormatter.menuBarRender(mode: .claudeOnly,
                                                  claude: LongLimitFixture.claudeAheadOfPace.menuBar,
                                                  codex: nil)
        XCTAssertEqual(MenuBarWidth.steadyForm(calm), calm)
        XCTAssertEqual(MenuBarWidth.steadyForm(calm.showingReminder(0, on: 0)), calm)
    }
}
