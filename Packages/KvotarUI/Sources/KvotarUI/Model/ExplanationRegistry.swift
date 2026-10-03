import Foundation
import KvotarCore

/// The explanation-layer element IDs (UI Spec Part 3 §5.2 — REV-67/D-72, STEP_111; extended to 21 by
/// REV-75/D-89, STEP_128). Stable across tabs: the *label* an element carries differs per tool and
/// per layout, the ID does not. A row or header element that carries one of these becomes a hover
/// card target; everything else is inert.
///
/// **Append-only.** `specID` is the case's index in `allCases`, so inserting anywhere but the end
/// renumbers every later element and breaks the §5.2 table and its fixture test at once.
public enum ExplanationElement: String, CaseIterable, Sendable, Hashable {
    /// E-01 — the primary window row (`5-hour used`, or width-named per D-58) and the D-58 caption.
    case primaryWindow
    /// E-02 — the secondary window row (`Weekly used`).
    case secondaryWindow
    /// E-03 — the primary reset row (`Resets at` / `Resets in`); `Weekly resets` is E-14.
    case reset
    /// E-04 — the header hero `%` on a windowed layout; the monthly layout's hero is E-15.
    case heroPercent
    /// E-05 — the burn card's primary line (`[pill] [%/min]`, or `[%/hr]` on a window a day or
    /// wider — REV-74/D-83). The monthly layout's spend rate is E-21.
    case burn
    /// E-06 — the local-app rows under `LOCAL ACTIVITY · TODAY` (STEP_197). Was the burn card's
    /// `Local source` row until D-67 deleted that card, leaving this element inert; the rows it
    /// now explains answer the same question one day later rather than one minute ago.
    case localSource
    /// E-07 — the burn card's `Elsewhere` row (the windowed share; the monthly row is E-19).
    /// The identifier keeps the old word (REV-81 / D-102 moved copy only).
    case offMachine
    /// E-08 — verdict line 2. **No fixed card** (REV-75/D-90): the concept changes with the
    /// verdict family, so `card(.verdictDetail)` is nil and the per-family cards land in
    /// STEP_130. Until then the detail line is inert — a nil body makes `.explainable` a no-op.
    case verdictDetail
    /// E-09 — a source tag (`Source: … · exact · 12s ago`, `Total: … (exact) · est. from JSONL`).
    /// The one **state-aware** entry — see `ExplanationRegistry.sourceTagCard`.
    case sourceTag
    /// E-10 — the `This window` / `Last window` / `Today` row of "What it's worth" (title inert).
    case estTokenValue
    /// E-11 — the `Cache hit` row.
    case cacheHit
    /// E-12 — the `Usage credits` row (§2.4a, Claude Pro/Max only).
    case usageCredits
    /// E-13 — the `7-day` and `30-day` rows of "What it's worth" (split out of E-10 in dogfood).
    case rollingHorizons
    /// E-14 — the `Weekly resets` row (split out of E-03 in dogfood).
    case weeklyReset
    /// E-15 — the Enterprise monthly `Used` row **and the monthly-layout hero**, which reads a
    /// money/credit figure rather than E-04's window percent (REV-75/D-89).
    case monthlyUsed
    /// E-16 — the Enterprise monthly `Pace` row.
    case monthlyPace
    /// E-17 — the Enterprise monthly `Resets` row.
    case monthlyReset
    /// E-18 — the monthly attribution split's `This machine` row (REV-47/D-42).
    case thisMachine
    /// E-19 — the monthly split's `Elsewhere` row on both tools (REV-81 / D-102 retired the
    /// `Off-machine` wording that REV-48 §2.2 had already excepted on Codex).
    case monthlyOffMachine
    /// E-20 — the monthly split's `Unattributed` row (the residual, hidden at zero).
    case unattributed
    /// E-21 — the burn line on the monthly layout (`~$4.10/hr` / `~14 credits/hr`) — a different
    /// concept from E-05's percent-per-window rate.
    case spendRate
    /// E-22 — a model-scoped limit row (`Fable used`, STEP_134/D-94; since STEP_176 also the
    /// Codex model windows in Other Limits and a model-window hero). The `<model> resets` row
    /// beside the Claude row stays inert — the two resets are one boundary in every capture, so
    /// that row is an exception, not a concept.
    case scopedLimit
    /// E-23 — the `LOCAL ACTIVITY · TODAY` summary (STEP_178 — REV-92). What the day's
    /// population is, what the collector can and cannot see, and that the project list is
    /// grouped local activity rather than a list of open repositories.
    case localActivity
    /// E-24 — the neutral clock beside a project name (STEP_178 — REV-92 §3): *latest observed
    /// usage*, never foreground editor focus and never a running process.
    case projectRecency

    /// The spec's row ID (`E-01` …), for tests and logs.
    public var specID: String {
        let index = ExplanationElement.allCases.firstIndex(of: self)! + 1
        return String(format: "E-%02d", index)
    }
}

/// The freeze reason a source-tag card may name (UI Spec Part 3 §5.2 rule 4). Exactly the two
/// reasons the verdict already puts into words — D-33 "Reconnecting…" (a rate-limited freeze) and
/// D-38 "sign-in expired" (an expired Claude credential) — so the card can never say anything the
/// verdict line would not. Set by `DisplayFormatter` from the same `AdapterHealth` fork.
public enum SourceFreeze: Sendable, Equatable {
    case reconnecting
    case signInExpired
}

/// Which live line an element is showing (UI Spec Part 3 §5.2 rule 4 — REV-75/D-88, STEP_130).
/// The raw value is the spec row's suffix: a row `E-02·weeklyTighter` is this element's
/// `.weeklyTighter` template. `live` is the single-line case; everything else names a state.
///
/// The E-08 cases (`resetsFirst` … `monthlyRunsOut`) are the **verdict families** of D-90, whose
/// rows are whole cards rather than trailing lines. They are `LiveVariant` cases and not
/// `VerdictFamily` ones because the two do not line up: `VerdictFamily.held` shares the
/// `resetsFirst` card, `.overQuota` splits into `overQuota` / `onCredits`, and `.monthly` splits
/// into `monthlyOnPace` / `monthlyRunsOut`. The formatter picks the variant at the branch that
/// already knows which case it is, so nothing has to be mapped back out of a coarser family.
public enum LiveVariant: String, CaseIterable, Sendable {
    case live, notStarted, none                 // E-01, E-07
    case primaryTighter, weeklyTighter          // E-02
    /// The long-limit tiers (REV-96 §3.9 — STEP_194). E-02 on the weekly, E-15/E-16 on the
    /// monthly meter: one variant per tier that has something to say, so the card explains the
    /// verdict the strip and the row are already showing rather than restating which window is
    /// tighter. `.onPace` has no variant — a card that says "nothing is wrong" is a card nobody
    /// opened for a reason.
    case aheadOfPace, nearlySpent
    case runway, pace                           // E-04 (`remaining` retired — REV-77 rule 8)
    case resetsFirst, exhaustion, nothingBurning, measuring, weeklyElevated,
         overQuota, onCredits, monthlyOnPace, monthlyRunsOut     // E-08 (D-90)
    case on, off, orgManaged                    // E-12 (`orgManaged` — REV-102, STEP_220)
}

/// Why a live line was not shown. **Diagnostics only** — the view never reads it; it exists so
/// `explanation-snapshot.json` can say "dropped: noBurn" instead of leaving a silent gap
/// (REV-75/D-93, STEP_133). Rule 4 is that the card shows its concept text alone: never a
/// placeholder, never a dash.
public enum LiveDropReason: String, Sendable {
    case noTemplate       // the spec cell for this (element, variant, tool) reads "—"
    case noWindow, noReset, noBurn, noRunway, noPace, noSecondary
    case noAttribution, noBalance
    case stale, monthlyLayout, placeholderHero
}

/// A card's live line as the formatter resolved it. `nil` (the absence of this value) means the
/// element has no live line at all on this render — an inert target — which is a different fact
/// from `.dropped`, and STEP_133 records only the latter.
public enum ExplanationLive: Sendable, Equatable {
    case shown(String)
    case dropped(LiveDropReason)

    /// What the view renders — `nil` on a drop.
    public var text: String? {
        if case .shown(let line) = self { return line }
        return nil
    }
}

/// The explanation registry as data (UI Spec Part 3 §5.2, D-72). One entry per element, one copy
/// column per tool (D-11); a `nil` cell means the element is inert on that tab. **Copy is the spec's,
/// byte for byte** — `ExplanationRegistryTests` reads the §5.2 table out of the UI Spec and asserts
/// equality — and it is a *dictionary*: concept cards do not change with state. The one exception is
/// the source-tag card, assembled per rule 4 from what the tag is currently showing.
///
/// **Voice is verdict tier since REV-75/D-87 (STEP_128)** — rule 7: one idea per sentence, "you /
/// your" where natural, and never "we"; the app has no first person.
///
/// Rendered as inline markdown (`**bold lead.**`, `*emphasis*`, `` `~` ``) by `ExplanationCardView`,
/// exactly as the anatomy's flip line already is.
public enum ExplanationRegistry {

    // MARK: Concept cards (rules 1–3, 5, 7)

    /// The card for `element` on `tool`, or `nil` where the spec cell reads "—" (inert) and for
    /// E-08, which has no fixed cell (D-90). `grain` is the D-58 window-grain word (`5-hour` /
    /// `Weekly` / `Monthly`) that fills the Codex placeholders — the tab's primary row is
    /// width-named, so the three cells that name it are too.
    public static func card(_ element: ExplanationElement, tool: Tool, grain: String? = nil) -> String? {
        switch (element, tool) {
        case (.primaryWindow, .claude):
            return "**5-hour window.** The clock starts with your first message, not at a fixed time, so the reset moves with when you started. Usage returns to zero at the reset."
        case (.primaryWindow, .codex):
            return filled(codexPrimaryWindowTemplate, grain: grain)

        case (.secondaryWindow, .claude):
            return "**Weekly window.** A second, longer quota on top of the 5-hour one. You need room in both; the tighter one sets the verdict and the colour."
        case (.secondaryWindow, .codex):
            return filled(codexSecondaryWindowTemplate, grain: grain)

        case (.reset, .claude):
            return "**Reset.** When this window ends and usage goes back to zero. The time comes from the account and is exact. Using Claude doesn't push it later — after the reset, your next message simply starts a new window."
        case (.reset, .codex):
            return "**Reset.** When this window ends and usage goes back to zero. The time comes from the account and is exact. Using Codex doesn't push it later — after the reset, your next turn simply starts a new window."

        case (.heroPercent, .claude), (.heroPercent, .codex):
            return "**Percent left.** How much of this window's quota you still have, straight from your account."

        case (.burn, .claude), (.burn, .codex):
            return "**Burn.** How fast you're using the quota, averaged over recent readings — per minute, or per hour on a long window. The account only reports whole percents, so when you're quiet it can't tell slow from stopped — it shows *Measuring…* until it can."

        case (.localSource, .claude):
            return "**Local apps.** What on this Mac used the quota today. A *subagent* is a helper that Claude Code starts for part of a task; its tokens count inside Claude Code's own figure. They all share one quota."
        case (.localSource, .codex):
            return "**Local apps.** Which Codex apps on this Mac used the quota today — the desktop app, the CLI, the editor extension. An app's figure includes helper threads it started. *Unknown app* is one this Mac hasn't seen before. ◷ marks the app seen most recently."

        case (.offMachine, .claude):
            // Desktop leads (REV-81 §3.1): Claude Desktop chat on this Mac writes no JSONL, so it
            // is both invisible to us and the commonest member of this bucket.
            return "**Elsewhere.** Usage that nothing Kvotar can see on this Mac explains — Claude Desktop here, claude.ai, mobile, or Claude Code on another computer. Worked out from timing, not measured."
        case (.offMachine, .codex):
            return "**Elsewhere.** Usage that didn't come from this Mac — the web app, your phone, another computer. It can't be seen directly, so it's worked out by subtraction."

        case (.verdictDetail, .claude), (.verdictDetail, .codex):
            // No fixed cell (D-90) — the card is one per verdict family and lands in STEP_130.
            return nil

        case (.sourceTag, _):
            // State-aware — assembled by `sourceTagCard`. The full glossary is `sourceTagGlossary`.
            return nil

        case (.estTokenValue, .claude), (.estTokenValue, .codex):
            return "**Est. token value.** What this work would have cost if you paid per token at the public API prices. Not a bill — it shows how much work you're getting for what you pay."

        case (.cacheHit, .claude), (.cacheHit, .codex):
            return "**Cache hit.** How much of the model's input today was reused from a cache instead of read fresh. Cached input is much cheaper at API prices. High is normal in long sessions."

        case (.usageCredits, .claude):
            return "**Usage credits.** Optional prepaid money that lets you keep working after you hit 100%, paying API prices until the reset."
        case (.usageCredits, .codex):
            return nil   // "—": no usage-credits concept on the Codex tab; the row is inert.

        case (.rollingHorizons, .claude), (.rollingHorizons, .codex):
            return "**7-day and 30-day.** The same estimate for the last 7 and 30 calendar days, from this Mac's session logs. Nothing to do with your quota windows, and still not a bill — good for spotting a trend."

        case (.weeklyReset, .claude):
            return "**Weekly reset.** When the weekly quota goes back to zero. The date comes from the account and is exact. The 5-hour window has its own, separate reset. Using Claude doesn't push this one later."
        case (.weeklyReset, .codex):
            return filled(codexWeeklyResetTemplate, grain: grain)

        case (.monthlyUsed, .claude):
            return "**Left this month.** How much of your organisation's monthly limit is still there, from the account. The limit is set by your admin. It resets on the date shown."
        case (.monthlyUsed, .codex):
            return "**Left this month.** How much of your organisation's monthly credit limit is still there, from the account. Credits aren't money. It resets on the date shown."

        case (.monthlyPace, .claude):
            return "**Pace.** Your spend per day so far this month, and where that lands against the limit — on pace, or running out before the reset. Worked out from the account's own meter, not from local sessions."
        case (.monthlyPace, .codex):
            return "**Pace.** Your credits per day so far this month, and where that lands against the limit — on pace, or running out before the reset. Worked out from the account's own meter, not from local sessions."

        case (.monthlyReset, .claude):
            return "**Reset.** When the monthly limit goes back to zero. The date comes from the account and is exact. Using Claude doesn't move it."
        case (.monthlyReset, .codex):
            return "**Reset.** When the monthly limit goes back to zero. The date comes from the account and is exact. Using Codex doesn't move it."

        case (.thisMachine, .claude):
            return "**This machine.** The part of this month's spend that happened while Claude Code was active on this Mac. The meter is exact; which bucket each step lands in is an estimate."
        case (.thisMachine, .codex):
            return "**This machine.** The part of this month's credits used while a Codex app was active on this Mac. The meter is exact; which bucket each step lands in is an estimate."

        case (.monthlyOffMachine, .claude):
            return "**Elsewhere.** Usage that nothing Kvotar can see on this Mac explains — Claude Desktop here, claude.ai, mobile, or Claude Code on another computer. Worked out from timing, not measured."
        case (.monthlyOffMachine, .codex):
            return "**Elsewhere.** Credits used while no Codex app on this Mac was active — another computer, or the cloud. Worked out from timing, not measured."

        case (.unattributed, .claude):
            return "**Unattributed.** Spend that was already on the meter before Kvotar was watching this month — after an install mid-month, or a long gap. It isn't guessed into either bucket."
        case (.unattributed, .codex):
            return "**Unattributed.** Credits already on the meter before Kvotar was watching this month — after an install mid-month, or a long gap. They aren't guessed into either bucket."

        case (.spendRate, .claude):
            return "**Spend rate.** How fast this month's limit is being used right now, averaged over the last hour, from the account's own meter. Blank until there are enough readings to average."
        case (.spendRate, .codex):
            return "**Spend rate.** How fast this month's credits are being used right now, averaged over the last hour, from the account's own meter. Blank until there are enough readings to average."

        case (.scopedLimit, .claude):
            return "**Model limit.** A weekly cap on this model alone, on top of the weekly limit above. Use it all and that model stops until the weekly reset. Everything else keeps running on whatever the weekly limit has left."
        case (.scopedLimit, .codex):
            return "**Model limit.** A separate cap on this model alone, with its own windows. Use it all and that model stops until its reset. Everything else keeps running on the account's own limit."

        case (.localActivity, .claude):
            return "**Today on this Mac.** Work Claude Code logged here since midnight, grouped by project. Anything else on your account — Claude Desktop, the web, another computer — isn't in it. These are grouped folders, not a list of open repositories."
        case (.localActivity, .codex):
            return "**Today on this Mac.** Work the Codex apps logged here since midnight, grouped by project. Anything else on your account — the web app, your phone, another computer — isn't in it. These are grouped folders, not a list of open repositories."

        case (.projectRecency, .claude), (.projectRecency, .codex):
            return "**Most recent.** This project has the newest logged activity today. It doesn't mean the window is open or anything is running now."
        }
    }

    /// The header fact's period-specific burn explanation (REV-94). It keeps derivation and
    /// whole-percent uncertainty in the card after the visible `(derived)` marker is removed.
    public static func burnFactCard(tool: Tool, period: String, monthly: Bool) -> String {
        if monthly {
            let noun = tool == .claude ? "limit" : "credit limit"
            return "**Quota burn.** How fast the \(period.lowercased()) \(noun) is being used right now, averaged over recent account readings. The rate is derived from changes in the account meter; tiny positive rates use a less-than bound instead of rounding to zero."
        }
        return "**Quota burn.** How fast the \(period.lowercased()) quota is being used, averaged over recent account readings. The rate is derived from changes in the account meter. The account reports whole percents, so very small changes are bounded rather than shown as zero."
    }

    /// The approved denominator and limitation for the header's local-observation gap.
    public static func notSeenLocallyFactCard(period: String) -> String {
        let periodPhrase = period.lowercased().hasSuffix("period")
            ? period.lowercased() : "\(period.lowercased()) period"
        return "**Not seen locally.** Estimated account usage not explained by local activity logs during this \(periodPhrase). It may come from other apps on this Mac, other devices, or missing or delayed data. It does not necessarily mean another device was used."
    }

    // MARK: The Codex grain templates (the `[Width]` / `[grain]` cells; tests compare these)

    /// The Codex E-01 cell with its `[Width]` placeholder intact.
    static let codexPrimaryWindowTemplate =
        "**[Width] window.** The account sets the length. The clock starts with your first turn, not at a fixed time, so the reset moves with when you started. Usage returns to zero at the reset."

    /// The Codex E-02 cell with its `[grain]` placeholder intact.
    static let codexSecondaryWindowTemplate =
        "**Weekly window.** A second, longer quota on top of the [grain] one. You need room in both; the tighter one sets the verdict and the colour."

    /// The Codex E-14 cell with its `[grain]` placeholder intact.
    static let codexWeeklyResetTemplate =
        "**Weekly reset.** When the weekly quota goes back to zero. The date comes from the account and is exact. The [grain] window has its own, separate reset. Using Codex doesn't push this one later."

    /// Fill a Codex grain placeholder. One substitution for both spellings — `[Width]` leads its
    /// sentence, `[grain]` sits inside one — so a cell can never be rendered half-filled. An
    /// unreported width reads `5-hour`, never a literal placeholder.
    private static func filled(_ template: String, grain: String?) -> String {
        let word = grain ?? "5-hour"
        return template
            .replacingOccurrences(of: "[Width]", with: word)
            .replacingOccurrences(of: "[grain]", with: word)
    }

    // MARK: Live lines (rule 4 as amended — REV-75/D-88 + D-90, STEP_130)

    /// The live-line template for `(element, variant)` on `tool`, placeholders intact, or `nil`
    /// where the spec cell reads "—". **One table**: `verdictDetailCard` is a name for a slice of
    /// it, not a second copy.
    ///
    /// Placeholder vocabulary, pinned by `ExplanationRegistryTests`: `[start] [reset] [wkReset]
    /// [left] [wkLeft] [used] [grain] [runway] [countdown] [stops] [elapsed] [period] [pace]
    /// [total] [local] [off] [balance] [limit] [days] [diff] [line]` — plus `[Width]`, which belongs to the
    /// fixed Codex E-01 cell above and to no live template. `[left]` / `[wkLeft]` are remaining
    /// (REV-77 / D-97); `[used]` survives in E-07's attribution arithmetic and in the bridge line.
    ///
    /// **`[pace]` names two different things**, deliberately (REV-75 §4.2's implementer note):
    /// in `E-04·pace` it takes one of `over pace` / `under pace` / `on pace` (the anatomy's Pace-row
    /// vocabulary — "ahead of the calendar" read as good news and named no subject), and in the two
    /// monthly E-08 rows it takes the per-day amount. One name, two elements — a second
    /// placeholder would have to be kept in step with the same vocabulary test for no gain.
    public static func liveTemplate(_ element: ExplanationElement, variant: LiveVariant,
                                    tool: Tool) -> String? {
        let cells: (claude: String?, codex: String?)
        switch (element, variant) {
        case (.primaryWindow, .live):   // E-01·live
            let both = "*This one started at [start] and resets at [reset].*"
            cells = (both, both)
        case (.primaryWindow, .notStarted):   // E-01·notStarted — both tools since REV-80 / D-101
            let both = "*Not started yet — your first turn starts the clock.*"
            cells = (both, both)
        case (.secondaryWindow, .primaryTighter):   // E-02·primaryTighter
            cells = ("*Right now the 5-hour window is the tighter one — [left]% left, against [wkLeft]% on the weekly.*",
                     "*Right now the [grain] window is the tighter one — [left]% left, against [wkLeft]% on the weekly.*")
        case (.secondaryWindow, .weeklyTighter):   // E-02·weeklyTighter
            cells = ("*Right now the weekly window is the tighter one — [wkLeft]% left, against [left]% on the 5-hour.*",
                     "*Right now the weekly window is the tighter one — [wkLeft]% left, against [left]% on the [grain] window.*")
        case (.secondaryWindow, .aheadOfPace):   // E-02·aheadOfPace
            let both = "*[used]% of the week used with [elapsed]% of it gone — [diff] points ahead.*"
            cells = (both, both)
        case (.secondaryWindow, .nearlySpent):   // E-02·nearlySpent
            // The line, named. A reader at 92 % with four days left and a calm five-hour window
            // needs to be told the *position* is what decided it, not the pace — otherwise the
            // red reads as a mistake.
            let both = "*At [used]%, past the [line]% line — that sets the verdict whatever the pace.*"
            cells = (both, both)
        case (.monthlyUsed, .aheadOfPace):   // E-15/E-16·aheadOfPace
            cells = ("*[used]% spent, [elapsed]% of the month gone — [diff] points ahead of even pace.*",
                     "*[used]% used, [elapsed]% of the month gone — [diff] points ahead of even pace.*")
        case (.monthlyUsed, .nearlySpent):   // E-15/E-16·nearlySpent
            cells = ("*[used]% spent, past the [line]% line — that sets the verdict whatever the pace.*",
                     "*[used]% used, past the [line]% line — that sets the verdict whatever the pace.*")
        case (.heroPercent, .runway):   // E-04·runway
            let both = "*About [runway] of usage left at today's speed.*"
            cells = (both, both)
        case (.heroPercent, .pace):   // E-04·pace
            let both = "*[elapsed]% of the [period] gone — you're [pace].*"
            cells = (both, both)
        case (.offMachine, .live):   // E-07·live
            let both = "*The account says [total]% used, this Mac explains ≈[local]%, so ≈[off]% came from elsewhere.*"
            cells = (both, both)
        case (.offMachine, .none):   // E-07·none
            let both = "*This window, everything the account shows is explained by this Mac.*"
            cells = (both, both)
        case (.verdictDetail, .resetsFirst):   // E-08·resetsFirst
            let both = "**Runway.** How long you can keep going at this speed before the quota runs out. *Yours: about [runway] — longer than the [countdown] to the reset, so the reset comes first.* The `~` means estimate. Reset times are exact."
            cells = (both, both)
        case (.verdictDetail, .exhaustion):   // E-08·exhaustion
            let both = "**Runway.** How long you can keep going at this speed before the quota runs out. *Yours: about [runway] — shorter than the [countdown] to the reset, so you'd stop at ~[stops].* The `~` means estimate. Reset times are exact."
            cells = (both, both)
        case (.verdictDetail, .nothingBurning):   // E-08·nothingBurning
            let both = "**Runway.** How long you can keep going at this speed before the quota runs out. *Nothing is burning right now, so the reset comes first.* Reset times are exact."
            cells = (both, both)
        case (.verdictDetail, .measuring):   // E-08·measuring
            let both = "**Runway.** How long you can keep going at this speed before the quota runs out. *Not measured yet — it shows once the account's number has moved.* Reset times are exact."
            cells = (both, both)
        case (.verdictDetail, .weeklyElevated):   // E-08·weeklyElevated
            cells = ("**Two resets.** The weekly limit is what's tight, so its reset is the one that matters — the 5-hour reset won't free anything up. *Weekly resets [wkReset]; the 5-hour window at [reset].*",
                     "**Two resets.** The weekly limit is what's tight, so its reset is the one that matters — the [grain] reset won't free anything up. *Weekly resets [wkReset]; the [grain] window at [reset].*")
        case (.verdictDetail, .overQuota):   // E-08·overQuota
            cells = ("**Blocked.** You've used 100% of this window. Nothing runs until the reset at [reset] — unless usage credits are on.",
                     "**Blocked.** You've used 100% of this window. Nothing runs until the reset at [reset].")
        case (.verdictDetail, .onCredits):   // E-08·onCredits
            cells = ("**On credits.** You're past 100%, so every token is now paid from your prepaid balance at API prices, until the reset at [reset].",
                     nil)
        case (.verdictDetail, .monthlyOnPace):   // E-08·monthlyOnPace
            cells = ("**Pace.** Your spend per day so far this month, against the limit. *~[pace] a day — at that rate the month ends before you reach [limit].*",
                     "**Pace.** Your credits per day so far this month, against the limit. *~[pace] a day — at that rate the month ends before you reach [limit].*")
        case (.verdictDetail, .monthlyRunsOut):   // E-08·monthlyRunsOut
            cells = ("**Pace.** Your spend per day so far this month, against the limit. *~[pace] a day — at that rate you'd reach [limit] about [days] before the reset.*",
                     "**Pace.** Your credits per day so far this month, against the limit. *~[pace] a day — at that rate you'd reach [limit] about [days] before the reset.*")
        case (.usageCredits, .off):   // E-12·off
            cells = ("*Yours are off — at 100%, Claude stops and waits for the reset.*",
                     nil)
        case (.usageCredits, .orgManaged):   // E-12·orgManaged
            cells = ("*Yours are paid by your organization — past 100%, work is charged at API prices against its [limit] monthly cap.*",
                     nil)
        case (.usageCredits, .on):   // E-12·on
            cells = ("*Yours are on — past 100%, work is paid from your [balance] balance until the reset.*",
                     nil)
        default:
            return nil
        }
        return tool == .claude ? cells.claude : cells.codex
    }

    /// The whole E-08 card for a verdict family (D-90) — lead, sentence and live segment in one
    /// string, because the segment sits *inside* the card rather than under it. `card(.verdictDetail)`
    /// is nil by the same decision, so this is the only body that element ever has. Filled by
    /// `liveLine` exactly like any other template.
    public static func verdictDetailCard(family: LiveVariant, tool: Tool) -> String? {
        liveTemplate(.verdictDetail, variant: family, tool: tool)
    }

    /// Fill a live template from the values `DisplayFormatter` supplies (rule 4). The registry
    /// owns the words and this rule; the formatter owns the values and never assembles prose.
    ///
    /// - a cell reading "—" ⇒ `.dropped(.noTemplate)`
    /// - **any** value `nil` ⇒ `.dropped(missing)` — the whole line goes, without trace
    /// - otherwise every `[name]` is replaced and the result is `.shown`
    ///
    /// A DEBUG assertion fires if a bracket survives, which is the only way a placeholder typo
    /// can reach a card: the vocabulary test pins the template side, this pins the fill side.
    public static func liveLine(_ element: ExplanationElement, variant: LiveVariant, tool: Tool,
                                values: [String: String?] = [:],
                                missing: LiveDropReason) -> ExplanationLive {
        guard let template = liveTemplate(element, variant: variant, tool: tool) else {
            return .dropped(.noTemplate)
        }
        var line = template
        for (name, value) in values {
            guard let value else { return .dropped(missing) }
            line = line.replacingOccurrences(of: "[\(name)]", with: value)
        }
        assert(line.range(of: "\\[[A-Za-z]+\\]", options: .regularExpression) == nil,
               "\(element.specID)·\(variant.rawValue) \(tool): unfilled placeholder in \(line)")
        // A template writes its own sign after the placeholder (`[used]% used`), so a value
        // formatted with `Fmt.percent` renders `40%%`. Caught live on the first six fills; pinned
        // here because the next one will be written the same way. `Fmt.percentNumber` is the fill.
        assert(!line.contains("%%"),
               "\(element.specID)·\(variant.rawValue) \(tool): doubled sign in \(line)")
        return .shown(line)
    }

    // MARK: The bridge line (rule 8 — REV-77/D-97, STEP_139)

    /// The first line of every card on an element that shows a quota percentage — the hero
    /// (E-04 / E-15), the Account-quota rows, the weekly row, the D-94 scoped row. Prose in the
    /// spec (rule 8), not a table row, so it is **not** a `LiveVariant`: one template, filled
    /// from the utilization the element was drawn from. `[used]` is the raw figure, **uncapped**
    /// — an over-quota card reads *`0% left · 106% used`* — and this is the only place the app
    /// shows a used figure (§0.1).
    public static let bridgeTemplate = "*[left]% left · [used]% used*"

    /// Fill the bridge line. `nil` utilization (a null / unknown window) drops it like any live
    /// line — the card shows its concept text alone.
    public static func bridgeLine(utilization: Double?) -> ExplanationLive {
        guard let utilization else { return .dropped(.noWindow) }
        return .shown(bridgeTemplate
            .replacingOccurrences(of: "[left]", with: Fmt.percentNumber(Fmt.remaining(utilization)))
            .replacingOccurrences(of: "[used]", with: Fmt.percentNumber(utilization)))
    }

    // MARK: Source-tag card (rule 4 — the one state-aware entry)

    /// The E-09 glossary segments, verbatim from the spec cell. The card shows the segments whose
    /// term the tag is currently displaying, plus the freeze sentence when a reason is known. The
    /// `est.` sentence names the tool whose logs it means, so it is per column (STEP_128).
    private static let exactSegment = "**exact:** straight from your account."
    private static func estSegment(tool: Tool) -> String {
        switch tool {
        case .claude: return "**est.:** estimated from Claude Code's session logs on this Mac."
        case .codex: return "**est.:** estimated from Codex's session logs on this Mac."
        }
    }
    private static let asOfSegment = "**as of [t]:** the last good reading — nothing fresher was available."
    private static let reconnectingSentence = "*Reconnecting…* — the account isn't answering right now."
    private static let signInExpiredSentence = "*sign-in expired* — open Claude Code to sign in again."

    /// The whole E-09 cell for `tool` — the spec's glossary form, every term and every freeze
    /// reason. Not rendered as such; it pins the segments byte-for-byte against the spec.
    public static func sourceTagGlossary(tool: Tool) -> String {
        switch tool {
        case .claude:
            return [exactSegment, estSegment(tool: tool), asOfSegment, reconnectingSentence, signInExpiredSentence]
                .joined(separator: " ")
        case .codex:
            return [exactSegment, estSegment(tool: tool), asOfSegment, reconnectingSentence].joined(separator: " ")
        }
    }

    /// The card for a source tag, assembled from what the tag currently shows (rule 4): the
    /// `exact:` sentence when the tag claims `· exact` / `(exact)`, `est.:` when it carries an
    /// `est.` token, `as of [t]:` — with `[t]` filled from the tag — when it is the stale-keep form,
    /// then the freeze sentence when a reason is known. `nil` when nothing applies: a tag that shows
    /// none of the three terms (the local JSONL tag, the "Priced at…" note) is inert.
    public static func sourceTagCard(tool: Tool, tag: SourceTag, freeze: SourceFreeze?) -> String? {
        var segments: [String] = []
        let base = tag.base
        if base.contains("· exact") || base.contains("(exact)") {
            segments.append(exactSegment)
        }
        if base.contains("est.") {
            segments.append(estSegment(tool: tool))
        }
        if let range = base.range(of: " · as of ") {
            let stamp = String(base[range.upperBound...])
            segments.append(asOfSegment.replacingOccurrences(of: "[t]", with: stamp))
        }
        // A tag showing none of the three terms is not an account claim (the local JSONL tag, the
        // "Priced at…" note) — it stays inert even under a freeze, which is about the account.
        guard !segments.isEmpty else { return nil }
        switch (freeze, tool) {
        case (.reconnecting?, _):
            segments.append(reconnectingSentence)
        case (.signInExpired?, .claude):
            segments.append(signInExpiredSentence)
        case (.signInExpired?, .codex), (nil, _):
            // The Codex cell names one reason only; the credential freeze is a Claude concept
            // (D-38) and the formatter never sets it for Codex — nothing is said rather than a
            // reason the verdict would not.
            break
        }
        return segments.joined(separator: " ")
    }
}
