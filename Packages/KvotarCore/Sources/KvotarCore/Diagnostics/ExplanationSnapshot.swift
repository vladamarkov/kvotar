import Foundation

/// What the popover was explaining at the moment a bundle was saved (REV-75/D-93, STEP_133).
///
/// The explanation layer's live line is *silent* when a value it needs is missing — rule 4 says
/// the card shows its concept text alone, never a placeholder and never a dash. On screen that is
/// right; in a support bundle it is a hole. This file closes it: every hover target as rendered,
/// with the line that filled it **or the reason it was dropped**, plus the verdict's anatomy.
/// A tester saves a bundle and every card is readable exactly as they saw it.
///
/// **Strings only, and deliberately so.** `ExplanationElement`, `ExplanationLive` and the registry
/// live in `KvotarUI`, which Core does not import; the walker on the other side of that boundary
/// (`AppViewModel.explanationSnapshot`) resolves every card and every drop reason and hands over
/// finished text. Core stores and ships it, and knows nothing about the layer that produced it.
///
/// **Privacy is by construction, not by redaction.** Only *tagged* elements are walked — a row the
/// formatter left untagged is inert on screen and absent here, which is what keeps the last active
/// project, the per-model rows, the session counts, the account email and the plan badge out of
/// the file. Nothing in here is filtered on the way in, because nothing that would need filtering
/// can reach it. What does travel is the never-store list's permitted half (REV-52 §4, Baseline
/// §10/§17): percentages, durations, clock times, dates, rates, and the app's own copy.
///
/// **This file does not cross the `DiagnosticsPayloadSanitizer` boundary** — that seam exists for
/// raw *provider* bodies, which nobody has normalized. Its key names are still avoided here
/// (`cardText`, `liveLine`, `label`, `value`, `inputs` — never `code`, `content`, `prompt`,
/// `secret`, `bearer`), so that a future decision to route this file through the sanitizer would
/// not silently redact half of it. The tool name `codex` is a *value*, never a key.
public struct ExplanationSnapshot: Codable, Sendable, Equatable {

    /// One hover target, exactly as it was rendered.
    public struct Entry: Codable, Sendable, Equatable {
        /// The spec's row ID — `E-01` … `E-22` (UI Spec Part 3 §5.2).
        public let element: String
        /// Where in the popover it was drawn: a section name (`Account quota`, `burn card`,
        /// `What happened`) or a header slot (`header hero`, `D-58 caption`, `verdict line 2`).
        /// With `label` this identifies the target — two cards can share a label across sections.
        public let site: String
        /// The row's own label, or `nil` for a target that has none (the hero, the caption, the
        /// verdict's detail line, a source tag).
        public let label: String?
        /// What the target displayed.
        public let value: String
        /// The concept card as the registry resolved it for this tab. `nil` on E-08, whose card is
        /// one per verdict family and therefore arrives whole in `liveLine` (D-90) — a target with
        /// neither a card nor a line is inert and is not recorded at all.
        public let cardText: String?
        /// The live line as rendered, or `nil` where none was shown.
        public let liveLine: String?
        /// Why the live line was not shown — `noBurn`, `noWindow`, `stale`, … `nil` when a line
        /// was shown, and also when the target never had one (an inert target records no drop).
        public let liveDropReason: String?

        public init(element: String, site: String, label: String?, value: String,
                    cardText: String?, liveLine: String?, liveDropReason: String?) {
            self.element = element
            self.site = site
            self.label = label
            self.value = value
            self.cardText = cardText
            self.liveLine = liveLine
            self.liveDropReason = liveDropReason
        }
    }

    /// The verdict's work, as the anatomy block showed it (UI Spec Part 3 §5.3).
    public struct Anatomy: Codable, Sendable, Equatable {
        /// The `VerdictFamily` raw value — identity, not wording.
        public let family: String
        /// `[label, value]` per row, in render order.
        public let rows: [[String]]
        public let comparison: String
        /// What the line reads next and the nearest condition that gets it there; `nil` where no
        /// honest next condition exists.
        public let flip: String?

        public init(family: String, rows: [[String]], comparison: String, flip: String?) {
            self.family = family
            self.rows = rows
            self.comparison = comparison
            self.flip = flip
        }
    }

    /// One tab.
    public struct ToolSnapshot: Codable, Sendable, Equatable {
        /// `claude` / `codex` — a value, never a key.
        public let tool: String
        /// Whether the tab was showing a stale-kept render (§9.3): every number below is then the
        /// last known one, not a current one.
        public let stale: Bool
        /// The render's own inputs, once per tab — used %, reset, window width, weekly %, burn,
        /// runway, off-machine %, tok/min, the monthly figures. What the entries below were
        /// computed *from*, so a wrong line can be told apart from a wrong input.
        public let inputs: [String: String]
        public let entries: [Entry]
        public let anatomy: Anatomy?

        public init(tool: String, stale: Bool, inputs: [String: String],
                    entries: [Entry], anatomy: Anatomy?) {
            self.tool = tool
            self.stale = stale
            self.inputs = inputs
            self.entries = entries
            self.anatomy = anatomy
        }
    }

    public let takenAt: Int
    public let takenAtLocal: String
    /// The tab that was in front when the bundle was saved.
    public let activeTab: String
    /// The peek timings in force (`ExplanationTiming`) — a card that never opened for a tester is
    /// a timing question first.
    public let peekDelayMs: Int
    public let graceLeaveMs: Int
    public let tools: [ToolSnapshot]

    public init(takenAt: Date, activeTab: String, peekDelayMs: Int, graceLeaveMs: Int,
                tools: [ToolSnapshot]) {
        self.takenAt = Int(takenAt.timeIntervalSince1970)
        self.takenAtLocal = BundleTime.iso(takenAt)
        self.activeTab = activeTab
        self.peekDelayMs = peekDelayMs
        self.graceLeaveMs = graceLeaveMs
        self.tools = tools
    }

    /// The archive member this is written as.
    public static let filename = "explanation-snapshot.json"
}
