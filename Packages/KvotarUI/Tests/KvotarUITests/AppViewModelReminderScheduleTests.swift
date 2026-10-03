import XCTest
import KvotarCore
@testable import KvotarUI

/// The clock half of REV-97 (STEP_199): when the bar switches phase, what it publishes, and when
/// the cycle starts over.
///
/// STEP_198 proved the arithmetic; this proves the view model asks it at the right moments. The
/// clock is injected, so a full minute of menu-bar behaviour is checked in microseconds instead of
/// by watching a real status item.
@MainActor
final class AppViewModelReminderScheduleTests: XCTestCase {

    private let entry = LongLimitFixture.now

    /// A view model with Claude in the rank-10 (amber) fixture and Codex calm, on a frozen clock.
    /// Amber, because since REV-100 §2.1 (STEP_210) it is the tier that cycles: red holds.
    private func model(_ fixture: LongLimitFixture = .claudeAheadOfPace,
                       withCodex: Bool = true) -> AppViewModel {
        let vm = AppViewModel()
        vm.clock = { [entry] in entry }
        if withCodex {
            vm.apply(tool: .codex, snapshot: calmCodex, forecast: calmCodexForecast,
                     state: .healthy, now: entry)
        }
        vm.apply(tool: fixture.tool, snapshot: fixture.snapshot,
                 forecast: fixture.forecast ?? calmCodexForecast, state: fixture.state, now: entry)
        return vm
    }

    private var calmCodex: QuotaSnapshot {
        QuotaSnapshot(tool: .codex, primaryUsedPct: 42,
                      primaryResetsAt: entry.addingTimeInterval(2 * 3600 + 4 * 60),
                      primaryWindowSeconds: 18_000, secondaryUsedPct: 20,
                      secondaryResetsAt: entry.addingTimeInterval(5 * 86_400),
                      rateLimitReached: false, source: .appServerRPC, planType: "plus")
    }

    private var calmCodexForecast: Forecast {
        Forecast(tool: .codex, tier: .fullRunway, runwayMinutes: 420, burnRatePerMin: 0.2,
                 isEstimate: false, pollCount: 10)
    }

    private func claudeLine(_ vm: AppViewModel) -> String? { vm.menuBarRender.lines.first?.text }

    // MARK: The cycle on the real render

    /// Entry fires at once: the reader who just crossed the line sees the reminder on the poll
    /// that crossed it, not a minute later.
    func testEntryRemindsImmediately() {
        let vm = model()
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%")
    }

    /// The five instants of §3.8, driven through the view model rather than through the pure
    /// function: reminder / reminder / steady / steady / reminder. Seven seconds up and **one
    /// minute** apart, because `claude-limit-ahead-of-pace` is rank 10 and reads amber's first
    /// hour in the REV-100 §2.2 table.
    func testTheFirstCycleOnTheRealRender() {
        let vm = model()
        let expected: [(TimeInterval, String)] = [
            (0,    "CL ⚠wk 30%"),
            (6.9,  "CL ⚠wk 30%"),
            (7,    "CL 71% ↻3h46m"),
            (59.9, "CL 71% ↻3h46m"),
            (60,   "CL ⚠wk 30%"),
        ]
        for (offset, text) in expected {
            vm.advanceReminderPhase(now: entry.addingTimeInterval(offset))
            XCTAssertEqual(claudeLine(vm), text, "at +\(offset)s")
        }
    }

    /// **Amber decays on the real render**: a minute between reminders for the first hour, ten
    /// the second, then hourly (REV-100 §2.2's three phases). Red has no column here any more —
    /// it holds.
    func testAmberDecaysOnTheRealRender() {
        let vm = model(.claudeAheadOfPace)
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "entry still reminds at once")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(60))
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "a minute later")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(3_660))
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "not every minute in the second hour")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(4_200))
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "every ten")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(7_800))
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "and after the second hour, hourly")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(10_800))
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%")
    }

    /// **A red monthly beside an amber weekly holds on the live render** (REV-100 §2.1 —
    /// STEP_210, the owner-accepted side effect). It used to alternate the two reminders; the red
    /// limit now owns the bar at every instant. Alternation itself is still pinned on the pure
    /// schedule (`MenuBarReminderTests.testTwoWarningsAlternate`).
    func testARedMonthlyHoldsOverAnAmberWeeklyOnTheRender() {
        let vm = model(.claudeBothLimitsWarning)
        let held = claudeLine(vm)
        XCTAssertTrue(held?.hasPrefix("CL ⚠mo 8% ↻") == true, held ?? "-")
        for offset in [0.0, 5, 300, 600, 3_600] {
            vm.advanceReminderPhase(now: entry.addingTimeInterval(offset))
            XCTAssertEqual(claudeLine(vm), held, "at +\(offset)s")
        }
    }

    /// **Two publishes per interval, and none at all otherwise.** A tick inside a phase changes
    /// nothing, so the controller is never asked to redraw — and a calm bar has no phase to tick.
    func testOnlyPhaseEdgesRepublish() {
        let vm = model()
        var publishes = 0
        let token = vm.objectWillChange.sink { _ in publishes += 1 }
        for tenth in 0...600 {
            vm.advanceReminderPhase(now: entry.addingTimeInterval(Double(tenth) / 10))
        }
        token.cancel()
        // One amber interval of ticks crosses exactly two edges: the reminder's end and the next
        // one's start.
        XCTAssertEqual(publishes, 2)
    }

    func testACalmToolNeverChangesPhase() {
        let vm = AppViewModel()
        vm.clock = { [entry] in entry }
        vm.apply(tool: .codex, snapshot: calmCodex, forecast: calmCodexForecast,
                 state: .healthy, now: entry)
        let steady = vm.menuBarRender
        for offset in [0.0, 5, 30, 60, 3_600] {
            vm.advanceReminderPhase(now: entry.addingTimeInterval(offset))
            XCTAssertEqual(vm.menuBarRender, steady, "at +\(offset)s")
        }
    }

    // MARK: Entry, exit, re-entry

    /// Leaving the tier ends the cycle: the row goes back to the ordinary string and stays there.
    func testLeavingTheTierStopsTheCycle() {
        let vm = model()
        var now = entry
        vm.clock = { now }
        let calm = LongLimitFixture.claudeAheadOfPace   // still reminds…
        XCTAssertFalse(calm.menuBar.reminders.isEmpty)

        now = entry.addingTimeInterval(120)
        vm.apply(tool: .claude, snapshot: healthyClaude(at: now), forecast: healthyClaudeForecast,
                 state: .healthy, now: now)
        XCTAssertEqual(claudeLine(vm), "CL 62% ↻3h46m")
        for offset in [0.0, 5, 60, 120] {
            vm.advanceReminderPhase(now: now.addingTimeInterval(offset))
            XCTAssertEqual(claudeLine(vm), "CL 62% ↻3h46m", "at +\(offset)s after leaving")
        }
    }

    /// **Restarted, not continued** (§2.1). A tool that leaves its tier and comes back reminds at
    /// once, rather than picking up wherever the old cycle happened to be.
    func testReEntryRestartsTheCycle() {
        let vm = model()
        var now = entry
        vm.clock = { now }

        now = entry.addingTimeInterval(30)          // mid-steady phase
        vm.apply(tool: .claude, snapshot: healthyClaude(at: now), forecast: healthyClaudeForecast,
                 state: .healthy, now: now)
        XCTAssertEqual(claudeLine(vm), "CL 62% ↻3h46m")

        now = entry.addingTimeInterval(37)          // would be steady on the old anchor
        let f = LongLimitFixture.claudeAheadOfPace
        vm.apply(tool: .claude, snapshot: f.snapshot, forecast: f.forecast!, state: f.state,
                 now: LongLimitFixture.now)
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "re-entry reminds at once")
        vm.advanceReminderPhase(now: now.addingTimeInterval(7))
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "…and the new cycle runs from there")
    }

    // MARK: Acknowledgement (REV-100 §2.2 — STEP_211)

    /// **Opening the popover acknowledges both tools' amber episodes.** Nothing more reminds on
    /// either row — not the next minute, not the second hour, not the hourly grid — and each
    /// episode's stored row carries the instant of the look.
    func testOpeningThePopoverAcknowledgesBothTools() {
        let vm = model()
        let codex = LongLimitFixture.codexAheadOfPace
        vm.apply(tool: .codex, snapshot: codex.snapshot, forecast: codex.forecast!,
                 state: codex.state, now: entry)
        var written: [Tool: String] = [:]
        vm.onPersistReminderEpisode = { tool, _, value in written[tool] = value }

        vm.acknowledgeReminders(now: entry.addingTimeInterval(30))
        let stamp = String(Int(entry.addingTimeInterval(30).timeIntervalSince1970))
        XCTAssertEqual(written[.claude]?.hasSuffix("|" + stamp), true, written[.claude] ?? "-")
        XCTAssertEqual(written[.codex]?.hasSuffix("|" + stamp), true, written[.codex] ?? "-")

        for offset in [60.0, 120, 3_600, 4_200, 7_200, 10_800] {
            vm.advanceReminderPhase(now: entry.addingTimeInterval(offset))
            XCTAssertFalse(vm.menuBarRender.lines.contains { $0.reminderIndex != nil },
                           "at +\(offset)s: \(vm.menuBarRender.lines.map(\.text))")
        }
        XCTAssertEqual(vm.menuBarRender.lines.first?.dot, .amber, "the dot keeps its colour")
    }

    /// A reminder on screen at the look **finishes** — seven seconds, then the fade — and a second
    /// look writes nothing, because the episode is already acknowledged.
    func testAReminderOnScreenFinishesAfterTheLook() {
        let vm = model(withCodex: false)
        var writes = 0
        vm.onPersistReminderEpisode = { _, _, _ in writes += 1 }
        vm.acknowledgeReminders(now: entry.addingTimeInterval(3))
        vm.advanceReminderPhase(now: entry.addingTimeInterval(6.9))
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "not cut")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(7))
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(60))
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "and nothing after it")
        vm.acknowledgeReminders(now: entry.addingTimeInterval(90))
        XCTAssertEqual(writes, 1)
    }

    /// **A relaunch after a look is silent.** The seeded row carries the acknowledgement, so the
    /// confirming poll earns no resume reminder and the grid stays quiet.
    func testAnAcknowledgedSeedStaysSilentOnRelaunch() {
        let f = LongLimitFixture.claudeAheadOfPace
        let vm = AppViewModel()
        var now = entry.addingTimeInterval(8_000)
        vm.clock = { now }
        let stored = ReminderEpisode(
            tool: .claude, limit: .secondary, tier: .aheadOfPace,
            enteredAt: entry, tierAt: entry, resetsAt: f.snapshot.secondaryResetsAt!,
            acknowledgedAt: entry.addingTimeInterval(90)).storedValue
        vm.seedReminderEpisode(tool: .claude, limit: .secondary, storedValue: stored)
        vm.apply(tool: .claude, snapshot: f.snapshot, forecast: f.forecast!, state: f.state,
                 now: LongLimitFixture.now)
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "no resume reminder")
        now = entry.addingTimeInterval(10_800)
        vm.advanceReminderPhase(now: now)
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "no hourly one either")
    }

    /// **Recovery then re-entry is a new, unacknowledged episode** with the full loud first hour —
    /// the look was about the old one.
    func testReEntryAfterALookIsLoudAgain() {
        let vm = model(withCodex: false)
        var now = entry
        vm.clock = { now }
        var written: [String?] = []
        vm.onPersistReminderEpisode = { _, _, value in written.append(value) }
        vm.acknowledgeReminders(now: entry.addingTimeInterval(30))

        now = entry.addingTimeInterval(120)
        vm.apply(tool: .claude, snapshot: healthyClaude(at: now), forecast: healthyClaudeForecast,
                 state: .healthy, now: now)
        now = entry.addingTimeInterval(180)
        let f = LongLimitFixture.claudeAheadOfPace
        vm.apply(tool: .claude, snapshot: f.snapshot, forecast: f.forecast!, state: f.state,
                 now: LongLimitFixture.now)
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "re-entry reminds at once")
        XCTAssertEqual(written.last??.hasSuffix("|"), true, "and is stored unacknowledged")
        vm.advanceReminderPhase(now: now.addingTimeInterval(60))
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "every minute again")
    }

    /// **A clock that stops on its own restarts for the next episode.** Before STEP_211 the loop
    /// could not run out of edges while something was warning; an acknowledged reminder ending is
    /// exactly that, and a finished task left in the slot would have denied the next episode its
    /// clock.
    func testAClockThatStopsOnItsOwnRestartsForTheNextEpisode() async throws {
        let vm = model(withCodex: false)          // task created; its body has not run yet
        vm.clock = { [entry] in entry.addingTimeInterval(6.95) }
        vm.acknowledgeReminders()                 // the reminder is still on screen: edge at 7 s
        XCTAssertTrue(vm.isReminderClockRunning)
        vm.clock = { [entry] in entry.addingTimeInterval(7) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(vm.isReminderClockRunning, "no edge left: the clock stopped and let go")

        let later = entry.addingTimeInterval(120)
        vm.clock = { later }
        vm.apply(tool: .claude, snapshot: healthyClaude(at: later), forecast: healthyClaudeForecast,
                 state: .healthy, now: later)
        let f = LongLimitFixture.claudeAheadOfPace
        vm.apply(tool: .claude, snapshot: f.snapshot, forecast: f.forecast!, state: f.state,
                 now: LongLimitFixture.now)
        XCTAssertTrue(vm.isReminderClockRunning, "the new episode has a clock")

        vm.apply(tool: .claude, snapshot: healthyClaude(at: later), forecast: healthyClaudeForecast,
                 state: .healthy, now: later)
        XCTAssertFalse(vm.isReminderClockRunning)
    }

    /// A percentage ticking down inside the same warning is not a re-entry — the cycle keeps its
    /// anchor rather than restarting every poll, which at the 120 s cadence would mean a reminder
    /// every other minute forever.
    func testAChangedReminderStringDoesNotRestartTheCycle() {
        let vm = model()
        var now = entry
        vm.clock = { now }
        now = entry.addingTimeInterval(20)
        let f = LongLimitFixture.claudeAheadOfPace
        vm.apply(tool: .claude, snapshot: f.snapshot, forecast: f.forecast!, state: f.state,
                 now: LongLimitFixture.now)
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "still in the steady phase of the first cycle")
    }

    // MARK: The episode's four events (REV-98 §2.3 — STEP_202)

    /// **A poll gap holds the episode.** A stale render reminds about nothing, and the schedule
    /// used to read that silence as recovery — so the reader came back to a replayed first-hour
    /// burst. Now the clocks are kept: when the reading returns, the cycle is exactly where it
    /// would have been.
    func testAStaleGapHoldsTheEpisodeRatherThanEndingIt() {
        let vm = model()
        var now = entry
        vm.clock = { now }
        let f = LongLimitFixture.claudeAheadOfPace

        now = entry.addingTimeInterval(400)
        vm.applyCached(tool: .claude, state: f.state, snapshot: f.snapshot,
                       asOf: entry.addingTimeInterval(-40 * 60), now: now)
        XCTAssertEqual(claudeLine(vm), "CL 71%", "stale: the cycle stops and the reading ages")

        // Back on a live poll 700 s after entry — mid-steady on the original clock, so the bar is
        // quiet. A restarted episode would have reminded here.
        now = entry.addingTimeInterval(700)
        vm.apply(tool: .claude, snapshot: f.snapshot, forecast: f.forecast!, state: f.state,
                 now: entry)
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "no replay and no catch-up")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(1_200))
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "the original grid, unmoved")
    }

    /// **Recovery is the tier clearing, not the percentage falling.** The weekly reads 52 % in
    /// both frames; the warning ends because the week caught up with it. The episode ends with
    /// it — and its stored row is cleared, so a later re-entry is a new episode.
    func testRecoveryAtUnchangedUtilizationEndsTheEpisode() {
        let warning = LongLimitFixture.claudeProjection115Amber
        let recovered = LongLimitFixture.claudeRecoveryOnPace
        let vm = AppViewModel()
        var now = entry
        vm.clock = { now }
        var cleared: [BlockEpisode.Limit] = []
        vm.onPersistReminderEpisode = { _, limit, value in
            if value == nil { cleared.append(limit) }
        }
        vm.apply(tool: .claude, snapshot: warning.snapshot, forecast: warning.forecast!,
                 state: warning.state, now: LongLimitFixture.now)
        XCTAssertTrue(claudeLine(vm)?.contains("⚠wk") == true, claudeLine(vm) ?? "-")

        now = entry.addingTimeInterval(1_800)
        vm.apply(tool: .claude, snapshot: recovered.snapshot, forecast: recovered.forecast!,
                 state: recovered.state, now: LongLimitFixture.now)
        XCTAssertEqual(cleared, [.secondary])
        for offset in [0.0, 5, 600, 3_600] {
            vm.advanceReminderPhase(now: now.addingTimeInterval(offset))
            XCTAssertFalse(claudeLine(vm)?.contains("⚠") == true, "at +\(offset)s after recovery")
        }
    }

    /// **A relaunch reminds once, then decays.** The seeded episode is two hours and thirteen
    /// minutes old: it reminds the moment a live reading confirms the tier, and then waits for its
    /// own hourly grid instead of replaying either louder hour.
    func testARelaunchRemindsOnceAndThenTakesTheDecayedCadence() {
        let f = LongLimitFixture.claudeAheadOfPace
        let vm = AppViewModel()
        var now = entry.addingTimeInterval(8_000)
        vm.clock = { now }
        let stored = ReminderEpisode(
            tool: .claude, limit: .secondary, tier: .aheadOfPace,
            enteredAt: entry, tierAt: entry,
            resetsAt: f.snapshot.secondaryResetsAt!).storedValue

        // Launch order is not guaranteed: the settings read can land before the first poll.
        vm.seedReminderEpisode(tool: .claude, limit: .secondary, storedValue: stored)
        vm.apply(tool: .claude, snapshot: f.snapshot, forecast: f.forecast!, state: f.state,
                 now: LongLimitFixture.now)
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "one reminder on the confirming poll")

        vm.advanceReminderPhase(now: now.addingTimeInterval(7))
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(8_060))
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "not the first-hour burst")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(8_400))
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "nor the second hour's ten minutes")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(10_800))
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "the grid at the episode's true age")
    }

    /// A stored row whose limit has recovered while the app was closed is dropped rather than
    /// resurrected — the seed is a restore, not an assertion.
    func testASeedForARecoveredLimitIsCleared() {
        let recovered = LongLimitFixture.claudeRecoveryOnPace
        let vm = AppViewModel()
        vm.clock = { [entry] in entry }
        var cleared = false
        vm.onPersistReminderEpisode = { _, _, value in if value == nil { cleared = true } }
        vm.apply(tool: .claude, snapshot: recovered.snapshot, forecast: recovered.forecast!,
                 state: recovered.state, now: LongLimitFixture.now)
        vm.seedReminderEpisode(
            tool: .claude, limit: .secondary,
            storedValue: ReminderEpisode(tool: .claude, limit: .secondary, tier: .aheadOfPace,
                                         enteredAt: entry, tierAt: entry,
                                         resetsAt: recovered.snapshot.secondaryResetsAt!)
                .storedValue)
        XCTAssertTrue(cleared)
        XCTAssertFalse(claudeLine(vm)?.contains("⚠") == true, claudeLine(vm) ?? "-")
    }

    /// A malformed row — a value written by a future build, or a truncated one — is dropped
    /// rather than crashing a menu bar.
    func testAMalformedSeedIsDropped() {
        let vm = model()
        var cleared = false
        vm.onPersistReminderEpisode = { _, _, value in if value == nil { cleared = true } }
        vm.seedReminderEpisode(tool: .claude, limit: .secondary, storedValue: "nonsense")
        XCTAssertTrue(cleared)
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "the live episode is untouched")
    }

    /// **Escalation moves the tier clock without restarting the episode.** The same weekly —
    /// one instance, one reset — goes amber → red half an hour in: `enteredAt` is kept, `tierAt`
    /// moves, and red **holds** the bar from that poll on, with no reminder to schedule
    /// (REV-100 §2.1 — STEP_210).
    ///
    /// The two readings must be the *same* week, which is why they are built here rather than
    /// taken from two fixtures: `claude-limit-ahead-of-pace` and `claude-limit-nearly-spent` sit
    /// at different points of different weeks, so switching between them is a new episode and
    /// would have made this pass for the wrong reason.
    func testEscalationKeepsTheEpisodeAndRedHoldsTheBar() {
        let vm = AppViewModel()
        var now = entry
        vm.clock = { now }
        var written: [String] = []
        vm.onPersistReminderEpisode = { _, _, value in written.append(value ?? "cleared") }
        vm.apply(tool: .claude, snapshot: weekly(used: 70), forecast: calmClaudeForecast,
                 state: .limitAheadOfPace, now: entry)
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%")

        now = entry.addingTimeInterval(1_800)
        vm.apply(tool: .claude, snapshot: weekly(used: 91), forecast: calmClaudeForecast,
                 state: .limitNearlySpent, now: entry)
        let held = claudeLine(vm)
        XCTAssertTrue(held?.hasPrefix("CL ⚠wk 9% ↻") == true, "red holds at once: \(held ?? "-")")
        for offset in [5.0, 300, 600, 3_600] {
            vm.advanceReminderPhase(now: now.addingTimeInterval(offset))
            XCTAssertEqual(claudeLine(vm), held, "held at +\(offset)s")
        }

        // Two rows written, and the second keeps the first's `enteredAt` while moving `tierAt`.
        XCTAssertEqual(written.count, 2)
        let first = written[0].split(separator: "|")
        let second = written[1].split(separator: "|")
        XCTAssertEqual(first[0], second[0], "enteredAt never moves inside an episode")
        XCTAssertNotEqual(first[1], second[1], "tierAt moves on escalation")
    }

    /// A reading that goes **backwards** inside the warning band takes the quieter cadence on the
    /// same clock: a limit that gets less serious must not get louder. Defensive rather than
    /// observed — utilization is monotone inside an instance, so this is a provider revising a
    /// figure down, not a week un-spending itself.
    func testADeEscalationDoesNotRestartTheHour() {
        let vm = AppViewModel()
        var now = entry
        vm.clock = { now }
        var written: [String] = []
        vm.onPersistReminderEpisode = { _, _, value in written.append(value ?? "cleared") }
        vm.apply(tool: .claude, snapshot: weekly(used: 91), forecast: calmClaudeForecast,
                 state: .limitNearlySpent, now: entry)

        now = entry.addingTimeInterval(4_000)   // past the decay boundary
        vm.apply(tool: .claude, snapshot: weekly(used: 70), forecast: calmClaudeForecast,
                 state: .limitAheadOfPace, now: entry)
        XCTAssertEqual(claudeLine(vm), "CL 71% ↻3h46m", "no fresh burst on the way down")
        let first = written[0].split(separator: "|")
        let second = written[1].split(separator: "|")
        XCTAssertEqual(first[1], second[1], "tierAt is kept")
        vm.advanceReminderPhase(now: entry.addingTimeInterval(4_200))
        XCTAssertEqual(claudeLine(vm), "CL ⚠wk 30%", "amber's second-hour grid, on the old clock")
    }

    /// One Claude weekly instance — same reset, same week position — so a change in the used
    /// percentage is a tier move inside one episode rather than a new one.
    private func weekly(used: Double) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: 29,
                      primaryResetsAt: entry.addingTimeInterval(226 * 60),
                      primaryWindowSeconds: 18_000, secondaryUsedPct: used,
                      secondaryResetsAt: entry.addingTimeInterval(4.2 * 86_400),
                      rateLimitReached: false, extraUsage: .disabled,
                      source: .oauth, email: "owner@example.com", planType: "max")
    }

    private var calmClaudeForecast: Forecast {
        Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 420, burnRatePerMin: 0.2,
                 isEstimate: false, pollCount: 10)
    }

    // MARK: The other tool never moves (§2.1)

    func testTheOtherToolsRowIsUntouchedThroughAReminder() {
        let vm = model()
        let codexSteady = vm.menuBarRender.lines[1]
        for offset in [0.0, 4.9, 5, 59.9, 60] {
            vm.advanceReminderPhase(now: entry.addingTimeInterval(offset))
            XCTAssertEqual(vm.menuBarRender.lines[1], codexSteady, "at +\(offset)s")
        }
    }

    /// The phase lands on the right row in every display mode — a single-tool mode renumbers the
    /// lines, and a phase index applied to the wrong one would remind about the other tool.
    func testThePhaseLandsOnTheRightRowInEveryMode() {
        let vm = model()
        for mode in MenuBarDisplayMode.allCases {
            vm.setMenuBarDisplayMode(mode)
            vm.advanceReminderPhase(now: entry)
            switch mode {
            case .bothStacked:
                XCTAssertEqual(vm.menuBarRender.lines.map(\.text),
                               ["CL ⚠wk 30%", "CX 58% ↻2h04m"])
            case .claudeOnly:
                XCTAssertEqual(vm.menuBarRender.lines.map(\.text), ["CL ⚠wk 30%"])
            case .codexOnly:
                XCTAssertEqual(vm.menuBarRender.lines.map(\.text), ["CX 58% ↻2h04m"])
            }
        }
    }

    // MARK: What never cycles (§2.4)

    /// A confirmed block holds its shape at every instant — it is not a reminder, and a block that
    /// flickered back to a five-hour percentage would be the very thing REV-97 §1.3 fixes.
    func testABlockHoldsAtEveryInstant() {
        let vm = model(.claudeWeeklySpent)
        for offset in [0.0, 4.9, 5, 30, 59.9, 60, 120] {
            vm.advanceReminderPhase(now: entry.addingTimeInterval(offset))
            XCTAssertEqual(claudeLine(vm), "CL ⚠wk 0% ↻3d", "at +\(offset)s")
        }
    }

    /// **Rank 5b holds at every instant** (REV-100 §2.1 / D-124 — STEP_210): the weekly's own
    /// reading and reset, never the five-hour's string, never a reminder.
    func testRedHoldsAtEveryInstant() {
        let vm = model(.claudeNearlySpent)
        for offset in [0.0, 4.9, 5, 300, 900, 3_600, 7_200] {
            vm.advanceReminderPhase(now: entry.addingTimeInterval(offset))
            XCTAssertEqual(claudeLine(vm), "CL ⚠wk 9% ↻4d", "at +\(offset)s")
        }
    }

    /// A five-hour warning outranks both long-limit ranks: the bar keeps its own urgent string.
    func testAFiveHourWarningKeepsTheBar() {
        let vm = model(.claudeFiveHourOutranksTheWeekly)
        let urgent = claudeLine(vm)
        XCTAssertEqual(urgent, "CL 4% ◔~11m")
        for offset in [0.0, 5, 60] {
            vm.advanceReminderPhase(now: entry.addingTimeInterval(offset))
            XCTAssertEqual(claudeLine(vm), urgent, "at +\(offset)s")
        }
    }

    // MARK: The debug fixture override (REV-97 §5 item 5)

    /// The override names a fixture; every name the set publishes resolves, and an unknown one is
    /// simply nil — a typo in an environment variable must not change what the bar shows.
    func testEveryFixtureNameResolvesAndAnUnknownOneDoesNot() {
        for fixture in LongLimitFixture.all {
            XCTAssertEqual(LongLimitFixture.named(fixture.name)?.name, fixture.name)
        }
        // The one frame outside `all` is reachable too: it is the case worth watching live
        // precisely because it must *not* remind.
        XCTAssertNotNil(LongLimitFixture.named("claude-five-hour-outranks-the-weekly"))
        XCTAssertNil(LongLimitFixture.named("claude-limit-nearly-spend"))
        XCTAssertNil(LongLimitFixture.named(""))
    }

    /// Nothing is forced unless the environment says so, which is what keeps the override out of
    /// every ordinary run — including this test suite.
    func testNoFixtureIsForcedByDefault() {
        XCTAssertNil(AppViewModel.menuBarFixture)
    }

    // MARK: Helpers

    /// Anchored to the instant it is applied, so the countdown reads the same however far into
    /// the test the tool leaves its tier.
    private func healthyClaude(at instant: Date) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: 38,
                      primaryResetsAt: instant.addingTimeInterval(226 * 60),
                      primaryWindowSeconds: 18_000, secondaryUsedPct: 20,
                      secondaryResetsAt: instant.addingTimeInterval(5 * 86_400),
                      rateLimitReached: false, extraUsage: .disabled,
                      source: .oauth, email: "owner@example.com", planType: "max")
    }

    private var healthyClaudeForecast: Forecast {
        Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 420, burnRatePerMin: 0.2,
                 isEstimate: false, pollCount: 10)
    }
}
