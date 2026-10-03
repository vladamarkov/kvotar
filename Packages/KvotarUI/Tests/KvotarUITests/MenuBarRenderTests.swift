import XCTest
import AppKit
import KvotarCore
@testable import KvotarUI

/// §1.0 display-mode matrix (Baseline §14.1) — pure `DisplayFormatter.menuBarRender` fixtures.
///
/// D-98 (REV-78) cut this from six modes to three. The Adaptive, Compact-glyph and Hidden tests
/// went with their modes, along with the gauge assertions and the `dominant:` argument.
final class MenuBarRenderTests: XCTestCase {

    // A live reading with nothing elevated — which is what a poll of a calm account produces,
    // and what makes a step into these lines an ordinary §2.4a crossfade rather than one of the
    // three immediate exemptions (STEP_203).
    private let claudeCalm = ToolMenuBarDisplay(
        prefix: "CL", dot: .green, percentText: "38%", timeSlot: "↻1h52m", longLimits: .live([]))
    private let claudeCritical = ToolMenuBarDisplay(
        prefix: "CL", dot: .red, percentText: "87%", timeSlot: "◔~11m", longLimits: .live([]))
    private let codexCalm = ToolMenuBarDisplay(
        prefix: "CX", dot: .green, percentText: "42%", timeSlot: "↻2h04m", longLimits: .live([]))
    private let codexElevated = ToolMenuBarDisplay(
        prefix: "CX", dot: .amber, percentText: "71%", timeSlot: "◔~31m", longLimits: .live([]))

    private func render(_ mode: MenuBarDisplayMode,
                        claude: ToolMenuBarDisplay?, codex: ToolMenuBarDisplay?) -> MenuBarRender {
        DisplayFormatter.menuBarRender(mode: mode, claude: claude, codex: codex)
    }

    // MARK: Both stacked

    func testStackedRendersOneRowPerToolWithDots() {
        let r = render(.bothStacked, claude: claudeCalm, codex: codexElevated)
        XCTAssertEqual(r.lines, [
            MenuBarRender.TextLine(text: "CL 38% ↻1h52m", dot: .green),
            MenuBarRender.TextLine(text: "CX 71% ◔~31m", dot: .amber),
        ])
    }

    /// D-32 — one detected tool collapses stacked to the single-tool shape (drawn as the D-107 reduced row), byte-identical to
    /// the matching single-tool mode. This is what makes "if both are detected show both,
    /// otherwise show whichever one is there" need no code and nothing persisted.
    func testStackedCollapsesToTheSingleToolShape() {
        let collapsed = render(.bothStacked, claude: claudeCalm, codex: nil)
        let claudeOnly = render(.claudeOnly, claude: claudeCalm, codex: nil)
        XCTAssertEqual(collapsed, claudeOnly)
        XCTAssertEqual(collapsed.lines.count, 1)
    }

    // MARK: Single tool

    func testClaudeOnlyIgnoresCodex() {
        let r = render(.claudeOnly, claude: claudeCritical, codex: codexElevated)
        XCTAssertEqual(r.lines, [MenuBarRender.TextLine(text: "CL 87% ◔~11m", dot: .red)])
    }

    func testCodexOnlyWithUndetectedCodexRendersNothing() {
        let r = render(.codexOnly, claude: claudeCalm, codex: nil)
        XCTAssertTrue(r.lines.isEmpty)
    }

    // MARK: Nothing detected — D-78 (REV-71 §3.3), STEP_118

    /// Every mode shows the mark when the detected set is empty. Before D-78, each mode
    /// independently produced an empty render, the view drew `EmptyView()`, and the controller
    /// sized the item to it — ~8 pt of invisible-but-clickable padding. The "every mode **but
    /// Hidden**" carve-out this test used to carry went with Hidden itself (D-98).
    func testNothingDetectedRendersTheMarkInEveryMode() {
        for mode in MenuBarDisplayMode.allCases {
            let r = render(mode, claude: nil, codex: nil)
            XCTAssertEqual(r.content, .nothingDetected, "\(mode.rawValue) must show the mark")
            XCTAssertTrue(r.lines.isEmpty, "\(mode.rawValue): no text of any kind")
        }
    }

    /// The moment one tool is detected the mark is gone — no leftover mark beside the tool's row.
    func testOneDetectedToolReplacesTheMark() {
        let r = render(.bothStacked, claude: claudeCalm, codex: nil)
        XCTAssertEqual(r.content, .tools(lines: [
            MenuBarRender.TextLine(text: "CL 38% ↻1h52m", dot: .green),
        ]))
    }

    /// The distinction the enum exists for: a **detected** tool with no reading (`–– est`,
    /// `—— est`) is not "nothing detected". Both used to be an empty render in some mode, and the
    /// type could not tell them apart.
    func testDetectedToolWithNoReadingIsNotNothingDetected() {
        let idle = ToolMenuBarDisplay(prefix: "CL", dot: .grey, percentText: "––", timeSlot: "est")
        let r = render(.claudeOnly, claude: idle, codex: nil)
        XCTAssertNotEqual(r.content, .nothingDetected)
        // `.immediate` is the §2.4a rule, not an accident: a missing or pending reading is one of
        // the three states that land at once, and idle is exactly that (STEP_203).
        XCTAssertEqual(r.lines, [MenuBarRender.TextLine(text: "CL –– est", dot: .grey,
                                                        transition: .immediate)])
    }

    /// And the converse: a single-tool mode whose tool is the undetected one still renders
    /// nothing, because the *other* tool is detected — a mark there would claim nothing is
    /// detected while something is. Companion to `testCodexOnlyWithUndetectedCodexRendersNothing`.
    func testSingleToolModeWithTheOtherToolDetectedIsNotNothingDetected() {
        let r = render(.codexOnly, claude: claudeCalm, codex: nil)
        XCTAssertNotEqual(r.content, .nothingDetected)
        XCTAssertTrue(r.lines.isEmpty)
    }

    // MARK: Width stability proxy (§1.0) — same state + same digit count → identical string

    func testSameStateSameDigitsRendersIdenticalString() {
        let a = render(.bothStacked, claude: claudeCalm, codex: codexCalm)
        let b = render(.bothStacked, claude: claudeCalm, codex: codexCalm)
        XCTAssertEqual(a, b)
    }

    // MARK: The two phases and what they cost in width (§1.0 / REV-97 §2.6 — STEP_198)

    /// **The reminder is what §2.6 reserves against, and it is now strictly free.** Measured
    /// rather than counted — the string is drawn in a monospaced-digit system font at the two
    /// shipped sizes, so a `%` sign and a `↻` are not the same width and character counts prove
    /// nothing.
    ///
    /// This used to allow a five-point overrun, because the reminder carried the limit's reset
    /// and the §2.7 compact form kept the cost near two points. **Variant D dropped the reset**
    /// (REV-98 §2.4 — STEP_203): the headline is provider, limit and remaining percent, and the
    /// reset moved to the popover. So the reminder is now *shorter* than every string the bar
    /// already renders, entering a warning tier reserves nothing extra, and the slack is what the
    /// headline grows into. `MenuBarWidthTests` asserts the same thing through the laid-out view.
    func testTheReminderIsShorterThanEveryStringTheBarAlreadyRenders() {
        let shipped = ["↻47h59m", "↻1h52m", "↻31d", "◔~59m", "◔~6d", "est"]
        for size in [9.0, 11.0] {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            func width(_ text: String) -> CGFloat {
                (text as NSString).size(withAttributes: [.font: font]).width
            }
            for prefix in ["CL", "CX"] {
                let envelope = [0, 9, 99, 100].flatMap { pct in
                    shipped.map { width("\(prefix) \(pct)% \($0)") }
                }.max()!
                for scope in ["wk", "mo"] {
                    for pct in [0, 9, 99, 100] {
                        let s = "\(prefix) ⚠\(scope) \(pct)%"
                        XCTAssertLessThan(
                            width(s), envelope,
                            "\(s) at \(Int(size))pt is \(String(format: "%.1f", width(s)))pt "
                            + "against a \(String(format: "%.1f", envelope))pt envelope")
                    }
                }
            }
        }
    }

    // MARK: The reminder's shape, and how a step into a line is drawn (REV-98 — STEP_203)

    /// **The reminder carries no reset** (§2.4 / §3.6) — and the two strings that still do, still
    /// do. The whole risk in dropping it was dropping it from the wrong place: a held block reads
    /// `CL ⚠wk 0% ↻3d` and that countdown is the only thing on the bar saying when the block ends.
    func testOnlyTheReminderLostItsReset() {
        let reminding = LongLimitFixture.claudeAheadOfPace.menuBar
        XCTAssertEqual(reminding.reminders, ["CL ⚠wk 30%"])
        XCTAssertTrue(reminding.fullString.contains("↻"), "the steady phase keeps its slot")

        // Red holds the limit's own reset, like a block (REV-100 §2.1 — STEP_210).
        let red = LongLimitFixture.claudeNearlySpent.menuBar
        XCTAssertTrue(red.reminders.isEmpty, "red is not a reminder")
        XCTAssertEqual(red.fullString, "CL ⚠wk 9% ↻4d")

        let blocked = LongLimitFixture.claudeWeeklySpent.menuBar
        XCTAssertTrue(blocked.reminders.isEmpty, "a block is not a reminder")
        XCTAssertTrue(blocked.fullString.contains("↻"), "and it keeps the blocking limit's reset")
    }

    /// **The three immediate exemptions, per fixture** (§2.4a). The formatter decides them,
    /// because it already tested for all three to decide what the line *says*; the view only
    /// reads the answer. **Rank 5b joins the block exemption** (REV-100 §2.1 — STEP_210): it holds
    /// a shape and reminds about nothing, so the existing rule marks it immediate — arriving at
    /// red lands at once, like arriving at a block.
    func testTheTransitionIsImmediateExactlyOnTheThreeExemptions() {
        let exempt: Set<String> = [LongLimitFixture.claudeWeeklySpent.name,
                                   LongLimitFixture.claudeBlockRollover.name,
                                   LongLimitFixture.claudeBlockStale.name,
                                   LongLimitFixture.claudeBlockBoth.name,
                                   LongLimitFixture.claudeFiveHourOutranksTheWeekly.name]
        for fixture in LongLimitFixture.all + [.claudeFiveHourOutranksTheWeekly] {
            let expected: MenuBarRender.TextLine.Transition =
                exempt.contains(fixture.name) || fixture.state == .limitNearlySpent
                    ? .immediate : .animated
            XCTAssertEqual(fixture.menuBar.transition, expected, fixture.name)
        }
    }

    /// The item reserves the **wider phase** (§2.6), and `phaseStrings` is the list it measures.
    /// Every string the line can render without a state change is in it, steady included — so a
    /// reservation computed from this list cannot be caught out by a phase edge.
    func testPhaseStringsCarryEveryStringTheLineCanShow() {
        let line = MenuBarRender.TextLine(
            steady: "CL 64% ↻3h46m",
            reminders: ["CL ⚠mo 8%", "CL ⚠wk 43%"], dot: .red)
        XCTAssertEqual(line.phaseStrings,
                       ["CL 64% ↻3h46m", "CL ⚠mo 8%", "CL ⚠wk 43%"])
        XCTAssertEqual(line.text, "CL 64% ↻3h46m")
        XCTAssertEqual(line.showingReminder(0).text, "CL ⚠mo 8%")
        XCTAssertEqual(line.showingReminder(1).text, "CL ⚠wk 43%")
        // An index the list does not have falls back to steady rather than trapping: the
        // schedule and the reminder list are computed on different cycles.
        XCTAssertEqual(line.showingReminder(7).text, "CL 64% ↻3h46m")
    }

    /// A line that never reminds reserves exactly one string — the ordinary case, and the proof
    /// that nothing about the normal menu bar changed in this step.
    func testALineWithNoReminderHasOnePhase() {
        XCTAssertEqual(MenuBarRender.TextLine(text: "CL 38% ↻1h52m").phaseStrings,
                       ["CL 38% ↻1h52m"])
    }

    /// **Amber reminds in the §3.1 grammar** — the limit's name and what is left of it — and
    /// **red holds the same two facts plus the limit's own reset** in the steady string, with no
    /// reminder (REV-100 §2.1 / D-124 — STEP_210).
    func testAmberRemindsAndRedHoldsInTheSpecGrammar() {
        let amber = LongLimitFixture.claudeAheadOfPace.menuBar
        XCTAssertEqual(amber.reminders, ["CL ⚠wk 30%"])
        let red = LongLimitFixture.claudeNearlySpent.menuBar
        XCTAssertEqual(red.reminders, [])
        XCTAssertEqual(red.fullString, "CL ⚠wk 9% ↻4d")
        let monthly = LongLimitFixture.claudeMonthlyNearlyReached.menuBar
        XCTAssertEqual(monthly.reminders, [])
        XCTAssertTrue(monthly.fullString.hasPrefix("CL ⚠mo 8% ↻"), monthly.fullString)
    }

    /// **The steady phase does not move with the clock, and the reminder does not either.** The
    /// only thing that changes between two polls is the countdown the steady phase already had;
    /// the reminder's compact reset is stable for hours, which is the point of §2.7.
    func testTheReminderIsStableBetweenPolls() {
        let f = LongLimitFixture.claudeAheadOfPace
        func menu(_ offset: TimeInterval) -> ToolMenuBarDisplay {
            DisplayFormatter.toolMenuBar(tool: .claude, state: f.state, snapshot: f.snapshot,
                                         forecast: f.forecast,
                                         now: LongLimitFixture.now.addingTimeInterval(offset))
        }
        XCTAssertEqual(menu(0).reminders, menu(600).reminders)
        // The steady slot it sits beside is a countdown and moves ten minutes in the same span.
        XCTAssertNotEqual(menu(0).timeSlot, menu(600).timeSlot)
    }

    // MARK: Settings raw values (Baseline §17.1)

    func testModeRawValuesAreTheSettingsStrings() {
        XCTAssertEqual(MenuBarDisplayMode.bothStacked.rawValue, "both_stacked")
        XCTAssertEqual(MenuBarDisplayMode.claudeOnly.rawValue, "claude_only")
        XCTAssertEqual(MenuBarDisplayMode.codexOnly.rawValue, "codex_only")
        XCTAssertEqual(MenuBarDisplayMode.settingsKey, "menu_bar_display_mode")
    }

    /// The retired raw values must not decode — this is the runtime half of the v21 migration
    /// (D-98): a database an older build wrote falls through to the `.bothStacked` default even
    /// before the migration rewrites the row.
    func testRetiredRawValuesDoNotDecode() {
        for retired in ["adaptive", "compact_glyph", "hidden"] {
            XCTAssertNil(MenuBarDisplayMode(rawValue: retired), "\(retired) must stay retired")
        }
        XCTAssertEqual(MenuBarDisplayMode.allCases.count, 3)
    }

    // MARK: What VoiceOver hears (REV-97 §2.8 — STEP_199)

    /// **The warning is spoken in both phases.** A reminder is up for five seconds in sixty; a
    /// reader who hears the row in the other fifty-five must not have to wait out the cycle to
    /// learn which limit is in trouble.
    func testTheLabelStatesTheWarningInBothPhases() {
        let line = MenuBarRender.TextLine(
            steady: "CL 64% ↻3h46m", reminders: ["CL ⚠wk 8%"], dot: .red)
        let steady = line.accessibilityLabel
        XCTAssertTrue(steady.contains("weekly limit 8%"), steady)
        XCTAssertTrue(steady.contains("Claude 64%"), steady)
        XCTAssertTrue(steady.contains("critical"), steady)

        let reminding = line.showingReminder(0).accessibilityLabel
        XCTAssertTrue(reminding.contains("weekly limit 8%"), reminding)
        // Said once, not twice: in the reminder phase the drawn text already is the warning.
        XCTAssertEqual(reminding.components(separatedBy: "weekly limit").count - 1, 1, reminding)
    }

    /// The bar's glyphs are read as words. Without a label VoiceOver reads the raw string, and
    /// "clockwise open circle arrow 3h46m" is not a reading of anything.
    func testTheLabelSpellsOutTheGlyphs() {
        XCTAssertEqual(MenuBarRender.TextLine(text: "CL 62% ↻1h52m", dot: .green)
                        .accessibilityLabel,
                       "Claude 62% resets in 1h52m, healthy")
        XCTAssertEqual(MenuBarRender.TextLine(text: "CX 13% ◔~11m", dot: .red)
                        .accessibilityLabel,
                       "Codex 13% runs out in about 11m, critical")
        XCTAssertEqual(MenuBarRender.TextLine(text: "CL ⚠mo 0% ↻9d", dot: .red)
                        .accessibilityLabel,
                       "Claude monthly limit 0% resets in 9d, critical")
    }

    /// The §1.6 glyph is a `$` drawn beside the text; a row that ignores its children for
    /// accessibility would silently drop it.
    func testTheLabelCarriesTheMoneyGlyph() {
        let armed = MenuBarRender.TextLine(text: "CL 4% ↻18m", dot: .amber, glyph: .armed)
        XCTAssertTrue(armed.accessibilityLabel.hasSuffix("extra usage may start"),
                      armed.accessibilityLabel)
        let charging = MenuBarRender.TextLine(text: "CL 0% ↻18m", dot: .red, glyph: .charging)
        XCTAssertTrue(charging.accessibilityLabel.hasSuffix("extra usage charging"),
                      charging.accessibilityLabel)
    }

    // MARK: The first-run window renders the steady phase (REV-97 §2.9)

    /// Screen 3 builds its own render straight from the formatter, which never picks a phase — so
    /// a reminder can never appear in a screenshot-shaped onboarding screen, where it would look
    /// like a bug.
    func testTheFormatterNeverPicksAPhase() {
        let render = DisplayFormatter.menuBarRender(
            mode: .bothStacked, claude: LongLimitFixture.claudeAheadOfPace.menuBar,
            codex: LongLimitFixture.codexAheadOfPace.menuBar)
        XCTAssertTrue(render.lines.allSatisfy { $0.reminderIndex == nil })
        XCTAssertEqual(render.lines.map(\.text), render.lines.map(\.steady))
        XCTAssertFalse(render.lines.contains { $0.reminders.isEmpty }, "…but both can remind")
    }
}
