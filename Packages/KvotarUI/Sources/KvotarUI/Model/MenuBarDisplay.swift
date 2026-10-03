import Foundation
import KvotarCore

/// The three user-selected menu-bar display modes (Baseline §14.1, UI Spec §1.0).
/// Supersedes the automatic width-degradation model — width behaviour is per-mode. Raw values
/// are the persisted `settings.menu_bar_display_mode` strings (§17.1).
///
/// `adaptive`, `compact_glyph` and `hidden` were retired by **D-98** (REV-78). A database written
/// by an older build can still hold one: migration `v21_retire_menu_bar_modes` rewrites the row,
/// and `init(rawValue:)` returns nil for it either way, so `AppDelegate`'s read falls through to
/// the `.bothStacked` default.
public enum MenuBarDisplayMode: String, Sendable, CaseIterable {
    case bothStacked = "both_stacked"
    case claudeOnly = "claude_only"
    case codexOnly = "codex_only"

    /// The `settings` table key (Baseline §17.1). An absent row reads as `.bothStacked`.
    public static let settingsKey = "menu_bar_display_mode"

    /// Picker label (interim right-click submenu now; Settings window in Step 30).
    public var label: String {
        switch self {
        case .bothStacked: return "Both (stacked)"
        case .claudeOnly:  return "Claude only"
        case .codexOnly:   return "Codex only"
        }
    }
}

/// One long limit as the menu bar reads it (REV-98 §2.3 — STEP_202): which limit, what tier, and
/// which instance of it. `reminderText` is the §2.1 reminder line, or `nil` where the bar knows
/// about this limit and deliberately says nothing about it — under a confirmed block, whose shape
/// *is* the steady string, and under a five-hour warning, which speaks first.
///
/// The tier and the reset are here because the **episode** needs them: `AppViewModel` keys one
/// episode per limit instance and reads its cadence off the tier, and a formatter that handed
/// over strings alone would force the view model to re-derive both.
public struct LongLimitStatus: Sendable, Equatable {
    public let limit: BlockEpisode.Limit
    public let tier: LongLimitAssessment.Tier
    public let resetsAt: Date
    public let reminderText: String?

    public init(limit: BlockEpisode.Limit, tier: LongLimitAssessment.Tier, resetsAt: Date,
                reminderText: String?) {
        self.limit = limit
        self.tier = tier
        self.resetsAt = resetsAt
        self.reminderText = reminderText
    }
}

/// What this render knows about the account's long limits (REV-98 §2.3 — STEP_202).
///
/// **Held and recovered used to be the same silence**, and that is the bug this type exists to
/// remove. Before it, the schedule saw an empty reminder list and cleared its anchor — so a stale
/// poll, a freeze and a genuine recovery were indistinguishable, and the reminder replayed from
/// the top on the next good reading.
///
/// - `unknown`: loading, idle, a null window, a monthly-hero layout, and every stale render.
///   Hold the episode, both clocks and the tier; the dot keeps its colour and the motion stops.
/// - `live`: a fresh reading naming **exactly** the limits that are elevated. Anything not in the
///   list has recovered, and recovery is the tier clearing rather than the percentage falling —
///   a week catching up with its own usage clears at unchanged utilization.
public enum LongLimitReading: Sendable, Equatable {
    case unknown
    case live([LongLimitStatus])

    /// The elevated limits, worst-ranked first, or `[]` where there is no reading. Callers that
    /// must distinguish "none" from "cannot tell" pattern-match instead.
    public var statuses: [LongLimitStatus] {
        if case let .live(statuses) = self { return statuses }
        return []
    }
}

/// Menu-bar presentation for a single tool. Pure formatted values — no logic (Baseline §14).
/// The §1.1 string grammar (`[dot] [prefix] [percentText] [timeSlot]`) is the canonical string
/// form reused inside every display mode (D-29-3).
///
/// - Loading:         `percentText = "…"`,   `timeSlot = nil`   → `CL …`
/// - Idle:            `percentText = "––"`,   `timeSlot = "est"` → `CL –– est`
/// - Null-window:     `percentText = "——"`,   `timeSlot = "est"` → `CX —— est`
/// - Normal:          `percentText = "62%"`,  `timeSlot = "↻1h52m"` / `"◔~24m"`
/// - Long-limit block: `percentText = "⚠wk 0%"`, `timeSlot = "↻3d"` (REV-97 §2.5 — STEP_198)
///
/// `percentText` is **remaining** — `100 − utilization`, floored at 0 (REV-77 / D-97, §0.1 /
/// §1.1); the conditions that pick a mode are still evaluated on utilization.
public struct ToolMenuBarDisplay: Sendable, Equatable {
    public let prefix: String
    public let dot: StatusDot
    public let percentText: String
    public let timeSlot: String?
    /// §1.6 money glyph — an amber/red `$` appended after the time slot (Claude only; `.none`
    /// otherwise). Rendered in its own colour by the view, not baked into `fullString`, so it
    /// reads "money trajectory" independent of the line's quota-tier colour. REV-29.
    public let glyph: MoneyGlyph
    /// The character the §1.6 glyph is drawn with — the account's currency symbol (REV-102
    /// §2.5 — STEP_219), `$` where the currency has none of its own or none is known.
    public let moneySymbol: String
    /// What this render knows about the account's long limits (REV-98 §2.3 — STEP_202). The
    /// reminder strings are a projection of it, so the bar's cycle and the episode's lifetime
    /// cannot be computed from two different readings.
    public let longLimits: LongLimitReading

    /// The §2.1 reminder strings this tool cycles through while a long limit carries a warning
    /// tier — `CL ⚠wk 8%` — **most severe first** (REV-97 §2.3). Empty is the ordinary case:
    /// no warning, no cycle, and the bar shows `fullString` and nothing else.
    ///
    /// Each entry is a whole line including the prefix, because the reminder is a different
    /// *shape* from the steady string rather than a different slot inside it (§3.1). A confirmed
    /// block carries none — its shape is the steady string and it holds (§2.4/§2.5) — and neither
    /// does a stale render, whose reading is `unknown`.
    public var reminders: [String] { longLimits.statuses.compactMap(\.reminderText) }

    /// Whether a step **into** this reading crossfades or lands at once (REV-98 §2.4a —
    /// STEP_203). A projection of the reading, like `reminders` — the three exemptions are
    /// exactly the three shapes the reading already distinguishes, so nothing new is decided
    /// here and the fade cannot disagree with the line it is fading to.
    ///
    /// - `.unknown` — a **missing or pending reading**: loading, idle, a null window, a stale
    ///   render. Immediate.
    /// - `.live`, non-empty, and **not one of them reminds** — a **confirmed block** or an
    ///   **urgent** five-hour state that outranks the long limit. Immediate: a fade is a
    ///   softening, and nothing about arriving at a block should be soft.
    /// - everything else, `.live([])` recovery included. Animated.
    public var transition: MenuBarRender.TextLine.Transition {
        guard case let .live(statuses) = longLimits else { return .immediate }
        guard !statuses.isEmpty else { return .animated }
        return statuses.contains(where: { $0.reminderText != nil }) ? .animated : .immediate
    }

    public init(prefix: String, dot: StatusDot, percentText: String, timeSlot: String?,
                glyph: MoneyGlyph = .none, moneySymbol: String = "$",
                longLimits: LongLimitReading = .unknown) {
        self.prefix = prefix
        self.dot = dot
        self.percentText = percentText
        self.timeSlot = timeSlot
        self.glyph = glyph
        self.moneySymbol = moneySymbol
        self.longLimits = longLimits
    }

    /// The full §1.1 string, e.g. `CL 38% ↻1h52m` (the dot and the §1.6 money glyph are rendered
    /// separately, each in its own colour).
    public var fullString: String {
        timeSlot.map { "\(prefix) \(percentText) \($0)" } ?? "\(prefix) \(percentText)"
    }
}

/// Everything the status item renders — one value per rebuild (Baseline §14.1). Built by
/// `DisplayFormatter.menuBarRender` from the per-tool displays; `Equatable` so the controller
/// re-measures the item width only when the content changed (width stability, §1.0).
public struct MenuBarRender: Sendable, Equatable {
    /// One text line. `dot` present → leading status dot (stacked / single-tool).
    ///
    /// D-98 (REV-78) removed `tier`: it was set at exactly two sites, both inside the Adaptive and
    /// Compact-glyph arms, and the surviving modes colour their row from `dot`.
    /// A line has **two phases** since STEP_198 (REV-97 §2.1): the ordinary reading, and — while
    /// a long limit carries a warning tier — a five-second reminder naming that limit. `steady`
    /// and `reminders` are both carried on every render so the item can reserve the wider of
    /// them once, at the state transition, and not move again (§2.6).
    public struct TextLine: Sendable, Equatable {
        /// Whether a change *into* this line crossfades or lands at once (REV-98 §2.4a —
        /// STEP_203).
        ///
        /// Three states change immediately, and they are a rule rather than a detail: a
        /// **confirmed block**, an **urgent** state, and a **missing or pending reading**. A fade
        /// is a softening, and nothing about arriving at a block should be soft. The formatter
        /// already tests all three to decide what the line *says*, so it states the answer here
        /// too rather than leaving the view to re-derive it from the strings.
        public enum Transition: Sendable, Equatable {
            case animated
            case immediate
        }

        /// The ordinary string for this reading: `CL 64% ↻3h46m`. Also the whole line in every
        /// state that does not remind, which is nearly all of them.
        public let steady: String
        /// Every reminder this line can show, most severe first (§2.3). Empty = no cycle.
        public let reminders: [String]
        /// Which phase is drawn now — `nil` is steady, otherwise an index into `reminders`.
        /// Set by the schedule, not by the formatter: STEP_198 always produces `nil` and the
        /// bar shows the steady phase until STEP_199 adds the clock.
        public let reminderIndex: Int?
        public let dot: StatusDot?
        /// §1.6 money glyph appended after the text, in its own amber/red colour (`.none` = absent).
        public let glyph: MoneyGlyph
        /// The §1.6 glyph's character — see `ToolMenuBarDisplay.moneySymbol`.
        public let moneySymbol: String
        /// How a step **into** this line is drawn (§2.4a). `.animated` is the ordinary case.
        public let transition: Transition

        /// What the view draws. An out-of-range index falls back to steady rather than trapping:
        /// the schedule and the reminder list are computed on different cycles, and a menu bar
        /// is not worth a crash.
        public var text: String {
            guard let i = reminderIndex, reminders.indices.contains(i) else { return steady }
            return reminders[i]
        }

        /// Every string this line can render **without a state change** — what §2.6 reserves the
        /// item's width against. The controller measures these once when the render changes; it
        /// never re-measures at a phase edge.
        public var phaseStrings: [String] { [steady] + reminders }

        public init(text: String, dot: StatusDot? = nil, glyph: MoneyGlyph = .none,
                    moneySymbol: String = "$", transition: Transition = .animated) {
            self.init(steady: text, reminders: [], reminderIndex: nil, dot: dot, glyph: glyph,
                      moneySymbol: moneySymbol, transition: transition)
        }

        public init(steady: String, reminders: [String] = [], reminderIndex: Int? = nil,
                    dot: StatusDot? = nil, glyph: MoneyGlyph = .none,
                    moneySymbol: String = "$", transition: Transition = .animated) {
            self.steady = steady
            self.reminders = reminders
            self.reminderIndex = reminderIndex
            self.dot = dot
            self.glyph = glyph
            self.moneySymbol = moneySymbol
            self.transition = transition
        }

        /// What VoiceOver reads for this row — **the warning in both phases** (REV-97 §2.8 —
        /// STEP_199).
        ///
        /// The reminder is visible for five seconds in sixty; a reader who hears the row at the
        /// wrong moment would otherwise have to wait out the cycle to learn which limit is in
        /// trouble, so in the steady phase the reminders are spoken after the ordinary reading.
        /// In the reminder phase `text` already is the warning and nothing is appended.
        ///
        /// The bar's glyphs are read out as words here (`⚠wk` → "weekly limit", `↻` → "resets
        /// in"): without a label VoiceOver reads the raw string, and "clockwise open circle
        /// arrow 3h46m" is not a reading of anything. **Spoken only** — this string reaches no
        /// visible surface and is not UI Spec copy (the `StatusDot.accessibilityStatusWord`
        /// precedent).
        public var accessibilityLabel: String {
            var parts = [Self.spoken(text)]
            if let dot { parts.append(dot.accessibilityStatusWord) }
            if reminderIndex == nil { parts.append(contentsOf: reminders.map(Self.spoken)) }
            switch glyph {
            case .none:     break
            case .armed:    parts.append("extra usage may start")
            case .charging: parts.append("extra usage charging")
            }
            return parts.joined(separator: ", ")
        }

        /// One menu-bar string as words. Order matters — the two-character limit names must be
        /// replaced before the bare `⚠` could be.
        private static func spoken(_ text: String) -> String {
            var out = text
            for (glyph, word) in [("CL ", "Claude "), ("CX ", "Codex "),
                                  ("⚠wk ", "weekly limit "), ("⚠mo ", "monthly limit "),
                                  ("◔~", "runs out in about "), ("↻", "resets in "),
                                  ("——", "unknown"), ("––", "unknown"), ("…", "loading")] {
                out = out.replacingOccurrences(of: glyph, with: word)
            }
            return out
        }

        /// This line in a given phase. Nothing else about it moves — the dot keeps the account's
        /// colour through both phases (§2.4), and the strings were both decided when the render
        /// was built.
        public func showingReminder(_ index: Int?) -> TextLine {
            TextLine(steady: steady, reminders: reminders, reminderIndex: index,
                     dot: dot, glyph: glyph, moneySymbol: moneySymbol, transition: transition)
        }
    }

    /// What the status item is showing. Two genuinely different things, named rather than
    /// inferred — the whole point of the enum is that `nothing detected` and `nothing to say`
    /// cannot be confused by a future reader, because before STEP_118 they were the same value
    /// (an empty render) and the difference between them was invisible in the type.
    /// *(D-98 dropped a third case, `.hidden` — the status item is now always visible.)*
    public enum Content: Sendable, Equatable {
        /// **No tool is detected** — D-78 (REV-71 §3.3). One neutral Kvotar mark and nothing else:
        /// no text,
        /// no percentage, no `——` and no tool prefix, because every one of those would assert
        /// something about a tool the app has not found. The mark names no tool and
        /// carries no tool's data; it is the app being findable and clickable, which is the one
        /// thing that *is* true. Before this case existed the item rendered `EmptyView()` and was
        /// sized to it — about 8 pt of padding, invisible but still clickable, which is how a
        /// user reached the welcome screen on 2026-08-17: by clicking a blank patch of menu bar.
        ///
        /// This does not contradict §1.0's "an undetected tool renders nothing" — that rule
        /// governs what a *tool* renders, and no tool renders here.
        case nothingDetected
        /// At least one tool is detected. `lines` is up to 2 (stacked) or 0–1 (single-tool).
        /// **`lines` may legitimately be empty with a tool detected** — a single-tool mode whose
        /// chosen tool is the undetected one — and that is *not* `nothingDetected`.
        case tools(lines: [TextLine])
    }

    public let content: Content

    public init(content: Content) {
        self.content = content
    }

    /// The ordinary case — at least one tool detected.
    public init(lines: [TextLine]) {
        self.content = .tools(lines: lines)
    }

    /// Text lines — empty in every non-`tools` state.
    public var lines: [TextLine] {
        if case .tools(let lines) = content { return lines }
        return []
    }

    /// A copy with one line's phase set (REV-97 §2.1). The **only** way a phase is chosen: the
    /// formatter builds a render with every line steady, and the schedule turns one line's
    /// reminder on and off from there. STEP_199 drives this from the clock; STEP_198's tests and
    /// previews use it to look at the phase the bar will show.
    ///
    /// A line index the render does not have is a no-op — a display mode can drop a tool between
    /// the schedule's tick and this call, and that is not worth a crash.
    public func showingReminder(_ index: Int?, on lineIndex: Int) -> MenuBarRender {
        guard case .tools(let lines) = content, lines.indices.contains(lineIndex) else { return self }
        var updated = lines
        updated[lineIndex] = lines[lineIndex].showingReminder(index)
        return MenuBarRender(lines: updated)
    }
}
