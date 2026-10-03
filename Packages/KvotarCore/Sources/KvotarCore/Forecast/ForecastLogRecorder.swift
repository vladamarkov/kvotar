import Foundation

/// One `forecast_log` row, fully derived (§17.1, STEP_51) — `SQLiteStore.writeForecastLog`
/// persists it verbatim.
///
/// **The "deliberately absent" clause, amended not repealed** *(STEP_188 — REV-95 §3.2)*. The
/// verdict template stays out: it is a derived conclusion that goes stale the day the copy changes
/// (§17 substrate principle). `displayedState` is not that. It is a fact about what the user saw,
/// which no later threshold can recompute and which `state_transitions` cannot supply past its
/// 90-day retention — and Spike D F13 is why it has to be recorded: the owner slows down when
/// warned, so a prediction made while a warning was on screen must be graded on its own
/// scoreboard. It is the **post-hysteresis engine state this evaluation resolved to**, not a claim
/// about pixels: a stale or frozen render forks its copy downstream and this column does not
/// follow it.
public struct ForecastLogEntry: Sendable, Equatable {

    /// Which §11.4 phase the forecast math ran in — the cold-start axis, not `ForecastTier`.
    public enum Tier: String, Sendable {
        case coldStart = "cold_start"
        case partial
        case full
    }

    /// Why the row was written: the 5-min sampling clock, or a state transition (which is
    /// always worth grading and bypasses the clock).
    public enum Trigger: String, Sendable {
        case sample
        case stateChange = "state_change"
    }

    public let tool: Tool
    public let computedAt: Date
    public let primaryUsedPct: Double?
    public let secondaryUsedPct: Double?
    /// Quantized §11.2a burn, unrounded — always the **18-minute rate**, whichever rate the
    /// runway used (REV-105 §2.4). `nil` = unmeasured; `0.0` = measured zero.
    public let burnRatePctPerMin: Double?
    /// Predicted exhaustion instant, as displayed — from the rate the forecast chose (REV-105
    /// §2.4). `nil` when burn ≈ 0 or unmeasured — a null prediction is itself gradable ("app
    /// claimed nothing was burning").
    public let etaTo100: Date?
    public let primaryResetsAt: Date?
    public let forecastTier: Tier
    public let trigger: Trigger
    public let appVersion: String
    /// The §13 state as displayed when the row was written — `StateEvaluation.state`, i.e. after
    /// the §13.4 de-escalation hysteresis, whose raw value is the `state_transitions.to_state`
    /// vocabulary a grader already reads.
    public let displayedState: AppState
    /// The first instant a warning-tier state (`AppState.warningStates`) was displayed in the
    /// **current primary-window instance**; nil while none has been. Set once and never
    /// overwritten — a calmer state does not clear it and a worse warning does not replace it —
    /// and dropped when the window instance ends, never inherited by the next one.
    ///
    /// **On a relaunch it is a lower bound.** The latch is in-memory, so a window that had already
    /// warned before the app restarted is stamped at the first evaluation of the new process. The
    /// *exposure flag* (nil versus set) stays correct for every row — rows written before the
    /// relaunch carry the old process's own stamp — and only the derived
    /// `computed_at − warningFirstShownAt` duration is short, in that one known direction.
    public let warningFirstShownAt: Date?
    /// The §11.5 shadow outputs for this evaluation, or nil where the rule could say nothing
    /// (STEP_190). A nil shadow writes five NULLs — itself a gradable record of "the app had no
    /// second opinion here" — and is never filled in from a previous evaluation (REV-54 §7).
    public let shadow: ShadowForecast?

    public init(
        tool: Tool,
        computedAt: Date,
        primaryUsedPct: Double?,
        secondaryUsedPct: Double?,
        burnRatePctPerMin: Double?,
        etaTo100: Date?,
        primaryResetsAt: Date?,
        forecastTier: Tier,
        trigger: Trigger,
        appVersion: String,
        displayedState: AppState,
        warningFirstShownAt: Date?,
        shadow: ShadowForecast? = nil
    ) {
        self.tool = tool
        self.computedAt = computedAt
        self.primaryUsedPct = primaryUsedPct
        self.secondaryUsedPct = secondaryUsedPct
        self.burnRatePctPerMin = burnRatePctPerMin
        self.etaTo100 = etaTo100
        self.primaryResetsAt = primaryResetsAt
        self.forecastTier = forecastTier
        self.trigger = trigger
        self.appVersion = appVersion
        self.displayedState = displayedState
        self.warningFirstShownAt = warningFirstShownAt
        self.shadow = shadow
    }
}

/// Decides, per §13 evaluation, whether a `forecast_log` row is due — ≥ `sampleInterval` since
/// this tool's last row (`trigger = "sample"`), or a state transition bypassing the clock
/// (`trigger = "state_change"`) — and builds the row (§17.1, STEP_51). The clock is in-memory
/// only: a duplicate first row after relaunch is harmless data, not a bug.
public struct ForecastLogRecorder {

    /// §17.1: at most one `"sample"` row per 5 minutes per tool.
    public static let sampleInterval: TimeInterval = 300

    /// One tool's warning exposure inside one primary-window instance (STEP_188 — REV-95 §3.2).
    /// `anchor` identifies the instance; `firstShownAt` is nil until a warning-tier state has been
    /// displayed in it.
    private struct WarningExposure {
        var anchor: Date
        var firstShownAt: Date?
    }

    private let appVersion: String
    private var lastWritten: [Tool: Date] = [:]
    private var exposure: [Tool: WarningExposure] = [:]

    public init(appVersion: String) {
        self.appVersion = appVersion
    }

    /// The row to persist for this evaluation, or `nil` when neither trigger condition holds.
    /// Advances the tool's clock at decision time — before the async store write, so two
    /// interleaved evaluations can never both pass the sampling check. A `state_change` row
    /// also advances it: the clock bounds row volume, and a sample moments after a transition
    /// would carry the identical measurement.
    ///
    /// `evaluation` carries both facts this needs — whether the state changed, and what state is
    /// being displayed — so the trigger and `displayedState` can never describe different
    /// evaluations (STEP_188).
    public mutating func entry(
        tool: Tool,
        snapshot: QuotaSnapshot?,
        forecast: Forecast,
        evaluation: StateEvaluation,
        shadow: ShadowForecast? = nil,
        now: Date
    ) -> ForecastLogEntry? {
        // Before the sampling guard, deliberately: the exposure latch has to see **every**
        // evaluation. Most write no row, and a rollover that happens between two rows would
        // otherwise go unnoticed — the next sample would then carry the previous window's stamp,
        // which is exactly the inheritance §3.1 forbids for the sibling columns.
        let warningFirstShownAt = observeExposure(
            tool: tool, state: evaluation.state, anchor: snapshot?.primaryResetsAt, now: now)
        let didTransition = evaluation.change != nil
        let sampleDue = lastWritten[tool].map {
            now.timeIntervalSince($0) >= Self.sampleInterval
        } ?? true
        guard didTransition || sampleDue else { return nil }
        lastWritten[tool] = now
        return ForecastLogEntry(
            tool: tool,
            computedAt: now,
            primaryUsedPct: snapshot?.primaryUsedPct,
            secondaryUsedPct: snapshot?.secondaryUsedPct,
            burnRatePctPerMin: forecast.shortBurnRatePerMin,
            // `runwayMinutes` is nil exactly when §17.1 wants a null eta: cold start, burn
            // unmeasured, or burn ≤ `nearZeroBurnPerMin` (§11.2/§11.4).
            etaTo100: forecast.runwayMinutes.map { now.addingTimeInterval($0 * 60) },
            primaryResetsAt: snapshot?.primaryResetsAt,
            forecastTier: Self.tier(pollCount: forecast.pollCount),
            trigger: didTransition ? .stateChange : .sample,
            appVersion: appVersion,
            displayedState: evaluation.state,
            warningFirstShownAt: warningFirstShownAt,
            shadow: shadow)
    }

    /// Tracks the first warning-tier display inside the current primary-window instance and
    /// returns it (STEP_188 — REV-95 §3.2). Called on every evaluation, row or no row.
    ///
    /// A window instance is identified by its anchor. It ends when the anchor **moves** by more
    /// than `QuotaSnapshot.resetJitterTolerance` — in either direction, unlike `StateEngine`'s
    /// advance-only test, because a Codex plan change or an early reset can hand back an earlier
    /// anchor and that is still a different window — or when the remembered anchor has passed,
    /// which is the clause that fires on Claude's post-reset payload (it carries no `resets_at`
    /// to advance, so an advance-only test would be blind at the rollover). A withdrawn window
    /// (REV-64) keeps its stamp until its own anchor passes: the alternative is this type
    /// restating engine rules it must not own.
    ///
    /// Within an instance the stamp is written once. Calming down does not clear it — the point is
    /// that the user *was* warned — and a second, worse warning does not replace it.
    private mutating func observeExposure(tool: Tool, state: AppState,
                                          anchor: Date?, now: Date) -> Date? {
        let tolerance = QuotaSnapshot.resetJitterTolerance
        if let known = exposure[tool] {
            let movedOn = anchor.map { abs($0.timeIntervalSince(known.anchor)) > tolerance } ?? false
            let passed = now.timeIntervalSince(known.anchor) > tolerance
            if movedOn || passed {
                exposure[tool] = nil
            } else if let anchor {
                // Absorb the endpoint's ±1s wobble on the anchor we are still inside.
                exposure[tool]?.anchor = anchor
            }
        }
        if state.isWarningTier {
            if exposure[tool] != nil {
                if exposure[tool]?.firstShownAt == nil { exposure[tool]?.firstShownAt = now }
            } else if let anchor {
                exposure[tool] = WarningExposure(anchor: anchor, firstShownAt: now)
            }
            // No window instance to scope the stamp to (null window, idle, not yet anchored) —
            // record nothing rather than a stamp that could never be correctly cleared.
        }
        return exposure[tool]?.firstShownAt
    }

    /// §11.4 phase from the buffer fill: 0–1 polls cold start, 2–9 partial average, ≥10 full.
    static func tier(pollCount: Int) -> ForecastLogEntry.Tier {
        if pollCount < 2 { return .coldStart }
        if pollCount < ForecastEngine.bufferSize { return .partial }
        return .full
    }

    /// `"0.9.3 (142)"`-style stamp from the host bundle — grading must separate engine
    /// generations (REV-35 precedent).
    public static func currentAppVersion(bundle: Bundle = .main) -> String {
        appVersionString(
            shortVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: bundle.infoDictionary?["CFBundleVersion"] as? String,
            channel: BuildChannel.current(bundle: bundle))
    }

    /// `"0.9.3 (142)"` on a release build, `"0.9.3 (142) beta"` on a beta one (REV-52 / STEP_72).
    /// The channel is appended rather than substituted so every existing `forecast_log` row and
    /// every version comparison keeps its shape; a bundle then never leaves its own provenance to
    /// inference.
    static func appVersionString(shortVersion: String?, build: String?,
                                 channel: BuildChannel = .release) -> String {
        let base = "\(shortVersion ?? "0.0.0") (\(build ?? "0"))"
        return channel == .release ? base : "\(base) \(channel.rawValue)"
    }
}
