import XCTest
import KvotarCore

// REV-77 / D-97 (STEP_140) ruling, amended the same evening: the delta line carries deltas and
// high-water marks — events, not gauges — so the %-left flip does not change what it measures.
// One copy addendum landed after dogfood: the bare Δ context token (`+13%`) was ambiguous once
// every level reads *left*, so it now says its direction — `13% burned` / `2% returned`. The
// off-machine token keeps its `+14% off-machine` form (it names itself).
@testable import KvotarUI

/// The "Since you last looked" gate and grammar (UI Spec Part 1 §2.8 / Part 2 §2.10, D-75 —
/// STEP_112), pure. Baseline §19 fixtures: delta-boundary, delta-boundary-limit, delta-unseen,
/// delta-fresh-null (delta-stale lives in the view-model suite — staleness is a render property).
final class DeltaLineTests: XCTestCase {

    // 2023-11-14 22:13:20 UTC. Local-day arithmetic runs in the test machine's zone; every
    // "same day" case stays inside a few minutes of `now` so no timezone can split it.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var nowUnix: Int { Int(now.timeIntervalSince1970) }
    private var resetsAt: Int { nowUnix + 3_600 }

    private func snap(takenAt: Int? = nil, window: Int?? = nil, used: Double? = 40,
                      family: VerdictFamily = .resetsFirst, tier: String = "low",
                      agents: Int = 0, visible: Bool = true,
                      off: Double? = nil) -> LastOpenSnapshot {
        LastOpenSnapshot(takenAt: takenAt ?? (nowUnix - 300),
                         windowResetsAt: window ?? resetsAt, usedPct: used,
                         verdictFamily: family.rawValue, burnTier: tier, agentCount: agents,
                         pctVisibleInMenuBar: visible, offMachinePct: off)
    }

    private func eval(_ previous: LastOpenSnapshot, _ current: LastOpenSnapshot,
                      tool: Tool = .claude) -> DeltaLine.Decision {
        DeltaLine.evaluate(previous: previous, current: current, tool: tool, now: now)
    }

    private var sinceClock: String {
        Fmt.clock(now.addingTimeInterval(-300))
    }

    // MARK: Gate

    func testIdenticalSnapshotsAreSilent() {
        XCTAssertEqual(eval(snap(), snap(takenAt: nowUnix)), .silent)
    }

    /// Trigger 1 — the count *rose*; the word is per tool (D-11: threads, never subagents, on Codex).
    func testAgentCountRoseNamesTheToolsUnit() {
        XCTAssertEqual(eval(snap(agents: 0), snap(takenAt: nowUnix, agents: 1)),
                       .line("Since \(sinceClock): 1 subagent spawned"))
        XCTAssertEqual(eval(snap(agents: 1), snap(takenAt: nowUnix, agents: 4)),
                       .line("Since \(sinceClock): 3 subagents spawned"))
        XCTAssertEqual(eval(snap(agents: 2), snap(takenAt: nowUnix, agents: 3), tool: .codex),
                       .line("Since \(sinceClock): 1 thread started"))
        XCTAssertEqual(eval(snap(agents: 0), snap(takenAt: nowUnix, agents: 2), tool: .codex),
                       .line("Since \(sinceClock): 2 threads started"))
        // A count that fell is not news.
        XCTAssertEqual(eval(snap(agents: 3), snap(takenAt: nowUnix, agents: 1)), .silent)
    }

    /// Trigger 2 — old → new pill words on a **rise**; `—` on either side is not a change.
    /// *(REV-74/D-85 — STEP_123: `high → none` used to render here. It is the one fixture this
    /// step edits, and the edit is the decision: a fall is the resting state arriving, which the
    /// pill directly below the line already says.)*
    func testBurnTierRoseAndUnknownExcluded() {
        XCTAssertEqual(eval(snap(tier: "low"), snap(takenAt: nowUnix, tier: "high")),
                       .line("Since \(sinceClock): burn low → high"))
        XCTAssertEqual(eval(snap(tier: "none"), snap(takenAt: nowUnix, tier: "mid")),
                       .line("Since \(sinceClock): burn very low → mid"))
        XCTAssertEqual(eval(snap(tier: "—"), snap(takenAt: nowUnix, tier: "mid")), .silent)
        XCTAssertEqual(eval(snap(tier: "mid"), snap(takenAt: nowUnix, tier: "—")), .silent)
    }

    /// A fall renders **no burn token** — not a quieter one (D-85). Every neighbouring rung, so a
    /// future reordering of the four words cannot pass by accident.
    func testBurnTierFallIsSilent() {
        for (was, now) in [("high", "none"), ("high", "mid"), ("mid", "low"), ("low", "none")] {
            XCTAssertEqual(eval(snap(tier: was), snap(takenAt: nowUnix, tier: now)), .silent,
                           "\(was) → \(now) is a fall and must render nothing")
        }
    }

    /// And a fall alongside a real trigger drops **only** its own token — the line still renders,
    /// still carries the other trigger and the Δ% context.
    func testBurnFallDropsItsTokenAndKeepsTheRestOfTheLine() {
        let line = eval(snap(used: 40, tier: "high", agents: 1),
                        snap(takenAt: nowUnix, used: 46, tier: "low", agents: 2))
        XCTAssertEqual(line, .line("Since \(sinceClock): 1 subagent spawned · 6% burned"))
    }

    /// Trigger 3 — family identity, not wording; the null-window / stale / connecting families
    /// never count in either direction. `measuring` joined them 2026-09-03 (D-110).
    func testVerdictFamilyChangedAndExcludedFamilies() {
        XCTAssertEqual(eval(snap(family: .resetsFirst), snap(takenAt: nowUnix, family: .exhaustion)),
                       .line("Since \(sinceClock): verdict changed"))
        for excluded in [VerdictFamily.nullWindow, .unknown, .reconnecting, .signInExpired, .idle,
                         .measuring] {
            XCTAssertEqual(eval(snap(family: excluded), snap(takenAt: nowUnix, family: .exhaustion)),
                           .silent, "\(excluded) → exhaustion")
            XCTAssertEqual(eval(snap(family: .exhaustion), snap(takenAt: nowUnix, family: excluded)),
                           .silent, "exhaustion → \(excluded)")
        }
    }

    /// D-110 (REV-68 amendment 2026-09-03 — Baseline §19 *delta-measuring*): `Measuring…` is a
    /// statement about the forecast buffer, not about the account, and the buffer starts empty on
    /// every launch — so a crossing into or out of it is a relaunch artefact, not news. The three
    /// crossings the logs actually recorded, all silent now.
    func testMeasuringCrossingIsNotNews() {
        // 2026-09-02 23:46 local, Codex tab — 13 idle hours, nothing else moved.
        XCTAssertEqual(eval(snap(family: .measuring, tier: "—"),
                            snap(takenAt: nowUnix, family: .nothingBurning, tier: "none")),
                       .silent, "the buffer filling and measuring a zero is not a verdict change")
        // 2026-09-01 22:58 and 23:00 local, Claude tab — relaunch out and back.
        XCTAssertEqual(eval(snap(family: .exhaustion, tier: "low"),
                            snap(takenAt: nowUnix, family: .measuring, tier: "—")),
                       .silent, "a relaunch emptying the buffer is not a verdict change")
        XCTAssertEqual(eval(snap(family: .measuring, tier: "—"),
                            snap(takenAt: nowUnix, family: .exhaustion, tier: "low")),
                       .silent, "nor is the buffer refilling two minutes later")
    }

    /// Muting trigger 3 mutes **only** trigger 3 — a `Measuring…` interval that also spawned a
    /// subagent or burned through the threshold still renders, minus the `verdict changed` token.
    func testMeasuringDoesNotMuteTheOtherTriggers() {
        XCTAssertEqual(eval(snap(used: 40, family: .measuring, agents: 0),
                            snap(takenAt: nowUnix, used: 46, family: .nothingBurning, agents: 1)),
                       .line("Since \(sinceClock): 1 subagent spawned · 6% burned"))
        XCTAssertEqual(eval(snap(used: 40, family: .measuring, visible: false),
                            snap(takenAt: nowUnix, used: 63, family: .exhaustion, visible: false)),
                       .line("Since \(sinceClock): 23% burned"))
    }

    /// Fixed token order, Δ% last as context (|Δ| ≥ 1) — the spec's first example.
    func testTokenOrderWithDeltaAsContext() {
        let line = eval(snap(used: 40, tier: "low", agents: 0),
                        snap(takenAt: nowUnix, used: 54, tier: "high", agents: 1))
        XCTAssertEqual(line, .line("Since \(sinceClock): 1 subagent spawned · burn low → high · 14% burned"))
        // Negative Δ uses the typographic minus; below 1% it is omitted.
        XCTAssertEqual(eval(snap(used: 40, family: .resetsFirst),
                            snap(takenAt: nowUnix, used: 38, family: .held)),
                       .line("Since \(sinceClock): verdict changed · 2% returned"))
        XCTAssertEqual(eval(snap(used: 40.2, family: .resetsFirst),
                            snap(takenAt: nowUnix, used: 40.6, family: .held)),
                       .line("Since \(sinceClock): verdict changed"))
    }

    /// Baseline §19 *delta-unseen*: Δ% alone fires only when the menu bar was not showing this
    /// tool's percentage — at the snapshot or now — and only at ≥ `deltaLinePctWhenUnseen`.
    func testDeltaAloneOnlyWhenMenuBarDidNotShowIt() {
        XCTAssertEqual(eval(snap(used: 40, visible: true), snap(takenAt: nowUnix, used: 63, visible: true)),
                       .silent, "the menu bar showed +23% happening")
        XCTAssertEqual(eval(snap(used: 40, visible: false), snap(takenAt: nowUnix, used: 63, visible: false)),
                       .line("Since \(sinceClock): 23% burned"))
        XCTAssertEqual(eval(snap(used: 40, visible: true), snap(takenAt: nowUnix, used: 63, visible: false)),
                       .line("Since \(sinceClock): 23% burned"), "hidden *now* counts too")
        XCTAssertEqual(eval(snap(used: 40, visible: false), snap(takenAt: nowUnix, used: 44, visible: false)),
                       .silent, "+4% is under the threshold")
        XCTAssertEqual(eval(snap(used: 40, visible: false), snap(takenAt: nowUnix, used: 45, visible: false)),
                       .line("Since \(sinceClock): 5% burned"), "at the threshold")
        XCTAssertEqual(eval(snap(used: nil, visible: false), snap(takenAt: nowUnix, used: 63, visible: false)),
                       .silent, "unknown → known is not a Δ")
    }

    /// Trigger 4 — window identity: wobble is not a boundary; nil vs non-nil is; and it wins.
    func testWindowBoundaryToleranceAndPrecedence() {
        XCTAssertEqual(eval(snap(), snap(takenAt: nowUnix, window: resetsAt + 30)), .silent)
        XCTAssertEqual(eval(snap(), snap(takenAt: nowUnix, window: resetsAt + 18_000)), .boundary)
        XCTAssertEqual(eval(snap(window: .some(nil)), snap(takenAt: nowUnix)), .boundary)
        XCTAssertEqual(eval(snap(), snap(takenAt: nowUnix, window: .some(nil))), .boundary)
        XCTAssertEqual(eval(snap(window: .some(nil)), snap(takenAt: nowUnix, window: .some(nil))), .silent)
        // Other tokens are dropped — they compare across windows and mean nothing.
        XCTAssertEqual(eval(snap(tier: "low", agents: 0),
                            snap(takenAt: nowUnix, window: resetsAt + 18_000, tier: "high", agents: 3)),
                       .boundary)
    }

    /// Trigger 7 (REV-68 amendment 2026-08-17, STEP_112a — Baseline §19 *delta-off-machine*): the
    /// off-machine share rose by ≥ the threshold — the one Δ the corner cannot show is *where* the
    /// burn came from. Only a rise, only at ≥ 5 (estimated, quantized, can settle downward);
    /// unknown on either side is not a rise; the token sits after the verdict, before Δ context.
    func testOffMachineRiseIsATrigger() {
        XCTAssertEqual(eval(snap(used: 45, off: 3), snap(takenAt: nowUnix, used: 59, off: 17)),
                       .line("Since \(sinceClock): +14% off-machine · 14% burned"),
                       "the Claude-web case: menu bar showed the %, not the source")
        XCTAssertEqual(eval(snap(used: 45, off: 3), snap(takenAt: nowUnix, used: 49, off: 7)),
                       .silent, "+4 is under the threshold")
        XCTAssertEqual(eval(snap(used: 45, off: 17), snap(takenAt: nowUnix, used: 45, off: 3)),
                       .silent, "a settle downward is not news")
        XCTAssertEqual(eval(snap(used: 45, off: nil), snap(takenAt: nowUnix, used: 59, off: 17)),
                       .silent, "unknown → known is not a rise")
        XCTAssertEqual(eval(snap(used: 45, family: .resetsFirst, off: 3),
                            snap(takenAt: nowUnix, used: 59, family: .held, off: 17)),
                       .line("Since \(sinceClock): verdict changed · +14% off-machine · 14% burned"))
    }

    /// D-98 (REV-78) retired `adaptive` / `compact_glyph` / `hidden`, so the only remaining way
    /// a tool's percentage goes unseen is the **other** tool's `_only` mode. The trigger itself
    /// is unchanged — that is the point of keeping this table.
    func testPctVisibleInMenuBarTable() {
        XCTAssertTrue(DeltaLine.pctVisibleInMenuBar(mode: .bothStacked, tool: .claude))
        XCTAssertTrue(DeltaLine.pctVisibleInMenuBar(mode: .bothStacked, tool: .codex))
        XCTAssertTrue(DeltaLine.pctVisibleInMenuBar(mode: .claudeOnly, tool: .claude))
        XCTAssertFalse(DeltaLine.pctVisibleInMenuBar(mode: .claudeOnly, tool: .codex))
        XCTAssertTrue(DeltaLine.pctVisibleInMenuBar(mode: .codexOnly, tool: .codex))
        XCTAssertFalse(DeltaLine.pctVisibleInMenuBar(mode: .codexOnly, tool: .claude))
    }

    // MARK: Boundary copy

    private var prevReset: Date { now.addingTimeInterval(-3_600) }
    private var prevClock: String { Fmt.clock(prevReset) }

    /// Baseline §19 *delta-boundary*: the previous window's high-water reading, on the new window.
    /// `[t]` is the current window's start (`resets_at − width`), never the previous window's
    /// reset — the two differ by the idle gap between them (STEP_112b: 8:20 pm vs 11:00 pm).
    func testBoundaryPopulatedEndedAtHighWater() {
        let outcome = WindowOutcome(resetsAt: prevReset, highWaterPct: 94, hitLimitAt: nil)
        // Previous reset 1 h ago; the new window was anchored 1 h after that (first request).
        let current = now.addingTimeInterval(18_000)
        let start = Fmt.clock(current.addingTimeInterval(-18_000))
        XCTAssertNotEqual(start, prevClock, "fixture: an idle gap separates the two windows")
        XCTAssertEqual(
            DeltaLine.boundaryLine(tool: .claude, outcome: outcome,
                                   currentResetsAt: current,
                                   currentWindowSeconds: 18_000, now: now),
            "New window since \(start) — last one ended at 94%")
    }

    /// Baseline §19 *delta-boundary-limit*: the first poll at or past 100 names the clock.
    func testBoundaryPopulatedHitTheLimit() {
        let hit = now.addingTimeInterval(-5_400)
        let outcome = WindowOutcome(resetsAt: prevReset, highWaterPct: 100, hitLimitAt: hit)
        let current = now.addingTimeInterval(14_400)
        XCTAssertEqual(
            DeltaLine.boundaryLine(tool: .codex, outcome: outcome,
                                   currentResetsAt: current,
                                   currentWindowSeconds: 18_000, now: now),
            "New window since \(Fmt.clock(current.addingTimeInterval(-18_000))) — last one hit the limit at \(Fmt.clock(hit))")
    }

    /// Previous window unknown (no `quota_series` rows): the plain form, dated from the current
    /// window's start — the only fact on hand.
    func testBoundaryPopulatedUnknownPrevious() {
        let current = now.addingTimeInterval(14_400)
        XCTAssertEqual(
            DeltaLine.boundaryLine(tool: .claude, outcome: nil, currentResetsAt: current,
                                   currentWindowSeconds: 18_000, now: now),
            "New window since \(Fmt.clock(current.addingTimeInterval(-18_000)))")
        // Width unknown ⇒ the 5-hour fallback.
        XCTAssertEqual(
            DeltaLine.boundaryLine(tool: .claude, outcome: nil, currentResetsAt: current,
                                   currentWindowSeconds: nil, now: now),
            "New window since \(Fmt.clock(current.addingTimeInterval(-18_000)))")
    }

    /// Baseline §19 *delta-fresh-null*: Claude states the fact once beside REV-46; 5-hour Codex
    /// does the same since REV-82 (the retrospective grain exists there now); a Codex window of
    /// any other width has no retrospective grain and takes the plain form (Part 2 §2.10); no
    /// previous window → nothing.
    func testBoundaryFreshNullForms() {
        let outcome = WindowOutcome(resetsAt: prevReset, highWaterPct: 61, hitLimitAt: nil)
        XCTAssertEqual(
            DeltaLine.boundaryLine(tool: .claude, outcome: outcome, currentResetsAt: nil,
                                   currentWindowSeconds: nil, now: now),
            "Last window ended at 61% — reset \(prevClock)")
        XCTAssertEqual(
            DeltaLine.boundaryLine(tool: .codex, outcome: outcome, currentResetsAt: nil,
                                   currentWindowSeconds: 18_000, now: now),
            "Last window ended at 61% — reset \(prevClock)")
        XCTAssertEqual(
            DeltaLine.boundaryLine(tool: .codex, outcome: outcome, currentResetsAt: nil,
                                   currentWindowSeconds: nil, now: now),
            "New window since \(prevClock)")
        XCTAssertEqual(
            DeltaLine.boundaryLine(tool: .codex, outcome: outcome, currentResetsAt: nil,
                                   currentWindowSeconds: 30 * 86_400, now: now),
            "New window since \(prevClock)")
        XCTAssertNil(DeltaLine.boundaryLine(tool: .claude, outcome: nil, currentResetsAt: nil,
                                            currentWindowSeconds: nil, now: now))
    }

    // MARK: Snapshot persistence + clock

    func testSnapshotJSONRoundTripAndKeys() throws {
        let s = snap(takenAt: nowUnix, window: .some(nil), used: nil, family: .nullWindow, tier: "—",
                     agents: 2, visible: false)
        let json = s.encoded()
        XCTAssertEqual(LastOpenSnapshot(json: json), s)
        // The §17.1 field names, verbatim.
        for key in ["taken_at", "window_resets_at", "used_pct", "verdict_family", "burn_tier",
                    "agent_count", "pct_visible_in_menu_bar"] {
            XCTAssertTrue(json.contains("\"\(key)\""), key)
        }
        // A row written before the off-machine field existed reads as unknown, not as corrupt.
        let legacy = LastOpenSnapshot(json: """
            {"agent_count":0,"burn_tier":"low","pct_visible_in_menu_bar":true,"taken_at":1,\
            "used_pct":77,"verdict_family":"exhaustion","window_resets_at":2}
            """)
        XCTAssertNotNil(legacy)
        XCTAssertNil(legacy?.offMachinePct)
        XCTAssertTrue(json.contains("\"off_machine_pct\""))
        XCTAssertNil(LastOpenSnapshot(json: "not json"))
        XCTAssertNil(LastOpenSnapshot(json: "{\"taken_at\": \"soon\"}"))
        XCTAssertEqual(LastOpenSnapshot.settingsKey(.claude), "last_open_snapshot_claude")
        XCTAssertEqual(LastOpenSnapshot.settingsKey(.codex), "last_open_snapshot_codex")
        // Sorted keys — same content, same bytes (so `writeSetting` can skip the no-op).
        XCTAssertEqual(json, LastOpenSnapshot(json: json)?.encoded())
    }

    /// `[t]` — the past-facing clock: same day bare, previous day `yesterday …`, older `Mon d, …`.
    func testClockDayPastForms() {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: 15, minute: 12, second: 0, of: now)!
        XCTAssertEqual(Fmt.clockDayPast(today.addingTimeInterval(-60), from: today), "3:11 pm")
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        XCTAssertEqual(Fmt.clockDayPast(yesterday, from: today), "yesterday 3:12 pm")
        let older = cal.date(byAdding: .day, value: -3, to: today)!
        XCTAssertEqual(Fmt.clockDayPast(older, from: today), "\(Fmt.monthDay(older)), 3:12 pm")
    }

    // MARK: Trigger 6 — window facts (REV-69 / STEP_146)

    private func change(_ kind: HistoryReport.AccountChange.Kind, type: String? = nil,
                        old: String? = nil, new: String? = nil) -> HistoryReport.AccountChange {
        HistoryReport.AccountChange(at: now, kind: kind, windowType: type, oldValue: old,
                                    newValue: new)
    }

    /// The tokens, folded like History's rows: a same-instant width change + window added is one
    /// token; plan changes are not window facts.
    func testWindowFactTokensAreFoldedAndNamedByWidth() {
        XCTAssertEqual(DeltaLine.windowFactTokens([
            change(.windowAdded, type: "weekly", new: "604800"),
            change(.windowWidthChanged, type: "five_hour", old: "604800", new: "18000"),
            change(.planChanged, old: "go", new: "plus"),
        ]), ["windows now 5-hour + weekly (was weekly)"])
        XCTAssertEqual(DeltaLine.windowFactTokens([
            change(.windowRemoved, type: "five_hour", old: "18000"),
            change(.earlyReset, type: "weekly"),
            change(.windowWidthChanged, type: "5_day", old: "604800", new: "432000"),
        ]), ["5-hour window removed", "weekly window reset early",
             "weekly window now 120-hour"])
    }

    /// A fact alone fires the line, leads it, and keeps the Δ context after it.
    func testAWindowFactFiresTheLineAndLeadsIt() {
        let facts = ["weekly window added"]
        XCTAssertEqual(DeltaLine.evaluate(previous: snap(), current: snap(takenAt: nowUnix, used: 43),
                                          tool: .codex, now: now, windowFacts: facts),
                       .line("Since \(sinceClock): weekly window added · 3% burned"))
        XCTAssertEqual(DeltaLine.evaluate(previous: snap(), current: snap(takenAt: nowUnix),
                                          tool: .codex, now: now, windowFacts: facts),
                       .line("Since \(sinceClock): weekly window added"))
    }

    /// The boundary form still wins the gate, and the caller appends the facts to its copy — a
    /// restructuring is itself a boundary, and the plain "New window since" would hide the news.
    func testABoundaryKeepsTheFactsAfterItsOwnCopy() {
        let facts = ["windows now 5-hour + weekly (was weekly)"]
        XCTAssertEqual(DeltaLine.evaluate(previous: snap(), current: snap(takenAt: nowUnix,
                                                                          window: resetsAt + 20_000),
                                          tool: .codex, now: now, windowFacts: facts), .boundary)
        XCTAssertEqual(DeltaLine.appendingFacts("New window since 4:15 pm", facts),
                       "New window since 4:15 pm · windows now 5-hour + weekly (was weekly)")
        XCTAssertEqual(DeltaLine.appendingFacts(nil, facts),
                       "windows now 5-hour + weekly (was weekly)")
        XCTAssertNil(DeltaLine.appendingFacts(nil, []))
    }
}
