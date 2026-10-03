import Foundation

/// The Codex `originator` → surface-bucket table, and the one place it lives (STEP_197).
///
/// **Why Codex vocabulary sits in `KvotarCore`.** The table was `CodexJSONLParser`'s private
/// business for as long as ingest was its only reader: the parser stamped a bucket onto every
/// token event and nothing downstream needed to ask again. STEP_197 gives it a second reader —
/// the daily local report folds a helper thread into the surface that *spawned* it, which means
/// resolving the helper session's stored `originator` at read time, inside Core, which cannot
/// import an adapter (the same constraint that put `SurfaceWorkSplit` here). Two copies of a
/// table like this one drift the moment a new originator appears: STEP_192 was exactly that
/// failure, one unmapped name reaching the popover as `Unknown`. So there is one table, and
/// `CodexJSONLParser.surfaceBucket` reads it too.
///
/// The helper half of the parser's rule does **not** live here: `Subagent · <nickname>` is
/// decided from a thread's own `thread_source` / `parent_thread_id`, which never reach Core.
public enum CodexSurface {
    /// The bucket an unmapped originator lands in — `SurfaceWorkSplit`'s label, named again here
    /// so the adapter has one import for the whole vocabulary.
    public static let unknownLabel = SurfaceWorkSplit.unknownLabel

    /// The surface a Codex `originator` names. `source` is accepted and deliberately unused by
    /// every row below — see the `Codex Desktop` note — but stays in the signature because it is
    /// part of the recorded evidence and a future row may need it.
    public static func bucket(originator: String, source: String? = nil) -> String {
        switch (originator, source) {
        // Any `source`, `"vscode"` included: the desktop app is built on the VS Code shell and
        // reports itself that way, so the old split told a desktop-only user they had used an
        // editor extension (REV-63 §6.2). A genuine extension routes separately via
        // `codex_vscode` — the row below — which is the evidence for reading this one as the
        // desktop app, and is pinned by `testCodexVSCodeOriginatorStaysIDEExtension`.
        // `codex_work_desktop` is the same desktop app under a new name (STEP-less hotfix,
        // 2026-08-13). ChatGPT.app 26.803.61601 — installed 2026-08-11, carrying codex
        // 0.147.0-alpha.6.5 — hard-codes this originator in its JS layer, and the bundled Rust
        // binary holds a whole new family beside it (`codex_work_web`, `codex_work_mobile`,
        // `codex_work_cca`, `chatgpt_cca`). Only this one is mapped: it is the only member
        // observed writing a real local session file, and the others are cloud surfaces that
        // never write into `~/.codex/sessions` at all. They stay in `Unknown` — bucket and
        // monitor — rather than being pre-mapped on a guess.
        case ("Codex Desktop", _), ("codex_work_desktop", _): return "Desktop"
        case ("codex_vscode", _): return "IDE extension"
        // `codex-tui` is the CLI's current originator (STEP_192, observed 2026-09-13 19:31 CEST on
        // `rollout-2026-09-13T16-14-29-…`, the one live session at the time) — it had been landing
        // in `Unknown`, and `Unknown` reached the popover through the multi-surface card alone.
        case ("codex_cli_rs", _), ("codex_exec", _), ("codex-tui", _): return "CLI"
        default: return unknownLabel
        }
    }
}
