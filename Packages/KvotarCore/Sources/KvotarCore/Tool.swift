/// The two agent tools Kvotar monitors. Shared primitive used by the display models,
/// the SQLite `tool` column, adapters, and `windowReset(tool:)`.
/// Naming per PATTERNS.md §Naming conventions: menu-bar prefixes are `CL` / `CX`.
public enum Tool: String, Sendable, CaseIterable {
    case claude
    case codex

    /// Menu-bar prefix — `CL` for Claude, `CX` for Codex (Baseline §4, UI Spec D-01).
    public var menuBarPrefix: String {
        switch self {
        case .claude: return "CL"
        case .codex: return "CX"
        }
    }

    /// Popover tab label — full name, not the menu-bar prefix (UI Spec §15.1).
    public var tabLabel: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}
