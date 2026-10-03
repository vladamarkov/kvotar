import Foundation

/// The one displayed-token-count rule (STEP_109). Extracted from `DisplayFormatter`, where it was
/// private to the UI package, so the popover's per-window count and the History window's per-period
/// count are the same arithmetic. Like `CacheHit`, this encodes a correction that cost real
/// debugging; a second copy in the report would be free to drift back to the wrong one.
public enum DisplayedTokens {

    /// The §4 `Displayed token count` for one model row, **per tool** (STEP_91).
    ///
    /// **Claude — all four columns, cache reads included** (REV-50/D-45). The columns are disjoint
    /// quantities there, and cache reads are ~97% of the count: excluding them is the 28× error
    /// that entry exists to prevent.
    ///
    /// **Codex — `input + output`.** Codex's `cached_input_tokens` is a subset of `input_tokens`
    /// (REV-62 §3.1) and its `reasoning_output_tokens` a subset of `output_tokens` (§3.2), so the
    /// per-turn total the provider itself reports is `input + output`; adding the cache columns
    /// counted the cached slice a second time and nearly doubled the displayed figure (live `go`
    /// window: 4.2M shown against a real 2.26M). Dropping both cache columns is correct under all
    /// three storage conventions (§8.4), whichever one holds the cached count.
    public static func sum(_ t: SQLiteStore.ModelTokenTotals, tool: Tool) -> Int {
        switch tool {
        case .claude: return t.inputTokens + t.outputTokens + t.cacheCreationTokens + t.cacheReadTokens
        case .codex:  return t.inputTokens + t.outputTokens
        }
    }

    /// The same rule summed across every model row in a period.
    public static func total(_ totals: [SQLiteStore.ModelTokenTotals], tool: Tool) -> Int {
        totals.reduce(0) { $0 + sum($1, tool: tool) }
    }
}
