import Foundation

/// Cumulative local-vs-off-machine attribution for one tool's current quota window — whatever
/// width the provider reported for it (REV-60), not a five-hour assumption.
/// Every figure is a **cumulative percentage of the window** consumed so far, not a rate — the
/// three shares reconcile to `totalUsedPct` by construction (`unattributedPct` is the residual).
/// This is what the Burn-rate split bar and Off-machine row render (UI Spec §2.4, cumulative
/// amendment): "of the `totalUsedPct`% used this window, `offMachinePct`% off-machine /
/// `localPct`% local / `unattributedPct`% unattributed".
public struct WindowAttribution: Sendable, Equatable {
    /// Window % attributed to other surfaces (claude.ai / Desktop / mobile / another machine) —
    /// the sum of every settled poll interval in which no local token event landed (exact, no
    /// conversion).
    public let offMachinePct: Double
    /// Window % attributed to local activity — intervals with local token events, plus intervals
    /// still inside the in-flight guard (pending; they may settle to off-machine later).
    public let localPct: Double
    /// Window % the app could not attribute — the slice consumed before its first reading of the
    /// window, in the one case elimination cannot reach it: the app was **quit** across part of
    /// that span, so the local corpus provably cannot answer (§7.2 zero-backfill). Never guessed.
    /// Renders as `Not observed` (UI Spec §2.5a, REV-56/D-52).
    public let unattributedPct: Double
    /// Total window % consumed so far (the high-water utilization). `offMachinePct + localPct +
    /// unattributedPct == totalUsedPct` by construction. A **floor**, not a total, when
    /// `closeObserved` is false.
    public let totalUsedPct: Double
    /// False only when this window has already **ended** and the app's last reading of it predates
    /// that close by more than `OffMachineEstimator.closeObservationTolerance` — the case where
    /// `totalUsedPct` is merely the highest reading the app happened to see and the window may have
    /// ended anywhere above it (REV-56 §4.1 — STEP_84). The display marks it `≥N%`.
    ///
    /// True for a window still open: there is no close to have missed.
    public let closeObserved: Bool

    public init(offMachinePct: Double, localPct: Double, unattributedPct: Double,
                totalUsedPct: Double, closeObserved: Bool = true) {
        self.offMachinePct = offMachinePct
        self.localPct = localPct
        self.unattributedPct = unattributedPct
        self.totalUsedPct = totalUsedPct
        self.closeObserved = closeObserved
    }

    /// True when there is anything consumed to decompose (the bar renders); false hides it.
    public var hasUsage: Bool { totalUsedPct > 0.0001 }
}

/// Derives the exact off-machine / local split for the current quota window by **retrospective
/// whole-window recompute** (REV-53 §3 — supersedes the REV-27 forward accumulator, which
/// survives only in `MonthlyAttributionEstimator`).
///
/// ## Why recompute, not a forward accumulator (REV-53, supersedes REV-27/REV-23 here)
/// The old design classified each poll's delta **at the moment of the poll**, using an 8-minute
/// local-liveness proxy (`localValueLast8Min`) because a long turn writes JSONL only at
/// completion, so true idleness wasn't knowable live. That proxy blended any interval within
/// 8 minutes of local activity into Local — erasing concurrent web usage (the 2026-07-21
/// incident) — and a forward-only accumulator can never un-decide a misclassification.
///
/// The recompute inverts the timing: the window's account-side boundaries are persisted
/// (`quota_series`, written by `writePoll` in the same transaction as the snapshot) and every
/// call re-walks **all** of the current window's intervals against the token events that have
/// *actually landed* (`local_usage_events`, permanent). In hindsight idleness is a lookup:
/// an interval is **settled idle** — its delta exact off-machine — once the in-flight guard
/// has passed (`now ≥ t₁ + G`) with zero token events **and no local-liveness mark** in
/// `(t₀, t₁ + G]`. The guard outwaits a
/// *call* that was still streaming at the boundary (its usage writes at completion), not a
/// *turn* — hence 180s, not the old 480s. Everything else (tokens present, or still pending)
/// counts Local.
///
/// ## Why token silence was never enough (STEP_173)
/// Codex writes a turn’s `token_count` twenty to thirty minutes after the work begins (§8.4), so
/// a stretch the user worked straight through can hold no token rows at all — and where those
/// tokens land against a *later* interval, the self-healing above never reaches back. On the alpha
/// tester’s 2026-09-03 Codex window the split therefore booked **61 of 95 points as Elsewhere**
/// while their editor extension wrote to disk every 10–30 seconds, directly beneath a
/// `Local source` row correctly naming that surface as active. STEP_170 fixed the row and left the
/// number. The fix here is that both now read one clock: `writePoll` stamps each series row with
/// the §12 liveness timestamp as of that poll — the same value the row renders from — and a mark
/// inside an interval blocks its settlement exactly as a token event does. Replayed, that window
/// returns **Elsewhere 3.0 / This machine 92.0**.
///
/// A mark is evidence a surface was *alive*, never of an amount: it adds no tokens, moves no rate,
/// and cannot change the total. What it deliberately gives up is genuine Elsewhere burn that
/// overlaps local file activity — the concession REV-53 §8 already makes for intervals carrying
/// token rows, widened to intervals carrying any local write. Late JSONL self-heals on the next recompute — including, deliberately, a
/// token landing *after* an interval settled (write latency > G lowers off; do **not** clamp —
/// self-healing is the REV-53 §8 accepted posture and clamping would freeze misclassification).
///
/// ## Walk semantics (the subtle parts, pinned by tests)
/// - **Running high-water, not naive pairwise deltas:** `delta = max(0, p₁ − hw)` with `hw`
///   carried across the walk — a wobble sequence 0,10,9,10 must yield 10, not 11 (§11.2a
///   quantized-utilization discipline).
/// - **Open lower bound on the token bucket:** a JSONL write landing exactly at `t₀` belongs to
///   the *previous* interval and must not poison this one (the 18:41–18:45 incident pin).
/// - **The leading slice is resolved by elimination, under app coverage** (REV-56 §5 —
///   STEP_84): the quota already spent when the first reading landed is classified by the same
///   token-presence rule as any interval, gated on `app_lifecycle_events` proving the app ran
///   for the whole span. It stays unattributed only where the app was **quit** — the one case
///   the §7.2 zero-backfill invariant makes unanswerable. The monotone-floor property of the
///   display is empirical (settling only adds to off), not enforced by a clamp. A liveness mark
///   in the slice counts it Local without waiting for the guard, as a token does.
/// - **The total is a floor when the close was never observed** (`closeObserved`, REV-56 §4.1).
///
/// The DB is the state: nothing is persisted here (the KV `offmachine_accum_*` blobs are
/// retired; stale keys are left in place). In memory only a per-tool cache of the last result
/// plus the last window's reset anchor — and after a restart a nil-window poll **lazily
/// recomputes** the newest persisted window, which the REV-46 idle retrospective depends on.
/// With no store (or a failed token read) nothing can settle, so every delta stays Local —
/// the conservative degraded posture.
public actor OffMachineEstimator {

    /// Seconds past an interval's end that must stay token-free before the interval is trusted
    /// as idle — outwaits an API call in flight at the boundary whose usage writes at
    /// completion. Dogfood-tunable starting value (P1-20); the STEP_76 soak compares
    /// {120, 180, 300} against known-clean days.
    public static let inFlightGuard: TimeInterval = 180

    /// How close to a window's `resets_at` the last reading must land for the close to count as
    /// observed (REV-56 §4.1 — STEP_84). Set to the §9.2 **maximum** legal poll interval, not the
    /// base one: inside that span the app was still polling right up to the close and the reading
    /// is as good as the cadence allows, so an ordinary window never acquires a `≥`. Beyond it the
    /// app demonstrably stopped watching. (Live 2026-07-29: the recapped 16:00 window's last poll
    /// sat 166s before the close at a then-current ~130s cadence — observed; the 05:00 window's
    /// last poll sat 1h16m before its close — not.)
    public static let closeObservationTolerance: TimeInterval = 300

    /// A `resets_at`/window-start advance beyond this is a genuine window rollover (mirrors
    /// `ForecastEngine.resetJitterTolerance` — the endpoint wobbles ±1s between polls). Also
    /// the `quota_series` row-selection tolerance.
    static let resetJitterToleranceUnix: Double = 60

    /// One account-side observation inside a window — the pure walk's input.
    struct SeriesSample: Equatable {
        let polledAt: Date
        let usedPct: Double
        /// The §12 liveness timestamp as of this poll — the newest local *write*, in-memory token
        /// event or persisted token event the app knew about (STEP_170), persisted onto the series
        /// row by `writePoll` and read back here (STEP_173). It is the same value the burn card
        /// rendered `Local source` from, which is what stops the row and the Elsewhere number
        /// disagreeing. Nil on rows written before `v22_quota_series_local_activity` and whenever
        /// no local activity had yet been observed — both read as no evidence.
        let lastLocalActivityAt: Date?

        init(polledAt: Date, usedPct: Double, lastLocalActivityAt: Date? = nil) {
            self.polledAt = polledAt
            self.usedPct = usedPct
            self.lastLocalActivityAt = lastLocalActivityAt
        }
    }

    /// The window width assumed when none is known — Claude's true width, and the width of every
    /// Codex payload that omits the field (REV-60). Reached only on the paths that resolve a
    /// window out of `quota_series`, which carries no width column: see `current` and `lastKnown`.
    static let fallbackWindowSeconds: TimeInterval = 18_000

    private let store: SQLiteStore?
    private var lastAttribution: [Tool: WindowAttribution] = [:]
    private var lastResetsAt: [Tool: Date] = [:]
    /// The reported width of the window `lastResetsAt` names. Kept because the walk needs a real
    /// window *start*, and nothing in `quota_series` can supply the width after a restart.
    private var lastWindowSeconds: [Tool: TimeInterval] = [:]
    /// Nil-store fallback: the current window's samples, kept in memory so the degraded path
    /// runs the same walk (nothing settles without token data — everything Local).
    private var memorySeries: [Tool: [SeriesSample]] = [:]
    private var memoryResetsAt: [Tool: Date] = [:]

    public init(store: SQLiteStore? = nil) {
        self.store = store
    }

    // MARK: - Record

    /// Folds one poll into the window recompute and returns the current `WindowAttribution`
    /// (`nil` only when no window has ever been observed).
    ///
    /// - Parameters:
    ///   - resetsAt: `snapshot.primaryResetsAt` — the window's endpoint-reported close; `nil` on a
    ///     null/unreachable window — then the last-known attribution is returned (lazily
    ///     recomputed from the newest persisted window after a restart).
    ///   - windowSeconds: `snapshot.primaryWindowLength` — the **reported** width. Taken alongside
    ///     `resetsAt` rather than reconstructed from a window start, which is what REV-60 §2.1
    ///     found: the caller subtracted 18,000 s and this method added it back, so the two
    ///     cancelled and nobody noticed the constant for as long as every window really was five
    ///     hours wide.
    ///   - currentUsedPct: `snapshot.primaryUsedPct` — the exact account utilization this poll.
    ///     The matching `quota_series` row was written by `writePoll` moments earlier in the
    ///     same poll cycle, so the recompute already sees this reading.
    public func record(tool: Tool, resetsAt: Date?, windowSeconds: TimeInterval,
                       currentUsedPct: Double?, now: Date = Date()) async -> WindowAttribution? {
        guard let currentUsedPct, let resetsAt else {
            return await lastKnown(tool: tool, now: now)
        }

        if store == nil {
            appendToMemorySeries(tool: tool, resetsAt: resetsAt,
                                 sample: SeriesSample(polledAt: now, usedPct: currentUsedPct))
        }

        let attribution = await recomputeWindow(tool: tool, resetsAt: resetsAt,
                                                windowSeconds: windowSeconds,
                                                liveUsedPct: currentUsedPct, now: now)
        if let attribution {
            lastAttribution[tool] = attribution
            lastResetsAt[tool] = resetsAt
            lastWindowSeconds[tool] = windowSeconds
        }
        return attribution
    }

    /// The current attribution for `tool` without a fresh account reading — the between-poll
    /// re-render path (`handleLocalDelta`). Unlike the old accumulator this may *improve*: a
    /// landing turn's JSONL or the passage of guard time can settle a pending interval. It
    /// never invents usage — `totalUsedPct` cannot rise here (the live total is floored by the
    /// cached value, and the series holds no reading newer than the last poll).
    public func current(for tool: Tool, now: Date = Date()) async -> WindowAttribution? {
        var resetsAt = lastResetsAt[tool]
        var windowSeconds = lastWindowSeconds[tool]
        if resetsAt == nil, let store {
            // Resolved from the series after a restart, which carries no width column — so the
            // width falls back to five hours here and only here (REV-60 §2, `lastActiveWindow`
            // makes the same trade for the same reason).
            resetsAt = ((try? await store.latestQuotaSeriesPoint(tool: tool)) ?? nil)?.resetsAt
            windowSeconds = nil
        }
        guard let resetsAt else { return lastAttribution[tool] }
        let width = windowSeconds ?? Self.fallbackWindowSeconds
        let attribution = await recomputeWindow(
            tool: tool, resetsAt: resetsAt, windowSeconds: width,
            liveUsedPct: lastAttribution[tool]?.totalUsedPct, now: now)
        if let attribution {
            lastAttribution[tool] = attribution
            lastResetsAt[tool] = resetsAt
            lastWindowSeconds[tool] = width
        }
        return attribution ?? lastAttribution[tool]
    }

    // MARK: - Recompute

    /// Null-poll path: the cached result, or — after a restart emptied the cache — a lazy
    /// recompute of the newest persisted window (load-bearing for the REV-46 idle
    /// retrospective, which renders the *last* window's share on null-window polls).
    private func lastKnown(tool: Tool, now: Date) async -> WindowAttribution? {
        if let cached = lastAttribution[tool] { return cached }
        guard let store,
              let latest = (try? await store.latestQuotaSeriesPoint(tool: tool)) ?? nil else {
            return nil
        }
        // No width in `quota_series` — five hours, as in `current` above.
        let attribution = await recomputeWindow(tool: tool, resetsAt: latest.resetsAt,
                                                windowSeconds: Self.fallbackWindowSeconds,
                                                liveUsedPct: nil, now: now)
        if let attribution {
            lastAttribution[tool] = attribution
            lastResetsAt[tool] = latest.resetsAt
            lastWindowSeconds[tool] = Self.fallbackWindowSeconds
        }
        return attribution
    }

    /// Reads the window's samples + token timestamps and runs the pure walk. Two prepared
    /// reads, no per-interval queries (this also runs on the JSONL-delta re-render path).
    private func recomputeWindow(tool: Tool, resetsAt: Date, windowSeconds: TimeInterval,
                                 liveUsedPct: Double?, now: Date) async -> WindowAttribution? {
        // **The defect REV-60 §2.1 names.** This start is the lower bound of the token query
        // below, and it was derived by subtracting a hardcoded five hours from a reset that can
        // be a month away — putting it in the future, so the query returned nothing, so every
        // interval read "no local tokens" and the walk correctly attributed a token set that had
        // been excluded by a date. The caller's start and this one cancelled, which is why the
        // series lookup always looked healthy.
        let windowStart = resetsAt.addingTimeInterval(-windowSeconds)
        let points: [SeriesSample]
        let tokens: [Date]?
        var leadingSliceCovered = false
        if let store {
            let rows = (try? await store.quotaSeries(
                tool: tool, resetsAtNear: resetsAt,
                tolerance: Self.resetJitterToleranceUnix)) ?? []
            points = rows.map { SeriesSample(polledAt: $0.polledAt, usedPct: $0.usedPct,
                                             lastLocalActivityAt: $0.lastLocalActivityAt) }
            if let first = points.first {
                // Lower bound is the **window start**, not the first reading: the leading slice
                // is classified by the same token-presence rule as every interior interval, so
                // its span must be in the bucket (REV-56 §5 — STEP_84). Upper bound covers the
                // newest interval's guard span; a failed read degrades to nil = "unknown" ⇒
                // nothing settles (never "no tokens" ⇒ over-attribution).
                tokens = try? await store.tokenEventTimestamps(
                    tool: tool, since: windowStart,
                    until: now.addingTimeInterval(Self.inFlightGuard + 1))
                // App coverage over `[windowStart, t_first]`. The series row at `first.polledAt`
                // is the liveness evidence `processRunningSince` requires — only a running
                // process could have written it — so a launch at or before the window start
                // proves that same process spanned the whole slice. A failed read, an absent
                // history, or a `quit` in the way all land on `false`: the conservative direction,
                // which yields `Not observed` rather than a fabricated off-machine claim.
                let launchedAt = (try? await store.processRunningSince(at: first.polledAt)) ?? nil
                leadingSliceCovered = (launchedAt.map { $0 <= windowStart }) ?? false
            } else {
                tokens = nil
            }
        } else {
            points = (memoryResetsAt[tool].map {
                abs($0.timeIntervalSince(resetsAt)) <= Self.resetJitterToleranceUnix
            } ?? false) ? (memorySeries[tool] ?? []) : []
            tokens = nil
        }
        return Self.recompute(points: points, tokenTimestamps: tokens,
                              liveUsedPct: liveUsedPct, now: now, resetsAt: resetsAt,
                              windowSeconds: windowSeconds,
                              leadingSliceCovered: leadingSliceCovered)
    }

    /// The pure walk — all attribution semantics live here (see the type doc comment).
    ///
    /// - Parameters:
    ///   - resetsAt: the window's endpoint-reported close. With `windowSeconds` it supplies the
    ///     window start that bounds the leading slice, and it is the clock the `closeObserved`
    ///     floor test is made against. `nil` leaves both off (the leading slice stays
    ///     unattributed, the close counts as observed).
    ///   - windowSeconds: the window's **reported** width (REV-60). Defaulted to five hours, which
    ///     is Claude's real width and the width of every Codex payload that omits the field — the
    ///     same fallback, never an assumption about a width the provider did state.
    ///   - leadingSliceCovered: whether `app_lifecycle_events` proves the app was running for the
    ///     whole of `[windowStart, t_first]` — see `SQLiteStore.processRunningSince`.
    ///
    /// Local-liveness marks are not a parameter: they ride on `points` (`SeriesSample`), because
    /// they are recorded per poll by the same write that records the utilization (STEP_173).
    static func recompute(points: [SeriesSample], tokenTimestamps: [Date]?,
                          liveUsedPct: Double?, now: Date,
                          resetsAt: Date? = nil,
                          windowSeconds: TimeInterval = fallbackWindowSeconds,
                          leadingSliceCovered: Bool = false,
                          guardSeconds: TimeInterval = inFlightGuard) -> WindowAttribution? {
        guard let first = points.first else {
            // No series (first-ever poll's write failed, or degraded path before any record):
            // whatever the account says is honestly unattributed.
            return liveUsedPct.map {
                WindowAttribution(offMachinePct: 0, localPct: 0,
                                  unattributedPct: $0, totalUsedPct: $0)
            }
        }

        var highWater = first.usedPct          // the leading slice — resolved below, or residue
        var off = 0.0
        var local = 0.0
        // Every liveness mark the series carries, in one array so both the slice and the interior
        // walk apply one predicate (STEP_173). Unlike `tokenTimestamps` this is never "unknown":
        // it rides on the points already in hand, and an empty array is the honest reading for a
        // pre-v22 window — no evidence, so nothing is blocked from settling.
        let activityMarks = points.compactMap(\.lastLocalActivityAt)

        // ── The leading slice: `[windowStart, t_first]` ────────────────────────────────────
        // Quota the account had already spent when the app took its first reading of this
        // window. Its **amount** was never in question (`first.usedPct`, exact) — only its
        // identity, and the local corpus answers identity by the same rule the walk applies to
        // every interior interval: no local token events in the span ⇒ off-machine, exactly
        // (REV-56 §5 — STEP_84; supersedes §12.2's "stays unattributed — never guessed").
        //
        // The one added precondition is **coverage**: `JSONLDirectoryWatcher.start` seeds every
        // discovered file to EOF (§7.2), so anything Claude Code wrote while the app was not
        // running is never ingested, then or later — zero backfill. Where the app was quit,
        // "no local events" is evidence of nothing, and the slice stays unattributed. That is
        // the case, and the only case, that `Not observed` names.
        //
        // Deliberately *not* symmetric with the interior intervals on the pending case: those
        // default to Local inside the guard because the app was watching them and local work is
        // the norm there. This span was never watched, so it stays unattributed until it
        // settles — the slice only ever moves *out* of `Not observed`, never through a "This
        // machine" claim nothing supports.
        if first.usedPct > 0, let resetsAt {
            let windowStart = resetsAt.addingTimeInterval(-windowSeconds)
            // Closed lower bound, unlike the interior intervals: the interval that would
            // otherwise own a write landing exactly at `windowStart` belongs to the *previous
            // window* — a different denominator — so it cannot claim this one's usage.
            let tokensInSlice = tokenTimestamps.map { stamps in
                stamps.contains {
                    $0 >= windowStart && $0.timeIntervalSince(first.polledAt) <= guardSeconds
                }
            }
            // The same test over the liveness marks the series rows carry (STEP_173). A mark is
            // evidence a local surface was alive across the slice even where its token accounting
            // has not been written yet, so it blocks the elimination exactly as a token does.
            let activeInSlice = activityMarks.contains {
                $0 >= windowStart && $0.timeIntervalSince(first.polledAt) <= guardSeconds
            }
            let settled = now.timeIntervalSince(first.polledAt) >= guardSeconds
            if tokensInSlice == true || activeInSlice {
                local += first.usedPct                     // positive evidence — no guard wait
            } else if tokensInSlice == false, settled, leadingSliceCovered {
                off += first.usedPct                       // elimination, exact
            }
        }

        for (p0, p1) in zip(points, points.dropFirst()) {
            let delta = max(0, p1.usedPct - highWater)
            if delta > 0 {
                let settled = now.timeIntervalSince(p1.polledAt) >= guardSeconds
                let idle: Bool
                if settled, let tokens = tokenTimestamps {
                    // Token bucket is (t₀, t₁ + G]: open lower bound (a write at exactly t₀
                    // belongs to the previous interval), guard-extended upper bound.
                    let quiet = !tokens.contains {
                        $0 > p0.polledAt && $0.timeIntervalSince(p1.polledAt) <= guardSeconds
                    }
                    // …and the identical test over the liveness marks (STEP_173). Codex writes a
                    // turn's `token_count` twenty to thirty minutes after the work starts (§8.4),
                    // so token silence alone was never evidence of an idle machine: on the alpha
                    // tester's 2026-09-03 window this clause moves 58 points out of Elsewhere and
                    // into This machine, where the user was in fact working the whole time.
                    // An interval with a mark is treated exactly as a pending one — Local.
                    idle = quiet && !activityMarks.contains {
                        $0 > p0.polledAt && $0.timeIntervalSince(p1.polledAt) <= guardSeconds
                    }
                } else {
                    idle = false                // pending, or token data unknown
                }
                if idle { off += delta } else { local += delta }
            }
            highWater = max(highWater, p1.usedPct)
        }

        let total = max(highWater, liveUsedPct ?? 0)
        let unattributed = max(0, total - off - local)
        // `total` is the highest reading the app happened to *see*. That is the truth for a
        // window still running, but the idle retrospective fires precisely when the app slept
        // across a close — and then the window may have ended anywhere above the last reading
        // (REV-56 §4.1). Marked here, rendered as `≥N%`, rather than left as a caveat living
        // only in this source (the REV-37 family of defect).
        let closeObserved = resetsAt.map { resets in
            let last = points.last?.polledAt ?? first.polledAt
            return now < resets
                || last >= resets.addingTimeInterval(-Self.closeObservationTolerance)
        } ?? true
        return WindowAttribution(offMachinePct: off, localPct: local,
                                 unattributedPct: unattributed, totalUsedPct: total,
                                 closeObserved: closeObserved)
    }

    // MARK: - Degraded in-memory series (nil store)

    private func appendToMemorySeries(tool: Tool, resetsAt: Date, sample: SeriesSample) {
        if let previous = memoryResetsAt[tool],
           abs(previous.timeIntervalSince(resetsAt)) > Self.resetJitterToleranceUnix {
            memorySeries[tool] = []            // rollover — a new window starts fresh
        }
        memoryResetsAt[tool] = resetsAt
        memorySeries[tool, default: []].append(sample)
    }
}
