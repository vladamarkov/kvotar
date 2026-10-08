import Foundation

/// How the History window and the popover's daily report turn stored working directories into
/// project rows ([local usage](docs/spec/local-usage.md#todays-local-report)).
///
/// Both parsers store the **working directory** of a request (Claude's per-message `cwd`,
/// Codex's `threads.cwd`) — nothing else — and a session is labelled by the folder of its
/// earliest request (`SQLiteStore+TokenEvents.swift`). Every stored folder is then its own row:
/// no folder rolls into another, and a session stored elsewhere never changes a project's
/// identity.
///
/// **Why no roll-up:** the earlier rule rolled a path into the longest stored ancestor that had
/// a stored sub-folder session of its own. A folder became a root only by such an accident, so
/// one old session launched from a container like `~/Documents` absorbed every repo beneath it
/// that lacked one. Pure string rules only. **No filesystem access, no Git, no usage weights**:
/// walking up from `cwd` to find a repo root would read the user's disk outside agent-owned
/// directories, which the feature-attribution brainstorm rejected (FCA §17), and would not work
/// on history whose directories are gone.
public enum ProjectGrouping {

    /// Directories that are not projects: nil/empty, the root, temp trees, and a bare home
    /// directory. Their tokens are real and stay in the totals; they render as one honest
    /// "(no project)" row rather than as a project called `tmp`.
    public static func isNonProject(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return true }
        let p = (path as NSString).standardizingPath
        if p == "/" { return true }
        for prefix in temporaryPrefixes where p == prefix || p.hasPrefix(prefix + "/") {
            return true
        }
        // `/Users/<name>` and `/home/<name>` — a home directory, not a project.
        let parts = p.split(separator: "/")
        if parts.count == 2, parts[0] == "Users" || parts[0] == "home" { return true }
        return false
    }

    /// Temp trees on macOS: `/tmp` (a symlink to `/private/tmp`), `$TMPDIR` under
    /// `/var/folders` (likewise `/private/var/folders`).
    static let temporaryPrefixes = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]

    /// The row a path belongs to: the standardised path itself. `…/kvotar/dist` and `…/kvotar`
    /// are two rows, as are siblings that merely share a name prefix. Non-project paths return
    /// nil.
    public static func canonical(_ path: String?) -> String? {
        guard !isNonProject(path), let path else { return nil }
        return (path as NSString).standardizingPath
    }
}
