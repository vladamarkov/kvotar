import XCTest
import KvotarCore
@testable import KvotarUI

/// **Reduced motion keeps the colour and drops the pulse** (REV-97 §2.8 — STEP_199).
///
/// The system setting cannot be flipped from a test process — it lives behind System Settings —
/// so what is pinned here is the rule the view calls, stated once in `MenuBarReminder.pulses`
/// rather than inline where only an eye could check it. The pulse itself was measured on the live
/// bar (`docs/evidence/STEP_199/live-*`): three cycles, 1.6 s apart, inside the five-second phase.
final class MenuBarMotionTests: XCTestCase {

    func testOnlyAReminderPulses() {
        XCTAssertTrue(MenuBarReminder.pulses(reminderIndex: 0, reduceMotion: false))
        XCTAssertTrue(MenuBarReminder.pulses(reminderIndex: 1, reduceMotion: false))
        XCTAssertFalse(MenuBarReminder.pulses(reminderIndex: nil, reduceMotion: false),
                       "the steady phase never moves")
    }

    func testReducedMotionStopsThePulseInBothPhases() {
        XCTAssertFalse(MenuBarReminder.pulses(reminderIndex: 0, reduceMotion: true))
        XCTAssertFalse(MenuBarReminder.pulses(reminderIndex: nil, reduceMotion: true))
    }

    /// …and the reminder itself is unaffected: same string, same account colour, still shown. Only
    /// the motion is dropped.
    func testReducedMotionKeepsTheReminderAndItsColour() {
        let reminding = DisplayFormatter.menuBarRender(
            mode: .claudeOnly, claude: LongLimitFixture.claudeAheadOfPace.menuBar, codex: nil)
            .showingReminder(0, on: 0)
        XCTAssertEqual(reminding.lines[0].text, "CL ⚠wk 30%")
        XCTAssertEqual(reminding.lines[0].dot, .amber, "the account colour the row takes")
        XCTAssertFalse(MenuBarReminder.pulses(reminderIndex: reminding.lines[0].reminderIndex,
                                              reduceMotion: true))
    }

    // MARK: The crossfade (REV-98 §2.4a — STEP_203)

    private func reminding(_ fixture: LongLimitFixture, _ index: Int? = 0) -> MenuBarRender {
        let base = DisplayFormatter.menuBarRender(mode: .claudeOnly, claude: fixture.menuBar,
                                                  codex: nil)
        return index.map { base.showingReminder($0, on: 0) } ?? base
    }

    /// Both directions, which is the half the prototype originally had and the half it skipped:
    /// entry read as a glitch while exit read as a transition.
    func testBothEdgesOfAReminderFade() {
        let steady = reminding(.claudeAheadOfPace, nil)
        let shown = reminding(.claudeAheadOfPace, 0)
        XCTAssertTrue(MenuBarReminder.fades(from: steady, to: shown, reduceMotion: false),
                      "entry")
        XCTAssertTrue(MenuBarReminder.fades(from: shown, to: steady, reduceMotion: false),
                      "exit")
    }

    /// **Reduce motion drops the fade and the pulse together**, and keeps the colour — the
    /// reminder still appears, it simply arrives whole.
    func testReducedMotionDropsTheFade() {
        XCTAssertFalse(MenuBarReminder.fades(from: reminding(.claudeAheadOfPace, nil),
                                             to: reminding(.claudeAheadOfPace, 0),
                                             reduceMotion: true))
    }

    /// **An identical re-render keeps the layer and the pulse it already had.** At the 120 s poll
    /// cadence a fade on every rebuild would fire one every other minute, for nothing.
    func testAnIdenticalRerenderDoesNotFade() {
        let shown = reminding(.claudeAheadOfPace, 0)
        XCTAssertFalse(MenuBarReminder.fades(from: shown, to: shown, reduceMotion: false))
    }

    /// **The three exemptions.** A confirmed block, an urgent five-hour state that outranks the
    /// long limit, and a missing or pending reading all land at once. A fade is a softening, and
    /// nothing about arriving at a block should be soft.
    func testTheThreeExemptionsLandAtOnce() {
        let shown = reminding(.claudeAheadOfPace, 0)
        let exemptions: [LongLimitFixture] = [.claudeWeeklySpent,
                                              .claudeFiveHourOutranksTheWeekly,
                                              .claudeBlockStale]
        for exempt in exemptions {
            let to = reminding(exempt, nil)
            XCTAssertEqual(to.lines[0].transition, .immediate, exempt.name)
            XCTAssertFalse(MenuBarReminder.fades(from: shown, to: to, reduceMotion: false),
                           exempt.name)
        }
    }

    /// **Red lands at once, like a block** (REV-100 §2.1 — STEP_210). Rank 5b holds its shape and
    /// reminds about nothing, so the formatter's existing rule — a live reading with elevated
    /// limits and no reminder line — already marks it immediate. No fourth exemption was written.
    func testArrivingAtRedLandsAtOnce() {
        let to = reminding(.claudeNearlySpent, nil)
        XCTAssertEqual(to.lines[0].transition, .immediate)
        XCTAssertFalse(MenuBarReminder.fades(from: reminding(.claudeAheadOfPace, 0), to: to,
                                             reduceMotion: false))
    }

    /// A **recovery** is not an exemption — it is one of the four entry paths, and it fades.
    func testARecoveryFades() {
        let to = reminding(.claudeRecoveryOnPace, nil)
        XCTAssertEqual(to.lines[0].transition, .animated)
        XCTAssertTrue(MenuBarReminder.fades(from: reminding(.claudeAheadOfPace, 0), to: to,
                                            reduceMotion: false))
    }

    /// **A layout change never overlays two differently sized layers** — a tool appearing or
    /// disappearing swaps outright.
    func testALineCountChangeDoesNotFade() {
        let single = reminding(.claudeAheadOfPace, 0)
        let stacked = DisplayFormatter.menuBarRender(
            mode: .bothStacked, claude: LongLimitFixture.claudeAheadOfPace.menuBar,
            codex: ToolMenuBarDisplay(prefix: "CX", dot: .green, percentText: "58%",
                                      timeSlot: "↻2h04m", longLimits: .live([])))
            .showingReminder(0, on: 0)
        XCTAssertFalse(MenuBarReminder.fades(from: single, to: stacked, reduceMotion: false))
    }

    /// The transition is 350 ms and the pulse is offset by exactly it, which is what "the pulse
    /// waits for the fade" means arithmetically. Under REV-98 three cycles ran 150 ms past a
    /// five-second phase; since REV-100 §2.2 (STEP_211) four cycles in a seven-second phase end
    /// **250 ms inside it**, so the row is still when it fades out — recorded here so a future
    /// reader meets the number instead of discovering it.
    func testThePulseStartsAfterTheFadeAndEndsInsideThePhase() {
        XCTAssertEqual(MenuBarReminder.transitionSeconds, 0.35, accuracy: 0.0001)
        let pulseEnds = MenuBarReminder.transitionSeconds
            + MenuBarReminder.pulseCycleSeconds * Double(MenuBarReminder.pulseCycles)
        XCTAssertEqual(pulseEnds - MenuBarReminder.reminderSeconds, -0.25, accuracy: 0.0001)
    }
}
