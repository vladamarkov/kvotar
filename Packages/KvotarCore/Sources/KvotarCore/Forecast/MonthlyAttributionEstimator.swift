import Foundation

/// Cumulative local-vs-off-machine attribution for one tool's current **monthly** quota cycle.
/// Every figure is a raw amount in the meter's native scale (minor units for `.money`, credits
/// for `.credits`) — the estimator is deliberately unit-agnostic (REV-47/REV-48: one component,
/// two tools). The three shares reconcile to `usedAmount` by construction (`unattributedAmount`
/// is the residual). This is what the Monthly card's attribution rows render (UI Spec §2.3,
/// D-42): "of the `usedAmount` used this cycle, `localAmount` this machine / `offMachineAmount`
/// off-machine / `unattributedAmount` unattributed".
public struct MonthlyAttribution: Sendable, Equatable {
    /// Amount attributed to local JSONL activity — poll intervals that elapsed while local was
    /// active (exact meter delta, estimated classification).
    public let localAmount: Double
    /// Amount attributed to other surfaces — intervals that elapsed while local was idle.
    public let offMachineAmount: Double
    /// Amount the app could not attribute: spend observed on the meter before it began watching
    /// this cycle (mid-month install, long gaps). Never guessed into a bucket.
    public let unattributedAmount: Double
    /// Total amount consumed so far (the high-water meter reading). `localAmount +
    /// offMachineAmount + unattributedAmount == usedAmount`.
    public let usedAmount: Double

    public init(localAmount: Double, offMachineAmount: Double, unattributedAmount: Double,
                usedAmount: Double) {
        self.localAmount = localAmount
        self.offMachineAmount = offMachineAmount
        self.unattributedAmount = unattributedAmount
        self.usedAmount = usedAmount
    }

    /// True when there is anything consumed to decompose (the rows render); false hides them.
    public var hasUsage: Bool { usedAmount > 0.0001 }
}

/// Which local calendar day the monthly layout's §2.5a "What happened" section is anchored to
/// (REV-47 §2.4 — local midnight, always; the monthly card owns the quota clock). `nil` at the
/// display seam means "not the monthly layout"; `.none` means "monthly layout, but no local
/// activity today or yesterday" — the quiet line, dated from `LocalAttribution.lastActivityAt`.
public enum LocalDayGrain: Sendable, Equatable {
    case today
    case yesterday
    case none
}

/// Accumulates the exact local / off-machine split across the current monthly cycle, poll by
/// poll — `OffMachineEstimator`'s interval rule (REV-27) transplanted to the monthly meter
/// (REV-47): per poll, `Δ = max(0, used − high-water)` is exact (server-reported); the whole Δ
/// is classified by the same 8-minute local-liveness discriminator (`localValueLast8Min > 0`).
/// Local active ⇒ this machine, idle ⇒ off-machine. Because each interval's meter delta is
/// exact, the running totals are exact up to that classification; the unattributed share is
/// derived, never stored.
///
/// State is anchored on the monthly reset (Claude: the §8.0.4 **derived** calendar-month reset;
/// Codex: the server's `individual_limit.reset_at`) — an anchor moved beyond jitter tolerance is
/// a cycle rollover and starts fresh, so post-rollover spend before the first classified
/// interval lands in Unattributed, honestly. State per tool is persisted (settings KV) — a
/// month-long cycle outlives many launches.
public actor MonthlyAttributionEstimator {

    /// Persisted running state for one tool's current cycle. `localCumAmount`/`offCumAmount` are
    /// monotonic (only positive, classified deltas are added); the unattributed share is derived,
    /// never stored. `lastUsedAmount` is a high-water mark so endpoint wobble — including the
    /// SPIKE-observed eventual-consistency dips (P2-15) — can't double-count.
    struct AccumState: Codable, Sendable, Equatable {
        var cycleResetUnix: Double    // the monthly resets_at anchor
        var lastUsedAmount: Double    // high-water meter reading observed this cycle
        var localCumAmount: Double
        var offCumAmount: Double
    }

    /// An anchor moved beyond this is a genuine cycle rollover (mirrors
    /// `OffMachineEstimator.resetJitterToleranceUnix` — derivation/endpoint wobble tolerance).
    static let resetJitterToleranceUnix: Double = 60

    private let store: SQLiteStore?
    private var states: [Tool: AccumState] = [:]
    private var loaded: Set<Tool> = []

    public init(store: SQLiteStore? = nil) {
        self.store = store
    }

    private static func key(_ tool: Tool) -> String { "monthly_attrib_accum_\(tool.rawValue)" }

    // MARK: - Record

    /// Folds one poll into the cycle accumulator and returns the current `MonthlyAttribution`
    /// (`nil` only when no monthly meter has ever been observed for `tool`).
    ///
    /// - Parameters:
    ///   - cycleReset: the monthly limit's `resetsAt` — the cycle anchor; `nil` on a poll without
    ///     a monthly meter — then the last-known attribution is returned unchanged.
    ///   - usedAmount: the meter's `usedAmount` this poll — raw units, meter-native scale.
    ///   - localValueLast8Min: pricing-valued local burn ($/min) over the trailing 8 minutes
    ///     (`AttributionEngine.localValuePerMin` over `now − idleGap … now`). Used only as the
    ///     idle-vs-active discriminator for *this* interval; the 8-minute lookback matches the
    ///     liveness gap so a long turn (which writes no JSONL mid-turn) isn't misread as idle.
    public func record(tool: Tool, cycleReset: Date?, usedAmount: Double?,
                       localValueLast8Min: Double?, now: Date = Date()) async -> MonthlyAttribution? {
        await loadIfNeeded(tool)

        guard let usedAmount, let cycleReset else {
            return states[tool].map(Self.attribution(from:))
        }
        let resetUnix = cycleReset.timeIntervalSince1970

        // Same cycle? Continue the accumulator. Otherwise (rollover or first-ever observation)
        // start fresh: local/off reset to 0, so the residual `unattributedAmount` equals whatever
        // was already used before we started watching — honestly unattributed, never guessed.
        if var state = states[tool],
           abs(state.cycleResetUnix - resetUnix) <= Self.resetJitterToleranceUnix {
            let delta = max(0, usedAmount - state.lastUsedAmount)
            if delta > 0 {
                if (localValueLast8Min ?? 0) > 0 {
                    state.localCumAmount += delta    // local active this interval
                } else {
                    state.offCumAmount += delta      // local idle ⇒ off-machine
                }
            }
            state.lastUsedAmount = max(state.lastUsedAmount, usedAmount)   // high-water mark
            states[tool] = state
        } else {
            states[tool] = AccumState(cycleResetUnix: resetUnix, lastUsedAmount: usedAmount,
                                      localCumAmount: 0, offCumAmount: 0)
        }

        await persist(tool)
        return states[tool].map(Self.attribution(from:))
    }

    /// The current attribution for `tool` without advancing state — the between-poll re-render
    /// path, where no fresh meter delta exists so nothing should be attributed.
    public func current(for tool: Tool) async -> MonthlyAttribution? {
        await loadIfNeeded(tool)
        return states[tool].map(Self.attribution(from:))
    }

    // MARK: - Derivation

    private static func attribution(from s: AccumState) -> MonthlyAttribution {
        let used = max(s.lastUsedAmount, s.localCumAmount + s.offCumAmount)
        let unattributed = max(0, used - s.localCumAmount - s.offCumAmount)
        return MonthlyAttribution(localAmount: s.localCumAmount, offMachineAmount: s.offCumAmount,
                                  unattributedAmount: unattributed, usedAmount: used)
    }

    // MARK: - Persistence (settings KV; no migration)

    private func loadIfNeeded(_ tool: Tool) async {
        guard !loaded.contains(tool) else { return }
        loaded.insert(tool)
        guard let store else { return }
        guard let raw = (try? await store.readSetting(key: Self.key(tool))) ?? nil,
              let data = raw.data(using: .utf8),
              let state = try? JSONDecoder().decode(AccumState.self, from: data) else { return }
        states[tool] = state
    }

    private func persist(_ tool: Tool) async {
        guard let store, let state = states[tool],
              let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        try? await store.writeSetting(key: Self.key(tool), value: json)
    }
}
