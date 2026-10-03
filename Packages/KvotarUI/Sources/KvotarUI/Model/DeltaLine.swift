import Foundation
import KvotarCore

// "Since you last looked" — UI Spec Part 1 §2.8 / Part 2 §2.10 (REV-68, D-75 — STEP_112).
//
// One data-tier line above the header, rendered on open only when something the menu bar could
// not have shown has changed since this tool's tab was last displayed: a subagent / thread
// spawned, the burn tier rose (D-85 — a fall is not news), the verdict family changed, or a
// window boundary was crossed.
// Δ% is context (last, signed) and a trigger only when the menu bar was not showing that tool's
// percentage. Everything here is pure: the snapshot value, the noise gate, and the copy grammar.
// The view model owns the lifecycle (`AppViewModel+DeltaLine.swift`); persistence is one
// `settings` row per tool, JSON, overwritten on every display.
//
// Trigger 6 (REV-69 window facts — STEP_146): the `discontinuity_events` window rows dated after
// the snapshot, read by the view model (one local read after the open, like the boundary form)
// and folded to tokens by `windowFactTokens`. A fact survives the window-boundary form: a
// restructuring *is* a boundary, and "New window since 4:15 pm" alone would hide the news.

/// What the tab showed the last time it was displayed — the seven §2.8 fields, persisted as JSON
/// under `settings.last_open_snapshot_<tool>`. Timestamps are unix seconds (`Int`, PATTERNS.md).
public struct LastOpenSnapshot: Codable, Sendable, Equatable {
    public let takenAt: Int
    /// Window identity — `primaryResetsAt`; nil on a null window.
    public let windowResetsAt: Int?
    /// `primaryUsedPct` as shown; nil when unknown.
    public let usedPct: Double?
    /// The §2.2a row `headerVerdict` chose (`VerdictFamily.rawValue`), not the rendered string.
    public let verdictFamily: String
    /// The §2.4 pill: `none` / `low` / `mid` / `high` / `—`.
    public let burnTier: String
    /// Claude: subagent count (§2.4 `Local source`); Codex: `Threads` (§2.6).
    public let agentCount: Int
    /// Whether the menu-bar display mode showed this tool's percentage at that moment.
    public let pctVisibleInMenuBar: Bool
    /// The §2.4 `Off-machine` share of the window (`WindowAttribution.offMachinePct`, whole
    /// window %); nil when the recompute had nothing to say (no window, stale render, monthly
    /// layout). *(REV-68 amendment 2026-08-17 — STEP_112a: the one Δ the corner cannot show is
    /// where the burn came from.)*
    public let offMachinePct: Double?

    enum CodingKeys: String, CodingKey {
        case takenAt = "taken_at"
        case windowResetsAt = "window_resets_at"
        case usedPct = "used_pct"
        case verdictFamily = "verdict_family"
        case burnTier = "burn_tier"
        case agentCount = "agent_count"
        case pctVisibleInMenuBar = "pct_visible_in_menu_bar"
        case offMachinePct = "off_machine_pct"
    }

    public init(takenAt: Int, windowResetsAt: Int?, usedPct: Double?, verdictFamily: String,
                burnTier: String, agentCount: Int, pctVisibleInMenuBar: Bool,
                offMachinePct: Double? = nil) {
        self.takenAt = takenAt
        self.windowResetsAt = windowResetsAt
        self.usedPct = usedPct
        self.verdictFamily = verdictFamily
        self.burnTier = burnTier
        self.agentCount = agentCount
        self.pctVisibleInMenuBar = pctVisibleInMenuBar
        self.offMachinePct = offMachinePct
    }

    /// Rows written before STEP_112a carry no `off_machine_pct`; read them as unknown.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        takenAt = try c.decode(Int.self, forKey: .takenAt)
        windowResetsAt = try c.decodeIfPresent(Int.self, forKey: .windowResetsAt)
        usedPct = try c.decodeIfPresent(Double.self, forKey: .usedPct)
        verdictFamily = try c.decode(String.self, forKey: .verdictFamily)
        burnTier = try c.decode(String.self, forKey: .burnTier)
        agentCount = try c.decode(Int.self, forKey: .agentCount)
        pctVisibleInMenuBar = try c.decode(Bool.self, forKey: .pctVisibleInMenuBar)
        offMachinePct = try c.decodeIfPresent(Double.self, forKey: .offMachinePct)
    }

    /// Explicit `null` for the two nullable fields — the persisted row carries all seven §17.1
    /// keys every time (the synthesized encoder would drop an absent optional).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(takenAt, forKey: .takenAt)
        try c.encode(windowResetsAt, forKey: .windowResetsAt)
        try c.encode(usedPct, forKey: .usedPct)
        try c.encode(verdictFamily, forKey: .verdictFamily)
        try c.encode(burnTier, forKey: .burnTier)
        try c.encode(agentCount, forKey: .agentCount)
        try c.encode(pctVisibleInMenuBar, forKey: .pctVisibleInMenuBar)
        try c.encode(offMachinePct, forKey: .offMachinePct)
    }

    /// `settings` key (Baseline §17.1): `last_open_snapshot_claude` / `last_open_snapshot_codex`.
    public static func settingsKey(_ tool: Tool) -> String { "last_open_snapshot_\(tool.rawValue)" }

    /// The persisted form. Sorted keys so an unchanged snapshot is a byte-identical string —
    /// `writeSetting` skips no-op writes, and only that keeps a same-second re-display from
    /// costing an audit row.
    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// nil on anything undecodable — a corrupt row reads as "absent snapshot" (no line, rewritten).
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LastOpenSnapshot.self, from: data)
        else { return nil }
        self = decoded
    }
}

/// The noise gate and the copy grammar (§2.8), as pure functions.
public enum DeltaLine {

    /// `deltaLinePctWhenUnseen` (UI Spec Part 1 §5): Δ% is a trigger only when the menu bar was
    /// not showing this tool's percentage, and then only at or past this. Dogfood-tune.
    public static let pctWhenUnseen: Double = 5

    /// Reset stamps wobble by a second or two between polls; the same tolerance the
    /// `quota_series` reads use, so a wobble never reads as a new window.
    static let resetJitterTolerance = 60

    /// Verdict families that never count as a change, in either direction — the line is not a
    /// second stale banner. `nullWindow` (No active session), `unknown` (`——`), `reconnecting`,
    /// `signInExpired`, and `idle` (the grey `—` of a stale-kept render).
    ///
    /// **`measuring` joined them 2026-09-03 (REV-68 amendment / D-110 — STEP_164).** `Measuring…`
    /// is a statement about *our own* forecast buffer — the §11.2a rule that an unresolved burn is
    /// `nil`, not zero — and the buffer starts empty on every launch, so the family is reachable
    /// almost only by relaunching. Every crossing observed in dogfood was that: `exhaustion →
    /// measuring` on a relaunch open, `measuring → exhaustion` two minutes later when the buffer
    /// filled, and `measuring → nothingBurning` after a 13-hour idle stretch (2026-09-02 23:46
    /// local, Codex tab, nothing else moved) — three `verdict changed` banners for news that never
    /// happened to the user's quota. **Accepted loss:** a real verdict arriving out of `Measuring…`
    /// is no longer announced here; it is the header's own line one row below, unmissable.
    ///
    /// **`notStarted` joined them 2026-09-15 (D-123 — STEP_207)** on the same argument as
    /// `nullWindow`, which it splits off from: it is a statement about whether a window exists,
    /// and trigger 4 above already reports that as a boundary — from the window's own anchor,
    /// with the outcome of the one that ended. Left in, every rollover would say
    /// `verdict changed` twice (into the shape, then out of it two minutes later) beside a line
    /// that has already said it better.
    static let excludedFamilies: Set<String> = [
        VerdictFamily.nullWindow.rawValue, VerdictFamily.unknown.rawValue,
        VerdictFamily.reconnecting.rawValue, VerdictFamily.signInExpired.rawValue,
        VerdictFamily.idle.rawValue, VerdictFamily.measuring.rawValue,
        VerdictFamily.notStarted.rawValue,
    ]

    /// Whether `mode` shows `tool`'s percentage in the menu bar (§2.8 snapshot table):
    /// `both_stacked` / this tool's `_only` → true; the **other** tool's `_only` → false.
    ///
    /// D-98 (REV-78) retired `adaptive`, `compact_glyph` and `hidden`, so a single-tool mode is
    /// now the only way a tool's percentage goes unseen. The D-75 Δ%-alone trigger and
    /// `pctWhenUnseen` are unchanged — only the reachable false-set narrowed. Snapshots persisted
    /// by an older build with `pct_visible_in_menu_bar: false` stay decodable and compare
    /// correctly, which is why nothing rewrites them.
    public static func pctVisibleInMenuBar(mode: MenuBarDisplayMode, tool: Tool) -> Bool {
        switch mode {
        case .bothStacked: return true
        case .claudeOnly: return tool == .claude
        case .codexOnly: return tool == .codex
        }
    }

    /// The gate's verdict for one display.
    public enum Decision: Equatable {
        /// Nothing the menu bar could not have shown changed.
        case silent
        /// The line, ready to render.
        case line(String)
        /// A window boundary — the copy needs the previous window's outcome (`quota_series`);
        /// see `boundaryLine`. Trigger 4 wins; every other token is dropped.
        case boundary
    }

    /// The §2.8 noise gate over two snapshots of the same tool. `current` is the snapshot just
    /// taken (its `takenAt` is "now"); `previous` is what the tab showed last time.
    public static func evaluate(previous: LastOpenSnapshot, current: LastOpenSnapshot,
                                tool: Tool, now: Date, windowFacts: [String] = []) -> Decision {
        // Trigger 4 — window identity differs (nil vs non-nil counts; wobble does not). The
        // caller appends `windowFacts` to the boundary copy (`appendingFacts`).
        if windowChanged(previous.windowResetsAt, current.windowResetsAt) { return .boundary }

        // Trigger 6 — recorded window facts, first: they are the biggest news on the line.
        var tokens: [String] = windowFacts
        // Trigger 1 — agent count rose.
        let rise = current.agentCount - previous.agentCount
        if rise > 0 { tokens.append(agentToken(rise, tool: tool)) }
        // Trigger 2 — the burn tier **rose** (REV-74/D-85 — STEP_123). A fall is silent: this line
        // exists for what the menu bar could not show and the user would want to know they missed,
        // and burn falling is the resting state arriving — `burn low → none` above a card whose pill
        // reads `none` is one fact twice, and reads as a nonsense scale besides. A rise then a fall
        // inside one interval (a thread that ran and finished) is the common case and stays silent:
        // the tiers at the two ends are what is compared, as before. `—` is excluded by having no
        // rank (unknown → known is not a change).
        if let was = tierRank(previous.burnTier), let now = tierRank(current.burnTier), now > was {
            tokens.append("burn \(visibleTier(previous.burnTier)) → \(visibleTier(current.burnTier))")
        }
        // Trigger 3 — verdict family changed, excluded families on neither side.
        if previous.verdictFamily != current.verdictFamily,
           !excludedFamilies.contains(previous.verdictFamily),
           !excludedFamilies.contains(current.verdictFamily) {
            tokens.append("verdict changed")
        }
        // Trigger 7 (REV-68 amendment, STEP_112a) — the off-machine share rose by at least the
        // threshold: the corner shows how much burned, never *where*. Estimated and quantized, so
        // only a rise counts, and only at ≥ `pctWhenUnseen` (the recompute can settle downward).
        if let a = previous.offMachinePct, let b = current.offMachinePct {
            let rise = (b - a).rounded()
            if rise >= pctWhenUnseen { tokens.append("+\(Int(rise))% off-machine") }
        }
        // Δ% — context whenever the line renders (|Δ| ≥ 1); a trigger only when the menu bar was
        // not showing this tool's percentage at the snapshot or now, at ≥ `pctWhenUnseen`.
        let delta = deltaPct(previous.usedPct, current.usedPct)
        let unseen = !previous.pctVisibleInMenuBar || !current.pctVisibleInMenuBar
        if tokens.isEmpty {
            guard unseen, let delta, abs(delta) >= pctWhenUnseen else { return .silent }
        }
        if let delta, abs(delta) >= 1 { tokens.append(deltaToken(delta)) }
        return .line(line(since: previous.takenAt, tokens: tokens, now: now))
    }

    /// The persisted lowest-band key predates REV-94. Keep it decodable and ordered, but never
    /// expose the retired `none` vocabulary in new UI.
    private static func visibleTier(_ tier: String) -> String {
        tier == "none" ? "very low" : tier
    }

    /// The window-boundary copy (§2.8 "Window-boundary form"). `outcome` is the previous window as
    /// `quota_series` recorded it (nil when unknown); `currentResetsAt` / `currentWindowSeconds`
    /// describe the current window when populated (nil ⇒ fresh provider-null). Returns nil where
    /// the spec has no line (fresh-null with no previous window on record).
    public static func boundaryLine(tool: Tool, outcome: WindowOutcome?, currentResetsAt: Date?,
                                    currentWindowSeconds: Int?, now: Date) -> String? {
        if let currentResetsAt {
            // The window starts on the first request after the previous reset, not at the reset
            // itself (an idle gap in between is the common case — evenings, overnight), so the
            // start is always the current window's own anchor: `resets_at − width`. The previous
            // window's reset stamp is never the answer here (STEP_112b).
            let width = TimeInterval(currentWindowSeconds ?? 18_000)
            let start = currentResetsAt.addingTimeInterval(-width)
            let since = "New window since \(Fmt.clockDayPast(start, from: now))"
            guard let outcome else { return since }   // previous window unknown — the only fact
            if let hit = outcome.hitLimitAt {
                return "\(since) — last one hit the limit at \(Fmt.clockDayPast(hit, from: now))"
            }
            return "\(since) — last one ended at \(Fmt.percent(outcome.highWaterPct))"
        }
        // Fresh provider-null: no new window has started.
        guard let outcome else { return nil }
        let reset = Fmt.clockDayPast(outcome.resetsAt, from: now)
        switch tool {
        case .claude:
            // REV-46 territory — the retrospective sections carry the detail; one line here
            // (a window that hit the limit reads "ended at 100%" — the spec has one form).
            return "Last window ended at \(Fmt.percent(outcome.highWaterPct)) — reset \(reset)"
        case .codex where currentWindowSeconds == 18_000:
            // The retrospective grain now exists on 5-hour Codex too (REV-82 — STEP_151), under
            // the same width gate the sections use; same one-line form.
            return "Last window ended at \(Fmt.percent(outcome.highWaterPct)) — reset \(reset)"
        case .codex:
            // No retrospective grain on a non-5-hour Codex window → the plain form.
            return "New window since \(reset)"
        }
    }

    /// The boundary line with the window facts after it — `New window since 4:15 pm · windows now
    /// 5-hour + weekly (was weekly)`. `nil` stays `nil` only when there are no facts either.
    public static func appendingFacts(_ line: String?, _ facts: [String]) -> String? {
        guard !facts.isEmpty else { return line }
        let tail = facts.joined(separator: " · ")
        return line.map { "\($0) · \(tail)" } ?? tail
    }

    /// The §2.8 trigger-6 tokens for the recorded window facts, folded like History's *What
    /// changed* rows (`HistoryDisplay.changeEntries`, STEP_141) so a restructuring is one token:
    /// `windows now 5-hour + weekly (was weekly)` · `weekly window now 5-day` · `weekly window
    /// added` · `5-hour window removed` · `weekly window reset early`. Widths by name (D-58),
    /// never a size. Plan changes are not window facts and are skipped.
    public static func windowFactTokens(_ changes: [HistoryReport.AccountChange]) -> [String] {
        HistoryDisplay.changeEntries(changes).compactMap { entry in
            switch entry {
            case .restructured(_, let before, let after):
                let was = before.compactMap { DisplayFormatter.windowGrain(seconds: $0)?.lowercased() }
                let wasClause = was.isEmpty ? "" : " (was \(was.joined(separator: " + ")))"
                return "windows now \(HistoryDisplay.widthList(after))\(wasClause)"
            case .single(let change):
                let grain = HistoryDisplay.grainName(change.windowType)
                let noun = { (g: String?) in HistoryDisplay.windowNoun(g) }
                switch change.kind {
                case .planChanged:
                    return nil
                case .windowWidthChanged:
                    let old = noun(HistoryDisplay.widthName(change.oldValue) ?? grain)
                    let new = HistoryDisplay.widthName(change.newValue) ?? "a new length"
                    return "\(old) now \(new)"
                case .windowAdded:
                    return "\(noun(HistoryDisplay.widthName(change.newValue) ?? grain)) added"
                case .windowRemoved:
                    return "\(noun(HistoryDisplay.widthName(change.oldValue) ?? grain)) removed"
                case .earlyReset:
                    return "\(noun(grain)) reset early"
                }
            }
        }
    }

    // MARK: Pieces

    /// The §2.4 pill words, calmest first — the scale trigger 2 compares along. Kept beside the
    /// grammar that prints them rather than in the view model, which only forwards the word
    /// `DisplayFormatter.burnTier` produced.
    static let tierOrder = ["none", "low", "mid", "high"]

    /// `nil` for `—` and for anything not on the scale (a pill word that is not one of the four
    /// cannot be said to have risen).
    static func tierRank(_ tier: String) -> Int? { tierOrder.firstIndex(of: tier) }

    static func windowChanged(_ a: Int?, _ b: Int?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case let (x?, y?): return abs(x - y) > resetJitterTolerance
        default: return true
        }
    }

    /// Whole-percent Δ, nil when either side is unknown.
    static func deltaPct(_ from: Double?, _ to: Double?) -> Double? {
        guard let from, let to else { return nil }
        return (to - from).rounded()
    }

    static func agentToken(_ n: Int, tool: Tool) -> String {
        switch tool {
        case .claude: return n == 1 ? "1 subagent spawned" : "\(n) subagents spawned"
        case .codex:  return n == 1 ? "1 thread started" : "\(n) threads started"
        }
    }

    /// `14% burned` / `3% returned` (REV-77 / D-97 addendum, 2026-08-23). The token was a bare
    /// signed figure (`+14%` / `−3%`), correct as a delta — but once every level on the screen
    /// reads *left*, a bare `+13%` no longer says which direction it means (it read as "13% more
    /// left"). The word carries the direction now; the sign is dropped. A negative delta —
    /// utilization settling downward without a window boundary — reads `returned`.
    static func deltaToken(_ delta: Double) -> String {
        let n = Int(delta)
        return n < 0 ? "\(-n)% returned" : "\(n)% burned"
    }

    static func line(since takenAt: Int, tokens: [String], now: Date) -> String {
        let t = Fmt.clockDayPast(Date(timeIntervalSince1970: TimeInterval(takenAt)), from: now)
        return "Since \(t): \(tokens.joined(separator: " · "))"
    }
}
