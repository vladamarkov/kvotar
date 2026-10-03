import Foundation

/// How the History window turns stored working directories into project rows (STEP_109
/// follow-up; roll-up rule replaced in STEP_157).
///
/// Both parsers store the **working directory** the agent was launched from (Claude's per-message
/// `cwd`, Codex's `threads.cwd`) — nothing else. On the dogfood machine that produced five rows for
/// one repository (`agentpilot`, `Packages/KvotarCore`, `Packages/KvotarUI`, `dist`, `docs`)
/// and promoted `/private/tmp` (30 Codex threads) and the home directory to "projects".
///
/// Two pure-string rules, applied over the set of paths already in the database. **No filesystem
/// access, no Git, no usage weights**: walking up from `cwd` to find a repo root would read the
/// user's disk outside agent-owned directories, which the feature-attribution brainstorm rejected
/// (FCA §17), and would not work on history whose directories are gone. Repo identity proper
/// (branch, remote URL) is FCA Phase-1 capture work, not a display rule.
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

    /// The row a path belongs to, given every distinct path seen for the tool: the **longest
    /// root** that is an ancestor of the path or the path itself. A stored path is a *root* when
    /// it has a stored proper descendant (a repo proves itself by its subfolder sessions) or no
    /// stored proper ancestor. `…/kvotar/dist` still rolls into `…/kvotar` when both were used;
    /// a sub-folder used on its own stays a row, because nothing says it is a sub-folder of
    /// anything. Non-project paths return nil.
    ///
    /// **Why not the shortest stored ancestor (STEP_109 → STEP_157):** that rule let one
    /// 25-minute session launched from `~/Documents` absorb a month of work — the single stored
    /// container path was an ancestor of both repos, so 131 sessions rendered as
    /// `Documents · 133 sessions`. Being roots themselves, the repos now stop the walk, and the
    /// container keeps its own honest one-session row. Residuals accepted with the contract
    /// (`TASKS/STEP_157_container_grouping.md`): a container whose only stored content is a
    /// single project with no stored subfolders still absorbs it, and three nested stored levels
    /// can split one repo into two rows. Rejected there: usage-weight dominance (threshold flaps
    /// rows month to month) and hardcoded folder names (hides a real project kept in Documents).
    public static func canonical(_ path: String?, among paths: [String?]) -> String? {
        guard !isNonProject(path), let path else { return nil }
        let p = (path as NSString).standardizingPath
        let candidates = paths.compactMap { $0 }
            .filter { !isNonProject($0) }
            .map { ($0 as NSString).standardizingPath }
        let roots = candidates.filter { c in
            candidates.contains { $0 != c && $0.hasPrefix(c + "/") }
                || !candidates.contains { $0 != c && c.hasPrefix($0 + "/") }
        }
        var best: String?
        for r in roots where (p == r || p.hasPrefix(r + "/")) && r.count > (best?.count ?? -1) {
            best = r
        }
        return best ?? p
    }
}
