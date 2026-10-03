import Foundation
import KvotarCore

/// The "Since you last looked" lifecycle (UI Spec Part 1 §2.8 / Part 2 §2.10, D-75 — STEP_112).
/// Displaying a tab *is* the look: the snapshot is taken (and persisted) whenever a tab is shown —
/// popover open, tab switch, notification-open landing — and compared with the one before it. The
/// line renders only when the §2.8 gate passes, sits as row 0 above that tab's header, never
/// live-updates, and is consumed by the display that produced it: the next display of the same tab
/// compares against a fresh snapshot, so it never repeats. Pure logic lives in `DeltaLine`.
extension AppViewModel {

    /// The tab `tool` is being displayed now. Called by `selectDefaultTab` (every open) and by
    /// `selectTab` (a real switch). Snapshots only when the tool has a render — the loading card,
    /// the welcome view and the idle card show nothing worth remembering, and keeping the previous
    /// snapshot means the next real look still compares against the last real look.
    func noteTabDisplayed(_ tool: Tool, now: Date) {
        deltaLineGeneration[tool, default: 0] += 1
        deltaLines[tool] = nil
        // The controller refreshes freshness *after* choosing the tab; render first so the family
        // and pill read from the same instant as the degraded window.
        renderDisplay(tool: tool, now: now)
        guard let inputs = snapshotInputs(for: tool, now: now) else { return }

        let header: HeaderSection?
        let pill: String?
        switch tool {
        case .claude: header = claudeState.header
        case .codex:  header = codexState.header
        }
        // The burn tier moved from the retired burn card onto the header fact (STEP_178); the
        // §2.8 trigger compares the same word it always did.
        pill = header?.accountBurn?.tier
        // The render's family, not the drawn row's (D-123 — STEP_207): a not-started window draws
        // no verdict, and reading the absence as `unknown` would put this render in the silent set
        // and delete the one line written for exactly that moment — `Last window ended at [N]%`,
        // the boundary form under a five-hour rollover.
        let family = header?.verdictFamily
        let current = LastOpenSnapshot(
            takenAt: Int(now.timeIntervalSince1970),
            windowResetsAt: inputs.snapshot.primaryResetsAt.map { Int($0.timeIntervalSince1970) },
            usedPct: inputs.snapshot.primaryUsedPct,
            verdictFamily: (family ?? .unknown).rawValue,
            burnTier: pill ?? "—",
            agentCount: tool == .claude ? (inputs.attribution?.subagentCount ?? 0)
                                        : (inputs.attribution?.sessionCount ?? 0),
            pctVisibleInMenuBar: DeltaLine.pctVisibleInMenuBar(mode: menuBarDisplayMode, tool: tool),
            offMachinePct: inputs.offMachinePct)

        let previous = lastOpenSnapshot[tool]
        lastOpenSnapshot[tool] = current
        onPersistLastOpenSnapshot?(tool, current.encoded())

        // Absent snapshot (first ever open of this tab, or a reset database) → no line.
        guard let previous else { return }
        // Never on a stale render, a freeze (`reconnecting` / `signInExpired`), `——` (`unknown`)
        // or the idle placeholder — those states own the top of the popover already (the loading
        // card and welcome never reach here). A fresh `nullWindow` render is fine: it is where the
        // "Last window ended at [N]%" form lives.
        guard !inputs.stale, let family, !Self.silentFamilies.contains(family) else { return }

        let generation = deltaLineGeneration[tool]
        let resetsAt = inputs.snapshot.primaryResetsAt
        let width = inputs.snapshot.primaryWindowSeconds
        // Trigger 6 (STEP_146) needs the recorded window facts since the last look — one local
        // read after the open, like the boundary form's. Without a loader the path is the
        // synchronous one it always was.
        guard let loadWindowFacts else {
            applyDeltaDecision(tool: tool, previous: previous, current: current, facts: [],
                               resetsAt: resetsAt, width: width, generation: generation, now: now)
            return
        }
        let since = Date(timeIntervalSince1970: TimeInterval(previous.takenAt))
        Task { @MainActor [weak self] in
            let facts = DeltaLine.windowFactTokens(await loadWindowFacts(tool, since))
            guard let self, self.deltaLineGeneration[tool] == generation else { return }
            self.applyDeltaDecision(tool: tool, previous: previous, current: current, facts: facts,
                                    resetsAt: resetsAt, width: width, generation: generation,
                                    now: now)
        }
    }

    /// The gate, then the copy. `facts` are the trigger-6 tokens (already folded); the boundary
    /// form gets them appended after its own read.
    private func applyDeltaDecision(tool: Tool, previous: LastOpenSnapshot,
                                    current: LastOpenSnapshot, facts: [String],
                                    resetsAt: Date?, width: Int?, generation: Int?, now: Date) {
        let decision = DeltaLine.evaluate(previous: previous, current: current, tool: tool,
                                          now: now, windowFacts: facts)
        Logger.debug("Since-you-last-looked evaluated", component: .appLifecycle,
                     metadata: ["tool": tool.rawValue, "decision": "\(decision)",
                                "agents": "\(previous.agentCount)→\(current.agentCount)",
                                "tier": "\(previous.burnTier)→\(current.burnTier)",
                                "family": "\(previous.verdictFamily)→\(current.verdictFamily)",
                                "facts": "\(facts.count)",
                                "off": "\(previous.offMachinePct.map { "\($0)" } ?? "nil")→\(current.offMachinePct.map { "\($0)" } ?? "nil")"])
        switch decision {
        case .silent:
            return
        case .line(let text):
            deltaLines[tool] = text
        case .boundary:
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.loadWindowOutcome?(tool, resetsAt)
                // The read is local, but the popover may have closed or moved on meanwhile.
                guard self.deltaLineGeneration[tool] == generation else { return }
                let text = DeltaLine.appendingFacts(DeltaLine.boundaryLine(
                    tool: tool, outcome: outcome, currentResetsAt: resetsAt,
                    currentWindowSeconds: width, now: now), facts)
                Logger.debug("Since-you-last-looked boundary", component: .appLifecycle,
                             metadata: ["tool": tool.rawValue, "line": text ?? "nil",
                                        "outcome": outcome.map { "\($0)" } ?? "nil"])
                self.deltaLines[tool] = text
            }
        }
    }

    /// Families whose render never carries the line (§2.8 "Never while…").
    static let silentFamilies: Set<VerdictFamily> = [.unknown, .reconnecting, .signInExpired, .idle]

    /// `✕` (or a click anywhere on the band): gone for this open.
    public func dismissDeltaLine(_ tool: Tool) {
        deltaLines[tool] = nil
    }

    /// The popover closed — the lines disappear with it, and no in-flight boundary read may land.
    public func popoverDidClose() {
        for tool in Tool.allCases { deltaLineGeneration[tool, default: 0] += 1 }
        deltaLines = [:]
    }

    /// Composition-root seed at launch: the persisted snapshot for `tool`, if any. Fills only an
    /// empty slot — a seed arriving after an open already took a snapshot must not clobber it.
    public func seedLastOpenSnapshot(tool: Tool, json: String) {
        guard lastOpenSnapshot[tool] == nil, let snapshot = LastOpenSnapshot(json: json) else { return }
        lastOpenSnapshot[tool] = snapshot
    }
}
