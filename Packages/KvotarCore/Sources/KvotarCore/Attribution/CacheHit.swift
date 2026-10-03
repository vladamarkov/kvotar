import Foundation

/// The one cache-hit rule (STEP_109). Extracted verbatim from `AttributionEngine`, where it was
/// private, so the popover's per-window figure and the History window's per-period figure cannot
/// drift apart. Both corrections encoded here were expensive to find; a second copy would lose them.
public enum CacheHit {

    /// Cache-hit ratio over a set of model totals (UI Spec §2.5 Claude / §2.6 Codex, STEP_27) —
    /// cached prompt tokens as a fraction of *all* prompt tokens, so a cache miss (freshly-written
    /// cache) correctly lowers the ratio (REV-21). `nil` when the denominator is empty; never
    /// fabricated as 0.
    ///
    /// **Claude:** `cacheRead / (input + cacheRead + cacheCreation)`. The three columns are
    /// disjoint quantities here, and cacheCreation tokens are misses written into the cache, so
    /// they belong in the denominator, not the numerator. Unchanged since REV-21.
    ///
    /// **Codex:** `cached / input` *(corrected STEP_91 — was `cached / (input + cached)`)*.
    /// Codex's `cached_input_tokens` is a **subset of** `input_tokens`, not a sibling of it
    /// (REV-62 §3.1: `cached <= input` in 4,905/4,905 events, and each turn's cached count tracks
    /// the *previous* turn's input at a median ratio of 0.9954 — cached is the re-sent
    /// transcript), so `input` is already the whole prompt and adding `cached` to it counted the
    /// cached slice twice. The old form under-reported the live `go` window as 46% against a real
    /// 85%. The numerator reads **both** cache columns via `codexCachedInputTokens` — the corpus
    /// stores that one quantity under two conventions either side of 2026-07-13 (§8.4), which is
    /// why a History period spanning that boundary must not read one column alone.
    public static func ratio(tool: Tool, totals: [SQLiteStore.ModelTokenTotals]) -> Double? {
        let input = totals.reduce(0) { $0 + $1.inputTokens }
        switch tool {
        case .claude:
            let cached = totals.reduce(0) { $0 + $1.cacheReadTokens }
            let uncachedExtra = totals.reduce(0) { $0 + $1.cacheCreationTokens }
            let denom = input + cached + uncachedExtra
            guard denom > 0 else { return nil }
            return Double(cached) / Double(denom)
        case .codex:
            let cached = totals.reduce(0) { $0 + $1.codexCachedInputTokens }
            guard input > 0 else { return nil }
            return Double(cached) / Double(input)
        }
    }
}
